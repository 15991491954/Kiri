//! Tauri command surface and application orchestration.
//! Synchronous commands run on the main thread; heavy work is spawned onto
//! background threads.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use tauri::{
    AppHandle, Emitter, Manager, Monitor, WebviewUrl, WebviewWindow, WebviewWindowBuilder,
};

use crate::capture::current as capture_backend;
use crate::core::annotation::{AnnotationAppearance, AnnotationAppearancePatch, AnnotationDocument, AnnotationPixelSize};
use crate::core::asset::{CaptureAsset, CaptureKind};
use crate::core::geometry::Rect;
use crate::core::library::{AssetLibraryError, EditorAnnotationState};
use crate::core::library_location::{
    self, LibraryAvailability, LibraryLocationError, LibraryStatusSnapshot,
};
use crate::core::policy::{RecordingOptions, RecordingOutputFormat};
use crate::core::recording_recovery::PendingRecording;
use crate::platform;
use crate::shortcut_settings::{
    RegistrationStatus as ShortcutRegistrationStatus, ShortcutAction, ShortcutSettingDto,
};
#[cfg(any(target_os = "macos", target_os = "linux"))]
use crate::state::RecoveryAction;
use crate::state::{
    emit_asset_content_changed, emit_error, emit_library_changed, emit_notice, emit_notice_local,
    emit_notice_on_monitor, emit_recording_state, show_completion_preview, ActiveRecording,
    AppState, ApprovedEditorSave, CaptureSession, CompletionPreviewDto, OverlayBinding,
    PendingCaptureCompletion, RecordingConfiguration, RecordingFlow, RecordingSaveJobDto,
    RecordingSaveJobGuard, StagedCaptureAnnotation, StagedEditorAnnotation,
};

// ---------------------------------------------------------------------------
// DTOs
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RectDto {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GifConversionStateDto {
    id: String,
    is_converting: bool,
    phase: &'static str,
    progress: Option<f64>,
    error: Option<String>,
}

fn publish_gif_state(app: &AppHandle, update: GifConversionStateDto) {
    let state = app.state::<AppState>();
    let id = uuid::Uuid::parse_str(&update.id).expect("internal GIF asset UUID");
    {
        let mut conversions = state.gif_conversions.lock().unwrap();
        if !update.is_converting { conversions.remove(&id); }
        else { conversions.insert(id, update.clone()); }
    }
    let _ = app.emit("gif-conversion-state", update);
}

#[tauri::command]
pub fn get_gif_conversion_states(app: AppHandle) -> Vec<GifConversionStateDto> {
    app.state::<AppState>().gif_conversions.lock().unwrap().values().cloned().collect()
}

impl From<&Rect> for RectDto {
    fn from(rect: &Rect) -> Self {
        Self {
            x: rect.x,
            y: rect.y,
            width: rect.width,
            height: rect.height,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CaptureContextDto {
    pub capture_id: uuid::Uuid,
    pub initial_mode: crate::state::CaptureMode,
    pub display_width: f64,
    pub display_height: f64,
    pub scale: f64,
    pub pixel_width: i64,
    pub pixel_height: i64,
    pub window_rects: Vec<RectDto>,
    pub source_application: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AssetDto {
    pub id: String,
    pub kind: String,
    pub created_at: f64,
    pub filename: String,
    pub title: Option<String>,
    pub ocr_text: Option<String>,
    pub tags: Vec<String>,
    pub pixel_width: i64,
    pub pixel_height: i64,
    pub duration: Option<f64>,
    pub file_size: Option<u64>,
    pub source_application: Option<String>,
    pub is_favorite: bool,
    pub trashed_at: Option<f64>,
    pub gif_eligible: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LibraryStatusDto {
    location_label: String,
    is_default: bool,
    availability: LibraryAvailability,
}

impl From<LibraryStatusSnapshot> for LibraryStatusDto {
    fn from(status: LibraryStatusSnapshot) -> Self {
        Self {
            location_label: status.location_label,
            is_default: status.is_default,
            availability: status.availability,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AssetAvailabilityDto {
    status: &'static str,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PendingRecordingDto {
    id: String,
    created_at: f64,
}

pub(crate) fn asset_dto(asset: &CaptureAsset) -> AssetDto {
    AssetDto {
        id: asset.id.to_string(),
        kind: asset.kind.as_str().to_string(),
        created_at: asset.created_at,
        filename: asset.filename.clone(),
        title: asset.title.clone(),
        ocr_text: asset.ocr_text.clone(),
        tags: asset.tags.clone(),
        pixel_width: asset.pixel_width,
        pixel_height: asset.pixel_height,
        duration: asset.duration,
        file_size: None,
        source_application: asset.source_application.clone(),
        is_favorite: asset.is_favorite,
        trashed_at: asset.trashed_at,
        gif_eligible: asset.kind == CaptureKind::Video
            && crate::core::policy::RecordingPolicy::is_gif_eligible(asset.duration),
    }
}

fn completion_asset_detail(asset: &CaptureAsset) -> String {
    let format = match asset.kind {
        CaptureKind::Image => "PNG",
        CaptureKind::Video => "MP4",
        CaptureKind::Gif => "GIF",
    };
    let mut parts = vec![format.to_string()];
    if let Some(duration) = asset.duration {
        parts.push(crate::core::policy::RecordingPolicy::elapsed_label(
            duration,
        ));
    }
    if asset.pixel_width > 0 && asset.pixel_height > 0 {
        parts.push(format!("{} × {}", asset.pixel_width, asset.pixel_height));
    }
    parts.join(" · ")
}

// ---------------------------------------------------------------------------
// Library commands (main thread)
// ---------------------------------------------------------------------------

#[tauri::command]
pub async fn list_assets(
    app: AppHandle,
    query: String,
    showing_trash: bool,
) -> Result<Vec<AssetDto>, String> {
    // Metadata on a custom/external library can block; keep it off the UI thread.
    tauri::async_runtime::spawn_blocking(move || {
        let state = app.state::<AppState>();
        let mut context = state.library.lock().unwrap();
        let library = context.library().map_err(|error| error.to_string())?;
        let assets = library.search(&query, showing_trash);
        Ok(assets
            .iter()
            // The library is the home of recorded video. Screenshots are a
            // clipboard-first capture: they are copied automatically and kept
            // only long enough to pin or edit, so they never appear in the
            // library list (older ones are purged by the retention pass).
            .filter(|asset| asset.kind != crate::core::asset::CaptureKind::Image)
            .map(|asset| {
                let mut dto = asset_dto(asset);
                dto.file_size = library.asset_file_size(asset);
                dto
            })
            .collect())
    })
    .await
    .map_err(|error| error.to_string())?
}

/// Days a screenshot spends in the library before the retention pass removes
/// it. Pins are memory-only and recordings are kept indefinitely.
const IMAGE_RETENTION_DAYS: f64 = 7.0;
/// How often the retention pass runs while Kiri stays open.
const IMAGE_CLEANUP_INTERVAL: Duration = Duration::from_secs(6 * 60 * 60);
/// Delay before the first pass: capture initialization has priority, and an
/// empty pass every six hours costs nothing.
const IMAGE_CLEANUP_START_DELAY: Duration = Duration::from_secs(20);

/// Starts the periodic screenshot-cache cleanup.
///
/// The library is the durable home of recorded video; screenshots live only
/// long enough to be copied, pinned, or edited. A worker thread removes image
/// assets older than [`IMAGE_RETENTION_DAYS`] and leaves video and GIF assets
/// (and their edit projects) alone. Runs on a worker so no capture, IPC reply,
/// or library render waits for it.
pub(crate) fn start_image_cache_cleanup(app: AppHandle) {
    let spawned = std::thread::Builder::new()
        .name("kiri-image-cleanup".into())
        .spawn(move || {
            std::thread::sleep(IMAGE_CLEANUP_START_DELAY);
            loop {
                purge_expired_screenshots(&app);
                std::thread::sleep(IMAGE_CLEANUP_INTERVAL);
            }
        });
    if let Err(error) = spawned {
        log::warn!("[cleanup] screenshot retention worker could not start: {error}");
    }
}

fn purge_expired_screenshots(app: &AppHandle) {
    let Some(state) = app.try_state::<AppState>() else { return };
    let cutoff = {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|elapsed| elapsed.as_millis() as f64)
            .unwrap_or_default();
        now - IMAGE_RETENTION_DAYS * 86_400_000.0
    };
    let removed = {
        let _transition = state.library_transition.lock().unwrap();
        let mut context = state.library.lock().unwrap();
        match context.library_mut() {
            Ok(library) => library.purge_image_assets_before(cutoff),
            Err(_) => return,
        }
    };
    match removed {
        Ok(0) => {}
        Ok(count) => {
            log::info!("[cleanup] removed {count} expired screenshot(s)");
            emit_library_changed(app);
        }
        Err(error) => log::warn!("[cleanup] screenshot retention failed: {error}"),
    }
}

/// Removes every cached screenshot image now, leaving recordings untouched.
///
/// The periodic pass only clears images past the retention window; this is the
/// user-facing "clear now" action in Settings. It returns how many images were
/// removed so the caller can confirm the result.
#[tauri::command]
pub fn clear_image_cache(app: AppHandle) -> Result<usize, String> {
    let state = app.state::<AppState>();
    let removed = {
        let _transition = state.library_transition.lock().map_err(|error| error.to_string())?;
        let mut context = state.library.lock().map_err(|error| error.to_string())?;
        let library = context.library_mut().map_err(|error| error.to_string())?;
        library
            .purge_image_assets_before(f64::MAX)
            .map_err(|error| error.to_string())?
    };
    if removed > 0 {
        log::info!("[cleanup] removed {removed} cached screenshot(s) on request");
        emit_library_changed(&app);
    }
    Ok(removed)
}

/// Localized confirmation for the tray's "clear image cache" action.
pub(crate) fn cache_cleared_message(locale: &str, removed: usize) -> String {
    let language = crate::core::locale::preferred_language("", locale);
    let template = match language {
        "zh-Hans" => "已清理图片缓存（%d 张）",
        "zh-Hant" => "已清理圖片快取（%d 張）",
        "ja" => "画像キャッシュを削除しました（%d 件）",
        "de" => "Bildcache geleert (%d)",
        "ko" => "이미지 캐시를 정리했습니다 (%d개)",
        "fr" => "Cache d’images vidé (%d)",
        _ => "Image cache cleared (%d)",
    };
    template.replace("%d", &removed.to_string())
}

fn with_asset_mutation(
    app: &AppHandle,
    id: &str,
    mutation: impl FnOnce(&mut crate::core::library::AssetLibrary, &uuid::Uuid) -> Result<(), String>,
) -> Result<(), String> {
    let parsed = uuid::Uuid::parse_str(id).map_err(|e| e.to_string())?;
    let state = app.state::<AppState>();
    let mut context = state.library.lock().unwrap();
    let library = context.library_mut().map_err(|error| error.to_string())?;
    mutation(library, &parsed)?;
    drop(context);
    emit_library_changed(app);
    Ok(())
}

#[tauri::command]
pub fn set_favorite(app: AppHandle, id: String, favorite: bool) -> Result<(), String> {
    with_asset_mutation(&app, &id, |library, parsed| {
        library
            .set_favorite(favorite, parsed)
            .map_err(|e| e.to_string())
    })
}

#[tauri::command]
pub fn move_to_trash(app: AppHandle, window: WebviewWindow, id: String) -> Result<(), String> {
    with_asset_mutation(&app, &id, |library, parsed| {
        library.move_to_trash(parsed).map_err(|e| e.to_string())
    })?;
    if window.label() != "toast" {
        emit_notice_local(&app, "Moved to Trash".into(), "trash".into());
    }
    Ok(())
}

#[tauri::command]
pub fn restore_asset(app: AppHandle, window: WebviewWindow, id: String) -> Result<(), String> {
    with_asset_mutation(&app, &id, |library, parsed| {
        library.restore(parsed).map_err(|e| e.to_string())
    })?;
    if window.label() != "toast" {
        emit_notice_local(
            &app,
            "Restored to Library".into(),
            "arrow.uturn.backward".into(),
        );
    }
    Ok(())
}

fn complete_library_deletion(
    result: Result<(), LibraryLocationError>,
    notify_committed: impl FnOnce(),
) -> Result<(), String> {
    // Cleanup can fail after the durable index update. Refresh every caller's
    // history in that case, while preserving the cleanup error for the user.
    if result.is_ok()
        || matches!(
            &result,
            Err(LibraryLocationError::Library(
                AssetLibraryError::CleanupFailed { .. }
            ))
        )
    {
        notify_committed();
    }
    result.map_err(|error| error.to_string())
}

#[tauri::command]
pub async fn permanently_delete(app: AppHandle, id: String) -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(move || permanently_delete_inner(app, id))
        .await
        .map_err(|error| error.to_string())?
}

fn permanently_delete_inner(app: AppHandle, id: String) -> Result<(), String> {
    let parsed = uuid::Uuid::parse_str(&id).map_err(|e| e.to_string())?;
    let state = app.state::<AppState>();
    let store = app.state::<crate::protocol::ProtocolStore>();
    let result: Result<(), LibraryLocationError> =
        crate::protocol::with_thumbnail_invalidation(&store, parsed, || {
            let mut context = state.library.lock().unwrap();
            context.library_mut()?.permanently_delete(&parsed)?;
            Ok(())
        });
    complete_library_deletion(result, || emit_library_changed(&app))?;
    emit_notice_local(&app, "Deleted Permanently".into(), "trash.fill".into());
    Ok(())
}

#[tauri::command]
pub async fn empty_trash(app: AppHandle) -> Result<(), String> {
    // Thumbnail generation and filesystem cleanup can both wait. Keep those
    // waits off the UI thread so confirmation and native events stay live.
    tauri::async_runtime::spawn_blocking(move || empty_trash_inner(app))
        .await
        .map_err(|error| error.to_string())?
}

fn empty_trash_inner(app: AppHandle) -> Result<(), String> {
    let state = app.state::<AppState>();
    let store = app.state::<crate::protocol::ProtocolStore>();
    let result: Result<(), LibraryLocationError> =
        crate::protocol::with_selected_thumbnail_invalidations(&store, || {
            let mut context = state.library.lock().unwrap();
            let mut removed_ids = Vec::new();
            let result = (|| {
                let library = context.library_mut()?;
                removed_ids = library
                    .all_assets(true)
                    .into_iter()
                    .map(|asset| asset.id)
                    .collect();
                library.empty_trash()?;
                Ok(())
            })();
            (removed_ids, result)
        });
    complete_library_deletion(result, || emit_library_changed(&app))?;
    emit_notice_local(&app, "Trash Emptied".into(), "trash.slash".into());
    Ok(())
}

/// Parses a batch of asset ids (frontend sends a JSON array of uuids).
fn parse_ids(ids: &[String]) -> Result<Vec<uuid::Uuid>, String> {
    ids.iter()
        .map(|id| uuid::Uuid::parse_str(id).map_err(|e| e.to_string()))
        .collect()
}

#[tauri::command]
pub fn batch_move_to_trash(app: AppHandle, ids: Vec<String>) -> Result<(), String> {
    let parsed = parse_ids(&ids)?;
    {
        let state = app.state::<AppState>();
        let mut context = state.library.lock().unwrap();
        context
            .library_mut()
            .map_err(|error| error.to_string())?
            .batch_move_to_trash(&parsed)
            .map_err(|e| e.to_string())?;
    }
    emit_library_changed(&app);
    Ok(())
}

#[tauri::command]
pub fn batch_restore(app: AppHandle, ids: Vec<String>) -> Result<(), String> {
    let parsed = parse_ids(&ids)?;
    {
        let state = app.state::<AppState>();
        let mut context = state.library.lock().unwrap();
        context
            .library_mut()
            .map_err(|error| error.to_string())?
            .batch_restore(&parsed)
            .map_err(|e| e.to_string())?;
    }
    emit_library_changed(&app);
    Ok(())
}

#[tauri::command]
pub async fn batch_permanently_delete(app: AppHandle, ids: Vec<String>) -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(move || batch_permanently_delete_inner(app, ids))
        .await
        .map_err(|error| error.to_string())?
}

fn batch_permanently_delete_inner(app: AppHandle, ids: Vec<String>) -> Result<(), String> {
    let parsed = parse_ids(&ids)?;
    let state = app.state::<AppState>();
    let store = app.state::<crate::protocol::ProtocolStore>();
    let result: Result<(), LibraryLocationError> =
        crate::protocol::with_thumbnail_invalidations(&store, &parsed, || {
            let mut context = state.library.lock().unwrap();
            context.library_mut()?.batch_permanently_delete(&parsed)?;
            Ok(())
        });
    complete_library_deletion(result, || emit_library_changed(&app))
}

#[tauri::command]
pub fn batch_set_favorite(app: AppHandle, ids: Vec<String>, favorite: bool) -> Result<(), String> {
    let parsed = parse_ids(&ids)?;
    {
        let state = app.state::<AppState>();
        let mut context = state.library.lock().unwrap();
        context
            .library_mut()
            .map_err(|error| error.to_string())?
            .batch_set_favorite(favorite, &parsed)
            .map_err(|e| e.to_string())?;
    }
    emit_library_changed(&app);
    Ok(())
}

#[tauri::command]
pub fn copy_asset(app: AppHandle, window: WebviewWindow, id: String) -> Result<(), String> {
    let parsed = uuid::Uuid::parse_str(&id).map_err(|e| e.to_string())?;
    let state = app.state::<AppState>();
    let mut context = state.library.lock().unwrap();
    let (asset, path) = {
        let library = context.library().map_err(|error| error.to_string())?;
        let asset = library
            .asset_by_id(&parsed)
            .cloned()
            .ok_or_else(|| "The capture could not be found.".to_string())?;
        let path = library
            .readable_asset_url(&asset)
            .map_err(|error| error.to_string())?;
        (asset, path)
    };
    match asset.kind {
        CaptureKind::Image => {
            let data = std::fs::read(&path).map_err(|e| e.to_string())?;
            platform::write_image_to_clipboard(&data).map_err(|e| e.to_string())?;
        }
        CaptureKind::Video | CaptureKind::Gif => {
            platform::write_file_to_clipboard(&path).map_err(|e| e.to_string())?;
        }
    }
    drop(context);
    if window.label() != "toast" {
        emit_notice_local(
            &app,
            "Copied to Clipboard".into(),
            "checkmark.circle.fill".into(),
        );
    }
    Ok(())
}

/// Copy the saved file rather than its image pixels, for file-manager paste.
#[tauri::command]
pub fn copy_asset_file(app: AppHandle, id: String) -> Result<(), String> {
    let parsed = uuid::Uuid::parse_str(&id).map_err(|error| error.to_string())?;
    let state = app.state::<AppState>();
    let mut context = state.library.lock().unwrap();
    let path = {
        let library = context.library().map_err(|error| error.to_string())?;
        let asset = library.asset_by_id(&parsed)
            .ok_or_else(|| "The capture could not be found.".to_string())?;
        library.readable_asset_url(asset).map_err(|error| error.to_string())?
    };
    platform::write_file_to_clipboard(&path).map_err(|error| error.to_string())?;
    drop(context);
    emit_notice_local(&app, "Copied to Clipboard".into(), "checkmark.circle.fill".into());
    Ok(())
}

#[tauri::command]
pub fn open_asset(app: AppHandle, id: String) -> Result<(), String> {
    let parsed = uuid::Uuid::parse_str(&id).map_err(|e| e.to_string())?;
    let state = app.state::<AppState>();
    let mut context = state.library.lock().unwrap();
    let asset = context
        .library()
        .map_err(|error| error.to_string())?
        .asset_by_id(&parsed)
        .cloned()
        .ok_or_else(|| "The capture could not be found.".to_string())?;
    let (width, height) = (asset.pixel_width, asset.pixel_height);
    drop(context);

    // In-app viewer window (image preview / video player), Esc to close.
    let label = format!("viewer-{}", asset.id.to_string().to_lowercase());
    if let Some(window) = app.get_webview_window(&label) {
        let _ = window.show();
        let _ = window.set_focus();
        return Ok(());
    }
    // Size the window to the asset's aspect ratio (clamped), so an image
    // opens close to its natural shape without covering the screen.
    let aspect = if width > 0 && height > 0 {
        (width as f64 / height as f64).clamp(0.4, 2.6)
    } else {
        1.5
    };
    let win_h = 640.0f64;
    let win_w = (win_h * aspect).clamp(360.0, 1200.0);
    let asset_id = asset.id;
    let window_title = format!(
        "{} — Lumen",
        asset.title.as_deref().unwrap_or(&asset.filename)
    );
    std::thread::Builder::new()
        .name("kiri-open-viewer".into())
        .spawn(move || {
            // Windows WebView2 window creation dispatches through the main
            // event loop. Building it inside this synchronous IPC command
            // leaves the new native window white while the command owns that
            // same loop. Create it from a worker after the IPC can return.
            if let Some(window) = app.get_webview_window(&label) {
                let _ = window.show();
                let _ = window.set_focus();
                return;
            }
            match WebviewWindowBuilder::new(
                &app,
                label,
                WebviewUrl::App(format!("index.html?window=viewer&id={asset_id}").into()),
            )
            .title(window_title)
            .inner_size(win_w, win_h)
            .resizable(true)
            .shadow(true)
            .decorations(true)
            .build()
            {
                Ok(_) => log::info!("[viewer] window opened asset_id={asset_id}"),
                Err(error) => {
                    log::error!("[viewer] window creation failed asset_id={asset_id}: {error}")
                }
            }
        })
        .map_err(|error| format!("The preview could not be opened: {error}"))?;
    Ok(())
}

fn restore_editor_window(window: &WebviewWindow) -> Result<(), String> {
    window.show().and_then(|_| window.unminimize()).and_then(|_| window.set_focus())
        .map_err(|error| format!("The screenshot window could not be restored: {error}"))
}

#[cfg(not(windows))]
fn restore_pinned_window(app: &AppHandle, window: &WebviewWindow) -> Result<(), String> {
    window.set_always_on_top(true)
        .map_err(|error| format!("The screenshot could not be pinned: {error}"))?;
    // Tao posts that request to the window thread; assert the band here so the
    // reused pin is already above other applications when the UI flips.
    platform::assert_window_topmost(window)
        .map_err(|error| format!("The screenshot could not be pinned: {error}"))?;
    platform::ensure_pin_topmost_guard(app);
    // Tell a reused WebView to reflect its restored native pin state.
    let _ = window.emit_to(window.label(), "pin-on-top", ());
    restore_editor_window(window)
}

/// Keeps a pinned screenshot above other applications.
///
/// The pin window is created topmost, but two situations still need this
/// command: `set_always_on_top(true)` is a no-op once Tao already wants the
/// band, so clicking a pin could not raise it above a sibling pin, and a pin
/// that dropped out of the band needs a synchronous, verified re-assert.
#[tauri::command]
pub fn set_pin_topmost(window: WebviewWindow, on_top: bool) -> Result<(), String> {
    if !window.label().starts_with(platform::PIN_WINDOW_LABEL_PREFIX) {
        return Err("Only pinned screenshots can change their topmost state.".into());
    }
    window.set_always_on_top(on_top)
        .map_err(|error| format!("The screenshot could not change its pinning: {error}"))?;
    if on_top {
        platform::assert_window_topmost(&window)
            .map_err(|error| format!("The screenshot could not be pinned: {error}"))?;
    } else {
        // Tao applies the unpin asynchronously and ignores a failed transition.
        // Make the native band match the UI before this command returns.
        platform::release_window_topmost(&window)
            .map_err(|error| format!("The screenshot could not change its pinning: {error}"))?;
    }
    platform::ensure_pin_topmost_guard(window.app_handle());
    Ok(())
}

/// Raises a pin within the topmost band when the user points at it.
#[tauri::command]
pub fn raise_pin(window: WebviewWindow) -> Result<(), String> {
    if !window.label().starts_with(platform::PIN_WINDOW_LABEL_PREFIX) {
        return Ok(());
    }
    // A pin the user explicitly unpinned must stay behind other windows.
    if !window.is_always_on_top().unwrap_or(false) {
        return Ok(());
    }
    platform::assert_window_topmost(&window)
        .map_err(|error| format!("The screenshot could not be raised: {error}"))
}

/// Physical size a pin reports after one zoom step.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct PinZoomSize {
    pub width: u32,
    pub height: u32,
}

/// Scales a pinned screenshot around the pointer that scrolled it.
///
/// Zoom is a view of the same image, so the native side owns the geometry and
/// returns the frame it actually applied; the WebView only turns that size into
/// the percentage it shows while scrolling. `image_width`/`image_height` are the
/// pin's intrinsic pixels, which keep the resized window on the image aspect
/// ratio instead of accumulating rounding drift over many steps.
#[tauri::command]
pub fn zoom_pin(
    window: WebviewWindow,
    factor: f64,
    anchor_x: f64,
    anchor_y: f64,
    image_width: u32,
    image_height: u32,
) -> Result<PinZoomSize, String> {
    if !window.label().starts_with(platform::PIN_WINDOW_LABEL_PREFIX) {
        return Err("Only pinned screenshots can zoom.".into());
    }
    let aspect = (image_width > 0 && image_height > 0)
        .then(|| f64::from(image_width) / f64::from(image_height));
    let (width, height) =
        platform::zoom_pinned_window(&window, factor, (anchor_x, anchor_y), aspect)
            .map_err(|error| format!("The screenshot could not be zoomed: {error}"))?;
    Ok(PinZoomSize { width, height })
}

#[tauri::command]
pub async fn pin_asset(window: WebviewWindow, app: AppHandle, id: String) -> Result<(), String> {
    if !matches!(window.label(), "library" | "toast")
        && !window.label().starts_with("editor-")
        && !window.label().starts_with("viewer-")
    {
        return Err("Only the library, editor, or completion preview can pin a screenshot.".into());
    }
    open_pinned_screenshot(app, id).await
}

async fn open_pinned_screenshot(app: AppHandle, id: String) -> Result<(), String> {
    #[cfg(windows)]
    {
        // Windows pins are native layered windows: no WebView, no focus change,
        // and no per-pin renderer process. The WebView pin stays the fallback on
        // other platforms.
        open_native_pinned_screenshot(app, id).await
    }
    #[cfg(not(windows))]
    {
        open_webview_pinned_screenshot(app, id).await
    }
}

/// Decodes a library capture into the premultiplied snapshot a pin owns.
///
/// Called from a blocking worker: reading a 4K PNG costs tens of milliseconds
/// and must not run on the message loop or a WebView IPC thread.
#[cfg(windows)]
fn decode_pinned_image(path: &Path) -> Result<crate::pin::PinImage, String> {
    let decoded = image::open(path)
        .map_err(|error| format!("The pinned screenshot could not be read: {error}"))?;
    let rgba = decoded.to_rgba8();
    crate::pin::PinImage::from_rgba(rgba.width(), rgba.height(), rgba.as_raw())
        .ok_or_else(|| "The pinned screenshot could not be read.".to_string())
}

/// Display scale and physical work area under the pointer.
#[cfg(windows)]
fn native_pin_target(app: &AppHandle) -> Result<(f64, crate::pin::PinRect), String> {
    let cursor = app
        .cursor_position()
        .map_err(|error| format!("The pinned screenshot could not be placed: {error}"))?;
    let monitor = app
        .monitor_from_point(cursor.x, cursor.y)
        .ok()
        .flatten()
        .or_else(|| app.primary_monitor().ok().flatten())
        .ok_or_else(|| "The pinned screenshot could not be placed.".to_string())?;
    let area = monitor.work_area();
    Ok((
        monitor.scale_factor().max(1.0),
        crate::pin::PinRect::new(
            area.position.x,
            area.position.y,
            area.size.width.max(1) as i32,
            area.size.height.max(1) as i32,
        ),
    ))
}

#[cfg(windows)]
async fn open_native_pinned_screenshot(app: AppHandle, id: String) -> Result<(), String> {
    let parsed = uuid::Uuid::parse_str(&id).map_err(|_| "Invalid screenshot.".to_string())?;
    let (path, asset_id, placement, monitors) = {
        let state = app.state::<AppState>();
        let mut context = state.library.lock().unwrap();
        let library = context.library().map_err(|error| error.to_string())?;
        let asset = library
            .asset_by_id(&parsed)
            .cloned()
            .ok_or_else(|| "Screenshot not found.".to_string())?;
        if asset.kind != CaptureKind::Image || asset.trashed_at.is_some() {
            return Err("Only active screenshots can be pinned.".into());
        }
        let path = library.readable_asset_url(&asset).map_err(|error| error.to_string())?;
        let placements = state.capture_pin_placements.lock().unwrap();
        let placement = placements.get(asset.id, (asset.pixel_width, asset.pixel_height));
        drop(placements);
        let monitors = app.available_monitors().unwrap_or_default();
        (path, asset.id, placement, monitors)
    };

    let image = tauri::async_runtime::spawn_blocking(move || decode_pinned_image(&path))
        .await
        .map_err(|error| format!("The pinned screenshot could not be read: {error}"))??;

    let (scale, workarea) = native_pin_target(&app)?;
    let cursor = app.cursor_position().unwrap_or(tauri::PhysicalPosition::new(0.0, 0.0));
    // Reuse the capture's on-screen origin only while that rectangle still
    // belongs to a connected display at the same scale.
    let placement_source = placement.filter(|origin| {
        monitors.iter().any(|monitor| {
            origin.fits_monitor(
                Rect::new(
                    f64::from(monitor.position().x),
                    f64::from(monitor.position().y),
                    f64::from(monitor.size().width),
                    f64::from(monitor.size().height),
                ),
                monitor.scale_factor(),
            )
        })
    });
    let frame = match placement_source {
        Some(origin) => crate::pin::PinRect::from_logical(origin.frame, origin.backing_scale),
        None => crate::pin::initial_frame(
            (image.width, image.height),
            (f64::from(cursor.x), f64::from(cursor.y)),
            workarea,
            0,
        ),
    };
    crate::pin::surface::open(
        &app,
        crate::pin::surface::PinSpec {
            image,
            frame,
            scale,
            origin: crate::pin::PinOrigin::Asset(asset_id),
        },
    )
    .map_err(|error| error.to_string())?;
    log::info!("[pin] screenshot opened native asset_id={asset_id}");
    Ok(())
}

#[cfg(not(windows))]
async fn open_webview_pinned_screenshot(app: AppHandle, id: String) -> Result<(), String> {
    let parsed = uuid::Uuid::parse_str(&id).map_err(|_| "Invalid screenshot.".to_string())?;
    let asset = {
        let state = app.state::<AppState>();
        let mut context = state.library.lock().unwrap();
        let library = context.library().map_err(|error| error.to_string())?;
        let asset = library.asset_by_id(&parsed).cloned()
            .ok_or_else(|| "Screenshot not found.".to_string())?;
        if asset.kind != CaptureKind::Image || asset.trashed_at.is_some() {
            return Err("Only active screenshots can be pinned.".into());
        }
        library.readable_asset_url(&asset).map_err(|error| error.to_string())?;
        asset
    };
    let label = format!("{}{}", platform::PIN_WINDOW_LABEL_PREFIX, asset.id.to_string().to_lowercase());
    if let Some(window) = app.get_webview_window(&label) {
        restore_pinned_window(&app, &window)?;
        return Ok(());
    }
    let source_width = asset.pixel_width.max(1) as f64;
    let source_height = asset.pixel_height.max(1) as f64;
    let scale = (680.0 / source_width).min(480.0 / source_height).min(1.0);
    let origin = {
        let state = app.state::<AppState>();
        let placements = state.capture_pin_placements.lock().unwrap();
        placements.get(asset.id, (asset.pixel_width, asset.pixel_height))
    };
    // A native monitor query may dispatch to the event loop. Never retain
    // the origin mutex while waiting on that loop's capture confirmations.
    let placement = origin.filter(|origin| app.available_monitors().is_ok_and(|monitors| monitors.iter().any(|monitor| {
            origin.fits_monitor(Rect::new(f64::from(monitor.position().x), f64::from(monitor.position().y),
                f64::from(monitor.size().width), f64::from(monitor.size().height)), monitor.scale_factor())
        })));
    let (width, height) = placement.map(|origin| (origin.frame.width, origin.frame.height))
        .unwrap_or(((source_width * scale).max(80.0), (source_height * scale).max(60.0)));
    let asset_id = asset.id;
    tauri::async_runtime::spawn_blocking(move || {
        if let Some(window) = app.get_webview_window(&label) {
            restore_pinned_window(&app, &window)?; return Ok(());
        }
        let builder = WebviewWindowBuilder::new(&app, label,
            WebviewUrl::App(format!("index.html?window=pin&id={asset_id}").into()))
            .title("Pinned Screenshot — Lumen")
            .inner_size(width, height)
            .min_inner_size(80.0, 60.0)
            // GTK needs resizable windows for both native and programmatic
            // sizing; Linux installs fixed-aspect geometry hints before mapping.
            // Other platforms keep native edges from bypassing the web grip.
            .resizable(cfg!(target_os = "linux"))
            .decorations(false)
            .transparent(true)
            .shadow(false)
            .always_on_top(true)
            .visible(false);
        let builder = if let Some(origin) = placement {
            builder.position(origin.frame.x, origin.frame.y)
        } else { builder };
        let window = builder.build()
            .map_err(|error| format!("Pinned screenshot could not be opened: {error}"))?;
        if let Some(origin) = placement {
            // Windows requires physical coordinates after creation to avoid
            // Tao choosing a different monitor's DPI for logical positions.
            if let Err(error) = platform::place_transient_window(&window, origin.frame, origin.backing_scale) {
                let _ = window.close();
                return Err(format!("Pinned screenshot could not be positioned: {error}"));
            }
        }
        #[cfg(target_os = "linux")]
        if let Err(error) = platform::linux::show_pinned_screenshot(&window, width, height) {
            let _ = window.close();
            return Err(format!("Pinned screenshot could not be opened: {error:#}"));
        }
        #[cfg(not(target_os = "linux"))]
        if let Err(error) = window.show().and_then(|_| window.set_focus()) {
            let _ = window.close();
            return Err(format!("Pinned screenshot could not be shown: {error}"));
        }
        // The builder already asked for the topmost band, but that request is
        // applied asynchronously. Assert it now so the pin is above other
        // applications from its first visible frame, and keep the self-heal
        // running for as long as any pin exists. A pin that is merely not
        // verifiably on top must not fail the whole action.
        if let Err(error) = platform::assert_window_topmost(&window) {
            log::warn!("[pin] topmost band could not be asserted asset_id={asset_id}: {error}");
        }
        platform::ensure_pin_topmost_guard(&app);
        log::info!("[pin] screenshot opened asset_id={asset_id}");
        Ok(())
    }).await.map_err(|error| format!("Pinned screenshot window stopped: {error}"))?
}

/// Pastes the clipboard as pins: an image, copied image files, or text.
///
/// This is the F3 action. It creates the same native pins as the screenshot
/// toolbar, centred on the pointer and cascaded, and never writes the content
/// to the library or to disk.
#[tauri::command]
pub async fn paste_as_pin(app: AppHandle) -> Result<usize, String> {
    paste_as_pin_impl(app).await
}

#[cfg(windows)]
async fn paste_as_pin_impl(app: AppHandle) -> Result<usize, String> {
    let (scale, workarea) = native_pin_target(&app)?;
    let cursor = app
        .cursor_position()
        .map_err(|error| format!("The pinned image could not be placed: {error}"))?;
    let (budget, cascade) = {
        let state = app.state::<AppState>();
        let pins = state.pins.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        (
            crate::pin::MAX_PIN_SOURCE_BYTES.saturating_sub(pins.source_bytes()),
            pins.len(),
        )
    };
    let sources = tauri::async_runtime::spawn_blocking(move || {
        crate::pin::clipboard::read_sources(scale, budget)
    })
    .await
    .map_err(|error| format!("The clipboard could not be read: {error}"))??;

    // A burst is atomic: refuse it up front instead of opening half of it and
    // then failing on the pin that no longer fits.
    let source_total = sources
        .iter()
        .fold(0u64, |total, source| total.saturating_add(source.image.bytes()));
    if sources.len() > crate::pin::MAX_PINS.saturating_sub(cascade) || source_total > budget {
        return Err("Close a pinned image before pinning another.".into());
    }

    let mut opened = 0usize;
    for (index, source) in sources.into_iter().enumerate() {
        let frame = crate::pin::initial_frame(
            (source.image.width, source.image.height),
            (f64::from(cursor.x), f64::from(cursor.y)),
            workarea,
            cascade + index,
        );
        crate::pin::surface::open(
            &app,
            crate::pin::surface::PinSpec {
                image: source.image,
                frame,
                scale,
                origin: crate::pin::PinOrigin::Clipboard,
            },
        )
        .map_err(|error| error.to_string())?;
        opened += 1;
    }
    log::info!("[pin] clipboard paste opened {opened} pin(s)");
    Ok(opened)
}

#[cfg(not(windows))]
async fn paste_as_pin_impl(_app: AppHandle) -> Result<usize, String> {
    Err("Pinned images are only available on Windows.".into())
}

#[tauri::command]
pub fn open_editor(app: AppHandle, id: String, recognize_qr: Option<bool>) -> Result<(), String> {
    let recognize_qr = recognize_qr.unwrap_or(false);
    let parsed =
        uuid::Uuid::parse_str(&id).map_err(|_| "The capture id is invalid.".to_string())?;
    let state = app.state::<AppState>();
    let mut context = state.library.lock().unwrap();
    let asset = context
        .library()
        .map_err(|error| error.to_string())?
        .asset_by_id(&parsed)
        .cloned()
        .ok_or_else(|| "The capture could not be found.".to_string())?;
    if asset.kind != CaptureKind::Image {
        return Err("Only image captures can be edited.".into());
    }
    drop(context);

    let label = format!("editor-{}", asset.id.to_string().to_lowercase());
    if let Some(window) = app.get_webview_window(&label) {
        restore_editor_window(&window)?;
        if recognize_qr {
            queue_editor_qr(&window, &app)?;
        }
        return Ok(());
    }
    let asset_id = asset.id;
    std::thread::Builder::new()
        .name("kiri-open-editor".into())
        .spawn(move || {
            // See open_asset: secondary WebViews must not be constructed from
            // the synchronous IPC handler on Windows.
            if let Some(window) = app.get_webview_window(&label) {
                if let Err(error) = restore_editor_window(&window) {
                    log::error!("[editor] window restore failed asset_id={asset_id}: {error}");
                    return;
                }
                if recognize_qr {
                    if let Err(error) = queue_editor_qr(&window, &app) {
                        log::error!("[editor] QR request failed asset_id={asset_id}: {error}");
                    }
                }
                return;
            }
            let qr_query = if recognize_qr { "&qr=1" } else { "" };
            match WebviewWindowBuilder::new(
                &app,
                label,
                WebviewUrl::App(format!("index.html?window=editor&id={asset_id}{qr_query}").into()),
            )
            .title("Lumen")
            .inner_size(880.0, 620.0)
            .min_inner_size(520.0, 420.0)
            .resizable(true)
            .shadow(true)
            .decorations(true)
            .build()
            {
                Ok(_) => log::info!("[editor] window opened asset_id={asset_id}"),
                Err(error) => {
                    // Another opener can win after our reuse check. Deliver
                    // this QR intent to that window without replacing its draft.
                    if recognize_qr {
                        if let Some(window) = app.get_webview_window(&format!("editor-{asset_id}")) {
                            if queue_editor_qr(&window, &app).is_ok() {
                                return;
                            }
                        }
                    }
                    log::error!("[editor] window creation failed asset_id={asset_id}: {error}")
                }
            }
        })
        .map_err(|error| format!("The screenshot editor could not be opened: {error}"))?;
    Ok(())
}

fn queue_editor_qr(window: &WebviewWindow, app: &AppHandle) -> Result<(), String> {
    app.state::<AppState>()
        .editor_qr_requests
        .lock()
        .unwrap()
        .insert(window.label().to_string());
    window
        .emit_to(window.label(), "editor-recognize-qr", ())
        .map_err(|_| "QR recognition failed.".to_string())
}

#[tauri::command]
pub fn take_editor_qr_request(window: WebviewWindow, app: AppHandle) -> Result<bool, String> {
    editor_window_id(&window)?;
    let state = app.state::<AppState>();
    let requested = state.editor_qr_requests.lock().unwrap().remove(window.label());
    Ok(requested)
}

#[tauri::command]
pub fn get_asset(app: AppHandle, id: String) -> Result<AssetDto, String> {
    let parsed = uuid::Uuid::parse_str(&id).map_err(|e| e.to_string())?;
    let state = app.state::<AppState>();
    let mut context = state.library.lock().unwrap();
    let library = context.library().map_err(|error| error.to_string())?;
    let asset = library
        .asset_by_id(&parsed)
        .cloned()
        .ok_or_else(|| "The capture could not be found.".to_string())?;
    Ok(asset_dto(&asset))
}

#[tauri::command]
pub async fn reveal_asset(app: AppHandle, id: String) -> Result<(), String> {
    let parsed = uuid::Uuid::parse_str(&id).map_err(|e| e.to_string())?;
    let state = app.state::<AppState>();
    let path = {
        let mut context = state.library.lock().unwrap();
        let library = context.library().map_err(|error| error.to_string())?;
        let asset = library
            .asset_by_id(&parsed)
            .cloned()
            .ok_or_else(|| "The capture could not be found.".to_string())?;
        library
            .readable_asset_url(&asset)
            .map_err(|error| error.to_string())?
    };
    reveal_path_async(path).await
}

async fn reveal_path_async(path: PathBuf) -> Result<(), String> {
    #[cfg(windows)]
    { tauri::async_runtime::spawn_blocking(move || platform::reveal_path(&path).map_err(|error| error.to_string()))
        .await.map_err(|error| error.to_string())? }
    #[cfg(not(windows))]
    { platform::reveal_path(&path).map_err(|error| error.to_string()) }
}

#[tauri::command]
pub fn get_library_status(app: AppHandle) -> LibraryStatusDto {
    let state = app.state::<AppState>();
    let status = state.library.lock().unwrap().status();
    status.into()
}

#[tauri::command]
pub fn get_asset_availability(app: AppHandle, id: String) -> Result<AssetAvailabilityDto, String> {
    let parsed = uuid::Uuid::parse_str(&id).map_err(|error| error.to_string())?;
    let state = app.state::<AppState>();
    let mut context = state.library.lock().unwrap();
    let status = match context.library() {
        Ok(library) => match library
            .asset_availability(&parsed)
            .map_err(|error| error.to_string())?
        {
            crate::core::library::AssetAvailability::Ready => "ready",
            crate::core::library::AssetAvailability::Missing => "missing",
            crate::core::library::AssetAvailability::Unreadable => "unreadable",
        },
        Err(LibraryLocationError::Unavailable | LibraryLocationError::Migrating) => {
            "libraryUnavailable"
        }
        Err(error) => return Err(error.to_string()),
    };
    Ok(AssetAvailabilityDto { status })
}

#[tauri::command]
pub async fn reveal_library(app: AppHandle) -> Result<(), String> {
    let state = app.state::<AppState>();
    let root = {
        let mut context = state.library.lock().unwrap();
        context.library().map_err(|error| error.to_string())?;
        context.root().to_path_buf()
    };
    reveal_path_async(root).await
}

#[tauri::command]
pub fn retry_library(app: AppHandle) -> Result<LibraryStatusDto, String> {
    let state = app.state::<AppState>();
    let mut context = state.library.lock().unwrap();
    context.retry().map_err(|error| error.to_string())?;
    let status = context.status().into();
    drop(context);
    crate::protocol::clear_thumbnails(&app.state::<crate::protocol::ProtocolStore>());
    emit_library_changed(&app);
    Ok(status)
}

async fn pick_library_folder(app: &AppHandle) -> Result<Option<PathBuf>, String> {
    use tauri_plugin_dialog::DialogExt;
    let dialog_app = app.clone();
    tauri::async_runtime::spawn_blocking(move || {
        dialog_app
            .dialog()
            .file()
            .blocking_pick_folder()
            .and_then(|path| path.into_path().ok())
    })
    .await
    .map_err(|error| format!("Could not open the folder picker: {error}"))
}

fn ensure_library_location_change_idle(app: &AppHandle) -> Result<(), String> {
    let state = app.state::<AppState>();
    if state.capture.lock().unwrap().session.is_some() || state.scroll_capture.is_active() {
        return Err("Finish the current capture before moving the library.".into());
    }
    let recording = state.recording.lock().unwrap();
    if recording.is_starting
        || recording.is_recording
        || recording.is_paused
        || recording.is_transitioning
        || recording.is_finalizing
    {
        return Err("Finish the current recording before moving the library.".into());
    }
    Ok(())
}

async fn migrate_active_library(
    app: &AppHandle,
    target_root: PathBuf,
    replace_same_library: bool,
) -> Result<LibraryStatusDto, String> {
    let state = app.state::<AppState>();
    let transition = state.library_transition.lock().unwrap();
    ensure_library_location_change_idle(app)?;
    let source = {
        let mut context = state.library.lock().unwrap();
        if context.root_matches(&target_root) {
            context.retry().map_err(|error| error.to_string())?;
            return Ok(context.status().into());
        }
        context
            .begin_migration()
            .map_err(|error| error.to_string())?
    };
    drop(transition);
    emit_library_changed(app);
    let prepared = tauri::async_runtime::spawn_blocking(move || {
        library_location::migrate_library(&source, &target_root, replace_same_library)
    })
    .await;
    let state = app.state::<AppState>();
    let mut context = state.library.lock().unwrap();
    match prepared {
        Ok(Ok(prepared)) => {
            context
                .activate_prepared(prepared)
                .map_err(|error| error.to_string())?;
            let status = context.status().into();
            drop(context);
            crate::protocol::clear_thumbnails(&app.state::<crate::protocol::ProtocolStore>());
            emit_library_changed(app);
            Ok(status)
        }
        Ok(Err(error)) => {
            context.cancel_migration();
            drop(context);
            emit_library_changed(app);
            Err(error.to_string())
        }
        Err(error) => {
            context.cancel_migration();
            drop(context);
            emit_library_changed(app);
            Err(format!("The library move did not finish: {error}"))
        }
    }
}

#[tauri::command]
pub async fn choose_library_location(app: AppHandle) -> Result<LibraryStatusDto, String> {
    let Some(container) = pick_library_folder(&app).await? else {
        return Ok(get_library_status(app));
    };
    let target = library_location::target_root_for_container(&container)
        .map_err(|error| error.to_string())?;
    if target.exists() {
        let availability = {
            let state = app.state::<AppState>();
            let availability = state.library.lock().unwrap().status().availability;
            availability
        };
        match availability {
            LibraryAvailability::Ready => migrate_active_library(&app, target, true).await,
            LibraryAvailability::Unavailable => switch_to_existing_library(&app, target).await,
            LibraryAvailability::Migrating => Err("library storage is being moved".into()),
        }
    } else {
        migrate_active_library(&app, target, false).await
    }
}

#[tauri::command]
pub async fn restore_default_library(app: AppHandle) -> Result<LibraryStatusDto, String> {
    let (target, availability) = {
        let state = app.state::<AppState>();
        let mut context = state.library.lock().unwrap();
        if context.is_default() {
            context.retry().map_err(|error| error.to_string())?;
            return Ok(context.status().into());
        }
        (
            context.default_root().to_path_buf(),
            context.status().availability,
        )
    };
    match availability {
        LibraryAvailability::Ready => migrate_active_library(&app, target, true).await,
        LibraryAvailability::Unavailable => {
            Err("Reconnect the library before restoring the default location.".into())
        }
        LibraryAvailability::Migrating => Err("library storage is being moved".into()),
    }
}

#[tauri::command]
pub async fn locate_library(app: AppHandle) -> Result<LibraryStatusDto, String> {
    let Some(selected) = pick_library_folder(&app).await? else {
        return Ok(get_library_status(app));
    };
    switch_to_existing_library(&app, selected).await
}

async fn switch_to_existing_library(
    app: &AppHandle,
    selected: PathBuf,
) -> Result<LibraryStatusDto, String> {
    let state = app.state::<AppState>();
    let transition = state.library_transition.lock().unwrap();
    ensure_library_location_change_idle(app)?;
    let (expected_id, expected_generation, expected_root) = {
        let mut context = state.library.lock().unwrap();
        if context.status().availability != LibraryAvailability::Unavailable {
            return Err("Locate is available only while the library is unavailable.".into());
        }
        if context.root_matches(&selected) {
            context.retry().map_err(|error| error.to_string())?;
            return Ok(context.status().into());
        }
        context
            .begin_locating()
            .map_err(|error| error.to_string())?;
        (
            context.expected_library_id(),
            context.expected_library_generation(),
            context.root().to_path_buf(),
        )
    };
    drop(transition);
    emit_library_changed(app);
    let prepared = tauri::async_runtime::spawn_blocking(move || {
        library_location::prepare_existing_location(
            &selected,
            expected_id,
            expected_generation,
            &expected_root,
        )
    })
    .await;
    let state = app.state::<AppState>();
    let mut context = state.library.lock().unwrap();
    match prepared {
        Ok(Ok(prepared)) => {
            context
                .activate_prepared(prepared)
                .map_err(|error| error.to_string())?;
            let status = context.status().into();
            drop(context);
            crate::protocol::clear_thumbnails(&app.state::<crate::protocol::ProtocolStore>());
            emit_library_changed(app);
            Ok(status)
        }
        Ok(Err(error)) => {
            context.cancel_locating();
            drop(context);
            emit_library_changed(app);
            Err(error.to_string())
        }
        Err(error) => {
            context.cancel_locating();
            drop(context);
            emit_library_changed(app);
            Err(format!(
                "The selected library could not be checked: {error}"
            ))
        }
    }
}

#[tauri::command]
pub async fn restore_missing_asset(app: AppHandle, id: String) -> Result<bool, String> {
    use tauri_plugin_dialog::DialogExt;
    let parsed = uuid::Uuid::parse_str(&id).map_err(|error| error.to_string())?;
    let (filter_label, extension, expected_asset) = {
        let state = app.state::<AppState>();
        let mut context = state.library.lock().unwrap();
        let library = context.library().map_err(|error| error.to_string())?;
        let asset = library
            .asset_by_id(&parsed)
            .cloned()
            .ok_or_else(|| "The capture could not be found.".to_string())?;
        if library
            .asset_availability(&parsed)
            .map_err(|error| error.to_string())?
            != crate::core::library::AssetAvailability::Missing
        {
            return Err("The capture file is not missing.".into());
        }
        let extension = crate::core::library::replacement_file_extension(&asset)
            .map_err(|error| error.to_string())?;
        let label = match asset.kind {
            CaptureKind::Image => "PNG image",
            CaptureKind::Video if extension == "mov" => "MOV video",
            CaptureKind::Video => "MP4 video",
            CaptureKind::Gif => "GIF image",
        };
        (label, extension, asset)
    };
    let dialog_app = app.clone();
    let selected = tauri::async_runtime::spawn_blocking(move || {
        dialog_app
            .dialog()
            .file()
            .add_filter(filter_label, &[extension])
            .blocking_pick_file()
            .and_then(|path| path.into_path().ok())
    })
    .await
    .map_err(|error| format!("Could not open the file picker: {error}"))?;
    let Some(selected) = selected else {
        return Ok(false);
    };
    let validation_path = selected.clone();
    let validation_asset = expected_asset.clone();
    let proof = tauri::async_runtime::spawn_blocking(move || {
        let proof =
            crate::core::library::replacement_file_proof(&validation_path, &validation_asset)
                .map_err(|error| error.to_string())?;
        validate_replacement_metadata(&validation_asset, &validation_path)?;
        Ok::<_, String>(proof)
    })
    .await
    .map_err(|error| format!("Could not validate the selected file: {error}"))??;
    let state = app.state::<AppState>();
    let mut context = state.library.lock().unwrap();
    context
        .library_mut()
        .map_err(|error| error.to_string())?
        .restore_missing_asset(&parsed, &selected, &proof)
        .map_err(|error| error.to_string())?;
    drop(context);
    crate::protocol::clear_thumbnail(&app.state::<crate::protocol::ProtocolStore>(), parsed);
    emit_asset_content_changed(&app, &parsed);
    emit_library_changed(&app);
    Ok(true)
}

fn validate_replacement_metadata(asset: &CaptureAsset, path: &Path) -> Result<(), String> {
    let (pixel_width, pixel_height, duration) = match asset.kind {
        CaptureKind::Image => {
            let reader = image::ImageReader::open(path)
                .map_err(|_| "The selected PNG could not be read.".to_string())?
                .with_guessed_format()
                .map_err(|_| "The selected PNG could not be read.".to_string())?;
            if reader.format() != Some(image::ImageFormat::Png) {
                return Err("The selected file is not a PNG image.".into());
            }
            let decoded = reader
                .decode()
                .map_err(|_| "The selected PNG is invalid.".to_string())?;
            (
                i64::from(decoded.width()),
                i64::from(decoded.height()),
                None,
            )
        }
        #[cfg(windows)]
        CaptureKind::Video => {
            let (width, height) = crate::gif::video_dimensions(path)
                .map_err(|_| "The selected video file is invalid.".to_string())?;
            (i64::from(width), i64::from(height), asset.duration)
        }
        #[cfg(any(windows, target_os = "macos", target_os = "linux"))]
        CaptureKind::Gif => {
            let reader = image::ImageReader::open(path)
                .map_err(|_| "The selected GIF could not be read.".to_string())?
                .with_guessed_format()
                .map_err(|_| "The selected GIF could not be read.".to_string())?;
            if reader.format() != Some(image::ImageFormat::Gif) {
                return Err("The selected file is not a GIF image.".into());
            }
            let decoded = reader
                .decode()
                .map_err(|_| "The selected GIF is invalid.".to_string())?;
            (
                i64::from(decoded.width()),
                i64::from(decoded.height()),
                asset.duration,
            )
        }
        #[cfg(any(target_os = "macos", target_os = "linux"))]
        CaptureKind::Video => crate::record::probe_video_native(path)
            .ok_or_else(|| "The selected media file is invalid.".to_string())?,
    };
    if (asset.pixel_width > 0 && pixel_width != asset.pixel_width)
        || (asset.pixel_height > 0 && pixel_height != asset.pixel_height)
        || asset
            .duration
            .is_some_and(|expected| duration.is_none_or(|actual| (actual - expected).abs() > 0.25))
    {
        return Err("The selected file does not match this library item.".into());
    }
    Ok(())
}

#[tauri::command]
pub fn remove_missing_asset(app: AppHandle, id: String) -> Result<(), String> {
    let parsed = uuid::Uuid::parse_str(&id).map_err(|error| error.to_string())?;
    let state = app.state::<AppState>();
    let store = app.state::<crate::protocol::ProtocolStore>();
    let result = crate::protocol::with_thumbnail_invalidation(&store, parsed, || {
        let mut context = state.library.lock().unwrap();
        context.library_mut()?.remove_missing_asset(&parsed)?;
        Ok(())
    });
    complete_library_deletion(result, || emit_library_changed(&app))
}

#[tauri::command]
pub async fn list_pending_recordings(app: AppHandle) -> Result<Vec<PendingRecordingDto>, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let state = app.state::<AppState>();
        let Ok(_transition) = state.recording_recovery_transition.try_lock() else {
            return Ok(Vec::new());
        };
        let pending = state.recording_recovery.lock().unwrap().list();
        Ok(pending
            .into_iter()
            .map(|pending| PendingRecordingDto {
                id: pending.id.to_string(),
                created_at: pending.created_at,
            })
            .collect())
    })
    .await
    .map_err(|error| format!("Could not check pending recordings: {error}"))?
}

#[tauri::command]
pub fn get_recording_save_jobs(app: AppHandle) -> Vec<RecordingSaveJobDto> {
    app.state::<AppState>().recording_save_jobs.lock().unwrap().snapshot()
}

#[tauri::command]
pub async fn retry_pending_recordings(app: AppHandle) -> Result<usize, String> {
    tauri::async_runtime::spawn_blocking(move || retry_pending_recordings_inner(&app))
        .await
        .map_err(|error| format!("Could not retry pending recordings: {error}"))?
}

fn retry_pending_recordings_inner(app: &AppHandle) -> Result<usize, String> {
    let state = app.state::<AppState>();
    let _transition = state
        .recording_recovery_transition
        .try_lock()
        .map_err(|_| "A recording is still being saved.".to_string())?;
    let pending_items = state.recording_recovery.lock().unwrap().list();
    if pending_items.is_empty() {
        return Ok(0);
    }

    let mut imported_count = 0;
    let mut completed_count = 0;
    let mut first_error = None;
    for mut pending in pending_items {
        let result = (|| -> Result<bool, String> {
            let video_path = state
                .recording_recovery
                .lock()
                .unwrap()
                .validate_video(&pending)
                .map_err(|error| error.to_string())?;
            let asset_state = {
                let store = state.recording_recovery.lock().unwrap();
                recovery_asset_state(&state, &store, &pending)?
            };
            match asset_state {
                RecoveryAssetState::Matching => {
                    cleanup_verified_recovery(&state, &mut pending)?;
                    return Ok(false);
                }
                RecoveryAssetState::Conflict => {
                    return Err(
                        "The active library contains a different item with this recording id."
                            .into(),
                    )
                }
                RecoveryAssetState::Absent | RecoveryAssetState::RestorableVideo => {}
            }

            state
                .recording_recovery
                .lock()
                .unwrap()
                .prepare_import(&mut pending, CaptureKind::Video, &video_path)
                .map_err(|error| error.to_string())?;
            #[cfg(windows)]
            let (pixel_width, pixel_height, duration) = {
                let (width, height) =
                    crate::gif::video_dimensions(&video_path).map_err(|error| error.to_string())?;
                (i64::from(width), i64::from(height), pending.duration)
            };
            #[cfg(any(target_os = "macos", target_os = "linux"))]
            let (pixel_width, pixel_height, duration) =
                crate::record::probe_video_native(&video_path)
                    .ok_or_else(|| "The pending recording is not a valid MP4.".to_string())?;
            import_recovery_output(
                &state,
                &video_path,
                &pending,
                CaptureKind::Video,
                "mp4",
                pixel_width,
                pixel_height,
                duration.or(pending.duration),
            )?;
            cleanup_verified_recovery(&state, &mut pending)?;
            Ok(true)
        })();

        match result {
            Ok(imported) => {
                completed_count += 1;
                imported_count += usize::from(imported);
            }
            Err(error) => {
                log::error!("recording recovery {} failed: {error}", pending.id);
                if first_error.is_none() {
                    first_error = Some(error);
                }
            }
        }
    }

    if imported_count > 0 {
        emit_library_changed(app);
    }
    if completed_count == 0 {
        return Err(first_error.unwrap_or_else(|| "No recording could be recovered.".into()));
    }
    Ok(imported_count)
}

fn cleanup_verified_recovery(
    state: &AppState,
    pending: &mut PendingRecording,
) -> Result<(), String> {
    let store = state.recording_recovery.lock().unwrap();
    let mut context = state.library.lock().unwrap();
    let library = context.library().map_err(|error| error.to_string())?;
    store
        .finish_verified_import(library, pending)
        .map_err(|error| error.to_string())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RecoveryAssetState {
    Absent,
    RestorableVideo,
    Matching,
    Conflict,
}

fn recovery_asset_state(
    state: &AppState,
    store: &crate::core::recording_recovery::RecordingRecoveryStore,
    pending: &PendingRecording,
) -> Result<RecoveryAssetState, String> {
    let mut context = state.library.lock().unwrap();
    let library = context.library().map_err(|error| error.to_string())?;
    let Some(asset) = library.asset_by_id(&pending.id) else {
        return Ok(RecoveryAssetState::Absent);
    };
    match library
        .asset_availability(&asset.id)
        .map_err(|error| error.to_string())?
    {
        crate::core::library::AssetAvailability::Ready => {
            let path = library
                .readable_asset_url(asset)
                .map_err(|error| error.to_string())?;
            if store
                .imported_asset_matches(pending, asset, &path)
                .map_err(|error| error.to_string())?
            {
                Ok(RecoveryAssetState::Matching)
            } else {
                Ok(RecoveryAssetState::Conflict)
            }
        }
        crate::core::library::AssetAvailability::Missing
            if asset.kind == CaptureKind::Video
                && store
                    .recovery_matches_import_proof(pending)
                    .map_err(|error| error.to_string())? =>
        {
            Ok(RecoveryAssetState::RestorableVideo)
        }
        crate::core::library::AssetAvailability::Missing
        | crate::core::library::AssetAvailability::Unreadable => Ok(RecoveryAssetState::Conflict),
    }
}

// One owner-bound native export at a time bounds encoder and temporary disk
// pressure. Keep the entry until native cancellation has actually finished.
struct ActiveVideoExport {
    request_id: uuid::Uuid,
    owner: String,
    control: crate::video_export::ExportControl,
}
static VIDEO_EXPORT_JOB: std::sync::Mutex<Option<ActiveVideoExport>> = std::sync::Mutex::new(None);
struct VideoExportPermit(uuid::Uuid);
impl Drop for VideoExportPermit {
    fn drop(&mut self) {
        let mut job = VIDEO_EXPORT_JOB
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        if job.as_ref().is_some_and(|job| job.request_id == self.0) {
            *job = None;
        }
    }
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct VideoExportProgressDto {
    request_id: String,
    #[serde(flatten)]
    update: crate::video_export::ExportProgress,
}

#[tauri::command]
pub fn cancel_video_export(window: WebviewWindow, request_id: String) -> Result<bool, String> {
    let request_id = uuid::Uuid::parse_str(&request_id).map_err(|error| error.to_string())?;
    let job = VIDEO_EXPORT_JOB
        .lock()
        .unwrap_or_else(|error| error.into_inner());
    Ok(job
        .as_ref()
        .filter(|job| job.request_id == request_id && job.owner == window.label())
        .is_some_and(|job| job.control.request_cancel()))
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MediaImportResult {
    ids: Vec<String>,
    failed: usize,
}

#[tauri::command]
pub async fn import_media(
    app: AppHandle,
    window: WebviewWindow,
    paths: Option<Vec<String>>,
) -> Result<MediaImportResult, String> {
    use tauri_plugin_dialog::DialogExt;
    require_library_window(&window)?;
    let selected: Vec<PathBuf> = if let Some(paths) = paths {
        paths.into_iter().map(PathBuf::from).collect()
    } else {
        let dialog_app = app.clone();
        tauri::async_runtime::spawn_blocking(move || {
            dialog_app
                .dialog()
                .file()
                .add_filter("Videos", &["mp4", "mov"])
                .blocking_pick_files()
                .unwrap_or_default()
                .into_iter()
                .filter_map(|path| path.into_path().ok())
                .collect::<Vec<_>>()
        })
        .await
        .map_err(|e| e.to_string())?
    };
    if selected.len() > 32 {
        return Err("Import at most 32 files at a time".into());
    }
    let state = app.state::<AppState>();
    let (identity, generation) = {
        let context = state.library.lock().unwrap();
        (
            context.expected_library_id(),
            context.expected_library_generation(),
        )
    };
    tauri::async_runtime::spawn_blocking(move || {
        let mut result = MediaImportResult {
            ids: vec![],
            failed: 0,
        };
        for path in selected {
            let imported = (|| -> Result<String, String> {
                let prepared = crate::media_import::prepare(&path).map_err(|e| e.to_string())?;
                // The library is the home of recorded video: a screenshot or a
                // still image is clipboard-first and would not be listed, so an
                // image dropped here is refused instead of disappearing.
                if prepared.kind == CaptureKind::Image {
                    return Err("Only video files can be imported into the library.".into());
                }
                let state = app.state::<AppState>();
                let mut context = state.library.lock().unwrap();
                if context.expected_library_id() != identity
                    || context.expected_library_generation() != generation
                {
                    return Err("Library changed during import".into());
                }
                let asset = context
                    .library_mut()
                    .map_err(|e| e.to_string())?
                    .import_file_with_title(
                        prepared.file.path(),
                        prepared.kind,
                        prepared.extension,
                        prepared.width,
                        prepared.height,
                        prepared.duration,
                        None,
                        crate::media_import::display_title(&path),
                    )
                    .map_err(|e| e.to_string())?;
                Ok(asset.id.to_string())
            })();
            match imported {
                Ok(id) => result.ids.push(id),
                Err(_) => result.failed += 1,
            }
        }
        if !result.ids.is_empty() {
            emit_library_changed(&app);
        }
        Ok(result)
    })
    .await
    .map_err(|e| e.to_string())?
}

#[tauri::command]
pub async fn paste_clipboard_image(window: WebviewWindow, app: AppHandle) -> Result<AssetDto, String> {
    require_library_window(&window)?;
    let state = app.state::<AppState>();
    let (identity, generation) = {
        let context = state.library.lock().unwrap();
        (context.expected_library_id(), context.expected_library_generation())
    };
    tauri::async_runtime::spawn_blocking(move || {
        let png = platform::read_image_from_clipboard().map_err(|error| error.to_string())?;
        let prepared = crate::media_import::prepare_clipboard_png(&png).map_err(|error| error.to_string())?;
        let state = app.state::<AppState>();
        let mut context = state.library.lock().unwrap();
        if context.expected_library_id() != identity || context.expected_library_generation() != generation {
            return Err("Library changed during import.".to_string());
        }
        let asset = context.library_mut().map_err(|error| error.to_string())?
            .import_file_with_title(prepared.file.path(), CaptureKind::Image, "png", prepared.width,
                prepared.height, None, None, None).map_err(|error| error.to_string())?;
        drop(context);
        emit_library_changed(&app);
        Ok(asset_dto(&asset))
    }).await.map_err(|_| "Clipboard image import stopped unexpectedly.".to_string())?
}

#[tauri::command]
pub async fn export_video_copy(
    app: AppHandle,
    window: WebviewWindow,
    id: String,
    segments: Vec<crate::video_export::VideoSegment>,
    effects: Vec<crate::video_export::VideoEffect>,
    annotations: Vec<crate::video_export::VideoAnnotation>,
    preset: crate::video_export::VideoExportPreset,
    request_id: Option<String>,
) -> Result<String, String> {
    let parsed = uuid::Uuid::parse_str(&id).map_err(|e| e.to_string())?;
    if window.label() != format!("viewer-{parsed}") {
        return Err("Video export requires its own viewer.".into());
    }
    if segments.is_empty() || segments.len() > 128 || effects.len() > 128 || annotations.len() > 128
    {
        return Err("Invalid video edit size.".into());
    }
    let request_id = request_id
        .as_deref()
        .map(uuid::Uuid::parse_str)
        .transpose()
        .map_err(|error| error.to_string())?
        .unwrap_or_else(uuid::Uuid::new_v4);
    let progress_window = window.clone();
    let control = crate::video_export::ExportControl::new(move |update| {
        let _ = progress_window.emit(
            "video-export-progress",
            VideoExportProgressDto {
                request_id: request_id.to_string(),
                update,
            },
        );
    });
    let permit = {
        let mut job = VIDEO_EXPORT_JOB
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        if job.is_some() {
            return Err("Another video is being exported.".into());
        }
        *job = Some(ActiveVideoExport {
            request_id,
            owner: window.label().to_owned(),
            control: control.clone(),
        });
        VideoExportPermit(request_id)
    };
    tauri::async_runtime::spawn_blocking(move || {
        let _permit = permit;
        let result = (|| {
            control.check().map_err(|error| error.to_string())?;
            control.report(crate::video_export::ExportPhase::Preparing, None);
            let mut snapshot = tempfile::Builder::new()
                .prefix("kiri-export-source-")
                .suffix(".mp4")
                .tempfile()
                .map_err(|e| e.to_string())?;
            let state = app.state::<AppState>();
            // Open under the library lock, then copy from the stable file handle
            // outside it. A large video on an external disk must not block UI commands.
            let (asset, mut source, library_id, generation) = {
                let mut context = state.library.lock().unwrap();
                let library_id = context.expected_library_id();
                let generation = context.expected_library_generation();
                let library = context.library().map_err(|e| e.to_string())?;
                let asset = library
                    .asset_by_id(&parsed)
                    .cloned()
                    .ok_or_else(|| "The capture could not be found.".to_string())?;
                if asset.kind != CaptureKind::Video || asset.trashed_at.is_some() {
                    return Err("Only active video captures can be exported.".into());
                }
                let source = library
                    .readable_asset_url(&asset)
                    .map_err(|e| e.to_string())?;
                let source = std::fs::File::open(source).map_err(|e| e.to_string())?;
                (asset, source, library_id, generation)
            };
            let source_length = source.metadata().map_err(|error| error.to_string())?.len();
            crate::video_export::copy_export_source(
                &mut source,
                snapshot.as_file_mut(),
                source_length,
                &control,
            )
            .map_err(|error| error.to_string())?;
            drop(source);
            let (path, width, height, duration) =
                crate::video_export::export_video_with_annotations_controlled(
                    snapshot.path(),
                    &segments,
                    &effects,
                    &annotations,
                    preset,
                    &control,
                )
                .map_err(|e| e.to_string())?;
            // RAII also removes the finished temporary export on import failure.
            let output = tempfile::TempPath::try_from_path(path).map_err(|e| e.to_string())?;
            let exported = {
                let mut context = state.library.lock().unwrap();
                if context.expected_library_id() != library_id
                    || context.expected_library_generation() != generation
                {
                    return Err("The library changed during export. Please retry.".into());
                }
                control.begin_commit().map_err(|error| error.to_string())?;
                control.report(crate::video_export::ExportPhase::Saving, None);
                context
                    .library_mut()
                    .map_err(|e| e.to_string())?
                    .import_file(
                        &output,
                        CaptureKind::Video,
                        "mp4",
                        width,
                        height,
                        Some(duration),
                        asset.source_application.clone(),
                    )
                    .map_err(|e| e.to_string())?
            };
            emit_library_changed(&app);
            Ok(exported.id.to_string())
        })();
        // Native APIs may add context to their cancellation errors. Keep this
        // exact sentinel stable so cancel never appears as an export failure.
        if control.is_cancelled() {
            Err(crate::video_export::EXPORT_CANCELLED.to_owned())
        } else {
            result
        }
    })
    .await
    .map_err(|e| e.to_string())?
}

#[tauri::command]
pub fn cancel_gif_conversion(app: AppHandle, window: WebviewWindow, id: String) -> Result<bool, String> {
    let parsed = uuid::Uuid::parse_str(&id).map_err(|error| error.to_string())?;
    if window.label() != "library" && window.label() != "toast" && window.label() != format!("viewer-{parsed}") {
        return Err("GIF cancellation requires its library or preview.".into());
    }
    let state = app.state::<AppState>();
    let controls = state.gif_controls.lock().unwrap();
    let cancelled = controls.get(&parsed).is_some_and(|control| control.request_cancel());
    if cancelled {
        // Serialize with progress updates; an old encoding update cannot replace cancelling.
        let mut conversions = state.gif_conversions.lock().unwrap();
        if let Some(job) = conversions.get_mut(&parsed) {
            job.phase = "cancelling";
            let _ = app.emit("gif-conversion-state", job.clone());
        }
    }
    Ok(cancelled)
}

#[tauri::command]
pub fn convert_to_gif(app: AppHandle, window: WebviewWindow, id: String) -> Result<(), String> {
    let parsed = uuid::Uuid::parse_str(&id).map_err(|e| e.to_string())?;
    let (asset, source_path, library_id, generation) = {
        let state = app.state::<AppState>();
        let mut context = state.library.lock().unwrap();
        let library_id = context.expected_library_id();
        let generation = context.expected_library_generation();
        let library = context.library().map_err(|error| error.to_string())?;
        let asset = library
            .asset_by_id(&parsed)
            .cloned()
            .ok_or_else(|| "The capture could not be found.".to_string())?;
        let source_path = library
            .readable_asset_url(&asset)
            .map_err(|error| error.to_string())?;
        if asset.kind != CaptureKind::Video
            || !crate::core::policy::RecordingPolicy::is_gif_eligible(asset.duration)
        {
            return Err("Only recordings with a known duration can be converted to GIF.".into());
        }
        if window.label() != "library" && window.label() != "toast" && window.label() != format!("viewer-{parsed}") {
            return Err("GIF conversion requires its library or preview.".into());
        }
        // Register while the source path is protected by the library lock.
        // rename_asset follows the same library -> conversion-map lock order.
        let mut converting = state.gif_conversions.lock().unwrap();
        if converting.get(&parsed).is_some_and(|job| job.is_converting) {
            return Err("Already converting.".into());
        }
        converting.insert(parsed, GifConversionStateDto {
            id: id.clone(), is_converting: true, phase: "preparing", progress: None, error: None,
        });
        (asset, source_path, library_id, generation)
    };
    let control = crate::gif::GifControl::default();
    let from_completion = window.label() == "toast";
    let completion_monitor = from_completion
        .then(|| window.current_monitor().ok().flatten())
        .flatten();
    let completion_id = uuid::Uuid::new_v4().to_string();
    app.state::<AppState>().gif_controls.lock().unwrap().insert(parsed, control.clone());
    publish_gif_state(&app, GifConversionStateDto {
        id: id.clone(), is_converting: true, phase: "preparing", progress: None, error: None,
    });
    if from_completion {
        let mut preview = CompletionPreviewDto::processing(
            completion_id.clone(), "gif", "Creating GIF", &completion_asset_detail(&asset));
        preview.asset_id = Some(id.clone());
        show_completion_preview(
            &app,
            &preview,
            completion_monitor.clone(),
        );
    }
    let handle = app.clone();
    std::thread::spawn(move || {
        let mut last_progress = ("preparing", std::time::Instant::now());
        let mut report = |phase: &'static str, progress: Option<f64>| {
            let controls = handle.state::<AppState>();
            let _controls = controls.gif_controls.lock().unwrap();
            if control.is_cancelled() { return; }
            if phase == last_progress.0 && progress != Some(1.0) &&
                last_progress.1.elapsed() < std::time::Duration::from_millis(200) { return; }
            last_progress = (phase, std::time::Instant::now());
            publish_gif_state(&handle, GifConversionStateDto {
                id: id.clone(), is_converting: true, phase, progress, error: None,
            });
        };
        let result = convert_asset_to_gif(&handle, &asset, &source_path, (library_id, generation), &control, &mut report);
        handle.state::<AppState>().gif_controls.lock().unwrap().remove(&parsed);
        let cancelled = control.is_cancelled();
        publish_gif_state(&handle, GifConversionStateDto {
            id: id.clone(), is_converting: false,
            phase: if cancelled { "cancelled" } else if result.is_ok() { "complete" } else { "failed" },
            progress: None, error: if cancelled { None } else { result.as_ref().err().cloned() },
        });
        if cancelled {
            if from_completion {
                show_completion_preview(&handle, &CompletionPreviewDto::ready(
                    completion_id, &asset, "GIF conversion cancelled", completion_asset_detail(&asset), false), completion_monitor);
            }
            return;
        }
        match result {
            Ok(gif_asset) if from_completion => show_completion_preview(
                &handle,
                &CompletionPreviewDto::ready(
                    completion_id,
                    &gif_asset,
                    "GIF Created",
                    completion_asset_detail(&gif_asset),
                    false,
                ),
                completion_monitor,
            ),
            Ok(_) => emit_notice_local(
                &handle,
                "GIF Created".into(),
                "sparkles.rectangle.stack".into(),
            ),
            Err(error) => {
                if from_completion {
                    let mut preview = CompletionPreviewDto::ready(
                        completion_id, &asset, "Could not create GIF", error.clone(), false);
                    preview.phase = "failed".into();
                    show_completion_preview(&handle, &preview, completion_monitor);
                }
                emit_error(&handle, error, None);
            }
        }
    });
    Ok(())
}

fn convert_asset_to_gif(
    app: &AppHandle,
    asset: &CaptureAsset,
    source_path: &std::path::Path,
    library_identity: (uuid::Uuid, uuid::Uuid),
    control: &crate::gif::GifControl,
    progress: crate::gif::GifProgress<'_>,
) -> Result<CaptureAsset, String> {
    let state = app.state::<AppState>();
    control.check().map_err(|error| error.to_string())?;
    let (gif_path, gif_width, gif_height, gif_duration) = export_gif_file(
        app,
        source_path,
        asset.pixel_width,
        asset.pixel_height,
        asset.duration,
        control,
        progress,
    )?;
    let output = tempfile::TempPath::try_from_path(gif_path).map_err(|error| error.to_string())?;
    let import_result = {
        let mut context = state.library.lock().unwrap();
        if (context.expected_library_id(), context.expected_library_generation()) != library_identity {
            return Err("Library changed during GIF conversion.".into());
        }
        control.begin_commit().map_err(|error| error.to_string())?;
        progress("saving", Some(1.0));
        context
            .library_mut()
            .map_err(|error| error.to_string())
            .and_then(|library| {
                library
                    .import_file(
                        &output,
                        CaptureKind::Gif,
                        "gif",
                        gif_width,
                        gif_height,
                        gif_duration.or(asset.duration),
                        asset.source_application.clone(),
                    )
                    .map_err(|e| e.to_string())
            })
    };
    let gif_asset = import_result.map_err(|error| format!("Could not save GIF: {error}"))?;
    emit_library_changed(app);
    Ok(gif_asset)
}

fn export_gif_file(
    app: &AppHandle,
    source_path: &std::path::Path,
    _source_width: i64,
    _source_height: i64,
    source_duration: Option<f64>,
    control: &crate::gif::GifControl,
    progress: crate::gif::GifProgress<'_>,
) -> Result<(PathBuf, i64, i64, Option<f64>), String> {
    let max_long_edge = crate::core::policy::RecordingPolicy::MAXIMUM_GIF_LONG_EDGE;
    let fps = crate::core::policy::RecordingPolicy::GIF_FRAMES_PER_SECOND;

    #[cfg(windows)]
    {
        let _ = (app, source_duration);
        let (gif_path, encoded_duration) = crate::gif::export_gif_controlled(source_path, max_long_edge, fps, control, progress)
            .map_err(|error| format!("{error:#}"))?;
        let (width, height) = if _source_width > 0 && _source_height > 0 {
            (_source_width as u32, _source_height as u32)
        } else {
            crate::gif::video_dimensions(source_path).map_err(|error| format!("{error:#}"))?
        };
        let (width, height) = crate::gif::scaled_dimensions(width, height, max_long_edge);
        Ok((
            gif_path,
            i64::from(width),
            i64::from(height),
            Some(encoded_duration),
        ))
    }

    #[cfg(target_os = "macos")]
    {
        let _ = (app, &progress);
        crate::macos_media::export_gif_controlled(source_path, max_long_edge, fps, control, progress)
            .map(|(path, width, height, duration)| {
                (path, width, height, duration.or(source_duration))
            })
            .map_err(|error| format!("{error:#}"))
    }

    #[cfg(target_os = "linux")]
    {
        let _ = (app, &progress);
        crate::linux_media::export_gif_controlled(source_path, max_long_edge, fps, control, progress)
            .map(|(path, width, height, duration)| {
                (path, width, height, duration.or(source_duration))
            })
            .map_err(|error| format!("{error:#}"))
    }
}

// ---------------------------------------------------------------------------
// Capture flow commands (Windows startup is dispatched from a worker thread)
// ---------------------------------------------------------------------------

/// Label of the overlay on the display that owned the pointer at capture
/// start. Secondary overlays use `overlay-2`, `overlay-3`, ...
const PRIMARY_OVERLAY_LABEL: &str = "overlay";

fn overlay_label_for(display_index: usize) -> String {
    if display_index == 0 {
        PRIMARY_OVERLAY_LABEL.to_string()
    } else {
        format!("overlay-{}", display_index + 1)
    }
}

fn capture_context(
    session: &CaptureSession,
    display_index: usize,
) -> CaptureContextDto {
    let display = session
        .displays
        .get(display_index)
        .or_else(|| session.displays.first())
        .expect("a capture session always owns one frozen display");
    CaptureContextDto {
        capture_id: session.capture_id,
        initial_mode: session.initial_mode,
        display_width: display.screen_frame.width,
        display_height: display.screen_frame.height,
        scale: display.backing_scale,
        pixel_width: display.pixel_width,
        pixel_height: display.pixel_height,
        window_rects: display.window_rects.iter().map(RectDto::from).collect(),
        source_application: session.source_application.clone(),
    }
}

fn capture_context_for_owner(
    session: &CaptureSession,
    owner: Option<&str>,
) -> Result<CaptureContextDto, String> {
    // A caller that names an overlay only ever gets that overlay's display. An
    // unknown label fails closed instead of borrowing display 0's pixels
    // (ADR 0117).
    let display_index = match owner {
        Some(label) => session
            .display_index_for_overlay(label)
            .ok_or_else(|| "This window is not part of the active capture session.".to_string())?,
        None => 0,
    };
    Ok(capture_context(session, display_index))
}

#[cfg(not(target_os = "linux"))]
#[tauri::command]
pub fn start_capture(window: WebviewWindow, app: AppHandle) -> Result<CaptureContextDto, String> {
    let mode = crate::state::load_capture_mode(&app);
    start_capture_with_owner(app, mode, Some(window.label().to_string()))
}

#[cfg(not(target_os = "linux"))]
pub(crate) fn start_capture_with_mode(
    app: AppHandle,
    initial_mode: crate::state::CaptureMode,
) -> Result<CaptureContextDto, String> {
    start_capture_with_owner(app, initial_mode, None)
}

#[cfg(not(target_os = "linux"))]
fn start_capture_with_owner(
    app: AppHandle,
    initial_mode: crate::state::CaptureMode,
    owner_label: Option<String>,
) -> Result<CaptureContextDto, String> {
    crate::scroll_capture::ensure_idle(&app)?;
    log::info!("start_capture: beginning capture flow");
    let state = app.state::<AppState>();
    let _start_permit = match state.capture_start.try_begin() {
        Some(permit) => permit,
        None => {
            // The overlay can request its already-created context while the
            // initiating call is still creating/focusing the WebView. Preserve
            // that re-entry, but never start a second native display freeze.
            let capture = state.capture.lock().unwrap();
            if let Some(session) = capture.session.as_ref() {
                log::info!(
                    "start_capture: returning active session during startup capture_id={} overlays={}",
                    session.capture_id,
                    session.overlays.len()
                );
                let context = capture_context_for_owner(session, owner_label.as_deref())?;
                drop(capture);
                maybe_start_secondary_display_capture(&app, owner_label.as_deref());
                return Ok(context);
            }
            log::warn!("start_capture: ignored concurrent native display freeze request");
            return Err("Screen capture is already starting.".into());
        }
    };
    let _transition = state.library_transition.lock().unwrap();
    // Scrolling capture can take ownership while this call waits for the lock.
    crate::scroll_capture::ensure_idle(&app)?;

    {
        let capture = state.capture.lock().unwrap();
        // The overlay frontend calls start_capture again when it loads; return
        // the existing session context instead of failing.
        if let Some(session) = capture.session.as_ref() {
            log::info!(
                "start_capture: returning active session capture_id={} overlays={}",
                session.capture_id,
                session.overlays.len()
            );
            let context = capture_context_for_owner(session, owner_label.as_deref())?;
            drop(capture);
            maybe_start_secondary_display_capture(&app, owner_label.as_deref());
            return Ok(context);
        }
        let recording = state.recording.lock().unwrap();
        if recording.is_recording
            || recording.is_paused
            || recording.is_transitioning
            || recording.is_finalizing
            || recording.is_starting
        {
            return Err("A recording session is active.".into());
        }
    }
    {
        let mut context = state.library.lock().unwrap();
        context.library().map_err(|error| error.to_string())?;
    }

    // Pre-flight only after ruling out an existing capture session. The
    // overlay asks for its current context when it mounts (twice under React
    // StrictMode in development), and that re-entry must never touch the
    // system permission request path.
    #[cfg(target_os = "macos")]
    {
        use crate::capture::current::PermissionState;
        match crate::capture::current::check_capture_permission() {
            PermissionState::Authorized => {}
            PermissionState::RestartRequired => {
                let message = "Screen Recording access was granted. Quit and reopen Lumen once to finish enabling capture.";
                emit_error(&app, message.into(), Some(RecoveryAction::QuitKiri));
                return Err(message.into());
            }
            PermissionState::SettingsRequired => {
                let message = "Screen Recording is off. Enable Lumen in System Settings, then quit and reopen it once.";
                emit_error(&app, message.into(), Some(RecoveryAction::OpenSettings));
                return Err(message.into());
            }
        }
    }

    let (pid, name) = platform::frontmost_application()
        .map(|(pid, name)| (Some(pid), name))
        .unwrap_or((None, None));
    let was_kiri_frontmost = pid == Some(std::process::id());
    let hidden_windows = hide_library_windows(&app)?;

    // Windows acknowledges the hide and flushes DWM instead of guessing how
    // long the native hide animation will take.
    #[cfg(not(windows))]
    std::thread::sleep(std::time::Duration::from_millis(120));

    let display = match capture_backend::capture_active_display() {
        Ok(display) => display,
        Err(error) => {
            restore_capture_origin(&app, &hidden_windows, was_kiri_frontmost, pid);
            let message = format!("Screen capture could not start: {error}");
            log::error!("start_capture: display capture failed: {error}");
            emit_error(&app, message.clone(), None);
            return Err(message);
        }
    };
    log::info!(
        "start_capture: display frozen logical={}x{} pixels={}x{} scale={}",
        display.screen_frame.width,
        display.screen_frame.height,
        display.pixel_width,
        display.pixel_height,
        display.backing_scale
    );

    finish_frozen_capture(
        &app, display, pid, name, was_kiri_frontmost, hidden_windows, initial_mode,
    )
}

#[cfg(target_os = "linux")]
#[tauri::command]
pub async fn start_capture(window: WebviewWindow, app: AppHandle) -> Result<CaptureContextDto, String> {
    let owner_label = window.label().to_string();
    tauri::async_runtime::spawn_blocking(move || {
        let mode = crate::state::load_capture_mode(&app);
        start_linux_capture_from_shortcut(app, mode, Some(owner_label))
    })
    .await
    .map_err(|error| error.to_string())?
}

/// Persist the mode the overlay last used. The frontend is the only writer;
/// the value is read by the generic capture entry points.
#[tauri::command]
pub fn set_capture_mode(app: AppHandle, mode: String) -> Result<(), String> {
    let parsed = crate::state::parse_capture_mode(&mode)
        .ok_or_else(|| format!("Unknown capture mode: {mode}"))?;
    if let Err(error) = crate::state::save_capture_mode(&app, parsed) {
        // The preference is a convenience, never a prerequisite: a failed
        // write keeps the current capture running and only affects the next
        // generic entry point.
        log::warn!("set_capture_mode: could not persist {mode}: {error}");
        return Err(error.to_string());
    }
    Ok(())
}

/// Share the mode one overlay picked with the other displays of the same
/// capture. Kept separate from the persisted preference: a peer that never
/// changed its own mode must not clobber the user's choice, but every visible
/// overlay should still show the same mode.
#[tauri::command]
pub fn sync_capture_mode(app: AppHandle, mode: String) -> Result<(), String> {
    let parsed = crate::state::parse_capture_mode(&mode)
        .ok_or_else(|| format!("Unknown capture mode: {mode}"))?;
    {
        let state = app.state::<AppState>();
        let mut capture = state.capture.lock().unwrap();
        if let Some(session) = capture.session.as_mut() {
            session.initial_mode = parsed;
        }
    }
    app.emit("capture-mode-changed", mode)
        .map_err(|error| error.to_string())
}

#[cfg(target_os = "linux")]
struct LinuxCapturePrep {
    pid: Option<u32>,
    name: Option<String>,
    was_kiri_frontmost: bool,
    hidden_windows: Vec<String>,
}

/// Freeze the display on a worker thread, then create GTK windows on the
/// main thread. Running `start_capture` entirely off-thread panics tao.
#[cfg(target_os = "linux")]
pub(crate) fn start_linux_capture_from_shortcut(
    app: AppHandle,
    initial_mode: crate::state::CaptureMode,
    owner_label: Option<String>,
) -> Result<CaptureContextDto, String> {
    log::info!("start_linux_capture_from_shortcut: beginning capture flow");
    let state = app.state::<AppState>();
    {
        let capture = state.capture.lock().unwrap();
        if let Some(session) = capture.session.as_ref() {
            let context = capture_context_for_owner(session, owner_label.as_deref())?;
            drop(capture);
            maybe_start_secondary_display_capture(&app, owner_label.as_deref());
            return Ok(context);
        }
    }
    let _start_permit = state
        .capture_start
        .try_begin()
        .ok_or("Screen capture is already starting.")?;

    let prep = linux_run_on_main(&app, {
        let app = app.clone();
        move || linux_capture_preflight(&app)
    })?;
    std::thread::sleep(std::time::Duration::from_millis(120));
    let display = match capture_backend::capture_active_display() {
        Ok(display) => display,
        Err(error) => {
            let message = capture_backend::capture_error_message(&error);
            let recovery = capture_backend::needs_portal_authorization(&error)
                .then_some(RecoveryAction::AuthorizeScreenshot);
            log::error!("start_capture: display capture failed: {error}");
            let _ = linux_run_on_main(&app, {
                let app = app.clone();
                let message = message.clone();
                move || {
                    restore_capture_origin(
                        &app,
                        &prep.hidden_windows,
                        prep.was_kiri_frontmost,
                        prep.pid,
                    );
                    emit_error(&app, message, recovery);
                    Ok(())
                }
            });
            return Err(message);
        }
    };
    linux_run_on_main(&app, {
        let app = app.clone();
        move || linux_capture_commit(&app, prep, display, initial_mode)
    })
}

#[cfg(target_os = "linux")]
fn linux_run_on_main<T, F>(app: &AppHandle, task: F) -> Result<T, String>
where
    T: Send + 'static,
    F: FnOnce() -> Result<T, String> + Send + 'static,
{
    let (sender, receiver) = mpsc::channel();
    app.run_on_main_thread(move || {
        let _ = sender.send(task());
    })
    .map_err(|error| error.to_string())?;
    receiver
        .recv()
        .map_err(|_| "The Linux UI thread stopped before capture could continue.".to_string())?
}

#[cfg(target_os = "linux")]
fn linux_capture_preflight(app: &AppHandle) -> Result<LinuxCapturePrep, String> {
    crate::scroll_capture::ensure_idle(app)?;
    if crate::capture::linux::is_wayland()
        && app.available_monitors().map_err(|e| e.to_string())?.len() != 1
    {
        return Err("Experimental Wayland capture currently requires one display. Use an X11 session for multiple displays.".into());
    }
    let state = app.state::<AppState>();
    {
        let capture = state.capture.lock().unwrap();
        if capture.session.is_some() {
            return Err("Screen capture is already starting.".into());
        }
        let recording = state.recording.lock().unwrap();
        if recording.is_recording
            || recording.is_paused
            || recording.is_transitioning
            || recording.is_finalizing
            || recording.is_starting
        {
            return Err("A recording session is active.".into());
        }
    }
    {
        let mut context = state.library.lock().unwrap();
        context.library().map_err(|error| error.to_string())?;
    }
    let (pid, name) = platform::frontmost_application()
        .map(|(pid, name)| (Some(pid), name))
        .unwrap_or((None, None));
    let was_kiri_frontmost = pid == Some(std::process::id());
    let hidden_windows = hide_library_windows(app)?;
    Ok(LinuxCapturePrep {
        pid,
        name,
        was_kiri_frontmost,
        hidden_windows,
    })
}

#[cfg(target_os = "linux")]
fn linux_capture_commit(
    app: &AppHandle,
    prep: LinuxCapturePrep,
    display: crate::capture::CapturedDisplay,
    initial_mode: crate::state::CaptureMode,
) -> Result<CaptureContextDto, String> {
    let state = app.state::<AppState>();
    let _transition = state.library_transition.lock().unwrap();
    // Recheck after the portal returns, under the same lock as scroll transfer.
    if let Err(error) = crate::scroll_capture::ensure_idle(app) {
        restore_capture_origin(app, &prep.hidden_windows, prep.was_kiri_frontmost, prep.pid);
        return Err(error);
    }
    // A library move can finish while the portal permission dialog is open.
    state
        .library
        .lock()
        .unwrap()
        .library()
        .map_err(|error| error.to_string())?;
    if state.capture.lock().unwrap().session.is_some() {
        restore_capture_origin(app, &prep.hidden_windows, prep.was_kiri_frontmost, prep.pid);
        return Err("Screen capture is already starting.".into());
    }
    let mut display = display;
    let mut monitors = app
        .available_monitors()
        .unwrap_or_default()
        .into_iter()
        .map(|monitor| {
            let position = monitor.position();
            let size = monitor.size();
            crate::capture::linux::LinuxMonitorHint {
                pixel_x: f64::from(position.x),
                pixel_y: f64::from(position.y),
                pixel_width: f64::from(size.width),
                pixel_height: f64::from(size.height),
                scale: monitor.scale_factor().max(1.0),
            }
        })
        .collect::<Vec<_>>();
    // Hyprland's own layout is authoritative when GTK/GDK_SCALE disagrees.
    if let Some(hypr) = crate::capture::linux::hyprland_focused_monitor_hint() {
        monitors.insert(0, hypr);
    }
    for (index, monitor) in monitors.iter().enumerate() {
        log::info!(
            "Linux monitor[{index}]: reported={:.0}x{:.0} at ({:.0},{:.0}) scale={:.2}",
            monitor.pixel_width,
            monitor.pixel_height,
            monitor.pixel_x,
            monitor.pixel_y,
            monitor.scale
        );
    }
    if crate::capture::linux::is_wayland() {
        crate::capture::linux::apply_overlay_geometry(&mut display, &monitors);
    }
    finish_frozen_capture(
        app,
        display,
        prep.pid,
        prep.name,
        prep.was_kiri_frontmost,
        prep.hidden_windows,
        initial_mode,
    )
}

fn finish_frozen_capture(
    app: &AppHandle,
    display: crate::capture::CapturedDisplay,
    pid: Option<u32>,
    name: Option<String>,
    was_kiri_frontmost: bool,
    hidden_windows: Vec<String>,
    initial_mode: crate::state::CaptureMode,
) -> Result<CaptureContextDto, String> {
    log::info!(
        "start_capture: display frozen logical={}x{} pixels={}x{} scale={}",
        display.screen_frame.width,
        display.screen_frame.height,
        display.pixel_width,
        display.pixel_height,
        display.backing_scale
    );

    let capture_id = uuid::Uuid::new_v4();
    let context = CaptureContextDto {
        capture_id,
        initial_mode,
        display_width: display.screen_frame.width,
        display_height: display.screen_frame.height,
        scale: display.backing_scale,
        pixel_width: display.pixel_width,
        pixel_height: display.pixel_height,
        window_rects: display.window_rects.iter().map(RectDto::from).collect(),
        source_application: name.clone(),
    };

    let overlay_frame = display.screen_frame;
    let overlay_scale = display.backing_scale;
    log::info!("start_capture: publishing frozen image capture_id={capture_id}");
    let capture_token = {
        let store = app.state::<crate::protocol::ProtocolStore>();
        crate::protocol::set_frozen_png(&store, capture_id, display.png_data.clone())
    };
    log::info!("start_capture: frozen image published capture_id={capture_id}");

    let overlay_label = overlay_label_for(0);
    log::info!("start_capture: publishing capture session capture_id={capture_id}");
    {
        let state = app.state::<AppState>();
        let mut capture = state.capture.lock().unwrap();
        capture.session = Some(CaptureSession {
            capture_id,
            initial_mode,
            displays: vec![display],
            overlays: vec![OverlayBinding {
                label: overlay_label.clone(),
                display_index: 0,
                token: capture_token.clone(),
            }],
            secondary_displays_started: false,
            source_application: name,
            return_pid: pid,
            was_kiri_frontmost,
            hidden_windows,
            annotation: None,
        });
    }
    log::info!("start_capture: capture session published capture_id={capture_id}");

    log::info!("start_capture: creating overlay window capture_id={capture_id}");
    if let Err(error) = create_overlay_window(
        app,
        &overlay_label,
        overlay_frame,
        overlay_scale,
        &capture_token,
        true,
    ) {
        let failed_session = {
            let state = app.state::<AppState>();
            let mut capture = state.capture.lock().unwrap();
            if capture
                .session
                .as_ref()
                .is_some_and(|session| session.capture_id == capture_id)
            {
                capture.session.take()
            } else {
                None
            }
        };
        if let Some(session) = failed_session {
            teardown_cancelled_capture(app, session, false);
        }
        log::error!("start_capture: overlay window creation failed: {error}");
        return Err(error.to_string());
    }
    // Windows needs explicit activation so the overlay receives keyboard
    // input. On macOS, activating Kiri here can leave another application's
    // native full-screen Space. The AppKit transient policy orders the overlay
    // above that Space without activation; clicking the overlay then gives it
    // normal interaction focus without a Space switch.
    #[cfg(windows)]
    platform::activate_self();
    log::info!("start_capture: overlay window ready ({overlay_label})");
    // Pins must leave the topmost band before the frozen image can capture a
    // click meant for the toolbar.
    sync_pin_capture_gate(app);

    Ok(context)
}

/// Starts the one-time secondary-display freeze. Only the primary overlay may
/// trigger this, and only after it has received its own context, so other
/// displays never delay the display the user is already interacting with.
fn maybe_start_secondary_display_capture(app: &AppHandle, owner: Option<&str>) {
    if owner != Some(PRIMARY_OVERLAY_LABEL) {
        return;
    }
    let (capture_id, primary_display_id) = {
        let state = app.state::<AppState>();
        let mut capture = state.capture.lock().unwrap();
        let Some(session) = capture.session.as_mut() else {
            return;
        };
        if session.secondary_displays_started {
            return;
        }
        session.secondary_displays_started = true;
        (
            session.capture_id,
            session.displays.first().map(|display| display.display_id),
        )
    };
    log::info!("start_capture: starting secondary display freeze capture_id={capture_id}");
    let app = app.clone();
    if let Err(error) = std::thread::Builder::new()
        .name("kiri-capture-displays".into())
        .spawn(move || capture_secondary_displays(app, capture_id, primary_display_id))
    {
        log::warn!("start_capture: could not start the display coordinator: {error}");
    }
}

fn capture_secondary_displays(
    app: AppHandle,
    capture_id: uuid::Uuid,
    primary_display_id: Option<u32>,
) {
    let Some(ids) = run_on_main_with_result(&app, capture_backend::display_ids) else {
        log::warn!("start_capture: could not enumerate displays for secondary overlays");
        return;
    };
    let ids = match ids {
        Ok(ids) => ids,
        Err(error) => {
            log::warn!("start_capture: display enumeration failed: {error}");
            return;
        }
    };
    let mut seen = std::collections::HashSet::new();
    for id in ids {
        if primary_display_id == Some(id) || !seen.insert(id) {
            continue;
        }
        if !capture_session_is_active(&app, capture_id) {
            log::info!("start_capture: secondary display freeze stopped; session ended");
            return;
        }
        // Freezing the next display never blocks the desktop: ScreenCaptureKit
        // requires the main thread, while the Windows and X11 backends already
        // run their own capture worker.
        let display = match freeze_secondary_display(&app, id) {
            Ok(display) => display,
            Err(error) => {
                // A disconnected or unavailable display is skipped; the
                // primary session and every already-created overlay continue.
                log::warn!("start_capture: skipping display {id}: {error}");
                continue;
            }
        };
        let display_id = display.display_id;
        let app_for_main = app.clone();
        match run_on_main_with_result(&app, move || {
            add_secondary_display_overlay(&app_for_main, capture_id, display)
        }) {
            Some(Ok(())) => {
                log::info!("start_capture: secondary overlay ready display_id={display_id}")
            }
            Some(Err(error)) => {
                log::warn!("start_capture: secondary overlay failed display_id={display_id}: {error}")
            }
            None => return,
        }
    }
    log::info!("start_capture: secondary display freeze complete capture_id={capture_id}");
}

/// Freezes one secondary display without stalling the primary overlay.
/// ScreenCaptureKit and `NSScreen` enumeration are main-thread-only; the
/// Windows and X11 backends capture on their own worker and are safe here.
fn freeze_secondary_display(
    app: &AppHandle,
    id: u32,
) -> Result<crate::capture::CapturedDisplay, String> {
    #[cfg(target_os = "macos")]
    {
        run_on_main_with_result(app, move || {
            capture_backend::capture_display_by_id(id)
        })
        .ok_or_else(|| "The main thread stopped during secondary display freeze.".to_string())?
        .map_err(|error| format!("{error:#}"))
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = app;
        capture_backend::capture_display_by_id(id).map_err(|error| format!("{error:#}"))
    }
}

fn capture_session_is_active(app: &AppHandle, capture_id: uuid::Uuid) -> bool {
    app.state::<AppState>()
        .capture
        .lock()
        .unwrap()
        .session
        .as_ref()
        .is_some_and(|session| session.capture_id == capture_id)
}

fn run_on_main_with_result<T: Send + 'static>(
    app: &AppHandle,
    task: impl FnOnce() -> T + Send + 'static,
) -> Option<T> {
    let (sender, receiver) = mpsc::channel();
    if app
        .run_on_main_thread(move || {
            let _ = sender.send(task());
        })
        .is_err()
    {
        return None;
    }
    // Native freezing has its own bounded timeouts; this outer bound only
    // prevents a dead event loop from keeping the coordinator alive forever.
    receiver
        .recv_timeout(std::time::Duration::from_secs(120))
        .ok()
}

fn add_secondary_display_overlay(
    app: &AppHandle,
    capture_id: uuid::Uuid,
    display: crate::capture::CapturedDisplay,
) -> Result<(), String> {
    let state = app.state::<AppState>();
    let (label, frame, scale, token) = {
        let mut capture = state.capture.lock().unwrap();
        let Some(session) = capture
            .session
            .as_mut()
            .filter(|session| session.capture_id == capture_id)
        else {
            return Err("The capture session ended.".into());
        };
        let label = overlay_label_for(session.displays.len());
        if session.overlays.iter().any(|overlay| overlay.label == label) {
            return Err("The overlay binding already exists.".into());
        }
        let token = {
            let store = app.state::<crate::protocol::ProtocolStore>();
            crate::protocol::set_frozen_png(&store, capture_id, display.png_data.clone())
        };
        let frame = display.screen_frame;
        let scale = display.backing_scale;
        let display_index = session.displays.len();
        session.displays.push(display);
        session.overlays.push(OverlayBinding {
            label: label.clone(),
            display_index,
            token: token.clone(),
        });
        (label, frame, scale, token)
    };

    if let Err(error) = create_overlay_window(app, &label, frame, scale, &token, false) {
        // Roll back only this last binding; earlier displays keep their own
        // indices and continue to work.
        let mut capture = state.capture.lock().unwrap();
        if let Some(session) = capture
            .session
            .as_mut()
            .filter(|session| session.capture_id == capture_id)
        {
            if session
                .overlays
                .last()
                .is_some_and(|overlay| overlay.label == label)
            {
                session.overlays.pop();
                session.displays.pop();
            }
        }
        return Err(error.to_string());
    }

    // Cancel or confirmation can consume the session while this WebView is
    // being created. Never leave that late overlay covering the desktop.
    let still_bound = {
        let capture = state.capture.lock().unwrap();
        capture.session.as_ref().is_some_and(|session| {
            session.capture_id == capture_id && session.has_overlay(&label)
        })
    };
    if !still_bound {
        if let Some(window) = app.get_webview_window(&label) {
            let _ = window.close();
        }
        return Err("The capture session ended.".into());
    }
    Ok(())
}

fn hide_library_windows(app: &AppHandle) -> Result<Vec<String>, String> {
    let mut hidden = Vec::new();
    for (label, window) in app.webview_windows() {
        let is_toast = label == "toast";
        if label.starts_with("library") && window.is_visible().unwrap_or(false) {
            hidden.push(label);
        } else if !is_toast {
            continue;
        }
        #[cfg(windows)]
        let result = platform::windows::hide_window_for_capture(&window);
        #[cfg(not(windows))]
        let result = window.hide().map_err(anyhow::Error::from);
        if let Err(error) = result {
            restore_capture_origin(app, &hidden, false, None);
            let message = format!("Screen capture could not start: {error}");
            log::error!("start_capture: hide window failed: {error:#}");
            emit_error(app, message.clone(), None);
            return Err(message);
        }
        if is_toast {
            // Clear renderer state only after native hiding is synchronized.
            let _ = window.emit("toast-dismiss", ());
        }
    }
    Ok(hidden)
}

pub(crate) fn restore_capture_origin(
    app: &AppHandle,
    hidden_windows: &[String],
    was_kiri_frontmost: bool,
    return_pid: Option<u32>,
) {
    for label in hidden_windows {
        if let Some(window) = app.get_webview_window(label) {
            #[cfg(target_os = "linux")]
            platform::linux::show_window_without_activation(app, label);
            #[cfg(not(target_os = "linux"))]
            let _ = window.show();
            #[cfg(target_os = "linux")]
            let _ = window;
        }
    }

    if was_kiri_frontmost {
        let focus_label = hidden_windows
            .iter()
            .find(|label| label.as_str() == "library")
            .or_else(|| hidden_windows.first());
        if let Some(window) = focus_label.and_then(|label| app.get_webview_window(label)) {
            let _ = window.set_focus();
        }
    } else if let Some(pid) = return_pid {
        // Showing a previously visible Kiri window may activate the process on
        // some systems. Restore the original external app after all windows
        // have returned to their pre-capture visibility.
        platform::activate_application(pid);
    }
}

fn create_overlay_window(
    app: &AppHandle,
    label: &str,
    screen_frame: Rect,
    backing_scale: f64,
    capture_token: &str,
    focus: bool,
) -> anyhow::Result<String> {
    let label = label.to_string();
    // Tauri inner_size/position are LOGICAL (points on macOS, DIPs on
    // Windows); the frontend works in display points 1:1.
    let builder = WebviewWindowBuilder::new(
        app,
        label.clone(),
        WebviewUrl::App(format!("index.html?window=overlay&captureToken={capture_token}").into()),
    )
    .title("Lumen")
    .inner_size(screen_frame.width, screen_frame.height)
    .position(screen_frame.x, screen_frame.y)
    .decorations(false)
    .transparent(true)
    .always_on_top(true)
    .skip_taskbar(true)
    .resizable(false)
    .shadow(false);
    // Tao maps visible GTK windows before applying decorations. Keep the Linux
    // overlay hidden until its borderless geometry and compositor policy are
    // configured, so the first map cannot inherit a window-manager frame offset.
    #[cfg(target_os = "linux")]
    let builder = builder.visible(false);
    // Secondary overlays must never steal keyboard focus from the primary
    // display. On macOS the primary keeps its existing non-activating
    // full-screen ordering path.
    #[cfg(any(windows, target_os = "linux"))]
    let builder = builder.focused(focus);
    #[cfg(target_os = "macos")]
    let builder = if focus { builder } else { builder.focused(false) };
    // Build visible on macOS: showing a newly created hidden WKWebView can race
    // initialization and leave the page blank.
    log::info!("create_overlay_window: building webview label={label}");
    let window = builder.build()?;
    log::info!("create_overlay_window: webview built label={label}");
    log::info!("create_overlay_window: placing window label={label}");
    if let Err(error) = platform::place_transient_window(&window, screen_frame, backing_scale) {
        let _ = window.close();
        return Err(error.into());
    }
    log::info!("create_overlay_window: window placed label={label}");
    #[cfg(windows)]
    {
        // Display points must map to screen pixels 1:1; the Windows text size
        // setting would otherwise scale the frozen capture by up to 2.25x.
        let display_scale = window.scale_factor().unwrap_or(backing_scale);
        crate::platform::windows::pin_webview_to_display_scale(&window, display_scale);
    }
    log::info!("create_overlay_window: configuring window label={label}");
    platform::configure_transient_window(&window, platform::TransientWindowRole::CaptureOverlay);
    log::info!("create_overlay_window: window configured label={label}");
    #[cfg(target_os = "linux")]
    if let Err(error) = platform::linux::show_capture_overlay(&window, screen_frame) {
        let _ = window.close();
        return Err(error.into());
    }
    #[cfg(any(windows, target_os = "linux"))]
    if focus {
        log::info!("create_overlay_window: focusing window label={label}");
        if let Err(error) = window.set_focus() {
            let _ = window.close();
            return Err(error.into());
        }
        log::info!("create_overlay_window: window focused label={label}");
    }
    #[cfg(target_os = "macos")]
    log::info!("create_overlay_window: ordered over active full-screen Space without activation label={label}");
    Ok(label)
}

#[tauri::command]
pub fn cancel_capture(window: WebviewWindow, app: AppHandle) -> Result<(), String> {
    let state = app.state::<AppState>();
    // Keep the active capture visible to library migration until its bytes are
    // durably committed. This closes the handoff gap between taking the
    // session and writing the library entry.
    let _transition = state.library_transition.lock().unwrap();
    let session = {
        let mut capture = state.capture.lock().unwrap();
        match capture.session.as_ref() {
            Some(session) if session.has_overlay(window.label()) => capture.session.take(),
            Some(_) => return Err("Capture command is only available to its overlay.".into()),
            None if window.label() == PRIMARY_OVERLAY_LABEL
                || window.label().starts_with("overlay-") =>
            {
                None
            }
            None => return Err("Capture command is only available to its overlay.".into()),
        }
    };
    crate::microphone::stop();
    let Some(session) = session else {
        log::info!("cancel_capture: no active session; closing orphan overlay");
        sync_pin_capture_gate(&app);
        let _ = window.close();
        return Ok(());
    };
    log::info!(
        "cancel_capture: capture_id={} requested",
        session.capture_id
    );
    teardown_cancelled_capture(&app, session, true);
    Ok(())
}

/// Closes the capture overlay that is calling, from a thread that is not the
/// event loop.
///
/// A confirmed capture leaves the overlay to close itself so the confirmation
/// reply reaches WebView2 before the window goes away. That close depends on
/// the `core:window:allow-close` capability, and every display has its own
/// overlay (`overlay`, `overlay-2`, ...): a label its capability list does not
/// cover leaves the user stuck in the editing HUD after the capture has
/// already been saved and pinned. This command is the backend fallback —
/// running as an async command keeps the close off the IPC thread, so it
/// cannot deadlock the reply the way a synchronous close inside the handler
/// would (verified on Windows 10 21H2).
#[tauri::command]
pub async fn close_capture_overlay(window: WebviewWindow) {
    let label = window.label();
    if label != PRIMARY_OVERLAY_LABEL && !label.starts_with("overlay-") {
        return;
    }
    log::info!("close_capture_overlay: closing label={label}");
    // Hide before closing: the capture is already saved, so a visible editor
    // waiting on a native close only looks like an ignored click.
    let _ = window.hide();
    let _ = window.close();
    let owned = window.clone();
    std::thread::spawn(move || {
        // A refused close would otherwise keep the hidden window (and its
        // label) alive. Destroy is addressed by window id, so it cannot reach
        // a later capture that reuses this label.
        std::thread::sleep(Duration::from_millis(400));
        let _ = owned.destroy();
    });
}

pub(crate) fn teardown_cancelled_capture(
    app: &AppHandle,
    session: CaptureSession,
    close_overlays: bool,
) {
    invalidate_capture_resources(app, &session);
    if close_overlays {
        for label in session.overlay_labels() {
            if let Some(window) = app.get_webview_window(label) {
                let _ = window.close();
            }
        }
    }
    restore_capture_origin(
        app,
        &session.hidden_windows,
        session.was_kiri_frontmost,
        session.return_pid,
    );
    sync_pin_capture_gate(app);
}

/// Keeps native pins out of the capture overlay's way for the whole session.
///
/// A pin is topmost, and the frozen screenshot does not contain it (`WDA_
/// EXCLUDEFROMCAPTURE`), so a pin that floats above the overlay both covers
/// the image the user is selecting and takes clicks aimed at the toolbar.
/// A 📌 click that lands on a pin instead of the button leaves the editing HUD
/// untouched, which is the intermittent "clicked pin, still editing" report.
/// The gate is derived from the live session, so every path that ends a
/// capture clears it.
pub(crate) fn sync_pin_capture_gate(app: &AppHandle) {
    let active = app
        .try_state::<AppState>()
        .and_then(|state| {
            state
                .capture
                .lock()
                .map(|capture| capture.session.is_some())
                .ok()
        })
        .unwrap_or(false);
    crate::pin::surface::set_capture_overlay_active(active);
}

pub(crate) struct CaptureLinkPreparation {
    pub capture_id: uuid::Uuid,
    owner_label: String,
    hidden_overlays: Vec<String>,
}

pub(crate) fn prepare_capture_link(
    owner: &WebviewWindow,
    app: &AppHandle,
    capture_id: uuid::Uuid,
) -> Result<CaptureLinkPreparation, String> {
    let state = app.state::<AppState>();
    let _transition = state.library_transition.lock().unwrap();
    let capture = state.capture.lock().unwrap();
    let session = capture
        .session
        .as_ref()
        .filter(|session| session.capture_id == capture_id && session.has_overlay(owner.label()))
        .ok_or("The QR request was canceled.")?;
    let mut hidden_overlays: Vec<WebviewWindow> = Vec::new();
    for label in session.overlay_labels() {
        if let Some(window) = app.get_webview_window(label) {
            if window.is_visible().unwrap_or(false) {
                if window.hide().is_err() {
                    for hidden in &hidden_overlays {
                        let _ = hidden.show();
                    }
                    let _ = owner.set_focus();
                    return Err("Could not open this link.".into());
                }
                hidden_overlays.push(window);
            }
        }
    }
    // Restore the pre-capture windows before opening the browser. Doing this
    // after opening would activate the old app over the requested destination.
    restore_capture_origin(
        app,
        &session.hidden_windows,
        session.was_kiri_frontmost,
        session.return_pid,
    );
    Ok(CaptureLinkPreparation {
        capture_id,
        owner_label: owner.label().to_string(),
        hidden_overlays: hidden_overlays
            .into_iter()
            .map(|window| window.label().to_string())
            .collect(),
    })
}

pub(crate) fn finish_capture_link(
    app: &AppHandle,
    prepared: CaptureLinkPreparation,
    opened: bool,
) -> Result<(), String> {
    let state = app.state::<AppState>();
    let _transition = state.library_transition.lock().unwrap();
    let mut capture = state.capture.lock().unwrap();
    let session = capture
        .session
        .as_ref()
        .filter(|session| {
            session.capture_id == prepared.capture_id && session.has_overlay(&prepared.owner_label)
        })
        .ok_or("The QR request was canceled.")?;
    if !opened {
        for label in &session.hidden_windows {
            if let Some(window) = app.get_webview_window(label) {
                let _ = window.hide();
            }
        }
        for label in prepared.hidden_overlays {
            if session.has_overlay(&label) {
                if let Some(window) = app.get_webview_window(&label) {
                    let _ = window.show();
                }
            }
        }
        if let Some(owner) = app.get_webview_window(&prepared.owner_label) {
            let _ = owner.set_focus();
        }
        return Ok(());
    }
    let session = capture.session.take().unwrap();
    drop(capture);
    crate::microphone::stop();
    invalidate_capture_resources(app, &session);
    sync_pin_capture_gate(app);
    for label in session.overlay_labels() {
        state.qr_requests.clear(label);
        // Keep the hidden IPC owner alive until WebView2 delivers the open
        // response. Its frontend closes it from onOpened after success.
        if label == prepared.owner_label {
            continue;
        }
        if let Some(window) = app.get_webview_window(label) {
            let _ = window.close();
        }
    }
    Ok(())
}

#[cfg(not(target_os = "linux"))]
pub(crate) fn open_capture_link(
    owner: &WebviewWindow,
    app: &AppHandle,
    capture_id: uuid::Uuid,
    open_link: impl FnOnce() -> Result<(), String>,
) -> Result<(), String> {
    let prepared = prepare_capture_link(owner, app, capture_id)?;
    let result = open_link();
    finish_capture_link(app, prepared, result.is_ok())?;
    result
}

pub(crate) fn invalidate_capture_resources(app: &AppHandle, session: &CaptureSession) {
    let state = app.state::<AppState>();
    for label in session.overlay_labels() {
        state
            .ocr_requests
            .clear_owner(&crate::ocr_controller::OcrRequestOwner {
                label: label.to_string(),
                capture_id: session.capture_id,
            });
    }
    crate::protocol::clear_frozen_png_for_capture(
        &app.state::<crate::protocol::ProtocolStore>(),
        session.capture_id,
    );
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PrepareCaptureAnnotationRequest {
    selection: RectDto,
    document_json: String,
}

#[tauri::command]
pub fn prepare_capture_annotation(
    window: WebviewWindow,
    app: AppHandle,
    request: PrepareCaptureAnnotationRequest,
) -> Result<String, String> {
    let document = AnnotationDocument::from_json(&request.document_json)?;
    let state = app.state::<AppState>();
    let mut capture = state.capture.lock().unwrap();
    let session = capture
        .session
        .as_mut()
        .filter(|session| session.has_overlay(window.label()))
        .ok_or_else(|| {
            "This command is only available from the active capture overlay.".to_string()
        })?;
    let selection = Rect::new(
        request.selection.x,
        request.selection.y,
        request.selection.width,
        request.selection.height,
    );
    let display = session
        .display_for_overlay(window.label())
        .cloned()
        .ok_or_else(|| "The capture display is no longer available.".to_string())?;
    validate_staged_capture_annotation(&display, selection, &document)?;
    let token = uuid::Uuid::new_v4();
    session.annotation = Some(StagedCaptureAnnotation {
        token,
        owner_label: window.label().to_string(),
        selection,
        document,
    });
    Ok(token.to_string())
}

/// Delay between a queued completion and the backend's own overlay close.
/// The renderer closes its WebView first, which normally wins; this fallback
/// hides the HUD shortly after the confirmation reply and then destroys the
/// window, so a close WebView2 silently ignored can never strand the editing
/// toolbar on screen.
const CONFIRMED_OVERLAY_CLOSE_FALLBACK: Duration = Duration::from_millis(320);
/// The same fallback for a confirmation that consumed the session but then
/// failed: that overlay can neither confirm nor cancel any more.
const FAILED_OVERLAY_CLOSE_FALLBACK: Duration = Duration::from_millis(600);
/// How long a queued completion may wait for its overlays to report
/// destruction before it is delivered anyway. WebView2 normally delivers that
/// event within a frame or two; a lost event must never keep the single
/// completion slot occupied, because every later 📌 click would then be
/// refused ("the previous capture is still completing") and the restored
/// editing HUD would look like an ignored click.
const STALLED_COMPLETION_TIMEOUT: Duration = Duration::from_millis(900);

/// Closes capture overlays that the renderer did not close itself.
///
/// Runs on a worker thread after a delay: closing a WebView2 window while its
/// IPC reply is still in flight is what wedges the Windows UI thread, so the
/// close always happens after that reply has been delivered.
///
/// The windows are addressed by handle rather than by label: Tauri dispatches
/// close/destroy to the window id, so a leftover handle can never reach a
/// later capture that reuses the same overlay label. Hiding comes first
/// because a hidden overlay cannot strand the user in the editing HUD, even
/// when WebView2 accepts a close and keeps painting the window.
fn schedule_overlay_close_fallback(
    app: &AppHandle,
    capture_id: uuid::Uuid,
    windows: Vec<WebviewWindow>,
    delay: Duration,
) {
    if windows.is_empty() {
        return;
    }
    let app = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(delay);
        let Some(state) = app.try_state::<AppState>() else {
            return;
        };
        // A newer capture owns the desktop now. Its overlays must not be
        // touched, whatever happened to the previous capture's windows — but
        // the previous completion still has to be delivered below, because a
        // queued completion is exactly what refuses the new capture's 📌 click.
        let newer_capture = state
            .capture
            .lock()
            .unwrap()
            .session
            .as_ref()
            .is_some_and(|session| session.capture_id != capture_id);
        if !newer_capture {
            for window in &windows {
                if app.get_webview_window(window.label()).is_none() {
                    continue;
                }
                log::warn!(
                    "confirm_capture: closing overlay the renderer left open label={}",
                    window.label()
                );
                let _ = window.hide();
                let _ = window.close();
            }
            // A refused or dropped close leaves the window alive and hidden.
            // Keep the label owned by the destroyed capture from blocking the
            // next one.
            std::thread::sleep(Duration::from_millis(300));
            for window in &windows {
                let _ = window.destroy();
            }
        }
        // `Destroyed` normally delivers the queued pin. If the event is lost
        // with the window, deliver the completion explicitly once the manager
        // has dropped the labels.
        let labels: Vec<String> = windows.iter().map(|window| window.label().to_string()).collect();
        for _ in 0..20 {
            if labels.iter().all(|label| app.get_webview_window(label).is_none()) {
                break;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        let waited = {
            let pending = state.pending_capture_completion.lock().unwrap();
            match pending.as_ref() {
                Some(pending) if pending.session.capture_id == capture_id => {
                    Some(pending.queued_at.elapsed())
                }
                _ => None,
            }
        };
        let Some(waited) = waited else { return };
        // A completion is only ever a saved capture: delivering it is always
        // better than leaving the slot occupied. Wait out the remaining grace
        // period, then deliver whatever is still queued, whatever the window
        // manager did with the overlays.
        if let Some(remaining) = STALLED_COMPLETION_TIMEOUT.checked_sub(waited) {
            if !remaining.is_zero() {
                std::thread::sleep(remaining);
            }
        }
        let handle = app.clone();
        let _ = app.run_on_main_thread(move || {
            for label in labels {
                finalize_confirmed_capture_after_overlay_destroyed(&handle, &label);
            }
            finish_stalled_completion(&handle);
        });
    });
}

/// Delivers a queued completion whose overlays are all gone.
///
/// The finalizer runs from the overlay's `Destroyed` event. When that event was
/// missed — the window was already gone when the completion was queued — the
/// slot stays occupied and every later confirmation fails after consuming its
/// own session, which leaves the user in the editing HUD.
fn flush_orphaned_capture_completion(app: &AppHandle) {
    let state = app.state::<AppState>();
    let (label, stalled) = {
        let pending = state.pending_capture_completion.lock().unwrap();
        let Some(pending) = pending.as_ref() else {
            return;
        };
        let stalled = pending.queued_at.elapsed() >= STALLED_COMPLETION_TIMEOUT;
        let overlays_gone = pending
            .session
            .overlay_labels()
            .all(|label| app.get_webview_window(label).is_none());
        if !overlays_gone && !stalled {
            return;
        }
        match pending.session.overlays.first() {
            Some(overlay) => (overlay.label.clone(), stalled),
            None => return,
        }
    };
    if stalled {
        // Windows that are still alive belong to a completion whose close was
        // never reported. Delivering it is what unblocks this confirmation.
        log::warn!("confirm_capture: delivering a stalled completion label={label}");
        finish_stalled_completion(app);
        return;
    }
    log::warn!("confirm_capture: finalizing an orphaned completion label={label}");
    finalize_confirmed_capture_after_overlay_destroyed(app, &label);
}

/// Delivers a queued completion that has waited longer than a WebView close can
/// take, so the single pending slot is never left occupied.
///
/// Returns `true` when a completion was delivered and the slot is free.
fn finish_stalled_completion(app: &AppHandle) -> bool {
    let state = app.state::<AppState>();
    let completed = {
        let mut slot = state.pending_capture_completion.lock().unwrap();
        let Some(pending) = slot.as_ref() else {
            return false;
        };
        if pending.queued_at.elapsed() < STALLED_COMPLETION_TIMEOUT {
            return false;
        }
        log::warn!(
            "confirm_capture: delivering a completion whose overlays never reported destruction labels={}",
            pending.session.overlays.len()
        );
        slot.take()
    };
    let Some(completed) = completed else {
        return false;
    };
    // A newer capture owns the desktop right now. Its overlay is waiting for
    // input, so the finished capture must not take focus back; the pin itself
    // never activates, so it can still be presented.
    let (newer_capture, active_labels): (bool, Vec<String>) = {
        let capture = state.capture.lock().unwrap();
        match capture.session.as_ref() {
            Some(session) => (
                session.capture_id != completed.session.capture_id,
                session.overlay_labels().map(str::to_string).collect(),
            ),
            None => (false, Vec::new()),
        }
    };
    let labels: Vec<String> = completed
        .session
        .overlay_labels()
        .map(str::to_string)
        .collect();
    for label in labels {
        // A label reused by the active capture belongs to that capture: closing
        // it would end the user's new selection.
        if active_labels.iter().any(|active| active == &label) {
            continue;
        }
        if let Some(window) = app.get_webview_window(&label) {
            let _ = window.hide();
            let _ = window.close();
        }
    }
    deliver_completed_capture(app, completed, !newer_capture);
    true
}

#[tauri::command]
pub fn confirm_capture(
    window: WebviewWindow,
    app: AppHandle,
    request: tauri::ipc::Request<'_>,
) -> Result<(), String> {
    let pin_on_top = match request.headers().get("x-kiri-pin-on-top") {
        None => false,
        Some(value) if value == "false" => false,
        Some(value) if value == "true" => true,
        Some(_) => return Err("The capture pin action is invalid.".into()),
    };
    let annotation_token = request
        .headers()
        .get("x-kiri-annotation-token")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| uuid::Uuid::parse_str(value).ok())
        .ok_or_else(|| "The capture annotation snapshot is invalid.".to_string())?;
    let png = match request.body() {
        tauri::ipc::InvokeBody::Raw(bytes) => bytes.as_slice(),
        tauri::ipc::InvokeBody::Json(_) => {
            return Err("The capture image must use the binary IPC payload.".into())
        }
    };
    if png.is_empty() {
        return Err("The capture image is empty.".into());
    }

    let state = app.state::<AppState>();
    // A completion from an earlier capture keeps the single pending slot busy.
    // Deliver it if its overlays are already gone; otherwise nudge those
    // overlays closed and refuse before this capture's session is consumed, so
    // a repeated Pin click still has something to confirm. Returning only
    // after the session was taken (the old order) stranded the editing HUD
    // with no way to confirm or cancel.
    flush_orphaned_capture_completion(&app);
    let stalled_completion = {
        let pending = state.pending_capture_completion.lock().unwrap();
        pending.as_ref().map(|pending| {
            (
                pending.session.capture_id,
                pending
                    .session
                    .overlay_labels()
                    .map(str::to_string)
                    .collect::<Vec<_>>(),
            )
        })
    };
    if let Some((pending_capture, labels)) = stalled_completion {
        // The queued capture is already saved; delivering it is always right
        // and frees the slot this confirmation needs. Waiting only while the
        // close is still fresh keeps a duplicate pin from opening beside a
        // completion that is about to arrive on its own.
        if finish_stalled_completion(&app) {
            log::warn!(
                "confirm_capture: delivered the stalled completion capture_id={pending_capture} before confirming"
            );
        } else {
            log::warn!(
                "confirm_capture: previous completion still queued overlays={}",
                labels.len()
            );
            let windows = labels
                .iter()
                .filter_map(|label| app.get_webview_window(label))
                .collect();
            schedule_overlay_close_fallback(&app, pending_capture, windows, CONFIRMED_OVERLAY_CLOSE_FALLBACK);
            return Err("The previous capture is still completing.".into());
        }
    }
    let (capture_id, max_width, max_height, staged, display) = {
        let capture = state.capture.lock().unwrap();
        let session = capture
            .session
            .as_ref()
            .ok_or_else(|| "No active capture session.".to_string())?;
        if !session.has_overlay(window.label()) {
            return Err("Capture confirmation is only available to its overlay.".into());
        }
        let staged = session
            .annotation
            .as_ref()
            .filter(|staged| staged.token == annotation_token)
            .cloned()
            .ok_or_else(|| {
                "The capture annotation snapshot changed before confirmation.".to_string()
            })?;
        // A snapshot belongs to the display it was prepared on. Confirming
        // from a peer overlay would pair this image with another screen's
        // geometry.
        if staged.owner_label != window.label() {
            return Err("This selection was prepared on another display.".into());
        }
        let display = session
            .display_for_overlay(&staged.owner_label)
            .cloned()
            .ok_or_else(|| "The capture display is no longer available.".to_string())?;
        (
            session.capture_id,
            display.pixel_width,
            display.pixel_height,
            staged,
            display,
        )
    };
    // Validate the complete PNG before consuming the active session or writing
    // to the clipboard/library. This also bounds decoder allocation by the
    // dimensions of the frozen display that owns the request.
    let pixel_size = validate_capture_png(png, max_width, max_height)?;
    log::info!(
        "confirm_capture: validated capture_id={} bytes={} pixels={}x{}",
        capture_id,
        png.len(),
        pixel_size.0,
        pixel_size.1
    );
    let editable_project = if staged.document.has_marks() {
        if (
            i64::from(staged.document.source_pixels.width),
            i64::from(staged.document.source_pixels.height),
        ) != pixel_size
        {
            return Err("The annotation document does not match the captured image.".to_string());
        }
        let source =
            crop_annotation_source(&display, staged.selection, staged.document.source_pixels)?;
        Some((source, staged.document.clone()))
    } else {
        None
    };
    let _transition = state.library_transition.lock().unwrap();
    let session = {
        let mut capture = state.capture.lock().unwrap();
        if capture.session.as_ref().is_none_or(|session| {
            session.capture_id != capture_id
                || session
                    .annotation
                    .as_ref()
                    .is_none_or(|staged| staged.token != annotation_token)
        }) {
            return Err("The capture session changed before confirmation.".into());
        }
        capture.session.take().unwrap()
    };
    log::info!(
        "confirm_capture: session consumed capture_id={}",
        session.capture_id
    );
    invalidate_capture_resources(&app, &session);
    // The session is gone, so the pins that were held below the overlay can
    // return to the topmost band while the overlay itself is being closed.
    sync_pin_capture_gate(&app);
    // The capture is committed from this point on, so its frozen screenshot and
    // toolbar are stale. Hide every overlay of the session now, before the
    // clipboard write and library import: those can take a while for a large
    // annotated capture, and a fully painted toolbar during that time reads as
    // an ignored 📌 click (the reported intermittent case). The renderer still
    // closes its own window after this reply; the fallbacks below finish if it
    // cannot.
    for label in session.overlay_labels() {
        if let Some(window) = app.get_webview_window(label) {
            let _ = window.hide();
        }
    }
    // Errors must be visible: show the library window before emitting.
    let session_feedback =
        match confirm_capture_inner(&app, &state, &session, &staged.owner_label, png, pixel_size, editable_project) {
            Ok(feedback) => feedback,
            Err(error) => {
                if let Some(window) = app.get_webview_window("library") {
                    let _ = window.show();
                }
                if capture_failure_requires_global_error(error.copied) {
                    emit_error(&app, error.message.clone(), None);
                }
                // The session is already consumed, so this overlay can never
                // confirm or cancel again. Leaving its HUD on screen reads as
                // an ignored 📌 click, so close it once the error is visible.
                let failed_windows: Vec<WebviewWindow> = session
                    .overlay_labels()
                    .filter_map(|label| app.get_webview_window(label))
                    .collect();
                // The capture is gone even though saving failed, so hide the
                // stale editor now instead of waiting for the delayed close;
                // the failure itself is reported through the library/notice.
                for overlay in &failed_windows {
                    let _ = overlay.hide();
                }
                schedule_overlay_close_fallback(
                    &app,
                    session.capture_id,
                    failed_windows,
                    FAILED_OVERLAY_CLOSE_FALLBACK,
                );
                return Err(error.message);
            }
        };
    let mut pending = state.pending_capture_completion.lock().unwrap();
    log::info!(
        "confirm_capture: completion queued until overlay destruction labels={}",
        session.overlays.len()
    );
    let confirmed_capture = session.capture_id;
    let confirmed_labels: Vec<String> =
        session.overlay_labels().map(str::to_string).collect();
    if let Some(id) = session_feedback.preview.asset_id.as_ref().and_then(|id| uuid::Uuid::parse_str(id).ok()) {
        state.capture_pin_placements.lock().unwrap().remember(id,
            crate::core::pin_placement::CapturePinPlacement::new(
                display.screen_frame, staged.selection, display.backing_scale, pixel_size,
            ));
    }
    *pending = Some(PendingCaptureCompletion {
        session,
        preview: session_feedback.preview,
        monitor: session_feedback.monitor,
        pin_on_top,
        queued_at: Instant::now(),
    });
    drop(pending);
    let confirmed_windows: Vec<WebviewWindow> = confirmed_labels
        .iter()
        .filter_map(|label| app.get_webview_window(label))
        .collect();
    // Hide the overlays before this command replies. The capture is already
    // saved, so the frozen screenshot and its toolbar are stale from this
    // moment on: a renderer that is slow, wedged, or refused permission to
    // close its own window must not be able to leave the editing HUD on
    // screen (that read as an ignored 📌 click). The renderer still closes the
    // window normally; these hidden windows are destroyed by the fallback
    // below if that close never arrives.
    for overlay in &confirmed_windows {
        let _ = overlay.hide();
    }
    // The renderer closes its own overlay after this reply arrives. If WebView2
    // accepts that close but never destroys the window, the queued completion —
    // and with it the pin — never runs and the editing HUD stays on screen.
    // This worker-thread close hides the HUD, then destroys the windows and
    // delivers the queued completion if the destroyed event was lost.
    schedule_overlay_close_fallback(
        &app,
        confirmed_capture,
        confirmed_windows,
        CONFIRMED_OVERLAY_CLOSE_FALLBACK,
    );
    Ok(())
}

#[derive(Debug)]
struct CaptureConfirmationFailure {
    message: String,
    copied: bool,
}

struct CaptureCompletionFeedback {
    preview: CompletionPreviewDto,
    monitor: Option<Monitor>,
}

fn capture_failure_requires_global_error(copied: bool) -> bool {
    !copied
}

fn confirm_capture_inner(
    app: &AppHandle,
    state: &AppState,
    session: &CaptureSession,
    owner_label: &str,
    png: &[u8],
    pixel_size: (i64, i64),
    editable_project: Option<(Vec<u8>, AnnotationDocument)>,
) -> Result<CaptureCompletionFeedback, CaptureConfirmationFailure> {
    log::info!("confirm_capture: bytes={}", png.len());

    // Feedback belongs on the display whose overlay confirmed this capture,
    // never on whichever peer overlay happened to be created first.
    let completion_monitor = app
        .get_webview_window(owner_label)
        .and_then(|window| window.current_monitor().ok().flatten());
    let copied = match platform::write_image_to_clipboard(png) {
        Ok(()) => {
            log::info!("confirm_capture: clipboard write complete");
            true
        }
        Err(error) => {
            log::error!("confirm_capture: clipboard write failed: {error}");
            false
        }
    };

    let (pixel_width, pixel_height) = pixel_size;
    let mut context = state.library.lock().unwrap();
    let library = match context.library_mut() {
        Ok(library) => library,
        Err(error) => {
            if copied {
                emit_notice_on_monitor(
                    app,
                    "Copied, but could not save".into(),
                    "exclamationmark.triangle.fill".into(),
                    completion_monitor,
                );
            }
            return Err(CaptureConfirmationFailure {
                message: error.to_string(),
                copied,
            });
        }
    };
    let import_result = match editable_project {
        Some((source, document)) => serde_json::to_value(document)
            .map_err(|_| "The annotation document could not be encoded.".to_string())
            .and_then(|document| {
                library
                    .import_data_with_annotation_project(
                        png,
                        CaptureKind::Image,
                        "png",
                        pixel_width,
                        pixel_height,
                        None,
                        session.source_application.clone(),
                        None,
                        &source,
                        &document,
                    )
                    .map_err(|error| error.to_string())
            }),
        None => library
            .import_data(
                png,
                CaptureKind::Image,
                "png",
                pixel_width,
                pixel_height,
                None,
                session.source_application.clone(),
                None,
            )
            .map_err(|error| error.to_string()),
    };
    drop(context);
    let asset = match import_result {
        Ok(asset) => asset,
        Err(error) => {
            if copied {
                emit_notice_on_monitor(
                    app,
                    "Copied, but could not save".into(),
                    "exclamationmark.triangle.fill".into(),
                    completion_monitor,
                );
            }
            return Err(CaptureConfirmationFailure {
                message: error,
                copied,
            });
        }
    };
    emit_library_changed(app);
    log::info!(
        "confirm_capture: library import complete asset_id={} copied={}",
        asset.id,
        copied
    );

    let title = if copied {
        "Copied and Saved"
    } else {
        "Saved — Copy Failed"
    };
    Ok(CaptureCompletionFeedback {
        preview: CompletionPreviewDto::ready(
            uuid::Uuid::new_v4().to_string(),
            &asset,
            title,
            completion_asset_detail(&asset),
            copied,
        ),
        monitor: completion_monitor,
    })
}

/// Saves pixels assembled internally by the bounded scrolling document.
/// Never accepts a renderer-provided image or relaxes normal capture IPC limits.
pub(crate) fn save_scroll_capture(
    app: &AppHandle,
    session: &CaptureSession,
    owner_label: &str,
    png: &[u8],
    size: (u32, u32),
) -> Result<CompletionPreviewDto, String> {
    let state = app.state::<AppState>();
    let _transition = state.library_transition.lock().unwrap();
    confirm_capture_inner(app, &state, session, owner_label, png,
        (i64::from(size.0), i64::from(size.1)), None)
        .map(|feedback| feedback.preview)
        .map_err(|failure| failure.message)
}

/// Finalizes a successful capture only after its owner WebView has gone away.
/// This callback runs outside the synchronous confirmation IPC, so creating
/// the completion preview cannot prevent WebView2 from delivering that IPC
/// response. The first destroyed overlay also closes any peers on other
/// monitors; the last one presents feedback and restores the capture origin.
pub(crate) fn finalize_confirmed_capture_after_overlay_destroyed(app: &AppHandle, label: &str) {
    let state = app.state::<AppState>();
    // Overlay labels (`overlay`, `overlay-2`, ...) are reused by every capture,
    // so the event alone does not prove which capture it belongs to. When the
    // active session owns this label under a different capture id, this window
    // belongs to the next capture and must not finalize the old completion.
    let queued_capture = {
        let slot = state.pending_capture_completion.lock().unwrap();
        match slot.as_ref() {
            Some(pending) if pending.session.has_overlay(label) => Some(pending.session.capture_id),
            _ => None,
        }
    };
    let Some(queued_capture) = queued_capture else {
        return;
    };
    let owned_by_later_capture = {
        let capture = state.capture.lock().unwrap();
        capture
            .session
            .as_ref()
            .is_some_and(|session| session.capture_id != queued_capture && session.has_overlay(label))
    };
    if owned_by_later_capture {
        log::info!("confirm_capture: ignoring a destroy event from a later capture label={label}");
        return;
    }

    let (remaining_labels, completed) = {
        let mut slot = state.pending_capture_completion.lock().unwrap();
        let Some(pending) = slot.as_mut() else {
            return;
        };
        if !pending.session.has_overlay(label) {
            return;
        }
        pending.session.overlays.retain(|overlay| {
            overlay.label != label && app.get_webview_window(&overlay.label).is_some()
        });
        let remaining_labels: Vec<String> = pending
            .session
            .overlay_labels()
            .map(str::to_string)
            .collect();
        let completed = if remaining_labels.is_empty() {
            slot.take()
        } else {
            None
        };
        (remaining_labels, completed)
    };

    for owner in remaining_labels {
        if let Some(window) = app.get_webview_window(&owner) {
            if let Err(error) = window.close() {
                log::error!("confirm_capture: peer overlay close failed label={owner}: {error}");
            }
        }
    }

    if let Some(completed) = completed {
        deliver_completed_capture(app, completed, true);
        log::info!("confirm_capture: completion flow returned after overlay destruction");
    }
}

/// Presents a finished capture.
///
/// `restore_origin` returns focus to the application the screenshot was taken
/// from. It is skipped when a newer capture already owns the desktop: that
/// overlay is waiting for input, and the pin itself never activates, so the
/// finished capture can still be presented without stealing that focus.
fn deliver_completed_capture(
    app: &AppHandle,
    completed: PendingCaptureCompletion,
    restore_origin: bool,
) {
    if restore_origin {
        restore_focus(app, &completed.session);
    }
    if completed.pin_on_top {
        let app = app.clone();
        tauri::async_runtime::spawn(async move {
            let mut preview = completed.preview;
            let result = match preview.asset_id.clone() {
                Some(id) => open_pinned_screenshot(app.clone(), id).await,
                None => Err("The saved screenshot is unavailable.".into()),
            };
            if let Err(error) = result {
                log::error!("confirm_capture: pin failed: {error}");
                preview.title = "Could not pin this screenshot.".into();
                show_completion_preview(&app, &preview, completed.monitor);
            } else if !preview.copied {
                emit_notice_on_monitor(
                    &app,
                    "Saved — Copy Failed".into(),
                    "exclamationmark.triangle.fill".into(),
                    completed.monitor,
                );
            }
        });
    } else {
        show_completion_preview(app, &completed.preview, completed.monitor);
    }
}

fn validate_staged_capture_annotation(
    display: &crate::capture::CapturedDisplay,
    selection: Rect,
    document: &AnnotationDocument,
) -> Result<(), String> {
    let values = [
        selection.x,
        selection.y,
        selection.width,
        selection.height,
        display.screen_frame.width,
        display.screen_frame.height,
    ];
    if values.iter().any(|value| !value.is_finite())
        || selection.x < 0.0
        || selection.y < 0.0
        || selection.width <= 0.0
        || selection.height <= 0.0
        || selection.x + selection.width > display.screen_frame.width + 0.01
        || selection.y + selection.height > display.screen_frame.height + 0.01
        || (document.canvas.width - selection.width).abs() > 0.01
        || (document.canvas.height - selection.height).abs() > 0.01
    {
        return Err("The annotation selection is invalid.".into());
    }
    let scale_x = display.pixel_width as f64 / display.screen_frame.width;
    let scale_y = display.pixel_height as f64 / display.screen_frame.height;
    let expected_width = (selection.width * scale_x).round();
    let expected_height = (selection.height * scale_y).round();
    if expected_width != f64::from(document.source_pixels.width)
        || expected_height != f64::from(document.source_pixels.height)
    {
        return Err("The annotation source dimensions are invalid.".into());
    }
    Ok(())
}

fn crop_annotation_source(
    display: &crate::capture::CapturedDisplay,
    selection: Rect,
    expected: AnnotationPixelSize,
) -> Result<Vec<u8>, String> {
    validate_capture_png(
        display.png_data.as_ref(),
        display.pixel_width,
        display.pixel_height,
    )?;
    let image =
        image::load_from_memory_with_format(display.png_data.as_ref(), image::ImageFormat::Png)
            .map_err(|_| "The frozen capture image is invalid.".to_string())?;
    let width = expected.width;
    let height = expected.height;
    if width == 0 || height == 0 || width > image.width() || height > image.height() {
        return Err("The annotation source dimensions are invalid.".into());
    }
    let scale_x = image.width() as f64 / display.screen_frame.width;
    let scale_y = image.height() as f64 / display.screen_frame.height;
    let max_left = image.width() - width;
    let max_top = image.height() - height;
    let left = (selection.x * scale_x)
        .round()
        .clamp(0.0, f64::from(max_left)) as u32;
    let top = (selection.y * scale_y)
        .round()
        .clamp(0.0, f64::from(max_top)) as u32;
    let cropped = image.crop_imm(left, top, width, height);
    let mut output = std::io::Cursor::new(Vec::new());
    cropped
        .write_to(&mut output, image::ImageFormat::Png)
        .map_err(|_| "The editable screenshot source could not be prepared.".to_string())?;
    Ok(output.into_inner())
}

const CAPTURE_PNG_SIGNATURE: &[u8; 8] = b"\x89PNG\r\n\x1a\n";
const CAPTURE_PNG_END: &[u8; 12] = b"\0\0\0\0IEND\xaeB`\x82";
const CAPTURE_PNG_SIZE_SLACK: u64 = 1024 * 1024;
const CAPTURE_PNG_DECODE_BYTES_PER_PIXEL: u64 = 8;

fn capture_png_dimensions(png: &[u8]) -> Option<(u32, u32)> {
    if png.len() < 33
        || !png.starts_with(CAPTURE_PNG_SIGNATURE)
        || png.get(8..12)? != 13_u32.to_be_bytes()
        || png.get(12..16)? != b"IHDR"
    {
        return None;
    }
    let width = u32::from_be_bytes(png.get(16..20)?.try_into().ok()?);
    let height = u32::from_be_bytes(png.get(20..24)?.try_into().ok()?);
    (width > 0 && height > 0).then_some((width, height))
}

fn validate_capture_png(png: &[u8], max_width: i64, max_height: i64) -> Result<(i64, i64), String> {
    if !png.starts_with(CAPTURE_PNG_SIGNATURE)
        || !png.ends_with(CAPTURE_PNG_END)
        || max_width <= 0
        || max_height <= 0
    {
        return Err("The capture image is invalid.".into());
    }
    let (header_width, header_height) =
        capture_png_dimensions(png).ok_or_else(|| "The capture image is invalid.".to_string())?;
    let width = i64::from(header_width);
    let height = i64::from(header_height);
    if width > max_width || height > max_height {
        return Err("The capture dimensions are invalid.".into());
    }

    let max_bytes = u64::from(header_width)
        .checked_mul(u64::from(header_height))
        .and_then(|pixels| pixels.checked_mul(4))
        .and_then(|bytes| bytes.checked_add(CAPTURE_PNG_SIZE_SLACK))
        .ok_or_else(|| "The capture dimensions are invalid.".to_string())?;
    if u64::try_from(png.len()).unwrap_or(u64::MAX) > max_bytes {
        return Err("The capture image is too large.".into());
    }

    let max_alloc = u64::from(header_width)
        .checked_mul(u64::from(header_height))
        .and_then(|pixels| pixels.checked_mul(CAPTURE_PNG_DECODE_BYTES_PER_PIXEL))
        .and_then(|bytes| bytes.checked_add(CAPTURE_PNG_SIZE_SLACK))
        .ok_or_else(|| "The capture dimensions are invalid.".to_string())?;
    let mut limits = image::Limits::default();
    limits.max_image_width = Some(header_width);
    limits.max_image_height = Some(header_height);
    limits.max_alloc = Some(max_alloc);
    let mut reader =
        image::ImageReader::with_format(std::io::Cursor::new(png), image::ImageFormat::Png);
    reader.limits(limits);
    let image = reader
        .decode()
        .map_err(|_| "The capture image is invalid.".to_string())?;
    if image.width() != header_width || image.height() != header_height {
        return Err("The capture dimensions are invalid.".into());
    }
    Ok((width, height))
}

#[tauri::command]
pub async fn save_file_dialog(
    window: WebviewWindow,
    app: AppHandle,
    default_name: String,
) -> Result<Option<String>, String> {
    use tauri_plugin_dialog::DialogExt;
    let editor_id = editor_window_id(&window)?;
    {
        let state = app.state::<AppState>();
        let mut context = state.library.lock().unwrap();
        let library = context.library().map_err(|error| error.to_string())?;
        let asset = library
            .asset_by_id(&editor_id)
            .ok_or_else(|| "The edited asset could not be found.".to_string())?;
        if asset.kind != CaptureKind::Image {
            return Err("Only image captures can be edited.".into());
        }
    }
    let window_label = window.label().to_string();
    // Localize the filter label from the persisted language preference.
    let language = crate::core::locale::preferred_language(
        &crate::state::load_language(&app),
        &get_locale(),
    );
    let filter_label = crate::core::locale::png_filter_label(language).to_string();
    let dialog_app = app.clone();
    let destination = tauri::async_runtime::spawn_blocking(move || {
        dialog_app
            .dialog()
            .file()
            .set_file_name(default_name)
            .add_filter(filter_label, &["png"])
            .blocking_save_file()
            .and_then(|path| path.into_path().ok())
    })
    .await
    .map_err(|error| format!("Could not open the save panel: {error}"))?;

    let state = app.state::<AppState>();
    let mut destinations = state.editor_save_destinations.lock().unwrap();
    let Some(path) = destination else {
        destinations.remove(&window_label);
        return Ok(None);
    };
    let token = uuid::Uuid::new_v4();
    destinations.insert(window_label, ApprovedEditorSave { token, path });
    Ok(Some(token.to_string()))
}

pub(crate) fn restore_focus(app: &AppHandle, session: &CaptureSession) {
    restore_capture_origin(
        app,
        &session.hidden_windows,
        session.was_kiri_frontmost,
        session.return_pid,
    );
}

// ---------------------------------------------------------------------------
// Editor command
// ---------------------------------------------------------------------------

const EDITOR_ACTION_INVALID_ERROR: &str = "The editor save action is invalid.";
const EDITOR_SAVE_ERROR: &str = "The edited image could not be saved to the selected file.";
const EDITOR_REVISION_MISMATCH_ERROR: &str = "The screenshot changed after the editor opened.";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum EditorSaveAction {
    Save,
    SaveAs,
}

fn parse_editor_save_action(
    value: Option<&str>,
    has_save_token: bool,
) -> Result<EditorSaveAction, String> {
    match (value, has_save_token) {
        (Some("save"), false) => Ok(EditorSaveAction::Save),
        (Some("save-as"), true) => Ok(EditorSaveAction::SaveAs),
        _ => Err(EDITOR_ACTION_INVALID_ERROR.into()),
    }
}

fn write_editor_save(path: &Path, png: &[u8]) -> Result<(), String> {
    let parent = path.parent().ok_or_else(|| EDITOR_SAVE_ERROR.to_string())?;
    let mut temporary = tempfile::Builder::new()
        .prefix(".kiri-export-")
        .suffix(".tmp")
        .tempfile_in(parent)
        .map_err(|_| EDITOR_SAVE_ERROR.to_string())?;
    std::io::Write::write_all(temporary.as_file_mut(), png)
        .and_then(|_| std::io::Write::flush(temporary.as_file_mut()))
        .and_then(|_| temporary.as_file().sync_all())
        .map_err(|_| EDITOR_SAVE_ERROR.to_string())?;
    temporary
        .persist(path)
        .map_err(|_| EDITOR_SAVE_ERROR.to_string())?;
    Ok(())
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AnnotationProjectDto {
    revision_sha256: String,
    state: EditorAnnotationState,
    document_json: Option<String>,
    read_only: bool,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EditorUpdateDto {
    revision_sha256: String,
    action_succeeded: bool,
}

#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EditorCropPixels {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
}

fn require_editor_window(window: &WebviewWindow, id: &uuid::Uuid) -> Result<(), String> {
    let expected = format!("editor-{}", id.to_string().to_lowercase());
    if window.label() == expected {
        Ok(())
    } else {
        Err("This command is only available from the matching screenshot editor.".into())
    }
}

fn editor_window_id(window: &WebviewWindow) -> Result<uuid::Uuid, String> {
    let raw_id = window
        .label()
        .strip_prefix("editor-")
        .ok_or_else(|| "This command is only available from a screenshot editor.".to_string())?;
    let id = uuid::Uuid::parse_str(raw_id)
        .map_err(|_| "This command is only available from a screenshot editor.".to_string())?;
    require_editor_window(window, &id)?;
    Ok(id)
}

fn editor_save_destination(
    destinations: &HashMap<String, ApprovedEditorSave>,
    window_label: &str,
    token: Option<uuid::Uuid>,
) -> Result<Option<PathBuf>, String> {
    let approved = destinations.get(window_label);
    match (token, approved) {
        (None, _) => Ok(None),
        (Some(token), Some(approved)) if approved.token == token => Ok(Some(approved.path.clone())),
        (Some(_), _) => Err("The selected save destination is no longer authorized.".into()),
    }
}

fn commit_editor_update<T, E>(
    mutation: impl FnOnce() -> Result<T, E>,
    committed_action: impl FnOnce() -> bool,
) -> Result<(T, bool), E> {
    let revision = mutation()?;
    Ok((revision, committed_action()))
}

fn is_annotation_revision(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn validate_editor_annotation_document(
    document: &AnnotationDocument,
    expected_size: (i64, i64),
) -> Result<(), String> {
    document.validate_for_image_pixels(expected_size.0, expected_size.1)
}

fn crop_editor_source(
    source_png: &[u8],
    expected_size: (i64, i64),
    crop: EditorCropPixels,
) -> Result<Vec<u8>, String> {
    if validate_capture_png(source_png, expected_size.0, expected_size.1)? != expected_size {
        return Err("The editable screenshot source dimensions changed unexpectedly.".into());
    }
    if crop.width == 0
        || crop.height == 0
        || u64::from(crop.x) + u64::from(crop.width) > expected_size.0 as u64
        || u64::from(crop.y) + u64::from(crop.height) > expected_size.1 as u64
    {
        return Err("The crop area is invalid.".into());
    }
    let image = image::load_from_memory_with_format(source_png, image::ImageFormat::Png)
        .map_err(|_| "The editable screenshot source is invalid.".to_string())?;
    let cropped = image.crop_imm(crop.x, crop.y, crop.width, crop.height);
    let mut output = std::io::Cursor::new(Vec::new());
    cropped
        .write_to(&mut output, image::ImageFormat::Png)
        .map_err(|_| "The cropped screenshot source could not be prepared.".to_string())?;
    Ok(output.into_inner())
}

#[tauri::command]
pub fn get_asset_annotation_project(
    window: WebviewWindow,
    app: AppHandle,
    id: String,
) -> Result<AnnotationProjectDto, String> {
    let parsed =
        uuid::Uuid::parse_str(&id).map_err(|_| "The edited asset id is invalid.".to_string())?;
    require_editor_window(&window, &parsed)?;
    let state = app.state::<AppState>();
    let (snapshot, expected_size) = {
        let mut context = state.library.lock().unwrap();
        let library = context.library().map_err(|error| error.to_string())?;
        let asset = library
            .asset_by_id(&parsed)
            .ok_or_else(|| "The edited asset could not be found.".to_string())?;
        if asset.kind != CaptureKind::Image {
            return Err("Only image captures can be edited.".into());
        }
        let expected_size = (asset.pixel_width, asset.pixel_height);
        let snapshot = library
            .load_editor_snapshot(&parsed)
            .map_err(|error| error.to_string())?;
        (snapshot, expected_size)
    };
    let document_json = snapshot
        .document
        .map(|document| {
            let document_json = serde_json::to_string(&document)
                .map_err(|_| "The annotation document could not be decoded.".to_string())?;
            let document = AnnotationDocument::from_json(&document_json)?;
            validate_editor_annotation_document(&document, expected_size)?;
            String::from_utf8(document.to_json()?)
                .map_err(|_| "The annotation document could not be decoded.".to_string())
        })
        .transpose()?;
    Ok(AnnotationProjectDto {
        revision_sha256: snapshot.revision_sha256,
        state: snapshot.state,
        document_json,
        read_only: false,
    })
}

#[tauri::command]
pub async fn prepare_asset_annotation(
    window: WebviewWindow,
    app: AppHandle,
    id: String,
    document_json: String,
    revision_sha256: String,
    crop_pixels: Option<EditorCropPixels>,
) -> Result<String, String> {
    let parsed =
        uuid::Uuid::parse_str(&id).map_err(|_| "The edited asset id is invalid.".to_string())?;
    require_editor_window(&window, &parsed)?;
    let document = AnnotationDocument::from_json(&document_json)?;
    let state = app.state::<AppState>();
    if !is_annotation_revision(&revision_sha256) {
        return Err("The editor source revision is invalid.".into());
    }
    let (expected_size, source_png) = {
        let mut context = state.library.lock().unwrap();
        let library = context.library().map_err(|error| error.to_string())?;
        let asset = library
            .asset_by_id(&parsed)
            .ok_or_else(|| "The edited asset could not be found.".to_string())?;
        if asset.kind != CaptureKind::Image {
            return Err("Only image captures can be edited.".into());
        }
        let snapshot = library
            .load_editor_snapshot(&parsed)
            .map_err(|error| error.to_string())?;
        if snapshot.revision_sha256 != revision_sha256 {
            return Err(EDITOR_REVISION_MISMATCH_ERROR.into());
        }
        ((asset.pixel_width, asset.pixel_height), snapshot.source)
    };
    let replacement_source_png = match crop_pixels {
        Some(crop) => Some(
            tauri::async_runtime::spawn_blocking(move || {
                crop_editor_source(&source_png, expected_size, crop)
            })
            .await
            .map_err(|_| "The cropped screenshot source could not be prepared.".to_string())??,
        ),
        None => None,
    };
    let output_size = crop_pixels
        .map(|crop| (i64::from(crop.width), i64::from(crop.height)))
        .unwrap_or(expected_size);
    validate_editor_annotation_document(&document, output_size)?;
    let token = uuid::Uuid::new_v4();
    state.editor_annotations.lock().unwrap().insert(
        window.label().to_string(),
        StagedEditorAnnotation {
            token,
            document,
            replacement_source_png,
            output_size,
            revision_sha256,
        },
    );
    Ok(token.to_string())
}

#[tauri::command]
pub fn update_asset(
    window: WebviewWindow,
    app: AppHandle,
    request: tauri::ipc::Request<'_>,
) -> Result<EditorUpdateDto, String> {
    let parsed = request
        .headers()
        .get("x-kiri-asset-id")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| uuid::Uuid::parse_str(value).ok())
        .ok_or_else(|| "The edited asset id is invalid.".to_string())?;
    require_editor_window(&window, &parsed)?;
    let annotation_token = request
        .headers()
        .get("x-kiri-annotation-token")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| uuid::Uuid::parse_str(value).ok())
        .ok_or_else(|| "The editor annotation snapshot is invalid.".to_string())?;
    let editor_action = request
        .headers()
        .get("x-kiri-editor-action")
        .and_then(|value| value.to_str().ok())
        .map(str::to_owned);
    let save_token = request
        .headers()
        .get("x-kiri-save-token")
        .map(|value| {
            value
                .to_str()
                .map_err(|_| "The save authorization is invalid.".to_string())
                .and_then(|value| {
                    uuid::Uuid::parse_str(value)
                        .map_err(|_| "The save authorization is invalid.".to_string())
                })
        })
        .transpose()?;
    let editor_action = parse_editor_save_action(editor_action.as_deref(), save_token.is_some())?;
    let png = match request.body() {
        tauri::ipc::InvokeBody::Raw(bytes) if !bytes.is_empty() => bytes.as_slice(),
        tauri::ipc::InvokeBody::Raw(_) => return Err("The edited image is empty.".into()),
        tauri::ipc::InvokeBody::Json(_) => {
            return Err("The edited image must use the binary IPC payload.".into())
        }
    };

    let state = app.state::<AppState>();
    let current_size = {
        let mut context = state.library.lock().unwrap();
        let library = context.library().map_err(|error| error.to_string())?;
        let asset = library
            .asset_by_id(&parsed)
            .ok_or_else(|| "The edited asset could not be found.".to_string())?;
        if asset.kind != CaptureKind::Image {
            return Err("Only image captures can be edited.".into());
        }
        (asset.pixel_width, asset.pixel_height)
    };
    let mut annotations = state.editor_annotations.lock().unwrap();
    let staged = annotations
        .get(window.label())
        .filter(|staged| staged.token == annotation_token)
        .cloned()
        .ok_or_else(|| "The editor annotation snapshot changed before saving.".to_string())?;
    if staged.replacement_source_png.is_none() && staged.output_size != current_size {
        return Err("The edited image dimensions changed unexpectedly.".into());
    }
    if validate_capture_png(png, staged.output_size.0, staged.output_size.1)? != staged.output_size
    {
        return Err("The edited image dimensions changed unexpectedly.".into());
    }
    validate_editor_annotation_document(&staged.document, staged.output_size)?;
    let mut destinations = state.editor_save_destinations.lock().unwrap();
    let save_path = editor_save_destination(&destinations, window.label(), save_token)?;
    let store = app.state::<crate::protocol::ProtocolStore>();
    let document_value = serde_json::to_value(&staged.document)
        .map_err(|_| "The annotation document could not be encoded.".to_string())?;
    if editor_action == EditorSaveAction::SaveAs {
        let current_revision = {
            let mut context = state.library.lock().unwrap();
            let library = context.library().map_err(|error| error.to_string())?;
            library
                .load_editor_snapshot(&parsed)
                .map_err(|error| error.to_string())?
                .revision_sha256
        };
        if current_revision != staged.revision_sha256 {
            return Err(EDITOR_REVISION_MISMATCH_ERROR.into());
        }
        annotations.remove(window.label());
        if save_token.is_some() {
            destinations.remove(window.label());
        }
        drop(destinations);
        drop(annotations);
        let action_succeeded = save_path
            .as_ref()
            .is_some_and(|path| write_editor_save(path, png).is_ok());
        return Ok(EditorUpdateDto {
            revision_sha256: current_revision,
            action_succeeded,
        });
    }
    let mutation: Result<(String, bool), LibraryLocationError> = commit_editor_update(
        || {
            crate::protocol::with_thumbnail_invalidation(&store, parsed, || {
                let mut context = state.library.lock().unwrap();
                let library = context.library_mut()?;
                if let Some(source_png) = staged.replacement_source_png.as_deref() {
                    library.save_editor_cropped_snapshot(
                        &parsed,
                        &staged.revision_sha256,
                        png,
                        source_png,
                        staged.output_size,
                        staged.document.has_marks().then_some(&document_value),
                    )?;
                } else {
                    library.save_editor_snapshot(
                        &parsed,
                        &staged.revision_sha256,
                        png,
                        staged.document.has_marks().then_some(&document_value),
                    )?;
                }
                Ok::<String, LibraryLocationError>(
                    library.load_editor_snapshot(&parsed)?.revision_sha256,
                )
            })
        },
        || {
            annotations.remove(window.label());
            if save_token.is_some() {
                destinations.remove(window.label());
            }
            drop(destinations);
            drop(annotations);

            debug_assert!(save_path.is_none());
            true
        },
    );
    let (revision_sha256, action_succeeded) = match mutation {
        Ok(result) => result,
        Err(LibraryLocationError::Library(AssetLibraryError::AnnotationRevisionMismatch)) => {
            return Err(EDITOR_REVISION_MISMATCH_ERROR.into())
        }
        Err(error) => return Err(error.to_string()),
    };
    emit_asset_content_changed(&app, &parsed);
    emit_library_changed(&app);
    Ok(EditorUpdateDto {
        revision_sha256,
        action_succeeded,
    })
}

/// Update the display title and the managed asset's actual file name together.
#[tauri::command]
pub async fn rename_asset(app: AppHandle, id: String, title: String) -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(move || rename_asset_inner(app, id, title))
        .await.map_err(|error| error.to_string())?
}

fn rename_asset_inner(app: AppHandle, id: String, title: String) -> Result<(), String> {
    let parsed = uuid::Uuid::parse_str(&id).map_err(|e| e.to_string())?;
    let trimmed = title.trim().to_string();
    let state = app.state::<AppState>();
    // Existing thumbnail generation retains a path after releasing the library
    // lock. Share its barrier, preserving all cached ID-keyed thumbnails.
    let result = crate::protocol::with_thumbnail_invalidations(&app.state::<crate::protocol::ProtocolStore>(), &[], || -> Result<_, String> {
        let mut context = state.library.lock().unwrap();
        // Conversion start follows the same library -> conversion-map order.
        if state.gif_conversions.lock().unwrap().get(&parsed).is_some_and(|job| job.is_converting) {
            return Err("Wait for GIF conversion to finish before renaming.".into());
        }
        Ok(context.library_mut().map_err(|error| error.to_string())?
            .rename_file(if trimmed.is_empty() { None } else { Some(trimmed) }, &parsed))
    })?;
    // CleanupFailed is committed: the new name is valid and persisted, while
    // an old duplicate needs attention. Never hide that successful mutation.
    if result.is_ok() || matches!(result, Err(AssetLibraryError::CleanupFailed { .. } | AssetLibraryError::CommittedRenameSyncFailed)) {
        emit_library_changed(&app);
    }
    result.map_err(|error| match error {
        AssetLibraryError::InvalidFilename => "Use a valid file name.".to_string(),
        AssetLibraryError::FilenameInUse => "A file with that name already exists.".to_string(),
        AssetLibraryError::CleanupFailed { .. } => "Renamed; the old file could not be removed.".to_string(),
        AssetLibraryError::CommittedRenameSyncFailed => "Renamed; disk synchronization failed.".to_string(),
        _ => "Couldn't rename this capture.".to_string(),
    })
}

/// Replaces the tag list of a capture (metadata only).
#[tauri::command]
pub fn set_tags(app: AppHandle, id: String, tags: Vec<String>) -> Result<(), String> {
    let parsed = uuid::Uuid::parse_str(&id).map_err(|e| e.to_string())?;
    let state = app.state::<AppState>();
    let mut context = state.library.lock().unwrap();
    context
        .library_mut()
        .map_err(|error| error.to_string())?
        .set_tags(tags, &parsed)
        .map_err(|e| e.to_string())?;
    drop(context);
    emit_library_changed(&app);
    Ok(())
}

#[tauri::command]
pub fn copy_capture_color(
    app: AppHandle,
    window: WebviewWindow,
    hex: String,
) -> Result<(), String> {
    if hex.len() != 7 || !hex.starts_with('#') || !hex.as_bytes()[1..].iter().all(u8::is_ascii_hexdigit) {
        return Err("Invalid color value.".into());
    }
    let state = app.state::<AppState>();
    let capture = state.capture.lock().unwrap();
    capture.session.as_ref()
        .filter(|session| session.has_overlay(window.label()))
        .ok_or("Capture command is only available to its overlay.")?;
    // Keep the frozen screen and selection available for more samples. OCR's
    // copy_text deliberately completes its session and is a separate action.
    platform::write_text_to_clipboard(&hex.to_ascii_uppercase()).map_err(|error| error.to_string())
}

#[tauri::command]
pub fn open_library(app: AppHandle, window: WebviewWindow) -> Result<(), String> {
    if !matches!(window.label(), "library" | "toast") {
        return Err("This command is unavailable from this window.".into());
    }
    crate::show_library_window(&app, "recording-error-recovery")
}

#[tauri::command]
pub async fn copy_support_info(app: AppHandle, window: WebviewWindow) -> Result<(), String> {
    require_library_window(&window)?;
    let displays = app.available_monitors().ok().map(|monitors| monitors.into_iter().map(|monitor| {
        crate::support_info::DisplayInfo {
            width: monitor.size().width, height: monitor.size().height, scale: monitor.scale_factor(),
        }
    }).collect::<Vec<_>>());
    let language = crate::state::load_language(&app);
    let language = if language.is_empty() { get_locale() } else { language };
    let text = crate::support_info::report(
        &app.package_info().version.to_string(), &language, displays.as_deref(),
    );
    // Diagnostics have no capture/session side effects and contain no library data.
    platform::write_text_to_clipboard(&text).map_err(|error| error.to_string())
}

#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SupportFolder { Settings, Logs, Errors, Temporary }

#[tauri::command]
pub async fn open_support_folder(app: AppHandle, window: WebviewWindow, folder: SupportFolder) -> Result<(), String> {
    require_library_window(&window)?;
    let path = match folder {
        SupportFolder::Settings => crate::paths::config_dir(&app),
        SupportFolder::Logs => {
            #[cfg(windows)]
            { crate::diagnostics::windows_log_dir() }
            #[cfg(not(windows))]
            { crate::state::log_dir() }
        },
        SupportFolder::Errors => crate::state::log_dir(),
        SupportFolder::Temporary => Some(std::env::temp_dir()),
    }.ok_or_else(|| "Couldn't open folder".to_string())?;
    // These fixed destinations never accept a path from the renderer. Create
    // the settings/log directory on this explicit action if it is still empty.
    let path = tauri::async_runtime::spawn_blocking(move || {
        std::fs::create_dir_all(&path).map_err(|error| error.to_string())?;
        Ok::<_, String>(path)
    }).await.map_err(|error| error.to_string())?
        .map_err(|error| { log::warn!("Could not prepare support folder: {error}"); "Couldn't open folder".to_string() })?;
    #[cfg(target_os = "macos")]
    {
        // Reveal selects the directory in its parent. These explicit folder
        // actions should open the directory itself in Finder.
        let url = objc2_foundation::NSURL::fileURLWithPath(
            &objc2_foundation::NSString::from_str(&path.to_string_lossy()));
        if objc2_app_kit::NSWorkspace::sharedWorkspace().openURL(&url) {
            Ok(())
        } else {
            Err("Couldn't open folder".into())
        }
    }
    #[cfg(not(target_os = "macos"))]
    { reveal_path_async(path).await }
}

#[tauri::command]
pub fn copy_text(app: AppHandle, window: WebviewWindow, text: String) -> Result<(), String> {
    platform::write_text_to_clipboard(&text).map_err(|e| e.to_string())?;
    // OCR runs inside a screen-covering always-on-top overlay. Tear that
    // capture session down before presenting confirmation, otherwise the
    // resident toast exists but remains hidden until the user closes OCR.
    cancel_capture(window, app.clone())?;
    emit_notice(&app, "Text Copied".into(), "checkmark.circle.fill".into());
    Ok(())
}

// ---------------------------------------------------------------------------
// Recording commands
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StartRecordingRequest {
    pub region: RectDto,
    pub options: RecordingOptions,
}

#[tauri::command]
pub async fn start_recording_flow(
    app: AppHandle,
    window: WebviewWindow,
    request: StartRecordingRequest,
) -> Result<(), String> {
    crate::scroll_capture::ensure_idle(&app)?;
    // Do not trigger a privacy prompt for stale/direct IPC without a live
    // user-initiated capture session.
    {
        let state = app.state::<AppState>();
        let capture = state.capture.lock().unwrap();
        match capture.session.as_ref() {
            Some(session) if session.has_overlay(window.label()) => {}
            _ => return Err("No active capture session.".into()),
        }
    }
    {
        let state = app.state::<AppState>();
        let mut context = state.library.lock().unwrap();
        context.library().map_err(|error| error.to_string())?;
    }

    crate::microphone::stop();
    let saved_options = request.options.normalized();
    let mut options = saved_options.clone();
    if options.output_format == RecordingOutputFormat::Gif {
        // GIF has no audio channel. Keep the saved MP4 preferences intact and
        // disable audio only for this capture session.
        options.captures_system_audio = false;
        options.captures_microphone = false;
    }
    #[cfg(target_os = "linux")]
    {
        // Click monitoring is separate from the shared-clock Linux audio pipeline.
        options.highlights_clicks = false;
    }
    #[cfg(target_os = "macos")]
    if options.captures_microphone {
        match platform::request_microphone_access() {
            Ok(platform::MicrophoneAccess::Authorized) => {}
            Ok(platform::MicrophoneAccess::Unsupported) => {
                // A stale preference or direct IPC call must not send the
                // macOS 15-only SCK microphone selector on older systems.
                options.captures_microphone = false;
            }
            Ok(platform::MicrophoneAccess::Denied) | Err(_) => {
                let message =
                    "Microphone access is off. Enable Lumen in System Settings to record your microphone.";
                emit_error(
                    &app,
                    message.into(),
                    Some(RecoveryAction::OpenMicrophoneSettings),
                );
                return Err(message.into());
            }
        }
    }

    if options.captures_microphone {
        if let Err(error) = crate::microphone::devices::validate_selection(options.microphone_device_id.as_deref()) {
            let notice = recording_start_error_notice(&error.to_string(), false);
            emit_error(&app, notice.clone(), None);
            return Err(notice);
        }
    }

    let (
        screen_frame,
        backing_scale,
        overlay_labels,
        recording_session_id,
    ) = {
        let state = app.state::<AppState>();
        let _transition = state.library_transition.lock().unwrap();
        {
            let mut context = state.library.lock().unwrap();
            context.library().map_err(|error| error.to_string())?;
        }
        let mut capture = state.capture.lock().unwrap();
        // Recording always uses the display owned by the overlay that asked
        // for it; a peer overlay on another screen never supplies geometry.
        let display = capture
            .session
            .as_ref()
            .and_then(|session| session.display_for_overlay(window.label()))
            .cloned()
            .ok_or_else(|| "No active capture session.".to_string())?;
        let Some(session) = capture.session.take() else {
            return Err("No active capture session.".into());
        };
        drop(capture);
        let completion_monitor = app
            .get_webview_window(window.label())
            .and_then(|window| window.current_monitor().ok().flatten());
        let overlay_labels: Vec<String> =
            session.overlay_labels().map(str::to_string).collect();
        *state.saved_recording_options.lock().unwrap() = saved_options.clone();
        let mut recording = state.recording.lock().unwrap();
        *recording = RecordingFlow {
            session_id: uuid::Uuid::new_v4(),
            return_pid: session.return_pid,
            was_kiri_frontmost: session.was_kiri_frontmost,
            is_starting: true,
            completion_monitor,
            configuration: Some(RecordingConfiguration {
                display_id: display.display_id,
                display_identity: display.display_identity.clone(),
                region: Rect::new(
                    request.region.x,
                    request.region.y,
                    request.region.width,
                    request.region.height,
                ),
                screen_frame: display.screen_frame,
                backing_scale: display.backing_scale,
                options: options.clone(),
            }),
            ..Default::default()
        };
        emit_recording_state(&app, &recording);
        invalidate_capture_resources(&app, &session);
        sync_pin_capture_gate(&app);
        (
            display.screen_frame,
            display.backing_scale,
            overlay_labels,
            recording.session_id,
        )
    };

    let region = request.region.clone();
    let uses_countdown = options.uses_countdown;
    let present_recording_ui = {
        let app = app.clone();
        let overlay_labels = overlay_labels.clone();
        move || -> Result<(), String> {
            for label in &overlay_labels {
                if let Some(window) = app.get_webview_window(label) {
                    #[cfg(target_os = "linux")]
                    platform::linux::hide_window_for_capture(&window)
                        .map_err(|error| error.to_string())?;
                    let _ = window.close();
                }
            }
            if uses_countdown {
                create_countdown_window(&app, screen_frame, backing_scale, &region)?;
            }
            Ok(())
        }
    };
    #[cfg(target_os = "linux")]
    if let Err(error) = linux_run_on_main(&app, present_recording_ui) {
        // Hide failure must not leave an armed recorder or stale overlay. The
        // session ID prevents a late failure from cancelling a replacement.
        for label in &overlay_labels {
            if let Some(window) = app.get_webview_window(label) {
                let _ = window.close();
            }
        }
        let still_current = app
            .state::<AppState>()
            .recording
            .lock()
            .unwrap()
            .pending_start_is_current(recording_session_id);
        if still_current {
            let _ = cancel_recording_flow(app.clone(), recording_session_id).await;
            emit_error(&app, "Could not start screen recording.".into(), None);
        }
        return Err(error);
    }
    #[cfg(not(target_os = "linux"))]
    present_recording_ui()?;

    crate::state::save_recording_options(&app, &saved_options);

    if !options.uses_countdown {
        // No countdown requested: start recording immediately.
        return begin_recording(app, Some(recording_session_id)).await;
    }

    // React reveals/focuses the window after mounting its controls. Do not
    // spend the three-second interval loading a hidden/lazy WebView.
    Ok(())
}

fn create_countdown_window(
    app: &AppHandle,
    screen_frame: Rect,
    backing_scale: f64,
    region: &RectDto,
) -> Result<(), String> {
    let label = "countdown".to_string();
    let session_id = app.state::<AppState>().recording.lock().unwrap().session_id;
    let region_screen = Rect::new(
        screen_frame.x + region.x,
        screen_frame.y + region.y,
        region.width,
        region.height,
    );
    log::info!(
        "create countdown window: screen_frame=({:.0},{:.0}) region=({:.0},{:.0}) → window at ({:.0},{:.0} {:.0}x{:.0})",
        screen_frame.x,
        screen_frame.y,
        region.x,
        region.y,
        region_screen.x,
        region_screen.y,
        region_screen.width,
        region_screen.height,
    );
    let builder = WebviewWindowBuilder::new(
        app,
        label.clone(),
        WebviewUrl::App(format!("index.html?window=countdown&session={session_id}").into()),
    )
    .title("Lumen")
    // Cover the whole display so the countdown badge is centered on the
    // SCREEN, not on the selected region (the user's expectation).
    .inner_size(screen_frame.width, screen_frame.height)
    .position(screen_frame.x, screen_frame.y)
    .visible(false)
    .focused(false)
    .decorations(false)
    .transparent(true)
    .always_on_top(true)
    .skip_taskbar(true)
    .shadow(false);
    let window = match builder.build() {
        Ok(window) => window,
        Err(error) => {
            reset_recording_session(app);
            return Err(error.to_string());
        }
    };
    if let Err(error) = platform::place_transient_window(&window, screen_frame, backing_scale) {
        let _ = window.close();
        reset_recording_session(app);
        return Err(error.to_string());
    }
    #[cfg(target_os = "linux")]
    platform::configure_transient_window(
        &window,
        platform::TransientWindowRole::RecordingCountdown,
    );
    Ok(())
}

#[tauri::command]
pub async fn recording_countdown_ready(
    app: AppHandle,
    window: WebviewWindow,
    session_id: uuid::Uuid,
) -> Result<(), String> {
    if window.label() != "countdown" {
        return Err("Only the countdown can present itself.".into());
    }
    let configuration = {
        let state = app.state::<AppState>();
        let recording = state.recording.lock().unwrap();
        if !recording.pending_start_is_current(session_id) || recording.startup_token.is_some() {
            return Err("The recording countdown is no longer active.".into());
        }
        recording.configuration.clone().unwrap()
    };
    platform::place_transient_window(
        &window,
        configuration.screen_frame,
        configuration.backing_scale,
    )
    .map_err(|error| error.to_string())?;
    platform::set_window_capture_excluded(&app, "countdown", true);
    platform::configure_transient_window(
        &window,
        platform::TransientWindowRole::RecordingCountdown,
    );
    #[cfg(target_os = "linux")]
    linux_run_on_main(&app, move || {
        platform::linux::show_recording_countdown(&window).map_err(|error| error.to_string())
    })?;
    #[cfg(not(target_os = "linux"))]
    {
        window.show().map_err(|error| error.to_string())?;
        window.set_focus().map_err(|error| error.to_string())?;
    }
    Ok(())
}

#[tauri::command]
pub fn get_recording_state(app: AppHandle) -> crate::state::RecordingStateDto {
    let state = app.state::<AppState>();
    let recording = state.recording.lock().unwrap();
    crate::state::recording_state(&recording)
}

#[tauri::command]
pub async fn cancel_recording_flow(app: AppHandle, session_id: uuid::Uuid) -> Result<(), String> {
    let abandoned = {
        let state = app.state::<AppState>();
        let mut recording = state.recording.lock().unwrap();
        if !recording.pending_start_is_current(session_id) {
            return Ok(());
        }
        let abandoned = recording.take_and_reset();
        emit_recording_state(&app, &recording);
        abandoned
    };
    let return_pid = abandoned.return_pid;
    let was_kiri_frontmost = abandoned.was_kiri_frontmost;
    cleanup_abandoned_recording(&app, abandoned);
    if !was_kiri_frontmost {
        if let Some(pid) = return_pid {
            platform::activate_application(pid);
        }
    }
    Ok(())
}

fn close_recording_windows(app: &AppHandle) {
    for label in ["countdown", "control-panel", "recording-region", "ripple"] {
        if let Some(window) = app.get_webview_window(label) {
            let _ = window.close();
        }
    }
}

fn stop_click_monitor(app: &AppHandle) {
    let monitor = {
        let state = app.state::<AppState>();
        let monitor = state.click_monitor.lock().unwrap().take();
        monitor
    };
    if let Some(monitor) = monitor {
        monitor.stop();
    }
}

fn discard_active_recording(mut active: ActiveRecording) {
    if let Some(mut recorder) = active.recorder.take() {
        let _ = recorder.stop();
    }
    if let Some(encoder) = active.encoder.take() {
        encoder.cancel();
    }
}

fn cleanup_abandoned_recording(app: &AppHandle, abandoned: RecordingFlow) {
    stop_click_monitor(app);
    close_recording_windows(app);
    if let Some(active) = abandoned.active {
        discard_active_recording(active);
    }
    for path in abandoned.segments {
        let _ = std::fs::remove_file(path);
    }
}

/// Aborts a recording and returns every session-owned resource to idle so no
/// spinner, overlay, click monitor, encoder, or partial segment survives.
fn reset_recording_session(app: &AppHandle) {
    let abandoned = {
        let state = app.state::<AppState>();
        let mut recording = state.recording.lock().unwrap();
        let abandoned = recording.take_and_reset();
        emit_recording_state(app, &recording);
        abandoned
    };
    cleanup_abandoned_recording(app, abandoned);
}

fn take_completed_recording_segments(app: &AppHandle) -> Vec<PathBuf> {
    let state = app.state::<AppState>();
    let mut recording = state.recording.lock().unwrap();
    recording.take_completed_segments()
}

/// Imports every segment that was completed before the active segment failed.
/// `finalize_recording` removes source files only after the library import is
/// durable; on an import failure the valid temporary files remain intact for
/// recovery instead of being erased by the generic session reset.
fn recover_completed_recording(
    app: &AppHandle,
    completed_segments: Vec<PathBuf>,
) -> Result<bool, String> {
    if completed_segments.is_empty() {
        return Ok(false);
    }
    finalize_recording(
        app,
        completed_segments,
        RecordingOutputFormat::Mp4,
        false,
        None,
    )
    .map(|_| true)
    .map_err(|error| error.to_string())
}

/// Resets only the startup task that still owns this session. A late download
/// failure from a cancelled task must not tear down a replacement recording.
fn reset_startup_if_current(app: &AppHandle, token: uuid::Uuid) -> bool {
    let abandoned = {
        let state = app.state::<AppState>();
        let mut recording = state.recording.lock().unwrap();
        let abandoned = recording.take_if_startup_is_current(token);
        if abandoned.is_some() {
            emit_recording_state(app, &recording);
        }
        abandoned
    };
    if let Some(abandoned) = abandoned {
        cleanup_abandoned_recording(app, abandoned);
        true
    } else {
        false
    }
}

fn show_recording_startup_failure(app: &AppHandle, token: uuid::Uuid, message: String, recovery: Option<crate::state::RecoveryAction>) -> bool {
    let monitor = app.state::<AppState>().recording.lock().unwrap().completion_monitor.clone();
    if !reset_startup_if_current(app, token) { return false; }
    emit_error(app, message.clone(), recovery);
    let mut preview = CompletionPreviewDto::processing(
        uuid::Uuid::new_v4().to_string(), "video", &message,
        "Check recording options and try again. If it still fails, copy info from Settings → About.",
    );
    preview.phase = "failed".into();
    show_completion_preview(app, &preview, monitor);
    true
}

fn startup_is_current(app: &AppHandle, token: uuid::Uuid) -> bool {
    let state = app.state::<AppState>();
    let recording = state.recording.lock().unwrap();
    recording.startup_is_current(token)
}

fn recover_failed_resume(app: &AppHandle) {
    let stale_active = {
        let state = app.state::<AppState>();
        let mut recording = state.recording.lock().unwrap();
        let stale_active = recording.recover_failed_resume();
        emit_recording_state(app, &recording);
        stale_active
    };
    if let Some(active) = stale_active {
        discard_active_recording(active);
    }
}

#[cfg(not(target_os = "linux"))]
fn create_control_panel(
    app: &AppHandle,
    configuration: &RecordingConfiguration,
    session_id: uuid::Uuid,
) -> Result<(), String> {
    let region = recording_region_frame(configuration);
    let frame = crate::core::recording_controls::controls_frame(
        configuration.screen_frame, region, (296.0, 52.0), None,
    );
    let panel = WebviewWindowBuilder::new(
        app,
        "control-panel".to_string(),
        WebviewUrl::App(format!("index.html?window=control-panel&session={session_id}").into()),
    )
    .title("Lumen")
    .inner_size(frame.width, frame.height)
    .position(frame.x, frame.y)
    .visible(false)
    .focused(false)
    .decorations(false)
    .transparent(true)
    .always_on_top(true)
    .skip_taskbar(true)
    .shadow(false)
    .build()
    .map_err(|e| e.to_string())?;
    if let Err(error) =
        platform::place_transient_window(&panel, frame, configuration.backing_scale)
    {
        let _ = panel.close();
        return Err(error.to_string());
    }
    platform::set_window_capture_excluded(app, "control-panel", true);
    // macOS transient policy orders the window front. Apply it only after
    // the renderer has measured its translated controls, immediately below.
    Ok(())
}

fn recording_region_frame(configuration: &RecordingConfiguration) -> Rect {
    Rect::new(configuration.screen_frame.x + configuration.region.x,
        configuration.screen_frame.y + configuration.region.y,
        configuration.region.width, configuration.region.height)
}

#[tauri::command]
pub fn position_recording_controls(
    app: AppHandle, window: WebviewWindow, session_id: uuid::Uuid,
    width: f64, height: f64, content_scale: f64, preserve_position: bool,
) -> Result<RecordingControlsLayout, String> {
    if window.label() != "control-panel" {
        return Err("This command is unavailable from this window.".into());
    }
    if !width.is_finite() || !height.is_finite() || !content_scale.is_finite()
        || !(96.0..=640.0).contains(&width) || !(40.0..=96.0).contains(&height)
        || !(0.5..=8.0).contains(&content_scale) {
        return Err("Invalid recording control dimensions.".into());
    }
    let configuration = {
        let state = app.state::<AppState>();
        let recording = state.recording.lock().unwrap();
        if recording.session_id != session_id || recording.is_finalizing {
            return Err("This recording is no longer active.".into());
        }
        recording.configuration.clone().ok_or("This recording is no longer active.")?
    };
    // Native monitor/window calls can dispatch to the UI thread; never keep
    // the recording mutex while waiting for them.
    let monitor = if preserve_position {
        window.current_monitor().ok().flatten()
    } else {
        app.available_monitors().ok().and_then(|monitors| monitors.into_iter().find(|monitor| {
            let p = monitor.position(); let s = monitor.size();
            crate::core::recording_controls::monitor_contains_screen(
                configuration.screen_frame, configuration.backing_scale,
                Rect::new(f64::from(p.x), f64::from(p.y), f64::from(s.width), f64::from(s.height)),
                monitor.scale_factor(),
            )
        }))
    };
    let scale = monitor.as_ref().map(Monitor::scale_factor).unwrap_or(configuration.backing_scale);
    let work_area = monitor.as_ref().map(|monitor| {
        let area = monitor.work_area();
        Rect::new(f64::from(area.position.x) / scale, f64::from(area.position.y) / scale,
            f64::from(area.size.width) / scale, f64::from(area.size.height) / scale)
    }).unwrap_or(configuration.screen_frame);
    let preferred = if preserve_position {
        let position = window.outer_position().map_err(|error| error.to_string())?;
        Some((f64::from(position.x) / scale, f64::from(position.y) / scale))
    } else { None };
    // WebView2 may include accessibility text scaling in its CSS pixel ratio.
    // Measure rendered content, rather than assuming it equals monitor DPI.
    let frame = crate::core::recording_controls::controls_frame(work_area,
        recording_region_frame(&configuration), (width * content_scale / scale, height * content_scale / scale), preferred);
    #[cfg(target_os = "macos")]
    {
        // Tao converts physical positions using the window's current scale,
        // which may still belong to the display we are moving away from.
        window.set_position(tauri::LogicalPosition::new(frame.x, frame.y)).map_err(|error| error.to_string())?;
        window.set_size(tauri::LogicalSize::new(frame.width, frame.height)).map_err(|error| error.to_string())?;
    }
    #[cfg(not(target_os = "macos"))]
    {
        window.set_position(tauri::PhysicalPosition::new((frame.x * scale).round() as i32,
            (frame.y * scale).round() as i32)).map_err(|error| error.to_string())?;
        window.set_size(tauri::PhysicalSize::new((frame.width * scale).round() as u32,
            (frame.height * scale).round() as u32)).map_err(|error| error.to_string())?;
    }
    let present = {
        let state = app.state::<AppState>();
        let mut recording = state.recording.lock().unwrap();
        recording.claim_controls_presentation(session_id)
    };
    if present {
        platform::show_window_without_activation(&app, "control-panel",
            platform::TransientWindowRole::RecordingControls);
    }
    let margin = 8.0_f64.min(work_area.width / 4.0).min(work_area.height / 4.0);
    Ok(RecordingControlsLayout {
        max_width: ((work_area.width - margin * 2.0).max(1.0) * scale / content_scale).floor(),
    })
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RecordingControlsLayout {
    max_width: f64,
}

#[cfg(not(target_os = "linux"))]
fn create_recording_region(app: &AppHandle, configuration: &RecordingConfiguration) -> Result<(), String> {
    #[cfg(windows)]
    {
        // Before Windows 10 2004, EXCLUDEFROMCAPTURE behaves like MONITOR,
        // which would black out a full transparent region window in video.
        // Keep the OS indicator on those systems instead of obscuring footage.
        use windows::Wdk::System::SystemServices::RtlGetVersion;
        use windows::Win32::System::SystemInformation::OSVERSIONINFOW;
        let mut version = OSVERSIONINFOW { dwOSVersionInfoSize: std::mem::size_of::<OSVERSIONINFOW>() as u32, ..Default::default() };
        if unsafe { RtlGetVersion(&mut version) }.is_err() || version.dwBuildNumber < 19041 {
            return Ok(());
        }
    }
    let frame = recording_region_frame(configuration);
    let window = WebviewWindowBuilder::new(app, "recording-region",
        WebviewUrl::App("index.html?window=recording-region".into()))
        .title("Lumen").inner_size(frame.width, frame.height).position(frame.x, frame.y)
        .visible(false).focused(false).focusable(false).decorations(false)
        .transparent(true).always_on_top(true).skip_taskbar(true).shadow(false).build()
        .map_err(|error| error.to_string())?;
    let prepare = || -> Result<(), String> {
        platform::place_transient_window(&window, frame, configuration.backing_scale).map_err(|error| error.to_string())?;
        #[cfg(windows)]
        {
            window.set_content_protected(true).map_err(|error| error.to_string())?;
            platform::windows::pin_webview_to_display_scale(&window, configuration.backing_scale);
        }
        window.set_ignore_cursor_events(true).map_err(|error| error.to_string())?;
        platform::configure_transient_window(&window, platform::TransientWindowRole::RecordingRegion);
        window.show().map_err(|error| error.to_string())
    };
    if let Err(error) = prepare() { let _ = window.close(); return Err(error); }
    Ok(())
}

fn create_ripple_window(
    app: &AppHandle,
    configuration: &RecordingConfiguration,
) -> Result<(), String> {
    let region = configuration.region;
    let frame = configuration.screen_frame;
    let ripple = WebviewWindowBuilder::new(
        app,
        "ripple".to_string(),
        WebviewUrl::App("index.html?window=ripple".into()),
    )
    .title("Lumen")
    .inner_size(region.width, region.height)
    .position(frame.x + region.x, frame.y + region.y)
    .decorations(false)
    .transparent(true)
    .always_on_top(true)
    .focused(false)
    .skip_taskbar(true)
    .shadow(false)
    .build()
    .map_err(|e| e.to_string())?;
    let ripple_frame = Rect::new(
        frame.x + region.x,
        frame.y + region.y,
        region.width,
        region.height,
    );
    if let Err(error) =
        platform::place_transient_window(&ripple, ripple_frame, configuration.backing_scale)
    {
        let _ = ripple.close();
        return Err(error.to_string());
    }
    platform::configure_transient_window(&ripple, platform::TransientWindowRole::ClickRipple);
    platform::set_window_click_through(app, "ripple");
    Ok(())
}

struct StartedRecorder {
    recorder: Box<dyn crate::capture::PlatformRecorder + Send>,
    system_audio_spec: Option<crate::record::AudioSpec>,
    microphone_spec: Option<crate::record::AudioSpec>,
}

struct RecorderSenders {
    video: crate::capture::VideoFrameSender,
    system_audio: Option<crate::record::AudioChunkSender>,
    microphone: Option<crate::record::AudioChunkSender>,
}

struct EncoderReceivers {
    video: mpsc::Receiver<Vec<u8>>,
    system_audio: Option<crate::record::AudioChunkReceiver>,
    microphone: Option<crate::record::AudioChunkReceiver>,
}

fn recording_channels(options: RecordingOptions) -> (RecorderSenders, EncoderReceivers) {
    let (video_tx, video_rx) = mpsc::sync_channel(crate::capture::VIDEO_FRAME_QUEUE_CAPACITY);
    let (audio_tx, audio_rx) = (options.captures_system_audio && !cfg!(target_os = "linux"))
        .then(crate::record::bounded_audio_channel)
        .map(|(tx, rx)| (Some(tx), Some(rx)))
        .unwrap_or((None, None));
    let (mic_tx, mic_rx) = (options.captures_microphone && !cfg!(target_os = "linux"))
        .then(crate::record::bounded_audio_channel)
        .map(|(tx, rx)| (Some(tx), Some(rx)))
        .unwrap_or((None, None));
    (
        RecorderSenders {
            video: video_tx,
            system_audio: audio_tx,
            microphone: mic_tx,
        },
        EncoderReceivers {
            video: video_rx,
            system_audio: audio_rx,
            microphone: mic_rx,
        },
    )
}

fn recording_encoder_error_notice(error: &str) -> String {
    if error.contains(crate::microphone::devices::SELECTED_UNAVAILABLE) {
        return crate::microphone::devices::SELECTED_UNAVAILABLE.into();
    }
    #[cfg(target_os = "linux")]
    for message in [
        crate::linux_audio::AUDIO_UNAVAILABLE,
        crate::linux_audio::MICROPHONE_UNAVAILABLE,
        crate::linux_audio::AUDIO_RECORDING_FAILED,
    ] {
        if error.contains(message) {
            return message.into();
        }
    }
    let _ = error;
    "Could not start the video encoder.".into()
}

fn recording_start_error_notice(error: &str, resuming: bool) -> String {
    if error.contains(crate::microphone::devices::SELECTED_UNAVAILABLE) {
        return crate::microphone::devices::SELECTED_UNAVAILABLE.into();
    }
    // Only known recovery guidance crosses the public notice boundary;
    // arbitrary native errors can contain implementation details.
    #[cfg(target_os = "macos")]
    if matches!(
        error,
        "The selected display geometry changed. Start a new capture before recording."
            | "The selected display is no longer available. Start a new capture."
    ) {
        return if resuming {
            "The selected display changed or is no longer available. Stop and save the paused recording, then start a new capture.".into()
        } else {
            error.to_string()
        };
    }
    match error {
        "No system-audio output device is available." => "No system-audio output device is available.".into(),
        "No microphone input device is available." => "No microphone input device is available.".into(),
        "The selected display changed or is no longer uniquely available. Select it again."
        | "The selected display is no longer available. Select it again."
        | "The selected display is ambiguous. Select it again."
        | "The selected display identity is unavailable. Select it again." => {
            if resuming {
                "The selected display changed or is no longer available. Stop and save the paused recording, then start a new capture.".into()
            } else {
                "The selected display is no longer available. Start a new capture.".into()
            }
        }
        _ => "Could not start screen recording.".into(),
    }
}

fn start_recorder(
    app: &AppHandle,
    configuration: &RecordingConfiguration,
    senders: RecorderSenders,
) -> Result<StartedRecorder, String> {
    #[cfg(any(windows, target_os = "linux"))]
    let _ = app;
    #[cfg(target_os = "macos")]
    let ripple_excepted = platform::window_capture_id(app, "ripple")
        .into_iter()
        .collect::<Vec<_>>();
    #[cfg(target_os = "macos")]
    {
        let recorder = crate::capture::macos::MacRecordingSession::start(
            configuration.display_id,
            configuration.screen_frame,
            configuration.region,
            configuration.backing_scale,
            configuration.options.clone(),
            &ripple_excepted,
            senders.video,
            senders.system_audio,
            senders.microphone,
        )
        .map_err(|e| e.to_string())?;
        let float_audio = crate::record::AudioSpec {
            sample_rate: 48_000,
            channels: 2,
            format: crate::record::AudioSampleFormat::F32,
        };
        Ok(StartedRecorder {
            recorder: Box::new(recorder),
            system_audio_spec: configuration
                .options
                .captures_system_audio
                .then_some(float_audio),
            microphone_spec: configuration
                .options
                .captures_microphone
                .then_some(float_audio),
        })
    }
    #[cfg(windows)]
    {
        let display_identity = configuration.display_identity.as_ref().ok_or_else(|| {
            "The selected display identity is unavailable. Select it again.".to_string()
        })?;
        let recorder = crate::capture::windows::WindowsRecorder::start(
            display_identity,
            configuration.region,
            configuration.backing_scale,
            configuration.options.clone(),
            senders.video,
            senders.system_audio,
            senders.microphone,
        )
        .map_err(|e| e.to_string())?;
        let system_audio_spec = recorder.system_audio_spec();
        let microphone_spec = recorder.microphone_spec();
        Ok(StartedRecorder {
            recorder: Box::new(recorder),
            system_audio_spec,
            microphone_spec,
        })
    }
    #[cfg(target_os = "linux")]
    {
        let recorder = crate::capture::linux::LinuxRecorder::start(
            configuration
                .display_identity
                .clone()
                .ok_or("The captured Linux display could not be identified.")?,
            configuration.region,
            configuration.backing_scale,
            configuration.options.clone(),
            senders.video,
            senders.system_audio,
            senders.microphone,
        )
        .map_err(|e| e.to_string())?;
        Ok(StartedRecorder {
            recorder: Box::new(recorder),
            system_audio_spec: configuration.options.captures_system_audio
                .then_some(crate::linux_audio::AUDIO_SPEC),
            microphone_spec: configuration.options.captures_microphone
                .then_some(crate::linux_audio::AUDIO_SPEC),
        })
    }
}

fn start_encoder(
    prepared: &PreparedEncoder,
    configuration: &RecordingConfiguration,
    out_path: PathBuf,
    receivers: EncoderReceivers,
    recorder: &StartedRecorder,
) -> Result<crate::record::SegmentEncoder, String> {
    let width = crate::core::policy::RecordingPolicy::pixel_dimension(
        configuration.region.width,
        configuration.backing_scale,
    );
    let height = crate::core::policy::RecordingPolicy::pixel_dimension(
        configuration.region.height,
        configuration.backing_scale,
    );
    let encoder_config = crate::record::EncoderConfig {
        width,
        height,
        fps: crate::core::policy::RecordingPolicy::FRAMES_PER_SECOND,
        bitrate: crate::record::bitrate_for(width, height),
        audio: recorder.system_audio_spec,
        mic: recorder.microphone_spec,
        #[cfg(target_os = "linux")]
        microphone_device_id: configuration.options.microphone_device_id.clone(),
    };
    match prepared {
        #[cfg(target_os = "macos")]
        PreparedEncoder::MacosNative => {
            log::info!(
                "start_encoder: AVFoundation H.264 {}x{}@{}, audio={}, mic={}",
                encoder_config.width,
                encoder_config.height,
                encoder_config.fps,
                encoder_config.audio.is_some(),
                encoder_config.mic.is_some(),
            );
            crate::record::SegmentEncoder::start_macos_native(
                &encoder_config,
                out_path,
                receivers.video,
                receivers.system_audio,
                receivers.microphone,
            )
            .map_err(|e| e.to_string())
        }
        #[cfg(windows)]
        PreparedEncoder::WindowsNative => {
            log::info!(
                "start_encoder: Windows Media Foundation H.264 {}x{}@{}, audio={}, mic={}",
                encoder_config.width,
                encoder_config.height,
                encoder_config.fps,
                encoder_config.audio.is_some(),
                encoder_config.mic.is_some(),
            );
            crate::record::SegmentEncoder::start_windows_native(
                &encoder_config,
                out_path,
                receivers.video,
                receivers.system_audio,
                receivers.microphone,
            )
            .map_err(|e| e.to_string())
        }
        #[cfg(target_os = "linux")]
        PreparedEncoder::LinuxNative => {
            log::info!(
                "start_encoder: Linux GStreamer H.264 {}x{}@{}, audio={}, mic={}",
                encoder_config.width,
                encoder_config.height,
                encoder_config.fps,
                encoder_config.audio.is_some(),
                encoder_config.mic.is_some(),
            );
            crate::record::SegmentEncoder::start_linux_native(
                &encoder_config,
                out_path,
                receivers.video,
                receivers.system_audio,
                receivers.microphone,
            )
            .map_err(|e| e.to_string())
        }
    }
}

enum PreparedEncoder {
    #[cfg(target_os = "macos")]
    MacosNative,
    #[cfg(windows)]
    WindowsNative,
    #[cfg(target_os = "linux")]
    LinuxNative,
}

async fn prepare_encoder(
    _app: AppHandle,
    _output_format: RecordingOutputFormat,
) -> Result<PreparedEncoder, String> {
    #[cfg(windows)]
    {
        let _ = (_app, _output_format);
        return Ok(PreparedEncoder::WindowsNative);
    }
    #[cfg(target_os = "macos")]
    {
        let _ = (_app, _output_format);
        Ok(PreparedEncoder::MacosNative)
    }
    #[cfg(target_os = "linux")]
    {
        let _ = (_app, _output_format);
        Ok(PreparedEncoder::LinuxNative)
    }
}

fn spawn_recording_clock(app: &AppHandle, session_id: uuid::Uuid) {
    let handle = app.clone();
    std::thread::spawn(move || loop {
        std::thread::sleep(std::time::Duration::from_millis(250));
        #[cfg(target_os = "linux")]
        if let Err(error) = stop_failed_linux_recording(&handle, session_id) {
            log::error!("recording: failed Linux session cleanup: {error}");
        }
        let should_continue = {
            let state = handle.state::<AppState>();
            let recording = state.recording.lock().unwrap();
            if recording.session_id != session_id
                || recording.configuration.is_none()
                || recording.is_finalizing
            {
                false
            } else if recording.is_recording && !recording.is_paused {
                emit_recording_state(&handle, &recording);
                true
            } else {
                // Keep the one session clock alive across pause/resume
                // transitions; paused time is excluded by recording_state().
                true
            }
        };
        if !should_continue {
            break;
        }
    });
}

#[tauri::command]
pub async fn begin_recording(app: AppHandle, session_id: Option<uuid::Uuid>) -> Result<(), String> {
    log::info!("begin_recording: called");
    let (startup_token, configuration, session_id) = {
        let state = app.state::<AppState>();
        let mut recording = state.recording.lock().unwrap();
        if session_id.is_some_and(|id| !recording.pending_start_is_current(id)) {
            return Ok(());
        }
        if recording.is_recording || recording.is_paused {
            return Ok(());
        }
        let Some(configuration) = recording.configuration.clone() else {
            return Err("No recording configuration.".into());
        };
        let Some(token) = recording.claim_startup() else {
            // Another begin request already owns this session, or the flow is
            // transitioning/finalizing. Treat duplicate IPC as idempotent.
            return Ok(());
        };
        emit_recording_state(&app, &recording);
        (token, configuration, recording.session_id)
    };

    // Claim first: a late completion from an old WebView cannot close the
    // countdown belonging to a newer recording.
    let present_controls = {
        let app = app.clone();
        let configuration = configuration.clone();
        move || -> Result<(), String> {
            if let Some(window) = app.get_webview_window("countdown") {
                #[cfg(target_os = "linux")]
                platform::linux::hide_window_for_capture(&window)
                    .map_err(|error| error.to_string())?;
                let _ = window.close();
            }
            #[cfg(target_os = "linux")]
            if let Some(window) = app.get_webview_window("toast") {
                platform::linux::hide_window_for_capture(&window)
                    .map_err(|error| error.to_string())?;
            }
            #[cfg(not(target_os = "linux"))]
            {
                if let Err(error) = create_recording_region(&app, &configuration) {
                    log::warn!("recording region indicator unavailable: {error}");
                }
                create_control_panel(&app, &configuration, session_id)?;
            }
            if configuration.options.highlights_clicks {
                create_ripple_window(&app, &configuration)?;
            }
            Ok(())
        }
    };
    #[cfg(target_os = "linux")]
    if let Err(error) = linux_run_on_main(&app, present_controls) {
        if show_recording_startup_failure(&app, startup_token, "Could not start screen recording.".into(), None) {
            return Err(error);
        }
        return Ok(());
    }
    #[cfg(not(target_os = "linux"))]
    if let Err(error) = present_controls() {
        if show_recording_startup_failure(&app, startup_token, "Could not start screen recording.".into(), None) {
            return Err(error);
        }
        return Ok(());
    }
    {
        // Countdown owns Escape until it has been hidden. Restoring the source
        // during countdown creation can race its ready/focus command. Respect
        // any application the user deliberately switched to during countdown.
        let frontmost_pid = platform::frontmost_application().map(|(pid, _)| pid);
        let return_pid = {
            let state = app.state::<AppState>();
            let recording = state.recording.lock().unwrap();
            if recording.session_id == session_id && recording.startup_is_current(startup_token) {
                recording.recording_origin_to_restore(frontmost_pid)
            } else {
                None
            }
        };
        if let Some(pid) = return_pid {
            platform::activate_application(pid);
        }
    }
    if configuration.options.highlights_clicks {
        // The click monitor needs the Input Monitoring permission; install
        // it only while highlighting clicks (avoids a permission prompt at
        // every launch).
        if let Err(error) = crate::ensure_click_monitor(&app) {
            log::error!("recording: global click monitor unavailable: {error}");
            let message = "Input Monitoring is off. Enable Lumen in System Settings to highlight clicks while recording.";
            #[cfg(target_os = "macos")]
            let recovery = Some(RecoveryAction::OpenInputMonitoringSettings);
            #[cfg(any(windows, target_os = "linux"))]
            let recovery = None;
            if show_recording_startup_failure(&app, startup_token, message.into(), recovery) {
                return Err(error.to_string());
            }
            return Ok(());
        }
    }

    // Windows MP4 and GIF sessions both start with the native Media Foundation
    // MP4 fallback, so encoder preparation is immediate and offline. Other
    // platform-native encoder setup finishes before capture begins.
    let prepared = match prepare_encoder(app.clone(), configuration.options.output_format).await {
        Ok(prepared) => prepared,
        Err(error) => {
            log::error!("recording: encoder preparation failed: {error}");
            if show_recording_startup_failure(&app, startup_token, "Could not start the video encoder.".into(), None) {
                return Err(error);
            }
            return Ok(());
        }
    };

    if !startup_is_current(&app, startup_token) {
        return Ok(());
    }

    let out_path = std::env::temp_dir().join(format!(
        "kiri-recording-{}.mp4",
        uuid::Uuid::new_v4().to_string().to_lowercase()
    ));

    let (senders, receivers) = recording_channels(configuration.options.clone());
    let mut started = match start_recorder(&app, &configuration, senders) {
        Ok(started) => started,
        Err(error) => {
            log::error!("recording: start_recorder failed: {error}");
            if show_recording_startup_failure(&app, startup_token, recording_start_error_notice(&error, false), None) {
                return Err(error);
            }
            return Ok(());
        }
    };
    if !startup_is_current(&app, startup_token) {
        let _ = started.recorder.stop();
        let _ = std::fs::remove_file(out_path);
        return Ok(());
    }
    let encoder = match start_encoder(
        &prepared,
        &configuration,
        out_path.clone(),
        receivers,
        &started,
    ) {
        Ok(encoder) => encoder,
        Err(error) => {
            log::error!("recording: start_encoder failed: {error}");
            let _ = started.recorder.stop();
            let _ = std::fs::remove_file(&out_path);
            if show_recording_startup_failure(&app, startup_token, recording_encoder_error_notice(&error), None) {
                return Err(error);
            }
            return Ok(());
        }
    };

    let stale_active = {
        let state = app.state::<AppState>();
        let mut recording = state.recording.lock().unwrap();
        let active = ActiveRecording {
            encoder: Some(encoder),
            recorder: Some(started.recorder),
        };
        match recording.complete_startup(startup_token, active) {
            Ok(()) => {
                emit_recording_state(&app, &recording);
                None
            }
            Err(active) => Some(active),
        }
    };
    if let Some(active) = stale_active {
        discard_active_recording(active);
        let _ = std::fs::remove_file(out_path);
        return Ok(());
    }

    // A single session-owned clock survives pause/resume and refreshes the
    // control panel without counting paused time.
    spawn_recording_clock(&app, session_id);

    emit_notice(
        &app,
        "Recording Started".into(),
        "record.circle.fill".into(),
    );
    Ok(())
}

#[tauri::command]
pub async fn pause_recording(app: AppHandle) -> Result<(), String> {
    pause_recording_session(app, None).await
}

async fn pause_recording_session(app: AppHandle, expected_session: Option<uuid::Uuid>) -> Result<(), String> {
    log::info!("pause_recording: called");
    let active = {
        let state = app.state::<AppState>();
        let mut recording = state.recording.lock().unwrap();
        if !recording.accepts_recording_action(expected_session)
            || !recording.is_recording || recording.is_transitioning {
            return Ok(());
        }
        recording.elapsed_before_segment = crate::state::recording_state(&recording).elapsed;
        recording.started_at = None;
        recording.is_recording = false;
        recording.is_transitioning = true;
        emit_recording_state(&app, &recording);
        recording.active.take()
    };
    let Some(mut active) = active else {
        let error = "The active recording session is unavailable.".to_string();
        reset_recording_session(&app);
        return Err(error);
    };

    if active
        .encoder
        .as_ref()
        .is_some_and(crate::record::SegmentEncoder::is_windows_native)
    {
        let pause_result = active
            .recorder
            .as_mut()
            .ok_or_else(|| "The native recorder is unavailable.".to_string())
            .and_then(|recorder| recorder.pause().map_err(|error| error.to_string()));
        if let Err(error) = pause_result {
            discard_active_recording(active);
            reset_recording_session(&app);
            return Err(error);
        }
        if let Some(encoder) = active.encoder.as_ref() {
            encoder.set_windows_paused(true);
        }
        let state = app.state::<AppState>();
        let mut recording = state.recording.lock().unwrap();
        recording.active = Some(active);
        recording.is_paused = true;
        recording.is_transitioning = false;
        emit_recording_state(&app, &recording);
        emit_notice(&app, "Recording Paused".into(), "pause.circle.fill".into());
        return Ok(());
    }

    let mut segment_path = None;
    let mut failure = None;
    match active.recorder.take() {
        Some(mut recorder) => {
            if let Err(error) = recorder.stop() {
                failure = Some(error.to_string());
            }
        }
        None => failure = Some("The native recorder is unavailable.".into()),
    }
    if failure.is_none() {
        match active.encoder.take() {
            Some(encoder) => match encoder.finish() {
                Ok(path) => segment_path = Some(path),
                Err(error) => failure = Some(error.to_string()),
            },
            None => failure = Some("The video encoder is unavailable.".into()),
        }
    } else if let Some(encoder) = active.encoder.take() {
        encoder.cancel();
    }
    drop(active);

    if let Some(error) = failure {
        log::error!("recording: current segment failed while pausing: {error}");
        let completed_segments = take_completed_recording_segments(&app);
        reset_recording_session(&app);
        let (message, recovery_error) = match recover_completed_recording(&app, completed_segments) {
            Ok(true) => (
                "The current recording section failed. Earlier completed sections were saved as a partial recording."
                    .to_string(),
                None,
            ),
            Ok(false) => ("Could not pause screen recording.".to_string(), None),
            Err(recovery_error) => (
                "Could not pause screen recording. Lumen kept the completed sections so they are not lost."
                    .to_string(),
                Some(recovery_error),
            ),
        };
        emit_error(&app, message, None);
        return Err(match recovery_error {
            Some(recovery_error) => {
                format!("{error}; partial recording recovery failed: {recovery_error}")
            }
            None => error,
        });
    }
    let state = app.state::<AppState>();
    let mut recording = state.recording.lock().unwrap();
    if let Some(path) = segment_path {
        recording.segments.push(path);
    }
    recording.is_paused = true;
    recording.is_transitioning = false;
    emit_recording_state(&app, &recording);
    emit_notice(&app, "Recording Paused".into(), "pause.circle.fill".into());
    Ok(())
}

#[tauri::command]
pub async fn resume_recording(app: AppHandle) -> Result<(), String> {
    resume_recording_session(app, None).await
}

async fn resume_recording_session(app: AppHandle, expected_session: Option<uuid::Uuid>) -> Result<(), String> {
    log::info!("resume_recording: called");
    let resumed_native = {
        let state = app.state::<AppState>();
        let mut recording = state.recording.lock().unwrap();
        if !recording.accepts_recording_action(expected_session) { return Ok(()); }
        let is_native = recording
            .active
            .as_ref()
            .and_then(|active| active.encoder.as_ref())
            .is_some_and(crate::record::SegmentEncoder::is_windows_native);
        if !recording.is_paused || recording.is_transitioning || !is_native {
            false
        } else {
            let active = recording
                .active
                .as_mut()
                .ok_or_else(|| "The active recording session is unavailable.".to_string())?;
            let recorder = active
                .recorder
                .as_mut()
                .ok_or_else(|| "The native recorder is unavailable.".to_string())?;
            recorder.resume().map_err(|error| error.to_string())?;
            if let Some(encoder) = active.encoder.as_ref() {
                encoder.set_windows_paused(false);
            }
            recording.is_paused = false;
            recording.is_recording = true;
            recording.started_at = Some(std::time::Instant::now());
            emit_recording_state(&app, &recording);
            true
        }
    };
    if resumed_native {
        emit_notice(&app, "Recording Resumed".into(), "play.circle.fill".into());
        return Ok(());
    }

    let configuration = {
        let state = app.state::<AppState>();
        let mut recording = state.recording.lock().unwrap();
        if !recording.accepts_recording_action(expected_session)
            || !recording.is_paused || recording.is_transitioning {
            return Ok(());
        }
        let Some(configuration) = recording.configuration.clone() else {
            return Err("No recording configuration.".into());
        };
        recording.is_transitioning = true;
        emit_recording_state(&app, &recording);
        configuration
    };

    // Resolve the encoder before recreating bounded capture channels. A
    // normal resume hits AppState's initialized path immediately; the async
    // boundary also makes inconsistent/direct IPC fail safely.
    let prepared = match prepare_encoder(app.clone(), configuration.options.output_format).await {
        Ok(prepared) => prepared,
        Err(error) => {
            log::error!("recording: resume encoder preparation failed: {error}");
            emit_error(&app, "Could not prepare the video encoder.".into(), None);
            recover_failed_resume(&app);
            return Err(error);
        }
    };

    let out_path = std::env::temp_dir().join(format!(
        "kiri-recording-{}.mp4",
        uuid::Uuid::new_v4().to_string().to_lowercase()
    ));

    let (senders, receivers) = recording_channels(configuration.options.clone());
    let mut started = match start_recorder(&app, &configuration, senders) {
        Ok(started) => started,
        Err(error) => {
            log::error!("recording: start_recorder failed: {error}");
            emit_error(&app, recording_start_error_notice(&error, true), None);
            recover_failed_resume(&app);
            return Err(error);
        }
    };
    let encoder = match start_encoder(
        &prepared,
        &configuration,
        out_path.clone(),
        receivers,
        &started,
    ) {
        Ok(encoder) => encoder,
        Err(error) => {
            log::error!("recording: start_encoder failed: {error}");
            let _ = started.recorder.stop();
            let _ = std::fs::remove_file(out_path);
            emit_error(&app, recording_encoder_error_notice(&error), None);
            recover_failed_resume(&app);
            return Err(error);
        }
    };

    {
        let state = app.state::<AppState>();
        let mut recording = state.recording.lock().unwrap();
        recording.is_paused = false;
        recording.is_transitioning = false;
        recording.is_recording = true;
        recording.started_at = Some(std::time::Instant::now());
        recording.active = Some(ActiveRecording {
            encoder: Some(encoder),
            recorder: Some(started.recorder),
        });
        emit_recording_state(&app, &recording);
    }
    emit_notice(&app, "Recording Resumed".into(), "play.circle.fill".into());
    Ok(())
}

#[tauri::command]
pub async fn stop_recording(app: AppHandle) -> Result<(), String> {
    stop_recording_session(app, None, None)
}

pub(crate) async fn perform_recording_shortcut(
    app: AppHandle, session_id: uuid::Uuid, action: ShortcutAction, paused: bool,
) -> Result<(), String> {
    match action {
        ShortcutAction::RecordingStop => stop_recording_session(app, None, Some(session_id)),
        ShortcutAction::RecordingPauseResume if paused => resume_recording_session(app, Some(session_id)).await,
        ShortcutAction::RecordingPauseResume => pause_recording_session(app, Some(session_id)).await,
        _ => Ok(()),
    }
}

#[cfg(target_os = "linux")]
fn stop_failed_linux_recording(app: &AppHandle, session_id: uuid::Uuid) -> Result<(), String> {
    stop_recording_session(app.clone(), Some(session_id), Some(session_id))
}

fn stop_recording_session(
    app: AppHandle,
    failed_session: Option<uuid::Uuid>,
    expected_session: Option<uuid::Uuid>,
) -> Result<(), String> {
    if failed_session.is_none() {
        log::info!("stop_recording: called");
    }
    let abandoned_startup = {
        let state = app.state::<AppState>();
        let mut recording = state.recording.lock().unwrap();
        if !recording.accepts_recording_action(expected_session) { return Ok(()); }
        if failed_session.is_none()
            && recording.is_starting
            && !recording.is_recording
            && !recording.is_paused
        {
            let abandoned = recording.take_and_reset();
            emit_recording_state(&app, &recording);
            Some(abandoned)
        } else {
            None
        }
    };
    if let Some(abandoned) = abandoned_startup {
        cleanup_abandoned_recording(&app, abandoned);
        return Ok(());
    }

    let (
        segments,
        active,
        needs_active_segment,
        return_pid,
        was_kiri_frontmost,
        output_format,
        completion_monitor,
        windows_native,
        finalize_metadata,
    ) = {
        let state = app.state::<AppState>();
        let mut recording = state.recording.lock().unwrap();
        if !recording.accepts_recording_action(expected_session) { return Ok(()); }
        #[cfg(target_os = "linux")]
        if let Some(expected_session) = failed_session {
            if recording.session_id != expected_session
                || !recording
                    .active
                    .as_ref()
                    .is_some_and(|active| {
                        active.recorder.as_ref().is_some_and(|recorder| recorder.unexpected_failure().is_some())
                            || active.encoder.as_ref().is_some_and(|encoder| encoder.unexpected_failure().is_some())
                    })
            {
                return Ok(());
            }
        }
        if !(recording.is_recording || recording.is_paused) || recording.is_transitioning {
            return Ok(());
        }
        let needs_active_segment = recording.is_recording;
        let elapsed = crate::state::recording_state(&recording).elapsed;
        let windows_native = recording
            .active
            .as_ref()
            .and_then(|active| active.encoder.as_ref())
            .is_some_and(crate::record::SegmentEncoder::is_windows_native);
        let finalize_metadata =
            recording
                .configuration
                .as_ref()
                .map(|configuration| RecordingFinalizeMetadata {
                    pixel_width: crate::core::policy::RecordingPolicy::pixel_dimension(
                        configuration.region.width,
                        configuration.backing_scale,
                    ),
                    pixel_height: crate::core::policy::RecordingPolicy::pixel_dimension(
                        configuration.region.height,
                        configuration.backing_scale,
                    ),
                    duration: (elapsed > 0.0).then_some(elapsed),
                });
        if let Some(encoder) = recording.active.as_ref().and_then(|active| active.encoder.as_ref()) {
            encoder.set_windows_paused(true);
        }
        recording.is_recording = false;
        recording.is_paused = false;
        recording.is_finalizing = true;
        recording.started_at = None;
        emit_recording_state(&app, &recording);
        (
            recording.take_completed_segments(),
            recording.active.take(),
            needs_active_segment,
            recording.return_pid,
            recording.was_kiri_frontmost,
            recording
                .configuration
                .as_ref()
                .map(|configuration| configuration.options.output_format)
                .unwrap_or_default(),
            recording.completion_monitor.take(),
            windows_native,
            finalize_metadata,
        )
    };

    stop_click_monitor(&app);
    close_recording_windows(&app);

    let completion_id = uuid::Uuid::new_v4().to_string();
    let save_job = RecordingSaveJobGuard::begin(&app, RecordingSaveJobDto {
        id: completion_id.clone(),
        kind: match output_format {
            RecordingOutputFormat::Mp4 => "video",
            RecordingOutputFormat::Gif => "gif",
        }.into(),
        created_at: chrono::Utc::now().to_rfc3339(),
        duration: finalize_metadata.and_then(|metadata| metadata.duration),
        pixel_width: finalize_metadata.map_or(0, |metadata| metadata.pixel_width),
        pixel_height: finalize_metadata.map_or(0, |metadata| metadata.pixel_height),
    });

    // Entire stop + finalize runs on a background thread: recorder.stop()
    // and encoder.finish() can block on SCK/native callbacks, and merging
    // + probing takes time. The UI already shows the finalizing spinner, so
    // the async command returns immediately and the panel stays responsive.
    let handle = app.clone();
    std::thread::spawn(move || {
        let _save_job = save_job;
        let mut failure = None;
        let mut final_segments = segments;
        if let Some(mut active) = active {
            #[cfg(target_os = "linux")]
            {
                failure = active.encoder.as_ref().and_then(|encoder| encoder.unexpected_failure());
            }
            match active.recorder.take() {
                Some(mut recorder) => {
                    if let Err(error) = recorder.stop() {
                        failure.get_or_insert_with(|| error.to_string());
                    }
                }
                None if needs_active_segment => {
                    failure = Some("The native recorder is unavailable.".into())
                }
                None => {}
            }
            if failure.is_none() {
                match active.encoder.take() {
                    Some(encoder) => match encoder.finish() {
                        Ok(path) => final_segments.push(path),
                        Err(error) => failure = Some(error.to_string()),
                    },
                    None if needs_active_segment => {
                        failure = Some("The video encoder is unavailable.".into())
                    }
                    None => {}
                }
            } else if let Some(encoder) = active.encoder.take() {
                encoder.cancel();
            }
        } else if needs_active_segment {
            failure = Some("The active recording session is unavailable.".into());
        }

        // The native capture session is over once its final MP4 segment has
        // been closed. Release the global recording lock and restore the
        // source application before potentially long merge/GIF work so an
        // unlimited-duration GIF never blocks the next capture or holds
        // focus for the whole conversion.
        reset_recording_session(&handle);
        if !was_kiri_frontmost {
            if let Some(pid) = return_pid {
                platform::activate_application(pid);
            }
        }

        if let Some(error) = failure {
            log::error!("recording: active segment failed while stopping: {error}");
            let recovery = recover_completed_recording(&handle, final_segments);
            let message = match recovery {
                Ok(true) => "Screen recording stopped unexpectedly. Earlier completed sections were saved as a partial recording."
                    .to_string(),
                Ok(false) => {
                    #[cfg(target_os = "linux")]
                    {
                        [
                            crate::linux_audio::AUDIO_UNAVAILABLE,
                            crate::linux_audio::MICROPHONE_UNAVAILABLE,
                            crate::linux_audio::AUDIO_RECORDING_FAILED,
                        ]
                        .into_iter().find(|message| error.contains(message))
                        .unwrap_or("Could not save the recording.").to_string()
                    }
                    #[cfg(not(target_os = "linux"))]
                    { "Could not save the recording.".to_string() }
                },
                Err(recovery_error) => {
                    log::error!("recording: partial recording recovery failed: {recovery_error}");
                    "Could not save the recording. Lumen kept the completed sections so they are not lost."
                        .to_string()
                }
            };
            #[cfg(target_os = "linux")]
            emit_notice_on_monitor(
                &handle,
                message.clone(),
                "exclamationmark.triangle.fill".into(),
                completion_monitor,
            );
            emit_error(&handle, message, None);
        } else {
            let (processing_kind, processing_title, processing_detail) = match output_format {
                RecordingOutputFormat::Mp4 => ("video", "Saving Recording", "MP4"),
                RecordingOutputFormat::Gif => ("gif", "Creating GIF", "12 fps · 720 px long edge"),
            };
            show_completion_preview(
                &handle,
                &CompletionPreviewDto::processing(
                    completion_id.clone(),
                    processing_kind,
                    processing_title,
                    processing_detail,
                ),
                completion_monitor.clone(),
            );
            let result = finalize_recording(
                &handle,
                final_segments,
                output_format,
                windows_native,
                finalize_metadata,
            );
            match result {
                Ok(outcome) => show_completion_preview(
                    &handle,
                    &CompletionPreviewDto::ready(
                        completion_id,
                        &outcome.asset,
                        if outcome.gif_fallback {
                            "GIF Failed — Recording Saved as MP4"
                        } else if outcome.asset.kind == CaptureKind::Gif {
                            "GIF Created"
                        } else {
                            "Recording Saved"
                        },
                        completion_asset_detail(&outcome.asset),
                        false,
                    ),
                    completion_monitor,
                ),
                Err(error) if error.is_queued() => {
                    log::warn!("recording: final import queued for retry: {error}");
                    emit_notice_on_monitor(
                        &handle,
                        "A recording is waiting to save".into(),
                        "arrow.clockwise".into(),
                        completion_monitor,
                    );
                }
                Err(error) => {
                    log::error!("recording: final import failed: {error}");
                    emit_notice_on_monitor(
                        &handle,
                        "Could not save the recording".into(),
                        "exclamationmark.triangle.fill".into(),
                        completion_monitor,
                    );
                    emit_error(&handle, "Could not save the recording.".into(), None);
                }
            }
        }
    });
    Ok(())
}

struct RecordingFinalizeOutcome {
    asset: CaptureAsset,
    gif_fallback: bool,
}

#[derive(Clone, Copy)]
struct RecordingFinalizeMetadata {
    pixel_width: i64,
    pixel_height: i64,
    duration: Option<f64>,
}

enum RecordingFinalizeError {
    Queued(String),
    Failed(String),
}

impl RecordingFinalizeError {
    fn is_queued(&self) -> bool {
        matches!(self, Self::Queued(_))
    }
}

impl std::fmt::Display for RecordingFinalizeError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Queued(message) | Self::Failed(message) => formatter.write_str(message),
        }
    }
}

fn import_recording_file(
    state: &AppState,
    path: &std::path::Path,
    kind: CaptureKind,
    extension: &str,
    pixel_width: i64,
    pixel_height: i64,
    duration: Option<f64>,
) -> Result<CaptureAsset, String> {
    let mut context = state.library.lock().unwrap();
    context
        .library_mut()
        .map_err(|error| error.to_string())?
        .import_file(
            path,
            kind,
            extension,
            pixel_width,
            pixel_height,
            duration,
            None,
        )
        .map_err(|error| error.to_string())
}

#[allow(clippy::too_many_arguments)]
fn import_recovery_output(
    state: &AppState,
    path: &std::path::Path,
    pending: &PendingRecording,
    kind: CaptureKind,
    extension: &str,
    pixel_width: i64,
    pixel_height: i64,
    duration: Option<f64>,
) -> Result<CaptureAsset, String> {
    let mut context = state.library.lock().unwrap();
    context
        .library_mut()
        .map_err(|error| error.to_string())?
        .import_file_with_stable_id(
            path,
            pending.id,
            pending.created_at,
            kind,
            extension,
            pixel_width,
            pixel_height,
            duration,
            None,
        )
        .map_err(|error| error.to_string())
}

fn finalize_recording(
    app: &AppHandle,
    segments: Vec<PathBuf>,
    output_format: RecordingOutputFormat,
    windows_native: bool,
    metadata: Option<RecordingFinalizeMetadata>,
) -> Result<RecordingFinalizeOutcome, RecordingFinalizeError> {
    let state = app.state::<AppState>();
    let _recovery_transition = state.recording_recovery_transition.lock().unwrap();
    let merged_path = std::env::temp_dir().join(format!(
        "kiri-recording-merged-{}.mp4",
        uuid::Uuid::new_v4().to_string().to_lowercase()
    ));
    let mut merge_completed = false;
    let mut pending = None;
    let result: Result<RecordingFinalizeOutcome, String> = (|| {
        if windows_native {
            if segments.len() != 1 {
                return Err("The Windows recording did not produce exactly one segment.".into());
            }
            std::fs::copy(&segments[0], &merged_path)
                .map_err(|error| format!("could not stage the Windows MP4: {error}"))?;
        } else {
            #[cfg(any(target_os = "macos", target_os = "linux"))]
            crate::record::merge_segments_native(&segments, &merged_path)
                .map_err(|e| e.to_string())?;
            #[cfg(windows)]
            return Err("The Windows recording unexpectedly used segmented output.".into());
        }
        merge_completed = true;
        let (pixel_width, pixel_height, duration) = if windows_native {
            metadata
                .map(|metadata| {
                    (
                        metadata.pixel_width,
                        metadata.pixel_height,
                        metadata.duration,
                    )
                })
                .unwrap_or((0, 0, None))
        } else {
            #[cfg(any(target_os = "macos", target_os = "linux"))]
            {
                crate::record::probe_video_native(&merged_path).unwrap_or((0, 0, None))
            }
            #[cfg(windows)]
            {
                (0, 0, None)
            }
        };
        match state.recording_recovery.lock().unwrap().persist(
            &merged_path,
            pixel_width,
            pixel_height,
            duration,
        ) {
            Ok(recording) => pending = Some(recording),
            Err(error) => {
                log::error!("recording: could not stage finalized MP4 for recovery: {error}")
            }
        }

        if output_format == RecordingOutputFormat::Mp4 {
            if let Some(pending) = pending.as_mut() {
                state
                    .recording_recovery
                    .lock()
                    .unwrap()
                    .prepare_import(pending, CaptureKind::Video, &merged_path)
                    .map_err(|error| error.to_string())?;
            }
            let asset = import_finalized_output(
                &state,
                &merged_path,
                pending.as_ref(),
                CaptureKind::Video,
                "mp4",
                pixel_width,
                pixel_height,
                duration,
            )?;
            return Ok(RecordingFinalizeOutcome {
                asset,
                gif_fallback: false,
            });
        }

        let gif_result = (|| {
            let (gif_path, gif_width, gif_height, gif_duration) =
                export_gif_file(app, &merged_path, pixel_width, pixel_height, duration, &crate::gif::GifControl::default(), &mut |_, _| {})?;
            if let Some(pending) = pending.as_mut() {
                state
                    .recording_recovery
                    .lock()
                    .unwrap()
                    .prepare_import(pending, CaptureKind::Gif, &gif_path)
                    .map_err(|error| error.to_string())?;
            }
            let import_result = import_finalized_output(
                &state,
                &gif_path,
                pending.as_ref(),
                CaptureKind::Gif,
                "gif",
                gif_width,
                gif_height,
                gif_duration.or(duration),
            );
            let _ = std::fs::remove_file(&gif_path);
            import_result
        })();

        match gif_result {
            Ok(asset) => Ok(RecordingFinalizeOutcome {
                asset,
                gif_fallback: false,
            }),
            Err(gif_error) => {
                log::warn!(
                    "recording: GIF finalization failed, preserving the MP4 fallback: {gif_error}"
                );
                if let Some(pending) = pending.as_mut() {
                    state
                        .recording_recovery
                        .lock()
                        .unwrap()
                        .prepare_import(pending, CaptureKind::Video, &merged_path)
                        .map_err(|error| error.to_string())?;
                }
                let asset = import_finalized_output(
                    &state,
                    &merged_path,
                    pending.as_ref(),
                    CaptureKind::Video,
                    "mp4",
                    pixel_width,
                    pixel_height,
                    duration,
                )
                .map_err(|fallback_error| {
                    format!(
                        "GIF finalization failed: {gif_error}; MP4 fallback failed: {fallback_error}"
                    )
                })?;
                Ok(RecordingFinalizeOutcome {
                    asset,
                    gif_fallback: true,
                })
            }
        }
    })();
    let recovery_kept = pending.as_ref().is_some_and(|pending| {
        state
            .recording_recovery
            .lock()
            .unwrap()
            .validate_video(pending)
            .is_ok()
    });
    let durably_kept = result.is_ok() || recovery_kept;
    if result.is_ok() {
        if let Some(mut pending) = pending.take() {
            if let Err(error) = cleanup_verified_recovery(&state, &mut pending) {
                log::warn!(
                    "recording: imported recovery {} could not be cleaned: {error}",
                    pending.id
                );
            }
        }
    }
    cleanup_finalization_files(&segments, &merged_path, merge_completed, durably_kept);

    match result {
        Ok(outcome) => {
            emit_library_changed(app);
            Ok(outcome)
        }
        Err(error) if recovery_kept => {
            emit_library_changed(app);
            Err(RecordingFinalizeError::Queued(error))
        }
        Err(error) => Err(RecordingFinalizeError::Failed(error)),
    }
}

#[allow(clippy::too_many_arguments)]
fn import_finalized_output(
    state: &AppState,
    path: &std::path::Path,
    pending: Option<&PendingRecording>,
    kind: CaptureKind,
    extension: &str,
    pixel_width: i64,
    pixel_height: i64,
    duration: Option<f64>,
) -> Result<CaptureAsset, String> {
    match pending {
        Some(pending) => import_recovery_output(
            state,
            path,
            pending,
            kind,
            extension,
            pixel_width,
            pixel_height,
            duration,
        ),
        None => import_recording_file(
            state,
            path,
            kind,
            extension,
            pixel_width,
            pixel_height,
            duration,
        ),
    }
}

fn cleanup_finalization_files(
    segments: &[PathBuf],
    merged_path: &std::path::Path,
    merge_completed: bool,
    durably_kept: bool,
) {
    if durably_kept {
        for segment in segments {
            let _ = std::fs::remove_file(segment);
        }
        let _ = std::fs::remove_file(merged_path);
    } else if !merge_completed {
        let _ = std::fs::remove_file(merged_path);
    }
}

// ---------------------------------------------------------------------------
// Settings / locale / shortcuts
// ---------------------------------------------------------------------------

#[tauri::command]
pub fn log_frontend_error(window: WebviewWindow, message: String) -> Result<(), String> {
    require_known_frontend_window(&window)?;
    log::error!("[frontend] {}", sanitize_frontend_log(message));
    Ok(())
}

fn require_known_frontend_window(window: &WebviewWindow) -> Result<(), String> {
    let label = window.label();
    if matches!(
        label,
        "library" | "overlay" | "countdown" | "control-panel" | "recording-region" | "ripple" | "confirm" | "toast"
    ) || ["viewer-", "editor-", "overlay-"]
        .iter()
        .any(|prefix| label.starts_with(prefix))
    {
        Ok(())
    } else {
        Err("This command is unavailable from this window.".into())
    }
}

fn sanitize_frontend_log(message: String) -> String {
    const MAX_BYTES: usize = 4 * 1024;
    let mut sanitized = String::with_capacity(message.len().min(MAX_BYTES));
    for character in message.chars() {
        let character = if character.is_control() {
            ' '
        } else {
            character
        };
        if sanitized.len() + character.len_utf8() > MAX_BYTES {
            break;
        }
        sanitized.push(character);
    }
    sanitized
}

#[tauri::command]
pub async fn show_confirm_dialog(
    app: AppHandle,
    kind: String,
    title: String,
    message: String,
    confirmLabel: String,
    ids: Option<Vec<String>>,
    localize: Option<bool>,
) -> Result<(), String> {
    let handle = app.clone();
    let task = move || {
        crate::state::show_confirm_dialog(
            &handle,
            kind,
            title,
            message,
            confirmLabel,
            ids.unwrap_or_default(),
            localize.unwrap_or(false),
        )
    };
    #[cfg(windows)]
    {
        let (sender, receiver) = tokio::sync::oneshot::channel();
        crate::window_tasks::dispatch(move || {
            let _ = sender.send(task());
        })?;
        receiver
            .await
            .map_err(|_| "The confirmation window task stopped.".to_string())?
    }
    #[cfg(target_os = "linux")]
    {
        tauri::async_runtime::spawn_blocking(move || linux_run_on_main(&app, task))
            .await
            .map_err(|error| error.to_string())?
    }
    #[cfg(target_os = "macos")]
    {
        tauri::async_runtime::spawn_blocking(task)
            .await
            .map_err(|error| error.to_string())?
    }
}

#[tauri::command]
pub fn mic_supported() -> bool {
    platform::mic_supported()
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PlatformCapabilitiesDto {
    pub scrolling_capture: bool,
    pub recording: bool,
    pub local_ocr: bool,
    pub system_audio: bool,
    pub microphone: bool,
    pub click_highlights: bool,
    pub video_editing: bool,
    pub video_speed_editing: bool,
    pub video_effects_editing: bool,
    pub video_annotations_editing: bool,
    pub video_export_presets: bool,
    pub manual_updates: bool,
}

#[tauri::command]
pub fn platform_capabilities() -> PlatformCapabilitiesDto {
    PlatformCapabilitiesDto {
        scrolling_capture: crate::scroll_capture::supported(),
        video_editing: crate::video_export::editing_available(),
        video_speed_editing: cfg!(any(windows, target_os = "macos")),
        video_effects_editing: cfg!(any(windows, target_os = "macos")),
        video_annotations_editing: cfg!(any(windows, target_os = "macos")),
        video_export_presets: cfg!(any(windows, target_os = "macos", target_os = "linux")),
        manual_updates: cfg!(target_os = "linux"),
        #[cfg(any(windows, target_os = "macos", target_os = "linux"))]
        recording: true,
        #[cfg(not(any(windows, target_os = "macos", target_os = "linux")))]
        recording: false,
        local_ocr: true,
        #[cfg(any(windows, target_os = "macos"))]
        system_audio: true,
        #[cfg(target_os = "linux")]
        system_audio: crate::linux_audio::supported(),
        microphone: platform::mic_supported(),
        #[cfg(any(windows, target_os = "macos"))]
        click_highlights: true,
        #[cfg(not(any(windows, target_os = "macos")))]
        click_highlights: false,
    }
}

#[tauri::command]
pub fn get_language(app: AppHandle) -> String {
    crate::state::load_language(&app)
}

#[tauri::command]
pub fn set_language(app: AppHandle, language: String) -> Result<(), String> {
    if !crate::core::locale::is_language(&language) {
        return Err("Invalid language.".into());
    }
    crate::state::save_language(&app, &language)
        .map_err(|_| "Could not save the language preference.".to_string())?;
    app.emit("language-changed", &language)
        .map_err(|error| error.to_string())?;
    crate::refresh_tray_menu(&app, &language)
}

#[tauri::command]
pub fn get_locale() -> String {
    crate::core::locale::language_for_locale(&sys_locale::get_locale().unwrap_or_else(|| "en".into()))
        .into()
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ShortcutStatusDto {
    pub label: String,
    pub status: ShortcutRegistrationStatus,
}

fn shortcut_status(
    binding: Option<tauri_plugin_global_shortcut::Shortcut>,
    registered: bool,
) -> ShortcutStatusDto {
    if crate::shortcut_settings::system_managed() {
        return ShortcutStatusDto {
            label: "kiri --capture".into(),
            status: ShortcutRegistrationStatus::SystemManaged,
        };
    }
    ShortcutStatusDto {
        label: binding
            .map(crate::shortcut_settings::label)
            .unwrap_or_default(),
        status: if binding.is_none() {
            ShortcutRegistrationStatus::Disabled
        } else if registered {
            ShortcutRegistrationStatus::Enabled
        } else {
            ShortcutRegistrationStatus::Occupied
        },
    }
}

fn require_library_window(window: &WebviewWindow) -> Result<(), String> {
    if window.label() == "library" {
        Ok(())
    } else {
        Err("This command is unavailable from this window.".into())
    }
}

#[tauri::command]
pub fn get_shortcut_status(window: WebviewWindow) -> Result<ShortcutStatusDto, String> {
    require_library_window(&window)?;
    Ok(shortcut_status(
        crate::shortcut_settings::current(window.app_handle(), ShortcutAction::Capture),
        crate::shortcut_settings::is_registered(window.app_handle(), ShortcutAction::Capture),
    ))
}

#[tauri::command]
pub fn retry_shortcut(window: WebviewWindow) -> Result<ShortcutStatusDto, String> {
    require_library_window(&window)?;
    let app = window.app_handle();
    if let Err(error) = crate::shortcut_settings::retry(app, ShortcutAction::Capture) {
        log::warn!("[shortcut] retry failed: {error}");
    }
    Ok(shortcut_status(
        crate::shortcut_settings::current(app, ShortcutAction::Capture),
        crate::shortcut_settings::is_registered(app, ShortcutAction::Capture),
    ))
}

#[tauri::command]
pub fn set_capture_shortcut_editing(window: WebviewWindow, editing: bool) -> Result<(), String> {
    set_shortcut_editing(window, editing)
}

#[tauri::command]
pub fn set_shortcut_editing(window: WebviewWindow, editing: bool) -> Result<(), String> {
    require_library_window(&window)?;
    if editing && !window.is_focused().unwrap_or(false) {
        return Err("Could not change the shortcut.".into());
    }
    let bindings = window.state::<crate::shortcut_settings::ShortcutBindings>();
    if editing {
        bindings.set_library_focused(true);
    }
    bindings.set_editing(editing);
    Ok(())
}

#[tauri::command]
pub fn set_capture_shortcut(
    window: WebviewWindow,
    shortcut: Option<String>,
) -> Result<ShortcutStatusDto, String> {
    require_library_window(&window)?;
    // Compatibility: the former capture-only API used null to restore default.
    let shortcut = shortcut.unwrap_or_else(|| crate::shortcut_settings::default_binding().to_string());
    crate::shortcut_settings::replace(window.app_handle(), ShortcutAction::Capture, Some(&shortcut))?;
    get_shortcut_status(window)
}

#[tauri::command]
pub fn get_shortcut_settings(window: WebviewWindow) -> Result<Vec<ShortcutSettingDto>, String> {
    if !shortcut_settings_read_allowed(window.label()) {
        return Err("This command is unavailable from this window.".into());
    }
    Ok(crate::shortcut_settings::settings(window.app_handle()))
}

fn shortcut_settings_read_allowed(label: &str) -> bool {
    // The control panel has a fixed native label; its recording session is a
    // query parameter. Only its read access is shared with Settings.
    matches!(label, "library" | "control-panel")
}

#[tauri::command]
pub fn set_action_shortcut(
    window: WebviewWindow,
    action: ShortcutAction,
    shortcut: Option<String>,
) -> Result<Vec<ShortcutSettingDto>, String> {
    require_library_window(&window)?;
    crate::shortcut_settings::replace(window.app_handle(), action, shortcut.as_deref())?;
    get_shortcut_settings(window)
}

#[tauri::command]
pub fn reset_action_shortcut(
    window: WebviewWindow,
    action: ShortcutAction,
) -> Result<Vec<ShortcutSettingDto>, String> {
    set_action_shortcut(window, action, Some(action.default_binding().to_string()))
}

#[tauri::command]
pub fn retry_action_shortcut(
    window: WebviewWindow,
    action: ShortcutAction,
) -> Result<Vec<ShortcutSettingDto>, String> {
    require_library_window(&window)?;
    // The UI reloads the row after failure and keeps its saved binding. Preserve
    // the reason (including media-key permission errors) instead of hiding it.
    crate::shortcut_settings::retry(window.app_handle(), action)?;
    get_shortcut_settings(window)
}

#[tauri::command]
pub fn open_settings(action: String) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        let url = match action.as_str() {
            "openSettings" => {
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            }
            "openInputMonitoringSettings" => {
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
            }
            "openMicrophoneSettings" => {
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            }
            _ => return Err("unknown action".into()),
        };
        let workspace = objc2_app_kit::NSWorkspace::sharedWorkspace();
        let url =
            objc2_foundation::NSURL::URLWithString(&objc2_foundation::NSString::from_str(url))
                .ok_or_else(|| "bad url".to_string())?;
        workspace.openURL(&url);
    }
    #[cfg(windows)]
    {
        let url = match action.as_str() {
            "openMicrophoneSettings" => "ms-settings:privacy-microphone",
            "openSettings" => "ms-settings:privacy",
            _ => return Err("unknown action".into()),
        };
        let _ = std::process::Command::new("cmd")
            .args(["/C", "start", url])
            .spawn();
    }
    #[cfg(target_os = "linux")]
    {
        let _ = action;
        // Screen sharing and microphone grants are handled by the desktop
        // portal dialogs; there is no single portable settings URL.
    }
    Ok(())
}

#[tauri::command]
pub async fn authorize_screenshot(window: WebviewWindow) -> Result<(), String> {
    require_library_window(&window)?;
    #[cfg(target_os = "linux")]
    {
        if !window.is_focused().unwrap_or(false) {
            return Err("Focus the Lumen Library before requesting screenshot access.".into());
        }
        let state = window.state::<AppState>();
        let _start_permit = state
            .capture_start
            .try_begin()
            .ok_or("Screen capture is already starting.")?;
        if state.capture.lock().unwrap().session.is_some() {
            return Err("A capture session is already active.".into());
        }
        crate::capture::linux::authorize_portal_screenshot()
            .await
            .map_err(|error| format!("Screenshot authorization failed: {error}"))
    }
    #[cfg(not(target_os = "linux"))]
    {
        Err("Screenshot authorization is only available on Linux.".into())
    }
}

#[tauri::command]
pub fn quit_app(app: AppHandle) -> Result<(), String> {
    app.exit(0);
    Ok(())
}

#[cfg(test)]
mod command_security_tests {
    #[test]
    fn cache_cleared_message_localizes_the_count() {
        assert_eq!(
            super::cache_cleared_message("zh-Hans", 3),
            "已清理图片缓存（3 张）"
        );
        assert_eq!(
            super::cache_cleared_message("en-US", 0),
            "Image cache cleared (0)"
        );
    }

    use super::{
        capture_failure_requires_global_error, cleanup_finalization_files, commit_editor_update,
        complete_library_deletion, crop_annotation_source, crop_editor_source,
        editor_save_destination, parse_editor_save_action, recording_channels,
        sanitize_frontend_log, validate_capture_png, validate_editor_annotation_document,
        validate_replacement_metadata, validate_staged_capture_annotation, write_editor_save,
        EditorCropPixels, EditorSaveAction, ShortcutRegistrationStatus,
        EDITOR_ACTION_INVALID_ERROR, EDITOR_SAVE_ERROR,
    };
    use crate::core::annotation::AnnotationDocument;
    use crate::core::asset::{CaptureAsset, CaptureKind};
    use crate::core::geometry::Rect;
    use crate::core::library::{AssetLibrary, AssetLibraryError};
    use crate::core::library_location::LibraryLocationError;
    use crate::core::policy::RecordingOptions;
    use crate::state::ApprovedEditorSave;
    use std::cell::Cell;
    use std::collections::HashMap;
    use std::io::Cursor;
    use std::path::PathBuf;
    use std::sync::mpsc::TrySendError;

    #[test]
    fn shortcut_settings_read_access_only_allows_library_and_fixed_control_panel() {
        for label in ["library", "control-panel"] {
            assert!(super::shortcut_settings_read_allowed(label));
        }
        for label in ["", "overlay", "countdown", "editor", "control-panel-stale", "library-other"] {
            assert!(!super::shortcut_settings_read_allowed(label), "{label}");
        }
    }

    #[test]
    fn recording_notice_keeps_unknown_native_details_private() {
        assert_eq!(
            super::recording_start_error_notice("native failure at /private/test.mp4", false),
            "Could not start screen recording."
        );
    }

    #[test]
    fn recording_notice_exposes_only_known_device_and_display_recovery() {
        assert_eq!(super::recording_start_error_notice("No system-audio output device is available.", false), "No system-audio output device is available.");
        assert_eq!(super::recording_start_error_notice("No microphone input device is available.", false), "No microphone input device is available.");
        assert_eq!(super::recording_start_error_notice("The selected display is ambiguous. Select it again.", false), "The selected display is no longer available. Start a new capture.");
        assert!(super::recording_start_error_notice("The selected display is ambiguous. Select it again.", true).contains("Stop and save"));
    }

    #[test]
    fn recording_notice_preserves_missing_selected_input_recovery() {
        let message = crate::microphone::devices::SELECTED_UNAVAILABLE;
        let wrapped = format!("starting input: {message}");
        for resuming in [false, true] {
            assert_eq!(super::recording_start_error_notice(&wrapped, resuming), message);
        }
        assert_eq!(super::recording_encoder_error_notice(&wrapped), message);
        assert_eq!(super::recording_encoder_error_notice("private native failure"), "Could not start the video encoder.");
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn recording_notice_preserves_display_recovery_guidance() {
        for message in [
            "The selected display geometry changed. Start a new capture before recording.",
            "The selected display is no longer available. Start a new capture.",
        ] {
            assert_eq!(super::recording_start_error_notice(message, false), message);
            assert_eq!(
                super::recording_start_error_notice(message, true),
                "The selected display changed or is no longer available. Stop and save the paused recording, then start a new capture."
            );
        }
    }

    #[test]
    fn removing_missing_record_notifies_after_commit_even_when_cleanup_fails() {
        for blocked_cleanup in [false, true] {
            let directory = tempfile::tempdir().unwrap();
            let root = directory.path().to_path_buf();
            let mut library = AssetLibrary::open(root.clone()).unwrap();
            let asset = library
                .import_data(b"flat", CaptureKind::Image, "png", 1, 1, None, None, None)
                .unwrap();
            std::fs::remove_file(library.asset_url(&asset)).unwrap();
            let source = root
                .join("Annotations")
                .join(format!("{}.source.png", asset.id));
            if blocked_cleanup {
                std::fs::create_dir(&source).unwrap();
            }

            let deletion = library
                .remove_missing_asset(&asset.id)
                .map_err(LibraryLocationError::from);
            if blocked_cleanup {
                assert!(matches!(
                    &deletion,
                    Err(LibraryLocationError::Library(
                        AssetLibraryError::CleanupFailed { failed_files: 1 }
                    ))
                ));
            }
            let notifications = Cell::new(0);
            let result = complete_library_deletion(deletion, || {
                notifications.set(notifications.get() + 1);
                assert!(library.asset_by_id(&asset.id).is_none());
                assert!(AssetLibrary::open(root.clone())
                    .unwrap()
                    .asset_by_id(&asset.id)
                    .is_none());
            });
            assert_eq!(notifications.get(), 1);
            assert_eq!(result.is_err(), blocked_cleanup);
            if blocked_cleanup {
                assert!(result.unwrap_err().contains("file(s) could not be removed"));
                assert!(source.is_dir());
            }
        }
    }

    #[test]
    fn rejected_missing_record_removal_does_not_notify_or_delete() {
        let directory = tempfile::tempdir().unwrap();
        let mut library = AssetLibrary::open(directory.path().to_path_buf()).unwrap();
        let asset = library
            .import_data(b"flat", CaptureKind::Image, "png", 1, 1, None, None, None)
            .unwrap();
        let deletion = library
            .remove_missing_asset(&asset.id)
            .map_err(LibraryLocationError::from);
        assert!(matches!(
            &deletion,
            Err(LibraryLocationError::Library(
                AssetLibraryError::AssetFileStillPresent
            ))
        ));
        assert!(complete_library_deletion(deletion, || panic!("deletion did not commit")).is_err());
        assert!(library.asset_by_id(&asset.id).is_some());
        assert_eq!(std::fs::read(library.asset_url(&asset)).unwrap(), b"flat");
    }

    #[test]
    fn frontend_error_log_is_single_line_and_bounded() {
        let sanitized = sanitize_frontend_log(format!("first\nsecond\0{}", "界".repeat(2_000)));
        assert!(!sanitized.chars().any(char::is_control));
        assert!(sanitized.len() <= 4 * 1024);
        assert!(sanitized.starts_with("first second "));
    }

    #[test]
    fn shortcut_status_reflects_native_registration() {
        let expected = crate::shortcut_settings::label(crate::shortcut_settings::default_binding());
        assert_eq!(expected, "F1");
        let enabled = super::shortcut_status(Some(crate::shortcut_settings::default_binding()), true);
        assert_eq!(enabled.label, expected);
        assert_eq!(enabled.status, ShortcutRegistrationStatus::Enabled);
        assert_eq!(serde_json::to_value(&enabled).unwrap()["status"], "enabled");

        let occupied = super::shortcut_status(Some(crate::shortcut_settings::default_binding()), false);
        assert_eq!(occupied.label, expected);
        assert_eq!(occupied.status, ShortcutRegistrationStatus::Occupied);
        assert_eq!(
            serde_json::to_value(&occupied).unwrap()["status"],
            "occupied"
        );
        let disabled = super::shortcut_status(None, false);
        assert!(disabled.label.is_empty());
        assert_eq!(disabled.status, ShortcutRegistrationStatus::Disabled);
        assert_eq!(serde_json::to_value(&disabled).unwrap()["status"], "disabled");
    }

    #[test]
    fn replacement_png_must_decode_and_match_the_indexed_dimensions() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("replacement.png");
        let mut encoded = Cursor::new(Vec::new());
        image::DynamicImage::new_rgba8(10, 20)
            .write_to(&mut encoded, image::ImageFormat::Png)
            .unwrap();
        std::fs::write(&path, encoded.into_inner()).unwrap();
        let mut asset = CaptureAsset {
            id: uuid::Uuid::new_v4(),
            kind: CaptureKind::Image,
            created_at: 1.0,
            filename: "missing.png".into(),
            title: None,
            ocr_text: None,
            ocr_original_text: None,
            qr_text: None,
            tags: Vec::new(),
            pixel_width: 10,
            pixel_height: 20,
            duration: None,
            source_application: None,
            is_favorite: false,
            trashed_at: None,
        };

        assert!(validate_replacement_metadata(&asset, &path).is_ok());
        asset.pixel_width = 11;
        assert!(validate_replacement_metadata(&asset, &path).is_err());
        std::fs::write(&path, b"\x89PNG\r\n\x1a\ntruncated").unwrap();
        assert!(validate_replacement_metadata(&asset, &path).is_err());
    }

    #[test]
    fn raw_video_frame_queue_has_a_hard_capacity() {
        let (senders, _receivers) = recording_channels(RecordingOptions::default());
        for _ in 0..crate::capture::VIDEO_FRAME_QUEUE_CAPACITY {
            senders.video.try_send(vec![0]).unwrap();
        }
        assert!(matches!(
            senders.video.try_send(vec![1]),
            Err(TrySendError::Full(_))
        ));
    }

    #[test]
    fn failed_recording_import_retains_completed_segments_for_recovery() {
        let directory = tempfile::tempdir().unwrap();
        let segment = directory.path().join("completed.mp4");
        let merged = directory.path().join("merged.mp4");
        std::fs::write(&segment, b"completed segment").unwrap();
        std::fs::write(&merged, b"failed merged output").unwrap();

        cleanup_finalization_files(std::slice::from_ref(&segment), &merged, true, false);

        assert!(segment.exists(), "valid completed segment must be retained");
        assert!(merged.exists(), "a completed merge remains recoverable");

        cleanup_finalization_files(std::slice::from_ref(&segment), &merged, true, true);
        assert!(
            !segment.exists(),
            "durably retained segments may be removed"
        );
        assert!(
            !merged.exists(),
            "the durable copy replaces the merged temp"
        );
    }

    #[test]
    fn failed_merge_removes_only_its_partial_output() {
        let directory = tempfile::tempdir().unwrap();
        let segment = directory.path().join("completed.mp4");
        let merged = directory.path().join("partial-merge.mp4");
        std::fs::write(&segment, b"completed segment").unwrap();
        std::fs::write(&merged, b"partial merge").unwrap();

        cleanup_finalization_files(std::slice::from_ref(&segment), &merged, false, false);

        assert!(segment.exists());
        assert!(!merged.exists());
    }

    #[test]
    fn capture_confirmation_validates_png_before_consuming_the_session() {
        let image = image::DynamicImage::ImageRgba8(image::RgbaImage::new(8, 6));
        let mut png = Cursor::new(Vec::new());
        image.write_to(&mut png, image::ImageFormat::Png).unwrap();
        let png = png.into_inner();

        assert_eq!(validate_capture_png(&png, 8, 6).unwrap(), (8, 6));
        assert!(validate_capture_png(&png, 7, 6).is_err());
        assert!(validate_capture_png(&png[..png.len() - 1], 8, 6).is_err());
        assert!(validate_capture_png(b"not a png", 8, 6).is_err());

        let mut oversized_header = png.clone();
        oversized_header[16..20].copy_from_slice(&u32::MAX.to_be_bytes());
        assert!(validate_capture_png(&oversized_header, 8, 6).is_err());
    }

    #[test]
    fn capture_double_failure_requires_a_global_error_after_the_overlay_closes() {
        assert!(capture_failure_requires_global_error(false));
        assert!(!capture_failure_requires_global_error(true));
    }

    #[test]
    fn editable_capture_source_matches_the_staged_pixel_dimensions() {
        let image = image::RgbaImage::from_fn(8, 6, |x, y| image::Rgba([x as u8, y as u8, 0, 255]));
        let mut png = Cursor::new(Vec::new());
        image::DynamicImage::ImageRgba8(image)
            .write_to(&mut png, image::ImageFormat::Png)
            .unwrap();
        let display = crate::capture::CapturedDisplay {
            png_data: png.into_inner().into(),
            pixel_width: 8,
            pixel_height: 6,
            screen_frame: Rect::new(0.0, 0.0, 4.0, 3.0),
            window_rects: Vec::new(),
            display_id: 1,
            display_identity: None,
            backing_scale: 2.0,
        };
        let selection = Rect::new(0.25, 0.5, 2.0, 1.5);
        let document = AnnotationDocument::from_json(
            r#"{"schemaVersion":1,"canvas":{"width":2,"height":1.5},"sourcePixels":{"width":4,"height":3},"marks":[{"kind":"mosaic","id":1,"points":[{"x":1,"y":1}],"brushDiameter":20,"intensity":"standard","style":"pixel"}]}"#,
        )
        .unwrap();
        validate_staged_capture_annotation(&display, selection, &document).unwrap();
        let source = crop_annotation_source(&display, selection, document.source_pixels).unwrap();
        let cropped =
            image::load_from_memory_with_format(&source, image::ImageFormat::Png).unwrap();
        assert_eq!((cropped.width(), cropped.height()), (4, 3));
        assert_eq!(cropped.to_rgba8().get_pixel(0, 0).0, [1, 1, 0, 255]);
    }

    #[test]
    fn editor_document_must_match_asset_pixels_and_aspect_ratio() {
        let document = AnnotationDocument::from_json(
            r#"{"schemaVersion":1,"canvas":{"width":400,"height":300},"sourcePixels":{"width":800,"height":600},"marks":[]}"#,
        )
        .unwrap();
        validate_editor_annotation_document(&document, (800, 600)).unwrap();
        assert!(validate_editor_annotation_document(&document, (801, 600)).is_err());

        let mut wrong_aspect = document;
        wrong_aspect.canvas.width = 500.0;
        assert!(validate_editor_annotation_document(&wrong_aspect, (800, 600)).is_err());
    }

    #[test]
    fn editor_crop_uses_the_exact_staged_source_pixels_and_rejects_bad_bounds() {
        let image = image::RgbaImage::from_fn(8, 6, |x, y| image::Rgba([x as u8, y as u8, 0, 255]));
        let mut png = Cursor::new(Vec::new());
        image::DynamicImage::ImageRgba8(image)
            .write_to(&mut png, image::ImageFormat::Png)
            .unwrap();
        let png = png.into_inner();

        let cropped = crop_editor_source(
            &png,
            (8, 6),
            EditorCropPixels {
                x: 2,
                y: 1,
                width: 4,
                height: 3,
            },
        )
        .unwrap();
        let cropped = image::load_from_memory_with_format(&cropped, image::ImageFormat::Png)
            .unwrap()
            .to_rgba8();
        assert_eq!(cropped.dimensions(), (4, 3));
        assert_eq!(cropped.get_pixel(0, 0).0, [2, 1, 0, 255]);
        assert_eq!(cropped.get_pixel(3, 2).0, [5, 3, 0, 255]);

        assert!(crop_editor_source(
            &png,
            (8, 6),
            EditorCropPixels {
                x: 7,
                y: 0,
                width: 2,
                height: 1,
            },
        )
        .is_err());

        let smaller = image::DynamicImage::new_rgba8(4, 3);
        let mut smaller_png = Cursor::new(Vec::new());
        smaller
            .write_to(&mut smaller_png, image::ImageFormat::Png)
            .unwrap();
        assert!(crop_editor_source(
            &smaller_png.into_inner(),
            (8, 6),
            EditorCropPixels {
                x: 0,
                y: 0,
                width: 4,
                height: 3,
            },
        )
        .is_err());
    }

    #[test]
    fn editor_save_action_matches_its_native_destination() {
        assert_eq!(
            parse_editor_save_action(None, false).unwrap_err(),
            EDITOR_ACTION_INVALID_ERROR
        );
        assert_eq!(
            parse_editor_save_action(Some("save"), false).unwrap(),
            EditorSaveAction::Save
        );
        assert_eq!(
            parse_editor_save_action(Some("save-as"), true).unwrap(),
            EditorSaveAction::SaveAs
        );
        assert!(parse_editor_save_action(Some("save"), true).is_err());
        assert!(parse_editor_save_action(Some("save-as"), false).is_err());
    }

    #[test]
    fn editor_save_destination_requires_the_native_token_without_consuming_it() {
        let label = "editor-00000000-0000-0000-0000-000000000001";
        let token = uuid::Uuid::new_v4();
        let path = PathBuf::from("/tmp/kiri-approved.png");
        let destinations = HashMap::from([(
            label.to_string(),
            ApprovedEditorSave {
                token,
                path: path.clone(),
            },
        )]);

        assert_eq!(
            editor_save_destination(&destinations, label, Some(token)).unwrap(),
            Some(path.clone())
        );
        assert_eq!(
            editor_save_destination(&destinations, label, Some(token)).unwrap(),
            Some(path)
        );
        assert!(editor_save_destination(&destinations, label, Some(uuid::Uuid::new_v4())).is_err());
        assert!(destinations.contains_key(label));
    }

    #[test]
    fn editor_revision_mismatch_retains_tokens_and_skips_external_action() {
        let label = "editor-00000000-0000-0000-0000-000000000001";
        let mut annotations = HashMap::from([(label, "annotation-token")]);
        let mut destinations = HashMap::from([(label, "save-token")]);
        let external_action_ran = Cell::new(false);

        let result = commit_editor_update(
            || Err::<String, _>("revision mismatch"),
            || {
                annotations.remove(label);
                destinations.remove(label);
                external_action_ran.set(true);
                true
            },
        );

        assert_eq!(result, Err("revision mismatch"));
        assert_eq!(annotations.get(label), Some(&"annotation-token"));
        assert_eq!(destinations.get(label), Some(&"save-token"));
        assert!(!external_action_ran.get());
    }

    #[test]
    fn editor_committed_action_returns_revision_even_when_external_action_fails() {
        let label = "editor-00000000-0000-0000-0000-000000000001";
        let mut annotations = HashMap::from([(label, "annotation-token")]);
        let mut destinations = HashMap::from([(label, "save-token")]);

        let result = commit_editor_update(
            || Ok::<String, &str>("next-revision".into()),
            || {
                annotations.remove(label);
                destinations.remove(label);
                false
            },
        )
        .unwrap();

        assert_eq!(result, ("next-revision".into(), false));
        assert!(!annotations.contains_key(label));
        assert!(!destinations.contains_key(label));
    }

    #[test]
    fn editor_save_failures_return_stable_errors() {
        let directory = tempfile::tempdir().unwrap();
        let output = directory.path().join("capture.png");
        std::fs::write(&output, b"old").unwrap();
        write_editor_save(&output, b"new-png").unwrap();
        assert_eq!(std::fs::read(&output).unwrap(), b"new-png");

        assert_eq!(
            write_editor_save(directory.path(), b"png").unwrap_err(),
            EDITOR_SAVE_ERROR
        );
        assert!(directory.path().is_dir());
        assert!(!std::fs::read_dir(directory.path())
            .unwrap()
            .any(|entry| entry
                .unwrap()
                .file_name()
                .to_string_lossy()
                .starts_with(".kiri-export-")));
    }
}

#[tauri::command]
pub fn get_recording_options(app: AppHandle) -> Result<RecordingOptions, String> {
    let options = {
        let state = app.state::<AppState>();
        let guard = state.saved_recording_options.lock().unwrap();
        guard.clone()
    };
    Ok(options)
}

#[tauri::command]
pub fn get_annotation_appearance(app: AppHandle) -> Result<AnnotationAppearance, String> {
    let appearance = {
        let state = app.state::<AppState>();
        let saved = *state.saved_annotation_appearance.lock().unwrap();
        saved
    };
    Ok(appearance)
}

#[tauri::command]
pub fn set_annotation_appearance(
    app: AppHandle,
    appearance: AnnotationAppearancePatch,
) -> Result<AnnotationAppearance, String> {
    let state = app.state::<AppState>();
    let mut saved = state.saved_annotation_appearance.lock().unwrap();
    let normalized = appearance.apply(*saved);
    crate::state::save_annotation_appearance(&app, &normalized)
        .map_err(|_| "The annotation preferences could not be saved.".to_string())?;
    *saved = normalized;
    // Emit while holding the preference lock so updates retain write order.
    let _ = app.emit("annotation-appearance-changed", normalized);
    Ok(normalized)
}

#[tauri::command]
pub fn set_recording_options(app: AppHandle, options: RecordingOptions) -> Result<(), String> {
    let normalized = options.normalized();
    {
        let state = app.state::<AppState>();
        *state.saved_recording_options.lock().unwrap() = normalized.clone();
    }
    crate::state::save_recording_options(&app, &normalized);
    Ok(())
}

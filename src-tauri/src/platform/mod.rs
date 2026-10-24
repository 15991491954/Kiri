//! Cross-platform helpers: clipboard, focus, file reveal, global click
//! monitoring, and capture-exclusion of Kiri's own windows.

#[cfg(target_os = "macos")]
pub mod macos;

#[cfg(windows)]
pub mod windows;

#[cfg(target_os = "linux")]
pub mod linux;

#[cfg(target_os = "macos")]
pub use macos as current;

#[cfg(windows)]
pub use windows as current;

#[cfg(target_os = "linux")]
pub use linux as current;

use std::path::Path;
use std::sync::Arc;

use anyhow::Result;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MicrophoneAccess {
    Authorized,
    Unsupported,
    Denied,
}

/// Native presentation roles for Kiri's short-lived capture and feedback
/// windows. The role keeps macOS Space behavior centralized without changing
/// the corresponding Windows window configuration.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransientWindowRole {
    CaptureOverlay,
    RecordingCountdown,
    RecordingControls,
    RecordingRegion,
    ScrollCaptureRegion,
    CompletionFeedback,
    ClickRipple,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct TransientWindowPolicy {
    pub can_join_all_spaces: bool,
    pub full_screen_auxiliary: bool,
    pub stationary: bool,
    pub screen_saver_level: bool,
    pub accessibility_hidden: bool,
}

impl TransientWindowRole {
    const fn policy(self) -> TransientWindowPolicy {
        TransientWindowPolicy {
            can_join_all_spaces: true,
            full_screen_auxiliary: true,
            stationary: matches!(self, Self::ClickRipple | Self::RecordingRegion | Self::ScrollCaptureRegion),
            // Preserve the existing native levels: capture UI and completion
            // feedback use the screen-saver level, while the click ripple
            // continues to rely on its always-on-top window configuration.
            screen_saver_level: !matches!(self, Self::ClickRipple | Self::RecordingRegion),
            // Only the passive scrolling mask is decorative; its sibling
            // controls and every other existing role retain their AX behavior.
            accessibility_hidden: matches!(self, Self::ScrollCaptureRegion),
        }
    }
}

/// Applies the native policy for a transient Kiri window. macOS requires
/// explicit collection behavior to appear in another app's full-screen Space.
pub fn configure_transient_window(window: &tauri::WebviewWindow, role: TransientWindowRole) {
    #[cfg(target_os = "macos")]
    macos::configure_transient_window(window, role.policy());

    #[cfg(target_os = "linux")]
    if linux::is_wayland_session()
        && matches!(
            role,
            TransientWindowRole::CaptureOverlay | TransientWindowRole::RecordingCountdown
        )
    {
        // The compositor controls Wayland top-level placement. The Linux first
        // release uses one display, so full-screen is the portable way to
        // guarantee the capture canvas matches that display.
        if let Err(error) = window.set_fullscreen(true) {
            log::warn!("Could not make the capture window full-screen: {error}");
        }
    }

    #[cfg(windows)]
    let _ = (window, role);
}

#[cfg(any(windows, test))]
fn physical_transient_frame(
    frame: crate::core::geometry::Rect,
    backing_scale: f64,
) -> (i32, i32, u32, u32) {
    let scale = backing_scale.max(1.0);
    (
        (frame.x * scale).round() as i32,
        (frame.y * scale).round() as i32,
        (frame.width * scale).round().max(1.0) as u32,
        (frame.height * scale).round().max(1.0) as u32,
    )
}

/// Corrects transient window geometry after creation. Tao chooses a monitor
/// for logical builder coordinates by trying each monitor's scale factor;
/// that is ambiguous on Windows mixed-DPI desktops. Repositioning with an
/// explicit physical frame keeps overlays on the display that was captured.
pub fn place_transient_window(
    window: &tauri::WebviewWindow,
    frame: crate::core::geometry::Rect,
    backing_scale: f64,
) -> tauri::Result<()> {
    #[cfg(windows)]
    {
        let (x, y, width, height) = physical_transient_frame(frame, backing_scale);
        window.set_position(tauri::PhysicalPosition::new(x, y))?;
        window.set_size(tauri::PhysicalSize::new(width, height))?;
    }

    #[cfg(not(windows))]
    let _ = (window, frame, backing_scale);

    Ok(())
}

/// Writes PNG bytes to the system clipboard as an image.
pub fn write_image_to_clipboard(png: &[u8]) -> Result<()> {
    #[cfg(target_os = "linux")]
    {
        linux::write_image_to_clipboard(png)
    }
    #[cfg(not(target_os = "linux"))]
    {
        let image = image::load_from_memory(png).map_err(|error| anyhow::anyhow!(error))?;
        let rgba = image.into_rgba8();
        let (width, height) = rgba.dimensions();
        let data = rgba.into_raw();
        let mut clipboard = arboard::Clipboard::new().map_err(|error| anyhow::anyhow!(error))?;
        clipboard
            .set_image(arboard::ImageData {
                width: width as usize,
                height: height as usize,
                bytes: std::borrow::Cow::Owned(data),
            })
            .map_err(|error| anyhow::anyhow!(error))
    }
}

/// Reads image pixels only for an explicit Paste Image action.
pub fn read_image_from_clipboard() -> Result<Vec<u8>> {
    #[cfg(target_os = "linux")]
    {
        linux::read_image_from_clipboard()
    }
    #[cfg(not(target_os = "linux"))]
    {
        let mut clipboard = arboard::Clipboard::new().map_err(|error| anyhow::anyhow!(error))?;
        let image = clipboard.get_image().map_err(|_| anyhow::anyhow!("The clipboard has no image."))?;
        let width = u32::try_from(image.width).map_err(|_| anyhow::anyhow!("Clipboard image is too large."))?;
        let height = u32::try_from(image.height).map_err(|_| anyhow::anyhow!("Clipboard image is too large."))?;
        if width == 0 || height == 0 || width > 8192 || height > 8192 ||
            (width as u64) * (height as u64) * 4 > 128 * 1024 * 1024 {
            return Err(anyhow::anyhow!("Clipboard image is too large."));
        }
        let pixels = image::RgbaImage::from_raw(width, height, image.bytes.into_owned())
            .ok_or_else(|| anyhow::anyhow!("Clipboard image is invalid."))?;
        let mut png = std::io::Cursor::new(Vec::new());
        image::DynamicImage::ImageRgba8(pixels).write_to(&mut png, image::ImageFormat::Png)?;
        Ok(png.into_inner())
    }
}

/// Writes plain text to the system clipboard.
pub fn write_text_to_clipboard(text: &str) -> Result<()> {
    #[cfg(target_os = "linux")]
    {
        linux::write_text_to_clipboard(text)
    }
    #[cfg(not(target_os = "linux"))]
    {
        let mut clipboard = arboard::Clipboard::new().map_err(|error| anyhow::anyhow!(error))?;
        clipboard
            .set_text(text.to_string())
            .map_err(|error| anyhow::anyhow!(error))
    }
}

/// Writes an existing regular file to the system clipboard as a file item.
pub fn write_file_to_clipboard(path: &Path) -> Result<()> {
    let metadata = std::fs::metadata(path).map_err(|error| {
        anyhow::anyhow!(
            "The file could not be accessed for copying ({}): {error}",
            path.display()
        )
    })?;
    if !metadata.is_file() {
        anyhow::bail!(
            "Only an existing regular file can be copied ({}).",
            path.display()
        );
    }

    #[cfg(target_os = "linux")]
    {
        linux::write_file_to_clipboard(path)
    }
    #[cfg(windows)]
    { windows::write_file_to_clipboard(path) }
    #[cfg(target_os = "macos")]
    {
        let mut clipboard = arboard::Clipboard::new()
            .map_err(|error| anyhow::anyhow!("The system clipboard is unavailable: {error}"))?;
        clipboard.set().file_list(&[path]).map_err(|error| {
            anyhow::anyhow!("The file could not be copied to the clipboard: {error}")
        })
    }
}

/// Shows a window without activating Kiri or moving keyboard focus to it.
pub fn show_window_without_activation(
    app: &tauri::AppHandle,
    label: &str,
    role: TransientWindowRole,
) {
    #[cfg(target_os = "macos")]
    current::show_window_without_activation(app, label, role.policy());

    #[cfg(any(windows, target_os = "linux"))]
    {
        let _ = role;
        current::show_window_without_activation(app, label);
    }
}

/// Activate the application with the given PID (focus restoration).
pub fn activate_application(pid: u32) {
    current::activate_application(pid);
}

/// Reveal a file in Finder / Explorer.
pub fn reveal_path(path: &Path) -> Result<()> {
    #[cfg(windows)]
    { current::reveal_path(path) }
    #[cfg(not(windows))]
    { current::reveal_path(path); Ok(()) }
}

/// Returns (pid, name) of the frontmost application.
pub fn frontmost_application() -> Option<(u32, Option<String>)> {
    current::frontmost_application()
}

/// Starts a global click listener (mouse down anywhere on the system).
/// The callback receives the click position in the primary display's
/// top-left-oriented coordinates.
pub fn start_click_monitor(
    callback: Arc<dyn Fn(f64, f64) + Send + Sync>,
) -> Result<Box<dyn ClickMonitorHandle + Send>> {
    current::start_click_monitor(callback)
}

pub trait ClickMonitorHandle: Send + Sync {
    fn stop(self: Box<Self>);
}

/// Label prefix shared by WebView-backed pinned screenshots. Window cleanup and
/// the Windows topmost guard both key off it, so they cannot drift apart.
pub const PIN_WINDOW_LABEL_PREFIX: &str = "pin-";

/// True only when a pinned screenshot lost Windows' topmost band while still
/// being meant to stay on top. A pin the user explicitly unpinned keeps that
/// state; a label that is not a pin is never touched.
#[cfg(any(windows, test))]
pub(crate) fn pin_lost_topmost_band(
    label: &str,
    wants_topmost: bool,
    native_topmost: bool,
) -> bool {
    label.starts_with(PIN_WINDOW_LABEL_PREFIX) && wants_topmost && !native_topmost
}

/// Re-asserts the native mechanism that keeps a pinned screenshot above other
/// applications. macOS and Linux rely on `set_always_on_top` from the window
/// manager, so this is a no-op there instead of a compile-time break.
pub fn assert_window_topmost(window: &tauri::WebviewWindow) -> Result<()> {
    #[cfg(windows)]
    {
        windows::assert_window_topmost(window)
    }
    #[cfg(not(windows))]
    {
        let _ = window;
        Ok(())
    }
}

/// Drops a pinned screenshot out of the native topmost band immediately.
pub fn release_window_topmost(window: &tauri::WebviewWindow) -> Result<()> {
    #[cfg(windows)]
    {
        windows::release_window_topmost(window)
    }
    #[cfg(not(windows))]
    {
        let _ = window;
        Ok(())
    }
}

/// Smallest physical window a pin may shrink to, in display-independent
/// pixels. It matches the builder's minimum size, so zooming out can never hide
/// the close control.
const PIN_MIN_SIZE_DIPS: (f64, f64) = (80.0, 60.0);

/// Largest physical edge one zoom step may produce. A pin is a composited
/// surface, and the desktop allocates memory in proportion to its area, so the
/// zoom stops at a bound that still covers pixel-level inspection instead of
/// letting a wheel burst ask for an unbounded window.
const PIN_MAX_ZOOM_EDGE: f64 = 8000.0;

/// A pin's frame in physical screen pixels.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PinFrame {
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
}

/// Scales a pin around the point under the pointer.
///
/// `anchor` is the pointer position inside the window as a fraction of its width
/// and height, so the image content the user is inspecting stays under the
/// cursor while the window grows or shrinks. The image aspect ratio is enforced
/// so the pin never letterboxes, which is also what lets the reported zoom
/// percentage be derived from the width alone. Bounds apply to the result, not
/// to the requested factor: a wheel burst that overshoots stops at the bound.
pub fn zoomed_pin_frame(
    frame: PinFrame,
    factor: f64,
    anchor: (f64, f64),
    aspect: Option<f64>,
    scale: f64,
) -> PinFrame {
    let current_width = f64::from(frame.width.max(1));
    let current_height = f64::from(frame.height.max(1));
    let aspect = match aspect {
        Some(value) if value.is_finite() && value >= 0.01 => value,
        _ => current_width / current_height,
    };
    let factor = if factor.is_finite() {
        factor.clamp(0.05, 20.0)
    } else {
        1.0
    };
    let scale = if scale.is_finite() && scale > 0.0 {
        scale
    } else {
        1.0
    };

    let mut width = current_width * factor;
    // Both edges must stay usable: a very wide image needs more than the
    // minimum width before its height clears the minimum height.
    let minimum_width = (PIN_MIN_SIZE_DIPS.0 * scale).max(PIN_MIN_SIZE_DIPS.1 * scale * aspect);
    width = width.clamp(minimum_width.min(PIN_MAX_ZOOM_EDGE), PIN_MAX_ZOOM_EDGE);
    let mut height = width / aspect;
    if height > PIN_MAX_ZOOM_EDGE {
        height = PIN_MAX_ZOOM_EDGE;
        width = height * aspect;
    }
    let width = width.round().max(1.0);
    let height = height.round().max(1.0);
    let anchor_x = anchor.0.clamp(0.0, 1.0);
    let anchor_y = anchor.1.clamp(0.0, 1.0);
    PinFrame {
        x: (f64::from(frame.x) + anchor_x * (current_width - width)).round() as i32,
        y: (f64::from(frame.y) + anchor_y * (current_height - height)).round() as i32,
        width: width as u32,
        height: height as u32,
    }
}

/// Resizes a pinned screenshot around the pointer that scrolled it.
///
/// Windows applies position and size in one native call so a fast wheel cannot
/// paint the window at its new size on the old origin. Other platforms go
/// through the window manager, which needs the two properties separately.
pub fn zoom_pinned_window(
    window: &tauri::WebviewWindow,
    factor: f64,
    anchor: (f64, f64),
    aspect: Option<f64>,
) -> Result<(u32, u32)> {
    #[cfg(windows)]
    {
        windows::zoom_pinned_window(window, factor, anchor, aspect)
    }
    #[cfg(not(windows))]
    {
        let position = window.outer_position()?;
        let size = window.inner_size()?;
        let frame = zoomed_pin_frame(
            PinFrame {
                x: position.x,
                y: position.y,
                width: size.width,
                height: size.height,
            },
            factor,
            anchor,
            aspect,
            window.scale_factor().unwrap_or(1.0),
        );
        window.set_size(tauri::PhysicalSize::new(frame.width, frame.height))?;
        window.set_position(tauri::PhysicalPosition::new(frame.x, frame.y))?;
        Ok((frame.width, frame.height))
    }
}

/// Starts the background guard that puts pins back into the topmost band if
/// another program drops them. Idempotent and safe to call for every pin.
pub fn ensure_pin_topmost_guard(app: &tauri::AppHandle) {
    #[cfg(windows)]
    windows::ensure_pin_topmost_guard(app);
    #[cfg(not(windows))]
    let _ = app;
}

/// Stops the guard once the last pinned screenshot is gone. Safe to call for
/// every pin that closes: the platform layer keeps the guard alive while any
/// other pin still exists.
pub fn release_pin_topmost_guard(app: &tauri::AppHandle, closed_label: &str) {
    #[cfg(windows)]
    windows::release_pin_topmost_guard(app, closed_label);
    #[cfg(not(windows))]
    let _ = (app, closed_label);
}

/// Excludes (or re-includes) one of Kiri's windows from screen capture.
pub fn set_window_capture_excluded(app: &tauri::AppHandle, label: &str, excluded: bool) {
    current::set_window_capture_excluded(app, label, excluded);
}

/// macOS-only: the CGWindowID of a window (used for SCK exceptingWindows).
#[cfg(target_os = "macos")]
pub fn window_capture_id(app: &tauri::AppHandle, label: &str) -> Option<u32> {
    macos::window_capture_id(app, label)
}

#[cfg(any(windows, target_os = "linux"))]
pub fn window_capture_id(_app: &tauri::AppHandle, _label: &str) -> Option<u32> {
    None
}

/// Windows-only activation hook for the capture overlay.
#[cfg(windows)]
pub fn activate_self() {
    current::activate_self();
}

/// True when microphone capture is available (macOS 15+; Windows: always).
pub fn mic_supported() -> bool {
    current::mic_supported()
}

/// Requests microphone access when the platform supports recording it.
/// A denied or restricted grant is reported explicitly so recording never
/// starts with a silently empty microphone track.
pub fn request_microphone_access() -> Result<MicrophoneAccess> {
    current::request_microphone_access()
}

/// Makes a window click-through so it never blocks the cursor.
pub fn set_window_click_through(app: &tauri::AppHandle, label: &str) {
    current::set_window_click_through(app, label);
}

#[cfg(test)]
mod tests {
    use super::{physical_transient_frame, TransientWindowRole};

    #[test]
    fn transient_windows_join_full_screen_spaces() {
        for role in [
            TransientWindowRole::CaptureOverlay,
            TransientWindowRole::RecordingCountdown,
            TransientWindowRole::RecordingControls,
            TransientWindowRole::RecordingRegion,
            TransientWindowRole::ScrollCaptureRegion,
            TransientWindowRole::CompletionFeedback,
            TransientWindowRole::ClickRipple,
        ] {
            let policy = role.policy();
            assert!(policy.can_join_all_spaces, "{role:?}");
            assert!(policy.full_screen_auxiliary, "{role:?}");
        }
    }

    #[test]
    fn ripple_is_stationary_without_changing_existing_window_levels() {
        for role in [
            TransientWindowRole::CaptureOverlay,
            TransientWindowRole::RecordingCountdown,
            TransientWindowRole::RecordingControls,
            TransientWindowRole::CompletionFeedback,
        ] {
            let policy = role.policy();
            assert!(!policy.stationary, "{role:?}");
            assert!(policy.screen_saver_level, "{role:?}");
        }

        let ripple = TransientWindowRole::ClickRipple.policy();
        assert!(ripple.stationary);
        assert!(!ripple.screen_saver_level);
    }

    #[test]
    fn only_passive_scroll_region_is_hidden_from_accessibility() {
        for role in [
            TransientWindowRole::CaptureOverlay,
            TransientWindowRole::RecordingCountdown,
            TransientWindowRole::RecordingControls,
            TransientWindowRole::RecordingRegion,
            TransientWindowRole::ScrollCaptureRegion,
            TransientWindowRole::CompletionFeedback,
            TransientWindowRole::ClickRipple,
        ] {
            assert_eq!(role.policy().accessibility_hidden,
                role == TransientWindowRole::ScrollCaptureRegion, "{role:?}");
        }
    }

    #[test]
    fn windows_mixed_dpi_frames_round_trip_to_physical_monitor_bounds() {
        assert_eq!(
            physical_transient_frame(
                crate::core::geometry::Rect::new(960.0, 0.0, 1280.0, 720.0),
                2.0,
            ),
            (1920, 0, 2560, 1440)
        );
        assert_eq!(
            physical_transient_frame(
                crate::core::geometry::Rect::new(-1280.0, 180.0, 1280.0, 720.0),
                2.0,
            ),
            (-2560, 360, 2560, 1440)
        );
    }

    #[test]
    fn topmost_guard_repairs_only_pins_that_still_want_to_be_on_top() {
        use super::pin_lost_topmost_band;

        // A pin that lost the band is put back above other applications.
        assert!(pin_lost_topmost_band("pin-2f0a", true, false));
        // An explicit unpin is the user's intent, not a failure to repair.
        assert!(!pin_lost_topmost_band("pin-2f0a", false, false));
        // A pin that already holds the band needs no work; re-asserting it on
        // every foreground change would reorder pins the user arranged.
        assert!(!pin_lost_topmost_band("pin-2f0a", true, true));
        // Every other Kiri window keeps its own stacking.
        for label in ["library", "toast", "overlay", "editor-2f0a", "pinned-2f0a"] {
            assert!(!pin_lost_topmost_band(label, true, false), "{label}");
        }
    }

    #[test]
    fn zoom_scales_a_pin_around_the_point_under_the_pointer() {
        use super::{zoomed_pin_frame, PinFrame};

        let frame = PinFrame { x: 100, y: 100, width: 400, height: 200 };
        // Zooming from the centre keeps the centre pixel under the cursor and
        // grows both edges with the image aspect ratio, not just one of them.
        assert_eq!(
            zoomed_pin_frame(frame, 2.0, (0.5, 0.5), Some(2.0), 1.0),
            PinFrame { x: -100, y: 0, width: 800, height: 400 }
        );
        // Corner anchors keep the opposite corner exactly where it was, so a
        // pin zoomed from its corner never appears to slide away.
        assert_eq!(
            zoomed_pin_frame(frame, 2.0, (0.0, 0.0), Some(2.0), 1.0),
            PinFrame { x: 100, y: 100, width: 800, height: 400 }
        );
        assert_eq!(
            zoomed_pin_frame(frame, 2.0, (1.0, 1.0), Some(2.0), 1.0),
            PinFrame { x: -300, y: -100, width: 800, height: 400 }
        );
    }

    #[test]
    fn zoom_stays_within_reachable_and_affordable_bounds() {
        use super::{zoomed_pin_frame, PinFrame};

        // Zooming out cannot shrink a pin below its close controls; a wide
        // image needs a wider minimum before its height clears that bound.
        for (scale, expected) in [(1.0, (120, 60)), (2.0, (240, 120))] {
            let tiny = zoomed_pin_frame(
                PinFrame { x: 0, y: 0, width: 400, height: 200 },
                0.01,
                (0.5, 0.5),
                Some(2.0),
                scale,
            );
            assert_eq!((tiny.width, tiny.height), expected, "{scale}");
        }
        // An oversized burst is capped rather than turning into a failed
        // window allocation.
        let wide = zoomed_pin_frame(
            PinFrame { x: 0, y: 0, width: 4000, height: 2000 },
            100.0,
            (0.5, 0.5),
            Some(2.0),
            1.0,
        );
        assert_eq!((wide.width, wide.height), (8000, 4000));
        // A tall image is capped by height and the width follows the aspect.
        let tall = zoomed_pin_frame(
            PinFrame { x: 0, y: 0, width: 400, height: 800 },
            100.0,
            (0.5, 0.5),
            Some(0.5),
            1.0,
        );
        assert_eq!((tall.width, tall.height), (4000, 8000));
        // A non-finite factor leaves the frame untouched instead of moving the
        // pin to a bogus origin.
        assert_eq!(
            zoomed_pin_frame(
                PinFrame { x: 7, y: 9, width: 400, height: 200 },
                f64::NAN,
                (0.3, 0.7),
                None,
                1.0,
            ),
            PinFrame { x: 7, y: 9, width: 400, height: 200 }
        );
    }
}

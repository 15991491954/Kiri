//! Optional macOS Dock presence. Native preference, separate from library data.
#[cfg(any(target_os = "macos", test))]
use std::io::Write;
use std::{path::Path, sync::Mutex};
use tauri::{AppHandle, Manager, WebviewWindow};

#[derive(Clone, Copy, Debug, serde::Serialize, serde::Deserialize)]
struct Preference {
    visible: bool,
}

impl Default for Preference {
    fn default() -> Self {
        Self { visible: true }
    }
}

struct CurrentPreference {
    visible: bool,
    #[cfg(target_os = "macos")]
    revision: u64,
}

pub struct DockSettings(Mutex<CurrentPreference>);

impl DockSettings {
    pub fn new(visible: bool) -> Self {
        Self(Mutex::new(CurrentPreference {
            visible,
            #[cfg(target_os = "macos")]
            revision: 0,
        }))
    }
}

#[derive(serde::Serialize)]
pub struct DockVisibilityDto {
    supported: bool,
    visible: bool,
}

fn load_at(path: &Path) -> bool {
    std::fs::read(path)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<Preference>(&bytes).ok())
        .unwrap_or_default()
        .visible
}

pub fn load(app: &AppHandle) -> bool {
    crate::paths::config_dir(app)
        .map(|dir| load_at(&dir.join("dock-visibility.json")))
        .unwrap_or(true)
}

#[cfg(any(target_os = "macos", test))]
fn stage_at(path: &Path, visible: bool) -> std::io::Result<tempfile::NamedTempFile> {
    let parent = path
        .parent()
        .ok_or_else(|| std::io::Error::other("Missing preference directory"))?;
    std::fs::create_dir_all(parent)?;
    let mut file = tempfile::NamedTempFile::new_in(parent)?;
    serde_json::to_writer_pretty(&mut file, &Preference { visible })?;
    file.flush()?;
    file.as_file().sync_all()?;
    Ok(file)
}

fn library_owner(window: &WebviewWindow) -> Result<(), String> {
    if window.label() != "library" {
        return Err("Dock settings are only available in Settings.".into());
    }
    Ok(())
}

#[tauri::command]
pub fn get_dock_visibility(window: WebviewWindow) -> Result<DockVisibilityDto, String> {
    library_owner(&window)?;
    Ok(DockVisibilityDto {
        supported: cfg!(target_os = "macos"),
        visible: window.state::<DockSettings>().0.lock().unwrap().visible,
    })
}

#[cfg(any(target_os = "macos", test))]
fn restore_library_presentation(
    was_visible: bool,
    was_focused: bool,
    capture_busy: bool,
    show: impl FnOnce() -> Result<(), String>,
    focus: impl FnOnce() -> Result<(), String>,
) -> Result<(), String> {
    if was_visible && !capture_busy {
        show()?;
        if was_focused {
            focus()?;
        }
    }
    Ok(())
}

#[cfg(target_os = "macos")]
struct LibraryPresentation {
    window: Option<WebviewWindow>,
    was_visible: bool,
    was_focused: bool,
}

#[cfg(target_os = "macos")]
fn library_presentation(app: &AppHandle) -> LibraryPresentation {
    let window = app.get_webview_window("library");
    let was_visible = window
        .as_ref()
        .is_some_and(|window| window.is_visible().unwrap_or(false));
    let was_focused = window
        .as_ref()
        .is_some_and(|window| window.is_focused().unwrap_or(false))
        && crate::platform::frontmost_application()
            .is_some_and(|(pid, _)| pid == std::process::id());
    LibraryPresentation {
        window,
        was_visible,
        was_focused,
    }
}

#[cfg(target_os = "macos")]
fn apply_runtime_visibility(
    app: &AppHandle,
    visible: bool,
    presentation: &LibraryPresentation,
) -> Result<(), String> {
    let LibraryPresentation {
        window,
        was_visible,
        was_focused,
    } = presentation;
    app.set_dock_visibility(visible)
        .map_err(|_| "Couldn't change Dock visibility.".to_string())?;
    // Transforming Dock presence can change activation. Restore the same
    // settings WebView, preserving its tab and scroll, without reopening a
    // window the user closed or stealing focus from a capture in progress.
    let state = app.state::<crate::state::AppState>();
    let capture_busy = state.capture_schedule.is_active()
        || state.capture_start.is_active()
        || state.capture.lock().unwrap().session.is_some()
        || state.pending_capture_completion.lock().unwrap().is_some()
        || state.recording.lock().unwrap().configuration.is_some();
    restore_library_presentation(
        *was_visible,
        *was_focused,
        capture_busy,
        || {
            window.as_ref().map_or(Ok(()), |window| {
                if *was_focused {
                    window.show().map_err(|error| error.to_string())
                } else if !window.is_visible().map_err(|error| error.to_string())? {
                    crate::platform::macos::restore_library_visibility_without_focus(window)
                        .map_err(|error| error.to_string())
                } else {
                    Ok(())
                }
            })
        },
        || {
            window.as_ref().map_or(Ok(()), |window| {
                window.set_focus().map_err(|error| error.to_string())
            })
        },
    )
}

// Tao guards Dock-hide for one second after showing it to prevent duplicate
// native icons. Retry only the latest accepted preference after that interval.
#[cfg(target_os = "macos")]
fn retry_hide(app: &AppHandle, revision: u64) {
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_millis(1200)).await;
        let handle = app.clone();
        let _ = app.run_on_main_thread(move || {
            let state = handle.state::<DockSettings>();
            let current = state.0.lock().unwrap();
            if !current.visible && current.revision == revision {
                let presentation = library_presentation(&handle);
                if let Err(error) = apply_runtime_visibility(&handle, false, &presentation) {
                    log::warn!("[dock] could not apply hidden preference: {error}");
                }
            }
        });
    });
}

#[tauri::command]
pub fn set_dock_visibility(window: WebviewWindow, visible: bool) -> Result<(), String> {
    library_owner(&window)?;
    #[cfg(target_os = "macos")]
    {
        let app = window.app_handle();
        let state = app.state::<DockSettings>();
        let mut current = state.0.lock().unwrap();
        if current.visible == visible {
            return Ok(());
        }
        let path = crate::paths::config_dir(app)
            .ok_or_else(|| "Couldn't change Dock visibility.".to_string())?
            .join("dock-visibility.json");
        let staged =
            stage_at(&path, visible).map_err(|_| "Couldn't change Dock visibility.".to_string())?;
        // Rollback must reuse this original visibility/focus snapshot, since
        // the attempted transform itself may have changed the native window.
        let presentation = library_presentation(app);
        if apply_runtime_visibility(app, visible, &presentation).is_err() {
            let _ = apply_runtime_visibility(app, current.visible, &presentation);
            if !current.visible {
                retry_hide(app, current.revision);
            }
            return Err("Couldn't change Dock visibility.".into());
        }
        if staged.persist(path).is_err() {
            let _ = apply_runtime_visibility(app, current.visible, &presentation);
            if !current.visible {
                retry_hide(app, current.revision);
            }
            return Err("Couldn't change Dock visibility.".into());
        }
        current.visible = visible;
        current.revision = current.revision.wrapping_add(1);
        if !visible {
            retry_hide(app, current.revision);
        }
        Ok(())
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = visible;
        Err("Dock visibility is only available on macOS.".into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_or_invalid_preference_preserves_the_visible_default() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("dock-visibility.json");
        assert!(load_at(&path));
        for invalid in [
            "broken",
            "{}",
            "{\"visible\":null}",
            "{\"visible\":\"false\"}",
        ] {
            std::fs::write(&path, invalid).unwrap();
            assert!(load_at(&path));
        }
    }

    #[test]
    fn atomic_preference_replacement_round_trips_both_values() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("nested/dock-visibility.json");
        for visible in [false, true, false] {
            stage_at(&path, visible).unwrap().persist(&path).unwrap();
            assert_eq!(load_at(&path), visible);
        }
    }

    #[test]
    fn staging_does_not_change_the_saved_preference() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("dock-visibility.json");
        stage_at(&path, true).unwrap().persist(&path).unwrap();
        let staged = stage_at(&path, false).unwrap();
        assert!(load_at(&path));
        drop(staged);
        assert!(load_at(&path));
    }

    #[test]
    fn changing_dock_presence_preserves_the_open_focused_settings_window() {
        let calls = std::cell::RefCell::new(Vec::new());
        restore_library_presentation(
            true,
            true,
            false,
            || {
                calls.borrow_mut().push("show same window");
                Ok(())
            },
            || {
                calls.borrow_mut().push("focus same window");
                Ok(())
            },
        )
        .unwrap();
        assert_eq!(*calls.borrow(), ["show same window", "focus same window"]);
    }

    #[test]
    fn restoring_dock_presence_does_not_reopen_hidden_windows_or_interrupt_capture() {
        for (was_visible, was_focused, capture_busy) in [
            (false, false, false),
            (false, true, false),
            (true, true, true),
        ] {
            restore_library_presentation(
                was_visible,
                was_focused,
                capture_busy,
                || panic!("must not reopen the library"),
                || panic!("must not take capture focus"),
            )
            .unwrap();
        }
        let calls = std::cell::Cell::new(0);
        restore_library_presentation(
            true,
            false,
            false,
            || {
                calls.set(calls.get() + 1);
                Ok(())
            },
            || panic!("must not focus a previously unfocused library"),
        )
        .unwrap();
        assert_eq!(calls.get(), 1);
    }
}

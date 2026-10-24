//! Platform dispatch for native pin windows.
//!
//! Windows uses the layered-window surface in [`super::surface_windows`]. Every
//! other platform keeps the WebView pin in `src/windows/PinWindow.tsx`; these
//! entry points only exist so the command layer has one shape everywhere.

use tauri::AppHandle;

use super::{PinId, PinImage, PinOrigin, PinRect};

pub struct PinSpec {
    pub image: PinImage,
    pub frame: PinRect,
    /// Scale factor of the display the pin opens on. Zoom limits and the
    /// percentage badge work in physical pixels, but the minimum usable size
    /// is a display-independent 80x60 DIP.
    pub scale: f64,
    pub origin: PinOrigin,
}

#[cfg(windows)]
pub fn open(app: &AppHandle, spec: PinSpec) -> Result<PinId, String> {
    super::surface_windows::open(app, spec)
}

#[cfg(not(windows))]
pub fn open(_app: &AppHandle, _spec: PinSpec) -> Result<PinId, String> {
    Err("Native pins are only available on Windows.".into())
}

#[cfg(windows)]
pub fn close_all() {
    super::surface_windows::close_all();
}

#[cfg(not(windows))]
pub fn close_all() {}

/// Tells native pins whether a screenshot capture is on screen.
///
/// While it is, pins stay out of the topmost band the overlay occupies and
/// pass hit tests through, so a toolbar click always reaches the capture
/// window instead of the pin drawn above it.
pub fn set_capture_overlay_active(active: bool) {
    #[cfg(windows)]
    super::surface_windows::set_capture_overlay_active(active);
    #[cfg(not(windows))]
    let _ = active;
}



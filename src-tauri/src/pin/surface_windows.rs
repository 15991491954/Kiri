//! Windows layered-window pins.
//!
//! One dedicated thread owns every pin window: it creates the HWNDs, uploads
//! premultiplied frames through `UpdateLayeredWindow`, and runs the message
//! loop that receives wheel, drag, and close messages. Images are decoded and
//! resampled on worker threads; this thread never reads a file and never
//! decodes.
//!
//! Two measured behaviours shaped the design:
//! - a hovered, never-activated layered window still receives `WM_MOUSEWHEEL`,
//!   which is what makes "scroll only the pin under the pointer" work;
//! - `SetCapture` is revoked immediately on such a window, so drags are driven
//!   by a temporary `WH_MOUSE_LL` hook that only samples the cursor and posts a
//!   message. No capture, no drift, and a fast flick out of the pin keeps
//!   tracking.

use std::collections::HashMap;
use std::ffi::c_void;
use std::sync::atomic::{AtomicBool, AtomicIsize, AtomicU64, Ordering};
use std::sync::{mpsc, Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{anyhow, Result};
use tauri::{AppHandle, Manager};
use windows::core::w;
use windows::Win32::Foundation::{COLORREF, HINSTANCE, HWND, LPARAM, LRESULT, POINT, RECT, SIZE, WPARAM};
use windows::Win32::Graphics::Gdi::{
    ClientToScreen, CreateCompatibleDC, CreateDIBSection, CreateFontW, DeleteDC, DeleteObject,
    DrawTextW, GetDC, GetMonitorInfoW, MonitorFromPoint, ReleaseDC, SelectObject, SetBkMode,
    SetTextColor, ValidateRect, BITMAPINFO, BITMAPINFOHEADER, BLENDFUNCTION, CLIP_DEFAULT_PRECIS,
    DEFAULT_CHARSET, DEFAULT_PITCH, DIB_RGB_COLORS, DT_CENTER, DT_SINGLELINE, DT_VCENTER,
    FF_DONTCARE, FONT_QUALITY, FW_NORMAL, HGDIOBJ, MONITORINFO, MONITOR_DEFAULTTONEAREST,
    OUT_DEFAULT_PRECIS, TRANSPARENT, AC_SRC_ALPHA, AC_SRC_OVER, BI_RGB,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Accessibility::{SetWinEventHook, UnhookWinEvent, HWINEVENTHOOK};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    GetAsyncKeyState, VK_CONTROL, VK_DOWN, VK_ESCAPE, VK_LBUTTON, VK_LEFT, VK_LWIN, VK_MENU, VK_RIGHT, VK_RWIN, VK_SHIFT, VK_UP,
};
use windows::Win32::UI::WindowsAndMessaging::{
    AppendMenuW, CallNextHookEx, CreatePopupMenu, CreateWindowExW, DefWindowProcW,
    DestroyMenu, DestroyWindow, DispatchMessageW, EndMenu, GetAncestor, GetClassNameW, GetCursorPos,
    GetMessageW, GetWindowLongPtrW, HHOOK, KillTimer, KBDLLHOOKSTRUCT, LoadCursorW,
    MENU_ITEM_FLAGS, MSG, PeekMessageW, PostMessageW, RegisterClassW, SetCursor, SetTimer,
    GetForegroundWindow, SetForegroundWindow, SetWindowDisplayAffinity, SetWindowLongPtrW, SetWindowPos, SetWindowsHookExW,
    ShowWindow, SystemParametersInfoW, TrackPopupMenu, TranslateMessage, UnhookWindowsHookEx,
    UpdateLayeredWindow, WindowFromPoint, CS_DBLCLKS, EVENT_SYSTEM_FOREGROUND,
    GA_ROOT, GWL_EXSTYLE, GWLP_USERDATA, HWND_BOTTOM, HWND_MESSAGE, HWND_NOTOPMOST, HWND_TOPMOST,
    IDC_ARROW, IDC_SIZENS, IDC_SIZENESW, IDC_SIZENWSE, IDC_SIZEWE, IDC_SIZEALL, MA_ACTIVATE,
    MA_NOACTIVATE, MF_CHECKED, MF_STRING, PM_NOREMOVE,
    SPI_GETMOUSEWHEELROUTING,
    SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOOWNERZORDER, SWP_NOSIZE, SWP_NOZORDER, SWP_SHOWWINDOW,
    SW_HIDE, SW_SHOWNOACTIVATE, SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS, TPM_RIGHTBUTTON, ULW_ALPHA,
    WDA_EXCLUDEFROMCAPTURE, WH_KEYBOARD_LL, WH_MOUSE_LL, WINDOW_EX_STYLE, WINEVENT_OUTOFCONTEXT,
    WINEVENT_SKIPOWNPROCESS, WM_APP, WM_COMMAND, WM_DESTROY, WM_ERASEBKGND, WM_KEYDOWN, WM_KEYUP,
    WM_LBUTTONDOWN, WM_LBUTTONUP, WM_MBUTTONDOWN, WM_MOUSEACTIVATE, WM_MOUSEMOVE, WM_MOUSEWHEEL,
    WM_NCDESTROY, WM_NCHITTEST, WM_PAINT, WM_RBUTTONDOWN, WM_RBUTTONUP, WM_SETCURSOR, WM_SETTINGCHANGE,
    WM_SYSKEYDOWN, WM_SYSKEYUP, WM_TIMER, WNDCLASSW, WS_EX_LAYERED, WS_EX_NOACTIVATE,
    WS_EX_TOOLWINDOW, WS_EX_TOPMOST, WS_EX_TRANSPARENT, WS_POPUP,
};

use super::resample;
use super::surface::PinSpec;
use super::text_image::rounded_rect_covers;
use super::{zoom_frame, zoom_frame_within, zoom_percent, PinId, PinRect};

const PIN_CLASS: &str = "KiriPinWindow";
const HOST_CLASS: &str = "KiriPinHost";
const BADGE_CLASS: &str = "KiriPinBadge";
/// Window class of a native popup menu, as user32 registers it.
const MENU_CLASS: &str = "#32768";

const WM_PIN_OPEN: u32 = WM_APP + 40;
const WM_PIN_CLOSE_ALL: u32 = WM_APP + 41;
const WM_PIN_DRAG: u32 = WM_APP + 42;
const WM_PIN_DRAG_END: u32 = WM_APP + 43;
const WM_PIN_FRAME: u32 = WM_APP + 44;
const WM_PIN_HEAL: u32 = WM_APP + 45;
const WM_PIN_CLOSE: u32 = WM_APP + 46;
/// A context-menu selection, re-posted so it runs after the menu's nested
/// message loop has unwound.
const WM_PIN_COMMAND: u32 = WM_APP + 47;
/// A capture overlay session started or ended (`wparam` carries the state).
const WM_PIN_CAPTURE_GATE: u32 = WM_APP + 48;
/// Moves the pin by a keyboard step: `wparam` = x units, `lparam` = y units.
const WM_PIN_NUDGE: u32 = WM_APP + 49;

const BADGE_TIMER: usize = 1;
/// The percentage pill stays small: it is a transient readout, not a control,
/// and a large badge competes with the pin it is reporting on.
const BADGE_WIDTH_DIP: i32 = 56;
const BADGE_HEIGHT_DIP: i32 = 20;
const BADGE_MARGIN_DIP: i32 = 8;
/// Width of the glow around a pin's photo, in DIP. The pin window is this much
/// larger than the photo on every side, so the light has somewhere to fade out
/// instead of being clipped at the window edge. Kept small: the glow only has
/// to lift a pin off the desktop, not cloud it.
const PIN_GLOW_MARGIN_DIP: f64 = 12.0;
/// Corner radius of the photo itself, in DIP. Small enough to keep a 1:1
/// screenshot readable, large enough to read as a floating card instead of a
/// pasted rectangle.
const PIN_CORNER_RADIUS_DIP: f64 = 8.0;
/// Physical-pixel caps for the values above. A display reporting an extreme
/// scale factor must not grow the glow band without bound.
const PIN_GLOW_MARGIN_MAX: i32 = 28;
const PIN_CORNER_RADIUS_MAX: i32 = 20;
/// Width of the glow's fade, in DIP. The band is brightest against the photo
/// edge and reaches nothing by `PIN_GLOW_MARGIN_DIP`.
const PIN_GLOW_BLUR_DIP: f64 = 8.0;
const PIN_GLOW_BLUR_MAX: i32 = 20;
/// Tint of the glow band, as channel multipliers in BGRA order. A pale blue
/// reads as a cool light edge; the previous white band looked like a hard
/// white shadow against light content.
const PIN_GLOW_TINT: [f64; 3] = [255.0, 214.0, 166.0];
/// Peak alpha of the glow against the photo edge. Painted with premultiplied
/// colour: it lightens the desktop behind a pin instead of casting a dark
/// drop shadow, so a capture on a dark wallpaper still separates from it
/// without looking like a pasted rectangle with a border.
const PIN_GLOW_ALPHA: f64 = 0.55;
/// A drag may push a pin off screen, but never so far that it cannot be found
/// and closed again: at least this many physical pixels stay inside the work
/// area of the monitor under the pointer.
const DRAG_VISIBLE_MARGIN: i32 = 48;
/// One arrow-key step for the selected pin, in DIP. Shift multiplies it by
/// `PIN_ARROW_SHIFT_FACTOR` for a quick coarse move.
const PIN_ARROW_STEP_DIP: f64 = 2.0;
const PIN_ARROW_SHIFT_FACTOR: i32 = 5;
/// A fast drag produces many samples per native round trip. The hook samples at
/// most this often; the newest position always wins.
const DRAG_POST_INTERVAL_MS: u64 = 4;

static SURFACE: Mutex<Option<Surface>> = Mutex::new(None);
static APP_HANDLE: OnceLock<AppHandle> = OnceLock::new();
static HOST_WINDOW: AtomicIsize = AtomicIsize::new(0);
static BADGE_WINDOW: AtomicIsize = AtomicIsize::new(0);
static MOUSE_HOOK: Mutex<Option<isize>> = Mutex::new(None);
static KEY_HOOK: Mutex<Option<isize>> = Mutex::new(None);
/// Guards against starting more than one Escape-hook thread while the hook is
/// still being installed.
static KEY_HOOK_STARTED: std::sync::atomic::AtomicBool =
    std::sync::atomic::AtomicBool::new(false);
static FOREGROUND_HOOK: Mutex<Option<isize>> = Mutex::new(None);
/// Dismisses a pin's context menu when the user clicks outside it. A pin is
/// never the foreground window, so the menu's modal loop never receives that
/// click itself; the hook exists only while a menu is tracking.
static MENU_MOUSE_HOOK: Mutex<Option<isize>> = Mutex::new(None);
static DRAG_TARGET: AtomicIsize = AtomicIsize::new(0);
/// The pin the user last pressed, so Escape can close it even if the pointer
/// has drifted off the card since the click.
static ACTIVE_PIN: AtomicIsize = AtomicIsize::new(0);
static LAST_DRAG_POST: AtomicU64 = AtomicU64::new(0);
static ESCAPE_DOWN: AtomicBool = AtomicBool::new(false);
/// True while a pin's native context menu is tracking. Escape belongs to the
/// menu for that moment, so the global hook must not also close the pin.
static MENU_OPEN: AtomicBool = AtomicBool::new(false);
/// The pin whose context menu is tracking. A pin is never the foreground
/// window, so its modal menu loop receives no keyboard input at all; the hook
/// ends the menu itself when Escape is pressed.
static MENU_PIN: AtomicIsize = AtomicIsize::new(0);
static WHEEL_ROUTES_ON_HOVER: AtomicBool = AtomicBool::new(true);
static RENDER_QUEUE: Mutex<Option<mpsc::Sender<RenderJob>>> = Mutex::new(None);
/// True while a screenshot capture is selecting a region on screen.
///
/// A pin and a capture overlay are both topmost, and the frozen screenshot is
/// captured before a pin is drawn, so a pin floating above the overlay both
/// hides a part of the image the user is selecting and swallows clicks meant
/// for the toolbar underneath it. A click on 📌 that actually landed on a pin
/// left the editing HUD open and unchanged, which is the reported
/// "clicked pin, still editing" case. While a capture is active, pins are
/// pushed out of the way and pass every hit test through.
static CAPTURE_OVERLAY_ACTIVE: AtomicBool = AtomicBool::new(false);

struct Surface {
    thread_id: u32,
    host: isize,
    thread: Option<thread::JoinHandle<()>>,
}

impl Drop for Surface {
    fn drop(&mut self) {
        unsafe {
            if self.host != 0 {
                let _ = PostMessageW(Some(hwnd(self.host)), WM_PIN_CLOSE_ALL, WPARAM(0), LPARAM(0));
            }
            let _ = windows::Win32::UI::WindowsAndMessaging::PostThreadMessageW(
                self.thread_id,
                windows::Win32::UI::WindowsAndMessaging::WM_QUIT,
                WPARAM(0),
                LPARAM(0),
            );
        }
        if let Some(thread) = self.thread.take() {
            if thread.thread().id() != thread::current().id() {
                let _ = thread.join();
            }
        }
    }
}

fn hwnd(value: isize) -> HWND {
    HWND(value as *mut c_void)
}

fn now_ms() -> u64 {
    static START: OnceLock<Instant> = OnceLock::new();
    START.get_or_init(Instant::now).elapsed().as_millis() as u64
}

fn with_pins<R>(app: &AppHandle, act: impl FnOnce(&mut super::PinRegistry) -> R) -> R {
    let state = app.state::<crate::state::AppState>();
    let mut pins = state.pins.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    act(&mut pins)
}

// ---------------------------------------------------------------------------
// Thread and host window
// ---------------------------------------------------------------------------

fn ensure_surface() -> Result<isize> {
    let mut slot = SURFACE.lock().unwrap_or_else(|p| p.into_inner());
    if let Some(surface) = slot.as_ref() {
        // The message loop owns the host window. If it exited (a failed loop),
        // the stored handle is dead and must not be reused: a later pin would
        // post into nowhere and appear to hang until the timeout.
        if surface.host != 0 && HOST_WINDOW.load(Ordering::Acquire) == surface.host {
            return Ok(surface.host);
        }
    }
    *slot = None;
    let (ready_tx, ready_rx) = mpsc::sync_channel::<Result<(u32, isize)>>(1);
    let thread = thread::Builder::new()
        .name("kiri-pin-surface".into())
        .spawn(move || run_surface_thread(ready_tx))?;
    let (thread_id, host) = match ready_rx.recv_timeout(Duration::from_secs(5)) {
        Ok(Ok(value)) => value,
        Ok(Err(error)) => {
            let _ = thread.join();
            return Err(error);
        }
        Err(error) => return Err(anyhow!("The pin surface did not become ready: {error}")),
    };
    *slot = Some(Surface { thread_id, host, thread: Some(thread) });
    Ok(host)
}

fn run_surface_thread(ready: mpsc::SyncSender<Result<(u32, isize)>>) {
    unsafe {
        // A thread receives messages only after it owns a message queue.
        let mut message = MSG::default();
        let _ = PeekMessageW(&mut message, None, 0, 0, PM_NOREMOVE);
        let thread_id = windows::Win32::System::Threading::GetCurrentThreadId();
        refresh_wheel_routing();
        if let Err(error) = register_classes() {
            let _ = ready.send(Err(error));
            return;
        }
        let host = match create_host_window() {
            Ok(host) => host,
            Err(error) => {
                let _ = ready.send(Err(error));
                return;
            }
        };
        HOST_WINDOW.store(host.0 as isize, Ordering::Release);
        if ready.send(Ok((thread_id, host.0 as isize))).is_err() {
            return;
        }
        loop {
            let status = GetMessageW(&mut message, None, 0, 0).0;
            if status == 0 {
                break;
            }
            if status == -1 {
                log::error!("[pin] surface message loop failed");
                break;
            }
            let _ = TranslateMessage(&message);
            DispatchMessageW(&message);
        }
        unhook_everything();
    }
}

unsafe fn register_classes() -> Result<()> {
    let instance = GetModuleHandleW(None)
        .map(|module| HINSTANCE(module.0))
        .map_err(|error| anyhow!("The pin window class could not be registered: {error}"))?;
    let mut class = WNDCLASSW { style: CS_DBLCLKS, hInstance: instance, ..Default::default() };
    // A pin is never activated and shows no editable content. Without an
    // explicit cursor the class keeps a null handle, and Windows then leaves
    // whatever cursor was showing (measured as the "app starting" arrow with a
    // spinner while a pin was hovered).
    if let Ok(cursor) = LoadCursorW(None, IDC_ARROW) {
        class.hCursor = cursor;
    }
    for (name, proc) in [
        (PIN_CLASS, pin_proc as unsafe extern "system" fn(HWND, u32, WPARAM, LPARAM) -> LRESULT),
        (HOST_CLASS, host_proc as unsafe extern "system" fn(HWND, u32, WPARAM, LPARAM) -> LRESULT),
        (BADGE_CLASS, badge_proc as unsafe extern "system" fn(HWND, u32, WPARAM, LPARAM) -> LRESULT),
    ] {
        class.lpfnWndProc = Some(proc);
        let name: Vec<u16> = name.encode_utf16().chain(std::iter::once(0)).collect();
        class.lpszClassName = windows::core::PCWSTR(name.as_ptr());
        if RegisterClassW(&class) == 0 {
            let error = std::io::Error::last_os_error();
            // A surface thread that restarts (after a failed message loop) can
            // re-register the same class; the class is process-wide, so that is
            // success rather than a reason to refuse every later pin.
            if error.raw_os_error() != Some(1410) {
                return Err(anyhow!("The pin window class could not be registered ({error:?})."));
            }
        }
    }
    Ok(())
}

unsafe fn create_host_window() -> Result<HWND> {
    let instance = HINSTANCE(GetModuleHandleW(None)?.0);
    CreateWindowExW(
        WINDOW_EX_STYLE(0),
        w!(r"KiriPinHost"),
        w!("KiriPinHost"),
        WS_POPUP,
        0,
        0,
        0,
        0,
        Some(HWND_MESSAGE),
        None,
        Some(instance),
        None,
    )
    .map_err(|error| anyhow!("The pin host window could not be created: {error}"))
}

unsafe extern "system" fn host_proc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    match msg {
        WM_PIN_OPEN => {
            let request = *Box::from_raw(lparam.0 as *mut OpenRequest);
            let result = create_pin(&request.app, request.spec);
            let _ = request.reply.send(result);
            LRESULT(0)
        }
        WM_PIN_CLOSE_ALL => {
            close_all_pins();
            LRESULT(0)
        }
        WM_PIN_HEAL => {
            heal_topmost();
            LRESULT(0)
        }
        WM_PIN_CAPTURE_GATE => {
            apply_capture_gate(wparam.0 != 0);
            LRESULT(0)
        }
        WM_DESTROY => {
            HOST_WINDOW.store(0, Ordering::Release);
            DefWindowProcW(hwnd, msg, wparam, lparam)
        }
        _ => DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

// ---------------------------------------------------------------------------
// Open
// ---------------------------------------------------------------------------

struct OpenRequest {
    app: AppHandle,
    spec: PinSpec,
    reply: mpsc::SyncSender<Result<PinId>>,
}

struct PinState {
    app: AppHandle,
    label: String,
    /// Session-unique instance number. A frame rendered for a closed pin must
    /// never be applied to a new pin that happens to reuse the same HWND.
    instance: u64,
    image: super::PinImage,
    /// The photo's rectangle on screen, in physical pixels. Everything the user
    /// interacts with (drag, wheel zoom, hit test, zoom percentage) works in
    /// this rectangle; the pin window is larger by `decor.margin` per side.
    frame: PinRect,
    decor: PinDecor,
    scale: f64,
    generation: u64,
    /// Continuous zoom factor of the photo, measured against its own pixels.
    /// The frame width is rounded to whole pixels every step, so the factor is
    /// kept separately; otherwise a wheel down can never return to exactly
    /// 100% and stops one pixel short (measured as "stuck at 101%").
    zoom: f64,
    display_bytes: u64,
    drag: Option<DragState>,
    resize: Option<ResizeState>,
    shown: bool,
    wants_topmost: bool,
}

/// Rounded corners and the soft glow that separate a pin from the desktop.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct PinDecor {
    /// Width of the glow band around the photo, in physical pixels.
    margin: i32,
    /// Corner radius of the photo, in physical pixels.
    radius: i32,
    /// Width of the glow's fade, in physical pixels.
    blur: i32,
}

impl PinDecor {
    fn for_scale(scale: f64) -> Self {
        let scale = if scale.is_finite() && scale > 0.0 { scale } else { 1.0 };
        let scaled = |value: f64, limit: i32| {
            (value * scale).round().clamp(0.0, f64::from(limit)) as i32
        };
        Self {
            margin: scaled(PIN_GLOW_MARGIN_DIP, PIN_GLOW_MARGIN_MAX),
            radius: scaled(PIN_CORNER_RADIUS_DIP, PIN_CORNER_RADIUS_MAX),
            blur: scaled(PIN_GLOW_BLUR_DIP, PIN_GLOW_BLUR_MAX),
        }
    }

    /// The window rectangle that contains `frame` plus its glow band.
    fn window_rect(self, frame: PinRect) -> PinRect {
        PinRect::new(
            frame.x - self.margin,
            frame.y - self.margin,
            frame.width + self.margin * 2,
            frame.height + self.margin * 2,
        )
    }
}

struct DragState {
    start_cursor: (i32, i32),
    start_frame: PinRect,
}

/// How close to the photo edge a pointer press must be to resize instead of
/// move the pin, in DIP.
const PIN_RESIZE_HANDLE_DIP: f64 = 8.0;

/// Which photo edges the pointer grabbed. Corners set two flags.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct PinHandle {
    left: bool,
    right: bool,
    top: bool,
    bottom: bool,
}

impl PinHandle {
    /// The handle under a screen point, if the point is inside the photo and
    /// close enough to an edge (or corner) to start a proportional resize.
    fn at(frame: PinRect, x: i32, y: i32, scale: f64) -> Option<Self> {
        if x < frame.x || x >= frame.right() || y < frame.y || y >= frame.bottom() {
            return None;
        }
        let margin = (PIN_RESIZE_HANDLE_DIP * scale.max(1.0)).round() as i32;
        let margin = margin.clamp(4, frame.width.min(frame.height) / 3);
        let left = x - frame.x <= margin;
        let right = frame.right() - x <= margin;
        let top = y - frame.y <= margin;
        let bottom = frame.bottom() - y <= margin;
        // A frame narrower than twice the margin cannot tell the sides apart;
        // the corner flags still work, so keep the near edge only.
        let left = left && !right;
        let right = right && !left;
        let top = top && !bottom;
        let bottom = bottom && !top;
        if !(left || right || top || bottom) {
            return None;
        }
        Some(Self { left, right, top, bottom })
    }

    /// Fraction of the photo that stays fixed while resizing: the opposite
    /// edge for an edge handle, the opposite corner for a corner handle.
    fn anchor(self) -> (f64, f64) {
        let x = if self.left {
            1.0
        } else if self.right {
            0.0
        } else {
            0.5
        };
        let y = if self.top {
            1.0
        } else if self.bottom {
            0.0
        } else {
            0.5
        };
        (x, y)
    }

    fn cursor_description(self) -> PinCursor {
        match (self.left || self.right, self.top || self.bottom) {
            (true, true) => {
                if (self.left && self.top) || (self.right && self.bottom) {
                    PinCursor::NorthWestSouthEast
                } else {
                    PinCursor::NorthEastSouthWest
                }
            }
            (true, false) => PinCursor::WestEast,
            (false, true) => PinCursor::NorthSouth,
            (false, false) => PinCursor::Arrow,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum PinCursor {
    Arrow,
    Move,
    WestEast,
    NorthSouth,
    NorthWestSouthEast,
    NorthEastSouthWest,
}

struct ResizeState {
    start_cursor: (i32, i32),
    start_frame: PinRect,
    handle: PinHandle,
}

pub fn open(app: &AppHandle, spec: PinSpec) -> Result<PinId, String> {
    let _ = APP_HANDLE.set(app.clone());
    let host = ensure_surface().map_err(|error| error.to_string())?;
    let (reply, answer) = mpsc::sync_channel(1);
    let request = Box::into_raw(Box::new(OpenRequest { app: app.clone(), spec, reply }));
    let posted = unsafe {
        PostMessageW(Some(hwnd(host)), WM_PIN_OPEN, WPARAM(0), LPARAM(request as isize))
    };
    if let Err(error) = posted {
        // Nobody else owns the box when the post fails.
        unsafe { drop(Box::from_raw(request)) };
        return Err(format!("The pinned screenshot could not be opened: {error}"));
    }
    match answer.recv_timeout(Duration::from_secs(10)) {
        Ok(Ok(id)) => Ok(id),
        Ok(Err(error)) => Err(error.to_string()),
        Err(_) => Err("The pinned screenshot did not open in time.".into()),
    }
}

/// Extended style a pin is created with.
///
/// `WS_EX_NOACTIVATE` is what actually keeps the user's application focused.
/// Returning `MA_NOACTIVATE` alone is not enough on Windows 10: clicking an
/// inactive topmost layered window still cancels the previous foreground
/// window first, leaving the desktop with no foreground window at all
/// (measured). The style is added only while the system routes wheel input to
/// the window under the cursor; with hover routing turned off a pin must be
/// able to become foreground so the wheel can reach it.
fn activation_ex_style() -> WINDOW_EX_STYLE {
    let base = WS_EX_TOOLWINDOW | WS_EX_TOPMOST;
    if WHEEL_ROUTES_ON_HOVER.load(Ordering::Acquire) {
        base | WS_EX_NOACTIVATE
    } else {
        base
    }
}

/// Applies the style that matches the current wheel-routing setting.
///
/// The setting can change while pins exist, and each pin is a top-level window
/// that receives `WM_SETTINGCHANGE` itself. Reading it once at creation would
/// leave old pins unable to activate after hover routing is turned off, or
/// leave them cancelling the user's foreground window after it is turned on.
fn sync_activation_style(window: HWND) {
    // Only `WS_EX_NOACTIVATE` belongs to this function. Re-applying the whole
    // activation style would also restore `WS_EX_TOPMOST` after the user chose
    // "unpin": a later `WM_SETTINGCHANGE` (theme, device, display change) would
    // silently put an explicitly unpinned reference back into the topmost band.
    let no_activate = activation_ex_style().0 as isize & WS_EX_NOACTIVATE.0 as isize;
    unsafe {
        let current = GetWindowLongPtrW(window, GWL_EXSTYLE);
        let next = (current & !(WS_EX_NOACTIVATE.0 as isize)) | no_activate;
        if next != current {
            SetWindowLongPtrW(window, GWL_EXSTYLE, next);
        }
    }
}

/// Creates one pin window and opts it into layered rendering.
///
/// A pin must be excluded from screen capture, and Windows rejects
/// `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)` on a window that already
/// carries `WS_EX_LAYERED`: the first call fails with
/// `ERROR_NOT_ENOUGH_MEMORY` (8) and the affinity stays `WDA_NONE`, so every
/// pin would show up in Kiri's own screenshots. The window is created
/// unlayered, excluded, and only then switched to `UpdateLayeredWindow`
/// rendering; the affinity survives that style change (verified on Windows 10
/// 21H2). Do not move the style into `CreateWindowExW`.
fn create_pin_window(instance: HINSTANCE, frame: PinRect, decor: PinDecor) -> Result<HWND> {
    let ex_style = activation_ex_style();
    let window_rect = decor.window_rect(frame);
    let window = unsafe {
        CreateWindowExW(
            ex_style,
            w!(r"KiriPinWindow"),
            w!("Lumen Pin"),
            WS_POPUP,
            window_rect.x,
            window_rect.y,
            window_rect.width,
            window_rect.height,
            None,
            None,
            Some(instance),
            None,
        )
    }
    .map_err(|error| anyhow!("The pinned screenshot window could not be created: {error}"))?;
    enable_layered_rendering(window);
    Ok(window)
}

/// Excludes a window from screen capture, then switches it to
/// `UpdateLayeredWindow` rendering. See [`create_pin_window`] for why the order
/// cannot be reversed.
fn enable_layered_rendering(window: HWND) {
    exclude_from_capture(window);
    unsafe {
        let style = GetWindowLongPtrW(window, GWL_EXSTYLE) | WS_EX_LAYERED.0 as isize;
        SetWindowLongPtrW(window, GWL_EXSTYLE, style);
    }
}

fn exclude_from_capture(window: HWND) {
    if let Err(error) = unsafe { SetWindowDisplayAffinity(window, WDA_EXCLUDEFROMCAPTURE) } {
        log::warn!("[pin] capture exclusion unavailable: {error}");
    }
}

/// Keeps a new pin inside the work area of the monitor it opens on.
fn clamp_frame_into_workarea(frame: PinRect) -> PinRect {
    unsafe {
        let point = POINT { x: frame.x, y: frame.y };
        let monitor = MonitorFromPoint(point, MONITOR_DEFAULTTONEAREST);
        let mut info = MONITORINFO {
            cbSize: std::mem::size_of::<MONITORINFO>() as u32,
            ..Default::default()
        };
        if GetMonitorInfoW(monitor, &mut info).as_bool() {
            let work = info.rcWork;
            return frame.clamp_into(PinRect::new(
                work.left,
                work.top,
                work.right - work.left,
                work.bottom - work.top,
            ));
        }
    }
    frame
}
fn create_pin(app: &AppHandle, spec: PinSpec) -> Result<PinId> {
    let scale = if spec.scale.is_finite() && spec.scale > 0.0 { spec.scale } else { 1.0 };
    // The setting can change while no pin exists, and message-only windows do
    // not receive the broadcast, so read it again before the first click.
    refresh_wheel_routing();
    // A pin never opens above the display-budget, even for a stitched capture.
    // A pin must land on a screen the user is looking at. A placement carried
    // over from a capture is already on-screen, but a display change or a DPI
    // conversion can push the frame past an edge; clamping keeps the card
    // reachable instead of silently invisible.
    let mut frame = clamp_frame_into_workarea(spec.frame);
    let pixels = u64::from(frame.width.max(1) as u32) * u64::from(frame.height.max(1) as u32);
    if pixels > super::MAX_PIN_DISPLAY_PIXELS {
        frame = zoom_frame(frame, 1.0, (0.5, 0.5), Some(spec.image.aspect()), scale);
    }
    let instance = unsafe { HINSTANCE(GetModuleHandleW(None)?.0) };
    let decor = PinDecor::for_scale(scale);
    let window = create_pin_window(instance, frame, decor)?;

    let id = match with_pins(app, |pins| {
        pins.insert(window.0 as isize, frame, spec.origin, spec.image.bytes())
    }) {
        Ok(id) => id,
        Err(error) => {
            unsafe {
                let _ = DestroyWindow(window);
            }
            return Err(anyhow!(error));
        }
    };

    let initial_zoom =
        f64::from(frame.width.max(1)) / f64::from(spec.image.width.max(1).max(1));
    let state = Box::new(PinState {
        app: app.clone(),
        label: id.label(),
        instance: id.0,
        image: spec.image,
        frame,
        decor,
        scale,
        generation: 0,
        zoom: initial_zoom,
        display_bytes: 0,
        drag: None,
        resize: None,
        shown: false,
        wants_topmost: true,
    });
    let pointer = Box::into_raw(state);
    unsafe { SetWindowLongPtrW(window, GWLP_USERDATA, pointer as isize) };

    if let Err(error) = start_first_frame(window, pointer) {
        unsafe {
            let _ = DestroyWindow(window);
        }
        return Err(error);
    }
    log::info!("[pin] opened id={} size={}x{}", id.0, frame.width, frame.height);
    Ok(id)
}

/// Uploads the opening frame. At 1:1 this is one copy plus a single
/// `UpdateLayeredWindow`, so the pin appears immediately; a resize is handed to
/// the resample worker and the pin is shown when that frame arrives.
fn start_first_frame(window: HWND, state: *mut PinState) -> Result<()> {
    let state = unsafe { &mut *state };
    let target = (state.frame.width.max(1) as u32, state.frame.height.max(1) as u32);
    if target == (state.image.width, state.image.height) {
        upload_pin_frame(
            window,
            &state.image.bgra,
            state.image.width as i32,
            state.image.height as i32,
            state.decor,
        )?;
        show_pin(window, state);
        return Ok(());
    }
    if !request_frame(window, state) {
        render_frame_inline(window, state);
    }
    Ok(())
}

fn show_pin(window: HWND, state: &mut PinState) {
    if state.shown {
        return;
    }
    state.shown = true;
    unsafe {
        let _ = ShowWindow(window, SW_SHOWNOACTIVATE);
    }
    // A pin is always a topmost reference card. The capture gate pushes
    // existing pins down while a screenshot is being selected, but a pin
    // created at the very end of a capture can race that gate: if the gate for
    // the closing session already ran, a pin sent to the bottom would never be
    // brought back and the user would see nothing at all. Claim the band now,
    // and again shortly after in case a late gate message still moves it.
    assert_topmost(window);
    let window_rect = state.decor.window_rect(state.frame);
    log::info!(
        "[pin] shown frame={}x{} at {},{} window={}x{} at {},{}",
        state.frame.width,
        state.frame.height,
        state.frame.x,
        state.frame.y,
        window_rect.width,
        window_rect.height,
        window_rect.x,
        window_rect.y
    );
    let raw = window.0 as isize;
    let _ = std::thread::Builder::new()
        .name("kiri-pin-topmost".into())
        .spawn(move || {
            std::thread::sleep(std::time::Duration::from_millis(260));
            let window = hwnd(raw);
            if !CAPTURE_OVERLAY_ACTIVE.load(Ordering::Acquire) {
                assert_topmost(window);
            }
        });
    ensure_hooks(state.app.clone());
}

// ---------------------------------------------------------------------------
// Pixels
// ---------------------------------------------------------------------------

fn request_frame(window: HWND, state: &mut PinState) -> bool {
    let Some(sender) = render_sender() else { return false };
    let job = RenderJob {
        hwnd: window.0 as isize,
        instance: state.instance,
        generation: state.generation,
        image: state.image.clone(),
        width: state.frame.width.max(1) as u32,
        height: state.frame.height.max(1) as u32,
    };
    if sender.send(job).is_err() {
        log::warn!("[pin] resample worker is unavailable");
        return false;
    }
    true
}

/// Last-resort frame render on the surface thread.
///
/// Only used when the resample worker cannot be started. A pin that never
/// receives a frame would be invisible yet registered and impossible to close,
/// which is worse than one blocking frame.
fn render_frame_inline(window: HWND, state: &mut PinState) {
    let width = state.frame.width.max(1) as u32;
    let height = state.frame.height.max(1) as u32;
    let pixels = resample::resample(&state.image, width, height);
    apply_frame(
        window,
        state,
        RenderResult { instance: state.instance, generation: state.generation, width, height, pixels },
    );
}

fn render_sender() -> Option<mpsc::Sender<RenderJob>> {
    let mut queue = RENDER_QUEUE.lock().unwrap_or_else(|p| p.into_inner());
    if let Some(sender) = queue.as_ref() {
        return Some(sender.clone());
    }
    let (sender, receiver) = mpsc::channel::<RenderJob>();
    let spawned = thread::Builder::new()
        .name("kiri-pin-resample".into())
        .spawn(move || run_resample_worker(receiver));
    if let Err(error) = spawned {
        log::error!("[pin] resample worker could not start: {error}");
        return None;
    }
    *queue = Some(sender.clone());
    Some(sender)
}

fn run_resample_worker(receiver: mpsc::Receiver<RenderJob>) {
    let mut latest: HashMap<isize, RenderJob> = HashMap::new();
    loop {
        let Ok(job) = receiver.recv() else { break };
        latest.insert(job.hwnd, job);
        // Coalesce a wheel burst: only the newest size per window is rendered.
        while let Ok(job) = receiver.try_recv() {
            latest.insert(job.hwnd, job);
        }
        for (_, job) in std::mem::take(&mut latest) {
            let pixels = resample::resample(&job.image, job.width, job.height);
            let result = Box::into_raw(Box::new(RenderResult {
                instance: job.instance,
                generation: job.generation,
                width: job.width,
                height: job.height,
                pixels,
            }));
            let posted = unsafe {
                PostMessageW(Some(hwnd(job.hwnd)), WM_PIN_FRAME, WPARAM(0), LPARAM(result as isize))
            };
            if posted.is_err() {
                unsafe { drop(Box::from_raw(result)) };
            }
        }
    }
}

struct RenderJob {
    hwnd: isize,
    instance: u64,
    generation: u64,
    image: super::PinImage,
    width: u32,
    height: u32,
}

struct RenderResult {
    instance: u64,
    generation: u64,
    width: u32,
    height: u32,
    pixels: std::sync::Arc<[u8]>,
}

/// Uploads one premultiplied BGRA frame into a layered window.
///
/// `fill` writes the whole bitmap, which is what lets a pin frame be composed
/// from a photo plus its glow without an intermediate full-size buffer.
fn upload_layered(
    window: HWND,
    width: i32,
    height: i32,
    fill: impl FnOnce(&mut [u8]),
) -> Result<()> {
    if width <= 0 || height <= 0 {
        return Err(anyhow!("The pinned image size is invalid."));
    }
    unsafe {
        let screen = GetDC(None);
        let device = CreateCompatibleDC(Some(screen));
        let header = BITMAPINFOHEADER {
            biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: width,
            // Negative height selects a top-down DIB.
            biHeight: -height,
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB.0,
            ..Default::default()
        };
        let info = BITMAPINFO { bmiHeader: header, ..Default::default() };
        let mut bits: *mut c_void = std::ptr::null_mut();
        let bitmap = CreateDIBSection(Some(device), &info, DIB_RGB_COLORS, &mut bits, None, 0)?;
        let previous = SelectObject(device, HGDIOBJ(bitmap.0));
        let pixels = std::slice::from_raw_parts_mut(
            bits as *mut u8,
            width as usize * height as usize * 4,
        );
        fill(pixels);
        let size = SIZE { cx: width, cy: height };
        let origin = POINT { x: 0, y: 0 };
        let blend = BLENDFUNCTION {
            BlendOp: AC_SRC_OVER as u8,
            BlendFlags: 0,
            SourceConstantAlpha: 255,
            AlphaFormat: AC_SRC_ALPHA as u8,
        };
        // `None` for the destination point keeps the geometry SetWindowPos
        // already applied; only the content is submitted.
        let result = UpdateLayeredWindow(
            window,
            None,
            None,
            Some(&size),
            Some(device),
            Some(&origin),
            COLORREF(0),
            Some(&blend),
            ULW_ALPHA,
        );
        SelectObject(device, previous);
        let _ = DeleteObject(HGDIOBJ(bitmap.0));
        let _ = DeleteDC(device);
        ReleaseDC(None, screen);
        result.map_err(|error| anyhow!("The pinned image could not be drawn: {error}"))
    }
}

fn upload(window: HWND, pixels: &[u8], width: i32, height: i32) -> Result<()> {
    if width <= 0 || height <= 0 || pixels.len() != width as usize * height as usize * 4 {
        return Err(anyhow!("The pinned image size does not match its pixels."));
    }
    upload_layered(window, width, height, |bits| bits.copy_from_slice(pixels))
}

/// Uploads a pin frame: the photo, rounded, over its glow.
///
/// The window is larger than the photo by `decor.margin` per side, and the DIB
/// is created at that size, so `UpdateLayeredWindow` keeps the geometry the pin
/// already has instead of resizing it.
fn upload_pin_frame(
    window: HWND,
    photo: &[u8],
    width: i32,
    height: i32,
    decor: PinDecor,
) -> Result<()> {
    if width <= 0 || height <= 0 || photo.len() != width as usize * height as usize * 4 {
        return Err(anyhow!("The pinned image size does not match its pixels."));
    }
    let window_rect = decor.window_rect(PinRect::new(0, 0, width, height));
    upload_layered(window, window_rect.width, window_rect.height, |bits| {
        compose_pin_frame(bits, window_rect.width, window_rect.height, photo, width, height, decor);
    })
}

/// Signed distance from a point to a rounded rectangle anchored at the origin.
/// Negative inside, positive outside, in pixels.
fn rounded_rect_distance(x: f64, y: f64, width: f64, height: f64, radius: f64) -> f64 {
    let half_width = width * 0.5;
    let half_height = height * 0.5;
    let straight_x = (x - half_width).abs() - (half_width - radius);
    let straight_y = (y - half_height).abs() - (half_height - radius);
    let outside = (straight_x.max(0.0).powi(2) + straight_y.max(0.0).powi(2)).sqrt();
    outside + straight_x.max(straight_y).min(0.0) - radius
}

/// Alpha of the glow for a point `distance` signed pixels from the photo's
/// rounded rectangle: negative inside, positive outside.
///
/// Full strength against the photo edge, fading smoothly to nothing one blur
/// width outside it. The band is white, so it lifts a pin off the desktop
/// instead of casting a dark shadow.
fn glow_alpha(distance: f64, blur: i32) -> u8 {
    if blur <= 0 || !distance.is_finite() {
        return 0;
    }
    let falloff = 1.0 - (distance.max(0.0) / f64::from(blur)).clamp(0.0, 1.0);
    (PIN_GLOW_ALPHA * falloff * falloff * 255.0).round().clamp(0.0, 255.0) as u8
}

/// Draws one pin frame into a top-down premultiplied BGRA bitmap.
///
/// `bits` is the whole window; the photo is inset by `decor.margin`, its
/// corners are cut to `decor.radius`, and the band around it holds the glow.
/// Every pixel of `bits` is written, so the caller does not have to clear it.
fn compose_pin_frame(
    bits: &mut [u8],
    window_width: i32,
    window_height: i32,
    photo: &[u8],
    width: i32,
    height: i32,
    decor: PinDecor,
) {
    let (window_width_px, window_height_px) = (window_width as usize, window_height as usize);
    let (width_px, height_px) = (width as usize, height as usize);
    if width <= 0
        || height <= 0
        || window_width <= 0
        || window_height <= 0
        || bits.len() < window_width_px * window_height_px * 4
        || photo.len() < width_px * height_px * 4
    {
        return;
    }
    let margin = decor.margin;
    let radius = decor.radius.min(width.min(height) / 2).max(0);
    let row_bytes = width_px * 4;
    for y in 0..height_px {
        let src = y * row_bytes;
        let dst = ((y + margin as usize) * window_width_px + margin as usize) * 4;
        bits[dst..dst + row_bytes].copy_from_slice(&photo[src..src + row_bytes]);
    }

    let photo_width = f64::from(width);
    let photo_height = f64::from(height);
    let radius_px = f64::from(radius);

    // One band pixel: premultiplied BGRA for the glow around the photo.
    let band_pixel = |x: i32, y: i32| -> [u8; 4] {
        let distance = rounded_rect_distance(
            f64::from(x - margin) + 0.5,
            f64::from(y - margin) + 0.5,
            photo_width,
            photo_height,
            radius_px,
        );
        // Premultiplied pale blue: the channels are the tint scaled by the
        // glow alpha, so the band only lightens what is behind the pin.
        let glow = glow_alpha(distance, decor.blur);
        let scale = f64::from(glow) / 255.0;
        [
            (PIN_GLOW_TINT[0] * scale).round() as u8,
            (PIN_GLOW_TINT[1] * scale).round() as u8,
            (PIN_GLOW_TINT[2] * scale).round() as u8,
            glow,
        ]
    };

    // The band: everything outside the photo rectangle.
    if margin > 0 {
        let mut write_band = |x: i32, y: i32| {
            let pixel = band_pixel(x, y);
            let offset = (y as usize * window_width_px + x as usize) * 4;
            bits[offset] = pixel[0];
            bits[offset + 1] = pixel[1];
            bits[offset + 2] = pixel[2];
            bits[offset + 3] = pixel[3];
        };
        for y in 0..margin {
            for x in 0..window_width {
                write_band(x, y);
            }
        }
        for y in (margin + height)..window_height {
            for x in 0..window_width {
                write_band(x, y);
            }
        }
        for y in margin..(margin + height) {
            for x in 0..margin {
                write_band(x, y);
            }
            for x in (margin + width)..window_width {
                write_band(x, y);
            }
        }
    }

    // The corners: cut the photo to the rounded rectangle. A one-pixel band is
    // blended so the arc is antialiased, and the uncovered part shows the
    // glow underneath instead of the photo.
    if radius > 0 {
        let corners = [
            (margin, margin),
            (margin + width - radius, margin),
            (margin, margin + height - radius),
            (margin + width - radius, margin + height - radius),
        ];
        for (corner_x, corner_y) in corners {
            for y in corner_y..(corner_y + radius).min(window_height) {
                for x in corner_x..(corner_x + radius).min(window_width) {
                    let distance = rounded_rect_distance(
                        f64::from(x - margin) + 0.5,
                        f64::from(y - margin) + 0.5,
                        photo_width,
                        photo_height,
                        radius_px,
                    );
                    let coverage = (0.5 - distance).clamp(0.0, 1.0);
                    if coverage >= 1.0 {
                        continue;
                    }
                    let under = band_pixel(x, y);
                    let offset = (y as usize * window_width_px + x as usize) * 4;
                    for (channel, under_value) in under.iter().enumerate() {
                        let value = f64::from(bits[offset + channel]) * coverage
                            + f64::from(*under_value) * (1.0 - coverage);
                        bits[offset + channel] = value.round().clamp(0.0, 255.0) as u8;
                    }
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Window procedure
// ---------------------------------------------------------------------------

unsafe extern "system" fn pin_proc(window: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    let state = GetWindowLongPtrW(window, GWLP_USERDATA) as *mut PinState;
    match msg {
        WM_SETCURSOR => {
            // The pointer means "move this pin" in the middle and "resize it
            // proportionally" within the edge band. Returning TRUE stops
            // DefWindowProc from clearing the cursor again.
            let mut cursor = PinCursor::Arrow;
            if !state.is_null() {
                let state = unsafe { &*state };
                if state.drag.is_some() {
                    cursor = PinCursor::Move;
                } else if let Some(resize) = state.resize.as_ref() {
                    cursor = resize.handle.cursor_description();
                } else {
                    let mut point = POINT::default();
                    if unsafe { GetCursorPos(&mut point) }.is_ok() {
                        if let Some(handle) =
                            PinHandle::at(state.frame, point.x, point.y, state.scale)
                        {
                            cursor = handle.cursor_description();
                        }
                    }
                }
            }
            let id = match cursor {
                PinCursor::Move => IDC_SIZEALL,
                PinCursor::WestEast => IDC_SIZEWE,
                PinCursor::NorthSouth => IDC_SIZENS,
                PinCursor::NorthWestSouthEast => IDC_SIZENWSE,
                PinCursor::NorthEastSouthWest => IDC_SIZENESW,
                PinCursor::Arrow => IDC_ARROW,
            };
            let _ = unsafe { SetCursor(LoadCursorW(None, id).ok()) };
            LRESULT(1)
        }
        WM_NCHITTEST => {
            // The glow band is decoration: it must not swallow clicks meant
            // for the window underneath it. Layered windows already pass
            // fully transparent pixels through, but the band is translucent,
            // so hit testing would otherwise leave an invisible frame around
            // every pin that blocks the desktop and the wheel.
            //
            // A capture overlay is the one window a pin must never cover: the
            // toolbar sits under it while the user picks a region, and a click
            // that lands on a pin is a click the overlay never receives.
            if CAPTURE_OVERLAY_ACTIVE.load(Ordering::Acquire) {
                return LRESULT(-1);
            }
            if state.is_null() {
                return LRESULT(-1);
            }
            let state = unsafe { &*state };
            let x = (lparam.0 & 0xFFFF) as u16 as i16 as i32;
            let y = ((lparam.0 >> 16) & 0xFFFF) as u16 as i16 as i32;
            let distance = rounded_rect_distance(
                f64::from(x - state.frame.x) + 0.5,
                f64::from(y - state.frame.y) + 0.5,
                f64::from(state.frame.width.max(1)),
                f64::from(state.frame.height.max(1)),
                f64::from(state.decor.radius.max(0).min(state.frame.width.min(state.frame.height) / 2)),
            );
            if distance <= 0.5 { LRESULT(1) } else { LRESULT(-1) }
        }
        WM_MOUSEACTIVATE => {
            // Clicking a pin must not take focus from the application the user
            // is working in. `WS_EX_NOACTIVATE` is what makes that true on
            // Windows 10; see `activation_ex_style`. The fallback exists for
            // systems that route the wheel only to the focused window: there a
            // pin must be able to become foreground, or the wheel never reaches
            // it.
            if WHEEL_ROUTES_ON_HOVER.load(Ordering::Acquire) {
                LRESULT(MA_NOACTIVATE as isize)
            } else {
                LRESULT(MA_ACTIVATE as isize)
            }
        }
        WM_LBUTTONDOWN => {
            if !state.is_null() {
                begin_drag(window, &mut *state);
            }
            LRESULT(0)
        }
        WM_MOUSEMOVE => {
            if !state.is_null() && ((*state).drag.is_some() || (*state).resize.is_some()) {
                // A release that happened outside the pin is normally caught by
                // the mouse hook, but the hook can miss the very last event.
                // Never keep applying a gesture whose button is already up.
                let pressed =
                    unsafe { GetAsyncKeyState(VK_LBUTTON.0 as i32) } as u16 & 0x8000 != 0;
                if pressed {
                    drag_to_cursor(window, &mut *state);
                } else {
                    (*state).drag = None;
                    (*state).resize = None;
                    end_drag();
                }
            }
            LRESULT(0)
        }
        WM_LBUTTONUP => {
            if !state.is_null() {
                // A click (rather than a drag) selects the pin and gives it the
                // keyboard, so the arrow keys and Escape work on the card the
                // user just picked even when the low-level hook cannot see the
                // key (input aimed at our own process).
                let clicked = (*state).drag.as_ref().is_some_and(|drag| {
                    let mut point = POINT::default();
                    unsafe { GetCursorPos(&mut point) }.is_ok()
                        && (point.x - drag.start_cursor.0).abs() <= 3
                        && (point.y - drag.start_cursor.1).abs() <= 3
                });
                (*state).drag = None;
                (*state).resize = None;
                if clicked {
                    activate_pin(window);
                }
            }
            ACTIVE_PIN.store(window.0 as isize, Ordering::Release);
            end_drag();
            LRESULT(0)
        }
        WM_KEYDOWN => {
            if !state.is_null() {
                match wparam.0 as u32 {
                    vk if vk == VK_ESCAPE.0 as u32 => {
                        let _ = unsafe {
                            PostMessageW(Some(window), WM_PIN_CLOSE, WPARAM(0), LPARAM(0))
                        };
                    }
                    vk if vk == VK_LEFT.0 as u32 => nudge_pin(window, &mut *state, -1, 0),
                    vk if vk == VK_RIGHT.0 as u32 => nudge_pin(window, &mut *state, 1, 0),
                    vk if vk == VK_UP.0 as u32 => nudge_pin(window, &mut *state, 0, -1),
                    vk if vk == VK_DOWN.0 as u32 => nudge_pin(window, &mut *state, 0, 1),
                    _ => {}
                }
            }
            LRESULT(0)
        }
        WM_PIN_NUDGE => {
            if !state.is_null() {
                nudge_pin(window, &mut *state, wparam.0 as i32, lparam.0 as i32);
            }
            LRESULT(0)
        }
        WM_MOUSEWHEEL => {
            if !state.is_null() {
                let delta = ((wparam.0 >> 16) & 0xFFFF) as u16 as i16;
                let x = (lparam.0 & 0xFFFF) as u16 as i16 as i32;
                let y = ((lparam.0 >> 16) & 0xFFFF) as u16 as i16 as i32;
                zoom_pin(window, &mut *state, delta, x, y);
            }
            LRESULT(0)
        }
        WM_RBUTTONUP => {
            // A menu is already tracking on this thread. Opening a nested one
            // would let the inner loop clear `MENU_OPEN` while the outer menu
            // still holds `state`, so a right-click during a menu is ignored
            // and the outside-click hook has already dismissed it.
            if !state.is_null() && !MENU_OPEN.load(Ordering::Acquire) {
                // The menu belongs to the pin the user pointed at, which must
                // also be the one on top of its siblings.
                raise_pin_window(window, &mut *state);
                show_menu(window, &mut *state, lparam);
            }
            LRESULT(0)
        }
        WM_COMMAND => {
            // `TrackPopupMenu` runs a nested message loop inside `show_menu`,
            // which still holds `state`. Closing a window from here would free
            // that state while the menu call is unwinding (and destroying the
            // menu's owner mid-track), so every command is re-posted and runs
            // after the menu loop has returned.
            let _ = unsafe {
                PostMessageW(Some(window), WM_PIN_COMMAND, wparam, LPARAM(0))
            };
            LRESULT(0)
        }
        WM_PIN_COMMAND => {
            if !state.is_null() {
                match (wparam.0 & 0xFFFF) as usize {
                    1 => {
                        let _ = DestroyWindow(window);
                    }
                    2 => close_all_pins(),
                    3 => toggle_topmost(window, &mut *state),
                    _ => {}
                }
            }
            LRESULT(0)
        }
        WM_PIN_DRAG => {
            if !state.is_null() {
                drag_to(window, &mut *state, wparam.0 as i32, lparam.0 as i32);
            }
            LRESULT(0)
        }
        WM_PIN_DRAG_END => {
            if !state.is_null() {
                (*state).drag = None;
                (*state).resize = None;
            }
            end_drag();
            LRESULT(0)
        }
        WM_PIN_FRAME => {
            let result = *Box::from_raw(lparam.0 as *mut RenderResult);
            if !state.is_null() {
                apply_frame(window, &mut *state, result);
            }
            LRESULT(0)
        }
        WM_PIN_CLOSE => {
            let _ = DestroyWindow(window);
            LRESULT(0)
        }
        WM_SETTINGCHANGE => {
            refresh_wheel_routing();
            // The style must follow the setting for pins that already exist.
            sync_activation_style(window);
            DefWindowProcW(window, msg, wparam, lparam)
        }
        WM_PAINT => {
            let _ = ValidateRect(Some(window), None);
            LRESULT(0)
        }
        WM_ERASEBKGND => LRESULT(1),
        WM_NCDESTROY => {
            let state = GetWindowLongPtrW(window, GWLP_USERDATA) as *mut PinState;
            if !state.is_null() {
                SetWindowLongPtrW(window, GWLP_USERDATA, 0);
                let state = Box::from_raw(state);
                release_pin(window, &state);
            }
            DefWindowProcW(window, msg, wparam, lparam)
        }
        _ => DefWindowProcW(window, msg, wparam, lparam),
    }
}

fn apply_frame(window: HWND, state: &mut PinState, result: RenderResult) {
    // A window handle can be reused after its pin closed. The instance number
    // is what tells those two windows apart.
    if result.instance != state.instance {
        return;
    }
    if result.generation != state.generation {
        // A newer size was requested while this frame was being rendered.
        return;
    }
    if let Err(error) = upload_pin_frame(
        window,
        &result.pixels,
        result.width as i32,
        result.height as i32,
        state.decor,
    ) {
        log::warn!("[pin] frame upload failed: {error}");
        return;
    }
    let bytes = if result.width == state.image.width && result.height == state.image.height {
        // Back at 100%: the snapshot itself is the displayed frame.
        0
    } else {
        result.pixels.len() as u64
    };
    if state.display_bytes != bytes {
        state.display_bytes = bytes;
        let label = state.label.clone();
        with_pins(&state.app, |pins| pins.set_display_bytes(&label, bytes));
    }
    show_pin(window, state);
}

fn release_pin(window: HWND, state: &PinState) {
    let closed = with_pins(&state.app, |pins| {
        pins.remove_by_hwnd(window.0 as isize)
    });
    let _ = ACTIVE_PIN.compare_exchange(
        window.0 as isize,
        0,
        Ordering::AcqRel,
        Ordering::Acquire,
    );
    if closed.is_some() {
        log::info!("[pin] closed label={}", state.label);
    }
    // A pin closed while it was being dragged must not leave the low-level
    // mouse hook sampling for a dead window.
    if DRAG_TARGET.load(Ordering::Acquire) == window.0 as isize {
        end_drag();
    }
    if with_pins(&state.app, |pins| pins.is_empty()) {
        // No hook may outlive the last pin.
        unhook_everything();
        hide_badge();
    }
}

// ---------------------------------------------------------------------------
// Drag
// ---------------------------------------------------------------------------

/// Gives a clicked pin the keyboard without moving it in the z-order.
///
/// Pins normally never activate, so hovering one leaves the user's application
/// focused. Pressing a pin is an explicit selection: dropping the no-activate
/// style lets the window receive arrow keys and Escape directly instead of
/// relying on the global hook, which Windows does not call for input aimed at
/// the process that installed it.
fn activate_pin(window: HWND) {
    unsafe {
        let style = GetWindowLongPtrW(window, GWL_EXSTYLE);
        let next = style & !(WS_EX_NOACTIVATE.0 as isize);
        if next != style {
            SetWindowLongPtrW(window, GWL_EXSTYLE, next);
        }
        let _ = SetForegroundWindow(window);
    }
}
/// Moves the selected pin by one keyboard step.
///
/// The step is expressed in DIP so it feels the same on scaled displays, and
/// the result is clamped to the monitor work area like a drag release.
fn nudge_pin(window: HWND, state: &mut PinState, x_units: i32, y_units: i32) {
    if x_units == 0 && y_units == 0 {
        return;
    }
    let step = (PIN_ARROW_STEP_DIP * state.scale).round().max(1.0) as i32;
    let next = PinRect::new(
        state.frame.x.saturating_add(x_units.saturating_mul(step)),
        state.frame.y.saturating_add(y_units.saturating_mul(step)),
        state.frame.width,
        state.frame.height,
    );
    let next =
        clamp_to_pointer_monitor(next, next.x + next.width / 2, next.y + next.height / 2);
    if next == state.frame {
        return;
    }
    state.frame = next;
    let rect = state.decor.window_rect(next);
    unsafe {
        let _ = SetWindowPos(
            window,
            Some(HWND_TOPMOST),
            rect.x,
            rect.y,
            rect.width,
            rect.height,
            SWP_NOACTIVATE | SWP_NOOWNERZORDER,
        );
    }
    let label = state.label.clone();
    with_pins(&state.app, |pins| pins.set_frame(&label, next));
}
fn begin_drag(window: HWND, state: &mut PinState) {
    // Pointing at a pin brings it above its siblings without activating it.
    raise_pin_window(window, state);
    ACTIVE_PIN.store(window.0 as isize, Ordering::Release);
    let mut point = POINT::default();
    if unsafe { GetCursorPos(&mut point) }.is_err() {
        return;
    }
    // Pressing near an edge resizes the photo (keeping its aspect ratio);
    // pressing anywhere else moves the window.
    let handle = PinHandle::at(state.frame, point.x, point.y, state.scale);
    if let Some(handle) = handle {
        state.resize = Some(ResizeState {
            start_cursor: (point.x, point.y),
            start_frame: state.frame,
            handle,
        });
        state.drag = None;
    } else {
        state.drag =
            Some(DragState { start_cursor: (point.x, point.y), start_frame: state.frame });
        state.resize = None;
    }
    DRAG_TARGET.store(window.0 as isize, Ordering::Release);
    LAST_DRAG_POST.store(0, Ordering::Release);
    install_mouse_hook();
}

/// Puts one pin on top of the whole topmost band and records the same order in
/// the registry.
///
/// The registry order is the band order: the foreground self-heal re-raises
/// pins in registry order, so a pin raised only natively would drop back below
/// its siblings on the next application switch.
///
/// A pin the user explicitly unpinned stays out of the band. Pointing at it
/// must not silently undo that choice; the WebView fallback has the same rule.
fn raise_pin_window(window: HWND, state: &mut PinState) {
    if !state.wants_topmost {
        return;
    }
    // The capture overlay owns the band while a screenshot is being taken.
    // Raising here would put this pin back above the frozen image and over
    // the toolbar the user is about to click.
    if CAPTURE_OVERLAY_ACTIVE.load(Ordering::Acquire) {
        return;
    }
    unsafe {
        let _ = SetWindowPos(
            window,
            Some(HWND_TOPMOST),
            0,
            0,
            0,
            0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER,
        );
    }
    let label = state.label.clone();
    let app = state.app.clone();
    with_pins(&app, |pins| pins.raise(&label));
}

fn drag_to_cursor(window: HWND, state: &mut PinState) {
    let mut point = POINT::default();
    if unsafe { GetCursorPos(&mut point) }.is_err() {
        return;
    }
    drag_to(window, state, point.x, point.y);
}

fn drag_to(window: HWND, state: &mut PinState, x: i32, y: i32) {
    if state.resize.is_some() {
        resize_to(window, state, x, y);
        return;
    }
    let Some(drag) = state.drag.as_ref() else { return };
    let frame = PinRect::new(
        drag.start_frame.x + (x - drag.start_cursor.0),
        drag.start_frame.y + (y - drag.start_cursor.1),
        drag.start_frame.width,
        drag.start_frame.height,
    );
    let frame = clamp_to_pointer_monitor(frame, x, y);
    if frame == state.frame {
        return;
    }
    state.frame = frame;
    let window_rect = state.decor.window_rect(frame);
    unsafe {
        let _ = SetWindowPos(
            window,
            None,
            window_rect.x,
            window_rect.y,
            0,
            0,
            SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOOWNERZORDER,
        );
    }
    let label = state.label.clone();
    let app = state.app.clone();
    with_pins(&app, |pins| pins.set_frame(&label, frame));
}

/// Keeps enough of a dragged pin on its monitor to be found again.
///
/// A pin is borderless, so one that is dropped completely off screen would be
/// impossible to right-click, close with Esc, or raise; the only recovery would
/// be restarting Kiri. The monitor under the pointer owns the bounds, which is
/// also what makes a drag across displays follow the display the user is on.
fn clamp_to_pointer_monitor(frame: PinRect, x: i32, y: i32) -> PinRect {
    let monitor = unsafe { MonitorFromPoint(POINT { x, y }, MONITOR_DEFAULTTONEAREST) };
    if monitor.is_invalid() {
        return frame;
    }
    let mut info =
        MONITORINFO { cbSize: std::mem::size_of::<MONITORINFO>() as u32, ..Default::default() };
    if !unsafe { GetMonitorInfoW(monitor, &mut info) }.as_bool() {
        return frame;
    }
    let area = info.rcWork;
    let margin = DRAG_VISIBLE_MARGIN.min(frame.width).min(frame.height).max(1);
    let left = area.left - frame.width + margin;
    let right = area.right - margin;
    let top = area.top - frame.height + margin;
    let bottom = area.bottom - margin;
    PinRect::new(
        frame.x.max(left.min(right)).min(right),
        frame.y.max(top.min(bottom)).min(bottom),
        frame.width,
        frame.height,
    )
}

fn end_drag() {
    DRAG_TARGET.store(0, Ordering::Release);
    let hook = MOUSE_HOOK.lock().unwrap_or_else(|p| p.into_inner()).take();
    if let Some(hook) = hook {
        unsafe {
            let _ = UnhookWindowsHookEx(HHOOK(hook as *mut c_void));
        }
    }
}

// ---------------------------------------------------------------------------
// Zoom
// ---------------------------------------------------------------------------

/// Applies one wheel step to the continuous zoom factor.
///
/// 100% is a detent: a step that would jump across it lands on it instead of
/// stopping beside it. Without this, 103% scrolled one notch down skipped to
/// 94% and the user could never get back to exactly 100% (reported as "stuck
/// at 101%"). A small tolerance also catches a trackpad that grazes 100%
/// without crossing it.
fn stepped_zoom(current: f64, factor: f64) -> f64 {
    let zoom = current * factor;
    let crossed = (current - 1.0).abs() > f64::EPSILON
        && (current - 1.0).is_sign_positive() != (zoom - 1.0).is_sign_positive();
    if crossed || (zoom - 1.0).abs() <= 0.02 {
        1.0
    } else {
        zoom
    }
}

fn zoom_pin(window: HWND, state: &mut PinState, delta: i16, cursor_x: i32, cursor_y: i32) {
    if delta == 0 {
        return;
    }
    let anchor = (
        (f64::from(cursor_x - state.frame.x) / f64::from(state.frame.width.max(1))).clamp(0.0, 1.0),
        (f64::from(cursor_y - state.frame.y) / f64::from(state.frame.height.max(1))).clamp(0.0, 1.0),
    );
    let factor = super::WHEEL_ZOOM_STEP.powf(f64::from(delta) / 120.0);
    // The displayed frame is a whole-pixel rectangle, so deriving the next
    // size from the previous rectangle loses the fraction of a pixel every
    // step. After a few wheel bursts that drift is visible as "cannot get back
    // to 100%". Keep the continuous factor instead, snap it to 1.0 when the
    // wheel comes back within half a step of it, and derive the rectangle from
    // the image's own pixels.
    let image_width = f64::from(state.image.width.max(1));
    let current = if state.zoom.is_finite() && state.zoom > 0.0 {
        state.zoom
    } else {
        f64::from(state.frame.width.max(1)) / image_width
    };
    let zoom = stepped_zoom(current, factor);
    let step = (image_width * zoom).round().max(1.0) / f64::from(state.frame.width.max(1));
    let next = zoom_frame_within(
        state.frame,
        step,
        anchor,
        Some(state.image.aspect()),
        state.scale,
        Some((state.image.width, state.image.height)),
    );
    let requested = (image_width * zoom).round().max(1.0);
    let applied_zoom = if (requested - f64::from(next.width)).abs() > 1.0 {
        f64::from(next.width) / image_width
    } else {
        zoom
    };
    commit_frame_size(window, state, next, applied_zoom);
    show_badge(state, anchor);
}

/// Applies a new photo rectangle, shared by wheel zoom and edge resizing.
///
/// Returns false when the size did not change or when the desktop-wide display
/// budget refused it. `zoom` is the continuous factor the caller wants to keep
/// (whole-pixel rounding means the applied rectangle can differ slightly).
fn commit_frame_size(window: HWND, state: &mut PinState, next: PinRect, zoom: f64) -> bool {
    if next == state.frame {
        return false;
    }
    // The scaled frames of all pins share one budget. A single pin is already
    // capped by `zoom_frame`; this keeps a desktop of them bounded as well.
    let next_bytes = super::frame_bytes(next, (state.image.width, state.image.height));
    let other_bytes = with_pins(&state.app, |pins| {
        pins.display_bytes()
            .saturating_sub(pins.display_bytes_of(&state.label))
    });
    if !super::display_budget_allows(other_bytes, next_bytes) {
        return false;
    }
    state.frame = next;
    state.zoom = if zoom.is_finite() && zoom > 0.0 {
        zoom
    } else {
        f64::from(next.width.max(1)) / f64::from(state.image.width.max(1))
    };
    // A gesture captured its origin when it began. Rebase it onto the new
    // frame, otherwise the next pointer sample would recompute the old size
    // from the stale origin and undo the change mid-gesture.
    let mut point = POINT::default();
    let cursor = unsafe { GetCursorPos(&mut point) }.ok().map(|_| (point.x, point.y));
    if let Some(cursor) = cursor {
        if let Some(drag) = state.drag.as_mut() {
            drag.start_frame = next;
            drag.start_cursor = cursor;
        }
        // A resize keeps its own start frame: the user is still dragging the
        // same edge from the press, so the factor must stay relative to it.
    }
    // Frames already being rendered are superseded by this size.
    state.generation += 1;
    let window_rect = state.decor.window_rect(next);
    unsafe {
        let _ = SetWindowPos(
            window,
            None,
            window_rect.x,
            window_rect.y,
            window_rect.width,
            window_rect.height,
            SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOOWNERZORDER,
        );
    }
    let label = state.label.clone();
    let app = state.app.clone();
    with_pins(&app, |pins| pins.set_frame(&label, next));
    if !request_frame(window, state) {
        render_frame_inline(window, state);
    }
    true
}

/// Proportional scale factor for a resize drag.
///
/// Only the axes the handle actually grabbed contribute; corners take the
/// axis the pointer moved most, so the photo never stretches.
fn resize_factor(
    handle: PinHandle,
    start_frame: PinRect,
    start_cursor: (i32, i32),
    x: i32,
    y: i32,
) -> f64 {
    let width = f64::from(start_frame.width.max(1));
    let height = f64::from(start_frame.height.max(1));
    let dx = f64::from(x - start_cursor.0);
    let dy = f64::from(y - start_cursor.1);
    let mut factor: Option<f64> = None;
    let mut consider = |candidate: f64| {
        factor = Some(match factor {
            Some(current) if (current - 1.0).abs() >= (candidate - 1.0).abs() => current,
            _ => candidate,
        });
    };
    if handle.left {
        consider((width - dx) / width);
    }
    if handle.right {
        consider((width + dx) / width);
    }
    if handle.top {
        consider((height - dy) / height);
    }
    if handle.bottom {
        consider((height + dy) / height);
    }
    factor.unwrap_or(1.0).clamp(0.02, 40.0)
}

/// Resizes from an edge or corner while keeping the image aspect ratio.
///
/// The opposite edge/corner stays fixed (`PinHandle::anchor`), and both axes
/// scale together, so the picture is never stretched. The axis the user drags
/// most decides the factor; the other axis follows the aspect ratio.
fn resize_to(window: HWND, state: &mut PinState, x: i32, y: i32) {
    let Some(resize) = state.resize.as_ref() else { return };
    let factor = resize_factor(resize.handle, resize.start_frame, resize.start_cursor, x, y);
    let next = zoom_frame_within(
        resize.start_frame,
        factor,
        resize.handle.anchor(),
        Some(state.image.aspect()),
        state.scale,
        Some((state.image.width, state.image.height)),
    );
    if next == state.frame {
        return;
    }
    let image_width = f64::from(state.image.width.max(1));
    let applied_zoom = f64::from(next.width.max(1)) / image_width;
    if commit_frame_size(window, state, next, applied_zoom) {
        // The percentage badge follows the pointer while the edge is dragged.
        let anchor_x = (f64::from(x) - f64::from(next.x)) / f64::from(next.width.max(1));
        let anchor_y = (f64::from(y) - f64::from(next.y)) / f64::from(next.height.max(1));
        show_badge(state, (anchor_x.clamp(0.0, 1.0), anchor_y.clamp(0.0, 1.0)));
    }
}

fn toggle_topmost(window: HWND, state: &mut PinState) {
    state.wants_topmost = !state.wants_topmost;
    unsafe {
        let _ = SetWindowPos(
            window,
            Some(if state.wants_topmost { HWND_TOPMOST } else { HWND_NOTOPMOST }),
            0,
            0,
            0,
            0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER,
        );
    }
    let label = state.label.clone();
    let app = state.app.clone();
    let wants = state.wants_topmost;
    with_pins(&app, |pins| pins.set_topmost(&label, wants));
}

fn assert_topmost(window: HWND) {
    for _ in 0..2 {
        unsafe {
            let _ = SetWindowPos(
                window,
                Some(HWND_TOPMOST),
                0,
                0,
                0,
                0,
                SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_SHOWWINDOW,
            );
            let style = GetWindowLongPtrW(window, GWL_EXSTYLE);
            if style & (WS_EX_TOPMOST.0 as isize) != 0 {
                return;
            }
        }
    }
}

fn show_menu(window: HWND, state: &mut PinState, lparam: LPARAM) {
    // `WM_RBUTTONUP` reports client coordinates; `TrackPopupMenu` places the
    // menu in screen coordinates. Converting is what keeps the menu at the
    // clicked point instead of at the pin's client offset from the desktop
    // origin. The cursor position is the fallback if the conversion fails.
    let mut point = POINT {
        x: (lparam.0 & 0xFFFF) as u16 as i16 as i32,
        y: ((lparam.0 >> 16) & 0xFFFF) as u16 as i16 as i32,
    };
    if !unsafe { ClientToScreen(window, &mut point) }.as_bool() {
        if unsafe { GetCursorPos(&mut point) }.is_err() {
            return;
        }
    }
    let (x, y) = (point.x, point.y);
    let checked = if state.wants_topmost { MF_CHECKED } else { MENU_ITEM_FLAGS(0) };
    let language = crate::state::load_language(&state.app);
    let (close, close_all, pin_on_top) = menu_labels(&language);
    unsafe {
        let Ok(menu) = CreatePopupMenu() else { return };
        let close: Vec<u16> = close.encode_utf16().chain(std::iter::once(0)).collect();
        let close_all: Vec<u16> = close_all.encode_utf16().chain(std::iter::once(0)).collect();
        let pin_on_top: Vec<u16> = pin_on_top.encode_utf16().chain(std::iter::once(0)).collect();
        let _ = AppendMenuW(menu, MF_STRING, 1, windows::core::PCWSTR(close.as_ptr()));
        let _ = AppendMenuW(menu, MF_STRING, 2, windows::core::PCWSTR(close_all.as_ptr()));
        let _ = AppendMenuW(
            menu,
            MF_STRING | checked,
            3,
            windows::core::PCWSTR(pin_on_top.as_ptr()),
        );
        // `TrackPopupMenu` runs a nested message loop on this thread, so the
        // Esc and mouse hooks below are re-entered while the menu is open. A
        // pin is never the foreground window, so that loop receives no
        // keyboard messages at all and no click outside the popup: the hooks
        // end the menu themselves instead of closing the pin.
        MENU_PIN.store(window.0 as isize, Ordering::Release);
        MENU_OPEN.store(true, Ordering::Release);
        install_menu_mouse_hook();
        let _ = TrackPopupMenu(menu, TPM_RIGHTBUTTON, x, y, Some(0), window, None);
        remove_menu_mouse_hook();
        MENU_OPEN.store(false, Ordering::Release);
        MENU_PIN.store(0, Ordering::Release);
        let _ = DestroyMenu(menu);
    }
}

/// Native context-menu labels in the language the rest of Kiri uses.
///
/// The WebView pin renders these through `t()`; a native menu has no i18n
/// runtime, so it follows the same small-table pattern as the tray menu.
fn menu_labels(language: &str) -> (&'static str, &'static str, &'static str) {
    match language {
        "zh-Hans" => ("关闭", "关闭全部贴图", "保持置顶"),
        "zh-Hant" => ("關閉", "關閉全部貼圖", "保持置頂"),
        "ja" => ("閉じる", "すべてのピンを閉じる", "最前面に固定"),
        "de" => ("Schließen", "Alle Pins schließen", "Im Vordergrund halten"),
        "fr" => ("Fermer", "Fermer toutes les épingles", "Garder au premier plan"),
        "ko" => ("닫기", "모든 핀 닫기", "항상 위에 고정"),
        _ => ("Close", "Close All Pins", "Pin on Top"),
    }
}

// ---------------------------------------------------------------------------
// Hooks: drag sampling, Esc, foreground self-heal
// ---------------------------------------------------------------------------

fn install_mouse_hook() {
    let mut slot = MOUSE_HOOK.lock().unwrap_or_else(|p| p.into_inner());
    if slot.is_some() {
        return;
    }
    match unsafe { SetWindowsHookExW(WH_MOUSE_LL, Some(drag_hook), None, 0) } {
        Ok(hook) => *slot = Some(hook.0 as isize),
        Err(error) => {
            // Without the hook the drag still works while the pointer stays
            // over the pin; a fast flick loses the gesture, never the state.
            log::warn!("[pin] drag hook unavailable: {error}");
        }
    }
}

fn ensure_hooks(app: AppHandle) {
    install_escape_hook();
    install_foreground_hook(app);
}

fn install_escape_hook() {
    // A low-level keyboard hook only receives callbacks on the thread that
    // pumps messages and installed it. The pin commands can run on a Tauri
    // worker whose message loop is never pumped, where `SetWindowsHookExW`
    // still succeeds and the hook silently never fires (measured: Escape did
    // nothing at all). Give the hook its own thread with an explicit loop.
    if KEY_HOOK_STARTED.swap(true, Ordering::AcqRel) {
        return;
    }
    let spawned = std::thread::Builder::new()
        .name("kiri-pin-esc-hook".into())
        .spawn(|| {
            match unsafe { SetWindowsHookExW(WH_KEYBOARD_LL, Some(escape_hook), None, 0) } {
                Ok(hook) => {
                    {
                        let mut slot = KEY_HOOK.lock().unwrap_or_else(|p| p.into_inner());
                        *slot = Some(hook.0 as isize);
                    }
                    // Closing the last pin removes the pin windows, not this
                    // thread. Re-read the physical key so a key that is still
                    // held keeps the latch, while a stale one is cleared.
                    let held =
                        unsafe { GetAsyncKeyState(VK_ESCAPE.0 as i32) } as u16 & 0x8000 != 0;
                    if !held {
                        ESCAPE_DOWN.store(false, Ordering::Release);
                    }
                    let mut message = MSG::default();
                    // GetMessageW returns 0 for WM_QUIT and -1 on error; keep
                    // pumping until either ends this thread.
                    while unsafe { GetMessageW(&mut message, None, 0, 0) }.0 > 0 {
                        unsafe {
                            let _ = TranslateMessage(&message);
                            DispatchMessageW(&message);
                        }
                    }
                    let _ = unsafe { UnhookWindowsHookEx(hook) };
                    let mut slot = KEY_HOOK.lock().unwrap_or_else(|p| p.into_inner());
                    *slot = None;
                }
                Err(error) => {
                    KEY_HOOK_STARTED.store(false, Ordering::Release);
                    log::warn!("[pin] Esc hook unavailable: {error}");
                }
            }
        });
    if let Err(error) = spawned {
        KEY_HOOK_STARTED.store(false, Ordering::Release);
        log::warn!("[pin] Esc hook thread could not start: {error}");
    }
}

fn install_foreground_hook(_app: AppHandle) {
    let mut slot = FOREGROUND_HOOK.lock().unwrap_or_else(|p| p.into_inner());
    if slot.is_some() {
        return;
    }
    let hook = unsafe {
        SetWinEventHook(
            EVENT_SYSTEM_FOREGROUND,
            EVENT_SYSTEM_FOREGROUND,
            None,
            Some(foreground_proc),
            0,
            0,
            WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS,
        )
    };
    if hook.is_invalid() {
        log::warn!("[pin] topmost self-heal hook unavailable");
        return;
    }
    *slot = Some(hook.0 as isize);
}

fn unhook_everything() {
    if let Some(hook) = KEY_HOOK.lock().unwrap_or_else(|p| p.into_inner()).take() {
        unsafe {
            let _ = UnhookWindowsHookEx(HHOOK(hook as *mut c_void));
        }
    }
    if let Some(hook) = FOREGROUND_HOOK.lock().unwrap_or_else(|p| p.into_inner()).take() {
        unsafe {
            let _ = UnhookWinEvent(HWINEVENTHOOK(hook as *mut c_void));
        }
    }
    remove_menu_mouse_hook();
    end_drag();
}

// ---------------------------------------------------------------------------
// Context-menu dismissal
// ---------------------------------------------------------------------------

fn install_menu_mouse_hook() {
    let mut slot = MENU_MOUSE_HOOK.lock().unwrap_or_else(|p| p.into_inner());
    if slot.is_some() {
        return;
    }
    match unsafe { SetWindowsHookExW(WH_MOUSE_LL, Some(menu_hook), None, 0) } {
        Ok(hook) => *slot = Some(hook.0 as isize),
        // Without the hook the menu still closes from Escape and from picking
        // an item; only the outside click would be lost.
        Err(error) => log::warn!("[pin] menu dismiss hook unavailable: {error}"),
    }
}

fn remove_menu_mouse_hook() {
    if let Some(hook) = MENU_MOUSE_HOOK.lock().unwrap_or_else(|p| p.into_inner()).take() {
        unsafe {
            let _ = UnhookWindowsHookEx(HHOOK(hook as *mut c_void));
        }
    }
}

/// Ends the tracking menu when a press lands outside it.
///
/// `TrackPopupMenu` runs a nested loop on this thread, so a low-level hook is
/// re-entered there just like the Escape hook. `EndMenu` is the documented way
/// to end the calling thread's active menu and is what the keyboard half of
/// this design already uses.
unsafe extern "system" fn menu_hook(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code >= 0 && MENU_OPEN.load(Ordering::Acquire) {
        let message = wparam.0 as u32;
        if matches!(
            message,
            WM_LBUTTONDOWN | WM_RBUTTONDOWN | WM_MBUTTONDOWN | WM_MOUSEWHEEL
        ) {
            let mut point = POINT::default();
            if unsafe { GetCursorPos(&mut point) }.is_ok() {
                // A click on the popup itself belongs to the menu: it selects
                // an item or dismisses the menu on its own.
                let under_cursor = unsafe { WindowFromPoint(point) };
                if !class_name_is(under_cursor, MENU_CLASS) {
                    let _ = unsafe { EndMenu() };
                }
            }
        }
    }
    unsafe { CallNextHookEx(None, code, wparam, lparam) }
}

unsafe extern "system" fn drag_hook(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code >= 0 {
        let target = DRAG_TARGET.load(Ordering::Acquire);
        if target != 0 {
            let pressed = unsafe { GetAsyncKeyState(VK_LBUTTON.0 as i32) } as u16 & 0x8000 != 0;

            if !pressed {
                // The button was released outside the pin.
                DRAG_TARGET.store(0, Ordering::Release);
                let _ = unsafe {
                    PostMessageW(Some(hwnd(target)), WM_PIN_DRAG_END, WPARAM(0), LPARAM(0))
                };
            } else {
                let now = now_ms();
                if now.saturating_sub(LAST_DRAG_POST.load(Ordering::Acquire)) >= DRAG_POST_INTERVAL_MS {
                    LAST_DRAG_POST.store(now, Ordering::Release);
                    let mut point = POINT::default();
                    if unsafe { GetCursorPos(&mut point) }.is_ok() {
                        let _ = unsafe {
                            PostMessageW(
                                Some(hwnd(target)),
                                WM_PIN_DRAG,
                                WPARAM(point.x as isize as usize),
                                LPARAM(point.y as isize),
                            )
                        };
                    }
                }
            }
        }
    }
    unsafe { CallNextHookEx(None, code, wparam, lparam) }
}

unsafe extern "system" fn escape_hook(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code < 0 {
        return unsafe { CallNextHookEx(None, code, wparam, lparam) };
    }
    let message = wparam.0 as u32;
    let pressed = matches!(message, WM_KEYDOWN | WM_SYSKEYDOWN);
    let released = matches!(message, WM_KEYUP | WM_SYSKEYUP);
    if !pressed && !released {
        return unsafe { CallNextHookEx(None, code, wparam, lparam) };
    }
    let data = unsafe { &*(lparam.0 as *const KBDLLHOOKSTRUCT) };
    if data.vkCode != VK_ESCAPE.0 as u32 {
        if released {
            ESCAPE_DOWN.store(false, Ordering::Release);
        }
        // Arrow keys nudge the pin under the pointer. They are swallowed only
        // while a pin is actually under the cursor, so typing elsewhere and
        // caret navigation in other applications stay untouched.
        let arrow = match data.vkCode {
            vk if vk == VK_LEFT.0 as u32 => Some((-1, 0)),
            vk if vk == VK_RIGHT.0 as u32 => Some((1, 0)),
            vk if vk == VK_UP.0 as u32 => Some((0, -1)),
            vk if vk == VK_DOWN.0 as u32 => Some((0, 1)),
            _ => None,
        };
        if let (Some((x, y)), true) = (arrow, pressed) {
            let pin_has_focus = is_pin_window(unsafe { GetForegroundWindow() });
            if !MENU_OPEN.load(Ordering::Acquire) && !modifier_held() && !pin_has_focus {
                let shift = unsafe { GetAsyncKeyState(VK_SHIFT.0 as i32) } as u16 & 0x8000 != 0;
                let factor = if shift { PIN_ARROW_SHIFT_FACTOR } else { 1 };
                let mut point = POINT::default();
                if unsafe { GetCursorPos(&mut point) }.is_ok() {
                    if let Some(target) = pin_under_pointer(point) {
                        let _ = unsafe {
                            PostMessageW(
                                Some(target),
                                WM_PIN_NUDGE,
                                WPARAM((x * factor) as usize),
                                LPARAM((y * factor) as isize),
                            )
                        };
                        return LRESULT(1);
                    }
                }
            }
        }
        return unsafe { CallNextHookEx(None, code, wparam, lparam) };
    }
    if released {
        ESCAPE_DOWN.store(false, Ordering::Release);
        return unsafe { CallNextHookEx(None, code, wparam, lparam) };
    }
    if MENU_OPEN.load(Ordering::Acquire) {
        // A pin is never the foreground window, so its modal menu loop receives
        // no keyboard messages and cannot dismiss itself. End the menu here and
        // swallow the key: one Escape closes the menu, never the pin.
        if MENU_PIN.load(Ordering::Acquire) != 0 {
            let _ = unsafe { EndMenu() };
            ESCAPE_DOWN.store(true, Ordering::Release);
            return LRESULT(1);
        }
        return unsafe { CallNextHookEx(None, code, wparam, lparam) };
    }
    // A selected pin receives Escape itself as WM_KEYDOWN; do not act twice.
    if is_pin_window(unsafe { GetForegroundWindow() }) {
        return unsafe { CallNextHookEx(None, code, wparam, lparam) };
    }
    // Holding Esc must not close a stack of pins.
    if ESCAPE_DOWN.swap(true, Ordering::AcqRel) {
        log::debug!("[pin][esc] ignored: latch is set");
        return LRESULT(1);
    }
    // Ctrl+Esc (Start menu) and Alt+Esc (window cycling) belong to the system,
    // not to the pin under the pointer.
    if modifier_held() {
        log::debug!("[pin][esc] ignored: a modifier is held");
        return unsafe { CallNextHookEx(None, code, wparam, lparam) };
    }
    let mut point = POINT::default();
    if unsafe { GetCursorPos(&mut point) }.is_err() {
        return unsafe { CallNextHookEx(None, code, wparam, lparam) };
    }
    // Prefer the pin under the pointer; if the pointer drifted after a drag or
    // a click, close the pin the user last selected instead of doing nothing.
    let target = pin_under_pointer(point).or_else(|| {
        let active = ACTIVE_PIN.load(Ordering::Acquire);
        (active != 0 && is_pin_window(hwnd(active))).then(|| hwnd(active))
    });
    let Some(target) = target else {
        log::debug!("[pin][esc] ignored: no pin contains the pointer");
        return unsafe { CallNextHookEx(None, code, wparam, lparam) };
    };
    log::debug!("[pin][esc] closing pin under the pointer hwnd={}", target.0 as isize);
    let _ = unsafe { PostMessageW(Some(target), WM_PIN_CLOSE, WPARAM(0), LPARAM(0)) };
    LRESULT(1)
}

/// Resolves the pin the pointer is over.
///
/// The glow band is transparent to hit testing and the zoom badge is its own
/// click-through window, so the window under the pointer is not always the pin
/// the user is pointing at. Fall back to the pin whose photo contains the
/// cursor.
fn pin_under_pointer(point: POINT) -> Option<HWND> {
    let under_cursor = unsafe { WindowFromPoint(point) };
    let root = if under_cursor.is_invalid() {
        hwnd(0)
    } else {
        unsafe { GetAncestor(under_cursor, GA_ROOT) }
    };
    if !root.is_invalid() && is_pin_window(root) {
        return Some(root);
    }
    APP_HANDLE
        .get()
        .and_then(|app| with_pins(app, |pins| pins.hwnd_at(point.x, point.y)))
        .map(hwnd)
}
/// True while Control, Alt, or the Windows key is down.
fn modifier_held() -> bool {
    [VK_CONTROL, VK_MENU, VK_LWIN, VK_RWIN].into_iter().any(|key| {
        let state = unsafe { GetAsyncKeyState(key.0 as i32) };
        state as u16 & 0x8000 != 0
    })
}

fn is_pin_window(window: HWND) -> bool {
    class_name_is(window, PIN_CLASS)
}

/// True when `window` is a live window of the named class.
fn class_name_is(window: HWND, expected: &str) -> bool {
    if window.is_invalid() {
        return false;
    }
    let mut buffer = [0u16; 64];
    let len = unsafe { GetClassNameW(window, &mut buffer) };
    if len <= 0 {
        return false;
    }
    let name: Vec<u16> = expected.encode_utf16().collect();
    &buffer[..len as usize] == name.as_slice()
}

unsafe extern "system" fn foreground_proc(
    _hook: HWINEVENTHOOK,
    _event: u32,
    _window: HWND,
    _object: i32,
    _child: i32,
    _thread: u32,
    _time: u32,
) {
    let host = HOST_WINDOW.load(Ordering::Acquire);
    if host != 0 {
        let _ = unsafe { PostMessageW(Some(hwnd(host)), WM_PIN_HEAL, WPARAM(0), LPARAM(0)) };
    }
}

fn heal_topmost() {
    // A capture overlay is intentionally above every pin, so the self-heal
    // must not lift pins back over it. The gate restores the band itself when
    // the capture session ends.
    if CAPTURE_OVERLAY_ACTIVE.load(Ordering::Acquire) {
        return;
    }
    let Some(app) = APP_HANDLE.get().cloned() else { return };
    let windows: Vec<isize> = with_pins(&app, |pins| {
        pins.labels()
            .filter(|(_, hwnd, wants)| *wants && *hwnd != 0)
            .map(|(_, hwnd, _)| hwnd)
            .collect()
    });
    for window in windows {
        let window = hwnd(window);
        // Re-entering the band is only necessary when the window actually left
        // it. An unconditional `SetWindowPos` on every foreground change would
        // reorder the band (the raised pin could drop below a sibling) and do
        // needless USER work while the user switches applications.
        let style = unsafe { GetWindowLongPtrW(window, GWL_EXSTYLE) };
        if style & WS_EX_TOPMOST.0 as isize == 0 {
            log::info!("[pin] restoring topmost band window={}", window.0 as isize);
            assert_topmost(window);
        }
    }
}

fn close_all_pins() {
    let Some(app) = APP_HANDLE.get().cloned() else { return };
    let windows: Vec<isize> = with_pins(&app, |pins| {
        pins.labels().map(|(_, hwnd, _)| hwnd).filter(|h| *h != 0).collect()
    });
    for window in windows {
        unsafe {
            let _ = DestroyWindow(hwnd(window));
        }
    }
}

pub fn close_all() {
    let host = HOST_WINDOW.load(Ordering::Acquire);
    if host != 0 {
        unsafe {
            let _ = PostMessageW(Some(hwnd(host)), WM_PIN_CLOSE_ALL, WPARAM(0), LPARAM(0));
        }
    }
}

/// Tells the surface whether a screenshot capture is currently on screen.
///
/// Pins are topmost by design, so without this they compete with the capture
/// overlay for the top of the band and for the click on a toolbar button. The
/// flag is also read directly by each pin's hit test, so a pin created while a
/// capture is running cannot block the overlay either.
pub fn set_capture_overlay_active(active: bool) {
    if CAPTURE_OVERLAY_ACTIVE.swap(active, Ordering::AcqRel) == active {
        return;
    }
    let host = HOST_WINDOW.load(Ordering::Acquire);
    if host != 0 {
        let _ = unsafe {
            PostMessageW(
                Some(hwnd(host)),
                WM_PIN_CAPTURE_GATE,
                WPARAM(usize::from(active)),
                LPARAM(0),
            )
        };
    }
}

/// Moves every live pin below the capture overlays, or restores the band.
///
/// Pins that the user explicitly unpinned are already outside the topmost
/// band, so only the ones that want it are pushed and restored.
fn apply_capture_gate(active: bool) {
    let Some(app) = APP_HANDLE.get().cloned() else { return };
    let windows: Vec<(isize, bool)> = with_pins(&app, |pins| {
        pins.labels()
            .map(|(_, hwnd, wants)| (hwnd, wants))
            .filter(|(hwnd, _)| *hwnd != 0)
            .collect()
    });
    for (window, wants_topmost) in windows {
        if !wants_topmost {
            continue;
        }
        let window = hwnd(window);
        unsafe {
            let _ = SetWindowPos(
                window,
                Some(if active { HWND_BOTTOM } else { HWND_TOPMOST }),
                0,
                0,
                0,
                0,
                SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER,
            );
        }
    }
}

// ---------------------------------------------------------------------------
// Zoom percentage badge
// ---------------------------------------------------------------------------

fn show_badge(state: &PinState, anchor: (f64, f64)) {
    let percent = zoom_percent(state.frame, state.image.width);
    let Some(badge) = ensure_badge(state.scale) else { return };
    let scale = state.scale;
    let margin = (f64::from(BADGE_MARGIN_DIP) * scale).round() as i32;
    let (badge_width, badge_height) = badge_size(scale);
    let x = if anchor.0 <= 0.5 {
        state.frame.x + margin
    } else {
        state.frame.right() - badge_width - margin
    };
    let y = if anchor.1 <= 0.5 {
        state.frame.y + margin
    } else {
        state.frame.bottom() - badge_height - margin
    };
    if let Some((pixels, width, height)) = render_badge(percent, scale) {
        if upload(badge, &pixels, width, height).is_err() {
            return;
        }
    }
    unsafe {
        let _ = SetWindowPos(
            badge,
            Some(HWND_TOPMOST),
            x,
            y,
            badge_width,
            badge_height,
            SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_SHOWWINDOW,
        );
        let _ = SetWindowDisplayAffinity(badge, WDA_EXCLUDEFROMCAPTURE);
        let _ = SetTimer(Some(badge), BADGE_TIMER, 900, None);
    }
}

fn hide_badge() {
    let badge = BADGE_WINDOW.load(Ordering::Acquire);
    if badge != 0 {
        unsafe {
            let _ = KillTimer(Some(hwnd(badge)), BADGE_TIMER);
            let _ = ShowWindow(hwnd(badge), SW_HIDE);
        }
    }
}

fn badge_size(scale: f64) -> (i32, i32) {
    (
        ((f64::from(BADGE_WIDTH_DIP) * scale).round() as i32).max(40),
        ((f64::from(BADGE_HEIGHT_DIP) * scale).round() as i32).max(16),
    )
}

fn ensure_badge(scale: f64) -> Option<HWND> {
    let existing = BADGE_WINDOW.load(Ordering::Acquire);
    if existing != 0 {
        return Some(hwnd(existing));
    }
    let (width, height) = badge_size(scale);
    let instance = unsafe { HINSTANCE(GetModuleHandleW(None).ok()?.0) };
    let badge = unsafe {
        CreateWindowExW(
            WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE,
            w!(r"KiriPinBadge"),
            w!("Lumen Pin Zoom"),
            WS_POPUP,
            0,
            0,
            width,
            height,
            None,
            None,
            Some(instance),
            None,
        )
    }
    .ok()?;
    enable_layered_rendering(badge);
    BADGE_WINDOW.store(badge.0 as isize, Ordering::Release);
    Some(badge)
}

unsafe extern "system" fn badge_proc(window: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    match msg {
        WM_TIMER => {
            if wparam.0 == BADGE_TIMER {
                let _ = unsafe { KillTimer(Some(window), BADGE_TIMER) };
                let _ = unsafe { ShowWindow(window, SW_HIDE) };
            }
            LRESULT(0)
        }
        WM_PAINT => {
            let _ = unsafe { ValidateRect(Some(window), None) };
            LRESULT(0)
        }
        WM_ERASEBKGND => LRESULT(1),
        _ => unsafe { DefWindowProcW(window, msg, wparam, lparam) },
    }
}

/// Renders the percentage pill: white antialiased text on a translucent dark
/// rounded body, premultiplied for `UpdateLayeredWindow`.
fn render_badge(percent: i64, scale: f64) -> Option<(Vec<u8>, i32, i32)> {
    let (width, height) = badge_size(scale);
    let font_px = ((9.0 * scale).round() as i32).max(7);
    let label = format!("{percent}%");
    unsafe {
        let screen = GetDC(None);
        let device = CreateCompatibleDC(Some(screen));
        let font = CreateFontW(
            -font_px,
            0,
            0,
            0,
            FW_NORMAL.0 as i32,
            0,
            0,
            0,
            DEFAULT_CHARSET,
            OUT_DEFAULT_PRECIS,
            CLIP_DEFAULT_PRECIS,
            // Grayscale antialiasing keeps the glyph coverage colour-neutral.
            // ClearType would write coloured subpixels and tint the pill.
            FONT_QUALITY(4),
            u32::from(DEFAULT_PITCH.0 | FF_DONTCARE.0),
            w!("Microsoft YaHei UI"),
        );
        if font.is_invalid() {
            let _ = DeleteDC(device);
            ReleaseDC(None, screen);
            return None;
        }
        let previous_font = SelectObject(device, HGDIOBJ(font.0));
        let header = BITMAPINFOHEADER {
            biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: width,
            biHeight: -height,
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB.0,
            ..Default::default()
        };
        let info = BITMAPINFO { bmiHeader: header, ..Default::default() };
        let mut bits: *mut c_void = std::ptr::null_mut();
        let Ok(bitmap) = CreateDIBSection(Some(device), &info, DIB_RGB_COLORS, &mut bits, None, 0)
        else {
            SelectObject(device, previous_font);
            let _ = DeleteObject(HGDIOBJ(font.0));
            let _ = DeleteDC(device);
            ReleaseDC(None, screen);
            return None;
        };
        let previous_bitmap = SelectObject(device, HGDIOBJ(bitmap.0));
        // Black background, white text: the luminance of the result is the
        // antialiased text coverage, which becomes the alpha channel. The
        // background mode must stay transparent: GDI's default background is
        // white, and an opaque fill would turn the whole text cell into one
        // solid white block instead of thin glyph strokes.
        std::ptr::write_bytes(bits as *mut u8, 0, (width * height * 4) as usize);
        SetBkMode(device, TRANSPARENT);
        SetTextColor(device, COLORREF(0x00FF_FFFF));
        let mut area = RECT { left: 0, top: 0, right: width, bottom: height };
        let mut body: Vec<u16> = label.encode_utf16().collect();
        DrawTextW(device, &mut body, &mut area, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
        let mut coverage = vec![0u8; (width * height * 4) as usize];
        std::ptr::copy_nonoverlapping(bits as *const u8, coverage.as_mut_ptr(), coverage.len());

        SelectObject(device, previous_bitmap);
        let _ = DeleteObject(HGDIOBJ(bitmap.0));
        SelectObject(device, previous_font);
        let _ = DeleteObject(HGDIOBJ(font.0));
        let _ = DeleteDC(device);
        ReleaseDC(None, screen);

        let radius = (5.0 * scale).max(2.0);
        let mut pixels = vec![0u8; coverage.len()];
        for y in 0..height {
            for x in 0..width {
                let index = (y as usize * width as usize + x as usize) * 4;
                // BGRA source: the glyph is white, so any channel is coverage.
                let text_alpha = u32::from(
                    coverage[index].max(coverage[index + 1]).max(coverage[index + 2]),
                );
                let body = rounded_rect_covers(
                    f64::from(x) + 0.5,
                    f64::from(y) + 0.5,
                    f64::from(width),
                    f64::from(height),
                    radius,
                );
                let (body_alpha, body_channel) = if body { (200u32, 25u32) } else { (0u32, 0u32) };
                let alpha = body_alpha + text_alpha * (255 - body_alpha) / 255;
                let channel = body_channel * (255 - text_alpha) / 255 + text_alpha;
                pixels[index] = channel.min(255) as u8;
                pixels[index + 1] = channel.min(255) as u8;
                pixels[index + 2] = channel.min(255) as u8;
                pixels[index + 3] = alpha.min(255) as u8;
            }
        }
        Some((pixels, width, height))
    }
}

// ---------------------------------------------------------------------------
// Environment
// ---------------------------------------------------------------------------

fn refresh_wheel_routing() {
    let mut enabled: i32 = 1;
    let result = unsafe {
        SystemParametersInfoW(
            SPI_GETMOUSEWHEELROUTING,
            0,
            Some(&mut enabled as *mut i32 as *mut c_void),
            SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS(0),
        )
    };
    // 0 means the system sends the wheel only to the focused window.
    if result.is_ok() {
        WHEEL_ROUTES_ON_HOVER.store(enabled != 0, Ordering::Release);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn badge_geometry_scales_with_the_display() {
        assert_eq!(badge_size(1.0), (56, 20));
        assert_eq!(badge_size(2.0), (112, 40));
    }

    #[test]
    fn edge_handles_are_detected_only_near_the_photo_border() {
        let frame = PinRect::new(100, 100, 400, 300);
        assert_eq!(PinHandle::at(frame, 300, 250, 1.0), None, "the centre moves the pin");
        let right = PinHandle::at(frame, 497, 250, 1.0).expect("right handle");
        assert!(right.right && !right.left && !right.top && !right.bottom);
        let corner = PinHandle::at(frame, 103, 397, 1.0).expect("bottom-left handle");
        assert!(corner.left && corner.bottom && !corner.right && !corner.top);
        // The glow band is outside the photo and must never resize.
        assert_eq!(PinHandle::at(frame, 505, 250, 1.0), None);
        assert_eq!(PinHandle::at(frame, 300, 95, 1.0), None);
    }

    #[test]
    fn a_resize_drag_scales_proportionally_from_the_opposite_edge() {
        let frame = PinRect::new(0, 0, 400, 300);
        let right = PinHandle { left: false, right: true, top: false, bottom: false };
        let factor = resize_factor(right, frame, (400, 150), 500, 150);
        assert!((factor - 1.25).abs() < 1e-9);
        let next = zoom_frame(frame, factor, right.anchor(), Some(400.0 / 300.0), 1.0);
        assert_eq!((next.width, next.height), (500, 375), "the photo keeps its aspect ratio");
        let bottom = PinHandle { left: false, right: false, top: false, bottom: true };
        let factor = resize_factor(bottom, frame, (200, 300), 200, 360);
        assert!((factor - 1.2).abs() < 1e-9);
        // A corner uses whichever axis the pointer moved further.
        let corner = PinHandle { left: false, right: true, top: false, bottom: true };
        assert!((resize_factor(corner, frame, (400, 300), 440, 360) - 1.2).abs() < 1e-9);
        // Dragging inward past the minimum stops at the clamp instead of flipping.
        assert_eq!(resize_factor(right, frame, (400, 150), 0, 150), 0.02);
    }

    /// 100% is a detent: scrolling back must always be able to land on it
    /// instead of stopping at 101% and then jumping below 100%.
    #[test]
    fn a_wheel_step_over_actual_size_lands_on_100_percent() {
        let step = super::super::WHEEL_ZOOM_STEP;
        // Hovering just above actual size and scrolling down lands exactly on
        // 100% instead of snapping past it to ~94%.
        assert_eq!(stepped_zoom(1.01, 1.0 / step), 1.0);
        assert_eq!(stepped_zoom(1.03, 1.0 / step), 1.0);
        // Coming up from below also stops at 100%.
        assert_eq!(stepped_zoom(0.95, step), 1.0);
        // A step that stays on one side does not snap.
        assert!(stepped_zoom(1.2, 1.0 / step) > 1.05);
        assert!(stepped_zoom(0.8, step) < 0.95);
        // Already at actual size, the next notch zooms away from it.
        assert!((stepped_zoom(1.0, step) - step).abs() < 1e-9);
        assert!((stepped_zoom(1.0, 1.0 / step) - 1.0 / step).abs() < 1e-9);
    }

    #[cfg(windows)]
    #[test]
    fn the_percentage_badge_draws_text_inside_a_rounded_body() {
        let (pixels, width, height) = render_badge(110, 1.0).expect("badge renders");
        assert_eq!((width, height), badge_size(1.0));
        // The corners are outside the rounded body, so the pill floats on the
        // desktop instead of showing a black rectangle.
        assert_eq!(pixels[3], 0);
        // The body is translucent dark, and the glyphs are near-white coverage.
        let centre = ((height as usize / 2) * width as usize + width as usize / 2) * 4;
        assert!(pixels[centre + 3] > 180, "{}", pixels[centre + 3]);
        let glyph = pixels
            .chunks_exact(4)
            .filter(|pixel| pixel[3] > 240 && pixel[0] > 180)
            .count();
        assert!(glyph > 20, "expected antialiased text, got {glyph} pixels");
    }

    #[cfg(windows)]
    #[test]
    fn the_badge_keeps_the_text_cell_transparent_instead_of_filling_it() {
        let (pixels, width, height) = render_badge(110, 1.0).expect("badge renders");
        // An opaque GDI background (the default white) would make the whole
        // text cell one solid block. Glyph strokes are only a few pixels wide,
        // so the longest bright run on the centre row stays short.
        let row = height as usize / 2;
        let mut longest = 0;
        let mut run = 0;
        for x in 0..width as usize {
            let index = (row * width as usize + x) * 4;
            if pixels[index + 3] == 255 && pixels[index] > 200 {
                run += 1;
                longest = longest.max(run);
            } else {
                run = 0;
            }
        }
        assert!(
            longest < 16,
            "the badge text cell was filled with an opaque background: run={longest}"
        );
        // The body stays translucent, so the pill still blends with the desktop.
        // The middle row at the left edge is inside the rounded body.
        let body_index = (row * width as usize + 4) * 4;
        assert!(pixels[body_index + 3] < 230, "{}", pixels[body_index + 3]);
    }

    #[test]
    fn pin_class_is_distinct_from_the_host_and_badge() {
        assert_ne!(PIN_CLASS, HOST_CLASS);
        assert_ne!(PIN_CLASS, BADGE_CLASS);
    }

    #[test]
    fn pin_decor_scales_with_the_display_and_stays_bounded() {
        assert_eq!(
            PinDecor::for_scale(1.0),
            PinDecor { margin: 12, radius: 8, blur: 8 }
        );
        assert_eq!(
            PinDecor::for_scale(2.0),
            PinDecor { margin: 24, radius: 16, blur: 16 }
        );
        // A degraded or absurd scale factor must not grow the band without
        // bound; the caps also keep a 1:1 photo readable.
        let huge = PinDecor::for_scale(50.0);
        assert_eq!(huge.margin, PIN_GLOW_MARGIN_MAX);
        assert_eq!(huge.radius, PIN_CORNER_RADIUS_MAX);
        assert_eq!(huge.blur, PIN_GLOW_BLUR_MAX);
        assert_eq!(
            PinDecor::for_scale(f64::NAN),
            PinDecor { margin: 12, radius: 8, blur: 8 }
        );
    }

    /// The band must be wide enough to hold the glow it fades through at every
    /// supported scale factor.
    #[test]
    fn the_glow_band_is_never_narrower_than_its_blur() {
        for scale in [1.0, 1.25, 1.5, 2.0, 3.0, f64::NAN, 50.0] {
            let decor = PinDecor::for_scale(scale);
            assert!(
                decor.margin >= decor.blur,
                "band {decor:?} clips its glow"
            );
        }
    }


    #[test]
    fn the_pin_window_is_the_photo_plus_its_glow_band() {
        let decor = PinDecor { margin: 8, radius: 6, blur: 6 };
        let frame = PinRect::new(100, 200, 400, 300);
        let window = decor.window_rect(frame);
        assert_eq!(window, PinRect::new(92, 192, 416, 316));
        // The photo keeps its exact on-screen position inside the window.
        assert_eq!(
            (window.x + decor.margin, window.y + decor.margin),
            (frame.x, frame.y)
        );
    }

    /// Builds a window bitmap and returns it for pixel assertions.
    fn composed(window_width: i32, window_height: i32, decor: PinDecor) -> Vec<u8> {
        let (width, height) = (
            window_width - decor.margin * 2,
            window_height - decor.margin * 2,
        );
        // Opaque white photo, premultiplied so every channel is 255.
        let photo = vec![255u8; width as usize * height as usize * 4];
        let mut bits = vec![0xAAu8; window_width as usize * window_height as usize * 4];
        compose_pin_frame(
            &mut bits,
            window_width,
            window_height,
            &photo,
            width,
            height,
            decor,
        );
        bits
    }

    #[test]
    fn a_composed_frame_keeps_the_photo_and_cuts_its_corners() {
        let decor = PinDecor { margin: 8, radius: 6, blur: 6 };
        let (window_width, window_height) = (40 + 16, 30 + 16);
        let bits = composed(window_width, window_height, decor);
        let pixel = |x: i32, y: i32| {
            let index = (y as usize * window_width as usize + x as usize) * 4;
            [bits[index], bits[index + 1], bits[index + 2], bits[index + 3]]
        };
        // The middle of the photo is untouched, including its alpha.
        assert_eq!(pixel(8 + 20, 8 + 15), [255, 255, 255, 255]);
        // The extreme window corner is outside the glow band, so it is fully
        // transparent instead of showing the cleared bitmap.
        assert_eq!(pixel(0, 0)[3], 0);
        // The band against the photo edge carries a premultiplied pale-blue
        // glow: the channels follow the tint and still fade with the alpha.
        let contact = pixel(7, 8 + 15);
        assert!(contact[3] > 40, "edge glow alpha {}", contact[3]);
        assert!(contact[0] > contact[1] && contact[1] > contact[2], "glow tint {:?}", contact);
        assert_eq!(contact[0], contact[3]);
        assert!(pixel(1, 8 + 15)[3] < contact[3]);
        // A glow is symmetric: above and below the photo read the same.
        assert_eq!(
            pixel(8 + 20, 6)[3],
            pixel(8 + 20, 8 + 30 + 1)[3],
            "the glow is not symmetric"
        );
        // The rounded corner no longer paints a square photo pixel: the photo
        // is cut, so the corner is translucent and no longer the photo white.
        let corner = pixel(8, 8);
        assert!(corner[3] < 255, "corner alpha {}", corner[3]);
        assert_ne!(&corner[..3], &[255, 255, 255]);
    }

    #[test]
    fn a_composed_frame_writes_every_window_pixel() {
        // Nothing may keep the uninitialized bitmap pattern: a stale value in
        // the band would paint a coloured fringe around every pin.
        let decor = PinDecor { margin: 8, radius: 6, blur: 6 };
        let bits = composed(56, 46, decor);
        assert!(
            !bits.chunks_exact(4).any(|pixel| pixel[3] == 0xAA || pixel[0] == 0xAA),
            "the glow band left uninitialized pixels"
        );
    }

    /// The glow has to separate a pin from whatever is behind it. Desktop
    /// content is usually darker than a capture, so a light halo is what makes
    /// the pin's rounded edge readable without drawing a border.
    #[test]
    fn the_pin_glow_lifts_the_edge_off_a_dark_desktop() {
        let decor = PinDecor::for_scale(1.0);
        let (photo_width, photo_height) = (80, 60);
        let (window_width, window_height) = (
            photo_width + decor.margin * 2,
            photo_height + decor.margin * 2,
        );
        // Opaque mid-grey photo, premultiplied.
        let photo = vec![200u8; (photo_width * photo_height * 4) as usize]
            .into_iter()
            .enumerate()
            .map(|(index, value)| if index % 4 == 3 { 255 } else { value })
            .collect::<Vec<u8>>();
        let mut bits = vec![0u8; (window_width * window_height * 4) as usize];
        compose_pin_frame(
            &mut bits,
            window_width,
            window_height,
            &photo,
            photo_width,
            photo_height,
            decor,
        );
        let over = |x: i32, y: i32, background: u32, channel: usize| -> i32 {
            let index = ((y * window_width + x) * 4) as usize;
            let alpha = u32::from(bits[index + 3]);
            let value = u32::from(bits[index + channel]);
            (value + background * (255 - alpha) / 255) as i32
        };
        let contact_x = decor.margin - 1;
        let middle_y = decor.margin + photo_height / 2;
        // A dark desktop (20) is visibly lightened right beside the photo.
        let dark = over(contact_x, middle_y, 20, 2);
        assert!(
            dark >= 20 + 20,
            "the pin glow is invisible on dark content: {dark}"
        );
        // The glow is a pale blue light: on light content its blue channel
        // lifts the edge, and its warm channels only dip slightly instead of
        // turning the halo into a dark outline.
        let light_blue = over(contact_x, middle_y, 245, 0);
        assert!(
            light_blue >= 245,
            "the glow darkened light content: {light_blue}"
        );
        let light_red = over(contact_x, middle_y, 245, 2);
        assert!(
            light_red >= 245 - 48,
            "the glow became a dark outline: {light_red}"
        );
        // The fade ends at the outer edge of the band: nothing is painted on
        // the desktop beyond it, so the glow never becomes a hard rectangle.
        assert_eq!(bits[(window_width as usize) * 4 + 3], 0);
    }

    #[cfg(windows)]
    #[test]
    fn the_glow_fades_to_nothing_at_the_band_edge() {
        let contact = glow_alpha(0.0, 8);
        assert!(contact > 100 && contact < 160, "edge glow alpha {contact}");
        assert!(glow_alpha(4.0, 8) < contact);
        assert!(glow_alpha(-4.0, 8) >= contact);
        assert_eq!(glow_alpha(8.0, 8), 0);
        assert_eq!(glow_alpha(0.0, 0), 0);
        assert_eq!(glow_alpha(f64::NAN, 8), 0);
    }

    /// Manual visual check: `cargo test --lib preview_composed_pin_frame
    /// -- --ignored --nocapture` writes `.cursor/pin-frame-preview.png`.
    #[cfg(windows)]
    #[test]
    #[ignore = "writes a visual preview for manual inspection"]
    fn preview_composed_pin_frame() {
        let decor = PinDecor::for_scale(1.0);
        let (width, height) = (320, 220);
        let (window_width, window_height) =
            (width + decor.margin * 2, height + decor.margin * 2);
        let mut photo = vec![0u8; (width * height * 4) as usize];
        for y in 0..height {
            for x in 0..width {
                let index = ((y * width + x) * 4) as usize;
                let value = if (x / 40 + y / 40) % 2 == 0 { 248 } else { 32 };
                photo[index] = value;
                photo[index + 1] = value;
                photo[index + 2] = value;
                photo[index + 3] = 255;
            }
        }
        let mut bits = vec![0u8; (window_width * window_height * 4) as usize];
        compose_pin_frame(
            &mut bits,
            window_width,
            window_height,
            &photo,
            width,
            height,
            decor,
        );
        let mut output = image::RgbaImage::new(window_width as u32, window_height as u32);
        for y in 0..window_height {
            for x in 0..window_width {
                let index = ((y * window_width + x) * 4) as usize;
                let alpha = u32::from(bits[index + 3]);
                // Left half over a light desktop, right half over a dark one.
                let background = if x < window_width / 2 { 245 } else { 30 };
                let channel = |offset: usize| {
                    let value = u32::from(bits[index + offset]);
                    (value + background * (255 - alpha) / 255).min(255) as u8
                };
                output.put_pixel(
                    x as u32,
                    y as u32,
                    image::Rgba([channel(2), channel(1), channel(0), 255]),
                );
            }
        }
        let path = std::path::Path::new("../.cursor/pin-frame-preview.png");
        output.save(path).expect("preview saved");
        eprintln!("wrote {}", path.display());
    }

    #[test]
    fn menu_labels_cover_supported_languages_and_default_to_english() {
        assert_eq!(menu_labels("en"), ("Close", "Close All Pins", "Pin on Top"));
        assert_eq!(menu_labels("zh-Hans").2, "保持置顶");
        assert_eq!(menu_labels("ja").0, "閉じる");
        assert_eq!(menu_labels("unknown").1, "Close All Pins");
    }
}

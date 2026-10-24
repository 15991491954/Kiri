# ADR 0118: Windows-native pinned images fed by screenshots and the clipboard

Status: accepted for implementation; Windows hardware acceptance uses the pin
checklist in the implementation plan.

## Context

Kiri could already pin a library screenshot, but the result was a WebView window
with a permanent black border that took focus, appeared in the taskbar, and could
only be closed with Escape while it owned the keyboard. The same asset could not
be pinned twice, and there was no way to pin something copied from another
application.

Snipaste treats a pinned image as a first-class object: an undecorated topmost
window per pin, clipboard content rendered to a bitmap (text included), a
low-level keyboard hook that closes the pin under the pointer on Escape, and no
focus change when a pin appears. Its pins also stay out of later captures.

The remaining gap that matters for Kiri is memory. Every WebView instance costs
tens of megabytes; a capture utility that keeps several references on screen
cannot pay that per pin. The product contract also requires captures to stay
local and not to add network or account behavior.

## Decision

Pinned images are Windows-native layered windows, created only on demand.

- **Object model.** `PinRegistry` in `AppState` owns one record per pin
  (instance label, HWND, physical rectangle, z-order). Labels are
  `pin-<instance>`, so one image can be pinned repeatedly. The cap is 16.
- **Rendering.** A dedicated `kiri-pin-surface` thread owns every pin window and
  its message loop. Windows are `WS_POPUP` with
  `WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_TOPMOST`, drawn with
  `UpdateLayeredWindow` from one premultiplied BGRA source per pin. At 100% and
  at the source's own size the source DIB is submitted directly, so the frame
  costs only the layered-window upload; below 100% a box filter shrinks it, and
  above 100% a banded, row-parallel bilinear resample fills a window-sized
  display DIB that is released when the pin returns to 100%. GDI `HALFTONE` is
  not used: measured on this machine it costs 30 ms at a 1080p target, 30 ms at
  4K and 209 ms at 8K, while the same resample written in Rust costs 39/84/206
  ms single-threaded and roughly a quarter of that on four threads. There is no
  WebView, no per-pin JavaScript bundle, and no border or title-bar decoration;
  the only decoration is the glow described below. Transparent pixels do not
  receive mouse input. Decoding, text rasterization and resampling run on worker
  threads; the surface thread only submits geometry and layers.
- **Focus and wheel routing.** Pins appear with `SW_SHOWNOACTIVATE` and answer
  `WM_MOUSEACTIVATE` with `MA_NOACTIVATE`, so they take no taskbar or Alt+Tab
  entry and never steal keyboard focus from the user's application. `MA_NOACTIVATE`
  alone is not enough on Windows 10: clicking an inactive topmost layered window
  still cancels the previous foreground window first, so the desktop is left
  with no foreground window at all (measured). While the system routes the wheel
  to the window under the cursor, pins therefore also carry `WS_EX_NOACTIVATE`;
  that style is what keeps the user's application focused, and it does not stop
  a hovered pin from receiving `WM_MOUSEWHEEL` (measured: delta 120, foreground
  window unchanged). The style is deliberately
  conditional rather than permanent: with that setting off, a pin must be able
  to become foreground, so Kiri drops `WS_EX_NOACTIVATE`, returns `MA_ACTIVATE`
  for clicks, and the wheel reaches the focused pin. Kiri reads
  `SPI_GETMOUSEWHEELROUTING` at startup and on `WM_SETTINGCHANGE`, and every
  existing pin updates its own style, so changing the setting does not require
  reopening pins.
- **Decoration.** The photo is drawn borderless with small rounded corners
  (8 DIP) and a soft light glow (an 8 DIP fade inside a 12 DIP band) composited
  into the same premultiplied frame, so the window is larger than the photo by
  the glow band on every side. The glow is premultiplied white rather than a
  dark drop shadow: a capture on a dark wallpaper still separates from it
  without making the pin look like a framed picture. The band and the cut
  corners are transparent to hit testing, so only the photo receives clicks and
  the decoration never becomes part of a screenshot.
- **Capture exclusion.** Each pin sets
  `WDA_EXCLUDEFROMCAPTURE`, so Kiri's own screenshots and recordings do not
  contain pins. If the call fails, capture hides pins for the duration of the
  session instead.
- **Screenshot integration.** The existing screenshot toolbar 📌 action is kept:
  confirmation writes the screenshot to the library once, then the pin opens at
  the captured selection's physical rectangle. Asset pins reference the library
  asset and do not copy bytes. The capture shortcut stays configurable; a user
  who binds F1 gets the same flow.
- **Clipboard integration.** A single shortcut action, `PastePin` (default F3,
  unbound on request), reads the clipboard with priority image > image files >
  text. Images and decoded files become premultiplied BGRA pins; text is laid out
  and rasterized by GDI into an opaque card on Windows. Clipboard pins are
  memory-only: they are never written to the library and, until P2, never touch
  disk.
- **Escape.** A `WH_KEYBOARD_LL` hook is installed only while at least one pin
  exists. It handles Escape alone, ignores auto-repeat, resolves the pin under
  `GetCursorPos` with `WindowFromPoint`, closes only that pin, and swallows the
  key only on a hit. Because the glow band is transparent to hit testing and the
  zoom badge is its own click-through window, a miss falls back to the pin whose
  photo rectangle contains the pointer, so pointing at the edge of a pin still
  closes it. A hook installation failure degrades to the existing window-focused
  Escape and the context menu.
- **Topmost is enforced native state, not a creation flag.** A pin must stay
  above every normal window for its whole life, including after the user
  activates another application, so Kiri never treats `WS_EX_TOPMOST` as a
  request made once at creation. Every create, reuse and pin transition
  re-asserts the band with a synchronous
  `SetWindowPos(HWND_TOPMOST, SWP_NOACTIVATE)` and then verifies with
  `GetWindowLongPtrW(GWL_EXSTYLE)` that the style really reports
  `WS_EX_TOPMOST`, retrying once if the first transition did not take effect;
  an explicit unpin drops out of the band synchronously and is verified, then
  left alone; it is never repaired. All
  pins are in that band at the same time, and clicking one raises it above its
  siblings without changing focus (`SetWindowPos` on the topmost band, never
  `SetForegroundWindow`). A best-effort `EVENT_SYSTEM_FOREGROUND` hook
  (`kiri-pin-topmost`) watches desktop activations and re-asserts only the pins
  that still want to be on top, so a third-party tool or a later DPI transition
  cannot silently leave a pin behind other applications. The hook exists only
  while pins do, runs on its own `WINEVENT_OUTOFCONTEXT` message loop, skips
  Kiri's own activations, and never touches a pin the user explicitly unpinned.
  Failure to install the hook degrades self-healing only: the pins are still
  created in the band and remain verifiably topmost.
- **Dragging and zooming are direct pointer operations on the image.** There is
  no title bar and no drag handle: pressing the image moves the window, with the
  pointer position read as physical screen coordinates (`GetCursorPos`) and the
  delta applied from the press origin, so a scaled desktop does not drift and
  the moving window cannot feed its own displacement back into the gesture.
  Because an unactivated pin is never the foreground window, Windows revokes
  `SetCapture` immediately (measured: the capture is released and the following
  `WM_CAPTURECHANGED` arrives before the first move), so shifting the window
  relies on `WM_MOUSEMOVE` only. That tracks small moves exactly but drops the
  gesture as soon as one move jumps past the pin's edge (measured: a single
  420-pixel move delivered no move at all), so a `WH_MOUSE_LL` hook is installed
  for the duration of a drag, reads `GetCursorPos` and posts the position to the
  surface thread (throttled to 4 ms so a high-report-rate mouse cannot flood it);
  button release ends the drag even outside the pin. The hook is
  absent when nothing is being dragged, and a pin press never calls
  `SetCapture`, which would end the gesture through `WM_CAPTURECHANGED`. A
  wheel over a pin zooms that pin, not the pin's siblings or the desktop: the
  platform layer computes the new size and position around the point under the
  pointer, applies both in one native call (`SWP_NOZORDER`, so zooming never
  raises or drops a pin out of the band and never reorders siblings; other
  platforms use the two window-manager requests), enforces the image aspect
  ratio so the reference never letterboxes, and reports the size the desktop
  really applied. 100% is one image pixel per physical screen pixel, and at 100%
  the source DIB is uploaded unchanged, so the pin stays pixel-crisp. The
  applied percentage is shown in a single shared 56×20 DIP layered badge window
  that follows the quadrant under the pointer; it never composites into the
  pin's own pixels, needs no pixel backup and no per-pin display buffer at 100%.
  Scrolling back to actual size is a detent: a wheel step that would jump across
  100% lands on it, so a pin always returns to exactly one image pixel per
  screen pixel instead of stopping at 101%. Wheel
  steps are serialized and coalesced, so a burst costs one resample per
  completed frame instead of one per event, and the result is bounded by the
  close-control minimum size, an 8000-pixel maximum edge and a 32-megapixel
  display buffer so a runaway scroll cannot ask for a surface the desktop cannot
  sustain. A 1080p frame costs about 10 ms and a 4K frame about 28 ms (resample
  plus upload; uploads measured at 1.5 ms, 7.7 ms and 27 ms for 1080p, 4K and
  8K surfaces), so dragging and zooming stay interactive without a GPU path. On
  Windows the pin under the cursor receives `WM_MOUSEWHEEL` directly while
  "Scroll inactive windows when I hover over them" is enabled (the default);
  when that option is off, a click brings the pin to the foreground
  (`MA_ACTIVATE`) and the wheel then follows focus.
- **Platform fallback.** macOS and Linux keep the existing WebView `PinWindow`
  as a compatibility path. They are not part of this decision's acceptance and
  do not claim global Escape.
- **Persistence is deferred.** Restoring pins after a restart, including the
  cache layout and recovery rules, is P2. It still does not write pins into the
  user's library.

## Consequences

- Pin memory approaches the image size instead of the WebView baseline, and the
  sixteenth pin costs roughly the same as the first. The byte budgets, not the
  count, are what actually bind: a 4K pin holds about 33 MB of premultiplied
  source, so the 256 MB source budget fits about seven of them even though the
  registry cap is 16.
- Interaction code (drag, wheel zoom, context menu), the drag-time mouse hook
  and the CPU resampler are ours to maintain on Windows instead of being
  inherited from CSS and React.
- Clipboard text is a bitmap: it reads identically everywhere but cannot be
  re-flowed after creation, matching Snipaste's behavior. Windows rasterizes it
  with GDI `DrawTextW`, so no font stack or shaping engine is bundled and text
  pins are Windows-only until a cross-platform path exists.
- Zooming is CPU-resampled and then uploaded through a layered window, so a 4K
  pin runs at roughly 30–50 frames per second while the wheel turns and an 8K
  pin is visibly slower; 100% and plain dragging cost no resample at all.
- A global F3 competes with applications that use F3 (find-next); users can
  rebind or disable it.
- Pins are absent from Kiri captures. A user who wants to capture a pin must
  save or copy it from the pin's context menu instead.
- With the OS "scroll inactive windows" setting turned off, the first click on a
  pin gives it foreground focus so the wheel can reach it; that is the one case
  where interacting with a pin changes which window is active.

## Measured baseline

Recorded on the development machine (Windows 10 21H2, 20 logical cores) with a
throwaway probe before any product code, because two of these numbers decide
whether the interaction design is viable at all.

| Case | Result |
| --- | --- |
| Hovering, never-activated layered pin receives `WM_MOUSEWHEEL` | Yes, delta 120, foreground window unchanged |
| Click activates the pin (`MA_NOACTIVATE` returned) | No activation; the pin never becomes the foreground window |
| Clicking the inactive pin while hover routing is on (`MA_NOACTIVATE` only) | The previous foreground window is cancelled; `GetForegroundWindow()` returns 0 |
| Same click with `WS_EX_NOACTIVATE` | Previous foreground window unchanged; the pin still receives clicks and `WM_MOUSEWHEEL` |
| `SetCapture` held by an unactivated pin | Revoked immediately; `WM_CAPTURECHANGED` arrives before the first move |
| Drag without capture, four 40-pixel steps | Window delta exactly (160, 100), drift (0, 0) |
| Drag without capture, one 420-pixel move | No move delivered; the gesture is lost |
| `StretchDIBits(HALFTONE)` 4K source → 1080p / 4K / 8K | 30.6 / 29.9 / 208.6 ms (P50) |
| `StretchDIBits(COLORONCOLOR)` 4K source → 1080p / 4K / 8K | 3.4 / 8.2 / 21.0 ms (P50) |
| Separable bilinear in Rust, single thread, 4K source → 1080p / 4K / 8K | 38.6 / 84.3 / 206.0 ms (P50) |
| `UpdateLayeredWindow` 1080p / 4K / 8K surface | 1.5 / 7.7 / 26.7 ms (P50), 7 MB / 31 MB / 126 MB per buffer |
| Premultiply an opaque 4K source once | 3.5 ms |

## Verification

- Rust tests cover the registry cap and byte budgets, hit-testing, clipboard
  source priority, text layout bounds (Windows), pointer math, wheel-routing
  `MA_ACTIVATE`/`MA_NOACTIVATE` selection, drag-hook install/uninstall
  transitions, and hook install/uninstall transitions, plus the zoom frame math
  (pointer anchoring, aspect enforcement, size bounds) and the resampler
  (integer weights, band seams, alpha premultiplication, identity scale).
- Pin window tests cover wheel coalescing, the pointer anchor fraction, the
  percentage the HUD shows, and that a drag or corner resize delays zooming
  until it releases the frame.
- Windows hardware: screenshot → 📌 lands pixel-aligned at the selection; focus
  is unchanged; no taskbar or Alt+Tab entry; Escape closes only the pin under the
  pointer; clipboard image, image files, and text each pin with F3; pins stay out
  of a subsequent capture; 16-pin memory, display-buffer release at 100%, and
  idle CPU are measured against both byte budgets. The editing toolbar is gone
  from the moment 📌 is clicked (the overlay is hidden, not just idle), so a
  delayed export can never look like an ignored click.
- Windows hardware, pointer: dragging the image follows the cursor without
  drift at 100%/150%, including a fast flick that leaves the pin's rectangle in
  one move; a wheel over an unactivated pin zooms it around the pointer and
  shows the applied percentage in the quadrant under the cursor; 100% is
  pixel-crisp; the pin keeps its position in the band and its order among
  siblings.
- Windows hardware, appearance: every pin shows the rounded photo with its
  light glow and no dark border; the pointer over a pin shows the normal arrow
  rather than the busy/"app starting" cursor; the zoom badge stays small and a
  wheel-up/wheel-down round trip returns the photo to exactly its starting size.
- macOS and Linux still build and keep their existing pin behavior; they do not
  claim text pins or global Escape, and Wayland's documented shortcut limitation
  is unchanged.

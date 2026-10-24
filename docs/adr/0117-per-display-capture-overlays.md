# ADR 0117: Per-display capture overlays with display-local selections

Status: accepted for implementation; native multi-display acceptance requires the
capture overlay checklist on real hardware.

## Context

A capture started on one display only. The display under the pointer was frozen
and given an overlay; every other connected display kept showing the live
desktop with no overlay and no frozen frame, so a region could not be dragged
there at all. Moving the pointer to the second display and trying again froze
the first display a second time.

The session model assumed one display: `CaptureSession` owned a single
`CapturedDisplay`, the protocol store held one frozen PNG, and every pixel
consumer — OCR, QR, scrolling capture, recording, annotation staging — read that
one display. Overlay labels were already stored in a vector, but only one label
was ever created.

A rectangle spanning two displays would need a shared coordinate space, a single
gesture that crosses two independent WebViews, and cross-display DPI conversion
for export. That is a different feature with its own risk.

## Decision

Each frozen display owns its own capture surface.

- `CaptureSession` stores `displays: Vec<CapturedDisplay>` and
  `overlays: Vec<OverlayBinding>`. Index 0 is the display that owned the pointer
  when capture started; every binding names its display index and its frozen
  frame token. Overlay labels are `overlay`, `overlay-2`, `overlay-3`, …. Two
  displays that report the same id are frozen once.
- The pointer display is still frozen and presented first, so the delay before
  the first interactive overlay is unchanged. After that overlay has requested
  its own context, a coordinator thread freezes the remaining displays one at a
  time and creates one overlay per display. A failed secondary freeze or overlay
  creation is logged and skipped; the primary session and the overlays already
  on screen keep working. A failed primary freeze still cancels capture.
- macOS dispatches each secondary freeze to the main thread because
  ScreenCaptureKit and `NSScreen` enumeration are main-thread-only. The Windows
  and X11 backends already capture on their own worker, so the coordinator calls
  them directly and never stalls the desktop.
- Wayland returns no additional display ids, so it keeps its existing
  single-display behavior instead of mapping a selection to an uncertain screen.
- Every command that reads pixels or geometry resolves the display through the
  calling overlay's binding: `start_capture` returns a per-overlay
  `CaptureContextDto`, and OCR, QR recognition, scrolling capture, recording,
  annotation staging, color copying, and microphone checks use the same owner.
  A missing binding fails closed instead of falling back to another display's
  pixels. `prepare_capture_annotation` records the owner label in the staged
  snapshot, and confirmation is rejected when it arrives from a peer overlay.
- Selection, annotation, and every export coordinate stay inside one display's
  local logical space with that display's own `backing_scale`. Completion
  feedback, the recording countdown, and the recording control bar are
  positioned on the display of the overlay that confirmed or started the
  capture. Escape cancels the whole session from any overlay; Return confirms
  only the focused overlay's selection.
- Frozen frames live in a token-keyed store and are revoked together by capture
  id. Destroying one overlay removes only its binding; the session ends — and
  restores the pre-capture windows — when the last binding is destroyed.

## Consequences

- A capture can begin on any connected display without moving the pointer to it
  first, and a region never spans two displays.
- Memory grows by one frozen PNG per display for the duration of the session;
  all frames are released when the session ends.
- Secondary overlays are created without initial keyboard focus, so the pointer
  display keeps typing, Return, and Escape behavior. Clicking a secondary
  overlay gives it normal interaction focus.
- Mixed-DPI desktops use each display's own scale. There is no cross-display
  conversion because no selection crosses displays.
- A display added, removed, or reordered after capture starts is not picked up
  by that session; the next capture enumerates displays again.
- Multi-display behavior remains untested on Wayland by design, and macOS
  full-screen Space parents are created per overlay window.

## Verification

- Rust: overlay labels resolve only their bound display, a missing binding
  resolves to nothing, destroying one overlay keeps the session alive while the
  last one ends it, and clearing a capture revokes every display token while a
  different capture keeps its own.
- Node: the overlay still uses per-display context for selection, OCR, QR, and
  recording requests.
- Manual (single display): capture, annotate, confirm, record, OCR, QR, and
  scrolling capture are unchanged.
- Manual (two displays, macOS Retina + 1x external, Windows 100 %/150 %, X11
  dual screen): both displays show a frozen overlay; the pointer display is
  interactive first; a region can be dragged on either display; the completion
  card, countdown, and recording controls appear on the display that started the
  action; Escape cancels from either display; disconnecting a secondary display
  before capture does not block the primary one.

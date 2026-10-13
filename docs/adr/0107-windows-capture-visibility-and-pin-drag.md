# ADR 0107: Synchronize Windows capture visibility and pin movement

- Status: Accepted
- Date: 2026-10-14

## Context

A fixed delay after hiding the library can freeze its DWM transition into the
screenshot. Windows WebView image dragging can also interfere with native
window dragging. An unsupported or unauthorized recording border override must
not stop capture.

## Decision

- Hide Kiri's visible library windows with their DWM transitions temporarily
  disabled. A visibility query acknowledges Tao's queued hide, then DwmFlush
  completes the compositor work before GDI freezes the desktop. Restore the
  normal transition policy on every exit. Hide failure restores prior windows
  and reports an error instead of capturing Kiri. Clear toast renderer state
  after native hiding completes.
- Extend ADR 0102: check border-control support and request the Windows
  Borderless capture capability before selecting WithoutBorder. Denial,
  unavailable APIs, or request errors retain Windows' default indicator and do
  not disable recording. Other sessions or OS policy may retain an indicator.
- Extend ADR 0095 to Windows: use captured pointer positions with serialized
  physical window updates. Keep the final pointer position when release occurs
  before native position/scale reads complete. Cancelled, unmounted, and
  superseded gestures cannot move the window. Linux retains native dragging.
- Suppress the pinned image's WebView context menu. Existing resize and close
  controls remain unchanged.

## Verification

Windows installed-app acceptance covers a visible library over a known source,
Escape restoration, and two exported pixel comparisons. Pin handler regressions
cover delayed origins, short gestures, cancellation, stale updates, and DPI
conversion. Windows runtime acceptance remains separate from these tests.

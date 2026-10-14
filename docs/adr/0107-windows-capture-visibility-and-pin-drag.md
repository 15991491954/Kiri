# ADR 0107: Synchronize Windows capture visibility and pin movement

- Status: Accepted
- Date: 2026-10-14

## Context

A fixed delay after hiding the library can freeze its DWM transition into the
screenshot. Windows WebView image dragging can also interfere with native
window dragging. An unsupported or unauthorized recording border override must
not stop capture.

The completion toast uses `ShowWindow(SW_SHOWNOACTIVATE)` to avoid taking focus.
That native show does not update Tao 0.35.3's cached `WindowFlags::VISIBLE`.
Tao's `set_visible(false)` applies only a flag difference, so a cached
false-to-false hide can do nothing while `IsWindowVisible` still reports a
visible toast. A queued-hide acknowledgement alone is therefore insufficient.

## Decision

- Hide Kiri's visible library windows with their DWM transitions temporarily
  disabled. A visibility query acknowledges Tao's queued hide, then DwmFlush
  completes the compositor work before GDI freezes the desktop. Restore the
  normal transition policy on every exit. Hide failure restores prior windows
  and reports an error instead of capturing Kiri. Clear toast renderer state
  after native hiding completes.
- After Tao's hide and its queue acknowledgement, reconcile any still-visible
  owned HWND with `ShowWindow(SW_HIDE)`, verify `IsWindowVisible` is false, and
  then flush DWM. This leaves both the cached flag and native window hidden.
  Preserve the toast's non-activating show; do not briefly show or focus a
  window just to repair a visibility flag. Native hide failures still stop
  capture and restore prior library windows.
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

Full CI run 38435925923 on candidate af74472 reproduced the stale-toast case
after successful cancellation and screenshot completion: the toast became
ready at 17:31:38.614 UTC, then capture failed its real visibility check at
17:31:40.526 UTC. The existing installed-app acceptance sequence must pass
through screenshot completion, visible toast, and the next capture without
relaxing its window or exported-pixel checks. The follow-up fix requires a new
Windows package and runtime verification; source/API checks are not that proof.

# ADR 0105: Recording controls follow the selected region

- Status: Accepted
- Date: 2026-10-13

## Context

A region recording produced the correct crop, but its controls opened in the
display corner and restored an unchecked global position from an earlier
recording. This separated the controls from the recorded area and could leave
them outside a changed display setup.

## Decision

- Give recording preparation its own compact layout: MP4/GIF format selection,
  Start, and four inline icon buttons for system audio, microphone, pointer, and
  click highlights. Reuse the capture toolbar’s dark palette and shared design
  tokens. Do not use switch widgets or an expandable settings area. Keep existing
  platform capability gates; GIF remains silent.
- Start always uses a three-second countdown, with no countdown toggle. Remove
  recording size editing and the microphone-test entry from this preparation
  panel. Screenshot width/height editing through its sliders button is unchanged.
- A small arrow beside the microphone opens the actual input-device list.
  Selecting a device affects Kiri’s recording only, never the system default.
  If the selected device is unavailable or disconnects, fail explicitly rather
  than silently substituting another microphone.
- Place the preparation panel in the center of a selection large enough to
  contain it. Otherwise prefer below, then above or beside the selection, and
  keep all actions within the display. This policy is separate from screenshot
  and OCR toolbars. Hold its position while the selection is being dragged or
  resized, then re-anchor on release. Preparation has no drag handle or manual
  panel movement. When a moved mode selector leaves too little height for the
  fixed header, scroll the whole preparation panel
  so every control remains reachable.
- Keep a compact, flat control bar with a drag grip, pause/resume, elapsed time,
  and an explicit Stop Recording button. Pausing retains the elapsed time.
- Measure the translated controls before showing the native window. Placement
  prefers the region's lower right, then above or beside it. When no external
  space exists, fit inside the monitor work area, avoiding reserved desktop UI.
- Respect the rendered CSS pixel ratio, including Windows accessibility text
  scaling. All native coordinates use the actual destination display scale.
- Manual dragging applies to the current recording only. Serialize drag and
  layout writes; fit the final position into the current monitor. A new recording
  starts beside its own region instead of restoring an absolute global position.
- Show a thin, monochrome, click-through outline at the recorded region. macOS
  excludes it through the existing application capture filter; Windows enables
  it only where window capture exclusion is supported. Indicator creation
  failure must not prevent otherwise valid recording.
- Windows builds before 19041 retain the system capture indicator instead of a
  full transparent excluded window, which those versions could render black.
  The existing optional WGC border capability check remains unchanged; an OS
  that cannot disable its display indicator can still show that indicator.
- Linux retains tray/CLI recording controls because portal capture cannot
  reliably exclude a floating bar or border.
- Stop, cancellation, and failure clean up the control bar and region outline
  together. The position command is bound to the active recording UUID and the
  control-panel window.

## Consequences

The recording crop and encoding pipeline are unchanged; microphone capture uses
the explicitly selected input. The control bar and region outline remain outside
exported footage. Native acceptance must cover selection
placement, reserved display areas, drag/pause/stop, capture exclusion, selected
microphone capture and explicit unavailable/disconnected-device failures, and
multiple-display scaling separately from geometry and renderer tests.

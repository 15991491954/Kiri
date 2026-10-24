# ADR 0116: Overlay mode switching and cursor feedback

Status: accepted for implementation; native pointer and keyboard acceptance uses
the existing capture overlay checklist.

## Context

The capture overlay opens with a mode selector fixed above the pointer. Choosing
Record or OCR required moving the mouse to the top of the screen before the
region could be dragged, and repeating the same kind of capture repeated that
movement every time. The selector was also the only way to change mode.

Two pointer-feedback gaps made region editing feel broken. Once a region
existed, the cursor stayed `crosshair` everywhere on the frozen screen: the
eight resize handles, the region interior, and the blank desktop all looked the
same. Users could not tell that edges were draggable, so they assumed resizing
was unavailable.

The overlay already owned complete pointer geometry (`hitTestHandle`,
`contains`) and a mode-switch routine (`switchMode`) that preserved a committed
region across modes, so both gaps were presentation problems rather than new
interaction models.

## Decision

Mode switching without pointer travel:

- Digits `1`, `2`, and `3` select Screenshot, Record, and OCR. They apply in
  `mode-select`, `selecting`, and `record-options` only, and are ignored while
  modifiers are held, while an IME composition is active, and while focus is in
  an editable control.
- The wheel cycles the same three modes in place. One switch needs 60
  accumulated pixels, then a 350 ms cooldown swallows trackpad momentum.
  Events over the mode selector, toolbars, recording options, size fields, and
  the color picker keep their native scrolling.
- The overlay remembers the mode the user actually worked in
  (`app_config_dir()/capture-mode.json`). The generic capture entries — the
  default shortcut, the tray item, `--capture`, and the library — start in that
  mode. Explicit entries (`--record`, `--ocr`, and their shortcuts) still force
  their own mode for that session. A missing or damaged file falls back to
  screenshot instead of blocking capture.
- The three mode buttons show small `1`/`2`/`3` badges, and the empty-region
  hint ends with the same reference. No new shortcut-setting rows are added;
  these keys only exist inside the overlay.

Cursor feedback:

- One shared mapping (`src/annotation/cursors.js`) decides every cursor for the
  overlay and the annotation canvas. Corners use `nwse-resize`/`nesw-resize`,
  edges use `ns-resize`/`ew-resize`, the region interior uses `move`, and blank
  frozen screen keeps `crosshair`.
- An active resize or move wins over hover state, so the cursor does not flicker
  back to `crosshair` when the pointer leaves a handle's hit circle mid-drag.
- The handle hit radius grows from 10 to 12 points while the drawn dots keep
  their 10 px size, so the cursor changes just before the pointer reaches a dot.
- Annotation marks reuse the same handle mapping. Line and arrow endpoints and
  the callout handle keep `crosshair` because they are single drag points, not
  corner resizes.

## Consequences

- Repeating a capture needs no selector visit: `Shift+Ctrl+A` (or the default
  macOS shortcut), then drag, and the previous mode is already active.
- A mode chosen through an explicit record/OCR shortcut also becomes the
  remembered mode, because the overlay writes the mode it finished in. Users who
  alternate deliberately keep the last choice from either entry point.
- The wheel is live only on the frozen screen. Scrolling inside the recording
  options or any numeric field is unchanged.
- Cursor shape now distinguishes "new region", "move", and eight resize
  directions on both the overlay and saved-image annotations.
- Selection geometry and hit testing are unchanged. A rectangle still never
  spans two displays; ADR 0117 gives each frozen display its own overlay
  instead of sharing one selection across displays.

## Verification

- Node: digit mapping, phase gating, wheel threshold/cooldown/cycling, cursor
  mapping and drag precedence, plus the rendered overlay's badges, hint text,
  wheel handling, hover cursors, and debounced mode write.
- Rust: `capture-mode.json` round-trip, unknown-mode rejection, and the
  screenshot fallback for damaged or missing files.
- Manual: `pnpm tauri dev`, then in the overlay press `1`/`2`/`3`, spin the
  wheel, confirm the hint and badges, and check cursor shapes over blank
  screen, inside a region, and on all eight handles. Confirm the next generic
  shortcut reopens the last mode and that the record shortcut still forces
  recording. A rectangle that spans two displays stays out of scope here;
  ADR 0117 covers working on a second display.

# 0120 - Pin context menu, zoom reset, and the remembered capture region

Date: 2026-10-24
Status: Accepted

## Context

The native Windows pins (ADR 0118) already moved, resized, zoomed, and changed
opacity, but they had no way to copy or save their own pixels, to hold a
position deliberately, or to return exactly to 100%. Separately, every
screenshot started from an empty selection, so repeating the same area meant
drawing it again.

## Decision

1. **Pin context menu.** Right-clicking a pin opens a native menu with, in
   order: Copy Image, Save as PNG, a separator, Pin on Top (checked while
   topmost), Lock Position (checked while locked), a separator, Close, and Close
   All Pins. Copy encodes the pin's own snapshot, not the library file, so a pin
   created from the clipboard can be copied back. Save uses the system save
   panel and writes PNG bytes. Lock Position keeps the card's rectangle fixed:
   dragging, edge resizing, and arrow nudging are ignored while it is checked;
   zoom still applies because it changes the reference size rather than the
   position. The menu is localized through the same small label table as the
   tray. The WebView pin on macOS and Linux mirrors the menu with Copy, Reset
   100%, Lock/Unlock Position, Pin on Top, and Close.

2. **100% is an explicit destination.** A double click on a pin, or Ctrl+0
   while a pin has the keyboard, restores one image pixel per physical pixel
   using the image's own dimensions, and shows the 100% badge. This replaces
   stepping the wheel towards 100% and is the same gesture on both pin
   implementations.

3. **Ctrl+Arrow nudges by one physical pixel.** Without Ctrl the arrow keys keep
   the display-independent DIP step, so scaled displays feel the same.

4. **The last screenshot region is remembered per display.** A completed
   screenshot saves its display-local region together with the display's
   logical frame in `Settings/last-capture-selection.json`. The next capture
   context includes that rectangle only when the same display is still present
   at the same position and size; the overlay then opens with it preselected, so
   Return repeats the area and a drag replaces it. Recording and OCR never
   restore a region. Cancelled selections, editor saves, and OCR probes do not
   update the file: only a confirmed screenshot is a meaningful "last area".

5. **The tray offers direct entries.** Capture, Pin from Clipboard, Start
   Recording, Open Library, Clear Image Cache, and Quit are all one click away,
   instead of routing every action through the library window.

## Consequences

- A stale region cannot be restored after a monitor is moved, resized, or
  disconnected; the capture simply starts empty, which is the safe default.
- The remembered region belongs to the display it was drawn on. A second
  overlay on another display receives no preselection.
- The pin menu writes files and clipboard content from worker threads, so a
  slow save panel never freezes the pin's message loop.
- `scripts/qa/windows-pin-interactions.ps1` and
  `scripts/qa/windows-capture-region.ps1` cover the new interactions with real
  native input and are part of the Windows pre-release pass.

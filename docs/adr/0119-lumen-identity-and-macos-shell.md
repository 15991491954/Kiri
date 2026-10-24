# ADR 0119: Lumen identity, macOS-style shell, and F1/F2/F3 shortcuts

Status: accepted for implementation.

## Context

The product shipped as "Kiri" with a monochrome workspace (ADR 0015), a native
Windows title bar, and a capture shortcut of `⇧⌘A` / `Shift+Ctrl+A`. The visual
identity no longer matched the interaction model: screenshots are clipboard-first
and pinned as floating references, the library stores recordings, and the three
actions a user reaches for are capture, pin, and record.

The owner asked for a macOS-style application shell (including the top area), a
professional name and icon, and dedicated function-key shortcuts: F1 to capture,
F2 to pin the clipboard, F3 to record. Screenshots must not accumulate in the
library, but are copied to the clipboard automatically.

## Decision

- **Name and mark.** The product is **Lumen**. The display name, window titles,
  tray label, notifications, documentation, and installer use it. The bundle
  identifier (`io.yuxino.kiri`), the `%APPDATA%\kiri` / `$XDG_DATA_HOME/kiri`
  storage layout, the `Kiri Library` managed folder, the `kiri://` protocol,
  window labels, and the `kiri.exe` binary name are kept: they are compatibility
  surfaces for existing libraries, update metadata, and the release pipeline, not
  branding. `bundle.mainBinaryName` pins the binary name so renaming the display
  name cannot break installers or QA scripts.
- **Mark.** A four-bracket viewfinder around a capture dot: a blue rounded
  square app icon (`scripts/app-icon-source.mjs` generates the 1024 master) and a
  monochrome menu-bar template (`scripts/tray-icon-source.mjs`). In the app the
  same geometry is drawn as SVG (`LumenMark`), so the brand stays crisp at every
  scale and needs no bitmap.
- **Application shell.** The main window is undecorated and owns its window
  chrome: a 46 DIP title bar with macOS traffic lights (close, minimize, zoom),
  the brand, a centered page title, and a drag region. Edges and corners start
  the compositor's resize loop through `startResizeDragging`, so minimum size,
  DPI, and snap behavior stay native. The sidebar is a translucent source list
  with 30 DIP rows; the workspace carries a compact toolbar (search, filters,
  actions) instead of a large page header.
- **Visual language.** Tokens follow macOS: system blue (`#007aff`) for
  selection, focus rings, and the primary action; neutral window/sidebar/content
  surfaces; hairline separators; 6 DIP control and 10 DIP card radii; the
  platform UI font stack (`-apple-system` → "SF Pro Text" → "Segoe UI" →
  "PingFang SC"). The monochrome-workspace rule of ADR 0015 is superseded for
  selection and primary actions; decoration remains restrained (no gradients or
  colored shadows in the workspace). Capture overlays and editors keep their dark
  HUD palette.
- **Shortcuts.** Defaults are `F1` capture, `F2` paste-as-pin, `F3` record on
  every platform. Function keys need no modifier and save without the
  single-key confirmation (ADR 0111). Recognition, library, and the recording
  pause/stop actions keep their modifier chords. A stored binding that is still
  the previous default (`⇧⌘A` / `Shift+Ctrl+A`, `⇧⌥⌘R` / `Shift+Ctrl+Alt+R`, or
  F3 for pinning) follows the new default on the next launch; a customized
  binding is never rewritten.
- **Library scope.** The library lists recordings (videos and GIF conversions of
  recordings) only. Screenshot images are clipboard-first: confirming a capture
  copies it, and the image is kept only long enough to pin or edit before the
  retention pass removes it. The library therefore has no image filter, no
  "Paste Image" action, and its import accepts video files only; a still image
  dropped on the window is reported as not importable instead of silently
  disappearing. The toolbar's pin action remains the way to keep a capture on
  screen.

## Consequences

- Existing installations keep their data and update path, while every
  user-visible name changes. The executable and identifier are intentionally not
  renamed.
- A custom title bar means Lumen now owns dragging, double-click zoom, and edge
  resizing for the main window; the title bar must keep those behaviors working
  at every scale and with a maximized window.
- F1/F2/F3 are global: applications that use F1 help or Explorer's F2 rename no
  longer receive those keys while Lumen runs. Users can rebind or disable any
  action in Settings.
- A migration rewrites only values that were still the old defaults. A user who
  deliberately kept `Shift+Ctrl+A` will be moved to F1 once; re-selecting it in
  Settings persists normally afterwards.
- Library imports are video-only. Importing a still image is refused with a
  visible notice instead of creating an asset the list would hide.

## Verification

- Rust tests cover the new defaults, the legacy-default migration, customized
  binding preservation, and registry/hit-test behavior unchanged by the shell.
- Node suites cover the library render without the image filter or paste action,
  the video-only import path, dictionary parity across seven languages, the
  titlebar's interaction classes, and the drag-region contract.
- Windows hardware: the undecorated window can be dragged from the title bar,
  double-clicked to zoom, resized from all eight edges, minimized, and closed
  with the traffic lights; the traffic lights show their glyphs on hover; the
  window keeps its shadow and never loses the close affordance.
- Windows hardware: F1 opens capture, F2 pins the copied image or text, F3 starts
  recording; the settings list shows F1/F2/F3 as defaults and Restore Default
  returns to them.
- Visual acceptance is judged on the real Windows compositor: title bar height,
  traffic-light spacing, sidebar selection tint, toolbar density, and dark mode
  are compared against macOS reference screenshots.

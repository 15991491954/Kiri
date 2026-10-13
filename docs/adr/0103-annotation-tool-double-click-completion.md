# ADR 0103: Blank screenshot completion with every annotation tool

- Status: Accepted
- Date: 2026-10-13
- Partially supersedes: ADR 0077 annotation tool restriction

## Context

The reopened #104 reports that blank double-click completion works only with Select. Requiring a tool change after annotating makes the same capture gesture behave inconsistently.

## Decision

- A stationary native mouse double-click on blank screenshot canvas completes with every annotation tool. The native click count owns the system timing; neither press may move three CSS pixels.
- Capture the pre-gesture history, including undo/redo. When the pair completes, restore it before export so click-created pen/mosaic dots, numbers, text or watermark drafts are excluded. Already committed annotations remain unchanged. A failed export retains the previous undo/redo state.
- Existing marks, selection handles, active text/composition, intervening typing, tool changes and canceled gestures retain their existing behavior. A newly mounted untouched input from the first click belongs to that pair; it does not block completion.
- Only screenshot overlays supply the completion callback. Saved-image/video editors, OCR and recording keep their behavior. Completion uses the existing export/IPC lock and restores source-app focus.

## Verification

Component event tests cover all tools, typed inputs, dragging either press, existing annotations, history retry and saved-image editing. Windows installed-app acceptance uses real native double-clicks and compares exported pixels with the desktop source for each tool.

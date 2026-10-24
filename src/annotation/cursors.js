// Pointer-cursor decisions shared by the capture overlay and the annotation
// canvas. Both surfaces hit-test the same eight selection handles, so the
// mapping lives here instead of being duplicated as inline ternaries.

// Handles are named after the corner/edge they sit on, which fixes the
// diagonal each one drags: corners run northwest-southeast or northeast-
// southwest, edges only run along one axis.
const HANDLE_CURSORS = Object.freeze({
  topLeft: "nwse-resize",
  bottomRight: "nwse-resize",
  topRight: "nesw-resize",
  bottomLeft: "nesw-resize",
  top: "ns-resize",
  bottom: "ns-resize",
  left: "ew-resize",
  right: "ew-resize",
});

export const HANDLE_CURSOR_MAP = HANDLE_CURSORS;

/** Cursor for a named selection handle, or null when the name is unknown. */
export function handleCursor(handle) {
  if (!handle) return null;
  return HANDLE_CURSORS[handle] ?? null;
}

/** Phases where the frozen screen accepts a drag that starts a new region. */
export function isRegionPhase(phase) {
  return phase === "mode-select" || phase === "selecting" || phase === "record-options";
}

/**
 * Root cursor for the capture overlay.
 *
 * An active drag wins over hover state so the cursor does not flicker back to
 * `crosshair` when the pointer leaves a handle's hit circle mid-resize.
 */
export function interactionCursor(state) {
  if (state.completing) return "progress";
  if (state.resizeHandle) return handleCursor(state.resizeHandle) ?? "crosshair";
  if (state.moving) return "move";
  if (state.dragging) return "crosshair";
  if (state.hoverHandle) return handleCursor(state.hoverHandle) ?? "crosshair";
  if (state.hoverInside) return "move";
  return isRegionPhase(state.phase) ? "crosshair" : "default";
}

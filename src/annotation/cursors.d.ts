export type SelectionHandleName =
  | "topLeft"
  | "topRight"
  | "bottomLeft"
  | "bottomRight"
  | "top"
  | "bottom"
  | "left"
  | "right";

export const HANDLE_CURSOR_MAP: Readonly<Record<SelectionHandleName, string>>;
export function handleCursor(handle: string | null | undefined): string | null;
export function isRegionPhase(phase: string): boolean;

export interface InteractionCursorState {
  completing?: boolean;
  phase: string;
  resizeHandle?: string | null;
  moving?: boolean;
  dragging?: boolean;
  hoverHandle?: string | null;
  hoverInside?: boolean;
}

export function interactionCursor(state: InteractionCursorState): string;

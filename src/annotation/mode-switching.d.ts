export type CaptureModeName = "screenshot" | "record" | "ocr";

export const MODE_ORDER: readonly CaptureModeName[];
export function modeForKey(key: string): CaptureModeName | null;
export function canSwitchMode(phase: string): boolean;
export function cycleMode(mode: CaptureModeName, direction: number): CaptureModeName;

export const WHEEL_SWITCH_THRESHOLD: number;
export const WHEEL_SWITCH_COOLDOWN_MS: number;

export interface WheelSwitchState {
  accumulated: number;
  cooldownUntil: number;
}

export interface WheelSwitchResult {
  state: WheelSwitchState;
  direction: number;
}

export function idleWheelState(): WheelSwitchState;
export function normalizeWheelDelta(deltaY: number, deltaMode?: number): number;
export function wheelModeStep(
  state: WheelSwitchState,
  deltaY: number,
  now: number,
): WheelSwitchResult;

// Mode switching for the capture overlay: number keys, wheel cycling, and the
// acceleration rules that keep a trackpad flick from skipping two modes.
// Pure functions so the overlay stays a thin consumer and Node can test them.

export const MODE_ORDER = Object.freeze(["screenshot", "record", "ocr"]);

const MODE_KEYS = Object.freeze({ "1": "screenshot", "2": "record", "3": "ocr" });

/** Number-key digit → capture mode. Digits match the selector's badge order. */
export function modeForKey(key) {
  if (typeof key !== "string") return null;
  return MODE_KEYS[key] ?? null;
}

/** Phases where changing mode cannot destroy in-progress annotation work.
 *
 * A finished OCR result or its consent prompt is a read-only surface: leaving
 * it must stay possible without closing the capture, so the mode selector and
 * the wheel keep working there.
 */
export function canSwitchMode(phase) {
  return phase === "mode-select" || phase === "selecting" || phase === "record-options"
    || phase === "ocr-result" || phase === "ocr-consent";
}

/** Cycle one step through MODE_ORDER; direction 0 or an unknown mode is a no-op. */
export function cycleMode(mode, direction) {
  const index = MODE_ORDER.indexOf(mode);
  if (index < 0 || !direction) return mode;
  const step = direction > 0 ? 1 : -1;
  return MODE_ORDER[(index + step + MODE_ORDER.length) % MODE_ORDER.length];
}

export const WHEEL_SWITCH_THRESHOLD = 60;
export const WHEEL_SWITCH_COOLDOWN_MS = 350;

export function idleWheelState() {
  return { accumulated: 0, cooldownUntil: 0 };
}

/**
 * Wheel deltas arrive in pixels on most engines, but Firefox-style line and
 * page modes still exist in embedded WebViews.
 */
export function normalizeWheelDelta(deltaY, deltaMode) {
  if (!Number.isFinite(deltaY)) return 0;
  if (deltaMode === 1) return deltaY * 16;
  if (deltaMode === 2) return deltaY * 400;
  return deltaY;
}

/**
 * Accumulate wheel movement and report a one-step switch once the threshold is
 * crossed. Momentum scroll after a switch is swallowed by the cooldown, and the
 * accumulator resets so the next gesture starts from zero.
 */
export function wheelModeStep(state, deltaY, now) {
  const current = state ?? idleWheelState();
  const delta = Number.isFinite(deltaY) ? deltaY : 0;
  if (delta === 0) return { state: current, direction: 0 };
  if (now < current.cooldownUntil) {
    return { state: { accumulated: 0, cooldownUntil: current.cooldownUntil }, direction: 0 };
  }
  const accumulated = current.accumulated + delta;
  if (Math.abs(accumulated) < WHEEL_SWITCH_THRESHOLD) {
    return { state: { accumulated, cooldownUntil: current.cooldownUntil }, direction: 0 };
  }
  return {
    state: { accumulated: 0, cooldownUntil: now + WHEEL_SWITCH_COOLDOWN_MS },
    direction: accumulated > 0 ? 1 : -1,
  };
}

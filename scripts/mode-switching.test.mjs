import assert from "node:assert/strict";
import test from "node:test";
import {
  MODE_ORDER,
  WHEEL_SWITCH_COOLDOWN_MS,
  WHEEL_SWITCH_THRESHOLD,
  canSwitchMode,
  cycleMode,
  idleWheelState,
  modeForKey,
  normalizeWheelDelta,
  wheelModeStep,
} from "../src/annotation/mode-switching.js";

test("digits 1, 2 and 3 select screenshot, record and OCR", () => {
  assert.deepEqual(MODE_ORDER, ["screenshot", "record", "ocr"]);
  assert.equal(modeForKey("1"), "screenshot");
  assert.equal(modeForKey("2"), "record");
  assert.equal(modeForKey("3"), "ocr");
  for (const key of ["0", "4", "a", " ", "Enter", ""]) assert.equal(modeForKey(key), null);
  assert.equal(modeForKey(undefined), null);
});

test("mode keys keep working on read-only result and consent surfaces", () => {
  for (const phase of ["mode-select", "selecting", "record-options", "ocr-result", "ocr-consent"]) {
    assert.equal(canSwitchMode(phase), true);
  }
  for (const phase of ["annotating", "qr-result", "ocr-preparing"]) {
    assert.equal(canSwitchMode(phase), false);
  }
});

test("cycling wraps in both directions", () => {
  assert.equal(cycleMode("screenshot", 1), "record");
  assert.equal(cycleMode("record", 1), "ocr");
  assert.equal(cycleMode("ocr", 1), "screenshot");
  assert.equal(cycleMode("screenshot", -1), "ocr");
  assert.equal(cycleMode("ocr", -1), "record");
  assert.equal(cycleMode("record", -1), "screenshot");
  assert.equal(cycleMode("record", 0), "record");
  assert.equal(cycleMode("unknown", 1), "unknown");
});

test("wheel movement below the threshold accumulates without switching", () => {
  let state = idleWheelState();
  let result = wheelModeStep(state, 20, 1000);
  assert.equal(result.direction, 0);
  assert.equal(result.state.accumulated, 20);
  result = wheelModeStep(result.state, 20, 1010);
  assert.equal(result.direction, 0);
  assert.equal(result.state.accumulated, 40);
});

test("crossing the threshold switches once and ignores momentum", () => {
  let result = wheelModeStep(idleWheelState(), WHEEL_SWITCH_THRESHOLD, 1000);
  assert.equal(result.direction, 1);
  assert.equal(result.state.accumulated, 0);
  assert.equal(result.state.cooldownUntil, 1000 + WHEEL_SWITCH_COOLDOWN_MS);

  // Momentum events right after the switch stay inside the cooldown.
  for (const now of [1010, 1100, 1300]) {
    const next = wheelModeStep(result.state, 400, now);
    assert.equal(next.direction, 0, String(now));
    assert.equal(next.state.accumulated, 0);
  }

  // The first event after the cooldown can switch again.
  const after = wheelModeStep(result.state, WHEEL_SWITCH_THRESHOLD, 1400);
  assert.equal(after.direction, 1);
});

test("upward wheel movement reports the negative direction", () => {
  const result = wheelModeStep(idleWheelState(), -WHEEL_SWITCH_THRESHOLD, 500);
  assert.equal(result.direction, -1);
  const mixed = wheelModeStep({ accumulated: 40, cooldownUntil: 0 }, -100, 600);
  assert.equal(mixed.direction, -1);
});

test("zero and non-finite deltas leave the accumulator untouched", () => {
  const state = { accumulated: 25, cooldownUntil: 0 };
  assert.deepEqual(wheelModeStep(state, 0, 10).state, state);
  assert.deepEqual(wheelModeStep(state, NaN, 10).state, state);
  assert.deepEqual(wheelModeStep(undefined, 5, 10).state, { accumulated: 5, cooldownUntil: 0 });
});

test("line and page wheel modes are normalised to pixels", () => {
  assert.equal(normalizeWheelDelta(3, 0), 3);
  assert.equal(normalizeWheelDelta(3, 1), 48);
  assert.equal(normalizeWheelDelta(1, 2), 400);
  assert.equal(normalizeWheelDelta(Number.NaN, 0), 0);
  assert.equal(normalizeWheelDelta(4), 4);
});

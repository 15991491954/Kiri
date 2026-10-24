import assert from "node:assert/strict";
import test from "node:test";
import { handleCursor, interactionCursor, isRegionPhase } from "../src/annotation/cursors.js";

test("each of the eight handles reports a resize direction that matches its edge", () => {
  assert.equal(handleCursor("topLeft"), "nwse-resize");
  assert.equal(handleCursor("bottomRight"), "nwse-resize");
  assert.equal(handleCursor("topRight"), "nesw-resize");
  assert.equal(handleCursor("bottomLeft"), "nesw-resize");
  assert.equal(handleCursor("top"), "ns-resize");
  assert.equal(handleCursor("bottom"), "ns-resize");
  assert.equal(handleCursor("left"), "ew-resize");
  assert.equal(handleCursor("right"), "ew-resize");
  assert.equal(handleCursor(null), null);
  assert.equal(handleCursor("center"), null);
});

test("blank canvas keeps the crosshair until a region exists", () => {
  for (const phase of ["mode-select", "selecting", "record-options"]) {
    assert.equal(isRegionPhase(phase), true);
    assert.equal(interactionCursor({ phase }), "crosshair");
  }
  for (const phase of ["annotating", "ocr-result", "qr-result", "ocr-consent"]) {
    assert.equal(isRegionPhase(phase), false);
    assert.equal(interactionCursor({ phase }), "default");
  }
});

test("hovering a handle or the inside of a region previews the pending action", () => {
  assert.equal(interactionCursor({ phase: "selecting", hoverHandle: "topLeft" }), "nwse-resize");
  assert.equal(interactionCursor({ phase: "record-options", hoverHandle: "right" }), "ew-resize");
  assert.equal(interactionCursor({ phase: "selecting", hoverInside: true }), "move");
  // Unknown handles still say "you can drag here" instead of falling back.
  assert.equal(interactionCursor({ phase: "selecting", hoverHandle: "center" }), "crosshair");
});

test("an active drag outranks hover state so the cursor does not flicker", () => {
  assert.equal(interactionCursor({ phase: "selecting", resizeHandle: "bottom", hoverInside: true }), "ns-resize");
  assert.equal(interactionCursor({ phase: "selecting", moving: true }), "move");
  assert.equal(interactionCursor({ phase: "selecting", dragging: true, hoverHandle: "top" }), "crosshair");
  assert.equal(interactionCursor({ phase: "selecting", completing: true }), "progress");
});

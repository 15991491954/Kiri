import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { createLibraryHarness, deferred, nodes, settleRequests, testAsset } from "./helpers/library-render-harness.mjs";
import * as viewerState from "../src/windows/viewer-state.js";

const source = 'import React from "react";\n' + readFileSync(new URL("../src/ocr/OcrDialog.tsx", import.meta.url), "utf8");
const record = (id, text) => ({ ...testAsset, id, ocrText: text });
const hasText = (tree, text) => nodes(tree).includes(text);
const button = (tree, text) => {
  const reader = nodes(tree).find((node) => node?.type?.name === "TextReader");
  return [...nodes(tree), ...nodes(reader?.props.actions)].find((node) => node?.type === "button" && hasText(node, text));
};

test("copy completion for another record never marks the newly selected text copied", async () => {
  const pending = deferred();
  const copied = [];
  const harness = createLibraryHarness({ copyOcrText: (text) => { copied.push(text); return pending.promise; } }, source);
  const component = harness.mount("TextReader", { text: "first", imageId: "one" });
  let tree = component.render();
  button(tree, "Copy Text").props.onClick();
  component.render({ text: "second", imageId: "two" });
  pending.resolve(); await settleRequests();
  tree = component.render();
  assert.deepEqual(copied, ["first"]);
  assert.equal(hasText(tree, "Text Copied"), false);
  component.unmount();
});

test("copy failures stay visible without losing text", async () => {
  const harness = createLibraryHarness({ copyOcrText: async () => { throw new Error("clipboard unavailable"); } }, source);
  const component = harness.mount("TextReader", { text: "keep this text" });
  let tree = component.render();
  button(tree, "Copy Text").props.onClick(); await settleRequests(); tree = component.render();
  assert.equal(hasText(tree, "keep this text"), true);
  assert.equal(hasText(tree, "Couldn't copy text."), true);
  component.unmount();
});

test("OCR dialog starts once and reads saved text without recognizing again", async () => {
  let calls = 0;
  const pending = deferred();
  const harness = createLibraryHarness({ recognizeAssetLocal: () => { calls++; return pending.promise; } }, source);
  const component = harness.mount("OcrDialog", { asset: testAsset, onClose() {} });
  component.render(); component.render(); assert.equal(calls, 1);
  component.unmount(); pending.resolve({ text: "complete" }); await settleRequests();
  const saved = harness.mount("OcrDialog", { asset: record("saved", "already recognized"), onClose() {} });
  saved.render(); assert.equal(calls, 1); saved.unmount();
});

test("an already open OCR dialog uses refreshed saved corrections", async () => {
  const harness = createLibraryHarness({ recognizeAssetLocal: () => { throw new Error("saved text must not be recognized again"); } }, source);
  const component = harness.mount("OcrDialog", { asset: record("saved", "first version"), onClose() {} });
  const reader = (tree) => nodes(tree).find(node => node?.type?.name === "TextReader");
  assert.equal(reader(component.render()).props.text, "first version");
  const updated = record("saved", "second version");
  assert.equal(reader(component.render({ asset: updated, onClose() {} })).props.text, "second version");
  const restored = record("saved", "original version");
  assert.equal(reader(component.render({ asset: restored, onClose() {} })).props.text, "original version");
  component.unmount();
});

test("an existing source viewer refreshes OCR metadata after saved asset changes", async () => {
  let asset = record("saved", "first version");
  const viewerSource = 'import React from "react";\n' + readFileSync(new URL("../src/windows/ViewerWindow.tsx", import.meta.url), "utf8");
  const harness = createLibraryHarness({
    getAsset: async () => asset,
    platformCapabilities: async () => ({ videoEditing: false }),
  }, viewerSource, { modules: {
    "@tauri-apps/api/window": { getCurrentWindow: () => ({ close: async () => {} }) },
    "./VideoTrimPlayer": { VideoTrimPlayer: "video-player" },
    "./viewer-state.js": viewerState,
  } });
  const viewer = harness.mount("ViewerWindow", { id: asset.id });
  viewer.render(); await settleRequests();
  button(viewer.render(), "Read Text").props.onClick();
  const dialog = () => nodes(viewer.render()).find(node => node?.type === "ocr-dialog");
  assert.equal(dialog().props.asset.ocrText, "first version");
  for (const text of ["second version", "third version"]) {
    asset = record("saved", text);
    harness.emit("assetContentChanged", asset.id); await settleRequests();
    assert.equal(dialog().props.asset.ocrText, text);
  }
  viewer.unmount();
});

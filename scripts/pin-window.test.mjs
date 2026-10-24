import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import ts from "typescript";
import { AnnotationInteractionLock } from "../src/annotation/interaction-lock.js";
import { capturePanelLayout, captureToolOptionsLayout, captureToolbarPosition } from "../src/windows/toolbar-layout.js";
import { createLibraryHarness, deferred, nodes, settleRequests } from "./helpers/library-render-harness.mjs";

const source = 'import React from "react";\n' + readFileSync(new URL("../src/windows/PinWindow.tsx", import.meta.url), "utf8");

function pinWindow(options = {}) {
  const requests = [];
  const sizes = [];
  const positions = [];
  const zooms = [];
  let drags = 0, closes = 0, raises = 0;
  let pinned, changed, reads = 0;
  const window = {
    // The Linux window manager can still be applying the builder's true state.
    isAlwaysOnTop: async () => { reads += 1; return false; },
    startDragging: async () => { drags += 1; },
    close: async () => { closes += 1; },
    innerSize: async () => ({ width: 400, height: 200 }),
    scaleFactor: options.scaleFactor ?? (async () => options.scale ?? 2),
    outerPosition: options.outerPosition ?? (async () => ({ x: -400, y: 100 })),
    setSize(value) { const result = deferred(); sizes.push({ value, ...result }); return result.promise; },
    setPosition(value) { const result = deferred(); positions.push({ value, ...result }); return result.promise; },
  };
  const h = createLibraryHarness({}, source, {navigator: { userAgent: options.userAgent ?? "Windows" }, modules: {
    "@tauri-apps/api/window": {getCurrentWindow: () => window},
    "@tauri-apps/api/dpi": {PhysicalSize: class { constructor(width, height) { this.width = width; this.height = height; } },
      PhysicalPosition: class { constructor(x, y) { this.x = x; this.y = y; } }},
    "../lib/ipc": {mediaUrl: () => "image:test", onAssetContentChanged: async callback => { changed = callback; return () => { changed = null; }; },
      onPinOnTop: async callback => { pinned = callback; return () => { pinned = null; }; },
      api: {
        setPinTopmost(value) { const result = deferred(); requests.push({value, ...result}); return result.promise; },
        raisePin: async () => { raises += 1; },
        zoomPin(factor, anchorX, anchorY, imageWidth, imageHeight) {
          const result = deferred();
          zooms.push({factor, anchorX, anchorY, imageWidth, imageHeight, ...result});
          return result.promise;
        },
      }},
    "./pin-window.css": {},
  }});
  h.window.devicePixelRatio = options.contentScale ?? 2.5;
  const component = h.mount("PinWindow", {id: "test-image"});
  component.render();
  return {component, requests, sizes, positions, zooms, drags: () => drags, closes: () => closes, raises: () => raises,
    keyboard: event => h.window.dispatchEvent({ type: "keydown", ...event }),
    reads: () => reads, pinned: () => pinned(), changed: id => changed(id)};
}

const pinButton = component => nodes(component.render()).find(node => node?.type === "button");
const pinLabel = component => pinButton(component).props["aria-label"];

test("a fresh pin keeps its builder state despite a transient false native snapshot", async () => {
  const h = pinWindow();
  await settleRequests();
  assert.equal(pinLabel(h.component), "Unpin");
  assert.equal(h.reads(), 0);
  pinButton(h.component).props.onClick();
  assert.equal(h.requests[0].value, false, "the first click must actually unpin");
  h.requests[0].resolve();
  await settleRequests();
  assert.equal(pinLabel(h.component), "Pin on Top");
});

test("a reused pin event restores the button and the next click unpins", async () => {
  const h = pinWindow();
  await settleRequests();
  pinButton(h.component).props.onClick();
  h.requests[0].resolve();
  await settleRequests();
  assert.equal(pinLabel(h.component), "Pin on Top");
  h.pinned();
  assert.equal(pinLabel(h.component), "Unpin");
  pinButton(h.component).props.onClick();
  assert.equal(h.requests[1].value, false);
});

test("a library repin wins over the completion of an older pending unpin", async () => {
  const h = pinWindow();
  await settleRequests();
  pinButton(h.component).props.onClick();
  h.pinned();
  h.requests[0].resolve();
  await settleRequests();
  assert.equal(pinLabel(h.component), "Unpin");
  pinButton(h.component).props.onClick();
  assert.equal(h.requests[1].value, false);
});

test("failed native changes keep the pin state and rapid repeated clicks make one request", async () => {
  const h = pinWindow();
  await settleRequests();
  const click = pinButton(h.component).props.onClick;
  click(); click();
  assert.equal(h.requests.length, 1);
  h.requests[0].reject(new Error("unavailable"));
  await settleRequests();
  assert.equal(pinLabel(h.component), "Unpin");
  assert.ok(nodes(h.component.render()).some(node => node?.props?.role === "alert"));
});


test("pointing at a topmost pin raises it above its sibling pins", async () => {
  const h = pinWindow();
  await settleRequests();
  h.component.render().props.onPointerDown();
  assert.equal(h.raises(), 1, "pointer down re-asserts the native topmost band");
  // Raising must not change the pin's own state; only the explicit toggle does.
  assert.equal(pinLabel(h.component), "Unpin");
});

test("a stale rejected toggle does not show an error after a successful library repin", async () => {
  const h = pinWindow();
  await settleRequests();
  pinButton(h.component).props.onClick();
  h.pinned();
  h.requests[0].reject(new Error("superseded"));
  await settleRequests();
  assert.equal(pinLabel(h.component), "Unpin");
  assert.ok(!nodes(h.component.render()).some(node => node?.props?.role === "alert"));
});

test("borderless references drag only from the image and retain accessible close controls", async () => {
  const h = pinWindow({ userAgent: "Linux" });
  const tree = nodes(h.component.render());
  const image = tree.find(node => node?.type === "main");
  image.props.onPointerDown({ button: 2 });
  assert.equal(h.drags(), 0);
  image.props.onPointerDown({ button: 0 });
  assert.equal(h.drags(), 1);
  let stopped = 0;
  tree.find(node => node?.props?.className === "pin-window__actions").props.onPointerDown({ stopPropagation: () => stopped++ });
  assert.equal(stopped, 1, "the action buttons must not start dragging");
  assert.equal(tree.find(node => node?.type === "img").props.draggable, false);
  tree.find(node => node?.props?.["aria-label"] === "Close").props.onClick();
  assert.equal(h.closes(), 1);
  h.keyboard({ key: "Escape", preventDefault() {} });
  assert.equal(h.closes(), 2);
});

test("borderless corner resize preserves aspect and coalesces pending Retina updates", async () => {
  const h = pinWindow();
  const grip = nodes(h.component.render()).find(node => node?.props?.className === "pin-window__resize");
  grip.props.onPointerDown({ button: 0, pointerId: 1, screenX: 100, screenY: 100,
    stopPropagation() {}, currentTarget: { setPointerCapture() {} } });
  grip.props.onPointerMove({ pointerId: 1, screenX: 150, screenY: 125 });
  await settleRequests();
  assert.deepEqual({ ...h.sizes[0].value }, { width: 500, height: 250 });
  grip.props.onPointerMove({ pointerId: 1, screenX: 175, screenY: 135 });
  grip.props.onPointerUp({ pointerId: 1, screenX: 200, screenY: 150 });
  assert.equal(h.sizes.length, 1, "window resize requests stay serial");
  h.sizes[0].resolve();
  await settleRequests();
  assert.equal(h.sizes.length, 2);
  assert.deepEqual({ ...h.sizes[1].value }, { width: 600, height: 300 });
  h.sizes[1].resolve();
  await settleRequests();
});

const moveEvent = (x, y, pointerId = 1) => ({ button: 0, pointerId, screenX: x, screenY: y,
  preventDefault() {}, currentTarget: { setPointerCapture() {} } });
const imageSurface = h => nodes(h.component.render()).find(node => node?.type === "main");

for (const userAgent of ["Macintosh", "Windows"]) {
test(`${userAgent} image dragging uses physical positions and coalesces movement`, async () => {
  const h = pinWindow({ userAgent });
  const image = imageSurface(h);
  image.props.onPointerDown(moveEvent(100, 100));
  image.props.onPointerMove(moveEvent(150, 125));
  await settleRequests();
  assert.equal(h.drags(), 0, "dragging must not depend on an asynchronous native mouse-down event");
  assert.deepEqual({ ...h.positions[0].value }, { x: -300, y: 150 });
  image.props.onPointerMove(moveEvent(170, 135));
  image.props.onPointerUp(moveEvent(200, 150));
  assert.equal(h.positions.length, 1, "native moves stay serial");
  h.positions[0].resolve();
  await settleRequests();
  assert.deepEqual({ ...h.positions[1].value }, { x: -200, y: 200 });
  h.positions[1].resolve();
  await settleRequests();
  image.props.onPointerMove(moveEvent(400, 400));
  assert.equal(h.positions.length, 2, "released pointers cannot move the window");
});

test(`a short ${userAgent} drag retains its last position while the native origin is loading`, async () => {
  const origin = deferred();
  const h = pinWindow({ userAgent, outerPosition: () => origin.promise });
  const image = imageSurface(h);
  image.props.onPointerDown(moveEvent(30, 40));
  image.props.onPointerMove(moveEvent(45, 50, 2));
  image.props.onPointerUp(moveEvent(60, 80));
  assert.equal(h.positions.length, 0);
  origin.resolve({ x: 20, y: 30 });
  await settleRequests();
  assert.deepEqual({ ...h.positions[0].value }, { x: 80, y: 110 });
  h.positions[0].resolve();
});

test(`cancelled and unmounted ${userAgent} drags cannot apply a late origin or pending movement`, async () => {
  for (const end of ["cancel", "unmount"]) {
    const origin = deferred();
    const h = pinWindow({ userAgent, outerPosition: () => origin.promise });
    const image = imageSurface(h);
    image.props.onPointerDown(moveEvent(100, 100));
    image.props.onPointerMove(moveEvent(200, 200));
    if (end === "cancel") image.props.onPointerCancel();
    else h.component.unmount();
    origin.resolve({ x: 20, y: 30 });
    await settleRequests();
    assert.equal(h.positions.length, 0, end);
  }
});

test(`a newer ${userAgent} drag invalidates an older delayed origin`, async () => {
  const origins = [deferred(), deferred()];
  let reads = 0;
  const h = pinWindow({ userAgent, outerPosition: () => origins[reads++].promise });
  const image = imageSurface(h);
  image.props.onPointerDown(moveEvent(10, 20));
  image.props.onPointerUp(moveEvent(200, 250));
  image.props.onPointerDown(moveEvent(300, 350));
  image.props.onPointerUp(moveEvent(320, 380));
  origins[1].resolve({ x: -400, y: 100 });
  await settleRequests();
  assert.deepEqual({ ...h.positions[0].value }, { x: -360, y: 160 });
  h.positions[0].resolve();
  origins[0].resolve({ x: -400, y: 100 });
  await settleRequests();
  assert.equal(h.positions.length, 1, "the old gesture must not jump the window back");
});
}

test("Windows drag waits for both native origin and display scale, independent of WebView content zoom", async () => {
  for (const scale of [1, 1.25, 2]) {
    const displayScale = deferred();
    const h = pinWindow({ userAgent: "Windows NT 10.0", contentScale: 2.5,
      scaleFactor: () => displayScale.promise });
    const image = imageSurface(h);
    image.props.onPointerDown(moveEvent(-20, 35));
    image.props.onPointerUp(moveEvent(15, 61));
    await settleRequests();
    assert.equal(h.positions.length, 0, "a partial native snapshot cannot move the window");
    displayScale.resolve(scale);
    await settleRequests();
    assert.deepEqual({ ...h.positions[0].value }, {
      x: Math.round(-400 + 35 * scale), y: Math.round(100 + 26 * scale),
    }, "screen-coordinate deltas use the native display scale exactly once");
    h.positions[0].resolve();
    h.component.unmount();
  }
});

test("right clicks never drag or expose the browser image menu; Linux retains native dragging", async () => {
  for (const userAgent of ["Macintosh", "Windows", "Linux"]) {
    const h = pinWindow({ userAgent });
    imageSurface(h).props.onPointerDown({ button: 2 });
    let prevented = 0;
    h.component.render().props.onContextMenu({ preventDefault: () => prevented++ });
    await settleRequests();
    assert.equal(prevented, 1, userAgent);
    assert.equal(h.positions.length, 0);
    assert.equal(h.drags(), 0);
    if (userAgent === "Linux") {
      imageSurface(h).props.onPointerDown({ button: 0 });
      assert.equal(h.drags(), 1);
    }
    h.component.unmount();
  }
});

const pinImage = h => nodes(h.component.render()).find(node => node?.type === "img");
const wheelEvent = (deltaY, { x = 200, y = 100, width = 400, height = 200, mode = 0 } = {}) =>
  ({ deltaY, deltaMode: mode, clientX: x, clientY: y,
    currentTarget: { clientWidth: width, clientHeight: height } });
const zoomHud = h => nodes(h.component.render()).find(node => node?.props?.className === "pin-window__zoom");

test("the wheel scales the pin around the pointer and shows the resulting percentage", async () => {
  const h = pinWindow();
  await settleRequests();
  pinImage(h).props.onLoad({ currentTarget: { naturalWidth: 400, naturalHeight: 200 } });
  h.component.render().props.onWheel(wheelEvent(-100));
  assert.equal(h.zooms.length, 1, "one native geometry change per wheel step");
  assert.equal(h.zooms[0].factor.toFixed(4), "1.1000", "one notch grows the pin by 10%");
  assert.equal(h.zooms[0].anchorX, 0.5, "the anchor is the pointer, not the window origin");
  assert.equal(h.zooms[0].anchorY, 0.5);
  assert.equal(h.zooms[0].imageWidth, 400, "the intrinsic size keeps the window on the image aspect");
  h.zooms[0].resolve({ width: 440, height: 220 });
  await settleRequests();
  assert.deepEqual(zoomHud(h).props.children, [110, "%"]);
  assert.equal(zoomHud(h).props.role, "status");
  assert.equal(zoomHud(h).props["data-corner"], "top-left");
  h.component.unmount();
});

test("the percentage badge stays in the quadrant under the pointer", async () => {
  const h = pinWindow();
  await settleRequests();
  pinImage(h).props.onLoad({ currentTarget: { naturalWidth: 400, naturalHeight: 200 } });
  h.component.render().props.onWheel(wheelEvent(-100, { x: 399, y: 199 }));
  h.zooms[0].resolve({ width: 440, height: 220 });
  await settleRequests();
  assert.equal(zoomHud(h).props["data-corner"], "bottom-right");
  h.component.unmount();
});

test("scrolling down zooms out around the pointer instead of the window centre", async () => {
  const h = pinWindow();
  await settleRequests();
  pinImage(h).props.onLoad({ currentTarget: { naturalWidth: 400, naturalHeight: 200 } });
  h.component.render().props.onWheel(wheelEvent(100, { x: 0, y: 0 }));
  assert.equal(h.zooms[0].factor.toFixed(4), "0.9091");
  assert.equal(h.zooms[0].anchorX, 0);
  assert.equal(h.zooms[0].anchorY, 0);
  h.zooms[0].resolve({ width: 364, height: 182 });
  await settleRequests();
  assert.deepEqual(zoomHud(h).props.children, [91, "%"]);
  h.component.unmount();
});

test("a wheel burst keeps one native resize in flight and adds the rest up", async () => {
  const h = pinWindow();
  await settleRequests();
  pinImage(h).props.onLoad({ currentTarget: { naturalWidth: 400, naturalHeight: 200 } });
  h.component.render().props.onWheel(wheelEvent(-100));
  h.component.render().props.onWheel(wheelEvent(-100));
  h.component.render().props.onWheel(wheelEvent(-100));
  assert.equal(h.zooms.length, 1, "window resizes stay serial");
  h.zooms[0].resolve({ width: 440, height: 220 });
  await settleRequests();
  assert.equal(h.zooms.length, 2);
  assert.equal(h.zooms[1].factor.toFixed(4), "1.2100", "queued notches apply as one step");
  h.zooms[1].resolve({ width: 532, height: 266 });
  await settleRequests();
  assert.deepEqual(zoomHud(h).props.children, [133, "%"]);
  h.component.unmount();
});

test("zooming waits until a drag gesture releases the window frame", async () => {
  const h = pinWindow();
  await settleRequests();
  const image = imageSurface(h);
  image.props.onPointerDown(moveEvent(100, 100));
  image.props.onPointerMove(moveEvent(120, 110));
  h.component.render().props.onWheel(wheelEvent(-100));
  assert.equal(h.zooms.length, 0, "a drag owns the coordinates it captured");
  image.props.onPointerUp(moveEvent(140, 120));
  await settleRequests();
  h.positions.forEach(position => position.resolve());
  await settleRequests();
  h.component.render().props.onWheel(wheelEvent(-100));
  assert.equal(h.zooms.length, 1);
  h.component.unmount();
});

test("a drag started during a wheel burst drops the queued zoom step", async () => {
  const h = pinWindow();
  await settleRequests();
  const image = imageSurface(h);
  h.component.render().props.onWheel(wheelEvent(-100));
  h.component.render().props.onWheel(wheelEvent(-100));
  assert.equal(h.zooms.length, 1);
  image.props.onPointerDown(moveEvent(100, 100));
  h.zooms[0].resolve({ width: 440, height: 220 });
  await settleRequests();
  assert.equal(h.zooms.length, 1, "a queued step cannot move the grabbed window");
  h.component.unmount();
});

test("zooming waits until a corner resize releases the window frame", async () => {
  const h = pinWindow();
  await settleRequests();
  const grip = nodes(h.component.render()).find(node => node?.props?.className === "pin-window__resize");
  grip.props.onPointerDown({ button: 0, pointerId: 1, screenX: 100, screenY: 100,
    stopPropagation() {}, currentTarget: { setPointerCapture() {} } });
  h.component.render().props.onWheel(wheelEvent(-100));
  assert.equal(h.zooms.length, 0);
  grip.props.onPointerUp({ pointerId: 1, screenX: 120, screenY: 110 });
  await settleRequests();
  h.sizes.forEach(size => size.resolve());
  await settleRequests();
  h.component.render().props.onWheel(wheelEvent(-100));
  assert.equal(h.zooms.length, 1);
  h.component.unmount();
});

test("the opening size is the zoom reference until the image reports its pixels", async () => {
  const h = pinWindow();
  await settleRequests();
  h.component.render().props.onWheel(wheelEvent(-100));
  h.zooms[0].resolve({ width: 500, height: 250 });
  await settleRequests();
  assert.deepEqual(zoomHud(h).props.children, [125, "%"]);
  h.component.unmount();
});

test("a failed zoom hides the percentage and leaves the next wheel usable", async () => {
  const h = pinWindow();
  await settleRequests();
  h.component.render().props.onWheel(wheelEvent(-100));
  h.zooms[0].reject(new Error("unavailable"));
  await settleRequests();
  assert.equal(zoomHud(h), undefined);
  h.component.render().props.onWheel(wheelEvent(-100));
  assert.equal(h.zooms.length, 2, "the queue does not wedge on a failure");
  h.zooms[1].resolve({ width: 484, height: 242 });
  await settleRequests();
  h.component.unmount();
});

test("saved image revisions refresh only their pin and recover an image load failure", async () => {
  const h = pinWindow();
  await settleRequests();
  const img = () => nodes(h.component.render()).find(node => node?.type === "img");
  assert.equal(img().props.src, "image:test?v=0");
  h.changed("another-image");
  assert.equal(img().props.src, "image:test?v=0");
  img().props.onError();
  assert.equal(img(), undefined);
  h.changed("test-image");
  assert.equal(img().props.src, "image:test?v=1");
});

const overlaySource = readFileSync(new URL("../src/windows/OverlayWindow.tsx", import.meta.url), "utf8");

function captureCompletion() {
  const tree = ts.createSourceFile("overlay.tsx", overlaySource, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
  let callback;
  const walk = node => {
    if (ts.isVariableDeclaration(node) && node.name.getText(tree) === "complete") {
      callback = node.initializer.arguments[0].getText(tree);
    }
    ts.forEachChild(node, walk);
  };
  walk(tree);
  assert.ok(callback);
  const output = ts.transpileModule(`const complete = ${callback};`, {}).outputText;
  const exported = deferred(), confirmed = deferred(), calls = [], handoffs = [], errors = [];
  const result = { png: new Uint8Array([1, 2, 3]), document: { marks: [{ kind: "text" }] } };
  const selection = { x: 10, y: 20, width: 100, height: 80 };
  // These mirror the module-level constants and helper the extracted callback
  // closes over; `new Function` has no module scope to read them from.
  const settleWithin = (work, ms) => Promise.race([
    work,
    new Promise(resolve => { setTimeout(() => resolve(undefined), ms); }),
  ]);
  const busyMessage = "The previous capture is still completing.";
  const context = {
    completionLock: new AnnotationInteractionLock(), modeSelectorDragRef: { current: null },
    setModeSelectorDragging: () => {}, setCompleting: () => {}, setCommitting: () => {},
    setPinning: value => handoffs.push(value),
    setAnnotationError: message => { if (message) errors.push(message); },
    confirmedRef: { current: false }, setConfirmed: () => {},
    closeConfirmedOverlay: async () => { calls.push("close"); return true; },
    selection,
    settleWithin, CONFIRM_BUSY_MESSAGE: busyMessage,
    CONFIRM_BUSY_RETRY_DELAY_MS: 0, CONFIRM_BUSY_MAX_ATTEMPTS: 3,
    EXPORT_RESULT_TIMEOUT_MS: 400, CONFIRM_CAPTURE_TIMEOUT_MS: 400,
    lostCaptureSession: message => message.includes("This command is only available from the active capture overlay.")
      || message.includes("only available to its overlay")
      || message.includes("No active capture session"),
    canvasRef: { current: { exportResult: () => { calls.push("export"); return exported.promise; },
      commitTextEditing: () => true, cancelTextEditing: () => {} } },
    api: { confirmCapture: (...args) => { calls.push(args); return confirmed.promise; } },
    getCurrentWindow: () => ({ close: async () => { calls.push("close"); },
      setIgnoreCursorEvents: async () => {} }),
    afterPaint: async () => { calls.push("paint"); },
    reportFrontend: message => calls.push(message),
  };
  const complete = new Function(...Object.keys(context), `${output}; return complete;`)(...Object.values(context));
  return { complete, exported, confirmed, calls, handoffs, errors, result, selection, lock: context.completionLock };
}

test("direct pin exports annotations once and waits for confirmation before closing", async () => {
  const h = captureCompletion();
  const steps = () => h.calls.filter(call => call === "export" || call === "close" || Array.isArray(call));
  const pending = h.complete(true);
  await h.complete();
  assert.ok(h.calls.includes("complete: a previous completion is still in flight"),
    "a click the lock ignores is reported instead of silently dropped");
  await settleRequests();
  assert.deepEqual(steps(), ["export"], "Done cannot race a pending pin export");
  h.exported.resolve(h.result);
  await settleRequests();
  assert.deepEqual(steps()[1], [h.result.png, { selection: h.selection, document: h.result.document }, true]);
  await h.complete(true);
  assert.equal(steps().length, 2, "a second pin cannot race native confirmation");
  assert.equal(h.lock.locked, true);
  h.confirmed.resolve();
  await pending;
  assert.equal(steps()[2], "close");
  assert.equal(h.lock.locked, false);
});

test("failed pin confirmation keeps the overlay open and releases completion for retry", async () => {
  const h = captureCompletion();
  const pending = h.complete(true);
  h.exported.resolve(h.result);
  await settleRequests();
  h.confirmed.reject(new Error("save failed"));
  await pending;
  assert.ok(!h.calls.includes("close"));
  assert.equal(h.lock.locked, false);
  assert.match(h.calls.at(-1), /save failed/);
});

test("normal completion retains its non-pinning action", async () => {
  const h = captureCompletion();
  const pending = h.complete();
  h.exported.resolve(h.result);
  h.confirmed.resolve();
  await pending;
  assert.equal(h.calls[1][2], false);
  assert.equal(h.calls[2], "close");
  assert.deepEqual(h.handoffs, [], "Done does not hide the editor before exporting");
});

test("a pin click takes the editing HUD off screen before the pixels are exported", async () => {
  const h = captureCompletion();
  const pending = h.complete(true);
  assert.deepEqual(h.handoffs, [true], "the click itself must hide the toolbar");
  assert.deepEqual(h.calls, ["paint"], "the export waits for the hidden HUD to paint");
  await settleRequests();
  assert.deepEqual(h.calls, ["paint", "export"], "hiding happens before the export starts");
  h.exported.resolve(h.result);
  await settleRequests();
  h.confirmed.resolve();
  await pending;
  assert.deepEqual(h.handoffs, [true], "a pinned capture never brings the editor back");
  assert.equal(h.calls[3], "close");
});

test("a pin click that cannot export returns the editor with an error", async () => {
  const h = captureCompletion();
  const pending = h.complete(true);
  h.exported.resolve(null);
  await pending;
  assert.deepEqual(h.handoffs, [true, false], "the handoff is released for a retry");
  assert.ok(!h.calls.includes("close"));
  assert.match(h.errors.at(-1), /Could not finish this screenshot/);
});

test("the toolbar exposes direct pin, disables it while completing, and isolates keyboard activation", () => {
  const toolbar = overlaySource.slice(overlaySource.indexOf("const TOOLS:"));
  const harness = createLibraryHarness({}, `import React,{useState,useRef,useEffect,useLayoutEffect} from "react";
    import {t} from "../i18n"; import {KiriIcon} from "../components/KiriIcons";
    import {AnnotationToolbarButton} from "../components/AnnotationToolbarButton";
    const captureToolbarPosition=${captureToolbarPosition.toString()}, capturePanelLayout=${capturePanelLayout.toString()}, captureToolOptionsLayout=${captureToolOptionsLayout.toString()}; ${toolbar}; export {ToolButton};`);
  let pins = 0, saves = 0;
  const props = { selection:{x:100,y:100,width:140,height:160}, bounds:{x:0,y:0,width:800,height:600},
    tool:"select", appearance:{}, canSetSize:true, disabled:false,
    onPin:()=>pins++, onDone:()=>saves++ };
  const component = harness.mount("Toolbar", props);
  const pin = nodes(component.render()).find(node => node?.props?.icon === "pin");
  assert.ok(pin);
  pin.props.onClick();
  assert.equal(pins, 1);
  assert.equal(saves, 0);
  const button = nodes(harness.mount("ToolButton", pin.props).render()).find(node => node?.type === "button");
  let stopped = 0;
  button.props.onKeyDown({ key:"Enter", stopPropagation:()=>stopped++ });
  assert.equal(stopped, 1, "Enter on Pin must not bubble into normal screenshot completion");
  const busy = nodes(component.render({ ...props, disabled:true }));
  assert.equal(busy.find(node => node?.props?.icon === "pin").props.disabled, true);
  assert.equal(busy.find(node => node?.props?.icon === "checkmark").props.disabled, true);
  component.unmount();
});

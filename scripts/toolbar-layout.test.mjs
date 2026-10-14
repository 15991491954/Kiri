import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { capturePanelLayout, captureToolbarPosition, recordingPanelLayout } from "../src/windows/toolbar-layout.js";
import { createLibraryHarness, nodes } from "./helpers/library-render-harness.mjs";

const overlaps = (position, size, rect) => position.left < rect.x + rect.width &&
  position.left + size.width > rect.x && position.top < rect.y + rect.height &&
  position.top + size.height > rect.y;

test("800×600 bottom-right region leaves a measured wrapped toolbar above the selection", () => {
  const selection = { x: 650, y: 420, width: 140, height: 160 };
  const size = { width: 784, height: 81 };
  const position = captureToolbarPosition(selection, { x: 0, y: 0, width: 800, height: 600 }, size);
  assert.deepEqual(position, { left: 8, top: 329 });
  assert.equal(position.top + size.height, selection.y - 10);
});

test("wide displays retain the centered row below the selection", () => {
  assert.deepEqual(captureToolbarPosition(
    { x: 500, y: 200, width: 500, height: 150 },
    { x: 0, y: 0, width: 1512, height: 982 },
    { width: 810, height: 48 },
  ), { left: 345, top: 360 });
});

test("all corners remain inside logical viewport bounds after height changes", () => {
  for (const [width, height] of [[640, 480], [800, 600], [1512, 982]]) {
    for (const toolbarHeight of [48, 81, 116]) {
      for (const x of [0, width - 140]) for (const y of [0, height - 160]) {
        const size = { width: Math.min(810, width - 16), height: toolbarHeight };
        const p = captureToolbarPosition({ x, y, width: 140, height: 160 }, { x: 0, y: 0, width, height }, size);
        assert.ok(p.left >= 8 && p.left + size.width <= width - 8);
        assert.ok(p.top >= 8 && p.top + size.height <= height - 8);
      }
    }
  }
});

test("nonzero bounds and constrained height do not force the toolbar off screen", () => {
  const bounds = { x: -800, y: -200, width: 800, height: 180 };
  const size = { width: 784, height: 116 };
  assert.deepEqual(captureToolbarPosition(
    { x: -150, y: -100, width: 140, height: 70 }, bounds, size,
  ), { left: -792, top: -144 });
});

test("a tall settings stack near the top stays inside the selection when neither outside edge fits", () => {
  const selection = { x: 80, y: 150, width: 1040, height: 620 };
  const bounds = { x: 0, y: 0, width: 1200, height: 800 };
  const mode = { x: 445, y: 44, width: 310, height: 44 };
  for (const height of [94, 130, 230]) {
    const size = { width: 550, height };
    const position = captureToolbarPosition(selection, bounds, size, false, mode);
    assert.ok(position.top >= selection.y + 10);
    assert.ok(position.top + size.height <= selection.y + selection.height - 10);
    assert.ok(!overlaps(position, size, mode));
  }
});

test("a mode selector only reserves its actual area, leaving clear room above a selection", () => {
  const selection = { x: 680, y: 155, width: 400, height: 620 };
  const size = { width: 420, height: 96 };
  const mode = { x: 280, y: 44, width: 310, height: 44 };
  const position = captureToolbarPosition(selection, { x: 0, y: 0, width: 1200, height: 800 }, size, false, mode);
  assert.deepEqual(position, { left: 670, top: 49 });
  assert.equal(position.top + size.height + 10, selection.y);
  assert.ok(!overlaps(position, size, mode));
});

test("a wrapped mode selector reserves both rows without trapping a compact toolbar", () => {
  const bounds = { x: 0, y: 0, width: 320, height: 480 };
  const selection = { x: 20, y: 130, width: 280, height: 330 };
  const mode = { x: 8, y: 44, width: 304, height: 80 };
  for (const height of [81, 160, 210]) {
    const size = { width: 304, height };
    const position = captureToolbarPosition(selection, bounds, size, false, mode);
    assert.ok(position.left >= 8 && position.left + size.width <= 312);
    assert.ok(position.top >= 8 && position.top + size.height <= 472);
    assert.ok(!overlaps(position, size, mode), "the selector's second row must also stay clear");
  }
});

test("narrow full-height selections use free side space before covering the canvas", () => {
  const selection = { x: 80, y: 0, width: 130, height: 800 };
  const size = { width: 550, height: 140 };
  const mode = { x: 445, y: 44, width: 310, height: 44 };
  const position = captureToolbarPosition(selection, { x: 0, y: 0, width: 1200, height: 800 }, size, false, mode);
  assert.deepEqual(position, { left: 220, top: 330 });
  assert.ok(!overlaps(position, size, selection));
  assert.ok(!overlaps(position, size, mode));
});

test("full-display and corner selections keep two and three rows clear of a moved mode selector", () => {
  for (const [width, height] of [[480, 640], [800, 600], [1512, 982]]) {
    const bounds = { x: 0, y: 0, width, height };
    for (const mode of [
      { x: width / 2 - 150, y: 44, width: 300, height: 44 },
      { x: 8, y: height - 70, width: 300, height: 44 },
    ]) for (const toolbarHeight of [94, 130, 230]) {
      const size = { width: Math.min(550, width - 16), height: toolbarHeight };
      for (const selection of [bounds,
        { x: 0, y: 0, width: 100, height: 160 },
        { x: width - 100, y: 0, width: 100, height: 160 },
        { x: 0, y: height - 160, width: 100, height: 160 },
        { x: width - 100, y: height - 160, width: 100, height: 160 },
      ]) {
        const position = captureToolbarPosition(selection, bounds, size, false, mode);
        assert.ok(position.left >= 8 && position.left + size.width <= width - 8);
        assert.ok(position.top >= 8 && position.top + size.height <= height - 8);
        assert.ok(!overlaps(position, size, mode));
      }
    }
  }
});

test("only visible HUD rows receive pointer input, with measurement updated when settings grow", () => {
  const source = readFileSync(new URL("../src/windows/OverlayWindow.tsx", import.meta.url), "utf8");
  // Compile the real tool definitions and both toolbar rows, including all
  // three direct text tools; no empty TOOLS shortcut hides wrap groups.
  const toolbar = source.slice(source.indexOf("const TOOLS:"));
  const css = readFileSync(new URL("../src/styles/design-system.css", import.meta.url), "utf8");
  const optionsCss = css.match(/\.kiri-capture-tool-options\s*\{([^}]+)\}/)?.[1];
  assert.ok(optionsCss, "the property HUD has an explicit input and width boundary");
  const optionsStyle = Object.fromEntries(optionsCss.split(";").filter(value => value.trim()).map(value => {
    const index = value.indexOf(":"); return [value.slice(0, index).trim(), value.slice(index + 1).trim()];
  }));
  let height = 48;
  const measured = { get offsetWidth() { return 550; }, get offsetHeight() { return height; } };
  const harness = createLibraryHarness({}, `import React,{useState,useRef,useEffect,useLayoutEffect} from "react";
    import {t} from "../i18n"; import {KiriIcon} from "../components/KiriIcons";
    const captureToolbarPosition=${captureToolbarPosition.toString()}, capturePanelLayout=${capturePanelLayout.toString()}; ${toolbar}`, {
    attachRef(node) {
      if (node.props.className === "kiri-capture-toolbar") node.props.ref.current = measured;
      if (node.props.className?.includes("kiri-annotation-tool-row")) node.props.ref.current = {offsetHeight: 48};
    },
    globals: { ResizeObserver: class { observe() {} disconnect() {} } },
  });
  const props = { selection: { x: 80, y: 150, width: 1040, height: 620 },
    bounds: { x: 0, y: 0, width: 1200, height: 800 }, modeSelectorBounds: { x: 445, y: 44, width: 310, height: 44 },
    tool: "select", appearance: {}, canSetSize: false, disabled: false };
  const component = harness.mount("Toolbar", props);
  let tree = component.render();
  let root = nodes(tree).find(node => node?.props?.className === "kiri-capture-toolbar");
  assert.equal(root.props.style.pointerEvents, "none");
  assert.ok(root.props.style.zIndex > 5, "selection keylines must not paint over controls");
  height = 230;
  tree = component.render({ ...props, selectedMark: {kind: "callout", id: 1}, styleControls: "callout-controls" });
  root = nodes(tree).find(node => node?.props?.className === "kiri-capture-toolbar");
  assert.ok(root.props.style.top >= props.selection.y + 10);
  assert.ok(root.props.style.top + height <= props.selection.y + props.selection.height - 10);
  assert.ok(!overlaps(root.props.style, {width: 550, height}, props.modeSelectorBounds), "the complete settings stack remains clear of the mode selector");
  const hud = nodes(tree).find(node => node?.props?.className?.includes("kiri-annotation-tool-row"));
  assert.equal(hud.props.style.pointerEvents, "auto");
  const settings = nodes(tree).find(node => node?.props?.children?.includes("callout-controls"));
  assert.equal(settings.props.className, "kiri-hud kiri-capture-tool-options");
  assert.equal(optionsStyle["pointer-events"], "auto", "only the visible property HUD receives input");
  assert.equal(optionsStyle.width, "100%", "the property HUD remains within the measured toolbar width");
  assert.ok(settings.props.style.maxHeight > 0);
  height = 130;
  tree = component.render({ ...props, selectedMark: {kind: "text", id: 2, labelDirection: "left"}, styleControls: "label-controls" });
  root = nodes(tree).find(node => node?.props?.className === "kiri-capture-toolbar");
  assert.equal(root.props.style.pointerEvents, "none", "a selected label must keep blank toolbar space pass-through");
  const labelSettings = nodes(tree).find(node => node?.props?.children?.includes("label-controls"));
  assert.ok(labelSettings, "selecting an existing label opens its settings");
  assert.equal(labelSettings.props.className, "kiri-hud kiri-capture-tool-options");
  assert.equal(optionsStyle["pointer-events"], "auto", "label color and font controls remain interactive");
  assert.equal(root.props.style.maxWidth, props.bounds.width - 16);
  assert.ok(root.props.style.top >= props.selection.y + 10);
  assert.ok(root.props.style.top + height <= props.selection.y + props.selection.height - 10);
  assert.ok(!overlaps(root.props.style, {width: 550, height}, props.modeSelectorBounds));
  assert.ok(!nodes(tree).some(node => node?.props?.children?.includes("callout-controls")), "changing to a label must remove stale callout settings");
  tree = component.render({...props, selectedMark: null, styleControls: "empty-select-options"});
  assert.ok(!nodes(tree).some(node => node?.props?.children?.includes("empty-select-options")), "clearing selection closes inactive Select settings");
  root = nodes(tree).find(node => node?.props?.className === "kiri-capture-toolbar");
  assert.equal(root.props.style.pointerEvents, "none");
  component.unmount();
});

test("legacy outside-panel layout keeps its actions clear of the mode selector", () => {
  const selection = { x: 300, y: 10, width: 680, height: 380 };
  const bounds = { x: 0, y: 0, width: 1280, height: 800 };
  const mode = { x: 492, y: 44, width: 296, height: 44 };
  const natural = { width: 360, height: 460 };
  const layout = capturePanelLayout(selection, bounds, natural, mode);
  assert.equal(layout.top, 400);
  assert.equal(layout.maxHeight, 392);
  assert.ok(!overlaps(layout, { width: layout.width, height: layout.maxHeight }, mode));
  assert.ok(layout.top + layout.maxHeight <= 792, "scrolling content must leave Start/Cancel on screen");
  const mp4 = { left: layout.left + 18, top: layout.top + 56 };
  assert.ok(!overlaps(mp4, { width: 158, height: 32 }, mode), "MP4 must not click the Screenshot selector");
});

test("scrollable OCR panels stay clear of wrapped and dragged modes at every edge", () => {
  for (const [width, height] of [[320, 480], [480, 640], [1280, 800]]) {
    const bounds = { x: 0, y: 0, width, height };
    const modeWidth = Math.min(304, width - 16), modeHeight = width === 320 ? 80 : 44;
    for (const mode of [
      { x: (width - modeWidth) / 2, y: 44, width: modeWidth, height: modeHeight },
      { x: 8, y: height / 2 - modeHeight / 2, width: modeWidth, height: modeHeight },
      { x: width - modeWidth - 8, y: height - modeHeight - 8, width: modeWidth, height: modeHeight },
    ]) for (const selection of [bounds,
      { x: 0, y: 0, width: 100, height: 120 },
      { x: width - 100, y: height - 120, width: 100, height: 120 },
    ]) for (const natural of [{ width: 360, height: 460 }, { width: 368, height: 204 }, { width: 440, height: 740 }]) {
      const p = capturePanelLayout(selection, bounds, natural, mode);
      const size = { width: p.width, height: Math.min(natural.height, p.maxHeight) };
      assert.ok(p.left >= 8 && p.left + size.width <= width - 8);
      assert.ok(p.top >= 8 && p.top + size.height <= height - 8);
      assert.ok(!overlaps(p, size, mode), JSON.stringify({ bounds, mode, selection, natural, p }));
      assert.ok(p.maxHeight >= 160, "constrained content must still leave a usable reading area and actions");
    }
  }
});

function recordingSetup() {
  const source = readFileSync(new URL("../src/windows/OverlayWindow.tsx", import.meta.url), "utf8");
  const panel = source.slice(source.indexOf("export function RecordOptionsPanel("), source.indexOf("interface ToolbarProps"));
  const clamp = source.slice(source.indexOf("function clampFloatingControl("), source.indexOf("// --- window hover candidate"));
  let naturalHeight = 184, style, changes = [], starts = 0, cancels = 0;
  const measured = {
    getBoundingClientRect() { return { height: Math.min(naturalHeight, style.maxHeight) }; },
    get clientHeight() { return Math.min(naturalHeight, style.maxHeight); },
    get scrollHeight() { return style.maxHeight < 168 ? naturalHeight : this.clientHeight; },
  };
  const scroll = { get scrollHeight() { return naturalHeight - 64; },
    get clientHeight() { return style.maxHeight < 168 ? naturalHeight - 64 : Math.max(0, Math.min(naturalHeight, style.maxHeight) - 64); }, firstElementChild: {} };
  const harness = createLibraryHarness({}, `import React,{useState,useRef,useEffect,useLayoutEffect} from "react";
    import {t} from "../i18n"; import {KiriIcon} from "../components/KiriIcons";
    const Mic="mic", Volume2="volume", MousePointer2="pointer", MousePointerClick="clicks", RecordingMicrophoneSelect="mic-select";
    const FLOATING_CONTROL_MARGIN=8,minX=r=>r.x,minY=r=>r.y,maxX=r=>r.x+r.width,maxY=r=>r.y+r.height;
    ${clamp} const recordingPanelLayout=${recordingPanelLayout.toString()}; ${panel}; export {RecordInput};`, {
    attachRef(node) {
      if (node.props.ref && node.props.className === "kiri-record-options") { style = node.props.style; node.props.ref.current = measured; }
      if (node.props.ref && node.props.className === "kiri-record-options__scroll") node.props.ref.current = scroll;
    },
    globals: { ResizeObserver: class { observe() {} disconnect() {} } },
  });
  const props = { anchor: { x: 100, y: 140, width: 600, height: 350 }, bounds: { x: 0, y: 0, width: 1280, height: 800 },
    modeSelectorBounds: { x: 492, y: 44, width: 296, height: 44 }, options: { outputFormat: "mp4", usesCountdown: true,
      capturesSystemAudio: true, capturesMicrophone: false, showsCursor: true, highlightsClicks: true }, sizeControlsOpen: false,
    systemAudioSupported: true, micSupported: true, clickHighlightsSupported: true, trayRecordingControls: false,
    onChange: value => changes.push(value), onStart: () => starts++, onCancel: () => cancels++, onToggleSize() {} };
  const component = harness.mount("RecordOptionsPanel", props);
  return { component, props, harness, changes, counts: () => ({ starts, cancels }),
    height(value) { naturalHeight = value; } };
}

const recordingRoot = tree => nodes(tree).find(node => node?.props?.className === "kiri-record-options");
const setupPointer = (x, y, button = false, header = true) => ({ button: 0, pointerId: 1, clientX: x, clientY: y,
  target: { closest: selector => selector === ".kiri-record-options__header" ? header : button }, currentTarget: { setPointerCapture() {} }, preventDefault() {}, stopPropagation() {} });

test("recording setup centers inside a roomy selection and below a small selection", () => {
  const bounds = { x: 0, y: 0, width: 1200, height: 800 };
  const size = { width: 336, height: 184 };
  assert.deepEqual(recordingPanelLayout({ x: 100, y: 140, width: 600, height: 350 }, bounds, size),
    { left: 232, top: 223, width: 336, maxHeight: 784 });
  const small = recordingPanelLayout({ x: 100, y: 140, width: 280, height: 94 }, bounds, size);
  assert.equal(small.left, 72); assert.equal(small.top, 246);
  const bottom = recordingPanelLayout({ x: 850, y: 690, width: 280, height: 94 }, bounds, size);
  assert.equal(bottom.top, 494); assert.ok(bottom.left + bottom.width <= 1192);
  const side = recordingPanelLayout({ x: 20, y: 0, width: 90, height: 800 }, bounds, size);
  assert.equal(side.left, 122); assert.equal(side.top, 308);
});

test("recording setup keeps resized dimensions controls clear above and beside small selections", () => {
  const p = recordingPanelLayout({ x: 400, y: 450, width: 180, height: 130 },
    { x: 0, y: 0, width: 800, height: 600 }, { width: 336, height: 300 }, null, true);
  assert.equal(p.top, 100);
  assert.ok(p.top + 300 <= 412, "the width field at y=412 remains reachable");
  const side = recordingPanelLayout({ x: 20, y: 0, width: 90, height: 800 },
    { x: 0, y: 0, width: 1200, height: 800 }, { width: 336, height: 184 }, null, true);
  assert.equal(side.left, 190, "right side placement clears the height field");
});

test("recording setup edges stay on screen and clear wrapped/moved mode selectors", () => {
  for (const [width, height] of [[320, 480], [800, 600], [1512, 982]]) {
    const bounds = { x: 0, y: 0, width, height };
    const mode = { x: 8, y: 44, width: Math.min(304, width - 16), height: width === 320 ? 80 : 44 };
    for (const selection of [bounds, { x: 0, y: 0, width: 100, height: 90 },
      { x: width - 100, y: height - 90, width: 100, height: 90 }]) {
      for (const panelHeight of [184, 400, 800]) {
        const p = recordingPanelLayout(selection, bounds, { width: 336, height: panelHeight }, mode);
        const size = { width: p.width, height: Math.min(panelHeight, p.maxHeight) };
        assert.ok(p.left >= 8 && p.left + size.width <= width - 8);
        assert.ok(p.top >= 8 && p.top + size.height <= height - 8);
        assert.ok(!overlaps(p, size, mode), JSON.stringify({ p, size, mode, selection }));
      }
    }
  }
});

test("recording setup stays still during selection gestures and always follows its selection", () => {
  const h = recordingSetup();
  let root = recordingRoot(h.component.render());
  const start = root.props.style;
  root = recordingRoot(h.component.render({ ...h.props, selectionAdjusting: true,
    anchor: { x: 600, y: 450, width: 180, height: 100 } }));
  assert.equal(root.props.style.left, start.left); assert.equal(root.props.style.top, start.top);
  assert.equal(root.props["data-adjusting"], true);
  root = recordingRoot(h.component.render({ ...h.props, anchor: { x: 600, y: 450, width: 180, height: 100 } }));
  assert.equal(root.props.style.top, 562);
  const automaticPosition = root.props.style;
  root.props.onPointerDown(setupPointer(700, 570));
  root.props.onPointerMove(setupPointer(4000, 4000));
  root.props.onPointerUp(setupPointer(4000, 4000));
  root = recordingRoot(h.component.render());
  assert.deepEqual(root.props.style, automaticPosition, "panel does not support manual dragging");
  h.component.unmount();
  const fresh = recordingSetup();
  root = recordingRoot(fresh.component.render());
  assert.equal(root.props.style.left, 210); assert.equal(root.props.style.top, 223);
  fresh.component.unmount();
});

test("recording setup keeps four direct controls without a second settings panel", () => {
  const h = recordingSetup();
  let tree = h.component.render();
  const header = nodes(tree).find(node => node?.props?.className === "kiri-record-options__header");
  const start = nodes(header).find(node => node?.props?.className === "kiri-record-options__start");
  start.props.onClick(); assert.equal(h.counts().starts, 1);
  assert.deepEqual(nodes(tree).filter(node => node?.props?.onToggle).map(node => node.props.label),
    ["System audio", "Microphone", "Pointer", "Click highlight"]);
  assert.ok(!nodes(tree).some(node => node?.props?.["aria-label"] === "More Actions"));
  assert.ok(!nodes(tree).some(node => node?.props?.label === "3-second countdown"));
  const microphone = nodes(tree).find(node => node?.props?.label === "Microphone");
  assert.ok(microphone.props.accessory, "microphone selection is beside its control");
  h.height(240);
  tree = h.component.render({ ...h.props, bounds: { x: 0, y: 0, width: 320, height: 480 },
    anchor: { x: 0, y: 0, width: 320, height: 480 }, modeSelectorBounds: { x: 8, y: 44, width: 304, height: 80 } });
  const root = recordingRoot(tree);
  assert.equal(root.props.style.width, 304);
  assert.ok(root.props.style.top >= 136);
  assert.ok(root.props.style.top + Math.min(240, root.props.style.maxHeight) <= 472);
  h.component.unmount();
});

test("very short available space scrolls the whole setup without losing its natural height", () => {
  const h = recordingSetup();
  h.height(300);
  const root = recordingRoot(h.component.render({ ...h.props,
    bounds: { x: 0, y: 0, width: 480, height: 320 },
    anchor: { x: 0, y: 0, width: 480, height: 320 },
    modeSelectorBounds: { x: 88, y: 138, width: 304, height: 44 },
  }));
  assert.equal(root.props.style.maxHeight, 118);
  assert.equal(root.props["data-constrained"], true);
  const expanded = recordingRoot(h.component.render(h.props));
  assert.equal(expanded.props["data-constrained"], undefined);
  assert.equal(expanded.props.style.top, 165, "restored space centers the full 300px panel, not the clipped 118px viewport");
  h.component.unmount();
});

test("format and device controls preserve silent GIF, platform limits, and pointer-highlight dependency", () => {
  const h = recordingSetup();
  let tree = h.component.render();
  const pointer = nodes(tree).find(node => node?.props?.label === "Pointer");
  pointer.props.onToggle();
  assert.equal(h.changes[0].showsCursor, false); assert.equal(h.changes[0].highlightsClicks, false);
  const gif = nodes(tree).find(node => node?.props?.className === "kiri-record-options__format" && node.props.children.includes("GIF"));
  gif.props.onClick(); assert.equal(h.changes[1].outputFormat, "gif");
  tree = h.component.render({ ...h.props, options: { ...h.props.options, outputFormat: "gif" } });
  assert.equal(nodes(tree).find(node => node?.props?.label === "System audio").props.disabled, true);
  assert.equal(nodes(tree).find(node => node?.props?.label === "Microphone").props.disabled, true);
  tree = h.component.render({ ...h.props, systemAudioSupported: false, micSupported: false });
  for (const label of ["System audio", "Microphone"]) {
    const input = nodes(tree).find(node => node?.props?.label === label);
    assert.equal(input.props.disabled, true); assert.equal(input.props.title, "Unavailable on this platform");
  }
  tree = h.component.render({ ...h.props, clickHighlightsSupported: false });
  assert.equal(nodes(tree).find(node => node?.props?.label === "Click highlight").props.disabled, true);
  tree = h.component.render({ ...h.props, options: { ...h.props.options, showsCursor: false } });
  const highlight = nodes(tree).find(node => node?.props?.label === "Click highlight");
  assert.equal(highlight.props.disabled, true); assert.equal(highlight.props.checked, false);
  const root = recordingRoot(tree), previous = root.props.style;
  root.props.onPointerDown(setupPointer(200, 200, true));
  root.props.onPointerMove(setupPointer(600, 600));
  assert.deepEqual(recordingRoot(h.component.render()).props.style, previous, "control clicks cannot drag the panel");
  root.props.onPointerDown(setupPointer(200, 200, false, false));
  root.props.onPointerMove(setupPointer(600, 600));
  assert.deepEqual(recordingRoot(h.component.render()).props.style, previous, "scrollable settings remain available to touch scrolling");
  h.component.unmount();
});

test("remote OCR measures wrapped content without hiding the mode selector or sending on layout changes", () => {
  const source = readFileSync(new URL("../src/ocr/RemoteOcrConsent.tsx", import.meta.url), "utf8");
  const panel = source.slice(source.indexOf("export function RemoteOcrConsent("));
  let naturalHeight = 600, style, sends = 0, local = 0;
  const measured = { children: [], getBoundingClientRect() { return { height: Math.min(naturalHeight, style.maxHeight) }; },
    get scrollHeight() { return naturalHeight - 2; }, get clientHeight() { return Math.min(naturalHeight, style.maxHeight) - 2; } };
  const harness = createLibraryHarness({}, `import React,{useState,useRef,useEffect,useLayoutEffect} from "react";
    import {t,fmt} from "../i18n"; import {KiriIcon} from "../components/KiriIcons";
    const useDialogFocusTrap=()=>useRef(null), ocrProviderLabel=value=>value,
      captureToolbarPosition=${captureToolbarPosition.toString()}, capturePanelLayout=${capturePanelLayout.toString()}; ${panel}`, {
    attachRef(node) {
      if (node.props.ref && node.props.className === "kiri-hud kiri-remote-consent") { style=node.props.style; node.props.ref.current=measured; }
    },
    globals: { ResizeObserver: class { observe() {} disconnect() {} } },
  });
  const props = { anchor: { x: 0, y: 0, width: 320, height: 480 }, bounds: { x: 0, y: 0, width: 320, height: 480 },
    modeSelectorBounds: { x: 8, y: 44, width: 304, height: 80 },
    prepared: { profile: { name: "A long profile", provider: "openai", origin: "https://fixture.invalid", model: "OCR" },
      imageWidth: 320, imageHeight: 480, byteLength: 2048 }, failed: false,
    onSend: () => sends++, onUseLocal: () => local++, onCancel() {} };
  const component = harness.mount("RemoteOcrConsent", props);
  let tree = component.render();
  let root = nodes(tree).find(node => node?.props?.role === "dialog");
  assert.equal(root.props.style.width, 304);
  assert.ok(root.props.style.top >= 134 && root.props.style.top + root.props.style.maxHeight <= 472);
  naturalHeight = 740;
  const mode = { x: 8, y: 200, width: 304, height: 80 };
  tree = component.render({ ...props, failed: true, modeSelectorBounds: mode });
  root = nodes(tree).find(node => node?.props?.role === "dialog");
  assert.ok(!overlaps(root.props.style, { width: 304, height: root.props.style.maxHeight }, mode));
  assert.equal(sends, 0);
  assert.equal(local, 0);
  const send = nodes(tree).find(node => node?.props?.className?.includes("kiri-remote-consent__send"));
  send.props.onClick();
  assert.equal(sends, 1, "remote OCR remains an explicit button action");
  component.unmount();
});

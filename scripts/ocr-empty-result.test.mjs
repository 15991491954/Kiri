import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { createLibraryHarness, nodes, settleRequests } from './helpers/library-render-harness.mjs';
const source = 'import React from "react";\n' + readFileSync(new URL('../src/ocr/OcrDialog.tsx', import.meta.url), 'utf8');

test('successful empty saved-image OCR presents the normal reader, without Retry or history claim', async () => {
  let calls = 0;
  const harness = createLibraryHarness({}, source, {
    modules: { '../lib/ipc': {
      api: { recognizeAssetLocal: async () => { calls++; return { text: '' }; } },
      mediaUrl: id => `media:${id}`, onLibraryChanged: async () => () => {},
    } },
    attachRef(node) { if (node.type === 'dialog') node.props.ref.current = { showModal() {}, close() {} }; },
  });
  const component = harness.mount('OcrDialog', { asset: { id: 'blank', kind: 'image' }, onClose() {} });
  component.render(); await settleRequests();
  const tree = component.render();
  assert.equal(calls, 1);
  const reader = nodes(tree).find(node => typeof node?.type === 'function' && node.type.name === 'TextReader');
  assert.equal(reader.props.text, '');
  assert.equal(nodes(tree).includes('Retry'), false);
  assert.equal(nodes(tree).includes('Saved to Text History'), false);
  const mountedReader = harness.mount('TextReader', reader.props);
  assert.ok(nodes(mountedReader.render()).includes('No Text Found'));
  mountedReader.unmount(); component.unmount();
});

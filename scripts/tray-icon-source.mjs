#!/usr/bin/env node
/**
 * Renders the macOS menu-bar template icon (`src-tauri/icons/tray-viewfinder.png`).
 *
 * macOS tints a template image with the menu-bar foreground color, so the mark
 * is pure black on transparency: the same viewfinder brackets as the app icon,
 * without the rounded-square plate.
 */
import { writeFileSync } from "node:fs";
import { deflateSync } from "node:zlib";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const SIZE = 64;
const SCALE = 4;
const CANVAS = SIZE * SCALE;
const pixels = new Uint8Array(CANVAS * CANVAS * 4);

function crc32(buffer) {
  let crc = 0xffffffff;
  for (const byte of buffer) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit += 1) crc = (crc >>> 1) ^ (0xedb88320 & -(crc & 1));
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, "ascii"), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body));
  return Buffer.concat([length, body, crc]);
}

function encodePng(width, height, rgba) {
  const stride = width * 4;
  const raw = Buffer.alloc((stride + 1) * height);
  for (let y = 0; y < height; y += 1) {
    raw[y * (stride + 1)] = 0;
    Buffer.from(rgba.buffer, y * stride, stride).copy(raw, y * (stride + 1) + 1);
  }
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0);
  header.writeUInt32BE(height, 4);
  header[8] = 8;
  header[9] = 6;
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk("IHDR", header),
    chunk("IDAT", deflateSync(raw, { level: 9 })),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

function capsule(px, py, x1, y1, x2, y2, width) {
  const radius = width / 2;
  const dx = x2 - x1;
  const dy = y2 - y1;
  const lengthSquared = dx * dx + dy * dy;
  let t = lengthSquared === 0 ? 0 : ((px - x1) * dx + (py - y1) * dy) / lengthSquared;
  t = Math.min(Math.max(t, 0), 1);
  return Math.hypot(px - (x1 + t * dx), py - (y1 + t * dy)) <= radius;
}

// The mark occupies the same 79% box as the app icon so both read as one brand.
const box = Math.round(CANVAS * 0.79);
const left = Math.round((CANVAS - box) / 2);
const top = left;
const right = left + box;
const bottom = top + box;
const arm = Math.round(box * 0.24);
const stroke = Math.round(box * 0.1);
const segments = [
  [left, top, left + arm, top],
  [left, top, left, top + arm],
  [right, top, right - arm, top],
  [right, top, right, top + arm],
  [left, bottom, left + arm, bottom],
  [left, bottom, left, bottom - arm],
  [right, bottom, right - arm, bottom],
  [right, bottom, right, bottom - arm],
];
const centre = CANVAS / 2;
const dot = box * 0.075;
for (let y = Math.floor(top - stroke); y <= Math.ceil(bottom + stroke); y += 1) {
  for (let x = Math.floor(left - stroke); x <= Math.ceil(right + stroke); x += 1) {
    const px = x + 0.5;
    const py = y + 0.5;
    if (Math.hypot(px - centre, py - centre) > dot &&
      !segments.some(([x1, y1, x2, y2]) => capsule(px, py, x1, y1, x2, y2, stroke))) continue;
    const index = (y * CANVAS + x) * 4;
    pixels[index] = 0;
    pixels[index + 1] = 0;
    pixels[index + 2] = 0;
    pixels[index + 3] = 255;
  }
}

const out = new Uint8Array(SIZE * SIZE * 4);
for (let y = 0; y < SIZE; y += 1) {
  for (let x = 0; x < SIZE; x += 1) {
    let alpha = 0;
    for (let sy = 0; sy < SCALE; sy += 1) {
      for (let sx = 0; sx < SCALE; sx += 1) {
        alpha += pixels[((y * SCALE + sy) * CANVAS + (x * SCALE + sx)) * 4 + 3];
      }
    }
    const index = (y * SIZE + x) * 4;
    out[index + 3] = Math.round(alpha / (SCALE * SCALE));
  }
}

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const target = join(root, "src-tauri", "icons", "tray-viewfinder.png");
writeFileSync(target, encodePng(SIZE, SIZE, out));
console.log(`Wrote ${target}`);

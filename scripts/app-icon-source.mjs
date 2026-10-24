#!/usr/bin/env node
/**
 * Renders the master app icon (`src-tauri/icons/app-icon-source.png`).
 *
 * The mark is drawn here instead of being exported from a design tool so the
 * brand stays reproducible: one blue rounded square with the Lumen viewfinder
 * glyph. The PNG is a 1024x1024 RGBA image with transparent padding beyond a
 * rounded-square silhouette, which is what `tauri icon` and
 * `scripts/app-icons.mjs verify` expect.
 */
import { writeFileSync } from "node:fs";
import { deflateSync } from "node:zlib";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const SIZE = 1024;
const SUPERSAMPLE = 4;
const CANVAS = SIZE * SUPERSAMPLE;

// Visible square is 79% of the canvas: the icon verifier accepts 78-84%,\n// and the anti-aliased edge of a 32 px rendering must stay below 86%.
const BOX = Math.round(CANVAS * 0.79);
const LEFT = Math.round((CANVAS - BOX) / 2);
const TOP = LEFT;
const RADIUS = Math.round(BOX * 0.235);

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
  header[8] = 8; // bit depth
  header[9] = 6; // RGBA
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk("IHDR", header),
    chunk("IDAT", deflateSync(raw, { level: 9 })),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

function inside(px, py, left, top, width, height, radius) {
  const right = left + width;
  const bottom = top + height;
  if (px < left || py < top || px > right || py > bottom) return 0;
  const nearestX = Math.min(Math.max(px, left + radius), right - radius);
  const nearestY = Math.min(Math.max(py, top + radius), bottom - radius);
  const dx = px - nearestX;
  const dy = py - nearestY;
  return dx * dx + dy * dy <= radius * radius ? 1 : 0;
}

function capsule(px, py, x1, y1, x2, y2, width) {
  const radius = width / 2;
  const dx = x2 - x1;
  const dy = y2 - y1;
  const lengthSquared = dx * dx + dy * dy;
  let t = lengthSquared === 0 ? 0 : ((px - x1) * dx + (py - y1) * dy) / lengthSquared;
  t = Math.min(Math.max(t, 0), 1);
  const nearestX = x1 + t * dx;
  const nearestY = y1 + t * dy;
  return Math.hypot(px - nearestX, py - nearestY) <= radius ? 1 : 0;
}

function fill(px, py, color) {
  const index = (py * CANVAS + px) * 4;
  if (color[3] >= 0.999) {
    pixels[index] = color[0];
    pixels[index + 1] = color[1];
    pixels[index + 2] = color[2];
    pixels[index + 3] = 255;
    return;
  }
  const alpha = color[3];
  const existing = pixels[index + 3] / 255;
  const out = alpha + existing * (1 - alpha);
  pixels[index] = Math.round((color[0] * alpha + pixels[index] * existing * (1 - alpha)) / out);
  pixels[index + 1] = Math.round((color[1] * alpha + pixels[index + 1] * existing * (1 - alpha)) / out);
  pixels[index + 2] = Math.round((color[2] * alpha + pixels[index + 2] * existing * (1 - alpha)) / out);
  pixels[index + 3] = Math.round(out * 255);
}

// --- background: blue vertical gradient inside a rounded square ------------
const TOP_COLOR = [78, 140, 255];
const BOTTOM_COLOR = [26, 86, 214];
for (let y = 0; y < CANVAS; y += 1) {
  const t = (y - TOP) / BOX;
  const clamp = Math.min(Math.max(t, 0), 1);
  // Ease the ramp so the top half stays lighter, like a macOS app icon.
  const eased = clamp * clamp * (3 - 2 * clamp);
  const color = TOP_COLOR.map((value, index) =>
    Math.round(value + (BOTTOM_COLOR[index] - value) * eased));
  for (let x = 0; x < CANVAS; x += 1) {
    if (!inside(x + 0.5, y + 0.5, LEFT, TOP, BOX, BOX, RADIUS)) continue;
    fill(x, y, [...color, 1]);
  }
}

// A restrained specular highlight across the top edge adds depth without a
// gradient band; it is what keeps the square from looking like a flat swatch.
for (let y = TOP; y < TOP + BOX * 0.46; y += 1) {
  const strength = 0.16 * (1 - (y - TOP) / (BOX * 0.46));
  for (let x = LEFT; x < LEFT + BOX; x += 1) {
    if (!inside(x + 0.5, y + 0.5, LEFT, TOP, BOX, BOX, RADIUS)) continue;
    fill(x, y, [255, 255, 255, strength]);
  }
}

// --- glyph: white viewfinder brackets and a capture dot --------------------
const WHITE = [255, 255, 255];
const glyphLeft = LEFT + Math.round(BOX * 0.205);
const glyphRight = LEFT + BOX - Math.round(BOX * 0.205);
const glyphTop = TOP + Math.round(BOX * 0.205);
const glyphBottom = TOP + BOX - Math.round(BOX * 0.205);
const arm = Math.round(BOX * 0.16);
const stroke = Math.round(BOX * 0.058);
const segments = [
  [glyphLeft, glyphTop, glyphLeft + arm, glyphTop],
  [glyphLeft, glyphTop, glyphLeft, glyphTop + arm],
  [glyphRight, glyphTop, glyphRight - arm, glyphTop],
  [glyphRight, glyphTop, glyphRight, glyphTop + arm],
  [glyphLeft, glyphBottom, glyphLeft + arm, glyphBottom],
  [glyphLeft, glyphBottom, glyphLeft, glyphBottom - arm],
  [glyphRight, glyphBottom, glyphRight - arm, glyphBottom],
  [glyphRight, glyphBottom, glyphRight, glyphBottom - arm],
];
const centre = CANVAS / 2;
const dotRadius = BOX * 0.052;
for (let y = Math.floor(glyphTop - stroke); y <= Math.ceil(glyphBottom + stroke); y += 1) {
  for (let x = Math.floor(glyphLeft - stroke); x <= Math.ceil(glyphRight + stroke); x += 1) {
    const px = x + 0.5;
    const py = y + 0.5;
    const onDot = Math.hypot(px - centre, py - centre) <= dotRadius;
    const onBracket = segments.some(([x1, y1, x2, y2]) => capsule(px, py, x1, y1, x2, y2, stroke));
    if (onDot || onBracket) fill(x, y, [...WHITE, 1]);
  }
}

// --- downsample to the master size -----------------------------------------
const out = new Uint8Array(SIZE * SIZE * 4);
for (let y = 0; y < SIZE; y += 1) {
  for (let x = 0; x < SIZE; x += 1) {
    let r = 0;
    let g = 0;
    let b = 0;
    let a = 0;
    for (let sy = 0; sy < SUPERSAMPLE; sy += 1) {
      for (let sx = 0; sx < SUPERSAMPLE; sx += 1) {
        const index = ((y * SUPERSAMPLE + sy) * CANVAS + (x * SUPERSAMPLE + sx)) * 4;
        const alpha = pixels[index + 3] / 255;
        r += pixels[index] * alpha;
        g += pixels[index + 1] * alpha;
        b += pixels[index + 2] * alpha;
        a += alpha;
      }
    }
    const index = (y * SIZE + x) * 4;
    const samples = SUPERSAMPLE * SUPERSAMPLE;
    if (a > 0) {
      out[index] = Math.round(r / a);
      out[index + 1] = Math.round(g / a);
      out[index + 2] = Math.round(b / a);
    }
    out[index + 3] = Math.round((a / samples) * 255);
  }
}

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const target = join(root, "src-tauri", "icons", "app-icon-source.png");
writeFileSync(target, encodePng(SIZE, SIZE, out));
console.log(`Wrote ${target}`);

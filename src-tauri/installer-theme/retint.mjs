import { createHash } from "node:crypto";
import { brotliCompressSync } from "node:zlib";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { loadBundle } from "./build.mjs";

const directory = fileURLToPath(new URL(".", import.meta.url));
const files = loadBundle(directory);

// 1. Installer copy: the product is Lumen everywhere, and the author's GitHub
//    star link is gone. The first-capture hint matches the real F1 default.
for (const name of Object.keys(files)) {
  if (!name.endsWith(".nsh") && name !== "preview.nsi") continue;
  let text = files[name].toString("utf8");
  text = text.split("Kiri").join("Lumen").split("kiri").join("lumen");
  text = text.replace(/^LangString YuxinoStarLink .*\r?\n/gm, "");
  text = text.split("Shift+Ctrl+A").join("F1");
  files[name] = Buffer.from(text, "utf8");
}

const theme = files["theme.nsh"].toString("utf8");
if (theme.includes("MUI_FINISHPAGE_LINK")) {
  files["theme.nsh"] = Buffer.from(
    theme
      .replace(/^!define MUI_FINISHPAGE_LINK .*\r?\n/gm, "")
      .replace(/^!define MUI_FINISHPAGE_LINK_LOCATION .*\r?\n/gm, "")
      .replace(/^!define MUI_FINISHPAGE_LINK_COLOR .*\r?\n/gm, ""),
    "utf8",
  );
}

// 2. New sidebar: a soft blue brand gradient with a faint ring, replacing the
//    old character illustration. 24-bit BMP, 656x1256, bottom-up rows.
const width = 656;
const height = 1256;
const rowBytes = (width * 3 + 3) & ~3;
const pixels = Buffer.alloc(rowBytes * height);
const clamp = (value) => Math.max(0, Math.min(255, Math.round(value)));
for (let y = 0; y < height; y += 1) {
  const t = y / (height - 1);
  for (let x = 0; x < width; x += 1) {
    const dx = (x - width / 2) / (width / 2);
    const dy = (y - height * 0.42) / (height * 0.42);
    const distance = Math.sqrt(dx * dx + dy * dy);
    const ring = Math.exp(-Math.pow((distance - 0.42) / 0.055, 2)) * 0.55;
    const glow = Math.exp(-(distance * distance) / 0.28) * 0.35;
    const base = 250 - t * 6;
    const blue = ring + glow;
    const r = clamp(base - blue * 34);
    const g = clamp(base - blue * 12 - t * 2);
    const b = clamp(base + blue * 8);
    const row = height - 1 - y;
    const offset = row * rowBytes + x * 3;
    pixels[offset] = b;
    pixels[offset + 1] = g;
    pixels[offset + 2] = r;
  }
}
const bmp = Buffer.alloc(54 + pixels.length);
bmp.write("BM", 0, "ascii");
bmp.writeUInt32LE(bmp.length, 2);
bmp.writeUInt32LE(54, 10);
bmp.writeUInt32LE(40, 14);
bmp.writeInt32LE(width, 18);
bmp.writeInt32LE(height, 22);
bmp.writeUInt16LE(1, 26);
bmp.writeUInt16LE(24, 28);
bmp.writeUInt32LE(0, 30);
bmp.writeUInt32LE(pixels.length, 34);
pixels.copy(bmp, 54);
files["sidebar.bmp"] = bmp;

// 3. Repack the pinned bundle and refresh its lock.
const pack = {
  format: "yuxino-installer-v2",
  product: "lumen",
  version: "1.0.0",
  files: Object.fromEntries(Object.entries(files).map(([name, data]) => [
    name,
    { size: data.length, sha256: createHash("sha256").update(data).digest("hex"), data: data.toString("base64") },
  ])),
};
const unpacked = Buffer.from(JSON.stringify(pack), "utf8");
const compressed = brotliCompressSync(unpacked);
writeFileSync(join(directory, "theme.bundle.br"), compressed);
writeFileSync(join(directory, "theme.lock.json"), JSON.stringify({
  format: "yuxino-installer-lock-v2",
  source: "Lumen installer theme",
  version: "1.0.0",
  product: "lumen",
  size: compressed.length,
  unpackedSize: unpacked.length,
  sha256: createHash("sha256").update(compressed).digest("hex"),
}, null, 2) + "\n");
console.log("bundle", compressed.length, unpacked.length);

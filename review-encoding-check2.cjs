const fs = require("fs");
const files = ["src/ocr/text-result.css","src/ocr/OcrDialog.tsx","src/annotation/cursors.js","src/annotation/mode-switching.js","src/styles/design-system.css","src/qr/qr.css","scripts/cursors.test.mjs","scripts/mode-switching.test.mjs"];
for (const f of files) {
  const text = fs.readFileSync(f, "utf8");
  const bad = text.indexOf("\uFFFD");
  const line = text.split(/\r?\n/).find(l => l.includes("summary::before")) || "";
  console.log(f, "replacement:", bad >= 0 ? "YES at " + bad : "none", line ? "| " + JSON.stringify(line.trim()) : "");
}

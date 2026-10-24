const fs = require("fs");
const dir = "src/i18n";
const files = fs.readdirSync(dir).filter(f => f.endsWith(".json"));
const maps = {};
for (const f of files) maps[f] = JSON.parse(fs.readFileSync(`${dir}/${f}`, "utf8"));
const base = Object.keys(maps["en.json"]).sort();
console.log("base keys:", base.length, "files:", files.join(","));
for (const [f, m] of Object.entries(maps)) {
  const keys = Object.keys(m).sort();
  const missing = base.filter(k => !(k in m));
  const extra = keys.filter(k => !(k in maps["en.json"]));
  if (missing.length || extra.length) console.log(f, "missing:", missing.join("|"), "extra:", extra.join("|"));
}
for (const k of ["Press 1 / 2 / 3 to change mode"]) {
  console.log(JSON.stringify(k), "present:", files.filter(f => k in maps[f]).join(","));
}
for (const k of ["Saved to Text History", "History wasn't saved. Copy the text before closing."]) {
  console.log("removed key", JSON.stringify(k), "still present in:", files.filter(f => k in maps[f]).join(",") || "none");
}

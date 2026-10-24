const fs = require("fs");
const path = process.argv[2];
const lines = fs.readFileSync(path, "utf8").split(/\r?\n/).filter(Boolean);
console.log("lines", lines.length);
for (let i = 0; i < Math.min(6, lines.length); i++) {
  let o; try { o = JSON.parse(lines[i]); } catch (e) { console.log(i, "PARSE FAIL", lines[i].slice(0,100)); continue; }
  console.log(i, "keys:", Object.keys(o).join(","), "| type:", o.type, "| role:", o.role ?? o.message?.role);
  console.log(JSON.stringify(o).slice(0, 400));
}

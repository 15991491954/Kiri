const fs = require("fs");
const path = process.argv[2];
const lines = fs.readFileSync(path, "utf8").split(/\r?\n/).filter(Boolean);
lines.forEach((line, i) => {
  let o; try { o = JSON.parse(line); } catch { return; }
  if (o.type !== "user") return;
  const c = o.message && o.message.content;
  let text = "";
  if (typeof c === "string") text = c;
  else if (Array.isArray(c)) text = c.filter(x => x.type === "text").map(x => x.text).join("\n");
  if (text.trim()) console.log(`\n===== USER line ${i+1} =====\n${text.trim().slice(0, 3000)}`);
});

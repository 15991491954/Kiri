const fs = require("fs");
const path = process.argv[2];
const lines = fs.readFileSync(path, "utf8").split(/\r?\n/).filter(Boolean);
for (let i = 291; i < lines.length; i++) {
  let o; try { o = JSON.parse(lines[i]); } catch { continue; }
  const role = o.role ?? o.message?.role;
  const c = o.message?.content;
  if (!Array.isArray(c)) continue;
  for (const part of c) {
    if (part.type === "text" && part.text.trim()) {
      console.log(`\n--- ${role} L${i+1} TEXT ---\n${part.text.trim().slice(0, 1200)}`);
    } else if (part.type === "tool_use") {
      const inp = part.input || {};
      const brief = inp.command || inp.path || inp.pattern || inp.description || "";
      console.log(`  [${role} L${i+1}] ${part.name}: ${String(brief).replace(/\s+/g," ").slice(0, 220)}`);
    }
  }
}

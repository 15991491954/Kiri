const fs = require("fs");
const path = process.argv[2];
const lines = fs.readFileSync(path, "utf8").split(/\r?\n/).filter(Boolean);
for (let i = 225; i < Math.min(292, lines.length); i++) {
  let o; try { o = JSON.parse(lines[i]); } catch { continue; }
  const role = o.role ?? o.message?.role;
  const c = o.message?.content;
  if (!Array.isArray(c)) continue;
  for (const part of c) {
    if (part.type === "text" && part.text.trim() && role === "assistant") {
      const t = part.text.trim().replace(/\s+/g, " ");
      console.log(`\n--- A${i+1} ---\n${t.slice(0, 1500)}`);
    } else if (part.type === "tool_use") {
      const inp = part.input || {};
      const brief = inp.command || inp.path || inp.pattern || inp.description || "";
      console.log(`  [A${i+1}] ${part.name}: ${String(brief).replace(/\s+/g," ").slice(0, 200)}`);
    }
  }
}

const fs = require("fs");
const path = process.argv[2];
const lines = fs.readFileSync(path, "utf8").split(/\r?\n/).filter(Boolean);
for (let i = 195; i < 292; i++) {
  let o; try { o = JSON.parse(lines[i]); } catch { continue; }
  const role = o.role ?? o.message?.role;
  const c = o.message?.content;
  if (!Array.isArray(c)) continue;
  for (const part of c) {
    if (part.type === "text" && part.text.trim() && role === "assistant") {
      console.log(`\n--- A${i+1} ---\n${part.text.trim().slice(0, 2500)}`);
    } else if (part.type === "tool_use") {
      const inp = part.input || {};
      const brief = inp.command || inp.path || inp.pattern || inp.description || "";
      console.log(`  [A${i+1}] ${part.name}: ${String(brief).replace(/\s+/g," ").slice(0, 200)}`);
    }
  }
}

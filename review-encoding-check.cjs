const fs = require("fs");
for (const f of ["docs/privacy/zh-CN.md","docs/privacy/en.md","docs/README.md","docs/architecture.md","src/i18n/zh-Hans.json","src/i18n/ja.json","CONTRIBUTING.md"]) {
  const text = fs.readFileSync(f, "utf8");
  const bad = [];
  let i = text.indexOf("\uFFFD");
  while (i >= 0 && bad.length < 5) { bad.push(JSON.stringify(text.slice(Math.max(0,i-25), i+5))); i = text.indexOf("\uFFFD", i+1); }
  console.log(f, "replacement-chars:", bad.length ? bad.join(" | ") : "none");
}

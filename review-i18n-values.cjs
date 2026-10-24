const fs = require("fs");
const files = ["en","zh-Hans","zh-Hant","ja","de","ko","fr"];
const keys = ["Press 1 / 2 / 3 to change mode","Copy Text","Text Copied","Recognized Text","Local OCR","No Text Found","View Source Image","Copy OCR Text","Paste as Pin"];
for (const k of keys) {
  const row = files.map(f => { const m = JSON.parse(fs.readFileSync(`src/i18n/${f}.json`,"utf8")); return `${f}=${m[k] ?? "(missing)"}`; });
  console.log(k + "\n  " + row.join("\n  "));
}

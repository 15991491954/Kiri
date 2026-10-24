const fs = require("fs");
const path = process.argv[2];
const lines = fs.readFileSync(path, "utf8").split(/\r?\n/).filter(Boolean);
function textOf(o){const c=o.message?.content;if(typeof c==="string")return c;if(Array.isArray(c))return c.filter(x=>x.type==="text").map(x=>x.text).join("\n");return "";}
lines.forEach((line,i)=>{
  if(i<40||i>291)return;
  let o;try{o=JSON.parse(line)}catch{return}
  const role=o.role??o.message?.role;
  if(role!=="assistant")return;
  const text=textOf(o).trim();
  if(text)console.log(`\n--- A${i+1} ---\n${text.slice(0,900)}`);
});

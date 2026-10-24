const fs = require("fs");
const path = process.argv[2];
const lines = fs.readFileSync(path, "utf8").split(/\r?\n/).filter(Boolean);
lines.forEach((line,i)=>{
  let o;try{o=JSON.parse(line)}catch{return}
  const role=o.role??o.message?.role;
  if(role!=="user")return;
  const c=o.message?.content;
  let t="";
  if(typeof c==="string")t=c; else if(Array.isArray(c))t=c.filter(x=>x.type==="text").map(x=>x.text).join("\n");
  const m=t.match(/<user_query>([\s\S]*?)<\/user_query>/);
  const ts=t.match(/<timestamp>([^<]*)<\/timestamp>/);
  if(m)console.log(`\n[${ts?ts[1]:"?"}] (line ${i+1})\n${m[1].trim().slice(0,1500)}`);
});

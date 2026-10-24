const port = process.argv[2] ?? "9333";
const pages = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
console.log(JSON.stringify(pages.map(p => ({type:p.type,title:p.title,url:p.url})), null, 2));
const overlay = pages.find(p => p.type === "page" && /[?&]window=overlay/.test(p.url));
if (!overlay) { console.log("NO_OVERLAY"); process.exit(0); }
const expression = `(() => ({ readyState: document.readyState, href: location.href,
  buttons: [...document.querySelectorAll("button")].map(b => b.getAttribute("aria-label") || b.title || b.textContent),
  body: document.body ? document.body.innerText.slice(0, 400) : null,
  html: document.body ? document.body.innerHTML.slice(0, 300) : null }))()`;
const value = await new Promise((resolve, reject) => {
  const socket = new WebSocket(overlay.webSocketDebuggerUrl);
  const timer = setTimeout(() => { socket.close(); reject(new Error("timeout")); }, 10000);
  socket.addEventListener("open", () => socket.send(JSON.stringify({id:1,method:"Runtime.evaluate",params:{expression,returnByValue:true}})));
  socket.addEventListener("message", event => { const m = JSON.parse(event.data); if (m.id !== 1) return;
    clearTimeout(timer); socket.close(); resolve(m.result?.result?.value); });
  socket.addEventListener("error", e => { clearTimeout(timer); reject(new Error(String(e))); });
});
console.log(JSON.stringify(value, null, 2));

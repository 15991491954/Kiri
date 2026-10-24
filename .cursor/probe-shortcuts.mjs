// Reads the shortcut DTOs from the running window through CDP.
// Used by the shell end-to-end check; not part of the product.
const port = process.argv[2] ?? "9334";

const pages = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
const page = pages.find((entry) => entry.type === "page" && /localhost:1420/.test(entry.url));
if (!page) {
  console.error("no library target");
  process.exit(2);
}

const expression = `(async () => {
  const internals = window.__TAURI_INTERNALS__;
  if (!internals) return { error: "no internals" };
  const settings = await internals.invoke("get_shortcut_settings");
  const defaults = {};
  for (const setting of settings.shortcuts ?? settings.settings ?? settings) {
    if (setting && setting.action) defaults[setting.action] = setting.defaultLabel ?? setting.label;
  }
  return defaults;
})()`;

const result = await new Promise((resolve, reject) => {
  const socket = new WebSocket(page.webSocketDebuggerUrl);
  const timer = setTimeout(() => { socket.close(); reject(new Error("timeout")); }, 10000);
  socket.addEventListener("open", () => socket.send(JSON.stringify({
    id: 1, method: "Runtime.evaluate",
    params: { expression, returnByValue: true, awaitPromise: true },
  })));
  socket.addEventListener("message", (event) => {
    const message = JSON.parse(event.data);
    if (message.id !== 1) return;
    clearTimeout(timer);
    socket.close();
    resolve(message.result?.result?.value);
  });
  socket.addEventListener("error", reject);
});
console.log(JSON.stringify(result));

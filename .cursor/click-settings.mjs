// Opens the Settings destination through the sidebar's third row.
const port = process.argv[2] ?? "9334";
const pages = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
const page = pages.find((entry) => entry.type === "page");
const expression = `(() => {
  const rows = [...document.querySelectorAll(".library-section-picker__button")];
  if (rows.length < 3) return { ok: false, count: rows.length };
  rows[2].click();
  return { ok: true };
})()`;
const value = await new Promise((resolve, reject) => {
  const socket = new WebSocket(page.webSocketDebuggerUrl);
  socket.onopen = () => socket.send(JSON.stringify({ id: 1, method: "Runtime.evaluate", params: { expression, returnByValue: true } }));
  socket.onmessage = (event) => {
    const message = JSON.parse(event.data);
    if (message.id !== 1) return;
    socket.close();
    resolve(message.result?.result?.value);
  };
  socket.onerror = reject;
});
console.log(JSON.stringify(value));

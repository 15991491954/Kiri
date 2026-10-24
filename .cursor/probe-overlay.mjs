const pages = await (await fetch("http://127.0.0.1:9335/json")).json();
console.log(pages.filter((p) => p.type === "page").map((p) => p.url).join("\n"));
const page = pages.find((p) => p.type === "page" && p.url.includes("window=overlay"));
if (!page) process.exit(0);
const value = await new Promise((resolve, reject) => {
  const socket = new WebSocket(page.webSocketDebuggerUrl);
  socket.onopen = () => socket.send(JSON.stringify({
    id: 1, method: "Runtime.evaluate",
    params: {
      expression: `({ text: document.body.innerText.slice(0, 200), nodes: document.querySelectorAll("*").length, buttons: document.querySelectorAll("button").length, root: document.getElementById("root")?.children.length ?? -1 })`,
      returnByValue: true,
    },
  }));
  socket.onmessage = (event) => {
    const message = JSON.parse(event.data);
    if (message.id !== 1) return;
    socket.close();
    resolve(message.result?.result?.value);
  };
  socket.onerror = reject;
});
console.log(JSON.stringify(value, null, 2));

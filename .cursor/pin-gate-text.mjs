// Opens the overlay's text tool and a canvas text editor through CDP, so the
// pin check can click Pin while a text annotation is still being edited.
// A capture on a multi-display desktop opens one overlay per display and only
// the overlay that owns the selection renders the toolbar, so every target is
// probed. Not part of the product.

const port = process.argv[2] ?? "9333";

const isOverlay = page => page.type === "page" && /[?&]window=overlay/.test(page.url);

async function connect(page) {
  const socket = new WebSocket(page.webSocketDebuggerUrl);
  const pending = new Map();
  let nextId = 1;
  socket.addEventListener("message", event => {
    const message = JSON.parse(event.data);
    const entry = pending.get(message.id);
    if (!entry) return;
    pending.delete(message.id);
    entry(message);
  });
  await new Promise((resolve, reject) => {
    socket.addEventListener("open", resolve);
    socket.addEventListener("error", reject);
  });
  const command = (method, params) => {
    const id = nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        pending.delete(id);
        reject(new Error(`${method} timed out`));
      }, 8000);
      pending.set(id, message => {
        clearTimeout(timer);
        if (message.error) reject(new Error(JSON.stringify(message.error)));
        else resolve(message.result);
      });
      socket.send(JSON.stringify({ id, method, params }));
    });
  };
  const evaluate = async expression => {
    const result = await command("Runtime.evaluate", { expression, returnByValue: true });
    return result?.result?.value;
  };
  return { socket, command, evaluate };
}

const toolExpression = `(() => {
  const buttons = [...document.querySelectorAll("button")];
  const text = buttons.find(button => (button.getAttribute("aria-keyshortcuts") || "").toUpperCase() === "T");
  if (!text) return { found: false, labels: buttons.map(button => button.getAttribute("aria-label")).filter(Boolean).slice(0, 24) };
  text.click();
  return { found: true, label: text.getAttribute("aria-label") };
})()`;

const deadline = Date.now() + 15000;
let done = null;
while (Date.now() < deadline && !done) {
  const pages = (await (await fetch(`http://127.0.0.1:${port}/json`)).json()).filter(isOverlay);
  for (const page of pages) {
    let session;
    try {
      session = await connect(page);
      const tool = await session.evaluate(toolExpression);
      if (!tool?.found) continue;
      const canvas = await session.evaluate(`(() => {
        const element = document.querySelector("canvas");
        if (!element) return null;
        const rect = element.getBoundingClientRect();
        return { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };
      })()`);
      if (canvas) {
        const press = { type: "mousePressed", x: canvas.x, y: canvas.y, button: "left", buttons: 1, clickCount: 1 };
        const release = { type: "mouseReleased", x: canvas.x, y: canvas.y, button: "left", buttons: 0, clickCount: 1 };
        await session.command("Input.dispatchMouseEvent", press);
        await new Promise(resolve => setTimeout(resolve, 120));
        await session.command("Input.dispatchMouseEvent", release);
      }
      await new Promise(resolve => setTimeout(resolve, 600));
      const editor = await session.evaluate(`(() => {
        const active = document.activeElement;
        return {
          tag: active?.tagName ?? null,
          editable: !!document.querySelector("textarea, [contenteditable=true]"),
        };
      })()`);
      done = { tool: tool.label, canvas: !!canvas, ...editor, page: page.url };
      break;
    } catch (error) {
      done = done ?? null;
    } finally {
      session?.socket.close();
    }
  }
  if (!done) await new Promise(resolve => setTimeout(resolve, 300));
}

console.log(JSON.stringify(done ?? { tool: "no-text-tool", editable: false }));
process.exit(done?.editable ? 0 : 2);

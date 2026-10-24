// Selects a region through CDP input and clicks the toolbar pin action.
const port = process.argv[2] ?? "9336";
const x = Number(process.argv[3] ?? 600);
const y = Number(process.argv[4] ?? 350);
const width = Number(process.argv[5] ?? 400);
const height = Number(process.argv[6] ?? 300);

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const targets = async () => (await (await fetch(`http://127.0.0.1:${port}/json`)).json())
  .filter((entry) => entry.type === "page");

function connect(url) {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(url);
    socket.onopen = () => resolve(socket);
    socket.onerror = reject;
  });
}

let nextId = 1;
function call(socket, method, params) {
  const id = nextId++;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`${method} timed out`)), 8000);
    const listener = (event) => {
      const message = JSON.parse(event.data);
      if (message.id !== id) return;
      clearTimeout(timer);
      socket.removeEventListener("message", listener);
      if (message.error) reject(new Error(JSON.stringify(message.error)));
      else resolve(message.result);
    };
    socket.addEventListener("message", listener);
    socket.send(JSON.stringify({ id, method, params }));
  });
}

const overlays = (await targets()).filter((page) => page.url.includes("window=overlay"));
for (const overlay of overlays) {
  const socket = await connect(overlay.webSocketDebuggerUrl);
  try {
    const mouse = (type, px, py, buttons) => call(socket, "Input.dispatchMouseEvent", {
      type, x: px, y: py, button: "left", buttons, clickCount: 1,
    });
    await mouse("mousePressed", x, y, 1);
    for (let step = 1; step <= 10; step += 1) {
      await mouse("mouseMoved", x + (width * step) / 10, y + (height * step) / 10, 1);
      await sleep(20);
    }
    await mouse("mouseReleased", x + width, y + height, 0);
    await sleep(500);
    const clicked = await call(socket, "Runtime.evaluate", {
      expression: `(() => {
        const button = [...document.querySelectorAll("button")].find((b) => /pin screenshot|pin on top|置顶截图|贴图/i.test(b.getAttribute("aria-label") || ""));
        if (!button) return { ok: false, labels: [...document.querySelectorAll("button")].map((b) => b.getAttribute("aria-label")).filter(Boolean) };
        button.click();
        return { ok: true };
      })()`,
      returnByValue: true,
    });
    console.log(JSON.stringify(clicked.result?.value));
    if (clicked.result?.value?.ok) process.exit(0);
  } catch (error) {
    console.log(JSON.stringify({ ok: false, error: String(error) }));
  } finally {
    socket.close();
  }
}
process.exit(1);

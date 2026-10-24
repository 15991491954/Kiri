// Drives the capture overlay through CDP input (renderer-level), then starts
// scrolling capture and reports the resulting windows and log lines.
import { readFileSync } from "node:fs";

const PORT = 9335;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function targets() {
  return (await (await fetch(`http://127.0.0.1:${PORT}/json`)).json()).filter((e) => e.type === "page");
}

function connect(url) {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(url);
    socket.onopen = () => resolve(socket);
    socket.onerror = reject;
  });
}

function call(socket, id, method, params) {
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
console.log("overlays", overlays.length);
let nextId = 1;
for (const overlay of overlays) {
  const socket = await connect(overlay.webSocketDebuggerUrl);
  try {
    const drag = async (type, x, y) => call(socket, nextId++, "Input.dispatchMouseEvent", {
      type, x, y, button: "left", buttons: type === "mouseReleased" ? 0 : 1, clickCount: 1,
    });
    await drag("mousePressed", 520, 300);
    for (let step = 1; step <= 10; step += 1) {
      await drag("mouseMoved", 520 + 52 * step, 300 + 42 * step);
      await sleep(20);
    }
    await drag("mouseReleased", 1040, 720);
    await sleep(400);
    const found = await call(socket, nextId++, "Runtime.evaluate", {
      expression: `(() => {
        const buttons = [...document.querySelectorAll("button")];
        const scroll = buttons.find((b) => /scroll|滚动/i.test((b.getAttribute("aria-label") || "") + " " + (b.getAttribute("title") || "")));
        if (!scroll) return { ok: false, labels: buttons.map((b) => b.getAttribute("aria-label") || b.getAttribute("title")).filter(Boolean) };
        scroll.click();
        return { ok: true, label: scroll.getAttribute("aria-label") || scroll.getAttribute("title") };
      })()`,
      returnByValue: true,
    });
    console.log("scroll button", JSON.stringify(found.result?.value));
    if (found.result?.value?.ok) break;
  } catch (error) {
    console.log("overlay failed", String(error));
  } finally {
    socket.close();
  }
}

await sleep(3000);
const after = await targets();
console.log("targets\n" + after.map((page) => page.url).join("\n"));
const logPath = `${process.env.LOCALAPPDATA}\\io.yuxino.kiri\\logs\\kiri.log`;
const recent = readFileSync(logPath, "utf8").split("\n").slice(-40)
  .filter((line) => /scroll|Scroll|exclude/.test(line)).join("\n");
console.log("log\n" + recent);

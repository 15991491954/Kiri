// Invokes start_scroll_capture directly on the overlay so the exclusion path is
// exercised without depending on synthetic mouse input.
import { readFileSync } from "node:fs";

const logPath = `${process.env.LOCALAPPDATA}\\io.yuxino.kiri\\logs\\kiri.log`;
const logText = readFileSync(logPath, "utf8");
const matches = [...logText.matchAll(/start_capture: returning active session capture_id=([a-f0-9-]+)/g)];
const captureId = matches.at(-1)?.[1];
if (!captureId) throw new Error("no capture id in the log");
console.log("capture", captureId);

const targets = await (await fetch("http://127.0.0.1:9335/json")).json();
const overlay = targets.find((entry) => entry.type === "page" && entry.url.includes("window=overlay"));
if (!overlay) throw new Error("no overlay target");

const expression = `(async () => {
  try {
    await window.__TAURI_INTERNALS__.invoke("start_scroll_capture", {
      captureId: ${JSON.stringify(captureId)},
      selection: { x: 0, y: 0, width: 2560, height: 1400 },
    });
    return { ok: true };
  } catch (error) {
    return { ok: false, error: String(error) };
  }
})()`;

const value = await new Promise((resolve, reject) => {
  const socket = new WebSocket(overlay.webSocketDebuggerUrl);
  socket.onopen = () => socket.send(JSON.stringify({
    id: 1, method: "Runtime.evaluate",
    params: { expression, returnByValue: true, awaitPromise: true },
  }));
  socket.onmessage = (event) => {
    const message = JSON.parse(event.data);
    if (message.id !== 1) return;
    socket.close();
    resolve(message.result?.result?.value);
  };
  socket.onerror = reject;
});
console.log("invoke", JSON.stringify(value));
await new Promise((resolve) => setTimeout(resolve, 3000));
const after = await (await fetch("http://127.0.0.1:9335/json")).json();
console.log("targets", after.map((entry) => entry.url).join("\n"));
const tail = readFileSync(logPath, "utf8").split("\n").slice(-25).filter((line) => line.includes("scroll") || line.includes("Scroll")).join("\n");
console.log("log", tail);

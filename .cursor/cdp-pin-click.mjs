// Clicks the capture toolbar's Pin action through the real WebView via CDP.
// Used by the screenshot -> pin end-to-end check; not part of the product.
//
// A capture on a multi-display desktop opens one overlay per display, and only
// the overlay that owns the drag selection renders the annotation toolbar. The
// script therefore probes every overlay instead of assuming the first target is
// the one the user selected on.

const port = process.argv[2] ?? "9333";
const deadline = Date.now() + 30000;

async function targets() {
  const response = await fetch(`http://127.0.0.1:${port}/json`);
  if (!response.ok) throw new Error(`CDP returned ${response.status}`);
  return response.json();
}

function evaluate(wsUrl, expression) {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(wsUrl);
    const timer = setTimeout(() => {
      socket.close();
      reject(new Error("CDP evaluate timed out"));
    }, 10000);
    socket.addEventListener("open", () => {
      socket.send(JSON.stringify({ id: 1, method: "Runtime.evaluate", params: { expression, returnByValue: true } }));
    });
    socket.addEventListener("message", event => {
      const message = JSON.parse(event.data);
      if (message.id !== 1) return;
      clearTimeout(timer);
      socket.close();
      if (message.error) reject(new Error(JSON.stringify(message.error)));
      else resolve(message.result?.result?.value);
    });
    socket.addEventListener("error", error => {
      clearTimeout(timer);
      reject(new Error(String(error)));
    });
  });
}

const clickPin = `(() => {
  const buttons = [...document.querySelectorAll("button")];
  const pin = buttons.find(button => /pin screenshot|pin on top|置顶|贴图/i.test(button.getAttribute("aria-label") || ""));
  if (!pin) return { ok: false, labels: buttons.map(button => button.getAttribute("aria-label")).filter(Boolean) };
  pin.click();
  return { ok: true, label: pin.getAttribute("aria-label"), href: location.href };
})()`;

let last = { ok: false, labels: [], overlays: [] };
while (Date.now() < deadline) {
  const pages = await targets();
  const overlays = pages.filter(page => page.type === "page" && /[?&]window=overlay/.test(page.url));
  last.overlays = overlays.map(page => page.url);
  for (const overlay of overlays) {
    try {
      const result = await evaluate(overlay.webSocketDebuggerUrl, clickPin);
      if (result?.ok) {
        console.log(JSON.stringify(result));
        await new Promise(resolve => setTimeout(resolve, 150));
        process.exit(0);
      }
      if (result?.labels?.length) last = result;
    } catch (error) {
      last = { ok: false, labels: [], error: String(error), overlays: last.overlays };
    }
  }
  await new Promise(resolve => setTimeout(resolve, 200));
}
console.log(JSON.stringify(last));
await new Promise(resolve => setTimeout(resolve, 150));
process.exit(2);

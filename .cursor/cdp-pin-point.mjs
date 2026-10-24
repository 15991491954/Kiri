// Returns the toolbar Pin button's screen position (CSS px) for the real-mouse
// hit test that this check needs. Not part of the product.

const port = process.argv[2] ?? "9333";
const deadline = Date.now() + 25000;

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

const probe = `(() => {
  const buttons = [...document.querySelectorAll("button")];
  const pin = buttons.find(button => /pin screenshot|pin on top|置顶|贴图/i.test(button.getAttribute("aria-label") || ""));
  if (!pin) return { ok: false, labels: buttons.map(button => button.getAttribute("aria-label")).filter(Boolean) };
  const rect = pin.getBoundingClientRect();
  const dpr = window.devicePixelRatio || 1;
  return {
    ok: true,
    label: pin.getAttribute("aria-label"),
    clientX: rect.left + rect.width / 2,
    clientY: rect.top + rect.height / 2,
    // Window.screenX/Y of a borderless overlay is its on-screen client origin.
    screenX: (window.screenX || 0) + rect.left + rect.width / 2,
    screenY: (window.screenY || 0) + rect.top + rect.height / 2,
    width: rect.width,
    height: rect.height,
    dpr,
    href: location.href,
  };
})()`;

let last = { ok: false };
while (Date.now() < deadline) {
  const pages = await targets();
  const overlays = pages.filter(page => page.type === "page" && /[?&]window=overlay/.test(page.url));
  for (const overlay of overlays) {
    try {
      const result = await evaluate(overlay.webSocketDebuggerUrl, probe);
      if (result?.ok) {
        console.log(JSON.stringify(result));
        await new Promise(resolve => setTimeout(resolve, 100));
        process.exit(0);
      }
      if (result?.labels?.length) last = result;
    } catch (error) {
      last = { ok: false, error: String(error) };
    }
  }
  await new Promise(resolve => setTimeout(resolve, 150));
}
console.log(JSON.stringify(last));
process.exit(2);

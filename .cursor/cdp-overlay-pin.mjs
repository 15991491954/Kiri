// Locates the capture overlay's Pin button through the real WebView via CDP.
// Prints JSON so the PowerShell E2E run can click it with real mouse input.
// Not part of the product; the temporary CDP port exists only for that run.

const port = process.argv[2] ?? "9333";
const deadline = Date.now() + Number(process.argv[3] ?? 20000);
const PIN_LABEL = /pin screenshot|pin on top|置顶|贴图/i;

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
  const labels = buttons.map(b => b.getAttribute("aria-label") || b.title || (b.textContent || "").trim());
  const pin = buttons.find(b => ${PIN_LABEL}.test(b.getAttribute("aria-label") || b.title || ""));
  if (!pin) return { found: false, href: location.href, readyState: document.readyState, labels };
  const rect = pin.getBoundingClientRect();
  return {
    found: true,
    href: location.href,
    label: pin.getAttribute("aria-label") || pin.title,
    rect: { x: rect.x, y: rect.y, width: rect.width, height: rect.height },
    dpr: window.devicePixelRatio,
    screenX: window.screenX,
    screenY: window.screenY,
    innerWidth: window.innerWidth,
    innerHeight: window.innerHeight,
  };
})()`;

async function finish(code, payload) {
  console.log(JSON.stringify(payload));
  // Let the CDP socket finish closing; exiting while a libuv handle is still
  // closing aborts the Node process with an assertion on Windows.
  await new Promise(resolve => setTimeout(resolve, 150));
  process.exit(code);
}

let last = { found: false, overlays: [] };
while (Date.now() < deadline) {
  const pages = await targets();
  const overlays = pages.filter(page => page.type === "page" && /[?&]window=overlay/.test(page.url));
  last = { found: false, overlays: overlays.map(page => page.url) };
  for (const overlay of overlays) {
    try {
      const info = await evaluate(overlay.webSocketDebuggerUrl, probe);
      if (info?.found) {
        info.webSocketDebuggerUrl = overlay.webSocketDebuggerUrl;
        await finish(0, info);
      }
      last = info ?? last;
      last.overlays = overlays.map(page => page.url);
    } catch (error) {
      last = { found: false, error: String(error), overlays: overlays.map(page => page.url) };
    }
  }
  await new Promise(resolve => setTimeout(resolve, 200));
}
await finish(4, last);

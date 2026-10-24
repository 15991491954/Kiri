// Lists every capture-overlay target and the buttons it currently renders.
// QA-only helper for diagnosing the screenshot -> pin flow on multi-monitor
// systems; it never ships with the product.

const port = process.argv[2] ?? "9333";

const pages = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
const overlays = pages.filter(page => page.type === "page" && /[?&]window=overlay/.test(page.url));

function evaluate(wsUrl, expression) {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(wsUrl);
    const timer = setTimeout(() => { socket.close(); reject(new Error("evaluate timed out")); }, 8000);
    socket.addEventListener("open", () =>
      socket.send(JSON.stringify({ id: 1, method: "Runtime.evaluate", params: { expression, returnByValue: true } })));
    socket.addEventListener("message", event => {
      const message = JSON.parse(event.data);
      if (message.id !== 1) return;
      clearTimeout(timer);
      socket.close();
      resolve(message.result?.result?.value);
    });
    socket.addEventListener("error", error => { clearTimeout(timer); reject(new Error(String(error))); });
  });
}

const probe = `(() => ({
  href: location.href,
  dpr: window.devicePixelRatio,
  screen: { x: window.screenX, y: window.screenY, w: window.innerWidth, h: window.innerHeight },
  buttons: [...document.querySelectorAll("button")].map(b => ({
    label: b.getAttribute("aria-label"),
    title: b.getAttribute("title"),
    text: (b.textContent || "").trim().slice(0, 24),
    visible: b.getBoundingClientRect().width > 0,
  })),
  toolbar: !!document.querySelector(".kiri-annotation-toolbar"),
  bodyText: (document.body?.innerText || "").replace(/\\s+/g, " ").slice(0, 160),
}))()`;

const result = [];
for (const overlay of overlays) {
  try {
    result.push(await evaluate(overlay.webSocketDebuggerUrl, probe));
  } catch (error) {
    result.push({ href: overlay.url, error: String(error) });
  }
}
console.log(JSON.stringify(result, null, 2));

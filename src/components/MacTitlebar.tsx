import { useEffect, useRef, useState } from "react";
import type { CSSProperties, PointerEvent as ReactPointerEvent } from "react";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { PhysicalPosition } from "@tauri-apps/api/dpi";
/** Mirrors the resize directions the window API accepts; the alias itself
 * is declared but not exported by `@tauri-apps/api/window`. */
type ResizeDirection = "East" | "North" | "NorthEast" | "NorthWest" | "South" | "SouthEast" | "SouthWest" | "West";
import { t } from "../i18n";
import { LumenMark } from "./LumenMark";
import "./kiri-titlebar.css";

/**
 * macOS-style window chrome for the main window.
 *
 * The window is undecorated, so this bar owns the three traffic lights, the
 * drag region, and double-click zoom. The resize handles are separate elements
 * at the window edges: without native decorations there is no frame to grab.
 */
export function MacTitlebar({ title, detail }: { title: string; detail?: string }) {
  const [maximized, setMaximized] = useState(false);

  useEffect(() => {
    const appWindow = getCurrentWindow();
    let disposed = false;
    const sync = () => {
      void appWindow.isMaximized().then((value) => {
        if (!disposed) setMaximized(value);
      }).catch(() => {});
    };
    sync();
    const unsubscribe = appWindow.onResized(sync);
    return () => {
      disposed = true;
      void unsubscribe.then((stop) => stop()).catch(() => {});
    };
  }, []);

  // A maximized window fills the display; rounding its corners would show the
  // desktop in the gaps.
  useEffect(() => {
    document.documentElement.dataset.maximized = String(maximized);
  }, [maximized]);
  const appWindow = getCurrentWindow();
  // The undecorated window is moved from the drag strip itself. `startDragging`
  // hands the pointer to the compositor, which then owns the loop; moving the
  // window by the reported pointer delta keeps the gesture inside the WebView
  // and works identically on every Windows session (measured on Windows 10).
  const drag = useRef<{
    pointerId: number;
    x: number;
    y: number;
    origin: { x: number; y: number } | null;
    pending: { x: number; y: number } | null;
    applying: boolean;
    finished: boolean;
    cancelled: boolean;
  } | null>(null);
  const applyDrag = (gesture: typeof drag.current) => {
    if (!gesture || !gesture.origin || gesture.applying || gesture.cancelled) return;
    const origin = gesture.origin;
    gesture.applying = true;
    void (async () => {
      try {
        // The origin arrives over IPC and can resolve after the pointer is
        // already up. Applying the queued delta afterwards is what makes a
        // short, fast flick move the window instead of being dropped.
        while (gesture.pending && !gesture.cancelled) {
          const point = gesture.pending;
          gesture.pending = null;
          await appWindow.setPosition(new PhysicalPosition(
            Math.round(origin.x + (point.x - gesture.x)),
            Math.round(origin.y + (point.y - gesture.y)),
          ));
        }
      } catch { gesture.pending = null; }
      finally {
        gesture.applying = false;
        if (gesture.finished && drag.current === gesture) drag.current = null;
      }
    })();
  };
  return (
    <header className="kiri-titlebar">
      <div className="kiri-titlebar__drag"
        onPointerDown={(event) => {
          if (event.button !== 0) return;
          event.preventDefault();
          event.currentTarget.setPointerCapture(event.pointerId);
          drag.current = {
            pointerId: event.pointerId,
            x: event.screenX,
            y: event.screenY,
            origin: null,
            pending: null,
            applying: false,
            finished: false,
            cancelled: false,
          };
          const gesture = drag.current;
          void appWindow.outerPosition().then((position) => {
            if (gesture.cancelled) return;
            gesture.origin = { x: position.x, y: position.y };
            applyDrag(gesture);
          }).catch(() => { gesture.origin = null; });
        }}
        onPointerMove={(event) => {
          const gesture = drag.current;
          if (!gesture || gesture.pointerId !== event.pointerId) return;
          gesture.pending = { x: event.screenX, y: event.screenY };
          applyDrag(gesture);
        }}
        onPointerUp={(event) => {
          const gesture = drag.current;
          if (!gesture || gesture.pointerId !== event.pointerId) return;
          gesture.pending = { x: event.screenX, y: event.screenY };
          gesture.finished = true;
          applyDrag(gesture);
        }}
        onPointerCancel={() => {
          if (drag.current) {
            drag.current.cancelled = true;
            drag.current.pending = null;
            drag.current = null;
          }
        }}
        onDoubleClick={() => void appWindow.toggleMaximize().catch(() => {})} />
      <div className="kiri-titlebar__brand" aria-hidden="true">
        <LumenMark size={15} />
        <strong>Lumen</strong>
      </div>
      <div className="kiri-titlebar__titles">
        <span className="kiri-titlebar__title">{title}</span>
        {detail && <span className="kiri-titlebar__detail">{detail}</span>}
      </div>
      <div className="kiri-titlebar__spacer" />
      <div className="kiri-titlebar__lights" role="group" aria-label={t("Window controls")}>
        <button type="button" className="kiri-window-light kiri-window-light--minimize"
          aria-label={t("Minimize")} title={t("Minimize")}
          onClick={() => void appWindow.minimize().catch(() => {})}><span aria-hidden="true">−</span></button>
        <button type="button" className="kiri-window-light kiri-window-light--zoom"
          aria-label={t(maximized ? "Restore" : "Zoom")} title={t(maximized ? "Restore" : "Zoom")}
          onClick={() => void appWindow.toggleMaximize().catch(() => {})}><span aria-hidden="true">+</span></button>
        <button type="button" className="kiri-window-light kiri-window-light--close"
          aria-label={t("Close")} title={t("Close")}
          onClick={() => void appWindow.close().catch(() => {})}><span aria-hidden="true">×</span></button>
      </div>
    </header>
  );
}

type Edge = { direction: ResizeDirection; style: CSSProperties };

const EDGE_SIZE = 5;
const CORNER_SIZE = 12;
const EDGES: Edge[] = [
  { direction: "North", style: { top: 0, left: CORNER_SIZE, right: CORNER_SIZE, height: EDGE_SIZE, cursor: "n-resize" } },
  { direction: "South", style: { bottom: 0, left: CORNER_SIZE, right: CORNER_SIZE, height: EDGE_SIZE, cursor: "s-resize" } },
  { direction: "West", style: { left: 0, top: CORNER_SIZE, bottom: CORNER_SIZE, width: EDGE_SIZE, cursor: "w-resize" } },
  { direction: "East", style: { right: 0, top: CORNER_SIZE, bottom: CORNER_SIZE, width: EDGE_SIZE, cursor: "e-resize" } },
  { direction: "NorthWest", style: { top: 0, left: 0, width: CORNER_SIZE, height: CORNER_SIZE, cursor: "nw-resize" } },
  { direction: "NorthEast", style: { top: 0, right: 0, width: CORNER_SIZE, height: CORNER_SIZE, cursor: "ne-resize" } },
  { direction: "SouthWest", style: { bottom: 0, left: 0, width: CORNER_SIZE, height: CORNER_SIZE, cursor: "sw-resize" } },
  { direction: "SouthEast", style: { bottom: 0, right: 0, width: CORNER_SIZE, height: CORNER_SIZE, cursor: "se-resize" } },
];

/**
 * Native resize handles for an undecorated window.
 *
 * Each strip starts the compositor's own resize loop, so the window keeps the
 * platform behavior (minimum size, snap, DPI) instead of reimplementing it.
 */
export function WindowResizeEdges() {
  const start = (event: ReactPointerEvent<HTMLDivElement>, direction: ResizeDirection) => {
    if (event.button !== 0) return;
    event.preventDefault();
    void getCurrentWindow().startResizeDragging(direction).catch(() => {});
  };
  return (
    <div className="kiri-resize-layer" aria-hidden="true">
      {EDGES.map(({ direction, style }) => (
        <div key={direction} className="kiri-resize-edge" style={style}
          onPointerDown={(event) => start(event, direction)} />
      ))}
    </div>
  );
}

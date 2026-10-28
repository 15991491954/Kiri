import { useEffect, useRef, useState } from "react";
import type { WheelEvent as ReactWheelEvent } from "react";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { PhysicalPosition, PhysicalSize } from "@tauri-apps/api/dpi";
import { api, mediaUrl, onAssetContentChanged, onPinOnTop } from "../lib/ipc";
import { t } from "../i18n";
import { KiriIcon } from "../components/KiriIcons";
import "./pin-window.css";

type ResizeGesture = {
  pointerId: number;
  x: number;
  y: number;
  base: { width: number; height: number; scale: number } | null;
  pending: { x: number; y: number } | null;
  applying: boolean;
};

type MoveGesture = {
  pointerId: number;
  x: number;
  y: number;
  base: { x: number; y: number; scale: number } | null;
  pending: { x: number; y: number } | null;
  applying: boolean;
  cancelled: boolean;
};

type ZoomCorner = "top-left" | "top-right" | "bottom-left" | "bottom-right";

type ZoomGesture = {
  applying: boolean;
  pending: { factor: number; anchorX: number; anchorY: number } | null;
  image: { width: number; height: number } | null;
  report: (size: { width: number; height: number }) => void;
};

async function applyZoom(gesture: ZoomGesture) {
  if (gesture.applying) return;
  gesture.applying = true;
  try {
    while (gesture.pending) {
      const step = gesture.pending;
      gesture.pending = null;
      const image = gesture.image;
      const size = await api.zoomPin(step.factor, step.anchorX, step.anchorY,
        image?.width ?? 0, image?.height ?? 0);
      gesture.report(size);
    }
  } catch { gesture.pending = null; }
  finally { gesture.applying = false; }
}

async function applyMove(gesture: MoveGesture) {
  if (!gesture.base || gesture.applying || gesture.cancelled) return;
  gesture.applying = true;
  try {
    while (gesture.pending && !gesture.cancelled) {
      const point = gesture.pending;
      gesture.pending = null;
      const { x, y, scale } = gesture.base;
      await getCurrentWindow().setPosition(new PhysicalPosition(
        Math.round(x + (point.x - gesture.x) * scale),
        Math.round(y + (point.y - gesture.y) * scale),
      ));
    }
  } catch { gesture.pending = null; }
  finally { gesture.applying = false; }
}

async function applyResize(gesture: ResizeGesture) {
  if (!gesture.base || gesture.applying) return;
  gesture.applying = true;
  try {
    while (gesture.pending) {
      const point = gesture.pending;
      gesture.pending = null;
      const { width, height, scale } = gesture.base;
      const dx = (point.x - gesture.x) * scale / width;
      const dy = (point.y - gesture.y) * scale / height;
      const minimum = Math.min(1, Math.max(80 * scale / width, 60 * scale / height));
      const ratio = Math.max(minimum, 1 + (Math.abs(dx) > Math.abs(dy) ? dx : dy));
      await getCurrentWindow().setSize(new PhysicalSize(Math.round(width * ratio), Math.round(height * ratio)));
    }
  } catch { gesture.pending = null; }
  finally { gesture.applying = false; }
}

export function PinWindow({ id }: { id: string }) {
  const [onTop, setOnTop] = useState(true);
  const [busy, setBusy] = useState(false);
  const topState = useRef({onTop: true, generation: 0, busy: false});
  const [locked, setLocked] = useState(false);
  const lockedRef = useRef(false);
  const [menu, setMenu] = useState<{ x: number; y: number } | null>(null);
  const [error, setError] = useState(false);
  const [imageFailed, setImageFailed] = useState(false);
  const [revision, setRevision] = useState(0);
  const resizeGesture = useRef<ResizeGesture | null>(null);
  const moveGesture = useRef<MoveGesture | null>(null);
  const latestMove = useRef<MoveGesture | null>(null);
  const zoomGesture = useRef<ZoomGesture | null>(null);
  const imageSize = useRef<{ width: number; height: number } | null>(null);
  const openedWidth = useRef(0);
  const zoomTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const zoomCorner = useRef<ZoomCorner>("top-left");
  const [zoomHint, setZoomHint] = useState<{ percent: number; corner: ZoomCorner } | null>(null);
  useEffect(() => {
    void getCurrentWindow().innerSize()
      .then(size => { openedWidth.current = size.width; })
      .catch(() => {});
    return () => {
      if (latestMove.current) latestMove.current.cancelled = true;
      if (zoomTimer.current) clearTimeout(zoomTimer.current);
    };
  }, []);
  useEffect(() => {
    // React installs wheel handlers passively, so only a native listener can
    // stop the WebView's own control-wheel page zoom from competing with the
    // pin's image zoom. The sizing itself stays in the React handler.
    const stopPageZoom = (event: WheelEvent) => event.preventDefault();
    window.addEventListener("wheel", stopPageZoom, { passive: false });
    // Removal only matches on the capture flag, so the passive option is not
    // repeated here.
    return () => window.removeEventListener("wheel", stopPageZoom);
  }, []);
  const menuRef = useRef(false);
  menuRef.current = !!menu;
  const showZoom = (size: { width: number; height: number }) => {
    // 100% means one image pixel per physical screen pixel, so the reference is
    // the intrinsic bitmap width. A pin opened on a Retina display starts at
    // 100%, while a library image fitted to a small reference starts below it.
    const reference = imageSize.current?.width || openedWidth.current;
    if (reference <= 0) return;
    setZoomHint({
      percent: Math.max(1, Math.round((size.width / reference) * 100)),
      corner: zoomCorner.current,
    });
    if (zoomTimer.current) clearTimeout(zoomTimer.current);
    zoomTimer.current = setTimeout(() => setZoomHint(null), 900);
  };
  const zoomBy = (factor: number, anchorX: number, anchorY: number) => {
    if (!Number.isFinite(factor) || factor <= 0) return;
    let gesture = zoomGesture.current;
    if (!gesture) {
      gesture = zoomGesture.current = { applying: false, pending: null, image: null,
        report: showZoom };
    }
    gesture.image = imageSize.current;
    // A fast wheel produces many events per native round trip; the factors add
    // up, and only the frame in progress is lost to the bound.
    gesture.pending = { factor: (gesture.pending?.factor ?? 1) * factor, anchorX, anchorY };
    void applyZoom(gesture);
  };
  // Ctrl+0 and a double click restore one image pixel per physical pixel.
  // The native Windows pin implements the same shortcut; this stays for the
  // WebView pin used on macOS and Linux.
  const resetZoom = async () => {
    const image = imageSize.current;
    if (!image) return;
    try {
      const size = await getCurrentWindow().innerSize();
      const factor = image.width / Math.max(1, size.width);
      if (Math.abs(factor - 1) < 0.005) {
        showZoom(size);
        return;
      }
      const next = await api.zoomPin(factor, 0.5, 0.5, image.width, image.height);
      showZoom(next);
    } catch { /* the window may already be closing */ }
  };
  const takeOverFrame = () => {
    // A drag or corner resize owns the frame from here on; a queued wheel step
    // would otherwise move the window out from under the pointer that grabbed it.
    if (zoomGesture.current) zoomGesture.current.pending = null;
  };
  useEffect(() => {
    const subscription = onAssetContentChanged((assetId) => {
      if (assetId === id) { setImageFailed(false); setRevision((value) => value + 1); }
    });
    return () => { void subscription.then((dispose) => dispose()).catch(() => {}); };
  }, [id]);
  useEffect(() => {
    const keydown = (event: KeyboardEvent) => {
      if (event.key === "Escape" && menuRef.current) {
        // Escape dismisses the context menu without closing the pin.
        event.preventDefault();
        setMenu(null);
        return;
      }
      if ((event.metaKey || event.ctrlKey) && event.key === "0") {
        event.preventDefault();
        void resetZoom();
        return;
      }
      if (event.key === "Escape" || ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "w")) {
        event.preventDefault(); void getCurrentWindow().close();
      }
    };
    window.addEventListener("keydown", keydown);
    return () => window.removeEventListener("keydown", keydown);
  }, []);
  useEffect(() => {
    let disposed = false;
    let unlisten: (() => void) | undefined;
    // Every new pin is created with always_on_top(true). The native getter can
    // briefly report false while the window manager is applying that request.
    // Track successful Lumen pin actions instead of freezing that startup snapshot.
    void onPinOnTop(() => {
      if (disposed) return;
      topState.current.generation += 1;
      topState.current.onTop = true;
      setOnTop(true);
      setError(false);
    }).then(stop => {
      if (disposed) stop();
      else unlisten = stop;
    }).catch(() => {});
    return () => { disposed = true; unlisten?.(); };
  }, []);
  const toggleLock = () => {
    lockedRef.current = !lockedRef.current;
    setLocked(lockedRef.current);
    if (lockedRef.current) {
      // A gesture in progress must not keep moving a card that is now locked.
      if (moveGesture.current) {
        moveGesture.current.cancelled = true;
        moveGesture.current.pending = null;
        moveGesture.current = null;
      }
      if (resizeGesture.current) {
        resizeGesture.current.pending = null;
        resizeGesture.current = null;
      }
    }
  };
  const toggleTop = async () => {
    const state = topState.current;
    if (state.busy) return;
    state.busy = true;
    const generation = state.generation;
    const next = !state.onTop;
    setBusy(true); setError(false);
    try {
      // The native side owns the topmost band: a pin that dropped out of it is
      // repaired synchronously, which a WebView flag alone cannot do.
      await api.setPinTopmost(next);
      // A library repin received while this request was pending is newer.
      if (state.generation === generation) {
        state.onTop = next;
        setOnTop(next);
      }
    }
    catch { if (state.generation === generation) setError(true); }
    finally { state.busy = false; setBusy(false); }
  };
  const handleWheel = (event: ReactWheelEvent<HTMLDivElement>) => {
    // A pointer gesture owns the frame while it runs: zooming would move the
    // window out from under the coordinates the gesture already captured.
    if (moveGesture.current || resizeGesture.current) return;
    const unit = event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? 400 : 1;
    const delta = Math.max(-240, Math.min(240, event.deltaY * unit));
    if (!delta) return;
    const host = event.currentTarget;
    const width = host.clientWidth || 1;
    const height = host.clientHeight || 1;
    const anchorX = Math.min(1, Math.max(0, event.clientX / width));
    const anchorY = Math.min(1, Math.max(0, event.clientY / height));
    // A zoom anchored at the pointer can push the opposite corner of the window
    // off screen, so the percentage badge stays in the quadrant under the cursor.
    zoomCorner.current =
      `${anchorY <= 0.5 ? "top" : "bottom"}-${anchorX <= 0.5 ? "left" : "right"}`;
    // One wheel notch is 100px and changes the size by 10%; trackpads send many
    // small deltas, and the exponent makes those continuous instead of steppy.
    zoomBy(Math.pow(1.1, -delta / 100), anchorX, anchorY);
  };
  return <div className="pin-window" aria-label={t("Screenshot Reference")}
    onWheel={handleWheel}
    onContextMenu={event => {
      event.preventDefault();
      setMenu({ x: event.clientX, y: event.clientY });
    }}
    onPointerDown={() => {
      // Pins are all topmost; pointing at one brings it above its siblings.
      void api.raisePin().catch(() => {});
      setMenu(null);
    }}>
    <div className="pin-window__actions" onPointerDown={event => event.stopPropagation()}>
      <button className="kiri-pin-action" type="button" disabled={busy}
        title={t(onTop ? "Unpin" : "Pin on Top")} aria-label={t(onTop ? "Unpin" : "Pin on Top")}
        onClick={() => void toggleTop()}><KiriIcon name={onTop ? "pin.slash" : "pin"} size={15} /></button>
      <button className="kiri-pin-action" type="button" title={t("Close")} aria-label={t("Close")}
        onClick={() => void getCurrentWindow().close()}><KiriIcon name="xmark" size={15} /></button>
    </div>
    {error && <p className="pin-window__error" role="alert">{t("Could not change window pinning on this desktop.")}</p>}
    {zoomHint && <div className="pin-window__zoom" role="status"
      data-corner={zoomHint.corner}>{zoomHint.percent}%</div>}
    <main className="pin-window__image" onDoubleClick={event => {
      // Double click restores 100%; the first click already selected the pin.
      event.preventDefault();
      void resetZoom();
    }} onPointerDown={event => {
      if (event.button !== 0) return;
      if (lockedRef.current) return;
      takeOverFrame();
      if (!/Macintosh|Mac OS X|Windows/i.test(navigator.userAgent)) {
        void getCurrentWindow().startDragging().catch(() => {});
        return;
      }
      // Native dragging reaches AppKit/Win32 asynchronously and a short gesture
      // may already have ended. Capture screen coordinates and retain pointerup
      // while the native origin loads. Linux keeps compositor-managed dragging.
      event.preventDefault();
      event.currentTarget.setPointerCapture(event.pointerId);
      if (latestMove.current) latestMove.current.cancelled = true;
      const gesture: MoveGesture = { pointerId: event.pointerId, x: event.screenX, y: event.screenY,
        base: null, pending: null, applying: false, cancelled: false };
      moveGesture.current = latestMove.current = gesture;
      const nativeWindow = getCurrentWindow();
      void Promise.all([nativeWindow.outerPosition(), nativeWindow.scaleFactor()]).then(([position, scale]) => {
        gesture.base = { x: position.x, y: position.y, scale };
        void applyMove(gesture);
      }).catch(() => { gesture.pending = null; });
    }} onPointerMove={event => {
      const gesture = moveGesture.current;
      if (!gesture || gesture.pointerId !== event.pointerId) return;
      gesture.pending = { x: event.screenX, y: event.screenY };
      void applyMove(gesture);
    }} onPointerUp={event => {
      const gesture = moveGesture.current;
      if (!gesture || gesture.pointerId !== event.pointerId) return;
      gesture.pending = { x: event.screenX, y: event.screenY };
      moveGesture.current = null;
      void applyMove(gesture);
    }} onPointerCancel={() => {
      if (moveGesture.current) {
        moveGesture.current.cancelled = true;
        moveGesture.current.pending = null;
      }
      moveGesture.current = null;
    }}>
      {imageFailed ? <p role="alert">{t("Can't read this file")}</p> :
        <img key={revision} src={`${mediaUrl(id)}?v=${revision}`} alt={t("Pinned screenshot")} draggable={false}
          onLoad={event => {
            const image = event.currentTarget;
            // Intrinsic size in image pixels: the reference the zoom
            // percentage is reported against.
            if (image.naturalWidth > 0 && image.naturalHeight > 0) {
              imageSize.current = { width: image.naturalWidth, height: image.naturalHeight };
            }
          }}
          onError={() => { imageSize.current = null; setImageFailed(true); }} />}
    </main>
    <div className="pin-window__resize" aria-hidden="true" onPointerDown={event => {
        event.stopPropagation();
        if (event.button !== 0) return;
        if (lockedRef.current) return;
        takeOverFrame();
        event.currentTarget.setPointerCapture(event.pointerId);
        const gesture: ResizeGesture = { pointerId: event.pointerId, x: event.screenX, y: event.screenY,
          base: null, pending: null, applying: false };
        resizeGesture.current = gesture;
        const window = getCurrentWindow();
        void Promise.all([window.innerSize(), window.scaleFactor()]).then(([size, scale]) => {
          gesture.base = { width: size.width, height: size.height, scale };
          void applyResize(gesture);
        }).catch(() => { gesture.pending = null; });
      }} onPointerMove={event => {
        const gesture = resizeGesture.current;
        if (!gesture || gesture.pointerId !== event.pointerId) return;
        gesture.pending = { x: event.screenX, y: event.screenY };
        void applyResize(gesture);
      }} onPointerUp={event => {
        const gesture = resizeGesture.current;
        if (!gesture || gesture.pointerId !== event.pointerId) return;
        gesture.pending = { x: event.screenX, y: event.screenY };
        resizeGesture.current = null;
        void applyResize(gesture);
      }} onPointerCancel={() => { resizeGesture.current = null; }} />
    {menu && <div className="pin-window__menu" role="menu"
      style={{
        left: Math.max(0, Math.min(menu.x, window.innerWidth - 180)),
        top: Math.max(0, Math.min(menu.y, window.innerHeight - 168)),
      }}
      onPointerDown={event => event.stopPropagation()}
      onContextMenu={event => event.preventDefault()}>
      <button type="button" role="menuitem" onClick={() => {
        setMenu(null);
        void api.copyAsset(id).catch(() => {});
      }}>{t("Copy")}</button>
      <button type="button" role="menuitem" onClick={() => {
        setMenu(null);
        void resetZoom();
      }}>{t("Reset")} 100%</button>
      <button type="button" role="menuitem" onClick={() => {
        setMenu(null);
        toggleLock();
      }}>{t(locked ? "Unlock Position" : "Lock Position")}</button>
      <button type="button" role="menuitem" onClick={() => {
        setMenu(null);
        void toggleTop();
      }}>{t(onTop ? "Unpin" : "Pin on Top")}</button>
      <button type="button" role="menuitem" onClick={() => {
        setMenu(null);
        void getCurrentWindow().close();
      }}>{t("Close")}</button>
    </div>}
  </div>;
}

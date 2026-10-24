import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { QrCode, Copy, ExternalLink, X, ChevronRight } from "lucide-react";
import { api, type QrCodeDto, type QrScanDto } from "../lib/ipc";
import { t, fmt } from "../i18n";
import type { Rect } from "../annotation/geom";
import { initialQrSelection, qrCodeCenter, qrContentType, qrLooksLikeLink } from "./selection.js";
import "../ocr/text-result.css";
import "./qr.css";

export function QrDetails({ code, action, preview, meta }: {
  code: QrCodeDto; action(action: string): Promise<unknown>; preview?: ReactNode; meta?: ReactNode;
}) {
  const [busy, setBusy] = useState(false);
  const busyRef = useRef(false);
  const [message, setMessage] = useState("");
  const contentType = qrContentType(code);
  const linkWarning = code.suspicious && contentType !== "WeChat" && (!!code.url || qrLooksLikeLink(code.text ?? ""));
  const directionWarning = code.text?.includes("\u202e") === true;
  const mounted = useRef(true);
  useEffect(() => { mounted.current = true; return () => { mounted.current = false; }; }, []);
  const run = async (name: string) => {
    if (busyRef.current) return;
    busyRef.current = true;
    setBusy(true); setMessage("");
    try {
      await action(name);
      if (!mounted.current) return;
      setMessage(t(name === "copy" ? "Copied to Clipboard" : "Link opened"));
    } catch (error) {
      if (mounted.current) setMessage(t(typeof error === "string" ? error : "Could not complete this QR action."));
    } finally { busyRef.current = false; if (mounted.current) setBusy(false); }
  };
  const controls = code.text ? (
    <div className="qr-actions">
      {code.url && <button type="button" className="kiri-button kiri-button--primary" disabled={busy} onClick={() => void run("open")}><ExternalLink size={14}/>{t("Open Link")}</button>}
      <button type="button" className={`kiri-button ${code.url ? "kiri-button--secondary" : "kiri-button--primary"}`} disabled={busy} onClick={() => void run("copy")}><Copy size={14}/>{t("Copy Text")}</button>
    </div>
  ) : null;
  return <section className="qr-details" aria-label={t("QR Content")}>
    <header className="qr-details__header">
      <div className="text-result__heading">
        <span className="text-reader__caption qr-content-type">{t(code.text ? contentType : "QR Content")}</span>
        {meta}
      </div>
    </header>
    <div className="qr-details__body">
      {preview}
      <div className="qr-details__content">
        <div className="qr-content" tabIndex={0}>{code.text ?? t("This QR code could not be decoded. Try a clearer image.")}</div>
        {code.text && <>
          {code.host && <p className="qr-host">{t("Destination")}: <bdi>{code.host}</bdi></p>}
          {(linkWarning || directionWarning) && <p className="qr-warning" role="note">{t(linkWarning ? "Review this content carefully. This link may be unsafe." : "Review this content carefully.")}</p>}
          {!code.url && linkWarning && <p className="qr-warning">{t("Only explicit HTTP or HTTPS links without credentials can be opened.")}</p>}
          {controls}
        </>}
      </div>
    </div>
    {message && <p className="qr-feedback" role="status">{message}</p>}
  </section>;
}

export function QrResults({ scan, onOpened, sourceRect, viewport, onClose }: {
  scan: QrScanDto;
  onOpened?(): void;
  sourceRect?: Rect;
  viewport?: Rect;
  onClose?(): void;
}) {
  const [selected, setSelected] = useState<number | null>(() => initialQrSelection(scan.codes));
  const [opening, setOpening] = useState(false);
  const openingRef = useRef(false);
  const mounted = useRef(true);
  const panelRef = useRef<HTMLDivElement>(null);
  const [panelHeight, setPanelHeight] = useState(240);
  useEffect(() => { mounted.current = true; return () => { mounted.current = false; }; }, []);
  const code = scan.codes.find(code => code.index === selected);
  useLayoutEffect(() => {
    const panel = panelRef.current;
    if (!panel) return;
    const measure = () => setPanelHeight(panel.offsetHeight);
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(panel);
    panel.focus({ preventScroll: true });
    return () => observer.disconnect();
  }, [selected, sourceRect?.width, viewport?.width, viewport?.height]);
  const onMarkerSelect = (index: number) => {
    if (openingRef.current) return;
    setSelected(index);
  };
  const targets = <div className="qr-targets" role="group" aria-label={t("Choose a QR code in the image")}>
        {scan.codes.map(code => {
          const center = qrCodeCenter(code.corners);
          return <button type="button" key={code.index} className="kiri-qr-marker" disabled={opening} style={{ left: `${center[0] * 100}%`, top: `${center[1] * 100}%` }} aria-pressed={selected === code.index} aria-label={fmt("QR code %d", code.index + 1)} onClick={() => onMarkerSelect(code.index)}>
            <ChevronRight size={18} strokeWidth={2.5} aria-hidden="true"/>
          </button>;
        })}
      </div>;
  const details = code ? <QrDetails key={code.index} code={code} action={async action => {
      const isOpen = action === "open";
      if (isOpen) {
        if (openingRef.current) return;
        openingRef.current = true; setOpening(true);
      }
      try {
        const result = await api.qrAction(scan.requestId, code.index, action);
        if (isOpen && mounted.current) onOpened?.();
        return result;
      } finally {
        if (isOpen) {
          openingRef.current = false;
          if (mounted.current) setOpening(false);
        }
      }
    }}/> : null;
  if (sourceRect && viewport) {
    const center = code ? qrCodeCenter(code.corners) : [0, 0];
    const anchor = { x: sourceRect.x + center[0] * sourceRect.width, y: sourceRect.y + center[1] * sourceRect.height };
    const margin = 12;
    const width = Math.min(340, Math.max(0, viewport.width - margin * 2));
    const minLeft = viewport.x + margin;
    const maxLeft = Math.max(minLeft, viewport.x + viewport.width - width - margin);
    const preferredLeft = anchor.x + 26 + width <= viewport.x + viewport.width - margin ? anchor.x + 26 : anchor.x - width - 26;
    const left = Math.min(maxLeft, Math.max(minLeft, preferredLeft));
    const minTop = viewport.y + margin;
    const top = Math.min(Math.max(minTop, viewport.y + viewport.height - panelHeight - margin), Math.max(minTop, anchor.y - 26));
    return <div className="qr-results-inline">
      <div className="qr-inline-source" style={{ left: sourceRect.x, top: sourceRect.y, width: sourceRect.width, height: sourceRect.height }}>{targets}</div>
      {code && <div ref={panelRef} className="qr-inline-panel" role="dialog" aria-label={t("QR Content")} tabIndex={-1} style={{ left, top, width, maxHeight: Math.max(0, viewport.height - margin * 2) }}>
        {onClose && <button type="button" className="kiri-icon-button qr-inline-close" aria-label={t("Close")} onClick={onClose}><X size={16}/></button>}
        {details}
      </div>}
    </div>;
  }
  return <div className="qr-results">
    <div className="qr-image-scroll"><div className="qr-image-stage">
      <img src={scan.imageUrl} alt={t("QR Source Image")} draggable={false}/>
      {targets}
    </div></div>
    {details ??
      <div className="qr-prompt" role="status"><QrCode size={28}/><p>{t(scan.codes.length ? "Choose a QR code in the image" : "No QR codes found. Try a clearer image or a larger selection.")}</p></div>}
  </div>;
}

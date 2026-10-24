import { useEffect, useRef, useState, type ReactNode } from "react";
import { api, mediaUrl, type AssetDto, type OcrRecognitionDto } from "../lib/ipc";
import { KiriIcon } from "../components/KiriIcons";
import { t } from "../i18n";
import "./text-result.css";

export function TextReader({ text, imageId, editor, heading, actions }: {
  text: string; imageId?: string; editor?: ReactNode; heading?: ReactNode; actions?: ReactNode;
}) {
  const [copied, setCopied] = useState(false);
  const [copyError, setCopyError] = useState(false);
  const [imageFailed, setImageFailed] = useState(false);
  const copyGeneration = useRef(0);
  useEffect(() => {
    setCopied(false); setCopyError(false); setImageFailed(false);
    copyGeneration.current += 1;
    return () => { copyGeneration.current += 1; };
  }, [text, imageId]);
  const copy = async () => {
    const generation = ++copyGeneration.current;
    setCopyError(false);
    try {
      await api.copyOcrText(text);
      if (generation === copyGeneration.current) setCopied(true);
    } catch {
      if (generation === copyGeneration.current) setCopyError(true);
    }
  };
  return <div className="text-reader">
    <div className="text-reader__actions">
      {heading ?? <span className="text-reader__caption">{t("Recognized Text")}</span>}
      <div className="text-result__actions">
        {!editor && <button type="button" className="kiri-button kiri-button--primary" disabled={!text.trim()} onClick={() => void copy()}>
          <KiriIcon name={copied ? "checkmark" : "doc.on.doc"} size={14} />
          {t(copied ? "Text Copied" : "Copy Text")}
        </button>}
        {actions}
      </div>
    </div>
    {copyError && <p className="text-result__error" role="alert">{t("Couldn't copy text.")}</p>}
    {editor ?? <div className="text-reader__body" tabIndex={0} role="region" aria-label={t("Recognized Text")}>
      {text.trim() ? text : t("No Text Found")}
    </div>}
    {imageId && <details className="text-reader__source" key={imageId}>
      <summary><KiriIcon name="photo.on.rectangle" size={14} />{t("View Source Image")}</summary>
      {imageFailed ? <p role="status">{t("Can't read this file")}</p> :
        <a href="#" onClick={(event) => { event.preventDefault(); void api.openAsset(imageId).catch(() => setImageFailed(true)); }} aria-label={t("Open Source Image")}>
          <img src={mediaUrl(imageId)} alt={t("OCR Source Image")} loading="lazy" onError={() => setImageFailed(true)} />
        </a>}
    </details>}
  </div>;
}

export function OcrDialog({ asset, onClose }: { asset: AssetDto; onClose(): void }) {
  const dialog = useRef<HTMLDialogElement>(null);
  const [result, setResult] = useState<OcrRecognitionDto | null>(asset.ocrText != null
    ? { text: asset.ocrText } : null);
  const [error, setError] = useState<string | null>(null);
  const [attempt, setAttempt] = useState(0);
  // A single promise survives React's effect replay. Closing never starts a retry.
  const request = useRef<Promise<OcrRecognitionDto> | null>(null);
  useEffect(() => {
    const element = dialog.current;
    element?.showModal();
    return () => element?.close();
  }, []);
  useEffect(() => {
    if (asset.ocrText != null) setResult({ text: asset.ocrText });
  }, [asset]);
  useEffect(() => {
    if (asset.ocrText != null) return;
    let current = true;
    setError(null);
    request.current ??= api.recognizeAssetLocal(asset.id);
    void request.current.then((value) => { if (current) setResult(value); }, (reason: unknown) => {
      if (current) setError(typeof reason === "string" ? reason : "Local OCR failed.");
    });
    return () => { current = false; };
  }, [asset.id, asset.ocrText, attempt]);
  return <dialog ref={dialog} className="text-dialog" onCancel={(event) => { event.preventDefault(); event.stopPropagation(); onClose(); }}
    onKeyDown={(event) => event.stopPropagation()} aria-labelledby="text-dialog-title">
    <header className="text-dialog__header">
      <div><h2 id="text-dialog-title">{t("Recognized Text")}</h2><p>{t("Local OCR")}</p></div>
      <button type="button" className="kiri-icon-button" aria-label={t("Close")} onClick={onClose}><KiriIcon name="xmark" size={16} /></button>
    </header>
    {result ? <TextReader text={result.text} imageId={asset.id} /> :
      <div className="text-result__empty" role={error ? "alert" : "status"}>
        <KiriIcon name="text.viewfinder" size={28} />
        <p>{t(error ?? "Recognizing Text…")}</p>
        {error && <button type="button" className="kiri-button kiri-button--secondary" onClick={() => { request.current = null; setAttempt((value) => value + 1); }}>{t("Retry")}</button>}
      </div>}
  </dialog>;
}

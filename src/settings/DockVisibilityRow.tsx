import { useCallback, useEffect, useRef, useState } from "react";
import { api, type DockVisibilityDto } from "../lib/ipc";
import { t } from "../i18n";

/** macOS appearance preference; it never controls window or capture lifetime. */
export function DockVisibilityRow() {
  const isMac = /Macintosh|Mac OS X/i.test(navigator.userAgent);
  const [status, setStatus] = useState<DockVisibilityDto | null>(null);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const mounted = useRef(false);
  const generation = useRef(0);
  const changing = useRef(false);

  const load = useCallback(async () => {
    if (!isMac) return;
    const request = ++generation.current;
    setLoading(true);
    setError(null);
    try {
      const next = await api.getDockVisibility();
      if (mounted.current && request === generation.current) setStatus(next);
    } catch {
      if (mounted.current && request === generation.current) setError("Couldn't load Dock visibility.");
    } finally {
      if (mounted.current && request === generation.current) setLoading(false);
    }
  }, [isMac]);

  useEffect(() => {
    mounted.current = true;
    void load();
    return () => { mounted.current = false; ++generation.current; };
  }, [load]);

  const change = async () => {
    if (!status?.supported || loading || changing.current) return;
    changing.current = true;
    setBusy(true);
    setError(null);
    const next = !status.visible;
    try {
      await api.setDockVisibility(next);
      if (mounted.current) setStatus({ supported: true, visible: next });
    } catch {
      if (mounted.current) setError("Couldn't change Dock visibility.");
    } finally {
      changing.current = false;
      if (mounted.current) setBusy(false);
    }
  };

  if (!isMac || status?.supported === false) return null;
  return (
    <div className="kiri-settings-card kiri-dock-row" aria-busy={loading || busy}>
      <div className="kiri-dock-copy">
        <strong>{t("Show in Dock")}</strong>
        <span>{t("When hidden, open Lumen from the menu bar.")}</span>
        {error && <span className="kiri-storage-error" role="alert">{t(error)}</span>}
      </div>
      {error && !status ? (
        <button type="button" className="kiri-button kiri-button--secondary" disabled={loading} onClick={() => void load()}>{t("Retry")}</button>
      ) : (
        <button
          type="button"
          role="switch"
          className="kiri-settings-switch"
          aria-label={t("Show in Dock")}
          aria-checked={status?.visible ?? true}
          disabled={loading || busy || !status}
          onClick={() => void change()}
        >
          <span aria-hidden="true" />
        </button>
      )}
    </div>
  );
}

import { useCallback, useEffect, useRef, useState } from "react";
import { api, onPortalShortcutsChanged, type PortalShortcutsDto } from "../lib/ipc";
import { t } from "../i18n";

const STATUS_TEXT: Record<PortalShortcutsDto["status"], string> = {
  unsupported: "Desktop shortcuts are unavailable in this session.",
  checking: "Checking desktop shortcut support…",
  unavailable: "This desktop does not provide a usable GlobalShortcuts Portal. Use the commands below.",
  ready: "Set up shortcuts with your desktop's permission dialog.",
  connecting: "Waiting for desktop shortcut approval…",
  active: "Current desktop bindings",
  declined: "Shortcut permission was declined or setup was cancelled. No Portal shortcuts are active.",
  failed: "Desktop shortcut setup failed. No Portal shortcuts are active. Use the commands below or retry.",
  closed: "The desktop shortcut session ended. Reconnect to use Portal shortcuts again.",
};
const COMMANDS = [
  ["Capture", "kiri --capture"],
  ["Pause/Resume Recording", "kiri --toggle-recording-pause"],
  ["Stop Recording", "kiri --stop-recording"],
];

export function PortalShortcutsCard() {
  const [status, setStatus] = useState<PortalShortcutsDto | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const alive = useRef(false);
  const operation = useRef<string | null>(null);
  const generation = useRef(0);
  const latestRevision = useRef(-1);
  const accept = useCallback((next: PortalShortcutsDto) => {
    if (!alive.current || next.revision < latestRevision.current) return;
    latestRevision.current = next.revision;
    setStatus(next);
  }, []);

  const update = useCallback(async (next: "setup" | "configure" | "refresh" | "disconnect") => {
    // This synchronous lock also covers repeated clicks before React renders.
    if (operation.current) return;
    operation.current = next;
    const current = ++generation.current;
    setBusy(next);
    setError(null);
    try {
      accept(await api.updatePortalShortcuts(next));
    } catch (failure) {
      if (alive.current && current === generation.current) setError(String(failure));
      // A failure cannot leave the last successful trigger presented as current.
      try { accept(await api.getPortalShortcuts()); }
      catch { if (alive.current) setStatus(null); }
    } finally {
      operation.current = null;
      if (alive.current && current === generation.current) setBusy(null);
    }
  }, [accept]);

  useEffect(() => {
    alive.current = true;
    // Subscribe before the snapshot so a fast setup/closure cannot disappear
    // between the initial read and subscription. Revisions reject stale IPC.
    const subscription = onPortalShortcutsChanged(accept);
    void subscription.then(() => api.getPortalShortcuts()).then(accept)
      .catch(() => { if (alive.current) setError("Could not load desktop shortcut status."); });
    const refresh = () => { void update("refresh"); };
    window.addEventListener("focus", refresh);
    return () => {
      alive.current = false;
      ++generation.current;
      if (operation.current === "setup") void api.cancelPortalShortcutSetup().catch(() => {});
      window.removeEventListener("focus", refresh);
      void subscription.then((dispose) => dispose()).catch(() => {});
    };
  }, [accept, update]);

  const pending = busy !== null || status?.status === "connecting" || status?.status === "checking";
  return (
    <div className="kiri-settings-card kiri-portal-shortcuts">
      <div className="kiri-shortcut-copy">
        <strong>{t("Wayland Desktop Shortcuts")}</strong>
        <span role="status" aria-live="polite">{t(status ? STATUS_TEXT[status.status] : "Loading desktop shortcut status…")}</span>
        <span>{t("Only Capture, Pause/Resume, and Stop are requested. Your desktop chooses the keys. Approved shortcuts are restored when Lumen starts; the desktop may ask again.")}</span>
        {error && <span role="alert">{t(error)}</span>}
      </div>
      <dl className="kiri-portal-bindings">
        {COMMANDS.map(([description, command], index) => (
          <div key={command}>
            <dt>{t(description)}</dt>
            <dd>{status?.status === "active" ? status.bindings[index]?.trigger || t("Not bound") : t("Not active")}</dd>
            <dd className="kiri-portal-command">{command}</dd>
          </div>
        ))}
      </dl>
      <div className="kiri-shortcut-actions">
        {status?.canConfigure && status.status === "active" ? (
          <button type="button" className="kiri-button kiri-button--secondary" disabled={pending} onClick={() => void update("configure")}>
            {t("Open Desktop Shortcut Settings")}
          </button>
        ) : (
          <button type="button" className="kiri-button kiri-button--secondary" disabled={pending || !status || status.status === "unavailable"} onClick={() => void update("setup")}>
            {t(status?.status === "closed" ? "Reconnect Desktop Shortcuts" : "Set Up Desktop Shortcuts")}
          </button>
        )}
        <button type="button" className="kiri-button kiri-button--secondary" disabled={pending} onClick={() => void update("refresh")}>
          {t("Refresh Shortcut Status")}
        </button>
        {status?.status === "active" && <button type="button" className="kiri-button kiri-button--secondary" disabled={pending} onClick={() => void update("disconnect")}>
          {t("Disconnect Desktop Shortcuts")}
        </button>}
        {busy === "setup" && <button type="button" className="kiri-button kiri-button--secondary" onClick={() => void api.cancelPortalShortcutSetup().catch(() => {})}>
          {t("Cancel Setup")}
        </button>}
      </div>
      <div className="kiri-shortcut-copy">
        <span>{t("You can always assign these commands in your desktop's keyboard settings. Lumen cannot verify command-based bindings. Configure a working Stop shortcut before recording.")}</span>
        {status?.status === "active" && !status.canConfigure && <span>{t("This Portal has no configuration UI. Change keys in desktop settings, or reconnect to request setup again.")}</span>}
        <span>{t("Disconnect stops Lumen listening and disables automatic restoration. Your desktop may keep its saved key choices.")}</span>
      </div>
    </div>
  );
}

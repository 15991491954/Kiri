// Content-sized recording controls anchored to the current capture region.
import { useEffect, useRef, useState } from "react";
import { GripVertical } from "lucide-react";
import { api, onRecordingState, type RecordingState } from "../lib/ipc";
import { t } from "../i18n";
import { KiriIcon } from "../components/KiriIcons";
import { useRecordingControlsLayout } from "./useRecordingControlsLayout";

export function ControlPanelWindow() {
  const [state, setState] = useState<RecordingState | null>(null);
  const stateRef = useRef<RecordingState | null>(null);
  stateRef.current = state;
  const sessionId = new URLSearchParams(window.location.search).get("session") ?? "";
  const { surface, ...dragHandlers } = useRecordingControlsLayout(sessionId);

  useEffect(() => {
    let disposed = false;
    let receivedEvent = false;
    const unlisten = onRecordingState((next) => {
      receivedEvent = true;
      if (!disposed) setState(next);
    });
    // The starting event can precede this lazy-loaded WebView. Subscribe first,
    // then hydrate; never replace a newer event with a stale snapshot.
    void unlisten.then(() => api.getRecordingState()).then((snapshot) => {
      if (!disposed && !receivedEvent) setState(snapshot);
    }).catch(() => {});
    return () => {
      disposed = true;
      void unlisten.then((dispose) => dispose()).catch(() => {});
    };
  }, []);

  // These shortcuts stay scoped to the focused control panel.
  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      const s = stateRef.current;
      if (!s) return;
      if (e.key === "Escape") {
        e.preventDefault();
        if (
          (s.isStarting || s.isRecording || s.isPaused) &&
          !s.isTransitioning && !s.isFinalizing
        ) {
          void api.stopRecording().catch(() => {});
        }
        return;
      }
      if (e.code === "Space") {
        // Prevent Space's native button click as well, including key repeats.
        e.preventDefault();
        if (e.repeat || s.isStarting || s.isTransitioning || s.isFinalizing) return;
        if (s.isPaused) void api.resumeRecording().catch(() => {});
        else if (s.isRecording) void api.pauseRecording().catch(() => {});
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, []);

  const busy = Boolean(state?.isStarting || state?.isTransitioning || state?.isFinalizing);
  const paused = Boolean(state?.isPaused);
  const hasSession = Boolean(state?.isRecording || state?.isPaused);
  const canStop = Boolean(state?.isStarting || hasSession);
  const pauseLabel = paused ? t("Resume Recording") : t("Pause Recording");

  return (
    <div ref={surface} className="kiri-record-controls-window">
      <div className="kiri-record-controls" data-paused={paused || undefined} {...dragHandlers}>
        <span className="kiri-record-controls__grip" aria-hidden="true">
          <GripVertical size={16} />
        </span>
        <button
          type="button"
          className="kiri-record-control-button"
          title={busy ? t("Preparing recording") : pauseLabel}
          aria-label={pauseLabel}
          aria-pressed={paused}
          aria-keyshortcuts="Space"
          disabled={busy || !hasSession}
          onClick={() => {
            if (paused) void api.resumeRecording().catch(() => {});
            else void api.pauseRecording().catch(() => {});
          }}
        >
          {busy
            ? <span className="kiri-record-controls__spinner" aria-hidden="true" />
            : <KiriIcon name={paused ? "play.fill" : "pause.fill"} size={17} />}
        </button>
        <span
          className="kiri-record-controls__time"
          role="timer"
          title={paused ? t("Paused") : undefined}
        >
          {state?.elapsedLabel ?? "00:00"}
        </span>
        <span className="kiri-record-controls__divider" aria-hidden="true" />
        <button
          type="button"
          className="kiri-record-control-button kiri-record-control-button--stop"
          title={state?.isStarting ? t("Cancel") : t("Stop and Save Recording")}
          aria-label={state?.isStarting ? t("Cancel") : t("Stop and Save Recording")}
          aria-keyshortcuts="Escape"
          disabled={Boolean(state?.isTransitioning || state?.isFinalizing || !canStop)}
          onClick={() => void api.stopRecording().catch(() => {})}
        >
          <KiriIcon name="stop.fill" size={12} />
          <span className="kiri-record-control-button__label">{state?.isStarting ? t("Cancel") : t("Stop Recording")}</span>
        </button>
      </div>
    </div>
  );
}

import { useCallback, useEffect, useId, useRef, useState, useSyncExternalStore } from "react";
import { ChoiceSelect } from "../components/ChoiceSelect";
import { type AppUpdater } from "./useAppUpdater";
import { KiriIcon } from "../components/KiriIcons";
import { fmt, getLanguage, languageNames, languages, onLanguageChange, setLanguage, t, type KiriLanguage } from "../i18n";
import {
  api,
  onLibraryChanged,
  type LibraryStatusDto,
  type OcrEngineRef,
  type OcrProviderProfileDto,
  type OcrProviderSettingsDto,
  type SaveOcrProviderProfileRequest,
} from "../lib/ipc";
import { OcrProfileDialog } from "./OcrProfileDialog";
import { ShortcutsSettings } from "./ShortcutsSettings";
import { DockVisibilityRow } from "./DockVisibilityRow";
import { StartupSettingsRow } from "./StartupSettingsRow";
import { SupportLinks } from "./SupportLinks";
import { OcrSettingsSection } from "./OcrSettingsSection";
import { useDialogFocusTrap } from "./useDialogFocusTrap";
import "./settings.css";

export function SettingsView({ updater }: { updater: AppUpdater }) {
  const tabs = [
    { id: "general", label: "General" },
    { id: "shortcuts", label: "Shortcuts" },
    { id: "ocr", label: "Text Recognition" },
    { id: "about", label: "About" },
  ] as const;
  type SettingsTab = typeof tabs[number]["id"];
  const [activeTab, setActiveTab] = useState<SettingsTab>(updater.hasUpdate ? "about" : "general");
  const tabButtons = useRef<Array<HTMLButtonElement | null>>([]);
  const openedWithUpdate = useRef(updater.hasUpdate);
  useEffect(() => {
    if (!openedWithUpdate.current) return;
    const heading = document.getElementById("about-settings-title");
    heading?.scrollIntoView({ block: "start" });
    heading?.focus({ preventScroll: true });
  }, []);
  const [settings, setSettings] = useState<OcrProviderSettingsDto | null>(null);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState(false);
  const [busy, setBusy] = useState(false);
  const [operationError, setOperationError] = useState<string | null>(null);
  const [editingProfile, setEditingProfile] = useState<OcrProviderProfileDto | null | undefined>();
  const [deleteTarget, setDeleteTarget] = useState<OcrProviderProfileDto | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setLoadError(false);
    try {
      setSettings(await api.getOcrProviderSettings());
    } catch {
      setLoadError(true);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  const activate = async (engine: OcrEngineRef) => {
    if (busy) return;
    setBusy(true);
    setOperationError(null);
    try {
      setSettings(await api.setActiveOcrEngine(engine));
    } catch {
      setOperationError("Couldn't change the OCR engine.");
    } finally {
      setBusy(false);
    }
  };

  const saveProfile = async (request: SaveOcrProviderProfileRequest) => {
    if (busy) return;
    setBusy(true);
    setOperationError(null);
    try {
      setSettings(await api.saveOcrProviderProfile(request));
      setEditingProfile(undefined);
    } catch {
      setOperationError("Couldn't save the OCR profile.");
    } finally {
      setBusy(false);
    }
  };

  const deleteProfile = async () => {
    if (!deleteTarget || busy) return;
    setBusy(true);
    setOperationError(null);
    try {
      setSettings(
        await api.deleteOcrProviderProfile(deleteTarget.id, deleteTarget.revision),
      );
      setDeleteTarget(null);
    } catch {
      setOperationError("Couldn't delete the OCR profile.");
    } finally {
      setBusy(false);
    }
  };

  return (
    <main className="kiri-settings" aria-label={t("Settings")}>
      <div className="kiri-settings__content">
        <nav className="kiri-settings-tabs" role="tablist" aria-label={t("Settings")}>
          {tabs.map((tab, index) => (
            <button className="kiri-settings-tab" key={tab.id} ref={(button) => { tabButtons.current[index] = button; }}
              type="button" role="tab" id={`settings-tab-${tab.id}`}
              aria-controls={`settings-panel-${tab.id}`} aria-selected={activeTab === tab.id}
              tabIndex={activeTab === tab.id ? 0 : -1}
              onClick={() => setActiveTab(tab.id)}
              onKeyDown={(event) => {
                const next = event.key === "ArrowRight" ? (index + 1) % tabs.length
                  : event.key === "ArrowLeft" ? (index + tabs.length - 1) % tabs.length
                  : event.key === "Home" ? 0 : event.key === "End" ? tabs.length - 1 : null;
                if (next === null) return;
                event.preventDefault();
                setActiveTab(tabs[next].id);
                tabButtons.current[next]?.focus();
              }}>
              {t(tab.label)}
              {tab.id === "about" && updater.hasUpdate && <span className="kiri-settings-tab-dot" aria-label={t("Update available")} />}
            </button>
          ))}
        </nav>
        <div className="kiri-settings-panel" role="tabpanel" id={`settings-panel-${activeTab}`}
          aria-labelledby={`settings-tab-${activeTab}`} tabIndex={0}>
        {activeTab === "general" && <GeneralSettingsSection />}
        {activeTab === "shortcuts" && <ShortcutsSettings />}
        {activeTab === "ocr" && <>
        {operationError && (
          <div className="kiri-settings-alert kiri-settings-alert--error" role="alert">
            {t(operationError)}
          </div>
        )}

        {loading ? (
          <div className="kiri-settings-card kiri-settings-loading" role="status">
            <span className="kiri-settings-spinner" aria-hidden="true" />
            {t("Loading OCR settings…")}
          </div>
        ) : loadError || !settings ? (
          <div className="kiri-settings-card kiri-settings-empty-state" role="alert">
            <KiriIcon name="text.viewfinder" size={24} />
            <strong>{t("Couldn't load OCR settings")}</strong>
            <span>{t("Local OCR remains available while you try again.")}</span>
            <button
              type="button"
              className="kiri-button kiri-button--secondary"
              onClick={() => void load()}
            >
              {t("Retry")}
            </button>
          </div>
        ) : (
          <OcrSettingsSection
            settings={settings}
            busy={busy}
            onActivate={(engine) => void activate(engine)}
            onAdd={() => {
              setOperationError(null);
              setEditingProfile(null);
            }}
            onEdit={(profile) => {
              setOperationError(null);
              setEditingProfile(profile);
            }}
            onDelete={(profile) => {
              setOperationError(null);
              setDeleteTarget(profile);
            }}
          />
        )}

        </>}
        {activeTab === "about" && <AboutSettingsSection updater={updater} />}
        </div>
      </div>

      {editingProfile !== undefined && (
        <OcrProfileDialog
          profile={editingProfile}
          busy={busy}
          error={operationError ? t(operationError) : null}
          onCancel={() => {
            if (!busy) {
              setEditingProfile(undefined);
              setOperationError(null);
            }
          }}
          onSave={(request) => void saveProfile(request)}
        />
      )}

      {deleteTarget && (
        <DeleteProfileDialog
          profile={deleteTarget}
          active={
            settings?.activeEngine.kind === "profile" &&
            settings.activeEngine.profileId === deleteTarget.id
          }
          busy={busy}
          error={operationError ? t(operationError) : null}
          onCancel={() => {
            if (!busy) {
              setDeleteTarget(null);
              setOperationError(null);
            }
          }}
          onDelete={() => void deleteProfile()}
        />
      )}
    </main>
  );
}

function AboutSettingsSection({ updater }: { updater: AppUpdater }) {
  const [copyState, setCopyState] = useState<"idle" | "copying" | "copied" | "error">("idle");
  const [cacheState, setCacheState] = useState<"idle" | "busy" | { removed: number } | "error">("idle");
  const clearing = useRef(false);
  const clearCache = async () => {
    if (clearing.current) return;
    clearing.current = true;
    setCacheState("busy");
    try { setCacheState({ removed: await api.clearImageCache() }); }
    catch { setCacheState("error"); }
    finally { clearing.current = false; }
  };
  const copying = useRef(false);
  useEffect(() => {
    if (copyState !== "copied") return;
    const timer = window.setTimeout(() => setCopyState("idle"), 1800);
    return () => window.clearTimeout(timer);
  }, [copyState]);
  const copyInfo = async () => {
    if (copying.current) return;
    copying.current = true;
    setCopyState("copying");
    try { await api.copySupportInfo(); setCopyState("copied"); }
    catch { setCopyState("error"); }
    finally { copying.current = false; }
  };
  const { currentVersion, isWindows } = updater;

  return (
    <section className="kiri-settings-section kiri-settings-section--about" aria-labelledby="about-settings-title">
      <div className="kiri-settings-section__heading">
        <div>
          <h2 id="about-settings-title" tabIndex={-1}>{t(updater.hasUpdate ? "Update available" : "About")}</h2>
        </div>
      </div>
      <div className="kiri-settings-card kiri-version-row">
        <div className="kiri-update-copy">
          <div className="kiri-version-title">
            <strong>Lumen</strong>
            <span className="kiri-settings-badge">
              {fmt("Version %@", currentVersion ? `v${currentVersion}` : "—")}
            </span>
          </div>
        </div>
          <div className="kiri-support-actions" role="group" aria-label={t("About")}>
          <button type="button" className="kiri-button kiri-button--secondary"
            disabled={copyState === "copying"} aria-label={t("Copy Info")}
            onClick={() => void copyInfo()}>
            <KiriIcon name={copyState === "copied" ? "checkmark" : "doc.on.doc"} size={15} />
            <span aria-live="polite">{t(copyState === "copied" ? "Copied" : "Copy Info")}</span>
          </button>
          {copyState === "error" && <span className="kiri-support-copy-status" role="alert">{t("Couldn't copy info. Try again.")}</span>}
          <SupportLinks isWindows={isWindows} />
          <button type="button" className="kiri-button kiri-button--secondary"
            disabled={cacheState === "busy"} onClick={() => void clearCache()}>
            {t(cacheState === "busy" ? "Clearing…" : "Clear Image Cache")}
          </button>
          {cacheState === "error" && (
            <span className="kiri-support-copy-status" role="alert">{t("Couldn't clear the image cache. Try again.")}</span>
          )}
          {typeof cacheState === "object" && cacheState !== null && (
            <span className="kiri-support-copy-status" role="status">
              {cacheState.removed === 0
                ? t("No cached images to clear")
                : fmt("%d images removed", cacheState.removed)}
            </span>
          )}
        </div>
      </div>
    </section>
  );
}

function GeneralSettingsSection() {
  const language = useSyncExternalStore(onLanguageChange, getLanguage);
  const [languageBusy, setLanguageBusy] = useState(false);
  const [languageError, setLanguageError] = useState(false);
  const [libraryStatus, setLibraryStatus] = useState<LibraryStatusDto | null>(null);
  const [libraryLoadError, setLibraryLoadError] = useState(false);
  const [libraryBusy, setLibraryBusy] = useState(false);
  const [libraryOperationError, setLibraryOperationError] = useState<string | null>(null);
  const libraryStatusGeneration = useRef(0);

  const loadLibraryStatus = useCallback(async (clearOperationErrorOnSuccess = false) => {
    const generation = ++libraryStatusGeneration.current;
    try {
      const status = await api.getLibraryStatus();
      if (generation !== libraryStatusGeneration.current) return;
      setLibraryStatus(status);
      setLibraryLoadError(false);
      if (clearOperationErrorOnSuccess) setLibraryOperationError(null);
    } catch {
      if (generation !== libraryStatusGeneration.current) return;
      setLibraryLoadError(true);
    }
  }, []);

  useEffect(() => {
    void loadLibraryStatus();
    const subscription = onLibraryChanged(() => {
      void loadLibraryStatus();
    });
    return () => {
      void subscription.then((dispose) => dispose()).catch(() => {});
    };
  }, [loadLibraryStatus]);

  const switchTo = async (next: KiriLanguage) => {
    if (languageBusy) return;
    setLanguageBusy(true);
    setLanguageError(false);
    try {
      await api.setLanguage(next);
      setLanguage(next);
    } catch {
      setLanguageError(true);
    } finally {
      setLanguageBusy(false);
    }
  };

  const runLibraryAction = async (
    action: () => Promise<unknown>,
    errorMessage: "Couldn't open folder" | "Couldn't update location",
  ) => {
    if (libraryBusy) return;
    setLibraryBusy(true);
    setLibraryOperationError(null);
    try {
      await action();
      await loadLibraryStatus(true);
    } catch {
      setLibraryOperationError(errorMessage);
      await loadLibraryStatus();
    } finally {
      setLibraryBusy(false);
    }
  };

  const statusLabel = libraryLoadError
    ? t("Unavailable")
    : libraryStatus?.availability === "migrating"
      ? t("Moving…")
      : libraryStatus?.availability === "unavailable"
        ? t("Unavailable")
        : null;
  const locationLabel = libraryStatus
    ? libraryStatus.isDefault
      ? t("Default")
      : libraryStatus.locationLabel
    : libraryLoadError
      ? t("Couldn't load location")
      : "—";

  return (
    <section className="kiri-settings-section kiri-settings-section--general" aria-labelledby="general-settings-title">
      <div className="kiri-settings-section__heading">
        <div>
          <h2 id="general-settings-title">{t("General")}</h2>
        </div>
      </div>
      <div className="kiri-settings-group">
      <div className="kiri-settings-card kiri-language-row">
        <div>
          <strong>{t("Language")}</strong>
          <span>{t("Changes apply to every Lumen window.")}</span>
          {languageError && <span role="alert">{t("Could not save the language preference.")}</span>}
        </div>
        <ChoiceSelect
          className="kiri-language-select"
          menuClassName="kiri-language-menu"
          menuMinWidth={220}
          label={t("Language")}
          value={language}
          disabled={languageBusy}
          onChange={(next) => { if (next !== language) void switchTo(next); }}
          options={languages.map((item) => ({ value: item, label: languageNames[item] }))}
        />
      </div>
      <DockVisibilityRow />
      <StartupSettingsRow />
      <div className="kiri-settings-card kiri-storage-row">
        <div className="kiri-storage-copy">
          <div className="kiri-storage-title">
            <strong>{t("Library Location")}</strong>
            {statusLabel && <span className="kiri-settings-badge">{statusLabel}</span>}
          </div>
          <span title={locationLabel}>{locationLabel}</span>
          {libraryOperationError && (
            <span className="kiri-storage-error" role="alert">
              {t(libraryOperationError)}
            </span>
          )}
        </div>
        <div className="kiri-storage-actions">
          {libraryLoadError ? (
            <button
              type="button"
              className="kiri-button kiri-button--secondary"
              disabled={libraryBusy}
              onClick={() => {
                setLibraryOperationError(null);
                void loadLibraryStatus(true);
              }}
            >
              {t("Retry")}
            </button>
          ) : libraryStatus?.availability === "ready" ? (
            <>
              <button
                type="button"
                className="kiri-button kiri-button--secondary"
                disabled={libraryBusy}
                onClick={() =>
                  void runLibraryAction(api.revealLibrary, "Couldn't open folder")
                }
              >
                {t("Open Folder")}
              </button>
              <button
                type="button"
                className="kiri-button kiri-button--secondary"
                disabled={libraryBusy}
                onClick={() =>
                  void runLibraryAction(api.chooseLibraryLocation, "Couldn't update location")
                }
              >
                {t("Change…")}
              </button>
              {!libraryStatus.isDefault && (
                <button
                  type="button"
                  className="kiri-button kiri-button--secondary"
                  disabled={libraryBusy}
                  onClick={() =>
                    void runLibraryAction(api.restoreDefaultLibrary, "Couldn't update location")
                  }
                >
                  {t("Restore Default")}
                </button>
              )}
            </>
          ) : libraryStatus?.availability === "unavailable" ? (
            <>
              <button
                type="button"
                className="kiri-button kiri-button--secondary"
                disabled={libraryBusy}
                onClick={() =>
                  void runLibraryAction(api.retryLibrary, "Couldn't update location")
                }
              >
                {t("Retry")}
              </button>
              <button
                type="button"
                className="kiri-button kiri-button--secondary"
                disabled={libraryBusy}
                onClick={() =>
                  void runLibraryAction(api.locateLibrary, "Couldn't update location")
                }
              >
                {t("Locate…")}
              </button>
            </>
          ) : null}
        </div>
      </div>
      </div>
    </section>
  );
}

function DeleteProfileDialog({
  profile,
  active,
  busy,
  error,
  onCancel,
  onDelete,
}: {
  profile: OcrProviderProfileDto;
  active: boolean;
  busy: boolean;
  error: string | null;
  onCancel(): void;
  onDelete(): void;
}) {
  const titleId = useId();
  const dialogRef = useDialogFocusTrap<HTMLDivElement>();
  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape" && !busy) {
        event.preventDefault();
        onCancel();
      } else if (event.key === "Enter" || event.key === "Return") {
        // Destructive actions are intentionally never bound to Return.
        event.preventDefault();
      }
    };
    window.addEventListener("keydown", onKeyDown, true);
    return () => window.removeEventListener("keydown", onKeyDown, true);
  }, [busy, onCancel]);

  return (
    <div className="kiri-settings-dialog-backdrop">
      <div
        ref={dialogRef}
        className="kiri-settings-dialog kiri-settings-dialog--compact"
        role="alertdialog"
        aria-modal="true"
        aria-labelledby={titleId}
        tabIndex={-1}
      >
        <h2 id={titleId}>{t("Delete OCR Profile?")}</h2>
        <p>{fmt("The profile “%@” and its saved API key will be removed.", profile.name)}</p>
        {active && <p>{t("Lumen will switch back to Local OCR after deletion.")}</p>}
        {error && (
          <div className="kiri-settings-form-error" role="alert">
            {error}
          </div>
        )}
        <div className="kiri-settings-dialog__actions">
          <button
            type="button"
            className="kiri-button kiri-button--secondary"
            onClick={onCancel}
            disabled={busy}
            autoFocus
          >
            {t("Cancel")}
          </button>
          <button
            type="button"
            className="kiri-button kiri-button--destructive kiri-button--destructive-fill"
            onClick={onDelete}
            disabled={busy}
          >
            {busy ? t("Deleting…") : t("Delete Profile")}
          </button>
        </div>
      </div>
    </div>
  );
}

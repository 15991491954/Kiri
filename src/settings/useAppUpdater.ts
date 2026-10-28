import { useEffect, useState } from "react";
import { getVersion } from "@tauri-apps/api/app";

/**
 * Read-only application information for the About section.
 *
 * Lumen no longer contacts a remote update service: there is no periodic or
 * on-open check, no download, and no install action. This hook only reports
 * the running version so support information and the About header stay
 * accurate.
 */
export type AppUpdater = {
  currentVersion: string;
  isWindows: boolean;
  hasUpdate: false;
};

export function useAppUpdater(): AppUpdater {
  const [currentVersion, setCurrentVersion] = useState("");
  const isWindows = /Windows/i.test(navigator.userAgent);

  useEffect(() => {
    let active = true;
    void getVersion()
      .then((version) => { if (active) setCurrentVersion(version); })
      .catch(() => {});
    return () => { active = false; };
  }, []);

  return { currentVersion, isWindows, hasUpdate: false };
}
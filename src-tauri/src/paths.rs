//! Application data locations and the one-time migration from the old names.
//!
//! The product is Lumen, so every folder the user can find uses that name:
//! `%APPDATA%\Lumen` (library plus `Settings`), `%LOCALAPPDATA%\Lumen\logs`,
//! and `Lumen Library` for a managed library. Old `kiri` folders are copied
//! forward once, never deleted, so an existing library and preferences keep
//! working after the rename.

use std::path::{Path, PathBuf};

use tauri::AppHandle;

/// Roaming folder that holds the library and the settings subfolder.
pub const APP_DIRECTORY: &str = "Lumen";
/// Settings live in a subfolder so they never mix with library assets.
pub const SETTINGS_DIRECTORY: &str = "Settings";
/// Legacy roaming folder that was the library root.
const LEGACY_LIBRARY_DIRECTORY: &str = "kiri";
/// Legacy bundle-identifier folder that held settings and local caches.
const LEGACY_IDENTIFIER_DIRECTORY: &str = "io.yuxino.kiri";
/// Legacy managed library folder inside a user-selected parent.
const LEGACY_MANAGED_LIBRARY_DIRECTORY: &str = "Kiri Library";

pub fn roaming_root() -> Option<PathBuf> {
    dirs::data_dir().map(|directory| directory.join(APP_DIRECTORY))
}

pub fn local_root() -> Option<PathBuf> {
    dirs::data_local_dir().map(|directory| directory.join(APP_DIRECTORY))
}

pub fn config_dir(_app: &AppHandle) -> Option<PathBuf> {
    roaming_root().map(|root| root.join(SETTINGS_DIRECTORY))
}

pub fn log_dir() -> Option<PathBuf> {
    local_root().map(|root| root.join("logs"))
}

/// Copies files from every legacy location into the new tree.
///
/// Existing files in the new tree always win, so a partially migrated install
/// can never be rolled back to older data. Failures are non-fatal: the app
/// keeps working with whatever it can read, and the legacy folder stays intact
/// as a fallback.
pub fn migrate_legacy_directories() {
    let Some(roaming) = dirs::data_dir() else { return };
    let Some(local) = dirs::data_local_dir() else { return };
    let target = roaming.join(APP_DIRECTORY);
    let settings = target.join(SETTINGS_DIRECTORY);
    // The old shared folder mixed the library and the settings. Split them so
    // the new tree has one obvious place for each.
    copy_library_tree(&roaming.join(LEGACY_LIBRARY_DIRECTORY), &target, &settings);
    // Settings, capture mode, appearance and shortcut bindings.
    merge_tree(&roaming.join(LEGACY_IDENTIFIER_DIRECTORY), &settings);
    // Logs and in-flight recording recovery.
    merge_tree(
        &local.join(LEGACY_IDENTIFIER_DIRECTORY),
        &local.join(APP_DIRECTORY),
    );
    // Repair an earlier partial migration that left settings beside the library.
    relocate_settings(&target, &settings);
    rewrite_library_root(&settings, &roaming.join(LEGACY_LIBRARY_DIRECTORY), &target);
    restore_library_marker(&target, &settings);
    migrate_managed_library_directory(&target);
}

/// Copies an old mixed folder, routing preference files into `settings`.
fn copy_library_tree(source: &Path, library: &Path, settings: &Path) {
    let Ok(entries) = std::fs::read_dir(source) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        let name = entry.file_name();
        let name_text = name.to_string_lossy();
        match entry.file_type() {
            Ok(kind) if kind.is_dir() => merge_tree(&path, &library.join(&name)),
            Ok(kind) if kind.is_file() => {
                let is_preference = name_text.ends_with(".json")
                    && name_text != "library.json"
                    && !name_text.starts_with('.');
                let destination = if is_preference {
                    settings.join(&name)
                } else {
                    library.join(&name)
                };
                if !destination.exists() {
                    let _ = std::fs::create_dir_all(destination.parent().unwrap_or(library));
                    let _ = std::fs::copy(&path, &destination);
                }
            }
            _ => {}
        }
    }
}

/// Moves preference JSON files left at the library root by an earlier build.
fn relocate_settings(library: &Path, settings: &Path) {
    let Ok(entries) = std::fs::read_dir(library) else { return };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let name_text = name.to_string_lossy();
        if !name_text.ends_with(".json") || name_text == "library.json" {
            continue;
        }
        let destination = settings.join(&name);
        if !destination.exists() {
            let _ = std::fs::create_dir_all(settings);
            let _ = std::fs::rename(entry.path(), &destination)
                .or_else(|_| std::fs::copy(entry.path(), &destination).map(|_| ()));
        }
    }
}

/// Repoints a stored library location at the renamed folder.
fn rewrite_library_root(settings: &Path, legacy: &Path, target: &Path) {
    let path = settings.join("library-location.json");
    let Ok(bytes) = std::fs::read(&path) else { return };
    let Ok(mut value) = serde_json::from_slice::<serde_json::Value>(&bytes) else { return };
    let Some(root) = value.get("root").and_then(|root| root.as_str()) else { return };
    if Path::new(root) != legacy {
        return;
    }
    value["root"] = serde_json::Value::String(target.to_string_lossy().into_owned());
    if let Ok(encoded) = serde_json::to_vec_pretty(&value) {
        let _ = std::fs::write(&path, encoded);
    }
}

/// Puts the library identity marker back at the library root.
///
/// An earlier build routed every `.json` from the old shared folder into
/// `Settings`, including the hidden `.kiri-library.json` marker. Without that
/// marker at the library root the library refuses to open ("library storage is
/// unavailable"), so captures, pins and the library list all stop working.
fn restore_library_marker(library: &Path, settings: &Path) {
    let marker = library.join(".kiri-library.json");
    if marker.exists() {
        return;
    }
    let misplaced = settings.join(".kiri-library.json");
    if misplaced.is_file() {
        let _ = std::fs::rename(&misplaced, &marker)
            .or_else(|_| std::fs::copy(&misplaced, &marker).map(|_| ()));
    }
}
/// Renames a managed library created under the old product name.
fn migrate_managed_library_directory(root: &Path) {
    let legacy = root.join(LEGACY_MANAGED_LIBRARY_DIRECTORY);
    let current = root.join(crate::core::library_location::MANAGED_LIBRARY_DIRECTORY_NAME);
    if legacy.is_dir() && !current.exists() {
        let _ = std::fs::rename(&legacy, &current);
    }
}

fn merge_tree(source: &Path, destination: &Path) {
    let Ok(entries) = std::fs::read_dir(source) else { return };
    if std::fs::create_dir_all(destination).is_err() {
        return;
    }
    for entry in entries.flatten() {
        let path = entry.path();
        let target = destination.join(entry.file_name());
        match entry.file_type() {
            Ok(kind) if kind.is_dir() => merge_tree(&path, &target),
            Ok(kind) if kind.is_file() => {
                if !target.exists() {
                    let _ = std::fs::copy(&path, &target);
                }
            }
            _ => {}
        }
    }
}

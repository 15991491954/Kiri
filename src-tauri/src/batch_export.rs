//! Explicit batch copies of visible library files into a user-picked folder.

use std::collections::HashSet;
use std::fs::{File, OpenOptions};
use std::io;
use std::path::Path;

use serde::Serialize;
use tauri::{AppHandle, Manager, WebviewWindow};
use tauri_plugin_dialog::DialogExt;

use crate::state::AppState;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BatchExportResult {
    exported: usize,
    failed: Vec<String>,
}

fn copy_without_overwrite(source: &mut File, folder: &Path, filename: &str) -> io::Result<()> {
    let path = Path::new(filename);
    let stem = path.file_stem().and_then(|part| part.to_str()).ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "invalid filename"))?;
    let extension = path.extension().and_then(|part| part.to_str()).ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "invalid extension"))?;
    for suffix in 1..=1000 {
        let name = if suffix == 1 { filename.to_string() } else { format!("{stem} ({suffix}).{extension}") };
        let destination = folder.join(name);
        let mut output = match OpenOptions::new().write(true).create_new(true).open(&destination) {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error),
        };
        let result = (|| {
            io::copy(source, &mut output)?;
            output.sync_all()
        })();
        if result.is_err() { let _ = std::fs::remove_file(&destination); }
        return result;
    }
    Err(io::Error::new(io::ErrorKind::AlreadyExists, "too many files with this name"))
}

#[tauri::command]
pub async fn export_selected_assets(
    window: WebviewWindow,
    app: AppHandle,
    ids: Vec<String>,
) -> Result<Option<BatchExportResult>, String> {
    if window.label() != "library" { return Err("Only the library can export selected files.".into()); }
    if ids.is_empty() || ids.len() > 500 { return Err("Select between 1 and 500 files.".into()); }
    let parsed = ids.iter().map(|id| uuid::Uuid::parse_str(id).map_err(|_| "Invalid selection.".to_string())).collect::<Result<Vec<_>, _>>()?;
    if parsed.iter().copied().collect::<HashSet<_>>().len() != parsed.len() {
        return Err("The selection contains duplicate files.".into());
    }
    let dialog_app = app.clone();
    let folder = tauri::async_runtime::spawn_blocking(move || {
        dialog_app.dialog().file().blocking_pick_folder().and_then(|path| path.into_path().ok())
    }).await.map_err(|error| format!("Could not open the folder picker: {error}"))?;
    let Some(folder) = folder else { return Ok(None); };
    tauri::async_runtime::spawn_blocking(move || {
        if !std::fs::symlink_metadata(&folder).map_err(|error| error.to_string())?.file_type().is_dir() {
            return Err("The selected destination is not a folder.".into());
        }
        let state = app.state::<AppState>();
        let (mut files, mut failed) = {
            let mut context = state.library.lock().unwrap();
            let library = context.library().map_err(|error| error.to_string())?;
            let mut files = Vec::new();
            let mut failed = Vec::new();
            for id in parsed {
                let Some(asset) = library.asset_by_id(&id) else { failed.push(id.to_string()); continue; };
                if asset.trashed_at.is_some() {
                    failed.push(asset.filename.clone()); continue;
                }
                match library.readable_asset_url(asset).and_then(|path| File::open(path).map_err(Into::into)) {
                    Ok(source) => files.push((asset.filename.clone(), source)),
                    Err(_) => failed.push(asset.filename.clone()),
                }
            }
            (files, failed)
        };
        let mut exported = 0;
        for (filename, mut source) in files.drain(..) {
            if copy_without_overwrite(&mut source, &folder, &filename).is_ok() { exported += 1; }
            else { failed.push(filename); }
        }
        Ok(Some(BatchExportResult { exported, failed }))
    }).await.map_err(|_| "Export stopped unexpectedly.".to_string())?
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn existing_file_is_never_overwritten() {
        let folder = tempfile::tempdir().unwrap();
        let source_path = folder.path().join("source");
        std::fs::write(&source_path, b"new").unwrap();
        std::fs::write(folder.path().join("capture.png"), b"old").unwrap();
        copy_without_overwrite(&mut File::open(source_path).unwrap(), folder.path(), "capture.png").unwrap();
        assert_eq!(std::fs::read(folder.path().join("capture.png")).unwrap(), b"old");
        assert_eq!(std::fs::read(folder.path().join("capture (2).png")).unwrap(), b"new");
    }
}

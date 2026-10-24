//! Reading pins out of the Windows clipboard.
//!
//! Everything here runs on a blocking worker: `arboard` opens the clipboard,
//! and decoding a copied PNG or laying out a text card is not work the message
//! loop or the UI thread may do. The clipboard itself is only held for the
//! duration of the read; a pin never keeps a lock on it.

use std::path::Path;
use std::time::Duration;

use anyhow::{anyhow, bail, Result};

use super::clipboard_source::{self, ClipboardSource};
use super::text_image;
use super::{PinImage, MAX_PIN_SOURCE_BYTES};

/// The clipboard is a shared, contention-prone resource: another process may
/// hold it for a few milliseconds while it copies.
const ATTEMPTS: usize = 3;
const RETRY_DELAY: Duration = Duration::from_millis(60);

/// One image ready to become a pin. Clipboard pins are snapshots: they keep no
/// link to the clipboard, the source file, or the library.
pub struct ClipboardPin {
    pub image: PinImage,
}

/// Reads the best payload the clipboard offers.
///
/// `budget_bytes` is what remains of the decoded-image budget; a payload that
/// would exceed it is rejected before it is decoded so a copied 8K bitmap does
/// not allocate first and fail second. `scale` is the destination display's
/// factor, used only by text cards, which are measured in DIP.
pub fn read_sources(scale: f64, budget_bytes: u64) -> Result<Vec<ClipboardPin>, String> {
    let mut last_error = None;
    for attempt in 0..ATTEMPTS {
        match read_once(scale, budget_bytes) {
            Ok(pins) => return Ok(pins),
            Err(error) => {
                last_error = Some(error);
                if attempt + 1 < ATTEMPTS {
                    std::thread::sleep(RETRY_DELAY);
                }
            }
        }
    }
    Err(last_error
        .map(|error| error.to_string())
        .unwrap_or_else(|| "Could not read the clipboard right now.".into()))
}

fn read_once(scale: f64, budget_bytes: u64) -> Result<Vec<ClipboardPin>> {
    let mut clipboard =
        arboard::Clipboard::new().map_err(|_| anyhow!("Could not read the clipboard right now."))?;
    let bitmap = clipboard.get_image().ok();
    let files = clipboard.get().file_list().ok();
    let text = clipboard.get_text().ok();
    // Release the clipboard before decoding anything.
    drop(clipboard);

    let source = clipboard_source::choose(
        bitmap.is_some(),
        files,
        text.as_deref(),
    )
    .ok_or_else(|| anyhow!("The clipboard has no image or text to pin."))?;

    match source {
        ClipboardSource::Image => {
            let bitmap = bitmap.ok_or_else(|| anyhow!("Could not read the clipboard right now."))?;
            Ok(vec![ClipboardPin {
                image: image_from_bitmap(bitmap, budget_bytes)?,
            }])
        }
        ClipboardSource::Files(files) => {
            let mut pins = Vec::with_capacity(files.len());
            let mut remaining = budget_bytes;
            for file in files {
                let image = image_from_file(&file, remaining)?;
                remaining = remaining.saturating_sub(image.bytes());
                pins.push(ClipboardPin { image });
            }
            if pins.is_empty() {
                bail!("The clipboard has no image or text to pin.");
            }
            Ok(pins)
        }
        ClipboardSource::Text(text) => {
            ensure_budget(text_len_bytes(&text), budget_bytes)?;
            let image = text_image::render_card(&text, scale)?;
            Ok(vec![ClipboardPin { image }])
        }
    }
}

fn text_len_bytes(text: &str) -> u64 {
    // Text cards are a small multiple of the string: one opaque pixel per
    // character cell plus padding. This is only a pre-check; the rendered card
    // is measured exactly afterwards.
    (text.chars().count() as u64)
        .saturating_mul(1024)
        .max(64 * 1024)
}

fn ensure_budget(bytes: u64, budget_bytes: u64) -> Result<()> {
    if bytes > budget_bytes.min(MAX_PIN_SOURCE_BYTES) {
        bail!("Close a pinned image before pinning another.");
    }
    Ok(())
}

fn image_from_bitmap(bitmap: arboard::ImageData<'_>, budget_bytes: u64) -> Result<PinImage> {
    let bytes = (bitmap.width as u64)
        .saturating_mul(bitmap.height as u64)
        .saturating_mul(4);
    ensure_budget(bytes, budget_bytes)?;
    PinImage::from_rgba(bitmap.width as u32, bitmap.height as u32, bitmap.bytes.as_ref())
        .ok_or_else(|| anyhow!("The clipboard image could not be pinned."))
}

fn image_from_file(path: &Path, budget_bytes: u64) -> Result<PinImage> {
    if !clipboard_source::is_image_path(path) {
        bail!("The clipboard has no image or text to pin.");
    }
    // Measure before decoding: a decompression bomb must not allocate first.
    let (width, height) = image::image_dimensions(path)
        .map_err(|_| anyhow!("The copied image could not be opened."))?;
    let bytes = u64::from(width).saturating_mul(u64::from(height)).saturating_mul(4);
    ensure_budget(bytes, budget_bytes)?;
    let decoded = image::open(path).map_err(|_| anyhow!("The copied image could not be opened."))?;
    let rgba = decoded.to_rgba8();
    PinImage::from_rgba(rgba.width(), rgba.height(), rgba.as_raw())
        .ok_or_else(|| anyhow!("The copied image could not be pinned."))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn budget_is_measured_before_decoding_and_never_exceeds_the_cap() {
        assert!(ensure_budget(1024, 2048).is_ok());
        assert!(ensure_budget(4096, 2048).is_err());
        // A caller-supplied budget larger than the global cap is still capped.
        assert!(ensure_budget(MAX_PIN_SOURCE_BYTES + 1, u64::MAX).is_err());
    }

    #[test]
    fn text_budget_grows_with_the_string() {
        let short = text_len_bytes("hello");
        let long = text_len_bytes(&"汉".repeat(5_000));
        assert!(short >= 64 * 1024);
        assert!(long > short);
    }

    #[test]
    fn non_image_paths_are_refused_before_any_io() {
        assert!(image_from_file(Path::new(r"C:\missing\notes.pdf"), 1024).is_err());
        assert!(image_from_file(Path::new(r"C:\missing\shot.png"), 1024).is_err());
    }
}

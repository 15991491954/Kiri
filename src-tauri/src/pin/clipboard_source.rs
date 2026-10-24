//! What the clipboard offers, and which offer wins.
//!
//! The choice is a pure function so it can be tested without a clipboard:
//! image > image files > text. Files are filtered by extension because a
//! copied folder or a PDF must not become a broken pin.

use std::path::{Path, PathBuf};

/// A pasted burst creates a cascade; more than this is almost always a misdrag
/// over a folder of screenshots.
pub const MAX_FILES: usize = 16;

pub const IMAGE_EXTENSIONS: &[&str] = &["png", "jpg", "jpeg", "webp", "gif", "bmp"];

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ClipboardSource {
    /// A bitmap (with or without accompanying text).
    Image,
    Files(Vec<PathBuf>),
    Text(String),
}

pub fn is_image_path(path: &Path) -> bool {
    path.extension()
        .and_then(|extension| extension.to_str())
        .is_some_and(|extension| {
            IMAGE_EXTENSIONS
                .iter()
                .any(|known| extension.eq_ignore_ascii_case(known))
        })
}

/// Picks the payload to pin. `None` means the clipboard has nothing usable.
pub fn choose(
    has_image: bool,
    files: Option<Vec<PathBuf>>,
    text: Option<&str>,
) -> Option<ClipboardSource> {
    if has_image {
        return Some(ClipboardSource::Image);
    }
    if let Some(files) = files {
        let mut images: Vec<PathBuf> = Vec::new();
        for file in files.into_iter().filter(|path| is_image_path(path)) {
            if images.len() >= MAX_FILES {
                break;
            }
            if !images.contains(&file) {
                images.push(file);
            }
        }
        if !images.is_empty() {
            return Some(ClipboardSource::Files(images));
        }
    }
    let text = text?.trim();
    if text.is_empty() {
        return None;
    }
    Some(ClipboardSource::Text(text.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn files(names: &[&str]) -> Vec<PathBuf> {
        names.iter().map(PathBuf::from).collect()
    }

    #[test]
    fn an_image_wins_over_text_and_files() {
        let chosen = choose(
            true,
            Some(files(&[r"C:\shot.png"])),
            Some("hello"),
        );
        assert_eq!(chosen, Some(ClipboardSource::Image));
    }

    #[test]
    fn image_files_win_over_text_and_keep_their_order() {
        let chosen = choose(
            false,
            Some(files(&[r"C:\b.PNG", r"C:\notes.txt", r"C:\a.jpeg"])),
            Some("hello"),
        );
        assert_eq!(
            chosen,
            Some(ClipboardSource::Files(files(&[r"C:\b.PNG", r"C:\a.jpeg"])))
        );
    }

    #[test]
    fn only_non_image_files_falls_through_to_text() {
        assert_eq!(
            choose(false, Some(files(&[r"C:\a.pdf"])), Some(" hello ")),
            Some(ClipboardSource::Text("hello".into()))
        );
    }

    #[test]
    fn nothing_usable_is_none() {
        assert_eq!(choose(false, None, None), None);
        assert_eq!(choose(false, Some(files(&[r"C:\a.pdf"])), Some("   ")), None);
        assert_eq!(choose(false, Some(Vec::new()), Some("")), None);
    }

    #[test]
    fn a_cascade_is_bounded_and_deduplicated() {
        let mut names = Vec::new();
        for index in 0..(MAX_FILES + 5) {
            names.push(format!("C:\\shot-{index}.png"));
        }
        let mut list = files(&names.iter().map(String::as_str).collect::<Vec<_>>());
        list.push(PathBuf::from("C:\\shot-0.png"));
        match choose(false, Some(list), None).unwrap() {
            ClipboardSource::Files(found) => {
                assert_eq!(found.len(), MAX_FILES);
                assert_eq!(found[0], PathBuf::from("C:\\shot-0.png"));
            }
            other => panic!("unexpected {other:?}"),
        }
    }

    #[test]
    fn extensions_are_case_insensitive_and_complete() {
        for name in ["a.png", "a.JPG", "a.JpEg", "a.webp", "a.gif", "a.bmp"] {
            assert!(is_image_path(Path::new(name)), "{name}");
        }
        for name in ["a.svg", "a.pdf", "a", "a.png.txt"] {
            assert!(!is_image_path(Path::new(name)), "{name}");
        }
    }
}

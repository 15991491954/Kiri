//! Text pins: a clipboard string becomes a small opaque card.
//!
//! Windows renders the card with GDI `DrawTextW` (no extra text-shaping crate).
//! The card body is opaque, so GDI's lack of alpha output never shows: only the
//! rounded corners are transparent, and those are masked in the pixel buffer.

use anyhow::Result;

use super::PinImage;

/// A pasted document is not a pin. The cap bounds the GDI layout work.
pub const MAX_CHARS: usize = 20_000;
/// A whitespace-free run longer than this is broken by hand. GDI's
/// `DT_WORDBREAK` only breaks between words, so a copied URL or a base64 blob
/// would otherwise be clipped at the card edge instead of wrapping.
pub const SOFT_BREAK_CHARS: usize = 48;
/// Card width in display-independent pixels before padding.
const MAX_WIDTH_DIP: f64 = 480.0;
const PADDING_DIP: f64 = 12.0;
const FONT_DIP: f64 = 14.0;
const MAX_HEIGHT_DIP: f64 = 1200.0;
const RADIUS_DIP: f64 = 8.0;
/// Cards float over arbitrary desktops, so they keep one dark body with light
/// text instead of following the application theme.
const CARD_RGB: (u8, u8, u8) = (32, 32, 32);
const TEXT_RGB: (u8, u8, u8) = (245, 245, 245);

/// Normalizes line endings, bounds the string, and marks a truncated document.
/// Truncation happens on a character boundary so a pasted emoji cannot split
/// into invalid UTF-16.
pub fn sanitize(text: &str) -> String {
    let normalized = text.replace("\r\n", "\n").replace('\r', "\n");
    let mut truncated = String::with_capacity(normalized.len().min(MAX_CHARS * 3));
    let mut characters = normalized.chars();
    let mut count = 0usize;
    let mut clipped = false;
    while let Some(character) = characters.next() {
        if count == MAX_CHARS - 1 {
            if characters.next().is_some() {
                clipped = true;
                break;
            }
        }
        truncated.push(character);
        count += 1;
    }
    if clipped {
        truncated.push('…');
    }
    insert_soft_breaks(truncated.trim_end())
}

/// Breaks whitespace-free runs so GDI wraps instead of clipping them.
///
/// Lines the user typed are preserved. Only a run longer than
/// [`SOFT_BREAK_CHARS`] gains hard breaks; CJK already wraps per character, so
/// the threshold is beyond its natural line length and changes nothing.
pub fn insert_soft_breaks(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + text.len() / SOFT_BREAK_CHARS + 8);
    for (line_index, line) in text.split('\n').enumerate() {
        if line_index > 0 {
            out.push('\n');
        }
        let mut run = 0usize;
        for character in line.chars() {
            if character.is_whitespace() {
                run = 0;
            } else {
                run += 1;
                if run > SOFT_BREAK_CHARS {
                    out.push('\n');
                    run = 1;
                }
            }
            out.push(character);
        }
    }
    out
}

/// True when a point lies inside a rounded rectangle. Each corner is a circle
/// of `radius`; the straight edges are inside by construction.
pub fn rounded_rect_covers(x: f64, y: f64, width: f64, height: f64, radius: f64) -> bool {
    if x < 0.0 || y < 0.0 || x >= width || y >= height {
        return false;
    }
    let radius = radius.clamp(0.0, width.min(height) / 2.0);
    if radius <= 0.0 {
        return true;
    }
    let corner_x = if x < radius {
        radius - x
    } else if x > width - radius {
        x - (width - radius)
    } else {
        return true;
    };
    let corner_y = if y < radius {
        radius - y
    } else if y > height - radius {
        y - (height - radius)
    } else {
        return true;
    };
    corner_x * corner_x + corner_y * corner_y <= radius * radius
}

#[cfg(windows)]
pub fn render_card(text: &str, scale: f64) -> Result<PinImage> {
    use windows::core::w;
    use windows::Win32::Foundation::{COLORREF, RECT};
    use windows::Win32::Graphics::Gdi::{
        CreateCompatibleDC, CreateDIBSection, CreateFontW, DeleteDC, DeleteObject, DrawTextW,
        GetDC, ReleaseDC, SelectObject, SetBkMode, SetTextColor, BITMAPINFO, BITMAPINFOHEADER,
        BI_RGB, CLEARTYPE_QUALITY, CLIP_DEFAULT_PRECIS, DEFAULT_CHARSET, DEFAULT_PITCH,
        DIB_RGB_COLORS, DT_CALCRECT, DT_EXPANDTABS, DT_NOPREFIX, DT_WORDBREAK, FF_DONTCARE,
        FONT_QUALITY, FW_NORMAL, HGDIOBJ, OUT_DEFAULT_PRECIS, TRANSPARENT,
    };

    let text = sanitize(text);
    if text.trim().is_empty() {
        anyhow::bail!("The clipboard has no image or text to pin.");
    }
    let scale = if scale.is_finite() { scale.clamp(0.5, 4.0) } else { 1.0 };
    let font_px = ((FONT_DIP * scale).round() as i32).max(8);
    let padding = ((PADDING_DIP * scale).round() as i32).max(2);
    let radius = (RADIUS_DIP * scale).max(1.0);
    let max_text_width = ((MAX_WIDTH_DIP * scale).round() as i32).max(font_px * 4);
    let max_text_height = ((MAX_HEIGHT_DIP * scale).round() as i32).max(font_px * 4);

    unsafe {
        let screen = GetDC(None);
        let device = CreateCompatibleDC(Some(screen));
        let font = CreateFontW(
            -font_px,
            0,
            0,
            0,
            FW_NORMAL.0 as i32,
            0,
            0,
            0,
            DEFAULT_CHARSET,
            OUT_DEFAULT_PRECIS,
            CLIP_DEFAULT_PRECIS,
            FONT_QUALITY(5),
            u32::from(DEFAULT_PITCH.0 | FF_DONTCARE.0),
            w!("Microsoft YaHei UI"),
        );
        let font = if font.is_invalid() {
            CreateFontW(
                -font_px, 0, 0, 0, FW_NORMAL.0 as i32, 0, 0, 0, DEFAULT_CHARSET,
                OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                u32::from(DEFAULT_PITCH.0 | FF_DONTCARE.0), w!("Segoe UI"),
            )
        } else {
            font
        };
        let previous_font = SelectObject(device, HGDIOBJ(font.0));

        let mut units: Vec<u16> = text.encode_utf16().collect();
        let mut measure = RECT { left: 0, top: 0, right: max_text_width, bottom: max_text_height };
        DrawTextW(
            device,
            &mut units,
            &mut measure,
            DT_CALCRECT | DT_WORDBREAK | DT_EXPANDTABS | DT_NOPREFIX,
        );
        let text_width = (measure.right - measure.left).clamp(font_px * 2, max_text_width);
        let text_height = (measure.bottom - measure.top).clamp(font_px, max_text_height);
        let width = text_width + padding * 2;
        let height = text_height + padding * 2;

        let header = BITMAPINFOHEADER {
            biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: width,
            // Negative height selects a top-down DIB, matching the buffer order.
            biHeight: -height,
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB.0,
            ..Default::default()
        };
        let info = BITMAPINFO { bmiHeader: header, ..Default::default() };
        let mut bits: *mut std::ffi::c_void = std::ptr::null_mut();
        let bitmap = CreateDIBSection(Some(device), &info, DIB_RGB_COLORS, &mut bits, None, 0)?;
        let previous_bitmap = SelectObject(device, HGDIOBJ(bitmap.0));

        let mut pixels = vec![0u8; width as usize * height as usize * 4];
        for y in 0..height {
            for x in 0..width {
                if rounded_rect_covers(
                    f64::from(x) + 0.5,
                    f64::from(y) + 0.5,
                    f64::from(width),
                    f64::from(height),
                    radius,
                ) {
                    let index = (y as usize * width as usize + x as usize) * 4;
                    // Opaque premultiplied BGRA.
                    pixels[index] = CARD_RGB.2;
                    pixels[index + 1] = CARD_RGB.1;
                    pixels[index + 2] = CARD_RGB.0;
                    pixels[index + 3] = 255;
                }
            }
        }
        std::ptr::copy_nonoverlapping(
            pixels.as_ptr(),
            bits as *mut u8,
            pixels.len(),
        );

        SetBkMode(device, TRANSPARENT);
        SetTextColor(
            device,
            COLORREF(
                (u32::from(TEXT_RGB.0) << 16) | (u32::from(TEXT_RGB.1) << 8) | u32::from(TEXT_RGB.2),
            ),
        );
        let mut area = RECT {
            left: padding,
            top: padding,
            right: width - padding,
            bottom: height - padding,
        };
        let mut body: Vec<u16> = text.encode_utf16().collect();
        DrawTextW(
            device,
            &mut body,
            &mut area,
            DT_WORDBREAK | DT_EXPANDTABS | DT_NOPREFIX,
        );
        // GDI writes colour channels only; the alpha byte we filled in stays.
        std::ptr::copy_nonoverlapping(bits as *const u8, pixels.as_mut_ptr(), pixels.len());
        // GDI writes colour channels only and leaves the alpha byte of every
        // glyph pixel at zero. The card body is opaque, so the mask decides
        // alpha: fully opaque inside the rounded rectangle, fully transparent
        // outside it. Without this a pin would show transparent text.
        for y in 0..height {
            for x in 0..width {
                let index = (y as usize * width as usize + x as usize) * 4;
                pixels[index + 3] = if rounded_rect_covers(
                    f64::from(x) + 0.5,
                    f64::from(y) + 0.5,
                    f64::from(width),
                    f64::from(height),
                    radius,
                ) {
                    255
                } else {
                    0
                };
            }
        }

        SelectObject(device, previous_bitmap);
        let _ = DeleteObject(HGDIOBJ(bitmap.0));
        SelectObject(device, previous_font);
        let _ = DeleteObject(HGDIOBJ(font.0));
        let _ = DeleteDC(device);
        ReleaseDC(None, screen);

        PinImage::new(width as u32, height as u32, pixels)
            .ok_or_else(|| anyhow::anyhow!("The text pin could not be composed."))
    }
}

#[cfg(not(windows))]
pub fn render_card(_text: &str, _scale: f64) -> Result<PinImage> {
    anyhow::bail!("Text pins are only available on Windows.")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn line_endings_are_normalized_and_trailing_space_removed() {
        assert_eq!(sanitize("a\r\nb\rc"), "a\nb\nc");
        assert_eq!(sanitize("value   \n"), "value");
    }

    #[test]
    fn truncation_respects_character_boundaries() {
        let text = "汉".repeat(MAX_CHARS + 100);
        let sanitized = sanitize(&text);
        let content: String = sanitized.chars().filter(|character| *character != '\n').collect();
        assert_eq!(content.chars().count(), MAX_CHARS);
        assert!(sanitized.ends_with('…'));
        let emoji = "😀".repeat(MAX_CHARS + 1);
        let sanitized = sanitize(&emoji);
        assert!(sanitized.ends_with('…'));
        let content: String = sanitized.chars().filter(|character| *character != '\n').collect();
        assert_eq!(content.chars().count(), MAX_CHARS);
    }

    #[test]
    fn soft_breaks_only_split_whitespace_free_runs() {
        assert_eq!(insert_soft_breaks("the quick brown fox"), "the quick brown fox");
        assert_eq!(insert_soft_breaks("first\nsecond"), "first\nsecond");
        let url = "a".repeat(SOFT_BREAK_CHARS * 3);
        let broken = insert_soft_breaks(&url);
        assert!(broken.contains('\n'));
        for line in broken.split('\n') {
            assert!(line.chars().count() <= SOFT_BREAK_CHARS, "{line}");
        }
        // Breaking must not lose any character.
        assert_eq!(broken.chars().filter(|character| *character != '\n').count(), url.len());
    }

    #[test]
    fn rounded_corners_are_outside_and_edges_are_inside() {
        assert!(rounded_rect_covers(50.0, 50.0, 100.0, 100.0, 8.0));
        assert!(rounded_rect_covers(0.5, 50.0, 100.0, 100.0, 8.0));
        assert!(!rounded_rect_covers(0.5, 0.5, 100.0, 100.0, 8.0));
        assert!(!rounded_rect_covers(99.5, 99.5, 100.0, 100.0, 8.0));
        assert!(!rounded_rect_covers(-1.0, 50.0, 100.0, 100.0, 8.0));
        // A zero radius is a plain rectangle.
        assert!(rounded_rect_covers(0.5, 0.5, 100.0, 100.0, 0.0));
    }

    #[cfg(windows)]
    #[test]
    fn a_short_line_becomes_a_bounded_opaque_card() {
        let card = render_card("Pinned note", 1.0).unwrap();
        assert!(card.width >= 40 && card.width <= 480 + 24);
        assert!(card.height >= 14 + 24);
        // Centre is card body; corner is transparent.
        let centre = ((card.height / 2) * card.width + card.width / 2) as usize * 4;
        assert_eq!(card.bgra[centre + 3], 255);
        assert_eq!(card.bgra[3], 0);
        for pixel in card.bgra.chunks_exact(4) {
            assert!(pixel[0] <= pixel[3] && pixel[1] <= pixel[3] && pixel[2] <= pixel[3]);
        }
    }

    #[cfg(windows)]
    #[test]
    fn long_wrapping_text_stays_within_the_height_budget() {
        let text = "中文换行测试 with latin words ".repeat(400);
        let card = render_card(&text, 1.0).unwrap();
        assert!(card.height <= 1200 + 24);
        assert!(card.width <= 480 + 24);
    }

    #[cfg(windows)]
    #[test]
    fn empty_text_is_rejected_instead_of_rendering_a_blank_pin() {
        assert!(render_card("   \n\t", 1.0).is_err());
    }
}

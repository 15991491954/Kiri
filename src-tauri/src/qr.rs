//! Offline QR recognition. Coordinates remain attached to each physical code,
//! including repeated payloads and codes that can be located but not decoded.
use image::ImageDecoder;
use serde::Serialize;

pub const MAX_PNG_BYTES: usize = 20 * 1024 * 1024;
const MAX_PIXELS: u64 = 32_000_000;
const MAX_CODES: usize = 64;
const MAX_LOCAL_SCAN_PIXELS: u64 = 8_000_000;
const MAX_LOCAL_REGION_PIXELS: u64 = 500_000;

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QrCode {
    pub index: usize,
    pub corners: [[f64; 2]; 4],
    pub text: Option<String>,
    pub url: Option<String>,
    pub host: Option<String>,
    pub suspicious: bool,
}

pub fn link(text: &str) -> Option<url::Url> {
    if text != text.trim()
        || text.chars().any(|c| c.is_control() || c.is_whitespace())
        || text.contains('\\')
        || text.contains('\u{202e}')
    {
        return None;
    }
    // Require the explicit web scheme; never execute arbitrary URI handlers.
    if !text.to_ascii_lowercase().starts_with("https://")
        && !text.to_ascii_lowercase().starts_with("http://")
    {
        return None;
    }
    let url = url::Url::parse(text).ok()?;
    if !matches!(url.scheme(), "https" | "http")
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
    {
        return None;
    }
    Some(url)
}

pub fn describe(index: usize, corners: [[f64; 2]; 4], text: Option<String>) -> QrCode {
    let parsed = text.as_deref().and_then(link);
    let host = parsed
        .as_ref()
        .and_then(|u| u.host_str())
        .map(str::to_owned);
    let suspicious = text.as_ref().is_some_and(|text| {
        host.as_ref().is_some_and(|h| {
            h.contains("xn--")
                || h == "localhost"
                || h.starts_with('[')
                || h.parse::<std::net::IpAddr>().is_ok()
        }) || text.contains('\u{202e}')
            || (parsed.is_none() && looks_like_link(text))
    });
    QrCode {
        index,
        corners,
        text,
        url: parsed.map(|u| u.to_string()),
        host,
        suspicious,
    }
}

fn looks_like_link(text: &str) -> bool {
    let Some((scheme, rest)) = text.trim().split_once(':') else {
        return false;
    };
    let mut bytes = scheme.bytes();
    if !bytes.next().is_some_and(|byte| byte.is_ascii_alphabetic())
        || !bytes.all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'+' | b'-' | b'.'))
    {
        return false;
    }
    rest.starts_with("//")
        || matches!(
            scheme.to_ascii_lowercase().as_str(),
            "http" | "https" | "javascript" | "data" | "file" | "vbscript"
        )
}

pub fn decode(png: &[u8]) -> Result<(u32, u32, Vec<QrCode>), String> {
    if png.len() > MAX_PNG_BYTES {
        return Err("The QR image exceeds the size limit.".into());
    }
    let decoder = image::codecs::png::PngDecoder::new(std::io::Cursor::new(png))
        .map_err(|_| "The QR image could not be read.".to_string())?;
    let (width, height) = decoder.dimensions();
    if width == 0 || height == 0 || u64::from(width) * u64::from(height) > MAX_PIXELS {
        return Err("The QR image exceeds the size limit.".into());
    }
    let gray = image::DynamicImage::from_decoder(decoder)
        .map_err(|_| "The QR image could not be read.".to_string())?
        .into_luma8();
    let mut decoder = quircs::Quirc::default();
    let mut codes = identify(&mut decoder, width, height, &gray);
    let mut finders = finder_centers(&decoder);
    let mut finder_limit_reached = decoder.capstones.len() >= 32;
    // A whole-image Otsu threshold can erase a locally low-contrast code when
    // unrelated bright/dark content dominates the image. Merge all three
    // bounded contrast passes, even after a partial result; different physical
    // codes may require different thresholds. Coordinates stay unchanged.
    let mut binary = vec![0; gray.len()];
    for threshold in [64, 128, 192] {
        for (pixel, value) in binary.iter_mut().zip(gray.iter()) {
            *pixel = if *value < threshold { 0 } else { 255 };
        }
        merge_codes(
            &mut codes,
            identify(&mut decoder, width, height, &binary),
            width,
            height,
        );
        for center in finder_centers(&decoder) {
            if !finders
                .iter()
                .any(|point| (point[0] - center[0]).hypot(point[1] - center[1]) <= 2.0)
            {
                finders.push(center);
            }
        }
        finder_limit_reached |= decoder.capstones.len() >= 32;
    }
    recover_local_codes(
        &mut decoder,
        &gray,
        &finders,
        finder_limit_reached,
        &mut codes,
    );
    codes.sort_by(|a, b| {
        a.corners[0][1]
            .total_cmp(&b.corners[0][1])
            .then(a.corners[0][0].total_cmp(&b.corners[0][0]))
    });
    for (i, code) in codes.iter_mut().enumerate() {
        code.index = i;
    }
    Ok((width, height, codes))
}

fn finder_centers(decoder: &quircs::Quirc) -> Vec<[f64; 2]> {
    decoder
        .capstones
        .iter()
        .take(MAX_CODES * 3)
        .map(|cap| [cap.center.x as f64, cap.center.y as f64])
        .collect()
}

fn finder_is_readable(point: [f64; 2], codes: &[QrCode], width: u32, height: u32) -> bool {
    codes.iter().filter(|code| code.text.is_some()).any(|code| {
        let corners = code
            .corners
            .map(|corner| [corner[0] * width as f64, corner[1] * height as f64]);
        let sides = std::array::from_fn::<_, 4, _>(|index| {
            let a = corners[index];
            let b = corners[(index + 1) % 4];
            (b[0] - a[0]) * (point[1] - a[1]) - (b[1] - a[1]) * (point[0] - a[0])
        });
        sides.iter().all(|side| *side >= 0.0) || sides.iter().all(|side| *side <= 0.0)
    })
}

fn recover_local_codes(
    decoder: &mut quircs::Quirc,
    gray: &image::GrayImage,
    finders: &[[f64; 2]],
    finder_limit_reached: bool,
    codes: &mut Vec<QrCode>,
) {
    // In a montage, Quirc can consume three neighboring codes' finders in one
    // unsupported grid. Threshold retries see the same grouping. Overlapping
    // local views remove distant neighbors without relaxing geometry checks.
    // Ordinary single-code and blank images never need these extra views.
    if finders.len() <= 3 {
        return;
    }
    let (width, height) = gray.dimensions();
    let uncovered_in = |x: u32, y: u32, tile_width: u32, tile_height: u32, codes: &[QrCode]| {
        finders
            .iter()
            .filter(|&&point| {
                point[0] >= x as f64
                    && point[0] < (x + tile_width) as f64
                    && point[1] >= y as f64
                    && point[1] < (y + tile_height) as f64
                    && !finder_is_readable(point, codes, width, height)
            })
            .count()
    };
    let mut regions = Vec::new();
    for (divisions, padding) in [(4, 2), (4, 3), (2, 2)] {
        // Padding leaves room for a complete finder triangle between adjacent
        // tile origins; without it a code can straddle every quarter view.
        let (tile_width, tile_height) = (
            (width.div_ceil(divisions) * padding / 2).min(width),
            (height.div_ceil(divisions) * padding / 2).min(height),
        );
        let steps = divisions * 2 - 2;
        for row in 0..=steps {
            for column in 0..=steps {
                let x = (width - tile_width) * column / steps;
                let y = (height - tile_height) * row / steps;
                let count = uncovered_in(x, y, tile_width, tile_height, codes);
                // Quirc has a hard 32-finder / 8-grid limit. At saturation,
                // unobserved parts of the image need scanning too.
                if finder_limit_reached || count >= 3 {
                    // Cover all quarters first, including finders the global
                    // 32-finder cap never observed. Then spend on overlap.
                    let coverage =
                        if divisions == 4 && padding == 2 && row % 2 == 0 && column % 2 == 0 {
                            0
                        } else {
                            1
                        };
                    regions.push((coverage, count, x, y, tile_width, tile_height));
                }
            }
        }
    }
    regions.sort_by_key(|&(coverage, count, _, _, tile_width, tile_height)| {
        (
            coverage,
            u64::from(tile_width) * u64::from(tile_height),
            std::cmp::Reverse(count),
        )
    });
    let mut pixels = 0;
    for (_, _, x, y, tile_width, tile_height) in regions {
        let area = u64::from(tile_width) * u64::from(tile_height);
        let scale = (MAX_LOCAL_REGION_PIXELS as f64 / area as f64)
            .sqrt()
            .min(1.0);
        let (local_width, local_height) = (
            (tile_width as f64 * scale).floor().max(1.0) as u32,
            (tile_height as f64 * scale).floor().max(1.0) as u32,
        );
        let local_area = u64::from(local_width) * u64::from(local_height);
        if pixels + local_area > MAX_LOCAL_SCAN_PIXELS {
            continue;
        }
        if !finder_limit_reached && uncovered_in(x, y, tile_width, tile_height, codes) < 3 {
            continue;
        }
        pixels += local_area;
        // Sample directly from the source. imageops::resize allocates a float
        // intermediate at the original tile width even for Nearest sampling.
        let tile = image::GrayImage::from_fn(local_width, local_height, |column, row| {
            *gray.get_pixel(
                x + (u64::from(column) * u64::from(tile_width) / u64::from(local_width)) as u32,
                y + (u64::from(row) * u64::from(tile_height) / u64::from(local_height)) as u32,
            )
        });
        // Dense grouping and low contrast can occur together. The whole-image
        // contrast pass may exhaust Quirc's finder limit before reaching this
        // tile, so retain the same fixed threshold retries in each local view.
        // View area remains bounded above; retries reuse one binary buffer.
        let mut local_codes = identify(decoder, local_width, local_height, &tile);
        let mut binary = vec![0; tile.len()];
        for threshold in [64, 128, 192] {
            for (pixel, value) in binary.iter_mut().zip(tile.iter()) {
                *pixel = if *value < threshold { 0 } else { 255 };
            }
            merge_codes(
                &mut local_codes,
                identify(decoder, local_width, local_height, &binary),
                local_width,
                local_height,
            );
        }
        let candidates = local_codes
            .into_iter()
            // Whole-image passes keep damaged, locatable codes. Local crops
            // are only a decoding recovery: cut-off neighbors must not add
            // speculative unreadable targets to an otherwise valid montage.
            .filter(|code| code.text.is_some())
            // A cut-off grid must not publish clamped, distorted geometry.
            .filter(|code| {
                code.corners
                    .iter()
                    .all(|point| point.iter().all(|value| *value > 0.0 && *value < 1.0))
            })
            .map(|mut code| {
                code.corners = code.corners.map(|point| {
                    [
                        (x as f64 + point[0] * tile_width as f64) / width as f64,
                        (y as f64 + point[1] * tile_height as f64) / height as f64,
                    ]
                });
                code
            })
            .collect();
        merge_codes(codes, candidates, width, height);
    }
}

fn identify(decoder: &mut quircs::Quirc, width: u32, height: u32, gray: &[u8]) -> Vec<QrCode> {
    let mut codes = Vec::new();
    let candidates: Vec<_> = decoder
        .identify(width as usize, height as usize, gray)
        .take(MAX_CODES)
        .enumerate()
        .filter_map(|(index, code)| code.ok().map(|code| (index, code)))
        .collect();
    for (index, code) in candidates {
        if !supported_grid(decoder, &decoder.grids[index]) {
            continue;
        }
        let corners = code.corners.map(|p| {
            [
                (p.x as f64 / width as f64).clamp(0.0, 1.0),
                (p.y as f64 / height as f64).clamp(0.0, 1.0),
            ]
        });
        let text = code
            .decode()
            .ok()
            .and_then(|d| String::from_utf8(d.payload).ok())
            .filter(|s| !s.is_empty() && s.len() <= 16 * 1024);
        codes.push(describe(codes.len(), corners, text));
    }
    codes
}

fn project(c: &[f64; 8], u: f64, v: f64) -> [f64; 2] {
    let denominator = c[6] * u + c[7] * v + 1.0;
    [
        (c[0] * u + c[1] * v + c[2]) / denominator,
        (c[3] * u + c[4] * v + c[5]) / denominator,
    ]
}

fn supported_grid(decoder: &quircs::Quirc, grid: &quircs::Grid) -> bool {
    let size = grid.grid_size as f64;
    let corners = [[0.0, 0.0], [size, 0.0], [size, size], [0.0, size]];
    // A projective pole inside the code can send its corners across the image.
    if !grid.c.iter().all(|value| value.is_finite())
        || corners
            .iter()
            .any(|[u, v]| grid.c[6] * u + grid.c[7] * v + 1.0 <= 0.0)
    {
        return false;
    }
    let finder_corners = [[0.0, 0.0], [7.0, 0.0], [7.0, 7.0], [0.0, 7.0]];
    let origins = [[0.0, size - 7.0], [0.0, 0.0], [size - 7.0, 0.0]];
    // Quirc may group finder patterns belonging to neighboring codes. Its
    // fitted grid must still agree with all three observed 7x7 finder shapes.
    // Allow three modules plus pixel rounding to retain damaged, locatable
    // codes without accepting an unrelated finder elsewhere in a montage.
    grid.caps.iter().zip(origins).all(|(&index, origin)| {
        let capstone = &decoder.capstones[index];
        let module = (0..4)
            .map(|i| {
                let a = capstone.corners[i];
                let b = capstone.corners[(i + 1) % 4];
                (a.x as f64 - b.x as f64).hypot(a.y as f64 - b.y as f64)
            })
            .sum::<f64>()
            / 28.0;
        finder_corners.iter().enumerate().all(|(i, [u, v])| {
            let predicted = project(&grid.c, origin[0] + u, origin[1] + v);
            let observed = capstone.corners[i];
            (predicted[0] - observed.x as f64).hypot(predicted[1] - observed.y as f64)
                <= module * 3.0 + 1.0
        })
    })
}

fn same_code_position(a: &QrCode, b: &QrCode, width: u32, height: u32) -> bool {
    let geometry = |code: &QrCode| {
        let points = code
            .corners
            .map(|p| [p[0] * width as f64, p[1] * height as f64]);
        let center = [
            points.iter().map(|p| p[0]).sum::<f64>() / 4.0,
            points.iter().map(|p| p[1]).sum::<f64>() / 4.0,
        ];
        let edges = std::array::from_fn::<_, 4, _>(|i| {
            let next = points[(i + 1) % 4];
            (points[i][0] - next[0]).hypot(points[i][1] - next[1])
        });
        let span = edges.iter().sum::<f64>() / 4.0;
        let shortest = edges.into_iter().fold(f64::INFINITY, f64::min);
        (center, span, shortest)
    };
    let (a_center, a_span, a_shortest) = geometry(a);
    let (b_center, b_span, b_shortest) = geometry(b);
    let smaller = a_span.min(b_span);
    // Use the short edge for positional tolerance so adjacent stretched codes
    // do not merge merely because their long edges are close together.
    let tolerance = a_shortest.min(b_shortest) * 0.15;
    smaller > 0.0
        && smaller >= a_span.max(b_span) * 0.75
        && (a_center[0] - b_center[0]).hypot(a_center[1] - b_center[1]) <= tolerance
}

fn merge_codes(codes: &mut Vec<QrCode>, candidates: Vec<QrCode>, width: u32, height: u32) {
    for candidate in candidates {
        if let Some(existing) = codes
            .iter_mut()
            .find(|code| same_code_position(code, &candidate, width, height))
        {
            // A later pass can decode a previously located code. Keep the first
            // readable result if another pass fails or disagrees.
            if existing.text.is_none() && candidate.text.is_some() {
                *existing = candidate;
            }
        } else if codes.len() < MAX_CODES {
            // Deduplicate physical positions, never payloads: repeated content
            // at different positions still needs separate clickable targets.
            codes.push(candidate);
        }
    }
}


#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn links_are_explicit_web_urls_without_credentials_or_controls() {
        for text in [
            "javascript:alert(1)",
            "file:///tmp/a",
            "data:text/html,hi",
            "https://trusted.example@evil.example",
            "https://a.example\\@b.example",
            "https://a.example\n",
            " https://a.example",
            "example.com",
            "https://",
        ] {
            assert!(link(text).is_none(), "{text}");
        }
        assert_eq!(
            link("https://example.com/a?q=1").unwrap().host_str(),
            Some("example.com")
        );
        assert!(describe(0, [[0.0; 2]; 4], Some("https://xn--pple-43d.com".into())).suspicious);
        assert!(describe(0, [[0.0; 2]; 4], Some("http://127.0.0.1".into())).suspicious);
        assert!(describe(0, [[0.0; 2]; 4], Some("https://[::1]".into())).suspicious);
        assert!(!describe(0, [[0.0; 2]; 4], Some("http://example.org".into())).suspicious);
    }

    #[test]
    fn plain_colon_text_and_embedded_urls_do_not_get_link_warnings() {
        for text in [
            "兔子二维码 https://tuzim.net",
            "Note: https://example.org",
            "Time: 12:30",
            "备注：测试",
        ] {
            let code = describe(0, [[0.0; 2]; 4], Some(text.into()));
            assert!(code.url.is_none());
            assert!(!code.suspicious, "plain content: {text}");
        }
        for text in [
            "https://user:password@example.org",
            "https://",
            " http://example.org",
            "ftp://example.org",
            "javascript:alert(1)",
            "file:///tmp/test",
            "data:text/html,test",
            "text\u{202e}reordered",
            "https://example.org/\u{202e}reordered",
        ] {
            let code = describe(0, [[0.0; 2]; 4], Some(text.into()));
            assert!(code.url.is_none(), "must not open: {text}");
            assert!(code.suspicious, "retain a warning: {text}");
        }
    }
    #[test]
    fn invalid_images_fail_without_results() {
        assert!(decode(b"not a PNG").is_err());
        let mut png = std::io::Cursor::new(Vec::new());
        image::DynamicImage::new_luma8(200, 100)
            .write_to(&mut png, image::ImageFormat::Png)
            .unwrap();
        assert!(decode(png.get_ref()).unwrap().2.is_empty());
    }

    #[test]
    fn real_single_multi_duplicate_and_unicode_codes_keep_their_positions() {
        let single = decode(include_bytes!("../tests/fixtures/qr/url.png"))
            .unwrap()
            .2;
        assert_eq!(single.len(), 1);
        assert_eq!(
            single[0].text.as_deref(),
            Some("https://example.org/kiri-safe")
        );
        let multi = decode(include_bytes!("../tests/fixtures/qr/multi.png"))
            .unwrap()
            .2;
        assert_eq!(multi.len(), 3);
        assert_eq!(multi.iter().filter(|c| c.text == single[0].text).count(), 2);
        assert!(multi
            .iter()
            .any(|c| c.text.as_deref() == Some("Kiri QR 测试")));
        assert!(multi.iter().all(|c| c
            .corners
            .iter()
            .all(|p| p.iter().all(|v| *v >= 0.0 && *v <= 1.0))));
        assert!(multi.iter().any(|c| c.corners[0][0] > 0.6));
    }

    fn public_montage(
        columns: u32,
        rows: u32,
        width: u32,
        height: u32,
        side: u32,
    ) -> image::GrayImage {
        let source = image::load_from_memory(include_bytes!("../tests/fixtures/qr/url.png"))
            .unwrap()
            .into_luma8();
        let code =
            image::imageops::resize(&source, side, side, image::imageops::FilterType::Nearest);
        let mut canvas = image::GrayImage::from_pixel(width, height, image::Luma([255]));
        for row in 0..rows {
            for column in 0..columns {
                let x = column * width / columns + (width / columns - side) / 2;
                let y = row * height / rows + (height / rows - side) / 2;
                image::imageops::replace(&mut canvas, &code, x as i64, y as i64);
            }
        }
        canvas
    }

    #[test]
    fn dense_montages_recover_more_than_eight_codes_without_merging_duplicate_payloads() {
        for (count, dimension) in [(3, 544), (4, 712)] {
            let canvas = public_montage(count, count, dimension, dimension, 148);
            let whole = identify(&mut quircs::Quirc::default(), dimension, dimension, &canvas);
            assert!(whole.len() < (count * count) as usize);
            let mut png = std::io::Cursor::new(Vec::new());
            canvas.write_to(&mut png, image::ImageFormat::Png).unwrap();
            let (_, _, codes) = decode(png.get_ref()).unwrap();
            assert_eq!(codes.len(), (count * count) as usize);
            for row in 0..count {
                for column in 0..count {
                    let center_x = (column as f64 + 0.5) * dimension as f64 / count as f64;
                    let center_y = (row as f64 + 0.5) * dimension as f64 / count as f64;
                    assert_eq!(
                        codes
                            .iter()
                            .filter(|code| {
                                let x = code.corners.iter().map(|p| p[0]).sum::<f64>()
                                    * dimension as f64
                                    / 4.0;
                                let y = code.corners.iter().map(|p| p[1]).sum::<f64>()
                                    * dimension as f64
                                    / 4.0;
                                code.text.as_deref() == Some("https://example.org/kiri-safe")
                                    && (x - center_x).abs() <= 3.0
                                    && (y - center_y).abs() <= 3.0
                            })
                            .count(),
                        1,
                        "one marker at every original code center"
                    );
                }
            }
        }
    }

    #[test]
    fn dense_montages_recover_low_contrast_codes_after_the_global_finder_limit() {
        let mut canvas = public_montage(4, 3, 608, 460, 148);
        // Use the third row's third code: the preceding high-contrast finders
        // fill Quirc's fixed cap before the global 192 threshold reaches it.
        let (x, y) = (
            2 * 608 / 4 + (608 / 4 - 148) / 2,
            2 * 460 / 3 + (460 / 3 - 148) / 2,
        );
        for row in y..y + 148 {
            for column in x..x + 148 {
                let value = canvas.get_pixel_mut(column, row);
                value[0] = if value[0] < 128 { 160 } else { 220 };
            }
        }
        let mut png = std::io::Cursor::new(Vec::new());
        canvas.write_to(&mut png, image::ImageFormat::Png).unwrap();
        let (_, _, codes) = decode(png.get_ref()).unwrap();
        assert_eq!(codes.len(), 12);
        assert!(codes
            .iter()
            .all(|code| code.text.as_deref() == Some("https://example.org/kiri-safe")));
        let center = [(x as f64 + 74.0) / 608.0, (y as f64 + 74.0) / 460.0];
        assert_eq!(
            codes
                .iter()
                .filter(|code| {
                    let x = code.corners.iter().map(|point| point[0]).sum::<f64>() / 4.0;
                    let y = code.corners.iter().map(|point| point[1]).sum::<f64>() / 4.0;
                    (x - center[0]).abs() * 608.0 <= 3.0 && (y - center[1]).abs() * 460.0 <= 3.0
                })
                .count(),
            1
        );
    }

    #[test]
    fn large_montages_recover_unobserved_bottom_rows_with_original_coordinates() {
        let canvas = public_montage(4, 4, 8000, 4000, 296);
        let mut png = std::io::Cursor::new(Vec::new());
        canvas.write_to(&mut png, image::ImageFormat::Png).unwrap();
        let (width, height, codes) = decode(png.get_ref()).unwrap();
        assert_eq!((width, height), (8000, 4000));
        assert_eq!(codes.len(), 16);
        assert!(codes
            .iter()
            .all(|code| code.text.as_deref() == Some("https://example.org/kiri-safe")));
        for row in 0..4 {
            for column in 0..4 {
                let center = [(column as f64 + 0.5) / 4.0, (row as f64 + 0.5) / 4.0];
                assert_eq!(
                    codes
                        .iter()
                        .filter(|code| {
                            let x = code.corners.iter().map(|p| p[0]).sum::<f64>() / 4.0;
                            let y = code.corners.iter().map(|p| p[1]).sum::<f64>() / 4.0;
                            (x - center[0]).abs() * width as f64 <= 4.0
                                && (y - center[1]).abs() * height as f64 <= 4.0
                        })
                        .count(),
                    1
                );
            }
        }
    }

    #[test]
    fn damaged_codes_stay_locatable_and_unsafe_payloads_stay_plain_content() {
        let broken = decode(include_bytes!("../tests/fixtures/qr/damaged.png"))
            .unwrap()
            .2;
        assert!(!broken.is_empty());
        assert!(broken.iter().all(|c| c.text.is_none() && c.url.is_none()));
        let unsafe_code = decode(include_bytes!("../tests/fixtures/qr/unsafe.png"))
            .unwrap()
            .2;
        assert_eq!(unsafe_code.len(), 1);
        assert_eq!(unsafe_code[0].text.as_deref(), Some("javascript:alert(1)"));
        assert!(unsafe_code[0].url.is_none());
        assert!(unsafe_code[0].suspicious);
    }

    #[test]
    fn low_contrast_codes_survive_unrelated_bright_and_dark_backgrounds() {
        let source = image::load_from_memory(include_bytes!("../tests/fixtures/qr/url.png"))
            .unwrap()
            .into_luma8();
        for (dark, light, background) in [(0, 100, 255), (100, 160, 0), (160, 230, 0)] {
            let mut code = source.clone();
            for value in code.iter_mut() {
                *value = if *value < 128 { dark } else { light };
            }
            let mut canvas = image::GrayImage::from_pixel(960, 480, image::Luma([background]));
            image::imageops::replace(&mut canvas, &code, 32, 32);
            image::imageops::replace(&mut canvas, &code, 600, 120);
            // The old single whole-image threshold loses both physical codes.
            assert!(identify(&mut quircs::Quirc::default(), 960, 480, &canvas).is_empty());
            let mut png = std::io::Cursor::new(Vec::new());
            canvas.write_to(&mut png, image::ImageFormat::Png).unwrap();
            let (width, height, codes) = decode(png.get_ref()).unwrap();
            assert_eq!((width, height), (960, 480));
            assert_eq!(codes.len(), 2);
            for (index, code) in codes.iter().enumerate() {
                assert_eq!(code.index, index);
                assert_eq!(code.text.as_deref(), Some("https://example.org/kiri-safe"));
            }
            assert!((codes[0].corners[0][0] * 960.0 - 64.0).abs() <= 1.0);
            assert!((codes[1].corners[0][0] * 960.0 - 632.0).abs() <= 1.0);
            assert!((codes[1].corners[0][1] * 480.0 - 152.0).abs() <= 1.0);
        }
    }

    #[test]
    fn empty_threshold_retries_do_not_invent_codes() {
        for value in [0, 64, 128, 192, 255] {
            let blank = image::GrayImage::from_pixel(320, 240, image::Luma([value]));
            let mut png = std::io::Cursor::new(Vec::new());
            blank.write_to(&mut png, image::ImageFormat::Png).unwrap();
            assert!(decode(png.get_ref()).unwrap().2.is_empty());
        }
    }

    #[test]
    fn partial_scans_merge_codes_from_different_contrast_ranges() {
        let url = image::load_from_memory(include_bytes!("../tests/fixtures/qr/url.png"))
            .unwrap()
            .into_luma8();
        let text = image::load_from_memory(include_bytes!("../tests/fixtures/qr/text.png"))
            .unwrap()
            .into_luma8();
        let mut canvas = image::GrayImage::from_pixel(960, 480, image::Luma([255]));
        for (source, dark, light, x, y) in [
            (&url, 0, 255, 32, 32),
            (&text, 0, 100, 352, 140),
            (&url, 150, 255, 672, 32),
        ] {
            let mut code = source.clone();
            for value in code.iter_mut() {
                *value = if *value < 128 { dark } else { light };
            }
            image::imageops::replace(&mut canvas, &code, x, y);
        }
        let initial = identify(&mut quircs::Quirc::default(), 960, 480, &canvas);
        assert_eq!(initial.len(), 2);
        assert!(initial
            .iter()
            .all(|code| code.text.as_deref() == Some("https://example.org/kiri-safe")));
        let mut png = std::io::Cursor::new(Vec::new());
        canvas.write_to(&mut png, image::ImageFormat::Png).unwrap();
        let (_, _, codes) = decode(png.get_ref()).unwrap();
        assert_eq!(codes.len(), 3);
        assert_eq!(
            codes
                .iter()
                .filter(|code| code.text.as_deref() == Some("https://example.org/kiri-safe"))
                .count(),
            2
        );
        assert_eq!(codes[2].text.as_deref(), Some("Kiri QR 测试"));
        for (index, code) in codes.iter().enumerate() {
            assert_eq!(code.index, index);
        }
        assert!((codes[0].corners[0][0] * 960.0 - 64.0).abs() <= 1.0);
        assert!((codes[1].corners[0][0] * 960.0 - 704.0).abs() <= 1.0);
        assert!((codes[2].corners[0][0] * 960.0 - 384.0).abs() <= 1.0);
    }

    #[test]
    fn initially_empty_scans_keep_results_from_later_thresholds() {
        let mut canvas = image::GrayImage::from_pixel(1280, 720, image::Luma([255]));
        for (png, dark, light, x, y) in [
            (
                include_bytes!("../tests/fixtures/qr/text.png").as_slice(),
                0,
                100,
                128,
                128,
            ),
            (
                include_bytes!("../tests/fixtures/qr/url.png").as_slice(),
                100,
                160,
                672,
                224,
            ),
        ] {
            let mut code = image::load_from_memory(png).unwrap().into_luma8();
            for value in code.iter_mut() {
                *value = if *value < 128 { dark } else { light };
            }
            image::imageops::replace(&mut canvas, &code, x, y);
        }
        assert!(identify(&mut quircs::Quirc::default(), 1280, 720, &canvas).is_empty());
        let mut png = std::io::Cursor::new(Vec::new());
        canvas.write_to(&mut png, image::ImageFormat::Png).unwrap();
        let (_, _, codes) = decode(png.get_ref()).unwrap();
        assert_eq!(codes.len(), 2);
        assert_eq!(codes[0].text.as_deref(), Some("Kiri QR 测试"));
        assert_eq!(
            codes[1].text.as_deref(),
            Some("https://example.org/kiri-safe")
        );
    }

    #[test]
    fn merging_upgrades_unreadable_codes_without_duplicating_or_downgrading_them() {
        let corners = [[0.1, 0.1], [0.2, 0.1], [0.2, 0.3], [0.1, 0.3]];
        let mut codes = vec![describe(0, corners, None)];
        let mut shifted = corners.map(|p| [p[0] + 0.002, p[1] + 0.004]);
        shifted.rotate_left(1);
        let readable = describe(0, shifted, Some("https://example.org/decoded".into()));
        merge_codes(&mut codes, vec![readable.clone()], 1000, 500);
        assert_eq!(codes.len(), 1);
        assert_eq!(codes[0].text, readable.text);
        assert_eq!(codes[0].url, readable.url);
        merge_codes(
            &mut codes,
            vec![
                describe(0, corners, None),
                describe(0, corners, Some("conflicting".into())),
            ],
            1000,
            500,
        );
        assert_eq!(codes.len(), 1);
        assert_eq!(codes[0].text, readable.text);
        let neighbor = describe(
            0,
            corners.map(|p| [p[0] + 0.11, p[1]]),
            readable.text.clone(),
        );
        merge_codes(&mut codes, vec![neighbor], 1000, 500);
        assert_eq!(codes.len(), 2);
    }

    #[test]
    fn merging_caps_physical_codes_but_still_upgrades_existing_results() {
        let corners = [[0.001, 0.1], [0.005, 0.1], [0.005, 0.2], [0.001, 0.2]];
        let candidates = (0..80)
            .map(|index| {
                describe(
                    index,
                    corners.map(|p| [p[0] + index as f64 * 0.01, p[1]]),
                    None,
                )
            })
            .collect();
        let mut codes = Vec::new();
        merge_codes(&mut codes, candidates, 1000, 500);
        assert_eq!(codes.len(), MAX_CODES);
        merge_codes(
            &mut codes,
            vec![describe(0, corners, Some("decoded at capacity".into()))],
            1000,
            500,
        );
        assert_eq!(codes.len(), MAX_CODES);
        assert_eq!(codes[0].text.as_deref(), Some("decoded at capacity"));
    }

    #[test]
    fn adjacent_stretched_codes_keep_separate_positions() {
        let source = image::load_from_memory(include_bytes!("../tests/fixtures/qr/url.png"))
            .unwrap()
            .into_luma8();
        let stretched =
            image::imageops::resize(&source, 740, 37, image::imageops::FilterType::Nearest);
        let mut dark = stretched.clone();
        for value in dark.iter_mut() {
            *value = if *value < 128 { 0 } else { 100 };
        }
        let mut canvas = image::GrayImage::from_pixel(800, 120, image::Luma([255]));
        image::imageops::replace(&mut canvas, &stretched, 32, 32);
        image::imageops::replace(&mut canvas, &dark, 32, 69);
        let mut png = std::io::Cursor::new(Vec::new());
        canvas.write_to(&mut png, image::ImageFormat::Png).unwrap();
        let (_, _, codes) = decode(png.get_ref()).unwrap();
        assert_eq!(codes.len(), 2);
        assert!(codes
            .iter()
            .all(|code| code.text.as_deref() == Some("https://example.org/kiri-safe")));
        assert!(codes[1].corners[0][1] > codes[0].corners[0][1]);
    }

    #[test]
    fn neighboring_finders_do_not_create_cross_image_targets() {
        for (png, expected) in [
            (
                include_bytes!("../tests/fixtures/qr/cross-finders.png").as_slice(),
                [[563.0, 282.0, 712.0, 431.0], [53.0, 521.0, 202.0, 670.0]],
            ),
            (
                include_bytes!("../tests/fixtures/qr/projective-pole.png").as_slice(),
                [[449.0, 246.0, 605.0, 402.0], [667.0, 358.0, 788.0, 479.0]],
            ),
        ] {
            let (_, _, codes) = decode(png).unwrap();
            // Both undamaged source codes now recover; the neighboring-finder
            // false grid and the code with a removed finder remain excluded.
            assert_eq!(codes.len(), 2, "only genuine QR targets should remain");
            for (code, expected) in codes.iter().zip(expected) {
                assert_eq!(code.text.as_deref(), Some("https://example.org/kiri-safe"));
                for corner in code.corners {
                    let (x, y) = (corner[0] * 1300.0, corner[1] * 750.0);
                    assert!((expected[0] - 2.0..=expected[2] + 2.0).contains(&x));
                    assert!((expected[1] - 2.0..=expected[3] + 2.0).contains(&y));
                }
            }
        }
    }

    #[test]
    fn standard_wechat_codes_decode_locally_and_custom_schemes_stay_content() {
        let (_, _, codes) = decode(include_bytes!("../tests/fixtures/qr/wechat.png")).unwrap();
        let expected = [
            "https://weixin.qq.com/r/KIRI_PUBLIC_FIXTURE",
            "https://login.weixin.qq.com/l/KIRI_PUBLIC_FIXTURE==",
            "https://mp.weixin.qq.com/s/KIRI_PUBLIC_FIXTURE",
            "weixin://wxpay/bizpayurl?pr=KIRI_PUBLIC_FIXTURE",
        ];
        assert_eq!(codes.len(), expected.len());
        for payload in expected {
            let code = codes
                .iter()
                .find(|code| code.text.as_deref() == Some(payload))
                .unwrap();
            assert_eq!(code.url.is_some(), payload.starts_with("https://"));
        }
    }

    #[test]
    fn rotated_and_perspective_codes_retain_supported_finder_geometry() {
        let source = image::load_from_memory(include_bytes!("../tests/fixtures/qr/url.png"))
            .unwrap()
            .into_luma8();
        let diagonal = 300.0 / 2.0_f64.sqrt();
        for c in [
            [
                diagonal,
                -diagonal,
                250.0,
                diagonal,
                diagonal,
                250.0 - diagonal,
                0.0,
                0.0,
            ],
            [340.0, 50.0, 50.0, 30.0, 350.0, 50.0, 0.2, 0.8],
        ] {
            let mut image = image::GrayImage::from_pixel(500, 500, image::Luma([255]));
            for (x, y, pixel) in image.enumerate_pixels_mut() {
                let (x, y) = (x as f64, y as f64);
                let (a, b) = (c[0] - x * c[6], c[1] - x * c[7]);
                let (d, e) = (c[3] - y * c[6], c[4] - y * c[7]);
                let (r, s) = (x - c[2], y - c[5]);
                let determinant = a * e - b * d;
                let (u, v) = ((r * e - b * s) / determinant, (a * s - r * d) / determinant);
                if (0.0..1.0).contains(&u) && (0.0..1.0).contains(&v) {
                    *pixel = *source.get_pixel(
                        (u * source.width() as f64) as u32,
                        (v * source.height() as f64) as u32,
                    );
                }
            }
            let mut png = std::io::Cursor::new(Vec::new());
            image.write_to(&mut png, image::ImageFormat::Png).unwrap();
            let (_, _, codes) = decode(png.get_ref()).unwrap();
            assert_eq!(codes.len(), 1);
            assert_eq!(
                codes[0].text.as_deref(),
                Some("https://example.org/kiri-safe")
            );
        }
    }
}

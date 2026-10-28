//! Resampling for native pins.
//!
//! A pin is submitted to the desktop as premultiplied BGRA. GDI's `HALFTONE`
//! stretch costs 30 ms for a 4K source even at 1080p and 208 ms at 8K, so a
//! continuous wheel zoom cannot use it. These routines are band-free (every
//! output row is computed independently, so parallel chunks are bit-identical
//! to a single thread) and allocate exactly one output image.
//!
//! Two growth filters exist: [`resample`] uses bilinear weights because a
//! wheel burst needs every intermediate frame cheaply, and
//! [`resample_sharp`] uses a Catmull-Rom bicubic for the settled frame, where
//! the one-time cost buys text and one-pixel lines that stay crisp instead of
//! fading into a soft ramp. Both share the same coverage-weighted shrink.

use std::sync::Arc;

use super::PinImage;

/// Threads used for one frame. Four keeps a 4K frame inside the 28 ms budget
/// without waking the whole machine for a single resize.
const MAX_THREADS: usize = 4;

pub fn worker_threads() -> usize {
    std::thread::available_parallelism()
        .map(|count| count.get().min(MAX_THREADS))
        .unwrap_or(1)
        .max(1)
}

/// Scales `source` to the requested size.
///
/// At 1:1 the caller's own buffer is returned without touching a pixel, which
/// is what makes 100% sharp and free. Shrinking on both axes uses a
/// coverage-weighted box filter, so a mild reduction keeps text edges instead
/// of averaging them with an uncovered neighbour (bilinear would skip source
/// pixels and alias text); growing uses bilinear.
pub fn resample(source: &PinImage, width: u32, height: u32) -> Arc<[u8]> {
    resample_with_threads(source, width, height, worker_threads())
}

pub fn resample_with_threads(
    source: &PinImage,
    width: u32,
    height: u32,
    threads: usize,
) -> Arc<[u8]> {
    let width = width.max(1);
    let height = height.max(1);
    if width == source.width && height == source.height {
        return Arc::clone(&source.bgra);
    }
    let threads = threads.max(1);
    let pixels = if width <= source.width && height <= source.height {
        box_reduce(source, width, height, threads)
    } else {
        bilinear(source, width, height, threads)
    };
    Arc::from(pixels)
}

/// Scales `source` to the requested size with the settled-frame growth filter.
///
/// Shrinking and the 1:1 fast path are identical to [`resample`]; growth uses
/// Catmull-Rom bicubic so a zoomed pin keeps text stems and one-pixel lines
/// near their source contrast. Bilinear leaves a soft two-pixel ramp at 200%,
/// which reads as "the pin got blurry as soon as I zoomed in".
pub fn resample_sharp(source: &PinImage, width: u32, height: u32) -> Arc<[u8]> {
    resample_sharp_with_threads(source, width, height, worker_threads())
}

pub fn resample_sharp_with_threads(
    source: &PinImage,
    width: u32,
    height: u32,
    threads: usize,
) -> Arc<[u8]> {
    let width = width.max(1);
    let height = height.max(1);
    if width == source.width && height == source.height {
        return Arc::clone(&source.bgra);
    }
    let threads = threads.max(1);
    let pixels = if width <= source.width && height <= source.height {
        box_reduce(source, width, height, threads)
    } else {
        bicubic(source, width, height, threads)
    };
    Arc::from(pixels)
}

/// Catmull-Rom weights for one axis, fixed point and summing to exactly 256.
///
/// The four taps straddle the sample point. Redistributing the rounding error
/// onto the largest weight keeps a uniform surface uniform, which matters for
/// premultiplied alpha: a sum that drifts by one unit per pixel shows up as a
/// faint band on flat fills.
fn catmull_rom_weights(fraction: f64) -> [i32; 4] {
    let mut weights = [0i32; 4];
    let mut sum = 0i32;
    for (index, distance) in [fraction + 1.0, fraction, 1.0 - fraction, 2.0 - fraction]
        .into_iter()
        .enumerate()
    {
        let distance = distance.abs();
        let value = if distance <= 1.0 {
            1.5 * distance.powi(3) - 2.5 * distance.powi(2) + 1.0
        } else if distance < 2.0 {
            -0.5 * distance.powi(3) + 2.5 * distance.powi(2) - 4.0 * distance + 2.0
        } else {
            0.0
        };
        weights[index] = (value * 256.0).round() as i32;
        sum += weights[index];
    }
    let largest = weights
        .iter()
        .enumerate()
        .max_by_key(|(_, weight)| weight.abs())
        .map(|(index, _)| index)
        .unwrap_or(0);
    weights[largest] += 256 - sum;
    weights
}

/// Four clamped source indices and fixed-point weights for one output cell.
fn bicubic_taps(
    target: usize,
    target_len: usize,
    source_len: usize,
) -> ([usize; 4], [i32; 4]) {
    let center = (target as f64 + 0.5) * source_len as f64 / target_len as f64 - 0.5;
    let base = center.floor();
    let fraction = (center - base).clamp(0.0, 1.0);
    let last = source_len.saturating_sub(1) as i64;
    let indices = [base as i64 - 1, base as i64, base as i64 + 1, base as i64 + 2]
        .map(|index| index.clamp(0, last) as usize);
    (indices, catmull_rom_weights(fraction))
}

fn bicubic(source: &PinImage, width: u32, height: u32, threads: usize) -> Vec<u8> {
    let (source_width, source_height) = (source.width as usize, source.height as usize);
    let (target_width, target_height) = (width as usize, height as usize);
    let columns: Vec<([usize; 4], [i32; 4])> = (0..target_width)
        .map(|x| bicubic_taps(x, target_width, source_width))
        .collect();
    let bytes = source.bgra.as_ref();
    let mut out = vec![0u8; target_width * target_height * 4];
    for_each_row(&mut out, target_width * 4, threads, |y, row| {
        let (rows, vertical) = bicubic_taps(y, target_height, source_height);
        for (x, (columns, horizontal)) in columns.iter().enumerate() {
            let mut accumulator = [0i32; 4];
            for (row_index, weight_y) in rows.iter().zip(vertical) {
                let line = &bytes[row_index * source_width * 4..(row_index + 1) * source_width * 4];
                for (column, weight_x) in columns.iter().zip(horizontal) {
                    let weight = weight_y * weight_x;
                    let index = column * 4;
                    for channel in 0..4 {
                        accumulator[channel] += i32::from(line[index + channel]) * weight;
                    }
                }
            }
            // Both axes sum to 256, so the product sums to 2^16. Overshoot is
            // clamped: a bicubic ring must never raise a colour channel above
            // its alpha, or the desktop adds light around the edge.
            let alpha = (((accumulator[3] + 32768) >> 16).clamp(0, 255)) as u8;
            row[x * 4 + 3] = alpha;
            for channel in 0..3 {
                let value = (((accumulator[channel] + 32768) >> 16).clamp(0, 255)) as u8;
                row[x * 4 + channel] = value.min(alpha);
            }
        }
    });
    out
}

/// Runs `render` for every output row, split into at most `threads` contiguous
/// chunks. Rows are independent, so the result does not depend on the chunking.
fn for_each_row(
    out: &mut [u8],
    row_bytes: usize,
    threads: usize,
    render: impl Fn(usize, &mut [u8]) + Sync,
) {
    let rows = out.len() / row_bytes;
    let threads = threads.min(rows.max(1)).max(1);
    if threads <= 1 {
        for (row, target) in out.chunks_mut(row_bytes).enumerate() {
            render(row, target);
        }
        return;
    }
    let rows_per_chunk = rows.div_ceil(threads);
    std::thread::scope(|scope| {
        for (chunk_index, chunk) in out.chunks_mut(rows_per_chunk * row_bytes).enumerate() {
            let render = &render;
            let base = chunk_index * rows_per_chunk;
            scope.spawn(move || {
                for (offset, target) in chunk.chunks_mut(row_bytes).enumerate() {
                    render(base + offset, target);
                }
            });
        }
    });
}

/// Fixed-point precision of one coverage weight. Powers of two keep the
/// integer accumulation exact enough that a uniform surface stays uniform.
const COVERAGE_SCALE: f64 = 1024.0;

/// One destination cell's source coverage: the first source index and how much
/// of each following source pixel the cell actually covers.
///
/// A box filter that rounds the span outwards includes a fully covered extra
/// source pixel whenever the ratio is just below 1 (for example 90%), which
/// averages a sharp text edge with its neighbour and reads as blur. Weighting
/// each source pixel by the covered fraction keeps a 90% pin nearly as crisp as
/// 100%, while an exact 50% still averages two pixels as before.
#[derive(Debug)]
struct CoverageSpan {
    start: usize,
    weights: Vec<u32>,
    total: u64,
}

fn coverage_span(index: usize, source_len: usize, target_len: usize) -> CoverageSpan {
    let start_f = index as f64 * source_len as f64 / target_len as f64;
    let end_f = (index + 1) as f64 * source_len as f64 / target_len as f64;
    let first = (start_f.floor() as usize).min(source_len - 1);
    let last = (end_f.ceil() as usize).clamp(first + 1, source_len);
    let mut weights = Vec::with_capacity(last - first);
    let mut total = 0u64;
    for source in first..last {
        let covered = end_f.min((source + 1) as f64) - start_f.max(source as f64);
        let weight = (covered * COVERAGE_SCALE).round().clamp(0.0, COVERAGE_SCALE) as u32;
        weights.push(weight);
        total += u64::from(weight);
    }
    // Rounding can zero every edge weight for a cell narrower than one source
    // pixel. Fall back to the containing pixel so the cell is never empty.
    if total == 0 {
        weights.clear();
        weights.push(COVERAGE_SCALE as u32);
        total = COVERAGE_SCALE as u64;
    }
    CoverageSpan { start: first, weights, total }
}

fn box_reduce(source: &PinImage, width: u32, height: u32, threads: usize) -> Vec<u8> {
    let (source_width, source_height) = (source.width as usize, source.height as usize);
    let (target_width, target_height) = (width as usize, height as usize);
    let mut out = vec![0u8; target_width * target_height * 4];
    let spans: Vec<CoverageSpan> = (0..target_width)
        .map(|x| coverage_span(x, source_width, target_width))
        .collect();
    let bytes = source.bgra.as_ref();
    for_each_row(&mut out, target_width * 4, threads, |y, row| {
        let vertical = coverage_span(y, source_height, target_height);
        for (target_x, horizontal) in spans.iter().enumerate() {
            let mut accumulator = [0u64; 4];
            for (offset_y, weight_y) in vertical.weights.iter().enumerate() {
                let source_y = vertical.start + offset_y;
                let line = &bytes[source_y * source_width * 4..(source_y + 1) * source_width * 4];
                for (offset_x, weight_x) in horizontal.weights.iter().enumerate() {
                    let source_x = horizontal.start + offset_x;
                    let weight = u64::from(*weight_y) * u64::from(*weight_x);
                    let index = source_x * 4;
                    for channel in 0..4 {
                        accumulator[channel] += u64::from(line[index + channel]) * weight;
                    }
                }
            }
            let divisor = vertical.total * horizontal.total;
            let half = divisor / 2;
            for channel in 0..4 {
                row[target_x * 4 + channel] =
                    ((accumulator[channel] + half) / divisor).min(255) as u8;
            }
        }
    });
    out
}

fn bilinear(source: &PinImage, width: u32, height: u32, threads: usize) -> Vec<u8> {
    let (source_width, source_height) = (source.width as usize, source.height as usize);
    let (target_width, target_height) = (width as usize, height as usize);
    // Fixed-point 8-bit weights. Both neighbours are clamped to the last pixel,
    // so the edge of an image never samples outside the buffer.
    let weights: Vec<(usize, usize, u32)> = (0..target_width)
        .map(|target| {
            let center = (target as f64 + 0.5) * source_width as f64 / target_width as f64 - 0.5;
            let base = center.floor();
            let fraction = (center - base).clamp(0.0, 1.0);
            let left = base.clamp(0.0, (source_width - 1) as f64) as usize;
            let right = (base + 1.0).clamp(0.0, (source_width - 1) as f64) as usize;
            (left, right, (fraction * 256.0).round() as u32)
        })
        .collect();
    let vertical: Vec<(usize, usize, u32)> = (0..target_height)
        .map(|target| {
            let center = (target as f64 + 0.5) * source_height as f64 / target_height as f64 - 0.5;
            let base = center.floor();
            let fraction = (center - base).clamp(0.0, 1.0);
            let top = base.clamp(0.0, (source_height - 1) as f64) as usize;
            let bottom = (base + 1.0).clamp(0.0, (source_height - 1) as f64) as usize;
            (top, bottom, (fraction * 256.0).round() as u32)
        })
        .collect();
    let bytes = source.bgra.as_ref();
    let mut out = vec![0u8; target_width * target_height * 4];
    for_each_row(&mut out, target_width * 4, threads, |y, row| {
        let (top, bottom, weight_y) = vertical[y];
        let top_line = &bytes[top * source_width * 4..(top + 1) * source_width * 4];
        let bottom_line = &bytes[bottom * source_width * 4..(bottom + 1) * source_width * 4];
        for (x, &(left, right, weight_x)) in weights.iter().enumerate() {
            let (left_index, right_index) = (left * 4, right * 4);
            let inverse_x = 256 - weight_x;
            let inverse_y = 256 - weight_y;
            for channel in 0..4 {
                let upper = u32::from(top_line[left_index + channel]) * inverse_x
                    + u32::from(top_line[right_index + channel]) * weight_x;
                let lower = u32::from(bottom_line[left_index + channel]) * inverse_x
                    + u32::from(bottom_line[right_index + channel]) * weight_x;
                row[x * 4 + channel] =
                    (((upper * inverse_y + lower * weight_y) >> 16).min(255)) as u8;
            }
        }
    });
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn image(width: u32, height: u32, pixels: &[[u8; 4]]) -> PinImage {
        let mut bytes = Vec::with_capacity(pixels.len() * 4);
        for pixel in pixels {
            bytes.extend_from_slice(pixel);
        }
        PinImage::new(width, height, bytes).unwrap()
    }

    fn gradient(width: u32, height: u32) -> PinImage {
        let mut bytes = Vec::with_capacity(width as usize * height as usize * 4);
        for y in 0..height {
            for x in 0..width {
                let alpha = 255u8;
                let red = ((x * 255) / width.max(1)) as u8;
                let green = ((y * 255) / height.max(1)) as u8;
                let blue = ((x + y) % 256) as u8;
                bytes.extend_from_slice(&[red.min(alpha), green.min(alpha), blue.min(alpha), alpha]);
            }
        }
        PinImage::new(width, height, bytes).unwrap()
    }

    #[test]
    fn one_to_one_never_resamples_or_copies() {
        let source = gradient(64, 48);
        let scaled = resample(&source, 64, 48);
        assert!(Arc::ptr_eq(&scaled, &source.bgra));
    }

    #[test]
    fn mild_shrink_keeps_a_single_pixel_line_sharp() {
        // 100 -> 90 used to average each output cell with a fully covered
        // extra neighbour, halving a one-pixel white line. Coverage weighting
        // must keep its brightness close to the source.
        let mut bytes = vec![0u8; 100 * 4];
        for channel in 0..4 {
            bytes[10 * 4 + channel] = 255;
        }
        let source = PinImage::new(100, 1, bytes).unwrap();
        let scaled = resample(&source, 90, 1);
        let max = scaled.chunks_exact(4).map(|pixel| pixel[0]).max().unwrap();
        let lit = scaled.chunks_exact(4).filter(|pixel| pixel[0] > 0).count();
        assert!(max >= 220, "brightness dropped to {max}");
        assert!(lit <= 2, "the line was smeared over {lit} output pixels");
    }

    #[test]
    fn shrinking_keeps_the_global_average_brightness() {
        let source = image(9, 1, &[[90, 90, 90, 255]; 9]);
        for width in [8u32, 7, 5, 3] {
            let scaled = resample(&source, width, 1);
            for pixel in scaled.chunks_exact(4) {
                assert_eq!(pixel[0], 90, "{width}px");
            }
        }
    }

    #[test]
    fn a_uniform_surface_stays_uniform_at_any_size() {
        let source = image(2, 2, &[[10, 20, 30, 255]; 4]);
        for (width, height) in [(4, 4), (1, 1), (200, 3)] {
            let scaled = resample(&source, width, height);
            for pixel in scaled.chunks_exact(4) {
                assert_eq!(pixel, &[10, 20, 30, 255]);
            }
        }
    }

    #[test]
    fn shrinking_averages_every_source_pixel_instead_of_dropping_rows() {
        // A single opaque white pixel in a 2x1 image must survive a 1x1 shrink
        // as half intensity, not disappear the way nearest-neighbour would.
        let source = image(2, 1, &[[255, 255, 255, 255], [0, 0, 0, 255]]);
        let scaled = resample(&source, 1, 1);
        assert_eq!(scaled[0], 128);
        assert_eq!(scaled[3], 255);
    }

    #[test]
    fn parallel_rows_are_bit_identical_to_a_single_thread() {
        let source = gradient(97, 61);
        for (width, height) in [(20, 13), (193, 122), (383, 244)] {
            let single = resample_with_threads(&source, width, height, 1);
            let parallel = resample_with_threads(&source, width, height, 4);
            assert_eq!(single.as_ref(), parallel.as_ref(), "{width}x{height}");
        }
    }

    #[test]
    fn premultiplied_invariant_survives_both_filters() {
        // Colour channels must never exceed alpha, or the desktop adds light.
        let mut bytes = Vec::new();
        for index in 0..64u32 {
            let alpha = (index * 4) as u8;
            bytes.extend_from_slice(&[alpha / 2, alpha / 3, alpha / 4, alpha]);
        }
        let source = PinImage::new(8, 8, bytes).unwrap();
        for (width, height) in [(3, 3), (17, 17), (64, 8)] {
            let scaled = resample(&source, width, height);
            for pixel in scaled.chunks_exact(4) {
                assert!(pixel[0] <= pixel[3] && pixel[1] <= pixel[3] && pixel[2] <= pixel[3]);
            }
        }
    }

    #[test]
    fn upscaling_preserves_the_corner_pixels_of_an_asymmetric_image() {
        let source = image(2, 2, &[
            [255, 0, 0, 255],
            [0, 255, 0, 255],
            [0, 0, 255, 255],
            [255, 255, 0, 255],
        ]);
        let scaled = resample(&source, 4, 4);
        let at = |x: usize, y: usize| &scaled[(y * 4 + x) * 4..(y * 4 + x) * 4 + 4];
        assert_eq!(at(0, 0), &[255, 0, 0, 255]);
        assert_eq!(at(3, 0), &[0, 255, 0, 255]);
        assert_eq!(at(0, 3), &[0, 0, 255, 255]);
        assert_eq!(at(3, 3), &[255, 255, 0, 255]);
    }

    #[test]
    fn sharp_upscaling_keeps_a_one_pixel_line_brighter_than_bilinear() {
        // A 200% zoom must not smear a one-pixel stem into a half-bright ramp.
        let mut bytes = Vec::new();
        for index in 0..8u8 {
            let value = if index == 3 { 255 } else { 0 };
            bytes.extend_from_slice(&[value, value, value, 255]);
        }
        let source = PinImage::new(8, 1, bytes).unwrap();
        let soft = resample(&source, 16, 1);
        let sharp = resample_sharp(&source, 16, 1);
        let peak = |pixels: &[u8]| pixels.chunks_exact(4).map(|pixel| pixel[0]).max().unwrap();
        assert!(peak(&sharp) > peak(&soft), "sharp {} <= soft {}", peak(&sharp), peak(&soft));
        assert!(peak(&sharp) >= 210, "sharp peak dropped to {}", peak(&sharp));
    }

    #[test]
    fn sharp_upscaling_keeps_uniform_surfaces_uniform() {
        let source = image(2, 2, &[[10, 20, 30, 255]; 4]);
        for (width, height) in [(5, 5), (200, 3), (7, 13)] {
            let scaled = resample_sharp(&source, width, height);
            for pixel in scaled.chunks_exact(4) {
                assert_eq!(pixel, &[10, 20, 30, 255], "{width}x{height}");
            }
        }
    }

    #[test]
    fn sharp_upscaling_preserves_the_premultiplied_invariant() {
        let mut bytes = Vec::new();
        for index in 0..64u32 {
            let alpha = (index * 4) as u8;
            bytes.extend_from_slice(&[alpha / 2, alpha / 3, alpha / 4, alpha]);
        }
        let source = PinImage::new(8, 8, bytes).unwrap();
        for (width, height) in [(17, 17), (64, 8), (33, 41)] {
            let scaled = resample_sharp(&source, width, height);
            for pixel in scaled.chunks_exact(4) {
                assert!(pixel[0] <= pixel[3] && pixel[1] <= pixel[3] && pixel[2] <= pixel[3]);
            }
        }
    }

    #[test]
    fn sharp_parallel_rows_are_bit_identical_to_a_single_thread() {
        let source = gradient(97, 61);
        for (width, height) in [(193, 122), (383, 244), (120, 300)] {
            let single = resample_sharp_with_threads(&source, width, height, 1);
            let parallel = resample_sharp_with_threads(&source, width, height, 4);
            assert_eq!(single.as_ref(), parallel.as_ref(), "{width}x{height}");
        }
    }

    #[test]
    fn sharp_one_to_one_and_shrinking_match_the_fast_path() {
        let source = gradient(64, 48);
        assert!(Arc::ptr_eq(&resample_sharp(&source, 64, 48), &source.bgra));
        let soft = resample(&source, 37, 28);
        let sharp = resample_sharp(&source, 37, 28);
        assert_eq!(soft.as_ref(), sharp.as_ref());
    }

    #[test]
    fn a_zero_sized_request_is_clamped_instead_of_panicking() {
        let source = gradient(8, 8);
        let scaled = resample(&source, 0, 0);
        assert_eq!(scaled.len(), 4);
    }
}

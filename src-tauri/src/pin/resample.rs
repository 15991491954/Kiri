//! Resampling for native pins.
//!
//! A pin is submitted to the desktop as premultiplied BGRA. GDI's `HALFTONE`
//! stretch costs 30 ms for a 4K source even at 1080p and 208 ms at 8K, so a
//! continuous wheel zoom cannot use it. These routines are band-free (every
//! output row is computed independently, so parallel chunks are bit-identical
//! to a single thread) and allocate exactly one output image.

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
/// is what makes 100% sharp and free. Shrinking on both axes uses a box filter
/// (bilinear would skip source pixels and alias text); growing uses bilinear.
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

/// Inclusive source span covered by one destination cell, never empty.
fn source_span(index: usize, source_len: usize, target_len: usize) -> (usize, usize) {
    let start = index * source_len / target_len;
    let end = ((index + 1) * source_len).div_ceil(target_len);
    let end = end.clamp(start + 1, source_len);
    (start.min(source_len - 1), end)
}

fn box_reduce(source: &PinImage, width: u32, height: u32, threads: usize) -> Vec<u8> {
    let (source_width, source_height) = (source.width as usize, source.height as usize);
    let (target_width, target_height) = (width as usize, height as usize);
    let mut out = vec![0u8; target_width * target_height * 4];
    let spans: Vec<(usize, usize)> = (0..target_width)
        .map(|x| source_span(x, source_width, target_width))
        .collect();
    let bytes = source.bgra.as_ref();
    for_each_row(&mut out, target_width * 4, threads, |y, row| {
        let (start_y, end_y) = source_span(y, source_height, target_height);
        let row_count = (end_y - start_y) as u32;
        let mut accumulator = vec![0u32; target_width * 4];
        for source_y in start_y..end_y {
            let line = &bytes[source_y * source_width * 4..(source_y + 1) * source_width * 4];
            for (target_x, &(start_x, end_x)) in spans.iter().enumerate() {
                let slot = target_x * 4;
                for source_x in start_x..end_x {
                    let index = source_x * 4;
                    accumulator[slot] += u32::from(line[index]);
                    accumulator[slot + 1] += u32::from(line[index + 1]);
                    accumulator[slot + 2] += u32::from(line[index + 2]);
                    accumulator[slot + 3] += u32::from(line[index + 3]);
                }
            }
        }
        for target_x in 0..target_width {
            let (start_x, end_x) = spans[target_x];
            let divisor = row_count * (end_x - start_x) as u32;
            let half = divisor / 2;
            for channel in 0..4 {
                let slot = target_x * 4 + channel;
                row[slot] = ((accumulator[slot] + half) / divisor).min(255) as u8;
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
    fn a_zero_sized_request_is_clamped_instead_of_panicking() {
        let source = gradient(8, 8);
        let scaled = resample(&source, 0, 0);
        assert_eq!(scaled.len(), 4);
    }
}

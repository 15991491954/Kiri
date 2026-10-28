# 0121 - Coverage-weighted downscaling for pinned images

Date: 2026-10-25
Status: Accepted

## Context

A native pin displays its snapshot at 100% using the decoded buffer directly,
which is sharp and free. Any other size is produced by the pin resampler. The
previous shrink filter computed each destination cell's source span with a
floor start and a ceiling end, then averaged every source pixel in that span at
full weight.

For a mild reduction such as 90%, each destination cell covers about 1.1 source
pixels. Rounding the span outward therefore included a second, mostly uncovered
source pixel at full weight in many cells. A one-pixel text stem was averaged
with its neighbour and dropped to roughly half contrast, which users reported
as "the pinned text gets blurry as soon as I zoom out a little".

## Decision

Keep the exact 1:1 fast path, keep bilinear growth, and replace the shrink
filter with a coverage-weighted box filter:

- Each destination cell computes its exact source interval
  `[index * source / target, (index + 1) * source / target)`.
- Every overlapped source pixel is weighted by the fraction of the cell it
  covers. Weights are fixed point (1024 units) and normalized by their actual
  sum, so an exact 50% reduction still averages two pixels exactly as before.
- A cell narrower than one source pixel falls back to that pixel, so rounding
  can never produce an empty weight set.
- Row chunks remain independent and deterministic: parallel output stays
  bit-identical to a single thread.

Weighted averaging is linear, so the premultiplied invariant (colour channel
never exceeds alpha) is preserved without extra clamping.

## Consequences

- Mild downscales (90%, 82%, 75%) retain nearly the contrast of 100% instead of
  averaging with an uncovered neighbour; a one-pixel line stays above 220/255
  at 90% in the regression test.
- Exact integer ratios and uniform surfaces are unchanged.
- The filter cost stays close to the previous box filter: each destination
  pixel reads only the source pixels its cell actually overlaps.
- Very small scales are still area-averaged and therefore soften, which is
  expected for a thumbnail-sized reference and is not treated as a defect.

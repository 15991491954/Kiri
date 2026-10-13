# ADR 0106: Include floating windows in macOS hover selection

- Status: Accepted
- Date: 2026-10-13

## Context

Hover selection accepted only windows at level zero. Floating panels and Mimi's
subtitle overlay use higher levels, so clicking them selected a window behind
them or required a manual region.

## Decision

- Include visible third-party windows at every nonnegative level. Do not require
  a title, keyboard focus, or a standard-window accessibility role.
- Use Quartz front-to-back order and require candidates to be in that visible
  snapshot. If Quartz metadata is unavailable altogether, fall back to window
  level and stable ScreenCaptureKit order within each level.
- Keep excluding Kiri's own process, ownerless or hidden windows, desktop layers,
  fully transparent helpers, and rectangles smaller than eight logical pixels
  after clipping to the selected display. Exclude Dock, Window Manager and other
  system chrome: their screen-sized, positive-level helper windows can have
  alpha one while being mostly transparent and must not intercept app selection.
- Keep the existing single hover outline and manual selection behavior. Do not
  change screenshot pixels, recording content filters, or privacy permissions.

## Consequences

Floating and nonactivating panels can be selected with the same hover and click
interaction as regular windows. Tests cover high levels, overlapping windows,
filtering, and negative-coordinate display layouts; native UI acceptance remains
separate from candidate-geometry checks.

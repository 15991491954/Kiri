//! Native pinned screenshots.
//!
//! A pin is a layered Win32 window that owns one premultiplied BGRA snapshot.
//! This module keeps everything that can be decided without a window: the
//! registry of live pins, integer geometry, the hit test, and the byte budgets
//! that bound a desktop full of 4K references.

use std::sync::Arc;

use uuid::Uuid;

use crate::core::geometry::Rect;

#[cfg(windows)]
pub mod clipboard;
pub mod clipboard_source;
pub mod resample;
pub mod surface;
#[cfg(windows)]
pub mod surface_windows;
pub mod text_image;

/// Hard cap on simultaneously open pins. The byte budgets below bind first for
/// large captures; this cap mainly keeps the window list inspectable.
pub const MAX_PINS: usize = 16;
/// Decoded snapshots held by the process. A 4K pin is ~33 MB, so this is the
/// budget that actually limits how many full-screen references can exist.
pub const MAX_PIN_SOURCE_BYTES: u64 = 256 * 1024 * 1024;
/// One scaled frame per pin exists only while the pin is away from 100%.
pub const MAX_PIN_DISPLAY_PIXELS: u64 = 32_000_000;
/// Scaled frames of every pin together. At 4 bytes per pixel this is 256 MB,
/// the same order as the source budget, and it is what keeps a desktop full of
/// zoomed 4K references from doubling the process footprint.
pub const MAX_PIN_DISPLAY_BYTES: u64 = 256 * 1024 * 1024;
/// Smallest usable pin, in physical pixels. It keeps the close controls and the
/// right-click target reachable after zooming out.
pub const MIN_PIN_SIZE: (i32, i32) = (80, 60);
/// Largest physical edge one zoom step may produce.
pub const MAX_PIN_EDGE: i32 = 8000;
/// One wheel notch changes the pin size by 10%; trackpad deltas are continuous.
pub const WHEEL_ZOOM_STEP: f64 = 1.1;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct PinId(pub u64);

impl PinId {
    pub fn label(self) -> String {
        format!("pin-{}", self.0)
    }
}

/// Integer screen rectangle in physical pixels.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PinRect {
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
}

impl PinRect {
    pub const fn new(x: i32, y: i32, width: i32, height: i32) -> Self {
        Self { x, y, width, height }
    }

    pub fn right(self) -> i32 {
        self.x.saturating_add(self.width)
    }

    pub fn bottom(self) -> i32 {
        self.y.saturating_add(self.height)
    }

    /// Half-open containment: the right and bottom edges belong to the next
    /// window, which is what the desktop's own hit test does.
    pub fn contains(self, x: i32, y: i32) -> bool {
        x >= self.x && x < self.right() && y >= self.y && y < self.bottom()
    }

    pub fn from_logical(rect: Rect, scale: f64) -> Self {
        let scale = if scale.is_finite() && scale > 0.0 { scale } else { 1.0 };
        Self::new(
            (rect.x * scale).round() as i32,
            (rect.y * scale).round() as i32,
            ((rect.width * scale).round() as i32).max(1),
            ((rect.height * scale).round() as i32).max(1),
        )
    }

    /// Slides the rectangle inside `bounds` without resizing it. A pin larger
    /// than the work area keeps its top-left corner reachable.
    pub fn clamp_into(self, bounds: PinRect) -> Self {
        let max_x = bounds.right().saturating_sub(self.width);
        let max_y = bounds.bottom().saturating_sub(self.height);
        Self::new(
            self.x.clamp(bounds.x, max_x.max(bounds.x)),
            self.y.clamp(bounds.y, max_y.max(bounds.y)),
            self.width,
            self.height,
        )
    }
}

/// A decoded, premultiplied BGRA snapshot. Pins never share mutable pixels:
/// a new pin decodes its own copy so a later edit of the library asset cannot
/// change what the user already pinned.
#[derive(Clone)]
pub struct PinImage {
    pub width: u32,
    pub height: u32,
    pub bgra: Arc<[u8]>,
}

impl PinImage {
    pub fn new(width: u32, height: u32, bgra: Vec<u8>) -> Option<Self> {
        if width == 0
            || height == 0
            || bgra.len() != width as usize * height as usize * 4
        {
            return None;
        }
        Some(Self { width, height, bgra: Arc::from(bgra) })
    }

    pub fn bytes(&self) -> u64 {
        self.bgra.len() as u64
    }

    pub fn aspect(&self) -> f64 {
        if self.height == 0 {
            1.0
        } else {
            f64::from(self.width) / f64::from(self.height)
        }
    }

    /// Converts non-premultiplied RGBA (what image decoders and the clipboard
    /// produce) into the premultiplied BGRA that `UpdateLayeredWindow` expects.
    pub fn from_rgba(width: u32, height: u32, rgba: &[u8]) -> Option<Self> {
        let pixels = width as usize * height as usize;
        if width == 0 || height == 0 || rgba.len() != pixels * 4 {
            return None;
        }
        let mut bgra = Vec::with_capacity(rgba.len());
        for pixel in rgba.chunks_exact(4) {
            let alpha = u32::from(pixel[3]);
            // Premultiplication must round down so no channel can exceed alpha.
            let scale = |value: u8| (u32::from(value) * alpha / 255) as u8;
            bgra.push(scale(pixel[2]));
            bgra.push(scale(pixel[1]));
            bgra.push(scale(pixel[0]));
            bgra.push(pixel[3]);
        }
        Self::new(width, height, bgra)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PinOrigin {
    /// A library capture; the asset id survives for editor/library entries.
    Asset(Uuid),
    /// Ephemeral clipboard content: never written to the library or to disk.
    Clipboard,
}

#[derive(Debug, Clone)]
pub struct PinRecord {
    /// Session-local identity; the label is the stable key the surface and the
    /// persistence layer use.
    #[allow(dead_code)]
    pub id: PinId,
    pub label: String,
    pub hwnd: isize,
    pub frame: PinRect,
    #[allow(dead_code)] // Read by the P2 persistence layer.
    pub origin: PinOrigin,
    pub wants_topmost: bool,
    pub source_bytes: u64,
    pub display_bytes: u64,
}

/// Metadata for the live pins. Images stay with their windows; the registry
/// only tracks identity, geometry, z-order, and the two byte budgets.
#[derive(Default)]
pub struct PinRegistry {
    next_id: u64,
    pins: Vec<PinRecord>,
    source_bytes: u64,
    display_bytes: u64,
}

impl PinRegistry {
    pub fn insert(
        &mut self,
        hwnd: isize,
        frame: PinRect,
        origin: PinOrigin,
        source_bytes: u64,
    ) -> Result<PinId, String> {
        if self.pins.len() >= MAX_PINS {
            return Err("Close a pinned image before pinning another.".into());
        }
        if self.source_bytes.saturating_add(source_bytes) > MAX_PIN_SOURCE_BYTES {
            return Err("Close a pinned image before pinning another.".into());
        }
        self.next_id += 1;
        let id = PinId(self.next_id);
        self.source_bytes += source_bytes;
        self.pins.push(PinRecord {
            id,
            label: id.label(),
            hwnd,
            frame,
            origin,
            wants_topmost: true,
            source_bytes,
            display_bytes: 0,
        });
        Ok(id)
    }

    pub fn remove_by_label(&mut self, label: &str) -> Option<PinRecord> {
        let index = self.pins.iter().position(|pin| pin.label == label)?;
        let pin = self.pins.remove(index);
        self.source_bytes = self.source_bytes.saturating_sub(pin.source_bytes);
        self.display_bytes = self.display_bytes.saturating_sub(pin.display_bytes);
        Some(pin)
    }

    pub fn remove_by_hwnd(&mut self, hwnd: isize) -> Option<PinRecord> {
        let label = self.pins.iter().find(|pin| pin.hwnd == hwnd)?.label.clone();
        self.remove_by_label(&label)
    }

    #[allow(dead_code)] // Kept for the persistence layer, which resolves by label.
    pub fn get(&self, label: &str) -> Option<&PinRecord> {
        self.pins.iter().find(|pin| pin.label == label)
    }

    pub fn len(&self) -> usize {
        self.pins.len()
    }

    pub fn is_empty(&self) -> bool {
        self.pins.is_empty()
    }

    pub fn source_bytes(&self) -> u64 {
        self.source_bytes
    }

    pub fn display_bytes(&self) -> u64 {
        self.display_bytes
    }

    /// Replaces the display-buffer accounting of one pin.
    pub fn set_display_bytes(&mut self, label: &str, bytes: u64) {
        if let Some(pin) = self.pins.iter_mut().find(|pin| pin.label == label) {
            self.display_bytes = self.display_bytes.saturating_sub(pin.display_bytes);
            pin.display_bytes = bytes;
            self.display_bytes = self.display_bytes.saturating_add(bytes);
        }
    }

    /// Bytes of the scaled frame one pin currently owns.
    pub fn display_bytes_of(&self, label: &str) -> u64 {
        self.pins
            .iter()
            .find(|pin| pin.label == label)
            .map(|pin| pin.display_bytes)
            .unwrap_or(0)
    }

    pub fn set_frame(&mut self, label: &str, frame: PinRect) {
        if let Some(pin) = self.pins.iter_mut().find(|pin| pin.label == label) {
            pin.frame = frame;
        }
    }

    #[allow(dead_code)] // Used when a window handle is rebound after a thread restart.
    pub fn set_hwnd(&mut self, label: &str, hwnd: isize) {
        if let Some(pin) = self.pins.iter_mut().find(|pin| pin.label == label) {
            pin.hwnd = hwnd;
        }
    }

    pub fn set_topmost(&mut self, label: &str, on_top: bool) {
        if let Some(pin) = self.pins.iter_mut().find(|pin| pin.label == label) {
            pin.wants_topmost = on_top;
        }
    }

    /// Brings a pin above its siblings. Pins share one topmost band, and the
    /// list order is the band order, so raising means moving to the end.
    pub fn raise(&mut self, label: &str) {
        if let Some(index) = self.pins.iter().position(|pin| pin.label == label) {
            let pin = self.pins.remove(index);
            self.pins.push(pin);
        }
    }

    /// Topmost pin under a screen point, using half-open rectangles.
    ///
    /// The live Escape path resolves the window with `WindowFromPoint`, which
    /// also respects transparent pixels; this pure hit test stays as the
    /// tested definition of the geometry and for callers without a window.
    #[allow(dead_code)]
    pub fn label_at(&self, x: i32, y: i32) -> Option<&str> {
        self.record_at(x, y).map(|pin| pin.label.as_str())
    }

    /// Handle of the topmost pin whose photo contains a screen point.
    ///
    /// Hit testing deliberately excludes the glow band, and the zoom badge is
    /// its own click-through window, so `WindowFromPoint` can report the window
    /// underneath while the user is still pointing at a pin. The registry order
    /// is the band order (last raised is on top).
    pub fn hwnd_at(&self, x: i32, y: i32) -> Option<isize> {
        self.record_at(x, y).map(|pin| pin.hwnd)
    }

    /// The topmost pin whose photo contains a screen point.
    fn record_at(&self, x: i32, y: i32) -> Option<&PinRecord> {
        self.pins.iter().rev().find(|pin| pin.frame.contains(x, y))
    }

    pub fn labels(&self) -> impl Iterator<Item = (&str, isize, bool)> {
        self.pins
            .iter()
            .map(|pin| (pin.label.as_str(), pin.hwnd, pin.wants_topmost))
    }
}

/// Initial frame for a pin whose origin is the pointer (clipboard pins).
///
/// The snapshot opens at 1:1 physical pixels, shrinks only when it would leave
/// the work area at 80%, is centred on the pointer, and cascades deeper pins so
/// a burst of clipboard pins stays distinguishable.
pub fn initial_frame(
    image: (u32, u32),
    pointer: (f64, f64),
    workarea: PinRect,
    cascade: usize,
) -> PinRect {
    let (mut width, mut height) = (image.0.max(1) as i32, image.1.max(1) as i32);
    let limit_width = ((f64::from(workarea.width) * 0.8).round() as i32).max(MIN_PIN_SIZE.0);
    let limit_height = ((f64::from(workarea.height) * 0.8).round() as i32).max(MIN_PIN_SIZE.1);
    if width > limit_width || height > limit_height {
        let scale = (f64::from(limit_width) / f64::from(width))
            .min(f64::from(limit_height) / f64::from(height));
        width = ((f64::from(width) * scale).round() as i32).max(MIN_PIN_SIZE.0);
        height = ((f64::from(height) * scale).round() as i32).max(MIN_PIN_SIZE.1);
    }
    let offset = (cascade % 8) as i32 * 24;
    // A work area narrower than the minimum pin must clamp to its own origin
    // instead of panicking on an inverted range.
    let clamp_axis = |value: i32, min: i32, max: i32| value.clamp(min, max.max(min));
    PinRect::new(
        clamp_axis(
            pointer.0.round() as i32 - width / 2 + offset,
            workarea.x,
            workarea.right() - width,
        ),
        clamp_axis(
            pointer.1.round() as i32 - height / 2 + offset,
            workarea.y,
            workarea.bottom() - height,
        ),
        width,
        height,
    )
    .clamp_into(workarea)
}

/// Smallest edge the pin may shrink to at this display scale.
fn minimum_size(scale: f64) -> (i32, i32) {
    let scale = if scale.is_finite() && scale > 0.0 { scale } else { 1.0 };
    (
        ((f64::from(MIN_PIN_SIZE.0) * scale).round() as i32).max(1),
        ((f64::from(MIN_PIN_SIZE.1) * scale).round() as i32).max(1),
    )
}

/// Scales a pin around the pointer and keeps the image aspect ratio.
///
/// `anchor` is the pointer position inside the window as a fraction of its
/// width and height, so the content under the cursor stays put while the pin
/// grows or shrinks. Bounds apply to the result: a burst that overshoots stops
/// at the bound without reporting an error.
pub fn zoom_frame(
    frame: PinRect,
    factor: f64,
    anchor: (f64, f64),
    aspect: Option<f64>,
    scale: f64,
) -> PinRect {
    zoom_frame_within(frame, factor, anchor, aspect, scale, None)
}

/// [`zoom_frame`] with the snapshot's own size as a hard floor.
///
/// The generic minimum exists so a pin never collapses into an unusable
/// sliver, but a wide, short card (pasted text) hits the
/// `minimum_height * aspect` rule long before 100%: a 400x48 card with a 60 DIP
/// minimum height stops shrinking at 150% and can never be restored. Capping
/// the floor at the image's own pixels keeps 100% reachable for every shape.
pub fn zoom_frame_within(
    frame: PinRect,
    factor: f64,
    anchor: (f64, f64),
    aspect: Option<f64>,
    scale: f64,
    source: Option<(u32, u32)>,
) -> PinRect {
    let current_width = f64::from(frame.width.max(1));
    let current_height = f64::from(frame.height.max(1));
    let aspect = match aspect {
        Some(value) if value.is_finite() && value >= 0.01 => value,
        _ => current_width / current_height,
    };
    let factor = if factor.is_finite() { factor.clamp(0.05, 20.0) } else { 1.0 };

    let (min_width, min_height) = minimum_size(scale);
    let (min_width, min_height) = match source {
        Some((source_width, source_height)) => (
            f64::from(min_width.max(1)).min(f64::from(source_width.max(1))),
            f64::from(min_height.max(1)).min(f64::from(source_height.max(1))),
        ),
        None => (f64::from(min_width), f64::from(min_height)),
    };
    let minimum_width = min_width.max(min_height * aspect);
    let edge = f64::from(MAX_PIN_EDGE);
    // Width times height must stay inside the pixel budget: with a fixed
    // aspect `a`, the widest allowed frame is `sqrt(pixels * a)`. Dividing by
    // the aspect instead would stop wide screenshots at a fraction of the
    // budget, which read as "zoom stops at 110%" on a 4K capture.
    let pixel_edge = (MAX_PIN_DISPLAY_PIXELS as f64 * aspect).sqrt();

    let mut width = (current_width * factor)
        .clamp(minimum_width.min(edge.min(pixel_edge)), edge.min(pixel_edge));
    let mut height = width / aspect;
    if height > edge {
        height = edge;
        width = height * aspect;
    }
    if height < min_height {
        height = min_height;
        width = (height * aspect).max(minimum_width);
    }
    let mut width = width.round().max(1.0);
    let mut height = height.round().max(1.0);
    // Rounding both edges up can leave the frame a row past the pixel budget
    // (6532x4899 is 268 pixels over 32 MP). Shrinking whole pixels of width
    // while keeping the aspect ratio makes the budget a hard bound instead of
    // an approximation the renderer has to tolerate.
    while (width as u64).saturating_mul(height as u64) > MAX_PIN_DISPLAY_PIXELS && width > 1.0 {
        width -= 1.0;
        height = (width / aspect).round().max(1.0);
    }
    let anchor_x = if anchor.0.is_finite() { anchor.0.clamp(0.0, 1.0) } else { 0.5 };
    let anchor_y = if anchor.1.is_finite() { anchor.1.clamp(0.0, 1.0) } else { 0.5 };
    PinRect::new(
        (f64::from(frame.x) + anchor_x * (current_width - width)).round() as i32,
        (f64::from(frame.y) + anchor_y * (current_height - height)).round() as i32,
        width as i32,
        height as i32,
    )
}

/// Zoom percentage against the snapshot's own pixels: 100% is one image pixel
/// per physical screen pixel.
pub fn zoom_percent(frame: PinRect, image_width: u32) -> i64 {
    if image_width == 0 {
        return 100;
    }
    ((f64::from(frame.width) / f64::from(image_width)) * 100.0).round() as i64
}

/// Bytes a pin's displayed frame needs, or zero when the pin is exactly 1:1 and
/// shows the snapshot buffer itself.
pub fn frame_bytes(frame: PinRect, image: (u32, u32)) -> u64 {
    if frame.width == image.0 as i32 && frame.height == image.1 as i32 {
        return 0;
    }
    u64::from(frame.width.max(0) as u32)
        .saturating_mul(u64::from(frame.height.max(0) as u32))
        .saturating_mul(4)
}

/// True when one more scaled frame still fits the shared display budget.
///
/// The caller passes what every other pin already holds, so the pin being
/// zoomed replaces its own frame instead of counting it twice.
pub fn display_budget_allows(other_pins_bytes: u64, next_frame_bytes: u64) -> bool {
    other_pins_bytes.saturating_add(next_frame_bytes) <= MAX_PIN_DISPLAY_BYTES
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rect() -> PinRect {
        PinRect::new(100, 100, 400, 200)
    }

    /// A pasted text card is wide and short. The generic 60 DIP minimum height
    /// used to force `minimum_height * aspect` width, so a 400x48 card could
    /// never shrink below ~139%: reported as "stuck at 138%".
    #[test]
    fn a_short_text_card_can_shrink_back_to_its_own_pixels() {
        let image = (400_u32, 48_u32);
        let aspect = 400.0 / 48.0;
        let frame = PinRect::new(0, 0, 552, 66);
        let next = zoom_frame_within(frame, 0.5, (0.5, 0.5), Some(aspect), 1.0, Some(image));
        assert_eq!((next.width, next.height), (400, 48));
        let percent = zoom_percent(next, image.0);
        assert_eq!(percent, 100);
    }

    #[test]
    fn the_minimum_floor_still_applies_without_a_source_size() {
        let frame = PinRect::new(0, 0, 552, 66);
        let next = zoom_frame(frame, 0.01, (0.5, 0.5), Some(552.0 / 66.0), 1.0);
        assert!(next.width >= MIN_PIN_SIZE.0);
        assert!(next.height >= MIN_PIN_SIZE.1);
    }

    #[test]
    fn registry_rejects_the_seventeenth_pin_without_changing_state() {
        let mut registry = PinRegistry::default();
        for index in 0..MAX_PINS {
            registry
                .insert(index as isize, rect(), PinOrigin::Clipboard, 1024)
                .unwrap();
        }
        let before = registry.source_bytes();
        assert!(registry
            .insert(99, rect(), PinOrigin::Clipboard, 1024)
            .is_err());
        assert_eq!(registry.len(), MAX_PINS);
        assert_eq!(registry.source_bytes(), before);
    }

    #[test]
    fn source_budget_refuses_a_pin_that_would_exceed_it() {
        let mut registry = PinRegistry::default();
        let per_pin = MAX_PIN_SOURCE_BYTES / 4;
        for index in 0..4 {
            registry
                .insert(index as isize, rect(), PinOrigin::Clipboard, per_pin)
                .unwrap();
        }
        assert_eq!(registry.source_bytes(), MAX_PIN_SOURCE_BYTES);
        assert!(registry
            .insert(4, rect(), PinOrigin::Clipboard, 1)
            .is_err());
        // Refusing must not consume an id or bytes.
        assert_eq!(registry.len(), 4);
    }

    #[test]
    fn removing_a_pin_returns_both_budgets_and_frees_its_label() {
        let mut registry = PinRegistry::default();
        let first = registry
            .insert(1, rect(), PinOrigin::Clipboard, 4096)
            .unwrap();
        registry.set_display_bytes(&first.label(), 8192);
        assert_eq!(registry.source_bytes(), 4096);
        assert_eq!(registry.display_bytes(), 8192);
        let removed = registry.remove_by_label(&first.label()).unwrap();
        assert_eq!(removed.id, first);
        assert_eq!(registry.source_bytes(), 0);
        assert_eq!(registry.display_bytes(), 0);
        assert!(registry.is_empty());
        let second = registry
            .insert(2, rect(), PinOrigin::Clipboard, 0)
            .unwrap();
        assert_ne!(second, first);
    }

    #[test]
    fn hit_test_prefers_the_raised_pin_and_uses_half_open_edges() {
        let mut registry = PinRegistry::default();
        let lower = registry
            .insert(1, PinRect::new(0, 0, 100, 100), PinOrigin::Clipboard, 0)
            .unwrap();
        let upper = registry
            .insert(2, PinRect::new(50, 50, 100, 100), PinOrigin::Clipboard, 0)
            .unwrap();
        assert_eq!(registry.label_at(60, 60), Some(upper.label().as_str()));
        // A point inside only the lower pin.
        assert_eq!(registry.label_at(10, 10), Some(lower.label().as_str()));
        // The right/bottom edges belong to whatever is behind.
        assert_eq!(registry.label_at(100, 100), Some(upper.label().as_str()));
        assert_eq!(registry.label_at(150, 150), None);
        registry.raise(&lower.label());
        assert_eq!(registry.label_at(60, 60), Some(lower.label().as_str()));
    }

    #[test]
    fn negative_monitor_coordinates_hit_correctly() {
        let mut registry = PinRegistry::default();
        registry
            .insert(1, PinRect::new(-1440, -200, 400, 300), PinOrigin::Clipboard, 0)
            .unwrap();
        assert!(registry.label_at(-1200, 0).is_some());
        assert!(registry.label_at(0, 0).is_none());
        // Escape closes the pin under the pointer by handle, not only by label.
        assert_eq!(registry.hwnd_at(-1200, 0), Some(1));
        assert_eq!(registry.hwnd_at(0, 0), None);
    }

    #[test]
    fn zoom_keeps_the_pointer_anchor_fixed() {
        let frame = PinRect::new(100, 100, 400, 200);
        let centre = zoom_frame(frame, 2.0, (0.5, 0.5), Some(2.0), 1.0);
        assert_eq!(centre, PinRect::new(-100, 0, 800, 400));
        let corner = zoom_frame(frame, 2.0, (0.0, 0.0), Some(2.0), 1.0);
        assert_eq!(corner, PinRect::new(100, 100, 800, 400));
        let far = zoom_frame(frame, 2.0, (1.0, 1.0), Some(2.0), 1.0);
        assert_eq!(far, PinRect::new(-300, -100, 800, 400));
    }

    #[test]
    fn zoom_out_stops_at_the_minimum_size_and_keeps_the_aspect_ratio() {
        let frame = PinRect::new(0, 0, 800, 400);
        let tiny = zoom_frame(frame, 0.01, (0.5, 0.5), Some(2.0), 1.0);
        // The 60px minimum height binds first and keeps the 2:1 ratio.
        assert_eq!((tiny.width, tiny.height), (120, 60));
        // A tall image binds on width instead.
        let tall = zoom_frame(PinRect::new(0, 0, 800, 3200), 0.01, (0.5, 0.5), Some(0.25), 1.0);
        assert_eq!(tall.width, 80);
        assert_eq!(tall.height, 320);
    }

    #[test]
    fn zoom_never_exceeds_the_edge_or_pixel_caps() {
        let frame = PinRect::new(0, 0, 400, 200);
        let huge = zoom_frame(frame, 1000.0, (0.5, 0.5), Some(2.0), 1.0);
        assert!(huge.width <= MAX_PIN_EDGE);
        let pixels = u64::try_from(huge.width).expect("pin width is positive")
            * u64::try_from(huge.height).expect("pin height is positive");
        assert!(pixels <= MAX_PIN_DISPLAY_PIXELS);
        // The cap clamps instead of reporting an error, and the pin stops moving.
        let again = zoom_frame(huge, 2.0, (0.5, 0.5), Some(2.0), 1.0);
        assert_eq!(huge, again);
    }

    #[test]
    fn every_aspect_ratio_stays_inside_the_pixel_budget_after_rounding() {
        // 6532x4899 was 268 pixels past 32 MP before the strict clamp: a
        // 4:3 capture at the ceiling is the case whole-pixel rounding breaks.
        for aspect in [0.25f64, 0.5, 0.75, 1.0, 4.0 / 3.0, 16.0 / 9.0, 2.0, 3.5] {
            let width = (400.0 * aspect).round().max(1.0) as i32;
            let frame = PinRect::new(0, 0, width.max(1), 400);
            let huge = zoom_frame(frame, 1000.0, (0.5, 0.5), Some(aspect), 1.0);
            let pixels = u64::try_from(huge.width).expect("width is positive")
                * u64::try_from(huge.height).expect("height is positive");
            assert!(
                pixels <= MAX_PIN_DISPLAY_PIXELS,
                "aspect={aspect} size={}x{} pixels={pixels}",
                huge.width,
                huge.height
            );
            assert!(huge.height <= MAX_PIN_EDGE && huge.width <= MAX_PIN_EDGE);
        }
    }

    #[test]
    fn minimum_size_doubles_on_a_two_hundred_percent_display() {
        let frame = PinRect::new(0, 0, 1600, 800);
        let tiny = zoom_frame(frame, 0.001, (0.5, 0.5), Some(2.0), 2.0);
        // 80x60 DIP at 200% is 160x120 physical, and the 2:1 ratio widens it.
        assert_eq!((tiny.width, tiny.height), (240, 120));
    }

    #[test]
    fn initial_frame_opens_at_native_size_and_shrinks_only_to_fit() {
        let workarea = PinRect::new(0, 0, 1920, 1080);
        let native = initial_frame((400, 300), (900.0, 500.0), workarea, 0);
        assert_eq!((native.width, native.height), (400, 300));
        assert_eq!((native.x, native.y), (700, 350));
        let big = initial_frame((3840, 2160), (900.0, 500.0), workarea, 0);
        assert!(big.width <= 1536 && big.height <= 864);
        assert!((f64::from(big.width) / f64::from(big.height) - 16.0 / 9.0).abs() < 0.01);
        let edge = initial_frame((400, 300), (1915.0, 1075.0), workarea, 0);
        assert_eq!((edge.x, edge.y), (1520, 780));
    }

    #[test]
    fn cascaded_pins_are_offset_but_stay_inside_the_work_area() {
        let workarea = PinRect::new(-1440, 0, 1440, 900);
        let first = initial_frame((300, 200), (-700.0, 450.0), workarea, 0);
        let second = initial_frame((300, 200), (-700.0, 450.0), workarea, 1);
        assert_eq!(second.x - first.x, 24);
        assert_eq!(second.y - first.y, 24);
        assert!(second.x >= workarea.x && second.right() <= workarea.right());
    }

    #[test]
    fn a_work_area_smaller_than_the_minimum_pin_does_not_panic() {
        // A tiny or degraded display (or a transient monitor report) must clamp
        // to its own origin instead of building an inverted clamp range.
        let tiny = PinRect::new(0, 0, 10, 10);
        let frame = initial_frame((400, 300), (10.0, 10.0), tiny, 0);
        assert_eq!((frame.x, frame.y), (0, 0));
        assert!(frame.width >= MIN_PIN_SIZE.0 && frame.height >= MIN_PIN_SIZE.1);
    }

    #[test]
    fn wide_images_use_the_whole_pixel_budget_instead_of_stopping_early() {
        // A 16:9 capture must be able to zoom until the frame fills the pixel
        // budget; the old aspect division capped this at ~110% of native.
        let aspect = 16.0 / 9.0;
        let frame = PinRect::new(0, 0, 3840, 2160);
        let huge = zoom_frame(frame, 1000.0, (0.5, 0.5), Some(aspect), 1.0);
        let pixels = u64::try_from(huge.width).expect("width is positive")
            * u64::try_from(huge.height).expect("height is positive");
        // The budget is a hard bound even after whole-pixel rounding.
        assert!(pixels <= MAX_PIN_DISPLAY_PIXELS, "{pixels}");
        assert!(
            pixels >= MAX_PIN_DISPLAY_PIXELS * 99 / 100,
            "a 16:9 frame should reach the budget, got {pixels}"
        );
        assert!(huge.width as f64 / f64::from(huge.height) - aspect < 0.01);
    }

    #[test]
    fn zoom_percentage_is_measured_against_the_image_pixels() {
        assert_eq!(zoom_percent(PinRect::new(0, 0, 400, 200), 400), 100);
        assert_eq!(zoom_percent(PinRect::new(0, 0, 200, 100), 400), 50);
        assert_eq!(zoom_percent(PinRect::new(0, 0, 600, 300), 400), 150);
        assert_eq!(zoom_percent(PinRect::new(0, 0, 0, 0), 0), 100);
    }

    #[test]
    fn a_shared_display_budget_counts_every_other_pin_exactly_once() {
        let image = (3840, 2160);
        // At 1:1 the snapshot buffer is the displayed frame, so it costs zero.
        assert_eq!(frame_bytes(PinRect::new(0, 0, 3840, 2160), image), 0);
        assert_eq!(frame_bytes(PinRect::new(0, 0, 1920, 1080), image), 1920 * 1080 * 4);
        let frame = 3840u64 * 2160 * 4;
        // Eight 4K scaled frames are ~253 MB and fit; nine are ~285 MB and do not.
        assert!(display_budget_allows(frame * 7, frame));
        assert!(!display_budget_allows(frame * 8, frame));
        // Bounds that overshoot saturate instead of wrapping.
        assert!(!display_budget_allows(u64::MAX, frame));
        assert_eq!(frame_bytes(PinRect::new(0, 0, 0, 0), (0, 0)), 0);
    }

    #[test]
    fn registry_reports_the_display_bytes_of_one_pin() {
        let mut registry = PinRegistry::default();
        let first = registry.insert(1, rect(), PinOrigin::Clipboard, 0).unwrap();
        let second = registry.insert(2, rect(), PinOrigin::Clipboard, 0).unwrap();
        registry.set_display_bytes(&first.label(), 1024);
        registry.set_display_bytes(&second.label(), 2048);
        assert_eq!(registry.display_bytes(), 3072);
        assert_eq!(registry.display_bytes_of(&first.label()), 1024);
        assert_eq!(registry.display_bytes_of("missing"), 0);
        registry.set_display_bytes(&first.label(), 0);
        assert_eq!(registry.display_bytes(), 2048);
    }

    #[test]
    fn premultiplied_conversion_never_leaves_a_channel_above_alpha() {
        let rgba = [255u8, 128, 0, 128, 10, 20, 30, 0, 200, 200, 200, 255];
        let image = PinImage::from_rgba(3, 1, &rgba).unwrap();
        for pixel in image.bgra.chunks_exact(4) {
            assert!(pixel[0] <= pixel[3] && pixel[1] <= pixel[3] && pixel[2] <= pixel[3]);
        }
        assert_eq!(&image.bgra[..], &[0, 64, 128, 128, 0, 0, 0, 0, 200, 200, 200, 255]);
    }
}

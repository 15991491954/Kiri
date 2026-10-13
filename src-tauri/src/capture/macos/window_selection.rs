//! Window hover includes floating/nonactivating panels, regardless of title.
//! ScreenCaptureKit supplies eligible content; Quartz supplies stacking order.

use std::cmp::Reverse;
use std::collections::HashMap;

use objc2_core_foundation::{CFDictionary, CFNumber, CFString, CFType};
use objc2_core_graphics::{
    kCGWindowAlpha, kCGWindowNumber, CGWindowListCopyWindowInfo, CGWindowListOption,
};

use crate::core::geometry::Rect;

pub(super) struct Candidate {
    pub id: u32,
    pub layer: isize,
    pub owner_pid: i32,
    pub on_screen: bool,
    pub frame: Rect,
}

pub(super) fn visible_window_order() -> Vec<(u32, f64)> {
    let Some(windows) = CGWindowListCopyWindowInfo(
        CGWindowListOption::OptionOnScreenOnly | CGWindowListOption::ExcludeDesktopElements,
        0,
    ) else {
        return Vec::new();
    };
    // CGWindowListCopyWindowInfo returns retained CFDictionary objects (unlike
    // CGWindowListCreate, whose array contains raw numeric window IDs).
    let windows = unsafe { windows.cast_unchecked::<CFType>() };
    windows
        .iter()
        .filter_map(|entry| {
            let info = entry.downcast_ref::<CFDictionary>()?;
            let info = unsafe { info.cast_unchecked::<CFString, CFType>() };
            // Quartz returns dictionaries of CFString keys and CFType values.
            let number = info.get(unsafe { kCGWindowNumber })?;
            let id = u32::try_from(number.downcast_ref::<CFNumber>()?.as_i64()?).ok()?;
            let alpha = info
                .get(unsafe { kCGWindowAlpha })
                .and_then(|value| value.downcast_ref::<CFNumber>()?.as_f64())
                .unwrap_or(1.0);
            Some((id, alpha))
        })
        .collect()
}

pub(super) fn candidate_rects(
    mut windows: Vec<Candidate>,
    display: Rect,
    own_pid: i32,
    order: &[(u32, f64)],
) -> Vec<Rect> {
    let stacking: HashMap<_, _> = order
        .iter()
        .enumerate()
        .map(|(index, &(id, alpha))| (id, (index, alpha)))
        .collect();
    windows.retain(|window| {
        window.on_screen
            && window.layer >= 0
            && window.owner_pid > 0
            && window.owner_pid != own_pid
            && stacking
                .get(&window.id)
                .is_none_or(|(_, alpha)| *alpha > 0.0)
    });
    // Nonzero layers include ordinary floating panels and subtitle overlays
    // at the screen-saver level. Same-layer windows follow Quartz front to back;
    // stable sorting retains SCK order if Quartz metadata is unavailable.
    windows.sort_by_key(|window| {
        (
            Reverse(window.layer),
            stacking
                .get(&window.id)
                .map(|(index, _)| *index)
                .unwrap_or(usize::MAX),
        )
    });
    windows
        .into_iter()
        .filter_map(|window| {
            let frame = window.frame;
            if ![frame.x, frame.y, frame.width, frame.height]
                .iter()
                .all(|v| v.is_finite())
            {
                return None;
            }
            let x = frame.x.max(display.x);
            let y = frame.y.max(display.y);
            let width = (frame.x + frame.width).min(display.x + display.width) - x;
            let height = (frame.y + frame.height).min(display.y + display.height) - y;
            // Both APIs use global top-left coordinates. Only translate to display
            // local coordinates; flipping y would mirror the hover rectangle.
            (width >= 8.0 && height >= 8.0)
                .then(|| Rect::new(x - display.x, y - display.y, width, height))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn window(id: u32, layer: isize) -> Candidate {
        Candidate {
            id,
            layer,
            owner_pid: 20,
            on_screen: true,
            frame: Rect::new(100.0 + f64::from(id), 100.0, 300.0, 120.0),
        }
    }
    const DISPLAY: Rect = Rect {
        x: 0.0,
        y: 0.0,
        width: 1440.0,
        height: 900.0,
    };

    #[test]
    fn floating_panels_and_mimi_level_overlay_precede_normal_windows() {
        let layers = [0, 3, 8, 25, 101, 1000];
        let windows = layers
            .iter()
            .enumerate()
            .map(|(id, &layer)| window(id as u32, layer))
            .collect();
        let rects = candidate_rects(windows, DISPLAY, 99, &[]);
        assert_eq!(
            rects.iter().map(|rect| rect.x).collect::<Vec<_>>(),
            vec![105.0, 104.0, 103.0, 102.0, 101.0, 100.0]
        );
    }

    #[test]
    fn same_layer_uses_actual_front_to_back_order_and_falls_back_stably() {
        let make = || vec![window(1, 0), window(2, 0), window(3, 0)];
        let ordered = candidate_rects(make(), DISPLAY, 99, &[(3, 1.0), (1, 1.0), (2, 1.0)]);
        assert_eq!(
            ordered.iter().map(|rect| rect.x).collect::<Vec<_>>(),
            vec![103.0, 101.0, 102.0]
        );
        let fallback = candidate_rects(make(), DISPLAY, 99, &[]);
        assert_eq!(
            fallback.iter().map(|rect| rect.x).collect::<Vec<_>>(),
            vec![101.0, 102.0, 103.0]
        );
    }

    #[test]
    fn excludes_own_hidden_desktop_transparent_and_invalid_windows() {
        let mut own = window(1, 1000);
        own.owner_pid = 99;
        let mut hidden = window(2, 1000);
        hidden.on_screen = false;
        let mut ownerless = window(3, 1000);
        ownerless.owner_pid = 0;
        let mut tiny = window(4, 1000);
        tiny.frame.width = 7.0;
        let mut outside = window(5, 1000);
        outside.frame.x = 1500.0;
        let mut invalid = window(6, 1000);
        invalid.frame.x = f64::NAN;
        let rects = candidate_rects(
            vec![
                own,
                hidden,
                ownerless,
                tiny,
                outside,
                invalid,
                window(7, -1),
                window(8, 1000),
                window(9, 1000),
            ],
            DISPLAY,
            99,
            &[(8, 0.0), (9, 0.2)],
        );
        assert_eq!(rects, vec![window(9, 1000).frame]);
    }

    #[test]
    fn clips_cross_display_panels_without_mirroring_negative_coordinates() {
        let display = Rect::new(-1440.0, -100.0, 1440.0, 900.0);
        let mut panel = window(1, 1000);
        panel.frame = Rect::new(-100.0, -120.0, 200.0, 140.0);
        assert_eq!(
            candidate_rects(vec![panel], display, 99, &[]),
            vec![Rect::new(1340.0, 0.0, 100.0, 120.0)]
        );
    }
}

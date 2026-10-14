"""Shared assertions for real, isolated screenshot pinning acceptance."""

import json
import math
from pathlib import Path
import re


def pin_content_evidence(actual, reference, scale):
    """Compare image content without Kiri's CSS frame and rounded corners."""
    from PIL import ImageChops, ImageStat

    if not math.isfinite(scale) or scale <= 0 or actual.size != reference.size:
        raise RuntimeError("Pin pixel comparison needs matching dimensions and a valid display scale")
    # The frame is 2 CSS px with an inner 1px highlight. Four CSS px also
    # clears the antialiased corners without weakening the content threshold.
    inset = math.ceil(4 * scale)
    width, height = actual.size
    if min(width, height) <= 2 * inset:
        raise RuntimeError("Pin is too small for an independent content comparison")
    bounds = (inset, inset, width - inset, height - inset)
    diff = ImageChops.difference(actual.convert("RGB").crop(bounds), reference.convert("RGB").crop(bounds))
    return {"mean_pixel_error": sum(ImageStat.Stat(diff).mean) / 3,
            "content_inset_physical": inset, "display_scale": scale}


def pin_outline_evidence(actual, reference, scale):
    """Sample the straight sides: rounded corners intentionally show the desktop."""
    if not math.isfinite(scale) or scale <= 0 or actual.size != reference.size:
        raise RuntimeError("Pin outline comparison needs matching dimensions and a valid display scale")
    width, height = actual.size
    if min(width, height) <= math.ceil(8 * scale):
        raise RuntimeError("Pin is too small for independent frame samples")
    offset = max(0, round(scale - 0.5))  # Center of the 2 CSS px dark stroke.
    points = [(width // 2, offset), (width - 1 - offset, height // 2),
              (width // 2, height - 1 - offset), (offset, height // 2)]
    actual, reference = actual.convert("RGB"), reference.convert("RGB")
    pixels = [actual.getpixel(point) for point in points]
    contrast = [max(abs(a - b) for a, b in zip(pixel, reference.getpixel(point)))
                for point, pixel in zip(points, pixels)]
    if any(max(pixel) > 64 for pixel in pixels) or min(contrast) < 25:
        raise RuntimeError(f"Pinned reference is missing a dark, visible frame side: pixels={pixels}, contrast={contrast}")
    return {"side_sample_points": points, "side_pixels": pixels,
            "side_contrast": contrast, "display_scale": scale, "visible": True}


def pin_open_log_marker(asset_id):
    # The Swift-compatible library index writes uppercase UUIDs, whereas Rust
    # Display uses lowercase in the native diagnostics.
    return f"[pin] screenshot opened asset_id={asset_id.lower()}"


def pin_lifecycle_evidence(log, asset_id):
    """Use only the log suffix recorded before clicking this capture's Pin."""
    queued = list(re.finditer(r"completion queued until overlay destruction labels=(\d+)", log))
    opened = list(re.finditer(re.escape(pin_open_log_marker(asset_id)) + r"\b", log))
    if len(queued) != 1 or len(opened) != 1:
        raise RuntimeError("Direct pin must queue one completion and open its saved asset once")
    destroyed = list(re.finditer(r"\[window\] destroyed label=(overlay[^\s]*)", log))
    count = int(queued[0].group(1))
    labels = [event.group(1) for event in destroyed]
    if count < 1 or len(labels) != count or len(set(labels)) != count:
        raise RuntimeError(f"Expected destruction of all {count} capture overlays, got {labels}")
    if not all(queued[0].start() < event.start() < opened[0].start() for event in destroyed):
        raise RuntimeError("A pin opened before every confirmed capture overlay was destroyed")
    return {"queued_overlay_count": count, "destroyed_overlays": labels,
            "pin_after_all_overlay_destroyed": True, "opened_once": True}


def proportional_resize_evidence(before, after):
    if min(before) <= 0 or min(after) <= 0:
        raise RuntimeError("Pin dimensions must be positive")
    if after[0] < before[0] + 20 or after[1] < before[1] + 10:
        raise RuntimeError(f"The corner drag did not grow the pin: {before} -> {after}")
    relative_error = abs((after[0] / after[1]) / (before[0] / before[1]) - 1)
    if relative_error > 0.015:
        raise RuntimeError(f"Corner resizing changed aspect: {before} -> {after}")
    return {"before": list(before), "after": list(after), "relative_aspect_error": relative_error}


def borderless_geometry_evidence(client, outer):
    if len(client) != 4 or len(outer) != 4 or client[2] <= client[0] or client[3] <= client[1]:
        raise RuntimeError("Pin must have positive native client dimensions")
    if any(abs(a - b) > 1 for a, b in zip(client, outer)):
        raise RuntimeError(f"Pin has a nonclient frame: client={client}, window={outer}")
    return {"client": list(client), "window": list(outer), "native_nonclient_frame": False}


def capture_origin_evidence(actual, selected):
    """Native screen pixels must retain both the selection origin and size."""
    if len(actual) != 4 or len(selected) != 4 or any(abs(a - b) > 1 for a, b in zip(actual, selected)):
        raise RuntimeError(f"Pin moved or resized the capture: selected={selected}, actual={actual}")
    return {"selected": list(selected), "initial_pin": list(actual), "matches_capture_region": True}


def annotated_capture_evidence(library, asset, source, copied):
    from PIL import Image, ImageChops, ImageStat

    filename = Path(asset["filename"])
    if filename.name != str(filename):
        raise RuntimeError("QA capture must stay inside its isolated library")
    image = Image.open(Path(library) / "Assets" / filename).convert("RGB")
    if image.size != source.size or image.size != copied.size:
        raise RuntimeError("Annotated screenshot changed the selected region dimensions")
    clipboard_error = sum(ImageStat.Stat(ImageChops.difference(image, copied.convert("RGB"))).mean) / 3
    if clipboard_error > 1.5:
        raise RuntimeError("Pinned capture's saved PNG differs from its clipboard image")
    changed = ImageChops.difference(image, source.convert("RGB"))
    colored = sum(r > 180 and r > g + 60 and r > b + 40 and max(delta) > 25
                  for (r, g, b), delta in zip(image.getdata(), changed.getdata()))
    if colored < 200:
        raise RuntimeError("Saved PNG is missing the rectangle drawn on the native overlay")
    project = json.loads((Path(library) / "Annotations" / f"{asset['id'].lower()}.json").read_text())
    marks = project["document"]["marks"]
    if len(marks) != 1 or marks[0]["kind"] != "rectangle":
        raise RuntimeError("Direct pin must retain its one editable rectangle annotation")
    return image, {"dimensions": list(image.size), "annotation_pixels": colored,
                   "clipboard_mean_pixel_error": clipboard_error, "editable_rectangle_retained": True}

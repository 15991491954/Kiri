// OverlayWindow — capture overlay: mode selector, window hover, region
// selection, annotation toolbar, OCR, and recording options. Port of
// SelectionOverlayController.swift.

import React, { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { getCurrentWindow } from "@tauri-apps/api/window";
import {
  api,
  onCaptureModeChanged,
  DEFAULT_RECORDING_OPTIONS,
  type CaptureContextDto,
  type PlatformCapabilitiesDto,
  type PreparedOcrRequestDto,
  type QrScanDto,
  type RecordingOptions,
} from "../lib/ipc";
import { t } from "../i18n";
import RecordingMicrophoneSelect from "./RecordingMicrophoneSelect";
import { Mic, MousePointer2, MousePointerClick, Volume2 } from "lucide-react";
import { isTextComposition } from "../annotation/text-composition.js";
import type { Point, Rect } from "../annotation/geom";
import {
  ALL_HANDLES,
  clampPoint,
  contains,
  handlePoint,
  hitTestHandle,
  intersection,
  isValidSelection,
  maxX,
  maxY,
  minX,
  minY,
  normalized,
  resized,
  standardized,
} from "../annotation/geom";
import {
  nextCalloutNumber,
  selectionBounds,
  type AnnotationMark,
  type AppearanceSettings,
  type Tool,
} from "../annotation/model";
import { useAnnotationAppearance } from "../annotation/useAnnotationAppearance";
import {AnnotationStyleControls} from "../annotation/AnnotationStyleControls";
import AnnotationCanvas, { type AnnotationCanvasHandle } from "../annotation/AnnotationCanvas";
import { AnnotationInteractionLock } from "../annotation/interaction-lock.js";
import { interactionCursor } from "../annotation/cursors.js";
import {
  canSwitchMode,
  cycleMode,
  idleWheelState,
  modeForKey,
  normalizeWheelDelta,
  wheelModeStep,
} from "../annotation/mode-switching.js";
import { KiriIcon, type IconName } from "../components/KiriIcons";
import { AnnotationToolbarButton } from "../components/AnnotationToolbarButton";
import { QrOverlay } from "../qr/QrOverlay";
import { RemoteOcrConsent } from "../ocr/RemoteOcrConsent";
import { kiriResourceUrl } from "../lib/kiri-resource-url.js";
import { capturePanelLayout, captureToolOptionsLayout, captureToolbarPosition, recordingPanelLayout } from "./toolbar-layout.js";
import { CaptureSizeControls } from "./CaptureSizeControls";
import { resizeCapturePixels } from "./capture-size.js";
import { CaptureColorPicker, useCaptureColorPicker } from "./CaptureColorPicker";
import "./capture-tool-options.css";

function recordingStartError(error: unknown): string {
  const message = String(error);
  for (const known of [
    "The selected microphone is unavailable. Choose another microphone and try again.",
    "Microphone access is off. Enable Lumen in System Settings to record your microphone.",
  ]) if (message.includes(known)) return known;
  return "Could not start screen recording.";
}

function scrollingStartError(error: unknown): string {
  const message = String(error);
  for (const known of [
    "Leave room outside the selection for scrolling capture controls.",
    "Select a scrolling area fully inside one application window.",
    "Finish the current scrolling capture first.",
    "Scrolling capture is unavailable in this desktop session.",
    "Could not register Escape for scrolling capture.",
    "Scrolling capture requires Windows 10 version 2004 or later.",
    "Scrolling capture requires desktop composition to exclude its controls.",
    "Could not exclude Lumen controls from scrolling capture.",
    "Could not create scrolling capture controls.",
    "Could not start the scrolling capture stream.",
  ]) if (message.includes(known)) return known;
  return "Could not start scrolling capture. Try again.";
}

type Phase =
  | "mode-select"
  | "selecting"
  | "annotating"
  | "ocr-preparing"
  | "ocr-consent"
  | "ocr-recognizing"
  | "ocr-result"
  | "qr-result"
  | "record-options";

type Mode = "screenshot" | "record" | "ocr";

const ACCENT = "#050505";
const MODE_SELECTOR_DRAG_THRESHOLD = 4;
const FLOATING_CONTROL_MARGIN = 8;
const DEFAULT_HINT_TOP = 102;
// Slightly larger than the 10px visual handle radius so the cursor changes
// just before the pointer reaches the dot.
const HANDLE_HIT_RADIUS = 12;
const CAPTURE_MODE_WRITE_DELAY_MS = 300;
// A confirmed capture closes its own overlay. WebView2 can accept that close
// and still keep the window alive, so each close step has a budget and the
// backend gets the remaining chance; its worker-thread fallback always ends the
// close. Without these bounds a pin click left a disabled editing HUD forever.
const OVERLAY_SELF_CLOSE_TIMEOUT_MS = 600;
const OVERLAY_BACKEND_CLOSE_TIMEOUT_MS = 2000;
// A confirmation that never settles must not trap the user in the editing HUD.
// The pixels are already exported by then, so the overlay closes itself and
// the backend finishes (or reports) the capture.
const EXPORT_RESULT_TIMEOUT_MS = 5000;
const CONFIRM_CAPTURE_TIMEOUT_MS = 8000;
// The single pending-confirmation slot keeps the previous capture busy for a
// moment after its overlays start closing. Retrying briefly is safe: that
// error is returned before this capture's session is consumed. The window is
// wider than the backend's own 900 ms stall timeout, so a fresh 📌 click waits
// for that slot to clear instead of restoring an editing HUD that is about to
// close. A WebView2 close that is still unwinding on a slow machine can take
// a few seconds, so the retry window covers more than the common case.
const CONFIRM_BUSY_RETRY_DELAY_MS = 260;
const CONFIRM_BUSY_MAX_ATTEMPTS = 20;
const CONFIRM_BUSY_MESSAGE = "The previous capture is still completing.";
// A pin handoff exports the capture before it confirms it. Every step is
// bounded above, so this only fires when a step never settles at all. It is the
// last resort that keeps a transparent full-screen window from holding the
// desktop: the HUD is already gone from the click on, so a stuck handoff would
// otherwise leave an invisible window that swallows input until the app exits.
const PIN_HANDOFF_TIMEOUT_MS = 15000;
// Backend errors that mean this overlay's capture session is gone. Retrying or
// restoring the editor after one of these would be a dead end, so the overlay
// closes instead.
const LOST_CAPTURE_SESSION_ERRORS = [
  "This command is only available from the active capture overlay.",
  "Capture confirmation is only available to its overlay.",
  "No active capture session.",
  "The capture annotation snapshot changed before confirmation.",
  "The capture session changed before confirmation.",
];

/** Resolves `undefined` when `work` has not settled within `ms`. */
function settleWithin<T>(work: Promise<T>, ms: number): Promise<T | undefined> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<undefined>(resolve => {
    timer = setTimeout(() => resolve(undefined), ms);
  });
  return Promise.race([work, timeout]).finally(() => {
    if (timer) clearTimeout(timer);
  });
}

/** True when a confirmation error means this overlay's capture session is gone. */
function lostCaptureSession(message: string): boolean {
  return LOST_CAPTURE_SESSION_ERRORS.some(text => message.includes(text));
}

/**
 * Resolves once the renderer has painted the pending React update.
 *
 * The pin handoff replaces the whole editor tree with a transparent page, and
 * the export that follows renders the full-resolution canvas synchronously.
 * Without yielding a frame first, that work owns the main thread before the
 * paint, so the toolbar stayed fully visible for the whole export and the 📌
 * click looked ignored. A hidden or throttled WebView can withhold animation
 * frames, so a short timer settles the wait as well.
 */
function afterPaint(): Promise<void> {
  return new Promise((resolve) => {
    let settled = false;
    const settle = () => {
      if (settled) return;
      settled = true;
      resolve();
    };
    if (typeof requestAnimationFrame === "function") {
      requestAnimationFrame(() => requestAnimationFrame(settle));
    }
    setTimeout(settle, 80);
  });
}

type ModeSelectorDrag = {
  pointerId: number;
  captureTarget: Element;
  start: Point;
  origin: Point;
  size: { width: number; height: number };
  moved: boolean;
};

function clampFloatingControl(position: Point, size: { width: number; height: number }, bounds: Rect): Point {
  const minLeft = minX(bounds) + FLOATING_CONTROL_MARGIN;
  const minTop = minY(bounds) + FLOATING_CONTROL_MARGIN;
  const maxLeft = Math.max(minLeft, maxX(bounds) - size.width - FLOATING_CONTROL_MARGIN);
  const maxTop = Math.max(minTop, maxY(bounds) - size.height - FLOATING_CONTROL_MARGIN);
  return {
    x: Math.min(Math.max(position.x, minLeft), maxLeft),
    y: Math.min(Math.max(position.y, minTop), maxTop),
  };
}

// --- window hover candidate (WindowSelectionGeometry.candidate port) ---
function reportFrontend(message: string) {
  void invoke("log_frontend_error", { message }).catch(() => {});
}

function windowCandidate(
  p: Point,
  windowsFrontToBack: Rect[],
  bounds: Rect,
): Rect | null {
  const minimum = 8;
  for (const window of windowsFrontToBack) {
    const visible = intersection(standardized(window), bounds);
    if (
      visible.width >= minimum &&
      visible.height >= minimum &&
      contains(visible, p)
    ) {
      return visible;
    }
  }
  return null;
}

/**
 * Floating overlay chrome that owns its own pointer gestures.
 *
 * The toolbar, tool options, mode selector, size fields, record options and
 * error banner are drawn above the frozen screen but inside the overlay root.
 * Without this guard their pointer-down also starts a region drag; the
 * pointer-up that follows can then replace the selection with the window
 * behind the button and move the toolbar before the click is delivered, which
 * is the intermittent "clicked 📌, still editing" report.
 */
const OVERLAY_CHROME_SELECTOR =
  ".kiri-hud, .kiri-capture-dimension, .kiri-record-options, .kiri-annotation-error";

export function pointerStartsInOverlayChrome(target: EventTarget | null): boolean {
  const closest = (target as { closest?: (selector: string) => unknown } | null)?.closest;
  return typeof closest === "function" && !!closest.call(target, OVERLAY_CHROME_SELECTOR);
}


export function OverlayWindow() {
  const [context, setContext] = useState<CaptureContextDto | null>(null);
  const [frozenSrc, setFrozenSrc] = useState<string>("");
  const [phase, setPhase] = useState<Phase>("mode-select");
  const [mode, setMode] = useState<Mode>("screenshot");
  const [selection, setSelection] = useState<Rect | null>(null);
  const [sizeControlsOpen, setSizeControlsOpen] = useState(false);
  const [hoverWindow, setHoverWindow] = useState<Rect | null>(null);
  const [drag, setDrag] = useState<{ start: Point; current: Point; moved: boolean } | null>(null);
  const [resizeHandle, setResizeHandle] = useState<string | null>(null);
  const [moveDrag, setMoveDrag] = useState<{ start: Point; original: Rect } | null>(null);
  const [tool, setTool] = useState<Tool>("select");
  const [selectedMark, setSelectedMark] = useState<AnnotationMark | null>(null);
  const [selectedMarkEditing, setSelectedMarkEditing] = useState(false);
  const [annotationError, setAnnotationError] = useState<string | null>(null);
  const [calloutNumber, setCalloutNumber] = useState(1);
  const [hasAnnotations, setHasAnnotations] = useState(false);
  const hasAnnotationContentRef = useRef(false);
  const onAnnotationSelection = useCallback((mark: AnnotationMark | null, editing: boolean) => {
    setSelectedMark(mark);
    setSelectedMarkEditing(editing);
  }, []);
  const onAnnotationDocument = useCallback((marks: AnnotationMark[]) => {
    setCalloutNumber(nextCalloutNumber(marks));
  }, []);
  const [appearance, setAppearance] = useAnnotationAppearance();
  const [canUndo, setCanUndo] = useState(false);
  const [canRedo, setCanRedo] = useState(false);
  const [qrScan, setQrScan] = useState<QrScanDto | null>(null);
  const [qrFailed, setQrFailed] = useState(false);
  const qrRequestRef = useRef<string | null>(null);
  const qrReturnPhaseRef = useRef<"selecting" | "annotating">("selecting");
  const [ocrText, setOcrText] = useState("");
  const [ocrFailed, setOcrFailed] = useState(false);
  const [preparedOcr, setPreparedOcr] = useState<PreparedOcrRequestDto | null>(null);
  const [remoteOcrFailed, setRemoteOcrFailed] = useState(false);
  const [recordSelectionRevision, setRecordSelectionRevision] = useState(0);
  const [recordOptions, setRecordOptions] = useState<RecordingOptions>(DEFAULT_RECORDING_OPTIONS);
  const [micSupported, setMicSupported] = useState(true);
  const [platformCaps, setPlatformCaps] = useState<PlatformCapabilitiesDto>({
    scrollingCapture: false,
    recording: true,
    localOcr: true,
    systemAudio: true,
    microphone: true,
    clickHighlights: true,
    videoEditing: true,
    videoSpeedEditing: false,
    videoEffectsEditing: false,
    videoAnnotationsEditing: false,
    videoExportPresets: false,
    manualUpdates: false,
  });
  const [modeSelectorPosition, setModeSelectorPosition] = useState<Point | null>(null);
  const [modeSelectorDragging, setModeSelectorDragging] = useState(false);
  const [modeSelectorBounds, setModeSelectorBounds] = useState<Rect | null>(null);
  const canvasRef = useRef<AnnotationCanvasHandle>(null);
  const selectionPointerStartRef = useRef<Point | null>(null);
  const selectionClickMovedRef = useRef(false);
  const doubleClickCanFinishRef = useRef(false);
  const imageRef = useRef<HTMLImageElement>(null);
  const modeSelectorRef = useRef<HTMLDivElement>(null);
  const modeSelectorDragRef = useRef<ModeSelectorDrag | null>(null);
  const suppressModeSelectorClickRef = useRef(false);
  const completionLock = useMemo(() => new AnnotationInteractionLock(), []);
  const [completing, setCompleting] = useState(false);
  // A confirmed capture has already been saved and (optionally) pinned. The
  // editing HUD must disappear at that moment: WebView2 can accept the native
  // close and keep painting the last frame, which read as an ignored 📌 click.
  const [confirmed, setConfirmed] = useState(false);
  const confirmedRef = useRef(false);
  // A Pin click hands this screenshot over to a floating reference. The editing
  // HUD leaves the screen as soon as the click lands, before the pixels are
  // exported: the export, a busy previous completion, and the confirmation can
  // each take a moment, and a toolbar that is still fully painted during that
  // window is indistinguishable from an ignored 📌 click ("clicked pin, still
  // editing"). A failure that leaves this capture's session alive releases the
  // handoff again, so the editor returns with an error and a retry works.
  const [pinning, setPinning] = useState(false);
  // A handoff that never settles must not leave this transparent full-screen
  // window alive: after the HUD is gone nothing else is clickable.
  useEffect(() => {
    if (!pinning) return;
    const timer = setTimeout(() => {
      if (confirmedRef.current) return;
      reportFrontend("pin handoff did not settle; closing the overlay");
      confirmedRef.current = true;
      setConfirmed(true);
      void api.closeCaptureOverlay().catch(() => { void getCurrentWindow().close().catch(() => {}); });
    }, PIN_HANDOFF_TIMEOUT_MS);
    return () => clearTimeout(timer);
  }, [pinning]);
  // Set once the annotation pixels are exported and the confirmation is being
  // sent. From then on the frozen screenshot is stale: the toolbar and the
  // selection chrome are hidden before the IPC reply, so a slow or failed
  // confirmation can never leave an editable-looking HUD behind.
  const [committing, setCommitting] = useState(false);
  const [hoverHandle, setHoverHandle] = useState<string | null>(null);
  const [hoverInsideSelection, setHoverInsideSelection] = useState(false);
  const wheelStateRef = useRef(idleWheelState());
  const modeWriteTimerRef = useRef<number | null>(null);
  const modeResolvedRef = useRef(false);
  const modeRef = useRef<Mode>("screenshot");
  const preparedOcrRef = useRef<PreparedOcrRequestDto | null>(null);
  const ocrGenerationRef = useRef(0);
  modeRef.current = mode;

  // Load context on mount.
  useEffect(() => {
    let disposed = false;
    let failed = false;
    let frozenBlobUrl: string | null = null;
    const abortOverlay = (message: string) => {
      if (disposed || failed) return;
      failed = true;
      reportFrontend(message);
      void api.cancelCapture().catch(() => getCurrentWindow().close());
    };
    const captureToken = new URLSearchParams(window.location.search).get("captureToken");
    if (!captureToken || !/^[a-f0-9]{32}$/.test(captureToken)) {
      abortOverlay("overlay capture token is missing or invalid");
      return () => {
        disposed = true;
      };
    }
    const frozenCaptureUrl = kiriResourceUrl("capture", ["frozen", `${captureToken}.png`]);
    (window as unknown as { __kiriOverlay: boolean }).__kiriOverlay = true;
    api.startCapture()
      .then((ctx) => {
        if (disposed) return;
        const initialMode = ctx.initialMode ?? "screenshot";
        modeRef.current = initialMode;
        modeResolvedRef.current = true;
        setMode(initialMode);
        setContext(ctx);
      })
      .catch((error) => {
        void invoke("log_frontend_error", {
          message: `overlay startCapture rejected: ${String(error)}`,
        }).catch(() => {});
        // Permission or capture failure: close the overlay so the library
        // window's error banner (emitted by the backend) is visible.
        void getCurrentWindow().close();
      });
    api.getRecordingOptions().then((options) => setRecordOptions(options)).catch(() => {});
    api.micSupported().then((supported) => setMicSupported(supported)).catch(() => {});
    api.platformCapabilities().then((caps) => {
      setPlatformCaps(caps);
      setMicSupported(caps.microphone);
    }).catch(() => {});
    // Load the frozen capture through a blob URL: canvas operations on the
    // custom-scheme image would taint the canvas and break PNG export.
    fetch(frozenCaptureUrl)
      .then((response) => {
        if (!response.ok) throw new Error("frozen capture unavailable");
        return response.blob();
      })
      .then((blob) => {
        if (disposed) return;
        const img = new Image();
        img.onerror = () => abortOverlay("overlay could not decode the frozen capture");
        frozenBlobUrl = URL.createObjectURL(blob);
        img.src = frozenBlobUrl;
        setFrozenSrc(img.src);
      })
      .catch((error) =>
        abortOverlay(`overlay could not load the frozen capture: ${String(error)}`),
      );
    return () => {
      disposed = true;
      if (frozenBlobUrl) URL.revokeObjectURL(frozenBlobUrl);
    };
  }, []);

  const bounds: Rect = context
    ? { x: 0, y: 0, width: context.displayWidth, height: context.displayHeight }
    : { x: 0, y: 0, width: window.innerWidth, height: window.innerHeight };

  const selectedAnnotationBounds = useMemo(() => {
    if (!selectedMark || !selection) return [];
    // Canvas marks use selection-local logical points, including live text
    // editors. Protect an empty callout editor as well as its separate badge.
    const rects = selectedMark.kind === "callout"
      ? [{x: selectedMark.center.x - selectedMark.size / 2, y: selectedMark.center.y - selectedMark.size / 2,
          width: selectedMark.size, height: selectedMark.size},
        ...(selectedMarkEditing || selectedMark.text.trim() ? [selectedMark.labelRect] : [])]
      : [selectionBounds(selectedMark)];
    return rects.map(rect => ({...rect, x: rect.x + selection.x, y: rect.y + selection.y}));
  }, [selectedMark, selectedMarkEditing, selection]);

  const colorPicker = useCaptureColorPicker(
    !!context && mode === "screenshot" && (phase === "mode-select" || phase === "selecting") &&
      !completing && !drag && !resizeHandle && !moveDrag && !modeSelectorDragging,
    imageRef, bounds, api.copyCaptureColor,
  );

  useLayoutEffect(() => {
    const selector = modeSelectorRef.current;
    if (!selector) { setModeSelectorBounds(null); return; }
    const measure = () => {
      const rect = selector.getBoundingClientRect();
      setModeSelectorBounds(previous => previous && previous.x === rect.left && previous.y === rect.top &&
        previous.width === rect.width && previous.height === rect.height ? previous :
        { x: rect.left, y: rect.top, width: rect.width, height: rect.height });
    };
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(selector);
    return () => observer.disconnect();
  }, [modeSelectorPosition, bounds.width, bounds.height, phase]);

  const modeSelectorPointerDown = (event: React.PointerEvent<HTMLDivElement>) => {
    if (
      completionLock.locked ||
      event.button !== 0 ||
      !event.isPrimary ||
      modeSelectorDragRef.current
    ) {
      return;
    }
    event.stopPropagation();
    const selector = modeSelectorRef.current;
    if (!selector) return;
    const rect = selector.getBoundingClientRect();
    const captureTarget = event.target instanceof Element ? event.target : event.currentTarget;
    suppressModeSelectorClickRef.current = false;
    modeSelectorDragRef.current = {
      pointerId: event.pointerId,
      captureTarget,
      start: { x: event.clientX, y: event.clientY },
      origin: { x: rect.left, y: rect.top },
      size: { width: rect.width, height: rect.height },
      moved: false,
    };
    captureTarget.setPointerCapture(event.pointerId);
  };

  const modeSelectorPointerMove = (event: React.PointerEvent<HTMLDivElement>) => {
    event.stopPropagation();
    const gesture = modeSelectorDragRef.current;
    if (!gesture || gesture.pointerId !== event.pointerId) return;
    if (completionLock.locked) return;
    const dx = event.clientX - gesture.start.x;
    const dy = event.clientY - gesture.start.y;
    if (!gesture.moved && Math.hypot(dx, dy) < MODE_SELECTOR_DRAG_THRESHOLD) return;
    event.preventDefault();
    if (!gesture.moved) {
      gesture.moved = true;
      setModeSelectorDragging(true);
    }
    setModeSelectorPosition(
      clampFloatingControl(
        { x: gesture.origin.x + dx, y: gesture.origin.y + dy },
        gesture.size,
        bounds,
      ),
    );
  };

  const finishModeSelectorDrag = (event: React.PointerEvent<HTMLDivElement>) => {
    event.stopPropagation();
    const gesture = modeSelectorDragRef.current;
    if (!gesture || gesture.pointerId !== event.pointerId) return;
    if (gesture.captureTarget.hasPointerCapture(event.pointerId)) {
      gesture.captureTarget.releasePointerCapture(event.pointerId);
    }
    modeSelectorDragRef.current = null;
    setModeSelectorDragging(false);
    if (gesture.moved) {
      suppressModeSelectorClickRef.current = true;
      window.setTimeout(() => {
        suppressModeSelectorClickRef.current = false;
      }, 0);
    }
  };

  const cancelModeSelectorDrag = (event: React.PointerEvent<HTMLDivElement>) => {
    event.stopPropagation();
    const gesture = modeSelectorDragRef.current;
    if (!gesture || gesture.pointerId !== event.pointerId) return;
    modeSelectorDragRef.current = null;
    setModeSelectorDragging(false);
  };

  useEffect(() => {
    setModeSelectorPosition((current) => {
      const selector = modeSelectorRef.current;
      if (!current || !selector) return current;
      const next = clampFloatingControl(
        current,
        { width: selector.offsetWidth, height: selector.offsetHeight },
        bounds,
      );
      return next.x === current.x && next.y === current.y ? current : next;
    });
  }, [bounds.x, bounds.y, bounds.width, bounds.height]);

  const discardPreparedOcr = useCallback(() => {
    ocrGenerationRef.current += 1;
    const pending = preparedOcrRef.current;
    preparedOcrRef.current = null;
    setPreparedOcr(null);
    setRemoteOcrFailed(false);
    if (pending) void api.cancelPreparedOcr(pending.requestId).catch(() => {});
  }, []);

  const discardQr = useCallback(() => {
    const id = qrRequestRef.current;
    qrRequestRef.current = null;
    setQrScan(null); setQrFailed(false);
    if (id) void api.cancelQr(id).catch(() => {});
  }, []);
  const runQr = useCallback(async (selection: Rect) => {
    discardQr();
    canvasRef.current?.commitTextEditing();
    qrReturnPhaseRef.current = phaseRef.current === "annotating" ? "annotating" : "selecting";
    const id = crypto.randomUUID();
    qrRequestRef.current = id;
    setPhase("qr-result");
    try {
      const result = await api.scanQr(id, selection, null);
      if (qrRequestRef.current === id) setQrScan(result);
    } catch {
      if (qrRequestRef.current === id) setQrFailed(true);
    }
  }, [discardQr]);
  const closeQr = useCallback(() => {
    discardQr();
    setPhase(qrReturnPhaseRef.current);
  }, [discardQr]);
  useEffect(() => () => { const id = qrRequestRef.current; qrRequestRef.current = null; if (id) void api.cancelQr(id).catch(() => {}); }, []);

  const cancel = useCallback(() => {
    discardPreparedOcr();
    discardQr();
    void api.cancelCapture().catch(() => {});
  }, [discardPreparedOcr, discardQr]);

  // The X on the recognized-text panel dismisses that result, not the capture.
  // The region and the current mode stay, so the toolbar (screenshot/record)
  // or a fresh drag can follow without losing the session.
  const dismissOcrResult = useCallback(() => {
    discardPreparedOcr();
    setOcrText("");
    setOcrFailed(false);
    setPhase("selecting");
    phaseRef.current = "selecting";
  }, [discardPreparedOcr]);

  // A confirmed capture leaves this overlay to close itself. The WebView close
  // needs `core:window:allow-close` for its label, and every display owns a
  // different label (`overlay`, `overlay-2`, ...). Leaving that path without a
  // fallback stranded the editing HUD on a secondary display after the image
  // had already been saved and pinned, so a refused close is retried through
  // the backend, which closes the same window from a worker thread.
  const closeConfirmedOverlay = useCallback(async () => {
    const selfClosed = await settleWithin(
      getCurrentWindow().close().then(() => true).catch(error => {
        reportFrontend(`overlay close rejected: ${String(error)}`);
        return false;
      }),
      OVERLAY_SELF_CLOSE_TIMEOUT_MS,
    );
    if (selfClosed) return true;
    if (selfClosed === undefined) {
      reportFrontend("overlay close did not settle; closing from the backend");
    }
    const closedByBackend = await settleWithin(
      api.closeCaptureOverlay().then(() => true).catch(next => {
        reportFrontend(`close_capture_overlay rejected: ${String(next)}`);
        return false;
      }),
      OVERLAY_BACKEND_CLOSE_TIMEOUT_MS,
    );
    // An unanswered backend close is still recovered by the confirmation
    // fallback that runs on its worker thread.
    return closedByBackend !== false;
  }, []);

  const complete = useCallback(
    async (pinOnTop = false) => {
      if (!completionLock.acquire()) {
        // A completion that never settled must not make the editor look
        // interactive while every click is ignored.
        reportFrontend("complete: a previous completion is still in flight");
        return;
      }
      // True once the pixels are exported and the confirmation is in flight.
      // From that point the editor must not come back: the backend consumes
      // the capture session before it can fail, so a restored toolbar would be
      // unable to confirm anything (the reported "clicked 📌, still editing").
      let handedOff = false;
      try {
        // The 📌 button promises a floating reference, not a finished edit.
        // Take the editing HUD off screen before the (possibly slow) export
        // starts so the click is always visibly answered; `handedOff` decides
        // below whether the editor may return.
        if (pinOnTop) {
          setAnnotationError(null);
          setPinning(true);
          // An open text editor makes the export return null, which would put
          // the editing HUD straight back after a 📌 click. Commit it; a
          // composition the commit refuses to touch is dropped, because the
          // click has already decided to leave the editor.
          const canvas = canvasRef.current;
          if (canvas && !canvas.commitTextEditing()) canvas.cancelTextEditing();
          // The export renders the full-resolution canvas synchronously. Hand
          // the renderer one frame first so the HUD removal is actually
          // painted; otherwise the toolbar stays visible for the whole export
          // and the click reads as ignored. This window also stops swallowing
          // clicks the user aims at the pin or the desktop underneath it while
          // the pixels are being exported.
          await afterPaint();
          await getCurrentWindow().setIgnoreCursorEvents(true).catch(() => {});
        }
        // Everything after the lock is inside `try` on purpose. Releasing a
        // stale mode-selector pointer capture can throw when the pointer was
        // cancelled between the check and the release; that must not escape
        // with the completion lock still held, which would silently ignore
        // every later 📌/Done click while the editing HUD stayed on screen.
        const modeSelectorGesture = modeSelectorDragRef.current;
        if (modeSelectorGesture) {
          try {
            if (modeSelectorGesture.captureTarget.hasPointerCapture(modeSelectorGesture.pointerId)) {
              modeSelectorGesture.captureTarget.releasePointerCapture(modeSelectorGesture.pointerId);
            }
          } catch {
            // The pointer is already gone; dropping the reference below is all
            // that is needed.
          }
          modeSelectorDragRef.current = null;
          setModeSelectorDragging(false);
        }
        setCompleting(true);
        const canvas = canvasRef.current;
        if (!canvas) {
          reportFrontend("complete: annotation canvas not mounted");
          setAnnotationError("Could not finish this screenshot.");
          return;
        }
        if (!selection) {
          reportFrontend("complete: annotation selection not available");
          setAnnotationError("Could not finish this screenshot.");
          return;
        }
        const exportOnce = () => settleWithin(canvas.exportResult(), EXPORT_RESULT_TIMEOUT_MS);
        let exported = await exportOnce();
        if (exported === undefined) {
          reportFrontend("complete: exportResult did not settle");
        }
        if (!exported) {
          // A null export is transient (an image still decoding, an editor
          // settling). One retry keeps a 📌 click from putting the editing HUD
          // back on screen when the user asked for a floating reference.
          reportFrontend("complete: exportResult returned no data; retrying");
          exported = await exportOnce();
        }
        if (!exported) {
          reportFrontend("complete: exportResult returned no data twice");
          setAnnotationError("Could not finish this screenshot.");
          return;
        }
        const payload = exported;
        handedOff = true;
        setCommitting(true);
        let failure = "";
        for (let attempt = 0; attempt < CONFIRM_BUSY_MAX_ATTEMPTS; attempt++) {
          if (attempt > 0) {
            await new Promise(resolve => setTimeout(resolve, CONFIRM_BUSY_RETRY_DELAY_MS));
          }
          const outcome = await settleWithin(
            api.confirmCapture(payload.png, { selection, document: payload.document }, pinOnTop)
              .then(() => ({ failed: false, message: "" }))
              .catch((error: unknown) => {
                const message = String(error);
                reportFrontend(`confirm_capture rejected: ${message}`);
                return { failed: true, message };
              }),
            CONFIRM_CAPTURE_TIMEOUT_MS,
          );
          if (outcome === undefined) {
            // Don't retry an unanswered request: it may already be committing
            // the capture. Closing the overlay is always safe here because the
            // backend owns the completion from now on.
            reportFrontend("confirm_capture did not settle; closing the overlay");
            failure = "";
            break;
          }
          if (!outcome.failed) {
            failure = "";
            break;
          }
          failure = outcome.message;
          if (!failure.includes(CONFIRM_BUSY_MESSAGE)) break;
          reportFrontend("confirm_capture: previous capture still completing; retrying");
        }
        if (failure && !lostCaptureSession(failure)) {
          // The session is still alive (the backend rejected before consuming
          // it), so give the editor back and let the user retry.
          handedOff = false;
          setCommitting(false);
          setAnnotationError("Could not finish this screenshot.");
          return;
        }
        // The capture is saved (or its session is gone) and the pin is queued.
        // The backend already hid this overlay; hiding the React tree as well
        // keeps a webview that has not painted the hide from showing the HUD.
        confirmedRef.current = true;
        setConfirmed(true);
        // The backend confirmation is synchronous. Close this owner WebView
        // only after its IPC response has arrived; dispatching a backend
        // close while WebView2 is still waiting can deadlock the Windows UI
        // thread and strand both the resident process and the next launch.
        if (!(await closeConfirmedOverlay())) {
          // The capture is already saved and copied. The backend destroys the
          // hidden overlay, so this is diagnostic rather than user-facing.
          reportFrontend("confirmed overlay did not acknowledge its close; backend will retry");
        }
      } catch (error) {
        reportFrontend(`confirm_capture rejected: ${String(error)}`);
        if (handedOff) {
          confirmedRef.current = true;
          setConfirmed(true);
          await closeConfirmedOverlay();
        } else {
          setAnnotationError("Could not finish this screenshot.");
        }
      } finally {
        if (!handedOff) {
          setCommitting(false);
          // The capture is still confirmable: give the editor back so the user
          // can retry or switch to Done instead of staring at a blank overlay.
          setPinning(false);
          // The handoff stopped ignoring cursor events; the restored editor
          // must receive clicks again.
          if (pinOnTop) void getCurrentWindow().setIgnoreCursorEvents(false).catch(() => {});
        }
        completionLock.release();
        setCompleting(false);
      }
    },
    [closeConfirmedOverlay, completionLock, selection],
  );

  const startScrollCapture = useCallback(async () => {
    if (!selection || !context?.captureId || !platformCaps.scrollingCapture ||
        hasAnnotationContentRef.current || selectedMarkEditing || !completionLock.acquire()) return;
    setCompleting(true);
    setAnnotationError(null);
    try {
      await api.startScrollCapture(context.captureId, selection);
    } catch (error) {
      reportFrontend(`start_scroll_capture rejected: ${String(error)}`);
      setAnnotationError(scrollingStartError(error));
    } finally {
      completionLock.release();
      setCompleting(false);
    }
  }, [completionLock, context?.captureId, platformCaps.scrollingCapture, selectedMarkEditing, selection]);

  const recognizePreparedLocal = useCallback(async () => {
    const pending = preparedOcrRef.current;
    if (!pending) return;
    const generation = ocrGenerationRef.current;
    setRemoteOcrFailed(false);
    setPhase("ocr-recognizing");
    try {
      const text = await api.recognizePreparedOcrLocal(pending.requestId);
      if (generation !== ocrGenerationRef.current) return;
      preparedOcrRef.current = null;
      setPreparedOcr(null);
      setOcrFailed(false);
      setOcrText(text.text);
      setPhase("ocr-result");
    } catch (error) {
      if (generation !== ocrGenerationRef.current) return;
      reportFrontend(`recognize_prepared_ocr_local rejected: ${String(error)}`);
      preparedOcrRef.current = null;
      setPreparedOcr(null);
      void api.cancelPreparedOcr(pending.requestId).catch(() => {});
      setOcrFailed(true);
      setOcrText("");
      setPhase("ocr-result");
    }
  }, []);

  const recognizePreparedRemote = useCallback(async () => {
    const pending = preparedOcrRef.current;
    const profile = pending?.profile;
    if (!pending || !profile || pending.engine.kind !== "profile") return;
    const generation = ocrGenerationRef.current;
    setRemoteOcrFailed(false);
    setPhase("ocr-recognizing");
    try {
      const text = await api.recognizePreparedOcrRemote(
        pending.requestId,
        profile.id,
        profile.revision,
      );
      if (generation !== ocrGenerationRef.current) return;
      preparedOcrRef.current = null;
      setPreparedOcr(null);
      setOcrFailed(false);
      setOcrText(text.text);
      setPhase("ocr-result");
    } catch {
      if (generation !== ocrGenerationRef.current) return;
      // Keep the same prepared image available for an explicit Retry or the
      // local-only action. A failed remote request is never retried silently.
      setRemoteOcrFailed(true);
      setPhase("ocr-consent");
    }
  }, []);

  const runOcr = useCallback(
    async (sel: Rect) => {
      const generation = ocrGenerationRef.current + 1;
      ocrGenerationRef.current = generation;
      const previous = preparedOcrRef.current;
      preparedOcrRef.current = null;
      setPreparedOcr(null);
      setRemoteOcrFailed(false);
      setOcrFailed(false);
      setOcrText("");
      setPhase("ocr-preparing");
      if (previous) void api.cancelPreparedOcr(previous.requestId).catch(() => {});

      try {
        const prepared = await api.prepareOcrRequest({
          x: sel.x,
          y: sel.y,
          width: sel.width,
          height: sel.height,
        });
        if (generation !== ocrGenerationRef.current) {
          void api.cancelPreparedOcr(prepared.requestId).catch(() => {});
          return;
        }

        preparedOcrRef.current = prepared;
        setPreparedOcr(prepared);
        if (prepared.engine.kind === "local") {
          void recognizePreparedLocal();
          return;
        }

        const profile = prepared.profile;
        if (
          !profile ||
          !profile.hasApiKey ||
          profile.id !== prepared.engine.profileId
        ) {
          preparedOcrRef.current = null;
          setPreparedOcr(null);
          void api.cancelPreparedOcr(prepared.requestId).catch(() => {});
          setOcrFailed(true);
          setPhase("ocr-result");
          return;
        }
        setPhase("ocr-consent");
      } catch (error) {
        if (generation !== ocrGenerationRef.current) return;
        reportFrontend(`prepare_ocr_request rejected: ${String(error)}`);
        setOcrFailed(true);
        setOcrText("");
        setPhase("ocr-result");
      }
    },
    [recognizePreparedLocal],
  );

  useEffect(
    () => () => {
      ocrGenerationRef.current += 1;
      const pending = preparedOcrRef.current;
      preparedOcrRef.current = null;
      if (pending) void api.cancelPreparedOcr(pending.requestId).catch(() => {});
    },
    [],
  );

  // Fields and active HUD gestures own Escape before the capture does.
  useEffect(() => {
    const onEscape = (e: KeyboardEvent) => {
      if (e.key !== "Escape") return;
      if (isTextComposition(e)) return;
      if (document.querySelector('.kiri-record-options__microphone[aria-expanded="true"]')) return;
      if (document.querySelector('.kiri-capture-toolbar button[data-dragging="true"]')) return;
      if (e.target instanceof Element && e.target.closest(".kiri-capture-dimension-input")) return;
      if (e.target instanceof Element && e.target.closest(".kiri-callout-description textarea")) return;
      if (e.target instanceof Element && e.target.closest(
        ".kiri-capture-tool-options input, .kiri-capture-tool-options textarea, .kiri-capture-tool-options select, .kiri-capture-options-move, .kiri-capture-toolbar-move",
      )) return;
      e.preventDefault();
      e.stopImmediatePropagation();
      // A confirmed capture can still be on screen while its native close is
      // pending. Escape then forces that close instead of being swallowed by
      // the completion lock.
      if (confirmedRef.current) {
        void getCurrentWindow().close().catch(() => {});
        void api.closeCaptureOverlay().catch(() => {});
        return;
      }
      if (completionLock.locked) return;
      if (phaseRef.current === "qr-result") { closeQr(); return; }
      if (phaseRef.current === "annotating" && canvasRef.current?.cancelTextEditing()) return;
      cancel();
    };
    window.addEventListener("keydown", onEscape, true);
    return () => window.removeEventListener("keydown", onEscape, true);
  }, [cancel, closeQr, completionLock]);

  // --- keyboard ---
  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      if (isTextComposition(e)) return;
      if (completionLock.locked) {
        e.preventDefault();
        e.stopPropagation();
        return;
      }
      // QR content is selectable, and its buttons keep their native keyboard
      // behavior. Annotation shortcuts must not intercept this reading phase.
      if (phaseRef.current === "qr-result" || phaseRef.current === "ocr-result") return;
      if (e.defaultPrevented) return;
      if (e.target instanceof Element && e.target.closest("input, textarea, select, [contenteditable]")) return;
      if (colorPicker.onCopyKeyDown(e)) return;
      const mod = e.metaKey || e.ctrlKey;
      if (!mod && !e.altKey && (e.key === "Delete" || e.key === "Backspace")) {
        if (phaseRef.current === "annotating") {
          e.preventDefault();
          canvasRef.current?.deleteSelection();
        }
        return;
      }
      if (mod && e.key.toLowerCase() === "z") {
        e.preventDefault();
        if (e.shiftKey) canvasRef.current?.redo();
        else canvasRef.current?.undo();
        return;
      }
      if (mod && e.key.toLowerCase() === "c") {
        e.preventDefault();
        if (phaseRef.current === "annotating") void complete();
        return;
      }
      if (e.key === "Enter" || e.key === "Return") {
        const ph = phaseRef.current;
        if (ph === "ocr-consent") {
          // Privacy default: Return never sends an image to a remote provider.
          // It recognizes this one prepared image locally instead.
          e.preventDefault();
          void recognizePreparedLocal();
          return;
        }
        // Outside consent, focused controls retain their native activation.
        // Consent always keeps Return as an explicit local recognition action.
        if (e.target instanceof Element && e.target.closest("button, a, select, input")) return;
        if (ph === "annotating") {
          void complete();
          return;
        }
        if (ph === "record-options" && selectionRef.current) {
          // Spec (recording §2.2): Start Recording is bound to Return.
          setAnnotationError(null);
          void api.startRecordingFlow(selectionRef.current, recordOptionsRef.current).catch(error => setAnnotationError(recordingStartError(error)));
          return;
        }
        if (ph === "selecting" && selectionRef.current && isValidSelection(selectionRef.current, 3)) {
          // Spec §5.2: Return with a valid selection confirms per mode.
          if (modeRef.current === "screenshot") {
            void complete();
          } else if (modeRef.current === "record") {
            setPhase("record-options");
          } else if (modeRef.current === "ocr") {
            void runOcr(selectionRef.current);
          }
          return;
        }
      }
      if (!mod && !e.altKey) {
        const key = e.key.toLowerCase();
        const map: Record<string, Tool> = {
          v: "select",
          p: "pen",
          r: "rectangle",
          l: "line",
          a: "arrow",
          t: "text",
          b: "label",
          n: "callout",
          m: "mosaic",
          w: "watermark",
        };
        if (key in map && phaseRef.current !== "mode-select") {
          const next = map[key];
          // Spec §6.6: switching tools commits any in-flight text edit.
          canvasRef.current?.commitTextEditing();
          canvasRef.current?.finishAppearanceAdjustment();
          if (next !== "select") canvasRef.current?.clearSelection();
          if (phaseRef.current === "selecting" && selectionRef.current) {
            // Selecting a tool locks the region into annotation mode.
            setPhase("annotating");
            setTool(next);
          } else {
            setTool(next);
          }
          if (next === "watermark") canvasRef.current?.editWatermark();
        }
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [complete, completionLock, recognizePreparedLocal, runOcr, colorPicker.onCopyKeyDown]);

  const phaseRef = useRef<Phase>("mode-select");
  phaseRef.current = phase;
  const selectionRef = useRef<Rect | null>(null);
  selectionRef.current = selection;
  const hoverWindowRef = useRef<Rect | null>(null);
  const recordOptionsRef = useRef<RecordingOptions>(recordOptions);
  recordOptionsRef.current = recordOptions;

  // --- pointer interactions ---
  const toPoint = useCallback(
    (e: React.PointerEvent): Point => ({ x: e.clientX, y: e.clientY }),
    [],
  );

  const onPointerDown = useCallback(
    (e: React.PointerEvent) => {
      if (e.button !== 0) return;
      if (pointerStartsInOverlayChrome(e.target)) {
        // The chrome behind this gesture owns it. Starting a region selection
        // here would move the toolbar out from under the click (see
        // `pointerStartsInOverlayChrome`).
        return;
      }
      selectionPointerStartRef.current = toPoint(e);
      selectionClickMovedRef.current = false;
      // OCR results: allow drawing a fresh region directly (no button) —
      // clicking/dragging in blank space starts a new selection which
      // re-runs recognition on release. phaseRef must be updated
      // synchronously so the same pointer-down proceeds into the drag
      // start below (setPhase alone is async and would return early).
      if (phaseRef.current === "ocr-result") {
        setOcrText("");
        setOcrFailed(false);
        setPhase("selecting");
        phaseRef.current = "selecting";
        setSelection(null);
        selectionRef.current = null;
      }
      if (
        phaseRef.current !== "mode-select" &&
        phaseRef.current !== "selecting" &&
        phaseRef.current !== "record-options"
      ) return;
      const p = clampPoint(toPoint(e), bounds);
      if (
        (phaseRef.current === "selecting" || phaseRef.current === "record-options") &&
        selectionRef.current
      ) {
        // Handle or move the existing selection.
        const handle = hitTestHandle(p, selectionRef.current, HANDLE_HIT_RADIUS);
        if (handle) {
          setResizeHandle(handle);
          setDrag({ start: p, current: p, moved: false });
          return;
        }
        if (contains(selectionRef.current, p)) {
          setMoveDrag({ start: p, original: { ...selectionRef.current } });
          return;
        }
      }
      setDrag({ start: p, current: p, moved: false });
    },
    [toPoint, bounds],
  );

  const onPointerMove = useCallback(
    (e: React.PointerEvent) => {
      const start = selectionPointerStartRef.current;
      if (start && Math.hypot(e.clientX - start.x, e.clientY - start.y) >= 3) {
        selectionClickMovedRef.current = true;
      }
      const p = clampPoint(toPoint(e), bounds);
      const interactive =
        phaseRef.current === "mode-select" ||
        phaseRef.current === "selecting" ||
        phaseRef.current === "record-options" ||
        (phaseRef.current === "ocr-result" && !!drag);
      if (!interactive) return;
      // Hover outline while not dragging. OCR mode never hovers windows
      // (spec §2.1: hoveredWindowSelection is always nil for .ocr).
      if (!drag && !resizeHandle && !moveDrag) {
        const candidate =
          modeRef.current !== "ocr" && context
            ? windowCandidate(p, context.windowRects, bounds)
            : null;
        if (candidate !== hoverWindowRef.current) {
          hoverWindowRef.current = candidate;
          setHoverWindow(candidate);
        }
        const currentSelection = selectionRef.current;
        const regionPhase =
          phaseRef.current === "selecting" || phaseRef.current === "record-options";
        setHoverHandle(
          regionPhase && currentSelection
            ? hitTestHandle(p, currentSelection, HANDLE_HIT_RADIUS)
            : null,
        );
        setHoverInsideSelection(regionPhase && !!currentSelection && contains(currentSelection, p));
        return;
      }
      setHoverWindow(null);
      if (resizeHandle && drag && selectionRef.current) {
        const resizedRect = resized(selectionRef.current, resizeHandle as never, p, bounds, 16);
        setSelection(resizedRect);
        setDrag({ ...drag, current: p, moved: true });
        return;
      }
      if (moveDrag) {
        const by = { x: p.x - moveDrag.start.x, y: p.y - moveDrag.start.y };
        const movedRect = {
          x: Math.min(Math.max(moveDrag.original.x + by.x, minX(bounds)), maxX(bounds) - moveDrag.original.width),
          y: Math.min(Math.max(moveDrag.original.y + by.y, minY(bounds)), maxY(bounds) - moveDrag.original.height),
          width: moveDrag.original.width,
          height: moveDrag.original.height,
        };
        setSelection(movedRect);
        return;
      }
      if (drag) {
        const moved = Math.hypot(p.x - drag.start.x, p.y - drag.start.y) >= 3;
        if (moved) {
          setSelection(normalized(drag.start, p));
          setDrag({ ...drag, current: p, moved: true });
        } else {
          setDrag({ ...drag, current: p });
        }
      }
    },
    [toPoint, bounds, context, drag, resizeHandle, moveDrag],
  );

  const onPointerUp = useCallback(
    (e: React.PointerEvent) => {
      if (e.button !== 0) return;
      const start = selectionPointerStartRef.current;
      if (start && Math.hypot(e.clientX - start.x, e.clientY - start.y) >= 3) {
        selectionClickMovedRef.current = true;
      }
      selectionPointerStartRef.current = null;
      const p = clampPoint(toPoint(e), bounds);
      if (resizeHandle || moveDrag) {
        setResizeHandle(null);
        setMoveDrag(null);
        setDrag(null);
        return;
      }
      if (drag) {
        const moved = Math.hypot(p.x - drag.start.x, p.y - drag.start.y) >= 3;
        const committedSelection = normalized(drag.start, p);
        if (!moved && context && modeRef.current !== "ocr") {
          const candidate = windowCandidate(p, context.windowRects, bounds);
          if (candidate) {
            setSelection(candidate);
            selectionRef.current = candidate;
            afterSelection(candidate);
          }
        } else if (moved && isValidSelection(committedSelection, 3)) {
          // Commit the release endpoint, not a partial/stale pointer-move render.
          // A plain click never starts OCR, and dragging cannot prepare a crop.
          setSelection(committedSelection);
          selectionRef.current = committedSelection;
          afterSelection(committedSelection);
        }
        setDrag(null);
      }
    },
    [toPoint, bounds, context, drag, resizeHandle, moveDrag],
  );

  function afterSelection(sel: Rect) {
    setSizeControlsOpen(false);
    if (modeRef.current === "screenshot") {
      // Spec §7.1: once a region is chosen, the toolbar appears immediately
      // but the region stays adjustable (phase stays .selecting, the
      // annotation canvas stays hidden). Picking a tool (or its shortcut)
      // is what locks the region into .annotating.
      setPhase("selecting");
      phaseRef.current = "selecting";
      setTool("select");
    } else if (modeRef.current === "ocr") {
      setPhase("ocr-preparing");
      void runOcr(sel);
    } else {
      setRecordSelectionRevision(value => value + 1);
      setPhase("record-options");
    }
  }

  // Switching modes clears transient UI while reusing a completed selection.
  // OCR starts only from this explicit action or a committed pointer release.
  // Remember the mode the user actually works in, debounced so holding a mode
  // key or spinning the wheel still writes once. Explicit entry points
  // (record/OCR shortcuts) force their own mode for that session.
  const persistCaptureMode = useCallback((value: Mode) => {
    if (modeWriteTimerRef.current !== null) clearTimeout(modeWriteTimerRef.current);
    modeWriteTimerRef.current = setTimeout(() => {
      modeWriteTimerRef.current = null;
      void api.setCaptureMode(value).catch(() => {});
    }, CAPTURE_MODE_WRITE_DELAY_MS);
  }, []);

  useEffect(
    () => () => {
      // Only a debounce that never fired needs the closing write. Writing on
      // every unmount would let a peer display overlay that never changed its
      // mode overwrite the choice made on the display the user worked in.
      if (modeWriteTimerRef.current === null) return;
      clearTimeout(modeWriteTimerRef.current);
      modeWriteTimerRef.current = null;
      // A capture that failed before its context arrived never learned the
      // backend's resolved mode; writing the local default would clobber it.
      if (!modeResolvedRef.current) return;
      void api.setCaptureMode(modeRef.current).catch(() => {});
    },
    [],
  );

  // One display's mode choice applied to this overlay. `runSelectionOcr` is
  // false for a peer display: it must follow the shared mode without starting
  // recognition on a leftover region the user did not act on.
  const adoptMode = useCallback(
    (next: Mode, runSelectionOcr: boolean) => {
      discardPreparedOcr();
      discardQr();
      modeRef.current = next;
      setMode(next);
      setSizeControlsOpen(false);
      setPhase("selecting");
      setDrag(null);
      setResizeHandle(null);
      setMoveDrag(null);
      setHoverWindow(null);
      hoverWindowRef.current = null;
      setOcrText("");
      setOcrFailed(false);
      setTool("select");
      const current = selectionRef.current;
      const hasSelection = !!current && isValidSelection(current, 3);
      if (next === "ocr") {
        if (runSelectionOcr && hasSelection && current) {
          // Reuse the finished crop once, without a render effect watching
          // live selection changes during a new OCR drag.
          void runOcr(current);
        } else if (!hasSelection) {
          setSelection(null);
        }
      } else if (next === "record" && hasSelection) {
        // Existing region + record mode → show the recording options.
        setPhase("record-options");
      } else if (next === "screenshot" && hasSelection) {
        // Existing region + screenshot → toolbar re-appears (selecting).
        setPhase("selecting");
      } else {
        setSelection(null);
      }
      // With a valid region: screenshot re-shows the toolbar (selecting
      // phase with a selection); record shows the options popover.
    },
    [discardPreparedOcr, discardQr, runOcr],
  );

  const switchMode = useCallback(
    (next: Mode) => {
      if (completionLock.locked) return;
      if (next === modeRef.current) return;
      adoptMode(next, true);
      persistCaptureMode(next);
      // Every display of this capture shows the same mode; the persisted
      // preference stays a separate, debounced write.
      void api.syncCaptureMode(next).catch(() => {});
    },
    [adoptMode, completionLock, persistCaptureMode],
  );

  const applyRemoteMode = useCallback(
    (next: Mode) => {
      if (next === modeRef.current) return;
      adoptMode(next, false);
    },
    [adoptMode],
  );

  // A peer display broadcasts the mode it picked; follow it without writing
  // the preference or starting OCR on this display's leftover region.
  useEffect(() => {
    let disposed = false;
    let unlisten: (() => void) | null = null;
    void onCaptureModeChanged((next) => {
      if (disposed) return;
      if (next !== "screenshot" && next !== "record" && next !== "ocr") return;
      if (completionLock.locked) return;
      if (!canSwitchMode(phaseRef.current)) return;
      applyRemoteMode(next);
    }).then((stop) => {
      if (disposed) stop();
      else unlisten = stop;
    }).catch(() => {});
    return () => {
      disposed = true;
      unlisten?.();
    };
  }, [applyRemoteMode, completionLock]);

  // --- mode switching without moving the pointer ---
  // Digits pick a mode outright; the wheel cycles them in place. Both only
  // apply while no annotation or result surface owns the overlay, and both
  // ignore editable controls so numeric inputs keep their native behavior.
  useEffect(() => {
    const onModeKeyDown = (e: KeyboardEvent) => {
      if (e.defaultPrevented || e.metaKey || e.ctrlKey || e.altKey) return;
      if (completionLock.locked) return;
      if (isTextComposition(e)) return;
      if (e.target instanceof Element && e.target.closest("input, textarea, select, [contenteditable]")) return;
      if (!canSwitchMode(phaseRef.current)) return;
      const next = modeForKey(e.key);
      if (!next) return;
      e.preventDefault();
      switchMode(next);
    };
    const onModeWheel = (e: WheelEvent) => {
      if (completionLock.locked) return;
      if (!canSwitchMode(phaseRef.current)) return;
      // Panels with their own scrolling range keep the wheel: the mode
      // selector is draggable chrome, the recording options scroll, and the
      // size fields need their native stepper behavior.
      if (
        e.target instanceof Element &&
        e.target.closest(
          ".kiri-mode-select, .kiri-capture-toolbar, .kiri-record-options, " +
            ".kiri-capture-tool-options, .kiri-capture-dimension, .kiri-color-picker, " +
            ".kiri-ocr-panel",
        )
      ) return;
      const result = wheelModeStep(
        wheelStateRef.current,
        normalizeWheelDelta(e.deltaY, e.deltaMode),
        performance.now(),
      );
      wheelStateRef.current = result.state;
      if (!result.direction) return;
      e.preventDefault();
      switchMode(cycleMode(modeRef.current, result.direction));
    };
    window.addEventListener("keydown", onModeKeyDown);
    window.addEventListener("wheel", onModeWheel, { passive: false });
    return () => {
      window.removeEventListener("keydown", onModeKeyDown);
      window.removeEventListener("wheel", onModeWheel);
    };
  }, [completionLock, switchMode]);

  // Leaving a region phase invalidates hover hit-test state gathered on the
  // frozen screen; a stale handle would otherwise keep a resize cursor.
  useEffect(() => {
    if (phase === "mode-select" || phase === "selecting" || phase === "record-options") return;
    setHoverHandle(null);
    setHoverInsideSelection(false);
  }, [phase]);

  // --- render ---
  const selectingRect = drag && drag.moved && !resizeHandle ? normalized(drag.start, drag.current) : null;
  const displayRect = selection ?? selectingRect;
  const activeDimRect = displayRect ?? hoverWindow;
  const annotating = phase === "annotating";
  const canResizeSelection = (mode === "screenshot" && phase === "selecting") ||
    (mode === "record" && (phase === "selecting" || phase === "record-options"));
  const showSizeControls = sizeControlsOpen && canResizeSelection;

  // A confirmed capture renders no editing UI at all. The window is about to
  // be destroyed; a transparent page is better than leaving a frozen
  // screenshot and its toolbar behind if the native close lags.
  //
  // A pending Pin handoff is hidden instead of unmounted: the annotation canvas
  // has to stay mounted so the export can still run, and a handoff that fails
  // must return the editor with its annotations intact. The overlay window is
  // transparent, so an invisible tree shows the desktop underneath.
  if (confirmed) {
    return (
      <div
        className="overlay-root kiri-dark"
        aria-hidden="true"
        style={{ position: "fixed", inset: 0, background: "transparent" }}
      />
    );
  }

  return (
    <div
      className="overlay-root kiri-dark"
      aria-busy={completing}
      data-interaction-disabled={completing || undefined}
      data-handoff={pinning ? "pin" : undefined}
      inert={completing || pinning}
      style={{
        position: "fixed",
        left: 0,
        top: 0,
        // Match selection and export coordinates even when the native
        // full-screen WebView allocation differs from the captured display.
        width: bounds.width,
        height: bounds.height,
        // While the frozen capture is still loading, stay translucent so the
        // live screen shows through; the window becomes opaque once the
        // frozen image is ready (mirroring the original's freeze behavior).
        background: frozenSrc ? "#141414" : "transparent",
        overflow: "hidden",
        // A pin handoff hides the whole editor without unmounting it: the
        // annotation canvas must survive for the export and for a retry, and a
        // transparent window shows the desktop once nothing paints.
        visibility: pinning ? "hidden" : undefined,
        pointerEvents: pinning ? "none" : undefined,
        cursor: interactionCursor({
          completing,
          phase,
          resizeHandle,
          moving: !!moveDrag,
          dragging: !!drag,
          hoverHandle,
          hoverInside: hoverInsideSelection,
        }),
      }}
      onPointerDown={completing || phase === "annotating" ? undefined : onPointerDown}
      onPointerDownCapture={colorPicker.clear}
      onPointerMoveCapture={colorPicker.onPointerMove}
      onPointerLeave={colorPicker.clear}
      onFocusCapture={colorPicker.clear}
      onPointerMove={completing || phase === "annotating" ? undefined : onPointerMove}
      onPointerUp={completing || phase === "annotating" ? undefined : onPointerUp}
      onClick={(event) => {
        const point = { x: event.clientX, y: event.clientY };
        const region = selectionRef.current;
        const eligible = event.target === event.currentTarget &&
          modeRef.current === "screenshot" && phaseRef.current === "selecting" &&
          !selectionClickMovedRef.current && !!region && isValidSelection(region, 3) &&
          contains(region, point) && !hitTestHandle(point, region, HANDLE_HIT_RADIUS);
        doubleClickCanFinishRef.current = event.detail === 1
          ? eligible : doubleClickCanFinishRef.current && eligible;
      }}
      onDoubleClick={(event) => {
        if (event.target !== event.currentTarget || !doubleClickCanFinishRef.current ||
          completionLock.locked || modeRef.current !== "screenshot" || phaseRef.current !== "selecting") return;
        event.preventDefault();
        void complete();
      }}
      onContextMenu={(e) => {
        // Spec §1.6: right-click returns to region selection while
        // annotating (tearing down annotations); otherwise it cancels.
        e.preventDefault();
        if (completing) return;
        if (phase === "qr-result") {
          closeQr();
        } else if (phase === "annotating") {
          setPhase("selecting");
          setSelection(null);
          setTool("select");
        } else {
          cancel();
        }
      }}
    >
      {context && frozenSrc && (
        <img
          ref={imageRef}
          src={frozenSrc}
          alt=""
          draggable={false}
          style={{ position: "absolute", inset: 0, width: "100%", height: "100%", pointerEvents: "none" }}
        />
      )}

      {colorPicker.sample && <CaptureColorPicker sample={colorPicker.sample} feedback={colorPicker.feedback} bounds={bounds} />}

      {/* Dim overlay */}
      {!activeDimRect && (
        <div
          style={{
            position: "absolute",
            inset: 0,
            background: "rgba(0,0,0,0.25)",
            pointerEvents: "none",
          }}
        />
      )}
      {/* Hover dim (spec: hover dims to 0.34, selection dims to 0.48) */}
      {activeDimRect && (
        <div style={{ position: "absolute", inset: 0, pointerEvents: "none" }}>
          <div
            style={{
              position: "absolute",
              left: activeDimRect.x,
              top: activeDimRect.y,
              width: activeDimRect.width,
              height: activeDimRect.height,
              boxShadow: "0 0 0 9999px rgba(0,0,0," + (displayRect ? "0.48" : "0.34") + ")",
            }}
          />
        </div>
      )}

      {/* Window hover outline: black edge stays legible against the white frozen-screen keyline. */}
      {hoverWindow && !displayRect && (
        <div
          style={{
            position: "absolute",
            left: hoverWindow.x,
            top: hoverWindow.y,
            width: hoverWindow.width,
            height: hoverWindow.height,
            border: `2px solid ${ACCENT}e6`,
            pointerEvents: "none",
          }}
        />
      )}

      {/* Selection outline: white outer keyline + black inner keyline. */}
      {displayRect && phase !== "annotating" && phase !== "qr-result" && (
        <>
          <div
            style={{
              position: "absolute",
              left: displayRect.x,
              top: displayRect.y,
              width: displayRect.width,
              height: displayRect.height,
              border: "3px solid rgba(255,255,255,0.92)",
              boxSizing: "border-box",
              pointerEvents: "none",
            }}
          />
          <div
            style={{
              position: "absolute",
              left: displayRect.x,
              top: displayRect.y,
              width: displayRect.width,
              height: displayRect.height,
              border: `1.5px solid ${ACCENT}`,
              boxSizing: "border-box",
              pointerEvents: "none",
            }}
          />
          <SelectionHandles rect={displayRect} />
          {!showSizeControls && <SizeBadge
            rect={displayRect}
            bounds={bounds}
            pixelScale={context?.scale ?? 1}
          />}
        </>
      )}

      {displayRect && showSizeControls && <CaptureSizeControls
        rect={displayRect} bounds={bounds} scale={context?.scale ?? 1}
        interactive={!!selection && !drag && !moveDrag && !resizeHandle && !completing}
        onChange={(axis, pixels) => {
          if (!selectionRef.current || !canResizeSelection || completionLock.locked) return;
          const next = resizeCapturePixels(selectionRef.current, bounds, context?.scale ?? 1, axis, pixels);
          selectionRef.current = next;
          setSelection(next);
        }}
      />}

      {/* Selection border while annotating: heavier white + black keylines. */}
      {displayRect && phase === "annotating" && (
        <>
          <div
            style={{
              position: "absolute",
              left: displayRect.x,
              top: displayRect.y,
              width: displayRect.width,
              height: displayRect.height,
              border: "4px solid rgba(255,255,255,0.92)",
              boxSizing: "border-box",
              pointerEvents: "none",
              zIndex: 5,
            }}
          />
          <div
            style={{
              position: "absolute",
              left: displayRect.x,
              top: displayRect.y,
              width: displayRect.width,
              height: displayRect.height,
              border: `2px solid ${ACCENT}`,
              boxSizing: "border-box",
              pointerEvents: "none",
              zIndex: 5,
            }}
          />
        </>
      )}

      {/* Annotation canvas — mounted (hidden) as soon as a region is chosen
          (spec §7.1: the canvas exists but is hidden until a tool is picked),
          so Done/Return export works without picking a tool. */}
      {selection &&
        isValidSelection(selection, 3) &&
        (annotating || phase === "selecting" || phase === "qr-result") && (
        <div
          style={{
            position: "absolute",
            left: selection.x,
            top: selection.y,
            width: selection.width,
            height: selection.height,
            visibility: annotating ? "visible" : "hidden",
            pointerEvents: annotating ? "auto" : "none",
          }}
        >
          <AnnotationCanvas
            ref={canvasRef}
            image={imageRef.current}
            displaySize={
              context
                ? { width: context.displayWidth, height: context.displayHeight }
                : undefined
            }
            region={{ x: selection.x, y: selection.y, width: selection.width, height: selection.height }}
            interactionDisabled={completing || phase === "qr-result"}
            interactionLock={completionLock}
            tool={tool}
            appearance={appearance}
            mosaicShape={appearance.mosaicShape}
            onError={setAnnotationError}
            calloutNumber={calloutNumber}
            onSelectionInfo={onAnnotationSelection}
            onDocumentChange={onAnnotationDocument}
            onHistoryChange={(u, r, hasContent) => {
              hasAnnotationContentRef.current = hasContent;
              setHasAnnotations(hasContent);
              setCanUndo(u);
              setCanRedo(r);
            }}
            onCancel={cancel}
            onFinishAfterTextCommit={() => void complete()}
            onFinishOnBlankDoubleClick={mode === "screenshot" ? () => void complete() : undefined}
          />
        </div>
      )}

      {/* Mode selector — ALWAYS visible (spec §1.2: never hidden), so the
          mode can be switched at any point: before/during selection and
          after a region is chosen (spec §2.4 changeCaptureMode). */}
      {!committing && phase !== "qr-result" && (
        <>
          <div
            ref={modeSelectorRef}
            className="kiri-hud kiri-mode-select"
            data-dragging={modeSelectorDragging || undefined}
            style={
              modeSelectorPosition
                ? {
                    zIndex: 8,
                    left: modeSelectorPosition.x,
                    top: modeSelectorPosition.y,
                    transform: "none",
                  }
                : { zIndex: 8 }
            }
            onPointerDown={modeSelectorPointerDown}
            onPointerMove={modeSelectorPointerMove}
            onPointerUp={finishModeSelectorDrag}
            onPointerCancel={cancelModeSelectorDrag}
            onLostPointerCapture={cancelModeSelectorDrag}
            onClickCapture={(event) => {
              if (!suppressModeSelectorClickRef.current) return;
              event.preventDefault();
              event.stopPropagation();
              suppressModeSelectorClickRef.current = false;
            }}
          >
            <ModeButton
              active={mode === "screenshot"}
              icon="camera.viewfinder"
              label={t("Screenshot")}
              badge="1"
              onClick={() => switchMode("screenshot")}
            />
            <ModeButton
              active={mode === "record"}
              icon="record.circle"
              label={t("Record")}
              badge="2"
              onClick={() => switchMode("record")}
            />
            <ModeButton
              active={mode === "ocr"}
              icon="text.viewfinder"
              label={t("OCR")}
              badge="3"
              onClick={() => switchMode("ocr")}
            />
          </div>
          {!selection && (
            <HintLabel
              text={
                (mode === "screenshot"
                  ? t("Drag to choose a capture area   ·   Click a window   ·   Esc to cancel")
                  : mode === "record"
                    ? t("Drag to choose a recording area   ·   Click a window   ·   Esc to cancel")
                    : t("Drag to choose text to recognize   ·   Esc to cancel")) +
                "   ·   " +
                t("Press 1 / 2 / 3 to change mode")
              }
              top={DEFAULT_HINT_TOP}
            />
          )}
        </>
      )}

      {phase === "qr-result" && selection && <QrOverlay scan={qrScan} failed={qrFailed} selection={selection} bounds={bounds} scale={context?.scale ?? 1} onClose={closeQr} onOpened={() => {
        // Wait for the opening IPC response before closing its owner WebView.
        // The backend already ended the capture and hid this overlay.
        void getCurrentWindow().close().catch(error => reportFrontend(`QR window close rejected: ${String(error)}`));
      }}/>}

      {/* OCR states */}
      {phase === "ocr-preparing" && <HintLabel text={t("Preparing Text…")} top={DEFAULT_HINT_TOP} />}
      {phase === "ocr-recognizing" && <HintLabel text={t("Recognizing Text…")} top={DEFAULT_HINT_TOP} />}

      {/* Drag hint while creating a region (spec §3.2.5: shown when no
          toolbar exists yet and the user is dragging). */}
      {phase === "selecting" && drag && drag.moved && !selection && (
        <HintLabel
          text={
            mode === "screenshot"
              ? t("Release to show tools")
              : mode === "record"
                ? t("Release for recording settings")
                : t("Release to recognize text")
          }
          top={DEFAULT_HINT_TOP}
        />
      )}
      {phase === "selecting" && mode === "ocr" && selection && !drag && (
        <HintLabel text={t("Release to recognize text")} top={DEFAULT_HINT_TOP} />
      )}
      {phase === "ocr-result" && (
        <OcrPanel
          text={ocrText}
          failed={ocrFailed}
          anchor={selection ?? { x: 0, y: 0, width: bounds.width, height: 0 }}
          bounds={bounds}
          modeSelectorBounds={modeSelectorBounds}
          onCopy={() => {
            void api.copyText(ocrText).catch(() => {});
          }}
          onClose={dismissOcrResult}
        />
      )}
      {phase === "ocr-consent" && preparedOcr?.profile && (
        <RemoteOcrConsent
          prepared={preparedOcr}
          anchor={selection ?? { x: 0, y: 0, width: bounds.width, height: 0 }}
          bounds={bounds}
          modeSelectorBounds={modeSelectorBounds}
          failed={remoteOcrFailed}
          onCancel={cancel}
          onUseLocal={() => void recognizePreparedLocal()}
          onSend={() => void recognizePreparedRemote()}
        />
      )}

      {/* Recording options */}
      {phase === "record-options" && selection && (
        <RecordOptionsPanel
          key={recordSelectionRevision}
          selectionAdjusting={!!drag || !!resizeHandle || !!moveDrag}
          anchor={selection}
          bounds={bounds}
          modeSelectorBounds={modeSelectorBounds}
          options={recordOptions}
          micSupported={micSupported && platformCaps.microphone}
          systemAudioSupported={platformCaps.systemAudio}
          clickHighlightsSupported={platformCaps.clickHighlights}
          trayRecordingControls={platformCaps.manualUpdates}
          sizeControlsOpen={sizeControlsOpen}
          onChange={(next) => {
            // Spec (recording §3): persist each toggle change immediately.
            setAnnotationError(null);
            setRecordOptions(next);
            void api.setRecordingOptions(next).catch(() => {});
          }}
          onStart={() => {
            setAnnotationError(null);
            void api.startRecordingFlow(selection, recordOptions).catch(error => setAnnotationError(recordingStartError(error)));
          }}
          onCancel={cancel}
        />
      )}

      {/* Toolbar — appears as soon as a region is chosen (spec §7.1); the
          region stays adjustable until a tool is picked, which locks it. */}
      {mode === "screenshot" && selection && (annotating || phase === "selecting") && (
        <Toolbar
          selection={selection}
          bounds={bounds}
          modeSelectorBounds={modeSelectorBounds}
          tool={tool}
          setTool={(next) => {
            canvasRef.current?.finishAppearanceAdjustment();
            if (next === "watermark") {
              if (phase === "selecting") setPhase("annotating");
              setTool(next);
              canvasRef.current?.editWatermark();
              return;
            }
            canvasRef.current?.commitTextEditing();
            if (next !== "select") canvasRef.current?.clearSelection();
            if (phase === "selecting") setPhase("annotating");
            setTool(next);
          }}
          appearance={appearance}
          setAppearance={setAppearance}
          selectedMark={selectedMark}
          avoidBounds={selectedAnnotationBounds}
          renderStyleControls={panelChrome => <AnnotationStyleControls panelChrome={panelChrome} tool={tool} selected={selectedMark} appearance={appearance}
            disabled={completing} nextNumber={calloutNumber} onNextNumber={setCalloutNumber}
            onCalloutEdit={(patch, transient) => canvasRef.current?.updateSelectedCallout(patch, transient)}
            onChange={(patch, transient) => { setAnnotationError(null); setAppearance({...appearance, ...patch}); canvasRef.current?.updateSelectionAppearance(patch, transient); }}
            onFinish={() => canvasRef.current?.finishAppearanceAdjustment()}
            onDelete={() => canvasRef.current?.deleteSelection()}
            onEditText={() => canvasRef.current?.editSelectedText()} onEditWatermark={() => canvasRef.current?.editWatermark()}/>}
          canUndo={canUndo}
          canRedo={canRedo}
          canSetSize={phase === "selecting"}
          sizeControlsOpen={sizeControlsOpen}
          onToggleSize={() => setSizeControlsOpen(open => !open)}
          disabled={completing}
          onUndo={() => canvasRef.current?.undo()}
          onRedo={() => canvasRef.current?.redo()}
          onDone={() => void complete()}
          onPin={() => void complete(true)}
          onScrollCapture={() => void startScrollCapture()}
          scrollCaptureUnavailable={!platformCaps.scrollingCapture
            ? "Scrolling capture is unavailable on this desktop."
            : hasAnnotations || selectedMarkEditing ? "Remove annotations before starting scrolling capture." : undefined}
          onOcr={() => {
            const canvas = canvasRef.current;
            canvas?.finishAppearanceAdjustment();
            if (canvas && !canvas.commitTextEditing()) return;
            switchMode("ocr");
          }}
          onQr={() => { if (selectionRef.current && !completionLock.locked) void runQr(selectionRef.current); }}
          onCancel={cancel}
        />
      )}

      {annotationError && <div role="alert" className="kiri-annotation-error" style={{bottom: 12}}
        onPointerDown={event => event.stopPropagation()}><span>{t(annotationError)}</span>
        <button type="button" className="kiri-annotation-error-dismiss" aria-label={t("Close")} onClick={() => setAnnotationError(null)}>×</button></div>}


    </div>
  );
}

// ---------------------------------------------------------------------------

function ModeButton(props: {
  active: boolean;
  icon: IconName;
  label: string;
  badge?: string;
  onClick(): void;
}) {
  return (
    <button
      type="button"
      onClick={props.onClick}
      className="kiri-mode-btn"
      aria-keyshortcuts={props.badge}
      data-active={props.active || undefined}
    >
      <span style={{ display: "flex", alignItems: "center", gap: 5 }}>
        <KiriIcon name={props.icon} size={14} />
        {props.label}
        {props.badge && (
          <span className="kiri-mode-btn__badge" aria-hidden="true">
            {props.badge}
          </span>
        )}
      </span>
    </button>
  );
}

function HintLabel(props: { text: string; top: number }) {
  return (
    <div
      style={{
        position: "absolute",
        left: "50%",
        top: props.top,
        transform: "translateX(-50%)",
        background: "rgba(8,8,8,0.86)",
        backdropFilter: "blur(12px)",
        WebkitBackdropFilter: "blur(12px)",
        border: "1px solid rgba(255,255,255,0.24)",
        borderRadius: "999px",
        color: "#fff",
        padding: "6px 11px",
        font: "550 11px var(--kiri-font-ui)",
        letterSpacing: "0.005em",
        whiteSpace: "pre",
        pointerEvents: "none",
        zIndex: 12,
        boxShadow: "0 8px 20px rgba(0,0,0,0.16)",
      }}
    >
      {props.text}
    </div>
  );
}

export function SelectionHandles(props: { rect: Rect }) {
  const { rect } = props;
  return (
    <>
      {ALL_HANDLES.map((handle) => {
        const p = handlePoint(handle, rect);
        return (
          // White outer circle with a black core remains visible over both
          // light and dark capture content.
          <div
            key={handle}
            style={{
              position: "absolute",
              left: p.x - 5,
              top: p.y - 5,
              width: 10,
              height: 10,
              borderRadius: "50%",
              background: "#fff",
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
              boxShadow: "0 0 2px rgba(0,0,0,0.3)",
              pointerEvents: "none",
            }}
          >
            <div
              style={{
                width: 6,
                height: 6,
                borderRadius: "50%",
                background: ACCENT,
              }}
            />
          </div>
        );
      })}
    </>
  );
}

function SizeBadge(props: { rect: Rect; bounds: Rect; pixelScale: number }) {
  const { rect, bounds } = props;
  const pixelScale =
    Number.isFinite(props.pixelScale) && props.pixelScale > 0 ? props.pixelScale : 1;
  // Selection geometry is expressed in display points, while the exact-size
  // controls and exported capture use physical pixels. Keep the badge in the
  // same unit so a 200 × 300 px request does not appear as 100 × 150 on a
  // Retina display.
  const pixelWidth = Math.round(rect.width * pixelScale);
  const pixelHeight = Math.round(rect.height * pixelScale);
  const label = `${pixelWidth} × ${pixelHeight}`;
  // Spec §3.2.3: badge sits 6pt above the selection, x clamped to
  // [6, bounds.maxX - badgeWidth - 6]; if it would clip the top edge,
  // it moves inside the selection's top instead.
  const width = Math.max(48, label.length * 7 + 16);
  const height = 22;
  const rawX = rect.x;
  const left = Math.min(Math.max(6, rawX), Math.max(6, bounds.width - width - 6));
  const outside = rect.y - height - 6;
  const top = outside >= 6 ? outside : rect.y + 6;
  return (
    <div
      style={{
        position: "absolute",
        left,
        top,
        width,
        height,
        background: "rgba(0,0,0,0.76)",
        border: "1px solid rgba(255,255,255,0.16)",
        borderRadius: height / 2,
        color: "#fff",
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        font: "500 11px ui-monospace, SFMono-Regular, Menlo, monospace",
        pointerEvents: "none",
        boxSizing: "border-box",
      }}
    >
      {label}
    </div>
  );
}

function OcrPanel(props: {
  text: string;
  failed: boolean;
  anchor: Rect;
  bounds: Rect;
  modeSelectorBounds?: Rect | null;
  onCopy(): void;
  onClose(): void;
}) {
  const { text, failed, anchor, bounds, modeSelectorBounds, onCopy, onClose } = props;
  const panelRef = useRef<HTMLDivElement>(null);
  const textRef = useRef<HTMLDivElement>(null);
  const [measuredHeight, setMeasuredHeight] = useState(0);
  const measurePanel = () => {
    const element = panelRef.current;
    if (!element) return;
    const content = textRef.current;
    const hiddenContent = content ? Math.max(0, content.scrollHeight - content.clientHeight) : 0;
    // Text has its own 150px reading viewport; only panel-induced clipping
    // should make the panel taller, not a long recognized document.
    const height = Math.ceil(element.getBoundingClientRect().height + Math.min(hiddenContent,
      Math.max(0, 150 - (content?.clientHeight ?? 0))));
    setMeasuredHeight(current => current === height ? current : height);
  };
  useLayoutEffect(measurePanel);
  useLayoutEffect(() => {
    const element = panelRef.current;
    if (!element) return;
    const observer = new ResizeObserver(measurePanel);
    observer.observe(element);
    if (textRef.current) observer.observe(textRef.current);
    return () => observer.disconnect();
  }, []);
  const { left, top, width: panelWidth, maxHeight } = capturePanelLayout(
    anchor, bounds, { width: 368, height: measuredHeight }, modeSelectorBounds,
  );
  return (
    <div
      ref={panelRef}
      className="kiri-hud kiri-ocr-panel"
      onPointerDown={(e) => e.stopPropagation()}
      style={{
        position: "absolute",
        left,
        top,
        width: panelWidth,
        maxHeight,
        overflow: "hidden",
        zIndex: 8,
        padding: 14,
        boxSizing: "border-box",
        borderRadius: 16,
        display: "flex",
        flexDirection: "column",
        gap: 10,
        boxShadow: "0 16px 42px rgba(0,0,0,0.22)",
      }}
    >
      <div style={{ display: "flex", flexShrink: 0, justifyContent: "space-between", alignItems: "center" }}>
        <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
          <span
            style={{
              width: 28,
              height: 28,
              display: "grid",
              placeItems: "center",
              borderRadius: 8,
              background: "#fff",
              color: "#000",
            }}
          >
            <KiriIcon name="text.viewfinder" size={15} />
          </span>
          <span style={{ font: "700 13px var(--kiri-font-ui)" }}>
            {failed ? t("Text Recognition Failed") : t("Recognized Text")}
          </span>
        </div>
        <button
          type="button"
          className="kiri-icon-button kiri-icon-button--hud"
          aria-label={t("Close")}
          title={t("Close")}
          onClick={onClose}
          style={{
            width: 28,
            height: 28,
          }}
        >
          <KiriIcon name="xmark" size={11} />
        </button>
      </div>
      <div
        ref={textRef}
        role="region"
        aria-label={t("Recognized Text")}
        tabIndex={0}
        style={{
          background: "rgba(255,255,255,0.97)",
          color: "#0a0a0a",
          borderRadius: 11,
          padding: "12px 14px",
          minHeight: Math.min(96, Math.max(0, maxHeight - 160)),
          flex: "1 1 auto",
          maxHeight: 150,
          boxSizing: "border-box",
          overflow: "auto",
          font: "450 13px/1.48 var(--kiri-font-ui)",
          userSelect: "text",
          WebkitUserSelect: "text",
          cursor: "text",
          whiteSpace: "pre-wrap",
          border: "1px solid rgba(255,255,255,0.24)",
          boxShadow: "inset 0 0 0 1px rgba(0,0,0,0.08)",
        }}
      >
        {text || (failed ? t("Adjust the region and try again") : t("No Text Found"))}
      </div>
      <button
        type="button"
        className="kiri-primary-button"
        onClick={onCopy}
        disabled={!text}
        style={{
          minHeight: 38,
          flexShrink: 0,
          borderRadius: 10,
          alignSelf: "flex-end",
          minWidth: 112,
          padding: "0 16px",
          display: "inline-flex",
          alignItems: "center",
          justifyContent: "center",
          gap: 7,
        }}
      >
        <KiriIcon name="doc.on.doc" size={13} />
        {t("Copy")}
      </button>
    </div>
  );
}

export function RecordOptionsPanel(props: {
  anchor: Rect;
  bounds: Rect;
  modeSelectorBounds?: Rect | null;
  selectionAdjusting?: boolean;
  options: RecordingOptions;
  micSupported: boolean;
  systemAudioSupported: boolean;
  clickHighlightsSupported: boolean;
  trayRecordingControls: boolean;
  sizeControlsOpen: boolean;
  onChange(options: RecordingOptions): void;
  onStart(): void;
  onCancel(): void;
}) {
  const { anchor, bounds, modeSelectorBounds, selectionAdjusting, options, micSupported,
    systemAudioSupported, clickHighlightsSupported, trayRecordingControls,
    sizeControlsOpen, onChange, onStart, onCancel } = props;
  const panelRef = useRef<HTMLDivElement>(null);
  const scrollRef = useRef<HTMLDivElement>(null);
  const [measuredHeight, setMeasuredHeight] = useState(140);
  const settledAnchor = useRef(anchor);
  // Keep the panel stationary and pass pointer input through while the region
  // is being moved/resized. Re-anchor once on release, not on every drag frame.
  if (!selectionAdjusting) settledAnchor.current = anchor;
  const measurePanel = () => {
    const element = panelRef.current;
    if (!element) return;
    const scroll = scrollRef.current;
    const hiddenContent = Math.max(0, (element.scrollHeight ?? 0) - (element.clientHeight ?? 0))
      + (scroll ? Math.max(0, scroll.scrollHeight - scroll.clientHeight) : 0);
    const height = Math.ceil(element.getBoundingClientRect().height + hiddenContent);
    setMeasuredHeight(current => current === height ? current : height);
  };
  useLayoutEffect(measurePanel);
  useLayoutEffect(() => {
    const element = panelRef.current;
    if (!element) return;
    const observer = new ResizeObserver(measurePanel);
    observer.observe(element);
    const content = scrollRef.current?.firstElementChild;
    if (content) observer.observe(content);
    return () => observer.disconnect();
  }, []);
  const gifOutput = options.outputFormat === "gif";
  const toggle = (key: "capturesSystemAudio" | "capturesMicrophone" | "showsCursor" | "highlightsClicks") => {
    const next = { ...options, usesCountdown: true, [key]: !options[key] };
    if (key === "showsCursor" && !next.showsCursor) next.highlightsClicks = false;
    onChange(next);
  };
  const layout = recordingPanelLayout(settledAnchor.current, bounds,
    { width: 336, height: measuredHeight }, modeSelectorBounds, sizeControlsOpen);
  const unavailable = t("Unavailable on this platform");
  return (
    <div ref={panelRef} className="kiri-record-options" role="region" aria-label={t("Record Region")}
      data-adjusting={selectionAdjusting || undefined}
      data-constrained={layout.maxHeight < 128 || undefined}
      style={{ left: layout.left, top: layout.top, width: layout.width, maxHeight: layout.maxHeight }}
      onPointerDown={event => event.stopPropagation()}
      onPointerMove={event => event.stopPropagation()}
      onPointerUp={event => event.stopPropagation()}>
      <div className="kiri-record-options__header">
        <div className="kiri-record-options__format-row">
          <div className="kiri-record-options__formats" role="group" aria-label={t("Recording format")}>
            {(["mp4", "gif"] as const).map(format => (
              <button key={format} type="button" className="kiri-record-options__format"
                aria-pressed={options.outputFormat === format}
                title={format === "gif" ? t("GIF · 12 fps · 720 px long edge · No audio") : t("MP4 · 30 fps · Saved locally")}
                onClick={() => onChange({ ...options, usesCountdown: true, outputFormat: format })}>
                {t(format === "mp4" ? "MP4" : "GIF")}
              </button>
            ))}
          </div>
        </div>
        <button type="button" className="kiri-record-options__start" onClick={onStart}>
          <span className="kiri-record-options__record-dot" aria-hidden="true" />
          {gifOutput ? t("Start GIF Recording") : t("Start Recording")}
        </button>
        <button type="button" className="kiri-record-options__icon" aria-label={t("Cancel")} title={t("Cancel")}
          onClick={onCancel}><KiriIcon name="xmark" size={16} /></button>
      </div>
      <div ref={scrollRef} className="kiri-record-options__scroll">
        <div className="kiri-record-options__body">
          <div className="kiri-record-options__inputs">
            <RecordInput label={t("System audio")} checked={!gifOutput && systemAudioSupported && options.capturesSystemAudio}
              disabled={gifOutput || !systemAudioSupported}
              title={gifOutput ? t("GIF · 12 fps · 720 px long edge · No audio") : !systemAudioSupported ? unavailable : undefined}
              onToggle={() => toggle("capturesSystemAudio")}
              icon={<Volume2 size={17} />} />
            <RecordInput label={t("Microphone")} checked={!gifOutput && micSupported && options.capturesMicrophone}
              disabled={gifOutput || !micSupported}
              title={gifOutput ? t("GIF · 12 fps · 720 px long edge · No audio") : !micSupported ? unavailable : undefined}
              onToggle={() => toggle("capturesMicrophone")}
              icon={<Mic size={17} />}
              accessory={<RecordingMicrophoneSelect options={options} disabled={gifOutput || !micSupported} onChange={onChange} />} />
            <RecordInput label={t("Pointer")} checked={options.showsCursor}
              onToggle={() => toggle("showsCursor")} icon={<MousePointer2 size={17} />} />
            <RecordInput label={t("Click highlight")} checked={options.showsCursor && clickHighlightsSupported && options.highlightsClicks}
              disabled={!options.showsCursor || !clickHighlightsSupported}
              title={!clickHighlightsSupported ? unavailable : !options.showsCursor ? t("Enable pointer to highlight clicks") : undefined}
              onToggle={() => toggle("highlightsClicks")} icon={<MousePointerClick size={17} />} />
          </div>
          {trayRecordingControls && <p className="kiri-record-options__tray">{t("Use the tray menu to pause, resume, or stop recording.")}</p>}
        </div>
      </div>
    </div>
  );
}

function RecordInput(props: { label: string; checked: boolean; disabled?: boolean; title?: string;
  onToggle(): void; icon: React.ReactNode; accessory?: React.ReactNode }) {
  return <div className="kiri-record-options__input-group" data-accessory={!!props.accessory || undefined}>
    <button type="button" className="kiri-record-options__input" role="switch" aria-checked={props.checked}
      disabled={props.disabled} title={props.title ?? props.label} onClick={props.onToggle}>
      <span className="kiri-record-options__input-icon" aria-hidden="true">{props.icon}</span>
      <span className="kiri-record-options__input-label">{props.label}</span>
      <span className="kiri-record-options__input-toggle" aria-hidden="true" />
    </button>
    {props.accessory}
  </div>;
}

interface ToolbarProps {
  selection: Rect;
  bounds: Rect;
  modeSelectorBounds?: Rect | null;
  tool: Tool;
  setTool(tool: Tool): void;
  appearance: AppearanceSettings;
  setAppearance(a: AppearanceSettings): void;
  selectedMark?: AnnotationMark | null;
  styleControls?: React.ReactNode;
  renderStyleControls?(panelChrome: React.ReactNode): React.ReactNode;
  avoidBounds?: Rect[];
  labelControls?: React.ReactNode;
  showLabelControls?: boolean;
  selectedLabelId?: number;
  calloutControls?: React.ReactNode;
  showCalloutControls?: boolean;
  selectedCalloutId?: number;
  canUndo: boolean;
  canRedo: boolean;
  canSetSize: boolean;
  sizeControlsOpen: boolean;
  onToggleSize(): void;
  disabled: boolean;
  onUndo(): void;
  onRedo(): void;
  onDone(): void;
  onPin(): void;
  onOcr(): void;
  onQr(): void;
  onScrollCapture?(): void;
  scrollCaptureUnavailable?: string;
  onCancel(): void;
  onTextFontBegin?(): void;
  onTextFontLive?(value: number): void;
  onTextFontEnd?(): void;
}

const TOOLS: { tool: Tool; icon: IconName; title: string; shortcut: string }[] = [
  { tool: "select", icon: "cursorarrow", title: "Select (V)", shortcut: "V" },
  { tool: "pen", icon: "pencil.tip", title: "Pen (P)", shortcut: "P" },
  { tool: "rectangle", icon: "rectangle.dashed", title: "Rectangle (R)", shortcut: "R" },
  { tool: "line", icon: "line.diagonal", title: "Line (L)", shortcut: "L" },
  { tool: "arrow", icon: "arrow.up.right", title: "Arrow (A)", shortcut: "A" },
  { tool: "text", icon: "textformat", title: "Text (T)", shortcut: "T" },
  { tool: "callout", icon: "number.circle", title: "Numbered callout (N)", shortcut: "N" },
  { tool: "label", icon: "tag", title: "Label bubble (B)", shortcut: "B" },
  { tool: "mosaic", icon: "square.grid.3x3.fill", title: "Mosaic (M)", shortcut: "M" },
  { tool: "watermark", icon: "watermark", title: "Watermark (W)", shortcut: "W" },
];

const toolbarRowStyle: React.CSSProperties = {
  display: "flex",
  flexWrap: "wrap",
  width: "max-content",
  maxWidth: "100%",
  boxSizing: "border-box",
  alignItems: "center",
  justifyContent: "center",
  gap: 2,
  padding: "6px",
  pointerEvents: "auto",
};

function useToolbarDrag(position: Point, enabled: boolean, onMove: (point: Point) => void) {
  const [dragging, setDragging] = useState(false);
  const drag = useRef<{pointerId: number; target: HTMLButtonElement; start: Point; origin: Point} | null>(null);
  const finish = (event?: React.PointerEvent<HTMLButtonElement>) => {
    const gesture = drag.current;
    if (!gesture || (event && event.pointerId !== gesture.pointerId)) return;
    event?.stopPropagation();
    drag.current = null;
    if (gesture.target.hasPointerCapture(gesture.pointerId)) gesture.target.releasePointerCapture(gesture.pointerId);
    setDragging(false);
  };
  useEffect(() => { if (!enabled) finish(); }, [enabled]);
  useEffect(() => () => {
    const gesture = drag.current;
    drag.current = null;
    if (gesture?.target.hasPointerCapture(gesture.pointerId)) gesture.target.releasePointerCapture(gesture.pointerId);
  }, []);
  useEffect(() => {
    const cancelDragOnEscape = (event: KeyboardEvent) => {
      // Pointer dragging preserves the canvas textarea's focus, so the key's
      // target may be outside the grip. End only this gesture, not that edit.
      if (event.key !== "Escape" || !drag.current || isTextComposition(event)) return;
      event.preventDefault(); event.stopImmediatePropagation();
      finish();
    };
    window.addEventListener("keydown", cancelDragOnEscape, true);
    return () => window.removeEventListener("keydown", cancelDragOnEscape, true);
  }, []);
  return {
    "data-dragging": dragging || undefined,
    onPointerDown(event: React.PointerEvent<HTMLButtonElement>) {
      if (!enabled || event.button !== 0 || !event.isPrimary || drag.current) return;
      event.preventDefault(); event.stopPropagation();
      drag.current = {pointerId: event.pointerId, target: event.currentTarget,
        start: {x: event.clientX, y: event.clientY}, origin: position};
      event.currentTarget.setPointerCapture(event.pointerId);
      setDragging(true);
    },
    onPointerMove(event: React.PointerEvent<HTMLButtonElement>) {
      const gesture = drag.current;
      if (!gesture || gesture.pointerId !== event.pointerId || !enabled) return;
      event.preventDefault(); event.stopPropagation();
      onMove({x: gesture.origin.x + event.clientX - gesture.start.x,
        y: gesture.origin.y + event.clientY - gesture.start.y});
    },
    onPointerUp: finish, onPointerCancel: finish, onLostPointerCapture: finish,
    onKeyDown(event: React.KeyboardEvent<HTMLButtonElement>) {
      event.stopPropagation();
      if (!enabled) return;
      if (event.key === "Escape") { event.preventDefault(); finish(); event.currentTarget.blur(); return; }
      if (event.key === "Enter" || event.key === " ") { event.preventDefault(); return; }
      if (!["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"].includes(event.key)) return;
      event.preventDefault();
      const step = event.shiftKey ? 10 : 2;
      onMove({x: position.x + (event.key === "ArrowLeft" ? -step : event.key === "ArrowRight" ? step : 0),
        y: position.y + (event.key === "ArrowUp" ? -step : event.key === "ArrowDown" ? step : 0)});
    },
  };
}

export function Toolbar(props: ToolbarProps) {
  const {selection, bounds, tool, setTool, canUndo, canRedo, canSetSize, sizeControlsOpen, onToggleSize,
    disabled, onUndo, onRedo, onDone, onPin, onOcr, onQr, onCancel} = props;
  const [detailsOpen, setDetailsOpen] = useState(false);
  const detailsHidden = useRef(false);
  useEffect(() => {
    if (!detailsHidden.current) setDetailsOpen(tool !== "select" || props.selectedMark != null || props.selectedCalloutId !== undefined || props.selectedLabelId !== undefined);
  }, [tool, props.selectedMark?.id, props.selectedCalloutId, props.selectedLabelId]);
  const toggleDetails = () => setDetailsOpen(open => {
    detailsHidden.current = open;
    return !open;
  });
  const [optionsPosition, setOptionsPosition] = useState<Point | null>(null);
  const [optionsAdjustmentPosition, setOptionsAdjustmentPosition] = useState<Point | null>(null);
  const optionsAdjustment = useRef<{pointerId: number | null; numberInput: HTMLElement | null}>({pointerId: null, numberInput: null});
  const [toolbarPosition, setToolbarPosition] = useState<Point | null>(null);
  const mainRef = useRef<HTMLDivElement>(null);
  const optionsRef = useRef<HTMLDivElement>(null);
  const barRef = useRef<HTMLDivElement>(null);
  const [barSize, setBarSize] = useState({ width: 420, height: 48 });
  const [optionsHeight, setOptionsHeight] = useState(96);
  const options = props.styleControls ?? (props.showLabelControls ? props.labelControls : props.showCalloutControls ? props.calloutControls : null);
  const showOptions = detailsOpen && !canSetSize && (!!props.renderStyleControls || !!options);
  // Measure each committed row change before paint, and observe later reflows
  // (font loading, translations and viewport wrapping) as well.
  const measureBar = () => {
    const el = mainRef.current;
    if (!el) return;
    setBarSize((previous) => {
      const width = el.offsetWidth;
      const height = el.offsetHeight;
      return width === previous.width && height === previous.height
        ? previous : { width, height };
    });
    const panel = optionsRef.current;
    if (panel) {
      // Scroll height preserves natural content height while the available
      // property area is constrained by the toolbar or the mode selector.
      setOptionsHeight(panel.scrollHeight + panel.offsetHeight - panel.clientHeight);
    }
  };
  useLayoutEffect(measureBar);
  useLayoutEffect(() => {
    const el = mainRef.current;
    if (!el) return;
    const observer = new ResizeObserver(measureBar);
    observer.observe(el);
    if (optionsRef.current) observer.observe(optionsRef.current);
    return () => observer.disconnect();
  }, [showOptions]);
  // Only the main row determines its anchor. Keep dimension clearance while
  // switching into annotation so choosing a tool does not move that anchor.
  const {left, top} = captureToolbarPosition(selection, bounds, barSize,
    sizeControlsOpen, props.modeSelectorBounds, toolbarPosition);
  const optionsLayout = captureToolOptionsLayout({x: left, y: top, ...barSize}, bounds,
    {width: Math.min(620, barSize.width), height: optionsHeight}, props.modeSelectorBounds, props.avoidBounds,
    optionsPosition ?? optionsAdjustmentPosition);
  const optionsLayoutRef = useRef(optionsLayout);
  optionsLayoutRef.current = optionsLayout;
  const holdOptionsPosition = () => setOptionsAdjustmentPosition(previous => previous ?? {
    x: optionsLayoutRef.current.left, y: optionsLayoutRef.current.top,
  });
  const finishOptionsPointer = (event: {pointerId: number}) => {
    if (optionsAdjustment.current.pointerId !== event.pointerId) return;
    optionsAdjustment.current.pointerId = null;
    if (!optionsAdjustment.current.numberInput) setOptionsAdjustmentPosition(null);
  };
  const clearOptionsAdjustment = () => {
    optionsAdjustment.current = {pointerId: null, numberInput: null};
    setOptionsAdjustmentPosition(null);
  };
  // Font/number changes also change annotation bounds. Keep controls under the
  // pointer (or focused number editor) until that adjustment is finished.
  useEffect(clearOptionsAdjustment, [showOptions, disabled, tool, props.selectedMark?.id, props.selectedCalloutId, props.selectedLabelId]);
  useEffect(() => {
    const restoreNumberFocus = () => {
      const input = document.activeElement;
      if (!input?.matches('input[type="number"]:not(:disabled)') || !optionsRef.current?.contains(input)) return;
      optionsAdjustment.current.numberInput = input as HTMLElement;
      holdOptionsPosition();
    };
    window.addEventListener("pointerup", finishOptionsPointer, true);
    window.addEventListener("pointercancel", finishOptionsPointer, true);
    window.addEventListener("lostpointercapture", finishOptionsPointer, true);
    window.addEventListener("blur", clearOptionsAdjustment);
    window.addEventListener("focus", restoreNumberFocus);
    return () => {
      window.removeEventListener("pointerup", finishOptionsPointer, true);
      window.removeEventListener("pointercancel", finishOptionsPointer, true);
      window.removeEventListener("lostpointercapture", finishOptionsPointer, true);
      window.removeEventListener("blur", clearOptionsAdjustment);
      window.removeEventListener("focus", restoreNumberFocus);
    };
  }, []);
  const toolbarDrag = useToolbarDrag({x: left, y: top}, !disabled, setToolbarPosition);
  const optionsDrag = useToolbarDrag({x: optionsLayout.left, y: optionsLayout.top}, showOptions && !disabled, setOptionsPosition);
  const dragGlyph = <svg width="14" height="14" viewBox="0 0 14 14" fill="currentColor" aria-hidden="true">
    {[3, 7, 11].flatMap(y => [4, 10].map(x => <circle key={`${x}-${y}`} cx={x} cy={y} r="1"/>))}
  </svg>;
  const panelChrome = <>
    <button type="button" className="kiri-capture-options-move" disabled={disabled}
      aria-label={t("Move tool options")} title={t("Drag to move. Use arrow keys for fine adjustments.")}
      {...optionsDrag}>{dragGlyph}</button>
    <button type="button" className="kiri-capture-options-hide" disabled={disabled}
      aria-label={t("Hide tool options")} title={t("Hide tool options")}
      onPointerDown={event => event.preventDefault()} onKeyDown={event => event.stopPropagation()}
      onClick={event => {
        detailsHidden.current = true;
        setDetailsOpen(false);
        if (document.activeElement === event.currentTarget) mainRef.current?.querySelector<HTMLButtonElement>("button[aria-expanded]")?.focus();
      }}>
      <svg width="14" height="14" viewBox="0 0 14 14" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d="m3 9 4-4 4 4"/></svg>
    </button>
  </>;
  const button = ({tool: value, icon, title, shortcut}: typeof TOOLS[number]) =>
    <ToolButton key={value} icon={icon} title={t(title)} shortcut={shortcut} active={tool === value} disabled={disabled} onClick={() => setTool(value)}/>;

  return (
    <>
      <div
        ref={barRef}
        className="kiri-capture-toolbar"
        aria-disabled={disabled}
        onPointerDown={(e) => e.stopPropagation()}
        style={{
          position: "absolute",
          left,
          top,
          display: "flex",
          flexDirection: "column",
          width: "max-content",
          maxWidth: Math.max(0, bounds.width - 16),
          boxSizing: "border-box",
          alignItems: "center",
          gap: 6,
          zIndex: 8,
          pointerEvents: "none",
          boxShadow: "none",
          opacity: disabled ? 0.62 : 1,
          transition: "opacity 0.12s ease-out",
        }}
      >
        <div ref={mainRef} className="kiri-hud kiri-annotation-tool-row" style={toolbarRowStyle}>
          <div className="kiri-annotation-tool-group">
            <button type="button" className="kiri-capture-toolbar-move" disabled={disabled}
              aria-label={t("Move annotation toolbar")} title={t("Drag to move. Use arrow keys for fine adjustments.")}
              {...toolbarDrag}>{dragGlyph}</button>
            <ToolButton icon="xmark" title={t("Cancel capture · Esc")} shortcut="Escape" onClick={onCancel}/>
          </div>
          <div className="kiri-annotation-tool-group" role="group" aria-label={t("Annotations")}>{TOOLS.map(button)}</div>
          <div className="kiri-annotation-tool-group">
            <ToolButton icon="arrow.uturn.backward" title={t("Undo")} shortcut="Mod+Z" disabled={!canUndo} onClick={onUndo}/>
            <ToolButton icon="arrow.uturn.forward" title={t("Redo")} shortcut="Mod+Shift+Z" disabled={!canRedo} onClick={onRedo}/>
          </div>
          <div className="kiri-annotation-tool-group">
            <ToolButton icon="text.viewfinder" title={t("Recognize Text")} disabled={disabled} onClick={onOcr}/>
            <ToolButton icon="qrcode" title={t("Recognize QR Codes")} disabled={disabled} onClick={onQr}/>
            {props.onScrollCapture && <ToolButton icon="arrows.up.down"
              title={props.scrollCaptureUnavailable ? `${t("Scrolling Screenshot")} · ${t(props.scrollCaptureUnavailable)}` : t("Scrolling Screenshot")}
              disabled={disabled || !!props.scrollCaptureUnavailable} onClick={props.onScrollCapture}/>}
            <ToolButton icon="slider.horizontal.3" title={t(canSetSize ? "Resize selection" : "Tool options")}
              active={canSetSize ? sizeControlsOpen : detailsOpen} expanded={canSetSize ? sizeControlsOpen : detailsOpen}
              onClick={() => canSetSize ? onToggleSize() : toggleDetails()}/>
            <ToolButton icon="pin" title={t("Pin Screenshot on Top")} disabled={disabled} onClick={onPin}/>
            <ToolButton icon="checkmark" title={t("Done — Copy to clipboard")} shortcut="Enter" primary disabled={disabled} onClick={onDone}/>
          </div>
        </div>
        {showOptions && <div ref={optionsRef} className="kiri-hud kiri-capture-tool-options"
          onPointerDownCapture={event => {
            if (disabled || event.button !== 0 || !event.isPrimary || optionsAdjustment.current.pointerId !== null) return;
            const control = (event.target as HTMLElement).closest("input, select, textarea, button, [role=slider]");
            if (!control || control.matches(".kiri-capture-options-move, .kiri-capture-options-hide")) return;
            optionsAdjustment.current.pointerId = event.pointerId;
            holdOptionsPosition();
          }}
          onPointerUpCapture={finishOptionsPointer} onPointerCancelCapture={finishOptionsPointer}
          onLostPointerCaptureCapture={finishOptionsPointer}
          onFocusCapture={event => {
            if (disabled || !event.target.matches('input[type="number"]')) return;
            optionsAdjustment.current.numberInput = event.target;
            holdOptionsPosition();
          }}
          onBlurCapture={event => {
            if (optionsAdjustment.current.numberInput !== event.target) return;
            const next = event.relatedTarget as HTMLElement | null;
            optionsAdjustment.current.numberInput = next?.matches?.('input[type="number"]') &&
              event.currentTarget.contains(next) ? next : null;
            if (!optionsAdjustment.current.numberInput && optionsAdjustment.current.pointerId === null) setOptionsAdjustmentPosition(null);
          }}
          style={{position: "absolute", left: optionsLayout.left - left, top: optionsLayout.top - top,
            width: optionsLayout.width, maxHeight: optionsLayout.maxHeight}}>
          {props.renderStyleControls ? props.renderStyleControls(panelChrome) : <><div className="kiri-capture-options-chrome">{panelChrome}</div>{options}</>}
        </div>}
      </div>
    </>
  );
}

const ToolButton = AnnotationToolbarButton;

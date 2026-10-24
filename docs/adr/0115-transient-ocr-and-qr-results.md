# ADR 0115: Transient OCR and QR results

Status: accepted for implementation; native acceptance uses the existing OCR/QR checklists.

## Context

Kiri 1.5 and 1.6 added two library-shaped destinations, Text History and QR
Favorites. Both persisted recognition output as extra image assets: OCR text
with `ocrText`/`ocrOriginalText` metadata and an independent PNG snapshot, and a
selected QR code's crop with searchable `qrText`. They also added dedicated
sidebar destinations with their own search, list/detail panes and edit actions.

In practice the main task is to read or copy a result once. Two extra sections
and a second persistence lifecycle made the main window feel busy, duplicated
library storage, and forced users to choose between "capture" and "history"
mental models for the same recognized content.

## Decision

Remove both destinations and their persistence paths. New OCR results stay in
the capture overlay or the saved-image dialog until dismissed, with Copy Text
available in place. New QR results stay in the existing recognition overlay;
selecting a code offers Copy and Open Link only. Neither path writes an asset,
an `ocrText`/`qrText` field, a snapshot, or a library-index commit.

Keep recognition itself unchanged: the initial overlay still offers Screenshot,
Record and OCR; the screenshot toolbar and saved-image editor still offer
Recognize QR Codes; local and opt-in remote OCR profiles and their disclosure
flow remain. Only the history/favorite storage and its two sidebar destinations
are removed.

Existing libraries remain readable. The legacy `ocrText`, `ocrOriginalText` and
`qrText` fields stay in the asset schema with their Swift-compatible JSON shape,
so old records still load, keep their text searchable, and follow the normal
Trash and permanent-deletion lifecycle. They are never rewritten or deleted by
migration, and no new record is created with them. Because their dedicated
grids no longer exist, legacy records appear as ordinary image assets.

## Consequences

- `src/ocr/TextHistory.tsx`, the lane imports in `LibraryWindow`, and backend
  `import_ocr`, `import_qr`, `update_ocr_text`, QR crop and
  `favorite`/`unfavorite` actions are removed.
- OCR and QR copy/open actions remain explicit; recognition never mutates the
  library, so a canceled capture or closed dialog cannot publish late state.
- This supersedes the destination and persistence decisions in ADRs 0030, 0055,
  0061, 0064 and 0098. Marker geometry and clipboard/link handoff decisions in
  ADRs 0063 and 0068 still apply.

## Verification

Unit and renderer tests cover the single-result OCR dialog, QR copy/open
actions, removed command registration and legacy asset decoding. Manual checks
confirm the sidebar contains only Library, Trash and Settings, that OCR from
capture, library, viewer and editor still copies text, and that QR recognition
still opens links without adding library records.

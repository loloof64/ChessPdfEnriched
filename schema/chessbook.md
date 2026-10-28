# `.chessbook` format, schema version 1

A `.chessbook` is a zip archive. The pipeline writes everything except `corrections.json`;
the reader writes only `corrections.json` and never modifies generated data.

```
book.chessbook
  manifest.json
  pages/p0042.json        one file per page, 4-digit zero-padded page number
  diagrams/p42_d1.png     cropped diagram images
  scans/p0042.png         original page images (optional, facsimile mode)
  corrections.json        manual corrections (reader-owned)
```

Re-running the pipeline replaces `pages/` and `diagrams/` and keeps `corrections.json`.

## IDs

Stable and derived from the page number and the order on the page (top to bottom, left to right):
diagram `p42_d1`, move `p42_m7`, text block `p42_t3`.

## manifest.json

```json
{
  "schema_version": 1,
  "title": "Book title",
  "language": "fr",
  "figurine_notation": false,
  "page_count": 312,
  "has_scans": false
}
```

`language` is `"fr"` or `"en"`, chosen by the user before processing.

## pages/pNNNN.json

All boxes are `[x, y, w, h]` in page-image pixels. `width`/`height` give the page-image size.

```json
{
  "page": 42,
  "width": 1654,
  "height": 2339,
  "blocks": [
    { "id": "p42_t1", "bbox": [120, 200, 900, 60], "text": "Après 12.Cf3 ...",
      "moves": ["p42_m1", "p42_m2"] }
  ],
  "moves": [
    { "id": "p42_m1", "block": "p42_t1", "span": [6, 10], "raw": "Cf3",
      "san": "Nf3", "fen": "<FEN after the move>", "ok": true,
      "after_diagram": "p42_d1", "variation_depth": 0 }
  ],
  "diagrams": [
    { "id": "p42_d1", "bbox": [300, 900, 400, 400], "image": "diagrams/p42_d1.png",
      "fen": "<placement + side to move>", "confidence": 0.93, "reviewed": false }
  ]
}
```

- `span` is the `[start, end)` character range of the move inside the block `text`, so the reader can make it clickable.
- `san` is always English SAN (French letters already converted). `ok: false` means the move was
  illegal from the last known position (probable OCR error); `san` and `fen` are then `null`.
- `variation_depth` is the nesting level of parentheses (0 = main line).
- `confidence` is in `[0, 1]`.

## corrections.json

```json
{
  "schema_version": 1,
  "corrections": [
    { "target": "p42_d1", "type": "diagram_fen", "value": "<FEN>",
      "source_hash": "sha256:...", "needs_review": false }
  ]
}
```

- `type` is one of `diagram_fen`, `move_san`, `ignore` (`value` is omitted for `ignore`).
- `source_hash` is the SHA-256 of the original generated value (the diagram `fen`, or the move `raw`).
- After a re-run, a correction whose `target` is missing or whose `source_hash` no longer matches the
  regenerated value gets `needs_review: true`. It is never applied silently and never deleted.

## Safe saving

The reader extracts the archive into a work folder, rewrites the zip to a temporary file next to
the original, then atomically renames it over the original.

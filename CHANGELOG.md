# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow the tag (`X.Y.Z`) and `pubspec.yaml`.

To release: move the items of `Unreleased` under a new `## [X.Y.Z] - date` heading, bump `version:` in `pubspec.yaml`,
commit, then push the tag `X.Y.Z`. The release workflow publishes that section as the release notes and fails if it is missing.

## [Unreleased]

### Pipeline
- Diagrams: the double reading now triggers below 0.99 confidence (was 0.975), except on images with arrows or highlights, where the
  base model invents pieces. Fixes the remaining phantom bishops and queens of the coloured-print book.
- GUI: the overall progress is shown as "step N of M" with the elapsed time, instead of a percentage bar based on guessed step durations.
- Diagrams: when the GPU is full (the OCR model keeps most of it), the diagram models load on the CPU instead of failing with "CUDA out of memory".

## [0.1.1] - 2026-11-18

### Pipeline
- Diagrams: double reading. When the fine-tuned model is unsure (mean confidence < 0.975) the original fenify model reads too and wins if
  it is more confident and plausible. Fixes books printed in another style (hatched squares were read as queens). Run
  `fetch_weights.py` again to get `fenify-base.pt`; without it nothing changes.
- Moves: text glued by the OCR (`e62.d4`), a dropped `]`, bare Black moves in prose and `e5.h3` no longer break the replay.

## [0.1.0] - 2026-11-17

First release.

### Pipeline (PDF → `.chessbook`)
- OCR of scanned pages (PaddleOCR-VL) or text layer of born-digital PDFs; moves are read in French or English notation
  and replayed with python-chess, so every clickable move is legal (variations, several games per page, ambiguous moves handled).
- Chessboard diagrams are located, cropped and read with a fine-tuned fenify model; orientation and side to move are detected,
  and the crop is checked against the positions of the game.
- Two entry points: graphical (`make_chessbook_gui.py`, remembers folders and language) and command line (`make_chessbook_cli.py`).
- `cuda` and `cpu` install profiles (`setup_venv.sh`); `fetch_weights.py` downloads the diagram weights (SHA-256 checked).

### Reader (Flutter)
- Opens a `.chessbook`: original page with clickable moves and diagrams, or reconstructed text; board with last-move arrow,
  zoom presets, page navigation, board flip, UCI export.
- Diagram editor; corrections are kept across rebuilds (`corrections.json`).

### Known limits
- Figurine notation is not supported.
- The diagram model can still invent a piece (for example under arrows or highlights).
- The `cpu` profile is untested.

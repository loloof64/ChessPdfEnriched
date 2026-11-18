# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow the tag (`X.Y.Z`) and `pubspec.yaml`.

To release: move the items of `Unreleased` under a new `## [X.Y.Z] - date` heading, bump `version:` in `pubspec.yaml`,
commit, then push the tag `X.Y.Z`. The release workflow publishes that section as the release notes and fails if it is missing.

## [Unreleased]

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

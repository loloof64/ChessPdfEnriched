# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow the tag (`X.Y.Z`) and `pubspec.yaml`.

To release: move the items of `Unreleased` under a new `## [X.Y.Z] - date` heading, bump `version:` in `pubspec.yaml`,
commit, then push the tag `X.Y.Z`. The release workflow publishes that section as the release notes and fails if it is missing.

## [Unreleased]

### Interface
- Interface languages: English, French and Spanish in the reader and in the graphical front end. They follow the system language
  (English when it is none of the three); a language menu allows a manual choice (Automatic, English, Français, Español), remembered
  between runs and applied at once. The Spanish texts have not been reviewed by a Spanish speaker yet.

### Pipeline
- Diagrams: the double reading now triggers below 0.99 confidence (was 0.975), except on images with arrows or highlights, where the
  base model invents pieces. Fixes the remaining phantom bishops and queens of the coloured-print book.
- GUI: the overall progress is shown as "step N of M" with the elapsed time, instead of a percentage bar based on guessed step durations.
- Moves: a prose word glued to a move by the OCR (`14.Ce2Opération`) no longer hides the move; a numbered move that is illegal because the
  OCR dropped or changed one letter (`Cf7` for `Cfd7`) is repaired when exactly one legal move fits and the following moves prove it.
- Diagrams: when both models place the same pieces on the same squares and differ only in colours, the fine-tuned reading is kept.
- Moves: a move the book omits (`31...Cc8` without White's 31st) is recovered when exactly one legal move makes the rest of the line legal; a glued word with an elision (`36.hxg6L'ouverture`), a promotion written without `=` (`gxf8D+`), a bare pawn move followed by its own variation (`b4 ( 19...bxa4 … )`) and a `]` closed too early followed by a stray `]` are now read correctly.
- Pages: a text block the main OCR cut short (a column reduced to its first sentence) is refilled from the classic OCR text inside its box.
- Diagrams: when both kings are clearly nearer to the pawns of the other colour, their colours are swapped (the readers mix them up on small prints).
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

# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow the tag (`X.Y.Z`) and `pubspec.yaml`.

To release: move the items of `Unreleased` under a new `## [X.Y.Z] - date` heading, bump `version:` in `pubspec.yaml`,
commit, then push the tag `X.Y.Z`. The release workflow publishes that section as the release notes and fails if it is missing.

## [Unreleased]

### Reader
- The board next to the page shows its coordinates (a-h, 1-8).

### Pipeline
- Moves: start positions are scored with the variations too (two diagrams often allow the same main line); an unbracketed alternative (`Si 3.Rh6 ...`) is a variation the book may leave for the main line again, also inside a bracket; a move mentioned again right after being played is no error; an omitted move is recovered also when several candidates lead to the same position.
- Diagrams: the orientation is read from the printed coordinates (digits 8..1 and letters a..h read by the classic OCR) when they are there, instead of guessing which army is at the bottom; the guess turned 29 of 42 diagrams of an endgame book (White's king and queen above Black's pawn) upside down.
- Diagrams: the colours of the two kings are checked against the image (black pieces are filled, white ones outlined) when it splits cleanly; the king-colour heuristic no longer overrides a right reading (it swapped the kings of a position where both stand next to the enemy pawns).
- Moves: a bare pawn move after commentary (`…Blanches. g6 16.axb5`) is read as Black's reply when the next White move is legal after it; in the middle of a page the game only restarts from another position when at least 3 moves are legal there.
- Moves: a glued word with a single lowercase letter (`Fe6En échangeant…`) no longer hides the move before it.
- Pages: a block the OCR labelled `figure_title` or `vision_footnote` that holds numbered moves is book text (a column of moves was ignored), and a block with fewer moves than the classic OCR reads in its box takes the classic text.
- Moves: a move the book omits is now recovered before any other start position is tried; before, a page could restart from a wrong diagram position where the next moves happened to be legal, which turned later correct moves red.
- Pages: near-duplicate passages repeated by the OCR with typos (`Poursoit`/`Poursuit`) are removed, so their moves are not read twice. Diagrams: when a page has to start from a diagram, every plausible reading of it (neighbouring crops, both models) is offered and the page's own moves decide (the autocrop can be a cell off).
- GUI: no more `…` character on the buttons and texts (three plain dots).

## [0.2.0] - 2026-11-18

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
- Pages: a line of moves the main OCR gave no block at all (e.g. `31.g4` printed above a diagram) is added from the classic OCR, in reading order,
  so the move is read and clickable. The classic OCR now runs while the pages are read (same total time, results cached).
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

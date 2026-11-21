# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow the tag (`X.Y.Z`) and `pubspec.yaml`.

To release: move the items of `Unreleased` under a new `## [X.Y.Z] - date` heading, bump `version:` in `pubspec.yaml`,
commit, then push the tag `X.Y.Z`. The release workflow publishes that section as the release notes and fails if it is missing.

## [Unreleased]

### Conversion

- Diagram reader: new fine-tuned weights (release `weights-2`, `finetune_real.py`: real diagrams labelled by the games). Hatched boards with white pieces on the first rank are read far better (T4 of Est-Indienne). `fetch_weights.py` downloads them.
- Diagrams: a hatched diagram is also read by the base model with the hatching flattened; an implausible or unsure reading is snapped to the nearest position of the book's games (within 4 squares, and 2 nearer than any other).
- Moves: a move that does not fit a bracket stays in it while a `]` follows; a misread previous move is corrected one edit away when the next numbered move needs it; a dropped disambiguation letter is repaired at the end of a variation; a `)` does not reopen the variation it closes.
- Moves: a footer block holding a numbered move (`27...Cd7`) is text; a figure cut in 4 by dashed lines is not a board.
- Diagram readers: when the OCR model leaves no GPU memory, the small nets move to the CPU instead of failing.
- Side to move: the dot search no longer reaches the next column (its pieces were counted as a second dot).
- Moves: a `;` sibling is no longer taken for a forgotten `]` (`; B) 1...f1C+` stays in its variation); an OCR comma before a `B)` label counts as the `;`; a move the diagram already shows ('Les Noirs viennent de jouer 44...Fe8') is a mention, so a misread of that diagram no longer wins over the exact one.
- Moves: `A)` / `B)` labels of alternatives are not closing parentheses; a sibling after `;` restarts from its own move number;
  a bare move that is an alternative to the previous one (`4.Kd6 Ke6 (...) d3`) is a variation, and the main line resumes after the comment.
- Moves: a new exercise whose first move was also legal before the last move of the previous one (`1.Da3#` then `1.Bd5+`) restarts from its own diagram
  when the other reading dies at once.
- Moves: a page that begins with a variation of the previous page's last move (`[19...Ff6!?] 20.exf5`) starts from the position after that move.
- Moves: a bare Black capture followed by a comment that mentions another move of that number (`dxe4 ... contrairement à 12...e5. [12...0-0? ...]`) is kept;
  `1..Te8` (two dots) is not a move number; a stray `]` goes with the last `]` before it, not with a `)`.
- Diagrams: a board the OCR labels `seal` is read like any other diagram (the first diagram of page 9 of Calcul de variantes 1 was missing).

## [0.2.1] - 2026-11-18

Mostly fixes found by reading more books (diagram orientation, side to move, moves lost or marked illegal). Books made with an earlier version keep their old readings: make them again to get the fixes.

### Reader
- The board next to the page shows its coordinates (a-h, 1-8).

### Pipeline
- Diagrams: the side to move read from the printed dot is now read against the army at the bottom of the diagram (the dot sits at the edge of the side to move); it was inverted for every diagram printed with White at the bottom, and it now wins over a match with a game of the book (which can be a coincidence).
- Moves: a bracketed variation written after the opponent's reply (`13.Rg4! h3 [13.Rg2?? …]`) varies the earlier move it names; a bare promotion written without `=` (`a1D`) is a move.
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

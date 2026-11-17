# ChessPdfEnriched

Read scanned chess books as interactive books: moves and diagrams are clickable, and a click shows the position on a board.

Two programs:

| Program | Folder | Role |
|---|---|---|
| **Pipeline** (Python) | `pipeline/` | turns a PDF into a `.chessbook` file (OCR, diagrams, moves) |
| **Reader** (Flutter) | repository root, `lib/` | opens a `.chessbook`: text, clickable moves, board, diagram correction |

The `.chessbook` format is described in [schema/chessbook.md](schema/chessbook.md). Detailed progress notes (measurements,
limits, pitfalls) are in [pipeline/NEXT_SESSION.md](pipeline/NEXT_SESSION.md) (in French).

Tagged releases (`X.Y.Z`) on GitHub provide the reader for Windows (x64 zip) and Linux (x64 AppImage), and a zip of the pipeline
(Python scripts and the dependency files needed to build its venv).

## 1. Pipeline: generate a `.chessbook` from a PDF

### Requirements

- Linux (tested on Ubuntu 26.04).
- [`uv`](https://docs.astral.sh/uv/getting-started/installation/) (Python venv and dependency manager).
- `poppler-utils`: `sudo apt install poppler-utils` (provides `pdftoppm` and `pdftotext`).
- A GPU is optional but strongly recommended for scanned books. Two install profiles exist:
  - **`cuda`**: NVIDIA GPU with a recent driver (CUDA 12.6 wheels of PyTorch and Paddle; an RTX 3060 12 GB is enough). This is
    the tested configuration.
  - **`cpu`**: any other machine (no NVIDIA GPU, or no GPU at all). **Not tested yet**: the diagram reader falls back to the CPU by
    itself, but the OCR of scanned pages (PaddleOCR-VL, 0.9B parameters) will be much slower; PDFs with a text layer avoid most of it.

### Install the venv

```bash
cd pipeline
./setup_venv.sh            # picks cuda when nvidia-smi finds a GPU, cpu otherwise
./setup_venv.sh --cpu      # or force a profile: --cuda / --cpu
```

The script checks `uv` and poppler, then runs `uv sync --extra <profile>`: it creates `pipeline/.venv` (Python 3.13) and installs
every dependency declared in `pyproject.toml` (PyTorch, Paddle/PaddleOCR-VL, python-chess, OpenCV, scikit-learn, etc.). The first
run downloads several GB, and the first OCR run also downloads its model. Without the script, always pass a profile:
`uv sync --extra cuda` or `uv sync --extra cpu` (a bare `uv sync` installs neither PyTorch nor Paddle).

Without `uv`: `python3.13 -m venv .venv`, then install PyTorch and Paddle by hand (`--index-url https://download.pytorch.org/whl/cu126`
and the Paddle CUDA 12.6 index, or the CPU builds) and `pip install -e .` for the rest. This path is untested.

### Diagram weights

Diagram reading uses a [fenify](https://github.com/notnil/fenify) model (MIT license) fine-tuned on synthetic boards. The file
`pipeline/work/fenify-ft.pt` is **not** in git (127 MB, the `work/` folder is ignored). To get it on a new machine:

1. either copy `pipeline/work/fenify-ft.pt` from a machine that has it;
2. or regenerate it: download the base weights `fenify-gpu.pt` (release `v2023-07-10` of notnil/fenify) into `pipeline/work/`, then
   follow "Régénérer `work/fenify-ft.pt`" in [pipeline/NEXT_SESSION.md](pipeline/NEXT_SESSION.md) (`finetune.py`, about 10 minutes on a GPU).

The program stops immediately, before any OCR, if the file is missing (option `--weights` for another path).

### Run

Graphical interface (pick the PDF, pick the output file, start, progress bars with elapsed time):

```bash
cd pipeline
.venv/bin/python make_chessbook_gui.py
```

Or the command line:

```bash
cd pipeline
.venv/bin/python make_chessbook_cli.py ~/Documents/Echecs/Ebooks/DeFabrice/attaque_minorite_1.pdf --lang fr -o attaque.chessbook
```

| Option | Role |
|---|---|
| `--lang fr` or `en` | move notation printed in the book: `fr` = C F T D R (Cavalier, Fou, Tour, Dame, Roi), `en` = N B R Q K |
| `-o file.chessbook` | output file (default: `<pdf name>.chessbook` in the current folder) |
| `--pages 1-40` or `3,5,8-10` | only process these pages (PDF page numbers; default: all) |
| `--title "Title"` | displayed title (default: the PDF title, else the file name) |
| `--dpi 200` | page rendering resolution |
| `--no-scans` | do not embed the page images (smaller file, no facsimile) |
| `--work folder` | cache folder (default: `pipeline/work/<pdf name>/`) |
| `--weights file.pt` | diagram reader weights |
| `--progress-lines` | machine-readable progress lines (used by the graphical interface) |

For each page, the program:

1. renders the page as an image; reads the text from the PDF text layer when there is one (at least 60 words), otherwise runs the
   OCR with PaddleOCR-VL (about one minute per page on an RTX 3060);
2. cleans known OCR defects: empty text blocks, passages repeated in the neighbouring block, text blocks returned as HTML tables;
3. finds the images and reads the position of those that are boards (fenify). A reading that is not confident or not plausible
   (no king, pawns on the back rank...) triggers a finer search for the board's crop, including larger sizes. The reading is
   compared with the game of the page (`matches_move` in the file: a good check of the reading);
3b. locates every move on the page image (for the facsimile): with the word boxes of the PDF when it has a text layer, otherwise with
   a second OCR (PP-OCRv5, word boxes) whose text is aligned character by character with the main model's;
4. reads the moves, converts them to English notation and replays them with python-chess. Variations written `[ ... ]` or `( ... )`
   start from the position before the last move. An illegal move is a probable OCR error: it is marked `ok: false` (red in the
   reader) and the line stops there. A move without a number is only believed as a Black reply; anything else is prose;
5. chooses where a passage starts from: the initial position, a position of another page's game (a page that does not begin at
   move 1), or, in exercise-style books, the position of a nearby diagram (the one after which the next moves are legal).

A summary per page is printed at the end: number of moves, of illegal moves, of diagrams read and confirmed by the game, and the total time.

**Speed**: the board search is cached in memory and in `work/<pdf>/autocrop/`, so a re-run of a book does not repeat it.

**Resuming**: slow steps (rendering, OCR) are kept in the cache folder. If the program is interrupted, running the same command
resumes where it stopped. To redo the OCR of a page, delete `work/<pdf>/blocks/p<N>.json`.

**Corrections**: running the program again on an already generated book replaces everything except `corrections.json`, the file where
the reader stores your diagram corrections. A correction is only applied if the generated diagram is unchanged; otherwise it is
flagged "to review".

### Known limits

- **Figurine notation (♘f3) is not handled** by `make_chessbook_cli.py`. Experiments exist (`figurines.py`, `inline.py`,
  `legality.py`) but they are not integrated; see `pipeline/NEXT_SESSION.md`.
- Diagram reading is **not 100 % reliable**: a black pawn under a highlighted square was once read as a queen with 98.7 % confidence.
  Check diagrams by eye and correct them in the reader (right click).
- Diagrams are only read if they are roughly square and look like a board; small screenshot boards are sometimes badly cropped
  (shown by the absence of `matches_move`).
- Descriptive notation of old books, two columns of moves in a table, etc.: not handled.
- Module tests are self-checks: `.venv/bin/python legality.py`, `orientation.py`, `plausibility.py`.

## 2. Flutter reader

Requirements: Flutter 3.47.x on Linux (`flutter doctor`) and `zenity` for the file-open dialog.
**Do not move to Flutter 3.50** for now: on this setup the Linux window is displayed shifted and cropped there.

```bash
flutter pub get
flutter run -d linux
```

- **Open a book**: "Ouvrir un livre" button (or the folder icon at the top) and choose a `.chessbook` file. You can also pass the
  path: `flutter run -d linux --dart-entrypoint-args path.chessbook`, or the `CHESSBOOK=path.chessbook` variable.
- **Read**: by default the **facsimile**: the original page as is (the PDF image), with clickable zones on the moves and the
  diagrams. Clicking a move shows the position, with the last-move arrow and its number (`3. Cf3`, `2... d5`). A move circled in
  red is illegal. The page/image icon in the top bar switches to the **rebuilt text** (text blocks laid out again, useful if the
  book has no page images, option `--no-scans`).
- **Pages**: previous and next buttons, or type a number in the field and confirm.
- **Zoom**: − and + buttons, or the menu in the middle: "Page entière" (whole page visible), "Largeur de page", or a percentage
  (100 % = real page size; beyond the pane width the page also scrolls horizontally).
- **Board**: the "Retourner l'échiquier" button flips the view.
- **Correct a diagram**: right click on the diagram, or the "Corriger ce diagramme" button after selecting it. Drag a piece from the
  palette onto a square, drag it off the board to remove it, then save. The correction is written to `corrections.json` inside the `.chessbook`.

Tests: `flutter test` (the corrections-saving test needs a generated book in `pipeline/work/fab/` and is skipped otherwise).

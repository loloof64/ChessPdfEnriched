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

### Interface languages

Both programs speak English, French and Spanish. They follow the system language (English when it is another one), and a language
menu (globe icon in the reader, "Interface language" in the graphical front end) lets you choose: Automatic, English, Français,
Español. The choice is remembered (reader: the platform's preferences; front end: `pipeline/work/gui_settings.json`) and applies at
once. It is independent of the language of a book's move notation (`--lang`, "Book move notation").

## 1. Pipeline: generate a `.chessbook` from a PDF

### Requirements

- Linux (tested on Ubuntu 26.04).
- [`uv`](https://docs.astral.sh/uv/getting-started/installation/) (Python venv and dependency manager). It is not in the Ubuntu
  repositories (`apt install uv` does not work): install it with `curl -LsSf https://astral.sh/uv/install.sh | sh` (or `pipx install uv`).
- `poppler-utils`: `sudo apt install poppler-utils` (provides `pdftoppm` and `pdftotext`).
- A GPU is optional but strongly recommended for scanned books. Two install profiles exist:
  - **`cuda`**: NVIDIA GPU with a recent driver (CUDA 12.6 wheels of PyTorch and Paddle; an RTX 3060 12 GB is enough). This is
    the tested configuration.
  - **`cpu`**: any other machine (no NVIDIA GPU, or no GPU at all). **Not tested yet**: the diagram reader falls back to the CPU by
    itself, but the OCR of scanned pages (PaddleOCR-VL, 0.9B parameters) will be much slower; PDFs with a text layer avoid most of it.

Disk space and download (sizes of the locked wheels for Linux x86-64; "on disk" for `cuda` is measured, for `cpu` it is an estimate):

| | Download | On disk (`pipeline/.venv`) |
|---|---|---|
| `cuda` | about 5 GB (Paddle GPU 2 GB, PyTorch 0.8 GB, NVIDIA libraries about 2 GB) | about 8.5 GB |
| `cpu` | about 0.6 GB | about 1.5 GB (estimate) |

Add to either profile: about 2 GB of OCR models downloaded at the first OCR run (`~/.paddlex`) and 122 MB for the diagram weights.
`uv` also keeps its own cache in `~/.cache/uv`, which grows with every version installed: `uv cache prune` removes what is unused.

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

The program reads chessboard diagrams with two neural networks, both in `pipeline/work/` (not in git, so on a new machine you must
download them): **`fenify-ft.pt`** (127 MB, required) and **`fenify-base.pt`** (122 MB, optional). The program stops immediately, before
any OCR, if the first is missing. One command downloads both (it checks the SHA-256 and never overwrites an existing file):

```bash
cd pipeline
.venv/bin/python fetch_weights.py          # fenify-ft.pt and fenify-base.pt
.venv/bin/python fetch_weights.py --base   # only fenify-base.pt (see below)
```

- **Fine-tuned weights** (`fenify-ft.pt`, release `weights-3` of this repository): the original model fine-tuned on synthetic boards, then on
  real diagrams of generated books whose position was confirmed by the game (`finetune_real.py`, which also lists hand-checked ones). Best on
  highlighted squares, arrows and hatched boards. Rebuilding them needs the generated `.chessbook` files, which are not in the repository.
- **Original fenify model** (`fenify-base.pt`, [notnil/fenify](https://github.com/notnil/fenify), MIT license, downloaded from its own
  release): reads clean diagrams as well as the fine-tuned one, and other print styles better (hatched squares, coloured boards), but
  it sometimes sees "ghost" pieces on highlighted squares or under arrows.
- **Double reading**: when the fine-tuned reading has a mean confidence below 0.99 and the image has no arrows or highlights, the base model reads the diagram too and its
  reading is kept if it is more confident and plausible. Without `fenify-base.pt` only the fine-tuned model is used. To use the base
  model alone: `--weights work/fenify-base.pt`.

Other files can be selected with `--weights path.pt` and `--base-weights path.pt`.

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
| `--weights file.pt` | diagram reader weights (fine-tuned) |
| `--base-weights file.pt` | original fenify weights for the double reading (default `work/fenify-base.pt`, optional) |
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

- **Open a book**: "Open a book" button (or the folder icon at the top) and choose a `.chessbook` file. You can also pass the
  path: `flutter run -d linux --dart-entrypoint-args path.chessbook`, or the `CHESSBOOK=path.chessbook` variable.
- **Read**: by default the **facsimile**: the original page as is (the PDF image), with clickable zones on the moves and the
  diagrams. Clicking a move shows the position, with the last-move arrow and its number (`3. Cf3`, `2... d5`). A move circled in
  red is illegal. The page/image icon in the top bar switches to the **rebuilt text** (text blocks laid out again, useful if the
  book has no page images, option `--no-scans`).
- **Pages**: previous and next buttons, or type a number in the field and confirm.
- **Zoom**: − and + buttons, or the menu in the middle: "Whole page", "Page width", or a percentage
  (100 % = real page size; beyond the pane width the page also scrolls horizontally).
- **Board**: the "Flip the board" button flips the view.
- **Correct a diagram**: right click on the diagram, or the "Correct this diagram" button after selecting it. Drag a piece from the
  palette onto a square, drag it off the board to remove it, then save. The correction is written to `corrections.json` inside the `.chessbook`.

Tests: `flutter test` (the corrections-saving test needs a generated book in `pipeline/work/fab/` and is skipped otherwise).

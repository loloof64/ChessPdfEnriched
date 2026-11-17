# Project: interactive reader for scanned chess books

## Goal
Turn scanned chess books (PDF) into interactive books: diagrams and moves are clickable, and a click
shows the matching position on a static board.

## Decisions made
- **Language**: French or English depending on the book. Chosen in the interface BEFORE processing
  (a pipeline parameter, no move-by-move detection). A "figurine" option (♘f3) comes on top.
- **Free models (Hugging Face)**: a specialised OCR model for text and layout
  (PaddleOCR-VL-1.6, 0.9B, Apache-2.0; alternatives GLM-OCR, DeepSeek-OCR), and a diagram reading model
  producing the FEN (fenify / Galatea board reader, MIT, TorchScript CPU, 300x300 input).
  Quality on diagrams from scanned books NOT tested: plan a test set.
- **Two programs** (the repository root is the Flutter project, the reader):
  - `pipeline/` (Python, subfolder): OCR with positions, diagram cropping, FEN, move detection and
    validation (python-chess), `.chessbook` export. Entry points: `make_chessbook_gui.py` (graphical) and
    `make_chessbook_cli.py` (command line).
  - repository root (Flutter/Dart, `lib/`): the reader. No OCR. Targets: desktop (Linux first, Windows/macOS
    possible), no Web.
  - `schema/`: description of the format, shared by both.
- **Flutter board**: `chessground` package (lichess, GPL-3.0, `StaticChessboard` for read-only display,
  position editor included) + `dartchess` for the logic. Check the licenses before distributing.

## Move detection
- SAN regex per language. French: C, F, T, D, R converted to N, B, R, Q, K before replay.
  English: no conversion. Figurine notation: symbol replacement.
- Descriptive notation of old books: separate conversion (later).
- OCR confusion rules specific to each language (l/1, O/0, B/8, e/c...).
- Replay with a rules engine: an illegal move = probable OCR error, reported without crashing.
- Context: a diagram fixes the starting position; numbered moves are replayed from the last known
  position; variations in brackets or parentheses form a stack.

## `.chessbook` format (zip archive)
```
book.chessbook
  manifest.json       language, title, schema version
  pages/              generated data (text blocks, moves with SAN + resulting FEN + ok,
                      diagrams with bbox, image, FEN, confidence, reviewed)
  diagrams/           cropped image of each diagram (e.g. p42_1.png)
  scans/              original pages (optional, facsimile mode)
  corrections.json    manual corrections, the ONLY file written by the reader
```
- Stable identifiers (e.g. `p42_d1`, `p42_m7`).
- Correction types: `diagram_fen`, `move_san`, `ignore`. Each correction keeps a `source_hash` of the
  original value; if the hash changes after reprocessing, the correction is flagged "to review"
  (never applied silently, never lost).
- Running the pipeline again replaces `pages/` and `diagrams/` but keeps `corrections.json`.
- Safe saving: extraction into a working folder, rewrite of the zip to a temporary file, then replacement.
- The reader never modifies the generated data.

## Reader interface
- Book text on one side, fixed board on the other; click on a move or a diagram = position.
- Right click: edit a diagram (position editor) or a move (text field).
- "To review" list: uncertain diagrams, illegal moves, orphan corrections.

## Environment (checked on Ubuntu)
- OS: Ubuntu 26.04 LTS. Main reader platform: Linux desktop.
- GPU: NVIDIA GeForce RTX 3060, 12 GB of VRAM, driver 580.178.04 (CUDA 13.0), ~239 MB used at idle.
- PyTorch ships its own CUDA runtime: no separate CUDA Toolkit needed. Driver 580 is plenty
  (the Paddle CUDA 12.6 wheels require a driver >= 550.54.14).
- Flutter 3.47.x (stable): `flutter doctor` without problems (Linux desktop toolchain OK).
- System Python: 3.14.4. Do NOT use it for the pipeline (see below).

## Pipeline Python environment: Python 3.13 in a virtual environment
- Reason: PaddleOCR / PaddleOCR-VL officially documents Python 3.8 to 3.13. Python 3.14 support is
  not confirmed (in particular the `paddlepaddle-gpu` wheels), and some GPU ecosystem dependencies
  have no cp314 wheels yet. PyTorch 2.9/2.10 support 3.14, but the bottleneck is Paddle.
- Create a dedicated Python 3.13 venv in `pipeline/` (`.venv`), without touching the system
  Python 3.14. Recommended tool: `uv`, which installs 3.13 next to the system one if needed.
- Pin the version in the project (`pipeline/.python-version` and `requires-python = ">=3.13,<3.14"`
  in `pyproject.toml`) so the environment is reproducible.
- Two install profiles (`pipeline/setup_venv.sh` picks one): `cuda` (NVIDIA GPU, CUDA 12.6 wheels of
  PyTorch and Paddle; the tested one) and `cpu` (any other machine; untested, slower OCR).
- Always activate this venv (or use `uv run`) before installing or running anything in `pipeline/`.
  Never run `pip install` outside the venv.
- Check every import and GPU detection (`torch.cuda.is_available()`, `paddle.device.is_compiled_with_cuda()`)
  before going further.
- Likely system dependency: `poppler-utils` (apt) to read PDFs.
- If Paddle misbehaves under 3.13, fallback: Python 3.12.

## First steps
1. Check the machine: GPU, Flutter (already OK, see above), `poppler-utils`.
1b. Create the Python 3.13 pipeline venv and validate the imports and the GPU.
2. Initialise `pipeline/` and `schema/` (the Flutter reader is at the root) and write the format schema.
3. End-to-end test on ONE page: OCR with positions, diagram cropping, FEN, display on a board.
4. Measure diagram reading reliability on positions with known FENs.
5. Then build the complete interface and the corrections system.

## To be provided by the user
- 5 to 10 representative scanned pages (diagrams, running text, variations), and the language of each book.
- A few diagrams whose exact FEN is known.

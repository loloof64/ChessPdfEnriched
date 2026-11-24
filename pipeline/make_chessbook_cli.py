#!/usr/bin/env python
"""Generate a .chessbook (schema/chessbook.md) from a chess-book PDF.

    .venv/bin/python make_chessbook_cli.py livre.pdf --lang fr -o livre.chessbook [--pages 1-40] [--title "..."]

Per page: render it; read the text from the PDF text layer when there is one, otherwise run PaddleOCR-VL; find the
diagrams, read their position (fenify) and check it against the game; read the moves and replay them with python-chess.
Slow steps are cached in a work folder (default work/<pdf name>/), so a run can be interrupted and resumed: delete a
file there to redo that step. An existing output file is replaced but its corrections.json (written by the reader) is kept.
Not supported yet: figurine notation (see figurines.py / inline.py spikes in NEXT_SESSION.md).
"""
import argparse
import ctypes
import html
import json
import re
import subprocess
import sys
import time
import zipfile
from collections import Counter
from pathlib import Path

import chess
import cv2
import numpy as np
import pypdfium2 as pdfium
import pypdfium2.raw as pdfium_c
from PIL import Image

import autocrop
from autocrop import candidate_boxes, find_board
from export_chessbook import FIGURE, KEEP, column_order, joined_text, page_data, text_blocks
from moves import replay, tokens
from trait import dot_turn
from wordboxes import Classic, add_orphans, coordinate_flip, fill_moves, fill_sparse, move_rects_ocr, move_rects_textlayer
from orientation import orient
from plausibility import add_missing_king, colors_only_differ, issues, repair_king_colors

MAX_EMBEDDED_PX = 40_000_000  # an embedded image bigger than this (width x height) is not extracted: PDFs can be hostile
MAX_EMBEDDED_PER_PAGE = 60
Image.MAX_IMAGE_PIXELS = 100_000_000  # explicit PIL limit (it raises above twice this) for rendered pages and extracted images
CONFIDENT = 0.95  # mean per-square probability above which a diagram reading is not second-guessed by a finer crop search
TRUSTED = 0.99  # fine-tuned reading below this mean confidence is double-checked with the base model...
MAX_VIVID = 0.002  # ...unless the diagram has arrows/highlights (share of bright saturated pixels): the fine-tuned model is trained for them, the base invents pieces there
MISSED_BOARD_SCORE = 2.0  # same score, for a picture that is only a candidate (missed_boards)
MIN_BOARD_SCORE = 2.5  # autocrop checkerboard score: logos < 1, small screenshot boards 3-5, real diagrams 6+
HERE = Path(__file__).parent
T0 = time.time()  # program start, for the total time
MACHINE = False  # --progress-lines: progress as '@@PROGRESS<TAB>label<TAB>i<TAB>n<TAB>note' lines (read by make_chessbook_gui.py)


def mmss(seconds):
    return f"{int(seconds) // 60:02d}:{int(seconds) % 60:02d}"


class bar:
    """Iterate over items while drawing a one-line progress bar on stderr. `note(text)` adds what is being done inside the current
    item (e.g. which diagram); on a terminal the line is redrawn, otherwise one plain line is printed per item."""
    def __init__(self, items, label, width=30):
        self.items, self.label, self.width, self.i, self.t0, self.tty = list(items), label, width, 0, time.time(), sys.stderr.isatty()

    def note(self, text=""):
        if MACHINE:
            print(f"@@PROGRESS\t{self.label}\t{self.i}\t{len(self.items)}\t{text}", file=sys.stderr, flush=True)
            return
        k = self.width * self.i // max(1, len(self.items))
        line = f"{self.label:<22}[{'#' * k}{'.' * (self.width - k)}] {self.i}/{len(self.items)} {mmss(time.time() - self.t0)} {text}"
        if self.tty:
            print("\r\033[K" + line, end="", file=sys.stderr, flush=True)
        elif not text:
            print(line, file=sys.stderr, flush=True)

    def __iter__(self):
        for self.i, it in enumerate(self.items):
            self.note()
            yield it
        self.i = len(self.items)
        self.note()
        if self.tty:
            print(file=sys.stderr)


def page_numbers(spec, count):
    if not spec:
        return list(range(1, count + 1))
    out = []
    for part in spec.split(","):
        a, _, b = part.partition("-")
        out += range(int(a), int(b or a) + 1)
    return [n for n in out if 1 <= n <= count]


def render(pdf, n, dpi, work):
    png = work / "pages" / f"p{n}.png"
    if not png.exists():
        png.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["pdftoppm", "-r", str(dpi), "-f", str(n), "-l", str(n), "-png", "-singlefile", str(pdf), str(png.with_suffix(""))], check=True)
    return png


def text_layer_blocks(pdf, n, k):
    """OCR-style blocks from the PDF's own text (pdftotext -bbox-layout), boxes in px (k = px per point): ONE BLOCK PER LINE,
    because the text layer gives the exact box of every line, so the reader can reproduce the page's layout and font sizes
    (a paragraph block would force one size on lines that differ: titles, bold lead-ins).
    The output is a regular XHTML subset, read with regexes: no XML parser on data derived from an untrusted PDF."""
    xml = subprocess.check_output(["pdftotext", "-bbox-layout", "-f", str(n), "-l", str(n), str(pdf), "-"], text=True)
    out = []
    for m in re.finditer(r'<line xMin="([\d.]+)" yMin="([\d.]+)" xMax="([\d.]+)" yMax="([\d.]+)">(.*?)</line>', xml, re.S):
        words, pos = [], 0
        for wm in re.finditer(r'<word xMin="([\d.]+)" yMin="([\d.]+)" xMax="([\d.]+)" yMax="([\d.]+)">(.*?)</word>', m.group(5), re.S):
            wt = html.unescape(wm.group(5))
            words.append([pos, pos + len(wt)] + [float(v) * k for v in wm.groups()[:4]])
            pos += len(wt) + 1  # words are joined with one space
        text = " ".join(html.unescape(w) for w in re.findall(r"<word [^>]*>(.*?)</word>", m.group(5), re.S)).strip()
        if text:
            out.append({"block_label": "text", "block_content": text, "words": words,
                        "block_bbox": [round(float(v) * k) for v in m.groups()[:4]]})
    return out


def image_blocks(doc, n, k, work):
    """Embedded images of a text-layer page as figure blocks (page-sized backgrounds and duplicates dropped). The image itself
    is extracted from the PDF: a crop of the rendered page would also contain the page's text, drawn a second time by the reader."""
    page = doc[n - 1]
    w, h = page.get_size()
    found = []
    for o in page.get_objects(filter=[pdfium_c.FPDF_PAGEOBJ_IMAGE]):
        l, b, r, t = o.get_bounds()
        box = [round(l * k), round((h - t) * k), round(r * k), round((h - b) * k)]
        if (r - l) * (t - b) < .8 * w * h and box not in [f[0] for f in found]:
            found.append((box, o))
    found.sort(key=lambda f: (round(f[0][1] / 100), f[0][0]))  # top to bottom, then left to right
    out = []
    (work / "embedded").mkdir(parents=True, exist_ok=True)
    for i, (box, o) in enumerate(found[:MAX_EMBEDDED_PER_PAGE], 1):
        block = {"block_label": "image", "block_content": "", "block_bbox": box}
        w_px, h_px = o.get_px_size()  # native size, read BEFORE decoding the image
        if 0 < w_px * h_px <= MAX_EMBEDDED_PX:  # otherwise the figure is cropped from the page render (text included)
            path = work / "embedded" / f"p{n}_{i}.png"
            im = o.get_bitmap(render=True).to_pil()
            im.thumbnail((4000, 4000))
            im.save(path)
            block["image_file"] = str(path.relative_to(work))
        out.append(block)
    return out


def strip_text(doc, n, k):
    """Style of every text object of a text-layer page, then the page rendered WITHOUT its text (shapes, colours, images and
    borders stay): the reader draws that as the page background and the text on top, in the original colours.
    Returns ([(cx_pt, cy_pt, bold, "#rrggbb")], background PIL image). Modifies the in-memory page: call after reading its images."""
    page = doc[n - 1]
    h = page.get_size()[1]
    objs = list(page.get_objects(filter=[pdfium_c.FPDF_PAGEOBJ_TEXT]))
    info = []
    for o in objs[:20000]:  # bound the work on a hostile PDF
        l, b, r, t = o.get_bounds()
        try:
            name = o.get_font().get_base_name() or ""
        except Exception:
            name = ""
        rgba = [ctypes.c_uint(), ctypes.c_uint(), ctypes.c_uint(), ctypes.c_uint()]
        pdfium_c.FPDFPageObj_GetFillColor(o.raw, *[ctypes.byref(c) for c in rgba])
        info.append(((l + r) / 2, h - (b + t) / 2, bool(re.search(r"bold|black|heavy", name, re.I)), "#%02x%02x%02x" % tuple(c.value & 255 for c in rgba[:3])))
    for o in objs:
        page.remove_obj(o)
    page.gen_content()
    return info, page.render(scale=k).to_pil().convert("RGB")


def style_of(box, info, k):
    """{"bold", "color"} of the text objects whose centre lies inside the line box (px), or None."""
    x0, y0, x1, y1 = (v / k for v in box)
    inside = [(bold, col) for cx, cy, bold, col in info if x0 - 1 <= cx <= x1 + 1 and y0 - 1 <= cy <= y1 + 1]
    if not inside:
        return None
    (bold, col), _ = Counter(inside).most_common(1)[0]
    return {"bold": bold, "color": col}


class Ocr:
    """PaddleOCR-VL, loaded on first use (importing paddle takes a while)."""

    pipe = None

    def blocks(self, png):
        if Ocr.pipe is None:
            from paddleocr import PaddleOCRVL
            Ocr.pipe = PaddleOCRVL()
        return [r for res in Ocr.pipe.predict(str(png)) for r in res.json["res"]["parsing_res_list"]]

    def read_page(self, png):
        """Blocks of a scanned page; text blocks the OCR left EMPTY are re-read from a crop. The OCR then often already put
        that text at the end of the previous block: it is cut there, otherwise the moves would be read twice."""
        blocks = self.blocks(png)
        page = Image.open(png).convert("RGB")
        for b in blocks:
            if b["block_label"] != "text" or b["block_content"].strip():
                continue
            x0, y0, x1, y1 = b["block_bbox"]
            crop = png.with_name(f"{png.stem}_crop{x0}_{y0}.png")
            page.crop((max(0, x0 - 12), max(0, y0 - 12), x1 + 12, y1 + 12)).save(crop)
            b["block_content"] = " ".join(r["block_content"] for r in self.blocks(crop) if r["block_content"].strip())
            head = b["block_content"][:25]
            for o in blocks:
                i = o["block_content"].find(head) if o is not b and head else -1
                if i > 0:
                    o["block_content"] = o["block_content"][:i].rstrip()
        return blocks


def dedupe(blocks):
    """The OCR sometimes runs past its box and repeats the text of the NEXT blocks at the end of a block: cut each block at
    the start of any later block's text it contains (otherwise those moves are read twice). The comparison ignores ALL whitespace
    ('42.Txc3' and '42. Txc3' are the same text), and tolerates a few OCR typos in the first words of the repeated text. Idempotent."""
    squash = lambda t: re.sub(r"\s+", "", t)
    for b in blocks:  # the OCR sometimes takes the last line of a column for a footer: a footer holding a numbered move ('27...Cd7') is text
        if b["block_label"] == "footer" and re.search(r"\b\d{1,3}\s*\.{1,3}\s*(?:[RDTFC][a-h1-8x]|[a-h][1-8]|0-0|O-O)", b["block_content"]):
            b["block_label"] = "text"
    for b in blocks:  # the OCR sometimes returns a text block as an HTML table: plain text, or its repeated text is not recognised
        if b["block_label"] in KEEP and "<t" in b["block_content"]:
            b["block_content"] = re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", b["block_content"]))).strip()
    keep = [b for b in blocks if b["block_label"] in KEEP and len(squash(b["block_content"])) >= 12]
    for i, a in enumerate(blocks):
        if a["block_label"] not in KEEP:
            continue
        for b in blocks[i + 1:]:
            if b not in keep:
                continue
            idx = [k for k, ch in enumerate(a["block_content"]) if not ch.isspace()]  # position in the original of each non-space char
            flat = "".join(a["block_content"][k] for k in idx)
            sb = squash(b["block_content"])
            for off in (0, 30, 60, 90):  # the repeated text may have OCR typos in its first words: look for a later window of it too
                n = 25 if off == 0 else 60  # (a longer window then: short runs of moves recur between games)
                at = flat.find(sb[off:off + n]) if len(sb) >= off + n else -1
                extra = flat[at - off + len(sb):] if at >= 0 else ""  # what follows the repeated text in the block; a SHORT later block ('- Proposition d'échange des Dames') is a phrase that recurs, not an overrun, unless it ends the block
                if at - off > 0 and (len(sb) >= 60 or len(extra) <= 2):
                    a["block_content"] = a["block_content"][:idx[at - off]].rstrip()
                    break
                if at == 0 or at - off == 0:
                    break
    return blocks


def page_blocks(pdf, doc, n, dpi, work, ocr, min_words):
    cache = work / "blocks" / f"p{n}.json"
    if cache.exists():
        return json.loads(cache.read_text()), "cache"
    png = render(pdf, n, dpi, work)
    words = len(subprocess.check_output(["pdftotext", "-f", str(n), "-l", str(n), str(pdf), "-"], text=True).split())
    if words >= min_words:
        k = dpi / 72
        imgs = image_blocks(doc, n, k, work)
        lines = text_layer_blocks(pdf, n, k)
        info, bg = strip_text(doc, n, k)
        bg.save(work / "pages" / f"p{n}_bg.png")
        for b in lines:
            b["style"] = style_of(b["block_bbox"], info, k)
        blocks, how = lines + imgs, "text layer"
    else:
        blocks, how = ocr.read_page(png), "OCR"
    cache.parent.mkdir(parents=True, exist_ok=True)
    cache.write_text(json.dumps(blocks, ensure_ascii=False))
    return blocks, how


def onwhite(im):
    """RGB version of an image that may have transparency (embedded logos): composited on white."""
    if im.mode != "RGBA":
        return im.convert("RGB")
    bg = Image.new("RGBA", im.size, "white")
    return Image.alpha_composite(bg, im).convert("RGB")


def read_boxes(model, im, boxes, batch=32):
    """[(raw board, confidence, box)] for the board inside each box (fenify, square 0 = a1), evaluated in batches."""
    import torch
    from read_fen import prep
    dev = next(iter(model.parameters())).device if list(model.parameters()) else "cpu"
    out = []
    for i in range(0, len(boxes), batch):
        x = torch.stack([prep(im.crop(b)) for b in boxes[i:i + batch]])
        with torch.no_grad():
            try:
                p = model(x.to(dev)).cpu()  # (B, 64, 13) probabilities
            except RuntimeError as e:  # the OCR model grew and took the GPU: this small net moves to the CPU for good
                if "out of memory" not in str(e):  # (TorchScript raises a plain RuntimeError, not torch.OutOfMemoryError)
                    raise
                dev = "cpu"
                p = model.cpu()(x)
        for q, box in zip(p, boxes[i:i + batch]):
            board = chess.Board(None)
            for sq, c in enumerate(q.argmax(dim=1).tolist()):
                if c:
                    board.set_piece_at(sq, chess.Piece((c - 1) % 6 + 1, chess.BLACK if c > 6 else chess.WHITE))
            out.append((add_missing_king(board), q.max(dim=1).values.mean().item(), box))
    return out


def dense_boxes(im, base):
    """Squares around the autocrop's best one, in steps of a third of a cell over +-1.6 cells and 3 sizes, nearest first.
    The autocrop can be off by a cell AND a few pixels (a checkerboard is periodic), which the one-cell shifts do not cover."""
    x0, y0, x1, y1 = base
    c = (x1 - x0) / 8
    step = max(3, round(c / 3))
    out = []
    for scale in (1.0, 0.94, 1.06):
        s = round((x1 - x0) * scale)
        for dy in range(-round(1.6 * c), round(1.6 * c) + 1, step):
            for dx in range(-round(1.6 * c), round(1.6 * c) + 1, step):
                b = (x0 + dx, y0 + dy, x0 + dx + s, y0 + dy + s)
                if b[0] >= 0 and b[1] >= 0 and b[2] <= im.width and b[3] <= im.height:
                    out.append((abs(dx) + abs(dy) + abs(scale - 1) * 100, b))
    return [b for _, b in sorted(out)]


def fix_colors(raw, im, box):
    """Piece colours checked against the image: black pieces are filled (a large share of very dark pixels in the middle of their square),
    white ones only outlined. The readers sometimes swap the colours of the two kings on small prints (a 'practical case').
    When the dark shares split cleanly in two groups (a gap of at least .05) and the reading disagrees with that split on at most two
    pieces and those are kings, they change colour (if the position stays plausible). Boards with dark squares or wood never split cleanly: untouched.
    Returns (board, decided): `decided` is True when the image split cleanly, i.e. its verdict on the colours (kept or corrected) is to be
    trusted over any heuristic."""
    pieces = list(raw.piece_map())
    if len(pieces) < 3:
        return raw, False
    g = np.asarray(im.convert("L").crop(tuple(box))).astype(float)
    h, w = g.shape
    dark = {}
    for sq in pieces:
        r, c = 7 - chess.square_rank(sq), chess.square_file(sq)
        cell = g[int(r * h / 8 + h / 40):int((r + 1) * h / 8 - h / 40), int(c * w / 8 + w / 40):int((c + 1) * w / 8 - w / 40)]
        dark[sq] = float((cell < 80).mean()) if cell.size else 0.0
    vals = sorted(dark.values())
    gap, at = max((vals[i + 1] - vals[i], i) for i in range(len(vals) - 1))
    if gap < .05:
        return raw, False
    threshold = (vals[at] + vals[at + 1]) / 2
    wrong = [sq for sq in pieces if (raw.piece_at(sq).color == chess.BLACK) != (dark[sq] > threshold)]
    if not wrong:
        return raw, True
    if len(wrong) > 2 or any(raw.piece_at(sq).piece_type != chess.KING for sq in wrong):  # only the kings are ever mixed up: anything else is doubtful
        return raw, False
    fixed = raw.copy()
    for sq in wrong:
        p = raw.piece_at(sq)
        fixed.set_piece_at(sq, chess.Piece(p.piece_type, not p.color))
    return (raw, False) if issues(fixed) else (fixed, True)


def orient_as(raw, flip):
    """(board with white at the bottom, flipped?, sure?) of a board read as displayed. `flip` (from the printed coordinates: True = Black is at
    the bottom) decides when it is known; otherwise the position itself is guessed from (orient)."""
    if flip is None:
        return orient(raw)
    return (raw.transform(lambda bb: chess.flip_vertical(chess.flip_horizontal(bb))) if flip else raw), flip, True


def alt_readings(models, im, min_conf=.95, flip=None):
    """Other plausible readings of a diagram (white at the bottom, piece placement): the crops next to the autocrop's best one, read by every model.
    The checker pattern is periodic, so the best crop can be a cell off, and a shifted board is read just as confidently. Used as possible
    start positions of a page: the page's own moves decide (how many of them are legal from there)."""
    out = []
    boxes = candidate_boxes(im)
    boxes = boxes + [b for b in dense_boxes(im, boxes[0])[:120] if b not in boxes]  # nearest first: within about a cell of the best crop, in finer steps
    for m in models:
        if m is None:
            continue
        for i in range(0, len(boxes), 64):
            for raw, conf, box in read_boxes(m, im, boxes[i:i + 64]):
                raw, decided = fix_colors(raw, im, box)
                raw = raw if decided else repair_king_colors(raw)
                if conf >= min_conf and not issues(raw) and (fen := orient_as(raw, flip)[0].board_fen()) not in out:
                    out.append(fen)
    return out


def load_models(weights, base_weights):
    """(fine-tuned model, original fenify model or None when its file is absent)."""
    import torch
    dev = "cuda" if torch.cuda.is_available() else "cpu"

    def load(p):
        try:
            return torch.jit.load(str(p), map_location=dev).eval()
        except RuntimeError as e:  # the OCR model keeps most of a 12 GB GPU: these small nets then run on the CPU
            if "out of memory" not in str(e):
                raise
            return torch.jit.load(str(p), map_location="cpu").eval()
    return load(weights), (load(base_weights) if base_weights and Path(base_weights).exists() else None)


def vivid_share(im):
    """Share of bright, saturated pixels (yellow/red arrows and highlights; never wood, pieces or pastel print)."""
    import numpy as np
    t = np.asarray(im.convert("RGB")).astype(float)
    mx, mn = t.max(2), t.min(2)
    return float((((mx - mn) / np.maximum(mx, 1) > .75) & (mx > 200)).mean())


def flatten(im, lo=100, hi=230, val=200):
    """The image with every mid-grey pixel set to one grey: the hatching of dark squares (a moire of thin lines, which makes the readers invent or
    recolour pieces) becomes a flat background; outlines (black) and white fills stay."""
    a = np.asarray(im.convert("L"))
    return Image.fromarray(np.where((a > lo) & (a < hi), val, a).astype("uint8")).convert("RGB")


def squares(fen):
    """The 64 squares of a piece placement, one character each ('.' = empty)."""
    return "".join("." * int(c) if c.isdigit() else c for c in fen.split()[0].replace("/", ""))


def snap_to_known(cands, known, limit=4):
    """(candidate, position) for a flawed reading that is a few squares away from ONE position of the book's games, else None. On hatched diagrams the readers
    misread a few white pieces (a rook for a bishop, a queen for a king...) but get the rest right: the position the game gives is then the printed one.
    Within `limit` squares of the position and 2 squares nearer to it than to any other."""
    names = {k: squares(k) for k in known}
    best = None
    for c in cands:
        e = squares(c[0].board_fen())
        d = sorted((sum(x != y for x, y in zip(e, v)), k) for k, v in names.items())
        if d and d[0][0] <= limit and (len(d) == 1 or d[1][0] >= d[0][0] + 2) and (best is None or d[0][0] < best[0]):
            best = (d[0][0], c, d[0][1])
    return best and best[1:]


def iou(a, b):
    """Intersection over union of two [x0, y0, x1, y1] boxes."""
    w, h = min(a[2], b[2]) - max(a[0], b[0]), min(a[3], b[3]) - max(a[1], b[1])
    inter = max(w, 0) * max(h, 0)
    return inter / ((a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter or 1)


def overlap(a, b):
    """Share of box a [x0, y0, x1, y1] that lies inside box b."""
    w, h = min(a[2], b[2]) - max(a[0], b[0]), min(a[3], b[3]) - max(a[1], b[1])
    return max(w, 0) * max(h, 0) / ((a[2] - a[0]) * (a[3] - a[1]) or 1)


def is_blank(im):
    """A picture with next to nothing drawn inside its border (a page frame, a white rectangle)."""
    g = np.asarray(onwhite(im).convert("L"))  # (transparent pixels are white)
    m = max(2, min(g.shape) // 30)
    return (g[m:-m, m:-m] < 200).mean() < .002


def could_be_board(im):
    """The picture may be ONE board: square-ish with a clear checkerboard, not cut in 4 by dashes."""
    if not .8 <= im.width / im.height <= 1.25:
        return False
    box = find_board(im)
    return box[4] >= MIN_BOARD_SCORE and not is_split(im, box[:4])


def frame_fit(g, box):
    """(box with each side moved to the darkest line within 10 pixels, score): the score is the sum over the sides of the share of that line's pixels
    darker than 120. The thin frame drawn round a board scores about 4 on its own box; a box shifted by cells scores far less."""
    x0, y0, x1, y1 = box
    H, W = g.shape
    if x0 < 12 or y0 < 12 or x1 > W - 12 or y1 > H - 12:
        return box, 0.
    dark = g < 120
    top = max(range(-10, 11), key=lambda d: dark[y0 + d, x0:x1].mean())
    bot = max(range(-10, 11), key=lambda d: dark[y1 + d, x0:x1].mean())
    left = max(range(-10, 11), key=lambda d: dark[y0:y1, x0 + d].mean())
    right = max(range(-10, 11), key=lambda d: dark[y0:y1, x1 + d].mean())
    return [x0 + left, y0 + top, x1 + right, y1 + bot], dark[y0 + top, x0:x1].mean() + dark[y1 + bot, x0:x1].mean() + dark[y0:y1, x0 + left].mean() + dark[y0:y1, x1 + right].mean()


def snap_to_frame(im, box):
    """The board box moved by whole cells (up to 2 each way) to where its frame is, when that is clearly better than where the checkerboard search put it
    (the search is periodic: it can pick a board one or two cells off)."""
    g = np.asarray(onwhite(im).convert("L"))
    c = (box[2] - box[0]) / 8
    fits = [frame_fit(g, [round(box[0] + dx * c), round(box[1] + dy * c), round(box[2] + dx * c), round(box[3] + dy * c)]) for dx in range(-2, 3) for dy in range(-2, 3)]
    best = max(fits, key=lambda f: f[1])
    return best[0] if best[1] > frame_fit(g, box)[1] + .5 else box


def split_boards(im):
    """[(picture, box in im)] for the boards of a picture that holds several (four tests on one page, two columns of boards): the board
    searched in the four overlapping quarters, kept when it is a clear checkerboard and not a duplicate. Each picture is the board with a
    margin for its coordinates and the dot beside it. Quarters come in column order (top-left, bottom-left, top-right, bottom-right)."""
    W, H = im.size
    if min(W, H) < 500:
        return []
    found = []
    for cx in (0, 1):
        for cy in (0, 1):
            x0, y0 = int(cx * W * .45), int(cy * H * .45)
            b = find_board(im.crop((x0, y0, int(x0 + W * .55), int(y0 + H * .55))), .45)
            box = snap_to_frame(im, [b[0] + x0, b[1] + y0, b[2] + x0, b[3] + y0]) if b[4] >= MIN_BOARD_SCORE else [0, 0, 0, 0]
            if b[4] >= MIN_BOARD_SCORE and not any(iou(box, f) > .5 for f in found):
                found.append(box)
    out = []
    for x0, y0, x1, y1 in found:
        m = round((x1 - x0) * .18)
        r = (max(0, x0 - m), max(0, y0 - m), min(W, x1 + m), min(H, y1 + m))
        out.append((im.crop(r), r))
    return out


def board_before(mv):
    """Piece placement before a replayed move, when it can be undone exactly (no capture, promotion or castling), else None."""
    if "x" in mv["san"] or len(mv["uci"]) > 4 or mv["san"].startswith("O"):
        return None
    b, m = chess.Board(mv["fen"]), chess.Move.from_uci(mv["uci"])
    b.set_piece_at(m.from_square, b.remove_piece_at(m.to_square))
    return b.board_fen()


def missed_boards(page_img, lines, blocks):
    """Image blocks for the boards the OCR did not see (a board inside a page-sized table, or no block at all): what is left of the page's ink once the
    figure blocks and the text lines (two characters or more: not the a-h / 1-8 coordinates) are erased, grouped by dilation, is kept when it is square-ish,
    board-sized and a clear checkerboard."""
    g = np.asarray(onwhite(page_img).convert("L"))
    ink = (g < 200).astype(np.uint8)
    for l in lines:
        boxes = [p[1] for p in l["pieces"]]
        if len("".join(p[0] for p in l["pieces"]).strip()) >= 2 and boxes:
            x0, y0, x1, y1 = min(b[0] for b in boxes), min(b[1] for b in boxes), max(b[2] for b in boxes), max(b[3] for b in boxes)
            ink[max(0, int(y0) - 4):int(y1) + 4, max(0, int(x0) - 4):int(x1) + 4] = 0
    figs = [[int(v) for v in b["block_bbox"]] for b in blocks if b["block_label"] in FIGURE]
    for x0, y0, x1, y1 in figs:
        ink[max(0, y0):y1, max(0, x0):x1] = 0
    n, _, stats, _ = cv2.connectedComponentsWithStats(cv2.dilate(ink, np.ones((25, 25), np.uint8)))  # (the page frame and column rules are far bigger than a board)
    out = []
    for x, y, w, h, _ in stats[1:]:
        if 150 <= w <= 900 and 150 <= h <= 900 and .75 <= w / h <= 1.33 and not any(overlap([x, y, x + w, y + h], f) > .3 for f in figs):  # (the frame of a found board can stick out of its box)
            im = page_img.crop((x, y, x + w, y + h))
            if .8 <= im.width / im.height <= 1.25 and find_board(im)[4] >= MISSED_BOARD_SCORE:  # (a faint hatched board scores 2.5, a logo under 1)
                out.append({"block_label": "image", "block_content": "", "block_bbox": [int(x), int(y), int(x + w), int(y + h)], "min_score": MISSED_BOARD_SCORE})
    return out


def unstretch(im):
    """A diagram image drawn wider (or taller) than its board is square: the autocrop looks for a square, so the image is squeezed to square
    when that makes the checkerboard clearly better (7.8 against 4.8 on a 1.24 wide board: the reading was a shifted board)."""
    if .87 <= im.width / im.height <= 1.15 or not .8 <= im.width / im.height <= 1.25:
        return im
    sq = im.resize((min(im.size),) * 2)
    return sq if find_board(sq)[4] > 1.3 * find_board(im)[4] else im


def read_diagram(model, im, known=frozenset(), base=None, flip=None, min_score=MIN_BOARD_SCORE):
    """Double reading: the fine-tuned `model` first; when it is not sure of itself (confidence < TRUSTED and no arrows or highlights, e.g. a print style it was
    not fine-tuned on: hatched squares make it invent queens) the original `base` model also reads (the image as is, then with its hatching
    flattened), and a reading wins if it is more confident and plausible (never over a reading that a game of the book confirms).
    A reading that stays implausible or unsure is finally snapped to the nearest position of the book's games (snap_to_known)."""
    im = unstretch(im)
    r = _read_diagram(model, im, known, flip, min_score)
    if not r:
        return r
    if min_score < MIN_BOARD_SCORE and (issues(r[4]) or len(r[4].piece_map()) < 4):  # a candidate the OCR did not call a figure: a logo or a flowchart box reads as a few pieces
        return None
    best, cands = r, [r]
    if base is not None and r[1] < TRUSTED and r[0].board_fen() not in known and vivid_share(im) < MAX_VIVID:  # a reading confirmed by the game stays
        for img in (im, flatten(im)):
            r2 = _read_diagram(base, img, known, flip)
            if not r2:
                continue
            cands.append(r2)
            # same pieces on the same squares but other colours: the base model mixes up who owns outlined pieces on hatched squares, keep the first
            if r2[1] > best[1] and not issues(r2[4]) and not colors_only_differ(r[0], r2[0]):
                # the base model invents queens on empty hatched squares (conf 1.0) where the fine-tuned one, reading the SAME square, sees nothing: drop those
                ft = read_boxes(model, im, [r2[5]])[0][0]
                raw = r2[4].copy()
                for sq in [sq for sq, p in raw.piece_map().items() if p.piece_type == chess.QUEEN and ft.piece_at(sq) is None]:
                    raw.remove_piece_at(sq)
                if raw.board_fen() != r2[4].board_fen():
                    oriented, flipped, sure = orient_as(raw, flip)
                    r2 = (oriented, r2[1], flipped, sure, raw, r2[5])
                best = r2
    # (a reading that is not plausible or not confident: up to 4 squares away; one the readers merely disagree on: 2, a printed variation can be 2-3 squares from a game position)
    flawed = issues(best[4]) or best[1] < CONFIDENT
    if known and best[0].board_fen() not in known and (flawed or len({c[0].board_fen() for c in cands}) > 1) and (hit := snap_to_known(cands, known, 4 if flawed else 2)):
        c, fen = hit
        oriented = chess.Board(fen + " w - - 0 1")
        raw = oriented.transform(lambda bb: chess.flip_vertical(chess.flip_horizontal(bb))) if c[2] else oriented  # (c[2] = the reading was upside down)
        return oriented, c[1], c[2], True, raw
    return best[:5]


def is_split(im, box):
    """A figure cut in 4 by dashed lines through the middle (several small positions on one board, e.g. 'Réseaux de mats'): not one position.
    The dashes darken the central column AND row (>= 0.4 of their pixels; measured: 0.4-0.76 there, <= 0.28 on ordinary boards)."""
    g = np.asarray(im.convert("L").crop(tuple(box)), float) < 110
    win = int(g.shape[1] / 8 * .3)
    return all(p[len(p) // 2 - win:len(p) // 2 + win].max() >= .4 for p in (g.mean(0), g.mean(1)))


def _read_diagram(model, im, known=frozenset(), flip=None, min_score=MIN_BOARD_SCORE):
    """(oriented board, confidence, flipped, orientation sure, raw board, box read) or None when the image is not a board.
    `known` = piece placements that occur in the book's games. Tries the best square and its one-cell shifts; if none reads as a
    known position, searches more finely around it (batched). The first reading that IS a known position wins, otherwise the
    best square's own reading is kept (the diagram may show a position that is in no game)."""
    if not .8 <= im.width / im.height <= 1.25:  # banners, labels
        return None
    box = find_board(im)
    if box[4] < min_score or is_split(im, box[:4]):
        return None
    first = candidate_boxes(im)
    reads = read_boxes(model, im, first)
    best = reads[0]
    hit = next((r for r in reads if orient_as(r[0], flip)[0].board_fen() in known), None)
    if hit is None and known:
        dense = dense_boxes(im, first[0])
        for i in range(0, len(dense), 64):
            hit = next((r for r in read_boxes(model, im, dense[i:i + 64]) if orient_as(r[0], flip)[0].board_fen() in known), None)
            if hit:
                break
    weak = issues(best[0]) or best[1] < CONFIDENT
    if (hit is None or hit is not best) and weak:
        # the best square's reading is not a legal-looking position (no king, pawns on the back rank...) or not a confident one: the autocrop is probably
        # off by a few pixels. Take the most confident plausible reading around it.
        # (also around a board found with a larger minimum size: the checker pattern can lock onto a 6x6 sub-board)
        pool, bases = [], [first[0], find_board(im, .8)[:4]]
        for base in dict.fromkeys(bases):
            for i in range(0, len(dense := dense_boxes(im, base)), 64):
                pool += [r for r in read_boxes(model, im, dense[i:i + 64]) if not issues(r[0])]
        if pool and (best_pool := max(pool, key=lambda r: r[1])):
            if hit is None:
                if issues(best[0]) or best_pool[1] > best[1]:
                    hit = best_pool
            elif best_pool[1] >= TRUSTED and sum(best_pool[0].piece_at(q) != hit[0].piece_at(q) for q in chess.SQUARES) > 4:
                hit = best_pool  # a game position that a crop merely happens to read (far from what a sure reading sees) is no confirmation
    raw, conf, box = hit or best
    raw, decided = fix_colors(raw, im, box)  # the image first; the heuristic on the kings only when the image cannot tell
    raw = raw if decided else repair_king_colors(raw)  # (both before the orientation, which compares the armies)
    oriented, flipped, sure = orient_as(raw, flip)
    return oriented, conf, flipped, sure, raw, box


def move_pairs(text, lang):
    """How many move numbers directly followed by a move the text holds."""
    toks = tokens(text, lang)
    return sum(t[0] == "num" and nxt[0] == "move" for t, nxt in zip(toks, toks[1:]))


def move_dense(html_text, lang):
    """True when at least half of the text of an HTML table is moves and move numbers (a game, not prose with a few moves)."""
    t = re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", html_text))).strip()
    return sum(k[3] - k[2] for k in tokens(t, lang) if k[0] != "prose") >= .5 * len(t)


def has_moves(text, lang):
    """True when the text has a move number directly followed by a move ('12.Cf3'), not only a numbered list ('1. Les Noirs')."""
    toks = tokens(text, lang)
    return any(t[0] == "num" and nxt[0] == "move" for t, nxt in zip(toks, toks[1:]))


def infer_start(text, lang, others):
    """(FEN, source, previous FEN) to replay a page from when its first move number is not 1: a position of another page's mainline at that ply
    after which the text replays (almost) without illegal moves. A page may also begin with a variation of the previous page's last move
    ('[19...Ff6!?] 20.exf5'): the start is then the position after that move, and the one before it is returned too. (None, None, None) when nothing fits."""
    toks = tokens(text, lang)
    num = next((t[1] for t, nxt in zip(toks, toks[1:]) if t[0] == "num" and nxt[0] == "move"), None)
    if num is None:
        return None, None, None
    ply = 2 * int(num.rstrip(".")) - (1 if num.endswith("...") else 2)
    if ply == 0:
        return chess.STARTING_FEN, "start of game", None
    best = (0, None, None, None)
    for page, ms in others:
        for i, m in enumerate(ms):
            if m["ok"] and m["depth"] == 0 and m["ply"] == ply:
                nxt = next((x for x in ms[i + 1:] if x["depth"] == 0), None)
                for fen, prev, src in [(m["fen"], None, f"position of page {page} at ply {ply}")] + (
                        [(nxt["fen"], m["fen"], f"position of page {page} at ply {ply + 1}")] if nxt and nxt["ok"] and nxt["ply"] == ply + 1 else []):
                    r = replay(text, fen, lang, prev=prev)
                    good, bad = sum(x["ok"] for x in r), sum(not x["ok"] for x in r)
                    if good >= 5 and bad <= max(2, good // 8) and good - 3 * bad > best[0]:  # prose alternatives without brackets give a few illegal moves
                        best = (good - 3 * bad, fen, src, prev)
    return best[1], best[2], best[3]


def selfcheck():
    """python make_chessbook_cli.py --check : OCR defects of the text blocks."""
    mk = lambda t: {"block_label": "text", "block_bbox": [0, 0, 1, 1], "block_content": t}
    a = mk("13...Cd8 Le Cavalier. 14.a4! Poursoit le plan de clarification à l'aile dame. 14...Tb8 [14...bxa4 15.Fxa4+- La case c4.] 15.axb5 Ouvre la colonne a. 15...axb5")
    b = mk("Poursuit le plan de clarification à l'aile dame. 14...Tb8 [ 14...bxa4 15.Fxa4+- La case c4.] 15.axb5 Ouvre la colonne a. 15...axb5 Les Blancs dominent.")
    dedupe([a, b])  # the repeated passage has OCR typos in its first words: the start of the next block is not found as is
    assert a["block_content"] == "13...Cd8 Le Cavalier. 14.a4!", a["block_content"]
    c, d = mk("1.e4 e5 2.Cf3 Cc6 3.Fb5 a6 4.Fa4 Cf6 5.0-0 Fe7"), mk("Avec la suite 6.Te1 b5 7.Fb3 d6 8.c3 0-0 9.h3 Ca5")
    dedupe([c, d])
    assert c["block_content"].endswith("Fe7") and d["block_content"].startswith("Avec")  # unrelated blocks are left alone
    k = chess.Board("8/8/8/1K6/1Q6/8/1p6/2k5 w - - 0 1")  # the position of 'Dame contre pions' diagram 1: White (K, Q) is ABOVE its enemy pawn
    assert orient_as(k, False)[0].board_fen() == "8/8/8/1K6/1Q6/8/1p6/2k5" and orient_as(k, False)[2] is True  # printed coordinates: kept as shown
    assert orient_as(k, True)[0].board_fen() == "5k2/6p1/8/6Q1/6K1/8/8/8"  # shown with Black at the bottom: turned round
    assert orient_as(k, None)[0].board_fen() == orient(k)[0].board_fen()  # no coordinates: the guess
    # piece colours read off the image: black pieces are filled (dark), white ones only outlined; the readers mix them up on small prints
    from PIL import ImageDraw
    im = Image.new("RGB", (160, 160), "white")
    dr = ImageDraw.Draw(im)
    for name, black in (("e3", True), ("d5", True), ("f5", True), ("e8", False), ("e4", False), ("e2", False)):
        sq = chess.parse_square(name)
        x, y = chess.square_file(sq) * 20, (7 - chess.square_rank(sq)) * 20
        if black:
            dr.rectangle([x + 5, y + 5, x + 14, y + 14], fill="black")
        else:
            for dx, dy in ((9, 6), (10, 6), (9, 13), (10, 13), (6, 10), (13, 10)):
                dr.point((x + dx, y + dy), fill="black")  # a few outline pixels
    bl = lambda t, x, y: {"block_label": "text", "block_content": t, "block_bbox": [x, y, x + 300, y + 50]}  # the OCR put the top of the right column before the end of the left one
    assert [b["block_content"] for b in column_order([bl("a", 50, 10), bl("c", 900, 10), bl("b", 50, 500), bl("d", 900, 500)], )] == ["a", "b", "c", "d"]
    wrong = chess.Board("4k3/8/8/3p1p2/4P3/4K3/4P3/8 w - - 0 1")  # the kings' colours swapped (the real misreading of 'Dame contre pions' diagram 8.1)
    fixed, decided = fix_colors(wrong, im, (0, 0, 160, 160))
    assert fixed.board_fen() == "4K3/8/8/3p1p2/4P3/4k3/4P3/8" and decided
    right = chess.Board("4K3/8/8/3p1p2/4P3/4k3/4P3/8 w - - 0 1")  # already right: kept, and the image is the authority (the kings' heuristic must not swap them)
    assert fix_colors(right, im, (0, 0, 160, 160)) == (right, True)
    rook = chess.Board("r3K3/8/8/3p1p2/4P3/4k3/4P3/8 w - - 0 1")  # a doubtful non-king piece (a black rook drawn light) is never recoloured
    assert fix_colors(rook, im, (0, 0, 160, 160))[1] is False
    blank = fix_colors(chess.Board("8/8/8/8/8/8/8/K6k w - - 0 1"), Image.new("RGB", (160, 160), "white"), (0, 0, 160, 160))
    assert blank[0].board_fen() == "8/8/8/8/8/8/8/K6k" and blank[1] is False  # no dark pieces: no information
    # the board before a quiet move (the diagram a passage starts from); None when a capture hides what stood on the square
    assert board_before({"san": "Qb6", "uci": "d6b6", "fen": "6rk/4b1r1/1Q6/Pp1p1p2/1P3R1P/4qBP1/6RK/8 b - - 1 1"}) == "6rk/4b1r1/3Q4/Pp1p1p2/1P3R1P/4qBP1/6RK/8"
    assert board_before({"san": "Qxb6", "uci": "d6b6", "fen": "6rk/4b1r1/1Q6/8/8/8/6RK/8 b - - 0 1"}) is None
    # a board the OCR missed (inside a page-sized table): found from the ink left once the text lines are erased
    from PIL import ImageDraw
    pg = Image.new("RGB", (1200, 1400), "white")
    d = ImageDraw.Draw(pg)
    d.rectangle([30, 30, 1170, 1370], outline="black", width=4)  # the page frame is no board
    for i in range(8):
        for j in range(8):
            d.rectangle([400 + i * 40, 500 + j * 40, 439 + i * 40, 539 + j * 40], fill=(110, 80, 60) if (i + j) % 2 else (240, 225, 200))
    d.rectangle([400, 500, 720, 820], outline="black", width=2)
    found = missed_boards(pg, [], [])
    assert len(found) == 1 and abs(found[0]["block_bbox"][0] - 400) < 40 and abs(found[0]["block_bbox"][1] - 500) < 40, found
    assert missed_boards(pg, [], [{"block_label": "image", "block_bbox": [380, 480, 740, 840]}]) == []  # a board the OCR found is left alone
    assert missed_boards(pg, [], [{"block_label": "image", "block_bbox": [420, 520, 700, 800]}]) == []  # also when its frame sticks out of the OCR's box
    print("make_chessbook_cli self-check ok")


def main():
    if sys.argv[1:] == ["--check"]:
        return selfcheck()
    ap = argparse.ArgumentParser(description="Generate a .chessbook from a chess-book PDF.")
    ap.add_argument("pdf", type=Path)
    ap.add_argument("-o", "--output", type=Path, help="default: <pdf name>.chessbook in the current folder")
    ap.add_argument("--lang", choices=("fr", "en"), default="fr", help="language of the move notation (fr: C F T D R, en: N B R Q K)")
    ap.add_argument("--title", help="default: PDF title, else file name")
    ap.add_argument("--pages", help="e.g. 1-40 or 3,5,8-10 (default: all)")
    ap.add_argument("--dpi", type=int, default=200)
    ap.add_argument("--work", type=Path, help="cache folder, default work/<pdf name>/")
    ap.add_argument("--no-scans", action="store_true", help="do not embed the page images (smaller file, no facsimile)")
    ap.add_argument("--min-text-words", type=int, default=60, help="pages with fewer words in the PDF text layer are OCRed")
    ap.add_argument("--progress-lines", action="store_true", help="machine-readable progress lines (used by make_chessbook_gui.py)")
    ap.add_argument("--weights", type=Path, default=HERE / "work" / "fenify-ft.pt", help="diagram reader weights (TorchScript)")
    ap.add_argument("--base-weights", type=Path, default=HERE / "work" / "fenify-base.pt",
                    help="original fenify weights for the double reading (optional: used only when the file exists)")
    a = ap.parse_args()
    global MACHINE
    MACHINE = a.progress_lines

    if not a.weights.exists():  # fail now, not after minutes of OCR
        sys.exit(f"Diagram weights not found: {a.weights}\nDownload them with: .venv/bin/python fetch_weights.py   (see \"Diagram weights\" in the README)")
    out = a.output or Path(a.pdf.stem + ".chessbook")
    work = a.work or HERE / "work" / a.pdf.stem
    (work / "diagrams").mkdir(parents=True, exist_ok=True)
    autocrop.CACHE_DIR = work / "autocrop"
    doc = pdfium.PdfDocument(str(a.pdf))
    title = a.title or doc.get_metadata_dict().get("Title") or a.pdf.stem
    pages = page_numbers(a.pages, len(doc))
    ocr, k = Ocr(), a.dpi / 72

    blocks, pngs, classic, page_lines = {}, {}, Classic(), {}
    for n in bar(pages, "Reading pages (OCR)"):
        blocks[n], how = page_blocks(a.pdf, doc, n, a.dpi, work, ocr, a.min_text_words)
        for b in blocks[n]:
            if b["block_label"] == "algorithm":  # the OCR calls a block of moves an 'algorithm' (a code listing) now and then: book text
                b["block_label"] = "text"
        pngs[n] = render(a.pdf, n, a.dpi, work)
        if how != "text layer":  # the main OCR drops text now and then: a column cut short, a line of moves with no block at all. The classic OCR
            lines = page_lines[n] = classic.lines(pngs[n], work / "ppocr" / f"p{n}.json")  # (cached, also used later to locate the moves) has them
            # a table of moves (a page taken for ONE table, or a game written one move per cell) is no text block: drop it, the lines of the classic OCR below give the moves
            blocks[n] = [b for b in blocks[n] if not (b["block_label"] == "table" and has_moves(b["block_content"], a.lang)
                                                      and (move_dense(b["block_content"], a.lang) or b["block_bbox"][3] - b["block_bbox"][1] > .5 * Image.open(pngs[n]).height))]
            blocks[n] += missed_boards(Image.open(pngs[n]).convert("RGB"), lines, blocks[n])
            fill_sparse(blocks[n], lines)
            fill_moves(blocks[n], lines, lambda t: move_pairs(t, a.lang))
            add_orphans(blocks[n], lines, lambda t: has_moves(t, a.lang))
        blocks[n] = dedupe(column_order(blocks[n]))

    # moves: pages whose text starts at move 1 first, the others from a position of another page's game
    texts = {n: joined_text(blocks[n]) for n in pages}
    replays, starts, start_fens, prevs = {}, {}, {}, {}
    for n in pages:
        fen, src, prev = infer_start(texts[n], a.lang, [])
        if fen:
            replays[n], starts[n], start_fens[n], prevs[n] = replay(texts[n], fen, a.lang, prev=prev), src, fen, prev
    for n in pages:
        if n not in replays:
            fen, src, prev = infer_start(texts[n], a.lang, [(p, replays[p]) for p in sorted(replays, key=lambda p: abs(p - n))])
            replays[n], starts[n], start_fens[n], prevs[n] = (replay(texts[n], fen, a.lang, prev=prev) if fen else []), src, fen, prev
    # exercise-style pages: each passage starts from a diagram of the book, not from the initial position. Pages whose replay fails
    # (or finds nothing) are replayed with the boards of the nearby diagrams as candidate restart positions (see moves.replay)
    model, base, boards = None, None, {}
    def boards_of(p, pb):
        nonlocal model, base
        if p not in boards:
            boards[p], page_img = [], Image.open(pngs[p]).convert("RGB")
            figs = [b for b in blocks[p] if b["block_label"] in FIGURE]
            for k, b in enumerate(figs, 1):
                pb.note(f"page {p}: diagram {k}/{len(figs)}")
                x0, y0, x1, y1 = b["block_bbox"]
                im = Image.open(work / b["image_file"]) if b.get("image_file") else page_img.crop((x0, y0, x1, y1))
                if model is None:
                    model, base = load_models(a.weights, a.base_weights)
                flip = coordinate_flip(page_lines[p], [x0, y0, x1, y1]) if p in page_lines else None  # printed a-h / 1-8, when the OCR read them
                r = read_diagram(model, onwhite(im), base=base, flip=flip, min_score=b.get("min_score", MIN_BOARD_SCORE))
                if r:
                    boards[p].append(r[0].board_fen())
                    boards[p] += [f for f in alt_readings((model, base), onwhite(im), flip=flip) if f not in boards[p]]  # the best crop may be a cell off
        return boards[p]
    pb = bar([n for n in pages if has_moves(texts[n], a.lang) and (not replays[n] or not all(m["ok"] for m in replays[n]))], "Moves from diagrams")
    for n in pb:
        if has_moves(texts[n], a.lang) and (not replays[n] or not all(m["ok"] for m in replays[n])):
            anchors = [f for p in sorted((q for q in pages if abs(q - n) <= 2), key=lambda q: abs(q - n)) for f in boards_of(p, pb)]
            if anchors:
                better = replay(texts[n], start_fens[n], a.lang, anchors, own=len(boards_of(n, pb)), prev=prevs[n])
                if sum(m["ok"] for m in better) > sum(m["ok"] for m in replays[n]):
                    replays[n] = better
                    starts[n] = starts[n] or "diagram positions"
    data = {n: page_data(n, blocks[n], pngs[n], replays[n]) for n in pages}
    for n in pages:  # text-layer pages: the page without its text, drawn under the text by the reader
        if (work / "pages" / f"p{n}_bg.png").exists():
            data[n]["background"] = f"backgrounds/p{n}.png"

    # where each move sits on the page image: lets the reader keep the ORIGINAL page and put clickable zones on it
    for n in bar(pages, "Locating moves"):
        if not any(m["ok"] for m in data[n]["moves"]):
            continue
        scanned = not (work / "pages" / f"p{n}_bg.png").exists()  # no text layer: locate through a second, classic OCR
        lines = classic.lines(pngs[n], work / "ppocr" / f"p{n}.json") if scanned else None
        by_id = {m["id"]: m for m in data[n]["moves"]}
        for blk, src in zip(data[n]["blocks"], text_blocks(blocks[n])):
            if not blk["moves"]:
                continue
            spans = [by_id[i]["span"] for i in blk["moves"]]
            if scanned:
                x, y, w, h = blk["bbox"]
                rects = move_rects_ocr(src["block_content"], [x, y, x + w, y + h], spans, lines)
            else:
                rects = move_rects_textlayer(src.get("words", []), spans)
            for i, r in zip(blk["moves"], rects):
                if r:
                    by_id[i]["rects"] = r

    # diagrams: read each figure, then look for its position in the games of the book
    known = {mv["fen"].split()[0] for p in pages for mv in data[p]["moves"] if mv["ok"]} | {chess.Board(f).board_fen() for f in start_fens.values() if f}
    known |= {f for p in pages for mv in data[p]["moves"] if mv["ok"] and (f := board_before(mv))}  # (the diagram a passage starts from is none of the above)
    fen_of = {mv["id"]: mv["fen"] for p in pages for mv in data[p]["moves"] if mv["ok"]}
    pb = bar(pages, "Reading diagrams")
    for n in pb:
        page_img = None
        nb = ni = 0
        figs = []
        for b in blocks[n]:  # (two image blocks on the same box are one picture)
            if b["block_label"] in FIGURE and not any(iou(b["block_bbox"], o["block_bbox"]) > .9 for o in figs):
                figs.append(b)
        for k, b in enumerate(figs, 1):
            pb.note(f"page {n}: diagram {k}/{len(figs)}")
            page_img = page_img or Image.open(pngs[n]).convert("RGB")
            x0, y0, x1, y1 = b["block_bbox"]
            im = Image.open(work / b["image_file"]) if b.get("image_file") else page_img.crop((x0, y0, x1, y1))
            if is_blank(im):  # the embedded picture is only a frame: the boards are drawn on the page itself
                im = page_img.crop((x0, y0, x1, y1))
            if model is None:
                model, base = load_models(a.weights, a.base_weights)
            items = [(im, [x0, y0, x1, y1])]
            if not could_be_board(im):
                items = [(sub, [x0 + sx0, y0 + sy0, x0 + sx1, y0 + sy1]) for sub, (sx0, sy0, sx1, sy1) in split_boards(im)] or items  # several boards in one picture
            for im, (x0, y0, x1, y1) in items:
                flip = coordinate_flip(page_lines[n], [x0, y0, x1, y1]) if n in page_lines else None
                r = read_diagram(model, onwhite(im), known, base, flip, b.get("min_score", MIN_BOARD_SCORE))
                if not r and b.get("min_score"):
                    continue  # a candidate of missed_boards that is no board (logo, flowchart box) is not an image of the book
                # boards are p{n}_d{k}, other images (logos, labels) p{n}_i{k}: board numbering does not depend on them
                if r:
                    nb += 1
                    fid = f"p{n}_d{nb}"
                else:
                    ni += 1
                    fid = f"p{n}_i{ni}"
                im.save(work / "diagrams" / f"{fid}.png")
                d = {"id": fid, "bbox": [x0, y0, x1 - x0, y1 - y0], "image": f"diagrams/{fid}.png", "fen": None, "confidence": 0, "reviewed": False}
                if r:
                    board, conf, flipped, sure, raw = r
                    d.update(fen=board.board_fen() + " w - - 0 1", confidence=round(conf, 3), flipped=flipped, orientation_sure=sure, issues=issues(raw))
                    # the printed position should occur in a game of the book: the page's own moves first, then any other page's
                    # (a page often shows positions of the full game printed elsewhere)
                    fen_board = board.board_fen()
                    hit = next((m["id"] for p in [n] + [q for q in pages if q != n] for m in data[p]["moves"] if m["ok"] and m["fen"].split()[0] == fen_board), None)
                    if not hit and starts[n] and chess.Board(start_fens[n]).board_fen() == fen_board:
                        hit = "start"  # the diagram shows the position the page's text starts from
                    if hit:
                        d["matches_move"] = hit  # the printed position occurs in the page's game: a strong check of the reading
                        # and the game tells whose turn it is (the book prints it as a dot beside the board): use the game's full FEN
                        full = start_fens[n] if hit == "start" else fen_of[hit]
                        d["fen"] = " ".join(full.split()[:4]) + " 0 1"
                        d["side_known"], d["side_source"] = True, "game"
                    # whose turn the printed dot says (level with the rank of the side to move)
                    # (the dot is read against the army at the bottom; it is evidence about THIS diagram, a game match can be a coincidence)
                    turn = dot_turn(page_img, [x0, y0, x1 - x0, y1 - y0], flipped)
                    if turn and (not d.get("side_known") or d["fen"].split()[1] != turn):
                        d["fen"] = " ".join(d["fen"].split()[:1] + [turn] + (d["fen"].split()[2:4] if d.get("side_known") else ["-", "-"])) + " 0 1"
                        d["side_known"], d["side_source"] = True, "dot"
                data[n]["diagrams"].append(d)

    # write the book; the reader's corrections.json survives a rebuild
    corrections = json.dumps({"schema_version": 1, "corrections": []})
    if out.exists():
        with zipfile.ZipFile(out) as old:
            if "corrections.json" in old.namelist():
                corrections = old.read("corrections.json").decode()
    tmp = out.with_name(out.name + ".tmp")
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("manifest.json", json.dumps({"schema_version": 1, "title": title, "language": a.lang, "figurine_notation": False,
                                                "page_count": len(pages), "has_scans": not a.no_scans, "dpi": a.dpi}, ensure_ascii=False, indent=1))
        z.writestr("corrections.json", corrections)
        for n in pages:
            z.writestr(f"pages/p{n:04d}.json", json.dumps(data[n], ensure_ascii=False, indent=1))
            if not a.no_scans:
                z.write(pngs[n], f"scans/p{n:04d}.png")
            if data[n].get("background"):
                z.write(work / "pages" / f"p{n}_bg.png", data[n]["background"])
            for d in data[n]["diagrams"]:
                z.write(work / d["image"], d["image"])
    tmp.replace(out)

    print(f"\n{out}: {len(pages)} pages, total time {mmss(time.time() - T0)}")
    for n in pages:
        ms, ds = data[n]["moves"], data[n]["diagrams"]
        bad = sum(not m["ok"] for m in ms)
        read = [d for d in ds if d["fen"]]
        located = sum(1 for m in ms if m.get("rects"))
        print(f"  page {n}: {len(ms)} moves ({located} located on the page image), {bad} illegal" + (f", start: {starts[n]}" if starts[n] and starts[n] != "start of game" else "")
              + (", NO START POSITION" if not ms and has_moves(texts[n], a.lang) and not starts[n] else "")
              + f"; diagrams: {len(read)}/{len(ds)} read, {sum('matches_move' in d for d in read)} match the game")


if __name__ == "__main__":
    sys.exit(main())

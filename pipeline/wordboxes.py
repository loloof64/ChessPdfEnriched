"""Where is each move on the page image? Pixel rectangles for the moves of a page, so the reader can keep the ORIGINAL page
and put clickable overlays on it.

- scanned pages: the main OCR (PaddleOCR-VL) gives accurate text but only block boxes. The classic PaddleOCR (PP-OCRv5) gives
  text pieces with boxes. Both texts describe the same lines, so a block's text is aligned character by character
  (difflib) with the text of the classic OCR lines inside the block, and a move's characters are mapped to boxes.
- text-layer pages: pdftotext gives every word's box (stored per line block by make_chessbook).
Usage as a script: wordboxes.py PAGE.png   (prints the classic OCR lines found)
"""
import difflib
import json
import sys
from pathlib import Path


class Classic:
    """PP-OCRv5 with word boxes, loaded on first use."""

    ocr = None

    def lines(self, png, cache=None):
        """[{"pieces": [(text, [x0, y0, x1, y1]), ...]}] for each text line of the page image; cached as JSON when asked."""
        if cache and Path(cache).exists():
            return json.loads(Path(cache).read_text())
        if Classic.ocr is None:
            from paddleocr import PaddleOCR
            Classic.ocr = PaddleOCR(use_doc_orientation_classify=False, use_doc_unwarping=False, use_textline_orientation=False, lang="fr")
        res = list(Classic.ocr.predict(str(png), return_word_box=True))[0].json["res"]
        out = [{"pieces": [(t, [float(v) for v in b]) for t, b in zip(words, boxes)]} for words, boxes in zip(res["text_word"], res["text_word_boxes"])]
        if cache:
            Path(cache).parent.mkdir(parents=True, exist_ok=True)
            Path(cache).write_text(json.dumps(out))
        return out


def char_boxes(pieces):
    """(text, [box per character]) of a line given as (text, box) pieces: a piece's box is shared out evenly among its characters."""
    text, boxes = "", []
    for t, (x0, y0, x1, y1) in pieces:
        n = max(len(t), 1)
        for i, _ in enumerate(t):
            boxes.append([x0 + (x1 - x0) * i / n, y0, x0 + (x1 - x0) * (i + 1) / n, y1])
        text += t
    return text, boxes


def block_stream(lines, bbox):
    """(text, char boxes) of the classic-OCR lines whose centre lies inside bbox [x0, y0, x1, y1], top to bottom."""
    x0, y0, x1, y1 = bbox
    inside = []
    for ln in lines:
        text, boxes = char_boxes([(t, b) for t, b in ln["pieces"]])
        if not boxes:
            continue
        cx = (min(b[0] for b in boxes) + max(b[2] for b in boxes)) / 2
        cy = (min(b[1] for b in boxes) + max(b[3] for b in boxes)) / 2
        if x0 - 4 <= cx <= x1 + 4 and y0 - 4 <= cy <= y1 + 4:
            inside.append((cy, min(b[0] for b in boxes), text, boxes))
    inside.sort(key=lambda r: (round(r[0] / 8), r[1]))
    text, boxes = "", []
    for _, _, t, b in inside:
        text += t + " "
        boxes += b + [None]  # the joining space has no box
    return text, boxes


def sparse_blocks(blocks, min_area=100_000, ratio=.3):
    """Text blocks that hold far fewer characters than their box allows (below `ratio` of the page's median density, box of at least
    `min_area` px²): the main OCR sometimes stops after a sentence and drops the rest of a column."""
    chars = lambda b: sum(not c.isspace() for c in b["block_content"])
    area = lambda b: (b["block_bbox"][2] - b["block_bbox"][0]) * (b["block_bbox"][3] - b["block_bbox"][1])
    text = [b for b in blocks if b["block_label"] == "text"]
    if len(text) < 3:
        return []
    dens = sorted(chars(b) / max(area(b), 1) for b in text)
    median = dens[len(dens) // 2]
    return [b for b in text if area(b) >= min_area and chars(b) / area(b) < ratio * median]


def fill_sparse(blocks, lines, gain=2.0):
    """Replace the text of each sparse block by the classic-OCR text inside its box when that holds at least `gain` times more characters."""
    count = lambda t: sum(not c.isspace() for c in t)
    for b in sparse_blocks(blocks):
        new = block_stream(lines, b["block_bbox"])[0].strip()
        if count(new) >= gain * count(b["block_content"]):
            b["block_content"] = new
    return blocks


def merge_rects(boxes, pad=2):
    """Boxes of consecutive characters -> one rectangle [x, y, w, h] per text line (boxes on the same row are united)."""
    rows = []
    for b in boxes:
        for r in rows:
            if abs((r[1] + r[3]) / 2 - (b[1] + b[3]) / 2) < (r[3] - r[1]) * .6:
                r[:] = [min(r[0], b[0]), min(r[1], b[1]), max(r[2], b[2]), max(r[3], b[3])]
                break
        else:
            rows.append(list(b))
    return [[round(r[0] - pad), round(r[1] - pad), round(r[2] - r[0] + 2 * pad), round(r[3] - r[1] + 2 * pad)] for r in rows]


def move_rects_ocr(block_text, bbox, spans, lines):
    """Rectangles for each [start, end) span of block_text (the main OCR's text of the block at bbox), or None per span when the
    classic OCR does not read those characters. Needs 60 % of a span's characters aligned."""
    a = block_text.replace("\n", " ")
    b, boxes = block_stream(lines, bbox)
    if not b.strip():
        return [None] * len(spans)
    to_b = {}
    for blk in difflib.SequenceMatcher(None, a, b, autojunk=False).get_matching_blocks():
        for i in range(blk.size):
            to_b[blk.a + i] = blk.b + i
    out = []
    for s, e in spans:
        hit = [boxes[to_b[i]] for i in range(s, e) if i in to_b and boxes[to_b[i]] is not None]
        out.append(merge_rects(hit) if len(hit) >= 0.6 * (e - s) and hit else None)
    return out


def move_rects_textlayer(words, spans):
    """Rectangles for spans of a text-layer line block whose words are [[start, end, x0, y0, x1, y1], ...] (offsets in the line
    text): a span's rectangle is cut proportionally inside the first and last word it touches."""
    out = []
    for s, e in spans:
        hit = []
        for ws, we, x0, y0, x1, y1 in words:
            if we <= s or ws >= e:
                continue
            w = max(we - ws, 1)
            hit.append([x0 + (x1 - x0) * (max(s, ws) - ws) / w, y0, x0 + (x1 - x0) * (min(e, we) - ws) / w, y1])
        out.append(merge_rects(hit) if hit else None)
    return out


def selfcheck():
    """python wordboxes.py --check : a text block the main OCR cut short is refilled from the classic OCR lines inside its box."""
    def blk(y, text):
        return {"block_label": "text", "block_bbox": [0, y, 600, y + 400], "block_content": text}
    full = "1.e4 c5 2.Cf3 e6 3.c3 Cf6 4.e5 Cd5 " * 6
    blocks = [blk(0, full), blk(500, full), blk(1000, full), blk(1500, "Voici une partie.")]
    line = lambda y, t: {"pieces": [(t, [10.0, y, 500.0, y + 20.0])]}
    lines = [line(1510, "Voici une partie."), line(1540, full[:200]), line(1570, full[200:])]
    assert [b["block_bbox"][1] for b in sparse_blocks(blocks)] == [1500]
    fill_sparse(blocks, lines)
    assert blocks[3]["block_content"].startswith("Voici une partie. 1.e4 c5") and blocks[0]["block_content"] == full  # others untouched
    short = [blk(0, "ab"), blk(500, "cd")]  # fewer than 3 text blocks: no baseline to compare with
    assert sparse_blocks(short) == []
    print("wordboxes self-check ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["--check"]:
        selfcheck(); sys.exit()
    for ln in Classic().lines(sys.argv[1])[:10]:
        print(char_boxes([(t, b) for t, b in ln["pieces"]])[0])

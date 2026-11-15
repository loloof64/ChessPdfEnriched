"""Step 5: recover the piece letter of figurine moves in OCR'd table blocks (OCR drops or garbles the figurines).

Per book: cluster the figurine glyphs (k-means on pixels), a human names each cluster once (`names`), then every
table cell is rebuilt as <letter><SAN without piece>. A cell has a figurine iff its connected-component count is
one more than the number of move characters the OCR read (so pawn moves never get a letter).
Usage: figurines.py PAGE.png PAGE.json [...]   (prints cells; run from pipeline/)
"""
import json
import re
import sys

import cv2
import numpy as np
from sklearn.cluster import KMeans

SAN_CHARS = re.compile(r"[a-h1-8xO0=+#!?-]")  # chars that count as glyphs of the move itself
feat = lambda g: cv2.resize(g, (40, 48), interpolation=cv2.INTER_AREA).astype(np.float64).ravel() / 255


def first_blob(g):
    """Keep only the leftmost ink blob of a window (columns up to the first blank gap), so a neighbouring letter
    does not shift the distance. Ink is bright in g."""
    ink = (g > 127).sum(axis=0) > 0
    start = int(np.argmax(ink))
    gap = 0
    for x in range(start, g.shape[1]):
        gap = 0 if ink[x] else gap + 1
        if gap >= 2:
            out = g.copy(); out[:, x:] = 0
            return out
    return g


def table_cells(page, block):
    """[(ocr_text, first_glyph_image_or_None, n_components)] for each non-empty move cell, in reading order."""
    x0, y0, x1, y1 = block["block_bbox"]
    c = page[y0:y1, x0:x1]
    n, _, st, _ = cv2.connectedComponentsWithStats(cv2.threshold(c, 140, 255, cv2.THRESH_BINARY_INV)[1])
    comps = [st[i] for i in range(1, n) if st[i][3] >= 20 and st[i][2] >= 10 and st[i][0] >= 100]
    rows, last = {}, None
    for s in sorted(comps, key=lambda s: s[1] + s[3] / 2):
        cy = s[1] + s[3] / 2
        if last is None or cy - last > 25:  # new text row (rows are ~50 px apart, glyph centres within a row < 15)
            rows[len(rows)] = []
        rows[len(rows) - 1].append(s); last = cy
    ocr_rows = [re.findall(r"<td>(.*?)</td>", r)[1:] for r in re.findall(r"<tr>(.*?)</tr>", block["block_content"])]
    ocr_rows = [[t for t in r if t.strip() != "..."] for r in ocr_rows]
    out = []
    for texts, (_, cs) in zip(ocr_rows, sorted(rows.items())):
        cs.sort(key=lambda s: s[0])
        cells, cur = [], []
        for s in cs:
            if cur and s[0] - (cur[-1][0] + cur[-1][2]) > 60:
                cells.append(cur); cur = []
            cur.append(s)
        cells.append(cur)
        for t, cell in zip(texts, cells):
            x = min(s[0] for s in cell); ytop = min(s[1] for s in cell); ybot = max(s[1] + s[3] for s in cell)
            out.append((t, first_blob(255 - c[max(0, ytop - 3):ybot + 3, max(0, x - 2):x + 38]), len(cell)))  # ~one figurine wide
    return out


def is_figurine_like(g):
    """Tall, line-art glyph (letters and digits are bold and dense)."""
    return g.shape[0] >= 30 and (g > 127).mean() < .42


def calibrate(cells, picks):
    """Exemplar set from a few human-picked cells: picks = {"Q": [(page, ocr_text), ...], ...} -> [(letter, features)].
    ponytail: unsupervised k-means mixed rare classes (bishop with king) on ~45 samples; exemplars are robust and cost
    one pick per class per book (a reader dialog: "click the bishop")."""
    return [(letter, feat(g)) for letter, keys in picks.items() for p, t, g, _ in cells if (p, t) in set(map(tuple, keys))]


def piece_of(exemplars, g, cut=11):
    """Letter of the nearest exemplar, '' if too far (pawn move, castling, letter)."""
    f = feat(g)
    d, letter = min((np.linalg.norm(f - e), l) for l, e in exemplars)
    return letter if d <= cut else ""


if __name__ == "__main__":
    # args: picks.json then PAGE.png PAGE.json pairs ; picks.json = {"Q": [[3, "d3"]], ...}
    picks = json.load(open(sys.argv[1]))
    cells = []
    for png, js in zip(sys.argv[2::2], sys.argv[3::2]):
        page = cv2.imread(png, 0)
        p = int(re.search(r"p-(\d+)", png).group(1))
        cells += [(p, *c) for b in json.load(open(js)) if b["block_label"] == "table" for c in table_cells(page, b)]
    ex = calibrate(cells, picks)
    for p, t, g, n in cells:
        print(p, f"{t!r:10}", piece_of(ex, g) + "".join(SAN_CHARS.findall(t)))

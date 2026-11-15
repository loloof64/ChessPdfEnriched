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
            out.append((t, 255 - c[max(0, ytop - 3):ybot + 3, max(0, x - 2):x + 38], len(cell)))  # ~one figurine wide
    return out


def is_figurine_like(g):
    """Tall, line-art glyph (letters and digits are bold and dense)."""
    return g.shape[0] >= 30 and (g > 127).mean() < .30


def calibrate(cells, k=10):
    """k-means over the figurine-like first glyphs of all cells; returns (model, reject distance)."""
    X = np.array([feat(g) for _, g, _ in cells if is_figurine_like(g)])
    km = KMeans(k, n_init=10, random_state=0).fit(X)
    d = km.transform(X).min(axis=1)
    return km, float(np.percentile(d, 80) * 1.5)  # ponytail: 80th pct x 1.5 as outlier cut; tune with more books


def piece_of(km, cut, g, names):
    """Letter of a figurine glyph, '' if it is not one (pawn move, letter that slipped through)."""
    if not is_figurine_like(g):
        return ""
    d = km.transform([feat(g)])[0]
    return names[int(d.argmin())] if d.min() <= cut else ""


if __name__ == "__main__":
    cells = []
    for png, js in zip(sys.argv[1::2], sys.argv[2::2]):
        page = cv2.imread(png, 0)
        cells += [(png, *c) for b in json.load(open(js)) if b["block_label"] == "table" for c in table_cells(page, b)]
    km, cut = calibrate([c[1:] for c in cells])
    names = json.load(open("work/fig_names.json")) if len(sys.argv) > 0 and __import__("os").path.exists("work/fig_names.json") else None
    if names is None:  # first run: dump one sheet per cluster so a human can name them
        for k in range(km.n_clusters):
            tiles = [cv2.resize(255 - g, (48, 56)) for _, t, g, n in cells if is_figurine_like(g) and km.predict([feat(g)])[0] == k][:8]
            cv2.imwrite(f"work/name{k}.png", np.hstack(tiles))
        print("wrote work/name*.png; create work/fig_names.json as [letter per cluster]")
    else:
        for png, t, g, n in cells:
            print(png[-7:], f"{t!r:10}", piece_of(km, cut, g, names) + "".join(SAN_CHARS.findall(t)))

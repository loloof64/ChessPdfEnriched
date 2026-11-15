"""Step 5b: recover figurine letters in running text (OCR turns each figurine into a garbage symbol, or drops it).

For a text block: split the page crop into lines and words, find the words whose first blob looks like a figurine
(tight-bbox nearest exemplar), then replace the OCR's garbage-prefixed moves, in order, with the piece letters.
If the two counts differ the block is returned unchanged with ok=False (goes to the reader's "to review" list).
Usage: inline.py picks.json p-N.png p-N.json [...]
"""
import json
import re
import sys

import cv2
import numpy as np

from figurines import calibrate, table_cells

CUT = 14.0  # figurines 8-13, letters >= 16 on PartiesFischer (3 lines)
GARBAGE_MOVE = re.compile(r"[^\x00-\x7f]+\s?(?=x?[a-h][1-8])")  # symbol(s) glued to a square, e.g. '☠xd5', 'w e3'


def tight(g):
    ys, xs = np.where(g > 127)
    return g[ys.min():ys.max() + 1, xs.min():xs.max() + 1]


def tfeat(g):
    return cv2.resize(tight(g), (32, 40), interpolation=cv2.INTER_AREA).astype(np.float64).ravel() / 255


def exemplars(pages, picks):
    """pages: [(page_no, png, json_path)]. Same human picks as figurines.py, features on the tight bbox."""
    cells = []
    for n, png, js in pages:
        img = cv2.imread(png, 0)
        cells += [(n, *t) for b in json.load(open(js)) if b["block_label"] == "table" for t in table_cells(img, b)]
    keys = {(p, t): l for l, ks in picks.items() if l for p, t in ks}
    return [(keys[(p, t)], tfeat(g)) for p, t, g, _ in cells if (p, t) in keys]


def figurines_in(crop, ex):
    """Piece letters of the figurines in a text-block crop, in reading order."""
    bw = (crop < 140).astype(np.uint8)
    rows = bw.sum(axis=1) > 0
    lines, start = [], None
    for y, r in enumerate(np.append(rows, False)):
        if r and start is None:
            start = y
        if not r and start is not None:
            if y - start > 12:
                lines.append((start, y))
            start = None
    found = []
    for a, e in lines:
        L = bw[a:e]
        cols = L.sum(axis=0) > 0
        words, s, gap, last = [], None, 0, 0
        for x, v in enumerate(cols):
            if v:
                s = x if s is None else s
                gap, last = 0, x
            elif s is not None:
                gap += 1
                if gap > 9:  # ponytail: fixed word gap in px (200 dpi); scale with line height for other scans
                    words.append((s, last + 1)); s = None
        if s is not None:
            words.append((s, last + 1))
        for ws, we in words:
            x = ws
            while x < we and cols[x]:
                x += 1  # first blob = columns until the first blank one
            g = (L[:, ws:x] * 255).astype(np.uint8)
            if g.sum() == 0 or tight(g).shape[0] < .5 * (e - a):
                continue
            d, letter = min((np.linalg.norm(tfeat(g) - f), l) for l, f in ex)
            if d <= CUT:
                found.append(letter)
    return found


def recover(page, block, ex):
    """(text with piece letters, ok)."""
    x0, y0, x1, y1 = block["block_bbox"]
    letters = figurines_in(page[y0:y1, x0:x1], ex)
    text = block["block_content"]
    marks = list(GARBAGE_MOVE.finditer(text))
    if len(marks) != len(letters):
        return text, False
    out, last = [], 0
    for m, l in zip(marks, letters):
        out += [text[last:m.start()], l]; last = m.end()
    return "".join(out) + text[last:], True


if __name__ == "__main__":
    picks = json.load(open(sys.argv[1]))
    trip = [(int(re.search(r"p-(\d+)", p).group(1)), p, j) for p, j in zip(sys.argv[2::2], sys.argv[3::2])]
    ex = exemplars(trip, picks)
    for n, png, js in trip:
        img = cv2.imread(png, 0)
        for b in json.load(open(js)):
            if b["block_label"] in ("text", "paragraph_title"):
                t, ok = recover(img, b, ex)
                print(n, "OK " if ok else "REV", t[:230].replace("\n", " "))

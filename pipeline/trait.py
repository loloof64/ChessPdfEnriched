"""Whose turn is it in a printed diagram? Books draw a dot beside the board: filled or hollow.

The dot lies OUTSIDE the diagram's own image (the OCR box cuts it), so it is looked for on the page image, in the margin
around the right side of the diagram's box. `dot_fill(page_img, bbox)` says 'filled' / 'hollow' / None. What each means
(top = White, bottom = Black) is checked against diagrams whose turn is known from the game: see __main__.
"""
import sys

import cv2
import numpy as np
from PIL import Image


def dot_turn(page: Image.Image, bbox, flipped=True):
    """'w' / 'b' / None: whose turn the dot beside the diagram says, for a diagram whose box on the page is bbox = [x, y, w, h] (px).
    `flipped`: Black is at the bottom of the printed diagram (the dot lies at the edge of the side to move: the top rank then is White's).
    The book puts a round dot at the right of the board (sometimes inside the OCR box's right edge, sometimes beyond it), level with the rank of the side to
    move: White's side is the bottom of the diagram, or the top when it is printed with Black at the bottom. The ring is thin and pale, so the position,
    not the fill, is what is read."""
    x, y, w, h = bbox
    px0, px1 = max(0, int(x + .85 * w)), min(page.width, int(x + w + .4 * w))
    py0, py1 = max(0, int(y - .1 * h)), min(page.height, int(y + 1.1 * h))
    g = np.asarray(page.convert("L"))[py0:py1, px0:px1]
    found = []
    for thr in (140, 215, 235, 248):  # filled dot, then ever paler rings (the page images are blurry upscaled screenshots)
        mask = cv2.morphologyEx((g < thr).astype(np.uint8), cv2.MORPH_CLOSE, np.ones((3, 3), np.uint8))  # joins a broken ring
        cs, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        for k in cs:
            bx, by, bw, bh = cv2.boundingRect(k)
            cx, cy = px0 + bx + bw / 2, py0 + by + bh / 2
            if (.04 * w <= bw <= .1 * w and .8 <= bw / max(bh, 1) <= 1.25 and cv2.contourArea(k) >= .6 * np.pi / 4 * bw * bh
                    and cx > x + .93 * w and y - .08 * h <= cy <= y + 1.08 * h):
                found.append(cy)
        if found:
            break
    if len(found) != 1:  # none, or ambiguous
        return None
    return "w" if ((found[0] - y) / h < .5) == flipped else "b"


def selfcheck():
    """python trait.py --check : the dot sits at the edge of the side to move, so its meaning depends on which army is at the bottom."""
    from PIL import ImageDraw
    def page_with_dot(top):
        im = Image.new("RGB", (400, 400), "white")
        cy = 62 if top else 238
        ImageDraw.Draw(im).ellipse([250, cy - 8, 266, cy + 8], fill="black")
        return im
    box = [50, 50, 200, 200]  # the diagram; the dot lies in the margin to its right, level with the top or the bottom rank
    assert dot_turn(page_with_dot(True), box, flipped=True) == "w" and dot_turn(page_with_dot(False), box, flipped=True) == "b"  # Black at the bottom
    assert dot_turn(page_with_dot(False), box, flipped=False) == "w" and dot_turn(page_with_dot(True), box, flipped=False) == "b"  # White at the bottom
    assert dot_turn(Image.new("RGB", (400, 400), "white"), box, flipped=False) is None
    print("trait self-check ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["--check"]:
        selfcheck()
        raise SystemExit
    import io
    import json
    import sys
    import zipfile
    agree = total = 0
    for book in sys.argv[1:]:
        z = zipfile.ZipFile(book)
        for n in sorted(int(f[7:11]) for f in z.namelist() if f.startswith("pages/p")):
            d = json.loads(z.read(f"pages/p{n:04d}.json"))
            fen = {m["id"]: m["fen"] for m in d["moves"] if m["ok"]}
            allfen = {}
            for f in z.namelist():
                if f.startswith("pages/p"):
                    allfen.update({m["id"]: m["fen"] for m in json.loads(z.read(f))["moves"] if m["ok"]})
            page = Image.open(io.BytesIO(z.read(f"scans/p{n:04d}.png"))).convert("RGB")
            for g in d["diagrams"]:
                if not g.get("fen"):
                    continue
                dot = dot_turn(page, g["bbox"], g.get("flipped") is not False)
                hit = g.get("matches_move")
                turn = allfen[hit].split()[1] if hit in allfen else None
                total += turn is not None and dot is not None
                agree += turn is not None and dot is not None and dot == turn
                print(f"{book[-30:]} {g['id']} dot={dot} game turn={turn}")
    print("dot agrees with the game:", agree, "/", total)

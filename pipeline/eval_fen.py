"""Step 4.4: per-square error of read_fen on hand-checked diagrams, with and without neutralize.

Usage: eval_fen.py   (run from pipeline/, needs work/fenify-gpu.pt and work/am1/*.png)
Truth FENs are in DISPLAY orientation (what fenify reads), written by Claude from the images.
Source: attaque_minorite_1.pdf p2, extracted with `pdfimages -png`; diagrams 2-5 are black-at-bottom.
"""
import chess
import torch
from PIL import Image

from neutralize import neutralize
from plausibility import issues
from read_fen import read_board

# Board interior crop proportions: valid for this book only (see NEXT_SESSION.md).
CROP = (.059, .058, .946, .936)
TRUTH = {
    "img-004": "6k1/pp6/2p5/3p4/1P1P4/8/P7/6K1",
    "img-005": "6k1/1p3ppp/p1p5/1P1p4/P2P4/4P3/5PPP/6K1",
    "img-006": "1K6/PPP3PP/5P2/4P1p1/4p2p/3p4/ppp5/1k6",
    "img-007": "1K6/PPP3PP/8/4P2p/4p3/3p4/ppp5/1k6",
    "img-008": "1K6/PPP4P/6P1/5P2/4P1p1/4p2p/pppp4/1k6",
    "img-009": "1K6/PPP4P/6P1/5Pp1/4P2p/4p3/pppp4/1k6",
}


def errors(read: chess.Board, truth: chess.Board):
    """(ghosts, missing, wrong): piece read on an empty square / piece not read / other piece read."""
    g = m = w = 0
    for sq in chess.SQUARES:
        r, t = read.piece_at(sq), truth.piece_at(sq)
        if r == t:
            continue
        if t is None:
            g += 1
        elif r is None:
            m += 1
        else:
            w += 1
    return g, m, w


if __name__ == "__main__":
    model = torch.jit.load("work/fenify-gpu.pt", map_location="cpu").eval()
    n_pieces = sum(c.isalpha() for f in TRUTH.values() for c in f)
    tot = {False: [0, 0, 0], True: [0, 0, 0]}
    for name, fen in TRUTH.items():
        im = Image.open(f"work/am1/{name}.png").convert("RGB")
        w, h = im.size
        im = im.crop((round(CROP[0] * w), round(CROP[1] * h), round(CROP[2] * w), round(CROP[3] * h)))
        truth = chess.Board(None)
        truth.set_board_fen(fen)
        row = [name]
        for clean in (False, True):
            read = read_board(model, neutralize(im) if clean else im)
            e = errors(read, truth)
            tot[clean] = [a + b for a, b in zip(tot[clean], e)]
            row.append(f"{'clean' if clean else 'raw  '} ghost/miss/wrong={e} flagged={issues(read) or '-'}")
        print(*row)
    for clean, e in tot.items():
        print("TOTAL", "clean" if clean else "raw  ", "ghost/miss/wrong =", tuple(e), "of", n_pieces, "pieces")

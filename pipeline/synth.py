"""Step 4.5: synthetic training boards = book wood backgrounds + random piece sets + highlights/arrows.

Backgrounds come from EMPTY, unhighlighted squares of the first two reference diagrams (img-004, img-005)
and from chessground board images; pieces come from the chessground piece sets (all piece types).
Label layout matches fenify: index = rank*8 + file with rank 0 at the image BOTTOM; class 0 empty,
1..6 white P N B R Q K, 7..12 black.
"""
import glob
import os
import random

import chess
import cv2
import numpy as np
from PIL import Image

from eval_fen import CROP, TRUTH

ASSETS = os.path.expanduser("~/.pub-cache/hosted/pub.dev/chessground-11.0.0/assets")
BOOK_SOURCES = ("img-004", "img-005")  # diagrams 006-009 stay held out for evaluation
# small hatched diagrams of structure_francaise_t1 (dark squares hatched): real squares of the two diagrams whose position is known.
# p1_d2 (truth 6k1/ppp3pp/4p3/3pN3/3P4/8/PPP2PPP/6K1) stays held out for evaluation.
HATCH_SOURCES = {"p1_d1": "6k1/ppp3pp/4p3/3p4/3P4/8/PPP2PPP/6K1", "p4_d2": "6k1/ppp3pp/8/3pp3/3P4/8/PPP2PPP/6K1"}
HATCH_DIR = "work/structure_francaise_t1/diagrams"
SQ = 64  # background tile size
TYPES = {"P": 1, "N": 2, "B": 3, "R": 4, "Q": 5, "K": 6}


def _squares(img: Image.Image):
    """Cut a board interior into 8x8 (row 0 = top) tiles of the array."""
    a = np.asarray(img.convert("RGB"))
    h, w, _ = a.shape
    return [[a[r * h // 8:(r + 1) * h // 8, c * w // 8:(c + 1) * w // 8] for c in range(8)] for r in range(8)]


def _book_tiles():
    tiles = {0: [], 1: []}  # parity 0 light, 1 dark
    pieces = {}  # (piece symbol, parity) -> real square tiles holding that piece
    for name in BOOK_SOURCES:
        im = Image.open(f"work/am1/{name}.png").convert("RGB")
        w, h = im.size
        im = im.crop((round(CROP[0] * w), round(CROP[1] * h), round(CROP[2] * w), round(CROP[3] * h)))
        truth = chess.Board(None)
        truth.set_board_fen(TRUTH[name])
        grid = _squares(im)
        for r in range(8):
            for c in range(8):
                piece = truth.piece_at((7 - r) * 8 + c)
                if piece is None:
                    tiles[(r + c) % 2].append(grid[r][c])
                else:
                    pieces.setdefault((piece.symbol(), (r + c) % 2), []).append(grid[r][c])
    # drop tiles polluted by arrows/highlights: keep those near the per-parity median colour
    for p, ts in tiles.items():
        med = np.median([t.reshape(-1, 3).mean(0) for t in ts], axis=0)
        tiles[p] = [t for t in ts if np.linalg.norm(t.reshape(-1, 3).mean(0) - med) < 20]
    # drop piece tiles holding a bright saturated highlight/arrow (bright yellow/red, never wood or pieces)
    def polluted(t):
        t = t.astype(float)
        mx, mn = t.max(2), t.min(2)
        return (((mx - mn) / np.maximum(mx, 1) > 0.75) & (mx > 200)).mean() > 0.01

    pieces = {k: [t for t in ts if not polluted(t)] for k, ts in pieces.items()}
    return tiles, {k: v for k, v in pieces.items() if v}


def _hatch_tiles():
    """(empty tiles by parity, piece tiles by (symbol, parity)) cut from the real hatched diagrams; the board box comes from autocrop."""
    import autocrop
    empty, pieces = {0: [], 1: []}, {}
    for name, fen in HATCH_SOURCES.items():
        im = Image.open(f"{HATCH_DIR}/{name}.png").convert("RGB")
        x0, y0, x1, y1, _ = autocrop.find_board(im)
        grid = _squares(im.crop((x0, y0, x1, y1)))
        truth = chess.Board(None)
        truth.set_board_fen(fen)
        for r in range(8):
            for c in range(8):
                t = grid[r][c].astype(int)
                if ((t[..., 0] > 180) & (t[..., 1] < 100)).any():  # the red side-to-move dot sits under the board
                    continue
                piece = truth.piece_at((7 - r) * 8 + c)
                if piece is None:
                    empty[(r + c) % 2].append(grid[r][c])
                else:
                    pieces.setdefault((piece.symbol(), (r + c) % 2), []).append(grid[r][c])
    return empty, pieces


def _piece_sets():
    sets = []
    for d in sorted(glob.glob(f"{ASSETS}/piece_sets/*")):
        files = {os.path.basename(f)[:2]: f for f in glob.glob(f"{d}/3.0x/*.webp")}
        if len(files) == 12:
            sets.append({k: Image.open(v).convert("RGBA") for k, v in files.items()})
    return sets


class Synth:
    def __init__(self):
        self.tiles, self.real_pieces = _book_tiles()
        self.hatch_empty, self.hatch_pieces = _hatch_tiles()
        self.sets = _piece_sets()
        self.boards = [Image.open(f).convert("RGB") for f in glob.glob(f"{ASSETS}/boards/*.jpg")]

    def _background(self, rng, s):
        if rng.random() < 0.7:  # book wood
            grid = [[cv2.resize(rng.choice(self.tiles[(r + c) % 2]), (s, s)) for c in range(8)] for r in range(8)]
            return np.vstack([np.hstack(row) for row in grid])
        b = rng.choice(self.boards).resize((8 * s, 8 * s))
        return np.asarray(b).copy()

    @staticmethod
    def _hatched(rng, s):
        """Black-and-white book print: white light squares, dark squares = white with thin diagonal lines (drawn large, then
        shrunk so the lines come out anti-aliased like a small printed diagram)."""
        k = 4
        n = 8 * s * k
        y, x = np.mgrid[0:n, 0:n]
        period = rng.uniform(2.5, 4.5) * k
        d = (x + y) if rng.random() < 0.5 else (x - y)
        lines = (d % period) < period * rng.uniform(0.35, 0.6)
        dark = ((y // (s * k)) + (x // (s * k))) % 2 == 1
        img = np.full((n, n, 3), rng.randint(235, 255), np.uint8)
        img[dark & lines] = rng.randint(0, 60)
        return cv2.resize(img, (8 * s, 8 * s), interpolation=cv2.INTER_AREA)

    def sample(self, seed=None):
        rng = random.Random(seed)
        hatched = rng.random() < 0.25  # small hatched print (cells of ~20 px), as in some books
        s = rng.randint(18, 30) if hatched else rng.randint(40, 64)
        if hatched and rng.random() < 0.5:  # real hatched squares
            img = np.vstack([np.hstack([cv2.resize(rng.choice(self.hatch_empty[(r + c) % 2]), (s, s)) for c in range(8)]) for r in range(8)])
        else:
            img = self._hatched(rng, s) if hatched else self._background(rng, s)
        # highlighted squares (under pieces)
        for _ in range(0 if hatched else rng.choice([0, 0, 1, 2, 3])):
            r, c = rng.randrange(8), rng.randrange(8)
            col = rng.choice([(235, 190, 30), (245, 60, 50), (250, 100, 90), (240, 210, 40)])
            col = np.clip(np.array(col) + np.random.randint(-15, 15, 3), 0, 255)
            a = rng.uniform(0.8, 1.0)
            reg = img[r * s:(r + 1) * s, c * s:(c + 1) * s]
            reg[:] = (a * col + (1 - a) * reg).astype(np.uint8)
        # random position
        labels = [0] * 64
        board = Image.fromarray(img).convert("RGBA")
        pset = rng.choice(self.sets)
        squares = [(r, c) for r in range(8) for c in range(8)]
        rng.shuffle(squares)
        n = rng.randint(2, 30)
        kings = squares[:2]
        others = squares[2:n]
        placed = [(kings[0], "wK"), (kings[1], "bK")]
        for (r, c) in others:
            if r in (0, 7):  # no pawns on back ranks; keep it simple: pawns only elsewhere
                kind = rng.choice("NBRQ")
            else:
                kind = rng.choice("PPPNBRQ")
            placed.append(((r, c), rng.choice("wb") + kind))
        for (r, c), key in placed:
            labels[(7 - r) * 8 + c] = TYPES[key[1]] + (0 if key[0] == "w" else 6)
            real = (self.hatch_pieces if hatched else self.real_pieces).get((key[1] if key[0] == "w" else key[1].lower(), (r + c) % 2))
            if real and rng.random() < 0.5:  # real book glyph, on its own background
                img_np = np.asarray(board.convert("RGB")).copy()
                img_np[r * s:(r + 1) * s, c * s:(c + 1) * s] = cv2.resize(rng.choice(real), (s, s))
                board = Image.fromarray(img_np).convert("RGBA")
                continue
            p = pset[key].resize((int(s * rng.uniform(0.85, 1.0)),) * 2)
            ox = c * s + (s - p.width) // 2 + rng.randint(-2, 2)
            oy = r * s + (s - p.height) // 2 + rng.randint(-2, 2)
            board.alpha_composite(p, (max(ox, 0), max(oy, 0)))
        img = np.asarray(board.convert("RGB")).copy()
        # arrows (over pieces)
        for _ in range(0 if hatched else rng.choice([0, 0, 1, 2])):  # black-and-white print: no arrows
            (r0, c0), (r1, c1) = rng.sample(squares, 2)
            col = rng.choice([(215, 175, 20), (200, 40, 40), (225, 190, 30)])
            p0 = np.array([c0 * s + s / 2, r0 * s + s / 2])
            p1 = np.array([c1 * s + s / 2, r1 * s + s / 2])
            ov = img.copy()
            d = (p1 - p0) / max(np.linalg.norm(p1 - p0), 1)
            n_ = np.array([-d[1], d[0]])
            w = s * rng.uniform(0.07, 0.14)
            tail = p1 - d * s * 0.35
            cv2.line(ov, tuple(p0.astype(int)), tuple(tail.astype(int)), col, max(int(w * 2), 1), cv2.LINE_AA)
            head = np.array([p1, tail + n_ * w * 2.2, tail - n_ * w * 2.2]).astype(np.int32)
            cv2.fillConvexPoly(ov, head, col, cv2.LINE_AA)
            img = cv2.addWeighted(ov, 0.9, img, 0.1, 0)
        # crop jitter: board interior is cropped by hand-made proportions in practice
        m = int(s * rng.uniform(0, 0.15))
        img = img[rng.randint(0, m):img.shape[0] - rng.randint(0, m), rng.randint(0, m):img.shape[1] - rng.randint(0, m)]
        if hatched or rng.random() < 0.5:  # mild blur/noise like a scan
            img = cv2.GaussianBlur(img, (3, 3), rng.uniform(0.3, 1.0))
        return Image.fromarray(img), labels


if __name__ == "__main__":
    g = Synth()
    print(len(g.tiles[0]), len(g.tiles[1]), "tiles;", {k: len(v) for k, v in g.real_pieces.items()}, "real piece tiles;", {k: len(v) for k, v in g.hatch_pieces.items()}, "hatched piece tiles;", len(g.sets), "piece sets;", len(g.boards), "boards")
    sheet = Image.new("RGB", (4 * 300, 2 * 300))
    for i in range(8):
        im, lab = g.sample(i)
        assert len(lab) == 64 and sum(1 for x in lab if x in (6, 12)) == 2
        sheet.paste(im.resize((300, 300)), ((i % 4) * 300, (i // 4) * 300))
    sheet.save("work/synth_sheet.png")

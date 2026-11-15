"""Step 4.7: find the 8x8 playing area inside a diagram image (frame, coordinates and margins removed).

Searches the square (x, y, size) whose 64 cells best follow a checkerboard luminance pattern, measured on
cell-corner patches only (pieces sit in the cell centre). Works for wood, flat and hatched-scan boards.
"""
import numpy as np
from PIL import Image


def _score(ii, x, y, s, p):
    """Checker contrast of squares at (x, y, s); vectorised over arrays x, y, s (cell size c = s/8, patch p*c)."""
    c = s / 8.0
    m = np.zeros(x.shape + (8, 8))
    for i in range(8):
        for j in range(8):
            acc = 0
            for fx in (.12, 1 - .12 - p):
                for fy in (.12, 1 - .12 - p):
                    x0 = np.rint(x + (j + fx) * c).astype(int); y0 = np.rint(y + (i + fy) * c).astype(int)
                    x1 = np.rint(x + (j + fx + p) * c).astype(int); y1 = np.rint(y + (i + fy + p) * c).astype(int)
                    area = np.maximum((x1 - x0) * (y1 - y0), 1)
                    acc = acc + (ii[y1, x1] - ii[y0, x1] - ii[y1, x0] + ii[y0, x0]) / area
            m[..., i, j] = acc / 4
    chk = np.fromfunction(lambda i, j: (-1.0) ** (i + j), (8, 8))
    d = m - m.mean(axis=(-1, -2), keepdims=True)
    return np.abs((d * chk).sum(axis=(-1, -2))) / (np.abs(d).sum(axis=(-1, -2)) + 1e-6) * np.log1p(np.abs((d * chk).sum(axis=(-1, -2))))


def _search(g, xs, ys, ss, p=.22):
    ii = np.pad(g.cumsum(0).cumsum(1), ((1, 0), (1, 0)))
    X, Y, S = np.meshgrid(xs, ys, ss, indexing="ij")
    ok = (X + S < g.shape[1] + 1) & (Y + S < g.shape[0] + 1)
    X, Y, S = X[ok], Y[ok], S[ok]
    sc = _score(ii, X, Y, S.astype(float), p)
    k = int(sc.argmax())
    return int(X[k]), int(Y[k]), int(S[k]), float(sc[k])


def find_board(img: Image.Image):
    """(x0, y0, x1, y1, score) of the playing area in img pixels. Low score = no clear board found."""
    g0 = np.asarray(img.convert("L"), dtype=float)
    f = max(1, round(max(g0.shape) / 220))
    small = np.asarray(img.convert("L").resize((g0.shape[1] // f, g0.shape[0] // f), Image.BILINEAR), dtype=float)
    h, w = small.shape
    x, y, s, _ = _search(small, range(0, w // 3), range(0, h // 3), range(int(min(w, h) * .55), min(w, h) + 1))
    x, y, s = x * f, y * f, s * f
    r = f + 1
    x, y, s, sc = _search(g0, range(max(0, x - r), x + r + 1), range(max(0, y - r), y + r + 1), range(max(8, s - r), s + r + 1))
    return x, y, x + s, y + s, sc


if __name__ == "__main__":
    import glob
    for fn in sorted(glob.glob("work/am1/img-00[4-9].png")) + ["work/f60/b03.png", "work/f60/b13.png"]:
        im = Image.open(fn); w, h = im.size
        x0, y0, x1, y1, sc = find_board(im)
        print(fn, im.size, (x0, y0, x1, y1), "fixed-prop crop:", (round(.059 * w), round(.058 * h), round(.946 * w), round(.936 * h)), f"score {sc:.2f}")

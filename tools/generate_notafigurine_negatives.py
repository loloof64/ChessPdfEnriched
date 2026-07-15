#!/usr/bin/env python3
"""Generate hard-negative crops for the "NotAFigurine" class.

Context
-------
`figurine_classifier.tflite` is currently a 5-class softmax {K,Q,R,B,N} with no
reject class, so it emits ~100% confidence for *any* input — including blank
crops, rank digits and letters — which is the root cause of the false-positive
"figurines" seen on scanned chess PDFs. The fix is to retrain it as a 6-class
model {K,Q,R,B,N,NotAFigurine}. This script produces the NotAFigurine class:
32x32 grayscale PNGs of things that are NOT chess pieces but that the CV
segmenter actually hands to the classifier.

It mirrors the conventions of `generate_synthetic_writing_elements.ipynb`
(system-font rendering, 32x32, augmentation) but is a standalone, portable
script (no google.colab / input()) and adds the two failure modes that book's
generator misses: blank/near-blank crops and mis-segmentation fragments. All
crops get scan-like degradation so they match the domain of the positive
glyphs (which are cropped from degraded scanned pages, not clean renders).

Output layout (ready to drop into the training zip as glyphs/NotAFigurine/):
    <out>/NotAFigurine/neg_000001.png ...

Usage
-----
    python3 tools/generate_notafigurine_negatives.py --out ./negatives --count 30000
Requires: pillow, numpy  (preinstalled on Colab; locally: apt install
python3-pil python3-numpy, or pip install pillow numpy).
"""

from __future__ import annotations

import argparse
import os
import random
import string
import sys

try:
    import numpy as np
    from PIL import Image, ImageDraw, ImageFont, ImageFilter
except ImportError as e:  # pragma: no cover - environment guard
    sys.exit(
        f"Missing dependency: {e.name}. Install with "
        "`pip install pillow numpy` (or apt install python3-pil python3-numpy)."
    )

IMG_SIZE = 32

# Characters worth over-weighting: these are exactly what sits next to piece
# glyphs in figurine move notation, so they are the negatives most likely to be
# mistaken for a piece by the current model. Kept as its own pool so we can
# sample it more often than the general alphabet.
NOTATION_CHARS = list("abcdefgh12345678x+#=!?O0-.,")
GENERAL_CHARS = (
    list(string.ascii_lowercase)
    + list(string.ascii_uppercase)
    + list(string.digits)
    + list(".,!?;:'\"()[]{}/-_%&@")
)

FONT_SEARCH_DIRS = [
    "/usr/share/fonts/truetype/dejavu",
    "/usr/share/fonts/truetype/liberation",
    "/usr/share/fonts/truetype/liberation2",
    "/usr/share/fonts",  # recursive fallback
]


def discover_fonts(max_fonts: int = 24) -> list[str]:
    """Return a spread of .ttf paths from the system font dirs."""
    found: list[str] = []
    seen: set[str] = set()
    for d in FONT_SEARCH_DIRS:
        if not os.path.isdir(d):
            continue
        for root, _dirs, files in os.walk(d):
            for f in sorted(files):
                if f.lower().endswith(".ttf") and f not in seen:
                    seen.add(f)
                    found.append(os.path.join(root, f))
        if len(found) >= max_fonts:
            break
    if not found:
        sys.exit(
            "No .ttf fonts found under "
            + ", ".join(FONT_SEARCH_DIRS)
            + ". Install e.g. fonts-dejavu / fonts-liberation."
        )
    return found[:max_fonts]


def _degrade(arr: np.ndarray, rng: random.Random) -> np.ndarray:
    """Apply scan-like degradation to a [0,1] float32 32x32 array.

    Mimics the artifacts of the positive glyphs (cropped from scanned,
    OCR-layer book pages): soft focus, sensor/paper grain, uneven exposure,
    and occasional bilevel-then-blur (halftone-ish) rendering.
    """
    a = arr

    # Random light background level (scans are rarely pure white).
    bg = rng.uniform(0.85, 1.0)
    a = np.clip(a * bg + (1.0 - bg) * 0.0, 0.0, 1.0)

    # Contrast / brightness jitter.
    contrast = rng.uniform(0.7, 1.3)
    a = np.clip((a - 0.5) * contrast + 0.5 + rng.uniform(-0.1, 0.1), 0.0, 1.0)

    # Occasional binarize-then-soften (halftone/photocopy look). Keep polarity
    # (dark ink on light paper): pixels at/above the threshold stay light(1.0),
    # below go dark(0.0) — the opposite would invert to white-on-black.
    if rng.random() < 0.3:
        a = (a >= rng.uniform(0.45, 0.65)).astype(np.float32)

    # Gaussian blur (scan softness), applied via PIL for a real kernel.
    if rng.random() < 0.8:
        radius = rng.uniform(0.3, 1.1)
        pil = Image.fromarray((a * 255).astype(np.uint8))
        pil = pil.filter(ImageFilter.GaussianBlur(radius))
        a = np.asarray(pil, dtype=np.float32) / 255.0

    # Additive Gaussian grain.
    if rng.random() < 0.8:
        sigma = rng.uniform(0.01, 0.06)
        a = np.clip(a + np.random.normal(0.0, sigma, a.shape), 0.0, 1.0)

    # Sparse salt-and-pepper.
    if rng.random() < 0.3:
        n = int(a.size * rng.uniform(0.003, 0.02))
        ys = np.random.randint(0, a.shape[0], n)
        xs = np.random.randint(0, a.shape[1], n)
        a[ys, xs] = np.where(np.random.random(n) < 0.5, 0.0, 1.0)

    return a.astype(np.float32)


def _render_char(ch: str, font: ImageFont.FreeTypeFont, rng: random.Random) -> np.ndarray:
    """Render a single character to a 32x32 [0,1] array with position/scale jitter."""
    # Render large then paste with jitter so glyphs land at varied positions.
    canvas = Image.new("L", (IMG_SIZE, IMG_SIZE), color=255)
    draw = ImageDraw.Draw(canvas)
    try:
        bbox = draw.textbbox((0, 0), ch, font=font)
    except Exception:
        bbox = (0, 0, IMG_SIZE // 2, IMG_SIZE)
    gw, gh = max(1, bbox[2] - bbox[0]), max(1, bbox[3] - bbox[1])
    # Center with jitter.
    jx = rng.randint(-3, 3)
    jy = rng.randint(-3, 3)
    px = (IMG_SIZE - gw) // 2 - bbox[0] + jx
    py = (IMG_SIZE - gh) // 2 - bbox[1] + jy
    draw.text((px, py), ch, fill=rng.randint(0, 70), font=font)

    # Small rotation (notation isn't heavily rotated, unlike piece augmentation).
    if rng.random() < 0.6:
        canvas = canvas.rotate(
            rng.uniform(-12, 12), resample=Image.BICUBIC, fillcolor=255
        )
    return np.asarray(canvas, dtype=np.float32) / 255.0


def _tight_crop(arr: np.ndarray, rng: random.Random) -> np.ndarray:
    """Crop [arr] to its ink bounding box plus a small random margin.

    CRITICAL: the classifier's feature vector includes an aspect-ratio term
    (origW/origH of the saved crop, see hog_extractor.dart / the training
    notebook). Positive glyphs are saved at their NATIVE crop size, so their
    aspect ratio varies by piece. If negatives were all saved at a fixed
    square 32x32, aspect would be a constant 1.0 for the whole class and the
    model would learn "aspect==1.0 -> NotAFigurine" — a spurious shortcut that
    does not transfer to inference (where element_parser passes the real crop
    w/h). Cropping to the glyph's true bbox gives negatives a realistic,
    varied aspect distribution (narrow 'l' ~0.3, wide 'm' ~1.1) matching how
    positives are stored.
    """
    ink = arr < 0.6  # pixels darker than mid-gray count as ink
    ys, xs = np.where(ink)
    if len(ys) == 0:  # no ink (e.g. degenerate fragment) — return as-is
        return arr
    top, bottom = ys.min(), ys.max()
    left, right = xs.min(), xs.max()
    my0, my1 = rng.randint(1, 5), rng.randint(1, 5)
    mx0, mx1 = rng.randint(1, 5), rng.randint(1, 5)
    h, w = arr.shape
    top = max(0, top - my0)
    bottom = min(h - 1, bottom + my1)
    left = max(0, left - mx0)
    right = min(w - 1, right + mx1)
    return arr[top : bottom + 1, left : right + 1]


def _make_blank(rng: random.Random) -> np.ndarray:
    """A blank / near-blank crop — the case the 5-class model calls 'R' at 100%.

    Sized at a random aspect (not fixed square) for the same aspect-ratio
    reason as _tight_crop: a whole class pinned to aspect 1.0 would be a
    give-away shortcut.
    """
    h = rng.randint(12, 34)
    w = max(4, int(h * rng.uniform(0.3, 1.4)))
    base = np.full((h, w), rng.uniform(0.9, 1.0), dtype=np.float32)
    # Optionally a faint smudge / partial stroke so it's not always pure flat.
    if rng.random() < 0.5:
        pil = Image.fromarray((base * 255).astype(np.uint8))
        d = ImageDraw.Draw(pil)
        for _ in range(rng.randint(1, 3)):
            x0, y0 = rng.randint(0, w - 1), rng.randint(0, h - 1)
            x1, y1 = rng.randint(0, w - 1), rng.randint(0, h - 1)
            d.line((x0, y0, x1, y1), fill=rng.randint(150, 220), width=1)
        base = np.asarray(pil, dtype=np.float32) / 255.0
    return base


def _make_fragment(
    chars: list[str], fonts: list[ImageFont.FreeTypeFont], rng: random.Random
) -> np.ndarray:
    """A mis-segmentation artifact: a partial glyph or two glued glyphs.

    These mimic what FigurineDetector's segmenter produces when glyphs touch
    with no gap — exactly the crops that currently reach the classifier as
    junk and get labeled 'R'.
    """
    kind = rng.random()
    if kind < 0.5:
        # Partial glyph: render one char then keep only a vertical slice.
        arr = _render_char(rng.choice(chars), rng.choice(fonts), rng)
        cut = rng.randint(8, 22)
        if rng.random() < 0.5:
            arr[:, cut:] = 1.0  # keep left part
        else:
            arr[:, :cut] = 1.0  # keep right part
        return arr
    else:
        # Two glued glyphs squeezed into one frame.
        a = _render_char(rng.choice(chars), rng.choice(fonts), rng)
        b = _render_char(rng.choice(chars), rng.choice(fonts), rng)
        shift = rng.randint(6, 14)
        out = np.ones((IMG_SIZE, IMG_SIZE), dtype=np.float32)
        out[:, : IMG_SIZE - shift] = np.minimum(
            out[:, : IMG_SIZE - shift], a[:, shift:]
        )
        out[:, shift:] = np.minimum(out[:, shift:], b[:, : IMG_SIZE - shift])
        return out


def generate(out_dir: str, count: int, seed: int) -> None:
    rng = random.Random(seed)
    np.random.seed(seed)

    font_paths = discover_fonts()
    # Load a few pixel sizes per font for scale variety.
    fonts: list[ImageFont.FreeTypeFont] = []
    for p in font_paths:
        for size in (20, 24, 28):
            try:
                fonts.append(ImageFont.truetype(p, size))
            except Exception:
                pass
    if not fonts:
        sys.exit("Could not load any TTF font.")
    print(f"Loaded {len(fonts)} font/size variants from {len(font_paths)} fonts")

    cls_dir = os.path.join(out_dir, "NotAFigurine")
    os.makedirs(cls_dir, exist_ok=True)

    # Composition of the negative set (sums to 1.0):
    #   55% notation-adjacent chars (highest value), 20% general text,
    #   15% mis-segmentation fragments, 10% blanks.
    p_notation, p_general, p_fragment = 0.55, 0.20, 0.15  # remainder = blanks

    written = 0
    for i in range(count):
        r = rng.random()
        if r < p_notation:
            arr = _tight_crop(
                _render_char(rng.choice(NOTATION_CHARS), rng.choice(fonts), rng), rng
            )
        elif r < p_notation + p_general:
            arr = _tight_crop(
                _render_char(rng.choice(GENERAL_CHARS), rng.choice(fonts), rng), rng
            )
        elif r < p_notation + p_general + p_fragment:
            arr = _tight_crop(
                _make_fragment(NOTATION_CHARS + GENERAL_CHARS, fonts, rng), rng
            )
        else:
            arr = _make_blank(rng)  # already variable-size

        # Saved at the crop's NATIVE (variable) size — do NOT resize to 32x32,
        # so the aspect-ratio feature stays meaningful (see _tight_crop).
        arr = _degrade(arr, rng)
        img = Image.fromarray((np.clip(arr, 0, 1) * 255).astype(np.uint8), mode="L")
        img.save(os.path.join(cls_dir, f"neg_{i:06d}.png"))
        written += 1
        if written % 5000 == 0:
            print(f"  {written}/{count}")

    print(f"\nDone: {written} NotAFigurine crops -> {cls_dir}")
    print("Add this folder into chess_glyphs_classifier.zip under glyphs/ and "
          "retrain with CLASS_NAMES=['K','Q','R','B','N','NotAFigurine'].")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", default="./negatives", help="output root dir")
    ap.add_argument("--count", type=int, default=30000, help="number of crops")
    ap.add_argument("--seed", type=int, default=42)
    args = ap.parse_args()
    generate(args.out, args.count, args.seed)


if __name__ == "__main__":
    main()

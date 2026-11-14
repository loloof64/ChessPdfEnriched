"""Step 4.1: replace highlight/arrow colours on a cropped board image by the plain square colours."""
import numpy as np
from PIL import Image
from scipy.ndimage import binary_dilation


def neutralize(img: Image.Image, dist: float = 60, sat: float = 0.5) -> Image.Image:
    """img = board interior only (8x8 squares, no frame). Square (0,0) = top-left = light."""
    a = np.asarray(img.convert("RGB")).astype(float)
    h, w, _ = a.shape
    ys, xs = np.mgrid[0:h, 0:w]
    parity = ((ys * 8 // h) + (xs * 8 // w)) % 2  # 0 light, 1 dark
    ref = np.stack([np.median(a[parity == p], axis=0) for p in (0, 1)])  # ponytail: median breaks if >half the squares are highlighted
    expected = ref[parity]
    mx, mn = a.max(2), a.min(2)
    # highlights are bright and saturated; pieces are grey or dark
    mask = ((mx - mn) / np.maximum(mx, 1) > sat) & (mx > 120) & (np.linalg.norm(a - expected, axis=2) > dist)
    # fringes: anti-aliased arrow/highlight edges next to the core mask
    soft = ((mx - mn) / np.maximum(mx, 1) > 0.3) & (mx > 150) & (np.linalg.norm(a - expected, axis=2) > dist / 2)
    mask = binary_dilation(mask, iterations=2) & soft | mask
    a[mask] = expected[mask]
    return Image.fromarray(a.astype(np.uint8))

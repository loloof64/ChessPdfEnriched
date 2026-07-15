#!/usr/bin/env python3
"""Harvest real in-domain NotAFigurine negatives from dumped .pgm crops.

The app dumps every 32x32 crop it classifies into figurine_crops/pageN/... as
.pgm files. That corpus (~27k crops for one book) is a goldmine of REAL,
domain-matched negatives — rank digits, file letters, punctuation, blanks and
mis-segmented fragments — but it is unlabeled and mixed with actual piece
glyphs, and it is far too large to sort by hand.

This tool makes the sort tractable by clustering. There are only a handful of
distinct piece shapes (K/Q/R/B/N x 2 colors x a few scales), so K-means groups
them into a few clusters while text/blank/fragment crops fall into others. You
review ONE montage per cluster (dozens of images, not tens of thousands) and
list which clusters to drop (pieces) or keep (negatives).

Workflow
--------
1. Cluster + build montages:
     python3 tools/harvest_pgm_negatives.py cluster \
         --crops ~/Documents/figurine_crops --work ./triage --k 80
   Then open ./triage/clusters/ in a file browser and note the cluster numbers.

2. Harvest — keep everything except the piece clusters you spotted:
     python3 tools/harvest_pgm_negatives.py harvest \
         --work ./triage --out ./negatives --exclude 4,17,23,50-52
   (or invert with --keep 1,2,3 to keep only listed clusters).

Output: <out>/NotAFigurine/real_000001.png ... (32x32 grayscale, same format
as the synthetic generator and the K/Q/R/B/N positive glyphs).

Requires: numpy, pillow, scikit-learn.
"""

from __future__ import annotations

import argparse
import os
import sys

try:
    import numpy as np
    from PIL import Image
    from sklearn.cluster import MiniBatchKMeans
except ImportError as e:  # pragma: no cover
    sys.exit(f"Missing dependency: {e.name}. Install numpy, pillow, scikit-learn.")

IMG_SIZE = 32


def read_pgm(path: str) -> np.ndarray | None:
    """Read a binary P5 PGM into a float32 [0,1] array of shape (H, W)."""
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError:
        return None
    pos = 0

    def token() -> bytes:
        nonlocal pos
        while pos < len(data) and data[pos : pos + 1].isspace():
            pos += 1
        start = pos
        while pos < len(data) and not data[pos : pos + 1].isspace():
            pos += 1
        return data[start:pos]

    if token() != b"P5":
        return None
    w = int(token())
    h = int(token())
    maxv = int(token())
    pos += 1  # single whitespace after maxval
    buf = data[pos : pos + w * h]
    if len(buf) != w * h:
        return None
    arr = np.frombuffer(buf, dtype=np.uint8).astype(np.float32) / maxv
    return arr.reshape(h, w)


def list_pgms(crops_dir: str) -> list[str]:
    out = []
    for root, _dirs, files in os.walk(crops_dir):
        for f in files:
            if f.lower().endswith(".pgm"):
                out.append(os.path.join(root, f))
    return sorted(out)


def cmd_cluster(args: argparse.Namespace) -> None:
    paths = list_pgms(args.crops)
    if not paths:
        sys.exit(f"No .pgm files found under {args.crops}")
    print(f"Found {len(paths)} .pgm crops. Loading...")

    feats = np.empty((len(paths), IMG_SIZE * IMG_SIZE), dtype=np.float32)
    kept_paths: list[str] = []
    w = 0
    for p in paths:
        a = read_pgm(p)
        if a is None or a.shape != (IMG_SIZE, IMG_SIZE):
            continue
        feats[w] = a.reshape(-1)
        kept_paths.append(p)
        w += 1
    feats = feats[:w]
    print(f"Loaded {w} crops (skipped {len(paths) - w} unreadable/odd-size).")

    k = min(args.k, w)
    print(f"Clustering into {k} groups (MiniBatchKMeans)...")
    km = MiniBatchKMeans(n_clusters=k, random_state=42, batch_size=1024, n_init=3)
    labels = km.fit_predict(feats)

    work = args.work
    os.makedirs(os.path.join(work, "clusters"), exist_ok=True)
    np.savez_compressed(
        os.path.join(work, "assignments.npz"),
        paths=np.array(kept_paths),
        labels=labels,
    )

    # Per-cluster mean ink (1 - mean brightness): solid piece glyphs and, more
    # importantly, the CUT/partial pieces that the buggy segmenter produces are
    # denser (more ink) than thin text strokes. Surfacing this in the montage
    # name and a sorted summary lets you scrutinise the ink-heavy clusters —
    # the ones most likely to hide piece material you must NOT harvest.
    ink = np.array(
        [
            (1.0 - feats[labels == cid].mean()) if (labels == cid).any() else 0.0
            for cid in range(k)
        ]
    )

    # One montage per cluster (up to 100 samples, 10x10 grid), named so the
    # cluster id, size and ink density are visible in the file browser.
    cell, pad, grid = IMG_SIZE, 2, 10
    counts = np.bincount(labels, minlength=k)
    for cid in range(k):
        idx = np.where(labels == cid)[0]
        if len(idx) == 0:
            continue
        sample = idx[:: max(1, len(idx) // (grid * grid))][: grid * grid]
        mont = Image.new(
            "L",
            (grid * (cell + pad) + pad, grid * (cell + pad) + pad),
            color=128,
        )
        for j, si in enumerate(sample):
            a = read_pgm(kept_paths[si])
            if a is None:
                continue
            im = Image.fromarray((a * 255).astype(np.uint8))
            r, c = divmod(j, grid)
            mont.paste(im, (pad + c * (cell + pad), pad + r * (cell + pad)))
        mont = mont.resize((mont.width * 2, mont.height * 2), Image.NEAREST)
        # ink*100 zero-padded so the filename sorts light→dark alphabetically.
        mont.save(
            os.path.join(
                work,
                "clusters",
                f"ink{int(ink[cid] * 100):02d}_cluster_{cid:03d}_n{counts[cid]}.png",
            )
        )

    print(f"\nWrote {k} montages to {os.path.join(work, 'clusters')}/")
    print("Clusters by ink density (densest = most likely to hide pieces/cut "
          "pieces — inspect these carefully, keep them only if clearly text):")
    for cid in np.argsort(-ink):
        bar = "#" * int(ink[cid] * 40)
        print(f"  cluster {cid:03d}  n={counts[cid]:5d}  ink={ink[cid]:.2f} {bar}")
    print("\nRecommended: harvest with --keep listing ONLY the clearly-text / "
          "blank clusters (conservative whitelist), not --exclude.")


def _parse_id_ranges(spec: str) -> set[int]:
    ids: set[int] = set()
    for part in spec.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            lo, hi = part.split("-")
            ids.update(range(int(lo), int(hi) + 1))
        else:
            ids.add(int(part))
    return ids


def cmd_harvest(args: argparse.Namespace) -> None:
    if bool(args.keep) == bool(args.exclude):
        sys.exit("Provide exactly one of --keep or --exclude.")

    npz = np.load(os.path.join(args.work, "assignments.npz"), allow_pickle=True)
    paths = npz["paths"]
    labels = npz["labels"]

    if args.keep:
        wanted = _parse_id_ranges(args.keep)
        mask = np.isin(labels, list(wanted))
    else:
        dropped = _parse_id_ranges(args.exclude)
        mask = ~np.isin(labels, list(dropped))

    sel = np.where(mask)[0]
    cls_dir = os.path.join(args.out, "NotAFigurine")
    os.makedirs(cls_dir, exist_ok=True)
    written = 0
    for si in sel:
        a = read_pgm(str(paths[si]))
        if a is None or a.shape != (IMG_SIZE, IMG_SIZE):
            continue
        Image.fromarray((a * 255).astype(np.uint8), mode="L").save(
            os.path.join(cls_dir, f"real_{written:06d}.png")
        )
        written += 1

    print(f"Harvested {written} real negatives -> {cls_dir}")
    print("Merge alongside the synthetic negatives into glyphs/NotAFigurine/.")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)

    pc = sub.add_parser("cluster", help="cluster crops and write montages")
    pc.add_argument("--crops", required=True, help="figurine_crops dir")
    pc.add_argument("--work", default="./triage", help="working dir for output")
    pc.add_argument("--k", type=int, default=80, help="number of clusters")
    pc.set_defaults(func=cmd_cluster)

    ph = sub.add_parser("harvest", help="copy selected clusters as PNG negatives")
    ph.add_argument("--work", default="./triage")
    ph.add_argument("--out", default="./negatives")
    ph.add_argument("--keep", help="cluster ids to KEEP, e.g. 1,2,5-9")
    ph.add_argument("--exclude", help="cluster ids to DROP (pieces), e.g. 4,17,23")
    ph.set_defaults(func=cmd_harvest)

    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()

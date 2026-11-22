#!/usr/bin/env python
"""Download the diagram reader weights into work/ (stdlib only, checks the SHA-256).

    .venv/bin/python fetch_weights.py          # work/fenify-ft.pt (fine-tuned, project's GitHub release "weights-3") AND work/fenify-base.pt
    .venv/bin/python fetch_weights.py --base   # only work/fenify-base.pt (original fenify model, MIT, notnil/fenify)
The program reads with the fine-tuned model and double-checks the readings it is unsure of with the base model.
Options: -o PATH (only with --base), --force (replace existing files)."""
import argparse
import hashlib
import sys
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).parent
FINE_TUNED = ("https://github.com/loloof64/ChessPdfEnriched/releases/download/weights-3/fenify-ft.pt",
              "ad73ac3105a920e491eab56eb635c389d132999513f87bbcd25c6eff9eca875b")
BASE = ("https://github.com/notnil/fenify/releases/download/v2023-07-10/models_2023-07-10-chessboard-2D-balanced-fen-gpu.pt",
        "eb91668eb6162506d40de7beab16ccb3bfd6a695e8e447b6c8e63f67e437f31b")


def download(url, sha, output):
    output.parent.mkdir(parents=True, exist_ok=True)
    part = output.with_name(output.name + ".part")
    digest, done = hashlib.sha256(), 0
    try:
        with urllib.request.urlopen(url, timeout=30) as r, open(part, "wb") as f:
            total = int(r.headers.get("Content-Length") or 0)
            while chunk := r.read(1 << 20):
                f.write(chunk)
                digest.update(chunk)
                done += len(chunk)
                print(f"\r{done / 1e6:6.1f} / {total / 1e6:.1f} MB", end="", file=sys.stderr, flush=True)
    except urllib.error.HTTPError as e:
        part.unlink(missing_ok=True)
        sys.exit(f"\nDownload failed ({e.code} {e.reason}): {url}")
    except OSError as e:
        part.unlink(missing_ok=True)
        sys.exit(f"\nDownload failed: {e}")
    print(file=sys.stderr)
    if digest.hexdigest() != sha:
        part.unlink(missing_ok=True)
        sys.exit(f"Checksum mismatch (got {digest.hexdigest()}, expected {sha}): the file was not saved.")
    part.replace(output)
    print(f"Saved {output}")


def main():
    ap = argparse.ArgumentParser(description="Download the diagram reader weights.")
    ap.add_argument("--base", action="store_true", help="only the original fenify model (work/fenify-base.pt)")
    ap.add_argument("-o", "--output", type=Path, help="destination, only with --base")
    ap.add_argument("--force", action="store_true", help="replace existing files")
    a = ap.parse_args()
    if a.output and not a.base:
        ap.error("-o needs --base (two files are downloaded otherwise)")
    jobs = [(BASE, a.output or HERE / "work" / "fenify-base.pt")]
    if not a.base:
        jobs.insert(0, (FINE_TUNED, HERE / "work" / "fenify-ft.pt"))
    for (url, sha), out in jobs:
        if out.exists() and not a.force:
            print(f"{out} already exists (use --force to replace it).")
        else:
            download(url, sha, out)


if __name__ == "__main__":
    main()

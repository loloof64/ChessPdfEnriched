#!/usr/bin/env python
"""Download the diagram reader weights into work/fenify-ft.pt (stdlib only, checks the SHA-256).

    .venv/bin/python fetch_weights.py          # the fine-tuned weights, from the project's GitHub release "weights-1"
    .venv/bin/python fetch_weights.py --base   # the original fenify model (MIT, notnil/fenify), a bit less accurate on highlighted squares
Options: -o PATH (default work/fenify-ft.pt), --force (replace an existing file)."""
import argparse
import hashlib
import sys
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).parent
FINE_TUNED = ("https://github.com/loloof64/ChessPdfEnriched/releases/download/weights-1/fenify-ft.pt",
              "f4689d45e8bd04402e70f8d211f4a8c8fbdc47a41b5c4816facdd7063e2f989e")
BASE = ("https://github.com/notnil/fenify/releases/download/v2023-07-10/models_2023-07-10-chessboard-2D-balanced-fen-gpu.pt",
        "eb91668eb6162506d40de7beab16ccb3bfd6a695e8e447b6c8e63f67e437f31b")


def main():
    ap = argparse.ArgumentParser(description="Download the diagram reader weights.")
    ap.add_argument("--base", action="store_true", help="the original fenify model instead of the fine-tuned one")
    ap.add_argument("-o", "--output", type=Path, default=HERE / "work" / "fenify-ft.pt")
    ap.add_argument("--force", action="store_true", help="replace an existing file")
    a = ap.parse_args()
    url, sha = BASE if a.base else FINE_TUNED
    if a.output.exists() and not a.force:
        sys.exit(f"{a.output} already exists (use --force to replace it).")
    a.output.parent.mkdir(parents=True, exist_ok=True)
    part = a.output.with_name(a.output.name + ".part")
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
        hint = "\nThe fine-tuned weights are not published at this address yet: use --base." if e.code == 404 and not a.base else ""
        sys.exit(f"\nDownload failed ({e.code} {e.reason}): {url}{hint}")
    except OSError as e:
        part.unlink(missing_ok=True)
        sys.exit(f"\nDownload failed: {e}")
    print(file=sys.stderr)
    if digest.hexdigest() != sha:
        part.unlink(missing_ok=True)
        sys.exit(f"Checksum mismatch (got {digest.hexdigest()}, expected {sha}): the file was not saved.")
    part.replace(a.output)
    print(f"Saved {a.output}")


if __name__ == "__main__":
    main()

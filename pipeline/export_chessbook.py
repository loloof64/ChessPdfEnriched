"""Step 7: write a .chessbook zip (schema/chessbook.md) from OCR'd French pages.

Usage: export_chessbook.py OUT.chessbook TITLE PAGE_NO:PAGE.json:PAGE.png [...]
Pages whose text does not start from move 1 (no known start position yet) are exported with their text but no moves.
"""
import json
import re
import sys
import zipfile

from PIL import Image

from french_moves import replay

KEEP = ("text", "paragraph_title", "header", "doc_title")


def page_data(no, js, png, start=None):
    blocks = [b for b in json.load(open(js)) if b["block_label"] in KEEP]
    texts = [b["block_content"] for b in blocks]
    joined = " ".join(texts)
    starts_at_one = re.search(r"\b1\.\s?[a-hCFTDR]", joined) is not None
    moves = replay(joined, start) if starts_at_one or start else []
    offs, o = [], 0
    for t in texts:
        offs.append((o, o + len(t))); o += len(t) + 1
    w, h = Image.open(png).size
    out_blocks = [{"id": f"p{no}_t{i + 1}", "bbox": [b["block_bbox"][0], b["block_bbox"][1], b["block_bbox"][2] - b["block_bbox"][0],
                   b["block_bbox"][3] - b["block_bbox"][1]], "text": t, "moves": []} for i, (b, t) in enumerate(zip(blocks, texts))]
    out_moves = []
    for m in moves:
        for i, (a, e) in enumerate(offs):
            if a <= m["span"][0] and m["span"][1] <= e:
                mid = f"p{no}_m{len(out_moves) + 1}"
                out_moves.append({"id": mid, "block": out_blocks[i]["id"], "span": [m["span"][0] - a, m["span"][1] - a], "raw": m["raw"],
                                  "san": m["san"], "fen": m["fen"], "ok": m["ok"], "variation_depth": m["depth"]})
                out_blocks[i]["moves"].append(mid)
                break
    return {"page": no, "width": w, "height": h, "blocks": out_blocks, "moves": out_moves, "diagrams": []}


if __name__ == "__main__":
    out, title, *pages = sys.argv[1:]
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("manifest.json", json.dumps({"schema_version": 1, "title": title, "language": "fr", "figurine_notation": False,
                                                "page_count": len(pages), "has_scans": True}, ensure_ascii=False, indent=1))
        for spec in pages:
            no, js, png = spec.split(":")
            d = page_data(int(no), js, png)
            z.writestr(f"pages/p{int(no):04d}.json", json.dumps(d, ensure_ascii=False, indent=1))
            z.write(png, f"scans/p{int(no):04d}.png")
            print(no, len(d["moves"]), "moves,", sum(not m["ok"] for m in d["moves"]), "illegal")

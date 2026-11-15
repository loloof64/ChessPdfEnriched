"""Build the complete .chessbook of attaque_minorite_1.pdf (Fabrice): text pages 1-2, 6 diagrams (p2), French games (p3-6).

Needs work/fab/page{3..6}.{png,json} (2x captures + PaddleOCR-VL blocks, see NEXT_SESSION.md), work/fab/img-002-004..009.png
(pdfimages), work/fenify-ft.pt. Usage: build_fabrice.py [OUT.chessbook]   (run from pipeline/)
"""
import json
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile

import chess
import torch
from PIL import Image

from autocrop import find_board
from export_chessbook import page_data
from french_moves import replay
from orientation import orient
from plausibility import issues
from read_fen import prep

PDF = "/home/laurent/Documents/Echecs/Ebooks/DeFabrice/attaque_minorite_1.pdf"
DPI = 150
K = DPI / 72
# diagram boxes of page 2 in pdftohtml units (page 892 px wide for 595.32 pt): measured once with `pdftohtml -xml`
P2_BOXES = [(133, 139, 302, 305), (494, 143, 298, 301), (133, 479, 299, 302), (492, 482, 299, 299), (133, 884, 298, 301), (498, 887, 297, 299)]
HTML = 1240 / 892
# Hand corrections (white at the bottom, placement only), checked square by square on the image. fenify reads the black pawn on b5
# (yellow highlight + arrow tips) as a queen with 98.7 % confidence, so no threshold can flag it.
CORRECTIONS = {"p2_d5": "6k1/4pppp/p2p4/1p1P4/2P5/1P6/P4PPP/6K1"}


def pdf_text_blocks(no):
    """[(bbox_px, text)] of a page with a real text layer."""
    xml = subprocess.check_output(["pdftotext", "-bbox-layout", "-f", str(no), "-l", str(no), PDF, "-"], text=True)
    root = ET.fromstring(re.sub(r' xmlns="[^"]+"', "", xml, count=1))
    out = []
    for b in root.iter("block"):
        lines = [" ".join(w.text or "" for w in l.iter("word")) for l in b.iter("line")]
        x0, y0, x1, y1 = (float(b.get(k)) * K for k in ("xMin", "yMin", "xMax", "yMax"))
        out.append(([round(x0), round(y0), round(x1 - x0), round(y1 - y0)], " ".join(lines)))
    return out


def read_diagram(model, im):
    x0, y0, x1, y1, _ = find_board(im)
    with torch.no_grad():
        p = model(prep(im.crop((x0, y0, x1, y1))).unsqueeze(0)).squeeze()  # (64, 13) probabilities, square 0 = a1 like read_fen
    cls, conf = p.argmax(dim=1), p.max(dim=1).values.mean().item()
    board = chess.Board(None)
    for i, c in enumerate(cls.tolist()):
        if c:
            board.set_piece_at(i, chess.Piece((c - 1) % 6 + 1, chess.BLACK if c > 6 else chess.WHITE))
    return board, conf


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "work/fab/attaque_minorite.chessbook"
    subprocess.run(["pdftoppm", "-r", str(DPI), "-png", "-f", "1", "-l", "2", PDF, "work/fab/pdf"], check=True)
    model = torch.jit.load("work/fenify-ft.pt", map_location="cpu").eval()
    pages, files = {}, {}
    os.makedirs("work/fab/crops", exist_ok=True)

    for no in (1, 2):
        png = f"work/fab/pdf-{no}.png"
        w, h = Image.open(png).size
        blocks = [{"id": f"p{no}_t{i + 1}", "bbox": b, "text": t, "moves": []} for i, (b, t) in enumerate(pdf_text_blocks(no)) if t.strip()]
        pages[no] = {"page": no, "width": w, "height": h, "blocks": blocks, "moves": [], "diagrams": []}
        files[f"scans/p{no:04d}.png"] = png

    for d, (x, y, bw, bh) in enumerate(P2_BOXES, 1):
        src = f"work/fab/img-002-{d + 3:03d}.png"
        im = Image.open(src).convert("RGB")
        board, conf = read_diagram(model, im)
        oriented, flipped, sure = orient(board)
        pages[2]["diagrams"].append({
            "id": f"p2_d{d}", "bbox": [round(x * HTML), round(y * HTML), round(bw * HTML), round(bh * HTML)], "image": f"diagrams/p2_d{d}.png",
            "fen": oriented.board_fen() + " w - - 0 1", "confidence": round(conf, 3), "reviewed": False,
            "flipped": flipped, "orientation_sure": sure, "issues": issues(board)})
        if (fix := CORRECTIONS.get(f"p2_d{d}")):
            assert fix != oriented.board_fen(), "correction is now redundant"
            pages[2]["diagrams"][-1].update(fen=fix + " w - - 0 1", reviewed=True, corrected=True)
        files[f"diagrams/p2_d{d}.png"] = src

    # page 6 is the full game that page 4 continues from move 16: its start position is the page-6 position after 16.Re3 (ply 31)
    full = {n: json.load(open(f"work/fab/page{n}.json")) for n in (3, 4, 5, 6)}
    text6 = " ".join(b["block_content"] for b in full[6] if b["block_label"] in ("text", "paragraph_title"))
    start4 = next(m["fen"] for m in replay(text6) if m["depth"] == 0 and m.get("ply") == 31)
    for no in (3, 4, 5, 6):
        pages[no] = page_data(no, f"work/fab/page{no}.json", f"work/fab/page{no}.png", start4 if no == 4 else None, "work/fab/crops")
        for d in pages[no]["diagrams"]:
            files[d["image"]] = f"work/fab/crops/{os.path.basename(d['image'])}"
        files[f"scans/p{no:04d}.png"] = f"work/fab/page{no}.png"

    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("manifest.json", json.dumps({"schema_version": 1, "title": "L'attaque de minorité (Fabrice)", "language": "fr",
                                                "figurine_notation": False, "page_count": 6, "has_scans": True}, ensure_ascii=False, indent=1))
        for no, d in sorted(pages.items()):
            z.writestr(f"pages/p{no:04d}.json", json.dumps(d, ensure_ascii=False, indent=1))
            print(no, len(d["blocks"]), "blocks,", len(d["moves"]), "moves,", sum(not m["ok"] for m in d["moves"]), "illegal,", len(d["diagrams"]), "diagrams")
        for name, src in files.items():
            z.write(src, name)
    for d in pages[2]["diagrams"]:
        print(d["id"], d["fen"], d["confidence"], "flipped" if d["flipped"] else "", "" if d["orientation_sure"] else "ORIENT?", d["issues"] or "")

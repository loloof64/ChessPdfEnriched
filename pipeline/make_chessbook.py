#!/usr/bin/env python
"""Generate a .chessbook (schema/chessbook.md) from a chess-book PDF.

    .venv/bin/python make_chessbook.py livre.pdf --lang fr -o livre.chessbook [--pages 1-40] [--title "..."]

Per page: render it; read the text from the PDF text layer when there is one, otherwise run PaddleOCR-VL; find the
diagrams, read their position (fenify) and check it against the game; read the moves and replay them with python-chess.
Slow steps are cached in a work folder (default work/<pdf name>/), so a run can be interrupted and resumed: delete a
file there to redo that step. An existing output file is replaced but its corrections.json (written by the reader) is kept.
Not supported yet: figurine notation (see figurines.py / inline.py spikes in NEXT_SESSION.md).
"""
import argparse
import html
import json
import re
import subprocess
import sys
import zipfile
from pathlib import Path

import chess
import pypdfium2 as pdfium
import pypdfium2.raw as pdfium_c
from PIL import Image

from autocrop import find_board
from export_chessbook import FIGURE, KEEP, joined_text, page_data
from moves import replay, tokens
from orientation import orient
from plausibility import issues

MIN_BOARD_SCORE = 2.5  # autocrop checkerboard score: logos < 1, small screenshot boards 3-5, real diagrams 6+
HERE = Path(__file__).parent


def page_numbers(spec, count):
    if not spec:
        return list(range(1, count + 1))
    out = []
    for part in spec.split(","):
        a, _, b = part.partition("-")
        out += range(int(a), int(b or a) + 1)
    return [n for n in out if 1 <= n <= count]


def render(pdf, n, dpi, work):
    png = work / "pages" / f"p{n}.png"
    if not png.exists():
        png.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["pdftoppm", "-r", str(dpi), "-f", str(n), "-l", str(n), "-png", "-singlefile", str(pdf), str(png.with_suffix(""))], check=True)
    return png


def text_layer_blocks(pdf, n, k):
    """OCR-style blocks from the PDF's own text (pdftotext -bbox-layout), boxes in px (k = px per point).
    The output is a regular XHTML subset, read with regexes: no XML parser on data derived from an untrusted PDF."""
    xml = subprocess.check_output(["pdftotext", "-bbox-layout", "-f", str(n), "-l", str(n), str(pdf), "-"], text=True)
    out = []
    for m in re.finditer(r'<block xMin="([\d.]+)" yMin="([\d.]+)" xMax="([\d.]+)" yMax="([\d.]+)">(.*?)</block>', xml, re.S):
        lines = re.findall(r"<line .*?</line>", m.group(5), re.S)
        text = " ".join(" ".join(html.unescape(w) for w in re.findall(r"<word [^>]*>(.*?)</word>", line, re.S)) for line in lines).strip()
        if text:
            out.append({"block_label": "text", "block_content": text, "block_bbox": [round(float(v) * k) for v in m.groups()[:4]]})
    return out


def image_blocks(doc, n, k, work):
    """Embedded images of a text-layer page as figure blocks (page-sized backgrounds and duplicates dropped). The image itself
    is extracted from the PDF: a crop of the rendered page would also contain the page's text, drawn a second time by the reader."""
    page = doc[n - 1]
    w, h = page.get_size()
    found = []
    for o in page.get_objects(filter=[pdfium_c.FPDF_PAGEOBJ_IMAGE]):
        l, b, r, t = o.get_bounds()
        box = [round(l * k), round((h - t) * k), round(r * k), round((h - b) * k)]
        if (r - l) * (t - b) < .8 * w * h and box not in [f[0] for f in found]:
            found.append((box, o))
    found.sort(key=lambda f: (round(f[0][1] / 100), f[0][0]))  # top to bottom, then left to right
    out = []
    (work / "embedded").mkdir(parents=True, exist_ok=True)
    for i, (box, o) in enumerate(found, 1):
        path = work / "embedded" / f"p{n}_{i}.png"
        o.get_bitmap(render=True).to_pil().save(path)
        out.append({"block_label": "image", "block_content": "", "block_bbox": box, "image_file": str(path.relative_to(work))})
    return out


class Ocr:
    """PaddleOCR-VL, loaded on first use (importing paddle takes a while)."""

    pipe = None

    def blocks(self, png):
        if Ocr.pipe is None:
            from paddleocr import PaddleOCRVL
            Ocr.pipe = PaddleOCRVL()
        return [r for res in Ocr.pipe.predict(str(png)) for r in res.json["res"]["parsing_res_list"]]

    def read_page(self, png):
        """Blocks of a scanned page; text blocks the OCR left EMPTY are re-read from a crop. The OCR then often already put
        that text at the end of the previous block: it is cut there, otherwise the moves would be read twice."""
        blocks = self.blocks(png)
        page = Image.open(png).convert("RGB")
        for b in blocks:
            if b["block_label"] != "text" or b["block_content"].strip():
                continue
            x0, y0, x1, y1 = b["block_bbox"]
            crop = png.with_name(f"{png.stem}_crop{x0}_{y0}.png")
            page.crop((max(0, x0 - 12), max(0, y0 - 12), x1 + 12, y1 + 12)).save(crop)
            b["block_content"] = " ".join(r["block_content"] for r in self.blocks(crop) if r["block_content"].strip())
            head = b["block_content"][:25]
            for o in blocks:
                i = o["block_content"].find(head) if o is not b and head else -1
                if i > 0:
                    o["block_content"] = o["block_content"][:i].rstrip()
        return blocks


def dedupe(blocks):
    """The OCR sometimes runs past its box and repeats the text of the NEXT blocks at the end of a block: cut each block at
    the start of any later block's text it contains (otherwise those moves are read twice). Idempotent."""
    keep = [b for b in blocks if b["block_label"] in KEEP and len(b["block_content"].strip()) >= 12]
    for i, a in enumerate(blocks):
        if a["block_label"] not in KEEP:
            continue
        for b in blocks[i + 1:]:
            head = re.sub(r"\s+", " ", b["block_content"]).strip()[:25]
            flat = re.sub(r"\s+", " ", a["block_content"])  # line breaks differ between the two copies
            at = flat.find(head) if b in keep and head else -1
            if at > 0:
                a["block_content"] = flat[:at].rstrip()
    return blocks


def page_blocks(pdf, doc, n, dpi, work, ocr, min_words):
    cache = work / "blocks" / f"p{n}.json"
    if cache.exists():
        return json.loads(cache.read_text()), "cache"
    png = render(pdf, n, dpi, work)
    words = len(subprocess.check_output(["pdftotext", "-f", str(n), "-l", str(n), str(pdf), "-"], text=True).split())
    if words >= min_words:
        k = dpi / 72
        blocks, how = text_layer_blocks(pdf, n, k) + image_blocks(doc, n, k, work), "text layer"
    else:
        blocks, how = ocr.read_page(png), "OCR"
    cache.parent.mkdir(parents=True, exist_ok=True)
    cache.write_text(json.dumps(blocks, ensure_ascii=False))
    return blocks, how


def onwhite(im):
    """RGB version of an image that may have transparency (embedded logos): composited on white."""
    if im.mode != "RGBA":
        return im.convert("RGB")
    bg = Image.new("RGBA", im.size, "white")
    return Image.alpha_composite(bg, im).convert("RGB")


def read_diagram(model, im):
    """(oriented board, confidence, flipped, orientation sure, raw board) or None when the image is not a board."""
    import torch
    from read_fen import prep
    if not .8 <= im.width / im.height <= 1.25:  # banners, labels
        return None
    x0, y0, x1, y1, score = find_board(im)
    if score < MIN_BOARD_SCORE:
        return None
    with torch.no_grad():
        p = model(prep(im.crop((x0, y0, x1, y1))).unsqueeze(0)).squeeze()  # (64, 13) probabilities, square 0 = a1
    board = chess.Board(None)
    for i, c in enumerate(p.argmax(dim=1).tolist()):
        if c:
            board.set_piece_at(i, chess.Piece((c - 1) % 6 + 1, chess.BLACK if c > 6 else chess.WHITE))
    oriented, flipped, sure = orient(board)
    return oriented, p.max(dim=1).values.mean().item(), flipped, sure, board


def infer_start(text, lang, others):
    """FEN to replay a page from when its first move number is not 1: a position of another page's mainline at that ply
    after which the text replays (almost) without illegal moves. Returns (fen, source) or (None, None)."""
    toks = tokens(text, lang)
    num = next((t[1] for t, nxt in zip(toks, toks[1:]) if t[0] == "num" and nxt[0] == "move"), None)
    if num is None:
        return None, None
    ply = 2 * int(num.rstrip(".")) - (1 if num.endswith("...") else 2)
    if ply == 0:
        return chess.STARTING_FEN, "start of game"
    best = (0, None, None)
    for page, ms in others:
        for m in ms:
            if m["ok"] and m["depth"] == 0 and m["ply"] == ply:
                r = replay(text, m["fen"], lang)
                good, bad = sum(x["ok"] for x in r), sum(not x["ok"] for x in r)
                if good >= 5 and bad <= max(1, good // 20) and good - 3 * bad > best[0]:
                    best = (good - 3 * bad, m["fen"], f"position of page {page} at ply {ply}")
    return best[1], best[2]


def main():
    ap = argparse.ArgumentParser(description="Generate a .chessbook from a chess-book PDF.")
    ap.add_argument("pdf", type=Path)
    ap.add_argument("-o", "--output", type=Path, help="default: <pdf name>.chessbook in the current folder")
    ap.add_argument("--lang", choices=("fr", "en"), default="fr", help="language of the move notation (fr: C F T D R, en: N B R Q K)")
    ap.add_argument("--title", help="default: PDF title, else file name")
    ap.add_argument("--pages", help="e.g. 1-40 or 3,5,8-10 (default: all)")
    ap.add_argument("--dpi", type=int, default=200)
    ap.add_argument("--work", type=Path, help="cache folder, default work/<pdf name>/")
    ap.add_argument("--no-scans", action="store_true", help="do not embed the page images (smaller file, no facsimile)")
    ap.add_argument("--min-text-words", type=int, default=60, help="pages with fewer words in the PDF text layer are OCRed")
    ap.add_argument("--weights", type=Path, default=HERE / "work" / "fenify-ft.pt", help="diagram reader weights (TorchScript)")
    a = ap.parse_args()

    if not a.weights.exists():  # fail now, not after minutes of OCR
        sys.exit(f"Poids des diagrammes introuvables : {a.weights}\nVoir la section « Poids des diagrammes » du README.")
    out = a.output or Path(a.pdf.stem + ".chessbook")
    work = a.work or HERE / "work" / a.pdf.stem
    (work / "diagrams").mkdir(parents=True, exist_ok=True)
    doc = pdfium.PdfDocument(str(a.pdf))
    title = a.title or doc.get_metadata_dict().get("Title") or a.pdf.stem
    pages = page_numbers(a.pages, len(doc))
    ocr, k = Ocr(), a.dpi / 72

    blocks, pngs = {}, {}
    for n in pages:
        blocks[n], how = page_blocks(a.pdf, doc, n, a.dpi, work, ocr, a.min_text_words)
        blocks[n] = dedupe(blocks[n])
        pngs[n] = render(a.pdf, n, a.dpi, work)
        print(f"page {n}: {how}, {len(blocks[n])} blocks", flush=True)

    # moves: pages whose text starts at move 1 first, the others from a position of another page's game
    texts = {n: joined_text(blocks[n]) for n in pages}
    replays, starts, start_fens = {}, {}, {}
    for n in pages:
        fen, src = infer_start(texts[n], a.lang, [])
        if fen:
            replays[n], starts[n], start_fens[n] = replay(texts[n], fen, a.lang), src, fen
    for n in pages:
        if n not in replays:
            fen, src = infer_start(texts[n], a.lang, [(p, replays[p]) for p in sorted(replays, key=lambda p: abs(p - n))])
            replays[n], starts[n], start_fens[n] = (replay(texts[n], fen, a.lang) if fen else []), src, fen
    data = {n: page_data(n, blocks[n], pngs[n], replays[n]) for n in pages}

    # diagrams: read each figure, then look for its position in the page's game
    model = None
    for n in pages:
        page_img = None
        nb = ni = 0
        for b in (b for b in blocks[n] if b["block_label"] in FIGURE):
            page_img = page_img or Image.open(pngs[n]).convert("RGB")
            x0, y0, x1, y1 = b["block_bbox"]
            im = Image.open(work / b["image_file"]) if b.get("image_file") else page_img.crop((x0, y0, x1, y1))
            if model is None:
                import torch
                model = torch.jit.load(str(a.weights), map_location="cpu").eval()
            r = read_diagram(model, onwhite(im))
            # boards are p{n}_d{k}, other images (logos, labels) p{n}_i{k}: board numbering does not depend on them
            if r:
                nb += 1
                fid = f"p{n}_d{nb}"
            else:
                ni += 1
                fid = f"p{n}_i{ni}"
            im.save(work / "diagrams" / f"{fid}.png")
            d = {"id": fid, "bbox": [x0, y0, x1 - x0, y1 - y0], "image": f"diagrams/{fid}.png", "fen": None, "confidence": 0, "reviewed": False}
            if r:
                board, conf, flipped, sure, raw = r
                d.update(fen=board.board_fen() + " w - - 0 1", confidence=round(conf, 3), flipped=flipped, orientation_sure=sure, issues=issues(raw))
                hit = next((m["id"] for m in data[n]["moves"] if m["ok"] and m["fen"].split()[0] == board.board_fen()), None)
                if not hit and starts[n] and chess.Board(start_fens[n]).board_fen() == board.board_fen():
                    hit = "start"  # the diagram shows the position the page's text starts from
                if hit:
                    d["matches_move"] = hit  # the printed position occurs in the page's game: a strong check of the reading
            data[n]["diagrams"].append(d)

    # write the book; the reader's corrections.json survives a rebuild
    corrections = json.dumps({"schema_version": 1, "corrections": []})
    if out.exists():
        with zipfile.ZipFile(out) as old:
            if "corrections.json" in old.namelist():
                corrections = old.read("corrections.json").decode()
    tmp = out.with_name(out.name + ".tmp")
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("manifest.json", json.dumps({"schema_version": 1, "title": title, "language": a.lang, "figurine_notation": False,
                                                "page_count": len(pages), "has_scans": not a.no_scans, "dpi": a.dpi}, ensure_ascii=False, indent=1))
        z.writestr("corrections.json", corrections)
        for n in pages:
            z.writestr(f"pages/p{n:04d}.json", json.dumps(data[n], ensure_ascii=False, indent=1))
            if not a.no_scans:
                z.write(pngs[n], f"scans/p{n:04d}.png")
            for d in data[n]["diagrams"]:
                z.write(work / d["image"], d["image"])
    tmp.replace(out)

    print(f"\n{out}: {len(pages)} pages")
    for n in pages:
        ms, ds = data[n]["moves"], data[n]["diagrams"]
        bad = sum(not m["ok"] for m in ms)
        read = [d for d in ds if d["fen"]]
        print(f"  page {n}: {len(ms)} moves, {bad} illegal" + (f", start: {starts[n]}" if starts[n] and starts[n] != "start of game" else "")
              + (", NO START POSITION" if not ms and re.search(r"\d+\.", texts[n]) and not starts[n] else "")
              + f"; diagrams: {len(read)}/{len(ds)} read, {sum('matches_move' in d for d in read)} match the game")


if __name__ == "__main__":
    sys.exit(main())

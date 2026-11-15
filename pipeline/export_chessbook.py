"""Page records of a .chessbook (schema/chessbook.md) from OCR-style blocks and replayed moves. Library, see make_chessbook.py."""
from PIL import Image

KEEP = ("text", "paragraph_title", "header", "doc_title")  # block labels that carry book text
FIGURE = ("image", "chart")  # block labels that may hold a diagram


def text_blocks(blocks):
    return [b for b in blocks if b["block_label"] in KEEP and b["block_content"].strip()]


def joined_text(blocks):
    """The page text moves are read from: block texts in reading order, one space apart."""
    return " ".join(b["block_content"] for b in text_blocks(blocks))


def page_data(no, blocks, png, moves):
    """{page, width, height, blocks, moves, diagrams=[]}: each move is attached to the block holding its span."""
    tb = text_blocks(blocks)
    offs, o = [], 0
    for b in tb:
        offs.append((o, o + len(b["block_content"]))); o += len(b["block_content"]) + 1
    w, h = Image.open(png).size
    out_blocks = [{"id": f"p{no}_t{i + 1}", "bbox": [b["block_bbox"][0], b["block_bbox"][1], b["block_bbox"][2] - b["block_bbox"][0],
                   b["block_bbox"][3] - b["block_bbox"][1]], "text": b["block_content"], "moves": []} for i, b in enumerate(tb)]
    out_moves = []
    for m in moves:
        for i, (a, e) in enumerate(offs):
            if a <= m["span"][0] and m["span"][1] <= e:
                mid = f"p{no}_m{len(out_moves) + 1}"
                out_moves.append({"id": mid, "block": out_blocks[i]["id"], "span": [m["span"][0] - a, m["span"][1] - a], "raw": m["raw"],
                                  "san": m["san"], "uci": m.get("uci"), "fen": m["fen"], "ok": m["ok"], "variation_depth": m["depth"]})
                out_blocks[i]["moves"].append(mid)
                break
    return {"page": no, "width": w, "height": h, "blocks": out_blocks, "moves": out_moves, "diagrams": []}

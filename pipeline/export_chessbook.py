"""Page records of a .chessbook (schema/chessbook.md) from OCR-style blocks and replayed moves. Library, see make_chessbook_cli.py."""
from PIL import Image

KEEP = ("text", "paragraph_title", "header", "doc_title")  # block labels that carry book text
FIGURE = ("image", "chart", "seal")  # block labels that may hold a diagram (the OCR sometimes calls a board a seal)


def text_blocks(blocks):
    return [b for b in blocks if b["block_label"] in KEEP and b["block_content"].strip()]


def column_order(blocks):
    """Blocks in two-column reading order (left column top to bottom, then right) when the page has two columns, else unchanged.
    The OCR sometimes puts the top of the right column before the end of the left one, which cuts a line of moves in two.
    The columns are split at the middle of the text's own extent (the text is not always centred on the page)."""
    texts = [b for b in blocks if b["block_label"] == "text"]
    if len(texts) < 4:
        return blocks
    mid = (min(b["block_bbox"][0] for b in texts) + max(b["block_bbox"][2] for b in texts)) / 2
    right = lambda b: b["block_bbox"][0] >= mid - 20  # a block spanning both columns (title, header) counts as left: it comes first
    if sum(right(b) for b in texts) < 2 or sum(not right(b) and b["block_bbox"][2] < mid + 60 for b in texts) < 2:
        return blocks
    return sorted(blocks, key=lambda b: (right(b), b["block_bbox"][1]))


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
                   b["block_bbox"][3] - b["block_bbox"][1]], "text": b["block_content"], "moves": [], **({"style": b["style"]} if b.get("style") else {})} for i, b in enumerate(tb)]
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

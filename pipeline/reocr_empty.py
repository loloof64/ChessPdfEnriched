"""Re-run the OCR on text blocks that came back EMPTY (PaddleOCR-VL sometimes drops a whole block, losing its moves).

Usage: reocr_empty.py PAGE.png PAGE.json [...]   rewrites the JSON in place; prints what was recovered.
"""
import json
import sys

from paddleocr import PaddleOCRVL
from PIL import Image

if __name__ == "__main__":
    pipe = PaddleOCRVL()
    for png, js in zip(sys.argv[1::2], sys.argv[2::2]):
        blocks, page, changed = json.load(open(js)), Image.open(png).convert("RGB"), False
        for b in blocks:
            if b["block_label"] != "text" or b["block_content"].strip():
                continue
            x0, y0, x1, y1 = b["block_bbox"]
            crop = page.crop((max(0, x0 - 12), max(0, y0 - 12), x1 + 12, y1 + 12))
            path = js.replace(".json", f"_crop{x0}_{y0}.png")
            crop.save(path)
            texts = [r["block_content"] for res in pipe.predict(path) for r in res.json["res"]["parsing_res_list"] if r["block_content"].strip()]
            b["block_content"] = " ".join(texts)
            changed = True
            # the OCR often already put this text at the end of the PREVIOUS block (and left this one empty): cut it there,
            # otherwise the moves are read twice and the text is drawn outside its own box
            head = b["block_content"][:25]
            for o in blocks:
                i = o["block_content"].find(head) if o is not b and head else -1
                if i > 0:
                    o["block_content"] = o["block_content"][:i].rstrip()
                    print("  cut duplicate from block", o["block_bbox"])
            print(js, b["block_bbox"], "->", b["block_content"][:160].replace("\n", " "))
        if changed:
            json.dump(blocks, open(js, "w"), ensure_ascii=False)

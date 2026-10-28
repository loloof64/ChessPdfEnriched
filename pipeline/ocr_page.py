"""Step 3 spike: run PaddleOCR-VL on one page image and dump blocks (label, bbox, text)."""
import json
import sys

from paddleocr import PaddleOCRVL

pipeline = PaddleOCRVL()
for res in pipeline.predict(sys.argv[1]):
    blocks = res.json["res"]["parsing_res_list"]
    print(json.dumps(blocks, ensure_ascii=False, indent=1))

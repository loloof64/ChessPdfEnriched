"""Step 6: parse French algebraic moves (C F T D R) out of OCR'd text and replay them with python-chess.

Mainline from the start position; '[ ... ]' variations branch from the position before the last mainline move.
Prose contains squares too ('pions a4 et b4'): a bare move is only taken when it sits in a run with a move number,
or is a capture / piece move / castling that the board expects (see `plausible_lone`).
Usage: french_moves.py PAGE.json [...]
"""
import json
import re
import sys

import chess

FR = str.maketrans("CFTDR", "NBRQK")
SAN = r"(?:0-0-0|0-0|O-O-O|O-O|[CFTDR]?[a-h]?[1-8]?x?[a-h][1-8](?:=[CFTD])?)[+#]?[!?]*"
TOKEN = re.compile(rf"(?P<num>\d+\.(?:\.\.)?|\d+\.\.\.)|(?P<move>{SAN})(?![A-Za-z0-9=.])|(?P<semi>;)|(?P<open>\[)|(?P<close>\])|(?P<res>1-0|0-1|1/2-1/2)")
STRIP = str.maketrans("", "", "+#!?=-")


def to_san(m: str) -> str:
    m = m.replace("0-0-0", "O-O-O").replace("0-0", "O-O")
    head = m.rstrip("!?")
    return head.translate(FR) if "O" not in head else head


def plausible_lone(tok: str) -> bool:
    """A bare move with no move number next to it: only believe it if it looks like a move, not a pawn square in prose."""
    return "x" in tok or tok[0] in "CFTDR" or tok.startswith(("0-0", "O-O")) or tok[-1] in "!?"  # 'a6!?': an annotation marks a move


def tokens(text):
    """[(kind, value, start, end)] in order; prose between tokens is recorded as ('prose', '')."""
    out, pos = [], 0
    for m in TOKEN.finditer(text):
        if text[pos:m.start()].strip(" \n\t,;:.()"):
            out.append(("prose", "", pos, m.start()))
        kind = m.lastgroup
        out.append((kind, m.group(kind), m.start(), m.end()))
        pos = m.end()
    return out


def replay(text):
    """[{san, fen, ok, depth, ply, raw}] ; mainline + variations. Stops a line at its first illegal move."""
    toks = tokens(text)
    board, before_last = chess.Board(), None
    stack, moves = [], []
    # runs of tokens without prose between them: a run is trusted if it holds a move number
    i = 0
    run_ok = {}
    while i < len(toks):
        if toks[i][0] == "prose":
            i += 1; continue
        j = i
        while j < len(toks) and toks[j][0] != "prose":
            j += 1
        has_num = any(k == "num" for k, *_ in toks[i:j])
        for k in range(i, j):
            run_ok[k] = has_num
        i = j
    dead = False
    for idx, (kind, val, start, end) in enumerate(toks):
        if kind == "open":
            stack.append((board, before_last, dead)); board = (before_last or board).copy(); dead = False; branch = board.copy()
        elif kind == "semi" and stack:  # sibling variation: restart from the same branch point
            board = stack[-1][1].copy() if stack[-1][1] else board; dead = False
        elif kind == "close" and stack:
            board, before_last, dead = stack.pop()
        elif kind == "move":
            if dead or not (run_ok.get(idx) or plausible_lone(val)):
                continue
            try:
                mv = board.parse_san(to_san(val))
            except ValueError:
                if (idx > 0 and toks[idx - 1][0] == "num") or plausible_lone(val):  # a pawn square in prose is just skipped
                    moves.append({"raw": val, "san": None, "fen": None, "ok": False, "depth": len(stack), "span": [start, end]})
                    dead = True
                continue
            prev = board.copy()
            san = board.san(mv); board.push(mv)
            before_last = prev
            moves.append({"raw": val, "san": san, "fen": board.fen(), "ok": True, "depth": len(stack), "ply": board.ply(), "span": [start, end]})
    return moves


if __name__ == "__main__":
    text = " ".join(b["block_content"] for p in sys.argv[1:] for b in json.load(open(p)) if b["block_label"] in ("text", "paragraph_title"))
    ms = replay(text)
    print(len(ms), "moves,", sum(not m["ok"] for m in ms), "illegal")
    print(" ".join(("" if m["depth"] == 0 else "(" * m["depth"]) + (m["san"] or "??" + m["raw"]) for m in ms))

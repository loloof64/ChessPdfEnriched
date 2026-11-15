"""Step 6: parse algebraic moves out of OCR'd text (French C F T D R, or English N B R Q K) and replay them with python-chess.

Mainline from the start position; '[ ... ]' variations branch from the position before the last mainline move.
Prose contains squares too ('pions a4 et b4'): a bare move is only taken when it sits in a run with a move number,
or is a capture / piece move / castling that the board expects (see `plausible_lone`).
Usage: moves.py [--lang fr|en] PAGE.json [...]   (OCR block lists)
"""
import json
import re
import sys

import chess

PIECES = {"fr": "CFTDR", "en": "NBRQK"}  # knight, bishop, rook, queen, king as printed in the book


def _lang(lang):
    """(token regex, translate table to English SAN, piece letters) for a book language."""
    p = PIECES[lang]
    san = rf"(?:0-0-0|0-0|O-O-O|O-O|[{p}]?[a-h]?[1-8]?x?[a-h][1-8](?:=[{p[:4]}])?)[+#]?[!?]*"
    tok = re.compile(rf"(?P<num>\d+\.(?:\.\.)?|\d+\.\.\.)|(?P<move>{san})(?![A-Za-z0-9=.])|(?P<semi>;)|(?P<open>\[)|(?P<close>\])|(?P<res>1-0|0-1|1/2-1/2)")
    return tok, str.maketrans(p, "NBRQK"), p


def to_san(m: str, table) -> str:
    m = m.replace("0-0-0", "O-O-O").replace("0-0", "O-O")
    head = m.rstrip("!?")
    return head.translate(table) if "O" not in head else head


def plausible_lone(tok: str, pieces: str) -> bool:
    """A bare move with no move number next to it: only believe it if it looks like a move, not a pawn square in prose."""
    return "x" in tok or tok[0] in pieces or tok.startswith(("0-0", "O-O")) or tok[-1] in "!?"  # 'a6!?': an annotation marks a move


def tokens(text, lang="fr"):
    """[(kind, value, start, end)] in order; prose between tokens is recorded as ('prose', '')."""
    out, pos = [], 0
    for m in _lang(lang)[0].finditer(text):
        if text[pos:m.start()].strip(" \n\t,;:.()"):
            out.append(("prose", "", pos, m.start()))
        kind = m.lastgroup
        out.append((kind, m.group(kind), m.start(), m.end()))
        pos = m.end()
    return out


def replay(text, start=None, lang="fr"):
    """[{san, fen, ok, depth, ply, raw}] ; mainline + variations. Stops a line at its first illegal move."""
    toks = tokens(text, lang)
    _, table, pieces = _lang(lang)
    board, before_last = chess.Board(start) if start else chess.Board(), None
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
            if dead or not (run_ok.get(idx) or plausible_lone(val, pieces)):
                continue
            try:
                mv = board.parse_san(to_san(val, table))
            except ValueError:
                if (idx > 0 and toks[idx - 1][0] == "num") or plausible_lone(val, pieces):  # a pawn square in prose is just skipped
                    moves.append({"raw": val, "san": None, "fen": None, "ok": False, "depth": len(stack), "span": [start, end]})
                    dead = True
                continue
            prev = board.copy()
            san = board.san(mv); board.push(mv)
            before_last = prev
            moves.append({"raw": val, "san": san, "fen": board.fen(), "ok": True, "depth": len(stack), "ply": board.ply(), "span": [start, end], "uci": mv.uci()})
    return moves


if __name__ == "__main__":
    args = sys.argv[1:]
    lang = "fr"
    if args[:1] == ["--lang"]:
        lang, args = args[1], args[2:]
    text = " ".join(b["block_content"] for p in args for b in json.load(open(p)) if b["block_label"] in ("text", "paragraph_title"))
    ms = replay(text, lang=lang)
    print(len(ms), "moves,", sum(not m["ok"] for m in ms), "illegal")
    print(" ".join(("" if m["depth"] == 0 else "(" * m["depth"]) + (m["san"] or "??" + m["raw"]) for m in ms))

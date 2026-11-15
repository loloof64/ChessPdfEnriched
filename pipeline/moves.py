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
    tok = re.compile(rf"(?P<num>\d+\.(?:\.\.)?|\d+\.\.\.)|(?P<move>{san})(?![A-Za-z0-9.])(?!=[A-Za-z0-9])|(?P<semi>;)|(?P<open>\[)|(?P<close>\])|(?P<res>1-0|0-1|1/2-1/2)")
    return tok, str.maketrans(p, "NBRQK"), p


def to_san(m: str, table) -> str:
    m = m.replace("0-0-0", "O-O-O").replace("0-0", "O-O")
    head = m.rstrip("!?")
    return head.translate(table) if "O" not in head else head


def plausible_lone(tok: str, pieces: str) -> bool:
    """A bare move with no move number next to it: only believe it if it looks like a move, not a pawn square in prose."""
    return "x" in tok or tok[0] in pieces or tok.startswith(("0-0", "O-O")) or tok[-1] in "!?"  # 'a6!?': an annotation marks a move


def _legal(board, tok, table):
    try:
        board.parse_san(to_san(tok, table))
        return True
    except ValueError:
        return False


def _disambiguate(board, san, toks, idx, table, look=4):
    """Pick among the legal moves a piece SAN could mean the one after which the next moves of the same run stay legal
    (ties: the first). Returns None when nothing fits at all."""
    head = san.rstrip("+#")
    cands = []
    for extra in ("abcdefgh12345678"):
        try:
            mv = board.parse_san(head[0] + extra + head[1:])
        except ValueError:
            continue
        if mv not in cands:
            cands.append(mv)
    best, best_score = None, -1
    for mv in cands:
        b = board.copy()
        b.push(mv)
        score = 0
        for kind, val, *_ in toks[idx + 1: idx + 1 + 3 * look]:
            if kind != "move":
                if kind == "num":
                    continue
                break
            try:
                b.push(b.parse_san(to_san(val, table)))
                score += 1
            except ValueError:
                break
            if score >= look:
                break
        if score > best_score:
            best, best_score = mv, score
    return best


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
    closed = None  # (board of the variation just closed, index of its ']'): the OCR sometimes closes a variation too early
    for idx, (kind, val, start, end) in enumerate(toks):
        if kind == "num" and dead and idx + 1 < len(toks) and toks[idx + 1][0] == "move":
            # after an illegal move (often an alternative given in prose without brackets: 'Si 24.Fxd5 ...') resume at the next move
            # number that is exactly the one the board expects and whose move is legal
            n, black = int(val.rstrip(".")), val.endswith("...")
            if n == board.fullmove_number and black == (board.turn == chess.BLACK) and _legal(board, toks[idx + 1][1], table):
                dead = False
        if kind == "num" and val == "1." and not stack and board.ply() > 0 and idx + 1 < len(toks) and toks[idx + 1][0] == "move":
            board, before_last, dead = chess.Board(), None, False  # "1." after moves have been played: a new game starts here
        elif kind == "open":
            stack.append((board, before_last, dead)); board = (before_last or board).copy(); dead = False; branch = board.copy()
        elif kind == "semi" and stack:  # sibling variation: restart from the same branch point
            board = stack[-1][1].copy() if stack[-1][1] else board; dead = False
        elif kind == "close" and stack:
            closed = (board.copy(), idx)
            board, before_last, dead = stack.pop()
        elif kind == "move":
            # a move number glued to the move ('23...Fxd5') is part of what the book prints in bold: include it in the span
            if idx > 0 and toks[idx - 1][0] == "num" and toks[idx - 1][3] == start:
                start = toks[idx - 1][2]
            if dead or not (run_ok.get(idx) or plausible_lone(val, pieces)):
                continue
            mv = None
            try:
                mv = board.parse_san(to_san(val, table))
            except chess.AmbiguousMoveError:  # two pieces can go there and the book does not say which ('26.Td2')
                mv = _disambiguate(board, to_san(val, table), toks, idx, table)
            except ValueError:
                pass
            if mv is None and closed is not None and all(toks[k][0] in ("move", "num") for k in range(closed[1] + 1, idx)):
                # a move right after a ']' that is illegal here but legal in the variation just closed: the OCR put the ']' too early
                try:
                    mv = closed[0].parse_san(to_san(val, table))
                    stack.append((board, before_last, dead))
                    board, dead = closed[0], False
                except ValueError:
                    pass
            if mv is None:
                # an illegal move that carries its own number, or a piece move / capture inside a numbered sequence, is an error (red,
                # the line stops). A bare pawn square in prose ('c6 se trouve sous tension') or a lone move-looking word ('...par Th1')
                # is just a mention: ignored
                if (idx > 0 and toks[idx - 1][0] == "num") or (plausible_lone(val, pieces) and run_ok.get(idx)):
                    moves.append({"raw": val, "san": None, "fen": None, "ok": False, "depth": len(stack), "span": [start, end]})
                    dead = True
                continue
            prev = board.copy()
            san = board.san(mv); board.push(mv)
            before_last = prev
            closed = None
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

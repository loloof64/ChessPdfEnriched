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
    san = rf"(?:0-0-0|0-0|O-O-O|O-O|[{p}]?[a-h]?[1-8]?x?[a-h][1-8](?:=[{p[:4]}]|(?<=[18])[{p[:4]}])?)[+#]?[!?]*"
    # a move number is not glued to a square ('e5.h3' is prose); the OCR sometimes drops the spaces ('e62.d4', 'cxd4f69.exf6', 'Ff40-012.0-0'),
    # so a move may be followed directly by a number, another pawn move, a castling or a prose word ('Ce2Opération')
    tok = re.compile(rf"(?P<num>(?<![a-h])\d+\.(?:\.\.)?|(?<![a-h])\d+\.\.\.)|(?P<move>{san})(?!(?!\d+\.|[a-h][1-8]|0-0|O-O|[A-Z]['’]?[a-zé]{{2,}})[A-Za-z0-9.])(?!=[A-Za-z0-9])|(?P<semi>;)|(?P<open>[\[(])|(?P<close>[\])])|(?P<res>1-0|0-1|1/2-1/2)")
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


def _run_length(board, mv, toks, idx, table, look, skip_prose=False):
    """How many of the moves that follow token idx stay legal in a row after `mv` is played on `board` (at most `look`); the run ends at
    prose unless `skip_prose` (commentary between two moves of the game)."""
    b = board.copy()
    b.push(mv)
    score, depth = 0, 0
    for kind, val, *_ in toks[idx + 1: idx + 1 + (6 if skip_prose else 3) * look]:
        if skip_prose and kind in ("open", "close"):  # a bracket in the commentary or a variation: its content is not the game's next moves
            depth += 1 if kind == "open" else -1
            if depth < 0:
                break
            continue
        if kind != "move" or depth:
            if kind == "num" or (skip_prose and (kind == "prose" or depth)):
                continue
            break
        try:
            b.push(b.parse_san(to_san(val, table)))
            score += 1
        except ValueError:
            break
        if score >= look:
            break
    return score


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
        if (score := _run_length(board, mv, toks, idx, table, look)) > best_score:
            best, best_score = mv, score
    return best


def _edit(a, b):
    """0 equal, 1 one character inserted into `a` (a dropped letter), 2 one character substituted, None: further apart."""
    if a == b:
        return 0
    if len(b) == len(a) + 1:
        return 1 if any(b[:i] + b[i + 1:] == a for i in range(len(b))) else None
    return 2 if len(a) == len(b) and sum(x != y for x, y in zip(a, b)) == 1 else None


def _repair(board, san, toks, idx, table, look=12):
    """A numbered move that is illegal because the OCR dropped or changed ONE character ('Cf7' for 'Cfd7'): the legal move whose SAN is
    one edit away and after which the next moves stay legal (at least 2, and clearly the best: a missing letter beats a wrong one,
    anything else tied gives up). Returns None when there is no such move."""
    head, found = san.rstrip("+#!?"), []
    for mv in board.legal_moves:
        kind = _edit(head, board.san(mv).rstrip("+#"))
        if kind and (score := _run_length(board, mv, toks, idx, table, look, True)) >= 2:
            found.append(((score, kind == 1), mv))
    if not found:
        return None
    top = max(k for k, _ in found)
    best = [mv for k, mv in found if k == top]
    return best[0] if len(best) == 1 else None


def _skipped_move(board, san, toks, idx, number, table, look=12, need=5):
    """The book (or the OCR) skips one move: '30.Tf2 a6 ... 31...Cc8' has no White 31st move. Returns (skipped move, the printed move) when
    exactly one legal move of the side to play makes the printed move and at least `need - 1` of the moves after it legal; otherwise None."""
    n, black = int(number.rstrip(".")), number.endswith("...")
    if not ((black and board.turn == chess.WHITE and n == board.fullmove_number) or (not black and board.turn == chess.BLACK and n == board.fullmove_number + 1)):
        return None
    found = []
    for first in board.legal_moves:
        b = board.copy()
        b.push(first)
        try:
            mv = b.parse_san(san)
        except ValueError:
            continue
        found.append((1 + _run_length(b, mv, toks, idx, table, look, True), first, mv))
    if not found:
        return None
    top = max(sc for sc, _, _ in found)
    best = [(first, mv) for sc, first, mv in found if sc == top]
    return best[0] if top >= need and len(best) == 1 else None


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


def _stray_close(toks, reach=60):
    """Index of the ']' the OCR/book put too early: a closing bracket with nothing open (a stray ']') means the last variation that closed
    just before it (at most `reach` tokens away) goes on up to there. None when there is no stray bracket."""
    depth, last_top = 0, None
    for k, (kind, *_) in enumerate(toks):
        if kind == "open":
            depth += 1
        elif kind == "close":
            if depth == 0:
                return last_top if last_top is not None and k - last_top <= reach else None
            depth -= 1
            if depth == 0:
                last_top = k
    return None


def replay(text, start=None, lang="fr", anchors=(), own=0, toks=None):
    """[{san, fen, ok, depth, ply, raw}] ; mainline + variations. Stops a line at its first illegal move.
    `anchors`: piece placements of diagrams. A move number that does not follow the board (or follows a dead line) may restart
    the game from one of them (the first `own` are the page's own diagrams, preferred on ties; side to move and move number come from the printed number) when that makes the next moves legal."""
    if toks is None:
        toks = tokens(text, lang)
        if (c := _stray_close(toks)) is not None:  # the variation before the stray ']' probably goes on: keep that reading when it is better
            alt = replay(text, start, lang, anchors, own, toks[:c] + [("prose", "", toks[c][2], toks[c][3])] + toks[c + 1:])
            plain = replay(text, start, lang, anchors, own, toks)
            bad = lambda ms: sum(not m["ok"] for m in ms)
            return alt if (bad(alt), -len(alt)) < (bad(plain), -len(plain)) else plain
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
        seen = False
        for k in range(i, j):  # a bare move BEFORE the run's first number is prose ('la case c4! 1...b5!'), not a numbered move
            seen = seen or toks[k][0] == "num"
            run_ok[k] = seen
        i = j
    dead = False
    closed = None  # (board of the variation just closed, index of its ']'): the OCR sometimes closes a variation too early
    def lookahead(b, idx, cap=8):
        """How many of the moves after token idx are legal in a row from board b (prose between them is skipped)."""
        b, n = b.copy(), 0
        depth = 0
        for k in range(idx + 1, len(toks)):
            if toks[k][0] == "open":
                depth += 1  # a variation does not continue the game: skip its content
            elif toks[k][0] == "close":
                if depth == 0:
                    break
                depth -= 1
            if toks[k][0] != "move" or depth:
                continue
            numbered = run_ok.get(k)
            if not (numbered or (plausible_lone(toks[k][1], pieces) and b.turn == chess.BLACK)):
                continue  # prose mention, as in the main loop
            try:
                b.push(b.parse_san(to_san(toks[k][1], table)))
            except ValueError:
                if numbered:
                    break
                continue
            n += 1
            if n >= cap:
                break
        return n

    for idx, (kind, val, start, end) in enumerate(toks):
        if anchors and kind == "num" and not stack and idx + 1 < len(toks) and toks[idx + 1][0] == "move":
            n, black = int(val.rstrip(".")), val.endswith("...")
            mismatch = dead or (board.fullmove_number, board.turn == chess.BLACK) != (n, black) or not _legal(board, toks[idx + 1][1], table)
            # a move the book omits explains a mismatch of one ply (recovered when the move is read): no other start position is needed
            if mismatch and (dead or not _skipped_move(board, to_san(toks[idx + 1][1], table), toks, idx + 1, val, table)):
                cur = 0 if dead else lookahead(board, idx)
                found, found_idx = [], []  # (score, board) of every candidate start that beats the current board, and its anchor index
                starts = ([chess.STARTING_BOARD_FEN] if n == 1 and not black else [])
                for ai, fen in enumerate(starts + list(anchors)):
                    cand = chess.Board(fen + (" b" if black else " w") + f" KQkq - 0 {n}")
                    cand.clean_castling_rights()
                    if (score := lookahead(cand, idx)) > cur:
                        found.append((score, cand)); found_idx.append(ai - len(starts))
                if found:
                    top = max(sc for sc, _ in found)
                    best = next(c for sc, c in found if sc == top)
                    # a single legal move proves little (many diagrams allow it): believe it only when exactly one diagram does
                    tops = [i for i, (sc, _) in enumerate(found) if sc == top]
                    played = any(m["ok"] and m["depth"] == 0 for m in moves)  # in the middle of a page the game is not abandoned for a position that
                    if top >= (3 if played else 2) or (not played and (len(tops) == 1 or sum(found_idx[i] < own for i in tops) == 1)):  # allows 1-2 moves
                        if top < 2 and len(tops) > 1:
                            best = next(found[i][1] for i in tops if found_idx[i] < own)
                        board, before_last, dead, stack = best, None, False, []
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
            # a bare move (no number in its run) is only a Black reply printed without its number ('13.b4 ... Ce4'): White's moves always carry
            # theirs, so a bare White-looking move is prose ('répliquer à Db3 par Db6')
            # a bare pawn move is believed when a variation of that very Black move follows it: 'b4 ( 19...bxa4 ... )'
            alt = (board.turn == chess.BLACK and idx + 2 < len(toks) and toks[idx + 1][0] == "open" and toks[idx + 2][0] == "num"
                   and toks[idx + 2][1].endswith("...") and int(toks[idx + 2][1].rstrip(".")) == board.fullmove_number)
            # ... or when it is a legal Black reply directly followed by the number of the next White move, and the line goes on legally after it:
            # 'Avec une initiative blanche. g6 16.axb5'
            if not alt and board.turn == chess.BLACK and idx + 2 < len(toks) and toks[idx + 1][0] == "num" and toks[idx + 2][0] == "move":
                n_, blk_ = int(toks[idx + 1][1].rstrip(".")), toks[idx + 1][1].endswith("...")
                if not blk_ and n_ == board.fullmove_number + 1:
                    try:
                        alt = _run_length(board, board.parse_san(to_san(val, table)), toks, idx, table, 2) >= 1  # the White move after it must be legal
                    except ValueError:
                        pass
            if dead or not (run_ok.get(idx) or (plausible_lone(val, pieces) and board.turn == chess.BLACK) or alt):
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
            if mv is None and stack and idx > 0 and toks[idx - 1][0] == "num":
                # a numbered move that is illegal in the variation but is exactly what an enclosing line expects: the OCR dropped a ']'
                n, black = int(toks[idx - 1][1].rstrip(".")), toks[idx - 1][1].endswith("...")
                for lvl in range(len(stack) - 1, -1, -1):
                    ob, obl, od = stack[lvl]
                    if (ob.fullmove_number, ob.turn == chess.BLACK) == (n, black) and _legal(ob, val, table):
                        mv, board, before_last, dead = ob.parse_san(to_san(val, table)), ob.copy(), obl, od
                        del stack[lvl:]
                        break
            inferred = None
            if mv is None and not dead and idx > 0 and toks[idx - 1][0] == "num":
                if skipped := _skipped_move(board, to_san(val, table), toks, idx, toks[idx - 1][1], table):
                    inferred = board.san(skipped[0])
                    board.push(skipped[0])  # not printed in the book: played silently so that the position after the printed move is right
                    mv = skipped[1]
            fixed = False
            if mv is None and not dead:
                mv = _repair(board, to_san(val, table), toks, idx, table)
                fixed = mv is not None
            if mv is None:
                # an illegal move that carries its own number, or a piece move / capture inside a numbered sequence, is an error (red,
                # the line stops). A bare pawn square in prose ('c6 se trouve sous tension') or a lone move-looking word ('...par Th1')
                # is just a mention: ignored
                if (idx > 0 and toks[idx - 1][0] == "num") or (plausible_lone(val, pieces) and run_ok.get(idx)):
                    moves.append({"raw": val, "san": None, "fen": None, "ok": False, "depth": len(stack), "span": [start, end]})
                    dead = True
                continue
            if not run_ok.get(idx):
                # a bare Black reply must be followed by the number of a White move ('Cg4' in a sentence, then '13...b6', is prose)
                # (the next number of this line: what lies inside brackets is skipped)
                depth, nxt = 0, None
                for t in toks[idx + 1:]:
                    depth += (t[0] == "open") - (t[0] == "close")
                    if depth < 0:
                        break
                    if t[0] == "num" and depth == 0:
                        nxt = t
                        break
                if nxt and nxt[1].endswith("...") != (board.turn == chess.WHITE):
                    continue
            prev = board.copy()
            san = board.san(mv); board.push(mv)
            before_last = prev
            closed = None
            moves.append({"raw": val, "san": san, "fen": board.fen(), "ok": True, "depth": len(stack), "ply": board.ply(), "span": [start, end], "uci": mv.uci(), **({"fixed": True} if fixed else {}), **({"after_skipped": inferred} if inferred else {})})
    return moves


def selfcheck():
    """python moves.py --check : OCR glitches seen in real books."""
    ok = lambda t: [m["san"] for m in replay(t) if m["ok"]]
    assert ok("1.e4 e62.d4 d53.Cd2 Cf64.e5 Cfd75.c3 c56.Fd3 Cc67.Ce2 cxd48.cxd4f69.exf6") == \
        "e4 e6 d4 d5 Nd2 Nf6 e5 Nfd7 c3 c5 Bd3 Nc6 Ne2 cxd4 cxd4 f6 exf6".split()  # spaces dropped
    t = "1.e4 e6 2.d4 d5 3.Cd2 Cf6 4.h3 empeche e5.h3 puis un Cg4 possible. 4...c5"  # 'e5.h3' and a bare 'Cg4' in prose
    assert ok(t)[-2:] == ["h3", "c5"]
    t = "1.e4 e6 2.d4 d5 3.Cd2 Cf6 4.e5 Cfd7 5.Cgf3 c5 [5...Cc6 6.Fd3 Cb4 7.Fe2] 6.c3"  # ']' present: control
    assert ok(t)[-1] == "c3"
    t = "1.e4 e6 2.d4 d5 3.Cd2 Cf6 4.e5 Cfd7 5.Cgf3 c5 [5...Cc6 6.Fd3 Cb4 7.Fe2 6.c3"  # dropped ']': 6.c3 goes back to the main line
    assert ok(t)[-1] == "c3" and [m["depth"] for m in replay(t)][-1] == 0
    t = "1.e4 e6 2.d4 d5 3.Cd2 Cf6 4.e5 Cfd7 5.c3 Un coup comme e5! pousse. 5...c5 6.Fd3"  # 'e5!' in prose is not Black's move
    assert ok(t)[-3:] == ["c3", "c5", "Bd3"] and ok(t).count("e5") == 1
    t = "1.e4 e6 2.d4 d5 3.Cc3 Cf6 4.e5 Cfd7 5.f4 c5 6.Cf3 Cc6 7.Fe3 a6 8.Dd2 b5 9.a3 Fb7 10.Fd3 Fe7 11.0-0 Dc7 12.dxc5 Cxc5 13.b4 Cd7 14.Ce2Opération domination 14...Cb6 15.Ced4"
    assert ok(t)[-3:] == ["Ne2", "Nb6", "Ned4"]  # a prose word glued to a move by the OCR ('Ce2Opération') does not hide the move
    t = "1.e4 e6 2.d4 d5 3.Cc3 Cf6 4.e5 Cf7 5.f4 c5 6.Cf3 Cc6 7.Fe3 a6"  # the OCR dropped a letter: 'Cf7' is 'Cfd7' (Cf7 is illegal, the next moves prove it)
    assert ok(t)[:12] == "e4 e6 d4 d5 Nc3 Nf6 e5 Nfd7 f4 c5 Nf3 Nc6".split() and len(ok(t)) == 14
    t = "1.e4 e5 2...Cc6 3.Fb5 a6 4.Fa4 Cf6 5.Cxe5 Fe7 6.0-0"  # the book omits White's 2nd move: only 2.Cf3 lets 5.Cxe5 be legal
    assert ok(t) == "e4 e5 Nc6 Bb5 a6 Ba4 Nf6 Nxe5 Be7 O-O".split() and replay(t)[2]["ply"] == 4
    t = "1.e4 e5 2...Cc6 3.Fb5 a6 4.Fa4 Cf6 5.0-0 Fe7 6.Te1"  # several White moves fit (Cf3, Ce2, Ch3): no guess
    assert ok(t) == ["e4", "e5"]
    t = "1.e4 e5 2...Cc6 3.Fb5"  # too little to tell which move is missing: no guess
    assert ok(t) == ["e4", "e5"]
    t = "1.e4 e5 2.Cf3L'attaque est claire. 2...Cc6 3.Fb5"  # a glued word that starts with an elision ('L'attaque') hides nothing
    assert ok(t) == "e4 e5 Nf3 Nc6 Bb5".split()
    t = "1.e4 e5 2.Cf3 Cc6 3.Fb5 [3.Fc4!?] Ce coup est plus solide. Cf6 4.d3 Fc5 5.0-0 d6] 3...a6 4.Fa4"  # ']' too early, then a stray ']'
    r = replay(t)
    assert all(m["ok"] for m in r) and [m["san"] for m in r if m["depth"] == 0] == "e4 e5 Nf3 Nc6 Bb5 a6 Ba4".split()
    t = "1.h4 g5 2.hxg5 h6 3.gxh6 Cf6 4.h7 Tg8 5.hxg8D Cxg8"  # promotion written without '=' ('hxg8D')
    assert ok(t)[-2:] == ["hxg8=Q", "Nxg8"] and len(ok(t)) == 10
    t = "1.e4 e5 2.Cf3 Cc6 3.Fb5 Le clou. a6 ( 3...Cf6 4.0-0 ) 4.Fa4"  # a bare pawn move followed by a variation of that very move IS a move
    r = replay(t)
    assert all(m["ok"] for m in r) and [m["san"] for m in r if m["depth"] == 0] == "e4 e5 Nf3 Nc6 Bb5 a6 Ba4".split()
    t = "1.e4 e5 2.Cf3 Cc6 3.Fb5 Le coup a6 est possible. 3...Cf6"  # a pawn square in prose is still prose
    assert [m["san"] for m in replay(t) if m["ok"]][-1] == "Nf6"
    t = "1.e4 e5 2.Cf3 Cc6 3.Fb5 a6 4.Fa4 Cf6 [4...b5 5.Fb3 Avec une initiative blanche. d6 6.c3] 5.0-0"  # a bare pawn move after commentary, then the White number
    assert all(m["ok"] for m in replay(t)) and [m["san"] for m in replay(t) if m["depth"] == 1][-2:] == ["d6", "c3"]
    rook = "3k4/8/8/8/8/8/8/3RK3"  # a diagram where 3.Td3 is legal
    assert [m["san"] for m in replay("3.Td3 Re8", None, "fr", [rook]) if m["ok"]] == ["Rd3+", "Ke8"]  # start of a page: one legal move is enough
    t = "1.e4 e5 2.Cf3 Cc6 3.Td3 Rd7"  # in the middle of a page a single legal move in some diagram does not move the game there
    assert [m["san"] for m in replay(t, None, "fr", [rook]) if m["ok"]] == ["e4", "e5", "Nf3", "Nc6"]
    wrong = "rnbqkbnr/pppp1ppp/8/4p3/4P3/2N5/PPPP1PPP/R1BQKBNR"  # a diagram where the 5 moves that follow are legal up to 5.Cxe5: not the game
    t = "1.e4 e5 2...Cc6 3.Fb5 a6 4.Fa4 Cf6 5.Cxe5 Fe7 6.0-0"  # the omitted 2.Cf3 is recovered before any other start position is tried
    assert [m["san"] for m in replay(t, None, "fr", [wrong]) if m["ok"]][-3:] == ["Nxe5", "Be7", "O-O"]
    print("moves.py self-check ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["--check"]:
        selfcheck(); sys.exit()
    args = sys.argv[1:]
    lang = "fr"
    if args[:1] == ["--lang"]:
        lang, args = args[1], args[2:]
    text = " ".join(b["block_content"] for p in args for b in json.load(open(p)) if b["block_label"] in ("text", "paragraph_title"))
    ms = replay(text, lang=lang)
    print(len(ms), "moves,", sum(not m["ok"] for m in ms), "illegal")
    print(" ".join(("" if m["depth"] == 0 else "(" * m["depth"]) + (m["san"] or "??" + m["raw"]) for m in ms))

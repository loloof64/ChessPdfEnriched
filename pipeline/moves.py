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
    tok = re.compile(rf"(?P<num>(?<![a-h])\d+(?:\.\.\.|\.(?!\.)))|(?P<move>{san})(?!(?!\d+\.|[a-h][1-8]|0-0|O-O|[A-Z]['’]?[a-zé]{{1,}})[A-Za-z0-9.])(?!=[A-Za-z0-9])|(?P<semi>;)|(?P<open>[\[(])|(?P<close>[\])])|(?P<res>1-0|0-1|1/2-1/2)")
    return tok, str.maketrans(p, "NBRQK"), p


def to_san(m: str, table) -> str:
    m = m.replace("0-0-0", "O-O-O").replace("0-0", "O-O")
    head = m.rstrip("!?")
    return head.translate(table) if "O" not in head else head


def plausible_lone(tok: str, pieces: str) -> bool:
    """A bare move with no move number next to it: only believe it if it looks like a move, not a pawn square in prose."""
    return ("x" in tok or tok[0] in pieces or tok.startswith(("0-0", "O-O")) or tok[-1] in "!?"  # 'a6!?': an annotation marks a move
            or "=" in tok or re.search(rf"[18][{pieces[:4]}]", tok) is not None)  # a promotion ('a1D', 'b8=D') is a move too


def _shows(board, tok, black, table):
    """True when `board` already shows the move `tok` played (by Black if `black`): the right piece stands on the destination square."""
    san = to_san(tok, table)
    sq = re.findall(r"[a-h][1-8]", san.split("=")[0])
    if "O" in san or not sq:
        return False
    p = board.piece_at(chess.parse_square(sq[-1]))
    return p is not None and p.color == (not black) and p.symbol().upper() == (san[0] if san[0] in "KQRBN" else "P")


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
        if kind and (score := _run_length(board, mv, toks, idx, table, look, True)) >= (1 if kind == 1 else 2):  # (a dropped letter is a stronger sign: the end of a variation leaves one move)
            found.append(((score, kind == 1), mv))
    if not found:
        return None
    top = max(k for k, _ in found)
    best = [mv for k, mv in found if k == top]
    return best[0] if len(best) == 1 else None


def _after_moves(board, toks, idx, table, n=2):
    """FEN of the pieces after the next `n` main-line moves following token idx (prose, numbers and bracketed variations skipped)."""
    b, depth, played = board.copy(), 0, 0
    for kind, val, *_ in toks[idx + 1:]:
        if kind in ("open", "close"):
            depth += 1 if kind == "open" else -1
            if depth < 0:
                break
        elif kind == "move" and not depth:
            try:
                b.push(b.parse_san(to_san(val, table)))
            except ValueError:
                break
            played += 1
            if played >= n:
                break
    return b.board_fen()


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
        score = 1 + _run_length(b, mv, toks, idx, table, look, True)
        b.push(mv)
        found.append((score, first, mv, _after_moves(b, toks, idx, table)))  # (candidates that reach the same position a move or two later are equivalent)
    if not found:
        return None
    top = max(sc for sc, *_ in found)
    best = [(first, mv, after) for sc, first, mv, after in found if sc == top]
    return (best[0][0], best[0][1]) if top >= need and len({after for *_, after in best}) == 1 else None


def tokens(text, lang="fr"):
    """[(kind, value, start, end)] in order; prose between tokens is recorded as ('prose', '')."""
    out, pos, parens = [], 0, 0
    for m in _lang(lang)[0].finditer(text):
        if m.group() == "(":
            parens += 1
        elif m.group() == ")":
            if parens:
                parens -= 1
            elif re.search(r"(?:^|[^\w.])[A-Za-z]$", text[max(0, m.start() - 2):m.start()]):
                if text[:m.start() - 1].rstrip().endswith(","):
                    out.append(("semi", ";", m.start(), m.end()))  # '57.Ff1=, B) 56.Ff2': the OCR read the ';' between two alternatives as a comma
                continue  # 'A)' / 'B)': the label of an alternative (no parenthesis open), not a closing parenthesis
        if text[pos:m.start()].strip(" \n\t,;:.()"):
            out.append(("prose", "", pos, m.start()))
        kind = m.lastgroup
        out.append((kind, m.group(kind), m.start(), m.end()))
        pos = m.end()
    return out


def _close_ahead(toks, idx):
    """True when a ']' later on closes the bracket that is open at idx: the variation goes on (a move that does not fit it is its own alternative, not the
    main line coming back after a dropped ']')."""
    depth = 0
    for t in toks[idx + 1:]:
        if t[0] == "open":
            depth += 1
        elif t[0] == "close":
            if depth == 0:
                return True
            depth -= 1
    return False


def _stray_close(toks, reach=60):
    """Index of the ']' the OCR/book put too early: a closing bracket with nothing open (a stray ']') means the last variation of the same kind
    that closed just before it (at most `reach` tokens away) goes on up to there. None when there is no stray bracket."""
    depth, last_top = 0, {}
    for k, (kind, val, *_) in enumerate(toks):
        if kind == "open":
            depth += 1
        elif kind == "close":
            if depth == 0:
                c = last_top.get(val)
                return c if c is not None and k - c <= reach else None
            depth -= 1
            if depth == 0:
                last_top[val] = k
    return None


def replay(text, start=None, lang="fr", anchors=(), own=0, toks=None, prev=None):
    """[{san, fen, ok, depth, ply, raw}] ; mainline + variations. Stops a line at its first illegal move.
    `anchors`: piece placements of diagrams. A move number that does not follow the board (or follows a dead line) may restart
    the game from one of them (the first `own` are the page's own diagrams, preferred on ties; side to move and move number come from the printed number) when that makes the next moves legal.
    `prev`: the position before `start` (a page that begins with a variation of the previous page's last move needs it)."""
    if toks is None:
        toks = tokens(text, lang)
        if (c := _stray_close(toks)) is not None:  # the variation before the stray ']' probably goes on: keep that reading when it is better
            alt = replay(text, start, lang, anchors, own, toks[:c] + [("prose", "", toks[c][2], toks[c][3])] + toks[c + 1:], prev)
            plain = replay(text, start, lang, anchors, own, toks, prev)
            bad = lambda ms: sum(not m["ok"] for m in ms)
            return alt if (bad(alt), -len(alt)) < (bad(plain), -len(plain)) else plain
    _, table, pieces = _lang(lang)
    board, before_last = chess.Board(start) if start else chess.Board(), chess.Board(prev) if prev else None
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
    implicit = set()  # indices of the `stack` entries that are variations never opened by a bracket ('Si 3.Rh6 ...'): they do not hide a new game
    bare_alt = None  # index of the last move taken as an implicit alternative to the move before it
    closed = None  # (board of the variation just closed, index of its ']'): the OCR sometimes closes a variation too early
    def future(b, idx):
        """Evidence that the game goes on from board b at token idx: the legal moves of the next tokens up to the first illegal one of the main
        line, variations included (a variation often tells two candidate start positions apart: the main line alone is the same for both)."""
        score = 0
        for m in replay("", b.fen(), lang, toks=toks[idx:idx + 80]):
            if m["ok"]:
                score += 1
            elif m["depth"] == 0:
                break  # the end of this game: what follows (another position's solution) says nothing about this start
            else:
                score -= 1  # an illegal move inside a variation weighs against this start but does not end the count
        return score

    skip_move = None  # index of a mentioned move the diagram already shows: not played
    comment = False  # the '(' after an implicit alternative opened a comment: the book's main line goes on after it
    for idx, (kind, val, start, end) in enumerate(toks):
        if idx == skip_move:
            continue
        implicit = {i for i in implicit if i < len(stack)}  # entries only leave the stack from the top
        if kind == "open" and bare_alt == idx - 1 and idx + 1 < len(toks) and toks[idx + 1][0] != "num":
            comment = True
        if kind == "num" and stack and len(stack) - 1 in implicit and idx + 1 < len(toks) and toks[idx + 1][0] == "move":
            # inside an unbracketed alternative: a numbered move that the MAIN line expects and allows brings the book back to it
            ob, obl, od = stack[-1]
            if (ob.fullmove_number, ob.turn == chess.BLACK) == (int(val.rstrip(".")), val.endswith("...")) and _legal(ob, toks[idx + 1][1], table):
                # (when the alternative line accepts that number too, the one the text goes on in better wins; a tie goes back to the main line)
                alt_ok = (board.fullmove_number, board.turn == chess.BLACK) == (int(val.rstrip(".")), val.endswith("...")) and _legal(board, toks[idx + 1][1], table)
                if not alt_ok or future(ob, idx) >= future(board, idx):
                    board, before_last, dead = ob.copy(), obl, od
                    stack.pop()
        if anchors and kind == "num" and all(i in implicit for i in range(len(stack))) and idx + 1 < len(toks) and toks[idx + 1][0] == "move":
            n, black = int(val.rstrip(".")), val.endswith("...")
            mismatch = dead or (board.fullmove_number, board.turn == chess.BLACK) != (n, black) or not _legal(board, toks[idx + 1][1], table)
            # a move the book omits explains a mismatch of one ply (recovered when the move is read): no other start position is needed
            alt_of_last = (before_last is not None and not dead and (before_last.fullmove_number, before_last.turn == chess.BLACK) == (n, black)
                           and _legal(before_last, toks[idx + 1][1], table) and not (moves and moves[-1]["raw"].rstrip("!?") == toks[idx + 1][1].rstrip("!?")))  # 'Si 3.Rh6': an alternative to the move just played
            # (an alternative to the last move is only the better reading when the line goes on from there: a new exercise often starts with a
            # move that was also legal before the last one ('1.Da3#' then, in the next exercise, '1.Fd5+'); a diagram that replays far more wins)
            if mismatch and (alt_of_last or dead or not _skipped_move(board, to_san(toks[idx + 1][1], table), toks, idx + 1, val, table)):
                cur = future(before_last, idx) if alt_of_last else 0 if dead else future(board, idx)
                found, found_idx = [], []  # (score, board, mention) of every candidate start that beats the current board, and its anchor index
                starts = ([chess.STARTING_BOARD_FEN] if n == 1 and not black else [])
                for ai, fen in enumerate(starts + list(anchors)):
                    cand = chess.Board(fen + (" b" if black else " w") + f" KQkq - 0 {n}")
                    cand.clean_castling_rights()
                    if (score := future(cand, idx)) > cur:
                        found.append((score, cand, None)); found_idx.append(ai - len(starts))
                    # the diagram may already show the move ('Les Noirs viennent de jouer 44...Fe8'): the text then goes on after it
                    after = chess.Board(fen + (" w" if black else " b") + f" KQkq - 0 {n + black}")
                    after.clean_castling_rights()
                    if idx + 2 < len(toks) and _shows(after, toks[idx + 1][1], black, table) and (score := future(after, idx + 2) + 1) > cur:
                        found.append((score, after, idx + 1)); found_idx.append(ai - len(starts))
                if found:
                    top = max(f[0] for f in found)
                    best, mention = next((f[1], f[2]) for f in found if f[0] == top)
                    # a single legal move proves little (many diagrams allow it): believe it only when exactly one diagram does
                    tops = [i for i, f in enumerate(found) if f[0] == top]
                    played = any(m["ok"] and m["depth"] == 0 for m in moves)  # in the middle of a page the game is not abandoned for a position that
                    if alt_of_last and (cur > 2 or top < cur + 3):
                        pass  # the alternative to the last move stays when it goes on legally ('Si 3.Rh6 ...'): it is dropped only when it dies at once
                    elif top >= (3 if played else 2) or (not played and (len(tops) == 1 or sum(found_idx[i] < own for i in tops) == 1)):  # allows 1-2 moves
                        if top < 2 and len(tops) > 1:
                            best, mention = next(found[i][1:] for i in tops if found_idx[i] < own)
                        board, before_last, dead, stack, implicit, skip_move = best, None, False, [], set(), mention
        if kind == "num" and dead and idx + 1 < len(toks) and toks[idx + 1][0] == "move":
            # after an illegal move (often an alternative given in prose without brackets: 'Si 24.Fxd5 ...') resume at the next move
            # number that is exactly the one the board expects and whose move is legal
            n, black = int(val.rstrip(".")), val.endswith("...")
            if n == board.fullmove_number and black == (board.turn == chess.BLACK) and _legal(board, toks[idx + 1][1], table):
                dead = False
        if kind == "num" and val == "1." and all(i in implicit for i in range(len(stack))) and board.ply() > 0 and idx + 1 < len(toks) and toks[idx + 1][0] == "move":
            board, before_last, dead, stack, implicit = chess.Board(), None, False, [], set()  # "1." after moves have been played: a new game starts here
        elif kind == "open" and not (bare_alt == idx - 1 and idx + 1 < len(toks) and toks[idx + 1][0] != "num"):  # (see the implicit alternative)
            stack.append((board, before_last, dead)); board = (before_last or board).copy(); dead = False; branch = board.copy()
        elif kind == "semi" and stack:  # sibling variation: restart from the same branch point
            board = stack[-1][1].copy() if stack[-1][1] else board; dead = False
        elif kind == "close" and stack:
            closed = (board.copy(), idx)
            while len(stack) > 1 and len(stack) - 1 in implicit:  # the bracket ends the unbracketed alternatives still open inside it
                stack.pop()
            board, before_last, dead = stack.pop()
        elif kind == "move":
            if comment and toks[idx - 1][0] == "prose" and stack and len(stack) - 1 in implicit and _legal(stack[-1][0], val, table):
                board, before_last, dead = stack.pop()  # the first move after the comment, legal in the main line too: back to the main line
            if toks[idx - 1][0] != "open":
                comment = False
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
            if mv is None and stack and idx > 0 and toks[idx - 1][0] == "num" and "semi" not in (toks[idx - 2][0], toks[max(idx - 3, 0)][0]) and not _close_ahead(toks, idx):
                # a numbered move that is illegal in the variation but is exactly what an enclosing line expects: the OCR dropped a ']'
                n, black = int(toks[idx - 1][1].rstrip(".")), toks[idx - 1][1].endswith("...")
                for lvl in range(len(stack) - 1, -1, -1):
                    ob, obl, od = stack[lvl]
                    if (ob.fullmove_number, ob.turn == chess.BLACK) == (n, black) and _legal(ob, val, table):
                        mv, board, before_last, dead = ob.parse_san(to_san(val, table)), ob.copy(), obl, od
                        del stack[lvl:]
                        break
            if mv is None and not dead and idx > 1 and toks[idx - 1][0] == "num" and (toks[idx - 2][0] == "open" or "semi" in (toks[idx - 2][0], toks[max(idx - 3, 0)][0])):
                # the first move of a bracket that does not fit the position before the last move: the book varies an EARLIER move of the line
                # (a White move written after Black's reply: '13.Rg4! h3 [13.Rg2?? ...]'), or the line an unbracketed alternative left
                n_, blk_ = int(toks[idx - 1][1].rstrip(".")), toks[idx - 1][1].endswith("...")
                # (after a ';' the book gives a sibling of a line already played ('A) 3...Cc4 ... ; B) 3...a4'): the position before that number, in this line)
                sib = toks[idx - 2][0] != "open"  # (the ';' may be followed by a label: 'B)')
                earlier = [chess.Board(m["before"]) for m in reversed(moves[-(60 if sib else 8):]) if m["ok"] and m["depth"] == len(stack) - (not sib) and m.get("before")]
                earlier += [stack[k][1] for k in sorted(implicit, reverse=True) if k < len(stack) - 1 and stack[k][1] is not None]
                for cand in earlier:
                    if (cand.fullmove_number, cand.turn == chess.BLACK) == (n_, blk_) and _legal(cand, val, table):
                        board = cand.copy()
                        mv = board.parse_san(to_san(val, table))
                        break
            if mv is None and not dead and before_last is not None and idx > 0 and toks[idx - 1][0] == "num":
                n_, blk_ = int(toks[idx - 1][1].rstrip(".")), toks[idx - 1][1].endswith("...")
                if ((before_last.fullmove_number, before_last.turn == chess.BLACK) == (n_, blk_) and _legal(before_last, val, table)
                        and not (moves and moves[-1]["raw"].rstrip("!?") == val.rstrip("!?"))):  # (the same move again is a mention)
                    if not stack or len(stack) - 1 not in implicit:  # an unbracketed alternative to the move just played ('Si 3.Rh6'): a variation
                        stack.append((board, before_last, dead))  # that the line may leave again for the line it came from
                        implicit.add(len(stack) - 1)
                    board = before_last.copy()
                    mv = board.parse_san(to_san(val, table))
            if (mv is None and not dead and before_last is not None and idx > 0 and toks[idx - 1][0] == "move" and run_ok.get(idx)
                    and plausible_lone(val, pieces) and _legal(before_last, val, table) and moves and moves[-1]["raw"].rstrip("!?") != val.rstrip("!?")):
                # a bare piece move right after a move, illegal for the side to move but legal where the last move was played: the book gives an
                # alternative to that move without brackets or number ('4.Rd6 Re6 (plus visuel ... d3 5.Re5': 4.Re6 is meant): believed when the text
                # goes on legally from there (an illegal move that is legal for the other side is often just an OCR or book typo)
                alt_board = before_last.copy()
                alt_board.push_san(to_san(val, table))
                if future(alt_board, idx + 1) >= 2:
                    stack.append((board, before_last, dead))
                    implicit.add(len(stack) - 1)
                    board = before_last.copy()
                    mv = board.parse_san(to_san(val, table))
                    bare_alt = idx
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
            if (mv is None and not dead and moves and moves[-1]["ok"] and moves[-1]["depth"] == len(stack) and before_last is not None
                    and idx > 0 and toks[idx - 1][0] == "num"):
                # the previous move was probably misread by the OCR ('Ce4' for 'Cc4': legal, but nothing goes on after it): a legal move of that
                # position one edit away from it, after which THIS numbered move and the next ones are legal, replaces it (only when it is the single best)
                head, found = to_san(moves[-1]["raw"], table).rstrip("+#!?"), []  # (as printed: 'Ce4', whose SAN here is 'Nxe4')
                for alt in before_last.legal_moves:
                    if _edit(head, before_last.san(alt).rstrip("+#")) and alt.uci() != moves[-1]["uci"]:
                        b = before_last.copy()
                        b.push(alt)
                        try:
                            nxt = b.parse_san(to_san(val, table))
                        except ValueError:
                            continue
                        if (score := _run_length(b, nxt, toks, idx, table, 12, True)) >= 2:
                            found.append((score, alt, b))
                if found and sum(f[0] == max(g[0] for g in found) for f in found) == 1:
                    _, alt, b = max(found, key=lambda f: f[0])
                    moves[-1].update(san=before_last.san(alt), fen=b.fen(), uci=alt.uci(), fixed=True)
                    board = b
                    mv = board.parse_san(to_san(val, table))
            if mv is None and any(m["ok"] and m["depth"] == len(stack) and m["raw"].rstrip("!?") == val.rstrip("!?") for m in moves[-6:]):
                continue  # the book mentions again a move it has just given ('3.Rf4 serait une erreur ... 3.Rf4??'): not an illegal move
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
                depth, nxt, mention = 0, None, None  # (indices into toks)
                for k in range(idx + 1, len(toks)):
                    t = toks[k]
                    depth += (t[0] == "open") - (t[0] == "close")
                    if depth < 0:
                        break
                    if t[0] == "num" and depth == 0:
                        if t[1].endswith("...") and int(t[1].rstrip(".")) == board.fullmove_number and mention is None:
                            mention = k  # maybe a mention of another Black move at this very number ('... contrairement à 12...e5.'), maybe the real move
                            continue
                        nxt = k
                        break
                if mention is not None and nxt is not None:
                    # the bare move is believed over the numbered one only when the next White move is legal after it and not after the numbered one
                    def follows(first):
                        b = board.copy()
                        try:
                            b.push(first)
                        except ValueError:
                            return False
                        return nxt + 1 < len(toks) and toks[nxt + 1][0] == "move" and _legal(b, toks[nxt + 1][1], table)
                    try:
                        other = board.parse_san(to_san(toks[mention + 1][1], table)) if toks[mention + 1][0] == "move" else None
                    except ValueError:
                        other = None
                    if not (follows(mv) and not (other and follows(other))):
                        nxt = mention
                nxt = toks[nxt if nxt is not None else mention] if (nxt is not None or mention is not None) else None
                if nxt and nxt[1].endswith("...") != (board.turn == chess.WHITE):
                    continue
            prev = board.copy()
            san = board.san(mv); board.push(mv)
            before_last = prev
            closed = None
            moves.append({"raw": val, "san": san, "fen": board.fen(), "ok": True, "depth": len(stack), "ply": board.ply(), "span": [start, end], "uci": mv.uci(), "before": prev.fen(), **({"fixed": True} if fixed else {}), **({"after_skipped": inferred} if inferred else {})})
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
    t = "1.e4 e6 2.d4 d5 3.Cd2 Cf6 4.e5 Cfd7 5.Cgf3 c5 [5...Cc6 A) 6.Fd3 Cb4 7.Fe2] 6.c3"  # 'A)' / 'B)' label alternatives: they do not close the bracket
    assert ok(t)[-1] == "c3" and [m["depth"] for m in replay(t)][-1] == 0 and [m["depth"] for m in replay(t)][-2] == 1
    t = "1.e4 e6 2.d4 d5 3.Cd2 Cf6 4.e5 Cfd7 5.Cgf3 c5 [5...Cc6 A) 6.Fd3 Cb4 7.Fe2 ; B) 6...Cxe5 7.Cxe5] 6.c3"  # 'B)' after a ';': a sibling of A), from the position before ITS first number
    assert all(m["ok"] for m in replay(t)) and [m["san"] for m in replay(t) if m["depth"] == 1][-2:] == ["Nxe5", "Nxe5"]
    t = "1.e4 e5 2.Cf3 Cc6 3.Fb5 a6 4.Fa4 Fc4 (plus actif. Cf6 5.O-O"  # 'Fc4' (White) is an alternative to 4.Fa4, written without brackets: not an illegal Black reply
    r = replay(t)
    assert all(m["ok"] for m in r) and [m["san"] for m in r if m["depth"] == 1] == ["Bc4"] and [m["san"] for m in r][-2:] == ["Nf6", "O-O"]  # the main line goes on after the comment
    # two exercises on a page: the second one starts with a move that was also legal before the first one's last move ('1.Rf1'), but only the
    # diagram of the second one replays the whole line
    t = "1.Ta8# Le seul coup. Exercice suivant : 1.Rf1 Rf7 2.a4 Re7 3.a5 Rd7 4.a6"
    r = replay(t, "6k1/5ppp/8/8/8/8/8/R5K1 w - - 0 1", "fr", ["4k3/8/8/8/8/8/PPP5/4K3"], own=1)
    assert all(m["ok"] for m in r) and [m["san"] for m in r][-1] == "a6" and len(r) == 8
    # 'Les Noirs viennent de jouer 44...Fe8': the diagram already shows that move (a mention). A misread of the diagram (king one square off) where the move is
    # still to be played must not win over the exact reading, which does replay the whole line
    t = "Les Noirs viennent de jouer 44...Fe8 Choix : A) : Rf2 B) : Rd2 C) : Autre coup 45. Rf2! Suite. [45. Rd2? Fh5 46. Fa4 Fg4 47. Fc2 Rh6-+]"
    r = replay(t, None, "fr", ["6k1/3b4/4p3/3pP1b1/2pP4/2P1N3/2B1K3/8", "4b3/6k1/4p3/3pP1b1/2pP4/2P1N3/2B1K3/8"], own=2)
    assert all(m["ok"] for m in r) and [m["san"] for m in r][-1] == "Kh6" and "Be8" not in [m["san"] for m in r], [(m["san"], m["ok"]) for m in r]
    tk = tokens("[1.e4 e5] 2.Cf3 (2.d4 d5) 2...Cc6 3.Fb5]")  # the stray ']' goes with the earlier ']' of the same kind, not with the ')' in between
    assert tk[_stray_close(tk)][1] == "]"
    t = "1.e4 e5 2.Cf3 Cc6 3.Fb5 a6 4.Fa4 Cf6 [4...Fc5 car 4..Cxe4 ne marche pas 5.O-O] 5.O-O"  # '4..Cxe4': a mention, not the White move 4 followed by Cxe4
    assert all(m["ok"] for m in replay(t)) and [m["san"] for m in replay(t) if m["depth"] == 1] == ["Bc5", "O-O"]
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
    t = "1.e4 e5 2.Cf3 Cc6 3.Fb5 Cf6En échangeant le Fou, les Noirs jouent bien. 4.0-0"  # a glued 2-letter word ('En')
    assert [m["san"] for m in replay(t) if m["ok"]][-2:] == ["Nf6", "O-O"]
    right, wrong = "Q7/8/8/3K4/8/8/pk6/8", "1K6/8/8/8/1Q6/8/k1p5/8"  # both allow 1.Db7+ Ra1; only the first allows the variation 1...Rc2 2.Dc6+ Rb2
    t = "1.Db7+ Ra1 Cherche le Pat. [1...Rc2 C'est une autre possibilite. 2.Dc6+ Rb2 3.Db5+ Rc2] 2.Dc6 Rb2"
    assert all(m["ok"] for m in replay(t, None, "fr", [wrong, right]))  # the start that also makes the variations legal wins the tie
    t = "1.e4 e5 2.Cf3 Si 2.Cc3 Cf6 3.Fb5"  # an unbracketed alternative to the move just played (same number and colour): from the position before it
    assert [m["san"] for m in replay(t) if m["ok"]] == "e4 e5 Nf3 Nc3 Nf6 Bb5".split() and all(m["ok"] for m in replay(t))
    t = "1.e4 e5 2.Cf3 Cc6 3.Fb5 Le coup 3.Fb5?? est annonce comme faible. 3...a6"  # the book repeats a move it has just given: a mention, not an error
    assert all(m["ok"] for m in replay(t)) and [m["san"] for m in replay(t)][-1] == "a6"
    t = "1.e4 e5 [1...c5 2.Cf3 Cc6 Si 2...d6 3.d4 cxd4] 2.Cf3"  # an unbracketed alternative INSIDE a variation, closed by the bracket
    assert all(m["ok"] for m in replay(t)) and [m["san"] for m in replay(t)][-1] == "Nf3"
    t = "1.e4 e5 [1...c5 2.Cf3 Cc6 Si 2...d6 3.d4 cxd4 3.Fb5 g6] 2.Cf3"  # ... and left for the variation's own line by the next numbered move
    r = replay(t)
    assert all(m["ok"] for m in r) and [m["san"] for m in r if m["depth"] == 1][-2:] == ["Bb5", "g6"]
    t = "1.g7 h3 2.g8D h2 3.Rg6 4.Rf5+ Rf1 [4...Rh1 5.Rg4] 5.Dh8 Rg1 6.Da1+ Rg2 7.Da2+ Rg1 8.Rg4 h1D 9.Rg3"  # Black's 3rd move is omitted: Rg1 or Rg2, the
    assert all(m["ok"] for m in replay(t, "8/7K/6P1/8/7p/8/8/7k w - - 0 1", "fr"))  # book goes on the same either way (4...Rf1): any of them will do
    t = "1.e4 e5 2.Cf3 Cc6 Si 2...d6 3.d4 Fg4 4.Fb5 3.Fb5 a6"  # after 'Si 2...d6' the book plays on in THAT line (3.d4 Fg4 is only legal there): both lines accept
    r = replay(t)  # a number 3, the text that follows decides
    assert all(m["ok"] for m in r) and [m["san"] for m in r if m["depth"] == 1] == ["d6", "d4", "Bg4", "Bb5+"] and [m["san"] for m in r][-2:] == ["Bb5", "a6"]
    t = "1.e4 e5 2.Cf3 Cc6 3.Fb5 Si 3.Fc4 Cf6 [3.Cc3 Cf6] 3...a6 4.Fa4"  # a bracket right after an unbracketed alternative varies the MAIN move (3.Fb5), not the alternative
    r = replay(t)
    assert all(m["ok"] for m in r) and [m["san"] for m in r][-2:] == ["a6", "Ba4"]
    t = "1.e4 e5 2.Cf3 Cc6 3.Fb5 a6 [3.Fc4 Cf6] 4.Fa4"  # a variation of White's 3rd move written AFTER Black's reply: it starts before 3.Fb5, not before 3...a6
    r = replay(t)
    assert all(m["ok"] for m in r) and [m["san"] for m in r if m["depth"] == 1] == ["Bc4", "Nf6"] and [m["san"] for m in r][-1] == "Ba4"
    t = "1.Re2 Les Noirs promeuvent. a1D Les Blancs. 2.Rf2"  # a Black promotion written 'a1D' (a1=D) with no number: a move, not a square in prose
    assert [m["san"] for m in replay(t, "4k3/8/8/8/8/8/p7/4K3 w - - 0 1", "fr") if m["ok"]] == ["Ke2", "a1=Q", "Kf2"]
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

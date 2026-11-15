"""Step 5c: replay a move sequence with python-chess to validate and repair figurine letters.

A move is (letter, text): letter in 'KQRBN' = figurine class guessed by the image classifier, '?' = a figurine is
there but its class is unknown, '' = no figurine seen (pawn move or castling). text = SAN without the piece letter
('xd5', 'ac1', 'e4+', '0-0'). Each move gets a status:
  ok         the given letter gives a legal move
  fixed      the given letter was illegal and exactly one other piece makes it legal
  ambiguous  several readings are legal (e.g. 'f3' = pawn or knight): the first legal one is played, the rest listed
  illegal    nothing is legal: the sequence stops there (OCR/classifier error, goes to the "to review" list)
"""
import chess

PIECES = "NBRQK"  # most to least frequent non-pawn mover: used as the tie-break when the class is unknown


def san_ok(board, san):
    """Legal move for san, or None. A printed '+' must really give check (an OCR-dropped '+' is not enforced)."""
    try:
        m = board.parse_san(san)
    except ValueError:
        return None
    return m if "+" not in san and "#" not in san or board.gives_check(m) else None


def decode(board, moves):
    """[(san, status, alternatives)] ; stops at the first illegal move."""
    board = board.copy()
    out = []
    for letter, text in moves:
        text = text.replace("0-0-0", "O-O-O").replace("0-0", "O-O")
        given = letter if letter in PIECES else ""
        legal = {p: m for p in ([given] if letter in PIECES else PIECES if letter == "?" else [""]) if (m := san_ok(board, p + text))}
        status = "ok"
        if not legal:  # guess wrong or figurine missed: try every reading
            legal = {p: m for p in (PIECES if letter else ("",) + tuple(PIECES)) if (m := san_ok(board, p + text))}  # a seen figurine is never a pawn
            status = "fixed"
        elif letter == "?" and len(legal) == 1:
            status = "ok"
        if not legal:
            out.append((letter + text, "illegal", []))
            break
        if len(legal) > 1:
            status = "ambiguous"
        p, m = next(iter(legal.items()))
        out.append((board.san(m), status, [q + text for q in legal if q != p]))
        board.push(m)
    return out


if __name__ == "__main__":
    start = chess.Board()
    seq = [("", "d4"), ("N", "f6"), ("", "c4"), ("", "e6"), ("N", "c3"), ("", "d5"), ("", "cxd5"), ("N", "xd5")]
    r = decode(start, seq)
    assert [s for s, _, _ in r] == "d4 Nf6 c4 e6 Nc3 d5 cxd5 Nxd5".split() and all(s == "ok" for _, s, _ in r)
    # classifier says rook for 'Nf6'-type error: knight move labelled R -> fixed
    r = decode(start, [("", "d4"), ("R", "f6")])
    assert r[1][:2] == ("Nf6", "fixed"), r
    # figurine missed (Qd2+ read as pawn): after a short line only the queen can go there
    r = decode(chess.Board("8/8/8/6k1/8/8/Q7/4K3 w - - 0 1"), [("", "d2+")])
    assert r[0][:2] == ("Qd2+", "fixed"), r
    # 'f3' with the knight symbol dropped is ambiguous: pawn f3 / Nf3 -> '?' keeps it a piece, '' keeps the pawn
    r = decode(chess.Board(), [("?", "f3")]); assert r[0][:2] == ("Nf3", "ok"), r
    r = decode(chess.Board(), [("", "f3")]); assert r[0][:2] == ("f3", "ok"), r
    r = decode(chess.Board(), [("", "xd5")]); assert r[0][1] == "fixed" or r[0][1] == "illegal", r
    # first illegal move stops the sequence
    r = decode(chess.Board(), [("", "e4"), ("", "e5"), ("B", "b5"), ("", "e5")]); assert [x[1] for x in r] == ["ok", "ok", "ok", "illegal"], r
    print("ok")

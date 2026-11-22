"""Step 4.4: plausibility checks on a FEN read from a diagram, feeding the reader's "to review" list."""
import chess


def issues(board: chess.Board) -> list[str]:
    """Empty list = plausible. Uses python-chess status flags plus a promotion-aware piece count."""
    found = [f.name.lower() for f in chess.Status if f in board.status() and f not in (chess.STATUS_VALID, chess.STATUS_OPPOSITE_CHECK)]  # side to move is unknown
    for color, name in ((chess.WHITE, "white"), (chess.BLACK, "black")):
        n = lambda t: len(board.pieces(t, color))
        # every piece beyond the starting set must come from a promoted pawn
        extra = sum(max(0, n(t) - s) for t, s in ((chess.QUEEN, 1), (chess.ROOK, 2), (chess.BISHOP, 2), (chess.KNIGHT, 2)))
        if n(chess.PAWN) + extra > 8:
            found.append(f"too_many_{name}_pieces_for_pawns")
    return found
    # ponytail: does not catch a lone ghost bishop (e.g. 3 bishops with few pawns is legal); needs the classifier route


def add_missing_king(board: chess.Board) -> chess.Board:
    """A diagram that shows ONE army only (a set-up of the Hedgehog, say) has no king for the other side, which would make it implausible:
    that side gets a king on its back rank, on a free square the shown army does not attack (nearest the e-file). `board` is changed in place."""
    for color in (chess.WHITE, chess.BLACK):
        if board.occupied_co[color] or board.king(not color) is None:
            continue
        back = 0 if color == chess.WHITE else 7
        free = [sq for sq in chess.SQUARES if board.piece_at(sq) is None and not board.is_attacked_by(not color, sq)]
        if free:  # (no free square: left as it is, the reading stays implausible)
            board.set_piece_at(min(free, key=lambda sq: (abs(chess.square_rank(sq) - back), abs(chess.square_file(sq) - 4), sq)), chess.Piece(chess.KING, color))
    return board


def repair_king_colors(board: chess.Board) -> chess.Board:
    """The readers sometimes mix up the colours of the two kings (outlined white vs filled black pieces in small prints). When BOTH kings are
    clearly nearer (by rank) to the pawns of the other colour than to their own, swap them, if that leaves a plausible position.
    Orientation-free: only ranks of the pawns are compared. Returns `board` itself when nothing is repaired."""
    wk, bk = board.king(chess.WHITE), board.king(chess.BLACK)
    wp, bp = board.pieces(chess.PAWN, chess.WHITE), board.pieces(chess.PAWN, chess.BLACK)
    if wk is None or bk is None or not wp or not bp:
        return board
    mean = lambda squares: sum(chess.square_rank(sq) for sq in squares) / len(squares)
    mw, mb = mean(wp), mean(bp)
    gain = 0.0  # how much nearer the kings get to their own pawns after the swap
    for king, own, other in ((wk, mw, mb), (bk, mb, mw)):
        g = abs(chess.square_rank(king) - own) - abs(chess.square_rank(king) - other)
        if g <= 0:  # this king is already nearer its own pawns (or equally near): leave the position alone
            return board
        gain += g
    if gain < 2:
        return board
    fixed = board.copy()
    fixed.set_piece_at(wk, chess.Piece(chess.KING, chess.BLACK))
    fixed.set_piece_at(bk, chess.Piece(chess.KING, chess.WHITE))
    return fixed if not issues(fixed) else board


def colors_only_differ(a: chess.Board, b: chess.Board) -> bool:
    """The two boards differ, but only in who owns the pieces: same squares occupied, same piece types."""
    types = lambda x: {sq: p.piece_type for sq, p in x.piece_map().items()}
    return a.board_fen() != b.board_fen() and types(a) == types(b)


if __name__ == "__main__":
    ok = lambda fen: issues(chess.Board(fen + " w - - 0 1"))
    assert ok("6k1/pp6/2p5/3p4/1P1P4/8/P7/6K1") == []
    b = add_missing_king(chess.Board("2r1r1k1/1bqnbppp/pp1ppn2/8/8/8/8/8 w - - 0 1"))  # Black only: a white king on e1, not attacked
    assert b.king(chess.WHITE) == chess.E1 and ok(b.board_fen()) == []
    b = add_missing_king(chess.Board("8/8/8/8/8/8/4r3/6k1 w - - 0 1"))  # e1 is attacked by the rook
    assert b.king(chess.WHITE) == chess.D1  # (f1 is next to the black king)
    assert add_missing_king(chess.Board(None)).board_fen() == "8/8/8/8/8/8/8/8"  # an empty board stays empty
    assert "too_many_kings" in ok("6k1/pp6/2p4K/3p4/1P1P4/8/P7/6K1")
    assert "pawns_on_backrank" in ok("P5k1/8/8/8/8/8/8/6K1")
    assert "no_black_king" in ok("8/8/8/8/8/8/8/6K1")
    assert ok("2b1kr2/p6r/1pB1pQ2/5p2/2pP4/2P5/PP3P2/R5K1") == []  # black in check, black to move
    assert ok("6k1/8/8/8/8/8/PPPPPPPP/QQ4K1") != []  # 8 pawns + 2 queens
    same = chess.Board("4k3/pp3ppp/4p3/3pP3/3N1P2/8/PPP3PP/4K3 w - - 0 1")  # a reading and the same one with the colours of K, k, N swapped
    swapped = chess.Board("4K3/pp3ppp/4p3/3pP3/3n1P2/8/PPP3PP/4k3 w - - 0 1")
    assert colors_only_differ(same, swapped) and not colors_only_differ(same, same)
    assert not colors_only_differ(same, chess.Board("4k3/pp3ppp/4p3/3pP3/3Q1P2/8/PPP3PP/4K3 w - - 0 1"))  # a piece type differs
    swapped_kings = chess.Board("6K1/pp3ppp/4p3/3pP3/3P4/8/PP3PPP/6k1 w - - 0 1")  # a real misreading: kings of the wrong colours
    assert repair_king_colors(swapped_kings).board_fen() == "6k1/pp3ppp/4p3/3pP3/3P4/8/PP3PPP/6K1"
    right = chess.Board("6k1/pp3ppp/4p3/3pP3/3P4/8/PP3PPP/6K1 w - - 0 1")
    assert repair_king_colors(right) is right
    raid = chess.Board("8/pp3ppp/8/8/3k4/8/PP3PPP/6K1 w - - 0 1")  # a king in the enemy camp: only one king is wrong, leave it
    assert repair_king_colors(raid) is raid
    assert repair_king_colors(chess.Board("8/8/8/8/8/8/8/K6k w - - 0 1")).board_fen() == "8/8/8/8/8/8/8/K6k"  # no pawns: nothing to compare
    print("ok")

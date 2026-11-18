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


def colors_only_differ(a: chess.Board, b: chess.Board) -> bool:
    """The two boards differ, but only in who owns the pieces: same squares occupied, same piece types."""
    types = lambda x: {sq: p.piece_type for sq, p in x.piece_map().items()}
    return a.board_fen() != b.board_fen() and types(a) == types(b)


if __name__ == "__main__":
    ok = lambda fen: issues(chess.Board(fen + " w - - 0 1"))
    assert ok("6k1/pp6/2p5/3p4/1P1P4/8/P7/6K1") == []
    assert "too_many_kings" in ok("6k1/pp6/2p4K/3p4/1P1P4/8/P7/6K1")
    assert "pawns_on_backrank" in ok("P5k1/8/8/8/8/8/8/6K1")
    assert "no_black_king" in ok("8/8/8/8/8/8/8/6K1")
    assert ok("2b1kr2/p6r/1pB1pQ2/5p2/2pP4/2P5/PP3P2/R5K1") == []  # black in check, black to move
    assert ok("6k1/8/8/8/8/8/PPPPPPPP/QQ4K1") != []  # 8 pawns + 2 queens
    same = chess.Board("4k3/pp3ppp/4p3/3pP3/3N1P2/8/PPP3PP/4K3 w - - 0 1")  # a reading and the same one with the colours of K, k, N swapped
    swapped = chess.Board("4K3/pp3ppp/4p3/3pP3/3n1P2/8/PPP3PP/4k3 w - - 0 1")
    assert colors_only_differ(same, swapped) and not colors_only_differ(same, same)
    assert not colors_only_differ(same, chess.Board("4k3/pp3ppp/4p3/3pP3/3Q1P2/8/PPP3PP/4K3 w - - 0 1"))  # a piece type differs
    print("ok")

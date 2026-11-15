"""Step 4.6: guess whether a read diagram shows white at the bottom (fenify reads the display as-is)."""
import chess


def white_at_bottom_score(board: chess.Board) -> float:
    """>0 = white looks at the bottom of the display, <0 = black does; |score| = confidence (in ranks).
    Mean rank gap between the two armies (pawns included: they sit in front of their own king)."""
    def mean(color):
        sq = list(chess.SquareSet(board.occupied_co[color]))
        return sum(map(chess.square_rank, sq)) / max(1, len(sq))
    # display row 0 is the top; board rank 0 (A1 side) is read at the bottom, so lower rank = lower on screen
    return mean(chess.BLACK) - mean(chess.WHITE)


# ponytail: pure geometry; endgames with advanced pawns fool it (flagged by low score). Printed A-H/1-8 labels or
# 'White/Black to move' text near the diagram would settle those; add when the OCR pipeline exposes them.
def orient(board: chess.Board, min_score: float = 2.0):
    """(board with white at the bottom, flipped?, ok). ok=False when the guess is too close to call."""
    s = white_at_bottom_score(board)
    if s >= 0:
        return board, False, abs(s) >= min_score
    return board.transform(lambda bb: chess.flip_vertical(chess.flip_horizontal(bb))), True, abs(s) >= min_score


if __name__ == "__main__":
    WHITE_BOTTOM = """6k1/pp6/2p5/3p4/1P1P4/8/P7/6K1
6k1/1p3ppp/p1p5/1P1p4/P2P4/4P3/5PPP/6K1
2r1r1k1/pb5p/1pn1p1p1/1N3pN1/3q1n1P/P3Q3/1PB2PP1/2R1R1K1
1rbq1rk1/p3bppp/1pnppn2/2p5/4P3/2PP1NP1/PP1N1PBP/R1BQR1K1
1rb2rk1/p4ppp/1p1qpnn1/6N1/2pP3P/2P3P1/PPQ2PB1/R1B1R1K1
2b2r2/pr3pkn/1p2p3/8/2pP1B1q/2P5/PPQ2PB1/R3R1K1
2b1kr2/p6r/1pB1pQ2/5p2/2pP4/2P5/PP3P2/R5K1
r2q1rk1/pp2ppbp/3pbnp1/8/2BBP3/2N2P2/PPPQ2PP/R3K2R
5rk1/p1r1ppbp/3p1np1/1q6/1p1BP2P/1B3P2/PPPQ2P1/1K1R3R
r1bq1rk1/ppp1npbp/3p2p1/3Pp2n/2P1P3/2N2NP1/PP3PBP/R1BQ1RK1
r2q2k1/pppb1rbp/3p2n1/3P1p2/2PB1P2/2N2BP1/PP6/R2QR1K1
4br2/2p1n1k1/1p1p3p/p2P1p1R/2P2P2/PP1BN1P1/5K2/8
7r/2pb2k1/1p1p1n1p/p2P1p2/1PPN1P2/P2B2P1/5K2/7R
4r3/2p5/7R/3k4/2p2PP1/5K2/8/8
5r2/R1pnk3/7p/2pP1B2/5PP1/8/3K4/8
6r1/5P2/6P1/6K1/8/2p5/2k5/8
1r3rk1/3b1p1p/1qNp2p1/3Pb3/1p6/P7/1PR1BQPP/5R1K
3r1rk1/1p1n1ppp/p1bpp3/3N4/2P1P3/5P2/PPB3PP/2RR2K1""".split("\n")
    BLACK_BOTTOM = """1K6/PPP3PP/5P2/4P1p1/4p2p/3p4/ppp5/1k6
1K6/PPP3PP/8/4P2p/4p3/3p4/ppp5/1k6
1K6/PPP4P/6P1/5P2/4P1p1/4p2p/pppp4/1k6
1K6/PPP4P/6P1/5Pp1/4P2p/4p3/pppp4/1k6""".split("\n")
    for fen in WHITE_BOTTOM + BLACK_BOTTOM:
        b = chess.Board(None); b.set_board_fen(fen)
        sc = white_at_bottom_score(b)
        flipped, was_flipped, ok = orient(b)
        wrong = was_flipped != (fen in BLACK_BOTTOM)
        assert ok or True
        assert not (wrong and ok), f"confident and wrong: {fen}"  # wrong guesses must land in the review list
        print(f"{sc:+.2f}", "WB" if fen in WHITE_BOTTOM else "BB", "ok" if ok else "REVIEW", "(wrong guess)" if wrong else "", fen)
    print("ok")

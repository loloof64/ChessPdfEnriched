"""Fine-tune the diagram reader on REAL diagrams of the generated books, labelled by the games (a diagram whose reading is a position of the
book's game: `matches_move`) plus a few hand-checked ones.

    .venv/bin/python finetune_real.py [--hold BOOK ...] [--steps N] [--out work/fenify-ft2.pt] [--weights work/fenify-ft.pt]

With --hold the named books are left out of training and the read errors (squares) before/after are printed per book: the generalisation test.
Without --hold everything is trained on (final weights). Input books: *.chessbook under --books (default ~/Documents/Echecs/chessbooks) and, for
`EXTRA`, other chessbooks / hand-checked FENs. Run from pipeline/.
"""
import argparse
import glob
import io
import json
import random
import zipfile
from pathlib import Path

import chess
import numpy as np
import torch
from PIL import Image, ImageFilter

import make_chessbook_cli as m
from autocrop import candidate_boxes
from read_fen import prep

# hand-checked on the page image (si4 = a fresh run of structure_est-indienne_t4, passed with --extra): (book, diagram id, FEN as printed, white at the bottom)
HAND = {("si4", "p1_d2"): "rnbq1rk1/ppp2pbp/5np1/4p3/2P1P3/2N2N2/PP2BPPP/R1BQK2R",
        ("si4", "p2_d2"): "r1bq1rk1/1pp1npbp/p2p1np1/3Pp3/2P1P3/2N2P2/PP1QN1PP/R3KB1R",
        ("si4", "p2_d3"): "rnbqk2r/ppp1ppbp/3p1np1/8/2PP4/5NP1/PP2PPBP/RNBQK2R",
        # hatched board, white knight (outline) on d5 read black by the weights-2 model
        ("structure_najdorf_1", "p1_d2"): "6k1/5ppp/p2p4/1p1Np3/4P3/8/PPP2PPP/6K1",
        # hatched board with Black's pieces only (the Hedgehog set-up): the weights-3 model invents white pieces
        ("structure_herisson_1", "p1_d1"): "2r1r1k1/1bqnbppp/pp1ppn2/8/8/8/8/8"}
ROT = lambda b: b.transform(lambda bb: chess.flip_vertical(chess.flip_horizontal(bb)))


def load(books_dir, extra):
    """[(book, id, PIL image, raw label board as displayed)]"""
    out = []
    for f in sorted(glob.glob(f"{books_dir}/**/*.chessbook", recursive=True)) + extra:
        book, z = Path(f).stem, zipfile.ZipFile(f)
        for name in z.namelist():
            if not (name.startswith("pages/p") and name.endswith(".json")):
                continue
            for d in json.loads(z.read(name))["diagrams"]:
                hand = HAND.get((book, d["id"]))
                if not (d["fen"] and (d.get("matches_move") or hand)):
                    continue
                b = chess.Board(hand + " w - - 0 1" if hand else d["fen"])
                out.append((book, d["id"], Image.open(io.BytesIO(z.read(d["image"]))).convert("RGB"), ROT(b) if d.get("flipped") else b))
    return out


def squares_wrong(read, truth):
    return sum(read.piece_at(s) != truth.piece_at(s) for s in chess.SQUARES)


def read_err(model, x, truth, dev):
    with torch.no_grad():
        p = model(x.unsqueeze(0).to(dev)).cpu()[0]
    board = chess.Board(None)
    for sq, c in enumerate(p.argmax(dim=1).tolist()):
        if c:
            board.set_piece_at(sq, chess.Piece((c - 1) % 6 + 1, chess.BLACK if c > 6 else chess.WHITE))
    return squares_wrong(board, truth)


def label(board):
    return torch.tensor([0 if (p := board.piece_at(sq)) is None else p.piece_type + 6 * (p.color == chess.BLACK) for sq in chess.SQUARES])


def best_box(model, im, truth, dev):
    """The candidate square whose reading is nearest the label (the autocrop is sometimes a cell off)."""
    boxes = candidate_boxes(im)
    errs = [read_err(model, prep(im.crop(b)), truth, dev) for b in boxes]
    return boxes[int(np.argmin(errs))], min(errs)


def augment(im, box, rng):
    """A jittered crop (shift and size within a fifth of a cell), sometimes with the hatching flattened or a slight blur / contrast change."""
    x0, y0, x1, y1 = box
    c = (x1 - x0) / 8
    j = lambda: rng.uniform(-.2, .2) * c
    b = (x0 + j(), y0 + j(), x1 + j(), y1 + j())
    b = (max(0, b[0]), max(0, b[1]), min(im.width, b[2]), min(im.height, b[3]))
    x = im.crop(tuple(round(v) for v in b))
    if rng.random() < .3:
        x = m.flatten(x)
    if rng.random() < .3:
        x = x.filter(ImageFilter.GaussianBlur(rng.uniform(.3, 1.0)))
    if rng.random() < .4:
        a = np.asarray(x).astype(float)
        x = Image.fromarray(np.clip((a - 128) * rng.uniform(.85, 1.15) + 128 + rng.uniform(-15, 15), 0, 255).astype("uint8"))
    return prep(x)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--books", default=str(Path.home() / "Documents/Echecs/chessbooks"))
    ap.add_argument("--extra", nargs="*", default=[], help="more .chessbook files (named by their stem like the others)")
    ap.add_argument("--hold", nargs="*", default=[])
    ap.add_argument("--steps", type=int, default=600)
    ap.add_argument("--lr", type=float, default=2e-5)
    ap.add_argument("--weights", default="work/fenify-ft.pt")
    ap.add_argument("--out", default="work/fenify-ft2.pt")
    a = ap.parse_args()
    rng = random.Random(0)
    torch.manual_seed(0)
    dev = "cuda" if torch.cuda.is_available() else "cpu"
    samples = [s for s in load(a.books, a.extra)]
    print(len(samples), "labelled diagrams from", len({s[0] for s in samples}), "books", flush=True)
    ref = torch.jit.load(a.weights, map_location=dev).eval()
    data = []  # (book, id, image, box, label tensor, truth board)
    for book, did, im, truth in samples:
        box, e = best_box(ref, im, truth, dev)
        if e <= 12:
            data.append((book, did, im, box, label(truth), truth))
        else:
            print("dropped (no crop reads within 12 squares):", book, did, e)
    train = [d for d in data if d[0] not in a.hold]
    held = [d for d in data if d[0] in a.hold]
    print(len(train), "train,", len(held), "held out", flush=True)
    model = torch.jit.load(a.weights, map_location=dev).train()
    opt = torch.optim.Adam(model.parameters(), lr=a.lr)
    for step in range(1, a.steps + 1):
        batch = rng.sample(train, 8)
        x = torch.stack([augment(d[2], d[3], rng) for d in batch]).to(dev)
        y = torch.stack([d[4] for d in batch]).to(dev)
        loss = torch.nn.functional.nll_loss(torch.log(model(x).clamp_min(1e-8)).flatten(0, 1), y.flatten())
        opt.zero_grad()
        loss.backward()
        opt.step()
        if step % 50 == 0:
            print(step, round(float(loss), 4), flush=True)
    model.eval()

    def report(title, rows):
        print(title)
        books = sorted({r[0] for r in rows})
        for bk in books + [None]:
            rs = [r for r in rows if bk is None or r[0] == bk]
            old = sum(read_err(ref, prep(r[2].crop(r[3])), r[5], dev) for r in rs)
            new = sum(read_err(model, prep(r[2].crop(r[3])), r[5], dev) for r in rs)
            print(f"  {bk or 'TOTAL':32s} {len(rs):3d} diagrams: wrong squares {old:4d} -> {new:4d}")
    if held:
        report("HELD OUT", held)
    report("TRAIN", train)
    model.cpu()
    model.save(a.out)
    print("saved", a.out)

"""Step 4.5: fine-tune fenify on synthetic boards; report error on the real reference diagrams.

Usage: finetune.py [STEPS]   -> writes work/fenify-ft.pt (TorchScript). Run from pipeline/.
"""
import sys

import chess
import torch
from PIL import Image
from torch.utils.data import DataLoader, IterableDataset, get_worker_info

from eval_fen import CROP, TRUTH, errors
from read_fen import prep, read_board
from synth import Synth

STEPS = int(sys.argv[1]) if len(sys.argv) > 1 else 3000
OUT = sys.argv[2] if len(sys.argv) > 2 else "work/fenify-ft.pt"
BATCH, LR = 8, 3e-5
HELD_OUT = ("img-006", "img-007", "img-008", "img-009")  # backgrounds were never taken from these


class Boards(IterableDataset):
    def __iter__(self):
        info = get_worker_info()
        gen, i = Synth(), (info.id if info else 0) * 10_000_000
        while True:
            img, labels = gen.sample(i)
            i += 1
            yield prep(img.convert("RGB")), torch.tensor(labels)


def hatch_eval(model):
    """Errors (ghost, missing, wrong) on the hatched diagrams: p1_d1 and p4_d2 are seen in training (their squares), p1_d2 is held out."""
    import autocrop
    from synth import HATCH_DIR, HATCH_SOURCES
    truths = dict(HATCH_SOURCES, p1_d2="6k1/ppp3pp/4p3/3pN3/3P4/8/PPP2PPP/6K1")
    out = {}
    for name, fen in truths.items():
        im = Image.open(f"{HATCH_DIR}/{name}.png").convert("RGB")
        x0, y0, x1, y1, _ = autocrop.find_board(im)
        truth = chess.Board(None)
        truth.set_board_fen(fen)
        out[name] = errors(read_board(model, im.crop((x0, y0, x1, y1))), truth)
    return out


def real_eval(model):
    """Total (ghost, missing, wrong) over all reference diagrams and over the held-out ones."""
    model.eval()
    tot, held = [0, 0, 0], [0, 0, 0]
    for name, fen in TRUTH.items():
        im = Image.open(f"work/am1/{name}.png").convert("RGB")
        w, h = im.size
        im = im.crop((round(CROP[0] * w), round(CROP[1] * h), round(CROP[2] * w), round(CROP[3] * h)))
        truth = chess.Board(None)
        truth.set_board_fen(fen)
        e = errors(read_board(model, im), truth)
        tot = [a + b for a, b in zip(tot, e)]
        if name in HELD_OUT:
            held = [a + b for a, b in zip(held, e)]
    model.train()
    return tuple(tot), tuple(held)


if __name__ == "__main__":
    dev = "cuda" if torch.cuda.is_available() else "cpu"
    model = torch.jit.load("work/fenify-gpu.pt", map_location=dev).train()
    print("start", real_eval(model.cpu()) if dev == "cpu" else None)
    opt = torch.optim.Adam(model.parameters(), lr=LR)
    loader = DataLoader(Boards(), batch_size=BATCH, num_workers=6)
    for step, (x, y) in enumerate(loader, 1):
        p = model(x.to(dev))  # softmax probabilities, (B, 64, 13)
        loss = torch.nn.functional.nll_loss(torch.log(p.clamp_min(1e-8)).flatten(0, 1), y.to(dev).flatten())
        opt.zero_grad()
        loss.backward()
        opt.step()
        if step % 100 == 0:
            print(step, round(float(loss), 4), flush=True)
        if step % 500 == 0 or step == STEPS:
            model.to("cpu")
            print("REAL ghost/miss/wrong all, held-out:", real_eval(model), "HATCHED", hatch_eval(model), flush=True)
            model.to(dev)
        if step == STEPS:
            break
    model.cpu().eval()
    model.save(OUT)

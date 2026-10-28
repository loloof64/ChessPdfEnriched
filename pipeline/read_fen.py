"""Step 3/4 spike: read the FEN of a cropped diagram image with the fenify TorchScript model.

Usage: read_fen.py MODEL.pt IMAGE.png [x0 y0 x1 y1]   (optional crop box in pixels)
Assumes white at the bottom (fenify has no orientation detection).
"""
import sys

import chess
import torch
from PIL import Image
from torchvision import transforms

prep = transforms.Compose([
    transforms.Grayscale(num_output_channels=3),
    transforms.Resize((300, 300)),
    transforms.ToTensor(),
    transforms.Normalize(mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225]),
])


def read_board(model, img: Image.Image) -> chess.Board:
    with torch.no_grad():
        logits = model(prep(img).unsqueeze(0))
    cls = logits.squeeze().argmax(dim=1).reshape(8, 8)
    board = chess.Board(None)
    for rank in range(8):
        for file in range(8):
            i = int(cls[rank][file])
            if i:
                color = chess.BLACK if i > 6 else chess.WHITE
                board.set_piece_at(rank * 8 + file, chess.Piece((i - 1) % 6 + 1, color))
    return board


if __name__ == "__main__":
    model = torch.jit.load(sys.argv[1], map_location="cpu").eval()
    img = Image.open(sys.argv[2]).convert("RGB")
    if len(sys.argv) == 7:
        img = img.crop(tuple(map(int, sys.argv[3:7])))
    img.save("work/crop.png")
    print(read_board(model, img).board_fen())

#!/usr/bin/env bash
# Creates pipeline/.venv with every Python dependency (see pyproject.toml) and checks the system tools.
set -euo pipefail
cd "$(dirname "$0")"

command -v uv >/dev/null || { echo "uv est requis : https://docs.astral.sh/uv/getting-started/installation/" >&2; exit 1; }
for tool in pdftoppm pdftotext; do
  command -v "$tool" >/dev/null || { echo "$tool manquant : sudo apt install poppler-utils" >&2; exit 1; }
done

uv sync   # creates .venv (Python 3.13) and installs torch/paddle CUDA 12.6 wheels: several GB, takes a while

if [ ! -f work/fenify-ft.pt ]; then
  echo
  echo "Attention : les poids de lecture des diagrammes (work/fenify-ft.pt) sont absents."
  echo "Voir la section « Poids des diagrammes » du README."
fi
echo
echo "OK. Essayer : .venv/bin/python make_chessbook.py --help"

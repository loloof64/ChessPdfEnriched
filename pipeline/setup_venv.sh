#!/usr/bin/env bash
# Creates pipeline/.venv with every Python dependency (see pyproject.toml) and checks the system tools.
# Usage: ./setup_venv.sh [--cuda | --cpu]   (default: cuda when nvidia-smi finds a GPU, cpu otherwise)
set -euo pipefail
cd "$(dirname "$0")"

command -v uv >/dev/null || { echo "uv is required (not available through apt). Install it with: curl -LsSf https://astral.sh/uv/install.sh | sh   (docs: https://docs.astral.sh/uv/getting-started/installation/)" >&2; exit 1; }
for tool in pdftoppm pdftotext; do
  command -v "$tool" >/dev/null || { echo "$tool is missing: sudo apt install poppler-utils" >&2; exit 1; }
done

profile="${1:-}"
case "$profile" in
  --cuda|--cpu) profile="${profile#--}" ;;
  "") if command -v nvidia-smi >/dev/null && nvidia-smi >/dev/null 2>&1; then profile=cuda; else profile=cpu; fi ;;
  *) echo "usage: $0 [--cuda | --cpu]" >&2; exit 1 ;;
esac
echo "Installing the '$profile' profile."

# creates .venv (Python 3.13); cuda: torch/paddle CUDA 12.6 wheels (several GB), cpu: CPU wheels. Takes a while.
uv sync --extra "$profile"

if [ ! -f work/fenify-ft.pt ]; then
  echo
  echo "Warning: the diagram reader weights (work/fenify-ft.pt) are missing."
  echo "See the \"Diagram weights\" section of the README."
fi
echo
echo "OK. Graphical interface: .venv/bin/python make_chessbook_gui.py   (command line: make_chessbook_cli.py --help)"

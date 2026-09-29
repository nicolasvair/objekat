#!/bin/bash
# Wrapper launched by OBJEKAT (@see manifest.json's "executable"). Its whole job is to fail
# LOUDLY and EARLY when the venv is missing, rather than let a bare `python3 separateur_voix.py`
# die on a cryptic `ModuleNotFoundError` for mlx-whisper — the convention this script family
# follows (@see plan_separateur_voix.md, D4) is "write the human message on stderr, exit != 0",
# and OBJEKAT surfaces exactly that text through `viewModel.notify`.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="$HOME/Library/Application Support/Objekat/venvs/separateur-voix"
PY="$VENV_DIR/bin/python3"

if [ ! -x "$PY" ]; then
  echo "Dépendances absentes : lancez install.sh ($HERE/install.sh) — il a besoin de Python >= 3.10 (brew install python@3.12)" >&2
  exit 2
fi

if ! "$PY" -c "import numpy, scipy, soundfile, mlx_whisper" 2>/dev/null; then
  echo "Dépendances incomplètes : relancez install.sh ($HERE/install.sh)" >&2
  exit 2
fi

exec "$PY" "$HERE/separateur_voix.py" "$@"

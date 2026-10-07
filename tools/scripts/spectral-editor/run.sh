#!/bin/bash
# Wrapper launched by OBJEKAT (@see manifest.json's "executable"). Its whole job is to fail LOUDLY and
# EARLY when the venv is missing, rather than let a bare `python3 spectral_editor.py` die on a cryptic
# `ModuleNotFoundError` — the convention of this script family is "write the human message on stderr,
# exit != 0", and OBJEKAT surfaces exactly that text.
# OBJEKAT_SPECTRAL_PYTHON overrides the interpreter (tests, or a machine where the venv lives elsewhere).
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="$HOME/Library/Application Support/Objekat/venvs/spectral-editor"
PY="${OBJEKAT_SPECTRAL_PYTHON:-$VENV_DIR/bin/python3}"

if [ ! -x "$PY" ]; then
  echo "Dépendances absentes : lancez install.sh ($HERE/install.sh) / Dependencies missing: run $HERE/install.sh" >&2
  exit 2
fi

if ! "$PY" -c "import numpy" 2>/dev/null; then
  echo "Dépendances incomplètes (numpy) : relancez install.sh ($HERE/install.sh) / Incomplete dependencies (numpy): rerun $HERE/install.sh" >&2
  exit 2
fi

exec "$PY" "$HERE/spectral_editor.py" "$@"

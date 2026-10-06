#!/bin/bash
# Sets up the "Spectral editor" script (folder and id: spectral-gain): a dedicated venv under
# ~/Library/Application Support/Objekat/venvs/spectral-gain (never the system Python's site-packages, never
# the app bundle), numpy installed in it, and a symlink into OBJEKAT's own Plugins folder. No model to
# download: the script is pure numpy.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPPORT_DIR="$HOME/Library/Application Support/Objekat"
VENV_DIR="$SUPPORT_DIR/venvs/spectral-gain"
PLUGINS_DIR="$SUPPORT_DIR/Plugins"

echo "== Spectral editor — install =="

# Any Python >= 3.9 hosts numpy: the newest one found in PATH and in Homebrew's prefixes, else macOS's own.
PY=""
for cand in python3.13 python3.12 python3.11 python3.10 python3.9 python3; do
  for dir in "" /opt/homebrew/bin/ /usr/local/bin/ /usr/bin/; do
    if command -v "${dir}${cand}" >/dev/null 2>&1 && \
       "$(command -v "${dir}${cand}")" -c 'import sys; sys.exit(sys.version_info < (3, 9))' 2>/dev/null; then
      PY="$(command -v "${dir}${cand}")"; break 2
    fi
  done
done
if [ -z "$PY" ]; then
  echo "No Python >= 3.9 found. Install one, then rerun: brew install python@3.12" >&2
  exit 1
fi

mkdir -p "$SUPPORT_DIR/venvs"
if [ ! -d "$VENV_DIR" ]; then
  echo "Creating venv ($PY) at: $VENV_DIR"
  "$PY" -m venv "$VENV_DIR"
else
  echo "Venv already exists: $VENV_DIR"
fi

"$VENV_DIR/bin/pip" install --upgrade pip
"$VENV_DIR/bin/pip" install -r "$HERE/requirements.txt"
"$VENV_DIR/bin/python3" -c "import numpy; print('numpy', numpy.__version__, 'ready.')"

mkdir -p "$PLUGINS_DIR"
LINK="$PLUGINS_DIR/spectral-gain"
if [ -L "$LINK" ] || [ -e "$LINK" ]; then
  echo "Already linked: $LINK"
else
  ln -s "$HERE" "$LINK"
  echo "Linked: $LINK -> $HERE"
fi

echo "Done. Reload the scripts in OBJEKAT (Scripts menu -> Reload) or relaunch the app."

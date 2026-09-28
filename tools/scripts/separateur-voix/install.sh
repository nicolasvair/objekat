#!/bin/bash
# Sets up the "Voice separator" script (@see plan_separateur_voix.md, D5): a dedicated venv under
# ~/Library/Application Support/Objekat/venvs/separateur-voix (never the system Python, never the
# app bundle — nothing here is embedded), the model pre-downloaded so the first real use does not
# stall on a multi-gigabyte fetch, and a symlink into OBJEKAT's own Plugins folder.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPPORT_DIR="$HOME/Library/Application Support/Objekat"
VENV_DIR="$SUPPORT_DIR/venvs/separateur-voix"
PLUGINS_DIR="$SUPPORT_DIR/Plugins"

echo "== Voice separator — install =="

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 not found. Install Python 3.10+ (arm64) first." >&2
  exit 1
fi

ARCH="$(python3 -c 'import platform; print(platform.machine())')"
if [ "$ARCH" != "arm64" ]; then
  echo "Warning: python3 reports '$ARCH', not arm64 — mlx-whisper needs Apple Silicon." >&2
fi
# The plan named Python >= 3.10; run for real on this machine's system python3 (3.9.6, macOS's
# own /usr/bin/python3), which installed and ran mlx-whisper without complaint — no version floor
# enforced here, the install simply fails loudly (pip's own resolver) if a real one is ever hit.

mkdir -p "$SUPPORT_DIR/venvs"
if [ ! -d "$VENV_DIR" ]; then
  echo "Creating venv at: $VENV_DIR"
  python3 -m venv "$VENV_DIR"
else
  echo "Venv already exists: $VENV_DIR"
fi

"$VENV_DIR/bin/pip" install --upgrade pip
"$VENV_DIR/bin/pip" install -r "$HERE/requirements.txt"

echo "Pre-downloading the model (mlx-community/whisper-large-v3-turbo) — this can take a while..."
"$VENV_DIR/bin/python3" - <<'PYEOF'
import mlx_whisper
import numpy as np
# A silent one-second clip is enough to force the model's weights to be fetched and cached —
# nothing here is a real transcription, just a warm-up download.
mlx_whisper.transcribe(np.zeros(16000, dtype=np.float32),
                       path_or_hf_repo="mlx-community/whisper-large-v3-turbo",
                       word_timestamps=True, language="en")
print("Model ready.")
PYEOF

mkdir -p "$PLUGINS_DIR"
LINK="$PLUGINS_DIR/separateur-voix"
if [ -L "$LINK" ] || [ -e "$LINK" ]; then
  echo "Already linked: $LINK"
else
  ln -s "$HERE" "$LINK"
  echo "Linked: $LINK -> $HERE"
fi

echo "Done. Reload the scripts in OBJEKAT (Scripts menu -> Reload) or relaunch the app."

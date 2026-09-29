#!/bin/bash
# Sets up the "Voice separator" script (@see plan_separateur_voix.md, D5): a dedicated venv under
# ~/Library/Application Support/Objekat/venvs/separateur-voix (never the system Python, never the
# app bundle — nothing here is embedded), the model pre-downloaded so the first real use does not
# stall on a multi-gigabyte fetch, and a symlink into OBJEKAT's own Plugins folder.
set -euo pipefail

# Optional heavy models for the breath evaluation's text display (all opt-in, none is needed to
# detect anything): --with-parakeet (Parakeet TDT v3, ~2.5 GB, same venv) and
# --with-align (wav2vec2 CTC forced alignment of Whisper's text, ~1.3 GB per language; languages in
# ALIGN_LANGS, default "fr").
WITH_PARAKEET=0
WITH_ALIGN=0
for arg in "$@"; do
  case "$arg" in
    --with-parakeet) WITH_PARAKEET=1 ;;
    --with-align) WITH_ALIGN=1 ;;
    *) echo "Unknown option: $arg (known: --with-parakeet, --with-align)" >&2; exit 1 ;;
  esac
done
ALIGN_LANGS="${ALIGN_LANGS:-fr}"

# free_gb_for <needed GB> <what>: a model that does not fit is SKIPPED with a message, never
# half-downloaded onto a full disk (the build of the app lives on the same volume).
free_gb_for() {
  local needed="$1" what="$2" free
  free="$(df -k "$HOME" | awk 'NR==2 {printf "%.1f", $4/1048576}')"
  if awk -v f="$free" -v n="$needed" 'BEGIN {exit !(f < n)}'; then
    echo "Skipping $what: needs about $needed GB free, only $free GB available." >&2
    return 1
  fi
  return 0
}

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPPORT_DIR="$HOME/Library/Application Support/Objekat"
VENV_DIR="$SUPPORT_DIR/venvs/separateur-voix"
PLUGINS_DIR="$SUPPORT_DIR/Plugins"

echo "== Voice separator — install =="

# ONE venv for everything (Whisper, alignment, Parakeet), on a Python >= 3.10 — macOS's own 3.9
# cannot host parakeet-mlx. Looked for in PATH and in Homebrew's prefixes; the message says what to do.
PY=""
for cand in python3.13 python3.12 python3.11 python3.10; do
  for dir in "" /opt/homebrew/bin/ /usr/local/bin/; do
    if command -v "${dir}${cand}" >/dev/null 2>&1; then PY="$(command -v "${dir}${cand}")"; break 2; fi
  done
done
if [ -z "$PY" ]; then
  echo "No Python >= 3.10 found (macOS's own is 3.9). Install one, then rerun: brew install python@3.12" >&2
  exit 1
fi
ARCH="$("$PY" -c 'import platform; print(platform.machine())')"
if [ "$ARCH" != "arm64" ]; then
  echo "Warning: $PY reports '$ARCH', not arm64 — mlx needs Apple Silicon." >&2
fi

mkdir -p "$SUPPORT_DIR/venvs"
# A venv left by an older version of this script (Python 3.9) is rebuilt; the model caches survive.
if [ -x "$VENV_DIR/bin/python3" ] && ! "$VENV_DIR/bin/python3" -c 'import sys; sys.exit(sys.version_info < (3, 10))'; then
  echo "Venv on an old Python, rebuilding: $VENV_DIR"
  rm -rf "$VENV_DIR"
fi
if [ ! -d "$VENV_DIR" ]; then
  echo "Creating venv ($PY) at: $VENV_DIR"
  "$PY" -m venv "$VENV_DIR"
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

if [ "$WITH_ALIGN" = 1 ]; then
  echo "== Alignment models (wav2vec2 CTC, Apache-2.0): $ALIGN_LANGS =="
  if free_gb_for 2 "the alignment models"; then
    "$VENV_DIR/bin/pip" install torch transformers
    ALIGN_LANGS="$ALIGN_LANGS" "$VENV_DIR/bin/python3" - <<'PYEOF'
import os
from transformers import Wav2Vec2ForCTC, Wav2Vec2Processor
repos = {"fr": "jonatasgrosman/wav2vec2-large-xlsr-53-french",
         "en": "jonatasgrosman/wav2vec2-large-xlsr-53-english",
         "es": "jonatasgrosman/wav2vec2-large-xlsr-53-spanish"}
for lang in os.environ["ALIGN_LANGS"].split(","):
    if lang in repos:
        Wav2Vec2Processor.from_pretrained(repos[lang]); Wav2Vec2ForCTC.from_pretrained(repos[lang])
        print("Alignment model ready:", lang)
PYEOF
  fi
fi

if [ "$WITH_PARAKEET" = 1 ]; then
  echo "== Parakeet TDT v3 (parakeet-mlx, Apache-2.0 code, CC-BY-4.0 weights) =="
  if free_gb_for 4 "Parakeet"; then
    "$VENV_DIR/bin/pip" install parakeet-mlx
    "$VENV_DIR/bin/python3" -c "from parakeet_mlx import from_pretrained; from_pretrained('mlx-community/parakeet-tdt-0.6b-v3'); print('Parakeet ready.')"
  fi
fi

mkdir -p "$PLUGINS_DIR"
LINK="$PLUGINS_DIR/separateur-voix"
if [ -L "$LINK" ] || [ -e "$LINK" ]; then
  echo "Already linked: $LINK"
else
  ln -s "$HERE" "$LINK"
  echo "Linked: $LINK -> $HERE"
fi

echo "Done. Reload the scripts in OBJEKAT (Scripts menu -> Reload) or relaunch the app."

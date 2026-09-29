#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Runs in a subprocess of the venv (Python >= 3.10, `parakeet-mlx`):
`parakeet_worker.py in.wav out.json` writes `[{"word", "start", "end"}, …]` (seconds).

Parakeet emits SUB-WORD tokens with a start and an end each; a token whose text begins with a space
opens a new word (SentencePiece's own convention), the words are the tokens glued between two of
them, timed from the first token's start to the last one's end (punctuation tokens excepted)."""

import json
import sys

import mlx.core as mx
import parakeet_mlx.parakeet as _pk
import soundfile as sf
from parakeet_mlx import from_pretrained

MODEL = "mlx-community/parakeet-tdt-0.6b-v3"


def words_from(result):
    words = []
    for sentence in result.sentences:
        current = None
        for tok in sentence.tokens:
            text = tok.text
            if current is None or text.startswith(" "):
                if current is not None:
                    words.append(current)
                current = {"word": text.strip(), "start": float(tok.start), "end": float(tok.end)}
            else:
                current["word"] += text
                # a trailing punctuation token (".", ",") is timed across the silence that follows
                # it: it belongs to the word's text, never to its end
                if any(ch.isalnum() for ch in text):
                    current["end"] = float(tok.end)
        if current is not None:
            words.append(current)
    return [w for w in words if w["word"]]


def _load_audio(filename, sampling_rate, dtype=mx.bfloat16):
    """parakeet-mlx decodes through an `ffmpeg` executable, which is one more thing to install; the
    caller already hands over 16 kHz mono PCM, so it is read directly (a wrong rate is refused)."""
    data, sr = sf.read(str(filename), dtype="float32", always_2d=True)
    if sr != sampling_rate:
        raise RuntimeError("parakeet worker expects %d Hz, got %d" % (sampling_rate, sr))
    return mx.array(data.mean(axis=1))  # float32 whatever `dtype`: get_logmel views the complex STFT as its own dtype


def main():
    wav, out = sys.argv[1], sys.argv[2]
    _pk.load_audio = _load_audio
    model = from_pretrained(MODEL)
    result = model.transcribe(wav)
    with open(out, "w", encoding="utf-8") as f:
        json.dump(words_from(result), f)


if __name__ == "__main__":
    main()

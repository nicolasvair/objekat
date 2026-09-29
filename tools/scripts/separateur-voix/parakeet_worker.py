#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Runs in the PARAKEET venv (Python >= 3.10, `parakeet-mlx`), never in the main one:
`parakeet_worker.py in.wav out.json` writes `[{"word", "start", "end"}, …]` (seconds).

Parakeet emits SUB-WORD tokens with a start and an end each; a token whose text begins with a space
opens a new word (SentencePiece's own convention), the words are the tokens glued between two of
them, timed from the first token's start to the last one's end."""

import json
import sys

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
                current["end"] = float(tok.end)
        if current is not None:
            words.append(current)
    return [w for w in words if w["word"]]


def main():
    wav, out = sys.argv[1], sys.argv[2]
    model = from_pretrained(MODEL)
    result = model.transcribe(wav)
    with open(out, "w", encoding="utf-8") as f:
        json.dump(words_from(result), f)


if __name__ == "__main__":
    main()

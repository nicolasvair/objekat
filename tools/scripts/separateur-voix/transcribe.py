#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The word-level transcription backends the breath evaluation can DISPLAY (never detect with):
no socket, importable and testable on its own (@see test_breath_mask.py).

A backend is chosen by id. Each answers the same thing — a list of `{"word", "start", "end"}`,
seconds relative to the audio handed in — and each says whether it is installed, so that a model
that is absent is a label in the panel and never a crash:

  whisper   mlx-whisper, `whisper-large-v3-turbo` (MIT code, MIT weights). Word times come from
            Whisper's own cross-attention: good on WHICH word, loose (tens of ms) on WHEN.
  parakeet  Parakeet TDT 0.6B v3 through `parakeet-mlx` (Apache-2.0 code, CC-BY-4.0 weights): a
            transducer that emits a time with every token. It needs Python >= 3.10 (the one venv is on it), and runs as a SUBPROCESS
            (`parakeet_worker.py`) — a whole process per transcription, no state to keep.
  align     Whisper's TEXT, re-timed by forced CTC alignment against a wav2vec2 model of the
            language (`jonatasgrosman/wav2vec2-large-xlsr-53-*`, Apache-2.0 code and weights) —
            the WhisperX idea, without WhisperX or its non-commercial weights. The Viterbi trellis
            is `ctc_forced_align` below, in numpy: no torchaudio.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile

import numpy as np

WHISPER_REPO = "mlx-community/whisper-large-v3-turbo"
PARAKEET_REPO = "mlx-community/parakeet-tdt-0.6b-v3"
ALIGN_REPOS = {
    "fr": "jonatasgrosman/wav2vec2-large-xlsr-53-french",
    "en": "jonatasgrosman/wav2vec2-large-xlsr-53-english",
    "es": "jonatasgrosman/wav2vec2-large-xlsr-53-spanish",
}
MODEL_IDS = ("none", "whisper", "parakeet", "align")
# Bumped whenever a backend's output changes, so a cached transcription is never read back as current.
BACKEND_VERSION = 1

HERE = os.path.dirname(os.path.abspath(__file__))
SUPPORT = os.path.join(os.path.expanduser("~"), "Library", "Application Support", "Objekat")
# parakeet-mlx lives in the main venv (Python >= 3.10 for everything); still a subprocess, so a
# transcription is a whole process with no state to keep. OBJEKAT_PARAKEET_PYTHON overrides it.
PARAKEET_PYTHON = os.environ.get("OBJEKAT_PARAKEET_PYTHON") or sys.executable


# MARK: - Is it installed?

def _hf_has(repo: str) -> bool:
    """The weights of `repo` are in the local Hugging Face cache (a snapshot with files in it)."""
    try:
        from huggingface_hub.constants import HF_HUB_CACHE
    except Exception:  # noqa: BLE001
        HF_HUB_CACHE = os.path.join(os.path.expanduser("~"), ".cache", "huggingface", "hub")
    snaps = os.path.join(HF_HUB_CACHE, "models--" + repo.replace("/", "--"), "snapshots")
    try:
        return any(os.listdir(os.path.join(snaps, s)) for s in os.listdir(snaps))
    except OSError:
        return False


def _has_module(name: str) -> bool:
    import importlib.util
    try:
        return importlib.util.find_spec(name) is not None
    except (ImportError, ValueError):
        return False


def installed(model: str, language: str = "fr") -> bool:
    """Whether `model` can run right now. Nothing is loaded and nothing is downloaded: a model whose
    weights are not in the cache counts as NOT installed (mlx-whisper would fetch 1.5 GB silently)."""
    if model == "none":
        return True
    if model == "whisper":
        return _has_module("mlx_whisper") and _hf_has(WHISPER_REPO)
    if model == "parakeet":
        return (_has_module("parakeet_mlx") or PARAKEET_PYTHON != sys.executable) and _hf_has(PARAKEET_REPO)
    if model == "align":
        return (installed("whisper") and _has_module("torch") and _has_module("transformers")
                and _hf_has(ALIGN_REPOS.get(language, ALIGN_REPOS["fr"])))
    return False


# MARK: - Resampling

def to_16k(mono: np.ndarray, sr: float) -> np.ndarray:
    from math import gcd
    from scipy.signal import resample_poly
    g = gcd(int(sr), 16000)
    return resample_poly(mono, 16000 // g, int(sr) // g).astype(np.float32)


# MARK: - Whisper

def whisper_transcribe(audio16: np.ndarray, language: str | None):
    """(words, segments): Whisper's word list and its segments (`{"text", "start", "end"}`), the
    latter being what the aligner re-times."""
    import mlx_whisper
    lang = None if language in (None, "", "auto") else language
    result = mlx_whisper.transcribe(audio16, path_or_hf_repo=WHISPER_REPO,
                                    word_timestamps=True, language=lang)
    words, segments = [], []
    for seg in result.get("segments", []):
        segments.append({"text": seg.get("text", "").strip(),
                         "start": float(seg.get("start", 0.0)), "end": float(seg.get("end", 0.0))})
        for w in seg.get("words", []):
            words.append({"word": w.get("word", "").strip(),
                          "start": float(w.get("start", 0.0)), "end": float(w.get("end", 0.0))})
    return words, segments


# MARK: - Parakeet (a subprocess in its own venv)

def parakeet_transcribe(audio16: np.ndarray) -> list[dict]:
    import soundfile as sf
    with tempfile.TemporaryDirectory(prefix="objekat-parakeet-") as tmp:
        wav, out = os.path.join(tmp, "in.wav"), os.path.join(tmp, "out.json")
        sf.write(wav, audio16, 16000, subtype="PCM_16")
        proc = subprocess.run([PARAKEET_PYTHON, os.path.join(HERE, "parakeet_worker.py"), wav, out],
                              capture_output=True, text=True)
        if proc.returncode != 0 or not os.path.exists(out):
            raise RuntimeError("parakeet: " + (proc.stderr or "no output").strip()[-300:])
        with open(out, "r", encoding="utf-8") as f:
            return json.load(f)


# MARK: - Forced CTC alignment

def ctc_forced_align(log_probs: np.ndarray, tokens: list[int], blank: int):
    """Viterbi forced alignment of `tokens` against `log_probs` (T, V). Returns, per token, the
    `(first_frame, last_frame)` its state was occupied on, or None when the audio is too short for
    the text (T less than the tokens plus the repeats that need a blank between them)."""
    T = log_probs.shape[0]
    L = len(tokens)
    if L == 0:
        return []
    S = 2 * L + 1
    labels = np.full(S, blank, dtype=np.int64)
    labels[1::2] = tokens
    # a state may be reached from two behind (skipping the blank) only onto a token that differs
    # from the token two states back
    skip_ok = np.zeros(S, dtype=bool)
    for s in range(3, S, 2):
        skip_ok[s] = labels[s] != labels[s - 2]
    NEG = -1e30
    alpha = np.full((T, S), NEG)
    back = np.zeros((T, S), dtype=np.int8)      # 0 = stayed, 1 = came from s-1, 2 = from s-2
    alpha[0, 0] = log_probs[0, blank]
    if S > 1:
        alpha[0, 1] = log_probs[0, labels[1]]
    emit = log_probs[:, labels]                 # (T, S)
    for t in range(1, T):
        prev = alpha[t - 1]
        stay = prev
        one = np.concatenate(([NEG], prev[:-1]))
        two = np.concatenate(([NEG, NEG], prev[:-2]))
        two = np.where(skip_ok, two, NEG)
        stack = np.stack([stay, one, two])
        choice = np.argmax(stack, axis=0)
        alpha[t] = stack[choice, np.arange(S)] + emit[t]
        back[t] = choice
    end = S - 1 if alpha[T - 1, S - 1] >= alpha[T - 1, S - 2] else S - 2
    if alpha[T - 1, end] <= NEG / 2:
        return None
    first = [None] * L
    last = [None] * L
    s = end
    for t in range(T - 1, -1, -1):
        if s % 2 == 1:
            j = (s - 1) // 2
            if last[j] is None:
                last[j] = t
            first[j] = t
        s -= int(back[t, s])
        if s < 0:
            break
    if any(f is None for f in first):
        return None
    return list(zip(first, last))


def _normalise(word: str, vocab: dict) -> list[int]:
    """The word as vocabulary ids — lower-cased, anything the model has no symbol for dropped."""
    ids = []
    for ch in word.lower():
        if ch in vocab:
            ids.append(vocab[ch])
    return ids


_ALIGN_CACHE: dict = {}


def _align_model(language: str):
    key = language if language in ALIGN_REPOS else "fr"
    if key not in _ALIGN_CACHE:
        from transformers import Wav2Vec2ForCTC, Wav2Vec2Processor
        repo = ALIGN_REPOS[key]
        _ALIGN_CACHE[key] = (Wav2Vec2Processor.from_pretrained(repo),
                             Wav2Vec2ForCTC.from_pretrained(repo).eval())
    return _ALIGN_CACHE[key]


def align_segments(audio16: np.ndarray, segments: list[dict], language: str) -> list[dict]:
    """Re-times the words of each Whisper segment against the wav2vec2 CTC of the language. A
    segment is cropped (with 0.3 s of room either side) so the model's cost stays bounded whatever
    the length of the file; a word with no symbol the model knows (a digit, a symbol) is dropped, and
    a segment the audio is too short for is left out rather than guessed."""
    import torch
    processor, model = _align_model(language)
    vocab = processor.tokenizer.get_vocab()
    blank = processor.tokenizer.pad_token_id
    delimiter = vocab.get("|")
    stride = 0.02
    out: list[dict] = []
    for seg in segments:
        words = [w for w in re.split(r"\s+", seg["text"]) if w]
        if not words:
            continue
        c0 = max(0.0, seg["start"] - 0.3)
        c1 = min(len(audio16) / 16000.0, seg["end"] + 0.3)
        chunk = audio16[int(c0 * 16000):int(c1 * 16000)]
        if len(chunk) < 400:
            continue
        with torch.no_grad():
            inputs = processor(chunk, sampling_rate=16000, return_tensors="pt")
            logits = model(inputs.input_values).logits[0]
        log_probs = torch.log_softmax(logits, dim=-1).numpy()
        tokens, owner = [], []           # owner[i] = index in `kept` of the word token i belongs to
        kept = []
        for w in words:
            ids = _normalise(w, vocab)
            if not ids:
                continue
            if kept and delimiter is not None:
                tokens.append(delimiter)
                owner.append(-1)
            kept.append(w)
            tokens.extend(ids)
            owner.extend([len(kept) - 1] * len(ids))
        spans = ctc_forced_align(log_probs, tokens, blank)
        if spans is None:
            continue
        for wi, w in enumerate(kept):
            frames = [spans[i] for i, o in enumerate(owner) if o == wi]
            out.append({"word": w, "start": c0 + frames[0][0] * stride,
                        "end": c0 + (frames[-1][1] + 1) * stride})
    return out


# MARK: - The entry point

def transcribe(model: str, mono: np.ndarray, sr: float, language: str | None) -> list[dict]:
    """`model` in {"whisper", "parakeet", "align"} → the words, seconds relative to `mono`."""
    audio16 = to_16k(mono, sr)
    if model == "whisper":
        return whisper_transcribe(audio16, language)[0]
    if model == "parakeet":
        return parakeet_transcribe(audio16)
    if model == "align":
        _words, segments = whisper_transcribe(audio16, language)
        return align_segments(audio16, segments, language or "fr")
    raise ValueError("unknown model %r" % model)

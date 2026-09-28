#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Standalone test of the vectorised features and of `breath_mask` (@see plan_eval_respirations.md,
T1) — no Whisper, no socket. Run with the venv's own python3:

    python3 test_breath_mask.py

The REFERENCE implementations below are the ones `detect.py` had before it was vectorised (one
Python loop per frame, one dot product per lag): they are kept HERE, as the definition the new code
must agree with, and nowhere else.
"""

import math
import os
import shutil
import sys
import tempfile
import time

import numpy as np

import detect
import separateur_voix as sv
from test_detect import make_signal, SR, DURATION

FAILS = []


def check(label, ok, detail=""):
    if ok:
        print("ok    " + label)
    else:
        FAILS.append(label)
        print("FAIL  %s  %s" % (label, detail))


# ── The reference: detect.py as it was ────────────────────────────────────────────────────────

def ref_autocorr_voicing(frame, sr):
    lag_min = int(sr / 400.0)
    lag_max = min(int(sr / 70.0), len(frame) - 1)
    if lag_max <= lag_min:
        return 0.0
    x = frame - frame.mean()
    energy0 = float(np.dot(x, x))
    if energy0 <= 1e-12:
        return 0.0
    best = 0.0
    for lag in range(lag_min, lag_max + 1):
        c = float(np.dot(x[:-lag], x[lag:]))
        if c > best:
            best = c
    return best / energy0


def _band(mag2, freqs, lo, hi):
    band = mag2[(freqs >= lo) & (freqs <= hi)]
    return float(band.sum()) if band.size else 0.0


def ref_features(samples, sr):
    frame_len = max(2, int(round(detect.FRAME_MS / 1000.0 * sr)))
    hop_len = max(1, int(round(detect.HOP_MS / 1000.0 * sr)))
    n = len(samples)
    window = np.hanning(frame_len)
    n_frames = max(0, 1 + (n - frame_len) // hop_len) if n >= frame_len else 0
    out = {k: np.zeros(n_frames) for k in
           ("energy_db", "hf_lf", "e_mid", "e_hf", "zcr", "flatness", "voicing")}
    eps = 1e-12
    for i in range(n_frames):
        start = i * hop_len
        frame = samples[start:start + frame_len]
        w = frame * window
        out["energy_db"][i] = 10.0 * math.log10(float(np.mean(frame ** 2)) + eps)
        spectrum = np.fft.rfft(w)
        mag2 = spectrum.real ** 2 + spectrum.imag ** 2
        freqs = np.fft.rfftfreq(frame_len, d=1.0 / sr)
        e_lf = _band(mag2, freqs, 80.0, 1000.0)
        e_hf = _band(mag2, freqs, 4000.0, 10000.0)
        out["hf_lf"][i] = 10.0 * math.log10((e_hf + eps) / (e_lf + eps))
        out["e_hf"][i] = 10.0 * math.log10(e_hf + eps)
        out["e_mid"][i] = 10.0 * math.log10(_band(mag2, freqs, 1000.0, 4000.0) + eps)
        signs = np.sign(frame)
        signs[signs == 0] = 1
        out["zcr"][i] = float(np.mean(signs[1:] != signs[:-1]))
        band = mag2[(freqs >= 300.0) & (freqs <= 4000.0)]
        if band.size:
            band = band + eps
            gmean = math.exp(float(np.mean(np.log(band))))
            amean = float(np.mean(band))
            out["flatness"][i] = gmean / amean if amean > 0 else 0.0
        out["voicing"][i] = ref_autocorr_voicing(frame, sr)
    return out


def ref_frame_runs(mask, hop_s, fill_holes_s, min_len_s):
    if mask.size == 0:
        return []
    fill_frames = int(round(fill_holes_s / hop_s))
    m = mask.copy()
    i = 0
    while i < len(m):
        if not m[i]:
            j = i
            while j < len(m) and not m[j]:
                j += 1
            if i > 0 and j < len(m) and (j - i) <= fill_frames:
                m[i:j] = True
            i = j
        else:
            i += 1
    runs = []
    i = 0
    while i < len(m):
        if m[i]:
            j = i
            while j < len(m) and m[j]:
                j += 1
            if (j - i) * hop_s >= min_len_s:
                runs.append((i, j))
            i = j
        else:
            i += 1
    return runs


def ref_breath_regions(feats, duration, words):
    voiced = feats.voicing > 0.45
    ve = feats.energy_db[voiced]
    median_speech_db = float(np.median(ve)) if ve.size else float(np.median(feats.energy_db))
    noise_floor_db = float(np.percentile(feats.energy_db, 5))
    candidate = (~voiced) & (feats.energy_db > noise_floor_db + 6.0) \
        & (feats.energy_db < median_speech_db - 10.0) & (feats.flatness > 0.08) \
        & (feats.hf_lf_ratio_db < 6.0)
    gaps = detect._gaps_from_words(words, duration) if words else None
    if gaps is not None:
        in_gap = np.zeros_like(candidate)
        for g0, g1 in gaps:
            in_gap |= (feats.times >= g0) & (feats.times < g1)
        candidate &= in_gap
    runs = ref_frame_runs(candidate, feats.hop_s, detect.FILL_HOLE_MS / 1000.0,
                          detect.MIN_BREATH_MS / 1000.0)
    out = []
    for i, j in runs:
        lo = float(feats.times[i])
        hi = float(feats.times[j - 1] + detect.FRAME_MS / 1000.0)
        if gaps is not None:
            for g0, g1 in gaps:
                if g0 <= lo < g1:
                    hi = min(hi, g1 - detect.BREATH_END_MARGIN_S)
                    break
        if hi - lo >= detect.MIN_BREATH_MS / 1000.0:
            out.append((lo, hi))
    return out


# ── The tests ─────────────────────────────────────────────────────────────────────────────────

sig, words = None, None
try:
    made = make_signal()
    sig = made[0] if isinstance(made, tuple) else made
except Exception as e:   # noqa: BLE001
    print("cannot build the synthetic signal:", e)
    sys.exit(2)

# the words test_detect.py hands to the ASR-mode assertion: the gaps around the breath at 1.20-1.45
words = [{"word": "a", "start": 0.15, "end": 0.38}, {"word": "b", "start": 0.55, "end": 1.15},
         {"word": "c", "start": 1.50, "end": 1.78}, {"word": "d", "start": 1.95, "end": 2.08},
         {"word": "e", "start": 2.25, "end": 2.85}]

feats = detect.compute_features(sig, SR)
ref = ref_features(sig, SR)

d = np.abs(feats.voicing - ref["voicing"]).max()
check("voicing (FFT autocorrelation) == the lag loop, max |d| = %.2e" % d, d < 1e-6, d)
for mine, theirs in (("energy_db", "energy_db"), ("hf_lf_ratio_db", "hf_lf"), ("e_mid_db", "e_mid"),
                     ("e_hf_db", "e_hf"), ("zcr", "zcr"), ("flatness", "flatness")):
    d = np.abs(getattr(feats, mine) - ref[theirs]).max()
    check("feature %s == reference, max |d| = %.2e" % (mine, d), d < 1e-6, d)
check("frame times", np.allclose(feats.times, np.arange(len(ref["voicing"])) * feats.hop_s))
check("`voiced` is the score at 0.45", np.array_equal(feats.voiced, feats.voicing > 0.45))

# a signal shorter than a frame, and an all-zero one, do not crash and stay finite
short = detect.compute_features(sig[:100], SR)
check("a signal shorter than one frame gives no frames", len(short.times) == 0)
silent = detect.compute_features(np.zeros(SR // 2), SR)
check("silence: finite features, voicing 0",
      np.isfinite(silent.energy_db).all() and (silent.voicing == 0).all())

for label, w in (("with words", words), ("no words", None)):
    got = detect.breath_regions(sig, SR, feats, DURATION, w)
    want = ref_breath_regions(feats, DURATION, w)
    same = len(got) == len(want) and all(abs(a[0] - b[0]) < 1e-9 and abs(a[1] - b[1]) < 1e-9
                                         for a, b in zip(got, want))
    check("breath_mask(defaults) == the old breath_regions (%s): %d region(s)" % (label, len(got)),
          same, (got, want))
    check("  … and there is at least one breath", len(got) >= 1)


def covered(regions, step=0.001):
    grid = np.arange(0, DURATION, step)
    m = np.zeros(grid.shape, dtype=bool)
    for lo, hi in regions:
        m |= (grid >= lo) & (grid < hi)
    return m


def run(params, w=words):
    stats = detect.breath_stats(feats, params.unvoiced)
    return detect.breath_mask(feats, stats, detect.word_gaps(w, DURATION, params.gap), params)


bare = dict(min_len_on=False, fill_on=False, end_margin_on=False)
base = covered(run(detect.BreathParams(**bare)))
for crit in ("gap", "unvoiced", "above_floor", "below_speech", "flatness", "hf_lf"):
    off = covered(run(detect.BreathParams(**{**bare, crit + "_on": False})))
    check("switching '%s' off never removes coverage (%d -> %d ms)" % (crit, base.sum(), off.sum()),
          bool((off | ~base).all()))

prev = None
mono = True
for thr in np.linspace(0.0, 0.5, 26):
    c = covered(run(detect.BreathParams(flatness=float(thr), **bare))).sum()
    if prev is not None and c > prev:
        mono = False
    prev = c
check("raising the flatness threshold 0 -> 0.5 never adds coverage", mono)

bp = detect.BreathParams.from_values({"gap": 200, "gap_on": False, "flatness": 0.2})
check("BreathParams.from_values", bp.gap == 200 and bp.gap_on is False and bp.flatness == 0.2
      and bp.min_len == detect.MIN_BREATH_MS)

pieces = detect.segment_breaths(DURATION, run(detect.BreathParams()))
check("segment_breaths: jointive, covers [0, duration], two labels",
      abs(pieces[0][0]) < 1e-9 and abs(pieces[-1][1] - DURATION) < 1e-9
      and all(abs(a[1] - b[0]) < 1e-9 for a, b in zip(pieces, pieces[1:]))
      and {p[2] for p in pieces} <= {"voice", "breath"}, pieces)

# ── speed: ten minutes of frames (the small file's features tiled), what a slider drag re-runs ──
reps = 60000 // len(feats.times) + 1


def tile(a):
    return np.tile(a, reps)[:60000]


big = detect.Features(times=np.arange(60000) * feats.hop_s, energy_db=tile(feats.energy_db),
                      hf_lf_ratio_db=tile(feats.hf_lf_ratio_db), e_mid_db=tile(feats.e_mid_db),
                      zcr=tile(feats.zcr), flatness=tile(feats.flatness),
                      voicing=tile(feats.voicing), e_hf_db=tile(feats.e_hf_db), hop_s=feats.hop_s)
big_dur = 60000 * feats.hop_s
big_words = [{"word": "w", "start": i * 1.0 + 0.1, "end": i * 1.0 + 0.6} for i in range(int(big_dur))]
params = detect.BreathParams()
runs_t = []
for _ in range(5):
    t0 = time.perf_counter()
    stats = detect.breath_stats(big, params.unvoiced)
    gaps = detect.word_gaps(big_words, big_dur, params.gap)
    detect.breath_mask(big, stats, gaps, params)
    runs_t.append((time.perf_counter() - t0) * 1000)
best = min(runs_t)
check("breath_mask + stats + gaps on 10 min (60 000 frames): %.1f ms < 20 ms" % best, best < 20.0, runs_t)

# ── the cache ─────────────────────────────────────────────────────────────────────────────────
tmp = tempfile.mkdtemp(prefix="breath-cache-")
os.environ["OBJEKAT_SEPARATEUR_CACHE"] = os.path.join(tmp, "cache")
try:
    wav = os.path.join(tmp, "a.wav")
    with open(wav, "wb") as f:
        f.write(b"RIFFxxxx")
    calls = {"n": 0}

    def compute():
        calls["n"] += 1
        return words, feats, float(SR)

    k = sv.cache_key(wav, 0.0, 3.0, 1.0, "fr", False)
    w1, f1, s1 = sv.cached_analysis(k, compute)
    w2, f2, s2 = sv.cached_analysis(k, compute)
    check("cache: the second call does not analyse again", calls["n"] == 1, calls)
    check("cache: what comes back is what went in",
          w2 == words and s2 == SR and np.allclose(f2.voicing, feats.voicing)
          and np.allclose(f2.times, feats.times) and f2.hop_s == feats.hop_s)
    for label, other in (("offset", sv.cache_key(wav, 0.5, 3.0, 1.0, "fr", False)),
                         ("duration", sv.cache_key(wav, 0.0, 2.0, 1.0, "fr", False)),
                         ("language", sv.cache_key(wav, 0.0, 3.0, 1.0, "en", False)),
                         ("no-asr", sv.cache_key(wav, 0.0, 3.0, 1.0, "fr", True)),
                         ("speed", sv.cache_key(wav, 0.0, 3.0, 2.0, "fr", False))):
        check("cache key changes with the %s" % label, other != k)
    os.utime(wav, (time.time() + 100, time.time() + 100))
    check("cache key changes with the file's mtime", sv.cache_key(wav, 0.0, 3.0, 1.0, "fr", False) != k)
    with open(os.path.join(os.environ["OBJEKAT_SEPARATEUR_CACHE"], k + ".npz"), "wb") as f:
        f.write(b"not an npz")
    sv.cached_analysis(k, compute)
    check("cache: a corrupt file is recomputed, not an error", calls["n"] == 2, calls)
finally:
    shutil.rmtree(tmp, ignore_errors=True)

print()
if FAILS:
    print("%d FAILED" % len(FAILS))
    sys.exit(1)
print("ALL PASS")

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

# ── the evaluation grid: four criteria, fine time grid, low-pass ───────────────────────────────
import transcribe as tr

ef = detect.compute_eval_features(sig, SR)
hop = ef.hop_s
check("eval frames are centred: times = k * hop", np.allclose(ef.times, np.arange(len(ef.times)) * hop)
      and abs(hop - 0.0025) < 1e-6)

# voicing at frame k == the reference score on the 25 ms window CENTRED on k*hop
vlen = int(round(detect.EVAL_VOICING_WINDOW_MS / 1000.0 * SR))
worst = 0.0
for k in (100, 240, 400, 480, 600, 900):
    c = k * int(round(0.0025 * SR))
    seg = sig[c - vlen // 2: c - vlen // 2 + vlen]
    worst = max(worst, abs(ef.voicing[k] - ref_autocorr_voicing(seg, SR)))
check("eval voicing == the reference on the centred window, max |d| = %.2e" % worst, worst < 1e-6, worst)

# the low-passed energy == the energy of the spectrum below the cutoff, computed directly
llen = int(round(detect.EVAL_LP_WINDOW_MS / 1000.0 * SR))
win = np.hanning(llen)
freqs = np.fft.rfftfreq(llen, d=1.0 / SR)
worst = 0.0
for k in (200, 480, 500, 700):
    c = k * int(round(0.0025 * SR))
    seg = sig[c - llen // 2: c - llen // 2 + llen]
    m2 = np.abs(np.fft.rfft(seg * win)) ** 2
    for cut in (300.0, 1500.0, 6000.0):
        want = 10 * math.log10(m2[freqs <= cut].sum() / (np.sum(win ** 2) * llen) + 1e-12)
        got = float(ef.lp_db[k, int(round(cut / 100.0)) - 1])
        worst = max(worst, abs(got - want))
check("low-passed energy == the direct band sum (float16), max |d| = %.3f dB" % worst, worst < 0.15, worst)
check("a lower cutoff never has MORE energy", bool((np.diff(ef.lp_db.astype(np.float64), axis=1) >= -0.1).all()))


def eval_run(**kw):
    p = detect.EvalParams(**kw)
    return detect.eval_mask(ef, detect.eval_speech_level(ef, p.unvoiced, p.cutoff), p, DURATION)


z = eval_run(end_margin=0, min_len=60)
breath = [r for r in z if r[0] > 1.1 and r[1] < 1.55]
check("the synthetic breath [1.20, 1.45] is found, edges within 8 ms: %s" % breath,
      len(breath) == 1 and abs(breath[0][0] - 1.20) < 0.008 and abs(breath[0][1] - 1.45) < 0.008, breath)

# each criterion, off, never REMOVES coverage; and a bare mask (all off) is the whole timeline
def cov(regions):
    g = np.arange(0, DURATION, 0.001)
    m = np.zeros(g.shape, dtype=bool)
    for lo, hi in regions:
        m |= (g >= lo) & (g < hi)
    return m


base = cov(eval_run(min_len_on=False, end_margin_on=False))
for crit in ("unvoiced", "below_speech"):
    off = cov(eval_run(min_len_on=False, end_margin_on=False, **{crit + "_on": False}))
    check("switching '%s' off never removes coverage" % crit, bool((off | ~base).all()))
allon = cov(eval_run(unvoiced_on=False, below_speech_on=False, min_len_on=False, end_margin_on=False))
check("with every criterion off the zone is the whole signal", allon.all())

# min length: raising it never adds a zone
counts = [len(eval_run(min_len=float(m), end_margin_on=False)) for m in (0, 60, 120, 240, 400)]
check("raising the minimum length never adds zones %s" % counts, counts == sorted(counts, reverse=True))
short = eval_run(min_len=0, end_margin_on=False)
check("with min_len off, every zone is kept (>= min_len run)",
      len(eval_run(min_len_on=False, end_margin_on=False)) >= len(short))

# end margin: the zone stops X ms before the first voiced frame that follows it
vidx = np.flatnonzero(ef.voicing > 0.45)
for margin in (0.0, 10.0, 30.0):
    zs = eval_run(min_len_on=False, end_margin=margin)
    ok = True
    for lo, hi in zs:
        nxt = vidx[vidx * hop >= lo - 1e-9]
        if nxt.size and hi > nxt[0] * hop - margin / 1000.0 + 1e-9:
            ok = False
    check("end margin %g ms: every zone ends at least that far before the next voiced frame" % margin, ok)
z0 = eval_run(min_len_on=False, end_margin=0)
z30 = eval_run(min_len_on=False, end_margin=30)
breath0 = [r for r in z0 if 1.1 < r[0] < 1.3][0]
breath30 = [r for r in z30 if 1.1 < r[0] < 1.3][0]
check("a 30 ms margin shortens the breath's end by ~30 ms (%.3f -> %.3f)" % (breath0[1], breath30[1]),
      0.020 < breath0[1] - breath30[1] < 0.040)

# the cutoff has a say, and a lower speech threshold shrinks the candidate set
lo_cut = cov(eval_run(cutoff=300.0, min_len_on=False, end_margin_on=False))
check("the cutoff is a live parameter (speech level differs between 300 Hz and 6 kHz)",
      detect.eval_speech_level(ef, 0.45, 300.0) != detect.eval_speech_level(ef, 0.45, 6000.0))
prev, mono = None, True
for x in (0, 5, 10, 20, 30, 40):
    c = cov(eval_run(below_speech=float(x), min_len_on=False, end_margin_on=False)).sum()
    if prev is not None and c > prev:
        mono = False
    prev = c
check("raising 'X dB under speech' never adds coverage", mono)

ep = detect.EvalParams.from_values({"cutoff": 3000, "below_speech_on": False, "end_margin": 12})
check("EvalParams.from_values", ep.cutoff == 3000.0 and ep.below_speech_on is False
      and ep.end_margin == 12.0 and ep.min_len == 80.0)
check("eval defaults: cutoff 6 kHz, 10 dB, 80 ms, 5 ms",
      (ep.__class__().cutoff, ep.__class__().below_speech, ep.__class__().min_len,
       ep.__class__().end_margin) == (6000.0, 10.0, 80.0, 5.0))
pieces = detect.segment_breaths(DURATION, eval_run())
check("eval zones -> segment_breaths: jointive, two labels",
      abs(pieces[0][0]) < 1e-9 and abs(pieces[-1][1] - DURATION) < 1e-9
      and all(abs(a[1] - b[0]) < 1e-9 for a, b in zip(pieces, pieces[1:]))
      and {p[2] for p in pieces} <= {"voice", "breath"})

# 10 minutes of eval frames: what a slider drag re-runs (speech level + mask)
reps = 240000 // len(ef.times) + 1
big_e = detect.EvalFeatures(times=np.arange(240000) * hop, voicing=np.tile(ef.voicing, reps)[:240000],
                            lp_db=np.tile(ef.lp_db, (reps, 1))[:240000], cutoffs=ef.cutoffs, hop_s=hop)
p = detect.EvalParams()
runs_t = []
for _ in range(5):
    t0 = time.perf_counter()
    lvl = detect.eval_speech_level(big_e, p.unvoiced, p.cutoff)
    detect.eval_mask(big_e, lvl, p)
    runs_t.append((time.perf_counter() - t0) * 1000)
check("eval speech level + mask on 10 min (240 000 frames): %.1f ms < 30 ms" % min(runs_t),
      min(runs_t) < 30.0, runs_t)
# ...and the mask alone, the speech level being cached per (voicing, cutoff)
lvl = detect.eval_speech_level(big_e, p.unvoiced, p.cutoff)
t0 = time.perf_counter()
detect.eval_mask(big_e, lvl, p)
mask_ms = (time.perf_counter() - t0) * 1000
check("eval mask alone on 10 min: %.1f ms < 20 ms" % mask_ms, mask_ms < 20.0, mask_ms)

# ── CTC forced alignment (numpy Viterbi) on a hand-made emission ───────────────────────────────
V, blank = 5, 0
lp = np.full((12, V), -8.0)
plan = [0, 1, 1, 0, 2, 2, 0, 0, 3, 0, 3, 0]          # tokens 1, 2, 3, 3 (the repeat needs its blank)
for t, s in enumerate(plan):
    lp[t, s] = -0.01
sp = tr.ctc_forced_align(lp, [1, 2, 3, 3], blank)
check("ctc_forced_align recovers the token spans %s" % sp, sp == [(1, 2), (4, 5), (8, 8), (10, 10)], sp)
check("ctc_forced_align refuses audio too short for the text",
      tr.ctc_forced_align(np.log(np.full((3, V), 0.2)), [1, 2, 3, 3, 1], blank) is None)

# ── models: ids, availability, and nothing installed is a label ────────────────────────────────
check("model ids: none first", tr.MODEL_IDS[0] == "none" and set(tr.MODEL_IDS) == {"none", "whisper", "parakeet", "align"})
check("'none' is always installed; an unknown id never is",
      tr.installed("none") and not tr.installed("nope"))
_saved = tr.PARAKEET_PYTHON
tr.PARAKEET_PYTHON = "/nonexistent/python3"
check("parakeet with no venv is 'not installed', not an error", tr.installed("parakeet") is False)
tr.PARAKEET_PYTHON = _saved

# ── the caches ─────────────────────────────────────────────────────────────────────────────────
tmp = tempfile.mkdtemp(prefix="breath-cache-")
os.environ["OBJEKAT_SEPARATEUR_CACHE"] = os.path.join(tmp, "cache")
try:
    wav = os.path.join(tmp, "a.wav")
    with open(wav, "wb") as f:
        f.write(b"RIFFxxxx")
    calls = {"n": 0}

    def compute():
        calls["n"] += 1
        return ef

    k = sv.cache_key(wav, 0.0, 3.0, 1.0)
    f1 = sv.cached_features(k, compute)
    f2 = sv.cached_features(k, compute)
    check("features cache: the second call does not analyse again", calls["n"] == 1, calls)
    check("features cache: what comes back is what went in",
          np.allclose(f2.voicing, ef.voicing) and np.array_equal(f2.lp_db, ef.lp_db)
          and np.allclose(f2.times, ef.times) and f2.hop_s == ef.hop_s and f2.lp_db.dtype == np.float16)
    for label, other in (("offset", sv.cache_key(wav, 0.5, 3.0, 1.0)),
                         ("duration", sv.cache_key(wav, 0.0, 2.0, 1.0)),
                         ("speed", sv.cache_key(wav, 0.0, 3.0, 2.0))):
        check("features key changes with the %s" % label, other != k)
    os.utime(wav, (time.time() + 100, time.time() + 100))
    check("features key changes with the file's mtime", sv.cache_key(wav, 0.0, 3.0, 1.0) != k)
    with open(os.path.join(os.environ["OBJEKAT_SEPARATEUR_CACHE"], k + ".npz"), "wb") as f:
        f.write(b"not an npz")
    sv.cached_features(k, compute)
    check("features cache: a corrupt file is recomputed, not an error", calls["n"] == 2, calls)

    # words: one entry PER MODEL and language; a transcription is made once
    wk = {m: sv.words_cache_key(wav, 0.0, 3.0, 1.0, "fr", m) for m in ("whisper", "parakeet", "align")}
    check("words keys differ per model, per language, and from the features key",
          len(set(wk.values())) == 3 and sv.words_cache_key(wav, 0.0, 3.0, 1.0, "en", "whisper") != wk["whisper"]
          and wk["whisper"] != sv.cache_key(wav, 0.0, 3.0, 1.0))
    wcalls = {"n": 0}

    def wcompute():
        wcalls["n"] += 1
        return words, 1.5

    w1 = sv.cached_words(wk["whisper"], wcompute)
    w2 = sv.cached_words(wk["whisper"], wcompute)
    check("words cache: made once, then read (from_cache flips)", wcalls["n"] == 1
          and w1[2] is False and w2[2] is True and w2[0] == words and w2[1] == 1.5, (wcalls, w1[2], w2[2]))
    sv.cached_words(wk["parakeet"], wcompute)
    check("words cache: another model is another entry", wcalls["n"] == 2)

    # the Transcriber hands a backend's failure back as a value, never as a crash
    import threading
    obj = {"file": wav, "source_offset": 0.0, "duration": 3.0, "speed": 1.0}
    t = sv.Transcriber(obj, "es", lambda: (sig, SR))
    tr_orig = tr.transcribe
    tr.transcribe = lambda model, mono, sr, lang: (_ for _ in ()).throw(RuntimeError("boom"))
    try:
        t.request("whisper")
        for _ in range(100):
            if t.collect():
                break
            time.sleep(0.05)
    finally:
        tr.transcribe = tr_orig
    check("Transcriber: a failing backend is a RuntimeError value and frees the worker",
          isinstance(t.done.get("whisper"), RuntimeError) and t.running is None, t.done)
finally:
    shutil.rmtree(tmp, ignore_errors=True)

print()
if FAILS:
    print("%d FAILED" % len(FAILS))
    sys.exit(1)
print("ALL PASS")

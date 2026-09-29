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

# ── the evaluation grid: fine time grid, low-pass, hole filling, text, two categories ──────────
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

# the low-passed energy, the HF / LF band energies and the zero-crossing rate == computed directly
llen = int(round(detect.EVAL_LP_WINDOW_MS / 1000.0 * SR))
win = np.hanning(llen)
freqs = np.fft.rfftfreq(llen, d=1.0 / SR)
worst, worst_hf, worst_lf, worst_z = 0.0, 0.0, 0.0, 0.0
norm = np.sum(win ** 2) * llen
for k in (200, 480, 500, 700, 720, 870):
    c = k * int(round(0.0025 * SR))
    seg = sig[c - llen // 2: c - llen // 2 + llen]
    m2 = np.abs(np.fft.rfft(seg * win)) ** 2
    hf = m2[(freqs >= 4000) & (freqs <= 10000)].sum()
    lf = m2[(freqs >= 80) & (freqs <= 1000)].sum()
    worst_hf = max(worst_hf, abs(ef.hf_db[k] - 10 * math.log10(hf / norm + 1e-12)))
    worst_lf = max(worst_lf, abs(ef.lf_db[k] - 10 * math.log10(lf / norm + 1e-12)))
    neg = seg < 0
    worst_z = max(worst_z, abs(ef.zcr[k] - np.mean(neg[1:] != neg[:-1])))
# the low-passed energy == a direct Butterworth low-pass (same resampling, zero phase), per cutoff
from math import gcd as _gcd
from scipy.signal import butter as _butter, resample_poly as _rp, sosfiltfilt as _sff
_g = _gcd(int(SR), detect.EVAL_LP_RATE)
_y = _rp(sig - sig.mean(), detect.EVAL_LP_RATE // _g, int(SR) // _g)
_w = int(round(detect.EVAL_LP_WINDOW_MS / 1000.0 * detect.EVAL_LP_RATE))
for ci, cut in enumerate(detect.EVAL_CUTOFFS[[0, 1, 4, 9]]):
    _z = _sff(_butter(detect.EVAL_LP_ORDER, cut, fs=detect.EVAL_LP_RATE, output="sos"), _y)
    col = list(detect.EVAL_CUTOFFS).index(cut)
    for k in (200, 480, 500, 700, 720, 870):
        c0 = int(round(ef.times[k] * detect.EVAL_LP_RATE)) - _w // 2
        want = 10 * math.log10(float(np.mean(_z[c0:c0 + _w] ** 2)) + 1e-12)
        worst = max(worst, abs(float(ef.lp_db[k, col]) - want))
check("low-passed energy == a direct Butterworth low-pass (float16), max |d| = %.3f dB" % worst, worst < 0.15, worst)
# a tone ABOVE the cutoff is attenuated, one BELOW passes: it is really a low-pass
_t = np.arange(int(SR)) / SR
_lo = detect.compute_eval_features(0.3 * np.sin(2 * np.pi * 150 * _t), SR)
_hi = detect.compute_eval_features(0.3 * np.sin(2 * np.pi * 800 * _t), SR)
_c = list(detect.EVAL_CUTOFFS).index(200.0)
_m = slice(100, 300)
_att = float(np.mean(_lo.lp_db[_m, _c].astype(float)) - np.mean(_hi.lp_db[_m, _c].astype(float)))
check("200 Hz low-pass: an 800 Hz tone sits >= 40 dB under a 150 Hz one (%.1f dB)" % _att, _att >= 40, _att)
check("HF band energy == the direct band sum, max |d| = %.4f dB" % worst_hf, worst_hf < 1e-3, worst_hf)
check("LF band energy == the direct band sum, max |d| = %.4f dB" % worst_lf, worst_lf < 1e-3, worst_lf)
check("zero-crossing rate == the direct count, max |d| = %.2e" % worst_z, worst_z < 1e-6, worst_z)
# (No "a lower cutoff never has more energy" here: that holds for a spectrum, not for a real filter
# read on a 12 ms window — near an attack a lower cutoff rings longer and can briefly carry MORE
# energy. What a low-pass must do is checked on steady tones below.)
seen = []
ef_p = detect.compute_eval_features(sig, SR, progress=seen.append)
check("compute_eval_features reports progress: rising, ending on 1.0 (%d calls)" % len(seen),
      len(seen) >= 1 and seen == sorted(seen) and abs(seen[-1] - 1.0) < 1e-9)

# ── the defaults the user fixed ──
d = detect.EvalSettings.from_values({})
check("defaults — breaths: voicing 0.4, 10 dB, cutoff 200 Hz, 120 ms",
      (d.breath.unvoiced, d.breath.below_speech, d.breath.cutoff, d.breath.min_len) == (0.4, 10.0, 200.0, 120.0))
check("defaults — each block owns its hole filling ON 20 ms, text ON, tolerance 500 ms",
      all((x.fill_on, x.fill, x.text_on, x.tolerance) == (True, 20.0, True, 500.0)
          for x in (d.breath, d.sibilant)) and not hasattr(d, "common"))
check("the end margin is gone", not hasattr(d.breath, "end_margin") and not hasattr(d.breath, "end_margin_on"))
es = detect.EvalSettings.from_values({"b_cutoff": 400, "b_below_speech_on": False, "b_tolerance": 300,
                                      "b_fill": 0, "s_zcr": 0.2, "s_on": False})
check("EvalSettings.from_values reads the prefixed panel ids",
      es.breath.cutoff == 400.0 and es.breath.below_speech_on is False and es.breath.tolerance == 300.0
      and es.breath.fill == 0.0 and es.sibilant.tolerance == 500.0 and es.sibilant.zcr == 0.2 and es.sibilant.on is False
      and es.breath.min_len == 120.0)


def settings(**kw):
    """Breaths alone, no text unless asked, hole filling at its default."""
    values = {"s_on": False}
    values.update(kw)
    return detect.EvalSettings.from_values(values)


def breath_run(**kw):
    s = settings(**kw)
    return detect.eval_zones(ef, s, DURATION, None, "fr")["breath"]


z = breath_run(b_min_len=80)
breath = [r for r in z if r[0] > 1.1 and r[1] < 1.55]
check("the synthetic breath [1.20, 1.45] is found, edges within 10 ms: %s" % breath,
      len(breath) == 1 and abs(breath[0][0] - 1.20) < 0.010 and abs(breath[0][1] - 1.45) < 0.010, breath)


def cov(regions):
    g = np.arange(0, DURATION, 0.001)
    m = np.zeros(g.shape, dtype=bool)
    for lo, hi in regions:
        m |= (g >= lo) & (g < hi)
    return m


# each criterion, off, never REMOVES coverage; a bare mask (all off) is the whole timeline
bare = dict(b_min_len_on=False, b_fill_on=False)
base = cov(breath_run(**bare))
for crit in ("b_unvoiced", "b_below_speech"):
    off = cov(breath_run(**bare, **{crit + "_on": False}))
    check("switching '%s' off never removes coverage" % crit, bool((off | ~base).all()))
allon = cov(breath_run(b_unvoiced_on=False, b_below_speech_on=False, **bare))
check("with every criterion off the zone is the whole signal", allon.all())

counts = [len(breath_run(b_min_len=float(m), b_fill_on=False)) for m in (80, 120, 160, 200)]
check("raising the minimum length never adds zones %s" % counts, counts == sorted(counts, reverse=True))
lens = [min((h - l) for l, h in breath_run(b_min_len=float(m), b_fill_on=False) or [(0, 9)]) for m in (80, 120, 200)]
check("every zone kept is at least the minimum length %s" % lens, all(x * 1000 >= m - 1e-6 for x, m in zip(lens, (80, 120, 200))))

prev, mono = None, True
for x in (3, 6, 10, 15):
    c = cov(breath_run(b_below_speech=float(x), **bare)).sum()
    if prev is not None and c > prev:
        mono = False
    prev = c
check("raising 'X dB under speech' never adds coverage", mono)
prev, mono = None, True
for x in (0.2, 0.3, 0.4, 0.5, 0.6):
    c = cov(breath_run(b_unvoiced=x, **bare)).sum()
    if prev is not None and c < prev:
        mono = False
    prev = c
check("raising the voicing ceiling never removes coverage", mono)
check("the cutoff is a live parameter (speech level differs between 200 Hz and 1 kHz)",
      detect.eval_speech_level(ef, 0.4, 200.0) != detect.eval_speech_level(ef, 0.4, 1000.0))

# ── THE HOLE FILLING (bouche-trou), on a hand-made grid so the hole is exactly as long as said ──
def hand_features(pattern):
    """A grid whose voicing says exactly where the candidate frames are (`1` = candidate)."""
    n = len(pattern)
    return detect.EvalFeatures(times=np.arange(n) * 0.0025, voicing=np.where(np.array(pattern) == 1, 0.0, 1.0),
                               lp_db=np.zeros((n, len(detect.EVAL_CUTOFFS)), dtype=np.float16),
                               cutoffs=detect.EVAL_CUTOFFS.copy(), hop_s=0.0025,
                               hf_db=np.full(n, -60.0, dtype=np.float32), lf_db=np.full(n, -60.0, dtype=np.float32),
                               zcr=np.zeros(n, dtype=np.float32))


def two_zones(hole_frames, **kw):
    pat = [0] * 20 + [1] * 40 + [0] * hole_frames + [1] * 40 + [0] * 20
    f = hand_features(pat)
    s = detect.EvalSettings.from_values({"b_below_speech_on": False, "b_min_len_on": False,
                                         "s_on": False, "b_text_on": False, **kw})
    return detect.eval_zones(f, s, len(pat) * 0.0025, None, "fr")["breath"]


check("a hole SHORTER than the setting is bridged (15 ms hole, fill 20): 1 zone",
      len(two_zones(6, b_fill_on=True, b_fill=20)) == 1, two_zones(6, b_fill_on=True, b_fill=20))
check("a hole as long as the setting is bridged (15 ms hole, fill 15): 1 zone",
      len(two_zones(6, b_fill_on=True, b_fill=15)) == 1)
check("a hole LONGER than the setting stays open (30 ms hole, fill 20): 2 zones",
      len(two_zones(12, b_fill_on=True, b_fill=20)) == 2, two_zones(12, b_fill_on=True, b_fill=20))
check("a hole one frame longer than the setting stays open (15 ms hole, fill 12.5): 2 zones",
      len(two_zones(6, b_fill_on=True, b_fill=12.5)) == 2)
check("with the box OFF nothing is bridged (15 ms hole): 2 zones", len(two_zones(6, b_fill_on=False, b_fill=100)) == 2)
merged = two_zones(6, b_fill_on=True, b_fill=20)[0]
check("a bridged zone runs from the first zone's start to the second's end (%.4f-%.4f)" % merged,
      abs(merged[0] - (20 * 0.0025 - 0.00125)) < 1e-6 and abs(merged[1] - ((20 + 86 - 1) * 0.0025 + 0.00125)) < 1e-6, merged)
check("a hole at the very edge of the file is never bridged",
      len(two_zones(0, b_fill_on=True, b_fill=100)) == 1)
n_off = len(breath_run(b_unvoiced=0.6, b_below_speech_on=False, b_min_len_on=False, b_fill_on=False))
n_on = len(breath_run(b_unvoiced=0.6, b_below_speech_on=False, b_min_len_on=False, b_fill_on=True, b_fill=100))
check("on the real signal the filling only ever MERGES zones (%d -> %d)" % (n_off, n_on), n_on <= n_off)
c_off = cov(breath_run(b_unvoiced=0.6, b_below_speech_on=False, b_min_len_on=False, b_fill_on=False))
c_on = cov(breath_run(b_unvoiced=0.6, b_below_speech_on=False, b_min_len_on=False, b_fill_on=True, b_fill=100))
check("...and never removes coverage", bool((c_on | ~c_off).all()))

# ── THE TEXT as a criterion ──
gaps_w = [{"word": "a", "start": 0.20, "end": 1.05}, {"word": "b", "start": 1.60, "end": 2.90}]
check("word gaps: the head, the space between two words, the tail",
      [(round(a, 3), round(b, 3)) for a, b in detect.word_gap_intervals(gaps_w, 3.0)]
      == [(0.0, 0.2), (1.05, 1.6), (2.9, 3.0)])
zs = [(0.5, 0.6)]
check("keep_near: a zone at exactly the tolerance is kept, one millisecond further is not",
      detect.keep_near(zs, [(0.7, 0.8)], 0.1) == zs and detect.keep_near(zs, [(0.701, 0.8)], 0.1) == []
      and detect.keep_near(zs, [(0.0, 0.4)], 0.1) == zs and detect.keep_near(zs, [(0.3, 0.55)], 0.0) == zs)
check("keep_near: no place, nothing is near anything", detect.keep_near(zs, [], 9.0) == [])
far_words = [{"word": "long", "start": 0.15, "end": 2.90}]      # the only gaps are the head and the tail
no_text = breath_run(b_min_len=80, b_text_on=False)
check("no words: the text changes nothing (breath still there)",
      any(1.1 < r[0] < 1.3 for r in detect.eval_zones(ef, settings(b_min_len=80, b_text_on=True), DURATION,
                                                        None, "fr")["breath"]))
def with_words(words, **kw):
    return detect.eval_zones(ef, settings(b_min_len=80, **kw), DURATION, words, "fr")["breath"]
has = lambda zs_: any(1.1 < r[0] < 1.3 for r in zs_)         # noqa: E731
check("the breath sits in a gap between words: kept at tolerance 50 ms", has(with_words(gaps_w, b_text_on=True, b_tolerance=50)))
check("a breath 1 s from any gap is dropped at tolerance 800 ms", not has(with_words(far_words, b_text_on=True, b_tolerance=800)))
check("...kept once the box is unchecked", has(with_words(far_words, b_text_on=False, b_tolerance=50)))
check("text ON drops zones, never adds: %d <= %d" % (len(with_words(gaps_w, b_text_on=True, b_tolerance=50)),
                                                    len(no_text)),
      len(with_words(gaps_w, b_text_on=True, b_tolerance=50)) <= len(no_text))

# ── PRIORITY: where the categories overlap, SS/CH wins ──
check("subtract_zones: a cut splits a zone in two and eats a whole one",
      detect.subtract_zones([(0.0, 1.0), (2.0, 3.0)], [(0.4, 0.5), (1.9, 3.1)]) == [(0.0, 0.4), (0.5, 1.0)])
loose = detect.EvalSettings.from_values({"b_unvoiced_on": False, "b_below_speech_on": False,
                                         "b_min_len_on": False, "b_text_on": False})
both = detect.eval_zones(ef, loose, DURATION, None, "fr")
b_cov, s_cov = cov(both["breath"]), cov(both["sibilant"])
check("with a breath category that covers everything, SS/CH still takes its stretch (%d SS/CH zones)"
      % len(both["sibilant"]), len(both["sibilant"]) >= 2)
check("the two categories never overlap", not (b_cov & s_cov).any())
check("the SS/CH zones are untouched by the breath category",
      detect.eval_zones(ef, detect.EvalSettings.from_values({"b_on": False, "b_text_on": False}), DURATION,
                        None, "fr")["sibilant"] == both["sibilant"])
check("a category switched off returns nothing",
      detect.eval_zones(ef, detect.EvalSettings.from_values({"b_on": False, "s_on": False}), DURATION,
                        None, "fr") == {"breath": [], "sibilant": []})

pieces = detect.segment_zones(DURATION, both)
check("segment_zones: jointive, covers [0, duration], three labels",
      abs(pieces[0][0]) < 1e-9 and abs(pieces[-1][1] - DURATION) < 1e-9
      and all(abs(a[1] - b[0]) < 1e-9 for a, b in zip(pieces, pieces[1:]))
      and {p[2] for p in pieces} <= {"voice", "breath", "sibilant"}, pieces)
cuts, lanes = detect.cuts_and_lanes(detect.segment_zones(DURATION, {"sibilant": both["sibilant"]}),
                                    {"voice": 0, "sibilant": 1})
check("cuts_and_lanes with a category off: lanes are contiguous from 0",
      len(lanes) == len(cuts) + 1 and set(lanes) <= {0, 1})

# 10 minutes of eval frames: what a slider drag re-runs (speech level + both masks)
reps = 240000 // len(ef.times) + 1
big_e = detect.EvalFeatures(times=np.arange(240000) * hop, voicing=np.tile(ef.voicing, reps)[:240000],
                            lp_db=np.tile(ef.lp_db, (reps, 1))[:240000], cutoffs=ef.cutoffs, hop_s=hop,
                            hf_db=np.tile(ef.hf_db, reps)[:240000], lf_db=np.tile(ef.lf_db, reps)[:240000],
                            zcr=np.tile(ef.zcr, reps)[:240000])
st = detect.EvalSettings.from_values({"b_text_on": False})
runs_t = []
lvl = detect.eval_speech_level(big_e, st.breath.unvoiced, st.breath.cutoff)
big_e.hf_floor_db()
for _ in range(5):
    t0 = time.perf_counter()
    detect.eval_zones(big_e, st, 600.0, None, "fr", lvl)
    runs_t.append((time.perf_counter() - t0) * 1000)
check("both masks on 10 min (240 000 frames): %.1f ms < 60 ms" % min(runs_t), min(runs_t) < 60.0, runs_t)
big_words = [{"word": "sa", "start": i * 1.0 + 0.1, "end": i * 1.0 + 0.6} for i in range(600)]
st_t = detect.EvalSettings.from_values({"b_text_on": True})
t0 = time.perf_counter()
detect.eval_zones(big_e, st_t, 600.0, big_words, "fr", lvl)
check("...with 600 words as a criterion: %.1f ms < 200 ms" % ((time.perf_counter() - t0) * 1000),
      (time.perf_counter() - t0) * 1000 < 200.0)

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
_saved = tr._has_module
tr._has_module = lambda name: False
check("parakeet without its module is 'not installed', not an error", tr.installed("parakeet") is False
      and tr.installed("whisper") is False and tr.installed("align") is False)
tr._has_module = _saved

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
          and np.allclose(f2.times, ef.times) and f2.hop_s == ef.hop_s and f2.lp_db.dtype == np.float16
          and np.array_equal(f2.hf_db, ef.hf_db) and np.array_equal(f2.lf_db, ef.lf_db) and np.array_equal(f2.zcr, ef.zcr))
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
    tr.transcribe = lambda model, mono, sr, lang, progress=None: (_ for _ in ()).throw(RuntimeError("boom"))
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

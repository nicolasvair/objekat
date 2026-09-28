#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Pure signal detection for the "voice separator" script — no socket, no Whisper import at
module scope, importable and unit-testable on its own (@see test_detect.py).

The contract (@see plan_separateur_voix.md, D2): given a mono signal at its NATIVE sample rate
(the portion of the file the object actually plays) and, optionally, Whisper's word timestamps
(seconds RELATIVE TO THE START OF THAT SAME PORTION), produce a segmentation of the whole portion
into three labels — "voice" (the default), "breath", "sibilant" (SS and CH share one label: D6
puts them on the SAME sub-lane) — as a list of contiguous, non-overlapping pieces covering
`[0, duration]` exactly.

Whisper situates the WORD; the frame-by-frame band energy situates the FRICTION or the BREATH at
10 ms — the orthography FILTERS which words are sibilant candidates, the signal BOUNDS where
inside them. Without word timestamps (`words=None`, `--no-asr`), the acoustic criteria alone
decide, with a wider tolerance (the caller is expected to relax its own assertions accordingly).
"""

from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np

FRAME_MS = 25.0
HOP_MS = 10.0
MIN_GAP_MS = 120.0          # a candidate breath gap between two words
MIN_BREATH_MS = 80.0        # the shortest run counted as a breath
MIN_SIBILANT_MS = 30.0      # the shortest run counted as a sibilant
FILL_HOLE_MS = 20.0         # a hole this short or shorter is bridged
MIN_PIECE_MS = 20.0         # a piece shorter than this is folded into its neighbour
WORD_SEARCH_MARGIN_S = 0.040
BREATH_END_MARGIN_S = 0.015

# Grapheme sets used to shortlist a sibilant/CH CANDIDATE word — the orthography filters,
# the signal bounds (@see module docstring). Deliberately coarse: a false positive here costs
# nothing (the signal criterion below still has to fire), a false negative would silently drop a
# real "s" the script was asked to find.
SIBILANT_GRAPHEMES = {
    "fr": ["ch", "ss", "ç", "sh", "s", "x", "z", "ce", "ci", "cy", "ge", "gi", "gy"],
    "en": ["sh", "ch", "-tion", "x", "z", "s", "ce", "ci", "cy", "ge", "gi", "gy"],
    "es": ["ch", "ll", "s", "z", "x", "ce", "ci"],
}


def graphemes_for(word: str, language: str) -> int:
    """The number `k` of sibilant/CH graphemes a word contains for `language` — how many
    fricative REGIONS the signal is allowed to keep for that word (@see sibilant_regions)."""
    w = word.lower()
    table = SIBILANT_GRAPHEMES.get(language, SIBILANT_GRAPHEMES["fr"])
    count = 0
    i = 0
    while i < len(w):
        matched = False
        for g in sorted(table, key=len, reverse=True):
            if w.startswith(g, i):
                count += 1
                i += len(g)
                matched = True
                break
        if not matched:
            i += 1
    return count


def is_sibilant_candidate(word: str, language: str) -> bool:
    return graphemes_for(word, language) > 0


# MARK: - Per-frame features

@dataclass
class Features:
    times: np.ndarray          # frame START times, seconds, relative to the portion
    energy_db: np.ndarray
    hf_lf_ratio_db: np.ndarray  # 10*log10(E[4-10kHz] / E[80-1000Hz])
    e_mid_db: np.ndarray        # 10*log10(E[1-4kHz])
    zcr: np.ndarray
    flatness: np.ndarray
    voiced: np.ndarray          # bool
    e_hf_db: np.ndarray          # 10*log10(E[4-10kHz]) — the sibilant refinement reads THIS, not the raw envelope
    hop_s: float


def _band_energy(mag2: np.ndarray, freqs: np.ndarray, lo: float, hi: float) -> float:
    band = mag2[(freqs >= lo) & (freqs <= hi)]
    return float(band.sum()) if band.size else 0.0


def _autocorr_voicing(frame: np.ndarray, sr: float) -> float:
    """Normalised autocorrelation peak over the 70-400 Hz lag range — a crude but cheap voicing
    detector, exactly the strength D2 asks for (a filter for a CANDIDATE, not a pitch tracker)."""
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


def compute_features(samples: np.ndarray, sr: float) -> Features:
    frame_len = max(2, int(round(FRAME_MS / 1000.0 * sr)))
    hop_len = max(1, int(round(HOP_MS / 1000.0 * sr)))
    n = len(samples)
    window = np.hanning(frame_len)
    n_frames = max(0, 1 + (n - frame_len) // hop_len) if n >= frame_len else 0

    times = np.zeros(n_frames)
    energy_db = np.zeros(n_frames)
    hf_lf = np.zeros(n_frames)
    e_mid = np.zeros(n_frames)
    e_hf = np.zeros(n_frames)
    zcr = np.zeros(n_frames)
    flatness = np.zeros(n_frames)
    voiced = np.zeros(n_frames, dtype=bool)

    eps = 1e-12
    for i in range(n_frames):
        start = i * hop_len
        frame = samples[start:start + frame_len]
        if len(frame) < frame_len:
            frame = np.pad(frame, (0, frame_len - len(frame)))
        times[i] = start / sr

        w = frame * window
        energy_db[i] = 10.0 * math.log10(float(np.mean(frame ** 2)) + eps)

        spectrum = np.fft.rfft(w)
        mag2 = (spectrum.real ** 2 + spectrum.imag ** 2)
        freqs = np.fft.rfftfreq(frame_len, d=1.0 / sr)

        e_lf_v = _band_energy(mag2, freqs, 80.0, 1000.0)
        e_hf_v = _band_energy(mag2, freqs, 4000.0, 10000.0)
        hf_lf[i] = 10.0 * math.log10((e_hf_v + eps) / (e_lf_v + eps))
        e_hf[i] = 10.0 * math.log10(e_hf_v + eps)
        e_mid[i] = 10.0 * math.log10(_band_energy(mag2, freqs, 1000.0, 4000.0) + eps)

        signs = np.sign(frame)
        signs[signs == 0] = 1
        zcr[i] = float(np.mean(signs[1:] != signs[:-1]))

        # Restricted to the band a breath actually occupies (300-4000 Hz): the full spectrum
        # would include the near-zero bins OUTSIDE a band-limited sound's own energy, and those
        # collapse a geometric mean to ~0 regardless of how flat the sound is WITHIN its band.
        band = mag2[(freqs >= 300.0) & (freqs <= 4000.0)]
        if band.size:
            band = band + eps
            gmean = math.exp(float(np.mean(np.log(band))))
            amean = float(np.mean(band))
            flatness[i] = gmean / amean if amean > 0 else 0.0
        voiced[i] = _autocorr_voicing(frame, sr) > 0.45

    return Features(times=times, energy_db=energy_db, hf_lf_ratio_db=hf_lf, e_mid_db=e_mid,
                    zcr=zcr, flatness=flatness, voiced=voiced, e_hf_db=e_hf, hop_s=hop_len / sr)


# MARK: - Runs of frames matching a predicate

def _frame_runs(mask: np.ndarray, hop_s: float, fill_holes_s: float, min_len_s: float):
    """Contiguous [start, end) index runs of `True` in `mask`, holes of at most `fill_holes_s`
    bridged first, then filtered to at least `min_len_s` long."""
    if mask.size == 0:
        return []
    fill_frames = int(round(fill_holes_s / hop_s))
    m = mask.copy()
    # Bridge short holes: a run of `False` of length <= fill_frames surrounded by `True` becomes `True`.
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
            length_s = (j - i) * hop_s
            if length_s >= min_len_s:
                runs.append((i, j))
            i = j
        else:
            i += 1
    return runs


def _refine_envelope_bounds(samples: np.ndarray, sr: float, lo: float, hi: float) -> tuple[float, float]:
    """Tightens `[lo, hi]` (seconds) onto the RMS envelope of the raw signal: the threshold sits
    halfway between the segment's floor and its peak, read on a 5 ms sliding RMS."""
    win = max(1, int(round(0.005 * sr)))
    i0 = max(0, int(round(lo * sr)))
    i1 = min(len(samples), int(round(hi * sr)))
    if i1 - i0 < win:
        return lo, hi
    seg = samples[i0:i1]
    n = len(seg) // win
    if n < 2:
        return lo, hi
    rms = np.array([math.sqrt(float(np.mean(seg[k * win:(k + 1) * win] ** 2)) + 1e-12)
                    for k in range(n)])
    threshold = (rms.min() + rms.max()) / 2.0
    above = np.where(rms >= threshold)[0]
    if above.size == 0:
        return lo, hi
    new_lo = lo + (above[0] * win) / sr
    new_hi = lo + ((above[-1] + 1) * win) / sr
    # A run whose RMS barely varies (typical of a steady noise burst, as against a real rise-then-
    # fall envelope) can see the halfway threshold keep only its single loudest window — a
    # tightening that THROWS AWAY most of a detection nobody asked to shrink. Kept only when it
    # still covers at least half of what came in.
    if new_hi - new_lo < 0.5 * (hi - lo):
        return lo, hi
    return new_lo, new_hi


# MARK: - Breaths

def breath_regions(samples: np.ndarray, sr: float, feats: Features, duration: float,
                   words: list[dict] | None) -> list[tuple[float, float]]:
    voiced_energy = feats.energy_db[feats.voiced]
    median_speech_db = float(np.median(voiced_energy)) if voiced_energy.size else float(np.median(feats.energy_db))
    noise_floor_db = float(np.percentile(feats.energy_db, 5))
    sib_threshold_db = 6.0

    candidate = (~feats.voiced) \
        & (feats.energy_db > noise_floor_db + 6.0) \
        & (feats.energy_db < median_speech_db - 10.0) \
        & (feats.flatness > 0.08) \
        & (feats.hf_lf_ratio_db < sib_threshold_db)

    gaps = _gaps_from_words(words, duration) if words else None
    if gaps is not None:
        in_gap = np.zeros_like(candidate)
        for g0, g1 in gaps:
            in_gap |= (feats.times >= g0) & (feats.times < g1)
        candidate &= in_gap

    runs = _frame_runs(candidate, feats.hop_s, FILL_HOLE_MS / 1000.0, MIN_BREATH_MS / 1000.0)
    out = []
    for i, j in runs:
        lo = float(feats.times[i])
        # `times[k]` is a frame's START; the frame itself spans FRAME_MS (25), not HOP_MS (10) —
        # closing the run on `+ hop_s` alone under-ran the true end by the 15 ms difference on
        # every boundary (found chasing a stray 20 ms miss in test_detect.py's ASR-mode assertion).
        hi = float(feats.times[j - 1] + FRAME_MS / 1000.0)
        # No raw-envelope refinement here (unlike a sibilant's HF-peak one, @see
        # _refine_hf_bounds): a breath's envelope is close to flat noise, and the 5 ms RMS
        # window's halfway threshold nibbles at the tail long before the frame-level (10 ms hop)
        # bound the candidate mask already gives — the frame resolution IS the refinement.
        if gaps is not None:
            # The margin belongs to whichever gap this run fell in.
            for g0, g1 in gaps:
                if g0 <= lo < g1:
                    hi = min(hi, g1 - BREATH_END_MARGIN_S)
                    break
        if hi - lo >= MIN_BREATH_MS / 1000.0:
            out.append((lo, hi))
    return out


def _gaps_from_words(words, duration):
    gaps = []
    prev_end = 0.0
    for wd in sorted(words, key=lambda w: w["start"]):
        if wd["start"] - prev_end >= MIN_GAP_MS / 1000.0:
            gaps.append((prev_end, wd["start"]))
        prev_end = max(prev_end, wd["end"])
    if duration - prev_end >= MIN_GAP_MS / 1000.0:
        gaps.append((prev_end, duration))
    return gaps


# MARK: - Sibilants / CH

def _refine_hf_bounds(feats: Features, i: int, j: int) -> tuple[float, float]:
    """Tightens frame range `[i, j)` onto the -12 dB threshold of ITS OWN HF-band peak
    (`e_hf_db`) — read from the frame features already computed, not from the raw envelope: a
    fricative's HF energy is exactly what told the coarse detector to look here, so refining
    against the SAME measurement cannot disagree with it the way a raw RMS reading can."""
    segment = feats.e_hf_db[i:j]
    if segment.size == 0:
        return float(feats.times[i]), float(feats.times[j - 1] + FRAME_MS / 1000.0)
    threshold = float(segment.max()) - 12.0
    above = np.where(segment >= threshold)[0]
    if above.size == 0:
        return float(feats.times[i]), float(feats.times[j - 1] + FRAME_MS / 1000.0)
    lo = float(feats.times[i + above[0]])
    hi = float(feats.times[i + above[-1]] + FRAME_MS / 1000.0)
    return lo, hi


def sibilant_regions(samples: np.ndarray, sr: float, feats: Features, duration: float,
                     words: list[dict] | None, language: str) -> list[tuple[float, float]]:
    noise_floor_db = float(np.percentile(feats.energy_db, 5))
    # ZCR/HF thresholds set to catch "ch" (centred lower, ~2.5-6 kHz) as readily as "s"
    # (~5-9 kHz) — D2 names 0.25/+6 dB as the working figures, tuned down after they missed a
    # synthetic "ch" outright (@see plan_separateur_voix.md, "Écarts").
    candidate = (~feats.voiced) \
        & (feats.hf_lf_ratio_db > 4.0) \
        & (feats.zcr > 0.12) \
        & (feats.energy_db > noise_floor_db + 10.0)

    if words:
        out: list[tuple[float, float]] = []
        for wd in words:
            k = graphemes_for(wd["word"], language)
            if k <= 0:
                continue
            lo_w = max(0.0, wd["start"] - WORD_SEARCH_MARGIN_S)
            hi_w = min(duration, wd["end"] + WORD_SEARCH_MARGIN_S)
            in_word = candidate & (feats.times >= lo_w) & (feats.times < hi_w)
            runs = _frame_runs(in_word, feats.hop_s, FILL_HOLE_MS / 1000.0, MIN_SIBILANT_MS / 1000.0)
            scored = []
            for i, j in runs:
                mean_e = float(np.mean(feats.hf_lf_ratio_db[i:j]))
                scored.append((mean_e, i, j))
            scored.sort(key=lambda t: -t[0])
            for _, i, j in scored[:k]:
                out.append(_refine_hf_bounds(feats, i, j))
        out.sort()
        return out
    else:
        runs = _frame_runs(candidate, feats.hop_s, FILL_HOLE_MS / 1000.0, MIN_SIBILANT_MS / 1000.0)
        return [_refine_hf_bounds(feats, i, j) for i, j in runs]


# MARK: - Segmentation

def segment(samples: np.ndarray, sr: float, duration: float,
           words: list[dict] | None = None, language: str = "fr") -> list[tuple[float, float, str]]:
    """The full pipeline: features → breaths → sibilants → a label per instant → pieces covering
    `[0, duration]` exactly, jointive, none shorter than `MIN_PIECE_MS` (folded into a neighbour).
    Labels: "voice" (default), "breath", "sibilant"."""
    feats = compute_features(samples, sr)
    breaths = breath_regions(samples, sr, feats, duration, words)
    sibilants = sibilant_regions(samples, sr, feats, duration, words, language)

    regions = sorted([(lo, hi, "breath") for lo, hi in breaths]
                     + [(lo, hi, "sibilant") for lo, hi in sibilants])
    # Non-overlapping: a later region's start is clipped past an earlier one's end.
    cleaned: list[tuple[float, float, str]] = []
    for lo, hi, label in regions:
        if cleaned and lo < cleaned[-1][1]:
            lo = cleaned[-1][1]
        if hi > lo:
            cleaned.append((lo, hi, label))

    pieces: list[list] = []
    cursor = 0.0
    for lo, hi, label in cleaned:
        if lo > cursor:
            pieces.append([cursor, lo, "voice"])
        pieces.append([lo, hi, label])
        cursor = hi
    if duration > cursor:
        pieces.append([cursor, duration, "voice"])
    if not pieces:
        pieces = [[0.0, duration, "voice"]]

    # Fold pieces shorter than MIN_PIECE_MS into a neighbour (the previous one when there is one,
    # the next one for a piece born first).
    min_len = MIN_PIECE_MS / 1000.0
    changed = True
    while changed and len(pieces) > 1:
        changed = False
        for idx, p in enumerate(pieces):
            if p[1] - p[0] < min_len:
                if idx > 0:
                    pieces[idx - 1][1] = p[1]
                else:
                    pieces[idx + 1][0] = p[0]
                del pieces[idx]
                changed = True
                break

    return [(p[0], p[1], p[2]) for p in pieces]


LANE_FOR_LABEL = {"voice": 0, "breath": 1, "sibilant": 2}
LANE_NAMES = {"fr": ["Voix", "Respirations", "SS/CH"],
             "en": ["Voice", "Breaths", "SS/CH"],
             "es": ["Voz", "Respiraciones", "SS/CH"]}


def cuts_and_lanes(pieces: list[tuple[float, float, str]]) -> tuple[list[float], list[int]]:
    """`pieces` (as `segment` returns them) → `(cuts, lanes)` for `object.explode`: the interior
    boundaries, and each piece's sub-lane."""
    cuts = [p[0] for p in pieces[1:]]
    lanes = [LANE_FOR_LABEL[p[2]] for p in pieces]
    return cuts, lanes

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

VOICING_THRESHOLD = 0.45     # the historical fixed cut; `BreathParams.unvoiced` makes it adjustable

# Bumped whenever `compute_features` changes what it returns, so a cache written by an older
# version is not read back as if it were current (@see separateur_voix.py's feature cache).
FEATURES_VERSION = 2

# Frames are transformed in chunks: 10 minutes at 48 kHz is 60 000 frames of 1 200 samples, and
# a strided view over them costs nothing while the windowed COPY of all of them at once would be
# 576 MB.
_CHUNK_FRAMES = 1024


@dataclass
class Features:
    times: np.ndarray          # frame START times, seconds, relative to the portion
    energy_db: np.ndarray
    hf_lf_ratio_db: np.ndarray  # 10*log10(E[4-10kHz] / E[80-1000Hz])
    e_mid_db: np.ndarray        # 10*log10(E[1-4kHz])
    zcr: np.ndarray
    flatness: np.ndarray
    voicing: np.ndarray         # the normalised autocorrelation peak itself, 0…1 — a SCORE, so
                                # that the cut between voiced and not can be moved by a hand
    e_hf_db: np.ndarray          # 10*log10(E[4-10kHz]) — the sibilant refinement reads THIS, not the raw envelope
    hop_s: float

    @property
    def voiced(self) -> np.ndarray:
        """The historical boolean, at the historical threshold."""
        return self.voicing > VOICING_THRESHOLD


def _band_matrix(freqs: np.ndarray, lo: float, hi: float) -> np.ndarray:
    return ((freqs >= lo) & (freqs <= hi)).astype(np.float64)


def compute_features(samples: np.ndarray, sr: float) -> Features:
    """Per-frame features, vectorised: frames are a strided view (25 ms window, 10 ms hop), the
    spectrum one `rfft` per chunk, the bands are matrix products against 0/1 bin masks, and the
    voicing is an autocorrelation by FFT (`irfft(|rfft(x, 2N)|²)`, zero-padded to 2N so it is the
    LINEAR autocorrelation the lag loop used to compute one dot product at a time)."""
    frame_len = max(2, int(round(FRAME_MS / 1000.0 * sr)))
    hop_len = max(1, int(round(HOP_MS / 1000.0 * sr)))
    n = len(samples)
    n_frames = max(0, 1 + (n - frame_len) // hop_len) if n >= frame_len else 0

    def empty():
        return np.zeros(n_frames)

    times = np.arange(n_frames) * hop_len / sr
    energy_db, hf_lf, e_mid, e_hf = empty(), empty(), empty(), empty()
    zcr, flatness, voicing = empty(), empty(), empty()
    if n_frames == 0:
        return Features(times=times, energy_db=energy_db, hf_lf_ratio_db=hf_lf, e_mid_db=e_mid,
                        zcr=zcr, flatness=flatness, voicing=voicing, e_hf_db=e_hf,
                        hop_s=hop_len / sr)

    samples = np.asarray(samples, dtype=np.float64)
    window = np.hanning(frame_len)
    freqs = np.fft.rfftfreq(frame_len, d=1.0 / sr)
    lf_band = _band_matrix(freqs, 80.0, 1000.0)
    hf_band = _band_matrix(freqs, 4000.0, 10000.0)
    mid_band = _band_matrix(freqs, 1000.0, 4000.0)
    flat_sel = (freqs >= 300.0) & (freqs <= 4000.0)

    lag_min = int(sr / 400.0)
    lag_max = min(int(sr / 70.0), frame_len - 1)
    fft_len = 2 * frame_len

    eps = 1e-12
    view = np.lib.stride_tricks.sliding_window_view(samples, frame_len)[::hop_len][:n_frames]
    for c0 in range(0, n_frames, _CHUNK_FRAMES):
        c1 = min(n_frames, c0 + _CHUNK_FRAMES)
        frames = view[c0:c1]

        energy_db[c0:c1] = 10.0 * np.log10(np.mean(frames ** 2, axis=1) + eps)

        spectrum = np.fft.rfft(frames * window, axis=1)
        mag2 = spectrum.real ** 2 + spectrum.imag ** 2
        e_lf_v = mag2 @ lf_band
        e_hf_v = mag2 @ hf_band
        hf_lf[c0:c1] = 10.0 * np.log10((e_hf_v + eps) / (e_lf_v + eps))
        e_hf[c0:c1] = 10.0 * np.log10(e_hf_v + eps)
        e_mid[c0:c1] = 10.0 * np.log10(mag2 @ mid_band + eps)

        signs = np.sign(frames)
        signs[signs == 0] = 1
        zcr[c0:c1] = np.mean(signs[:, 1:] != signs[:, :-1], axis=1)

        # Restricted to the band a breath actually occupies (300-4000 Hz): the full spectrum
        # would include the near-zero bins OUTSIDE a band-limited sound's own energy, and those
        # collapse a geometric mean to ~0 regardless of how flat the sound is WITHIN its band.
        band = mag2[:, flat_sel] + eps
        if band.shape[1]:
            gmean = np.exp(np.mean(np.log(band), axis=1))
            amean = np.mean(band, axis=1)
            flatness[c0:c1] = np.where(amean > 0, gmean / np.where(amean > 0, amean, 1.0), 0.0)

        # Voicing: the peak of the normalised autocorrelation over the 70-400 Hz lags — a filter
        # for a CANDIDATE, not a pitch tracker. Kept as a SCORE.
        if lag_max > lag_min:
            x = frames - frames.mean(axis=1, keepdims=True)
            spec = np.fft.rfft(x, n=fft_len, axis=1)
            r = np.fft.irfft(spec.real ** 2 + spec.imag ** 2, n=fft_len, axis=1)
            energy0 = r[:, 0]
            best = np.maximum(r[:, lag_min:lag_max + 1].max(axis=1), 0.0)
            voicing[c0:c1] = np.where(energy0 > 1e-12, best / np.where(energy0 > 1e-12, energy0, 1.0), 0.0)

    return Features(times=times, energy_db=energy_db, hf_lf_ratio_db=hf_lf, e_mid_db=e_mid,
                    zcr=zcr, flatness=flatness, voicing=voicing, e_hf_db=e_hf, hop_s=hop_len / sr)


# MARK: - Runs of frames matching a predicate

def _frame_runs(mask: np.ndarray, hop_s: float, fill_holes_s: float, min_len_s: float):
    """Contiguous [start, end) index runs of `True` in `mask`, holes of at most `fill_holes_s`
    bridged first, then filtered to at least `min_len_s` long. Vectorised: run boundaries come from
    a `diff` of the padded mask, never from a walk over the frames."""
    if mask.size == 0:
        return []
    m = np.asarray(mask, dtype=bool).copy()
    fill_frames = int(round(fill_holes_s / hop_s))
    if fill_frames > 0:
        # A hole is a run of False with True on BOTH sides (a mask starting or ending on False has
        # no such neighbour, so its edge run is never bridged).
        pad = np.concatenate(([True], m, [True])).astype(np.int8)
        d = np.diff(pad)
        starts = np.flatnonzero(d == -1)      # first False of a run
        ends = np.flatnonzero(d == 1)         # one past its last False
        sel = ((ends - starts) <= fill_frames) & (starts > 0) & (ends < len(m))
        if sel.any():
            delta = np.zeros(len(m) + 1, dtype=np.int64)
            np.add.at(delta, starts[sel], 1)
            np.add.at(delta, ends[sel], -1)
            m |= np.cumsum(delta)[:-1] > 0
    d = np.diff(np.concatenate(([0], m.astype(np.int8), [0])))
    starts = np.flatnonzero(d == 1)
    ends = np.flatnonzero(d == -1)
    keep = (ends - starts) * hop_s >= min_len_s
    return list(zip(starts[keep].tolist(), ends[keep].tolist()))


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

@dataclass
class BreathParams:
    """The nine criteria of a breath, each with its own on / off. The defaults are the figures the
    detector always used, so `breath_mask(…, BreathParams())` IS the historical `breath_regions`.
    A criterion switched OFF drops out of the conjunction (a `gap` off = no restriction to the
    spaces between words); `min_len`, `fill` and `end_margin` off mean 0."""
    gap: float = MIN_GAP_MS              # ms — a space between words at least this long
    unvoiced: float = VOICING_THRESHOLD   # voicing score below this
    above_floor: float = 6.0             # dB above the noise floor (5th percentile)
    below_speech: float = 10.0           # dB under the median of the voiced frames
    flatness: float = 0.08               # spectral flatness above this
    hf_lf: float = 6.0                   # dB, high / low band ratio below this
    min_len: float = MIN_BREATH_MS       # ms — the shortest run kept
    fill: float = FILL_HOLE_MS           # ms — a hole this short is bridged
    end_margin: float = BREATH_END_MARGIN_S * 1000.0   # ms — kept clear before the next word
    gap_on: bool = True
    unvoiced_on: bool = True
    above_floor_on: bool = True
    below_speech_on: bool = True
    flatness_on: bool = True
    hf_lf_on: bool = True
    min_len_on: bool = True
    fill_on: bool = True
    end_margin_on: bool = True

    @classmethod
    def from_values(cls, values: dict) -> "BreathParams":
        """From a panel's `values` ({'gap': 120, 'gap_on': True, …}); an absent key keeps its default."""
        p = cls()
        for name in cls.__dataclass_fields__:
            if name in values:
                setattr(p, name, type(getattr(p, name))(values[name]))
        return p


@dataclass
class BreathStats:
    median_speech_db: float
    noise_floor_db: float


def breath_stats(feats: Features, unvoiced: float = VOICING_THRESHOLD) -> BreathStats:
    """What the energy criteria are measured against. The median of the VOICED frames depends on
    where the voicing cut is, so it is recomputed per cut (a median of a few thousand numbers) —
    the floor does not, and is the same for every setting."""
    voiced_energy = feats.energy_db[feats.voicing > unvoiced]
    median_speech_db = float(np.median(voiced_energy)) if voiced_energy.size else float(np.median(feats.energy_db))
    noise_floor_db = float(np.percentile(feats.energy_db, 5))
    return BreathStats(median_speech_db, noise_floor_db)


def word_gaps(words: list[dict] | None, duration: float,
              min_gap_ms: float = MIN_GAP_MS) -> tuple[np.ndarray, np.ndarray] | None:
    """The spaces between words at least `min_gap_ms` long, as two arrays (starts, ends) — sorted
    and disjoint, which is what lets a frame be placed with ONE `searchsorted` instead of a test
    against every gap. None when there are no words (then nothing restricts where a breath can be)."""
    if not words:
        return None
    gaps = _gaps_from_words(words, duration, min_gap_ms)
    g0 = np.array([g[0] for g in gaps], dtype=np.float64)
    g1 = np.array([g[1] for g in gaps], dtype=np.float64)
    return g0, g1


def _gap_index(times: np.ndarray, gaps: tuple[np.ndarray, np.ndarray]) -> np.ndarray:
    """For each time, the index of the gap [g0, g1) that contains it, or -1."""
    g0, g1 = gaps
    if g0.size == 0:
        return np.full(times.shape, -1, dtype=np.int64)
    idx = np.searchsorted(g0, times, side="right") - 1
    inside = (idx >= 0) & (times < g1[np.clip(idx, 0, None)])
    return np.where(inside, idx, -1)


def breath_mask(feats: Features, stats: BreathStats, gaps: tuple[np.ndarray, np.ndarray] | None,
                params: BreathParams) -> list[tuple[float, float]]:
    """The breaths, as (start, end) seconds — PURE: features and stats in, regions out, nothing
    recomputed. It is what runs on every setting a hand moves, so it is all array arithmetic over
    the frames (a few milliseconds for ten minutes of audio).

    `stats` must have been made for `params.unvoiced` (@see breath_stats), and `gaps` for
    `params.gap` (@see word_gaps)."""
    p = params
    candidate = np.ones(feats.times.shape, dtype=bool)
    if p.unvoiced_on:
        candidate &= feats.voicing <= p.unvoiced
    if p.above_floor_on:
        candidate &= feats.energy_db > stats.noise_floor_db + p.above_floor
    if p.below_speech_on:
        candidate &= feats.energy_db < stats.median_speech_db - p.below_speech
    if p.flatness_on:
        candidate &= feats.flatness > p.flatness
    if p.hf_lf_on:
        candidate &= feats.hf_lf_ratio_db < p.hf_lf

    use_gaps = gaps is not None and p.gap_on
    if use_gaps:
        candidate &= _gap_index(feats.times, gaps) >= 0

    runs = _frame_runs(candidate, feats.hop_s,
                       (p.fill / 1000.0) if p.fill_on else 0.0,
                       (p.min_len / 1000.0) if p.min_len_on else 0.0)
    if not runs:
        return []
    starts = np.array([r[0] for r in runs])
    ends = np.array([r[1] for r in runs])
    lo = feats.times[starts]
    hi = feats.times[ends - 1] + FRAME_MS / 1000.0
    if use_gaps and p.end_margin_on:
        # The margin belongs to whichever gap the run STARTED in.
        gi = _gap_index(lo, gaps)
        capped = gi >= 0
        hi = np.where(capped, np.minimum(hi, gaps[1][np.clip(gi, 0, None)] - p.end_margin / 1000.0), hi)
    min_len = (p.min_len / 1000.0) if p.min_len_on else 0.0
    keep = (hi - lo) >= max(min_len, 1e-9)
    return list(zip(lo[keep].tolist(), hi[keep].tolist()))


def breath_regions(samples: np.ndarray, sr: float, feats: Features, duration: float,
                   words: list[dict] | None) -> list[tuple[float, float]]:
    """The historical entry point: the defaults, stats and gaps computed on the spot."""
    p = BreathParams()
    return breath_mask(feats, breath_stats(feats, p.unvoiced), word_gaps(words, duration, p.gap), p)


def _gaps_from_words(words, duration, min_gap_ms=MIN_GAP_MS):
    gaps = []
    prev_end = 0.0
    for wd in sorted(words, key=lambda w: w["start"]):
        if wd["start"] - prev_end >= min_gap_ms / 1000.0:
            gaps.append((prev_end, wd["start"]))
        prev_end = max(prev_end, wd["end"])
    if duration - prev_end >= min_gap_ms / 1000.0:
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

def _pieces_from_regions(regions: list[tuple[float, float, str]],
                        duration: float) -> list[tuple[float, float, str]]:
    """Labelled regions → pieces covering `[0, duration]` exactly, jointive, none shorter than
    `MIN_PIECE_MS` (folded into a neighbour). Everything outside a region is "voice"."""
    regions = sorted(regions)
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


def segment(samples: np.ndarray, sr: float, duration: float,
           words: list[dict] | None = None, language: str = "fr") -> list[tuple[float, float, str]]:
    """The full pipeline: features → breaths → sibilants → a label per instant → pieces covering
    `[0, duration]` exactly, jointive, none shorter than `MIN_PIECE_MS` (folded into a neighbour).
    Labels: "voice" (default), "breath", "sibilant"."""
    feats = compute_features(samples, sr)
    breaths = breath_regions(samples, sr, feats, duration, words)
    sibilants = sibilant_regions(samples, sr, feats, duration, words, language)
    return _pieces_from_regions([(lo, hi, "breath") for lo, hi in breaths]
                                + [(lo, hi, "sibilant") for lo, hi in sibilants], duration)


def segment_breaths(duration: float, regions: list[tuple[float, float]]) -> list[tuple[float, float, str]]:
    """Breath regions only → the two-label pieces (voice / breath) an evaluation lays out on two
    sub-lanes. Same folding rule as `segment` (no piece under `MIN_PIECE_MS`)."""
    return _pieces_from_regions([(lo, hi, "breath") for lo, hi in regions], duration)


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

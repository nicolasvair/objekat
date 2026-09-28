#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Standalone test of `detect.py` on a SYNTHETIC signal — no Whisper, no socket
(@see plan_separateur_voix.md, T1). Run with the venv's own python3:

    python3 test_detect.py
"""

import sys

import numpy as np

import detect

SR = 48000
DURATION = 3.0


def make_signal():
    """3 s @ 48 kHz:
      • "vowels" everywhere by default — harmonics of 140 Hz, slowly amplitude-modulated, loud;
      • a 250 ms breath at [1.20, 1.45] — pink-ish noise band-passed 300-3000 Hz, -30 dB under
        the vowels, with the vowel silenced under it (a real breath falls in a gap between words);
      • two "s" of 120 ms at [0.40, 0.52] and [2.10, 2.22] — highpass noise 5-9 kHz;
      • one "ch" of 100 ms at [1.80, 1.90] — bandpass noise 2.5-6 kHz.
    A voiced "vowel" floor plays everywhere else, INCLUDING under the s/ch (as it would around a
    consonant in running speech) but NOT under the breath (silence, as in a real gap)."""
    t = np.arange(int(SR * DURATION)) / SR
    rng = np.random.default_rng(0)

    # Vowels: 140 Hz + harmonics, slow tremolo, moderate level.
    vowel = np.zeros_like(t)
    for k in range(1, 6):
        vowel += (1.0 / k) * np.sin(2 * np.pi * 140 * k * t)
    vowel *= 0.25 * (1.0 + 0.1 * np.sin(2 * np.pi * 3 * t))
    vowel /= np.max(np.abs(vowel))
    vowel *= 0.3
    # A real recording starts and ends in silence — a HARD gate, not a ramp: a ramp long enough
    # to matter (> one 25 ms frame) never gives a single frame that is background alone, which is
    # exactly what the detector's own noise-floor estimate (a low percentile of the frame
    # energies) needs to measure something TRUE. Without it, the only quiet stretch in the whole
    # file is the breath itself.
    edge_n = int(round(0.15 * SR))
    vowel[:edge_n] = 0.0
    vowel[-edge_n:] = 0.0

    # Room tone: a low, broadband noise floor everywhere — kept under EVERY event below (a
    # breath included), so the file's true quietest frames stay the head/tail silence, never an
    # event that is supposed to stand out ABOVE the room.
    background = 0.3 * (10 ** (-55 / 20)) * rng.standard_normal(len(t))
    sig = vowel + background

    def fades(n, edge=0.03):
        w = np.ones(n)
        e = max(1, int(n * edge))
        w[:e] = np.linspace(0, 1, e)
        w[-e:] = np.linspace(1, 0, e)
        return w

    def band_noise(n, lo, hi):
        noise = rng.standard_normal(n)
        spec = np.fft.rfft(noise)
        freqs = np.fft.rfftfreq(n, 1 / SR)
        spec[(freqs < lo) | (freqs > hi)] = 0
        out = np.fft.irfft(spec, n)
        return out / (np.max(np.abs(out)) + 1e-9)

    def place(start, dur, amp_signal, silence_vowel=False):
        i0 = int(round(start * SR))
        i1 = i0 + len(amp_signal)
        w = fades(len(amp_signal))
        if silence_vowel:
            sig[i0:i1] = background[i0:i1] + amp_signal * w
        else:
            sig[i0:i1] = background[i0:i1] + vowel[i0:i1] * (1 - w * 0.9) + amp_signal * w

    # Breath: -22 dB relative to the vowel's own peak (well above the -55 dB room, well under the
    # vowel), vowel silenced under it.
    breath = band_noise(int(round(0.25 * SR)), 300, 3000)
    breath *= 0.3 * (10 ** (-22 / 20))
    place(1.20, 0.25, breath, silence_vowel=True)

    # Two "s": highpass 5-9 kHz, at a level comparable to the vowel.
    for start in (0.40, 2.10):
        s = band_noise(int(round(0.12 * SR)), 5000, 9000)
        s *= 0.28
        place(start, 0.12, s, silence_vowel=False)

    # One "ch": bandpass 2.5-6 kHz.
    ch = band_noise(int(round(0.10 * SR)), 2500, 6000)
    ch *= 0.28
    place(1.80, 0.10, ch, silence_vowel=False)

    return sig.astype(np.float64)


TRUTH = [
    (0.40, 0.52, "sibilant"),
    (1.20, 1.45, "breath"),
    (1.80, 1.90, "sibilant"),
    (2.10, 2.22, "sibilant"),
]

# Fake Whisper word timestamps (seconds, relative to the portion — the same reference as the
# signal): a gap around the breath, an "s"-word wrapping the first "s", a "ch"-word wrapping the
# "ch", an "s"-word wrapping the second "s".
WORDS = [
    {"word": "la",       "start": 0.05, "end": 0.35},
    {"word": "salle",    "start": 0.38, "end": 0.65},   # wraps the first "s" [0.40, 0.52]
    {"word": "est",      "start": 0.70, "end": 0.95},
    # gap 0.95 -> 1.60 (>= 120 ms): the breath at [1.20, 1.45] falls inside it
    {"word": "grande",   "start": 1.60, "end": 1.78},
    {"word": "chaude",   "start": 1.78, "end": 2.05},   # wraps the "ch" [1.80, 1.90]
    {"word": "assise",   "start": 2.05, "end": 2.35},   # wraps the second "s" [2.10, 2.22]
    {"word": "ici",      "start": 2.40, "end": 2.70},
]


def check(pieces, tol, label):
    ok = True
    detected = [(lo, hi, lab) for lo, hi, lab in pieces if lab != "voice"]
    if len(detected) != len(TRUTH):
        print(f"[{label}] FAIL — {len(detected)} non-voice region(s) detected, {len(TRUTH)} expected:")
        for r in detected:
            print("   ", r)
        return False
    for (lo, hi, lab), (tlo, thi, tlab) in zip(detected, TRUTH):
        if lab != tlab:
            print(f"[{label}] FAIL — {(lo, hi)} labelled {lab!r}, expected {tlab!r}")
            ok = False
            continue
        if abs(lo - tlo) > tol or abs(hi - thi) > tol:
            print(f"[{label}] FAIL — {lab} at [{lo:.3f},{hi:.3f}], "
                 f"truth [{tlo:.3f},{thi:.3f}], tolerance {tol*1000:.0f} ms")
            ok = False
    # No false positive inside the vowel-only stretches.
    vowel_windows = [(0.0, 0.35), (0.65, 1.15), (1.50, 1.75), (2.30, 3.0)]
    for lo, hi, lab in pieces:
        if lab == "voice":
            continue
        for vlo, vhi in vowel_windows:
            if lo >= vlo and hi <= vhi:
                print(f"[{label}] FAIL — false positive {lab} at [{lo:.3f},{hi:.3f}] inside a vowel-only span")
                ok = False
    # Jointive coverage, strictly increasing cuts, no piece under 20 ms.
    if abs(pieces[0][0]) > 1e-9 or abs(pieces[-1][1] - DURATION) > 1e-6:
        print(f"[{label}] FAIL — coverage is not exactly [0, {DURATION}]")
        ok = False
    for a, b in zip(pieces, pieces[1:]):
        if abs(a[1] - b[0]) > 1e-9:
            print(f"[{label}] FAIL — a gap/overlap between {a} and {b}")
            ok = False
        if b[0] - a[0] <= 0:
            print(f"[{label}] FAIL — cuts not strictly increasing at {a}/{b}")
            ok = False
    for lo, hi, lab in pieces:
        if hi - lo < 0.020 - 1e-9:
            print(f"[{label}] FAIL — piece under 20 ms: {(lo, hi, lab)}")
            ok = False
    if ok:
        print(f"[{label}] OK — {len(detected)} region(s), {len(pieces)} piece(s)")
    return ok


def main():
    sig = make_signal()

    ok = True
    pieces_asr = detect.segment(sig, SR, DURATION, words=WORDS, language="fr")
    ok &= check(pieces_asr, tol=0.015, label="with Whisper words (±15 ms)")

    pieces_no_asr = detect.segment(sig, SR, DURATION, words=None, language="fr")
    ok &= check(pieces_no_asr, tol=0.025, label="--no-asr (±25 ms)")

    cuts, lanes = detect.cuts_and_lanes(pieces_asr)
    if len(lanes) != len(cuts) + 1:
        print("FAIL — lanes/cuts size mismatch")
        ok = False
    elif sorted(cuts) != cuts or len(set(cuts)) != len(cuts):
        print("FAIL — cuts not strictly increasing")
        ok = False
    else:
        print(f"cuts_and_lanes OK — {len(cuts)} cuts, lanes {lanes}")

    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

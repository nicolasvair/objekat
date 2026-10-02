#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Measuring what a resampler does to a signal — the analysis half of `scenario_resample_quality.py`.

Nothing here talks to the app. It makes the FIXTURES (float32 WAVs: a 1 kHz, a 10 kHz and a 19 kHz sine
at -6 dBFS, and a band-limited noise, each at 44.1 / 48 / 96 kHz), and it reads back the RENDERS (24-bit
WAVs — re-read as 24 bits: as int16 they look like time stretched by 1.5, see CLAUDE.md) and turns them
into numbers:

  TONES (a sine whose pitch is exactly known)
    • sinad_db     — SINAD = THD+N, the fundamental's RMS against the RMS of everything else, after a
                     least-squares fit of ONE sine (amplitude, phase, DC and a refined frequency) over
                     the analysis window. Whatever the resampler adds — harmonics, aliases, noise,
                     modulation, steps — lands in the residual.
    • cents        — the pitch actually heard against f0 × speed, in cents. The varispeed contract:
                     speed 1.07 raises the pitch by 1.07, not by approximately that.
    • clicks       — DISCONTINUITIES. The residual of the fit is impulsive where the signal jumps (a
                     resampler recalibrated on the wrong position leaves a step, a click), and
                     Gaussian-ish where it merely adds noise. A click is a residual sample beyond
                     max(8 × robust sigma, -100 dBc), clusters closer than 32 samples counting as one.
                     `click_period` is the median spacing of clusters in samples: 512 or a multiple of
                     the block size is the signature of a defect that strikes ONCE PER BLOCK.
    • resid_peak_dbc — the largest residual sample against the fundamental's amplitude.

  NOISE (a signal with no periodicity, band-limited to 16 kHz so that every case is in every converter's
  passband: sinc medium keeps 90 % of Nyquist, i.e. 19.8 kHz at 44.1)
    • lag          — the render's delay against the IDEAL output, by cross-correlation (+ parabolic
                     refinement), in samples at the output rate. The ideal is y[n] = x(v · n / fs_out),
                     read off the source with a long Kaiser-windowed sinc (~-120 dB): an offline
                     reference that has no block, no ratio rounding and no state.
    • snr_db       — after removing that lag (a fractional shift in the Fourier domain) and the best gain,
                     the energy of the ideal against the energy of what is left: how close the render is
                     to the exact answer, passband droop and everything else included.

All of it is read between two instants well inside the render (0.5 s → 7.5 s) so that the file's edges and
the engine's start-up play no part.

Used as a command, it prints the matrix a scenario recorded, or compares two of them:

    ./analyze_resample.py results_lagrange.json
    ./analyze_resample.py --compare results_lagrange.json results_sinc.json
"""

import sys, os, json, wave, math

import numpy as np

RATES = (44100, 48000, 96000)
SPEEDS = (1.0, 1.07, 0.5)
TONE_FREQS = (1000.0, 10000.0)
EDGE_TONE = 19000.0            # only at speed 1: 90 % of 44.1 kHz's Nyquist is 19.8 kHz
FIXTURE_SECONDS = 10.0
AMPLITUDE = 0.5                # -6 dBFS
NOISE_BAND = (100.0, 16000.0)
WINDOW = (0.5, 7.5)            # seconds of output analysed


# --------------------------------------------------------------------------------------------- fixtures
def _write_wav_f32(path, data, rate):
    """A stereo float32 WAV, written by hand (a `wave` module that does not know floats)."""
    import struct
    data = np.asarray(data, dtype="<f4")
    stereo = np.stack([data, data], axis=1).reshape(-1)
    payload = stereo.tobytes()
    with open(path, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", 36 + len(payload)) + b"WAVE")
        f.write(b"fmt " + struct.pack("<IHHIIHH", 16, 3, 2, rate, rate * 8, 8, 32))
        f.write(b"data" + struct.pack("<I", len(payload)) + payload)


def tone(freq, rate, seconds=FIXTURE_SECONDS, amp=AMPLITUDE):
    # Phase computed from an integer sample index in double precision: no accumulated drift.
    n = np.arange(int(round(seconds * rate)), dtype=np.float64)
    return amp * np.sin(2 * np.pi * freq * n / rate)


def band_noise(rate, seconds=FIXTURE_SECONDS, seed=1, band=NOISE_BAND, peak=AMPLITUDE):
    """White gaussian noise brick-wall filtered in the Fourier domain to `band`, scaled to `peak`."""
    rng = np.random.default_rng(seed)
    n = int(round(seconds * rate))
    spec = np.fft.rfft(rng.standard_normal(n))
    freqs = np.fft.rfftfreq(n, 1.0 / rate)
    spec[(freqs < band[0]) | (freqs > band[1])] = 0.0
    x = np.fft.irfft(spec, n)
    return x * (peak / np.max(np.abs(x)))


def fixture_name(kind, rate, freq=None):
    return "tone_%d_%d.wav" % (int(freq), rate) if kind == "tone" else "noise_%d.wav" % rate


def make_fixtures(directory, seconds=FIXTURE_SECONDS):
    """Writes every fixture into `directory` and returns {(kind, rate, freq): path}."""
    os.makedirs(directory, exist_ok=True)
    out = {}
    for rate in RATES:
        for f in TONE_FREQS + (EDGE_TONE,):
            p = os.path.join(directory, fixture_name("tone", rate, f))
            _write_wav_f32(p, tone(f, rate, seconds), rate)
            out[("tone", rate, f)] = p
        p = os.path.join(directory, fixture_name("noise", rate))
        _write_wav_f32(p, band_noise(rate, seconds, seed=rate), rate)
        out[("noise", rate, None)] = p
    return out


def read_wav_f32_left(path):
    """Left channel of a float32 or 16/24/32-bit PCM stereo WAV, as float64 in [-1, 1], and its rate."""
    with open(path, "rb") as f:
        raw = f.read()
    assert raw[:4] == b"RIFF" and raw[8:12] == b"WAVE", path
    pos, fmt, data = 12, None, None
    while pos + 8 <= len(raw):
        cid, size = raw[pos:pos + 4], int.from_bytes(raw[pos + 4:pos + 8], "little")
        body = raw[pos + 8:pos + 8 + size]
        if cid == b"fmt ":
            tag, nch, rate, _, _, bits = (int.from_bytes(body[0:2], "little"), int.from_bytes(body[2:4], "little"),
                                          int.from_bytes(body[4:8], "little"), 0, 0, int.from_bytes(body[14:16], "little"))
            if tag == 0xFFFE:   # WAVE_FORMAT_EXTENSIBLE: the real tag opens the sub-format GUID
                tag = int.from_bytes(body[24:26], "little")
            fmt = (tag, nch, rate, bits)
        elif cid == b"data":
            data = body if size >= len(body) else body[:size]
            break
        pos += 8 + size + (size & 1)
    tag, nch, rate, bits = fmt
    if tag == 3 and bits == 32:
        x = np.frombuffer(data[:len(data) // 4 * 4], dtype="<f4").astype(np.float64)
    elif tag == 1 and bits == 24:
        b = np.frombuffer(data[:len(data) // 3 * 3], dtype=np.uint8).reshape(-1, 3).astype(np.int32)
        v = b[:, 0] | (b[:, 1] << 8) | (b[:, 2] << 16)
        x = np.where(v & 0x800000, v - (1 << 24), v).astype(np.float64) / 8388608.0
    elif tag == 1 and bits == 16:
        x = np.frombuffer(data[:len(data) // 2 * 2], dtype="<i2").astype(np.float64) / 32768.0
    elif tag == 1 and bits == 32:
        x = np.frombuffer(data[:len(data) // 4 * 4], dtype="<i4").astype(np.float64) / 2147483648.0
    else:
        raise ValueError("unsupported WAV format %r in %s" % (fmt, path))
    return x.reshape(-1, nch)[:, 0].copy(), rate


# --------------------------------------------------------------------------------------------- tones
def _fit_sine(x, t, f):
    """Linear least squares at a FIXED frequency: x ~ a cos + b sin + c. Returns (coeffs, residual)."""
    w = 2 * np.pi * f * t
    m = np.stack([np.cos(w), np.sin(w), np.ones_like(w)], axis=1)
    coeffs, *_ = np.linalg.lstsq(m, x, rcond=None)
    return coeffs, x - m @ coeffs


def _refine_frequency(x, t, f_guess, span):
    """Golden-section search of the frequency minimising the fit's residual energy."""
    lo, hi = f_guess - span, f_guess + span
    g = (math.sqrt(5) - 1) / 2
    a, b = hi - g * (hi - lo), lo + g * (hi - lo)
    fa = float(np.sum(_fit_sine(x, t, a)[1] ** 2))
    fb = float(np.sum(_fit_sine(x, t, b)[1] ** 2))
    for _ in range(40):
        if fa < fb:
            hi, b, fb = b, a, fa
            a = hi - g * (hi - lo)
            fa = float(np.sum(_fit_sine(x, t, a)[1] ** 2))
        else:
            lo, a, fa = a, b, fb
            b = lo + g * (hi - lo)
            fb = float(np.sum(_fit_sine(x, t, b)[1] ** 2))
    return (lo + hi) / 2


def analyze_tone(x, rate, f_expected, window=WINDOW):
    a, b = int(window[0] * rate), min(int(window[1] * rate), len(x))
    seg = x[a:b] - np.mean(x[a:b])
    n = len(seg)
    t = np.arange(n, dtype=np.float64) / rate
    spec = np.abs(np.fft.rfft(seg * np.blackman(n)))
    k = int(np.argmax(spec))
    f_fft = k * rate / n
    # The search is bracketed by the FFT's own resolution: never wider than a few bins.
    f_meas = _refine_frequency(seg, t, f_fft, span=4.0 * rate / n)
    (ca, cb, cc), r = _fit_sine(seg, t, f_meas)
    amp = math.hypot(ca, cb)
    rms_sig = amp / math.sqrt(2)
    rms_res = float(np.sqrt(np.mean(r ** 2)))
    sinad = 20 * math.log10(rms_sig / max(rms_res, 1e-12))

    # Discontinuities: impulsive residual. Robust sigma (MAD), absolute floor -100 dBc.
    sigma = 1.4826 * float(np.median(np.abs(r - np.median(r))))
    thr = max(8.0 * sigma, amp * 1e-5)
    hot = np.flatnonzero(np.abs(r) > thr)
    clusters = []
    for i in hot:
        if clusters and i - clusters[-1][-1] < 32:
            clusters[-1].append(int(i))
        else:
            clusters.append([int(i)])
    starts = np.array([c[0] for c in clusters], dtype=np.float64)
    period = float(np.median(np.diff(starts))) if len(starts) >= 3 else None

    # Timing jumps. A resampler that re-aims its source on a rounded position does not leave an
    # impulse, it leaves a STEP IN PHASE (a sine that carries on a fraction of a sample early or late),
    # which the residual shows as a burst of sinusoid, not as a spike. The analytic signal's phase,
    # detrended, turns it into a step; its increments are read in samples of TIME (phase / 2 pi f) so
    # that a threshold means the same at 1 kHz and at 10 kHz.
    from scipy.signal import hilbert
    ph = np.unwrap(np.angle(hilbert(seg)))
    ph = ph - np.polyval(np.polyfit(np.arange(n), ph, 1), np.arange(n))
    edge = max(int(0.05 * rate), 64)
    dt = np.diff(ph[edge:-edge]) / (2 * np.pi * f_meas) * rate
    gap = int(2 * rate / f_meas) + 1
    jump_clusters = []
    for i in np.flatnonzero(np.abs(dt) > 0.02):
        if jump_clusters and i - jump_clusters[-1][-1] < gap:
            jump_clusters[-1].append(int(i))
        else:
            jump_clusters.append([int(i)])
    jump_sizes = [abs(float(np.sum(dt[c[0]:c[-1] + 1]))) for c in jump_clusters]
    jstarts = np.array([c[0] for c in jump_clusters], dtype=np.float64)
    jump_period = float(np.median(np.diff(jstarts))) if len(jstarts) >= 3 else None
    return {
        "jumps": len(jump_clusters),
        "jump_max": max(jump_sizes) if jump_sizes else 0.0,
        "jump_period": jump_period,
        "phase_noise_samples": float(np.std(dt)),
        "f_meas": f_meas,
        "cents": 1200 * math.log2(f_meas / f_expected),
        "amp_dbfs": 20 * math.log10(amp),
        "sinad_db": sinad,
        "resid_peak_dbc": 20 * math.log10(max(float(np.max(np.abs(r))), 1e-12) / amp),
        "clicks": len(clusters),
        "click_period": period,
        "click_threshold_dbc": 20 * math.log10(thr / amp),
    }


# --------------------------------------------------------------------------------------------- noise
def _kaiser_i0(x):
    return np.i0(x)


def ideal_resample(x, fs_src, fs_out, speed, n_out, half=64, beta=12.0):
    """y[n] = x(speed * n / fs_out * fs_src): the source read at fractional positions with a long
    Kaiser-windowed sinc. Valid where the source has no content above ~0.85 of its own Nyquist."""
    pos_all = np.arange(n_out, dtype=np.float64) * (speed * fs_src / fs_out)
    ks = np.arange(-half + 1, half + 1)
    out = np.zeros(n_out)
    i0 = _kaiser_i0(beta)
    chunk = 8192
    for s in range(0, n_out, chunk):
        pos = pos_all[s:s + chunk]
        base = np.floor(pos).astype(np.int64)
        frac = pos - base
        idx = base[:, None] + ks[None, :]
        u = ks[None, :] - frac[:, None]                       # distance of each tap from the point
        w = np.sinc(u) * _kaiser_i0(beta * np.sqrt(np.clip(1.0 - (u / half) ** 2, 0.0, 1.0))) / i0
        valid = (idx >= 0) & (idx < len(x))
        out[s:s + chunk] = np.sum(np.where(valid, x[np.clip(idx, 0, len(x) - 1)], 0.0) * w, axis=1)
    return out


def _fractional_shift(x, delay):
    """x delayed by `delay` samples (fractional), by a phase ramp in the Fourier domain."""
    n = len(x)
    f = np.fft.rfftfreq(n)
    return np.fft.irfft(np.fft.rfft(x) * np.exp(-2j * np.pi * f * delay), n)


def analyze_noise(render, rate_out, source, rate_src, speed, window=WINDOW):
    a, b = int(window[0] * rate_out), min(int(window[1] * rate_out), len(render))
    ideal = ideal_resample(source, rate_src, rate_out, speed, b)
    r, i = render[a:b], ideal[a:b]
    n = len(r)
    nfft = 1 << (2 * n - 1).bit_length()
    cc = np.fft.irfft(np.fft.rfft(r, nfft) * np.conj(np.fft.rfft(i, nfft)), nfft)
    maxlag = 256
    lags = np.concatenate([np.arange(0, maxlag + 1), np.arange(-maxlag, 0)])
    vals = np.concatenate([cc[:maxlag + 1], cc[nfft - maxlag:]])
    j = int(np.argmax(vals))
    lag = int(lags[j])
    # Parabolic refinement through the neighbours (looked up in the circular correlation itself).
    y0, y1, y2 = cc[(lag - 1) % nfft], cc[lag % nfft], cc[(lag + 1) % nfft]
    den = (y0 - 2 * y1 + y2)
    frac = 0.5 * (y0 - y2) / den if den != 0 else 0.0
    lag_f = lag + frac
    aligned = _fractional_shift(i, lag_f)
    edge = 2048
    rr, ii = r[edge:-edge], aligned[edge:-edge]
    g = float(np.dot(rr, ii) / np.dot(ii, ii))
    err = rr - g * ii
    return {
        "lag": lag_f,
        "gain_db": 20 * math.log10(abs(g)) if g else None,
        "snr_db": 10 * math.log10(float(np.dot(g * ii, g * ii)) / max(float(np.dot(err, err)), 1e-30)),
    }


# --------------------------------------------------------------------------------------------- reports
def _key(r):
    return (r["kind"], r["freq"], r["src"], r["out"], r["speed"])


def format_table(results):
    rows = ["%-6s %6s %6s %6s %5s | %7s %7s %6s %7s %6s %6s %8s | %6s %7s" % (
        "kind", "f0", "src", "out", "speed", "SINAD", "cents", "jumps", "jmax", "jper", "clicks", "peak dBc",
        "lag", "SNR")]
    for r in sorted(results, key=_key):
        m = r.get("m") or {}
        if r["kind"] == "tone":
            rows.append("%-6s %6d %6d %6d %5.2f | %7.1f %7.2f %6d %7.3f %6s %6d %8.1f | %6s %7s" % (
                r["kind"], r["freq"], r["src"], r["out"], r["speed"], m["sinad_db"], m["cents"], m["jumps"],
                m["jump_max"], "-" if m["jump_period"] is None else "%.0f" % m["jump_period"], m["clicks"],
                m["resid_peak_dbc"], "", ""))
        else:
            rows.append("%-6s %6s %6d %6d %5.2f | %7s %7s %6s %7s %6s %6s %8s | %6.2f %7.1f" % (
                r["kind"], "-", r["src"], r["out"], r["speed"], "", "", "", "", "", "", "", m["lag"], m["snr_db"]))
    return "\n".join(rows)


def format_compare(a, b, la="A", lb="B"):
    ia = {_key(r): r for r in a}
    rows = ["%-6s %6s %6s %6s %5s | SINAD %s -> %s | jumps %s -> %s (max, samples) | SNR vs ideal, lag" % (
        "kind", "f0", "src", "out", "speed", la, lb, la, lb)]
    for r in sorted(b, key=_key):
        o = ia.get(_key(r))
        if not o:
            continue
        ma, mb = o["m"], r["m"]
        if r["kind"] == "tone":
            rows.append("%-6s %6d %6d %6d %5.2f | %6.1f -> %6.1f dB | %4d -> %4d (%.3f -> %.3f)" % (
                r["kind"], r["freq"], r["src"], r["out"], r["speed"], ma["sinad_db"], mb["sinad_db"],
                ma["jumps"], mb["jumps"], ma["jump_max"], mb["jump_max"]))
        else:
            rows.append("%-6s %6s %6d %6d %5.2f | SNR %6.1f -> %6.1f dB (lag %.2f -> %.2f)" % (
                r["kind"], "-", r["src"], r["out"], r["speed"], ma["snr_db"], mb["snr_db"], ma["lag"], mb["lag"]))
    return "\n".join(rows)


if __name__ == "__main__":
    args = sys.argv[1:]
    if len(args) == 3 and args[0] == "--compare":
        da, db = json.load(open(args[1])), json.load(open(args[2]))
        print(format_compare(da["results"], db["results"], da.get("label", "A"), db.get("label", "B")))
    elif len(args) == 1:
        d = json.load(open(args[0]))
        print("label:", d.get("label"), "  mode:", d.get("mode"))
        print(format_table(d["results"]))
    else:
        print(__doc__)
        sys.exit(2)

"""STFT / ISTFT with a time-frequency gain, streamed in blocks (numpy only).

Definitions (plan 3.4)
- Periodic Hann window  w[n] = 0.5 - 0.5 cos(2 pi n / N).
- Hop  H = floor(N / k + 0.5).
- Frames are centred: frame j covers [jH - N/2, jH + N/2), J = ceil(L / H) + 1 frames, zero padded.
- Analysis  rfft(w * seg).  Synthesis  y += w * irfft(M * X),  wsum += w^2,  out = y / wsum
  wherever wsum > 1e-12, cropped to [0, L).
- Arithmetic is float64 whatever the storage; `out_dtype` only chooses the type of the result.
- One mask serves every channel (linked).
"""
import math

import numpy as np
from numpy.lib.stride_tricks import sliding_window_view

WSUM_EPS = 1e-12


def hop_for(n, k):
    """Hop in samples for FFT size n and overlap factor k: floor(n/k + 0.5)."""
    return int(math.floor(n / float(k) + 0.5))


def hann(n):
    """Periodic Hann window of length n (float64)."""
    i = np.arange(n, dtype=np.float64)
    return 0.5 - 0.5 * np.cos(2.0 * np.pi * i / n)


def frame_count(length, hop):
    """J = ceil(L / H) + 1 centred frames."""
    return -(-int(length) // int(hop)) + 1


def _check(n, k):
    if n < 2 or n % 2:
        raise ValueError("FFT size must be even")
    h = hop_for(n, k)
    if h < 1:
        raise ValueError("hop would be zero")
    return h


def _as_channels(x):
    """(L,) or (L, ch) -> (ch, L) view; and whether the input was 1-D."""
    x = np.asarray(x)
    if x.ndim == 1:
        return x[None, :], True
    if x.ndim != 2:
        raise ValueError("x must be (L,) or (L, channels)")
    return x.T, False


def _segments(xc, n, h, j0, j1):
    """Windowed-ready segments of frames j0..j1-1: float64 array (ch, nb, N), zero padded."""
    ch, length = xc.shape
    nb = j1 - j0
    s0 = j0 * h - n // 2
    span = (nb - 1) * h + n
    chunk = np.zeros((ch, span), dtype=np.float64)
    a, b = max(s0, 0), min(s0 + span, length)
    if b > a:
        chunk[:, a - s0:b - s0] = xc[:, a:b]
    win = sliding_window_view(chunk, n, axis=1)  # (ch, span - n + 1, N)
    return win[:, ::h, :][:, :nb, :]


def analysis_blocks(x, n, k, block=256):
    """Yield (j0, X) with X complex128 shaped (channels, nb, N/2 + 1), nb <= block."""
    h = _check(n, k)
    xc, _ = _as_channels(x)
    total = frame_count(xc.shape[1], h)
    w = hann(n)
    for j0 in range(0, total, block):
        j1 = min(j0 + block, total)
        yield j0, np.fft.rfft(_segments(xc, n, h, j0, j1) * w, axis=2)


def process(x, sr, n, k, gain_block_fn, out_dtype=np.float32, block=256):
    """Apply a time-frequency gain to x.

    x: (L,) or (L, channels). sr is carried for the caller's convenience (the mask grid is the
    caller's business) and is not used by the transform itself.
    gain_block_fn(j0, j1) -> LINEAR gain array shaped (j1 - j0, N/2 + 1) for frames j0..j1-1.
    Returns an array shaped like x, of dtype out_dtype.
    """
    h = _check(n, k)
    xc, one_d = _as_channels(x)
    ch, length = xc.shape
    total = frame_count(length, h)
    w = hann(n)
    w2 = w * w
    out = np.zeros((ch, length), dtype=out_dtype)
    carry_y = np.zeros((ch, 0))
    carry_w = np.zeros(0)
    for j0 in range(0, total, block):
        j1 = min(j0 + block, total)
        nb = j1 - j0
        s0 = j0 * h - n // 2
        span = (nb - 1) * h + n
        spec = np.fft.rfft(_segments(xc, n, h, j0, j1) * w, axis=2)
        m = np.asarray(gain_block_fn(j0, j1), dtype=np.float64)
        if m.shape != (nb, n // 2 + 1):
            raise ValueError("gain block has shape %r, expected %r" % (m.shape, (nb, n // 2 + 1)))
        frames = np.fft.irfft(spec * m[None, :, :], n=n, axis=2) * w
        ybuf = np.zeros((ch, span))
        wbuf = np.zeros(span)
        ybuf[:, :carry_y.shape[1]] = carry_y
        wbuf[:carry_w.shape[0]] = carry_w
        for i in range(nb):
            o = i * h
            ybuf[:, o:o + n] += frames[:, i, :]
            wbuf[o:o + n] += w2
        last = j1 == total
        done = span if last else nb * h
        a, b = max(s0, 0), min(s0 + done, length)
        if b > a:
            ys = ybuf[:, a - s0:b - s0]
            ws = wbuf[a - s0:b - s0]
            res = np.zeros_like(ys)
            ok = ws > WSUM_EPS
            res[:, ok] = ys[:, ok] / ws[ok]
            out[:, a:b] = res
        carry_y = ybuf[:, done:].copy()
        carry_w = wbuf[done:].copy()
    return out[0] if one_d else out.T.copy()

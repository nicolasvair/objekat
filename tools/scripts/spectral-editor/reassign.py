"""The FOCUSED display of the spectrogram: a time-frequency REASSIGNED spectrogram (revision 7). DISPLAY ONLY.

The processing (mask, STFT / ISTFT of `dsp.py`) is untouched and stays the plain FFT of the "FFT size" /
"Overlap" settings. This module only draws a sharper PICTURE of an audio signal, on the very same grid as
`image.build_db` (1024 log-spaced rows over [20 Hz, sr / 2], row 0 = the top; columns tiling [0, L / sr]), so
that the app, the readout, the rectangle and the brush neither know nor care which one is on screen.

Method (Auger & Flandrin 1995, "Improving the readability of time-frequency and time-scale
representations by the reassignment method"). A frame is analysed with three windows at once, h (periodic
Hann), t.h (the Hann times each sample's offset from the window centre, in samples) and dh/dt (the Hann's
derivative, in 1 / sample), zero-padded to the compute size `pad`. For every bin of the frame centred at t,
with X_w the transform with window w:

    group delay      t^ = t + Re( X_th . conj(X_h) ) / |X_h|^2        (where the energy REALLY is, in time)
    inst. frequency  f^ = f - Im( X_dh . conj(X_h) ) / (2 pi |X_h|^2) (and in frequency; f is the bin's, with the
                                                                       time unit being the sample)

and the energy |X_h|^2 of the bin is deposited at (t^, f^) instead of (t, f), with BILINEAR splatting onto the
four neighbouring cells. Bins below `threshold_db` under the loudest bin of the signal (read on the plain, not padded, transform:
up to 1.4 dB under the padded one) are not reassigned at all (their phase is noise: reassigning them only draws speckle). A cell is then shown in dB, 0 dB being a
full-scale sine, as in the normal picture; the two channels are drawn as the max of their own pictures.

What it can and cannot do (physics, not a bug):
- a tone, a click, a chirp become LINES, whatever the window: an isolated 440 Hz sine with a 512 window (bins of 94 Hz,
  a mainlobe of about 190 Hz either side in the normal picture) shows as a line within about 1 Hz;
- two tones closer than the window resolves (55 Hz and 61.7 Hz with a 512 window) are NOT claimed as two: the picture
  holds one blur centred between them, with no valley. Reassignment moves each frame's energy to where that frame says
  it is; it creates no information the window did not keep. Only a window longer than about 1 / 6.7 Hz resolves them
  (the normal picture at FFT 32768 does; 16384 barely);
- BELOW ABOUT TWO BINS OF THE WINDOW (190 Hz at 512, 47 Hz at 2048) the line degrades: the real signal's negative-frequency
  image falls inside the mainlobe and corrupts the phase slope, so a 55 Hz tone seen with a 512 window is smeared over
  20..140 Hz (it is clean with a 2048 window). A bass or a kick wants a long window;
- a line sits where a row boundary falls between two cells: its energy splits over the two rows (up to -3 dB each).

Cost: three FFTs of the compute size per frame, and one deposit per bin above the threshold. The number of frames is kept
to at most `MAX_FRAMES_PER_COLUMN` per column (never a hop above window / 2: that would let events fall between frames),
and the blocks of frames are spread over `THREADS` threads (numpy's FFTs and array arithmetic release the GIL).
"""
import math
import os
import threading
from concurrent.futures import ThreadPoolExecutor

import numpy as np

import dsp
import image

ROWS = image.ROWS
MAX_COLS = image.MAX_COLS
F_MIN = image.F_MIN
MAX_FRAMES_PER_COLUMN = 1       # the cap on the work: one frame per picture column is enough to draw a line
ENERGY_FLOOR = 1e-24            # the level of an empty cell, in energy (-240 dB)
BLOCK_BINS = 1 << 20            # frames per block x padded size: bounds the memory of a block
THREADS = max(1, min(8, os.cpu_count() or 1))


def _even(n):
    n = int(n)
    return n if n % 2 == 0 else n + 1


def settings(window, pad, overlap):
    """(window, pad, overlap) made safe: window >= 4 and even, pad >= window and even, overlap >= 2."""
    window = max(4, _even(window))
    pad = max(window, _even(pad))
    return window, pad, max(2, int(overlap))


def column_count(length, window, overlap, max_cols=MAX_COLS):
    """W of the picture: one column per hop of the (window, overlap) analysis, at most max_cols (like `image`)."""
    return image.column_count(int(length), dsp.hop_for(window, overlap), max_cols)


def effective_hop(length, window, overlap, width):
    """The hop really used: the nominal one, lifted so as to keep at most MAX_FRAMES_PER_COLUMN frames per column
    (the work is proportional to the frames), and never above window / 2."""
    nominal = dsp.hop_for(window, overlap)
    cap = -(-int(length) // (int(width) * MAX_FRAMES_PER_COLUMN))
    return max(1, min(window // 2, max(nominal, cap)))


def blank_db(length, window, overlap, rows=ROWS, max_cols=MAX_COLS):
    """The levels of silence (`image.BLANK_DB`), shaped like `build_db`'s."""
    window, _pad, overlap = settings(window, window, overlap)
    return np.full((rows, column_count(length, window, overlap, max_cols)), image.BLANK_DB, dtype=np.float32)


def windows(window):
    """(h, t.h, dh/dt): the periodic Hann, the Hann times its offset from the centre (samples), the Hann's derivative
    (1 / sample)."""
    n = np.arange(window, dtype=np.float64)
    h = dsp.hann(window)
    return h, (n - window / 2.0) * h, (np.pi / window) * np.sin(2.0 * np.pi * n / window)


def peak_energy(xc, window, hop, total):
    """The largest |X_h|^2 of the plain (not padded) transform of every frame and channel: the reference of the threshold."""
    h = dsp.hann(window)
    block = max(64, (1 << 22) // window)
    best = 0.0
    for ch in range(xc.shape[0]):
        for j0 in range(0, total, block):
            seg = dsp._segments(xc[ch:ch + 1], window, hop, j0, min(j0 + block, total))[0]
            spec = np.fft.rfft(seg * h, axis=1)
            best = max(best, float((spec.real ** 2 + spec.imag ** 2).max()))
    return best


def _splat(acc, lock, tcol, rpos, weight):
    """Deposits `weight` at the continuous cell coordinates (tcol, rpos), bilinearly, onto `acc`: a grid with ONE cell
    of border all round, (W + 2, rows + 2), where cell (c + 1, r + 1) is the cell (c, r) of the picture. A coordinate is
    within [-0.5, W - 0.5) x [-0.5, rows - 0.5), so its four cells always exist; `fold` brings the border back."""
    padded_rows = acc.shape[1]
    u = tcol + 1.0                                  # >= 0.5: the cast to int is a floor
    v = rpos + 1.0
    c0 = u.astype(np.int64)
    r0 = v.astype(np.int64)
    fc = u - c0
    fr = v - r0
    cmin = int(c0.min())
    cols = int(c0.max()) - cmin + 2
    idx = (c0 - cmin) * padded_rows + r0              # one index; the other three cells are at +1, +R, +R + 1
    wc1 = weight * fc
    wc0 = weight - wc1
    cells = cols * padded_rows
    local = np.bincount(idx, weights=wc0 * (1.0 - fr), minlength=cells)
    local[1:] += np.bincount(idx, weights=wc0 * fr, minlength=cells)[:-1]
    local[padded_rows:] += np.bincount(idx, weights=wc1 * (1.0 - fr), minlength=cells)[:-padded_rows]
    local[padded_rows + 1:] += np.bincount(idx, weights=wc1 * fr, minlength=cells)[:-padded_rows - 1]
    with lock:
        acc[cmin:cmin + cols] += local.reshape(cols, padded_rows)


def fold(acc):
    """The picture's cells (W, rows) of a padded accumulator: the border (what fell half a cell outside) joins the edge cell."""
    acc[1] += acc[0]
    acc[-2] += acc[-1]
    acc[:, 1] += acc[:, 0]
    acc[:, -2] += acc[:, -1]
    return acc[1:-1, 1:-1]


def _block(acc, lock, seg, j0, geometry, floor_e):
    """Reassigns every bin above floor_e of the frames j0.. whose samples are `seg` (nb, N) into acc (padded)."""
    sr, window, pad, hop, length, wins, rows, width = geometry
    wh, wt, wd = wins
    x_h = np.fft.rfft(seg * wh, n=pad, axis=1)
    energy = x_h.real ** 2 + x_h.imag ** 2
    above = energy > floor_e
    frames = np.nonzero(above.any(axis=1))[0]
    if not len(frames):
        return
    if len(frames) < len(seg):                      # silent frames cost nothing more
        seg, x_h, energy, above = seg[frames], x_h[frames], energy[frames], above[frames]
    x_t = np.fft.rfft(seg * wt, n=pad, axis=1)
    x_d = np.fft.rfft(seg * wd, n=pad, axis=1)
    with np.errstate(divide="ignore", invalid="ignore"):
        dt = (x_t.real * x_h.real + x_t.imag * x_h.imag) / energy                 # samples, from the frame centre
        dw = (x_d.imag * x_h.real - x_d.real * x_h.imag) / energy                 # rad / sample
        that = ((j0 + frames) * hop)[:, None] + dt
        fhat = np.arange(energy.shape[1])[None, :] * (sr / float(pad)) - dw * (sr / (2.0 * math.pi))
        # A comparison with a NaN or an infinity is false: whatever is not finite is dropped here.
        keep = (above & (np.abs(dt) <= window / 2.0) & (that >= 0) & (that < length)
                & (fhat >= F_MIN) & (fhat <= sr / 2.0))
    if not keep.any():
        return
    that, fhat, e = that[keep], fhat[keep], energy[keep]
    octaves = math.log2((sr / 2.0) / F_MIN)
    _splat(acc, lock, that * (width / float(length)) - 0.5, np.log2(fhat / F_MIN) * (rows / octaves) - 0.5, e)


def _accumulate(acc, xc, ch, geometry, total, floor_e, pool):
    """Reassigns channel `ch` into acc (W, rows), the blocks of frames spread over the thread pool."""
    window, pad, hop = geometry[1:4]
    block = max(8, min(256, BLOCK_BINS // pad))
    lock = threading.Lock()
    jobs = []
    for j0 in range(0, total, block):
        seg = dsp._segments(xc[ch:ch + 1], window, hop, j0, min(j0 + block, total))[0]
        jobs.append(pool.submit(_block, acc, lock, seg, j0, geometry, floor_e))
        if len(jobs) >= 4 * pool._max_workers:      # bounded read-ahead: the views are cheap, the blocks are not
            jobs.pop(0).result()
    for j in jobs:
        j.result()


def build_db(x, sr, window=512, pad=4096, overlap=8, threshold_db=-80.0, rows=ROWS, max_cols=MAX_COLS):
    """The levels in dB of the REASSIGNED spectrogram, float64 shaped (rows, W), row 0 = the top (highest frequency):
    the same grid as `image.build_db`, 0 dB = a full-scale sine. `x` is (L,) or (L, channels)."""
    window, pad, overlap = settings(window, pad, overlap)
    xc, _ = dsp._as_channels(x)
    length = xc.shape[1]
    if length < 1:
        raise ValueError("empty signal")
    width = column_count(length, window, overlap, max_cols)
    hop = effective_hop(length, window, overlap, width)
    total = dsp.frame_count(length, hop)
    peak = peak_energy(xc, window, hop, total)
    out = np.full((width, rows), ENERGY_FLOOR)
    if peak > 0.0:
        floor_e = peak * 10.0 ** (float(threshold_db) / 10.0)
        geometry = (sr, window, pad, hop, length, windows(window), rows, width)
        with ThreadPoolExecutor(max_workers=THREADS) as pool:
            for ch in range(xc.shape[0]):
                acc = np.zeros((width + 2, rows + 2))
                _accumulate(acc, xc, ch, geometry, total, floor_e, pool)
                best = fold(acc) if ch == 0 else np.maximum(best, fold(acc))
        # A sine of amplitude A leaves sum_k |X_k|^2 = 1.5 (pad / N) (A N / 4)^2 over its lobe in one frame: dividing by
        # that and by the frames per column makes the cell read A^2, i.e. 0 dB for a full-scale sine, like the normal picture.
        scale = 1.0 / (1.5 * pad / window * (window / 4.0) ** 2 * (total / float(width)))
        out = np.maximum(best * scale, ENERGY_FLOOR)
    db = 10.0 * np.log10(out)
    return np.ascontiguousarray(db[:, ::-1].T)

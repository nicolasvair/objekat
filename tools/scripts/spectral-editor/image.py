"""The base image of the canvas: a log-frequency spectrogram as an OBJKCNV1 file (plan 3.4).

- Magnitude of a cell: max(|X_L|, |X_R|) (a mono signal is one channel).
- Rows: 1024, log-spaced over the world's y range [20 Hz, sr / 2], row 0 = the highest band.
  A row takes the max of the bin magnitudes inside its band; if no bin falls inside it,
  it interpolates linearly (in frequency) at the row centre.
- Columns: W = min(floor(L / H) + 1, 8192), tiling the world x range [0, L / sr] uniformly. Frame j is
  centred at t_j = j H / sr and answers for the stretch of time [t_j - H/2, t_j + H/2) (its Voronoi
  cell among the frames); a column is the max over every frame whose stretch touches it. So the
  frame that is nearest to a given time always feeds the column containing that time (an event
  never shows up half a frame late), no column is ever empty, and a click survives the pooling.
- Levels: dB = 20 log10(max(m, 1e-12) / (N / 4)) (0 dB = a full-scale sine on a bin), mapped to
  idx = clip(rint((dB + 100) / 100 * 255), 0, 255), value range -100 .. 0 dB, magma palette.
"""
import math

import numpy as np

import canvasfile
import colormap
import dsp

ROWS = 1024
MAX_COLS = 8192
F_MIN = 20.0
V0 = -100.0
V255 = 0.0
FLOOR = 1e-12


def row_bands(sr, n, rows=ROWS, fmin=F_MIN):
    """Static row/bin mapping for (sr, n): (bin_start_per_row_group, group_rows, interp_rows, i0, i1, wt).

    Rows are numbered from the BOTTOM here (row 0 = fmin) and flipped by the caller.
    """
    fmax = sr / 2.0
    nb = n // 2 + 1
    f = np.arange(nb, dtype=np.float64) * sr / n
    octaves = math.log2(fmax / fmin)
    with np.errstate(divide="ignore"):
        pos = np.where(f >= fmin, np.log2(np.maximum(f, 1e-300) / fmin) / octaves * rows, -1.0)
    band = np.floor(pos + 1e-9).astype(np.int64)
    band = np.where(pos < 0, -1, np.minimum(band, rows - 1))
    valid = np.nonzero(band >= 0)[0]
    first = valid[0] if len(valid) else 0
    vb = band[valid]
    if len(valid):
        change = np.concatenate(([True], vb[1:] != vb[:-1]))
        starts = valid[np.nonzero(change)[0]]
        group_rows = vb[change]
    else:
        starts = np.zeros(0, dtype=np.int64)
        group_rows = np.zeros(0, dtype=np.int64)
    has = np.zeros(rows, dtype=bool)
    has[group_rows] = True
    interp_rows = np.nonzero(~has)[0]
    centre = fmin * 2.0 ** ((interp_rows + 0.5) / rows * octaves)
    pos_bin = np.clip(centre * n / sr, 0.0, nb - 1.0)
    i0 = np.minimum(np.floor(pos_bin).astype(np.int64), nb - 2)
    wt = pos_bin - i0
    return starts, group_rows, interp_rows, i0, i0 + 1, wt, first


def column_count(length, hop, max_cols=MAX_COLS):
    """W: one column per frame centre inside [0, L], at most max_cols."""
    return min(length // hop + 1, max_cols)


def frame_columns(j, hop, length, width):
    """(first, last) column fed by the frames `j` (an int array): the columns touched by the stretch
    [(j - 1/2) H, (j + 1/2) H) samples. Exact integer arithmetic, clamped to [0, width - 1]."""
    j = np.asarray(j, dtype=np.int64)
    den = 2 * length
    lo = ((2 * j - 1) * hop * width) // den
    hi = -((-((2 * j + 1) * hop * width)) // den) - 1
    lo = np.clip(lo, 0, width - 1)
    hi = np.clip(hi, 0, width - 1)
    return lo, np.maximum(hi, lo)


def column_of_time(t, sr, length, width):
    """The column of the picture that contains time t (seconds), clamped."""
    return int(min(width - 1, max(0, math.floor(t * sr * width / float(length)))))


def build_image(x, sr, n, k, rows=ROWS, max_cols=MAX_COLS, block=256):
    """uint8 index image shaped (rows, W), row 0 = the top (highest frequency)."""
    h = dsp.hop_for(n, k)
    length = np.asarray(x).shape[0]
    if length < 1:
        raise ValueError("empty signal")
    width = column_count(length, h, max_cols)
    starts, group_rows, interp_rows, i0, i1, wt, _first = row_bands(sr, n, rows)
    colmax = np.zeros((width, rows))
    for j0, spec in dsp.analysis_blocks(x, n, k, block):
        mag = np.abs(spec).max(axis=0)  # (nb, bins): L/R union
        nbf = mag.shape[0]
        out = np.zeros((nbf, rows))
        if len(starts):
            out[:, group_rows] = np.maximum.reduceat(mag[:, starts[0]:], starts - starts[0], axis=1)
            # the last group must stop at the last valid bin: bins above are all valid, so reduceat is exact
        if len(interp_rows):
            out[:, interp_rows] = mag[:, i0] * (1.0 - wt) + mag[:, i1] * wt
        lo, hi = frame_columns(np.arange(j0, j0 + nbf), h, length, width)
        for d in range(int((hi - lo).max()) + 1):
            sel = np.nonzero(lo + d <= hi)[0]
            cols = lo[sel] + d  # non-decreasing in j
            change = np.concatenate(([True], cols[1:] != cols[:-1]))
            seg = np.nonzero(change)[0]
            red = np.maximum.reduceat(out[sel], seg, axis=0)
            ucols = cols[seg]
            colmax[ucols] = np.maximum(colmax[ucols], red)
    db = 20.0 * np.log10(np.maximum(colmax, FLOOR) / (n / 4.0))
    idx = np.clip(np.rint((db - V0) / (V255 - V0) * 255.0), 0, 255).astype(np.uint8)
    return np.ascontiguousarray(idx[:, ::-1].T)


def write_index_image(path, idx):
    """Writes a uint8 index image (rows, W) as OBJKCNV1 (magma, -100 .. 0 dB). Returns (W, H)."""
    canvasfile.write_cnv(path, idx, V0, V255, colormap.MAGMA)
    return idx.shape[1], idx.shape[0]


def write_base_image(path, x, sr, n, k):
    """Build the base image and write it as OBJKCNV1 (magma, -100 .. 0 dB). Returns (W, H)."""
    return write_index_image(path, build_image(x, sr, n, k))


def blank_image(length, n, k, rows=ROWS, max_cols=MAX_COLS):
    """The picture of silence (every cell at the floor, -100 dB = black), shaped like `build_image`'s
    for a signal of `length` samples: the difference spectrogram when nothing has been done yet, with no
    transform to compute."""
    return np.zeros((rows, column_count(int(length), dsp.hop_for(n, k), max_cols)), dtype=np.uint8)


def row_of_frequency(freq, sr, rows=ROWS, fmin=F_MIN):
    """Row number (0 = top) whose band contains `freq`."""
    octaves = math.log2((sr / 2.0) / fmin)
    band = int(math.floor(math.log2(freq / fmin) / octaves * rows))
    return rows - 1 - min(max(band, 0), rows - 1)

"""The two picture layers of the spectral editor (plan 3.5, revised by 9.3).

THE VEIL — an OBJKRGB1 picture of the gain G of the COMMITTED STEPS only (a pending selection is never
part of it: it has its own layer below), recomputed after every history change.
- Grid: columns = min(4096, max(256, ceil(T / 0.005))) over the world x range, rows = 512 log-spaced
  over the world y range, G evaluated at cell centres with `mask`.
- Colours (premultiplied): attenuation (G < 0): (0, 0.75, 1), alpha 0.75 * (1 - 10^(G/20));
  boost (G > 0): (0.4, 1, 0.3), alpha 0.5 * min(1, (10^(G/20) - 1) / 3).
- `VeilCache` adds only the new steps when the active list is the previous one plus appended
  steps, and recomputes the whole grid otherwise (any undo).

THE SELECTION LAYER — the pending selection (the trailing drafts), same grid as the veil: amber
(1, 0.85, 0.25), alpha 0.6 * S, premultiplied; opacity = intensity, the gain plays no part in it.
- `SelectionCache` applies only the new draft ops when the list is the previous one plus appended
  ops (the clamped updates are sequential, so this is exact), and recomputes the whole grid on an
  undo or when a feather changes (a feather moves the rectangles' edges, so S is not reusable).

Orientation: `veil_grid` and G / S are ascending in both axes, shaped (columns, rows-from-bottom);
`render_veil` / `render_selection` flip to the picture's order (row 0 = the top).
"""
import math

import numpy as np

import canvasfile
import mask

MAX_COLS = 4096
MIN_COLS = 256
COL_SECONDS = 0.005
ROWS = 512
ATTENUATION_RGB = (0.0, 0.75, 1.0)
BOOST_RGB = (0.4, 1.0, 0.3)
SELECTION_RGB = (1.0, 0.85, 0.25)
SELECTION_ALPHA = 0.6


def veil_dims(world):
    x = world["x"]
    cols = min(MAX_COLS, max(MIN_COLS, int(math.ceil((float(x["max"]) - float(x["min"])) / COL_SECONDS))))
    return cols, ROWS


def veil_grid(world):
    """(xw, yw): warped cell-centre coordinates, both ascending."""
    cols, rows = veil_dims(world)
    ax, ay = world["x"], world["y"]
    x0, x1 = mask.warp(float(ax["min"]), ax.get("mapping") or "lin"), mask.warp(float(ax["max"]), ax.get("mapping") or "lin")
    y0, y1 = mask.warp(float(ay["min"]), ay.get("mapping") or "lin"), mask.warp(float(ay["max"]), ay.get("mapping") or "lin")
    xw = x0 + (np.arange(cols) + 0.5) * (x1 - x0) / cols
    yw = y0 + (np.arange(rows) + 0.5) * (y1 - y0) / rows
    return xw, yw


def render_veil(g):
    """G (dB, shaped (columns, rows-from-bottom)) -> premultiplied RGBA uint8 (rows, columns, 4).

    Computed in float32 and in G's own orientation, flipped once when written (about 3x faster
    than the straightforward float64 version on a 4096 x 512 grid, which matters on every edit).
    """
    g32 = np.maximum(g, mask.MIN_DB).astype(np.float32)
    lin = np.exp(g32 * np.float32(math.log(10.0) / 20.0))
    neg = g32 < 0
    # attenuation: 0.75 (1 - lin); boost: 0.5 min(1, (lin - 1) / 3); G == 0 gives 0 in the boost branch
    alpha = np.where(neg, np.float32(0.75) * (np.float32(1.0) - lin), np.minimum(np.float32(0.5), (lin - np.float32(1.0)) * np.float32(0.5 / 3.0)))
    scaled = alpha * np.float32(255.0)
    packed = np.empty(g.shape + (4,), dtype=np.uint8)
    for ch in range(3):
        colour = np.where(neg, np.float32(ATTENUATION_RGB[ch]), np.float32(BOOST_RGB[ch]))
        packed[..., ch] = np.rint(scaled * colour)
    packed[..., 3] = np.rint(scaled)
    # one transposing, flipping copy of 4-byte pixels
    flipped = np.ascontiguousarray(packed.view("<u4")[..., 0].T[::-1])
    return flipped.view(np.uint8).reshape(g.shape[1], g.shape[0], 4)


def write_veil(path, g):
    canvasfile.write_rgb(path, render_veil(g))


def render_selection(s):
    """S (selection intensity in [0, 1], shaped (columns, rows-from-bottom)) -> premultiplied RGBA uint8
    (rows, columns, 4): amber (1, 0.85, 0.25), alpha 0.6 * S, so S = 1 is 60 % opaque and S = 0 is clear."""
    s32 = np.clip(np.asarray(s), 0.0, 1.0).astype(np.float32)
    scaled = s32 * np.float32(SELECTION_ALPHA * 255.0)
    packed = np.empty(s32.shape + (4,), dtype=np.uint8)
    for ch in range(3):
        packed[..., ch] = np.rint(scaled * np.float32(SELECTION_RGB[ch]))
    packed[..., 3] = np.rint(scaled)
    flipped = np.ascontiguousarray(packed.view("<u4")[..., 0].T[::-1])
    return flipped.view(np.uint8).reshape(s32.shape[1], s32.shape[0], 4)


def write_selection(path, s):
    canvasfile.write_rgb(path, render_selection(s))


class VeilCache:
    """Keeps G for the last list of steps. `update(steps, world)` returns G (do not mutate it).
    `steps` = [(ops, params)], the committed steps (@see mask.split_history)."""

    def __init__(self):
        self.world = None
        self.steps = []
        self.g = None
        self.xw = None
        self.yw = None
        self.compiled_cache = {}
        self.full_recomputes = 0
        self.incremental_updates = 0

    @staticmethod
    def _world_key(world):
        return tuple((a, float(world[a]["min"]), float(world[a]["max"]), world[a].get("mapping") or "lin") for a in ("x", "y"))

    def update(self, steps, world):
        steps = [(list(ops), dict(params)) for ops, params in steps]
        key = self._world_key(world)
        n = len(self.steps)
        appended = (self.g is not None and key == self.world and len(steps) >= n and steps[:n] == self.steps)
        if not appended:
            self.xw, self.yw = veil_grid(world)
            self.world = key
            self.g = np.zeros((len(self.xw), len(self.yw)))
            self.compiled_cache = {}
            self.steps = []
            self.full_recomputes += 1
            new = steps
        else:
            if len(steps) > n:
                self.incremental_updates += 1
            new = steps[n:]
        for ops, params in new:
            self.g += mask.step_gain_grid(ops, params, self.xw, self.yw, world, self.compiled_cache)
        self.steps = steps
        return self.g


class SelectionCache:
    """Keeps S for the last list of draft ops at the last feathers.
    `update(draft_ops, world, feather_ms, feather_st)` returns S (do not mutate it)."""

    def __init__(self):
        self.world = None
        self.ops = []
        self.feathers = None
        self.s = None
        self.xw = None
        self.yw = None
        self.compiled_cache = {}
        self.full_recomputes = 0
        self.incremental_updates = 0

    def update(self, draft_ops, world, feather_ms, feather_st):
        draft_ops = list(draft_ops)
        key = VeilCache._world_key(world)
        feathers = (float(feather_ms), float(feather_st))
        n = len(self.ops)
        appended = (self.s is not None and key == self.world and feathers == self.feathers
                    and len(draft_ops) >= n and draft_ops[:n] == self.ops)
        if not appended:
            self.xw, self.yw = veil_grid(world)
            self.world = key
            self.feathers = feathers
            self.s = np.zeros((len(self.xw), len(self.yw)))
            self.compiled_cache = {}
            self.ops = []
            self.full_recomputes += 1
            new = draft_ops
        else:
            if len(draft_ops) > n:
                self.incremental_updates += 1
            new = draft_ops[n:]
        fx, fy = mask.feather_axes(*feathers)
        for p in mask.compile_ops(new, world, self.compiled_cache):
            mask.add_op_to_selection(self.s, p, self.xw, self.yw, fx, fy)
        self.ops = draft_ops
        return self.s

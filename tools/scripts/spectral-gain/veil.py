"""The mask veil layer: an OBJKRGB1 picture of the gain G, recomputed after every history change
(plan 3.5).

- Grid: columns = min(4096, max(256, ceil(T / 0.005))) over the world x range, rows = 512 log-spaced
  over the world y range, G evaluated at cell centres with `mask`.
- Colours (premultiplied): attenuation (G < 0): (0, 0.75, 1), alpha 0.75 * (1 - 10^(G/20));
  boost (G > 0): (0.4, 1, 0.3), alpha 0.5 * min(1, (10^(G/20) - 1) / 3).
- `VeilCache` adds only the new contributions when the active list is the previous one plus appended
  ops, and recomputes the whole grid otherwise.

Orientation: `veil_grid` and G are ascending in both axes, G shaped (columns, rows-from-bottom);
`render_veil` flips to the picture's order (row 0 = the top).
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


class VeilCache:
    """Keeps G for the last active list. `update(ops, world)` returns G (do not mutate it)."""

    def __init__(self):
        self.world = None
        self.ops = []
        self.g = None
        self.xw = None
        self.yw = None
        self.compiled_cache = {}
        self.full_recomputes = 0
        self.incremental_updates = 0

    @staticmethod
    def _world_key(world):
        return tuple((a, float(world[a]["min"]), float(world[a]["max"]), world[a].get("mapping") or "lin") for a in ("x", "y"))

    def update(self, ops, world):
        ops = list(ops)
        key = self._world_key(world)
        n = len(self.ops)
        appended = (self.g is not None and key == self.world and len(ops) >= n and ops[:n] == self.ops)
        if not appended:
            self.xw, self.yw = veil_grid(world)
            self.world = key
            self.g = np.zeros((len(self.xw), len(self.yw)))
            self.compiled_cache = {}
            self.ops = []
            self.full_recomputes += 1
            new = ops
        else:
            if len(ops) > n:
                self.incremental_updates += 1
            new = ops[n:]
        for p in mask.compile_ops(new, world, self.compiled_cache):
            mask.add_op_to_grid(self.g, p, self.xw, self.yw)
        self.ops = ops
        return self.g

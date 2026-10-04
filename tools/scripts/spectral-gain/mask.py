"""The gain mathematics of the spectral editor: the ONLY home of the rectangle, the cumulative
spray eraser and their summation (plan 3.3). The app knows gestures; this module knows dB.

Everything is in dB and additive. The total G of a list of active ops is clamped to >= -300 dB
before it becomes a linear gain; there is no ceiling on boosts.

Layout of the module
- Pure Python (no numpy import): SPACING, R, warp, profile, per_dab_db, dab_centres, ramp,
  rect_weight_1d, is_open, active_ops, rect_from_op, eraser_from_op, gain_at.
- numpy, imported lazily: compile_ops, add_op_to_grid, gain_grid, to_linear,
  stft_gain_block_fn. A grid is shaped (len(xw), len(yw)): columns first, which is the
  (frames, bins) layout `dsp.process` wants. Patches are located with `searchsorted`, so an op only
  touches the cells it can reach.

World: {"x": {"min", "max", "mapping"}, "y": {...}} exactly as `script.canvas.get` reports it
(`mapping` is "lin" by default, "log" warps with log2). Op coordinates are DATA units; grids are
addressed in WARPED units (seconds on a lin axis, octaves on a log axis).

Conventions the plan leaves open, and what this module does
- An op whose tool is neither "rect" nor "eraser" contributes nothing.
- A missing or non-finite parameter raises ValueError (a script that declares its tools wrongly
  must hear about it rather than get silently wrong audio).
- A degenerate eraser (size_x or size_y not > 0) contributes nothing.
"""
import math

SPACING = 0.25  # distance between dabs, in diameters
R = 0.5         # dab radius, in diameters
OPEN_TOLERANCE = 1e-9
MIN_DB = -300.0


# ---------------------------------------------------------------- pure Python

def warp(v, mapping="lin"):
    """Data value -> warped value (log2 on a log axis)."""
    return math.log2(v) if mapping == "log" else v


def unwarp(w, mapping="lin"):
    return 2.0 ** w if mapping == "log" else w


def profile(rho, h):
    """Dab falloff at distance rho (in radii): 1 inside the hard core h, 0 beyond 1,
    a raised cosine in between. `h` is hardness / 100."""
    if rho >= 1.0:
        return 0.0
    if rho <= h:
        return 1.0
    return 0.5 + 0.5 * math.cos(math.pi * (rho - h) / (1.0 - h))


def per_dab_db(amount, h):
    """dB deposited by ONE dab so that a straight crossing deposits `amount` on its centre line:
    amount * SPACING / (R * (1 + h)) = amount * 0.5 / (1 + h)."""
    return amount * SPACING / (R * (1.0 + h))


def dab_centres(u, v):
    """Dab centres, in normalised (diameter) space, along the polyline (u[i], v[i]).

    Centres sit at arc lengths (k + 0.5) * SPACING. A still hand deposits nothing, and
    resampling the path more densely does not move any dab.
    """
    dabs = []
    acc = 0.0
    k = 0
    for i in range(1, len(u)):
        du = u[i] - u[i - 1]
        dv = v[i] - v[i - 1]
        seg = math.sqrt(du * du + dv * dv)
        if seg <= 0:
            continue
        while (k + 0.5) * SPACING <= acc + seg:
            t = ((k + 0.5) * SPACING - acc) / seg
            dabs.append((u[i - 1] + t * du, v[i - 1] + t * dv))
            k += 1
        acc += seg
    return dabs


def ramp(t):
    """0 for t <= 0, 1 for t >= 1, raised cosine between."""
    if t <= 0.0:
        return 0.0
    if t >= 1.0:
        return 1.0
    return 0.5 - 0.5 * math.cos(math.pi * t)


def is_open(edge, bound, span):
    """True when a rectangle's edge sits on the world bound (within 1e-9 of the span, in data
    units): such an edge has no ramp and the rectangle extends without limit."""
    return abs(edge - bound) <= OPEN_TOLERANCE * span


def rect_weight_1d(v, lo, hi, feather, open_lo=False, open_hi=False):
    """Weight of warped coordinate v for [lo, hi] with a feather centred on each drawn edge."""
    if feather <= 0.0:
        if (not open_lo and v < lo) or (not open_hi and v > hi):
            return 0.0
        return 1.0
    w = 1.0
    if not open_lo:
        w = min(w, ramp((v - (lo - feather / 2.0)) / feather))
    if not open_hi:
        w = min(w, ramp(((hi + feather / 2.0) - v) / feather))
    return w


def active_ops(history):
    """The active ops of a `history` payload: ops[:cursor]."""
    return list(history["ops"][:history["cursor"]])


def _finite(x, what):
    x = float(x)
    if not math.isfinite(x):
        raise ValueError("%s is not finite" % what)
    return x


def _param(op, name):
    params = op.get("params") or {}
    if name not in params:
        raise ValueError("op %s lacks the parameter %r" % (op.get("id"), name))
    return _finite(params[name], "parameter %r of op %s" % (name, op.get("id")))


def _axis(world, name):
    a = world[name]
    return float(a["min"]), float(a["max"]), a.get("mapping") or "lin"


def rect_from_op(op, world):
    """Primitive of a rect op: dict(kind, lo_x, hi_x, lo_y, hi_y, open flags, fx, fy, gain_db),
    with lo/hi WARPED, sorted and clamped to the world."""
    xmin, xmax, xmap = _axis(world, "x")
    ymin, ymax, ymap = _axis(world, "y")
    x0, x1 = sorted((_finite(op["x0"], "x0"), _finite(op["x1"], "x1")))
    y0, y1 = sorted((_finite(op["y0"], "y0"), _finite(op["y1"], "y1")))
    x0, x1 = max(x0, xmin), min(x1, xmax)
    y0, y1 = max(y0, ymin), min(y1, ymax)
    gain = _param(op, "gain")
    fms = max(0.0, _param(op, "feather_ms"))
    fst = max(0.0, _param(op, "feather_st"))
    return {
        "kind": "rect",
        "lo_x": warp(x0, xmap), "hi_x": warp(x1, xmap),
        "lo_y": warp(y0, ymap), "hi_y": warp(y1, ymap),
        "open_lo_x": is_open(x0, xmin, xmax - xmin), "open_hi_x": is_open(x1, xmax, xmax - xmin),
        "open_lo_y": is_open(y0, ymin, ymax - ymin), "open_hi_y": is_open(y1, ymax, ymax - ymin),
        "fx": fms / 1000.0, "fy": fst / 12.0,
        "gain_db": gain,
    }


def eraser_from_op(op, world):
    """Primitive of an eraser op: dict(kind, dabs [(u, v)], a (dB per dab), h, size_x, size_y).
    Returns None for a degenerate stroke."""
    _, _, xmap = _axis(world, "x")
    _, _, ymap = _axis(world, "y")
    sx = _finite(op["size_x"], "size_x")
    sy = _finite(op["size_y"], "size_y")
    amount = _param(op, "amount")
    h = min(1.0, max(0.0, _param(op, "hardness") / 100.0))
    if sx <= 0 or sy <= 0:
        return None
    u, v = [], []
    for p in op["points"]:
        u.append(warp(_finite(p[0], "point x"), xmap) / sx)
        v.append(warp(_finite(p[1], "point y"), ymap) / sy)
    return {"kind": "eraser", "dabs": dab_centres(u, v), "a": per_dab_db(amount, h),
            "h": h, "size_x": sx, "size_y": sy}


def _primitive(op, world):
    tool = op.get("tool")
    if tool == "rect":
        return rect_from_op(op, world)
    if tool == "eraser":
        return eraser_from_op(op, world)
    return None


def _prim_gain_at(p, xw, yw):
    if p["kind"] == "rect":
        wx = rect_weight_1d(xw, p["lo_x"], p["hi_x"], p["fx"], p["open_lo_x"], p["open_hi_x"])
        if wx == 0.0:
            return 0.0
        wy = rect_weight_1d(yw, p["lo_y"], p["hi_y"], p["fy"], p["open_lo_y"], p["open_hi_y"])
        return p["gain_db"] * wx * wy
    total = 0.0
    sx, sy, h = p["size_x"], p["size_y"], p["h"]
    for cu, cv in p["dabs"]:
        du = xw / sx - cu
        dv = yw / sy - cv
        rho = math.sqrt(du * du + dv * dv) / R
        total += p["a"] * profile(rho, h)
    return total


def gain_at(x, y, ops, world):
    """Total G in dB at a point given in DATA units: the sum over `ops` (already the active ones).
    Not clamped (see `to_linear` for the -300 dB floor)."""
    _, _, xmap = _axis(world, "x")
    _, _, ymap = _axis(world, "y")
    return gain_at_warped(warp(x, xmap), warp(y, ymap), ops, world)


def gain_at_warped(xw, yw, ops, world):
    total = 0.0
    for op in ops:
        p = _primitive(op, world)
        if p is not None:
            total += _prim_gain_at(p, xw, yw)
    return total


# ---------------------------------------------------------------- numpy part

def _np():
    import numpy
    return numpy


def compile_ops(ops, world, cache=None):
    """Primitives of `ops` (those with a gain meaning), ready for `add_op_to_grid`.
    `cache` is an optional dict keyed by op id: ops are immutable per id for one canvas."""
    out = []
    for op in ops:
        key = op.get("id")
        if cache is not None and key in cache:
            p = cache[key]
        else:
            p = _primitive(op, world)
            if cache is not None:
                cache[key] = p
        if p is not None:
            out.append(p)
    return out


def _ramp_arr(t):
    np = _np()
    return np.where(t <= 0, 0.0, np.where(t >= 1, 1.0, 0.5 - 0.5 * np.cos(np.pi * np.clip(t, 0.0, 1.0))))


def _weight_arr(v, lo, hi, feather, open_lo, open_hi):
    np = _np()
    if feather <= 0.0:
        w = np.ones(v.shape)
        if not open_lo:
            w[v < lo] = 0.0
        if not open_hi:
            w[v > hi] = 0.0
        return w
    w = np.ones(v.shape)
    if not open_lo:
        w = np.minimum(w, _ramp_arr((v - (lo - feather / 2.0)) / feather))
    if not open_hi:
        w = np.minimum(w, _ramp_arr(((hi + feather / 2.0) - v) / feather))
    return w


def _profile_arr(rho, h):
    np = _np()
    if h >= 1.0:
        return np.where(rho < 1.0, 1.0, 0.0)
    mid = 0.5 + 0.5 * np.cos(np.pi * np.clip((rho - h) / (1.0 - h), 0.0, 1.0))
    return np.where(rho >= 1.0, 0.0, np.where(rho <= h, 1.0, mid))


def add_op_to_grid(grid, p, xw, yw):
    """Add the contribution (dB) of one primitive into `grid` shaped (len(xw), len(yw)).
    xw and yw are ascending arrays of warped coordinates."""
    np = _np()
    if p["kind"] == "rect":
        fx, fy = p["fx"], p["fy"]
        x_lo = -np.inf if p["open_lo_x"] else p["lo_x"] - fx / 2.0
        x_hi = np.inf if p["open_hi_x"] else p["hi_x"] + fx / 2.0
        y_lo = -np.inf if p["open_lo_y"] else p["lo_y"] - fy / 2.0
        y_hi = np.inf if p["open_hi_y"] else p["hi_y"] + fy / 2.0
        i0, i1 = np.searchsorted(xw, x_lo, "left"), np.searchsorted(xw, x_hi, "right")
        j0, j1 = np.searchsorted(yw, y_lo, "left"), np.searchsorted(yw, y_hi, "right")
        if i1 <= i0 or j1 <= j0:
            return
        wx = _weight_arr(xw[i0:i1], p["lo_x"], p["hi_x"], fx, p["open_lo_x"], p["open_hi_x"])
        wy = _weight_arr(yw[j0:j1], p["lo_y"], p["hi_y"], fy, p["open_lo_y"], p["open_hi_y"])
        grid[i0:i1, j0:j1] += p["gain_db"] * np.outer(wx, wy)
        return
    sx, sy, h, a = p["size_x"], p["size_y"], p["h"], p["a"]
    rx, ry = R * sx, R * sy
    for cu, cv in p["dabs"]:
        cx, cy = cu * sx, cv * sy
        i0, i1 = np.searchsorted(xw, cx - rx, "left"), np.searchsorted(xw, cx + rx, "right")
        j0, j1 = np.searchsorted(yw, cy - ry, "left"), np.searchsorted(yw, cy + ry, "right")
        if i1 <= i0 or j1 <= j0:
            continue
        du = (xw[i0:i1] / sx - cu)[:, None]
        dv = (yw[j0:j1] / sy - cv)[None, :]
        rho = np.sqrt(du * du + dv * dv) / R
        grid[i0:i1, j0:j1] += a * _profile_arr(rho, h)


def gain_grid(ops, xw, yw, world, compiled=None):
    """G in dB on the grid xw x yw (warped, ascending), shaped (len(xw), len(yw)).
    Pass `compiled` (from `compile_ops`) to skip the interpretation of `ops`."""
    np = _np()
    xw = np.asarray(xw, dtype=np.float64)
    yw = np.asarray(yw, dtype=np.float64)
    grid = np.zeros((len(xw), len(yw)))
    for p in (compiled if compiled is not None else compile_ops(ops, world)):
        add_op_to_grid(grid, p, xw, yw)
    return grid


def to_linear(g_db):
    """dB -> linear amplitude, with G clamped to >= -300 dB first."""
    np = _np()
    return 10.0 ** (np.maximum(g_db, MIN_DB) / 20.0)


def stft_grid_axes(world, sr, n, h, j0, j1):
    """Warped coordinates of the STFT cells of frames j0..j1-1: (xw, yw) with yw covering bins
    1..N/2 (the DC bin is not on a log axis; `stft_gain_block_fn` copies bin 1 into it)."""
    np = _np()
    _, _, xmap = _axis(world, "x")
    _, _, ymap = _axis(world, "y")
    t = np.arange(j0, j1, dtype=np.float64) * h / float(sr)
    f = np.arange(1, n // 2 + 1, dtype=np.float64) * sr / float(n)
    return (np.log2(t) if xmap == "log" else t), (np.log2(f) if ymap == "log" else f)


def stft_gain_block_fn(ops, world, sr, n, k, cache=None):
    """The `gain_block_fn` for `dsp.process`: linear gain (nb, N/2 + 1) for frames j0..j1-1.
    Cell (j, bin b >= 1) is evaluated at (jH/sr, b*sr/N); the DC bin copies bin 1."""
    np = _np()
    h = int(math.floor(n / float(k) + 0.5))
    prims = compile_ops(ops, world, cache)

    def fn(j0, j1):
        xw, yw = stft_grid_axes(world, sr, n, h, j0, j1)
        g = gain_grid(None, xw, yw, world, compiled=prims)
        full = np.empty((j1 - j0, n // 2 + 1))
        full[:, 1:] = g
        full[:, 0] = g[:, 0]
        return to_linear(full)

    return fn

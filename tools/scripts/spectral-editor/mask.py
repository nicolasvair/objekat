"""The gain mathematics of the spectral editor: the ONLY home of the rectangle, the brush, the weighted
selection and its pro rata gain (plan 9.3). The app knows gestures, steps and history; this module
knows dB.

The model (plan 9, revision 3)
- A gesture (an OP) draws SELECTION INTENSITY S in [0, 1] over time x frequency, and has a polarity,
  "add" or "subtract". S starts at 0 and the ops are applied IN ORDER:
    brush add       S <- min(1, S + q * D)        D = sum over the dabs of per_dab_weight(h) * profile
    brush subtract  S <- max(0, S - q * D)        q = quantity / 100 (a property of the gesture: op params)
    rect add        S <- max(S, W)                W = wx * wy, the feathered box (open edges as before)
    rect subtract   S <- min(S, 1 - W)
  One straight brush crossing deposits exactly 1 on the centre line (D), so it adds exactly q.
- A STEP is a list of ops with the params it was sealed with: its gain is `gain * S`, and its S uses the
  step's own `feather_ms` / `feather_st`. The total of the active steps is the sum, in dB:
  G = sum(gain_s * S_s), plus `live_gain * S_draft` for the trailing drafts (the pending selection, drawn
  with the CURRENT values: a preview, never a step). So gain and feathers are tunable live, quantity and
  hardness are fixed by the gesture.
- G is clamped to >= -300 dB when it becomes a linear gain (`to_linear`); there is no ceiling on boosts.

Layout of the module
- Pure Python (no numpy import): SPACING_MAX / SPACING_MIN, spacing_for, R, warp, profile, per_dab_weight,
  dab_centres, ramp, rect_weight_1d, is_open, split_history, rect_from_op, brush_from_op,
  selection_at(_warped), gain_at(_warped).
- numpy, imported lazily: compile_ops, add_op_to_selection, selection_grid, step_gain_grid, gain_grid,
  to_linear, stft_gain_block_fn. A grid is shaped (len(xw), len(yw)): columns first, which is the
  (frames, bins) layout `dsp.process` wants. Patches are located with `searchsorted`, so an op only
  touches the cells it can reach.

World: {"x": {"min", "max", "mapping"}, "y": {...}} exactly as `script.canvas.get` reports it
(`mapping` is "lin" by default, "log" warps with log2). Op coordinates are DATA units; grids are
addressed in WARPED units (seconds on a lin axis, octaves on a log axis).

History: `split_history` reads a `history` payload (`entries` + `cursor`) into the active STEPS
[(ops, params)] and the ops of the trailing active drafts.

Conventions the plan leaves open, and what this module does
- An op whose tool is neither "rect" nor "brush" contributes nothing.
- A missing or non-finite parameter raises ValueError (a script that declares its tools wrongly
  must hear about it rather than get silently wrong audio). A polarity other than add/subtract too.
- A degenerate brush (size_x or size_y not > 0) contributes nothing; quantity is clamped to 0..100 and
  hardness to 0..100.
"""
import math

SPACING_MAX = 0.25        # distance between dabs, in diameters, for a soft brush (h <= SPACING_KNEE_H)
SPACING_MIN = 1.0 / 64.0  # ... and for a perfectly hard one (h = 1)
SPACING_KNEE_H = 0.3
SPACING = SPACING_MAX     # historical name: the spacing of a soft brush
R = 0.5                   # dab radius, in diameters
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


def spacing_for(h):
    """Distance between dabs, in diameters, for hardness h in [0, 1] (clamped).

    Sampling the dab profile every `s` diameters leaves a ripple along a straight stroke whose
    size depends on how sharp the profile is. A soft brush is fine at 0.25; a hard one (a nearly
    box-shaped profile) needs far denser dabs. So: 0.25 up to h = 0.3, then a straight line down
    to 1/64 at h = 1. Measured worst-case ripple on the centre line of a straight stroke stays
    under 1.4 % of the quantity for every h (0.0 ... 1.0 in steps of 0.01); with the old fixed 0.25
    it reached 25 %. The Swift trace (purely visual) mirrors this function.
    """
    h = min(1.0, max(0.0, h))
    if h <= SPACING_KNEE_H:
        return SPACING_MAX
    if h >= 1.0:
        return SPACING_MIN
    return SPACING_MAX - (SPACING_MAX - SPACING_MIN) * (h - SPACING_KNEE_H) / (1.0 - SPACING_KNEE_H)


def per_dab_weight(h):
    """Selection intensity deposited by ONE dab (before the quantity) so that a straight crossing
    deposits exactly 1 on its centre line: spacing_for(h) / (R * (1 + h)). (The profile's integral
    across the centre line is R * (1 + h), and dabs sit spacing_for(h) apart.)"""
    return spacing_for(h) / (R * (1.0 + h))


def dab_centres(u, v, spacing=SPACING_MAX):
    """Dab centres, in normalised (diameter) space, along the polyline (u[i], v[i]).

    Centres sit at arc lengths (k + 0.5) * spacing (`spacing_for(h)` for a brush). A still hand
    deposits nothing, and resampling the path more densely does not move any dab.
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
        while (k + 0.5) * spacing <= acc + seg:
            t = ((k + 0.5) * spacing - acc) / seg
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


def split_history(history):
    """The active part of a `history` payload: (steps, draft_ops).

    `steps` = [(ops, params)] for the active entries of kind "step" (ops and params of each, in order);
    `draft_ops` = the ops of the TRAILING active entries of kind "draft" (the pending selection), in
    order. Active = entries[:cursor]. A draft below a step cannot happen (a commit consumes every
    draft, a mode switch is refused while one is pending) and raises ValueError, like an unknown kind."""
    steps = []
    draft_ops = []
    for entry in list(history.get("entries") or [])[:history["cursor"]]:
        kind = entry.get("kind")
        if kind == "step":
            if draft_ops:
                raise ValueError("entry %s: a step above a draft" % entry.get("id"))
            steps.append((list(entry.get("ops") or []), dict(entry.get("params") or {})))
        elif kind == "draft":
            draft_ops.extend(entry.get("ops") or [])
        else:
            raise ValueError("entry %s: unknown kind %r" % (entry.get("id"), kind))
    return steps, draft_ops


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


def _sign(op):
    """+1 for an "add" op (the default when the key is absent), -1 for "subtract"."""
    polarity = op.get("polarity", "add")
    if polarity == "add":
        return 1
    if polarity == "subtract":
        return -1
    raise ValueError("op %s: unknown polarity %r" % (op.get("id"), polarity))


def step_values(params):
    """(gain dB, feather_ms, feather_st) of a step's params (or of the live values): the three keys
    that are tunable while a selection is pending. Feathers are clamped to >= 0."""
    def get(name):
        if params is None or name not in params:
            raise ValueError("the step params lack %r" % name)
        return _finite(params[name], "step parameter %r" % name)

    return get("gain"), max(0.0, get("feather_ms")), max(0.0, get("feather_st"))


def feather_axes(feather_ms, feather_st):
    """(fx, fy): the feathers in warped units, seconds on the time axis and octaves on the log one."""
    return max(0.0, feather_ms) / 1000.0, max(0.0, feather_st) / 12.0


def _axis(world, name):
    a = world[name]
    return float(a["min"]), float(a["max"]), a.get("mapping") or "lin"


def rect_from_op(op, world):
    """Geometry of a rect op: dict(kind, lo_x, hi_x, lo_y, hi_y, open flags, sign), with lo/hi WARPED,
    sorted and clamped to the world. The feathers are not the op's: they come with the step."""
    xmin, xmax, xmap = _axis(world, "x")
    ymin, ymax, ymap = _axis(world, "y")
    x0, x1 = sorted((_finite(op["x0"], "x0"), _finite(op["x1"], "x1")))
    y0, y1 = sorted((_finite(op["y0"], "y0"), _finite(op["y1"], "y1")))
    x0, x1 = max(x0, xmin), min(x1, xmax)
    y0, y1 = max(y0, ymin), min(y1, ymax)
    return {
        "kind": "rect", "sign": _sign(op),
        "lo_x": warp(x0, xmap), "hi_x": warp(x1, xmap),
        "lo_y": warp(y0, ymap), "hi_y": warp(y1, ymap),
        "open_lo_x": is_open(x0, xmin, xmax - xmin), "open_hi_x": is_open(x1, xmax, xmax - xmin),
        "open_lo_y": is_open(y0, ymin, ymax - ymin), "open_hi_y": is_open(y1, ymax, ymax - ymin),
    }


def brush_from_op(op, world):
    """Primitive of a brush op: dict(kind, sign, dabs [(u, v)], w (deposit per dab), q (quantity, 0..1),
    h, spacing, size_x, size_y). Returns None for a degenerate stroke."""
    _, _, xmap = _axis(world, "x")
    _, _, ymap = _axis(world, "y")
    sign = _sign(op)
    sx = _finite(op["size_x"], "size_x")
    sy = _finite(op["size_y"], "size_y")
    q = min(1.0, max(0.0, _param(op, "quantity") / 100.0))
    h = min(1.0, max(0.0, _param(op, "hardness") / 100.0))
    if sx <= 0 or sy <= 0:
        return None
    u, v = [], []
    for p in op["points"]:
        u.append(warp(_finite(p[0], "point x"), xmap) / sx)
        v.append(warp(_finite(p[1], "point y"), ymap) / sy)
    return {"kind": "brush", "sign": sign, "dabs": dab_centres(u, v, spacing_for(h)), "w": per_dab_weight(h),
            "q": q, "h": h, "spacing": spacing_for(h), "size_x": sx, "size_y": sy}


def _primitive(op, world):
    tool = op.get("tool")
    if tool == "rect":
        return rect_from_op(op, world)
    if tool == "brush":
        return brush_from_op(op, world)
    return None


def _prim_weight_at(p, xw, yw, fx, fy):
    """What an op deposits at a point, before the polarity is applied: W for a rect, q * D for a brush."""
    if p["kind"] == "rect":
        wx = rect_weight_1d(xw, p["lo_x"], p["hi_x"], fx, p["open_lo_x"], p["open_hi_x"])
        if wx == 0.0:
            return 0.0
        return wx * rect_weight_1d(yw, p["lo_y"], p["hi_y"], fy, p["open_lo_y"], p["open_hi_y"])
    total = 0.0
    sx, sy, h = p["size_x"], p["size_y"], p["h"]
    for cu, cv in p["dabs"]:
        du = xw / sx - cu
        dv = yw / sy - cv
        rho = math.sqrt(du * du + dv * dv) / R
        total += profile(rho, h)
    return p["q"] * p["w"] * total


def selection_at_warped(xw, yw, ops, world, feather_ms=0.0, feather_st=0.0):
    """Selection intensity S in [0, 1] at a point given in WARPED units, after `ops` in order."""
    fx, fy = feather_axes(feather_ms, feather_st)
    s = 0.0
    for op in ops:
        p = _primitive(op, world)
        if p is None:
            continue
        v = _prim_weight_at(p, xw, yw, fx, fy)
        if p["kind"] == "rect":
            s = max(s, v) if p["sign"] > 0 else min(s, 1.0 - v)
        else:
            s = min(1.0, s + v) if p["sign"] > 0 else max(0.0, s - v)
    return s


def selection_at(x, y, ops, world, feather_ms=0.0, feather_st=0.0):
    """`selection_at_warped` for a point in DATA units."""
    _, _, xmap = _axis(world, "x")
    _, _, ymap = _axis(world, "y")
    return selection_at_warped(warp(x, xmap), warp(y, ymap), ops, world, feather_ms, feather_st)


def gain_at(x, y, steps, world, draft_ops=None, live=None):
    """Total G in dB at a point given in DATA units: sum of gain_s * S_s over `steps` [(ops, params)],
    plus live gain * S_draft when `draft_ops` is not empty (`live` = the current values). Not clamped
    (see `to_linear` for the -300 dB floor)."""
    _, _, xmap = _axis(world, "x")
    _, _, ymap = _axis(world, "y")
    return gain_at_warped(warp(x, xmap), warp(y, ymap), steps, world, draft_ops, live)


def gain_at_warped(xw, yw, steps, world, draft_ops=None, live=None):
    total = 0.0
    for ops, params in steps:
        gain, fms, fst = step_values(params)
        total += gain * selection_at_warped(xw, yw, ops, world, fms, fst)
    if draft_ops:
        gain, fms, fst = step_values(live)
        total += gain * selection_at_warped(xw, yw, draft_ops, world, fms, fst)
    return total


# ---------------------------------------------------------------- numpy part

def _np():
    import numpy
    return numpy


def compile_ops(ops, world, cache=None):
    """Primitives of `ops` (those with a selection meaning), ready for `add_op_to_selection`.
    `cache` is an optional dict keyed by op id: ops are immutable per id for one canvas, and a
    primitive holds geometry only (the feathers come at grid time), so one op serves every feather."""
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


def add_op_to_selection(S, p, xw, yw, fx=0.0, fy=0.0):
    """Applies one primitive to the selection grid `S` (shaped (len(xw), len(yw)), in [0, 1]), IN PLACE.
    xw and yw are ascending arrays of warped coordinates; fx, fy the feathers in warped units."""
    np = _np()
    if p["kind"] == "rect":
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
        w = np.outer(wx, wy)
        patch = S[i0:i1, j0:j1]
        if p["sign"] > 0:
            np.maximum(patch, w, out=patch)
        else:
            np.minimum(patch, 1.0 - w, out=patch)
        return
    if not p["dabs"]:
        return
    sx, sy, h = p["size_x"], p["size_y"], p["h"]
    rx, ry = R * sx, R * sy
    d = np.asarray(p["dabs"], dtype=np.float64)
    cxs, cys = d[:, 0] * sx, d[:, 1] * sy
    i0 = int(np.searchsorted(xw, cxs - rx, "left").min())
    i1 = int(np.searchsorted(xw, cxs + rx, "right").max())
    j0 = int(np.searchsorted(yw, cys - ry, "left").min())
    j1 = int(np.searchsorted(yw, cys + ry, "right").max())
    if i1 <= i0 or j1 <= j0:
        return
    deposit = np.zeros((i1 - i0, j1 - j0))
    for (cu, cv), cx, cy in zip(p["dabs"], cxs, cys):
        a0, a1 = np.searchsorted(xw, cx - rx, "left"), np.searchsorted(xw, cx + rx, "right")
        b0, b1 = np.searchsorted(yw, cy - ry, "left"), np.searchsorted(yw, cy + ry, "right")
        if a1 <= a0 or b1 <= b0:
            continue
        du = (xw[a0:a1] / sx - cu)[:, None]
        dv = (yw[b0:b1] / sy - cv)[None, :]
        rho = np.sqrt(du * du + dv * dv) / R
        deposit[a0 - i0:a1 - i0, b0 - j0:b1 - j0] += _profile_arr(rho, h)
    deposit *= p["q"] * p["w"]
    patch = S[i0:i1, j0:j1]
    if p["sign"] > 0:
        np.minimum(patch + deposit, 1.0, out=patch)
    else:
        np.maximum(patch - deposit, 0.0, out=patch)


def selection_grid(ops, xw, yw, world, feather_ms=0.0, feather_st=0.0, compiled=None):
    """Selection intensity S on the grid xw x yw (warped, ascending), shaped (len(xw), len(yw)), in [0, 1].
    Pass `compiled` (from `compile_ops`) to skip the interpretation of `ops`."""
    np = _np()
    xw = np.asarray(xw, dtype=np.float64)
    yw = np.asarray(yw, dtype=np.float64)
    fx, fy = feather_axes(feather_ms, feather_st)
    S = np.zeros((len(xw), len(yw)))
    for p in (compiled if compiled is not None else compile_ops(ops, world)):
        add_op_to_selection(S, p, xw, yw, fx, fy)
    return S


def step_gain_grid(ops, params, xw, yw, world, cache=None):
    """The contribution in dB of ONE step (or of the pending selection at the live values): gain * S,
    S taken with the feathers of `params`. A step whose gain is 0 costs nothing."""
    np = _np()
    gain, fms, fst = step_values(params)
    if gain == 0.0:
        return np.zeros((len(xw), len(yw)))
    S = selection_grid(None, xw, yw, world, fms, fst, compiled=compile_ops(ops, world, cache))
    S *= gain
    return S


def gain_grid(steps, xw, yw, world, draft_ops=None, live=None, cache=None):
    """G in dB on the grid xw x yw (warped, ascending), shaped (len(xw), len(yw)):
    sum of gain_s * S_s over `steps` [(ops, params)], plus live gain * S_draft for `draft_ops`.
    `cache` (a dict) keeps the compiled primitives per op id."""
    np = _np()
    xw = np.asarray(xw, dtype=np.float64)
    yw = np.asarray(yw, dtype=np.float64)
    grid = np.zeros((len(xw), len(yw)))
    for ops, params in steps:
        grid += step_gain_grid(ops, params, xw, yw, world, cache)
    if draft_ops:
        grid += step_gain_grid(draft_ops, live, xw, yw, world, cache)
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


def stft_gain_block_fn(steps, draft_ops, live, world, sr, n, k, cache=None):
    """The `gain_block_fn` for `dsp.process`: linear gain (nb, N/2 + 1) for frames j0..j1-1.
    Cell (j, bin b >= 1) is evaluated at (jH/sr, b*sr/N); the DC bin copies bin 1. `steps` are the
    committed steps [(ops, params)]; `draft_ops` + `live` the pending selection at the current values
    (both may be empty / None)."""
    np = _np()
    h = int(math.floor(n / float(k) + 0.5))
    steps = [(list(ops), dict(params)) for ops, params in steps]

    def fn(j0, j1):
        xw, yw = stft_grid_axes(world, sr, n, h, j0, j1)
        g = gain_grid(steps, xw, yw, world, draft_ops, live, cache)
        full = np.empty((j1 - j0, n // 2 + 1))
        full[:, 1:] = g
        full[:, 0] = g[:, 0]
        return to_linear(full)

    return fn

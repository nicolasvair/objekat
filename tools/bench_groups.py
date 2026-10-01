#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Open groups under scroll and zoom — what a few hundred pieces cost, flat, grouped, nested, selected.

A question this was written to answer: is it worth drawing an open group's children (and its
sub-groups, and its SELECTED clips) in the timeline's batched Canvas instead of one SwiftUI view
each? No verdict here, only numbers taken the same way in every situation; the thresholds live
with whoever reads them (see `--ratios`).

    # 1. a RELEASE build, in UI MODE (never --headless: nothing is drawn there, nothing would be
    #    measured; Debug draws the timeline up to ×40 slower, so a Debug run is refused)
    objekat.app/Contents/MacOS/objekat --api --no-recent --socket=/tmp/cc501/rel.sock

    # 2. measure, keep the result (about 6-8 minutes for S0..S7, some 15-20 more for S8 and the
    #    tool scenarios)
    ./bench_groups.py /tmp/cc501/rel.sock --label base --out base.json
    ./bench_groups.py /tmp/cc501/rel.sock --only S0,S2,S3 --repeat 5 --label quick
    ./bench_groups.py /tmp/cc501/rel.sock --only tools --label tools      # E6.0: every `@tool` scenario

    # 3. compare two runs, a whole table of runs, or read a run's ratios against the flat case
    ./bench_groups.py --compare base.json after.json
    ./bench_groups.py --table base1.json base2.json after.json
    ./bench_groups.py --ratios base.json

Hands off the trackpad and the mouse while it runs: every gesture is a synthetic event, and a step
that saw a real one is flagged `contaminated` (and its numbers are not to be trusted).

The window is fixed at 1400×900 where `debug.resize_window` exists (Debug only). In Release it
cannot be: the window keeps the size it has, and the viewport actually measured is written in the
result — compare only runs that share it.

Scenarios — N pieces of 0.5 s cut out of ONE 300 s noise file (generated in a temporary directory,
outside the repository), one fresh project per scenario:

    S0  600 plain clips, 12 lanes of 50 (no group at all)
    S1  the same 600 in ONE group, closed (the witness)
    S2  the group open
    S3  the group open, its 600 children selected (⌘A inside it)
    S4  nested: 12 sub-groups of 50 (group_lanes), the outer one open, the sub-groups closed
    S5  nested, everything open
    S6  nested (outer open, sub-groups closed), ONE sub-group selected, then ⌘A → the 12 selected
    S7  nested, everything open, ONE piece selected, then ⌘A → the 50 of its sub-group selected

Steps, each from a view of its own put there by `view.set`, repeated `--repeat` times (3), the
MEDIAN of each metric kept:

    scroll_right     3000 px in 2 s from pps 100
    zoom_in          ×4 from pps 100
    zoom_out_wide    ×0.25 from pps 20 — ends near 5 pps, nearly every piece in the window: the
                     step where SwiftUI pays for what it holds
    scroll_wide      600 px in 1 s from pps 5

Tools and colour (E6.0) — the situations that put EVERY block on the rich SwiftUI path, which the
batched Canvas does not cover. They need `tool.set`, `object.set_color` (and `view.state.hover` for
the landing check); an older build is refused with a clear message:

    S8        600 plain clips, every one given a custom colour (`object.set_color`): rich reason `color`
    S0@T      S0 with the tool T armed (LOCKED, as ⇧+key arms it) — T is volume, pan, aux or stem
    S3@T      S3 (600 children selected, group open) with the tool T armed
    `--only tools` selects every `@T` scenario, `--only nav` the eight of the first table.
    Under Volume / Pan / Aux only the block AIMED AT (`tool_hover`) and the blocks a viewport edge
    can cut (`tool_span`, at most ~2 per lane on screen) are rich; the rest is the Canvas's. The old
    regime — every visible clip rich, `rich_reasons.tool = V` — is `debug.force_rich_tools true`.
    Under Stem only the HOVERED block goes rich (`stem_hover`, clip or group), so the sweep below
    is what makes it move.

Two more steps, run on S0, S3, S8 and every `@T` scenario (S0 / S3 with the selection tool are the
references for the `@T` ones):

    hover_sweep      `input.hover` laid on one visible clip after the other (--hover-moves, default
                     120, one every --hover-interval-ms, default 16 — the pointer's own pace), from
                     pps 100: every move changes the block aimed at, hence what a tool's hover
                     re-evaluates. Contaminated when a real input event was seen, or when the
                     pointer is not where the last move put it (a real mouse over the timeline).
    tool_switch      (`@T` only) the selection tool, then T armed, then the selection tool again,
                     each followed by `wait_idle`, under ONE frame recording: what the SWITCH costs
                     (600 blocks leaving the Canvas and coming back). Read busy total / frame max.

Each `@T` scenario also checks, before measuring, that five synthetic hovers LAND (`view.state.hover`
names the block aimed at) and prints it as `hover landed n/5` (n/a under Aux, whose hover is a
send knob). `perf.census` is read at pps 5 with the tool armed: the setup line carries the
`rich_reasons` and the ForEach total.

NOT measured: DRAGGING a block (`input.drag` does not exist — TODO, see docs/command_api.md): the
`preview` / `spill` rich reasons cannot be put on screen by a script, so a drag has to be felt by hand.
"""

import argparse, json, os, shutil, statistics, sys, tempfile, time
import wave

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError
from bench_navigation import METRICS, dig

N_PIECES = 600
PIECE_S = 0.5
LANES = 12
WINDOW = (1400, 900)
FIXED_BLOCK = 121.5

STEPS = [
    ("scroll_right",  "input.scroll", {"direction": "right", "distance_px": 3000, "duration_ms": 2000},
     {"pps": 100, "block_height": FIXED_BLOCK, "scroll_x": 0, "scroll_y": 0}),
    ("zoom_in",       "input.zoom",   {"axis": "horizontal", "factor": 4, "duration_ms": 800},
     {"pps": 100, "block_height": FIXED_BLOCK, "scroll_x": 0, "scroll_y": 0}),
    ("zoom_out_wide", "input.zoom",   {"axis": "horizontal", "factor": 0.25, "duration_ms": 800},
     {"pps": 20, "block_height": FIXED_BLOCK, "scroll_x": 0, "scroll_y": 0}),
    ("scroll_wide",   "input.scroll", {"direction": "right", "distance_px": 600, "duration_ms": 1000},
     {"pps": 5, "block_height": FIXED_BLOCK, "scroll_x": 0, "scroll_y": 0}),
]
STEP_NAMES = [s[0] for s in STEPS]
# The steps that are not a gesture of `input.*` (@see hover_sweep, tool_switch).
EXTRA_STEPS = ["hover_sweep", "tool_switch"]
ALL_STEP_NAMES = STEP_NAMES + EXTRA_STEPS
HOVER_START = {"pps": 100, "block_height": FIXED_BLOCK, "scroll_x": 0, "scroll_y": 0}
HOVER_MOVES = 120
HOVER_INTERVAL_MS = 16
TOOLS = ["volume", "pan", "aux", "stem"]

SCENARIOS = [
    ("S0", "600 plain, 12 lanes"),
    ("S1", "1 group, closed"),
    ("S2", "1 group, open"),
    ("S3", "open + 600 children selected"),
    ("S4", "12 sub-groups folded, outer open"),
    ("S5", "nested, all open"),
    ("S6", "sub-group selected + select-all (12)"),
    ("S7", "nested open + select-all in a sub-group (50)"),
    ("S8", "600 clips, every one coloured (rich: color)"),
] + [("%s@%s" % (base, tool), "%s, tool %s armed" % (desc, tool))
     for base, desc in (("S0", "600 plain"), ("S3", "open + 600 children selected"))
     for tool in TOOLS]

# Which scenarios run the hover sweep: the three references and every tool one.
HOVER_SCENARIOS = {"S0", "S3", "S8"}


def split_name(name):
    """'S3@pan' -> ('S3', 'pan'); 'S3' -> ('S3', None)."""
    base, _, tool = name.partition("@")
    return base, (tool or None)


# ----------------------------------------------------------------------------- the material

def make_noise_wav(directory, seconds=300, rate=22050):
    """A noise file whose level moves (a slow envelope per half second), so the pieces' waveforms
    are neither flat nor identical. Written once, outside the repository."""
    import numpy as np
    path = os.path.join(directory, "noise_%ds.wav" % seconds)
    rng = np.random.default_rng(501)
    n = seconds * rate
    env = np.repeat(rng.uniform(0.05, 1.0, size=int(seconds / PIECE_S) + 1), int(rate * PIECE_S))[:n]
    data = (rng.uniform(-1, 1, size=n) * env * 30000).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(data.tobytes())
    return path


# ----------------------------------------------------------------------------- the window

def set_window(c, w, h):
    """Fixes the document window's size through `debug.resize_window` — which exists in Debug
    ONLY. A Release build has no door onto the window's frame (System Events would need the
    Automation permission, which a script has no business asking for), so there the window is
    left as it is: the viewport actually measured is written in the result and printed per
    scenario, and two runs are comparable as long as it is the same. Returns how it was done,
    or None."""
    try:
        c.send("debug.resize_window", {"width": w, "height": h})
        return "debug.resize_window"
    except ObjekatError:
        print("  ! no debug.resize_window in this build: the window keeps its size (see 'viewport')",
              file=sys.stderr)
        return None


# ----------------------------------------------------------------------------- the scenarios

def settle(c, ms=1500):
    c.send("wait_idle", {"timeout_ms": 180000, "settle_ms": ms})


def explode(c, wav, group_lanes):
    clip = c.send("object.add", {"path": wav, "lane": 0, "start": 0})
    n = N_PIECES
    cuts = [round(i * PIECE_S, 6) for i in range(1, n)]
    lanes = [i % LANES for i in range(n)]
    r = c.send("object.explode", {"id": clip["id"], "cuts": cuts, "lanes": lanes,
                                   "group_lanes": group_lanes})
    return r


def build(c, wav, name, has_tools=True):
    """Lays the scenario's project down and returns (description of what is on screen, extras)."""
    base, tool = split_name(name)
    c.send("project.new")
    if has_tools:
        c.send("tool.set", {"tool": "selection"})   # a tool survives project.new
    settle(c, 500)
    if base == "S0":
        r = explode(c, wav, False)
        c.send("group.disband", {"id": r["group"]})
        c.send("selection.clear")
    elif base == "S8":
        r = explode(c, wav, False)
        c.send("group.disband", {"id": r["group"]})
        c.send("selection.clear")
        ids = [o["id"] for o in c.send("object.list")["objects"] if o["kind"] == "clip"]
        c.send("object.set_color", {"ids": ids, "color_index": 3})
        c.send("selection.clear")
    elif base in ("S1", "S2", "S3"):
        r = explode(c, wav, False)
        c.send("group.expand", {"id": r["group"], "expanded": base != "S1"})
        c.send("selection.clear")      # the explode leaves its group selected
        if base == "S3":
            c.send("selection.set", {"ids": [r["pieces"][0]["id"]]})
            c.send("selection.all")
    else:
        r = explode(c, wav, True)
        c.send("group.expand", {"id": r["group"], "expanded": True})
        open_subs = base in ("S5", "S7")
        for g in r["lane_groups"]:
            c.send("group.expand", {"id": g, "expanded": open_subs})
        c.send("selection.clear")
        if base == "S6":
            c.send("selection.set", {"ids": [r["lane_groups"][0]]})
            c.send("selection.all")
        elif base == "S7":
            c.send("selection.set", {"ids": [r["pieces"][0]["id"]]})
            c.send("selection.all")
    if tool:
        # Armed LOCKED, as ⇧ + the key arms it: it stays until the next `tool.set`.
        c.send("tool.set", {"tool": tool, "stem": 1} if tool == "stem" else {"tool": tool})
    settle(c, 2000)
    # The regime census is read from the WIDE view (pps 5: nearly every piece in the window), where
    # it says what the step that follows will pay for. It describes the visible blocks only.
    c.send("view.set", {"pps": 5, "block_height": FIXED_BLOCK, "scroll_x": 0, "scroll_y": 0})
    settle(c, 800)
    census = c.send("perf.census")
    sel = c.send("selection.get")
    regimes = census.get("regimes") or {}
    return {"objects_on_screen": census.get("objects_total"),
            "selected": sel.get("count"),
            "max_depth": census.get("max_group_depth"),
            "tool": tool or "selection",
            "regimes": regimes,
            # The E0 census: why the rich blocks are rich, and the SwiftUI layers' element count.
            "rich_reasons": {k: v for k, v in (regimes.get("rich_reasons") or {}).items() if v},
            "foreach_total": regimes.get("foreach_total"),
            "foreach_layers": regimes.get("foreach_layers")}


def regimes_text(regimes):
    """One short line for the setup print: the visible blocks by regime (@see
    `Shared/TimelineRegimeMeter.swift`). A build without `regimes` in its census prints 'n/a'."""
    if not regimes:
        return "regimes n/a"
    text = ("visible: %s clips canvas / %s rich, %s groups canvas / %s rich, group bands %s canvas / %s rich"
            % (regimes["clips_canvas"], regimes["clips_rich"], regimes["groups_canvas"],
               regimes["groups_rich"], regimes["group_bands_canvas"], regimes["group_bands_rich"]))
    reasons = {k: v for k, v in (regimes.get("rich_reasons") or {}).items() if v}
    if reasons:
        text += "; rich because " + ", ".join("%s %d" % kv for kv in sorted(reasons.items()))
    if regimes.get("foreach_total") is not None:
        text += "; ForEach elements %s" % regimes["foreach_total"]
    return text


def measure_step(c, name, runner, start, repeat):
    """`repeat` CLEAN runs from the same starting view, the median of each metric. A run that
    saw a real input event (a hand on the trackpad or the mouse) is thrown away and done again,
    up to 3 extra times per run wanted; if clean runs are still missing the contaminated ones
    fill in, and the step says so. `runner()` does one run and answers what an `input.*`
    gesture answers (`frames`, `contaminated`, `build`, and optionally `view_before` /
    `view_after` / `settle_ms`) — @see gesture, hover_sweep, tool_switch."""
    runs, thrown = [], 0
    for _ in range(repeat * 4):
        if len([x for x in runs if not x["contaminated"]]) >= repeat:
            break
        c.send("view.set", start)
        r = runner()
        vb, va = r.get("view_before") or {}, r.get("view_after") or {}
        run_ = {"frames": r["frames"], "contaminated": r["contaminated"], "build": r.get("build"),
                "dx": (va.get("scroll_x", 0) or 0) - (vb.get("scroll_x", 0) or 0),
                "pps_after": va.get("pps"), "settle_ms": r.get("settle_ms")}
        runs.append(run_)
    clean = [x for x in runs if not x["contaminated"]]
    thrown = len(runs) - len(clean)
    used = clean if len(clean) >= repeat else clean + [x for x in runs if x["contaminated"]][:repeat - len(clean)]
    step = {"contaminated": len(clean) < repeat, "thrown_runs": thrown, "build": runs[-1]["build"]}
    for mlabel, path in METRICS:
        vals = [dig(x["frames"], path) for x in used]
        vals = [v for v in vals if v is not None]
        step[mlabel] = statistics.median(vals) if vals else None
    step["fps_runs"] = [round(dig(x["frames"], ("fps_mean",)) or 0, 1) for x in used]
    step["moved_px"] = statistics.median([x["dx"] for x in used])
    step["pps_end"] = statistics.median([x["pps_after"] or 0 for x in used])
    return step


def gesture(c, cmd, params):
    """The runner of the four navigation steps: one `input.*` gesture."""
    return lambda: c.send(cmd, params)


def hover_targets(c, limit=None):
    """Where to lay the pointer: the centres of the visible clips, at HOVER_START's view (pps 100,
    scroll 0), in viewport points, ordered by time then row — each one a block, so that every move
    changes the block aimed at. Answers [(id, x, y)]."""
    c.send("view.set", HOVER_START)
    vs = c.send("view.state")
    vsnap = vs.get("vsnap") or {}
    ruler, step = vsnap.get("ruler_h", 50), vsnap.get("lane_step", FIXED_BLOCK + 4)
    vw, vh = vs["viewport_w"], vs["viewport_h"]
    pps = HOVER_START["pps"]
    out = []
    for o in c.send("object.list")["objects"]:
        if o["kind"] != "clip":
            continue
        x = o["start"] * pps + o["duration"] * pps / 2
        y = ruler + o["display_lane"] * step + FIXED_BLOCK / 2
        if 6 < x < vw - 6 and y < vh - 6:
            out.append((o["start"], o["display_lane"], o["id"], x, y))
    out.sort()
    return [(i, x, y) for _, _, i, x, y in out][:limit]


def hover_landed(c, targets, tool):
    """Before measuring: do five synthetic hovers LAND? Answers 'n/5', or None where the tool's
    hover is not a block (Aux: a send knob) or the build has no `view.state.hover`."""
    if tool == "aux":
        return None
    picks = targets[:5]
    ok = 0
    for i, x, y in picks:
        c.send("input.hover", {"x": x, "y": y})
        time.sleep(0.15)
        h = c.send("view.state.hover")
        if (h.get("hovered_id") or "").upper() == i.upper():
            ok += 1
    c.send("input.hover", {"leave": True})
    return "%d/%d" % (ok, len(picks))


def hover_runner(c, targets, moves, interval_ms):
    """One hover sweep under ONE frame recording: `moves` `input.hover` calls, one block after the
    other (cycling through the visible ones), paced at the pointer's own interval. Contaminated by a
    real input event, or when the pointer is not where the last move left it."""
    def run_once():
        c.send("perf.frames.start")
        last = None
        t_next = time.time()
        for k in range(moves):
            _, x, y = targets[k % len(targets)]
            c.send("input.hover", {"x": x, "y": y})
            last = (x, y)
            t_next += interval_ms / 1000.0
            time.sleep(max(0.0, t_next - time.time()))
        h = c.send("view.state.hover")
        r = c.send("perf.frames.stop")
        pos = (h.get("viewport") or {})
        moved_away = (not pos) or abs(pos.get("x", -1) - last[0]) > 1.5 or abs(pos.get("y", -1) - last[1]) > 1.5
        c.send("input.hover", {"leave": True})
        return {"frames": r["frames"], "build": r.get("build"),
                "contaminated": r.get("real_input_events", 0) > 0 or moved_away}
    return run_once


def tool_switch_runner(c, tool):
    """One arm-then-release under ONE frame recording: selection (the rest state), the tool armed,
    the selection tool again, each followed by a settled `wait_idle` — what the SWITCH costs, with
    every visible block leaving the Canvas for its rich view and coming back."""
    params = {"tool": tool, "stem": 1} if tool == "stem" else {"tool": tool}
    def run_once():
        c.send("tool.set", {"tool": "selection"})
        settle(c, 600)
        c.send("perf.frames.start")
        c.send("tool.set", params)
        settle(c, 600)
        c.send("tool.set", {"tool": "selection"})
        settle(c, 600)
        r = c.send("perf.frames.stop")
        # Put the tool back for whatever follows in this scenario.
        c.send("tool.set", params)
        settle(c, 600)
        return {"frames": r["frames"], "build": r.get("build"),
                "contaminated": r.get("real_input_events", 0) > 0}
    return run_once


def run(sock, label, repeat, only, allow_debug, resize, hover_moves=HOVER_MOVES,
        hover_interval_ms=HOVER_INTERVAL_MS):
    tmp = tempfile.mkdtemp(prefix="bench_groups_")
    try:
        wav = make_noise_wav(tmp)
        c = ObjekatClient(sock, timeout=600)
        c.connect()
        info = c.send("app.info")
        result = {"label": label, "when": time.strftime("%Y-%m-%d %H:%M:%S"), "repeat": repeat,
                  "pieces": N_PIECES, "scenarios": {}}
        if resize:
            result["window_by"] = set_window(c, *WINDOW)
            time.sleep(1.0)
        # E6.0 needs the harness commands (tool.set, object.set_color, view.state.hover): an older
        # build is refused up front rather than half-way through.
        def has(cmd):
            try:
                c.send("help", {"name": cmd})
                return True
            except ObjekatError:
                return False
        has_tools = has("tool.set") and has("object.set_color") and has("view.state.hover")
        wanted = [(n, d) for n, d in SCENARIOS if not only or n in only]
        if not has_tools and any(split_name(n)[1] or split_name(n)[0] == "S8" for n, _ in wanted):
            print("!! this build has no tool.set / object.set_color / view.state.hover: "
                  "S8 and the @tool scenarios need them (run --only S0,...,S7)", file=sys.stderr)
            return None
        result["has_tools"] = has_tools
        for name, desc in wanted:
            base, tool = split_name(name)
            print("%s  %s" % (name, desc))
            t0 = time.time()
            setup = build(c, wav, name, has_tools)
            vs = c.send("view.state")
            viewport = [vs.get("viewport_w"), vs.get("viewport_h")]
            print("   setup %.1fs: %s objects on screen, %s selected, depth %s, viewport %sx%s"
                  % (time.time() - t0, setup["objects_on_screen"], setup["selected"], setup["max_depth"],
                     viewport[0], viewport[1]))
            print("   regimes at pps 5: %s" % regimes_text(setup.get("regimes")))
            if result.setdefault("viewport", viewport) != viewport:
                print("!! the window changed size during the run (%s -> %s): the numbers before and "
                      "after are not comparable" % (result["viewport"], viewport), file=sys.stderr)
                result["viewport_changed"] = True
            scen = {"desc": desc, "setup": setup, "steps": {}}
            todo = [(sname, gesture(c, cmd, params), start) for sname, cmd, params, start in STEPS]
            if has_tools and (base in HOVER_SCENARIOS):
                targets = hover_targets(c)
                if targets:
                    landed = hover_landed(c, targets, tool) if has_tools else None
                    setup["hover_landed"] = landed
                    setup["hover_targets"] = len(targets)
                    print("   hover: %d visible clips to aim at, landed %s"
                          % (len(targets), landed if landed else "n/a"))
                    todo.append(("hover_sweep", hover_runner(c, targets, hover_moves, hover_interval_ms),
                                 HOVER_START))
                else:
                    print("   ! no visible clip to hover at pps 100: hover_sweep skipped", file=sys.stderr)
            if tool:
                todo.append(("tool_switch", tool_switch_runner(c, tool), HOVER_START))
            for sname, runner, start in todo:
                step = measure_step(c, sname, runner, start, repeat)
                if step["build"] != "release" and not allow_debug:
                    print("!! build is %r, not release: refusing to go on (Debug is up to ×40 slower)"
                          % step["build"], file=sys.stderr)
                    return None
                result["build"] = step["build"]
                scen["steps"][sname] = step
                print("   %-14s fps %6.1f   p95 %7.2f ms   p99 %7.2f   late %3s   busy %8.1f ms   moved %5.0f px  pps_end %6.2f  %s%s"
                      % (sname, step["fps"] or 0, step["frame p95"] or 0, step["frame p99"] or 0,
                         step["late frames"], step["busy total"] or 0, step["moved_px"], step["pps_end"],
                         step["fps_runs"],
                         ("   CONTAMINATED" if step["contaminated"] else "")
                         + ("   (%d run(s) redone)" % step["thrown_runs"] if step["thrown_runs"] else "")))
            result["scenarios"][name] = scen
            if tool:
                c.send("tool.set", {"tool": "selection"})
        c.send("project.new")
        if has_tools:
            c.send("tool.set", {"tool": "selection"})
        c.send("view.set", STEPS[0][3])
        return result
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# ----------------------------------------------------------------------------- reading results

def load(path):
    with open(path) as f:
        return json.load(f)


def compare(a, b):
    print("A = %s (%s, %s)   B = %s (%s, %s)"
          % (a["label"], a.get("build"), a.get("when"), b["label"], b.get("build"), b.get("when")))
    if a.get("build") != b.get("build"):
        print("!! different builds (%s / %s): Debug vs Release alone is ×40" % (a.get("build"), b.get("build")))
    if a.get("viewport") != b.get("viewport") or a.get("viewport_changed") or b.get("viewport_changed"):
        print("!! the viewports differ or moved during a run (%s / %s): the figures do not compare"
              % (a.get("viewport"), b.get("viewport")))
    worst = []
    for sname, _ in SCENARIOS:
        sa, sb = a["scenarios"].get(sname), b["scenarios"].get(sname)
        if not sa or not sb:
            continue
        print("\n%s  %s" % (sname, sa["desc"]))
        for step in ALL_STEP_NAMES:
            ta, tb = sa["steps"].get(step), sb["steps"].get(step)
            if not ta or not tb:
                continue
            flag = "   (contaminated)" if ta["contaminated"] or tb["contaminated"] else ""
            print("  %-14s%s" % (step, flag))
            for mlabel, _ in METRICS:
                va, vb = ta.get(mlabel), tb.get(mlabel)
                if va is None or vb is None:
                    continue
                ratio = ("×%.2f" % (vb / va)) if va else ("—" if vb == 0 else "new")
                print("    %-12s %10.2f %10.2f   %s" % (mlabel, va, vb, ratio))
            if ta["fps"] and tb["fps"] and ta["frame p95"] and tb["frame p95"]:
                worst.append((abs(tb["fps"] / ta["fps"] - 1), abs(tb["frame p95"] / ta["frame p95"] - 1),
                              "%s/%s" % (sname, step)))
    if worst:
        print("\nreport: largest fps change %.1f %% (%s), largest p95 change %.1f %% (%s); "
              "median fps change %.1f %%, median p95 change %.1f %%"
              % (100 * max(worst)[0], max(worst)[2], 100 * max(worst, key=lambda w: w[1])[1],
                 max(worst, key=lambda w: w[1])[2],
                 100 * statistics.median(w[0] for w in worst), 100 * statistics.median(w[1] for w in worst)))


def table(paths):
    runs = [load(p) for p in paths]
    head = "%-4s %-14s" % ("", "step") + "".join("  %-22s" % r["label"][:22] for r in runs)
    for metric, title in (("fps", "fps (mean)"), ("frame p95", "frame p95 (ms)")):
        print("\n" + title)
        print(head)
        for sname, _ in SCENARIOS:
            for step in ALL_STEP_NAMES:
                cells = []
                for r in runs:
                    t = (r["scenarios"].get(sname) or {}).get("steps", {}).get(step)
                    cells.append("%7.1f%s" % (t[metric], "*" if t["contaminated"] else " ") if t else "     - ")
                if all(x.strip() == "-" for x in cells):
                    continue
                print("%-4s %-14s" % (sname, step) + "".join("  %-22s" % x for x in cells))


def ratios(path):
    """Each scenario against S0 (the flat case), step by step: the figures the decision reads."""
    r = load(path)
    base = r["scenarios"].get("S0")
    print("%s (%s): fps and p95 of each scenario against S0, and against S2 (the open group)\n" % (r["label"], r.get("build")))
    print("%-4s %-14s %8s %9s %8s %9s   %8s %9s" % ("", "step", "fps", "fps/S0", "p95", "p95/S0", "fps/S2", "p95/S2"))
    s2 = r["scenarios"].get("S2")
    for sname, _ in SCENARIOS:
        s = r["scenarios"].get(sname)
        if not s:
            continue
        for step in ALL_STEP_NAMES:
            t = s["steps"].get(step)
            b0 = base["steps"].get(step) if base else None
            b2 = s2["steps"].get(step) if s2 else None
            f0 = "%8.2f" % (t["fps"] / b0["fps"]) if b0 and b0["fps"] else "       -"
            p0 = "%9.2f" % (t["frame p95"] / b0["frame p95"]) if b0 and b0["frame p95"] else "        -"
            f2 = "%8.2f" % (t["fps"] / b2["fps"]) if b2 and b2["fps"] else "       -"
            p2 = "%9.2f" % (t["frame p95"] / b2["frame p95"]) if b2 and b2["frame p95"] else "        -"
            print("%-4s %-14s %8.1f %s %8.2f %s   %s %s%s"
                  % (sname, step, t["fps"], f0, t["frame p95"], p0, f2, p2,
                     "  CONTAMINATED" if t["contaminated"] else ""))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("socket", nargs="?")
    ap.add_argument("--label", default="run")
    ap.add_argument("--out")
    ap.add_argument("--repeat", type=int, default=3)
    ap.add_argument("--only", help="comma-separated scenarios, e.g. S0,S2,S3 or S0@volume; "
                                   "`tools` = every @tool scenario, `nav` = S0..S7")
    ap.add_argument("--hover-moves", type=int, default=HOVER_MOVES, help="input.hover calls per sweep (default 120)")
    ap.add_argument("--hover-interval-ms", type=float, default=HOVER_INTERVAL_MS,
                    help="pause between two hover moves (default 16)")
    ap.add_argument("--allow-debug", action="store_true", help="accept a Debug build (numbers are NOT comparable with Release)")
    ap.add_argument("--no-resize", action="store_true", help="leave the window as it is")
    ap.add_argument("--compare", nargs=2, metavar=("A.json", "B.json"))
    ap.add_argument("--table", nargs="+", metavar="RUN.json")
    ap.add_argument("--ratios", metavar="RUN.json")
    args = ap.parse_args()
    if args.compare:
        compare(load(args.compare[0]), load(args.compare[1]))
        return 0
    if args.table:
        table(args.table)
        return 0
    if args.ratios:
        ratios(args.ratios)
        return 0
    if not args.socket:
        ap.print_usage()
        return 2
    only = None
    if args.only:
        only = set()
        for token in args.only.split(","):
            if token == "tools":
                only |= {n for n, _ in SCENARIOS if "@" in n}
            elif token == "nav":
                only |= {n for n, _ in SCENARIOS if n[1:].isdigit() and n != "S8"}
            else:
                only.add(token)
        unknown = only - {n for n, _ in SCENARIOS}
        if unknown:
            ap.error("unknown scenario(s): %s" % ", ".join(sorted(unknown)))
    result = run(args.socket, args.label, max(1, args.repeat), only, args.allow_debug, not args.no_resize,
                 args.hover_moves, args.hover_interval_ms)
    if result is None:
        return 1
    if args.out:
        with open(args.out, "w") as f:
            json.dump(result, f, indent=1)
        print("-> %s" % args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())

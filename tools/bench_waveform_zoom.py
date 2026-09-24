#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Waveform zoom benchmark — a horizontal scroll measured at a ladder of horizontal zooms, to find
the pps band where the timeline gives way and to COMPARE two builds on it.

Why a ladder: the waveform drawing changes regime with the zoom. Below
`WaveformCache.sampleModeThreshold` (3 000 px/s at the time of writing) it reads mipmap peaks
(100 or 1 000 peaks/s); above it, it decodes PCM regions from the wav and builds a min/max
envelope per pixel. A slowdown felt "zoomed in strongly, but not at max zoom" lives somewhere on
that ladder, and a single-zoom bench cannot say where.

No thresholds and no verdict, in the spirit of `bench_navigation.py`: a number from here means
something only next to another one taken the same way.

    # 1. an instance in UI MODE (never --headless: nothing is drawn there, so nothing would be
    #    measured), on its OWN copy of the project folder (two builds on one folder invalidate each
    #    other's .wfc cache at every launch). Debug draws up to x40 slower: compare like with like.
    #    (`--project=` is honoured by --headless only: in UI mode the script opens it, `--open`)
    objekat.app/Contents/MacOS/objekat --api --no-recent --socket=/tmp/o.sock

    # 2. measure
    ./bench_waveform_zoom.py /tmp/o.sock --open /copy/p.objekat.json --label release-base --out base.json
    ./bench_waveform_zoom.py /tmp/o.sock --label open-groups --expand-groups all --out open.json

    # 3. compare (any number of runs, one column each)
    ./bench_waveform_zoom.py --compare base.json patched.json [more.json ...]

Per zoom level (`--levels`, px/s):
  1. `view.set` pps + `--block-height` + `--scroll-y`, scroll_x placed so that `--at` seconds sits
     at the viewport's left edge;
  2. wait until the waveform cache is quiet (`perf.waveforms`: `in_flight == 0` and the decode
     counters unchanged over a few polls) — what the new view needed is decoded before measuring;
  3. `--repeat` times, from that same view: one `input.scroll` to the right of `--distance-px`
     over `--duration-ms` (through the hand's own path), and with `--back` the same distance back
     to the left. Each pass records the frame report and the delta of the cache counters
     (region decodes / evictions / decode seconds, mipmaps computed / read from disk).
The median of each frame metric over the passes is kept; cache deltas are kept both for the
FIRST pass (cold: regions not decoded yet) and summed over all passes.

`--expand-groups all|<uuid,uuid>` opens groups first (`group.expand`, not an undoable gesture), so
their children's lanes and the groups' composite band are on screen.

Hands off the trackpad and the mouse while it runs: a pass that saw a real event is flagged
`contaminated` (and a level with a contaminated pass says so in the table).
"""

import argparse, json, os, statistics, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient

DEFAULT_LEVELS = [30, 80, 150, 400, 900, 2000, 2900, 3100, 5000, 10000, 20000, 60000, 200000]

# (label, path into the frame report)
FRAME_METRICS = [
    ("fps",         ("fps_mean",)),
    ("frame p50",   ("frame_ms", "p50")),
    ("frame p95",   ("frame_ms", "p95")),
    ("frame max",   ("frame_ms", "max")),
    ("late",        ("late_frames",)),
    ("hitch ms/s",  ("hitch_ms_per_s",)),
    ("busy p95",    ("main_busy_ms", "p95")),
    ("busy max",    ("main_busy_ms", "max")),    # a few huge run-loop turns hide under a small p95
    ("busy total",  ("main_busy_total_ms",)),
]

# perf.waveforms counters whose DELTA over a pass is recorded
WF_COUNTERS = ["region_decodes", "region_evictions", "region_decode_seconds",
               "mipmaps_computed", "mipmap_compute_seconds", "mipmaps_read_from_disk"]

# what --compare prints, per level: (label, key in the level record, format)
COMPARE_ROWS = [
    ("fps",              "fps",                  "%.1f"),
    ("frame p50 ms",     "frame p50",            "%.1f"),
    ("frame p95 ms",     "frame p95",            "%.1f"),
    ("frame max ms",     "frame max",            "%.0f"),
    ("late frames",      "late",                 "%.0f"),
    ("hitch ms/s",       "hitch ms/s",           "%.0f"),
    ("busy p95 ms",      "busy p95",             "%.1f"),
    ("busy max ms",      "busy max",             "%.0f"),
    ("busy total ms",    "busy total",           "%.0f"),
    ("decodes (1st)",    "wf1.region_decodes",   "%.0f"),
    ("evictions (1st)",  "wf1.region_evictions", "%.0f"),
    ("decode s (1st)",   "wf1.region_decode_seconds", "%.3f"),
    ("decodes (all)",    "wf.region_decodes",    "%.0f"),
    ("evictions (all)",  "wf.region_evictions",  "%.0f"),
    ("decode s (all)",   "wf.region_decode_seconds", "%.3f"),
    ("settle decodes",   "settle.region_decodes", "%.0f"),
    ("settle wait ms",   "settle_wait_ms",       "%.0f"),
]


def dig(d, path):
    for k in path:
        if d is None:
            return None
        d = d.get(k)
    return d


def wf_delta(a, b):
    return {k: (b.get(k) or 0) - (a.get(k) or 0) for k in WF_COUNTERS}


def wait_cache_quiet(c, timeout_s=60.0, polls=4, interval_s=0.1):
    """`in_flight == 0` AND the decode/compute counters unchanged over `polls` consecutive
    readings: a region is decoded on draw, so the drawing has to have caught up too."""
    deadline = time.time() + timeout_s
    prev, stable, snap = None, 0, None
    t0 = time.time()
    while time.time() < deadline:
        snap = c.send("perf.waveforms")
        key = tuple(snap.get(k) for k in ("region_decodes", "mipmaps_computed", "mipmaps_read_from_disk"))
        if snap.get("in_flight", 0) == 0 and key == prev:
            stable += 1
            if stable >= polls:
                return snap, (time.time() - t0) * 1000.0, True
        else:
            stable = 0
        prev = key
        time.sleep(interval_s)
    return snap, (time.time() - t0) * 1000.0, False


def expand_groups(c, spec):
    objs = c.send("object.list")["objects"]
    groups = [o for o in objs if o.get("kind") == "group"]
    if spec != "all":
        wanted = set(s.strip().upper() for s in spec.split(",") if s.strip())
        groups = [g for g in groups if g["id"].upper() in wanted]
    opened = []
    # parents before children: a child group only has a lane once its parent is open
    for g in sorted(groups, key=lambda g: g.get("depth", 0)):
        r = c.send("group.expand", {"id": g["id"], "expanded": True})
        opened.append({"id": g["id"], "name": g.get("name"), "expanded": r.get("expanded")})
    c.send("wait_idle", {"timeout_ms": 10000})
    return opened


def one_pass(c, direction, args):
    before = c.send("perf.waveforms")
    r = c.send("input.scroll", {"direction": direction, "distance_px": args.distance_px,
                                "duration_ms": args.duration_ms})
    after = c.send("perf.waveforms")
    vb, va = r.get("view_before") or {}, r.get("view_after") or {}
    return {"direction": direction, "frames": r["frames"], "contaminated": r["contaminated"],
            "settle_ms": r.get("settle_ms"), "build": r.get("build"),
            "moved_px": (va.get("scroll_x") or 0) - (vb.get("scroll_x") or 0),
            "wf": wf_delta(before, after)}


def measure_level(c, pps, args):
    start = {"pps": pps, "block_height": args.block_height, "scroll_y": args.scroll_y,
             "scroll_x": max(0.0, args.at * pps)}
    rec = {"pps": pps}
    s0 = c.send("perf.waveforms")
    view = c.send("view.set", start)
    s1, waited, quiet = wait_cache_quiet(c)
    rec["settle"] = wf_delta(s0, s1)
    rec["settle_wait_ms"] = waited
    rec["settle_quiet"] = quiet
    rec["view"] = {k: view.get(k) for k in ("pps", "block_height", "scroll_x", "scroll_y",
                                             "visible_time", "viewport_w", "viewport_h", "content_w")}
    passes = []
    for i in range(args.repeat):
        if i > 0:
            c.send("view.set", start)
            wait_cache_quiet(c, timeout_s=10)
        passes.append(one_pass(c, "right", args))
        if args.back:
            passes.append(one_pass(c, "left", args))
    rec["passes"] = passes
    rec["build"] = passes[0].get("build")
    rec["contaminated"] = any(p["contaminated"] for p in passes)
    for label, path in FRAME_METRICS:
        vals = [dig(p["frames"], path) for p in passes]
        vals = [v for v in vals if v is not None]
        rec[label] = statistics.median(vals) if vals else None
    first = [p for p in passes if p is passes[0] or (args.back and p is passes[1])]
    rec["wf1"] = {k: sum(p["wf"][k] for p in first) for k in WF_COUNTERS}
    rec["wf"] = {k: sum(p["wf"][k] for p in passes) for k in WF_COUNTERS}
    rec["moved_px"] = statistics.median([abs(p["moved_px"]) for p in passes])
    return rec


def measure(args):
    c = ObjekatClient(args.socket, timeout=600)
    c.connect()
    if args.open:
        c.send("project.open", {"path": os.path.abspath(args.open)})
        c.send("wait_idle", {"timeout_ms": 60000, "settle_ms": 500})
    info = c.send("app.info")
    try:
        c.send("view.state")   # answers invalid_state in --headless, where nothing is drawn
    except Exception as e:
        sys.exit("no timeline to measure (is this instance --headless?): %s" % e)
    census = c.send("perf.census")
    wf = c.send("perf.waveforms")
    result = {"label": args.label, "when": time.strftime("%Y-%m-%d %H:%M:%S"),
              "project": info.get("project_path"), "objects": census.get("objects_total"),
              "sample_mode_threshold": wf.get("sample_mode_threshold"),
              "densities": wf.get("densities"),
              "params": {"levels": args.levels, "block_height": args.block_height,
                         "scroll_y": args.scroll_y, "at": args.at, "distance_px": args.distance_px,
                         "duration_ms": args.duration_ms, "repeat": args.repeat, "back": args.back,
                         "expand_groups": args.expand_groups},
              "levels": []}
    if args.expand_groups:
        result["expanded"] = expand_groups(c, args.expand_groups)
        result["objects_after_expand"] = c.send("perf.census").get("objects_total")
        print("opened %d group(s)" % len(result["expanded"]))
    if args.preload:
        c.send("waveform.preload")
        wait_cache_quiet(c, timeout_s=600)
    print("%-8s %6s %8s %8s %8s %5s %9s %9s %10s %8s %8s %8s"
          % ("pps", "fps", "p50", "p95", "max", "late", "busy p95", "busy max", "busy total",
             "dec(1st)", "evict", "dec s"))
    for pps in args.levels:
        rec = measure_level(c, pps, args)
        result["build"] = rec["build"]
        result["levels"].append(rec)
        print("%-8g %6.1f %8.1f %8.1f %8.0f %5.0f %9.1f %9.0f %10.0f %8d %8d %8.3f%s%s"
              % (pps, rec["fps"] or 0, rec["frame p50"] or 0, rec["frame p95"] or 0,
                 rec["frame max"] or 0, rec["late"] or 0, rec["busy p95"] or 0,
                 rec["busy max"] or 0, rec["busy total"] or 0,
                 rec["wf1"]["region_decodes"], rec["wf"]["region_evictions"],
                 rec["wf"]["region_decode_seconds"],
                 "   CONTAMINATED" if rec["contaminated"] else "",
                 "   (moved %.0f px)" % rec["moved_px"] if rec["moved_px"] < 0.8 * args.distance_px else ""))
    return result


def get_row(rec, key):
    if key not in rec and "." not in key:
        path = dict(FRAME_METRICS).get(key)          # a run saved before the metric existed
        if path and rec.get("passes"):
            vals = [v for v in (dig(p["frames"], path) for p in rec["passes"]) if v is not None]
            return statistics.median(vals) if vals else None
    if "." in key:
        a, b = key.split(".", 1)
        return (rec.get(a) or {}).get(b)
    return rec.get(key)


def compare(paths):
    runs = []
    for p in paths:
        with open(p) as f:
            runs.append(json.load(f))
    for i, r in enumerate(runs):
        print("[%d] %s — %s, %s objects, build %s, %s"
              % (i, r["label"], os.path.basename(r.get("project") or "?"), r.get("objects"),
                 r.get("build"), r.get("when")))
    builds = set(r.get("build") for r in runs)
    if len(builds) > 1:
        print("!! runs from different builds (%s): Debug vs Release alone is up to x40"
              % ", ".join(sorted(str(b) for b in builds)))
    params = [json.dumps(r.get("params"), sort_keys=True) for r in runs]
    if len(set(params)) > 1:
        print("!! runs taken with different parameters — compare with care")
    levels = []
    for r in runs:
        for rec in r["levels"]:
            if rec["pps"] not in levels:
                levels.append(rec["pps"])
    colw = 12
    for pps in sorted(levels):
        recs = [next((x for x in r["levels"] if x["pps"] == pps), None) for r in runs]
        flag = "   (contaminated)" if any(x and x.get("contaminated") for x in recs) else ""
        print("\n== %g px/s%s" % (pps, flag))
        print("  %-16s" % "" + "".join(("[%d]" % i).rjust(colw) for i in range(len(runs)))
              + ("   last/first" if len(runs) > 1 else ""))
        for label, key, fmt in COMPARE_ROWS:
            vals = [get_row(x, key) if x else None for x in recs]
            cells = "".join((fmt % v if v is not None else "—").rjust(colw) for v in vals)
            ratio = ""
            if len(vals) > 1 and vals[0] not in (None, 0) and vals[-1] is not None:
                ratio = "   x%.2f" % (vals[-1] / vals[0])
            print("  %-16s%s%s" % (label, cells, ratio))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("socket", nargs="?")
    ap.add_argument("--label", default="run")
    ap.add_argument("--open", metavar="PROJECT.json", help="project.open this file first")
    ap.add_argument("--out")
    ap.add_argument("--levels", type=lambda s: [float(x) for x in s.split(",")], default=DEFAULT_LEVELS,
                    help="comma-separated px/s (default: %s)" % ",".join(str(x) for x in DEFAULT_LEVELS))
    ap.add_argument("--block-height", type=float, default=80.0)
    ap.add_argument("--scroll-y", type=float, default=0.0)
    ap.add_argument("--at", type=float, default=300.0,
                    help="timeline second placed at the viewport's left edge before each pass (default 300)")
    ap.add_argument("--distance-px", type=float, default=3000.0)
    ap.add_argument("--duration-ms", type=float, default=2000.0)
    ap.add_argument("--repeat", type=int, default=3)
    ap.add_argument("--back", action="store_true", help="also scroll back left after each right pass")
    ap.add_argument("--expand-groups", metavar="all|UUID,UUID",
                    help="open these groups (or all of them) before measuring")
    ap.add_argument("--preload", action="store_true",
                    help="waveform.preload + wait before the first level (mipmaps, not regions)")
    ap.add_argument("--compare", nargs="+", metavar="RUN.json")
    args = ap.parse_args()
    if args.compare:
        compare(args.compare)
        return 0
    if not args.socket:
        ap.print_usage()
        return 2
    args.repeat = max(1, args.repeat)
    result = measure(args)
    if args.out:
        with open(args.out, "w") as f:
            json.dump(result, f, indent=1)
        print("-> %s" % args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())

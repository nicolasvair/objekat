#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Navigation benchmark — the same walk through the timeline, measured, to COMPARE two situations.

No thresholds and no verdict: a number from here means something only next to another one taken
the same way (50 objects against 500, a build against the next, Debug against Release).

    # 1. an instance in UI MODE with the project to measure (never --headless: nothing is drawn
    #    there, so nothing would be measured). Release unless Debug is what is being compared —
    #    the two differ by up to ×40 on the timeline's drawing.
    objekat.app/Contents/MacOS/objekat --api --no-recent --socket=/tmp/o.sock --project=/path/p.objekat.json

    # 2. measure, keep the result
    ./bench_navigation.py /tmp/o.sock --label before --out before.json
    #    … change something, relaunch …
    ./bench_navigation.py /tmp/o.sock --label after --out after.json

    # 3. compare
    ./bench_navigation.py --compare before.json after.json

The walk (every step through `input.*`, so through the hand's own path): scroll right, down, left,
up; zoom in and out horizontally (⇧ + swipe); zoom in and out vertically. Each step is repeated
`--repeat` times (default 3) from the same starting view, and the MEDIAN of each metric is kept —
a first cold pass (waveforms to compute) would otherwise weigh on the comparison.

Hands off the trackpad and the mouse while it runs: a step that saw a real event is flagged
`contaminated`, and the comparison says so.
"""

import argparse, json, os, statistics, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient

START = {"pps": 100, "block_height": 121.5, "scroll_x": 0, "scroll_y": 0}

# (name, command, params, starting view)
WALK = [
    ("scroll_right", "input.scroll", {"direction": "right", "distance_px": 3000, "duration_ms": 2000}, START),
    ("scroll_down",  "input.scroll", {"direction": "down",  "distance_px": 800,  "duration_ms": 1000}, START),
    ("scroll_left",  "input.scroll", {"direction": "left",  "distance_px": 3000, "duration_ms": 2000},
     dict(START, scroll_x=3000)),
    ("scroll_up",    "input.scroll", {"direction": "up",    "distance_px": 800,  "duration_ms": 1000},
     dict(START, scroll_y=800)),
    ("zoom_h_in",    "input.zoom",   {"axis": "horizontal", "factor": 4,    "duration_ms": 800}, START),
    ("zoom_h_out",   "input.zoom",   {"axis": "horizontal", "factor": 0.25, "duration_ms": 800},
     dict(START, pps=400)),
    ("zoom_v_in",    "input.zoom",   {"axis": "vertical",   "factor": 1.8,  "duration_ms": 600}, START),
    ("zoom_v_out",   "input.zoom",   {"axis": "vertical",   "factor": 0.55, "duration_ms": 600}, START),
]

# What a comparison reads, as (label, path into the frame report).
METRICS = [
    ("fps",          ("fps_mean",)),
    ("frame p50",    ("frame_ms", "p50")),
    ("frame p95",    ("frame_ms", "p95")),
    ("frame p99",    ("frame_ms", "p99")),
    ("frame max",    ("frame_ms", "max")),
    ("late frames",  ("late_frames",)),
    ("dropped",      ("dropped_frames_est",)),
    ("hitch ms/s",   ("hitch_ms_per_s",)),
    ("busy p95",     ("main_busy_ms", "p95")),
    ("busy total",   ("main_busy_total_ms",)),
]


def dig(d, path):
    for k in path:
        if d is None:
            return None
        d = d.get(k)
    return d


def measure(sock, label, repeat):
    c = ObjekatClient(sock, timeout=300)
    c.connect()
    info = c.send("app.info")
    census = c.send("perf.census")
    result = {"label": label, "when": time.strftime("%Y-%m-%d %H:%M:%S"),
              "project": info.get("project_path"), "objects": census.get("objects_total"),
              "steps": {}}
    for name, cmd, params, start in WALK:
        runs = []
        for _ in range(repeat):
            c.send("view.set", start)
            r = c.send(cmd, params)
            result["build"] = r.get("build")
            runs.append({"frames": r["frames"], "contaminated": r["contaminated"],
                         "settle_ms": r.get("settle_ms")})
        step = {"contaminated": any(x["contaminated"] for x in runs)}
        for mlabel, path in METRICS:
            vals = [dig(x["frames"], path) for x in runs]
            vals = [v for v in vals if v is not None]
            step[mlabel] = statistics.median(vals) if vals else None
        result["steps"][name] = step
        print("  %-13s fps %6.1f   p95 %7.2f ms   late %3s   busy total %8.1f ms%s"
              % (name, step["fps"] or 0, step["frame p95"] or 0, step["late frames"],
                 step["busy total"] or 0, "   CONTAMINATED" if step["contaminated"] else ""))
    c.send("view.set", START)
    return result


def compare(a, b):
    print("A = %s (%s objects, %s)   B = %s (%s objects, %s)"
          % (a["label"], a.get("objects"), a.get("build"), b["label"], b.get("objects"), b.get("build")))
    if a.get("build") != b.get("build"):
        print("!! the two runs come from different builds (%s / %s): Debug vs Release alone is ×40"
              % (a.get("build"), b.get("build")))
    for name, _, _, _ in WALK:
        sa, sb = a["steps"].get(name), b["steps"].get(name)
        if not sa or not sb:
            continue
        flag = "   (contaminated)" if sa["contaminated"] or sb["contaminated"] else ""
        print("\n%s%s" % (name, flag))
        for mlabel, _ in METRICS:
            va, vb = sa.get(mlabel), sb.get(mlabel)
            if va is None or vb is None:
                continue
            ratio = ("×%.2f" % (vb / va)) if va else ("—" if vb == 0 else "new")
            print("  %-12s %10.2f %10.2f   %s" % (mlabel, va, vb, ratio))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("socket", nargs="?")
    ap.add_argument("--label", default="run")
    ap.add_argument("--out")
    ap.add_argument("--repeat", type=int, default=3)
    ap.add_argument("--compare", nargs=2, metavar=("A.json", "B.json"))
    args = ap.parse_args()
    if args.compare:
        with open(args.compare[0]) as fa, open(args.compare[1]) as fb:
            compare(json.load(fa), json.load(fb))
        return 0
    if not args.socket:
        ap.print_usage()
        return 2
    result = measure(args.socket, args.label, max(1, args.repeat))
    if args.out:
        with open(args.out, "w") as f:
            json.dump(result, f, indent=1)
        print("→ %s" % args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())

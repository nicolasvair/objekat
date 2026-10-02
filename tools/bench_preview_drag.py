#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""What a DRAG costs when 600 blocks are selected — the previews drawn by the Canvas (E7).

Before E7 a gesture's preview (move, trim, resize, fade, spill, loop bound) sent every block it
touched onto a rich SwiftUI view: dragging 600 selected pieces created 600 views on the first
frame. The batched Canvas draws those previews now (`BlockPreviewGeometry`), and the fallback
`objekat.timeline.richPreviews` puts the old regime back with no rebuild, so the SAME build can be
measured both ways:

    # 1. a RELEASE build, in UI MODE (never --headless; Debug is up to ×40 slower — refused here).
    #    The screen must be awake and unlocked (`caffeinate -u`), and the app in front: a synthetic
    #    press on a window that is not key is swallowed.
    A=objekat.app/Contents/MacOS/objekat
    $A --api --no-recent --socket=/tmp/cc501/new.sock                                       # Canvas
    $A --api --no-recent --socket=/tmp/cc501/old.sock -objekat.timeline.richPreviews YES    # rich

    # 2. measure each, then compare
    ./bench_preview_drag.py /tmp/cc501/new.sock --label canvas --out bench_results/preview_drag_canvas.json
    ./bench_preview_drag.py /tmp/cc501/old.sock --label rich   --out bench_results/preview_drag_rich.json
    ./bench_preview_drag.py --compare bench_results/preview_drag_rich.json bench_results/preview_drag_canvas.json

The scene is bench_groups' S3 (600 pieces of 0.5 s in ONE open group, all 600 selected). Each run
presses on a visible selected piece (the zone must read `move`), drags it `--travel` px to the right
in `--duration-ms`, KEEPS the button down, reads `perf.census` (the regimes UNDER the gesture: with
the Canvas, `clips_rich` and `rich_reasons.preview` ≈ 0), then releases and undoes. The frame report
of the drag is the usual one (`perf.frames`): fps, frame max (the first frame is where the 600 views
were created), p95, busy. The model is read back after the release: the selection must have moved
together by the same travel.

Hands off the trackpad and the mouse while it runs (a real input event flags the run contaminated).
"""

import argparse, json, os, shutil, statistics, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError
from bench_navigation import METRICS, dig
from bench_groups import build, make_noise_wav, settle, FIXED_BLOCK


def grab_point(c, pps):
    """A point on a visible, selected piece whose hover zone reads `move`: (x, y, id)."""
    c.send("view.set", {"pps": pps, "block_height": FIXED_BLOCK, "scroll_x": 0, "scroll_y": 0})
    settle(c, 500)
    vs = c.send("view.state")
    vsnap = vs.get("vsnap") or {}
    ruler, step = vsnap.get("ruler_h", 50), vsnap.get("lane_step", FIXED_BLOCK + 4)
    vw, vh = vs["viewport_w"], vs["viewport_h"]
    sel = {s.upper() for s in c.send("selection.get").get("ids", [])}
    cands = sorted((o["start"], o["display_lane"], o) for o in c.send("object.list")["objects"]
                   if o["kind"] == "clip" and (not sel or o["id"].upper() in sel))
    for _, _, o in cands:
        x0 = o["start"] * pps
        if not 40 < x0 < vw - 200:
            continue
        y = ruler + o["display_lane"] * step + 100
        if y >= vh - 4:
            continue
        for dx in (o["duration"] * pps / 2, 1, 2, 3, 4, 6, 8):
            x = x0 + dx
            if x >= vw - 2:
                continue
            c.send("input.hover", {"x": x, "y": y})
            if c.send("view.state.hover").get("zone") == "move":
                c.send("input.hover", {"leave": True})
                return x, y, o["id"]
    raise RuntimeError("no visible selected piece with a `move` zone at pps %s" % pps)


def one_run(c, pps, travel, duration_ms):
    x, y, oid = grab_point(c, pps)
    before = {o["id"]: o["start"] for o in c.send("object.list")["objects"]}
    c.send("input.hover", {"x": x, "y": y})
    r = c.send("input.drag", {"x": x, "y": y, "dx": travel, "dy": 0, "duration_ms": duration_ms,
                              "rate_hz": 120, "release": False})
    census = c.send("perf.census")["regimes"]
    c.send("input.release")
    # The release is an event like the others: with 600 rich views a frame can take over a second,
    # so wait until the pieces have moved (or 30 s) instead of trusting one `wait_idle`.
    deltas = [0]
    for _ in range(60):
        settle(c, 500)
        after = {o["id"]: o["start"] for o in c.send("object.list")["objects"]}
        deltas = sorted({round(after[i] - before[i], 3) for i in before if i in after})
        if deltas != [0]:
            break
    if deltas != [0]:
        c.send("edit.undo")        # only when a move was made: the undo must not eat the setup
    settle(c, 800)
    return {"frames": r["frames"], "contaminated": r.get("contaminated", False),
            "build": r.get("build"), "census": census, "grab": [x, y], "moved_by": deltas}


def measure(sock, label, repeat, pps_list, travel, duration_ms, allow_debug):
    tmp = tempfile.mkdtemp(prefix="bench_preview_drag_")
    try:
        c = ObjekatClient(sock, timeout=600)
        c.connect()
        wav = make_noise_wav(tmp)
        result = {"label": label, "when": time.strftime("%Y-%m-%d %H:%M:%S"), "repeat": repeat,
                  "travel_px": travel, "duration_ms": duration_ms, "scenarios": {}}
        build(c, wav, "S3")
        # Off the grid: with the snap on, the preview only changes every grid step, and the frame
        # count then measures the grid and not the drawing.
        c.send("project.set_snap", {"enabled": False})
        vs = c.send("view.state")
        result["viewport"] = [vs.get("viewport_w"), vs.get("viewport_h")]
        for pps in pps_list:
            runs = []
            for _ in range(repeat * 3):
                if len([r for r in runs if not r["contaminated"]]) >= repeat:
                    break
                runs.append(one_run(c, pps, travel, duration_ms))
            clean = [r for r in runs if not r["contaminated"]] or runs
            clean = clean[:repeat]
            if runs[-1]["build"] != "release" and not allow_debug:
                print("!! build is %r, not release: refusing (Debug is up to ×40 slower)" % runs[-1]["build"],
                      file=sys.stderr)
                return None
            result["build"] = runs[-1]["build"]
            step = {"runs": len(clean), "thrown_runs": len(runs) - len(clean)}
            for mlabel, path in METRICS:
                vals = [v for v in (dig(r["frames"], path) for r in clean) if v is not None]
                step[mlabel] = statistics.median(vals) if vals else None
            step["fps_runs"] = [round(dig(r["frames"], ("fps_mean",)) or 0, 1) for r in clean]
            # What the census says UNDER the gesture (the last clean run's, the others agree).
            rg = clean[-1]["census"]
            step["census"] = {"clips_canvas": rg.get("clips_canvas"), "clips_rich": rg.get("clips_rich"),
                              "groups_canvas": rg.get("groups_canvas"), "groups_rich": rg.get("groups_rich"),
                              "rich_reasons": {k: v for k, v in (rg.get("rich_reasons") or {}).items() if v},
                              "foreach_total": rg.get("foreach_total")}
            step["moved_by"] = clean[-1]["moved_by"]
            result["scenarios"]["S3 move @pps %g" % pps] = step
            print("S3 move @pps %-4g fps %6.1f  frame max %7.1f ms  p95 %6.1f  busy %8.1f ms  %s  census %s  moved_by %s"
                  % (pps, step["fps"] or 0, step["frame max"] or 0, step["frame p95"] or 0,
                     step["busy total"] or 0, step["fps_runs"], json.dumps(step["census"]), step["moved_by"]))
        c.send("project.new")
        return result
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def compare(a, b):
    with open(a) as f: ra = json.load(f)
    with open(b) as f: rb = json.load(f)
    print("%s  ->  %s" % (ra["label"], rb["label"]))
    for name in ra["scenarios"]:
        if name not in rb["scenarios"]:
            continue
        sa, sb = ra["scenarios"][name], rb["scenarios"][name]
        print(name)
        for m, _ in METRICS:
            va, vb = sa.get(m), sb.get(m)
            if va is None or vb is None:
                continue
            ratio = (vb / va) if va else float("nan")
            print("   %-12s %10.2f -> %10.2f   x%.2f" % (m, va, vb, ratio))
        print("   census       %s\n             -> %s" % (json.dumps(sa["census"]), json.dumps(sb["census"])))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sock", nargs="?")
    ap.add_argument("--label", default="run")
    ap.add_argument("--out")
    ap.add_argument("--repeat", type=int, default=3)
    ap.add_argument("--pps", default="5,20", help="zoom levels, comma separated (default 5,20)")
    ap.add_argument("--travel", type=float, default=400, help="px to the right (default 400)")
    ap.add_argument("--duration-ms", type=float, default=1500)
    ap.add_argument("--allow-debug", action="store_true")
    ap.add_argument("--compare", nargs=2, metavar=("A", "B"))
    args = ap.parse_args()
    if args.compare:
        compare(*args.compare)
        return
    if not args.sock:
        ap.error("a socket is needed")
    res = measure(args.sock, args.label, args.repeat, [float(x) for x in args.pps.split(",")],
                  args.travel, args.duration_ms, args.allow_debug)
    if res is None:
        sys.exit(1)
    if args.out:
        with open(args.out, "w") as f:
            json.dump(res, f, indent=1)
        print("written", args.out)


if __name__ == "__main__":
    main()

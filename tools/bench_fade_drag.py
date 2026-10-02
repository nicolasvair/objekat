#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""What a FADE / CROSSFADE drag costs per frame, on screen — the "lag while I drag the edges of a
fade" of 2 October 2026.

    # a RELEASE build in UI mode (Debug draws up to x40 slower — compare like with like). The screen
    # awake and unlocked, hands off the trackpad while it runs.
    objekat.app/Contents/MacOS/objekat --api --no-recent --socket=/tmp/cc501/fd.sock
    ./bench_fade_drag.py /tmp/cc501/fd.sock --label before --out bench_results/fade_drag_before.json
    ./bench_fade_drag.py --compare bench_results/fade_drag_before.json bench_results/fade_drag_after.json

The scene: `--lanes` rows of `--per-lane` clips butted end to end, every seam a crossfade (the case
the report was made on). Four gestures, each `--repeat` times, each undone after:

  fade_in      the plain fade-in handle of the first clip of a row (no crossfade on that side), inwards
  xf_both      the top triangle of a crossfade (widen symmetrically)
  xf_side      the right side of a crossfade's upper half (one edge travels)
  fade_spill   the fade-out handle of the LAST clip of a row pulled outwards past its edge (a preview,
               no model write until the drop)

For each: the frame report (`perf.frames`) of the drag, plus the census counters read across it
(`items_writes`, `lane_entries_rebuilds`, `passes`, `canvas_draws`) — what the frames did, not only
how long they took.
"""

import argparse, json, os, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient
from bench_navigation import METRICS, dig
from bench_groups import make_noise_wav, settle

CLIP_S, MARGIN_S, XF_S = 2.0, 0.6, 0.5
PPS, BLOCK = 120, 90.0


def build_scene(c, wav, lanes, per_lane):
    c.send("project.new")
    ids = []
    home = 1000.0
    for lane in range(lanes):
        row = []
        for i in range(per_lane):
            o = c.send("object.add", {"path": wav, "lane": lane, "start": home})
            c.send("object.trim", {"id": o["id"], "start": home + MARGIN_S, "duration": CLIP_S})
            c.send("object.move", {"id": o["id"], "start": i * CLIP_S})
            home += 10
            row.append(o["id"])
        for a, b in zip(row, row[1:]):
            c.send("crossfade.open", {"left": a, "right": b, "width": XF_S})
        ids.append(row)
    c.send("selection.clear")
    return ids


def counters(c):
    p = c.send("perf.census")
    r = p.get("regimes") or {}
    return {"items_writes": p.get("items_writes"), "lane_entries_rebuilds": p.get("lane_entries_rebuilds"),
            "passes": r.get("passes"), "canvas_draws": r.get("canvas_draws")}


def geometry(c):
    c.send("view.set", {"pps": PPS, "block_height": BLOCK, "scroll_x": 0, "scroll_y": 0})
    settle(c, 600)
    vs = c.send("view.state")
    vsnap = vs.get("vsnap") or {}
    return vsnap.get("ruler_h", 50), vsnap.get("lane_step", BLOCK + 4), vs["viewport_w"], vs["viewport_h"]


def objects_by_id(c):
    return {o["id"].upper(): o for o in c.send("object.list")["objects"]}


def gesture_points(c, rows):
    ruler, step, vw, vh = geometry(c)
    objs = objects_by_id(c)
    pts = {}
    lane = 1 if len(rows) > 1 else 0
    row = rows[lane]
    first = objs[row[0].upper()]
    top = ruler + first["display_lane"] * step
    # fade-in handle of the first clip: upper half, a few px in from its left edge
    for dx in (4, 8, 12, 16, 24):
        x, y = first["start"] * PPS + dx, top + BLOCK * 0.2
        c.send("input.hover", {"x": x, "y": y})
        if c.send("view.state.hover").get("zone") == "fadeIn":
            pts["fade_in"] = (x, y, 120, 0)
            break
    # the first crossfade of the row, fully visible
    z = None
    for zz in c.send("crossfade.list")["crossfades"]:
        if zz["left"].upper() == row[1].upper() or zz["left"].upper() == row[2].upper():
            z = zz
            break
    if z:
        x0, x1 = z["start"] * PPS, z["end"] * PPS
        pts["xf_both"] = ((x0 + x1) / 2, top + BLOCK * 0.12, 60, 0)
        pts["xf_side"] = (x0 + 0.8 * (x1 - x0), top + BLOCK * 0.35, 60, 0)
    c.send("input.hover", {"leave": True})
    return pts, (ruler, step, vw, vh)


def one(c, name, pt, duration_ms):
    x, y, dx, dy = pt
    c0 = counters(c)
    c.send("input.hover", {"x": x, "y": y})
    r = c.send("input.drag", {"x": x, "y": y, "dx": dx, "dy": dy, "duration_ms": duration_ms,
                              "rate_hz": 120, "release": True})
    settle(c, 300)
    c1 = counters(c)
    c.send("edit.undo")
    settle(c, 300)
    f = r.get("frames") or {}
    out = {k: dig(f, p) for k, p in METRICS}
    out.update({k: (c1[k] - c0[k]) if (c1[k] is not None and c0[k] is not None) else None for k in c0})
    out["contaminated"] = r.get("contaminated")
    out["build"] = r.get("build")
    return out



def run(sock, label, lanes, per_lane, repeat, duration_ms, only):
    c = ObjekatClient(sock, timeout=600)
    c.connect()
    wav = make_noise_wav(tempfile.gettempdir(), seconds=60)
    rows = build_scene(c, wav, lanes, per_lane)
    settle(c, 1500)
    pts, geo = gesture_points(c, rows)
    print("geometry ruler=%s step=%s viewport=%sx%s  points=%s" % (geo + (sorted(pts),)))
    res = {"label": label, "objects": lanes * per_lane, "steps": {}}
    for name, pt in pts.items():
        if only and name not in only:
            continue
        runs = [one(c, name, pt, duration_ms) for _ in range(repeat)]
        res["steps"][name] = runs
        for r in runs:
            print("%-10s fps %5.1f  p50 %6.1f  p95 %6.1f  max %6.1f  busy_tot %7.1f  writes %s rebuilds %s passes %s draws %s %s" % (
                name, r["fps"] or 0, r["frame p50"] or 0, r["frame p95"] or 0, r["frame max"] or 0,
                r["busy total"] or 0, r["items_writes"], r["lane_entries_rebuilds"], r["passes"],
                r["canvas_draws"], "CONTAMINATED" if r["contaminated"] else ""))
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("socket", nargs="?")
    ap.add_argument("--label", default="run")
    ap.add_argument("--lanes", type=int, default=8)
    ap.add_argument("--per-lane", type=int, default=20)
    ap.add_argument("--repeat", type=int, default=2)
    ap.add_argument("--duration-ms", type=int, default=1500)
    ap.add_argument("--only", nargs="*")
    ap.add_argument("--out")
    a = ap.parse_args()
    res = run(a.socket, a.label, a.lanes, a.per_lane, a.repeat, a.duration_ms, a.only)
    if a.out:
        with open(a.out, "w") as f:
            json.dump(res, f, indent=1)


if __name__ == "__main__":
    main()

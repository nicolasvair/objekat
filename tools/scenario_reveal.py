#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""`view.reveal` — the timeline's view coming to a selection made in the sound list. A scenario
that ASSERTS, in UI MODE against the real scroll view (never `--headless`: the command needs the
timeline on screen, and answers `invalid_state` without it).

    objekat.app/Contents/MacOS/objekat --api --no-audio --no-recent --socket=/tmp/o.sock
    ./scenario_reveal.py /tmp/o.sock

What it is out to prove (`TimelineReveal` holds the arithmetic, tested alone by
`test_timeline_reveal.swift`; this is the wiring): an object out of sight is brought in and the
zoom is left alone; an object already in sight moves NOTHING; several objects that do not fit are
framed by a zoom-out; a child of a folded group has its group unfolded; the vertical scroll finds a
lane far below; the lane snap frames it instead when active; the selection is never touched.

Exit: 0 if every assertion passes, 1 otherwise.
"""

import os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

if len(sys.argv) != 2:
    print(__doc__)
    sys.exit(2)

fails = []
count = 0


def check(cond, label):
    global count
    count += 1
    print(("  OK   " if cond else "  FAIL ") + label)
    if not cond:
        fails.append(label)


c = ObjekatClient(sys.argv[1])
c.connect()

BIP = os.path.join(HERE, "fixtures", "bip.wav")

info = c.send("app.info")
check(info.get("records_recent_projects") is False, "the instance records no recent project (--no-recent)")

c.send("project.new")
rw = c.send("debug.resize_window", {"width": 1400, "height": 1000})
check(rw["height"] > 700, "window resized to a generous height (%s)" % rw["height"])


def add(lane, start):
    return c.send("object.add", {"path": BIP, "lane": lane, "start": start})["id"]


def by_id():
    return {o["id"]: o for o in c.send("object.list")["objects"]}


def visible_time(v):
    return v["visible_time"]


def in_view_time(v, t0, t1, tol=0.01):
    lo, hi = visible_time(v)
    return lo - tol <= t0 and t1 <= hi + tol


def reveal(ids):
    return c.send("view.reveal", {"ids": ids})


def same_view(a, b):
    return (abs(a["scroll_x"] - b["scroll_x"]) < 0.6 and abs(a["scroll_y"] - b["scroll_y"]) < 0.6
            and a["pps"] == b["pps"] and a["block_height"] == b["block_height"])


A = add(0, 0.0)
B = add(0, 200.0)
C = add(5, 400.0)
X = add(1, 50.0)
Y = add(2, 53.0)
F = add(60, 0.5)          # far below the window
objs = by_id()
check(objs[F]["lane"] >= 30, "a far-away lane exists (%s)" % objs[F]["lane"])

c.send("selection.clear")
# A free (not snapped) vertical view to start from: the snap is exercised on its own below.
base = {"pps": 100, "block_height": 40, "scroll_x": 0, "scroll_y": 0}


def start_view(**extra):
    p = dict(base)
    p.update(extra)
    return c.send("view.set", p)


v = start_view()
VW = v["viewport_w"]
check(VW > 500, "a usable viewport width (%s)" % VW)

print("already visible: nothing moves")
r = reveal([A])
check(same_view(r["view_before"], r["view"]), "an object already in view leaves the view exactly as it was")
check(r["unfolded"] == [], "nothing unfolded")

print("out of view: brought in, zoom untouched")
r = reveal([B])
v1 = r["view"]
check(v1["pps"] == 100, "pps unchanged for a single object (%s)" % v1["pps"])
check(in_view_time(v1, 200.0, 200.4), "the object at 200 s is now in view %s" % visible_time(v1))
centre = (v1["visible_time"][0] + v1["visible_time"][1]) / 2
check(abs(centre - 200.2) < 0.2, "…and centred (view centre %.3f s)" % centre)

r2 = reveal([B])
check(same_view(r2["view_before"], r2["view"]), "revealing it again, now in sight, moves nothing")

print("several that fit but are out of view: scroll only")
start_view()
r = reveal([X, Y])
v2 = r["view"]
check(v2["pps"] == 100, "pps unchanged when the box fits (%s)" % v2["pps"])
check(in_view_time(v2, 50.0, 53.4), "both objects are in view %s" % visible_time(v2))

print("several that do not fit: zoom out to frame them")
start_view()
r = reveal([A, B, C])
v3 = r["view"]
check(v3["pps"] < 100, "the zoom went out (%s)" % v3["pps"])
check(in_view_time(v3, 0.0, 400.4, 0.05), "the whole box is in view %s" % visible_time(v3))
span_px = 400.4 * v3["pps"]
check(abs(span_px - 0.8 * v3["viewport_w"]) < 0.02 * v3["viewport_w"] or v3["pps"] <= v3["min_pps"] * 1.001,
      "…filling ~80%% of the width (%.0f of %.0f px) unless the zoom-out limit stopped it" % (span_px, v3["viewport_w"]))
check(v3["pps"] >= v3["min_pps"] - 1e-9, "never below the timeline's own minimum zoom")

print("the zoom bounds hold")
start_view(pps=100)
mn = c.send("view.state")["min_pps"]
r = reveal([A, C])
check(r["view"]["pps"] >= mn - 1e-9, "the result respects min_pps (%s >= %s)" % (r["view"]["pps"], mn))

print("vertical: a lane far below is brought in, no vertical zoom")
v = start_view(pps=100)
bh0 = v["block_height"]
check(not v["vsnap"]["active"], "the vertical view is free (snap off) for this block (block_height %s)" % bh0)
ruler = v["vsnap"]["ruler_h"]
step = v["vsnap"]["lane_step"]
r = reveal([F])
vv = r["view"]
check(vv["scroll_y"] > 0, "the view scrolled down (%s)" % vv["scroll_y"])
lane = by_id()[F]["display_lane"]
top = ruler + lane * step
check(top >= vv["scroll_y"] + ruler - 1 and top + bh0 <= vv["scroll_y"] + vv["viewport_h"] + 1,
      "the lane's block is inside the visible rows (top %.0f, scroll %.0f)" % (top, vv["scroll_y"]))
check(vv["block_height"] == bh0, "no vertical zoom (block_height %s)" % vv["block_height"])
check(vv["pps"] == 100, "and no horizontal zoom for a single object")

r = reveal([A])
check(r["view"]["scroll_y"] < vv["scroll_y"], "going back to lane 0 scrolls back up")

print("vertical, with the lane snap active: the lane is FRAMED")
avail = c.send("view.state")["vsnap"]["available_h"]
v = c.send("view.set", {"pps": 100, "block_height": avail * 0.8, "scroll_x": 0, "scroll_y": 0})
check(v["vsnap"]["active"], "the snap is active at a 0.8 ratio")
r = reveal([F])
time.sleep(0.4)
vs = c.send("view.state")["vsnap"]
check(vs["on_grid"], "the view is on the grid after the reveal")
check(vs["lane"] == lane, "…framed on the object's own lane (%s == %s)" % (vs["lane"], lane))
c.send("view.set", {"block_height": bh0, "scroll_x": 0, "scroll_y": 0})

print("a child of a folded group: the group is unfolded")
G1 = add(10, 100.0)
G2 = add(11, 101.0)
grp = c.send("group.create", {"ids": [G1, G2]})["id"]
c.send("group.expand", {"id": grp, "expanded": False})
check(G1 not in by_id(), "the child is not in the timeline's rows while its group is folded")
start_view()
r = reveal([G1])
check(r["unfolded"] == [grp], "the reveal names the group it unfolded")
o = by_id()
check(G1 in o and o[G1].get("parent") == grp, "the child is now a row of the timeline")
check(in_view_time(r["view"], 100.0, 100.4), "…and in view %s" % visible_time(r["view"]))

print("the selection is never touched")
c.send("selection.set", {"ids": [A]})
before = sorted(c.send("selection.get")["ids"])
reveal([B])
after = sorted(c.send("selection.get")["ids"])
check(before == after, "view.reveal does not change the selection")

print("errors")
try:
    c.send("view.reveal", {"ids": ["00000000-0000-0000-0000-000000000000"]})
    check(False, "an unknown id is refused")
except ObjekatError as e:
    check(getattr(e, "code", "") == "not_found" or "not_found" in str(e), "an unknown id answers not_found")
try:
    c.send("view.reveal", {"ids": []})
    check(False, "an empty list is refused")
except ObjekatError as e:
    check(True, "an empty list is refused")

print("\n%d assertions, %d failed" % (count, len(fails)))
if fails:
    print("FAILED:")
    for f in fails:
        print("  - " + f)
    sys.exit(1)
print("ALL PASS")

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The horizontal zoom-out limit (`view.state.min_pps`) — a scenario that ASSERTS, in UI MODE.

    objekat.app/Contents/MacOS/objekat --api --no-recent --socket=/tmp/o.sock
    ./scenario_zoom_out.py /tmp/o.sock

What it is out to prove: the furthest the view zooms OUT is the session's own length — the whole
session, and 5 % more, in the window — and not a fixed 1 px/s (which capped the view at ~10 min on
a 600 px window whatever the session lasted). A short project still stops at a minute of timeline.

  • a clip placed at 3000 s, `view.set pps=0.0001` → the zoom lands on viewport / (end × 1.05);
  • a short project → the 60 s floor (viewport / 60);
  • every other door reaches the same bound: ⇧-scroll and the `t` / `r` keys, a session saved
    and reopened;
  • the bound follows the content (a longer session zooms out further) and never drags the
    CURRENT zoom along when it moves;
  • zoomed all the way out, the view still draws (frames are counted), the ruler included.

Never `--headless`: the commands need the timeline on screen (`invalid_state` otherwise). Hands
off the trackpad and the mouse during the run.

Exit: 0 if every assertion passes, 1 otherwise.
"""

import math, os, sys, tempfile

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


def near(a, b, rel=0.01):
    return abs(a - b) <= rel * abs(b)


c = ObjekatClient(sys.argv[1])
c.connect()

BIP = os.path.join(HERE, "fixtures", "bip.wav")
FIT = 1.05
FLOOR = 60.0


def state():
    return c.send("view.state")


def end_of(oid):
    o = c.send("object.get", {"id": oid})
    return o["start"] + o["duration"]


info = c.send("app.info")
check(info["has_document"], "a document is open")
if info["object_count"] > 0:
    c.send("project.new")

# A known window, so the viewport width is stable for the whole run.
c.send("debug.resize_window", {"width": 1400, "height": 900})
c.send("view.set", {"pps": 100, "scroll_x": 0, "scroll_y": 0})
vw = state()["viewport_w"]
check(vw > 400, "a usable viewport width (%s)" % vw)

print("short project → the 60 s floor")
v = c.send("view.set", {"pps": 0.0001})
check(v["min_pps"] is not None, "view.state carries min_pps (%s)" % v["min_pps"])
check(near(v["min_pps"], vw / FLOOR), "empty project: min_pps = viewport / 60 (%s vs %.4f)" % (v["min_pps"], vw / FLOOR))
check(v["pps"] == v["min_pps"], "view.set pps=0.0001 lands on min_pps (%s)" % v["pps"])
check(v["max_pps"] == 200000, "max_pps unchanged (%s)" % v["max_pps"])

r = c.send("object.add", {"path": BIP, "lane": 0, "start": 5.0})
short_end = end_of(r["id"])
check(short_end < FLOOR / FIT, "a short clip stays under the floor (ends at %.2f s)" % short_end)
v = c.send("view.set", {"pps": 0.0001})
check(near(v["pps"], vw / FLOOR), "a short project still stops at a minute of timeline (%s)" % v["pps"])
c.send("object.remove", {"ids": [r["id"]]})

print("a clip at 3000 s")
r = c.send("object.add", {"path": BIP, "lane": 0, "start": 3000.0})
oid = r["id"]
end = end_of(oid)
want = vw / (end * FIT)
v = c.send("view.set", {"pps": 0.0001})
check(v["pps"] < 1.0 and v["pps"] > 1e-4, "the old 1 px/s floor is gone (pps %s)" % v["pps"])
check(near(v["pps"], want), "pps ≈ viewport / (end × 1.05): %s vs %.6f" % (v["pps"], want))
check(near(v["min_pps"], want), "min_pps says the same (%s)" % v["min_pps"])
vt = v["visible_time"]
check(vt[0] == 0 and end < vt[1] <= end * FIT * 1.02,
      "the whole session is on screen, 5 %% to spare (visible %s → %s, session ends %.2f)" % (vt[0], vt[1], end))
check(v["content_w"] >= v["viewport_w"] - 1, "the canvas is never narrower than the window (%s ≥ %s)" % (v["content_w"], v["viewport_w"]))

print("the bound does not drag the current zoom along")
mid = want * 3
v = c.send("view.set", {"pps": mid})
check(near(v["pps"], mid), "a zoom above the bound is kept (%s)" % v["pps"])
r2 = c.send("object.add", {"path": BIP, "lane": 1, "start": 9000.0})
end2 = end_of(r2["id"])
v = state()
check(near(v["pps"], mid), "adding a far clip does not move the zoom (%s)" % v["pps"])
check(near(v["min_pps"], vw / (end2 * FIT)), "…but the bound moved out: min_pps %s vs %.6f" % (v["min_pps"], vw / (end2 * FIT)))
v = c.send("view.set", {"pps": 0.0001})
check(near(v["pps"], vw / (end2 * FIT)), "a 9000 s session zooms out further (%s)" % v["pps"])
c.send("object.remove", {"ids": [r2["id"]]})
v = c.send("view.set", {"pps": 0.0001})
check(near(v["pps"], want), "and back when the clip goes (%s)" % v["pps"])

print("the other doors reach the same bound")
c.send("view.set", {"pps": want * 4, "scroll_x": 0})
d = c.send("input.zoom", {"axis": "horizontal", "factor": 0.001})
check(near(d["view_after"]["pps"], want), "⇧-scroll far out stops at the bound (%s)" % d["view_after"]["pps"])
c.send("view.set", {"pps": want * 4, "scroll_x": 0})
d = c.send("input.zoom", {"via": "keys", "factor": 1 / 1.5 ** 8})
check(near(d["view_after"]["pps"], want), "r × 8 stops at the bound (%s)" % d["view_after"]["pps"])
check(d["view_after"]["min_pps"] is not None and d["view_after"]["pps"] >= d["view_after"]["min_pps"] - 1e-9,
      "never below min_pps")

print("a session saved and reopened")
with tempfile.TemporaryDirectory() as tmp:
    path = os.path.join(tmp, "zoom_out.objekat")
    c.send("view.set", {"pps": 0.0001})
    c.send("project.save_as", {"path": path})
    c.send("project.new")
    v = c.send("view.set", {"pps": 0.0001})
    check(near(v["pps"], vw / FLOOR), "a new project is back on the 60 s floor (%s)" % v["pps"])
    c.send("project.open", {"path": path})
    try:
        c.send("wait_idle", {})
    except ObjekatError:
        pass
    v = state()
    check(near(v["pps"], want, 0.02), "the reopened session comes back fully zoomed out (%s vs %.6f)" % (v["pps"], want))
    c.send("project.new")

print("drawn at that zoom")
c.send("object.add", {"path": BIP, "lane": 0, "start": 3000.0})
c.send("view.set", {"pps": 0.0001, "scroll_x": 0})
c.send("perf.frames.start")
d = c.send("input.scroll", {"direction": "right", "distance_px": 300, "measure": False})
r = c.send("perf.frames.stop")
check(r["frames"]["frames"] > 5, "frames are produced fully zoomed out (%d)" % r["frames"]["frames"])
check(not d["contaminated"], "no real input interfered")

c.send("project.new")
c.send("view.set", {"pps": 100, "scroll_x": 0, "scroll_y": 0})
print()
print("%d assertions, %d failed" % (count, len(fails)))
for f in fails:
    print("  FAIL " + f)
sys.exit(1 if fails else 0)

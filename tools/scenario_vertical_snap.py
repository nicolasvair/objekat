#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The vertical lane snap (`view.state.vsnap`, `plan_vertical_lane_snap.md`) — a scenario that
ASSERTS, in UI MODE against the real scroll view and the real scroll monitor.

    objekat.app/Contents/MacOS/objekat --api --no-recent --socket=/tmp/o.sock
    ./scenario_vertical_snap.py /tmp/o.sock

What it is out to prove: once a lane's block passes 70 % of the available height
(`viewportHeight − rulerHeight`), the vertical scroll snaps lane to lane instead of scrolling
continuously, and the zoom itself is clamped so a lane can never exceed 90 % — both independent
of the TIME snap. Every gesture is a SYNTHETIC event through `input.scroll`/`input.zoom`, the same
door a hand uses (@see InputSynth) — `contaminated` says whether the real trackpad interfered.

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

# A known, generous window so `available_h` is stable across the whole run — debug.resize_window
# is the door (@see plan_vertical_lane_snap.md's divergence note: no window_h on view.set, this
# already does exactly that).
rw = c.send("debug.resize_window", {"width": 1400, "height": 1000})
# The window manager may adjust the requested frame (e.g. keeping it on screen) — what matters is
# a stable, generous height to measure `available_h` against, not the exact figure asked for.
check(rw["height"] > 800, "window resized to a generous height (%s)" % rw["height"])

# 24 lanes of material — enough to walk several lanes in both directions and still have "the end".
if c.send("app.info")["object_count"] < 24:
    c.send("batch", {"commands": [{"cmd": "object.add",
                                    "params": {"path": BIP, "lane": l, "start": 0.0}}
                                   for l in range(24)]})


def state():
    return c.send("view.state")


def vsnap():
    return state()["vsnap"]


def set_bh(bh, **extra):
    p = {"block_height": bh}
    p.update(extra)
    return c.send("view.set", p)


c.send("view.set", {"pps": 100, "scroll_x": 0, "scroll_y": 0})
base = vsnap()
check(base is not None, "vsnap answers with an interface")
AVAIL = base["available_h"]
check(AVAIL > 200, "a usable available height (%s)" % AVAIL)

print("clamp (D2)")
v = set_bh(5000)
check(abs(v["vsnap"]["ratio"] - 0.90) < 0.003, "block_height=5000 clamps to ~90%% (ratio %.4f)" % v["vsnap"]["ratio"])
check(v["block_height"] == v["vsnap"]["max_block_height"], "the answer's block_height IS max_block_height")

set_bh(AVAIL * 0.3)
d = c.send("input.zoom", {"axis": "vertical", "factor": 6})
check(d["achieved_factor"] < 6, "a factor that would exceed 90%% falls short (%.3f)" % d["achieved_factor"])
check(d["view_after"]["vsnap"]["ratio"] <= 0.901, "…and the ratio after is still <= 90%% (%.4f)" % d["view_after"]["vsnap"]["ratio"])

set_bh(AVAIL * 0.3)
d = c.send("input.zoom", {"axis": "vertical", "factor": 6, "via": "keys"})
check(d["view_after"]["vsnap"]["ratio"] <= 0.901, "…same clamp via ⇧T presses (%.4f)" % d["view_after"]["vsnap"]["ratio"])

print("below 70% — free, continuous scroll")
set_bh(AVAIL * 0.5, scroll_y=500)
v0 = vsnap()
check(not v0["active"], "0.5 ratio is not active")
d = c.send("input.scroll", {"direction": "down", "distance_px": 137, "style": "trackpad"})
# Below threshold the monitor never intercepts: this is the ordinary NSScrollView path, whose own
# deceleration is not pixel-exact (@see scenario_navigation.py's own 8px tolerance on a plain
# swipe) — only the DIRECTION and a rough magnitude are asserted here.
moved = d["view_after"]["scroll_y"] - 500
check(80 < moved < 220, "plain scroll moved roughly 137 px, continuously (%s)" % moved)
check(not d["view_after"]["vsnap"]["active"], "still not active")
check(not d["contaminated"], "no real input interfered")

print("above 70% — snapped")
v = set_bh(AVAIL * 0.8, scroll_y=0)
check(v["vsnap"]["active"], "0.8 ratio is active")
ls = v["vsnap"]["lane_step"]
lane0 = v["vsnap"]["lane"]
check(lane0 == 0, "starting scroll_y=0 frames lane 0 (%s)" % lane0)

# D7 — an off-grid scroll_y re-frames onto the nearest lane once the scroll comes to rest.
set_bh(AVAIL * 0.8, scroll_y=ls * 2.3)
time.sleep(0.6)
v = vsnap()
check(v["on_grid"], "an off-grid scroll_y is re-framed onto the grid (D7)")
check(v["lane"] == 2, "…onto the nearest lane, 2 (%s)" % v["lane"])

print("trackpad: one lane per gesture, momentum swallowed")
set_bh(AVAIL * 0.8, scroll_y=0)
d = c.send("input.scroll", {"direction": "down", "distance_px": 60, "style": "trackpad", "momentum": True})
time.sleep(0.3)
v = vsnap()
check(v["lane"] == 1 and v["on_grid"], "a 60pt swipe down steps exactly one lane (lane=%s on_grid=%s)" % (v["lane"], v["on_grid"]))

d = c.send("input.scroll", {"direction": "up", "distance_px": 60, "style": "trackpad", "momentum": True})
time.sleep(0.3)
v = vsnap()
check(v["lane"] == 0, "…and back up (lane=%s)" % v["lane"])

set_bh(AVAIL * 0.8, scroll_y=0)
d = c.send("input.scroll", {"direction": "down", "distance_px": 600, "style": "trackpad", "momentum": True})
time.sleep(0.4)
v = vsnap()
check(v["lane"] == 1, "a LONG swipe (600pt, momentum) still steps exactly one lane (lane=%s)" % v["lane"])

set_bh(AVAIL * 0.8, scroll_y=0)
d = c.send("input.scroll", {"direction": "down", "distance_px": 10, "style": "trackpad"})
time.sleep(0.2)
v = vsnap()
check(v["lane"] == 0 and v["on_grid"], "a sub-threshold swipe (10pt) changes nothing (lane=%s)" % v["lane"])

print("wheel: one lane per notch")
set_bh(AVAIL * 0.8, scroll_y=0)
d = c.send("input.scroll", {"direction": "down", "style": "wheel", "notches": 3})
time.sleep(0.4)
v = vsnap()
check(v["lane"] == 3 and v["on_grid"], "three notches → exactly three lanes (lane=%s)" % v["lane"])

print("horizontal pass-through")
set_bh(AVAIL * 0.8, scroll_y=0)
before = state()
d = c.send("input.scroll", {"direction": "right", "distance_px": 400, "style": "trackpad"})
after = d["view_after"]
check(after["scroll_x"] > before["scroll_x"] + 200, "a horizontal swipe still moves scroll_x (%s)" % after["scroll_x"])
check(after["vsnap"]["on_grid"], "…and scroll_y is untouched, still on grid")

print("the two ends")
set_bh(AVAIL * 0.8, scroll_y=0)
d = c.send("input.scroll", {"direction": "up", "distance_px": 60, "style": "trackpad"})
time.sleep(0.3)
check(vsnap()["lane"] == 0, "going up from lane 0 stays at lane 0")

print("⇧ still zooms in snap mode (priority intact)")
set_bh(AVAIL * 0.8, scroll_y=0)
before = state()
d = c.send("input.zoom", {"axis": "vertical", "factor": 1.1})
check(d["view_after"]["block_height"] != before["block_height"], "⇧-scroll still zoomed, not stepped a lane")

print("crossing 70% while zooming (D8)")
set_bh(AVAIL * 0.5, scroll_y=300)
d = c.send("input.zoom", {"axis": "vertical", "factor": 1.8})
time.sleep(0.4)
v = vsnap()
check(v["active"], "zooming across the threshold activates the snap")
check(v["on_grid"], "…and settles framed on a lane (D8)")

d = c.send("input.zoom", {"axis": "vertical", "factor": 1 / 3})
time.sleep(0.4)
v = vsnap()
check(not v["active"], "zooming back out below 70%% deactivates it")
d = c.send("input.scroll", {"direction": "down", "distance_px": 50, "style": "trackpad"})
check(d["view_after"]["vsnap"]["active"] is False, "…and a free swipe moves continuously again")

print("resize keeps the ratio (D3)")
set_bh(AVAIL * 0.8, scroll_y=0)
lane_before = vsnap()["lane"]
rw2 = c.send("debug.resize_window", {"width": 1400, "height": 800})
time.sleep(0.2)
v = vsnap()
check(abs(v["ratio"] - 0.8) < 0.02, "the ratio survives a shrink (%.4f)" % v["ratio"])
c.send("debug.resize_window", {"width": 1400, "height": 1000})
time.sleep(0.2)
v = vsnap()
check(abs(v["ratio"] - 0.8) < 0.02, "…and a grow back (%.4f)" % v["ratio"])

print("↑ / ↓ frame the lane (D9)")
set_bh(AVAIL * 0.8, scroll_y=0)
c.send("caret.set", {"lane": 0})
c.send("caret.step_lane", {"by": 1})
c.send("caret.step_lane", {"by": 1})
time.sleep(0.4)
v = vsnap()
check(v["lane"] == 2 and v["on_grid"], "two steps of caret.step_lane frame lane 2 (lane=%s)" % v["lane"])

print("independence from the time snap (D11)")
c.send("project.set_snap", {"enabled": False})
v1 = vsnap()
c.send("project.set_snap", {"enabled": True})
v2 = vsnap()
check(v1["active"] == v2["active"] and abs(v1["ratio"] - v2["ratio"]) < 1e-6,
      "toggling the TIME snap changes nothing in vsnap")

c.send("view.set", {"scroll_x": 0, "scroll_y": 0})
print()
print("%d assertions, %d failed" % (count, len(fails)))
for f in fails:
    print("  FAIL " + f)
sys.exit(1 if fails else 0)

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The navigation commands (`view.*`, `input.*`, `perf.frames.*`) — a scenario that ASSERTS.

What it is out to prove: a scripted scroll or zoom takes the hand's own path and lands where the
timeline's own law says it should.

    # 1. launch the app with the API, in UI MODE — NEVER --headless: these commands need the
    #    timeline on screen, and answer `invalid_state` without it. The window comes to the
    #    front during the run; do not touch the trackpad or the mouse over it meanwhile
    #    (`contaminated` would say so, and the view would move under the script).
    objekat.app/Contents/MacOS/objekat --api --no-recent --socket=/tmp/o.sock

    # 2. replay
    ./scenario_navigation.py /tmp/o.sock

  • `input.selftest` finds at least one route that reaches the monitors AND moves the view;
  • `view.set` puts the view where it is asked, and `view.state` reads it back;
  • a trackpad swipe moves the scroll in the direction named, and the same swipe twice from the
    same start lands on the same place (to a few points: the scroll view reads the events'
    timing, and the pump's is exact to a millisecond or two, not to the microsecond);
  • ⇧-scroll zooms by the timeline's own law, e^(0.01·dx), short of the requested factor by no
    more than its 3-point dead zone accounts for — and only UNDER A HOVER, as for a hand;
  • `t` / `r` zoom by exactly 1.5 per press, ⇧ for the vertical;
  • a recorded sequence replayed from the same start lands on the same zoom, and on the same
    scroll to within 5 % — measured on 24 September 2026: plain swipes land on the same pixel
    5 times in 6, but a swipe WITH inertia spreads by ±3.5 %, in steps of exactly one finger
    event (~17 px here). Events are dated on the pump's schedule, so this is the scroll view
    folding one event into a different frame, not the pump — a hand is subject to it too;
  • a frame report has the fields a comparison reads, and no gesture here is contaminated.

Exit: 0 if every assertion passes, 1 otherwise.
"""

import math, os, sys

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
START = {"pps": 100, "block_height": 121.5, "scroll_x": 0, "scroll_y": 0}

# Enough material that the canvas is wider and taller than the window.
if c.send("app.info")["object_count"] < 20:
    c.send("batch", {"commands": [{"cmd": "object.add",
                                    "params": {"path": BIP, "lane": l, "start": t * 2.0}}
                                   for l in range(12) for t in range(40)]})


def state():
    return c.send("view.state")


print("selftest")
st = c.send("input.selftest")
check(st["auto"] is not None, "a route reaches the monitors and moves the view (auto = %s)" % st["auto"])
for name, row in st["routes"].items():
    print("       %-8s ok=%s seen=%s moved=%s" % (name, row["ok"], row["seen_by_monitor"], row["view_moved_px"]))

print("view.set / view.state")
v = c.send("view.set", START)
check(v["pps"] == 100 and v["block_height"] == 121.5, "zoom set")
check(v["scroll_x"] == 0 and v["scroll_y"] == 0, "scroll set")
v = c.send("view.set", {"scroll_x": 1234})
check(abs(v["scroll_x"] - 1234) < 0.5, "scroll_x 1234 read back (%s)" % v["scroll_x"])
check(v["model_scroll_x"] == v["scroll_x"], "the model's mirror agrees")

print("trackpad scroll")
runs = []
for _ in range(2):
    c.send("view.set", START)
    d = c.send("input.scroll", {"direction": "right", "distance_px": 800})
    runs.append(d["view_after"]["scroll_x"])
    check(d["events_seen"] == d["events_posted"], "every event reached the timeline (%d)" % d["events_posted"])
    check(not d["contaminated"], "no real input during the gesture")
check(runs[0] > 600, "right = later time comes into view (%s px for 800 asked)" % runs[0])
check(abs(runs[0] - runs[1]) <= 8, "the same swipe twice lands within 8 px (%s / %s)" % tuple(runs))
c.send("view.set", START)
d = c.send("input.scroll", {"direction": "down", "distance_px": 300})
check(d["view_after"]["scroll_y"] > 200, "down = lower lanes come into view (%s)" % d["view_after"]["scroll_y"])
c.send("view.set", {"scroll_x": 2000, "scroll_y": 0})
d = c.send("input.scroll", {"direction": "left", "distance_px": 500})
check(d["view_after"]["scroll_x"] < 2000, "left = earlier time (%s)" % d["view_after"]["scroll_x"])
f = d["frames"]
for key in ("frames", "expected_frame_ms", "frame_ms", "late_frames", "dropped_frames_est",
            "hitch_ms_per_s", "main_busy_ms"):
    check(key in f, "frame report carries %s" % key)
check(f["frame_ms"]["p50"] <= f["frame_ms"]["p95"] <= f["frame_ms"]["max"], "p50 ≤ p95 ≤ max")

print("⇧-scroll zoom (the timeline's own law)")
for axis, factor, key in (("horizontal", 2.0, "pps"), ("horizontal", 0.5, "pps"),
                          ("vertical", 0.5, "block_height"), ("vertical", 1.6, "block_height")):
    c.send("view.set", START)
    d = c.send("input.zoom", {"axis": axis, "factor": factor})
    got = d["achieved_factor"]
    # The dead zone swallows < 3 points, i.e. at most e^(0.03) either way (0.036 vertically).
    slack = math.exp(0.036)
    check(factor / slack <= got <= factor * slack if factor > 1 else factor * slack >= got >= factor / slack,
          "%s ×%s → ×%s" % (axis, factor, got))
    check(d["view_after"][key] != d["view_before"][key], "%s moved" % key)
c.send("view.set", START)
c.send("input.hover", {"leave": True})
d = c.send("input.scroll", {"dx": 60, "modifiers": ["shift"], "hover": False})
check(d["view_after"]["pps"] == 100, "no hover, no zoom — as for a hand off the timeline")
check(d["events_seen"] == d["events_posted"], "…though the monitor did see every event")

print("keys")
c.send("view.set", START)
d = c.send("input.zoom", {"via": "keys", "factor": 2.25})
check(d["presses"] == 2 and abs(d["achieved_factor"] - 2.25) < 1e-6, "t ×2 = ×2.25 (%s)" % d["achieved_factor"])
d = c.send("input.zoom", {"via": "keys", "factor": 1 / 1.5, "axis": "vertical"})
check(abs(d["achieved_factor"] - 1 / 1.5) < 1e-6, "⇧r = ÷1.5 vertical (%s)" % d["achieved_factor"])
d = c.send("input.key", {"key": "t"})
check(d["claimed"] is False and d["events_seen"] == 2, "a bare t reaches the timeline, down and up")
try:
    c.send("input.key", {"key": "nosuchkey"})
    check(False, "an unknown key is refused")
except ObjekatError as e:
    check(e.code == "bad_params", "an unknown key is refused")

print("record → replay")
c.send("view.set", START)
c.send("input.record.start")
c.send("input.scroll", {"direction": "right", "distance_px": 600, "duration_ms": 300, "momentum": True})
c.send("input.zoom", {"factor": 1.8})
c.send("input.key", {"key": "t", "modifiers": ["shift"]})
rec = c.send("input.record.stop")
a = state()
check(rec["count"] > 50 and rec["duration_ms"] > 300, "recorded %d events over %s ms" % (rec["count"], rec["duration_ms"]))
for _ in range(2):
    c.send("view.set", START)
    d = c.send("input.replay", {"events": rec["events"]})
    b = d["view_after"]
    check(b["pps"] == a["pps"] and b["block_height"] == a["block_height"], "replay: same zoom")
    check(abs(b["scroll_x"] - a["scroll_x"]) <= 0.05 * a["scroll_x"],
          "replay: scroll within 5 %% (%s vs %s)" % (b["scroll_x"], a["scroll_x"]))

print("perf.frames")
c.send("perf.frames.start")
c.send("input.scroll", {"direction": "right", "distance_px": 400, "measure": False})
r = c.send("perf.frames.stop")
check(r["frames"]["frames"] > 10, "perf.frames counted %d frames" % r["frames"]["frames"])

print("scenario")
r = c.send("input.scenario", {"steps": [
    {"cmd": "view.set", "params": START},
    {"cmd": "input.scroll", "params": {"direction": "right", "distance_px": 500}},
    {"wait_ms": 50},
    {"cmd": "input.zoom", "params": {"factor": 0.7}},
]})
check(len(r["steps"]) == 4 and r["frames"]["frames"] > 0, "4 steps, one report each and one overall")
check(r["steps"][1]["result"]["frames"] is None, "a step's own measurement is off inside a scenario")

c.send("view.set", START)
print()
print("%d assertions, %d failed" % (count, len(fails)))
for f in fails:
    print("  FAIL " + f)
sys.exit(1 if fails else 0)

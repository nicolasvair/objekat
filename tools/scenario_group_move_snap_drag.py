#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The snap of a MOVE under a real mouse drag (`input.drag`, UI mode): the grabbed object is the
ONLY reference of the snap, the other moved objects follow with the same travel, and nothing the
hand carries is a magnet. Twin of `scenario_group_move_snap.py` (which drives the release alone).

    objekat.app/Contents/MacOS/objekat --api --no-recent --socket=/tmp/o.sock
    ./scenario_group_move_snap_drag.py /tmp/o.sock

At 100 px/s the grid is 0.5 s and the reach of a mark 0.08 s (8 px).

Exit: 0 if every assertion passes, 1 otherwise.
"""

import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient
import scenario_canvas_nested as s

if len(sys.argv) != 2:
    print(__doc__)
    sys.exit(2)

BIP = os.path.join(HERE, "fixtures", "bip.wav")
EPS = 1e-6
fails = []
count = 0


def check(cond, label):
    global count
    count += 1
    print(("  OK   " if cond else "  FAIL ") + label)
    if not cond:
        fails.append(label)


c = ObjekatClient(sys.argv[1], timeout=120)
c.connect()


def settle(ms=300):
    s.settle(c, ms)


def fresh():
    c.send("project.new")
    c.send("project.set_snap", {"enabled": True})
    settle()


def add(lane, start, dur=1.0):
    return c.send("object.add", {"path": BIP, "lane": lane, "start": start, "duration": dur})["id"]


def start(i):
    return c.send("object.get", {"id": i})["start"]


def on_grid(t, g=0.5):
    return abs(t / g - round(t / g)) < 1e-6


def drag(oid, dx):
    c.send("view.set", {"pps": 100, "block_height": 60, "scroll_x": 0, "scroll_y": 0}); settle()
    x, y = s.find_zone(c, oid, "move")
    c.send("input.drag", {"x": x, "y": y, "dx": dx, "dy": 0, "duration_ms": 400})
    settle(500)


# ── 1. Two clips off the grid: the grabbed one snaps, the other keeps its gap ────────────────
print("two clips, snap ON: one travel for both")
fresh()
a = add(0, 1.13)
b = add(1, 3.41)
c.send("selection.set", {"ids": [a, b]}); settle()
drag(a, 190)
sa, sb = start(a), start(b)
check(on_grid(sa), "the grabbed clip lands on the grid: %s" % sa)
check(abs((sb - sa) - 2.28) < EPS, "the gap is kept (%.6f, expected 2.28)" % (sb - sa))
check(not on_grid(sb), "the other clip was NOT snapped on its own: %s" % sb)

# ── 2. A carried open group: its child's mark is not a magnet ───────────────────────────────
# The child carries a mark 0.32 s after the group's start. Carried by 0.34 s, the group's start
# reaches 0.02 s from where that mark WAS (the grid being 0.03 s away): a magnet on oneself would
# land it there (travel 0.32); the mark travels with the hand, so the grid must win (start on 0.5).
print("open group carrying a marked child: no self-magnet")
fresh()
x = add(0, 1.13, 2.0)
g = c.send("group.create", {"ids": [x]})["id"]
c.send("group.expand", {"id": g, "expanded": True}); settle()
g0 = start(g)
c.send("object.add_marker", {"object": x, "at": g0 + 0.32}); settle()
c.send("selection.set", {"ids": [g]}); settle()
drag(g, 34)
sg = start(g)
check(abs(sg - (g0 + 0.32)) > 1e-3, "the group did not stick to its own child's mark (%s)" % sg)
check(on_grid(sg) or on_grid(sg + c.send("object.get", {"id": g})["duration"]),
      "the group landed on the grid instead: %s" % sg)

print("\n%d/%d OK" % (count - len(fails), count))
sys.exit(1 if fails else 0)

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""A move of SEVERAL objects with the snap ON keeps the gaps between them — asserted through
`debug.move_drop` (DEBUG build only), the very function the drag handler calls on release
(`EditViewModel.commitMoveDrop`).

The fault (5 October 2026): the gesture snapped ONE travel `dt` off the grabbed object, but the
release then went through `updateStartTime`, which snapped EACH start again on its own — every
object jumped to its own nearest grid line and the moved objects drifted apart in time. The release
now applies `dt` as is; only the API's `object.move` (one object, `snap: true`) still snaps.

    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --socket=/tmp/o.sock
    ./scenario_group_move_snap.py /tmp/o.sock

At the default zoom (100 px/s) the grid is 0.5 s and the tolerance 0.08 s: every start below is
OFF the grid and far from every other edge, so a per-object re-snap would always show.

Exit: 0 if every assertion passes, 1 otherwise.
"""

import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient

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


c = ObjekatClient(sys.argv[1])
c.connect()


def settle(ms=300):
    c.send("wait_idle", {"timeout_ms": 120000, "settle_ms": ms})


def fresh():
    c.send("project.new")
    c.send("project.set_snap", {"enabled": True})
    settle()


def add(lane, start):
    return c.send("object.add", {"path": BIP, "lane": lane, "start": start, "duration": 1.0})["id"]


def start(i):
    return c.send("object.get", {"id": i})["start"]


# ── 0. Sanity: the grid IS active (otherwise nothing below would prove anything) ──────────────
print("sanity: the API's single-object move still snaps")
fresh()
a = add(0, 0.0)
c.send("object.move", {"id": a, "start": 1.13, "snap": True}); settle()
check(abs(start(a) - 1.0) < EPS, "object.move snap:true lands 1.13 on the grid (1.0): %s" % start(a))
c.send("object.move", {"id": a, "start": 1.13, "snap": False}); settle()
check(abs(start(a) - 1.13) < EPS, "object.move snap:false keeps 1.13: %s" % start(a))

# ── 1. Two root clips, off the grid, carried together ───────────────────────────────────────
print("two root clips, snap ON")
fresh()
a = add(0, 1.13)
b = add(1, 3.41)
settle()
r = c.send("debug.move_drop", {"id": a, "ids": [b], "dt": 2.0, "dl": 0}); settle()
check(r.get("decision") == "root", "decision root (%s)" % r.get("decision"))
sa, sb = start(a), start(b)
check(abs(sa - 3.13) < EPS, "grabbed clip carried by exactly dt: %s" % sa)
check(abs(sb - 5.41) < EPS, "other clip carried by exactly dt (not re-snapped to 5.5): %s" % sb)
check(abs((sb - sa) - 2.28) < EPS, "gap kept: %.6f" % (sb - sa))
c.send("edit.undo"); settle()
check(abs(start(a) - 1.13) < EPS and abs(start(b) - 3.41) < EPS, "one undo gives the move back")

# ── 2. A root group and a clip, carried together ────────────────────────────────────────────
print("root group + clip, snap ON")
fresh()
x = add(0, 1.13)
y = add(1, 2.77)
g = c.send("group.create", {"ids": [x, y]})["id"]
z = add(2, 6.41)
settle()
g0, z0 = start(g), start(z)
r = c.send("debug.move_drop", {"id": z, "ids": [g], "dt": 1.6, "dl": 0}); settle()
check(r.get("decision") == "root", "decision root (%s)" % r.get("decision"))
check(abs(start(z) - (z0 + 1.6)) < EPS, "clip carried by exactly dt: %s" % start(z))
check(abs(start(g) - (g0 + 1.6)) < EPS, "group carried by exactly dt: %s" % start(g))
check(abs((start(z) - start(g)) - (z0 - g0)) < EPS, "gap group / clip kept")
c.send("group.expand", {"id": g, "expanded": True}); settle()
check(abs(start(x) - (1.13 + 1.6)) < EPS and abs(start(y) - (2.77 + 1.6)) < EPS,
      "the group's children follow by the same dt: %s, %s" % (start(x), start(y)))

# ── 3. Two children moved inside their own (open) group ─────────────────────────────────────
print("two children inside their group, snap ON")
fresh()
x = add(0, 1.13)
y = add(1, 2.77)
g = c.send("group.create", {"ids": [x, y]})["id"]
c.send("group.expand", {"id": g, "expanded": True}); settle()
r = c.send("debug.move_drop", {"id": x, "ids": [y], "dt": 0.9, "dl": 0}); settle()
check(r.get("decision") == "move_in_source", "decision move_in_source (%s)" % r.get("decision"))
check(abs(start(x) - 2.03) < EPS and abs(start(y) - 3.67) < EPS,
      "both children carried by exactly dt: %s, %s" % (start(x), start(y)))

print("\n%d/%d OK" % (count - len(fails), count))
sys.exit(1 if fails else 0)

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The floor at t = 0 for every moved object, at any depth (`Shared/ZeroFloor.swift`, rules of
16 October 2026), driven with no screen.

Doors used: `object.move` (one object, one step), `debug.move_drop` (the RELEASE of a drag — the
function the drag handler calls when the hand lets go, DEBUG builds only), `object.trim`,
`clipboard.paste`, and `perf.census` (`undo_depth`) for the undo convention. The per-gesture memory
(R4, sticky once 0 is reached) lives in the drag itself and has no headless door: it is asserted by
`tools/test_zero_floor.swift`, with the multi-selection mixing children and root objects (R5).

    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --socket=/tmp/o.sock
    ./scenario_zero_floor.py /tmp/o.sock

The snap is OFF except in the R9 block. Exit: 0 if every assertion passes, 1 otherwise.
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


def fresh(snap=False):
    c.send("project.new")
    c.send("project.set_snap", {"enabled": snap})
    settle()


def add(lane, start, dur=1.0):
    return c.send("object.add", {"path": BIP, "lane": lane, "start": start, "duration": dur})["id"]


def start(i):
    return c.send("object.get", {"id": i})["start"]


def move(i, s, snap=False):
    c.send("object.move", {"id": i, "start": s, "snap": snap})
    settle()


def drop(i, dt, ids=None):
    p = {"id": i, "dt": dt, "dl": 0}
    if ids:
        p["ids"] = ids
    r = c.send("debug.move_drop", p)
    settle()
    return r


def undo_depth():
    return c.send("perf.census")["undo_depth"]


def undo():
    c.send("edit.undo")
    settle()


def near(a, b):
    return abs(a - b) < EPS


def scene_a20_c10():
    """Group A@20 holding c@10 (absolute) and e@13.63, open so its children are on screen."""
    fresh()
    cc = add(0, 20.0)
    ee = add(1, 23.63)
    g = c.send("group.create", {"ids": [cc, ee]})["id"]
    settle()
    move(cc, 10.0)
    move(ee, 13.63)
    c.send("group.expand", {"id": g, "expanded": True})
    settle()
    return g, cc, ee


# ── R1: a child is floored at 0 ─────────────────────────────────────────────────────────────────
print("R1 — a child of a group stops at 0")
g, cc, ee = scene_a20_c10()
check(near(start(g), 20.0) and near(start(cc), 10.0), "scene: A@20, c@10 (%s, %s)" % (start(g), start(cc)))
r = drop(cc, -15.0)
check(r.get("decision") == "move_in_source", "release inside the group (%s)" % r.get("decision"))
check(near(start(cc), 0.0), "c@10 dragged -15 stops at 0 (moved -10): %s" % start(cc))
check(near(start(g), 20.0), "... A has not moved: %s" % start(g))
undo()
check(near(start(cc), 10.0), "one undo gives c back at 10: %s" % start(cc))
move(cc, -5.0)
check(near(start(cc), 0.0), "object.move c@10 to -5 lands at 0: %s" % start(cc))
undo()

# ── R2: a group is floored by its own start, its children may go negative ──────────────────────
print("R2 — a group stops at 0, its children follow before 0")
r = drop(g, -25.0)
check(r.get("decision") == "root", "release at the root (%s)" % r.get("decision"))
check(near(start(g), 0.0), "A@20 dragged -25 stops at 0 (moved -20): %s" % start(g))
check(near(start(cc), -10.0), "... c carried to -10: %s" % start(cc))
check(near(start(ee), -6.37), "... e carried to -6.37: %s" % start(ee))
undo()
check(near(start(g), 20.0) and near(start(cc), 10.0), "one undo gives the tree back")
move(g, -5.0)
check(near(start(g), 0.0) and near(start(cc), -10.0), "object.move A to -5: A 0, c -10 (%s, %s)"
      % (start(g), start(cc)))

# ── R3: an object starting negative is free while it stays negative ────────────────────────────
print("R3 — a negative start is not floored while it stays negative")
r = drop(cc, -5.0)
check(near(start(cc), -15.0), "c@-10 dragged -5 -> -15: %s" % start(cc))
undo()
drop(cc, 4.0)
check(near(start(cc), -6.0), "c@-10 dragged +4 -> -6: %s" % start(cc))
undo()
drop(cc, 15.0)
check(near(start(cc), 5.0), "c@-10 dragged +15 -> +5 (crosses 0): %s" % start(cc))
undo()
move(cc, -12.0)
check(near(start(cc), -12.0), "object.move c@-10 to -12 stays -12: %s" % start(cc))
undo()
check(near(start(cc), -10.0), "... undone: %s" % start(cc))

# ── R5: a selection keeps its spacing, the most constraining object wins ──────────────────────
print("R5 — one common travel")
# c@-10 and e@-6.37 (both negative): free together.
drop(cc, -3.0, [ee])
check(near(start(cc), -13.0) and near(start(ee), -9.37), "two negative children dragged -3: -13, -9.37")
undo()
# e brought to 5 (a positive start), c still at -10: dragged -8 -> e blocks at 0, both move -5.
move(ee, 5.0)
drop(cc, -8.0, [ee])
check(near(start(ee), 0.0), "c1@-10, c2@5 dragged -8: c2 blocks at 0: %s" % start(ee))
check(near(start(cc), -15.0), "... c1 moved the same -5, to -15: %s" % start(cc))
undo()
undo()
fresh()
k1 = add(0, 3.0)
k2 = add(1, 8.0)
gk = c.send("group.create", {"ids": [k1, k2]})["id"]
settle()
c.send("group.expand", {"id": gk, "expanded": True})
settle()
drop(k1, -10.0, [k2])
check(near(start(k1), 0.0) and near(start(k2), 5.0),
      "children c1@3, c2@8 dragged -10 -> all move -3 (0, 5): %s, %s" % (start(k1), start(k2)))

# ── R6: nested groups ─────────────────────────────────────────────────────────────────────────
print("R6 — A@20 > B@15 > c@12, B dragged -20")
fresh()
n = add(0, 20.0)
ga = c.send("group.create", {"ids": [n]})["id"]
settle()
c.send("group.expand", {"id": ga, "expanded": True})
settle()
gb = c.send("group.create", {"ids": [n]})["id"]   # a subgroup: the member's parent is A
settle()
move(gb, 15.0)
move(n, 12.0)
c.send("group.expand", {"id": gb, "expanded": True})
settle()
check(near(start(ga), 20.0) and near(start(gb), 15.0) and near(start(n), 12.0),
      "scene: A %s, B %s, c %s" % (start(ga), start(gb), start(n)))
drop(gb, -20.0)
check(near(start(gb), 0.0), "B@15 dragged -20 stops at 0: %s" % start(gb))
check(near(start(n), -3.0), "... c@12 goes to -3 (B is not blocked by c): %s" % start(n))
check(near(start(ga), 20.0), "... A has not moved: %s" % start(ga))

# ── R7: the left-edge trim ────────────────────────────────────────────────────────────────────
print("R7 — a trim never extends a start below 0")
c.send("object.trim", {"id": gb, "start": -4.0, "duration": 6.0})
settle()
check(near(start(gb), 0.0), "group B@0 trimmed to -4 stays at 0: %s" % start(gb))
undo()
d0 = undo_depth()
c.send("object.trim", {"id": n, "start": -5.0, "duration": 1.0})
settle()
check(near(start(n), -3.0), "c@-3 trimmed to -5: no extension, stays -3: %s" % start(n))
# Nothing changed, so no undo point: an undo here would take back the PREVIOUS gesture (the drop).
check(undo_depth() == d0, "... and that refused trim pushed no undo point (%d -> %d)" % (d0, undo_depth()))
if undo_depth() > d0:
    undo()
c.send("object.trim", {"id": n, "start": -2.5, "duration": 0.5})
settle()
check(near(start(n), -2.5), "c@-3 trimmed to -2.5 (cropping the negative head) is kept: %s" % start(n))
undo()
fresh()
t1 = add(0, 2.0, 3.0)
gt = c.send("group.create", {"ids": [t1]})["id"]
settle()
c.send("object.trim", {"id": gt, "start": -1.0, "duration": 6.0})
settle()
check(near(start(gt), 0.0), "root group @2 trimmed to -1 floors at 0: %s" % start(gt))

# ── undo: a release the floor held entirely leaves no undo point ──────────────────────────────
print("undo — nothing moved, no undo point")
g, cc, ee = scene_a20_c10()
move(cc, 0.0)
d0 = undo_depth()
r = drop(cc, -4.0)
check(near(start(cc), 0.0), "c@0 dragged -4 stays at 0: %s" % start(cc))
check(undo_depth() == d0, "... and pushed no undo point (%d -> %d)" % (d0, undo_depth()))
drop(cc, 2.0)
check(undo_depth() == d0 + 1, "a real move pushes exactly one (%d -> %d)" % (d0, undo_depth()))

# ── paste: what is pasted lands at or after 0 ────────────────────────────────────────────────
print("paste — a pasted negative child lands at the caret")
g, cc, ee = scene_a20_c10()
move(g, 0.0)                       # c -> -10, e -> -6.37
c.send("selection.set", {"ids": [cc]})
c.send("clipboard.copy")
c.send("transport.seek", {"seconds": 2.0})
settle()
r = c.send("clipboard.paste")
settle()
pasted = [i for i in r.get("ids", []) if i != cc]
check(len(pasted) == 1 and near(start(pasted[0]), 2.0),
      "the copy of c@-10 is pasted at the cursor (2.0): %s" % [start(i) for i in pasted])

# ── R9: an edge before 0 is never a snap target ───────────────────────────────────────────────
print("R9 — no snap onto an invisible edge (snap ON, 0.5 s grid, 0.08 s reach at the default zoom)")
fresh(snap=True)
a1 = add(0, 20.13)
a2 = add(1, 23.63)
gr = c.send("group.create", {"ids": [a1, a2]})["id"]
settle()
move(a1, 10.13)
move(a2, 15.0)
move(gr, 0.0)                      # the group carries a1 to 10.13 - 20.13 = -10 (R2)
move(a1, -9.87)                    # off the grid: a1 = -9.87 .. -8.87 (negative, R3: free)
c.send("group.disband", {"id": gr})
settle()
check(near(start(a1), -9.87), "a root object at -9.87 .. -8.87 after dissolving: %s" % start(a1))
# a2 (negative, free) aimed at -8.9: the invisible end -8.87 is 0.03 away, the grid's -9.0 is 0.1.
move(a2, -8.9, snap=True)
check(not near(start(a2), -8.87), "a2 aimed at -8.9 does NOT snap onto the invisible -8.87: %s" % start(a2))
check(near(start(a2), -9.0), "... it lands on the grid (-9.0): %s" % start(a2))
# Sanity: the same geometry after 0 DOES snap (the mechanism is alive).
z = add(2, 30.13)
y = add(3, 40.0)
move(y, 31.1, snap=True)
check(near(start(y), 31.13), "sanity: aimed at 31.1, snaps onto the visible end 31.13: %s" % start(y))

print("%d checks, %d failed" % (count, len(fails)))
print("ALL PASS" if not fails else "FAILED: %s" % fails)
sys.exit(1 if fails else 0)

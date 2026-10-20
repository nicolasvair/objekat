#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Straightening an automation segment, and the straight-line detent of the ⌥-wheel — what the
model answers to the calls the GESTURES make (`automation.*`).

The gestures themselves (⌥ + double click on a segment, ⌥ + the wheel) cannot be driven from
here: the headless API has no pointer. What this proves is the half underneath them:

  * `automation.straighten` (the ⌥ double click) zeroes c on the segment's left point, in ONE undo
    point, and pushes none when the segment was already straight;
  * with `selection: true` (the double click landing inside a selection) every segment whose two
    ends are selected goes straight, and nothing else;
  * `automation.wheel_curvature` (the ⌥-wheel) adds its notches up from the gesture's start and
    stops on the straight line when it crosses it, for one more notch.

The detent's arithmetic itself is asserted by `tools/test_automation_curve_shape.swift`.

    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --socket=/tmp/o.sock
    ./scenario_automation_curve.py /tmp/o.sock

Exit: 0 if every assertion passes, 1 otherwise.
"""

import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

if len(sys.argv) != 2:
    print(__doc__)
    sys.exit(2)

SOCK = sys.argv[1]
BIP = os.path.join(HERE, "fixtures", "bip.wav")
fails = []


def check(label, ok, detail=""):
    if ok:
        print("ok    " + label)
    else:
        fails.append(label)
        print("FAIL  %s  %s" % (label, detail))


with ObjekatClient(SOCK) as c:
    def cmd(name, **params):
        return c.send(name, params or None)

    cmd("project.new")
    oid = cmd("object.add", path=BIP, lane=0, start=1.0)["id"]

    def lane():
        for l in cmd("automation.list", id=oid)["lanes"]:
            if l["param"] == "volume":
                return l["points"]
        return []

    def cs():
        return [round(p["c"], 6) for p in lane()]

    # Storage order deliberately NOT time order: index 0 is the point at t = 0.3.
    pts = [{"t": 0.3, "v": 0, "c": 0.5},
           {"t": 0.0, "v": -24, "c": 0.4},
           {"t": 0.1, "v": -6, "c": -0.3},
           {"t": 0.4, "v": -12, "c": 0.0}]
    cmd("automation.set_points", id=oid, param="volume", points=pts)
    check("set_points lays the curve as given", cs() == [0.5, 0.4, -0.3, 0.0], str(cs()))

    # --- straightening one segment (the ⌥ double click) -----------------------------------------
    r = cmd("automation.straighten", id=oid, param="volume", index=2)
    check("straighten one: answers 1 bent", r["straightened"] == 1, str(r))
    check("straighten one: c = 0 on that point only", cs() == [0.5, 0.4, 0.0, 0.0], str(cs()))
    cmd("edit.undo")
    check("straighten one: ONE undo gives the bend back", cs() == [0.5, 0.4, -0.3, 0.0], str(cs()))
    cmd("edit.redo")
    check("straighten one: redo", cs() == [0.5, 0.4, 0.0, 0.0], str(cs()))

    before = cmd("perf.census")["undo_depth"]
    r = cmd("automation.straighten", id=oid, param="volume", index=2)
    check("an already straight segment: nothing bent", r["straightened"] == 0, str(r))
    after = cmd("perf.census")["undo_depth"]
    check("an already straight segment: no undo point", before == after, "%s -> %s" % (before, after))
    cmd("edit.undo")
    check("…so the next undo is the previous straighten", cs() == [0.5, 0.4, -0.3, 0.0], str(cs()))

    # --- straightening the segments a selection holds -------------------------------------------
    # Selected: t=0 (idx 1), t=0.1 (idx 2) and t=0.4 (idx 3) — t=0.3 (idx 0) is NOT. The only
    # segment with both ends selected is 0 → 0.1 (owner idx 1); 0.1 → 0.3 and 0.3 → 0.4 each lack one.
    cmd("automation.select_points", id=oid, param="volume", indices=[1, 2, 3])
    r = cmd("automation.straighten", selection=True)
    check("selection: one segment held, one bent", r["straightened"] == 1 and r["segments"] == 1, str(r))
    check("selection: only the segment with BOTH ends selected", cs() == [0.5, 0.0, -0.3, 0.0], str(cs()))
    cmd("edit.undo")
    cmd("automation.select_points", id=oid, param="volume", indices=[0, 1, 2, 3])
    r = cmd("automation.straighten", selection=True)
    check("selection: all selected → every bent segment", r["straightened"] == 3, str(r))
    check("selection: whole curve straight", cs() == [0.0, 0.0, 0.0, 0.0], str(cs()))
    cmd("edit.undo")
    check("selection: ONE undo for the lot", cs() == [0.5, 0.4, -0.3, 0.0], str(cs()))
    r = cmd("automation.straighten", id=oid, param="volume")
    check("no index = every segment of the curve", r["straightened"] == 3 and cs() == [0.0] * 4, str(r))
    cmd("edit.undo")

    # --- the ⌥-wheel through the detent ----------------------------------------------------------
    # Segment t=0 → 0.1 (owner idx 1) RISES (-24 → -6). Start straight, three notches up, then down.
    cmd("automation.straighten", id=oid, param="volume", index=1)
    seen = []
    first = True
    for k in [1, 1, 1]:
        cmd("automation.wheel_curvature", id=oid, param="volume", index=1, steps=k, new_gesture=first)
        first = False
        seen.append(cs()[1])
    check("wheel from straight: the curve bends at the first notch", seen[0] != 0, str(seen))
    check("wheel: bends further notch after notch", abs(seen[2]) > abs(seen[1]) > abs(seen[0]), str(seen))
    down = []
    for k in [-1] * 6:
        cmd("automation.wheel_curvature", id=oid, param="volume", index=1, steps=k, new_gesture=False)
        down.append(cs()[1])
    zeros = [d for d in down if d == 0]
    check("wheel: crossing straight holds it for two notches", len(zeros) == 2, str(down))
    check("wheel: and leaves it on the other side", down[-1] != 0 and (down[-1] > 0) != (seen[2] > 0), str(down))
    # A NEW gesture from a bent curve: notches back the same way land exactly on straight.
    cur = cs()[1]
    cmd("automation.wheel_curvature", id=oid, param="volume", index=1, steps=1, new_gesture=True)
    nxt = cs()[1]
    check("wheel: a new gesture moves from where the curve is", nxt != cur, "%s -> %s" % (cur, nxt))
    # undo after one gesture of wheel = back to before that gesture
    cmd("edit.undo")
    check("wheel: one undo per gesture", cs()[1] == cur, "%s vs %s" % (cs()[1], cur))

    # Errors.
    try:
        cmd("automation.straighten", id=oid, param="volume", index=99)
        check("index out of range refused", False)
    except ObjekatError:
        check("index out of range refused", True)
    try:
        cmd("automation.set_points", id=oid, param="nonsense", points=[])
        check("unknown param refused", False)
    except ObjekatError:
        check("unknown param refused", True)

print("\n%d failed" % len(fails) if fails else "\nALL PASS")
sys.exit(1 if fails else 0)

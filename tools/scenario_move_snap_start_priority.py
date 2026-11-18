#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The START of a moved object has the magnet's priority over its END (17 November 2026), and the
snap of a file drop (`debug.file_drop` with `snap`).

    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --socket=/tmp/o.sock
    ./scenario_move_snap_start_priority.py /tmp/o.sock

@see Shared/ObjectMoveSnap.swift (the pure rule, tools/test_object_move_snap.swift), `snapObjectMove`.
Asserted through `debug.move_snap` (`use_end`: the END won). At the default zoom the grid is 0.5 s and the
tolerance 0.08 s; the marks below are off the grid so only a mark can have been reached.

  S1  both edges within reach of a mark, the END the nearer: the START wins (use_end false)
  S2  only the end within reach: the end lands
  S3  no mark in reach: the GRID on the START (never on the end), though the end is nearer to a line
  S4  a mark out of reach of the start (0.09) and the end within: the end
  S5  the CARET is a target like a mark, same precedence
  S6  snap off: the raw start, whatever is around
  S7  an object's edge is a target the same way (a neighbour object)
  F1  debug.file_drop: snap true -> the grid on the start; snap false -> the start as it is; a mark wins

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
fails = []
count = 0


def check(label, ok, detail=""):
    global count
    count += 1
    if ok:
        print("ok    " + label)
    else:
        fails.append(label)
        print("FAIL  %s  %s" % (label, detail))


def near(a, b, eps=1e-6):
    return a is not None and abs(a - b) < eps


with ObjekatClient(sys.argv[1]) as c:
    def cmd(_cmd_name, **p):
        return c.send(_cmd_name, p or None)

    def fresh(snap=True):
        cmd("project.new")
        cmd("project.set_snap", enabled=snap)
        lane = cmd("marker_lane.create", name="snap")["lane"]
        return lane

    def probe(i, dt):
        return cmd("debug.move_snap", id=i, raw_dt=dt)

    def add(start, dur, lane=0):
        return cmd("object.add", path=BIP, lane=lane, start=start, duration=dur)["id"]

    # ------------------------------------------------------------------ S1 .. S4: markers
    lane = fresh()
    a = add(0.0, 1.0)
    cmd("marker.add", lane=lane, at=5.07)       # the start (5.0) is 0.07 away
    cmd("marker.add", lane=lane, at=6.01)       # the end (6.0) is 0.01 away: nearer
    r = probe(a, 5.0)
    check("S1 both edges in reach, the end nearer: the START wins",
          r["use_end"] is False and near(r["start"], 5.07) and r["guide"]["on_target"] is True, str(r))
    check("S1 the guide stands on the start's mark", near(r["guide"]["time"], 5.07), str(r["guide"]))

    lane = fresh()
    a = add(0.0, 1.0)
    cmd("marker.add", lane=lane, at=6.01)
    r = probe(a, 5.0)
    check("S2 only the end in reach: the end lands (start 5.01)",
          r["use_end"] is True and near(r["start"], 5.01) and r["guide"]["on_target"] is True, str(r))

    lane = fresh()
    a = add(0.0, 0.9)
    r = probe(a, 5.2)         # start 5.2 (0.2 from 5.0), end 6.1 (0.1 from 6.0): the end is nearer to a line
    check("S3 no mark: the grid on the START though the end is nearer to a line",
          r["use_end"] is False and near(r["start"], 5.0) and r["guide"]["on_target"] is False, str(r))

    lane = fresh()
    a = add(0.0, 1.0)
    cmd("marker.add", lane=lane, at=5.09)       # 0.09 from the start: out of reach
    cmd("marker.add", lane=lane, at=6.05)       # the end (6.0) 0.05
    r = probe(a, 5.0)
    check("S4 start out of reach (0.09), end in reach: the end",
          r["use_end"] is True and near(r["start"], 5.05), str(r))

    # ------------------------------------------------------------------ S5: the caret
    lane = fresh()
    a = add(0.0, 1.0)
    cmd("marker.add", lane=lane, at=6.01)
    cmd("caret.set", lane=3, time=5.07)
    r = probe(a, 5.0)
    check("S5 caret within reach of the start, a mark of the end nearer: the START (the caret)",
          r["use_end"] is False and near(r["start"], 5.07), str(r))

    # ------------------------------------------------------------------ S6: snap off
    lane = fresh(snap=False)
    a = add(0.0, 1.0)
    cmd("marker.add", lane=lane, at=5.07)
    r = probe(a, 5.0)
    check("S6 snap off: the raw start", near(r["start"], 5.0) and r["use_end"] is False, str(r))

    # ------------------------------------------------------------------ S7: a neighbour object
    fresh()
    a = add(0.0, 1.0, lane=0)
    add(5.07, 0.93, lane=1)        # starts 5.07, ends 6.0 (exactly at the end of A once moved)
    r = probe(a, 5.0)
    check("S7 neighbour: its START (5.07) catches A's start, not its end (6.0 on A's end)",
          r["use_end"] is False and near(r["start"], 5.07), str(r))

    # ------------------------------------------------------------------ F1: the file drop
    lane = fresh()
    d = cmd("debug.file_drop", paths=[BIP], lane=0, start=1.23, snap=True)
    check("F1 snap true: the grid on the start (1.0)", near(d["placed"][0]["start"], 1.0), str(d["placed"]))
    d = cmd("debug.file_drop", paths=[BIP], lane=1, start=1.23, snap=False)
    check("F1 snap false: the start as it is (1.23)", near(d["placed"][0]["start"], 1.23), str(d["placed"]))
    d = cmd("debug.file_drop", paths=[BIP], lane=2, start=1.23)
    check("F1 snap absent: the start as it is", near(d["placed"][0]["start"], 1.23), str(d["placed"]))
    cmd("marker.add", lane=lane, at=3.07)
    # the drop reads `snappedTimePure` (single instant: a mark wins only when it is NEARER than the grid line,
    # unlike a MOVE where a real mark always beats the grid) — unchanged by the lot, so 3.06 is asserted
    d = cmd("debug.file_drop", paths=[BIP], lane=3, start=3.06, snap=True)
    check("F1 a mark nearer than the grid line wins (3.07, not 3.0)", near(d["placed"][0]["start"], 3.07), str(d["placed"]))

print("\n%d assertions, %d failed" % (count, len(fails)))
print("ALL PASS" if not fails else "FAILED:\n  " + "\n  ".join(fails))
sys.exit(1 if fails else 0)

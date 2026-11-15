#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The CARET is a snap target for an object being moved (`CaretSnap`) — asserted through
`debug.move_snap` (DEBUG build only), the very function the drag handler calls on every frame
(`EditViewModel.snapObjectMove`).

    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --socket=/tmp/o.sock
    ./scenario_caret_move_snap.py /tmp/o.sock

At the default zoom (100 px/s) the grid is 0.5 s and the tolerance 0.08 s. The caret stands at 4.27,
OFF the grid and far from every other edge: only the caret can pull a start (or an end) onto it.

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


def fresh(snap=True):
    c.send("project.new")
    c.send("project.set_snap", {"enabled": snap})
    settle()


def snap(i, raw_dt):
    return c.send("debug.move_snap", {"id": i, "raw_dt": raw_dt})


def add(lane, start, dur=1.0):
    return c.send("object.add", {"path": BIP, "lane": lane, "start": start, "duration": dur})["id"]


# ── 1. Caret laid at 4.27: the START lands on it ───────────────────────────────────────────
print("caret at 4.27, snap ON")
fresh()
a = add(0, 0.0)
settle()
c.send("caret.set", {"lane": 3, "time": 4.27}); settle()
r = snap(a, 4.23)
check(abs(r["start"] - 4.27) < EPS, "raw start 4.23 lands on the caret 4.27 (not on the grid 4.0): %s" % r["start"])
check(not r["use_end"], "the START won")
check(r["guide"] is not None and r["guide"]["on_target"] and abs(r["guide"]["time"] - 4.27) < EPS,
      "the guide stands on the caret and is lit (onTarget): %s" % r["guide"])

# ── 2. ... and the END lands on it too ────────────────────────────────────────────────────
r = snap(a, 3.30)          # the end (duration 1.0) is at 4.30
check(r["use_end"], "the END won")
check(abs(r["start"] + 1.0 - 4.27) < EPS, "the END (start + 1.0) lands on the caret: %s" % (r["start"] + 1.0))
check(r["guide"] is not None and r["guide"]["on_target"] and abs(r["guide"]["time"] - 4.27) < EPS,
      "guide on the caret, lit: %s" % r["guide"])

# ── 3. Out of reach (more than 8 px = 0.08 s): the grid decides ───────────────────────────
r = snap(a, 4.10)
check(abs(r["start"] - 4.0) < EPS and not r["guide"]["on_target"],
      "raw start 4.10 is out of the caret's reach: grid 4.0, guide grey: %s %s" % (r["start"], r["guide"]))

# ── 4. The lane of the caret is of no importance ───────────────────────────────────────────
c.send("caret.set", {"lane": 0, "time": 4.27}); settle()
check(abs(snap(a, 4.23)["start"] - 4.27) < EPS, "caret on another lane: same instant, same landing")

# ── 5. A time selection hides the caret: it is no target any more ──────────────────────────
c.send("caret.set", {"lane": 3, "time": 4.27}); settle()
c.send("timesel.set", {"start": 8.0, "end": 9.0, "lanes": [5]}); settle()
r = snap(a, 4.23)
check(abs(r["start"] - 4.0) < EPS, "with a time selection up, the caret is not a magnet (grid 4.0): %s" % r["start"])

# ── 6. No caret at all: the grid ──────────────────────────────────────────────────────────
print("no caret, snap ON")
fresh()
a = add(0, 0.0)
settle()
r = snap(a, 4.23)
check(abs(r["start"] - 4.0) < EPS and not r["guide"]["on_target"],
      "without a caret raw start 4.23 goes to the grid 4.0, grey: %s %s" % (r["start"], r["guide"]))

# ── 7. Snap OFF: nothing, not even the caret ──────────────────────────────────────────────
print("caret at 4.27, snap OFF")
fresh(snap=False)
a = add(0, 0.0)
settle()
c.send("caret.set", {"lane": 3, "time": 4.27}); settle()
r = snap(a, 4.23)
check(abs(r["start"] - 4.23) < EPS, "snap off: the start stays where the hand put it (4.23): %s" % r["start"])

print("\n%d/%d OK" % (count - len(fails), count))
sys.exit(1 if fails else 0)

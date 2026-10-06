#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""What a time selection LANDS ON when the hand carries it — asserted through `timesel.snap_probe`.

The drag itself (a mouse gesture on the timeline) cannot be driven from here. What this proves is
the half underneath it: the precedence the gesture reads its answer from (`SelectionMoveSnap`, plus
`EditViewModel.selectionMoveExcluded` for what is kept out of the targets). The decision table is
also asserted alone by `tools/test_selection_move_snap.swift`.

  * the range's START lands on a real mark even when the range begins in silence (no object edge
    there) — which the old two-edges-of-the-grabbed-object snap could never do;
  * a real mark beats the grid even when the grid line is nearer;
  * only the range's bounds are references: a mark that only the grabbed object's edge would
    reach is ignored, the bounds then go to the grid (`grab` no longer exists);
  * the range's END lands on a mark the start does not reach;
  * snap off: the raw travel;
  * the wall at zero belongs to the RANGE: an object lying later does not limit the travel;
  * without ⌥ the scraps a cut leaves at the two bounds are NOT targets (no magnet on oneself);
    with ⌥ the originals stay in place and ARE.

    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --socket=/tmp/o.sock
    ./scenario_selection_snap.py /tmp/o.sock

At the default zoom (100 px/s) the tolerance is 0.08 s and the grid 0.5 s; the marks below are off
the grid on purpose, so that only the mark can have been reached.

Exit: 0 if every assertion passes, 1 otherwise.
"""

import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

if len(sys.argv) != 2:
    print(__doc__)
    sys.exit(2)

SOCK = sys.argv[1]
fails = []


def check(label, ok, detail=""):
    if ok:
        print("ok    " + label)
    else:
        fails.append(label)
        print("FAIL  %s  %s" % (label, detail))


def near(a, b, eps=1e-6):
    return abs(a - b) < eps


with ObjekatClient(SOCK) as c:
    def cmd(_cmd_name, **params):
        return c.send(_cmd_name, params or None)

    info = cmd("app.info")
    check("--no-recent honoured", info.get("records_recent_projects") is False,
          str(info.get("records_recent_projects")))

    def fresh():
        cmd("project.new")
        cmd("project.set_snap", enabled=True)
        return cmd("marker_lane.create", name="snap")["lane"]

    def mark(lane, at):
        return cmd("marker.add", lane=lane, at=at)["marker"]

    def probe(dt, **kw):
        return cmd("timesel.snap_probe", dt=dt, **kw)

    # ── a range that begins in SILENCE ───────────────────────────────────────────────────────
    # M1 starts at 4.8, the range is 4 -> 6: nothing at all sits at the range's start.
    lane = fresh()
    cmd("midi.create_clip", start=4.8, end=9.0, lane=0)["id"]
    cmd("timesel.set", start=4.0, end=6.0, lanes=[0])
    mk = mark(lane, 10.03)

    r = probe(6.02)
    check("the range's START lands on a marker, the range beginning in silence",
          near(r["start"], 10.03) and r["edge"] == "start" and r["on_target"] is True
          and near(r["guide_time"], 10.03), json.dumps(r))
    # 10.01 is 0.01 from the grid line 10.0 and 0.02 from the marker: the REAL mark still wins.
    r = probe(6.01)
    check("a real mark is never beaten by the grid, even a nearer one",
          near(r["start"], 10.03) and r["on_target"] is True, json.dumps(r))

    r = probe(5.91)     # 9.91 -> 0.12 from the marker: out of reach (8 px)
    check("out of reach nothing pulls: the grid decides, grey",
          near(r["start"], 10.0) and r["on_target"] is False, json.dumps(r))

    # ── the object inside is NO reference: only the range's bounds are ───────────────────────
    # M1 starts at 4.8: at dt = 6.10 its start would sit 0.01 from a mark at 10.91, while the range's
    # start (10.10) is 0.07 from 10.03. The START wins (it is the caret).
    mk2 = mark(lane, 10.91)
    r = probe(6.10)
    check("the range's start within reach lands, whatever an object inside would reach",
          r["edge"] == "start" and near(r["start"], 10.03), json.dumps(r))
    cmd("marker.remove", lane=lane, marker=mk)
    # With the start out of reach, the mark M1's start would reach is ignored: the grid decides.
    r = probe(6.10)
    check("a mark only an object's edge would reach is ignored: the grid takes the start, grey",
          r["edge"] == "start" and r["on_target"] is False and near(r["start"], 10.0)
          and near(r["guide_time"], 10.0), json.dumps(r))
    cmd("marker.remove", lane=lane, marker=mk2)

    # ── the END ──────────────────────────────────────────────────────────────────────────────
    mk3 = mark(lane, 14.03)
    r = probe(7.98)     # end -> 13.98, start -> 11.98: only the end reaches
    check("the range's END lands on a marker the start does not reach",
          r["edge"] == "end" and near(r["end"], 14.03) and r["on_target"] is True
          and near(r["guide_time"], 14.03), json.dumps(r))
    cmd("marker.remove", lane=lane, marker=mk3)

    # ── the snap off ─────────────────────────────────────────────────────────────────────────
    mk = mark(lane, 10.03)
    r = probe(6.02, snap=False)
    check("snap off: the raw travel, grey, the guide on the start",
          near(r["dt"], 6.02) and r["on_target"] is False and r["edge"] == "start"
          and near(r["guide_time"], 10.02), json.dumps(r))
    cmd("marker.remove", lane=lane, marker=mk)

    # ── the grid, last ───────────────────────────────────────────────────────────────────────
    r = probe(5.75)
    check("with nothing there the grid takes the start, grey",
          near(r["start"], 10.0) and r["on_target"] is False, json.dumps(r))

    # ── the wall belongs to the RANGE ────────────────────────────────────────────────────────
    # M1 starts at 4.8, later than the range's start (4.0): the old rule walled at -4.8 and left the
    # range's start at -0.8. The range stops at 0, i.e. a travel of -4, object or no object.
    r = probe(-10)
    check("the RANGE stops at zero", near(r["dt"], -4.0) and r["clamped"] is True
          and near(r["start"], 0.0) and near(r["guide_time"], 0.0), json.dumps(r))
    r = probe(-3.0)
    check("short of the wall nothing is clamped", r["clamped"] is False and near(r["start"], 1.0),
          json.dumps(r))

    # ── ⌥ copies: the originals stay and ARE targets; without ⌥ they are not ─────────────────
    # M1 starts at 4.8. Carrying the range by 0.77 puts its start at 4.77: with ⌥ the original's
    # start catches it; without, the object is carried (or cut) and is no target — the grid decides.
    r = probe(0.77, copy=True)
    check("⌥: the ORIGINAL's edge is a target",
          near(r["start"], 4.8) and r["on_target"] is True and r["edge"] == "start", json.dumps(r))
    r = probe(0.77)
    check("without ⌥ the object the range crosses is no target",
          r["on_target"] is False and near(r["dt"], 1.0), json.dumps(r))

    # ── no magnet on oneself ─────────────────────────────────────────────────────────────────
    # The drag first cuts at the two bounds. The state below IS that state: M2 cut at 4.13 and 6.13,
    # the range on the piece in the middle. The scraps outside end/start exactly at the bounds.
    lane = fresh()
    m2 = cmd("midi.create_clip", start=2.0, end=8.0, lane=0)["id"]
    pieces = cmd("object.split_at", seconds=4.13, ids=[m2])["ids"]
    right = [i for i in pieces if i != m2][0]
    pieces = cmd("object.split_at", seconds=6.13, ids=[right])["ids"]
    cmd("timesel.set", start=4.13, end=6.13, lanes=[0])
    n_before = len(cmd("object.list")["objects"])
    r = probe(0.03)
    check("no ⌥: the scraps cut at the bounds are NOT targets — the range is free to leave",
          not near(r["dt"], 0.0) and near(r["dt"], -0.13) and r["on_target"] is False, json.dumps(r))
    r = probe(0.03, copy=True)
    check("⌥: the same scraps ARE there (the originals stay) and hold the range back",
          near(r["dt"], 0.0) and r["on_target"] is True, json.dumps(r))

    # ── a probe touches nothing ──────────────────────────────────────────────────────────────
    after = cmd("object.list")["objects"]
    check("the probe moves, cuts and creates nothing", len(after) == n_before == 3,
          "%d -> %d" % (n_before, len(after)))
    sel = cmd("timesel.set", start=4.13, end=6.13, lanes=[0])
    probe(1.0)
    check("and the selection is where it was",
          cmd("timesel.set", start=4.13, end=6.13, lanes=[0]) == sel)

    # ── the refusal ──────────────────────────────────────────────────────────────────────────
    cmd("timesel.clear")
    try:
        probe(1.0)
        check("no time selection: refused", False, "answered")
    except ObjekatError as e:
        check("no time selection: refused (invalid_state)", e.code == "invalid_state", str(e))

print()
if fails:
    print("%d FAILED: %s" % (len(fails), fails))
    sys.exit(1)
print("ALL PASS")

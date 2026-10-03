#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The ⇧ click (and ⌘) of the select tool, through `selection.click` — ONE rule, whatever the depth.

`EditViewModel.handleLaneClick` (the code the timeline runs, after `TimelineView.lanePointProbe`)
is the only left-click path: a top-level object, a child of an open group and a sub-group's child
are all entries of `laneEntries`. The same cases are therefore replayed at three depths — top
level, inside an open group, inside a group inside a group:

  * ⇧ AFTER an object was selected, aimed AFTER it: the time selection covers the object WHOLE
    plus the zone up to the point (`baseTimeSelection` = `selectedObjectsFrame()`);
  * ⇧ aimed BEFORE it: the same, growing leftwards;
  * ⇧ on another lane: the rows crossed come with it;
  * a second ⇧ GROWS the range (a union), the objects it encloses are selected;
  * a caret laid by a plain click, then ⇧: the passage between the caret and the point;
  * ⇧ / ⌘ on an object's BODY belong to the object (extend the selection / toggle it): no range;
  * ⌘ on time toggles the lane clicked in or out of the range;
  * a group open ABOVE an object that stays top level: the range spans both, rows crossed included;
  * automation: a band reads ONLY a traced range (never the frame of the selected objects), and ⇧
    does not reach out of the surface it started on.

    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --socket=/tmp/o.sock
    ./scenario_shift_click.py /tmp/o.sock

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
BIP = os.path.join(HERE, "fixtures", "bip.wav")
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
    def cmd(name, **params):
        return c.send(name, params or None)

    def ent(oid):
        return next(o for o in cmd("object.list")["objects"] if o["id"] == oid)

    def sel():
        return cmd("selection.get")

    def ids():
        return set(sel()["ids"])

    def ts():
        t = sel().get("time_selection")
        return None if t is None else (t["start"], t["end"], set(t["lanes"]))

    def body(oid, **kw):
        return cmd("selection.click", id=oid, zone="body", **kw)

    def empty(lane, time, **kw):
        return cmd("selection.click", lane=lane, time=time, **kw)

    info = cmd("app.info")
    check("--no-recent honoured", info.get("records_recent_projects") is False)

    def build(depth):
        """Three 2 s clips A (lane 0), B (lane 1), C (lane 2, later: 6..8) at the given depth.
        The container's window therefore runs 2 .. 8, so every click below lies inside it."""
        cmd("project.new")
        a = cmd("object.add", path=BIP, lane=0, start=2.0, duration=2.0)["id"]
        b = cmd("object.add", path=BIP, lane=1, start=2.0, duration=2.0)["id"]
        cc = cmd("object.add", path=BIP, lane=2, start=6.0, duration=2.0)["id"]
        groups = []
        if depth >= 1:
            if depth == 1:
                g = cmd("group.create", ids=[a, b, cc])["id"]
                groups = [g]
            else:
                inner = cmd("group.create", ids=[a, b])["id"]
                outer = cmd("group.create", ids=[inner, cc])["id"]
                groups = [outer, inner]
            for g in groups:
                cmd("group.expand", id=g, expanded=True)
        cmd("selection.clear")
        cmd("timesel.clear")
        cmd("transport.seek", seconds=0.0)
        return a, b, cc, groups

    for depth in (0, 1, 2):
        tag = ("top level", "open group", "group in a group")[depth]

        def T(s):
            return "[%s] %s" % (tag, s)

        a, b, cc, groups = build(depth)
        ea, eb, ec = ent(a), ent(b), ent(cc)
        la, lb, lc = ea["display_lane"], eb["display_lane"], ec["display_lane"]
        check(T("setup: depth is what was asked"),
              ea["depth"] == depth and eb["depth"] == depth, "%s %s" % (ea["depth"], eb["depth"]))
        check(T("setup: the rows are distinct"), len({la, lb, lc}) == 3, (la, lb, lc))
        a0, a1 = ea["start"], ea["start"] + ea["duration"]
        check(T("setup: A runs 2..4"), near(a0, 2.0) and near(a1, 4.0), (a0, a1))

        # ── ⇧ aimed AFTER the object ────────────────────────────────────────────────────────
        body(a)
        check(T("A selected by a plain click"), ids() == {a} and ts() is None, str(sel()))
        empty(la, 7.0, shift=True)
        t = ts()
        check(T("⇧ after A: the range covers A WHOLE plus the zone up to the point"),
              t is not None and near(t[0], 2.0) and near(t[1], 7.0) and la in t[2], str(t))
        check(T("… A is still selected (enclosed by the range)"), a in ids(), str(ids()))
        check(T("… the cursor is on the range's start"),
              near(cmd("transport.state")["cursor"], 2.0), cmd("transport.state")["cursor"])

        # ── ⇧ aimed BEFORE the object ───────────────────────────────────────────────────────
        body(a)
        empty(la, 0.5, shift=True)
        t = ts()
        check(T("⇧ before A: the range runs from the point to A's END"),
              t is not None and near(t[0], 0.5) and near(t[1], 4.0) and la in t[2], str(t))
        check(T("… A is enclosed, hence selected"), a in ids(), str(ids()))

        # ── ⇧ on another lane ───────────────────────────────────────────────────────────────
        body(a)
        empty(lb, 7.0, shift=True)
        t = ts()
        lo, hi = min(la, lb), max(la, lb)
        check(T("⇧ on another row: both rows and all the rows crossed"),
              t is not None and near(t[0], 2.0) and near(t[1], 7.0) and t[2] == set(range(lo, hi + 1)),
              str(t))
        check(T("… B (2..4, on the new row) is enclosed, hence selected"), {a, b} <= ids(), str(ids()))

        # ── a second ⇧ ──────────────────────────────────────────────────────────────────────
        body(a)
        empty(la, 5.0, shift=True)
        empty(la, 9.0, shift=True)
        t = ts()
        check(T("a second ⇧ GROWS the range"),
              t is not None and near(t[0], 2.0) and near(t[1], 9.0), str(t))
        empty(lb, 1.0, shift=True)
        t = ts()
        check(T("… in every direction (time and rows)"),
              t is not None and near(t[0], 1.0) and near(t[1], 9.0)
              and {la, lb} <= t[2], str(t))

        # ── a caret, then ⇧ ─────────────────────────────────────────────────────────────────
        cmd("selection.clear")
        empty(la, 1.0)
        s = sel()
        check(T("a plain click on an empty row lays the caret"),
              s.get("caret", {}).get("lane") == la and ts() is None and ids() == set(), str(s))
        empty(lb, 5.0, shift=True)
        t = ts()
        check(T("⇧ after the caret: the passage between the caret and the point, rows crossed"),
              t is not None and near(t[0], 1.0) and near(t[1], 5.0)
              and t[2] == set(range(lo, hi + 1)), str(t))
        empty(lb, 3.0, shift=True)
        t = ts()
        check(T("… a second ⇧ re-extends from the same anchor (it SHORTENS here)"),
              t is not None and near(t[0], 1.0) and near(t[1], 3.0), str(t))

        # ── ⇧ / ⌘ on an object's BODY: the object's, no range ───────────────────────────────
        body(a)
        body(b, shift=True)
        check(T("⇧ on B's body extends the OBJECT selection (no range)"),
              ids() >= {a, b} and ts() is None and cc not in ids(), "%s %s" % (ids(), ts()))
        body(a)
        body(b, cmd=True)
        check(T("⌘ on B's body toggles B in"), ids() == {a, b} and ts() is None, str(ids()))
        body(b, cmd=True)
        check(T("⌘ on B's body again toggles it out"), ids() == {a} and ts() is None, str(ids()))

        # ── ⌘ on time: toggles the lane ─────────────────────────────────────────────────────
        body(a)
        empty(lb, 3.0, cmd=True)
        t = ts()
        check(T("⌘ on another row's time adds the row to A's frame"),
              t is not None and near(t[0], 2.0) and near(t[1], 4.0) and t[2] == {la, lb}, str(t))
        check(T("… B, enclosed, is selected"), {a, b} <= ids(), str(ids()))
        empty(lb, 3.0, cmd=True)
        t = ts()
        check(T("⌘ on the same row again takes it out"),
              t is not None and t[2] == {la}, str(t))

        # ── the plain click still clears a range ────────────────────────────────────────────
        empty(lc, 9.0)
        check(T("a plain click on time clears range and selection, lays the caret"),
              ts() is None and ids() == set() and sel().get("caret", {}).get("lane") == lc, str(sel()))

        # ── a selected group's frame, or a selected CHILD's: the absolute start ────────────
        if depth >= 1:
            body(b)
            empty(lb, 9.0, shift=True)
            t = ts()
            check(T("a CHILD selected, then ⇧: its ABSOLUTE frame (not its container-relative one)"),
                  t is not None and near(t[0], 2.0) and near(t[1], 9.0) and lb in t[2], str(t))
            body(groups[0])
            empty(la - 1 if la > 0 else 0, 11.0, shift=True)
            t = ts()
            eg = ent(groups[0])
            check(T("the OUTERMOST group selected, then ⇧: starts at the group's start"),
                  t is not None and near(t[0], min(eg["start"], 11.0)) and near(t[1], 11.0), "%s %s" % (t, eg))

    # ── a group open ABOVE an object that stays top level ───────────────────────────────────
    cmd("project.new")
    a = cmd("object.add", path=BIP, lane=0, start=2.0, duration=2.0)["id"]
    b = cmd("object.add", path=BIP, lane=1, start=2.0, duration=2.0)["id"]
    top = cmd("object.add", path=BIP, lane=2, start=3.0, duration=2.0)["id"]
    g = cmd("group.create", ids=[a, b])["id"]
    cmd("group.expand", id=g, expanded=True)
    cmd("selection.clear")
    ea, eb, et = ent(a), ent(b), ent(top)
    check("above-top: A and B are children, the other object is NOT",
          ea["depth"] == 1 and eb["depth"] == 1 and et["depth"] == 0, (ea["depth"], eb["depth"], et["depth"]))
    check("above-top: the top-level object sits BELOW the open group's rows",
          et["display_lane"] > max(ea["display_lane"], eb["display_lane"]),
          (et["display_lane"], ea["display_lane"], eb["display_lane"]))
    la, lb, lt = ea["display_lane"], eb["display_lane"], et["display_lane"]
    body(a)
    body(top, shift=True)
    check("above-top: ⇧ on the top-level object's BODY extends the object selection over the "
          "rectangle (a child, then the object below)",
          {a, top} <= ids() and ts() is None, "%s %s" % (ids(), ts()))
    body(a)
    empty(lt, 6.0, shift=True)
    t = ts()
    check("above-top: child A, then ⇧ on the lane of the top-level object: every row between",
          t is not None and near(t[0], 2.0) and near(t[1], 6.0)
          and t[2] == set(range(la, lt + 1)), str(t))
    check("… the top-level object (3..5) is enclosed, the child B (2..4) too",
          {a, b, top} <= ids(), str(ids()))
    body(top)
    empty(la, 1.0, shift=True)
    t = ts()
    check("above-top: the top-level object, then ⇧ up on a child's row: the same rows",
          t is not None and near(t[0], 1.0) and near(t[1], 5.0)
          and t[2] == set(range(la, lt + 1)), str(t))

    # ── automation: a band reads only a traced range ────────────────────────────────────────
    cmd("project.new")
    a = cmd("object.add", path=BIP, lane=0, start=2.0, duration=4.0)["id"]
    b = cmd("object.add", path=BIP, lane=1, start=2.0, duration=4.0)["id"]
    cmd("selection.clear")
    body(a, double=True, option=True)
    ea, eb = ent(a), ent(b)
    band = ea["display_lane"] + 1
    check("automation: the band opened (B moved down)", eb["display_lane"] > band - 1 and eb["display_lane"] >= 2,
          (ea["display_lane"], eb["display_lane"]))
    body(a)
    before = ids()
    empty(band, 3.0, shift=True)
    check("automation: ⇧ on a band with only an OBJECT selected does not borrow its frame",
          ts() is None, str(ts()))
    cmd("selection.clear")
    empty(band, 3.0)
    empty(band, 4.5, shift=True)
    t = ts()
    check("automation: caret on the band, then ⇧ on the band: a range on the band alone",
          t is not None and near(t[0], 3.0) and near(t[1], 4.5) and t[2] == {band}, str(t))
    check("automation: … and no object selected by it", ids() == set(), str(ids()))
    empty(eb["display_lane"], 5.0, shift=True)
    t2 = ts()
    # NB: today the range is REPLACED by one on the object row (3..5, {B's row}) rather than kept: the
    # growth branch confines the lanes to the clicked row's kind. Never a MIXED range, which is the rule.
    check("automation: ⇧ onto an object row never makes a MIXED range (band + object rows)",
          t2 is not None and (t2[2] == {band} or band not in t2[2]), str(t2))
    empty(band, 2.5)
    empty(band, 5.5, shift=True)
    t = ts()
    check("automation: a new caret on the band, ⇧ again: a range on the band alone",
          t is not None and near(t[0], 2.5) and near(t[1], 5.5) and t[2] == {band}, str(t))

    cmd("selection.clear")
    cmd("project.new")

print()
if fails:
    print("FAILED (%d): %s" % (len(fails), ", ".join(fails)))
    sys.exit(1)
print("ALL PASS")

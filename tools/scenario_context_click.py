#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""What a RIGHT CLICK on an object decides — asserted through `selection.context_click`.

The menu itself is AppKit and cannot be driven from here. What this proves is the half underneath
it, the part the monitor runs BEFORE it builds anything: `ContextMenuPlan` (also asserted alone by
`tools/test_context_menu_plan.swift`) and the selection a right click on an object's BODY makes
(`EditViewModel.selectForContextClick`, the same plain-click selection as the left click's).

  * the lower half of an object, no range: the click SELECTS it first — range cleared, cursor on
    its start — and the menu is the object's;
  * an object already in the selection: NOTHING changes (the multiple selection stays whole, so
    'Consolidate N linked' and the FX link remain on offer);
  * an object OUTSIDE the selection replaces it;
  * the upper half (time): no selection, no cursor move, the marker on offer, no comment;
  * a point INSIDE the time selection: today's menu, nothing selected, the comment on offer;
  * a time selection lying elsewhere is cleared by a body click outside it, exactly as the left
    click clears it;
  * a click on NO object (an empty lane, `id` omitted, `lane` + `time` given): a time selection
    ANYWHERE — inside it or lying elsewhere, on its lanes or not — gives the range's menu (group,
    aux, MIDI clip, comment), nothing is selected; with no time selection but clips SELECTED (a
    clip or a MIDI clip, not a consolidated instance): 'Group the selection' alone, nothing is
    selected; with neither: no menu at all (the event goes on to the views);
  * a child of an open group (cursor on its ABSOLUTE start), and an infinite bus.

    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --socket=/tmp/o.sock
    ./scenario_context_click.py /tmp/o.sock

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

    info = cmd("app.info")
    check("--no-recent honoured", info.get("records_recent_projects") is False,
          str(info.get("records_recent_projects")))

    def sel():
        return set(cmd("selection.get")["ids"])

    def cursor():
        return cmd("transport.state")["cursor"]

    def click(oid, zone="body", **kw):
        return cmd("selection.context_click", id=oid, zone=zone, **kw)

    def fresh():
        cmd("project.new")
        a = cmd("object.add", path=BIP, lane=0, start=2.0)["id"]
        b = cmd("object.add", path=BIP, lane=1, start=4.0)["id"]
        d = cmd("object.add", path=BIP, lane=2, start=6.0)["id"]
        cmd("selection.clear")
        cmd("timesel.clear")
        cmd("transport.seek", seconds=0.0)
        return a, b, d

    # ── the lower half selects, like a left click ───────────────────────────────────────────
    a, b, d = fresh()
    r = click(a)
    check("body click, nothing selected: the body's menu and a selection",
          r["layout"] == "object_body_menu" and r["selects_object"] is True and r["applied"] is True,
          json.dumps(r))
    check("… the object becomes THE selection", sel() == {a}, str(sel()))
    check("… the cursor goes to its start", near(cursor(), 2.0), str(cursor()))
    check("… no object marker, no comment in the object's own menu",
          r["offers_object_marker"] is False and r["offers_comment"] is False, json.dumps(r))

    # ── an object outside the selection replaces it ─────────────────────────────────────────
    cmd("selection.set", ids=[a, b])
    r = click(d)
    check("body click on an object OUTSIDE the selection replaces it",
          sel() == {d} and r["applied"] is True, "%s %s" % (sel(), json.dumps(r)))
    check("… and the cursor follows to the new object's start", near(cursor(), 6.0), str(cursor()))

    # ── an object already in the selection: nothing changes ─────────────────────────────────
    cmd("selection.set", ids=[a, b])
    cmd("transport.seek", seconds=1.25)
    r = click(b)
    check("body click on an object ALREADY selected: no selection is made",
          r["layout"] == "object_body_menu" and r["selects_object"] is False
          and r["applied"] is False, json.dumps(r))
    check("… the multiple selection is kept whole", sel() == {a, b}, str(sel()))
    check("… and the cursor does not move", near(cursor(), 1.25), str(cursor()))

    # a time selection that coexists with the object selection stays too
    cmd("timesel.set", start=8.0, end=9.0, lanes=[0])
    r = click(a, time=2.1)
    check("… and a time selection lying elsewhere stays too (nothing changes at all)",
          r["applied"] is False and "time_selection" in cmd("selection.get"),
          json.dumps(cmd("selection.get"))[:200])
    cmd("timesel.clear")

    # ── a range lying elsewhere is cleared by a body click outside it ───────────────────────
    a, b, d = fresh()
    cmd("timesel.set", start=8.0, end=9.0, lanes=[0])
    r = click(b)       # object b: lane 1, 4.0 .. 4.4 -> outside the range
    check("body click outside the range selects", r["selects_object"] is True and r["applied"] is True,
          json.dumps(r))
    check("… and the time selection is cleared, as the left click clears it",
          "time_selection" not in cmd("selection.get") and sel() == {b},
          json.dumps(cmd("selection.get"))[:200])

    # ── the upper half: time ────────────────────────────────────────────────────────────────
    a, b, d = fresh()
    cmd("selection.set", ids=[d])
    cmd("transport.seek", seconds=3.3)
    r = click(a, zone="time")
    check("upper half: the time menu — marker offered, no comment",
          r["layout"] == "object_time_menu" and r["offers_object_marker"] is True
          and r["offers_comment"] is False, json.dumps(r))
    check("… nothing selected", r["selects_object"] is False and r["applied"] is False and sel() == {d},
          "%s %s" % (sel(), json.dumps(r)))
    check("… and the cursor stays where it was", near(cursor(), 3.3), str(cursor()))

    # ── a point INSIDE the time selection: today's menu, nothing selected ───────────────────
    a, b, d = fresh()
    cmd("timesel.set", start=1.5, end=2.3, lanes=[0])
    for zone in ("time", "body"):
        r = click(a, zone=zone, time=2.1)
        check("inside the range (%s half): the range's menu" % zone,
              r["layout"] == "range_menu" and r["offers_comment"] is True
              and r["offers_object_marker"] is True, json.dumps(r))
        check("… and nothing is selected (%s half)" % zone,
              r["selects_object"] is False and r["applied"] is False and sel() == set(),
              "%s %s" % (sel(), json.dumps(r)))
    # the same object, a point past the range's end: outside, so the object's own reading
    r = click(a, zone="time", time=2.35)
    check("a point just past the range's end is OUTSIDE it (time half: marker only)",
          r["layout"] == "object_time_menu" and r["offers_comment"] is False, json.dumps(r))
    # another lane than the range's: outside whatever the instant
    r = click(b, zone="time", time=1.9)
    check("the right instant on a lane the range does not cover is outside it",
          r["layout"] == "object_time_menu", json.dumps(r))
    cmd("timesel.clear")

    # ── an EMPTY lane: a range anywhere gives the range's menu, no range gives none ─────────
    def empty(lane, time, **kw):
        return cmd("selection.context_click", lane=lane, time=time, **kw)

    a, b, d = fresh()
    cmd("timesel.set", start=8.0, end=9.0, lanes=[0])
    for label, ln, t in (("inside the range", 0, 8.5),
                         ("on its lane, past its end", 0, 20.0),
                         ("at its instants, on a lane it does not cover", 5, 8.5),
                         ("away from it on every axis", 6, 30.0)):
        r = empty(ln, t)
        check("empty lane, %s: the range's menu" % label,
              r["layout"] == "range_menu" and r["offers_comment"] is True, json.dumps(r))
        check("… no object marker (no object), nothing selected, nothing applied (%s)" % label,
              r["offers_object_marker"] is False and r["selects_object"] is False
              and r["applied"] is False, json.dumps(r))
    check("… and the range is still there, untouched",
          "time_selection" in cmd("selection.get") and sel() == set(),
          json.dumps(cmd("selection.get"))[:200])
    r = empty(5, 20.0, zone="time")
    check("empty lane: `zone` means nothing without an object", r["layout"] == "range_menu",
          json.dumps(r))
    cmd("timesel.clear")

    # the same click with clips selected but no range: 'Group the selection' alone, nothing touched
    cmd("selection.set", ids=[a, b])
    cmd("transport.seek", seconds=1.25)
    r = empty(5, 20.0)
    check("empty lane, no time selection, clips selected: 'Group the selection' alone",
          r["layout"] == "group_selection_menu" and r["offers_comment"] is False
          and r["offers_object_marker"] is False and r["selects_object"] is False
          and r["applied"] is False, json.dumps(r))
    check("… the object selection and the cursor are left alone",
          sel() == {a, b} and near(cursor(), 1.25), "%s %s" % (sel(), cursor()))
    cmd("selection.set", ids=[a])
    check("… one clip selected is enough (the menu says 'Group the clip')",
          empty(0, 0.5)["layout"] == "group_selection_menu" and sel() == {a})
    cmd("selection.clear")
    check("empty lane, nothing selected, no range: no menu",
          empty(0, 0.5)["layout"] == "nothing")

    # only what is groupable counts: a group alone is not a clip, a MIDI clip is
    cmd("project.new")
    h1 = cmd("object.add", path=BIP, lane=0, start=2.0)["id"]
    h2 = cmd("object.add", path=BIP, lane=1, start=4.0)["id"]
    hg = cmd("group.create", ids=[h1, h2])["id"]
    cmd("selection.set", ids=[hg])
    r = empty(5, 20.0)
    check("empty lane, no range, only a GROUP selected: no menu (not a clip)",
          r["layout"] == "nothing" and sel() == {hg}, "%s %s" % (sel(), json.dumps(r)))
    midi = cmd("midi.create_clip", start=10.0, end=12.0, lane=3)["id"]
    cmd("selection.set", ids=[midi])
    r = empty(6, 30.0)
    check("empty lane, no range, a MIDI clip selected: 'Group the selection'",
          r["layout"] == "group_selection_menu" and sel() == {midi}, "%s %s" % (sel(), json.dumps(r)))
    cmd("selection.set", ids=[hg, midi])
    check("empty lane, no range, a group and a MIDI clip selected: still on offer",
          empty(6, 30.0)["layout"] == "group_selection_menu")
    # a time selection wins over the clips: the range's menu, as before
    cmd("timesel.set", start=8.0, end=9.0, lanes=[0])
    check("empty lane, a range AND clips selected: the range's menu, not the group's",
          empty(6, 30.0)["layout"] == "range_menu")
    cmd("timesel.clear")
    a, b, d = fresh()

    # a range with an object selected: the range wins on an empty lane, the selection stays
    cmd("selection.set", ids=[a])
    cmd("timesel.set", start=8.0, end=9.0, lanes=[0])
    r = empty(5, 20.0)
    check("empty lane, a range and an object selected: the range's menu, the selection stays",
          r["layout"] == "range_menu" and sel() == {a}, "%s %s" % (sel(), json.dumps(r)))
    cmd("timesel.clear")

    # an object lying elsewhere on the range does not turn into the range's menu (new spec kept)
    cmd("timesel.set", start=8.0, end=9.0, lanes=[0])
    r = click(b, zone="time", time=4.1)
    check("an OBJECT outside the range keeps its own reading (the range is not asked)",
          r["layout"] == "object_time_menu" and r["offers_comment"] is False, json.dumps(r))
    cmd("timesel.clear")

    # ── a child of an open group: the cursor goes to its ABSOLUTE start ─────────────────────
    cmd("project.new")
    g1 = cmd("object.add", path=BIP, lane=0, start=10.0)["id"]
    g2 = cmd("object.add", path=BIP, lane=1, start=12.0)["id"]
    grp = cmd("group.create", ids=[g1, g2])["id"]
    cmd("group.expand", id=grp, expanded=True)
    cmd("selection.clear")
    cmd("transport.seek", seconds=0.0)
    r = click(g2)
    check("a child's body click selects it",
          r["applied"] is True and sel() == {g2}, "%s %s" % (sel(), json.dumps(r)))
    check("… the cursor goes to its ABSOLUTE start", near(cursor(), 12.0), str(cursor()))
    cmd("group.expand", id=grp, expanded=False)

    # ── an infinite bus: the whole lane is its surface; a body click selects it ─────────────
    cmd("project.new")
    cmd("object.add", path=BIP, lane=0, start=1.0)
    bus = cmd("aux.create", start=0.0, end=3.0, lane=1)["id"]
    cmd("object.set_infinite", id=bus, on=True)
    cmd("selection.clear")
    r = click(bus, time=40.0)
    check("an infinite bus clicked far from its stored span selects like any object",
          r["layout"] == "object_body_menu" and sel() == {bus}, "%s %s" % (sel(), json.dumps(r)))
    x = bus

    # ── bad parameters ──────────────────────────────────────────────────────────────────────
    try:
        click(x, zone="middle")
        check("an unknown zone is refused", False)
    except ObjekatError:
        check("an unknown zone is refused", True)
    for params in ({"lane": 2}, {"time": 1.0}, {}):
        try:
            cmd("selection.context_click", **params)
            check("an empty-lane click needs both `lane` and `time` (%s)" % params, False)
        except ObjekatError:
            check("an empty-lane click needs both `lane` and `time` (%s)" % params, True)
    try:
        cmd("selection.context_click", id="00000000-0000-0000-0000-000000000000")
        check("an unknown object is refused", False)
    except ObjekatError:
        check("an unknown object is refused", True)

print()
if fails:
    print("FAILED (%d): %s" % (len(fails), ", ".join(fails)))
    sys.exit(1)
print("ALL PASS")

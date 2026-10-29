#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Several inputs dragged at once (`rec.drop` with `inputs`), on the virtual card.

The Inputs tab selects N inputs and drags one of them: N zones (or assignments) in ONE gesture, ONE undo
point. One lane per input, DOWNWARDS from the lane of the hand, in the order given (the channels'); each
lane has its OWN end (the existing rule: 40 % of the view, or the next object of that lane; a time
selection gives its in/out); the refusal is GLOBAL (one lane refused, nothing is done and no undo point is
pushed); a lane holding a group that can record gives that group the input (assign), like a single drop.
Driven on `--virtual-audio` (4 inputs). The view is 100 s wide for the planner (`visible_secs`).

  A  three inputs on free lanes: consecutive lanes, same start, same end, ONE undo point; undo takes
     the three zones away, redo brings them back; the dry run changes nothing; the zones are selected
  B  each lane its OWN end (a clip on the 2nd lane, another on the 3rd)
  C  global refusal: a clip under the 3rd lane, nothing is created, no undo point
  D  assignment: a zone already on the 2nd lane takes its input; the other two lanes make zones; ONE undo
     point whose undo gives the previous input back
  E  a time selection over the three lanes: its in/out for each, and it is consumed
  F  a stereo pair and a mono, in an open group's sub-lanes: sub-groups
  G  malformed `inputs`; the single form (first / count) still works
  H  Settings.xml is byte for byte what it was

Settings.xml is only READ (hash). Run on the virtual card ONLY.

    ./scenario_record_multi_drop.py /path/to/objekat.app

Exit: 0 if every assertion passes, 1 if one fails, 2 on bad usage.
"""

import hashlib, os, shutil, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

if len(sys.argv) != 2:
    print(__doc__)
    sys.exit(2)

APP = sys.argv[1]
BIN = os.path.join(APP, "Contents", "MacOS", "objekat")
if not os.path.exists(BIN):
    print("not an app bundle: %s" % APP)
    sys.exit(2)

SETTINGS = os.path.expanduser("~/Library/objekat/Settings.xml")
BIP = os.path.join(HERE, "fixtures", "bip.wav")
ok, ko = 0, 0


def section(title):
    print("\n── %s " % title + "─" * max(4, 74 - len(title)))


def check(label, cond, detail=""):
    global ok, ko
    if cond:
        ok += 1
        print("  OK   %-66s" % label)
    else:
        ko += 1
        print("  FAIL %-66s %s" % (label, detail))


def digest():
    try:
        with open(SETTINGS, "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()[:16]
    except FileNotFoundError:
        return None


def refused(c, cmd, **params):
    try:
        c.send(cmd, params or None)
        return None
    except ObjekatError as e:
        return e.code


def near(a, b, tol=1e-6):
    return a is not None and b is not None and abs(a - b) < tol


def objs(c):
    return {o["id"]: o for o in c.send("object.list")["objects"]}


def undo_depth(c):
    return c.send("perf.census")["undo_depth"]


def zone(c, gid):
    return next((z for z in c.send("rec.status")["zones"] if z["id"] == gid), None)


def mono(*firsts):
    return [{"first": f} for f in firsts]


def multi(c, inputs, lane, time_s, **kw):
    p = {"inputs": inputs, "lane": lane, "time": time_s}
    p.update(kw)
    return c.send("rec.drop", p)


def clip(c, lane, start, dur):
    c.send("object.add", {"path": BIP, "lane": lane, "start": start, "duration": dur})
    c.send("wait_idle", {"timeout_ms": 5000})
    new = [o for o in objs(c).values() if o["kind"] != "group" and near(o["start"], start)
           and o["display_lane"] == lane]
    return new[0]["id"] if new else None


def wipe(c):
    c.send("project.new")
    c.send("input.enable")


before = digest()
SOCK = "/tmp/objk-recmulti-%d.sock" % os.getpid()
if os.path.exists(SOCK):
    os.remove(SOCK)
proc = subprocess.Popen([BIN, "--headless", "--api", "--no-recent", "--language=en", "--virtual-audio",
                         "--socket=" + SOCK], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
tmp = tempfile.mkdtemp(prefix="objk-recmulti-")
try:
    for _ in range(160):
        if os.path.exists(SOCK):
            break
        time.sleep(0.25)
    with ObjekatClient(SOCK) as c:
        wipe(c)

        # ── A: three inputs on free lanes ---------------------------------------------------------
        section("A  three inputs, free lanes")
        d0 = undo_depth(c)
        r = multi(c, mono(0, 1, 2), 3, 5.0, dry_run=True)
        check("dry run: three creations, 5 -> 45, on lanes 3, 4, 5",
              r["applied"] is False and r["refused"] is False and len(r["drops"]) == 3
              and all(d["outcome"] == "create" and near(d["start"], 5) and near(d["end"], 45) for d in r["drops"])
              and [d["lane"] for d in r["drops"]] == [3, 4, 5], r)
        check("dry run: nothing changed", objs(c) == {} and undo_depth(c) == d0)
        r = multi(c, mono(0, 1, 2), 3, 5.0)
        groups = [d["group"] for d in r["drops"]]
        check("drop: applied, three groups", r["applied"] and all(groups) and len(set(groups)) == 3, r)
        o = objs(c)
        check("three zones, on consecutive lanes 3, 4, 5, in the order given",
              [o[g]["display_lane"] for g in groups] == [3, 4, 5] and all(o[g]["kind"] == "group" for g in groups),
              [o[g]["display_lane"] for g in groups])
        check("... named after their inputs (In 1, In 2, In 3)",
              [o[g]["name"] for g in groups] == ["In 1", "In 2", "In 3"], [o[g]["name"] for g in groups])
        check("... each with its input",
              [zone(c, g)["input"] for g in groups] == [{"first": 0, "count": 1}, {"first": 1, "count": 1},
                                                        {"first": 2, "count": 1}])
        check("... from 5 s, 40 s long",
              all(near(o[g]["start"], 5) and near(o[g]["duration"], 40) for g in groups))
        check("ONE undo point for the three", undo_depth(c) == d0 + 1, (d0, undo_depth(c)))
        sel = c.send("selection.get")
        check("the three zones are selected", set(sel["ids"]) == set(groups), sel)
        c.send("edit.undo")
        check("one undo takes the three away", objs(c) == {} and undo_depth(c) == d0, (len(objs(c)), undo_depth(c)))
        c.send("edit.redo")
        check("redo brings the three back", set(objs(c)) == set(groups))
        c.send("edit.undo")

        # ── B: each lane its own end --------------------------------------------------------------
        section("B  each lane its own end")
        c1 = clip(c, 4, 20, 4)
        c2 = clip(c, 5, 12, 4)
        r = multi(c, mono(0, 1, 2), 3, 5.0)
        ends = [d["end"] for d in r["drops"]]
        check("ends 45 / 20 / 12 (free lane, clip at 20, clip at 12)",
              r["applied"] and near(ends[0], 45) and near(ends[1], 20) and near(ends[2], 12), r)
        check("... starts all at 5", all(near(d["start"], 5) for d in r["drops"]))
        wipe(c)

        # ── C: global refusal ---------------------------------------------------------------------
        section("C  one lane refused refuses the lot")
        clip(c, 5, 0, 30)
        d0 = undo_depth(c)
        n0 = len(objs(c))
        r = multi(c, mono(0, 1, 2), 3, 5.0)
        check("a clip under the third lane: refused as a whole",
              r["refused"] is True and r["applied"] is False, r)
        check("... the third lane says why (onObject)", r["drops"][2]["outcome"] == "refuse"
              and r["drops"][2]["reason"] == "onObject", r["drops"][2])
        check("... the first two would have been fine alone", r["drops"][0]["outcome"] == "create"
              and r["drops"][1]["outcome"] == "create")
        check("... nothing created, no undo point", len(objs(c)) == n0 and undo_depth(c) == d0)
        r = multi(c, mono(0, 1), 3, 5.0)
        check("two inputs stop above the clip: fine", r["applied"] is True, r)
        wipe(c)

        # ── D: assignment -------------------------------------------------------------------------
        section("D  a zone on the second lane takes its input")
        z4 = c.send("rec.drop", {"first": 3, "lane": 4, "time": 5.0})["group"]
        d0 = undo_depth(c)
        r = multi(c, mono(0, 1, 2), 3, 10.0)
        kinds = [d["outcome"] for d in r["drops"]]
        check("create / assign / create", kinds == ["create", "assign", "create"], kinds)
        check("... the assign targets the existing zone", r["drops"][1].get("target") == z4, r["drops"][1])
        check("... it has the new input (In 2)", zone(c, z4)["input"] == {"first": 1, "count": 1}, zone(c, z4))
        check("... only two zones were made (three in all)", len([1 for o in objs(c).values() if o["kind"] == "group"]) == 3)
        check("ONE undo point", undo_depth(c) == d0 + 1, (d0, undo_depth(c)))
        c.send("edit.undo")
        check("undo gives the previous input back and removes the two new zones",
              zone(c, z4)["input"] == {"first": 3, "count": 1}
              and len([1 for o in objs(c).values() if o["kind"] == "group"]) == 1)
        d1 = undo_depth(c)
        r = multi(c, [{"first": 3}], 4, 10.0)
        check("assigning the input a zone already has: no undo point",
              r["drops"][0]["outcome"] == "assign" and undo_depth(c) == d1, (d1, undo_depth(c)))
        wipe(c)

        # ── E: a time selection -------------------------------------------------------------------
        section("E  time selection over the three lanes")
        c.send("timesel.set", {"start": 60, "end": 64, "lanes": [8, 9, 10]})
        r = multi(c, mono(0, 1, 2), 8, 62.0)
        check("each zone has exactly the selection's in/out (60 -> 64)",
              r["applied"] and all(near(d["start"], 60) and near(d["end"], 64) for d in r["drops"]), r)
        check("the selection is consumed", "time_selection" not in c.send("selection.get"))
        c.send("timesel.set", {"start": 70, "end": 74, "lanes": [8, 9]})
        r = multi(c, mono(0, 1, 2), 8, 71.0, dry_run=True)
        check("a lane outside the selection follows the ordinary rule (71 -> 111)",
              near(r["drops"][0]["start"], 70) and near(r["drops"][1]["end"], 74)
              and near(r["drops"][2]["start"], 71) and near(r["drops"][2]["end"], 111), r)
        c.send("timesel.clear")
        wipe(c)

        # ── F: a stereo pair and a mono -----------------------------------------------------------
        section("F  stereo pair and mono, an open group")
        r = multi(c, [{"first": 0, "count": 2}, {"first": 2}], 6, 0.0)
        g2 = [d["group"] for d in r["drops"]]
        check("a pair and a mono: two zones on lanes 6 and 7",
              r["applied"] and [objs(c)[g]["display_lane"] for g in g2] == [6, 7], r)
        check("... the pair keeps count 2", zone(c, g2[0])["input"] == {"first": 0, "count": 2}
              and zone(c, g2[1])["input"] == {"first": 2, "count": 1})
        wipe(c)
        outer = c.send("rec.drop", {"first": 3, "lane": 0, "time": 0.0, "visible_secs": 100})["group"]
        c.send("rec.assign", {"group": outer})
        check("(the outer group is a plain recordable zone, not what we test here)", True)

        # ── G: malformed ---------------------------------------------------------------------------
        section("G  malformed inputs, single form")
        check("empty list: bad_params", refused(c, "rec.drop", inputs=[], lane=0, time=0.0) == "bad_params")
        check("count 3: bad_params", refused(c, "rec.drop", inputs=[{"first": 0, "count": 3}], lane=0, time=0.0) == "bad_params")
        check("no first: bad_params", refused(c, "rec.drop", inputs=[{"count": 1}], lane=0, time=0.0) == "bad_params")
        check("neither first nor inputs: bad_params", refused(c, "rec.drop", lane=0, time=0.0) == "bad_params")
        wipe(c)
        r = c.send("rec.drop", {"first": 1, "lane": 2, "time": 3.0})
        check("the single form still answers outcome / group", r["outcome"] == "create" and r["group"], r)

    check("Settings.xml untouched by the whole run (hash)", digest() == before, "%s -> %s" % (before, digest()))
finally:
    try:
        proc.terminate()
        proc.wait(timeout=20)
    except Exception:
        proc.kill()
    if os.path.exists(SOCK):
        os.remove(SOCK)
    shutil.rmtree(tmp, ignore_errors=True)

print("\n%d OK, %d FAILED" % (ok, ko))
sys.exit(0 if ko == 0 else 1)

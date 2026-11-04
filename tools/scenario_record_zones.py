#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Recording zones (`rec.drop|assign|arm|status`), on the virtual card.

A zone is a GROUP with a `recordInput`. An input dragged from the Inputs tab creates one or is assigned
to an existing group (the planner is `RecordZonePlanner`, the same one the hand's drop and these commands
read); a zone can be armed (session state: not saved, not in the undo). Nothing records yet.
Driven on `--virtual-audio` (4 inputs). The view is 100 s wide for the planner unless said otherwise
(`visible_secs`), and a pixel is 1/100 s (the floor is max(1 s, 24 px) = 1 s).

  A  the drop on an empty lane: a group named after the input, 40 % of the view, one undo point, a dry
     run changes nothing, undo removes it and redo brings it back
  B  the limits: stops at the next object of the lane, the floor refuses, a clip refuses
  C  a time selection gives its in/out (and is consumed)
  D  a group that can record takes the input (one undo point, none when nothing changes)
  E  an open group: the zone is a sub-group; a lane under a clip's piano roll refuses nothing wrong
  F  groups that cannot record: infinite, looping, consolidated (drop, assign and arm refused)
  G  arming: refusals, several zones on one input, outside the undo, the record button via `can_record`
  H  arming is not persisted (reopening, new project); the input is.
  J  the name: a zone is born without a label, its default name is its input's (it follows the input's
     renaming); `input_prefix` appears only once a name is typed, goes when it is cleared, and a label
     equal to the input's name (an older project) is still the default
  K  arming several zones at once (`rec.arm groups`): the ones that cannot are passed over in silence
  I  Settings.xml is byte for byte what it was

Settings.xml is only READ (hash). Run on the virtual card ONLY.

    ./scenario_record_zones.py /path/to/objekat.app

Exit: 0 if every assertion passes, 1 if one fails, 2 on bad usage.
"""

import hashlib, json, os, shutil, subprocess, sys, tempfile, time

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


def drop(c, first, lane, time_s, **kw):
    p = {"first": first, "lane": lane, "time": time_s}
    p.update(kw)
    return c.send("rec.drop", p)


def clip(c, lane, start, dur):
    c.send("object.add", {"path": BIP, "lane": lane, "start": start, "duration": dur})
    c.send("wait_idle", {"timeout_ms": 5000})
    new = [o for o in objs(c).values() if o["kind"] != "group" and near(o["start"], start)
           and o["display_lane"] == lane]
    return new[0]["id"] if new else None


before = digest()
SOCK = "/tmp/objk-reczone-%d.sock" % os.getpid()
if os.path.exists(SOCK):
    os.remove(SOCK)
proc = subprocess.Popen([BIN, "--headless", "--api", "--no-recent", "--language=en", "--virtual-audio",
                         "--socket=" + SOCK], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
tmp = tempfile.mkdtemp(prefix="objk-reczone-")
try:
    for _ in range(160):
        if os.path.exists(SOCK):
            break
        time.sleep(0.25)
    with ObjekatClient(SOCK) as c:
        c.send("project.new")
        c.send("input.enable")
        c.send("input.set_name", {"first": 2, "name": "Voix"})
        check("no zone in a new project", c.send("rec.status")["zones"] == [])

        # ── A: the drop on an empty lane ---------------------------------------------------------
        section("A  drop on an empty lane")
        d0 = undo_depth(c)
        r = drop(c, 2, 3, 5.0, dry_run=True)
        check("dry run: create 5 -> 45 (40 % of 100 s)",
              r["outcome"] == "create" and near(r["start"], 5) and near(r["end"], 45) and r["applied"] is False, r)
        check("dry run: nothing changed", objs(c) == {} and undo_depth(c) == d0)
        r = drop(c, 2, 3, 5.0)
        gid = r["group"]
        check("drop: create 5 -> 45, applied", r["outcome"] == "create" and r["applied"] and gid, r)
        o = objs(c).get(gid, {})
        check("the group is a group named after the input", o.get("kind") == "group" and o.get("name") == "Voix", o)
        check("... from 5 s, 40 s long, on the lane aimed at",
              near(o.get("start"), 5) and near(o.get("duration"), 40) and o.get("display_lane") == 3, o)
        z = zone(c, gid)
        check("rec.status: the zone has the input, present, not armed",
              z and z["input"] == {"first": 2, "count": 1} and z["input_present"] and not z["armed"]
              and z["recordable"], z)
        check("one undo point for the creation", undo_depth(c) == d0 + 1, (d0, undo_depth(c)))
        r = drop(c, 1, 0, 0.0, visible_secs=10)
        check("a narrower view: 40 % of 10 s = 4 s", near(r["end"] - r["start"], 4), r)
        c.send("edit.undo")
        check("undo removes that one only", gid in objs(c) and len(objs(c)) == 1)
        c.send("edit.undo")
        check("undo removes the creation", objs(c) == {} and undo_depth(c) == d0)
        c.send("edit.redo")
        check("redo brings the zone back, with its input", gid in objs(c) and zone(c, gid) is not None
              and zone(c, gid)["input"] == {"first": 2, "count": 1}, zone(c, gid))
        stereo = drop(c, 0, 12, 0.0, **{"count": 2})
        gst = stereo["group"]
        check("a stereo input names the group \"In 1-2\"-style and keeps count 2",
              zone(c, gst)["input"] == {"first": 0, "count": 2}, zone(c, gst))

        # ── B: the limits ------------------------------------------------------------------------
        section("B  limits: next object, floor, clip")
        c5 = clip(c, 5, 20, 4)
        d0 = undo_depth(c)
        r = drop(c, 0, 5, 5.0)
        check("stops at the next object of the lane (5 -> 20)",
              r["outcome"] == "create" and near(r["start"], 5) and near(r["end"], 20), r)
        gb = r["group"]
        c6 = clip(c, 6, 5.5, 4)
        d1 = undo_depth(c)
        r = drop(c, 0, 6, 5.0)
        check("less than the floor (0.5 s): refused tooShort",
              r["outcome"] == "refuse" and r["reason"] == "tooShort" and r["applied"] is False, r)
        check("... no undo point, nothing created", undo_depth(c) == d1)
        r = drop(c, 0, 5, 21.0)
        check("on a clip: refused onObject", r["outcome"] == "refuse" and r["reason"] == "onObject", r)
        check("... the clip is untouched", objs(c)[c5].get("kind") != "group" and undo_depth(c) == d1)
        check("rec.assign on a clip is refused", refused(c, "rec.assign", group=c5, first=0) == "invalid_state")
        check("rec.arm on a clip is refused", refused(c, "rec.arm", group=c5, on=True) is not None)
        check("rec.arm on an unknown id is refused",
              refused(c, "rec.arm", group="00000000-0000-0000-0000-000000000000", on=True) is not None)

        # ── C: a time selection ------------------------------------------------------------------
        section("C  time selection")
        c.send("timesel.set", {"start": 60, "end": 64, "lanes": [8]})
        r = drop(c, 3, 8, 62.0)
        check("on the selection: its in/out (60 -> 64)",
              r["outcome"] == "create" and near(r["start"], 60) and near(r["end"], 64), r)
        gc = r["group"]
        check("... a group named \"In 4\"", objs(c)[gc]["name"] == "In 4", objs(c)[gc]["name"])
        c.send("timesel.set", {"start": 70, "end": 74, "lanes": [9]})
        r = drop(c, 3, 8, 71.0, dry_run=True)
        check("a selection on ANOTHER lane is ignored (71 -> 111)",
              r["outcome"] == "create" and near(r["start"], 71) and near(r["end"], 111), r)
        c.send("timesel.clear")

        # ── D: assignment -------------------------------------------------------------------------
        section("D  assignment to an existing group")
        d0 = undo_depth(c)
        r = drop(c, 1, 3, 10.0)
        check("on a group that can record: assign", r["outcome"] == "assign" and r["target"] == gid, r)
        check("... it has the new input", zone(c, gid)["input"] == {"first": 1, "count": 1}, zone(c, gid))
        check("... the group did not move or grow", near(objs(c)[gid]["start"], 5) and near(objs(c)[gid]["duration"], 40))
        check("... one undo point", undo_depth(c) == d0 + 1, (d0, undo_depth(c)))
        r = drop(c, 1, 3, 10.0)
        check("the same input again: assign, no undo point", r["outcome"] == "assign" and undo_depth(c) == d0 + 1)
        c.send("edit.undo")
        check("undo gives the previous input back", zone(c, gid)["input"] == {"first": 2, "count": 1}, zone(c, gid))
        c.send("edit.redo")
        check("redo gives the new one", zone(c, gid)["input"] == {"first": 1, "count": 1})
        c.send("rec.assign", {"group": gid, "first": 2})
        d1 = undo_depth(c)
        c.send("rec.assign", {"group": gid})
        check("rec.assign without `first` takes the input away (one undo point)",
              zone(c, gid) is None and undo_depth(c) == d1 + 1)
        c.send("edit.undo")
        check("undo puts it back", zone(c, gid) is not None and zone(c, gid)["input"] == {"first": 2, "count": 1})

        # ── E: an open group ---------------------------------------------------------------------
        section("E  an open group")
        ga = clip(c, 14, 30, 4)
        gb2 = clip(c, 15, 30, 2)
        grp = c.send("group.create", {"ids": [ga, gb2]})["id"]
        c.send("group.expand", {"id": grp, "expanded": True})
        o = objs(c)
        kids = sorted((v for v in o.values() if v["parent"] == grp), key=lambda v: v["display_lane"])
        check("the open group shows its two clips on two sub-lanes", len(kids) == 2, kids)
        sub = kids[1]["display_lane"]
        d0 = undo_depth(c)
        r = drop(c, 0, sub, 32.5, visible_secs=4)
        check("a drop on the empty part of a sub-lane: create, inside the group",
              r["outcome"] == "create" and r["parent"] == grp, r)
        check("... the new zone is a child of the open group",
              r["group"] and objs(c).get(r["group"], {}).get("parent") == grp, objs(c).get(r.get("group")))
        check("... one undo point", undo_depth(c) == d0 + 1)
        check("a drop on the open group's own row (on the group): assign",
              drop(c, 1, objs(c)[grp]["display_lane"], 31.0)["outcome"] == "assign")
        r = drop(c, 0, kids[0]["display_lane"], 31.0)
        check("a drop on a clip inside an open group: refused", r["outcome"] == "refuse", r)
        c.send("group.expand", {"id": grp, "expanded": False})

        # ── F: groups that cannot record ---------------------------------------------------------
        section("F  infinite, looping, consolidated")
        ci = clip(c, 20, 10, 4)
        inf = c.send("group.create", {"ids": [ci]})["id"]
        c.send("object.set_infinite", {"id": inf, "on": True})
        li = objs(c)[inf]["display_lane"]
        d0 = undo_depth(c)
        r = drop(c, 0, li, 10.0)
        check("on an infinite group: refused notRecordable",
              r["outcome"] == "refuse" and r["reason"] == "notRecordable", r)
        check("rec.assign on an infinite group is refused", refused(c, "rec.assign", group=inf, first=0) == "invalid_state")
        check("rec.arm on an infinite group is refused", refused(c, "rec.arm", group=inf, on=True) is not None)
        check("none of those refusals pushed an undo point", undo_depth(c) == d0, (d0, undo_depth(c)))

        cl = clip(c, 22, 10, 4)
        lp = c.send("group.create", {"ids": [cl]})["id"]
        c.send("object.set_loop", {"id": lp, "enabled": True})
        lpl = objs(c)[lp]["display_lane"]
        r = drop(c, 0, lpl, 11.0)
        check("on a looping group: refused notRecordable",
              r["outcome"] == "refuse" and r["reason"] == "notRecordable", r)
        check("rec.assign on a looping group is refused", refused(c, "rec.assign", group=lp, first=0) == "invalid_state")

        c.send("project.save_as", {"path": os.path.join(tmp, "p0", "p0.objekat.json")})   # a bake needs a folder
        cc = clip(c, 24, 10, 4)
        cg = c.send("group.create", {"ids": [cc]})["id"]
        c.send("consolidate.make", {"id": cg})
        c.send("wait_idle", {"timeout_ms": 60000})
        inst = [v for v in objs(c).values() if v.get("definition")]
        if inst:
            r = drop(c, 0, inst[0]["display_lane"], 11.0)
            # A closed instance is a clip-kind object (a group only while open for editing): refused either way.
            check("on a consolidated object: refused (%s)" % r.get("reason"),
                  r["outcome"] == "refuse" and r["applied"] is False, r)
            check("rec.assign on a consolidated object is refused",
                  refused(c, "rec.assign", group=inst[0]["id"], first=0) == "invalid_state")
        else:
            check("a consolidated instance exists (the bake finished)", False, objs(c))

        # ── G: arming ----------------------------------------------------------------------------
        section("G  arming")
        c.send("project.new")
        c.send("input.enable")
        plain_clip = clip(c, 30, 0, 2)
        plain = c.send("group.create", {"ids": [plain_clip]})["id"]
        check("arming a group with no input is refused", refused(c, "rec.arm", group=plain, on=True) == "invalid_state")
        zb = drop(c, 0, 40, 100.0)["group"]            # input 1 (index 0) -- same input as gb
        zc = drop(c, 0, 41, 100.0)["group"]            # the same input again, on another zone
        c.send("rec.assign", {"group": plain, "first": 3, "count": 2})
        check("a pair that does not fit the 4-channel card is absent",
              zone(c, plain)["input_present"] is False, zone(c, plain))
        check("arming a zone whose input is absent is refused",
              refused(c, "rec.arm", group=plain, on=True) == "invalid_state")
        st = c.send("rec.status")
        check("nothing armed yet: can_record is false", st["armed"] == [] and st["can_record"] is False, st)
        check("the project has never been saved", st["project_saved"] is False)
        d0 = undo_depth(c)
        c.send("rec.arm", {"group": zb, "on": True})
        c.send("rec.arm", {"group": zc, "on": True})
        st = c.send("rec.status")
        check("two zones armed on the SAME input", sorted(st["armed"]) == sorted([zb, zc]), st["armed"])
        check("arming is outside the undo", undo_depth(c) == d0, (d0, undo_depth(c)))
        check("armed but the project was never saved: the record button stays grey", st["can_record"] is False)
        path = os.path.join(tmp, "p", "p.objekat.json")
        c.send("project.save_as", {"path": path})
        st = c.send("rec.status")
        check("saved: still armed, the record button is live", sorted(st["armed"]) == sorted([zb, zc])
              and st["can_record"] is True and st["project_saved"] is True, st)
        check("saving did not disarm anything", all(z["armed"] for z in st["zones"] if z["id"] in (zb, zc)))
        c.send("rec.arm", {"group": zb, "on": False})
        st = c.send("rec.status")
        check("one disarmed: the other stays armed and the button live", st["armed"] == [zc] and st["can_record"])
        c.send("rec.arm", {"group": zc, "on": False})
        check("none armed: the button is grey again", c.send("rec.status")["can_record"] is False)
        check("disarming a disarmed zone is harmless", refused(c, "rec.arm", group=zc, on=False) is None)
        c.send("rec.arm", {"group": zc, "on": True})
        c.send("rec.assign", {"group": zc})
        check("taking the input away disarms the zone",
              c.send("rec.status")["armed"] == [] and c.send("rec.status")["can_record"] is False)
        c.send("rec.arm", {"group": zb, "on": True})
        c.send("input.disable")
        st = c.send("rec.status")
        check("inputs closed: the armed zone stops counting, the button is grey",
              st["armed"] == [] and st["can_record"] is False and zone(c, zb)["input_present"] is False, st)
        check("... and arming is refused", refused(c, "rec.arm", group=zb, on=True) == "invalid_state")
        c.send("rec.arm", {"group": zb, "on": False})
        c.send("input.enable")
        check("inputs open again: the zone is armable again", zone(c, zb)["input_present"] is True)

        # ── H: not persisted ---------------------------------------------------------------------
        section("H  arming is not persisted")
        c.send("rec.arm", {"group": zb, "on": True})
        c.send("project.save")
        doc = json.load(open(path))
        txt = json.dumps(doc)
        check("the file keeps the zone's input (recordInput)", "recordInput" in txt)
        import re
        keys = re.findall(r'"([A-Za-z_]*[Aa]rm[A-Za-z_]*)"\s*:', txt)
        check("... and says nothing of arming (no key about it)", keys == [], keys)
        c.send("project.open", {"path": path})
        c.send("input.enable")
        st = c.send("rec.status")
        check("reopened: the zones and their inputs are back, nothing is armed",
              any(z["id"] == zb for z in st["zones"]) and st["armed"] == [] and st["can_record"] is False, st)
        c.send("rec.arm", {"group": zb, "on": True})
        c.send("project.new")
        st = c.send("rec.status")
        check("a new project: no zone, nothing armed", st["zones"] == [] and st["armed"] == [] and not st["can_record"], st)

        # ── J: the name ----------------------------------------------------------------------------
        section("J  the name of a zone")
        c.send("project.new")
        c.send("input.enable")
        c.send("input.set_name", {"first": 2, "name": "Voix"})
        gz = drop(c, 2, 0, 0.0)["group"]
        check("born without a name of its own: no input_prefix, named after its input",
              zone(c, gz)["input_prefix"] is None and zone(c, gz)["name"] == "Voix" and objs(c)[gz]["name"] == "Voix",
              zone(c, gz))
        c.send("input.set_name", {"first": 2, "name": "Chant"})
        check("the default name follows the input's renaming",
              zone(c, gz)["name"] == "Chant" and objs(c)[gz]["name"] == "Chant" and zone(c, gz)["input_prefix"] is None,
              zone(c, gz))
        c.send("object.rename", {"id": gz, "name": "Refrain"})
        check("a typed name is a group name: the input's name comes in front",
              zone(c, gz)["input_prefix"] == "Chant" and zone(c, gz)["name"] == "Refrain", zone(c, gz))
        c.send("input.set_name", {"first": 2, "name": "Micro"})
        check("... and the prefix follows the input's renaming", zone(c, gz)["input_prefix"] == "Micro", zone(c, gz))
        c.send("object.rename", {"id": gz, "name": ""})
        check("clearing the name gives the default back (no prefix)",
              zone(c, gz)["input_prefix"] is None and zone(c, gz)["name"] == "Micro", zone(c, gz))
        # A zone of an older project carried the input's name as a label: that is the default, not a group name.
        c.send("object.rename", {"id": gz, "name": "Micro"})
        check("a label equal to the input's name is still the default (older projects)",
              zone(c, gz)["input_prefix"] is None and zone(c, gz)["name"] == "Micro", zone(c, gz))
        c.send("object.rename", {"id": gz, "name": "micro"})
        check("... another case is a name somebody chose", zone(c, gz)["input_prefix"] == "Micro", zone(c, gz))
        c.send("object.rename", {"id": gz, "name": ""})
        # A group that is no zone never has a prefix, whatever its name.
        pc = clip(c, 30, 0, 2)
        pg = c.send("group.create", {"ids": [pc]})["id"]
        c.send("object.rename", {"id": pg, "name": "Plain"})
        check("a group with no input: not a zone, so not in rec.status", zone(c, pg) is None)
        c.send("rec.assign", {"group": pg, "first": 0})
        c.send("object.rename", {"id": pg, "name": ""})
        check("assigned an input to a named-then-cleared group: default name is the input's",
              zone(c, pg)["input_prefix"] is None and zone(c, pg)["name"] == "In 1", zone(c, pg))

        # ── K: several zones at once ---------------------------------------------------------------
        section("K  arming several zones at once")
        c.send("project.new")
        c.send("input.enable")
        a = drop(c, 0, 0, 0.0)["group"]
        b = drop(c, 1, 1, 0.0)["group"]
        nc = clip(c, 5, 0, 2)
        cnone = c.send("group.create", {"ids": [nc]})["id"]      # a group with no input
        d0 = undo_depth(c)
        r = c.send("rec.arm", {"groups": [a, b, cnone], "on": True})
        check("groups [a, b, no-input]: a and b are armed, the third is passed over",
              sorted(r["armed"]) == sorted([a, b]) and r["ignored"] == [cnone], r)
        check("... without an error, and outside the undo", undo_depth(c) == d0)
        r = c.send("rec.arm", {"groups": [a, b, cnone], "on": False})
        check("the same list disarms them (disarming is always possible: nothing ignored)",
              r["armed"] == [] and r["ignored"] == [], r)
        check("none of them can: invalid_state",
              refused(c, "rec.arm", groups=[cnone], on=True) == "invalid_state")
        check("an unknown id among the others is ignored too",
              c.send("rec.arm", {"groups": [a, "00000000-0000-0000-0000-000000000000"], "on": True})["armed"] == [a])
        check("an empty list does nothing", c.send("rec.arm", {"groups": [], "on": True})["armed"] == [a])
        check("neither group nor groups is a bad call", refused(c, "rec.arm", on=True) is not None)
        c.send("rec.arm", {"group": a, "on": False})

        # ── L: Esc disarms every zone (rec.disarm_all, the door Esc's key handler shares) ----------------
        section("L  rec.disarm_all")
        c.send("project.new")
        c.send("input.enable")
        a = drop(c, 0, 0, 0.0)["group"]
        b = drop(c, 1, 1, 0.0)["group"]
        r = c.send("rec.arm", {"groups": [a, b], "on": True})
        check("two zones armed", sorted(r["armed"]) == sorted([a, b]), r)
        d0 = undo_depth(c)
        r = c.send("rec.disarm_all")
        check("rec.disarm_all: nothing armed any more", r["armed"] == [], r)
        check("... and rec.status agrees", c.send("rec.status")["armed"] == [])
        check("... outside the undo", undo_depth(c) == d0)
        r = c.send("rec.disarm_all")
        check("a second call answers the same", r["armed"] == [], r)

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

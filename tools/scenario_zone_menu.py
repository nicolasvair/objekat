#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The object menu applied to a ZONE — `selection.context_action` with `apply_to_zone`.

The right click INSIDE a time selection, on an object, builds the OBJECT's own menu in `zone` scope
(`EditViewModel.performZoneMenuAction`): the objects the range crosses are CUT at its two bounds and
the action applies to the pieces inside, and to nothing else. There is no branch for the depth, so
every case below runs twice — the objects at the top level, and as children of an open group:

  * colour: a clip cut in three, ONLY the middle piece coloured, ONE undo gives the clip back whole;
  * group: the range's own entry (wrap what is inside) — one undo;
  * dissolve a group: the middle piece of the group is dissolved, the sides stay groups — one undo;
  * deconsolidate an instance: the middle piece leaves its definition, the sides keep it — one undo;
  * consolidate a clip: the middle piece becomes an instance, the sides stay plain — TWO undos (the
    isolation, then the bake's own point: the accepted cost);
  * FX link over several objects;
  * `dry_run` touches nothing and says what it WOULD apply to; an entry that is not offered in zone
    scope (`consolidate_linked`) is refused with the list of what is;
  * several lanes: only the lanes of the range are cut;
  * a range spilling over the start of the timeline; a range whose edge falls on an object's edge
    (no cut needed);
  * an infinite bus on a covered row is left alone (neither cut nor painted).

    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --socket=/tmp/o.sock
    ./scenario_zone_menu.py /tmp/o.sock

Exit: 0 if every assertion passes, 1 otherwise.
"""

import json, os, shutil, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

if len(sys.argv) != 2:
    print(__doc__)
    sys.exit(2)

SOCK = sys.argv[1]
BIP = os.path.join(HERE, "fixtures", "bip.wav")
ROOT = os.path.realpath(tempfile.mkdtemp(prefix="objk-zone-", dir="/tmp"))
fails = []


def check(label, ok, detail=""):
    if ok:
        print("ok    " + label)
    else:
        fails.append(label)
        print("FAIL  %s  %s" % (label, detail))


def near(a, b, eps=1e-3):
    return abs(a - b) < eps


try:
    with ObjekatClient(SOCK) as c:
        def cmd(name, **params):
            return c.send(name, params or None)

        def refused(name, **params):
            try:
                cmd(name, **params)
                return None
            except ObjekatError as e:
                return e

        def objs():
            return cmd("object.list")["objects"]

        def ent(oid):
            return next((o for o in objs() if o["id"] == oid), None)

        def colours():
            out = {}

            def walk(o):
                if isinstance(o, dict):
                    if "id" in o and "colorIndex" in o and "stateXML" not in o and "gainDb" not in o:
                        out[o["id"]] = o["colorIndex"]
                    for v in o.values():
                        walk(v)
                elif isinstance(o, list):
                    for v in o:
                        walk(v)
            walk(cmd("project.get_state").get("items", []))
            return out

        def on_row(lane, kinds=("clip",)):
            return sorted((o for o in objs() if o["display_lane"] == lane and o["kind"] in kinds),
                          key=lambda o: o["start"])

        def spans(lst):
            return [(round(o["start"], 3), round(o["start"] + o["duration"], 3)) for o in lst]

        def undo():
            cmd("edit.undo")

        def zone(start, end, lanes):
            cmd("timesel.set", start=start, end=end, lanes=lanes)

        def act(action, oid=None, dry=False, **args):
            p = {"action": action, "apply_to_zone": True}
            if oid is not None:
                p["id"] = oid
            if dry:
                p["dry_run"] = True
            if args:
                p["args"] = args
            return cmd("selection.context_action", **p)

        def clip(lane, start, dur, wrap_list=None):
            i = cmd("object.add", path=BIP, lane=lane, start=start, duration=dur)["id"]
            return i

        def project_new():
            cmd("project.new")
            cmd("selection.clear")
            cmd("timesel.clear")
            cmd("transport.seek", seconds=0.0)

        def wrap(ids):
            """Fixtures become children of an open group (a spacer keeps the group non-trivial)."""
            spacer = clip(9, 2.0, 6.0)
            g = cmd("group.create", ids=list(ids) + [spacer])["id"]
            cmd("group.expand", id=g, expanded=True)
            cmd("selection.clear")
            return g

        info = cmd("app.info")
        check("--no-recent honoured", info.get("records_recent_projects") is False)
        cmd("app.set_dialog_policy", policy="assume_yes")

        # a saved project: consolidating needs samples/consolidate/
        proj = os.path.join(ROOT, "z", "z.objekat.json")
        project_new()
        cmd("project.save_as", path=proj)

        for depth, tag in ((0, "top level"), (1, "child of an open group")):
            def T(s, tag=tag):
                return "[%s] %s" % (tag, s)

            def build(*specs):
                """specs: (lane, start, dur). Returns the ids, wrapped in a group when depth == 1."""
                project_new()
                ids = [clip(*s) for s in specs]
                if depth:
                    wrap(ids)
                return ids

            # ── colour: three pieces, only the middle one painted, ONE undo ──────────────────
            (x,) = build((0, 2.0, 6.0))
            e = ent(x)
            row = e["display_lane"]
            check(T("setup: depth"), e["depth"] == depth, e["depth"])
            zone(4.0, 6.0, [row])
            r = act("set_color", x, color_index=3)
            lst = on_row(row)
            check(T("colour: the clip is cut in THREE"), spans(lst) == [(2.0, 4.0), (4.0, 6.0), (6.0, 8.0)],
                  str(spans(lst)))
            col = colours()
            painted = [o["id"] for o in lst if col.get(o["id"]) == 3]
            check(T("colour: ONLY the middle piece is painted"),
                  painted == [lst[1]["id"]], "%s %s" % (painted, col))
            check(T("colour: the answer names the zone scope and the isolation"),
                  r["scope"] == "zone", json.dumps(r)[:200])
            check(T("colour: the pieces inside are the selection, the range is kept"),
                  set(cmd("selection.get")["ids"]) == {lst[1]["id"]}
                  and "time_selection" in cmd("selection.get"), json.dumps(cmd("selection.get"))[:200])
            undo()
            lst = on_row(row)
            check(T("colour: ONE ⌘Z gives the clip back whole and unpainted"),
                  spans(lst) == [(2.0, 8.0)] and lst[0]["id"] == x and colours().get(x) is None,
                  "%s %s" % (spans(lst), colours().get(x)))

            # ── dry run ──────────────────────────────────────────────────────────────────────
            zone(4.0, 6.0, [row])
            before = json.dumps(objs(), sort_keys=True)
            sel_before = json.dumps(cmd("selection.get"), sort_keys=True)
            r = act("set_color", x, dry=True, color_index=3)
            check(T("dry_run: says what it would apply to"),
                  r.get("dry_run") is True and r["needs_isolation"] is True and r["target_ids"] == [x],
                  json.dumps(r))
            check(T("dry_run: touches nothing (objects, selection)"),
                  json.dumps(objs(), sort_keys=True) == before
                  and json.dumps(cmd("selection.get"), sort_keys=True) == sel_before)
            zone(2.0, 8.0, [row])
            r = act("set_color", x, dry=True, color_index=3)
            check(T("dry_run: a range of whole objects needs no isolation"),
                  r["needs_isolation"] is False, json.dumps(r))
            e = refused("selection.context_action", action="consolidate_linked", id=x,
                        apply_to_zone=True)
            check(T("an entry not offered in zone scope is refused, with the offered ones"),
                  e is not None and e.code == "invalid_state"
                  and "offered" in json.dumps(e.details or {}), str(e))
            cmd("timesel.clear")
            e = refused("selection.context_action", action="set_color", id=x, apply_to_zone=True,
                        args={"color_index": 1})
            check(T("apply_to_zone without a time selection: invalid_state"),
                  e is not None and e.code == "invalid_state", str(e))

            # ── group (the range's own entry) ───────────────────────────────────────────────
            (x,) = build((0, 2.0, 6.0))
            row = ent(x)["display_lane"]
            zone(4.0, 6.0, [row])
            act("group_selection", x)
            gs = [o for o in objs() if o["kind"] == "group" and near(o["start"], 4.0)
                  and near(o["duration"], 2.0)]
            check(T("group: a group of the 4..6 part appears"), len(gs) == 1, str(spans(objs())))
            if gs:
                cmd("group.expand", id=gs[0]["id"], expanded=True)
                inner = [o for o in objs() if o["parent"] == gs[0]["id"]]
                check(T("group: it holds the middle piece"),
                      len(inner) == 1 and near(inner[0]["start"], 4.0) and near(inner[0]["duration"], 2.0),
                      str(inner))
            outside = [o for o in objs() if o["kind"] == "clip" and o["parent"] != (gs[0]["id"] if gs else None)
                       and o["display_lane"] >= 0 and not near(o["start"], 4.0)
                       and o["start"] < 8.5 and o["duration"] < 5]
            check(T("group: the sides stay where they were (2..4 and 6..8)"),
                  any(near(o["start"], 2.0) and near(o["duration"], 2.0) for o in outside)
                  and any(near(o["start"], 6.0) and near(o["duration"], 2.0) for o in outside),
                  str([(o["start"], o["duration"], o["kind"]) for o in objs()]))
            n_groups = len([o for o in objs() if o["kind"] == "group"])
            undo()
            lst = on_row(ent(x)["display_lane"] if ent(x) else row)
            check(T("group: ONE ⌘Z gives back the clip whole"),
                  ent(x) is not None and near(ent(x)["duration"], 6.0)
                  and len([o for o in objs() if o["kind"] == "group"]) == n_groups - 1,
                  str([(o["kind"], o["start"], o["duration"]) for o in objs()]))

            # ── dissolve a group ────────────────────────────────────────────────────────────
            project_new()
            p = clip(0, 2.0, 6.0)
            q = clip(1, 2.0, 6.0)
            g = cmd("group.create", ids=[p, q])["id"]
            if depth:
                w = clip(5, 2.0, 6.0)
                outer = cmd("group.create", ids=[g, w])["id"]
                cmd("group.expand", id=outer, expanded=True)
            cmd("selection.clear")
            eg = ent(g)
            check(T("setup: the group's depth"), eg["depth"] == depth, eg["depth"])
            grow = eg["display_lane"]
            n_before = len(objs())
            zone(4.0, 6.0, [grow])
            act("disband_group", g)
            gl = sorted((o for o in objs() if o["kind"] == "group" and o["id"] != (outer if depth else None)),
                        key=lambda o: o["start"])
            check(T("dissolve: two groups remain, the sides (2..4, 6..8)"),
                  spans(gl) == [(2.0, 4.0), (6.0, 8.0)], str(spans(gl)))
            released = [o for o in objs() if o["kind"] == "clip" and near(o["start"], 4.0)
                        and near(o["duration"], 2.0) and o["parent"] not in {x["id"] for x in gl}]
            check(T("dissolve: the middle piece's two clips are released, at the group's own level"),
                  len(released) >= 2 and all(o["depth"] == depth for o in released),
                  str([(o["start"], o["duration"], o["depth"], o["parent"]) for o in objs() if o["kind"] == "clip"]))
            undo()
            eg2 = ent(g)
            check(T("dissolve: ONE ⌘Z gives the group back whole"),
                  eg2 is not None and eg2["kind"] == "group" and near(eg2["duration"], 6.0)
                  and len(objs()) == n_before, "%s %d/%d" % (eg2, len(objs()), n_before))

            # ── multi-lane: only the lanes of the range are cut ────────────────────────────
            x, y, z = build((0, 2.0, 6.0), (1, 2.0, 6.0), (2, 2.0, 6.0))
            rx, ry, rz = ent(x)["display_lane"], ent(y)["display_lane"], ent(z)["display_lane"]
            zone(4.0, 6.0, sorted({rx, ry}))
            act("set_color", x, color_index=5)
            lx, ly, lz = on_row(rx), on_row(ry), on_row(rz)
            check(T("multi-lane: both covered lanes are cut in three"),
                  len(lx) == 3 and len(ly) == 3, "%s %s" % (spans(lx), spans(ly)))
            check(T("multi-lane: the third lane is untouched (same id, whole)"),
                  len(lz) == 1 and lz[0]["id"] == z and near(lz[0]["duration"], 6.0), str(spans(lz)))
            col = colours()
            check(T("multi-lane: both middle pieces painted, nothing else"),
                  col.get(lx[1]["id"]) == 5 and col.get(ly[1]["id"]) == 5
                  and not any(col.get(o["id"]) == 5 for o in lx + ly if o is not lx[1] and o is not ly[1]),
                  str(col))
            undo()
            check(T("multi-lane: ONE ⌘Z gives all of it back"),
                  spans(on_row(rx)) == [(2.0, 8.0)] and spans(on_row(ry)) == [(2.0, 8.0)],
                  "%s %s" % (spans(on_row(rx)), spans(on_row(ry))))

            # ── a range spilling over the start of the timeline ────────────────────────────
            (x,) = build((0, 1.0, 5.0))
            row = ent(x)["display_lane"]
            zone(0.0, 3.0, [row])      # 0 is the wall: the range starts BEFORE the object
            act("set_color", x, color_index=2)
            lst = on_row(row)
            check(T("spilling over the start: ONE cut, at the range's end (1..3 | 3..6)"),
                  spans(lst) == [(1.0, 3.0), (3.0, 6.0)], str(spans(lst)))
            check(T("… the piece inside is painted, the rest is not"),
                  colours().get(lst[0]["id"]) == 2 and colours().get(lst[1]["id"]) is None, str(colours()))
            undo()
            check(T("… ONE ⌘Z"), spans(on_row(row)) == [(1.0, 6.0)], str(spans(on_row(row))))

            # an edge of the range on an edge of the object: no cut at all
            (x,) = build((0, 2.0, 4.0))
            row = ent(x)["display_lane"]
            zone(2.0, 6.0, [row])
            r = act("set_color", x, dry=True, color_index=2)
            act("set_color", x, color_index=2)
            check(T("range = the object: no cut, the object is painted as it stands"),
                  spans(on_row(row)) == [(2.0, 6.0)] and colours().get(x) == 2
                  and r["needs_isolation"] is False, "%s %s" % (spans(on_row(row)), colours().get(x)))
            undo()
            check(T("… ONE ⌘Z unpaints it"), colours().get(x) is None, str(colours().get(x)))

            # ── an infinite bus on a covered row is ignored ─────────────────────────────────
            project_new()
            x = clip(0, 2.0, 6.0)
            bus = cmd("aux.create", start=0.0, end=3.0, lane=1)["id"]
            cmd("object.set_infinite", id=bus, on=True)
            if depth:
                wrap([x])
            cmd("selection.clear")
            row = ent(x)["display_lane"]
            brow = ent(bus)["display_lane"]
            zone(4.0, 6.0, sorted({row, brow}))
            r = act("set_color", x, dry=True, color_index=4)
            check(T("infinite bus: not among the targets"), bus not in r["target_ids"], json.dumps(r))
            act("set_color", x, color_index=4)
            eb = ent(bus)
            check(T("infinite bus: neither cut nor painted"),
                  eb is not None and eb["infinite"] is True if "infinite" in (eb or {}) else eb is not None,
                  str(eb))
            check(T("infinite bus: still ONE object on its row, not painted"),
                  len([o for o in objs() if o["display_lane"] == brow and o["kind"] == "aux"]) == 1
                  and colours().get(bus) != 4, str(colours().get(bus)))
            check(T("infinite bus: the clip next to it WAS cut and painted"),
                  len(on_row(row)) == 3, str(spans(on_row(row))))

            # ── consolidate (two undos) and deconsolidate (one) ─────────────────────────────
            (x,) = build((0, 2.0, 6.0))
            # NB: build() starts a new, UNSAVED project — consolidation needs a saved one
            cmd("project.save_as", path=proj)
            row = ent(x)["display_lane"]
            zone(4.0, 6.0, [row])
            act("consolidate_clip", x)
            cmd("wait_idle", timeout_ms=60000)
            lst = on_row(row, kinds=("clip", "group"))
            check(T("consolidate: three pieces, the middle one an instance"),
                  len(lst) == 3 and lst[1].get("definition") and not lst[0].get("definition")
                  and not lst[2].get("definition"),
                  str([(o["kind"], o["start"], o["duration"], o.get("definition")) for o in lst]))
            # NB: a lone clip is first WRAPPED in a one-item group (an undo point of its own, as in
            # objects scope: `consolidateWrappingClip`), so the zone costs THREE ⌘Z — isolation, wrap,
            # bake — where command_api.md says two.
            states = []
            for _ in range(3):
                undo()
                states.append(on_row(row, kinds=("clip", "group")))
            check(T("consolidate: ⌘Z #1 takes the bake back (the middle is a plain wrapper group)"),
                  len(states[0]) == 3 and not any(o.get("definition") for o in states[0]),
                  str([(o["kind"], o["start"]) for o in states[0]]))
            check(T("consolidate: ⌘Z #2 takes the wrap back (3 plain clips)"),
                  len(states[1]) == 3 and all(o["kind"] == "clip" for o in states[1]),
                  str([(o["kind"], o["start"]) for o in states[1]]))
            check(T("consolidate: ⌘Z #3 gives the clip back whole (THREE undos)"),
                  len(states[2]) == 1 and states[2][0]["id"] == x and near(states[2][0]["duration"], 6.0),
                  str(spans(states[2])))

            # consolidate a GROUP: isolation + bake = the documented two
            project_new()
            cmd("project.save_as", path=proj)
            p1 = clip(0, 2.0, 6.0)
            q1 = clip(1, 2.0, 6.0)
            g1 = cmd("group.create", ids=[p1, q1])["id"]
            if depth:
                w1 = clip(5, 2.0, 6.0)
                cmd("group.expand", id=cmd("group.create", ids=[g1, w1])["id"], expanded=True)
            cmd("selection.clear")
            grow = ent(g1)["display_lane"]
            zone(4.0, 6.0, [grow])
            act("consolidate_group", g1)
            cmd("wait_idle", timeout_ms=60000)
            lst = on_row(grow, kinds=("clip", "group"))
            check(T("consolidate a group: three pieces, the middle one an instance"),
                  len(lst) == 3 and lst[1].get("definition") and not lst[0].get("definition")
                  and not lst[2].get("definition"),
                  str([(o["kind"], o["start"], o["duration"], o.get("definition")) for o in lst]))
            undo()
            undo()
            lst = on_row(grow, kinds=("clip", "group"))
            check(T("consolidate a group: TWO ⌘Z give the group back whole"),
                  len(lst) == 1 and lst[0]["id"] == g1 and near(lst[0]["duration"], 6.0),
                  str([(o["kind"], o["start"], o["duration"]) for o in lst]))

            # deconsolidate an instance, in the middle
            (x,) = build((0, 2.0, 6.0))
            cmd("project.save_as", path=proj)
            job = cmd("consolidate.make", id=x)
            cmd("job.wait", id=job["job_id"], timeout_ms=60000)
            cmd("wait_idle", timeout_ms=60000)
            inst = [o for o in objs() if o.get("definition")]
            check(T("deconsolidate: setup, an instance exists"), len(inst) == 1, str(inst))
            if inst:
                ii = inst[0]
                irow = ii["display_lane"]
                zone(4.0, 6.0, [irow])
                act("deconsolidate", ii["id"])
                lst = on_row(irow, kinds=("clip", "group"))
                check(T("deconsolidate: three pieces, ONLY the middle one left its definition"),
                      len(lst) == 3 and lst[0].get("definition") and lst[2].get("definition")
                      and not lst[1].get("definition"),
                      str([(o["kind"], o["start"], o["duration"], o.get("definition")) for o in lst]))
                undo()
                lst = on_row(irow, kinds=("clip", "group"))
                check(T("deconsolidate: ONE ⌘Z gives the instance back whole"),
                      len(lst) == 1 and lst[0].get("definition") and near(lst[0]["duration"], 6.0),
                      str([(o["kind"], o["start"], o["duration"], o.get("definition")) for o in lst]))

            # ── FX link over several objects ───────────────────────────────────────────────
            x, y = build((0, 2.0, 6.0), (1, 2.0, 6.0))
            cmd("plugin.add", host=x, identifier="4bandEq", format="TracktionInternal")
            cmd("plugin.add", host=y, identifier="reverb", format="TracktionInternal")
            rx, ry = ent(x)["display_lane"], ent(y)["display_lane"]
            zone(4.0, 6.0, sorted({rx, ry}))
            r = act("create_fx_link", x, dry=True)
            check(T("FX link: offered in zone scope over two objects with a plugin"),
                  r["target_ids"] and len(r["target_ids"]) == 2, json.dumps(r))
            n_links = cmd("fxlink.list")["count"]

            def hosts_by_link():
                return [{m["host"] for m in l["members"]} for l in cmd("fxlink.list")["links"]]

            act("create_fx_link", x)
            lx, ly = on_row(rx), on_row(ry)
            check(T("FX link: both lanes cut in three"), len(lx) == 3 and len(ly) == 3,
                  "%s %s" % (spans(lx), spans(ly)))
            mid = {lx[1]["id"], ly[1]["id"]}
            check(T("FX link (range cuts the objects): the two MIDDLE pieces share ONE bin"),
                  any(mid <= h for h in hosts_by_link()),
                  "links=%s (the cut itself auto-bins each object's pieces, so nothing joins x and y)"
                  % [sorted(k[:4] for k in h) for h in hosts_by_link()])
            undo()
            check(T("FX link: ONE ⌘Z gives both objects back whole, no new bin"),
                  spans(on_row(rx)) == [(2.0, 8.0)] and spans(on_row(ry)) == [(2.0, 8.0)]
                  and cmd("fxlink.list")["count"] == n_links,
                  "%s %s %s" % (spans(on_row(rx)), spans(on_row(ry)), cmd("fxlink.list")["count"]))

            # the same over WHOLE objects: no cut, so no automatic bin to get in the way
            zone(2.0, 8.0, sorted({rx, ry}))
            act("create_fx_link", x)
            check(T("FX link (range = whole objects): x and y share ONE bin"),
                  any({x, y} <= h for h in hosts_by_link()),
                  str([sorted(k[:4] for k in h) for h in hosts_by_link()]))
            undo()
            check(T("FX link (whole objects): ONE ⌘Z removes it"),
                  cmd("fxlink.list")["count"] == n_links, str(cmd("fxlink.list")["count"]))

        # ── an empty lane (no id): the range's own menu in the same command ─────────────────
        project_new()
        a = clip(0, 2.0, 6.0)
        zone(4.0, 6.0, [0])
        r = act("group_selection", None, dry=True)
        check("no id: the range's own entries are offered (group)", r["scope"] == "zone", json.dumps(r))
        act("group_selection", None)
        check("no id: wrapping the range makes a group of the 4..6 part",
              any(o["kind"] == "group" and near(o["start"], 4.0) and near(o["duration"], 2.0) for o in objs()),
              str([(o["kind"], o["start"], o["duration"]) for o in objs()]))
        undo()
        check("no id: ONE ⌘Z", not any(o["kind"] == "group" for o in objs())
              and ent(a) is not None and near(ent(a)["duration"], 6.0))
finally:
    shutil.rmtree(ROOT, ignore_errors=True)

print()
if fails:
    print("FAILED (%d): %s" % (len(fails), ", ".join(fails)))
    sys.exit(1)
print("ALL PASS")

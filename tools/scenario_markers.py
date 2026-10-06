#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Markers, regions and comments — a scenario that ASSERTS rather than replaying.

Same shape as `scenario_families.py`, and for the same reason: a JSON-lines scenario
cannot reuse an identifier an earlier command returned, and everything here does.

    # 1. launch the app with the API, on a SHORT socket (a system limit: 103 bytes).
    #    `--no-recent`: the throwaway project below does not enter "Recent projects".
    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --socket=/tmp/o.sock

    # 2. replay
    ./scenario_markers.py /tmp/o.sock

What it is really out to prove, beyond the commands answering: that the markers an
object carries FOLLOW ITS MATTER through the editing gestures. A cut distributes them
between the two halves and rebases the right-hand ones on the cut; a reverse mirrors
them; an undo gives them back; a save and a reload keep them. That is the part no
build can check, and the part the eye alone would otherwise have to catch.

Exit: 0 if every assertion passes, 1 otherwise.
"""

import json, os, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

if len(sys.argv) != 2:
    print(__doc__)
    sys.exit(2)

SOCK = sys.argv[1]
FIXTURE = os.path.join(HERE, "fixtures", "bip.wav")

fails = []


def check(label, ok, detail=""):
    if ok:
        print("ok    " + label)
    else:
        fails.append(label)
        print("FAIL  %s  %s" % (label, detail))


def approx(a, b, eps=1e-6):
    return abs(a - b) < eps


with ObjekatClient(SOCK) as c:
    def cmd(_cmd_name, **params):
        return c.send(_cmd_name, params or None)

    info = cmd("app.info")
    check("--no-recent honoured", info.get("records_recent_projects") is False,
          str(info.get("records_recent_projects")))
    cmd("project.new")

    # ── the band ───────────────────────────────────────────────────────────
    lane = cmd("marker_lane.create", name="Nicolas")["lane"]
    m1 = cmd("marker.add", lane=lane, at=1.5, name="attaque")["marker"]
    r1 = cmd("marker.add", lane=lane, at=4.0, duration=3.0, name="refrain")["marker"]
    lanes = cmd("marker_lane.list")["lanes"]
    check("one row, two entries", len(lanes) == 1 and lanes[0]["count"] == 2)
    entries = {m["id"]: m for m in lanes[0]["markers"]}
    check("a marker is not a region", entries[m1]["is_region"] is False)
    check("a region is one", entries[r1]["is_region"] is True and approx(entries[r1]["duration"], 3.0))
    check("read back in order", [m["name"] for m in lanes[0]["markers"]] == ["attaque", "refrain"])

    cmd("marker.move", lane=lane, marker=m1, at=2.25)
    cmd("marker.rename", lane=lane, marker=m1, name="attaque 2")
    got = [m for m in cmd("marker_lane.list")["lanes"][0]["markers"] if m["id"] == m1][0]
    check("moved and renamed", approx(got["time"], 2.25) and got["name"] == "attaque 2")

    cmd("marker_lane.set_visible", lane=lane, visible=False)
    check("hiding is not deleting",
          cmd("marker_lane.list")["lanes"][0]["visible"] is False
          and cmd("marker_lane.list")["lanes"][0]["count"] == 2)
    cmd("marker_lane.set_visible", lane=lane, visible=True)

    # an unknown row is refused rather than quietly served the default one
    try:
        cmd("marker.add", lane="00000000-0000-0000-0000-000000000000", at=1)
        check("an unknown row is refused", False, "it went through")
    except ObjekatError as e:
        check("an unknown row is refused", e.code == "not_found", e.code)

    # ── an object's markers ────────────────────────────────────────────────
    obj = cmd("object.add", path=FIXTURE, lane=0, start=2.0)
    oid = obj.get("id") or obj.get("object") or obj["objects"][0]["id"]
    cmd("wait_idle", timeout_ms=5000)
    dur = [o for o in cmd("object.list")["objects"] if o["id"] == oid][0]["duration"]
    print("      (object %.3f s long, starting at 2.0)" % dur)

    # The object runs [2.0, 2.4]. Laid at an ABSOLUTE time, stored RELATIVE.
    cmd("object.add_marker", object=oid, at=2.20, name="dedans")
    got = cmd("object.list_markers", object=oid)
    check("stored in the object's frame", approx(got["markers"][0]["time"], 0.20),
          str(got["markers"][0]["time"]))
    check("read back absolute too", approx(got["markers"][0]["absolute_time"], 2.20))
    check("origin reported", approx(got["origin"], 2.0))
    check("and it is inside the window", got["markers"][0]["audible"] is True)

    # moving the object leaves the marker on the same material
    cmd("object.move", id=oid, start=5.0)
    got = cmd("object.list_markers", object=oid)
    check("a move costs nothing", approx(got["markers"][0]["time"], 0.20))
    check("and the absolute reading follows", approx(got["markers"][0]["absolute_time"], 5.20))
    cmd("object.move", id=oid, start=2.0)

    # a marker pushed outside the window is kept, not lost
    out = cmd("object.add_marker", object=oid, rel=-0.1, name="derriere")["marker"]
    outm = [m for m in cmd("object.list_markers", object=oid)["markers"] if m["id"] == out][0]
    check("a marker behind the edge is kept but silent", outm["audible"] is False)
    cmd("object.remove_marker", object=oid, marker=out)

    # ── the real test: a cut through a marked object ───────────────────────
    cmd("object.add_marker", object=oid, at=2.05, name="tot")
    cmd("object.add_marker", object=oid, at=2.30, name="tard")
    cmd("object.split_at", ids=[oid], seconds=2.20)
    objs = sorted(cmd("object.list")["objects"], key=lambda o: o["start"])
    check("the cut made two halves", len(objs) == 2, str(len(objs)))
    left, right = objs[0], objs[1]
    lm = {m["name"]: m for m in cmd("object.list_markers", object=left["id"])["markers"]}
    rm = {m["name"]: m for m in cmd("object.list_markers", object=right["id"])["markers"]}
    check("the early marker stayed left", "tot" in lm and "tot" not in rm,
          "%s / %s" % (list(lm), list(rm)))
    check("the late one went right", "tard" in rm and "tard" not in lm,
          "%s / %s" % (list(lm), list(rm)))
    check("the one exactly on the cut went right", "dedans" in rm and "dedans" not in lm)
    check("rebased on the cut, not on the old origin",
          approx(rm["tard"]["time"], 0.10) and approx(rm["tard"]["absolute_time"], 2.30),
          "rel %s abs %s" % (rm["tard"]["time"], rm["tard"]["absolute_time"]))
    check("the one on the cut sits at the new origin", approx(rm["dedans"]["time"], 0.0),
          str(rm["dedans"]["time"]))
    check("and the left one did not move",
          approx(lm["tot"]["absolute_time"], 2.05), str(lm["tot"]["absolute_time"]))

    # undo puts the two halves back into one, markers included
    cmd("edit.undo")
    objs = cmd("object.list")["objects"]
    check("undo gives one object back", len(objs) == 1, str(len(objs)))
    names = sorted(m["name"] for m in cmd("object.list_markers", object=objs[0]["id"])["markers"])
    check("with its three markers", names == ["dedans", "tard", "tot"], str(names))

    # ── a reverse turns the markers round ──────────────────────────────────
    oid = objs[0]["id"]
    before = {m["name"]: m["time"] for m in cmd("object.list_markers", object=oid)["markers"]}
    odur = [o for o in cmd("object.list")["objects"] if o["id"] == oid][0]["duration"]
    cmd("object.set_reversed", id=oid, reversed=True)
    after = {m["name"]: m["time"] for m in cmd("object.list_markers", object=oid)["markers"]}
    check("reverse mirrors every marker",
          all(approx(after[n], odur - before[n]) for n in before), "%s -> %s" % (before, after))
    cmd("object.set_reversed", id=oid, reversed=False)

    # ── comments ───────────────────────────────────────────────────────────
    cid = cmd("comment.create", **{"from": 1.0, "to": 4.0, "lane": 2,
                                   "text": "à **revoir** : trop sec"})["comment"]
    cl = cmd("comment.list")["comments"]
    check("one comment", len(cl) == 1 and approx(cl[0]["duration"], 3.0))
    check("markdown kept verbatim", "**revoir**" in cl[0]["text"])
    cmd("comment.set_text", comment=cid, text="ok")
    check("text rewritten", cmd("comment.list")["comments"][0]["text"] == "ok")

    # ── colours: what is inherited, and what is asked for ──────────────────
    # A mark takes the colour of what carries it until it asks for its own — the ROW for a
    # mark of the band, WHITE for a comment and for a mark on an object. That is why every
    # `color_index` here reads null until somebody sets one: null is not 'no colour'.
    def band_marker(mid, lane_id=None):
        for l in cmd("marker_lane.list")["lanes"]:
            if lane_id and l["id"] != lane_id:
                continue
            for m in l["markers"]:
                if m["id"] == mid:
                    return m
        return None

    check("a mark is born inheriting", band_marker(m1)["color_index"] is None)
    cmd("marker_lane.set_color", lane=lane, color_index=5)
    check("the row's own hue is set",
          cmd("marker_lane.list")["lanes"][0]["color_index"] == 5)
    check("recolouring the row leaves the marks inheriting", band_marker(m1)["color_index"] is None)

    cmd("marker.set_color", lane=lane, marker=m1, color_index=7)
    check("a mark can ask for its own", band_marker(m1)["color_index"] == 7)
    check("and its neighbour still inherits", band_marker(r1)["color_index"] is None)
    cmd("marker.set_color", lane=lane, marker=r1, color_index=2)
    cmd("marker.set_color", lane=lane, marker=r1)          # no color_index = inherit again
    check("asking for none gives the row's back", band_marker(r1)["color_index"] is None)

    cmd("object.set_marker_color", object=oid, marker=
        cmd("object.list_markers", object=oid)["markers"][0]["id"], color_index=9)
    check("a mark on an object takes a hue too",
          cmd("object.list_markers", object=oid)["markers"][0]["color_index"] == 9)

    check("a comment is born WHITE, not a palette hue", cl[0]["color_index"] is None)
    cmd("comment.set_color", comment=cid, color_index=3)
    check("a comment can be sorted by colour",
          cmd("comment.list")["comments"][0]["color_index"] == 3)
    cmd("comment.set_color", comment=cid)
    check("and go back to white", cmd("comment.list")["comments"][0]["color_index"] is None)
    cmd("comment.set_color", comment=cid, color_index=3)

    # ── changing row keeps the mark's identity ─────────────────────────────
    lane2 = cmd("marker_lane.create", name="Relecture")["lane"]
    cmd("marker.set_lane", lane=lane, marker=r1, to=lane2)
    lanes_now = {l["id"]: l for l in cmd("marker_lane.list")["lanes"]}
    check("it left its row", all(m["id"] != r1 for m in lanes_now[lane]["markers"]))
    moved = [m for m in lanes_now[lane2]["markers"] if m["id"] == r1]
    check("and arrived on the other WITH THE SAME ID", len(moved) == 1)
    check("its time did not change — a row is a layer, not a place",
          moved and approx(moved[0]["time"], 4.0), str(moved))
    cmd("marker.set_lane", lane=lane2, marker=r1, to=lane)
    cmd("marker_lane.remove", lane=lane2)
    check("back where it was", len(cmd("marker_lane.list")["lanes"][0]["markers"]) == 2)

    # ── it survives a save and a reload ────────────────────────────────────
    folder = tempfile.mkdtemp(prefix="objekat-markers-")
    path = os.path.join(folder, "test.objekat.json")
    cmd("project.set_snap", enabled=False)   # a session built OFF the grid must reopen off it
    cmd("project.save_as", path=path)
    with open(path) as f:
        doc = json.load(f)
    check("session format bumped", doc.get("version") == 19, str(doc.get("version")))
    check("the rows are written", len(doc.get("markerLanes", [])) == 1)
    check("the comments are written", len(doc.get("comments", [])) == 1)
    check("the object's markers are written",
          len(doc["items"][0].get("markers", [])) == 3, str(doc["items"][0].get("markers")))
    check("the notice mentions the two frames",
          any("RELATIVE to the start of the object" in l for l in doc.get("_readme", [])))
    check("the snap is written with the project", doc.get("snapEnabled") is False,
          str(doc.get("snapEnabled")))

    cmd("project.new")
    check("a new project empties the band", cmd("marker_lane.list")["count"] == 0)
    check("and starts back ON the grid",
          cmd("project.get_state").get("snapEnabled") is not False)
    cmd("project.open", path=path)
    cmd("wait_idle", timeout_ms=5000)
    reread = cmd("marker_lane.list")
    check("the rows come back", reread["count"] == 1 and reread["lanes"][0]["name"] == "Nicolas")
    check("with their two entries", reread["lanes"][0]["count"] == 2)
    check("the comment comes back", cmd("comment.list")["count"] == 1)
    check("and the project reopens OFF the grid, as it was left",
          cmd("project.get_state").get("snapEnabled") is False)
    cmd("project.set_snap", enabled=True)
    check("the row keeps its hue", reread["lanes"][0]["color_index"] == 5)
    kept = {m["id"]: m for m in reread["lanes"][0]["markers"]}
    check("a hue asked for is written down", kept[m1]["color_index"] == 7)
    check("an inherited one is NOT — it is an absent key, not a value",
          kept[r1]["color_index"] is None)
    check("the comment keeps its hue",
          cmd("comment.list")["comments"][0]["color_index"] == 3)
    rid = cmd("object.list")["objects"][0]["id"]
    check("the object's markers come back",
          cmd("object.list_markers", object=rid)["count"] == 3)

    # ── a comment follows its lane when a group opens ──────────────────────
    # The bug this asserts against: a comment used to store the DISPLAY row it was drawn on.
    # Opening a group inserts its children's rows and pushes everything below DOWN — the
    # comment stayed put while the lane it was talking about slid away, and the note ended up
    # beside somebody else's material. It stores a BASE row now, and `display_lane` is where
    # that lands on screen.
    cmd("project.new")
    a1 = cmd("object.add", path=FIXTURE, lane=0, start=0.0)["id"]
    a2 = cmd("object.add", path=FIXTURE, lane=1, start=1.0)["id"]
    cmd("object.add", path=FIXTURE, lane=3, start=0.5)
    cmd("wait_idle", timeout_ms=5000)
    note = cmd("comment.create", **{"from": 0.0, "to": 2.0, "lane": 3, "text": "sur la 3"})["comment"]
    got = cmd("comment.list")["comments"][0]
    check("a closed timeline draws a comment on its own row",
          got["lane"] == 3 and got["display_lane"] == 3,
          "%s / %s" % (got["lane"], got["display_lane"]))

    grp = cmd("group.create", ids=[a1, a2])["id"]
    cmd("group.expand", id=grp, expanded=True)
    got = cmd("comment.list")["comments"][0]
    check("opening a group pushes the comment down with the lanes",
          got["display_lane"] > 3, "display_lane %s" % got["display_lane"])
    check("and what is STORED has not moved — it is a base row", got["lane"] == 3)

    cmd("group.expand", id=grp, expanded=False)
    got = cmd("comment.list")["comments"][0]
    check("closing it brings the comment back", got["display_lane"] == 3)
    cmd("comment.remove", comment=note)

    # ── a comment INSIDE a group, and recursively ─────────────────────────
    # A note about a group's content belongs in the group, not beside it: it changes FRAME on the
    # way in — its time becomes the group's own and its row a row of the group's band — which is
    # what makes it follow the group when it moves, disappear while the group is folded, be copied
    # with it and go with it when it is deleted. Exactly the bargain a marker carried by an object
    # strikes, one level up.
    cmd("project.new")
    b1 = cmd("object.add", path=FIXTURE, lane=0, start=2.0)["id"]
    b2 = cmd("object.add", path=FIXTURE, lane=1, start=3.0)["id"]
    cmd("wait_idle", timeout_ms=5000)
    g = cmd("group.create", ids=[b1, b2])["id"]
    cmd("group.expand", id=g, expanded=True)
    gstart = cmd("object.get", id=g)["start"]
    inner = cmd("comment.create", **{"from": gstart + 1.0, "to": gstart + 2.0,
                                     "lane": 0, "parent": g, "text": "dans le groupe"})["comment"]
    got = [x for x in cmd("comment.list")["comments"] if x["id"] == inner][0]
    check("a comment can be laid IN a group", got["parent"] == g)
    check("its stored time is the GROUP's frame", approx(got["start"], 1.0), str(got["start"]))
    check("and its absolute time is where it was asked for",
          approx(got["abs_start"], gstart + 1.0), str(got["abs_start"]))
    check("it is drawn INSIDE the group's band", got["display_lane"] is not None
          and got["display_lane"] > 0, str(got["display_lane"]))

    # Moving the group carries the note: nothing in the gesture names it.
    cmd("object.move", id=g, start=gstart + 5.0)
    got = [x for x in cmd("comment.list")["comments"] if x["id"] == inner][0]
    check("the comment FOLLOWS its group when it moves",
          approx(got["abs_start"], gstart + 6.0) and approx(got["start"], 1.0),
          "%s / %s" % (got["abs_start"], got["start"]))
    cmd("object.move", id=g, start=gstart)

    # Folded, it has no row at all — and that is a null, not a wrong row.
    cmd("group.expand", id=g, expanded=False)
    got = [x for x in cmd("comment.list")["comments"] if x["id"] == inner][0]
    check("a folded group draws none of its comments", got["display_lane"] is None,
          str(got["display_lane"]))
    cmd("group.expand", id=g, expanded=True)
    check("unfolding gives it its row back",
          [x for x in cmd("comment.list")["comments"]
           if x["id"] == inner][0]["display_lane"] is not None)

    # A save and a reload keep the frame.
    folder2 = tempfile.mkdtemp(prefix="objekat-nested-comment-")
    path2 = os.path.join(folder2, "nested.objekat.json")
    cmd("project.save_as", path=path2)
    with open(path2) as f:
        doc2 = json.load(f)
    check("the parent is written into the session",
          doc2.get("comments", [{}])[0].get("parentID") == g, str(doc2.get("comments")))
    check("the notice describes the frame a parent puts the comment in",
          any("parentID" in l for l in doc2.get("_readme", [])))
    cmd("project.new")
    cmd("project.open", path=path2)
    cmd("wait_idle", timeout_ms=5000)
    back = cmd("comment.list")["comments"]
    check("a nested comment comes back with its group",
          len(back) == 1 and back[0]["parent"] == g and approx(back[0]["start"], 1.0),
          str(back))

    # A copy takes it along, a deletion takes it away.
    cmd("object.duplicate", ids=[g])
    cl = cmd("comment.list")["comments"]
    check("duplicating a group duplicates its comments", len(cl) == 2, str(len(cl)))
    check("and the copy hangs off the COPY of the group",
          len({x["parent"] for x in cl}) == 2, str([x["parent"] for x in cl]))
    cmd("object.remove", ids=[g])
    cl = cmd("comment.list")["comments"]
    check("deleting a group takes its comments with it",
          len(cl) == 1 and cl[0]["parent"] != g, str(cl))

    # Dissolving is opening, not deleting: the note comes up onto the timeline.
    other = cl[0]["parent"]
    cmd("group.disband", id=other)
    cl = cmd("comment.list")["comments"]
    check("dissolving a group brings its comments up to the timeline",
          len(cl) == 1 and cl[0]["parent"] is None, str(cl))
    check("and they keep the instant they were at",
          approx(cl[0]["abs_start"], cl[0]["start"]), str(cl[0]))

    # ── the marks are SNAP TARGETS ────────────────────────────────────────
    # The point of putting a mark somewhere is to be able to land on it. Until now the snap knew
    # the grid and the objects' edges and nothing else, so an edge had to be eyeballed onto a
    # marker — which is a mark doing half its job. A region counts TWICE (both its bounds), and a
    # HIDDEN row counts for nothing: it keeps its content but has stopped saying anything, and an
    # edge jumping onto something nobody can see reads as a fault.
    #
    # The numbers are chosen OFF the grid, which is 0.5 s at the default zoom (100 px/s): 3.43
    # could only ever have been reached by the marker. Mind the object's OWN edges, which are
    # targets as well and move with it — hence a fresh position asked for at each step rather
    # than a loop over one.
    cmd("project.new")
    cmd("project.set_snap", enabled=True)
    obj = cmd("object.add", path=FIXTURE, lane=0, start=0.0)["id"]
    cmd("wait_idle", timeout_ms=5000)

    def move_to(t):
        cmd("object.move", id=obj, start=t, snap=True)
        return cmd("object.get", id=obj)["start"]

    got = move_to(3.42)
    check("with nothing there, the grid still has the last word", abs(got - 3.5) < 1e-9, str(got))

    lane = cmd("marker_lane.create", name="snap")["lane"]
    mk = cmd("marker.add", lane=lane, at=3.43)["marker"]
    got = move_to(3.42)
    check("a MARKER catches the edge, over the grid line beside it",
          abs(got - 3.43) < 1e-9, str(got))
    got = move_to(3.20)
    check("out of reach it does not pull — 8 px and no more", abs(got - 3.0) < 1e-9, str(got))

    # 1.90 s rather than 0.90: a region is never shorter than 1 s (Marker.minRegionDuration).
    reg = cmd("marker.add", lane=lane, at=6.03, duration=1.90)["marker"]
    got = move_to(6.02)
    check("a REGION's start catches it", abs(got - 6.03) < 1e-9, str(got))
    got = move_to(7.92)
    check("and its END too — a region is two targets, not one",
          abs(got - 7.93) < 1e-9, str(got))

    move_to(1.0)                                    # out of its own way first
    cmd("marker_lane.set_visible", lane=lane, visible=False)
    got = move_to(7.92)
    check("a HIDDEN row catches nothing: what one cannot see must not pull",
          abs(got - 8.0) < 1e-9, str(got))
    cmd("marker_lane.set_visible", lane=lane, visible=True)
    cmd("marker.remove", lane=lane, marker=mk)
    cmd("marker.remove", lane=lane, marker=reg)

    # A mark carried by an OBJECT is a target too, and in EDIT time: it is stored RELATIVE to its
    # object, so what the snap has to offer is `start + time`. 9.07 rather than 0.07, and it must
    # also beat the neighbour's own left edge at 9.0, which is further away.
    other = cmd("object.add", path=FIXTURE, lane=2, start=9.0)["id"]
    cmd("wait_idle", timeout_ms=5000)
    cmd("object.add_marker", object=other, at=9.07)      # absolute; stored as 0.07 relative
    got = move_to(9.06)
    check("a mark carried by an object pulls at its EDIT time", abs(got - 9.07) < 1e-9, str(got))

    # ── and a MARK is snapped too, without catching on itself ──────────────
    # A marker and a region are placed against the same material an object's edge is placed
    # against, so the band's drag goes through the same snap and lights the same dashed guide.
    # What only shows once a mark is dragged: the drag writes into the model on every frame, so
    # the mark stands where the hand last put it — and left in its own target list it would be
    # its own magnet, winning every time within the eight pixels of tolerance and refusing to
    # move at all. `marker.move` with `snap` is that door, which is what makes it assertable.
    cmd("project.new")
    cmd("project.set_snap", enabled=True)
    obj = cmd("object.add", path=FIXTURE, lane=0, start=0.0)["id"]
    cmd("wait_idle", timeout_ms=5000)
    cmd("object.move", id=obj, start=20.0)              # the object's own edges out of the way
    lane = cmd("marker_lane.create", name="drag")["lane"]

    mk = cmd("marker.add", lane=lane, at=4.03)["marker"]
    got = cmd("marker.move", lane=lane, marker=mk, at=4.06, snap=True)["at"]
    check("a dragged marker does NOT catch on itself", abs(got - 4.0) < 1e-9, str(got))
    got = cmd("marker.move", lane=lane, marker=mk, at=4.20, snap=True)["at"]
    check("and it goes on moving with the hand", abs(got - 4.0) < 1e-9, str(got))

    # Another mark on the row is a target like any other — that is what marks are FOR.
    ref = cmd("marker.add", lane=lane, at=7.13)["marker"]
    got = cmd("marker.move", lane=lane, marker=mk, at=7.12, snap=True)["at"]
    check("but it does catch on somebody ELSE's mark", abs(got - 7.13) < 1e-9, str(got))
    cmd("marker.remove", lane=lane, marker=ref)

    # ── cropping a REGION ─────────────────────────────────────────────────
    # A region is a passage, and until now its bounds could only be set when it was created: one
    # re-created a region rather than adjusting it. Its two ends crop, the other end anchoring,
    # exactly as on a clip and on a comment.
    reg = cmd("marker.add", lane=lane, at=10.0, duration=2.0)["marker"]
    r = cmd("marker.move", lane=lane, marker=reg, at=10.0, duration=3.4)
    check("a region's END can be pulled out",
          abs(r["at"] - 10.0) < 1e-9 and abs(r["duration"] - 3.4) < 1e-9, json.dumps(r))
    r = cmd("marker.move", lane=lane, marker=reg, at=11.2, duration=2.2)
    check("and its START, the far end staying put",
          abs(r["at"] - 11.2) < 1e-9 and abs(r["at"] + r["duration"] - 13.4) < 1e-9, json.dumps(r))
    # BOTH bounds go through the snap: a region is two instants, not one.
    r = cmd("marker.move", lane=lane, marker=reg, at=11.02, duration=2.46, snap=True)
    check("both of a region's bounds snap",
          abs(r["at"] - 11.0) < 1e-9 and abs(r["at"] + r["duration"] - 13.5) < 1e-9, json.dumps(r))
    check("and neither of them caught on the other", r["duration"] > 0.5, json.dumps(r))
    cmd("edit.undo")
    row = [l for l in cmd("marker_lane.list")["lanes"] if l["id"] == lane][0]
    r = [m for m in row["markers"] if m["id"] == reg][0]
    check("a crop is one undo", abs(r["time"] - 11.2) < 1e-9, json.dumps(r))

    # ── picking SEVERAL marks ──────────────────────────────────────────────
    # The click's logic lives in the view-model (`handleMarkBandClick`), and `marker.select`
    # drives exactly that: a plain click, ⌘-clicks (toggle), ⇧-clicks (extend). What no script can
    # reach is the hand's own drag of a group and the menu — the rest is here.
    cmd("project.new")
    cmd("project.set_snap", enabled=False)
    rowA = cmd("marker_lane.create", name="A")["lane"]
    rowB = cmd("marker_lane.create", name="B")["lane"]
    mA1 = cmd("marker.add", lane=rowA, at=1.0, name="a1")["marker"]
    mA2 = cmd("marker.add", lane=rowA, at=3.0, name="a2")["marker"]
    rA = cmd("marker.add", lane=rowA, at=5.0, duration=2.0, name="reg")["marker"]
    mA3 = cmd("marker.add", lane=rowA, at=6.5, name="a3")["marker"]
    mA4 = cmd("marker.add", lane=rowA, at=9.0, name="a4")["marker"]
    mB1 = cmd("marker.add", lane=rowB, at=2.0, name="b1")["marker"]
    mB2 = cmd("marker.add", lane=rowB, at=4.0, name="b2")["marker"]
    mB3 = cmd("marker.add", lane=rowB, at=8.0, name="b3")["marker"]

    def lm(row, mid):
        return {"lane": row, "marker": mid}

    def sel_ids():
        return [i.get("marker") or i.get("comment") for i in cmd("marker.selection")["items"]]

    def sel_set():
        return set(sel_ids())

    def cursor():
        return cmd("transport.state")["cursor"]

    def select(items, mode="replace"):
        return cmd("marker.select", items=items, mode=mode)

    # A plain click: the mark alone, and the CURSOR at its start.
    cmd("transport.seek", seconds=7.7)
    select([lm(rowA, mA1)])
    check("a plain click selects the mark", sel_ids() == [mA1], str(sel_ids()))
    check("and the cursor goes to its start", approx(cursor(), 1.0), str(cursor()))
    select([lm(rowA, rA)])
    check("on a REGION the cursor goes to its START", approx(cursor(), 5.0), str(cursor()))
    check("and the selection is the region alone", sel_ids() == [rA], str(sel_ids()))

    # ⌘: in and out, the others staying, the cursor left where it was.
    select([lm(rowA, mA1)])
    cmd("transport.seek", seconds=7.7)
    select([lm(rowA, mA2)], mode="toggle")
    check("⌘-click adds to the selection", sel_set() == {mA1, mA2}, str(sel_ids()))
    check("and does not move the cursor", approx(cursor(), 7.7), str(cursor()))
    select([lm(rowB, mB1)], mode="toggle")
    check("across rows too", sel_set() == {mA1, mA2, mB1}, str(sel_ids()))
    select([lm(rowA, mA2)], mode="toggle")
    check("⌘-click on a selected mark takes it OUT", sel_set() == {mA1, mB1}, str(sel_ids()))

    # A `replace` with several items = a click then ⌘-clicks.
    select([lm(rowA, mA1), lm(rowA, mA2), lm(rowB, mB2)])
    check("replace with three items selects exactly them",
          sel_set() == {mA1, mA2, mB2}, str(sel_ids()))

    # ⇧: the marks between the anchor and the click, in TIME and in ROWS — anchored, so a second
    # ⇧-click aimed back inside SHORTENS it.
    cmd("transport.seek", seconds=0)
    select([lm(rowA, mA1)])
    select([lm(rowA, mA3)], mode="extend")
    check("⇧-click takes what lies between (a1 … a3), a region included",
          sel_set() == {mA1, mA2, rA, mA3}, str(sel_ids()))
    select([lm(rowA, mA2)], mode="extend")
    check("a second ⇧-click back inside SHORTENS it (the anchor holds still)",
          sel_set() == {mA1, mA2}, str(sel_ids()))
    # A region counts by OVERLAP: ⇧ stopping INSIDE it still takes it whole.
    mIn = cmd("marker.add", lane=rowA, at=6.0, name="in")["marker"]
    select([lm(rowA, mA1)])
    select([lm(rowA, mIn)], mode="extend")
    check("a region the span only overlaps is taken",
          rA in sel_set() and mIn in sel_set() and mA3 not in sel_set(), str(sel_ids()))
    cmd("marker.remove", lane=rowA, marker=mIn)
    # Rows: from row A to row B, the time span applies to both.
    select([lm(rowA, mA1)])
    select([lm(rowB, mB2)], mode="extend")
    check("⇧ across rows takes the span of time in BOTH (a1 a2 b1 b2, not b3)",
          sel_set() == {mA1, mA2, mB1, mB2}, str(sel_ids()))
    # A click on nothing lets go; ⇧ with no anchor simply adds.
    select([])
    check("a click on nothing deselects", sel_ids() == [], str(sel_ids()))
    sel = select([lm(rowB, mB3)], mode="extend")
    check("⇧ with no anchor just adds the mark", sel_ids() == [mB3], str(sel_ids()))
    # A stale anchor is validated, not trusted.
    select([lm(rowA, mA1)])
    cmd("marker.remove", lane=rowA, marker=mA1)
    select([lm(rowA, mA4)], mode="extend")
    check("an anchor that has gone is not extended from", sel_ids() == [mA4], str(sel_ids()))
    mA1 = cmd("marker.add", lane=rowA, at=1.0, name="a1")["marker"]

    # Exclusivity with the objects: one or the other, never both.
    obj = cmd("object.add", path=FIXTURE, lane=3, start=2.0)
    oid = obj.get("id") or obj.get("object") or obj["objects"][0]["id"]
    cmd("wait_idle", timeout_ms=5000)
    select([lm(rowA, mA2), lm(rowB, mB2)])
    check("marks selected", len(sel_ids()) == 2)
    cmd("selection.set", ids=[oid])
    check("selecting an object lets go of the marks", sel_ids() == [], str(sel_ids()))
    select([lm(rowA, mA2)])
    check("and selecting a mark lets go of the objects",
          cmd("selection.get")["count"] == 0, json.dumps(cmd("selection.get")))

    # ⌫ on several marks of every kind: ONE undo.
    mk_obj = cmd("object.add_marker", object=oid, at=2.1, name="carried")["marker"]
    note = cmd("comment.create", **{"from": 3.0, "to": 4.0, "lane": 5, "text": "note"})["comment"]
    everything = [lm(rowA, mA2), lm(rowB, mB2), {"object": oid, "marker": mk_obj}, {"comment": note}]
    select(everything)
    check("marks of the band, of an object and a comment, together", len(sel_ids()) == 4,
          str(sel_ids()))

    def n_marks():
        band = sum(l["count"] for l in cmd("marker_lane.list")["lanes"])
        return band, len(cmd("object.list_markers", object=oid)["markers"]), \
            len(cmd("comment.list")["comments"])

    before = n_marks()
    r = cmd("marker.remove_selected")
    check("remove_selected takes all four", r["removed"] == 4 and r["remaining"] == 0, json.dumps(r))
    after = n_marks()
    check("band -2, object -1, comment -1",
          after == (before[0] - 2, before[1] - 1, before[2] - 1), "%s -> %s" % (before, after))
    cmd("edit.undo")
    check("ONE undo gives all four back", n_marks() == before, str(n_marks()))
    # ... and the same through ⌫'s own function, with two marks.
    select([lm(rowA, mA2), lm(rowB, mB2)])
    cmd("marker.remove_selected")
    cmd("edit.undo")
    check("two marks, one undo", n_marks() == before, str(n_marks()))

    # The selection is pruned when its targets go: an undo that takes a mark away.
    zed = cmd("marker.add", lane=rowA, at=8.5, name="zed")["marker"]
    select([lm(rowA, mA2), lm(rowA, zed)])
    cmd("edit.undo")          # undoes the creation of `zed`
    check("an undo that removes a mark prunes it from the selection",
          sel_ids() == [mA2], str(sel_ids()))
    # ... a deleted row takes its marks' selection with it.
    select([lm(rowB, mB1), lm(rowA, mA2)])
    cmd("marker_lane.remove", lane=rowB)
    check("a deleted row prunes its marks", sel_ids() == [mA2], str(sel_ids()))
    cmd("edit.undo")
    # A cut that moves a marker onto the other half (a NEW object) prunes it from the selection,
    # the mark of the band beside it staying selected.
    cmd("project.new")
    row = cmd("marker_lane.create", name="cut")["lane"]
    keep = cmd("marker.add", lane=row, at=0.5, name="keep")["marker"]
    co = cmd("object.add", path=FIXTURE, lane=0, start=2.0)["id"]
    cmd("wait_idle", timeout_ms=5000)
    early = cmd("object.add_marker", object=co, at=2.05, name="early")["marker"]
    late = cmd("object.add_marker", object=co, at=2.30, name="late")["marker"]
    select([lm(row, keep), {"object": co, "marker": early}, {"object": co, "marker": late}])
    cmd("object.split_at", ids=[co], seconds=2.20)
    check("a cut prunes the marks it moved to the other half, keeps the rest",
          sel_set() == {keep, early}, str(sel_ids()))

    # Loading a project starts with nothing selected.
    select([lm(row, keep)])
    cmd("project.new")
    check("a new project selects no mark", sel_ids() == [], str(sel_ids()))

    # A selection that cannot be resolved is refused, not half-applied.
    try:
        cmd("marker.select", items=[{"lane": "00000000-0000-0000-0000-000000000000",
                                     "marker": "00000000-0000-0000-0000-000000000001"}])
        check("an unknown mark is refused", False, "it went through")
    except ObjekatError as e:
        check("an unknown mark is refused", e.code == "not_found", e.code)
    try:
        cmd("marker.remove_selected")
        check("remove_selected with nothing selected is refused", False, "it went through")
    except ObjekatError as e:
        check("remove_selected with nothing selected is refused", e.code == "invalid_state", e.code)

    # ── removing TIME from the ruler carries the band's marks ──────────────
    # ⌥⌫ over a range traced in the RULER (time or BPM half) removes time: the marks of the
    # band follow the objects. The same range over every lane but traced in the TIMELINE only
    # removes matter on lanes: the marks stay. Rule = `Marker.splicedInTime` (the one an
    # object's own markers already obey): after → slides back, point inside → goes, region
    # straddling → loses the overlap.
    cmd("project.new")
    rrow = cmd("marker_lane.create", name="ripple")["lane"]
    k_before = cmd("marker.add", lane=rrow, at=1.0, name="avant")["marker"]
    k_strad = cmd("marker.add", lane=rrow, at=1.5, duration=1.0, name="chevauche")["marker"]
    k_inside = cmd("marker.add", lane=rrow, at=3.0, name="dedans")["marker"]
    k_after = cmd("marker.add", lane=rrow, at=6.0, name="apres")["marker"]
    k_region = cmd("marker.add", lane=rrow, at=7.0, duration=1.0, name="region apres")["marker"]
    ro = cmd("object.add", path=FIXTURE, lane=0, start=8.0)["id"]
    cmd("wait_idle", timeout_ms=5000)

    def band_state():
        return {m["id"]: (m["time"], m.get("duration", 0.0))
                for m in cmd("marker_lane.list")["lanes"][0]["markers"]}

    def obj_start(oid_):
        return [o for o in cmd("object.list")["objects"] if o["id"] == oid_][0]["start"]

    marks0 = band_state()

    # 1) from the ruler: the marks follow.
    cmd("timesel.set", start=2.0, end=4.0, from_ruler=True)
    res = cmd("timesel.ripple_delete")
    check("ruler ripple: reported as carrying the marks", res.get("markers_follow") is True, str(res))
    st = band_state()
    check("ruler ripple: the object after slid back", approx(obj_start(ro), 6.0), str(obj_start(ro)))
    check("ruler ripple: a mark before the range does not move",
          k_before in st and approx(st[k_before][0], 1.0), str(st.get(k_before)))
    check("ruler ripple: a mark after the range slides back by its length",
          k_after in st and approx(st[k_after][0], 4.0), str(st.get(k_after)))
    check("ruler ripple: a region after slides back whole",
          k_region in st and approx(st[k_region][0], 5.0) and approx(st[k_region][1], 1.0),
          str(st.get(k_region)))
    check("ruler ripple: a point inside the range goes", k_inside not in st, str(st.get(k_inside)))
    # [1.5, 2.5] minus [2, 4] would leave 0.5 s: a region never goes under 1 s, so it is kept at
    # 1 s from its start (Marker.minRegionDuration).
    check("ruler ripple: a straddling region trimmed under 1 s is kept at 1 s",
          k_strad in st and approx(st[k_strad][0], 1.5) and approx(st[k_strad][1], 1.0),
          str(st.get(k_strad)))

    # 2) ONE undo gives back the objects AND the marks.
    cmd("edit.undo")
    check("ruler ripple: one undo puts the marks back", band_state() == marks0, str(band_state()))
    check("ruler ripple: and the object", approx(obj_start(ro), 8.0), str(obj_start(ro)))

    # 3) the same range over every lane, traced in the TIMELINE: the marks stay.
    cmd("timesel.set", start=2.0, end=4.0, all_lanes=True)
    res = cmd("timesel.ripple_delete")
    check("lanes-only ripple: reported as NOT carrying the marks",
          res.get("markers_follow") is False, str(res))
    check("lanes-only ripple: the object still slid back", approx(obj_start(ro), 6.0),
          str(obj_start(ro)))
    check("lanes-only ripple: the band is untouched", band_state() == marks0, str(band_state()))
    cmd("edit.undo")
    check("lanes-only ripple: undo puts the object back", approx(obj_start(ro), 8.0),
          str(obj_start(ro)))

    # 4) the ruler origin does not outlive a timeline write: re-setting the range without
    #    `from_ruler` drops it.
    cmd("timesel.set", start=2.0, end=4.0, from_ruler=True)
    cmd("timesel.set", start=2.0, end=4.0, all_lanes=True)
    res = cmd("timesel.ripple_delete")
    check("a timeline write drops the ruler origin", res.get("markers_follow") is False, str(res))
    check("so the band stays put", band_state() == marks0, str(band_state()))
    cmd("edit.undo")

    # 5) tracing in the ruler lets go of the selected marks — ALWAYS: whether the range encloses
    #    an object or not (before, only an enclosed object selected carried them out).
    select([lm(rrow, k_region)])
    cmd("timesel.set", start=7.5, end=600.0, from_ruler=True, select_objects=True)
    check("a ruler range selects the object it encloses",
          ro.upper() in [i.upper() for i in cmd("selection.get").get("ids", [])],
          json.dumps(cmd("selection.get")))
    check("and lets go of the selected region", sel_ids() == [], str(sel_ids()))
    select([lm(rrow, k_region)])
    cmd("timesel.set", start=0.2, end=0.8, from_ruler=True, select_objects=True)
    check("a ruler range over no object lets go of the region too",
          sel_ids() == [] and cmd("selection.get")["count"] == 0, str(sel_ids()))
    select([lm(rrow, k_region)])
    cmd("timesel.set", start=0.2, end=0.8, from_ruler=True)
    check("timesel.set from_ruler alone lets go of the marks", sel_ids() == [], str(sel_ids()))
    cmd("timesel.clear")

    # ── a region is never shorter than 1 s (Marker.minRegionDuration) ──────
    cmd("project.new")
    frow = cmd("marker_lane.create", name="floor")["lane"]

    def band_mark(mid):
        for m in cmd("marker_lane.list")["lanes"][0]["markers"]:
            if m["id"] == mid:
                return m
        return None

    short = cmd("marker.add", lane=frow, at=2.0, duration=0.4)["marker"]
    m = band_mark(short)
    check("floor: marker.add of a 0.4 s region makes it 1 s",
          m is not None and approx(m.get("duration", 0.0), 1.0), str(m))
    big = cmd("marker.add", lane=frow, at=5.0, duration=3.0)["marker"]
    r = cmd("marker.move", lane=frow, marker=big, at=5.0, duration=0.3)
    m = band_mark(big)
    check("floor: marker.move cropping a region under 1 s keeps it at 1 s",
          m is not None and approx(m["time"], 5.0) and approx(m.get("duration", 0.0), 1.0)
          and approx(r["duration"], 1.0), str(m) + " " + json.dumps(r))
    cmd("marker.move", lane=frow, marker=big, at=5.0, duration=0)
    m = band_mark(big)
    check("floor: duration 0 still turns a region back into a point",
          m is not None and approx(m.get("duration", 0.0), 0.0), str(m))
    pt = cmd("marker.add", lane=frow, at=9.0)["marker"]
    m = band_mark(pt)
    check("floor: a point marker stays a point", m is not None and approx(m.get("duration", 0.0), 0.0),
          str(m))

    fo = cmd("object.add", path=FIXTURE, lane=0, start=0.0)["id"]
    cmd("wait_idle", timeout_ms=5000)

    def obj_mark(mid):
        for mm in cmd("object.list_markers", object=fo)["markers"]:
            if mm["id"] == mid:
                return mm
        return None

    om = cmd("object.add_marker", object=fo, rel=0.1, duration=0.2)["marker"]
    m = obj_mark(om)
    check("floor: object.add_marker of a 0.2 s region makes it 1 s",
          m is not None and approx(m.get("duration", 0.0), 1.0), str(m))
    cmd("object.move_marker", object=fo, marker=om, rel=0.1, duration=0.5)
    m = obj_mark(om)
    check("floor: object.move_marker under 1 s keeps it at 1 s",
          m is not None and approx(m.get("duration", 0.0), 1.0), str(m))

print("\nALL PASS" if not fails else "\n%d FAILURE(S): %s" % (len(fails), ", ".join(fails)))
sys.exit(0 if not fails else 1)

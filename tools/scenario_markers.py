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
    check("session format bumped", doc.get("version") == 13, str(doc.get("version")))
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

    reg = cmd("marker.add", lane=lane, at=6.03, duration=0.90)["marker"]
    got = move_to(6.02)
    check("a REGION's start catches it", abs(got - 6.03) < 1e-9, str(got))
    got = move_to(6.92)
    check("and its END too — a region is two targets, not one",
          abs(got - 6.93) < 1e-9, str(got))

    move_to(1.0)                                    # out of its own way first
    cmd("marker_lane.set_visible", lane=lane, visible=False)
    got = move_to(6.92)
    check("a HIDDEN row catches nothing: what one cannot see must not pull",
          abs(got - 7.0) < 1e-9, str(got))
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

print("\nALL PASS" if not fails else "\n%d FAILURE(S): %s" % (len(fails), ", ".join(fails)))
sys.exit(0 if not fails else 1)

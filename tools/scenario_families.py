#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""A smoke scenario over the command families (increment 5).

What this file brings over `tools/smoke.jsonl`: a JSON-lines scenario cannot
REUSE an identifier returned by an earlier command. Yet almost everything here depends on that
(grouping the object just added, sending to the aux just created). Hence a Python
driver, which chains the commands while keeping the identifiers to hand.

    # 1. launch the app with the API, on a SHORT socket (a system limit: 103 bytes).
    #    `--no-recent`: the throwaway project created below does not enter "Recent projects".
    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --socket=/tmp/o.sock

    # 2. replay the scenario
    ./scenario_families.py /tmp/o.sock /tmp/trial/project.objekat.json

The second argument is the project path to create: sound objects require a project
folder (samples/objects/). Exit: 0 if everything passes, 1 as soon as one command fails.
"""

import sys, os, json

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

if len(sys.argv) != 3:
    print(__doc__)
    sys.exit(2)

SOCK = sys.argv[1]
PROJ = sys.argv[2]
BIP  = os.path.join(HERE, "fixtures", "bip.wav")

ok, ko = 0, 0
def step(label, fn):
    global ok, ko
    try:
        r = fn()
        ok += 1
        print("  OK   %-28s %s" % (label, json.dumps(r, ensure_ascii=False)[:150]))
        return r
    except ObjekatError as e:
        ko += 1
        print("  FAIL %-28s %s" % (label, e.args[0]))
        return None

def check(label, cond, detail=""):
    """An assertion on what a command ANSWERED, not merely on its answering."""
    global ok, ko
    if cond:
        ok += 1
        print("  OK   %-28s" % label)
    else:
        ko += 1
        print("  FAIL %-28s %s" % (label, detail))

with ObjekatClient(SOCK) as c:
    n = len(c.send("help")["commands"])
    print("commands registered:", n)

    c.send("app.set_dialog_policy", {"policy": "assume_yes"})
    c.send("project.new")
    c.send("project.save_as", {"path": PROJ})

    a = step("object.add A",  lambda: c.send("object.add", {"path": BIP, "lane": 0, "start": 0}))
    b = step("object.add B",  lambda: c.send("object.add", {"path": BIP, "lane": 1, "start": 0}))
    ida, idb = a["id"], b["id"]

    # --- object attributes
    step("object.get",        lambda: c.send("object.get", {"id": ida}))
    step("object.rename",     lambda: c.send("object.rename", {"id": ida, "name": "Bip A"}))
    step("object.set_fade",   lambda: c.send("object.set_fade", {"id": ida, "in": 0.05, "out": 0.1}))
    step("object.set_speed",  lambda: c.send("object.set_speed", {"id": ida, "ratio": 2.0}))
    step("object.set_reversed", lambda: c.send("object.set_reversed", {"id": ida}))
    step("object.set_pan",    lambda: c.send("object.set_pan", {"ids": [ida], "pan": -0.5}))
    step("object.set_mute",   lambda: c.send("object.set_mute", {"ids": [idb], "muted": True}))
    step("object.set_duration", lambda: c.send("object.set_duration", {"id": idb, "duration": 0.3}))
    step("object.trim",       lambda: c.send("object.trim", {"id": idb, "start": 0.1, "duration": 0.2}))
    step("object.set_source_offset", lambda: c.send("object.set_source_offset", {"id": idb, "offset": 0.01}))

    # --- pan: every gesture clicks onto the tenths, for one object and for several
    c.send("project.set_snap", {"enabled": True})
    c.send("object.set_pan", {"ids": [ida], "pan": 0.0})
    r = step("object.adjust_pan one object", lambda: c.send("object.adjust_pan", {"by": 0.13, "ids": [ida]}))
    check("one object: it lands on the tenth",
          r and abs(r["pans"][0] - 0.1) < 1e-6, str(r and r["pans"]))
    # The detent is UNCONDITIONAL: the grid's snap is about time, and turning it off must not leave
    # the pan continuous (which is exactly the regression reported on 15 September 2026).
    c.send("project.set_snap", {"enabled": False})
    c.send("object.set_pan", {"ids": [ida], "pan": 0.0})
    r = step("object.adjust_pan, snap off", lambda: c.send("object.adjust_pan", {"by": 0.13, "ids": [ida]}))
    check("the snap off changes nothing: still the tenth",
          r and abs(r["pans"][0] - 0.1) < 1e-6, str(r and r["pans"]))
    # object.set_pan is the machine's door and stays exact — the detent belongs to the hand.
    r = step("object.set_pan is exact", lambda: c.send("object.set_pan", {"ids": [ida], "pan": 0.37}))
    check("object.set_pan writes the value as given",
          abs(c.send("object.get", {"id": ida})["pan"] - 0.37) < 1e-6)
    c.send("project.set_snap", {"enabled": True})
    c.send("object.set_pan", {"ids": [ida], "pan": 0.0})
    c.send("object.set_pan", {"ids": [idb], "pan": 0.5})
    r = step("object.adjust_pan two objects", lambda: c.send("object.adjust_pan", {"by": 0.13, "ids": [ida, idb]}))
    check("several objects click onto the tenths too",
          r and sorted(round(v, 4) for v in r["pans"]) == [0.1, 0.6], str(r and r["pans"]))
    # The ±0.1 arrows go down the same path, and they are what the detent must not disturb: ten
    # presses walk the whole half-range and land on 1, with none of the float dust a chain of
    # additions leaves behind. (What CANNOT be asserted from here is the drag itself: a gesture
    # holds ONE anchor for its whole length and hands over its total travel, whereas each call of
    # this command takes a fresh anchor — that invariant lives in the gesture, and only the hand
    # can see it.)
    c.send("object.set_pan", {"ids": [ida], "pan": 0.0})
    for _ in range(10):
        r = c.send("object.adjust_pan", {"by": 0.1, "ids": [ida]})
    check("ten steps of a tenth land exactly on the edge, with no float dust",
          abs(r["pans"][0] - 1.0) < 1e-6, str(r["pans"]))
    c.send("object.set_pan", {"ids": [ida, idb], "pan": 0.0})

    # --- the END goes, the fade-out stays: its START is anchored and it simply ends earlier
    #     (16 September 2026). Three doors, one rule — the crop, a time selection deleted off the
    #     tail, and the cut that keeps the left. Lengths are taken as fractions of the fixture's
    #     own duration, so the assertions hold whatever bip.wav lasts.
    fo = step("object.add fade", lambda: c.send("object.add", {"path": BIP, "lane": 10, "start": 0}))
    idf = fo["id"]
    D = c.send("object.get", {"id": idf})["duration"]
    c.send("object.set_fade", {"id": idf, "in": 0, "out": 0.4 * D})
    step("object.set_duration crops", lambda: c.send("object.set_duration", {"id": idf, "duration": 0.8 * D}))
    g = c.send("object.get", {"id": idf})
    # The fade began at 0.6·D and still does: 0.8·D − 0.6·D is left of it.
    check("cropping the end keeps the fade, ending earlier",
          abs(g["fade_out"] - 0.2 * D) < 1e-6, "fade_out=%s, expected %s" % (g["fade_out"], 0.2 * D))
    step("object.set_duration lengthens", lambda: c.send("object.set_duration", {"id": idf, "duration": 0.9 * D}))
    check("pulling the end back OUT leaves the fade alone — it follows the edge",
          abs(c.send("object.get", {"id": idf})["fade_out"] - 0.2 * D) < 1e-6)
    step("object.set_duration past the fade", lambda: c.send("object.set_duration", {"id": idf, "duration": 0.5 * D}))
    check("a crop PAST the fade's own start leaves no fade at all",
          abs(c.send("object.get", {"id": idf})["fade_out"]) < 1e-9)

    ft = step("object.add fade tail", lambda: c.send("object.add", {"path": BIP, "lane": 11, "start": 0}))
    idt = ft["id"]
    c.send("object.set_fade", {"id": idt, "in": 0, "out": 0.4 * D})
    c.send("timesel.set", {"start": 0.8 * D, "end": 2 * D, "lane": 11})
    step("timesel.delete the tail", lambda: c.send("timesel.delete"))
    g = c.send("object.get", {"id": idt})
    check("a selection deleted off the tail keeps the fade too",
          abs(g["duration"] - 0.8 * D) < 1e-6 and abs(g["fade_out"] - 0.2 * D) < 1e-6, str(g))
    c.send("timesel.clear")

    fc = step("object.add fade cut", lambda: c.send("object.add", {"path": BIP, "lane": 12, "start": 0}))
    idc = fc["id"]
    c.send("object.set_fade", {"id": idc, "in": 0, "out": 0.4 * D})
    step("ripple_cut keeping the left", lambda: c.send("object.ripple_cut",
         {"id": idc, "seconds": 0.8 * D, "keep": "left"}))
    g = c.send("object.get", {"id": idc})
    check("keeping the left half is deleting the end, so the fade stays",
          abs(g["fade_out"] - 0.2 * D) < 1e-6, str(g))
    # A plain SPLIT is not that: there the fade goes with the right-hand piece, which is the half
    # that still ends where it ended.
    fs = step("object.add split", lambda: c.send("object.add", {"path": BIP, "lane": 13, "start": 0}))
    ids_ = fs["id"]
    c.send("object.set_fade", {"id": ids_, "in": 0, "out": 0.4 * D})
    halves = step("object.split_at", lambda: c.send("object.split_at", {"ids": [ids_], "seconds": 0.8 * D}))
    check("a split leaves the left half without a fade-out",
          abs(c.send("object.get", {"id": ids_})["fade_out"]) < 1e-9)
    # Every fixture goes, the split's right-hand half included: the rows they occupy are the
    # timeline's LAST, and one left behind would move the floor the arrow assertions below stop at.
    step("remove the fade fixtures",
         lambda: c.send("object.remove", {"ids": [idf, idt, idc] + (halves["ids"] if halves else [ids_])}))
    c.send("selection.clear")

    # --- the time selection slides across the rows (the bare arrows), moving nothing
    c.send("timesel.set", {"start": 0, "end": 1, "lane": 0, "lane_count": 2})
    before = c.send("object.get", {"id": ida})
    r = step("timesel.step_lane \u2193", lambda: c.send("timesel.step_lane", {"by": 1}))
    ts = r and r["time_selection"]
    check("\u2193 slides the passage one row down, its height and its span kept",
          ts and ts["lanes"] == [1, 2] and ts["start"] == 0 and ts["end"] == 1, str(ts))
    r = step("timesel.step_lane \u2193 again", lambda: c.send("timesel.step_lane", {"by": 1}))
    check("at the last row the timeline draws it stops, keeping the selection",
          r and r["moved"] is False and r["time_selection"]["lanes"] == [1, 2], str(r))
    r = step("timesel.step_lane \u2191", lambda: c.send("timesel.step_lane", {"by": -1}))
    check("\u2191 brings it back up", r and r["time_selection"]["lanes"] == [0, 1],
          str(r and r["time_selection"]))
    r = step("timesel.step_lane \u2191 at the top", lambda: c.send("timesel.step_lane", {"by": -1}))
    check("row 0 stops it too, and does not clip the selection",
          r and r["moved"] is False and r["time_selection"]["lanes"] == [0, 1], str(r))
    after = c.send("object.get", {"id": ida})
    check("and NOT ONE object moved — it is the frame that travels",
          after["lane"] == before["lane"] and after["start"] == before["start"],
          "%s → %s" % (before, after))
    c.send("timesel.clear")

    # --- the same arrows with OBJECTS selected and no range traced: the frame they FILL is
    #     adopted and travels, and the objects are let go of as it leaves them.
    c.send("selection.set", {"ids": [ida]})
    ga = c.send("object.get", {"id": ida})       # A is on row 0: ↑ has nowhere to go
    r = step("timesel.step_lane ↑ object", lambda: c.send("timesel.step_lane", {"by": -1}))
    check("at row 0 a press changes NOTHING, the object selection included",
          r and r["moved"] is False and r["count"] == 1 and "time_selection" not in r, str(r))
    r = step("timesel.step_lane ↓ object", lambda: c.send("timesel.step_lane", {"by": 1}))
    ts = r and r.get("time_selection")
    check("an object selection is read as the frame it fills, one row lower",
          ts and ts["lanes"] == [ga["display_lane"] + 1]
          and abs(ts["start"] - ga["start"]) < 1e-9
          and abs(ts["end"] - (ga["start"] + ga["duration"])) < 1e-9,
          "%s from %s" % (ts, ga))
    check("and the objects are let go of — the frame has left them", r and r["count"] == 0, str(r))
    moved = c.send("object.get", {"id": ida})
    check("the object itself has not budged",
          moved["lane"] == ga["lane"] and abs(moved["start"] - ga["start"]) < 1e-9,
          "%s → %s" % (ga, moved))
    c.send("timesel.clear")
    c.send("selection.clear")

    # --- an infinite bus changes row: an empty one takes it, another bus swaps with it, a row
    #     holding matter refuses it (a full-width band would cover whatever is there).
    x1 = step("aux.create bus 1",  lambda: c.send("aux.create", {"start": 0, "end": 1, "lane": 4}))
    x2 = step("aux.create bus 2",  lambda: c.send("aux.create", {"start": 0, "end": 1, "lane": 6}))
    id1, id2 = x1["id"], x2["id"]
    step("object.set_infinite 1",  lambda: c.send("object.set_infinite", {"id": id1, "on": True}))
    r = step("object.set_infinite 2", lambda: c.send("object.set_infinite", {"id": id2, "on": True}))
    check("object.get reports the infinite", c.send("object.get", {"id": id1})["infinite"] is True)
    l2 = c.send("object.get", {"id": id2})["lane"]

    r = step("object.move bus, empty row", lambda: c.send("object.move", {"id": id1, "lane": 12}))
    check("an empty row simply takes it", r and r["lane"] == 12, str(r))
    r = step("object.move bus onto bus",  lambda: c.send("object.move", {"id": id1, "lane": l2}))
    check("a row holding ONE other infinite bus swaps with it",
          r and r["lane"] == l2 and c.send("object.get", {"id": id2})["lane"] == 12,
          "%s / bus 2 on %s" % (r, c.send("object.get", {"id": id2})["lane"]))
    try:
        c.send("object.move", {"id": id1, "lane": 0})   # row 0 carries object A
        check("a row holding matter refuses the band", False, "it went through")
    except ObjekatError as e:
        check("a row holding matter refuses the band", e.code == "invalid_state", e.code)
    check("and the refusal moved NOTHING",
          c.send("object.get", {"id": id1})["lane"] == l2
          and c.send("object.get", {"id": ida})["lane"] == 0)
    # The two buses go away again: the rest of the scenario lays its own auxes on these rows, and
    # a band left lying about would be one more sender in every `aux.list` below.
    step("object.remove buses", lambda: c.send("object.remove", {"ids": [id1, id2]}))
    c.send("selection.clear")

    # --- stems
    s = step("stem.add",      lambda: c.send("stem.add", {"name": "Voice", "format": "mono"}))
    sid = s["id"]
    step("stem.list",         lambda: c.send("stem.list"))
    step("stem.assign",       lambda: c.send("stem.assign", {"stem": sid, "ids": [ida]}))
    step("stem.set_gain",     lambda: c.send("stem.set_gain", {"id": sid, "db": -3}))
    step("stem.mute",         lambda: c.send("stem.mute", {"id": sid, "muted": True}))
    step("stem.mute off",     lambda: c.send("stem.mute", {"id": sid, "muted": False}))
    step("stem.route_to_main", lambda: c.send("stem.route_to_main", {"id": sid, "on": False}))
    step("stem.rename",       lambda: c.send("stem.rename", {"id": sid, "name": "Lead voice"}))
    step("stem.recolor",      lambda: c.send("stem.recolor", {"id": sid, "color_index": 5}))
    step("stem.level",        lambda: c.send("stem.level"))

    # --- groups
    g = step("group.create",  lambda: c.send("group.create", {"ids": [ida, idb]}))
    gid = g["id"]
    step("group.expand",      lambda: c.send("group.expand", {"id": gid, "expanded": True}))
    step("group.eject",       lambda: c.send("group.eject", {"ids": [ida], "lane": 3}))
    step("group.reparent",    lambda: c.send("group.reparent", {"ids": [ida], "group": gid}))
    step("group.disband",     lambda: c.send("group.disband", {"id": gid}))

    # --- time selection + aux + sends
    step("timesel.set",       lambda: c.send("timesel.set", {"start": 0, "end": 2, "lane": 5}))
    aux = step("aux.create",  lambda: c.send("aux.create", {"start": 0, "end": 2, "lane": 5}))
    step("aux.list",          lambda: c.send("aux.list"))
    if aux:
        step("send.set_level", lambda: c.send("send.set_level", {"id": ida, "aux": aux["id"], "db": -6}))
        step("send.enable",   lambda: c.send("send.enable", {"id": ida, "aux": aux["id"], "enabled": False}))
        step("send.list",     lambda: c.send("send.list", {"id": ida}))

    # --- MIDI
    m = step("midi.create_clip", lambda: c.send("midi.create_clip", {"start": 4, "end": 6, "lane": 6}))
    if m:
        mid = m["id"]
        note = step("midi.add_note", lambda: c.send("midi.add_note",
                    {"id": mid, "pitch": 60, "start_beat": 0, "length_beats": 1}))
        step("midi.list_notes", lambda: c.send("midi.list_notes", {"id": mid}))
        if note:
            nid = note["note"]["id"]
            step("midi.update_note", lambda: c.send("midi.update_note",
                 {"id": mid, "note_id": nid, "velocity": 80, "pitch": 64}))
            step("midi.transpose", lambda: c.send("midi.transpose",
                 {"semitones": 12, "note_ids": [nid]}))
            step("midi.delete_notes", lambda: c.send("midi.delete_notes",
                 {"id": mid, "note_ids": [nid]}))

    # --- plugins (a cached catalogue, no scan)
    av = step("plugin.list_available", lambda: c.send("plugin.list_available"))
    if av and av["count"]:
        name = av["plugins"][0]["identifier"]
        added = step("plugin.add", lambda: c.send("plugin.add", {"host": ida, "identifier": name}))
        step("plugin.list",   lambda: c.send("plugin.list", {"host": ida}))
        if added:
            pid = added["plugin"]["id"]
            step("plugin.get_params", lambda: c.send("plugin.get_params", {"plugin": pid}))
            step("plugin.toggle", lambda: c.send("plugin.toggle", {"host": ida, "plugin": pid}))
            step("plugin.copy",  lambda: c.send("plugin.copy", {"from": ida, "plugin": pid, "to": sid}))
            step("plugin.remove", lambda: c.send("plugin.remove", {"host": ida, "plugin": pid}))
    else:
        print("  (empty plugin catalogue — the plugin family is not exercised)")

    # --- clipboard
    step("selection.set",     lambda: c.send("selection.set", {"ids": [ida]}))
    step("clipboard.copy",    lambda: c.send("clipboard.copy"))
    step("clipboard.paste",   lambda: c.send("clipboard.paste"))
    step("timesel.set 2",     lambda: c.send("timesel.set", {"start": 0, "end": 1, "lanes": [0, 1]}))
    step("timesel.copy",      lambda: c.send("timesel.copy"))
    step("timesel.delete",    lambda: c.send("timesel.delete"))
    step("edit.undo",         lambda: c.send("edit.undo"))

    # --- sound objects (an asynchronous bake)
    step("selection.set B",   lambda: c.send("selection.set", {"ids": [idb]}))
    sh = step("definition.make",  lambda: c.send("definition.make", {"id": idb}))
    if sh:
        step("job.wait",      lambda: c.send("job.wait", {"id": sh["job_id"], "timeout_ms": 30000}))
        lst = step("definition.list", lambda: c.send("definition.list"))
        if lst and lst["count"]:
            pl = lst["definitions"][0]["placements"]
            if pl:
                step("definition.edit_begin", lambda: c.send("definition.edit_begin", {"placement": pl[0]}))
                step("definition.state",  lambda: c.send("definition.state"))
                step("definition.edit_cancel", lambda: c.send("definition.edit_cancel"))
                step("definition.detach", lambda: c.send("definition.detach", {"placement": pl[0]}))

    # --- the format notice and export (an asynchronous render)
    step("project.schema",    lambda: c.send("project.schema"))
    # One export at a time (the API refuses the second): every render is waited for.
    def render(label, params):
        r = step(label, lambda: c.send("export.run", params))
        if r:
            step("  job.wait", lambda: c.send("job.wait", {"id": r["job_id"], "timeout_ms": 60000}))
        return r

    out = lambda n: os.path.join(os.path.dirname(PROJ), n)
    render("export.run", {})
    step("export.status",     lambda: c.send("export.status"))
    render("export.run range", {"format": "wav", "sample_rate": 48000,
                                "start": 0.0, "end": 0.5, "path": out("range.wav")})
    # Musical times + laying the markers, then rendering the IN/OUT zone thus laid.
    render("export.run bars", {"format": "wav", "set_markers": True,
                               "start": "1:1:0", "end": "2:1:0", "path": out("bars.wav")})
    render("export.run inout", {"format": "wav", "range": "inout", "path": out("io.wav")})

    step("wait_idle",         lambda: c.send("wait_idle", {"timeout_ms": 10000}))
    step("perf.census",       lambda: c.send("perf.census"))
    step("app.dialogs",       lambda: c.send("app.dialogs"))

print("\n=== %d OK, %d FAILED ===" % (ok, ko))
sys.exit(1 if ko else 0)

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

    # --- TWO GESTURES, told apart (21 September 2026). The hand on the edge HANDLE — the crop,
    #     the trim, `object.resize` / `object.trim` — does not change the SIZE of a fade: the fade
    #     travels with the edge it is anchored to. Matter REMOVED — a time selection deleted, the
    #     cut that keeps the left — shortens the fade by exactly what went, its start (or its end)
    #     staying opposite the same material. Lengths are taken as fractions of the fixture's own
    #     duration, so the assertions hold whatever bip.wav lasts.
    fo = step("object.add fade", lambda: c.send("object.add", {"path": BIP, "lane": 10, "start": 0}))
    idf = fo["id"]
    D = c.send("object.get", {"id": idf})["duration"]
    c.send("object.set_fade", {"id": idf, "in": 0, "out": 0.4 * D})
    step("object.set_duration crops", lambda: c.send("object.set_duration", {"id": idf, "duration": 0.8 * D}))
    g = c.send("object.get", {"id": idf})
    check("cropping the end keeps the fade's SIZE — it follows the edge",
          abs(g["fade_out"] - 0.4 * D) < 1e-6, "fade_out=%s, expected %s" % (g["fade_out"], 0.4 * D))
    step("object.set_duration lengthens", lambda: c.send("object.set_duration", {"id": idf, "duration": 0.9 * D}))
    check("pulling the end back OUT leaves the fade alone too",
          abs(c.send("object.get", {"id": idf})["fade_out"] - 0.4 * D) < 1e-6)
    step("object.set_duration under the fade", lambda: c.send("object.set_duration", {"id": idf, "duration": 0.3 * D}))
    check("cropped SHORTER than its fade, the object clamps — a physical limit, not the rule",
          abs(c.send("object.get", {"id": idf})["fade_out"] - 0.3 * D) < 1e-6)

    # The left edge under the same hand: the fade-in keeps its size against the new start, which
    # is the fade-out's mirror just above. This is what tells `object.trim` from a deletion.
    tr = step("object.add trim", lambda: c.send("object.add", {"path": BIP, "lane": 14, "start": 0}))
    idtr = tr["id"]
    c.send("object.set_fade", {"id": idtr, "in": 0.2 * D, "out": 0.2 * D})
    step("object.trim moves the start in",
         lambda: c.send("object.trim", {"id": idtr, "start": 0.2 * D, "duration": 0.6 * D}))
    g = c.send("object.get", {"id": idtr})
    check("trimming the start keeps BOTH fades' size",
          abs(g["fade_in"] - 0.2 * D) < 1e-6 and abs(g["fade_out"] - 0.2 * D) < 1e-6, str(g))

    # And the other gesture on the same edge: matter taken off the head shortens the fade-in by
    # exactly what went, instead of leaving it whole or clearing it.
    hd = step("object.add fade head", lambda: c.send("object.add", {"path": BIP, "lane": 15, "start": 0}))
    idhd = hd["id"]
    c.send("object.set_fade", {"id": idhd, "in": 0.4 * D, "out": 0})
    c.send("timesel.set", {"start": 0, "end": 0.2 * D, "lane": 15})
    step("timesel.delete the head", lambda: c.send("timesel.delete"))
    g = c.send("object.get", {"id": idhd})
    check("a selection deleted off the head SHORTENS the fade-in by what went",
          abs(g["fade_in"] - 0.2 * D) < 1e-6 and abs(g["duration"] - 0.8 * D) < 1e-6, str(g))
    c.send("timesel.clear")

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
    c.send("object.set_fade_curve", {"id": idc, "out": "convex", "out_bend": 0.5})
    step("ripple_cut keeping the left", lambda: c.send("object.ripple_cut",
         {"id": idc, "seconds": 0.8 * D, "keep": "left"}))
    g = c.send("object.get", {"id": idc})
    check("keeping the left half is deleting the end, so the fade stays",
          abs(g["fade_out"] - 0.2 * D) < 1e-6, str(g))
    check("…and its SHAPE stays with it: a shortened fade is the same curve with less room",
          g["fade_out_curve"] == "convex" and abs(g["fade_out_bend"] - 0.5) < 1e-9, str(g))
    # A plain SPLIT is not that: there the fade goes with the right-hand piece, which is the half
    # that still ends where it ended.
    fs = step("object.add split", lambda: c.send("object.add", {"path": BIP, "lane": 13, "start": 0}))
    ids_ = fs["id"]
    c.send("object.set_fade", {"id": ids_, "in": 0.2 * D, "out": 0.4 * D})
    # Both edges BENT before the cut: what the two halves do with the shapes is the whole
    # question (21 September 2026). A shape left on the fade of no length the cut opens does not
    # show — it lies in wait and comes out the first time that edge is pulled.
    c.send("object.set_fade_curve", {"id": ids_, "in": "concave", "in_bend": 0.5,
                                     "out": "convex", "out_bend": 0.75})
    halves = step("object.split_at", lambda: c.send("object.split_at", {"ids": [ids_], "seconds": 0.8 * D}))
    check("a split leaves the left half without a fade-out",
          abs(c.send("object.get", {"id": ids_})["fade_out"]) < 1e-9)
    gl = c.send("object.get", {"id": ids_})
    gr = c.send("object.get", {"id": [i for i in halves["ids"] if i != ids_][0]})
    check("the edge the cut OPENED starts straight, on either half",
          gl["fade_out_curve"] == "linear" and abs(gl["fade_out_bend"]) < 1e-9
          and gr["fade_in_curve"] == "linear" and abs(gr["fade_in_bend"]) < 1e-9,
          "left=%s/%s right=%s/%s" % (gl["fade_out_curve"], gl["fade_out_bend"],
                                      gr["fade_in_curve"], gr["fade_in_bend"]))
    check("and each half keeps the edge it already had, shape included",
          gl["fade_in_curve"] == "concave" and abs(gl["fade_in_bend"] - 0.5) < 1e-9
          and abs(gl["fade_in"] - 0.2 * D) < 1e-6
          # 0.4 D of fade on a half 0.2 D long: the length clamps to the room left, the shape does not.
          and gr["fade_out_curve"] == "convex" and abs(gr["fade_out_bend"] - 0.75) < 1e-9
          and abs(gr["fade_out"] - 0.2 * D) < 1e-6,
          "left=%s right=%s" % (gl, gr))
    # --- WHERE a crossfade's zone is taken FROM. `crossfade.open` on its own centres the zone on
    #     the join, both edges giving half: nothing there says which of two alike objects should
    #     give, so the join is the only landmark. A fade PULLED onto its neighbour is not that
    #     gesture — the fade drawn is the source and the facing one its consequence, so the zone is
    #     anchored on the NEIGHBOUR's own edge and the whole travel happens on the pulled side.
    #     Both readings go through this one command (`start` = the wish, clamped like the width),
    #     which is what lets the difference be asserted with no hand on the screen.
    #     The two fixtures are trimmed on purpose: opening a seam re-exposes hidden matter, so a
    #     pair of untouched clips has nothing to give and the zone could not open at all.
    xa = step("object.add crossfade left", lambda: c.send("object.add", {"path": BIP, "lane": 16, "start": 0}))
    xb = step("object.add crossfade right", lambda: c.send("object.add", {"path": BIP, "lane": 16, "start": D}))
    idxa, idxb = xa["id"], xb["id"]
    c.send("object.set_duration", {"id": idxa, "duration": 0.5 * D})   # 0.5 D of file left behind its end
    c.send("object.trim", {"id": idxb, "start": 1.2 * D, "duration": 0.6 * D})  # 0.2 D behind its start
    c.send("object.move", {"id": idxb, "start": 0.5 * D})              # butted against the left one
    step("crossfade.open centred", lambda: c.send("crossfade.open",
         {"left": idxa, "right": idxb, "width": 0.25 * D}))
    g = c.send("object.get", {"id": idxb})
    check("told only a width, the zone is shared out — the neighbour backs up by half of it",
          abs(g["start"] - 0.375 * D) < 1e-6, "start=%s, expected %s" % (g["start"], 0.375 * D))
    c.send("crossfade.close", {"left": idxa, "right": idxb})
    step("crossfade.open from the neighbour's edge", lambda: c.send("crossfade.open",
         {"left": idxa, "right": idxb, "width": 0.25 * D, "start": 0.5 * D}))
    gb = c.send("object.get", {"id": idxb})
    ga = c.send("object.get", {"id": idxa})
    check("anchored on the neighbour's edge, it does not move and the pulled side travels alone",
          abs(gb["start"] - 0.5 * D) < 1e-6
          and abs(ga["start"] + ga["duration"] - 0.75 * D) < 1e-6
          and abs(ga["fade_out"] - 0.25 * D) < 1e-6 and abs(gb["fade_in"] - 0.25 * D) < 1e-6,
          "left=%s right=%s" % (ga, gb))
    # And the two facing SHAPES stay each edge's own through it: the zone commands the LENGTH and
    # nothing else, which is what lets the created fade be the MIRROR of the one that was drawn
    # (`a^p` and `a^(1/p)`, reflected through the diagonal) instead of a copy of it.
    c.send("object.set_fade_curve", {"id": idxa, "out": "convex", "out_bend": 0.5})
    c.send("object.set_fade_curve", {"id": idxb, "in": "concave", "in_bend": 0.5})
    c.send("crossfade.open", {"left": idxa, "right": idxb, "width": 0.25 * D, "start": 0.5 * D})
    ga = c.send("object.get", {"id": idxa})
    gb = c.send("object.get", {"id": idxb})
    check("a bulged fade and its hollowed mirror survive the zone being laid again",
          ga["fade_out_curve"] == "convex" and abs(ga["fade_out_bend"] - 0.5) < 1e-9
          and gb["fade_in_curve"] == "concave" and abs(gb["fade_in_bend"] - 0.5) < 1e-9,
          "left=%s right=%s" % (ga["fade_out_curve"], gb["fade_in_curve"]))

    # Every fixture goes, the split's right-hand half included: the rows they occupy are the
    # timeline's LAST, and one left behind would move the floor the arrow assertions below stop at.
    step("remove the fade fixtures",
         lambda: c.send("object.remove", {"ids": [idf, idtr, idhd, idt, idc, idxa, idxb]
                                                 + (halves["ids"] if halves else [ids_])}))
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

    # --- with NOTHING selected the arrows are not idle either: a plain click lays a CARET, and it
    #     is that point of insertion which then walks the rows (same floor, same ceiling, no undo).
    r = step("caret.set row 1", lambda: c.send("caret.set", {"lane": 1, "time": 0.25}))
    check("a caret is laid where the click was, the selections let go of",
          r and r.get("caret", {}).get("lane") == 1 and r["count"] == 0
          and "time_selection" not in r, str(r))
    r = step("caret.step_lane ↓", lambda: c.send("caret.step_lane", {"by": 1}))
    check("↓ walks the caret one row down, its instant kept",
          r and r["moved"] is True and r["caret"]["lane"] == 2
          and abs(r["caret"]["time"] - 0.25) < 1e-9, str(r))
    r = step("caret.step_lane ↓ at the floor", lambda: c.send("caret.step_lane", {"by": 1}))
    check("the last row the timeline draws stops it, and the caret is kept",
          r and r["moved"] is False and r["caret"]["lane"] == 2, str(r))
    r = step("caret.step_lane ↑ ×3", lambda: c.send("caret.step_lane", {"by": -3}))
    check("row 0 stops it going up, without losing the caret",
          r and r["caret"]["lane"] == 0, str(r))
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
        sl = step("send.list", lambda: c.send("send.list", {"id": ida}))
        # `automated` says whether a CURVE drives the level. Nothing has laid one here, so it
        # answers false — what this asserts is that the key EXISTS and that a free send is not
        # reported locked. The lock itself is NOT reachable from a script: the command API has no
        # door onto the automations at all (no `automation.*` family), so nothing headless can lay
        # the point that would close it. @see CLAUDE.md, the debt of 16 September 2026.
        send0 = sl and sl["sends"][0]
        check("send.list says whether a curve holds the level",
              send0 is not None and send0.get("automated") is False, str(send0))
        # The hand's own door: relative, over the SELECTION, and it names what it left alone.
        c.send("send.enable", {"id": ida, "aux": aux["id"], "enabled": True})
        c.send("send.set_level", {"id": ida, "aux": aux["id"], "db": -6})
        r = step("send.adjust_level", lambda: c.send("send.adjust_level",
                 {"aux": aux["id"], "db": 3, "ids": [ida]}))
        check("a free send follows the hand, and is not among the locked",
              r and r["count"] == 1 and r["locked"] == [], str(r))
        check("and the level really moved",
              abs(c.send("send.list", {"id": ida})["sends"][0]["level_db"] + 3) < 1e-4,
              str(c.send("send.list", {"id": ida})["sends"][0]["level_db"]))

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

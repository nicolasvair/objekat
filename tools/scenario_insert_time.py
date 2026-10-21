#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Insert time — a scenario that ASSERTS: the blank opened from a time-ruler selection.

    # 1. launch the app with the API, on a SHORT socket (a system limit: 103 bytes).
    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --socket=/tmp/o.sock

    # 2. replay
    ./scenario_insert_time.py /tmp/o.sock

What it is out to prove: the gesture `timesel.insert_time` (the ruler's "Insert time" entry) opens
a blank the length of the time selection AT ITS START and carries what follows:
  - the objects after it slide, an object straddling the instant is CUT there (a group in depth,
    a MIDI clip too), the cut halves keep their source and their edge fades;
  - an infinite bus is neither cut nor moved, its finite children slide;
  - the marker band, the timeline's comments follow ONLY when the range was traced in the ruler
    (`markers_follow`), the loop is covered by a pure test (no door onto it headless);
  - one undo gives everything back, the selection stays on the blank and the caret goes to its start;
  - a range with nothing after it, a consolidated object open for editing: refused, no undo step;
  - and the ripple delete (⌥⌫) now slides the comments back too.

Exit: 0 if every assertion passes, 1 otherwise.
"""

import json, math, os, struct, sys, tempfile, wave

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


def approx(a, b, eps=1e-6):
    return abs(a - b) < eps


def refused(fn, label, code="invalid_state"):
    try:
        fn()
        check(label, False, "it went through")
    except ObjekatError as e:
        check(label, e.code == code, "%s: %s" % (e.code, e.message))


ROOT = tempfile.mkdtemp(prefix="ins_")
TONE = os.path.join(ROOT, "tone10.wav")      # 10 s of 220 Hz: long enough for any cut below
with wave.open(TONE, "wb") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(44100)
    w.writeframes(b"".join(struct.pack("<h", int(8000 * math.sin(2 * math.pi * 220 * n / 44100)))
                           for n in range(44100 * 10)))


with ObjekatClient(SOCK) as c:
    def cmd(_cmd_name, **params):
        return c.send(_cmd_name, params or None)

    info = cmd("app.info")
    check("--no-recent honoured", info.get("records_recent_projects") is False,
          str(info.get("records_recent_projects")))

    def objs():
        return {o["id"]: o for o in cmd("object.list")["objects"]}

    def starts(ids):
        o = objs()
        return [round(o[i]["start"], 6) for i in ids]

    def band(lane):
        for l in cmd("marker_lane.list")["lanes"]:
            if l["id"] == lane:
                return {m["id"]: (round(m["time"], 6), round(m.get("duration", 0.0), 6))
                        for m in l["markers"]}
        return {}

    def comment_starts(ids):
        d = {x["id"]: x for x in cmd("comment.list")["comments"]}
        return [round(d[i]["start"], 6) if i in d else None for i in ids]

    def add(start, dur, lane, **kw):
        return cmd("object.add", path=TONE, lane=lane, start=start, duration=dur, **kw)["id"]

    # ── 1. the plain case: three objects, a ruler range, the ones after slide ────────────────
    cmd("project.new")
    o1 = add(0.0, 2.0, 0)
    o2 = add(5.0, 2.0, 1)
    o3 = add(10.0, 2.0, 2)
    cmd("wait_idle", timeout_ms=5000)
    cmd("timesel.set", start=4.0, end=6.0, from_ruler=True)
    res = cmd("timesel.insert_time")
    check("1: reports the length opened", approx(res["inserted"], 2.0), str(res))
    check("1: nothing was cut", res["cut_count"] == 0, str(res))
    check("1: two objects slid", res["shifted_count"] == 2, str(res))
    check("1: a ruler range carries the marks", res["markers_follow"] is True, str(res))
    check("1: no container at the top level", res["container"] is None, str(res))
    check("1: 0 / 5 / 10 became 0 / 7 / 12", starts([o1, o2, o3]) == [0.0, 7.0, 12.0],
          str(starts([o1, o2, o3])))
    sel = cmd("selection.get")
    ts = sel.get("time_selection") or {}
    check("1: the selection stays on the blank (same range)",
          approx(ts.get("start", -1), 4.0) and approx(ts.get("end", -1), 6.0), str(ts))
    check("1: no object selected afterwards", sel["count"] == 0 and sel["ids"] == [], str(sel))
    check("1: the caret is at the start of the blank",
          approx(cmd("transport.state")["cursor"], 4.0), str(cmd("transport.state")))
    cmd("edit.undo")
    check("1: ONE undo puts all three back", starts([o1, o2, o3]) == [0.0, 5.0, 10.0],
          str(starts([o1, o2, o3])))
    cmd("edit.redo")
    check("1: redo opens the blank again", starts([o1, o2, o3]) == [0.0, 7.0, 12.0],
          str(starts([o1, o2, o3])))
    cmd("edit.undo")

    # ── 2. an object straddling the instant is cut there, its right half slides ─────────────
    cmd("project.new")
    s = add(3.0, 5.0, 0)
    cmd("object.set_fade", id=s, **{"in": 0.5, "out": 0.75})
    cmd("wait_idle", timeout_ms=5000)
    before = set(objs())
    cmd("timesel.set", start=4.0, end=6.0, from_ruler=True)
    res = cmd("timesel.insert_time")
    check("2: one cut, one slide", res["cut_count"] == 1 and res["shifted_count"] >= 1, str(res))
    after = objs()
    pieces = sorted(after.values(), key=lambda o: o["start"])
    check("2: two pieces", len(pieces) == 2, str([(p["start"], p["duration"]) for p in pieces]))
    left, right = pieces[0], pieces[1]
    check("2: the left piece keeps its start and ends at the instant",
          approx(left["start"], 3.0) and approx(left["duration"], 1.0),
          "%s / %s" % (left["start"], left["duration"]))
    check("2: the right piece starts after the blank and keeps the rest",
          approx(right["start"], 6.0) and approx(right["duration"], 4.0),
          "%s / %s" % (right["start"], right["duration"]))
    lg, rg = cmd("object.get", id=left["id"]), cmd("object.get", id=right["id"])
    check("2: the left piece plays from the start of the file", approx(lg["source_offset"], 0.0),
          str(lg["source_offset"]))
    check("2: the right piece plays on from the cut (offset 1 s of source)",
          approx(rg["source_offset"], 1.0), str(rg["source_offset"]))
    check("2: the fade-in stays on the left piece, the cut edge is bare",
          approx(lg["fade_in"], 0.5) and approx(lg["fade_out"], 0.0),
          "%s / %s" % (lg["fade_in"], lg["fade_out"]))
    check("2: the fade-out stays on the right piece, the cut edge is bare",
          approx(rg["fade_out"], 0.75) and approx(rg["fade_in"], 0.0),
          "%s / %s" % (rg["fade_in"], rg["fade_out"]))
    check("2: no selection left on the pieces", cmd("selection.get")["count"] == 0)
    cmd("edit.undo")
    got = objs()
    check("2: ONE undo gives the whole object back",
          set(got) == before and approx(got[s]["start"], 3.0) and approx(got[s]["duration"], 5.0),
          str([(o["start"], o["duration"]) for o in got.values()]))

    # An object that merely STARTS at the instant is not cut, it slides.
    cmd("project.new")
    e1 = add(4.0, 2.0, 0)
    e2 = add(1.0, 3.0, 1)        # ends exactly at the instant: untouched
    cmd("timesel.set", start=4.0, end=5.0, from_ruler=True)
    res = cmd("timesel.insert_time")
    check("2b: one starting AT the instant slides, none cut", res["cut_count"] == 0
          and starts([e1]) == [5.0], "%s %s" % (res, starts([e1])))
    check("2b: one ending AT the instant stays", starts([e2]) == [1.0], str(starts([e2])))

    # ── 3. a group straddling the instant is cut in depth ───────────────────────────────────
    cmd("project.new")
    ga = add(3.0, 5.0, 0)
    gb = add(3.0, 5.0, 1)
    g = cmd("group.create", ids=[ga, gb])["id"]
    cmd("group.expand", id=g, expanded=True)
    cmd("wait_idle", timeout_ms=5000)
    cmd("timesel.set", start=4.0, end=6.0, from_ruler=True)
    res = cmd("timesel.insert_time")
    after = objs()
    groups = sorted([o for o in after.values() if o["kind"] == "group"], key=lambda o: o["start"])
    check("3: the group became two groups", len(groups) == 2,
          str([(o["kind"], o["start"], o["duration"]) for o in after.values()]))
    if len(groups) == 2:
        check("3: first group ends at the instant, second starts after the blank",
              approx(groups[0]["start"], 3.0) and approx(groups[0]["duration"], 1.0)
              and approx(groups[1]["start"], 6.0) and approx(groups[1]["duration"], 4.0),
              str([(o["start"], o["duration"]) for o in groups]))
        kids_l = [o for o in after.values() if o["parent"] == groups[0]["id"]]
        kids_r = [o for o in after.values() if o["parent"] == groups[1]["id"]]
        check("3: every child was cut with it (two on each side)",
              len(kids_l) == 2 and len(kids_r) == 2, "%d / %d" % (len(kids_l), len(kids_r)))
        check("3: the children of the right group start after the blank",
              all(approx(k["start"], 6.0) and approx(k["duration"], 4.0) for k in kids_r),
              str([(k["start"], k["duration"]) for k in kids_r]))
        check("3: the children of the left group end at the instant",
              all(approx(k["start"], 3.0) and approx(k["duration"], 1.0) for k in kids_l),
              str([(k["start"], k["duration"]) for k in kids_l]))
    cmd("edit.undo")
    after = objs()
    check("3: ONE undo gives the group and its children back",
          len([o for o in after.values() if o["kind"] == "group"]) == 1
          and len(after) == 3 and approx(after[g]["start"], 3.0) and approx(after[g]["duration"], 5.0),
          str([(o["kind"], o["start"], o["duration"]) for o in after.values()]))

    # ── 4. a MIDI clip straddling the instant ───────────────────────────────────────────────
    cmd("project.new")
    m = cmd("midi.create_clip", start=3.0, end=8.0, lane=0)
    mid, beats = m["id"], m["length_beats"]
    bps = beats / 5.0                                   # beats per second, whatever the tempo
    cmd("midi.add_note", id=mid, pitch=60, start_beat=0.0, length_beats=0.5 * bps)
    cmd("midi.add_note", id=mid, pitch=64, start_beat=0.8 * beats, length_beats=0.5 * bps)
    cmd("timesel.set", start=4.0, end=6.0, from_ruler=True)
    res = cmd("timesel.insert_time")
    after = objs()
    midis = sorted([o for o in after.values() if o["kind"] == "midi"], key=lambda o: o["start"])
    check("4: the MIDI clip was cut in two", len(midis) == 2 and res["cut_count"] == 1,
          str([(o["start"], o["duration"]) for o in midis]))
    if len(midis) == 2:
        check("4: the halves are 3-4 s and 6-10 s",
              approx(midis[0]["start"], 3.0) and approx(midis[0]["duration"], 1.0)
              and approx(midis[1]["start"], 6.0) and approx(midis[1]["duration"], 4.0),
              str([(o["start"], o["duration"]) for o in midis]))
        n = [cmd("object.get", id=o["id"])["midi_notes"] for o in midis]
        check("4: each half kept its note", n == [1, 1], str(n))
    cmd("edit.undo")
    check("4: ONE undo gives the clip back",
          len([o for o in objs().values() if o["kind"] == "midi"]) == 1)

    # ── 5. an infinite bus is neither cut nor moved, its finite children slide ──────────────
    cmd("project.new")
    ia = add(5.0, 2.0, 0)
    ib = add(9.0, 2.0, 1)
    ig = cmd("group.create", ids=[ia, ib])["id"]
    r = cmd("object.set_infinite", id=ig, on=True)
    check("5: the group is infinite", r["infinite"] is True, str(r))
    cmd("group.expand", id=ig, expanded=True)
    cmd("wait_idle", timeout_ms=5000)
    gs0 = objs()[ig]["start"], objs()[ig]["duration"]
    cmd("timesel.set", start=4.0, end=6.0, from_ruler=True)
    res = cmd("timesel.insert_time")
    after = objs()
    check("5: the infinite group did not move or change length",
          (after[ig]["start"], after[ig]["duration"]) == gs0,
          "%s -> %s" % (gs0, (after[ig]["start"], after[ig]["duration"])))
    check("5: it is still infinite", cmd("object.get", id=ig)["infinite"] is True)
    check("5: its finite children slid (5 -> 7, 9 -> 11)",
          starts([ia, ib]) == [7.0, 11.0], str(starts([ia, ib])))
    check("5: nothing was cut", res["cut_count"] == 0, str(res))
    cmd("edit.undo")
    check("5: ONE undo puts the children back", starts([ia, ib]) == [5.0, 9.0], str(starts([ia, ib])))

    # ── 6. the marker band, comments (a ruler range carries them) ───────────────────────────
    cmd("project.new")
    row = cmd("marker_lane.create", name="ins")["lane"]
    k_before = cmd("marker.add", lane=row, at=1.0, name="avant")["marker"]
    k_at = cmd("marker.add", lane=row, at=4.0, name="a")["marker"]
    k_after = cmd("marker.add", lane=row, at=5.0, name="apres")["marker"]
    k_strad = cmd("marker.add", lane=row, at=3.0, duration=2.0, name="chevauche")["marker"]
    k_regend = cmd("marker.add", lane=row, at=2.0, duration=2.0, name="finit a lo")["marker"]
    k_regafter = cmd("marker.add", lane=row, at=7.0, duration=2.0, name="apres region")["marker"]
    c_before = cmd("comment.create", **{"from": 2.0, "to": 3.0, "text": "avant"})["comment"]
    c_after = cmd("comment.create", **{"from": 5.0, "to": 6.5, "text": "apres"})["comment"]
    c_at = cmd("comment.create", **{"from": 4.0, "to": 5.0, "text": "pile"})["comment"]
    ob = add(5.0, 2.0, 0)
    cmd("wait_idle", timeout_ms=5000)
    band0, com0 = band(row), comment_starts([c_before, c_after, c_at])
    cmd("timesel.set", start=4.0, end=6.0, from_ruler=True)
    res = cmd("timesel.insert_time")
    b = band(row)
    check("6: the marks follow", res["markers_follow"] is True, str(res))
    check("6: a point before the instant stays", b[k_before] == (1.0, 0.0), str(b[k_before]))
    check("6: a point AT the instant slides", b[k_at] == (6.0, 0.0), str(b[k_at]))
    check("6: a point after slides", b[k_after] == (7.0, 0.0), str(b[k_after]))
    check("6: a region containing the instant is LENGTHENED, its start stays",
          b[k_strad] == (3.0, 4.0), str(b[k_strad]))
    check("6: a region ending AT the instant is left alone", b[k_regend] == (2.0, 2.0),
          str(b[k_regend]))
    check("6: a region after slides whole", b[k_regafter] == (9.0, 2.0), str(b[k_regafter]))
    check("6: nothing was dropped", set(b) == set(band0), str(set(band0) - set(b)))
    check("6: comments: before stays, after slides, one at the instant slides",
          comment_starts([c_before, c_after, c_at]) == [2.0, 7.0, 6.0],
          str(comment_starts([c_before, c_after, c_at])))
    check("6: the object after slid too", starts([ob]) == [7.0], str(starts([ob])))
    cmd("edit.undo")
    check("6: ONE undo puts the band back", band(row) == band0, str(band(row)))
    check("6: ... and the comments", comment_starts([c_before, c_after, c_at]) == com0,
          str(comment_starts([c_before, c_after, c_at])))
    check("6: ... and the object", starts([ob]) == [5.0], str(starts([ob])))

    # ── 7. a selection traced in the TIMELINE does not carry the marks ──────────────────────
    cmd("timesel.set", start=4.0, end=6.0, all_lanes=True)
    res = cmd("timesel.insert_time")
    check("7: reported as NOT carrying the marks", res["markers_follow"] is False, str(res))
    check("7: the object still slid", starts([ob]) == [7.0], str(starts([ob])))
    check("7: the band is untouched", band(row) == band0, str(band(row)))
    check("7: the comments are untouched",
          comment_starts([c_before, c_after, c_at]) == com0,
          str(comment_starts([c_before, c_after, c_at])))
    cmd("edit.undo")

    # ── 8. refusals: nothing after the instant, and no undo step is left behind ─────────────
    cmd("project.new")
    r1 = add(0.0, 2.0, 0)
    cmd("object.set_fade", id=r1, **{"in": 0.25})        # a known gesture to undo afterwards
    cmd("timesel.set", start=50.0, end=52.0, from_ruler=True)
    refused(lambda: cmd("timesel.insert_time"), "8: a range with nothing after it is refused")
    cmd("timesel.clear")
    refused(lambda: cmd("timesel.insert_time"), "8: no selection is refused")
    cmd("edit.undo")
    check("8: the refusals left NO undo step (the undo took back the fade)",
          approx(cmd("object.get", id=r1)["fade_in"], 0.0), str(cmd("object.get", id=r1)["fade_in"]))

    # ── 9. a consolidated object open for editing refuses the gesture ───────────────────────
    cmd("project.new")
    cc = add(0.0, 2.0, 0)
    cmd("project.save_as", path=os.path.join(ROOT, "cons", "cons.json"))
    job = cmd("consolidate.make", id=cc)
    cmd("job.wait", id=job["job_id"], timeout_ms=60000)
    cmd("wait_idle", timeout_ms=30000)
    defs = cmd("consolidate.list")["definitions"]
    check("9: a consolidated object exists", len(defs) == 1, str(defs))
    if defs:
        pid = defs[0]["placements"][0]
        tail = add(5.0, 2.0, 3)
        r = cmd("consolidate.edit_begin", placement=pid)
        check("9: opened for editing", r["depth"] == 1, str(r))
        cmd("timesel.set", start=0.5, end=1.0, from_ruler=True)
        refused(lambda: cmd("timesel.insert_time"),
                "9: insert time is refused while a consolidated object is open")
        cmd("consolidate.edit_cancel")
        check("9: the object outside it was not moved", starts([tail]) == [5.0], str(starts([tail])))

    # ── 10. the ripple delete now carries the comments ──────────────────────────────────────
    cmd("project.new")
    row = cmd("marker_lane.create", name="rip")["lane"]
    d_before = cmd("comment.create", **{"from": 1.0, "to": 1.5, "text": "avant"})["comment"]
    d_inside = cmd("comment.create", **{"from": 3.0, "to": 3.5, "text": "dedans"})["comment"]
    d_after = cmd("comment.create", **{"from": 6.0, "to": 7.0, "text": "apres"})["comment"]
    rb = add(8.0, 2.0, 0)
    cmd("wait_idle", timeout_ms=5000)
    com0 = comment_starts([d_before, d_inside, d_after])
    cmd("timesel.set", start=2.0, end=4.0, from_ruler=True)
    res = cmd("timesel.ripple_delete")
    check("10: ruler ripple delete reports the marks follow", res.get("markers_follow") is True, str(res))
    got = comment_starts([d_before, d_inside, d_after])
    check("10: a comment before the range stays", got[0] == 1.0, str(got))
    check("10: a comment starting inside the range goes", got[1] is None, str(got))
    check("10: a comment after the range slides back by its length", got[2] == 4.0, str(got))
    check("10: the object after slid back too", starts([rb]) == [6.0], str(starts([rb])))
    cmd("edit.undo")
    check("10: ONE undo brings the comments back",
          comment_starts([d_before, d_inside, d_after]) == com0,
          str(comment_starts([d_before, d_inside, d_after])))
    # From the TIMELINE, the comments stay.
    cmd("timesel.set", start=2.0, end=4.0, all_lanes=True)
    res = cmd("timesel.ripple_delete")
    check("10: a timeline range leaves the comments alone",
          res.get("markers_follow") is False
          and comment_starts([d_before, d_inside, d_after]) == com0,
          "%s %s" % (res, comment_starts([d_before, d_inside, d_after])))
    cmd("edit.undo")

    # ── 11. inside an open group: the scope is the group, its window grows ──────────────────
    cmd("project.new")
    ja = add(5.0, 2.0, 0)
    jb = add(9.0, 2.0, 1)
    jg = cmd("group.create", ids=[ja, jb])["id"]
    cmd("group.expand", id=jg, expanded=True)
    out = add(12.0, 2.0, 5)
    cmd("wait_idle", timeout_ms=5000)
    ents = objs()
    lanes = sorted({ents[ja]["display_lane"], ents[jb]["display_lane"]})
    g0 = (ents[jg]["start"], ents[jg]["duration"])
    cmd("timesel.set", start=6.0, end=8.0, lanes=lanes)
    res = cmd("timesel.insert_time")
    after = objs()
    check("11: the container is the group", res["container"] is not None
          and res["container"].upper() == jg.upper(), str(res))
    check("11: markers do not follow inside a container", res["markers_follow"] is False, str(res))
    check("11: the object OUTSIDE the group did not move", starts([out]) == [12.0], str(starts([out])))
    kids = sorted([o for o in after.values() if o["parent"] == jg], key=lambda o: o["start"])
    check("11: the straddling child was cut (5-6 and 8-9) and the other slid (11-13)",
          len(kids) == 3
          and [(round(k["start"], 6), round(k["duration"], 6)) for k in kids]
          == [(5.0, 1.0), (8.0, 1.0), (11.0, 2.0)],
          str([(k["start"], k["duration"]) for k in kids]))
    check("11: every lane of the group was selected, so its window grew by the blank",
          approx(after[jg]["start"], g0[0]) and approx(after[jg]["duration"], g0[1] + 2.0),
          "%s -> %s" % (g0, (after[jg]["start"], after[jg]["duration"])))
    cmd("edit.undo")
    after = objs()
    check("11: ONE undo gives the group back",
          approx(after[jg]["duration"], g0[1]) and starts([ja, jb]) == [5.0, 9.0]
          and len([o for o in after.values() if o["parent"] == jg]) == 2,
          str([(o["start"], o["duration"]) for o in after.values()]))

    # ── a window on the headless pid would be a bug (nothing here may open one) ─────────────
    pid_ = info.get("pid")
    if pid_:
        try:
            import Quartz
            wins = [w for w in (Quartz.CGWindowListCopyWindowInfo(
                        Quartz.kCGWindowListOptionAll, Quartz.kCGNullWindowID) or [])
                    if w.get("kCGWindowOwnerPID") == pid_ and w.get("kCGWindowLayer") == 0]
            check("no window on the headless pid", len(wins) == 0, str(len(wins)))
        except ImportError:
            print("skip  no window check (no Quartz module)")

print()
if fails:
    print("%d FAILED:" % len(fails))
    for f in fails:
        print("  - " + f)
    sys.exit(1)
print("ALL PASS")

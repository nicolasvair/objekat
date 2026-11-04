#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""E5b / E6 of the loop recording (docs/plan_enregistrement_audio.md, "Rec en boucle"): the MIDI takes and their shared sequence.

Headless, on the virtual card and the virtual MIDI input (`--virtual-audio --virtual-midi`), never a window. A MIDI zone armed on the
virtual device records sixteen notes (one every 200 ms) THROUGH a loop [1 s, 2 s] switched on from 0.5 s, and then:

  M1  one take per pass; the passes partition the notes (every note in exactly one take); mute mode: only the last pass audible
      (in the model AND in the engine); newest on the top lane; each take names the shared sequence with the offset of its pass;
      ONE undo takes all of it away.
  M2  the window follows the edges: the end pulled in hides the notes behind it, pushed out again gives the same notes back, pulled
      further than the pass reveals the capture's next notes; the start pulled in moves the offset.
  M3  the first edit of a take's notes detaches it (no more `midi_sequence`, and its edges no longer reveal anything).
  M4  format 37: the file carries `midiSequences` and the `midiSequence` of the takes that still hold; the project reopened resolves
      its windows again; with no take left the sequence is not written (orphan).
  M5  a recording with NO loop makes one take and no sequence.

    ./scenario_record_loop_midi.py /path/to/objekat.app

Exit: 0 if every assertion passes, 1 if one fails, 2 on bad usage.
"""

import json, os, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient

if len(sys.argv) != 2:
    print(__doc__)
    sys.exit(2)

APP = sys.argv[1]
BIN = os.path.join(APP, "Contents", "MacOS", "objekat")
if not os.path.exists(BIN):
    print("not an app bundle: %s" % APP)
    sys.exit(2)

ok, ko = 0, 0


def check(label, cond, detail=""):
    global ok, ko
    if cond:
        ok += 1
        print("  OK    %s" % label)
    else:
        ko += 1
        print("  FAIL  %s   %s" % (label, detail))


def section(t):
    print("\n== %s" % t)


tmp = tempfile.mkdtemp(prefix="objk-loopmidi-")
sock = "/tmp/objk-loopmidi-%d.sock" % os.getpid()
if os.path.exists(sock):
    os.remove(sock)
proc = subprocess.Popen([BIN, "--headless", "--api", "--no-recent", "--language=en", "--virtual-audio", "--virtual-midi",
                         "--socket=" + sock],
                        stdout=subprocess.DEVNULL, stderr=open(os.path.join(tmp, "app.err"), "w"),
                        env=dict(os.environ, OBJ_SKIP_REAL_CARD="1"))
for _ in range(160):
    if os.path.exists(sock):
        break
    time.sleep(0.25)

N = 16


def kids(c, gid):
    c.send("group.expand", {"id": gid, "expanded": True})      # left open: object.get reads the lane entries
    return [o for o in c.send("object.list")["objects"] if o["parent"] == gid]


def record(c, vid, loop, name):
    """A MIDI zone [0, 60] on lane 0, N notes through (or not) a loop [1, 2]; returns (group, rec.stop answer)."""
    c.send("timesel.set", {"start": 0, "end": 60, "lanes": [0]})
    r = c.send("rec.drop", {"midi": vid, "lane": 0, "time": 30})
    c.send("timesel.clear")
    gid = r["group"]
    insts = c.send("plugin.list_available", {"instruments_only": True})["plugins"]
    dls = next(p for p in insts if p["name"] == "DLSMusicDevice")
    c.send("instrument.set", {"id": gid, "identifier": dls["identifier"], "format": dls["format"]})
    c.send("rec.arm", {"group": gid, "on": True})
    if loop:
        c.send("debug.transport_loop", {"start": 1.0, "end": 2.0, "enabled": True})
    else:
        c.send("debug.transport_loop", {"enabled": False})
    c.send("transport.seek", {"seconds": 0.5})
    c.send("rec.start")
    ev = []
    for i in range(N):
        on = 0.1 + 0.2 * i
        ev.append({"kind": "on", "note": 40 + i, "velocity": 90, "delay_ms": on * 1000})
        ev.append({"kind": "off", "note": 40 + i, "velocity": 0, "delay_ms": (on + 0.05) * 1000})
    c.send("midi.virtual.send", {"events": ev})
    time.sleep(2.3)
    mid = c.send("rec.status")                     # the second lap of a 1 s loop is running (clock ~2.3 s, head ~1.8 s)
    time.sleep(0.1 + 0.2 * N + 0.5 - 2.3)
    st = c.send("rec.stop")
    c.send("rec.arm", {"group": gid, "on": False})
    st["mid"] = mid
    return gid, st


try:
    with ObjekatClient(sock) as c:
        c.send("project.new")
        c.send("input.enable")
        path = os.path.join(tmp, "m6", "m6.objekat")
        c.send("project.save_as", {"path": path})
        vid = c.send("midi.virtual.status")["device_id"]

        # ---------------------------------------------------------------- M1
        section("M1 a MIDI recording through a loop [1 s, 2 s]")
        gid, st = record(c, vid, True, "loop")
        mid = st["mid"]
        pr = mid["progress"]
        print("       mid-recording: lap %s, pass_start %s, progress %s" % (mid.get("lap"), mid.get("pass_start"),
                                                                           [(round(b["start"], 2), round(b["end"], 2)) for b in pr]))
        check("rec.status says the lap while it loops", mid.get("lap", 0) >= 1, mid.get("lap"))
        check("the red block grows from the START OF THE PASS (the loop's start), never past the loop's end",
              len(pr) == 1 and abs(pr[0]["start"] - 1.0) < 0.05 and pr[0]["end"] <= 2.0 + 0.05 and pr[0]["end"] > pr[0]["start"], pr)
        takes = sorted(st["last_takes"], key=lambda t: t["pass"])
        passes = takes[0]["passes"] if takes else 0
        print("       %d take(s), %d pass(es): %s" % (len(takes), passes, [(t["pass"], len(t["notes"]), t["audible"]) for t in takes]))
        check("at least three passes through a 1 s loop", passes >= 3, passes)
        check("one take per pass (the zone covers the loop)", len(takes) == passes, (len(takes), passes))
        check("the last pass is the partial one", takes[-1]["partial"] and not any(t["partial"] for t in takes[:-1]))
        check("every note is in exactly one take", sum(len(t["notes"]) for t in takes) == N, [len(t["notes"]) for t in takes])
        pitches = [sorted(n["pitch"] for n in t["notes"]) for t in takes]
        flat = [p for ps in pitches for p in ps]
        check("the passes partition the pitches 40..55 in order", flat == list(range(40, 40 + N)), flat)
        check("mute mode: only the LAST pass is audible", [t["audible"] for t in takes] == [False] * (len(takes) - 1) + [True])
        check("each pass starts on the timeline where the loop put it",
              abs(takes[0]["start"] - 0.5) < 0.1 and all(abs(t["start"] - 1.0) < 0.1 for t in takes[1:]),
              [round(t["start"], 3) for t in takes])
        check("the newest take is on the top lane, one lane each",
              [t["lane"] for t in takes] == sorted([t["lane"] for t in takes], reverse=True)
              and len(set(t["lane"] for t in takes)) == len(takes), [t["lane"] for t in takes])

        kids(c, gid)
        ids = [t["object"] for t in takes]
        objs = [c.send("object.get", {"id": i}) for i in ids]
        obj = lambda o: o.get("object", o)
        refs = [obj(o).get("midi_sequence") for o in objs]
        check("every take names a sequence", all(refs), refs)
        check("one shared sequence", len(set(r["id"] for r in refs if r)) == 1)
        check("the offsets are the passes' own (seconds x 2 beats at 120)",
              all(abs(r["offset_beats"] - t["source_offset"] * 2.0) < 1e-6 for r, t in zip(refs, takes)),
              [(r["offset_beats"], t["source_offset"]) for r, t in zip(refs, takes)])
        check("the engine mutes what the model mutes",
              all(obj(o).get("engine_midi_muted") == (not t["audible"]) for o, t in zip(objs, takes)),
              [(obj(o).get("engine_midi_muted"), t["audible"]) for o, t in zip(objs, takes)])

        c.send("edit.undo")
        check("ONE undo takes the whole recording away", len(kids(c, gid)) == 0, len(kids(c, gid)))
        c.send("edit.redo")
        check("one redo brings every take back", len(kids(c, gid)) == len(takes), len(kids(c, gid)))

        # ---------------------------------------------------------------- M2
        section("M2 the window follows the edges")
        t0 = takes[0]
        tid = t0["object"]
        start, dur = t0["start"], t0["duration"]
        n0 = len(c.send("midi.list_notes", {"id": tid})["notes"])
        check("the first pass holds some notes", n0 > 2, n0)
        c.send("object.trim", {"id": tid, "start": start, "duration": dur - 0.6})
        n_in = len(c.send("midi.list_notes", {"id": tid})["notes"])
        check("the end pulled in hides the notes behind it", n_in < n0, (n_in, n0))
        c.send("object.trim", {"id": tid, "start": start, "duration": dur})
        back = c.send("midi.list_notes", {"id": tid})["notes"]
        check("pushed out again it gives the same notes back", len(back) == n0, (len(back), n0))
        c.send("object.trim", {"id": tid, "start": start, "duration": dur + 1.2})
        n_out = len(c.send("midi.list_notes", {"id": tid})["notes"])
        check("pulled further than its pass it reveals the capture's next notes", n_out > n0, (n_out, n0))
        c.send("object.trim", {"id": tid, "start": start, "duration": dur})
        off0 = obj(c.send("object.get", {"id": tid}))["midi_sequence"]["offset_beats"]
        c.send("object.trim", {"id": tid, "start": start + 0.5, "duration": dur - 0.5})
        o1 = obj(c.send("object.get", {"id": tid}))
        check("the start pulled in moves the offset by the same beats (0.5 s = 1 beat)",
              abs(o1["midi_sequence"]["offset_beats"] - (off0 + 1.0)) < 1e-6, (off0, o1["midi_sequence"]))
        n_s = c.send("midi.list_notes", {"id": tid})["notes"]
        check("the notes are rebased on the new start (none negative)", all(n["start_beat"] >= 0 for n in n_s), n_s)
        c.send("object.trim", {"id": tid, "start": start, "duration": dur})
        check("the start pushed back out restores the offset", abs(obj(c.send("object.get", {"id": tid}))["midi_sequence"]["offset_beats"] - off0) < 1e-6)

        # ---------------------------------------------------------------- M3
        section("M3 the first edit detaches")
        edited = takes[1]["object"]
        notes = c.send("midi.list_notes", {"id": edited})["notes"]
        c.send("midi.update_note", {"id": edited, "note_id": notes[0]["id"], "pitch": notes[0]["pitch"] + 12})
        o = obj(c.send("object.get", {"id": edited}))
        check("an edited take is a classic clip (no `midi_sequence`)", "midi_sequence" not in o, o.get("midi_sequence"))
        e_start, e_dur = takes[1]["start"], takes[1]["duration"]
        n_before = len(c.send("midi.list_notes", {"id": edited})["notes"])
        c.send("object.trim", {"id": edited, "start": e_start, "duration": e_dur + 1.2})
        n_after = len(c.send("midi.list_notes", {"id": edited})["notes"])
        check("pulling its end out reveals nothing any more", n_after == n_before, (n_before, n_after))
        check("the other takes are untouched by the edit",
              all("midi_sequence" in obj(c.send("object.get", {"id": t["object"]})) for i, t in enumerate(takes) if i != 1))

        # ---------------------------------------------------------------- M4
        section("M4 format 37")
        c.send("project.save")
        doc = json.load(open(path))
        check("the file is format 37", doc.get("version") == 37, doc.get("version"))
        seqs = doc.get("midiSequences") or []
        check("the file keeps ONE sequence of %d notes" % N, len(seqs) == 1 and len(seqs[0]["notes"]) == N,
              [len(s["notes"]) for s in seqs])

        def walk(items):
            for it in items:
                yield it
                if it["kind"]["type"] == "group":
                    yield from walk(it["kind"]["children"])
        clips = [it for it in walk(doc["items"]) if it["kind"]["type"] == "midiClip"]
        with_ref = [it for it in clips if "midiSequence" in it]
        check("every take but the edited one carries its reference", len(clips) == len(takes) and len(with_ref) == len(takes) - 1,
              (len(clips), len(with_ref)))
        check("the reference is {id, offsetBeats} and nothing else (no signature)",
              all(set(it["midiSequence"].keys()) == {"id", "offsetBeats"} for it in with_ref))
        check("a reference names the sequence written", all(it["midiSequence"]["id"] == seqs[0]["id"] for it in with_ref))

        c.send("project.open", {"path": path})
        gid2 = next(o["id"] for o in c.send("object.list")["objects"] if o["kind"] == "group")
        reopened = kids(c, gid2)
        by_start = {o["id"]: o for o in reopened}
        check("reopened: the takes are all there", len(reopened) == len(takes), len(reopened))
        c.send("object.trim", {"id": tid, "start": start, "duration": dur + 1.2})
        n_re = len(c.send("midi.list_notes", {"id": tid})["notes"])
        check("reopened: a take still reveals the capture when its edge is pulled out", n_re > n0, (n_re, n0))
        c.send("object.trim", {"id": tid, "start": start, "duration": dur})
        check("reopened: and hides it again", len(c.send("midi.list_notes", {"id": tid})["notes"]) == n0)

        c.send("object.remove", {"ids": [t["object"] for t in takes]})
        c.send("project.save")
        doc2 = json.load(open(path))
        check("with no take left the sequence is not written (orphan)", not doc2.get("midiSequences"), doc2.get("midiSequences"))

        # ---------------------------------------------------------------- M5
        section("M5 no loop: one take, no sequence")
        gid3, st3 = record(c, vid, False, "linear")
        t3 = st3["last_takes"]
        check("one take, one pass", len(t3) == 1 and t3[0]["passes"] == 1, [(t["pass"], t["passes"]) for t in t3])
        check("it holds every note", len(t3[0]["notes"]) == N, len(t3[0]["notes"]))
        o3 = obj(c.send("object.get", {"id": t3[0]["object"]}))
        check("it names no sequence", "midi_sequence" not in o3, o3.get("midi_sequence"))
        check("rec.status in a linear recording: lap 0", st3["mid"].get("lap") == 0, st3["mid"].get("lap"))
        c.send("project.save")
        check("and the file writes none", not json.load(open(path)).get("midiSequences"))
finally:
    proc.terminate()
    try:
        proc.wait(10)
    except subprocess.TimeoutExpired:
        proc.kill()

print("\n%d OK, %d FAIL" % (ok, ko))
sys.exit(0 if ko == 0 else 1)

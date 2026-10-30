#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""MIDI recording zones (`--virtual-midi`, `--virtual-audio`), headless.

A MIDI zone is a GROUP with a MIDI input (`recordMidiInput`, session format 36), recorded with the same
`rec.start` / `rec.stop` as an audio zone: each take is a `.midiClip` child with handles, newest on top, the
previous takes muted (or not, "add" mode), ONE undo point. While a zone is armed the engine plays its input
by a hidden capture track; the zone's INSTRUMENT sits on the group and plays the (empty) takes.
The virtual device "OBJ Virtual MIDI" is fed by `midi.virtual.send`. The instrument is Apple's DLSMusicDevice
(no third-party plugin, no licence).

  A  enumeration (All MIDI Ins first) and the activity meter (velocity, cleared by the read)
  B  drag -> zone (rec.drop midi), refusals, mixed MIDI + audio drag (MIDI first), assign, instrument on a zone
  C  listening: arming is not hearing (master level stays silent); the capture track is live only while armed
  D  a 4-note take: pitches / velocities / timing, ONE undo point, an empty clip hosted by the zone, no file
  E  second take: newest on top, the previous muted; "add" mode; the same input on two zones; the same take
     played twice does not touch the first one
  F  no note = no take (the mutes are given back); punch-in; a note held at the stop is closed; sustain pedal
  G  mixed audio + MIDI recording (one file for the audio zone, none for the MIDI one)
  H  refusals; the file (format 35, recordMidiInput, zoneInstruments) and its reading back
  I  Settings.xml is byte for byte what it was

    ./scenario_midi_record.py /path/to/objekat.app

Exit: 0 if every assertion passes, 1 if one fails, 2 on bad usage.
"""

import hashlib, json, os, struct, subprocess, sys, tempfile, time

import numpy as np

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
ok, ko = 0, 0
ERRS = []   # measured timing errors (s), for the report


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


def undo_depth(c):
    return c.send("perf.census")["undo_depth"]


def wait_pos(c, t, timeout=30):
    end = time.time() + timeout
    while time.time() < end:
        if c.send("transport.state")["position"] >= t:
            return True
        time.sleep(0.03)
    return False


def kids(c, gid):
    c.send("group.expand", {"id": gid, "expanded": True})
    out = [o for o in c.send("object.list")["objects"] if o["parent"] == gid]
    c.send("group.expand", {"id": gid, "expanded": False})
    return sorted(out, key=lambda o: o["lane"])


def get_child(c, gid, oid):
    c.send("group.expand", {"id": gid, "expanded": True})
    try:
        return c.send("object.get", {"id": oid})
    finally:
        c.send("group.expand", {"id": gid, "expanded": False})


def notes_of(c, gid, oid):
    c.send("group.expand", {"id": gid, "expanded": True})
    try:
        return c.send("midi.list_notes", {"id": oid})["notes"]
    finally:
        c.send("group.expand", {"id": gid, "expanded": False})


def master_level(c):
    c.send("stem.level")
    time.sleep(0.5)
    return c.send("stem.level", {"id": c.send("stem.list")["main"]})["level"]


def play(c, notes, tempo=None):
    """Sends [(pitch, on_s, dur_s, velocity)] relative to NOW; returns the timeline position of 'now'."""
    pos = c.send("transport.state")["position"]
    ev = []
    for p, on, dur, vel in notes:
        ev.append({"kind": "on", "note": p, "velocity": vel, "delay_ms": on * 1000})
        ev.append({"kind": "off", "note": p, "velocity": 0, "delay_ms": (on + dur) * 1000})
    c.send("midi.virtual.send", {"events": ev})
    return pos


def settle_sent(c, timeout=15):
    end = time.time() + timeout
    while time.time() < end:
        if c.send("midi.virtual.status")["pending"] == 0:
            return True
        time.sleep(0.05)
    return False


def read_wav_float(path):
    with open(path, "rb") as f:
        raw = f.read()
    pos, ch, sr, data = 12, 1, 48000, b""
    while pos + 8 <= len(raw):
        cid, size = raw[pos:pos + 4], struct.unpack("<I", raw[pos + 4:pos + 8])[0]
        body = raw[pos + 8:pos + 8 + size]
        if cid == b"fmt ":
            _, ch, sr = struct.unpack("<HHI", body[:8])
        elif cid == b"data":
            data = body
        pos += 8 + size + (size & 1)
    return np.frombuffer(data[:len(data) // 4 * 4], dtype="<f4").reshape(-1, ch), sr


def make_zone(c, midi, start, end, lane):
    c.send("timesel.set", {"start": start, "end": end, "lanes": [lane]})
    r = c.send("rec.drop", {"midi": midi, "lane": lane, "time": (start + end) / 2})
    c.send("timesel.clear")
    assert r["outcome"] == "create", r
    return r["group"]


def zone_status(c, gid):
    return next((z for z in c.send("rec.status")["zones"] if z["id"] == gid), None)


before = digest()
SOCK = "/tmp/objk-midi-%d.sock" % os.getpid()
if os.path.exists(SOCK):
    os.remove(SOCK)
tmp = tempfile.mkdtemp(prefix="objk-midi-")
proc = subprocess.Popen([BIN, "--headless", "--api", "--no-recent", "--language=en", "--virtual-audio",
                         "--virtual-midi", "--socket=" + SOCK], stdout=subprocess.DEVNULL,
                        stderr=open(os.path.join(tmp, "app.err"), "w"),
                        env=dict(os.environ, OBJ_SKIP_REAL_CARD="1"))
try:
    for _ in range(160):
        if os.path.exists(SOCK):
            break
        time.sleep(0.25)
    with ObjekatClient(SOCK) as c:
        c.send("project.new")
        c.send("input.enable")
        c.send("audio.virtual.set_input", {"channel": 0, "signal": "sine", "frequency": 440, "amplitude": 0.5})
        TEMPO = c.send("transport.state")["tempo"]
        SPB = 60.0 / TEMPO
        vstat = c.send("midi.virtual.status")
        VID = vstat["device_id"]
        insts = c.send("plugin.list_available", {"instruments_only": True})["plugins"]
        DLS = next(p for p in insts if p["name"] == "DLSMusicDevice")
        INST = {"identifier": DLS["identifier"], "format": DLS["format"]}

        # ── A ----------------------------------------------------------------------------------------
        section("A  enumeration and activity")
        check("the harness is active", vstat["active"] is True and vstat["name"] == "OBJ Virtual MIDI", vstat)
        lst = c.send("input.list.midi_inputs")
        ids = [d["id"] for d in lst["midi_inputs"]]
        check("'All MIDI Ins' is first", ids[:1] == ["all_midi_in"], ids)
        check("the virtual input is listed", VID in ids and lst["midi_inputs"][ids.index(VID)]["virtual"] is True)
        c.send("input.levels.midi_activity")
        c.send("midi.virtual.send", {"events": [{"kind": "on", "note": 60, "velocity": 97},
                                                {"kind": "off", "note": 60, "velocity": 0, "delay_ms": 50}]})
        settle_sent(c)
        time.sleep(0.2)
        act = {a["id"]: a["velocity"] for a in c.send("input.levels.midi_activity")["activity"]}
        check("activity: velocity 97 on the virtual input AND on All MIDI Ins",
              act.get(VID) == 97 and act.get("all_midi_in") == 97, act)
        check("the read clears it", c.send("input.levels.midi_activity")["activity"] == [])
        check("midi.virtual.status counts what was sent", c.send("midi.virtual.status")["sent"] >= 2)

        # ── B ----------------------------------------------------------------------------------------
        section("B  drag -> zone, refusals, mixed drag, assign, instrument")
        d0 = undo_depth(c)
        z1 = make_zone(c, VID, 0, 8, 0)
        zs = zone_status(c, z1)
        check("the drop made a MIDI zone on the virtual input",
              zs is not None and zs["source"] == "midi" and zs["midi_input"]["id"] == VID, zs)
        check("named after the input", zs["name"] == "OBJ Virtual MIDI", zs["name"])
        check("one undo point for the drop", undo_depth(c) == d0 + 1, (d0, undo_depth(c)))
        check("unknown MIDI input: not_found, nothing done",
              refused(c, "rec.drop", midi="nope", lane=3, time=2.0) == "not_found" and undo_depth(c) == d0 + 1)
        check("instrument.set with a plugin that does not exist is refused",
              refused(c, "instrument.set", id=z1, name="NoSuchSynth") == "not_found")
        d1 = undo_depth(c)
        ins = c.send("instrument.set", {"id": z1, **INST})
        check("instrument.set on the zone", ins["instrument"]["name"] == "DLSMusicDevice", ins)
        check("... in ONE undo point", undo_depth(c) == d1 + 1)
        zs = zone_status(c, z1)
        check("the zone reports its instrument", zs["instrument"] is not None and zs["instrument"]["name"] == "DLSMusicDevice", zs)
        r = c.send("rec.drop", {"inputs": [{"first": 0}, {"midi": VID}], "lane": 2, "time": 3.0, "dry_run": True})
        check("mixed dry run: two lanes planned, nothing applied", r["applied"] is False and len(r["drops"]) == 2, r)
        d2 = undo_depth(c)
        r = c.send("rec.drop", {"inputs": [{"midi": VID}, {"first": 0}], "lane": 2, "time": 3.0})
        check("mixed drag: one lane per source, in the order given, ONE undo",
              r["applied"] and [d["outcome"] for d in r["drops"]] == ["create", "create"] and undo_depth(c) == d2 + 1, r)
        srcs = [zone_status(c, d["group"])["source"] for d in r["drops"]]
        check("the MIDI zone is on the first lane, the audio zone below", srcs == ["midi", "audio"], srcs)
        c.send("edit.undo")
        check("undo removes both zones", zone_status(c, r["drops"][0]["group"]) is None)
        zx = make_zone(c, VID, 20, 24, 4)
        c.send("rec.assign", {"group": zx, "first": 0})
        check("rec.assign: the audio source replaces the MIDI one",
              zone_status(c, zx)["source"] == "audio", zone_status(c, zx))
        c.send("rec.assign", {"group": zx, "midi": VID})
        check("... and back to MIDI", zone_status(c, zx)["source"] == "midi")
        c.send("rec.assign", {"group": zx})
        check("rec.assign with no source clears the zone", zone_status(c, zx) is None)
        c.send("edit.undo"); c.send("edit.undo"); c.send("edit.undo"); c.send("edit.undo")

        # ── C ----------------------------------------------------------------------------------------
        section("C  listening: arming is not hearing (armed = silent too)")
        z1s = zone_status(c, z1)
        check("instrument survived the undos of the others", z1s is not None and z1s["instrument"] is not None, z1s)
        live = lambda: c.send("input.list.midi_inputs")["zones"]
        check("disarmed: no hidden track", all(not z["live"] for z in live()))
        master_level(c)
        play(c, [(60, 0.1, 1.5, 110)])
        settle_sent(c)
        quiet = master_level(c)
        check("disarmed: the master is silent (%.3f)" % quiet, quiet < 0.02, quiet)
        c.send("rec.arm", {"group": z1, "on": True})
        time.sleep(0.5)
        check("armed: the zone is live on the engine", any(z["live"] and z["id"] == z1 for z in live()), live())
        master_level(c)
        play(c, [(60, 0.1, 1.5, 110)])
        time.sleep(0.9)
        heard = master_level(c)
        check("armed: still SILENT on the master, the instrument is the group's and plays the takes (%.3f)" % heard,
              heard < 0.02, heard)
        settle_sent(c)
        time.sleep(1.0)
        c.send("rec.arm", {"group": z1, "on": False})
        time.sleep(0.5)
        check("disarmed again: the hidden track is released", all(not z["live"] for z in live()))
        master_level(c)
        play(c, [(60, 0.1, 1.0, 110)])
        settle_sent(c); time.sleep(0.3)
        quiet = master_level(c)
        check("... and the master is silent (%.3f)" % quiet, quiet < 0.02, quiet)

        # ── D ----------------------------------------------------------------------------------------
        section("D  a 4-note take (project NOT saved: a MIDI take needs no file)")
        c.send("rec.arm", {"group": z1, "on": True})
        st = c.send("rec.status")
        check("MIDI only: can_record without a saved project", st["can_record"] is True and st["project_saved"] is False, st)
        c.send("transport.seek", {"seconds": 0})
        d0 = undo_depth(c)
        c.send("rec.start")
        time.sleep(0.3)
        script = [(60, 0.5, 0.3, 100), (64, 1.0, 0.3, 90), (67, 1.5, 0.3, 80), (72, 2.0, 0.3, 70)]
        pos0 = play(c, script)
        wait_pos(c, 3.5)
        settle_sent(c)
        r = c.send("rec.stop")
        tk = r["last_takes"]
        check("one take, MIDI", len(tk) == 1 and tk[0]["group"] == z1 and tk[0]["source"] == "midi", tk)
        t = tk[0]
        check("the take holds 4 notes", len(t["notes"]) == 4, t["notes"])
        check("pitches 60/64/67/72, velocities 100/90/80/70",
              [(n["pitch"], n["velocity"]) for n in t["notes"]] == [(60, 100), (64, 90), (67, 80), (72, 70)], t["notes"])
        errs = []
        for n, (p, on, dur, vel) in zip(t["notes"], script):
            secs = t["start"] + n["start_beat"] * SPB
            errs.append(secs - (pos0 + on))
        ERRS.extend(errs)
        check("timing within 0.1 s of what was played (errors %s ms)" % ["%.0f" % (e * 1000) for e in errs],
              all(abs(e) < 0.1 for e in errs), errs)
        lens = [n["length_beats"] * SPB for n in t["notes"]]
        check("durations ~0.3 s", all(abs(l - 0.3) < 0.1 for l in lens), lens)
        check("no file: path is empty and samples/rec was not created", t["path"] == "" )
        check("ONE undo point for the stop", undo_depth(c) == d0 + 1, (d0, undo_depth(c)))
        ks = kids(c, z1)
        check("the zone has the take as its child, a MIDI clip",
              len(ks) == 1 and ks[0]["id"] == t["object"], ks)
        o = get_child(c, z1, t["object"])
        ti = o.get("instruments") or []
        zs = zone_status(c, z1)
        check("the take is an EMPTY clip: no instrument of its own, played by the zone's (instrument_host)",
              ti == [] and o.get("instrument_state") == "hosted" and o.get("instrument_host") == z1
              and zs["instrument"] is not None, (ti, o.get("instrument_state"), o.get("instrument_host")))
        check("the take is on lane 0 of the zone, nothing muted", t["lane"] == 0 and t["muted"] == [])
        check("the take is the capture (0 -> ~3.5 s) cropped to the zone's window (0 -> 8)",
              near(t["start"], 0, 1e-3) and 3.2 < t["duration"] < 3.9, t)
        c.send("edit.undo")
        check("undo: the zone is empty again", kids(c, z1) == [])
        c.send("edit.redo")
        check("redo: the take is back with its 4 notes", len(notes_of(c, z1, t["object"])) == 4)

        # ── E ----------------------------------------------------------------------------------------
        section("E  second take (mute), add mode, two zones on one input")
        first_take = t["object"]
        c.send("transport.seek", {"seconds": 0})
        c.send("rec.start")
        time.sleep(0.3)
        play(c, [(62, 0.5, 0.3, 100), (65, 1.0, 0.3, 100)])
        wait_pos(c, 2.5); settle_sent(c)
        r = c.send("rec.stop")
        t2 = r["last_takes"][0]
        check("second take: 2 notes, lane 0, the first one muted", len(t2["notes"]) == 2 and t2["lane"] == 0
              and t2["muted"] == [first_take], t2)
        ks = kids(c, z1)
        check("lanes: the newest on top (0), the older below (1) and muted",
              [k["lane"] for k in ks] == [0, 1] and [k["muted"] for k in ks] == [False, True], ks)
        check("the first take kept its 4 notes", len(notes_of(c, z1, first_take)) == 4)
        c.send("rec.set_take_mode", {"group": z1, "mode": "add"})
        c.send("transport.seek", {"seconds": 0})
        c.send("rec.start")
        time.sleep(0.3)
        play(c, [(70, 0.5, 0.3, 100)])
        wait_pos(c, 1.8); settle_sent(c)
        r = c.send("rec.stop")
        t3 = r["last_takes"][0]
        ks = kids(c, z1)
        check("add mode: third take on top, nothing newly muted (the older stay as they were)",
              t3["muted"] == [] and [k["lane"] for k in ks] == [0, 1, 2] and [k["muted"] for k in ks] == [False, False, True], (t3, ks))
        c.send("rec.set_take_mode", {"group": z1, "mode": "mute"})
        z2 = make_zone(c, VID, 10, 18, 1)
        c.send("instrument.set", {"id": z2, **INST})
        c.send("rec.arm", {"group": z2, "on": True})
        time.sleep(0.4)
        both = [z for z in c.send("input.list.midi_inputs")["zones"] if z["live"]]
        check("two zones on the same input: each has its hidden track", len(both) == 2, both)
        c.send("transport.seek", {"seconds": 9})
        c.send("rec.start")
        time.sleep(0.3)
        play(c, [(60, 0.5, 0.3, 100), (62, 1.0, 0.3, 100)])
        wait_pos(c, 11.6); settle_sent(c)
        r = c.send("rec.stop")
        by = {x["group"]: x for x in r["last_takes"]}
        check("one take per zone, both with the notes of the device", z1 in by and z2 in by
              and len(by[z2]["notes"]) == 2, by)
        check("z2's take starts at its window (10 s) with a handle for the note before it",
              near(by[z2]["start"], 10, 1e-3))
        c.send("rec.arm", {"group": z2, "on": False})
        c.send("rec.arm", {"group": z1, "on": False})

        # ── F ----------------------------------------------------------------------------------------
        section("F  no note, punch-in, held note, sustain pedal")
        z3 = make_zone(c, VID, 30, 40, 2)
        c.send("instrument.set", {"id": z3, **INST})
        c.send("rec.arm", {"group": z3, "on": True})
        c.send("transport.seek", {"seconds": 29})
        d0 = undo_depth(c)
        c.send("rec.start")
        wait_pos(c, 31.0)
        r = c.send("rec.stop")
        check("no note played: no take", r["last_takes"] == [] and kids(c, z3) == [], r["last_takes"])
        check("... and no undo point", undo_depth(c) == d0, (d0, undo_depth(c)))
        # punch-in: the transport is playing, the press is at ~31
        c.send("transport.seek", {"seconds": 29})
        c.send("transport.play")
        wait_pos(c, 30.0)
        c.send("rec.start")
        time.sleep(0.2)
        pos0 = play(c, [(60, 0.5, 0.4, 100), (64, 1.2, 0.4, 100)])
        wait_pos(c, pos0 + 2.2); settle_sent(c)
        r = c.send("rec.stop")
        tp = r["last_takes"][0]
        check("punch-in: a take with the 2 notes", len(tp["notes"]) == 2, tp)
        errs = [tp["start"] + n["start_beat"] * SPB - (pos0 + on) for n, on in zip(tp["notes"], (0.5, 1.2))]
        ERRS.extend(errs)
        check("punch-in timing within 0.1 s (errors %s ms)" % ["%.0f" % (e * 1000) for e in errs],
              all(abs(e) < 0.1 for e in errs), errs)
        # a note still held at the stop
        c.send("transport.seek", {"seconds": 33})
        c.send("rec.start")
        time.sleep(0.2)
        c.send("midi.virtual.send", {"events": [{"kind": "on", "note": 55, "velocity": 100, "delay_ms": 300}]})
        time.sleep(1.2)
        r = c.send("rec.stop")
        th = r["last_takes"][0] if r["last_takes"] else None
        check("a note held at the stop is CLOSED (a take with one note of positive length)",
              th is not None and len(th["notes"]) == 1 and th["notes"][0]["length_beats"] > 0, th)
        c.send("midi.virtual.send", {"events": [{"kind": "off", "note": 55}]})
        # sustain: note 0.3 s, the pedal is held 1.5 s -> the note lasts ~1.5 s
        c.send("transport.seek", {"seconds": 35})
        c.send("rec.start")
        time.sleep(0.2)
        c.send("midi.virtual.send", {"events": [
            {"kind": "cc", "note": 64, "velocity": 127, "delay_ms": 100},
            {"kind": "on", "note": 57, "velocity": 100, "delay_ms": 300},
            {"kind": "off", "note": 57, "velocity": 0, "delay_ms": 600},
            {"kind": "cc", "note": 64, "velocity": 0, "delay_ms": 1800}]})
        time.sleep(2.4)
        settle_sent(c)
        r = c.send("rec.stop")
        ts = r["last_takes"][0] if r["last_takes"] else None
        sl = ts["notes"][0]["length_beats"] * SPB if ts and ts["notes"] else None
        check("sustain pedal folded into the note duration (%s s ~ 1.5)" % (None if sl is None else round(sl, 2)),
              sl is not None and 1.2 < sl < 1.8, ts)
        c.send("rec.arm", {"group": z3, "on": False})

        # ── G ----------------------------------------------------------------------------------------
        section("G  mixed audio + MIDI recording")
        P = os.path.join(tmp, "pm")
        c.send("project.save_as", {"path": os.path.join(P, "pm.objekat")})
        r = c.send("rec.drop", {"inputs": [{"midi": VID}, {"first": 0}], "lane": 6, "time": 52.0, "visible_secs": 100})
        gm, ga = r["drops"][0]["group"], r["drops"][1]["group"]
        c.send("instrument.set", {"id": gm, **INST})
        c.send("rec.arm", {"groups": [gm, ga], "on": True})
        check("both zones armed", set(c.send("rec.status")["armed"]) >= {gm, ga})
        zst = zone_status(c, gm)
        c.send("transport.seek", {"seconds": 50})
        c.send("rec.start")
        time.sleep(0.3)
        pos0 = play(c, [(60, 0.5, 0.3, 100), (67, 1.0, 0.3, 100)])
        wait_pos(c, 53.5); settle_sent(c)
        r = c.send("rec.stop")
        by = {x["group"]: x for x in r["last_takes"]}
        check("two takes: a MIDI one and an audio one", gm in by and ga in by and by[gm]["source"] == "midi"
              and by[ga]["source"] == "audio", r["last_takes"])
        check("the audio take has its file, the MIDI one none",
              by[ga]["path"].endswith(".wav") and os.path.exists(by[ga]["path"]) and by[gm]["path"] == "", by)
        check("the MIDI take has its 2 notes", len(by[gm]["notes"]) == 2)
        rec = os.path.join(P, "samples", "rec")
        check("samples/rec holds ONE file", os.path.isdir(rec) and len(os.listdir(rec)) == 1, os.listdir(rec) if os.path.isdir(rec) else None)
        c.send("rec.arm", {"groups": [gm, ga], "on": False})


        # ── J ----------------------------------------------------------------------------------------
        # The former section J measured the latency between the sound HEARD live (loopback) and the instant recorded,
        # through the zone's instrument on its hidden track. Since format 36 arming is not hearing: the live path is the
        # INPUT's own instrument (docs/plan_groupes_midi.md, E8-E10), whose scenario takes this measure over.

        # ── H ----------------------------------------------------------------------------------------
        section("H  refusals, the file, reading it back")
        plain = c.send("rec.drop", {"first": 1, "lane": 9, "time": 5.0})["group"]
        c.send("rec.assign", {"group": plain})
        check("rec.arm on a group with no input is refused", refused(c, "rec.arm", group=plain, on=True) == "invalid_state")
        check("instrument.set on a group that is not a MIDI zone is ACCEPTED (any group may host an instrument)",
              c.send("instrument.set", {"id": plain, **INST})["instrument"]["name"] == "DLSMusicDevice")
        c.send("instrument.remove", {"id": plain})
        check("rec.assign midi with an unknown id is not_found", refused(c, "rec.assign", group=gm, midi="nope") == "not_found")
        check("midi.virtual.send with no event is refused", refused(c, "midi.virtual.send", events=[]) == "bad_params")
        check("midi.virtual.send with a bad kind is refused",
              refused(c, "midi.virtual.send", events=[{"kind": "zz", "note": 60}]) == "bad_params")
        c.send("project.save")
        path = os.path.join(P, "pm.objekat")
        raw = ""
        for dp, _, fs in os.walk(P):
            for f in fs:
                if f.endswith(".json") or f.endswith(".objekat") or f.endswith(".objekat.json"):
                    try:
                        raw += open(os.path.join(dp, f), errors="ignore").read()
                    except OSError:
                        pass
        check("the file is session format 36", "OBJEKAT session — format 36." in raw)
        check("... with recordMidiInput on the zone", '"recordMidiInput"' in raw)
        check("... and the zone's instrument under zoneInstruments", '"zoneInstruments"' in raw)
        c.send("project.open", {"path": path})
        zs = zone_status(c, gm)
        check("reopened: the zone is still a MIDI zone on the same input, with its instrument",
              zs is not None and zs["source"] == "midi" and zs["midi_input"]["id"] == VID
              and zs["instrument"] is not None and zs["instrument"]["name"] == "DLSMusicDevice", zs)
        check("... and it can be armed again", refused(c, "rec.arm", group=gm, on=True) is None)

    # ── I ------------------------------------------------------------------------------------------------
    section("I  Settings.xml")
    after = digest()
    check("Settings.xml is byte for byte what it was", before == after, (before, after))
    if ERRS:
        print("\n  timing error, note start vs what was played: mean %+.0f ms, min %+.0f, max %+.0f (n=%d)"
              % (1000 * sum(ERRS) / len(ERRS), 1000 * min(ERRS), 1000 * max(ERRS), len(ERRS)))
finally:
    proc.terminate()
    try:
        proc.wait(15)
    except Exception:
        proc.kill()
    if os.path.exists(SOCK):
        os.remove(SOCK)

print("\n%d ok, %d fail" % (ok, ko))
sys.exit(1 if ko else 0)

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Recording (`rec.start|stop`, the transport's record button), on the virtual card.

Armed zones record the INPUTS they carry: one 32-bit float WAV per input and per take in
`<project>/samples/rec/`, shared by every zone armed on that input. When the recording ends each zone
receives a take (a child of the group, `RecordTakePlanner`): the file cropped to the zone's window with
HANDLES, on the TOP lane of the zone (the newest on top, the older takes go down by one lane), the
previous takes being muted whole in the default "mute" take mode; all of it in ONE undo point.
Driven on `--virtual-audio` (4 inputs, a known signal on each; real time: the scenario takes a minute).

  A  one zone: file name, WAV header (format 3, 32 bits, 48 kHz), sine content, handles (the file is
     longer than the object, the object's source offset points into it), the edge can be pulled out
  B  two zones on one input = ONE file; two inputs with the same name -> " (2)"; the previous take of a
     zone is muted, the new one is on the lane ABOVE it (the older goes down); ONE undo point (undo brings
     everything back, lanes included)
  C  a take that does not cross the zone's window: the object exists (whole capture, in the grey area,
     on top), the previous take is NOT muted
  B2 the previous takes are muted when the recording STARTS (during the recording, in the same undo point
     as the take: one undo brings everything back); not when the press is past the window's end; a
     capture that stops before the window gives them back (one undo point either way); the red block of the take in
     progress (`rec.status` recording_start / progress): the window's part up to the head, on the lane
     the take will land on (the top one)
  T  the TAKE MODE of a zone ("mute" / "add"): `rec.set_take_mode` on one then on SEVERAL zones (one undo
     point), refusals (a clip, a bad mode, an unknown group: nothing changes), two zones on the SAME input
     one in each mode over three takes (add: nothing muted, all audible; lanes newest on top; ONE undo
     brings back the lanes too), the mode saved in the file (absent for "mute", format 34) and read back,
     `rec.assign` refused while recording, the red block on the top lane
  D  stereo pairs 1-2 and 2-3 share the channel 2: identical sample for sample in both files
  E  punch-in during playback (no graph rebuild at the press); a tab switch and a project replacement are
     refused while recording; unsaved project / nothing armed: refused
  E2 the stereo pairs are FIXED while recording: input.pair / unpair / set_pairs -> invalid_state, the
     recording goes on, rec.stop gives the takes and the files; accepted again once stopped
  F  CALIBRATION (every take also with the main thread stalled 100 ms after the start, engine patch 0048): loopback of the
     virtual card, an impulse played at t = 1.000 s must be recorded at
     1.000 s once the file's position on the timeline is applied: to the SAMPLE (error 0, +-1 at most),
     for the buffer sizes 64 / 128 / 256 / 512 / 1024, 4 takes started cold (seek 0, rec.start) and 4
     punched in during playback (play from 0, rec.start at 0.2 s); ONE error value per size. The card
     announces its latencies the way CoreAudio does (buffers included): their sum is the loopback delay
  F2 same, with a 20 ms latency plugin on the Main (bs 256, 3 cold + 3 punch-in, stalled or not)
  R  ROBUSTNESS of the take against a main thread that is late (engine patch 0048, "the record cuts itself after one
     block"): `rec.start {debug_stall_ms}` keeps the main thread busy right after the take has started; whatever the
     stall (0 / 15 / 30 / 60 / 100 / 250 ms), cold or punched in, at bs 512 and 64 (and 128 / 256 / 1024 at 0 and 100 ms),
     the take must last as long as the recording (not one block), the engine must report ONE start, ONE stop and ONE
     `recordingFinished` per input (no restart, none before `rec.stop`), the BWAV time reference (`bext`) is the press
     (exact when cold); 10 quick 2 s record / stop cycles in the "mute" mode: no take under 0.5 s; a device-change
     broadcast that changes nothing (`audio.debug.broadcast_change`) does not end the recording
  H  the buffer size changes during a recording: clean stop, the take is kept, the file is valid
  G  Settings.xml is byte for byte what it was

Settings.xml is only READ (hash). Run on the virtual card ONLY.

    ./scenario_record.py /path/to/objekat.app

Exit: 0 if every assertion passes, 1 if one fails, 2 on bad usage.
"""

import hashlib, json, math, os, re, shutil, struct, subprocess, sys, tempfile, time, wave

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
SR = 48000
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


def undo_depth(c):
    return c.send("perf.census")["undo_depth"]


def read_wav(path):
    """(format tag, channels, sample rate, bits, float32 data [frames, channels])."""
    with open(path, "rb") as f:
        raw = f.read()
    assert raw[:4] == b"RIFF" and raw[8:12] == b"WAVE", "not a RIFF/WAVE"
    pos, fmt, data = 12, None, None
    while pos + 8 <= len(raw):
        cid, size = raw[pos:pos + 4], struct.unpack("<I", raw[pos + 4:pos + 8])[0]
        body = raw[pos + 8:pos + 8 + size]
        if cid == b"fmt ":
            tag, ch, sr, _, _, bits = struct.unpack("<HHIIHH", body[:16])
            if tag == 0xFFFE and len(body) >= 26:
                tag = struct.unpack("<H", body[24:26])[0]
            fmt = (tag, ch, sr, bits)
        elif cid == b"data":
            data = body
        pos += 8 + size + (size & 1)
    tag, ch, sr, bits = fmt
    arr = np.frombuffer(data[:len(data) // 4 * 4], dtype="<f4").reshape(-1, ch) if tag == 3 else None
    return tag, ch, sr, bits, arr


def rec_files(folder):
    d = os.path.join(folder, "samples", "rec")
    return sorted(os.listdir(d)) if os.path.isdir(d) else []


def wait_pos(c, t, timeout=30):
    end = time.time() + timeout
    while time.time() < end:
        if c.send("transport.state")["position"] >= t:
            return True
        time.sleep(0.05)
    return False


def make_zone(c, first, start, end, lane, count=1):
    c.send("timesel.set", {"start": start, "end": end, "lanes": [lane]})
    r = c.send("rec.drop", {"first": first, "count": count, "lane": lane, "time": (start + end) / 2})
    c.send("timesel.clear")
    assert r["outcome"] == "create", r
    return r["group"]


def kids(c, gid):
    """The direct children of a group, by lane (they are listed once the group is open)."""
    c.send("group.expand", {"id": gid, "expanded": True})
    out = [o for o in c.send("object.list")["objects"] if o["parent"] == gid]
    c.send("group.expand", {"id": gid, "expanded": False})     # the lanes below must stay where they were
    return sorted(out, key=lambda o: o["lane"])


def get_child(c, gid, oid):
    c.send("group.expand", {"id": gid, "expanded": True})
    try:
        return c.send("object.get", {"id": oid})
    finally:
        c.send("group.expand", {"id": gid, "expanded": False})


def sine_rms_ok(x, amp, tol=0.06):
    """x is a sine of amplitude amp: peak and RMS agree."""
    return abs(float(np.max(np.abs(x))) - amp) < tol * max(amp, 0.1) + 0.01 \
        and abs(float(np.sqrt(np.mean(x ** 2))) - amp / math.sqrt(2)) < tol * amp + 0.01


def new_project(c, tmp, name):
    c.send("project.new")
    path = os.path.join(tmp, name, name + ".objekat")
    c.send("project.save_as", {"path": path})
    return os.path.join(tmp, name)


def read_tref(path):
    """The BWAV time reference (`bext`, samples) of a WAV file, or None."""
    with open(path, "rb") as f:
        raw = f.read()
    pos = 12
    while pos + 8 <= len(raw):
        cid, size = raw[pos:pos + 4], struct.unpack("<I", raw[pos + 4:pos + 8])[0]
        if cid == b"bext":
            return struct.unpack("<Q", raw[pos + 8 + 338:pos + 8 + 346])[0]
        pos += 8 + size + (size & 1)
    return None


def rec_log(mark=0):
    """The `[REC]` lines the engine traced into stderr from byte offset `mark` -> (lines, new offset)."""
    try:
        with open(ERR, errors="ignore") as f:
            f.seek(mark)
            txt = f.read()
            return [l for l in txt.splitlines() if "[REC]" in l], mark + len(txt.encode("utf-8", "ignore"))
    except OSError:
        return [], mark


before = digest()
SOCK = "/tmp/objk-rec-%d.sock" % os.getpid()
if os.path.exists(SOCK):
    os.remove(SOCK)
tmp = tempfile.mkdtemp(prefix="objk-rec-")
ERR = os.path.join(tmp, "app.err")
proc = subprocess.Popen([BIN, "--headless", "--api", "--no-recent", "--language=en", "--virtual-audio",
                         "--socket=" + SOCK], stdout=subprocess.DEVNULL, stderr=open(ERR, "w"))


def rebuilds():
    try:
        return open(ERR, errors="ignore").read().count("[GRAPH] rebuild")
    except OSError:
        return 0


try:
    for _ in range(160):
        if os.path.exists(SOCK):
            break
        time.sleep(0.25)
    with ObjekatClient(SOCK) as c:
        c.send("project.new")
        c.send("input.enable")
        for ch, f, a in ((0, 440, 0.5), (1, 1000, 0.25), (2, 2000, 0.125)):
            c.send("audio.virtual.set_input", {"channel": ch, "signal": "sine", "frequency": f, "amplitude": a})
        c.send("audio.virtual.set_input", {"channel": 3, "signal": "silence"})

        # ── refusals before anything exists -----------------------------------------------------
        section("refusals: unsaved project, nothing armed, not recording")
        g0 = make_zone(c, 0, 2, 6, 0)
        c.send("rec.arm", {"group": g0, "on": True})
        st = c.send("rec.status")
        check("unsaved project: can_record is false", st["can_record"] is False and st["project_saved"] is False, st)
        check("unsaved project: rec.start refused", refused(c, "rec.start") == "invalid_state")
        check("rec.stop when not recording is refused", refused(c, "rec.stop") == "invalid_state")

        # ── A: one zone --------------------------------------------------------------------------
        section("A  one zone: file, header, content, handles")
        P = new_project(c, tmp, "p1")
        c.send("input.set_name", {"first": 0, "name": "Voix"})
        c.send("input.set_name", {"first": 1, "name": "Voix"})        # same name on purpose (B)
        za = make_zone(c, 0, 2, 6, 0)                                  # the zone: 2 -> 6 s on the card's input 1
        check("nothing armed: rec.start refused", refused(c, "rec.start") == "invalid_state")
        c.send("rec.arm", {"group": za, "on": True})
        check("armed + saved: can_record", c.send("rec.status")["can_record"] is True)
        c.send("transport.seek", {"seconds": 0})
        d0 = undo_depth(c)
        r = c.send("rec.start")
        check("rec.start: recording and playing", r["recording"] is True and c.send("transport.state")["playing"])
        check("a second rec.start is refused", refused(c, "rec.start") == "invalid_state")
        check("transport.play while recording changes nothing", c.send("transport.play") is not None
              and c.send("rec.status")["recording"] is True)
        wait_pos(c, 8.0)
        r = c.send("rec.stop")
        check("rec.stop: not recording any more, transport stopped",
              r["recording"] is False and not c.send("transport.state")["playing"])
        takes = r["last_takes"]
        check("one take, for the zone", len(takes) == 1 and takes[0]["group"] == za, takes)
        t = takes[0]
        files = rec_files(P)
        check("one file in samples/rec", len(files) == 1, files)
        check("named Voix AAAA-MM-JJ HH-MM-SS.wav",
              bool(files) and re.fullmatch(r"Voix \d{4}-\d{2}-\d{2} \d{2}-\d{2}-\d{2}\.wav", files[0]) is not None, files)
        tag, ch, sr, bits, arr = read_wav(os.path.join(P, "samples", "rec", files[0]))
        check("WAV header: format 3 (float), 32 bits, mono", tag == 3 and bits == 32 and ch == 1, (tag, bits, ch))
        check("... at the device rate (48 kHz)", sr == SR, sr)
        check("file path of the take = that file", os.path.basename(t["path"]) == files[0])
        flen = arr.shape[0] / sr
        check("the file holds the whole recording (8 s +- 0.3)", abs(flen - 8.0) < 0.3, flen)
        mid = arr[int(3 * sr):int(5 * sr), 0]
        check("content: a 0.5 sine, not silence", sine_rms_ok(mid, 0.5), (float(np.max(np.abs(mid))), float(np.sqrt(np.mean(mid ** 2)))))
        check("take: 2 -> 6 s (the window)", near(t["start"], 2, 1e-3) and near(t["duration"], 4, 1e-3), t)
        origin = t["start"] - t["source_offset"]
        check("HANDLES: the file starts before the take (offset ~ 2 s)", abs(t["source_offset"] - 2.0) < 0.1
              and flen > t["duration"] + 3.0, (t["source_offset"], flen))
        check("take on lane 0, inside the zone, nothing muted", t["lane"] == 0 and not t["outside_window"] and t["muted"] == [])
        check("rec.stop is ONE undo point", undo_depth(c) == d0 + 1, (d0, undo_depth(c)))
        ch_ = kids(c, za)
        check("the zone has the take as its child", len(ch_) == 1 and ch_[0]["id"] == t["object"], ch_)
        o = get_child(c, za, t["object"])
        check("object: start 2, duration 4, offset ~2", near(o["start"], 2, 1e-3) and near(o["duration"], 4, 1e-3)
              and abs(o["source_offset"] - t["source_offset"]) < 1e-6, o)
        c.send("group.expand", {"id": za, "expanded": True})
        c.send("object.trim", {"id": t["object"], "start": 1.0, "duration": 5.5})
        c.send("group.expand", {"id": za, "expanded": False})
        o2 = get_child(c, za, t["object"])
        check("EDGES PULLABLE: the left edge goes out to 1 s, the offset follows",
              near(o2["start"], 1.0, 1e-3) and near(o2["duration"], 5.5, 1e-3)
              and abs(o2["source_offset"] - (t["source_offset"] - 1.0)) < 1e-3, o2)
        c.send("edit.undo")
        c.send("edit.undo")
        check("undo x2: the zone is empty again", kids(c, za) == [])
        c.send("edit.redo")
        check("redo: the take is back", len(kids(c, za)) == 1)

        # ── B: two zones on one input, two inputs one name, the previous take muted -------------
        section("B  one file for two zones, \" (2)\", mute, lane order, one undo")
        zb = make_zone(c, 0, 4, 8, 1)                  # same input as za, an overlapping window
        zc = make_zone(c, 1, 2, 6, 2)                  # the other input, named "Voix" too
        c.send("rec.arm", {"group": zb, "on": True})
        c.send("rec.arm", {"group": zc, "on": True})
        c.send("transport.seek", {"seconds": 0})
        d0 = undo_depth(c)
        c.send("rec.start")
        wait_pos(c, 9.0)
        r = c.send("rec.stop")
        takes = {t["group"]: t for t in r["last_takes"]}
        check("three takes (za, zb, zc)", len(takes) == 3 and za in takes and zb in takes and zc in takes, r["last_takes"])
        files2 = [f for f in rec_files(P) if f not in files]
        check("two NEW files only (one per input, not one per zone)", len(files2) == 2, files2)
        bases = sorted(files2)
        check("same name on two inputs: the second one is \" (2)\"",
              any(re.fullmatch(r"Voix \d{4}-\d{2}-\d{2} \d{2}-\d{2}-\d{2}\.wav", f) for f in bases)
              and any(re.fullmatch(r"Voix \d{4}-\d{2}-\d{2} \d{2}-\d{2}-\d{2} \(2\)\.wav", f) for f in bases), bases)
        check("za and zb share the SAME file", takes[za]["path"] == takes[zb]["path"] != takes[zc]["path"])
        wa = read_wav(takes[za]["path"])
        wc = read_wav(takes[zc]["path"])
        check("input 1 carries its own signal (0.25 sine at 1 kHz), input 0 its own",
              sine_rms_ok(wc[4][int(3 * SR):int(5 * SR), 0], 0.25)
              and sine_rms_ok(wa[4][int(3 * SR):int(5 * SR), 0], 0.5))
        check("za: second take on the TOP lane (0), the first one muted",
              takes[za]["lane"] == 0 and len(takes[za]["muted"]) == 1, takes[za])
        ks = kids(c, za)
        check("za: lanes 0 (newest, audible, on top) then 1 (older, muted, gone down)",
              [k["lane"] for k in ks] == [0, 1] and [k["muted"] for k in ks] == [False, True]
              and ks[0]["id"] == takes[za]["object"], ks)
        check("zb, zc: first take of their zone, lane 0, no mute", takes[zb]["lane"] == 0 and takes[zc]["lane"] == 0
              and takes[zb]["muted"] == [] and takes[zc]["muted"] == [])
        check("the take is cropped to each window (zb 4 -> 8)", near(takes[zb]["start"], 4, 1e-3)
              and near(takes[zb]["duration"], 4, 1e-3) and abs(takes[zb]["source_offset"] - 4.0) < 0.1, takes[zb])
        check("ONE undo point for the whole stop", undo_depth(c) == d0 + 1, (d0, undo_depth(c)))
        c.send("edit.undo")
        ks = kids(c, za)
        check("undo: the new take is gone, the previous one is audible again AND back on lane 0",
              len(ks) == 1 and ks[0]["muted"] is False and ks[0]["lane"] == 0 and kids(c, zb) == [] and kids(c, zc) == [])
        c.send("edit.redo")
        ks = kids(c, za)
        check("redo: both takes, the older muted and below", [k["muted"] for k in ks] == [False, True]
              and [k["lane"] for k in ks] == [0, 1])
        c.send("rec.arm", {"group": za, "on": False})
        c.send("rec.arm", {"group": zb, "on": False})
        c.send("rec.arm", {"group": zc, "on": False})

        # ── C: a take outside the window ----------------------------------------------------------
        section("C  capture outside the zone's window")
        zd = make_zone(c, 2, 1, 3, 3)                  # input 3 of the card (2 kHz), window 1 -> 3 s
        c.send("rec.arm", {"group": zd, "on": True})
        c.send("transport.seek", {"seconds": 0})
        c.send("rec.start")
        wait_pos(c, 4.0)
        r1 = c.send("rec.stop")
        t1 = r1["last_takes"][0]
        check("first take inside the window", not t1["outside_window"] and near(t1["start"], 1, 1e-3))
        c.send("transport.seek", {"seconds": 6})
        c.send("rec.start")
        wait_pos(c, 8.0)
        r2 = c.send("rec.stop")
        t2 = r2["last_takes"][0]
        check("capture 6 -> 8 s, window 1 -> 3 s: an object exists, flagged outside", t2["outside_window"] is True, t2)
        check("... over the WHOLE capture (starts ~6 s, ~2 s long, offset 0)",
              abs(t2["start"] - 6) < 0.15 and abs(t2["duration"] - 2) < 0.2 and near(t2["source_offset"], 0), t2)
        check("... and the previous take is NOT muted", t2["muted"] == [], t2)
        ks = kids(c, zd)
        check("the zone holds both, none muted, the new one on top",
              [k["lane"] for k in ks] == [0, 1] and [k["muted"] for k in ks] == [False, False]
              and ks[0]["id"] == t2["object"] and ks[1]["id"] == t1["object"], ks)
        c.send("rec.arm", {"group": zd, "on": False})

        # ── B2: the previous takes are muted when the recording STARTS ------------------------------
        section("B2 previous takes muted at the press, red block, one undo point, stop before the window")
        Pm = new_project(c, tmp, "pm")
        zm = make_zone(c, 0, 1, 5, 0)                  # window 1 -> 5 s
        c.send("rec.arm", {"group": zm, "on": True})
        c.send("transport.seek", {"seconds": 0})
        d0 = undo_depth(c)
        c.send("rec.start")
        check("no previous take: nothing to mute, no undo point at the press", undo_depth(c) == d0)
        wait_pos(c, 6.0)
        t1 = c.send("rec.stop")["last_takes"][0]
        check("first take: nothing muted, ONE undo point", t1["muted"] == [] and undo_depth(c) == d0 + 1, t1)

        def zone_row(gid):
            return [o for o in c.send("object.list")["objects"] if o["id"] == gid][0]["display_lane"]

        c.send("transport.seek", {"seconds": 0})
        d1 = undo_depth(c)
        c.send("rec.start")
        time.sleep(0.4)
        ks = kids(c, zm)
        check("rec.start: the previous take is muted AT ONCE (during the recording)",
              len(ks) == 1 and ks[0]["id"] == t1["object"] and ks[0]["muted"] is True, ks)
        check("... in ONE undo point pushed by the press", undo_depth(c) == d1 + 1, (d1, undo_depth(c)))
        check("... and pushed one lane DOWN, so that the lane of the take being made is empty (L9)",
              ks[0]["lane"] == 1, ks)
        st = c.send("rec.status")
        check("rec.status: recording_start = the press (0 s)", near(st["recording_start"], 0, 0.05), st["recording_start"])
        check("... the head has not reached the window: no red block yet", st["progress"] == [], st["progress"])
        wait_pos(c, 3.0)
        st = c.send("rec.status")
        gd = zone_row(zm)
        pr = st["progress"]
        check("red block: the zone's window from its start (1 s) to the head (~3 s)",
              len(pr) == 1 and pr[0]["group"] == zm and near(pr[0]["start"], 1, 1e-6) and 2.9 < pr[0]["end"] < 3.6, pr)
        check("... on the zone's own row while it is closed", len(pr) == 1 and pr[0]["lane"] == gd, (pr, gd))
        c.send("group.expand", {"id": zm, "expanded": True})
        pr = c.send("rec.status")["progress"]
        check("... on the TOP lane once the zone is open (zone row + 1: the previous take goes down at the stop)",
              len(pr) == 1 and pr[0]["lane"] == zone_row(zm) + 1, (pr, zone_row(zm)))
        c.send("group.expand", {"id": zm, "expanded": False})
        wait_pos(c, 5.6)
        pr = c.send("rec.status")["progress"]
        check("... bounded to the window's end (5 s)", len(pr) == 1 and near(pr[0]["end"], 5, 1e-6), pr)
        r = c.send("rec.stop")
        t2 = r["last_takes"][0]
        check("rec.stop: no block any more, no start", c.send("rec.status")["progress"] == []
              and c.send("rec.status")["recording_start"] is None)
        check("new take on the top lane, reporting the take muted at the press",
              t2["lane"] == 0 and t2["muted"] == [t1["object"]], t2)
        check("... the press and the stop make ONE undo point", undo_depth(c) == d1 + 1, (d1, undo_depth(c)))
        ks = kids(c, zm)
        check("lanes 0 (audible, newest) then 1 (muted, older)", [k["muted"] for k in ks] == [False, True]
              and [k["lane"] for k in ks] == [0, 1]
              and ks[0]["id"] == t2["object"] and ks[1]["id"] == t1["object"], ks)
        c.send("edit.undo")
        ks = kids(c, zm)
        check("ONE undo: the new take is gone AND the previous one is audible again, back on lane 0",
              len(ks) == 1 and ks[0]["muted"] is False and ks[0]["lane"] == 0 and undo_depth(c) == d1, ks)
        c.send("edit.redo")
        ks = kids(c, zm)
        check("redo: both takes, the older muted and below", [k["muted"] for k in ks] == [False, True], ks)

        # pressed past the window's end: the audible take is left alone
        c.send("transport.seek", {"seconds": 6})
        d2 = undo_depth(c)
        c.send("rec.start")
        time.sleep(0.4)
        ks = kids(c, zm)
        check("pressed past the window's end: nothing muted, no undo point at the press",
              [k["muted"] for k in ks] == [False, True] and undo_depth(c) == d2, (ks, d2, undo_depth(c)))
        wait_pos(c, 7.5)
        check("... and no red block (the head is outside the window)", c.send("rec.status")["progress"] == [])
        t3 = c.send("rec.stop")["last_takes"][0]
        ks = kids(c, zm)
        check("... the take outside the window mutes nothing either",
              t3["outside_window"] is True and t3["muted"] == [] and [k["muted"] for k in ks] == [False, False, True]
              and ks[0]["id"] == t3["object"], (t3, ks))
        c.send("edit.undo")
        check("... undo removes it", len(kids(c, zm)) == 2 and undo_depth(c) == d2)

        # stopped before the window: the capture does not cross it, so the mute of the press is given back
        c.send("transport.seek", {"seconds": 0})
        d3 = undo_depth(c)
        c.send("rec.start")
        time.sleep(0.4)
        ks = kids(c, zm)
        check("press at 0, window at 1 s: the audible take is muted during the recording",
              [k["muted"] for k in ks] == [True, True] and undo_depth(c) == d3 + 1, (ks, d3, undo_depth(c)))
        check("... both previous takes one lane down during it (L9)", [k["lane"] for k in ks] == [1, 2], ks)
        wait_pos(c, 0.7)
        t4 = c.send("rec.stop")["last_takes"]
        ks = kids(c, zm)
        check("stop at 0.7 s (before the window): the take is outside, the previous ones are audible again",
              len(t4) == 1 and t4[0]["outside_window"] is True and t4[0]["muted"] == []
              and [k["muted"] for k in ks] == [False, False, True] and ks[0]["id"] == t4[0]["object"], (t4, ks))
        check("... lanes 0, 1, 2 at the stop: the shift of the press was the one the take needed (L9)",
              [k["lane"] for k in ks] == [0, 1, 2], ks)
        check("... still ONE undo point, and undo brings the muted state back", undo_depth(c) == d3 + 1)
        c.send("edit.undo")
        ks = kids(c, zm)
        check("... undo: the new take is gone, as before the press", len(ks) == 2 and [k["muted"] for k in ks] == [False, True]
              and [k["lane"] for k in ks] == [0, 1] and undo_depth(c) == d3, ks)
        c.send("rec.arm", {"group": zm, "on": False})

        # ── T: the take mode of a zone ----------------------------------------------------------------
        section("T  take mode: mute / add, newest on top, several zones at once, saved, assign refused while recording")
        c.send("audio.virtual.set_input", {"channel": 0, "signal": "sine", "frequency": 440, "amplitude": 0.5})
        Pt = new_project(c, tmp, "pt")
        zmu = make_zone(c, 0, 1, 5, 0)                 # the default mode
        zad = make_zone(c, 0, 1, 5, 1)                 # the same input, same window; will be set to "add"
        zad2 = make_zone(c, 1, 1, 5, 2)                # another zone for the multi-setting
        modes = lambda: {z["id"]: z["take_mode"] for z in c.send("rec.status")["zones"]}
        check("rec.status: every zone starts in \"mute\"", set(modes().values()) == {"mute"} and len(modes()) == 3, modes())
        d0 = undo_depth(c)
        r = c.send("rec.set_take_mode", {"group": zad, "mode": "add"})
        check("set_take_mode (one group): the zone is \"add\", the others untouched",
              modes()[zad] == "add" and modes()[zmu] == "mute" and modes()[zad2] == "mute", modes())
        check("... ONE undo point", undo_depth(c) == d0 + 1, (d0, undo_depth(c)))
        c.send("rec.set_take_mode", {"group": zad, "mode": "add"})
        check("... the same mode again changes nothing: no undo point", undo_depth(c) == d0 + 1)
        c.send("edit.undo")
        check("undo: back to \"mute\"", modes()[zad] == "mute" and undo_depth(c) == d0, modes())
        c.send("edit.redo")
        check("redo: \"add\" again", modes()[zad] == "add")

        d1 = undo_depth(c)
        c.send("rec.set_take_mode", {"groups": [zmu, zad2, zad], "mode": "add"})
        check("set_take_mode (several groups): the two that were in \"mute\" change, ONE undo point",
              set(modes().values()) == {"add"} and undo_depth(c) == d1 + 1, (modes(), d1, undo_depth(c)))
        c.send("edit.undo")
        check("... ONE undo gives the two back (the third was already \"add\")",
              modes()[zmu] == "mute" and modes()[zad2] == "mute" and modes()[zad] == "add", modes())
        check("... and the undo stack is where it was", undo_depth(c) == d1, (d1, undo_depth(c)))

        # refusals: nothing moves, not even for the valid ones in the list
        bip = os.path.join(tmp, "bip.wav")
        with wave.open(bip, "wb") as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
            w.writeframes((np.sin(np.arange(SR) * 2 * math.pi * 1000 / SR) * 8000).astype("<i2").tobytes())
        c.send("object.add", {"path": bip, "lane": 6, "start": 20})
        c.send("wait_idle", {"timeout_ms": 5000})
        clip_id = [o["id"] for o in c.send("object.list")["objects"] if o["kind"] != "group" and o["display_lane"] == 6][0]
        d2 = undo_depth(c)
        check("a clip is not a recording zone: refused (invalid_state)",
              refused(c, "rec.set_take_mode", group=clip_id, mode="add") == "invalid_state")
        check("a list holding a clip: refused, and the VALID zone in it is left alone",
              refused(c, "rec.set_take_mode", groups=[zmu, clip_id], mode="add") == "invalid_state"
              and modes()[zmu] == "mute" and undo_depth(c) == d2, modes())
        check("a bad mode: bad_params", refused(c, "rec.set_take_mode", group=zmu, mode="overdub") == "bad_params")
        check("an unknown group: not_found",
              refused(c, "rec.set_take_mode", group="00000000-0000-0000-0000-000000000000", mode="add") == "not_found")
        check("neither group nor groups: bad_params", refused(c, "rec.set_take_mode", mode="add") == "bad_params")
        check("an empty list: refused", refused(c, "rec.set_take_mode", groups=[], mode="add") is not None)
        check("none of the refusals pushed an undo point or moved a zone", undo_depth(c) == d2 and modes()[zad] == "add")

        # three takes on the same input: zmu (mute) and zad (add) side by side
        c.send("rec.arm", {"group": zmu, "on": True})
        c.send("rec.arm", {"group": zad, "on": True})
        order = {zmu: [], zad: []}                                     # the takes, oldest first
        for n in (1, 2, 3):
            c.send("transport.seek", {"seconds": 0})
            dN = undo_depth(c)
            c.send("rec.start")
            if n == 2:
                time.sleep(0.4)
                kz = kids(c, zad)
                check("rec.start (add): nothing of this zone is muted at the press", all(k["muted"] is False for k in kz), kz)
                kz = kids(c, zmu)
                check("rec.start (mute): its previous take IS muted at the press", all(k["muted"] is True for k in kz), kz)
                c.send("group.expand", {"id": zad, "expanded": True})
                wait_pos(c, 2.5)
                pr = {b["group"]: b for b in c.send("rec.status")["progress"]}
                check("the red block of each zone is on its TOP lane (zone row + 1) in both modes",
                      zad in pr and pr[zad]["lane"] == [o for o in c.send("object.list")["objects"] if o["id"] == zad][0]["display_lane"] + 1,
                      pr)
                c.send("group.expand", {"id": zad, "expanded": False})
                # the zone's input is frozen at the press
                before_assign = [z["input"] for z in c.send("rec.status")["zones"] if z["id"] == zmu]
                check("rec.assign during a recording: invalid_state", refused(c, "rec.assign", group=zmu, first=1) == "invalid_state")
                check("... the zone keeps its input", [z["input"] for z in c.send("rec.status")["zones"] if z["id"] == zmu] == before_assign)
                check("rec.set_take_mode during a recording is accepted (counts from the next press)",
                      refused(c, "rec.set_take_mode", group=zad2, mode="mute") is None)
            wait_pos(c, 6.0)
            r = c.send("rec.stop")
            tk = {t["group"]: t for t in r["last_takes"]}
            check("take %d: one per zone, both on lane 0 (the top)" % n,
                  len(tk) == 2 and tk[zmu]["lane"] == 0 and tk[zad]["lane"] == 0, r["last_takes"])
            check("take %d: ONE undo point" % n, undo_depth(c) == dN + 1, (dN, undo_depth(c)))
            order[zmu].append(tk[zmu]["object"]); order[zad].append(tk[zad]["object"])
            if n > 1:
                check("take %d: the \"mute\" zone reports the take(s) it muted, the \"add\" zone none" % n,
                      len(tk[zmu]["muted"]) == 1 and tk[zad]["muted"] == [], (tk[zmu]["muted"], tk[zad]["muted"]))
        kmu, kad = kids(c, zmu), kids(c, zad)
        newest_first = lambda ids: list(reversed(ids))
        check("\"mute\" zone: lanes 0, 1, 2 read newest, middle, oldest", [k["lane"] for k in kmu] == [0, 1, 2]
              and [k["id"] for k in kmu] == newest_first(order[zmu]), kmu)
        check("\"add\" zone: the same order", [k["lane"] for k in kad] == [0, 1, 2]
              and [k["id"] for k in kad] == newest_first(order[zad]), kad)
        check("\"mute\": only the newest is audible", [k["muted"] for k in kmu] == [False, True, True], kmu)
        check("\"add\": all three stay audible", [k["muted"] for k in kad] == [False, False, False], kad)
        c.send("edit.undo")                                            # the third take, in both zones: ONE point
        kmu, kad = kids(c, zmu), kids(c, zad)
        check("ONE undo of the third recording: both zones are back to two takes, lanes 0 and 1",
              [k["lane"] for k in kmu] == [0, 1] and [k["lane"] for k in kad] == [0, 1]
              and [k["id"] for k in kmu] == newest_first(order[zmu][:2]) and [k["id"] for k in kad] == newest_first(order[zad][:2]),
              (kmu, kad))
        check("... mute zone: the newest of the two audible, the older muted; add zone: both audible",
              [k["muted"] for k in kmu] == [False, True] and [k["muted"] for k in kad] == [False, False], (kmu, kad))
        c.send("rec.arm", {"group": zmu, "on": False})
        c.send("rec.arm", {"group": zad, "on": False})

        # the file: "add" is written, "mute" is the absence of the key
        c.send("project.save")
        ptfile = [f for f in os.listdir(Pt) if f.endswith(".objekat")][0]
        doc = json.load(open(os.path.join(Pt, ptfile)))
        items = {i["id"]: i for i in doc["items"]}
        check("saved: format 37", doc.get("version") == 37, doc.get("version"))
        check("saved: the \"add\" zone carries recordTakeMode add", items[zad].get("recordTakeMode") == "add", items.get(zad, {}).keys())
        check("saved: the \"mute\" zone carries NO key", "recordTakeMode" not in items[zmu], items[zmu].keys())
        check("saved: the _readme describes the key", any("recordTakeMode" in line for line in doc.get("_readme", [])))
        c.send("project.new")
        c.send("project.open", {"path": os.path.join(Pt, ptfile)})
        mm = modes()
        check("reopened: the modes are back (add / mute / mute)", mm.get(zad) == "add" and mm.get(zmu) == "mute"
              and mm.get(zad2) == "mute", mm)
        old = json.load(open(os.path.join(Pt, ptfile)))
        for i in old["items"]:
            i.pop("recordTakeMode", None)
        old["version"] = 33
        oldp = os.path.join(Pt, "before34.objekat")
        json.dump(old, open(oldp, "w"))
        c.send("project.open", {"path": oldp})
        check("a format 33 file (no key anywhere) opens with every zone in \"mute\"", set(modes().values()) == {"mute"}, modes())

        # ── D: stereo pairs 1-2 and 2-3 ------------------------------------------------------------
        section("D  pairs 1-2 and 2-3: the shared channel is identical")
        P2 = new_project(c, tmp, "p2")
        c.send("input.pair", {"first": 0})
        c.send("input.pair", {"first": 1})
        zp = make_zone(c, 0, 1, 5, 0, count=2)
        zq = make_zone(c, 1, 1, 5, 1, count=2)
        c.send("rec.arm", {"group": zp, "on": True})
        c.send("rec.arm", {"group": zq, "on": True})
        check("both pairs armed", len(c.send("rec.status")["armed"]) == 2, c.send("rec.status"))
        c.send("transport.seek", {"seconds": 0})
        c.send("rec.start")
        wait_pos(c, 6.0)
        r = c.send("rec.stop")
        tk = {t["group"]: t for t in r["last_takes"]}
        check("two takes, two stereo files", len(tk) == 2 and len(rec_files(P2)) == 2, (r["last_takes"], rec_files(P2)))
        w12 = read_wav(tk[zp]["path"])
        w23 = read_wav(tk[zq]["path"])
        check("both files are stereo float32", w12[0] == 3 and w12[1] == 2 and w12[3] == 32
              and w23[0] == 3 and w23[1] == 2 and w23[3] == 32, (w12[:4], w23[:4]))
        n = min(w12[4].shape[0], w23[4].shape[0])
        check("files start together (same length +- 1 block)", abs(w12[4].shape[0] - w23[4].shape[0]) <= 512,
              (w12[4].shape[0], w23[4].shape[0]))
        # the channel 2 (index 1) is the right of 1-2 and the left of 2-3: same samples, same place
        same = np.array_equal(w12[4][:n, 1], w23[4][:n, 0])
        check("channel 2: identical SAMPLE FOR SAMPLE in both files", same,
              float(np.max(np.abs(w12[4][:n, 1] - w23[4][:n, 0]))))
        mid = slice(int(2 * SR), int(4 * SR))
        check("1-2 = (0.5 sine, 0.25 sine), 2-3 = (0.25 sine, 0.125 sine)",
              sine_rms_ok(w12[4][mid, 0], 0.5) and sine_rms_ok(w12[4][mid, 1], 0.25)
              and sine_rms_ok(w23[4][mid, 0], 0.25) and sine_rms_ok(w23[4][mid, 1], 0.125))
        c.send("rec.arm", {"group": zp, "on": False})
        c.send("rec.arm", {"group": zq, "on": False})
        c.send("input.unpair", {"first": 0})
        c.send("input.unpair", {"first": 1})

        # ── E: punch-in, tab switch ---------------------------------------------------------------
        section("E  punch-in during playback, nothing replaced while recording")
        P3 = new_project(c, tmp, "p3")
        ze = make_zone(c, 0, 0, 20, 0)
        c.send("rec.arm", {"group": ze, "on": True})
        c.send("transport.seek", {"seconds": 0})
        c.send("transport.play")
        wait_pos(c, 3.0)
        n0 = rebuilds()
        t_press = c.send("transport.state")["position"]
        c.send("rec.start")
        time.sleep(0.7)
        n1 = rebuilds()
        check("punch-in: the graph is NOT rebuilt at the press", n1 == n0, (n0, n1))
        check("a tab cannot be opened while recording", refused(c, "tab.new") is not None
              and len(c.send("tab.list")["tabs"]) == 1)
        check("the project cannot be replaced while recording", refused(c, "project.new") == "invalid_state")
        wait_pos(c, t_press + 2.5)
        r = c.send("rec.stop")
        t = r["last_takes"][0]
        check("punch-in: the take starts where the button was pressed (+-0.15 s)", abs(t["start"] - t_press) < 0.15, (t["start"], t_press))
        check("... lasts until the stop (2.5 s +- 0.3), offset 0", abs(t["duration"] - 2.5) < 0.3 and near(t["source_offset"], 0, 1e-3), t)
        tag, ch, sr, bits, arr = read_wav(t["path"])
        check("... the file holds just that (not the 3 s before)", abs(arr.shape[0] / sr - t["duration"]) < 0.05, arr.shape[0] / sr)
        check("a tab can be opened again after the stop", refused(c, "tab.new") is None)
        c.send("tab.close", {"discard": True})                         # the new tab (the active one)

        # ── E2: the stereo pairs are fixed while recording --------------------------------------------
        section("E2 pairing refused while recording (invalid_state), the take is not lost, accepted again after")
        P3b = new_project(c, tmp, "p3b")
        c.send("input.pair", {"first": 0})
        c.send("input.pair", {"first": 1})
        r = c.send("rec.drop", {"inputs": [{"first": 0, "count": 2}, {"first": 1, "count": 2}, {"first": 2}],
                                "lane": 0, "time": 0})
        grp = [d["group"] for d in r["drops"]]
        check("three zones dropped (2 pairs + 1 mono)", len(grp) == 3, r)
        for g in grp:
            c.send("rec.arm", {"group": g, "on": True})
        pairs_before = c.send("input.list")["pairs"]
        c.send("transport.seek", {"seconds": 0})
        c.send("rec.start")
        time.sleep(1.5)
        check("input.unpair refused during a recording (invalid_state)",
              refused(c, "input.unpair", first=1) == "invalid_state")
        check("input.pair refused during a recording (invalid_state)",
              refused(c, "input.pair", first=2) == "invalid_state")
        check("input.set_pairs refused during a recording (invalid_state)",
              refused(c, "input.set_pairs", pairs=[]) == "invalid_state")
        check("the pairs did not move", c.send("input.list")["pairs"] == pairs_before, c.send("input.list")["pairs"])
        check("the recording goes on", c.send("rec.status")["recording"] is True, c.send("rec.status"))
        time.sleep(1.0)
        r = c.send("rec.stop")
        lt = r["last_takes"]
        check("rec.stop gives the three takes", len(lt) == 3, lt)
        check("... and the three files exist on disk", len(rec_files(P3b)) == 3, rec_files(P3b))
        if len(lt) == 3:
            wavs = [read_wav(t["path"]) for t in lt]
            check("... valid float32 WAVs, at least 2 s long", all(w[0] == 3 and w[3] == 32 and w[4].shape[0] / w[2] >= 2.0 for w in wavs),
                  [(w[0], w[3], w[4].shape[0] / w[2]) for w in wavs])
        check("after the stop input.unpair is accepted again", refused(c, "input.unpair", first=1) is None
              and c.send("input.list")["pairs"] == [0])
        check("... input.pair too", refused(c, "input.pair", first=1) is None)
        check("... and input.set_pairs", refused(c, "input.set_pairs", pairs=[]) is None
              and c.send("input.list")["pairs"] == [])

        # ── F: CALIBRATION ---------------------------------------------------------------------------
        section("F  CALIBRATION: an impulse played at t = 1.000 s is recorded at 1.000 s (to the sample)")
        P4 = new_project(c, tmp, "p4")
        imp = os.path.join(tmp, "impulse.wav")
        with wave.open(imp, "wb") as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
            frames = np.zeros(3 * SR, dtype="<i2")
            frames[SR] = 26000                                            # sample 48000 = 1.000 s
            w.writeframes(frames.tobytes())
        c.send("object.add", {"path": imp, "lane": 5, "start": 0})
        c.send("wait_idle", {"timeout_ms": 5000})
        c.send("audio.virtual.set_input", {"channel": 0, "signal": "loopback"})
        zf = make_zone(c, 0, 0, 4, 0)
        c.send("rec.arm", {"group": zf, "on": True})

        def measure(mode, n, stall=0):
            """n takes of the impulse through the loopback. mode: "cold" (seek 0, rec.start) or "punch"
            (play from 0, rec.start at 0.2 s). `stall`: the main thread kept busy that many ms right after the
            take has started (the calibration must not depend on it: engine patch 0048). -> [(error in
            samples, peak, file origin on the timeline)]."""
            out = []
            for _ in range(n):
                c.send("transport.seek", {"seconds": 0})
                if mode == "punch":
                    c.send("transport.play")
                    wait_pos(c, 0.2)
                c.send("rec.start", {"debug_stall_ms": stall} if stall else None)
                wait_pos(c, 3.0)
                t = c.send("rec.stop")["last_takes"][0]
                tag, ch, sr, bits, arr = read_wav(t["path"])
                x = np.abs(arr[:, 0])
                i = int(np.argmax(x))
                # the file's first sample sits at (take start - source offset) on the timeline
                org = t["start"] - t["source_offset"]
                out.append((int(round((org + i / sr - 1.0) * sr)), float(x[i]), org))
                c.send("edit.undo")        # no replay of this take (it would come back through the loopback)
                time.sleep(1.1)            # a different file name each time
            return out

        def judge(tag, res, mode):
            errs = [e for e, _, _ in res]
            print("       %s: error in samples per take %s" % (tag, errs))
            for k, (e, pk, org) in enumerate(res):
                check("%s take %d: the impulse is back (peak > 0.1)" % (tag, k + 1), pk > 0.1, pk)
                check("%s take %d: error %+d sample(s), expected 0 (+-1)" % (tag, k + 1, e), abs(e) <= 1, e)
                if mode == "punch":
                    check("%s take %d: starts where it was pressed, before the impulse (%.3f s < 0.95 s)" % (tag, k + 1, org),
                          org < 0.95, org)
            return errs

        for bs in (64, 128, 256, 512, 1024):
            b = c.send("audio.set_buffer_size", {"frames": bs})
            time.sleep(0.5)
            vs = c.send("audio.virtual.status")
            check("bs %d: the card runs at it" % bs, vs.get("block_size") == bs and b["buffer_size"] == bs, (vs.get("block_size"), b))
            check("bs %d: announced in + out latency (%s + %s) = loopback_delay (%s)" %
                  (bs, vs.get("announced_input_latency"), vs.get("announced_output_latency"), vs.get("loopback_delay")),
                  vs.get("announced_input_latency", -1) + vs.get("announced_output_latency", -1) == vs.get("loopback_delay"), vs)
            check("bs %d: loopback_delay = 2*bs + 64 + 96" % bs, vs.get("loopback_delay") == 2 * bs + 160, vs.get("loopback_delay"))
            errs = []
            for stall in (0, 100):         # 100 ms: the main thread late for the engine's deferred update (0048)
                sfx = "" if stall == 0 else " stall %d" % stall
                errs += judge("bs %d cold%s" % (bs, sfx), measure("cold", 4, stall), "cold") \
                      + judge("bs %d punch-in%s" % (bs, sfx), measure("punch", 4, stall), "punch")
            check("bs %d: ONE error value over the 16 takes, stalled or not (%s)" % (bs, sorted(set(errs))), len(set(errs)) == 1, errs)
        c.send("audio.set_buffer_size", {"frames": 256})
        time.sleep(0.5)

        # ── F2: CALIBRATION with a declared latency on the Main --------------------------------------
        section("F2 CALIBRATION with a 20 ms latency plugin on the Main (bs 256)")
        main_id = c.send("stem.list")["main"]
        c.send("debug.add_test_plugin", {"host": main_id, "type": "latencyTester", "latency_ms": 20})
        c.send("wait_idle", {"timeout_ms": 5000})
        # The PDC resync (`checkLatencyAndRebuild`) re-reads the plugins' latency on a ~250 ms tick: a rec
        # pressed inside that window would still compensate the OLD latency (known, measured: +20 ms).
        time.sleep(1.0)
        errs2 = []
        for stall in (0, 100):
            sfx = "" if stall == 0 else " stall %d" % stall
            errs2 += judge("main latency cold%s" % sfx, measure("cold", 3, stall), "cold") \
                   + judge("main latency punch-in%s" % sfx, measure("punch", 3, stall), "punch")
        check("main latency: ONE error value over the 12 takes (%s)" % sorted(set(errs2)), len(set(errs2)) == 1, errs2)
        c.send("edit.undo")                                           # the test plugin

        # ── R: a main thread that is late must not cut the take ------------------------------------
        section("R  robustness: debug_stall_ms (main thread late), one take = one recording, tref = the press")
        P6 = new_project(c, tmp, "p6")
        c.send("audio.virtual.set_input", {"channel": 0, "signal": "sine", "frequency": 440, "amplitude": 0.5})
        zr = make_zone(c, 0, 0, 60, 0)
        c.send("rec.arm", {"group": zr, "on": True})

        def counts(lines):
            """How many times the engine told it: (aboutToStart, aboutToStop, finished with a clip, finished without)."""
            return (sum(" aboutToStart " in l for l in lines), sum(" aboutToStop " in l for l in lines),
                    sum(" finished " in l and "NO CLIP" not in l for l in lines), sum("NO CLIP" in l for l in lines))

        def take_run(mode, stall, dur=2.0, keep=False):
            """One take of `dur` s after the press, with the main thread stalled `stall` ms right after the start.
            -> dict(n, secs, wall, tref_err, bs, lines_before_stop, lines_after_stop)."""
            c.send("transport.seek", {"seconds": 0})
            if mode == "punch":
                c.send("transport.play")
                wait_pos(c, 0.5)
            _, mark = rec_log(0 if not hasattr(take_run, "mark") else take_run.mark)
            take_run.mark = mark
            t0 = time.time()
            r = c.send("rec.start", {"debug_stall_ms": stall} if stall else None)
            time.sleep(max(0.0, dur - (time.time() - t0)))                         # `dur` s after the call began
            during, mark = rec_log(take_run.mark)
            still = c.send("rec.status")["recording"]
            wall = time.time() - t0
            res = c.send("rec.stop")
            after, mark = rec_log(mark)
            take_run.mark = mark
            lt = res["last_takes"]
            out = dict(n=None, secs=None, wall=wall, tref_err=None, still=still, during=during, after=after, ok=bool(lt))
            if lt:
                t = lt[0]
                tag, ch, sr, bits, arr = read_wav(t["path"])
                tref = read_tref(t["path"])
                pressed = [float(re.search(r"pos=([0-9.]+)", l).group(1)) for l in during if " press:" in l]
                out.update(n=arr.shape[0], secs=arr.shape[0] / sr, sr=sr, tref=tref, press_pos=(pressed[0] if pressed else None),
                           origin=t["start"] - t["source_offset"])
                if tref is not None and pressed:
                    out["tref_err"] = tref - round(pressed[0] * sr)
            if not keep:
                c.send("edit.undo")
                time.sleep(1.05)
            return out

        def judge_run(label, mode, r, bs):
            check("%s: a take came out, 1 start / 0 stop before rec.stop" % label,
                  r["ok"] and counts(r["during"])[:3] == (1, 0, 0) and r["still"] is True, (r["ok"], counts(r["during"]), r["still"]))
            if not r["ok"]:
                return
            check("%s: ONE start, ONE stop, ONE clip for the input (no restart)" % label,
                  counts(r["during"] + r["after"]) == (1, 1, 1, 0), counts(r["during"] + r["after"]))
            slack = 0.05 + 3.0 * bs / r["sr"]
            check("%s: the take lasts as long as the recording (%.3f s vs %.3f s)" % (label, r["secs"], r["wall"]),
                  abs(r["secs"] - r["wall"]) < slack + 0.12, (r["secs"], r["wall"]))
            # Cold: the file starts EXACTLY at the press. Punched in: the position read at the press is the
            # transport's, and the first recorded block comes after the file is opened (aboutToStart is 5-15 ms
            # after the press in a Debug build), so the reference sits 0..~25 ms after it — never BEFORE it, and
            # never a restart's worth later (that one is caught by the single aboutToStart above).
            e = r["tref_err"]
            lo, hi = (-1, 1) if mode == "cold" else (-bs, int(0.05 * r["sr"]) + bs)
            check("%s: BWAV time reference = the press (err %s samples, allowed %d..%d)" % (label, e, lo, hi),
                  e is not None and lo <= e <= hi, e)

        grid = [(512, st) for st in (0, 15, 30, 60, 100, 250)] + [(64, st) for st in (0, 15, 30, 60, 100, 250)] \
             + [(bs_, st) for bs_ in (128, 256, 1024) for st in (0, 100)]
        errs_r = {}
        for bs_ in (512, 64, 128, 256, 1024):
            b = c.send("audio.set_buffer_size", {"frames": bs_})
            time.sleep(0.5)
            for mode in ("cold", "punch"):
                for st in [st for b2, st in grid if b2 == bs_]:
                    r = take_run(mode, st)
                    judge_run("bs %d %s stall %d ms" % (bs_, mode, st), mode, r, bs_)
                    errs_r[(bs_, mode, st)] = (r["secs"], r["tref_err"])
        print("       (bs, mode, stall) -> (take seconds, tref - press in samples):")
        for k_, v_ in errs_r.items():
            print("         %-22s %s" % (k_, v_))

        # 10 quick 2 s record / stop cycles in the "mute" mode (the takes pile up, the previous ones muted): none short.
        c.send("audio.set_buffer_size", {"frames": 512})
        time.sleep(0.5)
        durs = []
        for k_ in range(10):
            r = take_run("cold" if k_ % 2 == 0 else "punch", 0 if k_ % 3 else 60, keep=True)
            durs.append(r["secs"])
            time.sleep(0.3)
        print("       10 quick cycles (mute mode), take seconds: %s" % [None if d is None else round(d, 2) for d in durs])
        check("10 quick cycles: every take lasts >= 0.5 s (about 2 s)", all(d is not None and d > 1.5 for d in durs), durs)
        check("... in the mute mode: only the newest take is audible", sum(1 for k in kids(c, zr) if not k["muted"]) == 1,
              [(k["lane"], k["muted"]) for k in kids(c, zr)])

        # A device-change broadcast that changes nothing must not end the recording (the watcher compares the card).
        c.send("transport.seek", {"seconds": 0})
        _, mark = rec_log(0)
        t0 = time.time()
        c.send("rec.start")
        time.sleep(0.8)
        for _ in range(3):
            check("audio.debug.broadcast_change is accepted", refused(c, "audio.debug.broadcast_change") is None)
            time.sleep(0.4)
        time.sleep(0.6)
        lines, mark = rec_log(mark)
        wall = time.time() - t0
        check("a no-op device broadcast: still recording, transport playing",
              c.send("rec.status")["recording"] is True and c.send("transport.state")["playing"] is True)
        check("... the watcher kept the take (3 broadcasts seen, 3 decisions 'keep'), no stop",
              sum("keep recording" in l for l in lines) >= 3 and counts(lines)[1] == 0 and not any("STOP" in l for l in lines),
              [l[-90:] for l in lines if "device-change" in l])
        res = c.send("rec.stop")
        tk = res["last_takes"]
        check("... the take is whole (as long as the recording)", len(tk) == 1
              and abs(read_wav(tk[0]["path"])[4].shape[0] / SR - wall) < 0.3, (tk, wall))
        c.send("edit.undo")

        # ── H: the card changes during a recording -------------------------------------------------
        section("H  buffer size changed during a recording: clean stop, takes kept")
        P5 = new_project(c, tmp, "p5")
        c.send("audio.virtual.set_input", {"channel": 0, "signal": "sine", "frequency": 440, "amplitude": 0.5})
        zh = make_zone(c, 0, 0, 20, 0)
        c.send("rec.arm", {"group": zh, "on": True})
        c.send("transport.seek", {"seconds": 0})
        c.send("rec.start")
        wait_pos(c, 1.5)
        c.send("audio.set_buffer_size", {"frames": 128})
        deadline = time.time() + 10
        while time.time() < deadline and c.send("rec.status")["recording"]:
            time.sleep(0.1)
        st = c.send("rec.status")
        check("the recording stopped by itself", st["recording"] is False, st)
        check("... the transport stopped too", c.send("transport.state")["playing"] is False)
        lt = st["last_takes"]
        check("... the take is in the project", len(lt) == 1, lt)
        if lt:
            tag, ch, sr, bits, arr = read_wav(lt[0]["path"])
            check("... the file is a valid WAV holding the sine (>= 1 s)", arr.shape[0] / sr >= 1.0
                  and sine_rms_ok(arr[int(0.5 * sr):int(1.0 * sr), 0], 0.5), (arr.shape, sr))
        b = c.send("audio.set_buffer_size", {"frames": 256})
        check("the card is back to 256", b["buffer_size"] == 256, b)
        check("the project is not stuck: a new recording starts", refused(c, "rec.start") is None)
        c.send("rec.stop")

        # ── G: Settings.xml ---------------------------------------------------------------------------
        section("G  Settings.xml untouched")
        check("Settings.xml is byte for byte what it was", digest() == before, (before, digest()))
finally:
    proc.terminate()
    try:
        proc.wait(timeout=10)
    except Exception:
        proc.kill()
    if os.path.exists(SOCK):
        os.remove(SOCK)
    if ko == 0:
        shutil.rmtree(tmp, ignore_errors=True)
    else:
        print("\n(kept for inspection: %s)" % tmp)

print("\n%d OK, %d FAIL" % (ok, ko))
sys.exit(1 if ko else 0)

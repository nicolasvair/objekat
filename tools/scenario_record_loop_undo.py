#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""L8 of the 4 November 2026 feedback (docs/plan_retours_2026-11-04.md): a recording made THROUGH a loop is undone PASS BY PASS.

Headless, on the virtual card and the virtual MIDI input (`--virtual-audio --virtual-midi`), never a window. A zone [0, 60] on lane 0
records through a loop [1 s, 2 s] switched on from 0.5 s, so that one recording gives several takes (one per pass). Then:

  U1  AUDIO, "mute" mode. rec.stop leaves ONE undo point per pass (16 at most). One edit.undo takes the LAST pass away only: the
      previous pass is the top lane again, audible, the others muted, the lanes contiguous from 0. A second undo does the same
      with the pass before; edit.redo brings one back. As many undos as passes empty the zone.
  U2  The file is kept: the remaining top take can be pulled out into the matter the undone passes hold (object.trim accepted,
      longer).
  U3  AUDIO, "add" mode: the same undo, and every remaining take stays audible.
  U4  edit.undo / edit.redo during a recording answer invalid_state, and the recording still ends with its takes.
  U5  MIDI: the same undo pass by pass; the sequence is kept (outside the undo): the remaining top take, pulled out, reveals the
      notes of the passes that were undone.
  U6  A single-pass recording keeps ONE undo point.

    ./scenario_record_loop_undo.py /path/to/objekat.app

Exit: 0 if every assertion passes, 1 if one fails, 2 on bad usage.
"""

import os, subprocess, sys, tempfile, time

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


tmp = tempfile.mkdtemp(prefix="objk-loopundo-")
sock = "/tmp/objk-loopundo-%d.sock" % os.getpid()
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

N = 16          # MIDI notes, one every 200 ms


def new_project(c, name):
    c.send("project.new")
    c.send("project.save_as", {"path": os.path.join(tmp, name, name + ".objekat")})


def kids(c, gid):
    """The zone's direct children, top lane first (the group is left open: object.get reads the lane entries)."""
    c.send("group.expand", {"id": gid, "expanded": True})
    out = [o for o in c.send("object.list")["objects"] if o["parent"] == gid]
    return sorted(out, key=lambda o: o["lane"])


def undo_depth(c):
    return c.send("perf.census")["undo_depth"]


def audio_zone(c, mode):
    c.send("timesel.set", {"start": 0, "end": 60, "lanes": [0]})
    r = c.send("rec.drop", {"first": 0, "count": 1, "lane": 0, "time": 30})
    c.send("timesel.clear")
    gid = r["group"]
    if mode != "mute":
        c.send("rec.set_take_mode", {"group": gid, "mode": mode})
    c.send("rec.arm", {"group": gid, "on": True})
    return gid


def record_audio(c, seconds):
    c.send("debug.transport_loop", {"start": 1.0, "end": 2.0, "enabled": True})
    c.send("transport.seek", {"seconds": 0.5})
    c.send("rec.start")
    time.sleep(seconds)
    r = c.send("rec.stop")
    c.send("debug.transport_loop", {"enabled": False})
    return sorted(r["last_takes"], key=lambda t: t["pass"])


def lanes_contiguous(ks):
    return [k["lane"] for k in ks] == list(range(len(ks)))


def run_audio(c, mode, name):
    tag = "[%s]" % mode
    new_project(c, name)
    c.send("input.enable")
    gid = audio_zone(c, mode)
    d0 = undo_depth(c)
    tk = record_audio(c, 3.5)
    n = len(tk)
    steps = min(n, 16)
    check("%s several takes (one per pass): %d" % (tag, n), n >= 3, n)
    check("%s one undo point per pass (%d)" % (tag, steps), undo_depth(c) == d0 + steps, (d0, undo_depth(c), steps))
    ks = kids(c, gid)
    check("%s %d takes in the zone, lanes 0..%d" % (tag, n, n - 1), len(ks) == n and lanes_contiguous(ks), ks)
    check("%s the newest pass on the top lane" % tag, ks[0]["id"] == tk[-1]["object"], (ks[0]["id"], tk[-1]["object"]))

    c.send("edit.undo")
    ks = kids(c, gid)
    check("%s one undo: the LAST pass is gone, the others stay" % tag,
          len(ks) == n - 1 and [k["id"] for k in ks] == [t["object"] for t in reversed(tk[:-1])], [k["id"] for k in ks])
    check("%s the lanes are contiguous from 0" % tag, lanes_contiguous(ks), [k["lane"] for k in ks])
    if mode == "mute":
        check("%s the previous pass is the top lane again and AUDIBLE, the others muted" % tag,
              [k["muted"] for k in ks] == [False] + [True] * (len(ks) - 1), [k["muted"] for k in ks])
    else:
        check("%s every take stays audible" % tag, all(not k["muted"] for k in ks), [k["muted"] for k in ks])

    c.send("edit.undo")
    ks = kids(c, gid)
    check("%s a second undo: one more pass gone, lanes contiguous" % tag, len(ks) == n - 2 and lanes_contiguous(ks), ks)
    if mode == "mute" and ks:
        check("%s ... and the top one audible" % tag, [k["muted"] for k in ks] == [False] + [True] * (len(ks) - 1))

    c.send("edit.redo")
    ks = kids(c, gid)
    check("%s a redo brings one pass back" % tag, len(ks) == n - 1 and lanes_contiguous(ks), len(ks))
    c.send("edit.undo")
    undone = 2
    if mode == "mute":
        # U2 — the FILE is kept: the remaining top take can be pulled out into the passes that were undone.
        top = kids(c, gid)[0]
        dur = top["duration"]
        r = c.send("object.trim", {"id": top["id"], "start": top["start"], "duration": dur + 0.4})
        check("%s the remaining top take is pulled out into the matter of the undone passes (room)" % tag,
              r["duration"] > dur + 0.2, (dur, r["duration"]))
        c.send("edit.undo")                                          # the trim's own point
    for _ in range(steps - undone):
        c.send("edit.undo")
    check("%s as many undos as passes empty the zone" % tag, len(kids(c, gid)) == 0, len(kids(c, gid)))
    c.send("rec.arm", {"group": gid, "on": False})
    return gid


def record_midi(c, vid):
    c.send("timesel.set", {"start": 0, "end": 60, "lanes": [0]})
    r = c.send("rec.drop", {"midi": vid, "lane": 0, "time": 30})
    c.send("timesel.clear")
    gid = r["group"]
    insts = c.send("plugin.list_available", {"instruments_only": True})["plugins"]
    dls = next(p for p in insts if p["name"] == "DLSMusicDevice")
    c.send("instrument.set", {"id": gid, "identifier": dls["identifier"], "format": dls["format"]})
    c.send("rec.arm", {"group": gid, "on": True})
    c.send("debug.transport_loop", {"start": 1.0, "end": 2.0, "enabled": True})
    c.send("transport.seek", {"seconds": 0.5})
    c.send("rec.start")
    ev = []
    for i in range(N):
        on = 0.1 + 0.2 * i
        ev.append({"kind": "on", "note": 40 + i, "velocity": 90, "delay_ms": on * 1000})
        ev.append({"kind": "off", "note": 40 + i, "velocity": 0, "delay_ms": (on + 0.05) * 1000})
    c.send("midi.virtual.send", {"events": ev})
    time.sleep(3.8)
    st = c.send("rec.stop")
    c.send("rec.arm", {"group": gid, "on": False})
    c.send("debug.transport_loop", {"enabled": False})
    return gid, sorted(st["last_takes"], key=lambda t: t["pass"])


try:
    with ObjekatClient(sock) as c:
        # ---------------------------------------------------------------- U1, U2
        section("U1 / U2 audio, \"mute\" mode: one undo per pass, the file is kept")
        run_audio(c, "mute", "u1")

        # ---------------------------------------------------------------- U3
        section("U3 audio, \"add\" mode")
        run_audio(c, "add", "u3")

        # ---------------------------------------------------------------- U4
        section("U4 no undo while recording")
        new_project(c, "u4")
        c.send("input.enable")
        gid = audio_zone(c, "mute")
        c.send("debug.transport_loop", {"start": 1.0, "end": 2.0, "enabled": True})
        c.send("transport.seek", {"seconds": 0.5})
        c.send("rec.start")
        time.sleep(0.5)
        for cmd in ("edit.undo", "edit.redo"):
            try:
                c.send(cmd)
                code = None
            except ObjekatError as e:
                code = e.code
            check("%s during a recording answers invalid_state" % cmd, code == "invalid_state", code)
        time.sleep(1.5)
        r = c.send("rec.stop")
        c.send("debug.transport_loop", {"enabled": False})
        check("the recording ended normally, with its takes", len(r["last_takes"]) >= 2, r["last_takes"])
        check("... and they are in the zone", len(kids(c, gid)) == len(r["last_takes"]), len(kids(c, gid)))
        c.send("rec.arm", {"group": gid, "on": False})

        # ---------------------------------------------------------------- U6
        section("U6 a single-pass recording keeps ONE undo point")
        new_project(c, "u6")
        c.send("input.enable")
        gid = audio_zone(c, "mute")
        d0 = undo_depth(c)
        c.send("debug.transport_loop", {"enabled": False})
        c.send("transport.seek", {"seconds": 0.0})
        c.send("rec.start")
        time.sleep(1.0)
        r = c.send("rec.stop")
        check("one take", len(r["last_takes"]) == 1, r["last_takes"])
        check("ONE undo point", undo_depth(c) == d0 + 1, (d0, undo_depth(c)))
        c.send("edit.undo")
        check("one undo empties the zone", len(kids(c, gid)) == 0)
        c.send("rec.arm", {"group": gid, "on": False})

        # ---------------------------------------------------------------- U5
        section("U5 MIDI through a loop, pass by pass")
        new_project(c, "u5")
        c.send("input.enable")
        vid = c.send("midi.virtual.status")["device_id"]
        d0 = undo_depth(c)
        gid, takes = record_midi(c, vid)
        n = len(takes)
        steps = min(n, 16)
        check("MIDI: several takes: %d" % n, n >= 3, n)
        check("MIDI: one undo point per pass (%d)" % steps, undo_depth(c) == d0 + steps, (d0, undo_depth(c), steps))
        c.send("edit.undo")
        ks = kids(c, gid)
        check("MIDI: one undo takes the last pass away only", len(ks) == n - 1 and lanes_contiguous(ks), ks)
        check("MIDI: the previous pass is on top and audible, the others muted",
              [k["muted"] for k in ks] == [False] + [True] * (len(ks) - 1), [k["muted"] for k in ks])
        c.send("edit.undo")
        ks = kids(c, gid)
        top = ks[0]
        check("MIDI: the top take is the pass before the two undone", top["id"] == takes[n - 3]["object"],
              (top["id"], takes[n - 3]["object"]))
        before = len(c.send("midi.list_notes", {"id": top["id"]})["notes"])
        c.send("object.trim", {"id": top["id"], "start": top["start"], "duration": top["duration"] + 1.2})
        after = len(c.send("midi.list_notes", {"id": top["id"]})["notes"])
        check("MIDI: the sequence is kept: pulled out, the take reveals the undone passes' notes", after > before, (before, after))
        c.send("edit.undo")                                          # the trim
        for _ in range(steps - 2):
            c.send("edit.undo")
        check("MIDI: as many undos as passes empty the zone", len(kids(c, gid)) == 0, len(kids(c, gid)))
finally:
    proc.terminate()
    try:
        proc.wait(10)
    except subprocess.TimeoutExpired:
        proc.kill()
    if os.path.exists(sock):
        os.remove(sock)

print("\n%d OK, %d FAILED" % (ok, ko))
sys.exit(1 if ko else 0)

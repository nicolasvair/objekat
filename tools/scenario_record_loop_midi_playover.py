#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Recording MIDI through a loop: the player never hears the passes already played (patch 0051).

Tracktion's `MidiInputDeviceNode` has a « live play-over » (an overdub of the loop): while a device records through a loop, every
note played is also kept, stamped on the looped timeline, and REPLAYED at each lap into the node's own output. Objekat's loop
recording (0050) lays ONE take per pass and mutes the older ones, so the replay contradicts it: the monitored input (the hidden
track of the MIDI input, the instrument the player hears himself through) played back the earlier passes, cumulatively, under the
new one — while the takes themselves, once laid, are muted as they should be.

The old probes put the instrument on the ZONE only and never opened the monitoring of the INPUT, so they could not hear it. Here the
input has its instrument and its monitoring (`input.set_instrument` + `input.monitor`), the way a player works.

Headless, on the virtual card and the virtual MIDI input (`--virtual-audio --virtual-midi`), never a window. A MIDI zone on lane 0
armed on the virtual device, a loop [0 s, 4 s]; levels are read on the main bus (`stem.level`, a peak since the last read) in windows
driven by the head's position. Two layouts: V1 (zone WITHOUT instrument: only the input's monitoring can sound) and V2 (zone WITH
the DLS, the likely real case). The DLS rings for about 1.8 s after a note-off (measured): a window of silence always starts well
over 2 s after the last note-off, hence the 4 s loop and the pauses after a stop.

  P0  pass 1 after the note was released: silence (control)
  P1  pass 2, nothing played: silence (the note of pass 1 must not come back)                         [FAILS before 0051]
  P2  a note played live is heard (the monitoring still works)
  P3  pass 3, nothing played: silence in the windows of pass 1 AND of pass 2                          [FAILS before 0051]
  P4  stop: one audible take (the newest) holding its own pass's note only
  P5  a second recording through the loop right after: nothing of the first one comes back
  P6  an earlier linear take (V2): silent under a loop recording (the clip's own mute, no regression)
  P7  a linear recording is monitored live, one take, nothing replayed afterwards
  P8  the loop switched on DURING a recording started without it: same silence on the next lap
  P9  same as P1 with the computer keyboard as the source (skipped if the engine does not list it)
  P4b a short recording, then played back in the loop: only the last pass is heard (V2)
  P10 OBJ_REC_STOCK=1 (second launch, punch-in on a looping play: the stock engine cannot start a recording on a loop): the
      play-over is back (the switch commands it: proof of the cause)

    ./scenario_record_loop_midi_playover.py /path/to/objekat.app

Exit: 0 if every assertion passes, 1 if one fails, 2 on bad usage.
"""

import os, subprocess, sys, tempfile, time

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

SOUND, SILENT = 0.02, 0.005
LOOP_END = 4.0
SETTLE = 2.6          # the DLS's release, after a stop
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


tmp = tempfile.mkdtemp(prefix="objk-playover-")


def launch(tag, extra_env=None):
    sock = "/tmp/objk-playover-%s-%d.sock" % (tag, os.getpid())
    if os.path.exists(sock):
        os.remove(sock)
    err = os.path.join(tmp, "app-%s.err" % tag)
    env = dict(os.environ, OBJ_SKIP_REAL_CARD="1")
    env.update(extra_env or {})
    proc = subprocess.Popen([BIN, "--headless", "--api", "--no-recent", "--language=en", "--virtual-audio", "--virtual-midi",
                             "--socket=" + sock],
                            stdout=subprocess.DEVNULL, stderr=open(err, "w"), env=env)
    for _ in range(160):
        if os.path.exists(sock):
            break
        time.sleep(0.25)
    return proc, sock, err


# ---------------------------------------------------------------- the head and the levels

def pos(c):
    return c.send("transport.state")["position"]


def wait_pos(c, t, timeout=8.0):
    """Waits for the head to reach t in the pass that runs; False if the head wrapped (went back) or the time ran out first."""
    end, prev = time.time() + timeout, None
    while time.time() < end:
        p = pos(c)
        if p >= t:
            return True
        if prev is not None and p < prev - 0.5:
            return False
        prev = p
        time.sleep(0.01)
    return False


def wait_wrap(c, timeout=8.0):
    """Waits for the head to go back (the loop's end): the next pass begins."""
    end, prev = time.time() + timeout, pos(c)
    while time.time() < end:
        p = pos(c)
        if p < prev - 0.5:
            return True
        prev = p
        time.sleep(0.01)
    return False


class Bus:
    def __init__(self, c):
        self.c = c
        self.main = c.send("stem.list")["main"]

    def window(self, a, b):
        """Peak on the main bus between the positions a and b of the pass that runs (None if the head left the pass)."""
        if not wait_pos(self.c, a):
            return None
        self.c.send("stem.level", {"id": self.main})
        if not wait_pos(self.c, b):
            return None
        return self.c.send("stem.level", {"id": self.main})["level"]


def play(c, notes):
    """notes: [(pitch, on_ms, off_ms)] from now (the virtual input)."""
    ev = []
    for p, on, off in notes:
        ev.append({"kind": "on", "note": p, "velocity": 110, "delay_ms": on})
        ev.append({"kind": "off", "note": p, "velocity": 0, "delay_ms": off})
    c.send("midi.virtual.send", {"events": ev})


def fmt(v):
    return "n/a" if v is None else "%.3f" % v


def silent(label, v, why=""):
    check("%s: silence (%s)" % (label, fmt(v)), v is not None and v < SILENT, why or v)


def heard(label, v, why=""):
    check("%s: heard (%s)" % (label, fmt(v)), v is not None and v > SOUND, why or v)


# ---------------------------------------------------------------- the rig

def setup(c, zone_instrument, device="virtual"):
    """A new project; the MIDI input has its instrument AND its monitoring; a MIDI zone armed on it; loop [0, 2] on."""
    c.send("project.new")
    c.send("input.enable")
    if device == "virtual":
        dev = c.send("midi.virtual.status")["device_id"]
    else:
        c.send("midi.keyboard.set", {"on": True})
        dev = c.send("midi.keyboard.status")["device_id"]
        if not dev:
            return None
    dls = next(p for p in c.send("plugin.list_available", {"instruments_only": True})["plugins"] if p["name"] == "DLSMusicDevice")
    c.send("input.set_instrument", {"midi": dev, "identifier": dls["identifier"], "format": dls["format"]})
    out = c.send("input.monitor", {"midi": dev, "on": True})
    row = next(d for d in out["midi_inputs"] if d["id"] == dev)
    check("the input has its instrument and is heard", row["heard"] is True, row)
    c.send("timesel.set", {"start": 0, "end": 8, "lanes": [0]})
    gid = c.send("rec.drop", {"midi": dev, "lane": 0, "time": 4})["group"]
    c.send("timesel.clear")
    if zone_instrument:
        c.send("instrument.set", {"id": gid, "identifier": dls["identifier"], "format": dls["format"]})
    c.send("rec.arm", {"group": gid, "on": True})
    time.sleep(0.5)
    return dev, gid, dls


def loop_on(c):
    c.send("debug.transport_loop", {"start": 0.0, "end": LOOP_END, "enabled": True})


def loop_off(c):
    c.send("debug.transport_loop", {"enabled": False})


def start(c, gid):
    c.send("rec.arm", {"group": gid, "on": True})
    c.send("transport.seek", {"seconds": 0})
    c.send("rec.start")


def passes_one_to_four(c, bus, gid, name):
    """P0..P4: four passes of 4 s, notes 60 (pass 1, 0.2-0.5), 64 (pass 2, 1.0-1.3), nothing (pass 3), 67 (pass 4, 1.6-1.9)."""
    loop_on(c)
    start(c, gid)
    play(c, [(60, 200, 500)])
    heard("%s P2 pass 1, note 60 played live" % name, bus.window(0.25, 0.45))
    silent("%s P0 pass 1, long after the release" % name, bus.window(2.8, 3.9))

    check("%s the head wraps into pass 2" % name, wait_wrap(c))
    play(c, [(64, 1000, 1300)])
    silent("%s P1 pass 2, nothing played at 0.25-0.45 (note 60 of pass 1 must not return)" % name, bus.window(0.25, 0.45))
    heard("%s P2 pass 2, note 64 played live" % name, bus.window(1.05, 1.25))

    check("%s the head wraps into pass 3" % name, wait_wrap(c))
    silent("%s P3 pass 3, nothing played, place of the note of pass 1" % name, bus.window(0.25, 0.45))
    silent("%s P3 pass 3, nothing played, place of the note of pass 2" % name, bus.window(1.05, 1.25))

    check("%s the head wraps into pass 4" % name, wait_wrap(c))
    play(c, [(67, 1600, 1900)])
    heard("%s P2 pass 4, note 67 played live" % name, bus.window(1.65, 1.85))
    wait_pos(c, 2.1)
    st = c.send("rec.stop")

    takes = sorted(st["last_takes"], key=lambda t: t["pass"])
    print("       %d take(s): %s" % (len(takes), [(t["pass"], sorted(n["pitch"] for n in t["notes"]), t["audible"]) for t in takes]))
    check("%s P4 at least three takes" % name, len(takes) >= 3, len(takes))
    aud = [t for t in takes if t["audible"]]
    check("%s P4 exactly one audible take: the newest" % name,
          len(aud) == 1 and aud[0]["pass"] == takes[-1]["pass"], [(t["pass"], t["audible"]) for t in takes])
    check("%s P4 the newest take holds the note of its own pass only" % name,
          sorted(n["pitch"] for n in takes[-1]["notes"]) == [67], [n["pitch"] for n in takes[-1]["notes"]])


def second_recording(c, bus, gid, name):
    """P5: right after the first one, no other action (but the DLS's release). Nothing played: nothing of the first recording's notes
    (60 and 64, muted takes) comes back, from the first lap on."""
    time.sleep(SETTLE)
    start(c, gid)
    for lap in (1, 2):
        silent("%s P5 2nd recording, pass %d, place of 60" % (name, lap), bus.window(0.25, 0.45))
        silent("%s P5 2nd recording, pass %d, place of 64" % (name, lap), bus.window(1.05, 1.25))
        if lap == 1:
            check("%s the head wraps into pass 2" % name, wait_wrap(c))
    c.send("rec.stop")


def settle(c):
    time.sleep(SETTLE)


proc = proc2 = None
try:
    proc, sock, err = launch("a")
    with ObjekatClient(sock) as c:
        # ---------------------------------------------------------------- V1: the input's monitoring alone
        section("V1 zone WITHOUT instrument (only the input's monitoring can sound)")
        dev, gid, dls = setup(c, False)
        bus = Bus(c)
        passes_one_to_four(c, bus, gid, "V1")
        second_recording(c, bus, gid, "V1")
        loop_off(c)

        # ---------------------------------------------------------------- V2: zone with the DLS
        section("V2 zone WITH the DLS")
        dev, gid, dls = setup(c, True)
        bus = Bus(c)
        passes_one_to_four(c, bus, gid, "V2")
        second_recording(c, bus, gid, "V2")
        loop_off(c)

        # ---------------------------------------------------------------- P4b
        section("P4b played back after a loop recording: only the last pass is heard")
        dev, gid, dls = setup(c, True)
        bus = Bus(c)
        loop_on(c)
        start(c, gid)
        play(c, [(60, 200, 500)])
        wait_wrap(c)
        play(c, [(67, 1600, 1900)])
        wait_pos(c, 2.1)
        c.send("rec.stop")
        settle(c)
        c.send("transport.seek", {"seconds": 0})
        c.send("transport.play")
        silent("P4b played back, place of note 60 (pass 1, muted take)", bus.window(0.25, 0.45))
        heard("P4b played back, place of note 67 (the last pass)", bus.window(1.65, 1.85))
        c.send("transport.stop")
        loop_off(c)

        # ---------------------------------------------------------------- P7 then P6
        section("P7 / P6 a linear recording, then a loop recording over it")
        dev, gid, dls = setup(c, True)
        bus = Bus(c)
        start(c, gid)
        play(c, [(60, 200, 3500)])
        heard("P7 linear recording: the note is heard live", bus.window(0.3, 0.5))
        wait_pos(c, 3.8)
        st = c.send("rec.stop")
        check("P7 one take", len(st["last_takes"]) == 1, len(st["last_takes"]))
        settle(c)
        c.send("transport.seek", {"seconds": 0})
        c.send("transport.play")
        heard("P7 played back: the take (the held note) is heard", bus.window(1.0, 1.2))
        c.send("transport.stop")
        settle(c)
        loop_on(c)
        start(c, gid)
        silent("P6 loop recording over a linear take, pass 1, place of the start", bus.window(0.25, 0.45))
        silent("P6 loop recording over a linear take, pass 1, middle of the held note", bus.window(1.0, 1.2))
        check("P6 the head wraps into pass 2", wait_wrap(c))
        silent("P6 ... pass 2", bus.window(0.25, 0.45))
        c.send("rec.stop")
        loop_off(c)

        # ---------------------------------------------------------------- P8
        section("P8 the loop switched on DURING a recording started without it")
        dev, gid, dls = setup(c, True)
        bus = Bus(c)
        start(c, gid)
        loop_on(c)
        play(c, [(60, 200, 500)])
        heard("P8 pass 1, note 60 played live", bus.window(0.25, 0.45))
        wrapped = wait_wrap(c, 8.0)
        check("P8 the head wraps once the loop is on (the recording went on through it)", wrapped)
        if wrapped:
            silent("P8 next lap, nothing played", bus.window(0.25, 0.45))
        try:
            c.send("rec.stop")
        except Exception:
            pass
        loop_off(c)

        # ---------------------------------------------------------------- P9
        section("P9 the computer keyboard as the source")
        r = setup(c, True, "keyboard")
        if r is None:
            print("  SKIP  the engine does not list the computer keyboard")
        else:
            dev, gid, dls = r
            bus = Bus(c)
            loop_on(c)
            start(c, gid)
            wait_pos(c, 0.2)
            c.send("midi.keyboard.key", {"key_code": 0})
            heard("P9 pass 1, the key is heard live", bus.window(0.25, 0.45))
            wait_pos(c, 0.5)
            c.send("midi.keyboard.key", {"key_code": 0, "down": False})
            check("P9 the head wraps into pass 2", wait_wrap(c))
            silent("P9 pass 2, nothing played", bus.window(0.25, 0.45))
            try:
                c.send("rec.stop")
            except Exception:
                pass
            loop_off(c)
            c.send("midi.keyboard.set", {"on": False})

    # ---------------------------------------------------------------- P10: the stock engine behaviour
    section("P10 OBJ_REC_STOCK=1: the play-over is back (the switch commands it)")
    proc.terminate()
    proc.wait(10)
    proc = None
    proc2, sock2, err2 = launch("b", {"OBJ_REC_STOCK": "1"})
    with ObjekatClient(sock2) as c:
        dev, gid, dls = setup(c, False)
        bus = Bus(c)
        loop_on(c)
        c.send("rec.arm", {"group": gid, "on": True})
        c.send("transport.seek", {"seconds": 0})
        c.send("transport.play")                    # the stock engine only records through a loop by a punch-in on a looping play
        wait_pos(c, 0.05)
        c.send("rec.start")
        play(c, [(60, 200, 500)])
        bus.window(0.25, 0.45)
        if wait_wrap(c):
            heard("P10 stock: pass 2, nothing played, the note of pass 1 comes back", bus.window(0.25, 0.45))
        else:
            check("P10 stock: the head wraps (the recording went on through the loop)", False)
        try:
            c.send("rec.stop")
        except Exception:
            pass
finally:
    for p in (proc, proc2):
        if p is not None:
            p.terminate()
            try:
                p.wait(10)
            except Exception:
                p.kill()
    print("\napp logs: %s" % tmp)
    print("%d PASS / %d FAIL" % (ok, ko))

sys.exit(1 if ko else 0)

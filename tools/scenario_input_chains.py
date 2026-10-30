#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""E8 of docs/plan_groupes_midi.md : the ENGINE side of the input chains (FX on an audio input, instrument on a MIDI
input), driven through `debug.input_host` (DEBUG builds; the model is not involved yet — that is E9).

  I1  an audio host registered on an input that is live: the chain resolves, an FX compiled on it is mounted, the
      input heard through it still reaches the Main
  I2  the host unregistered: the chain does not resolve, the FX instance is gone; the input is heard as before
  I3  a host on an input that does not exist (inputs closed): registered but DORMANT (live false)
  I4  a MIDI host: registered with the virtual device, an instrument mounted; nothing is heard until the device is
      monitored; monitored -> a note on the virtual device is heard on the Main; unmonitored -> silence again
  I5  a MIDI input with no instrument cannot be monitored (refusal), unregistering the host stops the monitoring

    ./scenario_input_chains.py /path/to/objekat.app

Exit: 0 if every assertion passes, 1 otherwise, 2 on bad usage.
"""

import os, subprocess, sys, tempfile, time, traceback, uuid

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

if len(sys.argv) < 2:
    print(__doc__)
    sys.exit(2)

APP = sys.argv[1]
BIN = os.path.join(APP, "Contents", "MacOS", "objekat")
if not os.path.exists(BIN):
    print("not an app bundle: %s" % APP)
    sys.exit(2)

WORK = tempfile.mkdtemp(prefix="objk-inch-")
FAILS = []
TOTAL = [0]


def check(label, ok, detail=""):
    TOTAL[0] += 1
    if ok:
        print("ok    " + label)
    else:
        FAILS.append(label)
        print("FAIL  %s  %s" % (label, detail))


def main():
    sock = "/tmp/objk-inch-%d.sock" % os.getpid()
    if os.path.exists(sock):
        os.remove(sock)
    proc = subprocess.Popen([BIN, "--headless", "--api", "--no-recent", "--language=en", "--virtual-audio",
                             "--virtual-midi", "--socket=" + sock],
                            stdout=subprocess.DEVNULL, stderr=open(os.path.join(WORK, "app.err"), "w"),
                            env=dict(os.environ, OBJ_SKIP_REAL_CARD="1"))
    try:
        for _ in range(240):
            if os.path.exists(sock):
                break
            time.sleep(0.25)
        c = ObjekatClient(sock).connect()
        c.send("project.new")
        c.send("audio.virtual.set_input", {"channel": 0, "signal": "sine", "frequency": 440, "amplitude": 0.5})
        for ch in (1, 2, 3):
            c.send("audio.virtual.set_input", {"channel": ch, "signal": "silence"})
        main_id = c.send("stem.list")["main"]

        def level():
            c.send("stem.level")
            time.sleep(0.5)
            return c.send("stem.level", {"id": main_id})["level"]

        def door(op, **kw):
            kw["op"] = op
            return c.send("debug.input_host", kw)

        fx = next(p for p in c.send("plugin.list_available")["plugins"]
                  if p["format"] == "AudioUnit" and not p.get("is_instrument") and p["name"].startswith("AU"))
        inst = next(p for p in c.send("plugin.list_available", {"instruments_only": True})["plugins"]
                    if p["name"] == "DLSMusicDevice")
        fxp = {"identifier": fx["identifier"], "format": fx["format"]}
        instp = {"identifier": inst["identifier"], "format": inst["format"]}

        # ── I3 first: the inputs are closed
        host_a = str(uuid.uuid4()).upper()
        r = door("register_audio", host=host_a, first=0, count=1)
        check("I3 inputs closed: the host is dormant (not live)", r["live"] is False, r)
        door("unregister", host=host_a)

        # ── I1
        c.send("input.enable")
        r = door("register_audio", host=host_a, first=0, count=1)
        check("I1 inputs open: the host resolves", r["live"] is True and r["registered"] is True, r)
        r = door("add_plugin", host=host_a, **fxp)
        check("I1 an FX compiled on the host loads", r["failed"] == [], r)
        plug = r["plugin"]
        mounted = False
        for _ in range(40):
            try:
                info = c.send("debug.plugin_buses", {"plugin": plug})
                mounted = info.get("loaded", True) is not False
                if mounted:
                    break
            except ObjekatError:
                pass
            time.sleep(0.25)
        check("I1 the FX instance is mounted", mounted)
        c.send("input.monitor", {"first": 0, "on": True})
        time.sleep(0.5)
        heard = level()
        check("I1 the input heard through the host still reaches the Main (%.3f)" % heard, heard > 0.3, heard)

        # ── I2
        door("unregister", host=host_a)
        r = door("live", host=host_a)
        check("I2 unregistered: the chain no longer resolves", r["live"] is False, r)
        gone = False
        try:
            c.send("debug.plugin_buses", {"plugin": plug})
        except ObjekatError as e:
            gone = e.code == "not_found"
        check("I2 ... and the FX instance is gone", gone)
        time.sleep(0.5)
        heard = level()
        check("I2 the input is still heard, bare (%.3f)" % heard, heard > 0.8, heard)
        c.send("input.monitor", {"first": 0, "on": False})

        # ── I6: the listening gain survives the chain (the FX go BEFORE the ObjGain, which is never taken for one)
        c.send("input.set_monitor_gain", {"first": 0, "db": -40})
        c.send("input.monitor", {"first": 0, "on": True})
        r = door("register_audio", host=host_a, first=0, count=1)
        r = door("add_plugin", host=host_a, **fxp)
        check("I6 FX added on a chain whose input has a listening gain", r["failed"] == [], r)
        time.sleep(0.5)
        low = level()
        check("I6 the gain is still applied after the compile (%.3f, bare would be ~0.9)" % low, low < 0.5, low)
        door("add_plugin", host=host_a, **fxp)
        time.sleep(0.5)
        low = level()
        check("I6 ... and after a second compile (%.3f)" % low, low < 0.5, low)
        door("unregister", host=host_a)
        time.sleep(0.5)
        low = level()
        check("I6 ... and after the chain is gone (%.3f)" % low, low < 0.5, low)
        c.send("input.set_monitor_gain", {"first": 0, "db": 0})
        c.send("input.monitor", {"first": 0, "on": False})

        # ── I4 / I5: MIDI host
        devs = c.send("midi.virtual.status")
        dev = devs["device_id"]
        check("the virtual MIDI device exists", devs.get("active") is True and bool(dev), devs)
        host_m = str(uuid.uuid4()).upper()
        r = door("register_midi", host=host_m, device=dev)
        check("I4 MIDI host registered (hidden track created)", r["registered"] is True, r)
        r = door("midi_monitor", device=dev, on=True)
        check("I5 no instrument yet: monitoring is refused", bool(r["error"]) and dev not in r["monitors"], r)
        r = door("set_instrument", host=host_m, **instp)
        check("I4 instrument mounted on the host", bool(r.get("plugin_key")), r)
        time.sleep(1.0)
        quiet = level()
        check("I4 nothing heard before the monitoring (%.3f)" % quiet, quiet < 0.05, quiet)
        r = door("midi_monitor", device=dev, on=True)
        check("I4 monitoring accepted", r["error"] is None and dev in r["monitors"], r)
        # Apple's DLS loads its sound bank on the FIRST note after it is instantiated, and swallows it: prime it.
        c.send("midi.virtual.send", {"events": [{"kind": "on", "note": 48, "velocity": 100},
                                                 {"kind": "off", "note": 48, "delay_ms": 300}]})
        time.sleep(2.0)
        level()
        c.send("midi.virtual.send", {"events": [{"kind": "on", "note": 60, "velocity": 120}]})
        time.sleep(0.8)
        heard = level()
        check("I4 the note is heard on the Main (%.3f)" % heard, heard > 0.02, heard)
        c.send("midi.virtual.send", {"events": [{"kind": "off", "note": 60}]})
        r = door("midi_monitor", device=dev, on=False)
        check("I4 monitoring off", dev not in r["monitors"], r)
        time.sleep(2.5)
        level()
        c.send("midi.virtual.send", {"events": [{"kind": "on", "note": 64, "velocity": 120}]})
        time.sleep(0.8)
        silent = level()
        check("I4 unmonitored: a note is not heard (%.3f)" % silent, silent < 0.02, silent)
        c.send("midi.virtual.send", {"events": [{"kind": "off", "note": 64}]})
        door("midi_monitor", device=dev, on=True)
        r = door("unregister", host=host_m)
        check("I5 unregistering the host drops the instrument and ... ", r["live"] is False, r)
        r = door("midi_monitor", device=dev, on=True)
        check("I5 ... the monitoring is refused again (no instrument)", bool(r["error"]), r)
        c.close()
    except Exception:
        traceback.print_exc()
        FAILS.append("exception")
    finally:
        proc.terminate()
        try:
            proc.wait(15)
        except Exception:
            proc.kill()
        if os.path.exists(sock):
            os.remove(sock)
    print("\n%d checks, %d failed" % (TOTAL[0], len(FAILS)))
    sys.exit(1 if FAILS else 0)


main()

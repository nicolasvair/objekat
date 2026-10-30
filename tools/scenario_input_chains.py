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
  I6  the listening gain survives a chain compiled on its input

E9 (the model, through the public API: `input.host`, `plugin.*`, `input.set_instrument`, `input.monitor`):

  M1  FX added through `plugin.*` on `input.host`: mounted while open, listed, counted in `input.list`
  M2  FX that colour what is HEARD (-10 dB or more) and NOT what is recorded (take RMS = the input's, +-0.1 dB)
  M3  closed and not heard -> unmounted (states kept); heard -> mounted again
  M4  save / reopen: `inputChains` in the file, the chain back under the same host, mounted only when heard
  M5  undo of the FX added; a new project forgets the chains
  M6  MIDI: instrument on an input (one undo point), refused without one, heard only when monitored, removed, undo

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


def read_wav_float(path):
    import struct
    import numpy as np
    raw = open(path, "rb").read()
    pos, ch, data = 12, 1, b""
    while pos + 8 <= len(raw):
        cid, size = raw[pos:pos + 4], struct.unpack("<I", raw[pos + 4:pos + 8])[0]
        body = raw[pos + 8:pos + 8 + size]
        if cid == b"fmt ":
            ch = struct.unpack("<H", body[2:4])[0]
        elif cid == b"data":
            data = body
        pos += 8 + size + (size & 1)
    return np.frombuffer(data[:len(data) // 4 * 4], dtype="<f4").reshape(-1, ch)


def e9(c, level, fxp, instp, dev):
    import json
    import numpy as np
    LPF = {"identifier": "aufx,lpas,appl"}

    def plist(host):
        return c.send("plugin.list", {"host": host})["plugins"]

    def cutoff_index(pid):
        for prm in c.send("plugin.get_params", {"plugin": pid}).get("params", []):
            if "cutoff" in prm["name"].lower():
                return prm["index"]
        return None

    def wait_loaded(pid):
        for _ in range(60):
            try:
                if c.send("debug.plugin_buses", {"plugin": pid}).get("loaded", True) is not False:
                    return True
            except ObjekatError:
                pass
            time.sleep(0.25)
        return False

    def absent(pid):
        try:
            c.send("debug.plugin_buses", {"plugin": pid})
            return False
        except ObjekatError as e:
            return e.code == "not_found"

    def input_row(first=0):
        return next(r for r in c.send("input.list")["record_inputs"] if r["first"] == first and r["count"] == 1)

    def record_take(name):
        c.send("timesel.set", {"start": 0, "end": 4, "lanes": [0]})
        zone = c.send("rec.drop", {"first": 0, "count": 1, "lane": 0, "time": 2})["group"]
        c.send("timesel.clear")
        c.send("rec.arm", {"group": zone, "on": True})
        c.send("transport.seek", {"seconds": 0})
        c.send("rec.start")
        end = time.time() + 20
        while time.time() < end and c.send("transport.state")["position"] < 3.0:
            time.sleep(0.05)
        take = c.send("rec.stop")["last_takes"][0]
        c.send("rec.arm", {"group": zone, "on": False})
        x = read_wav_float(take["path"])[:, 0]
        return x[int(0.5 * 48000):int(2.5 * 48000)]

    tmp = os.path.join(WORK, "e9")
    c.send("project.new")
    c.send("project.save_as", {"path": os.path.join(tmp, "p", "p.objekat.json")})
    c.send("audio.virtual.set_input", {"channel": 0, "signal": "sine", "frequency": 440, "amplitude": 0.5})
    c.send("input.enable")
    check("M1 no chain yet: host_id null, fx_count 0", input_row()["host_id"] is None and input_row()["fx_count"] == 0)
    h = c.send("input.host", {"first": 0})
    host = h["host_id"]
    check("M1 input.host makes the chain, mounted (open), nothing in it", h["kind"] == "audio" and h["mounted"] and h["plugins"] == 0, h)
    check("M1 the same host again", c.send("input.host", {"first": 0})["host_id"] == host)
    r = c.send("plugin.add", {"host": host, **LPF})
    pid = r["plugin"]["id"]
    check("M1 plugin.add on the host lists it", [p["id"] for p in plist(host)] == [pid], plist(host))
    check("M1 the instance is mounted", wait_loaded(pid))
    row = input_row()
    check("M1 input.list: host_id and fx_count", row["host_id"] == host and row["fx_count"] == 1, row)
    k = cutoff_index(pid)
    check("M1 the AU answers its parameters (a Cutoff)", k is not None)
    c.send("plugin.set_param", {"plugin": pid, "index": k, "value": 0.003})
    time.sleep(0.5)

    # M2: heard through the FX vs not; recorded without it
    c.send("input.monitor", {"first": 0, "on": True})
    time.sleep(0.8)
    filtered = level()
    c.send("input.monitor", {"first": 0, "on": False})
    c.send("plugin.toggle", {"host": host, "plugin": pid}) if False else None
    take = record_take("fx")
    rms = float(np.sqrt(np.mean(take ** 2)))
    check("M2 heard through the lowpass: well under the bare input (%.3f, bare ~0.90)" % filtered, filtered < 0.75, filtered)
    check("M2 the recording ignores it: take RMS %.4f = 0.3536 (+-0.1 dB)" % rms, abs(20 * np.log10(rms / 0.35355)) < 0.1, rms)

    # M3: closed and not heard -> unmounted, states kept
    h = c.send("input.host", {"first": 0, "open": False})
    check("M3 closed and not heard: unmounted", h["mounted"] is False and h["live"] is False, h)
    check("M3 ... the instance is gone", absent(pid))
    check("M3 ... the chain is kept in the model", [p["id"] for p in plist(host)] == [pid])
    c.send("input.monitor", {"first": 0, "on": True})
    check("M3 heard: mounted again", wait_loaded(pid))
    time.sleep(0.8)
    again = level()
    check("M3 ... and the cutoff came back with it (%.3f ~ %.3f)" % (again, filtered), abs(again - filtered) < 0.08, (again, filtered))
    c.send("input.monitor", {"first": 0, "on": False})

    # M4: save / reopen
    path = os.path.join(tmp, "p", "p.objekat.json")
    c.send("project.save")
    doc = json.load(open(path))
    ic = doc.get("inputChains") or {}
    check("M4 the file carries inputChains.audio['1'] with the plugin and the same host",
          ic.get("audio", {}).get("1", {}).get("hostID", "").upper() == host.upper()
          and len(ic.get("audio", {}).get("1", {}).get("plugins", [])) == 1, ic)
    check("M4 ... with its state captured (the cutoff)", bool(ic.get("audio", {}).get("1", {}).get("plugins", [{}])[0].get("stateXML")))
    c.send("project.new")
    check("M5 a new project forgets the chains", input_row()["host_id"] is None and input_row()["fx_count"] == 0, input_row())
    check("M5 ... and the instance is gone", absent(pid))
    c.send("project.open", {"path": path})
    row = input_row()
    check("M4 reopened: the same host and the plugin", row["host_id"].upper() == host.upper() and row["fx_count"] == 1, row)
    check("M4 ... NOT mounted (nothing is heard)", absent(pid))
    c.send("input.monitor", {"first": 0, "on": True})
    check("M4 heard: mounted", wait_loaded(pid))
    k2 = cutoff_index(pid)
    shown = [q for q in c.send("plugin.get_params", {"plugin": pid})["params"] if q["index"] == k2][0]
    check("M4 ... with the cutoff of the file (display %s)" % shown.get("display"), shown["value"] < 0.05, shown)
    c.send("input.monitor", {"first": 0, "on": False})

    # M5: undo
    c.send("input.host", {"first": 0})
    r2 = c.send("plugin.add", {"host": host, **LPF})
    pid2 = r2["plugin"]["id"]
    check("M5 a second FX is added", len(plist(host)) == 2 and wait_loaded(pid2))
    c.send("edit.undo", {})
    time.sleep(0.5)
    check("M5 undo: the second FX is gone from the model and the engine",
          [p["id"] for p in plist(host)] == [pid] and absent(pid2), plist(host))
    c.send("edit.redo", {})
    time.sleep(0.5)
    check("M5 redo: it is back", len(plist(host)) == 2)
    c.send("edit.undo", {})
    c.send("input.host", {"first": 0, "open": False})

    # M6: MIDI
    r = refused_cmd(c, "input.monitor", midi=dev, on=True)
    check("M6 no instrument: monitoring is refused (invalid_state)", r == "invalid_state", r)
    r = refused_cmd(c, "input.set_instrument", midi=dev, **fxp)
    check("M6 an effect is not an instrument (bad_params)", r == "bad_params", r)
    depth = c.send("perf.census")["undo_depth"]
    out = c.send("input.set_instrument", {"midi": dev, **instp})
    row = next(d for d in out["midi_inputs"] if d["id"] == dev)
    check("M6 the instrument is set, host_id given, not heard", row["instrument"] == "DLSMusicDevice" and row["host_id"] and not row["heard"], row)
    check("M6 ... one undo point", c.send("perf.census")["undo_depth"] == depth + 1)
    mh = row["host_id"]
    check("M6 plugin.list on the MIDI host lists the instrument", [i["name"] for i in c.send("plugin.list", {"host": mh})["instruments"]] == ["DLSMusicDevice"])
    out = c.send("input.monitor", {"midi": dev, "on": True})
    row = next(d for d in out["midi_inputs"] if d["id"] == dev)
    check("M6 monitored: heard", row["heard"] is True, row)
    c.send("midi.virtual.send", {"events": [{"kind": "on", "note": 48, "velocity": 100}, {"kind": "off", "note": 48, "delay_ms": 300}]})
    time.sleep(2.0)
    level()
    c.send("midi.virtual.send", {"events": [{"kind": "on", "note": 60, "velocity": 120}]})
    time.sleep(0.8)
    heard = level()
    check("M6 the note is heard (%.3f)" % heard, heard > 0.02, heard)
    c.send("midi.virtual.send", {"events": [{"kind": "off", "note": 60}]})
    c.send("input.remove_instrument", {"midi": dev})
    out = c.send("input.list.midi_inputs")
    row = next(d for d in out["midi_inputs"] if d["id"] == dev)
    check("M6 removed: no instrument, no longer heard", row["instrument"] is None and not row["heard"], row)
    c.send("edit.undo", {})
    row = next(d for d in c.send("input.list.midi_inputs")["midi_inputs"] if d["id"] == dev)
    check("M6 undo of the removal: the instrument is back", row["instrument"] == "DLSMusicDevice", row)
    c.send("edit.undo", {})
    row = next(d for d in c.send("input.list.midi_inputs")["midi_inputs"] if d["id"] == dev)
    check("M6 undo of the setting: gone again", row["instrument"] is None, row)


def refused_cmd(c, cmd, **params):
    try:
        c.send(cmd, params)
        return None
    except ObjekatError as e:
        return e.code


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
            return c.send("stem.level", {"id": c.send("stem.list")["main"]})["level"]

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
        e9(c, level, fxp, instp, dev)
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

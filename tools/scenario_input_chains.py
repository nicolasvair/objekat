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

E11 (a zone CREATED from an input takes a copy of what it carries; `rec.drop`, then `plugin.list` / `plugin.get_params`):

  H1  MIDI input with an instrument -> the new zone has its own copy (new id), `inherited.instrument`
  H2  changing one side (the zone's copy or the input's chain) leaves the other alone, for the FX and the instrument
  H3  a drop on an EXISTING zone (assign) changes nothing in its chain
  H4  card input with FX -> the new zone has copies (new ids, same setting), `inherited.fx`; one undo removes the zone only
  H5  several inputs dropped at once: every lane inherits its own
  H6  an input NOT mounted (closed, not heard): the copy is made from the model's state

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

    # M7: audio FX BEHIND a MIDI input's instrument (inputs panel, step 1). Order [instrument, FX...] is proven by the
    # sound: an FX laid before a generator would change nothing.
    c.send("input.set_instrument", {"midi": dev, **instp})
    mh = next(d for d in c.send("input.list.midi_inputs")["midi_inputs"] if d["id"] == dev)["host_id"]
    c.send("input.monitor", {"midi": dev, "on": True})
    c.send("midi.virtual.send", {"events": [{"kind": "on", "note": 48, "velocity": 100}, {"kind": "off", "note": 48, "delay_ms": 300}]})
    time.sleep(2.0)

    def play60():
        level()
        c.send("midi.virtual.send", {"events": [{"kind": "on", "note": 60, "velocity": 120}]})
        time.sleep(0.8)
        v = level()
        c.send("midi.virtual.send", {"events": [{"kind": "off", "note": 60}]})
        time.sleep(1.5)
        return v

    bare = play60()
    check("M7 bare instrument heard (%.3f)" % bare, bare > 0.02, bare)
    r = c.send("plugin.add", {"host": mh, **LPF})
    fpid = r["plugin"]["id"]
    check("M7 plugin.add on the MIDI host: listed behind the instrument",
          [p["id"] for p in plist(mh)] == [fpid]
          and [i["name"] for i in c.send("plugin.list", {"host": mh})["instruments"]] == ["DLSMusicDevice"], plist(mh))
    check("M7 the FX instance is mounted", wait_loaded(fpid))
    row = next(d for d in c.send("input.list.midi_inputs")["midi_inputs"] if d["id"] == dev)
    check("M7 input.list.midi_inputs: fx_count 1, still heard", row["fx_count"] == 1 and row["heard"] is True, row)
    k7 = cutoff_index(fpid)
    c.send("plugin.set_param", {"plugin": fpid, "index": k7, "value": 0.003})
    time.sleep(0.5)
    filtered = play60()
    check("M7 the note now goes THROUGH the FX: %.3f << %.3f" % (filtered, bare), filtered < 0.5 * bare, (filtered, bare))
    # closed and not heard: unmounted, kept; heard again: back with its setting
    c.send("input.monitor", {"midi": dev, "on": False})
    c.send("input.host", {"midi": dev, "open": False})
    check("M7 unmounted: the FX instance is gone, the chain kept", absent(fpid) and [p["id"] for p in plist(mh)] == [fpid])
    c.send("input.monitor", {"midi": dev, "on": True})
    check("M7 heard again: the FX is mounted again", wait_loaded(fpid))
    time.sleep(1.0)
    again = play60()
    check("M7 ... behind the instrument still (%.3f ~ %.3f)" % (again, filtered), again < 0.5 * bare, (again, bare))
    # save / reopen
    c.send("project.save")
    doc = json.load(open(os.path.join(tmp, "p", "p.objekat.json")))
    mc = (doc.get("inputChains") or {}).get("midi", {}).get(dev, {})
    check("M7 the file carries the instrument and the FX of the MIDI chain",
          mc.get("instrument") and len(mc.get("plugins", [])) == 1, mc)
    # an instrument replaced keeps the FX, which stay behind the new one
    c.send("input.monitor", {"midi": dev, "on": False})
    out = c.send("input.set_instrument", {"midi": dev, **instp})
    row = next(d for d in out["midi_inputs"] if d["id"] == dev)
    check("M7 replacing the instrument keeps the FX", row["fx_count"] == 1 and [p["id"] for p in plist(mh)] == [fpid], row)
    c.send("edit.undo", {})
    c.send("input.remove_instrument", {"midi": dev})
    row = next(d for d in c.send("input.list.midi_inputs")["midi_inputs"] if d["id"] == dev)
    check("M7 removing the instrument keeps the FX", row["instrument"] is None and row["fx_count"] == 1, row)
    c.send("edit.undo", {})
    row = next(d for d in c.send("input.list.midi_inputs")["midi_inputs"] if d["id"] == dev)
    check("M7 undo of the removal: instrument and FX both back", row["instrument"] == "DLSMusicDevice" and row["fx_count"] == 1, row)
    c.send("edit.undo", {})
    c.send("edit.undo", {})
    c.send("input.host", {"midi": dev, "open": False})

    # M8: the instrument slot by HOST id (what the synoptic's card speaks): instrument.set / instrument.remove on the host
    mh = c.send("input.host", {"midi": dev, "open": False})["host_id"]      # (the undos above forgot the old record)
    depth = c.send("perf.census")["undo_depth"]
    r = c.send("instrument.set", {"id": mh, **instp})
    check("M8 instrument.set on a MIDI input host: one undo point, the instrument is there",
          r["instrument"]["name"] == "DLSMusicDevice" and c.send("perf.census")["undo_depth"] == depth + 1, r)
    row = next(d for d in c.send("input.list.midi_inputs")["midi_inputs"] if d["id"] == dev)
    check("M8 ... visible through input.list.midi_inputs and plugin.list", row["instrument"] == "DLSMusicDevice"
          and [i["name"] for i in c.send("plugin.list", {"host": mh})["instruments"]] == ["DLSMusicDevice"], row)
    ipid = c.send("plugin.list", {"host": mh})["instruments"][0]["id"]
    check("M8 plugin.level accepts the instrument of a MIDI host", "level" in c.send("plugin.level", {"host": mh, "plugin": ipid}))
    c.send("instrument.remove", {"id": mh})
    row = next(d for d in c.send("input.list.midi_inputs")["midi_inputs"] if d["id"] == dev)
    check("M8 instrument.remove on the host: gone", row["instrument"] is None, row)
    r = refused_cmd(c, "instrument.remove", id=mh)
    check("M8 ... removing again is invalid_state", r == "invalid_state", r)
    c.send("edit.undo", {})
    c.send("edit.undo", {})
    row = next(d for d in c.send("input.list.midi_inputs")["midi_inputs"] if d["id"] == dev)
    check("M8 undo x2: back to no instrument", row["instrument"] is None, row)

    # M9: the rectangles and their popup (inputs panel, step 4): `input.strip`
    def strip(kind, **match):
        for r in c.send("input.strip")["strips"]:
            if r["kind"] == kind and all(r.get(k) == v for k, v in match.items()):
                return r
        return None
    check("M9 the MIDI device and the card input each have a rectangle",
          strip("midi", id=dev) is not None and strip("audio", first=0, count=1) is not None)
    check("M9 no popup open at first", c.send("input.strip")["open"] is None)
    r = c.send("input.strip", {"midi": dev})
    check("M9 opening a MIDI popup holds its chain mounted", r["open"]["id"] == dev and r["mounted"] and r["host_id"], r)
    mh9 = r["host_id"]
    c.send("instrument.set", {"id": mh9, **instp})
    check("M9 a LONE instrument has no badge", strip("midi", id=dev)["badges"] == [], strip("midi", id=dev))
    fx9 = c.send("plugin.add", {"host": mh9, **LPF})["plugin"]["id"]
    check("M9 instrument + FX: the fx badge", strip("midi", id=dev)["badges"] == ["fx"], strip("midi", id=dev))
    rt = c.send("debug.rename_shortcut")
    check("M9 popup of a MIDI input open: R renames nothing", rt["target"] == "none", rt)
    r = c.send("input.strip", {"first": 0})
    check("M9 opening another popup closes the first one, and lets its chain go",
          r["open"]["kind"] == "audio" and r["host_id"] != mh9
          and not c.send("input.host", {"midi": dev, "open": False})["mounted"], r)
    rt = c.send("debug.rename_shortcut")
    check("M9 popup of a card input open: R renames THAT input", rt["target"] == "input" and rt["first"] == 0, rt)
    check("M9 ... in the popup (the rectangle is not in rename)", c.send("input.strip")["open"]["open"] is True)
    c.send("input.strip", {"first": 0, "open": False})
    check("M9 closing it", c.send("input.strip")["open"] is None)
    c.send("project.new")
    c.send("input.strip", {"first": 0})
    c.send("project.new")
    check("M9 a new project closes the popup", c.send("input.strip")["open"] is None)

    # M10: dragging the instrument OUT of a MIDI input's popup (inputs panel, step 5): `plugin.drop` from the input's host.
    c.send("project.new")
    mh = c.send("input.host", {"midi": dev, "open": False})["host_id"]
    c.send("instrument.set", {"id": mh, **instp})
    ip = c.send("plugin.list", {"host": mh})["instruments"][0]["id"]
    clip = c.send("midi.create_clip", {"start": 0, "end": 2, "lane": 2})["id"]
    stem = c.send("stem.list")["main"]
    def row10():
        return next(d for d in c.send("input.list.midi_inputs")["midi_inputs"] if d["id"] == dev)
    def inst_of(h):
        return [i["name"] for i in c.send("plugin.list", {"host": h})["instruments"]]
    r = c.send("plugin.drop", {"from": mh, "plugin": ip, "to": stem})
    check("M10 an instrument dropped on a stem is refused (the cursor says so before release)",
          r["refused"] is True and r["placed"] is False, r)
    zone = c.send("rec.drop", {"first": 0, "count": 1, "lane": 5, "time": 2})["group"]
    r = c.send("plugin.drop", {"from": mh, "plugin": ip, "to": zone})
    check("M10 ... on an audio group (a recording zone) too", r["refused"] is True and r["placed"] is False, r)
    check("M10 ... and nothing moved", row10()["instrument"] == "DLSMusicDevice" and inst_of(zone) == [])
    depth = c.send("perf.census")["undo_depth"]
    r = c.send("plugin.drop", {"from": mh, "plugin": ip, "to": clip, "mode": "copy"})
    check("M10 copy (⌥) onto a MIDI clip: the clip has it, the input keeps it, one undo point",
          r["placed"] is True and inst_of(clip) == ["DLSMusicDevice"] and row10()["instrument"] == "DLSMusicDevice"
          and c.send("perf.census")["undo_depth"] == depth + 1, r)
    c.send("edit.undo", {})
    check("M10 undo of the copy: the clip has none again", inst_of(clip) == [] and row10()["instrument"] == "DLSMusicDevice")
    c.send("input.monitor", {"midi": dev, "on": True})
    check("M10 the input is heard through its instrument", row10()["heard"] is True, row10())
    depth = c.send("perf.census")["undo_depth"]
    r = c.send("plugin.drop", {"from": mh, "plugin": ip, "to": clip})
    check("M10 move onto a MIDI clip: the clip has it, the input has none", r["placed"] is True
          and inst_of(clip) == ["DLSMusicDevice"] and row10()["instrument"] is None, r)
    check("M10 ... and it is no longer heard (nothing plays its notes)", row10()["heard"] is False, row10())
    check("M10 ... one undo point", c.send("perf.census")["undo_depth"] == depth + 1)
    c.send("edit.undo", {})
    check("M10 undo of the move: the input has its instrument back, the clip none",
          row10()["instrument"] == "DLSMusicDevice" and inst_of(clip) == [])
    # to a group (eligible: it holds a MIDI clip only)
    gid = c.send("group.create", {"ids": [clip]})["id"]
    ip = c.send("plugin.list", {"host": mh})["instruments"][0]["id"]
    r = c.send("plugin.drop", {"from": mh, "plugin": ip, "to": gid, "mode": "copy"})
    check("M10 copy onto a group that holds MIDI only: the group carries the instrument",
          r["placed"] is True and inst_of(gid) == ["DLSMusicDevice"], r)
    gip = c.send("plugin.list", {"host": gid})["instruments"][0]["id"]
    clip2 = c.send("midi.create_clip", {"start": 4, "end": 6, "lane": 8})["id"]
    r = c.send("plugin.drop", {"from": gid, "plugin": gip, "to": clip2})
    check("M10 an instrument moves from a GROUP to a clip (the source is read by host)",
          r["placed"] is True and inst_of(clip2) == ["DLSMusicDevice"] and inst_of(gid) == [], r)

    # M12: the LISTENING level of a MIDI input (inputs panel, step 7): an ObjGain after the instrument and its FX
    c.send("project.new")
    c.send("input.set_instrument", {"midi": dev, **instp})
    mh = next(d for d in c.send("input.list.midi_inputs")["midi_inputs"] if d["id"] == dev)["host_id"]
    c.send("input.monitor", {"midi": dev, "on": True})
    c.send("midi.virtual.send", {"events": [{"kind": "on", "note": 48, "velocity": 100}, {"kind": "off", "note": 48, "delay_ms": 300}]})
    time.sleep(2.0)
    v0 = play60()
    check("M12 0 dB: the note is heard (%.3f)" % v0, v0 > 0.02, v0)
    out = c.send("input.set_monitor_gain", {"midi": dev, "db": -24})
    row = next(d for d in out["midi_inputs"] if d["id"] == dev)
    check("M12 input.set_monitor_gain {midi}: monitor_gain_db in input.list.midi_inputs", row["monitor_gain_db"] == -24, row)
    v1 = play60()
    check("M12 -24 dB: the note is far quieter (%.4f << %.3f)" % (v1, v0), v1 < 0.3 * v0, (v1, v0))
    c.send("plugin.add", {"host": mh, **LPF})
    time.sleep(1.0)
    v2 = play60()
    check("M12 an FX added BEHIND the instrument stays in front of the gain (%.4f)" % v2, v2 < 0.3 * v0, (v2, v0))
    c.send("input.set_monitor_gain", {"midi": dev, "db": 0})
    v3 = play60()
    check("M12 back to 0 dB (%.3f)" % v3, v3 > 0.8 * v0, (v3, v0))
    c.send("input.monitor", {"midi": dev, "on": False})
    c.send("input.host", {"midi": dev, "open": False})
    out = c.send("input.set_monitor_gain", {"midi": dev, "db": -24})
    check("M12 set while the chain is unmounted: held", next(d for d in out["midi_inputs"] if d["id"] == dev)["monitor_gain_db"] == -24)
    c.send("input.monitor", {"midi": dev, "on": True})
    time.sleep(1.0)
    v4 = play60()
    check("M12 ... and applied when the chain is mounted again (%.4f)" % v4, v4 < 0.3 * v0, (v4, v0))
    c.send("input.set_monitor_gain", {"midi": dev, "db": 0})
    c.send("input.monitor", {"midi": dev, "on": False})
    r = refused_cmd(c, "input.set_monitor_gain", midi="nope", db=3)
    check("M12 an unknown MIDI input: not_found", r == "not_found", r)

    # M11: drops ON the rectangles (inputs panel, step 6): the host of the input is the target of `plugin.drop`
    c.send("project.new")
    c.send("input.enable")
    ah = c.send("input.host", {"first": 0, "open": False})["host_id"]
    mh = c.send("input.host", {"midi": dev, "open": False})["host_id"]
    clip = c.send("midi.create_clip", {"start": 0, "end": 2, "lane": 0})["id"]
    cfx = c.send("plugin.add", {"host": clip, **LPF})["plugin"]["id"]
    depth = c.send("perf.census")["undo_depth"]
    r = c.send("plugin.drop", {"from": clip, "plugin": cfx, "to": ah, "mode": "copy"})
    check("M11 an FX dropped (copy) on a card input's host joins its chain, one undo point",
          r["placed"] is True and len(plist(ah)) == 1 and c.send("perf.census")["undo_depth"] == depth + 1, r)
    placed = plist(ah)[0]["id"]
    check("M11 ... the host was not held open: the chain is not left mounted", absent(placed))
    check("M11 ... the source kept its own (a copy)", [p["id"] for p in plist(clip)] == [cfx])
    r = c.send("plugin.drop", {"from": clip, "plugin": cfx, "to": mh})
    check("M11 an FX dropped (move) on a MIDI input's host joins its chain, after the (absent) instrument",
          r["placed"] is True and len(plist(mh)) == 1 and plist(clip) == [], r)
    inst_clip = c.send("midi.create_clip", {"start": 4, "end": 6, "lane": 1})["id"]
    c.send("instrument.set", {"id": inst_clip, **instp})
    ic = c.send("plugin.list", {"host": inst_clip})["instruments"][0]["id"]
    r = c.send("plugin.drop", {"from": inst_clip, "plugin": ic, "to": ah})
    check("M11 an instrument on an AUDIO input is refused", r["refused"] is True and r["placed"] is False, r)
    r = c.send("plugin.drop", {"from": inst_clip, "plugin": ic, "to": mh})
    row = next(d for d in c.send("input.list.midi_inputs")["midi_inputs"] if d["id"] == dev)
    check("M11 an instrument on a MIDI input is taken (move): the clip loses it, the FX stay behind it",
          r["placed"] is True and row["instrument"] == "DLSMusicDevice" and row["fx_count"] == 1
          and c.send("plugin.list", {"host": inst_clip})["instruments"] == [], r)
    first = c.send("plugin.list", {"host": mh})["instruments"][0]["id"]
    c.send("instrument.set", {"id": inst_clip, **instp})
    ic = c.send("plugin.list", {"host": inst_clip})["instruments"][0]["id"]
    r = c.send("plugin.drop", {"from": inst_clip, "plugin": ic, "to": mh, "mode": "copy"})
    second = c.send("plugin.list", {"host": mh})["instruments"][0]["id"]
    row = next(d for d in c.send("input.list.midi_inputs")["midi_inputs"] if d["id"] == dev)
    check("M11 ... a second one REPLACES the first (new id), the FX still there",
          r["placed"] is True and second != first and row["fx_count"] == 1, (first, second))
    # during a recording (a recording needs a saved project)
    c.send("project.save_as", {"path": os.path.join(WORK, "m11", "p", "p.objekat.json")})
    zone = c.send("rec.drop", {"first": 1, "count": 1, "lane": 6, "time": 2})["group"]
    c.send("rec.arm", {"group": zone, "on": True})
    c.send("transport.seek", {"seconds": 0})
    c.send("rec.start")
    r = c.send("plugin.drop_at", {"from": inst_clip, "plugin": ic, "host": ah, "mode": "copy", "dry_run": True})
    c.send("rec.stop")
    c.send("rec.arm", {"group": zone, "on": False})
    time.sleep(1.0)
    check("M11 nothing is dropped on an input during a recording", r["refused"] is True, r)
    # an FX link bin
    a2 = c.send("plugin.add", {"host": inst_clip, **LPF})["plugin"]["id"]
    c.send("plugin.add", {"host": inst_clip, **LPF})
    lk = c.send("fxlink.create", {"host": inst_clip, "plugins": [a2]})
    blk = next((p["id"] for p in plist(inst_clip) if p.get("is_fx_block")), None)
    check("M11 (an FX link bin was made to be dropped)", blk is not None, plist(inst_clip))
    if blk is not None:
        r = c.send("plugin.drop_at", {"from": inst_clip, "plugin": blk, "host": ah, "dry_run": True})
        check("M11 an FX link bin on an input is refused", r["refused"] is True, r)


def e11(c, instp, dev):
    LPF = {"identifier": "aufx,lpas,appl"}

    def loaded(pid):
        for _ in range(60):
            try:
                c.send("debug.plugin_buses", {"plugin": pid})
                return True
            except ObjekatError:
                time.sleep(0.25)
        return False

    def absent(pid):
        try:
            c.send("debug.plugin_buses", {"plugin": pid})
            return False
        except ObjekatError as e:
            return e.code == "not_found"

    def cutoff(pid):
        for prm in c.send("plugin.get_params", {"plugin": pid}).get("params", []):
            if "cutoff" in prm["name"].lower():
                return prm["index"], prm["value"]
        return None, None

    def lst(host):
        return c.send("plugin.list", {"host": host})

    c.send("project.new")
    c.send("audio.virtual.set_input", {"channel": 0, "signal": "sine", "frequency": 440, "amplitude": 0.5})
    c.send("input.enable")
    host = c.send("input.host", {"first": 0})["host_id"]
    pid = c.send("plugin.add", {"host": host, **LPF})["plugin"]["id"]
    loaded(pid)
    k, _ = cutoff(pid)
    c.send("plugin.set_param", {"plugin": pid, "index": k, "value": 0.003})
    time.sleep(0.3)
    _, set_value = cutoff(pid)

    # H4: a card input with FX
    depth = c.send("perf.census")["undo_depth"]
    r = c.send("rec.drop", {"first": 0, "count": 1, "lane": 0, "time": 1})
    g1 = r["group"]
    check("H4 the zone is created and says what it took (fx 1)", r["outcome"] == "create" and (r.get("inherited") or {}).get("fx") == 1, r)
    check("H4 ... one undo point for the whole gesture", c.send("perf.census")["undo_depth"] == depth + 1)
    copy = lst(g1)["plugins"]
    check("H4 the zone holds ONE copy, with an id of its own", len(copy) == 1 and copy[0]["id"] != pid, copy)
    cid = copy[0]["id"]
    check("H4 ... mounted on the zone", loaded(cid))
    time.sleep(1.5)                           # (the state restore of a fresh instance lands on its own time)
    ck, cv = cutoff(cid)
    check("H4 ... with the input's setting (%.4f ~ %.4f)" % (cv or -1, set_value or -1), cv is not None and abs(cv - set_value) < 0.002, (cv, set_value))
    check("H4 ... and the input's chain is unchanged", [p["id"] for p in lst(host)["plugins"]] == [pid])

    # H2: each side on its own
    c.send("plugin.set_param", {"plugin": cid, "index": ck, "value": 0.9})
    for _ in range(20):                       # the AU takes the value on its own time
        time.sleep(0.25)
        if abs(cutoff(cid)[1] - 0.9) < 0.01:
            break
    check("H2 the zone's copy moved, the input's FX did not", abs(cutoff(cid)[1] - 0.9) < 0.01 and abs(cutoff(pid)[1] - set_value) < 0.002, (cutoff(cid), cutoff(pid)))
    c.send("plugin.set_param", {"plugin": pid, "index": k, "value": 0.2})
    for _ in range(20):
        time.sleep(0.25)
        if abs(cutoff(pid)[1] - 0.2) < 0.01:
            break
    check("H2 the input's FX moved, the zone's copy did not", abs(cutoff(pid)[1] - 0.2) < 0.01 and abs(cutoff(cid)[1] - 0.9) < 0.01, (cutoff(cid), cutoff(pid)))

    # H3: a zone from a bare input inherits nothing; dropped on again by an input WITH FX, an ENTIRELY EMPTY group
    # takes the copy (inputs panel, step 3) — and says so (`inherited` also on an assign)
    r0 = c.send("rec.drop", {"first": 1, "count": 1, "lane": 2, "time": 1})
    g3 = r0["group"]
    check("H3 a zone from a bare input inherits nothing", r0["outcome"] == "create" and "inherited" not in r0 and lst(g3)["plugins"] == [], r0)
    depth = c.send("perf.census")["undo_depth"]
    r1 = c.send("rec.drop", {"first": 0, "count": 1, "lane": 2, "time": 2})
    check("H3 dropping an input WITH FX on the empty zone assigns AND copies", r1["outcome"] == "assign" and r1["target"] == g3
          and (r1.get("inherited") or {}).get("fx") == 1, r1)
    c3 = lst(g3)["plugins"]
    check("H3 ... one copy with an id of its own, one undo point", len(c3) == 1 and c3[0]["id"] != pid
          and c.send("perf.census")["undo_depth"] == depth + 1, c3)
    # a group that holds something keeps its chain: only its source changes
    depth = c.send("perf.census")["undo_depth"]
    r1b = c.send("rec.drop", {"first": 1, "count": 1, "lane": 2, "time": 2})
    check("H7 a NON-empty group (it has an FX) keeps its chain, only the source changes",
          r1b["outcome"] == "assign" and "inherited" not in r1b and [p["id"] for p in lst(g3)["plugins"]] == [c3[0]["id"]]
          and c.send("perf.census")["undo_depth"] == depth + 1, r1b)
    # the same source dropped again on a non-empty group: nothing changes, no undo point
    depth = c.send("perf.census")["undo_depth"]
    c.send("rec.drop", {"first": 1, "count": 1, "lane": 2, "time": 2})
    check("H7 ... a redrop of the same source on it changes nothing, no undo point", c.send("perf.census")["undo_depth"] == depth)

    # H8: a redrop of the SAME source on a group that is still empty copies, with its undo point
    ra = c.send("rec.drop", {"first": 2, "count": 1, "lane": 10, "time": 1})        # input 3: bare
    g8 = ra["group"]
    h2 = c.send("input.host", {"first": 2})["host_id"]
    p8 = c.send("plugin.add", {"host": h2, **LPF})["plugin"]["id"]                 # ... now it carries an FX
    depth = c.send("perf.census")["undo_depth"]
    rb = c.send("rec.drop", {"first": 2, "count": 1, "lane": 10, "time": 2})
    c8 = lst(g8)["plugins"]
    check("H8 same source, group still empty: assigns, copies, says so", rb["outcome"] == "assign" and rb["target"] == g8
          and (rb.get("inherited") or {}).get("fx") == 1 and len(c8) == 1 and c8[0]["id"] != p8, (rb, c8))
    check("H8 ... and the redrop made an undo point (it changed something)", c.send("perf.census")["undo_depth"] == depth + 1)
    c.send("edit.undo", {})
    check("H8 undo takes the copy away again", lst(g8)["plugins"] == [])
    c.send("input.host", {"first": 2, "open": False})

    # H9: assigning from the menu (rec.assign) copies nothing, even on an empty group
    rc = c.send("rec.drop", {"first": 1, "count": 1, "lane": 12, "time": 1})
    g9 = rc["group"]
    c.send("rec.assign", {"group": g9, "first": 0, "count": 1})
    check("H9 rec.assign on an empty group copies nothing", lst(g9)["plugins"] == [])

    # H10: a group with a send is not empty (the send is something the user built)
    rd = c.send("rec.drop", {"first": 1, "count": 1, "lane": 14, "time": 1})
    g10 = rd["group"]
    au = c.send("aux.create", {"start": 0, "end": 6, "lane": 20})["id"]
    c.send("send.create", {"id": g10, "aux": au})
    r10 = c.send("rec.drop", {"first": 0, "count": 1, "lane": 14, "time": 2})
    check("H10 a group that carries a send is NOT empty: assigns, copies nothing",
          r10["outcome"] == "assign" and r10["target"] == g10 and "inherited" not in r10 and lst(g10)["plugins"] == [], r10)

    # H1: a MIDI input with an instrument
    c.send("input.set_instrument", {"midi": dev, **instp})
    ihost = next(d for d in c.send("input.list.midi_inputs")["midi_inputs"] if d["id"] == dev)["host_id"]
    inst_id = lst(ihost)["instruments"][0]["id"]
    r2 = c.send("rec.drop", {"midi": dev, "lane": 4, "time": 1})
    g2 = r2["group"]
    check("H1 the MIDI zone says it took the instrument", r2["outcome"] == "create" and (r2.get("inherited") or {}).get("instrument") == "DLSMusicDevice", r2)
    zi = lst(g2)["instruments"]
    check("H1 ... a copy of its own (new id)", len(zi) == 1 and zi[0]["id"] != inst_id and zi[0]["name"] == "DLSMusicDevice", zi)
    check("H1 ... and the input still has its instrument", [i["id"] for i in lst(ihost)["instruments"]] == [inst_id])
    r3 = c.send("rec.drop", {"midi": dev, "lane": 4, "time": 2})
    check("H3 a second drop of the same MIDI input assigns and leaves the zone's instrument alone",
          r3["outcome"] == "assign" and [i["id"] for i in lst(g2)["instruments"]] == [zi[0]["id"]], r3)

    # H2 for the instrument: the input loses its own, the zone keeps its copy
    c.send("input.remove_instrument", {"midi": dev})
    check("H2 the input's instrument is removed, the zone's copy stays", lst(ihost)["instruments"] == [] and len(lst(g2)["instruments"]) == 1)

    # H5: several inputs at once
    c.send("input.set_instrument", {"midi": dev, **instp})
    r5 = c.send("rec.drop", {"inputs": [{"first": 0, "count": 1}, {"midi": dev}], "lane": 6, "time": 1})
    d5 = r5["drops"]
    check("H5 both lanes are created and each inherits its own",
          len(d5) == 2 and d5[0].get("inherited", {}).get("fx") == 1 and d5[1].get("inherited", {}).get("instrument") == "DLSMusicDevice", r5)
    check("H5 ... the FX on the audio zone, the instrument on the MIDI one",
          len(lst(d5[0]["group"])["plugins"]) == 1 and len(lst(d5[1]["group"])["instruments"]) == 1)

    # H6: an input that is not mounted
    c.send("input.host", {"first": 0, "open": False})
    check("H6 the input chain is not mounted (closed, not heard)", absent(pid))
    r6 = c.send("rec.drop", {"first": 0, "count": 1, "lane": 8, "time": 1})
    c6 = lst(r6["group"])["plugins"]
    check("H6 the zone still gets its copy", r6["outcome"] == "create" and len(c6) == 1 and c6[0]["id"] != pid, r6)
    check("H6 ... mounted on the zone, with the state the model kept (%.3f)" % 0.2,
          loaded(c6[0]["id"]) and abs(cutoff(c6[0]["id"])[1] - 0.2) < 0.01, cutoff(c6[0]["id"]))

    # H4: one undo removes the zone and nothing of the input
    c.send("edit.undo", {})
    check("H4 undo removes the last zone; the input's chain is intact", [p["id"] for p in lst(host)["plugins"]] == [pid])


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
        e11(c, instp, dev)
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

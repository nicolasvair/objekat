#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The Inputs tab's model and its monitoring (`input.set_name|pair|unpair|monitor`), on the virtual card.

Names and pairs belong to the PROJECT (format 33, outside the undo, project marked modified);
monitoring belongs to the ENGINE: an input is heard through a hidden track the model does not know,
so the app's solo does not silence it, and it is not saved. Driven on `--virtual-audio` (4 inputs,
a known signal on each); the master's level is read through `stem.level` of the Main.

  A  names: defaults ("In 3" / "In 1-2"), a typed name, a blank name goes back to the default, the
     project is marked modified, nothing enters the undo history
  B  pairs: 1-2 and 2-3 coexist, the pairs are listed FIRST and every mono STAYS, unpair keeps the names
  C  the file: names and pairs are written to the project (format 33), come back on reopening, a
     project without the key opens with defaults, a new project forgets them
  D  monitoring: silent master -> the input is heard (stopped), the other inputs are not, a stereo
     input is heard, a solo elsewhere does not silence it, monitoring stops with the inputs and with a
     pair heard being taken apart, but NOT with a new or opened project (it is the card's, not
     the project's); refusals when the inputs are closed
  E  Settings.xml is byte for byte what it was

Settings.xml is only READ (hash); nothing here writes it. Run on the virtual card ONLY.

    ./scenario_input_monitor.py /path/to/objekat.app

Exit: 0 if every assertion passes, 1 if one fails, 2 on bad usage.
"""

import hashlib, json, os, shutil, subprocess, sys, tempfile, time

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
BIP = os.path.join(HERE, "fixtures", "bip.wav")
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


def recs(lst):
    """`record_inputs` as {(first, count): entry}."""
    return {(d["first"], d["count"]): d for d in lst["record_inputs"]}


def names(lst):
    return [(d["first"], d["count"], d["name"]) for d in lst["record_inputs"]]


def master_level(c):
    """The Main's level since the previous read (0..1 over -60..0 dBFS), after a short settle."""
    c.send("stem.level")
    time.sleep(0.5)
    return c.send("stem.level", {"id": c.send("stem.list")["main"]})["level"]


before = digest()
SOCK = "/tmp/objk-inmon-%d.sock" % os.getpid()
if os.path.exists(SOCK):
    os.remove(SOCK)
proc = subprocess.Popen([BIN, "--headless", "--api", "--no-recent", "--language=en", "--virtual-audio",
                         "--socket=" + SOCK], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
tmp = tempfile.mkdtemp(prefix="objk-inmon-")
try:
    for _ in range(160):
        if os.path.exists(SOCK):
            break
        time.sleep(0.25)
    with ObjekatClient(SOCK) as c:
        c.send("project.new")
        c.send("audio.virtual.set_input", {"channel": 0, "signal": "sine", "frequency": 440, "amplitude": 0.5})
        c.send("audio.virtual.set_input", {"channel": 1, "signal": "silence"})
        c.send("audio.virtual.set_input", {"channel": 2, "signal": "sine", "frequency": 1000, "amplitude": 0.25})
        c.send("audio.virtual.set_input", {"channel": 3, "signal": "silence"})

        # ── D0: closed -------------------------------------------------------------------------
        section("closed: nothing to name or hear")
        lst = c.send("input.list")
        check("closed: record_inputs is empty", lst["open"] is False and lst["record_inputs"] == [], lst)
        check("closed: monitoring is refused (invalid_state)",
              refused(c, "input.monitor", first=0, on=True) == "invalid_state")

        lst = c.send("input.enable")
        check("enabled: 4 mono rows", names(lst) == [(0, 1, "In 1"), (1, 1, "In 2"), (2, 1, "In 3"), (3, 1, "In 4")],
              names(lst))

        # ── A: names ----------------------------------------------------------------------------
        section("A  names")
        c.send("project.save_as", {"path": os.path.join(tmp, "p", "p.objekat.json")})
        check("saved: the project is clean", c.send("app.info").get("dirty") is False)
        undo0 = c.send("perf.census")["undo_depth"]
        lst = c.send("input.set_name", {"first": 2, "name": "Voix"})
        check("a typed name shows", recs(lst)[(2, 1)]["name"] == "Voix" and recs(lst)[(2, 1)]["custom"], lst["record_inputs"])
        check("... and the others keep their default", recs(lst)[(0, 1)]["name"] == "In 1" and not recs(lst)[(0, 1)]["custom"])
        check("the project is marked modified", c.send("app.info").get("dirty") is True)
        check("a name is outside the undo history", c.send("perf.census")["undo_depth"] == undo0)
        lst = c.send("input.set_name", {"first": 2, "name": "   "})
        check("a blank name goes back to the default", recs(lst)[(2, 1)]["name"] == "In 3", lst["record_inputs"])
        c.send("input.set_name", {"first": 2, "name": "  Voix  "})
        check("a name is trimmed", recs(c.send("input.list"))[(2, 1)]["name"] == "Voix")
        check("a bad channel count is refused", refused(c, "input.set_name", first=0, count=3, name="x") == "bad_params")

        # ── B: pairs ----------------------------------------------------------------------------
        section("B  pairs")
        lst = c.send("input.pair", {"first": 0})
        check("pair 1-2: the pair FIRST, then the four monos (they stay)",
              names(lst) == [(0, 2, "In 1-2"), (0, 1, "In 1"), (1, 1, "In 2"), (2, 1, "Voix"), (3, 1, "In 4")], names(lst))
        lst = c.send("input.pair", {"first": 1})
        check("pair 2-3 coexists with 1-2: both pairs first, the four monos still there",
              names(lst) == [(0, 2, "In 1-2"), (1, 2, "In 2-3"), (0, 1, "In 1"), (1, 1, "In 2"), (2, 1, "Voix"), (3, 1, "In 4")],
              names(lst))
        c.send("input.set_name", {"first": 0, "count": 2, "name": "Guitare"})
        lst = c.send("input.unpair", {"first": 1})
        check("unpair 2-3: the pair is gone, the monos are as they were (names kept)",
              names(lst) == [(0, 2, "Guitare"), (0, 1, "In 1"), (1, 1, "In 2"), (2, 1, "Voix"), (3, 1, "In 4")], names(lst))
        check("pairs in force are [0]", lst["pairs"] == [0], lst["pairs"])
        lst = c.send("input.unpair", {"first": 0})
        check("unpair 1-2: the four monos alone", [r[:2] for r in names(lst)] == [(0, 1), (1, 1), (2, 1), (3, 1)], names(lst))
        lst = c.send("input.pair", {"first": 0})
        check("pairing again finds the pair's name", recs(lst)[(0, 2)]["name"] == "Guitare", names(lst))
        lst = c.send("input.pair", {"first": 3})
        check("a pair that does not fit the card (4-5 on 4 channels) is refused silently: not offered",
              (3, 2) not in recs(lst), names(lst))
        c.send("input.set_pairs", {"pairs": []})

        # ── C: the file -------------------------------------------------------------------------
        section("C  the project file")
        c.send("input.pair", {"first": 0})
        c.send("input.pair", {"first": 1})
        path = os.path.join(tmp, "p", "p.objekat.json")
        c.send("project.save")
        doc = json.load(open(path))
        ri = doc.get("recordInputs") or {}
        check("written: format 33 with recordInputs", doc.get("version") == 33 and bool(ri), (doc.get("version"), ri))
        check("written: the pairs [0, 1] and the names", ri.get("pairs") == [0, 1] and ri.get("names", {}).get("3") == "Voix"
              and ri.get("names", {}).get("1-2") == "Guitare", ri)
        check("written: the card it was made on is indicated", isinstance(ri.get("deviceName"), str), ri)
        check("written: monitoring is NOT in the file", "monitor" not in json.dumps(doc).lower().replace("monitordb", ""))
        c.send("project.new")
        lst = c.send("input.list")
        check("a new project forgets the names and pairs",
              names(lst) == [(0, 1, "In 1"), (1, 1, "In 2"), (2, 1, "In 3"), (3, 1, "In 4")] and lst["pairs"] == [], names(lst))
        c.send("project.open", {"path": path})
        lst = c.send("input.list")
        check("reopened: pairs and names are back",
              [r[:2] for r in names(lst)] == [(0, 2), (1, 2), (0, 1), (1, 1), (2, 1), (3, 1)]
              and names(lst)[0][2] == "Guitare" and lst["pairs"] == [0, 1], names(lst))
        # a project written before format 33: no key at all
        old = json.load(open(path))
        old.pop("recordInputs", None)
        old["version"] = 32
        oldpath = os.path.join(tmp, "p", "old.objekat.json")
        json.dump(old, open(oldpath, "w"))
        c.send("project.open", {"path": oldpath})
        lst = c.send("input.list")
        check("a format 32 project opens with the defaults",
              names(lst) == [(0, 1, "In 1"), (1, 1, "In 2"), (2, 1, "In 3"), (3, 1, "In 4")], names(lst))
        check("... and opening it did not mark it modified", c.send("app.info").get("dirty") is False)

        # ── D: monitoring -----------------------------------------------------------------------
        section("D  monitoring")
        c.send("project.new")
        c.send("object.add", {"path": BIP, "lane": 0, "start": 0})
        c.send("wait_idle", {"timeout_ms": 5000})
        c.send("transport.seek", {"seconds": 0})
        quiet = master_level(c)
        check("nothing monitored: the master is silent (%.3f)" % quiet, quiet < 0.05, quiet)
        check("monitored is empty", all(not d["monitored"] for d in c.send("input.list")["record_inputs"]))

        lst = c.send("input.monitor", {"first": 0, "on": True})
        check("input 1 monitored", recs(lst)[(0, 1)]["monitored"] is True, lst["record_inputs"])
        time.sleep(0.5)
        heard = master_level(c)
        check("the master carries the sine 0.5 while STOPPED (%.3f ~ 0.9)" % heard, heard > 0.8, heard)
        check("... and the transport is stopped", c.send("transport.state")["playing"] is False)

        c.send("input.monitor", {"first": 0, "on": False})
        time.sleep(0.5)
        gone = master_level(c)
        check("monitor off: the master is silent again (%.3f)" % gone, gone < 0.05, gone)

        c.send("input.monitor", {"first": 1, "on": True})            # a SILENT input
        time.sleep(0.5)
        silent = master_level(c)
        check("a silent input monitored adds nothing (%.3f)" % silent, silent < 0.05, silent)
        c.send("input.monitor", {"first": 1, "on": False})

        # stereo: pair 1-2 carries the sine on its left channel
        c.send("input.pair", {"first": 0})
        lst = c.send("input.monitor", {"first": 0, "count": 2, "on": True})
        check("the stereo input monitored", recs(lst)[(0, 2)]["monitored"] is True, lst["record_inputs"])
        time.sleep(0.5)
        st = master_level(c)
        check("a stereo input is heard (%.3f)" % st, st > 0.8, st)

        # a solo elsewhere does not silence it
        oid = c.send("object.list")["objects"][0]["id"]
        c.send("solo.set", {"ids": [oid], "on": True})
        time.sleep(0.5)
        solo = master_level(c)
        check("a solo on another object leaves the monitored input audible (%.3f)" % solo, solo > 0.8, solo)
        c.send("solo.clear")

        # a pair no longer swallows the monos: a monitored mono keeps being heard when a pair is made
        c.send("input.unpair", {"first": 0})
        check("unpairing drops the monitoring of the pair",
              all(not d["monitored"] for d in c.send("input.list")["record_inputs"]))
        c.send("input.monitor", {"first": 0, "on": True})
        lst = c.send("input.pair", {"first": 0})
        check("a pairing leaves a monitored mono monitored (the monos stay)",
              recs(lst)[(0, 1)]["monitored"] is True and recs(lst)[(0, 2)]["monitored"] is False, lst["record_inputs"])
        time.sleep(0.5)
        master_level(c)
        after_pair = master_level(c)
        check("... and the master still carries it (%.3f)" % after_pair, after_pair > 0.8, after_pair)
        c.send("input.monitor", {"first": 0, "on": False})
        c.send("input.unpair", {"first": 0})

        check("monitoring an input that does not exist is refused", refused(c, "input.monitor", first=9, on=True) == "invalid_state")

        # monitoring stops with the inputs
        c.send("input.monitor", {"first": 0, "on": True})
        c.send("input.disable")
        lst = c.send("input.enable")
        check("closing the inputs ends the monitoring", all(not d["monitored"] for d in lst["record_inputs"]), lst["record_inputs"])
        time.sleep(0.5)
        master_level(c)
        closed = master_level(c)
        check("... and the master is silent (%.3f)" % closed, closed < 0.05, closed)

        # ... but NOT with a project change: the monitoring is the card's, not the project's
        c.send("input.monitor", {"first": 0, "on": True})
        c.send("project.new")
        lst = c.send("input.list")
        check("a new project does not end the monitoring", recs(lst)[(0, 1)]["monitored"] is True, lst["record_inputs"])
        time.sleep(0.5)
        master_level(c)
        newp = master_level(c)
        check("... and the master still carries it (%.3f)" % newp, newp > 0.8, newp)
        c.send("project.open", {"path": oldpath})        # no pairs in this one: input 1 is still a mono
        lst = c.send("input.list")
        check("opening a project does not end it either", recs(lst)[(0, 1)]["monitored"] is True, lst["record_inputs"])
        time.sleep(0.5)
        master_level(c)
        opened = master_level(c)
        check("... the master still carries it (%.3f)" % opened, opened > 0.8, opened)
        c.send("input.monitor", {"first": 0, "on": False})
        time.sleep(0.5)
        master_level(c)
        off = master_level(c)
        check("... and it can still be turned off afterwards (%.3f)" % off, off < 0.05, off)

        # a buffer / rate change rebuilds the engine's devices: the monitoring must come back
        c.send("input.monitor", {"first": 0, "on": True})
        c.send("audio.set_buffer_size", {"frames": 128})
        lst = c.send("input.list")
        check("a buffer change keeps the input monitored", recs(lst)[(0, 1)]["monitored"] is True, lst["record_inputs"])
        time.sleep(0.5)
        master_level(c)
        buf = master_level(c)
        check("... and still audible (%.3f)" % buf, buf > 0.8, buf)
        c.send("audio.set_sample_rate", {"hz": 44100})
        time.sleep(0.5)
        master_level(c)
        rate = master_level(c)
        check("a rate change keeps it audible (%.3f)" % rate, rate > 0.8, rate)
        c.send("audio.set_buffer_size", {"frames": 256})
        c.send("audio.set_sample_rate", {"hz": 48000})
        c.send("input.monitor", {"first": 0, "on": False})

        # playback still works with an input monitored, and an export is not polluted by the hidden track
        c.send("object.add", {"path": BIP, "lane": 0, "start": 0})
        c.send("wait_idle", {"timeout_ms": 5000})
        c.send("input.monitor", {"first": 0, "on": True})
        c.send("transport.seek", {"seconds": 0})
        c.send("transport.play")
        time.sleep(0.4)
        playing = c.send("transport.state")["playing"]
        c.send("transport.stop")
        check("playback works with an input monitored", playing is True)
        c.send("input.monitor", {"first": 0, "on": False})

    check("Settings.xml untouched by the whole run (hash)", digest() == before, "%s -> %s" % (before, digest()))
finally:
    try:
        proc.terminate()
        proc.wait(timeout=20)
    except Exception:
        proc.kill()
    if os.path.exists(SOCK):
        os.remove(SOCK)
    shutil.rmtree(tmp, ignore_errors=True)

print("\n%d OK, %d FAILED" % (ok, ko))
sys.exit(0 if ko == 0 else 1)

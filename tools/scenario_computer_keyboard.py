#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The « Computer Keyboard » MIDI input (`--virtual-audio`), headless, through `midi.keyboard.*`.

The mode turns the letter keys into notes on a Tracktion virtual device that is always listed (second,
after "All MIDI Ins"). `midi.keyboard.key` goes through the SAME router as the key monitor (the monitor's
own early exits -- text field, plugin window -- need a window and are NOT covered here; `input.key` is not used).
Keys are PHYSICAL keyCodes (AZERTY home row: q=0 d=2 g=5 ... w=6 octave down, x=7 octave up).

  A  the line: listed second, flagged, stable id; mode OFF at launch (keys pass through, nothing heard)
  B  the mode: activity velocity 100 on the keyboard and NOT on "All MIDI Ins"; no note on u-grave / a / r / i;
     no capture with cmd ctrl alt shift; a repeat swallowed; octave keys and the octave range; the mode is
     outside the undo
  C  a zone made by rec.drop, a take with the right pitches (one undo), "All MIDI Ins" receives nothing
  D  listening: instrument + input.monitor -> RMS above the threshold; no monitor -> silence (armed is not hearing)
  D2 the instrument's output on the row's meter: > 0 while the transport is stopped and the input is heard; none unheard
  E  octave change with a note held (the note-off is the pitch fixed at the press), allNotesOff (mode off, tab switch)
  F  save / reopen: the zone finds its source again, the mode is not in the file
  G  Settings.xml has no trace of the device

    ./scenario_computer_keyboard.py /path/to/objekat.app

Exit: 0 if every assertion passes, 1 if one fails, 2 on bad usage.
"""

import hashlib, os, re, subprocess, sys, tempfile, time

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

# physical keyCodes
Q, D, G, W, X = 0, 2, 5, 6, 7
KC_UGRAVE, KC_A, KC_R, KC_I = 39, 12, 15, 34


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


def settings_bytes():
    try:
        with open(SETTINGS, "rb") as f:
            return f.read()
    except FileNotFoundError:
        return None


def normalised(raw):
    """Settings.xml without audioDeviceRate (the known false failure of the plain hash) and without the <PLUGIN/>
    entries of the plugin list, which the app rewrites in another order / subset at every exit (measured, with no
    device involved)."""
    if raw is None:
        return None
    raw = re.sub(rb'audioDeviceRate="[^"]*"', b"", raw)
    raw = re.sub(rb"<PLUGIN\b.*?/>", b"", raw, flags=re.S)
    return hashlib.sha256(raw).hexdigest()[:16]


def refused(c, cmd, **params):
    try:
        c.send(cmd, params or None)
        return None
    except ObjekatError as e:
        return e.code


def undo_depth(c):
    return c.send("perf.census")["undo_depth"]


def activity(c):
    """Velocity per input id. A REAL controller plugged in can add its own id (seen: midiin_xxx at 127): callers
    judge the keyboard's id and 'All MIDI Ins' only, and 'All MIDI Ins' by the velocity 100 (the keyboard's)."""
    return {a["id"]: a["velocity"] for a in c.send("input.levels.midi_activity")["activity"]}


def keyboard_activity(act, ck):
    return {k: v for k, v in act.items() if k == ck or (k == "all_midi_in" and v == 100)}


def master_level(c):
    c.send("stem.level")
    time.sleep(0.5)
    return c.send("stem.level", {"id": c.send("stem.list")["main"]})["level"]


def key(c, code, down=True, **kw):
    p = {"key_code": code, "down": down}
    p.update(kw)
    return c.send("midi.keyboard.key", p)


def tap(c, code, hold=0.25):
    d = key(c, code, True)
    time.sleep(hold)
    u = key(c, code, False)
    return d, u


def make_zone(c, midi, start, end, lane):
    c.send("timesel.set", {"start": start, "end": end, "lanes": [lane]})
    r = c.send("rec.drop", {"midi": midi, "lane": lane, "time": (start + end) / 2})
    c.send("timesel.clear")
    assert r["outcome"] == "create", r
    return r["group"]


def zone_status(c, gid):
    return next((z for z in c.send("rec.status")["zones"] if z["id"] == gid), None)


def wait_pos(c, t, timeout=30):
    end = time.time() + timeout
    while time.time() < end:
        if c.send("transport.state")["position"] >= t:
            return True
        time.sleep(0.03)
    return False


settings_before = settings_bytes()
SOCK = "/tmp/objk-ckbd-%d.sock" % os.getpid()
if os.path.exists(SOCK):
    os.remove(SOCK)
tmp = tempfile.mkdtemp(prefix="objk-ckbd-")
proc = subprocess.Popen([BIN, "--headless", "--api", "--no-recent", "--language=en", "--virtual-audio",
                         "--socket=" + SOCK], stdout=subprocess.DEVNULL,
                        stderr=open(os.path.join(tmp, "app.err"), "w"),
                        env=dict(os.environ, OBJ_SKIP_REAL_CARD="1"))
try:
    for _ in range(160):
        if os.path.exists(SOCK):
            break
        time.sleep(0.25)
    with ObjekatClient(SOCK) as c:
        # ── A ----------------------------------------------------------------------------------------
        section("A  the line, and the mode OFF at launch")
        st0 = c.send("midi.keyboard.status")
        check("the mode is off at launch", st0["on"] is False, st0)
        check("octave 60 (C4) at launch", st0["octave"] == 60 and st0["octave_name"] == "C4", st0)
        check("nothing held", st0["held"] == [], st0)
        # The layout the keys are named after depends on the machine: only the shape is asserted.
        check("layout_family and layout_name are present (string or null)",
              "layout_family" in st0 and "layout_name" in st0
              and st0["layout_family"] in (None, "azerty", "qwerty", "qwertz")
              and (st0["layout_name"] is None or isinstance(st0["layout_name"], str)), st0)
        check("a known family is shown under its title",
              st0["layout_family"] is None or st0["layout_name"] == st0["layout_family"].upper(), st0)
        c.send("project.new")
        c.send("input.enable")
        lst = c.send("input.list.midi_inputs")["midi_inputs"]
        ids = [d["id"] for d in lst]
        CK = st0["device_id"]
        check("'All MIDI Ins' first, the keyboard SECOND", ids[:2] == ["all_midi_in", CK], ids)
        row = lst[1]
        check("the row is flagged computer_keyboard, and only it",
              row["computer_keyboard"] is True and sum(1 for d in lst if d.get("computer_keyboard")) == 1, row)
        check("the id is the stable hash form (vmidiin_...)", CK.startswith("vmidiin_"), CK)
        c.send("input.levels.midi_activity")
        r = key(c, Q, True)
        key(c, Q, False)
        check("mode off: a key passes through", r["decision"]["kind"] == "pass_through" if isinstance(r["decision"], dict)
              else r["decision"] == "pass_through", r)
        time.sleep(0.2)
        act_off = activity(c)
        check("mode off: no keyboard activity", keyboard_activity(act_off, CK) == {}, act_off)

        # ── B ----------------------------------------------------------------------------------------
        section("B  the mode: notes, refusals, octaves")
        d0 = undo_depth(c)
        s = c.send("midi.keyboard.set", {"on": True})
        check("midi.keyboard.set on", s["on"] is True, s)
        c.send("input.levels.midi_activity")
        r = key(c, Q, True)
        dec = r["decision"]
        dec_s = dec if isinstance(dec, str) else dec.get("kind", dec)
        check("q down: note_on 60", dec_s == "note_on" and r.get("note", dec.get("note") if isinstance(dec, dict) else None) == 60, r)
        check("held table holds q -> 60", {"key_code": Q, "note": 60} in r["held"], r["held"])
        time.sleep(0.2)
        act = activity(c)
        check("activity: velocity 100 on the keyboard", act.get(CK) == 100, act)
        check("'All MIDI Ins' does NOT receive the keyboard (no velocity 100 there)", act.get("all_midi_in") != 100, act)
        r = key(c, Q, False)
        dec = r["decision"]
        dec_s = dec if isinstance(dec, str) else dec.get("kind", dec)
        check("q up: note_off 60, table emptied", dec_s == "note_off" and r["held"] == [], r)

        def dec_of(r):
            dd = r["decision"]
            return dd if isinstance(dd, str) else dd.get("kind", dd)

        for name, code in (("u-grave", KC_UGRAVE), ("a", KC_A), ("r", KC_R), ("i", KC_I)):
            c.send("input.levels.midi_activity")
            r = key(c, code, True)
            key(c, code, False)
            time.sleep(0.1)
            a = activity(c)
            check("%s (keyCode %d) is not a note" % (name, code),
                  dec_of(r) in ("pass_through", "swallow") and r["held"] == [] and keyboard_activity(a, CK) == {}, (r, a))
        for flag in ("cmd", "ctrl", "alt", "shift"):
            c.send("input.levels.midi_activity")
            r = key(c, Q, True, flags=[flag])
            key(c, Q, False, flags=[flag])
            time.sleep(0.1)
            a = activity(c)
            check("q with %s: not captured" % flag, dec_of(r) == "pass_through" and keyboard_activity(a, CK) == {}, (r, a))
        r1 = key(c, Q, True)
        r2 = key(c, Q, True, repeat=True)
        check("a repeat is swallowed, the key stays held once",
              dec_of(r1) == "note_on" and dec_of(r2) == "swallow" and len(r2["held"]) == 1, (r1, r2))
        key(c, Q, False)
        check("octave keys: x -> 72", dec_of(key(c, X, True)) == "octave" and c.send("midi.keyboard.status")["octave"] == 72)
        key(c, X, False)
        check("octave keys: w twice -> 48", dec_of(key(c, W, True)) == "octave" and dec_of(key(c, W, True)) == "octave"
              and c.send("midi.keyboard.status")["octave"] == 48)
        key(c, W, False)
        r = key(c, Q, True)
        check("the notes follow the octave (q -> 48)", {"key_code": Q, "note": 48} in r["held"], r["held"])
        key(c, Q, False)
        for base in (0, 108):
            s = c.send("midi.keyboard.octave", {"base": base})
            check("base %d accepted" % base, s["octave"] == base, s)
        check("base 120 refused", refused(c, "midi.keyboard.octave", base=120) == "bad_params")
        check("base 7 (not a multiple of 12) refused", refused(c, "midi.keyboard.octave", base=7) == "bad_params")
        check("base -12 refused", refused(c, "midi.keyboard.octave", base=-12) == "bad_params")
        check("both base and delta refused", refused(c, "midi.keyboard.octave", base=60, delta=1) == "bad_params")
        check("neither refused", refused(c, "midi.keyboard.octave") == "bad_params")
        c.send("midi.keyboard.octave", {"base": 108})
        key(c, X, True); key(c, X, False)
        check("x at 108 stays at 108", c.send("midi.keyboard.status")["octave"] == 108)
        r = key(c, 41, True)
        key(c, 41, False)
        check("m at base 108 is MIDI 124 (still valid)", dec_of(r) == "note_on", r)
        c.send("midi.keyboard.octave", {"base": 0})
        key(c, W, True); key(c, W, False)
        check("w at 0 stays at 0", c.send("midi.keyboard.status")["octave"] == 0)
        s = c.send("midi.keyboard.octave", {"delta": 100})
        check("delta clamps to 108", s["octave"] == 108, s)
        s = c.send("midi.keyboard.octave", {"delta": -100})
        check("delta clamps to 0", s["octave"] == 0, s)
        c.send("midi.keyboard.octave", {"base": 60})
        check("mode and octave are outside the undo", undo_depth(c) == d0, (d0, undo_depth(c)))

        # ── C ----------------------------------------------------------------------------------------
        section("C  a zone on the keyboard, a take, 'All MIDI Ins' receives nothing")
        insts = c.send("plugin.list_available", {"instruments_only": True})["plugins"]
        DLS = next(p for p in insts if p["name"] == "DLSMusicDevice")
        INST = {"identifier": DLS["identifier"], "format": DLS["format"]}
        d0 = undo_depth(c)
        z1 = make_zone(c, CK, 0, 8, 0)
        zs = zone_status(c, z1)
        check("rec.drop made a MIDI zone on the keyboard input",
              zs is not None and zs["source"] == "midi" and zs["midi_input"]["id"] == CK, zs)
        check("one undo point for the drop", undo_depth(c) == d0 + 1, (d0, undo_depth(c)))
        c.send("instrument.set", {"id": z1, **INST})
        zall = make_zone(c, "all_midi_in", 10, 18, 1)
        zas = zone_status(c, zall)
        check("a zone on All MIDI Ins exists", zas is not None and zas["midi_input"]["id"] == "all_midi_in", zas)
        c.send("rec.arm", {"groups": [z1], "on": True})
        c.send("transport.seek", {"seconds": 0})
        d0 = undo_depth(c)
        c.send("rec.start")
        time.sleep(0.3)
        for code in (Q, D, G):
            tap(c, code, 0.3)
            time.sleep(0.2)
        wait_pos(c, 2.2)
        r = c.send("rec.stop")
        tk = r["last_takes"]
        check("one take, MIDI, on the keyboard zone", len(tk) == 1 and tk[0]["group"] == z1 and tk[0]["source"] == "midi", tk)
        pitches = [n["pitch"] for n in tk[0]["notes"]] if tk else []
        vels = [n["velocity"] for n in tk[0]["notes"]] if tk else []
        check("pitches 60 / 64 / 67 (q d g), all velocity 100", pitches == [60, 64, 67] and set(vels) == {100}, (pitches, vels))
        check("ONE undo point for the stop", undo_depth(c) == d0 + 1, (d0, undo_depth(c)))
        c.send("edit.undo")
        c.send("group.expand", {"id": z1, "expanded": True})
        left = [o for o in c.send("object.list")["objects"] if o["parent"] == z1]
        c.send("group.expand", {"id": z1, "expanded": False})
        check("one undo removes the whole take (the zone is empty again)", left == [], left)
        # a zone on All MIDI Ins receives NOTHING from the keyboard
        c.send("rec.arm", {"groups": [z1], "on": False})
        c.send("rec.arm", {"groups": [zall], "on": True})
        c.send("transport.seek", {"seconds": 9})
        c.send("rec.start")
        time.sleep(0.3)
        tap(c, Q, 0.3); tap(c, D, 0.3)
        wait_pos(c, 10.8)
        r = c.send("rec.stop")
        check("a zone on All MIDI Ins records nothing from the keyboard", r["last_takes"] == [], r["last_takes"])
        c.send("rec.arm", {"groups": [zall], "on": False})

        # ── D ----------------------------------------------------------------------------------------
        section("D  listening (armed is not hearing)")
        c.send("rec.arm", {"groups": [z1], "on": True})
        master_level(c)
        key(c, Q, True)
        time.sleep(0.8)
        armed = master_level(c)
        key(c, Q, False)
        check("armed, no input instrument, no monitor: SILENT (%.3f)" % armed, armed < 0.02, armed)
        c.send("rec.arm", {"groups": [z1], "on": False})
        check("input.monitor without an instrument is refused", refused(c, "input.monitor", midi=CK, on=True) == "invalid_state")
        ins = c.send("input.set_instrument", {"midi": CK, **INST})
        row = next(d for d in ins["midi_inputs"] if d["id"] == CK)
        check("input.set_instrument on the keyboard input", row["instrument"] is not None, row)
        master_level(c)
        key(c, Q, True)
        time.sleep(0.8)
        silent = master_level(c)
        key(c, Q, False)
        check("instrument but not monitored: SILENT (%.3f)" % silent, silent < 0.02, silent)
        c.send("input.monitor", {"midi": CK, "on": True})
        master_level(c)
        key(c, Q, True)
        time.sleep(0.8)
        heard = master_level(c)
        check("monitored: a held note is HEARD (%.3f)" % heard, heard > 0.05, heard)
        key(c, Q, False)

        # ── D2 (L10) ---------------------------------------------------------------------------------
        section("D2  the instrument's level on the MIDI row's meter (the transport is STOPPED)")

        def instrument_level(cc):
            row_ = next((e for e in cc.send("input.levels.midi_activity")["instrument_levels"] if e["id"] == CK), None)
            return row_ and row_["instrument_level"]

        check("the transport is stopped for this section", not c.send("transport.state")["playing"])
        instrument_level(c)         # the first call registers the measure
        key(c, Q, True)
        peak = 0.0
        for _ in range(20):
            time.sleep(0.05)
            v = instrument_level(c)
            peak = max(peak, v or 0.0)
        check("monitor on, a held note: instrument_level > 0 while stopped (%.3f)" % peak, peak > 0.0, peak)
        key(c, Q, False)
        act = {a["id"]: a for a in c.send("input.levels.midi_activity")["activity"]}
        check("an activity entry carries instrument_level (number or null)",
              all(("instrument_level" in a) for a in act.values()), act)
        c.send("input.monitor", {"midi": CK, "on": False})
        time.sleep(0.4)
        instrument_level(c)
        key(c, Q, True)
        time.sleep(0.5)
        off = instrument_level(c)
        key(c, Q, False)
        check("monitor off: instrument_level is null or 0 (%s)" % off, off is None or off == 0, off)
        c.send("input.monitor", {"midi": CK, "on": True})

        # ── E ----------------------------------------------------------------------------------------
        section("E  octave change with a note held, allNotesOff")
        c.send("midi.keyboard.octave", {"base": 60})
        key(c, Q, True)
        key(c, W, True); key(c, W, False)
        st = c.send("midi.keyboard.status")
        check("octave moved to 48 while q is held; the table still says q -> 60",
              st["octave"] == 48 and {"key_code": Q, "note": 60} in st["held"], st)
        r = key(c, Q, False)
        check("q up: note_off 60 (fixed at the press), not 48",
              dec_of(r) == "note_off" and (r.get("note") or (r["decision"].get("note") if isinstance(r["decision"], dict) else None)) == 60, r)
        check("table emptied", r["held"] == [], r)
        c.send("midi.keyboard.octave", {"base": 60})
        key(c, Q, True); key(c, D, True)
        check("two keys held", len(c.send("midi.keyboard.status")["held"]) == 2)
        master_level(c)
        time.sleep(0.6)
        c.send("midi.keyboard.set", {"on": False})
        st = c.send("midi.keyboard.status")
        check("mode off: every note released (held empty)", st["on"] is False and st["held"] == [], st)
        time.sleep(0.8)
        master_level(c)
        time.sleep(0.5)
        after = master_level(c)
        check("... and the sound stops (%.3f)" % after, after < 0.02, after)
        r = key(c, Q, True)
        check("mode off again: a key passes through", dec_of(r) == "pass_through", r)
        c.send("midi.keyboard.set", {"on": True})
        key(c, G, True)
        check("a note held before a tab switch", len(c.send("midi.keyboard.status")["held"]) == 1)
        c.send("tab.new")
        st = c.send("midi.keyboard.status")
        check("tab switch: allNotesOff (held empty), mode kept across tabs", st["held"] == [] and st["on"] is True, st)
        c.send("tab.select", {"index": 1})
        c.send("input.monitor", {"midi": CK, "on": False})

        # ── F ----------------------------------------------------------------------------------------
        section("F  save / reopen")
        P = os.path.join(tmp, "ck")
        path = os.path.join(P, "ck.objekat")
        c.send("project.save_as", {"path": path})
        c.send("project.save")
        raw = ""
        for dp, _, fs in os.walk(P):
            for f in fs:
                if f.endswith((".json", ".objekat")):
                    raw += open(os.path.join(dp, f), errors="ignore").read()
        check("the zone's source (recordMidiInput) is in the file", '"recordMidiInput"' in raw and CK in raw)
        check("the mode / octave are NOT in the file",
              not re.search(r'computerKeyboard(On|Mode)|keyboardOctave|"octave"', raw, re.I), "")
        c.send("midi.keyboard.set", {"on": False})
        c.send("project.open", {"path": path})
        zs = zone_status(c, z1)
        check("reopened: the zone finds its keyboard source again",
              zs is not None and zs["source"] == "midi" and zs["midi_input"]["id"] == CK, zs)
        lst = c.send("input.list.midi_inputs")["midi_inputs"]
        check("... and the line is still second", [d["id"] for d in lst][:2] == ["all_midi_in", CK])
        check("a reopened project does not turn the mode on", c.send("midi.keyboard.status")["on"] is False)

    # ── G ------------------------------------------------------------------------------------------------
    section("G  Settings.xml")
    after_raw = settings_bytes()
    check("no trace of the device in Settings.xml",
          after_raw is None or (b"Computer Keyboard" not in after_raw and b"vmidiin_" not in after_raw))
    same = settings_before == after_raw
    check("Settings.xml unchanged (modulo audioDeviceRate)", same or normalised(settings_before) == normalised(after_raw),
          (normalised(settings_before), normalised(after_raw)))
    if not same and normalised(settings_before) == normalised(after_raw):
        print("  note: the plain hash differs; the content does not (audioDeviceRate / plugin scan order)")
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

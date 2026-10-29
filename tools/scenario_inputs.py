#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The sound card's INPUTS (`input.*`), opened on demand, driven on the virtual card.

The card's inputs are closed at launch and open with `input.enable`, on the same device as the
output; the engine describes one mono input per channel plus one stereo input per neighbouring pair
(2N - 1), and the bridge exposes a peak meter per channel. The virtual card (`--virtual-audio`,
4 inputs) gives each input a known signal, so the whole chain is asserted with no hardware:

  PHASE A — `--virtual-audio` (4 inputs)
    * closed at launch: `input.list` empty, `audio.status.input_channels` 0
    * `input.enable`: 4 inputs, 7 engine devices (4 monos + 3 pairs), the output untouched
    * levels: sine 0.5 -> -6 dB (+-0.5), sine 0.25 -> -12 dB, silence -> under -90 dB, an impulse
      train -> 0 dB; a read CLEARS the peak
    * the loopback input carries the output (and is silent when nothing plays): the proof that the
      meter, a second audio callback, does not leak into the speakers
    * pairs: declared pairs consume their channels, an overlap keeps the lower one, a pair outside
      the card is ignored, `[]` goes back to all-mono; a stereo input reports its louder channel
    * a rate change and a buffer change leave the inputs where they were
    * `input.disable` / `input.enable` again
    * Settings.xml is byte for byte what it was
  PHASE B — `--virtual-audio --no-audio`: an empty list and empty levels, no error
  PHASE C — a NORMAL launch on the real card: the inputs are NOT opened (no microphone prompt, no
    surprise for AirPods), and Settings.xml carries no input device. The real card's inputs are
    never opened here; that one is for the eye.

Settings.xml is backed up first and restored byte for byte at the end.

    ./scenario_inputs.py /path/to/objekat.app

Exit: 0 if every assertion passes, 1 if one fails, 2 on bad usage.
"""

import hashlib, os, re, shutil, subprocess, sys, time

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
BACKUP = os.path.abspath(os.path.join(HERE, "..", ".objekat-settings-backup-inputs-%d.xml" % os.getpid()))
BIP = os.path.join(HERE, "fixtures", "bip.wav")
CARD = "OBJ Virtual"

ok, ko = 0, 0


def section(title):
    print("\n── %s " % title + "─" * max(4, 74 - len(title)))


def check(label, cond, detail=""):
    global ok, ko
    if cond:
        ok += 1
        print("  OK   %-62s" % label)
    else:
        ko += 1
        print("  FAIL %-62s %s" % (label, detail))


def launch(sock, extra_args):
    if os.path.exists(sock):
        os.remove(sock)
    proc = subprocess.Popen([BIN, "--headless", "--api", "--no-recent", "--language=en",
                             "--socket=" + sock] + extra_args,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(160):
        if os.path.exists(sock):
            return proc
        time.sleep(0.25)
    proc.kill()
    raise RuntimeError("the app did not open its socket: " + sock)


def stop(proc, sock):
    if proc is None:
        return
    try:
        proc.terminate()
        proc.wait(timeout=20)
    except Exception:
        proc.kill()
    if os.path.exists(sock):
        os.remove(sock)


def settings_bytes():
    try:
        with open(SETTINGS, "rb") as f:
            return f.read()
    except FileNotFoundError:
        return None


def digest(b):
    return None if b is None else hashlib.sha256(b).hexdigest()[:16]


def refused(c, name, **params):
    try:
        c.send(name, params or None)
        return None
    except ObjekatError as e:
        return e.code


def peaks(c, settle=0.5):
    """Clears the meters, lets `settle` seconds of audio go by, reads what they caught."""
    c.send("input.levels")
    time.sleep(settle)
    return c.send("input.levels")


def db(r, ch):
    return r["channels"][ch]["peak_db"]


def shape(lst):
    """`inputs` as [(first, count), ...] — enough to compare layouts."""
    return [(d["first"], d["count"]) for d in lst["inputs"]]


original = settings_bytes()
if original is not None:
    shutil.copyfile(SETTINGS, BACKUP)
before = digest(original)
SOCK = "/tmp/objk-inputs-%d.sock" % os.getpid()
proc = None
try:
    # ════════════════════════════════════════════════════════════════════════════════════════
    section("PHASE A — --virtual-audio (4 inputs)")
    proc = launch(SOCK, ["--virtual-audio"])
    with ObjekatClient(SOCK) as c:
        # -- closed at launch ---------------------------------------------------------------
        lst = c.send("input.list")
        check("closed at launch: open false", lst["open"] is False, lst)
        check("closed at launch: input.list is empty", lst["inputs"] == [] and lst["engine_devices"] == [], lst)
        st = c.send("audio.status")
        check("closed at launch: audio.status.input_channels is 0",
              st["input_channels"] == 0 and st["live"]["input_channels"] == 0, st)
        lv = c.send("input.levels")
        check("closed at launch: levels are empty", lv["open"] is False and lv["channels"] == [], lv)

        c.send("audio.virtual.set_input", {"channel": 0, "signal": "sine", "frequency": 440, "amplitude": 0.5})
        c.send("audio.virtual.set_input", {"channel": 1, "signal": "silence"})
        c.send("audio.virtual.set_input", {"channel": 2, "signal": "sine", "frequency": 1000, "amplitude": 0.25})
        c.send("audio.virtual.set_input", {"channel": 3, "signal": "impulse", "amplitude": 1.0, "period": 0.3})

        # -- enable -------------------------------------------------------------------------
        t0 = time.monotonic()
        lst = c.send("input.enable")
        print("  ..   input.enable took %.0f ms" % ((time.monotonic() - t0) * 1000))
        check("enabled: open true on the virtual card", lst["open"] is True and lst["device"] == CARD, lst)
        check("enabled: 4 input channels", lst["channels"] == 4 and len(lst["channel_names"]) == 4, lst)
        check("enabled: input.list has 4 entries", len(lst["inputs"]) == 4, lst["inputs"])
        check("enabled: 4 mono inputs on channels 0..3", shape(lst) == [(0, 1), (1, 1), (2, 1), (3, 1)], shape(lst))
        check("enabled: the engine describes 2N - 1 = 7 devices", len(lst["engine_devices"]) == 7, len(lst["engine_devices"]))
        pair_devs = [d for d in lst["engine_devices"] if d["count"] == 2]
        check("enabled: 3 neighbouring pairs described, none enabled",
              len(pair_devs) == 3 and not any(d["enabled"] for d in pair_devs), pair_devs)
        check("enabled: pairs in force are empty", lst["pairs"] == [], lst["pairs"])
        st = c.send("audio.status")
        check("enabled: audio.status.input_channels is 4", st["input_channels"] == 4, st["input_channels"])
        check("enabled: the output is untouched (device, 2 out, running)",
              st["device"] == CARD and st["output_channels"] == 2 and st["running"] is True, st)
        check("enabled: a second input.enable is a no-op", len(c.send("input.enable")["inputs"]) == 4)

        # -- levels -------------------------------------------------------------------------
        r = peaks(c, 0.8)
        check("sine 0.5 on channel 0 -> -6 dB (+-0.5): %.2f" % db(r, 0), abs(db(r, 0) - (-6.02)) <= 0.5, db(r, 0))
        check("silence on channel 1 -> under -90 dB: %.1f" % db(r, 1), db(r, 1) < -90, db(r, 1))
        check("sine 0.25 on channel 2 -> -12 dB (+-0.5): %.2f" % db(r, 2), abs(db(r, 2) - (-12.04)) <= 0.5, db(r, 2))
        check("impulse train on channel 3 -> 0 dB (+-0.5): %.2f" % db(r, 3), abs(db(r, 3)) <= 0.5, db(r, 3))
        check("levels: 4 channels, 4 enabled inputs folded onto them",
              len(r["channels"]) == 4 and len(r["inputs"]) == 4 and abs(r["inputs"][0]["peak_db"] - db(r, 0)) < 1e-6, r)

        c.send("audio.virtual.set_input", {"channel": 0, "signal": "silence"})
        c.send("input.levels")                    # clears (and carries the last blocks of the sine)
        time.sleep(0.1)
        c.send("input.levels")
        time.sleep(0.4)
        r2 = c.send("input.levels")
        check("a read clears the peak: silence now reads under -90 dB (%.1f)" % db(r2, 0), db(r2, 0) < -90, db(r2, 0))
        c.send("audio.virtual.set_input", {"channel": 0, "signal": "sine", "frequency": 440, "amplitude": 0.5})

        # -- loopback: the meter must not leak into the output ----------------------------------
        c.send("audio.virtual.set_input", {"channel": 1, "signal": "loopback"})
        c.send("project.new")
        c.send("object.add", {"path": BIP, "lane": 0, "start": 0})
        c.send("wait_idle", {"timeout_ms": 5000})
        c.send("transport.seek", {"seconds": 0})
        r = peaks(c, 0.5)
        check("loopback, nothing playing -> silence (%.1f dB): no garbage from the meter" % db(r, 1),
              db(r, 1) < -90, db(r, 1))
        c.send("input.levels")
        c.send("transport.play")
        time.sleep(0.9)
        r = c.send("input.levels")
        c.send("transport.stop")
        check("loopback, bip playing -> the output comes back on input 1 (%.1f dB)" % db(r, 1),
              -30 < db(r, 1) <= 0.5, db(r, 1))
        r = peaks(c, 0.6)
        check("loopback, stopped again -> silence (%.1f dB)" % db(r, 1), db(r, 1) < -90, db(r, 1))
        c.send("audio.virtual.set_input", {"channel": 1, "signal": "silence"})

        # -- stereo pairs -------------------------------------------------------------------
        lst = c.send("input.set_pairs", {"pairs": [0]})
        check("pair 1+2: pairs in force [0]", lst["pairs"] == [0], lst["pairs"])
        check("pair 1+2: the stereo input and monos 3, 4 are offered",
              shape(lst) == [(2, 1), (3, 1), (0, 2)], shape(lst))
        check("pair 1+2: still 7 engine devices", len(lst["engine_devices"]) == 7)
        r = peaks(c, 0.5)
        stereo = [d for d in r["inputs"] if d["count"] == 2]
        check("pair 1+2: the stereo input reports its louder channel (-6 dB): %s" %
              ("%.2f" % stereo[0]["peak_db"] if stereo else "?"),
              len(stereo) == 1 and abs(stereo[0]["peak_db"] - (-6.02)) <= 0.5, r["inputs"])

        lst = c.send("input.set_pairs", {"pairs": [0, 2]})
        check("pairs 1+2 and 3+4: two stereo inputs only", shape(lst) == [(0, 2), (2, 2)], shape(lst))
        lst = c.send("input.set_pairs", {"pairs": [1, 0]})
        check("overlapping pairs (2+3, 1+2): the lower one wins", lst["pairs"] == [0], lst["pairs"])
        lst = c.send("input.set_pairs", {"pairs": [3, 7, -1]})
        check("pairs outside the card are ignored: back to 4 monos", lst["pairs"] == [] and len(lst["inputs"]) == 4, lst)
        lst = c.send("input.set_pairs", {"pairs": [1]})
        check("pair 2+3: monos 1 and 4 and the stereo input", shape(lst) == [(0, 1), (3, 1), (1, 2)], shape(lst))
        lst = c.send("input.set_pairs", {"pairs": []})
        check("[] -> all mono again", shape(lst) == [(0, 1), (1, 1), (2, 1), (3, 1)], shape(lst))
        check("a non-integer pair is refused", refused(c, "input.set_pairs", pairs=["a"]) == "bad_params")

        # -- a rate and a buffer change leave the inputs in place ---------------------------------
        c.send("audio.set_sample_rate", {"hz": 44100})
        lst = c.send("input.list")
        st = c.send("audio.status")
        check("44100 Hz: the inputs are still there (4)", lst["open"] is True and len(lst["inputs"]) == 4, lst)
        check("44100 Hz: audio.status agrees (rate, 4 input channels, running)",
              st["sample_rate"] == 44100 and st["input_channels"] == 4 and st["running"] is True, st)
        r = peaks(c, 0.6)
        check("44100 Hz: the sine still reads -6 dB (%.2f)" % db(r, 0), abs(db(r, 0) - (-6.02)) <= 0.5, db(r, 0))

        c.send("audio.set_buffer_size", {"frames": 128})
        lst = c.send("input.list")
        check("128 frames: the inputs are still there (4)", lst["open"] is True and len(lst["inputs"]) == 4, lst)
        r = peaks(c, 0.6)
        check("128 frames: the sine still reads -6 dB (%.2f)" % db(r, 0), abs(db(r, 0) - (-6.02)) <= 0.5, db(r, 0))

        # a pair survives the reopening too
        c.send("input.set_pairs", {"pairs": [2]})
        c.send("audio.set_buffer_size", {"frames": 256})
        lst = c.send("input.list")
        check("a declared pair survives a buffer change", shape(lst) == [(0, 1), (1, 1), (2, 2)], shape(lst))
        c.send("input.set_pairs", {"pairs": []})
        c.send("audio.set_sample_rate", {"hz": 48000})

        # -- playing while the inputs change ------------------------------------------------------
        c.send("transport.seek", {"seconds": 0})
        c.send("transport.play")
        time.sleep(0.3)
        c.send("input.disable")
        time.sleep(0.5)
        playing = c.send("transport.state")["playing"]
        c.send("transport.stop")
        check("playback survives closing the inputs", playing is True)

        # -- disable / enable again -----------------------------------------------------------
        lst = c.send("input.list")
        check("disable: closed, empty", lst["open"] is False and lst["inputs"] == [] and lst["engine_devices"] == [], lst)
        st = c.send("audio.status")
        check("disable: input_channels back to 0, output still running",
              st["input_channels"] == 0 and st["running"] is True and st["device"] == CARD, st)
        check("disable: levels are empty", c.send("input.levels")["channels"] == [])
        lst = c.send("input.enable")
        check("enable again: 4 inputs", lst["open"] is True and len(lst["inputs"]) == 4, lst)
        r = peaks(c, 0.6)
        check("enable again: the sine reads -6 dB (%.2f)" % db(r, 0), abs(db(r, 0) - (-6.02)) <= 0.5, db(r, 0))
        time.sleep(0.5)
    stop(proc, SOCK)
    proc = None
    after = settings_bytes()
    check("Settings.xml untouched by the whole run (hash)", digest(after) == before, "%s -> %s" % (before, digest(after)))
    check("Settings.xml never mentions the virtual card", after is None or CARD.encode() not in after)

    # ════════════════════════════════════════════════════════════════════════════════════════
    section("PHASE B — --virtual-audio --no-audio")
    proc = launch(SOCK, ["--virtual-audio", "--no-audio"])
    with ObjekatClient(SOCK) as c:
        lst = c.send("input.list")
        check("--no-audio: an empty list, no error", lst["open"] is False and lst["inputs"] == [], lst)
        lv = c.send("input.levels")
        check("--no-audio: empty levels, no error", lv["open"] is False and lv["channels"] == [], lv)
        pr = c.send("input.set_pairs", {"pairs": [0]})
        check("--no-audio: declaring a pair is harmless", pr["inputs"] == [], pr)
        st = c.send("audio.status")
        if st["device"] is None:
            check("--no-audio: input.enable is refused (invalid_state)", refused(c, "input.enable") == "invalid_state")
        else:
            # The known pre-existing limitation (command_api.md, "audio.*"): a real card opened
            # despite --no-audio. Opening ITS inputs here would raise the microphone prompt.
            print("  ..   --no-audio opened a real device (known limitation): input.enable not exercised")
    stop(proc, SOCK)
    proc = None

    # ════════════════════════════════════════════════════════════════════════════════════════
    section("PHASE C — a normal launch on the real card")
    proc = launch(SOCK, [])
    with ObjekatClient(SOCK) as c:
        st = c.send("audio.status")
        lst = c.send("input.list")
        print("  ..   the normal launch opened: %s (%s)" % (st["device"], st["type"]))
        check("the real card is not the virtual one", st["device"] != CARD)
        check("on a real card too, the inputs are closed at launch",
              lst["open"] is False and lst["inputs"] == [], lst)
        check("on a real card too, audio.status.input_channels is 0",
              st["input_channels"] == 0 and st["live"]["input_channels"] == 0, st)
        time.sleep(1.0)
    stop(proc, SOCK)
    proc = None
    final = settings_bytes()
    check("Settings.xml carries no input device after a normal launch",
          final is None or re.search(rb'audioInputDeviceName="[^"]+"', final) is None)
finally:
    stop(proc, SOCK)
    if original is not None and os.path.exists(BACKUP):
        shutil.copyfile(BACKUP, SETTINGS)
        os.remove(BACKUP)
    elif original is None and os.path.exists(SETTINGS):
        os.remove(SETTINGS)

print("\n%d passed, %d failed" % (ok, ko))
sys.exit(0 if ko == 0 else 1)

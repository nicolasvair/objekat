#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The card whose inputs are ANOTHER device (AirPods), driven on the virtual card.

AirPods show up in CoreAudio as TWO devices with one name: a speaker (output only) and a microphone
(input only). Opening "the inputs of the output device" made JUCE build an aggregate of the two, the
switch to the call profile made CoreAudio republish both, and the aggregate restarted itself from a
CoreAudio thread while the main thread was still opening it: a crash (2026-10-29). The engine now asks
the system BEFORE touching anything (`objekat/Shared/OBJCoreAudioProbe.h`) and refuses. The virtual
card reaches the same refusal with no hardware through `splitin:1`.

  PHASE A — `--virtual-audio=in:2,splitin:1`
    * the card says so: audio.virtual.status.split_inputs, audio.status.inputs_separate (cached AND
      live), input.list.inputs_separate — and the inputs are closed
    * input.enable is refused: invalid_state, details.reason = inputs_on_separate_device, the message
      names the reason
    * NOTHING was touched: same device, 2 outputs, still running, the device generation has not moved
      (no restart of the output), the transport still plays, inputs still closed, input.list empty
    * the refusal repeats (a second ask answers the same) and input.disable stays a no-op
  PHASE B — `--virtual-audio=in:2` (no splitin): inputs_separate false everywhere, input.enable
    succeeds (2 channels), and inputs_separate stays false once open
  PHASE C — `--virtual-audio=in:2,splitin:0`: same as B (the key parses)
  Settings.xml is byte for byte what it was. Nothing here opens the machine's real card.

    ./scenario_inputs_split_device.py /path/to/objekat.app

Exit: 0 if every assertion passes, 1 if one fails, 2 on bad usage.
"""

import hashlib, os, shutil, subprocess, sys, time

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
BACKUP = os.path.abspath(os.path.join(HERE, "..", ".objekat-settings-backup-split-%d.xml" % os.getpid()))
CARD = "OBJ Virtual"
REASON = "inputs_on_separate_device"

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


def refusal(c, name, **params):
    """The ObjekatError the command raises, or None if it succeeded."""
    try:
        c.send(name, params or None)
        return None
    except ObjekatError as e:
        return e


original = settings_bytes()
if original is not None:
    shutil.copyfile(SETTINGS, BACKUP)
before = digest(original)
SOCK = "/tmp/objk-split-%d.sock" % os.getpid()
proc = None
try:
    # ════════════════════════════════════════════════════════════════════════════════════════
    section("PHASE A — --virtual-audio=in:2,splitin:1")
    proc = launch(SOCK, ["--virtual-audio=in:2,splitin:1"])
    with ObjekatClient(SOCK) as c:
        v = c.send("audio.virtual.status")
        check("the card declares split_inputs", v.get("split_inputs") is True, v)
        check("the card still has its 2 inputs", v["inputs"] == 2, v)
        st = c.send("audio.status")
        check("audio.status.inputs_separate is true (cached)", st.get("inputs_separate") is True, st)
        check("audio.status.live.inputs_separate is true", st["live"].get("inputs_separate") is True, st["live"])
        check("inputs are closed at launch", st["input_channels"] == 0, st)
        lst = c.send("input.list")
        check("input.list: closed, inputs_separate true, empty",
              lst["open"] is False and lst.get("inputs_separate") is True and lst["inputs"] == [], lst)

        gen = st["generation"]
        e = refusal(c, "input.enable")
        check("input.enable is refused", e is not None, "it succeeded")
        check("  ... as invalid_state", e is not None and e.code == "invalid_state", e and e.code)
        check("  ... with details.reason = %s" % REASON,
              e is not None and isinstance(e.details, dict) and e.details.get("reason") == REASON, e and e.details)
        check("  ... and a message that names the cause",
              e is not None and "separate device" in e.message, e and e.message)

        # Nothing was touched.
        time.sleep(0.5)
        st2 = c.send("audio.status")
        check("the output is untouched: same device, 2 outputs, running",
              st2["device"] == CARD and st2["output_channels"] == 2 and st2["running"] is True, st2)
        check("the output was NOT restarted (generation did not move)", st2["generation"] == gen,
              "%s -> %s" % (gen, st2["generation"]))
        check("the inputs are still closed", st2["input_channels"] == 0 and st2["live"]["input_channels"] == 0, st2)
        lst2 = c.send("input.list")
        check("input.list is unchanged (closed, empty, still separate)",
              lst2["open"] is False and lst2["inputs"] == [] and lst2["engine_devices"] == []
              and lst2.get("inputs_separate") is True, lst2)
        c.send("transport.seek", {"seconds": 0})
        c.send("transport.play")
        p0 = c.send("transport.state")["position"]
        time.sleep(0.4)
        p1 = c.send("transport.state")["position"]
        c.send("transport.stop")
        check("the transport still plays on the same card (%.2f -> %.2f)" % (p0, p1), p1 > p0 + 0.2, (p0, p1))

        e2 = refusal(c, "input.enable")
        check("a second input.enable is refused the same way",
              e2 is not None and e2.code == "invalid_state" and (e2.details or {}).get("reason") == REASON, e2 and e2.details)
        check("input.disable stays a no-op", c.send("input.disable")["open"] is False)
        check("the generation still has not moved", c.send("audio.status")["generation"] == gen)
    stop(proc, SOCK)
    proc = None

    # ════════════════════════════════════════════════════════════════════════════════════════
    for title, spec in (("PHASE B — --virtual-audio=in:2 (no splitin)", "--virtual-audio=in:2"),
                        ("PHASE C — --virtual-audio=in:2,splitin:0", "--virtual-audio=in:2,splitin:0")):
        section(title)
        proc = launch(SOCK, [spec])
        with ObjekatClient(SOCK) as c:
            v = c.send("audio.virtual.status")
            check("split_inputs is false", v.get("split_inputs") is False, v)
            st = c.send("audio.status")
            check("audio.status.inputs_separate is false", st.get("inputs_separate") is False, st)
            check("input.list.inputs_separate is false", c.send("input.list").get("inputs_separate") is False)
            lst = c.send("input.enable")
            check("input.enable succeeds: open, 2 channels", lst["open"] is True and lst["channels"] == 2, lst)
            st = c.send("audio.status")
            check("inputs_separate stays false once open", st.get("inputs_separate") is False
                  and st["input_channels"] == 2, st)
        stop(proc, SOCK)
        proc = None

    check("Settings.xml is byte for byte what it was", digest(settings_bytes()) == before)
finally:
    stop(proc, SOCK)
    if original is not None and os.path.exists(BACKUP):
        shutil.copyfile(BACKUP, SETTINGS)
        os.remove(BACKUP)
    elif original is None and os.path.exists(SETTINGS):
        os.remove(SETTINGS)

print("\n%d passed, %d failed" % (ok, ko))
sys.exit(0 if ko == 0 else 1)

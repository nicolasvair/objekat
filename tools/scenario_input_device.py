#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""An INPUT card that is not the OUTPUT card (lot D), driven on the virtual card. No hardware, no window.

  PHASE A — `--virtual-audio=in:2,in2:3` : the choice of the input card
    * audio.devices.inputs lists the output card's own entry (same_as_output) and the second card
    * audio.status.input_device is null until a card is chosen; audio.set_input_device chooses by UID,
      refuses an unknown one, and `null` (or the output card's UID) goes back to "the same card"
    * the inputs open on the CHOSEN card (3 channels, not the output card's 2), the output untouched
      (same device, 2 outputs, running), the signal of the second card's channel reaches its input
    * changing the choice while the inputs are open reopens them on the new card
    * Settings.xml is byte for byte what it was

    ./scenario_input_device.py /path/to/objekat.app

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
BACKUP = os.path.abspath(os.path.join(HERE, "..", ".objekat-settings-backup-indev-%d.xml" % os.getpid()))
CARD = "OBJ Virtual"
CARD2 = "OBJ Virtual In 2"

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
    try:
        c.send(name, params or None)
        return None
    except ObjekatError as e:
        return e


def peak(c, channel, secs=0.6):
    """The loudest reading of one input channel over `secs` (the meter clears at every read)."""
    c.send("input.levels")
    time.sleep(secs)
    ch = c.send("input.levels")["channels"]
    return ch[channel]["peak_db"] if channel < len(ch) else None


original = settings_bytes()
if original is not None:
    shutil.copyfile(SETTINGS, BACKUP)
before = digest(original)
SOCK = "/tmp/objk-indev-%d.sock" % os.getpid()
proc = None
try:
    # ════════════════════════════════════════════════════════════════════════════════════════
    section("PHASE A — --virtual-audio=in:2,in2:3 : the choice of the input card")
    proc = launch(SOCK, ["--virtual-audio=in:2,in2:3"])
    with ObjekatClient(SOCK) as c:
        inputs = c.send("audio.devices.inputs")["inputs"]
        by_uid = {d["uid"]: d for d in inputs}
        check("two input cards listed", set(by_uid) == {CARD, CARD2}, list(by_uid))
        check("the output card's entry is same_as_output, 2 channels",
              by_uid.get(CARD, {}).get("same_as_output") is True and by_uid[CARD]["channels"] == 2, by_uid.get(CARD))
        check("the second card is another card, 3 channels",
              by_uid.get(CARD2, {}).get("same_as_output") is False and by_uid[CARD2]["channels"] == 3, by_uid.get(CARD2))
        check("audio.devices carries the same list", len(c.send("audio.devices")["inputs"]) == 2)
        st = c.send("audio.status")
        check("audio.status.input_device is null by default", st["input_device"] is None, st["input_device"])
        check("no card selected in the list", not any(d["selected"] for d in inputs))

        e = refusal(c, "audio.set_input_device", uid="no such card")
        check("an unknown UID is refused", e is not None and e.code == "invalid_state", e and (e.code, e.message))
        check("... and nothing moved", c.send("audio.status")["input_device"] is None)

        st = c.send("audio.set_input_device", {"uid": CARD2})
        check("choosing the second card: input_device carries its uid and name",
              st["input_device"] == {"uid": CARD2, "name": CARD2}, st["input_device"])
        check("the inputs are still closed (a choice only)", st["input_channels"] == 0 and st["live"]["input_channels"] == 0, st)
        check("inputs_separate is false with a card chosen", st["inputs_separate"] is False, st)
        check("the choice is marked in the list",
              [d["uid"] for d in c.send("audio.devices.inputs")["inputs"] if d["selected"]] == [CARD2])

        gen = st["generation"]
        lst = c.send("input.enable")
        check("input.enable opens the CHOSEN card: 3 channels", lst["open"] is True and lst["channels"] == 3, lst)
        check("channel names are the second card's", lst["channel_names"] == ["In2 1", "In2 2", "In2 3"], lst["channel_names"])
        st = c.send("audio.status")
        check("the output is untouched: same device, 2 outputs, running",
              st["device"] == CARD and st["output_channels"] == 2 and st["running"] is True, st)
        check("3 input channels active", st["input_channels"] == 3 and st["live"]["input_channels"] == 3, st)

        # The signal of the second card reaches its own input (channel 2 = the second card's first).
        c.send("audio.virtual.set_input", {"channel": 2, "signal": "sine", "frequency": 1000, "amplitude": 0.5})
        p = peak(c, 0)
        check("the second card's channel 1 carries its sine (%s dB)" % p, p is not None and -9 < p < -5, p)
        c.send("audio.virtual.set_input", {"channel": 0, "signal": "sine", "frequency": 500, "amplitude": 0.9})
        p_other = peak(c, 1)
        check("the MAIN card's signal does not leak in (%s dB)" % p_other, p_other is not None and p_other < -100, p_other)
        check("the transport plays on the output card",
              (c.send("transport.play"), time.sleep(0.4), c.send("transport.state")["position"])[2] > 0.2)
        c.send("transport.stop")

        # Back to the same card while open: closed and reopened on the output card's own inputs.
        st = c.send("audio.set_input_device", {"uid": None})
        check("null = the same card again", st["input_device"] is None, st["input_device"])
        check("the inputs were reopened on the output card (2 channels)",
              st["input_channels"] == 2 and c.send("input.list")["channels"] == 2, st["input_channels"])
        st = c.send("audio.set_input_device", {"uid": CARD2})
        check("chosen again while open: reopened on the second card (3 channels)",
              st["input_channels"] == 3 and st["input_device"]["uid"] == CARD2, st["input_channels"])
        st = c.send("audio.set_input_device", {"uid": CARD})
        check("the output card's own UID means the same card", st["input_device"] is None and st["input_channels"] == 2, st)
        c.send("input.disable")
        check("input.disable closes them", c.send("audio.status")["input_channels"] == 0)
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

print("\n%d OK, %d FAIL" % (ok, ko))
sys.exit(0 if ko == 0 else 1)

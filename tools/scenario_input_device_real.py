#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""An INPUT card other than the OUTPUT card, on REAL cards (lot D, step 4): the private aggregate.

NOT part of the headless suites: it opens real hardware (headless, no window). Run it under the guard,
which gives the cards, the defaults, the preferences and Settings.xml back exactly:

    ./audio_state_guard.py run -- ./scenario_input_device_real.py /path/to/objekat.app

Skips (exit 0) when the machine has no suitable second card. Never picks a Bluetooth or Continuity
card (their state machine is step 5). What it proves: the aggregate is the open device, yet the output
card is still what everything REPORTS; no list, answer or Settings.xml ever carries its name; the inputs
open with the chosen card's channel count; leaving restores the output card alone. What it cannot: that
a signal reaches an input (the microphone permission is the user's, not a script's).
"""
import os, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

if len(sys.argv) != 2:
    print(__doc__); sys.exit(2)
APP = sys.argv[1]
BIN = os.path.join(APP, "Contents", "MacOS", "objekat")
SETTINGS = os.path.expanduser("~/Library/objekat/Settings.xml")
MASK = "OBJEKAT private"
ok = ko = 0


def check(label, cond, detail=""):
    global ok, ko
    if cond: ok += 1; print("  OK   %-66s" % label)
    else:    ko += 1; print("  FAIL %-66s %s" % (label, detail))


sock = "/tmp/objk-indev-real-%d.sock" % os.getpid()
if os.path.exists(sock): os.remove(sock)
proc = subprocess.Popen([BIN, "--headless", "--api", "--no-recent", "--language=en", "--socket=" + sock],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    for _ in range(160):
        if os.path.exists(sock): break
        time.sleep(0.25)
    with ObjekatClient(sock) as c:
        st = c.send("audio.status")
        if st.get("type") != "CoreAudio" or not st.get("device") or not st.get("running"):
            print("no running CoreAudio output (%s): skipped" % st.get("device")); sys.exit(0)
        out = st["device"]
        inputs = c.send("audio.devices.inputs")["inputs"]
        bad = ("airpods", "iphone", "ipad", "bluetooth", "continuity")
        cands = [d for d in inputs if not d["same_as_output"] and d["channels"] > 0
                 and not any(b in d["name"].lower() for b in bad)]
        if not cands:
            print("no second input card: skipped"); sys.exit(0)
        card = cands[0]
        print("  output: %s   input card: %s (%d ch)" % (out, card["name"], card["channels"]))

        check("no aggregate in the input list", not any(MASK in d["name"] for d in inputs))
        check("no aggregate in the output list",
              not any(MASK in n for n in [d if isinstance(d, str) else d.get("name", "") for d in c.send("audio.devices")["outputs"]]))

        st = c.send("audio.set_input_device", {"uid": card["uid"]})
        check("the choice alone opens nothing", st["input_channels"] == 0 and st["device"] == out, st)

        try:
            lst = c.send("input.enable")
        except ObjekatError as e:
            # The frequency rule: the OUTPUT card decides, the input card aligns or the choice is refused.
            check("the rate rule refuses with a message naming both rates", "does not offer" in e.message and "Hz" in e.message, e.message)
            st = c.send("audio.status")
            check("... and nothing moved (output running, inputs closed)",
                  st["running"] is True and st["input_channels"] == 0 and st["device"] == out, st)
            print("  (refused: %s)  moving the output card to 48000 Hz and trying again" % e.message)
            c.send("audio.set_sample_rate", {"hz": 48000})
            lst = c.send("input.enable")
        check("input.enable opens the chosen card (%d channels)" % card["channels"],
              lst["open"] is True and lst["channels"] == card["channels"], lst)
        st = c.send("audio.status")
        check("the device reported is still the OUTPUT card", st["device"] == out and MASK not in str(st), st["device"])
        check("... a CoreAudio device, running", st["type"] == "CoreAudio" and st["running"] is True, st["type"])
        check("... with the chosen card's input channels", st["input_channels"] == card["channels"], st["input_channels"])
        check("... and the live read agrees", st["live"]["device"] == out and st["live"]["input_channels"] == card["channels"], st["live"])
        check("no aggregate in the channel names", MASK not in str(lst.get("channel_names")), lst.get("channel_names"))
        check("inputs_separate is false (a card is chosen)", st["inputs_separate"] is False)
        check("no aggregate in audio.devices", MASK not in str(c.send("audio.devices")))
        check("the transport plays", (c.send("transport.play"), time.sleep(0.5), c.send("transport.state")["position"])[2] > 0.2)
        c.send("transport.stop")

        c.send("input.disable")
        st = c.send("audio.status")
        check("input.disable: the output card alone again", st["input_channels"] == 0 and st["device"] == out
              and st["live"]["device"] == out and st["input_device"]["uid"] == card["uid"], st)
        st = c.send("audio.set_input_device", {"uid": None})
        check("null = the same card again", st["input_device"] is None and st["device"] == out, st["input_device"])

        # A change of OUTPUT while the inputs are open on a chosen card: they follow (reopened on the new output).
        outs = c.send("audio.devices")["outputs"]
        names = [o if isinstance(o, str) else o.get("name", "") for o in outs]
        other = [n for n in names if n != out and not any(b in n.lower() for b in bad) and MASK not in n]
        c.send("audio.set_input_device", {"uid": card["uid"]}); c.send("input.enable")
        if other:
            try:
                c.send("audio.set_device", {"name": other[0]})
                time.sleep(1.0)
                st = c.send("audio.status")
                check("output -> %s: the inputs followed (aggregate rebuilt, %d channels)" % (other[0], card["channels"]),
                      st["device"] == other[0] and st["input_channels"] == card["channels"]
                      and st["input_device"] is not None and st["running"] is True, st)
                c.send("audio.set_device", {"name": out})
                time.sleep(1.0)
                st = c.send("audio.status")
                check("back to %s: still followed" % out, st["device"] == out and st["input_channels"] == card["channels"], st)
            except ObjekatError as e:
                check("output change", False, e.message)
        else:
            print("  (no other output card: the follow-the-output check is skipped)")
        c.send("input.disable")

        # open once more and leave through a change of the choice while open
        c.send("audio.set_input_device", {"uid": card["uid"]}); c.send("input.enable")
        st = c.send("audio.set_input_device", {"uid": None})
        check("back to the same card while open: the aggregate is gone, the output card runs",
              st["device"] == out and st["live"]["device"] == out and st["running"] is True, st)
        c.send("audio.set_input_device", {"uid": card["uid"]}); c.send("input.enable")   # leave it open for the exit
finally:
    proc.terminate()
    try: proc.wait(timeout=20)
    except Exception: proc.kill()
    if os.path.exists(sock): os.remove(sock)

try:
    text = open(SETTINGS, encoding="utf-8", errors="replace").read()
except FileNotFoundError:
    text = ""
check("Settings.xml never carries the aggregate", MASK not in text)
print("\n%d OK, %d FAIL" % (ok, ko))
sys.exit(1 if ko else 0)

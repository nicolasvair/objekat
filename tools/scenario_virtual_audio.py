#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The virtual sound card (`--virtual-audio`) put to the test, headless, with no hardware.

`--virtual-audio` replaces every sound card with "OBJ Virtual": a real `juce::AudioIODeviceType`
whose device calls the audio callback paced on the wall clock (one block every bs/sr seconds,
absolute deadlines), with synthetic inputs. It exists so that playback, input meters and recording
can be tested on any machine, at real-time speed. Its one dangerous property is that it is a card
the machine does not have: if it leaked into ~/Library/objekat/Settings.xml, the next NORMAL launch
would look for it. So this scenario is as much about what the virtual card does NOT do.

  PHASE A — `--virtual-audio` (defaults: 4 in, 2 out, 48 kHz, 256 frames, latencies 64/96)
    * audio.status reads "OBJ Virtual", open and running, with the announced figures
    * transport.play advances the position at real time (+-5 %)
    * audio.virtual.set_input is validated, and what it sets is read back
    * a sample-rate / buffer change on the virtual card works, and leaves Settings.xml alone
    * Settings.xml is byte for byte what it was, and never mentions "OBJ Virtual"
  PHASE B — `--virtual-audio=in:2,out:2,sr:44100,bs:128,inlat:10,outlat:20` — the spec is honoured
    and the loopback delay follows the model (2 * bs + inlat + outlat)
  PHASE C — `--virtual-audio --no-audio` — no audio at all outranks the virtual card
  PHASE D — a NORMAL launch afterwards: not the virtual card, Settings.xml still clean

Settings.xml is backed up first and restored byte for byte at the end (phase D's normal launch
rewrites it, as any launch of the app does).

    ./scenario_virtual_audio.py /path/to/objekat.app

Exit: 0 if every assertion passes, 1 if one fails, 2 on bad usage.
"""

import hashlib, json, os, shutil, subprocess, sys, time

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
BACKUP = os.path.abspath(os.path.join(HERE, "..", ".objekat-settings-backup-vaudio-%d.xml" % os.getpid()))
BIP = os.path.join(HERE, "fixtures", "bip.wav")
CARD = "OBJ Virtual"

ok, ko = 0, 0


def section(title):
    print("\n── %s " % title + "─" * max(4, 74 - len(title)))


def check(label, cond, detail=""):
    global ok, ko
    if cond:
        ok += 1
        print("  OK   %-58s" % label)
    else:
        ko += 1
        print("  FAIL %-58s %s" % (label, detail))


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
    """The error code a command is refused with, or None if it was accepted."""
    try:
        c.send(name, params or None)
        return None
    except ObjekatError as e:
        return e.code if hasattr(e, "code") else str(e)


original = settings_bytes()
if original is not None:
    shutil.copyfile(SETTINGS, BACKUP)
before = digest(original)
print("Settings.xml before: %s (%s)" % (before or "absent", "%d bytes" % len(original) if original else "-"))

SOCK = "/tmp/objk-vaudio-%d.sock" % os.getpid()
proc = None
try:
    # ════════════════════════════════════════════════════════════════════════════════════════
    section("PHASE A — --virtual-audio (defaults)")
    proc = launch(SOCK, ["--virtual-audio"])
    with ObjekatClient(SOCK) as c:
        st = c.send("audio.status")
        check("audio.status device is the virtual card", st["device"] == CARD, st["device"])
        check("audio.status type is the virtual card", st["type"] == CARD, st["type"])
        check("running", st["running"] is True, st)
        check("48000 Hz", st["sample_rate"] == 48000, st["sample_rate"])
        check("256 frames", st["buffer_size"] == 256, st["buffer_size"])
        check("2 output channels", st["output_channels"] == 2, st["output_channels"])
        check("cached == live", st["live"]["device"] == st["device"]
              and st["live"]["sample_rate"] == st["sample_rate"]
              and st["live"]["buffer_size"] == st["buffer_size"], st["live"])

        vs = c.send("audio.virtual.status")
        check("virtual.status active", vs["active"] is True, vs)
        check("virtual.status open", vs["open"] is True, vs)
        check("4 inputs, 2 outputs", vs["inputs"] == 4 and vs["outputs"] == 2, vs)
        check("configured latencies 64 / 96", vs["input_latency"] == 64 and vs["output_latency"] == 96, vs)
        check("inputs closed at launch: the card announces no input latency, output = configured + one buffer (352)",
              vs["announced_input_latency"] == 0 and vs["announced_output_latency"] == 96 + 256, vs)
        c.send("input.enable")                             # open the card's inputs: it now announces them too
        vs = c.send("audio.virtual.status")
        check("ANNOUNCED latencies = configured + one buffer (320 / 352), like CoreAudio",
              vs["announced_input_latency"] == 64 + 256 and vs["announced_output_latency"] == 96 + 256, vs)
        check("announced in + out = loopback_delay",
              vs["announced_input_latency"] + vs["announced_output_latency"] == vs["loopback_delay"], vs)
        check("loopback_delay = 2*256 + 64 + 96 = 672", vs["loopback_delay"] == 672, vs["loopback_delay"])
        check("every input starts on silence", all(s["signal"] == "silence" for s in vs["signals"]), vs["signals"])

        # -- the enumeration offers the virtual card and ONLY it ------------------------------
        devs = c.send("audio.devices")
        check("audio.devices offers only the virtual card", devs["outputs"] == [CARD], devs["outputs"])

        # -- real-time pacing ---------------------------------------------------------------
        c.send("project.new")
        c.send("object.add", {"path": BIP, "lane": 0, "start": 0})
        c.send("wait_idle", {"timeout_ms": 5000})
        c.send("transport.seek", {"seconds": 0})
        c.send("transport.play")
        time.sleep(0.6)                                    # let the transport settle
        p0 = c.send("transport.state")["position"]
        w0 = time.monotonic()
        time.sleep(4.0)
        p1 = c.send("transport.state")["position"]
        w1 = time.monotonic()
        ratio = (p1 - p0) / (w1 - w0)
        check("transport.play advances at real time (ratio %.4f, +-5 %%)" % ratio,
              0.95 <= ratio <= 1.05, "ratio=%.4f" % ratio)
        check("the transport is playing", c.send("transport.state")["playing"] is True)
        c.send("transport.stop")

        # -- set_input: validated, and read back --------------------------------------------
        check("channel out of range refused", refused(c, "audio.virtual.set_input", channel=4, signal="sine") == "bad_params")
        check("negative channel refused", refused(c, "audio.virtual.set_input", channel=-1, signal="sine") == "bad_params")
        check("unknown signal refused", refused(c, "audio.virtual.set_input", channel=0, signal="noise") == "bad_params")
        check("zero frequency refused", refused(c, "audio.virtual.set_input", channel=0, signal="sine", frequency=0) == "bad_params")
        check("amplitude over 4 refused", refused(c, "audio.virtual.set_input", channel=0, signal="sine", amplitude=9) == "bad_params")
        check("period under 1 ms refused", refused(c, "audio.virtual.set_input", channel=0, signal="impulse", period=0) == "bad_params")
        r = c.send("audio.virtual.set_input", {"channel": 2, "signal": "sine", "frequency": 1000, "amplitude": 0.25})
        s2 = r["signals"][2]
        check("set_input read back (sine 1 kHz 0.25 on channel 2)",
              s2["signal"] == "sine" and s2["frequency"] == 1000 and s2["amplitude"] == 0.25, s2)
        check("the other channels are untouched", all(r["signals"][i]["signal"] == "silence" for i in (0, 1, 3)), r["signals"])
        c.send("audio.virtual.set_input", {"channel": 2, "signal": "silence"})

        # -- a rate and a buffer change on the virtual card ---------------------------------
        a = c.send("audio.set_sample_rate", {"hz": 44100})
        check("sample rate changed to 44100", a["sample_rate"] == 44100 and a["device"] == CARD, a)
        check("the card keeps running after the change", a["running"] is True, a)
        vs2 = c.send("audio.virtual.status")
        check("loopback_delay follows the live block (672, bs unchanged)", vs2["loopback_delay"] == 672, vs2)
        b = c.send("audio.set_buffer_size", {"frames": 128})
        check("buffer changed to 128", b["buffer_size"] == 128 and b["device"] == CARD, b)
        vs3 = c.send("audio.virtual.status")
        check("loopback_delay follows the new block (2*128 + 160 = 416)", vs3["loopback_delay"] == 416, vs3["loopback_delay"])
        check("the announced latencies follow the block too (192 / 224)",
              vs3["announced_input_latency"] == 64 + 128 and vs3["announced_output_latency"] == 96 + 128, vs3)
        c.send("audio.set_buffer_size", {"frames": 256})
        c.send("audio.set_sample_rate", {"hz": 48000})

        time.sleep(1.0)                                    # let any deferred settings write happen
    stop(proc, SOCK)
    proc = None

    after = settings_bytes()
    check("Settings.xml untouched by the virtual run (hash)", digest(after) == before,
          "%s -> %s" % (before, digest(after)))
    check("Settings.xml never mentions the virtual card",
          after is None or CARD.encode() not in after)

    # ════════════════════════════════════════════════════════════════════════════════════════
    section("PHASE B — --virtual-audio=in:2,out:2,sr:44100,bs:128,inlat:10,outlat:20")
    proc = launch(SOCK, ["--virtual-audio=in:2,out:2,sr:44100,bs:128,inlat:10,outlat:20"])
    with ObjekatClient(SOCK) as c:
        st = c.send("audio.status")
        check("device is the virtual card", st["device"] == CARD, st["device"])
        check("44100 Hz", st["sample_rate"] == 44100, st["sample_rate"])
        check("128 frames", st["buffer_size"] == 128, st["buffer_size"])
        c.send("input.enable")
        vs = c.send("audio.virtual.status")
        check("2 inputs", vs["inputs"] == 2, vs)
        check("latencies 10 / 20", vs["input_latency"] == 10 and vs["output_latency"] == 20, vs)
        check("loopback_delay = 2*128 + 10 + 20 = 286", vs["loopback_delay"] == 286, vs["loopback_delay"])
        check("announced latencies 138 / 148 (sum = loopback_delay)",
              vs["announced_input_latency"] == 138 and vs["announced_output_latency"] == 148, vs)
        check("channel 2 does not exist", refused(c, "audio.virtual.set_input", channel=2, signal="sine") == "bad_params")
    stop(proc, SOCK)
    proc = None

    # A malformed spec must not stop the app from starting: unknown keys and bad values fall back.
    proc = launch(SOCK, ["--virtual-audio=bogus:1,in:x,bs:777,sr:12345,out:2"])
    with ObjekatClient(SOCK) as c:
        st = c.send("audio.status")
        check("a malformed spec still starts the card on its defaults",
              st["device"] == CARD and st["sample_rate"] == 48000 and st["buffer_size"] == 256, st)
    stop(proc, SOCK)
    proc = None

    # ════════════════════════════════════════════════════════════════════════════════════════
    section("PHASE C — --virtual-audio --no-audio")
    proc = launch(SOCK, ["--virtual-audio", "--no-audio"])
    with ObjekatClient(SOCK) as c:
        vs = c.send("audio.virtual.status")
        check("the virtual card is dropped (active false)", vs["active"] is False, vs)
        st = c.send("audio.status")
        check("audio.status is not the virtual card", st["device"] != CARD, st["device"])
        check("set_input is refused", refused(c, "audio.virtual.set_input", channel=0, signal="sine") == "invalid_state")
    stop(proc, SOCK)
    proc = None

    # ════════════════════════════════════════════════════════════════════════════════════════
    section("PHASE D — a normal launch afterwards")
    proc = launch(SOCK, [])
    with ObjekatClient(SOCK) as c:
        st = c.send("audio.status")
        check("the device is not the virtual card", st["device"] != CARD, st["device"])
        check("virtual.status says inactive", c.send("audio.virtual.status")["active"] is False)
        print("  ..   the normal launch opened: %s (%s)" % (st["device"], st["type"]))
    stop(proc, SOCK)
    proc = None
    final = settings_bytes()
    check("Settings.xml still never mentions the virtual card",
          final is None or CARD.encode() not in final)
finally:
    stop(proc, SOCK)
    if original is not None and os.path.exists(BACKUP):
        shutil.copyfile(BACKUP, SETTINGS)
        os.remove(BACKUP)
    elif original is None and os.path.exists(SETTINGS):
        os.remove(SETTINGS)

print("\n%d passed, %d failed" % (ok, ko))
sys.exit(0 if ko == 0 else 1)

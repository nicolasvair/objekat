#!/usr/bin/env python3
"""Recording calibration on a REAL CoreAudio device whose output 1 comes back on its input 1
(BlackHole, or a card with a cable from out 1 to in 1).

    python3 tools/calib_record_device.py <objekat.app> [device name] [buffer sizes...] [--takes=N] [--modes=cold,punch]
    e.g.  python3 tools/calib_record_device.py objekat.app "BlackHole 16ch" 64 256 512 --takes=6

An impulse is played at t = 1.000 s, recorded through the loop, and found again in the take: the
error printed is (where the take puts it) - 1.000 s, in samples. On a perfect loop (BlackHole) a
well-compensated recording reads 0; on a cable it reads the card's true round trip minus what it
declares. Two ways of starting, per buffer size (`--modes`, both by default):

    cold    seek 0, rec.start
    punch   transport.play from 0, rec.start at 0.2 s (punch-in during playback)

After each size a SUMMARY line gives, per mode, the largest |error| and the set of values met; the
very last line gives the same over every size.

Touches the real device: ~/Library/objekat/Settings.xml is saved before and put back after.
Measures only, asserts nothing. Exit 2 on bad usage.
"""

import os, shutil, struct, subprocess, sys, tempfile, time, wave

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient

if len(sys.argv) < 2:
    print(__doc__)
    sys.exit(2)
APP = sys.argv[1]
BIN = os.path.join(APP, "Contents", "MacOS", "objekat")
FLAGS = [a for a in sys.argv[2:] if a.startswith("--")]
ARGS = [a for a in sys.argv[2:] if not a.startswith("--")]
DEVICE = ARGS[0] if ARGS and not ARGS[0].isdigit() else "BlackHole 16ch"
BUFFERS = [int(b) for b in (ARGS[1:] if ARGS and not ARGS[0].isdigit() else ARGS)] or [64, 256, 512]
TAKES = 6
MODES = ["cold", "punch"]
for f in FLAGS:
    if f.startswith("--takes="):
        TAKES = int(f.split("=", 1)[1])
    elif f.startswith("--modes="):
        MODES = [m for m in f.split("=", 1)[1].split(",") if m in ("cold", "punch")]
    else:
        print("unknown option %s" % f)
        sys.exit(2)
if not os.path.exists(BIN):
    print("not an app bundle: %s" % APP)
    sys.exit(2)

SETTINGS = os.path.expanduser("~/Library/objekat/Settings.xml")


def read_wav_f32(path):
    with open(path, "rb") as f:
        raw = f.read()
    pos, ch, sr, data = 12, 1, 48000, b""
    while pos + 8 <= len(raw):
        cid, size = raw[pos:pos + 4], struct.unpack("<I", raw[pos + 4:pos + 8])[0]
        body = raw[pos + 8:pos + 8 + size]
        if cid == b"fmt ":
            _, ch, sr = struct.unpack("<HHI", body[:8])
        elif cid == b"data":
            data = body
        pos += 8 + size + (size & 1)
    return sr, np.frombuffer(data[:len(data) // 4 * 4], dtype="<f4").reshape(-1, ch)


def wait_pos(c, t, timeout=30):
    end = time.time() + timeout
    while time.time() < end:
        if c.send("transport.state")["position"] >= t:
            return
        time.sleep(0.05)


tmp = tempfile.mkdtemp(prefix="objk-calib-")
backup = os.path.join(tmp, "Settings.xml")
had_settings = os.path.exists(SETTINGS)
if had_settings:
    shutil.copy2(SETTINGS, backup)
SOCK = "/tmp/objk-calib-%d.sock" % os.getpid()
# Through LaunchServices (`open`) and not exec'd: macOS then asks for the microphone in the app's own
# name. Exec'd from a shell, the app inherits the shell's responsible process, and without that one's
# permission CoreAudio hands it silence and asks nothing.
# OBJ_* variables of this shell are handed down (`open` does not inherit the environment).
env_args = [a for k, v in os.environ.items() if k.startswith("OBJ_") for a in ("--env", "%s=%s" % (k, v))]
subprocess.run(["open", "-n"] + env_args + ["-a", APP, "--args", "--headless", "--api", "--no-recent", "--language=en",
                "--socket=" + SOCK], check=True)
try:
    for _ in range(160):
        if os.path.exists(SOCK):
            break
        time.sleep(0.25)
    with ObjekatClient(SOCK) as c:
        outs = c.send("audio.devices")["outputs"]
        if DEVICE not in outs:
            print("device '%s' not found; available: %s" % (DEVICE, outs))
            sys.exit(2)
        c.send("audio.set_device", {"name": DEVICE})
        c.send("project.new")
        c.send("project.save_as", {"path": os.path.join(tmp, "calib", "calib.objekat")})
        c.send("input.enable")
        input("If macOS asks for the microphone, allow it, then press Return... ") if sys.stdin.isatty() else time.sleep(15)
        summary = []
        for bs in BUFFERS:
            st = c.send("audio.set_buffer_size", {"frames": bs})
            sr = int(st.get("sample_rate") or st.get("live", {}).get("sample_rate") or 48000)
            imp = os.path.join(tmp, "impulse_%d.wav" % sr)
            if not os.path.exists(imp):
                with wave.open(imp, "wb") as w:
                    w.setnchannels(1); w.setsampwidth(2); w.setframerate(sr)
                    frames = np.zeros(3 * sr, dtype="<i2")
                    frames[sr] = 26000                                    # 1.000 s
                    w.writeframes(frames.tobytes())
            c.send("project.new")
            c.send("project.save_as", {"path": os.path.join(tmp, "calib%d" % bs, "calib.objekat")})
            c.send("object.add", {"path": imp, "lane": 5, "start": 0})
            c.send("wait_idle", {"timeout_ms": 5000})
            c.send("timesel.set", {"start": 0, "end": 4, "lanes": [0]})
            z = c.send("rec.drop", {"first": 0, "count": 1, "lane": 0, "time": 2})["group"]
            c.send("timesel.clear")
            c.send("rec.arm", {"group": z, "on": True})
            time.sleep(1.0)
            for mode in MODES:
                errs = []
                for k in range(TAKES):
                    c.send("transport.seek", {"seconds": 0})
                    if mode == "punch":
                        c.send("transport.play")
                        wait_pos(c, 0.2)
                    c.send("rec.start")
                    wait_pos(c, 3.0)
                    t = c.send("rec.stop")["last_takes"][0]
                    fsr, arr = read_wav_f32(t["path"])
                    x = np.abs(arr[:, 0])
                    i = int(np.argmax(x))
                    at = (t["start"] - t["source_offset"]) + i / fsr
                    errs.append((int(round((at - 1.0) * fsr)), float(x[i])))
                    c.send("edit.undo")
                    time.sleep(1.1)
                print("buffer %4d @ %d Hz %-5s: error in samples per take: %s   (peaks %s)" %
                      (bs, sr, mode, ", ".join("%+d" % e for e, _ in errs), ", ".join("%.2f" % p for _, p in errs)))
                summary.append((bs, mode, [e for e, _ in errs]))
            mine = [e for b, m, es in summary if b == bs for e in es]
            print("SUMMARY buffer %4d: max |error| = %d samples, values = %s" % (bs, max(abs(e) for e in mine), sorted(set(mine))))
        allerr = [e for _, _, es in summary for e in es]
        print("SUMMARY all sizes %s, modes %s: max |error| = %d samples, values = %s" %
              (BUFFERS, MODES, max(abs(e) for e in allerr), sorted(set(allerr))))
        print("\nstatus:", c.send("audio.status"))
finally:
    subprocess.run(["pkill", "-f", "--", "--socket=" + SOCK])
    time.sleep(2)
    if had_settings:
        shutil.copy2(backup, SETTINGS)
    print("Settings.xml restored" if had_settings else "no Settings.xml before")

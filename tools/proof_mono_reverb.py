#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Preuve rapide : un wav MONO traversé par un plugin stéréo-sortie (AUMatrixReverb) sort-il en stéréo ?

Exporte le mix (24 bits) et mesure le RMS de L-R. Avant le correctif (fallback « fichier » d'ObjGain),
L-R = 0 : la sortie du plugin est repliée en mono. Après : L-R != 0.

    ./proof_mono_reverb.py /path/to/objekat.app
"""
import math, os, random, shutil, subprocess, sys, tempfile, time, wave, struct

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient

APP = sys.argv[1]
BIN = os.path.join(APP, "Contents", "MacOS", "objekat")
WORK = tempfile.mkdtemp(prefix="objpm_", dir="/tmp")
SOCK = os.path.join(WORK, "s.sock")
AU_MATRIX_REVERB = "AudioUnit:Effects/aufx,mrev,appl"

# un wav mono : une salve de bruit blanc 0,4 s, puis le silence (la queue de réverbération reste)
mono = os.path.join(WORK, "mono_noise.wav")
random.seed(7)
with wave.open(mono, "wb") as w:
    w.setnchannels(1); w.setsampwidth(3); w.setframerate(48000)
    frames = bytearray()
    for n in range(int(2.0 * 48000)):
        v = (random.uniform(-1, 1) * 0.3) if n < 0.4 * 48000 else 0.0
        frames += struct.pack("<i", int(v * 8388607))[:3]
    w.writeframes(bytes(frames))

proc = subprocess.Popen([BIN, "--headless", "--api", "--no-recent", "--language=en", "--socket=" + SOCK],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
code = 1
try:
    for _ in range(160):
        if os.path.exists(SOCK):
            break
        time.sleep(0.25)
    with ObjekatClient(SOCK, timeout=240) as c:
        send = c.send
        send("app.set_dialog_policy", {"policy": "assume_yes"})
        send("project.new")
        send("project.save_as", {"path": os.path.join(WORK, "p.objekat")})
        obj = send("object.add", {"path": mono, "lane": 0, "start": 0.0})["id"]
        pl = send("plugin.add", {"host": obj, "identifier": AU_MATRIX_REVERB})["plugin"]["id"]
        for _ in range(160):
            r = send("plugin.channel_layouts", {"host": obj, "plugin": pl})
            if r.get("loaded"):
                break
            time.sleep(0.25)
        print("reverb layout:", r.get("current"), r.get("inputs"), "->", r.get("outputs"))
        out = os.path.join(WORK, "out.wav")
        j = send("export.run", {"format": "wav", "sample_rate": 48000, "bit_depth": 24, "dithering": False,
                                "start": 0.0, "end": 2.0, "path": out})
        send("job.wait", {"id": j["job_id"], "timeout_ms": 120000})
        with wave.open(out, "rb") as w:
            assert w.getnchannels() == 2 and w.getsampwidth() == 3
            raw = w.readframes(w.getnframes())
        n = len(raw) // 6
        sl = sr = sd = 0.0
        for i in range(n):
            l = int.from_bytes(raw[i * 6:i * 6 + 3], "little", signed=True) / 8388608.0
            rr = int.from_bytes(raw[i * 6 + 3:i * 6 + 6], "little", signed=True) / 8388608.0
            sl += l * l; sr += rr * rr; sd += (l - rr) ** 2
        rms = lambda s: math.sqrt(s / n)
        print("RMS L = %.6f   RMS R = %.6f   RMS (L-R) = %.6f" % (rms(sl), rms(sr), rms(sd)))
        code = 0 if rms(sd) > 1e-4 else 1
        print("RESULT:", "L-R != 0 (stereo preserved)" if code == 0 else "L-R = 0 (folded to mono)")
finally:
    proc.terminate()
    try:
        proc.wait(timeout=10)
    except Exception:
        proc.kill()
    shutil.rmtree(WORK, ignore_errors=True)
sys.exit(code)

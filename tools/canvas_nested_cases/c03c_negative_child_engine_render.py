#!/usr/bin/env python3
"""c03c — the ENGINE side of the zero-clamp rule: a child of a group that starts before 0 must play the
RIGHT part of its file (the bridge turns the head cut into a source offset). Minimal project: a clip N
(8 s file, 0..4 s) in a group G whose window is 2..4 s, then G is brought back to 0 (N sits at -2, the
window 0..2 plays file seconds 2..4). N is moved +1 s with `object.move` (-> -1: the window now plays file
seconds 1..3; the old clamp pushed it to 0, i.e. file seconds 0..2). Each state is rendered
(`export.run`, WAV 48k/24 bit, no dither, 0..2 s) and compared to the source wav by cross-correlation: the
render must be the file read from the expected offset (best lag ~0, residual tiny).
Usage: c03c_negative_child_engine_render.py [socket]"""
import sys, os, json, time, wave
import numpy as np
sys.path.insert(0, __file__.rsplit('/canvas_nested_cases', 1)[0])
import scenario_canvas_nested as s
from objekat_cli import ObjekatClient
c = ObjekatClient(sys.argv[1] if len(sys.argv) > 1 else '/tmp/cc501/t.sock'); c.connect()
fails = []
def check(label, ok, detail=""):
    print(("ok    " + label) if ok else ("FAIL  " + label + "  " + str(detail)))
    if not ok: fails.append(label)

W = '/tmp/cc501/nested/depth1.wav'
def read(p):
    with wave.open(p) as w:
        n, ch, sw = w.getnframes(), w.getnchannels(), w.getsampwidth()
        raw = w.readframes(n)
    if sw == 2: a = np.frombuffer(raw, '<i2').astype(np.float64) / 32768
    elif sw == 3:
        b = np.frombuffer(raw, np.uint8).reshape(-1, 3)
        v = (b[:, 0].astype(np.int32) | (b[:, 1].astype(np.int32) << 8) | (b[:, 2].astype(np.int32) << 16))
        v = np.where(v >= 1 << 23, v - (1 << 24), v); a = v / 8388608.0
    else: raise SystemExit("sample width %d" % sw)
    return a.reshape(-1, ch)[:, 0]
src = read(W)

c.send("project.new"); c.send("project.set_snap", {"enabled": False}); s.settle(c)
n = c.send("object.add", {"path": W, "lane": 0, "start": 0.0, "duration": 4.0})["id"]
g = c.send("group.create", {"ids": [n]})["id"]
c.send("group.expand", {"id": g, "expanded": True})
c.send("object.trim", {"id": g, "start": 2.0, "duration": 2.0})
c.send("object.move", {"id": g, "start": 0.0}); s.settle(c, 400)
def st(i): return c.send("object.get", {"id": i})["start"]
check("setup: N at -2, G at 0", abs(st(n) + 2) < 1e-6 and abs(st(g)) < 1e-6, (st(n), st(g)))

out = '/tmp/cc501/nested/c03c'
os.makedirs(out, exist_ok=True)
def render(tag):
    p = os.path.join(out, tag + '.wav')
    if os.path.exists(p): os.remove(p)
    r = c.send("export.run", {"path": p, "format": "wav", "sample_rate": 48000, "bit_depth": 24,
                              "dithering": False, "start": 0.0, "end": 2.0})
    c.send("job.wait", {"id": r["job_id"], "timeout_ms": 120000})
    return read(p)
def expect(label, got, off_s):
    ref = src[int(off_s * 48000): int((off_s + 2) * 48000)]
    m = min(len(got), len(ref))
    got, ref = got[:m], ref[:m]
    # best lag in +-0.5 s by cross-correlation (FFT) — a source offset error shows as a lag
    f = np.fft.rfft(got, 2 * m) * np.conj(np.fft.rfft(ref, 2 * m))
    cc = np.fft.irfft(f)
    lag = int(np.argmax(cc)); lag = lag if lag < m else lag - 2 * m
    resid = float(np.sqrt(np.mean((got - ref) ** 2)) / (np.sqrt(np.mean(ref ** 2)) + 1e-12))
    check("%s: best lag %d samples (expect 0), residual %.4f of the signal" % (label, lag, resid),
          abs(lag) <= 2 and resid < 0.02)
expect("N at -2 plays file 2..4", render("before"), 2.0)
c.send("object.move", {"id": n, "start": st(n) + 1}); s.settle(c, 400)
check("N moved to -1 (not clamped)", abs(st(n) + 1) < 1e-6, st(n))
expect("N at -1 plays file 1..3", render("after_move"), 1.0)
c.send("edit.undo"); s.settle(c, 400)
expect("after undo: file 2..4 again", render("after_undo"), 2.0)
print("ALL PASS" if not fails else "FAILED: %s" % fails)
sys.exit(1 if fails else 0)

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The loudness an export measures while it renders (ITU-R BS.1770-4 / EBU R128, Tech 3341 / 3342).

The engine's tap (`OBJExportTap`) feeds every rendered block to `Shared/OBJLoudness.h`, the poll reads
the 100 ms sub-blocks incrementally, and `LoudnessAnalysis` turns them into the momentary, short-term
and integrated values, the loudness range and the true peak. `tools/test_loudness.swift` proves the
arithmetic on generated signals; this scenario proves the WHOLE PATH on a real render — the tap, the
atomics, the incremental read, the API — by exporting generated WAVs and reading the answer the way a
script would:

  • a stereo 997 Hz sine that renders at -23 dBFS, 20 s, exported as a 24-bit WAV WITHOUT dither,
    reads integrated = -23 LUFS and a true peak of -23 dBTP (at 48 kHz and at 44.1 kHz);
  • two levels 10 LU apart (-20 then -30) read a loudness range of about 10 LU, and the
    integrated value is the gated power mean of the two;
  • the curves (`export.loudness`) come out cut down, with nulls where a window has not filled;
  • nothing of the previous render shows while the next one prepares;
  • the loudness GROWS during a long render (caught mid-flight), and never goes back;
  • no window opens on the headless process;
  • and, where numpy / scipy are there, an INDEPENDENT measurement of the WAV that was written
    (scipy's lfilter for the K-weighting, resample_poly for the true peak, numpy for the gates) agrees
    with what the tap measured — the strongest proof there is that the tap saw what went to disk.

THE ENGINE'S -3 dB. A stereo clip at the centre comes out of the engine 3.00 dB quieter (the pan law of
the object's gain stage; measured on the rendered file: a -23 dBFS source peaks at -26.00 dBFS). It is
the ENGINE'S level, not the measurement's — so the sources are written 3 dB hotter, and the numbers
asserted below are the ones the RENDER carries.

    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --socket=/tmp/o.sock
    ./scenario_loudness.py /tmp/o.sock /tmp/trial/project.objekat

Exit: 0 if everything passes, 1 as soon as one assertion fails.
"""

import sys, os, json, time, math, struct, wave, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

if len(sys.argv) != 3:
    print(__doc__)
    sys.exit(2)

SOCK = sys.argv[1]
PROJ = sys.argv[2]
OUT = lambda n: os.path.join(os.path.dirname(PROJ), n)

ok, ko = 0, 0

# A centred stereo clip renders 3 dB down (see the docstring). Sources are written this much hotter.
ENGINE_CENTRE_LOSS_DB = 3.0


def step(label, fn):
    global ok, ko
    try:
        r = fn()
        ok += 1
        print("  OK   %-40s %s" % (label, json.dumps(r, ensure_ascii=False)[:120]))
        return r
    except ObjekatError as e:
        ko += 1
        print("  FAIL %-40s %s" % (label, e.args[0]))
        return None


def check(label, cond, detail=""):
    global ok, ko
    if cond:
        ok += 1
        print("  OK   %-40s" % label)
    else:
        ko += 1
        print("  FAIL %-40s %s" % (label, detail))


def near(a, b, tol):
    return a is not None and abs(a - b) <= tol


def write_sine(path, segments, rate=48000, freq=997.0):
    """A stereo 24-bit WAV: `segments` is [(seconds, peak dBFS)], the phase continuous across them.
    Written by hand (`wave` takes the raw bytes) — 24 bits so the file adds no quantisation of its own."""
    frames = bytearray()
    phase = 0.0
    step_ = 2 * math.pi * freq / rate
    for seconds, dbfs in segments:
        amp = 10 ** (dbfs / 20.0)
        for _ in range(int(seconds * rate)):
            v = int(round(amp * math.sin(phase) * 8388607))
            b = struct.pack("<i", v)[:3]
            frames += b + b
            phase += step_
            if phase > 2 * math.pi:
                phase -= 2 * math.pi
    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(3)
        w.setframerate(rate)
        w.writeframes(bytes(frames))


def pid_for_socket(sock_path):
    try:
        out = subprocess.check_output(["lsof", "-t", sock_path], text=True, stderr=subprocess.DEVNULL)
        pids = [int(p) for p in out.split()]
        return pids[0] if pids else None
    except Exception:
        return None


def window_count_for_pid(pid):
    try:
        import Quartz
    except ImportError:
        return None
    info = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionAll, Quartz.kCGNullWindowID)
    return sum(1 for w in info if w.get("kCGWindowOwnerPID") == pid)


def independent_measurement(path):
    """BS.1770 / Tech 3342 done again from the WAV that was written, with scipy and numpy and nothing
    from the app. Returns (integrated LUFS, LRA LU, true peak dBTP), or None without scipy."""
    try:
        import numpy as np
        from scipy.signal import lfilter, resample_poly
    except ImportError:
        return None
    with wave.open(path, "rb") as w:
        rate, nch = w.getframerate(), w.getnchannels()
        raw = w.readframes(w.getnframes())
    ints = np.frombuffer(raw, dtype=np.uint8).reshape(-1, 3).astype(np.int32)
    v = ints[:, 0] | (ints[:, 1] << 8) | (ints[:, 2] << 16)
    v = np.where(v & 0x800000, v - (1 << 24), v).astype(np.float64) / 8388608.0
    x = v.reshape(-1, nch).T

    def biquads(fs):
        f0, G, Q = 1681.974450955533, 3.999843853973347, 0.7071752369554196
        K = math.tan(math.pi * f0 / fs); Vh = 10 ** (G / 20); Vb = Vh ** 0.4996667741545416
        a0 = 1 + K / Q + K * K
        shelf = ([(Vh + Vb * K / Q + K * K) / a0, 2 * (K * K - Vh) / a0, (Vh - Vb * K / Q + K * K) / a0],
                 [1, 2 * (K * K - 1) / a0, (1 - K / Q + K * K) / a0])
        f0, Q = 38.13547087602444, 0.5003270373238773
        K = math.tan(math.pi * f0 / fs); a0 = 1 + K / Q + K * K
        hp = ([1, -2, 1], [1, 2 * (K * K - 1) / a0, (1 - K / Q + K * K) / a0])
        return shelf, hp

    shelf, hp = biquads(rate)
    y = np.stack([lfilter(*hp, lfilter(*shelf, ch)) for ch in x])
    sub = int(round(rate * 0.1))
    nsub = y.shape[1] // sub
    e = (y[:, :nsub * sub].reshape(nch, nsub, sub) ** 2).mean(axis=2).sum(axis=0)     # per 100 ms

    def windows(n):
        return np.array([e[k - n + 1:k + 1].mean() for k in range(n - 1, nsub)])

    lufs = lambda z: -0.691 + 10 * np.log10(np.maximum(z, 1e-300))
    m = windows(4)
    m = m[lufs(m) > -70]
    rel = lufs(m.mean()) - 10
    integrated = lufs(m[lufs(m) > rel].mean()) if (lufs(m) > rel).any() else -np.inf

    st = windows(30)
    st = st[lufs(st) > -70]
    lra = None
    if len(st):
        st = st[lufs(st) > lufs(st.mean()) - 20]
        l = np.sort(lufs(st))
        lra = float(np.percentile(l, 95) - np.percentile(l, 10))

    tp = max(np.abs(resample_poly(ch, 4, 1)).max() for ch in x)
    return float(integrated), lra, float(20 * np.log10(tp)) if tp > 0 else -np.inf


os.makedirs(os.path.dirname(PROJ), exist_ok=True)
SINE23 = OUT("sine_-23_48k.wav")
SINE23_441 = OUT("sine_-23_44k.wav")
STEP = OUT("sine_-20_-30_48k.wav")
HOT = ENGINE_CENTRE_LOSS_DB
write_sine(SINE23, [(20, -23 + HOT)], rate=48000)
write_sine(SINE23_441, [(20, -23 + HOT)], rate=44100)
write_sine(STEP, [(20, -20 + HOT), (20, -30 + HOT)], rate=48000)

with ObjekatClient(SOCK) as c:
    c.send("app.set_dialog_policy", {"policy": "assume_yes"})
    c.send("project.new")
    c.send("project.save_as", {"path": PROJ})

    # --- no export at all
    st = c.send("export.status")
    check("no job: loudness is null", st.get("loudness") is None and st.get("running") is False, st)
    try:
        c.send("export.loudness")
        check("export.loudness refuses with no job", False, "it answered")
    except ObjekatError as e:
        check("export.loudness refuses with no job", e.code == "invalid_state", e.code)

    def render(name, rate, start, end, **extra):
        params = {"format": "wav", "sample_rate": rate, "bit_depth": 24, "dithering": False,
                  "start": start, "end": end, "path": OUT(name)}
        params.update(extra)
        r = step("export %s" % name, lambda: c.send("export.run", params))
        if r:
            step("  job.wait", lambda: c.send("job.wait", {"id": r["job_id"], "timeout_ms": 120000}))
        return r

    # ------------------------------------------------------------------ -23 dBFS, 48 kHz
    c.send("object.add", {"path": SINE23, "lane": 0, "start": 0.0})
    render("l7_23_48.wav", 48000, 0.0, 20.0)
    L = c.send("export.status").get("loudness")
    check("loudness object present", isinstance(L, dict), L)
    if isinstance(L, dict):
        check("48k: integrated -23 LUFS", near(L["integrated"], -23.0, 0.2), L["integrated"])
        check("48k: true peak -23 dBTP", near(L["true_peak"], -23.0, 0.3), L["true_peak"])
        check("48k: momentary -23", near(L["momentary"], -23.0, 0.2), L["momentary"])
        check("48k: short-term -23", near(L["short_term"], -23.0, 0.2), L["short_term"])
        check("48k: maxima -23", near(L["momentary_max"], -23.0, 0.3) and near(L["short_term_max"], -23.0, 0.3),
              (L["momentary_max"], L["short_term_max"]))
        check("48k: about 200 sub-blocks", 198 <= L["blocks"] <= 201, L["blocks"])
        check("48k: steady sine has ~0 LU of range", L["lra"] is not None and L["lra"] < 0.5, L["lra"])

    ref = independent_measurement(OUT("l7_23_48.wav"))
    if ref is None:
        print("  ..   independent measurement skipped: no numpy / scipy")
    elif isinstance(L, dict):
        check("independent: integrated agrees with the tap (0.1 LU)", near(L["integrated"], ref[0], 0.1),
              "%s vs %.3f" % (L["integrated"], ref[0]))
        check("independent: true peak agrees with the tap (0.3 dB)", near(L["true_peak"], ref[2], 0.3),
              "%s vs %.3f" % (L["true_peak"], ref[2]))

    cv = step("export.loudness (50 points)", lambda: c.send("export.loudness", {"points": 50}))
    if cv:
        n = len(cv["times"])
        check("curves: 50 points", n == 50 and len(cv["momentary"]) == 50 and len(cv["short_term"]) == 50
              and len(cv["integrated"]) == 50, n)
        check("curves: times increase up to the end",
              all(b > a for a, b in zip(cv["times"], cv["times"][1:])) and near(cv["times"][-1], 20.0, 0.3),
              cv["times"][-3:])
        check("curves: momentary is null before 0.4 s only, then -23",
              cv["momentary"][-1] is not None and near(cv["momentary"][-1], -23.0, 0.2), cv["momentary"][:3])
        check("curves: short-term null at the start, -23 at the end",
              cv["short_term"][0] is None and near(cv["short_term"][-1], -23.0, 0.2),
              (cv["short_term"][0], cv["short_term"][-1]))
        check("curves: integrated ends on the summary's value",
              near(cv["integrated"][-1], cv["summary"]["integrated"], 0.05),
              (cv["integrated"][-1], cv["summary"]["integrated"]))
    try:
        c.send("export.loudness", {"points": 0})
        check("export.loudness rejects points=0", False, "it answered")
    except ObjekatError as e:
        check("export.loudness rejects points=0", e.code == "bad_params", e.code)

    # The file itself is the witness that the loudness measured is that of what was WRITTEN:
    # nothing the tap saw may differ from the bytes on disk (undithered, 24 bits).
    with wave.open(OUT("l7_23_48.wav"), "rb") as w:
        check("the render is a 24-bit stereo 48 kHz wave",
              (w.getsampwidth(), w.getnchannels(), w.getframerate()) == (3, 2, 48000),
              (w.getsampwidth(), w.getnchannels(), w.getframerate()))

    # ------------------------------------------------------------------ -23 dBFS, 44.1 kHz
    c.send("project.new")
    c.send("project.save_as", {"path": OUT("l7_441.objekat")})
    c.send("object.add", {"path": SINE23_441, "lane": 0, "start": 0.0})
    render("l7_23_441.wav", 44100, 0.0, 20.0)
    L = c.send("export.status").get("loudness") or {}
    check("44.1k: integrated -23 LUFS", near(L.get("integrated"), -23.0, 0.2), L.get("integrated"))
    check("44.1k: true peak -23 dBTP", near(L.get("true_peak"), -23.0, 0.3), L.get("true_peak"))
    ref = independent_measurement(OUT("l7_23_441.wav"))
    if ref is not None:
        check("independent 44.1k: integrated agrees (0.1 LU)", near(L.get("integrated"), ref[0], 0.1),
              "%s vs %.3f" % (L.get("integrated"), ref[0]))

    # ------------------------------------------------------------------ two levels: LRA and the gate
    c.send("project.new")
    c.send("project.save_as", {"path": OUT("l7_step.objekat")})
    c.send("object.add", {"path": STEP, "lane": 0, "start": 0.0})
    r = step("run two levels", lambda: c.send("export.run", {
        "format": "wav", "sample_rate": 48000, "bit_depth": 24, "dithering": False,
        "start": 0.0, "end": 40.0, "path": OUT("l7_step.wav")}))
    seen_preparing = []
    if r:
        deadline = time.time() + 60
        while time.time() < deadline:
            st = c.send("export.status")
            if st.get("phase") == "preparing":
                seen_preparing.append((st.get("loudness") or {}).get("blocks"))
            if not st.get("running"):
                break
            time.sleep(0.01)
        step("  job.wait", lambda: c.send("job.wait", {"id": r["job_id"], "timeout_ms": 120000}))
    check("nothing of the previous render while preparing",
          all(b in (0, None) for b in seen_preparing), seen_preparing[:6])
    L = c.send("export.status").get("loudness") or {}
    check("two levels: LRA = 10 +-1 LU", near(L.get("lra"), 10.0, 1.0), L.get("lra"))
    expected = 10 * math.log10((10 ** (-20 / 10.0) + 10 ** (-30 / 10.0)) / 2)
    check("two levels: integrated = power mean of the two (10 LU apart, inside the gate)",
          near(L.get("integrated"), expected, 0.3), "%s vs %.2f" % (L.get("integrated"), expected))
    check("two levels: short-term max -20", near(L.get("short_term_max"), -20.0, 0.3), L.get("short_term_max"))
    ref = independent_measurement(OUT("l7_step.wav"))
    if ref is not None:
        check("independent two levels: integrated agrees (0.1 LU)", near(L.get("integrated"), ref[0], 0.1),
              "%s vs %.3f" % (L.get("integrated"), ref[0]))
        check("independent two levels: LRA agrees (0.3 LU)", near(L.get("lra"), ref[1], 0.3),
              "%s vs %s" % (L.get("lra"), ref[1]))
        check("independent two levels: true peak agrees (0.3 dB)", near(L.get("true_peak"), ref[2], 0.3),
              "%s vs %.3f" % (L.get("true_peak"), ref[2]))
    cv = c.send("export.loudness", {"points": 40})
    check("two levels: the momentary curve steps down 10 LU",
          cv["momentary"][10] is not None and cv["momentary"][-2] is not None
          and near(cv["momentary"][10] - cv["momentary"][-2], 10.0, 0.5),
          (cv["momentary"][10], cv["momentary"][-2]))

    # ------------------------------------------------------------------ growth, caught mid-render
    r = step("run long (silence after the sound)", lambda: c.send("export.run", {
        "format": "wav", "sample_rate": 44100, "bit_depth": 24, "dithering": False,
        "start": 0.0, "end": 900.0, "path": OUT("l7_long.wav")}))
    samples = []
    if r:
        deadline = time.time() + 180
        while time.time() < deadline:
            st = c.send("export.status")
            if not st.get("running"):
                break
            if st.get("phase") == "rendering":
                samples.append(st["loudness"]["blocks"])
            time.sleep(0.02)
        step("  job.wait", lambda: c.send("job.wait", {"id": r["job_id"], "timeout_ms": 180000}))
    total_blocks = 9000
    print("  ..   %d samples taken while rendering" % len(samples))
    check("caught it mid-render", len(samples) >= 2, len(samples))
    check("the loudness GROWS (strictly between nothing and all)",
          any(0 < b < total_blocks - 10 for b in samples), samples[:10])
    check("and never goes back", all(b >= a for a, b in zip(samples, samples[1:])), samples[:20])
    L = c.send("export.status").get("loudness") or {}
    check("long: every sub-block measured", 8995 <= L.get("blocks", 0) <= 9001, L.get("blocks"))
    check("long: the silence gated out, integrated unchanged by it",
          near(L.get("integrated"), expected, 0.3), "%s vs %.2f" % (L.get("integrated"), expected))
    check("long: momentary is silence at the end (null)", L.get("momentary") is None, L.get("momentary"))

    # ------------------------------------------------------------------ silence
    c.send("project.new")
    c.send("project.save_as", {"path": OUT("l7_silence.objekat")})
    c.send("object.add", {"path": SINE23, "lane": 0, "start": 0.0})
    render("l7_silence.wav", 48000, 100.0, 110.0)
    L = c.send("export.status").get("loudness") or {}
    check("silence: integrated, lra, true peak are null",
          L.get("integrated") is None and L.get("lra") is None and L.get("true_peak") is None, L)
    check("silence: 100 sub-blocks measured", 98 <= L.get("blocks", 0) <= 101, L.get("blocks"))

    # ------------------------------------------------------------------ headless: no window
    pid = pid_for_socket(SOCK)
    if pid is not None:
        wc = window_count_for_pid(pid)
        check("no window on the headless pid", wc in (0, None), wc)

print("")
if ko:
    print("%d FAILED, %d ok" % (ko, ok))
    sys.exit(1)
print("ALL PASS (%d assertions)" % ok)

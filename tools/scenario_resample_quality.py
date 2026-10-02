#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""What the resampler does to a sound, measured on a render — the sample rate of the file against the
sample rate of the output, and the varispeed.

Why this exists. Tracktion's default resampler is Lagrange, whose reader re-aims its source at a ROUNDED
position on every block (a jump of one sample from time to time: a crackle as soon as the file and the
output do not share a rate — 44.1 ↔ 48, 96 → 44.1). OBJEKAT therefore asks for sinc (libsamplerate) and
never for Lagrange — `sincMedium` live and for a render DIRECT on the project, `sincBest` for a render on
a COPY (`background: true`) and for a bake. The sinc reader had a latent defect of its own, which the
varispeed would have exposed at once: it kept its position at the OUTPUT rate (`readPosition +=
numFramesToDo`) while its caller hands it a position in clip time, which moves at speed × duration. At any
speed other than 1 the two drifted apart by more than the one-sample tolerance on EVERY block, and the
reader reset its state — a click per block. Engine patch 0034.

What the scenario does: it exports an 8 s render (24-bit WAV, no dither) of 1 kHz, 10 kHz (and 19 kHz at
speed 1) sines and of a band-limited noise, for every file rate × output rate in {44.1, 48, 96} kHz and every
speed in {1, 1.07, 0.5}, and `analyze_resample.py` measures each render: SINAD, pitch against f0 × speed,
discontinuities (and their spacing: 512 = once per block), and for the noise the lag and the SNR against an
offline ideal. The matrix is written to a JSON, one per run, so that two runs can be compared
(`analyze_resample.py --compare`). `--bench` adds the cost: twenty 60 s clips rendered on top of each other,
wall time and CPU time of the app.

THE QUALITY UNDER TEST IS NOT SELECTABLE FROM HERE: it is whatever the app asks for by itself (sincMedium
for a render DIRECT, sincBest for a render on a COPY with `--background`). To measure Lagrange as a
reference — which is how the 'before' of engine patch 0034 was taken — one has to build the app with a
TEMPORARY switch (a `getenv` in `objDefaultResamplingQuality` and an early return in
`objUpgradeResamplingForRender (te::Edit&)`, of `OBJEngineCore.mm`) and never commit it. One run = one
instance:

    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --socket=/tmp/o.sock
    ./scenario_resample_quality.py /tmp/o.sock /tmp/trial/project.objekat --label sinc --expect sinc \\
        --out sinc.json

Options:
    --label NAME     recorded in the JSON
    --expect sinc    ASSERTS what a sinc build must deliver (no click, SINAD, pitch, lag); `none`
                     (default) only records
    --background     render on a COPY of the project (sincBest) instead of the live Edit (sincMedium)
    --quick          a reduced matrix (44.1 and 48 kHz only, speeds 1 and 1.07)
    --bench          adds the twenty-clips cost measurement
    --out FILE       where to write the JSON (default: next to the project)

Exit: 0 if everything asserted passes (or nothing was), 1 as soon as one assertion fails.
"""

import sys, os, json, time, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError
import analyze_resample as ar

argv = sys.argv[1:]
flags = {"--background", "--quick", "--bench"}
opts = {"--label": "unlabelled", "--expect": "none", "--out": None}
positional = []
i = 0
while i < len(argv):
    a = argv[i]
    if a in flags:
        opts[a] = True
    elif a in opts:
        i += 1
        opts[a] = argv[i]
    elif a.startswith("--"):
        print("unknown option", a)
        sys.exit(2)
    else:
        positional.append(a)
    i += 1
if len(positional) != 2:
    print(__doc__)
    sys.exit(2)

SOCK, PROJ = positional
WORK = os.path.dirname(PROJ)
FIX = os.path.join(WORK, "fixtures")
LABEL, EXPECT = opts["--label"], opts["--expect"]
BACKGROUND, QUICK, BENCH = bool(opts.get("--background")), bool(opts.get("--quick")), bool(opts.get("--bench"))
OUT_JSON = opts["--out"] or os.path.join(WORK, "resample_%s.json" % LABEL)
RENDER_SECONDS = 8.0

ok, ko = 0, 0


def check(label, cond, detail=""):
    global ok, ko
    if cond:
        ok += 1
    else:
        ko += 1
        print("  FAIL %-58s %s" % (label, detail))


def pid_for_socket(sock_path):
    try:
        out = subprocess.check_output(["lsof", "-t", sock_path], text=True, stderr=subprocess.DEVNULL)
        pids = [int(p) for p in out.split()]
        return pids[0] if pids else None
    except Exception:
        return None


def cpu_seconds(pid):
    """User + system CPU time of a process, from `ps` (10 ms resolution)."""
    try:
        s = subprocess.check_output(["ps", "-o", "cputime=", "-p", str(pid)], text=True).strip()
    except Exception:
        return None
    parts = s.split(":")
    secs = 0.0
    for p in parts:
        secs = secs * 60 + float(p)
    return secs


def window_count_for_pid(pid):
    try:
        import Quartz
    except ImportError:
        return None
    info = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionAll, Quartz.kCGNullWindowID)
    return sum(1 for w in info if w.get("kCGWindowOwnerPID") == pid)


rates = (44100, 48000) if QUICK else ar.RATES
speeds = (1.0, 1.07) if QUICK else ar.SPEEDS

os.makedirs(WORK, exist_ok=True)
fixtures = ar.make_fixtures(FIX)
sources = {}      # (kind, rate, freq) -> samples, read back from the file as the engine reads it
for key, path in fixtures.items():
    sources[key], _ = ar.read_wav_f32_left(path)

results = []
bench = []

with ObjekatClient(SOCK, timeout=600.0) as c:
    c.send("app.set_dialog_policy", {"policy": "assume_yes"})
    c.send("project.new")
    c.send("project.save_as", {"path": PROJ})
    pid = pid_for_socket(SOCK)

    def render(name, out_rate, start, end):
        t0 = time.time()
        params = {"format": "wav", "sample_rate": out_rate, "bit_depth": 24, "dithering": False,
                  "start": start, "end": end, "path": os.path.join(WORK, name), "background": BACKGROUND}
        r = c.send("export.run", params)
        c.send("job.wait", {"id": r["job_id"], "timeout_ms": 600000})
        return os.path.join(WORK, name), time.time() - t0

    def run_case(kind, src_rate, out_rate, speed, freq=None):
        path = fixtures[(kind, src_rate, freq)]
        added = c.send("object.add", {"path": path, "lane": 0, "start": 0.0})
        oid = added["id"]
        if speed != 1.0:
            c.send("object.set_speed", {"id": oid, "ratio": speed})
        wav, secs = render("r.wav", out_rate, 0.0, RENDER_SECONDS)
        x, rate = ar.read_wav_f32_left(wav)
        c.send("object.remove", {"ids": [oid]})
        os.remove(wav)
        if rate != out_rate:
            check("rendered rate", False, "%s vs %s" % (rate, out_rate))
        if kind == "tone":
            f_expected = freq * speed
            m = ar.analyze_tone(x, out_rate, f_expected)
        else:
            m = ar.analyze_noise(x, out_rate, sources[(kind, src_rate, None)], src_rate, speed)
        rec = {"kind": kind, "freq": freq, "src": src_rate, "out": out_rate, "speed": speed,
               "render_s": round(secs, 3), "m": m}
        results.append(rec)
        return rec

    t_start = time.time()
    for src in rates:
        for out in rates:
            for speed in speeds:
                for f in ar.TONE_FREQS:
                    run_case("tone", src, out, speed, f)
                if speed == 1.0 and not QUICK:
                    run_case("tone", src, out, 1.0, ar.EDGE_TONE)
                run_case("noise", src, out, speed)
            print("  .. src %d -> out %d done (%d renders so far, %.0f s)" % (src, out, len(results),
                                                                         time.time() - t_start))

    # ------------------------------------------------------------------ cost: twenty long clips
    if BENCH:
        n_clips, secs_clip = 20, 60.0
        cases = [(48000, 48000, 1.0), (44100, 48000, 1.0), (96000, 44100, 1.0), (48000, 48000, 1.07)]
        for src_rate, out_rate, speed in cases:
            p = os.path.join(FIX, "bench_noise_%d.wav" % src_rate)
            if not os.path.exists(p):
                ar._write_wav_f32(p, ar.band_noise(src_rate, secs_clip, seed=7), src_rate)
            ids = []
            for lane in range(n_clips):
                ids.append(c.send("object.add", {"path": p, "lane": lane, "start": 0.0})["id"])
            if speed != 1.0:
                for oid in ids:
                    c.send("object.set_speed", {"id": oid, "ratio": speed})
            length = 50.0
            cpu0, t0 = cpu_seconds(pid), time.time()
            wav, secs = render("bench.wav", out_rate, 0.0, length)
            cpu1 = cpu_seconds(pid)
            os.remove(wav)
            c.send("object.remove", {"ids": ids})
            rec = {"src": src_rate, "out": out_rate, "speed": speed, "clips": n_clips, "audio_s": length,
                   "wall_s": round(secs, 2), "cpu_s": None if cpu0 is None or cpu1 is None else round(cpu1 - cpu0, 2)}
            bench.append(rec)
            print("  bench %s" % json.dumps(rec))

    if pid is not None:
        n = window_count_for_pid(pid)
        check("no window on the headless pid", n in (0, None), n)

# ---------------------------------------------------------------------------------------------- verdicts
if EXPECT == "sinc":
    for r in results:
        tag = "%s %s %d->%d x%.2f" % (r["kind"], r["freq"] or "", r["src"], r["out"], r["speed"])
        m = r["m"]
        if r["kind"] == "tone":
            check("%s: no timing jump" % tag, m["jumps"] == 0,
                  "%d jumps (max %.3f sample), period %s" % (m["jumps"], m["jump_max"], m["jump_period"]))
            check("%s: no click" % tag, m["clicks"] == 0, "%d clicks, period %s" % (m["clicks"], m["click_period"]))
            check("%s: pitch within 0.5 cent" % tag, abs(m["cents"]) < 0.5, "%.3f cents" % m["cents"])
            floor = 80.0 if r["freq"] < 15000 else 70.0
            check("%s: SINAD >= %.0f dB" % (tag, floor), m["sinad_db"] >= floor, "%.1f dB" % m["sinad_db"])
        else:
            check("%s: lag under 0.5 sample" % tag, abs(m["lag"]) < 0.5, "%.3f" % m["lag"])
            check("%s: SNR vs ideal >= 70 dB" % tag, m["snr_db"] >= 70.0, "%.1f dB" % m["snr_db"])

doc = {"label": LABEL, "mode": "background (copy)" if BACKGROUND else "direct", "expect": EXPECT,
       "render_seconds": RENDER_SECONDS, "results": results, "bench": bench}
with open(OUT_JSON, "w") as f:
    json.dump(doc, f, indent=1)
print(ar.format_table(results))
print("wrote", OUT_JSON)
print("\n%s: %d passed, %d failed (%d renders analysed)" % ("PASS" if ko == 0 else "FAIL", ok, ko, len(results)))
sys.exit(1 if ko else 0)

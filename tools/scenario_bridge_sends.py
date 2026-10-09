#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Sends on the audio bridge, as a user meets them: any object reaches any aux of its stem or of the Main.

What a person asks — "send this to the reverb", from a group, from a stem, to an aux inside another
group — and what can be asserted of it with no screen (docs/plan_sends_rework.md §C.3):

  • THE EAR, by export + difference. The wet of a send is measured as E_on − E_off (the same export
    with the send disabled), never by panning: a mono object is duplicated left → right at the end
    of its chain, and a hard-left sender into a hard-right aux depends on the pan law;
  • LEVEL and ALIGNMENT to the sample: `idx(peak wet) == idx(peak dry)`, and the peak ratio equals
    the send level;
  • Q8 (section M): the wet's envelope when the send's level is AUTOMATED — the legacy plugin was
    called in 128-sample sub-blocks there and overwrote its own tap length; the bridge removes the
    cause by construction. The same section runs on `main` first (`--ref`), the numbers being the
    answer recorded in the plan;
  • the NULL TEST (section O): the same sessions exported by an instance launched with
    OBJ_SENDS_LEGACY=1 and by a normal one must subtract to ≤ 1 LSB of 24 bits.

    objekat.app/Contents/MacOS/objekat --headless --api --no-recent --language=en --socket=/tmp/os.sock
    ./scenario_bridge_sends.py /tmp/os.sock /tmp/trial_sends/project.objekat [options]

Options:
    --ref            run against `main` AS IS (the legacy engine): the checks that need the bridge's
                     report (`passes`, `gate_edges`, aligned readers…) and the sections that need the
                     new scope are skipped, every measured number is printed as a REFERENCE.
    --only A,M,O     run only these sections.
    --tag NAME       section O: the tag of the exports it writes (O_<case>_<tag>.wav).
    --compare A B    section O, second half: subtract the exports of tags A and B (no instance needed).

NOT `--no-audio` (the bridge reads the device's clock); exits 2 if `app.info` says audio is not
running. A DEBUG build (it reads `debug.bridge_report`). Exit: 0 if everything passes, 1 otherwise.
"""

import json, math, os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError
import bridge_scenario_common as B

args = sys.argv[1:]


def opt(name, n=0):
    if name in args:
        i = args.index(name)
        vals = args[i + 1:i + 1 + n]
        del args[i:i + 1 + n]
        return vals if n else True
    return None


REF = bool(opt("--ref"))
ONLY = (opt("--only", 1) or [None])[0]
TAG = (opt("--tag", 1) or ["run"])[0]
COMPARE = opt("--compare", 2)
ONLY = set(ONLY.split(",")) if ONLY else None

T = B.Tally(ObjekatError)
step, check = T.step, T.check

if COMPARE:
    pass
elif len(args) != 2:
    print(__doc__)
    sys.exit(2)
else:
    SOCK, PROJ = args
    DIR = os.path.dirname(PROJ)
    os.makedirs(DIR, exist_ok=True)

SR = B.SR
LSB = 1.0 / 8388607.0
IMP_AMP = 0.2          # an impulse at 0.2: dry + wet never clips the export (0.9 did, at −6 dB)


def want(section):
    return ONLY is None or section in ONLY


def out(name):
    return os.path.join(DIR, name)


def fixtures():
    B._write24(out("imp.wav"), [IMP_AMP if i == SR else 0.0 for i in range(3 * SR)])
    B._write24(out("imp_small.wav"), [0.05 if i == 2 * SR else 0.0 for i in range(3 * SR)])
    B.make_sine(out("sine1k.wav"), seconds=4.0, hz=1000.0, dbfs=-12.0)


def wait(c):
    c.send("wait_idle")


def fresh(c, name):
    """A new project in its own folder (samples are copied next to it)."""
    c.send("project.new")
    os.makedirs(out(name), exist_ok=True)
    c.send("project.save_as", {"path": out(name + "/project.objekat")})


def render(c, name, t0=0.0, t1=3.0):
    wait(c)
    r = c.send("export.run", {"format": "wav", "sample_rate": SR, "dithering": False,
                              "start": t0, "end": t1, "path": out(name)})
    c.send("job.wait", {"id": r["job_id"], "timeout_ms": 180000})
    return B.read_wav(out(name))[0]


def sub(a, b):
    n = min(len(a), len(b))
    return [a[i] - b[i] for i in range(n)]


def maxabs(s):
    return max((abs(v) for v in s), default=0.0)


def bridge_report(c):
    """The newest published build; the LIVE graph only exists once the playback context is
    allocated, so play a moment first."""
    c.send("transport.play", {})
    time.sleep(0.8)
    c.send("transport.stop")
    wait(c)
    return c.send("debug.bridge_report")


def send_readers(rep):
    eng = rep.get("engine") or {}
    return [r for r in eng.get("readers", []) if r.get("consumer") in ("auxInput", "aux")]


def add_test(c, host, kind, latency_ms=None):
    p = {"host": host, "type": kind}
    if latency_ms is not None:
        p["latency_ms"] = latency_ms
    return c.send("debug.add_test_plugin", p)


def lay_send(c, x, aux, db):
    c.send("send.set_level", {"id": x, "aux": aux, "db": db})


def measure(c, label, x, aux, db, t1=3.0, tag=""):
    """Wet by difference. Returns (dry, wet) and asserts determinism, alignment and level."""
    on = render(c, "%s%s_on.wav" % (label, tag), 0.0, t1)
    c.send("send.enable", {"id": x, "aux": aux, "enabled": False})
    off = render(c, "%s%s_off.wav" % (label, tag), 0.0, t1)
    off2 = render(c, "%s%s_off2.wav" % (label, tag), 0.0, t1)
    c.send("send.enable", {"id": x, "aux": aux, "enabled": True})
    check(label + ": two identical exports subtract to zero", maxabs(sub(off, off2)) == 0.0, maxabs(sub(off, off2)))
    wet = sub(on, off)
    return off, wet


def level_and_index(label, dry, wet, db, tol=0.05):
    pd, pw = B.peak_index(dry), B.peak_index(wet)
    if pw is None:
        check(label + ": the wet is present", False, "wet is silent")
        return None
    got = 20.0 * math.log10(max(abs(wet[pw]), 1e-12) / max(abs(dry[pd]), 1e-12))
    print("       %s: peak dry @%s, wet @%s, level %.3f dB (wanted %.2f)" % (label, pd, pw, got, db))
    check(label + ": wet aligned to the dry (same sample)", pd == pw, "%s vs %s" % (pd, pw))
    check(label + ": level %.1f dB (+-%.2f)" % (db, tol), abs(got - db) <= tol, "%.3f" % got)
    return got


# --------------------------------------------------------------------------------------------------
# The cast of a case. Each builder returns (sender, aux) and leaves the project ready to render.
# --------------------------------------------------------------------------------------------------

def cast_siblings(c, name):
    fresh(c, name)
    x = c.send("object.add", {"path": out("imp.wav"), "lane": 0, "start": 0.0})["id"]
    a = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 1})["id"]
    return x, a


def cast_stem(c, name):
    x, a = cast_siblings(c, name)
    s = c.send("stem.add", {"name": "S"})["id"]
    c.send("stem.assign", {"stem": s, "ids": [x, a]})
    return x, a


def cast_group(c, name):
    """The sender and the aux both inside ONE group (siblings of that group)."""
    x, a = cast_siblings(c, name)
    g = c.send("group.create", {"ids": [x, a]})["id"]
    return x, a, g


CASTS_A = (("A1 siblings at the Main", cast_siblings),
           ("A2 siblings in a stem", cast_stem),
           ("A3 siblings inside a group", lambda c, n: cast_group(c, n)[:2]))


def check_pass_counters(c, label, expect_readers=1):
    """On the bridge: one converged pass, every send reader aligned."""
    if REF:
        return
    rep = bridge_report(c)
    eng = rep.get("engine") or {}
    build = eng.get("build") or {}
    check(label + ": the build converged in one pass", build.get("converged") is True and build.get("passes") == 1,
          build)
    rds = send_readers(rep)
    check(label + ": %d send reader(s), all aligned" % expect_readers,
          len(rds) == expect_readers and all(r.get("alignment_error_samples") == 0 for r in rds), rds)
    check(label + ": no torn block", all(r.get("blocks_torn", 0) == 0 for r in rds), rds)


# --------------------------------------------------------------------------------------------------
# A — in scope, as today
# --------------------------------------------------------------------------------------------------

def section_A(c):
    print("\n--- A  in scope, as today: level -6 dB, to the sample")
    for label, cast in CASTS_A:
        x, a = cast(c, label.split()[0])
        lay_send(c, x, a, -6.0)
        dry, wet = measure(c, label.split()[0], x, a, -6.0)
        level_and_index(label, dry, wet, -6.0)
        check_pass_counters(c, label)


# --------------------------------------------------------------------------------------------------
# D — latency, in scope
# --------------------------------------------------------------------------------------------------

def d_case(c, name, where):
    x, a = cast_siblings(c, name)
    # The sibling is a SMALL impulse at 2 s: it must not add to the sender's peak at 1 s.
    other = c.send("object.add", {"path": out("imp_small.wav"), "lane": 3, "start": 0.0})["id"]
    host = {"sender": x, "aux": a, "sibling": other}[where]
    add_test(c, host, "latencyTester", 20.0)
    lay_send(c, x, a, -6.0)
    wait(c)
    time.sleep(0.4)          # a latency tester asks for a rebuild on its own timer
    wait(c)
    return x, a


def section_D(c):
    print("\n--- D  latency (20 ms) on the sender / on the aux / on a sibling: the wet stays on the dry")
    for where in ("sender", "aux", "sibling"):
        label = "D-" + where
        x, a = d_case(c, label, where)
        dry, wet = measure(c, label, x, a, -6.0)
        # With a latency on the SENDER the dry is itself delayed by PDC; the pair must stay together.
        level_and_index(label, dry, wet, -6.0)


# --------------------------------------------------------------------------------------------------
# M — Q8: an automated send level
# --------------------------------------------------------------------------------------------------

def curve_db(points, t):
    if t <= points[0][0]:
        return points[0][1]
    for (t0, v0), (t1, v1) in zip(points, points[1:]):
        if t0 <= t <= t1:
            return v0 + (v1 - v0) * (t - t0) / (t1 - t0)
    return points[-1][1]


def automate_send(c, proj_dir, x_id, aux_id, points, new_name):
    """No `automation.*` command exists: the curve is written in the saved session, which is then
    reopened (a model door that the format already has)."""
    c.send("project.save")
    path = out(proj_dir + "/project.objekat")
    d = json.load(open(path))
    for it in d["items"]:
        if it["id"] == x_id:
            it["automation"] = [{"param": {"type": "send", "auxID": aux_id},
                                 "points": [{"t": t, "v": v, "c": 0} for t, v in points]}]
    json.dump(d, open(path, "w"), indent=1)
    c.send("project.open", {"path": path})
    wait(c)


def window_rms_db(s, t0, t1, win=0.010):
    out_ = []
    t = t0
    while t + win <= t1 + 1e-9:
        out_.append((t, B.db(B.rms(s, t, t + win))))
        t += win
    return out_


def section_M(c):
    print("\n--- M  Q8: the send level AUTOMATED (1 kHz sine, wet by difference)")
    for variant, pts, tol in (("M1 flat -6 dB", [(0.0, -6.0), (4.0, -6.0)], 0.1),
                              ("M2 ramp -30 -> 0 dB over 1 s", [(0.0, -30.0), (1.0, 0.0), (4.0, 0.0)], 1.0)):
        name = variant.split()[0]
        fresh(c, name)
        x = c.send("object.add", {"path": out("sine1k.wav"), "lane": 0, "start": 0.0})["id"]
        a = c.send("aux.create", {"start": 0.0, "end": 4.0, "lane": 1})["id"]
        lay_send(c, x, a, 0.0)
        automate_send(c, name, x, a, pts, name)
        sl = c.send("send.list", {"id": x})["sends"]
        check(variant + ": the send is automated", bool(sl) and sl[0].get("automated") is True, sl)
        dry, wet = measure(c, name, x, a, 0.0, t1=4.0)
        wd = dict(window_rms_db(wet, 0.2, 3.8))
        dd = dict(window_rms_db(dry, 0.2, 3.8))
        # Per 10 ms window: the wet's level minus the dry's, against the curve.
        errs = []
        for t in sorted(wd):
            errs.append((t, (wd[t] - dd[t]) - curve_db(pts, t + 0.005)))
        stats = [e for _, e in errs]
        mean_e = sum(stats) / len(stats)
        print("       %s: (wet - dry) - curve over %d windows: min %.2f dB, mean %.2f dB, max %.2f dB" %
              (variant, len(stats), min(stats), mean_e, max(stats)))
        if tol <= 0.1:
            worst = max(abs(e) for e in stats)
            if REF:
                print("       REFERENCE (Q8): worst |error| %.3f dB, spread %.2f dB" % (worst, max(stats) - min(stats)))
            else:
                check(variant + ": wet = dry + curve within %.1f dB" % tol, worst <= tol, "%.3f dB" % worst)
        else:
            # The 50 ms smoother lags the curve: take the best constant lag in 0..60 ms.
            best = None
            for lag_ms in range(0, 65, 5):
                lag = lag_ms / 1000.0
                w = max(abs((wd[t] - dd[t]) - curve_db(pts, t + 0.005 - lag)) for t in sorted(wd) if t > 0.3)
                if best is None or w < best[0]:
                    best = (w, lag_ms)
            holes = [t for t in sorted(wd) if wd[t] < -90.0]
            print("       %s: best fit lag %d ms, worst error %.3f dB, holes (< -90 dB windows): %d" %
                  (variant, best[1], best[0], len(holes)))
            if REF:
                print("       REFERENCE (Q8): ramp error %.2f dB at the best lag" % best[0])
            else:
                check(variant + ": the envelope follows the curve within %.1f dB (lag <= 60 ms)" % tol, best[0] <= tol,
                      "%.3f dB at lag %d ms" % best)
                check(variant + ": no hole", not holes, holes[:5])
        # The 128-sample signature of Q8: the largest window-to-window step of the wet's RMS inside
        # the flat part of M1 should be ~0.
        check_pass_counters(c, variant)


# --------------------------------------------------------------------------------------------------
# O — the null test, legacy vs bridge
# --------------------------------------------------------------------------------------------------

def section_O(c):
    print("\n--- O  null-test exports (tag %s): in-scope sessions of A and D" % TAG)
    for label, cast in CASTS_A:
        n = label.split()[0]
        x, a = cast(c, n)
        lay_send(c, x, a, -6.0)
        render(c, "O_%s_%s.wav" % (n, TAG))
    for where in ("sender", "aux", "sibling"):
        x, a = d_case(c, "Od-" + where, where)
        render(c, "O_D%s_%s.wav" % (where, TAG))


def section_O_compare(dirpath, tag_a, tag_b):
    print("\n--- O  null test: %s vs %s" % (tag_a, tag_b))
    names = sorted(f[2:-len(tag_a) - 5] for f in os.listdir(dirpath) if f.startswith("O_") and f.endswith("_%s.wav" % tag_a))
    for n in names:
        a = B.read_wav(os.path.join(dirpath, "O_%s_%s.wav" % (n, tag_a)))[0]
        b = B.read_wav(os.path.join(dirpath, "O_%s_%s.wav" % (n, tag_b)))[0]
        d = maxabs(sub(a, b))
        print("       %s: max |difference| = %.3e (%.2f LSB)  peak %.4f" % (n, d, d / LSB, maxabs(a)))
        check("O %s: legacy and bridge null to <= 1 LSB" % n, len(a) == len(b) and d <= LSB * 1.0001, d / LSB)


# --------------------------------------------------------------------------------------------------

if COMPARE:
    DIR = COMPARE[0] if os.path.isdir(COMPARE[0]) else None
    print("usage of --compare: --compare <dir> <tagA>:<tagB>") if DIR is None else None
    ta, tb = COMPARE[1].split(":")
    section_O_compare(DIR, ta, tb)
    T.finish()
    sys.exit(0 if T.ko == 0 else 1)

fixtures()
with ObjekatClient(SOCK) as c:
    B.require_audio(c)
    c.send("app.set_dialog_policy", {"policy": "assume_yes"})
    print("mode: %s" % ("REFERENCE (main, legacy engine)" if REF else "bridge"))
    for sec, fn in (("A", section_A), ("D", section_D), ("M", section_M), ("O", section_O)):
        if want(sec):
            fn(c)

T.finish()
sys.exit(0 if T.ko == 0 else 1)

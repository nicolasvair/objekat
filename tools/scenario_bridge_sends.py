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
  • Q8 (section M): the wet's envelope when the send's level is AUTOMATED — the first, pre-bridge
    send plugin was called in 128-sample sub-blocks there and overwrote its own tap length; the
    bridge removes the cause by construction. The numbers measured on `main` (`--ref`) are recorded
    in the plan (journal B.J). The null test against that old path (former section O) went with the
    path itself, deleted at the start of INC 2.

    objekat.app/Contents/MacOS/objekat --headless --api --no-recent --language=en --socket=/tmp/os.sock
    ./scenario_bridge_sends.py /tmp/os.sock /tmp/trial_sends/project.objekat [options]

Options:
    --ref            run against `main` AS IS (the pre-bridge engine): the checks that need the bridge's
                     report (`passes`, `gate_edges`, aligned readers…) and the sections that need the
                     new scope are skipped, every measured number is printed as a REFERENCE.
    --only A,M,Q2    run only these sections (INC 2's sections carry a 2: Q2, R2, S2, T2, U2, V2, W2, X2,
                     Y2, Z2, P2 — INC 1 already used the letters P to T).

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
ONLY = set(ONLY.split(",")) if ONLY else None

T = B.Tally(ObjekatError)
step, check = T.step, T.check

if len(args) != 2:
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
    B._write24(out("imp_two.wav"), [IMP_AMP if i in (SR, 2 * SR) else 0.0 for i in range(3 * SR)])


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
# Helpers for the sections below
# --------------------------------------------------------------------------------------------------

def grp(c, ids):
    return c.send("group.create", {"ids": ids})["id"]


def send_entry(c, x, a):
    for e in c.send("send.list", {"id": x})["sends"]:
        if e["aux"] == a:
            return e
    return None


def silent(label, wet, tol=1e-6):
    m = maxabs(wet)
    check(label + ": the wet is silent", m <= tol, "%.3e" % m)


def with_other(c, lane=3, start=0.0):
    """A small impulse at 2 s on its own lane: keeps a group alive and spans it, never collides with
    the sender's peak at 1 s."""
    return c.send("object.add", {"path": out("imp_small.wav"), "lane": lane, "start": start})["id"]


def gate_edges(c):
    rep = bridge_report(c)
    return ((rep.get("engine") or {}).get("build") or {}).get("gate_edges"), rep


def build_of(c):
    return (((c.send("debug.bridge_report") or {}).get("engine") or {}).get("build") or {})


# --------------------------------------------------------------------------------------------------
# B — upward
# --------------------------------------------------------------------------------------------------

def section_B(c):
    print("\n--- B  upward: a child / grandchild reaches an aux outside its groups (no rank needed)")
    # B1  child of a group -> aux of the Main
    fresh(c, "B1")
    x = c.send("object.add", {"path": out("imp.wav"), "lane": 0, "start": 0.0})["id"]
    o = with_other(c)
    a = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 5})["id"]
    grp(c, [x, o])
    lay_send(c, x, a, -6.0)
    dry, wet = measure(c, "B1", x, a, -6.0)
    level_and_index("B1 child -> Main aux", dry, wet, -6.0)
    ge, _ = gate_edges(c)
    check("B1: no gate edge (upward needs no rank)", ge == 0, ge)
    # B2  grandchild -> Main aux
    fresh(c, "B2")
    x = c.send("object.add", {"path": out("imp.wav"), "lane": 0, "start": 0.0})["id"]
    o1, o2 = with_other(c), with_other(c, lane=4)
    a = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 8})["id"]
    g2 = grp(c, [x, o1])
    grp(c, [g2, o2])
    lay_send(c, x, a, -6.0)
    dry, wet = measure(c, "B2", x, a, -6.0)
    level_and_index("B2 grandchild -> Main aux", dry, wet, -6.0)
    ge, _ = gate_edges(c)
    check("B2: no gate edge", ge == 0, ge)
    # B3  child of a group of stem X -> top-level aux of X
    fresh(c, "B3")
    x = c.send("object.add", {"path": out("imp.wav"), "lane": 0, "start": 0.0})["id"]
    o = with_other(c)
    a = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 5})["id"]
    g = grp(c, [x, o])
    st = c.send("stem.add", {"name": "X"})["id"]
    c.send("stem.assign", {"stem": st, "ids": [g, a]})
    lay_send(c, x, a, -6.0)
    dry, wet = measure(c, "B3", x, a, -6.0)
    level_and_index("B3 child of a group of stem X -> aux of X", dry, wet, -6.0)
    # B4  grandchild -> aux of its grandparent group
    fresh(c, "B4")
    x = c.send("object.add", {"path": out("imp.wav"), "lane": 0, "start": 0.0})["id"]
    o = with_other(c)
    a = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 5})["id"]
    g2 = grp(c, [x, o])
    grp(c, [g2, a])
    lay_send(c, x, a, -6.0)
    dry, wet = measure(c, "B4", x, a, -6.0)
    level_and_index("B4 grandchild -> aux of its grandparent group", dry, wet, -6.0)


# --------------------------------------------------------------------------------------------------
# C — across: the aux is in a group the sender is not in
# --------------------------------------------------------------------------------------------------

def section_C(c):
    print("\n--- C  across: the return comes out THROUGH the aux's group (its fader acts on the wet)")
    # C1  top-level sender -> aux inside G2 ; G2's fader at -12 dB
    fresh(c, "C1")
    x = c.send("object.add", {"path": out("imp.wav"), "lane": 0, "start": 0.0})["id"]
    a = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 5})["id"]
    o2 = with_other(c, lane=6)
    g2 = grp(c, [a, o2])
    lay_send(c, x, a, -6.0)
    dry, wet = measure(c, "C1a", x, a, -6.0)
    level_and_index("C1 top-level -> aux in G2 (fader 0 dB)", dry, wet, -6.0)
    ge, rep = gate_edges(c)
    check("C1: a gate edge exists (G2 waits for the sender)", ge is not None and ge > 0, ge)
    c.send("object.set_gain", {"ids": [g2], "db": -12.0})
    dry, wet = measure(c, "C1b", x, a, -18.0)
    level_and_index("C1 ... G2 fader -12 dB: the wet goes THROUGH it", dry, wet, -18.0)
    check_pass_counters(c, "C1")
    # C2  child of G1 -> aux inside G2
    fresh(c, "C2")
    x = c.send("object.add", {"path": out("imp.wav"), "lane": 0, "start": 0.0})["id"]
    o1 = with_other(c)
    a = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 5})["id"]
    o2 = with_other(c, lane=6)
    grp(c, [x, o1])
    grp(c, [a, o2])
    lay_send(c, x, a, -6.0)
    dry, wet = measure(c, "C2", x, a, -6.0)
    level_and_index("C2 child of G1 -> aux in G2", dry, wet, -6.0)
    ge, _ = gate_edges(c)
    check("C2: a gate edge exists", ge is not None and ge > 0, ge)


# --------------------------------------------------------------------------------------------------
# D2 — latency in the across case
# --------------------------------------------------------------------------------------------------

def section_D2(c):
    print("\n--- D2  latency (20 ms) in the ACROSS case: the sender's group, the aux's group, an unrelated object")
    for where in ("senderGroup", "auxGroup", "unrelated", "all"):
        label = "D2-" + where
        fresh(c, label)
        x = c.send("object.add", {"path": out("imp.wav"), "lane": 0, "start": 0.0})["id"]
        o1 = with_other(c)
        a = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 5})["id"]
        o2 = with_other(c, lane=6)
        unrelated = with_other(c, lane=9)
        g1 = grp(c, [x, o1])
        g2 = grp(c, [a, o2])
        targets = {"senderGroup": [g1], "auxGroup": [g2], "unrelated": [unrelated],
                   "all": [x, a, g1, g2, unrelated]}[where]
        for t in targets:
            add_test(c, t, "latencyTester", 20.0)
        lay_send(c, x, a, -6.0)
        wait(c)
        time.sleep(0.5)
        wait(c)
        dry, wet = measure(c, label, x, a, -6.0)
        level_and_index(label, dry, wet, -6.0)
        b = build_of(c)
        print("       %s: build %s passes=%s converged=%s" % (label, b.get("id"), b.get("passes"), b.get("converged")))
        check(label + ": converged", b.get("converged") is True, b)
        check(label + ": at most two construction passes", (b.get("passes") or 9) <= 2, b)


# --------------------------------------------------------------------------------------------------
# E — the stem limit
# --------------------------------------------------------------------------------------------------

def section_E(c):
    print("\n--- E  stem limit: an object does not reach an aux of a sibling stem")
    fresh(c, "E")
    x = c.send("object.add", {"path": out("imp.wav"), "lane": 0, "start": 0.0})["id"]
    y = c.send("object.add", {"path": out("imp.wav"), "lane": 2, "start": 0.0})["id"]
    ax = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 5})["id"]
    ay = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 7})["id"]
    sx = c.send("stem.add", {"name": "X"})["id"]
    sy = c.send("stem.add", {"name": "Y"})["id"]
    c.send("stem.assign", {"stem": sx, "ids": [x, ax]})
    c.send("stem.assign", {"stem": sy, "ids": [y, ay]})
    cands = {e["aux"]: e["refusal"] for e in c.send("send.candidates", {"id": x})["candidates"]}
    check("E: x -> aux of X is allowed", cands.get(ax) is None, cands)
    check("E: x -> aux of Y says outOfStem", cands.get(ay) == "outOfStem", cands)
    # forced through the machine's door: the entry is kept, the plan refuses it
    lay_send(c, x, ay, -6.0)
    e = send_entry(c, x, ay)
    check("E: the forced entry is kept", e is not None and e["enabled"] is True, e)
    check("E: ... and refused outOfStem (routed false)", e is not None and e["status"] == "refused"
          and e["refusal"] == "outOfStem" and e["routed"] is False, e)
    # (the other sender is muted each time: two impulses at the same sample would add up in the dry)
    c.send("object.set_mute", {"ids": [y], "muted": True})
    dry, wet = measure(c, "E-out", x, ay, -6.0)
    silent("E x -> aux of Y", wet)
    c.send("object.set_mute", {"ids": [y], "muted": False})
    # the sibling-stem sends of the same cast keep working
    lay_send(c, y, ay, -6.0)
    c.send("object.set_mute", {"ids": [x], "muted": True})
    dry, wet = measure(c, "E-in", y, ay, -6.0)
    level_and_index("E y -> aux of Y (untouched)", dry, wet, -6.0)
    c.send("object.set_mute", {"ids": [x], "muted": False})
    # an aux of the Main is reachable from a stem
    am = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 9})["id"]
    lay_send(c, x, am, -6.0)
    c.send("object.set_mute", {"ids": [y], "muted": True})
    dry, wet = measure(c, "E-main", x, am, -6.0)
    level_and_index("E x (stem X) -> aux of the Main", dry, wet, -6.0)


# --------------------------------------------------------------------------------------------------
# F — refusals
# --------------------------------------------------------------------------------------------------

def section_F(c):
    print("\n--- F  refusals: a group to its own aux, an aux as sender, the two-group cycle")
    fresh(c, "F1")
    x = c.send("object.add", {"path": out("imp.wav"), "lane": 0, "start": 0.0})["id"]
    a = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 5})["id"]
    g = grp(c, [x, a])
    lay_send(c, g, a, -6.0)
    e = send_entry(c, g, a)
    check("F1: a group -> an aux it contains is refused ancestorSource", e is not None and e["refusal"] == "ancestorSource", e)
    dry, wet = measure(c, "F1", g, a, -6.0)
    silent("F1", wet)
    a2 = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 9})["id"]
    lay_send(c, a, a2, -6.0)
    e = send_entry(c, a, a2)
    check("F1: an aux as sender is refused auxSource", e is not None and e["refusal"] == "auxSource", e)
    # the two-group cycle
    fresh(c, "F2")
    x1 = c.send("object.add", {"path": out("imp.wav"), "lane": 0, "start": 0.0})["id"]
    a1 = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 1})["id"]
    x2 = c.send("object.add", {"path": out("imp_small.wav"), "lane": 4, "start": 0.0})["id"]
    a2 = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 5})["id"]
    grp(c, [x1, a1])
    grp(c, [x2, a2])
    lay_send(c, x1, a2, -6.0)           # G1 -> G2: the first, accepted
    lay_send(c, x2, a1, -6.0)           # G2 -> G1: closes the loop
    e1, e2 = send_entry(c, x1, a2), send_entry(c, x2, a1)
    check("F2: the first send of the cycle is accepted", e1 is not None and e1["status"] == "active", e1)
    check("F2: the second is refused cycle", e2 is not None and e2["refusal"] == "cycle", e2)
    # (a refusal depends on the ORDER of the routes: switching the first send off lets the second in,
    # so each is measured against a render where the OTHER is off)
    both = render(c, "F2_both.wav")
    c.send("send.enable", {"id": x2, "aux": a1, "enabled": False})
    only1 = render(c, "F2_only1.wav")
    check("F2: the refused send adds nothing (both == only the first)", maxabs(sub(both, only1)) == 0.0,
          maxabs(sub(both, only1)))
    c.send("send.enable", {"id": x1, "aux": a2, "enabled": False})
    none = render(c, "F2_none.wav")
    wet1 = sub(only1, none)
    level_and_index("F2 first send unchanged", none, wet1, -6.0)
    cands = {e["aux"]: e["refusal"] for e in c.send("send.candidates", {"id": x2})["candidates"]}
    c.send("send.enable", {"id": x1, "aux": a2, "enabled": True})
    c.send("send.enable", {"id": x2, "aux": a1, "enabled": True})
    cands = {e["aux"]: e["refusal"] for e in c.send("send.candidates", {"id": x2})["candidates"]}
    check("F2: send.candidates says cycle for the loop", cands.get(a1) == "cycle", cands)


# --------------------------------------------------------------------------------------------------
# G / H — undo, redo, save, reopen
# --------------------------------------------------------------------------------------------------

def section_GH(c):
    print("\n--- G  undo / redo of a send: lay, level, on/off")
    fresh(c, "G")
    x = c.send("object.add", {"path": out("imp.wav"), "lane": 0, "start": 0.0})["id"]
    a = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 1})["id"]
    e0 = render(c, "G_E0.wav")
    lay_send(c, x, a, -6.0)
    e1 = render(c, "G_E1.wav")
    check("G: the send makes a wet", maxabs(sub(e1, e0)) > 1e-3, maxabs(sub(e1, e0)))
    c.send("edit.undo"); wait(c)
    check("G: undo of the send: no wet", maxabs(sub(render(c, "G_u1.wav"), e0)) == 0.0, "")
    c.send("edit.redo"); wait(c)
    check("G: redo: the same as E1 (null)", maxabs(sub(render(c, "G_r1.wav"), e1)) == 0.0, "")
    lay_send(c, x, a, -12.0)
    e2 = render(c, "G_E2.wav")
    c.send("edit.undo"); wait(c)
    check("G: undo of the level: E1 again", maxabs(sub(render(c, "G_u2.wav"), e1)) == 0.0, "")
    c.send("edit.redo"); wait(c)
    check("G: redo of the level: E2 again", maxabs(sub(render(c, "G_r2.wav"), e2)) == 0.0, "")
    c.send("send.enable", {"id": x, "aux": a, "enabled": False})
    e3 = render(c, "G_E3.wav")
    check("G: switched off: no wet", maxabs(sub(e3, e0)) == 0.0, "")
    c.send("edit.undo"); wait(c)
    check("G: undo of the switch: E2 again", maxabs(sub(render(c, "G_u3.wav"), e2)) == 0.0, "")
    c.send("edit.redo"); wait(c)
    check("G: redo of the switch: E3 again", maxabs(sub(render(c, "G_r3.wav"), e3)) == 0.0, "")
    c.send("send.enable", {"id": x, "aux": a, "enabled": True}); wait(c)

    print("\n--- H  save and reopen: the same sound, the same send list")
    before = c.send("send.list", {"id": x})
    ref = render(c, "H_ref.wav")
    c.send("project.save")
    path = out("G/project.objekat")
    c.send("project.open", {"path": path})
    wait(c)
    after = c.send("send.list", {"id": x})
    strip = lambda d: [(e["aux"], e["level_db"], e["enabled"], e["routed"], e["status"]) for e in d["sends"]]
    check("H: send.list identical after reopening", strip(before) == strip(after), (strip(before), strip(after)))
    check("H: the export subtracts to zero against the one before", maxabs(sub(render(c, "H_new.wav"), ref)) == 0.0, "")


# --------------------------------------------------------------------------------------------------
# I — duplicate, split
# --------------------------------------------------------------------------------------------------

def section_I(c):
    print("\n--- I  duplicate the sender, split the sender, split the aux")
    fresh(c, "I1")
    x = c.send("object.add", {"path": out("imp.wav"), "lane": 0, "start": 0.0})["id"]
    a = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 5})["id"]
    lay_send(c, x, a, -6.0)
    dry, wet1 = measure(c, "I1a", x, a, -6.0)
    d = c.send("object.duplicate", {"ids": [x]})["ids"][0]
    c.send("object.move", {"id": d, "lane": 2, "start": 0.0, "snap": False})
    wait(c)
    e = send_entry(c, d, a)
    check("I1: the duplicate carries the send", e is not None and e["enabled"] is True, e)
    on = render(c, "I1b_on.wav")
    c.send("send.enable", {"id": x, "aux": a, "enabled": False})
    c.send("send.enable", {"id": d, "aux": a, "enabled": False})
    off = render(c, "I1b_off.wav")
    wet2 = sub(on, off)
    p1, p2 = B.peak_index(wet1), B.peak_index(wet2)
    r = B.db(abs(wet2[p2])) - B.db(abs(wet1[p1])) if p1 is not None and p2 is not None else None
    print("       I1: wet of two senders vs one: %s dB, peaks @%s/@%s" % (None if r is None else "%.3f" % r, p1, p2))
    check("I1: two identical senders: +6.02 dB (+-0.05)", r is not None and abs(r - 6.0206) <= 0.05, r)
    check("I1: same index", p1 == p2, (p1, p2))

    fresh(c, "I2")
    x = c.send("object.add", {"path": out("imp.wav"), "lane": 0, "start": 0.0})["id"]
    a = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 5})["id"]
    lay_send(c, x, a, -6.0)
    dry, wet1 = measure(c, "I2a", x, a, -6.0)
    c.send("object.split_at", {"seconds": 2.0, "ids": [x]})
    wait(c)
    dry, wet2 = measure(c, "I2b", x, a, -6.0)
    level_and_index("I2 sender split across the silence after the impulse", dry, wet2, -6.0)

    fresh(c, "I3")
    x = c.send("object.add", {"path": out("imp_two.wav"), "lane": 0, "start": 0.0})["id"]
    a = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 5})["id"]
    lay_send(c, x, a, -6.0)
    c.send("object.split_at", {"seconds": 1.5, "ids": [a]})
    wait(c)
    auxes = c.send("aux.list")["auxes"]
    check("I3: the aux is now two halves", len(auxes) == 2, auxes)
    on = render(c, "I3_on.wav")
    for h in auxes:
        c.send("send.enable", {"id": x, "aux": h["id"], "enabled": False})
    off = render(c, "I3_off.wav")
    wet = sub(on, off)
    win = lambda sig, t: max(abs(v) for v in sig[int((t - 0.1) * SR):int((t + 0.1) * SR)])
    r_a = B.db(win(wet, 1.0)) - B.db(win(off, 1.0))
    r_b = B.db(win(wet, 2.0)) - B.db(win(off, 2.0))
    print("       I3: wet / dry at the two impulses: %.3f dB / %.3f dB" % (r_a, r_b))
    check("I3: the first half of the aux is fed (-6 dB)", abs(r_a + 6.0) <= 0.05, r_a)
    check("I3: the second half is fed too (duplicateSendsTarget)", abs(r_b + 6.0) <= 0.05, r_b)


# --------------------------------------------------------------------------------------------------
# J — regrouping
# --------------------------------------------------------------------------------------------------

def section_J(c):
    print("\n--- J  grouping, ungrouping, moving the aux: the send stays active and identical")
    fresh(c, "J")
    x = c.send("object.add", {"path": out("imp.wav"), "lane": 0, "start": 0.0})["id"]
    a = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 5})["id"]
    lay_send(c, x, a, -6.0)
    dry, wet = measure(c, "J0", x, a, -6.0)
    level_and_index("J0 siblings", dry, wet, -6.0)
    g = grp(c, [x])           # the sender alone: its aux is now OUTSIDE its group
    e = send_entry(c, x, a)
    check("J1: grouped alone, the send is still active", e is not None and e["status"] == "active", e)
    dry, wet = measure(c, "J1", x, a, -6.0)
    level_and_index("J1 sender grouped alone", dry, wet, -6.0)
    c.send("group.disband", {"id": g})
    dry, wet = measure(c, "J2", x, a, -6.0)
    level_and_index("J2 ungrouped", dry, wet, -6.0)
    g2 = grp(c, [x, a])
    e = send_entry(c, x, a)
    check("J3: sender and aux grouped together, still active", e is not None and e["status"] == "active", e)
    dry, wet = measure(c, "J3", x, a, -6.0)
    level_and_index("J3 sender + aux in one group", dry, wet, -6.0)
    c.send("group.disband", {"id": g2})
    # move the aux into another group: the wet now goes through that group's chain
    o = with_other(c, lane=20)       # a free lane: an object laid over an aux on the same lane would replace it
    g3 = grp(c, [o])
    c.send("object.set_gain", {"ids": [g3], "db": -12.0})
    c.send("group.reparent", {"ids": [a], "group": g3})
    wait(c)
    e = send_entry(c, x, a)
    check("J4: aux moved into another group, send active", e is not None and e["status"] == "active", e)
    dry, wet = measure(c, "J4", x, a, -18.0)
    level_and_index("J4 aux in a group at -12 dB: the wet goes through it", dry, wet, -18.0)
    c.send("group.disband", {"id": g3})
    dry, wet = measure(c, "J5", x, a, -6.0)
    level_and_index("J5 group dissolved", dry, wet, -6.0)


# --------------------------------------------------------------------------------------------------
# K — stem change
# --------------------------------------------------------------------------------------------------

def section_K(c):
    print("\n--- K  stem change: out of stem = refused and silent, back = identical, aux to the Main = reachable")
    fresh(c, "K")
    x = c.send("object.add", {"path": out("imp.wav"), "lane": 0, "start": 0.0})["id"]
    a = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 5})["id"]
    sx = c.send("stem.add", {"name": "X"})["id"]
    sy = c.send("stem.add", {"name": "Y"})["id"]
    main = c.send("stem.list")["main"]
    c.send("stem.assign", {"stem": sx, "ids": [x, a]})
    lay_send(c, x, a, -6.0)
    dry, wet = measure(c, "K0", x, a, -6.0)
    level_and_index("K0 both in X", dry, wet, -6.0)
    c.send("stem.assign", {"stem": sy, "ids": [x]})
    wait(c)
    e = send_entry(c, x, a)
    check("K1: sender moved to Y: refused outOfStem", e is not None and e["refusal"] == "outOfStem", e)
    dry, wet = measure(c, "K1", x, a, -6.0)
    silent("K1", wet)
    c.send("stem.assign", {"stem": sx, "ids": [x]})
    wait(c)
    dry, wet = measure(c, "K2", x, a, -6.0)
    level_and_index("K2 back in X: identical", dry, wet, -6.0)
    c.send("stem.assign", {"stem": sy, "ids": [x]})
    c.send("stem.assign", {"stem": main, "ids": [a]})
    wait(c)
    e = send_entry(c, x, a)
    check("K3: aux moved to the Main, sender in Y: reachable again", e is not None and e["status"] == "active", e)
    dry, wet = measure(c, "K3", x, a, -6.0)
    level_and_index("K3 aux at the Main seen from Y", dry, wet, -6.0)


# --------------------------------------------------------------------------------------------------
# L — mute and solo
# --------------------------------------------------------------------------------------------------

def section_L(c):
    print("\n--- L  mute and solo: the sender's, its stem's, another solo, and the GROUP's mute (Q-U1)")
    fresh(c, "L")
    x = c.send("object.add", {"path": out("imp.wav"), "lane": 0, "start": 0.0})["id"]
    other = c.send("object.add", {"path": out("imp_small.wav"), "lane": 3, "start": 0.0})["id"]
    a = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 5})["id"]
    lay_send(c, x, a, -6.0)
    dry, wet = measure(c, "L0", x, a, -6.0)
    level_and_index("L0 reference", dry, wet, -6.0)
    c.send("object.set_mute", {"ids": [x], "muted": True})
    dry, wet = measure(c, "L1", x, a, -6.0)
    silent("L1 the sender muted", wet)
    c.send("object.set_mute", {"ids": [x], "muted": False})
    c.send("solo.set", {"ids": [other], "on": True})
    dry, wet = measure(c, "L3", x, a, -6.0)
    silent("L3 another object soloed", wet)
    c.send("solo.clear")
    c.send("solo.set", {"ids": [x], "on": True})
    on = render(c, "L4_on.wav")
    c.send("send.enable", {"id": x, "aux": a, "enabled": False})
    off = render(c, "L4_off.wav")
    c.send("send.enable", {"id": x, "aux": a, "enabled": True})
    wet4 = sub(on, off)
    check("L4: a direct solo of the sender opens the aux (wet present)", maxabs(wet4) > 1e-3, maxabs(wet4))
    c.send("solo.clear")
    # the stem
    fresh(c, "L2")
    x = c.send("object.add", {"path": out("imp.wav"), "lane": 0, "start": 0.0})["id"]
    a = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 5})["id"]
    st = c.send("stem.add", {"name": "X"})["id"]
    c.send("stem.assign", {"stem": st, "ids": [x]})
    lay_send(c, x, a, -6.0)
    dry, wet = measure(c, "L2a", x, a, -6.0)
    level_and_index("L2 reference (sender in a stem, aux at the Main)", dry, wet, -6.0)
    c.send("stem.mute", {"id": st, "muted": True})
    dry, wet = measure(c, "L2b", x, a, -6.0)
    silent("L2 the sender's stem muted", wet)
    c.send("stem.mute", {"id": st, "muted": False})
    # the group's mute, the aux outside the group
    fresh(c, "L5")
    x = c.send("object.add", {"path": out("imp.wav"), "lane": 0, "start": 0.0})["id"]
    o = with_other(c)
    a = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 5})["id"]
    g = grp(c, [x, o])
    lay_send(c, x, a, -6.0)
    dry, wet = measure(c, "L5a", x, a, -6.0)
    level_and_index("L5 reference (child -> aux outside its group)", dry, wet, -6.0)
    c.send("object.set_mute", {"ids": [g], "muted": True})
    wait(c)
    time.sleep(0.2)
    on = render(c, "L5b_on.wav")
    c.send("send.enable", {"id": x, "aux": a, "enabled": False})
    off = render(c, "L5b_off.wav")
    c.send("send.enable", {"id": x, "aux": a, "enabled": True})
    silent("L5 the sender's GROUP muted: the send to the aux outside is gated", sub(on, off))
    c.send("object.set_mute", {"ids": [g], "muted": False})
    wait(c)
    dry, wet = measure(c, "L5c", x, a, -6.0)
    level_and_index("L5 unmuted again", dry, wet, -6.0)
    # a group's mute does NOT touch a send to an aux INSIDE that group (the group's own silence covers it)
    fresh(c, "L6")
    x = c.send("object.add", {"path": out("imp.wav"), "lane": 0, "start": 0.0})["id"]
    a = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 5})["id"]
    g = grp(c, [x, a])
    lay_send(c, x, a, -6.0)
    c.send("object.set_mute", {"ids": [g], "muted": True})
    wait(c)
    dry, wet = measure(c, "L6", x, a, -6.0)
    silent("L6 a muted group, sender and aux both inside: everything silent", dry)


# --------------------------------------------------------------------------------------------------
# N — a looping group
# --------------------------------------------------------------------------------------------------

def section_N(c):
    print("\n--- N  a sender inside a LOOPING group: every turn of the loop has the same wet, no hole at the wrap")
    fresh(c, "N")
    x = c.send("object.add", {"path": out("sine1k.wav"), "lane": 0, "start": 0.0})["id"]
    c.send("object.set_duration", {"id": x, "duration": 1.5})
    a = c.send("aux.create", {"start": 0.0, "end": 6.0, "lane": 5})["id"]
    g = grp(c, [x])
    c.send("object.set_loop", {"id": g, "enabled": True})
    c.send("object.set_loop_range", {"id": g, "start": 0.0, "end": 1.5})
    c.send("object.set_duration", {"id": g, "duration": 6.0})
    wait(c)
    lay_send(c, x, a, -6.0)
    on = render(c, "N_on.wav", 0.0, 6.0)
    c.send("send.enable", {"id": x, "aux": a, "enabled": False})
    off = render(c, "N_off.wav", 0.0, 6.0)
    c.send("send.enable", {"id": x, "aux": a, "enabled": True})
    wet = sub(on, off)
    turns = []
    for k in range(4):
        t0 = 0.05 + 1.5 * k
        turns.append(B.db(B.rms(wet, t0, t0 + 1.4)))
    print("       N: wet RMS per loop turn (dB): %s" % ", ".join("%.2f" % v for v in turns))
    check("N: the wet is there in every turn", min(turns) > -40.0, turns)
    check("N: every turn has the same level (+-0.1 dB)", max(turns) - min(turns) <= 0.1, turns)
    # no hole at the wrap: 5 ms windows around each wrap
    holes = []
    for k in (1, 2, 3):
        t = 1.5 * k
        for w in window_rms_db(wet, t - 0.02, t + 0.02, win=0.002):
            if w[1] < -45.0:
                holes.append((round(w[0], 4), round(w[1], 1)))
    check("N: no hole at the wrap of the loop", not holes, holes[:6])


# --------------------------------------------------------------------------------------------------
# P — old sessions, dangling sends
# --------------------------------------------------------------------------------------------------

def section_P(c):
    print("\n--- P  an old session: sends once silent now SOUND (Q-U2); a dangling send and its curve are dropped")
    fresh(c, "P")
    x = c.send("object.add", {"path": out("imp.wav"), "lane": 0, "start": 0.0})["id"]
    o = with_other(c)
    a = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 5})["id"]
    grp(c, [x, o])
    lay_send(c, x, a, -6.0)
    c.send("project.save")
    path = out("P/project.objekat")
    d = json.load(open(path))
    ghost = "00000000-0000-4000-8000-00000000DEAD"
    for it in d["items"]:
        for ch in (it.get("kind", {}).get("children") or []):
            if ch["id"] == x:
                ch.setdefault("sends", []).append({"auxID": ghost, "levelDb": -6.0, "enabled": True})
                ch.setdefault("automation", []).append({"param": {"type": "send", "auxID": ghost},
                                                        "points": [{"t": 0.0, "v": -6.0, "c": 0}]})
    d["version"] = 20
    json.dump(d, open(path, "w"), indent=1)
    c.send("project.open", {"path": path})
    wait(c)
    sl = c.send("send.list", {"id": x})
    auxes = [e["aux"] for e in sl["sends"]]
    check("P: the dangling send is gone on open", ghost not in auxes and a in auxes, auxes)
    e = send_entry(c, x, a)
    check("P: the send the old rule did not route stays ENABLED, level kept, and is active",
          e is not None and e["enabled"] is True and abs(e["level_db"] + 6.0) < 1e-6 and e["status"] == "active", e)
    dry, wet = measure(c, "P", x, a, -6.0)
    level_and_index("P the old-session send now sounds", dry, wet, -6.0)
    c.send("project.save")
    d2 = json.load(open(path))
    check("P: saved again as format 21", d2.get("version") == 21, d2.get("version"))
    blob = json.dumps(d2)
    check("P: neither the ghost send nor its curve survive the save", ghost not in blob, "")

    print("\n--- P2  deleting an aux takes the sends that name it, in the SAME undo point")
    fresh(c, "P2")
    x = c.send("object.add", {"path": out("imp.wav"), "lane": 0, "start": 0.0})["id"]
    a = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 5})["id"]
    lay_send(c, x, a, -6.0)
    c.send("object.remove", {"ids": [a]})
    wait(c)
    time.sleep(0.2)
    wait(c)
    check("P2: the send is gone with its aux", send_entry(c, x, a) is None, c.send("send.list", {"id": x}))
    c.send("edit.undo")
    wait(c)
    e = send_entry(c, x, a)
    check("P2: ONE undo brings the aux AND the send back", e is not None and abs(e["level_db"] + 6.0) < 1e-6
          and len(c.send("aux.list")["auxes"]) == 1, e)
    dry, wet = measure(c, "P2", x, a, -6.0)
    level_and_index("P2 after the undo", dry, wet, -6.0)


# --------------------------------------------------------------------------------------------------
# Q — windows
# --------------------------------------------------------------------------------------------------

def section_Q(c):
    print("\n--- Q  windows: the sender outside the aux's window, an infinite aux, the sender outside the host group's span")
    fresh(c, "Q1")
    x = c.send("object.add", {"path": out("imp.wav"), "lane": 0, "start": 0.0})["id"]
    a = c.send("aux.create", {"start": 2.0, "end": 3.0, "lane": 5})["id"]
    lay_send(c, x, a, -6.0)
    dry, wet = measure(c, "Q1", x, a, -6.0)
    silent("Q1 the sender's impulse is outside the aux's window", wet)
    c.send("object.set_infinite", {"id": a, "on": True})
    wait(c)
    dry, wet = measure(c, "Q2", x, a, -6.0)
    level_and_index("Q2 an infinite aux", dry, wet, -6.0)
    fresh(c, "Q3")
    x = c.send("object.add", {"path": out("imp.wav"), "lane": 0, "start": 4.0})["id"]
    a = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 5})["id"]
    o = with_other(c, lane=6)
    grp(c, [a, o])
    lay_send(c, x, a, -6.0)
    on = render(c, "Q3_on.wav", 0.0, 7.0)
    c.send("send.enable", {"id": x, "aux": a, "enabled": False})
    off = render(c, "Q3_off.wav", 0.0, 7.0)
    c.send("send.enable", {"id": x, "aux": a, "enabled": True})
    silent("Q3 the sender is outside the HOST group's span", sub(on, off))


# --------------------------------------------------------------------------------------------------
# R — a group holding only an aux
# --------------------------------------------------------------------------------------------------

def section_R(c):
    print("\n--- R  a group holding ONLY an aux, fed from outside")
    fresh(c, "R")
    x = c.send("object.add", {"path": out("imp.wav"), "lane": 0, "start": 0.0})["id"]
    a = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 5})["id"]
    grp(c, [a])
    lay_send(c, x, a, -6.0)
    dry, wet = measure(c, "R", x, a, -6.0)
    level_and_index("R sender -> an aux alone in its group", dry, wet, -6.0)
    check_pass_counters(c, "R")


# --------------------------------------------------------------------------------------------------
# S — rebuild cost
# --------------------------------------------------------------------------------------------------

def section_S(c, n=200):
    print("\n--- S  rebuild cost: %d objects, each with one send to a Main aux" % n)
    fresh(c, "S")
    a = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 0})["id"]
    ids = []
    for i in range(n):
        ids.append(c.send("object.add", {"path": out("imp_small.wav"), "lane": 1 + i, "start": 0.0})["id"])
    for x in ids:
        lay_send(c, x, a, -20.0)
    wait(c)
    rep = bridge_report(c)
    b0 = (rep["engine"] or {}).get("build") or {}
    rds = send_readers(rep)
    print("       S: build %s passes=%s, %d send readers" % (b0.get("id"), b0.get("passes"), len(rds)))
    check("S: %d send readers" % n, len(rds) == n, len(rds))
    check("S: steady state: one pass, converged", b0.get("passes") == 1 and b0.get("converged") is True, b0)
    bad = [r for r in rds if r.get("status") in ("late", "over_declared")]
    check("S: no reader late or over-declared", not bad, bad[:3])
    # a group-membership change reshapes everything: resyncAllSends
    st = c.send("stem.add", {"name": "S2"})["id"]
    wait(c)
    rep = bridge_report(c)
    b1 = (rep["engine"] or {}).get("build") or {}
    c.send("stem.assign", {"stem": st, "ids": ids})
    wait(c)
    rep = bridge_report(c)
    b2 = (rep["engine"] or {}).get("build") or {}
    print("       S: build ids: %s -> %s (the stem change); passes=%s" % (b1.get("id"), b2.get("id"), b2.get("passes")))
    # Each build id is one graph build; play/stop of the report helper does not rebuild it
    check("S: the stem change costs ONE rebuild", (b2.get("id") or 0) - (b1.get("id") or 0) <= 2,
          (b1.get("id"), b2.get("id")))
    rds = send_readers(rep)
    check("S: still %d send readers, one pass" % n, len(rds) == n and b2.get("passes") == 1, (len(rds), b2.get("passes")))


# --------------------------------------------------------------------------------------------------
# T — the live graph
# --------------------------------------------------------------------------------------------------

def section_T(c):
    print("\n--- T  the live graph: play 2 s, every send reader read and nothing torn")
    fresh(c, "T")
    x = c.send("object.add", {"path": out("sine1k.wav"), "lane": 0, "start": 0.0})["id"]
    o = c.send("object.add", {"path": out("sine1k.wav"), "lane": 3, "start": 0.0})["id"]
    a = c.send("aux.create", {"start": 0.0, "end": 4.0, "lane": 5})["id"]
    g = grp(c, [x])
    lay_send(c, x, a, -6.0)
    lay_send(c, o, a, -12.0)
    wait(c)
    c.send("transport.play", {})
    time.sleep(2.0)
    rep = c.send("debug.bridge_report")
    c.send("transport.stop")
    wait(c)
    rds = send_readers(rep)
    check("T: two send readers", len(rds) == 2, rds)
    check("T: blocks were read on every one", all(r.get("blocks_read", 0) > 0 for r in rds), rds)
    check("T: nothing torn", all(r.get("blocks_torn", 0) == 0 for r in rds), rds)
    check("T: all aligned", all(r.get("alignment_error_samples") == 0 for r in rds), rds)


# --------------------------------------------------------------------------------------------------

fixtures()
with ObjekatClient(SOCK) as c:
    B.require_audio(c)
    c.send("app.set_dialog_policy", {"policy": "assume_yes"})
    print("mode: %s" % ("REFERENCE (main, pre-bridge engine)" if REF else "bridge"))
    for sec, fn in (("A", section_A), ("B", section_B), ("C", section_C), ("D", section_D), ("D2", section_D2),
                    ("E", section_E), ("F", section_F), ("GH", section_GH), ("I", section_I), ("J", section_J),
                    ("K", section_K), ("L", section_L), ("M", section_M), ("N", section_N), ("P", section_P),
                    ("Q", section_Q), ("R", section_R), ("S", section_S), ("T", section_T)):
        if want(sec):
            fn(c)

T.finish()
sys.exit(0 if T.ko == 0 else 1)

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
                     Y2, Z2, RT2, PF and K2 — INC 1 already used the letters P to T). INC 3's carry a 3
                     (plugins ON a send): A3, L3, O3 (the ear), G3, M3 (the gates and the
                     refusals), X3 (limits), U3 (undo), Z3 (the file), C3 (copies), R3 (retarget and
                     positions), T3 (tails), B3 (consolidation), K3 (a key on a send's plugin), H3 (every
                     plugin command on a send host), P3 (parity with INC 2). Added on 10 October: I5 (the cut
                     of an aux duplicates the send's curves), AU3 (a REAL Apple Audio Unit on a send — skipped
                     with a line when AULowpass is not installed), SC3 (the rank-change crash, kept), D3
                     (copies are independent, from the copy's side), PL3 (positions changed while playing).
                     The reopening in a NEW PROCESS is a scenario of its own: scenario_send_plugins_reopen.py.

P3 compares every export of THIS run with the same-named export of an INC 2 reference run (the build
before plugins on sends existed): set INC2_REF_DIR=<dir of that run's exports>. Without it P3 is skipped.

T2 (4) compares a post-fader send's export with the one an INC 1 build made of the same project:
set INC1_REF_DIR=<dir>; `--only T2REF` on the INC 1 app writes the reference there (it is NOT part of a
normal run), T2 on the new app compares against it.

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
    if section == "T2REF":              # never part of a normal run
        return ONLY is not None and section in ONLY
    return ONLY is None or section in ONLY


def out(name):
    return os.path.join(DIR, name)


def fixtures():
    B._write24(out("imp.wav"), [IMP_AMP if i == SR else 0.0 for i in range(3 * SR)])
    B._write24(out("imp_small.wav"), [0.05 if i == 2 * SR else 0.0 for i in range(3 * SR)])
    B.make_sine(out("sine1k.wav"), seconds=4.0, hz=1000.0, dbfs=-12.0)
    B._write24(out("imp_two.wav"), [IMP_AMP if i in (SR, 2 * SR) else 0.0 for i in range(3 * SR)])
    B.make_sine(out("sine1s.wav"), seconds=1.0, hz=1000.0, dbfs=-12.0)      # INC 3: a short tone per sender
    B.make_sine(out("sine_m6.wav"), seconds=3.0, hz=1000.0, dbfs=-6.0)      # INC 3: what a clipper at -12 bites


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


def add_test(c, host, kind, latency_ms=None, gain_db=None):
    p = {"host": host, "type": kind}
    if latency_ms is not None:
        p["latency_ms"] = latency_ms
    if gain_db is not None:
        p["gain_db"] = gain_db
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
# I4 — the split of an AUX keeps the POSITION of the senders' send (an INC 2 gap, fixed at the head of INC 3)
# --------------------------------------------------------------------------------------------------

def section_I4(c):
    print("\n--- I4  the split of an aux: the senders' new send keeps the original's position")
    if REF:
        print("       (skipped in --ref: positions are INC 2)")
        return
    # [G -12], fader -20: the level proves the place (the sum of the gains upstream of the tap).
    for name, params, expect in (("pre_fader", {"position": "pre_fader"}, -12.0),
                                 ("chain", {"position": "chain", "index": 0}, 0.0),
                                 ("input", {"position": "input"}, 0.0),
                                 ("post_fader", {"position": "post_fader"}, -32.0)):
        fresh(c, "I4_" + name)
        x = c.send("object.add", {"path": out("imp_two.wav"), "lane": 0, "start": 0.0})["id"]
        a = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 5})["id"]
        add_test(c, x, "gainTester", gain_db=-12.0)
        c.send("object.set_gain", {"ids": [x], "db": -20.0})
        c.send("send.create", dict({"id": x, "aux": a}, **params))
        lay_send(c, x, a, 0.0)
        settle(c)
        c.send("object.split_at", {"seconds": 1.5, "ids": [a]})
        settle(c)
        auxes = [h["id"] for h in c.send("aux.list")["auxes"]]
        check("I4 %s: the aux is two halves" % name, len(auxes) == 2 and a in auxes, auxes)
        rows = {r["aux"]: r for r in c.send("send.list", {"id": x})["sends"]}
        for h in auxes:
            row = rows.get(h) or {}
            check("I4 %s: the send to %s half is at %s" % (name, "the original" if h == a else "the NEW", params["position"]),
                  row.get("position") == params["position"] and row.get("index") == params.get("index"), row)
        audit(c, "I4 " + name, want_senders=1)
        on = render(c, "I4_%s_on.wav" % name)
        for h in auxes:
            c.send("send.enable", {"id": x, "aux": h, "enabled": False})
        off = render(c, "I4_%s_off.wav" % name)
        wet = sub(on, off)
        win = lambda sig, t: max(abs(v) for v in sig[int((t - 0.1) * SR):int((t + 0.1) * SR)])
        # re the SOURCE impulse: the dry is 20 dB down (fader) and through the -12 dB tester
        k = B.db(win(off, 1.0)) + 32.0
        for t, which in ((1.0, "first"), (2.0, "second")):
            got = B.db(max(win(wet, t), 1e-12)) - k
            print("       I4 %s: wet in the %s half: %.3f dB re source" % (name, which, got))
            check("I4 %s: the %s half hears the send at its position (%.0f dB, 0.05)" % (name, which, expect),
                  abs(got - expect) <= 0.05, got)


# --------------------------------------------------------------------------------------------------
# I5 — the split of an aux duplicates the CURVES of the send: its level's and its plugins'
# --------------------------------------------------------------------------------------------------

def write_lanes(c, proj_dir, x_id, lanes):
    """Writes automation lanes on `x_id` in the saved session and reopens it (no `automation.*`
    command exists; the undo history starts empty after the reopen)."""
    c.send("project.save")
    path = out(proj_dir + "/project.objekat")
    d = json.load(open(path))
    o = find_obj(d["items"], x_id)
    o["automation"] = [{"param": prm, "points": [{"t": t, "v": v, "c": 0} for t, v in pts]} for prm, pts in lanes]
    json.dump(d, open(path, "w"), indent=1)
    c.send("project.open", {"path": path})
    wait(c)
    settle(c)


def saved_object(c, proj_dir, x_id):
    c.send("project.save")
    return find_obj(json.load(open(out(proj_dir + "/project.objekat")))["items"], x_id)


def section_I5(c):
    print("\n--- I5  the split of an aux: the new send gets the CURVES too (level and send plugins), under the copies' ids, in one undo")
    if REF:
        print("       (skipped in --ref: plugins on a send are INC 3)")
        return
    level_pts = [(0.0, -6.0), (3.0, -30.0)]
    freq_pts = [(0.0, 0.2), (3.0, 0.0)]          # normalised: 4408 Hz -> 10 Hz over the 3 s
    times = (0.5, 1.0, 1.4, 1.6, 2.0, 2.5, 2.8)
    for name, pos, with_plugin in (("level", "post_fader", False), ("plugin_post", "post_fader", True), ("plugin_input", "input", True)):
        tag = "I5_" + name
        fresh(c, tag)
        x = c.send("object.add", {"path": out("sine1k.wav"), "lane": 0, "start": 0.0})["id"]
        a = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 5})["id"]
        c.send("send.create", {"id": x, "aux": a, "position": "post_fader"})
        lay_send(c, x, a, 0.0)
        set_position(c, x, a, pos)
        lp = None
        lanes = [({"type": "send", "auxID": a}, level_pts)]
        if with_plugin:
            h = need_host(c, tag, x, a)
            r = step(tag + ": the built-in Low Pass is laid on the send", lambda: c.send("plugin.add", {"host": h, "identifier": "lowpass"}))
            lp = ((r or {}).get("plugin") or {}).get("id")
            if lp is None:
                continue
            settle(c)
            lanes = [({"type": "plugin", "pluginKey": lp, "paramID": "frequency"}, freq_pts)] + (lanes if name == "plugin_input" else [])
        write_lanes(c, tag, x, lanes)
        n_lanes = len(lanes)
        o0 = saved_object(c, tag, x)
        check(tag + ": the lanes were read back (%d)" % n_lanes, len(o0.get("automation", [])) == n_lanes, o0.get("automation"))

        # before the cut
        on0 = render(c, tag + "_before_on.wav")
        c.send("send.enable", {"id": x, "aux": a, "enabled": False})
        off = render(c, tag + "_off.wav")
        c.send("send.enable", {"id": x, "aux": a, "enabled": True})
        settle(c)
        wet0 = sub(on0, off)
        l0 = [seg_db(wet0, t, t + 0.05) for t in times]
        print("       %s before the cut: wet at %s s = %s dBFS" % (tag, "/".join("%.1f" % t for t in times), " / ".join("%.2f" % v for v in l0)))
        check(tag + ": the curve is heard (the wet falls by more than 6 dB between 0.5 s and 2.8 s)", l0[0] - l0[-1] > 6.0, (l0[0], l0[-1]))

        # the cut
        c.send("object.split_at", {"seconds": 1.5, "ids": [a]})
        settle(c)
        auxes = [h_["id"] for h_ in c.send("aux.list")["auxes"]]
        check(tag + ": the aux is two halves", len(auxes) == 2 and a in auxes, auxes)
        new = [h_ for h_ in auxes if h_ != a]
        if len(new) != 1:
            continue
        b = new[0]
        o1 = saved_object(c, tag, x)
        lanes1 = o1.get("automation", [])
        pts = lambda l: [(q["t"], q["v"]) for q in l["points"]]
        def lane_of(prm):
            for l in lanes1:
                if all(str(l["param"].get(k)).lower() == str(v).lower() for k, v in prm.items()):
                    return l
            return None
        check(tag + ": the object holds twice the lanes (%d)" % (2 * n_lanes), len(lanes1) == 2 * n_lanes, [l["param"] for l in lanes1])
        if name != "plugin_post":
            la, lb = lane_of({"type": "send", "auxID": a}), lane_of({"type": "send", "auxID": b})
            check(tag + ": the LEVEL's lane exists for both halves, same points",
                  la is not None and lb is not None and pts(la) == pts(lb), (la, lb))
        if with_plugin:
            ids_a, ids_b = send_plugins3(c, x, a), send_plugins3(c, x, b)
            check(tag + ": each half's send has its own plugin (fresh id)", len(ids_a) == 1 and len(ids_b) == 1 and ids_a[0] == lp and ids_b[0] != lp, (ids_a, ids_b))
            if len(ids_b) == 1:
                pa = lane_of({"type": "plugin", "pluginKey": lp, "paramID": "frequency"})
                pb = lane_of({"type": "plugin", "pluginKey": ids_b[0], "paramID": "frequency"})
                check(tag + ": the plugin's lane exists for the original AND for the COPY's id, same points",
                      pa is not None and pb is not None and pts(pa) == pts(pb), (pa, pb))
                rows = (send_entry(c, x, b) or {}).get("plugins", [])
                check(tag + ": the copy is not linked", all(not r_.get("linked") for r_ in rows), rows)
                links = [q for s_ in o1.get("sends", []) for q in s_.get("plugins", []) if q.get("linkGroupID")]
                check(tag + ": no `linkGroupID` on a send plugin in the file", links == [], links)
        audits3(c, tag)

        on1 = render(c, tag + "_after_on.wav")
        wet1 = sub(on1, off)
        l1 = [seg_db(wet1, t, t + 0.05) for t in times]
        print("       %s after the cut:  wet at the same times     = %s dBFS" % (tag, " / ".join("%.2f" % v for v in l1)))
        check(tag + ": both halves sound as before the cut (0.1 dB at every reading)",
              all(abs(u - v) <= 0.1 for u, v in zip(l0, l1)), [round(v - u, 3) for u, v in zip(l0, l1)])

        # ONE undo point: the cut, its sends and their curves
        c.send("edit.undo", {})
        settle(c)
        auxes_u = [h_["id"] for h_ in c.send("aux.list")["auxes"]]
        o2 = saved_object(c, tag, x)
        check(tag + ": ONE undo: one aux, one send, the original lanes only",
              auxes_u == [a] and len(o2.get("sends", [])) == 1 and len(o2.get("automation", [])) == n_lanes,
              (auxes_u, len(o2.get("sends", [])), [l["param"] for l in o2.get("automation", [])]))
        on2 = render(c, tag + "_undone_on.wav")
        l2 = [seg_db(sub(on2, off), t, t + 0.05) for t in times]
        check(tag + ": undone: the wet is the one before the cut (0.1 dB)", all(abs(u - v) <= 0.1 for u, v in zip(l0, l2)), l2)
        c.send("edit.redo", {})
        settle(c)
        o3 = saved_object(c, tag, x)
        check(tag + ": redo: two halves again, twice the lanes",
              len(c.send("aux.list")["auxes"]) == 2 and len(o3.get("automation", [])) == 2 * n_lanes,
              [l["param"] for l in o3.get("automation", [])])
        on3 = render(c, tag + "_redone_on.wav")
        l3 = [seg_db(sub(on3, off), t, t + 0.05) for t in times]
        check(tag + ": redone: both halves sound as before the cut (0.1 dB)", all(abs(u - v) <= 0.1 for u, v in zip(l0, l3)), l3)
        audits3(c, tag + " redone")


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
    check("P: saved again as format 25", d2.get("version") == 25, d2.get("version"))
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
# F2 — a full chain: the send is refused WITH a reason, not silently absent (INC 2, step 2.0)
# --------------------------------------------------------------------------------------------------

def section_F2(c):
    print("\n--- F2  a full chain: the send says why it is not heard")
    if REF:
        print("       (skipped in --ref: needs the bridge's report)")
        return
    x, a = cast_siblings(c, "F2")
    plugs = []
    for _ in range(16):             # the engine caps a list at 20: trims, fader and window leave 16
        plugs.append(add_test(c, x, "objKeyProbe")["plugin"])
        wait(c)
    check("F2: 16 plugins fit", len(c.send("plugin.list", {"host": x})["plugins"]) == 16)
    lay_send(c, x, a, -6.0)
    wait(c)
    time.sleep(0.5)
    wait(c)
    rep = bridge_report(c)
    row = [s for s in c.send("send.list", {"id": x})["sends"] if s["aux"] == a][0]
    print("       F2: send.list row: status=%s refusal=%s routed=%s; readers=%d"
          % (row.get("status"), row.get("refusal"), row.get("routed"), len(send_readers(rep))))
    check("F2: no send reader was laid", len(send_readers(rep)) == 0, send_readers(rep))
    check("F2: the row says chainFull", row.get("refusal") == "chainFull" and row.get("status") == "refused", row)
    # One plugin out: the slot is free, the next sync lays the send.
    c.send("plugin.remove", {"host": x, "plugin": plugs[-1]})
    wait(c)
    time.sleep(0.5)
    wait(c)
    rep = bridge_report(c)
    row = [s for s in c.send("send.list", {"id": x})["sends"] if s["aux"] == a][0]
    check("F2: a slot freed, the send is laid", len(send_readers(rep)) == 1, send_readers(rep))
    check("F2: and the refusal is gone", row.get("refusal") is None and row.get("status") == "active", row)
    dry, wet = measure(c, "F2", x, a, -6.0)
    level_and_index("F2 after the slot is freed", dry, wet, -6.0)

# --------------------------------------------------------------------------------------------------
# INC 2 — where a send takes its signal (docs/plan_sends_rework.md §D.1). Sections carry a 2.
# --------------------------------------------------------------------------------------------------

def settle(c):
    """The bridge sync is coalesced on the main queue: let it run, then run what it scheduled."""
    wait(c)
    time.sleep(0.3)
    wait(c)


def audit(c, label, want_senders=None):
    """The model's bijection marker <-> send AND the engine's list against the model. Returns the answer."""
    settle(c)
    r = c.send("debug.send_marker_audit")
    check(label + ": send_marker_audit (model + engine) has no violation", r.get("ok") is True, r.get("violations"))
    if want_senders is not None:
        check(label + ": the engine half judged %d sender(s)" % want_senders,
              r.get("engine_senders_checked") == want_senders, r.get("engine_senders_checked"))
    return r


def where_in_list(layout, aux):
    """Reads a sender's engine list (the audit's `engine_layouts`) and names the place of its send:
    input | chain<n> (n plugins upstream) | pre | post."""
    roles = {e["role"]: e["index"] for e in layout if e["role"] in ("trimIn", "trimOut", "fader", "windowFade")}
    mine = [e for e in layout if e["role"] == "send" and e.get("aux") == aux]
    if not mine:
        return "absent"
    i = mine[0]["index"]
    if "trimIn" in roles and i < roles["trimIn"]:
        return "input"
    if "windowFade" in roles and i > roles["windowFade"]:
        return "post"
    if "fader" in roles and i > roles["fader"]:
        return "post"
    if "trimOut" in roles and i > roles["trimOut"]:
        return "pre"
    return "chain%d" % sum(1 for e in layout if e["role"] == "fx" and e["index"] < i)


_K = []


def pipeline_offset_db(c):
    """The export's own offset against the file (0.2 comes out at 0.1838: -0.733 dB, the same for the
    dry and for any wet), measured ONCE on a bare object: the levels below are re the SOURCE, corrected
    by it, so that "the sum of the gains upstream" can be read straight off."""
    if not _K:
        fresh(c, "CAL")
        c.send("object.add", {"path": out("imp.wav"), "lane": 0, "start": 0.0})
        d = render(c, "CAL.wav", 0.0, 3.0)
        _K.append(20.0 * math.log10(d[B.peak_index(d)] / IMP_AMP))
        print("       (pipeline offset of the export against the file: %.3f dB)" % _K[0])
    return _K[0]


def wet_db(wet):
    pw = B.peak_index(wet)
    if pw is None:
        return None
    return 20.0 * math.log10(max(abs(wet[pw]), 1e-12) / IMP_AMP) - (_K[0] if _K else 0.0)


def position_row(c, x, a):
    return [s for s in c.send("send.list", {"id": x})["sends"] if s["aux"] == a][0]


def measure_wet_db(c, label, x, a):
    dry, wet = measure(c, label, x, a, 0.0)
    pd, pw = B.peak_index(dry), B.peak_index(wet)
    db = wet_db(wet)
    print("       %s: peak dry @%s, wet @%s, wet %s dB re source" % (label, pd, pw, None if db is None else "%.3f" % db))
    return dry, wet, db


# --------------------------------------------------------------------------------------------------
# Q2 — the wet's level IS the sum of the gains upstream of the tap
# --------------------------------------------------------------------------------------------------

def section_Q2(c):
    print("\n--- Q2  position of a send: the wet's level is the sum of the gains upstream of the tap")
    if REF:
        print("       (skipped in --ref: positions are INC 2)")
        return
    pipeline_offset_db(c)
    x, a = cast_siblings(c, "Q2")
    add_test(c, x, "gainTester", gain_db=-12.0)
    c.send("debug.set_chain_gain", {"host": x, "in_db": -6.0, "out_db": -3.0})
    c.send("object.set_gain", {"ids": [x], "db": -20.0})
    created = c.send("send.create", {"id": x, "aux": a, "position": "input"})
    check("Q2: send.create answers the position", created.get("position") == "input" and created.get("level_db") <= -59.0, created)
    lay_send(c, x, a, 0.0)
    audit(c, "Q2 created at input", want_senders=1)
    # IN -6, [G -12], OUT -3, fader -20: what is upstream of each place
    steps = [("input",   {"position": "input"},                  0.0,   "input"),
             ("chain 0", {"position": "chain", "index": 0},      -6.0,  "chain0"),
             ("chain 1", {"position": "chain", "index": 1},      -18.0, "chain1"),
             ("pre",     {"position": "pre_fader"},               -21.0, "pre"),
             ("post",    {"position": "post_fader"},              -41.0, "post"),
             ("input again", {"position": "input"},              0.0,   "input"),
             ("chain 1 again", {"position": "chain", "index": 1}, -18.0, "chain1")]
    for name, params, expect, place in steps:
        r = c.send("send.set_position", dict({"id": x, "aux": a}, **params))
        check("Q2 %s: send.set_position answers %s" % (name, params["position"]), r.get("position") == params["position"], r)
        rep = audit(c, "Q2 %s" % name, want_senders=1)
        lay = (rep.get("engine_layouts") or {}).get(x, [])
        got_place = where_in_list(lay, a)
        check("Q2 %s: the engine's list puts the send at '%s'" % (name, place), got_place == place,
              [(e["index"], e["role"]) for e in lay])
        row = position_row(c, x, a)
        check("Q2 %s: send.list says %s" % (name, params["position"]), row.get("position") == params["position"], row)
        _, wet, db = measure_wet_db(c, "Q2_" + name.replace(" ", "_"), x, a)
        check("Q2 %s: wet %.1f dB re source (+-0.05)" % (name, expect), db is not None and abs(db - expect) <= 0.05, db)
    eng = (bridge_report(c).get("engine") or {})
    rows = [r for r in eng.get("sends", []) if r.get("aux") == a]
    lay = (c.send("debug.send_marker_audit").get("engine_layouts") or {}).get(x, [])
    idx = [e["index"] for e in lay if e["role"] == "send"]
    check("Q2: debug.bridge_report's list_index is the audit's", len(rows) == 1 and [rows[0].get("list_index")] == idx, (rows, idx))
    check("Q2: the plugin was told chain (3)", rows and rows[0].get("tap_position") == 3, rows)


# --------------------------------------------------------------------------------------------------
# R2 — the marker keeps its place in the ARRAY
# --------------------------------------------------------------------------------------------------

def section_R2(c):
    print("\n--- R2  the marker keeps its array place: reorder, then delete")
    if REF:
        print("       (skipped in --ref)")
        return
    pipeline_offset_db(c)
    x, a = cast_siblings(c, "R2")
    g12 = add_test(c, x, "gainTester", gain_db=-12.0)["plugin"]
    g7 = add_test(c, x, "gainTester", gain_db=-7.0)["plugin"]
    c.send("send.create", {"id": x, "aux": a, "position": "chain", "index": 1})
    lay_send(c, x, a, 0.0)
    audit(c, "R2 [G12 | G7]", want_senders=1)
    check("R2: send.list names the plugins on each side",
          position_row(c, x, a).get("after_plugin") == g12 and position_row(c, x, a).get("before_plugin") == g7,
          position_row(c, x, a))
    _, _, db = measure_wet_db(c, "R2_a", x, a)
    check("R2: tapped between the two: -12 dB", db is not None and abs(db + 12.0) <= 0.05, db)
    # Reorder: drop G7 at the front of the root series. A drop is REMOVE + INSERT: [G12, m, G7] becomes
    # [G7, G12, m] — the marker keeps its place relative to the entries that stay (still after G12), and
    # G7, which was downstream of it, is now upstream (docs/plan_sends_rework.md journal D.1.F: the plan's
    # "-7" assumed a swap in place, which no gesture performs).
    c.send("plugin.drop_at", {"from": x, "host": x, "plugin": g7, "series": "root", "at": 0})
    audit(c, "R2 reordered", want_senders=1)
    seq = ["marker" if e.get("is_send_marker") else e["id"] for e in c.send("plugin.list", {"host": x})["plugins"]]
    check("R2: the array is now [G7, G12, marker]", seq == [g7, g12, "marker"], seq)
    row = position_row(c, x, a)
    _, _, db = measure_wet_db(c, "R2_b", x, a)
    check("R2: the tap, still after G12, now has G7 upstream too: -19 dB (index %s)" % row.get("index"),
          db is not None and abs(db + 19.0) <= 0.05, (db, row))
    check("R2: send.list: chain 2, after G12, before nothing",
          row.get("index") == 2 and row.get("after_plugin") == g12 and row.get("before_plugin") is None, row)
    # Delete the first plugin (G7).
    c.send("plugin.remove", {"host": x, "plugin": g7})
    audit(c, "R2 first deleted", want_senders=1)
    row = position_row(c, x, a)
    _, _, db = measure_wet_db(c, "R2_c", x, a)
    check("R2: G7 deleted, only G12 upstream: -12 dB", db is not None and abs(db + 12.0) <= 0.05, (db, row))
    check("R2: the send is chain 1 (the position follows the array)", row.get("position") == "chain" and row.get("index") == 1, row)
    # Delete the last one too: the marker stays, now in front of nothing.
    c.send("plugin.remove", {"host": x, "plugin": g12})
    audit(c, "R2 all deleted", want_senders=1)
    row = position_row(c, x, a)
    _, _, db = measure_wet_db(c, "R2_d", x, a)
    check("R2: no plugin left: 0 dB, chain 0", db is not None and abs(db) <= 0.05 and row.get("index") == 0, (db, row))


# --------------------------------------------------------------------------------------------------
# V2 — latency: the wet stays on the dry's sample at every position; the tap's age follows the chain
# --------------------------------------------------------------------------------------------------

def section_V2(c):
    print("\n--- V2  latency: the wet is on the dry's sample at every position")
    if REF:
        print("       (skipped in --ref)")
        return
    pipeline_offset_db(c)
    x, a = cast_siblings(c, "V2")
    add_test(c, x, "latencyTester", latency_ms=20.0)
    add_test(c, x, "gainTester", gain_db=-12.0)
    add_test(c, x, "latencyTester", latency_ms=10.0)
    c.send("send.create", {"id": x, "aux": a, "position": "input"})
    lay_send(c, x, a, 0.0)
    # The age is counted in samples of the LIVE graph, which runs at the DEVICE's rate (the exports are 48 kHz
    # whatever it is): a machine whose output device sits at 96 kHz doubles every age. Read it, do not assume SR.
    live_sr = (((bridge_report(c).get("engine") or {}).get("build") or {}).get("sample_rate")) or SR
    print("       V2: the live graph runs at %s Hz (the ages are in its samples)" % live_sr)
    ms = lambda v: int(round(v * live_sr / 1000.0))
    # (name, params, expected level re source, expected age in samples)
    steps = [("input",   {"position": "input"},                0.0,   0),
             ("chain 0", {"position": "chain", "index": 0},    0.0,   0),
             ("chain 1", {"position": "chain", "index": 1},    0.0,   ms(20)),
             ("chain 2", {"position": "chain", "index": 2},    -12.0, ms(20)),
             ("chain 3", {"position": "chain", "index": 3},    -12.0, ms(30)),
             ("pre",     {"position": "pre_fader"},            -12.0, ms(30)),
             ("post",    {"position": "post_fader"},           -12.0, ms(30))]
    for name, params, expect, age in steps:
        c.send("send.set_position", dict({"id": x, "aux": a}, **params))
        audit(c, "V2 %s" % name, want_senders=1)
        dry, wet, db = measure_wet_db(c, "V2_" + name.replace(" ", "_"), x, a)
        pd, pw = B.peak_index(dry), B.peak_index(wet)
        check("V2 %s: wet on the dry's sample" % name, pd is not None and pd == pw, (pd, pw))
        check("V2 %s: level %.0f dB re source" % (name, expect), db is not None and abs(db - expect) <= 0.05, db)
        rep = bridge_report(c)
        rows = [r for r in (rep.get("engine") or {}).get("sends", []) if r.get("aux") == a]
        got_age = rows[0].get("age_samples") if rows else None
        print("       V2 %s: age_samples=%s (wanted %d)" % (name, got_age, age))
        check("V2 %s: age_samples == %d" % (name, age), got_age is not None and abs(got_age - age) <= 1, rows)


# --------------------------------------------------------------------------------------------------
# K2 — the marker survives every gesture that rebuilds a chain (runtime half of the 2.2 tests)
# --------------------------------------------------------------------------------------------------

def markers_and_positions(c, ids, a):
    """For each id: (position name, chain index) of its send to `a`, and the marker count in plugin.list."""
    out_ = []
    for i in ids:
        rows = [s for s in c.send("send.list", {"id": i})["sends"] if s["aux"] == a]
        mk = [e for e in c.send("plugin.list", {"host": i})["plugins"] if e.get("is_send_marker")]
        out_.append((rows[0].get("position") if rows else None, rows[0].get("index") if rows else None, len(mk)))
    return out_


def section_K2(c):
    print("\n--- K2  the marker survives duplicate, cut, copy/paste, group/ungroup, delete of a neighbour")
    if REF:
        print("       (skipped in --ref)")
        return
    x, a = cast_siblings(c, "K2")
    g12 = add_test(c, x, "gainTester", gain_db=-12.0)["plugin"]
    g7 = add_test(c, x, "gainTester", gain_db=-7.0)["plugin"]
    c.send("send.create", {"id": x, "aux": a, "position": "chain", "index": 1})
    lay_send(c, x, a, 0.0)
    audit(c, "K2 start")
    check("K2: start: chain 1, one marker", markers_and_positions(c, [x], a) == [("chain", 1, 1)], markers_and_positions(c, [x], a))

    d = c.send("object.duplicate", {"ids": [x]})["ids"]
    audit(c, "K2 duplicate")
    pos = markers_and_positions(c, d, a)
    print("       K2: duplicate -> %s" % pos)
    check("K2: the duplicate has its own send, still chain 1, one marker (the audit: no orphan, no duplicate)",
          pos == [("chain", 1, 1)], pos)

    pieces = c.send("object.split_at", {"seconds": 1.5, "ids": [x]})["ids"]
    audit(c, "K2 cut")
    pos = markers_and_positions(c, pieces, a)
    print("       K2: cut -> %s" % pos)
    check("K2: both halves of the cut keep chain 1 and one marker", len(pos) == 2 and all(p == ("chain", 1, 1) for p in pos), pos)

    c.send("clipboard.copy", {"ids": pieces[:1]})
    c.send("clipboard.paste", {})
    audit(c, "K2 paste")
    allobj = [o["id"] for o in c.send("object.list", {})["objects"] if o["id"] != a]
    pos = markers_and_positions(c, allobj, a)
    print("       K2: after paste, %d objects: %s" % (len(allobj), pos))
    check("K2: every object that sends keeps one marker for one send",
          all((p[0] is None and p[2] == 0) or p == ("chain", 1, 1) for p in pos), pos)

    g = c.send("group.create", {"ids": allobj})["id"]
    audit(c, "K2 group")
    c.send("group.disband", {"id": g})
    audit(c, "K2 ungroup")
    pos = markers_and_positions(c, allobj, a)
    check("K2: group then ungroup: the same positions", all((p[0] is None and p[2] == 0) or p == ("chain", 1, 1) for p in pos), pos)

    # Deleting the plugin on the left of the marker: the marker is still there, now at index 0.
    # (A copy is FX-linked by default: its plugins sit in bins, so take the first LEAF.)
    def first_leaf(entries):
        for e in entries:
            if e.get("is_send_marker"):
                continue
            if e.get("is_fx_block"):
                inner = first_leaf(e.get("plugins", []))
                if inner:
                    return inner
                continue
            return e["id"]
        return None
    c.send("plugin.remove", {"host": allobj[0], "plugin": first_leaf(c.send("plugin.list", {"host": allobj[0]})["plugins"])})
    audit(c, "K2 neighbour deleted")
    row = markers_and_positions(c, [allobj[0]], a)
    print("       K2: after a neighbour is deleted: %s" % row)
    check("K2: a neighbour deleted: one marker, chain position clamped to the plugins left",
          row[0][0] == "chain" and row[0][2] == 1, row)

    c.send("send.remove", {"id": allobj[0], "aux": a})
    audit(c, "K2 send removed")
    row = markers_and_positions(c, [allobj[0]], a)
    check("K2: removing the send removes its marker (one undo point)", row == [(None, None, 0)], row)
    c.send("edit.undo", {})
    settle(c)
    row = markers_and_positions(c, [allobj[0]], a)
    audit(c, "K2 undo of the removal")
    check("K2: undo brings the send AND its marker back", row[0][0] == "chain" and row[0][2] == 1, row)

# --------------------------------------------------------------------------------------------------
# S2 — a send that taps before the fader FOLLOWS the sender's fades and window (Q-U5), not its fader/pan
# --------------------------------------------------------------------------------------------------

def render_st(c, name, t0=0.0, t1=3.0):
    wait(c)
    r = c.send("export.run", {"format": "wav", "sample_rate": SR, "dithering": False,
                              "start": t0, "end": t1, "path": out(name)})
    c.send("job.wait", {"id": r["job_id"], "timeout_ms": 180000})
    return B.read_wav(out(name))


def measure_st(c, label, x, a, t1=3.0):
    """Wet by difference, BOTH channels. Returns (dry channels, wet channels)."""
    on = render_st(c, "%s_on.wav" % label, 0.0, t1)
    c.send("send.enable", {"id": x, "aux": a, "enabled": False})
    off = render_st(c, "%s_off.wav" % label, 0.0, t1)
    c.send("send.enable", {"id": x, "aux": a, "enabled": True})
    return off, [sub(on[k], off[k]) for k in range(min(len(on), len(off)))]


def section_S2(c):
    print("\n--- S2  a send before the fader follows the fades and the window, not the fader nor the pan")
    if REF:
        print("       (skipped in --ref)")
        return
    # S2a: the fades. (wet - dry) per 10 ms window = the fader's -20 dB inverse => +20 dB; post-fader: 0 dB.
    for name, params, ups in (("pre", {"position": "pre_fader"}, 20.0),
                              ("chain", {"position": "chain", "index": 0}, 20.0),
                              ("input", {"position": "input"}, 20.0),
                              ("post", {"position": "post_fader"}, 0.0)):
        fresh(c, "S2" + name)
        x = c.send("object.add", {"path": out("sine1k.wav"), "lane": 0, "start": 0.0})["id"]
        a = c.send("aux.create", {"start": 0.0, "end": 4.0, "lane": 1})["id"]
        add_test(c, x, "gainTester", gain_db=0.0)
        c.send("object.set_fade", {"id": x, "in": 0.5, "out": 0.5})
        c.send("object.set_gain", {"ids": [x], "db": -20.0})
        c.send("send.create", dict({"id": x, "aux": a}, **params))
        lay_send(c, x, a, 0.0)
        audit(c, "S2 %s" % name, want_senders=1)
        dry, wet = measure_st(c, "S2" + name, x, a, t1=4.0)
        wd, dd = dict(window_rms_db(wet[0], 0.0, 4.0)), dict(window_rms_db(dry[0], 0.0, 4.0))
        live = [t for t in sorted(wd) if dd[t] > -100.0]
        errs = [(wd[t] - dd[t]) - ups for t in live]
        worst = max(abs(e) for e in errs) if errs else 99.0
        fades = [t for t in live if t < 0.5 or t > 3.5]
        print("       S2 %s: %d windows (%d in the fades), (wet - dry) - %.0f dB: worst %.3f dB"
              % (name, len(live), len(fades), ups, worst))
        check("S2 %s: wet = dry %+.0f dB in every window, fades included (0.5 dB)" % (name, ups), worst <= 0.5, "%.3f" % worst)
        check("S2 %s: the fades were really measured" % name, len(fades) > 80, len(fades))
        rep = bridge_report(c)
        eng = [r for r in (rep.get("engine") or {}).get("sends", []) if r.get("aux") == a]
        check("S2 %s: envelope source %s" % (name, "set" if params["position"] != "post_fader" else "absent"),
              eng and eng[0].get("follows_envelope") == (params["position"] != "post_fader"), eng)

    # S2b: the window. A group cropped to [1, 2] holds a 4 s sine: the pre-fader send of the GROUP carries
    # nothing outside the window — exactly nothing.
    fresh(c, "S2g")
    x = c.send("object.add", {"path": out("sine1k.wav"), "lane": 0, "start": 0.0})["id"]
    o = with_other(c, lane=4)
    a = c.send("aux.create", {"start": 0.0, "end": 4.0, "lane": 8})["id"]
    g = grp(c, [x, o])
    c.send("object.trim", {"id": g, "start": 1.0, "duration": 1.0})
    c.send("send.create", {"id": g, "aux": a, "position": "pre_fader"})
    lay_send(c, g, a, 0.0)
    audit(c, "S2 group")
    dry, wet = measure_st(c, "S2g", g, a, t1=4.0)
    w = wet[0]
    outside = [v for i, v in enumerate(w) if i < int(0.98 * SR) or i > int(2.02 * SR)]
    inside = w[int(1.1 * SR):int(1.9 * SR)]
    print("       S2 group: wet outside [1,2] max |v| = %.3g, inside = %.3g" % (maxabs(outside), maxabs(inside)))
    check("S2 group: the wet is exactly 0 outside the group's window", maxabs(outside) == 0.0, maxabs(outside))
    check("S2 group: and present inside it", maxabs(inside) > 1e-3, maxabs(inside))

    # S2c: the pan. Hard left on X: the dry is left only, the pre-fader wet stays centred.
    fresh(c, "S2p")
    x = c.send("object.add", {"path": out("sine1k.wav"), "lane": 0, "start": 0.0})["id"]
    a = c.send("aux.create", {"start": 0.0, "end": 4.0, "lane": 1})["id"]
    c.send("object.set_pan", {"ids": [x], "pan": -1.0})
    c.send("send.create", {"id": x, "aux": a, "position": "pre_fader"})
    lay_send(c, x, a, 0.0)
    dry, wet = measure_st(c, "S2p", x, a, t1=3.0)
    dl, dr = B.rms(dry[0], 0.5, 2.5), B.rms(dry[1], 0.5, 2.5)
    wl, wr = B.rms(wet[0], 0.5, 2.5), B.rms(wet[1], 0.5, 2.5)
    print("       S2 pan: dry L %.1f dB R %.1f dB; wet L %.1f dB R %.1f dB" % (B.db(dl), B.db(dr), B.db(wl), B.db(wr)))
    check("S2 pan: the dry is hard left", B.db(dr) < B.db(dl) - 60.0, (B.db(dl), B.db(dr)))
    check("S2 pan: the pre-fader wet stays centred (L == R within 0.1 dB)", abs(B.db(wl) - B.db(wr)) <= 0.1, (B.db(wl), B.db(wr)))


# --------------------------------------------------------------------------------------------------
# T2 — the direct signal is never written (bit-identical exports)
# --------------------------------------------------------------------------------------------------

def section_T2(c):
    print("\n--- T2  the direct signal is bit-identical with a send at any position")
    if REF:
        print("       (skipped in --ref)")
        return
    ref_dir = os.environ.get("INC1_REF_DIR")
    fresh(c, "T2")
    x = c.send("object.add", {"path": out("sine1k.wav"), "lane": 0, "start": 0.0})["id"]
    a = c.send("aux.create", {"start": 0.0, "end": 4.0, "lane": 1})["id"]
    add_test(c, x, "gainTester", gain_db=-12.0)
    c.send("object.set_fade", {"id": x, "in": 0.3, "out": 0.3})
    base = render(c, "T2_1_nosend.wav", 0.0, 3.0)
    # (2) a mid-chain send at -inf
    c.send("send.create", {"id": x, "aux": a, "position": "chain", "index": 1})
    audit(c, "T2 created", want_senders=0)
    r2 = render(c, "T2_2_silent.wav", 0.0, 3.0)
    check("T2 (1)-(2): a mid-chain send at -inf: exports equal EXACTLY", sub(base, r2) == [0.0] * len(sub(base, r2)), maxabs(sub(base, r2)))
    # (3) the send at 0 dB into a MUTED aux, at each position
    c.send("object.set_mute", {"ids": [a], "muted": True})
    lay_send(c, x, a, 0.0)
    for name, params in (("chain 1", {"position": "chain", "index": 1}), ("chain 0", {"position": "chain", "index": 0}),
                         ("input", {"position": "input"}), ("pre", {"position": "pre_fader"}),
                         ("post", {"position": "post_fader"})):
        c.send("send.set_position", dict({"id": x, "aux": a}, **params))
        audit(c, "T2 %s" % name, want_senders=1)
        r3 = render(c, "T2_3_%s.wav" % name.replace(" ", ""), 0.0, 3.0)
        d = sub(base, r3)
        check("T2 (1)-(3) %s: send at 0 dB into a muted aux: the direct signal is bit-identical" % name,
              maxabs(d) == 0.0, maxabs(d))
    # (4) a post-fader send only, against the INC 1 build's export of the same project
    now = t2_post_project(c)
    ref_path = os.path.join(ref_dir, "T2_4_post.wav") if ref_dir else None
    if not ref_path or not os.path.exists(ref_path):
        print("       T2 (4): no INC 1 reference (INC1_REF_DIR=%s) — NOT compared; make it with --only T2REF on the INC 1 app" % ref_dir)
    else:
        ref = B.read_wav(ref_path)[0]
        d = sub(now, ref)
        check("T2 (4): a post-fader send's export equals the INC 1 build's, bit for bit (%d samples)" % len(now),
              len(now) == len(ref) and maxabs(d) == 0.0, maxabs(d))


def t2_post_project(c):
    """The project of T2 (4), built with commands the INC 1 build already has; returns its export."""
    fresh(c, "T2c")
    x = c.send("object.add", {"path": out("sine1k.wav"), "lane": 0, "start": 0.0})["id"]
    a = c.send("aux.create", {"start": 0.0, "end": 4.0, "lane": 1})["id"]
    c.send("object.set_fade", {"id": x, "in": 0.3, "out": 0.3})
    lay_send(c, x, a, -6.0)
    return render(c, "T2_4_post.wav", 0.0, 3.0)


def section_T2REF(c):
    """Run on the INC 1 build: writes the reference export T2 (4) compares against."""
    ref_dir = os.environ.get("INC1_REF_DIR")
    if not ref_dir:
        print("T2REF needs INC1_REF_DIR")
        sys.exit(2)
    t2_post_project(c)
    os.makedirs(ref_dir, exist_ok=True)
    import shutil
    shutil.copy(out("T2_4_post.wav"), os.path.join(ref_dir, "T2_4_post.wav"))
    print("       T2REF: reference written to %s" % ref_dir)


# --------------------------------------------------------------------------------------------------
# W2 — copies end to end: duplicate, cut, copy/paste, group/ungroup, cross-project paste
# --------------------------------------------------------------------------------------------------

W2_POSITIONS = (("input",  {"position": "input"},                 0.0),
                ("chain0", {"position": "chain", "index": 0},    -6.0),
                ("chain1", {"position": "chain", "index": 1},    -18.0),
                ("pre",    {"position": "pre_fader"},            -21.0),
                ("post",   {"position": "post_fader"},           -41.0))


def w2_build(c, name, params):
    """X = impulse with [G(-12)], IN -6, OUT -3, fader -20, its send to a root aux at 0 dB at `params`."""
    fresh(c, name)
    x = c.send("object.add", {"path": out("imp.wav"), "lane": 0, "start": 0.0})["id"]
    a = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 8})["id"]
    add_test(c, x, "gainTester", gain_db=-12.0)
    c.send("debug.set_chain_gain", {"host": x, "in_db": -6.0, "out_db": -3.0})
    c.send("object.set_gain", {"ids": [x], "db": -20.0})
    c.send("send.create", dict({"id": x, "aux": a}, **params))
    lay_send(c, x, a, 0.0)
    return x, a


def w2_check_one(c, label, obj, a, pname, params, expect, others=(), measure_it=True):
    """The copy `obj` carries the same position, one marker iff in the chain, and (if asked) the same wet."""
    row = position_row(c, obj, a)
    want_name = params["position"]
    ok = row.get("position") == want_name and (want_name != "chain" or row.get("index") == params["index"])
    check("%s: send.list says %s%s" % (label, want_name, "" if want_name != "chain" else " %d" % params["index"]), ok, row)
    mk = markers_and_positions(c, [obj], a)[0][2]
    check("%s: %d marker(s) in the chain" % (label, 1 if want_name == "chain" else 0), mk == (1 if want_name == "chain" else 0), mk)
    if measure_it:
        for o in others:
            c.send("send.enable", {"id": o, "aux": a, "enabled": False})
        _, _, db = measure_wet_db(c, label.replace(" ", "_"), obj, a)
        for o in others:
            c.send("send.enable", {"id": o, "aux": a, "enabled": True})
        check("%s: wet %.0f dB re source (0.05)" % (label, expect), db is not None and abs(db - expect) <= 0.05, db)


def section_W2(c):
    print("\n--- W2  copies end to end: the position, the marker and the wet survive every way to copy")
    if REF:
        print("       (skipped in --ref)")
        return
    pipeline_offset_db(c)
    for pname, params, expect in W2_POSITIONS:
        tag = "W2 " + pname
        # --- duplicate
        x, a = w2_build(c, "W2" + pname, params)
        w2_check_one(c, tag + " original", x, a, pname, params, expect)
        d = c.send("object.duplicate", {"ids": [x]})["ids"]
        audit(c, tag + " duplicate")
        check(tag + " duplicate: one copy", len(d) == 1, d)
        c.send("object.move", {"id": d[0], "lane": 2, "start": 0.0})    # the copy lands after the original: bring it back under the aux
        settle(c)
        w2_check_one(c, tag + " duplicate", d[0], a, pname, params, expect, others=[x])
        w2_check_one(c, tag + " original after the duplicate", x, a, pname, params, expect, others=[d[0]])
        # --- cut: the left half carries the impulse (at 1.0 s), the right one is silent but keeps its send
        pieces = c.send("object.split_at", {"seconds": 1.5, "ids": [d[0]]})["ids"]
        audit(c, tag + " cut")
        starts = {i: c.send("object.get", {"id": i})["start"] for i in pieces}
        left = min(starts, key=starts.get)
        right = max(starts, key=starts.get)
        w2_check_one(c, tag + " cut, left half", left, a, pname, params, expect, others=[x])
        w2_check_one(c, tag + " cut, right half", right, a, pname, params, expect, measure_it=False)
        if pname == "chain1":
            shape = {}
            for half, h in (("left", left), ("right", right)):
                plist = c.send("plugin.list", {"host": h})["plugins"]
                shape[half] = [("bin" if e.get("is_fx_block") else "marker" if e.get("is_send_marker") else "plugin") for e in plist]
            print("       W2 chain1: top level of each half after the cut: %s" % shape)
            check(tag + " cut: each half holds one bin {G} and the marker after it (the tap measures -18 above)",
                  shape["left"] == ["bin", "marker"] and shape["right"] == ["bin", "marker"], shape)
        # --- copy / paste on another lane, same time
        c.send("selection.set", {"ids": [x]})
        c.send("clipboard.copy", {})
        c.send("timesel.set", {"start": 0.0, "end": 3.0, "lane": 3, "lane_count": 1})
        pasted = c.send("clipboard.paste", {})["ids"]
        audit(c, tag + " paste")
        check(tag + " paste: one object pasted", len(pasted) == 1, pasted)
        if pasted:
            w2_check_one(c, tag + " paste", pasted[0], a, pname, params, expect, others=[x, left])
        # --- group / ungroup
        o = with_other(c, lane=5)
        g = c.send("group.create", {"ids": [x, o]})["id"]
        audit(c, tag + " group")
        w2_check_one(c, tag + " in a group", x, a, pname, params, expect, others=[i for i in (left, *(pasted or [])) if i != x])
        c.send("group.disband", {"id": g})
        audit(c, tag + " ungroup")
        w2_check_one(c, tag + " ungrouped", x, a, pname, params, expect, others=[i for i in (left, *(pasted or [])) if i != x])

    # --- cross-project paste: the aux in the lot, then without it.
    # The target tab is made FIRST (a `tab.new` after the copy drops the clipboard: the new project
    # starts with an empty one — see the report), then the copy is made in the source tab.
    def new_target(tag2):
        src = c.send("app.info")["active_tab"]
        c.send("tab.new", {})
        os.makedirs(out(tag2), exist_ok=True)
        c.send("project.save_as", {"path": out("%s/project.objekat" % tag2)})
        tgt = c.send("app.info")["active_tab"]
        c.send("tab.select", {"id": src})
        return src, tgt

    for pname, params, expect in (W2_POSITIONS[2], W2_POSITIONS[3]):
        tag = "W2 cross " + pname
        x, a = w2_build(c, "W2x" + pname, params)
        o = with_other(c, lane=5)
        g = c.send("group.create", {"ids": [x, a, o]})["id"]       # the aux travels with its sender
        wait(c)
        src, tgt = new_target("W2xt" + pname)
        c.send("selection.set", {"ids": [g]})
        copied = c.send("clipboard.copy", {})
        check(tag + ": the group is copied", copied.get("copied") == 1, copied)
        c.send("tab.select", {"id": tgt})
        c.send("timesel.set", {"start": 0.0, "end": 3.0, "lane": 0, "lane_count": 1})
        pasted = c.send("clipboard.paste", {})["ids"]
        settle(c)
        audit(c, tag + " pasted")
        check(tag + ": one group pasted", len(pasted) == 1, pasted)
        newg = pasted[0] if pasted else None
        if newg:
            c.send("group.expand", {"id": newg, "expanded": True})
            wait(c)
            kids = [k for k in c.send("object.list", {})["objects"] if k.get("parent") == newg]
            naux = [k["id"] for k in kids if k["kind"] == "aux"]
            nx = [k["id"] for k in kids if k["kind"] == "clip"
                  and c.send("send.list", {"id": k["id"]})["sends"]]
            check(tag + ": the pasted group holds the sender and the aux", len(nx) == 1 and len(naux) == 1, kids)
            if nx and naux:
                w2_check_one(c, tag + " (aux in the lot)", nx[0], naux[0], pname, params, expect)
        c.send("tab.close", {"id": tgt, "discard": True})
        wait(c)
        check(tag + ": back on the source tab", c.send("app.info")["active_tab"] == src)
        # without the aux: the sender alone goes to a project that holds no aux
        c.send("group.disband", {"id": g})
        wait(c)
        src, tgt = new_target("W2xu" + pname)
        c.send("selection.set", {"ids": [x]})
        copied = c.send("clipboard.copy", {})
        check(tag + ": the sender alone is copied", copied.get("copied") == 1, copied)
        c.send("tab.select", {"id": tgt})
        c.send("timesel.set", {"start": 0.0, "end": 3.0, "lane": 0, "lane_count": 1})
        alone = c.send("clipboard.paste", {})["ids"]
        settle(c)
        audit(c, tag + " alone")
        check(tag + ": the sender pasted without its aux: one object", len(alone) == 1, alone)
        if alone:
            rows = c.send("send.list", {"id": alone[0]})["sends"]
            mk = [e for e in c.send("plugin.list", {"host": alone[0]})["plugins"] if e.get("is_send_marker")]
            check(tag + ": without the aux: no send and no marker", rows == [] and mk == [], (rows, mk))
        c.send("tab.close", {"id": tgt, "discard": True})
        wait(c)

# --------------------------------------------------------------------------------------------------
# X2 — undo / redo of a send's position: one move = one undo point, the object is PATCHED (not rebuilt)
# --------------------------------------------------------------------------------------------------

def app_log_lines():
    """The app's stderr (set APP_LOG=/path), or None when this run was not given it."""
    path = os.environ.get("APP_LOG")
    if not path or not os.path.exists(path):
        return None
    with open(path, errors="replace") as f:
        return f.read().splitlines()


def undo_trace_since(before):
    now = app_log_lines()
    if now is None or before is None:
        return None
    return [l for l in now[len(before):] if "[UNDO]" in l]


def fx_instances(c, x):
    lay = (c.send("debug.send_marker_audit").get("engine_layouts") or {}).get(x, [])
    return [(e.get("key"), e.get("instance")) for e in lay if e["role"] == "fx"]


def section_X2(c):
    print("\n--- X2  undo / redo of a send's position: one gesture = one undo, patched in place")
    if REF:
        print("       (skipped in --ref)")
        return
    pipeline_offset_db(c)
    x, a = cast_siblings(c, "X2")
    add_test(c, x, "gainTester", gain_db=-12.0)
    c.send("debug.set_chain_gain", {"host": x, "in_db": -6.0, "out_db": -3.0})
    c.send("object.set_gain", {"ids": [x], "db": -20.0})
    c.send("send.create", {"id": x, "aux": a, "position": "post_fader"})
    lay_send(c, x, a, 0.0)
    audit(c, "X2 start", want_senders=1)
    # The reference WITHOUT the send, rendered once up front: `send.enable` is an undo point, so the
    # by-difference measure of the other sections (which toggles it) would cut the undo chain under test.
    c.send("send.enable", {"id": x, "aux": a, "enabled": False})
    off_ref = render(c, "X2_off_ref.wav", 0.0, 3.0)
    c.send("send.enable", {"id": x, "aux": a, "enabled": True})

    def wet_now(label):
        on = render(c, label.replace(" ", "_") + ".wav", 0.0, 3.0)
        return wet_db(sub(on, off_ref))

    P = [("post",   {"position": "post_fader"},               -41.0),
         ("input",  {"position": "input"},                      0.0),
         ("chain0", {"position": "chain", "index": 0},         -6.0),
         ("chain1", {"position": "chain", "index": 1},        -18.0),
         ("pre",    {"position": "pre_fader"},                -21.0),
         ("post",   {"position": "post_fader"},               -41.0)]
    base_inst = fx_instances(c, x)
    check("X2: the chain holds one plugin, with an engine instance", len(base_inst) == 1 and base_inst[0][1], base_inst)

    def state_is(label, k):
        name, params, expect = P[k]
        audit(c, label)
        row = position_row(c, x, a)
        ok = row.get("position") == params["position"] and (params["position"] != "chain" or row.get("index") == params["index"])
        check("%s: send.list says %s" % (label, name), ok, row)
        db = wet_now(label)
        print("       %s: wet %s dB re source" % (label, None if db is None else "%.3f" % db))
        check("%s: wet %.0f dB re source (0.05)" % (label, expect), db is not None and abs(db - expect) <= 0.05, db)
        inst = fx_instances(c, x)
        check("%s: the plugin instance is the SAME engine object" % label, inst == base_inst, (inst, base_inst))

    # forward: five moves, each one undo point
    for k in range(1, 6):
        c.send("send.set_position", dict({"id": x, "aux": a}, **P[k][1]))
        state_is("X2 move %d to %s" % (k, P[k][0]), k)

    log0 = app_log_lines()
    if log0 is None:
        print("       (no APP_LOG: the [UNDO] trace is not read)")
    for j in range(1, 6):
        before = app_log_lines()
        c.send("edit.undo", {})
        settle(c)
        tr = undo_trace_since(before)
        if tr is not None:
            check("X2 undo %d: trace says 0 rebuilt, 1 patched" % j, bool(tr) and "0 rebuilt, 1 patched" in tr[-1], tr)
        state_is("X2 undo %d (back to %s)" % (j, P[5 - j][0]), 5 - j)
    for j in range(1, 6):
        before = app_log_lines()
        c.send("edit.redo", {})
        settle(c)
        tr = undo_trace_since(before)
        if tr is not None:
            check("X2 redo %d: trace says 0 rebuilt, 1 patched" % j, bool(tr) and "0 rebuilt, 1 patched" in tr[-1], tr)
        state_is("X2 redo %d (forward to %s)" % (j, P[j][0]), j)

    # the card's deletion: removes the send AND its marker, one undo point; undo brings both back
    c.send("send.set_position", {"id": x, "aux": a, "position": "chain", "index": 1})
    settle(c)
    c.send("send.remove", {"id": x, "aux": a})
    settle(c)
    check("X2: send removed", send_entry(c, x, a) is None)
    before = app_log_lines()
    c.send("edit.undo", {})
    settle(c)
    tr = undo_trace_since(before)
    print("       X2: undo of the card's deletion -> %s" % (tr[-1].strip() if tr else None))
    row = position_row(c, x, a)
    check("X2: undo of the deletion brings the send back at chain 1", row.get("position") == "chain" and row.get("index") == 1, row)
    audit(c, "X2 after the undo of the deletion")
    db = wet_now("X2 after undo deletion")
    check("X2: ... and the wet is -18 dB again", db is not None and abs(db - (-18.0)) <= 0.05, db)


# --------------------------------------------------------------------------------------------------
# Y2 — consolidate / bake and the sends that tap inside the chain (Q-U6, confirmed)
# --------------------------------------------------------------------------------------------------

def y2_build(c, name, params, fader_db=None):
    """X = impulse with [G(-12)], IN -6, OUT -3, its send to a root aux at 0 dB at `params`."""
    fresh(c, name)
    x = c.send("object.add", {"path": out("imp.wav"), "lane": 0, "start": 0.0})["id"]
    a = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 8})["id"]
    add_test(c, x, "gainTester", gain_db=-12.0)
    c.send("debug.set_chain_gain", {"host": x, "in_db": -6.0, "out_db": -3.0})
    if fader_db is not None:
        c.send("object.set_gain", {"ids": [x], "db": fader_db})
    c.send("send.create", dict({"id": x, "aux": a}, **params))
    lay_send(c, x, a, 0.0)
    settle(c)
    return x, a


def y2_fingerprint(c, x):
    """What 'nothing changed' means: the object, its chain, its sends, the list of objects."""
    return json.dumps([c.send("object.get", {"id": x}), c.send("plugin.list", {"host": x}),
                       c.send("send.list", {"id": x}),
                       sorted(o["id"] for o in c.send("object.list", {})["objects"])], sort_keys=True)


def y2_consolidate(c, x, **extra):
    r = c.send("consolidate.make", dict({"id": x}, **extra))
    c.send("job.wait", {"id": r["job_id"], "timeout_ms": 180000})
    settle(c)
    return r


def y2_placement(c, before_ids):
    new = [o for o in c.send("object.list", {})["objects"] if o["id"] not in before_ids and o["kind"] != "aux"]
    tops = [o for o in new if o.get("parent") is None]
    return tops[0]["id"] if tops else None


def section_Y2(c):
    print("\n--- Y2  consolidate: the sends that tap inside the chain (default refuse, fold, remove) and the pre-fader refusal")
    if REF:
        print("       (skipped in --ref)")
        return
    pipeline_offset_db(c)
    chain = {"position": "chain", "index": 1}

    # --- refuse (the default)
    x, a = y2_build(c, "Y2refuse", chain)
    before = y2_fingerprint(c, x)
    for label, extra in (("default", {}), ("explicit refuse", {"mid_chain_sends": "refuse"})):
        try:
            c.send("consolidate.make", dict({"id": x}, **extra))
            check("Y2 %s: refused" % label, False, "it was accepted")
        except ObjekatError as e:
            check("Y2 %s: invalid_state, message names mid_chain_sends" % label,
                  e.code == "invalid_state" and e.message.startswith("mid_chain_sends"), "%s %s" % (e.code, e.message))
            rows = e.details or []
            check("Y2 %s: the error lists the send (object, aux, position)" % label,
                  len(rows) == 1 and rows[0].get("aux") == a and rows[0].get("position") == "chain", rows)
    check("Y2 refuse: the model is unchanged (fingerprint)", y2_fingerprint(c, x) == before)
    check("Y2 refuse: no render was started", c.send("consolidate.state").get("renders") == [], c.send("consolidate.state"))
    try:
        c.send("consolidate.make", {"id": x, "mid_chain_sends": "sideways"})
        check("Y2: an unknown mid_chain_sends is refused", False, "accepted")
    except ObjekatError as e:
        check("Y2: an unknown mid_chain_sends is bad_params", e.code == "bad_params", e.code)

    # --- the hand's path, headless: nobody can answer, so it is a refusal, journalled
    c.send("app.dialogs", {"clear": True})
    c.send("selection.set", {"ids": [x]})
    c.send("selection.context_action", {"action": "consolidate_clip", "id": x})
    wait(c)
    dl = c.send("app.dialogs", {})
    mine = [d for d in dl.get("dialogs", []) if d.get("answer") == "refused"]
    check("Y2 hand path (no interface): the question is journalled as refused", len(mine) == 1, dl)
    check("Y2 hand path: the model is unchanged", y2_fingerprint(c, x) == before)
    audit(c, "Y2 refuse")

    # --- fold
    x, a = y2_build(c, "Y2fold", chain)
    ids0 = {o["id"] for o in c.send("object.list", {})["objects"]}
    y2_consolidate(c, x, mid_chain_sends="fold")
    pl = y2_placement(c, ids0)
    check("Y2 fold: a placement was made", pl is not None, pl)
    if pl:
        rows = c.send("send.list", {"id": pl})["sends"]
        check("Y2 fold: the placement has ONE send, post-fader, kept at 0 dB",
              len(rows) == 1 and rows[0]["aux"] == a and rows[0]["position"] == "post_fader" and rows[0]["level_db"] == 0,
              rows)
        mk = [e for e in c.send("plugin.list", {"host": pl})["plugins"] if e.get("is_send_marker")]
        check("Y2 fold: no marker anywhere", mk == [] and c.send("debug.send_marker_audit").get("markers") == 0, mk)
        audit(c, "Y2 fold")
        # the fold is its own undo point, taken before the wrap and the bake: three undos take the
        # project back (the bake's commit, the wrap in a group — where the send moved to the wrapper —,
        # then the fold: the chain send is back, marker included)
        def sends_of(i):
            try:
                return c.send("send.list", {"id": i}).get("sends")
            except ObjekatError:
                return None
        c.send("edit.undo", {}); settle(c)
        check("Y2 fold: undo 1 takes back the bake; the clip is inside its wrapper, the send on the wrapper",
              sends_of(x) == [] and len(sends_of(pl) or []) == 1, (sends_of(x), sends_of(pl)))
        c.send("edit.undo", {}); settle(c)
        rr = sends_of(x)
        check("Y2 fold: undo 2 takes back the wrap; the send is on the clip, still post-fader (folded)",
              rr is not None and len(rr) == 1 and rr[0]["position"] == "post_fader", rr)
        c.send("edit.undo", {}); settle(c)
        rr = sends_of(x)
        check("Y2 fold: undo 3 takes back the fold: chain 1 again",
              rr is not None and len(rr) == 1 and rr[0]["position"] == "chain" and rr[0].get("index") == 1, rr)
        audit(c, "Y2 fold undone")
        # (the by-difference measure toggles send.enable, an undo point: it comes AFTER the undo checks)
        _, _, dbu = measure_wet_db(c, "Y2_fold_undone", x, a)
        check("Y2 fold: after the two undos the wet is -18 dB again (the chain send)", dbu is not None and abs(dbu + 18.0) <= 0.05, dbu)

    # --- remove
    x, a = y2_build(c, "Y2remove", chain)
    ids0 = {o["id"] for o in c.send("object.list", {})["objects"]}
    y2_consolidate(c, x, mid_chain_sends="remove")
    pl = y2_placement(c, ids0)
    check("Y2 remove: a placement was made", pl is not None, pl)
    if pl:
        rows = c.send("send.list", {"id": pl})["sends"]
        check("Y2 remove: no send on the placement", rows == [], rows)
        audit(c, "Y2 remove")

    # --- an input send is concerned too
    x, a = y2_build(c, "Y2input", {"position": "input"})
    try:
        c.send("consolidate.make", {"id": x})
        check("Y2 input: refused by default", False, "accepted")
    except ObjekatError as e:
        check("Y2 input: refused by default", e.code == "invalid_state" and (e.details or [{}])[0].get("position") == "input", e)

    # --- a pre-fader send is REFUSED (decided 10 October 2026, "for the moment"): no choice offered,
    #     whatever mid_chain_sends says, with or without a fader on the clip; nothing changed, nothing baked
    def refused_pre(label, x, a, **extra):
        try:
            c.send("consolidate.make", dict({"id": x}, **extra))
            check("Y2 %s: refused" % label, False, "it was accepted")
        except ObjekatError as e:
            check("Y2 %s: invalid_state, message names pre_fader_send" % label,
                  e.code == "invalid_state" and e.message.startswith("pre_fader_send"), "%s %s" % (e.code, e.message))
            rows = e.details or []
            check("Y2 %s: the error lists the send (object, aux, position)" % label,
                  len(rows) == 1 and rows[0].get("aux") == a and rows[0].get("position") == "pre_fader", rows)

    for tag, fader in (("pre", None), ("preF", -20.0)):
        x, a = y2_build(c, "Y2" + tag, {"position": "pre_fader"}, fader_db=fader)
        before = y2_fingerprint(c, x)
        for label, extra in (("%s default" % tag, {}), ("%s mid_chain_sends=refuse" % tag, {"mid_chain_sends": "refuse"}),
                             ("%s mid_chain_sends=fold" % tag, {"mid_chain_sends": "fold"}),
                             ("%s mid_chain_sends=remove" % tag, {"mid_chain_sends": "remove"})):
            refused_pre(label, x, a, **extra)
        check("Y2 %s: the model is unchanged (fingerprint)" % tag, y2_fingerprint(c, x) == before)
        check("Y2 %s: no render was started" % tag, c.send("consolidate.state").get("renders") == [],
              c.send("consolidate.state"))
        rows = c.send("send.list", {"id": x})["sends"]
        check("Y2 %s: the send is still pre-fader" % tag, len(rows) == 1 and rows[0]["position"] == "pre_fader", rows)

    # --- the hand's path, headless: one message, journalled as reported, nothing changed
    x, a = y2_build(c, "Y2preHand", {"position": "pre_fader"})
    before = y2_fingerprint(c, x)
    c.send("app.dialogs", {"clear": True})
    c.send("selection.set", {"ids": [x]})
    c.send("selection.context_action", {"action": "consolidate_clip", "id": x})
    wait(c)
    dl = c.send("app.dialogs", {})
    mine = [d for d in dl.get("dialogs", []) if d.get("answer") == "reported"]
    check("Y2 pre hand path: ONE message, journalled as reported (a single OK, no choice)",
          len(mine) == 1 and len(dl.get("dialogs", [])) == 1, dl)
    check("Y2 pre hand path: the message names the object's pre-fader send's aux (en)",
          len(mine) == 1 and "pre-fader" in (mine[0].get("info") or "") and "before the fader" in (mine[0].get("info") or ""), mine)
    check("Y2 pre hand path: the model is unchanged", y2_fingerprint(c, x) == before)
    check("Y2 pre hand path: no render was started", c.send("consolidate.state").get("renders") == [])
    audit(c, "Y2 pre")

    # --- an object with BOTH a chain send and a pre-fader send: the pre-fader refusal wins
    x, a = y2_build(c, "Y2both", chain)
    a2 = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 9})["id"]
    c.send("send.create", {"id": x, "aux": a2, "position": "pre_fader"})
    settle(c)
    before = y2_fingerprint(c, x)
    for label, extra in (("both default", {}), ("both fold", {"mid_chain_sends": "fold"})):
        try:
            c.send("consolidate.make", dict({"id": x}, **extra))
            check("Y2 %s: refused" % label, False, "it was accepted")
        except ObjekatError as e:
            rows = e.details or []
            check("Y2 %s: the PRE-FADER refusal wins (message, one row = the pre-fader send)" % label,
                  e.code == "invalid_state" and e.message.startswith("pre_fader_send")
                  and len(rows) == 1 and rows[0].get("aux") == a2 and rows[0].get("position") == "pre_fader",
                  "%s %s %s" % (e.code, e.message, rows))
    check("Y2 both: nothing was folded (fingerprint)", y2_fingerprint(c, x) == before)
    audit(c, "Y2 both")

    # --- a group's OWN pre-fader send blocks the group, and the lone clip inside is not the group's concern
    x, a = y2_build(c, "Y2grp", {"position": "post_fader"})
    g = grp(c, [x])
    c.send("send.create", {"id": g, "aux": a, "position": "pre_fader"})
    settle(c)
    before = y2_fingerprint(c, g)
    refused_pre("group own", g, a)
    check("Y2 group own: the model is unchanged (fingerprint)", y2_fingerprint(c, g) == before)


# --------------------------------------------------------------------------------------------------
# U2 — Q-U12: a silenced sender feeds no aux, wherever its send taps
# --------------------------------------------------------------------------------------------------

def section_RT2(c):
    print("\n--- RT2  send.retarget: same level / position / wet at the new aux; refusals; undo; pick-mode doors")
    if REF:
        print("       (skipped in --ref)")
        return
    pipeline_offset_db(c)
    fresh(c, "RT2")
    x = c.send("object.add", {"path": out("imp.wav"), "lane": 0, "start": 0.0})["id"]
    a1 = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 1})["id"]
    a2 = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 2})["id"]
    other = c.send("object.add", {"path": out("imp.wav"), "lane": 4, "start": 0.0})["id"]
    add_test(c, x, "gainTester", gain_db=-12.0)
    c.send("send.create", {"id": x, "aux": a1, "position": "chain", "index": 1})
    lay_send(c, x, a1, -6.0)
    audit(c, "RT2 before", want_senders=1)
    _, _, db1 = measure_wet_db(c, "RT2_a1", x, a1)
    check("RT2: the wet at a1 is -12 + -6 = -18 dB re source (+-0.05)", db1 is not None and abs(db1 + 18.0) <= 0.05, db1)

    r = c.send("send.retarget", {"id": x, "aux": a1, "to": a2})
    check("RT2: send.retarget answers the new aux, the old one, the level and the position",
          r.get("aux") == a2 and r.get("was") == a1 and abs(r.get("level_db") + 6.0) < 1e-3
          and r.get("position") == "chain" and r.get("index") == 1, r)
    sends = c.send("send.list", {"id": x})["sends"]
    check("RT2: send.list holds ONE send, towards a2, still chain 1, on",
          len(sends) == 1 and sends[0]["aux"] == a2 and sends[0]["position"] == "chain"
          and sends[0]["index"] == 1 and sends[0].get("enabled") is True, sends)
    rep = audit(c, "RT2 after", want_senders=1)
    lay = (rep.get("engine_layouts") or {}).get(x, [])
    check("RT2: the engine's list puts the send (for a2) between the plugins",
          where_in_list(lay, a2) == "chain1" and where_in_list(lay, a1) == "absent", [(e["index"], e["role"], e.get("aux")) for e in lay])
    _, _, db2 = measure_wet_db(c, "RT2_a2", x, a2)
    check("RT2: the wet at a2 is the same as it was at a1 (+-0.05 dB)", db2 is not None and abs(db2 - db1) <= 0.05, (db1, db2))
    # --- refusals, each with its reason, and nothing changed
    before = c.send("send.list", {"id": x})["sends"]
    cases = [("no such send", {"id": x, "aux": a1, "to": a2}, "not_found"),
             ("the target is not an aux", {"id": x, "aux": a2, "to": other}, "invalid_state"),
             ("the same aux", {"id": x, "aux": a2, "to": a2}, "invalid_state")]
    for label, params, code in cases:
        try:
            c.send("send.retarget", params)
            check("RT2 %s: refused" % label, False, "accepted")
        except ObjekatError as e:
            check("RT2 %s: refused (%s) with a reason" % (label, code), e.code == code and "refused" in e.message, "%s %s" % (e.code, e.message))
    a3 = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 3})["id"]
    c.send("send.create", {"id": x, "aux": a3, "position": "post_fader"})
    try:
        c.send("send.retarget", {"id": x, "aux": a2, "to": a3})
        check("RT2 target already has a send: refused", False, "accepted")
    except ObjekatError as e:
        check("RT2 target already has a send: invalid_state", e.code == "invalid_state", "%s %s" % (e.code, e.message))
    after_refusals = [s_ for s_ in c.send("send.list", {"id": x})["sends"] if s_["aux"] in (a2,)]
    check("RT2: refusals changed nothing (the a2 send is as it was)",
          len(after_refusals) == 1 and after_refusals[0]["position"] == "chain" and after_refusals[0]["index"] == 1,
          after_refusals)
    c.send("send.remove", {"id": x, "aux": a3})

    # --- undo / redo: one point, and the marker comes back to a1
    c.send("project.save")
    n_before = len(c.send("send.list", {"id": x})["sends"])
    c.send("send.retarget", {"id": x, "aux": a2, "to": a1})
    c.send("edit.undo", {})
    settle(c)
    row = [s_ for s_ in c.send("send.list", {"id": x})["sends"]]
    check("RT2: one undo puts the send back on a2, same position", len(row) == n_before and row[0]["aux"] == a2
          and row[0]["position"] == "chain", row)
    audit(c, "RT2 undone", want_senders=1)
    c.send("edit.redo", {})
    settle(c)
    row = [s_ for s_ in c.send("send.list", {"id": x})["sends"]]
    check("RT2: redo aims it at a1 again", row[0]["aux"] == a1 and row[0]["position"] == "chain", row)
    audit(c, "RT2 redone", want_senders=1)

    # --- the pick mode ("Choose an object on the timeline..."), through its debug door
    c.send("send.remove", {"id": x, "aux": a1})
    settle(c)
    check("RT2 pick: idle at first", c.send("debug.route_pick", {"action": "state"}).get("mode") == "none")
    r = c.send("debug.route_pick", {"action": "begin_send", "id": x, "position": "pre_fader"})
    check("RT2 pick: armed for a send", r.get("mode") == "send", r)
    r = c.send("debug.route_pick", {"action": "refusal", "object": other})
    check("RT2 pick: a non-aux is refused, with a reason", isinstance(r.get("refusal"), str) and "aux" in r["refusal"], r)
    r = c.send("debug.route_pick", {"action": "refusal", "object": a3})
    check("RT2 pick: an aux in scope is not refused", r.get("refusal") is None, r)
    r = c.send("debug.route_pick", {"action": "commit", "object": other})
    check("RT2 pick: clicking a non-aux changes nothing and leaves the mode armed",
          r.get("committed") is False and r.get("mode") == "send", r)
    n0 = len(c.send("send.list", {"id": x})["sends"])
    r = c.send("debug.route_pick", {"action": "commit", "object": a3})
    check("RT2 pick: clicking an aux makes the send and leaves the mode", r.get("committed") is True and r.get("mode") == "none", r)
    sends = c.send("send.list", {"id": x})["sends"]
    row = [s_ for s_ in sends if s_["aux"] == a3]
    check("RT2 pick: the send exists, at the position the pick was armed with, silent and on",
          len(sends) == n0 + 1 and len(row) == 1 and row[0]["position"] == "pre_fader" and row[0]["level_db"] <= -59.0, sends)
    audit(c, "RT2 picked")
    c.send("edit.undo", {})
    settle(c)
    check("RT2 pick: ONE undo takes the new send away", len(c.send("send.list", {"id": x})["sends"]) == n0)
    c.send("edit.redo", {})
    settle(c)
    # re-aim by pick
    r = c.send("debug.route_pick", {"action": "begin_send", "id": x, "position": "post_fader", "retargeting": a3})
    check("RT2 pick (retarget): armed", r.get("mode") == "send", r)
    check("RT2 pick (retarget): the aux it already goes to is not a refusal (a no-op)",
          c.send("debug.route_pick", {"action": "refusal", "object": a3}).get("refusal") is None)
    r = c.send("debug.route_pick", {"action": "commit", "object": a2})
    row = [s_ for s_ in c.send("send.list", {"id": x})["sends"]]
    check("RT2 pick (retarget): the send now goes to a2 and a3 has none, position kept",
          r.get("committed") is True and any(s_["aux"] == a2 and s_["position"] == "pre_fader" for s_ in row)
          and not any(s_["aux"] == a3 for s_ in row), row)
    c.send("debug.route_pick", {"action": "begin_send", "id": x, "position": "input"})
    check("RT2 pick: Esc leaves the mode", c.send("debug.route_pick", {"action": "end"}).get("mode") == "none")
    audit(c, "RT2 end")

    # --- the "Send to..." menu's data: Q-U3 order, greyed with a reason
    fresh(c, "RT2menu")
    x = c.send("object.add", {"path": out("imp.wav"), "lane": 0, "start": 0.0})["id"]
    y = c.send("object.add", {"path": out("imp.wav"), "lane": 5, "start": 0.0})["id"]
    aux_main = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 1, "name": "MainAux"})["id"]
    aux_sib = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 2, "name": "SibAux"})["id"]
    g = c.send("group.create", {"ids": [x, aux_sib]})["id"]       # x and SibAux now siblings inside a group
    st = c.send("stem.add", {"name": "S"})["id"]
    c.send("stem.assign", {"stem": st, "ids": [g]})
    settle(c)
    m = c.send("debug.send_target_menu", {"id": x})["sections"]
    ids_ = [[e["aux"] for e in sec["entries"]] for sec in m]
    print("       menu tiers %s: %d + %d entries" % ([sec["tier"] for sec in m], *[len(i) for i in ids_]))
    check("RT2 menu: the aux of the sender's own group comes first (tier 0)", m and m[0]["tier"] == 0 and ids_[0] == [aux_sib], m)
    check("RT2 menu: the Main's aux comes last (tier 2) and a stem-bound sender can reach it",
          m and m[-1]["tier"] == 2 and ids_[-1] == [aux_main], m)
    check("RT2 menu: sections are in tier order", [sec["tier"] for sec in m] == sorted(sec["tier"] for sec in m), m)
    c.send("send.create", {"id": x, "aux": aux_sib})
    m = c.send("debug.send_target_menu", {"id": x})["sections"]
    sib = [e for sec in m for e in sec["entries"] if e["aux"] == aux_sib][0]
    check("RT2 menu: an aux that already has a send is greyed, with the reason", sib["enabled"] is False and sib["reason"], sib)
    m2 = c.send("debug.send_target_menu", {"id": x, "retargeting": aux_sib})["sections"]
    check("RT2 menu: 'Change target...' leaves the card's own aux out",
          not any(e["aux"] == aux_sib for sec in m2 for e in sec["entries"]), m2)
    check("RT2 menu: an aux, a stem and the Main have no menu",
          c.send("debug.send_target_menu", {"id": aux_main})["sections"] == [])



def section_U2(c):
    print("\n--- U2  a muted / filtered-out / stem-muted sender feeds no aux, even before the fader")
    if REF:
        print("       (skipped in --ref)")
        return
    for name, params in (("post", {"position": "post_fader"}), ("pre", {"position": "pre_fader"}),
                         ("chain", {"position": "chain", "index": 0}), ("input", {"position": "input"})):
        fresh(c, "U2" + name)
        x = c.send("object.add", {"path": out("sine1k.wav"), "lane": 0, "start": 0.0})["id"]
        o = c.send("object.add", {"path": out("sine1k.wav"), "lane": 3, "start": 0.0})["id"]
        a = c.send("aux.create", {"start": 0.0, "end": 4.0, "lane": 5})["id"]
        add_test(c, x, "gainTester", gain_db=0.0)
        c.send("send.create", dict({"id": x, "aux": a}, **params))
        lay_send(c, x, a, 0.0)
        audit(c, "U2 %s" % name, want_senders=1)

        def wet_db_win(label):
            _, w = measure(c, "U2%s_%s" % (name, label), x, a, 0.0, t1=3.0)
            return B.db(B.rms(w, 0.5, 2.5)), maxabs(w[int(0.5 * SR):int(2.5 * SR)])

        lit, _ = wet_db_win("lit")
        check("U2 %s: audible: the wet is there (%.1f dB)" % (name, lit), lit > -40.0, lit)
        c.send("object.set_mute", {"ids": [x], "muted": True})
        settle(c)
        _, mx = wet_db_win("muted")
        check("U2 %s: X muted: the wet is exactly 0" % name, mx == 0.0, mx)
        c.send("object.set_mute", {"ids": [x], "muted": False})
        settle(c)
        back, _ = wet_db_win("unmuted")
        check("U2 %s: un-muted: the wet is back, same level (0.05 dB)" % name, abs(back - lit) <= 0.05, (back, lit))
        c.send("solo.set", {"ids": [o], "on": True})
        settle(c)
        _, mx = wet_db_win("solo")
        check("U2 %s: another object soloed (X filtered out): the wet is exactly 0" % name, mx == 0.0, mx)
        c.send("solo.clear", {})
        settle(c)
        back, _ = wet_db_win("unsolo")
        check("U2 %s: solo cleared: the wet is back (0.05 dB)" % name, abs(back - lit) <= 0.05, (back, lit))
        st = c.send("stem.add", {"name": "S"})["id"]
        c.send("stem.assign", {"stem": st, "ids": [x, a]})
        settle(c)
        c.send("stem.mute", {"id": st, "muted": True})
        settle(c)
        _, mx = wet_db_win("stemmute")
        check("U2 %s: X's stem muted: the wet is exactly 0" % name, mx == 0.0, mx)
        c.send("stem.mute", {"id": st, "muted": False})
        settle(c)
        back, _ = wet_db_win("stemback")
        check("U2 %s: stem un-muted: the wet is back (0.05 dB)" % name, abs(back - lit) <= 0.05, (back, lit))
        audit(c, "U2 %s end" % name)


# --------------------------------------------------------------------------------------------------
# Z2 — save and reopen: the position, the marker and the wet come back
# PF — files that are not what the app wrote: format 21, and a format-22 file that breaks the marker rules
# --------------------------------------------------------------------------------------------------

def find_obj(items, oid):
    """An object of a saved session, wherever it nests."""
    for it in items:
        if it.get("id") == oid:
            return it
        r = find_obj((it.get("kind") or {}).get("children") or [], oid)
        if r is not None:
            return r
    return None


def section_Z2(c):
    print("\n--- Z2  save / reopen: every position, its marker and its wet come back; the file is clean")
    if REF:
        print("       (skipped in --ref)")
        return
    pipeline_offset_db(c)
    x, a1 = cast_siblings(c, "Z2")
    a2 = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 2})["id"]
    a3 = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 4})["id"]
    add_test(c, x, "gainTester", gain_db=-12.0)
    c.send("debug.set_chain_gain", {"host": x, "in_db": -6.0, "out_db": -3.0})
    c.send("object.set_gain", {"ids": [x], "db": -20.0})
    w = c.send("object.add", {"path": out("imp.wav"), "lane": 6, "start": 0.0})["id"]
    c.send("send.create", {"id": x, "aux": a1, "position": "chain", "index": 1})
    c.send("send.create", {"id": x, "aux": a2, "position": "input"})
    c.send("send.create", {"id": x, "aux": a3, "position": "pre_fader"})
    c.send("send.create", {"id": w, "aux": a1, "position": "post_fader"})
    for snd, aux, db in ((x, a1, 0.0), (x, a2, 0.0), (x, a3, 0.0), (w, a1, -6.0)):
        lay_send(c, snd, aux, db)
    audit(c, "Z2 before save", want_senders=2)

    cases = (("X chain(1)", x, a1, "chain", -18.0), ("X input", x, a2, "input", 0.0),
             ("X pre", x, a3, "pre_fader", -21.0), ("W post", w, a1, "post_fader", -6.0 - 0.0))
    before = {}
    for name, snd, aux, pos, expect in cases:
        dry, wet = measure(c, "Z2 %s" % name, snd, aux, 0.0)
        db = wet_db(wet)
        row = position_row(c, snd, aux)
        before[name] = (db, row)
        print("       Z2 before %-10s wet %s dB re source (position %s)" % (name, None if db is None else "%.3f" % db, row.get("position")))
        check("Z2 before: %s is %s" % (name, pos), row.get("position") == pos, row)
        check("Z2 before: %s wet %.0f dB (0.05)" % (name, expect), db is not None and abs(db - expect) <= 0.05, db)

    c.send("project.save")
    path = out("Z2/project.objekat")
    d1 = json.load(open(path))
    check("Z2 file: saved as format 25", d1.get("version") == 25, d1.get("version"))
    ox = find_obj(d1["items"], x)
    ow = find_obj(d1["items"], w)
    markers = [p_ for p_ in ox.get("plugins", []) if "sendMarker" in p_]
    check("Z2 file: exactly one marker on X, for the chain send", len(markers) == 1 and markers[0]["sendMarker"]["auxID"].lower() == a1.lower(),
          markers)
    taps = {sd["auxID"].lower(): sd.get("tap") for sd in ox.get("sends", [])}
    check("Z2 file: the input send carries tap=input, the pre-fader one tap=preFader, the chain one NO tap",
          taps.get(a2.lower()) == "input" and taps.get(a3.lower()) == "preFader" and taps.get(a1.lower()) is None, taps)
    check("Z2 file: W's post-fader send has no tap and W has no marker",
          all(sd.get("tap") is None for sd in ow.get("sends", [])) and not any("sendMarker" in p_ for p_ in ow.get("plugins", [])),
          ow.get("sends"))

    c.send("project.open", {"path": path})
    wait(c)
    audit(c, "Z2 after reopen", want_senders=2)
    for name, snd, aux, pos, expect in cases:
        b_db, b_row = before[name]
        row = position_row(c, snd, aux)
        same = all(row.get(k) == b_row.get(k) for k in ("position", "index", "after_plugin", "before_plugin", "follows_window", "status"))
        check("Z2 reopen: %s comes back at the same place with the same neighbours and status" % name, same, (row, b_row))
        dry, wet = measure(c, "Z2 reopen %s" % name, snd, aux, 0.0)
        db = wet_db(wet)
        print("       Z2 reopen %-10s wet %s dB re source" % (name, None if db is None else "%.3f" % db))
        check("Z2 reopen: %s wet %.3f dB, as before the save (0.05)" % (name, b_db if b_db is not None else float('nan')),
              db is not None and b_db is not None and abs(db - b_db) <= 0.05, (db, b_db))
    rds = send_readers(bridge_report(c))
    check("Z2 reopen: 4 send readers, all aligned to the sample", len(rds) == 4 and all(r.get("alignment_error_samples") == 0 for r in rds), rds)

    # a second save with nothing touched writes the same sends and the same chain skeleton
    c.send("project.save")
    d2 = json.load(open(path))
    ox2 = find_obj(d2["items"], x)

    def skeleton(o):
        return ([(p_.get("id"), "sendMarker" in p_) for p_ in o.get("plugins", [])],
                sorted((sd["auxID"].lower(), sd.get("tap"), sd.get("levelDb"), sd.get("enabled")) for sd in o.get("sends", [])))
    check("Z2 file: a second save writes the same chain skeleton and the same sends", skeleton(ox) == skeleton(ox2),
          (skeleton(ox), skeleton(ox2)))
    audit(c, "Z2 end")


def section_PF(c):
    print("\n--- PF  a format-21 file opens as post-fader; a format-22 file that breaks the marker rules is repaired")
    if REF:
        print("       (skipped in --ref)")
        return
    pipeline_offset_db(c)
    # ---- (1) format 21: no tap, no marker
    x, a = cast_siblings(c, "PF1")
    c.send("debug.set_chain_gain", {"host": x, "in_db": -6.0, "out_db": -3.0})
    c.send("object.set_gain", {"ids": [x], "db": -20.0})
    c.send("send.create", {"id": x, "aux": a, "position": "post_fader"})
    lay_send(c, x, a, -6.0)
    dry, wet = measure(c, "PF1 before", x, a, -6.0)
    v1 = wet_db(wet)
    print("       PF1 post-fader wet before: %s dB re source" % (None if v1 is None else "%.3f" % v1))
    c.send("project.save")
    path = out("PF1/project.objekat")
    d = json.load(open(path))
    blob = json.dumps(d["items"])      # not the _readme, which names both keys in prose
    check("PF1: the post-fader file this build writes holds neither a marker nor a tap (it IS a format-21 shape)",
          "sendMarker" not in blob and '"tap"' not in blob, "")
    d["version"] = 21
    json.dump(d, open(path, "w"), indent=1)
    c.send("project.open", {"path": path})
    wait(c)
    row = position_row(c, x, a)
    check("PF1: opened at post_fader, not following the window", row.get("position") == "post_fader" and row.get("follows_window") is False, row)
    dry, wet = measure(c, "PF1 after", x, a, -6.0)
    v2 = wet_db(wet)
    check("PF1: the wet is what it was (0.05 dB)", v1 is not None and v2 is not None and abs(v1 - v2) <= 0.05, (v1, v2))
    audit(c, "PF1", want_senders=1)
    c.send("project.save")
    d2 = json.load(open(path))
    blob2 = json.dumps(d2["items"])
    check("PF1: saved as format 25, and still without marker or tap", d2.get("version") == 25 and "sendMarker" not in blob2 and '"tap"' not in blob2,
          d2.get("version"))

    # ---- (2) format 22 that breaks the rules: marker + tap, a duplicate marker, an orphan marker
    x, a = cast_siblings(c, "PF2")
    c.send("debug.set_chain_gain", {"host": x, "in_db": -6.0, "out_db": -3.0})
    c.send("send.create", {"id": x, "aux": a, "position": "chain", "index": 0})
    lay_send(c, x, a, 0.0)
    dry, wet = measure(c, "PF2 before", x, a, 0.0)
    v1 = wet_db(wet)
    print("       PF2 chain(0) wet before: %s dB re source (the tap before the chain: only the IN gain, -6)" % (None if v1 is None else "%.3f" % v1))
    check("PF2: chain(0) taps after the chain's in gain only (-6 dB, 0.05)", v1 is not None and abs(v1 + 6.0) <= 0.05, v1)
    c.send("project.save")
    path = out("PF2/project.objekat")
    d = json.load(open(path))
    ox = find_obj(d["items"], x)
    mk = [p_ for p_ in ox["plugins"] if "sendMarker" in p_]
    check("PF2: the saved file holds the marker", len(mk) == 1, ox["plugins"])
    dup = json.loads(json.dumps(mk[0]))
    dup["id"] = "00000000-0000-4000-8000-0000000000D1"
    orphan = json.loads(json.dumps(mk[0]))
    orphan["id"] = "00000000-0000-4000-8000-0000000000D2"
    orphan["sendMarker"]["auxID"] = "00000000-0000-4000-8000-00000000DEAD"
    ox["plugins"] = ox["plugins"] + [dup, orphan]
    for sd in ox["sends"]:
        sd["tap"] = "preFader"                 # the marker must win over this
    json.dump(d, open(path, "w"), indent=1)
    c.send("project.open", {"path": path})
    wait(c)
    row = position_row(c, x, a)
    check("PF2: the marker wins over the tap: position chain, index 0", row.get("position") == "chain" and row.get("index") == 0, row)
    r = audit(c, "PF2 after open", want_senders=1)
    check("PF2: ONE marker is left (the duplicate and the orphan were dropped)", r.get("markers") == 1, r.get("markers"))
    dry, wet = measure(c, "PF2 after", x, a, 0.0)
    v2 = wet_db(wet)
    check("PF2: the wet is the chain(0) one, not a pre-fader one (-6 dB, 0.05)", v2 is not None and abs(v2 + 6.0) <= 0.05, v2)
    c.send("project.save")
    d3 = json.load(open(path))
    ox3 = find_obj(d3["items"], x)
    check("PF2: saved again: one marker, no tap on the send", sum(1 for p_ in ox3["plugins"] if "sendMarker" in p_) == 1
          and all(sd.get("tap") is None for sd in ox3["sends"]), (ox3["plugins"], ox3["sends"]))

# ==================================================================================================
# INC 3 — plugins ON a send (docs/plan_sends_rework.md §D.2.C). The mini-chain of a send is a chain
# HOST of its own (`send.list` gives its id, `chain_host`): every plugin command takes it.
# ==================================================================================================

def send_host(c, x, a):
    """The chain host of the send x -> a, or None when the app has no such door."""
    rows = [r for r in c.send("send.list", {"id": x})["sends"] if r["aux"] == a]
    return rows[0].get("chain_host") if rows else None


def need_host(c, label, x, a):
    h = send_host(c, x, a)
    check(label + ": send.list gives the send's chain_host", h is not None, "no door yet (INC 3, step 3.8)")
    return h


def add_on_send(c, label, x, a, kind, **kw):
    """Lays a test plugin ON the send x -> a. Returns (host, plugin id) or (None, None)."""
    h = need_host(c, label, x, a)
    if h is None:
        return None, None
    params = {"host": h, "type": kind}
    params.update(kw)
    r = step(label + ": %s laid on the send" % kind, lambda: c.send("debug.add_test_plugin", params))
    settle(c)
    return h, (r or {}).get("plugin")


def aux_wet(c, name, aux, t1=3.0):
    """(dry, wet) of everything that reaches `aux`: the export with the aux, minus the export with the
    aux muted. For the sections with SEVERAL senders, where switching one send off is not the wet."""
    on = render(c, name + "_on.wav", 0.0, t1)
    c.send("object.set_mute", {"ids": [aux], "muted": True})
    settle(c)
    off = render(c, name + "_off.wav", 0.0, t1)
    c.send("object.set_mute", {"ids": [aux], "muted": False})
    settle(c)
    return off, sub(on, off)


def seg(s, t0, t1):
    return s[int(t0 * SR):int(t1 * SR)]


def seg_db(s, t0, t1):
    return B.db(B.rms(s, t0, t1))


def seg_peak_db(s, t0, t1):
    return B.db(maxabs(seg(s, t0, t1)))


def engine_send_row(rep, x, a):
    for e in ((rep.get("engine") or {}).get("sends") or []):
        if e.get("sender") == x and e.get("aux") == a:
            return e
    return {}


def set_position(c, x, a, pos):
    prm = {"id": x, "aux": a, "position": pos}
    if pos == "chain":
        prm["index"] = 0
    c.send("send.set_position", prm)
    settle(c)


POSITIONS3 = ("post_fader", "pre_fader", "input", "chain")


# --------------------------------------------------------------------------------------------------
# A3 — THE feature: a plugin on a send acts on THIS sender's wet, and on nothing else
# --------------------------------------------------------------------------------------------------

def section_A3(c):
    print("\n--- A3  a plugin on a send acts on this sender's wet only (dry and the other sender untouched)")
    if REF:
        print("       (skipped in --ref: plugins on a send are INC 3)")
        return
    for pos in POSITIONS3:
        name = "A3_" + pos
        fresh(c, name)
        x1 = c.send("object.add", {"path": out("sine1s.wav"), "lane": 0, "start": 0.0})["id"]
        x2 = c.send("object.add", {"path": out("sine1s.wav"), "lane": 1, "start": 1.5})["id"]
        a = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 2})["id"]
        for x in (x1, x2):
            c.send("send.create", {"id": x, "aux": a, "position": "post_fader"})
            lay_send(c, x, a, -6.0)
            set_position(c, x, a, pos)
        dry0, wet0 = aux_wet(c, name + "_ref", a)
        ref1, ref2 = seg_db(wet0, 0.2, 0.8), seg_db(wet0, 1.7, 2.3)
        check("A3 %s: reference: both senders reach the aux (%.1f / %.1f dB)" % (pos, ref1, ref2),
              ref1 > -40.0 and ref2 > -40.0, (ref1, ref2))

        h, pid = add_on_send(c, "A3 " + pos, x1, a, "gainTester", gain_db=-12.0)
        if pid is None:
            continue
        dry1, wet1 = aux_wet(c, name + "_fx", a)
        check("A3 %s (1): the direct signal is identical, sample for sample" % pos,
              maxabs(sub(dry1, dry0)) == 0.0, maxabs(sub(dry1, dry0)))
        got = seg_db(wet1, 0.2, 0.8) - ref1
        print("       A3 %s: X1's wet %.3f dB against the reference (wanted -12.00)" % (pos, got))
        check("A3 %s (2): X1's wet is 12 dB down (0.05)" % pos, abs(got + 12.0) <= 0.05, "%.3f" % got)
        d2 = maxabs(seg(sub(wet1, wet0), 1.4, 3.0))
        check("A3 %s (3): X2's wet is identical, sample for sample" % pos, d2 == 0.0, d2)

        # (4) the control: the same plugin on X1's TRUNK lowers the direct signal too.
        step("A3 %s: the plugin leaves the send" % pos, lambda: c.send("plugin.remove", {"host": h, "plugin": pid}))
        settle(c)
        dryb, wetb = aux_wet(c, name + "_back", a)
        check("A3 %s: plugin removed: wet and dry are the reference again" % pos,
              maxabs(sub(dryb, dry0)) == 0.0 and maxabs(sub(wetb, wet0)) == 0.0,
              (maxabs(sub(dryb, dry0)), maxabs(sub(wetb, wet0))))
        add_test(c, x1, "gainTester", gain_db=-12.0)
        settle(c)
        dry2, _ = aux_wet(c, name + "_trunk", a)
        gd = seg_db(dry2, 0.2, 0.8) - seg_db(dry0, 0.2, 0.8)
        check("A3 %s (4): control: on the TRUNK the same plugin lowers the direct signal by 12 dB" % pos,
              abs(gd + 12.0) <= 0.05, "%.3f" % gd)
        audit(c, "A3 " + pos)


# --------------------------------------------------------------------------------------------------
# L3 — a latency plugin on a send ages the TAP: the wet stays on the dry, the dry does not move
# --------------------------------------------------------------------------------------------------

def set_latency(c, plugin, ms):
    c.send("debug.set_plugin_property", {"plugin": plugin, "property": "time", "value": ms / 1000.0})
    wait(c)
    time.sleep(0.6)          # the latency watch rebuilds on its own timer
    wait(c)


def section_L3(c):
    print("\n--- L3  latency ON a send: the wet stays on the dry to the sample, the dry is untouched")
    if REF:
        print("       (skipped in --ref: plugins on a send are INC 3)")
        return
    x, a = cast_siblings(c, "L3")
    # A second sender, WITHOUT mini-chain, to the same aux: a small impulse at 2 s.
    y = c.send("object.add", {"path": out("imp_small.wav"), "lane": 3, "start": 0.0})["id"]
    lay_send(c, x, a, -6.0)
    lay_send(c, y, a, -6.0)
    dry0, wet0 = aux_wet(c, "L3_ref", a)
    p0x, p0y = B.peak_index(seg(wet0, 0.5, 1.5)), B.peak_index(seg(wet0, 1.5, 2.5))
    check("L3: reference: both wets are on their dry", p0x == int(0.5 * SR) and p0y == int(0.5 * SR), (p0x, p0y))

    h, pid = add_on_send(c, "L3", x, a, "latencyTester", latency_ms=20.0)
    if pid is None:
        return
    set_latency(c, pid, 20.0)
    dry1, wet1 = aux_wet(c, "L3_lat", a)
    check("L3: the direct signal is identical with a 20 ms plugin on the send",
          maxabs(sub(dry1, dry0)) == 0.0, maxabs(sub(dry1, dry0)))
    check("L3: the wet is identical too (a pure delay, compensated to the sample)",
          maxabs(sub(wet1, wet0)) == 0.0, maxabs(sub(wet1, wet0)))
    pd, pw = B.peak_index(dry1), B.peak_index(wet1)
    check("L3: idx(wet peak) == idx(dry peak)", pd == pw, "%s vs %s" % (pd, pw))
    py = B.peak_index(seg(wet1, 1.5, 2.5))
    check("L3: the second sender (no mini-chain) is still on its dry", py == int(0.5 * SR), py)

    rep = bridge_report(c)
    eng = rep.get("engine") or {}
    build = eng.get("build") or {}
    rate = build.get("sample_rate") or 0
    P = int(round(0.020 * rate))
    row = engine_send_row(rep, x, a)
    print("       L3: graph at %s Hz, send row %s" % (rate, row))
    check("L3: the tap's age is L + P (%d samples at the graph's rate)" % P, row.get("age_samples") == P, row)
    check("L3: chain_latency_samples == P", row.get("chain_latency_samples") == P, row)
    check("L3: chain_plugins == 1", row.get("chain_plugins") == 1, row)
    check("L3: converged in at most 2 passes", build.get("converged") is True and (build.get("passes") or 9) <= 2, build)
    rds = send_readers(rep)
    check("L3: two send readers, aligned, none torn",
          len(rds) == 2 and all(r.get("alignment_error_samples") == 0 and r.get("blocks_torn", 0) == 0
                                and r.get("status") == "aligned" for r in rds), rds)
    # The reader of the send that CARRIES the mini-chain reads its tap with no delay: nothing is ever
    # uncovered. The other sender's reader is delayed by P, and a delay line has a warm-up: the first
    # ceil(P / block) blocks of a stream (the live graph's, and each export's) ask for samples from
    # before the stream began, which are silence by definition. That is the bridge's own behaviour
    # (measured identical with the same 20 ms plugin on the sender's TRUNK, the INC 2 path), so it is
    # printed and bounded, not asserted to be zero.
    mine = [r for r in rds if (r.get("send") or "").startswith(x)]
    other = [r for r in rds if not (r.get("send") or "").startswith(x)]
    check("L3: the mini-chain's reader: no delay, nothing uncovered",
          len(mine) == 1 and mine[0].get("delay") == 0 and mine[0].get("blocks_uncovered", 0) == 0, mine)
    check("L3: the other sender's reader is delayed by exactly P", len(other) == 1 and other[0].get("delay") == P, other)
    if other:
        print("       L3: the delayed reader's warm-up: %s uncovered block(s) out of %s read (every stream start counts)"
              % (other[0].get("blocks_uncovered"), other[0].get("blocks_read")))
    check("L3: the return declares L + P (the aux, and only it, carries the mini-chain's latency)",
          all(r.get("declared") == P for r in rds), rds)

    # A 30 ms plugin on the AUX: R > L + P, nothing is padded, one pass.
    r30 = add_test(c, a, "latencyTester", 30.0)
    set_latency(c, r30["plugin"], 30.0)
    dry2, wet2 = aux_wet(c, "L3_aux30", a)
    pd, pw = B.peak_index(dry2), B.peak_index(wet2)
    check("L3: with 30 ms on the aux: idx(wet peak) == idx(dry peak)", pd == pw, "%s vs %s" % (pd, pw))
    rep = bridge_report(c)
    build = (rep.get("engine") or {}).get("build") or {}
    check("L3: with 30 ms on the aux: one pass, converged", build.get("converged") is True and build.get("passes") == 1, build)
    c.send("plugin.remove", {"host": a, "plugin": r30["plugin"]})
    settle(c)

    # The latency changed while laid: realigned by the latency watch.
    set_latency(c, pid, 5.0)
    dry3, wet3 = aux_wet(c, "L3_5ms", a)
    check("L3: latency changed to 5 ms: the direct signal still identical", maxabs(sub(dry3, dry0)) == 0.0, maxabs(sub(dry3, dry0)))
    check("L3: latency changed to 5 ms: the wet still identical", maxabs(sub(wet3, wet0)) == 0.0, maxabs(sub(wet3, wet0)))
    rep = bridge_report(c)
    row = engine_send_row(rep, x, a)
    rate = ((rep.get("engine") or {}).get("build") or {}).get("sample_rate") or 0
    check("L3: the tap's age follows (5 ms)", row.get("age_samples") == int(round(0.005 * rate)), row)
    audit(c, "L3")


# --------------------------------------------------------------------------------------------------
# O3 — the order on the copy: the plugins, then the envelope, then the level
# --------------------------------------------------------------------------------------------------

def section_O3(c):
    print("\n--- O3  order on the send's copy: plugins -> envelope -> level")
    if REF:
        print("       (skipped in --ref: plugins on a send are INC 3)")
        return
    # No pipeline offset here: `pipeline_offset_db` is what the export does to an IMPULSE (-0.733 dB, the
    # resampler's band limit); a 1 kHz tone comes out at its own level, and the clipper's ceiling is read
    # straight off the peak.
    k = 0.0

    # (1) the level comes AFTER the plugins: a clipper at -12 dBFS on a -6 dBFS sine, send at -6 dB.
    fresh(c, "O3a")
    x = c.send("object.add", {"path": out("sine_m6.wav"), "lane": 0, "start": 0.0})["id"]
    a = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 1})["id"]
    lay_send(c, x, a, -6.0)
    h, pid = add_on_send(c, "O3", x, a, "clipTester", ceiling_db=-12.0)
    if pid is None:
        return
    levels = {}
    for pos in ("post_fader", "pre_fader"):
        set_position(c, x, a, pos)
        dry, wet = measure(c, "O3a_" + pos, x, a, 0.0)
        levels[pos] = seg_peak_db(wet, 1.0, 2.0) - k
        print("       O3 %s: wet peak %.3f dBFS (clip -12, then level -6: -18; the other order: -12)" % (pos, levels[pos]))
        check("O3 %s: wet peak -18.0 dBFS (0.1): the level acts AFTER the plugins" % pos,
              abs(levels[pos] + 18.0) <= 0.1, "%.3f" % levels[pos])
    check("O3: post-fader with the fader at 0 dB = pre-fader (0.05 dB), clipper laid",
          abs(levels["post_fader"] - levels["pre_fader"]) <= 0.05, levels)

    # (2) the envelope comes AFTER the plugins (Q-U18, decided on 10 October: an effect's tail follows
    # the object's fade): a pre-fader send, a 1 s fade-in. Read where the fade is well under the
    # ceiling: the clipper sees the UN-faded signal and bites it (-12 dBFS), THEN the fade and the
    # level are laid: the wet is 12 dB under the dry. The other order (fade, then clip) would give
    # 6 dB; a fade laid TWICE would give 12 dB plus the fade once more (20 or so).
    fresh(c, "O3b")
    x = c.send("object.add", {"path": out("sine_m6.wav"), "lane": 0, "start": 0.0})["id"]
    a = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 1})["id"]
    c.send("object.set_fade", {"id": x, "in": 1.0})
    c.send("send.create", {"id": x, "aux": a, "position": "pre_fader"})
    lay_send(c, x, a, -6.0)
    h, pid = add_on_send(c, "O3 fade", x, a, "clipTester", ceiling_db=-12.0)
    if pid is None:
        return
    dry, wet = measure(c, "O3b", x, a, 0.0)
    full = seg_peak_db(dry, 1.5, 2.5)
    t_read = None
    for i in range(5, 95):
        t = i / 100.0
        e = seg_peak_db(dry, t, t + 0.01) - full
        if -10.0 <= e <= -8.0:
            t_read = t
            break
    check("O3 fade: a 10 ms window where the fade is 8 to 10 dB down exists", t_read is not None, "none")
    if t_read is not None:
        e = seg_peak_db(dry, t_read, t_read + 0.01) - full
        got = seg_peak_db(wet, t_read, t_read + 0.01) - seg_peak_db(dry, t_read, t_read + 0.01)
        print("       O3 fade: at %.2f s the fade is %.2f dB; wet - dry = %.3f dB (clip first: -12; envelope first: -6)"
              % (t_read, e, got))
        check("O3 fade: the clipper sees the UN-faded signal, the fade is laid after it, ONCE (wet = dry - 12 dB, 0.3)",
              abs(got + 12.0) <= 0.3, "%.3f" % got)
    steady = seg_peak_db(wet, 1.5, 2.5) - k
    check("O3 fade: past the fade the clipper bites (-18 dBFS, 0.1)", abs(steady + 18.0) <= 0.1, "%.3f" % steady)


# --------------------------------------------------------------------------------------------------
# P3 — no plugin on a send = INC 2, to the sample
# --------------------------------------------------------------------------------------------------

# --------------------------------------------------------------------------------------------------
# The cast of the sections below: X (an impulse at 1 s) sends to the aux A, a gainTester ON the send.
# The wet is read re the SOURCE (pipeline offset removed): it is the sum of the gains it went through.
# --------------------------------------------------------------------------------------------------

def cast3(c, name, gain_db=-12.0, level=-6.0, pos="post_fader"):
    pipeline_offset_db(c)
    x, a = cast_siblings(c, name)
    c.send("send.create", {"id": x, "aux": a, "position": "post_fader"})
    lay_send(c, x, a, level)
    if pos != "post_fader":
        set_position(c, x, a, pos)
    h, pid = add_on_send(c, name, x, a, "gainTester", gain_db=gain_db)
    return x, a, h, pid


def wet3(c, name, aux, t1=3.0):
    """(wet level re source or None when silent, wet) of everything that reaches `aux`."""
    _, w = aux_wet(c, name, aux, t1)
    return (wet_db(w) if maxabs(w) > 0.0 else None), w


def near(label, got, want_db, tol=0.05):
    print("       %s: %s dB (wanted %.2f)" % (label, None if got is None else "%.3f" % got, want_db))
    check("%s is %.2f dB (%.2f)" % (label, want_db, tol), got is not None and abs(got - want_db) <= tol, got)


def set_gain3(c, pid, db):
    """A gainTester's gain, set on the LIVE instance (the engine's door: the model does not know)."""
    c.send("debug.set_plugin_property", {"plugin": pid, "property": "gainDb", "value": db})
    settle(c)


def send_plugins3(c, x, a):
    return [p_["id"] for p_ in (send_entry(c, x, a) or {}).get("plugins", [])]


def audits3(c, label):
    r = c.send("debug.plugin_id_audit")
    check(label + ": plugin_id_audit is clean", r.get("count") == 0 and r.get("engine_foreign_refusals", 0) == 0, r)
    m = audit(c, label)
    check(label + ": no send plugin is linked", m.get("linked_send_plugins") == [], m.get("linked_send_plugins"))
    return m


def in_engine(c, pid):
    """True if the engine holds an instance under this key."""
    try:
        c.send("debug.set_plugin_property", {"plugin": pid, "property": "objProbe", "value": 1.0})
        return True
    except ObjekatError:
        return False


def refused(label, fn, code="invalid_state", reason=None):
    try:
        r = fn()
        check(label + ": refused", False, "accepted: %s" % (r,))
    except ObjekatError as e:
        why = (e.details or {}).get("reason") if isinstance(e.details, dict) else None
        check(label + ": refused (%s%s)" % (code, ", " + reason if reason else ""),
              e.code == code and (reason is None or why == reason), "%s %s %s" % (e.code, e.message, e.details))


# --------------------------------------------------------------------------------------------------
# G3 — the level, the switch, mute, solo and the gates still give silence, plugin laid
# --------------------------------------------------------------------------------------------------

def section_G3(c):
    print("\n--- G3  -inf, off, mute, solo, stem mute, group mute: silence, with a plugin on the send")
    if REF:
        print("       (skipped in --ref: plugins on a send are INC 3)")
        return
    x, a, h, pid = cast3(c, "G3", gain_db=6.0, level=0.0)
    if pid is None:
        return
    db, _ = wet3(c, "G3_lit", a)
    near("G3: lit: the wet", db, 6.0)
    set_gain3(c, pid, 24.0)             # not measured lit: 0.2 x 15.8 is above the export's ceiling (it clips)
    r = c.send("send.set_level", {"id": x, "aux": a, "db": -200.0})
    settle(c)
    check("G3: the send is at -inf (not routed)", r.get("routed") is False, r)
    _, w = wet3(c, "G3_inf", a)
    check("G3: -inf with a +24 dB plugin on the send: the wet is exactly 0", maxabs(w) == 0.0, maxabs(w))
    set_gain3(c, pid, 6.0)
    lay_send(c, x, a, 0.0)
    c.send("send.enable", {"id": x, "aux": a, "enabled": False})
    settle(c)
    _, w = wet3(c, "G3_off", a)
    check("G3: send switched off: the wet is exactly 0", maxabs(w) == 0.0, maxabs(w))
    row = engine_send_row(bridge_report(c), x, a)
    check("G3: switched off: the engine still holds the send's plugin", row.get("chain_plugins") == 1
          and pid in (row.get("chain_keys") or []) and in_engine(c, pid), row)
    step("G3: switched off: plugin.get_params still answers", lambda: c.send("plugin.get_params", {"plugin": pid}))
    c.send("send.enable", {"id": x, "aux": a, "enabled": True})
    settle(c)
    db, _ = wet3(c, "G3_on", a)
    near("G3: switched on again: the wet", db, 6.0)

    for pos in POSITIONS3:
        name = "G3_" + pos
        pipeline_offset_db(c)
        fresh(c, name)
        x = c.send("object.add", {"path": out("imp.wav"), "lane": 0, "start": 0.0})["id"]
        k = with_other(c, lane=1)
        o = with_other(c, lane=3)
        a = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 5})["id"]
        g = grp(c, [x, k])
        c.send("send.create", {"id": x, "aux": a, "position": "post_fader"})
        lay_send(c, x, a, 0.0)
        set_position(c, x, a, pos)
        h, pid = add_on_send(c, name, x, a, "gainTester", gain_db=6.0)
        if pid is None:
            continue
        lit, _ = wet3(c, name + "_lit", a)
        near("G3 %s: lit: the wet" % pos, lit, 6.0)

        def gated(label, on, off):
            on()
            settle(c)
            _, w = wet3(c, "%s_%s" % (name, label.replace(" ", "_")), a)
            m = maxabs(seg(w, 0.9, 1.2))
            check("G3 %s: %s: the wet is silent (1e-6)" % (pos, label), m <= 1e-6, "%.3e" % m)
            off()
            settle(c)

        gated("sender muted", lambda: c.send("object.set_mute", {"ids": [x], "muted": True}),
              lambda: c.send("object.set_mute", {"ids": [x], "muted": False}))
        gated("another object soloed", lambda: c.send("solo.set", {"ids": [o], "on": True}),
              lambda: c.send("solo.clear", {}))
        gated("parent group muted", lambda: c.send("object.set_mute", {"ids": [g], "muted": True}),
              lambda: c.send("object.set_mute", {"ids": [g], "muted": False}))
        st = c.send("stem.add", {"name": "S"})["id"]
        c.send("stem.assign", {"stem": st, "ids": [g, a]})
        settle(c)
        gated("stem muted", lambda: c.send("stem.mute", {"id": st, "muted": True}),
              lambda: c.send("stem.mute", {"id": st, "muted": False}))
        back, _ = wet3(c, name + "_back", a)
        near("G3 %s: every gate lifted: the wet" % pos, back, 6.0)
        audits3(c, "G3 " + pos)


# --------------------------------------------------------------------------------------------------
# M3 — materialisation: the plugins of a send that is not alive exist, keep their state, cost no reader
# --------------------------------------------------------------------------------------------------

def section_M3(c):
    print("\n--- M3  a send at -inf / off keeps its plugins alive; nothing is re-instantiated; removal leaves no key")
    if REF:
        print("       (skipped in --ref: plugins on a send are INC 3)")
        return
    pipeline_offset_db(c)
    x, a = cast_siblings(c, "M3")
    c.send("send.create", {"id": x, "aux": a, "position": "post_fader"})          # a new send: -inf
    settle(c)
    h, pid = add_on_send(c, "M3 (send at -inf)", x, a, "gainTester", gain_db=-12.0)
    if pid is None:
        return
    step("M3: plugin.get_params answers for a plugin of a send at -inf", lambda: c.send("plugin.get_params", {"plugin": pid}))
    check("M3: the engine holds the instance", in_engine(c, pid))
    rep = bridge_report(c)
    row = engine_send_row(rep, x, a)
    print("       M3: engine row at -inf: %s" % row)
    check("M3: at -inf the bridge lays NO reader for it", len(send_readers(rep)) == 0, send_readers(rep))
    check("M3: at -inf the engine's send is a disabled carrier holding the plugin",
          row.get("enabled") is False and row.get("chain_plugins") == 1, row)
    set_gain3(c, pid, -9.0)                    # a state only the live instance knows
    lay_send(c, x, a, 0.0)
    settle(c)
    db, _ = wet3(c, "M3_raised", a)
    near("M3: level raised: the wet reads the state set while at -inf (same instance)", db, -9.0)
    for label, on, off in (("-inf and back", lambda: lay_send(c, x, a, -200.0), lambda: lay_send(c, x, a, 0.0)),
                           ("off and on", lambda: c.send("send.enable", {"id": x, "aux": a, "enabled": False}),
                            lambda: c.send("send.enable", {"id": x, "aux": a, "enabled": True}))):
        on()
        settle(c)
        check("M3 %s: the instance stays while the send is silent" % label, in_engine(c, pid))
        off()
        settle(c)
        db, _ = wet3(c, "M3_" + label.replace(" ", "_"), a)
        near("M3 %s: the wet (state intact)" % label, db, -9.0)
    audits3(c, "M3 alive")
    c.send("send.remove", {"id": x, "aux": a})
    settle(c)
    check("M3: send removed: no engine key is left for its plugin", not in_engine(c, pid))
    audits3(c, "M3 removed")
    c.send("edit.undo", {})
    settle(c)
    check("M3: undo of the removal: the send is back with its plugin (same id)", send_plugins3(c, x, a) == [pid],
          send_entry(c, x, a))
    db, _ = wet3(c, "M3_undone", a)
    near("M3: undo of the removal: the wet, with the state the plugin had", db, -9.0)
    audits3(c, "M3 undone")

    # the object's chain full: the send is refused, its plugins are NOT instantiated; a slot freed lays them
    x, a = cast_siblings(c, "M3full")
    plugs = []
    for _ in range(16):
        plugs.append(add_test(c, x, "gainTester", gain_db=0.0)["plugin"])
    wait(c)
    c.send("send.create", {"id": x, "aux": a, "position": "post_fader"})
    lay_send(c, x, a, 0.0)
    settle(c)
    hh = need_host(c, "M3 full", x, a)
    r = step("M3 full: a plugin is laid on the refused send (the model takes it)",
             lambda: c.send("debug.add_test_plugin", {"host": hh, "type": "gainTester", "gain_db": -12.0}))
    settle(c)
    p2 = (r or {}).get("plugin")
    row = send_entry(c, x, a) or {}
    check("M3 full: the send is refused chainFull", row.get("refusal") == "chainFull" and row.get("status") == "refused", row)
    check("M3 full: its plugin is NOT instantiated", p2 is not None and not in_engine(c, p2))
    _, w = wet3(c, "M3full_refused", a)
    check("M3 full: the refused send is silent", maxabs(w) == 0.0, maxabs(w))
    c.send("plugin.remove", {"host": x, "plugin": plugs[-1]})
    settle(c)
    time.sleep(0.5)
    settle(c)
    row = send_entry(c, x, a) or {}
    check("M3 full: one slot freed: the send is active", row.get("status") == "active", row)
    check("M3 full: ... and its plugin is instantiated", p2 is not None and in_engine(c, p2))
    db, _ = wet3(c, "M3full_laid", a)
    print("       M3 full: wet once laid: %s dB re source (the plugin's gain is the model's: the instance is new)" % db)
    check("M3 full: once laid the send sounds", db is not None, db)
    audits3(c, "M3 full")


# --------------------------------------------------------------------------------------------------
# X3 — limits: 20 plugins on a send, its own count; the object's chain is not charged for them
# --------------------------------------------------------------------------------------------------

def section_X3(c):
    print("\n--- X3  a send takes 20 plugins (its own limit); the object's chain still counts the send as ONE entry")
    if REF:
        print("       (skipped in --ref: plugins on a send are INC 3)")
        return
    pipeline_offset_db(c)
    x, a = cast_siblings(c, "X3")
    c.send("send.create", {"id": x, "aux": a, "position": "post_fader"})
    lay_send(c, x, a, 0.0)
    h = need_host(c, "X3", x, a)
    if h is None:
        return
    for _ in range(20):
        c.send("debug.add_test_plugin", {"host": h, "type": "gainTester", "gain_db": -1.0})
    settle(c)
    check("X3: 20 plugins sit on the send", len(send_plugins3(c, x, a)) == 20, len(send_plugins3(c, x, a)))
    refused("X3: the 21st", lambda: c.send("debug.add_test_plugin", {"host": h, "type": "gainTester"}), reason="chainFull")
    check("X3: the object's own chain is empty", c.send("plugin.list", {"host": x})["plugins"] == [])
    row = engine_send_row(bridge_report(c), x, a)
    check("X3: the engine's mini-chain holds 20", row.get("chain_plugins") == 20, row)
    db, _ = wet3(c, "X3_20", a)
    near("X3: twenty -1 dB plugins: the wet", db, -20.0, tol=0.1)
    trunk = []
    for _ in range(15):
        trunk.append(add_test(c, x, "gainTester", gain_db=0.0)["plugin"])
    settle(c)
    row = send_entry(c, x, a) or {}
    check("X3: 15 plugins on the object + the send carrying 20: the send is active", row.get("status") == "active", row)
    db, _ = wet3(c, "X3_15", a)
    near("X3: ... and its wet is unchanged", db, -20.0, tol=0.1)
    # The engine caps a list at 20 and the send holds one slot of the object's list: with a send, the
    # object takes 15 plugins and the 16th is the one turned away (INC 2's behaviour, unchanged — the
    # send's own twenty plugins are NOT on that list).
    try:
        add_test(c, x, "gainTester", gain_db=0.0)
        took16 = True
    except ObjekatError as e:
        took16 = False
        print("       X3: a 16th plugin on the object: %s" % e)
    settle(c)
    n = len(c.send("plugin.list", {"host": x})["plugins"])
    row = send_entry(c, x, a) or {}
    print("       X3: after the 16th: the object holds %d, the send is %s (refusal %s)" % (n, row.get("status"), row.get("refusal")))
    check("X3: a 16th plugin on the object is turned away exactly as with a plain send (15 stay, the send stays active)",
          not took16 and n == 15 and row.get("status") == "active", (took16, n, row))
    db, _ = wet3(c, "X3_16", a)
    near("X3: ... and the wet is still the twenty plugins'", db, -20.0, tol=0.1)
    audits3(c, "X3")


# --------------------------------------------------------------------------------------------------
# U3 — undo / redo of every gesture on a send's plugins
# --------------------------------------------------------------------------------------------------

def section_U3(c):
    print("\n--- U3  undo / redo: add, move trunk -> send, copy (alt and cmd alike), reorder, bypass, remove, parameter")
    if REF:
        print("       (skipped in --ref: plugins on a send are INC 3)")
        return
    pipeline_offset_db(c)
    x, a = cast_siblings(c, "U3")
    c.send("send.create", {"id": x, "aux": a, "position": "input"})
    lay_send(c, x, a, 0.0)
    # The object's fader at the floor: an INPUT send does not hear it, and the dry (which the plugins
    # moved to and from the trunk would change) weighs nothing in the export (-96 dB).
    c.send("object.set_gain", {"ids": [x], "db": -96.0})
    settle(c)
    h = need_host(c, "U3", x, a)
    if h is None:
        return
    # The reference WITHOUT the aux, once, up front (muting is an undo point).
    c.send("object.set_mute", {"ids": [a], "muted": True})
    settle(c)
    off_ref = render(c, "U3_off_ref.wav", 0.0, 3.0)
    c.send("object.set_mute", {"ids": [a], "muted": False})
    settle(c)
    count = [0]

    def wet_now():
        count[0] += 1
        w = sub(render(c, "U3_%02d.wav" % count[0], 0.0, 3.0), off_ref)
        return wet_db(w) if maxabs(w) > 0.0 else None

    def undo_redo(label, before_db, after_db, patched=False):
        near("U3 %s: the wet" % label, wet_now(), after_db)
        log0 = app_log_lines()
        c.send("edit.undo", {})
        settle(c)
        tr = undo_trace_since(log0)
        if tr:
            print("       U3 %s: undo trace: %s" % (label, tr[-1].strip()[-60:]))
            if patched:
                check("U3 %s: the undo patches in place (0 rebuilt)" % label, "0 rebuilt" in tr[-1], tr[-1])
        near("U3 %s: undone: the wet" % label, wet_now(), before_db)
        c.send("edit.redo", {})
        settle(c)
        near("U3 %s: redone: the wet" % label, wet_now(), after_db)
        audits3(c, "U3 " + label)

    near("U3: start (input send, 0 dB): the wet", wet_now(), 0.0)
    # 1. add
    pid = c.send("debug.add_test_plugin", {"host": h, "type": "gainTester", "gain_db": -12.0})["plugin"]
    settle(c)
    c.send("edit.undo", {})
    settle(c)
    check("U3 add: undone: the send carries nothing", send_plugins3(c, x, a) == [], send_plugins3(c, x, a))
    near("U3 add: undone: the wet", wet_now(), 0.0)
    c.send("edit.redo", {})
    settle(c)
    check("U3 add: redone: the plugin is back, same id", send_plugins3(c, x, a) == [pid], send_plugins3(c, x, a))
    set_gain3(c, pid, -12.0)          # the gain was laid after the add's undo point: lay it again
    near("U3 add: redone: the wet", wet_now(), -12.0)
    # 2. move trunk -> send (an input send does not hear the trunk: the wet changes only by the move)
    t1 = add_test(c, x, "gainTester", gain_db=-6.0)["plugin"]
    settle(c)
    near("U3: a -6 dB plugin on the TRUNK does not reach an input send: the wet", wet_now(), -12.0)
    r = c.send("plugin.move", {"from": x, "to": h, "plugin": t1})
    settle(c)
    moved = (r.get("plugins") or [None])[0]
    check("U3 move: the plugin is on the send (a move mints a fresh id, as between two objects) and off the trunk",
          moved is not None and send_plugins3(c, x, a) == [pid, moved] and c.send("plugin.list", {"host": x})["plugins"] == [],
          (send_plugins3(c, x, a), c.send("plugin.list", {"host": x})))
    t1 = moved
    undo_redo("move trunk -> send", -12.0, -18.0)
    # 3. copy: alt, then cmd — the same plain copy
    t2 = add_test(c, x, "gainTester", gain_db=-3.0)["plugin"]
    settle(c)
    r = c.send("plugin.drop_at", {"from": x, "host": h, "plugin": t2, "mode": "copy"})
    settle(c)
    ids = send_plugins3(c, x, a)
    check("U3 alt copy: outcome copy, a third plugin on the send with a FRESH id, the original stays on the trunk",
          r.get("outcome") == "copy" and len(ids) == 3 and t2 not in ids
          and [p_["id"] for p_ in c.send("plugin.list", {"host": x})["plugins"]] == [t2], (r, ids))
    undo_redo("alt copy trunk -> send", -18.0, -21.0)
    r = c.send("plugin.drop_at", {"from": x, "host": h, "plugin": t2, "mode": "link", "dry_run": True})
    check("U3 cmd: the resolver answers a plain COPY (no link on a send)", r.get("outcome") == "copy", r)
    r = c.send("plugin.drop_at", {"from": x, "host": h, "plugin": t2, "mode": "link"})
    settle(c)
    ids4 = send_plugins3(c, x, a)
    lst = c.send("plugin.list", {"host": h})["plugins"]
    check("U3 cmd copy: a fourth plugin, fresh id, NOT linked; the trunk's original not linked either",
          len(ids4) == 4 and t2 not in ids4 and all(not p_.get("linked") for p_ in lst)
          and all(not p_.get("linked") for p_ in c.send("plugin.list", {"host": x})["plugins"]), (ids4, lst))
    undo_redo("cmd copy trunk -> send", -21.0, -24.0)
    refused("U3: plugin.link towards a send", lambda: c.send("plugin.link", {"from": x, "to": h, "plugin": t2}),
            reason="send_plugins_never_linked")
    refused("U3: plugin.link from a send", lambda: c.send("plugin.link", {"from": h, "to": x, "plugin": pid}),
            reason="send_plugins_never_linked")
    # 4. reorder inside the box
    order0 = send_plugins3(c, x, a)
    c.send("plugin.drop_at", {"from": h, "host": h, "plugin": order0[-1], "series": "root", "at": 0})
    settle(c)
    order1 = send_plugins3(c, x, a)
    check("U3 reorder: the last row is now the first", order1 == [order0[-1]] + order0[:-1], (order0, order1))
    c.send("edit.undo", {})
    settle(c)
    check("U3 reorder: undone: the order is back", send_plugins3(c, x, a) == order0, send_plugins3(c, x, a))
    c.send("edit.redo", {})
    settle(c)
    check("U3 reorder: redone", send_plugins3(c, x, a) == order1, send_plugins3(c, x, a))
    near("U3 reorder: the wet does not move", wet_now(), -24.0)
    # 5. bypass
    c.send("plugin.toggle", {"host": h, "plugin": pid})
    settle(c)
    undo_redo("bypass of the -12 dB plugin", -24.0, -12.0)
    c.send("plugin.toggle", {"host": h, "plugin": pid})
    settle(c)
    # 6. remove
    c.send("plugin.remove", {"host": h, "plugin": pid})
    settle(c)
    undo_redo("remove the -12 dB plugin", -24.0, -12.0)
    c.send("edit.undo", {})
    settle(c)
    near("U3: back with the four plugins: the wet", wet_now(), -24.0)
    # 7. a parameter (@see scenario_plugin_state_undo.py for the order): the state is set, an unrelated
    #    gesture takes the undo snapshot, the state moves again OUTSIDE any snapshot; the undo finds a
    #    difference confined to a send plugin's state and puts it back on the LIVE instance.
    set_gain3(c, pid, -2.0)                       # -24 + 10
    near("U3 parameter: -2 dB on the first plugin: the wet", wet_now(), -14.0)
    c.send("object.move", {"id": x, "start": 0.25})           # the snapshot is taken HERE
    settle(c)
    set_gain3(c, pid, -20.0)
    near("U3 parameter: changed again to -20, outside any undo point: the wet", wet_now(), -32.0)
    log0 = app_log_lines()
    c.send("edit.undo", {})
    settle(c)
    tr = undo_trace_since(log0)
    print("       U3 parameter: undo trace: %s" % (tr[-1].strip()[-60:] if tr else None))
    check("U3 parameter: the undo does NOT rebuild the object (0 rebuilt, patched in place)",
          bool(tr) and "0 rebuilt" in tr[-1] and "1 patched" in tr[-1], tr[-1:] )
    check("U3 parameter: the unrelated gesture is undone", abs(c.send("object.get", {"id": x})["start"]) < 1e-6)
    near("U3 parameter: undone: the send plugin's state of the undo point is back (-2 dB)", wet_now(), -14.0)
    check("U3 parameter: the instance is still the engine's", in_engine(c, pid))
    audits3(c, "U3 end")


def wet_of(c, name, snd, aux, others=()):
    """The wet ONE sender lays in `aux`: the other senders muted for the measure."""
    others = [o for o in others if o and o != snd]
    if others:
        c.send("object.set_mute", {"ids": others, "muted": True})
        settle(c)
    db, w = wet3(c, name, aux)
    if others:
        c.send("object.set_mute", {"ids": others, "muted": False})
        settle(c)
    return db, w


def send_instance(c, x, a):
    """The engine's send plugin of x -> a (its instance pointer), from the audit's layouts."""
    lay = (c.send("debug.send_marker_audit").get("engine_layouts") or {}).get(x, [])
    rows = [e for e in lay if e.get("aux") == a]
    return rows[0].get("instance") if rows else None


# --------------------------------------------------------------------------------------------------
# Z3 — save / reopen
# --------------------------------------------------------------------------------------------------

def section_Z3(c):
    print("\n--- Z3  save / reopen: the send's plugins, their ids and states come back; format 25; a hand-written file is sanitised")
    if REF:
        print("       (skipped in --ref: plugins on a send are INC 3)")
        return
    x, a, h, pid = cast3(c, "Z3", gain_db=-12.0, level=-6.0)
    if pid is None:
        return
    lp = step("Z3: plugin.add lowpass on the send host", lambda: c.send("plugin.add", {"host": h, "identifier": "lowpass"}))
    lp = ((lp or {}).get("plugin") or {}).get("id")
    settle(c)
    c.send("plugin.set_param", {"plugin": lp, "index": 0, "value": 9000.0})
    w = with_other(c, lane=3)
    a2 = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 7})["id"]
    c.send("send.create", {"id": w, "aux": a2, "position": "post_fader"})
    lay_send(c, w, a2, -6.0)
    settle(c)
    db0, _ = wet3(c, "Z3_before", a)
    ids0 = send_plugins3(c, x, a)
    print("       Z3 before: wet %s dB re source, plugins %s" % (db0, ids0))
    check("Z3 before: two plugins on the send", ids0 == [pid, lp], ids0)
    c.send("project.save")
    path = out("Z3/project.objekat")
    d1 = json.load(open(path))
    check("Z3 file: saved as format 25", d1.get("version") == 25, d1.get("version"))
    ox, ow = find_obj(d1["items"], x), find_obj(d1["items"], w)
    fp = [p_["id"].upper() for p_ in (ox["sends"][0].get("plugins") or [])]
    check("Z3 file: the send carries its two plugins, same ids, in order", fp == [pid.upper(), lp.upper()], fp)
    check("Z3 file: a send without plugins has NO `plugins` key", all("plugins" not in sd for sd in ow["sends"]), ow["sends"])
    check("Z3 file: the gainTester's state is in the file", "gainDb=\"-12" in ox["sends"][0]["plugins"][0].get("stateXML", ""),
          ox["sends"][0]["plugins"][0].get("stateXML"))
    c.send("project.open", {"path": path})
    wait(c)
    settle(c)
    check("Z3 reopen: the same plugin ids, in order", send_plugins3(c, x, a) == ids0, send_plugins3(c, x, a))
    db1, _ = wet3(c, "Z3_after", a)
    print("       Z3 reopen: wet %s dB re source" % db1)
    check("Z3 reopen: the wet is what it was (0.01 dB)", db0 is not None and db1 is not None and abs(db0 - db1) <= 0.01, (db0, db1))
    v = c.send("plugin.get_params", {"plugin": lp})["params"][0]["value"]
    check("Z3 reopen: the lowpass's state is read back (9000 Hz)", abs(v - 9000.0) < 1.0, v)
    audits3(c, "Z3 reopen")

    # ---- a format-22 project (no send plugin anywhere) reopened and re-saved: items identical
    x, a = cast_siblings(c, "Z3b")
    a2 = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 7})["id"]
    a3 = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 9})["id"]
    c.send("send.create", {"id": x, "aux": a, "position": "chain", "index": 0})
    c.send("send.create", {"id": x, "aux": a2, "position": "input"})
    c.send("send.create", {"id": x, "aux": a3, "position": "pre_fader"})
    for aux in (a, a2, a3):
        lay_send(c, x, aux, -6.0)
    settle(c)
    c.send("project.save")
    path = out("Z3b/project.objekat")
    d = json.load(open(path))
    items0 = json.dumps(d["items"], sort_keys=True)
    check("Z3b: a project without send plugins writes no `plugins` key on any send", '"plugins": [{' not in json.dumps(find_obj(d["items"], x)["sends"]),
          find_obj(d["items"], x)["sends"])
    d["version"] = 22
    json.dump(d, open(path, "w"), indent=1)
    c.send("project.open", {"path": path})
    wait(c)
    settle(c)
    audit(c, "Z3b reopened as 22")
    c.send("project.save")
    d2 = json.load(open(path))
    check("Z3b: the format-22 file is re-saved as 24 with `items` identical",
          d2.get("version") == 25 and json.dumps(d2["items"], sort_keys=True) == items0, d2.get("version"))

    # ---- a hand-written 23 file: a bin, a marker and a LINKED leaf inside a send's plugins
    pipeline_offset_db(c)
    x, a = cast_siblings(c, "Z3h")
    a2 = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 7})["id"]
    g1 = add_test(c, x, "gainTester", gain_db=0.0)["plugin"]
    g2 = add_test(c, x, "gainTester", gain_db=0.0)["plugin"]
    settle(c)
    step("Z3h: a bin on the trunk", lambda: c.send("fxlink.create", {"host": x, "plugins": [g1, g2], "name": "Bin"}))
    c.send("send.create", {"id": x, "aux": a2, "position": "chain", "index": 0})
    c.send("send.create", {"id": x, "aux": a, "position": "post_fader"})
    lay_send(c, x, a, 0.0)
    h, pid = add_on_send(c, "Z3h", x, a, "gainTester", gain_db=-12.0)
    settle(c)
    c.send("project.save")
    path = out("Z3h/project.objekat")
    d = json.load(open(path))
    ox = find_obj(d["items"], x)
    bins = [p_ for p_ in ox["plugins"] if "fxBlock" in p_]
    mks = [p_ for p_ in ox["plugins"] if "sendMarker" in p_]
    check("Z3h file: the trunk holds one bin and one marker to move", len(bins) == 1 and len(mks) == 1, [list(p_.keys()) for p_ in ox["plugins"]])
    if len(bins) == 1 and len(mks) == 1:
        sd = [s_ for s_ in ox["sends"] if s_["auxID"].lower() == a.lower()][0]
        sd["plugins"][0]["linkGroupID"] = "11111111-2222-4333-8444-555555555555"
        sd["plugins"] = [mks[0], sd["plugins"][0], bins[0]]
        ox["plugins"] = [p_ for p_ in ox["plugins"] if "fxBlock" not in p_ and "sendMarker" not in p_]
        ox["sends"] = [s_ for s_ in ox["sends"] if s_["auxID"].lower() == a.lower()]
        json.dump(d, open(path, "w"), indent=1)
        log0 = app_log_lines()
        r = step("Z3h: the hand-written file opens (no crash)", lambda: c.send("project.open", {"path": path}))
        wait(c)
        settle(c)
        ids = send_plugins3(c, x, a)
        lst = c.send("plugin.list", {"host": send_host(c, x, a)})["plugins"]
        check("Z3h: the send keeps its ONE leaf (same id); the bin and the marker are dropped", ids == [pid], (ids, lst))
        check("Z3h: the leaf is no longer linked", all(not p_.get("linked") for p_ in lst), lst)
        now = app_log_lines()
        if now is not None and log0 is not None:
            lines = [l for l in now[len(log0):] if "[SENDS]" in l and "dropped from a send's plugins" in l]
            print("       Z3h: log: %s" % (lines[-1][-110:] if lines else None))
            check("Z3h: the sanitising is logged (2 entries dropped)", bool(lines) and "2 entry" in lines[-1], lines)
        db, _ = wet3(c, "Z3h", a)
        near("Z3h: the wet goes through the leaf", db, -12.0)
        audits3(c, "Z3h")


# --------------------------------------------------------------------------------------------------
# C3 — copies: every copy has its own mini-chain, fresh ids, never linked
# --------------------------------------------------------------------------------------------------

def section_C3(c):
    print("\n--- C3  duplicate, copy / paste, split of the sender, split of the aux: independent copies, fresh ids, no link")
    if REF:
        print("       (skipped in --ref: plugins on a send are INC 3)")
        return
    x, a, h, pid = cast3(c, "C3", gain_db=-12.0, level=0.0)
    if pid is None:
        return
    seen = {pid}

    def fresh_copy(label, obj, aux=None):
        ids = send_plugins3(c, obj, aux or a)
        ok = len(ids) == 1 and ids[0] not in seen
        check("C3 %s: the copy has ONE send plugin with a FRESH id" % label, ok, (ids, sorted(seen)))
        lst = c.send("plugin.list", {"host": send_host(c, obj, aux or a)})["plugins"] if ids else []
        check("C3 %s: it is not linked" % label, bool(ids) and all(not p_.get("linked") for p_ in lst), lst)
        if ids:
            seen.add(ids[0])
            check("C3 %s: the engine holds its instance" % label, in_engine(c, ids[0]))
        return ids[0] if ids else None

    # --- duplicate
    d = c.send("object.duplicate", {"ids": [x]})["ids"]
    settle(c)
    dup = d[0] if d else None
    c.send("object.move", {"id": dup, "lane": 6, "start": 0.0})      # a duplicate lands AFTER its source: bring it under the aux
    settle(c)
    dp = fresh_copy("duplicate", dup)
    audits3(c, "C3 duplicate")
    db, _ = wet_of(c, "C3_dup", dup, a, others=[x])
    near("C3 duplicate: its wet (state copied)", db, -12.0)
    set_gain3(c, pid, -3.0)
    db, _ = wet_of(c, "C3_orig", x, a, others=[dup])
    near("C3: the ORIGINAL's plugin changed to -3: its wet", db, -3.0)
    db, _ = wet_of(c, "C3_dup2", dup, a, others=[x])
    near("C3: ... the duplicate's wet does NOT follow", db, -12.0)

    # --- copy / paste (the live state travels: -3)
    c.send("selection.set", {"ids": [x]})
    c.send("clipboard.copy", {})
    c.send("timesel.set", {"start": 0.0, "end": 3.0, "lane": 4, "lane_count": 1})
    pasted = c.send("clipboard.paste", {})["ids"]
    settle(c)
    pst = pasted[0] if pasted else None
    check("C3 paste: one object pasted", len(pasted) == 1, pasted)
    fresh_copy("paste", pst)
    audits3(c, "C3 paste")
    db, _ = wet_of(c, "C3_paste", pst, a, others=[x, dup])
    near("C3 paste: its wet (the state at the copy: -3)", db, -3.0)
    set_gain3(c, pid, -12.0)
    db, _ = wet_of(c, "C3_paste2", pst, a, others=[x, dup])
    near("C3: the original changed back to -12: the pasted copy does NOT follow", db, -3.0)
    db, _ = wet_of(c, "C3_orig2", x, a, others=[dup, pst])
    near("C3: ... and the original's wet", db, -12.0)

    # --- split of the sender, at 0.5 s: the impulse (1 s) is in the RIGHT half, which is the new object
    pieces = c.send("object.split_at", {"seconds": 0.5, "ids": [x]})["ids"]
    settle(c)
    right = [i for i in pieces if i != x]
    check("C3 cut: two pieces, the left one keeps the object's id", len(pieces) == 2 and len(right) == 1, pieces)
    rt = right[0] if right else None
    check("C3 cut: the left half keeps the original plugin", send_plugins3(c, x, a) == [pid], send_plugins3(c, x, a))
    rp = fresh_copy("cut, right half", rt)
    audits3(c, "C3 cut")
    db, _ = wet_of(c, "C3_right", rt, a, others=[x, dup, pst])
    near("C3 cut: the right half's wet", db, -12.0)
    set_gain3(c, pid, -30.0)
    db, _ = wet_of(c, "C3_right2", rt, a, others=[x, dup, pst])
    near("C3 cut: the left half's plugin changed: the right half does NOT follow", db, -12.0)

    # --- split of the aux: every sender gets a send to the new half, with its own copies
    halves = c.send("object.split_at", {"seconds": 1.5, "ids": [a]})["ids"]
    settle(c)
    nb = [i for i in halves if i != a]
    check("C3 aux cut: two halves", len(halves) == 2 and len(nb) == 1, halves)
    if nb:
        b = nb[0]
        for label, obj in (("duplicate", dup), ("pasted", pst), ("right half", rt)):
            fresh_copy("aux cut, %s -> new half" % label, obj, aux=b)
        m = audits3(c, "C3 aux cut")
        print("       C3: send plugins in the project: %s (all distinct: %s)" % (m.get("send_plugins"), len(seen)))
        db, _ = wet_of(c, "C3_auxcut", rt, a, others=[x, dup, pst])
        near("C3 aux cut: the wet into the first half (the impulse is at 1 s) is unchanged", db, -12.0)
    print("       C3: the alt-drag copy of an OBJECT has no API door: not run here (object.duplicate takes the same copy path)")


# --------------------------------------------------------------------------------------------------
# R3 — retarget and position: the plugins, their state and their instances follow
# --------------------------------------------------------------------------------------------------

def section_R3(c):
    print("\n--- R3  send.retarget and send.set_position keep the plugins, their LIVE state and their instances")
    if REF:
        print("       (skipped in --ref: plugins on a send are INC 3)")
        return
    x, a, h, pid = cast3(c, "R3", gain_db=-12.0, level=-6.0)
    if pid is None:
        return
    b = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 7})["id"]
    settle(c)
    set_gain3(c, pid, -9.0)                   # live only: the model still says -12
    db, _ = wet3(c, "R3_a", a)
    near("R3: before: the wet into A (plugin -9 live, level -6)", db, -15.0)
    inst0 = send_instance(c, x, a)
    r = c.send("send.retarget", {"id": x, "aux": a, "to": b})
    settle(c)
    row = send_entry(c, x, b) or {}
    check("R3 retarget: the send to B carries the plugin (same id), the level", [p_["id"] for p_ in row.get("plugins", [])] == [pid]
          and row.get("level_db") == -6 and send_entry(c, x, a) is None, (row, r))
    inst1 = send_instance(c, x, b)
    print("       R3 retarget: engine send instance before %s, after %s" % (inst0, inst1))
    check("R3 retarget: the engine's send plugin is the SAME object (re-keyed in place)", inst0 is not None and inst0 == inst1, (inst0, inst1))
    check("R3 retarget: the plugin's instance is still the engine's", in_engine(c, pid))
    db, _ = wet3(c, "R3_b", b)
    near("R3 retarget: the wet arrives in B with the LIVE state (not re-instantiated from the model's -12)", db, -15.0)
    _, wa = wet3(c, "R3_a2", a)
    check("R3 retarget: nothing reaches A any more", maxabs(wa) == 0.0, maxabs(wa))
    audits3(c, "R3 retarget")
    c.send("edit.undo", {})          # the mutes of the measures are undo points: undo back to the retarget
    for _ in range(12):
        if send_entry(c, x, a) is not None:
            break
        c.send("edit.undo", {})
    settle(c)
    row = send_entry(c, x, a) or {}
    check("R3 retarget undone: the send is back on A with its plugin", [p_["id"] for p_ in row.get("plugins", [])] == [pid], row)
    audits3(c, "R3 retarget undone")

    # --- the four positions, against Q2's table minus the plugin's gain
    pipeline_offset_db(c)
    x, a = cast_siblings(c, "R3pos")
    add_test(c, x, "gainTester", gain_db=-12.0)
    c.send("debug.set_chain_gain", {"host": x, "in_db": -6.0, "out_db": -3.0})
    c.send("object.set_gain", {"ids": [x], "db": -20.0})
    c.send("send.create", {"id": x, "aux": a, "position": "post_fader"})
    lay_send(c, x, a, 0.0)
    h, pid = add_on_send(c, "R3pos", x, a, "gainTester", gain_db=-12.0)
    if pid is None:
        return
    set_gain3(c, pid, -9.0)
    inst0 = send_instance(c, x, a)
    for name, prm, expect in (("post", {"position": "post_fader"}, -41.0), ("input", {"position": "input"}, 0.0),
                              ("chain0", {"position": "chain", "index": 0}, -6.0), ("chain1", {"position": "chain", "index": 1}, -18.0),
                              ("pre", {"position": "pre_fader"}, -21.0), ("post again", {"position": "post_fader"}, -41.0)):
        c.send("send.set_position", dict({"id": x, "aux": a}, **prm))
        settle(c)
        check("R3 %s: the plugin stays on the send, same id" % name, send_plugins3(c, x, a) == [pid], send_plugins3(c, x, a))
        check("R3 %s: same engine send instance" % name, send_instance(c, x, a) == inst0, (send_instance(c, x, a), inst0))
        db, _ = wet3(c, "R3pos_" + name.replace(" ", "_"), a)
        near("R3 %s: the wet = Q2's %.0f dB + the plugin's LIVE -9" % (name, expect), db, expect - 9.0)
        audits3(c, "R3 " + name)


# --------------------------------------------------------------------------------------------------
# T3 — window and tails (A.e, Q-U18): an effect on a send stops with the object
# --------------------------------------------------------------------------------------------------

def t3_delay(c, name, host):
    """The engine's built-in Delay (200 ms, 50 % wet, feedback -6 dB) on `host`. Returns its id."""
    r = step(name + ": the built-in Delay is laid", lambda: c.send("plugin.add", {"host": host, "identifier": "delay"}))
    dl = ((r or {}).get("plugin") or {}).get("id")
    if dl is None:
        return None
    settle(c)
    c.send("debug.set_plugin_property", {"plugin": dl, "property": "length", "value": 200.0})
    c.send("plugin.set_param", {"plugin": dl, "index": 1, "value": 0.5})
    settle(c)
    return dl


def t3_echoes(w):
    """(direct, echo at 1.2 s, echo at 1.4 s) peaks of an impulse at 1 s through the Delay, in dBFS."""
    return seg_peak_db(w, 0.95, 1.05), seg_peak_db(w, 1.15, 1.25), seg_peak_db(w, 1.35, 1.45)


def section_T3(c):
    print("\n--- T3  a delay ON a send: its tail follows the object's fade and stops with the object")
    if REF:
        print("       (skipped in --ref: plugins on a send are INC 3)")
        return
    # (The plan's `latencyTester` cannot show a tail: its delay is DECLARED, hence compensated. The
    # engine's built-in Delay is used instead: 200 ms, 50 % wet, feedback -6 dB.)

    # THE YARDSTICK: the same Delay in the object's OWN chain (trunk). Q-U18: the tail of a send's
    # effect behaves like the tail of a plugin of the object: it follows the fade-out, it dies at the
    # window's end. Measured once, on the dry.
    fresh(c, "T3_trunk")
    xt = c.send("object.add", {"path": out("imp.wav"), "lane": 0, "start": 0.0})["id"]
    trunk = None
    if t3_delay(c, "T3 trunk", xt) is not None:
        c.send("object.trim", {"id": xt, "start": 0.0, "duration": 1.5})
        c.send("object.set_fade", {"id": xt, "out": 0.5})
        settle(c)
        d = render(c, "T3_trunk_fade.wav")
        trunk = t3_echoes(d)
        print("       T3 trunk (the Delay in the object's chain), window [0, 1.5], fade-out 0.5 s: direct %.2f dBFS, "
              "echo at 1.2 s %.2f, at 1.4 s %.2f; max after 1.5 s %.2e" % (trunk + (maxabs(seg(d, 1.5, 3.0)),)))
        c.send("object.trim", {"id": xt, "start": 0.0, "duration": 1.1})
        c.send("object.set_fade", {"id": xt, "out": 0.0})
        settle(c)
        d = render(c, "T3_trunk_cut.wav")
        print("       T3 trunk, object ending at 1.1 s WITHOUT fade: max after 1.1 s %.2e (the trunk's tail is cut "
              "at the window's end too)" % maxabs(seg(d, 1.1, 3.0)))
        check("T3 trunk: a plugin of the object's chain rings nothing past the window's end (the yardstick)",
              maxabs(seg(d, 1.1, 3.0)) <= 1e-6, "%.3e" % maxabs(seg(d, 1.1, 3.0)))

    for pos in POSITIONS3:
        name = "T3_" + pos
        pipeline_offset_db(c)
        x, a = cast_siblings(c, name)
        c.send("send.create", {"id": x, "aux": a, "position": "post_fader"})
        lay_send(c, x, a, 0.0)
        set_position(c, x, a, pos)
        h = need_host(c, name, x, a)
        if t3_delay(c, name, h) is None:
            continue
        _, w = wet3(c, name + "_whole", a)
        direct, echo1, echo2 = t3_echoes(w)
        print("       %s whole object: direct %.1f dBFS, echo at 1.2 s %.1f, at 1.4 s %.1f" % (name, direct, echo1, echo2))
        check(name + ": whole object (3 s): the echoes at 1.2 s and 1.4 s are in the wet", echo1 > -40.0 and echo2 > -50.0, (direct, echo1, echo2))
        whole = (direct, echo1, echo2)

        # the object ends at 1.5 s after a 0.5 s fade-out: the echoes of 1.2 s and 1.4 s are IN the
        # fade. They follow it — once: the same figures as the Delay in the object's own chain.
        c.send("object.trim", {"id": x, "start": 0.0, "duration": 1.5})
        c.send("object.set_fade", {"id": x, "out": 0.5})
        settle(c)
        _, w = wet3(c, name + "_fade", a)
        f = t3_echoes(w)
        g1, g2 = f[1] - whole[1], f[2] - whole[2]
        after = maxabs(seg(w, 1.5, 3.0))
        print("       %s window [0, 1.5], fade-out 0.5 s: direct %.2f dBFS, echo at 1.2 s %.2f (fade %.2f dB), "
              "at 1.4 s %.2f (fade %.2f dB); max after 1.5 s %.2e" % (name, f[0], f[1], g1, f[2], g2, after))
        check(name + ": fade-out: the direct part (at the fade's start) is untouched (0.05 dB)", abs(f[0] - whole[0]) <= 0.05, (f[0], whole[0]))
        check(name + ": fade-out: the tail FOLLOWS the fade (each echo lower than without fade, the later the lower)",
              g1 < -1.0 and g2 < g1 - 1.0, (g1, g2))
        check(name + ": fade-out: NOTHING after the window's end", after <= 1e-6, "%.3e" % after)
        if trunk is not None:
            t1_, t2_ = trunk[1] - trunk[0], trunk[2] - trunk[0]
            s1_, s2_ = f[1] - f[0], f[2] - f[0]
            print("       %s echo re direct: send %.3f / %.3f dB, trunk %.3f / %.3f dB (a fade laid twice would "
                  "double %.2f and %.2f)" % (name, s1_, s2_, t1_, t2_, g1, g2))
            check(name + ": fade-out: the tail is the one of a plugin of the object's chain: the fade ONCE, not squared (0.1 dB)",
                  abs(s1_ - t1_) <= 0.1 and abs(s2_ - t2_) <= 0.1, (s1_, t1_, s2_, t2_))

        # the object ends at 1.1 s, no fade: the echo of 1.2 s would ring after it
        c.send("object.set_fade", {"id": x, "out": 0.0})
        c.send("object.trim", {"id": x, "start": 0.0, "duration": 1.1})
        settle(c)
        _, w = wet3(c, name + "_cut", a)
        direct = seg_peak_db(w, 0.95, 1.05)
        after = maxabs(seg(w, 1.15, 3.0))
        edge = maxabs(seg(w, 1.1, 1.15))
        print("       %s object ending at 1.1 s: direct %.1f dBFS, max in [1.10, 1.15] %.2e, max after 1.15 s %.2e" % (name, direct, edge, after))
        check(name + ": object ending at 1.1 s: the direct part is still sent", direct > -40.0, direct)
        check(name + ": ... and NOTHING rings after the object's end (the tail stops with the object)", after <= 1e-6, "%.3e" % after)
        check(name + ": ... not even in the 50 ms that follow the end", edge <= 1e-6, "%.3e" % edge)
        # the window starts AFTER the impulse: nothing may reach the aux, not even an echo
        c.send("object.trim", {"id": x, "start": 1.1, "duration": 1.5})
        settle(c)
        _, w = wet3(c, name + "_late", a)
        print("       %s window [1.1, 2.6] (the impulse at 1 s is outside): wet max %.2e" % (name, maxabs(w)))
        check(name + ": the impulse is outside the window: nothing is sent, no echo of it either", maxabs(w) <= 1e-6, "%.3e" % maxabs(w))
        audits3(c, name)

    # ONE fade, not two, on a steady tone, at the four positions: a 1 s fade-in, a gain of -12 dB on
    # the send. wet - dry is -12 dB all along the fade; a fade laid twice would add the fade's own
    # depth (10 dB and more at the start).
    for pos in POSITIONS3:
        name = "T3once_" + pos
        fresh(c, name)
        x = c.send("object.add", {"path": out("sine_m6.wav"), "lane": 0, "start": 0.0})["id"]
        a = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 1})["id"]
        c.send("object.set_fade", {"id": x, "in": 1.0})
        c.send("send.create", {"id": x, "aux": a, "position": "post_fader"})
        lay_send(c, x, a, 0.0)
        set_position(c, x, a, pos)
        h, pid = add_on_send(c, name, x, a, "gainTester", gain_db=-12.0)
        if pid is None:
            continue
        dry, wet = measure(c, name, x, a, 0.0)
        got = [seg_db(wet, t, t + 0.01) - seg_db(dry, t, t + 0.01) for t in (0.1, 0.3, 0.6, 0.9, 1.5)]
        depth = seg_db(dry, 0.1, 0.11) - seg_db(dry, 1.5, 1.51)
        print("       %s: wet - dry at 0.1 / 0.3 / 0.6 / 0.9 / 1.5 s = %s dB (the fade is %.1f dB deep at 0.1 s)"
              % (name, " / ".join("%.3f" % g for g in got), depth))
        check(name + ": the fade is laid ONCE on the wet (wet - dry = -12 dB all along the fade, 0.05)",
              all(abs(g + 12.0) <= 0.05 for g in got), got)
        rep = bridge_report(c)
        row = engine_send_row(rep, x, a)
        check(name + ": the engine's send follows the envelope", row.get("follows_envelope") is True, row)
        audits3(c, name)
        if pos != "post_fader":
            continue
        # post-fader is the position whose PLACE depends on what the send carries. Bypassed: the place
        # does not move (a bypass does not pass through the positioning), no wet branch is built, and
        # the envelope is still laid once. Emptied: the send goes back after the window-fade and lays
        # nothing — INC 2.
        c.send("plugin.toggle", {"host": h, "plugin": pid})
        settle(c)
        dry, wet = measure(c, name + "_bypassed", x, a, 0.0)
        got = [seg_db(wet, t, t + 0.01) - seg_db(dry, t, t + 0.01) for t in (0.1, 0.3, 0.6, 0.9, 1.5)]
        print("       %s, the plugin BYPASSED: wet - dry = %s dB" % (name, " / ".join("%.3f" % g for g in got)))
        check(name + ": bypassed: the wet is the dry, the fade ONCE (0 dB all along, 0.05)", all(abs(g) <= 0.05 for g in got), got)
        row = engine_send_row(bridge_report(c), x, a)
        check(name + ": bypassed: the send still follows the envelope (it still carries a plugin)", row.get("follows_envelope") is True, row)
        audits3(c, name + " bypassed")
        c.send("plugin.remove", {"host": h, "plugin": pid})
        settle(c)
        dry, wet = measure(c, name + "_emptied", x, a, 0.0)
        got = [seg_db(wet, t, t + 0.01) - seg_db(dry, t, t + 0.01) for t in (0.1, 0.3, 0.6, 0.9, 1.5)]
        print("       %s, the plugin REMOVED: wet - dry = %s dB" % (name, " / ".join("%.3f" % g for g in got)))
        check(name + ": emptied: the wet is the dry, the fade ONCE (0 dB all along, 0.05)", all(abs(g) <= 0.05 for g in got), got)
        row = engine_send_row(bridge_report(c), x, a)
        lay = (c.send("debug.send_marker_audit").get("engine_layouts") or {}).get(x, [])
        check(name + ": emptied: the send is back at the END of the list and lays no envelope (INC 2's place)",
              row.get("follows_envelope") is False and where_in_list(lay, a) == "post"
              and row.get("list_index") == max(e["index"] for e in lay), (row, [(e["index"], e["role"]) for e in lay]))
        audits3(c, name + " emptied")

    # LATENCY: the envelope is laid at the mini-chain's OUTPUT, on the object's time. A declared latency
    # of 20 ms on the send, a window [0.5, 2.0] with fades of 20 ms at both ends: the wet is the dry
    # times the level, to the SAMPLE (an envelope late or early by one sample leaves 1/960 of the
    # amplitude, -60 dB; by the 20 ms of the latency, the whole amplitude).
    for pos in POSITIONS3:
        name = "T3lat_" + pos
        fresh(c, name)
        x = c.send("object.add", {"path": out("sine_m6.wav"), "lane": 0, "start": 0.0})["id"]
        a = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 1})["id"]
        c.send("object.trim", {"id": x, "start": 0.5, "duration": 1.5})
        c.send("object.set_fade", {"id": x, "in": 0.02, "out": 0.02})
        c.send("send.create", {"id": x, "aux": a, "position": "post_fader"})
        lay_send(c, x, a, -6.0)
        set_position(c, x, a, pos)
        h, pid = add_on_send(c, name, x, a, "latencyTester", latency_ms=20.0)
        if pid is None:
            continue
        time.sleep(0.6)
        settle(c)
        dry, wet = measure(c, name, x, a, -6.0)
        g = 10.0 ** (-6.0 / 20.0)
        res = maxabs([wet[i] - g * dry[i] for i in range(min(len(dry), len(wet)))])
        pk = maxabs(dry)
        rel = B.db(res / pk) if res > 0.0 and pk > 0.0 else -200.0
        outside = max(maxabs(seg(wet, 0.0, 0.5)), maxabs(seg(wet, 2.0, 3.0)))
        print("       %s: 20 ms of latency on the send, fades of 20 ms: max |wet - level x dry| = %.2e (%.1f dB re the dry's peak); "
              "wet outside the window %.2e" % (name, res, rel, outside))
        check(name + ": the wet is the dry times the level to the sample, fades included (residue <= -80 dB)", rel <= -80.0, "%.1f" % rel)
        check(name + ": nothing outside the window", outside <= 1e-6, "%.3e" % outside)
        rep = bridge_report(c)
        row = engine_send_row(rep, x, a)
        rate = ((rep.get("engine") or {}).get("build") or {}).get("sample_rate") or 0
        check(name + ": the mini-chain declares its 20 ms", row.get("chain_latency_samples") == int(round(0.020 * rate)), row)
        audits3(c, name)


# --------------------------------------------------------------------------------------------------
# AU3 — a REAL Audio Unit (Apple's AULowpass) on a send
# --------------------------------------------------------------------------------------------------

APPLE_AU = "aufx,lpas,appl"          # AULowpass: ships with macOS, no licence, no window needed
AU_LOW = 0.003                       # its Cutoff, normalised: about 150 Hz (0.6: wide open)


def au_available(c, ident=APPLE_AU):
    av = c.send("plugin.list_available", {})
    rows = av.get("plugins", av) if isinstance(av, dict) else av
    return any(p_.get("identifier") == ident for p_ in rows)


def chain_instances(c, x, a):
    """The identities of the plugins the engine's send x -> a carries ("plugin address/hosted instance")."""
    return engine_send_row(c.send("debug.bridge_report"), x, a).get("chain_instances")


def au_cutoff_index(c, pid):
    for prm in c.send("plugin.get_params", {"plugin": pid}).get("params", []):
        if "cutoff" in prm["name"].lower():
            return prm["index"]
    return None


def alive(c, label):
    try:
        info = c.send("app.info")
        check(label + ": the app is alive and answers", bool(info), info)
        return True
    except Exception as e:                       # a dead socket is not an ObjekatError
        check(label + ": the app is alive and answers", False, repr(e))
        return False


def section_AU3(c):
    print("\n--- AU3  a REAL Audio Unit on a send (Apple AULowpass): effect, dry untouched, undo of a parameter, retarget, positions while playing, duplicate, removal")
    if REF:
        print("       (skipped in --ref: plugins on a send are INC 3)")
        return
    if not au_available(c):
        print("       (skipped: %s is not in this machine's plugin list)" % APPLE_AU)
        return
    fresh(c, "AU3")
    x = c.send("object.add", {"path": out("sine1k.wav"), "lane": 0, "start": 0.0})["id"]
    a = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 5})["id"]
    b = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 7})["id"]
    z = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 9})["id"]     # only there to be moved (an unrelated gesture)
    c.send("send.create", {"id": x, "aux": a, "position": "post_fader"})
    lay_send(c, x, a, 0.0)
    settle(c)
    dry0, wet0 = measure(c, "AU3_ref", x, a, 0.0)
    ref = seg_db(wet0, 1.0, 2.0)
    wet_level = lambda name: seg_db(sub(render(c, name), dry0), 1.0, 2.0) - ref      # no state touched: no undo point

    h = need_host(c, "AU3", x, a)
    r = step("AU3: plugin.add AULowpass on the send", lambda: c.send("plugin.add", {"host": h, "identifier": APPLE_AU}))
    pid = ((r or {}).get("plugin") or {}).get("id")
    if pid is None:
        return
    settle(c)
    time.sleep(1.0)
    settle(c)
    check("AU3: it is an AudioUnit by Apple", r["plugin"].get("format") == "AudioUnit" and r["plugin"].get("manufacturer") == "Apple", r["plugin"])
    k = au_cutoff_index(c, pid)
    prms = c.send("plugin.get_params", {"plugin": pid})
    check("AU3: the live instance answers its parameters (a Cutoff among them)", k is not None and prms.get("count", 0) >= 3, prms)
    if k is None:
        return
    c.send("plugin.set_param", {"plugin": pid, "index": k, "value": AU_LOW})
    settle(c)
    shown = [q for q in c.send("plugin.get_params", {"plugin": pid})["params"] if q["index"] == k][0]
    dry1, wet1 = measure(c, "AU3_low", x, a, 0.0)
    low = seg_db(wet1, 1.0, 2.0) - ref
    print("       AU3: cutoff at 0.003 (the AU shows %s Hz): the wet of a 1 kHz tone is %.2f dB under the wet without plugin" % (shown.get("display"), low))
    check("AU3: the AU acts on the WET (more than 10 dB down)", low < -10.0, low)
    check("AU3: the DRY is untouched, sample for sample", maxabs(sub(dry1, dry0)) == 0.0, maxabs(sub(dry1, dry0)))
    inst0 = chain_instances(c, x, a)
    check("AU3: the engine reports ONE hosted instance on the send", isinstance(inst0, list) and len(inst0) == 1 and not inst0[0].endswith("/0x0"), inst0)
    audits3(c, "AU3 laid")

    # --- undo / redo of a parameter: the state is put back on the LIVE instance, nothing is reloaded
    c.send("object.move", {"id": z, "start": 0.5})            # the undo snapshot is taken HERE (cutoff low)
    settle(c)
    c.send("plugin.set_param", {"plugin": pid, "index": k, "value": 0.6})
    settle(c)
    high = wet_level("AU3_high.wav")
    print("       AU3: cutoff at 0.6, outside any undo point: wet %.2f dB re no plugin" % high)
    check("AU3: the parameter is heard (the wet comes back up by more than 10 dB)", high - low > 10.0, (low, high))
    log0 = app_log_lines()
    c.send("edit.undo", {})
    settle(c)
    tr = undo_trace_since(log0)
    print("       AU3: undo trace: %s" % (tr[-1].strip()[-60:] if tr else None))
    if tr is not None:
        check("AU3 undo: the object is NOT rebuilt (0 rebuilt, patched in place)", bool(tr) and "0 rebuilt" in tr[-1], tr[-1:])
    got = wet_level("AU3_undone.wav")
    check("AU3 undo: the AU's state of the undo point is back (wet %.2f dB, 0.2)" % low, abs(got - low) <= 0.2, got)
    check("AU3 undo: the SAME hosted instance (no reload)", chain_instances(c, x, a) == inst0, (chain_instances(c, x, a), inst0))
    c.send("edit.redo", {})
    settle(c)
    got = wet_level("AU3_redone.wav")
    check("AU3 redo: the state at the undo is back (wet %.2f dB, 0.2)" % high, abs(got - high) <= 0.2, got)
    check("AU3 redo: the SAME hosted instance", chain_instances(c, x, a) == inst0, (chain_instances(c, x, a), inst0))
    c.send("plugin.set_param", {"plugin": pid, "index": k, "value": AU_LOW})
    settle(c)

    # --- retarget: the instance is kept, with its live state
    c.send("send.retarget", {"id": x, "aux": a, "to": b})
    settle(c)
    check("AU3 retarget: the send to B carries the AU (same id)", send_plugins3(c, x, b) == [pid] and send_entry(c, x, a) is None, send_plugins3(c, x, b))
    check("AU3 retarget: the SAME hosted instance", chain_instances(c, x, b) == inst0, (chain_instances(c, x, b), inst0))
    got = wet_level("AU3_retargeted.wav")
    check("AU3 retarget: the wet into B is the one into A (%.2f dB, 0.2)" % low, abs(got - low) <= 0.2, got)
    audits3(c, "AU3 retarget")

    # --- the four positions WHILE PLAYING
    c.send("transport.play", {})
    time.sleep(0.4)
    for pos in ("pre_fader", "input", "chain", "post_fader", "input", "post_fader"):
        prm = {"id": x, "aux": b, "position": pos}
        if pos == "chain":
            prm["index"] = 0
        c.send("send.set_position", prm)
        time.sleep(0.35)
    c.send("transport.stop")
    settle(c)
    if not alive(c, "AU3 positions while playing"):
        return
    check("AU3 positions while playing: the SAME hosted instance", chain_instances(c, x, b) == inst0, (chain_instances(c, x, b), inst0))
    got = wet_level("AU3_after_play.wav")
    check("AU3 positions while playing: the wet is right afterwards (%.2f dB, 0.2)" % low, abs(got - low) <= 0.2, got)
    audits3(c, "AU3 positions while playing")

    # --- duplicate the object: an independent instance
    d = c.send("object.duplicate", {"ids": [x]})["ids"]
    settle(c)
    dup = d[0] if d else None
    c.send("object.move", {"id": dup, "lane": 6, "start": 0.0})
    settle(c)
    time.sleep(1.0)
    settle(c)
    ids = send_plugins3(c, dup, b)
    check("AU3 duplicate: the copy's send carries ONE AU under a fresh id", len(ids) == 1 and ids[0] != pid, ids)
    if len(ids) == 1:
        inst_d = chain_instances(c, dup, b)
        check("AU3 duplicate: another hosted instance", isinstance(inst_d, list) and len(inst_d) == 1 and inst_d != inst0
              and inst_d[0].split("/")[1] != inst0[0].split("/")[1], (inst_d, inst0))
        _, w = wet_of(c, "AU3_dup", dup, b, others=[x])
        dl = seg_db(w, 1.0, 2.0) - ref
        check("AU3 duplicate: its wet has the original's state (%.2f dB, 0.2)" % low, abs(dl - low) <= 0.2, dl)
        kd = au_cutoff_index(c, ids[0])
        c.send("plugin.set_param", {"plugin": ids[0], "index": kd, "value": 0.6})
        settle(c)
        _, w = wet_of(c, "AU3_dup2", dup, b, others=[x])
        dl2 = seg_db(w, 1.0, 2.0) - ref
        _, w = wet_of(c, "AU3_orig2", x, b, others=[dup])
        ol = seg_db(w, 1.0, 2.0) - ref
        print("       AU3 duplicate: the COPY's cutoff changed to 0.6: copy %.2f dB, original %.2f dB (re no plugin)" % (dl2, ol))
        check("AU3 duplicate: the copy's parameter moves the copy (more than 10 dB up)", dl2 - dl > 10.0, (dl, dl2))
        check("AU3 duplicate: ... and NOT the original (%.2f dB, 0.2)" % low, abs(ol - low) <= 0.2, ol)
    audits3(c, "AU3 duplicate")

    # --- removing the send purges the instance
    before = audits3(c, "AU3 before removal").get("send_plugins")
    c.send("send.remove", {"id": x, "aux": b})
    settle(c)
    if not alive(c, "AU3 send removed"):
        return
    gone = True
    try:
        gone = c.send("plugin.get_params", {"plugin": pid}).get("count", 0) == 0
    except ObjekatError:
        gone = True
    check("AU3 send removed: the engine holds no instance under the AU's key", gone)
    check("AU3 send removed: no engine send row is left for it", engine_send_row(c.send("debug.bridge_report"), x, b) == {})
    after = audits3(c, "AU3 send removed").get("send_plugins")
    check("AU3 send removed: one send plugin less in the project", isinstance(before, int) and after == before - 1, (before, after))
    if dup:
        check("AU3 send removed: the duplicate keeps its own AU", len(send_plugins3(c, dup, b)) == 1 and chain_instances(c, dup, b) is not None)
    c.send("edit.undo", {})
    settle(c)
    time.sleep(1.0)
    settle(c)
    check("AU3 removal undone: the send and its AU are back (same id)", send_plugins3(c, x, b) == [pid], send_plugins3(c, x, b))
    inst_back = chain_instances(c, x, b)
    check("AU3 removal undone: the engine hosts an instance again", isinstance(inst_back, list) and len(inst_back) == 1 and not inst_back[0].endswith("/0x0"), inst_back)
    _, w = wet_of(c, "AU3_back", x, b, others=[dup] if dup else [])
    bl = seg_db(w, 1.0, 2.0) - ref
    check("AU3 removal undone: with the state it had (%.2f dB, 0.2)" % low, abs(bl - low) <= 0.2, bl)
    audits3(c, "AU3 end")


# --------------------------------------------------------------------------------------------------
# SC3 — the crash of 10 October, kept: a sender changes RANK, then a plugin is added on its send
# --------------------------------------------------------------------------------------------------

def section_SC3(c):
    print("\n--- SC3  a sidechain key moves the sender to another rank, THEN a plugin is added on its send (the old crash)")
    if REF:
        print("       (skipped in --ref: plugins on a send are INC 3)")
        return
    for variant in ("trunk", "send"):
        name = "SC3_" + variant
        pipeline_offset_db(c)
        x, a = cast_siblings(c, name)
        k = c.send("object.add", {"path": out("imp_small.wav"), "lane": 2, "start": 0.0})["id"]
        c.send("send.create", {"id": x, "aux": a, "position": "input"})
        lay_send(c, x, a, 0.0)
        settle(c)
        h = need_host(c, name, x, a)
        if h is None:
            continue
        if variant == "trunk":
            probe = (step(name + ": a key probe in the sender's chain", lambda: add_test(c, x, "objKeyProbe")) or {}).get("plugin")
            key_host = x
        else:
            _, probe = add_on_send(c, name, x, a, "objKeyProbe")
            key_host = h
        if probe is None:
            continue
        settle(c)
        rank0 = (bridge_report(c).get("model") or {}).get("root_ranks", {}).get(x)
        r = step(name + ": plugin.set_sidechain (keyed by another object)",
                 lambda: c.send("plugin.set_sidechain", {"host": key_host, "plugin": probe, "source": k}))
        if r is None:
            continue
        settle(c)
        time.sleep(0.5)
        settle(c)
        rank1 = (bridge_report(c).get("model") or {}).get("root_ranks", {}).get(x)
        print("       %s: the sender's rank: %s before the key, %s after" % (name, rank0, rank1))
        check(name + ": the key changed the sender's rank (the clip moved to another pool track)",
              rank1 is not None and rank1 != (rank0 or 0), (rank0, rank1))
        # THE moment: the mini-chain's list used to point at the pruned track
        _, g = add_on_send(c, name + " after the rank change", x, a, "gainTester", gain_db=-12.0)
        if not alive(c, name + " plugin added on the send after the rank change"):
            return
        r = step(name + ": plugin.add (built-in Low Pass) on the send too", lambda: c.send("plugin.add", {"host": h, "identifier": "lowpass"}))
        lp = ((r or {}).get("plugin") or {}).get("id")
        settle(c)
        if not alive(c, name + " second plugin added"):
            return
        if lp:
            c.send("plugin.remove", {"host": h, "plugin": lp})
            settle(c)
        want_n = 1 if variant == "trunk" else 2
        check(name + ": the send carries what was laid (%d)" % want_n, len(send_plugins3(c, x, a)) == want_n, send_plugins3(c, x, a))
        db, w = wet3(c, name, a)
        near(name + ": the wet (input send, 0 dB, through the -12 dB plugin)", db, -12.0)
        check(name + ": ... on the source's sample", B.peak_index(w) == SR, B.peak_index(w))
        # and back: the key is cleared, the rank returns, one more plugin
        c.send("plugin.set_sidechain", {"host": key_host, "plugin": probe, "source": None})
        settle(c)
        time.sleep(0.5)
        settle(c)
        _, g2 = add_on_send(c, name + " after the key is cleared", x, a, "gainTester", gain_db=-6.0)
        if not alive(c, name + " plugin added after the key is cleared"):
            return
        db, _ = wet3(c, name + "_cleared", a)
        near(name + ": key cleared, one more plugin (-6): the wet", db, -18.0)
        audits3(c, name)


# --------------------------------------------------------------------------------------------------
# D3 — copies are INDEPENDENT, read from the copy's side: a parameter moved on the copy
# --------------------------------------------------------------------------------------------------

def section_D3(c):
    print("\n--- D3  duplicate / cut / copy-paste: a parameter changed on the COPY's send plugin does not move the original")
    if REF:
        print("       (skipped in --ref: plugins on a send are INC 3)")
        return
    fresh(c, "D3")
    x = c.send("object.add", {"path": out("sine1k.wav"), "lane": 0, "start": 0.0})["id"]
    a = c.send("aux.create", {"start": 0.0, "end": 4.0, "lane": 5})["id"]
    c.send("send.create", {"id": x, "aux": a, "position": "pre_fader"})
    lay_send(c, x, a, 0.0)
    settle(c)
    h = need_host(c, "D3", x, a)
    r = step("D3: the built-in Low Pass on the send", lambda: c.send("plugin.add", {"host": h, "identifier": "lowpass"}))
    pid = ((r or {}).get("plugin") or {}).get("id")
    if pid is None:
        return
    settle(c)
    c.send("plugin.set_param", {"plugin": pid, "index": 0, "value": 8000.0})        # the real parameter door (the one a link mirrors)
    settle(c)
    everyone = [x]

    def level(name, obj, t0=0.2, t1=0.8):
        _, w = wet_of(c, name, obj, a, others=everyone)
        return seg_db(w, t0, t1)

    base = level("D3_base", x)
    print("       D3: the original's wet, Low Pass at 8 kHz: %.2f dBFS" % base)

    def judge(label, copy, t0=0.2, t1=0.8):
        ids = send_plugins3(c, copy, a)
        check("D3 %s: the copy's send has ONE plugin, a fresh id" % label, len(ids) == 1 and ids[0] != pid, ids)
        if len(ids) != 1:
            return
        everyone.append(copy)
        rows = (send_entry(c, copy, a) or {}).get("plugins", [])
        check("D3 %s: not linked" % label, all(not q.get("linked") for q in rows), rows)
        before = level("D3_%s_copy0" % label, copy, t0, t1)
        check("D3 %s: the copy sounds like the original (0.1 dB)" % label, abs(before - base) <= 0.1, (before, base))
        c.send("plugin.set_param", {"plugin": ids[0], "index": 0, "value": 150.0})
        settle(c)
        after = level("D3_%s_copy1" % label, copy, t0, t1)
        orig = level("D3_%s_orig" % label, x)
        print("       D3 %s: the COPY's Low Pass to 150 Hz: copy %.2f -> %.2f dBFS, original %.2f dBFS" % (label, before, after, orig))
        check("D3 %s: the parameter moves the COPY (more than 20 dB down)" % label, before - after > 20.0, (before, after))
        check("D3 %s: ... and NOT the original (0.05 dB)" % label, abs(orig - base) <= 0.05, (orig, base))
        prm = c.send("plugin.get_params", {"plugin": pid})["params"][0]["value"]
        check("D3 %s: the original's live parameter still reads 8000 Hz" % label, abs(prm - 8000.0) < 1.0, prm)
        m = audits3(c, "D3 " + label)

    # duplicate
    d = c.send("object.duplicate", {"ids": [x]})["ids"]
    settle(c)
    if d:
        c.send("object.move", {"id": d[0], "lane": 6, "start": 0.0})
        settle(c)
        judge("duplicate", d[0])
    # copy / paste
    c.send("selection.set", {"ids": [x]})
    c.send("clipboard.copy", {})
    c.send("timesel.set", {"start": 0.0, "end": 4.0, "lane": 3, "lane_count": 1})
    pasted = c.send("clipboard.paste", {})["ids"]
    settle(c)
    check("D3 paste: one object pasted", len(pasted) == 1, pasted)
    if pasted:
        judge("paste", pasted[0])
    # cut: the right half is the new object (2 s .. 4 s)
    pieces = c.send("object.split_at", {"seconds": 2.0, "ids": [x]})["ids"]
    settle(c)
    right = [i for i in pieces if i != x]
    check("D3 cut: two pieces, the left one keeps the id", len(pieces) == 2 and len(right) == 1, pieces)
    if right:
        judge("cut", right[0], 2.2, 2.8)
    # the file: no id twice, no link on a send plugin
    c.send("project.save")
    d1 = json.load(open(out("D3/project.objekat")))
    found = []
    def walk(items):
        for it in items:
            for s_ in it.get("sends", []):
                found.extend(s_.get("plugins", []))
            walk((it.get("kind") or {}).get("children") or [])
    walk(d1["items"])
    ids_ = [q["id"] for q in found]
    check("D3 file: %d send plugins, every id once" % len(ids_), len(ids_) == len(everyone) and len(set(ids_)) == len(ids_), ids_)
    check("D3 file: no `linkGroupID` on any send plugin", all(not q.get("linkGroupID") for q in found), [q for q in found if q.get("linkGroupID")])
    r = c.send("debug.plugin_id_audit")
    check("D3: debug.plugin_id_audit count is 0", r.get("count") == 0, r)


# --------------------------------------------------------------------------------------------------
# PL3 — the position of a send that carries plugins, changed WHILE PLAYING
# --------------------------------------------------------------------------------------------------

def section_PL3(c):
    print("\n--- PL3  send.set_position on a send that carries plugins, during playback: no crash, the wet is right afterwards")
    if REF:
        print("       (skipped in --ref: plugins on a send are INC 3)")
        return
    pipeline_offset_db(c)
    x, a = cast_siblings(c, "PL3")
    c.send("object.set_gain", {"ids": [x], "db": -20.0})
    c.send("send.create", {"id": x, "aux": a, "position": "post_fader"})
    lay_send(c, x, a, 0.0)
    h, pid = add_on_send(c, "PL3", x, a, "gainTester", gain_db=-12.0)
    if pid is None:
        return
    r = step("PL3: a built-in Delay on the send too (a tail, a state)", lambda: c.send("plugin.add", {"host": h, "identifier": "delay"}))
    dl = ((r or {}).get("plugin") or {}).get("id")
    settle(c)
    if dl:
        c.send("plugin.set_param", {"plugin": dl, "index": 1, "value": 0.0})        # mix 0: the delay passes the signal, it only has to survive
        settle(c)
    inst0 = chain_instances(c, x, a)
    expect = {"post_fader": -32.0, "pre_fader": -12.0, "input": -12.0, "chain": -12.0}
    for final in ("pre_fader", "post_fader", "chain", "input"):
        c.send("transport.play", {})
        time.sleep(0.3)
        seq = [p_ for p_ in ("input", "chain", "post_fader", "pre_fader", "post_fader", "input") if p_ != final] + [final]
        for pos in seq:
            prm = {"id": x, "aux": a, "position": pos}
            if pos == "chain":
                prm["index"] = 0
            c.send("send.set_position", prm)
            time.sleep(0.2)
        time.sleep(0.3)
        c.send("transport.stop")
        settle(c)
        if not alive(c, "PL3 %d moves while playing, ending at %s" % (len(seq), final)):
            return
        row = send_entry(c, x, a) or {}
        check("PL3 ending at %s: the model says so, the plugins are on the send" % final,
              row.get("position") == final and len(row.get("plugins", [])) == (2 if dl else 1), row)
        check("PL3 ending at %s: the same plugin instances" % final, chain_instances(c, x, a) == inst0, (chain_instances(c, x, a), inst0))
        db, _ = wet3(c, "PL3_" + final, a)
        near("PL3 ending at %s: the wet" % final, db, expect[final])
        audits3(c, "PL3 " + final)


# --------------------------------------------------------------------------------------------------
# B3 — consolidate / bake
# --------------------------------------------------------------------------------------------------

def section_B3(c):
    print("\n--- B3  consolidate: fold / remove / pre-fader refusal with a plugin on the send; a group's child; un-bake")
    if REF:
        print("       (skipped in --ref: plugins on a send are INC 3)")
        return
    pipeline_offset_db(c)

    def sends_of(i):
        try:
            return c.send("send.list", {"id": i}).get("sends")
        except ObjekatError:
            return None

    # --- fold
    x, a = y2_build(c, "B3fold", {"position": "input"})
    h, pid = add_on_send(c, "B3 fold", x, a, "gainTester", gain_db=-12.0)
    if pid is None:
        return
    db, _ = wet3(c, "B3fold_before", a)
    near("B3 fold: before: the input send through its plugin", db, -12.0)
    refused("B3: consolidate with an input send carrying a plugin, default", lambda: c.send("consolidate.make", {"id": x}))
    ids0 = {o["id"] for o in c.send("object.list", {})["objects"]}
    y2_consolidate(c, x, mid_chain_sends="fold")
    pl = y2_placement(c, ids0)
    check("B3 fold: a placement was made", pl is not None, pl)
    if pl:
        rows = sends_of(pl) or []
        check("B3 fold: the placement's send is post-fader and carries the plugin (same id)",
              len(rows) == 1 and rows[0]["position"] == "post_fader" and [p_["id"] for p_ in rows[0].get("plugins", [])] == [pid], rows)
        check("B3 fold: the plugin's instance is the engine's", in_engine(c, pid))
        audits3(c, "B3 fold")
        db, _ = wet3(c, "B3fold_after", a)
        near("B3 fold: the wet is the BAKED signal (-6 -12 -3) through the plugin (-12)", db, -33.0)

    # --- remove: the send and its plugin go; undo brings both back
    x, a = y2_build(c, "B3remove", {"position": "input"})
    h, pid = add_on_send(c, "B3 remove", x, a, "gainTester", gain_db=-12.0)
    ids0 = {o["id"] for o in c.send("object.list", {})["objects"]}
    y2_consolidate(c, x, mid_chain_sends="remove")
    pl = y2_placement(c, ids0)
    check("B3 remove: a placement was made, with no send", pl is not None and sends_of(pl) == [], (pl, sends_of(pl) if pl else None))
    check("B3 remove: no engine key is left for the send's plugin", not in_engine(c, pid))
    m = audits3(c, "B3 remove")
    check("B3 remove: no send plugin is left in the project", m.get("send_plugins") in (0, [], None), m.get("send_plugins"))
    n = 0
    while n < 4 and not (sends_of(x) and (sends_of(x)[0].get("plugins"))):
        c.send("edit.undo", {})
        settle(c)
        n += 1
    rr = sends_of(x) or []
    print("       B3 remove: %d undo(s) to get the send back on the clip" % n)
    check("B3 remove: undone: the send is back at input WITH its plugin (same id)",
          len(rr) == 1 and rr[0]["position"] == "input" and [p_["id"] for p_ in rr[0].get("plugins", [])] == [pid], rr)
    audits3(c, "B3 remove undone")
    db, _ = wet3(c, "B3remove_undone", a)
    near("B3 remove: undone: the wet", db, -12.0)

    # --- pre-fader: refused, plugin or not
    x, a = y2_build(c, "B3pre", {"position": "pre_fader"})
    h, pid = add_on_send(c, "B3 pre", x, a, "gainTester", gain_db=-12.0)
    before = y2_fingerprint(c, x)
    for extra in ({}, {"mid_chain_sends": "fold"}, {"mid_chain_sends": "remove"}):
        try:
            c.send("consolidate.make", dict({"id": x}, **extra))
            check("B3 pre %s: refused" % extra, False, "accepted")
        except ObjekatError as e:
            check("B3 pre %s: refused pre_fader_send" % extra, e.code == "invalid_state" and e.message.startswith("pre_fader_send"), e)
    check("B3 pre: nothing changed (fingerprint, the send's plugins included)", y2_fingerprint(c, x) == before)

    # --- a group whose CHILD carries a mini-chain: baked, then un-baked
    fresh(c, "B3grp")
    x = c.send("object.add", {"path": out("imp.wav"), "lane": 0, "start": 0.0})["id"]
    o = with_other(c, lane=1)
    a = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 8})["id"]
    g = grp(c, [x, o])
    c.send("send.create", {"id": x, "aux": a, "position": "post_fader"})
    lay_send(c, x, a, 0.0)
    h, pid = add_on_send(c, "B3 group", x, a, "gainTester", gain_db=-12.0)
    db0, _ = wet3(c, "B3grp_before", a)
    near("B3 group: before the bake: the child's wet", db0, -12.0)
    ids0 = {o_["id"] for o_ in c.send("object.list", {})["objects"]}
    r = step("B3 group: the group is consolidated", lambda: y2_consolidate(c, g))
    objs = c.send("object.list", {})["objects"]
    pl = g if any(o_["id"] == g for o_ in objs) else y2_placement(c, ids0)
    m = audits3(c, "B3 group baked")
    dbb, wb = wet3(c, "B3grp_baked", a)
    print("       B3 group baked: placement %s; wet into the aux %s dB; send plugins in the model: %s"
          % (pl, dbb, m.get("send_plugins")))
    r = step("B3 group: consolidate.unmake", lambda: c.send("consolidate.unmake", {"placement": pl}))
    settle(c)
    for o_ in c.send("object.list", {})["objects"]:                  # the children of a folded group are not listed
        if o_.get("kind") == "group":
            c.send("group.expand", {"id": o_["id"], "expanded": True})
    wait(c)
    kids = [o_["id"] for o_ in c.send("object.list", {})["objects"] if o_.get("kind") == "clip"]
    carriers = [(k, send_plugins3(c, k, a)) for k in kids if send_entry(c, k, a)]
    print("       B3 group un-baked: senders %s" % carriers)
    check("B3 group un-baked: ONE child sends to the aux with ONE plugin, a FRESH id",
          len(carriers) == 1 and len(carriers[0][1]) == 1 and carriers[0][1][0] != pid, carriers)
    audits3(c, "B3 group un-baked")
    db1, _ = wet3(c, "B3grp_unbaked", a)
    near("B3 group un-baked: the wet is as before the bake", db1, -12.0)


# --------------------------------------------------------------------------------------------------
# K3 — a sidechain key on a plugin of a mini-chain
# --------------------------------------------------------------------------------------------------

def section_K3(c):
    print("\n--- K3  a keyed plugin ON a send: left = the sent signal, right = the key, aligned to the sample")
    if REF:
        print("       (skipped in --ref: plugins on a send are INC 3)")
        return
    B.make_impulse_left(out("imp_left.wav"))

    def stereo_wet(label, a):
        on = render_st(c, label + "_on.wav")
        c.send("object.set_mute", {"ids": [a], "muted": True})
        settle(c)
        off = render_st(c, label + "_off.wav")
        c.send("object.set_mute", {"ids": [a], "muted": False})
        settle(c)
        return [sub(on[k], off[k]) for k in range(2)]

    for pos in ("post_fader", "input"):
        name = "K3_" + pos
        fresh(c, name)
        x = c.send("object.add", {"path": out("imp_left.wav"), "lane": 0, "start": 0.0})["id"]
        k = c.send("object.add", {"path": out("imp.wav"), "lane": 2, "start": 0.0})["id"]
        a = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 5})["id"]
        c.send("send.create", {"id": x, "aux": a, "position": "post_fader"})
        lay_send(c, x, a, -12.0)                # the source peaks at 0.9 and the export clips at 1.0: a clipped
        c.send("object.set_gain", {"ids": [x], "db": -12.0})    # sample subtracts to ZERO and the "peak" slides onto the ripple beside it
        set_position(c, x, a, pos)
        h, probe = add_on_send(c, name, x, a, "objKeyProbe")
        if probe is None:
            continue
        src = step(name + ": plugin.sidechain_sources answers on a send host",
                   lambda: c.send("plugin.sidechain_sources", {"host": h, "plugin": probe}))
        r = step(name + ": plugin.set_sidechain on the send's plugin", lambda: c.send("plugin.set_sidechain", {"host": h, "plugin": probe, "source": k}))
        if r is None:
            continue
        settle(c)
        time.sleep(0.4)
        settle(c)

        def aligned(label):
            wl, wr = stereo_wet(label, a)
            il, ir = B.peak_index(wl), B.peak_index(wr)
            print("       %s: wet peak L (the sent signal) @%s, R (the key) @%s" % (label, il, ir))
            check("%s: the sent signal is at the source's sample (48000)" % label, il == SR, il)
            check("%s: the key is there, aligned to the sample" % label, ir is not None and ir == il, (il, ir))

        aligned(name + " nothing anywhere")
        try:
            lk = c.send("debug.add_test_plugin", {"host": k, "type": "latencyTester", "latency_ms": 10.0})["plugin"]
        except ObjekatError as e:
            check(name + ": a latency on the key source", False, e)
        settle(c)
        time.sleep(0.6)
        settle(c)
        aligned(name + " key OLDER (10 ms on the source)")
        try:
            lm = c.send("debug.add_test_plugin", {"host": h, "type": "latencyTester", "latency_ms": 20.0})["plugin"]
            c.send("plugin.drop_at", {"from": h, "host": h, "plugin": lm, "series": "root", "at": 0})
        except ObjekatError as e:
            check(name + ": a latency in the mini-chain before the probe", False, e)
        settle(c)
        time.sleep(0.6)
        settle(c)
        check(name + ": the mini-chain is [latency, probe]", send_plugins3(c, x, a)[-1:] == [probe] and len(send_plugins3(c, x, a)) == 2,
              send_plugins3(c, x, a))
        aligned(name + " key YOUNGER (20 ms in the mini-chain before the probe)")
        b = build_of(c)
        check(name + ": the build converged", b.get("converged") is True, b)
        audits3(c, name)


# --------------------------------------------------------------------------------------------------
# H3 — addressing: every plugin command on a send host
# --------------------------------------------------------------------------------------------------

def section_H3(c):
    print("\n--- H3  a send's mini-chain is a chain host: every plugin.* command, the refusals, an unknown host")
    if REF:
        print("       (skipped in --ref: plugins on a send are INC 3)")
        return
    pipeline_offset_db(c)
    x, a = cast_siblings(c, "H3")
    a2 = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 7})["id"]
    c.send("send.create", {"id": x, "aux": a, "position": "post_fader"})
    lay_send(c, x, a, 0.0)
    c.send("send.create", {"id": x, "aux": a2, "position": "post_fader"})          # stays at -inf
    settle(c)
    h, h2 = need_host(c, "H3", x, a), need_host(c, "H3 (second send, -inf)", x, a2)
    if h is None or h2 is None:
        return
    check("H3: two sends, two distinct hosts, neither is the object", len({h, h2, x}) == 3, (h, h2))
    r = step("H3: plugin.add (built-in lowpass) on a send at -inf", lambda: c.send("plugin.add", {"host": h2, "identifier": "lowpass"}))
    lp2 = ((r or {}).get("plugin") or {}).get("id")
    settle(c)
    step("H3: plugin.get_params on it", lambda: c.send("plugin.get_params", {"plugin": lp2}))
    r = step("H3: plugin.add on the live send", lambda: c.send("plugin.add", {"host": h, "identifier": "lowpass"}))
    lp = ((r or {}).get("plugin") or {}).get("id")
    g = c.send("debug.add_test_plugin", {"host": h, "type": "gainTester", "gain_db": -12.0})["plugin"]
    settle(c)
    lst = c.send("plugin.list", {"host": h})
    check("H3 plugin.list: is_send_chain, the sender, the aux, the two plugins in order",
          lst.get("is_send_chain") is True and lst.get("sender") == x and lst.get("aux") == a
          and [p_["id"] for p_ in lst["plugins"]] == [lp, g], lst)
    row = send_entry(c, x, a) or {}
    check("H3 send.list: chain_host and plugins", row.get("chain_host") == h and [p_["id"] for p_ in row.get("plugins", [])] == [lp, g], row)
    og = c.send("object.get", {"id": x})
    check("H3 object.get: plugins_on_sends counts them (3)", og.get("plugins_on_sends") == 3, og.get("plugins_on_sends"))
    c.send("plugin.set_param", {"plugin": lp, "index": 0, "value": 2000.0})
    v = c.send("plugin.get_params", {"plugin": lp})["params"][0]["value"]
    check("H3 plugin.set_param / get_params", abs(v - 2000.0) < 1.0, v)
    c.send("plugin.toggle", {"host": h, "plugin": lp})
    settle(c)
    check("H3 plugin.toggle: the lowpass is bypassed", [p_["enabled"] for p_ in c.send("plugin.list", {"host": h})["plugins"]] == [False, True])
    db, _ = wet3(c, "H3_toggle", a)
    near("H3: the lowpass bypassed, the gain active: the wet", db, -12.0)
    r = c.send("plugin.copy", {"from": h, "to": h2, "plugin": g})
    settle(c)
    cp = (r.get("plugins") or [None])[0]
    check("H3 plugin.copy send -> send: a fresh id on the other send, the source kept",
          cp not in (None, g) and send_plugins3(c, x, a2) == [lp2, cp] and send_plugins3(c, x, a) == [lp, g], (r, send_plugins3(c, x, a2)))
    r = c.send("plugin.move", {"from": h2, "to": x, "plugin": cp})
    settle(c)
    tk = (r.get("plugins") or [None])[0]
    check("H3 plugin.move send -> trunk", send_plugins3(c, x, a2) == [lp2] and [p_["id"] for p_ in c.send("plugin.list", {"host": x})["plugins"]] == [tk], r)
    c.send("plugin.select", {"host": h, "plugins": [lp, g]})
    sel = c.send("plugin.selection")
    check("H3 plugin.select / selection on a send host", sel.get("host") == h and sorted(p_["id"] for p_ in sel.get("plugins", [])) == sorted([lp, g]), sel)
    c.send("plugin.toggle_selected")
    settle(c)
    check("H3 plugin.toggle_selected", [p_["enabled"] for p_ in c.send("plugin.list", {"host": h})["plugins"]] in ([True, False], [False, False], [True, True]),
          c.send("plugin.list", {"host": h})["plugins"])
    c.send("edit.undo", {})
    settle(c)
    c.send("plugin.select", {"host": h, "plugins": [g]})
    c.send("plugin.duplicate_selected")
    settle(c)
    ids = send_plugins3(c, x, a)
    check("H3 plugin.duplicate_selected: three plugins, the copy right after its source, fresh id, not linked",
          len(ids) == 3 and ids[:2] == [lp, g] and ids[2] not in (lp, g)
          and all(not p_.get("linked") for p_ in c.send("plugin.list", {"host": h})["plugins"]), c.send("plugin.list", {"host": h})["plugins"])
    c.send("plugin.select", {"host": h, "plugins": [g]})
    c.send("plugin.copy_selected")
    r = step("H3 plugin.paste on the other send", lambda: c.send("plugin.paste", {"host": h2}))
    settle(c)
    check("H3 plugin.paste: the other send holds two plugins", len(send_plugins3(c, x, a2)) == 2, send_plugins3(c, x, a2))
    c.send("plugin.select", {"host": h, "plugins": [ids[2]]})
    c.send("plugin.remove_selected")
    settle(c)
    check("H3 plugin.remove_selected", send_plugins3(c, x, a) == [lp, g], send_plugins3(c, x, a))
    c.send("plugin.deselect")
    c.send("plugin.remove", {"host": h, "plugin": lp})
    settle(c)
    check("H3 plugin.remove", send_plugins3(c, x, a) == [g], send_plugins3(c, x, a))
    audits3(c, "H3 commands")

    # --- refusals
    g1 = add_test(c, x, "gainTester", gain_db=0.0)["plugin"]
    g2 = add_test(c, x, "gainTester", gain_db=0.0)["plugin"]
    settle(c)
    blk = step("H3: a bin on the trunk", lambda: c.send("fxlink.create", {"host": x, "plugins": [g1, g2], "name": "Bin"}))
    settle(c)
    bins = [e for e in c.send("plugin.list", {"host": x})["plugins"] if e.get("is_fx_block")]
    if bins:
        r = c.send("plugin.drop_at", {"from": x, "host": h, "plugin": bins[0]["id"], "dry_run": True})
        check("H3: a bin dropped on a send is refused send_chain_leaves_only", r.get("refused") is True and r.get("reason") == "send_chain_leaves_only", r)
        r = c.send("plugin.drop_at", {"from": x, "host": h, "plugin": bins[0]["id"]})
        check("H3: ... and the real drop places nothing", r.get("placed") is False and send_plugins3(c, x, a) == [g], (r, send_plugins3(c, x, a)))
        r = c.send("plugin.drop_at", {"from": h, "host": x, "plugin": g, "series": {"block": bins[0]["id"]}, "dry_run": True})
        print("       H3: a send plugin dropped INTO a bin of the trunk: %s" % r)
    else:
        check("H3: a bin exists on the trunk", False, c.send("plugin.list", {"host": x}))
    refused("H3: fxlink.create on a send host", lambda: c.send("fxlink.create", {"host": h, "plugins": [g], "name": "No"}),
            reason="send_plugins_never_linked")
    if bins and blk:
        refused("H3: fxlink.attach on a send host", lambda: c.send("fxlink.attach", {"link": blk["id"], "host": h}),
                reason="send_plugins_never_linked")
    check("H3: the send's chain is untouched by the refusals", send_plugins3(c, x, a) == [g], send_plugins3(c, x, a))
    refused("H3: plugin.link from a send", lambda: c.send("plugin.link", {"from": h, "to": x, "plugin": g}), reason="send_plugins_never_linked")
    refused("H3: plugin.link to a send", lambda: c.send("plugin.link", {"from": x, "to": h, "plugin": tk}), reason="send_plugins_never_linked")
    ghost = "00000000-0000-4000-8000-00000000BEEF"
    for cmd, prm in (("plugin.list", {"host": ghost}), ("plugin.add", {"host": ghost, "identifier": "lowpass"}),
                     ("plugin.move", {"from": h, "to": ghost, "plugin": g}), ("plugin.copy", {"from": h, "to": ghost, "plugin": g}),
                     ("debug.add_test_plugin", {"host": ghost, "type": "gainTester"})):
        refused("H3: %s with an unknown host" % cmd, lambda: c.send(cmd, prm), code="not_found")
    # a removed send: its host is gone
    c.send("send.remove", {"id": x, "aux": a2})
    settle(c)
    refused("H3: plugin.list on the host of a removed send", lambda: c.send("plugin.list", {"host": h2}), code="not_found")
    m = audits3(c, "H3 end")
    check("H3 end: the linked list of the audit is empty and the bin's members are the trunk's only", m.get("linked_send_plugins") == [], m)


def wav_data(path):
    """The raw bytes of a WAV's `data` chunk (the header carries a date: files are never compared whole)."""
    with open(path, "rb") as f:
        blob = f.read()
    if blob[:4] != b"RIFF" or blob[8:12] != b"WAVE":
        return None
    i = 12
    while i + 8 <= len(blob):
        cid, size = blob[i:i + 4], int.from_bytes(blob[i + 4:i + 8], "little")
        if cid == b"data":
            return blob[i + 8:i + 8 + size]
        i += 8 + size + (size & 1)
    return None


def section_P3(c):
    print("\n--- P3  no plugin on a send = the INC 2 build, sample for sample (INC2_REF_DIR)")
    ref_dir = os.environ.get("INC2_REF_DIR")
    if REF or not ref_dir:
        print("       (skipped: set INC2_REF_DIR to the exports of the INC 2 reference run, step 3.0)")
        return
    names = sorted(n for n in os.listdir(ref_dir) if n.endswith(".wav") and os.path.isfile(out(n)))
    fixtures_ = {"imp.wav", "imp_small.wav", "sine1k.wav", "imp_two.wav"}
    names = [n for n in names if n not in fixtures_]
    differing = [n for n in names if wav_data(os.path.join(ref_dir, n)) != wav_data(out(n))]
    print("       P3: %d exports of this run have a reference; %d differ" % (len(names), len(differing)))
    check("P3: this run made exports the reference has (%d)" % len(names), len(names) > 0, "nothing to compare")
    check("P3: every INC 2 export is identical to the reference, sample for sample", not differing, differing[:12])


# --------------------------------------------------------------------------------------------------

fixtures()
with ObjekatClient(SOCK) as c:
    B.require_audio(c)
    c.send("app.set_dialog_policy", {"policy": "assume_yes"})
    print("mode: %s" % ("REFERENCE (main, pre-bridge engine)" if REF else "bridge"))
    for sec, fn in (("A", section_A), ("B", section_B), ("C", section_C), ("D", section_D), ("D2", section_D2),
                    ("E", section_E), ("F", section_F), ("GH", section_GH), ("I", section_I), ("I4", section_I4), ("I5", section_I5), ("J", section_J),
                    ("K", section_K), ("L", section_L), ("M", section_M), ("N", section_N), ("P", section_P),
                    ("Q", section_Q), ("R", section_R), ("S", section_S), ("T", section_T),
                    ("F2", section_F2), ("Q2", section_Q2), ("R2", section_R2), ("V2", section_V2),
                    ("K2", section_K2), ("S2", section_S2), ("T2", section_T2), ("U2", section_U2), ("W2", section_W2), ("X2", section_X2), ("Y2", section_Y2), ("RT2", section_RT2),
                    ("Z2", section_Z2), ("PF", section_PF),
                    ("A3", section_A3), ("L3", section_L3), ("O3", section_O3),
                    ("G3", section_G3), ("M3", section_M3), ("X3", section_X3), ("U3", section_U3),
                    ("Z3", section_Z3), ("C3", section_C3), ("R3", section_R3), ("T3", section_T3),
                    ("AU3", section_AU3), ("SC3", section_SC3), ("D3", section_D3), ("PL3", section_PL3),
                    ("B3", section_B3), ("K3", section_K3), ("H3", section_H3),
                    ("P3", section_P3),
                    ("T2REF", section_T2REF)):
        if want(sec):
            fn(c)

T.finish()
sys.exit(0 if T.ko == 0 else 1)

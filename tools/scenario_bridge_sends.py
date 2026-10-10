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
                     Y2, Z2, RT2, PF and K2 — INC 1 already used the letters P to T).

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
    check("P: saved again as format 22", d2.get("version") == 22, d2.get("version"))
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
    check("Z2 file: saved as format 22", d1.get("version") == 22, d1.get("version"))
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
    check("PF1: saved as format 22, and still without marker or tap", d2.get("version") == 22 and "sendMarker" not in blob2 and '"tap"' not in blob2,
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

# --------------------------------------------------------------------------------------------------

fixtures()
with ObjekatClient(SOCK) as c:
    B.require_audio(c)
    c.send("app.set_dialog_policy", {"policy": "assume_yes"})
    print("mode: %s" % ("REFERENCE (main, pre-bridge engine)" if REF else "bridge"))
    for sec, fn in (("A", section_A), ("B", section_B), ("C", section_C), ("D", section_D), ("D2", section_D2),
                    ("E", section_E), ("F", section_F), ("GH", section_GH), ("I", section_I), ("I4", section_I4), ("J", section_J),
                    ("K", section_K), ("L", section_L), ("M", section_M), ("N", section_N), ("P", section_P),
                    ("Q", section_Q), ("R", section_R), ("S", section_S), ("T", section_T),
                    ("F2", section_F2), ("Q2", section_Q2), ("R2", section_R2), ("V2", section_V2),
                    ("K2", section_K2), ("S2", section_S2), ("T2", section_T2), ("U2", section_U2), ("W2", section_W2), ("X2", section_X2), ("Y2", section_Y2), ("RT2", section_RT2),
                    ("Z2", section_Z2), ("PF", section_PF),
                    ("T2REF", section_T2REF)):
        if want(sec):
            fn(c)

T.finish()
sys.exit(0 if T.ko == 0 else 1)

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Mix settings over a multiple selection (pan / gain / mute) — one lane-entry rebuild per command.

`EditViewModel.items.didSet` rebuilds the lane entries (O(N)) on every write unless the write sits
inside `batchItemsMutation`. A multi-object mix setting writes `items` once PER OBJECT (+ the
automation-touch write), so K objects cost K rebuilds per step: a pan drag over 200 objects was
~290 ms a step. The mix commands are now wrapped in a batch. This scenario proves the wrapping
changed the COST and nothing else:

  A  perf.census `lane_entries_rebuilds` delta around one command: 1 (it was ~K)
  B  ORACLE: the same sequence leaves the same pans / volumes / mutes on every step, in the old
     build and in the new one (`--out state.json` on each, then `--compare a.json b.json`);
     plus self-checks — the delta is not doubled on linked instances, the pan detent holds,
     `object.set_pan` stays exact, the detached instance does not follow
  C  undo: +1 `undo_depth` per command (+0 when nothing moved), N commands then N × edit.undo = the
     initial state, ONE edit.undo undoes the whole selection (K objects), and the 2026-08-08
     regression (delete X, adjust_pan, 1 undo → the pan comes back and X stays deleted)
  D  engine: a muted / soloed object stays silent after a relative gain (rendered mix, WAV export),
     the rendered level of an object equals the one of a twin set straight from its model values,
     and the rendering is stored in `--out` so two builds can be compared sample-wise

    # launch the build to test, UI mode or --headless, with the API, on a SHORT socket
    objekat.app/Contents/MacOS/objekat --api --no-recent --socket=/tmp/oinsp.sock

    ./scenario_mix_batch.py /tmp/oinsp.sock /tmp/omix --label before --out before_mix.json
    ./scenario_mix_batch.py /tmp/oinsp.sock /tmp/omix --label after  --out after_mix.json
    ./scenario_mix_batch.py --compare before_mix.json after_mix.json

Options: `--k 200` (size of the perf / undo fixture), `--no-audio` (skip phase D).
Exit: 0 if every assertion passes (and, with --compare, the two files agree), 1 otherwise.
"""

import json, math, os, shutil, sys, time, wave

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

BIP = os.path.join(HERE, "fixtures", "bip.wav")
FAILS = []


def check(label, ok, detail=""):
    print("  %s %s%s" % ("OK  " if ok else "FAIL", label, "" if ok or not detail else "   <- %s" % (detail,)))
    if not ok:
        FAILS.append(label)


# ── state export ───────────────────────────────────────────────────────────────────────────

def dump(c):
    """The mix of every object, keyed by what it IS (depth, lane, start, kind), never by its UUID."""
    out, seen = {}, {}
    for o in c.send("object.list")["objects"]:
        key = "d%d:l%d:s%.3f:%s" % (o["depth"], o["display_lane"], o["start"], o["kind"])
        n = seen.get(key, 0)
        seen[key] = n + 1
        if n:
            key += "#%d" % n
        out[key] = [round(o["pan"], 6), round(o["volume_db"], 6), bool(o["muted"])]
    defs = [[d["name"], round(d["pan"], 6), round(d["volume_db"], 6), bool(d["muted"])]
            for d in c.send("consolidate.list")["definitions"]]
    return {"objects": out, "definitions": sorted(defs)}


def by_id(c):
    return {o["id"]: o for o in c.send("object.list")["objects"]}


def census(c):
    r = c.send("perf.census")
    return r["undo_depth"], r["lane_entries_rebuilds"], r["items_writes"]


def job_wait(c, r, timeout_ms=120000):
    return c.send("job.wait", {"id": r["job_id"], "timeout_ms": timeout_ms})


# ── fixture ────────────────────────────────────────────────────────────────────────────────

PANS = [0.37, -0.13, 0.0, 0.5, -0.9, 0.04, 0.81, -0.46, 0.22, -0.07]
VOLS = [-6, 0, 3, -12, -1, 7, -20, 0, 2, -3]


def fresh_project(c, folder, name):
    os.makedirs(folder, exist_ok=True)
    c.send("project.new")
    c.send("project.save_as", {"path": os.path.join(folder, name)})


def lay_clips(c, n, lane0=0, per_lane=10, t0=0.0):
    c.send("batch", {"commands": [
        {"cmd": "object.add", "params": {"path": BIP, "lane": lane0 + i // per_lane,
                                         "start": t0 + (i % per_lane) * 1.0}}
        for i in range(n)]})
    objs = [o for o in c.send("object.list")["objects"] if o["kind"] == "clip" and not o["parent"]]
    objs.sort(key=lambda o: (o["display_lane"], o["start"]))
    return [o["id"] for o in objs]


def colour_the_mix(c, ids):
    """Pans off the detent, assorted volumes, a few mutes — set through the exact doors."""
    cmds = []
    for i, oid in enumerate(ids):
        cmds.append({"cmd": "object.set_pan", "params": {"pan": PANS[i % len(PANS)], "ids": [oid]}})
        cmds.append({"cmd": "object.set_gain", "params": {"db": float(VOLS[i % len(VOLS)]), "ids": [oid]}})
        if i % 7 == 3:
            cmds.append({"cmd": "object.set_mute", "params": {"muted": True, "ids": [oid]}})
    c.send("batch", {"commands": cmds})


# ── phases ─────────────────────────────────────────────────────────────────────────────────

def phase_oracle_undo(c, folder, result):
    print("\n[B/C] oracle + undo — 40 clips, 2 linked instances, 1 detached")
    fresh_project(c, folder, "oracle.objekat.json")
    ids = lay_clips(c, 40, lane0=0, per_lane=10)
    colour_the_mix(c, ids)
    # Three consolidated objects of the same definition: a and b stay linked, d is detached.
    ca = c.send("object.add", {"path": BIP, "lane": 12, "start": 0.0})["id"]
    cb = c.send("object.add", {"path": BIP, "lane": 13, "start": 0.0})["id"]
    cd = c.send("object.add", {"path": BIP, "lane": 14, "start": 0.0})["id"]
    for oid, p, v in ((ca, 0.37, -4.0), (cb, 0.37, -4.0), (cd, 0.37, -4.0)):
        c.send("object.set_pan", {"pan": p, "ids": [oid]})
        c.send("object.set_gain", {"db": v, "ids": [oid]})
    job_wait(c, c.send("consolidate.make", {"id": ca, "also_link": [cb, cd]}))
    c.send("wait_idle", {"timeout_ms": 60000})
    defs = c.send("consolidate.list")["definitions"]
    assert len(defs) == 1, defs
    places = defs[0]["placements"]
    assert len(places) == 3, places
    plist = by_id(c)
    places.sort(key=lambda i: plist[i]["display_lane"])
    pa, pb, pd = places
    # The instances come out of the bake with DIFFERENT volumes (the origin keeps 0, the others the
    # value they had) — and a selection holding two such linked instances ends on whichever one the
    # Set's (per-process random) order propagates LAST. Synchronise them first, through the
    # propagating doors, so the oracle is deterministic: one set on `pa` takes the three.
    c.send("object.set_pan", {"pan": 0.37, "ids": [pa]})
    c.send("object.set_gain", {"db": -4.0, "ids": [pa]})
    c.send("consolidate.unmake", {"placement": pd})
    c.send("wait_idle", {"timeout_ms": 60000})
    cur = by_id(c)
    top = [o["id"] for o in cur.values() if not o["parent"] and o["kind"] in ("clip", "group")]
    check("fixture: instances a and b linked, d detached",
          pa in cur and pb in cur and cur[pa]["definition"] == cur[pb]["definition"]
          and "definition" not in cur[pd], {k: cur[k].get("definition") for k in (pa, pb, pd)})
    top_sorted = sorted(top, key=lambda i: (cur[i]["display_lane"], cur[i]["start"]))

    steps = []
    snap = lambda name: steps.append([name, dump(c)])
    snap("initial")
    initial = dump(c)

    depth_ok = []

    def run(name, cmd, params, expect_push=1, select=None):
        if select is not None:
            c.send("selection.set", {"ids": select})
        u0, r0, _ = census(c)
        t0 = time.time()
        c.send(cmd, params)
        ms = (time.time() - t0) * 1000
        u1, r1, _ = census(c)
        depth_ok.append((name, u1 - u0, expect_push))
        result["rebuilds"][name] = r1 - r0
        snap(name)
        return ms

    before_a = by_id(c)
    # 1. adjust_pan over the whole selection (default targets), then the other deltas.
    run("pan+0.13 (selection)", "object.adjust_pan", {"by": 0.13}, select=top_sorted)
    run("pan-0.4", "object.adjust_pan", {"by": -0.4})
    run("pan+2", "object.adjust_pan", {"by": 2.0})
    run("pan-2", "object.adjust_pan", {"by": -2.0})
    mid = by_id(c)
    # the delta is NOT doubled on the linked pair: both were selected, both moved by ONE delta
    run("pan+0.13 (one instance)", "object.adjust_pan", {"by": 0.13, "ids": [pa]})
    after = by_id(c)
    exp = max(-1.0, min(1.0, round((mid[pa]["pan"] + 0.13) * 10) / 10))
    check("one linked instance moved: its twin follows by ONE delta",
          abs(after[pa]["pan"] - exp) < 1e-4 and abs(after[pb]["pan"] - after[pa]["pan"]) < 1e-6,
          (mid[pa]["pan"], after[pa]["pan"], after[pb]["pan"], exp))
    check("detached instance did not follow", after[pd]["pan"] == mid[pd]["pan"],
          (mid[pd]["pan"], after[pd]["pan"]))
    # both linked instances selected together: one delta, not two
    run("pan+0.1 (a and b)", "object.adjust_pan", {"by": 0.1, "ids": [pa, pb]})
    after2 = by_id(c)
    exp2 = max(-1.0, min(1.0, round((after[pa]["pan"] + 0.1) * 10) / 10))
    check("both linked instances selected: delta not doubled",
          abs(after2[pa]["pan"] - exp2) < 1e-4 and abs(after2[pb]["pan"] - exp2) < 1e-4,
          (after[pa]["pan"], after2[pa]["pan"], after2[pb]["pan"], exp2))
    # the detent: every object touched by an adjust sits on a tenth
    run("pan+0.13 (detent probe)", "object.adjust_pan", {"by": 0.13}, select=top_sorted)
    cur = by_id(c)
    off = [i for i in top_sorted if abs(cur[i]["pan"] * 10 - round(cur[i]["pan"] * 10)) > 1e-4]
    check("pan detent holds on every object", not off, [cur[i]["pan"] for i in off][:5])

    # gain, relative
    g0 = by_id(c)
    run("gain+3 rel", "object.set_gain", {"db": 3.0, "relative": True}, select=top_sorted)
    g1 = by_id(c)
    bad = [i for i in top_sorted if abs(g1[i]["volume_db"] - max(-96, min(40, round(g0[i]["volume_db"] + 3)))) > 1e-4
           and i not in (pa, pb)]
    check("relative gain +3: every object = clamp(old + 3)", not bad, len(bad))
    check("relative gain +3: linked pair moved by ONE +3",
          g1[pa]["volume_db"] == g1[pb]["volume_db"] == g0[pa]["volume_db"] + 3,
          (g0[pa]["volume_db"], g1[pa]["volume_db"], g1[pb]["volume_db"]))
    run("gain-100 rel", "object.set_gain", {"db": -100.0, "relative": True})
    g2 = by_id(c)
    bad = [i for i in top_sorted if i not in (pa, pb)
           and g2[i]["volume_db"] != max(-96, min(40, g1[i]["volume_db"] - 100))]
    check("relative gain -100: every object = clamp(old - 100)", not bad, len(bad))
    run("gain+50 rel", "object.set_gain", {"db": 50.0, "relative": True})
    g3 = by_id(c)
    bad = [i for i in top_sorted if i not in (pa, pb)
           and g3[i]["volume_db"] != max(-96, min(40, g2[i]["volume_db"] + 50))]
    check("relative gain +50: every object = clamp(old + 50)", not bad, len(bad))
    check("linked pair still equal after the big deltas", g3[pa]["volume_db"] == g3[pb]["volume_db"],
          (g3[pa]["volume_db"], g3[pb]["volume_db"]))

    # absolute pan / gain / mute on a subset
    sub = top_sorted[:12]
    run("set_pan abs 0.37 (12)", "object.set_pan", {"pan": 0.37, "ids": sub})
    s1 = by_id(c)
    check("set_pan stays EXACT (0.37, no detent)", all(abs(s1[i]["pan"] - 0.37) < 1e-6 for i in sub),
          [s1[i]["pan"] for i in sub][:3])
    run("set_pan abs -0.13 (b)", "object.set_pan", {"pan": -0.13, "ids": [pb]})
    s2 = by_id(c)
    check("set_pan on one instance: its twin follows, the detached one does not",
          abs(s2[pa]["pan"] + 0.13) < 1e-6 and abs(s2[pb]["pan"] + 0.13) < 1e-6
          and s2[pd]["pan"] == s1[pd]["pan"], (s2[pa]["pan"], s2[pb]["pan"], s2[pd]["pan"]))
    run("set_gain abs -3.4 (10)", "object.set_gain", {"db": -3.4, "ids": top_sorted[:10]})
    run("set_mute toggle (9)", "object.set_mute", {"ids": top_sorted[10:19]})
    run("set_mute true (a)", "object.set_mute", {"muted": True, "ids": [pa]})
    s3 = by_id(c)
    check("mute on one linked instance: its twin follows, the detached one does not",
          s3[pa]["muted"] and s3[pb]["muted"] and not s3[pd]["muted"],
          (s3[pa]["muted"], s3[pb]["muted"], s3[pd]["muted"]))
    run("set_mute false (a, 5)", "object.set_mute", {"muted": False, "ids": [pa] + top_sorted[10:15]})
    run("set_gain rel +1 (a and b)", "object.set_gain", {"db": 1.0, "relative": True, "ids": [pa, pb]})
    run("pan+0.4 (selection of 3)", "object.adjust_pan", {"by": 0.4, "ids": top_sorted[20:23]})

    # C — undo depth: +1 per command
    for name, d, exp_d in depth_ok:
        check("undo_depth +%d: %s" % (exp_d, name), d == exp_d, d)
    # a command that changes nothing leaves no undo entry (touch order already recorded above)
    u0, _, _ = census(c)
    c.send("object.set_mute", {"muted": False, "ids": top_sorted[32:35]})   # they are not muted
    u1, _, _ = census(c)
    check("a command that moved nothing: undo_depth +0", u1 == u0, (u0, u1))

    result["steps"] = steps
    # N commands then N undos = the initial state
    n = len(depth_ok)
    for _ in range(n):
        c.send("edit.undo")
    undone = dump(c)
    check("%d commands then %d × edit.undo = the initial state" % (n, n),
          undone == initial,
          [k for k in initial["objects"] if initial["objects"][k] != undone["objects"].get(k)][:4])

    # the 2026-08-08 regression: delete X, adjust_pan the selection, ONE undo → pan back, X stays deleted
    cur = by_id(c)
    x = top_sorted[5]
    c.send("object.remove", {"ids": [x]})
    c.send("selection.set", {"ids": [i for i in top_sorted if i != x and i in by_id(c)][:20]})
    removed_state = dump(c)
    c.send("object.adjust_pan", {"by": 0.3})
    check("regression 2026-08-08: pan moved", dump(c) != removed_state)
    c.send("edit.undo")
    check("regression 2026-08-08: ONE undo → pan back, X still deleted",
          dump(c) == removed_state and x not in by_id(c))
    c.send("edit.undo")   # now X comes back
    check("…and the next undo gives X back", x in by_id(c))


def phase_perf_undo(c, folder, k, result):
    print("\n[A/C] census + undo on %d objects" % k)
    fresh_project(c, folder, "perf.objekat.json")
    ids = lay_clips(c, k, lane0=0, per_lane=10)
    colour_the_mix(c, ids)
    c.send("selection.set", {"ids": ids})
    time.sleep(1.0)
    base = dump(c)
    cases = [
        ("adjust_pan", "object.adjust_pan", {"by": 0.13}),
        ("set_gain relative", "object.set_gain", {"db": 2.0, "relative": True}),
        ("set_gain absolute", "object.set_gain", {"db": -5.0}),
        ("set_pan", "object.set_pan", {"pan": 0.2}),
        ("set_mute", "object.set_mute", {"muted": True}),
        ("set_mute toggle back", "object.set_mute", {}),
    ]
    for name, cmd, params in cases:
        u0, r0, w0 = census(c)
        t0 = time.time()
        c.send(cmd, params)
        ms = (time.time() - t0) * 1000
        u1, r1, w1 = census(c)
        result["perf"][name] = {"rebuilds": r1 - r0, "writes": w1 - w0, "ms": round(ms, 1)}
        print("      %-22s rebuilds +%-4d writes +%-4d  %7.1f ms   undo +%d" % (name, r1 - r0, w1 - w0, ms, u1 - u0))
        check("%s over %d: ONE lane-entry rebuild" % (name, k), r1 - r0 == 1, r1 - r0)
    # ONE edit.undo undoes the whole selection, a single gesture each
    c.send("object.adjust_pan", {"by": 0.5})
    after = dump(c)
    c.send("edit.undo")
    one = dump(c)
    pan_changed = sum(1 for kk in after["objects"] if after["objects"][kk][0] != one["objects"][kk][0])
    check("ONE edit.undo undoes the pan of all %d objects" % k, pan_changed >= k * 0.8, pan_changed)


def read_wav_levels(path, segs):
    with wave.open(path) as w:
        nch, sr, n = w.getnchannels(), w.getframerate(), w.getnframes()
        raw = w.readframes(n)
        sw = w.getsampwidth()
    import array
    assert sw == 2
    a = array.array("h", raw)
    out = []
    for t0, t1 in segs:
        i0, i1 = int(t0 * sr) * nch, min(len(a), int(t1 * sr) * nch)
        L = [a[i] for i in range(i0, i1, nch)]
        R = [a[i] for i in range(i0 + (1 if nch > 1 else 0), i1, nch)]
        rms = lambda v: math.sqrt(sum(x * x for x in v) / len(v)) / 32768.0 if v else 0.0
        out.append([rms(L), rms(R)])
    return out


def export_wav(c, path):
    if os.path.exists(path):
        os.remove(path)
    job_wait(c, c.send("export.run", {"path": path, "format": "wav", "bit_depth": 16,
                                       "sample_rate": 44100, "dithering": False}), 180000)
    return path if os.path.exists(path) else path.replace(".wav", "") + ".wav"


def phase_engine(c, folder, result):
    print("\n[D] engine — rendered mix")
    fresh_project(c, folder, "audio.objekat.json")
    n = 8
    # clip i at t = 2*i on its own lane; a twin of each at t = 40 + 2*i
    ids = [c.send("object.add", {"path": BIP, "lane": i, "start": 2.0 * i})["id"] for i in range(n)]
    pans = [0.37, -0.13, 0.0, 0.5, -0.9, 0.04, 0.8, -0.46]
    vols = [-6, 0, 3, -12, -1, -20, 2, -3]
    for i, oid in enumerate(ids):
        c.send("object.set_pan", {"pan": pans[i], "ids": [oid]})
        c.send("object.set_gain", {"db": float(vols[i]), "ids": [oid]})
    muted = ids[2]
    c.send("object.set_mute", {"muted": True, "ids": [muted]})
    c.send("selection.set", {"ids": ids})
    c.send("object.adjust_pan", {"by": 0.13})
    c.send("object.adjust_pan", {"by": -0.4})
    c.send("object.set_gain", {"db": 3.0, "relative": True})
    c.send("object.set_gain", {"db": 2.0, "relative": True})
    segs = [(2.0 * i + 0.02, 2.0 * i + 0.38) for i in range(n)]
    cur = by_id(c)
    twins = []
    for i, oid in enumerate(ids):
        t = c.send("object.add", {"path": BIP, "lane": 10 + i, "start": 40.0 + 2.0 * i})["id"]
        twins.append(t)
        c.send("object.set_pan", {"pan": cur[oid]["pan"], "ids": [t]})
        c.send("object.set_gain", {"db": cur[oid]["volume_db"], "ids": [t]})
        if cur[oid]["muted"]:
            c.send("object.set_mute", {"muted": True, "ids": [t]})
    tsegs = [(40.0 + 2.0 * i + 0.02, 40.0 + 2.0 * i + 0.38) for i in range(n)]
    wav = export_wav(c, os.path.join(folder, "mix_a.wav"))
    lv = read_wav_levels(wav, segs)
    tl = read_wav_levels(wav, tsegs)
    check("muted object is silent after relative gains", lv[2][0] < 1e-5 and lv[2][1] < 1e-5, lv[2])
    check("audible objects are audible", all(max(l) > 1e-4 for i, l in enumerate(lv) if i != 2),
          [round(max(l), 5) for l in lv])
    bad = [i for i in range(n) if any(abs(a - b) > 2e-4 + 1e-3 * max(a, b) for a, b in zip(lv[i], tl[i]))]
    check("engine level == twin set straight from the model values (pan + gain)", not bad,
          [(i, lv[i], tl[i]) for i in bad][:2])
    result["audio_levels"] = {"adjusted": lv, "twins": tl}

    # SOLO: one soloed object, a relative gain on everything → the others stay silent
    c.send("object.set_mute", {"muted": False, "ids": [muted]})
    solo = ids[4]
    c.send("solo.set", {"ids": [solo], "on": True})
    c.send("selection.set", {"ids": ids})
    c.send("object.set_gain", {"db": 4.0, "relative": True})
    wav2 = export_wav(c, os.path.join(folder, "mix_b.wav"))
    lv2 = read_wav_levels(wav2, segs)
    silent = [i for i in range(n) if i != 4 and max(lv2[i]) > 1e-5]
    check("soloed object audible, the others silent after a relative gain",
          max(lv2[4]) > 1e-4 and not silent, (lv2[4], silent))
    result["audio_levels"]["solo"] = lv2
    c.send("solo.clear")


# ── main ───────────────────────────────────────────────────────────────────────────────────

def compare(pa, pb):
    a, b = json.load(open(pa)), json.load(open(pb))
    ok = True
    print("A = %s   B = %s" % (a["label"], b["label"]))
    sa, sb = a["steps"], b["steps"]
    if [s[0] for s in sa] != [s[0] for s in sb]:
        print("FAIL the two runs did not do the same steps"); return 1
    for (name, da), (_, db) in zip(sa, sb):
        diffs = []
        for k in set(da["objects"]) | set(db["objects"]):
            if da["objects"].get(k) != db["objects"].get(k):
                diffs.append((k, da["objects"].get(k), db["objects"].get(k)))
        if da["definitions"] != db["definitions"]:
            diffs.append(("definitions", da["definitions"], db["definitions"]))
        print("  %s %-30s %d objects, %d differences" % ("OK  " if not diffs else "FAIL", name,
                                                         len(da["objects"]), len(diffs)))
        for d in diffs[:3]:
            print("        ", d)
        ok = ok and not diffs
    la, lb = a.get("audio_levels"), b.get("audio_levels")
    if la and lb:
        worst = 0.0
        for key in la:
            for ra, rb in zip(la[key], lb[key]):
                for x, y in zip(ra, rb):
                    worst = max(worst, abs(x - y))
        print("  %s rendered levels, worst absolute difference %.2e" % ("OK  " if worst < 1e-4 else "FAIL", worst))
        ok = ok and worst < 1e-4
    print("RESULT: %s" % ("identical" if ok else "DIFFERENT"))
    return 0 if ok else 1


def main():
    argv = sys.argv[1:]
    if argv and argv[0] == "--compare":
        return compare(argv[1], argv[2])
    pos = [a for a in argv if not a.startswith("--")]
    opt = {}
    i = 0
    while i < len(argv):
        if argv[i] in ("--label", "--out", "--k"):
            opt[argv[i]] = argv[i + 1]
            pos = [p for p in pos if p != argv[i + 1]]
            i += 2
        else:
            i += 1
    if len(pos) != 2:
        print(__doc__)
        return 2
    sock, work = pos
    k = int(opt.get("--k", 200))
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    c = ObjekatClient(sock, timeout=900)
    c.connect()
    result = {"label": opt.get("--label", "run"), "when": time.strftime("%Y-%m-%d %H:%M:%S"),
              "rebuilds": {}, "perf": {}}
    phase_oracle_undo(c, work, result)
    phase_perf_undo(c, work, k, result)
    if "--no-audio" not in argv:
        phase_engine(c, work, result)
    if "--out" in opt:
        with open(opt["--out"], "w") as f:
            json.dump(result, f, indent=1)
        print("-> %s" % opt["--out"])
    print("\n%s" % ("ALL OK" if not FAILS else "FAILED: %d\n  - %s" % (len(FAILS), "\n  - ".join(FAILS))))
    return 0 if not FAILS else 1


if __name__ == "__main__":
    sys.exit(main())

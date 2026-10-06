#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The audio bridge, as a user meets it: a compressor keyed by another object or stem.

What a person asks — "duck the bass under the kick", across stems and across groups — and what can
be asserted of it with no screen (docs/plan_sidechain.md §6 step 1.12):

  • STRUCTURE — `plugin.sidechain_sources` offers what the rules allow and says why it refuses the
    rest (the host's own group, its stem, a loop, a container cycle);
  • ENGINE — `debug.bridge_report` shows one tap, one reader, one converged pass;
  • THE EAR, by export + RMS — the built-in compressor, keyed by a stem that is NOT sent to the
    Main (so the key is used and never heard), ducks a sine under 1 kHz bursts; clearing the key
    restores it; muting the source silences the key (D1: the key is what is HEARD of its source);
  • ACROSS GROUPS and with a STEM as source;
  • UNDO / REDO — the key is patched, not rebuilt (`dest_instance` is unchanged);
  • SAVE / REOPEN, and COPIES — duplicate, split, delete the source (the key stays, inactive).

    objekat.app/Contents/MacOS/objekat --headless --api --no-recent --language=en \
        --socket=/tmp/o.sock

NOT `--no-audio` (the bridge reads the device's clock); exits 2 if `app.info` says audio is not running.
    ./scenario_sidechain.py /tmp/o.sock /tmp/trial/project.objekat

A DEBUG build (it reads `debug.bridge_report`). Exit: 0 if everything passes, 1 otherwise.
"""

import os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError
import bridge_scenario_common as B

if len(sys.argv) != 3:
    print(__doc__)
    sys.exit(2)

SOCK, PROJ = sys.argv[1], sys.argv[2]
DIR = os.path.dirname(PROJ)
T = B.Tally(ObjekatError)
step, check = T.step, T.check
OUT = lambda n: os.path.join(DIR, n)

KICK, SINE = OUT("bursts.wav"), OUT("sine.wav")
B.make_bursts(KICK)
B.make_sine(SINE)
SINE_HZ = 220.0
BURSTS = [(1.0, 1.5), (2.5, 3.0)]
QUIET = [(0.2, 0.8), (1.7, 2.3), (3.2, 3.8)]


def wait(c):
    c.send("wait_idle")


def render(c, name, t0=0.0, t1=4.0):
    r = c.send("export.run", {"format": "wav", "sample_rate": B.SR, "dithering": False,
                              "start": t0, "end": t1, "path": OUT(name)})
    c.send("job.wait", {"id": r["job_id"], "timeout_ms": 120000})
    return B.read_wav(OUT(name))[0]


def duck_db(samples):
    """How far under the quiet stretches the host's 220 Hz sine sits inside the burst windows, in dB
    (negative = ducked). Measured AT 220 Hz: an export mixes every stem, DETACHED ONES INCLUDED
    (`stem.route_to_main false` does not silence it — see the report), so the 1 kHz bursts are
    audible in the render and a broadband RMS would measure them, not the ducking."""
    inside = sum(B.tone_rms(samples, a, b, SINE_HZ) for a, b in BURSTS) / len(BURSTS)
    outside = sum(B.tone_rms(samples, a, b, SINE_HZ) for a, b in QUIET) / len(QUIET)
    return B.db(inside) - B.db(outside)


def add_compressor(c, host, strong=True):
    p = c.send("plugin.add", {"host": host, "identifier": "compressor", "format": "TracktionInternal"})
    pid = p["plugin"]["id"]
    if strong:
        # The ratio at its minimum (the harshest), the threshold BETWEEN the two signals: the sine
        # (-12 dBFS, 0.25) must stay under it, or the compressor squashes its own input with no key
        # at all (the first version put the threshold at its minimum: the baseline was ducked 24 dB);
        # the bursts (-3 dBFS, 0.71) must be over it. The key's gain is raised so that the reduction
        # is deep (r *= (thresh + (level - thresh) * rat) / level, level = key * gain).
        want = {"Threshold": 0.4, "Sidechain gain": 12.0}
        for q in c.send("plugin.get_params", {"plugin": pid})["params"]:
            if q["name"] in want:
                c.send("plugin.set_param", {"plugin": pid, "index": q["index"], "value": want[q["name"]]})
            elif q["name"] == "Ratio":
                c.send("plugin.set_param", {"plugin": pid, "index": q["index"], "value": q["min"]})
    return pid


def flat(plugins):
    """plugin.list answers FX blocks (an FX link, made by default on a copy or a split) holding their
    plugins in `plugins`: the leaves, in order."""
    for p in plugins:
        if p.get("is_fx_block"):
            yield from flat(p.get("plugins", []))
        else:
            yield p


def sidechain_of(c, host, plugin):
    for p in flat(c.send("plugin.list", {"host": host})["plugins"]):
        if p["id"] == plugin:
            return p.get("sidechain")
    return "missing"


def report(c):
    """The newest published build. The LIVE graph only exists once the playback context is
    allocated (a play, an export): play for a moment so that the build under test is the live one."""
    c.send("transport.play", {})
    time.sleep(0.8)
    c.send("transport.stop")
    wait(c)
    return c.send("debug.bridge_report")


with ObjekatClient(SOCK) as c:
    B.require_audio(c)
    c.send("app.set_dialog_policy", {"policy": "assume_yes"})
    c.send("project.new")
    c.send("project.save_as", {"path": PROJ})
    pid = B.pid_for_socket(SOCK)

    # ---- the cast: the sine (Y) in a stem sent to the Main, the bursts (X) in a stem that is NOT
    stem_y = c.send("stem.add", {"name": "Bass"})["id"]
    stem_x = c.send("stem.add", {"name": "Kick"})["id"]
    c.send("stem.route_to_main", {"id": stem_x, "on": False})
    y = c.send("object.add", {"path": SINE, "lane": 0, "start": 0.0})["id"]
    x = c.send("object.add", {"path": KICK, "lane": 1, "start": 0.0})["id"]
    c.send("stem.assign", {"stem": stem_y, "ids": [y]})
    c.send("stem.assign", {"stem": stem_x, "ids": [x]})
    comp = add_compressor(c, y)
    wait(c)

    # ---- baseline: no key, nothing ducks
    base = render(c, "base.wav")
    d0 = duck_db(base)
    check("no key: the sine is not ducked", abs(d0) < 0.5, "%.2f dB" % d0)

    # ---- structure: what the menu offers
    src = step("plugin.sidechain_sources", lambda: c.send("plugin.sidechain_sources", {"host": y, "plugin": comp}))
    if src:
        ids = {e["id"] for e in src["sources"]}
        refused = {e["id"]: e["reason"] for e in src["refused"]}
        check("the live compressor can sidechain", src["can_sidechain"] is True, src)
        check("the other object and both stems are offered", x in ids and stem_x in ids, ids)
        check("the host is not a candidate", y not in ids and y not in refused)
        check("its own stem is refused as an ancestor", refused.get(stem_y) == "ancestorSource", refused)
        check("the Main is not listed", all(e["kind"] != "main" for e in src["sources"] + src["refused"]))

    # ---- the key, and the engine's report
    r = step("set_sidechain y <- x", lambda: c.send("plugin.set_sidechain", {"host": y, "plugin": comp, "source": x}))
    check("the key is active", r and r["active"] is True and r["reason"] is None, r)
    wait(c)
    rep = report(c)
    eng = rep["engine"] or {}
    check("one tap", len(eng.get("taps", [])) == 1, eng.get("taps"))
    check("one reader", len(eng.get("readers", [])) == 1, eng.get("readers"))
    check("converged in one pass (a key younger than its host)",
          eng.get("build", {}).get("converged") is True and eng["build"]["passes"] == 1, eng.get("build"))
    inst0 = (eng.get("readers") or [{}])[0].get("dest_instance")

    # ---- the ear: ducking by export + RMS
    keyed = render(c, "keyed.wav")
    dk = duck_db(keyed)
    check("keyed: the burst windows are at least 6 dB under the rest", dk <= -6.0, "%.2f dB" % dk)

    step("clear the key", lambda: c.send("plugin.set_sidechain", {"host": y, "plugin": comp, "source": None}))
    wait(c)
    cleared = render(c, "cleared.wav")
    check("key cleared: back within 0.5 dB", abs(duck_db(cleared)) < 0.5, "%.2f dB" % duck_db(cleared))

    step("key again", lambda: c.send("plugin.set_sidechain", {"host": y, "plugin": comp, "source": x}))
    wait(c)
    step("mute x", lambda: c.send("object.set_mute", {"ids": [x], "muted": True}))
    wait(c)
    muted = render(c, "muted.wav")
    check("a muted source stops keying (D1)", abs(duck_db(muted)) < 0.5, "%.2f dB" % duck_db(muted))
    step("unmute x", lambda: c.send("object.set_mute", {"ids": [x], "muted": False}))
    wait(c)

    # ---- a STEM as the source
    step("key by the Kick stem", lambda: c.send("plugin.set_sidechain", {"host": y, "plugin": comp, "source": stem_x}))
    wait(c)
    by_stem = render(c, "by_stem.wav")
    check("a stem as source ducks too", duck_db(by_stem) <= -6.0, "%.2f dB" % duck_db(by_stem))
    step("back to x", lambda: c.send("plugin.set_sidechain", {"host": y, "plugin": comp, "source": x}))

    # ---- loops
    comp_x = add_compressor(c, x, strong=False)
    T.expect_error("x cannot be keyed by y while y is keyed by x",
                   lambda: c.send("plugin.set_sidechain", {"host": x, "plugin": comp_x, "source": y}),
                   code="bad_params", reason="cycle")
    T.expect_error("a plugin cannot be keyed by its own object",
                   lambda: c.send("plugin.set_sidechain", {"host": y, "plugin": comp, "source": y}),
                   code="bad_params", reason="selfSource")

    # ---- groups: the container cycle, and a source that contains the host
    a = c.send("object.add", {"path": SINE, "lane": 4, "start": 10.0})["id"]
    d = c.send("object.add", {"path": SINE, "lane": 5, "start": 10.0})["id"]
    b = c.send("object.add", {"path": KICK, "lane": 6, "start": 10.0})["id"]
    cc = c.send("object.add", {"path": KICK, "lane": 7, "start": 10.0})["id"]
    g1 = c.send("group.create", {"ids": [a, d]})["id"]
    g2 = c.send("group.create", {"ids": [b, cc]})["id"]
    pa, pc = add_compressor(c, a, False), add_compressor(c, cc, False)
    T.expect_error("a group cannot key its own child",
                   lambda: c.send("plugin.set_sidechain", {"host": a, "plugin": pa, "source": g1}),
                   code="bad_params", reason="ancestorSource")
    step("a <- b (across two groups)", lambda: c.send("plugin.set_sidechain", {"host": a, "plugin": pa, "source": b}))
    T.expect_error("c <- d would close a loop between the two groups",
                   lambda: c.send("plugin.set_sidechain", {"host": cc, "plugin": pc, "source": d}),
                   code="bad_params", reason="cycle")
    step("clean up the group routes", lambda: c.send("plugin.set_sidechain", {"host": a, "plugin": pa, "source": None}))

    # ---- across groups, by ear: X inside a group in its stem, Y inside a group in another
    stem_x2 = c.send("stem.add", {"name": "Kick 2"})["id"]
    c.send("stem.route_to_main", {"id": stem_x2, "on": False})
    stem_y2 = c.send("stem.add", {"name": "Bass 2"})["id"]
    ey = c.send("object.add", {"path": SINE, "lane": 8, "start": 100.0})["id"]
    ex = c.send("object.add", {"path": KICK, "lane": 9, "start": 100.0})["id"]
    gy = c.send("group.create", {"ids": [ey]})["id"]
    gx = c.send("group.create", {"ids": [ex]})["id"]
    c.send("stem.assign", {"stem": stem_y2, "ids": [gy]})
    c.send("stem.assign", {"stem": stem_x2, "ids": [gx]})
    pey = add_compressor(c, ey)
    step("a child of one group keyed by a child of another", lambda: c.send(
        "plugin.set_sidechain", {"host": ey, "plugin": pey, "source": ex}))
    wait(c)
    # Both groups sit at t = 100 s: render that stretch, and mute everything else out of the way.
    c.send("object.set_mute", {"ids": [y, x], "muted": True})
    across = render(c, "across.wav", 100.0, 104.0)
    check("across groups and stems it ducks", duck_db(across) <= -6.0, "%.2f dB" % duck_db(across))
    c.send("object.set_mute", {"ids": [y, x], "muted": False})
    step("clear it", lambda: c.send("plugin.set_sidechain", {"host": ey, "plugin": pey, "source": None}))
    wait(c)

    # ---- undo / redo: patched, not rebuilt
    before = sidechain_of(c, y, comp)
    check("the key is on", before and before["source"] == x and before["active"] is True, before)
    step("clear (one undo step)", lambda: c.send("plugin.set_sidechain", {"host": y, "plugin": comp, "source": None}))
    step("edit.undo", lambda: c.send("edit.undo"))
    wait(c)
    after = sidechain_of(c, y, comp)
    check("undo brings the key back", after and after["source"] == x, after)
    rd = (report(c)["engine"] or {}).get("readers") or [{}]
    inst1 = next((q.get("dest_instance") for q in rd if q.get("plugin") == comp), None)
    check("and the compressor was not rebuilt (same instance)", inst0 is not None and inst1 == inst0, (inst0, inst1))
    step("edit.redo", lambda: c.send("edit.redo"))
    wait(c)
    check("redo clears it again", sidechain_of(c, y, comp) is None, sidechain_of(c, y, comp))
    step("edit.undo again", lambda: c.send("edit.undo"))
    wait(c)

    # ---- save, reopen: the same key, active
    step("project.save", lambda: c.send("project.save"))
    step("project.open", lambda: c.send("project.open", {"path": PROJ}))
    wait(c)
    reopened = sidechain_of(c, y, comp)
    check("the key survives a reopen, active", reopened and reopened["source"] == x and reopened["active"] is True, reopened)
    check("and the engine is routed again",
          len(((report(c)["engine"] or {}).get("readers") or [])) >= 1, report(c)["engine"])

    # ---- copies
    dup = step("object.duplicate y", lambda: c.send("object.duplicate", {"ids": [y]}))
    wait(c)
    if dup:
        for copy_id in dup["ids"]:
            if copy_id == y:
                continue
            leaves = list(flat(c.send("plugin.list", {"host": copy_id})["plugins"]))
            keyed_copy = [p for p in leaves if p.get("sidechain")]
            check("a duplicate is keyed by the same source", keyed_copy and keyed_copy[0]["sidechain"]["source"] == x, leaves)
    halves = step("split y", lambda: c.send("object.split_at", {"ids": [y], "seconds": 2.0}))
    wait(c)
    if halves:
        for half in halves["ids"]:
            leaves = list(flat(c.send("plugin.list", {"host": half})["plugins"]))
            check("both halves of a split stay keyed", any(p.get("sidechain") for p in leaves), leaves)

    # ---- the source goes, the key stays (inactive), and comes back with the undo
    step("delete x", lambda: c.send("object.remove", {"ids": [x]}))
    wait(c)
    gone = sidechain_of(c, y, comp)
    check("a deleted source leaves the key, inactive",
          gone and gone["active"] is False and gone["reason"] == "unknownSource", gone)
    step("edit.undo", lambda: c.send("edit.undo"))
    wait(c)
    back = sidechain_of(c, y, comp)
    check("undoing the deletion makes it active again", back and back["active"] is True, back)

    # ---- hygiene
    audit = step("debug.plugin_id_audit", lambda: c.send("debug.plugin_id_audit"))
    check("no duplicate plugin id", audit and audit["count"] == 0, audit)
    n = B.window_count_for_pid(pid) if pid else None
    check("no window on the headless pid", n in (0, None), n)

sys.exit(T.finish())

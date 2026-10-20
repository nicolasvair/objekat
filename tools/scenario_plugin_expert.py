#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The plugin editor's EXPERT bar (engine patch 0045) — a scenario that ASSERTS, on exports re-read in
24 bits, against a headless instance WITH audio (the gain match measures what is PLAYED).

    objekat.app/Contents/MacOS/objekat --headless --api --no-recent --language=en --socket=/tmp/opx.sock
    ./scenario_plugin_expert.py /tmp/opx.sock

What it proves, on a built-in Low Pass over a 1 kHz tone:
  • the TRIMS are heard, live render and render on a copy alike: output −6 dB measured −6, input +6 dB
    measured +6 (the plugin is linear), the coupled nudge (+n in, −n out) leaves the level where it was;
  • a BYPASS bypasses the trims with the plugin;
  • ±24 dB is the range; one undo point per set, the undo PATCHED (same plugin id, same level back);
  • `plugin.list` carries `trims` only when they are not neutral;
  • a manual link (⌘) carries them to the linked instance; a duplicate and a save / reopen keep them;
  • the GAIN MATCH is refused while stopped, and while playing sets the OUTPUT trim so that the export
    comes back to the dry level (within 0.5 dB), the input trim untouched;
  • a built-in publishes no gain-reduction parameter: no candidate;
  • no window on the headless pid.
Exit: 0 if every assertion passes, 1 otherwise; 2 if the instance has no audio.
"""

import math, os, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError
from bridge_scenario_common import SR, _write24, read_wav, rms, db, pid_for_socket, window_count_for_pid

if len(sys.argv) != 2:
    print(__doc__)
    sys.exit(2)

SOCK = sys.argv[1]
TMP = tempfile.mkdtemp(prefix="pluginexpert_")
SRC = os.path.join(TMP, "tone1k.wav")
_write24(SRC, [0.25 * math.sin(2 * math.pi * 1000.0 * i / SR) for i in range(int(6.0 * SR))])

fails, total = [], 0


def check(label, ok, detail=""):
    global total
    total += 1
    if ok:
        print("ok    " + label)
    else:
        fails.append(label)
        print("FAIL  %s   %s" % (label, detail))


def near(a, b, tol):
    return a is not None and b is not None and abs(a - b) <= tol


try:
    with ObjekatClient(SOCK) as c:
        def cmd(_name, **params):
            return c.send(_name, params or None)

        def refused(_name, **params):
            try:
                c.send(_name, params or None)
                return None
            except ObjekatError as e:
                return (e.code, (e.details or {}).get("reason"))

        def idle():
            cmd("wait_idle", timeout_ms=30000)

        if not cmd("app.info").get("audio_running"):
            print("this scenario needs an instance WITH audio (no --no-audio)")
            sys.exit(2)

        n_render = [0]

        def render(background=False):
            n_render[0] += 1
            out = os.path.join(TMP, "r%02d.wav" % n_render[0])
            r = cmd("export.run", format="wav", sample_rate=SR, bit_depth=24, dithering=False,
                    start=0.0, end=2.0, path=out, background=background)
            cmd("job.wait", id=r["job_id"], timeout_ms=60000)
            return read_wav(out)

        def level(background=False):
            return db(rms(render(background)[0], 0.5, 1.8))

        def trims(pid):
            t = cmd("plugin.trims", plugin=pid)
            return (t["input_db"], t["output_db"])

        def listed(host, pid):
            return next(p for p in cmd("plugin.list", host=host)["plugins"] if p["id"] == pid)

        cmd("app.set_dialog_policy", policy="assume_yes")
        cmd("project.new")
        A = cmd("object.add", path=SRC, lane=0, start=0)["id"]
        idle()
        L_dry = level()

        P = cmd("plugin.add", host=A, identifier="lowpass", format="TracktionInternal")["plugin"]["id"]
        cmd("plugin.set_param", plugin=P, index=0, value=400.0)
        idle()
        L_wet = level()
        check("the low pass at 400 Hz lowers the 1 kHz tone by more than 3 dB", L_dry - L_wet > 3.0,
              "dry %.2f wet %.2f" % (L_dry, L_wet))

        # ── trims are heard ───────────────────────────────────────────────
        check("a fresh plugin has neutral trims", trims(P) == (0, 0), str(trims(P)))
        check("plugin.list omits neutral trims", "trims" not in listed(A, P))
        cmd("plugin.set_trims", plugin=P, output=-6.0)
        idle()
        check("plugin.trims reads the output trim", trims(P) == (0, -6), str(trims(P)))
        check("plugin.list carries the trims", listed(A, P).get("trims") == {"input_db": 0, "output_db": -6},
              str(listed(A, P).get("trims")))
        l = level()
        check("output −6 dB is heard as −6 dB (live render)", near(l - L_wet, -6.0, 0.05), "%.3f" % (l - L_wet))
        l = level(background=True)
        check("...and on a render on a copy", near(l - L_wet, -6.0, 0.05), "%.3f" % (l - L_wet))

        cmd("plugin.set_trims", plugin=P, input=6.0, output=0.0)
        idle()
        l = level()
        check("input +6 dB is heard as +6 dB (a linear plugin)", near(l - L_wet, 6.0, 0.05), "%.3f" % (l - L_wet))

        cmd("plugin.set_trims", plugin=P, input=0.0, output=0.0)
        r = cmd("plugin.nudge_trims", plugin=P, delta=5.0)
        idle()
        check("the coupled nudge moves +n in / −n out", trims(P) == (5, -5), str(trims(P)))
        l = level()
        check("...and leaves a linear plugin's level where it was", near(l - L_wet, 0.0, 0.05), "%.3f" % (l - L_wet))

        cmd("plugin.set_trims", plugin=P, input=20.0, output=-20.0)
        cmd("plugin.nudge_trims", plugin=P, delta=10.0)
        check("the nudge stops at ±24 dB", trims(P) == (24, -24), str(trims(P)))
        cmd("plugin.set_trims", plugin=P, input=40.0, output=-40.0)
        check("a set is clamped to ±24 dB", trims(P) == (24, -24), str(trims(P)))

        # ── bypass ────────────────────────────────────────────────────────
        cmd("plugin.set_trims", plugin=P, input=0.0, output=-12.0)
        cmd("plugin.toggle", host=A, plugin=P)
        idle()
        l = level()
        check("a bypass bypasses the trims (dry level)", near(l, L_dry, 0.05), "%.3f vs %.3f" % (l, L_dry))
        cmd("plugin.toggle", host=A, plugin=P)
        idle()
        l = level()
        check("switched back on, the trims are heard again", near(l - L_wet, -12.0, 0.05), "%.3f" % (l - L_wet))

        # ── undo / redo, patched ──────────────────────────────────────────
        cmd("plugin.set_trims", plugin=P, input=0.0, output=-3.0)
        idle()
        cmd("edit.undo"); idle()
        check("undo gives the previous trims back", trims(P) == (0, -12), str(trims(P)))
        check("...on the SAME plugin (no rebuild)", any(p["id"] == P for p in cmd("plugin.list", host=A)["plugins"]))
        l = level()
        check("...and the engine follows", near(l - L_wet, -12.0, 0.05), "%.3f" % (l - L_wet))
        cmd("edit.redo"); idle()
        check("redo lays them again", trims(P) == (0, -3), str(trims(P)))
        l = level()
        check("...and the engine follows the redo", near(l - L_wet, -3.0, 0.05), "%.3f" % (l - L_wet))

        # ── gain reduction on a built-in ──────────────────────────────────
        gr = cmd("plugin.gain_reduction", plugin=P)
        check("a built-in publishes no gain-reduction candidate", gr["candidates"] == [] and gr["chosen"] is None,
              str(gr))

        # ── link, duplicate ───────────────────────────────────────────────
        B = cmd("object.add", path=SRC, lane=1, start=10.0)["id"]
        idle()
        LP = cmd("plugin.link", **{"from": A, "plugin": P, "to": B})["plugins"][0]
        idle()
        check("a linked copy carries the trims", trims(LP) == (0, -3), str(trims(LP)))
        cmd("plugin.set_trims", plugin=P, input=2.0, output=-4.0)
        check("a set on a linked plugin moves its linked instance", trims(LP) == (2, -4), str(trims(LP)))
        cmd("plugin.set_trims", plugin=LP, input=0.0, output=-3.0)
        check("...both ways", trims(P) == (0, -3), str(trims(P)))

        before = {o["id"] for o in cmd("object.list")["objects"]}
        cmd("object.duplicate", ids=[A])
        idle()
        D = [o["id"] for o in cmd("object.list")["objects"] if o["id"] not in before]
        dp = [p for p in cmd("plugin.list", host=D[0])["plugins"] if p.get("identifier") == "lowpass"] if D else []
        check("a duplicate keeps the trims", bool(dp) and dp[0].get("trims") == {"input_db": 0, "output_db": -3},
              str(dp))

        # ── save / reopen ─────────────────────────────────────────────────
        path = os.path.join(TMP, "expert.objekat")
        cmd("project.save_as", path=path)
        idle()
        with open(path) as f:
            text = f.read()
        import json
        doc = json.loads(text)
        check("the session is written in format 27", doc.get("version") == 27, str(doc.get("version")))
        check("the file carries outputTrimDb", '"outputTrimDb"' in text)
        cmd("project.new")
        cmd("project.open", path=path)
        idle()
        check("reopened, the trims are back", trims(P) == (0, -3), str(trims(P)))
        l = level()
        check("...and heard", near(l - L_wet, -3.0, 0.05), "%.3f" % (l - L_wet))

        # ── gain match ────────────────────────────────────────────────────
        cmd("plugin.set_trims", plugin=P, input=0.0, output=0.0)
        idle()
        e = refused("plugin.gain_match", plugin=P)
        check("the gain match is refused while stopped", e is not None and e[0] == "invalid_state", str(e))
        cmd("plugin.measure_loudness", plugin=P, on=True)
        cmd("transport.play", seconds=0.0)
        time.sleep(3.0)
        loud = cmd("plugin.loudness", plugin=P)
        check("the probe measured blocks while playing", loud.get("blocks", 0) >= 10, str(loud))
        g = cmd("plugin.gain_match", plugin=P)
        cmd("transport.stop")
        cmd("plugin.measure_loudness", plugin=P, on=False)
        t = trims(P)
        check("the gain match leaves the input trim alone", t[0] == 0, str(t))
        check("the gain match sets an output trim near the plugin's loss", near(t[1], L_dry - L_wet, 0.5),
              "%s vs %.2f" % (t, L_dry - L_wet))
        idle()
        l = level()
        check("after the gain match the export is back at the dry level", near(l, L_dry, 0.5),
              "%.2f vs %.2f" % (l, L_dry))
        cmd("edit.undo"); idle()
        check("one undo takes the gain match back", trims(P) == (0, 0), str(trims(P)))

        pid = pid_for_socket(SOCK)
        if pid:
            check("no window on the headless pid", window_count_for_pid(pid) == 0)
except ObjekatError as e:
    fails.append("api error: %s" % e)
    print("FAIL  api error: %s" % e)

print("\n%d checks, %d failed" % (total, len(fails)))
if fails:
    for f in fails:
        print("  - " + f)
sys.exit(1 if fails else 0)

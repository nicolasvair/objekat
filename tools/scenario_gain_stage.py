#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The GAIN STAGE (plan_synoptic_rework B.0.1 / B.0.5) — a scenario that ASSERTS, on exports re-read
in 24 bits.

    # 1. launch the app with the API, on a SHORT socket (a system limit: 103 bytes)
    objekat.app/Contents/MacOS/objekat --headless --api --no-recent --no-audio --language=en --socket=/tmp/ogs.sock
    # 2. run
    ./scenario_gain_stage.py /tmp/ogs.sock

What it proves:
  • `plugin.add_gain_stage` lays a stage (`plugin.list` shows `gain_stage`), opens no window, and the
    stage is HEARD: -6 dB measured -6 ± 0.05 dB, its mute under -90 dBFS, the gain+pan+mute face's
    pan -1 silences the right channel (< -60 dB);
  • the two faces have the SAME parameter list (gain, pan, mute) — linked instances pair by index;
  • refusals: a gain out of ±24 dB, a bypass (`plugin.toggle`, `toggle_selected`), a full chain;
  • ONE undo point per add and per set, and undoing them gives the reference back bit for bit;
  • in an FX link the stage joins the DEFINITION: every member gets an instance, a set on one moves
    the others; on a send's mini-chain it is accepted;
  • a cut leaves a stage on both halves, at the same values; a save and a reopen keep them;
  • on the Main it survives a reopen as a USER plugin (the master anchor stays neutral);
  • the plugin ids stay unique (`debug.plugin_id_audit`, DEBUG builds).

Exit: 0 if every assertion passes, 1 otherwise.
"""

import math, os, shutil, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError
from bridge_scenario_common import SR, _write24, read_wav, rms, db, pid_for_socket, window_count_for_pid

if len(sys.argv) != 2:
    print(__doc__)
    sys.exit(2)

SOCK = sys.argv[1]
TMP = tempfile.mkdtemp(prefix="gainstage_")
SRC = os.path.join(TMP, "tone1k.wav")


def _write24_stereo(path, samples):
    """The same tone on both channels. STEREO on purpose: on a MONO clip the fader copies left to right
    after the chain (a mono source is centred there), which would erase any pan laid before it."""
    import wave
    raw = bytearray()
    for v in samples:
        b = max(-8388608, min(8388607, int(round(v * 8388607.0)))).to_bytes(3, "little", signed=True)
        raw += b + b
    with wave.open(path, "wb") as w:
        w.setnchannels(2); w.setsampwidth(3); w.setframerate(SR); w.writeframes(bytes(raw))


_write24_stereo(SRC, [0.5 * math.sin(2 * math.pi * 1000.0 * i / SR) for i in range(int(2.0 * SR))])

fails, total = [], 0


def check(label, ok, detail=""):
    global total
    total += 1
    if ok:
        print("ok    " + label)
    else:
        fails.append(label)
        print("FAIL  %s   %s" % (label, detail))


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

        has_audit = refused("debug.plugin_id_audit") is None

        def audit_clean(phase):
            if not has_audit:
                return
            a = cmd("debug.plugin_id_audit")
            check("no duplicated plugin id %s" % phase,
                  a["count"] == 0 and a["engine_foreign_refusals"] == 0, str(a))

        def render(name, end=1.5):
            out = os.path.join(TMP, name)
            r = cmd("export.run", format="wav", sample_rate=SR, bit_depth=24, dithering=False,
                    start=0.0, end=end, path=out)
            cmd("job.wait", id=r["job_id"], timeout_ms=60000)
            return read_wav(out)

        def level(chans, ch=0):
            return db(rms(chans[ch], 0.3, 1.2))

        def maxdiff(a, b):
            n = min(len(a[0]), len(b[0]))
            return max(max(abs(x - y) for x, y in zip(ca[:n], cb[:n])) for ca, cb in zip(a, b))

        def chain(host):
            return cmd("plugin.list", host=host)["plugins"]

        def stages(host):
            out = []
            for p in chain(host):
                if p.get("is_fx_block"):
                    out += [q for q in p["plugins"] if q.get("gain_stage")]
                elif p.get("gain_stage"):
                    out.append(p)
            return out

        def stage(pid):
            return cmd("plugin.gain_stage", plugin=pid)

        LSB = 1.0 / 8388608.0

        cmd("app.set_dialog_policy", policy="assume_yes")
        cmd("project.new")
        X = cmd("object.add", path=SRC, lane=0, start=0)["id"]
        idle()
        ref = render("ref.wav")
        L0 = level(ref)
        check("the reference plays (1 kHz at about -9 dBFS)", -12 < L0 < -6, "%.2f" % L0)

        # ── laying one ─────────────────────────────────────────────────────────────────────────
        r = cmd("plugin.add_gain_stage", host=X, face="gain")
        G = r["plugin"]["id"]
        idle()
        check("the answer names a gain-face stage", r["plugin"].get("gain_stage") == "gain", str(r))
        check("plugin.list shows it with its face", [p["id"] for p in stages(X)] == [G])
        check("a plain plugin says gain_stage null",
              all(("gain_stage" in p) for p in chain(X) if not p.get("is_fx_block")))
        pid = pid_for_socket(SOCK)
        wins = window_count_for_pid(pid) if pid else None
        if wins is None:
            print("skip  no-window check (Quartz unavailable)")
        else:
            on = 0
            try:
                import Quartz
                info = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID)
                on = sum(1 for w in info if w.get("kCGWindowOwnerPID") == pid)
            except Exception:
                pass
            check("adding a stage opens no window", on == 0, "%d on-screen window(s)" % on)
        s = stage(G)
        check("plugin.gain_stage reads it neutral", s["face"] == "gain" and s["gain_db"] == 0 and s["pan"] == 0
              and s["muted"] is False, str(s))
        names = [p["name"] for p in cmd("plugin.get_params", plugin=G)["params"]]
        check("ONE parameter list: gain, pan, mute", names == ["Gain", "Pan", "Mute"], str(names))
        neutral = render("neutral.wav")
        check("a neutral stage is the identity (bit for bit)", maxdiff(neutral, ref) <= LSB,
              "%.3g" % maxdiff(neutral, ref))

        cmd("plugin.set_param", plugin=G, index=0, value=-6.0)
        idle()
        m6 = render("minus6.wav")
        check("-6 dB is heard as -6 ± 0.05 dB", abs(level(m6) - L0 + 6.0) <= 0.05, "%.3f" % (level(m6) - L0))
        check("plugin.gain_stage reads -6", abs(stage(G)["gain_db"] + 6.0) < 1e-4)

        cmd("plugin.set_param", plugin=G, index=2, value=1)
        idle()
        mu = render("muted.wav")
        check("the mute is heard (< -90 dBFS)", level(mu) < -90, "%.1f" % level(mu))
        check("plugin.gain_stage reads muted", stage(G)["muted"] is True)

        # undo: one point per set, and the add's own
        cmd("edit.undo"); idle()
        check("undo of the mute: -6 dB again", abs(level(render("u1.wav")) - L0 + 6.0) <= 0.05)
        cmd("edit.undo"); idle()
        check("undo of the -6: the stage is back to 0 dB", abs(stage(G)["gain_db"]) < 1e-4, str(stage(G)))
        cmd("edit.undo"); idle()
        check("undo of the add: no stage left", stages(X) == [])
        check("...and the reference comes back bit for bit", maxdiff(render("u3.wav"), ref) <= LSB)
        cmd("edit.redo"); idle()
        check("redo lays it again", len(stages(X)) == 1)

        # refusals
        check("gain_db 25 is refused (±24)",
              refused("plugin.add_gain_stage", host=X, face="gain", gain_db=25)
              == ("bad_params", "gain_out_of_range"))
        check("an unknown face is refused", (refused("plugin.add_gain_stage", host=X, face="trim") or ("",))[0]
              == "bad_params")
        G = stages(X)[0]["id"]
        check("plugin.toggle is refused (no bypass)",
              refused("plugin.toggle", host=X, plugin=G) == ("invalid_state", "gain_stage_no_bypass"))
        refused("plugin.select", host=X, plugins=[G])
        sel = cmd("plugin.selection")
        if sel.get("plugins"):
            check("toggle_selected over stages only is refused",
                  refused("plugin.toggle_selected") == ("invalid_state", "gain_stage_no_bypass"))
        else:
            print("skip  toggle_selected (selection not settable)")
        check("the stage stayed enabled", stages(X)[0]["enabled"] is True)

        # ── the gain + pan + mute face ─────────────────────────────────────────────────────────
        cmd("plugin.remove", host=X, plugin=G)
        r = cmd("plugin.add_gain_stage", host=X, face="gain_pan_mute", pan=-1.0)
        P = r["plugin"]["id"]
        idle()
        names2 = [p["name"] for p in cmd("plugin.get_params", plugin=P)["params"]]
        check("the gain+pan+mute face has the SAME list", names2 == names, str(names2))
        pm = render("panleft.wav")
        check("pan -1: the right channel is silent (< -60 dB under the left)",
              len(pm) == 2 and level(pm, 1) < level(pm, 0) - 60, "L %.1f R %.1f" % (level(pm, 0), level(pm, 1)))
        s = stage(P)
        check("plugin.gain_stage reads the face and the pan", s["face"] == "gain_pan_mute" and abs(s["pan"] + 1) < 1e-4,
              str(s))
        cmd("plugin.set_param", plugin=P, index=1, value=0.0)
        cmd("plugin.set_param", plugin=P, index=0, value=-3.0)
        idle()

        # ── a cut, a save, a reopen ────────────────────────────────────────────────────────────
        cmd("object.split_at", seconds=1.0, ids=[X])
        idle()
        objs = [o for o in cmd("object.list")["objects"]]
        halves = [o["id"] for o in objs]
        sv = [stage(st["id"]) for h in halves for st in stages(h)]
        check("the cut leaves a stage on BOTH halves", len(halves) == 2 and len(sv) == 2, str(sv))
        check("...at the same values", all(abs(v["gain_db"] + 3.0) < 1e-4 and v["face"] == "gain_pan_mute" for v in sv),
              str(sv))
        audit_clean("after the cut")
        proj = os.path.join(TMP, "gs", "gs.objekat")
        os.makedirs(os.path.dirname(proj), exist_ok=True)
        cmd("project.save_as", path=proj)
        cmd("project.new")
        cmd("project.open", path=proj)
        idle()
        sv2 = [stage(st["id"]) for h in halves for st in stages(h)]
        check("save + reopen: the stages and their values are back",
              len(sv2) == 2 and all(abs(v["gain_db"] + 3.0) < 1e-4 for v in sv2), str(sv2))

        # ── an FX link: the stage joins the definition ─────────────────────────────────────────
        cmd("project.new")
        A = cmd("object.add", path=SRC, lane=0, start=0)["id"]
        B = cmd("object.add", path=SRC, lane=1, start=0)["id"]
        eq = cmd("plugin.add", host=A, identifier="4bandEq", format="TracktionInternal")["plugin"]["id"]
        LID = cmd("fxlink.create", host=A, plugins=[eq], name="Bin")["id"]
        cmd("fxlink.attach", link=LID, host=B)
        idle()
        blockA = next(p for p in chain(A) if p.get("is_fx_block"))["id"]
        r = cmd("plugin.add_gain_stage", host=A, face="gain", series={"block": blockA}, gain_db=-4.0)
        idle()
        check("in an attached bin the answer names the definition", "definition" in r, str(r))
        sa, sb = stages(A), stages(B)
        check("EVERY member gets an instance", len(sa) == 1 and len(sb) == 1 and sa[0]["id"] != sb[0]["id"],
              "%s / %s" % (sa, sb))
        check("born at -4 dB on both", abs(stage(sa[0]["id"])["gain_db"] + 4) < 1e-4
              and abs(stage(sb[0]["id"])["gain_db"] + 4) < 1e-4)
        cmd("plugin.set_param", plugin=sa[0]["id"], index=0, value=-10.0)
        idle()
        dl = time.time() + 5
        vb = stage(sb[0]["id"])["gain_db"]
        while abs(vb + 10) > 1e-3 and time.time() < dl:
            time.sleep(0.2); vb = stage(sb[0]["id"])["gain_db"]
        check("a set on one member moves the other (mirror by index)", abs(vb + 10) < 1e-3, "%s" % vb)
        check("the bin's stage has no bypass either",
              refused("fxlink.set_plugin_enabled", link=LID, plugin=r["definition"], enabled=False)
              == ("invalid_state", "gain_stage_no_bypass"))
        audit_clean("in a bin")

        # ── a send's mini-chain ─────────────────────────────────────────────────────────────────
        aux = cmd("aux.create", start=0.0, end=2.0, lane=3)["id"]
        cmd("send.create", id=A, aux=aux, position="post_fader")
        r = cmd("plugin.add_gain_stage", host=A, face="gain", series={"send": aux}, gain_db=-6.0)
        idle()
        sl = cmd("send.list", id=A)
        sends = sl.get("sends", sl if isinstance(sl, list) else [])
        sp = [p for s_ in sends if s_.get("aux") == aux for p in s_.get("plugins", [])]
        check("a send's mini-chain takes a stage", len(sp) == 1 and sp[0]["id"] == r["plugin"]["id"], str(sl))
        # The send's WET level rides the audio bridge (the device's clock): it is measured by
        # scenario_bridge_sends.py with audio on, not here.
        print("skip  the send's wet level (measured by scenario_bridge_sends.py, audio on)")
        # full: the mini-chain's capacity
        n = 1
        why = None
        while n < 40:
            why = refused("plugin.add_gain_stage", host=A, face="gain", series={"send": aux})
            if why is not None:
                break
            n += 1
        check("a full mini-chain refuses the stage with chainFull", why == ("invalid_state", "chainFull") and n == 20,
              "after %d: %s" % (n, why))
        audit_clean("on a send")

        # ── the Main ───────────────────────────────────────────────────────────────────────────
        cmd("project.new")
        Y = cmd("object.add", path=SRC, lane=0, start=0)["id"]
        idle()
        refM = level(render("main_ref.wav"))
        main = cmd("stem.list")["main"]
        r = cmd("plugin.add_gain_stage", host=main, face="gain", gain_db=-6.0)
        MG = r["plugin"]["id"]
        idle()
        check("a stage on the Main is heard (-6 dB)", abs(level(render("main_m6.wav")) - refM + 6) <= 0.05)
        projM = os.path.join(TMP, "gm", "gm.objekat")
        os.makedirs(os.path.dirname(projM), exist_ok=True)
        cmd("project.save_as", path=projM)
        cmd("project.new")
        cmd("project.open", path=projM)
        idle()
        ms = stages(main)
        check("after a reopen it is still a USER plugin of the Main", [p["id"] for p in ms] == [MG], str(ms))
        check("...at -6, the master anchor neutral (level still -6)",
              abs(level(render("main_reopen.wav")) - refM + 6) <= 0.05)
        audit_clean("at the end")
except ObjekatError as e:
    fails.append("unexpected error: %s" % e)
    print("FAIL  unexpected error: %s" % e)
finally:
    shutil.rmtree(TMP, ignore_errors=True)

print("\n=== %d checks, %d FAILED ===" % (total, len(fails)))
for f in fails:
    print("  - " + f)
sys.exit(1 if fails else 0)

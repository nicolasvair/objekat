#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The PER-PLUGIN OUTPUT METER (engine patch 0042) — a scenario that ASSERTS, on live playback.

What a person asks: "show me what comes OUT of each card" — a thin line under the synoptic's plugin
cards. The engine measures the plugin's own output (RMS) at the end of PluginNode::process, only for
the plugins a view registered; no node is added to the graph and nothing is rebuilt.

    # 1. launch the app with the API on a SHORT socket (system limit: 103 bytes). NOT --no-audio:
    #    the meters read the audio callback, which only runs with a device open.
    objekat.app/Contents/MacOS/objekat --headless --api --no-recent --language=en --socket=/tmp/opm.sock
    # 2. run
    ./scenario_plugin_meters.py /tmp/opm.sock

The chain under test is [Gain 0 dB -> Gain -20 dB] on a 1 kHz tone; the Main is lowered to -60 dB so
the run is (nearly) silent in the room — the meters sit before it.

What it proves:
  * chain: level(stage 2) is level(stage 1) minus 20 dB (+-1), and stage 1 reads the tone's RMS;
  * stopped transport reads 0; an UNREGISTERED plugin reads 0; registering only stage 1 leaves stage 2 at 0;
  * a BYPASSED plugin reads 0, and reads again once re-enabled;
  * a parallel branch, a send's mini-chain, a stem's chain and the Main's chain each meter their own
    plugins (relative drops between two stages);
  * a MIDI object's instrument meters (when a built-in instrument is available);
  * two owners: withdrawing one leaves the other measured, withdrawing both reads 0;
  * robustness: removing / bypassing / undoing a plugin that is being measured, a reload, an export run
    while measuring — nothing crashes, nothing stale is read;
  * the graph: no rebuild at all when a meter is registered or withdrawn.

A DEBUG build. Exit: 0 if every assertion passes, 1 otherwise.
"""

import math, os, sys, tempfile, time, wave

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError
import bridge_scenario_common as B

if len(sys.argv) not in (2, 3):
    print(__doc__)
    sys.exit(2)

SOCK = sys.argv[1]
GRAPH_LOG = sys.argv[2] if len(sys.argv) == 3 else None   # the app's stderr, to count [GRAPH] rebuilds
SR = B.SR
TMP = tempfile.mkdtemp(prefix="plugmeters_")
TONE = os.path.join(TMP, "tone1k.wav")
TONE_DBFS = 20.0 * math.log10(0.5 / math.sqrt(2.0))      # RMS of a 0.5-peak sine: -9.03 dBFS


def _write_stereo(path, seconds, amp=0.5, hz=1000.0):
    raw = bytearray()
    for i in range(int(seconds * SR)):
        v = amp * math.sin(2 * math.pi * hz * i / SR)
        b = max(-8388608, min(8388607, int(round(v * 8388607.0)))).to_bytes(3, "little", signed=True)
        raw += b + b
    with wave.open(path, "wb") as w:
        w.setnchannels(2); w.setsampwidth(3); w.setframerate(SR); w.writeframes(bytes(raw))


_write_stereo(TONE, 40.0)

T = B.Tally(ObjekatError)


def check(label, cond, detail=""):
    """Tally.check, but the figures are also printed when the check passes (they go in the report)."""
    T.check(label, cond, detail)
    if cond and detail:
        print("         [%s]" % (detail[:110]))


def main():
    with ObjekatClient(SOCK) as c:
        B.require_audio(c)

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

        def graph_rebuilds():
            """How many `[GRAPH] rebuild` lines the app has written to its stderr so far (None = unknown)."""
            if not GRAPH_LOG or not os.path.exists(GRAPH_LOG):
                return None
            with open(GRAPH_LOG, "r", errors="replace") as f:
                return sum(1 for line in f if "[GRAPH] rebuild" in line)

        def db_of(r):
            return r["db"] if r["level"] > 0 else None

        def sample(host, plugins, dur=1.0, every=0.05, skip=0.45, seconds=None):
            """Plays `dur` s and returns, per plugin, the list of the levels read (dB-mapped 0..1 values)
            after `skip` s (the graph's start-up). One read per plugin per `every` s: two reads within 15 ms
            return the same cached value, so this is not a way to read faster than the engine measures."""
            out = {p: [] for p in plugins}
            if seconds is None:
                cmd("transport.play")
            else:
                cmd("transport.play", seconds=seconds)
            t0 = time.time()
            while time.time() - t0 < dur:
                for p in plugins:
                    r = cmd("plugin.level", host=host, plugin=p)
                    if time.time() - t0 >= skip:
                        out[p].append(r["level"])
                time.sleep(every)
            cmd("transport.stop")
            # What the synoptic does at the first poll after a stop: one read per plugin empties the
            # engine's peak-hold, so the next playback does not open on this one's last peak.
            time.sleep(0.05)
            for p in plugins:
                cmd("plugin.level", host=host, plugin=p)
            return out

        def top_db(levels):
            """The steady level in dB: the median of the non-zero reads (0 if nothing was read)."""
            nz = sorted(v for v in levels if v > 0)
            if not nz:
                return None
            return nz[len(nz) // 2] * 60.0 - 60.0

        def reads_zero(levels):
            return len(levels) > 0 and all(v == 0 for v in levels)

        cmd("app.set_dialog_policy", policy="assume_yes")
        cmd("project.new")
        stems = cmd("stem.list")
        MAIN = stems["main"]
        cmd("stem.set_gain", id=MAIN, db=-60)         # nearly silent in the room: the meters sit BEFORE it

        # ---- the chain [Gain 0 -> Gain -20] ---------------------------------------------------------
        X = cmd("object.add", path=TONE, lane=0, start=0)["id"]
        idle()
        G1 = cmd("plugin.add_gain_stage", host=X, face="gain", gain_db=0.0)["plugin"]["id"]
        G2 = cmd("plugin.add_gain_stage", host=X, face="gain", gain_db=-20.0)["plugin"]["id"]
        idle()

        base = graph_rebuilds()

        r = cmd("plugin.level", host=X, plugin=G1)
        check("not registered: reads 0 (stopped)", r["level"] == 0, str(r))
        s = sample(X, [G1, G2], dur=1.2)
        check("not registered: reads 0 while playing", reads_zero(s[G1]) and reads_zero(s[G2]),
              "%s %s" % (s[G1][:4], s[G2][:4]))

        after_reads = graph_rebuilds()
        cmd("plugin.meter", host=X, plugins=[G1, G2])
        idle()
        s = sample(X, [G1, G2], dur=1.6)
        d1, d2 = top_db(s[G1]), top_db(s[G2])
        check("stage 1 reads the tone's RMS (%.2f dBFS +-1.5)" % TONE_DBFS,
              d1 is not None and abs(d1 - TONE_DBFS) <= 1.5, "%s" % d1)
        check("stage 2 reads 20 dB under stage 1 (+-1)",
              d1 is not None and d2 is not None and abs((d1 - d2) - 20.0) <= 1.0, "%s %s" % (d1, d2))
        check("stage 2 stays below stage 1 on every pair of reads",
              all(b < a for a, b in zip(s[G1], s[G2]) if a > 0 and b > 0))

        # the transport stopped: 0 (twice: the first read empties the peak-hold)
        cmd("plugin.level", host=X, plugin=G1)
        time.sleep(0.1)
        r = cmd("plugin.level", host=X, plugin=G1)
        check("stopped transport reads 0", r["level"] == 0, str(r))

        # only stage 1 registered
        cmd("plugin.meter", host=X, plugins=[G1])
        s = sample(X, [G1, G2], dur=1.2)
        check("only stage 1 registered: it reads, stage 2 reads 0",
              top_db(s[G1]) is not None and reads_zero(s[G2]), "%s %s" % (s[G1][:3], s[G2][:3]))
        cmd("plugin.meter", host=X, plugins=[G1, G2])

        # unknown ids are refused as usual
        check("an unknown plugin is not_found",
              (refused("plugin.level", host=X, plugin="00000000-0000-0000-0000-000000000000") or ("",))[0]
              == "not_found")

        # ---- two owners ---------------------------------------------------------------------------
        cmd("plugin.meter", host=X, plugins=[G1], owner="b")
        cmd("plugin.meter", host=X, plugins=[])                       # withdraw "api"
        s = sample(X, [G1, G2], dur=1.2)
        check("withdrawing one owner leaves the other's plugins measured, and only those",
              top_db(s[G1]) is not None and reads_zero(s[G2]), "%s %s" % (s[G1][:3], s[G2][:3]))
        cmd("plugin.meter", host=X, plugins=[], owner="b")
        s = sample(X, [G1, G2], dur=1.0)
        check("every owner withdrawn: reads 0", reads_zero(s[G1]) and reads_zero(s[G2]))
        cmd("plugin.meter", host=X, plugins=[G1, G2])

        # ---- a bypassed plugin reads 0 -------------------------------------------------------------
        fx = [p for p in cmd("plugin.list_available")["plugins"]
              if p["format"] == "TracktionInternal" and not p["is_instrument"]
              and p["identifier"] in ("4bandEq", "lowpass", "chorus", "phaser", "reverb", "delay")]
        P = None
        for cand in fx:
            try:
                r = cmd("plugin.add", host=X, identifier=cand["identifier"], format=cand["format"])
                P = r["plugin"]["id"]
                P_NAME = cand["name"]
                break
            except ObjekatError:
                continue
        if P is None:
            print("skip  no built-in effect to bypass")
        else:
            idle()
            cmd("plugin.meter", host=X, plugins=[G1, G2, P])
            s = sample(X, [P], dur=1.4)
            check("a live built-in (%s) reads a level" % P_NAME, top_db(s[P]) is not None, str(s[P][:4]))
            cmd("plugin.toggle", host=X, plugin=P)
            idle()
            s = sample(X, [P, G1], dur=1.2)
            check("BYPASSED: it reads 0 (and the stage before it still reads)",
                  reads_zero(s[P]) and top_db(s[G1]) is not None, "%s | %s" % (s[P][:4], s[G1][:2]))
            cmd("plugin.toggle", host=X, plugin=P)
            idle()
            s = sample(X, [P], dur=1.4)
            check("re-enabled: it reads again", top_db(s[P]) is not None, str(s[P][:4]))
            # removal while measured: nothing crashes, the read says not_found, the others go on
            cmd("transport.play")
            time.sleep(0.4)
            cmd("plugin.remove", host=X, plugin=P)
            time.sleep(0.3)
            check("removed while measured: not_found",
                  (refused("plugin.level", host=X, plugin=P) or ("",))[0] == "not_found")
            r = cmd("plugin.level", host=X, plugin=G1)
            cmd("transport.stop")
            check("removed while measured: the app is alive and the neighbours still answer", "level" in r)
            cmd("plugin.meter", host=X, plugins=[G1, G2])
            idle()

        # ---- undo / redo of a chain edit while measured -------------------------------------------
        cmd("transport.play")
        time.sleep(0.4)
        cmd("plugin.set_param", plugin=G2, index=0, value=-10.0)
        cmd("edit.undo"); time.sleep(0.2)
        cmd("edit.redo"); time.sleep(0.2)
        cmd("edit.undo"); time.sleep(0.5)
        cmd("transport.stop")
        idle()
        s = sample(X, [G1, G2], dur=1.4)
        d1, d2 = top_db(s[G1]), top_db(s[G2])
        check("after set_param + undo/redo/undo: still -20 between the stages",
              d1 is not None and d2 is not None and abs((d1 - d2) - 20.0) <= 1.0, "%s %s" % (d1, d2))

        # ---- the graph was not rebuilt by any of it --------------------------------------------------
        now = graph_rebuilds()
        if base is None:
            print("skip  no graph log given (pass the app's stderr file as the 2nd argument)")
        else:
            # Registering / withdrawing / reading must not rebuild: the count only moves with the
            # structural edits above (a bypass, an add, a remove, a set_param), never with a meter.
            before_meter = after_reads
            cmd("transport.play"); time.sleep(0.6)
            n0 = graph_rebuilds()
            for k in range(6):
                cmd("plugin.meter", host=X, plugins=[G1, G2] if k % 2 == 0 else [], owner="churn")
                cmd("plugin.level", host=X, plugin=G1)
                time.sleep(0.15)
            time.sleep(0.5)
            n1 = graph_rebuilds()
            cmd("plugin.meter", host=X, plugins=[], owner="churn")
            cmd("transport.stop")
            check("registering / withdrawing meters 6 times while playing: ZERO graph rebuilds",
                  n0 is not None and n1 == n0, "%s -> %s" % (n0, n1))

        # ---- a parallel branch ---------------------------------------------------------------------
        # [G1(0)] then a parallel block: voice 0 = [G2(-20)], voice 1 = [G3(-10)].
        br = cmd("plugin.branch", host=X, plugin=G2)
        idle()
        block = br["block"]
        if block is None:
            print("skip  branch: no block id returned")
        else:
            G3 = cmd("plugin.add_gain_stage", host=X, face="gain", gain_db=-10.0,
                     series={"voice": {"block": block, "index": 1}})["plugin"]["id"]
            idle()
            cmd("plugin.meter", host=X, plugins=[G1, G2, G3])
            s = sample(X, [G1, G2, G3], dur=1.6)
            d1, d2, d3 = top_db(s[G1]), top_db(s[G2]), top_db(s[G3])
            check("branch: voice 0 (-20) and voice 1 (-10) each meter their own output",
                  None not in (d1, d2, d3) and abs((d1 - d2) - 20.0) <= 1.0 and abs((d1 - d3) - 10.0) <= 1.0,
                  "%s %s %s" % (d1, d2, d3))
            cmd("edit.undo"); cmd("edit.undo"); idle()   # back to the plain chain (the branch, the stage)
            cmd("plugin.meter", host=X, plugins=[])

        # ---- a send's mini-chain -------------------------------------------------------------------
        aux = cmd("aux.create", start=0.0, end=30.0, lane=1)["id"] if True else None
        idle()
        snd = cmd("send.create", id=X, aux=aux)
        idle()
        cmd("send.set_level", id=X, aux=aux, db=0.0)
        S1 = cmd("plugin.add_gain_stage", host=X, face="gain", gain_db=0.0, series={"send": aux})
        S2 = cmd("plugin.add_gain_stage", host=X, face="gain", gain_db=-12.0, series={"send": aux})
        idle()
        SH, SP1, SP2 = S1["host"], S1["plugin"]["id"], S2["plugin"]["id"]
        cmd("plugin.meter", host=SH, plugins=[SP1, SP2])
        s = sample(SH, [SP1, SP2], dur=1.8)
        d1, d2 = top_db(s[SP1]), top_db(s[SP2])
        check("send chain: stage 2 (-12) reads 12 dB under stage 1 (+-1)",
              d1 is not None and d2 is not None and abs((d1 - d2) - 12.0) <= 1.0, "%s %s" % (d1, d2))
        cmd("plugin.meter", host=SH, plugins=[])

        # ---- a stem, and the Main -----------------------------------------------------------------
        ST = cmd("stem.add", name="Bass")["id"]
        cmd("stem.assign", stem=ST, ids=[X])
        idle()
        T1 = cmd("plugin.add_gain_stage", host=ST, face="gain", gain_db=0.0)["plugin"]["id"]
        T2 = cmd("plugin.add_gain_stage", host=ST, face="gain", gain_db=-8.0)["plugin"]["id"]
        M1 = cmd("plugin.add_gain_stage", host=MAIN, face="gain", gain_db=0.0)["plugin"]["id"]
        M2 = cmd("plugin.add_gain_stage", host=MAIN, face="gain", gain_db=-6.0)["plugin"]["id"]
        idle()
        cmd("plugin.meter", host=ST, plugins=[T1, T2], owner="stem")
        cmd("plugin.meter", host=MAIN, plugins=[M1, M2], owner="main")
        out_st = sample(ST, [T1, T2], dur=1.8)
        d1, d2 = top_db(out_st[T1]), top_db(out_st[T2])
        check("stem synoptic: stage 2 (-8) reads 8 dB under stage 1 (+-1)",
              d1 is not None and d2 is not None and abs((d1 - d2) - 8.0) <= 1.0, "%s %s" % (d1, d2))
        # the stem's first stage sees the object's output: the object's own chain ended -20 dB under the tone
        # (G1 0, G2 -20) -> the stem's stage 1 reads about TONE-20 (+-1.5)
        check("stem stage 1 sees the object's output (TONE - 20 dB, +-1.5)",
              d1 is not None and abs(d1 - (TONE_DBFS - 20.0)) <= 1.5, "%s" % d1)
        out_mn = sample(MAIN, [M1, M2], dur=1.8)
        d1m, d2m = top_db(out_mn[M1]), top_db(out_mn[M2])
        check("Main synoptic: stage 2 (-6) reads 6 dB under stage 1 (+-1)",
              d1m is not None and d2m is not None and abs((d1m - d2m) - 6.0) <= 1.0, "%s %s" % (d1m, d2m))
        cmd("plugin.meter", host=ST, plugins=[], owner="stem")
        cmd("plugin.meter", host=MAIN, plugins=[], owner="main")

        # ---- an instrument -------------------------------------------------------------------------
        insts = cmd("plugin.list_available", instruments_only=True)["plugins"]
        pick = next((p for p in insts if p["name"] == "DLSMusicDevice"), None)
        if pick is None:
            print("skip  no instrument available for the instrument check")
        else:
            m = cmd("midi.create_clip", start=0.0, end=20.0, lane=3)["id"]
            idle()
            ins = cmd("instrument.set", id=m, identifier=pick["identifier"], format=pick["format"])
            iid = ins["instrument"]["id"]
            for n in range(0, 16):
                cmd("midi.add_note", id=m, pitch=60, start_beat=n * 1.0, length_beats=0.9, velocity=100)
            idle()
            cmd("plugin.meter", host=m, plugins=[iid])
            s = sample(m, [iid], dur=2.6, skip=0.3)
            check("the MIDI object's instrument meters its output (%s)" % pick["name"],
                  top_db(s[iid]) is not None, str(s[iid][:8]))
            cmd("plugin.meter", host=m, plugins=[])

        # ---- an export run leaves the meters alone -------------------------------------------------
        # The tone of Z starts at 20 s, so playing from 2 s reads silence on Z's stage. An export of
        # 20..23 s renders Z's tone through the SAME plugin instance (the live Edit): if the render fed
        # the live measurer, its peak would wait there and the very first read of a play from 2 s would
        # show it. (A stopped read empties the peak: nothing may be read between the export and the play.)
        Z = cmd("object.add", path=TONE, lane=6, start=20.0)["id"]
        idle()
        GZ = cmd("plugin.add_gain_stage", host=Z, face="gain", gain_db=0.0)["plugin"]["id"]
        idle()
        cmd("plugin.meter", host=Z, plugins=[GZ], owner="zed")
        s = sample(Z, [GZ], dur=1.4, skip=0.4, seconds=20.0)
        check("Z: positive control, playing over its tone reads the tone",
              top_db(s[GZ]) is not None and abs(top_db(s[GZ]) - TONE_DBFS) <= 1.5, str(s[GZ][:6]))
        s = sample(Z, [GZ], dur=1.0, skip=0.0, seconds=2.0)
        check("Z: playing over silence reads 0", reads_zero(s[GZ]), str(s[GZ][:6]))
        out = os.path.join(TMP, "exp.wav")
        r = cmd("export.run", format="wav", sample_rate=SR, bit_depth=24, dithering=False,
                start=20.0, end=23.0, path=out)
        cmd("job.wait", id=r["job_id"], timeout_ms=60000)
        s = sample(Z, [GZ], dur=1.0, skip=0.0, seconds=2.0)
        check("an export of Z's tone, then a play over silence: the FIRST reads are 0 (no pollution)",
              reads_zero(s[GZ]), str(s[GZ][:6]))
        exp = B.read_wav(out)[0]
        check("(the export itself rendered the tone)", B.rms(exp, 0.2, 2.5) > 1e-4, "%.3g" % B.rms(exp, 0.2, 2.5))
        cmd("plugin.meter", host=Z, plugins=[], owner="zed")

        # ---- a project reload while registered --------------------------------------------------------
        proj = os.path.join(TMP, "proj.objekat")
        cmd("project.save_as", path=proj)
        cmd("project.open", path=proj)
        idle()
        r = refused("plugin.level", host=X, plugin=G1)
        check("after reopening, the ids are the project's: still answerable, no crash",
              r is None or r[0] == "not_found")
        cmd("project.new")
        idle()
        check("after project.new the old plugin is not_found (nothing stale is read)",
              (refused("plugin.level", host=X, plugin=G1) or ("",))[0] == "not_found")

    print()
    print("%d ok, %d ko" % (T.ok, T.ko))
    return 0 if T.ko == 0 else 1


try:
    code = main()
except ObjekatError as e:
    print("ERROR  " + str(e))
    code = 1
sys.exit(code)

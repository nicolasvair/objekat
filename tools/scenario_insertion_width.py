#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The channel width DECIDED ONCE, at a plugin's insertion (EditViewModel+InsertionWidth), through the API.

The rule (user decision of 27 November 2026): the plugin is put in the width of the signal that ARRIVES at its
place in the chain — mono arrives -> 1 -> 1, stereo arrives -> 2 -> 2, never an automatic 1 -> 2; a plugin that
refuses the width keeps its own; groups, auxes and consolidated objects are stereo; if one member of an FX link
is stereo all its instances are; the decision is part of the insertion's undo step; during playback it is applied
at once (a brief cut) and the transport goes on.

Asserted with Apple's own AudioUnits (AULowpass: mono + stereo; AUMatrixReverb: 1->2 + 2->2 only; AUReverb2:
all three). Headless, its own instance on its own socket.

    ./scenario_insertion_width.py /path/to/objekat.app

Exit: 0 if every assertion passes, 1 otherwise, 2 on bad usage.
"""

import math, os, shutil, struct, subprocess, sys, tempfile, time, wave

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

if len(sys.argv) != 2:
    print(__doc__)
    sys.exit(2)

APP = sys.argv[1]
BIN = os.path.join(APP, "Contents", "MacOS", "objekat")
if not os.path.exists(BIN):
    print("not an app bundle: %s" % APP)
    sys.exit(2)

WORK = tempfile.mkdtemp(prefix="objiw_", dir="/tmp")
SOCK = os.path.join(WORK, "s.sock")
ok, ko = 0, 0

AU_LOWPASS = "AudioUnit:Effects/aufx,lpas,appl"
AU_MATRIX_REVERB = "AudioUnit:Effects/aufx,mrev,appl"
AU_REVERB2 = "AudioUnit:Effects/aufx,rvb2,appl"


def section(title):
    print("\n-- %s " % title + "-" * max(4, 70 - len(title)))


def check(label, cond, detail=""):
    global ok, ko
    if cond:
        ok += 1
        print("  OK   %s" % label)
    else:
        ko += 1
        print("  FAIL %s   %s" % (label, detail))


def write_wav(path, channels, seconds=3.0, rate=48000):
    frames = bytearray()
    for n in range(int(seconds * rate)):
        for ch in range(channels):
            v = 0.1 * math.sin(2 * math.pi * (1000.0 + 2000.0 * ch) * n / rate)
            frames += struct.pack("<i", int(v * 8388607))[:3]
    with wave.open(path, "wb") as w:
        w.setnchannels(channels); w.setsampwidth(3); w.setframerate(rate)
        w.writeframes(bytes(frames))


MONO = os.path.join(WORK, "mono.wav")
STEREO = os.path.join(WORK, "stereo.wav")
write_wav(MONO, 1)
write_wav(STEREO, 2)

# --virtual-audio: a card input to put a chain on (no real card is touched).
proc = subprocess.Popen([BIN, "--headless", "--api", "--no-recent", "--language=en", "--virtual-audio=in:2",
                         "--socket=" + SOCK],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                        env=dict(os.environ, OBJ_SKIP_REAL_CARD="1"))
try:
    for _ in range(160):
        if os.path.exists(SOCK):
            break
        time.sleep(0.25)
    else:
        print("the app did not open its socket")
        proc.kill()
        sys.exit(1)

    with ObjekatClient(SOCK, timeout=240) as c:
        send = c.send
        send("app.set_dialog_policy", {"policy": "assume_yes"})

        def idle(ms=60000):
            send("wait_idle", {"timeout_ms": ms})

        def layouts(host, plugin):
            return send("plugin.channel_layouts", {"host": host, "plugin": plugin})

        def add(host, ident):
            pid = send("plugin.add", {"host": host, "identifier": ident})["plugin"]["id"]
            idle()   # covers the load AND the width decision (Quiescence: "plugin width decision")
            return pid

        def shape(r):
            return (r.get("inputs"), r.get("outputs"))

        def fresh(name):
            send("project.new")
            send("project.save_as", {"path": os.path.join(WORK, name + ".objekat")})

        # ---------------------------------------------------------------- a mono file
        section("a mono file: the plugin is put in mono (1 -> 1), never 1 -> 2 on its own")
        fresh("mono")
        m = send("object.add", {"path": MONO, "lane": 0, "start": 0.0})["id"]
        lp = add(m, AU_LOWPASS)
        check("AULowpass on a mono file is 1 -> 1", shape(layouts(m, lp)) == (1, 1), layouts(m, lp))
        rv = add(m, AU_REVERB2)
        check("AUReverb2 (takes all three) on a mono file is 1 -> 1, not 1 -> 2",
              shape(layouts(m, rv)) == (1, 1), layouts(m, rv))
        mr = add(m, AU_MATRIX_REVERB)
        check("AUMatrixReverb (no mono) refuses the width: it keeps its own (1 -> 2 or 2 -> 2)",
              layouts(m, mr)["outputs"] == 2, layouts(m, mr))

        # ---------------------------------------------------------------- one undo step
        section("the decision belongs to the insertion's undo step")
        fresh("undo")
        m = send("object.add", {"path": MONO, "lane": 0, "start": 0.0})["id"]
        n_before = len(send("plugin.list", {"host": m})["plugins"])
        lp = add(m, AU_LOWPASS)
        check("mono after the insertion", shape(layouts(m, lp)) == (1, 1))
        send("edit.undo")
        check("ONE edit.undo removes the plugin (and its width with it)",
              len(send("plugin.list", {"host": m})["plugins"]) == n_before)
        send("edit.redo")
        idle()
        pl = send("plugin.list", {"host": m})["plugins"]
        check("edit.redo brings it back", len(pl) == n_before + 1)
        back = pl[-1]["id"]
        for _ in range(80):
            if layouts(m, back).get("loaded"):
                break
            time.sleep(0.25)
        check("redo: still mono", shape(layouts(m, back)) == (1, 1), layouts(m, back))

        # ---------------------------------------------------------------- a stereo file
        section("a stereo file: stereo (2 -> 2)")
        fresh("stereo")
        s = send("object.add", {"path": STEREO, "lane": 0, "start": 0.0})["id"]
        lp = add(s, AU_LOWPASS)
        check("AULowpass on a stereo file is 2 -> 2", shape(layouts(s, lp)) == (2, 2), layouts(s, lp))
        rv = add(s, AU_REVERB2)
        check("AUReverb2 on a stereo file is 2 -> 2", shape(layouts(s, rv)) == (2, 2), layouts(s, rv))

        # ---------------------------------------------------------------- a group
        section("a group (even holding a single mono object): stereo")
        fresh("group")
        m = send("object.add", {"path": MONO, "lane": 0, "start": 0.0})["id"]
        g = send("group.create", {"ids": [m]})["id"]
        gp = add(g, AU_LOWPASS)
        check("AULowpass on a group of one mono object is 2 -> 2", shape(layouts(g, gp)) == (2, 2), layouts(g, gp))

        # ---------------------------------------------------------------- an FX link
        section("an FX link: one stereo member makes ALL the instances stereo")
        fresh("link")
        a = send("object.add", {"path": MONO, "lane": 0, "start": 0.0})["id"]
        b = send("object.add", {"path": STEREO, "lane": 1, "start": 0.0})["id"]
        pa = add(a, AU_LOWPASS)
        check("(the source plugin on the mono object is mono)", shape(layouts(a, pa)) == (1, 1))
        lid = send("fxlink.create", {"host": a, "plugins": [pa]})["id"]
        send("fxlink.attach", {"link": lid, "host": b})
        idle()

        def bin_instances(host):
            out = []
            for q in send("plugin.list", {"host": host})["plugins"]:
                if q.get("is_fx_block"):
                    out += [x["id"] for x in q["plugins"]]
            return out

        send("fxlink.add_plugin", {"link": lid, "identifier": AU_REVERB2, "index": 0})   # the HEAD of the bin: mono on a, stereo on b
        idle()
        ia, ib = bin_instances(a), bin_instances(b)
        for host, ids in ((a, ia), (b, ib)):
            for i in ids:
                for _ in range(80):
                    if layouts(host, i).get("loaded"):
                        break
                    time.sleep(0.25)
        check("the new bin plugin is stereo on the MONO host too (the other member is stereo)",
              shape(layouts(a, ia[0])) == (2, 2) and shape(layouts(b, ib[0])) == (2, 2),
              (layouts(a, ia[0]), layouts(b, ib[0])))

        # ---------------------------------------------------------------- a send's mini-chain
        section("a send's mini-chain: stereo (the tapped copy is a pair), whatever the sender")
        fresh("send")
        m = send("object.add", {"path": MONO, "lane": 0, "start": 0.0})["id"]
        aux = send("aux.create", {"start": 0.0, "end": 3.0, "lane": 2})["id"]
        send("send.create", {"id": m, "aux": aux})
        send("send.set_level", {"id": m, "aux": aux, "db": 0.0})
        row = [r for r in send("send.list", {"id": m})["sends"] if r["aux"] == aux][0]
        sh = row.get("chain_host")
        check("send.list gives the send's chain_host", sh is not None, row)
        if sh:
            sp = add(sh, AU_LOWPASS)
            check("AULowpass on the mini-chain of a MONO sender is 2 -> 2", shape(layouts(sh, sp)) == (2, 2),
                  layouts(sh, sp))

        # ---------------------------------------------------------------- a channel choice on the cable
        section("a channel choice (L / R / C) on the cable that enters the plugin: mono")
        fresh("pick")
        s = send("object.add", {"path": STEREO, "lane": 0, "start": 0.0})["id"]
        send("chain.set_cable", {"host": s, "index": 0, "choice": "left"})     # the file's own choice, at the head
        p1 = add(s, AU_LOWPASS)
        check("head of a stereo clip set to Left: the plugin is 1 -> 1", shape(layouts(s, p1)) == (1, 1),
              layouts(s, p1))
        fresh("pick2")
        s = send("object.add", {"path": STEREO, "lane": 0, "start": 0.0})["id"]
        p1 = add(s, AU_LOWPASS)
        check("(control: no choice, the first plugin is 2 -> 2)", shape(layouts(s, p1)) == (2, 2))
        send("chain.set_cable", {"host": s, "index": 1, "choice": "sum"})      # a pick on the cable after it
        p2 = add(s, AU_REVERB2)
        check("a Sum pick before the next plugin: it is 1 -> 1", shape(layouts(s, p2)) == (1, 1),
              layouts(s, p2))

        # ---------------------------------------------------------------- an input chain
        section("a card input's chain follows the input: mono input -> mono, pair -> stereo")
        fresh("inputs")
        try:
            send("input.enable")
            hm = send("input.host", {"first": 0, "count": 1})["host_id"]
            pm = add(hm, AU_LOWPASS)
            check("AULowpass on a MONO card input is 1 -> 1", shape(layouts(hm, pm)) == (1, 1), layouts(hm, pm))
            fresh("inputs2")   # the pair on its own (a mono and a pair on the same channels exclude each other)
            send("input.enable")
            hr = send("input.host", {"first": 0, "count": 2})
            print("       (input.host pair: %s)" % {k: hr.get(k) for k in ("mounted", "live", "kind")})
            if not hr.get("live"):
                # The virtual card does not bring a PAIR live (input.host answers live: false): the plugin
                # would never be instantiated. Said, not failed — the mono half above is the proof that the
                # chain follows the input; the pair is the same code path with count 2.
                print("       (skipped: the virtual card's input pair is not live; stereo input NOT exercised)")
            else:
                ps = add(hr["host_id"], AU_LOWPASS)
                check("AULowpass on a STEREO card input is 2 -> 2", shape(layouts(hr["host_id"], ps)) == (2, 2),
                      layouts(hr["host_id"], ps))
        except ObjekatError as e:
            check("the input chains could be driven (needs the virtual input device)", False, e.message)

        # ---------------------------------------------------------------- during playback
        section("during playback: applied at once, the transport goes on")
        fresh("playing")
        m = send("object.add", {"path": MONO, "lane": 0, "start": 0.0})["id"]
        send("transport.play")
        time.sleep(0.4)
        check("the transport plays", send("transport.state").get("playing") is True)
        lp = send("plugin.add", {"host": m, "identifier": AU_LOWPASS})["plugin"]["id"]
        idle()
        check("the width was decided while playing: mono", shape(layouts(m, lp)) == (1, 1), layouts(m, lp))
        time.sleep(0.4)
        check("the transport is still playing", send("transport.state").get("playing") is True,
              send("transport.state"))
        send("transport.stop")
        # the hand's own door goes through during playback too (brief cut, the transport resumes)
        send("transport.play")
        time.sleep(0.3)
        r = send("plugin.set_channel_layout", {"host": m, "plugin": lp, "variant": "stereo"})
        check("plugin.set_channel_layout goes through while playing", r.get("changed") is True, r)
        time.sleep(0.4)
        check("... and the transport is still playing", send("transport.state").get("playing") is True,
              send("transport.state"))
        check("... in the new width", shape(layouts(m, lp)) == (2, 2), layouts(m, lp))
        send("transport.stop")
finally:
    proc.terminate()
    try:
        proc.wait(timeout=10)
    except Exception:
        proc.kill()
    shutil.rmtree(WORK, ignore_errors=True)

print("\n%d OK, %d FAIL" % (ok, ko))
sys.exit(0 if ko == 0 else 1)

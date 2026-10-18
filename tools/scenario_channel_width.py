#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The CHANNEL WIDTH of a plugin (mono / mono -> stereo / stereo), driven through the API.

An external plugin (AU / VST3) has a MAIN bus whose width the graph reads: `plugin.channel_layouts`
reports it with the variants the instance accepts, `plugin.set_channel_layout` puts it in one of
three: `mono` (1 in, 1 out), `mono_stereo` (1 in, 2 out), `stereo` (2 in, 2 out). The width is part
of the plugin's STATE (the binary `layout` property of its tree), so it is saved with the project and
undone with the plugin. The change frees the playback context, so it is refused while the transport
plays.

What is asserted, with Apple's own AudioUnits (installed with macOS, so the scenario runs anywhere):

  * the surface: both commands are in `help`; a built-in plugin has no variants and refuses; an unknown
    plugin, a bad variant and an unsupported one are refused with their stable codes;
  * the variants: AULowpass takes mono and stereo only, AUMatrixReverb takes mono -> stereo and stereo,
    AUReverb2 all three (the table is printed, it is part of what the feature reports);
  * applying: the engine's bus follows, a second identical request changes nothing and leaves no undo
    point, ONE edit.undo takes it back and ONE edit.redo gives it again, engine side;
  * persistence: the width survives a save and a reopening of the project;
  * linked instances change together (and come back together on the undo); an FX link bin's members
    too, and a member attached afterwards is born in the new width (the definition carries it);
  * refusal while PLAYING (`invalid_state`, reason `playing`);
  * the SOUND, on a 24-bit export of a stereo file whose two sides carry two different tones (L 1 kHz,
    R 3 kHz): what becomes of each side through a stereo plugin, a mono one (1 -> 1) and a mono -> stereo
    one. This is what the card's warning tooltip says, so it is measured and not guessed;
  * no window opens on the headless instance.

It launches ITS OWN instance (`--headless --api --no-recent --language=en`) on its own socket.

    ./scenario_channel_width.py /path/to/objekat.app

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

WORK = tempfile.mkdtemp(prefix="objcw_", dir="/tmp")   # short: a UNIX socket path is capped at ~103 bytes
SOCK = os.path.join(WORK, "s.sock")
ok, ko = 0, 0

AU_LOWPASS = "AudioUnit:Effects/aufx,lpas,appl"
AU_MATRIX_REVERB = "AudioUnit:Effects/aufx,mrev,appl"
AU_REVERB2 = "AudioUnit:Effects/aufx,rvb2,appl"
AU_DYNAMICS = "AudioUnit:Effects/aufx,dcmp,appl"
BUILTIN = "4bandEq"


def section(title):
    print("\n── %s " % title + "─" * max(4, 74 - len(title)))


def check(label, cond, detail=""):
    global ok, ko
    if cond:
        ok += 1
        print("  OK   %s" % label)
    else:
        ko += 1
        print("  FAIL %s   %s" % (label, detail))


def refused(fn, label, code, reason=None):
    try:
        fn()
        check(label, False, "it went through")
    except ObjekatError as e:
        got = (e.details or {}).get("reason") if isinstance(e.details, dict) else None
        check(label, e.code == code and (reason is None or got == reason),
              "%s / %s: %s" % (e.code, got, e.message))


def write_wav(path, seconds=2.0, rate=48000, left_hz=1000.0, right_hz=3000.0, db=-20.0, channels=2):
    """24-bit WAV; stereo: L = a sine at `left_hz`, R = a sine at `right_hz`, both at `db`."""
    amp = 10 ** (db / 20.0)
    frames = bytearray()
    for n in range(int(seconds * rate)):
        for hz in ([left_hz, right_hz][:channels]):
            frames += struct.pack("<i", int(round(amp * math.sin(2 * math.pi * hz * n / rate) * 8388607)))[:3]
    with wave.open(path, "wb") as w:
        w.setnchannels(channels)
        w.setsampwidth(3)
        w.setframerate(rate)
        w.writeframes(bytes(frames))


def read_channels(path):
    with wave.open(path, "rb") as w:
        assert w.getsampwidth() == 3 and w.getnchannels() == 2, (w.getsampwidth(), w.getnchannels())
        rate = w.getframerate()
        raw = w.readframes(w.getnframes())
    n = len(raw) // 6
    ch = ([0.0] * n, [0.0] * n)
    for i in range(n):
        for c in (0, 1):
            o = i * 6 + c * 3
            ch[c][i] = int.from_bytes(raw[o:o + 3], "little", signed=True) / 8388608.0
    return rate, ch


def tone_db(samples, rate, hz, t0=0.5, t1=1.9):
    """Level in dBFS (as a sine's peak) of the component at `hz`, Goertzel over [t0, t1] seconds."""
    a, b = int(t0 * rate), int(t1 * rate)
    seg = samples[a:b]
    n = len(seg)
    if n == 0:
        return -200.0
    w = 2 * math.pi * hz / rate
    coeff = 2 * math.cos(w)
    s1 = s2 = 0.0
    for x in seg:
        s0 = x + coeff * s1 - s2
        s2, s1 = s1, s0
    power = s1 * s1 + s2 * s2 - coeff * s1 * s2
    amp = 2 * math.sqrt(max(power, 0.0)) / n
    return 20 * math.log10(amp) if amp > 1e-10 else -200.0


def pid_for_socket(sock_path):
    try:
        out = subprocess.check_output(["lsof", "-t", sock_path], text=True, stderr=subprocess.DEVNULL)
        pids = [int(p) for p in out.split()]
        return pids[0] if pids else None
    except Exception:
        return None


def window_count_for_pid(pid):
    try:
        import Quartz
    except ImportError:
        return None
    info = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionAll, Quartz.kCGNullWindowID)
    return sum(1 for w in info if w.get("kCGWindowOwnerPID") == pid)


STEREO = os.path.join(WORK, "stereo_L1k_R3k.wav")
write_wav(STEREO)
MONO = os.path.join(WORK, "mono_1k.wav")
write_wav(MONO, channels=1)

proc = subprocess.Popen([BIN, "--headless", "--api", "--no-recent", "--language=en", "--socket=" + SOCK],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
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
        info = send("app.info")
        check("records_recent_projects is false", info.get("records_recent_projects") is False, info)

        def layouts(host, plugin):
            return send("plugin.channel_layouts", {"host": host, "plugin": plugin})

        def set_layout(host, plugin, variant):
            return send("plugin.set_channel_layout", {"host": host, "plugin": plugin, "variant": variant})

        def wait_loaded(host, plugin, timeout=40.0):
            deadline = time.time() + timeout
            r = layouts(host, plugin)
            while not r.get("loaded") and time.time() < deadline:
                time.sleep(0.25)
                r = layouts(host, plugin)
            return r

        def variants_of(r):
            return {v["id"]: v["supported"] for v in r.get("variants", [])}

        def add_plugin(host, ident):
            return send("plugin.add", {"host": host, "identifier": ident})["plugin"]["id"]

        def fresh(path=STEREO, name="p"):
            send("project.new")
            manifest = os.path.join(WORK, name + ".objekat")
            send("project.save_as", {"path": manifest})
            return manifest, send("object.add", {"path": path, "lane": 0, "start": 0.0})["id"]

        # ═══════════════════════════════════════════════════════════════ the surface
        section("the surface: both commands, and what is refused")
        helped = send("help")
        names = {cmd["name"] for cmd in helped["commands"]} if isinstance(helped, dict) and "commands" in helped \
            else set(helped if isinstance(helped, list) else [])
        check("plugin.channel_layouts is in help", "plugin.channel_layouts" in names, sorted(names)[:5])
        check("plugin.set_channel_layout is in help", "plugin.set_channel_layout" in names)

        _, obj = fresh(name="surface")
        eq = add_plugin(obj, BUILTIN)
        r = layouts(obj, eq)
        check("a built-in plugin: external false, no variants", r["external"] is False and r["variants"] == [], r)
        refused(lambda: set_layout(obj, eq, "mono"), "a built-in plugin refuses a layout", "bad_params", "not_external")

        lp = add_plugin(obj, AU_LOWPASS)
        r = wait_loaded(obj, lp)
        check("AULowpass loads", r.get("loaded") is True, r)
        refused(lambda: set_layout(obj, lp, "quadraphonic"), "an unknown variant is refused", "bad_params", "bad_variant")
        refused(lambda: set_layout(obj, "00000000-0000-0000-0000-000000000001", "mono"),
                "an unknown plugin is not_found", "not_found")
        refused(lambda: layouts("00000000-0000-0000-0000-000000000002", lp), "an unknown host is not_found", "not_found")
        refused(lambda: send("plugin.set_channel_layout", {"host": obj, "plugin": lp}),
                "a missing variant is bad_params", "bad_params")

        # ═══════════════════════════════════════════════════════════════ the variants
        section("the variants Apple's own AudioUnits accept")
        table = {}
        for label, ident in (("AULowpass", AU_LOWPASS), ("AUDynamicsProcessor", AU_DYNAMICS),
                             ("AUMatrixReverb", AU_MATRIX_REVERB), ("AUReverb2", AU_REVERB2)):
            pid_ = lp if ident == AU_LOWPASS else add_plugin(obj, ident)
            r = wait_loaded(obj, pid_)
            table[label] = (pid_, r)
            print("       %-20s %s -> %s  %s" % (label, r.get("inputs"), r.get("outputs"),
                                                  {k: ("yes" if v else "no") for k, v in variants_of(r).items()}))
        r = table["AULowpass"][1]
        check("AULowpass: stereo by default", r["current"] == "stereo" and r["inputs"] == 2 and r["outputs"] == 2, r)
        check("AULowpass: mono and stereo, not mono -> stereo",
              variants_of(r) == {"mono": True, "mono_stereo": False, "stereo": True}, variants_of(r))
        check("AULowpass: the current variant is flagged", [v["id"] for v in r["variants"] if v["current"]] == ["stereo"], r)
        r = table["AUMatrixReverb"][1]
        check("AUMatrixReverb: mono -> stereo and stereo, not mono",
              variants_of(r) == {"mono": False, "mono_stereo": True, "stereo": True}, variants_of(r))
        r = table["AUReverb2"][1]
        check("AUReverb2: all three", all(variants_of(r).values()) and len(variants_of(r)) == 3, variants_of(r))
        check("an AudioUnit's answer is exact", table["AULowpass"][1]["exact"] is True)
        check("the format is reported", table["AULowpass"][1]["format"] == "AudioUnit", table["AULowpass"][1])

        refused(lambda: set_layout(obj, lp, "mono_stereo"), "AULowpass refuses mono -> stereo", "bad_params", "unsupported")
        check("the refusal changed nothing", layouts(obj, lp)["current"] == "stereo")

        # ═══════════════════════════════════════════════════════════════ applying, undo, redo
        section("applying a variant, undo and redo")
        _, obj = fresh(name="apply")
        lp = add_plugin(obj, AU_LOWPASS)
        wait_loaded(obj, lp)
        send("object.move", {"id": obj, "start": 0.0})    # a harmless gesture: the undo below must not eat it
        res = set_layout(obj, lp, "mono")
        check("set mono: changed, 1 instance, answers the bus",
              res["changed"] is True and res["instances"] == 1 and res["inputs"] == 1 and res["outputs"] == 1, res)
        r = layouts(obj, lp)
        check("the engine now reports 1 -> 1, current mono", r["inputs"] == 1 and r["outputs"] == 1 and r["current"] == "mono", r)
        check("the variants follow (mono is now the current one)",
              [v["id"] for v in r["variants"] if v["current"]] == ["mono"], r)

        again = set_layout(obj, lp, "mono")
        check("the same request again: changed false, 0 instances", again["changed"] is False and again["instances"] == 0, again)
        send("edit.undo")
        r = layouts(obj, lp)
        check("ONE undo after set + no-op set: back to stereo (the no-op left no undo point)",
              r["current"] == "stereo" and r["inputs"] == 2, r)
        send("edit.redo")
        r = layouts(obj, lp)
        check("redo: mono again, engine side", r["current"] == "mono" and r["inputs"] == 1, r)
        send("edit.undo")
        send("edit.undo")
        check("a second undo goes to the gesture BEFORE (the object stays)", send("object.get", {"id": obj})["id"] == obj)
        send("edit.redo"); send("edit.redo")
        check("two redos: mono once more", layouts(obj, lp)["current"] == "mono")

        # ═══════════════════════════════════════════════════════════════ persistence
        section("persistence: the width is saved with the project")
        # NB: the earlier sections left STEREO AULowpass instances in the engine's parking (a project
        # replaced parks its plugins ~20 s): reopening must not take one of those for this MONO one —
        # the chunk is the same, only the `layout` property differs (@see takeParkedPluginMatching:).
        manifest = os.path.join(WORK, "apply.objekat")
        send("project.save_as", {"path": manifest})
        state = send("plugin.get_state", {"plugin": lp, "include_chunk": False})
        check("the live state is readable after the change", state["size"] > 0, state)
        send("project.new")
        send("project.open", {"path": manifest})
        send("wait_idle", {"timeout_ms": 60000})
        objs = send("object.list")["objects"] if "objects" in send("object.list") else send("object.list")
        oid = [o for o in objs if o.get("kind", "clip") in ("clip", "audio")][0]["id"]
        plist = send("plugin.list", {"host": oid})["plugins"]
        lp2 = plist[0]["id"]
        r = wait_loaded(oid, lp2)
        check("reopened: the plugin is back", r.get("loaded") is True, r)
        check("reopened: still mono (1 -> 1)", r.get("current") == "mono" and r.get("inputs") == 1, r)

        # ═══════════════════════════════════════════════════════════════ an FX link changes together
        section("linked instances change together")
        _, a = fresh(name="link")
        b = send("object.add", {"path": STEREO, "lane": 1, "start": 0.0})["id"]
        pa = add_plugin(a, AU_LOWPASS)
        wait_loaded(a, pa)
        placed = send("plugin.link", {"from": a, "plugin": pa, "to": b})
        pb = placed["plugins"][0]
        wait_loaded(b, pb)
        ra = layouts(a, pa)
        check("the menu data says one other instance changes with it", ra["linked"] == 1, ra)
        res = set_layout(a, pa, "mono")
        check("both instances changed", res["changed"] is True and res["instances"] == 2, res)
        check("the mirror is mono too", layouts(b, pb)["current"] == "mono", layouts(b, pb))
        send("edit.undo")
        check("ONE undo takes both back",
              layouts(a, pa)["current"] == "stereo" and layouts(b, pb)["current"] == "stereo",
              (layouts(a, pa)["current"], layouts(b, pb)["current"]))
        send("edit.redo")
        check("redo gives both again", layouts(a, pa)["current"] == "mono" and layouts(b, pb)["current"] == "mono")

        # ═══════════════════════════════════════════════════════════════ an FX link bin
        section("an FX link bin: its mirrors AND its definition change together")
        _, a = fresh(name="bin")
        b = send("object.add", {"path": STEREO, "lane": 1, "start": 0.0})["id"]
        c3 = send("object.add", {"path": STEREO, "lane": 2, "start": 0.0})["id"]
        pa = add_plugin(a, AU_LOWPASS)
        wait_loaded(a, pa)
        lid = send("fxlink.create", {"host": a, "plugins": [pa]})["id"]
        send("fxlink.attach", {"link": lid, "host": b})
        send("wait_idle", {"timeout_ms": 30000})

        def bin_instance(host):
            for q in send("plugin.list", {"host": host})["plugins"]:
                if q.get("is_fx_block"):
                    return q["plugins"][0]["id"]
            return None

        ia, ib = bin_instance(a), bin_instance(b)
        wait_loaded(b, ib)
        check("the bin's menu data says one other instance changes with it", layouts(a, ia)["linked"] == 1)
        res = set_layout(a, ia, "mono")
        check("both members changed", res["instances"] == 2, res)
        check("the other member is mono", layouts(b, ib)["current"] == "mono")
        send("fxlink.attach", {"link": lid, "host": c3})
        send("wait_idle", {"timeout_ms": 30000})
        ic = bin_instance(c3)
        r = wait_loaded(c3, ic)
        check("a member attached AFTER the change is born mono (the definition carries the width)",
              r.get("current") == "mono", r)
        send("edit.undo")   # the attach
        send("edit.undo")   # the width
        check("undo: both members stereo again",
              layouts(a, ia)["current"] == "stereo" and layouts(b, ib)["current"] == "stereo")

        # ═══════════════════════════════════════════════════════════════ refused while playing
        section("refused while the transport plays")
        _, obj = fresh(name="playing")
        lp = add_plugin(obj, AU_LOWPASS)
        wait_loaded(obj, lp)
        send("transport.play")
        time.sleep(0.4)
        playing = send("transport.state").get("playing")
        check("the transport plays", playing is True, send("transport.state"))
        check("channel_layouts says so", layouts(obj, lp)["playing"] is True)
        refused(lambda: set_layout(obj, lp, "mono"), "a change while playing is invalid_state / playing",
                "invalid_state", "playing")
        send("transport.stop")
        time.sleep(0.2)
        check("nothing changed", layouts(obj, lp)["current"] == "stereo")
        check("once stopped it goes through", set_layout(obj, lp, "mono")["changed"] is True)

        # ═══════════════════════════════════════════════════════════════ what the sound does
        section("the SOUND: a stereo file, L = 1 kHz, R = 3 kHz, through a plugin cutting both")
        exports = {"n": 0}

        def render(tag):
            exports["n"] += 1
            path = os.path.join(WORK, "out_%02d_%s.wav" % (exports["n"], tag))
            r = send("export.run", {"format": "wav", "sample_rate": 48000, "bit_depth": 24,
                                    "dithering": False, "start": 0.0, "end": 2.0, "path": path})
            send("job.wait", {"id": r["job_id"], "timeout_ms": 120000})
            rate, ch = read_channels(path)
            return {(side, hz): tone_db(ch[i], rate, hz)
                    for i, side in enumerate("LR") for hz in (1000.0, 3000.0)}

        def fmt(m):
            return "L1k %6.1f  L3k %6.1f  R1k %6.1f  R3k %6.1f" % (m["L", 1000.0], m["L", 3000.0], m["R", 1000.0], m["R", 3000.0])

        def set_param_named(host, plugin, needle, to_max):
            ps = send("plugin.get_params", {"plugin": plugin})["params"]
            for i, p in enumerate(ps):
                if needle in p["name"].lower():
                    send("plugin.set_param", {"plugin": plugin, "index": i, "value": p["max"] if to_max else p["min"]})
                    return True
            return False

        _, obj = fresh(name="sound")
        ref = render("dry")
        print("       dry:                 " + fmt(ref))
        check("the dry file: L carries 1 kHz and R 3 kHz at -20 dBFS",
              abs(ref["L", 1000.0] + 20) < 0.3 and abs(ref["R", 3000.0] + 20) < 0.3
              and ref["L", 3000.0] < -90 and ref["R", 1000.0] < -90, fmt(ref))

        lp = add_plugin(obj, AU_LOWPASS)
        wait_loaded(obj, lp)
        # a cutoff at the bottom of its range: whatever the plugin PROCESSES comes out far under the dry level.
        cut_ok = set_param_named(obj, lp, "cutoff", to_max=False)
        check("AULowpass: its cutoff parameter is found and lowered", cut_ok)
        st = render("lowpass_stereo")
        print("       stereo (2 -> 2):     " + fmt(st))
        check("stereo plugin: BOTH sides are processed (1 kHz and 3 kHz gone)",
              st["L", 1000.0] < ref["L", 1000.0] - 30 and st["R", 3000.0] < ref["R", 3000.0] - 30, fmt(st))

        set_layout(obj, lp, "mono")
        mo = render("lowpass_mono")
        print("       mono (1 -> 1):       " + fmt(mo))
        left_processed = mo["L", 1000.0] < ref["L", 1000.0] - 30
        right_dry = abs(mo["R", 3000.0] - ref["R", 3000.0]) < 1.0
        check("mono plugin on a stereo file: the LEFT side is processed", left_processed, fmt(mo))
        check("mono plugin on a stereo file: the RIGHT side goes through UNPROCESSED", right_dry, fmt(mo))
        MONO_STEREO_RIGHT_DRY = right_dry

        # a plugin that takes ONE channel in and gives TWO out: which of the two input sides does it read?
        rv = add_plugin(obj, AU_REVERB2)
        wait_loaded(obj, rv)
        send("plugin.toggle", {"host": obj, "plugin": lp})   # bypass the lowpass
        wet_ok = set_param_named(obj, rv, "dry/wet", to_max=True) or set_param_named(obj, rv, "mix", to_max=True)
        check("AUReverb2: its dry/wet is found and set to wet", wet_ok)
        set_layout(obj, rv, "stereo")
        rs = render("reverb_stereo")
        print("       reverb stereo:       " + fmt(rs))
        set_layout(obj, rv, "mono_stereo")
        r12 = render("reverb_mono_stereo")
        print("       reverb 1 -> 2:       " + fmt(r12))
        check("1 -> 2 plugin on a stereo file: the right side's own tone (3 kHz) never reaches the output",
              r12["R", 3000.0] < -60 and r12["L", 3000.0] < -60, fmt(r12))
        check("1 -> 2 plugin on a stereo file: the left side's tone (1 kHz) is what is processed",
              r12["L", 1000.0] > -60 or r12["R", 1000.0] > -60, fmt(r12))

        # ═══════════════════════════════════════════════════════════════ no window
        section("no window on the headless instance")
        pid = pid_for_socket(SOCK)
        n = window_count_for_pid(pid) if pid else None
        check("no window opened on the headless pid", n in (0, None), n)
finally:
    proc.terminate()
    try:
        proc.wait(timeout=10)
    except Exception:
        proc.kill()
    shutil.rmtree(WORK, ignore_errors=True)

print("\n%d OK, %d FAILED" % (ok, ko))
sys.exit(0 if ko == 0 else 1)

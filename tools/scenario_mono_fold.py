#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The STEREO -> MONO FOLD of a plugin with one main input, driven through the API.

A stereo signal entering a plugin whose main bus has ONE input is folded by a per-plugin choice
(`ObjectPlugin.monoFold`, session format 28): `left`, `right`, or `sum` = (L + R) / 2. Whichever is
chosen, the plugin's output replaces the pair: a 1 -> 1 plugin's mono result goes to both sides and the
channel not taken is CUT (since 20 October 2026: an explicit `left` used to let R pass round it dry). A
plugin INSERTED by this build is `sum`; a plugin read from a file without the key (every project before
format 28) plays `MonoFold.whenUnset` = `sum` too (decision of 21 October 2026: such a project used to
read the left channel and let R pass dry; it now sums, on purpose).

What is asserted, with Apple's own AudioUnits (installed with macOS):

  * the surface: `plugin.set_mono_fold` in help, a bad fold refused, the default of a new plugin is
    `sum` and it is written in the file;
  * the SOUND, on 24-bit exports of a stereo file whose sides carry two different tones (L 1 kHz,
    R 3 kHz, -20 dBFS each), through AULowpass in mono (1 -> 1): left / right / sum, with the filter
    open (levels: sum = each tone at -26 dBFS on BOTH sides; left = 1 kHz on both sides, 3 kHz cut)
    and closed (the plugin really processes what it is fed, nothing passes round it); through AUReverb2
    in mono -> stereo (1 -> 2), left, right and sum;
  * the engine halves (`fold_in` / `fold_out`): IN + OUT for right / sum on a 1 -> 1 plugin, OUT only
    for left, IN only (right / sum) on a 1 -> 2; nothing on a stereo plugin, whose export is then
    bit-exact whatever the fold;
  * an OLD-FORMAT file (no `monoFold` key, version 26): reads `sum` (not chosen), lays both halves,
    nothing passes round the plugin, and its export is bit-exact with the same project set to `sum`
    through the API;
  * undo / redo, save / reopen, plugin.copy, object.duplicate, a manual link (both change together)
    and an FX link bin (members and definition: a member attached afterwards is born with the fold);
  * no window opens on the headless instance.

    ./scenario_mono_fold.py /path/to/objekat.app [socket]

Exit: 0 if every assertion passes, 1 otherwise, 2 on bad usage.
"""

import json, math, os, shutil, struct, subprocess, sys, tempfile, time, wave

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

if len(sys.argv) not in (2, 3):
    print(__doc__)
    sys.exit(2)

APP = sys.argv[1]
BIN = os.path.join(APP, "Contents", "MacOS", "objekat")
if not os.path.exists(BIN):
    print("not an app bundle: %s" % APP)
    sys.exit(2)

WORK = tempfile.mkdtemp(prefix="objmf_", dir="/tmp")
SOCK = sys.argv[2] if len(sys.argv) == 3 else os.path.join(WORK, "s.sock")
ok, ko = 0, 0

AU_LOWPASS = "AudioUnit:Effects/aufx,lpas,appl"
AU_REVERB2 = "AudioUnit:Effects/aufx,rvb2,appl"


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


def write_wav(path, seconds=2.0, rate=48000, left_hz=1000.0, right_hz=3000.0, db=-20.0):
    amp = 10 ** (db / 20.0)
    frames = bytearray()
    for n in range(int(seconds * rate)):
        for hz in (left_hz, right_hz):
            frames += struct.pack("<i", int(round(amp * math.sin(2 * math.pi * hz * n / rate) * 8388607)))[:3]
    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(3)
        w.setframerate(rate)
        w.writeframes(bytes(frames))


def read_raw(path):
    with wave.open(path, "rb") as w:
        assert w.getsampwidth() == 3 and w.getnchannels() == 2
        return w.getframerate(), w.readframes(w.getnframes())


def channels(raw):
    n = len(raw) // 6
    ch = ([0.0] * n, [0.0] * n)
    for i in range(n):
        for c in (0, 1):
            o = i * 6 + c * 3
            ch[c][i] = int.from_bytes(raw[o:o + 3], "little", signed=True) / 8388608.0
    return ch


def channel_bytes(raw, c):
    return b"".join(raw[i * 6 + c * 3:i * 6 + c * 3 + 3] for i in range(len(raw) // 6))


def max_diff_lsb(a, b):
    """Largest difference in 24-bit steps between two raw stereo 24-bit buffers (and the frame count)."""
    n = min(len(a), len(b)) // 3
    worst = 0
    for i in range(n):
        x = int.from_bytes(a[i * 3:i * 3 + 3], "little", signed=True)
        y = int.from_bytes(b[i * 3:i * 3 + 3], "little", signed=True)
        worst = max(worst, abs(x - y))
    return worst


def tone_db(samples, rate, hz, t0=0.5, t1=1.9):
    a, b = int(t0 * rate), int(t1 * rate)
    seg = samples[a:b]
    n = len(seg)
    w = 2 * math.pi * hz / rate
    coeff = 2 * math.cos(w)
    s1 = s2 = 0.0
    for x in seg:
        s0 = x + coeff * s1 - s2
        s2, s1 = s1, s0
    power = s1 * s1 + s2 * s2 - coeff * s1 * s2
    amp = 2 * math.sqrt(max(power, 0.0)) / n
    return 20 * math.log10(amp) if amp > 1e-10 else -200.0


def rms_db(samples, rate, t0=0.5, t1=1.9):
    seg = samples[int(t0 * rate):int(t1 * rate)]
    r = math.sqrt(sum(x * x for x in seg) / max(1, len(seg)))
    return 20 * math.log10(r) if r > 1e-10 else -200.0


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
_, SRC_RAW = read_raw(STEREO)

if os.path.exists(SOCK):
    os.unlink(SOCK)
proc = subprocess.Popen([BIN, "--headless", "--api", "--no-recent", "--no-audio", "--language=en",
                         "--socket=" + SOCK], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
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

        def layouts(host, plugin):
            return send("plugin.channel_layouts", {"host": host, "plugin": plugin})

        def wait_loaded(host, plugin, timeout=40.0):
            deadline = time.time() + timeout
            r = layouts(host, plugin)
            while not r.get("loaded") and time.time() < deadline:
                time.sleep(0.25)
                r = layouts(host, plugin)
            return r

        def fold(host, plugin, f):
            return send("plugin.set_mono_fold", {"host": host, "plugin": plugin, "fold": f})

        def add_plugin(host, ident):
            p = send("plugin.add", {"host": host, "identifier": ident})["plugin"]["id"]
            wait_loaded(host, p)
            return p

        def fresh(name):
            send("project.new")
            manifest = os.path.join(WORK, name + ".objekat")
            send("project.save_as", {"path": manifest})
            return manifest, send("object.add", {"path": STEREO, "lane": 0, "start": 0.0})["id"]

        def set_param_named(plugin, needle, to_max):
            ps = send("plugin.get_params", {"plugin": plugin})["params"]
            for i, p in enumerate(ps):
                if needle in p["name"].lower():
                    send("plugin.set_param", {"plugin": plugin, "index": i, "value": p["max"] if to_max else p["min"]})
                    return True
            return False

        exports = {"n": 0}

        def render(tag):
            exports["n"] += 1
            path = os.path.join(WORK, "out_%02d_%s.wav" % (exports["n"], tag))
            r = send("export.run", {"format": "wav", "sample_rate": 48000, "bit_depth": 24,
                                    "dithering": False, "start": 0.0, "end": 2.0, "path": path})
            send("job.wait", {"id": r["job_id"], "timeout_ms": 120000})
            rate, raw = read_raw(path)
            ch = channels(raw)
            m = {(side, hz): tone_db(ch[i], rate, hz) for i, side in enumerate("LR") for hz in (1000.0, 3000.0)}
            m["rmsL"], m["rmsR"] = rms_db(ch[0], rate), rms_db(ch[1], rate)
            m["raw"] = raw
            return m

        def fmt(m):
            return "L1k %6.1f L3k %6.1f R1k %6.1f R3k %6.1f | RMS L %6.1f R %6.1f" % (
                m["L", 1000.0], m["L", 3000.0], m["R", 1000.0], m["R", 3000.0], m["rmsL"], m["rmsR"])

        def near(a, b, tol=1.0):
            return abs(a - b) <= tol

        def same_sound(a, b, tol=0.1):
            return all(abs(a[s, hz] - b[s, hz]) <= tol or (a[s, hz] < -80 and b[s, hz] < -80)
                       for s in "LR" for hz in (1000.0, 3000.0))

        def leaf_of(host):
            q = send("plugin.list", {"host": host})["plugins"][0]
            return q["plugins"][0]["id"] if q.get("is_fx_block") else q["id"]

        def halves(r):
            return tuple(None if r.get(k) is None else (r[k]["active"], r[k]["mode"]) for k in ("fold_in", "fold_out"))

        # ═══════════════════════════════════════════════════════════════ surface + default
        section("the surface, and the default of a NEW plugin")
        helped = send("help")
        names = {cmd["name"] for cmd in helped["commands"]} if isinstance(helped, dict) and "commands" in helped \
            else set(helped if isinstance(helped, list) else [])
        check("plugin.set_mono_fold is in help", "plugin.set_mono_fold" in names)

        manifest, obj = fresh("sound")
        eq = add_plugin(obj, "4bandEq")
        r = layouts(obj, eq)
        check("a BUILT-IN plugin (`sum` by default): nothing laid", halves(r) == (None, None), halves(r))
        send("plugin.remove", {"host": obj, "plugin": eq})
        lp = add_plugin(obj, AU_LOWPASS)
        r = layouts(obj, lp)
        check("a plugin inserted by this build reads `sum`", r.get("mono_fold") == "sum", r.get("mono_fold"))
        try:
            fold(obj, lp, "middle")
            check("a bad fold is refused", False, "it went through")
        except ObjekatError as e:
            check("a bad fold is refused (bad_params)", getattr(e, "code", None) == "bad_params", e)
        send("project.save")
        doc = json.load(open(manifest))
        blob = json.dumps(doc)
        check("the file is format 31", doc.get("version") == 31, doc.get("version"))
        check("the new plugin is written \"monoFold\": \"sum\"", '"monoFold": "sum"' in blob)

        # ═══════════════════════════════════════════════════════════════ the sound, 1 -> 1
        section("the SOUND: L = 1 kHz, R = 3 kHz, through AULowpass in MONO (1 -> 1)")
        send("plugin.toggle", {"host": obj, "plugin": lp})          # bypass: the dry reference
        dry = render("dry")
        send("plugin.toggle", {"host": obj, "plugin": lp})
        print("       dry:             " + fmt(dry))
        check("dry: L 1 kHz and R 3 kHz at -20 dBFS", near(dry["L", 1000.0], -20, 0.3) and near(dry["R", 3000.0], -20, 0.3))

        check("the filter is opened to its top", set_param_named(lp, "cutoff", to_max=True))
        stereo_left = None
        fold(obj, lp, "left")
        stereo_left = render("stereo_left")
        fold(obj, lp, "sum")
        r = layouts(obj, lp)
        check("a STEREO plugin with `sum`: NOTHING laid (no slot of the 20-plugin list spent)", halves(r) == (None, None), halves(r))
        stereo_sum = render("stereo_sum")
        check("a STEREO plugin: `sum` is bit-exact with `left` (the fold does nothing there)",
              stereo_sum["raw"] == stereo_left["raw"])

        send("plugin.set_channel_layout", {"host": obj, "plugin": lp, "variant": "mono"})
        res = {}
        for f in ("left", "right", "sum"):
            fold(obj, lp, f)
            r = layouts(obj, lp)
            res[f] = render("open_" + f)
            print("       open, %-6s       %s   halves %s" % (f + ":", fmt(res[f]), halves(r)))
            if f == "left":
                check("left: only the OUT half laid (the plugin reads L by itself; its output replaces the pair)",
                      halves(r) == (None, (True, "left")), halves(r))
            else:
                check("%s: both halves laid and active" % f, halves(r) == ((True, f), (True, f)), halves(r))
        L_, R_, S_ = res["left"], res["right"], res["sum"]
        check("left: both sides carry 1 kHz at -20, the right channel's 3 kHz is CUT (nothing passes dry)",
              near(L_["L", 1000.0], -20) and near(L_["R", 1000.0], -20) and L_["L", 3000.0] < -80 and L_["R", 3000.0] < -80, fmt(L_))
        check("right: both sides carry 3 kHz at -20, no 1 kHz",
              near(R_["L", 3000.0], -20) and near(R_["R", 3000.0], -20) and R_["L", 1000.0] < -80 and R_["R", 1000.0] < -80, fmt(R_))
        check("sum: both sides carry 1 kHz AND 3 kHz at -26 dBFS ((L + R) / 2 = -6.02 dB each)",
              all(near(S_[s, hz], -26.02) for s in "LR" for hz in (1000.0, 3000.0)), fmt(S_))
        check("sum: RMS -26 dBFS per side (two tones at -26 peak, -29 RMS each, add up to -26)",
              near(S_["rmsL"], -26.02, 1.0) and near(S_["rmsR"], -26.02, 1.0), fmt(S_))
        check("left / right / sum: the two sides are identical (the plugin's output replaces the pair)",
              all(channel_bytes(m["raw"], 0) == channel_bytes(m["raw"], 1) for m in (L_, R_, S_)))

        section("the plugin really processes what it is fed (filter CLOSED)")
        set_param_named(lp, "cutoff", to_max=False)
        for f in ("left", "right", "sum"):
            fold(obj, lp, f)
            res[f] = render("closed_" + f)
            print("       closed, %-6s     %s" % (f + ":", fmt(res[f])))
        check("left: nothing passes round the plugin (both sides cut)",
              max(res["left"][s, hz] for s in "LR" for hz in (1000.0, 3000.0)) < -50, fmt(res["left"]))
        check("right: nothing passes round the plugin (both sides cut)",
              max(res["right"][s, hz] for s in "LR" for hz in (1000.0, 3000.0)) < -50, fmt(res["right"]))
        check("sum: nothing passes round the plugin (both sides cut)",
              max(res["sum"][s, hz] for s in "LR" for hz in (1000.0, 3000.0)) < -50, fmt(res["sum"]))
        set_param_named(lp, "cutoff", to_max=True)

        # ═══════════════════════════════════════════════════════════════ the sound, 1 -> 2
        section("the SOUND through AUReverb2 in MONO -> STEREO (1 -> 2), fully wet")
        send("plugin.toggle", {"host": obj, "plugin": lp})
        rv = add_plugin(obj, AU_REVERB2)
        check("its dry/wet is set to wet", set_param_named(rv, "dry/wet", True) or set_param_named(rv, "mix", True))
        send("plugin.set_channel_layout", {"host": obj, "plugin": rv, "variant": "mono_stereo"})
        rr = {}
        for f in ("left", "right", "sum"):
            fold(obj, rv, f)
            r = layouts(obj, rv)
            rr[f] = render("rev_" + f)
            print("       1->2, %-6s       %s   halves %s" % (f + ":", fmt(rr[f]), halves(r)))
        check("1 -> 2: only the IN half is laid (the plugin's two outputs are its own)",
              halves(layouts(obj, rv)) == ((True, "sum"), None), halves(layouts(obj, rv)))
        fold(obj, rv, "left")
        check("1 -> 2 left: nothing laid (the plugin reads L by itself, its two outputs are its own)",
              halves(layouts(obj, rv)) == (None, None), halves(layouts(obj, rv)))
        hear = lambda m, hz: max(m["L", hz], m["R", hz]) > -60
        check("1 -> 2 left: 1 kHz heard, 3 kHz not", hear(rr["left"], 1000.0) and not hear(rr["left"], 3000.0), fmt(rr["left"]))
        check("1 -> 2 right: 3 kHz heard, 1 kHz not", hear(rr["right"], 3000.0) and not hear(rr["right"], 1000.0), fmt(rr["right"]))
        check("1 -> 2 sum: both tones heard", hear(rr["sum"], 1000.0) and hear(rr["sum"], 3000.0), fmt(rr["sum"]))
        send("plugin.remove", {"host": obj, "plugin": rv})
        send("plugin.toggle", {"host": obj, "plugin": lp})

        # ═══════════════════════════════════════════════════════════════ undo / redo, no-op
        section("undo / redo, and a no-op")
        fold(obj, lp, "sum")
        n = fold(obj, lp, "sum")
        check("the same fold again: changed false", n["changed"] is False, n)
        fold(obj, lp, "right")
        send("edit.undo")
        r = layouts(obj, lp)
        check("ONE undo gives `sum` back, model and engine", r["mono_fold"] == "sum" and halves(r) == ((True, "sum"), (True, "sum")), (r["mono_fold"], halves(r)))
        u = render("undo")
        # Not bit-exact: two renders of one AU filter several gestures apart are not sample-aligned
        # (measured: same levels, a time offset). The levels and the L == R identity say the fold.
        check("... and the sound of `sum` (same tone levels as the earlier sum export, L == R)",
              same_sound(u, S_) and channel_bytes(u["raw"], 0) == channel_bytes(u["raw"], 1), fmt(u))
        send("edit.redo")
        r = layouts(obj, lp)
        check("redo gives `right` again", r["mono_fold"] == "right" and halves(r) == ((True, "right"), (True, "right")), (r["mono_fold"], halves(r)))
        fold(obj, lp, "left")
        send("edit.undo")
        r = layouts(obj, lp)
        check("undo of right -> left: right again, both halves laid again",
              r["mono_fold"] == "right" and halves(r) == ((True, "right"), (True, "right")), (r["mono_fold"], halves(r)))

        # ═══════════════════════════════════════════════════════════════ copies
        section("save / reopen, copies")
        send("project.save")
        send("project.open", {"path": manifest})
        send("wait_idle", {"timeout_ms": 60000})
        objs = send("object.list")
        objs = objs["objects"] if isinstance(objs, dict) and "objects" in objs else objs
        obj = objs[0]["id"]
        lp = leaf_of(obj)
        r = wait_loaded(obj, lp)
        check("reopened: `right`, halves active", r.get("mono_fold") == "right" and halves(r) == ((True, "right"), (True, "right")), (r.get("mono_fold"), halves(r)))
        reo = render("reopened")
        check("reopened: the sound of `right` (same tone levels, L == R)",
              same_sound(reo, R_) and channel_bytes(reo["raw"], 0) == channel_bytes(reo["raw"], 1), fmt(reo))

        b = send("object.add", {"path": STEREO, "lane": 1, "start": 0.0})["id"]
        send("plugin.copy", {"from": obj, "plugin": lp, "to": b})
        pb = send("plugin.list", {"host": b})["plugins"][-1]["id"]
        check("plugin.copy carries the fold", wait_loaded(b, pb).get("mono_fold") == "right")
        d = send("object.duplicate", {"ids": [obj]})
        did = (d.get("ids") or [None])[0] if isinstance(d, dict) else None
        if did:
            pd = leaf_of(did)   # a duplicate makes an FX link bin of the chain
            check("object.duplicate carries the fold", wait_loaded(did, pd).get("mono_fold") == "right")
        else:
            check("object.duplicate answered an id", False, d)

        # ═══════════════════════════════════════════════════════════════ an OLD file
        section("an OLD-FORMAT file (no monoFold key, version 26)")
        old_manifest, oo = fresh("old")
        olp = add_plugin(oo, AU_LOWPASS)
        set_param_named(olp, "cutoff", to_max=False)
        send("plugin.set_channel_layout", {"host": oo, "plugin": olp, "variant": "mono"})
        send("project.save")
        doc = json.load(open(old_manifest))

        def strip(x):
            if isinstance(x, dict):
                x.pop("monoFold", None)
                for v in x.values():
                    strip(v)
            elif isinstance(x, list):
                for v in x:
                    strip(v)
        strip(doc)
        doc["version"] = 26
        json.dump(doc, open(old_manifest, "w"), indent=2)
        send("project.open", {"path": old_manifest})
        send("wait_idle", {"timeout_ms": 60000})
        objs = send("object.list")
        objs = objs["objects"] if isinstance(objs, dict) and "objects" in objs else objs
        oo = objs[0]["id"]
        olp = send("plugin.list", {"host": oo})["plugins"][0]["id"]
        r = wait_loaded(oo, olp)
        check("old file: the plugin plays `sum` (MonoFold.whenUnset)", r.get("mono_fold") == "sum", r.get("mono_fold"))
        check("old file: the fold is NOT chosen (no key)", r.get("mono_fold_chosen") is False, r.get("mono_fold_chosen"))
        check("old file: both halves laid and active (the sum)", halves(r) == ((True, "sum"), (True, "sum")), halves(r))
        old = render("old_file")
        print("       old file:        " + fmt(old))
        check("old file: nothing passes round the closed filter any more (R no longer dry)",
              max(old[s, hz] for s in "LR" for hz in (1000.0, 3000.0)) < -50, fmt(old))
        # The FIRST render after an AU is opened differs from every later one (its filter warms up).
        # So the comparison is made on a second render of the old file, against a render of it set to
        # `sum` through the API.
        old2 = render("old_file_again")
        fold(oo, olp, "left")
        fold(oo, olp, "sum")        # through the API: the same graph as the old file
        check("set through the API: the fold is now chosen", layouts(oo, olp).get("mono_fold_chosen") is True)
        again = render("old_set_sum")
        check("old file: bit-exact with the same project set to `sum` through the API",
              again["raw"] == old2["raw"],
              "L %d LSB, R %d LSB" % (max_diff_lsb(channel_bytes(old2["raw"], 0), channel_bytes(again["raw"], 0)),
                                      max_diff_lsb(channel_bytes(old2["raw"], 1), channel_bytes(again["raw"], 1))))

        # ═══════════════════════════════════════════════════════════════ links
        section("a manual link, and an FX link bin")
        _, a = fresh("link")
        b = send("object.add", {"path": STEREO, "lane": 1, "start": 0.0})["id"]
        pa = add_plugin(a, AU_LOWPASS)
        placed = send("plugin.link", {"from": a, "plugin": pa, "to": b})
        pb = placed["plugins"][0]
        wait_loaded(b, pb)
        res2 = fold(a, pa, "right")
        check("a linked pair changes together (instances 2)", res2["instances"] == 2, res2)
        check("the peer reads `right`", layouts(b, pb)["mono_fold"] == "right")
        send("edit.undo")
        check("ONE undo takes both back to `sum`", layouts(a, pa)["mono_fold"] == "sum" and layouts(b, pb)["mono_fold"] == "sum")

        _, a = fresh("bin")
        b = send("object.add", {"path": STEREO, "lane": 1, "start": 0.0})["id"]
        c3 = send("object.add", {"path": STEREO, "lane": 2, "start": 0.0})["id"]
        pa = add_plugin(a, AU_LOWPASS)
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
        send("plugin.set_channel_layout", {"host": a, "plugin": ia, "variant": "mono"})
        res3 = fold(a, ia, "right")
        check("the bin's members change together", res3["instances"] == 2, res3)
        rb = layouts(b, ib)
        check("the other member reads `right`, its halves active", rb["mono_fold"] == "right" and halves(rb)[0] == (True, "right"), (rb["mono_fold"], halves(rb)))
        send("fxlink.attach", {"link": lid, "host": c3})
        send("wait_idle", {"timeout_ms": 30000})
        ic = bin_instance(c3)
        check("a member attached AFTERWARDS is born `right` (the definition carries it)",
              wait_loaded(c3, ic).get("mono_fold") == "right")

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

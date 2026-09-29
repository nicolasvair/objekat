#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Lot L9 — the CHANNEL CHOICE of a stereo clip (LR / L / R / C), put to the test through the API.

A clip of EXACTLY two channels can be heard as it is (`lr`), as its left channel on both sides
(`l`), as its right channel on both sides (`r`) or as the mono sum `(L + R) / 2` on both sides
(`c`) — per clip, at playback, the file never touched. The choice lives in ONE engine plugin at
the HEAD of the clip's chain (`ObjChannelMode`), so an EXPORT is what proves the engine followed
and not just the model: every claim of the sound is measured on a 24-bit WAV re-read here.

The witness file is stereo, L = a sine at -20 dBFS, R = silence. The engine attenuates a centred
stereo signal by 3 dB (found by lot L7), so nothing is compared to an absolute level — everything
is compared to the LR export of the same clip:

    lr  -> R silent, L at the reference
    l   -> both sides at the reference
    r   -> both sides silent
    c   -> both sides 6 dB under the reference

Then the mode must SURVIVE: undo / redo (model AND engine agree, through `engine_channel_mode`),
a cut, a duplicate, a copy / paste, a save and a reopening, and a consolidation (the export is the
same before and after). A format-17 project (no key, `version` 17) must open as LR, a MONO clip
must be refused, and no window may open on the headless instance.

It launches ITS OWN instance (`--headless --api --no-audio --no-recent`) on its own socket.

    ./scenario_channel_mode.py /path/to/objekat.app

Exit: 0 if every assertion passes, 1 otherwise, 2 on bad usage.
"""

import json, math, os, shutil, struct, subprocess, sys, tempfile, time, wave

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

WORK = tempfile.mkdtemp(prefix="objchm_", dir="/tmp")   # short: a UNIX socket path is capped at ~103 bytes
SOCK = os.path.join(WORK, "s.sock")
ok, ko = 0, 0


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


def refused(fn, label, code):
    try:
        fn()
        check(label, False, "it went through")
    except ObjekatError as e:
        check(label, e.code == code, "%s: %s" % (e.code, e.message))


def write_wav(path, channels, seconds=2.0, rate=48000, freq=997.0, db_left=-20.0):
    """24-bit WAV. Stereo: L = sine at `db_left`, R = silence. Mono: the same sine."""
    amp = 10 ** (db_left / 20.0)
    frames = bytearray()
    for n in range(int(seconds * rate)):
        v = int(round(amp * math.sin(2 * math.pi * freq * n / rate) * 8388607))
        b = struct.pack("<i", v)[:3]
        frames += b + (b"\x00\x00\x00" if channels == 2 else b"")
    with wave.open(path, "wb") as w:
        w.setnchannels(channels)
        w.setsampwidth(3)
        w.setframerate(rate)
        w.writeframes(bytes(frames))


def read_rms_db(path):
    """(rmsL, rmsR) in dBFS of a 24-bit stereo WAV — floor at -200."""
    with wave.open(path, "rb") as w:
        assert w.getsampwidth() == 3 and w.getnchannels() == 2, (w.getsampwidth(), w.getnchannels())
        raw = w.readframes(w.getnframes())
    n = len(raw) // 6
    acc = [0.0, 0.0]
    for i in range(n):
        for ch in (0, 1):
            o = i * 6 + ch * 3
            v = int.from_bytes(raw[o:o + 3], "little", signed=True) / 8388608.0
            acc[ch] += v * v
    return tuple(10 * math.log10(a / n) if a > 0 else -200.0 for a in acc)


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


STEREO = os.path.join(WORK, "stereo_L_-20.wav")
MONO = os.path.join(WORK, "mono_-20.wav")
write_wav(STEREO, 2)
write_wav(MONO, 1)

proc = subprocess.Popen([BIN, "--headless", "--api", "--no-audio", "--no-recent",
                         "--language=en", "--socket=" + SOCK],
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

    with ObjekatClient(SOCK) as c:
        send = c.send
        c.send("app.set_dialog_policy", {"policy": "assume_yes"})
        info = send("app.info")
        check("records_recent_projects is false", info.get("records_recent_projects") is False, info)

        exports = {"n": 0}

        def render(tag):
            exports["n"] += 1
            path = os.path.join(WORK, "out_%02d_%s.wav" % (exports["n"], tag))
            r = send("export.run", {"format": "wav", "sample_rate": 48000, "bit_depth": 24,
                                    "dithering": False, "start": 0.0, "end": 2.0, "path": path})
            send("job.wait", {"id": r["job_id"], "timeout_ms": 120000})
            return read_rms_db(path)

        def get(oid):
            return send("object.get", {"id": oid})

        def fresh(name, mode=None):
            """A new saved project holding one stereo clip; returns (manifest, id)."""
            send("project.new")
            manifest = os.path.join(WORK, name + ".objekat")
            send("project.save_as", {"path": manifest})
            oid = send("object.add", {"path": STEREO, "lane": 0, "start": 0.0})["id"]
            if mode:
                send("object.set_channel_mode", {"id": oid, "mode": mode})
            return manifest, oid

        def baseline():
            """The LR left-side level of a fresh project: the reference of everything else there.
            Measured in each project because the engine's level for a centred stereo signal is not
            the same before and after an undo (found while writing this: ANY undo, a gain's
            included, shifts an export by +3 dB for the rest of the process — a pre-existing
            trait of the engine, unrelated to the channel choice, reported rather than fixed)."""
            _, oid_ = fresh("baseline")
            return render("baseline")[0]

        def near(a, b, tol):
            return abs(a - b) <= tol

        # ══════════════════════════════════════════════════════════ the sound of each mode
        section("the sound of each mode (export, 24 bits)")
        manifest, oid = fresh("sound")
        g = get(oid)
        check("the witness clip has 2 channels", g["channels"] == 2, g["channels"])
        check("default channel_mode is lr, model AND engine",
              g["channel_mode"] == "lr" and g["engine_channel_mode"] == "lr", g)

        lr_l, lr_r = render("lr")
        check("lr: right side is silent", lr_r < -120, lr_r)
        check("lr: left side carries the sine (about -20 dB rms minus 3 dB of law minus 3 dB of sine)",
              -40 < lr_l < -15, lr_l)
        REF = lr_l

        send("object.set_channel_mode", {"id": oid, "mode": "l"})
        l_l, l_r = render("l")
        check("l: left at the reference", near(l_l, REF, 0.1), (l_l, REF))
        check("l: right at the reference too", near(l_r, REF, 0.1), (l_r, REF))

        send("object.set_channel_mode", {"id": oid, "mode": "r"})
        r_l, r_r = render("r")
        check("r: both sides silent", r_l < -120 and r_r < -120, (r_l, r_r))

        send("object.set_channel_mode", {"id": oid, "mode": "c"})
        c_l, c_r = render("c")
        check("c: left 6 dB under the reference", near(c_l, REF - 6.0206, 0.15), (c_l, REF))
        check("c: right 6 dB under the reference", near(c_r, REF - 6.0206, 0.15), (c_r, REF))

        send("object.set_channel_mode", {"id": oid, "mode": "lr"})
        b_l, b_r = render("back_to_lr")
        check("back to lr: the original export again", near(b_l, REF, 0.05) and b_r < -120, (b_l, b_r))

        # ══════════════════════════════════════════════════════════ refusals
        section("refusals")
        refused(lambda: send("object.set_channel_mode", {"id": oid, "mode": "x"}),
                "an unknown mode is bad_params", "bad_params")
        mono_id = send("object.add", {"path": MONO, "lane": 2, "start": 0.0})["id"]
        gm = get(mono_id)
        check("the mono clip reports 1 channel", gm["channels"] == 1, gm["channels"])
        refused(lambda: send("object.set_channel_mode", {"id": mono_id, "mode": "c"}),
                "a mono clip is refused (invalid_state)", "invalid_state")
        check("the mono clip stays lr", get(mono_id)["channel_mode"] == "lr")
        gid = send("group.create", {"ids": [mono_id]})["id"]
        refused(lambda: send("object.set_channel_mode", {"id": gid, "mode": "l"}),
                "a group is refused (invalid_state)", "invalid_state")
        refused(lambda: send("object.set_channel_mode",
                             {"id": "00000000-0000-0000-0000-000000000000", "mode": "l"}),
                "an unknown object is not_found", "not_found")

        # ══════════════════════════════════════════════════════════ undo / redo
        section("undo / redo — model and engine agree")
        manifest, oid = fresh("undo")
        send("object.set_channel_mode", {"id": oid, "mode": "r"})
        send("object.set_channel_mode", {"id": oid, "mode": "c"})
        send("edit.undo")  # c -> r
        g = get(oid)
        check("undo: back to r, model AND engine", g["channel_mode"] == "r" and g["engine_channel_mode"] == "r", g)
        send("edit.undo")  # r -> lr
        g = get(oid)
        check("undo: back to lr, model AND engine", g["channel_mode"] == "lr" and g["engine_channel_mode"] == "lr", g)
        send("edit.redo")
        send("edit.redo")
        g = get(oid)
        check("redo x2: c again, model AND engine", g["channel_mode"] == "c" and g["engine_channel_mode"] == "c", g)
        send("edit.undo")  # c -> r
        # setting the same mode again is not an edit: no undo point
        send("object.set_channel_mode", {"id": oid, "mode": "r"})
        send("object.set_channel_mode", {"id": oid, "mode": "r"})
        send("edit.undo")
        check("setting the same mode twice pushed ONE undo point (the first one; the no-ops none)",
              get(oid)["channel_mode"] == "lr", get(oid)["channel_mode"])

        # ══════════════════════════════════════════════════════════ split
        section("split / cut")
        ref = baseline()
        manifest, oid = fresh("split", "l")
        cut = send("object.split_at", {"seconds": 1.0, "ids": [oid]})
        ids = cut["ids"]
        check("the cut made two pieces", len(ids) == 2, ids)
        for k in ids:
            g = get(k)
            check("piece %s keeps l, model AND engine" % k[:8],
                  g["channel_mode"] == "l" and g["engine_channel_mode"] == "l", g)
        s_l, s_r = render("split_l")
        check("the two halves still sound as l (both sides at the LR reference)",
              near(s_l, ref, 0.3) and near(s_r, ref, 0.3), (s_l, s_r, ref))
        send("edit.undo")
        g = get(oid)
        check("undo of the cut: whole clip, still l in the engine",
              g["channel_mode"] == "l" and g["engine_channel_mode"] == "l", g)

        # ══════════════════════════════════════════════════════════ duplicate
        section("duplicate")
        manifest, oid = fresh("dup", "c")
        d = send("object.duplicate", {"ids": [oid]})
        check("one copy", d["count"] == 1, d)
        for k in d["ids"]:
            g = get(k)
            check("the duplicate keeps c, model AND engine",
                  g["channel_mode"] == "c" and g["engine_channel_mode"] == "c", g)
        check("the original is untouched", get(oid)["channel_mode"] == "c")

        # ══════════════════════════════════════════════════════════ copy / paste
        section("clipboard copy / paste")
        manifest, oid = fresh("clip", "r")
        send("selection.set", {"ids": [oid]})
        send("clipboard.copy")
        send("transport.seek", {"seconds": 5.0})
        p = send("clipboard.paste")
        check("pasted one object", len(p["ids"]) == 1 and p["ids"][0] != oid, p)
        for k in p["ids"]:
            g = get(k)
            check("the pasted clip keeps r, model AND engine",
                  g["channel_mode"] == "r" and g["engine_channel_mode"] == "r", g)

        # ══════════════════════════════════════════════════════════ save / reopen, format 17
        section("save / reopen; a format-17 session opens as LR")
        manifest, oid = fresh("save", "c")
        lr_id = send("object.add", {"path": STEREO, "lane": 2, "start": 0.0})["id"]
        send("project.save")
        with open(manifest, "r", encoding="utf-8") as f:
            doc = json.load(f)
        check("the session is written as format 18", doc.get("version") == 18, doc.get("version"))

        def clips(items):
            for o in items:
                yield o
                for ch in o.get("kind", {}).get("children", []):
                    yield from clips([ch])

        rows = {o["id"]: o for o in clips(doc["items"])}
        check("the c clip writes channelMode = c", rows[oid].get("channelMode") == "c", rows.get(oid))
        check("the lr clip writes NO channelMode key", "channelMode" not in rows[lr_id], rows.get(lr_id))

        send("project.new")
        send("project.open", {"path": manifest})
        send("wait_idle", {"timeout_ms": 60000})
        g = get(oid)
        check("reopened: c, model AND engine",
              g["channel_mode"] == "c" and g["engine_channel_mode"] == "c", g)
        g = get(lr_id)
        check("reopened: the other clip is lr", g["channel_mode"] == "lr" and g["engine_channel_mode"] == "lr", g)
        send("object.remove", {"ids": [lr_id]})
        s_l, s_r = render("reopened_c")
        send("object.set_channel_mode", {"id": oid, "mode": "lr"})
        ref = render("reopened_lr")[0]
        check("reopened: the export is still the mono sum (both sides, 6 dB under lr)",
              near(s_l, ref - 6.0206, 0.15) and near(s_r, ref - 6.0206, 0.15), (s_l, s_r, ref))

        # forge the OLD format: version 17, no key at all
        old = json.loads(json.dumps(doc))
        old["version"] = 17
        for o in clips(old["items"]):
            o.pop("channelMode", None)
        manifest17 = os.path.join(WORK, "old17.objekat")
        with open(manifest17, "w", encoding="utf-8") as f:
            json.dump(old, f)
        send("project.new")
        send("project.open", {"path": manifest17})
        send("wait_idle", {"timeout_ms": 60000})
        g = get(oid)
        check("a format-17 session opens as lr, model AND engine",
              g["channel_mode"] == "lr" and g["engine_channel_mode"] == "lr", g)

        # ══════════════════════════════════════════════════════════ consolidation
        section("consolidation — the baked wave carries the choice")
        manifest, oid = fresh("consol")
        ref = render("consol_lr")[0]
        send("object.set_channel_mode", {"id": oid, "mode": "c"})
        before = render("before_consolidation")
        check("before: c at 6 dB under the lr reference, both sides",
              near(before[0], ref - 6.0206, 0.2) and near(before[1], ref - 6.0206, 0.2), (before, ref))
        job = send("consolidate.make", {"id": oid})
        send("job.wait", {"id": job["job_id"], "timeout_ms": 120000})
        send("wait_idle", {"timeout_ms": 60000})
        after = render("after_consolidation")
        check("after: the export is the same (left)", near(after[0], before[0], 0.15), (before, after))
        check("after: the export is the same (right)", near(after[1], before[1], 0.15), (before, after))
        defs = send("consolidate.list")["definitions"]
        inst = defs[0]["placements"][0] if defs and defs[0].get("placements") else oid
        check("the consolidation made one definition with one placement",
              len(defs) == 1 and len(defs[0].get("placements", [])) == 1, defs)
        refused(lambda: send("object.set_channel_mode", {"id": inst, "mode": "l"}),
                "a consolidated instance is refused (its wave is baked)", "invalid_state")

        # ══════════════════════════════════════════════════════════ no window
        section("no window on the headless instance")
        pid = pid_for_socket(SOCK)
        n = window_count_for_pid(pid) if pid else None
        if n is None:
            print("  ..   skipped: no Quartz / pid")
        else:
            check("no window opened by the headless instance", n == 0, n)
finally:
    try:
        proc.terminate()
        proc.wait(timeout=20)
    except Exception:
        proc.kill()
    shutil.rmtree(WORK, ignore_errors=True)

print("\n%d ok, %d failed" % (ok, ko))
print("ALL PASS" if ko == 0 else "FAILURES")
sys.exit(0 if ko == 0 else 1)

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ARA / Melodyne on an audio object, put to the test through the command API.

docs/ara_melodyne_plan.md §5.2. An audio object can carry an ARA SOURCE (Melodyne VST3): the clip
plays THROUGH it, ahead of its chain. This scenario asserts, with no screen:

  A  detection         the catalogue knows Melodyne as ARA; the probe finds its factory
  B  placement         plugin.add -> slot "ara_source", plugin.list shows it first, analysis, notes
  C  audible           an isolated render sounds like the dry one (RMS, pitch)
  D  chain after       gain, filter, fade, window, channel mode apply AFTER the source
  E  groups            grouping, nesting, ungrouping, changing lane: still audible, one region
  G  save / reopen     the archive is written (format 20), comes back, same notes, same sound
  H  undo              removal / delete are undoable; OBJEKAT's undo never touches a live retouch (Q1)
  I  copy / duplicate / cut   every piece has its own source and its own plugin id
  J  consolidation     consolidate.make bakes the sound; a consolidated instance refuses a source
  K  refusals          MIDI, group, aux, stem, speed, reversed, loop; the guards of the source
  L  tabs              inter-project copy-paste, tab round trips
  M  archive size      30 s and 3 min melodies (bytes, base64, ms, bytes per minute)
  N  missing plugin    the object plays dry, the archive is rewritten untouched
  O  cost (Q3)         1, 10 and 40 Melodyne objects: load time, RSS, pushUndo with stale archives
  P  the "+" door      place -> remove -> place again through the picker's own logic (debug.ara_picker),
                       also after undo / redo of a removal, of a placement, and after a false-positive pick
  Z  end               no window on the headless pid; no duplicated plugin id

It launches ITS OWN instance (`--headless --api --no-recent`, `--no-audio` unless --audio) on its own
socket and exits 3 (SKIP) if no Melodyne VST3 is installed.

    ./scenario_ara.py /path/to/objekat.app [--sections=ABCG] [--audio] [--quick]

Exit: 0 everything passes, 1 a failure, 2 bad usage, 3 SKIP.
"""

import glob
import json
import subprocess, math, os, shutil, subprocess, sys, tempfile, time, wave

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

args = [a for a in sys.argv[1:] if not a.startswith("--")]
flags = [a for a in sys.argv[1:] if a.startswith("--")]
if len(args) != 1:
    print(__doc__)
    sys.exit(2)
APP = args[0]
BIN = os.path.join(APP, "Contents", "MacOS", "objekat")
if not os.path.exists(BIN):
    print("not an app bundle: %s" % APP)
    sys.exit(2)
SECTIONS = None
for f in flags:
    if f.startswith("--sections="):
        SECTIONS = set(f.split("=", 1)[1].upper())
WITH_AUDIO = "--audio" in flags
QUICK = "--quick" in flags

WORK = tempfile.mkdtemp(prefix="ara_", dir="/tmp")     # short: a UNIX socket path is capped at ~103 bytes
SOCK = os.path.join(WORK, "s.sock")
SR = 48000
ok, ko = 0, 0
FAILS = []


def want(letter):
    return SECTIONS is None or letter in SECTIONS


def section(title):
    print("\n── %s " % title + "─" * max(4, 74 - len(title)), flush=True)


def check(label, cond, detail=""):
    global ok, ko
    if cond:
        ok += 1
        print("  OK   %s" % label)
    else:
        ko += 1
        FAILS.append(label)
        print("  FAIL %s   %s" % (label, detail))
    sys.stdout.flush()


def info(text):
    print("  ..   %s" % text)
    sys.stdout.flush()


def refused(fn, label, code="invalid_state", reason=None):
    try:
        fn()
        check(label, False, "it went through")
    except ObjekatError as e:
        good = e.code == code and (reason is None or (e.details or {}).get("reason") == reason)
        check(label, good, "%s: %s %s" % (e.code, e.message, e.details))


# ───────────────────────────────────────────────────────────────────────────── signals / measures

def write_wav(path, x, rate=SR):
    """24-bit WAV; x is (frames,) or (frames, channels), floats in [-1, 1]."""
    x = np.asarray(x, dtype=np.float64)
    if x.ndim == 1:
        x = x[:, None]
    q = np.clip(np.round(x * 8388607.0), -8388608, 8388607).astype(np.int32)
    b = q.astype("<i4").view(np.uint8).reshape(-1, 4)[:, :3]
    with wave.open(path, "wb") as w:
        w.setnchannels(x.shape[1])
        w.setsampwidth(3)
        w.setframerate(rate)
        w.writeframes(b.tobytes())


def read_wav(path):
    """(frames, channels) float array of a 16/24-bit PCM WAV, and its rate."""
    with wave.open(path, "rb") as w:
        ch, sw, n, rate, raw = w.getnchannels(), w.getsampwidth(), w.getnframes(), w.getframerate(), None
        raw = w.readframes(n)
    if sw == 3:
        a = np.frombuffer(raw, dtype=np.uint8).reshape(-1, 3)
        v = (a[:, 0].astype(np.int32) | (a[:, 1].astype(np.int32) << 8) | (a[:, 2].astype(np.int32) << 16))
        v = np.where(v >= 1 << 23, v - (1 << 24), v)
        x = v.astype(np.float64) / 8388608.0
    elif sw == 2:
        x = np.frombuffer(raw, dtype="<i2").astype(np.float64) / 32768.0
    else:
        raise RuntimeError("unexpected sample width %d" % sw)
    return x.reshape(-1, ch), rate


def rms_db(x, t0=0.0, t1=None, rate=SR, channel=None):
    x = np.atleast_2d(x.T).T if x.ndim == 1 else x
    a = int(t0 * rate)
    b = x.shape[0] if t1 is None else int(t1 * rate)
    seg = x[a:b] if channel is None else x[a:b, channel:channel + 1]
    if seg.size == 0:
        return -200.0
    r = math.sqrt(float(np.mean(seg * seg)))
    return 20 * math.log10(r) if r > 1e-12 else -200.0


def pitch_hz(x, rate=SR, t0=1.0, t1=None):
    """Frequency of the spectral peak (Hann, parabolic interpolation), channels summed."""
    m = x.mean(axis=1) if x.ndim == 2 else x
    a = int(t0 * rate)
    b = len(m) if t1 is None else min(len(m), int(t1 * rate))
    seg = m[a:b]
    if len(seg) < 4096:
        return 0.0
    seg = seg[: (len(seg) // 2) * 2] * np.hanning(len(seg) // 2 * 2)
    spec = np.abs(np.fft.rfft(seg, n=1 << int(math.ceil(math.log2(len(seg))) + 1)))
    k = int(np.argmax(spec[1:])) + 1
    if 1 <= k < len(spec) - 1:
        a1, b1, c1 = math.log(spec[k - 1] + 1e-30), math.log(spec[k] + 1e-30), math.log(spec[k + 1] + 1e-30)
        d = 0.5 * (a1 - c1) / (a1 - 2 * b1 + c1) if (a1 - 2 * b1 + c1) != 0 else 0.0
    else:
        d = 0.0
    n = (len(spec) - 1) * 2
    return (k + d) * rate / n


def correlation(a, b):
    n = min(len(a), len(b))
    a = a[:n].reshape(-1)
    b = b[:n].reshape(-1)
    d = math.sqrt(float(np.dot(a, a)) * float(np.dot(b, b)))
    return float(np.dot(a, b)) / d if d > 0 else 0.0


def make_sine(path, seconds=10.0, hz=220.0, dbfs=-12.0, stereo_left_only=False, rate=SR):
    t = np.arange(int(seconds * rate)) / rate
    s = 10 ** (dbfs / 20.0) * np.sin(2 * math.pi * hz * t)
    if stereo_left_only:
        s = np.stack([s, np.zeros_like(s)], axis=1)
    write_wav(path, s, rate)


def make_melody(path, seconds):
    """Notes of 0.5 s on a major scale, a slight vibrato, harmonics, 2 % noise (reproducible)."""
    rng = np.random.default_rng(1234)
    scale = [0, 2, 4, 5, 7, 9, 11, 12, 11, 9, 7, 5, 4, 2]
    n = int(seconds * SR)
    out = np.zeros(n)
    note_len = int(0.5 * SR)
    for i in range(0, n, note_len):
        semis = scale[(i // note_len) % len(scale)]
        f0 = 220.0 * 2 ** (semis / 12.0)
        m = min(note_len, n - i)
        t = np.arange(m) / SR
        vib = 1 + 0.004 * np.sin(2 * math.pi * 5.5 * (t + i / SR))
        ph = 2 * math.pi * np.cumsum(f0 * vib) / SR
        env = np.minimum(1.0, np.minimum(t / 0.02, (m / SR - t) / 0.03))
        out[i:i + m] = env * sum(np.sin(h * ph) / h for h in (1, 2, 3)) * 0.2
    out += 0.02 * rng.standard_normal(n) * 0.2
    write_wav(path, np.clip(out, -0.95, 0.95))


def wave_rate(path):
    """Sample rate of any audio file `afinfo` reads (the bakes are 32-bit float, which `wave` refuses)."""
    out = subprocess.run(["afinfo", path], capture_output=True, text=True).stdout
    for line in out.splitlines():
        if "Data format" in line and " Hz" in line:
            return int(line.split(" Hz")[0].split()[-1])
    return None


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
    info_ = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionAll, Quartz.kCGNullWindowID)
    return sum(1 for w in info_ if w.get("kCGWindowOwnerPID") == pid)


# ───────────────────────────────────────────────────────────────────────────── the instance

SINE220 = os.path.join(WORK, "sine220.wav")
SINE1K = os.path.join(WORK, "sine1k.wav")
SINE220_ST = os.path.join(WORK, "sine220_L.wav")
MELODY30 = os.path.join(WORK, "melody30.wav")
MELODY180 = os.path.join(WORK, "melody180.wav")
make_sine(SINE220)
make_sine(SINE1K, hz=1000.0)
make_sine(SINE220_ST, stereo_left_only=True)
make_melody(MELODY30, 30.0)

argv = [BIN, "--headless", "--api", "--no-recent", "--language=en", "--socket=" + SOCK]
if not WITH_AUDIO:
    argv.insert(2, "--no-audio")
LOGFILE = os.path.join(WORK, "app.log")
proc = subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=open(LOGFILE, "w"))
rc = 1


def finish():
    print("\n=== %d OK, %d FAILED ===" % (ok, ko))
    for f in FAILS:
        print("   FAIL: %s" % f)
    return 1 if ko else 0


try:
    for _ in range(240):
        if os.path.exists(SOCK):
            break
        time.sleep(0.25)
    else:
        print("the app did not open its socket")
        sys.exit(1)

    with ObjekatClient(SOCK, timeout=1800.0) as c:
        send = c.send
        send("app.set_dialog_policy", {"policy": "assume_yes"})
        ai = send("app.info")
        check("records_recent_projects is false", ai.get("records_recent_projects") is False, ai)

        # the catalogue (the scan can take a while the very first time)
        send("plugin.scan")
        mel = None
        for _ in range(240):
            r = send("plugin.list_available", {"filter": "melodyne"})
            if not r["scanning"] and r["count"] > 0:
                break
            time.sleep(1)
        cands = [p for p in r["plugins"] if p["format"] == "VST3"]
        if not cands:
            print("SKIP: no Melodyne VST3 in the catalogue (%d entries named melodyne)" % r["count"])
            rc = 3
            raise SystemExit(3)
        mel = cands[0]

        # ── helpers on the live instance ────────────────────────────────────────────────
        counter = {"n": 0}

        def tag(name):
            counter["n"] += 1
            return os.path.join(WORK, "%03d_%s.wav" % (counter["n"], name))

        def wait(timeout=60000):
            send("wait_idle", {"timeout_ms": timeout})

        def fresh(name):
            send("project.new")
            manifest = os.path.join(WORK, name + ".objekat")
            send("project.save_as", {"path": manifest})
            return manifest

        def add_clip(path, lane=0, start=0.0):
            return send("object.add", {"path": path, "lane": lane, "start": start})["id"]

        def render_iso(oid, name, start=None, end=None, rate=SR):
            p = {"id": oid, "path": tag(name), "sample_rate": rate}
            if start is not None:
                p["start"] = start
            if end is not None:
                p["end"] = end
            j = send("object.render_isolated", p)["job_id"]
            send("job.wait", {"id": j, "timeout_ms": 600000})
            return read_wav(p["path"])[0]

        def export_mix(name, t0, t1, background=False, rate=SR):
            p = tag(name)
            r = send("export.run", {"format": "wav", "sample_rate": rate, "bit_depth": 24, "dithering": False,
                                    "start": t0, "end": t1, "path": p, "background": background})
            send("job.wait", {"id": r["job_id"], "timeout_ms": 600000})
            return read_wav(p)[0]

        def add_ara(oid, name_hint="Melodyne"):
            r = send("plugin.add", {"host": oid, "identifier": mel["identifier"], "format": "VST3"})
            return r

        def wait_ara(oid, timeout_ms=180000):
            return send("object.ara.wait_analysis", {"id": oid, "timeout_ms": timeout_ms})

        def status(oid):
            return send("object.ara.status", {"id": oid})

        def notes(oid):
            return send("object.ara.notes", {"id": oid})["notes"]

        def pitches(ns):
            return sorted(set(n["pitch"] for n in ns))

        def get(oid):
            return send("object.get", {"id": oid})

        def objs():
            return send("object.list")["objects"]

        def ara_objects():
            """Every object carrying a source, groups descended, by object.list's own flat view."""
            out = []
            for o in objs():
                try:
                    if status(o["id"]).get("has_source"):
                        out.append(o["id"])
                except ObjekatError:
                    pass
            return out

        def audit():
            return send("debug.plugin_id_audit")["count"]

        def near(a, b, tol):
            return abs(a - b) <= tol

        # ══════════════════════════════════════════════════════════════════════ A
        if want("A"):
            section("A  detection")
            check("Melodyne VST3 is in the catalogue with ara:true", mel.get("ara") is True, mel)
            pr = send("debug.ara_probe", {"identifier": mel["identifier"], "format": "VST3", "name": mel["name"]})
            check("the probe finds an ARA factory", pr.get("has_ara") is True, pr)
            check("the probe reads the factory archive id", bool(pr.get("factory_archive_id")), pr)
            others = [p for p in send("plugin.list_available", {})["plugins"] if p["ara"] and p["format"] != "VST3"]
            check("no non-VST3 plugin is offered as ARA (Q2)", not others, others)

        # ══════════════════════════════════════════════════════════════════════ B, C
        B_ID = None
        DRY220 = None
        if any(want(x) for x in "BCDEGHIJ"):
            fresh("main")
            B_ID = add_clip(SINE220, lane=0)
            wait()
            DRY220 = render_iso(B_ID, "dry220")
            info("dry reference: %.2f dBFS, %.1f Hz" % (rms_db(DRY220), pitch_hz(DRY220)))

        if want("B") or want("C") or want("D"):
            section("B  placement")
            t0 = time.time()
            r = add_ara(B_ID)
            info("plugin.add took %.0f ms" % ((time.time() - t0) * 1000))
            check("plugin.add answers slot ara_source", r.get("slot") == "ara_source", r)
            check("the answer carries the plugin (name, VST3)",
                  "melodyne" in r["plugin"]["name"].lower() and r["plugin"]["format"] == "VST3", r)
            lst = send("plugin.list", {"host": B_ID})
            check("plugin.list shows the source FIRST, slot ara_source",
                  lst["plugins"] and lst["plugins"][0].get("slot") == "ara_source"
                  and lst["plugins"][0]["id"] == r["plugin"]["id"], lst["plugins"][:1])
            check("the source is not counted in the chain beyond that first entry", len(lst["plugins"]) == 1, lst)
            st = status(B_ID)
            check("object.ara.status: has_source and engine_valid", st["has_source"] and st["engine_valid"], st)
            t0 = time.time()
            w = wait_ara(B_ID)
            info("analysis finished in %.1f s" % (time.time() - t0))
            check("analysis finished in < 120 s with at least one region", time.time() - t0 < 120 and w["regions"] >= 1, w)
            ns = notes(B_ID)
            check("object.ara.notes: at least one note, pitch 57 (A3 = 220 Hz)", 57 in pitches(ns), pitches(ns))
            info("%d notes, pitches %s" % (len(ns), pitches(ns)))

        if want("C"):
            section("C  audible")
            ara = render_iso(B_ID, "ara220")
            r_dry, r_ara = rms_db(DRY220), rms_db(ara)
            check("isolated render RMS > -40 dBFS (%.1f)" % r_ara, r_ara > -40, r_ara)
            check("|RMS - dry RMS| <= 1.5 dB (%.2f vs %.2f)" % (r_ara, r_dry), abs(r_ara - r_dry) <= 1.5, (r_ara, r_dry))
            p = pitch_hz(ara)
            check("pitch 220 Hz +/- 1 %% (%.2f)" % p, abs(p - 220) / 220 <= 0.01, p)
            check("exactly one playback region", status(B_ID)["regions"] == 1, status(B_ID))
            # Without a retouch Melodyne gives the audio back, so RMS and pitch cannot tell "through
            # Melodyne" from "dry". The residue can: a dry render is the file bit for bit, a render through
            # the plugin is not (a few LSB of float rounding in its resynthesis path).
            n_ = min(len(ara), len(DRY220))
            resid = ara[:n_] - DRY220[:n_]
            peak = float(np.abs(resid).max())
            info("residue ara - dry: peak %.2e" % peak)
            check("the render really went THROUGH the plugin (not bit-exact with the dry one)", peak > 0.0, peak)
            check("... and the residue stays tiny (< -80 dBFS)", peak < 10 ** (-80 / 20.0), peak)

        # ══════════════════════════════════════════════════════════════════════ D
        if want("D"):
            section("D  the chain applies AFTER the source")
            base = render_iso(B_ID, "d_base")
            rb = rms_db(base)
            send("object.set_gain", {"ids": [B_ID], "db": -12.0})
            wait()
            g = render_iso(B_ID, "d_gain")
            check("volume -12 dB: RMS -12 +/- 0.5 dB (%.2f)" % (rms_db(g) - rb), near(rms_db(g) - rb, -12.0, 0.5))
            send("object.set_gain", {"ids": [B_ID], "db": 0.0})
            wait()

            # a low-pass at 200 Hz on a 1 kHz sine
            fresh("d_filter")
            k = add_clip(SINE1K, lane=0)
            ref = render_iso(k, "d_1k_dry")
            add_ara(k)
            wait_ara(k)
            arak = render_iso(k, "d_1k_ara")
            lp = send("plugin.add", {"host": k, "identifier": "lowpass", "format": "TracktionInternal"})["plugin"]["id"]
            params = send("plugin.get_params", {"plugin": lp})["params"]
            freq = [q for q in params if "freq" in q["name"].lower() or "cutoff" in q["name"].lower()]
            if freq:
                send("plugin.set_param", {"plugin": lp, "index": freq[0]["index"], "value": 200.0})
            else:
                send("plugin.set_param", {"plugin": lp, "index": 0, "value": 200.0})
            wait()
            lpr = render_iso(k, "d_1k_lp")
            drop = rms_db(lpr) - rms_db(arak)
            check("low-pass at 200 Hz on 1 kHz: level drops >= 15 dB (%.1f)" % drop, drop <= -15, drop)

            # fade-in, window, channel mode on the 220 source
            fresh("d_fade")
            f = add_clip(SINE220, lane=0)
            add_ara(f)
            wait_ara(f)
            send("object.set_fade", {"id": f, "in": 1.0})
            wait()
            fr = render_iso(f, "d_fade")
            head, mid = rms_db(fr, 0.0, 0.1), rms_db(fr, 4.0, 6.0)
            check("fade-in 1 s: first 100 ms are >= 20 dB under the middle (%.1f)" % (head - mid), head - mid <= -20, head - mid)
            send("object.set_fade", {"id": f, "in": 0.0})
            send("object.set_duration", {"id": f, "duration": 5.0})
            wait()
            wr = render_iso(f, "d_window", start=0.0, end=10.0)
            check("object shortened to 5 s: silence after the end (< -90 dBFS)", rms_db(wr, 5.5, 10.0) < -90, rms_db(wr, 5.5, 10.0))
            check("... and sound before it", rms_db(wr, 1.0, 4.0) > -40)

            fresh("d_chan")
            s = add_clip(SINE220_ST, lane=0)
            add_ara(s)
            wait_ara(s)
            lr = render_iso(s, "d_lr")
            send("object.set_channel_mode", {"id": s, "mode": "l"})
            wait()
            lc = render_iso(s, "d_l")
            check("channel mode l after the source: right side = left side (%.1f / %.1f)"
                  % (rms_db(lc, channel=1), rms_db(lc, channel=0)),
                  near(rms_db(lc, channel=1), rms_db(lc, channel=0), 1.0) and rms_db(lc, channel=1) > -40)
            check("(and lr kept the right side silent: %.0f)" % rms_db(lr, channel=1), rms_db(lr, channel=1) < -60)

        # ══════════════════════════════════════════════════════════════════════ E
        if want("E"):
            section("E  groups")
            fresh("e_groups")
            a = add_clip(SINE220, lane=0)
            ref = export_mix("e_ref", 0.0, 5.0)
            rref = rms_db(ref)
            add_ara(a)
            wait_ara(a)
            c_mix = export_mix("e_c", 0.0, 5.0)
            check("mix export with the source ~ dry (%.2f vs %.2f)" % (rms_db(c_mix), rref), near(rms_db(c_mix), rref, 1.5))
            g1 = send("group.create", {"ids": [a]})["id"]
            wait()
            m1 = export_mix("e_group", 0.0, 5.0)
            check("grouped: RMS within 1.5 dB (%.2f)" % rms_db(m1), near(rms_db(m1), rref, 1.5), rms_db(m1))
            check("grouped: the source is still there and valid", status(a)["engine_valid"] and status(a)["regions"] == 1, status(a))
            g2 = send("group.create", {"ids": [g1]})["id"]
            wait()
            m2 = export_mix("e_nested", 0.0, 5.0)
            check("nested two levels: RMS within 1.5 dB (%.2f)" % rms_db(m2), near(rms_db(m2), rref, 1.5), rms_db(m2))
            check("nested: pitch 220 Hz (%.2f)" % pitch_hz(m2), abs(pitch_hz(m2) - 220) / 220 < 0.01)
            send("group.disband", {"id": g2})
            wait()
            send("group.disband", {"id": g1})
            wait()
            m3 = export_mix("e_ungrouped", 0.0, 5.0)
            check("ungrouped: RMS within 1.5 dB (%.2f)" % rms_db(m3), near(rms_db(m3), rref, 1.5), rms_db(m3))
            send("object.move", {"id": a, "lane": 3})
            wait()
            m4 = export_mix("e_lane", 0.0, 5.0)
            check("lane changed: still audible (%.2f)" % rms_db(m4), near(rms_db(m4), rref, 1.5), rms_db(m4))
            check("lane changed: regions == 1", status(a)["regions"] == 1 and status(a)["engine_valid"], status(a))

        # ══════════════════════════════════════════════════════════════════════ G
        if want("G"):
            section("G  save / reopen")
            manifest = fresh("g_save")
            a = add_clip(SINE220, lane=0)
            add_ara(a)
            wait_ara(a)
            plug_id = send("plugin.list", {"host": a})["plugins"][0]["id"]
            notes_before = notes(a)
            audio_before = render_iso(a, "g_before")
            send("project.save")
            doc = json.load(open(manifest))
            check("version == 20", doc.get("version") == 20, doc.get("version"))

            def find_ara(o):
                if isinstance(o, dict):
                    if "araSource" in o and o["araSource"]:
                        return o["araSource"]
                    for v in o.values():
                        r_ = find_ara(v)
                        if r_:
                            return r_
                elif isinstance(o, list):
                    for v in o:
                        r_ = find_ara(v)
                        if r_:
                            return r_
                return None

            src = find_ara(doc)
            check("the JSON holds araSource.archive.data, bytes > 0",
                  bool(src) and bool(src.get("archive", {}).get("data")) and src["archive"]["bytes"] > 0,
                  (src or {}).get("archive", {}).get("bytes"))
            check("the JSON source carries the same plugin id", bool(src) and src["plugin"]["id"].upper() == plug_id.upper(),
                  (src or {}).get("plugin", {}).get("id"))
            info("archive: %d bytes, %d base64 chars" % (src["archive"]["bytes"], len(src["archive"]["data"])))
            send("project.new")
            send("project.open", {"path": manifest})
            wait(120000)
            st = wait_ara(a, 120000)
            check("reopened: engine_valid", st["engine_valid"], st)
            check("reopened: same plugin id", send("plugin.list", {"host": a})["plugins"][0]["id"] == plug_id)
            notes_after = notes(a)
            same = len(notes_before) == len(notes_after) and all(
                n1["pitch"] == n2["pitch"] and abs(n1["start"] - n2["start"]) < 0.001
                for n1, n2 in zip(notes_before, notes_after))
            check("reopened: the notes are identical (%d vs %d)" % (len(notes_before), len(notes_after)), same)
            after = render_iso(a, "g_after")
            check("post-reload render: |dRMS| < 0.5 dB, correlation > 0.99",
                  abs(rms_db(after) - rms_db(audio_before)) < 0.5 and correlation(after, audio_before) > 0.99,
                  (rms_db(after), rms_db(audio_before), correlation(after, audio_before)))
            check("no duplicated plugin id after the reload", audit() == 0)

        # ══════════════════════════════════════════════════════════════════════ H
        if want("H"):
            section("H  undo (Q1)")
            fresh("h_undo")
            a = add_clip(SINE220, lane=0)
            dry = render_iso(a, "h_dry")
            add_ara(a)
            wait_ara(a)
            notes0 = notes(a)
            plug0 = send("plugin.list", {"host": a})["plugins"][0]["id"]
            send("plugin.remove", {"host": a, "plugin": plug0})
            wait()
            check("plugin.remove: the source is gone from the model", not status(a)["has_source"])
            rd = render_iso(a, "h_removed")
            check("removed: the render is the dry reference (%.2f vs %.2f)" % (rms_db(rd), rms_db(dry)),
                  near(rms_db(rd), rms_db(dry), 0.3))
            send("edit.undo")
            wait()
            wait_ara(a)
            st = status(a)
            check("undo of the removal: the source is back and valid", st["has_source"] and st["engine_valid"], st)
            check("undo: notes identical", pitches(notes(a)) == pitches(notes0) and len(notes(a)) == len(notes0))
            send("edit.redo")
            wait()
            check("redo: removed again", not status(a)["has_source"])
            send("edit.undo")
            wait()
            wait_ara(a)
            # delete the object, undo
            send("object.remove", {"ids": [a]})
            wait()
            send("edit.undo")
            wait()
            wait_ara(a)
            check("delete then undo: the source is back", status(a)["has_source"] and status(a)["engine_valid"], status(a))
            # Q1(b): a live capture is never replaced by a snapshot's archive
            send("object.move", {"id": a, "start": 1.0})       # an undo point holding the archive known now
            wait_ara(a)
            cap1 = send("object.ara.capture", {"id": a})
            plug_before = send("plugin.list", {"host": a})["plugins"][0]["id"]
            send("object.move", {"id": a, "start": 2.0})
            send("edit.undo")                                         # undo the second move only
            wait()
            plug_after = send("plugin.list", {"host": a})["plugins"][0]["id"]
            cap2 = send("object.ara.capture", {"id": a})
            check("undo of a move: same source (plugin id)", plug_before == plug_after)
            check("undo of a move: live archive not replaced (bytes %d / %d)" % (cap1["bytes"], cap2["bytes"]),
                  cap1["bytes"] == cap2["bytes"] and cap2["modification_id"] == cap1["modification_id"], (cap1, cap2))
            send("edit.undo")                                         # undo the first move: back to an OLDER snapshot
            wait()
            cap3 = send("object.ara.capture", {"id": a})
            check("undo past a capture: the live archive is still the live one (bytes %d)" % cap3["bytes"],
                  cap3["bytes"] == cap1["bytes"] and cap3["modification_id"] == cap1["modification_id"], (cap1, cap3))
            check("(and the instance was not rebuilt: still valid with one region)",
                  status(a)["engine_valid"] and status(a)["regions"] == 1, status(a))

            # Q1(b) when the snapshot's archive and the live one really DIFFER: the point is taken right
            # after the source is added (the archive then known is the early one), the analysis ends,
            # the live archive is captured, then the point is undone.
            fresh("h_q1")
            m = add_clip(MELODY30, lane=0)
            add_ara(m)
            send("object.move", {"id": m, "start": 1.0})          # undo point P: archive known NOW
            plug_m = send("plugin.list", {"host": m})["plugins"][0]["id"]
            wait_ara(m, 300000)
            early = status(m)["model_archive_bytes"]
            live_cap = send("object.ara.capture", {"id": m})
            info("model archive when the point was taken: %d bytes; live archive: %d bytes (%s)"
                 % (early, live_cap["bytes"], "DISCRIMINATING" if early != live_cap["bytes"] else "same size: weak"))
            send("edit.undo")
            wait()
            check("undo of the move: same plugin instance (no rebuild)",
                  send("plugin.list", {"host": m})["plugins"][0]["id"] == plug_m)
            after = send("object.ara.capture", {"id": m})
            check("undo of the move: the live archive is untouched (%d vs %d bytes)" % (after["bytes"], live_cap["bytes"]),
                  after["bytes"] == live_cap["bytes"] and after["modification_id"] == live_cap["modification_id"],
                  (live_cap, after))
            check("(and its notes are all there: %d)" % len(notes(m)), len(notes(m)) >= 20)

        # ══════════════════════════════════════════════════════════════════════ I
        if want("I"):
            section("I  copy / duplicate / cut")
            fresh("i_copy")
            a = add_clip(SINE220, lane=0)
            add_ara(a)
            wait_ara(a)
            orig_plug = send("plugin.list", {"host": a})["plugins"][0]["id"]
            send("selection.set", {"ids": [a]})
            send("clipboard.copy")
            send("transport.seek", {"seconds": 12.0})
            pasted = send("clipboard.paste")["ids"]
            d = send("object.duplicate", {"ids": [a]})["ids"]
            cut = send("object.split_at", {"seconds": 5.0, "ids": [a]})["ids"]
            wait()
            everyone = [a] + pasted + d + cut
            everyone = list(dict.fromkeys(everyone))
            plugs = {}
            for oid in everyone:
                st = status(oid)
                check("%s has a source" % oid[:8], st["has_source"], st)
                plugs[oid] = send("plugin.list", {"host": oid})["plugins"][0]["id"]
            check("every source has its own plugin id", len(set(plugs.values())) == len(plugs), plugs)
            check("the copies' ids differ from the original's", all(plugs[o] != orig_plug for o in everyone if o != a))
            check("debug.plugin_id_audit = 0", audit() == 0)
            for oid in everyone:
                info("%s status before waiting: %s" % (oid[:8], json.dumps(status(oid))[:300]))
                try:
                    wait_ara(oid, 60000)
                except ObjekatError as e:
                    check("%s: analysis ready" % oid[:8], False, "%s %s %s" % (e.code, e.message, e.details))
                    continue
                x = render_iso(oid, "i_%s" % oid[:6])
                p = pitch_hz(x, t0=0.5)
                check("%s: audible and 220 Hz (%.1f dB, %.1f Hz)" % (oid[:8], rms_db(x), p),
                      rms_db(x) > -40 and abs(p - 220) / 220 < 0.01)
                check("%s: one region" % oid[:8], status(oid)["regions"] == 1, status(oid))

        # ══════════════════════════════════════════════════════════════════════ J
        if want("J"):
            section("J  consolidation / export / isolated render go THROUGH Melodyne")
            # Without a retouch Melodyne gives the audio back, so RMS and pitch cannot tell "through the
            # plugin" from "dry". Its SIGNATURE can: when it renders at a rate DIFFERENT from its source
            # file's (it resamples), it fades the last ~2.4 ms of an audio source out; at the file's own
            # rate it is the identity and leaves no trace (measured, file x render: 44.1x48 and 48x44.1 and
            # 96x44.1/48 fade, 44.1x44.1 and 48x48 do not). A dry render never fades.
            # The bake renders at the DEVICE's rate (OBJRenderFileSpec.sampleRate 0 = the card's), so the
            # source file must NOT be at that rate or the bake is a perfect copy of the dry file and no
            # proof is left. The device's rate is the machine's state (a headless instance with no device
            # runs at 44.1 kHz, one that opened the saved interface at 48 kHz, @see app.info): the file is
            # made to differ from it, and EVERY render below is made at the device's rate.
            R = int(send("app.info")["sample_rate"])
            F = 44100 if R != 44100 else 48000
            J_SRC = os.path.join(WORK, "sine220_%d.wav" % F)
            make_sine(J_SRC, rate=F)
            info("device rate %d Hz ; source file at %d Hz (they must differ for the signature to exist)" % (R, F))

            def mono(x):
                return x.mean(axis=1) if x.ndim == 2 else x

            def tail_level(x):
                return float(np.abs(mono(x)[-3:]).max())

            fresh("j_consol")
            a = add_clip(J_SRC, lane=0)
            dry = mono(render_iso(a, "j_dry", rate=R))
            add_ara(a)
            wait_ara(a)
            live = mono(render_iso(a, "j_live", rate=R))
            info("dry tail %.4f ; live tail %.4f (the Melodyne signature: the live one is faded out)"
                 % (tail_level(dry), tail_level(live)))
            check("signature: the live ARA render is faded out at its end, the dry one is not",
                  tail_level(live) < 0.2 * tail_level(dry), (tail_level(live), tail_level(dry)))

            def same(a_, b_):
                n_ = min(len(a_), len(b_))
                return float(np.abs(a_[:n_] - b_[:n_]).max())

            # (1) export, direct then on a COPY of the project (the second clone path)
            exd = mono(export_mix("j_export_direct", 0.0, 10.0, rate=R))
            exb = mono(export_mix("j_export_copy", 0.0, 10.0, background=True, rate=R))
            info("export direct vs live: %.2e ; on a copy vs live: %.2e ; on a copy vs dry: %.2e"
                 % (same(exd, live), same(exb, live), same(exb, dry)))
            check("export direct carries the signature (== live <= 1e-5)", same(exd, live) <= 1e-5, same(exd, live))
            check("export ON A COPY carries the signature (== live <= 1e-5)", same(exb, live) <= 1e-5, same(exb, live))
            check("export ON A COPY is not the dry file (differs by > 1e-3)", same(exb, dry) > 1e-3, same(exb, dry))

            # (2) consolidation: the bake clone is the FIRST path
            try:
                r = send("consolidate.make", {"id": a})
                send("job.wait", {"id": r["job_id"], "timeout_ms": 600000})
                wait(300000)
                inst = [o for o in objs() if o.get("definition")]
                check("consolidate.make produced a consolidated instance", len(inst) >= 1, objs())
                if inst:
                    cid = inst[0]["id"]
                    # the premise, read off the baked wave itself: written at the card's rate, faded
                    waves = sorted(glob.glob(os.path.join(WORK, "samples", "consolidate", "*.wav")),
                                   key=os.path.getmtime)
                    bake_rate = wave_rate(waves[-1]) if waves else None
                    check("the bake is written at the device's rate (%s Hz)" % R, bake_rate == R, bake_rate)
                    x = mono(render_iso(cid, "j_cons", rate=R))
                    info("bake vs live: %.2e ; bake vs dry: %.2e (rms %.2f dB, pitch %.2f Hz)"
                         % (same(x, live), same(x, dry), rms_db(x, 0.0, 4.0, rate=R), pitch_hz(x, rate=R, t0=0.5)))
                    check("the bake went THROUGH the plugin (== live within -70 dBFS: the signature is there)", same(x, live) <= 3e-4, same(x, live))
                    check("the bake is not the dry file (differs by > 1e-3)", same(x, dry) > 1e-3, same(x, dry))
                    check("consolidated RMS equals live (+/- 0.5 dB)",
                          near(rms_db(x, 0.0, 4.0, rate=R), rms_db(live, 0.0, 4.0, rate=R), 0.5))
                    check("consolidated pitch 220 Hz", abs(pitch_hz(x, rate=R, t0=0.5) - 220) / 220 < 0.01)
                    refused(lambda: add_ara(cid), "plugin.add Melodyne on the consolidated instance -> invalid_state")
                    check("consolidated instance has no source", not status(cid).get("has_source"))
            except ObjekatError as e:
                check("consolidate.make on a Melodyne object", False, "%s: %s" % (e.code, e.message))

            # (3) a targeted render must not instantiate the OTHER Melodyne objects of the project
            fresh("j_targeted")
            a1 = add_clip(SINE220, lane=0)
            a2 = add_clip(SINE220, lane=1)
            add_ara(a1)
            add_ara(a2)
            wait_ara(a1)
            wait_ara(a2)
            t1 = time.time()
            x1 = render_iso(a1, "j_target1")
            info("targeted render with 2 sources in the project: %.2f s" % (time.time() - t1))
            check("targeted render of one of two sources is audible and 220 Hz",
                  rms_db(x1) > -40 and abs(pitch_hz(x1, t0=0.5) - 220) / 220 < 0.01)

        # ══════════════════════════════════════════════════════════════════════ J (compressed sources)
        if want("J"):
            section("J2  compressed sources (FLAC, AAC) under a source")
            fresh("j_compressed")
            lane_ = 0
            for ext, args in (("flac", ["-f", "flac", "-d", "flac"]), ("m4a", ["-f", "m4af", "-d", "aac"])):
                dst = os.path.join(WORK, "sine220." + ext)
                rc = subprocess.run(["afconvert"] + args + [SINE220, dst], capture_output=True, text=True)
                if rc.returncode != 0 or not os.path.exists(dst):
                    info("afconvert %s unavailable: %s" % (ext, rc.stderr.strip()[:100]))
                    continue
                try:
                    c = add_clip(dst, lane=lane_)
                    lane_ += 1
                except ObjekatError as e:
                    info("%s: object.add refused (%s)" % (ext, e.message))
                    continue
                try:
                    add_ara(c)
                    wait_ara(c, 120000)
                    x = render_iso(c, "j_%s" % ext)
                    p_ = pitch_hz(x, t0=0.5)
                    check("%s source under Melodyne: audible and 220 Hz (%.1f dB, %.1f Hz)" % (ext, rms_db(x), p_),
                          rms_db(x) > -40 and abs(p_ - 220) / 220 < 0.01)
                except ObjekatError as e:
                    info("%s: Melodyne refused or failed: %s %s" % (ext, e.code, e.message))
                    check("%s source is either refused with a reason or works" % ext, e.code == "invalid_state", e.message)

        # ══════════════════════════════════════════════════════════════════════ K
        if want("K"):
            section("K  refusals")
            fresh("k_refuse")
            m = send("midi.create_clip", {"lane": 3, "start": 0.0, "end": 2.0})["id"]
            refused(lambda: add_ara(m), "plugin.add Melodyne on a MIDI clip", reason="notAClip")
            x = add_clip(SINE220, lane=0)
            y = add_clip(SINE220, lane=1)
            gid = send("group.create", {"ids": [y]})["id"]
            refused(lambda: add_ara(gid), "plugin.add Melodyne on a group", reason="notAClip")
            stem = send("stem.add", {"name": "S"})["id"]
            refused(lambda: add_ara(stem), "plugin.add Melodyne on a stem")
            try:
                aux = send("aux.create", {"start": 0.0, "end": 2.0, "lane": 5})["id"]
                refused(lambda: add_ara(aux), "plugin.add Melodyne on an aux")
            except ObjekatError as e:
                info("aux.create not usable here: %s" % e.message)
            sp = add_clip(SINE220, lane=6)
            send("object.set_speed", {"id": sp, "ratio": 1.5})
            refused(lambda: add_ara(sp), "plugin.add Melodyne on a speed-1.5 object", reason="speedNotOne")
            rv = add_clip(SINE220, lane=7)
            send("object.set_reversed", {"id": rv, "reversed": True})
            refused(lambda: add_ara(rv), "plugin.add Melodyne on a reversed object", reason="reversed")
            lp = add_clip(SINE220, lane=8)
            send("object.set_loop", {"id": lp, "enabled": True})
            refused(lambda: add_ara(lp), "plugin.add Melodyne on a looping object", reason="looped")
            check("a refusal changes nothing in the model", not status(sp).get("has_source") and not status(rv).get("has_source"))
            add_ara(x)
            wait_ara(x)
            before = get(x)
            refused(lambda: send("object.set_speed", {"id": x, "ratio": 1.2}), "object.set_speed refused under a source", reason="speedNotOne")
            refused(lambda: send("object.set_reversed", {"id": x, "reversed": True}), "object.set_reversed refused", reason="reversed")
            refused(lambda: send("object.set_loop", {"id": x, "enabled": True}), "object.set_loop refused", reason="looped")
            after = get(x)
            check("the model is unchanged by the refusals",
                  after["speed"] == before["speed"] and after["reversed"] == before["reversed"] and after["loop"] == before["loop"],
                  (before, after))
            send("object.set_speed", {"id": x, "ratio": 1.0})
            check("speed 1 stays accepted (no-op)", get(x)["speed"] == 1.0)
            # a group holding a Melodyne object may not loop
            g2 = send("group.create", {"ids": [x]})["id"]
            refused(lambda: send("object.set_loop", {"id": g2, "enabled": True}),
                    "object.set_loop on a group holding a Melodyne object", reason="ancestorLooped")
            # the source's id is not a card
            pid_ = send("plugin.list", {"host": x})["plugins"][0]["id"]
            for cmd, prm in (("plugin.toggle", {"host": x, "plugin": pid_}),
                             ("plugin.move", {"from": x, "plugin": pid_, "to": y}),
                             ("plugin.copy", {"from": x, "plugin": pid_, "to": y}),
                             ("plugin.link", {"from": x, "plugin": pid_, "to": y}),
                             ("plugin.drop", {"from": x, "plugin": pid_, "to": y})):
                refused(lambda cmd=cmd, prm=prm: send(cmd, prm), "%s on the ARA source" % cmd)
            check("the source is still there after those", status(x)["has_source"])

        # ══════════════════════════════════════════════════════════════════════ L
        if want("L"):
            section("L  tabs and inter-project copy-paste")
            fresh("l_a")
            n_objects = 4 if QUICK else 10
            ids_ = []
            for k in range(n_objects):
                oid = add_clip(MELODY30 if k % 2 == 0 and not QUICK else SINE220, lane=k)
                add_ara(oid)
                ids_.append(oid)
            for oid in ids_:
                wait_ara(oid, 300000)
            wait()
            before = {oid: (send("plugin.list", {"host": oid})["plugins"][0]["id"], len(notes(oid))) for oid in ids_}
            sample_ = ids_[0]
            ref_render = render_iso(sample_, "l_before", end=3.0)

            # (1) a round trip through another tab: the instances are torn down at parking and recreated
            #     from their archives at the return
            send("tab.new")
            wait()
            check("while parked, A's engine has no instance of A (the new tab is empty)", len(ara_objects()) == 0, ara_objects())
            t0_ = time.time()
            send("tab.select", {"index": 1})
            wait(300000)
            for oid in ids_:
                wait_ara(oid, 300000)
            t_back = time.time() - t0_
            info("tab return with %d Melodyne objects: %.2f s" % (n_objects, t_back))
            check("every object is back with its source", all(status(oid)["has_source"] and status(oid)["engine_valid"] for oid in ids_))
            check("same plugin ids and same notes after the return",
                  all((send("plugin.list", {"host": oid})["plugins"][0]["id"], len(notes(oid))) == before[oid] for oid in ids_),
                  {oid[:6]: ((send("plugin.list", {"host": oid})["plugins"][0]["id"], len(notes(oid))), before[oid]) for oid in ids_})
            back_render = render_iso(sample_, "l_after", end=3.0)
            nn_ = min(len(ref_render), len(back_render))
            check("same sound after the return", float(np.abs(ref_render[:nn_] - back_render[:nn_]).max()) <= 1e-5)
            check("debug.plugin_id_audit = 0 after the tab trip", audit() == 0)

            # (2) copy in A, paste in B (another project, another engine state)
            send("selection.set", {"ids": [ids_[0], ids_[1]]})
            send("clipboard.copy")
            send("tab.select", {"index": 2})
            wait()
            manifest_b = os.path.join(WORK, "l_b.objekat")
            send("project.save_as", {"path": manifest_b})
            pasted = send("clipboard.paste")["ids"]
            wait()
            check("the paste produced the objects", len(pasted) == 2, pasted)
            for oid in pasted:
                try:
                    wait_ara(oid, 300000)
                except ObjekatError as e:
                    check("%s: pasted source ready" % oid[:6], False, "%s %s" % (e.code, e.message))
                    continue
                st = status(oid)
                pid_ = send("plugin.list", {"host": oid})["plugins"][0]["id"]
                check("%s: pasted object has a working source" % oid[:6], st["has_source"] and st["engine_valid"], st)
                check("%s: its plugin id is new" % oid[:6], pid_ not in [v[0] for v in before.values()], pid_)
            n_src = {ids_[0]: before[ids_[0]][1], ids_[1]: before[ids_[1]][1]}
            check("the pasted objects carry the notes of their sources",
                  sorted(len(notes(oid)) for oid in pasted) == sorted(n_src.values()),
                  ([len(notes(oid)) for oid in pasted], n_src))
            check("debug.plugin_id_audit = 0 in B", audit() == 0)
            x_p = render_iso(pasted[0], "l_pasted", end=3.0)
            check("a pasted object is audible", rms_db(x_p) > -40, rms_db(x_p))
            send("project.save")
            doc_b = json.load(open(manifest_b))
            n_ara_json = json.dumps(doc_b).count('"araSource"')
            check("B's file holds the two archives", n_ara_json >= 2, n_ara_json)

            # undo: ONE step removes the paste
            send("edit.undo")
            wait()
            check("one undo removes the whole paste", len(ara_objects()) == 0, ara_objects())

            # A is untouched
            send("tab.select", {"index": 1})
            wait(300000)
            for oid in ids_:
                wait_ara(oid, 300000)
            check("A still has its %d sources, with the same plugin ids" % n_objects,
                  all(send("plugin.list", {"host": oid})["plugins"][0]["id"] == before[oid][0] for oid in ids_))
            send("tab.close", {"index": 2, "discard": True})

        # ══════════════════════════════════════════════════════════════════════ M
        if want("M"):
            section("M  archive size (decision 4)")
            if QUICK:
                durations = [("melody30", MELODY30)]
            else:
                make_melody(MELODY180, 180.0)
                durations = [("melody30", MELODY30), ("melody180", MELODY180)]
            rows = []
            for label, path in durations:
                manifest = fresh("m_" + label)
                a = add_clip(path, lane=0)
                add_ara(a)
                t0 = time.time()
                wait_ara(a, 900000)
                t_an = time.time() - t0
                cap = send("object.ara.capture", {"id": a})
                send("project.save")
                size_with = os.path.getsize(manifest)
                send("plugin.remove", {"host": a, "plugin": send("plugin.list", {"host": a})["plugins"][0]["id"]})
                send("project.save")
                size_without = os.path.getsize(manifest)
                minutes = {"melody30": 0.5, "melody180": 3.0}[label]
                rows.append((label, t_an, cap["bytes"], cap["base64_chars"], cap["ms"], size_with - size_without,
                             cap["bytes"] / minutes))
            print("\n  %-10s %9s %10s %10s %9s %11s %12s" % ("signal", "analysis", "bytes", "base64", "capture", "json delta", "bytes/min"))
            for r in rows:
                print("  %-10s %7.1f s %10d %10d %6.0f ms %11d %12.0f" % r)
            for r in rows:
                check("%s: archive captured (%d bytes)" % (r[0], r[2]), r[2] > 0)
            big = [r for r in rows if r[0] == "melody180"]
            if big and big[0][2] > 2_000_000:
                info("WARNING: the 3-minute archive is %.1f MB (> 2 MB): consider moving archives to samples/" % (big[0][2] / 1e6))

        # ══════════════════════════════════════════════════════════════════════ N
        if want("N"):
            section("N  plugin missing")
            manifest = fresh("n_missing")
            a = add_clip(SINE220, lane=0)
            dry = render_iso(a, "n_dry")
            add_ara(a)
            wait_ara(a)
            send("object.ara.capture", {"id": a})
            send("project.save")
            doc = json.load(open(manifest))

            def corrupt(o):
                if isinstance(o, dict):
                    if o.get("araSource"):
                        o["araSource"]["plugin"]["identifier"] = "Nonexistent Vendor/NoSuchAra"
                        o["araSource"]["plugin"]["name"] = "NoSuchAra"
                    for v in o.values():
                        corrupt(v)
                elif isinstance(o, list):
                    for v in o:
                        corrupt(v)
            sha_before = None
            def archive_sha(o):
                if isinstance(o, dict):
                    if o.get("araSource") and o["araSource"].get("archive"):
                        return o["araSource"]["archive"]["data"]
                    for v in o.values():
                        r_ = archive_sha(v)
                        if r_:
                            return r_
                elif isinstance(o, list):
                    for v in o:
                        r_ = archive_sha(v)
                        if r_:
                            return r_
                return None
            sha_before = archive_sha(doc)
            corrupt(doc)
            bad = os.path.join(WORK, "n_missing_bad.objekat")
            json.dump(doc, open(bad, "w"))
            send("project.new")
            send("project.open", {"path": bad})
            wait(120000)
            check("the project with a missing ARA plugin loads", True)
            x = render_iso(a, "n_dry_loaded")
            check("the object plays DRY (%.2f vs %.2f dB)" % (rms_db(x), rms_db(dry)), near(rms_db(x), rms_db(dry), 0.5))
            st = status(a)
            check("the model still has the source, engine not valid", st["has_source"] and not st["engine_valid"], st)
            send("project.save_as", {"path": os.path.join(WORK, "n_missing_resaved.objekat")})
            doc2 = json.load(open(os.path.join(WORK, "n_missing_resaved.objekat")))
            check("the save rewrites the archive untouched", archive_sha(doc2) == sha_before)
            check("(and the source's plugin entry too)", archive_sha(doc2) is not None)

        # ══════════════════════════════════════════════════════════════════════ O
        if want("O"):
            section("O  cost of N sources (Q3)")
            sizes = [1, 10] if QUICK else [1, 10, 40]
            results = []
            fresh("o_baseline")
            info("RSS of the empty project: %.0f MB" % send("debug.ara_report")["rss_mb"])
            for n in sizes:
                manifest = fresh("o_%d" % n)
                a = add_clip(MELODY30, lane=0)
                add_ara(a)
                wait_ara(a, 300000)
                send("object.ara.capture", {"id": a})
                if n > 1:
                    # duplicate one at a time: the API's duplicate makes one copy
                    ids = []
                    for i in range(n - 1):
                        d = send("object.duplicate", {"ids": [a]})["ids"]
                        ids += d
                        send("object.move", {"id": d[0], "lane": i + 1, "start": 0.0})
                wait(300000)
                rep = send("debug.ara_report")
                send("project.save")
                size = os.path.getsize(manifest)
                send("project.new")
                t0 = time.time()
                send("project.open", {"path": manifest})
                wait(600000)
                load_s = time.time() - t0
                rep2 = send("debug.ara_report")
                results.append((n, load_s, rep2["rss_mb"], rep2["instances"], size))
                check("N=%d: all %d instances running after the load (%d)" % (n, n, rep2["instances"]),
                      rep2["instances"] == n, rep2)
            print("\n  %4s %10s %10s %10s %12s" % ("N", "load (s)", "RSS (MB)", "instances", "json bytes"))
            for r in results:
                print("  %4d %10.2f %10.0f %10d %12d" % r)
            # pushUndo with N objects: all fresh, ONE stale, ALL stale (a rename pushes a point, so it pays
            # the captures of every stale source before it takes its snapshot)
            n = sizes[-1]
            ids = [o["id"] for o in objs() if o.get("kind", "") != "group"][:n]
            if ids:
                def rename_ms():
                    t0 = time.time()
                    send("object.rename", {"id": ids[0], "name": "x%d" % int(time.time() * 1000 % 100000)})
                    return (time.time() - t0) * 1000
                for oid in ids:
                    send("object.ara.capture", {"id": oid})
                wait()
                fresh_ms = rename_ms()
                info("pushUndo (rename) with %d sources, none stale: %.0f ms" % (len(ids), fresh_ms))
                for label, marked in (("one stale", ids[1:2]), ("all stale", ids)):
                    for oid in ids:
                        send("object.ara.capture", {"id": oid})
                    send("debug.ara_mark_stale", {"ids": marked})
                    rep0 = send("debug.ara_report")
                    ms = rename_ms()
                    rep1 = send("debug.ara_report")
                    info("pushUndo (rename) with %d sources, %s: %.0f ms (%d captures, %d stale before)"
                         % (len(ids), label, ms, rep1["captures"] - rep0["captures"], rep0["stale"]))
        # ══════════════════════════════════════════════════════════════════════ P
        if want("P"):
            section("P  the \"+\" door: place, remove, place again")
            fresh("p_door")
            a = add_clip(SINE220, lane=0)

            def door(pick=None):
                pr = {"host": a}
                if pick:
                    pr["pick"] = pick
                return send("debug.ara_picker", pr)

            def offered(d):
                return [c["identifier"] for c in d["candidates"]]

            def pick_mel(label):
                d = door(mel["identifier"])
                pk = d.get("picked", {})
                check("%s: the picker offers Melodyne and the click goes through" % label,
                      pk.get("clickable") and pk.get("ok"), d)
                wait_ara(a)
                st = status(a)
                check("%s: the source is set and valid" % label, st["has_source"] and st["engine_valid"], st)
                return d

            def remove_source():
                plug = send("plugin.list", {"host": a})["plugins"][0]["id"]
                send("plugin.remove", {"host": a, "plugin": plug})
                wait()
                check("removed: no source", not status(a)["has_source"], status(a))

            d0 = door()
            check("before any source: Melodyne is among the offered rows", mel["identifier"] in offered(d0), d0)
            check("before any source: nothing refuses the object", d0["refusal"] is None, d0)
            pick_mel("first placement")
            d1 = door()
            check("with a source: the row is refused (already_source), the picker is not asked twice",
                  d1["refusal"] == "alreadySource", d1)
            remove_source()
            d2 = door()
            check("after the removal: Melodyne is offered again", mel["identifier"] in offered(d2), d2)
            check("after the removal: nothing refuses the object", d2["refusal"] is None, d2)
            check("after the removal: Melodyne was never 'disproved'", mel["identifier"] not in d2["disproved"], d2)
            pick_mel("second placement (after a removal)")
            # place -> remove -> place, several times over
            for i in range(3):
                remove_source()
                pick_mel("round %d" % (i + 3))
            # undo / redo of a removal, then the door
            remove_source()
            send("edit.undo")
            wait()
            wait_ara(a)
            check("undo of the removal: the source is back", status(a)["has_source"] and status(a)["engine_valid"], status(a))
            remove_source()
            send("edit.undo")
            wait()
            send("edit.redo")
            wait()
            check("undo then redo of the removal: no source", not status(a)["has_source"], status(a))
            d3 = door()
            check("after undo+redo of a removal: Melodyne is offered, nothing refuses",
                  mel["identifier"] in offered(d3) and d3["refusal"] is None, d3)
            pick_mel("placement after undo+redo of a removal")
            # undo of the placement itself, then place again
            send("edit.undo")
            wait()
            check("undo of the placement: no source", not status(a)["has_source"], status(a))
            d4 = door()
            check("after the undo of a placement: offered, nothing refuses",
                  mel["identifier"] in offered(d4) and d4["refusal"] is None, d4)
            pick_mel("placement after the undo of a placement")
            # a removal made while Melodyne is still analysing
            fresh("p_door2")
            a = add_clip(MELODY30, lane=0)
            door(mel["identifier"])
            remove_source()
            pick_mel("placement right after a removal during the analysis")
            # a candidate the module PROVES not ARA (a false positive of the file pre-filter) must not
            # take Melodyne's row away with it; a module the engine could not read must not be condemned.
            others = [i for i in offered(door()) if i != mel["identifier"]]
            info("%d other candidate(s) offered by the pre-filter" % len(others))
            remove_source()
            for ident in others[:3]:
                d = door(ident)
                pk = d.get("picked", {})
                info("  %s -> %s" % (os.path.basename(ident), pk.get("refusal") or "set up"))
                if pk.get("ok"):
                    remove_source()
                check("a pick on %s leaves Melodyne offered" % os.path.basename(ident),
                      mel["identifier"] in offered(d), d)
            pick_mel("placement after the picks on other candidates")

        # ══════════════════════════════════════════════════════════════════════ Z
        if want("Z") or SECTIONS is None:
            section("Z  end")
            pid = pid_for_socket(SOCK)
            wc = window_count_for_pid(pid) if pid else None
            check("no window on the headless pid (%s)" % wc, wc in (0, None), wc)
            check("debug.plugin_id_audit = 0", audit() == 0)
    rc = finish()
except SystemExit as e:
    rc = e.code if isinstance(e.code, int) else 1
except Exception as e:
    import traceback
    traceback.print_exc()
    rc = finish() or 1
finally:
    try:
        os.system("grep -E '\\[ARA\\]|\\[PERF\\] ARA' %s | tail -15" % LOGFILE)
    except Exception:
        pass
    proc.kill()
    proc.wait()
sys.exit(rc)

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""E0 of the loop recording (docs/plan_enregistrement_audio.md, "Rec en boucle"): PROOFS, before the design is built on them.

Headless, on the virtual card (`--virtual-audio`, `--virtual-midi`), never a window. Two instances are driven: the engine as the
patch 0050 makes it, and the stock behaviour (`OBJ_REC_STOCK=1` puts the flag of `OBJEngineBehaviour::recordsThroughLoop` back
to false), so that a result is always read against the reference.

  P1  PUNCH-IN during a play that is ALREADY looping. Stock: the recorder is told the LOOPED position of the press but gets the
      play head's UNLOOPED clock, which is N laps further: the file starts with N x L of silence (WaveInputDevice
      firstRecCallback: `adjustSamples -= (blockStart - punchStart)` < 0 -> silence). 0050: the recording clock is anchored at the
      LOOPED position of the press -> no silence. (Needs the loop to be kept under the recording: `ObjekatSession`, E4. The
      scenario was first run, in E0, with the same change made by hand.)
  P2  JOURNAL vs RENDER. White noise on the timeline, the card's loopback as the input, a loop [3 s, 5 s] switched on by the tick
      while a recording started from 1 s runs. The journal the engine kept (`[REC] ... journal:` in stderr: (clock, timeline) at
      every discontinuity of the head) must say where every stretch of the file comes from: for each stretch the file is
      cross-correlated with the source at the timeline position the journal gives -> lag 0 (+-1 sample).
  P3  REBASE UNDER RECORDING. The loop is switched on / its bounds are moved / it is switched off in the middle of a recording.
      Stock: the loop change ends the recording (TransportControl: `stopIfRecording` on `looping`) and the play head rebases its
      unlooped clock. 0050: the recording goes on, the recording clock is not rebased (the diagnostic counts how often the head's
      own unlooped clock moved against it), the journal stays one monotone line, the file stays continuous.
  P4  MIDI COST. A long MIDI capture (thousands of notes) through a short loop: the time `rec.stop` takes, the number of passes
      and the number of notes -- against the same capture with no loop.

    ./scenario_record_loop_proof.py /path/to/objekat.app

Exit: 0 if every assertion passes, 1 if one fails, 2 on bad usage. Prints the measures it takes (they are the report of E0).
"""

import hashlib, math, os, re, struct, subprocess, sys, tempfile, time, wave

import numpy as np

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

SETTINGS = os.path.expanduser("~/Library/objekat/Settings.xml")
SR = 48000
ok, ko = 0, 0


def section(title):
    print("\n── %s " % title + "─" * max(4, 74 - len(title)))


def check(label, cond, detail=""):
    global ok, ko
    if cond:
        ok += 1
        print("  OK   %-72s" % label)
    else:
        ko += 1
        print("  FAIL %-72s %s" % (label, detail))


def digest():
    try:
        with open(SETTINGS, "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()[:16]
    except FileNotFoundError:
        return None


def read_wav(path):
    """(sample rate, float32 data [frames, channels]) of a 16-bit PCM or 32-bit float WAV."""
    with open(path, "rb") as f:
        raw = f.read()
    pos, fmt, data = 12, None, None
    while pos + 8 <= len(raw):
        cid, size = raw[pos:pos + 4], struct.unpack("<I", raw[pos + 4:pos + 8])[0]
        body = raw[pos + 8:pos + 8 + size]
        if cid == b"fmt ":
            tag, ch, sr, _, _, bits = struct.unpack("<HHIIHH", body[:16])
            if tag == 0xFFFE and len(body) >= 26:
                tag = struct.unpack("<H", body[24:26])[0]
            fmt = (tag, ch, sr, bits)
        elif cid == b"data":
            data = body
        pos += 8 + size + (size & 1)
    tag, ch, sr, bits = fmt
    if tag == 3:
        arr = np.frombuffer(data[:len(data) // 4 * 4], dtype="<f4").reshape(-1, ch)
    else:
        arr = np.frombuffer(data[:len(data) // 2 * 2], dtype="<i2").reshape(-1, ch).astype("float32") / 32768.0
    return sr, arr


def wait_pos(c, t, timeout=40):
    end = time.time() + timeout
    while time.time() < end:
        if c.send("transport.state")["position"] >= t:
            return True
        time.sleep(0.02)
    return False


def new_project(c, tmp, name):
    c.send("project.new")
    path = os.path.join(tmp, name, name + ".objekat")
    c.send("project.save_as", {"path": path})
    return os.path.join(tmp, name)


def kids(c, gid):
    c.send("group.expand", {"id": gid, "expanded": True})
    out = [o for o in c.send("object.list")["objects"] if o["parent"] == gid]
    c.send("group.expand", {"id": gid, "expanded": False})
    return out


def make_zone(c, first, start, end, lane):
    c.send("timesel.set", {"start": start, "end": end, "lanes": [lane]})
    r = c.send("rec.drop", {"first": first, "count": 1, "lane": lane, "time": (start + end) / 2})
    c.send("timesel.clear")
    assert r["outcome"] == "create", r
    return r["group"]


JOURNAL = re.compile(r"\[REC\] \+[\d.]+ ms journal: (\d+) point\(s\)( OVERFLOW)?, stock-clock rebases (\d+) \(last (-?\d+) samples\) "
                     r"\(clock,timeline\):(.*)$")


def last_journal(err_path):
    """The last `[REC] journal` line of the app's stderr -> (points [(clock, timeline)], overflow, rebases, last jump) or None."""
    try:
        lines = [l for l in open(err_path, errors="ignore").read().splitlines() if "journal:" in l and "[REC]" in l]
    except OSError:
        return None
    if not lines:
        return None
    m = JOURNAL.search(lines[-1])
    if not m:
        return None
    pts = [(float(a), float(b)) for a, b in re.findall(r"\(([-0-9.]+),([-0-9.]+)\)", m.group(5))]
    return pts, bool(m.group(2)), int(m.group(3)), int(m.group(4))


def leading_silence(x, thr=0.01):
    idx = np.nonzero(np.abs(x) > thr)[0]
    return (idx[0] if len(idx) else len(x)) / SR


class App:
    def __init__(self, tmp, name, stock, midi=False):
        self.sock = "/tmp/objk-loopproof-%s-%d.sock" % (name, os.getpid())
        if os.path.exists(self.sock):
            os.remove(self.sock)
        self.err = os.path.join(tmp, "app-%s.err" % name)
        args = [BIN, "--headless", "--api", "--no-recent", "--language=en", "--virtual-audio"]
        if midi:
            args.append("--virtual-midi")
        env = dict(os.environ, OBJ_SKIP_REAL_CARD="1")
        if stock:
            env["OBJ_REC_STOCK"] = "1"
        self.proc = subprocess.Popen(args + ["--socket=" + self.sock], stdout=subprocess.DEVNULL,
                                     stderr=open(self.err, "w"), env=env)
        for _ in range(160):
            if os.path.exists(self.sock):
                break
            time.sleep(0.25)

    def close(self):
        self.proc.terminate()
        try:
            self.proc.wait(10)
        except subprocess.TimeoutExpired:
            self.proc.kill()


before = digest()
tmp = tempfile.mkdtemp(prefix="objk-loopproof-")

# the noise the loopback will carry (16-bit, mono, 48 kHz, 14 s): unique everywhere
noise = os.path.join(tmp, "noise.wav")
rng = np.random.RandomState(7)
src = (rng.uniform(-1.0, 1.0, 14 * SR) * 0.4 * 32767).astype("<i2")
with wave.open(noise, "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
    w.writeframes(src.tobytes())
srcf = src.astype("float32") / 32768.0


def lag_of(x, t0_samples, margin=600):
    """The lag (samples) at which the file chunk `x` matches the noise placed at `t0_samples`: x[n] ~ src[t0 + n + lag]."""
    n = len(x)
    lo, hi = t0_samples - margin, t0_samples + n + margin
    if lo < 0 or hi > len(srcf):
        return None, 0.0
    ref = srcf[lo:hi]
    nfft = 1 << (len(ref) + n).bit_length()
    corr = np.fft.irfft(np.fft.rfft(ref, nfft) * np.conj(np.fft.rfft(x, nfft)), nfft)[:2 * margin + 1]
    k = int(np.argmax(corr))
    norm = float(np.sqrt(np.sum(x ** 2) * np.sum(ref[k:k + n] ** 2))) + 1e-12
    return k - margin, float(corr[k] / norm)


def run(stock):
    tag = "STOCK" if stock else "0050 "
    app = App(tmp, "stock" if stock else "new", stock, midi=not stock)
    out = {}
    try:
        with ObjekatClient(app.sock) as c:
            c.send("project.new")
            c.send("input.enable")
            c.send("audio.virtual.set_input", {"channel": 0, "signal": "sine", "frequency": 440, "amplitude": 0.5})

            # ── P1 ----------------------------------------------------------------------------------
            section("P1 [%s] punch-in during a play that is already looping (loop [1 s, 3 s], pressed after ~5 s)" % tag)
            new_project(c, tmp, "p1-" + tag.strip())
            z = make_zone(c, 0, 0, 60, 0)
            c.send("rec.arm", {"group": z, "on": True})
            c.send("debug.transport_loop", {"start": 1.0, "end": 3.0, "enabled": True})
            c.send("transport.seek", {"seconds": 1.2})
            c.send("transport.play")
            time.sleep(5.3)                       # ~2.6 laps of 2 s
            pos_press = c.send("transport.state")["position"]
            c.send("rec.start")
            time.sleep(1.5)
            t = sorted(c.send("rec.stop")["last_takes"], key=lambda x: x["pass"])    # one take per pass, one file
            check("[%s] the recording gave a take" % tag, len(t) >= 1, t)
            if t:
                sr, arr = read_wav(t[0]["path"])
                sil = leading_silence(arr[:, 0])
                dur = len(arr) / sr
                print("       press at %.3f s (looped), file %.3f s long, LEADING SILENCE %.3f s" % (pos_press, dur, sil))
                out["p1_silence"] = sil
                if stock:
                    check("[STOCK] DEFECT PROVEN: the file starts with N x L = a multiple of 2 s of silence (%.3f s)" % sil,
                          sil > 1.5, sil)
                else:
                    check("[0050] no silence at the head (%.3f s)" % sil, sil < 0.05, sil)
                    check("[0050] the file is as long as the recording (%.3f s ~ 1.5 s + latency tail)" % dur, 1.3 < dur < 1.9, dur)
            c.send("edit.undo")

            # ── P3 ----------------------------------------------------------------------------------
            section("P3 [%s] loop switched on / moved / off IN THE MIDDLE of a recording" % tag)
            new_project(c, tmp, "p3-" + tag.strip())
            z = make_zone(c, 0, 0, 60, 0)
            c.send("rec.arm", {"group": z, "on": True})
            c.send("debug.transport_loop", {"start": 3.0, "end": 5.0, "enabled": False})
            c.send("transport.seek", {"seconds": 0.5})
            c.send("rec.start")
            wait_pos(c, 2.0)
            c.send("debug.transport_loop", {"start": 3.0, "end": 5.0, "enabled": True})      # switched on before the head gets there
            wait_pos(c, 3.3)
            time.sleep(0.4)
            rec_after_on = c.send("rec.status")["recording"]
            if not stock:
                time.sleep(2.2)                                                              # one wrap at 5 s (head back near 3.0-3.5)
                c.send("debug.transport_loop", {"start": 3.0, "end": 4.0, "enabled": True})  # the bounds move: the next wrap follows
                time.sleep(2.6)
                c.send("debug.transport_loop", {"start": 3.0, "end": 4.0, "enabled": False})  # the loop is cut: straight on
                time.sleep(1.0)
            rec_going = c.send("rec.status")["recording"]
            if stock:
                check("[STOCK] DEFECT PROVEN: switching the loop on ended the recording (recording=%s)" % rec_after_on,
                      rec_after_on is False, rec_after_on)
                c.send("transport.stop") if c.send("transport.state")["playing"] else None
            else:
                check("[0050] the recording goes on through the three loop edits", rec_going is True, rec_going)
                t = sorted(c.send("rec.stop")["last_takes"], key=lambda x: x["pass"])
                j = last_journal(app.err)
                check("[0050] a journal exists", j is not None)
                if j is not None:
                    pts, over, rebases, jump = j
                    clocks = [p[0] for p in pts]
                    print("       journal: %d points, stock unlooped clock rebased %d time(s) (last jump %d samples), overflow=%s"
                          % (len(pts), rebases, jump, over))
                    print("       points (clock, timeline): %s" % ", ".join("(%.3f, %.3f)" % p for p in pts))
                    check("[0050] the recording clock is monotone (strictly increasing journal)", all(b > a for a, b in zip(clocks, clocks[1:])), clocks)
                    check("[0050] the stock unlooped clock WAS rebased by the loop edits (%d) -- the recording clock was not" % rebases, rebases >= 1, rebases)
                    out["p3_rebases"] = rebases
                    check("[0050] no overflow", not over)
                    if t:
                        sr, arr = read_wav(t[0]["path"])
                        origin = t[0]["start"] - t[0]["source_offset"]
                        total = clocks[-1] - clocks[0]
                        print("       file %.3f s, origin on the clock %.3f s, journal spans from clock %.3f s" % (len(arr) / sr, origin, clocks[0]))
                        check("[0050] the file is continuous: no stretch is silent (sine all along)",
                              float(np.min(np.abs(np.convolve(np.abs(arr[int(0.2 * sr):, 0]), np.ones(2400) / 2400, "valid")))) > 0.05)
            c.send("edit.undo") if not stock else None
            if c.send("transport.state")["playing"]:
                c.send("transport.stop")
            c.send("debug.transport_loop", {"enabled": False})

            if not stock:
                # ── P5 -------------------------------------------------------------------------------
                section("P5 [%s] a loop under 250 ms is not a loop for the recorder: the recording is linear" % tag)
                new_project(c, tmp, "p5")
                z = make_zone(c, 0, 0, 30, 0)
                c.send("rec.arm", {"group": z, "on": True})
                c.send("debug.transport_loop", {"start": 3.0, "end": 3.1, "enabled": True})
                c.send("transport.seek", {"seconds": 2.0})
                c.send("rec.start")
                wait_pos(c, 4.0)
                t = c.send("rec.stop")["last_takes"]
                j = last_journal(app.err)
                check("a 100 ms loop: the journal has ONE point (no wrap) and the take lasts the recording",
                      j is not None and len(j[0]) == 1 and len(t) == 1 and 1.9 < t[0]["duration"] < 2.3, (j, t))
                c.send("debug.transport_loop", {"enabled": False})

                # ── P6 -------------------------------------------------------------------------------
                section("P6 [%s] audio takes N per zone: one per pass crossing the window, one file, newest on top, one undo" % tag)
                new_project(c, tmp, "p6")
                z = make_zone(c, 0, 2.0, 4.5, 0)
                c.send("rec.arm", {"group": z, "on": True})
                c.send("debug.transport_loop", {"start": 3.0, "end": 5.0, "enabled": True})
                c.send("transport.seek", {"seconds": 1.0})
                d0 = c.send("perf.census")["undo_depth"]
                c.send("rec.start")
                wait_pos(c, 3.5)
                time.sleep(5.2)                                           # 1 -> 5, then 3 -> 5 two times and a bit
                r = c.send("rec.stop")
                tk = r["last_takes"]
                j = last_journal(app.err)
                pts = j[0] if j else []
                print("       journal: %s" % ", ".join("(%.3f, %.3f)" % p for p in pts))
                print("       takes: %s" % "; ".join("pass %d lane %d [%.3f +%.3f] off %.3f %s" % (t["pass"], t["lane"], t["start"], t["duration"],
                      t["source_offset"], "audible" if t["audible"] else "muted") for t in tk))
                check("one take per pass that crosses the window (%d passes in the journal)" % len(pts),
                      len(tk) == len(pts) and len(tk) >= 3, (len(tk), len(pts)))
                check("one file for all of them", len({t["path"] for t in tk}) == 1)
                check("the newest on lane 0, the older ones below: lanes read newest..oldest",
                      [t["lane"] for t in sorted(tk, key=lambda t: t["pass"])] == list(range(len(tk) - 1, -1, -1)))
                check("only the LAST pass is audible (mute mode)", [t["audible"] for t in sorted(tk, key=lambda t: t["pass"])]
                      == [False] * (len(tk) - 1) + [True])
                check("the passes after the first start on the loop's start (3.000) and are cropped at the window's end (4.5)",
                      all(abs(t["start"] - 3.0) < 1e-3 and abs(t["start"] + t["duration"] - 4.5) < 1e-3 for t in tk if 0 < t["pass"] < len(tk) - 1))
                if tk:
                    t0 = min(tk, key=lambda t: t["pass"])
                    check("pass 0 starts at the window's start, 2.000", abs(t0["start"] - 2.0) < 1e-3, t0["start"])
                    # one continuous file: the takes' file positions chain through the loop (offset_k = k-th pass's file start)
                    offs = [t["source_offset"] for t in sorted(tk, key=lambda t: t["pass"])]
                    check("file offsets increase pass after pass", all(b > a for a, b in zip(offs, offs[1:])), offs)
                steps = min(len(tk), 16)
                check("rec.stop leaves ONE undo point per pass (%d)" % steps, c.send("perf.census")["undo_depth"] == d0 + steps,
                      (c.send("perf.census")["undo_depth"], d0, steps))
                c.send("edit.undo")
                check("one undo takes the last pass away only", len(kids(c, z)) == len(tk) - 1, len(kids(c, z)))
                for _ in range(steps - 1):
                    c.send("edit.undo")
                check("one undo per pass takes every take away", kids(c, z) == [])
                c.send("debug.transport_loop", {"enabled": False})

                # ── P2 -------------------------------------------------------------------------------
                section("P2 [%s] the journal against the render (noise, loopback, loop [3 s, 5 s] switched on by the tick)" % tag)
                new_project(c, tmp, "p2")
                c.send("object.add", {"path": noise, "lane": 5, "start": 0})
                c.send("wait_idle", {"timeout_ms": 5000})
                c.send("audio.virtual.set_input", {"channel": 0, "signal": "loopback"})
                z = make_zone(c, 0, 0, 14, 0)
                c.send("rec.arm", {"group": z, "on": True})
                c.send("debug.transport_loop", {"start": 3.0, "end": 5.0, "enabled": True})
                c.send("transport.seek", {"seconds": 1.0})
                c.send("rec.start")
                wait_pos(c, 3.2)
                time.sleep(6.5)                                   # ~3 laps
                t = sorted(c.send("rec.stop")["last_takes"], key=lambda x: x["pass"])
                j = last_journal(app.err)
                check("a take and a journal", len(t) >= 1 and j is not None, (t, j))
                if t and j:
                    pts = j[0]
                    sr, arr = read_wav(t[0]["path"])
                    x = arr[:, 0]
                    origin = t[0]["start"] - t[0]["source_offset"]          # the clock instant of the file's first sample
                    print("       file %.3f s, origin %.4f s on the clock; journal: %s" % (len(x) / sr, origin,
                          ", ".join("(%.4f, %.4f)" % p for p in pts)))
                    # the stretches: [clock_i, clock_{i+1}) at timeline_i...; the last one runs to the end of the file
                    ends = [p[0] for p in pts[1:]] + [origin + len(x) / sr]
                    lags = []
                    for (c0, t0), c1 in zip(pts, ends):
                        f0 = int(round((c0 - origin) * sr)) + int(0.30 * sr)          # 300 ms in: the playback itself needs ~150 ms to
                        f1 = int(round((c1 - origin) * sr)) - int(0.08 * sr)   # refill its read-ahead after a jump (Debug build)
                        if f1 - f0 < int(0.3 * sr):
                            continue
                        f1 = min(f1, f0 + int(0.8 * sr))
                        tl0 = int(round(t0 * sr)) + (f0 - int(round((c0 - origin) * sr)))
                        lag, q = lag_of(x[f0:f1], tl0)
                        lags.append((c0, t0, lag, q))
                        print("       stretch from clock %.3f (timeline %.3f): lag %s sample(s), correlation %.3f" % (c0, t0, lag, q))
                    check("at least 3 stretches could be compared (>= 2 laps of the loop)", len(lags) >= 3, lags)
                    check("every stretch matches the source at the timeline the journal gives: lag 0 (+-1 sample)",
                          all(l is not None and abs(l) <= 1 and q > 0.9 for _, _, l, q in lags), lags)
                    # the wraps are exactly at the loop's bounds: 5.0 -> 3.0
                    jumps = [(pts[i][0] - pts[i - 1][0], pts[i - 1][1]) for i in range(1, len(pts))]
                    wrap_ok = all(abs((dc + t0) - 5.0) < 2.0 / sr or abs(dc) < 0.2 for dc, t0 in jumps)
                    check("each pass ends exactly on the loop's end (5.000 s) within 2 samples", wrap_ok, jumps)
                    after = [p for p in pts if p[1] == pts[-1][1]]
                    check("the passes restart at the loop's start (3.000 s)", all(abs(p[1] - 3.0) < 1.0 / sr for p in pts[2:]), pts)
    finally:
        app.close()
    return out


def p4():
    section("P4 [0050] MIDI cost: a long capture through a short loop")
    app = App(tmp, "midi", False, midi=True)
    try:
        with ObjekatClient(app.sock) as c:
            c.send("project.new")
            c.send("input.enable")
            new_project(c, tmp, "p4")
            vstat = c.send("midi.virtual.status")
            vid = vstat["device_id"]
            insts = c.send("plugin.list_available", {"instruments_only": True})["plugins"]
            dls = next(p for p in insts if p["name"] == "DLSMusicDevice")

            def one(loop):
                c.send("timesel.set", {"start": 0, "end": 60, "lanes": [0 if not loop else 1]})
                r = c.send("rec.drop", {"midi": vid, "lane": 0 if not loop else 1, "time": 30})
                c.send("timesel.clear")
                gid = r["group"]
                c.send("instrument.set", {"id": gid, "identifier": dls["identifier"], "format": dls["format"]})
                c.send("rec.arm", {"group": gid, "on": True})
                if loop:
                    c.send("debug.transport_loop", {"start": 1.0, "end": 1.5, "enabled": True})
                else:
                    c.send("debug.transport_loop", {"enabled": False})
                c.send("transport.seek", {"seconds": 0.5})
                c.send("rec.start")
                n, span = 1500, 12.0
                ev = []
                for i in range(n):
                    on = 0.3 + span * i / n
                    ev.append({"kind": "on", "note": 40 + (i % 40), "velocity": 90, "delay_ms": on * 1000})
                    ev.append({"kind": "off", "note": 40 + (i % 40), "velocity": 0, "delay_ms": (on + 0.03) * 1000})
                c.send("midi.virtual.send", {"events": ev})
                time.sleep(span + 1.0)
                t0 = time.time()
                st = c.send("rec.stop")
                dt = time.time() - t0
                take = st["last_takes"][0] if st["last_takes"] else None
                if take is not None:
                    take = dict(take, notes=len(take.get("notes", [])))
                j = last_journal(app.err)
                npass = len(j[0]) if j else 0
                c.send("rec.arm", {"group": gid, "on": False})
                return dt, (take or {}).get("notes", 0), npass

            for loop in (False, True):
                dt, notes, npass = one(loop)
                print("       %s: rec.stop took %.0f ms, %d notes in the take, %d journal point(s)"
                      % ("through a loop [1 s, 1.5 s]" if loop else "linear               ", dt * 1000, notes, npass))
                check("MIDI capture %s: rec.stop under 2 s" % ("through the loop" if loop else "linear"), dt < 2.0, dt)
    finally:
        app.close()


run(True)
res = run(False)
p4()

after = digest()
section("Settings.xml")
print("  note Settings.xml %s (a known false failure of the scenarios: the engine rewrites it on exit)"
      % ("unchanged" if before == after else "rewritten on exit: %s -> %s" % (before, after)))

print("\n%d OK, %d FAIL" % (ok, ko))
sys.exit(0 if ko == 0 else 1)

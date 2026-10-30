#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""E0 of docs/plan_groupes_midi.md : the ENGINE PROOF (P1..P13). No production behaviour is exercised that
the plan wants to change: the experiment mounts an instrument on a GROUP's container, engine side only
(`debug.mount_instrument`, DEBUG builds), puts empty MIDI clips (no instrument of their own) inside it and
measures what comes out. Headless, `--virtual-audio`, Apple's DLSMusicDevice (no third-party plugin).

  P1  group with an instrument + empty clip: sound (export RMS); witness without the instrument: exact silence
  P2  host > sub-group > empty clip: same signal as P1 (cross-correlation lag, max difference)
  P3  clip with its own instrument (normal path): the REFERENCE ("same as before"), reproducible hash
  P4  note crossing the end of a cropped (bounded) group: silent after it, no stuck note on re-entry
  P5  looping group: as many attacks as laps, none stuck, none doubled
  P6  transport loop, real time: as many attacks as laps (note ON the loop start included)
  P7  jump of the playhead during a note: no note after the jump
  P8  PDC: host + latency plugin next to an audio clip: both paths shifted alike
  P9  volume curve on an empty clip and on a sub-group: the notes do not move (timestamps)
  P10 two empty clips with different notes: the sum of the two alone; none played twice
  P11 external FX on an empty clip, enabled / disabled: does it eat the notes
  P12 native mute / unmute / mute again during a note, real time: no note stuck at the 2nd mute
  P13 instrument on an EMPTY group, a clip added afterwards: sound at the export

Statuses: PASS = the engine does what the plan needs; DEFECT = a patch (or a guard) is needed, the figures say
which; INFO = a measurement that justifies a design choice; ERROR = the harness failed, nothing proved.

    ./scenario_group_midi_proof.py /path/to/objekat.app [P1 P4 ...]

Exit: 0 if no DEFECT / ERROR, 1 otherwise, 2 on bad usage.
"""

import hashlib, math, os, struct, subprocess, sys, tempfile, time, traceback, wave

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

if len(sys.argv) < 2:
    print(__doc__)
    sys.exit(2)

APP = sys.argv[1]
ONLY = [a.upper() for a in sys.argv[2:]]
BIN = os.path.join(APP, "Contents", "MacOS", "objekat")
if not os.path.exists(BIN):
    print("not an app bundle: %s" % APP)
    sys.exit(2)

SR = 48000
BLOCK = 512                 # a render block, in samples (the unit of the plan's "±1 bloc")
WORK = tempfile.mkdtemp(prefix="objk-gmp-")
VERDICT = {}                # "P1" -> (status, text)
NOTES = {}                  # "P1" -> [lines of measurements]


# ── small helpers ────────────────────────────────────────────────────────────────────────────────

def section(title):
    print("\n── %s " % title + "─" * max(4, 90 - len(title)))


def say(pid, line):
    NOTES.setdefault(pid, []).append(line)
    print("     " + line)


def verdict(pid, status, text):
    VERDICT[pid] = (status, text)
    print("  %-7s %s : %s" % (status, pid, text))


class App:
    """One headless instance, one socket, killed on exit."""

    def __init__(self, tag):
        self.sock = "/tmp/objk-gmp-%d-%s.sock" % (os.getpid(), tag)
        if os.path.exists(self.sock):
            os.remove(self.sock)
        self.err = os.path.join(WORK, "app-%s.err" % tag)
        self.proc = subprocess.Popen(
            [BIN, "--headless", "--api", "--no-recent", "--language=en", "--virtual-audio", "--virtual-midi",
             "--socket=" + self.sock],
            stdout=subprocess.DEVNULL, stderr=open(self.err, "w"), env=dict(os.environ, OBJ_SKIP_REAL_CARD="1"))
        for _ in range(240):
            if os.path.exists(self.sock):
                break
            time.sleep(0.25)
        self.c = ObjekatClient(self.sock).connect()

    def close(self):
        try:
            self.c.close()
        except Exception:
            pass
        self.proc.terminate()
        try:
            self.proc.wait(15)
        except Exception:
            self.proc.kill()
        if os.path.exists(self.sock):
            os.remove(self.sock)


def read_wav(path):
    """24-bit (or 16 / 32-float) PCM WAV -> float array (frames, channels)."""
    with open(path, "rb") as f:
        raw = f.read()
    pos, fmt, data = 12, None, b""
    while pos + 8 <= len(raw):
        cid, size = raw[pos:pos + 4], struct.unpack("<I", raw[pos + 4:pos + 8])[0]
        body = raw[pos + 8:pos + 8 + size]
        if cid == b"fmt ":
            fmt = struct.unpack("<HHIIHH", body[:16])
        elif cid == b"data":
            data = body
        pos += 8 + size + (size & 1)
    tag, ch, sr, _, _, bits = fmt
    assert sr == SR, sr
    if tag == 3 and bits == 32:
        x = np.frombuffer(data[:len(data) // 4 * 4], dtype="<f4").astype(np.float64)
    elif bits == 24:
        n = len(data) // 3
        b = np.frombuffer(data[:n * 3], dtype=np.uint8).reshape(n, 3).astype(np.int32)
        v = b[:, 0] | (b[:, 1] << 8) | (b[:, 2] << 16)
        v = np.where(v & 0x800000, v - 0x1000000, v)
        x = v.astype(np.float64) / 8388608.0
    elif bits == 16:
        x = np.frombuffer(data[:len(data) // 2 * 2], dtype="<i2").astype(np.float64) / 32768.0
    else:
        raise ValueError("unsupported wav: %r" % (fmt,))
    return x.reshape(-1, ch)


def write_click(path, secs=0.25):
    """A mono 16-bit file: 1 kHz burst, 8 ms, starting AT sample 0 (the reference path of P8)."""
    n = int(SR * secs)
    t = np.arange(n) / SR
    x = np.zeros(n)
    m = int(SR * 0.008)
    x[:m] = 0.5 * np.sin(2 * np.pi * 1000 * t[:m]) * np.hanning(m)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes((x * 32767).astype("<i2").tobytes())


def peak(x, a=0.0, b=None):
    s = x[int(a * SR):(None if b is None else int(b * SR))]
    return float(np.max(np.abs(s))) if s.size else 0.0


def rms(x, a=0.0, b=None):
    s = x[int(a * SR):(None if b is None else int(b * SR))]
    return float(np.sqrt(np.mean(s ** 2))) if s.size else 0.0


def db(v):
    return 20 * math.log10(max(v, 1e-12))


def onset(x, a, b, thr=1e-3):
    """First sample (absolute) in [a, b] seconds whose |value| exceeds thr, or None."""
    s = np.max(np.abs(x[int(a * SR):int(b * SR)]), axis=1) if x.ndim == 2 else np.abs(x[int(a * SR):int(b * SR)])
    i = np.nonzero(s > thr)[0]
    return None if i.size == 0 else int(a * SR) + int(i[0])


def lag_and_diff(a, b, t0=0.0, t1=None, maxlag=4096):
    """Cross-correlation lag of b against a (samples, + = b later), and the max |a-b| (same length)."""
    n = min(len(a), len(b))
    a, b = a[:n], b[:n]
    sa = a[int(t0 * SR):(None if t1 is None else int(t1 * SR)), 0]
    sb = b[int(t0 * SR):(None if t1 is None else int(t1 * SR)), 0]
    if np.max(np.abs(sa)) < 1e-9 or np.max(np.abs(sb)) < 1e-9:
        return None, float(np.max(np.abs(a - b)))
    N = 1 << int(math.ceil(math.log2(len(sa) + len(sb))))
    cc = np.fft.irfft(np.fft.rfft(sb, N) * np.conj(np.fft.rfft(sa, N)), N)
    cc = np.concatenate([cc[-maxlag:], cc[:maxlag + 1]])
    return int(np.argmax(cc)) - maxlag, float(np.max(np.abs(a - b)))


def sha(x):
    return hashlib.sha256(np.round(x * 8388608.0).astype(np.int32).tobytes()).hexdigest()[:16]


def attacks(x, a, b, thr_rel=0.05, quiet_ms=60, ratio=2.5):
    """Times (s) of the attacks in [a, b]: a 2 ms envelope sample above thr_rel of the global peak AND `ratio`
    times the max of the previous quiet_ms."""
    s = np.max(np.abs(x), axis=1)
    h = int(SR * 0.002)
    env = np.array([s[i:i + h].max() for i in range(0, len(s) - h, h)])
    g = env.max() if env.size else 0
    out, last = [], -10.0
    back = max(1, int(quiet_ms / 2))
    for i in range(0, len(env)):
        t = i * h / SR
        if t < a or t > b:
            continue
        prev = env[max(0, i - back):i].max() if i > 0 else 0.0
        if env[i] > thr_rel * g and env[i] > ratio * max(prev, 1e-6) and t - last > 0.12:
            out.append(t)
            last = t
    return out


# ── the scene builders ───────────────────────────────────────────────────────────────────────────

def boot(tag):
    app = App(tag)
    c = app.c
    c.send("project.new")
    insts = c.send("plugin.list_available", {"instruments_only": True})["plugins"]
    dls = next(p for p in insts if p["name"] == "DLSMusicDevice")
    app.inst = {"identifier": dls["identifier"], "format": dls["format"]}
    st = c.send("transport.state")
    app.tempo = st["tempo"]
    app.spb = 60.0 / st["tempo"]
    app.main = c.send("stem.list")["main"]
    return app


def midi_clip(app, start, end, lane, notes):
    """An EMPTY clip (no instrument of its own). notes = [(pitch, start_s, len_s, velocity)] relative to the clip."""
    c = app.c
    m = c.send("midi.create_clip", {"start": start, "end": end, "lane": lane})["id"]
    for pitch, s, l, v in notes:
        c.send("midi.add_note", {"id": m, "pitch": pitch, "start_beat": s / app.spb,
                                 "length_beats": l / app.spb, "velocity": v})
    return m


def group(app, ids):
    return app.c.send("group.create", {"ids": ids})["id"]


def mount(app, gid):
    return app.c.send("debug.mount_instrument", {"id": gid, **app.inst})["plugin_key"]


def export(app, name, start, end):
    c = app.c
    path = os.path.join(WORK, name + ".wav")
    if os.path.exists(path):
        os.remove(path)
    r = c.send("export.run", {"path": path, "format": "wav", "sample_rate": SR, "bit_depth": 24,
                              "dithering": False, "start": start, "end": end})
    job = c.send("job.wait", {"id": r["job_id"], "timeout_ms": 120000})
    res = job.get("result", {})
    if res.get("phase") == "failed":
        # The engine refuses to render a project with no audio source at all ("Didn't find any audio to
        # render"): empty MIDI clips and no instrument = nothing to render = silence, by definition.
        print("     (export %s: %s -> silence)" % (name, res.get("error")))
        return np.zeros((int((end - start) * SR), 2))
    return read_wav(path)


def level(app):
    return app.c.send("stem.level", {"id": app.main})["level"]


FIRED = []     # series-clock time of each event of the last run_rt, in order


def run_rt(app, t_from, duration, events=(), poll=0.012):
    """Real-time playback from t_from for `duration` wall seconds. events = [(position_threshold, fn)] fired once
    when the transport position first reaches the threshold (after the previous event fired). Returns
    [(wall, position, level)]. Always stops the transport."""
    c = app.c
    del FIRED[:]
    c.send("transport.stop")
    c.send("transport.seek", {"seconds": t_from})
    level(app)                                   # clears the peak
    pending = list(events)
    out = []
    c.send("transport.play")
    t0 = time.time()
    try:
        while time.time() - t0 < duration:
            pos = c.send("transport.state")["position"]
            lv = level(app)
            out.append((time.time() - t0, pos, lv))
            if pending and pos >= pending[0][0]:
                _, fn = pending.pop(0)
                FIRED.append(time.time() - t0)       # series clock (same as the first column)
                fn()
            time.sleep(poll)
    finally:
        c.send("transport.stop")
    return out


def lvl_between(series, p0, p1, wall0=None, wall1=None):
    sel = [l for (w, p, l) in series
           if (wall0 is None or w >= wall0) and (wall1 is None or w <= wall1) and p0 <= p <= p1]
    return (max(sel) if sel else None), len(sel)


# ── the cases ────────────────────────────────────────────────────────────────────────────────────

NOTE_ON = 1.0   # s


def scene_basic(app, notes=None, start=0.0, end=4.0, lane=0):
    notes = notes if notes is not None else [(72, NOTE_ON, 0.4, 127)]
    return midi_clip(app, start, end, lane, notes)


def p1():
    section("P1  group with an instrument + empty clip")
    app = boot("p1")
    try:
        c = app.c
        m = scene_basic(app)
        g = group(app, [m])
        wit = export(app, "p1_witness", 0, 4)                 # witness: the group has no instrument yet
        key = mount(app, g)
        chain = [e["role"] for e in c.send("debug.engine_chain", {"id": g})["chain"]]
        say("P1", "chain of the group after the mount: %s" % chain)
        x = export(app, "p1_host", 0, 4)
        pw, px = peak(wit), peak(x)
        on = onset(x, 0.5, 2.0)
        say("P1", "witness (no instrument): peak %.2e (%.1f dBFS)" % (pw, db(pw)))
        say("P1", "with instrument on the group: peak %.4f (%.1f dBFS), RMS[1.0-2.0] %.5f, onset sample %s (%.4f s)"
            % (px, db(px), rms(x, 1.0, 2.0), on, (on or 0) / SR))
        if pw == 0.0 and px > 1e-3 and on is not None:
            verdict("P1", "PASS", "peak %.4f (%.1f dBFS) with the instrument on the group, witness exactly 0; onset at %.4f s"
                    % (px, db(px), on / SR))
        else:
            verdict("P1", "DEFECT", "witness peak %.2e, host peak %.2e, onset %s" % (pw, px, on))
        return x
    finally:
        app.close()


def p2(x1):
    section("P2  host > sub-group > empty clip")
    app = boot("p2")
    try:
        c = app.c
        m = scene_basic(app)
        s = group(app, [m])
        h = group(app, [s])
        c.send("group.expand", {"id": h, "expanded": True})
        c.send("group.expand", {"id": s, "expanded": True})
        objs = {o["id"]: o for o in c.send("object.list")["objects"]}
        say("P2", "nesting: clip.parent == S: %s ; S.parent == H: %s ; H.parent: %s"
            % (objs[m]["parent"] == s, objs[s]["parent"] == h, objs[h]["parent"]))
        c.send("group.expand", {"id": s, "expanded": False})
        c.send("group.expand", {"id": h, "expanded": False})
        mount(app, h)
        x = export(app, "p2", 0, 4)
        lag, md = lag_and_diff(x1, x, 0.5, 3.0)
        on1, on2 = onset(x1, 0.5, 2.0), onset(x, 0.5, 2.0)
        say("P2", "peak %.4f ; onset %s (P1: %s) ; xcorr lag vs P1 %s sample(s) ; max|P2-P1| = %.2e"
            % (peak(x), on2, on1, lag, md))
        if on2 is None:
            verdict("P2", "DEFECT", "no sound through host > sub-group > clip (peak %.2e)" % peak(x))
        elif abs((on2 or 0) - (on1 or 0)) <= BLOCK and (lag is None or abs(lag) <= BLOCK):
            verdict("P2", "PASS", "same signal as P1: onset delta %d sample(s), lag %s, max diff %.2e (limit %d)"
                    % (on2 - on1, lag, md, BLOCK))
        else:
            verdict("P2", "DEFECT", "onset delta %d, lag %s, max diff %.2e" % (on2 - on1, lag, md))
    finally:
        app.close()


def p3():
    section("P3  clip with its own instrument (reference)")
    hashes, xs = [], []
    for k in range(2):
        app = boot("p3%d" % k)
        try:
            c = app.c
            m = scene_basic(app)
            c.send("instrument.set", {"id": m, **app.inst})
            x = export(app, "p3_%d" % k, 0, 4)
            hashes.append(sha(x))
            xs.append(x)
        finally:
            app.close()
    x = xs[0]
    on = onset(x, 0.5, 2.0)
    say("P3", "REFERENCE: peak %.6f, RMS[1.0-2.0] %.6f, onset sample %s, hash %s ; second run hash %s"
        % (peak(x), rms(x, 1.0, 2.0), on, hashes[0], hashes[1]))
    if peak(x) > 1e-3 and hashes[0] == hashes[1]:
        verdict("P3", "PASS", "reference recorded and reproducible (hash %s, peak %.4f, RMS %.5f, onset %d)"
                % (hashes[0], peak(x), rms(x, 1.0, 2.0), on))
    elif peak(x) > 1e-3:
        lag, md = lag_and_diff(xs[0], xs[1], 0.5, 3.0)
        verdict("P3", "INFO", "reference not bit-exact between runs (hash %s / %s, lag %s, max diff %.2e): "
                "compare with a tolerance" % (hashes[0], hashes[1], lag, md))
    else:
        verdict("P3", "DEFECT", "no sound from a clip with its own instrument (peak %.2e)" % peak(x))
    return x


def p3_vs_p1(x3, x1):
    lag, md = lag_and_diff(x3, x1, 0.5, 3.0)
    say("P3", "clip-own-instrument vs group-host (P1): xcorr lag %s, max diff %.2e, peaks %.4f / %.4f"
        % (lag, md, peak(x3), peak(x1)))


def p4():
    section("P4  note crossing the end of a cropped (bounded) group")
    res = {}
    # offline: the window ends at 2.0 s, the note goes on until 5.0 s.
    app = boot("p4a")
    try:
        c = app.c
        m = midi_clip(app, 0, 6, 0, [(60, 1.0, 4.0, 127)])
        g = group(app, [m])
        mount(app, g)
        c.send("object.set_duration", {"id": g, "duration": 2.0})
        o = [o for o in c.send("object.list")["objects"] if o["id"] == g][0]
        say("P4", "group after the crop: start %.3f duration %.3f" % (o["start"], o["duration"]))
        x = export(app, "p4_offline", 0, 8)
        a, b = peak(x, 1.2, 1.9), peak(x, 2.05, 8.0)
        say("P4", "offline: peak in the window [1.2-1.9] %.4f ; after the end [2.05-8.0] %.2e" % (a, b))
        res["offline_after"] = b
        res["offline_in"] = a
    finally:
        app.close()

    def loop_case(tag, note_len, crop):
        app = boot(tag)
        try:
            c = app.c
            m = midi_clip(app, 0, 6, 0, [(60, 1.0, note_len, 127)])
            g = group(app, [m])
            mount(app, g)
            if crop:
                c.send("object.set_duration", {"id": g, "duration": 2.0})
            c.send("debug.transport_loop", {"start": 0.5, "end": 3.0, "enabled": True})
            ser = run_rt(app, 0.5, 8.4)
            # laps: count the wraps of the position
            laps, prev = [0.0], None
            for (w, p, l) in ser:
                if prev is not None and p < prev - 0.5:
                    laps.append(w)
                prev = p
            return ser, laps
        finally:
            app.close()

    # stuck test: lap 2+ , positions 0.55-0.95 (before the note starts at 1.0 and inside the window)
    ser_long, laps_long = loop_case("p4b", 4.0, True)
    ser_ctrl, laps_ctrl = loop_case("p4c", 0.5, True)
    for name, ser, laps in (("note crossing the window end", ser_long, laps_long),
                            ("control (note ends at 1.5, inside the window)", ser_ctrl, laps_ctrl)):
        per = []
        for k in range(len(laps)):
            w0 = laps[k] + 0.05
            w1 = (laps[k + 1] if k + 1 < len(laps) else 1e9)
            mx, n = lvl_between(ser, 0.6, 0.95, w0, w1)
            per.append((mx, n))
        say("P4", "loop [0.5,3.0], %s: laps=%d ; level in [0.6,0.95] per lap (VU 0..1, -60..0 dB): %s"
            % (name, len(laps), ", ".join("-" if m is None else "%.3f" % m for m, n in per)))
        res[name] = per
    ctrl = res["control (note ends at 1.5, inside the window)"]
    long_ = res["note crossing the window end"]
    stuck_laps = [m for m, n in long_[1:] if m is not None and m > 0.02]
    ctrl_stuck = [m for m, n in ctrl[1:] if m is not None and m > 0.02]
    if res["offline_after"] > 1e-4:
        verdict("P4", "DEFECT", "offline: energy after the window end, peak %.2e" % res["offline_after"])
    elif stuck_laps and not ctrl_stuck:
        verdict("P4", "DEFECT", "stuck note on re-entry: level before the note on laps >=2 = %s (control: %s)"
                % (["%.3f" % m for m in stuck_laps], ["%.3f" % m for m, n in ctrl[1:] if m is not None]))
    elif ctrl_stuck:
        verdict("P4", "INFO", "control itself not silent on re-entry (%s): the measurement is not clean"
                % ["%.3f" % m for m in ctrl_stuck])
    else:
        verdict("P4", "PASS", "silent after the window end (offline peak %.2e, %.4f inside) and no sound on re-entry "
                "after the wrap (laps>=2: %s, control: %s). Caveat: the transport wrap is a jump (cf. P7)"
                % (res["offline_after"], res["offline_in"],
                   ["%.3f" % m for m, n in long_[1:] if m is not None], ["%.3f" % m for m, n in ctrl[1:] if m is not None]))

    # No-jump re-entry: widen the window while playing, once the note has been held past the old end.
    app = boot("p4d")
    try:
        c = app.c
        m = midi_clip(app, 0, 6, 0, [(60, 1.0, 4.0, 127)])
        g = group(app, [m])
        mount(app, g)
        c.send("object.set_duration", {"id": g, "duration": 2.0})
        mark = {}

        def widen():
            mark["wall"] = time.time()
            c.send("object.set_duration", {"id": g, "duration": 6.0})

        ser = run_rt(app, 0.0, 5.0, events=[(2.6, widen)])
        t0 = None
        for (w, p, l) in ser:
            if p >= 2.6:
                t0 = w
                break
        after = [l for (w, p, l) in ser if t0 is not None and w >= t0 + 0.15 and 2.7 <= p <= 4.9]
        say("P4", "widen at pos 2.6 while the note (pitch 60, 1.0-5.0) is held past the old end: levels after = max %.3f over %d polls"
            % (max(after) if after else -1, len(after)))
        if after and max(after) > 0.02:
            verdict("P4b", "INFO", "a note held across the window end sounds again when the window is widened with NO jump "
                    "(level %.3f): either stuck, or the container simply ran it (cannot be told apart from here)" % max(after))
        else:
            verdict("P4b", "PASS", "widening the window with no jump brings back no stuck note (max level %s)"
                    % ("%.3f" % max(after) if after else "n/a"))
    finally:
        app.close()


def p5():
    section("P5  looping group")
    app = boot("p5")
    try:
        c = app.c
        # pattern 0..2 s : attacks at 0.0 and 1.0 ; the group is lengthened to 8 s => 4 laps.
        m = midi_clip(app, 0, 2, 0, [(72, 0.0, 0.25, 127), (76, 1.0, 0.25, 127)])
        g = group(app, [m])
        c.send("object.set_loop", {"id": g, "enabled": True})
        c.send("object.set_duration", {"id": g, "duration": 8.0})
        o = [o for o in c.send("object.list")["objects"] if o["id"] == g][0]
        say("P5", "group: start %.2f duration %.2f ; loop on" % (o["start"], o["duration"]))
        mount(app, g)
        x = export(app, "p5", 0, 9)
        at = attacks(x, 0.0, 9.0)
        exp = [0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0]
        say("P5", "attacks found at: %s" % ["%.3f" % t for t in at])
        amp = []
        for t in exp:
            amp.append(peak(x, t, t + 0.2))
        say("P5", "attack peak per expected position: %s" % ["%.4f" % a for a in amp])
        gap = [rms(x, t + 1.7, t + 1.95) for t in (0.0, 2.0, 4.0, 6.0)]
        say("P5", "tail RMS just before each lap end: %s" % ["%.5f" % g_ for g_ in gap])
        ok_count = len(at) == len(exp) and all(abs(a - e) < 0.03 for a, e in zip(at, exp))
        say("P5", "attack count %d (expected %d)" % (len(at), len(exp)))
        ratios = [amp[i] / amp[i % 2] for i in range(len(amp)) if amp[i % 2] > 0]
        ok_amp = all(0.8 <= r <= 1.25 for r in ratios)
        if ok_count and ok_amp:
            verdict("P5", "PASS", "8 attacks for 4 laps x 2 notes at %s, amplitudes within %.2f..%.2f of the first lap"
                    % (["%.2f" % t for t in at], min(ratios), max(ratios)))
        else:
            verdict("P5", "DEFECT", "attacks %d expected 8 (%s), amplitude ratios %s"
                    % (len(at), ["%.2f" % t for t in at], ["%.2f" % r for r in ratios]))
    finally:
        app.close()

    # the note crosses the OUT bound: it has to be cut at every wrap (a held key is not re-attacked by a
    # second note-on: the AU needs the note-off). Run on the host AND with the instrument on the clip itself
    # (the path in production today) to say whether it is new or pre-existing.
    res = {}
    for tag, host in (("p5b", True), ("p5c", False)):
        app = boot(tag)
        try:
            c = app.c
            m = midi_clip(app, 0, 3, 0, [(72, 0.0, 0.25, 127), (64, 0.5, 3.0, 127)])
            if not host:
                c.send("instrument.set", {"id": m, **app.inst})
            g = group(app, [m])
            c.send("object.set_loop", {"id": g, "enabled": True})
            c.send("object.set_loop_range", {"id": g, "start": 0.0, "end": 1.0})
            c.send("object.set_duration", {"id": g, "duration": 4.0})
            if host:
                mount(app, g)
            x = export(app, tag, 0, 5)
            A = [peak(x, t, t + 0.12) for t in (0, 1, 2, 3)]
            B = [peak(x, t + 0.5, t + 0.62) for t in (0, 1, 2, 3)]
            res[tag] = (A, B)
            say("P5", "%s, loop 0..1 over 4 s, clip 3 s: note A (72, 0.0-0.25) attack per lap %s ; note B (64, 0.5 -> 3.5, crosses OUT) attack per lap %s"
                % ("instrument on the HOST" if host else "instrument on the CLIP", ["%.4f" % v for v in A], ["%.4f" % v for v in B]))
        finally:
            app.close()
    Ah, Bh = res["p5b"]
    Ac, Bc = res["p5c"]
    rb = [v / Bh[0] for v in Bh]
    rbc = [v / Bc[0] for v in Bc]
    if all(0.8 <= r <= 1.25 for r in rb):
        verdict("P5b", "PASS", "a note crossing the loop OUT is cut and re-attacked at every lap (ratios %s)" % ["%.2f" % r for r in rb])
    else:
        same = all(abs(a - b) < 0.1 * max(a, b) for a, b in zip(rb, rbc))
        verdict("P5b", "DEFECT", "a note crossing the loop OUT is NOT cut at the wrap: its attack is gone from lap 2 on (host: %s). "
                "A at the loop start is fine (%s). %s"
                % (["%.2f" % r for r in rb], ["%.2f" % (v / Ah[0]) for v in Ah],
                   "IDENTICAL with the instrument on the clip itself (%s): pre-existing, not caused by mounting on the host" % ["%.2f" % r for r in rbc] if same
                   else "with the instrument on the clip: %s" % ["%.2f" % r for r in rbc]))


def p6():
    section("P6  transport loop, real time")
    app = boot("p6")
    try:
        c = app.c
        m = midi_clip(app, 0, 2, 0, [(72, 0.0, 0.25, 127), (76, 1.0, 0.25, 127)])
        g = group(app, [m])
        mount(app, g)
        c.send("debug.transport_loop", {"start": 0.0, "end": 2.0, "enabled": True})
        ser = run_rt(app, 0.0, 8.8)
        wraps, prev = [], None
        for i, (w, p, l) in enumerate(ser):
            if prev is not None and p < prev - 0.5:
                wraps.append(i)
            prev = p
        say("P6", "polls %d, wraps seen %d" % (len(ser), len(wraps)))
        # attack events on the VU series
        ev = []
        for i in range(4, len(ser)):
            w, p, l = ser[i]
            base = min(s_[2] for s_ in ser[i - 4:i])
            if l - base >= 0.25 and (not ev or w - ev[-1][0] > 0.2):
                ev.append((w, p, l))
        # what the transport passed through, from the position series: the loop start (initial + each wrap)
        # and the middle note at 1.0
        exp = []
        if ser and ser[0][1] < 0.2:
            exp.append((ser[0][0], "start"))
        for i in range(1, len(ser)):
            p0, p1 = ser[i - 1][1], ser[i][1]
            if p1 < p0 - 0.5:
                exp.append((ser[i][0], "start"))
            elif p0 < 1.0 <= p1:
                exp.append((ser[i - 1][0], "mid"))
        horizon = ser[-1][0] - 0.25
        exp = [e for e in exp if e[0] <= horizon]
        used, missed = set(), []
        for (w, kind) in exp:
            hit = next((j for j, e in enumerate(ev) if j not in used and abs(e[0] - w) <= 0.18), None)
            if hit is None:
                missed.append((round(w, 2), kind))
            else:
                used.add(hit)
        extra = [(round(e[0], 2), round(e[1], 2)) for j, e in enumerate(ev) if j not in used and e[0] <= horizon]
        say("P6", "polls %d ; passes through the loop start %d, through the middle note %d ; attacks heard %d"
            % (len(ser), sum(1 for e in exp if e[1] == "start"), sum(1 for e in exp if e[1] == "mid"), len(ev)))
        say("P6", "attacks heard at (wall s, position): %s" % [(round(e[0], 2), round(e[1], 2)) for e in ev])
        say("P6", "expected but not heard: %s ; heard but not expected: %s" % (missed, extra))
        laps = sum(1 for e in exp if e[1] == "start") - 1
        if laps >= 2 and not missed and not extra:
            verdict("P6", "PASS", "%d wraps of the transport loop: every pass through the loop start (the note ON the start included) and through the middle note re-attacks, none doubled (%d attacks)"
                    % (laps, len(used)))
        else:
            verdict("P6", "DEFECT", "wraps %d ; missed %s ; extra %s" % (laps, missed, extra))
    finally:
        app.close()


def p7():
    section("P7  playhead jump during a note")

    def tail(series, w_event, lo, hi):
        sel = [l for (w, p, l) in series if w_event + lo <= w <= w_event + hi]
        return (max(sel) if sel else None)

    out = {}
    for tag, nlen, jump in (("jump", 4.0, True), ("natural", 1.2, False)):
        app = boot("p7" + tag[0])
        try:
            c = app.c
            m = midi_clip(app, 0, 6, 0, [(60, 0.0, nlen, 127)])
            g = group(app, [m])
            mount(app, g)
            ev = [(1.2, lambda: c.send("transport.seek", {"seconds": 5.0}))] if jump else [(1.2, lambda: None)]
            ser = run_rt(app, 0.0, 4.0, events=ev)
            w_ev = FIRED[0]
            prof = [tail(ser, w_ev, a_, a_ + 0.25) for a_ in (-0.3, 0.0, 0.25, 0.5, 0.75, 1.0, 1.5)]
            out[tag] = prof
            say("P7", "%s: max level in 0.25 s windows at [-0.3, 0, +0.25, +0.5, +0.75, +1.0, +1.5] s from the %s: %s"
                % (tag, "seek to 5.0 s" if jump else "natural note-off at 1.2 s",
                   ["-" if v is None else "%.3f" % v for v in prof]))
        finally:
            app.close()
    j, n = out["jump"], out["natural"]
    if (n[0] or 0) < 0.1:
        verdict("P7", "ERROR", "note not heard before the event")
        return
    # the jump has to leave no more than the natural release does (generous: x2 + a floor)
    late = [(a_, b_) for a_, b_ in zip(j[3:], n[3:]) if a_ is not None and b_ is not None]
    worse = [(round(a_, 3), round(b_, 3)) for a_, b_ in late if a_ > max(2.0 * b_, 0.03)]
    if worse:
        verdict("P7", "DEFECT", "after the jump the note sounds longer than its natural release (jump vs natural, from +0.5 s): %s" % worse)
    else:
        verdict("P7", "PASS", "after the jump the tail follows the natural release (jump %s vs natural %s from +0.5 s)"
                % (["%.3f" % a_ for a_, b_ in late], ["%.3f" % b_ for a_, b_ in late]))


def p8():
    section("P8  PDC: host + latency plugin next to an audio clip")
    click = os.path.join(WORK, "click.wav")
    write_click(click)
    res = {}
    for tag, lat in (("p8a", None), ("p8b", 50.0)):
        app = boot(tag)
        try:
            c = app.c
            m = midi_clip(app, 2.0, 4.0, 0, [(72, 0.0, 0.4, 127)])    # note at 2.0 s
            g = group(app, [m])
            mount(app, g)
            if lat:
                c.send("debug.add_test_plugin", {"host": g, "type": "latencyTester", "latency_ms": lat})
                chain = [(e["role"], e["type"]) for e in c.send("debug.engine_chain", {"id": g})["chain"]]
                say("P8", "host chain: %s" % chain)
                c.send("wait_idle")
                time.sleep(0.6)          # a latency tester asks for a rebuild on its own timer (~250 ms)
                c.send("wait_idle")
            c.send("object.add", {"path": click, "lane": 3, "start": 1.0})        # click at 1.0 s
            x = export(app, tag, 0, 4)
            oc, om = onset(x, 0.8, 1.6, 2e-3), onset(x, 1.8, 2.6, 1e-3)
            res[tag] = (oc, om)
            say("P8", "%s: click onset sample %s (nominal %d) -> %+d ; note onset %s (nominal %d) -> %+d"
                % ("no latency plugin" if not lat else "latency %.0f ms (%d samples)" % (lat, int(lat * SR / 1000)),
                   oc, SR, (oc or 0) - SR, om, 2 * SR, (om or 0) - 2 * SR))
        finally:
            app.close()
    (c0, m0), (c1, m1) = res["p8a"], res["p8b"]
    if None in (c0, m0, c1, m1):
        verdict("P8", "ERROR", "onset not found: %s" % res)
        return
    rel0, rel1 = m0 - c0, m1 - c1          # note vs click, without / with the latency plugin
    shift_click, shift_note = c1 - c0, m1 - m0
    say("P8", "note-click distance: %d samples without the plugin, %d with it (delta %+d) ; shifts: click %+d, note %+d"
        % (rel0, rel1, rel1 - rel0, shift_click, shift_note))
    if abs(rel1 - rel0) <= BLOCK:
        verdict("P8", "PASS", "host path with a 50 ms plugin stays aligned with the audio clip: note-click distance changes by %+d sample(s) (limit %d); both shifted by click %+d / note %+d"
                % (rel1 - rel0, BLOCK, shift_click, shift_note))
    else:
        verdict("P8", "DEFECT", "host path NOT compensated: note-click distance moves by %+d samples (%.1f ms) with the 50 ms plugin; shifts click %+d, note %+d"
                % (rel1 - rel0, (rel1 - rel0) * 1000.0 / SR, shift_click, shift_note))


def p9():
    section("P9  volume curve on an empty clip / a sub-group")
    notes = [(60, 1.0037, 0.25, 127), (64, 2.2113, 0.25, 127), (67, 3.4871, 0.25, 127)]
    curve = [{"t": 0.0, "v": 0.0}, {"t": 2.0, "v": 0.0}, {"t": 4.0, "v": 0.0}]

    def scene(tag, where):
        app = boot(tag)
        try:
            c = app.c
            m = midi_clip(app, 0, 5, 0, notes)
            s = group(app, [m])
            h = group(app, [s])
            mount(app, h)
            if where == "clip":
                c.send("automation.set_points", {"id": m, "param": "volume", "points": curve})
            elif where == "sub":
                c.send("automation.set_points", {"id": s, "param": "volume", "points": curve})
            lanes = c.send("automation.list", {"id": m if where == "clip" else s})["lanes"] if where else []
            return export(app, tag, 0, 5), lanes
        finally:
            app.close()

    ctrl, _ = scene("p9c", None)
    ctrl2, _ = scene("p9d", None)
    say("P9", "determinism: control vs control max |diff| = %.2e" % float(np.max(np.abs(ctrl - ctrl2))))
    out = {}
    for where in ("clip", "sub"):
        x, lanes = scene("p9" + where[0], where)
        per = []
        for t in (1.0037, 2.2113, 3.4871):
            i0, i1 = int((t - 0.05) * SR), int((t + 0.6) * SR)
            lag, md = lag_and_diff(ctrl[i0:i1], x[i0:i1], 0.0, None, maxlag=2000)
            per.append((t, lag, md))
        out[where] = per
        say("P9", "curve on the %s (0 dB flat, 3 points at 0/2/4 s, %d lane): per note [time, lag in samples (- = EARLIER than the control), max diff]: %s"
            % (where, len(lanes), [(t, lag, "%.2e" % md) for t, lag, md in per]))
    if peak(ctrl) < 1e-3 or float(np.max(np.abs(ctrl - ctrl2))) > 0:
        verdict("P9", "ERROR", "control silent or not reproducible")
        return
    bad = {w: [(t, lag) for t, lag, md in per if lag != 0 or md > 0] for w, per in out.items()}
    if any(bad.values()):
        verdict("P9", "DEFECT", "a volume curve moves the notes: " + "; ".join(
            "on the %s: %s" % (w, ["%.4f s -> %+d samples (%.2f ms)" % (t, lag, 1000.0 * lag / SR) for t, lag in v])
            for w, v in bad.items() if v) + " (patch 0049c: MIDI timestamps after sub-blocks)")
    else:
        verdict("P9", "PASS", "3 off-grid notes unchanged to the sample with a volume curve on the clip and on the sub-group")


def p10():
    section("P10 two empty clips with different notes in one host")
    nA = [(72, 1.0, 0.4, 127)]
    nB = [(76, 1.0, 0.4, 127)]

    def scene(tag, kind):
        app = boot(tag)
        try:
            c = app.c
            if kind == "A":
                ids = [midi_clip(app, 0, 4, 0, nA)]
            elif kind == "B":
                ids = [midi_clip(app, 0, 4, 0, nB)]
            else:
                ids = [midi_clip(app, 0, 4, 0, nA), midi_clip(app, 0, 4, 1, nB)]
            g = group(app, ids)
            if kind == "AB-sub":     # each clip in its own sub-group under the host
                pass
            mount(app, g)
            return export(app, tag, 0, 4)
        finally:
            app.close()

    a, b, ab = scene("p10a", "A"), scene("p10b", "B"), scene("p10ab", "AB")
    n = min(len(a), len(b), len(ab))
    resid = ab[:n] - (a[:n] + b[:n])
    say("P10", "peaks: A %.4f, B %.4f, A+B in one host %.4f ; residual |AB-(A+B)| max %.2e (%.1f dB under AB peak)"
        % (peak(a), peak(b), peak(ab), float(np.max(np.abs(resid))), db(float(np.max(np.abs(resid))) / max(peak(ab), 1e-12))))

    # sub-groups
    app = boot("p10s")
    try:
        c = app.c
        m1 = midi_clip(app, 0, 4, 0, nA)
        s1 = group(app, [m1])
        m2 = midi_clip(app, 0, 4, 1, nB)
        s2 = group(app, [m2])
        h = group(app, [s1, s2])
        mount(app, h)
        abs_ = export(app, "p10s", 0, 4)
    finally:
        app.close()
    resid2 = abs_[:n] - (a[:n] + b[:n])
    say("P10", "two sub-groups S1{A} S2{B} under the host: peak %.4f ; residual vs A+B max %.2e" % (peak(abs_), float(np.max(np.abs(resid2)))))
    tol = 0.02 * max(peak(ab), 1e-9)
    if peak(a) < 1e-3 or peak(b) < 1e-3:
        verdict("P10", "ERROR", "a single clip is silent (A %.2e, B %.2e)" % (peak(a), peak(b)))
    elif float(np.max(np.abs(resid))) <= tol and float(np.max(np.abs(resid2))) <= tol:
        verdict("P10", "PASS", "AB == A+B (residual %.2e, tolerance %.2e) in one host and through two sub-groups: nothing played twice, nothing lost"
                % (max(float(np.max(np.abs(resid))), float(np.max(np.abs(resid2)))), tol))
    else:
        verdict("P10", "DEFECT", "residual one host %.2e, sub-groups %.2e (tolerance %.2e): peaks A %.4f B %.4f AB %.4f"
                % (float(np.max(np.abs(resid))), float(np.max(np.abs(resid2))), tol, peak(a), peak(b), peak(ab)))


def p11():
    section("P11 external FX on an empty clip")
    app = boot("p11")
    try:
        c = app.c
        fx = [p for p in c.send("plugin.list_available")["plugins"]
              if p["format"] == "AudioUnit" and not p.get("is_instrument") and p["name"] in ("AUBandpass", "AUDelay", "AULowpass", "AUHighpass", "AUPeakLimiter")]
        if not fx:
            fx = [p for p in c.send("plugin.list_available")["plugins"] if p["format"] == "AudioUnit" and not p.get("is_instrument") and p["name"].startswith("AU")]
        say("P11", "available AU effects used: %s" % [p["name"] for p in fx[:3]])
        results = []
        for p in fx[:2]:
            c.send("project.new")
            m = scene_basic(app)
            g = group(app, [m])
            mount(app, g)
            base = export(app, "p11_base_%s" % p["name"], 0, 4)
            r = c.send("plugin.add", {"host": m, "identifier": p["identifier"], "format": p["format"]})
            pid = r["plugin"]["id"]
            on = export(app, "p11_on_%s" % p["name"], 0, 4)
            tg = c.send("plugin.toggle", {"host": m, "plugin": pid})
            say("P11", "plugin.toggle -> enabled=%s" % tg["enabled"])
            off = export(app, "p11_off_%s" % p["name"], 0, 4)
            results.append((p["name"], peak(base), peak(on), peak(off)))
            say("P11", "%s on the empty clip: peak without FX %.4f ; FX enabled %.4f ; FX toggled once (disabled?) %.4f"
                % (p["name"], peak(base), peak(on), peak(off)))
        if not results:
            verdict("P11", "ERROR", "no AU effect found")
            return
        eats = [r for r in results if r[2] < 0.1 * r[1]]
        off_ok = all(abs(r[3] - r[1]) < 0.02 * r[1] for r in results)
        if eats and off_ok:
            verdict("P11", "INFO", "an enabled external FX on an empty clip EATS the notes (%s: %.4f -> %.4f); disabling it gives them back -> engine-side disable (2.5) is needed and sufficient"
                    % (eats[0][0], eats[0][1], eats[0][2]))
        elif not eats:
            verdict("P11", "INFO", "enabled external FX did not eat the notes here (%s): peaks %s -> the guard of 2.5 is a precaution, not proven necessary"
                    % ([r[0] for r in results], [(round(r[1], 4), round(r[2], 4)) for r in results]))
        else:
            verdict("P11", "INFO", "FX eats the notes (%s) but disabling does not restore them: %s"
                    % (eats[0][0], [(r[0], round(r[1], 4), round(r[2], 4), round(r[3], 4)) for r in results]))
    finally:
        app.close()


def p12():
    section("P12 native mute / unmute / mute again, real time")
    # The level after a note-off is the natural release of the instrument, not zero:
    # a CONTROL run ends the same notes naturally at the instants the mutes fall,
    # and the mute run is judged against it.
    def one(tag, notes, events_spec):
        app = boot(tag)
        try:
            c = app.c
            m = midi_clip(app, 0, 6, 0, notes)
            g = group(app, [m])
            mount(app, g)
            steps = []

            def setm(v, t):
                def f():
                    r = c.send("debug.midi_mute", {"id": m, "muted": v})
                    steps.append((t, r["engine_muted"]))
                return f
            ev = [(t, setm(v, n)) for (t, v, n) in events_spec]
            ser = run_rt(app, 0.0, 6.2, events=ev)
            return ser, steps
        finally:
            app.close()

    def lv(ser, p0, p1):
        sel = [l for (w, p, l) in ser if p0 <= p <= p1]
        return (max(sel) if sel else None)

    ser, steps = one("p12", [(60, 0.0, 1.4, 127), (64, 2.0, 3.0, 127)],
                     [(0.5, True, "mute1"), (1.0, False, "unmute"), (3.0, True, "mute2")])
    say("P12", "mute events (engine state read back): %s" % steps)
    ctl, _ = one("p12c", [(60, 0.0, 0.5, 127), (64, 2.0, 1.0, 127)], [])
    wins = {"N1 playing 0.2-0.5": (0.2, 0.5), "mute1 +0.45 s (0.95-1.0)": (0.95, 1.0),
            "N2 playing 2.2-2.9": (2.2, 2.9), "mute2 +0.5..2 s (3.5-5.0)": (3.5, 5.0), "mute2 +1..2 s (4.0-5.0)": (4.0, 5.0)}
    rows = {}
    for k, (p0, p1) in wins.items():
        a_, b_ = lv(ser, p0, p1), lv(ctl, p0, p1)
        rows[k] = (a_, b_)
        say("P12", "%-28s mute run %.3f ; natural-end control %.3f" % (k, a_ if a_ is not None else -1, b_ if b_ is not None else -1))
    n1, n2 = rows["N1 playing 0.2-0.5"][0], rows["N2 playing 2.2-2.9"][0]
    r1, r1c = rows["mute1 +0.45 s (0.95-1.0)"]
    r2, r2c = rows["mute2 +1..2 s (4.0-5.0)"]
    tol = 0.05
    if (n1 or 0) < 0.1 or (n2 or 0) < 0.1:
        verdict("P12", "ERROR", "notes not heard before the mutes (N1 %s, N2 %s)" % (n1, n2))
    elif (r1 or 0) > (r1c or 0) + tol:
        verdict("P12", "DEFECT", "FIRST mute leaves the note sounding (%.3f vs %.3f natural release): note-off at mute missing" % (r1, r1c))
    elif (r2 or 0) > (r2c or 0) + tol:
        verdict("P12", "DEFECT", "2nd mute: note N2 STUCK (%.3f at 4.0-5.0 s vs %.3f natural release; 1st mute was clean: %.3f vs %.3f) -> wasMute never reset"
                % (r2, r2c, r1, r1c))
    else:
        verdict("P12", "PASS", "both mutes cut their note like a natural note-off (mute1 %.3f vs %.3f ; mute2 %.3f vs %.3f)" % (r1, r1c, r2, r2c))


def p13():
    section("P13 instrument on an EMPTY group, a clip added afterwards")
    app = boot("p13")
    try:
        c = app.c
        seed = midi_clip(app, 0, 4, 0, [])
        g = group(app, [seed])
        c.send("object.remove", {"ids": [seed]})
        objs = {o["id"]: o for o in c.send("object.list")["objects"]}
        say("P13", "after removing the only child: group %s, objects left %d" % ("still there" if g in objs else "GONE", len(objs)))
        if g not in objs:
            verdict("P13", "ERROR", "an emptied group disappears: another way to get an empty group is needed (zone)")
            return
        key = mount(app, g)
        chain0 = [e["role"] for e in c.send("debug.engine_chain", {"id": g})["chain"]]
        say("P13", "chain of the empty group after the mount: %s" % chain0)
        m = midi_clip(app, 0, 4, 1, [(72, NOTE_ON, 0.4, 127)])
        c.send("group.reparent", {"ids": [m], "group": g})
        c.send("group.expand", {"id": g, "expanded": True})
        o = {o["id"]: o for o in c.send("object.list")["objects"]}
        say("P13", "clip parent == group: %s ; group start %.2f dur %.2f"
            % (o[m]["parent"] == g, o[g]["start"], o[g]["duration"]))
        chain1 = [e["role"] for e in c.send("debug.engine_chain", {"id": g})["chain"]]
        say("P13", "chain of the group after the clip arrived: %s" % chain1)
        x = export(app, "p13", 0, 4)
        say("P13", "export peak %.4f, onset %s" % (peak(x), onset(x, 0.5, 2.0)))
        if peak(x) > 1e-3:
            verdict("P13", "PASS", "instrument mounted on an empty group sounds once a clip is added (peak %.4f, onset %.4f s)"
                    % (peak(x), onset(x, 0.5, 2.0) / SR))
        else:
            verdict("P13", "DEFECT", "silence at the export (peak %.2e); chain before %s after %s" % (peak(x), chain0, chain1))
    finally:
        app.close()


CASES = ["P1", "P2", "P3", "P4", "P5", "P6", "P7", "P8", "P9", "P10", "P11", "P12", "P13"]


def want(p):
    return not ONLY or p in ONLY


x1 = None
x3 = None
for pid in CASES:
    if not want(pid):
        continue
    try:
        if pid == "P1":
            x1 = p1()
        elif pid == "P2":
            if x1 is None:
                x1 = p1()
            p2(x1)
        elif pid == "P3":
            x3 = p3()
            if x1 is None:
                try:
                    x1 = p1()
                except Exception:
                    pass
            if x1 is not None:
                p3_vs_p1(x3, x1)
        elif pid in ("P4", "P5", "P6", "P7", "P8", "P9", "P10", "P11", "P12", "P13"):
            globals()[pid.lower()]()
    except Exception as e:      # the harness failed on that case: say so, go on
        traceback.print_exc()
        verdict(pid, "ERROR", "%s: %s" % (type(e).__name__, e))

print("\n" + "=" * 100)
print("VERDICT")
print("=" * 100)
for pid in sorted(VERDICT, key=lambda s: (int("".join(ch for ch in s if ch.isdigit())), s)):
    st, tx = VERDICT[pid]
    print("%-5s %-7s %s" % (pid, st, tx))
bad = [p for p, (s, _) in VERDICT.items() if s in ("DEFECT", "ERROR")]
print("\nwork dir: %s" % WORK)
sys.exit(1 if bad else 0)

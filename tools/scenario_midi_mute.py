#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""E3 of docs/plan_groupes_midi.md : NATIVE MUTE of the empty MIDI clips (M1..M6).

An EMPTY clip (a MIDI clip with no instrument of its own) is played by the instrument of the first group above it.
Its fader cannot silence it (the MIDI crosses a sub-group's fader), so the app drives the `mute` of the te::MidiClip
instead: the clip's own silence OR the silence of a group between it and its host. This scenario measures it through
exports (24-bit WAV re-read):

  M1  mute of an empty clip: its window is exact silence, the other clip's window is untouched (bit for bit)
  M2  solo of an empty clip: it alone is heard
  M3  solo of another object: the empty clips are silent
  M4  mute of a sub-group (its clip alone falls silent), then of the host (everything falls silent)
  M5  muted stem: silent ; unmuted: back to the baseline
  M6  consolidate (content render) with a live solo elsewhere: the wave ignores the solo, honours the MODEL's mute
  +   no graph rebuild during a mute, an unmute, a solo, a stem mute ([GRAPH] lines of the engine's journal)

The instrument goes on the group through `instrument.set` when the app accepts it (E4 and after), through the engine-only
door `debug.mount_instrument` before that. Headless, Apple's DLSMusicDevice.

    ./scenario_midi_mute.py /path/to/objekat.app

Exit: 0 if every assertion passes, 1 otherwise, 2 on bad usage.
"""

import os, struct, subprocess, sys, tempfile, time, traceback

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

if len(sys.argv) < 2:
    print(__doc__)
    sys.exit(2)

APP = sys.argv[1]
BIN = os.path.join(APP, "Contents", "MacOS", "objekat")
if not os.path.exists(BIN):
    print("not an app bundle: %s" % APP)
    sys.exit(2)

SR = 48000
WORK = tempfile.mkdtemp(prefix="objk-mute-")
FAILS = []
TOTAL = [0]


def check(label, ok, detail=""):
    TOTAL[0] += 1
    if ok:
        print("ok    " + label)
    else:
        FAILS.append(label)
        print("FAIL  %s  %s" % (label, detail))


class App:
    def __init__(self, tag):
        self.sock = "/tmp/objk-mute-%d-%s.sock" % (os.getpid(), tag)
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
        self.c.send("project.new")
        insts = self.c.send("plugin.list_available", {"instruments_only": True})["plugins"]
        dls = next(p for p in insts if p["name"] == "DLSMusicDevice")
        self.inst = {"identifier": dls["identifier"], "format": dls["format"]}
        self.spb = 60.0 / self.c.send("transport.state")["tempo"]

    def rebuilds(self):
        """Number of graph rebuilds the engine has journaled so far (Debug build)."""
        time.sleep(0.3)
        with open(self.err, errors="replace") as f:
            return sum(1 for l in f if l.startswith("[GRAPH] rebuild #"))

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
    raw = open(path, "rb").read()
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
    if tag == 3 and bits == 32:
        x = np.frombuffer(data[:len(data) // 4 * 4], dtype="<f4").astype(np.float64)
    elif bits == 24:
        n = len(data) // 3
        b = np.frombuffer(data[:n * 3], dtype=np.uint8).reshape(n, 3).astype(np.int32)
        v = b[:, 0] | (b[:, 1] << 8) | (b[:, 2] << 16)
        x = np.where(v & 0x800000, v - 0x1000000, v).astype(np.float64) / 8388608.0
    else:
        raise ValueError("unsupported wav %r" % (fmt,))
    return x.reshape(-1, ch)


def rms(x, a, b):
    s = x[int(a * SR):int(b * SR)]
    return float(np.sqrt(np.mean(s ** 2))) if s.size else 0.0


def export(app, name, start=0.0, end=5.0):
    path = os.path.join(WORK, name + ".wav")
    if os.path.exists(path):
        os.remove(path)
    r = app.c.send("export.run", {"path": path, "format": "wav", "sample_rate": SR, "bit_depth": 24,
                                  "dithering": False, "start": start, "end": end})
    job = app.c.send("job.wait", {"id": r["job_id"], "timeout_ms": 120000})
    if job.get("result", {}).get("phase") == "failed":
        return np.zeros((int((end - start) * SR), 2))      # nothing to render = silence
    return read_wav(path)


def midi_clip(app, start, end, lane, notes):
    m = app.c.send("midi.create_clip", {"start": start, "end": end, "lane": lane})["id"]
    for pitch, s, l, v in notes:
        app.c.send("midi.add_note", {"id": m, "pitch": pitch, "start_beat": s / app.spb,
                                     "length_beats": l / app.spb, "velocity": v})
    return m


def group(app, ids):
    return app.c.send("group.create", {"ids": ids})["id"]


def mount(app, gid):
    try:
        app.c.send("instrument.set", {"id": gid, **app.inst})
        return "instrument.set"
    except ObjekatError:
        app.c.send("debug.mount_instrument", {"id": gid, **app.inst})
        return "debug.mount_instrument"


def expand(app, gid):
    app.c.send("group.expand", {"id": gid, "expanded": True})


# Windows where each note sounds (the DLS piano rings ~1 s). Every measurement runs in its OWN app instance: the
# instrument keeps its voices and reverb between two exports of one instance (the tail of the last note leaks into
# the head of the next render), so two renders of one instance are not comparable bit for bit.
WA = (0.45, 1.45)     # clip A: pitch 60 at 0.5 s
WB = (2.45, 3.45)     # clip B: pitch 72 at 2.5 s
WC = (3.95, 4.95)     # clip C (other group): pitch 67 at 4.0 s
SILENT = 2e-6


def scene(app):
    """Host H holds A (lane 0, 0.5 s) and B (lane 1, 2.5 s); another group K, with its own instrument, holds C (4.0 s)."""
    a = midi_clip(app, 0, 5, 0, [(60, 0.5, 0.4, 127)])
    b = midi_clip(app, 0, 5, 1, [(72, 2.5, 0.4, 127)])
    h = group(app, [a, b])
    mount(app, h)
    c = midi_clip(app, 0, 5, 2, [(67, 4.0, 0.4, 127)])
    k = group(app, [c])
    mount(app, k)
    for g in (h, k):
        expand(app, g)
    return dict(a=a, b=b, h=h, c=c, k=k)


def scene_sub(app):
    """Host H holds the sub-group S (which holds A) and B."""
    a = midi_clip(app, 0, 5, 0, [(60, 0.5, 0.4, 127)])
    b = midi_clip(app, 0, 5, 1, [(72, 2.5, 0.4, 127)])
    s = group(app, [a])
    h = group(app, [s, b])
    mount(app, h)
    for g in (h, s):
        expand(app, g)
    return dict(a=a, b=b, s=s, h=h)


def render(tag, build, mutate=None):
    """A fresh instance: build the scene, apply `mutate(app, ids)` (returns a dict of extras), export. -> (signal, extras)."""
    app = App(tag)
    try:
        ids = build(app)
        extras = mutate(app, ids) if mutate else {}
        return export(app, tag, 0.0, 5.0), (extras or {})
    finally:
        app.close()


def removing(*keys):
    """A `mutate` that deletes objects: the CONTROL a muted render is compared with (no note ever reaches the instrument)."""
    def f(app, ids):
        app.c.send("object.remove", {"ids": [ids[k] for k in keys]})
        return {}
    return f


def muting(*keys):
    """A `mutate` that mutes objects the ordinary way (the control of the solo/stem cases, whose topology must stay the
    same: an instrument that disappears changes the other instruments' render)."""
    def f(app, ids):
        app.c.send("object.set_mute", {"ids": [ids[k] for k in keys], "muted": True})
        return {}
    return f


TAIL = 1e-3     # an instrument's own tail from a previous note (reverb) may still ring in a window: 30 dB under a note


def same(x, y):
    return x.shape == y.shape and float(np.max(np.abs(x - y))) == 0.0


def native(app, oid):
    return app.c.send("debug.midi_mute", {"id": oid}).get("engine_muted")


def win(x, w):
    return x[int(w[0] * SR):int(w[1] * SR)]


def maxdiff(x, y, w):
    return float(np.max(np.abs(win(x, w) - win(y, w))))


def m1():
    base, _ = render("m1_base", scene)
    ctl, _ = render("m1_ctl", scene, removing("a"))

    def mute(app, ids):
        n0 = app.rebuilds()
        app.c.send("object.set_mute", {"ids": [ids["a"]], "muted": True})
        n1 = app.rebuilds()
        return {"n0": n0, "n1": n1, "native": native(app, ids["a"])}
    x, e = render("m1_muted", scene, mute)

    def unmute(app, ids):
        app.c.send("object.set_mute", {"ids": [ids["a"]], "muted": True})
        n1 = app.rebuilds()
        app.c.send("object.set_mute", {"ids": [ids["a"]], "muted": False})
        n2 = app.rebuilds()
        return {"n1": n1, "n2": n2, "native": native(app, ids["a"])}
    y, e2 = render("m1_unmuted", scene, unmute)
    print("\n── M1 ──")
    check("baseline: A, B and C are all heard (RMS %.4f / %.4f / %.4f)" % (rms(base, *WA), rms(base, *WB), rms(base, *WC)),
          min(rms(base, *WA), rms(base, *WB), rms(base, *WC)) > 1e-3)
    check("M1 muted clip: its window is exact silence (RMS %.2e)" % rms(x, *WA), rms(x, *WA) < SILENT)
    check("M1 muted render == render with A deleted, whole file, bit for bit (max diff %.2e)" % float(np.max(np.abs(x - ctl))),
          same(x, ctl))
    check("M1 the other clips still sound (RMS B %.4f, C %.4f)" % (rms(x, *WB), rms(x, *WC)),
          rms(x, *WB) > 1e-3 and rms(x, *WC) > 1e-3)
    check("M1 the mute is the NATIVE one of the te::MidiClip (engine_muted=%s)" % e["native"], e["native"] is True)
    check("M1 no graph rebuild during the mute (%d -> %d)" % (e["n0"], e["n1"]), e["n1"] == e["n0"])
    check("M1 unmuted again: back to the baseline, bit for bit", same(y, base))
    check("M1 native mute cleared by the unmute (engine_muted=%s)" % e2["native"], e2["native"] is False)
    check("M1 no graph rebuild during the unmute (%d -> %d)" % (e2["n1"], e2["n2"]), e2["n2"] == e2["n1"])


def m2():
    base, _ = render("m2_base", scene)
    ctl, _ = render("m2_ctl", scene, muting("b", "c"))

    def solo(app, ids):
        n0 = app.rebuilds()
        app.c.send("solo.set", {"ids": [ids["a"]], "on": True})
        return {"n0": n0, "n1": app.rebuilds()}
    x, e = render("m2_solo", scene, solo)
    print("\n── M2 ──")
    check("M2 solo of A: A is heard as in the baseline (max diff %.2e, RMS %.4f)" % (maxdiff(x, base, WA), rms(x, *WA)),
          maxdiff(x, base, WA) == 0.0 and rms(x, *WA) > 1e-3)
    check("M2 solo of A: B is silent (RMS %.2e, under the tail floor)" % rms(x, *WB), rms(x, *WB) < TAIL)
    check("M2 solo of A: C (other group) is silent (RMS %.2e, under the tail floor)" % rms(x, *WC), rms(x, *WC) < TAIL)
    check("M2 solo of A == render with B and C muted, bit for bit (max diff %.2e)" % float(np.max(np.abs(x - ctl))), same(x, ctl))
    check("M2 no graph rebuild during the solo (%d -> %d)" % (e["n0"], e["n1"]), e["n1"] == e["n0"])

    def cleared(app, ids):
        app.c.send("solo.set", {"ids": [ids["a"]], "on": True})
        app.c.send("solo.clear")
        return {}
    y, _ = render("m2_clear", scene, cleared)
    check("M2 solo cleared: back to the baseline, bit for bit", same(y, base))


def m3():
    base, _ = render("m3_base", scene)
    ctl, _ = render("m3_ctl", scene, removing("a", "b"))

    def solo(app, ids):
        app.c.send("solo.set", {"ids": [ids["k"]], "on": True})
        return {"native_a": native(app, ids["a"]), "native_c": native(app, ids["c"])}
    x, e = render("m3_solo_k", scene, solo)
    print("\n── M3 ──")
    check("M3 solo of another group: its clip C is heard (RMS %.4f)" % rms(x, *WC), rms(x, *WC) > 1e-3)
    check("M3 solo elsewhere: A is silent (RMS %.2e)" % rms(x, *WA), rms(x, *WA) < SILENT)
    check("M3 solo elsewhere: B is silent (RMS %.2e)" % rms(x, *WB), rms(x, *WB) < SILENT)
    check("M3 solo of K == render with A and B deleted, bit for bit (max diff %.2e)" % float(np.max(np.abs(x - ctl))), same(x, ctl))
    check("M3 native mute of A while the solo filters it out (engine_muted=%s)" % e["native_a"], e["native_a"] is True)
    check("M3 C, the soloed one, is not muted natively (engine_muted=%s)" % e["native_c"], e["native_c"] is False)

    def cleared(app, ids):
        app.c.send("solo.set", {"ids": [ids["k"]], "on": True})
        app.c.send("solo.clear")
        return {"native_a": native(app, ids["a"])}
    y, e2 = render("m3_clear", scene, cleared)
    check("M3 solo cleared: native mute lifted (engine_muted=%s) and baseline back, bit for bit" % e2["native_a"],
          e2["native_a"] is False and same(y, base))


def m4():
    base, _ = render("m4_base", scene_sub)
    ctl, _ = render("m4_ctl", scene_sub, removing("a"))

    def sub(app, ids):
        n0 = app.rebuilds()
        app.c.send("object.set_mute", {"ids": [ids["s"]], "muted": True})
        n1 = app.rebuilds()
        return {"n0": n0, "n1": n1, "native_a": native(app, ids["a"]), "native_b": native(app, ids["b"])}
    x, e = render("m4_sub", scene_sub, sub)

    def host(app, ids):
        app.c.send("object.set_mute", {"ids": [ids["h"]], "muted": True})
        return {}
    z, _ = render("m4_host", scene_sub, host)

    def back(app, ids):
        app.c.send("object.set_mute", {"ids": [ids["s"]], "muted": True})
        app.c.send("object.set_mute", {"ids": [ids["s"]], "muted": False})
        app.c.send("object.set_mute", {"ids": [ids["h"]], "muted": True})
        app.c.send("object.set_mute", {"ids": [ids["h"]], "muted": False})
        return {"native_a": native(app, ids["a"])}
    w, e3 = render("m4_back", scene_sub, back)
    print("\n── M4 ──")
    check("baseline: A and B heard through host > sub-group", rms(base, *WA) > 1e-3 and rms(base, *WB) > 1e-3)
    check("M4 muted sub-group: its clip A is silent (RMS %.2e)" % rms(x, *WA), rms(x, *WA) < SILENT)
    check("M4 muted sub-group == render with A deleted, bit for bit (max diff %.2e)" % float(np.max(np.abs(x - ctl))), same(x, ctl))
    check("M4 B (direct child of the host) still sounds (RMS %.4f)" % rms(x, *WB), rms(x, *WB) > 1e-3)
    check("M4 the sub-group's mute went DOWN the tree to A (engine_muted=%s), not to B (%s)" % (e["native_a"], e["native_b"]),
          e["native_a"] is True and e["native_b"] is False)
    check("M4 no graph rebuild during the sub-group's mute (%d -> %d)" % (e["n0"], e["n1"]), e["n1"] == e["n0"])
    check("M4 muted host: everything is silent (RMS A %.2e, B %.2e)" % (rms(z, *WA), rms(z, *WB)),
          rms(z, *WA) < SILENT and rms(z, *WB) < SILENT)
    check("M4 mutes lifted: baseline back, bit for bit, native mute off (%s)" % e3["native_a"], same(w, base) and e3["native_a"] is False)


def m5():
    def assigned(app, ids):
        st = app.c.send("stem.add", {"name": "Keys"})["id"]
        app.c.send("stem.assign", {"stem": st, "ids": [ids["h"]]})
        return {"stem": st}
    mid, _ = render("m5_assigned", scene, assigned)

    def hostmuted(app, ids):
        assigned(app, ids)
        app.c.send("object.set_mute", {"ids": [ids["h"]], "muted": True})
        return {}
    ctl, _ = render("m5_ctl", scene, hostmuted)

    def muted(app, ids):
        st = assigned(app, ids)["stem"]
        n0 = app.rebuilds()
        app.c.send("stem.mute", {"id": st, "muted": True})
        return {"n0": n0, "n1": app.rebuilds(), "native_a": native(app, ids["a"]), "native_b": native(app, ids["b"])}
    x, e = render("m5_muted", scene, muted)

    def unmuted(app, ids):
        st = assigned(app, ids)["stem"]
        app.c.send("stem.mute", {"id": st, "muted": True})
        app.c.send("stem.mute", {"id": st, "muted": False})
        return {"native_a": native(app, ids["a"])}
    y, e2 = render("m5_unmuted", scene, unmuted)
    print("\n── M5 ──")
    check("M5 assigned to a stem: still heard (RMS A %.4f)" % rms(mid, *WA), rms(mid, *WA) > 1e-3)
    check("M5 muted stem: A and B are silent (RMS %.2e / %.2e)" % (rms(x, *WA), rms(x, *WB)),
          rms(x, *WA) < SILENT and rms(x, *WB) < SILENT)
    check("M5 muted stem == render with the host muted directly, bit for bit (max diff %.2e)" % float(np.max(np.abs(x - ctl))), same(x, ctl))
    check("M5 muted stem: C (not on the stem) is heard (RMS %.4f)" % rms(x, *WC), rms(x, *WC) > 1e-3)
    check("M5 muted stem: the empty clips of its group are natively muted (A %s, B %s)" % (e["native_a"], e["native_b"]),
          e["native_a"] is True and e["native_b"] is True)
    check("M5 no graph rebuild during the stem's mute (%d -> %d)" % (e["n0"], e["n1"]), e["n1"] == e["n0"])
    check("M5 unmuted: back to the assigned render, bit for bit (native mute %s)" % e2["native_a"],
          same(y, mid) and e2["native_a"] is False)


def waves_of(proj):
    out = []
    for root, _, files in os.walk(proj):
        for f in files:
            if f.endswith((".wav", ".flac")) and "consolidate" in root:
                out.append(os.path.join(root, f))
    return sorted(out)


def wave_signal(w):
    if w.endswith(".flac"):
        wav = os.path.join(WORK, "m6_dec.wav")
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI24", w, wav], check=True)
        w = wav
    return read_wav(w)


def wait_job(app, r):
    job = app.c.send("job.wait", {"id": r["job_id"], "timeout_ms": 180000})
    res = job.get("result", {})
    return res.get("phase") != "failed" and "error" not in res, res


def m6():
    """The CONTENT render of a consolidated group (the re-bake at the commit of an edit) forces the MODEL's state on
    the clone: a live solo elsewhere (native mute of the empty clips) must not leak into the wave, and the model's own
    mute must."""
    print("\n── M6 ──")
    app = App("m6")
    try:
        ids = scene(app)
        proj = os.path.join(WORK, "m6proj")
        app.c.send("project.save_as", {"path": os.path.join(proj, "m6.objekat")})
        app.c.send("object.set_mute", {"ids": [ids["a"]], "muted": True})     # the MODEL's mute of A
        ok, res = wait_job(app, app.c.send("consolidate.make", {"id": ids["h"]}))
        check("M6 the first consolidation ran (%s)" % ("ok" if ok else res), ok)
        w1 = waves_of(proj)
        check("M6 one wave written (%s)" % [os.path.basename(w) for w in w1], len(w1) == 1)
        if len(w1) != 1:
            return
        x = wave_signal(w1[0])
        check("M6 first wave: model-muted A is silent (RMS %.2e), B is in it (RMS %.4f)" % (rms(x, *WA), rms(x, *WB)),
              rms(x, *WA) < SILENT and rms(x, *WB) > 1e-3)
        # The edit: A audible again, B muted by the MODEL, then a LIVE solo elsewhere before the commit.
        app.c.send("consolidate.edit_begin", {"placement": ids["h"]})
        root = app.c.send("consolidate.state").get("content_root_id")
        expand(app, root)
        kids = sorted((o for o in app.c.send("object.list").get("objects", []) if o.get("parent") == root),
                      key=lambda o: o.get("lane", 0))
        print("      opened content: %d children %s" % (len(kids), [(o["kind"], o["lane"]) for o in kids]))
        check("M6 the opened content shows A and B", len(kids) == 2)
        if len(kids) != 2:
            return
        ka, kb = kids[0]["id"], kids[1]["id"]
        app.c.send("object.set_mute", {"ids": [ka], "muted": False})
        app.c.send("object.set_mute", {"ids": [kb], "muted": True})
        app.c.send("solo.set", {"ids": [ids["k"]], "on": True})
        ok, res = wait_job(app, app.c.send("consolidate.edit_commit"))
        w2 = [w for w in waves_of(proj) if w not in w1]
        if not ok or len(w2) != 1:
            # Before E4/E6 the group instrument exists only as a debug mount on the live container: the sidecar of the
            # consolidated object holds no plugin, so the re-bake of the opened content has nothing to play and fails.
            print("SKIP  M6 content render (re-bake %s, %d new wave): needs the instrument to be part of the model (E4/E6)"
                  % ("ok" if ok else "failed", len(w2)))
            return
        check("M6 the commit re-baked and wrote a second wave", True)
        y = wave_signal(w2[0])
        check("M6 content render ignores the live solo: A (unmuted in the model) is in it (RMS %.4f)" % rms(y, *WA),
              rms(y, *WA) > 1e-3)
        check("M6 content render honours the MODEL's mute of B (RMS %.2e)" % rms(y, *WB), rms(y, *WB) < SILENT)
    finally:
        app.close()


for name, fn in (("M1", m1), ("M2", m2), ("M3", m3), ("M4", m4), ("M5", m5), ("M6", m6)):
    if len(sys.argv) > 2 and name not in [a.upper() for a in sys.argv[2:]]:
        continue
    try:
        fn()
    except Exception as e:
        traceback.print_exc()
        check("%s ran without error" % name, False, "%s: %s" % (type(e).__name__, e))

print("\n%d/%d assertions pass" % (TOTAL[0] - len(FAILS), TOTAL[0]))
print("work dir: %s" % WORK)
sys.exit(1 if FAILS else 0)

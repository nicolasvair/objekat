#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Breath evaluation, app side (@see plan_eval_respirations.md, T2) — driven headless.

Section (a) — THE ONE-SAMPLE HOLE AFTER A CUT. A clip is cut at instants whose position in
samples has a fractional part of 0.1 / 0.3 / 0.49 / 0.5 / 0.7, and the group rendered after
`object.explode` is compared to the render of the original object. Before the object window
counted samples like the clip does (`OBJWindowFadePlugin.h`), a fractional part in (0 ; 0.5)
left ONE sample at exactly floor(c·sr) at zero — the clip A had stopped playing it, the
window of B had already killed it.

    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --socket=/tmp/o.sock
    ./scenario_breath_eval.py /tmp/o.sock

Exit: 0 if every assertion passes, 1 otherwise.
"""

import math
import os
import shutil
import struct
import sys
import tempfile
import wave

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

if len(sys.argv) != 2:
    print(__doc__)
    sys.exit(2)

SOCK = sys.argv[1]
fails = []
roots = []


def check(label, ok, detail=""):
    if ok:
        print("ok    " + label)
    else:
        fails.append(label)
        print("FAIL  %s  %s" % (label, detail))


def tmproot(tag):
    folder = tempfile.mkdtemp(prefix="objekat-breath-%s-" % tag)
    roots.append(folder)
    return os.path.realpath(folder)


def make_wav(path, seconds, rate):
    """24-bit mono, a sine RIDING ON A DC OFFSET so that no sample is ever near zero: a zero in
    the render can then only be a sample somebody killed."""
    frames = int(round(seconds * rate))
    raw = bytearray()
    for i in range(frames):
        v = 0.30 + 0.15 * math.sin(2 * math.pi * 220.0 * i / rate)
        raw += struct.pack("<i", int(v * (2 ** 23 - 1)))[0:3]
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(3)
        w.setframerate(rate)
        w.writeframes(bytes(raw))
    return path


def read_wav_24(path):
    """Channel 0 only, one value per FRAME (the export is stereo)."""
    with wave.open(path, "rb") as w:
        n = w.getnframes()
        ch = w.getnchannels()
        raw = w.readframes(n)
    out = []
    step = 3 * ch
    for i in range(0, len(raw) - step + 1, step):
        chunk = raw[i:i + 3] + (b"\xff" if raw[i + 2] >= 0x80 else b"\x00")
        out.append(struct.unpack("<i", chunk)[0])
    return out


def cleanup():
    for r in roots:
        shutil.rmtree(r, ignore_errors=True)


def section_a(c, rate):
    """One object, one cut per fractional part."""
    ROOT = tmproot("a%d" % rate)
    WAV = make_wav(os.path.join(ROOT, "tone.wav"), 3.0, rate)
    fracs = [0.1, 0.3, 0.49, 0.55, 0.7]   # 0.5 exactly is a float tie, @see plan Écarts
    for frac in fracs:
        c.send("project.new")
        c.send("project.save_as", {"path": os.path.join(ROOT, "s%s.objekat" % frac)})
        a = c.send("object.add", {"path": WAV, "lane": 0, "start": 1.0})["id"]
        o = c.send("object.get", {"id": a})
        start, dur = o["start"], o["duration"]
        # a cut at (K + frac) samples from the timeline's origin, K well inside the clip
        K = int(round((start + dur / 2) * rate))
        cut = (K + frac) / rate
        ref = os.path.join(ROOT, "ref-%s.wav" % frac)
        r = c.send("export.run", {"format": "wav", "sample_rate": rate, "bit_depth": 24,
                                  "start": start, "end": start + dur, "path": ref})
        c.send("job.wait", {"id": r["job_id"], "timeout_ms": 60000})
        c.send("object.explode", {"id": a, "cuts": [cut], "lanes": [0, 1]})
        out = os.path.join(ROOT, "cut-%s.wav" % frac)
        r = c.send("export.run", {"format": "wav", "sample_rate": rate, "bit_depth": 24,
                                  "start": start, "end": start + dur, "path": out})
        c.send("job.wait", {"id": r["job_id"], "timeout_ms": 60000})
        s0, s1 = read_wav_24(ref), read_wav_24(out)
        n = min(len(s0), len(s1))
        bad = [i for i in range(n) if abs(s0[i] - s1[i]) > 2 ** 23 * 1e-4]
        zeros = [i for i in bad if s1[i] == 0 and s0[i] != 0]
        expected = K - int(round(start * rate))   # index of floor(c·sr) in the render
        label = "a%d frac=%.2f" % (rate, frac)
        print("info  %s: %d bad samples at %s (floor(c·sr) is at %d), zeros %s"
              % (label, len(bad), bad[:6], expected, zeros[:6]))
        check("%s: no sample differs from the original" % label, len(bad) == 0, bad[:6])
        check("%s: no zeroed sample" % label, len(zeros) == 0, zeros[:6])


def expect_error(fn, code, label):
    try:
        fn()
        check(label, False, "it went through")
    except ObjekatError as e:
        check(label, e.code == code, "%s: %s" % (e.code, e.message))


def section_b(c):
    """The overlay layer: a model, a life, no trace in the project."""
    ROOT = tmproot("b")
    WAV = make_wav(os.path.join(ROOT, "tone.wav"), 3.0, 48000)
    c.send("project.new")
    a = c.send("object.add", {"path": WAV, "lane": 0, "start": 0.0})["id"]
    dirty0 = c.send("app.info").get("is_dirty")
    texts = [{"start": i * 0.0005, "end": i * 0.0005 + 0.0004, "text": "w%d" % i} for i in range(5000)]
    zones = [{"start": i * 0.05, "end": i * 0.05 + 0.02, "color": "red"} for i in range(50)]
    r = c.send("overlay.set", {"id": a, "texts": texts, "zones": zones})
    check("b: set counts", r["texts"] == 5000 and r["zones"] == 50, r)
    g = c.send("overlay.get", {"id": a})
    check("b: get counts", g["texts"] == 5000 and len(g["zones"]) == 50 and g["owner_is_caller"], g)
    r = c.send("overlay.set", {"id": a, "zones": zones[:10], "replace": ["zones"]})
    check("b: replace zones keeps texts", r["texts"] == 5000 and r["zones"] == 10, r)
    r = c.send("overlay.set", {"id": a, "replace": ["zones"]})
    check("b: replace with no value empties the field", r["zones"] == 0 and r["texts"] == 5000, r)
    check("b: the project is not dirtied", c.send("app.info").get("is_dirty") == dirty0)
    expect_error(lambda: c.send("overlay.set", {"id": "00000000-0000-0000-0000-000000000000",
                                                 "zones": []}), "not_found", "b: unknown object")
    expect_error(lambda: c.send("overlay.set", {"id": a, "zones": [{"start": 2, "end": 1}]}),
                 "bad_params", "b: start > end refused")
    expect_error(lambda: c.send("overlay.set", {"id": a, "zones": [{"start": 0, "end": 1, "color": "pink"}]}),
                 "bad_params", "b: unknown colour refused")
    big = [{"start": 0, "end": 0.1} for _ in range(20001)]
    expect_error(lambda: c.send("overlay.set", {"id": a, "zones": big}), "bad_params",
                 "b: more than 20000 elements refused")
    # undo does not touch the layer (nothing to undo: it is not an edit)
    c.send("object.set_fade", {"id": a, "in": 0.05, "out": 0.05})
    c.send("edit.undo")
    check("b: edit.undo leaves the layer", c.send("overlay.get", {"id": a})["texts"] == 5000)
    # the layer belongs to the connection
    with ObjekatClient(SOCK, timeout=60) as c2:
        b = c2.send("overlay.get", {"id": a})
        check("b: another connection is not the owner", b["owner_is_caller"] is False, b)
        c2.send("overlay.set", {"id": a, "zones": [{"start": 0, "end": 1}]})
    import time
    time.sleep(0.5)
    check("b: closing the owner's connection clears the layer",
          c.send("overlay.list")["overlays"] == [], c.send("overlay.list"))
    # an object that goes takes its layer along
    c.send("overlay.set", {"id": a, "zones": [{"start": 0, "end": 1}]})
    c.send("object.remove", {"ids": [a]})
    check("b: a removed object's layer is purged", c.send("overlay.list")["overlays"] == [])


CONTROLS = [
    {"id": "gap_on", "kind": "bool", "label": "Gap", "value": True},
    {"id": "gap", "kind": "number", "label": "Gap", "value": 120, "min": 40, "max": 400,
     "step": 10, "unit": "ms", "enabled_by": "gap_on"},
    {"id": "go", "kind": "button", "label": "Go"},
]


def section_c(c):
    """The panel: declared, read by long poll, driven by the hand's door."""
    import threading
    import time
    ROOT = tmproot("c")
    WAV = make_wav(os.path.join(ROOT, "tone.wav"), 1.0, 48000)
    c.send("project.new")
    a = c.send("object.add", {"path": WAV, "lane": 0, "start": 0.0})["id"]
    dup = CONTROLS + [{"id": "gap", "kind": "bool", "label": "dup"}]
    expect_error(lambda: c.send("script.panel.open", {"title": "t", "controls": dup}),
                 "bad_params", "c: duplicate control id refused")
    bad = [{"id": "x", "kind": "number", "label": "x", "min": 5, "max": 5, "step": 1}]
    expect_error(lambda: c.send("script.panel.open", {"title": "t", "controls": bad}),
                 "bad_params", "c: min >= max refused")
    bad = [{"id": "x", "kind": "number", "label": "x", "min": 0, "max": 5, "step": 0}]
    expect_error(lambda: c.send("script.panel.open", {"title": "t", "controls": bad}),
                 "bad_params", "c: step <= 0 refused")
    bad = [{"id": "x", "kind": "number", "label": "x", "min": 0, "max": 5, "step": 1, "value": 9}]
    expect_error(lambda: c.send("script.panel.open", {"title": "t", "controls": bad}),
                 "bad_params", "c: value out of range refused")
    r = c.send("script.panel.open", {"title": "Eval", "controls": CONTROLS, "object": a,
                                     "status": "Analyse...", "busy": True})
    pid = r["panel_id"]
    check("c: open answers rev 0", r["rev"] == 0, r)
    g = c.send("script.panel.get", {"panel_id": pid})
    check("c: get: open, defaults", g["state"] == "open" and g["values"]["gap"] == 120
          and g["values"]["gap_on"] is True and g["status"] == "Analyse...", g)
    t0 = time.time()
    w = c.send("script.panel.wait", {"panel_id": pid, "since_rev": 0, "timeout_ms": 300})
    check("c: wait times out with rev unchanged", w["rev"] == 0 and w["state"] == "open"
          and time.time() - t0 >= 0.25, w)
    c.send("script.panel.update", {"panel_id": pid, "status": "42 breaths", "busy": False})
    w = c.send("script.panel.get", {"panel_id": pid})
    check("c: update never moves rev", w["rev"] == 0 and w["status"] == "42 breaths", w)
    # a second connection wakes the wait in flight
    # the wait runs on THIS connection's thread while another connection drives the hand
    def hand():
        time.sleep(0.4)
        with ObjekatClient(SOCK, timeout=30) as c2:
            c2.send("script.panel.input", {"panel_id": pid, "values": {"gap": 200}})
    th = threading.Thread(target=hand)
    th.start()
    t0 = time.time()
    w = c.send("script.panel.wait", {"panel_id": pid, "since_rev": 0, "timeout_ms": 5000})
    dt = time.time() - t0
    th.join()
    check("c: a wait is woken by input from another connection (rev+1, value)",
          w["rev"] == 1 and w["values"]["gap"] == 200 and 0.3 < dt < 2.0, (w, dt))
    c.send("script.panel.input", {"panel_id": pid, "press": "go"})
    w = c.send("script.panel.get", {"panel_id": pid})
    check("c: a button press is an event, read once", w["events"] == [{"button": "go"}], w)
    w = c.send("script.panel.get", {"panel_id": pid})
    check("c: events are emptied by the read", w["events"] == [], w)
    expect_error(lambda: c.send("script.panel.input", {"panel_id": pid, "values": {"nope": 1}}),
                 "bad_params", "c: input on an unknown control refused")
    c.send("script.panel.input", {"panel_id": pid, "values": {"gap": 9999}})
    check("c: a number is clamped to its range",
          c.send("script.panel.get", {"panel_id": pid})["values"]["gap"] == 400)
    check("c: list shows the panel", [p["panel_id"] for p in c.send("script.panel.list")["panels"]] == [pid])
    c.send("script.panel.input", {"panel_id": pid, "press": "cancel"})
    check("c: cancel -> state cancelled",
          c.send("script.panel.get", {"panel_id": pid})["state"] == "cancelled")
    # an object that goes closes its panel
    r = c.send("script.panel.open", {"title": "Eval", "controls": CONTROLS, "object": a})
    c.send("object.remove", {"ids": [a]})
    check("c: the object's removal closes the panel",
          c.send("script.panel.get", {"panel_id": r["panel_id"]})["state"] == "closed")
    # the connection's closing removes the panel
    with ObjekatClient(SOCK, timeout=30) as c3:
        c3.send("script.panel.open", {"title": "x", "controls": CONTROLS})
        check("c: visible from another connection", len(c.send("script.panel.list")["panels"]) >= 1)
    time.sleep(0.5)
    check("c: closing the owner's connection removes its panel",
          all(p["title"] != "x" for p in c.send("script.panel.list")["panels"]),
          c.send("script.panel.list"))


try:
    with ObjekatClient(SOCK, timeout=180) as c:
        c.send("app.set_dialog_policy", {"policy": "assume_yes"})
        section_a(c, 48000)
        section_a(c, 44100)
        section_b(c)
        section_c(c)
finally:
    cleanup()

print()
if fails:
    print("%d FAILED" % len(fails))
    sys.exit(1)
print("ALL PASS")

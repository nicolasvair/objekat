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
import subprocess
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


def forget_remembered(c):
    """The script's panel remembers what was validated (`remember`), and these sections expect its
    DECLARED values: open its key, press Reset (which erases the entry), close."""
    pid = c.send("script.panel.open", {"title": "forget", "remember": "separateur-voix.eval",
                                       "controls": [{"id": "x", "kind": "bool", "label": "x"}]})["panel_id"]
    c.send("script.panel.input", {"panel_id": pid, "press": "reset"})
    c.send("script.panel.close", {"panel_id": pid})


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
    # ── the `choice` control ──
    opts = [{"id": "none", "label": "None"}, {"id": "w", "label": "Whisper"}, {"id": "p", "label": "Parakeet"}]
    for label, controls in (
            ("no options", [{"id": "m", "kind": "choice", "label": "m"}]),
            ("empty options", [{"id": "m", "kind": "choice", "label": "m", "options": []}]),
            ("an option with no label", [{"id": "m", "kind": "choice", "label": "m", "options": [{"id": "a"}]}]),
            ("duplicate option ids", [{"id": "m", "kind": "choice", "label": "m",
                                       "options": [{"id": "a", "label": "A"}, {"id": "a", "label": "B"}]}]),
            ("a value outside the options", [{"id": "m", "kind": "choice", "label": "m",
                                              "options": opts, "value": "zzz"}])):
        expect_error(lambda controls=controls: c.send("script.panel.open", {"title": "t", "controls": controls}),
                     "bad_params", "c: choice with %s refused" % label)
    r = c.send("script.panel.open", {"title": "Model", "controls": [
        {"id": "model", "kind": "choice", "label": "Text", "options": opts}]})
    cp = r["panel_id"]
    g = c.send("script.panel.get", {"panel_id": cp})
    check("c: a choice defaults to its first option and reads back as a string id",
          g["values"] == {"model": "none"}, g)
    c.send("script.panel.input", {"panel_id": cp, "values": {"model": "p"}})
    g = c.send("script.panel.get", {"panel_id": cp})
    check("c: input on a choice moves rev and stores the option id", g["rev"] == 1 and g["values"]["model"] == "p", g)
    expect_error(lambda: c.send("script.panel.input", {"panel_id": cp, "values": {"model": "nope"}}),
                 "bad_params", "c: input: an id that is not an option is refused")
    expect_error(lambda: c.send("script.panel.input", {"panel_id": cp, "values": {"model": 3}}),
                 "bad_params", "c: input: a choice is a string")
    c.send("script.panel.update", {"panel_id": cp, "values": {"model": "w"}})
    g = c.send("script.panel.get", {"panel_id": cp})
    check("c: update recalibrates a choice without moving rev", g["values"]["model"] == "w" and g["rev"] == 1, g)
    expect_error(lambda: c.send("script.panel.update", {"panel_id": cp, "values": {"model": "nope"}}),
                 "bad_params", "c: update: an unknown option is refused")
    c.send("script.panel.close", {"panel_id": cp})
    # ── the `progress` and `section` controls ──
    expect_error(lambda: c.send("script.panel.open", {"title": "t", "controls": [
        {"id": "p", "kind": "progress", "label": "p", "value": 1.5}]}), "bad_params",
        "c: a progress above 1 is refused")
    expect_error(lambda: c.send("script.panel.open", {"title": "t", "controls": [
        {"id": "p", "kind": "progress", "label": "p", "value": -0.1}]}), "bad_params",
        "c: a progress below 0 is refused")
    r = c.send("script.panel.open", {"title": "Prog", "controls": [
        {"id": "sec", "kind": "section", "label": "Common"},
        {"id": "p1", "kind": "progress", "label": "Analysing", "value": None},
        {"id": "p2", "kind": "progress", "label": "Idle"},
        {"id": "p3", "kind": "progress", "label": "Half", "value": 0.5},
        {"id": "b", "kind": "bool", "label": "b", "value": True}]})
    pp = r["panel_id"]
    g = c.send("script.panel.get", {"panel_id": pp})
    check("c: progress: null = indeterminate, absent = 0, a value kept; a section holds no value",
          g["values"] == {"p1": None, "p2": 0, "p3": 0.5, "b": True}, g["values"])
    c.send("script.panel.update", {"panel_id": pp, "values": {"p1": 0.25, "p2": 7, "p3": None},
                                   "labels": {"p1": "Transcribing", "sec": "Renamed"}})
    g = c.send("script.panel.get", {"panel_id": pp})
    check("c: update moves a progress (clamped to 1, null = indeterminate) and never moves rev",
          g["values"]["p1"] == 0.25 and g["values"]["p2"] == 1 and g["values"]["p3"] is None and g["rev"] == 0,
          g)
    expect_error(lambda: c.send("script.panel.update", {"panel_id": pp, "values": {"p1": "half"}}),
                 "bad_params", "c: update: a progress is a number or null")
    expect_error(lambda: c.send("script.panel.update", {"panel_id": pp, "values": {"sec": 1}}),
                 "bad_params", "c: update: a section holds no value")
    expect_error(lambda: c.send("script.panel.update", {"panel_id": pp, "labels": {"nope": "x"}}),
                 "bad_params", "c: update: labels name a known control")
    expect_error(lambda: c.send("script.panel.update", {"panel_id": pp, "labels": {"p1": 3}}),
                 "bad_params", "c: update: a label is a string")
    expect_error(lambda: c.send("script.panel.input", {"panel_id": pp, "values": {"p1": 0.9}}),
                 "bad_params", "c: input: the hand cannot set a progress bar")
    c.send("script.panel.close", {"panel_id": pp})
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


VENV_PY = os.path.expanduser(
    "~/Library/Application Support/Objekat/venvs/separateur-voix/bin/python3")
SCRIPT_DIR = os.path.join(HERE, "scripts", "separateur-voix")


def make_voice_wav(path):
    """The synthetic voice of test_detect.py (vowels, one breath, two 's', one 'ch') as a 24-bit
    mono wav — written by the script's own venv, which has numpy and soundfile."""
    code = ("import sys; sys.path.insert(0, %r); import soundfile as sf, test_detect as t; "
            "sf.write(%r, t.make_signal(), t.SR, subtype='PCM_24')" % (SCRIPT_DIR, path))
    subprocess.run([VENV_PY, "-c", code], check=True)
    return path


def wait_for(fn, label, timeout=30.0, step=0.1):
    import time
    end = time.time() + timeout
    last = None
    while time.time() < end:
        try:
            last = fn()
            if last:
                return last
        except ObjekatError as e:
            last = e
        time.sleep(step)
    check(label, False, "timed out; last = %r" % (last,))
    return None


PANEL_IDS = {
    "model", "progress", "group_lanes", "fade_ms", "language",
    "b_on", "b_unvoiced_on", "b_unvoiced", "b_below_speech_on", "b_below_speech", "b_cutoff",
    "b_min_len_on", "b_min_len", "b_fill_on", "b_fill", "b_text_on", "b_tolerance",
    "s_fill_on", "s_fill", "s_text_on", "s_tolerance",
    "s_on", "s_unvoiced_on", "s_unvoiced", "s_hf_ratio_on", "s_hf_ratio", "s_zcr_on", "s_zcr",
    "s_hf_energy_on", "s_hf_energy", "s_min_len_on", "s_min_len", "s_refine_on", "s_refine"}


def make_burst_wav(path):
    """Two 5-9 kHz noise bursts with a 30 ms hole of room tone between them (0.80-0.90, 0.93-1.03), a
    vowel-like buzz on either side — what the hole filling has to be seen bridging in the overlay."""
    code = ("import numpy as np, soundfile as sf\n"
            "sr=48000; rng=np.random.default_rng(3); n=int(2.0*sr); t=np.arange(n)/sr\n"
            "x=0.3*10**(-55/20)*rng.standard_normal(n)\n"
            "v=sum((1/k)*np.sin(2*np.pi*140*k*t) for k in range(1,6))*0.08\n"
            "for a,b in ((0.2,0.75),(1.1,1.7)): i,j=int(a*sr),int(b*sr); x[i:j]+=v[i:j]\n"
            "def burst(a,b):\n"
            "    m=int((b-a)*sr); z=rng.standard_normal(m); f=np.fft.rfft(z); fr=np.fft.rfftfreq(m,1/sr)\n"
            "    f[(fr<5000)|(fr>9000)]=0; z=np.fft.irfft(f,m); z=z/np.abs(z).max()*0.28\n"
            "    w=np.ones(m); e=int(m*0.03); w[:e]=np.linspace(0,1,e); w[-e:]=np.linspace(1,0,e)\n"
            "    x[int(a*sr):int(a*sr)+m]+=z*w\n"
            "burst(0.80,0.90); burst(0.93,1.03)\n"
            "sf.write(%r, x, sr, subtype='PCM_24')\n" % path)
    subprocess.run([VENV_PY, "-c", code], check=True)
    return path


def section_d(c):
    """End to end: the script, its panel, its overlay, the cut."""
    import time
    if not os.path.exists(VENV_PY):
        print("skip  d: the script's venv is not installed (%s)" % VENV_PY)
        return
    ROOT = tmproot("d")
    WAV = make_voice_wav(os.path.join(ROOT, "voice.wav"))
    BURST = make_burst_wav(os.path.join(ROOT, "burst.wav"))
    c.send("project.new")
    a = c.send("object.add", {"path": WAV, "lane": 2, "start": 0.0})["id"]

    def launch(obj=None, extra=()):
        forget_remembered(c)
        env = dict(os.environ, OBJEKAT_SOCKET=SOCK, OBJEKAT_LANGUAGE="en",
                   OBJEKAT_SEPARATEUR_CACHE=os.path.join(ROOT, "cache"))
        return subprocess.Popen([os.path.join(SCRIPT_DIR, "run.sh"), "--eval-separation", "--object", obj or a,
                                 *extra], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def panels():
        return [p for p in c.send("script.panel.list")["panels"] if p["state"] == "open"]

    def overlay(obj=None):
        try:
            return c.send("overlay.get", {"id": obj or a})
        except ObjekatError:
            return {"zones": [], "texts": 0, "rev": -1}

    def zones(color=None, obj=None):
        return [z for z in overlay(obj)["zones"] if color is None or z["color"] == color]

    def settle(pid, obj=None):
        """Waits for the script to have answered the last input: the overlay rev stops moving."""
        time.sleep(0.5)
        r = overlay(obj)["rev"]
        for _ in range(20):
            time.sleep(0.15)
            r2 = overlay(obj)["rev"]
            if r2 == r:
                return r2
            r = r2
        return r

    def press(pid, values=None, button=None):
        args = {"panel_id": pid}
        if values:
            args["values"] = values
        if button:
            args["press"] = button
        c.send("script.panel.input", args)

    # ── the panel, and both categories on the overlay ──
    proc = launch(extra=("--no-asr",))
    got = wait_for(panels, "d: the script opens its panel")
    pid = got[0]["panel_id"] if got else None
    wait_for(lambda: zones(), "d: the script lays zones over the object")
    if pid:
        g0 = c.send("script.panel.get", {"panel_id": pid})
        v = g0["values"]
        check("d: the panel carries the model, progress, breath block and consonant block controls — and nothing else",
              set(v) == PANEL_IDS, sorted(set(v) ^ PANEL_IDS))
        check("d: 'create groups' is ON by default, the spoken language is one of fr / en / es",
              v["group_lanes"] in (True, 1) and v["language"] in ("fr", "en", "es"), v)
        check("d: 'fade between pieces' is offered, 5 ms by default",
              v["fade_ms"] == 5, v.get("fade_ms"))
        check("d: defaults: model none (--no-asr), breaths 0.4 / 10 dB / 200 Hz / 120 ms, hole 20 ms, text 500 ms",
              (v["model"], v["b_unvoiced"], v["b_below_speech"], v["b_cutoff"], v["b_min_len"], v["b_fill"],
               v["b_tolerance"]) == ("none", 0.4, 10, 200, 120, 20, 100), v)
        check("d: the consonant block owns its own hole filling and tolerance (20 ms / 100 ms), no shared control",
              (v["s_fill"], v["s_tolerance"], v["s_text_on"], v["b_text_on"]) == (20, 100, True, True), v)
        check("d: defaults: SS/CH hf/lf -6 dB, zcr 0.12, HF +10 dB, 30 ms, 12 dB, 'not voiced' off",
              (v["s_hf_ratio"], v["s_zcr"], v["s_hf_energy"], v["s_min_len"], v["s_refine"],
               v["s_unvoiced_on"]) == (-6, 0.12, 10, 30, 12, False), v)
        check("d: the analysis finished: progress 1.0, labelled",
              v["progress"] == 1.0, v["progress"])
        white, yellow = zones("white"), zones("yellow")
        check("d: breaths are WHITE and SS/CH YELLOW on the overlay (%d / %d zones)" % (len(white), len(yellow)),
              len(white) >= 1 and len(yellow) == 3, [(z["color"], round(z["start"], 2)) for z in zones()])
        check("d: the status line counts both categories",
              "breath" in g0["status"] and "consonant" in g0["status"], g0["status"])
        # switching a category off takes its zones off, the other stays
        r0 = overlay()["rev"]
        press(pid, {"s_on": False})
        wait_for(lambda: overlay()["rev"] > r0, "d: a setting re-runs the mask")
        check("d: SS/CH off -> no yellow zone, breaths untouched",
              zones("yellow") == [] and len(zones("white")) == len(white))
        press(pid, {"s_on": True, "b_on": False})
        settle(pid)
        check("d: breaths off -> no white zone, SS/CH back", zones("white") == [] and len(zones("yellow")) == 3)
        press(pid, {"b_on": True})
        settle(pid)
        # the priority: with the breath criteria loosened to cover everything, SS/CH still owns its stretch
        press(pid, {"b_unvoiced_on": False, "b_below_speech_on": False, "b_min_len_on": False})
        settle(pid)
        ys, ws = zones("yellow"), zones("white")
        overlap = any(y["start"] < w["end"] - 1e-6 and w["start"] < y["end"] - 1e-6 for y in ys for w in ws)
        check("d: overlapping categories: SS/CH wins, no zone overlaps another", len(ys) == 3 and not overlap)
        press(pid, {"b_unvoiced_on": True, "b_below_speech_on": True, "b_min_len_on": True})
        # the cutoff and a range: a value out of range is clamped by the app
        press(pid, {"b_cutoff": 5000})
        check("d: the breath cutoff is clamped to 1000 Hz",
              c.send("script.panel.get", {"panel_id": pid})["values"]["b_cutoff"] == 1000)
        press(pid, {"b_cutoff": 200})
        # a model that is not installed says so, and the panel stays alive
        press(pid, {"model": "parakeet"})
        wait_for(lambda: ("not installed" in c.send("script.panel.get", {"panel_id": pid})["status"])
                 or (overlay()["texts"] > 0),
                 "d: an absent model says 'not installed' in the status line (or, installed, shows words)")
        press(pid, {"model": "none"})
        wait_for(lambda: overlay()["texts"] == 0, "d: 'None' clears the words")
        settle(pid)
        press(pid, button="validate")
    rc = proc.wait(timeout=60)
    check("d: the script exits 0 after Validate", rc == 0, proc.stderr.read().decode()[-400:])
    time.sleep(0.3)
    objs = c.send("object.list")["objects"]
    groups = [o for o in objs if o.get("kind") == "group"]
    check("d: Validate cuts the object into a group", len(groups) == 1 and a not in [o["id"] for o in objs],
          [(o.get("kind"), o.get("name")) for o in objs])
    if groups:
        c.send("group.expand", {"id": groups[0]["id"], "expanded": True})
        kids = [o for o in c.send("object.list")["objects"] if o.get("parent") == groups[0]["id"]]
        check("d: three sub-lanes, named Voice / Breaths / Consonants",
              {k["lane"] for k in kids} == {0, 1, 2}
              and {k["name"] for k in kids} == {"Voice", "Breaths", "Consonants"}, [(k["lane"], k["name"]) for k in kids])
    check("d: overlay and panel gone", c.send("overlay.list")["overlays"] == [] and panels() == [])
    c.send("edit.undo")
    objs = c.send("object.list")["objects"]
    check("d: one undo gives the original object back", [o["id"] for o in objs] == [a],
          [o["id"] for o in objs])

    # ── only the categories that are ON get a lane ──
    proc = launch(extra=("--no-asr",))
    got = wait_for(panels, "d: two-lane run: panel opens")
    wait_for(lambda: zones(), "d: two-lane run: zones")
    if got:
        press(got[0]["panel_id"], {"b_on": False})
        settle(got[0]["panel_id"])
        print("info  d: before validate: %s / zones %s" % (
            {k: v for k, v in c.send("script.panel.get", {"panel_id": got[0]["panel_id"]})["values"].items() if k in ("b_on", "s_on")},
            [(z["color"]) for z in zones()]))
        press(got[0]["panel_id"], button="validate")
    rc = proc.wait(timeout=60)
    time.sleep(0.3)
    groups = [o for o in c.send("object.list")["objects"] if o.get("kind") == "group"]
    if not groups:
        print("info  d: two-lane run exited %s: %s / objects %s" % (
            rc, proc.stderr.read().decode()[-400:],
            [(o.get("kind"), o.get("name")) for o in c.send("object.list")["objects"]]))
    if groups:
        c.send("group.expand", {"id": groups[0]["id"], "expanded": True})
        kids = [o for o in c.send("object.list")["objects"] if o.get("parent") == groups[0]["id"]]
        check("d: breaths off -> two sub-lanes, Voice / Consonants",
              {k["lane"] for k in kids} == {0, 1} and {k["name"] for k in kids} == {"Voice", "Consonants"},
              [(k["lane"], k["name"]) for k in kids])
    else:
        check("d: breaths off -> the object was cut", False)
    c.send("edit.undo")

    # ── THE HOLE FILLING, seen in the overlay ──
    b = c.send("object.add", {"path": BURST, "lane": 4, "start": 0.0})["id"]
    proc = launch(b, ("--no-asr",))
    got = wait_for(panels, "d: hole run: panel opens")
    wait_for(lambda: zones(obj=b), "d: hole run: zones", timeout=30)
    if got:
        pid = got[0]["panel_id"]
        press(pid, {"b_on": False, "s_fill_on": False})
        settle(pid, b)
        apart = zones("yellow", b)
        check("d: hole filling OFF: the two bursts (30 ms hole) are two zones: %s"
              % [(round(z['start'], 3), round(z['end'], 3)) for z in apart], len(apart) == 2, apart)
        press(pid, {"s_fill_on": True, "s_fill": 20})
        settle(pid, b)
        check("d: hole filling ON at 20 ms: the 30 ms hole stays open (2 zones)", len(zones("yellow", b)) == 2,
              zones("yellow", b))
        press(pid, {"s_fill": 40})
        settle(pid, b)
        joined = zones("yellow", b)
        check("d: hole filling at 40 ms: ONE zone, from the first burst to the second: %s"
              % [(round(z['start'], 3), round(z['end'], 3)) for z in joined],
              len(joined) == 1 and abs(joined[0]["start"] - 0.80) < 0.02 and abs(joined[0]["end"] - 1.03) < 0.02,
              joined)
        press(pid, button="cancel")
    proc.wait(timeout=60)
    c.send("object.remove", {"ids": [b]})

    # ── Cancel ──
    before = c.send("object.list")["objects"]
    proc = launch(extra=("--no-asr",))
    got = wait_for(panels, "d: cancel run: panel opens")
    if got:
        wait_for(lambda: zones(), "d: cancel run: zones")
        c.send("script.panel.input", {"panel_id": got[0]["panel_id"], "press": "cancel"})
    rc = proc.wait(timeout=60)
    time.sleep(0.3)
    check("d: Cancel exits 0 and leaves the project as it was",
          rc == 0 and c.send("object.list")["objects"] == before)
    check("d: Cancel leaves no overlay", c.send("overlay.list")["overlays"] == [])

    # ── The script is killed while its panel is open ──
    proc = launch(extra=("--no-asr",))
    got = wait_for(panels, "d: kill run: panel opens")
    wait_for(lambda: zones(), "d: kill run: zones")
    proc.kill()
    proc.wait()
    ok = wait_for(lambda: c.send("overlay.list")["overlays"] == [] and panels() == [],
                  "d: SIGKILL on the script clears its overlay and its panel", timeout=10)
    if ok:
        check("d: SIGKILL on the script clears its overlay and its panel", True)


def section_f(c):
    """A REAL voice (`say -v Thomas`, s / ch / z / j and two pauses) through the script and a real
    transcription model: the progress bar's life, the text as a criterion, Validate on three lanes."""
    import time
    if not os.path.exists(VENV_PY) or shutil.which("say") is None:
        print("skip  f: no venv or no `say`")
        return
    probe = subprocess.run([VENV_PY, "-c", "import sys; sys.path.insert(0, %r); import transcribe as tr; "
                            "print(' '.join(m for m in ('align', 'whisper') if tr.installed(m, 'fr')))" % SCRIPT_DIR],
                           capture_output=True, text=True).stdout.split()
    model = probe[0] if probe else None
    if model is None:
        print("skip  f: no transcription model installed")
        return
    ROOT = tmproot("f")
    WAV = os.path.join(ROOT, "thomas.wav")
    subprocess.run(["say", "-v", "Thomas", "-o", WAV, "--data-format=LEI16@44100",
                    "Le serpent chuchote : ces six chasseurs sont assis sous les cyprès. [[slnc 900]] "
                    "Zazie joue au jardin avec des jujubes et des chiens. [[slnc 1100]] "
                    "Un joli visage, une bonne journée, la chaise jaune, le cheval gris."], check=True)
    c.send("project.new")
    a = c.send("object.add", {"path": WAV, "lane": 0, "start": 0.0})["id"]
    env = dict(os.environ, OBJEKAT_SOCKET=SOCK, OBJEKAT_LANGUAGE="fr",
               OBJEKAT_SEPARATEUR_CACHE=os.path.join(ROOT, "cache"))
    forget_remembered(c)
    proc = subprocess.Popen([os.path.join(SCRIPT_DIR, "run.sh"), "--eval-separation", "--object", a,
                             "--model", model], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    end = time.time() + 30
    pid = None
    while time.time() < end and not pid:
        ps = [p for p in c.send("script.panel.list")["panels"] if p["state"] == "open"]
        pid = ps[0]["panel_id"] if ps else None
        time.sleep(0.05)
    check("f: the panel opens", pid is not None)
    if not pid:
        proc.kill()
        return
    seen = []           # (label, value) of the progress bar over time
    end = time.time() + 120
    words = 0
    while time.time() < end:
        g = c.send("script.panel.get", {"panel_id": pid})
        seen.append(g["values"].get("progress"))
        try:
            words = c.send("overlay.get", {"id": a})["texts"]
        except ObjekatError:
            words = 0
        if words > 0 and g["values"].get("progress") == 1.0:
            break
        time.sleep(0.05)
    fractions = [x for x in seen if x is not None]
    print("info  f: progress values seen (%s): %s" % (model, sorted(set(fractions))[:12]))
    check("f: the bar was indeterminate (null) at some point while working", None in seen)
    check("f: the bar reached 1.0 when the transcription finished, %d words on the overlay" % words,
          fractions and fractions[-1] == 1.0 and words > 10)
    n_all = {k: len(zones_of(c, a, k)) for k in ("white", "yellow")}
    print("info  f: zones with the defaults and the text: %s" % n_all)
    check("f: both categories find something on a real voice", n_all["white"] >= 2 and n_all["yellow"] >= 6, n_all)
    # the text as a criterion, PER BLOCK: each block's box + tolerance moves only its own zones
    def counts():
        time.sleep(1.0)
        out = {k: len(zones_of(c, a, k)) for k in ("white", "yellow")}
        out["white_s"] = round(sum(z["end"] - z["start"] for z in zones_of(c, a, "white")), 3)
        return out

    def put(values):
        c.send("script.panel.input", {"panel_id": pid, "values": values})

    put({"b_text_on": False, "s_text_on": False})
    off = counts()
    put({"b_text_on": True, "b_tolerance": 50})
    b_only = counts()
    put({"b_text_on": False, "s_text_on": True, "s_tolerance": 50})
    s_only = counts()
    print("info  f: text off %s, breaths text 50 ms %s, consonants text 50 ms %s" % (off, b_only, s_only))
    check("f: independence — the breaths' text/tolerance leaves the consonant zones as they were",
          b_only["yellow"] == off["yellow"], (off, b_only))
    check("f: independence — dropping consonant zones can only GIVE room to the breaths (priority rule), never take it",
          s_only["white_s"] >= off["white_s"] - 1e-6, (off, s_only))
    check("f: each text criterion only ever DROPS zones of its own block",
          b_only["white"] <= off["white"] and s_only["yellow"] <= off["yellow"])
    put({"b_text_on": True, "b_tolerance": 500, "s_tolerance": 500})
    time.sleep(0.8)
    c.send("script.panel.input", {"panel_id": pid, "press": "validate"})
    rc = proc.wait(timeout=60)
    check("f: the script exits 0 after Validate", rc == 0, proc.stderr.read().decode()[-300:])
    time.sleep(0.3)
    groups = [o for o in c.send("object.list")["objects"] if o.get("kind") == "group"]
    if groups:
        c.send("group.expand", {"id": groups[0]["id"], "expanded": True})
        kids = [o for o in c.send("object.list")["objects"] if o.get("parent") == groups[0]["id"]]
        check("f: Validate lays the real voice on three sub-lanes (Voix / Respirations / Consonnes)",
              {k["lane"] for k in kids} == {0, 1, 2}
              and {k["name"] for k in kids} == {"Voix", "Respirations", "Consonnes"},
              [(k["lane"], k["name"]) for k in kids])
        print("info  f: %d pieces: %s" % (len(kids), {n: sum(1 for k in kids if k["name"] == n) for n in {k["name"] for k in kids}}))
    else:
        check("f: Validate cut the object", False)


def zones_of(c, obj, color):
    try:
        return [z for z in c.send("overlay.get", {"id": obj})["zones"] if z["color"] == color]
    except ObjekatError:
        return []


def section_g(c):
    """`remember`: the values last VALIDATED are the next opening's; Cancel remembers nothing;
    Reset returns to the declared values and forgets. Under --headless / --no-recent the memory
    is the process's own, and the app's real UserDefaults domain must stay free of any panel key."""
    ctl = [{"id": "on", "kind": "bool", "label": "On", "value": False},
           {"id": "gap", "kind": "number", "label": "Gap", "value": 120, "min": 40, "max": 400,
            "step": 10, "unit": "ms"},
           {"id": "m", "kind": "choice", "label": "M", "value": "a",
            "options": [{"id": "a", "label": "A"}, {"id": "b", "label": "B"}]},
           {"id": "prog", "kind": "progress", "label": "P", "value": 0.5},
           {"id": "go", "kind": "button", "label": "Go"}]
    key = "scenario-remember-%d" % os.getpid()

    def open_(controls=ctl, remember=key):
        r = c.send("script.panel.open", {"title": "Rem", "controls": controls, "remember": remember})
        return r["panel_id"]

    def vals(pid):
        return c.send("script.panel.get", {"panel_id": pid})["values"]

    pid = open_()
    v = vals(pid)
    check("g: first opening = declared values", v["gap"] == 120 and v["on"] is False and v["m"] == "a", v)
    check("g: get reports the remember key",
          c.send("script.panel.get", {"panel_id": pid})["remember"] == key)
    c.send("script.panel.input", {"panel_id": pid, "values": {"gap": 250, "on": True, "m": "b"}})
    c.send("script.panel.input", {"panel_id": pid, "press": "cancel"})
    pid = open_()
    v = vals(pid)
    check("g: Cancel remembers nothing", v["gap"] == 120 and v["on"] is False and v["m"] == "a", v)
    c.send("script.panel.input", {"panel_id": pid, "values": {"gap": 250, "on": True, "m": "b"}})
    c.send("script.panel.input", {"panel_id": pid, "press": "validate"})
    pid = open_()
    v = vals(pid)
    check("g: Validate then reopen = remembered values",
          v["gap"] == 250 and v["on"] is True and v["m"] == "b" and v["prog"] == 0.5, v)
    # a panel without `remember` is not affected, and does not remember either
    other = c.send("script.panel.open", {"title": "Rem", "controls": ctl})["panel_id"]
    check("g: without remember, declared values", vals(other)["gap"] == 120)
    check("g: without remember, no key",
          c.send("script.panel.get", {"panel_id": other})["remember"] is None)
    expect_error(lambda: c.send("script.panel.input", {"panel_id": other, "press": "reset"}),
                 "bad_params", "g: reset is refused on a panel that does not remember")
    # Reset: declared values, the hand's rev moves, the entry is erased
    pid = open_()
    rev0 = c.send("script.panel.get", {"panel_id": pid})["rev"]
    c.send("script.panel.input", {"panel_id": pid, "press": "reset"})
    g = c.send("script.panel.get", {"panel_id": pid})
    check("g: Reset returns the declared values and moves rev",
          g["values"]["gap"] == 120 and g["values"]["on"] is False and g["values"]["m"] == "a"
          and g["rev"] > rev0 and g["state"] == "open", g)
    c.send("script.panel.input", {"panel_id": pid, "press": "cancel"})
    pid = open_()
    check("g: Reset erased the entry", vals(pid)["gap"] == 120)
    # a stale entry is ignored value by value: out of range, wrong type, unknown option
    c.send("script.panel.input", {"panel_id": pid, "values": {"gap": 300, "on": True, "m": "b"}})
    c.send("script.panel.input", {"panel_id": pid, "press": "validate"})
    changed = [{"id": "on", "kind": "number", "label": "On", "value": 1, "min": 0, "max": 2, "step": 1},
               {"id": "gap", "kind": "number", "label": "Gap", "value": 60, "min": 40, "max": 200,
                "step": 10},
               {"id": "m", "kind": "choice", "label": "M", "value": "c",
                "options": [{"id": "c", "label": "C"}, {"id": "d", "label": "D"}]}]
    pid = open_(changed)
    v = vals(pid)
    check("g: an entry that no longer fits is ignored", v["on"] == 1 and v["gap"] == 60 and v["m"] == "c", v)
    c.send("script.panel.input", {"panel_id": pid, "press": "cancel"})
    # `true` derives the key from the title
    pid = c.send("script.panel.open", {"title": "Rem", "controls": ctl, "remember": True})["panel_id"]
    check("g: remember true = a key from the title",
          c.send("script.panel.get", {"panel_id": pid})["remember"] == "Rem")
    c.send("script.panel.close", {"panel_id": pid})
    expect_error(lambda: c.send("script.panel.open", {"title": "", "controls": ctl, "remember": True}),
                 "bad_params", "g: remember true with no title refused")
    expect_error(lambda: c.send("script.panel.open", {"title": "t", "controls": ctl, "remember": 3}),
                 "bad_params", "g: remember 3 refused")
    info = c.send("app.info")
    check("g: the instance is a test one (no-recent)", info.get("records_recent_projects") is False, info)
    out = subprocess.run(["defaults", "read", "org.labelpeche.objekat"], capture_output=True, text=True)
    check("g: the real UserDefaults domain holds no panel key",
          "scriptPanel" not in out.stdout and key not in out.stdout)


def section_e():
    """No window on the headless process (a panel was opened and closed above)."""
    try:
        import Quartz
    except ImportError:
        print("skip  e: Quartz not available")
        return
    out = subprocess.run(["pgrep", "-f", "socket=" + SOCK], capture_output=True, text=True).stdout.split()
    pids = [int(x) for x in out]
    if not pids:
        print("skip  e: cannot find the app's pid")
        return
    wins = [w for w in Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionAll,
                                                         Quartz.kCGNullWindowID)
            if w.get("kCGWindowOwnerPID") in pids]
    check("e: no window on the headless pid", len(wins) == 0, len(wins))


try:
    with ObjekatClient(SOCK, timeout=180) as c:
        c.send("app.set_dialog_policy", {"policy": "assume_yes"})
        only = os.environ.get("SECTIONS", "abcdfge")     # e.g. SECTIONS=d to run one section
        if "a" in only:
            section_a(c, 48000)
            section_a(c, 44100)
        for name, fn in (("b", section_b), ("c", section_c), ("d", section_d), ("f", section_f), ("g", section_g)):
            if name in only:
                fn(c)
        if "e" in only:
            section_e()
finally:
    cleanup()

print()
if fails:
    print("%d FAILED" % len(fails))
    sys.exit(1)
print("ALL PASS")

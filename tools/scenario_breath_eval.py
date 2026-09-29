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


def section_d(c):
    """End to end: the script, its panel, its overlay, the cut."""
    import time
    if not os.path.exists(VENV_PY):
        print("skip  d: the script's venv is not installed (%s)" % VENV_PY)
        return
    ROOT = tmproot("d")
    WAV = make_voice_wav(os.path.join(ROOT, "voice.wav"))
    c.send("project.new")
    a = c.send("object.add", {"path": WAV, "lane": 2, "start": 0.0})["id"]

    def launch():
        env = dict(os.environ, OBJEKAT_SOCKET=SOCK, OBJEKAT_LANGUAGE="en",
                   OBJEKAT_SEPARATEUR_CACHE=os.path.join(ROOT, "cache"))
        return subprocess.Popen([os.path.join(SCRIPT_DIR, "run.sh"), "--breaths-eval", "--no-asr",
                                 "--object", a], env=env, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE)

    def panels():
        return [p for p in c.send("script.panel.list")["panels"] if p["state"] == "open"]

    def zones():
        try:
            return len(c.send("overlay.get", {"id": a})["zones"])
        except ObjekatError:
            return 0

    # ── Validate ──
    proc = launch()
    got = wait_for(panels, "d: the script opens its panel")
    pid = got[0]["panel_id"] if got else None
    n0 = wait_for(zones, "d: the script lays zones over the object")
    check("d: zones were laid", bool(n0), n0)
    if pid:
        rev0 = c.send("overlay.get", {"id": a})["rev"]
        g0 = c.send("script.panel.get", {"panel_id": pid})
        check("d: the panel carries the four criteria, the cutoff and the model choice, nothing else",
              set(g0["values"]) == {"model", "unvoiced_on", "unvoiced", "below_speech_on", "below_speech",
                                    "cutoff", "min_len_on", "min_len", "end_margin_on", "end_margin"},
              sorted(g0["values"]))
        check("d: defaults: model none, cutoff 6000 Hz, 10 dB, 80 ms, 5 ms",
              (g0["values"]["model"], g0["values"]["cutoff"], g0["values"]["below_speech"],
               g0["values"]["min_len"], g0["values"]["end_margin"]) == ("none", 6000, 10, 80, 5),
              g0["values"])
        c.send("script.panel.input", {"panel_id": pid, "values": {"below_speech_on": False}})
        wait_for(lambda: c.send("overlay.get", {"id": a})["rev"] > rev0, "d: a setting re-runs the mask")
        n1 = zones()
        check("d: switching the energy criterion off never loses zones (%s -> %s)" % (n0, n1),
              n1 >= (n0 or 0))
        c.send("script.panel.input", {"panel_id": pid, "values": {"below_speech_on": True, "cutoff": 800}})
        wait_for(lambda: c.send("overlay.get", {"id": a})["rev"] > rev0 + 1, "d: the cutoff moves the zones")
        # a model that is not installed says so, and the panel stays alive
        c.send("script.panel.input", {"panel_id": pid, "values": {"model": "parakeet"}})
        wait_for(lambda: ("not installed" in c.send("script.panel.get", {"panel_id": pid})["status"])
                 or ("zone" in c.send("script.panel.get", {"panel_id": pid})["status"]
                     and c.send("overlay.get", {"id": a})["texts"] > 0),
                 "d: an absent model says 'not installed' in the status line (or, installed, shows words)")
        c.send("script.panel.input", {"panel_id": pid, "values": {"model": "none"}})
        wait_for(lambda: c.send("overlay.get", {"id": a})["texts"] == 0, "d: 'None' clears the words")
        c.send("script.panel.input", {"panel_id": pid, "press": "validate"})
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
        check("d: two sub-lanes, named voice / breaths",
              {k["lane"] for k in kids} == {0, 1}
              and {k["name"] for k in kids} == {"Voice", "Breaths"}, [(k["lane"], k["name"]) for k in kids])
    check("d: overlay and panel gone", c.send("overlay.list")["overlays"] == [] and panels() == [])
    c.send("edit.undo")
    objs = c.send("object.list")["objects"]
    check("d: one undo gives the original object back", [o["id"] for o in objs] == [a],
          [o["id"] for o in objs])

    # ── Cancel ──
    before = c.send("object.list")["objects"]
    proc = launch()
    got = wait_for(panels, "d: cancel run: panel opens")
    if got:
        wait_for(zones, "d: cancel run: zones")
        c.send("script.panel.input", {"panel_id": got[0]["panel_id"], "press": "cancel"})
    rc = proc.wait(timeout=60)
    time.sleep(0.3)
    check("d: Cancel exits 0 and leaves the project as it was",
          rc == 0 and c.send("object.list")["objects"] == before)
    check("d: Cancel leaves no overlay", c.send("overlay.list")["overlays"] == [])

    # ── The script is killed while its panel is open ──
    proc = launch()
    got = wait_for(panels, "d: kill run: panel opens")
    wait_for(zones, "d: kill run: zones")
    proc.kill()
    proc.wait()
    ok = wait_for(lambda: c.send("overlay.list")["overlays"] == [] and panels() == [],
                  "d: SIGKILL on the script clears its overlay and its panel", timeout=10)
    if ok:
        check("d: SIGKILL on the script clears its overlay and its panel", True)


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
        section_a(c, 48000)
        section_a(c, 44100)
        section_b(c)
        section_c(c)
        section_d(c)
        section_e()
finally:
    cleanup()

print()
if fails:
    print("%d FAILED" % len(fails))
    sys.exit(1)
print("ALL PASS")

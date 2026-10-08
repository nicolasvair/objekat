#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The spectral editor, app side — driven headless (@see plan_spectral_editor.md, section 6).

Standard library only. `SECTIONS=` picks the sections to run (default: every one that exists).

Section (a) — THE API ADDITIONS the editor leans on: `object.get` answers `source_sample_rate`,
`source_bit_depth` and `source_format` for a clip (and null for anything else), `object.add` takes
a `name`, and a `batch [add, mute]` is ONE undo.

    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --socket=/tmp/o.sock
    ./scenario_spectral_editor.py /tmp/o.sock

Section (b) — THE CANVAS CONTRACT (`script.canvas.*`): the test client plays the script. Opening
and its refusals, the base image, the ops the hand draws, the history, the layers and the rule that
says which traces are still visible, the long poll, the audio and the transport model, `remember`,
the absence of any trace in the project, and the canvas's life.

Section (c) — END TO END, INSTANT MODE: the real script (`tools/scripts/spectral-editor/run.sh --object ID`,
its own process and its own connection) is driven through the canvas door like a hand would: a rectangle,
an undo, two brush strokes, an out-and-back stroke, an expert change, Validate. Checked on the base
image's pixels (the spectrogram itself shows what is applied: no overlay), on the result's tones
(Goertzel), on a WAV export of the session before / after, and on what a second session remembers.
Section (g) — END TO END, SELECTION MODE: a weighted selection built with a rectangle, a brush pass and
an Erase pass, the gain tuned LIVE (the history does not move, the preview does), Apply (one step, the
selection layer gone, the spectrogram shows it), undo, and Validate with a selection still pending (what is
heard is written). Section (d) — THE FORMATS the file
comes back in (44.1 kHz / 16-bit mono, float, stereo with L != R, stereo with L == R). Section (e) —
REFUSALS AND ENDINGS: a group of 601 s, Cancel, a SIGKILLed script, a clip whose file has gone. (c), (d)
and (e) are skipped when the script's venv is missing (`install.sh`).

Section (h) — REVISION 5: a picture per listening state (`set_image {slot}`: the plot draws the picture of the slot
being heard, no round trip), and the monitoring level (`input {monitor_db}`, -20..+20 dB, app-owned, kept IN THE
PROJECT under the canvas's `remember` key: saved, restored on reopening, 0 dB in another project, never in the user's
UserDefaults). The real script's pictures (Original, Difference) and the overlap's effect on the picture are checked
in (c).

Section (i) — REVISION 6, CANVAS SIDE: an op's `slot` (the audio heard when it was drawn), and in Selection mode
the undo that REVEALS an applied step's selection (pending again, settings restored; redo; Instant unchanged).
Section (j) — REVISION 6, END TO END: working on the Difference (G' = 1 - (1 - G) g; Result + Difference = Original,
pending selection included) and the spectrogram's display range (recoloured in place, remembered, Reset).

Section (k) — THE BIG WINDOWS: FFT 16384 and 32768 end to end (the picture's width follows the hop, a -24 dB rectangle
is -24 dB, the choice is remembered, Reset gives back 2048) and an object shorter than the window (coarse picture,
no refusal, the rectangle still works).

Section (l) — REVISION 7, THE FOCUSED DISPLAY: the reassigned spectrogram chosen in the Expert section (display only): the
three pictures on the focused grid, a tone drawn as a line, the status "Focused (display only)", the audio untouched (a
-24 dB rectangle is -24 dB), the compute size lifted to the window, remembered, Reset.

Section (f) — NO WINDOW ON THE HEADLESS PID: a canvas is opened, given an image, a layer, audio and
an op, played, and closed, and `CGWindowListCopyWindowInfo` on the app's pid stays empty (opening a
window is the window layer's only side effect, and `--headless` forbids it).

Exit: 0 if every assertion passes, 1 otherwise.
"""

import json
import math
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import time
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


def expect_error(fn, code, label):
    try:
        fn()
        check(label, False, "it went through")
    except ObjekatError as e:
        check(label, e.code == code, "%s: %s" % (e.code, e.message))


def tmproot(tag):
    folder = tempfile.mkdtemp(prefix="objekat-spectral-%s-" % tag)
    roots.append(folder)
    return os.path.realpath(folder)


def make_wav(path, seconds, rate, depth=24, hz=440.0, amp=0.25):
    """A mono sine, written with `wave` (16 or 24 bit integer PCM)."""
    frames = int(round(seconds * rate))
    raw = bytearray()
    for i in range(frames):
        v = amp * math.sin(2 * math.pi * hz * i / rate)
        if depth == 16:
            raw += struct.pack("<h", int(v * 32767))
        else:
            raw += struct.pack("<i", int(v * (2 ** 23 - 1)))[0:3]
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(depth // 8)
        w.setframerate(rate)
        w.writeframes(bytes(raw))
    return path


def make_float_wav(path, seconds, rate, hz=440.0, amp=0.25):
    """A mono 32-bit FLOAT wav (format tag 3, which `wave` cannot write), by hand."""
    frames = int(round(seconds * rate))
    data = b"".join(struct.pack("<f", amp * math.sin(2 * math.pi * hz * i / rate)) for i in range(frames))
    fmt = struct.pack("<HHIIHH", 3, 1, rate, rate * 4, 4, 32)
    fact = struct.pack("<I", frames)
    body = (b"WAVE" + b"fmt " + struct.pack("<I", len(fmt)) + fmt
            + b"fact" + struct.pack("<I", len(fact)) + fact
            + b"data" + struct.pack("<I", len(data)) + data)
    with open(path, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", len(body)) + body)
    return path


def cleanup():
    for r in roots:
        shutil.rmtree(r, ignore_errors=True)


# ---------------------------------------------------------------------------------------------
# a. API additions
# ---------------------------------------------------------------------------------------------

def section_a(c):
    ROOT = tmproot("a")
    w24 = make_wav(os.path.join(ROOT, "w24.wav"), 1.0, 48000, 24)
    w16 = make_wav(os.path.join(ROOT, "w16.wav"), 1.0, 44100, 16)
    wf = make_float_wav(os.path.join(ROOT, "wf32.wav"), 1.0, 48000)
    c.send("project.new")

    a = c.send("object.add", {"path": w24, "lane": 0, "start": 0.0})["id"]
    b = c.send("object.add", {"path": w16, "lane": 1, "start": 0.0})["id"]
    f = c.send("object.add", {"path": wf, "lane": 2, "start": 0.0})["id"]
    ga = c.send("object.get", {"id": a})
    check("a: 48 kHz / 24-bit file: source_sample_rate", ga["source_sample_rate"] == 48000, ga["source_sample_rate"])
    check("a: 48 kHz / 24-bit file: source_bit_depth", ga["source_bit_depth"] == 24, ga["source_bit_depth"])
    check("a: 48 kHz / 24-bit file: source_format", ga["source_format"] == "pcm_int", ga["source_format"])
    gb = c.send("object.get", {"id": b})
    check("a: 44.1 kHz / 16-bit file: source_sample_rate", gb["source_sample_rate"] == 44100, gb["source_sample_rate"])
    check("a: 44.1 kHz / 16-bit file: source_bit_depth", gb["source_bit_depth"] == 16, gb["source_bit_depth"])
    check("a: 44.1 kHz / 16-bit file: source_format", gb["source_format"] == "pcm_int", gb["source_format"])
    gf = c.send("object.get", {"id": f})
    check("a: float file: pcm_float / 32", gf["source_format"] == "pcm_float" and gf["source_bit_depth"] == 32
          and gf["source_sample_rate"] == 48000, (gf["source_format"], gf["source_bit_depth"]))

    # a group is no clip: null across the board
    c.send("selection.set", {"ids": [a, b]})
    grp = c.send("group.create", {"ids": [a, b]})
    gid = grp.get("id") or grp.get("group_id")
    if gid is None:
        gid = next((o["id"] for o in c.send("object.list")["objects"] if o["kind"] == "group"), None)
    gg = c.send("object.get", {"id": gid})
    check("a: a group has null source_* fields",
          gg["source_sample_rate"] is None and gg["source_bit_depth"] is None and gg["source_format"] is None, gg)

    # object.add name
    c.send("project.new")
    n = c.send("object.add", {"path": w24, "lane": 0, "start": 1.0, "name": "tone (spectral)"})["id"]
    check("a: object.add name shows that name", c.send("object.get", {"id": n})["name"] == "tone (spectral)",
          c.send("object.get", {"id": n})["name"])
    n2 = c.send("object.add", {"path": w24, "lane": 1, "start": 1.0})["id"]
    check("a: no name = the file's name", c.send("object.get", {"id": n2})["name"] == "w24.wav")
    n3 = c.send("object.add", {"path": w24, "lane": 2, "start": 1.0, "name": ""})["id"]
    check("a: an empty name = the file's name", c.send("object.get", {"id": n3})["name"] == "w24.wav")
    # one undo takes the added object away (the name cost no second step)
    c.send("edit.undo")
    ids = [o["id"] for o in c.send("object.list")["objects"]]
    check("a: one undo removes an object laid down with a name (no extra step)",
          n3 not in ids and n2 in ids and n in ids, ids)

    # batch [add, mute] then ONE undo
    c.send("project.new")
    orig = c.send("object.add", {"path": w24, "lane": 0, "start": 0.0})["id"]
    r = c.send("batch", {"commands": [
        {"cmd": "object.add", "params": {"path": w16, "lane": 1, "start": 0.0, "name": "orig (spectral)"}},
        {"cmd": "object.set_mute", "params": {"ids": [orig], "muted": True}},
    ]})
    objs = {o["id"]: o for o in c.send("object.list")["objects"]}
    new = [o for o in objs.values() if o["name"] == "orig (spectral)"]
    check("a: batch [add, mute]: the new object exists and the original is muted",
          len(new) == 1 and objs[orig]["muted"] is True, (r, list(objs.values())))
    c.send("edit.undo")
    objs = {o["id"]: o for o in c.send("object.list")["objects"]}
    check("a: ONE edit.undo removes the new object AND unmutes the original",
          list(objs) == [orig] and objs[orig]["muted"] is False, list(objs.values()))



# ---------------------------------------------------------------------------------------------
# b. The canvas contract
# ---------------------------------------------------------------------------------------------

def write_cnv(path, w, h, v0=-100.0, v255=0.0, indices=None):
    """An OBJKCNV1: header, a grey palette, one index per pixel."""
    indices = indices if indices is not None else bytes((i * 7) % 256 for i in range(w * h))
    palette = b"".join(bytes((i, i, i)) for i in range(256))
    with open(path, "wb") as f:
        f.write(b"OBJKCNV1" + struct.pack("<IIffI", w, h, v0, v255, 0) + palette + bytes(indices))
    return path


def write_rgb(path, w, h, rgba=(0, 191, 255, 191)):
    """An OBJKRGB1 filled with one premultiplied colour."""
    with open(path, "wb") as f:
        f.write(b"OBJKRGB1" + struct.pack("<IIQ", w, h, 0) + bytes(rgba) * (w * h))
    return path


def timed(fn):
    t = time.time()
    r = fn()
    return r, time.time() - t


TOOLS = [
    {"id": "rect", "kind": "rect", "label": "Rectangle", "params": ["gain", "feather_ms", "feather_st"]},
    {"id": "brush", "kind": "stroke", "label": "Brush", "icon": "paintbrush.pointed",
     "params": ["quantity", "hardness"], "size_control": "size_px"},
    {"id": "pick", "kind": "point", "label": "Pick"},
]

CANVAS_CONTROLS = [
    {"id": "sec_rect", "kind": "section", "label": "Rectangle"},
    {"id": "gain", "kind": "number", "label": "Gain", "value": -12, "min": -60, "max": 12, "step": 0.5, "unit": "dB"},
    {"id": "feather_ms", "kind": "number", "label": "Feather", "value": 10, "min": 0, "max": 200, "step": 1, "unit": "ms"},
    {"id": "feather_st", "kind": "number", "label": "Feather", "value": 1, "min": 0, "max": 12, "step": 0.1, "unit": "st"},
    {"id": "size_px", "kind": "number", "label": "Size", "value": 32, "min": 4, "max": 200, "step": 1, "unit": "px"},
    {"id": "quantity", "kind": "number", "label": "Amount per pass", "value": 25, "min": 1, "max": 100, "step": 1, "unit": "%"},
    {"id": "hardness", "kind": "number", "label": "Hardness", "value": 50, "min": 0, "max": 100, "step": 1, "unit": "%"},
    {"id": "go", "kind": "button", "label": "Go"},
    {"id": "prog", "kind": "progress", "label": "Progress"},
]

# Every hand-value control (bool, number, choice) — what a committed STEP snapshots when it is sealed.
ALL_VALUES = {"gain": -12, "feather_ms": 10, "feather_st": 1, "size_px": 32, "quantity": 25, "hardness": 50}

X_AXIS = {"min": 0, "max": 10, "unit": "s"}
Y_AXIS = {"min": 20, "max": 24000, "unit": "Hz", "mapping": "log"}


def open_canvas(c, **kw):
    params = {"title": "Test", "controls": CANVAS_CONTROLS, "tools": TOOLS}
    params.update(kw)
    return c.send("script.canvas.open", params)["canvas_id"]


def section_b(c):
    ROOT = tmproot("b")
    WAV3 = make_wav(os.path.join(ROOT, "tone3.wav"), 3.0, 48000, 24)
    WAV1 = make_wav(os.path.join(ROOT, "tone1.wav"), 1.0, 48000, 24)
    CNV = write_cnv(os.path.join(ROOT, "base.objkcnv"), 4, 2)
    RGB = write_rgb(os.path.join(ROOT, "tint.objkrgb"), 8, 4)
    RGB2 = write_rgb(os.path.join(ROOT, "tint2.objkrgb"), 2, 2)
    c.send("project.new")
    obj = c.send("object.add", {"path": WAV3, "lane": 0, "start": 0.0})["id"]

    # -- opening ---------------------------------------------------------------------------
    r = c.send("script.canvas.open", {"title": "Open", "controls": CANVAS_CONTROLS, "tools": TOOLS})
    cid = r["canvas_id"]
    check("b: open answers rev 0", r["rev"] == 0, r)
    g = c.send("script.canvas.get", {"canvas_id": cid})
    check("b: get: open, the first declared tool is active, no image, no world",
          g["state"] == "open" and g["tool"] == "rect" and g["image"] is None and g["world"] is None
          and g["layers"] == [] and g["view"] is None, g)
    check("b: get: values hold the declared defaults", g["values"]["gain"] == -12 and g["values"]["size_px"] == 32, g["values"])
    check("b: get: empty history", g["history"]["rev"] == 0 and g["history"]["cursor"] == 0
          and g["history"]["count"] == 0 and g["history"]["pending"] == 0 and g["history"]["unreflected"] == []
          and g["history"]["entries"] == [] and "ops" not in g["history"], g["history"])
    check("b: get: no modes by default — Instant, polarity add", g["modes"] is False and g["mode"] == "instant"
          and g["polarity"] == "add", (g["modes"], g["mode"], g["polarity"]))
    check("b: get: transport at rest", g["transport"]["playing"] is False and g["transport"]["caret"] == 0
          and g["transport"]["position"] == 0 and g["transport"]["listen"] == "original"
          and "delta" not in g["transport"]
          and g["transport"]["slots"] == {"original": None, "result": None, "delta": None}, g["transport"])
    check("b: a second open on the same connection replaces the first (it ends closed)",
          c.send("script.canvas.open", {"title": "Open2", "tools": []})["rev"] == 0
          and [x["title"] for x in c.send("script.canvas.list")["canvases"]] == ["Open2"],
          c.send("script.canvas.list"))
    g = c.send("script.canvas.get", {"canvas_id": c.send("script.canvas.list")["canvases"][0]["canvas_id"]})
    check("b: with no tool declared there is no active tool (no Hand any more)", g["tool"] is None, g["tool"])
    cid = open_canvas(c)

    def refuse(label, **kw):
        bad_tools = kw.pop("tools", None)
        params = {"title": "Bad", "controls": CANVAS_CONTROLS, "tools": bad_tools if bad_tools is not None else TOOLS}
        params.update(kw)
        expect_error(lambda: c.send("script.canvas.open", params), "bad_params", "b: open refuses " + label)

    refuse("a duplicate tool id", tools=[TOOLS[0], dict(TOOLS[0])])
    refuse("an unknown tool kind", tools=[{"id": "x", "kind": "lasso", "label": "X"}])
    refuse("a tool with no label", tools=[{"id": "x", "kind": "rect"}])
    refuse("an unknown control in params", tools=[{"id": "x", "kind": "rect", "label": "X", "params": ["nope"]}])
    refuse("a button in params", tools=[{"id": "x", "kind": "rect", "label": "X", "params": ["go"]}])
    refuse("a progress in params", tools=[{"id": "x", "kind": "rect", "label": "X", "params": ["prog"]}])
    refuse("a section in params", tools=[{"id": "x", "kind": "rect", "label": "X", "params": ["sec_rect"]}])
    refuse("a stroke tool with no size_control", tools=[{"id": "x", "kind": "stroke", "label": "X"}])
    refuse("a size_control that is not a control", tools=[{"id": "x", "kind": "stroke", "label": "X", "size_control": "nope"}])
    refuse("a size_control on a button", tools=[{"id": "x", "kind": "stroke", "label": "X", "size_control": "go"}])
    refuse("a size_control on a rect", tools=[{"id": "x", "kind": "rect", "label": "X", "size_control": "size_px"}])
    refuse("a duplicate control id", controls=[CANVAS_CONTROLS[1], dict(CANVAS_CONTROLS[1])])
    refuse("a control with min >= max",
           controls=[{"id": "n", "kind": "number", "label": "n", "min": 1, "max": 1, "step": 1}], tools=[])
    expect_error(lambda: c.send("script.canvas.open", {"title": "x", "controls": CANVAS_CONTROLS}),
                 "bad_params", "b: open refuses a missing tools list")
    expect_error(lambda: c.send("script.canvas.open", {"title": "x", "tools": [], "object": "00000000-0000-0000-0000-000000000000"}),
                 "not_found", "b: open: unknown object")
    expect_error(lambda: c.send("script.canvas.open", {"title": "", "tools": [], "remember": True}),
                 "bad_params", "b: remember true with no title refused")
    cid = open_canvas(c, object=obj)           # the refusals above must not have replaced a live canvas
    cid_h = open_canvas(c, tools=[{"id": "hand", "kind": "rect", "label": "H"}])
    check("b: the id \"hand\" is no longer reserved: an ordinary tool",
          c.send("script.canvas.get", {"canvas_id": cid_h})["tool"] == "hand")
    cid = open_canvas(c, object=obj)

    # -- set_image -------------------------------------------------------------------------
    expect_error(lambda: c.send("script.canvas.set_layer", {"canvas_id": cid, "layer": "tint", "path": RGB}),
                 "invalid_state", "b: set_layer without a base image -> invalid_state")
    r = c.send("script.canvas.set_image", {"canvas_id": cid, "path": CNV, "x": X_AXIS, "y": Y_AXIS, "value_unit": "dB"})
    check("b: a 4x2 OBJKCNV1 echoes its size and has values",
          r == {"width": 4, "height": 2, "has_values": True}, r)
    g = c.send("script.canvas.get", {"canvas_id": cid})
    check("b: get: image, world and a fitted view",
          g["image"] == {"path": CNV, "width": 4, "height": 2, "has_values": True, "history_rev": None,
                         "slots": {}, "shown": CNV}
          and g["world"]["x"] == {"min": 0, "max": 10, "unit": "s", "mapping": "lin"}
          and g["world"]["y"] == {"min": 20, "max": 24000, "unit": "Hz", "mapping": "log"}
          and g["view"]["x0"] == 0 and g["view"]["x1"] == 10
          and abs(g["view"]["y0"] - 20) < 1e-6 and abs(g["view"]["y1"] - 24000) < 1e-3
          and g["view"]["width"] == 1000 and g["view"]["height"] == 500, g)
    short = os.path.join(ROOT, "short.objkcnv")
    with open(CNV, "rb") as f:
        data = f.read()
    with open(short, "wb") as f:
        f.write(data[:-1])
    expect_error(lambda: c.send("script.canvas.set_image", {"canvas_id": cid, "path": short, "x": X_AXIS, "y": Y_AXIS}),
                 "bad_params", "b: set_image: a truncated file -> bad_params")
    junk = os.path.join(ROOT, "junk.bin")
    with open(junk, "wb") as f:
        f.write(b"not an image at all")
    expect_error(lambda: c.send("script.canvas.set_image", {"canvas_id": cid, "path": junk, "x": X_AXIS, "y": Y_AXIS}),
                 "bad_params", "b: set_image: a file no reader knows -> bad_params")
    expect_error(lambda: c.send("script.canvas.set_image", {"canvas_id": cid, "path": os.path.join(ROOT, "missing.objkcnv"),
                                                              "x": X_AXIS, "y": Y_AXIS}),
                 "not_found", "b: set_image: a missing file -> not_found")
    expect_error(lambda: c.send("script.canvas.set_image", {"canvas_id": cid, "path": CNV, "x": X_AXIS,
                                                              "y": {"min": 0, "max": 100, "mapping": "log"}}),
                 "bad_params", "b: set_image: a log axis with min 0 -> bad_params")
    expect_error(lambda: c.send("script.canvas.set_image", {"canvas_id": cid, "path": CNV, "x": {"min": 5, "max": 5}, "y": Y_AXIS}),
                 "bad_params", "b: set_image: min >= max -> bad_params")
    expect_error(lambda: c.send("script.canvas.set_image", {"canvas_id": cid, "path": CNV, "x": X_AXIS,
                                                              "y": {"min": 1, "max": 2, "mapping": "cubic"}}),
                 "bad_params", "b: set_image: an unknown mapping -> bad_params")
    big = os.path.join(ROOT, "toowide.objkrgb")
    with open(big, "wb") as f:
        f.write(b"OBJKRGB1" + struct.pack("<IIQ", 16385, 1, 0) + bytes(4 * 16385))
    expect_error(lambda: c.send("script.canvas.set_image", {"canvas_id": cid, "path": big, "x": X_AXIS, "y": Y_AXIS}),
                 "bad_params", "b: set_image: a width over 16384 -> bad_params")
    check("b: the refused calls left the image as it was",
          c.send("script.canvas.get", {"canvas_id": cid})["image"]["path"] == CNV)
    r = c.send("script.canvas.set_image", {"canvas_id": cid, "path": RGB, "x": X_AXIS, "y": Y_AXIS})
    check("b: an OBJKRGB1 base has no values", r == {"width": 8, "height": 4, "has_values": False}, r)
    c.send("script.canvas.set_image", {"canvas_id": cid, "path": CNV, "x": X_AXIS, "y": Y_AXIS, "value_unit": "dB"})

    # -- ops -------------------------------------------------------------------------------
    rev0 = c.send("script.canvas.get", {"canvas_id": cid})["rev"]
    r = c.send("script.canvas.input", {"canvas_id": cid, "op": {"kind": "rect", "x0": 12, "x1": -1, "y0": 10000, "y1": 100}})
    check("b: a rect input is added, moves rev, history and cursor",
          r["added"] is True and r["rev"] > rev0 and r["history_rev"] == 1 and r["cursor"] == 1, r)
    g = c.send("script.canvas.get", {"canvas_id": cid})
    e1 = g["history"]["entries"][0]
    op1 = e1["ops"][0]
    check("b: Instant: a gesture is ONE step of one op, params = EVERY hand value, polarity add",
          e1["kind"] == "step" and e1["id"] == 1 and e1["active_since"] == 1 and len(e1["ops"]) == 1
          and e1["params"] == ALL_VALUES and op1["polarity"] == "add" and "active_since" not in op1, e1)
    check("b: the rect is sorted and clamped to the world",
          (op1["kind"], op1["tool"], op1["x0"], op1["x1"], op1["y0"], op1["y1"]) == ("rect", "rect", 0, 10, 100, 10000), op1)
    check("b: the op's params snapshot the tool's controls (and only those)",
          op1["params"] == {"gain": -12, "feather_ms": 10, "feather_st": 1} and op1["id"] == 1, op1)
    c.send("script.canvas.input", {"canvas_id": cid, "values": {"gain": -24}})
    c.send("script.canvas.input", {"canvas_id": cid, "op": {"kind": "rect", "x0": 1, "x1": 2, "y0": 200, "y1": 400}})
    ents = c.send("script.canvas.get", {"canvas_id": cid})["history"]["entries"]
    ops = [o for e in ents for o in e["ops"]]
    check("b: the next op snapshots the new value and the earlier op is unchanged",
          ops[1]["params"]["gain"] == -24 and ops[0]["params"]["gain"] == -12 and ops[1]["id"] == 2, ops)
    check("b: ... and so does its step (the earlier step keeps -12)",
          ents[1]["params"]["gain"] == -24 and ents[0]["params"]["gain"] == -12, ents)
    rev_before = c.send("script.canvas.get", {"canvas_id": cid})["rev"]
    r = c.send("script.canvas.input", {"canvas_id": cid, "op": {"kind": "rect", "x0": 3, "x1": 3, "y0": 200, "y1": 400}})
    check("b: a rect of zero area adds nothing and leaves rev alone",
          r["added"] is False and r["rev"] == rev_before and r["cursor"] == 2, r)
    r = c.send("script.canvas.input", {"canvas_id": cid, "op": {"kind": "rect", "x0": 11, "x1": 12, "y0": 200, "y1": 400}})
    check("b: a rect wholly outside the world is zero area once clamped", r["added"] is False, r)
    pts = [[1.0, 3000.0], [2.5, 3000.0], [4.0, 3100.0]]
    r = c.send("script.canvas.input", {"canvas_id": cid, "op": {"kind": "stroke", "points": pts, "view_scale": {"x": 500, "y": 100}}})
    check("b: a stroke is added", r["added"] is True and r["cursor"] == 3, r)
    op3 = c.send("script.canvas.get", {"canvas_id": cid})["history"]["entries"][2]["ops"][0]
    check("b: stroke: size_pt from size_px, size_x = 32/500, size_y = 32/100",
          op3["kind"] == "stroke" and op3["tool"] == "brush" and op3["size_pt"] == 32
          and abs(op3["size_x"] - 0.064) < 1e-12 and abs(op3["size_y"] - 0.32) < 1e-12, op3)
    check("b: stroke: points stored as given, params are the brush's",
          op3["points"] == pts and op3["params"] == {"quantity": 25, "hardness": 50}, op3)
    rev_before = c.send("script.canvas.get", {"canvas_id": cid})["rev"]
    r = c.send("script.canvas.input", {"canvas_id": cid, "op": {"kind": "stroke", "points": [[1.0, 3000.0], [1.0001, 3000.0]],
                                                                  "view_scale": {"x": 500, "y": 100}}})
    check("b: a stroke shorter than 1 pt adds nothing and leaves rev alone",
          r["added"] is False and r["rev"] == rev_before and r["cursor"] == 3, r)
    expect_error(lambda: c.send("script.canvas.input", {"canvas_id": cid, "op": {"kind": "stroke", "points": [[1.0, 3000.0]]}}),
                 "bad_params", "b: a stroke of one point -> bad_params")
    expect_error(lambda: c.send("script.canvas.input", {"canvas_id": cid, "op": {"kind": "stroke", "points": [[1.0, 0.0], [2.0, 5.0]]}}),
                 "bad_params", "b: a stroke point at y <= 0 on a log axis -> bad_params")
    expect_error(lambda: c.send("script.canvas.input", {"canvas_id": cid, "op": {"kind": "stroke", "points": [[0.0, 100.0]] * 20001}}),
                 "bad_params", "b: a stroke of 20001 points -> bad_params")
    expect_error(lambda: c.send("script.canvas.input", {"canvas_id": cid, "op": {"kind": "rect", "x0": 1, "x1": "a", "y0": 1, "y1": 2}}),
                 "bad_params", "b: a rect with a non-number -> bad_params")
    r = c.send("script.canvas.input", {"canvas_id": cid, "op": {"kind": "point", "x": 5, "y": 1000}})
    op4 = c.send("script.canvas.get", {"canvas_id": cid})["history"]["entries"][3]["ops"][0]
    check("b: a point op (the first point tool is used)",
          r["added"] is True and op4["kind"] == "point" and op4["tool"] == "pick" and op4["x"] == 5 and op4["y"] == 1000
          and op4["params"] == {}, op4)
    rev_before = c.send("script.canvas.get", {"canvas_id": cid})["rev"]
    c.send("script.canvas.input", {"canvas_id": cid, "tool": "brush"})
    g = c.send("script.canvas.get", {"canvas_id": cid})
    check("b: tool moves no rev", g["tool"] == "brush" and g["rev"] == rev_before)
    c.send("script.canvas.input", {"canvas_id": cid, "op": {"kind": "rect", "x0": 0, "x1": 1, "y0": 100, "y1": 200}})
    last = c.send("script.canvas.get", {"canvas_id": cid})["history"]["entries"][-1]["ops"][-1]
    check("b: a rect with the stroke tool active uses the first tool of its kind", last["tool"] == "rect", last)
    expect_error(lambda: c.send("script.canvas.input", {"canvas_id": cid, "tool": "nope"}),
                 "bad_params", "b: an unknown tool -> bad_params")
    expect_error(lambda: c.send("script.canvas.input", {"canvas_id": cid, "tool": "hand"}),
                 "bad_params", "b: tool \"hand\" -> bad_params (there is no Hand any more)")
    expect_error(lambda: c.send("script.canvas.input", {"canvas_id": cid, "values": {"nope": 1}}),
                 "bad_params", "b: input: an unknown control is refused")
    expect_error(lambda: c.send("script.canvas.input", {"canvas_id": cid, "values": {"prog": 0.5}}),
                 "bad_params", "b: input: the hand cannot set a progress bar")
    c.send("script.canvas.input", {"canvas_id": cid, "values": {"gain": 99}})
    check("b: a number is clamped to its range", c.send("script.canvas.get", {"canvas_id": cid})["values"]["gain"] == 12)
    # the rect-less canvas
    cid_nr = open_canvas(c, tools=[{"id": "pick", "kind": "point", "label": "Pick"}])
    expect_error(lambda: c.send("script.canvas.input", {"canvas_id": cid_nr, "op": {"kind": "point", "x": 1, "y": 1}}),
                 "invalid_state", "b: an op before the world exists -> invalid_state")
    c.send("script.canvas.set_image", {"canvas_id": cid_nr, "path": CNV, "x": X_AXIS, "y": Y_AXIS})
    expect_error(lambda: c.send("script.canvas.input", {"canvas_id": cid_nr, "op": {"kind": "rect", "x0": 0, "x1": 1, "y0": 100, "y1": 200}}),
                 "invalid_state", "b: an op of a kind no tool offers -> invalid_state")
    cid = open_canvas(c, object=obj)
    c.send("script.canvas.set_image", {"canvas_id": cid, "path": CNV, "x": X_AXIS, "y": Y_AXIS, "value_unit": "dB"})

    # -- history ---------------------------------------------------------------------------
    def rect(x0, x1):
        return c.send("script.canvas.input", {"canvas_id": cid, "op": {"kind": "rect", "x0": x0, "x1": x1, "y0": 100, "y1": 200}})

    def hist():
        return c.send("script.canvas.get", {"canvas_id": cid})["history"]

    r1, r2, r3 = rect(0, 1), rect(1, 2), rect(2, 3)
    h = hist()
    check("b: three steps, cursor 3, ids 1 2 3, pending 0", h["cursor"] == 3 and h["count"] == 3 and h["pending"] == 0
          and [e["id"] for e in h["entries"]] == [1, 2, 3] and all(e["kind"] == "step" for e in h["entries"]), h)
    rev = c.send("script.canvas.get", {"canvas_id": cid})["rev"]
    r = c.send("script.canvas.input", {"canvas_id": cid, "undo": True})
    check("b: undo moves the cursor, the history rev and rev", r["cursor"] == 2 and r["history_rev"] == 4 and r["rev"] > rev
          and r["added"] is False, r)
    h = hist()
    check("b: an undone entry stays in the list", h["count"] == 3 and h["cursor"] == 2, h)
    r = c.send("script.canvas.input", {"canvas_id": cid, "redo": True})
    check("b: redo moves it back", r["cursor"] == 3 and r["history_rev"] == 5, r)
    c.send("script.canvas.input", {"canvas_id": cid, "undo": True})
    c.send("script.canvas.input", {"canvas_id": cid, "undo": True})
    r = rect(5, 6)
    h = hist()
    check("b: a new op after an undo truncates the redo tail (ids stay monotonic)",
          h["count"] == 2 and h["cursor"] == 2 and [e["id"] for e in h["entries"]] == [1, 4], h)
    rev = c.send("script.canvas.get", {"canvas_id": cid})["rev"]
    r = c.send("script.canvas.input", {"canvas_id": cid, "redo": True})
    check("b: redo at the end is a no-op", r["rev"] == rev and r["cursor"] == 2 and r["added"] is False, r)
    c.send("script.canvas.input", {"canvas_id": cid, "undo": True})
    c.send("script.canvas.input", {"canvas_id": cid, "undo": True})
    rev = c.send("script.canvas.get", {"canvas_id": cid})["rev"]
    r = c.send("script.canvas.input", {"canvas_id": cid, "undo": True})
    check("b: undo at the start is a no-op", r["rev"] == rev and r["cursor"] == 0 and r["added"] is False, r)
    c.send("script.canvas.input", {"canvas_id": cid, "redo": True})
    c.send("script.canvas.input", {"canvas_id": cid, "redo": True})

    # -- modes, drafts, commit, polarity ---------------------------------------------------
    cm_no = open_canvas(c, object=obj)
    c.send("script.canvas.set_image", {"canvas_id": cm_no, "path": CNV, "x": X_AXIS, "y": Y_AXIS})
    expect_error(lambda: c.send("script.canvas.input", {"canvas_id": cm_no, "mode": "select"}),
                 "invalid_state", "b: without modes, mode -> invalid_state")
    expect_error(lambda: c.send("script.canvas.input", {"canvas_id": cm_no, "mode": "instant"}),
                 "invalid_state", "b: without modes, even mode instant -> invalid_state")
    expect_error(lambda: c.send("script.canvas.input", {"canvas_id": cm_no, "polarity": "subtract"}),
                 "invalid_state", "b: without modes, polarity subtract -> invalid_state")
    expect_error(lambda: c.send("script.canvas.input", {"canvas_id": cm_no, "op": {
                     "kind": "rect", "x0": 0, "x1": 1, "y0": 100, "y1": 200, "polarity": "subtract"}}),
                 "invalid_state", "b: without modes, an op with polarity subtract -> invalid_state")
    r = c.send("script.canvas.input", {"canvas_id": cm_no, "commit": True})
    check("b: commit with nothing pending is a no-op (added false, rev and history unmoved)",
          r["added"] is False and r["committed"] is False and r["history_rev"] == 0 and r["rev"] == 0, r)

    cm = open_canvas(c, object=obj, modes=True)
    c.send("script.canvas.set_image", {"canvas_id": cm, "path": CNV, "x": X_AXIS, "y": Y_AXIS})

    def cg():
        return c.send("script.canvas.get", {"canvas_id": cm})

    def cinput(**kw):
        kw["canvas_id"] = cm
        return c.send("script.canvas.input", kw)

    def crect(x0, x1, **extra):
        op = {"kind": "rect", "x0": x0, "x1": x1, "y0": 100, "y1": 200}
        op.update(extra)
        return cinput(op=op)

    g = cg()
    check("b: modes: true -> modes, mode instant, polarity add", g["modes"] is True and g["mode"] == "instant"
          and g["polarity"] == "add", (g["modes"], g["mode"], g["polarity"]))
    expect_error(lambda: cinput(polarity="subtract"), "invalid_state", "b: polarity subtract in Instant -> invalid_state")
    expect_error(lambda: crect(0, 1, polarity="subtract"), "invalid_state", "b: an op with polarity subtract in Instant -> invalid_state")
    expect_error(lambda: cinput(mode="sideways"), "bad_params", "b: an unknown mode -> bad_params")
    expect_error(lambda: cinput(polarity="sideways"), "bad_params", "b: an unknown polarity -> bad_params")
    crect(0, 1)
    e = cg()["history"]["entries"][0]
    check("b: modes: an Instant gesture is still a step with every value",
          e["kind"] == "step" and e["params"] == ALL_VALUES and e["ops"][0]["polarity"] == "add", e)
    rev0 = cg()["rev"]
    cinput(mode="select")
    cinput(polarity="subtract")
    g = cg()
    check("b: mode and polarity move no rev", g["rev"] == rev0 and g["mode"] == "select" and g["polarity"] == "subtract"
          and g["history"]["rev"] == 1, (g["rev"], rev0, g["mode"], g["polarity"]))
    r = crect(1, 2)
    check("b: Selection: a gesture is a DRAFT (pending 1), polarity = the toggle's, history and rev move",
          r["added"] is True and r["pending"] == 1 and r["history_rev"] == 2 and r["rev"] > rev0, r)
    r = crect(2, 3, polarity="add")
    h = cg()["history"]
    d1, d2 = h["entries"][1], h["entries"][2]
    check("b: a second draft; an op's own polarity overrides the toggle's; a draft has no params and one op",
          r["pending"] == 2 and h["pending"] == 2 and h["count"] == 3 and h["cursor"] == 3
          and [d1["kind"], d2["kind"]] == ["draft", "draft"] and "params" not in d1 and len(d1["ops"]) == 1
          and d1["ops"][0]["polarity"] == "subtract" and d2["ops"][0]["polarity"] == "add"
          and d1["active_since"] == 2 and d2["active_since"] == 3, h)
    rev1 = cg()["rev"]
    cinput(values={"gain": -6})
    g = cg()
    check("b: a value change with a pending selection moves rev but NOT history.rev",
          g["rev"] > rev1 and g["history"]["rev"] == 3 and g["history"]["pending"] == 2, (g["rev"], rev1, g["history"]))
    expect_error(lambda: cinput(mode="instant"), "invalid_state", "b: mode while a selection is pending -> invalid_state")
    check("b: ... and the refused switch changed nothing", cg()["mode"] == "select")
    # undo peels the drafts one by one, then a whole step
    cinput(undo=True)
    h = cg()["history"]
    check("b: undo #1 peels the last draft alone", h["cursor"] == 2 and h["pending"] == 1 and h["count"] == 3, h)
    cinput(undo=True)
    h = cg()["history"]
    check("b: undo #2 peels the first draft", h["cursor"] == 1 and h["pending"] == 0, h)
    # (revision 6: in Selection mode an undo of an applied step REVEALS its selection instead — section i; this
    # part of the history checks the plain undo, so the hand goes back to Instant, which is allowed with nothing pending)
    cinput(mode="instant")
    cinput(undo=True)
    h = cg()["history"]
    check("b: undo #3 removes the whole applied step", h["cursor"] == 0 and h["pending"] == 0 and h["count"] == 3, h)
    cinput(mode="select")
    cinput(redo=True)
    cinput(redo=True)
    cinput(redo=True)
    h = cg()["history"]
    check("b: three redos bring the step and both drafts back", h["cursor"] == 3 and h["pending"] == 2, h)
    check("b: a redone entry's active_since is refreshed (> the draft's first)",
          h["entries"][1]["active_since"] > 2 and h["entries"][2]["active_since"] > h["entries"][1]["active_since"], h)
    rev2 = cg()["rev"]
    hrev2 = cg()["history"]["rev"]
    r = cinput(commit=True)
    g = cg()
    h = g["history"]
    st = h["entries"][1]
    check("b: commit: ONE step replaces the two drafts, ops in order, params = every value NOW",
          r["added"] is True and r["committed"] is True and r["pending"] == 0 and h["count"] == 2 and h["cursor"] == 2
          and h["pending"] == 0 and st["kind"] == "step" and len(st["ops"]) == 2
          and [o["polarity"] for o in st["ops"]] == ["subtract", "add"] and st["ops"][0]["id"] < st["ops"][1]["id"]
          and st["params"] == dict(ALL_VALUES, gain=-6), (r, h))
    check("b: the sealed ops keep their own params (gain -12 at the gesture), the step has -6 (at the seal)",
          st["ops"][0]["params"]["gain"] == -12 and st["params"]["gain"] == -6, st)
    check("b: commit moves rev and history.rev; the seal refreshes active_since",
          g["rev"] > rev2 and h["rev"] > hrev2 and st["active_since"] == h["rev"], (g["rev"], rev2, h["rev"], hrev2))
    check("b: after the seal the op traces show until the script reflects them (unreflected lists the sealed ops)",
          set(h["unreflected"]) >= {o["id"] for o in st["ops"]}, h["unreflected"])
    rev3, hrev3 = g["rev"], h["rev"]
    r = cinput(commit=True)
    g = cg()
    check("b: a second commit is a no-op (nothing pending): added false, nothing moved",
          r["added"] is False and r["committed"] is False and g["rev"] == rev3 and g["history"]["rev"] == hrev3, r)
    cinput(mode="instant")                      # revision 6: in Selection mode this undo reveals the step (section i)
    cinput(undo=True)
    h = cg()["history"]
    check("b: undo after a commit removes the WHOLE step; its drafts do not come back",
          h["cursor"] == 1 and h["count"] == 2 and h["pending"] == 0 and h["entries"][1]["kind"] == "step", h)
    cinput(redo=True)
    h = cg()["history"]
    check("b: redo brings the step back whole", h["cursor"] == 2 and len(h["entries"][1]["ops"]) == 2, h)
    cinput(undo=True)
    cinput(mode="select")
    r = crect(4, 5)
    h = cg()["history"]
    check("b: a new draft drops the redo tail (the undone commit); entry ids stay monotonic",
          h["count"] == 2 and h["pending"] == 1 and [e["id"] for e in h["entries"]] == [1, 5], h)
    rev4 = cg()["rev"]
    r = cinput(discard=True)
    g = cg()
    h = g["history"]
    check("b: discard throws the pending selection away (nothing to redo), moves rev",
          r["discarded"] is True and r["pending"] == 0 and h["count"] == 1 and h["cursor"] == 1 and h["pending"] == 0
          and g["rev"] > rev4, (r, h))
    r = cinput(discard=True)
    check("b: discard with nothing pending is a no-op", r["discarded"] is False)
    cinput(mode="instant")
    g = cg()
    check("b: back to Instant once nothing is pending; the polarity toggle returns to add",
          g["mode"] == "instant" and g["polarity"] == "add", (g["mode"], g["polarity"]))
    cinput(mode="select")
    crect(6, 7)
    expect_error(lambda: cinput(mode="instant"), "invalid_state", "b: mode refused again with a new pending draft")
    cinput(commit=True)
    cinput(mode="instant")
    cinput(mode="instant")                      # same mode: no-op, never an error
    check("b: switching to the mode already held is a no-op", cg()["mode"] == "instant")

    # -- layers and reflection -------------------------------------------------------------
    cid = open_canvas(c, object=obj)
    c.send("script.canvas.set_image", {"canvas_id": cid, "path": CNV, "x": X_AXIS, "y": Y_AXIS})
    a = rect(0, 1)["history_rev"]
    b2 = rect(1, 2)["history_rev"]
    check("b: after ops 1 and 2: both traces are visible", hist()["unreflected"] == [1, 2], hist())
    r = c.send("script.canvas.set_layer", {"canvas_id": cid, "layer": "tint", "path": RGB, "z": 1, "history_rev": a})
    check("b: an RGB1 layer is listed (size, z, opacity, history_rev)",
          r["layers"] == [{"layer": "tint", "path": RGB, "width": 8, "height": 4, "z": 1, "opacity": 1, "history_rev": a}], r)
    check("b: a layer reflecting op 1 hides its trace -> unreflected = [2]", hist()["unreflected"] == [2], hist())
    check("b: get lists the layer", [l["layer"] for l in c.send("script.canvas.get", {"canvas_id": cid})["layers"]] == ["tint"])
    c.send("script.canvas.set_layer", {"canvas_id": cid, "layer": "tint", "path": RGB, "history_rev": b2})
    check("b: a layer at the current rev -> unreflected = []", hist()["unreflected"] == [], hist())
    c.send("script.canvas.input", {"canvas_id": cid, "undo": True})
    check("b: undo: the undone op has no trace; the layer still shows it until the script answers",
          hist()["unreflected"] == [], hist())
    c.send("script.canvas.input", {"canvas_id": cid, "redo": True})
    check("b: redo of op 2 -> its trace is back (the entry's active_since refreshed)", hist()["unreflected"] == [2], hist())
    r = c.send("script.canvas.set_layer", {"canvas_id": cid, "layer": "tint", "path": RGB2, "opacity": 0.5})
    check("b: replacing a layer keeps its z, takes the opacity, history_rev as given (none)",
          r["layers"] == [{"layer": "tint", "path": RGB2, "width": 2, "height": 2, "z": 1, "opacity": 0.5, "history_rev": None}], r)
    check("b: a layer with no history_rev reflects nothing", hist()["unreflected"] == [1, 2], hist())
    # revision 4: the BASE image itself can reflect the history (the script redraws the spectrogram)
    c.send("script.canvas.set_image", {"canvas_id": cid, "path": CNV, "x": X_AXIS, "y": Y_AXIS, "history_rev": a})
    g = c.send("script.canvas.get", {"canvas_id": cid})
    check("b: set_image history_rev: the base image reflecting op 1 hides its trace; get shows image.history_rev",
          hist()["unreflected"] == [2] and g["image"]["history_rev"] == a, (hist(), g["image"]))
    c.send("script.canvas.set_image", {"canvas_id": cid, "path": CNV, "x": X_AXIS, "y": Y_AXIS, "history_rev": hist()["rev"]})
    check("b: ... at the current rev every trace is hidden", hist()["unreflected"] == [], hist())
    c.send("script.canvas.set_image", {"canvas_id": cid, "path": CNV, "x": X_AXIS, "y": Y_AXIS})
    g = c.send("script.canvas.get", {"canvas_id": cid})
    check("b: a set_image with no history_rev reflects nothing again (image.history_rev null)",
          hist()["unreflected"] == [1, 2] and g["image"]["history_rev"] is None, (hist(), g["image"]))
    expect_error(lambda: c.send("script.canvas.set_image", {"canvas_id": cid, "path": CNV, "x": X_AXIS, "y": Y_AXIS, "history_rev": "x"}),
                 "bad_params", "b: set_image: a non-integer history_rev -> bad_params")
    c.send("script.canvas.set_layer", {"canvas_id": cid, "layer": "a", "path": RGB, "z": 5})
    r = c.send("script.canvas.set_layer", {"canvas_id": cid, "layer": "b", "path": RGB, "z": 0})
    check("b: layers are listed in ascending z", [l["layer"] for l in r["layers"]] == ["b", "tint", "a"], r)
    expect_error(lambda: c.send("script.canvas.set_layer", {"canvas_id": cid, "layer": "x", "path": RGB, "opacity": 2}),
                 "bad_params", "b: opacity above 1 -> bad_params")
    expect_error(lambda: c.send("script.canvas.set_layer", {"canvas_id": cid, "layer": "x", "path": os.path.join(ROOT, "no.objkrgb")}),
                 "not_found", "b: a missing layer file -> not_found")
    expect_error(lambda: c.send("script.canvas.set_layer", {"canvas_id": cid, "layer": "x", "path": junk}),
                 "bad_params", "b: a layer no reader knows -> bad_params")
    expect_error(lambda: c.send("script.canvas.set_layer", {"canvas_id": cid, "layer": "", "path": RGB}),
                 "bad_params", "b: an empty layer id -> bad_params")
    for i in range(5):
        c.send("script.canvas.set_layer", {"canvas_id": cid, "layer": "f%d" % i, "path": RGB})
    expect_error(lambda: c.send("script.canvas.set_layer", {"canvas_id": cid, "layer": "ninth", "path": RGB}),
                 "bad_params", "b: a ninth layer -> bad_params")
    r = c.send("script.canvas.set_layer", {"canvas_id": cid, "layer": "f0", "path": None})
    check("b: path null removes a layer", "f0" not in [l["layer"] for l in r["layers"]] and len(r["layers"]) == 7, r)
    c.send("script.canvas.set_image", {"canvas_id": cid, "path": CNV, "x": X_AXIS, "y": Y_AXIS})
    check("b: the same axes keep the layers", len(c.send("script.canvas.get", {"canvas_id": cid})["layers"]) == 7)
    c.send("script.canvas.input", {"canvas_id": cid, "view": {"x0": 2, "x1": 4, "y0": 100, "y1": 1000}})
    v = c.send("script.canvas.get", {"canvas_id": cid})["view"]
    check("b: view (data units) is applied without moving rev", v["x0"] == 2 and v["x1"] == 4
          and abs(v["y0"] - 100) < 1e-6 and abs(v["y1"] - 1000) < 1e-6, v)
    c.send("script.canvas.set_image", {"canvas_id": cid, "path": CNV, "x": X_AXIS, "y": Y_AXIS})
    check("b: the same axes keep the view", c.send("script.canvas.get", {"canvas_id": cid})["view"]["x0"] == 2)
    c.send("script.canvas.set_image", {"canvas_id": cid, "path": CNV, "x": {"min": 0, "max": 20, "unit": "s"}, "y": Y_AXIS})
    g = c.send("script.canvas.get", {"canvas_id": cid})
    check("b: a world change drops the layers and refits the view",
          g["layers"] == [] and g["view"]["x0"] == 0 and g["view"]["x1"] == 20, g["view"])
    c.send("script.canvas.input", {"canvas_id": cid, "view": {"x0": -5, "x1": 100, "y0": 1, "y1": 99999}})
    v = c.send("script.canvas.get", {"canvas_id": cid})["view"]
    check("b: a view beyond the world is clamped to it", v["x0"] == 0 and v["x1"] == 20
          and abs(v["y0"] - 20) < 1e-6 and abs(v["y1"] - 24000) < 1e-3, v)
    expect_error(lambda: c.send("script.canvas.input", {"canvas_id": cid, "view": {"x0": 3, "x1": 2, "y0": 100, "y1": 200}}),
                 "bad_params", "b: a view with x0 >= x1 -> bad_params")
    c.send("script.canvas.set_image", {"canvas_id": cid, "path": CNV, "x": X_AXIS, "y": Y_AXIS})

    # -- rev, wait, known_history_rev ------------------------------------------------------
    g = c.send("script.canvas.get", {"canvas_id": cid})
    rev = g["rev"]
    c.send("script.canvas.update", {"canvas_id": cid, "status": "Working", "busy": True, "values": {"prog": 0.5}})
    g = c.send("script.canvas.get", {"canvas_id": cid})
    check("b: update never moves rev, and writes status, busy and a progress",
          g["rev"] == rev and g["status"] == "Working" and g["busy"] is True and g["values"]["prog"] == 0.5, g)
    c.send("script.canvas.update", {"canvas_id": cid, "labels": {"go": "Again"}})
    expect_error(lambda: c.send("script.canvas.update", {"canvas_id": cid, "labels": {"nope": "x"}}),
                 "bad_params", "b: update: labels name a known control")
    r, dt = timed(lambda: c.send("script.canvas.wait", {"canvas_id": cid, "since_rev": rev, "timeout_ms": 300}))
    check("b: wait times out at its budget with rev unchanged", r["rev"] == rev and 0.2 < dt < 1.5, (r["rev"], dt))
    c.send("script.canvas.input", {"canvas_id": cid, "values": {"gain": -3}})
    r, dt = timed(lambda: c.send("script.canvas.wait", {"canvas_id": cid, "since_rev": rev, "timeout_ms": 3000}))
    check("b: values move rev; a wait on the old rev returns at once with them",
          r["rev"] > rev and dt < 0.5 and r["values"]["gain"] == -3, (r["rev"], dt))
    # a wait woken from another connection while this one is blocked
    rev = r["rev"]
    woke = {}

    def waiter():
        with ObjekatClient(SOCK, timeout=30) as c2:
            woke["r"], woke["dt"] = timed(lambda: c2.send("script.canvas.wait", {"canvas_id": cid, "since_rev": rev, "timeout_ms": 4000}))

    th = threading.Thread(target=waiter)
    th.start()
    time.sleep(0.4)
    c.send("script.canvas.input", {"canvas_id": cid, "op": {"kind": "rect", "x0": 0, "x1": 1, "y0": 100, "y1": 200}})
    th.join(10)
    check("b: a wait is woken by the hand (an op) from another connection",
          "r" in woke and woke["r"]["rev"] > rev and 0.3 < woke["dt"] < 2.5, woke)
    h_rev = c.send("script.canvas.get", {"canvas_id": cid})["history"]["rev"]
    g = c.send("script.canvas.get", {"canvas_id": cid, "known_history_rev": h_rev})
    check("b: known_history_rev == history.rev omits the entries, keeps the rest",
          "entries" not in g["history"] and g["history"]["rev"] == h_rev and "unreflected" in g["history"]
          and "pending" in g["history"], g["history"])
    g = c.send("script.canvas.get", {"canvas_id": cid, "known_history_rev": h_rev - 1})
    check("b: another known_history_rev keeps the entries", "entries" in g["history"])
    r = c.send("script.canvas.wait", {"canvas_id": cid, "since_rev": 10 ** 6, "timeout_ms": 50, "known_history_rev": h_rev})
    check("b: wait honours known_history_rev", "entries" not in r["history"])
    c.send("script.canvas.input", {"canvas_id": cid, "press": "go"})
    g = c.send("script.canvas.get", {"canvas_id": cid})
    check("b: a button press is an event, read once", g["events"] == [{"button": "go"}]
          and c.send("script.canvas.get", {"canvas_id": cid})["events"] == [])
    expect_error(lambda: c.send("script.canvas.input", {"canvas_id": cid, "press": "nope"}),
                 "bad_params", "b: an unknown button is refused")
    expect_error(lambda: c.send("script.canvas.input", {"canvas_id": cid, "press": "reset"}),
                 "bad_params", "b: reset is refused on a canvas that does not remember")

    # -- audio and transport ---------------------------------------------------------------
    cid = open_canvas(c, object=obj)
    c.send("script.canvas.set_image", {"canvas_id": cid, "path": CNV, "x": X_AXIS, "y": Y_AXIS})
    expect_error(lambda: c.send("script.canvas.input", {"canvas_id": cid, "play": True}),
                 "invalid_state", "b: play with no original -> invalid_state")
    expect_error(lambda: c.send("script.canvas.set_audio", {"canvas_id": cid, "original": os.path.join(ROOT, "no.wav")}),
                 "not_found", "b: set_audio: a missing file -> not_found")
    expect_error(lambda: c.send("script.canvas.set_audio", {"canvas_id": cid, "original": junk}),
                 "bad_params", "b: set_audio: an unreadable file -> bad_params")
    r = c.send("script.canvas.set_audio", {"canvas_id": cid, "original": WAV3, "history_rev": 0})
    check("b: set_audio reports slots and durations",
          r["slots"] == {"original": WAV3, "result": None, "delta": None}
          and abs(r["durations"]["original"] - 3.0) < 1e-6 and r["playing"] is False and r["caret"] == 0, r)
    check("b: audio_history_rev is stored",
          c.send("script.canvas.get", {"canvas_id": cid})["transport"]["audio_history_rev"] == 0)
    # revision 4: set_audio {listen} chooses the slot heard, with the files it brings
    expect_error(lambda: c.send("script.canvas.set_audio", {"canvas_id": cid, "listen": "result"}),
                 "invalid_state", "b: set_audio listen on an empty slot -> invalid_state")
    expect_error(lambda: c.send("script.canvas.set_audio", {"canvas_id": cid, "result": WAV3, "listen": "sideways"}),
                 "bad_params", "b: set_audio: an unknown listen -> bad_params")
    check("b: ... and a refused call stored nothing",
          c.send("script.canvas.get", {"canvas_id": cid})["transport"]["slots"]["result"] is None)
    r = c.send("script.canvas.set_audio", {"canvas_id": cid, "result": WAV3, "listen": "result"})
    t = c.send("script.canvas.get", {"canvas_id": cid})["transport"]
    check("b: set_audio listen result with the file: the slot is heard at once", t["listen"] == "result" and t["slots"]["result"] == WAV3, t)
    c.send("script.canvas.set_audio", {"canvas_id": cid, "result": None})
    t = c.send("script.canvas.get", {"canvas_id": cid})["transport"]
    check("b: clearing the heard result still falls back to the original", t["listen"] == "original", t)
    expect_error(lambda: c.send("script.canvas.input", {"canvas_id": cid, "listen": "result"}),
                 "invalid_state", "b: listen on an empty slot -> invalid_state")
    expect_error(lambda: c.send("script.canvas.input", {"canvas_id": cid, "listen": "delta"}),
                 "invalid_state", "b: listen delta without a delta slot -> invalid_state")
    expect_error(lambda: c.send("script.canvas.input", {"canvas_id": cid, "listen": "sideways"}),
                 "bad_params", "b: an unknown listen value -> bad_params")
    c.send("script.canvas.set_audio", {"canvas_id": cid, "result": WAV3, "delta": WAV1, "history_rev": 0})
    c.send("script.canvas.input", {"canvas_id": cid, "values": {"gain": -6}})
    # project transport, then canvas play: the project must end up stopped
    c.send("transport.play")
    pstate = c.send("transport.state").get("playing")
    c.send("script.canvas.input", {"canvas_id": cid, "play": True})
    check("b: canvas play stops the PROJECT's transport (it was %s)" % pstate,
          c.send("transport.state").get("playing") is False)
    p0 = c.send("script.canvas.get", {"canvas_id": cid})["transport"]
    time.sleep(0.3)
    p1 = c.send("script.canvas.get", {"canvas_id": cid})["transport"]
    check("b: playing: the position advances (>= 0.2 s after 0.3 s), the caret stays",
          p1["playing"] is True and p1["position"] - p0["position"] >= 0.2 and p1["caret"] == 0, (p0, p1))
    pos_before = c.send("script.canvas.get", {"canvas_id": cid})["transport"]["position"]
    c.send("script.canvas.input", {"canvas_id": cid, "listen": "result"})
    t = c.send("script.canvas.get", {"canvas_id": cid})["transport"]
    check("b: switching to result keeps the position (< 0.05 s drift) and keeps playing",
          t["listen"] == "result" and t["playing"] is True and 0 <= t["position"] - pos_before < 0.25, (pos_before, t))
    pos_before = c.send("script.canvas.get", {"canvas_id": cid})["transport"]["position"]
    c.send("script.canvas.input", {"canvas_id": cid, "listen": "delta"})
    t = c.send("script.canvas.get", {"canvas_id": cid})["transport"]
    check("b: listen delta (the third state of the one switch): no restart, still playing, no `delta` field",
          t["listen"] == "delta" and t["playing"] is True and "delta" not in t and 0 <= t["position"] - pos_before < 0.25, t)
    c.send("script.canvas.input", {"canvas_id": cid, "seek": 2.0})
    t = c.send("script.canvas.get", {"canvas_id": cid})["transport"]
    check("b: seek while playing jumps there and moves the caret",
          t["caret"] == 2.0 and 2.0 <= t["position"] < 2.3 and t["playing"] is True, t)
    c.send("script.canvas.input", {"canvas_id": cid, "play": False})
    t = c.send("script.canvas.get", {"canvas_id": cid})["transport"]
    check("b: STOP returns the position to the caret", t["playing"] is False and t["position"] == 2.0 and t["caret"] == 2.0, t)
    c.send("script.canvas.input", {"canvas_id": cid, "seek": 1.25})
    t = c.send("script.canvas.get", {"canvas_id": cid})["transport"]
    check("b: seek while stopped sets the caret and the position", t["caret"] == 1.25 and t["position"] == 1.25, t)
    c.send("script.canvas.input", {"canvas_id": cid, "seek": 99})
    check("b: seek is clamped to the longest slot", c.send("script.canvas.get", {"canvas_id": cid})["transport"]["caret"] == 3.0)
    c.send("script.canvas.input", {"canvas_id": cid, "seek": -4})
    check("b: seek is clamped at 0", c.send("script.canvas.get", {"canvas_id": cid})["transport"]["caret"] == 0.0)
    # running past the end is a stop, back on the caret
    c.send("script.canvas.set_audio", {"canvas_id": cid, "original": WAV1, "result": None, "delta": None})
    t = c.send("script.canvas.get", {"canvas_id": cid})["transport"]
    check("b: clearing the heard slot (delta) falls back to the original",
          t["listen"] == "original" and t["slots"]["result"] is None and t["slots"]["delta"] is None, t)
    c.send("script.canvas.set_audio", {"canvas_id": cid, "result": WAV1})
    c.send("script.canvas.input", {"canvas_id": cid, "listen": "result"})
    c.send("script.canvas.set_audio", {"canvas_id": cid, "delta": WAV1})
    check("b: clearing a slot that is NOT heard leaves listen alone",
          c.send("script.canvas.get", {"canvas_id": cid})["transport"]["listen"] == "result")
    c.send("script.canvas.set_audio", {"canvas_id": cid, "result": None, "delta": None})
    check("b: clearing the heard result falls back to the original",
          c.send("script.canvas.get", {"canvas_id": cid})["transport"]["listen"] == "original")
    c.send("script.canvas.input", {"canvas_id": cid, "seek": 0.2})
    c.send("script.canvas.input", {"canvas_id": cid, "play": True})
    time.sleep(1.3)
    t = c.send("script.canvas.get", {"canvas_id": cid})["transport"]
    check("b: running past the end stops, the position back on the caret",
          t["playing"] is False and t["position"] == 0.2 and t["caret"] == 0.2, t)
    c.send("script.canvas.input", {"canvas_id": cid, "play": True})
    c.send("script.canvas.set_audio", {"canvas_id": cid, "original": None})
    t = c.send("script.canvas.get", {"canvas_id": cid})["transport"]
    check("b: clearing the original stops playback", t["playing"] is False and t["slots"]["original"] is None, t)
    c.send("script.canvas.set_audio", {"canvas_id": cid, "original": WAV3, "offset": 1.5})
    c.send("script.canvas.input", {"canvas_id": cid, "seek": 99})
    check("b: the end of the transport follows the offset (offset + duration)",
          abs(c.send("script.canvas.get", {"canvas_id": cid})["transport"]["caret"] - 4.5) < 1e-6)

    # -- remember (live, revision 4) -------------------------------------------------------
    key = "spectral-editor.scenario.b"
    cr = open_canvas(c, remember=key, modes=True)
    g0 = c.send("script.canvas.get", {"canvas_id": cr})
    check("b: a first opening of a remembering canvas shows the declared values, Instant, the first tool",
          g0["values"]["gain"] == -12 and g0["remember"] == key and g0["mode"] == "instant" and g0["tool"] == "rect", g0["values"])
    c.send("script.canvas.input", {"canvas_id": cr, "values": {"gain": -33, "hardness": 80}})
    c.send("script.canvas.input", {"canvas_id": cr, "tool": "brush"})
    c.send("script.canvas.input", {"canvas_id": cr, "mode": "select"})
    c.send("script.canvas.input", {"canvas_id": cr, "press": "cancel"})
    cr = open_canvas(c, remember=key, modes=True)
    v = c.send("script.canvas.get", {"canvas_id": cr})
    check("b: values, tool and mode are remembered LIVE: even a Cancel keeps them",
          v["values"]["gain"] == -33 and v["values"]["hardness"] == 80 and v["tool"] == "brush" and v["mode"] == "select",
          (v["values"], v["tool"], v["mode"]))
    check("b: the history is not remembered (a fresh one)", v["history"]["count"] == 0 and v["history"]["pending"] == 0)
    c.send("script.canvas.input", {"canvas_id": cr, "values": {"gain": -7}})
    c.send("script.canvas.input", {"canvas_id": cr, "press": "validate"})
    check("b: Validate ends the canvas", c.send("script.canvas.get", {"canvas_id": cr})["state"] == "validated")
    expect_error(lambda: c.send("script.canvas.input", {"canvas_id": cr, "values": {"gain": 1}}),
                 "invalid_state", "b: input on a validated canvas -> invalid_state")
    expect_error(lambda: c.send("script.canvas.set_image", {"canvas_id": cr, "path": CNV, "x": X_AXIS, "y": Y_AXIS}),
                 "invalid_state", "b: set_image on a canvas that is not open -> invalid_state")
    cr = open_canvas(c, remember=key, modes=True)
    g = c.send("script.canvas.get", {"canvas_id": cr})
    check("b: a re-open shows the last values, tool and mode", g["values"]["gain"] == -7 and g["values"]["hardness"] == 80
          and g["tool"] == "brush" and g["mode"] == "select", (g["values"], g["tool"], g["mode"]))
    cr2 = open_canvas(c, remember=key)
    g = c.send("script.canvas.get", {"canvas_id": cr2})
    check("b: a canvas WITHOUT modes does not take a remembered mode",
          g["mode"] == "instant" and g["tool"] == "brush" and g["values"]["gain"] == -7, (g["mode"], g["tool"]))
    cr3 = open_canvas(c, remember=key, modes=True, tools=[TOOLS[0]])
    g = c.send("script.canvas.get", {"canvas_id": cr3})
    check("b: a remembered tool the canvas no longer declares is ignored (the first tool stays)", g["tool"] == "rect", g["tool"])
    cr = open_canvas(c, remember=key, modes=True)
    rv = c.send("script.canvas.get", {"canvas_id": cr})["rev"]
    c.send("script.canvas.input", {"canvas_id": cr, "press": "reset"})
    g = c.send("script.canvas.get", {"canvas_id": cr})
    check("b: reset restores the declared values and moves rev", g["values"]["gain"] == -12 and g["values"]["hardness"] == 50
          and g["rev"] > rv, g["values"])
    check("b: reset leaves the tool and the mode where they are", g["tool"] == "brush" and g["mode"] == "select", (g["tool"], g["mode"]))
    c.send("script.canvas.input", {"canvas_id": cr, "press": "cancel"})
    cr = open_canvas(c, remember=key, modes=True)
    g = c.send("script.canvas.get", {"canvas_id": cr})
    check("b: reset erased the values' memory (not the tool/mode's)",
          g["values"]["gain"] == -12 and g["tool"] == "brush" and g["mode"] == "select")
    c.send("script.canvas.close", {"canvas_id": cr})
    cr = open_canvas(c, remember=key + ".other", modes=True)
    g = c.send("script.canvas.get", {"canvas_id": cr})
    check("b: another key remembers nothing of it", g["tool"] == "rect" and g["mode"] == "instant" and g["values"]["gain"] == -12)
    c.send("script.canvas.close", {"canvas_id": cr})

    # -- a number with `presets` (revision 6b): a row of buttons, every value snapped to the nearest ---------
    PRESETS = [-60, -24, -12, -6, -3, 3]

    def gain_control(**kw):
        ctl = {"id": "g", "kind": "number", "label": "Gain", "min": -60, "max": 12, "step": 0.5, "unit": "dB",
               "presets": PRESETS}
        ctl.update(kw)
        return ctl

    def with_ctl(*ctls, **kw):
        return c.send("script.canvas.open", dict({"title": "Presets", "controls": list(ctls), "tools": []}, **kw))["canvas_id"]

    def val(cp):
        return c.send("script.canvas.get", {"canvas_id": cp})["values"]

    cp = with_ctl(gain_control(value=-12))
    check("b: presets: the declared value (a preset) is the default", val(cp)["g"] == -12, val(cp))
    c.send("script.canvas.close", {"canvas_id": cp})
    cp = with_ctl(gain_control())
    check("b: presets: with no value the first preset is the default", val(cp)["g"] == -60, val(cp))
    for given, want in ((-7, -6), (-6, -6), (99, 3), (-99, -60), (-9, -12), (-43, -60), (0, -3), (3, 3)):
        c.send("script.canvas.input", {"canvas_id": cp, "values": {"g": given}})
        check("b: presets: input %s is snapped to %s (nearest; a tie goes to the first listed)" % (given, want),
              val(cp)["g"] == want, val(cp))
    c.send("script.canvas.update", {"canvas_id": cp, "values": {"g": -33}})
    check("b: presets: update snaps too (-33 -> -24)", val(cp)["g"] == -24, val(cp))
    rv = c.send("script.canvas.get", {"canvas_id": cp})["rev"]
    c.send("script.canvas.input", {"canvas_id": cp, "values": {"g": -3}})
    check("b: presets: a click moves rev once", c.send("script.canvas.get", {"canvas_id": cp})["rev"] > rv)
    expect_error(lambda: c.send("script.canvas.input", {"canvas_id": cp, "values": {"g": "loud"}}),
                 "bad_params", "b: presets: a non-number is refused")
    c.send("script.canvas.close", {"canvas_id": cp})
    for label, ctl in (("an empty list", gain_control(presets=[])),
                       ("a preset out of min…max", gain_control(presets=[-60, 13])),
                       ("a duplicate", gain_control(presets=[-6, -6])),
                       ("a list that is not numbers", gain_control(presets=["a"])),
                       ("presets that are not a list", gain_control(presets=-6)),
                       ("a value that is not a preset", gain_control(value=-7)),
                       ("presets on a bool", {"id": "b", "kind": "bool", "label": "B", "presets": [1]})):
        expect_error(lambda: with_ctl(ctl), "bad_params", "b: presets: open refuses " + label)
    kp = "spectral-editor.scenario.b.presets"
    cp = with_ctl(gain_control(value=-12), remember=kp)
    c.send("script.canvas.input", {"canvas_id": cp, "values": {"g": -24}})
    c.send("script.canvas.input", {"canvas_id": cp, "press": "cancel"})
    cp = with_ctl(gain_control(value=-12), remember=kp)
    check("b: presets: a remembered preset comes back", val(cp)["g"] == -24, val(cp))
    c.send("script.canvas.close", {"canvas_id": cp})
    ks = kp + ".slider"
    cp = with_ctl({"id": "g", "kind": "number", "label": "Gain", "min": -60, "max": 12, "step": 0.5,
                   "value": -12, "unit": "dB"}, remember=ks)
    c.send("script.canvas.input", {"canvas_id": cp, "values": {"g": -7}})
    c.send("script.canvas.input", {"canvas_id": cp, "press": "cancel"})
    cp = with_ctl(gain_control(value=-12, max=3), remember=ks)
    check("b: presets: a value remembered as a slider's (-7) is snapped to the nearest preset (-6)",
          val(cp)["g"] == -6, val(cp))
    c.send("script.canvas.close", {"canvas_id": cp})
    cp = with_ctl({"id": "g", "kind": "number", "label": "Gain", "min": -60, "max": 12, "step": 0.5,
                   "value": -12, "unit": "dB"}, remember=ks)
    c.send("script.canvas.input", {"canvas_id": cp, "values": {"g": 11.5}})
    c.send("script.canvas.input", {"canvas_id": cp, "press": "cancel"})
    cp = with_ctl(gain_control(value=-12, max=3), remember=ks)
    check("b: presets: a remembered value outside the new range (+11.5) is snapped too (+3)",
          val(cp)["g"] == 3, val(cp))
    c.send("script.canvas.input", {"canvas_id": cp, "press": "reset"})
    check("b: presets: reset gives back the declared preset", val(cp)["g"] == -12, val(cp))
    c.send("script.canvas.close", {"canvas_id": cp})

    # -- no trace in the project -----------------------------------------------------------
    cid = open_canvas(c, object=obj)
    c.send("script.canvas.set_image", {"canvas_id": cid, "path": CNV, "x": X_AXIS, "y": Y_AXIS})
    c.send("project.new")
    obj = c.send("object.add", {"path": WAV3, "lane": 0, "start": 0.0})["id"]
    dirty0 = c.send("app.info").get("is_dirty")
    cid = open_canvas(c, object=obj)
    c.send("script.canvas.set_image", {"canvas_id": cid, "path": CNV, "x": X_AXIS, "y": Y_AXIS})
    c.send("script.canvas.input", {"canvas_id": cid, "values": {"gain": -1},
                                   "op": {"kind": "rect", "x0": 0, "x1": 1, "y0": 100, "y1": 200}})
    c.send("script.canvas.set_layer", {"canvas_id": cid, "layer": "tint", "path": RGB})
    c.send("script.canvas.set_audio", {"canvas_id": cid, "original": WAV1})
    check("b: the project is not dirtied by a canvas", c.send("app.info").get("is_dirty") == dirty0)
    c.send("object.set_fade", {"id": obj, "in": 0.05, "out": 0.05})
    c.send("edit.undo")
    g = c.send("script.canvas.get", {"canvas_id": cid})
    check("b: edit.undo leaves the canvas alone (ops, layers, audio, state)",
          g["state"] == "open" and g["history"]["count"] == 1 and len(g["layers"]) == 1
          and g["transport"]["slots"]["original"] == WAV1, g["history"])

    # -- lifetime --------------------------------------------------------------------------
    c.send("script.canvas.close", {"canvas_id": cid})
    check("b: close -> state closed", c.send("script.canvas.get", {"canvas_id": cid})["state"] == "closed")
    expect_error(lambda: c.send("script.canvas.close", {"canvas_id": "00000000-0000-0000-0000-000000000000"}),
                 "not_found", "b: close: unknown canvas")
    expect_error(lambda: c.send("script.canvas.get", {"canvas_id": "00000000-0000-0000-0000-000000000000"}),
                 "not_found", "b: get: unknown canvas")
    cid = open_canvas(c, object=obj)
    c.send("object.remove", {"ids": [obj]})
    c.send("script.canvas.list")
    check("b: removing the object closes the canvas", c.send("script.canvas.get", {"canvas_id": cid})["state"] == "closed")
    with ObjekatClient(SOCK, timeout=30) as c3:
        other = c3.send("script.canvas.open", {"title": "other", "tools": []})["canvas_id"]
        check("b: a canvas is visible from another connection",
              other in [x["canvas_id"] for x in c.send("script.canvas.list")["canvases"]])
    time.sleep(0.5)
    check("b: closing the owner's connection removes its canvas",
          other not in [x["canvas_id"] for x in c.send("script.canvas.list")["canvases"]], c.send("script.canvas.list"))
    c.send("project.new")
    obj = c.send("object.add", {"path": WAV3, "lane": 0, "start": 0.0})["id"]
    cid = open_canvas(c, object=obj)
    c.send("script.canvas.set_image", {"canvas_id": cid, "path": CNV, "x": X_AXIS, "y": Y_AXIS})
    c.send("script.canvas.set_audio", {"canvas_id": cid, "original": WAV3})
    c.send("script.canvas.input", {"canvas_id": cid, "play": True})
    c.send("project.new")
    g = c.send("script.canvas.get", {"canvas_id": cid})
    check("b: project.new closes the canvas, and its playback with it",
          g["state"] == "closed" and g["transport"]["playing"] is False, g["state"])
    expect_error(lambda: c.send("script.canvas.input", {"canvas_id": cid, "values": {"gain": 1}}),
                 "invalid_state", "b: input on a closed canvas -> invalid_state")

# ---------------------------------------------------------------------------------------------
# c, d, e. The script, end to end
# ---------------------------------------------------------------------------------------------

SG_DIR = os.path.join(HERE, "scripts", "spectral-editor")
VENV_PY = os.path.expanduser("~/Library/Application Support/Objekat/venvs/spectral-editor/bin/python3")


def venv_ok():
    if not os.access(VENV_PY, os.X_OK):
        return False
    return subprocess.run([VENV_PY, "-c", "import numpy"], capture_output=True).returncode == 0


def make_tones_wav(path, seconds, rate, tones, depth=24, channels=1, right_tones=None):
    """A wav (16 or 24 bit PCM) of summed sines {Hz: amplitude}. `channels` 2 writes the same signal on
    both sides unless `right_tones` is given (then the right side carries those)."""
    frames = int(round(seconds * rate))
    scale = 2 ** (depth - 1) - 1
    raw = bytearray()
    for i in range(frames):
        l = sum(a * math.sin(2 * math.pi * f * i / rate) for f, a in tones.items())
        r = l if right_tones is None else sum(a * math.sin(2 * math.pi * f * i / rate) for f, a in right_tones.items())
        for v in ((l,) if channels == 1 else (l, r)):
            q = int(round(v * scale))
            raw += struct.pack("<h", q) if depth == 16 else struct.pack("<i", q)[0:3]
    with wave.open(path, "wb") as w:
        w.setnchannels(channels)
        w.setsampwidth(depth // 8)
        w.setframerate(rate)
        w.writeframes(bytes(raw))
    return path


def read_wav_any(path):
    """(rate, bits, is_float, [one list of floats per channel]) for PCM 16 / 24 / 32 and float 32 wavs."""
    data = open(path, "rb").read()
    assert data[:4] == b"RIFF" and data[8:12] == b"WAVE", "not a wav: " + path
    pos, fmt, pcm = 12, None, None
    while pos + 8 <= len(data):
        cid, size = data[pos:pos + 4], struct.unpack("<I", data[pos + 4:pos + 8])[0]
        body = pos + 8
        if cid == b"fmt ":
            tag, ch, rate, _br, _al, bits = struct.unpack("<HHIIHH", data[body:body + 16])
            if tag == 0xFFFE:
                tag = struct.unpack("<H", data[body + 24:body + 26])[0]
            fmt = (tag, ch, rate, bits)
        elif cid == b"data":
            pcm = data[body:body + size]
            break
        pos = body + size + (size & 1)
    tag, ch, rate, bits = fmt
    n = len(pcm) // (ch * bits // 8)
    if tag == 3:
        import array
        a = array.array("f")
        a.frombytes(pcm[:n * ch * 4])
        flat = list(a)
    elif bits == 16:
        flat = [v / 32768.0 for v in struct.unpack("<%dh" % (n * ch), pcm[:n * ch * 2])]
    elif bits == 24:
        flat = []
        for i in range(0, n * ch * 3, 3):
            v = pcm[i] | (pcm[i + 1] << 8) | (pcm[i + 2] << 16)
            flat.append((v - (1 << 24) if v & 0x800000 else v) / 8388608.0)
    else:
        flat = [v / 2147483648.0 for v in struct.unpack("<%di" % (n * ch), pcm[:n * ch * 4])]
    return rate, bits, tag == 3, [flat[c::ch] for c in range(ch)]


def goertzel_db(x, rate, f, t0=None, t1=None):
    """Amplitude in dB (re 1.0 = full scale peak) of the component at f Hz over [t0, t1] s, Hann-windowed."""
    a = 0 if t0 is None else int(t0 * rate)
    b = len(x) if t1 is None else int(t1 * rate)
    seg = x[a:b]
    n = len(seg)
    coeff = 2.0 * math.cos(2 * math.pi * f / rate)
    s1 = s2 = 0.0
    for i, v in enumerate(seg):
        w = 0.5 - 0.5 * math.cos(2 * math.pi * i / n)
        s0 = v * w + coeff * s1 - s2
        s2, s1 = s1, s0
    power = s1 * s1 + s2 * s2 - coeff * s1 * s2
    return 10 * math.log10(max(power * 4.0 / ((n * 0.5) ** 2), 1e-30))


def read_rgb_pixel(path, col, row):
    """RGBA of one pixel of an OBJKRGB1 file, 0...255 each."""
    with open(path, "rb") as f:
        head = f.read(24)
        assert head[:8] == b"OBJKRGB1", head[:8]
        w, h = struct.unpack("<II", head[8:16])
        col, row = min(w - 1, max(0, col)), min(h - 1, max(0, row))
        f.seek(24 + 4 * (row * w + col))
        return tuple(f.read(4))


def layer_alpha(layer, world, t, hz):
    """The alpha (0...1) of an RGB layer at time t s and frequency hz, from a `layers` entry and the `world`."""
    x, y = world["x"], world["y"]
    col = int((t - x["min"]) / (x["max"] - x["min"]) * layer["width"])
    row = int((math.log2(y["max"]) - math.log2(hz)) / (math.log2(y["max"]) - math.log2(y["min"])) * layer["height"])
    return read_rgb_pixel(layer["path"], col, row)[3] / 255.0


def image_db(path, world, t, hz):
    """The level (dB) of the BASE image (an OBJKCNV1) at time t s and frequency hz: the best of the
    3 x 3 cells around it (a tone is a mainlobe, a few cells wide)."""
    with open(path, "rb") as f:
        head = f.read(796)
        assert head[:8] == b"OBJKCNV1", head[:8]
        w, h, v0, v255, _ = struct.unpack("<IIffI", head[8:28])
        body = f.read(w * h)
    x, y = world["x"], world["y"]
    col = int((t - x["min"]) / (x["max"] - x["min"]) * w)
    row = int((math.log2(y["max"]) - math.log2(hz)) / (math.log2(y["max"]) - math.log2(y["min"])) * h)
    best = 0
    for r in range(max(0, row - 1), min(h, row + 2)):
        for cc in range(max(0, col - 1), min(w, col + 2)):
            best = max(best, body[r * w + cc])
    return v0 + best / 255.0 * (v255 - v0)


class Script:
    """The real script, launched like the app launches it (run.sh, OBJEKAT_SOCKET), on its own connection."""

    def __init__(self, c, object_id, cache, extra_args=(), key=None):
        self.c = c
        self.object_id = object_id
        # A key of its own: the app remembers LIVE, and one headless process serves every section, so a
        # shared key would carry the mode and the values of one section into the next.
        self.key = key or "spectral-editor.scenario.%s" % os.path.basename(cache.rstrip("/"))
        env = dict(os.environ)
        env.update({"OBJEKAT_SOCKET": SOCK, "OBJEKAT_SPECTRAL_CACHE": cache, "OBJEKAT_LANGUAGE": "en",
                    "OBJEKAT_SPECTRAL_REMEMBER": self.key})
        self.cache = cache
        self.proc = subprocess.Popen([os.path.join(SG_DIR, "run.sh"), "--object", object_id] + list(extra_args),
                                     env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.cid = None

    def find_canvas(self, timeout=60):
        end = time.time() + timeout
        while time.time() < end:
            for cv in self.c.send("script.canvas.list")["canvases"]:
                if (cv.get("object") or "").lower() == self.object_id.lower() and cv["state"] == "open":
                    self.cid = cv["canvas_id"]
                    return self.cid
            if self.proc.poll() is not None:
                return None
            time.sleep(0.2)
        return None

    def get(self):
        return self.c.send("script.canvas.get", {"canvas_id": self.cid})

    def wait_for(self, pred, timeout=60, what=""):
        """Polls `get` until pred(state) is true; returns the state, or None on timeout / script exit."""
        end = time.time() + timeout
        while time.time() < end:
            st = self.get()
            if pred(st):
                return st
            if self.proc.poll() is not None:
                return None
            time.sleep(0.15)
        return None

    def ready(self, timeout=90):
        return self.wait_for(lambda s: s.get("image") and s["transport"]["slots"]["original"] and not s["busy"], timeout)

    @staticmethod
    def synced(s):
        """Instant mode: the spectrogram and the audio reflect the history at hand, and no trace is left."""
        rev = s["history"]["rev"]
        return (s["image"]["history_rev"] == rev and s["history"]["unreflected"] == []
                and s["transport"]["audio_history_rev"] == rev and not s["busy"])

    @staticmethod
    def pictures_synced(s):
        """Instant mode, and the Difference's picture (sent after the rest has settled) is at the current rev too."""
        delta = (s["image"] or {}).get("slots", {}).get("delta")
        return Script.synced(s) and delta is not None and delta["history_rev"] == s["history"]["rev"]

    @staticmethod
    def synced_selection(s):
        """Selection mode with something pending: the selection layer and the audio reflect the history at
        hand, and no trace is left. (The picture is NOT redrawn by a draft: it shows committed steps only.)"""
        sel = [l for l in s["layers"] if l["layer"] == "selection"]
        rev = s["history"]["rev"]
        return (bool(sel) and sel[0]["history_rev"] == rev and s["history"]["unreflected"] == []
                and s["transport"]["audio_history_rev"] == rev and not s["busy"])

    def settle(self, timeout=90):
        return self.wait_for(self.synced, timeout)

    def hand(self, **kw):
        kw["canvas_id"] = self.cid
        return self.c.send("script.canvas.input", kw)

    def finish(self, timeout=60):
        try:
            out, err = self.proc.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            out, err = self.proc.communicate()
            return None, out, err
        return self.proc.returncode, out, err

    def abort(self):
        if self.proc.poll() is None:
            self.proc.kill()
            self.proc.communicate()


def export_wav(c, path, start, end, rate=48000):
    r = c.send("export.run", {"format": "wav", "sample_rate": rate, "bit_depth": 24, "dithering": False,
                              "start": start, "end": end, "path": path})
    c.send("job.wait", {"id": r["job_id"], "timeout_ms": 120000})
    return read_wav_any(path)[3][0]


def open_canvases(c):
    """The canvases still open (an ended one stays listed, state `closed`, until the document changes)."""
    return [x for x in c.send("script.canvas.list")["canvases"] if x["state"] == "open"]


def fresh_saved_project(c, root, name="p"):
    c.send("project.new")
    c.send("project.save_as", {"path": os.path.join(root, name + ".objekat")})


def section_c(c):
    if not venv_ok():
        print("skip  c: the script's venv is missing (run tools/scripts/spectral-editor/install.sh)")
        return
    ROOT = tmproot("c")
    CACHE = os.path.join(ROOT, "cache")
    RATE, T = 48000, 2.0
    TONES = {300.0: 0.25, 3000.0: 0.25}
    import json
    manifest = json.load(open(os.path.join(SG_DIR, "manifest.json"), encoding="utf-8"))
    known = {x["name"] for x in c.send("help")["commands"]}
    unknown = [r for r in manifest["requires"] if r not in known]
    check("c: every command the manifest requires exists in the app", not unknown, unknown)

    fresh_saved_project(c, ROOT)
    wav = make_tones_wav(os.path.join(ROOT, "tone.wav"), T, RATE, TONES, 24)
    oid = c.send("object.add", {"path": wav, "lane": 0, "start": 0.0, "name": "tone"})["id"]
    base = export_wav(c, os.path.join(ROOT, "baseline.wav"), 0.0, T)
    dirty0 = c.send("app.info").get("dirty")

    sc = Script(c, oid, CACHE)
    try:
        cid = sc.find_canvas()
        check("c: the script opens a canvas bound to the object", cid is not None, sc.proc.poll())
        if cid is None:
            return
        st = sc.ready()
        check("c: the base image and the original slot arrive", st is not None)
        if st is None:
            return
        w = st["world"]
        check("c: world x is [0, 2] s, lin", abs(w["x"]["min"]) < 1e-9 and abs(w["x"]["max"] - T) < 0.02
              and w["x"]["unit"] == "s" and w["x"]["mapping"] == "lin", w["x"])
        check("c: world y is [20, 24000] Hz, log", abs(w["y"]["min"] - 20) < 1e-9 and abs(w["y"]["max"] - 24000) < 1e-6
              and w["y"]["mapping"] == "log" and w["y"]["unit"] == "Hz", w["y"])
        check("c: defaults 2048 / 4", st["values"].get("fft_size") == "2048" and st["values"].get("overlap") == 4, st["values"])
        check("c: the base image is an indexed picture with a readout", st["image"]["has_values"] is True, st["image"])
        check("c: the canvas remembers (under the key the test gave)", st["remember"] == sc.key, st["remember"])
        check("c: the preview opens on the RESULT", st["transport"]["listen"] == "result", st["transport"]["listen"])
        check("c: no layer at all at the start (no veil)", st["layers"] == [], st["layers"])
        check("c: tools are rect + brush (stroke); the canvas has modes, opens in Instant",
              st["tool"] == "rect" and st["modes"] is True and st["mode"] == "instant", (st["tool"], st["modes"], st["mode"]))
        orig_path = st["transport"]["slots"]["original"]
        orig = read_wav_any(orig_path)[3][0]
        # the level of the ORIGINAL spectrogram, read now (the script keeps only its last two pictures)
        i3k0, i300 = image_db(st["image"]["path"], st["world"], 1.0, 3000), image_db(st["image"]["path"], st["world"], 1.0, 300)
        check("c: the project is untouched while the canvas is open (not dirty)",
              c.send("app.info").get("dirty") == dirty0)

        # ---- rectangle ------------------------------------------------------------------
        sc.hand(values={"gain": -24})
        t_op = time.time()
        sc.hand(tool="rect", op={"kind": "rect", "x0": 0, "x1": T, "y0": 2000, "y1": 4500})
        st = sc.settle()
        print("info  c: the picture and the audio caught up %.2f s after the gesture (2 s object)" % (time.time() - t_op))
        check("c: rect: the spectrogram and the audio catch up with the history", st is not None)
        if st is None:
            return
        check("c: rect: NO overlay (an applied step is in the picture itself): no layer, no trace left",
              st["layers"] == [] and st["history"]["unreflected"] == [], (st["layers"], st["history"]["unreflected"]))
        i3k, i300b = image_db(st["image"]["path"], st["world"], 1.0, 3000), image_db(st["image"]["path"], st["world"], 1.0, 300)
        check("c: rect: the spectrogram shows 3 kHz down by 24 dB +-3 (%.1f -> %.1f dB)" % (i3k0, i3k),
              abs((i3k - i3k0) + 24) <= 3.0, (i3k0, i3k))
        check("c: rect: ... and 300 Hz where it was (+-0.7 dB)", abs(i300b - i300) <= 0.7, (i300, i300b))
        res = read_wav_any(st["transport"]["slots"]["result"])[3][0]
        d3 = goertzel_db(res, RATE, 3000) - goertzel_db(orig, RATE, 3000)
        d300 = goertzel_db(res, RATE, 300) - goertzel_db(orig, RATE, 300)
        check("c: rect: 3 kHz is at -24 dB +-1 on the result", abs(d3 + 24) <= 1.0, d3)
        check("c: rect: 300 Hz is within +-0.2 dB", abs(d300) <= 0.2, d300)
        dl = read_wav_any(st["transport"]["slots"]["delta"])[3][0]
        check("c: rect: the delta carries the 3 kHz that was taken away",
              goertzel_db(dl, RATE, 3000) > goertzel_db(dl, RATE, 300) + 30,
              (goertzel_db(dl, RATE, 3000), goertzel_db(dl, RATE, 300)))

        # ---- revision 5: one picture per listening state ---------------------------------------
        st = sc.wait_for(Script.pictures_synced)
        check("c: r5: the Difference's picture arrives (slot delta, at the current history rev)", st is not None)
        if st is None:
            return
        slots = st["image"]["slots"]
        check("c: r5: Original and Difference have a picture of their own; the Result's is the base image",
              set(slots) == {"original", "delta"}, sorted(slots))
        o3k, o300 = image_db(slots["original"]["path"], st["world"], 1.0, 3000), image_db(slots["original"]["path"], st["world"], 1.0, 300)
        check("c: r5: the Original's picture is the untouched spectrogram (3 kHz and 300 Hz as at the start, +-0.7 dB)",
              abs(o3k - i3k0) <= 0.7 and abs(o300 - i300) <= 0.7, (o3k, i3k0, o300, i300))
        d3k, d300k = image_db(slots["delta"]["path"], st["world"], 1.0, 3000), image_db(slots["delta"]["path"], st["world"], 1.0, 300)
        check("c: r5: the Difference's picture shows what was taken away: 3 kHz nearly as loud as the original "
              "(-0.6 dB, +-2), 300 Hz at the floor (<= -80 dB)", abs(d3k - (i3k0 - 0.56)) <= 2.0 and d300k <= -80.0, (d3k, i3k0, d300k))
        check("c: r5: the picture and the audio of the Difference come from the same history rev",
              slots["delta"]["history_rev"] == st["transport"]["audio_history_rev"], (slots["delta"], st["transport"]))
        shown = {}
        for listen in ("original", "delta", "result"):
            sc.hand(listen=listen)
            shown[listen] = sc.get()["image"]["shown"]
        check("c: r5: what is drawn follows what is heard (Original -> slot original, Difference -> slot delta, Result -> base)",
              shown["original"] == slots["original"]["path"] and shown["delta"] == slots["delta"]["path"]
              and shown["result"] == st["image"]["path"], (shown, slots, st["image"]["path"]))

        e = st["history"]["entries"][st["history"]["cursor"] - 1]
        check("c: rect: ONE step, sealed with every hand value (the gain it was drawn at)",
              e["kind"] == "step" and e["params"]["gain"] == -24 and e["params"]["quantity"] == 25
              and e["ops"][0]["polarity"] == "add" and st["history"]["pending"] == 0, e)

        # ---- undo ------------------------------------------------------------------------
        prev_res = st["transport"]["slots"]["result"]
        sc.hand(undo=True)
        st = sc.wait_for(lambda s: Script.synced(s) and s["history"]["cursor"] == 0
                         and s["transport"]["slots"]["result"] != prev_res)
        check("c: undo: the result is recomputed", st is not None)
        if st is None:
            return
        res = read_wav_any(st["transport"]["slots"]["result"])[3][0]
        d3 = goertzel_db(res, RATE, 3000) - goertzel_db(orig, RATE, 3000)
        check("c: undo: 3 kHz is back within +-0.2 dB", abs(d3) <= 0.2, d3)
        check("c: undo: the spectrogram is the original again at (1 s, 3 kHz) (+-0.7 dB), still no layer",
              abs(image_db(st["image"]["path"], st["world"], 1.0, 3000) - i3k0) <= 0.7 and st["layers"] == [])
        st = sc.wait_for(Script.pictures_synced)
        check("c: r5: undo: the Difference's picture is silence again (3 kHz at the floor)",
              st is not None and image_db(st["image"]["slots"]["delta"]["path"], st["world"], 1.0, 3000) <= -80.0)
        if st is None:
            return

        # ---- brush, calibrated (gain -12, quantity 25: one pass = -3 dB) ---------------------
        sc.hand(values={"gain": -12})
        stroke = {"kind": "stroke", "points": [[-0.2, 3000], [2.2, 3000]], "view_scale": {"x": 400, "y": 32}}
        sc.hand(tool="brush", op=stroke)
        st = sc.settle()
        check("c: brush: caught up after the first stroke", st is not None)
        if st is None:
            return
        e = st["history"]["entries"][st["history"]["cursor"] - 1]
        check("c: brush: the op carries size_y = 1 octave (32 pt at 32 pt/oct), quantity 25 in its params",
              abs(e["ops"][0]["size_y"] - 1.0) < 1e-9 and e["ops"][0]["params"] == {"quantity": 25, "hardness": 50}, e)
        res = read_wav_any(st["transport"]["slots"]["result"])[3][0]
        d1 = goertzel_db(res, RATE, 3000, 0.5, 1.5) - goertzel_db(orig, RATE, 3000, 0.5, 1.5)
        d1_300 = goertzel_db(res, RATE, 300, 0.5, 1.5) - goertzel_db(orig, RATE, 300, 0.5, 1.5)
        check("c: brush: one pass gives -3 dB +-0.4 on the middle second", abs(d1 + 3) <= 0.4, d1)
        check("c: brush: 300 Hz is not touched", abs(d1_300) <= 0.2, d1_300)
        sc.hand(tool="brush", op=stroke)
        st = sc.settle()
        check("c: brush: caught up after the second stroke (two steps)", st is not None and st["history"]["cursor"] == 2)
        if st is None:
            return
        res = read_wav_any(st["transport"]["slots"]["result"])[3][0]
        d2 = goertzel_db(res, RATE, 3000, 0.5, 1.5) - goertzel_db(orig, RATE, 3000, 0.5, 1.5)
        check("c: brush: the same stroke again, as a second step, gives -6 dB +-0.5 (steps add in dB)", abs(d2 + 6) <= 0.5, d2)

        # ---- out and back in ONE stroke: the same -6, from a single step ------------------------
        sc.hand(undo=True)
        sc.hand(undo=True)
        st = sc.wait_for(lambda s: Script.synced(s) and s["history"]["cursor"] == 0)
        check("c: two undos bring the history back to 0", st is not None)
        if st is None:
            return
        back = {"kind": "stroke", "points": [[-0.2, 3000], [2.2, 3000], [-0.2, 3000]], "view_scale": {"x": 400, "y": 32}}
        sc.hand(tool="brush", op=back)
        st = sc.settle()
        check("c: out-and-back: caught up (one step)", st is not None and st["history"]["cursor"] == 1
              and st["history"]["count"] == 1, st and st["history"])
        if st is None:
            return
        res = read_wav_any(st["transport"]["slots"]["result"])[3][0]
        d2 = goertzel_db(res, RATE, 3000, 0.5, 1.5) - goertzel_db(orig, RATE, 3000, 0.5, 1.5)
        check("c: out-and-back: ONE stroke crossing twice gives -6 dB +-0.5", abs(d2 + 6) <= 0.5, d2)

        # ---- expert change ---------------------------------------------------------------
        img_before, res_before = st["image"]["path"], st["transport"]["slots"]["result"]
        w4 = st["image"]["width"]
        sc.hand(values={"overlap": 8})
        st = sc.wait_for(lambda s: s["image"]["path"] != img_before and s["transport"]["slots"]["result"] != res_before
                         and not s["busy"])
        check("c: overlap 8: a new base image and a new result", st is not None)
        if st is None:
            return
        check("c: overlap 8: the operations are kept", st["history"]["count"] == 1 and st["history"]["cursor"] == 1,
              st["history"]["count"])
        check("c: overlap 8: the picture has twice the columns (one per NEW hop: %d -> %d)" % (w4, st["image"]["width"]),
              w4 == 96000 // 512 + 1 and st["image"]["width"] == 96000 // 256 + 1, (w4, st["image"]["width"]))
        res = read_wav_any(st["transport"]["slots"]["result"])[3][0]
        d8 = goertzel_db(res, RATE, 3000, 0.5, 1.5) - goertzel_db(orig, RATE, 3000, 0.5, 1.5)
        check("c: overlap 8: the result still carries the stroke (-6 dB +-0.5)", abs(d8 + 6) <= 0.5, d8)

        # ---- validate --------------------------------------------------------------------
        sc.hand(press="validate")
        rc, out, err = sc.finish(90)
        check("c: validate: the script exits 0", rc == 0, (rc, out, err[-300:]))
    finally:
        sc.abort()

    objs = {o["id"]: o for o in c.send("object.list")["objects"]}
    new = [o for o in objs.values() if o["name"] == "tone (spectral)"]
    check("c: validate: one new object named 'tone (spectral)' at the same start",
          len(new) == 1 and abs(new[0]["start"] - 0.0) < 1e-6, [o["name"] for o in objs.values()])
    check("c: validate: the original is muted", objs[oid]["muted"] is True)
    if new:
        f = new[0].get("file", "")
        check("c: validate: the file lies in <project>/samples/spectral/", "/samples/spectral/" in f and os.path.exists(f), f)
        check("c: validate: its lane is a new row (not the original's)", new[0]["display_lane"] != objs[oid]["display_lane"],
              (new[0]["display_lane"], objs[oid]["display_lane"]))
    after = export_wav(c, os.path.join(ROOT, "after.wav"), 0.0, T)
    e3 = goertzel_db(after, RATE, 3000, 0.5, 1.5) - goertzel_db(base, RATE, 3000, 0.5, 1.5)
    e300 = goertzel_db(after, RATE, 300, 0.5, 1.5) - goertzel_db(base, RATE, 300, 0.5, 1.5)
    print("info  c: export before/after Validate: 3 kHz %+.2f dB, 300 Hz %+.2f dB" % (e3, e300))
    check("c: validate: the export shows 3 kHz down by the out-and-back stroke (-6 dB +-1)", abs(e3 + 6) <= 1.0, e3)
    check("c: validate: the export keeps 300 Hz (+-0.3 dB)", abs(e300) <= 0.3, e300)
    c.send("edit.undo")
    objs = {o["id"]: o for o in c.send("object.list")["objects"]}
    check("c: ONE edit.undo removes the new object and unmutes the original",
          list(objs) == [oid] and objs[oid]["muted"] is False, [o["name"] for o in objs.values()])
    check("c: the canvas is gone", not open_canvases(c))
    check("c: the work folder is removed", not os.path.isdir(CACHE) or os.listdir(CACHE) == [], os.listdir(CACHE) if os.path.isdir(CACHE) else None)

    # ---- what a NEXT session remembers (same key): the controls, the tool, the mode ---------------------
    sc2 = Script(c, oid, CACHE, key=sc.key)
    try:
        sc2.find_canvas()
        st2 = sc2.ready()
        check("c: remember: the second session opens", st2 is not None)
        if st2 is not None:
            v = st2["values"]
            check("c: remember: last session's gain (-12), overlap (8) and tool (brush) are back; the mode is Instant",
                  v["gain"] == -12 and v["overlap"] == 8 and st2["tool"] == "brush" and st2["mode"] == "instant",
                  (v, st2["tool"], st2["mode"]))
            sc2.hand(mode="select", tool="rect", values={"gain": -7, "feather_ms": 500, "feather_st": 3, "size_px": 90,
                                                         "quantity": 60, "hardness": 70, "fft_size": "4096", "overlap": 6})
            check("c: the gain is a row of buttons (revision 6b): a value between two (-7) is snapped to the nearest (-6)",
                  sc2.get()["values"]["gain"] == -6, sc2.get()["values"]["gain"])
            sc2.hand(press="cancel")
        sc2.finish(60)
    finally:
        sc2.abort()
    sc3 = Script(c, oid, CACHE, key=sc.key)
    try:
        sc3.find_canvas()
        st3 = sc3.ready()
        check("c: remember: the third session opens", st3 is not None)
        if st3 is not None:
            v = st3["values"]
            check("c: remember: ALL the persisted controls come back (even after a Cancel): gain (-6, the -7 snapped), both feathers "
                  "(500 ms: the range reaches 1 s), brush size, amount, hardness, FFT size, overlap",
                  (v["gain"], v["feather_ms"], v["feather_st"], v["size_px"], v["quantity"], v["hardness"], v["fft_size"], v["overlap"])
                  == (-6, 500, 3, 90, 60, 70, "4096", 6), v)
            check("c: remember: the mode (Selection) and the tool (rect) come back", st3["mode"] == "select" and st3["tool"] == "rect",
                  (st3["mode"], st3["tool"]))
            sc3.hand(press="reset")
            v = sc3.get()["values"]
            check("c: remember: Reset gives back the DECLARED defaults (gain -12, feather 10 ms, FFT 2048, overlap 4)",
                  (v["gain"], v["feather_ms"], v["fft_size"], v["overlap"]) == (-12, 10, "2048", 4), v)
            sc3.hand(press="cancel")
        sc3.finish(60)
    finally:
        sc3.abort()

    # ---- launched by the app itself (script.run: the door the context menu goes through) -------
    listed = {x["name"]: x for x in c.send("script.list")["scripts"]}
    if "spectral-editor" in listed and listed["spectral-editor"]["available"]:
        c.send("script.run", {"script": "spectral-editor", "ids": [oid]})
        cid, end = None, time.time() + 60
        while time.time() < end and cid is None:
            for cv in open_canvases(c):
                if (cv.get("object") or "").lower() == oid.lower():
                    cid = cv["canvas_id"]
            time.sleep(0.2)
        check("c: script.run (the app's own launch, OBJEKAT_OBJECT_IDS) opens the canvas", cid is not None)
        if cid:
            c.send("script.canvas.input", {"canvas_id": cid, "press": "cancel"})
            end = time.time() + 30
            while time.time() < end and open_canvases(c):
                time.sleep(0.2)
            check("c: script.run: Cancel ends it and the canvas goes", not open_canvases(c))
            check("c: script.run: the project is as the undo left it (one object, unmuted)",
                  [o["id"] for o in c.send("object.list")["objects"]] == [oid]
                  and c.send("object.get", {"id": oid})["muted"] is False)
    else:
        print("skip  c: script.run: spectral-editor is not installed in the Plugins folder (run install.sh)")


def section_g(c):
    """END TO END, SELECTION MODE (plan 9.5 g): the real script, a weighted selection, live tuning, Apply."""
    if not venv_ok():
        print("skip  g: the script's venv is missing (run tools/scripts/spectral-editor/install.sh)")
        return
    ROOT = tmproot("g")
    CACHE = os.path.join(ROOT, "cache")
    RATE, T = 48000, 2.0
    TONES = {300.0: 0.2, 3000.0: 0.2, 8000.0: 0.2}
    fresh_saved_project(c, ROOT)
    wav = make_tones_wav(os.path.join(ROOT, "tone.wav"), T, RATE, TONES, 24)
    oid = c.send("object.add", {"path": wav, "lane": 0, "start": 0.0, "name": "tone"})["id"]
    base = export_wav(c, os.path.join(ROOT, "baseline.wav"), 0.0, T)

    def result_of(st):
        return read_wav_any(st["transport"]["slots"]["result"])[3][0]

    def db(res, orig, hz):
        return goertzel_db(res, RATE, hz, 0.5, 1.5) - goertzel_db(orig, RATE, hz, 0.5, 1.5)

    def layer(st, name):
        found = [l for l in st["layers"] if l["layer"] == name]
        return found[0] if found else None

    def caught_up(sc, prev_result, timeout=60):
        """After a LIVE tweak the history does not move: the new result is told by its path (and busy off)."""
        return sc.wait_for(lambda s: s["transport"]["slots"]["result"] != prev_result and not s["busy"], timeout)

    sc = Script(c, oid, CACHE)
    try:
        if sc.find_canvas() is None:
            check("g: the script opens a canvas", False, sc.proc.poll())
            return
        st = sc.ready()
        check("g: the canvas is ready", st is not None)
        if st is None:
            return
        orig = read_wav_any(st["transport"]["slots"]["original"])[3][0]
        i3k0 = image_db(st["image"]["path"], st["world"], 1.0, 3000)
        base_img = st["image"]["path"]
        sc.hand(mode="select")
        st = sc.get()
        check("g: mode select accepted (modes were declared at open)", st["mode"] == "select" and st["modes"] is True, st["mode"])

        # ---- a rectangle over 2-4.5 kHz: a pending selection, no step, no overlay ---------------
        rev0 = st["history"]["rev"]
        sc.hand(tool="rect", op={"kind": "rect", "x0": 0, "x1": T, "y0": 2000, "y1": 4500})
        st = sc.wait_for(Script.synced_selection)
        check("g: rect: the selection layer and the audio catch up", st is not None)
        if st is None:
            return
        h = st["history"]
        check("g: rect: ONE draft pending, no step, history.rev moved once",
              h["pending"] == 1 and h["cursor"] == 1 and h["entries"][0]["kind"] == "draft" and h["rev"] == rev0 + 1, h)
        sel = layer(st, "selection")
        a3k, a300 = layer_alpha(sel, st["world"], 1.0, 3000), layer_alpha(sel, st["world"], 1.0, 300)
        check("g: rect: the selection layer is amber-opaque 0.6 at (1 s, 3 kHz), 0 at 300 Hz",
              abs(a3k - 0.6) <= 0.03 and a300 == 0.0, (a3k, a300))
        check("g: rect: the only layer is the selection's, and the picture is untouched (nothing is committed)",
              [l["layer"] for l in st["layers"]] == ["selection"] and st["image"]["path"] == base_img,
              [l["layer"] for l in st["layers"]])
        res = result_of(st)
        d3 = db(res, orig, 3000)
        check("g: rect: the result already carries the pending selection (3 kHz at -12 +-1, 300 Hz untouched)",
              abs(d3 + 12) <= 1.0 and abs(db(res, orig, 300)) <= 0.2, (d3, db(res, orig, 300)))

        # ---- live tuning: the gain moves, the history does not ----------------------------------
        hist_rev, sel_path = st["history"]["rev"], sel["path"]
        prev = st["transport"]["slots"]["result"]
        sc.hand(values={"gain": -6})
        st = caught_up(sc, prev)
        check("g: gain -6: the result is recomputed", st is not None)
        if st is None:
            return
        check("g: gain -6: history.rev UNCHANGED, the selection layer untouched (the gain is not its opacity)",
              st["history"]["rev"] == hist_rev and layer(st, "selection")["path"] == sel_path, st["history"]["rev"])
        d3 = db(result_of(st), orig, 3000)
        check("g: gain -6: 3 kHz at -6 dB +-1", abs(d3 + 6) <= 1.0, d3)
        prev = st["transport"]["slots"]["result"]
        sc.hand(values={"gain": -12})
        st = caught_up(sc, prev)
        d3 = db(result_of(st), orig, 3000) if st else None
        check("g: gain -12: 3 kHz at -12 dB +-1, history.rev still UNCHANGED",
              st is not None and abs(d3 + 12) <= 1.0 and st["history"]["rev"] == hist_rev, d3)
        if st is None:
            return
        # The other buttons of the row (revision 6b), the ends included: each click is heard at once, the history
        # does not move, and a value that is not a button (-5) is snapped to the nearest (-6) BEFORE it is heard.
        for given, want in ((-24, -24), (3, 3), (-5, -6), (-12, -12)):
            prev = st["transport"]["slots"]["result"]
            sc.hand(values={"gain": given})
            st = caught_up(sc, prev)
            d3 = db(result_of(st), orig, 3000) if st else None
            check("g: gain button %s (given %s): the control reads %s, 3 kHz at %s dB +-1, history.rev UNCHANGED"
                  % (want, given, want, want),
                  st is not None and st["values"]["gain"] == want and abs(d3 - want) <= 1.0
                  and st["history"]["rev"] == hist_rev, (st["values"]["gain"] if st else None, d3))
            if st is None:
                return
        # A feather moves the selection's edges: the selection layer IS redrawn (and the history still not).
        prev, sel_path = st["transport"]["slots"]["result"], layer(st, "selection")["path"]
        sc.hand(values={"feather_ms": 40})
        st = sc.wait_for(lambda s: s["transport"]["slots"]["result"] != prev and not s["busy"]
                         and layer(s, "selection")["path"] != sel_path)
        check("g: a feather change redraws the selection layer too, history.rev unchanged",
              st is not None and st["history"]["rev"] == hist_rev, st and st["history"]["rev"])
        if st is None:
            return
        sc.hand(values={"feather_ms": 10})
        st = sc.wait_for(lambda s: not s["busy"] and layer(s, "selection")["path"] != layer(st, "selection")["path"])
        if st is None:
            return

        # ---- a brush pass at quantity 50 over a second band: pro rata, -6 ----------------------------
        prev = st["transport"]["slots"]["result"]
        sc.hand(values={"quantity": 50})
        stroke = {"kind": "stroke", "points": [[-0.2, 8000], [2.2, 8000]], "view_scale": {"x": 400, "y": 32}}
        sc.hand(tool="brush", op=stroke)
        st = sc.wait_for(lambda s: Script.synced_selection(s) and s["history"]["pending"] == 2)
        check("g: brush: a second draft pending", st is not None)
        if st is None:
            return
        res = result_of(st)
        d8 = db(res, orig, 8000)
        check("g: brush at quantity 50: the 8 kHz band is at -6 dB +-0.6 (pro rata: 50 % of -12)", abs(d8 + 6) <= 0.6, d8)
        check("g: brush: the rectangle's band is still at -12 +-1", abs(db(res, orig, 3000) + 12) <= 1.0, db(res, orig, 3000))
        a8 = layer_alpha(layer(st, "selection"), st["world"], 1.0, 8000)
        check("g: brush: the selection layer's alpha at 8 kHz is 0.6 * 0.5", abs(a8 - 0.3) <= 0.03, a8)

        # ---- an Erase pass at 50 over it: back to 0 ----------------------------------------------------
        sc.hand(polarity="subtract")
        sc.hand(op=stroke)
        st = sc.wait_for(lambda s: Script.synced_selection(s) and s["history"]["pending"] == 3)
        check("g: erase: a third draft pending, recorded as subtract",
              st is not None and st["history"]["entries"][2]["ops"][0]["polarity"] == "subtract", st and st["history"])
        if st is None:
            return
        res = result_of(st)
        d8 = db(res, orig, 8000)
        check("g: erase at 50 over the brush pass: 8 kHz back to 0 +-0.3", abs(d8) <= 0.3, d8)
        check("g: erase: 3 kHz still at -12 +-1", abs(db(res, orig, 3000) + 12) <= 1.0)
        sc.hand(polarity="add")

        # ---- Apply: ONE step, the selection layer gone, the spectrogram shows it -----------------------------
        sc.hand(commit=True)
        st = sc.wait_for(lambda s: Script.synced(s) and layer(s, "selection") is None)
        check("g: commit: the spectrogram catches up and the selection layer is gone", st is not None)
        if st is None:
            return
        h = st["history"]
        check("g: commit: ONE step of three ops, params = the values now, pending 0",
              h["pending"] == 0 and h["count"] == 1 and h["entries"][0]["kind"] == "step"
              and len(h["entries"][0]["ops"]) == 3 and h["entries"][0]["params"]["gain"] == -12
              and h["entries"][0]["params"]["quantity"] == 50, h)
        check("g: commit: NO layer at all (no blue veil, no amber), the picture is a new one",
              st["layers"] == [] and st["image"]["path"] != base_img, ([l["layer"] for l in st["layers"]], st["image"]["path"]))
        i3k = image_db(st["image"]["path"], st["world"], 1.0, 3000)
        check("g: commit: the spectrogram shows 3 kHz down by 12 dB +-2.5 (%.1f -> %.1f dB)" % (i3k0, i3k),
              abs((i3k - i3k0) + 12) <= 2.5, (i3k0, i3k))
        d3 = db(result_of(st), orig, 3000)
        check("g: commit: the result keeps 3 kHz at -12 +-1", abs(d3 + 12) <= 1.0, d3)

        # ---- the gain moved AFTER Apply changes nothing (the step carries its own) --------------------
        res_path, img_path = st["transport"]["slots"]["result"], st["image"]["path"]
        sc.hand(values={"gain": -3})
        time.sleep(2.5)
        st = sc.get()
        check("g: the gain moved after Apply changes neither the result nor the picture",
              st["transport"]["slots"]["result"] == res_path and st["image"]["path"] == img_path
              and abs(db(result_of(st), orig, 3000) + 12) <= 1.0, st["transport"]["slots"]["result"])

        # ---- undo REVEALS the step's selection (revision 6): pending again, settings back --------------
        sc.hand(undo=True)
        st = sc.wait_for(lambda s: Script.synced_selection(s) and s["history"]["pending"] > 0)
        check("g: undo of the applied step brings its 3 gestures back as the PENDING selection (no step left)",
              st is not None and st["history"]["pending"] == 3 and st["history"]["count"] == 3
              and all(e["kind"] == "draft" for e in st["history"]["entries"]), st and st["history"])
        if st is None:
            return
        check("g: undo: the step's gain (-12) is back in the controls (it had been moved to -3 after Apply)",
              st["values"]["gain"] == -12, st["values"]["gain"])
        check("g: undo: the spectrogram is the original's again (+-0.7 dB) and the selection layer shows the selection",
              abs(image_db(st["image"]["path"], st["world"], 1.0, 3000) - i3k0) <= 0.7 and layer(st, "selection") is not None)
        check("g: undo: the preview carries the revealed selection (3 kHz -12 +-1)",
              abs(db(result_of(st), orig, 3000) + 12) <= 1.0, db(result_of(st), orig, 3000))
        sc.hand(discard=True)
        st = sc.wait_for(lambda s: s["history"]["pending"] == 0 and s["layers"] == [] and not s["busy"]
                         and s["transport"]["audio_history_rev"] == s["history"]["rev"])
        check("g: Ignore throws the revealed selection away: nothing pending, 3 kHz back to 0 +-0.2",
              st is not None and st["history"]["count"] == 0 and abs(db(result_of(st), orig, 3000)) <= 0.2,
              st and st["history"])
        if st is None:
            return

        # ---- Validate with a selection still pending writes what is HEARD ------------------------------
        sc.hand(values={"gain": -12})
        sc.hand(tool="rect", op={"kind": "rect", "x0": 0, "x1": T, "y0": 2000, "y1": 4500})
        st = sc.wait_for(lambda s: Script.synced_selection(s) and s["history"]["pending"] == 1
                         and s["history"]["cursor"] == 1)
        check("g: a new pending selection (after the undone step: the redo tail is dropped)",
              st is not None and st["history"]["count"] == 1 and st["history"]["entries"][0]["kind"] == "draft", st and st["history"])
        if st is None:
            return
        sc.hand(press="validate")
        rc, out, err = sc.finish(90)
        check("g: validate with a pending selection: the script exits 0", rc == 0, (rc, out, err[-300:]))
    finally:
        sc.abort()

    objs = {o["id"]: o for o in c.send("object.list")["objects"]}
    new = [o for o in objs.values() if o["name"] == "tone (spectral)"]
    check("g: validate: one new object, the original muted", len(new) == 1 and objs[oid]["muted"] is True,
          [o["name"] for o in objs.values()])
    after = export_wav(c, os.path.join(ROOT, "after.wav"), 0.0, T)
    e3 = goertzel_db(after, RATE, 3000, 0.5, 1.5) - goertzel_db(base, RATE, 3000, 0.5, 1.5)
    e300 = goertzel_db(after, RATE, 300, 0.5, 1.5) - goertzel_db(base, RATE, 300, 0.5, 1.5)
    e8k = goertzel_db(after, RATE, 8000, 0.5, 1.5) - goertzel_db(base, RATE, 8000, 0.5, 1.5)
    print("info  g: export before/after Validate: 3 kHz %+.2f dB, 300 Hz %+.2f dB, 8 kHz %+.2f dB" % (e3, e300, e8k))
    check("g: validate: the written file carries the pending selection (3 kHz at -12 dB +-1)", abs(e3 + 12) <= 1.0, e3)
    check("g: validate: 300 Hz and 8 kHz are untouched (+-0.3)", abs(e300) <= 0.3 and abs(e8k) <= 0.3, (e300, e8k))
    c.send("edit.undo")
    check("g: ONE edit.undo takes it all back",
          [o["id"] for o in c.send("object.list")["objects"]] == [oid] and c.send("object.get", {"id": oid})["muted"] is False)
    check("g: the canvas is gone", not open_canvases(c))


def run_to_validate(c, root, tag, wav, name="tone", extra=None):
    """A saved project with `wav` as one object, the script launched and validated at once (no operation).
    Returns (returncode, stderr, the new object or None)."""
    fresh_saved_project(c, root, tag)
    oid = c.send("object.add", {"path": wav, "lane": 0, "start": 0.5, "name": name})["id"]
    sc = Script(c, oid, os.path.join(root, "cache-" + tag))
    try:
        if sc.find_canvas() is None or sc.ready() is None:
            return None, sc.finish(5)[2], None
        sc.hand(press="validate")
        rc, out, err = sc.finish(90)
    finally:
        sc.abort()
    new = [o for o in c.send("object.list")["objects"] if o["name"] == "%s (spectral)" % name]
    return rc, err, (new[0] if new else None)


def section_d(c):
    if not venv_ok():
        print("skip  d: the script's venv is missing (run tools/scripts/spectral-editor/install.sh)")
        return
    ROOT = tmproot("d")

    def header(path):
        rate, bits, is_float, chans = read_wav_any(path)
        return rate, bits, is_float, len(chans), chans

    w1 = make_tones_wav(os.path.join(ROOT, "m441.wav"), 1.0, 44100, {1000.0: 0.25}, 16)
    rc, err, new = run_to_validate(c, ROOT, "d1", w1)
    check("d: 44.1 kHz / 16-bit mono: the script exits 0", rc == 0, (rc, err[-300:]))
    if new:
        rate, bits, fl, ch, _ = header(new["file"])
        check("d: 44.1 kHz / 16-bit mono -> 44100 Hz, 16-bit, 1 channel", (rate, bits, fl, ch) == (44100, 16, False, 1),
              (rate, bits, fl, ch))
    else:
        check("d: 44.1 kHz / 16-bit mono: a new object exists", False)

    wf = make_float_wav(os.path.join(ROOT, "f32.wav"), 1.0, 48000)
    rc, err, new = run_to_validate(c, ROOT, "d2", wf)
    check("d: float source: the script exits 0", rc == 0, (rc, err[-300:]))
    if new:
        rate, bits, fl, ch, _ = header(new["file"])
        check("d: 32-bit float mono source -> 48000 Hz, 32-bit float, 1 channel", (rate, bits, fl, ch) == (48000, 32, True, 1),
              (rate, bits, fl, ch))
    else:
        check("d: float source: a new object exists", False)

    w2 = make_tones_wav(os.path.join(ROOT, "st_lr.wav"), 1.0, 48000, {300.0: 0.25}, 24, channels=2, right_tones={3000.0: 0.25})
    rc, err, new = run_to_validate(c, ROOT, "d3", w2)
    check("d: stereo L != R: the script exits 0", rc == 0, (rc, err[-300:]))
    if new:
        rate, bits, fl, ch, _ = header(new["file"])
        check("d: stereo with L != R -> 48000 Hz, 24-bit, 2 channels", (rate, bits, fl, ch) == (48000, 24, False, 2),
              (rate, bits, fl, ch))
    else:
        check("d: stereo L != R: a new object exists", False)

    w3 = make_tones_wav(os.path.join(ROOT, "st_eq.wav"), 1.0, 48000, {500.0: 0.25}, 24, channels=2)
    rc, err, new = run_to_validate(c, ROOT, "d4", w3)
    check("d: stereo L == R: the script exits 0", rc == 0, (rc, err[-300:]))
    if new:
        rate, bits, fl, ch, _ = header(new["file"])
        check("d: stereo with L == R -> 48000 Hz, 24-bit, 1 channel", (rate, bits, fl, ch) == (48000, 24, False, 1),
              (rate, bits, fl, ch))
    else:
        check("d: stereo L == R: a new object exists", False)


def section_e(c):
    if not venv_ok():
        print("skip  e: the script's venv is missing (run tools/scripts/spectral-editor/install.sh)")
        return
    ROOT = tmproot("e")

    # ---- 601 s: refused, with a message, and no canvas ----------------------------------------
    short = make_tones_wav(os.path.join(ROOT, "s.wav"), 1.0, 8000, {440.0: 0.25}, 16)
    fresh_saved_project(c, ROOT, "e1")
    a = c.send("object.add", {"path": short, "lane": 0, "start": 0.0})["id"]
    b = c.send("object.add", {"path": short, "lane": 1, "start": 600.0})["id"]
    g = c.send("group.create", {"ids": [a, b]})
    gid = g.get("id") or g.get("group_id")
    dur = c.send("object.get", {"id": gid})["duration"]
    check("e: the group spans 601 s", abs(dur - 601.0) < 0.1, dur)
    sc = Script(c, gid, os.path.join(ROOT, "cache-e1"))
    try:
        rc, out, err = sc.finish(60)
        print("info  e: 601 s -> exit %s, stderr: %s" % (rc, err.strip()))
        check("e: a group of 601 s: the script exits != 0", rc not in (None, 0), rc)
        check("e: ... with a message on stderr", "too long" in err.lower() or "trop long" in err.lower(), err[-300:])
        check("e: ... and no canvas was opened", not open_canvases(c), open_canvases(c))
    finally:
        sc.abort()

    # ---- Cancel: the project is unchanged -----------------------------------------------------
    tone = make_tones_wav(os.path.join(ROOT, "t.wav"), 1.0, 48000, {440.0: 0.25}, 24)
    fresh_saved_project(c, ROOT, "e2")
    oid = c.send("object.add", {"path": tone, "lane": 0, "start": 0.0, "name": "tone"})["id"]
    before = c.send("object.list")["objects"]
    dirty0 = c.send("app.info").get("dirty")
    cache2 = os.path.join(ROOT, "cache-e2")
    sc = Script(c, oid, cache2)
    try:
        ok = sc.find_canvas() is not None and sc.ready() is not None
        check("e: cancel: the canvas is up", ok)
        if ok:
            sc.hand(op={"kind": "rect", "x0": 0, "x1": 1, "y0": 100, "y1": 1000})
            sc.settle()
            sc.hand(press="cancel")
            rc, out, err = sc.finish(60)
            check("e: cancel: the script exits 0", rc == 0, (rc, err[-300:]))
    finally:
        sc.abort()
    after = c.send("object.list")["objects"]
    check("e: cancel: the objects are exactly as before", after == before, (len(before), len(after)))
    check("e: cancel: the project is not dirty", c.send("app.info").get("dirty") == dirty0)
    check("e: cancel: the work folder is removed", not os.path.isdir(cache2) or os.listdir(cache2) == [])
    check("e: cancel: nothing was written under samples/spectral",
          not os.path.isdir(os.path.join(ROOT, "samples", "spectral")) or os.listdir(os.path.join(ROOT, "samples", "spectral")) == [])

    # ---- SIGKILL: the canvas goes within 10 s --------------------------------------------------
    sc = Script(c, oid, os.path.join(ROOT, "cache-e3"))
    try:
        ok = sc.find_canvas() is not None
        check("e: sigkill: the canvas is up", ok)
        if ok:
            sc.proc.kill()
            sc.proc.communicate()
            end = time.time() + 10
            gone = False
            while time.time() < end:
                if not open_canvases(c):
                    gone = True
                    break
                time.sleep(0.2)
            check("e: sigkill: the canvas is gone within 10 s", gone)
    finally:
        sc.abort()

    # ---- a clip whose file is missing -----------------------------------------------------------
    fresh_saved_project(c, ROOT, "e4")
    gone_wav = make_tones_wav(os.path.join(ROOT, "gone.wav"), 1.0, 8000, {440.0: 0.25}, 16)
    mid = c.send("object.add", {"path": gone_wav, "lane": 0, "start": 0.0, "name": "gone"})["id"]
    os.remove(gone_wav)
    c.send("project.rescan_missing")
    sc = Script(c, mid, os.path.join(ROOT, "cache-e4"))
    try:
        rc, out, err = sc.finish(60)
        print("info  e: missing file -> exit %s, stderr: %s" % (rc, err.strip()))
        check("e: a missing file: the script exits != 0 with a message", rc not in (None, 0) and err.strip() != "", (rc, err[-200:]))
        check("e: a missing file: no canvas", not open_canvases(c), open_canvases(c))
    finally:
        sc.abort()


# ---------------------------------------------------------------------------------------------
# f. No window on the headless pid
# ---------------------------------------------------------------------------------------------

def app_pid():
    """The pid of the instance that listens on SOCK (the socket's owner, else the command line)."""
    for cmd in (["lsof", "-t", SOCK], ["pgrep", "-f", "socket=" + SOCK]):
        try:
            out = subprocess.run(cmd, capture_output=True, text=True).stdout.split()
        except OSError:
            continue
        if out:
            return int(out[0])
    return None


def section_f(c):
    try:
        import Quartz
    except ImportError:
        print("skip  f: Quartz not available")
        return
    pid = app_pid()
    if pid is None:
        print("skip  f: cannot find the app's pid")
        return
    ROOT = tmproot("f")
    WAV1 = make_wav(os.path.join(ROOT, "tone1.wav"), 1.0, 48000, 24)
    CNV = write_cnv(os.path.join(ROOT, "base.objkcnv"), 4, 2)
    RGB = write_rgb(os.path.join(ROOT, "tint.objkrgb"), 8, 4)
    c.send("project.new")
    cid = open_canvas(c)
    c.send("script.canvas.set_image", {"canvas_id": cid, "path": CNV, "x": X_AXIS, "y": Y_AXIS})
    c.send("script.canvas.set_layer", {"canvas_id": cid, "layer": "tint", "path": RGB, "history_rev": 0})
    c.send("script.canvas.set_audio", {"canvas_id": cid, "original": WAV1, "result": WAV1})
    c.send("script.canvas.input", {"canvas_id": cid, "op": {"kind": "rect", "x0": 1, "x1": 3, "y0": 100, "y1": 1000}})
    c.send("script.canvas.input", {"canvas_id": cid, "play": True})
    time.sleep(0.3)

    def windows():
        info = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionAll, Quartz.kCGNullWindowID) or []
        return [w for w in info if w.get("kCGWindowOwnerPID") == pid]

    check("f: no window on the headless pid while a canvas is open and playing", windows() == [], str(windows())[:200])
    c.send("script.canvas.close", {"canvas_id": cid})
    check("f: nor after it is closed", windows() == [], str(windows())[:200])


# ---------------------------------------------------------------------------------------------
# (h) revision 5 — a picture per listening state, the monitoring level
# ---------------------------------------------------------------------------------------------

def section_h(c):
    ROOT = tmproot("h")
    WAV = make_wav(os.path.join(ROOT, "tone.wav"), 1.0, 48000, 24)
    BASE = write_cnv(os.path.join(ROOT, "base.objkcnv"), 4, 2)
    ORIG = write_cnv(os.path.join(ROOT, "orig.objkcnv"), 8, 4)
    DELTA = write_cnv(os.path.join(ROOT, "delta.objkcnv"), 2, 2)
    fresh_saved_project(c, ROOT, "p")
    cid = open_canvas(c)

    def get():
        return c.send("script.canvas.get", {"canvas_id": cid})

    def hist():
        return get()["history"]

    # -- a picture per slot ----------------------------------------------------------------
    expect_error(lambda: c.send("script.canvas.set_image", {"canvas_id": cid, "slot": "original", "path": ORIG}),
                 "invalid_state", "h: set_image with a slot before any base image -> invalid_state")
    c.send("script.canvas.set_image", {"canvas_id": cid, "path": BASE, "x": X_AXIS, "y": Y_AXIS, "value_unit": "dB"})
    g = get()
    check("h: no slot picture at first: image.slots is empty and the base image is shown",
          g["image"]["slots"] == {} and g["image"]["shown"] == BASE, g["image"])
    r = c.send("script.canvas.set_image", {"canvas_id": cid, "slot": "original", "path": ORIG})
    check("h: set_image {slot} answers the size of that picture (it need not match the base image's)",
          (r["width"], r["height"]) == (8, 4), r)
    c.send("script.canvas.set_image", {"canvas_id": cid, "slot": "delta", "path": DELTA, "history_rev": 0})
    g = get()
    check("h: get lists both pictures with their size and history_rev",
          g["image"]["slots"] == {"original": {"path": ORIG, "width": 8, "height": 4, "history_rev": None},
                                  "delta": {"path": DELTA, "width": 2, "height": 2, "history_rev": 0}}, g["image"]["slots"])
    check("h: the base image is unchanged by them", g["image"]["path"] == BASE and g["image"]["width"] == 4, g["image"])
    check("h: before any audio the listened slot is the original: its picture is shown", g["image"]["shown"] == ORIG, g["image"])
    c.send("script.canvas.set_audio", {"canvas_id": cid, "original": WAV, "result": WAV, "delta": WAV, "listen": "result"})
    check("h: Result shows the base image", get()["image"]["shown"] == BASE)
    c.send("script.canvas.input", {"canvas_id": cid, "listen": "delta"})
    check("h: Difference shows its own picture", get()["image"]["shown"] == DELTA)
    rev = get()["rev"]
    c.send("script.canvas.input", {"canvas_id": cid, "listen": "original"})
    check("h: Original shows its own picture", get()["image"]["shown"] == ORIG)
    check("h: switching the listened slot does not move rev", get()["rev"] == rev)
    c.send("script.canvas.set_image", {"canvas_id": cid, "slot": "original", "path": None})
    check("h: path null removes a slot's picture: the base image is shown again for it",
          "original" not in get()["image"]["slots"] and get()["image"]["shown"] == BASE, get()["image"])
    expect_error(lambda: c.send("script.canvas.set_image", {"canvas_id": cid, "slot": "nope", "path": ORIG}),
                 "bad_params", "h: an unknown slot -> bad_params")
    expect_error(lambda: c.send("script.canvas.set_image", {"canvas_id": cid, "slot": "original",
                                                             "path": os.path.join(ROOT, "no.objkcnv")}),
                 "not_found", "h: a missing slot picture -> not_found")
    expect_error(lambda: c.send("script.canvas.set_image", {"canvas_id": cid, "slot": "original"}),
                 "bad_params", "h: a slot picture with no path -> bad_params")
    # a picture that reflects the history hides the traces, whichever slot it belongs to
    c.send("script.canvas.input", {"canvas_id": cid, "op": {"kind": "rect", "x0": 1, "x1": 2, "y0": 100, "y1": 1000}})
    check("h: a gesture leaves its raw trace", len(hist()["unreflected"]) == 1, hist())
    c.send("script.canvas.set_image", {"canvas_id": cid, "slot": "delta", "path": DELTA, "history_rev": hist()["rev"]})
    check("h: a slot picture stamped with the history rev hides the trace (it counts like a layer)",
          hist()["unreflected"] == [], hist())
    c.send("script.canvas.set_image", {"canvas_id": cid, "path": BASE, "x": X_AXIS, "y": Y_AXIS})
    check("h: the same world keeps the slot pictures", "delta" in get()["image"]["slots"])
    c.send("script.canvas.set_image", {"canvas_id": cid, "path": BASE, "x": {"min": 0, "max": 20, "unit": "s"}, "y": Y_AXIS})
    check("h: a new world drops them (they cover the old one)", get()["image"]["slots"] == {}, get()["image"])

    # -- the monitoring level ---------------------------------------------------------------
    check("h: the monitoring level starts at 0 dB", get()["transport"]["monitor_db"] == 0, get()["transport"])
    rev = get()["rev"]
    r = c.send("script.canvas.input", {"canvas_id": cid, "monitor_db": 6})
    g = get()
    check("h: input monitor_db sets it, and moves no rev", g["transport"]["monitor_db"] == 6 and g["rev"] == rev
          and r["rev"] == rev, (g["transport"], g["rev"], rev))
    for given, want in ((35, 20), (-99, -20), (3.14159, 3.1), (-0.04, 0), (20, 20), (-20, -20)):
        c.send("script.canvas.input", {"canvas_id": cid, "monitor_db": given})
        got = get()["transport"]["monitor_db"]
        check("h: monitor_db %s -> %s (clamped to -20..+20, rounded to 0.1 dB)" % (given, want), got == want, got)
    expect_error(lambda: c.send("script.canvas.input", {"canvas_id": cid, "monitor_db": "loud"}),
                 "bad_params", "h: a non-number monitor_db -> bad_params")
    check("h: a refused level changes nothing", get()["transport"]["monitor_db"] == -20)
    c.send("script.canvas.input", {"canvas_id": cid, "monitor_db": 5})
    check("h: a canvas that does not remember keeps nothing in the project",
          "canvasSettings" not in c.send("project.get_state"), c.send("project.get_state").get("canvasSettings"))
    check("h: the monitoring level never moves the history or the audio files",
          hist()["rev"] == 1 and get()["transport"]["slots"]["original"] == WAV, hist())

    # -- ... and PER PROJECT -----------------------------------------------------------------
    key = "spectral-editor.r5.%s" % os.path.basename(ROOT.rstrip("/"))
    other = key + ".other"

    def open_remembering(k):
        return c.send("script.canvas.open", {"title": "R", "tools": TOOLS, "controls": CANVAS_CONTROLS,
                                            "remember": k})["canvas_id"]

    dirty0 = c.send("app.info").get("dirty")
    cid = open_remembering(key)
    check("h: a remembering canvas in a project that knows nothing opens at 0 dB", get()["transport"]["monitor_db"] == 0)
    c.send("script.canvas.input", {"canvas_id": cid, "monitor_db": 7.5})
    check("h: its level lands in the project document, under its remember key",
          c.send("project.get_state").get("canvasSettings") == {key: {"monitorDB": 7.5}},
          c.send("project.get_state").get("canvasSettings"))
    check("h: changing it does not mark the project modified (a listening preference, like the viewport)",
          c.send("app.info").get("dirty") == dirty0)
    cid = open_remembering(key)
    check("h: reopening the editor in the same project finds the level (7.5 dB)", get()["transport"]["monitor_db"] == 7.5)
    cid = open_remembering(other)
    check("h: another key has a level of its own (0 dB)", get()["transport"]["monitor_db"] == 0)
    c.send("script.canvas.input", {"canvas_id": cid, "monitor_db": -3})
    check("h: ... kept beside the first", c.send("project.get_state").get("canvasSettings")
          == {key: {"monitorDB": 7.5}, other: {"monitorDB": -3}}, c.send("project.get_state").get("canvasSettings"))
    c.send("script.canvas.input", {"canvas_id": cid, "monitor_db": 0})
    check("h: back to 0 dB writes nothing for that key",
          c.send("project.get_state").get("canvasSettings") == {key: {"monitorDB": 7.5}})
    c.send("project.save")
    with open(os.path.join(ROOT, "p.objekat"), encoding="utf-8") as f:
        on_disk = json.load(f)
    check("h: the saved file carries canvasSettings", on_disk.get("canvasSettings") == {key: {"monitorDB": 7.5}},
          on_disk.get("canvasSettings"))
    check("h: ... without bumping the format (the key is optional: an older reader ignores it)",
          on_disk.get("version") == 20, on_disk.get("version"))
    c.send("project.new")
    cid = open_remembering(key)
    check("h: a NEW project starts the editor at 0 dB", get()["transport"]["monitor_db"] == 0)
    check("h: ... and carries no canvasSettings", "canvasSettings" not in c.send("project.get_state"))
    c.send("project.open", {"path": os.path.join(ROOT, "p.objekat")})
    cid = open_remembering(key)
    check("h: reopening the saved project restores 7.5 dB", get()["transport"]["monitor_db"] == 7.5, get()["transport"])
    # a hand-edited file: a level out of range is clamped, a non-number is ignored
    doc = json.load(open(os.path.join(ROOT, "p.objekat"), encoding="utf-8"))
    doc["canvasSettings"] = {key: {"monitorDB": 99}, other: {"monitorDB": "x"}}
    bad_path = os.path.join(ROOT, "edited.objekat")
    json.dump(doc, open(bad_path, "w", encoding="utf-8"))
    c.send("project.open", {"path": bad_path})
    cid = open_remembering(key)
    check("h: a hand-edited level of 99 dB opens clamped to +20", get()["transport"]["monitor_db"] == 20)
    cid = open_remembering(other)
    check("h: a level of the wrong type is ignored (0 dB), the project still opens", get()["transport"]["monitor_db"] == 0)
    c.send("project.new")


def section_i(c):
    """REVISION 6, CANVAS SIDE (no script): an op records the audio slot heard when it was drawn (`slot`), and
    in Selection mode an undo of an APPLIED step brings its selection back as the pending one with its
    settings restored (a redo puts the step back); Instant mode undoes as before."""
    ROOT = tmproot("i")
    WAV = make_wav(os.path.join(ROOT, "tone.wav"), 3.0, 48000, 24)
    CNV = write_cnv(os.path.join(ROOT, "base.objkcnv"), 4, 2)
    c.send("project.new")
    obj = c.send("object.add", {"path": WAV, "lane": 0, "start": 0.0})["id"]
    tools = [{"id": "rect", "kind": "rect", "label": "Rectangle", "params": []},
             {"id": "brush", "kind": "stroke", "label": "Brush", "params": ["quantity", "hardness"], "size_control": "size_px"}]
    controls = CANVAS_CONTROLS + [{"id": "view", "kind": "number", "label": "View", "value": 5, "min": 0, "max": 10,
                                   "step": 1, "advanced": True}]
    cid = c.send("script.canvas.open", {"title": "R6", "controls": controls, "tools": tools, "object": obj,
                                        "modes": True})["canvas_id"]
    c.send("script.canvas.set_image", {"canvas_id": cid, "path": CNV, "x": X_AXIS, "y": Y_AXIS})
    c.send("script.canvas.set_audio", {"canvas_id": cid, "original": WAV, "result": WAV, "delta": WAV, "history_rev": 0})

    def get():
        return c.send("script.canvas.get", {"canvas_id": cid})

    def hist():
        return get()["history"]

    def inp(**kw):
        kw["canvas_id"] = cid
        return c.send("script.canvas.input", kw)

    def rect(x0, x1, y0=100, y1=200):
        return inp(op={"kind": "rect", "x0": x0, "x1": x1, "y0": y0, "y1": y1})

    # -- the slot of an op --------------------------------------------------------------------
    slots = []
    for listen in ("original", "result", "delta"):
        inp(listen=listen)
        rect(len(slots), len(slots) + 1)
        slots.append(listen)
    h = hist()
    check("i: an op carries the audio slot heard when it was drawn (original, result, delta)",
          [e["ops"][0]["slot"] for e in h["entries"]] == slots and h["count"] == 3, h["entries"])
    inp(undo=True)
    inp(undo=True)
    inp(undo=True)
    h = hist()
    check("i: Instant mode: undo is the plain one (the steps stay listed, cursor 0, nothing pending)",
          h["cursor"] == 0 and h["count"] == 3 and h["pending"] == 0, h)
    for _ in range(3):
        inp(redo=True)
    h = hist()
    check("i: ... and redo brings them back", h["cursor"] == 3 and h["count"] == 3 and h["pending"] == 0, h)
    base_count = 3

    # -- Selection mode: undo reveals the applied step's selection ---------------------------------
    inp(mode="select")
    inp(listen="delta")
    inp(values={"gain": -6, "feather_ms": 25, "feather_st": 2, "quantity": 60, "view": 7})
    rect(1.0, 2.0, 100, 1000)
    rect(2.0, 2.5, 500, 4000)
    inp(commit=True)
    h = hist()
    st = h["entries"][-1]
    check("i: Selection: two gestures sealed into ONE step (params gain -6, feather 25 ms / 2 st)",
          h["pending"] == 0 and st["kind"] == "step" and len(st["ops"]) == 2 and st["params"]["gain"] == -6
          and st["params"]["feather_ms"] == 25 and st["params"]["feather_st"] == 2, st)
    step_id, op_ids = st["id"], [o["id"] for o in st["ops"]]
    geom = [(o["x0"], o["x1"], o["y0"], o["y1"], o["slot"]) for o in st["ops"]]
    inp(values={"gain": -20, "feather_ms": 100, "feather_st": 5, "quantity": 30, "view": 2})
    rev = hist()["rev"]
    inp(undo=True)
    g = get()
    h = g["history"]
    drafts = [e for e in h["entries"] if e["kind"] == "draft"]
    check("i: undo of an applied step in Selection mode: its selection is PENDING (2 drafts), the step is gone",
          h["pending"] == 2 and len(drafts) == 2 and h["count"] == base_count + 2 and h["cursor"] == h["count"]
          and h["rev"] > rev and not any(e["id"] == step_id for e in h["entries"]), h)
    check("i: ... the drafts are the very gestures (geometry and the slot they were drawn in), in order",
          [(o["x0"], o["x1"], o["y0"], o["y1"], o["slot"]) for e in drafts for o in e["ops"]] == geom, drafts)
    v = g["values"]
    check("i: ... the step's gain and feathers are back in the controls (-6, 25, 2)",
          v["gain"] == -6 and v["feather_ms"] == 25 and v["feather_st"] == 2, v)
    check("i: ... the brush's values, the size and an advanced setting are NOT restored (30, 2)",
          v["quantity"] == 30 and v["view"] == 2 and v["size_px"] == 32, v)
    check("i: ... the app stays in Selection mode, the polarity toggle untouched", g["mode"] == "select" and g["polarity"] == "add")
    # redo puts the step back, exactly
    inp(redo=True)
    h = hist()
    st2 = h["entries"][-1]
    check("i: redo right after: the SAME step comes back (id, ops, params), no draft left",
          h["pending"] == 0 and st2["kind"] == "step" and st2["id"] == step_id and [o["id"] for o in st2["ops"]] == op_ids
          and st2["params"]["gain"] == -6 and h["count"] == base_count + 1, h)
    check("i: ... redo does not revert the controls (gain still -6 from the reveal)", get()["values"]["gain"] == -6)
    # reveal again, tweak, re-apply: a NEW step with the new gain; the old one is gone
    inp(undo=True)
    inp(values={"gain": -3})
    inp(commit=True)
    h = hist()
    st3 = h["entries"][-1]
    check("i: reveal, tweak the gain, Apply again: ONE new step (gain -3, 2 ops), the old step is gone",
          h["pending"] == 0 and st3["kind"] == "step" and st3["id"] != step_id and st3["params"]["gain"] == -3
          and len(st3["ops"]) == 2 and h["count"] == base_count + 1, h)
    check("i: ... its ops kept the slot they were drawn in (delta)", [o["slot"] for o in st3["ops"]] == ["delta", "delta"], st3["ops"])
    # a revealed selection obeys the usual pending rules: undo peels ONE gesture
    inp(undo=True)
    inp(undo=True)
    h = hist()
    check("i: with a selection pending, undo removes the last gesture (not a whole step): 1 draft left",
          h["pending"] == 1 and h["cursor"] == base_count + 1 and h["count"] == base_count + 2, h)
    inp(redo=True)
    check("i: ... and redo gives it back", hist()["pending"] == 2)
    inp(commit=True)
    inp(undo=True)                                    # reveal
    n = hist()["pending"]
    rect(0.2, 0.4)
    h0 = hist()
    r = inp(redo=True)
    check("i: a new gesture after a reveal forgets its redo (redo is a no-op)",
          r["added"] is False and hist()["rev"] == h0["rev"] and hist()["pending"] == n + 1, (r, h0))
    inp(discard=True)
    h = hist()
    check("i: Ignore throws the revealed selection away, nothing to redo", h["pending"] == 0)
    r = inp(redo=True)
    check("i: ... redo after Ignore is a no-op", r["added"] is False and hist()["pending"] == 0, r)
    inp(mode="instant")
    check("i: Instant again once nothing is pending", get()["mode"] == "instant")
    c.send("script.canvas.close", {"canvas_id": cid})


def cnv_range(path):
    """(v0, v255) of an OBJKCNV1 file: the value range its readout uses."""
    with open(path, "rb") as f:
        head = f.read(28)
    assert head[:8] == b"OBJKCNV1", head[:8]
    return struct.unpack("<ff", head[16:24])


def section_j(c):
    """REVISION 6, END TO END (the real script): working on the DIFFERENCE (Result + Difference = Original, the
    levels follow G' = 1 - (1 - G) g) and the spectrogram's DISPLAY RANGE (re-coloured, remembered)."""
    if not venv_ok():
        print("skip  j: the script's venv is missing (run tools/scripts/spectral-editor/install.sh)")
        return
    ROOT = tmproot("j")
    CACHE = os.path.join(ROOT, "cache")
    RATE, T = 48000, 2.0
    TONES = {300.0: 0.2, 3000.0: 0.2}
    fresh_saved_project(c, ROOT)
    wav = make_tones_wav(os.path.join(ROOT, "tone.wav"), T, RATE, TONES, 24)
    oid = c.send("object.add", {"path": wav, "lane": 0, "start": 0.0, "name": "tone"})["id"]

    def audio(st, slot):
        return read_wav_any(st["transport"]["slots"][slot])[3][0]

    def lvl(x, ref, hz):
        return goertzel_db(x, RATE, hz, 0.5, 1.5) - goertzel_db(ref, RATE, hz, 0.5, 1.5)

    sc = Script(c, oid, CACHE, key="spectral-editor.scenario.j")   # its own key: c and g leave Selection mode behind
    try:
        if sc.find_canvas() is None:
            check("j: the script opens a canvas", False, sc.proc.poll())
            return
        st = sc.ready()
        check("j: the canvas is ready", st is not None)
        if st is None:
            return
        orig = audio(st, "original")
        world = st["world"]

        # ---- step 1 on the Result: -24 dB over 2-4.5 kHz ------------------------------------------
        sc.hand(values={"gain": -24})
        sc.hand(tool="rect", op={"kind": "rect", "x0": 0, "x1": T, "y0": 2000, "y1": 4500})
        st = sc.wait_for(Script.pictures_synced)
        if st is None:
            check("j: step 1 settles", False)
            return
        e = st["history"]["entries"][0]
        check("j: an op drawn while listening to the Result carries slot result", e["ops"][0]["slot"] == "result", e["ops"])
        res, dlt = audio(st, "result"), audio(st, "delta")
        check("j: step 1: the result is 3 kHz at -24 dB (+-1), 300 Hz untouched",
              abs(lvl(res, orig, 3000) + 24) <= 1.0 and abs(lvl(res, orig, 300)) <= 0.2, (lvl(res, orig, 3000), lvl(res, orig, 300)))
        diff1 = 20 * math.log10(1 - 10 ** (-24 / 20.0))
        check("j: step 1: the difference is original - result: 3 kHz at %.2f dB (+-1)" % diff1,
              abs(lvl(dlt, orig, 3000) - diff1) <= 1.0, lvl(dlt, orig, 3000))

        # ---- step 2 on the Difference: -12 dB over the same band ---------------------------------
        sc.hand(listen="delta", values={"gain": -12})
        sc.hand(op={"kind": "rect", "x0": 0, "x1": T, "y0": 2000, "y1": 4500})
        st = sc.wait_for(lambda s: len(s["history"]["entries"]) == 2 and Script.pictures_synced(s))
        if st is None:
            check("j: step 2 settles", False)
            return
        e = st["history"]["entries"][1]
        check("j: an op drawn while listening to the Difference carries slot delta", e["ops"][0]["slot"] == "delta", e["ops"])
        res, dlt = audio(st, "result"), audio(st, "delta")
        g1, g2 = 10 ** (-24 / 20.0), 10 ** (-12 / 20.0)
        gp = 1 - (1 - g1) * g2                       # G' = 1 - (1 - G) g
        want_res, want_dlt = 20 * math.log10(gp), 20 * math.log10((1 - g1) * g2)
        check("j: step 2: the RESULT follows G' = 1 - (1 - G) g: 3 kHz at %.2f dB (+-1), not -36" % want_res,
              abs(lvl(res, orig, 3000) - want_res) <= 1.0, lvl(res, orig, 3000))
        check("j: step 2: the DIFFERENCE is 12 dB lower than before: 3 kHz at %.2f dB (+-1)" % want_dlt,
              abs(lvl(dlt, orig, 3000) - want_dlt) <= 1.0, lvl(dlt, orig, 3000))
        check("j: step 2: 300 Hz untouched in the result, absent from the difference",
              abs(lvl(res, orig, 300)) <= 0.2 and lvl(dlt, orig, 300) <= -60, (lvl(res, orig, 300), lvl(dlt, orig, 300)))
        n = min(len(orig), len(res), len(dlt))
        worst = max(abs(orig[i] - res[i] - dlt[i]) for i in range(0, n, 7))
        check("j: Result + Difference = Original, sample for sample (worst %.2e)" % worst, worst < 1e-5, worst)
        # the pictures follow: the Difference's picture is 12 dB lower, the Result's lost only a little more
        slots = st["image"]["slots"]
        d_img = image_db(slots["delta"]["path"], world, 1.0, 3000)
        o_img = image_db(slots["original"]["path"], world, 1.0, 3000)
        r_img = image_db(st["image"]["path"], world, 1.0, 3000)
        check("j: the Difference's picture shows 3 kHz %.1f dB under the Original's (+-3)" % want_dlt,
              abs((d_img - o_img) - want_dlt) <= 3.0, (d_img, o_img))
        check("j: the Result's picture shows 3 kHz %.1f dB under the Original's (+-3)" % want_res,
              abs((r_img - o_img) - want_res) <= 3.0, (r_img, o_img))

        # ---- the display range ------------------------------------------------------------------
        before = sc.get()
        paths = (before["image"]["path"], slots["original"]["path"], slots["delta"]["path"])
        check("j: the default display range is -100 .. 0 dB on every picture", all(cnv_range(p) == (-100.0, 0.0) for p in paths),
              [cnv_range(p) for p in paths])
        hrev, audio_paths = before["history"]["rev"], (before["transport"]["slots"]["result"], before["transport"]["slots"]["delta"])
        sc.hand(values={"db_floor": -60, "db_ceiling": -10})
        st = sc.wait_for(lambda s: s["image"]["path"] != paths[0] and s["image"]["slots"]["original"]["path"] != paths[1]
                         and s["image"]["slots"]["delta"]["path"] != paths[2] and not s["busy"])
        check("j: a new range recolours the Result, the Original and the Difference pictures", st is not None)
        if st is None:
            return
        slots2 = st["image"]["slots"]
        new = (st["image"]["path"], slots2["original"]["path"], slots2["delta"]["path"])
        check("j: ... each one now carries the range (-60 .. -10 dB) for its readout",
              all(cnv_range(p) == (-60.0, -10.0) for p in new), [cnv_range(p) for p in new])
        check("j: ... the readout still tells the truth (the Original's 3 kHz within 1 dB of before)",
              abs(image_db(slots2["original"]["path"], world, 1.0, 3000) - o_img) <= 1.0,
              (image_db(slots2["original"]["path"], world, 1.0, 3000), o_img))
        check("j: ... display only: the history rev, the audio files and the steps are untouched",
              st["history"]["rev"] == hrev and (st["transport"]["slots"]["result"], st["transport"]["slots"]["delta"]) == audio_paths
              and len(st["history"]["entries"]) == 2, st["history"]["rev"])
        check("j: ... the pictures keep their history stamp (what the app does with the traces does not move)",
              st["image"]["history_rev"] == before["image"]["history_rev"]
              and st["image"]["slots"]["delta"]["history_rev"] == before["image"]["slots"]["delta"]["history_rev"], st["image"])
        # a floor above the ceiling carries the ceiling (never an empty range)
        sc.hand(values={"db_floor": -20, "db_ceiling": -40})
        st = sc.wait_for(lambda s: s["image"]["path"] != new[0] and not s["busy"])
        check("j: a floor above the ceiling lifts the ceiling by 6 dB (-20 .. -14), never an empty range",
              st is not None and cnv_range(st["image"]["path"]) == (-20.0, -14.0), st and cnv_range(st["image"]["path"]))
        sc.hand(values={"db_floor": -90, "db_ceiling": -5})
        st = sc.wait_for(lambda s: cnv_range(s["image"]["path"]) == (-90.0, -5.0) and not s["busy"])
        check("j: the range is set again", st is not None)
        # ---- Selection mode on the Difference: the PENDING selection is previewed on the difference too -----------
        sc.hand(mode="select", listen="delta", values={"gain": -6})
        sc.hand(op={"kind": "rect", "x0": 0, "x1": T, "y0": 2000, "y1": 4500})
        st = sc.wait_for(lambda s: s["history"]["pending"] == 1 and Script.synced_selection(s))
        check("j: Selection on the Difference: one pending gesture, the selection layer arrives", st is not None)
        if st is not None:
            res = audio(st, "result")
            gpp = 1 - (1 - gp) * 10 ** (-6 / 20.0)
            check("j: ... the preview is G'' = 1 - (1 - G') g: 3 kHz at %.2f dB (+-1)" % (20 * math.log10(gpp)),
                  abs(lvl(res, orig, 3000) - 20 * math.log10(gpp)) <= 1.0, lvl(res, orig, 3000))
            sc.hand(discard=True)
        sc.hand(press="cancel")
        sc.finish(60)
    finally:
        sc.abort()

    # ---- remembered by the next session ---------------------------------------------------------------
    sc2 = Script(c, oid, CACHE, key=sc.key)
    try:
        sc2.find_canvas()
        st2 = sc2.ready()
        check("j: the next session opens", st2 is not None)
        if st2 is not None:
            v = st2["values"]
            check("j: the display range is remembered (-90 .. -5) and drawn so from the first picture",
                  (v["db_floor"], v["db_ceiling"]) == (-90, -5) and cnv_range(st2["image"]["path"]) == (-90.0, -5.0)
                  and cnv_range(st2["image"]["slots"]["original"]["path"]) == (-90.0, -5.0), (v, cnv_range(st2["image"]["path"])))
            check("j: ... and the Difference's (blank) picture too",
                  cnv_range(st2["image"]["slots"]["delta"]["path"]) == (-90.0, -5.0)
                  if "delta" in st2["image"]["slots"] else False, st2["image"]["slots"])
            sc2.hand(press="reset")
            v = sc2.get()["values"]
            check("j: Reset gives back the declared range (-100 .. 0)", (v["db_floor"], v["db_ceiling"]) == (-100, 0), v)
            sc2.hand(press="cancel")
        sc2.finish(60)
    finally:
        sc2.abort()


# ---------------------------------------------------------------------------------------------
# k. The two largest FFT sizes (16384, 32768), end to end
# ---------------------------------------------------------------------------------------------

def section_k(c):
    """THE BIG WINDOWS, END TO END (the real script): 16384 and 32768 chosen in the Expert section — the picture's
    width follows the hop (one column per hop), a rectangle at -24 dB is -24 dB on the result, the choice is remembered
    by the next session, and an object SHORTER than the window (0.4 s against a 0.68 s window) opens, draws a coarse
    picture (never fewer than one column) and takes its rectangle all the same: no refusal, no clamp."""
    if not venv_ok():
        print("skip  k: the script's venv is missing (run tools/scripts/spectral-editor/install.sh)")
        return
    ROOT = tmproot("k")
    CACHE = os.path.join(ROOT, "cache")
    RATE, T = 48000, 2.0
    TONES = {300.0: 0.2, 3000.0: 0.2}
    fresh_saved_project(c, ROOT)
    wav = make_tones_wav(os.path.join(ROOT, "tone.wav"), T, RATE, TONES, 24)
    oid = c.send("object.add", {"path": wav, "lane": 0, "start": 0.0, "name": "tone"})["id"]

    def hop(n, k=4):
        return int(math.floor(n / float(k) + 0.5))

    def audio(st, slot):
        return read_wav_any(st["transport"]["slots"][slot])[3][0]

    def lvl(x, ref, hz, a=0.5, b=1.5):
        return goertzel_db(x, RATE, hz, a, b) - goertzel_db(ref, RATE, hz, a, b)

    key = "spectral-editor.scenario.k"
    sc = Script(c, oid, CACHE, key=key)
    try:
        if sc.find_canvas() is None:
            check("k: the script opens a canvas", False, sc.proc.poll())
            return
        st = sc.ready()
        check("k: the canvas is ready, at the default 2048 / 4", st is not None and st["values"]["fft_size"] == "2048", st and st["values"])
        if st is None:
            return
        orig = audio(st, "original")
        for n in (16384, 32768):
            want_w = int(T * RATE) // hop(n) + 1
            sc.hand(values={"fft_size": str(n), "overlap": 4})
            st = sc.wait_for(lambda s: s["values"]["fft_size"] == str(n) and s["image"]["width"] == want_w
                             and Script.pictures_synced(s), 90)
            check("k: FFT %d: the picture is redrawn, %d columns (one per hop of %d) by 1024 rows" % (n, want_w, hop(n)),
                  st is not None, st and (st["values"]["fft_size"], st["image"]["width"], st["image"]["height"]))
            if st is None:
                return
            check("k: FFT %d: no step yet, the result is the original (null, within 0.01 dB at 3 kHz and 300 Hz)" % n,
                  abs(lvl(audio(st, "result"), orig, 3000)) < 0.01 and abs(lvl(audio(st, "result"), orig, 300)) < 0.01)
            sc.hand(values={"gain": -24})
            sc.hand(tool="rect", op={"kind": "rect", "x0": 0, "x1": T, "y0": 2000, "y1": 4500})
            st = sc.wait_for(lambda s: len(s["history"]["entries"]) == 1 and Script.pictures_synced(s), 90)
            if st is None:
                check("k: FFT %d: the rectangle settles" % n, False)
                return
            res = audio(st, "result")
            check("k: FFT %d: a rectangle at -24 dB: 3 kHz at -24 (+-0.5), 300 Hz untouched (+-0.2)" % n,
                  abs(lvl(res, orig, 3000) + 24) <= 0.5 and abs(lvl(res, orig, 300)) <= 0.2, (lvl(res, orig, 3000), lvl(res, orig, 300)))
            sc.hand(undo=True)
            st = sc.wait_for(lambda s: len(s["history"]["entries"]) == 1 and s["history"]["cursor"] == 0 and Script.pictures_synced(s), 90)
            check("k: FFT %d: undo gives the original back" % n, st is not None)
            if st is None:
                return
        sc.hand(press="cancel")
        sc.finish(60)
    finally:
        sc.abort()

    # ---- the next session remembers 32768 (the last choice), and opens on it -----------------------------------
    sc2 = Script(c, oid, CACHE, key=key)
    try:
        sc2.find_canvas()
        st2 = sc2.ready()
        check("k: remember: the next session opens", st2 is not None)
        if st2 is not None:
            want_w = int(T * RATE) // hop(32768) + 1
            check("k: remember: FFT 32768 comes back, and the FIRST picture is already drawn with it (%d columns)" % want_w,
                  st2["values"]["fft_size"] == "32768" and st2["image"]["width"] == want_w, (st2["values"]["fft_size"], st2["image"]["width"]))
            sc2.hand(press="reset")
            check("k: remember: Reset gives back 2048 (the default is unchanged)", sc2.get()["values"]["fft_size"] == "2048")
            sc2.hand(press="cancel")
        sc2.finish(60)
    finally:
        sc2.abort()

    # ---- an object SHORTER than the window: not refused, not clamped ---------------------------------------------
    TS = 0.4
    fresh_saved_project(c, ROOT, "k2")
    short = make_tones_wav(os.path.join(ROOT, "short.wav"), TS, RATE, TONES, 24)
    sid = c.send("object.add", {"path": short, "lane": 0, "start": 0.0, "name": "short"})["id"]
    sc3 = Script(c, sid, os.path.join(ROOT, "cache-short"), key=key + ".short")
    try:
        sc3.find_canvas()
        st = sc3.ready()
        check("k: short object: opens at 2048", st is not None)
        if st is None:
            return
        orig = audio(st, "original")
        for n in (16384, 32768):
            want_w = max(1, int(TS * RATE) // hop(n) + 1)
            sc3.hand(values={"fft_size": str(n), "overlap": 4, "gain": -24})
            st = sc3.wait_for(lambda s: s["values"]["fft_size"] == str(n) and s["image"]["width"] == want_w
                              and Script.pictures_synced(s), 90)
            check("k: short object (%.1f s) at FFT %d (a %.2f s window): a coarse picture of %d column(s), no refusal"
                  % (TS, n, n / float(RATE), want_w), st is not None, st and (st["values"]["fft_size"], st["image"]["width"]))
            if st is None:
                return
            sc3.hand(tool="rect", op={"kind": "rect", "x0": 0, "x1": TS, "y0": 2000, "y1": 4500})
            st = sc3.wait_for(lambda s: len(s["history"]["entries"]) == 1 and Script.pictures_synced(s), 90)
            if st is None:
                check("k: short object at FFT %d: the rectangle settles" % n, False)
                return
            res = audio(st, "result")
            check("k: short object at FFT %d: the rectangle still gives -24 dB at 3 kHz (+-1), 300 Hz untouched (+-0.3)" % n,
                  abs(lvl(res, orig, 3000, 0.1, 0.3) + 24) <= 1.0 and abs(lvl(res, orig, 300, 0.1, 0.3)) <= 0.3,
                  (lvl(res, orig, 3000, 0.1, 0.3), lvl(res, orig, 300, 0.1, 0.3)))
            sc3.hand(undo=True)
            st = sc3.wait_for(lambda s: s["history"]["cursor"] == 0 and Script.pictures_synced(s), 90)
            if st is None:
                check("k: short object at FFT %d: undo settles" % n, False)
                return
        sc3.hand(press="cancel")
        sc3.finish(60)
    finally:
        sc3.abort()


# ---------------------------------------------------------------------------------------------
# l. The focused display (revision 7), end to end
# ---------------------------------------------------------------------------------------------

def section_l(c):
    """THE FOCUSED (REASSIGNED) DISPLAY, END TO END (the real script): chosen in the Expert section, the three pictures are
    drawn on the focused grid (one column per hop of the DISPLAY analysis, 1024 rows) and a 440 Hz tone is a line where the
    normal picture shows its lobe; the status says "Focused (display only)"; the PROCESSING stays the normal FFT (a rectangle at
    -24 dB is -24 dB on the audio and visible in the focused picture); the compute size is lifted to the window; the choice is
    remembered by the next session; Reset gives Normal back."""
    if not venv_ok():
        print("skip  l: the script's venv is missing (run tools/scripts/spectral-editor/install.sh)")
        return
    ROOT = tmproot("l")
    CACHE = os.path.join(ROOT, "cache")
    RATE, T = 48000, 2.0
    fresh_saved_project(c, ROOT)
    wav = make_tones_wav(os.path.join(ROOT, "tones.wav"), T, RATE, {440.0: 0.25, 3000.0: 0.25}, 24)
    oid = c.send("object.add", {"path": wav, "lane": 0, "start": 0.0, "name": "tones"})["id"]

    def hop(n, k):
        return int(math.floor(n / float(k) + 0.5))

    def width(n, k):
        return int(T * RATE) // hop(n, k) + 1

    def audio(st, slot):
        return read_wav_any(st["transport"]["slots"][slot])[3][0]

    key = "spectral-editor.scenario.l"
    sc = Script(c, oid, CACHE, key=key)
    try:
        if sc.find_canvas() is None:
            check("l: the script opens a canvas", False, sc.proc.poll())
            return
        st = sc.ready()
        check("l: the canvas opens in the Normal display, the focused settings at their defaults",
              st is not None and st["values"].get("display_mode") == "normal" and st["values"].get("focus_window") == "512"
              and st["values"].get("focus_pad") == "4096" and st["values"].get("focus_overlap") == 8
              and st["values"].get("focus_threshold") == -80, st and st["values"])
        if st is None:
            return
        check("l: Normal: the status does not mention the focused display", "Focused" not in st["status"], st["status"])
        world, w0 = st["world"], st["image"]["width"]
        n440, n470 = image_db(st["image"]["path"], world, 1.0, 440), image_db(st["image"]["path"], world, 1.0, 470)
        check("l: Normal 2048: the 440 Hz lobe is wide: 470 Hz is within 25 dB (%.1f vs %.1f)" % (n470, n440), n470 - n440 > -25.0, (n440, n470))
        orig = audio(st, "original")

        # ---- the focused display (defaults: window 512, compute size 4096, overlap 8, threshold -80) ----------------
        sc.hand(values={"display_mode": "focused"})
        want_w = width(512, 8)
        st = sc.wait_for(lambda s: s["values"]["display_mode"] == "focused" and s["image"]["width"] == want_w
                         and Script.pictures_synced(s) and "Focused (display only)" in s["status"], 120)
        check("l: focused: the pictures are redrawn on the focused grid (%d columns = one per hop of 64) by 1024 rows, "
              "and the status says Focused (display only)" % want_w, st is not None,
              st and (st["image"]["width"], st["image"]["height"], st["status"]))
        if st is None:
            return
        world = st["world"]
        f440, f470 = image_db(st["image"]["path"], world, 1.0, 440), image_db(st["image"]["path"], world, 1.0, 470)
        check("l: focused: the 440 Hz tone is a line at about -12 dB (%.1f), 470 Hz is at least 45 dB under it (%.1f)" % (f440, f470),
              -16.0 <= f440 <= -11.0 and f470 - f440 < -45.0, (f440, f470))
        slots = st["image"]["slots"]
        check("l: focused: the Original's and the Difference's pictures are there too (all three redrawn together)",
              set(slots) == {"original", "delta"} and all(slots[k].get("path") for k in slots), slots)
        f3k0 = image_db(st["image"]["path"], world, 1.0, 3000)
        check("l: focused: the processing is untouched by the display: the result is still the original (null, 0.01 dB)",
              abs(goertzel_db(audio(st, "result"), RATE, 3000) - goertzel_db(orig, RATE, 3000)) < 0.01)

        # ---- a step: the audio is the normal FFT's, the focused picture shows it ---------------------------------
        sc.hand(values={"gain": -24})
        sc.hand(tool="rect", op={"kind": "rect", "x0": 0, "x1": T, "y0": 2000, "y1": 4500})
        st = sc.wait_for(lambda s: len(s["history"]["entries"]) == 1 and Script.pictures_synced(s), 120)
        check("l: focused: a rectangle settles (picture, audio, difference)", st is not None)
        if st is None:
            return
        res = audio(st, "result")
        d3 = goertzel_db(res, RATE, 3000) - goertzel_db(orig, RATE, 3000)
        d440 = goertzel_db(res, RATE, 440) - goertzel_db(orig, RATE, 440)
        check("l: focused: the audio is the normal processing: 3 kHz at -24 dB (+-0.5), 440 Hz untouched (+-0.2)",
              abs(d3 + 24) <= 0.5 and abs(d440) <= 0.2, (d3, d440))
        f3k = image_db(st["image"]["path"], world, 1.0, 3000)
        check("l: focused: the picture shows it: 3 kHz down by 24 dB (+-3, %.1f -> %.1f)" % (f3k0, f3k),
              abs((f3k - f3k0) + 24) <= 3.0, (f3k0, f3k))
        check("l: focused: the status keeps both: the step count and the display",
              "1 step" in st["status"] and "Focused (display only)" in st["status"], st["status"])
        sc.hand(undo=True)
        st = sc.wait_for(lambda s: s["history"]["cursor"] == 0 and Script.pictures_synced(s), 120)
        check("l: focused: undo gives the original picture back (3 kHz as at the start, +-3 dB)",
              st is not None and abs(image_db(st["image"]["path"], world, 1.0, 3000) - f3k0) <= 3.0)
        if st is None:
            return

        # ---- the compute size is lifted to the window; another window and overlap -----------------------------------
        sc.hand(values={"focus_window": "2048", "focus_pad": "1024", "focus_overlap": 4})
        want_w = width(2048, 4)
        st = sc.wait_for(lambda s: s["values"]["focus_window"] == "2048" and s["image"]["width"] == want_w
                         and Script.pictures_synced(s), 120)
        check("l: focused 2048 / compute size 1024 (lifted to 2048) / overlap 4: %d columns, no refusal" % want_w, st is not None,
              st and st["image"]["width"])
        if st is None:
            return
        sc.hand(press="cancel")
        sc.finish(60)
    finally:
        sc.abort()

    # ---- the next session remembers the focused display, and its first picture is already drawn with it -------------------
    sc2 = Script(c, oid, CACHE, key=key)
    try:
        sc2.find_canvas()
        st2 = sc2.ready()
        want_w = width(2048, 4)
        check("l: remember: the next session opens focused (window 2048, overlap 4), the FIRST picture drawn with it (%d columns)" % want_w,
              st2 is not None and st2["values"]["display_mode"] == "focused" and st2["values"]["focus_window"] == "2048"
              and st2["image"]["width"] == want_w and "Focused (display only)" in st2["status"],
              st2 and (st2["values"], st2["image"]["width"], st2["status"]))
        if st2 is not None:
            sc2.hand(press="reset")
            st2 = sc2.wait_for(lambda s: s["values"]["display_mode"] == "normal" and s["image"]["width"] == width(2048, 4) and
                               "Focused" not in s["status"] and Script.pictures_synced(s), 120)
            check("l: Reset gives the Normal display back (the 2048 / 4 picture and its status)", st2 is not None,
                  st2 and (st2["values"]["display_mode"], st2["image"]["width"], st2["status"]))
            sc2.hand(press="cancel")
        sc2.finish(60)
    finally:
        sc2.abort()


# ---------------------------------------------------------------------------------------------

try:
    with ObjekatClient(SOCK, timeout=180) as c:
        c.send("app.set_dialog_policy", {"policy": "assume_yes"})
        only = os.environ.get("SECTIONS", "abcdefghijkl")
        for name, fn in (("a", section_a), ("b", section_b), ("c", section_c), ("d", section_d), ("e", section_e),
                         ("f", section_f), ("g", section_g), ("h", section_h), ("i", section_i), ("j", section_j),
                         ("k", section_k), ("l", section_l)):
            if name in only:
                fn(c)
finally:
    cleanup()

print()
if fails:
    print("%d FAILED" % len(fails))
    sys.exit(1)
print("ALL PASS")

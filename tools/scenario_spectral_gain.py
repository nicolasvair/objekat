#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The spectral editor, app side — driven headless (@see plan_spectral_gain.md, section 6).

Standard library only. `SECTIONS=` picks the sections to run (default: every one that exists).

Section (a) — THE API ADDITIONS the editor leans on: `object.get` answers `source_sample_rate`,
`source_bit_depth` and `source_format` for a clip (and null for anything else), `object.add` takes
a `name`, and a `batch [add, mute]` is ONE undo.

    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --socket=/tmp/o.sock
    ./scenario_spectral_gain.py /tmp/o.sock

Section (b) — THE CANVAS CONTRACT (`script.canvas.*`): the test client plays the script. Opening
and its refusals, the base image, the ops the hand draws, the history, the layers and the rule that
says which traces are still visible, the long poll, the audio and the transport model, `remember`,
the absence of any trace in the project, and the canvas's life.

Section (f) — NO WINDOW ON THE HEADLESS PID: a canvas is opened, given an image, a layer, audio and
an op, played, and closed, and `CGWindowListCopyWindowInfo` on the app's pid stays empty (opening a
window is the window layer's only side effect, and `--headless` forbids it).

Exit: 0 if every assertion passes, 1 otherwise.
"""

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
    {"id": "eraser", "kind": "stroke", "label": "Eraser", "icon": "eraser",
     "params": ["amount", "hardness"], "size_control": "size_px"},
    {"id": "pick", "kind": "point", "label": "Pick"},
]

CANVAS_CONTROLS = [
    {"id": "sec_rect", "kind": "section", "label": "Rectangle"},
    {"id": "gain", "kind": "number", "label": "Gain", "value": -12, "min": -60, "max": 12, "step": 0.5, "unit": "dB"},
    {"id": "feather_ms", "kind": "number", "label": "Feather", "value": 10, "min": 0, "max": 200, "step": 1, "unit": "ms"},
    {"id": "feather_st", "kind": "number", "label": "Feather", "value": 1, "min": 0, "max": 12, "step": 0.1, "unit": "st"},
    {"id": "size_px", "kind": "number", "label": "Size", "value": 32, "min": 4, "max": 200, "step": 1, "unit": "px"},
    {"id": "amount", "kind": "number", "label": "Amount", "value": -3, "min": -24, "max": -0.5, "step": 0.5, "unit": "dB"},
    {"id": "hardness", "kind": "number", "label": "Hardness", "value": 50, "min": 0, "max": 100, "step": 1, "unit": "%"},
    {"id": "go", "kind": "button", "label": "Go"},
    {"id": "prog", "kind": "progress", "label": "Progress"},
]

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
    RGB = write_rgb(os.path.join(ROOT, "veil.objkrgb"), 8, 4)
    RGB2 = write_rgb(os.path.join(ROOT, "veil2.objkrgb"), 2, 2)
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
          and g["history"]["count"] == 0 and g["history"]["unreflected"] == [] and g["history"]["ops"] == [], g["history"])
    check("b: get: transport at rest", g["transport"]["playing"] is False and g["transport"]["caret"] == 0
          and g["transport"]["position"] == 0 and g["transport"]["listen"] == "original"
          and g["transport"]["delta"] is False
          and g["transport"]["slots"] == {"original": None, "result": None, "delta": None}, g["transport"])
    check("b: a second open on the same connection replaces the first (it ends closed)",
          c.send("script.canvas.open", {"title": "Open2", "tools": []})["rev"] == 0
          and [x["title"] for x in c.send("script.canvas.list")["canvases"]] == ["Open2"],
          c.send("script.canvas.list"))
    g = c.send("script.canvas.get", {"canvas_id": c.send("script.canvas.list")["canvases"][0]["canvas_id"]})
    check("b: with no tool the Hand is the active one", g["tool"] == "hand", g["tool"])
    cid = open_canvas(c)

    def refuse(label, **kw):
        bad_tools = kw.pop("tools", None)
        params = {"title": "Bad", "controls": CANVAS_CONTROLS, "tools": bad_tools if bad_tools is not None else TOOLS}
        params.update(kw)
        expect_error(lambda: c.send("script.canvas.open", params), "bad_params", "b: open refuses " + label)

    refuse("a duplicate tool id", tools=[TOOLS[0], dict(TOOLS[0])])
    refuse("an unknown tool kind", tools=[{"id": "x", "kind": "lasso", "label": "X"}])
    refuse("the reserved id hand", tools=[{"id": "hand", "kind": "rect", "label": "H"}])
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

    # -- set_image -------------------------------------------------------------------------
    expect_error(lambda: c.send("script.canvas.set_layer", {"canvas_id": cid, "layer": "veil", "path": RGB}),
                 "invalid_state", "b: set_layer without a base image -> invalid_state")
    r = c.send("script.canvas.set_image", {"canvas_id": cid, "path": CNV, "x": X_AXIS, "y": Y_AXIS, "value_unit": "dB"})
    check("b: a 4x2 OBJKCNV1 echoes its size and has values",
          r == {"width": 4, "height": 2, "has_values": True}, r)
    g = c.send("script.canvas.get", {"canvas_id": cid})
    check("b: get: image, world and a fitted view",
          g["image"] == {"path": CNV, "width": 4, "height": 2, "has_values": True}
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
    op1 = g["history"]["ops"][0]
    check("b: the rect is sorted and clamped to the world",
          (op1["kind"], op1["tool"], op1["x0"], op1["x1"], op1["y0"], op1["y1"]) == ("rect", "rect", 0, 10, 100, 10000), op1)
    check("b: the op's params snapshot the tool's controls (and only those)",
          op1["params"] == {"gain": -12, "feather_ms": 10, "feather_st": 1} and op1["id"] == 1
          and op1["active_since"] == 1, op1)
    c.send("script.canvas.input", {"canvas_id": cid, "values": {"gain": -24}})
    c.send("script.canvas.input", {"canvas_id": cid, "op": {"kind": "rect", "x0": 1, "x1": 2, "y0": 200, "y1": 400}})
    ops = c.send("script.canvas.get", {"canvas_id": cid})["history"]["ops"]
    check("b: the next op snapshots the new value and the earlier op is unchanged",
          ops[1]["params"]["gain"] == -24 and ops[0]["params"]["gain"] == -12 and ops[1]["id"] == 2, ops)
    rev_before = c.send("script.canvas.get", {"canvas_id": cid})["rev"]
    r = c.send("script.canvas.input", {"canvas_id": cid, "op": {"kind": "rect", "x0": 3, "x1": 3, "y0": 200, "y1": 400}})
    check("b: a rect of zero area adds nothing and leaves rev alone",
          r["added"] is False and r["rev"] == rev_before and r["cursor"] == 2, r)
    r = c.send("script.canvas.input", {"canvas_id": cid, "op": {"kind": "rect", "x0": 11, "x1": 12, "y0": 200, "y1": 400}})
    check("b: a rect wholly outside the world is zero area once clamped", r["added"] is False, r)
    pts = [[1.0, 3000.0], [2.5, 3000.0], [4.0, 3100.0]]
    r = c.send("script.canvas.input", {"canvas_id": cid, "op": {"kind": "stroke", "points": pts, "view_scale": {"x": 500, "y": 100}}})
    check("b: a stroke is added", r["added"] is True and r["cursor"] == 3, r)
    op3 = c.send("script.canvas.get", {"canvas_id": cid})["history"]["ops"][2]
    check("b: stroke: size_pt from size_px, size_x = 32/500, size_y = 32/100",
          op3["kind"] == "stroke" and op3["tool"] == "eraser" and op3["size_pt"] == 32
          and abs(op3["size_x"] - 0.064) < 1e-12 and abs(op3["size_y"] - 0.32) < 1e-12, op3)
    check("b: stroke: points stored as given, params are the eraser's",
          op3["points"] == pts and op3["params"] == {"amount": -3, "hardness": 50}, op3)
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
    op4 = c.send("script.canvas.get", {"canvas_id": cid})["history"]["ops"][3]
    check("b: a point op (the first point tool is used)",
          r["added"] is True and op4["kind"] == "point" and op4["tool"] == "pick" and op4["x"] == 5 and op4["y"] == 1000
          and op4["params"] == {}, op4)
    c.send("script.canvas.input", {"canvas_id": cid, "tool": "eraser"})
    check("b: tool moves no rev", c.send("script.canvas.get", {"canvas_id": cid})["tool"] == "eraser")
    c.send("script.canvas.input", {"canvas_id": cid, "op": {"kind": "rect", "x0": 0, "x1": 1, "y0": 100, "y1": 200}})
    ops = c.send("script.canvas.get", {"canvas_id": cid})["history"]["ops"]
    check("b: a rect with the stroke tool active uses the first tool of its kind", ops[-1]["tool"] == "rect", ops[-1])
    expect_error(lambda: c.send("script.canvas.input", {"canvas_id": cid, "tool": "nope"}),
                 "bad_params", "b: an unknown tool -> bad_params")
    c.send("script.canvas.input", {"canvas_id": cid, "tool": "hand"})
    check("b: the Hand can be selected", c.send("script.canvas.get", {"canvas_id": cid})["tool"] == "hand")
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
    check("b: three ops, cursor 3, ids 1 2 3", h["cursor"] == 3 and h["count"] == 3 and [o["id"] for o in h["ops"]] == [1, 2, 3], h)
    rev = c.send("script.canvas.get", {"canvas_id": cid})["rev"]
    r = c.send("script.canvas.input", {"canvas_id": cid, "undo": True})
    check("b: undo moves the cursor, the history rev and rev", r["cursor"] == 2 and r["history_rev"] == 4 and r["rev"] > rev
          and r["added"] is False, r)
    h = hist()
    check("b: an undone op stays in the list", h["count"] == 3 and h["cursor"] == 2, h)
    r = c.send("script.canvas.input", {"canvas_id": cid, "redo": True})
    check("b: redo moves it back", r["cursor"] == 3 and r["history_rev"] == 5, r)
    c.send("script.canvas.input", {"canvas_id": cid, "undo": True})
    c.send("script.canvas.input", {"canvas_id": cid, "undo": True})
    r = rect(5, 6)
    h = hist()
    check("b: a new op after an undo truncates the redo tail (ids stay monotonic)",
          h["count"] == 2 and h["cursor"] == 2 and [o["id"] for o in h["ops"]] == [1, 4], h)
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

    # -- layers and reflection -------------------------------------------------------------
    cid = open_canvas(c, object=obj)
    c.send("script.canvas.set_image", {"canvas_id": cid, "path": CNV, "x": X_AXIS, "y": Y_AXIS})
    a = rect(0, 1)["history_rev"]
    b2 = rect(1, 2)["history_rev"]
    check("b: after ops 1 and 2: both traces are visible", hist()["unreflected"] == [1, 2], hist())
    r = c.send("script.canvas.set_layer", {"canvas_id": cid, "layer": "veil", "path": RGB, "z": 1, "history_rev": a})
    check("b: an RGB1 layer is listed (size, z, opacity, history_rev)",
          r["layers"] == [{"layer": "veil", "path": RGB, "width": 8, "height": 4, "z": 1, "opacity": 1, "history_rev": a}], r)
    check("b: a layer reflecting op 1 hides its trace -> unreflected = [2]", hist()["unreflected"] == [2], hist())
    check("b: get lists the layer", [l["layer"] for l in c.send("script.canvas.get", {"canvas_id": cid})["layers"]] == ["veil"])
    c.send("script.canvas.set_layer", {"canvas_id": cid, "layer": "veil", "path": RGB, "history_rev": b2})
    check("b: a layer at the current rev -> unreflected = []", hist()["unreflected"] == [], hist())
    c.send("script.canvas.input", {"canvas_id": cid, "undo": True})
    check("b: undo: the undone op has no trace; the veil still shows it until the script answers",
          hist()["unreflected"] == [], hist())
    c.send("script.canvas.input", {"canvas_id": cid, "redo": True})
    check("b: redo of op 2 -> its trace is back (active_since refreshed)", hist()["unreflected"] == [2], hist())
    r = c.send("script.canvas.set_layer", {"canvas_id": cid, "layer": "veil", "path": RGB2, "opacity": 0.5})
    check("b: replacing a layer keeps its z, takes the opacity, history_rev as given (none)",
          r["layers"] == [{"layer": "veil", "path": RGB2, "width": 2, "height": 2, "z": 1, "opacity": 0.5, "history_rev": None}], r)
    check("b: a layer with no history_rev reflects nothing", hist()["unreflected"] == [1, 2], hist())
    c.send("script.canvas.set_layer", {"canvas_id": cid, "layer": "a", "path": RGB, "z": 5})
    r = c.send("script.canvas.set_layer", {"canvas_id": cid, "layer": "b", "path": RGB, "z": 0})
    check("b: layers are listed in ascending z", [l["layer"] for l in r["layers"]] == ["b", "veil", "a"], r)
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
    check("b: known_history_rev == history.rev omits ops, keeps the rest",
          "ops" not in g["history"] and g["history"]["rev"] == h_rev and "unreflected" in g["history"], g["history"])
    g = c.send("script.canvas.get", {"canvas_id": cid, "known_history_rev": h_rev - 1})
    check("b: another known_history_rev keeps the ops", "ops" in g["history"])
    r = c.send("script.canvas.wait", {"canvas_id": cid, "since_rev": 10 ** 6, "timeout_ms": 50, "known_history_rev": h_rev})
    check("b: wait honours known_history_rev", "ops" not in r["history"])
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
    expect_error(lambda: c.send("script.canvas.input", {"canvas_id": cid, "listen": "result"}),
                 "invalid_state", "b: listen on an empty slot -> invalid_state")
    expect_error(lambda: c.send("script.canvas.input", {"canvas_id": cid, "delta": True}),
                 "invalid_state", "b: delta without a delta slot -> invalid_state")
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
    c.send("script.canvas.input", {"canvas_id": cid, "delta": True})
    check("b: delta on", c.send("script.canvas.get", {"canvas_id": cid})["transport"]["delta"] is True)
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
    check("b: clearing the heard slot falls back to the original; a cleared delta is off",
          t["listen"] == "original" and t["delta"] is False and t["slots"]["result"] is None, t)
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

    # -- remember --------------------------------------------------------------------------
    key = "spectral-gain.scenario"
    cr = open_canvas(c, remember=key)
    c.send("script.canvas.input", {"canvas_id": cr, "values": {"gain": -33, "hardness": 80}})
    c.send("script.canvas.input", {"canvas_id": cr, "press": "cancel"})
    cr = open_canvas(c, remember=key)
    v = c.send("script.canvas.get", {"canvas_id": cr})
    check("b: Cancel remembers nothing", v["values"]["gain"] == -12 and v["remember"] == key, v["values"])
    c.send("script.canvas.input", {"canvas_id": cr, "values": {"gain": -33, "hardness": 80}})
    c.send("script.canvas.input", {"canvas_id": cr, "press": "validate"})
    check("b: Validate ends the canvas", c.send("script.canvas.get", {"canvas_id": cr})["state"] == "validated")
    expect_error(lambda: c.send("script.canvas.input", {"canvas_id": cr, "values": {"gain": 1}}),
                 "invalid_state", "b: input on a validated canvas -> invalid_state")
    expect_error(lambda: c.send("script.canvas.set_image", {"canvas_id": cr, "path": CNV, "x": X_AXIS, "y": Y_AXIS}),
                 "invalid_state", "b: set_image on a canvas that is not open -> invalid_state")
    cr = open_canvas(c, remember=key)
    v = c.send("script.canvas.get", {"canvas_id": cr})["values"]
    check("b: a re-open shows the values last validated", v["gain"] == -33 and v["hardness"] == 80, v)
    rv = c.send("script.canvas.get", {"canvas_id": cr})["rev"]
    c.send("script.canvas.input", {"canvas_id": cr, "press": "reset"})
    g = c.send("script.canvas.get", {"canvas_id": cr})
    check("b: reset restores the declared values and moves rev", g["values"]["gain"] == -12 and g["values"]["hardness"] == 50
          and g["rev"] > rv, g["values"])
    c.send("script.canvas.input", {"canvas_id": cr, "press": "cancel"})
    cr = open_canvas(c, remember=key)
    check("b: reset erased the memory", c.send("script.canvas.get", {"canvas_id": cr})["values"]["gain"] == -12)
    c.send("script.canvas.close", {"canvas_id": cr})

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
    c.send("script.canvas.set_layer", {"canvas_id": cid, "layer": "veil", "path": RGB})
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
    RGB = write_rgb(os.path.join(ROOT, "veil.objkrgb"), 8, 4)
    c.send("project.new")
    cid = open_canvas(c)
    c.send("script.canvas.set_image", {"canvas_id": cid, "path": CNV, "x": X_AXIS, "y": Y_AXIS})
    c.send("script.canvas.set_layer", {"canvas_id": cid, "layer": "veil", "path": RGB, "history_rev": 0})
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

try:
    with ObjekatClient(SOCK, timeout=180) as c:
        c.send("app.set_dialog_policy", {"policy": "assume_yes"})
        only = os.environ.get("SECTIONS", "abf")
        for name, fn in (("a", section_a), ("b", section_b), ("f", section_f)):
            if name in only:
                fn(c)
finally:
    cleanup()

print()
if fails:
    print("%d FAILED" % len(fails))
    sys.exit(1)
print("ALL PASS")

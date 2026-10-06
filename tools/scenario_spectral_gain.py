#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The spectral editor, app side — driven headless (@see plan_spectral_gain.md, section 6).

Standard library only. `SECTIONS=` picks the sections to run (default: every one that exists).

Section (a) — THE API ADDITIONS the editor leans on: `object.get` answers `source_sample_rate`,
`source_bit_depth` and `source_format` for a clip (and null for anything else), `object.add` takes
a `name`, and a `batch [add, mute]` is ONE undo.

    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --socket=/tmp/o.sock
    ./scenario_spectral_gain.py /tmp/o.sock

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

try:
    with ObjekatClient(SOCK, timeout=180) as c:
        c.send("app.set_dialog_policy", {"policy": "assume_yes"})
        only = os.environ.get("SECTIONS", "ab")
        for name, fn in (("a", section_a),):
            if name in only:
                fn(c)
finally:
    cleanup()

print()
if fails:
    print("%d FAILED" % len(fails))
    sys.exit(1)
print("ALL PASS")

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The LEFT trim of a LOOPING clip keeps the pattern anchored (file AND timeline).

    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --language=en \
        --socket=/tmp/o.sock
    ./scenario_trim_loop.py /tmp/o.sock

@see Shared/LoopRetrim.swift, EditViewModel+LoopRetrim.swift: the loop bounds are LOCAL seconds, so
moving the left edge used to slide the pattern inside the file. Now the repeats keep their grid, the
trim only moves the window, and what is heard at an instant that stays inside the window is unchanged.

Fixture (as scenario_speed_loop.py): a 1 s ramp, looped, stretched to 4 s, laid at 2 s; the offline
render [0, 8] is the REFERENCE every other render is compared against.

  T1  trim +0.25 -> source offset 0.25, IN -0.25, OUT 0.75; the render is the reference on [2.25, 6]
  T2  trim +1.5  -> offset 0.5, IN -0.5; not silent; identical on [3.5, 6]
  T3  exact round trips (+0.25, +1.5, and several small steps)
  T4  extension to the left shows the previous repeat; [2, 6] unchanged; an object at 0 stays at 0
  T5  IN INSIDE the block ([0.25, 0.75]) then trim +0.1: the grid is fixed (renders from 1.0: a render
      starting at 0 plays the file from its start on the first pass when the loop IN is > 0 and the
      clip enters at offset 0 — an engine quirk that predates this work, see the end of the file)
  T6  speed 2, then trim
  T7  undo gives the exact state back
  T8  a non-looping clip: the ordinary trim, unchanged
  T9  loop off / on after a trim
  N1  a plain cut of a looping clip: the right piece plays the same pattern
  N2  an object laid over its head / its middle (resolveOverlaps): the kept parts are unchanged
  N3  a time selection deleted from its head / its middle (carve), and a copied passage pasted away

Exit: 0 if every assertion passes, 1 otherwise.
"""

import os, struct, sys, tempfile

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient

if len(sys.argv) != 2:
    print(__doc__)
    sys.exit(2)

SOCK = sys.argv[1]
WORK = tempfile.mkdtemp(prefix="objekat_trimloop_")
SR = 48000
L = 1.0
TOL = 5e-3
fails = []
count = 0


def check(label, ok, detail=""):
    global count
    count += 1
    if ok:
        print("ok    " + label)
    else:
        fails.append(label)
        print("FAIL  %s  %s" % (label, detail))


def near(a, b, eps=1e-6):
    return a is not None and abs(a - b) < eps


def write_wav(path, x):
    i = np.round(np.asarray(x) * (2 ** 23 - 1)).astype(np.int32)
    b = np.stack([i & 255, (i >> 8) & 255, (i >> 16) & 255], axis=1).astype(np.uint8)
    data = np.repeat(b, 2, axis=0).tobytes()
    with open(path, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVE")
        f.write(b"fmt " + struct.pack("<IHHIIHH", 16, 1, 2, SR, SR * 6, 6, 24))
        f.write(b"data" + struct.pack("<I", len(data)) + data)


def write_ramp(path, seconds):
    write_wav(path, np.linspace(-0.8, 0.8, int(seconds * SR)))


def write_zeros(path, seconds):
    write_wav(path, np.zeros(int(seconds * SR)))


def read_channel0(path):
    raw = open(path, "rb").read()
    pos, fmt, data = 12, None, b""
    while pos + 8 <= len(raw):
        cid, size = raw[pos:pos + 4], struct.unpack("<I", raw[pos + 4:pos + 8])[0]
        if cid == b"fmt ":
            fmt = struct.unpack("<HHIIHH", raw[pos + 8:pos + 24])
        elif cid == b"data":
            data = raw[pos + 8:pos + 8 + size]
        pos += 8 + size + (size & 1)
    _, ch, _, _, _, bits = fmt
    assert bits == 24, bits
    n = len(data) // 3
    b = np.frombuffer(data[:n * 3], dtype=np.uint8).reshape(n, 3).astype(np.int32)
    v = b[:, 0] | (b[:, 1] << 8) | (b[:, 2] << 16)
    v = np.where(v >= 2 ** 23, v - 2 ** 24, v)
    return (v / 2.0 ** 23)[::ch]


RAMP = os.path.join(WORK, "ramp.wav")
ZERO1 = os.path.join(WORK, "zero1.wav")
ZERO09 = os.path.join(WORK, "zero09.wav")
write_ramp(RAMP, L)
write_zeros(ZERO1, 1.0)
write_zeros(ZERO09, 0.9)


def seg(x, a, b):
    """The samples of a render over [a, b] seconds."""
    return x[int(round(a * SR)):int(round(b * SR))]


def maxdiff(x, y, a, b, ya=None):
    """Largest |x - y| over [a, b] of x, against y read from `ya` (default: the same instants)."""
    ya = a if ya is None else ya
    sx, sy = seg(x, a, b), seg(y, ya, ya + (b - a))
    n = min(len(sx), len(sy))
    return float(np.max(np.abs(sx[:n] - sy[:n]))) if n else 1e9


def peak(x, a, b):
    s = seg(x, a, b)
    return float(np.max(np.abs(s))) if len(s) else 0.0


with ObjekatClient(SOCK) as c:
    def cmd(name, **params):
        return c.send(name, params or None)

    serial = [0]

    def mix(start=0.0, end=8.0):
        serial[0] += 1
        out = os.path.join(WORK, "r%04d.wav" % serial[0])
        r = cmd("export.run", format="wav", sample_rate=SR, bit_depth=24, dithering=False,
                start=start, end=end, path=out)
        job = cmd("job.wait", id=r["job_id"], timeout_ms=180000)
        res = job.get("result", {})
        assert res.get("phase") != "failed" and "error" not in res, job
        # padded so that index = absolute time x SR whatever the render's start
        return np.concatenate([np.zeros(int(round(start * SR))), read_channel0(out)])

    def clear():
        ids = [o["id"] for o in cmd("object.list")["objects"] if not o.get("parent")]
        if ids:
            cmd("object.remove", ids=ids)
        cmd("timesel.clear")
        cmd("selection.clear")
        cmd("debug.transport_loop", enabled=False)

    def looped_clip(start=2.0, factor=4.0, lane=0):
        clip = cmd("object.add", path=RAMP, lane=lane, start=start)["id"]
        cmd("object.set_loop", id=clip, enabled=True)
        cmd("object.set_duration", id=clip, duration=factor * L)
        got = cmd("object.get", id=clip)
        assert near(got["duration"], factor * L) and got["loop"], got
        return clip

    def st(clip):
        o = cmd("object.get", id=clip)
        return (o["start"], o["duration"], o["source_offset"], o["loop"],
                o.get("loop_start"), o.get("loop_end"), o["speed"])

    def trim_left(clip, new_start, end=6.0):
        cmd("object.trim", id=clip, start=new_start, duration=end - new_start)

    def clips_by_start():
        objs = [o for o in cmd("object.list")["objects"] if not o.get("parent")]
        return sorted(objs, key=lambda o: o["start"])

    def same(label, ref, got, a, b, ya=None):
        d = maxdiff(got, ref, a, b, ya)
        check(label, d < TOL, "max diff %.5f" % d)

    # ------------------------------------------------------------------ reference
    clear()
    clip = looped_clip()
    REF = mix()
    check("REF fixture: pattern present on [2, 6], silent outside",
          peak(REF, 2.0, 6.0) > 0.7 and peak(REF, 0.0, 1.95) < 1e-4 and peak(REF, 6.05, 8.0) < 1e-4,
          "%s %s %s" % (peak(REF, 2.0, 6.0), peak(REF, 0, 1.95), peak(REF, 6.05, 8)))

    # ------------------------------------------------------------------ T1
    trim_left(clip, 2.25)
    s, d, so, lp, ls, le, sp = st(clip)
    check("T1 start 2.25, duration 3.75", near(s, 2.25) and near(d, 3.75), str((s, d)))
    check("T1 source offset 0.25", near(so, 0.25), str(so))
    check("T1 IN -0.25, OUT 0.75", near(ls, -0.25) and near(le, 0.75), str((ls, le)))
    check("T1 still looping", lp is True)
    R = mix()
    same("T1 render identical to the reference on [2.26, 5.99]", REF, R, 2.26, 5.99)
    same("T1 the pattern restarts at 3", REF, R, 2.99, 3.02)
    same("T1 restart at 4", REF, R, 3.99, 4.02)
    same("T1 restart at 5", REF, R, 4.99, 5.02)
    check("T1 nothing before the new edge", peak(R, 0.0, 2.2) < 1e-4)

    # ------------------------------------------------------------------ T3 (first half): back to the start
    trim_left(clip, 2.0)
    s, d, so, lp, ls, le, sp = st(clip)
    check("T3 round trip +0.25: exactly the initial state",
          near(s, 2.0, 1e-9) and near(d, 4.0, 1e-9) and near(so, 0.0, 1e-9)
          and near(ls, 0.0, 1e-9) and near(le, 1.0, 1e-9), str((s, d, so, ls, le)))
    same("T3 round trip +0.25: the render is the reference again", REF, mix(), 1.9, 6.1)

    # ------------------------------------------------------------------ T2
    trim_left(clip, 3.5)
    s, d, so, lp, ls, le, sp = st(clip)
    check("T2 offset 0.5 (a whole repeat swallowed)", near(so, 0.5) and near(s, 3.5), str((s, so)))
    check("T2 IN -0.5, OUT 0.5", near(ls, -0.5) and near(le, 0.5), str((ls, le)))
    R = mix()
    check("T2 not silent", peak(R, 3.5, 6.0) > 0.7, str(peak(R, 3.5, 6.0)))
    same("T2 identical to the reference on [3.51, 5.99]", REF, R, 3.51, 5.99)
    trim_left(clip, 2.0)
    s, d, so, lp, ls, le, sp = st(clip)
    check("T3 round trip +1.5: exactly the initial state",
          near(s, 2.0, 1e-9) and near(d, 4.0, 1e-9) and near(so, 0.0, 1e-9)
          and near(ls, 0.0, 1e-9) and near(le, 1.0, 1e-9), str((s, d, so, ls, le)))
    for i in range(1, 9):
        trim_left(clip, 2.0 + 0.07 * i)
    for i in range(7, -1, -1):
        trim_left(clip, 2.0 + 0.07 * i)
    s, d, so, lp, ls, le, sp = st(clip)
    check("T3 eight steps forward and back: still the initial state",
          near(s, 2.0, 1e-6) and near(so, 0.0, 1e-6) and near(ls, 0.0, 1e-6) and near(le, 1.0, 1e-6),
          str((s, d, so, ls, le)))

    # ------------------------------------------------------------------ T4
    trim_left(clip, 1.0)
    s, d, so, lp, ls, le, sp = st(clip)
    check("T4 extended to 1.0: start 1.0, the grid holds (offset 0, IN 0)",
          near(s, 1.0) and near(so, 0.0) and near(ls, 0.0), str((s, so, ls)))
    R = mix()
    same("T4 [2, 6] unchanged", REF, R, 2.01, 5.99)
    same("T4 [1, 2] plays the previous repeat", REF, R, 1.01, 1.99, ya=2.01)
    trim_left(clip, 1.75)
    s, d, so, lp, ls, le, sp = st(clip)
    check("T4 extended by 0.25: enters the file 0.75 in", near(so, 0.75) and near(ls, -0.75), str((so, ls)))
    R = mix()
    same("T4 extended by 0.25: [2, 6] unchanged", REF, R, 2.01, 5.99)
    same("T4 extended by 0.25: [1.76, 2] is the end of the previous repeat", REF, R, 1.76, 1.99, ya=2.76)
    # an object laid at 0: trimmed to the left, it stays at the floor
    clear()
    z = looped_clip(start=0.0)
    cmd("object.trim", id=z, start=-1.0, duration=5.0)
    s, d, so, lp, ls, le, sp = st(z)
    check("T4 an object at 0 cannot go left: it stays at 0 (floor)", near(s, 0.0) and near(so, 0.0), str((s, so)))
    # an object at 2 extended far to the left stops at 0
    clear()
    clip = looped_clip()
    cmd("object.trim", id=clip, start=-1.0, duration=7.0)
    s, d, so, lp, ls, le, sp = st(clip)
    check("T4 extended past 0: floored at 0 and still on the grid", near(s, 0.0) and near(so, 0.0) and near(ls, 0.0),
          str((s, so, ls)))
    R = mix()
    same("T4 extended to 0: the render over [2, 6] is the reference", REF, R, 2.01, 5.99)
    same("T4 extended to 0: [0, 2] plays the previous repeats", REF, R, 0.01, 1.99, ya=2.01)

    # ------------------------------------------------------------------ T5
    clear()
    clip = looped_clip()
    cmd("object.set_loop_range", id=clip, start=0.25, end=0.75)
    # NB the renders of this block start at 1.0, not 0: see the note at the end of the file.
    R0 = mix(1.0)
    check("T5 fixture: IN/OUT [0.25, 0.75] read back", near(st(clip)[4], 0.25) and near(st(clip)[5], 0.75),
          str(st(clip)))
    trim_left(clip, 2.1)
    s, d, so, lp, ls, le, sp = st(clip)
    check("T5 canonical form: IN <= 0 and the period kept",
          ls <= 1e-9 and near(le - ls, 0.5), str((ls, le)))
    R = mix(1.0)
    same("T5 trim +0.1: the grid is fixed (render identical on [2.11, 5.99])", R0, R, 2.11, 5.99)
    trim_left(clip, 1.9)
    R = mix(1.0)
    same("T5 extension to 1.9: [2, 6] unchanged", R0, R, 2.01, 5.99)
    trim_left(clip, 2.0)
    same("T5 back at the original edge: identical", R0, mix(1.0), 2.01, 5.99)

    # ------------------------------------------------------------------ T6
    clear()
    clip = looped_clip()
    cmd("object.set_speed", id=clip, ratio=2.0)
    s, d, so, lp, ls, le, sp = st(clip)
    check("T6 fixture: speed 2, duration 2, bounds [0, 0.5]", near(sp, 2.0) and near(d, 2.0) and near(le, 0.5),
          str((sp, d, ls, le)))
    R0 = mix()
    cmd("object.trim", id=clip, start=2.2, duration=1.8)
    s, d, so, lp, ls, le, sp = st(clip)
    check("T6 speed 2: offset advances by 0.2 x 2 = 0.4, IN -0.2, OUT 0.3",
          near(so, 0.4) and near(ls, -0.2) and near(le, 0.3), str((so, ls, le)))
    same("T6 speed 2: identical on [2.21, 3.99]", R0, mix(), 2.21, 3.99)
    cmd("object.trim", id=clip, start=2.7, duration=1.3)
    s, d, so, lp, ls, le, sp = st(clip)
    check("T6 speed 2: +0.7 = one repeat + 0.2", near(so, 0.4) and near(ls, -0.2), str((so, ls)))
    same("T6 speed 2, past a period: identical on [2.71, 3.99]", R0, mix(), 2.71, 3.99)

    # ------------------------------------------------------------------ T7
    clear()
    clip = looped_clip()
    R0 = mix()
    before = st(clip)
    trim_left(clip, 2.25)
    cmd("edit.undo")
    after = st(clip)
    check("T7 undo: the exact state (start, duration, offset, bounds)",
          all(near(a, b, 1e-9) for a, b in zip(before[:3] + before[4:6], after[:3] + after[4:6]))
          and before[3] == after[3], "%s -> %s" % (before, after))
    same("T7 undo: the render is the reference", R0, mix(), 1.9, 6.1)

    # ------------------------------------------------------------------ T8
    clear()
    clip = cmd("object.add", path=RAMP, lane=0, start=2.0)["id"]
    R0 = mix()
    cmd("object.trim", id=clip, start=2.25, duration=0.75)
    s, d, so, lp, ls, le, sp = st(clip)
    check("T8 not looping: ordinary trim (offset 0.25, no loop)", near(so, 0.25) and lp is False, str((so, lp)))
    same("T8 not looping: identical on [2.26, 2.99]", R0, mix(), 2.26, 2.99)

    # ------------------------------------------------------------------ T9
    clear()
    clip = looped_clip()
    R0 = mix()
    trim_left(clip, 2.25)
    cmd("object.set_loop", id=clip, enabled=False)
    s, d, so, lp, ls, le, sp = st(clip)
    check("T9 loop off: not looping, the offset kept", lp is False and near(so, 0.25), str((lp, so)))
    R = mix()
    same("T9 loop off: the first (partial) repeat still plays, identical on [2.26, 2.99]", R0, R, 2.26, 2.99)
    cmd("object.set_loop", id=clip, enabled=True)
    s, d, so, lp, ls, le, sp = st(clip)
    R = mix()
    check("T9 loop back on: looping and not silent", lp is True and peak(R, 2.3, 6.0) > 0.7,
          str((lp, so, ls, le, peak(R, 2.3, 6.0))))
    same("T9 loop back on: identical on [2.26, 2.99]", R0, R, 2.26, 2.99)

    # ------------------------------------------------------------------ N1: a plain cut
    clear()
    clip = looped_clip()
    R0 = mix()
    cmd("object.split_at", ids=[clip], seconds=3.25)
    pieces = clips_by_start()
    check("N1 the cut gives two pieces", len(pieces) == 2, str(len(pieces)))
    if len(pieces) == 2:
        s, d, so, lp, ls, le, sp = st(pieces[1]["id"])
        check("N1 right piece: offset 0.25, IN -0.25, OUT 0.75, still looping",
              near(so, 0.25) and near(ls, -0.25) and near(le, 0.75) and lp is True, str((so, ls, le, lp)))
    R = mix()
    same("N1 left part identical", R0, R, 2.01, 3.24)
    same("N1 right part identical", R0, R, 3.27, 5.99)
    cmd("edit.undo")
    same("N1 undo: the reference again", R0, mix(), 1.9, 6.1)

    # ------------------------------------------------------------------ N2: an object laid over
    clear()
    clip = looped_clip()
    R0 = mix()
    cover = cmd("object.add", path=ZERO1, lane=0, start=1.5)["id"]       # covers [1.5, 2.5]: the head goes
    if any(o["id"] == clip for o in clips_by_start()):
        s, d, so, lp, ls, le, sp = st(clip)
        check("N2 head overwritten: start 2.5, offset 0.5, IN -0.5",
              near(s, 2.5) and near(so, 0.5) and near(ls, -0.5), str((s, so, ls)))
    else:
        check("N2 head overwritten: the looping clip survived", False, "gone")
    R = mix()
    same("N2 head overwritten: the kept part is unchanged on [2.51, 5.99]", R0, R, 2.51, 5.99)
    cmd("edit.undo")
    same("N2 undo: the reference again", R0, mix(), 1.9, 6.1)

    clear()
    clip = looped_clip()
    cover = cmd("object.add", path=ZERO09, lane=0, start=3.0)["id"]     # a hole [3.0, 3.9]
    others = [o for o in clips_by_start() if o["id"] != cover and o["start"] > 3.5]
    if others:
        s, d, so, lp, ls, le, sp = st(others[0]["id"])
        check("N2 hole: the right piece starts at 3.9, offset 0.9, IN -0.9, OUT 0.1",
              near(s, 3.9) and near(so, 0.9) and near(ls, -0.9) and near(le, 0.1), str((s, so, ls, le)))
    else:
        check("N2 hole: a right piece exists", False, "none")
    R = mix()
    same("N2 hole: left part unchanged", R0, R, 2.01, 2.99)
    same("N2 hole: right part unchanged", R0, R, 3.92, 5.99)
    check("N2 hole: silent inside", peak(R, 3.02, 3.88) < 1e-4, str(peak(R, 3.02, 3.88)))

    # ------------------------------------------------------------------ N3: carve a time selection
    clear()
    clip = looped_clip()
    cmd("timesel.set", start=1.5, end=2.6, lanes=[0])
    cmd("timesel.delete")
    pieces = clips_by_start()
    if len(pieces) == 1:
        s, d, so, lp, ls, le, sp = st(pieces[0]["id"])
        check("N3 head carved: start 2.6, offset 0.6, IN -0.6",
              near(s, 2.6) and near(so, 0.6) and near(ls, -0.6), str((s, so, ls)))
    else:
        check("N3 head carved: one piece left", False, str(len(pieces)))
    R = mix()
    same("N3 head carved: the kept part is unchanged", R0, R, 2.61, 5.99)
    cmd("timesel.clear")
    cmd("edit.undo")
    same("N3 undo: the reference again", R0, mix(), 1.9, 6.1)

    clear()
    clip = looped_clip()
    cmd("timesel.set", start=3.0, end=3.9, lanes=[0])
    cmd("timesel.delete")
    pieces = clips_by_start()
    check("N3 middle carved: two pieces", len(pieces) == 2, str(len(pieces)))
    if len(pieces) == 2:
        s, d, so, lp, ls, le, sp = st(pieces[1]["id"])
        check("N3 middle carved: right piece offset 0.9, IN -0.9, OUT 0.1",
              near(s, 3.9) and near(so, 0.9) and near(ls, -0.9) and near(le, 0.1), str((s, so, ls, le)))
    R = mix()
    same("N3 middle carved: left part unchanged", R0, R, 2.01, 2.99)
    same("N3 middle carved: right part unchanged", R0, R, 3.92, 5.99)
    check("N3 middle carved: silent inside", peak(R, 3.02, 3.88) < 1e-4, str(peak(R, 3.02, 3.88)))
    cmd("timesel.clear")

    # a passage copied and pasted away (the clipboard's fragments)
    clear()
    clip = looped_clip()
    R0 = mix(0.0, 14.0)
    cmd("timesel.set", start=2.6, end=3.4, lanes=[0])
    cmd("timesel.copy")
    cmd("timesel.set", start=10.0, end=10.8, lanes=[0])
    cmd("clipboard.paste")
    R = mix(0.0, 14.0)
    same("N3 a passage pasted at 10: the same sound as [2.6, 3.4]", R0, R, 10.01, 10.79, ya=2.61)
    check("N3 the pasted passage is not silent", peak(R, 10.0, 10.8) > 0.5, str(peak(R, 10.0, 10.8)))
    same("N3 the source clip is untouched", R0, R, 2.01, 5.99)

    clear()

print("\n%d assertions, %d failed" % (count, len(fails)))
print("ALL PASS" if not fails else "FAILED:\n  " + "\n  ".join(fails))
sys.exit(1 if fails else 0)

# NOTE (T5, an engine quirk that predates the loop-anchored trim). With a loop whose IN is > 0 in the
# FILE and a clip entering at offset 0 (offsetForRead == 0 in OBJEngineCore updatePosition), an offline
# render that starts at 0 (or exactly on the clip) plays the file from its start on the first pass
# (0.01 at the clip's first sample instead of IN + 0.01), then wraps on [IN, OUT]; a render that starts
# anywhere else (1.0, 2.3 ...) enters at IN, as the model and the drawing say. Measured on the
# fixture 1 s ramp, IN 0.25 / OUT 0.75. Not touched here; T5 therefore renders from 1.0.

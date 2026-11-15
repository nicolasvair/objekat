#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Changing the SPEED of a LOOPING clip keeps its loop (the number of repetitions).

    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --language=en \
        --socket=/tmp/o.sock
    ./scenario_speed_loop.py /tmp/o.sock

@see EditViewModel.applySpeed: a looping clip is longer than its material on purpose, so the
material bound must not apply (the duration scales by oldSpeed / newSpeed, bounded by the
neighbour only), and the loop's IN/OUT bounds — local timeline seconds — scale by the same factor.

  B1  a clip of material L = 1 s looped and stretched to 4 L, speed 2 -> 2 L, loop still on, bounds / 2,
      and the offline render shows the pattern 4 times.
  B2  speed 0.5 -> 8 L; bounded by the neighbour when there is one.
  B3  a round trip 1 -> 1.06 -> 1 gives back the same duration and bounds.
  B4  a TRANSPORT loop is not touched by a speed change.
  B5  a clip that does NOT loop stays bounded by its material (forwards and reversed).
  B6  undo gives the duration and the bounds back.

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
WORK = tempfile.mkdtemp(prefix="objekat_speedloop_")
SR = 48000
L = 1.0
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


def write_ramp(path, seconds):
    n = int(seconds * SR)
    x = np.linspace(-0.8, 0.8, n)
    i = np.round(x * (2 ** 23 - 1)).astype(np.int32)
    b = np.stack([i & 255, (i >> 8) & 255, (i >> 16) & 255], axis=1).astype(np.uint8)
    data = np.repeat(b, 2, axis=0).tobytes()
    with open(path, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVE")
        f.write(b"fmt " + struct.pack("<IHHIIHH", 16, 1, 2, SR, SR * 6, 6, 24))
        f.write(b"data" + struct.pack("<I", len(data)) + data)


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
write_ramp(RAMP, L)

with ObjekatClient(SOCK) as c:
    def cmd(name, **params):
        return c.send(name, params or None)

    serial = [0]

    def mix(start, end):
        serial[0] += 1
        out = os.path.join(WORK, "r%04d.wav" % serial[0])
        r = cmd("export.run", format="wav", sample_rate=SR, bit_depth=24, dithering=False,
                start=start, end=end, path=out)
        job = cmd("job.wait", id=r["job_id"], timeout_ms=180000)
        res = job.get("result", {})
        assert res.get("phase") != "failed" and "error" not in res, job
        return read_channel0(out)

    def clear():
        ids = [o["id"] for o in cmd("object.list")["objects"] if not o.get("parent")]
        if ids:
            cmd("object.remove", ids=ids)
        cmd("timesel.clear")
        cmd("selection.clear")
        cmd("debug.transport_loop", enabled=False)

    def looped_clip(start=2.0, factor=4.0, lane=0):
        """A clip of material L, looped, stretched to `factor` L."""
        clip = cmd("object.add", path=RAMP, lane=lane, start=start)["id"]
        cmd("object.set_loop", id=clip, enabled=True)
        cmd("object.set_duration", id=clip, duration=factor * L)
        got = cmd("object.get", id=clip)
        assert near(got["duration"], factor * L) and got["loop"], got
        return clip

    def state(clip):
        o = cmd("object.get", id=clip)
        return o["duration"], o["loop"], o.get("loop_start"), o.get("loop_end"), o["speed"]

    # ---- B1: speed 2 on a looped clip stretched to 4 L ---------------------------------------
    clear()
    clip = looped_clip()
    d, lp, ls, le, sp = state(clip)
    check("B1 the fixture: 4 L, looping, bounds [0, L]", near(d, 4.0) and lp and near(ls, 0) and near(le, L),
          str((d, lp, ls, le)))
    cmd("object.set_speed", id=clip, ratio=2.0)
    d, lp, ls, le, sp = state(clip)
    check("B1 speed 2: duration 2 L (the repetitions are kept)", near(d, 2.0), "duration %s" % d)
    check("B1 speed 2: still looping", lp is True)
    check("B1 speed 2: bounds halved", near(ls, 0.0) and near(le, 0.5), "%s %s" % (ls, le))
    check("B1 speed 2: speed stored", near(sp, 2.0), str(sp))
    x = mix(2.0, 4.0)
    P = int(0.5 * SR)
    seg = x[: 4 * P]
    check("B1 render: 2 s long and audible to the end",
          len(x) >= 4 * P - 8 and float(np.abs(seg[-P // 4:]).max()) > 0.3,
          "len %d, tail peak %.3f" % (len(x), float(np.abs(seg[-P // 4:]).max()) if len(seg) else -1))
    # the ramp resets: a fall of more than 0.5 within a few samples, counted once per cluster
    fall = (seg[4:] - seg[:-4]) < -0.5
    idx = np.flatnonzero(fall)
    resets = 0 if len(idx) == 0 else 1 + int(np.sum(np.diff(idx) > 200))
    check("B1 render: the pattern is heard 4 times (3 resets)", resets == 3, "resets %d" % resets)
    a = seg[int(0.02 * SR):P - int(0.02 * SR)]
    b = seg[P + int(0.02 * SR):2 * P - int(0.02 * SR)]
    check("B1 render: period L / 2", float(np.abs(a - b).max()) < 5e-3, "max diff %.5f" % float(np.abs(a - b).max()))

    # ---- B6 (here: right after B1): undo gives everything back --------------------------------
    cmd("edit.undo")
    d, lp, ls, le, sp = state(clip)
    check("B6 undo: duration back", near(d, 4.0), str(d))
    check("B6 undo: bounds back", near(ls, 0.0) and near(le, L), "%s %s" % (ls, le))
    check("B6 undo: speed back and loop kept", near(sp, 1.0) and lp, "%s %s" % (sp, lp))

    # ---- B2: speed 0.5 -> 8 L, and bounded by a neighbour --------------------------------------
    clear()
    clip = looped_clip()
    cmd("object.set_speed", id=clip, ratio=0.5)
    d, lp, ls, le, sp = state(clip)
    check("B2 speed 0.5: 8 L", near(d, 8.0), str(d))
    check("B2 speed 0.5: loop kept, bounds doubled", lp and near(ls, 0.0) and near(le, 2.0), "%s %s %s" % (lp, ls, le))
    clear()
    clip = looped_clip()
    cmd("object.add", path=RAMP, lane=0, start=8.0)          # the neighbour, 6 s after the start
    cmd("object.set_speed", id=clip, ratio=0.5)
    d, lp, ls, le, sp = state(clip)
    check("B2 a neighbour bounds the lengthening (6 s)", near(d, 6.0), str(d))
    check("B2 with a neighbour: loop kept, bounds doubled (the factor is the speed's, not the duration's)",
          lp and near(le, 2.0), "%s %s" % (lp, le))

    # ---- B3: round trip -------------------------------------------------------------------------
    clear()
    clip = looped_clip()
    cmd("object.set_speed", id=clip, ratio=1.06)
    d1 = state(clip)[0]
    cmd("object.set_speed", id=clip, ratio=1.0)
    d, lp, ls, le, sp = state(clip)
    check("B3 1 -> 1.06 shortens", d1 < 4.0 - 1e-3, str(d1))
    check("B3 round trip: same duration", near(d, 4.0, 1e-9), str(d))
    check("B3 round trip: same bounds", near(ls, 0.0, 1e-9) and near(le, L, 1e-9), "%s %s" % (ls, le))
    check("B3 round trip: loop kept", lp is True)

    # ---- B4: the TRANSPORT loop is not the clip's -----------------------------------------------
    clear()
    clip = looped_clip()
    cmd("debug.transport_loop", start=2.0, end=4.0, enabled=True)
    cmd("object.set_speed", id=clip, ratio=2.0)
    t = cmd("transport.state")
    check("B4 the transport loop is still on", t.get("loop_enabled") is True, str(t))
    check("B4 and keeps its region", t.get("loop_region") == [2.0, 4.0], str(t.get("loop_region")))
    cmd("debug.transport_loop", enabled=False)

    # ---- B5: a clip that does not loop stays bounded by its material ----------------------------
    clear()
    clip = cmd("object.add", path=RAMP, lane=0, start=2.0)["id"]
    cmd("object.set_speed", id=clip, ratio=2.0)
    d = state(clip)[0]
    check("B5 not looping, speed 2: half the material", near(d, 0.5), str(d))
    cmd("object.set_speed", id=clip, ratio=0.25)
    o = cmd("object.get", id=clip)
    check("B5 not looping, speed 0.25: 4 L, and the source range does not overrun the file",
          near(o["duration"], 4.0) and o["source_offset"] + o["duration"] * o["speed"] <= o["file_duration"] + 1e-6,
          str(o["duration"]))
    check("B5 not looping: no loop bounds invented", o["loop"] is False)
    clear()
    clip = cmd("object.add", path=RAMP, lane=0, start=2.0)["id"]
    cmd("object.set_reversed", id=clip, reversed=True)
    cmd("object.set_speed", id=clip, ratio=0.5)
    o = cmd("object.get", id=clip)
    check("B5 reversed, speed 0.5: 2 L", near(o["duration"], 2.0), str(o["duration"]))
    check("B5 reversed: the source range stays inside the file",
          o["source_offset"] >= -1e-9 and o["source_offset"] + o["duration"] * o["speed"] <= o["file_duration"] + 1e-6,
          "%s %s" % (o["source_offset"], o["duration"]))

    clear()

print("\n%d assertions, %d failed" % (count, len(fails)))
print("ALL PASS" if not fails else "FAILED:\n  " + "\n  ".join(fails))
sys.exit(1 if fails else 0)

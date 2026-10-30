#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Cutting a LOOPING group keeps the phase of its pattern — proven on the rendered AUDIO.

    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --language=en \
        --socket=/tmp/o.sock
    ./scenario_group_loop_cut.py /tmp/o.sock

A looping group is a porthole on a repeating pattern: the two halves of a cut must, laid side by
side, sound exactly like the group did (@see EditViewModel.loopedGroupRightHalf). So every case
exports the mix BEFORE, cuts, exports the same stretch AFTER and subtracts, sample for sample.

The EXPORT and not `object.render_isolated`: that one opens the container on the rendered range and
sets its offset to the range's start (`openContainer`, OBJEngineCore.mm), so it reads a looping
group at `IN + (T mod P)` and not at the phase playback has.

The fixture is a RAMP (sample value = position in the file), which makes any error READABLE: the
difference is not just "not null", it says how many seconds the pattern slid (`measured delay`).

The engine's fold, which the right half must reproduce (start S, IN = S + a, period P, a local to
the group; `refreshContainerSpanForKey:`, `ContainerClipNode`):

    material heard at T = IN + ((T − O) mod P)        O = min(S, IN), the origin of the repeats

The looped cases name S, a, P and the cut c:
  A. a > 0, cut past IN, the reported case (a = 1 s).    B. the cut BEFORE IN.    C. a ≥ P.
  D. S = 0: the copies land below the timeline's zero.   E. a = 0 and a right half cut again
  (a < 0), which never slid.  F. two children.           G. a sub-group, cut through its parent.
  H. keep=right, window_only, and the undo.              I. a hole traced by a time selection.
  J. a fragment copied by a time selection.              K. reopened from disk.
  L. the group's head deleted by a time selection.

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
WORK = tempfile.mkdtemp(prefix="objekat_loopcut_")
SR = 48000
FILE_SECONDS = 8.0
EPS = 2e-3     # the null test: well under one step of the pattern, far above the 24-bit noise
EDGE = 0.003   # what is left out either side of a seam between two pieces
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
    return abs(a - b) < eps


def write_ramp(path, rising=True):
    """24-bit stereo, the sample value being the position in the file."""
    n = int(FILE_SECONDS * SR)
    x = np.linspace(-0.8, 0.8, n) if rising else np.linspace(0.6, -0.6, n)
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
RAMP2 = os.path.join(WORK, "ramp2.wav")
write_ramp(RAMP)
write_ramp(RAMP2, rising=False)


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

    def looped_group(S, a, P, duration, second_child=False):
        clip = cmd("object.add", path=RAMP, lane=0, start=S)["id"]
        ids = [clip]
        if second_child:
            ids.append(cmd("object.add", path=RAMP2, lane=1, start=S + 0.25)["id"])
        g = cmd("group.create", ids=ids)["id"]
        cmd("object.set_duration", id=g, duration=duration)
        cmd("object.set_loop", id=g, enabled=True)
        cmd("object.set_loop_range", id=g, start=a, end=a + P)
        got = cmd("object.get", id=g)
        assert near(got["duration"], duration) and near(got["start"], S), got
        return g

    def slip(after, before, P):
        """How late the pattern comes after the cut, in seconds (0 ≤ δ < P), read off the ramp."""
        step = float(np.median(np.diff(before)))   # the ramp's slope, whatever the gain on the way
        return float(np.median((before - after) / (step * SR) % P))

    def same(label, after, before, P=None, seams=()):
        """`after` and `before` must null, sample for sample, apart from the seams (in samples)."""
        n = min(len(after), len(before))
        e = int(EDGE * SR)
        keep = np.ones(n, dtype=bool)
        for s in (0, n, *seams):
            keep[max(0, s - e):min(n, s + e)] = False
        d = np.abs(after[:n] - before[:n])[keep]
        peak = float(d.max()) if len(d) else 0.0
        loud = float(np.abs(before[:n][keep]).max()) if len(d) else 0.0
        note = "residual %.5f" % peak
        if P is not None and peak >= EPS:
            tail = seams[-1] if seams else 0
            note += ", measured delay %.4f s" % slip(after[tail + e:n - e], before[tail + e:n - e], P)
        check(label + " (%s)" % note, len(after) == len(before) and peak < EPS and loud > 0.1,
              "%d vs %d samples, loudest %.3f" % (len(after), len(before), loud))

    def cut_case(name, S, a, P, cut, duration=16.0, second_child=False, **options):
        clear()
        g = looped_group(S, a, P, duration, second_child)
        end = S + duration
        before = mix(S, end)
        answer = cmd("object.split_at", ids=[g], seconds=cut, **options)
        check(name + ": pieces", len(answer["ids"]) == (1 if "keep" in options else 2), str(answer))
        same(name, mix(S if "keep" not in options else cut, end),
             before if "keep" not in options else before[int(round((cut - S) * SR)):],
             P, seams=() if "keep" in options else (int(round((cut - S) * SR)),))
        return g, before, answer["ids"]

    # A — IN inside the first period, the cut after it.
    cut_case("A1 S=2 a=1 P=2 c=7.3", 2.0, 1.0, 2.0, 7.3)
    cut_case("A2 S=2 a=0.6 P=0.75 c=7.3", 2.0, 0.6, 0.75, 7.3)
    cut_case("A3 S=3.5 a=2.25 P=1.3 c=11.1", 3.5, 2.25, 1.3, 11.1)
    cut_case("A4 S=2 a=1 P=2 c=8 (on the grid)", 2.0, 1.0, 2.0, 8.0)
    cut_case("A5 S=2 a=1 P=3 c=7.3", 2.0, 1.0, 3.0, 7.3)
    # B — the cut before IN.
    cut_case("B1 S=2 a=1.5 P=2 c=2.6", 2.0, 1.5, 2.0, 2.6)
    # C — IN further than a whole period from the left edge.
    cut_case("C1 S=2 a=2.5 P=2 c=7.3", 2.0, 2.5, 2.0, 7.3)
    cut_case("C2 S=2 a=4 P=2 c=7.3 (a multiple of P)", 2.0, 4.0, 2.0, 7.3)
    # D — the material before IN goes below zero, which the bridge has to translate.
    cut_case("D1 S=0 a=1 P=2 c=0.5", 0.0, 1.0, 2.0, 0.5)
    cut_case("D2 S=0 a=1 P=2 c=5.3", 0.0, 1.0, 2.0, 5.3)
    # E — the control, which never slid, and a right half cut again.
    cut_case("E1 S=2 a=0 P=2 c=7.3", 2.0, 0.0, 2.0, 7.3)
    _, before, ids = cut_case("E2 S=2 a=1 P=2 c=7.3", 2.0, 1.0, 2.0, 7.3)
    right = max(ids, key=lambda i: cmd("object.get", id=i)["start"])
    cmd("object.split_at", ids=[right], seconds=12.1)
    same("E2 the right half cut again", mix(2.0, 18.0), before, 2.0,
         seams=(int(round(5.3 * SR)), int(round(10.1 * SR))))
    # F — several children.
    cut_case("F1 two children S=2 a=1 P=2 c=7.3", 2.0, 1.0, 2.0, 7.3, second_child=True)

    # G — a looping sub-group inside a plain group: `splitSubtree`'s own path.
    clear()
    inner = looped_group(2.0, 1.0, 2.0, 12.0)
    other = cmd("object.add", path=RAMP2, lane=3, start=2.0)["id"]
    outer = cmd("group.create", ids=[inner, other])["id"]
    before = mix(2.0, 14.0)
    cmd("object.split_at", ids=[outer], seconds=7.3)
    same("G1 a sub-group cut through its parent", mix(2.0, 14.0), before, seams=(int(round(5.3 * SR)),))

    # H — the other doors of the cut, then the undo.
    g, before, _ = cut_case("H1 window_only", 2.0, 1.0, 2.0, 7.3, window_only=True)
    cmd("edit.undo")
    same("H2 the undo gives the group back", mix(2.0, 18.0), before)
    cut_case("H3 keep=right", 2.0, 1.0, 2.0, 7.3, keep="right")

    # I — a hole traced in the middle: the piece after it is a right half.
    clear()
    looped_group(2.0, 1.0, 2.0, 16.0)
    before = mix(2.0, 18.0)
    cmd("timesel.set", start=7.3, end=9.1, lanes=[0])
    cmd("timesel.delete")
    k = int(round(7.1 * SR))
    same("I1 what follows a hole", mix(9.1, 18.0), before[k:], 2.0)

    # J — a fragment copied by a time selection and pasted far away: the same stretch of pattern.
    clear()
    looped_group(2.0, 1.0, 2.0, 16.0)
    before = mix(2.0, 18.0)
    cmd("timesel.set", start=7.3, end=9.1, lanes=[0])
    cmd("timesel.copy")
    cmd("timesel.clear")
    cmd("transport.seek", seconds=30.0)
    cmd("clipboard.paste")
    same("J1 a pasted fragment", mix(30.0, 31.8), before[int(round(5.3 * SR)):int(round(7.1 * SR))], 2.0)

    # L — the head of the group taken away by a time selection: what stays is a right half too.
    clear()
    looped_group(2.0, 1.0, 2.0, 16.0)
    before = mix(2.0, 18.0)
    cmd("timesel.set", start=1.0, end=7.3, lanes=[0])
    cmd("timesel.delete")
    same("L1 the head deleted", mix(7.3, 18.0), before[int(round(5.3 * SR)):], 2.0)

    # K — a right half whose copies live below zero, read back from disk.
    _, before, _ = cut_case("K1 S=0 a=1 P=2 c=5.3", 0.0, 1.0, 2.0, 5.3)
    path = os.path.join(WORK, "reopened.objekat")
    cmd("project.save_as", path=path)
    cmd("project.open", path=path)
    same("K2 reopened from disk", mix(0.0, 16.0), before, 2.0, seams=(int(round(5.3 * SR)),))

    clear()

print("\n%d assertions, %d failed" % (count, len(fails)))
print("ALL PASS" if not fails else "FAILED:\n  " + "\n  ".join(fails))
sys.exit(1 if fails else 0)

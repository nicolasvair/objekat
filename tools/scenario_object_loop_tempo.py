#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""What a TEMPO change does to an object's LOOP bounds (`object.get`: loop_start / loop_end).

    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --socket=/tmp/o.sock
    ./scenario_object_loop_tempo.py /tmp/o.sock

@see EditViewModel.resyncPositionsFromTracktion / rescaleMidiClipDurations: the bounds name a place in
MUSICAL content, so a looping GROUP (grid mode BPM) and a MIDI CLIP (both modes) have them multiplied by
the same ratio as their duration; without it the period handed to the engine stayed the old one on a
stretched content. A looping AUDIO clip reads seconds of the file: its bounds never move.

  G1  group looping, mode BPM, 120 -> 100: start / duration / bounds x1.2, the child stays aligned on
      the group, the same number of cycles
  G2  back to 120: the exact state; and an undo of the tempo change gives it back too
  G3  mode TIME: tempo 100 moves nothing of a group
  M1  MIDI clip looping, mode BPM: duration AND bounds x1.2 (the same number of cycles)
  M2  MIDI clip looping, mode TIME: the clip follows the tempo (duration, bounds), its start stays
  A1  audio clip looping, mode BPM: only the START moves (bounds, offset kept)
  A2  audio clip looping, mode TIME: nothing moves

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
WORK = tempfile.mkdtemp(prefix="objekat_looptempo_")
import atexit, shutil
atexit.register(shutil.rmtree, WORK, True)   # the renders are large: leave no trace
SR = 48000
R = 1.2          # 120 -> 100 BPM
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


def near(a, b, eps=1e-4):
    return a is not None and abs(a - b) < eps


def write_ramp(path, seconds=1.0):
    x = np.linspace(-0.8, 0.8, int(seconds * SR))
    i = np.round(x * (2 ** 23 - 1)).astype(np.int32)
    b = np.stack([i & 255, (i >> 8) & 255, (i >> 16) & 255], axis=1).astype(np.uint8)
    data = np.repeat(b, 2, axis=0).tobytes()
    with open(path, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVE")
        f.write(b"fmt " + struct.pack("<IHHIIHH", 16, 1, 2, SR, SR * 6, 6, 24))
        f.write(b"data" + struct.pack("<I", len(data)) + data)


RAMP = os.path.join(WORK, "ramp.wav")
write_ramp(RAMP)

with ObjekatClient(SOCK) as c:
    def cmd(name, **params):
        return c.send(name, params or None)

    def snap(i):
        o = cmd("object.get", id=i)
        return {k: o.get(k) for k in ("start", "duration", "loop", "loop_start", "loop_end", "source_offset")}

    def child_start():
        # the first child of the first root item, as the model stores it
        it = [i for i in cmd("project.get_state")["items"]][0]
        return it["kind"]["children"][0]["startTime"]

    def cycles(s):
        return s["duration"] / (s["loop_end"] - s["loop_start"])

    def fresh(mode, bpm=120):
        cmd("project.new")
        cmd("project.set_grid_mode", mode="time")
        cmd("project.set_tempo", bpm=bpm)
        cmd("project.set_grid_mode", mode=mode)

    # ------------------------------------------------------------------ G1 / G2: a looping group, BPM
    fresh("bpm")
    a = cmd("object.add", path=RAMP, lane=0, start=2.0)["id"]
    g = cmd("group.create", ids=[a])["id"]
    cmd("object.set_duration", id=g, duration=4.0)
    cmd("object.set_loop", id=g, enabled=True)
    cmd("object.set_loop_range", id=g, start=0, end=1)
    g0, a0 = snap(g), child_start()
    check("G fixture: looping group 2 s, 4 s long, bounds 0 / 1, 4 cycles",
          near(g0["start"], 2.0) and near(g0["duration"], 4.0) and near(g0["loop_end"] - g0["loop_start"], 1.0)
          and g0["loop"] is True and near(cycles(g0), 4.0), str(g0))
    r = cmd("project.set_tempo", bpm=100)
    check("G1 tempo 100 accepted", near(r["tempo"], 100), str(r))
    g1, a1 = snap(g), child_start()
    check("G1 start x1.2", near(g1["start"], 2.0 * R), str(g1))
    check("G1 duration x1.2", near(g1["duration"], 4.0 * R), str(g1))
    check("G1 bounds x1.2 (period 1.2)", near(g1["loop_end"] - g1["loop_start"], 1.0 * R), str(g1))
    check("G1 same number of cycles (4)", near(cycles(g1), 4.0, 1e-3), str(cycles(g1)))
    check("G1 the child follows (stored start x1.2, still laid on the pattern)",
          near(a1, a0 * R), "%s vs %s" % (a1, a0))
    cmd("project.set_tempo", bpm=120)
    g2 = snap(g)
    check("G2 back to 120: the exact state",
          all(near(g2[k], g0[k]) for k in ("start", "duration", "loop_start", "loop_end")), "%s vs %s" % (g2, g0))
    cmd("project.set_tempo", bpm=100)
    cmd("edit.undo")
    g3 = snap(g)
    check("G2 undo of the tempo change: bounds, start and duration back",
          all(near(g3[k], g0[k]) for k in ("start", "duration", "loop_start", "loop_end")), "%s vs %s" % (g3, g0))

    # ------------------------------------------------------------------ G3: a looping group, TIME
    fresh("time")
    a = cmd("object.add", path=RAMP, lane=0, start=2.0)["id"]
    g = cmd("group.create", ids=[a])["id"]
    cmd("object.set_duration", id=g, duration=4.0)
    cmd("object.set_loop", id=g, enabled=True)
    cmd("object.set_loop_range", id=g, start=0, end=1)
    g0 = snap(g)
    cmd("project.set_tempo", bpm=100)
    g1 = snap(g)
    check("G3 mode Time: nothing of the group moves",
          all(near(g1[k], g0[k]) for k in ("start", "duration", "loop_start", "loop_end")), "%s vs %s" % (g1, g0))

    # ------------------------------------------------------------------ M1: a looping MIDI clip, BPM
    for mode in ("bpm", "time"):
        fresh(mode)
        spb = 0.5            # 120 BPM
        m = cmd("midi.create_clip", start=2.0, end=2.0 + 4 * spb * 2, lane=0)["id"]   # 4 s
        cmd("midi.add_note", id=m, pitch=60, start_beat=0, length_beats=1)
        cmd("object.set_loop", id=m, enabled=True)
        cmd("object.set_loop_range", id=m, start=0, end=2 * spb * 2)    # 2 s period (4 beats)
        m0 = snap(m)
        check("M fixture (%s): looping, 4 s, period 2 s" % mode,
              m0["loop"] is True and near(m0["duration"], 4.0) and near(m0["loop_end"] - m0["loop_start"], 2.0), str(m0))
        cmd("project.set_tempo", bpm=100)
        m1 = snap(m)
        check("M (%s) duration x1.2 (musical content follows)" % mode, near(m1["duration"], 4.0 * R), str(m1))
        check("M (%s) bounds x1.2" % mode, near(m1["loop_end"] - m1["loop_start"], 2.0 * R), str(m1))
        check("M (%s) same number of cycles" % mode, near(cycles(m1), cycles(m0), 1e-3), "%s %s" % (cycles(m1), cycles(m0)))
        check("M (%s) start %s" % (mode, "x1.2" if mode == "bpm" else "kept"),
              near(m1["start"], 2.0 * R if mode == "bpm" else 2.0), str(m1))
        cmd("edit.undo")
        m2 = snap(m)
        check("M (%s) undo: the exact state" % mode,
              all(near(m2[k], m0[k]) for k in ("start", "duration", "loop_start", "loop_end")), "%s vs %s" % (m2, m0))

    # ------------------------------------------------------------------ A1 / A2: a looping AUDIO clip
    for mode in ("bpm", "time"):
        fresh(mode)
        a = cmd("object.add", path=RAMP, lane=0, start=2.0)["id"]
        cmd("object.set_loop", id=a, enabled=True)
        cmd("object.set_duration", id=a, duration=4.0)
        a0 = snap(a)
        cmd("project.set_tempo", bpm=100)
        a1 = snap(a)
        check("A (%s) the loop bounds never move" % mode,
              near(a1["loop_start"], a0["loop_start"]) and near(a1["loop_end"], a0["loop_end"]), "%s vs %s" % (a1, a0))
        check("A (%s) offset and duration kept" % mode,
              near(a1["source_offset"], a0["source_offset"]) and near(a1["duration"], a0["duration"]), "%s vs %s" % (a1, a0))
        check("A (%s) start %s" % (mode, "x1.2" if mode == "bpm" else "kept"),
              near(a1["start"], 2.0 * R if mode == "bpm" else 2.0), str(a1))

print("\n%d assertions, %d failed" % (count, len(fails)))
print("ALL PASS" if not fails else "FAILED:\n  " + "\n  ".join(fails))
sys.exit(1 if fails else 0)

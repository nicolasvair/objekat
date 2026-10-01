#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""A PARITY project — built through the API, to be OPENED ON SCREEN and compared by eye.

    # 1. any instance will do for BUILDING (the model is all that is needed): a headless one is
    #    simplest, and never opens a window
    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --socket=/tmp/cc501/par.sock

    # 2. build and save (default folder /tmp/cc501/parity, outside the repository)
    ./scenario_parity_project.py /tmp/cc501/par.sock [--out /tmp/cc501/parity]

Why it exists. A clip SELECTED used to be drawn by a rich SwiftUI view (`SoundBlockView`) and an
unselected one by the timeline's batched Canvas; the Canvas now draws both. Nobody can check by
machine that the two LOOK the same — the visual belongs to the user — so this lays down every
case that could differ, in one project, in two columns:

    left column (t = 0)   the reference: leave these UNSELECTED
    right column (t = 30) the same clips: SELECT these (marquee them, or ⌘-click)

and the A/B switch (a DEBUG build only) flips every SELECTED clip between the new path (the Canvas)
and the old one (the rich view): @see `Shared/DebugRenderSwitches.swift`.

Rows, top to bottom (the lane numbers are printed by the run):

    plain · muted · straight fades · bent fades (convex in / S out) · reverse · speed ×0.5 ·
    speed ×1.5 + 6 dB + pan L30 (the META summary) · loop (IN/OUT inside the file) · stereo ·
    stereo, mono-sum channel mode · MISSING file on the default stem · MISSING file on the RED
    stem · a stem MUTED (the clip itself is not) · a clip 15 / 40 / 100 px wide at 100 pps (the
    label's thresholds: name from 10 px, mute badge from 30, meta from 60), muted and with a gain ·
    ten stem colours (one lane of clips, and a copy of it below to select) · a CROSSFADE pair
    (and a copy below: select only the left one, only the right one, both).

What it cannot make: the salmon / pink NAME BAND is an object's own colour, which keeps a clip on
its rich view whatever its selection (`colorIndex != nil` is excluded from the Canvas) and has no
API door — set one by hand (right click) if you want to see the red on salmon.

It leaves the project saved and the file of the MISSING rows deleted from disk, which is how a
file goes missing in real life. Exit 0 when the project was built.
"""

import argparse, array, math, os, random, shutil, sys, wave

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

RATE = 48000
LEFT, RIGHT = 0.0, 30.0       # the two columns' start, in seconds
FILE_S = 8.0                  # the length of the audio files below


def write_wav(path, channels, seconds=FILE_S, seed=1):
    """A noise file whose level moves (a slow envelope, a quicker one on the right channel of a
    stereo file) so the waveform is neither flat nor symmetric, a fade or a reverse is readable,
    and the two lanes of a stereo file differ."""
    rnd = random.Random(seed)
    n = int(seconds * RATE)
    frames = array.array("h")
    for i in range(n):
        t = i / RATE
        env_l = 0.25 + 0.7 * abs(math.sin(2 * math.pi * t / 3.1)) * (1 - 0.5 * t / seconds)
        env_r = 0.2 + 0.75 * abs(math.sin(2 * math.pi * t / 1.3 + 1))
        frames.append(int(rnd.uniform(-1, 1) * env_l * 26000))
        if channels == 2:
            frames.append(int(rnd.uniform(-1, 1) * env_r * 26000))
    with wave.open(path, "wb") as w:
        w.setnchannels(channels)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(frames.tobytes())
    return path


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("socket")
    ap.add_argument("--out", default="/tmp/cc501/parity")
    args = ap.parse_args()

    out = os.path.abspath(args.out)
    if os.path.isdir(out):
        shutil.rmtree(out)
    media = os.path.join(out, "media")
    os.makedirs(media)
    mono = write_wav(os.path.join(media, "mono.wav"), 1, seed=1)
    stereo = write_wav(os.path.join(media, "stereo.wav"), 2, seed=2)
    gone = write_wav(os.path.join(media, "missing_take.wav"), 1, seed=3)

    c = ObjekatClient(args.socket)
    c.connect()
    if c.send("app.info")["object_count"] > 0:
        c.send("project.new")
    cmd = c.send

    # ---- the stems: the ten colours of the palette, the red one (index 6) among them
    stems = {0: cmd("stem.list")["main"]}
    for i in range(1, 10):
        stems[i] = cmd("stem.add", {"name": "Stem %d" % i, "color_index": i})["id"]
    muted_stem = cmd("stem.add", {"name": "Muted stem", "color_index": 2})["id"]
    cmd("stem.mute", {"id": muted_stem, "muted": True})

    lane = [0]
    rows = []

    def add(path, start, dur=None, stem=None):
        p = {"path": path, "lane": lane[0], "start": start}
        if dur is not None:
            p["duration"] = dur
        oid = cmd("object.add", p)["id"]
        if stem is not None:
            cmd("stem.assign", {"stem": stem, "ids": [oid]})
        return oid

    def both(name, build):
        """One row, the same clip in both columns."""
        for start in (LEFT, RIGHT):
            build(start)
        rows.append((lane[0], name))
        lane[0] += 1

    def b_plain(start): add(mono, start)
    both("plain", b_plain)

    def b_muted(start):
        o = add(mono, start)
        cmd("object.set_mute", {"ids": [o], "muted": True})
    both("muted (the clip's own mute)", b_muted)

    def b_fades(start):
        o = add(mono, start)
        cmd("object.set_fade", {"id": o, "in": 1.5, "out": 2.0})
    both("straight fades in 1.5 s / out 2 s", b_fades)

    def b_curves(start):
        o = add(mono, start)
        cmd("object.set_fade", {"id": o, "in": 2.0, "out": 2.5})
        cmd("object.set_fade_curve", {"id": o, "in": "convex", "out": "sCurve", "in_bend": 0.8, "out_bend": 1.0})
    both("bent fades (convex in, S out)", b_curves)

    def b_reverse(start):
        o = add(mono, start)
        cmd("object.set_fade", {"id": o, "in": 1.0})
        cmd("object.set_reversed", {"id": o, "reversed": True})
    both("reversed, fade-in 1 s", b_reverse)

    def b_slow(start):
        o = add(mono, start)
        cmd("object.set_speed", {"id": o, "ratio": 0.5})
    both("speed x0.50 (the meta says it)", b_slow)

    def b_meta(start):
        o = add(mono, start)
        cmd("object.set_speed", {"id": o, "ratio": 1.5})
        cmd("object.set_gain", {"ids": [o], "db": 6})
        cmd("object.set_pan", {"ids": [o], "pan": -0.3})
    both("speed x1.50 + 6 dB + pan L30 (meta)", b_meta)

    def b_loop(start):
        o = add(mono, start, dur=3.0)
        cmd("object.set_loop", {"id": o, "enabled": True})
        cmd("object.set_loop_range", {"id": o, "start": 0.5, "end": 2.0})
        cmd("object.set_duration", {"id": o, "duration": 7.0})
    both("loop: IN 0.5 / OUT 2.0, stretched to 7 s (grips when selected)", b_loop)

    def b_stereo(start): add(stereo, start)
    both("stereo file (two lanes + separator)", b_stereo)

    def b_stereo_c(start):
        o = add(stereo, start)
        cmd("object.set_channel_mode", {"id": o, "mode": "c"})
    both("stereo, channel mode mono-sum", b_stereo_c)

    def b_missing(start): add(gone, start)
    both("MISSING file, default (blue) stem", b_missing)

    def b_missing_red(start): add(gone, start, stem=stems[6])
    both("MISSING file, RED stem (red on a red band: the halo)", b_missing_red)

    def b_stem_muted(start): add(mono, start, stem=muted_stem)
    both("the STEM is muted, the clip is not (grey waveform + veil, no M badge)", b_stem_muted)

    def b_narrow(start):
        x = start
        for width_s in (0.15, 0.40, 1.00):
            o = add(mono, x, dur=width_s)
            cmd("object.set_mute", {"ids": [o], "muted": True})
            cmd("object.set_gain", {"ids": [o], "db": -6})
            x += width_s + 0.5
    both("narrow clips 0.15 / 0.40 / 1.00 s, muted, -6 dB (100 pps: 15 / 40 / 100 px)", b_narrow)

    # ---- the ten stem colours: one lane to leave alone, one below it to select
    for label in ("stem colours (reference)", "stem colours (SELECT this lane)"):
        for i in range(10):
            add(mono, i * 6.0, dur=5.0, stem=stems[i])
        rows.append((lane[0], label))
        lane[0] += 1

    # ---- the crossfade: a pair, and a copy of it to select by halves
    for label in ("crossfade pair (reference)", "crossfade pair (select the left, the right, both)"):
        a = add(mono, 0.0, dur=6.0)
        b = add(mono, 6.0, dur=6.0)
        cmd("object.set_fade", {"id": b, "out": 1.0})
        cmd("crossfade.open", {"left": a, "right": b, "width": 2.0})
        rows.append((lane[0], label))
        lane[0] += 1

    cmd("selection.clear")
    manifest = os.path.join(out, "parity.objekat")
    cmd("project.save_as", {"path": manifest})
    # Only now, so that the project holds the path and the disk does not: a MISSING file.
    os.remove(gone)
    scan = cmd("project.rescan_missing")
    wf = cmd("perf.waveforms")

    print("Parity project written: %s" % manifest)
    print("  %d lanes, %d paths missing (the two MISSING rows), media in %s" % (lane[0], scan["path_count"], media))
    print("\nLanes (display row, top = 0):")
    for row, name in rows:
        print("  %2d  %s" % (row, name))
    print("""
OPEN IT in a Debug build (the A/B switch exists in Debug only), in the app: File > Open, then
%s
(or, on an instance started with --api --socket=/tmp/cc501/ui.sock:
   tools/objekat_cli.py --socket /tmp/cc501/ui.sock project.open --path %s )

ZOOM LEVELS to look at (the left/right columns are at 0 s and 30 s: scroll_x = t * pps):
   5 pps   whole project: the blocks are slivers, only the fills and borders speak
  20 pps   a clip is ~160 px: label, fades and loop marks are drawn, the waveform is a sliver
 100 pps   a clip is ~800 px: everything, the meta and the badge included
 samples   %.0f pps and above: sample mode (a clip is drawn on its own, individually)
 on a running instance:  objekat_cli.py --socket SOCK view.set --pps 100 --scroll_x 0

THE A/B: select the right column, then flip the switch and compare pixel against pixel:
   objekat_cli.py --socket SOCK debug.force_rich_blocks --enabled true    # old: rich views
   objekat_cli.py --socket SOCK debug.force_rich_blocks --enabled false   # new: Canvas
 or persistently, then relaunch:
   defaults write org.labelpeche.objekat objekat.debug.forceRichBlocks -bool YES
   defaults delete org.labelpeche.objekat objekat.debug.forceRichBlocks
 And compare the right column (selected) with the left one (unselected) for what must NOT jump on
 selection: the border should only get brighter, not move.

WHAT TO LOOK AT, selected clips, Canvas vs rich:
   - the border: bright (0.9) and 1.5 pt, and no 0.75 px jump when selecting (the Canvas keeps
     its centred stroke, the rich view had an inset one: a hair thinner inside the block)
   - the icon: 11 pt in the Canvas against 13 pt bold in the rich view (kept on purpose)
   - the red of the MISSING rows, on the default band and on the red-stem band (white halo)
   - light and dark appearance
   - the crossfade, with the left, the right, then both selected: waveforms of both clips
     visible through the shared zone, the selected one drawn above its neighbour
   - the META (volume / pan / speed) and the M badge, now drawn for every clip
   - the loop's grips (a bar and a flag at each bound) on the selected looped clip
   - the stem-muted row: waveform grey in the Canvas, stem-coloured under the veil in the rich view
   - the stem colours, fades (straight and bent), reverse, speed, stereo separator""" % (
        manifest, manifest, wf.get("sample_mode_threshold", 0)))
    return 0


if __name__ == "__main__":
    sys.exit(main())

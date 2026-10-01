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

Then, below those rows, a section of OPEN GROUPS (the second A/B: the tinted bands under an open
group, the rise under its block and the '+' of its drop lane, which the Canvas draws now — the same
switch brings back the old SwiftUI layers). One group per root lane, each its own row, none shares a
lane with another (a band spans the whole timeline, two groups on one lane would stack their
tints and read as a nesting that is not there):

    open group, 2 child lanes (the reference) · the same, odd/even parity flipped by the
    group above (a group with ONE child lane has a span of 2 rows, so the next group lands on the
    other parity) · open group on the RED stem · MUTED open group · open group to SELECT as a
    whole · open group to SELECT A CHILD of (its band goes stronger: "you are in this group") ·
    NESTED, three levels all open (outer > mid > inner, a clip at each level) · nested, two levels,
    the inner one on the red stem (two hues stacking) · a very NARROW open group (0.5 s) · an
    INFINITE open group (a full-width band, last because it adds a row of its own).

Last, a section of GROUPS' BLOCKS (the third A/B: the block of a group, which the Canvas draws now —
radius 20, tint, inset border, composite, fades, mute veil, glyph, name, meta, chevron). All CLOSED
(the chevron then points right; the open ones above point down), one per root lane:

    closed group (the reference) · closed group to SELECT (tint 0.55, border 0.9) · MUTED closed
    group (veil, grey composite) · closed group on the RED stem · straight fades + 6 dB + pan L30
    (the fade veils, the label pushed past the fade, the META) · bent fades · a child whose file is
    MISSING (the group's name goes red, on the default band) · the same on the RED stem (the halo)
    · four NARROW groups 0.20 / 0.45 / 0.70 / 1.00 s (20 / 45 / 70 / 100 px at 100 pps: the label
    from 30 px, the chevron from 60, the meta from 80) · a LONG group (40 s: scroll it at 100 pps
    and zoom to ~2000 pps, the block is millions of px wide).

E5 rows (own colour, MIDI, looping MIDI, aux, looping group): the blocks the batched Canvas now
draws that used to stay on their rich view for a static reason. A consolidated object is not made
here (an asynchronous bake): do it by hand.

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

    # ---- E5: the blocks that used to stay on their rich view for a STATIC reason. Each row has
    # its reference column and the one to select (the same `both` rule): look at them with the
    # A/B switch in each state, selected and not, light and dark.
    def b_colour(start):
        o = add(mono, start, dur=6.0)
        cmd("object.set_color", {"ids": [o], "color_index": 3})
    both("OWN COLOUR (salmon name band over the stem body, border in the own colour)", b_colour)

    def b_colour_muted(start):
        o = add(mono, start, dur=6.0, stem=stems[6])
        cmd("object.set_color", {"ids": [o], "color_index": 8})
        cmd("object.set_mute", {"ids": [o], "muted": True})
    both("own colour on the RED stem, muted (the red name on the band, the veil)", b_colour_muted)

    def b_midi(start):
        r = cmd("midi.create_clip", {"start": start, "end": start + 6.0, "lane": lane[0]})
        for k, (pitch, sb) in enumerate(((60, 0.0), (64, 1.0), (67, 2.0), (72, 3.5), (55, 5.0))):
            cmd("midi.add_note", {"id": r["id"], "pitch": pitch, "start_beat": sb,
                                  "length_beats": 0.8, "velocity": 40 + 20 * k})
    both("MIDI clip (the notes: range, margins, velocity opacity)", b_midi)

    def b_midi_loop(start):
        r = cmd("midi.create_clip", {"start": start, "end": start + 9.0, "lane": lane[0]})
        for pitch, sb in ((60, 0.0), (64, 0.5), (67, 1.0)):
            cmd("midi.add_note", {"id": r["id"], "pitch": pitch, "start_beat": sb,
                                  "length_beats": 0.4, "velocity": 100})
        cmd("object.set_loop", {"id": r["id"], "enabled": True})
    both("LOOPING MIDI clip (the pattern repeats from the left edge, the grips are always shown)", b_midi_loop)

    def b_aux(start):
        cmd("aux.create", {"start": start, "end": start + 6.0, "lane": lane[0]})
    both("AUX (glyph chequerboard, radius 20)", b_aux)

    def b_aux_colour(start):
        r = cmd("aux.create", {"start": start, "end": start + 6.0, "lane": lane[0]})
        cmd("object.set_color", {"ids": [r["id"]], "color_index": 5})
    both("aux with its own colour", b_aux_colour)

    def b_loop_group(start):
        o = add(mono, start, dur=3.0)
        g = cmd("group.create", {"ids": [o]})["id"]
        cmd("group.expand", {"id": g, "expanded": False})
        cmd("object.set_loop", {"id": g, "enabled": True})
    both("LOOPING group, closed (the composite repeats, the IN / OUT grips)", b_loop_group)

    # ---- OPEN GROUPS: one per root lane (a band spans the whole timeline). Built after every
    # row above so that their lane numbers do not move. `object.add`'s lane is a DISPLAY row: a
    # clip added on a row an open group holds would join that group (the drop rule), so every group
    # is made CLOSED, on rows that are free, and they are all OPENED together at the end.
    group_rows = []
    to_open = []

    def put(path, lane_, start, dur, stem=None):
        oid = cmd("object.add", {"path": path, "lane": lane_, "start": start, "duration": dur})["id"]
        if stem is not None:
            cmd("stem.assign", {"stem": stem, "ids": [oid]})
        return oid

    def close_and_remember(gid, stem=None, muted=False, keep_closed=False):
        cmd("group.expand", {"id": gid, "expanded": False})
        if stem is not None:
            cmd("stem.assign", {"stem": stem, "ids": [gid]})
        if muted:
            cmd("object.set_mute", {"ids": [gid], "muted": True})
        if not keep_closed:
            to_open.append(gid)
        return gid

    def make_group(root, parts, stem=None, muted=False, remember=True):
        """parts = [(child lane, start, duration)]. A CLOSED group, opened at the end."""
        ids = [put(mono, root + dl, st, du) for dl, st, du in parts]
        gid = cmd("group.create", {"ids": ids})["id"]
        return close_and_remember(gid, stem, muted, keep_closed=not remember)

    def nest(first_lane, inner, levels):
        """Wraps the group `inner` (at root lane `first_lane`) in `levels` NEW groups, one inside
        the next. A wrapper is made from ONE clip (`group.create` on a group plus a clip names the
        wrong new group in its answer, the inner one being rebuilt) and the inner group is then
        moved into it (`group.reparent`). Wrapper k lives on root lane `first_lane + k`. Returns
        the outermost group's id."""
        cur = inner
        for k in range(1, levels + 1):
            clip = put(mono, first_lane + k, 0.2, 8.0)
            wrapper = cmd("group.create", {"ids": [clip]})["id"]
            cmd("group.expand", {"id": wrapper, "expanded": False})
            cmd("group.reparent", {"ids": [cur], "group": wrapper, "child_lane": 1})
            to_open.append(wrapper)
            cur = wrapper
        return cur

    two = [(0, 0.0, 4.0), (0, 5.0, 3.0), (1, 2.0, 5.0)]     # 2 child lanes -> span 3 (+ drop lane)
    root = lane[0]

    def next_row(name):
        nonlocal root
        group_rows.append((root, name))
        root += 1

    make_group(root, two);                                   next_row("open group, 2 child lanes (reference, leave it)")
    make_group(root, [(0, 0.0, 4.0), (0, 5.0, 3.0)]);        next_row("open group, 1 child lane (its span is odd: the next row flips the lane parity)")
    make_group(root, two, stem=stems[6]);                    next_row("open group on the RED stem (another tint)")
    make_group(root, two, muted=True);                       next_row("MUTED open group (the band does not change; the block does)")
    make_group(root, two);                                   next_row("open group to SELECT as a whole (click its header)")
    make_group(root, two);                                   next_row("open group to SELECT A CHILD of (its band goes stronger)")

    # nested, three levels: inner (2 lanes) < mid < outer, a clip beside the inner one at each level
    inner = make_group(root, [(0, 0.5, 3.0), (1, 2.0, 3.0)])
    nest(root, inner, 2)
    root += 2
    next_row("NESTED, 3 levels all open (outer > mid > inner): the tints stack, deeper = stronger")

    # nested, two levels, the inner one on another colour
    inner = make_group(root, [(0, 0.5, 3.0), (1, 2.0, 3.0)], stem=stems[6])
    nest(root, inner, 1)
    root += 1
    next_row("NESTED, 2 levels, the inner one on the RED stem (two hues stack)")

    make_group(root, [(0, 0.0, 0.5), (1, 0.0, 0.5)]);        next_row("NARROW open group, 0.5 s (50 px at 100 pps: the rise and the '+' on a short block)")
    inf = make_group(root, two)
    cmd("object.set_infinite", {"id": inf, "on": True})      # while closed: it takes the row below
    next_row("INFINITE open group (full-width band; it took a row of its own just below)")

    # ---- GROUPS' BLOCKS: closed groups, one per root lane (they stay closed)
    def closed(parts, **kw):
        return make_group(root, parts, remember=False, **kw)

    root += 1   # the row the INFINITE group above took for itself
    one = [(0, 0.0, 4.0), (0, 5.0, 3.0), (1, 2.0, 5.0)]
    closed(one);                                             next_row("CLOSED group (reference, leave it; the chevron points right)")
    closed(one);                                             next_row("CLOSED group to SELECT (tint 0.55, border 0.9)")
    closed(one, muted=True);                                 next_row("MUTED closed group (black veil, grey composite)")
    closed(one, stem=stems[6]);                              next_row("CLOSED group on the RED stem")
    g = closed(one)
    cmd("object.set_fade", {"id": g, "in": 1.5, "out": 2.0})
    cmd("object.set_gain", {"ids": [g], "db": 6})
    cmd("object.set_pan", {"ids": [g], "pan": -0.3})
    next_row("CLOSED group, fades in 1.5 s / out 2 s, +6 dB, pan L30 (veils, label past the fade, meta)")
    g = closed(one)
    cmd("object.set_fade", {"id": g, "in": 2.0, "out": 2.5})
    cmd("object.set_fade_curve", {"id": g, "in": "convex", "out": "sCurve", "in_bend": 0.8, "out_bend": 1.0})
    next_row("CLOSED group, bent fades (convex in, S out)")
    ids = [put(gone, root, 0.0, 4.0), put(mono, root, 5.0, 3.0)]
    close_and_remember(cmd("group.create", {"ids": ids})["id"], keep_closed=True)
    next_row("CLOSED group holding a MISSING file (name red + bold, white halo)")
    ids = [put(gone, root, 0.0, 4.0), put(mono, root, 5.0, 3.0)]
    close_and_remember(cmd("group.create", {"ids": ids})["id"], stem=stems[6], keep_closed=True)
    next_row("the same on the RED stem (red on red: the halo)")
    x = 0.0
    for width_s in (0.20, 0.45, 0.70, 1.00):
        c1 = put(mono, root, x, width_s)
        gid = close_and_remember(cmd("group.create", {"ids": [c1]})["id"], keep_closed=True)
        cmd("object.set_gain", {"ids": [gid], "db": -6})
        x += width_s + 0.5
    next_row("NARROW closed groups 0.20 / 0.45 / 0.70 / 1.00 s, -6 dB (100 pps: 20 / 45 / 70 / 100 px)")
    closed([(0, 0.0, 8.0), (0, 10.0, 8.0), (0, 20.0, 8.0), (0, 30.0, 8.0), (1, 5.0, 30.0)])
    next_row("LONG closed group (40 s): scroll at 100 pps, zoom to ~2000 pps")

    # Open them all, the outermost last (a group opens in place, order does not matter for the
    # model, but the nested ones must be open for their bands to exist at all).
    for gid in to_open:
        cmd("group.expand", {"id": gid, "expanded": True})
    lane[0] = root

    cmd("selection.clear")
    manifest = os.path.join(out, "parity.objekat")
    cmd("project.save_as", {"path": manifest})
    # Only now, so that the project holds the path and the disk does not: a MISSING file.
    os.remove(gone)
    scan = cmd("project.rescan_missing")
    wf = cmd("perf.waveforms")

    print("Parity project written: %s" % manifest)
    print("  %d root lanes, %d paths missing (the two MISSING rows), media in %s" % (lane[0], scan["path_count"], media))
    print("\nLanes (display row, top = 0):")
    for row, name in rows:
        print("  %2d  %s" % (row, name))
    print("\nOpen groups (ROOT lane — the display row shifts down by what the groups above hold open):")
    for row, name in group_rows:
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

 The switch is ONE "everything rich" switch: `true` also puts the OPEN GROUPS' bands back on their
 old SwiftUI layers (below, "THE GROUPS' A/B"), `false` draws them in the one Canvas.

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
   - the stem colours, fades (straight and bent), reverse, speed, stereo separator

THE GROUPS' BLOCKS A/B (the closed-groups section, last rows; also look at the OPEN groups' blocks
above, which are the same drawing): the same switch, `true` = every group on `GroupBlockView`.
Select the "to SELECT" group and the open "SELECT as a whole" one, then flip it and compare:
   - the radius (20), the tint (0.30 / 0.55) and the INSET 2 pt border (0.5 / 0.9, in the custom
     colour when there is one) — the Canvas fill is built from the same shapes as the rich view
   - the composite: same silhouette, clipped to the rounded corners (a child at the very start),
     grey on a muted group, under the fade veils
   - the label: glyph + name (the Canvas's 11 pt glyph against the rich 12 pt, kept on purpose),
     the red + halo of the MISSING rows, the META from 80 px, the CHEVRON from 60 px (right when
     closed, down when open; its height on the name row is an estimate — compare it)
   - the muted veil (0.38) at the corners; a stem-muted group
   - a group on a stem; the crossfade-free neighbours; light and dark
   - what must stay RICH (counters: `perf.census` → `regimes.groups_rich`): an infinite group, a
     group being renamed (double click its name), one being dragged / trimmed / resized / faded,
     under the Volume / Pan / Aux tools, and a CONSOLIDATED object open for editing (its ✕). Not
     makeable here: a consolidated object (an asynchronous bake) — do it by hand.

THE GROUPS' A/B (the open-groups section, bottom of the project; nothing to select unless said).
Flip the same switch with each of these in view, light AND dark appearance (the base of the rise
is a dynamic colour, `controlBackgroundColor`), at 5 / 20 / 100 pps, and at ~2000 pps for the
group's start and end (the band must not stop short and the borders must keep their gaps):
   - the RISE under each group block: the block and the row below it must read as ONE material,
     no seam, no lighter or darker strip across the gutter, at the block's two bottom corners
   - the BAND tint and its borders: top border interrupted under the block, bottom border whole,
     1 px; no half-pixel shimmer at a fractional vertical zoom
   - the PARITY of the alternating rows: the groups sit on rows of both parities (the 1-lane
     group flips it for the next one); the rise must carry the same 2%% of black as the row it
     continues, on both
   - NESTED groups: the tints stack deeper = stronger, each level's rise matches its first row;
     the two-hue stack (the red inner one)
   - SELECTED group (select the "SELECT as a whole" group by its header) and a SELECTED CHILD of
     the "SELECT A CHILD" group: the band goes from 0.11 to 0.22 and the border from 0.35 to 0.8
     ("you are in this group"); the same on the parent when the child of a nested group is selected
   - the MUTED open group: the bands are the same as the unmuted one (only the block changes)
   - the '+' in the drop lane: size, grey, centred on the group's in/out range, also on the
     narrow group, and absent on a CLOSED group
   - the INFINITE group: full-width band, its rise spanning the whole width
   - scroll sideways at 100 pps: the band edges, the borders' gaps and the '+' must not flicker
     or pop at the viewport's edge""" % (
        manifest, manifest, wf.get("sample_mode_threshold", 0)))
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The picture and the sound of a video GROUP stay paired through every group gesture (plan-video §2.5, §9.3).

    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --socket=/tmp/v.sock
    ./scenario_video_group_sync.py /tmp/v.sock /path/to/scratch

The oracle is the corpus itself: every picture frame carries its number as a barcode and every audio
track carries ONE click at a known instant of the movie (2.0 s -> frame 48, 5.0 s -> frame 120 at
24 fps). After each gesture the mix is rendered by the REAL engine export (`export.run`), the position
of every click is read back (the sound as heard), and for each click the picture is rendered at that
very instant (`video.render_frame`, the preview's own graph): half a millisecond AFTER the click the
barcode must be the click's frame, half a millisecond BEFORE it the frame before. `video.layers` must
say the same source instant (within 0.5 ms). A gesture that removes the click must also remove (or
move) the picture at that instant. Where the click should land is also computed independently of the
engine (a plain model of the gesture) and compared to the sample.

Gestures: move, trim (head, tail, past the click), cut tool (window only), cut through (children
distributed), copy, slip of the collapsed group, loop (whole group, a sub-range, IN beyond the click),
the right half of a cut looped group, and a negative start (a child before 0 inside a cropped group).

Exit: 0 if every assertion passes, 1 otherwise.
"""
import os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from video_scenario_common import *  # noqa

if len(sys.argv) < 3:
    print(__doc__); sys.exit(2)
SOCK, SCRATCH = sys.argv[1], sys.argv[2]
FX = make_fixtures(os.path.join(SCRATCH, "fx"))
K = Checker(); check = K.check
FPS = 24.0
EPS = 0.0005          # just after the click (the player asks for the frame 0.5 ms past each boundary: VideoPlayerSlot.frameEpsilon)
EPS_BEFORE = 0.002    # just before it: 2 ms, clear of that 0.5 ms
casecount = [0]

with ObjekatClient(SOCK) as c:
    S = c.send

    def fresh(fixture="pcm16.mov", start=0.0):
        casecount[0] += 1
        d = os.path.join(SCRATCH, "gsync_%02d" % casecount[0])
        new_saved_project(c, d, "g")
        r = S("video.import", {"path": os.path.join(FX, fixture), "start": start, "lane": 0})
        S("wait_idle", {"timeout_ms": 5000})
        return r, d

    def pairing(label, d, expected, end, absent_probe=(), window_starts_at_click=False, observed=False):
        """`expected` = [(timeline instant, source instant of the movie)] the engine must play AND the
        picture must show. `absent_probe` = timeline instants where NO click may be heard and NO picture
        of the click's frame may be shown (a click that left the window takes its picture with it)."""
        x = export_mix(c, os.path.join(d, "mix.wav"), start=0.0, end=end)
        found = impulses(x)
        times = [i / SR for i, _ in found]
        if observed:
            # The click instants are the ENGINE's (no independent model): each must carry a picture of a click frame.
            print("info  %s: clicks heard at %s" % (label, ["%.4f" % t for t in times]))
            expected = [(idx / SR, expected[0][1] if len(expected) == 1 else None) for idx, _ in found]
        else:
            check("%s: %d click(s) heard" % (label, len(expected)), len(found) == len(expected), "heard %s" % ["%.4f" % t for t in times])
            if len(found) != len(expected):
                return
        for k, ((T, src), (idx, pk)) in enumerate(zip(expected, found)):
            if not observed:
                gap = idx - int(round(T * SR))
                check("%s: click %d at %.4f s (model) is %+d sample(s) from the engine's" % (label, k, T, gap), gap == 0, "heard sample %d" % idx)
            t_heard = idx / SR
            if src is None:      # observed, two kinds of click: the picture itself says which one (frame 48 or 120)
                src = 2.0 if abs(frame_at(c, t_heard + EPS, d)[0] - 48) == 0 else 5.0
            want = int(src * FPS + 1e-6)
            after, ra = frame_at(c, t_heard + EPS, d)
            before, rb = frame_at(c, t_heard - EPS_BEFORE, d)
            check("%s: click %d - picture right after it = frame %d" % (label, k, want), after == want, "got %s (render %s)" % (after, {k2: ra[k2] for k2 in ('layers', 'decoded')}))
            if window_starts_at_click:
                check("%s: click %d - nothing before it (the window starts on the click)" % (label, k), before is None, "got %s" % before)
            else:
                check("%s: click %d - picture 2 ms before it = frame %d" % (label, k, want - 1), before == want - 1, "got %s" % before)
            lay = S("video.layers", {"t": t_heard + EPS})["layers"]
            check("%s: click %d - video.layers says source %.4f s" % (label, k, src + EPS),
                  len(lay) == 1 and abs(lay[0]["source_time"] - (src + EPS)) < 1e-4, str([l["source_time"] for l in lay]))
        for T in absent_probe:
            lay = S("video.layers", {"t": T})["layers"]
            check("%s: no picture at %.3f s (the click's window is gone)" % (label, T), len(lay) == 0, str([l["source_time"] for l in lay]))

    def group_of(r):
        return r["id"]

    # ------------------------------------------------------------------ reference: untouched
    r, d = fresh(start=0.0)
    pairing("untouched", d, [(2.0, 2.0)], end=12)

    # ------------------------------------------------------------------ move (off the frame grid)
    r, d = fresh(start=0.0)
    S("object.move", {"id": r["id"], "start": 7.3})
    S("wait_idle", {"timeout_ms": 5000})
    pairing("move to 7.3", d, [(9.3, 2.0)], end=20)
    S("object.move", {"id": r["id"], "start": 0.0})
    pairing("move back to 0", d, [(2.0, 2.0)], end=12)

    # ------------------------------------------------------------------ trim: head, tail, past the click
    r, d = fresh(start=4.0)
    S("object.trim", {"id": r["id"], "start": 5.0, "duration": 9.0})
    S("wait_idle", {"timeout_ms": 5000})
    pairing("trim head by 1 s (window 5..14)", d, [(6.0, 2.0)], end=16)
    S("object.trim", {"id": r["id"], "start": 5.0, "duration": 2.0})   # window 5..7: the click (6.0) stays, the end is cut
    pairing("trim tail (window 5..7)", d, [(6.0, 2.0)], end=16, absent_probe=(7.2, 9.0))
    S("object.trim", {"id": r["id"], "start": 7.0, "duration": 5.0})   # head past the click (6.0)
    pairing("trim head past the click (window 7..12)", d, [], end=16, absent_probe=(6.0, 6.5))
    pic_at = frame_at(c, 7.5, d)[0]
    check("trim head past the click: the picture at 7.5 s is frame %d" % int((7.5 - 4.0) * FPS), pic_at == int((7.5 - 4.0) * FPS), str(pic_at))
    S("edit.undo")
    pairing("undo of that trim: window 5..7 again", d, [(6.0, 2.0)], end=16)
    S("edit.undo"); S("edit.undo")
    pairing("two more undos: the untouched group", d, [(6.0, 2.0)], end=16)

    # ------------------------------------------------------------------ cut tool (window only)
    r, d = fresh(start=3.0)       # click at 5.0
    S("object.split_at", {"seconds": 4.0, "ids": [r["id"]], "window_only": True})
    S("wait_idle", {"timeout_ms": 5000})
    rows = objects(c)
    tops = [o for o in rows.values() if o["parent"] is None and o["kind"] == "group"]
    check("cut tool: two groups", len(tops) == 2, str(len(tops)))
    pairing("cut tool at 4.0 (click in the RIGHT half)", d, [(5.0, 2.0)], end=16)
    S("edit.undo")
    S("object.split_at", {"seconds": 6.0, "ids": [r["id"]], "window_only": True})
    S("wait_idle", {"timeout_ms": 5000})
    pairing("cut tool at 6.0 (click in the LEFT half)", d, [(5.0, 2.0)], end=16)
    check("cut tool at 6.0: the picture right after the cut (6.1 s) is frame %d" % int(3.1 * FPS), frame_at(c, 6.1, d)[0] == int(3.1 * FPS))
    S("edit.undo")
    S("object.split_at", {"seconds": 5.0, "ids": [r["id"]], "window_only": True, "keep": "right"})
    S("wait_idle", {"timeout_ms": 5000})
    pairing("cut tool at the click's own instant, keep right", d, [(5.0, 2.0)], end=16, window_starts_at_click=True)

    # ------------------------------------------------------------------ cut through (children distributed)
    r, d = fresh(start=3.0)
    S("object.split_at", {"seconds": 4.0, "ids": [r["id"]]})
    S("wait_idle", {"timeout_ms": 5000})
    pairing("cut through at 4.0 (click in the right half)", d, [(5.0, 2.0)], end=16)
    # picture on both sides of the cut stays continuous
    for t in (3.5, 4.5, 6.0, 8.0):
        want = int((t - 3.0) * FPS + 1e-6)
        check("cut through at 4.0: picture at %.1f s is frame %d" % (t, want), frame_at(c, t, d)[0] == want)
    S("edit.undo")
    S("object.split_at", {"seconds": 6.5, "ids": [r["id"]]})
    S("wait_idle", {"timeout_ms": 5000})
    pairing("cut through at 6.5 (click in the left half)", d, [(5.0, 2.0)], end=16)
    for t in (6.0, 7.0, 9.0):
        want = int((t - 3.0) * FPS + 1e-6)
        check("cut through at 6.5: picture at %.1f s is frame %d" % (t, want), frame_at(c, t, d)[0] == want)
    S("edit.undo")

    # ------------------------------------------------------------------ copy
    r, d = fresh(start=0.0)
    dup = S("object.duplicate", {"ids": [r["id"]]})
    S("wait_idle", {"timeout_ms": 5000})
    rows = objects(c)
    groups = [o for o in rows.values() if o["kind"] == "group" and o["parent"] is None]
    check("copy: two top-level groups", len(groups) == 2, str(len(groups)))
    copy = [g for g in groups if g["id"] != r["id"]][0]
    S("object.move", {"id": copy["id"], "start": 20.0, "lane": 2})
    S("wait_idle", {"timeout_ms": 5000})
    pairing("copy moved to 20 (two clicks: 2.0 and 22.0)", d, [(2.0, 2.0), (22.0, 2.0)], end=34)
    flat = state_flat(c)
    check("copy: the copy has its own picture object (new id), same video facet", len(pictures(flat)) == 2 and len({p["id"] for p in pictures(flat)}) == 2)

    # ------------------------------------------------------------------ slip of the collapsed group
    # The gesture (EditViewModel+Slip, `slippableClips`) hands the content of a FOLDED group to the slip: every clip
    # with a file - the picture object and the sound - gets the same offset. The API slips one clip at a time
    # (`object.set_source_offset` refuses a group), so the gesture is replayed child by child. A clip whose window
    # is the whole file has no room to slip, so the children are first shortened to 8 s (file 10 s).
    r, d = fresh(start=3.0)       # click at 5.0, window 3..13, children 3..13
    rows = objects(c)
    kids = children_of(rows, r["id"])
    for k in kids:
        S("object.set_duration", {"id": k["id"], "duration": 8.0})
    S("wait_idle", {"timeout_ms": 5000})
    pairing("before the slip (children shortened to 8 s)", d, [(5.0, 2.0)], end=16)
    S("group.expand", {"id": r["id"], "expanded": False})
    for k in kids:
        S("object.set_source_offset", {"id": k["id"], "offset": 1.0})
    S("wait_idle", {"timeout_ms": 5000})
    flat = state_flat(c)
    got = {k["id"]: flat[k["id"]]["kind"].get("sourceOffset", 0) for k in kids}
    check("slip: the picture and the sound took the same offset (1.0)", all(abs(v - 1.0) < 1e-9 for v in got.values()), str(got))
    # the content moved 1 s earlier under the same window: the click (source 2.0) is now at 3.0 + (2.0 - 1.0) = 4.0
    pairing("slip +1.0 of the collapsed group (click now at 4.0)", d, [(4.0, 2.0)], end=16)
    for t in (3.0, 6.0, 9.5):
        want = int((t - 3.0 + 1.0) * FPS + 1e-6)
        check("slip: picture at %.1f s is frame %d (source %.1f)" % (t, want, t - 3.0 + 1.0), frame_at(c, t, d)[0] == want)

    # ------------------------------------------------------------------ loop
    r, d = fresh(start=0.0)       # click at 2.0, window 0..10
    S("object.set_loop", {"id": r["id"], "enabled": True})
    S("object.set_duration", {"id": r["id"], "duration": 25.0})
    S("wait_idle", {"timeout_ms": 5000})
    pairing("loop of the whole group over 25 s (3 passes of 10 s)", d, [(2.0, 2.0), (12.0, 2.0), (22.0, 2.0)], end=30)
    for t, want in ((1.0, 24), (11.0, 24), (21.0, 24), (24.9, int(4.9 * FPS)), (5.0, 120)):
        got = frame_at(c, t, d)[0]
        check("loop whole: picture at %.1f s is frame %d" % (t, want), got == want, str(got))
    S("object.set_loop_range", {"id": r["id"], "start": 1.0, "end": 4.0})
    S("wait_idle", {"timeout_ms": 5000})
    x = export_mix(c, os.path.join(d, "mix.wav"), start=0.0, end=30)
    times = [i / SR for i, _ in impulses(x)]
    print("info  loop range [1,4) over 25 s: clicks at %s" % times)
    # Independent model of the fold (plan §4.3): T local to the group, IN=1, OUT=4, L=3 -> origin=min(0,IN)=0
    # -> local = IN + ((T - origin) mod L) = 1 + (T mod 3). The click (local 2.0) is heard when T mod 3 == 1.
    model = [1.0 + 3.0 * n for n in range(0, 9) if 1.0 + 3.0 * n < 25.0]
    pairing("loop sub-range [1,4) over 25 s", d, [(t, 2.0) for t in model], end=30)
    S("object.set_loop_range", {"id": r["id"], "start": 3.0, "end": 6.0})   # pattern without the click
    S("wait_idle", {"timeout_ms": 5000})
    pairing("loop sub-range [3,6): the click is outside the pattern", d, [], end=30)
    lay = S("video.layers", {"t": 10.0})["layers"]
    check("loop sub-range [3,6): the picture at 10.0 s shows source %.1f (pattern 3..6, local %.1f)" % (3.0 + (10.0 % 3.0), 3.0 + (10.0 % 3.0)),
          len(lay) == 1 and abs(lay[0]["source_time"] - (3.0 + (10.0 % 3.0))) < 1e-6, str(lay))

    # ------------------------------------------------------------------ loop with both clicks (2 tracks), then cut the looped group
    r, d = fresh(fixture="multi.mov", start=0.0)       # clicks at 2.0 (frame 48) and 5.0 (frame 120)
    S("object.set_loop", {"id": r["id"], "enabled": True})
    S("object.set_loop_range", {"id": r["id"], "start": 1.0, "end": 7.0})
    S("object.set_duration", {"id": r["id"], "duration": 20.0})
    S("wait_idle", {"timeout_ms": 5000})
    # L = 6; local = 1 + (T mod 6). click@2 -> T = 1 + 6n ; click@5 -> T = 4 + 6n
    ev = sorted([(1.0 + 6 * n, 2.0) for n in range(4) if 1.0 + 6 * n < 20] + [(4.0 + 6 * n, 5.0) for n in range(4) if 4.0 + 6 * n < 20])
    pairing("loop [1,7) of a 2-click group over 20 s", d, ev, end=26)
    # cut the looped group in the middle (window only): the right half's IN becomes negative (plan 4.3)
    S("object.split_at", {"seconds": 9.0, "ids": [r["id"]], "window_only": True})
    S("wait_idle", {"timeout_ms": 5000})
    # After the cut the ENGINE is the oracle (it shifts the right half's phase by IN = 1 s on `main` too:
    # clicks at 11, 14, 17 instead of the seamless 10, 13, 16, 19 - a finding of the audio side, not of the video).
    # Whatever it plays, the picture must show the matching click frame at each of those instants.
    pairing("right half of a cut looped group (cut at 9.0) - engine as oracle", d, ev, end=26, observed=True)
    x = export_mix(c, os.path.join(d, "mix.wav"), start=0.0, end=26)
    heard = [round(i / SR, 3) for i, _ in impulses(x)]
    seamless = [t for t, _ in ev]
    print("info  cut looped group: heard %s, seamless continuation would be %s" % (heard, seamless))

    # ------------------------------------------------------------------ negative time: a child before 0 in a cropped group
    r, d = fresh(start=6.0)       # children at 6.0 (click at 8.0), window 6..16
    S("object.trim", {"id": r["id"], "start": 7.0, "duration": 9.0})     # window 7..16, children still start at 6.0
    S("object.move", {"id": r["id"], "start": 0.0})                      # window 0..9 -> children now start at -1.0
    S("wait_idle", {"timeout_ms": 5000})
    rows = objects(c)
    kids = children_of(rows, r["id"])
    starts = sorted(round(k["start"], 6) for k in kids)
    check("negative start: the children now begin before 0 (-1.0)", starts and starts[0] < 0 and abs(starts[0] + 1.0) < 1e-6, str(starts))
    pairing("negative start (children at -1.0, window 0..9)", d, [(1.0, 2.0)], end=12)
    got = frame_at(c, 0.0, d)[0]
    check("negative start: the picture at 0.0 is frame %d (movie 1.0 s)" % int(1.0 * FPS), got == int(1.0 * FPS), str(got))
    S("project.save")
    S("project.open", {"path": os.path.join(d, "g.objekat")})
    S("wait_idle", {"timeout_ms": 10000})
    pairing("negative start, after save + reopen", d, [(1.0, 2.0)], end=12)

sys.exit(K.finish())

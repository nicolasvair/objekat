#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The picture object's fades and silence (plan_fusion_video, part 2) - what `video.layers` says of its opacity.

    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --socket=/tmp/v.sock
    ./scenario_video_fade_mute.py /tmp/v.sock /path/to/scratch

The picture follows the sound's own rules, read through the very resolver the preview and
`video.render_frame` use (headless: no window, no player):

  * FADES are opacity, with the audio's curves: the picture's own fade-in / fade-out, a group's fade
    multiplying those of everything below it, the shapes (convex bulges, concave hollows), a layer that
    has faded out completely is not a layer; two groups cross-faded add up to full opacity at every
    instant (a crossfade never dips);
  * SILENCE hides the picture exactly where a sound object at its place would be silenced: its own mute,
    its group's mute, its stem's mute, and a SOLO elsewhere (the solo of the group keeps it, the solo of
    the audio child or of another object hides it, the solo of the picture itself keeps it) - while the
    mute of the audio CHILD leaves the picture alone;
  * a CROSSFADE between two sibling pictures is the same geometry as a sound's: the zone is opacity,
    the two halves add up to full opacity, the incoming picture is in front, the matter of both is
    re-exposed (the source time is continuous across the seam), an image against a SOUND is refused
    (`mixedMedia`), an image against a group is accepted, two pictures of two groups are refused by
    naming the groups; a muted half leaves the other alone at its own opacity; two layers at most;
    undo, redo and a reopened project give the same layers; and (Debug builds) the live preview of
    the drag and of the fade pulled out onto a neighbour say what the commit then writes;
  * the fades and the mute are saved with the project and undone like any edit; the engine commands that
    would act on a clip (set_fade, set_fade_curve, set_mute, crossfade.open) are harmless on an object
    that has none.

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
PROJ = os.path.join(SCRATCH, "fademute_proj")
TOL = 0.02


def near(a, b, tol=TOL):
    return a is not None and abs(a - b) <= tol


with ObjekatClient(SOCK) as c:
    S = c.send

    def idle():
        S("wait_idle", {"timeout_ms": 5000})

    def op(pic, t):
        """The opacity `video.layers` gives the picture at `t`, or None when it is not a layer."""
        for l in S("video.layers", {"t": t})["layers"]:
            if l["object_id"] == pic:
                return l["opacity"]
        return None

    def fades(oid, fin=0.0, fout=0.0):
        S("object.set_fade", {"id": oid, "in": fin, "out": fout}); idle()

    path = new_saved_project(c, PROJ, "fm")
    r = S("video.import", {"path": os.path.join(FX, "aac_mov.mov"), "start": 0.0, "lane": 0}); idle()
    grp, pic, aud = r["id"], r["picture_id"], r["audio_ids"][0]
    r2 = S("video.import", {"path": os.path.join(FX, "aac_mp4.mp4"), "start": 8.0, "lane": 4}); idle()
    grp2, pic2, aud2 = r2["id"], r2["picture_id"], r2["audio_ids"][0]
    print("info  group %s picture %s | second group %s picture %s" % (grp[:8], pic[:8], grp2[:8], pic2[:8]))
    check("start: the picture is a full-opacity layer at 5 s", near(op(pic, 5.0), 1.0, 1e-9), str(op(pic, 5.0)))

    # ------------------------------------------------------------------ the picture's own fades
    fades(pic, 2.0, 2.0)
    check("fade in 2 s: half opacity at 1 s", near(op(pic, 1.0), 0.5), str(op(pic, 1.0)))
    check("fade in 2 s: a quarter at 0.5 s", near(op(pic, 0.5), 0.25), str(op(pic, 0.5)))
    check("fade in 2 s: full opacity at 5 s", near(op(pic, 5.0), 1.0, 1e-9), str(op(pic, 5.0)))
    check("fade out 2 s: half opacity at 9 s", near(op(pic, 9.0), 0.5), str(op(pic, 9.0)))
    check("a picture faded out entirely is not a layer (nothing at 0.0)", op(pic, 0.0) is None, str(op(pic, 0.0)))
    S("object.set_fade_curve", {"id": pic, "in": "convex", "in_bend": 0.5}); idle()
    convex = op(pic, 1.0)
    S("object.set_fade_curve", {"id": pic, "in": "concave", "in_bend": 0.5}); idle()
    concave = op(pic, 1.0)
    S("object.set_fade_curve", {"id": pic, "in": "linear", "in_bend": 0.0}); idle()
    check("the shapes are the audio's: convex bulges above the straight line, concave hollows under it",
          convex is not None and concave is not None and convex > 0.6 and concave < 0.4 and near(op(pic, 1.0), 0.5),
          "convex %s concave %s" % (convex, concave))

    # ------------------------------------------------------------------ a group's fade multiplies
    fades(pic, 0.0, 0.0)
    fades(grp, 4.0, 0.0)
    check("group fade in 4 s: half opacity at 2 s, the picture having none of its own", near(op(pic, 2.0), 0.5), str(op(pic, 2.0)))
    fades(pic, 2.0, 0.0)
    check("group fade x picture fade: 0.5 x 0.25 at 1 s... = 0.125", near(op(pic, 1.0), 0.25 * 0.5), str(op(pic, 1.0)))
    fades(grp, 0.0, 0.0); fades(pic, 0.0, 0.0)
    check("fades cleared: full opacity again", near(op(pic, 1.0), 1.0, 1e-9), str(op(pic, 1.0)))

    # ------------------------------------------------------------------ crossfade between two video groups: no dip
    fades(grp, 0.0, 2.0)        # group 1 lives on 0..10, fades out over 8..10
    fades(grp2, 2.0, 0.0)       # group 2 starts at 8, fades in over 8..10
    sums, ok_two = [], True
    for t in (8.25, 8.5, 9.0, 9.5, 9.75):
        layers = S("video.layers", {"t": t})["layers"]
        if len(layers) != 2:
            ok_two = False
        sums.append(round(sum(l["opacity"] for l in layers), 3))
    check("two groups cross-faded: two layers and opacities adding up to 1 at every instant of the overlap",
          ok_two and all(near(s, 1.0, 0.03) for s in sums), str(sums))
    mid = [l["opacity"] for l in S("video.layers", {"t": 9.0})["layers"]]
    check("... half and half at the middle", len(mid) == 2 and all(near(m, 0.5) for m in mid), str(mid))
    fades(grp, 0.0, 0.0); fades(grp2, 0.0, 0.0)

    # ------------------------------------------------------------------ mute
    S("object.set_mute", {"ids": [pic], "muted": True}); idle()
    check("the picture muted: it is no layer", op(pic, 5.0) is None)
    S("object.set_mute", {"ids": [pic], "muted": False}); idle()
    check("... unmuted: back at full opacity", near(op(pic, 5.0), 1.0, 1e-9))
    S("object.set_mute", {"ids": [grp], "muted": True}); idle()
    check("the group muted: its picture is hidden", op(pic, 5.0) is None)
    S("object.set_mute", {"ids": [grp], "muted": False}); idle()
    S("object.set_mute", {"ids": [aud], "muted": True}); idle()
    check("the audio CHILD muted: the picture stays (a sibling's mute is not its own)", near(op(pic, 5.0), 1.0, 1e-9))
    S("object.set_mute", {"ids": [aud], "muted": False}); idle()

    # ------------------------------------------------------------------ solo and stem mute: the picture is heard as a sound would be
    def solo_state(label, on_ids, expected):
        S("solo.clear"); idle()
        S("solo.set", {"ids": on_ids, "on": True}); idle()
        check("solo of %s: the picture is %s" % (label, "kept" if expected else "hidden"),
              (op(pic, 5.0) is not None) == expected, str(op(pic, 5.0)))
    solo_state("its group", [grp], True)
    solo_state("the audio child", [aud], False)
    solo_state("the picture itself", [pic], True)
    solo_state("another object (the audio of the other group)", [aud2], False)
    solo_state("the other group", [grp2], False)
    S("solo.clear"); idle()
    check("no solo any more: the picture is back", near(op(pic, 5.0), 1.0, 1e-9))

    stem = S("stem.add", {"name": "Vid"})["id"]
    S("stem.assign", {"stem": stem, "ids": [grp]}); idle()
    S("stem.mute", {"id": stem, "muted": True}); idle()
    check("the stem of its group muted: the picture is hidden", op(pic, 5.0) is None)
    check("... and the other group (on the Main) keeps its picture", op(pic2, 9.0) is not None)
    S("stem.mute", {"id": stem, "muted": False}); idle()
    check("the stem unmuted: the picture is back", near(op(pic, 5.0), 1.0, 1e-9))

    # ------------------------------------------------------------------ the engine's doors are harmless on a picture
    refused = {}
    for name, params in (("object.set_fade", {"id": pic, "in": 1.0}),
                         ("object.set_fade_curve", {"id": pic, "in": "convex"}),
                         ("object.set_mute", {"ids": [pic], "muted": True}),
                         ("crossfade.open", {"left": pic, "right": pic2, "width": 1.0})):
        try:
            S(name, params); refused[name] = "ok"
        except ObjekatError as e:
            refused[name] = e.code
    print("info  on the picture: %s" % refused)
    check("set_fade, set_fade_curve and set_mute answer on a picture (no engine clip: nothing to do, no error)",
          all(refused[n] == "ok" for n in ("object.set_fade", "object.set_fade_curve", "object.set_mute")), str(refused))
    check("crossfade.open between the pictures of TWO groups is refused as bad_params, the groups named (E2), the app still answers",
          refused["crossfade.open"] == "bad_params" and S("app.info") is not None, str(refused["crossfade.open"]))
    S("object.set_mute", {"ids": [pic], "muted": False}); fades(pic, 0.0, 0.0)
    S("object.set_fade_curve", {"id": pic, "in": "linear", "in_bend": 0.0}); idle()

    # ------------------------------------------------------------------ undo, then persistence
    fades(pic, 2.0, 2.0)
    S("object.set_mute", {"ids": [pic2], "muted": True}); idle()
    check("fades and mute set: the first picture is half at 1 s, the second is hidden at 9.5 s",
          near(op(pic, 1.0), 0.5) and op(pic2, 9.5) is None, "%s %s" % (op(pic, 1.0), op(pic2, 9.5)))
    S("edit.undo"); idle()
    check("undo: the mute of the second picture is taken back", op(pic2, 9.5) is not None and near(op(pic, 1.0), 0.5))
    S("edit.undo"); idle()
    check("undo again: the fades of the first picture are gone (full opacity at 1 s)", near(op(pic, 1.0), 1.0, 1e-9), str(op(pic, 1.0)))
    S("edit.redo"); idle()
    S("edit.redo"); idle()
    before = {t: (op(pic, t), op(pic2, t)) for t in (0.5, 1.0, 5.0, 9.0, 9.5)}
    S("project.save"); idle()
    S("project.open", {"path": path}); idle()
    after = {t: (op(pic, t), op(pic2, t)) for t in before}

    def same_opacity(a, b):
        return (b is None) if a is None else near(a, b, 1e-6)
    same = all(same_opacity(before[t][0], after[t][0]) and same_opacity(before[t][1], after[t][1]) for t in before)
    check("saved and reopened: the same opacities (fades) and the same hidden picture (mute)", same, "%s -> %s" % (before, after))
    check("... the muted picture is still hidden, the faded one still half at 1 s",
          op(pic2, 9.5) is None and near(op(pic, 1.0), 0.5), "%s %s" % (op(pic2, 9.5), op(pic, 1.0)))

    # ================================================================================================
    # CROSSFADE between two sibling PICTURES (plan_xfade_image)
    # ================================================================================================
    def layers(t):
        return S("video.layers", {"t": t})["layers"]

    def ids_at(t):
        return [l["object_id"] for l in layers(t)]

    def refusal(name, params):
        try:
            S(name, params); idle()
            return None, None
        except ObjekatError as e:
            return e.code, e

    def fresh(sub, name):
        S("project.new")
        return new_saved_project(c, os.path.join(SCRATCH, sub), name)

    def two_halves():
        """A silent picture cut at 5 s: (left id, right id), left first."""
        r = S("video.import", {"path": os.path.join(FX, "silent.mp4"), "start": 0.0, "lane": 0}); idle()
        S("object.split_at", {"seconds": 5.0, "ids": [r["id"]]}); idle()
        pics = sorted(pictures(state_flat(c)), key=lambda i: i["startTime"])
        return pics[0]["id"], pics[1]["id"]

    # ---- A. two halves of one silent picture, root level
    xpath = fresh("xfade_proj", "xf")
    L, R = two_halves()
    check("A: before: a butted pair is one layer at a time, no overlap (one layer at 4.9 s, one at 5.1 s)",
          ids_at(4.9) == [L] and ids_at(5.1) == [R], "%s %s" % (ids_at(4.9), ids_at(5.1)))
    S("crossfade.open", {"left": L, "right": R, "width": 2.0}); idle()
    z = S("crossfade.list")["crossfades"]
    check("A: crossfade.open on two sibling pictures works (one zone listed)", len(z) == 1, str(z))
    sums = []
    for t in (4.1, 4.5, 5.0, 5.5, 5.9):
        ls = layers(t)
        sums.append((len(ls), round(sum(l["opacity"] for l in ls), 3)))
    check("A: two layers and opacities adding up to 1 at every instant of the zone",
          all(n == 2 and near(sm, 1.0, 0.03) for n, sm in sums), str(sums))
    mid = layers(5.0)
    check("A: half and half at the middle of the zone", len(mid) == 2 and all(near(l["opacity"], 0.5) for l in mid),
          str([l["opacity"] for l in mid]))
    check("A: outside the zone one layer at full opacity (3.9 s: left, 6.1 s: right)",
          ids_at(3.9) == [L] and ids_at(6.1) == [R] and near(op(L, 3.9), 1.0, 1e-9) and near(op(R, 6.1), 1.0, 1e-9),
          "%s %s" % (ids_at(3.9), ids_at(6.1)))
    check("A: the INCOMING picture is in front (last layer = the right-hand one) through the whole zone",
          all(ids_at(t)[-1] == R for t in (4.1, 4.5, 5.0, 5.5, 5.9)), str([ids_at(t) for t in (4.5, 5.0, 5.5)]))
    check("A: the matter is re-exposed: both layers read the same source instant at the seam (5.0 s)",
          all(near(l["source_time"], 5.0, 0.05) for l in mid), str([l["source_time"] for l in mid]))
    check("A: the source time keeps running through the zone (left at 4.5 s reads 4.5, right at 5.5 s reads 5.5)",
          near(next(l for l in layers(4.5) if l["object_id"] == L)["source_time"], 4.5, 0.05)
          and near(next(l for l in layers(5.5) if l["object_id"] == R)["source_time"], 5.5, 0.05))
    # a still really composed at the seam: two layers decoded
    fr = S("video.render_frame", {"time": 5.0, "path": os.path.join(SCRATCH, "xf_seam.png")})
    check("A: video.render_frame at the seam composes two layers", fr.get("layers") == 2, str(fr))

    # ---- A2. mute of one half: the other alone at its own opacity
    S("object.set_mute", {"ids": [L], "muted": True}); idle()
    ls = layers(4.5)
    check("A: the left half muted: the right one is alone in the zone, at ITS opacity (0.25 at 4.5 s)",
          len(ls) == 1 and ls[0]["object_id"] == R and near(ls[0]["opacity"], 0.25), str(ls))
    S("object.set_mute", {"ids": [L], "muted": False}); idle()
    S("object.set_mute", {"ids": [R], "muted": True}); idle()
    ls = layers(5.5)
    check("A: the right half muted: the left one is alone in the zone, at ITS opacity (0.25 at 5.5 s)",
          len(ls) == 1 and ls[0]["object_id"] == L and near(ls[0]["opacity"], 0.25), str(ls))
    S("object.set_mute", {"ids": [R], "muted": False}); idle()
    check("A: both back: two layers again", len(layers(5.0)) == 2)

    # ---- A3. the sound's mirror rule: a convex fade-out against a concave fade-in keeps the sum at 1
    S("object.set_fade_curve", {"id": L, "out": "convex", "out_bend": 0.5}); idle()
    S("object.set_fade_curve", {"id": R, "in": "concave", "in_bend": 0.5}); idle()
    convex_mid = [l["opacity"] for l in layers(4.5) if l["object_id"] == L]
    concave_mid = [l["opacity"] for l in layers(4.5) if l["object_id"] == R]
    check("A: the shapes are the sound's: at a quarter of the zone the convex fade-out is above 0.8, the concave fade-in under 0.2",
          convex_mid and concave_mid and convex_mid[0] > 0.8 and concave_mid[0] < 0.2, "%s %s" % (convex_mid, concave_mid))
    S("object.set_fade_curve", {"id": L, "out": "linear", "out_bend": 0.0}); idle()
    S("object.set_fade_curve", {"id": R, "in": "linear", "in_bend": 0.0}); idle()

    # ---- A4. undo / redo / persistence
    undos = 0
    while len(S("crossfade.list")["crossfades"]) > 0 and undos < 14:     # the mutes, the curves, then the crossfade itself
        S("edit.undo"); idle(); undos += 1
    n_after_undo = len(S("crossfade.list")["crossfades"])
    check("A: undo: the curves and the crossfade are taken back, a butted pair again (one layer at 4.5 s)",
          n_after_undo == 0 and len(layers(4.5)) == 1, "zones %d layers %d" % (n_after_undo, len(layers(4.5))))
    for _ in range(undos):
        S("edit.redo"); idle()
    check("A: redo: the crossfade is back, two layers at 5.0 s", len(layers(5.0)) == 2)
    before = {t: [(l["object_id"][:8], round(l["opacity"], 4)) for l in layers(t)] for t in (3.9, 4.5, 5.0, 5.5, 6.1)}
    S("project.save"); idle()
    S("project.open", {"path": xpath}); idle()
    after = {t: [(l["object_id"][:8], round(l["opacity"], 4)) for l in layers(t)] for t in before}
    check("A: saved and reopened: the same layers and opacities", before == after, "%s\n   -> %s" % (before, after))
    S("crossfade.close", {"left": L, "right": R}); idle()
    check("A: crossfade.close: one layer again at 5.0 s and the two halves butted",
          len(layers(5.0)) == 1 and len(S("crossfade.list")["crossfades"]) == 0)

    # ---- B. image against SOUND: refused, in both directions
    fresh("xfade_projb", "xfb")
    r = S("video.import", {"path": os.path.join(FX, "silent.mp4"), "start": 0.0, "lane": 0}); idle()
    pic_s = r.get("picture_id", r["id"])
    snd = S("object.add", {"path": os.path.join(HERE, "fixtures", "bip.wav"), "lane": 0, "start": 10.0})["id"]; idle()
    code, err = refusal("crossfade.open", {"left": pic_s, "right": snd, "width": 0.2})
    check("B: picture then sound: crossfade.open refused as bad_params, naming the mix of media",
          code == "bad_params" and err is not None and "picture" in str(err.message).lower() and "sound" in str(err.message).lower(),
          "%s %s" % (code, err and err.message))
    check("B: ... and nothing was written (no zone)", len(S("crossfade.list")["crossfades"]) == 0)
    S("object.move", {"id": snd, "start": 0.0}); idle()
    S("object.move", {"id": pic_s, "start": 0.4}); idle()
    code, err = refusal("crossfade.open", {"left": snd, "right": pic_s, "width": 0.2})
    check("B: sound then picture: refused too", code == "bad_params", "%s %s" % (code, err and err.message))

    # ---- C. image against a GROUP: accepted
    fresh("xfade_projc", "xfc")
    Lc, Rc = two_halves()
    S("object.remove", {"ids": [Rc]}); idle()
    rg = S("video.import", {"path": os.path.join(FX, "aac_mov.mov"), "start": 5.0, "lane": 0}); idle()
    grp_c = rg["id"]
    code, err = refusal("crossfade.open", {"left": Lc, "right": grp_c, "width": 2.0})
    check("C: a picture against a GROUP is accepted", code is None, "%s %s" % (code, err and err.message))
    if code is None:
        ls = layers(5.0)
        check("C: at the middle of the zone two layers add up to 1",
              len(ls) == 2 and near(sum(l["opacity"] for l in ls), 1.0, 0.03), str(ls))

    # ---- D. two pictures of TWO groups: refused, naming the groups
    fresh("xfade_projd", "xfd")
    r1 = S("video.import", {"path": os.path.join(FX, "aac_mov.mov"), "start": 0.0, "lane": 0}); idle()
    r2 = S("video.import", {"path": os.path.join(FX, "aac_mp4.mp4"), "start": 10.0, "lane": 0}); idle()
    code, err = refusal("crossfade.open", {"left": r1["picture_id"], "right": r2["picture_id"], "width": 1.0})
    det = getattr(err, "details", None) or {}
    msg = str(err.message) if err else ""
    check("D: two pictures of two groups: refused as bad_params", code == "bad_params", "%s %s" % (code, msg))
    check("D: ... the message names the groups (and says what to do)", "group" in msg.lower(), msg)
    check("D: ... and the details carry the two groups' ids",
          det.get("left_group") == r1["id"] and det.get("right_group") == r2["id"], str(det))
    check("D: nothing was written", len(S("crossfade.list")["crossfades"]) == 0)

    # ---- E. at most two layers
    fresh("xfade_proje", "xfe")
    La, Ra = two_halves()
    S("crossfade.open", {"left": La, "right": Ra, "width": 2.0}); idle()
    third = S("video.import", {"path": os.path.join(FX, "silent.mp4"), "start": 0.0, "lane": 3}); idle()
    ls = layers(5.0)
    check("E: three pictures at one instant: two layers at most (the cap is kept)",
          len(ls) <= 2, str(len(ls)))

    # ---- F. the live preview (Debug builds only)
    fresh("xfade_projf", "xff")
    Lf, Rf = two_halves()
    S("crossfade.open", {"left": Lf, "right": Rf, "width": 2.0}); idle()
    ts = [4.5, 5.0, 5.5]
    try:
        d = S("debug.crossfade_drag", {"lefts": [Lf], "rights": [Rf], "part": "both", "dx": [0.1, 0.2, 0.5],
                                       "video_t": ts})
        idle()
        prev, aft = d["video_layers_preview"], d["video_layers_after"]

        def flat_layers(rows):
            return [[(l["object_id"][:8], round(l["opacity"], 3), round(l["source_time"], 2)) for l in row["layers"]] for row in rows]
        check("F: the drag changes nothing in the model while the hand is down (0 writes)", d["drag_items_writes"] == 0, str(d["drag_items_writes"]))
        check("F: the preview index of the drag's copies says what the commit then writes",
              flat_layers(prev) == flat_layers(aft), "%s\n   vs %s" % (flat_layers(prev), flat_layers(aft)))
        check("F: the preview shows two layers with the incoming one in front at the seam",
              len(prev[1]["layers"]) == 2 and prev[1]["layers"][-1]["object_id"] == Rf, str(prev[1]))
        S("edit.undo"); idle()
    except ObjekatError as e:
        print("info  debug.crossfade_drag unavailable here (%s: %s): preview checks skipped" % (e.code, e.message))
    # a fade pulled out onto the neighbour: the preview of the crossfade being CREATED
    fresh("xfade_projg", "xfg")
    Lg, Rg = two_halves()
    try:
        d = S("debug.crossfade_spill_preview", {"left": Lg, "right": Rg, "width": 2.0, "side": "out", "t": [5.5, 6.0, 6.5]})
        check("F: the spill preview writes nothing (0 writes, 0 undo)", d["items_writes"] == 0 and d["undo_pushes"] == 0, str(d))
        pv = [[(l["object_id"], round(l["opacity"], 3), round(l["source_time"], 2)) for l in row["layers"]] for row in d["layers"]]
        check("F: ... and shows two layers at the middle, the incoming one in front",
              len(pv[1]) == 2 and pv[1][-1][0] == Rg, str(pv))
        S("crossfade.open", {"left": Lg, "right": Rg, "width": 2.0, "start": 5.0, "pin": "start"}); idle()
        real = [[(l["object_id"], round(l["opacity"], 3), round(l["source_time"], 2)) for l in layers(t)] for t in (5.5, 6.0, 6.5)]
        check("F: ... identical to what crossfade.open then gives", pv == real, "%s\n   vs %s" % (pv, real))
    except ObjekatError as e:
        print("info  debug.crossfade_spill_preview unavailable here (%s: %s): skipped" % (e.code, e.message))


sys.exit(K.finish())

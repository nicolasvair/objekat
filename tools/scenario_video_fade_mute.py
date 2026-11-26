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
    check("crossfade.open on a picture is refused or does nothing, never a crash (the app still answers)",
          S("app.info") is not None, str(refused["crossfade.open"]))
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

sys.exit(K.finish())

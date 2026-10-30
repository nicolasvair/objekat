#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The picture object inside its group (plan-video §5.1, §9.3) - the V1 slice of `scenario_video_edit`.

    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --socket=/tmp/v.sock
    ./scenario_video_edit.py /tmp/v.sock /path/to/scratch

  * the movie's own sound is NOT in the composite: the mix of an imported group holds one click, and it
    is silent once the extracted audio child is muted (so the .mov/.mp4 itself is never played);
  * no waveform cache (`.wfc`) is made for the video file itself (only for the extracted audio);
  * a plugin and a send are REFUSED on the picture object (and accepted on the audio child);
  * the picture object can be cut and trimmed alone, undone and redone, and the sound is not touched.

Not in V1 (no thumbnails, fades, mute of the picture, reverse, `Reunir`): not tested here.

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
PROJ = os.path.join(SCRATCH, "edit_proj")
FPS = 24.0

with ObjekatClient(SOCK) as c:
    S = c.send
    new_saved_project(c, PROJ, "e")

    # ------------------------------------------------------------------ the sound of the .mov is not in the composite
    r = S("video.import", {"path": os.path.join(FX, "aac_mov.mov"), "start": 0.0, "lane": 0})
    S("wait_idle", {"timeout_ms": 5000})
    pic, aud, grp = r["picture_id"], r["audio_ids"][0], r["id"]
    x = export_mix(c, os.path.join(SCRATCH, "edit_mix.wav"), start=0.0, end=12.0)
    clicks = impulses(x, thr=0.05)
    check("the mix of the group holds ONE click (the extracted sound; the .mov's own is not played)", len(clicks) == 1 and clicks[0][0] == 2 * SR, str(clicks))
    S("object.set_mute", {"ids": [aud], "muted": True})
    S("wait_idle", {"timeout_ms": 5000})
    x = export_mix(c, os.path.join(SCRATCH, "edit_mix_muted.wav"), start=0.0, end=12.0)
    import numpy as np
    check("with the audio child muted the mix is silent (peak < 1e-6): nothing of the .mov leaks in", float(np.max(np.abs(x))) < 1e-6, "peak %g" % float(np.max(np.abs(x))))
    S("object.set_mute", {"ids": [aud], "muted": False})
    try:
        out = S("object.render_isolated", {"id": pic, "path": os.path.join(SCRATCH, "edit_pic_isolated.wav"), "start": 0.0, "end": 6.0})
        res = S("job.wait", {"id": out["job_id"], "timeout_ms": 30000})
        if res.get("state") == "done" and os.path.exists(os.path.join(SCRATCH, "edit_pic_isolated.wav")):
            xi, _ = read_wav(os.path.join(SCRATCH, "edit_pic_isolated.wav"))
            check("render_isolated of the PICTURE object is silent", float(np.max(np.abs(xi))) < 1e-6, "peak %g" % float(np.max(np.abs(xi))))
        else:
            check("render_isolated of the PICTURE object does not produce sound (job %s)" % res.get("state"), res.get("state") in ("failed", "cancelled"), str(res)[:200])
    except ObjekatError as e:
        check("render_isolated of the PICTURE object is refused (%s)" % e.code, True)

    # ------------------------------------------------------------------ no .wfc for the video
    wf = os.path.join(PROJ, "waveforms")
    names = sorted(os.listdir(wf)) if os.path.isdir(wf) else []
    S("group.expand", {"id": grp, "expanded": True}); S("wait_idle", {"timeout_ms": 5000})
    S("project.save")
    names = sorted(os.listdir(wf)) if os.path.isdir(wf) else []
    print("info  waveforms/: %s" % names)
    check("no .wfc named after the video file (.mov / .mp4 / .m4v)", not any(n.endswith((".mov.wfc", ".mp4.wfc", ".m4v.wfc")) for n in names), str(names))
    check("no waveform is cached for the original file's name at all", not any(n.startswith("aac_mov.mov") for n in names), str(names))

    # ------------------------------------------------------------------ plugin / send on the picture
    try:
        S("plugin.add", {"host": pic, "identifier": "4bandEq"}); refused = None
    except ObjekatError as e:
        refused = e
    check("plugin.add on the picture object is refused (invalid_state)", refused is not None and refused.code == "invalid_state", str(refused))
    ok_audio = True
    try:
        S("plugin.add", {"host": aud, "identifier": "4bandEq"})
    except ObjekatError as e:
        ok_audio = False; print("info  plugin.add on the audio child: %s" % e)
    check("plugin.add on the AUDIO child still works", ok_audio)
    aux = S("aux.create", {"start": 0.0, "end": 12.0, "lane": 6})["id"]
    try:
        S("send.create", {"id": pic, "aux": aux}); refused = None
    except ObjekatError as e:
        refused = e
    check("send.create from the picture object is refused (invalid_state)", refused is not None and refused.code == "invalid_state", str(refused))
    try:
        S("send.create", {"id": aud, "aux": aux}); sent = True
    except ObjekatError as e:
        sent = False; print("info  send.create from the audio child: %s" % e)
    check("send.create from the AUDIO child still works", sent)
    flat = state_flat(c)
    check("the picture object carries no plugin and no send in the saved document",
          not (flat[pic].get("plugins") or flat[pic].get("sends")), str({k: flat[pic].get(k) for k in ("plugins", "sends")}))

    # ------------------------------------------------------------------ cut, trim, undo of the picture alone
    def picture_ids():
        return [i for i in state_flat(c).values() if i.get("video")]

    def frame(t):
        return frame_at(c, t, SCRATCH, "edit_f.png")[0]

    check("start: one picture object", len(picture_ids()) == 1)
    cut = S("object.split_at", {"seconds": 4.0, "ids": [pic]})
    S("wait_idle", {"timeout_ms": 5000})
    pics = picture_ids()
    check("cutting the picture object at 4.0 makes TWO pictures (object.split_at answered %d piece(s))" % cut["count"], len(pics) == 2, "%d picture(s)" % len(pics))
    cut_done = len(pics) == 2
    if cut_done:
        check("cut picture: frame at 3.99 is %d, at 4.01 is %d (continuous across the cut)" % (int(3.99 * FPS), int(4.01 * FPS)),
              frame(3.99) == int(3.99 * FPS) and frame(4.01) == int(4.01 * FPS), "%s %s" % (frame(3.99), frame(4.01)))
        check("cut picture: frames at 0.5 and 9.9 are right", frame(0.5) == 12 and frame(9.9) == int(9.9 * FPS), "%s %s" % (frame(0.5), frame(9.9)))
        x = export_mix(c, os.path.join(SCRATCH, "edit_mix2.wav"), start=0.0, end=12.0)
        check("the cut of the picture did not touch the sound (one click at 2.0)", [i for i, _ in impulses(x)] == [2 * SR])
        S("edit.undo"); S("wait_idle", {"timeout_ms": 5000})
        check("undo of the cut: one picture again, frame at 4.01 right", len(picture_ids()) == 1 and frame(4.01) == int(4.01 * FPS))
        S("edit.redo"); S("wait_idle", {"timeout_ms": 5000})
        check("redo of the cut: two pictures", len(picture_ids()) == 2)
        S("edit.undo"); S("wait_idle", {"timeout_ms": 5000})

    S("object.trim", {"id": pic, "start": 1.0, "duration": 6.0})     # picture 1..7
    S("wait_idle", {"timeout_ms": 5000})
    check("trim of the picture (1..7): picture at 0.5 s is gone", S("video.layers", {"t": 0.5})["layers"] == [])
    check("trim of the picture (1..7): picture at 1.5 s is frame %d (the content did not move)" % int(1.5 * FPS), frame(1.5) == int(1.5 * FPS), str(frame(1.5)))
    check("trim of the picture (1..7): picture at 7.5 s is gone", S("video.layers", {"t": 7.5})["layers"] == [])
    x = export_mix(c, os.path.join(SCRATCH, "edit_mix3.wav"), start=0.0, end=12.0)
    check("the trim of the picture did not touch the sound", [i for i, _ in impulses(x)] == [2 * SR])
    S("edit.undo"); S("wait_idle", {"timeout_ms": 5000})
    check("undo of the trim: picture at 0.5 s is back (frame 12)", frame(0.5) == 12)
    check("undo of the trim: picture at 9.9 s is back", frame(9.9) == int(9.9 * FPS))

    # ------------------------------------------------------------------ a picture alone (no sound) cut and trimmed like a clip
    S("group.expand", {"id": grp, "expanded": False})
    r2 = S("video.import", {"path": os.path.join(FX, "silent.mp4"), "start": 20.0, "lane": 9})   # a lane clear of the (expanded) group
    S("wait_idle", {"timeout_ms": 5000})
    n_before = len(picture_ids())
    cut2 = S("object.split_at", {"seconds": 24.0, "ids": [r2["id"]]})
    S("wait_idle", {"timeout_ms": 5000})
    n_pic = len(picture_ids())
    check("silent video (a picture alone, top level) cut at 24.0 makes two pictures (answered %d piece(s))" % cut2["count"], n_pic == n_before + 1, "%d picture(s) in the project" % n_pic)
    check("silent video cut at 24.0: picture at 23.9 s is frame %d and at 24.1 s frame %d" % (int(3.9 * FPS), int(4.1 * FPS)),
          frame(23.9) == int(3.9 * FPS) and frame(24.1) == int(4.1 * FPS), "%s %s" % (frame(23.9), frame(24.1)))
    if n_pic > n_before:
        S("edit.undo"); S("wait_idle", {"timeout_ms": 5000})
        check("silent video: undo of the cut keeps ONE picture there", frame(24.1) == int(4.1 * FPS))

sys.exit(K.finish())

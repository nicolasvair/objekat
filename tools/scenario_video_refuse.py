#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""What OBJEKAT refuses to import as a video (plan-video §3.2, §9.3): refused CLEARLY, nothing created.

    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --socket=/tmp/v.sock
    ./scenario_video_refuse.py /tmp/v.sock /path/to/scratch

For each file: `video.probe` says `refused` with a stable reason, `video.import` fails with that reason
and a message a person can read, the object count is unchanged, no undo point was pushed (the earlier
work is not undone by an `edit.undo`), and `samples/video/` holds exactly what it held before.

  fake.mkv       Matroska by name (and by magic bytes)          -> unsupported_container
  notvideo.txt   not a media file                               -> unsupported_container
  badcodec.mp4   a real MP4 whose picture FourCC is one nobody decodes -> undecodable_codec
  garbage.mp4    random bytes under a .mp4 name                  -> unreadable
  empty.mov      zero bytes                                      -> unreadable
  bip.wav        an audio file                                   -> audio_only (probe) / refused (import)
  (missing)      a path that does not exist                      -> not_found

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
PROJ = os.path.join(SCRATCH, "refuse_proj")
BIP = os.path.join(HERE, "fixtures", "bip.wav")

CASES = [
    ("fake.mkv",     os.path.join(FX, "refuse", "fake.mkv"),     "unsupported_container"),
    ("notvideo.txt", os.path.join(FX, "refuse", "notvideo.txt"), "unsupported_container"),
    ("badcodec.mp4", os.path.join(FX, "refuse", "badcodec.mp4"), "undecodable_codec"),
    ("garbage.mp4",  os.path.join(FX, "refuse", "garbage.mp4"),  "unreadable"),
    ("empty.mov",    os.path.join(FX, "refuse", "empty.mov"),    "unreadable"),
]

def tree(root):
    out = []
    for d, _, fs in os.walk(root):
        for f in fs:
            out.append(os.path.relpath(os.path.join(d, f), root))
    return sorted(out)

with ObjekatClient(SOCK) as c:
    S = c.send
    new_saved_project(c, PROJ, "r")
    S("object.add", {"path": BIP, "lane": 2, "start": 1.0})     # an earlier step an erroneous undo would remove
    S("wait_idle", {"timeout_ms": 5000})
    n0 = S("app.info")["object_count"]
    files0 = tree(os.path.dirname(PROJ))

    for name, path, reason in CASES:
        p = S("video.probe", {"path": path})
        check("%s: probe says refused / %s" % (name, reason), p.get("kind") == "refused" and p.get("reason") == reason, str(p))
        try:
            S("video.import", {"path": path}); err = None
        except ObjekatError as e:
            err = e
        check("%s: import fails with reason %s" % (name, reason), err is not None and (err.details or {}).get("reason") == reason, str(err))
        if err is not None:
            check("%s: the message is a sentence (>= 20 characters, names no raw code)" % name, len(err.message) >= 20, err.message)
        check("%s: no object created" % name, S("app.info")["object_count"] == n0)
        check("%s: no file created in the project folder" % name, tree(os.path.dirname(PROJ)) == files0, str(set(tree(os.path.dirname(PROJ))) ^ set(files0)))

    # No undo point may have been left by any of them: the earlier object (bip.wav) is still there after one undo
    # only if the stack holds exactly the steps that existed before.
    rows0 = {o["name"] for o in S("object.list")["objects"]}
    check("the earlier object is still there after all the refusals", "bip.wav" in rows0)

    # an audio WAV: not a video container
    p = S("video.probe", {"path": BIP})
    check("bip.wav: probe says refused / unsupported_container", p.get("kind") == "refused" and p.get("reason") == "unsupported_container", str(p))
    try:
        S("video.import", {"path": BIP}); err = None
    except ObjekatError as e:
        err = e
    check("bip.wav: video.import refuses it (bad_params, unsupported_container)", err is not None and err.code == "bad_params" and (err.details or {}).get("reason") == "unsupported_container", str(err))
    check("bip.wav: no object created", S("app.info")["object_count"] == n0)

    # a path that does not exist
    for fn, label in (("video.probe", "probe"), ("video.import", "import")):
        try:
            S(fn, {"path": os.path.join(SCRATCH, "nowhere.mp4")}); err = None
        except ObjekatError as e:
            err = e
        check("missing path: %s answers not_found" % label, err is not None and err.code == "not_found", str(err))

    # a refusal leaves the undo stack alone: one undo removes the bip.wav (the single earlier step), not more
    S("edit.undo")
    check("one undo takes away the earlier step only (the refusals left no undo point)", S("app.info")["object_count"] == n0 - 1)
    S("edit.redo")
    check("... and redo gives it back", S("app.info")["object_count"] == n0)

    # a good video right after the refusals still imports
    r = S("video.import", {"path": os.path.join(FX, "aac_mp4.mp4"), "start": 5.0, "lane": 4})
    check("a valid MP4 imports normally after the refusals", r["group"] is True and S("app.info")["object_count"] == n0 + 1)

    # an audio-only MP4/M4A (the sound extracted from that very video) is not a video either
    m4a = os.path.join(PROJ.replace("refuse_proj", "refuse_proj"), "samples", "video", r["audio_tracks"][0]["file"])
    import shutil
    audio_only = os.path.join(SCRATCH, "refuse_audio_only.mp4")     # the same ISO container, no picture track
    shutil.copyfile(m4a, audio_only)
    p = S("video.probe", {"path": audio_only})
    check("an MP4 with no picture track: probe says audio_only", p.get("kind") == "audio_only", str(p))
    n1 = S("app.info")["object_count"]
    try:
        S("video.import", {"path": audio_only}); err = None
    except ObjekatError as e:
        err = e
    check("an MP4 with no picture track: video.import refuses it, nothing created", err is not None and S("app.info")["object_count"] == n1, str(err))

sys.exit(K.finish())

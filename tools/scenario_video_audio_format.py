#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The sound of an imported video lands on the SAMPLE the picture says it does (plan-video §2.4, §9.3).

    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --socket=/tmp/v.sock
    ./scenario_video_audio_format.py /tmp/v.sock /path/to/scratch

Every fixture audio track carries ONE impulse at a known instant of the MOVIE's clock
(`make_video_fixtures.swift`). The files are imported side by side (one group per file, 12 s apart),
the mix is rendered by the REAL engine export (`export.run`, 24-bit WAV, 48 kHz), and the position of
every click is read back: the gap to `group start + impulse instant` must be 0 samples.

Covered: AAC-M4A from a MOV and from an MP4, PCM 16 / 24 / 32-float (depth kept), an audio that starts
AFTER the picture (AAC and PCM), two audio tracks (the alternate one comes in muted), a 44.1 kHz track
(resampled by the engine: the gap is REPORTED and held to one sample). The "fallback" row of the plan
(a stream that fails the engine-reader verification) cannot be forced through the API: it is carried by
`test_video_audio_align.swift`, and any import here that falls back reports `fallback_reason`.

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
PROJ = os.path.join(SCRATCH, "audio_format_proj")

# file, movie-clock instant(s) of the impulse(s) that must be heard, expected `written`, picture-relative start of the audio clip
CASES = [
    ("aac_mp4.mp4",        [2.0], "kept",  0.0),
    ("aac_mov.mov",        [2.0], "kept",  0.0),
    ("pcm16.mov",          [2.0], "wav16", 0.0),
    ("pcm24.mov",          [2.0], "wav24", 0.0),
    ("pcm32f.mov",         [2.0], "wav32f", 0.0),
    ("late_audio.mp4",     [4.0], None,    1.5),
    ("late_aac.mov",       [4.0], None,    1.5),
    ("late_audio_pcm.mov", [4.0], "wav24", 1.5),
    ("disabled.mov",       [2.0], "wav16", 0.0),
    ("multi.mov",          [2.0, 5.0], "wav16", 0.0),
    ("sr44.mov",           [2.0], "wav16", 0.0),
]
STEP = 12.0

def wav_header(path):
    import struct
    with open(path, "rb") as fh:
        raw = fh.read(4096)
    pos = 12
    while pos + 8 <= len(raw):
        cid, size = raw[pos:pos + 4], struct.unpack("<I", raw[pos + 4:pos + 8])[0]
        if cid == b"fmt ":
            tag, ch, sr, _, _, bits = struct.unpack("<HHIIHH", raw[pos + 8:pos + 24])
            return tag, ch, sr, bits
        pos += 8 + size + (size & 1)
    return None

with ObjekatClient(SOCK) as c:
    S = c.send
    new_saved_project(c, PROJ, "fmt")
    imports = []
    for i, (name, imps, written, audio_off) in enumerate(CASES):
        start = 1.0 + i * STEP
        r = S("video.import", {"path": os.path.join(FX, name), "start": start, "lane": i})
        imports.append((name, imps, written, audio_off, start, r))
    S("wait_idle", {"timeout_ms": 10000})
    rows = objects(c); flat = state_flat(c)

    for name, imps, written, audio_off, start, r in imports:
        t0 = r["audio_tracks"][0]
        if written is not None:
            check("%s: audio written as %s (format kept)" % (name, written), t0["written"] == written, "%s (reason %s)" % (t0["written"], t0["fallback_reason"]))
        else:
            print("info  %s: audio written as %s, fallback_reason=%s" % (name, t0["written"], t0["fallback_reason"]))
        # the clip carries the track's own start inside the movie
        aid = r["audio_ids"][0]
        clip_start = flat[aid]["startTime"]
        # A late track is either padded with silence (clip at the group's start) or kept with its own start:
        # both are right as long as the click lands (below). The geometry is reported.
        check("%s: first audio clip starts at the group start (padded) or at its own start +%.1f" % (name, audio_off),
              abs(clip_start - start) < 1e-6 or abs(clip_start - (start + audio_off)) < 1e-6, "%s vs %s / %s" % (clip_start, start, start + audio_off))
        print("info  %s: audio clip at %+.3f s from the group start, written=%s, reason=%s" % (name, clip_start - start, t0["written"], t0["fallback_reason"]))
        # depth of the file on disk
        f = os.path.join(PROJ, flat[aid]["kind"]["filePath"]) if not flat[aid]["kind"]["filePath"].startswith("/") else flat[aid]["kind"]["filePath"]
        if f.endswith(".wav"):
            tag, ch, sr, bits = wav_header(f)
            exp_bits = {"wav16": 16, "wav24": 24, "wav32f": 32}.get(t0["written"])
            check("%s: extracted WAV has depth %s bits (tag %s)" % (name, exp_bits, tag), bits == exp_bits and (tag == 3) == (t0["written"] == "wav32f"), "bits %s tag %s" % (bits, tag))

    # two enabled tracks come in audible; a DISABLED track comes in MUTED (and is heard once unmuted).
    r_multi = [x for x in imports if x[0] == "multi.mov"][0][5]
    check("multi.mov: both enabled tracks audible", [t["muted"] for t in r_multi["audio_tracks"]] == [False, False], str([t["muted"] for t in r_multi["audio_tracks"]]))
    r_dis = [x for x in imports if x[0] == "disabled.mov"][0][5]
    check("disabled.mov: track 1 audible, the disabled track 2 comes in muted", [t["muted"] for t in r_dis["audio_tracks"]] == [False, True], str([t["muted"] for t in r_dis["audio_tracks"]]))
    start_dis = [x for x in imports if x[0] == "disabled.mov"][0][4]
    x0 = export_mix(c, os.path.join(SCRATCH, "audio_format_mix0.wav"), start=start_dis, end=start_dis + 9)
    heard = [i for i, _ in impulses(x0)]
    check("disabled.mov: only ONE click is heard while the disabled track is muted", len(heard) == 1, str(heard))
    S("object.set_mute", {"ids": [r_dis["audio_ids"][1]], "muted": False})
    S("wait_idle", {"timeout_ms": 5000})

    total_len = 1.0 + len(CASES) * STEP + 2
    x = export_mix(c, os.path.join(SCRATCH, "audio_format_mix.wav"), start=0.0, end=total_len)
    found = impulses(x)
    print("info  %d clicks found in the mix: %s" % (len(found), [i for i, _ in found]))
    expected = []
    for name, imps, written, audio_off, start, r in imports:
        if name == "disabled.mov":
            imps = [2.0, 5.0]
        for t in imps:
            expected.append((name, int(round((start + t) * SR)), t))
    check("the mix holds exactly the expected number of clicks (%d)" % len(expected), len(found) == len(expected), "%d found" % len(found))
    got = [i for i, _ in found]
    for name, exp, t in expected:
        near = min(got, key=lambda g: abs(g - exp)) if got else None
        gap = (near - exp) if near is not None else None
        tol = 1 if name == "sr44.mov" else 0
        check("%s: click at movie %.1f s lands %d sample(s) from the expected position (tolerance %d)" % (name, t, gap if gap is not None else -999999, tol),
              gap is not None and abs(gap) <= tol, "gap=%s at %s expected %s" % (gap, near, exp))
        if near is not None:
            pk = dict(found)[near]
            check("%s: click at %.1f s is loud (peak %.2f > 0.3)" % (name, t, pk), pk > 0.3)

sys.exit(K.finish())

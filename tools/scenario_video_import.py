#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Video import (plan-video §8 V1, §9.3) — a group is laid down atomically, in ONE undo.

    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --socket=/tmp/v.sock
    ./scenario_video_import.py /tmp/v.sock /path/to/scratch   # the scratch folder holds the fixtures and projects

What it asserts (the plan's table, row `scenario_video_import.py`):
  * a group appears: one picture child (no sound), N audio children, window = the file's duration;
  * a video without sound lands as the picture ALONE (no group);
  * ONE undo takes it all away, redo gives the same ids back, and the earlier work is untouched;
  * an unsaved project REFUSES, and nothing is created;
  * a cancelled extraction leaves no object and no partial file;
  * a tab switch is refused while the extraction runs.
The last two depend on catching the extraction while it runs (a 150 s PCM file takes seconds); when the
race is lost the scenario SAYS the case was not exercised instead of passing it.

Exit: 0 if every assertion passes, 1 otherwise.
"""
import os, sys, threading, time
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from video_scenario_common import *  # noqa

if len(sys.argv) < 3:
    print(__doc__); sys.exit(2)
SOCK, SCRATCH = sys.argv[1], sys.argv[2]
FX = make_fixtures(os.path.join(SCRATCH, "fx"))
K = Checker(); check = K.check
PROJ = os.path.join(SCRATCH, "import_proj")
BIP = os.path.join(HERE, "fixtures", "bip.wav")

def near(a, b, e=1e-6): return abs(a - b) < e

with ObjekatClient(SOCK) as c:
    S = c.send
    S("app.info")
    # ------------------------------------------------------------------ unsaved project: refused
    S("project.new")
    try:
        S("video.import", {"path": os.path.join(FX, "aac_mp4.mp4")}); refused = None
    except ObjekatError as e:
        refused = e
    check("unsaved project: import refused (invalid_state / needs_save)",
          refused is not None and refused.code == "invalid_state" and (refused.details or {}).get("reason") == "needs_save",
          str(refused))
    check("unsaved project: nothing created", S("app.info")["object_count"] == 0 and not S("app.info")["dirty"])
    try:
        S("edit.undo"); left = True
    except ObjekatError as e:
        left = not (e.code == "invalid_state")
    check("unsaved project: the refused import left no undo point (edit.undo = nothing to undo)", not left)

    # ------------------------------------------------------------------ saved project, a first piece of work
    new_saved_project(c, PROJ, "imp")
    S("object.add", {"path": BIP, "lane": 3, "start": 0.5})
    S("wait_idle", {"timeout_ms": 5000})
    n_before = S("app.info")["object_count"]

    # ------------------------------------------------------------------ the import itself (AAC / MP4)
    r = S("video.import", {"path": os.path.join(FX, "aac_mp4.mp4"), "start": 2.0, "lane": 0})
    S("wait_idle", {"timeout_ms": 5000})
    check("import returns a group", r["group"] is True)
    rows = objects(c); flat = state_flat(c)
    g = rows[r["id"]]
    kids = children_of(rows, r["id"])
    check("group window = the file's duration (10 s)", near(g["duration"], 10.0) and near(r["duration"], 10.0), str(g["duration"]))
    check("group starts where it was dropped (2.0 s)", near(g["start"], 2.0), str(g["start"]))
    pics = [k for k in kids if flat[k["id"]].get("video")]
    auds = [k for k in kids if not flat[k["id"]].get("video")]
    check("exactly one picture child and one audio child", len(pics) == 1 and len(auds) == 1, "%d/%d" % (len(pics), len(auds)))
    check("picture child id = picture_id; audio ids returned", pics and pics[0]["id"] == r["picture_id"] and r["audio_ids"] == [auds[0]["id"]])
    if pics:
        p = flat[pics[0]["id"]]
        check("picture child spans the picture (start 2.0, duration 10)", near(p["startTime"], 2.0) and near(p["duration"], 10.0), "%s %s" % (p.get("startTime"), p["duration"]))
        check("picture child carries fps 24 and 320x180", p["video"]["nominalFPS"] == 24 and p["video"]["pixelSize"] == {"width": 320, "height": 180}, str(p["video"]))
        check("picture child references the ORIGINAL file (not copied)", p["kind"]["filePath"].endswith("/fx/aac_mp4.mp4"), p["kind"]["filePath"])
    if auds:
        a = flat[auds[0]["id"]]
        check("audio child starts with the picture (2.0) and lasts 10 s", near(a["startTime"], 2.0) and near(a["duration"], 10.0), "%s %s" % (a.get("startTime"), a["duration"]))
        check("audio child lives in the project's samples/video/", a["kind"]["filePath"].startswith("samples/video/") and a["kind"]["filePath"].endswith(".m4a"), a["kind"]["filePath"])
        check("AAC kept, no re-encode (written=kept)", r["audio_tracks"][0]["written"] == "kept", str(r["audio_tracks"]))
    check("the original MP4 was not copied into samples/", not any(f.endswith(".mp4") for d, _, fs in os.walk(os.path.join(PROJ, "samples")) for f in fs))

    # ------------------------------------------------------------------ ONE undo, undo/redo complete
    ids_before = set(rows)
    S("edit.undo")
    S("wait_idle", {"timeout_ms": 5000})
    rows_u = objects(c)
    check("one undo removes the whole group (and only it)", S("app.info")["object_count"] == n_before and r["id"] not in rows_u and r["picture_id"] not in rows_u and r["audio_ids"][0] not in rows_u,
          "count %s vs %s" % (S("app.info")["object_count"], n_before))
    check("the earlier work (bip.wav) is still there after that single undo", any(o["name"] == "bip.wav" for o in rows_u.values()))
    check("video.layers sees no picture after the undo", S("video.layers", {"t": 3.0})["pictures"] == 0)
    S("edit.redo")
    S("wait_idle", {"timeout_ms": 5000})
    rows_r = objects(c); flat_r = state_flat(c)
    check("one redo gives the group back with the SAME ids (group, picture, audio)", {r["id"], r["picture_id"], r["audio_ids"][0]} <= set(rows_r))
    check("redo restores the picture's video facet and the same geometry", flat_r[r["picture_id"]].get("video") is not None and near(rows_r[r["id"]]["start"], 2.0) and near(rows_r[r["id"]]["duration"], 10.0))
    check("video.layers sees the picture again after redo", S("video.layers", {"t": 3.0})["pictures"] == 1)
    S("edit.undo"); S("edit.redo"); S("edit.undo"); S("edit.redo")
    S("wait_idle", {"timeout_ms": 5000})
    check("undo/redo twice more: still one group, count stable", S("app.info")["object_count"] == len(objects(c)) and r["id"] in objects(c))

    # ------------------------------------------------------------------ two audio tracks
    r2 = S("video.import", {"path": os.path.join(FX, "multi.mov"), "start": 30.0, "lane": 5})
    rows2 = objects(c); flat2 = state_flat(c)
    kids2 = children_of(rows2, r2["id"])
    check("2-track MOV: one picture + two audio children", len([k for k in kids2 if flat2[k["id"]].get("video")]) == 1 and len(r2["audio_ids"]) == 2, str(len(kids2)))
    check("2-track MOV: tracks reported with their codec / written / muted flag", len(r2["audio_tracks"]) == 2 and all("written" in t and "muted" in t for t in r2["audio_tracks"]), str(r2["audio_tracks"]))
    S("edit.undo")
    check("2-track MOV: one undo removes all three objects", r2["id"] not in objects(c) and all(i not in objects(c) for i in r2["audio_ids"]))

    # ------------------------------------------------------------------ no sound: the picture alone
    r3 = S("video.import", {"path": os.path.join(FX, "silent.mp4"), "start": 40.0, "lane": 4})
    rows3 = objects(c); flat3 = state_flat(c)
    check("no sound: no group (group=false)", r3["group"] is False)
    check("no sound: no audio ids", r3["audio_ids"] == [])
    check("no sound: id = picture_id and it is a plain top-level clip", r3["id"] == r3["picture_id"] and rows3[r3["id"]]["parent"] is None and rows3[r3["id"]]["kind"] == "clip", str(rows3.get(r3["id"])))
    check("no sound: duration 10 s at 40.0", near(rows3[r3["id"]]["duration"], 10.0) and near(rows3[r3["id"]]["start"], 40.0))
    check("no sound: it carries the video facet", bool(flat3[r3["id"]].get("video")))
    S("edit.undo")
    check("no sound: one undo removes it", r3["id"] not in objects(c))
    S("edit.redo")
    check("no sound: redo brings it back", r3["id"] in objects(c))

    # ------------------------------------------------------------------ reopen: the saved project keeps the group
    S("project.save")
    S("project.new")
    S("project.open", {"path": os.path.join(PROJ, "imp.objekat")})
    S("wait_idle", {"timeout_ms": 10000})
    rows_o = objects(c)
    check("save + reopen: the groups and pictures are back", r["id"] in rows_o and r["picture_id"] in rows_o and r3["id"] in rows_o)
    check("save + reopen: video.layers answers for the reopened picture", S("video.layers", {"t": 3.0})["pictures"] >= 2)

    # ------------------------------------------------------------------ cancellation: nothing left behind
    def samples_files():
        d = os.path.join(PROJ, "samples", "video")
        return sorted(os.listdir(d)) if os.path.isdir(d) else []

    def race(action, label, wait_running=True):
        """Starts a long import on a second connection; once the EXTRACTION is running (the status says so; the
        probe before it takes seconds in a Debug build) calls `action(status)`. Returns (caught, outcome,
        files before, object count before)."""
        files0 = samples_files(); count0 = S("app.info")["object_count"]
        outcome = {}
        def go():
            with ObjekatClient(SOCK) as c2:
                try:
                    outcome["r"] = c2.send("video.import", {"path": os.path.join(FX, "long30.mov"), "start": 100.0, "lane": 8})
                except ObjekatError as e:
                    outcome["e"] = e
        th = threading.Thread(target=go); th.start()
        seen, deadline = False, time.time() + 20
        while th.is_alive() and time.time() < deadline:
            st = S("video.import_status")
            if st["running"] == wait_running:
                seen = True
                outcome["action"] = action(st)
                break
            time.sleep(0.02)
        th.join(timeout=90)
        return seen, outcome, files0, count0

    seen, out, files0, count0 = race(lambda st: S("video.import_cancel"), "cancel")
    if not seen:
        print("NOTE  cancellation race not caught (the import finished before the cancel) — case NOT exercised")
    else:
        e = out.get("e")
        check("cancel: the import answers 'cancelled' (invalid_state)", e is not None and e.code == "invalid_state" and (e.details or {}).get("reason") == "cancelled", str(out))
        S("wait_idle", {"timeout_ms": 5000})
        check("cancel: no object created", S("app.info")["object_count"] == count0, "%s vs %s" % (S("app.info")["object_count"], count0))
        check("cancel: no partial file left in samples/video/", samples_files() == files0, "%s vs %s" % (samples_files(), files0))
        check("cancel: status is idle again", S("video.import_status")["running"] is False)

    def try_tab(st):
        try:
            S("tab.new"); return "accepted"
        except ObjekatError as e:
            return e.code
    seen, out, files0, count0 = race(try_tab, "tab")
    holder = {"tab": out.get("action")}
    if not seen:
        print("NOTE  tab race not caught — case NOT exercised")
    else:
        check("tab.new during the extraction is refused (invalid_state)", holder.get("tab") == "invalid_state", str(holder))
        if "r" in out:
            S("edit.undo")
    S("wait_idle", {"timeout_ms": 5000})
    tl = S("tab.list")
    check("tab count still 1 at the end", S("app.info")["tab_count"] == 1, str(tl)[:200])

sys.exit(K.finish())

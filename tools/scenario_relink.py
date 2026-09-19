#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Missing files and relinking — a scenario that ASSERTS rather than replaying.

Same shape as `scenario_markers.py`, and for the same reason: a JSON-lines scenario
cannot reuse an identifier an earlier command returned, and everything here does.

    # 1. launch the app with the API, on a SHORT socket (a system limit: 103 bytes).
    #    `--no-recent`: the throwaway projects below do not enter "Recent projects".
    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --socket=/tmp/o.sock

    # 2. replay
    ./scenario_relink.py /tmp/o.sock

It makes its own wav files in a temporary folder and MOVES them about on disk under the
app's feet — which is the only honest way to test this: a missing file is a fact of the
file system, not a flag one can set. The folders are removed on the way out, whether the
run passed or not.

What it is really out to prove, beyond the commands answering:

  • the unit of a repair is the PATH — three objects on one take are three objects and ONE
    broken path, and mending it mends all three in one gesture and one undo point;
  • a clip nested in a FOLDED group is scanned, counted and repaired like any other, and the
    group says `missing_descendant` without ever saying `missing` (it owns no file);
  • the PROPAGATION: repairing one path teaches a prefix, `project.relink_preview` says what
    else that prefix would mend WITHOUT touching anything, and `propagate: true` mends the lot
    for one ⌘Z;
  • the CLAMP: a shorter file slides the window back, and cuts its length only when the file is
    shorter than the window itself — never a clip reading past the end of its own file;
  • and the line between the two gestures: `object.replace_source` is deliberate and NEVER
    propagates, even when the pair it is given would have taught a substitution that mends
    something else.

Exit: 0 if every assertion passes, 1 otherwise.
"""

import array, math, os, shutil, sys, tempfile, wave

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

if len(sys.argv) != 2:
    print(__doc__)
    sys.exit(2)

SOCK = sys.argv[1]
RATE = 48000          # every length below is an exact number of frames at this rate

fails = []
roots = []


def check(label, ok, detail=""):
    if ok:
        print("ok    " + label)
    else:
        fails.append(label)
        print("FAIL  %s  %s" % (label, detail))


def approx(a, b, eps=1e-3):
    try:
        return abs(float(a) - float(b)) < eps
    except (TypeError, ValueError):
        return False


def tmproot(tag):
    """A temporary folder, remembered so the `finally` below can take it away again."""
    folder = tempfile.mkdtemp(prefix="objekat-relink-%s-" % tag)
    roots.append(folder)
    return folder


def make_wav(path, seconds, freq=440.0):
    """A mono 16-bit wav of exactly `seconds`. Its CONTENT is beside the point here — what
    matters is that it opens, that its length is readable and that two files can differ in
    length, which is what the clamp is asserted on."""
    folder = os.path.dirname(path)
    if folder:
        os.makedirs(folder, exist_ok=True)
    frames = int(round(seconds * RATE))
    samples = array.array(
        "h", (int(8000 * math.sin(2 * math.pi * freq * i / RATE)) for i in range(frames)))
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(samples.tobytes())
    return path


try:
    with ObjekatClient(SOCK) as c:
        def cmd(_cmd_name, **params):
            return c.send(_cmd_name, params or None)

        def objects():
            return cmd("object.list")["objects"]

        def row(oid):
            for o in objects():
                if o["id"] == oid:
                    return o
            return None

        def refused(label, code, fn):
            """A refusal is a contract too: a script branches on the CODE, never on the message."""
            try:
                fn()
                check(label, False, "it went through")
            except ObjekatError as e:
                check(label, e.code == code, e.code)

        info = cmd("app.info")
        check("--no-recent honoured", info.get("records_recent_projects") is False,
              str(info.get("records_recent_projects")))

        # ── 1. A take that goes: one path, three objects, one of them inside a folded group ──
        # The unit of the repair is the PATH. Three clips on one take are ONE thing to mend, and
        # the figures the API answers with keep the two readings apart throughout: `path_count`
        # is what a repair works in, `object_count` is what a human counts.
        cmd("project.new")
        d1 = tmproot("take")
        take = make_wav(os.path.join(d1, "take.wav"), 0.6)
        moved_take = os.path.join(d1, "take-moved.wav")

        o1 = cmd("object.add", path=take, lane=0, start=0.0)["id"]
        o2 = cmd("object.add", path=take, lane=1, start=2.0)["id"]
        o3 = cmd("object.add", path=take, lane=2, start=4.0)["id"]
        cmd("wait_idle", timeout_ms=5000)
        check("a healthy project has nothing missing",
              cmd("project.rescan_missing")["path_count"] == 0)

        # Grouped BEFORE the file goes, which is the realistic order — and the group is then shut,
        # so the scan has to walk into something the screen is not showing.
        grp = cmd("group.create", ids=[o1, o2])["id"]
        cmd("group.expand", id=grp, expanded=False)

        os.rename(take, moved_take)
        check("missing_files reads the last SCAN and not the disk",
              cmd("project.missing_files")["path_count"] == 0)

        scan = cmd("project.rescan_missing")
        check("the rescan is the one command that asks the disk",
              scan["path_count"] == 1 and scan["object_count"] == 3,
              "%s paths / %s objects" % (scan["path_count"], scan["object_count"]))

        mf = cmd("project.missing_files")
        check("one PATH, three OBJECTS — a folded group hides nothing from the scan",
              mf["path_count"] == 1 and mf["object_count"] == 3
              and mf["files"][0]["object_count"] == 3, str(mf))
        check("the row names the path the session still holds, and why it is gone",
              mf["files"][0]["path"] == take and mf["files"][0]["reason"] == "absent",
              str(mf["files"][0]))

        # A GROUP owns no file, so it is never `missing` — it says `missing_descendant` instead,
        # which is a different statement and deliberately a second field.
        g = cmd("object.get", id=grp)
        check("a group is never missing — it owns no file — but it says something DOWN THERE is",
              g["missing"] is False and g["missing_reason"] is None
              and g["missing_descendant"] is True, str(g))

        cmd("group.expand", id=grp, expanded=True)
        got = cmd("object.get", id=o1)
        check("a clip says it plainly, and has no descendants to worry about",
              got["missing"] is True and got["missing_reason"] == "absent"
              and got["missing_descendant"] is False, str(got.get("missing_reason")))
        check("object.list carries the same verdict, for every object on that path",
              len([o for o in objects() if o.get("missing")]) == 3,
              str([o.get("missing") for o in objects()]))

        # Renaming a FILE teaches nothing generalisable: the substitution would be the whole path
        # against the whole path, which is a rule matching one thing.
        pv = cmd("project.relink_preview", **{"from": take, "to": moved_take})
        check("a renamed file teaches no prefix",
              pv["substitution"] is None and pv["path_count"] == 0, str(pv))

        rp = cmd("project.relink_path", **{"from": take, "to": moved_take})
        check("one repair, three objects mended, and no prefix learned",
              rp["objects"] == 3 and rp["paths"] == 1 and rp["substitution"] is None, str(rp))
        check("nothing is missing any more, and missing_files agrees with no second scan",
              rp["missing_paths"] == 0 and rp["missing_objects"] == 0
              and cmd("project.missing_files")["path_count"] == 0, str(rp))

        got = cmd("object.get", id=o1)
        check("the clip reads the new file, with a coherent file_duration, and is no longer red",
              got["file"] == moved_take and approx(got["file_duration"], 0.6)
              and got["missing"] is False,
              "%s / %s" % (got["file"], got["file_duration"]))
        check("the group stops warning too",
              cmd("object.get", id=grp)["missing_descendant"] is False)

        # ── 2. Propagation: two files under one root, one repaired by hand ────────────────
        # Accidents come by packets. Repairing `<root>/orig/A/one.wav` onto `<root>/moved/A/one.wav`
        # teaches `<root>/orig` → `<root>/moved`, and that prefix is what is offered for the rest.
        cmd("project.new")
        d2 = tmproot("prop")
        one_old = make_wav(os.path.join(d2, "orig", "A", "one.wav"), 0.5)
        two_old = make_wav(os.path.join(d2, "orig", "B", "two.wav"), 0.9)
        p1 = cmd("object.add", path=one_old, lane=0, start=0.0)["id"]
        p2 = cmd("object.add", path=two_old, lane=1, start=2.0)["id"]
        cmd("wait_idle", timeout_ms=5000)

        os.rename(os.path.join(d2, "orig"), os.path.join(d2, "moved"))
        one_new = os.path.join(d2, "moved", "A", "one.wav")
        two_new = os.path.join(d2, "moved", "B", "two.wav")
        scan = cmd("project.rescan_missing")
        check("one move, two broken paths",
              scan["path_count"] == 2 and scan["object_count"] == 2, str(scan))

        pv = cmd("project.relink_preview", **{"from": one_old, "to": one_new})
        check("the pair teaches the ROOT and not the whole path",
              pv["substitution"] == {"from": os.path.join(d2, "orig"),
                                     "to": os.path.join(d2, "moved")}, str(pv["substitution"]))
        check("and the preview names the OTHER file it would mend",
              pv["path_count"] == 1 and pv["object_count"] == 1
              and pv["resolves"][0]["path"] == two_old
              and pv["resolves"][0]["new_path"] == two_new
              and pv["resolves"][0]["object_count"] == 1, str(pv["resolves"]))
        check("a preview changes NOTHING — neither a path nor an object",
              cmd("project.missing_files")["path_count"] == 2
              and len([o for o in objects() if o.get("missing")]) == 2)

        # Without propagation: one path mended, the substitution still reported — it is what the
        # modal offers, and a caller has to be able to read it before deciding.
        rp = cmd("project.relink_path", **{"from": one_old, "to": one_new})
        check("without propagate only the path asked for is mended, the substitution reported all the same",
              rp["objects"] == 1 and rp["paths"] == 1 and rp["missing_paths"] == 1
              and rp["substitution"] == pv["substitution"], str(rp))

        cmd("edit.undo")
        check("⌘Z puts the broken path back into the model",
              row(p1)["file"] == one_old, row(p1)["file"])
        # The scan does NOT follow an undo on its own: `missingPaths` is a reading of the disk, and
        # only `project.rescan_missing` (or opening a project, or a volume moving) takes it again.
        scan = cmd("project.rescan_missing")
        check("and the rescan finds the two of them again", scan["path_count"] == 2, str(scan))

        rp = cmd("project.relink_path", **{"from": one_old, "to": one_new}, propagate=True)
        check("propagate mends BOTH paths and leaves nothing behind",
              rp["objects"] == 2 and rp["paths"] == 2
              and rp["missing_paths"] == 0 and rp["missing_objects"] == 0, str(rp))
        check("the object nobody pointed at reads the new root",
              row(p2)["file"] == two_new, row(p2)["file"])
        check("each with its own length",
              approx(cmd("object.get", id=p1)["file_duration"], 0.5)
              and approx(cmd("object.get", id=p2)["file_duration"], 0.9))

        # ONE undo for a propagated repair — this is the assertion the whole propagation rests on.
        cmd("edit.undo")
        check("one single ⌘Z undoes the propagated repair, both paths at once",
              row(p1)["file"] == one_old and row(p2)["file"] == two_old,
              "%s / %s" % (row(p1)["file"], row(p2)["file"]))
        check("it undid the repair only — the two objects are still there, and both broken again",
              len(objects()) == 2 and cmd("project.rescan_missing")["path_count"] == 2)

        # ── 3. Sweeping a folder ─────────────────────────────────────────────────────────
        cmd("project.new")
        d3 = tmproot("folder")
        kick = make_wav(os.path.join(d3, "src", "kick.wav"), 0.3)
        snare = make_wav(os.path.join(d3, "src", "snare.wav"), 0.45)
        empty = os.path.join(d3, "empty")
        os.makedirs(empty, exist_ok=True)
        f1 = cmd("object.add", path=kick, lane=0, start=0.0)["id"]
        f2 = cmd("object.add", path=snare, lane=1, start=1.0)["id"]
        cmd("wait_idle", timeout_ms=5000)

        os.rename(os.path.join(d3, "src"), os.path.join(d3, "dst"))
        check("two takes gone", cmd("project.rescan_missing")["path_count"] == 2)

        rf = cmd("project.relink_folder", folder=empty)
        check("finding nothing is an ANSWER, not an error",
              rf["objects"] == 0 and rf["paths"] == 0 and rf["missing_paths"] == 2, str(rf))

        rf = cmd("project.relink_folder", folder=os.path.join(d3, "dst"))
        check("a sweep mends by NAME, every path it finds, and leaves nothing missing",
              rf["objects"] == 2 and rf["paths"] == 2
              and rf["missing_paths"] == 0 and rf["missing_objects"] == 0, str(rf))
        check("each object landed on the file carrying ITS name",
              row(f1)["file"] == os.path.join(d3, "dst", "kick.wav")
              and row(f2)["file"] == os.path.join(d3, "dst", "snare.wav"),
              "%s / %s" % (row(f1)["file"], row(f2)["file"]))

        cmd("edit.undo")
        check("a whole sweep is one undo point too",
              row(f1)["file"] == kick and row(f2)["file"] == snare)

        # ── 4. The deliberate gesture never propagates ───────────────────────────────────
        # `object.replace_source` is "I have re-edited that sound outside". Here the pair it is
        # given WOULD teach a substitution that mends the other broken path — the preview says so
        # out loud first — and it must mend it all the same: nothing but the object aimed at moves.
        cmd("project.new")
        d4 = tmproot("replace")
        here_one = make_wav(os.path.join(d4, "here", "A", "one.wav"), 0.5)
        here_two = make_wav(os.path.join(d4, "here", "B", "two.wav"), 0.9)
        # The copies under `there` are LONGER than the originals, so that "nothing was clamped"
        # below is asserted away from the exact boundary: a window and a file of the same length
        # sit on the `>` of `fittedWindow`, where a float's last bit would decide the answer.
        there_one = make_wav(os.path.join(d4, "there", "A", "one.wav"), 1.2)
        there_two = make_wav(os.path.join(d4, "there", "B", "two.wav"), 1.1)
        q1 = cmd("object.add", path=here_one, lane=0, start=0.0)["id"]
        q2 = cmd("object.add", path=here_two, lane=1, start=2.0)["id"]
        cmd("wait_idle", timeout_ms=5000)

        os.remove(here_two)
        check("one of the two is gone", cmd("project.rescan_missing")["path_count"] == 1)
        pv = cmd("project.relink_preview", **{"from": here_one, "to": there_one})
        check("and the pair about to be used WOULD have propagated onto it",
              pv["path_count"] == 1 and pv["resolves"][0]["path"] == here_two, str(pv))

        rs = cmd("object.replace_source", id=q1, path=there_one)
        check("the object aimed at changed file, and a file long enough clamps nothing",
              rs["file"] == there_one and rs["missing"] is False
              and rs["clamped"] is False and approx(rs["duration"], 0.5)
              and approx(rs["source_offset"], 0.0), str(rs))
        mf = cmd("project.missing_files")
        check("and NOTHING else moved: the deliberate gesture does not propagate",
              mf["path_count"] == 1 and mf["files"][0]["path"] == here_two
              and row(q2)["missing"] is True, str(mf))

        cmd("project.relink_path", **{"from": here_two, "to": there_two})
        check("mended by hand, as a repair and not as a replacement",
              cmd("project.missing_files")["path_count"] == 0)

        # ── 5. The clamp: a shorter file never reads past its own end ────────────────────
        # Two steps, in this order: the window SLIDES BACK as far as it must, and only if the file
        # is shorter than the window ITSELF is the length cut (@see EditViewModel.fittedWindow).
        cmd("project.new")
        d5 = tmproot("clamp")
        long_a = make_wav(os.path.join(d5, "long-a.wav"), 4.0)
        long_b = make_wav(os.path.join(d5, "long-b.wav"), 4.0, freq=330.0)
        short = make_wav(os.path.join(d5, "short.wav"), 1.0)

        sl = cmd("object.add", path=long_a, lane=0, start=0.0, duration=0.5)["id"]
        cmd("object.set_source_offset", id=sl, offset=3.0)
        cmd("wait_idle", timeout_ms=5000)
        check("the window sits at the far end of a 4 s file",
              approx(cmd("object.get", id=sl)["source_offset"], 3.0))
        rs = cmd("object.replace_source", id=sl, path=short)
        check("a shorter file SLIDES the window back rather than reading emptiness — and keeps "
              "the length that was chosen",
              rs["clamped"] is True and approx(rs["source_offset"], 0.5)
              and approx(rs["duration"], 0.5)
              and approx(cmd("object.get", id=sl)["duration"], 0.5), str(rs))

        cut = cmd("object.add", path=long_a, lane=1, start=5.0, duration=2.0)["id"]
        cmd("wait_idle", timeout_ms=5000)
        rs = cmd("object.replace_source", id=cut, path=short)
        check("a file shorter than the WINDOW cuts the length, from the very beginning",
              rs["clamped"] is True and approx(rs["source_offset"], 0.0)
              and approx(rs["duration"], 1.0) and approx(rs["file_duration"], 1.0), str(rs))

        same = cmd("object.add", path=long_a, lane=2, start=10.0, duration=0.5)["id"]
        cmd("wait_idle", timeout_ms=5000)
        rs = cmd("object.replace_source", id=same, path=long_b)
        check("a file long enough clamps nothing at all",
              rs["clamped"] is False and approx(rs["duration"], 0.5)
              and approx(rs["source_offset"], 0.0), str(rs))

        # ── 6. The refusals — a script branches on the code ──────────────────────────────
        refused("replacing a file by itself is refused", "invalid_state",
                lambda: cmd("object.replace_source", id=same, path=long_b))
        refused("a file that is not there is refused", "not_found",
                lambda: cmd("object.replace_source", id=same,
                            path=os.path.join(d5, "nowhere.wav")))
        gid = cmd("group.create", ids=[sl, cut])["id"]
        refused("a GROUP has no source to replace", "not_found",
                lambda: cmd("object.replace_source", id=gid, path=short))
        refused("relinking a path nobody reads is refused", "not_found",
                lambda: cmd("project.relink_path", **{"from": os.path.join(d5, "ghost.wav"),
                                                      "to": short}))
        refused("relinking ONTO a file that is not there is refused", "not_found",
                lambda: cmd("project.relink_path", **{"from": long_a,
                                                      "to": os.path.join(d5, "nowhere.wav")}))
        refused("sweeping a folder that is not there is refused", "not_found",
                lambda: cmd("project.relink_folder", folder=os.path.join(d5, "no-folder")))

        # The app must not be left holding the temporary files while they are taken away.
        cmd("project.new")

finally:
    for folder in roots:
        shutil.rmtree(folder, ignore_errors=True)

print("\nALL PASS" if not fails else "\n%d FAILURE(S): %s" % (len(fails), ", ".join(fails)))
sys.exit(0 if not fails else 1)

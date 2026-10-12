#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Importing a FOLDER as a group, hierarchy kept — `object.import_folder`, asserted headless.

The timeline's drop of a folder and this command lay down through ONE function
(`EditViewModel.placeDropEntries`); the drag itself needs a screen, the result does not.

    # 1. launch the app with the API (WITH audio: the export at the end is re-read at RMS),
    #    on a SHORT socket (a system limit: 103 bytes). `--no-recent`: nothing enters "Recent".
    objekat.app/Contents/MacOS/objekat --headless --api --no-recent --socket=/tmp/o.sock

    # 2. replay
    ./scenario_import_folder.py /tmp/o.sock

It builds a real folder tree in a temporary directory (audio files of KNOWN lengths, a text file,
an empty folder, a hidden folder), imports it, and asserts:

  • the STRUCTURE: one folded group named after the folder; one lane per file, then per sub-folder
    (each a folded sub-group), recursively; nothing for the text file, the empty folder or the
    hidden folder; lanes compact, start shared (stacked) or end to end on one lane (sequential);
  • the BOUNDS: a group lasts the union of what it holds, never an infinite extent — heard, not
    just read: an export of the window after the group is silent;
  • ONE undo point for the whole import (and one redo);
  • the project saved and reopened gives the same tree;
  • an import INTO an open group nests the new group in it, on that group's stem;
  • the refusals (`not_found`, `bad_params`, `invalid_state`) and the two bounds (8 levels deep are
    read and the rest counted; more than 2000 files refuse the whole import);
  • no confirmation is ever asked of a script, even for more than 200 files.

Exit: 0 if every assertion passes, 1 otherwise.
"""

import array, json, math, os, shutil, sys, tempfile, time, wave

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

if len(sys.argv) != 2:
    print(__doc__)
    sys.exit(2)

SOCK = sys.argv[1]
RATE = 48000

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
    folder = tempfile.mkdtemp(prefix="objekat-impfolder-%s-" % tag)
    roots.append(folder)
    return os.path.realpath(folder)   # /var is a symlink to /private/var on macOS


def make_wav(path, seconds, freq=440.0, amp=8000):
    folder = os.path.dirname(path)
    if folder:
        os.makedirs(folder, exist_ok=True)
    frames = int(round(seconds * RATE))
    samples = array.array("h", (int(amp * math.sin(2 * math.pi * freq * i / RATE)) for i in range(frames)))
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(samples.tobytes())
    return path


def wav_rms(path):
    with wave.open(path, "rb") as w:
        width, raw = w.getsampwidth(), w.readframes(w.getnframes())
    if width == 2:
        vals, scale = array.array("h", raw), 32768.0
    elif width == 3:
        vals = [int.from_bytes(raw[i:i + 3], "little", signed=True) for i in range(0, len(raw) - 2, 3)]
        scale = 8388608.0
    else:
        raise RuntimeError("unexpected sample width: %d" % width)
    n = len(vals)
    return math.sqrt(sum((v / scale) ** 2 for v in vals) / n) if n else 0.0


def shape(t):
    """A tree of the command's answer reduced to (name, kind, [children]) — what structure means."""
    return (t["name"], t["kind"], [shape(c) for c in t.get("children", [])])


def walk(t):
    yield t
    for c in t.get("children", []):
        for x in walk(c):
            yield x


try:
    with ObjekatClient(SOCK) as c:
        def cmd(_cmd_name, **params):
            return c.send(_cmd_name, params or None)

        def objects():
            return cmd("object.list")["objects"]

        def refused(label, code, fn):
            try:
                fn()
                check(label, False, "it went through")
            except ObjekatError as e:
                check(label, e.code == code, "%s: %s" % (e.code, e))

        info = cmd("app.info")
        check("--no-recent honoured", info.get("records_recent_projects") is False)

        # ── The fixture: a tree with known lengths ──
        base = tmproot("kit")
        kit = os.path.join(base, "kit")
        make_wav(os.path.join(kit, "a.wav"), 1.0, 440)
        make_wav(os.path.join(kit, "b.wav"), 2.0, 550)
        make_wav(os.path.join(kit, "room", "r1.wav"), 0.5, 660)
        make_wav(os.path.join(kit, "room", "r2.wav"), 1.5, 770)
        make_wav(os.path.join(kit, "close", "c1.wav"), 1.0, 330)
        make_wav(os.path.join(kit, "close", "deep", "d1.wav"), 3.0, 880)
        os.makedirs(os.path.join(kit, "docs"))
        with open(os.path.join(kit, "docs", "readme.txt"), "w") as fh:
            fh.write("not audio")
        with open(os.path.join(kit, "notes.txt"), "w") as fh:
            fh.write("not audio either")
        os.makedirs(os.path.join(kit, "empty"))
        make_wav(os.path.join(kit, ".hidden", "ghost.wav"), 1.0)
        make_wav(os.path.join(kit, ".dotfile.wav"), 1.0)

        EXPECTED = ("kit", "group", [
            ("a.wav", "clip", []),
            ("b.wav", "clip", []),
            ("close", "group", [("c1.wav", "clip", []),
                                ("deep", "group", [("d1.wav", "clip", [])])]),
            ("room", "group", [("r1.wav", "clip", []), ("r2.wav", "clip", [])]),
        ])

        # ── 1. Stacked (the default) ──
        cmd("project.new")
        res = cmd("object.import_folder", path=kit, lane=2, start=5.0)
        tree = res["tree"]
        check("1. the structure: folder → group, files then sub-folders, junk left out",
              shape(tree) == EXPECTED, json.dumps(shape(tree)))
        check("1. the answer counts the 6 audio files (and omitted nothing)",
              res["files"] == 6 and res["omitted_deep_folders"] == 0 and res["mode"] == "stacked", str(res))
        check("1. the group starts at the drop and lasts the union (the 3 s file)",
              approx(res["start"], 5.0) and approx(res["duration"], 3.0), "%s %s" % (res["start"], res["duration"]))
        check("1. it lands on the lane asked", res["lane"] == 2 and res["parent"] is None, str(res["lane"]))
        nodes = list(walk(tree))
        check("1. every group is folded", all(n.get("expanded") is False for n in nodes if n["kind"] == "group"))
        check("1. stacked: everything starts together",
              all(approx(n["start"], 5.0) for n in nodes), str([n["start"] for n in nodes]))
        check("1. lanes: one per entry, relative to the group that holds them",
              [c_["lane"] for c_ in tree["children"]] == [0, 1, 2, 3]
              and [c_["lane"] for c_ in tree["children"][2]["children"]] == [0, 1]
              and [c_["lane"] for c_ in tree["children"][3]["children"]] == [0, 1])
        durs = {n["name"]: n["duration"] for n in nodes}
        check("1. a group lasts the union of its children",
              approx(durs["close"], 3.0) and approx(durs["deep"], 3.0) and approx(durs["room"], 1.5),
              str(durs))
        check("1. clips keep their own length",
              approx(durs["a.wav"], 1.0) and approx(durs["b.wav"], 2.0) and approx(durs["r1.wav"], 0.5), str(durs))
        check("1. folded: the lanes show ONE object, the group, named after the folder",
              [(o["kind"], o["name"], o["parent"]) for o in objects()] == [("group", "kit", None)],
              str([(o["kind"], o["name"]) for o in objects()]))

        def expand_all(t):
            """Opens every group of the tree, so that object.list shows what the model holds."""
            for n in walk(t):
                if n["kind"] == "group":
                    cmd("group.expand", id=n["id"], expanded=True)
        expand_all(tree)
        listed = {o["id"]: o for o in objects()}
        check("1. opened, object.list shows all 10 objects, each pointing at its parent",
              len(listed) == 10 and all(n["id"] in listed for n in nodes)
              and all(listed[k["id"]]["parent"] == n["id"] for n in nodes for k in n.get("children", [])),
              str(len(listed)))
        check("1. clips know their file",
              listed[tree["children"][0]["id"]].get("file") == os.path.join(kit, "a.wav"))

        first_id = tree["id"]
        undone = cmd("edit.undo")
        check("1. ONE undo removes the whole import", objects() == [] and undone["can_undo"] is False,
              str(len(objects())))
        redone = cmd("edit.redo")
        expand_all(tree)
        again = {o["id"] for o in objects()}
        check("1. ONE redo brings it all back (same ids)",
              first_id in again and all(n["id"] in again for n in nodes) and redone["can_redo"] is False,
              "%d of %d" % (len([n for n in nodes if n["id"] in again]), len(nodes)))

        # ── 2. Sequential (⌘) ──
        cmd("project.new")
        res = cmd("object.import_folder", path=kit, lane=0, start=0.0, mode="sequential")
        tree = res["tree"]
        check("2. sequential: same structure", shape(tree) == EXPECTED)
        kids = tree["children"]
        check("2. sequential: one lane for every entry of a level", all(k["lane"] == 0 for k in kids))
        check("2. sequential: each starts where the previous ends (0, 1, 3, 7)",
              [round(k["start"], 3) for k in kids] == [0.0, 1.0, 3.0, 7.0], str([k["start"] for k in kids]))
        check("2. sequential: a sub-folder is laid end to end too (c1 at 3, deep at 4)",
              [round(k["start"], 3) for k in kids[2]["children"]] == [3.0, 4.0]
              and all(k["lane"] == 0 for k in kids[2]["children"]))
        check("2. sequential: the group lasts the sum (1 + 2 + 4 + 2 = 9)",
              approx(res["duration"], 9.0) and res["mode"] == "sequential", str(res["duration"]))
        seq_id = tree["id"]

        # ── 3. Saved and reopened: the same tree ──
        # (Stacked: every group can be opened at once. In the end-to-end layout a level's entries
        # share ONE lane, and a lane opens a single band at a time — the display's own rule.)
        cmd("project.new")
        tree = cmd("object.import_folder", path=kit, lane=0, start=0.0)["tree"]
        proj = os.path.join(tmproot("proj"), "p", "import.objekat")
        os.makedirs(os.path.dirname(proj), exist_ok=True)
        cmd("project.save_as", path=proj)

        def digest():
            return sorted((o["id"], o["kind"], o["name"], o["lane"], round(o["start"], 4),
                           round(o["duration"], 4), o["parent"], o["expanded_span"])
                          for o in objects())
        expand_all(tree)
        before = digest()
        cmd("project.save")
        cmd("project.open", path=proj)
        cmd("wait_idle", timeout_ms=10000)
        expand_all(tree)
        after = digest()
        check("3. save / reopen: the same objects, the same positions, the same nesting",
              before == after and len(after) == 10,
              "%d vs %d; only before: %s; only after: %s" % (
                  len(before), len(after), [b for b in before if b not in after][:3],
                  [a for a in after if a not in before][:3]))

        # ── 4. Heard, not just read ──
        out_dir = tmproot("render")

        def render(tag, start, end):
            out = os.path.join(out_dir, "r-%s.wav" % tag)
            job = cmd("export.run", format="wav", sample_rate=48000, dithering=False,
                      start=start, end=end, path=out)["job_id"]
            done = cmd("job.wait", id=job, timeout_ms=60000)
            if not os.path.exists(out):
                raise RuntimeError("export failed: %s" % json.dumps(done))
            return wav_rms(out)

        cmd("project.new")
        cmd("object.import_folder", path=kit, lane=0, start=0.0, mode="sequential")
        # sequential layout: a 0-1, b 1-3, c1 3-4, d1 4-7, r1 7-7.5, r2 7.5-9
        check("4. sequential: the first second sounds (file a)", render("s_a", 0.0, 1.0) > 0.05)
        check("4. sequential: the deep file sounds where the plan put it (4-5 s)", render("s_d", 4.0, 5.0) > 0.05)
        silence = render("s_after", 9.3, 10.3)
        check("4. sequential: after the group there is nothing (it ends at 9 s)", silence < 1e-4, "rms %s" % silence)

        cmd("project.new")
        cmd("object.import_folder", path=kit, lane=0, start=0.0)
        check("4. stacked: it sounds from the start", render("k_start", 0.0, 1.0) > 0.05)
        silence = render("k_after", 3.4, 4.4)
        check("4. stacked: after the 3 s union there is nothing (no infinite extent)",
              silence < 1e-4, "rms %s" % silence)

        # ── 5. Into an open group, and onto its stem ──
        kit_id = [o["id"] for o in objects() if o["kind"] == "group" and o["name"] == "kit"][0]
        stem = cmd("stem.add", name="Imports")["id"]
        cmd("stem.assign", stem=stem, ids=[kit_id])
        cmd("group.expand", id=kit_id, expanded=True)
        rows = {o["id"]: o for o in objects()}
        a_id = [o["id"] for o in objects() if o["name"] == "a.wav" and o["parent"] == kit_id][0]
        target_lane = rows[a_id]["display_lane"]
        solo = os.path.join(tmproot("solo"), "solo")
        make_wav(os.path.join(solo, "s.wav"), 0.8, 500)
        res = cmd("object.import_folder", path=solo, lane=target_lane, start=1.2)
        check("5. a folder with ONE file still yields a group",
              res["tree"]["kind"] == "group" and res["tree"]["name"] == "solo"
              and res["files"] == 1 and len(res["tree"]["children"]) == 1, str(res["tree"]))
        check("5. dropped on an open group's band, it nests in that group",
              res["parent"] == kit_id and approx(res["start"], 1.2), str(res["parent"]))
        cmd("group.expand", id=res["id"], expanded=True)
        rows = {o["id"]: o for o in objects()}
        check("5. …and follows the group's stem (the group and its clip alike)",
              rows[res["id"]].get("stem") == stem
              and rows[res["tree"]["children"][0]["id"]].get("stem") == stem,
              str((rows[res["id"]].get("stem"), stem)))
        cmd("edit.undo")
        rows = {o["id"] for o in objects()}
        check("5. one undo takes only that import out", res["id"] not in rows and kit_id in rows)

        # ── 6. Refusals ──
        cmd("project.new")
        refused("6. a folder that does not exist: not_found", "not_found",
                lambda: cmd("object.import_folder", path=os.path.join(base, "nowhere")))
        refused("6. a FILE is not a folder: bad_params", "bad_params",
                lambda: cmd("object.import_folder", path=os.path.join(kit, "a.wav")))
        refused("6. an unknown mode: bad_params", "bad_params",
                lambda: cmd("object.import_folder", path=kit, mode="diagonal"))
        silent_dir = os.path.join(tmproot("silent"), "silent")
        os.makedirs(os.path.join(silent_dir, "sub"))
        with open(os.path.join(silent_dir, "sub", "x.txt"), "w") as fh:
            fh.write("x")
        refused("6. a folder with no audio at all: invalid_state", "invalid_state",
                lambda: cmd("object.import_folder", path=silent_dir))
        check("6. …and nothing was created", objects() == [])
        refused("6. …nor an undo point left behind by the refusals", "invalid_state",
                lambda: cmd("edit.undo"))

        # ── 7. Order, depth, size ──
        takes = os.path.join(tmproot("takes"), "takes")
        for n in ("take 10", "take 2", "take 1"):
            make_wav(os.path.join(takes, n + ".wav"), 0.1)
        res = cmd("object.import_folder", path=takes)
        check("7. Finder order: take 1, take 2, take 10 (not 1, 10, 2)",
              [k["name"] for k in res["tree"]["children"]] == ["take 1.wav", "take 2.wav", "take 10.wav"],
              str([k["name"] for k in res["tree"]["children"]]))
        cmd("edit.undo")

        deep = tmproot("deep")
        level = os.path.join(deep, "d0")
        for i in range(11):
            make_wav(os.path.join(level, "f%d.wav" % i), 0.1)
            level = os.path.join(level, "d%d" % (i + 1))
        res = cmd("object.import_folder", path=os.path.join(deep, "d0"))

        def depth(t):
            return 1 + max([depth(k) for k in t.get("children", []) if k["kind"] == "group"] or [0])
        check("7. 8 levels below the dropped folder are read (9 nested groups) and the rest counted",
              depth(res["tree"]) == 9 and res["omitted_deep_folders"] == 1 and res["files"] == 9,
              "depth %d, omitted %s, files %s" % (depth(res["tree"]), res["omitted_deep_folders"], res["files"]))
        cmd("edit.undo")

        # More than 200 files: a script is never asked (the dialogue is the drop's).
        cmd("app.dialogs", clear=True)
        many = os.path.join(tmproot("many"), "many")
        for i in range(230):
            make_wav(os.path.join(many, "t%03d.wav" % i), 0.05, 200 + i)
        t0 = time.time()
        res = cmd("object.import_folder", path=many)
        elapsed = time.time() - t0
        check("7. 230 files import without a confirmation (never asked of a script)",
              res["files"] == 230 and len(res["tree"]["children"]) == 230
              and cmd("app.dialogs")["count"] == 0, str(cmd("app.dialogs")))
        print("      (230 files imported in %.1f s)" % elapsed)
        check("7. …stacked, one lane each", [k["lane"] for k in res["tree"]["children"]] == list(range(230)))
        cmd("edit.undo")
        check("7. …and one undo removes the 231 objects", objects() == [])

        # More than 2000 files: the whole import is refused, nothing half-done.
        huge = os.path.join(tmproot("huge"), "huge")
        os.makedirs(huge)
        for i in range(2001):
            # 44-byte header + 2 frames: the smallest file that still opens. Written by hand —
            # 2001 `wave` writes through numpy-free Python would be slower than the check itself.
            with wave.open(os.path.join(huge, "f%04d.wav" % i), "wb") as w:
                w.setnchannels(1)
                w.setsampwidth(2)
                w.setframerate(RATE)
                w.writeframes(b"\x00\x00\x10\x00")
        refused("7. more than 2000 files: the whole import is refused (bad_params)", "bad_params",
                lambda: cmd("object.import_folder", path=huge))
        check("7. …and nothing was created", objects() == [])

        cmd("project.new")

finally:
    for folder in roots:
        shutil.rmtree(folder, ignore_errors=True)

print("\nALL PASS" if not fails else "\n%d FAILURE(S): %s" % (len(fails), ", ".join(fails)))
sys.exit(0 if not fails else 1)

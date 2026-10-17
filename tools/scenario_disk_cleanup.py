#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The disk-usage gauge and the clean-up of unused files — a scenario that asserts, through the API.

    # 1. launch the build with the API, on a SHORT socket (a system limit: 103 bytes).
    objekat.app/Contents/MacOS/objekat --headless --api --no-recent --socket=/tmp/odc.sock

    # 2. replay (add --keep to leave the work folder behind for a look)
    ./scenario_disk_cleanup.py /tmp/odc.sock

Sections:
  A  one project, two re-bakes: two orphan revisions, found; unsaved changes protect the saved
     copy; a dry run moves nothing; the real clean-up goes to the Trash (never deleted), leaves
     the project whole (no missing file, the render works).
  B  ⌘Z back to before the re-bakes: the files come back from the Trash and replay; redo; the
     Trash emptied behind the app's back is the usual missing-file path, not a crash.
  C  a second version in the same folder. Session scope offers EVERYTHING this session does not
     read, the file the other version still reads included (listed in `used_elsewhere`, named
     `used_by`); folder scope offers only what nobody reads and rejects it when asked. Without
     `paths` the clean-up takes the orphans only; named explicitly, the other version's wave goes
     to the Trash and that version, reopened, signals it missing (and finds it again once put back).
  D  what else protects: the clipboard, a project parked in another tab, a consolidated object
     being edited (the clean-up is refused), an unreadable version (folder scope refuses).
  E  files outside the universe are never listed; a project never saved has no figures.

Everything sent to the Trash is moved back out of it at the end (never deleted).
Exit: 0 if every assertion passes, 1 otherwise.
"""

import json, os, shutil, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

args = [a for a in sys.argv[1:] if not a.startswith("--")]
KEEP = "--keep" in sys.argv
if len(args) != 1:
    print(__doc__)
    sys.exit(2)

SOCK = args[0]
BIP = os.path.join(HERE, "fixtures", "bip.wav")
ROOT = os.path.realpath(tempfile.mkdtemp(prefix="objk-disk-", dir="/tmp"))
BACK = os.path.join(ROOT, "_trash_back")
TRASHED = []            # every Trash path the app reported, to put them back at the end
fails = []


def check(label, ok, detail=""):
    if ok:
        print("ok    " + label)
    else:
        fails.append(label)
        print("FAIL  %s  %s" % (label, detail))


def section(title):
    print("\n── %s " % title + "─" * max(0, 70 - len(title)))


def exists(p):
    return os.path.exists(p)


def refused(fn, label, code="invalid_state", needle=None):
    try:
        fn()
        check(label, False, "it went through")
    except ObjekatError as e:
        check(label, e.code == code and (needle is None or needle in str(e.details) + e.message),
              "%s: %s %s" % (e.code, e.message, getattr(e, "details", "")))


def main(cmd):
    def job_wait(r):
        return cmd("job.wait", id=r["job_id"], timeout_ms=60000)

    def idle():
        cmd("wait_idle", timeout_ms=60000)

    def du(scope="session"):
        return cmd("project.disk_usage", scope=scope)

    def paths(lst):
        return sorted(u["path"] for u in lst)

    def clean(**kw):
        r = cmd("project.clean_unused", **kw)
        for u in r.get("trashed", []):
            TRASHED.extend(u.get("trash", []))
        return r

    def rebake(placement, db):
        cmd("consolidate.edit_begin", placement=placement)
        kids = [o for o in cmd("object.list")["objects"] if o.get("parent") == placement and o["kind"] == "clip"]
        cmd("object.set_gain", ids=[kids[0]["id"]], db=db)
        job_wait(cmd("consolidate.edit_commit"))
        idle()

    def defs():
        return {d["id"]: d for d in cmd("consolidate.list")["definitions"]}

    def wave_rel(d):
        return "samples/consolidate/" + d["wave"]

    def sidecar_rel(d):
        return "samples/consolidate/" + d["wave"][:-4] + "_objectstate.json"

    def render(path):
        j = job_wait(cmd("export.run", path=path, format="wav", sample_rate=44100, bit_depth=24))
        return j["state"] == "done" and exists(path) and os.path.getsize(path) > 1000

    # ═════════════════════════════════════════════════════════════════════════════════════════
    section("A — two re-bakes, two orphans, and the clean-up")
    P = os.path.join(ROOT, "p")
    os.makedirs(P)
    cmd("project.new")
    refused(lambda: cmd("project.disk_usage"), "A0 a project never saved has no folder, hence no figures")
    clip = cmd("object.add", path=BIP, lane=0, start=0.0)["id"]
    man = os.path.join(P, "p.objekat")
    cmd("project.save_as", path=man)
    job_wait(cmd("consolidate.make", id=clip))
    idle()
    d0 = next(iter(defs().values()))
    pl = d0["placements"][0]
    W0 = dict(d0)
    cmd("project.save")
    rebake(pl, -6)
    W1 = dict(next(iter(defs().values())))
    rebake(pl, -3)
    W2 = dict(next(iter(defs().values())))
    check("A1 the waves are rev 0, 1, 2 (three different files)",
          len({W0["wave"], W1["wave"], W2["wave"]}) == 3 and W2["revision"] == 2, (W0, W1, W2))
    for w in (W0, W1, W2):
        check("A1 %s and its sidecar are on disk" % w["wave"],
              exists(os.path.join(P, wave_rel(w))) and exists(os.path.join(P, sidecar_rel(w))))

    r = du()
    check("A2 dirty project: the saved copy still reads rev 0, so rev 0 is PROTECTED, not offered",
          wave_rel(W0) in paths(r["protected"]) and wave_rel(W0) not in paths(r["cleanable"]), r["protected"])
    check("A2 rev 1 is already orphan", wave_rel(W1) in paths(r["cleanable"]))
    cmd("project.save")
    r = du()
    check("A3 saved: the two old revisions are the orphans",
          paths(r["cleanable"]) == sorted([wave_rel(W0), wave_rel(W1)]), paths(r["cleanable"]))
    check("A3 the current revision is not offered anywhere",
          wave_rel(W2) not in paths(r["cleanable"]) + paths(r["used_elsewhere"]) + paths(r["protected"]))
    unit0 = next(u for u in r["cleanable"] if u["path"] == wave_rel(W0))
    check("A3 a unit is the wave AND its sidecar", sidecar_rel(W0) in unit0["files"], unit0)
    on_disk = sum(os.path.getsize(os.path.join(P, f)) for u in r["cleanable"] for f in u["files"]
                  if exists(os.path.join(P, f)))
    check("A3 unused_bytes is what those files weigh", r["unused_bytes"] == on_disk, (r["unused_bytes"], on_disk))
    check("A3 total_bytes covers the folder", r["total_bytes"] >= on_disk + os.path.getsize(man), r["total_bytes"])
    check("A3 session scope: no file is used by another version",
          r["used_elsewhere"] == [] and r["unreadable_versions"] == [])

    before = sorted(os.listdir(os.path.join(P, "samples", "consolidate")))
    dry = cmd("project.clean_unused")
    check("A4 dry_run is the default and says what would move",
          dry["dry_run"] is True and len(dry["would_trash"]) == 2 and "trashed" not in dry, dry)
    check("A4 a dry run moves nothing", sorted(os.listdir(os.path.join(P, "samples", "consolidate"))) == before)

    r = clean(dry_run=False)
    check("A5 two units trashed", r["count"] == 2 and len(r["trashed"]) == 2, r)
    home_trash = os.path.expanduser("~/.Trash")
    trash_paths = [t for u in r["trashed"] for t in u["trash"]]
    check("A5 every file went to the Trash and exists there",
          trash_paths and all(t.startswith(home_trash) and exists(t) for t in trash_paths), trash_paths)
    check("A5 the originals are gone from the folder",
          not exists(os.path.join(P, wave_rel(W0))) and not exists(os.path.join(P, sidecar_rel(W1))))
    check("A5 the current revision and its sidecar are untouched",
          exists(os.path.join(P, wave_rel(W2))) and exists(os.path.join(P, sidecar_rel(W2))))
    check("A5 no missing file", cmd("project.rescan_missing")["path_count"] == 0)
    check("A5 the figures say nothing is left to clean", paths(du()["cleanable"]) == [])
    check("A5 the render still works", render(os.path.join(ROOT, "after_clean.wav")))

    # ═════════════════════════════════════════════════════════════════════════════════════════
    section("B — undo fetches the files back from the Trash")
    cmd("edit.undo"); idle()
    check("B1 one undo: rev 1 is back on disk (wave + sidecar), fetched from the Trash",
          exists(os.path.join(P, wave_rel(W1))) and exists(os.path.join(P, sidecar_rel(W1))))
    check("B1 the instance plays rev 1 and nothing is missing",
          defs()[W1["id"]]["revision"] == 1 and cmd("project.rescan_missing")["path_count"] == 0)
    cmd("edit.undo"); idle()
    check("B2 second undo: rev 0 is back too", exists(os.path.join(P, wave_rel(W0)))
          and exists(os.path.join(P, sidecar_rel(W0))))
    check("B2 the project is whole, and it renders",
          cmd("project.rescan_missing")["path_count"] == 0 and render(os.path.join(ROOT, "after_undo.wav")))
    check("B2 rev 2 stayed where it was (still on disk, now an orphan of this state)",
          exists(os.path.join(P, wave_rel(W2))))
    cmd("edit.redo"); idle(); cmd("edit.redo"); idle()
    check("B3 redo twice: back on rev 2, nothing missing",
          defs()[W2["id"]]["revision"] == 2 and cmd("project.rescan_missing")["path_count"] == 0)

    # The Trash emptied behind the app's back: moved away (never deleted) to simulate it.
    cmd("project.save")
    r = clean(dry_run=False)
    check("B4 cleaned again (rev 0 and rev 1)", r["count"] == 2, r)
    os.makedirs(BACK, exist_ok=True)
    gone = [t for u in r["trashed"] for t in u["trash"]]
    for t in gone:
        if exists(t):
            shutil.move(t, os.path.join(BACK, "gone_" + os.path.basename(t)))
    cmd("edit.undo"); idle()
    check("B4 Trash emptied: the undo went through (instance back on rev 1) and nothing was restored",
          defs()[W1["id"]]["revision"] == 1 and not exists(os.path.join(P, wave_rel(W1))))
    mf = cmd("project.rescan_missing")
    check("B4 the file is reported missing the usual way (rescan), the app is alive",
          mf["path_count"] >= 1 and cmd("app.info") is not None, mf)
    # put them back so the rest of the scenario starts whole
    for f in os.listdir(BACK):
        if f.startswith("gone_"):
            name = f[len("gone_"):]
            dest = os.path.join(P, "samples", "consolidate", name)
            shutil.move(os.path.join(BACK, f), dest)
    check("B4 files put back by hand: nothing missing after a rescan", cmd("project.rescan_missing")["path_count"] == 0)
    cmd("edit.redo"); idle()

    # ═════════════════════════════════════════════════════════════════════════════════════════
    section("C — a second version of the same folder holds its files")
    Q = os.path.join(ROOT, "q")
    os.makedirs(Q)
    cmd("project.new")
    c = cmd("object.add", path=BIP, lane=0, start=0.0)["id"]
    v1 = os.path.join(Q, "q V1.objekat")
    cmd("project.save_as", path=v1)
    job_wait(cmd("consolidate.make", id=c)); idle()
    dq = next(iter(defs().values()))
    plq = dq["placements"][0]
    V1wave = dict(dq)
    cmd("project.save")                        # V1 reads rev 0
    v2 = os.path.join(Q, "q V2.objekat")
    cmd("project.save_as", path=v2)            # V2 = the same session, another manifest
    rebake(plq, -6)
    V2wave = dict(next(iter(defs().values())))
    cmd("project.save")                        # V2 reads rev 1
    r = du()
    check("C1 session: rev 0 is used by V1 only, named",
          [h["path"] for h in r["used_elsewhere"]] == [wave_rel(V1wave)]
          and r["used_elsewhere"][0]["used_by"] == ["q V1.objekat"], r["used_elsewhere"])
    check("C1 session: the file V1 reads IS offered (cleanable), carrying used_by",
          paths(r["cleanable"]) == [wave_rel(V1wave)] and r["cleanable"][0]["used_by"] == ["q V1.objekat"], r["cleanable"])
    check("C1 session: it is not counted among the files nobody reads",
          r["unused_bytes"] == 0 and r["cleanable_bytes"] > 0 and r["used_elsewhere_bytes"] == r["cleanable_bytes"], r)
    rf = du("folder")
    check("C1 folder: nothing is offered (V1 reads it) but it is still listed apart",
          rf["cleanable"] == [] and [h["path"] for h in rf["used_elsewhere"]] == [wave_rel(V1wave)], rf)
    check("C1 session is a superset of folder", set(paths(rf["cleanable"])) <= set(paths(r["cleanable"])))
    dry = cmd("project.clean_unused", paths=[wave_rel(V1wave)])
    check("C1 a dry run naming it says what would go AND which version will miss it",
          dry["dry_run"] is True and paths(dry["would_trash"]) == [wave_rel(V1wave)]
          and dry["would_trash"][0]["used_by"] == ["q V1.objekat"] and dry["used_by_other_versions"] == 1, dry)
    r = clean(dry_run=False)
    check("C1 without paths only the files nobody reads are taken: here, nothing moves",
          r["count"] == 0 and exists(os.path.join(Q, wave_rel(V1wave))), r)
    r = clean(dry_run=False, scope="folder", paths=[wave_rel(V1wave)])
    check("C2 folder scope: asking for it anyway is rejected as used_elsewhere, nothing moves",
          r["count"] == 0 and r["rejected"] == [{"path": wave_rel(V1wave), "reason": "used_elsewhere"}]
          and exists(os.path.join(Q, wave_rel(V1wave))), r)
    r = clean(dry_run=False, paths=[wave_rel(V2wave)])
    check("C2 the version's own current wave is rejected as used",
          r["rejected"] == [{"path": wave_rel(V2wave), "reason": "used"}] and r["count"] == 0, r)
    check("C2 a path outside the universe is rejected as unknown",
          clean(paths=["../etc/passwd", "q V1.objekat"])["rejected"]
          == [{"path": "../etc/passwd", "reason": "unknown"}, {"path": "q V1.objekat", "reason": "unknown"}])
    rebake(plq, -3)
    V2b = dict(next(iter(defs().values())))
    cmd("project.save")                        # V2 reads rev 2
    r = du()
    check("C3 now rev 1 is the session's orphan, rev 0 is used elsewhere: session offers both",
          sorted(paths(r["cleanable"])) == sorted([wave_rel(V2wave), wave_rel(V1wave)])
          and [h["path"] for h in r["used_elsewhere"]] == [wave_rel(V1wave)], r)
    rf = du("folder")
    check("C3 folder offers rev 1 only (nobody reads it)",
          paths(rf["cleanable"]) == [wave_rel(V2wave)], rf["cleanable"])
    r = clean(dry_run=False, scope="session")
    check("C3 the default clean-up takes rev 1 only", r["count"] == 1 and r["trashed"][0]["path"] == wave_rel(V2wave)
          and "used_by" not in r["trashed"][0], r)
    check("C3 V1's wave is intact", exists(os.path.join(Q, wave_rel(V1wave)))
          and exists(os.path.join(Q, sidecar_rel(V1wave))))
    cmd("project.open", path=v1); idle()
    check("C4 V1 still opens whole", cmd("project.rescan_missing")["path_count"] == 0)
    check("C4 V1 sees V2's wave as used elsewhere (and offers it)",
          wave_rel(V2b) in paths(du()["used_elsewhere"]) and wave_rel(V2b) in paths(du()["cleanable"]),
          du()["used_elsewhere"])
    check("C4 folder scope from V1 does not offer it",
          wave_rel(V2b) not in paths(du("folder")["cleanable"]))

    # C5: from V2, the user CHOOSES to clean the wave V1 still reads.
    cmd("project.open", path=v2); idle()
    r = clean(dry_run=False, paths=[wave_rel(V1wave)])
    check("C5 session, named explicitly: V1's wave goes to the Trash, with the version that will miss it",
          r["count"] == 1 and r["trashed"][0]["path"] == wave_rel(V1wave)
          and r["trashed"][0]["used_by"] == ["q V1.objekat"] and r["rejected"] == [], r)
    check("C5 the files left the folder",
          not exists(os.path.join(Q, wave_rel(V1wave))) and not exists(os.path.join(Q, sidecar_rel(V1wave))))
    check("C5 V2 itself is whole", cmd("project.rescan_missing")["path_count"] == 0)
    cmd("project.open", path=v1); idle()
    check("C5 V1, reopened, signals the wave missing (the usual missing-file alert)",
          cmd("project.rescan_missing")["path_count"] >= 1)
    for t in r["trashed"][0]["trash"]:       # put them back by hand (moved, never deleted)
        rel = wave_rel(V1wave) if t.endswith(".wav") else sidecar_rel(V1wave)
        shutil.move(t, os.path.join(Q, rel))
    check("C5 put back: V1 is whole again", cmd("project.rescan_missing")["path_count"] == 0)

    # ═════════════════════════════════════════════════════════════════════════════════════════
    section("D — what else protects")
    cmd("project.open", path=v2); idle()
    # D1: the clipboard keeps a wave that left the project.
    inst = [o for o in cmd("object.list")["objects"] if o.get("definition")][0]["id"]
    rebake(inst, -1)
    V2c = dict(next(iter(defs().values())))
    cmd("project.save")
    cmd("selection.set", ids=[inst]); cmd("clipboard.copy")
    r = du()
    check("D1 (precondition) rev 2 is an orphan of the session",
          wave_rel(V2b) in paths(r["cleanable"]) + paths(r["protected"]) + paths(r["used_elsewhere"]), r)
    # the clipboard reads the CURRENT instance (rev 3), so protect check: remove it and save
    cmd("object.remove", ids=[inst]); cmd("project.save")
    r = du()
    check("D1 an object copied then deleted: its wave is protected by the clipboard",
          wave_rel(V2c) in paths(r["protected"]) and wave_rel(V2c) not in paths(r["cleanable"]), r["protected"])
    # D2: a consolidated object being edited -> the clean-up is refused.
    cmd("clipboard.paste"); idle()
    inst = [o for o in cmd("object.list")["objects"] if o.get("definition")][0]["id"]
    cmd("consolidate.edit_begin", placement=inst)
    refused(lambda: cmd("project.clean_unused", dry_run=False), "D2 refused during a consolidated edit",
            needle="busy")
    refused(lambda: cmd("project.clean_unused"), "D2 even as a dry run", needle="busy")
    cmd("consolidate.edit_cancel"); idle()
    # D3: an unreadable version: folder scope refuses, session scope answers.
    broken = os.path.join(Q, "broken.objekat")
    with open(broken, "w") as f:
        f.write('{"items": [')
    r = du("folder")
    check("D3 folder scope: an unreadable version cancels it", r["cleanable"] is None
          and r["unreadable_versions"] == ["broken.objekat"], r)
    refused(lambda: cmd("project.clean_unused", scope="folder", dry_run=False), "D3 folder clean-up refused",
            needle="unreadable_versions")
    check("D3 session scope still answers, and names the unreadable file",
          du("session")["cleanable"] is not None and du("session")["unreadable_versions"] == ["broken.objekat"])
    try:
        cmd("project.clean_unused", scope="session")
        check("D3 the session clean-up is not blocked by an unreadable version (dry run)", True)
    except ObjekatError as e:
        check("D3 the session clean-up is not blocked by an unreadable version (dry run)", False, e.message)
    os.remove(broken)
    other = os.path.join(Q, "notes.json")
    with open(other, "w") as f:
        f.write('{"name": "someone else\'s json"}')
    check("D3 a foreign valid JSON is ignored, not 'unreadable'", du("folder")["unreadable_versions"] == [])
    os.remove(other)

    # D4: a project parked in another tab keeps what it reads even when nothing saved says so.
    cmd("project.save")
    inst = [o for o in cmd("object.list")["objects"] if o.get("definition")][0]["id"]
    rebake(inst, -2)                                      # dirty: a new revision no saved file knows
    V2d = dict(next(iter(defs().values())))
    cmd("tab.open", path=v1); idle()                       # parks the dirty V2 tab, opens V1 in front
    r = du()
    check("D4 the parked tab's unsaved revision is protected, not offered",
          wave_rel(V2d) in paths(r["protected"]) and wave_rel(V2d) not in paths(r["cleanable"]),
          (V2d["wave"], r["protected"], r["cleanable"]))
    tabs = cmd("tab.list")["tabs"]
    cmd("tab.close", id=[t for t in tabs if not t.get("active")][0]["id"], discard=True)

    # ═════════════════════════════════════════════════════════════════════════════════════════
    section("E — the universe is a closed list")
    cmd("project.open", path=v2); idle()
    os.makedirs(os.path.join(Q, "samples", "other"), exist_ok=True)
    for rel in ("samples/other/alien.wav", "samples/root.wav", "notes.txt", "samples/consolidate/deep/x.wav"):
        full = os.path.join(Q, rel)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "wb") as f:
            f.write(b"x" * 10)
    r = du()
    listed = set(paths(r["cleanable"]) + paths(r["used_elsewhere"]) + paths(r["protected"]))
    check("E1 files outside samples/{consolidate,objects,sources} and waveforms/*.wfc are never listed",
          not any(x in listed for x in ("samples/other/alien.wav", "samples/root.wav", "notes.txt",
                                          "samples/consolidate/deep/x.wav")), listed)
    orphan_wfc = os.path.join(Q, "waveforms", "orphan.wav.wfc")
    os.makedirs(os.path.dirname(orphan_wfc), exist_ok=True)
    with open(orphan_wfc, "wb") as f:
        f.write(b"y" * 20)
    r = du()
    check("E2 an orphan waveform cache is offered", "waveforms/orphan.wav.wfc" in paths(r["cleanable"]), r["cleanable"])
    r = clean(dry_run=False, paths=["waveforms/orphan.wav.wfc"])
    check("E2 and goes to the Trash like the rest", r["count"] == 1 and not exists(orphan_wfc), r)
    check("E3 the alien files are untouched", all(exists(os.path.join(Q, x)) for x in
          ("samples/other/alien.wav", "samples/root.wav", "notes.txt")))


with ObjekatClient(SOCK) as client:
    def cmd(_name, **params):
        return client.send(_name, params or None)
    try:
        main(cmd)
    finally:
        # Put every file this run sent to the Trash back OUT of it (moved, never deleted).
        os.makedirs(BACK, exist_ok=True)
        for t in TRASHED:
            if exists(t):
                shutil.move(t, os.path.join(BACK, "trash_" + os.path.basename(t)))

print("\n%d failure(s)" % len(fails) if fails else "\nALL PASS")
if not KEEP:
    shutil.rmtree(ROOT, ignore_errors=True)
sys.exit(1 if fails else 0)

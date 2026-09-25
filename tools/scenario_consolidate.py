#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The consolidate rename, on a REALLY old project — a scenario that asserts.

Same shape as `scenario_relink.py` / `scenario_markers.py`: a JSON-lines scenario cannot reuse an
identifier an earlier command returned, and everything here does.

    # 1. launch the NEW build with the API, on a SHORT socket (a system limit: 103 bytes).
    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --socket=/tmp/oc.sock

    # 2. replay (add --keep to leave the work folder behind for a look)
    ./scenario_consolidate.py /tmp/oc.sock

PHASE A makes a project in the OLD format — consolidated objects in `samples/objects/`. The
honest way is to have an old build make it: if `../objekat 2026-09-23 13-00-42.app` (or
`$LEGACY_APP`) exists, the script launches it itself, windowless, on its own socket, drives it
through the `definition.*` names (the only ones it knows — and which the new build still answers,
as hidden aliases) and kills it. Otherwise it falls back on the new build, then moves
`samples/consolidate/*` to `samples/objects/` and rewrites the paths in the manifest and in every
sidecar — a forgery, and the report says which of the two it was.

The project it makes, from three clips of the same source:
  • A = consolidate(clip 1), duplicated once;
  • B = consolidate(group [A's copy, clip 2]) — so B holds an instance of A (nesting, cas E11);
  • C = consolidate(clip 3), independent — the one a later edit of A never touches, which is
    what keeps the project MIXED (both folders in use) for the copy (B14).

PHASE B drives the new build through B1 → B14 of `plan_consolidate.md`, plus the edges the plan
did not list (the X-labelled checks): undo/redo of a commit across the two folders, deconsolidating
an instance that only exists in the legacy folder, a copy onto the project's own folder.

Then the pre-existing bugs fixed on 2026-09-24, each checked STRICTLY (a failure counts):
  • BUG 1 — "Save a copy" onto / into / around the project's folder erased its consolidated waves;
  • BUG 2 — undoing a commit gave back the content as a detached group (commit, cancel, nested);
  • BUG 3 — the copy dropped `snapEnabled` and `viewport`.

Exit: 0 if every assertion passes, 1 otherwise.
"""

import json, os, shutil, stat, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

args = [a for a in sys.argv[1:] if not a.startswith("--")]
KEEP = "--keep" in sys.argv
if len(args) != 1:
    print(__doc__)
    sys.exit(2)

SOCK = args[0]
LEGACY_SOCK = "/tmp/objk-legacy.sock"
BIP = os.path.join(HERE, "fixtures", "bip.wav")
LEGACY_APP = os.environ.get("LEGACY_APP") or os.path.normpath(
    os.path.join(HERE, "..", "..", "objekat 2026-09-23 13-00-42.app"))

# REALPATH: `/tmp` is a symlink to `/private/tmp`. The app stores the paths it is GIVEN verbatim, but
# resolves some it discovers. One spelling on both sides, no assertion weakened.
ROOT = os.path.realpath(tempfile.mkdtemp(prefix="objk-cons-", dir="/tmp"))

fails = []


def check(label, ok, detail=""):
    if ok:
        print("ok    " + label)
    else:
        fails.append(label)
        print("FAIL  %s  %s" % (label, detail))


def section(title):
    print("\n── %s " % title + "─" * max(0, 70 - len(title)))


# ── disk helpers ────────────────────────────────────────────────────────────────────────────

def ls(folder):
    return sorted(os.listdir(folder)) if os.path.isdir(folder) else []


def waves(folder):
    return [f for f in ls(folder) if f.endswith(".wav")]


def sidecars(folder):
    return [f for f in ls(folder) if f.endswith("_objectstate.json")]


def sidecar_of(wave):
    return wave[:-4] + "_objectstate.json"


def fingerprint(folder):
    """relpath → (size, mtime_ns) for every file, plus every directory (as relpath → 'dir')."""
    fp = {}
    for dirpath, dirnames, filenames in os.walk(folder):
        for d in dirnames:
            fp[os.path.relpath(os.path.join(dirpath, d), folder)] = "dir"
        for f in filenames:
            p = os.path.join(dirpath, f)
            st = os.stat(p)
            fp[os.path.relpath(p, folder)] = (st.st_size, st.st_mtime_ns)
    return fp


def same_file(a, b):
    """The same file on disk, whatever the spelling (`/tmp` is `/private/tmp`): an instance
    restored from the project as it was LOADED keeps the spelling of the load."""
    return bool(a) and bool(b) and os.path.exists(a) and os.path.exists(b) and os.path.samefile(a, b)


def only(fp, prefix):
    return {k: v for k, v in fp.items() if k == prefix or k.startswith(prefix + "/")}


def read_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def text_files(folder):
    for dirpath, _, filenames in os.walk(folder):
        for f in filenames:
            if f.endswith((".json", ".objekat")):
                p = os.path.join(dirpath, f)
                with open(p, encoding="utf-8") as fh:
                    yield p, fh.read()


def walk_objects(items):
    """Every object of a serialised item list, nested groups included."""
    for o in items:
        yield o
        kind = o.get("kind", {})
        if kind.get("type") == "group":
            for c in walk_objects(kind.get("children", [])):
                yield c


def set_writable(folder, writable):
    for dirpath, dirnames, filenames in os.walk(folder):
        for p in [dirpath] + [os.path.join(dirpath, f) for f in filenames]:
            mode = os.stat(p).st_mode
            if writable:
                os.chmod(p, mode | stat.S_IWUSR)
            else:
                os.chmod(p, mode & ~(stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH))


# ── driving helpers ─────────────────────────────────────────────────────────────────────────

def make_cmd(client):
    def cmd(_name, **params):
        return client.send(_name, params or None)
    return cmd


def launch(app, sock):
    if os.path.exists(sock):
        os.remove(sock)
    proc = subprocess.Popen([os.path.join(app, "Contents", "MacOS", "objekat"),
                             "--headless", "--api", "--no-audio", "--no-recent",
                             "--socket=" + sock],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(120):
        if os.path.exists(sock):
            return proc
        time.sleep(0.25)
    proc.kill()
    raise RuntimeError("the app did not open its socket: " + sock)


def job_wait(cmd, r, timeout_ms=60000):
    return cmd("job.wait", id=r["job_id"], timeout_ms=timeout_ms)


def defs_by_id(cmd, name="consolidate.list"):
    return {d["id"]: d for d in cmd(name)["definitions"]}


def objects(cmd):
    return cmd("object.list")["objects"]


def obj(cmd, oid):
    for o in objects(cmd):
        if o["id"] == oid:
            return o
    return None


def children_of(cmd, pid):
    """The descendants of `pid`, in object.list's flattened reading."""
    rows = objects(cmd)
    ids, out, grew = {pid}, [], True
    while grew:
        grew = False
        for o in rows:
            if o.get("parent") in ids and o["id"] not in ids:
                ids.add(o["id"]); out.append(o); grew = True
    return out


def state_subtree(cmd, oid):
    """`oid` and its descendants as the SESSION serialises them. object.list only walks what the
    lanes show — a folded group's children are not in it — so a freshly deconsolidated (folded)
    group is read here. Paths under the project folder come back relative (portable)."""
    for o in walk_objects(cmd("project.get_state")["items"]):
        if o["id"] == oid:
            return list(walk_objects([o]))
    return []


def refused(cmd_fn, label, code, needle=None):
    try:
        cmd_fn()
        check(label, False, "it went through")
        return None
    except ObjekatError as e:
        ok = e.code == code and (needle is None or needle in e.message)
        check(label, ok, "%s: %s" % (e.code, e.message))
        return e


# ════════════════════════════════════════════════════════════════════════════════════════════
# PHASE A — a project in the OLD format
# ════════════════════════════════════════════════════════════════════════════════════════════

def build_legacy(cmd, folder):
    """Drives an app (old or new) through the `definition.*` names both understand. Returns the ids."""
    cmd("project.new")
    c1 = cmd("object.add", path=BIP, lane=0, start=0.0)["id"]
    c2 = cmd("object.add", path=BIP, lane=2, start=1.0)["id"]
    c3 = cmd("object.add", path=BIP, lane=4, start=3.0)["id"]
    manifest = os.path.join(folder, "legacy.json")
    cmd("project.save_as", path=manifest)

    job_wait(cmd, cmd("definition.make", id=c1))
    defs = defs_by_id(cmd, "definition.list")
    assert len(defs) == 1, defs
    a_id = next(iter(defs))
    pa = defs[a_id]["placements"][0]

    pa2 = cmd("object.duplicate", ids=[pa])["ids"][0]
    g = cmd("group.create", ids=[pa2, c2])["id"]
    job_wait(cmd, cmd("definition.make", id=g))
    b_id = [d for d in defs_by_id(cmd, "definition.list") if d != a_id][0]

    job_wait(cmd, cmd("definition.make", id=c3))
    defs = defs_by_id(cmd, "definition.list")
    c_id = [d for d in defs if d not in (a_id, b_id)][0]
    pc = defs[c_id]["placements"][0]
    cmd("wait_idle", timeout_ms=30000)
    cmd("project.save")
    return dict(manifest=manifest, a=a_id, b=b_id, c=c_id, pa=pa, pa2=pa2, pb=g, pc=pc)


def forge_old_format(folder):
    """The fallback: a project the NEW build made, moved into the old layout by hand."""
    src = os.path.join(folder, "samples", "consolidate")
    dst = os.path.join(folder, "samples", "objects")
    os.makedirs(dst, exist_ok=True)
    for f in ls(src):
        shutil.move(os.path.join(src, f), os.path.join(dst, f))
    os.rmdir(src)
    for p in [os.path.join(folder, "legacy.json")] + [os.path.join(dst, f) for f in sidecars(dst)]:
        with open(p, encoding="utf-8") as fh:
            t = fh.read()
        # Both spellings: Foundation's JSONEncoder escapes the slash (`samples\/consolidate\/`).
        t = t.replace("samples/consolidate/", "samples/objects/")
        t = t.replace("samples\\/consolidate\\/", "samples\\/objects\\/")
        if p.endswith("legacy.json"):
            # …and the format number the old build wrote.
            t = t.replace('"version" : 16', '"version" : 15')
        with open(p, "w", encoding="utf-8") as fh:
            fh.write(t)


legacy_proc = None
try:
    section("PHASE A — an old-format project")
    LEG = os.path.join(ROOT, "legacy")
    os.makedirs(LEG)
    if os.path.isdir(LEGACY_APP):
        print("made by the OLD build: " + LEGACY_APP)
        legacy_proc = launch(LEGACY_APP, LEGACY_SOCK)
        with ObjekatClient(LEGACY_SOCK) as lc:
            ids = build_legacy(make_cmd(lc), LEG)
        legacy_proc.terminate()
        legacy_proc.wait(timeout=20)
        legacy_proc = None
        forged = False
    else:
        print("no old build found — FORGED with the new build (%s absent)" % LEGACY_APP)
        with ObjekatClient(SOCK) as fc:
            fcmd = make_cmd(fc)
            ids = build_legacy(fcmd, LEG)
            fcmd("project.new")
        forge_old_format(LEG)
        forged = True

    OBJ = os.path.join(LEG, "samples", "objects")
    CONS = os.path.join(LEG, "samples", "consolidate")
    check("A: samples/objects/ holds 3 waves and 3 sidecars",
          len(waves(OBJ)) == 3 and len(sidecars(OBJ)) == 3, ls(OBJ))
    check("A: samples/consolidate/ does not exist", not os.path.exists(CONS))
    legacy_doc = read_json(ids["manifest"])
    check("A: the manifest is the old format (version 15)", legacy_doc.get("version") == 15,
          legacy_doc.get("version"))
    b_def = [d for d in legacy_doc["objectDefinitions"] if d["id"] == ids["b"]][0]
    check("A: B depends on A (nesting)",
          [d["definitionID"] for d in b_def.get("dependsOn", [])] == [ids["a"]], b_def)

    # The pristine copy every later scenario that needs the ORIGINAL old project starts from.
    PRISTINE = os.path.join(ROOT, "pristine")
    shutil.copytree(LEG, PRISTINE)

    def fresh_copy(name):
        dst = os.path.join(ROOT, name)
        shutil.copytree(PRISTINE, dst)
        return dst, os.path.join(dst, "legacy.json")

    # ════════════════════════════════════════════════════════════════════════════════════════
    # PHASE B — the new build
    # ════════════════════════════════════════════════════════════════════════════════════════
    with ObjekatClient(SOCK, timeout=180) as c:
        cmd = make_cmd(c)
        check("--no-recent honoured", cmd("app.info").get("records_recent_projects") is False)
        cmd("app.set_dialog_policy", policy="assume_yes")

        # ── B1 / B2 ──────────────────────────────────────────────────────────────────────────
        section("B1/B2 — opening the old project")
        before = fingerprint(LEG)
        cmd("project.open", path=ids["manifest"])
        cmd("wait_idle", timeout_ms=30000)
        mf = cmd("project.missing_files")
        check("B1: missing_files is empty", mf["path_count"] == 0, mf)
        defs = defs_by_id(cmd)
        check("B1: 3 definitions (A, B, C), none stale",
              set(defs) == {ids["a"], ids["b"], ids["c"]}
              and not any(d["stale"] for d in defs.values()), defs)
        after = fingerprint(LEG)
        check("B2: no samples/consolidate/ created by opening", not os.path.exists(CONS))
        check("B2: samples/ and the manifest untouched by opening",
              only(before, "samples") == only(after, "samples")
              and before["legacy.json"] == after["legacy.json"],
              set(after.items()) ^ set(before.items()))
        wf_changed = only(before, "waveforms") != only(after, "waveforms")
        print("info  waveforms/ %s by opening (a regenerable cache, outside B2)"
              % ("CHANGED" if wf_changed else "unchanged"))
        # X: the in-memory serialisation keeps the old relative paths (portable), not absolute ones.
        st = cmd("project.get_state")
        inst = [o for o in walk_objects(st["items"]) if o.get("definitionID")]
        check("X  get_state writes the old instances as samples/objects/… (relative)",
              inst and all(o["kind"]["filePath"].startswith("samples/objects/") for o in inst),
              [o["kind"]["filePath"] for o in inst])

        # ── B3 ───────────────────────────────────────────────────────────────────────────────
        section("B3 — opening B (sidecar in objects/) and cancelling")
        r = cmd("consolidate.edit_begin", placement=ids["pb"])
        s1 = cmd("consolidate.state")
        check("B3: edit_begin on B opens (depth 1)",
              r["depth"] == 1 and s1["editing"] and s1["definition"] == ids["b"], (r, s1))
        nested = [o for o in children_of(cmd, ids["pb"]) if o.get("definition") == ids["a"]]
        check("B3: B's content holds an instance of A reading A's wave in objects/",
              len(nested) == 1 and nested[0]["file"] == os.path.join(OBJ, defs[ids["a"]]["wave"]),
              nested)
        r = cmd("consolidate.edit_cancel")
        check("B3: edit_cancel closes (depth 0)", r["depth"] == 0 and not r["editing"], r)
        check("B3: still no samples/consolidate/", not os.path.exists(CONS))

        # ── B4 ───────────────────────────────────────────────────────────────────────────────
        section("B4 — editing A at the root, commit, cascade")
        obj_before = fingerprint(OBJ)
        r = cmd("consolidate.edit_begin", placement=ids["pa"])
        check("B4: edit_begin on A (depth 1)", r["depth"] == 1, r)
        kids = [o for o in children_of(cmd, ids["pa"]) if o["kind"] == "clip"]
        check("B4: A's content is one clip", len(kids) == 1, kids)
        if kids:
            cmd("object.set_gain", ids=[kids[0]["id"]], db=-6)
        j = job_wait(cmd, cmd("consolidate.edit_commit"))
        idle = cmd("wait_idle", timeout_ms=60000)
        check("B4: the commit job ends done, edit closed",
              j["state"] == "done" and j["result"]["editing"] is False, j)
        check("B4: wait_idle comes back idle", idle["idle"], idle)
        defs = defs_by_id(cmd)
        A, B, C = defs[ids["a"]], defs[ids["b"]], defs[ids["c"]]
        check("B4: A is at revision 1, wave _v1", A["revision"] == 1 and A["wave"].endswith("_v1.wav"), A)
        check("B4: A's new wave + sidecar are in samples/consolidate/",
              os.path.isfile(os.path.join(CONS, A["wave"]))
              and os.path.isfile(os.path.join(CONS, sidecar_of(A["wave"]))), ls(CONS))
        check("B4: the cascade re-baked B (revision 1, wave in consolidate/)",
              B["revision"] == 1 and os.path.isfile(os.path.join(CONS, B["wave"]))
              and os.path.isfile(os.path.join(CONS, sidecar_of(B["wave"]))), (B, ls(CONS)))
        check("B4: C untouched (revision 0, still in objects/)",
              C["revision"] == 0 and os.path.isfile(os.path.join(OBJ, C["wave"])), C)
        check("B4: nothing stale", not any(d["stale"] for d in defs.values()), defs)
        check("B4: samples/objects/ intact", fingerprint(OBJ) == obj_before)
        pa_row = obj(cmd, ids["pa"])
        check("B4: A's root instance reads the _v1 wave in consolidate/",
              pa_row and pa_row["file"] == os.path.join(CONS, A["wave"]), pa_row)

        # ── X: undo / redo of the commit, across the two folders (cas E13) ───────────────────
        section("X — undo/redo of the commit (E13)")
        cmd("edit.undo")
        cmd("wait_idle", timeout_ms=30000)
        du = defs_by_id(cmd)
        pa_row = obj(cmd, ids["pa"])
        check("X  undo: A back to revision 0", du[ids["a"]]["revision"] == 0, du[ids["a"]])
        # BUG 2 (fixed): undoing a COMMIT used to give back the materialised CONTENT as a plain
        # group — the undo point was pushed while the placement was still materialised.
        check("BUG2 undo: A's instance back, linked, on the objects/ wave",
              pa_row and pa_row["kind"] == "clip" and pa_row.get("definition") == ids["a"]
              and same_file(pa_row.get("file"), os.path.join(OBJ, du[ids["a"]]["wave"])), pa_row)
        check("BUG2 undo: no edit session left open", not cmd("consolidate.state")["editing"])
        check("X  undo: B back to revision 0 and not stale",
              du[ids["b"]]["revision"] == 0 and not du[ids["b"]]["stale"], du[ids["b"]])
        check("X  undo: nothing missing", cmd("project.rescan_missing")["path_count"] == 0)
        cmd("edit.redo")
        cmd("wait_idle", timeout_ms=30000)
        dr = defs_by_id(cmd)
        check("X  redo: A and B at revision 1 again",
              dr[ids["a"]]["revision"] == 1 and dr[ids["b"]]["revision"] == 1,
              (dr[ids["a"]], dr[ids["b"]]))
        pa_row = obj(cmd, ids["pa"])
        check("X  redo: A's instance on the _v1 wave again",
              pa_row and pa_row["file"] == os.path.join(CONS, dr[ids["a"]]["wave"]), pa_row)

        # ── B5 ───────────────────────────────────────────────────────────────────────────────
        section("B5 — saving: format 16, historic keys, relative paths")
        cmd("project.save")
        doc = read_json(ids["manifest"])
        st = cmd("project.get_state")
        check("B5: version 16 on disk and in get_state",
              doc.get("version") == 16 and st.get("version") == 16, (doc.get("version"), st.get("version")))
        check("B5: key objectDefinitions kept", "objectDefinitions" in doc
              and "consolidateDefinitions" not in doc, list(doc))
        dB = [d for d in doc["objectDefinitions"] if d["id"] == ids["b"]][0]
        check("B5: dependsOn[].definitionID kept",
              [d.get("definitionID") for d in dB.get("dependsOn", [])] == [ids["a"]], dB)
        inst = {o["id"]: o for o in walk_objects(doc["items"]) if "definitionID" in o}
        check("B5: instances carry the key definitionID (never consolidateID)",
              inst and "consolidateID" not in json.dumps(doc), list(inst))
        want = {ids["pa"]: "samples/consolidate/" + dr[ids["a"]]["wave"],
                ids["pb"]: "samples/consolidate/" + dr[ids["b"]]["wave"],
                ids["pc"]: "samples/objects/" + dr[ids["c"]]["wave"]}
        got = {k: inst[k]["kind"]["filePath"] for k in want if k in inst}
        check("B5: instance paths relative, A/B in consolidate/, C still in objects/",
              got == want, (got, want))
        raw = json.dumps(doc)
        check("B5: no absolute path under the project folder in the manifest", LEG not in raw)
        sc_b = read_json(os.path.join(CONS, sidecar_of(dr[ids["b"]]["wave"])))
        nested = [o for o in walk_objects([sc_b]) if o.get("definitionID") == ids["a"]]
        check("B5: B's new sidecar names A's _v1 wave, relative, under the historic key",
              len(nested) == 1
              and nested[0]["kind"]["filePath"] == "samples/consolidate/" + dr[ids["a"]]["wave"],
              [o["kind"] for o in nested])
        check("B5: no absolute project path in the new sidecars",
              all(LEG not in t for p, t in text_files(CONS)))

        # ── B6 ───────────────────────────────────────────────────────────────────────────────
        section("B6 — reopening")
        list_before = cmd("consolidate.list")
        cmd("project.open", path=ids["manifest"])
        cmd("wait_idle", timeout_ms=30000)
        check("B6: missing_files empty", cmd("project.missing_files")["path_count"] == 0)
        list_after = cmd("consolidate.list")
        check("B6: consolidate.list identical", list_after == list_before, (list_before, list_after))

        # ── X: deconsolidating an instance whose content only exists in objects/ ────────────
        section("X — deconsolidating C (legacy folder only)")
        r = cmd("consolidate.unmake", placement=ids["pc"])
        row = obj(cmd, ids["pc"])
        kids = state_subtree(cmd, ids["pc"])[1:]
        check("X  unmake C: detached, a group holding the source clip",
              r["still_linked"] is False and row["kind"] == "group"
              and any(k["kind"].get("filePath") == BIP for k in kids), (r, row, kids))
        cmd("edit.undo")
        check("X  undo puts C's instance back", obj(cmd, ids["pc"]).get("definition") == ids["c"])

        # ── B7 ───────────────────────────────────────────────────────────────────────────────
        section("B7 — deconsolidating A, undo, redo")
        r = cmd("consolidate.unmake", placement=ids["pa"])
        row = obj(cmd, ids["pa"])
        check("B7: still_linked false, kind group",
              r["still_linked"] is False and row["kind"] == "group" and not row.get("definition"),
              (r, row))
        cmd("edit.undo")
        row = obj(cmd, ids["pa"])
        check("B7: undo → linked instance again",
              row["kind"] == "clip" and row.get("definition") == ids["a"], row)
        cmd("edit.redo")
        row = obj(cmd, ids["pa"])
        check("B7: redo → detached again", row["kind"] == "group" and not row.get("definition"), row)

        # ── B8 ───────────────────────────────────────────────────────────────────────────────
        section("B8 — deconsolidating B: its A instance reads A's CURRENT wave")
        cur_a = defs_by_id(cmd)[ids["a"]]["wave"]
        r = cmd("consolidate.unmake", placement=ids["pb"])
        nested = [o for o in state_subtree(cmd, ids["pb"]) if o.get("definitionID") == ids["a"]]
        check("B8: B detached", r["still_linked"] is False, r)
        check("B8: the nested A instance reads consolidate/<A _v1>",
              len(nested) == 1 and nested[0]["kind"]["filePath"] == "samples/consolidate/" + cur_a,
              ([o["kind"] for o in nested], cur_a))

        # ── B9 ───────────────────────────────────────────────────────────────────────────────
        section("B9 — the old names")
        check("B9: definition.list == consolidate.list",
              cmd("definition.list") == cmd("consolidate.list"))
        names = [x["name"] for x in cmd("help")["commands"]]
        check("B9: help lists consolidate.* (7) and no definition.*",
              len([n for n in names if n.startswith("consolidate.")]) == 7
              and not any(n.startswith("definition.") for n in names))
        h = cmd("help", name="definition.make")
        check("B9: help definition.make → alias_of consolidate.make",
              h.get("alias_of") == "consolidate.make" and h.get("name") == "consolidate.make", h)
        h = cmd("help", name="definition.detach")
        check("X  help definition.detach → alias_of consolidate.unmake",
              h.get("alias_of") == "consolidate.unmake", h)

        # ── B10 ──────────────────────────────────────────────────────────────────────────────
        section("B10 — a never-saved project")
        cmd("project.new")
        cid = cmd("object.add", path=BIP, lane=0, start=0.0)["id"]
        refused(lambda: cmd("consolidate.make", id=cid),
                "B10: consolidate.make refused, message citing samples/consolidate/",
                "invalid_state", "samples/consolidate/")
        refused(lambda: cmd("definition.make", id=cid),
                "X  the alias refuses the same way", "invalid_state", "samples/consolidate/")

        # ── B11 ──────────────────────────────────────────────────────────────────────────────
        section("B11 — a new project")
        FRESH = os.path.join(ROOT, "fresh")
        cmd("project.save_as", path=os.path.join(FRESH, "fresh.json"))
        # The filling circle's data, read while the render runs: `consolidate.state.renders`
        # answers what the circle SHOWS. A short bip may finish between two polls, so the only
        # claims are the ones that hold whatever the timing: every reading names a bake, stays
        # inside 0…1 and never goes back, and nothing is left once the job is done.
        mk = cmd("consolidate.make", id=cid)
        readings = []
        deadline = time.time() + 60
        while time.time() < deadline and cmd("job.status", id=mk["job_id"])["state"] == "running":
            readings += cmd("consolidate.state")["renders"]
            time.sleep(0.02)
        job_wait(cmd, mk)
        cmd("wait_idle", timeout_ms=30000)
        progresses = [r["progress"] for r in readings if r.get("progress") is not None]
        check("X  render progress: only bakes, within 0…1, never going back",
              all(r.get("kind") == "bake" for r in readings)
              and all(0.0 <= p <= 1.0 for p in progresses)
              and all(a <= b for a, b in zip(progresses, progresses[1:])),
              readings)
        check("X  render progress: nothing left once the job is done",
              cmd("consolidate.state")["renders"] == [], cmd("consolidate.state"))
        d = list(defs_by_id(cmd).values())
        fc = os.path.join(FRESH, "samples", "consolidate")
        check("B11: the wave and its sidecar land in samples/consolidate/",
              len(d) == 1 and waves(fc) == [d[0]["wave"]] and sidecars(fc) == [sidecar_of(d[0]["wave"])],
              (d, ls(fc)))
        check("B11: samples/objects/ never created",
              not os.path.exists(os.path.join(FRESH, "samples", "objects")))

        # ── B12 ──────────────────────────────────────────────────────────────────────────────
        section("B12 — Save As to a NEW folder, then edit (Q3)")
        SRC12, man12 = fresh_copy("b12src")
        DST12 = os.path.join(ROOT, "b12dst")
        cmd("project.open", path=man12)
        cmd("wait_idle", timeout_ms=30000)
        cmd("project.save_as", path=os.path.join(DST12, "b12dst.json"))
        src_before = fingerprint(SRC12)
        try:
            r = cmd("consolidate.edit_begin", placement=ids["pa"])
            check("B12: edit_begin opens after the Save As (Q3 fallback)", r["depth"] == 1, r)
        except ObjekatError as e:
            check("B12: edit_begin opens after the Save As (Q3 fallback)", False, e)
        kids = [o for o in children_of(cmd, ids["pa"]) if o["kind"] == "clip"]
        if kids:
            cmd("object.set_gain", ids=[kids[0]["id"]], db=-6)
        j = job_wait(cmd, cmd("consolidate.edit_commit"))
        cmd("wait_idle", timeout_ms=60000)
        d12 = defs_by_id(cmd)
        c12 = os.path.join(DST12, "samples", "consolidate")
        check("B12: the commit writes into the NEW folder's consolidate/",
              j["result"]["editing"] is False and d12[ids["a"]]["revision"] == 1
              and os.path.isfile(os.path.join(c12, d12[ids["a"]]["wave"]))
              and os.path.isfile(os.path.join(c12, sidecar_of(d12[ids["a"]]["wave"]))),
              (j, d12[ids["a"]], ls(c12)))
        check("X  B12: the cascade re-bakes B from the OLD folder's sidecar, into the new one",
              d12[ids["b"]]["revision"] == 1
              and os.path.isfile(os.path.join(c12, d12[ids["b"]]["wave"])), (d12[ids["b"]], ls(c12)))
        check("B12: nothing written into the old folder", fingerprint(SRC12) == src_before)
        # Deconsolidating C, whose wave only exists in the OLD folder's objects/ (Q3 again).
        r = cmd("consolidate.unmake", placement=ids["pc"])
        check("X  B12: deconsolidating C after the Save As (sidecar via Q3)",
              r["still_linked"] is False, r)
        cmd("edit.undo")
        # BUG 1, the Q3 side: C's wave is still READ from the OLD folder, so that folder is a
        # source of any copy too — copying onto it would erase the wave C plays.
        src12_before = fingerprint(SRC12)
        refused(lambda: cmd("project.save_copy", path=SRC12),
                "BUG1 save_copy onto the OLD folder the waves are still read from → refused",
                "bad_params", "still reads consolidated waves from")
        check("BUG1 the old folder untouched by the refusal", fingerprint(SRC12) == src12_before)
        cmd("project.save")
        cmd("project.open", path=os.path.join(DST12, "b12dst.json"))
        cmd("wait_idle", timeout_ms=30000)
        check("X  B12: reopened, nothing missing", cmd("project.missing_files")["path_count"] == 0)

        # ── B13 ──────────────────────────────────────────────────────────────────────────────
        section("B13 — a read-only copy")
        RO, man13 = fresh_copy("b13ro")
        set_writable(RO, False)
        try:
            ro_before = fingerprint(RO)
            cmd("app.dialogs", clear=True)
            cmd("project.open", path=man13)
            cmd("wait_idle", timeout_ms=30000)
            check("B13: opening a read-only project works, nothing missing",
                  cmd("project.missing_files")["path_count"] == 0)
            r = cmd("consolidate.edit_begin", placement=ids["pa"])
            check("B13: edit_begin works on a read-only project", r["depth"] == 1, r)
            kids = [o for o in children_of(cmd, ids["pa"]) if o["kind"] == "clip"]
            if kids:
                cmd("object.set_gain", ids=[kids[0]["id"]], db=-6)
            j = job_wait(cmd, cmd("consolidate.edit_commit"))
            cmd("wait_idle", timeout_ms=60000)
            alive = cmd("app.info")
            dlg = cmd("app.dialogs")
            d13 = defs_by_id(cmd)
            check("B13: the commit fails cleanly — app alive, A still revision 0, edit still open",
                  alive["has_document"] and d13[ids["a"]]["revision"] == 0
                  and cmd("consolidate.state")["editing"], (j, d13[ids["a"]]))
            check("B13: the failure is REPORTED, naming samples/consolidate/ (not a bare "
                  "'render failed')",
                  dlg["count"] >= 1
                  and any("samples/consolidate/" in x["info"] for x in dlg["dialogs"]), dlg)
            print("info  B13 dialogue(s): %s" % [(x["title"], x["info"]) for x in dlg["dialogs"]])
            r = cmd("consolidate.edit_cancel")
            check("B13: edit_cancel afterwards closes cleanly", r["depth"] == 0, r)
            check("B13: nothing written on the read-only project", fingerprint(RO) == ro_before,
                  set(fingerprint(RO).items()) ^ set(ro_before.items()))
            cmd("project.new")
        finally:
            set_writable(RO, True)

        # ── B14 ──────────────────────────────────────────────────────────────────────────────
        section("B14 — project.save_copy of a mixed project")
        # BUG 3: a viewport that is not the default one, so that its survival means something.
        man = read_json(ids["manifest"])
        VP = {"pixelsPerSecond": 137.5, "blockHeight": 53.0, "scrollX": 211.0, "scrollY": 17.0}
        man["viewport"] = VP
        with open(ids["manifest"], "w", encoding="utf-8") as fh:
            json.dump(man, fh, indent=2, sort_keys=True)
        cmd("project.open", path=ids["manifest"])      # B5's state: A, B in consolidate/, C in objects/
        cmd("wait_idle", timeout_ms=30000)
        d14 = defs_by_id(cmd)
        check("B14: the project really is mixed (both folders in use)",
              os.path.isfile(os.path.join(CONS, d14[ids["a"]]["wave"]))
              and os.path.isfile(os.path.join(OBJ, d14[ids["c"]]["wave"])), d14)
        # A little unsaved change: the copy carries the project as it is in MEMORY.
        cmd("object.set_gain", ids=[ids["pc"]], db=-3)
        info_before = cmd("app.info")

        # ── BUG 1 (data loss, pre-existing): a copy onto the project's own folder erased its
        # consolidated waves — step 7's "remove the destination, then copy" fell on the source.
        # Every overlap is refused, by FILE-SYSTEM identity, whatever the spelling.
        section("BUG 1 — save_copy onto / into / around the project's folder")
        leg_before = fingerprint(LEG)
        cmd("app.dialogs", clear=True)
        refused(lambda: cmd("project.save_copy", path=LEG),
                "BUG1 save_copy onto the project's own folder → bad_params", "bad_params", "own folder")
        dlg = cmd("app.dialogs")
        check("BUG1 the refusal is the MENU's own (its alert is recorded, naming the folder)",
              dlg["count"] == 1 and LEG in dlg["dialogs"][0]["info"], dlg)
        refused(lambda: cmd("project.save_copy", path=LEG + "/"),
                "BUG1 …with a trailing slash", "bad_params", "own folder")
        refused(lambda: cmd("project.save_copy", path=os.path.join(LEG, "samples", "..")),
                "BUG1 …through '..'", "bad_params", "own folder")
        if LEG.startswith("/private/tmp/"):
            refused(lambda: cmd("project.save_copy", path=LEG[len("/private"):]),
                    "BUG1 …spelt /tmp/… (a symbolic link in the path)", "bad_params", "own folder")
        LINK = os.path.join(ROOT, "link-to-legacy")
        os.symlink(LEG, LINK)
        refused(lambda: cmd("project.save_copy", path=LINK),
                "BUG1 …through a symbolic link to it", "bad_params", "own folder")
        swapped = os.path.join(os.path.dirname(LEG), os.path.basename(LEG).upper())
        if os.path.exists(swapped):   # a case-insensitive volume (APFS by default)
            refused(lambda: cmd("project.save_copy", path=swapped),
                    "BUG1 …spelt in another case (case-insensitive volume)", "bad_params", "own folder")
        else:
            print("info  case-sensitive volume: the other-case spelling is another folder, not tested")
        refused(lambda: cmd("project.save_copy", path=os.path.join(LEG, "samples")),
                "BUG1 into an existing folder INSIDE the project → refused", "bad_params", "inside")
        refused(lambda: cmd("project.save_copy", path=os.path.join(LEG, "samples", "consolidate")),
                "BUG1 into samples/consolidate/ itself → refused", "bad_params", "inside")
        refused(lambda: cmd("project.save_copy", path=os.path.join(LEG, "new copy")),
                "BUG1 into a NEW folder inside the project → refused", "bad_params", "inside")
        refused(lambda: cmd("project.save_copy", path=os.path.join(LINK, "new copy")),
                "BUG1 into a new folder inside, through the link → refused", "bad_params", "inside")
        refused(lambda: cmd("project.save_copy", path=ROOT),
                "BUG1 into a folder CONTAINING the project → refused", "bad_params", "contains")
        check("BUG1 nothing created inside the project", not os.path.exists(os.path.join(LEG, "new copy")))
        check("BUG1 the project's files untouched by every refusal (waves still there)",
              fingerprint(LEG) == leg_before
              and os.path.isfile(os.path.join(CONS, d14[ids["a"]]["wave"]))
              and os.path.isfile(os.path.join(OBJ, d14[ids["c"]]["wave"])),
              set(fingerprint(LEG).items()) ^ set(leg_before.items()))
        os.remove(LINK)
        info_mid = cmd("app.info")
        check("BUG1 the refusals leave the project as it was (path, dirty)",
              info_mid["project_path"] == info_before["project_path"]
              and info_mid["dirty"] == info_before["dirty"], (info_before, info_mid))
        # BUG 3: the snap off (a project setting, saved with it) — the copy used to drop it.
        cmd("project.set_snap", enabled=False)
        st_before = cmd("project.get_state")
        print("info  viewport in memory after opening: %s" % st_before.get("viewport"))
        CAP = os.path.join(ROOT, "capsule")
        r = cmd("project.save_copy", path=CAP)
        check("B14: save_copy answers, nothing missing",
              r["manifest"] == os.path.join(CAP, "capsule.objekat") and r["missing"] == []
              and r["copied_files"] == 4, r)
        info_after = cmd("app.info")
        check("B14: the current project is untouched (path, dirty)",
              info_after["project_path"] == info_before["project_path"]
              and info_after["dirty"] == info_before["dirty"] is True,
              (info_before, info_after))
        cs = os.path.join(CAP, "samples")
        want_waves = sorted(d14[k]["wave"] for k in (ids["a"], ids["b"], ids["c"]))
        check("B14: the capsule has ONLY samples/consolidate/ and samples/sources/",
              ls(cs) == ["consolidate", "sources"], ls(cs))
        check("B14: consolidate/ = exactly the 3 CURRENT waves + their sidecars (no orphan)",
              waves(os.path.join(cs, "consolidate")) == want_waves
              and sidecars(os.path.join(cs, "consolidate")) == sorted(map(sidecar_of, want_waves)),
              (ls(os.path.join(cs, "consolidate")), want_waves))
        check("B14: the source landed in samples/sources/",
              ls(os.path.join(cs, "sources")) == ["bip.wav"], ls(os.path.join(cs, "sources")))
        leaks = [p for p, t in text_files(CAP) if LEG in t or os.path.dirname(BIP) in t]
        check("B14: no path of the original project nor of the source left in the capsule",
              not leaks, leaks)
        capdoc = read_json(os.path.join(CAP, "capsule.objekat"))
        check("BUG3 the copy keeps snapEnabled (false)", capdoc.get("snapEnabled") is False,
              capdoc.get("snapEnabled"))
        check("BUG3 the copy keeps the viewport, as it is in memory",
              capdoc.get("viewport") is not None and capdoc.get("viewport") == st_before.get("viewport"),
              (capdoc.get("viewport"), st_before.get("viewport")))
        # The ZOOM is the model's; the SCROLL is restored by the TimelineView once its content is in
        # place (`pendingViewRestore`) — there is no view without a window, so headless it reads 0.
        # The copy writes what memory holds, as a save does (checked just above).
        zoom = lambda v: {k: (v or {}).get(k) for k in ("pixelsPerSecond", "blockHeight")}
        check("BUG3 …whose zoom is the one the project was opened with",
              zoom(capdoc.get("viewport")) == zoom(VP), (capdoc.get("viewport"), VP))
        same_keys = [k for k in ("tempo", "timeSigNumerator", "timeSigDenominator", "gridMode",
                                 "stems", "version") if capdoc.get(k) != st_before.get(k)]
        check("BUG3 every other session setting identical to a save's", not same_keys,
              [(k, capdoc.get(k), st_before.get(k)) for k in same_keys])
        missing_keys = sorted(set(st_before) - set(capdoc))
        check("BUG3 the copy has every top-level key a save has", not missing_keys, missing_keys)
        pc_cap = [o for o in walk_objects(capdoc["items"]) if o["id"] == ids["pc"]]
        check("B14: the unsaved change travelled (C at -3 dB)",
              pc_cap and abs(pc_cap[0]["volume"] + 3) < 1e-6, pc_cap)
        # Self-contained for real: the original project is taken away before the capsule opens.
        HIDDEN = LEG + "-hidden"
        os.rename(LEG, HIDDEN)
        try:
            cmd("project.open", path=os.path.join(CAP, "capsule.objekat"))
            cmd("wait_idle", timeout_ms=30000)
            check("B14: capsule reopened with the original gone — missing_files empty",
                  cmd("project.missing_files")["path_count"] == 0)
            st_cap = cmd("project.get_state")
            check("BUG3 the reopened capsule is off the grid, at the original's zoom",
                  st_cap.get("snapEnabled") is False and zoom(st_cap.get("viewport")) == zoom(VP),
                  (st_cap.get("snapEnabled"), st_cap.get("viewport")))
            dc = defs_by_id(cmd)
            check("B14: the capsule lists the 3 definitions", set(dc) == set(d14), dc)
            r = cmd("consolidate.edit_begin", placement=ids["pb"])
            nested = [o for o in children_of(cmd, ids["pb"]) if o.get("definition") == ids["a"]]
            check("B14: edit_begin works in the capsule, B's nested A reads the capsule's wave",
                  r["depth"] == 1 and len(nested) == 1
                  and nested[0]["file"] == os.path.join(cs, "consolidate", d14[ids["a"]]["wave"]),
                  (r, nested))
            cmd("consolidate.edit_cancel")
            r = cmd("consolidate.edit_begin", placement=ids["pc"])
            check("X  B14: C (from the legacy folder) opens in the capsule", r["depth"] == 1, r)
            cmd("consolidate.edit_cancel")
            cmd("project.new")
        finally:
            os.rename(HIDDEN, LEG)

        # ── BUG 2 — undo / redo of a commit, of a cancel, of a nested commit ─────────────────
        section("BUG 2 — undoing a commit gives back the LINKED instance")
        U = os.path.join(ROOT, "undo")
        cmd("project.new")
        u1 = cmd("object.add", path=BIP, lane=0, start=0.0)["id"]
        u2 = cmd("object.add", path=BIP, lane=2, start=1.0)["id"]
        cmd("project.save_as", path=os.path.join(U, "undo.json"))
        job_wait(cmd, cmd("consolidate.make", id=u1))
        ua = list(defs_by_id(cmd))[0]
        pa1 = defs_by_id(cmd)[ua]["placements"][0]
        pa2 = cmd("object.duplicate", ids=[pa1])["ids"][0]          # a second ROOT instance of A
        # …and one to nest in B (duplicated from pa2: a second duplicate of pa1 would land on pa2's
        # spot and cover it)
        pa3 = cmd("object.duplicate", ids=[pa2])["ids"][0]
        check("BUG2 setup: three root instances of A",
              all(obj(cmd, x) and obj(cmd, x).get("definition") == ua for x in (pa1, pa2, pa3)))
        ug = cmd("group.create", ids=[pa3, u2])["id"]
        job_wait(cmd, cmd("consolidate.make", id=ug))
        ub = [d for d in defs_by_id(cmd) if d != ua][0]
        cmd("wait_idle", timeout_ms=30000)
        d0 = defs_by_id(cmd)
        UC = os.path.join(U, "samples", "consolidate")

        def linked(oid, defid, wave):
            row = obj(cmd, oid)
            return bool(row) and row["kind"] == "clip" and row.get("definition") == defid \
                and same_file(row.get("file"), os.path.join(UC, wave)), row

        def edit_and_commit(placement):
            cmd("consolidate.edit_begin", placement=placement)
            kids = [o for o in children_of(cmd, placement) if o["kind"] == "clip"]
            cmd("object.set_gain", ids=[kids[0]["id"]], db=-6)
            j = job_wait(cmd, cmd("consolidate.edit_commit"))
            cmd("wait_idle", timeout_ms=60000)
            return j

        # 1. commit on one root instance, then undo / undo / redo / redo.
        edit_and_commit(pa1)
        d1 = defs_by_id(cmd)
        check("BUG2 setup: A at revision 1, the cascade re-baked B",
              d1[ua]["revision"] == 1 and d1[ub]["revision"] == 1, (d1[ua], d1[ub]))
        cmd("edit.undo")
        cmd("wait_idle", timeout_ms=30000)
        du = defs_by_id(cmd)
        ok, row = linked(pa1, ua, d0[ua]["wave"])
        check("BUG2 undo commit: the edited instance is LINKED to A, on revision 0's wave", ok, row)
        ok, row = linked(pa2, ua, d0[ua]["wave"])
        check("BUG2 undo commit: the OTHER root instance of A back on revision 0's wave", ok, row)
        ok, row = linked(ug, ub, d0[ub]["wave"])
        check("BUG2 undo commit: B (holding A) back on its revision 0", ok, row)
        check("BUG2 undo commit: registry A rev 0, B rev 0, nothing stale",
              du[ua]["revision"] == 0 and du[ub]["revision"] == 0
              and not any(d["stale"] for d in du.values()), du)
        check("BUG2 undo commit: no session open", not cmd("consolidate.state")["editing"])
        check("BUG2 undo commit: no group left over from the content",
              not any(o["kind"] == "group" and not o.get("definition") for o in objects(cmd)),
              [o for o in objects(cmd) if o["kind"] == "group"])
        # A second undo steps over the session's own points (opening, the gain on the content)
        # to the gesture BEFORE the opening — B's consolidation — never into a materialised state.
        cmd("edit.undo")
        ok, row = linked(pa1, ua, d0[ua]["wave"])
        check("BUG2 2nd undo: the edited instance still linked (no session point resurrected)", ok, row)
        row = obj(cmd, ug)
        check("BUG2 2nd undo: it undid the gesture before the opening (B's consolidation)",
              row and row["kind"] == "group" and not row.get("definition"), row)
        cmd("edit.redo")
        ok, row = linked(ug, ub, d0[ub]["wave"])
        check("BUG2 redo: B consolidated again", ok, row)
        cmd("edit.redo")
        cmd("wait_idle", timeout_ms=30000)
        dr = defs_by_id(cmd)
        check("BUG2 redo commit: registry A rev 1, B rev 1",
              dr[ua]["revision"] == 1 and dr[ub]["revision"] == 1, (dr[ua], dr[ub]))
        for oid, label in ((pa1, "the edited instance"), (pa2, "the other root instance")):
            ok, row = linked(oid, ua, d1[ua]["wave"])
            check("BUG2 redo commit: %s on revision 1's wave" % label, ok, row)
        ok, row = linked(ug, ub, d1[ub]["wave"])
        check("BUG2 redo commit: B on its revision 1", ok, row)
        check("BUG2 redo: nothing missing", cmd("project.rescan_missing")["path_count"] == 0)

        # 2. a cancel leaves nothing behind it: the undo after it never resurrects the content.
        cmd("consolidate.edit_begin", placement=pa1)
        kids = [o for o in children_of(cmd, pa1) if o["kind"] == "clip"]
        cmd("object.set_gain", ids=[kids[0]["id"]], db=-12)
        cmd("consolidate.edit_cancel")
        ok, row = linked(pa1, ua, d1[ua]["wave"])
        check("BUG2 cancel: linked on revision 1", ok, row)
        cmd("edit.undo")
        cmd("wait_idle", timeout_ms=30000)
        ok, row = linked(pa1, ua, d0[ua]["wave"])
        check("BUG2 undo after a cancel: the COMMIT is undone (the session left no point)", ok, row)
        cmd("edit.redo")
        cmd("wait_idle", timeout_ms=30000)
        ok, row = linked(pa1, ua, d1[ua]["wave"])
        check("BUG2 …and redone", ok, row)

        # 3. a NESTED commit (A opened inside B), then B's commit: one undo = B before ITS commit.
        cmd("consolidate.edit_begin", placement=ug)
        inner = [o for o in children_of(cmd, ug) if o.get("definition") == ua]
        check("BUG2 nested: B open, holding one instance of A", len(inner) == 1, inner)
        r = cmd("consolidate.edit_begin", placement=inner[0]["id"])
        check("BUG2 nested: A opened inside B (depth 2)", r["depth"] == 2, r)
        kids = [o for o in children_of(cmd, inner[0]["id"]) if o["kind"] == "clip"]
        cmd("object.set_gain", ids=[kids[0]["id"]], db=-3)
        j = job_wait(cmd, cmd("consolidate.edit_commit"))
        cmd("wait_idle", timeout_ms=60000)
        st = cmd("consolidate.state")
        check("BUG2 nested: the child commit leaves B open",
              j["state"] == "done" and st["editing"] and st["definition"] == ub, (j, st))
        d2 = defs_by_id(cmd)
        check("BUG2 nested: A at revision 2", d2[ua]["revision"] == 2, d2[ua])
        cmd("edit.undo")          # inside B's session: undoes A's commit, B stays open
        inner_row = obj(cmd, inner[0]["id"])
        check("BUG2 nested undo inside the parent: the inner A back LINKED to revision 1",
              inner_row and inner_row["kind"] == "clip" and inner_row.get("definition") == ua
              and inner_row["file"] == os.path.join(UC, d1[ua]["wave"])
              and cmd("consolidate.state")["editing"], inner_row)
        cmd("edit.redo")
        inner_row = obj(cmd, inner[0]["id"])
        check("BUG2 nested redo inside the parent: the inner A on revision 2",
              inner_row and inner_row.get("definition") == ua
              and inner_row["file"] == os.path.join(UC, d2[ua]["wave"]), inner_row)
        job_wait(cmd, cmd("consolidate.edit_commit"))       # B's commit
        cmd("wait_idle", timeout_ms=60000)
        d3 = defs_by_id(cmd)
        check("BUG2 nested: B committed (revision 2)", d3[ub]["revision"] == 2, d3[ub])
        cmd("edit.undo")
        cmd("wait_idle", timeout_ms=30000)
        du = defs_by_id(cmd)
        ok, row = linked(ug, ub, d1[ub]["wave"])
        check("BUG2 nested undo: B LINKED again, on the revision before its commit", ok, row)
        check("BUG2 nested undo: B back to revision 1, A keeps revision 2 (committed before)",
              du[ub]["revision"] == 1 and du[ua]["revision"] == 2, (du[ub], du[ua]))
        check("BUG2 nested undo: no session open", not cmd("consolidate.state")["editing"])
        cmd("edit.redo")
        cmd("wait_idle", timeout_ms=30000)
        ok, row = linked(ug, ub, d3[ub]["wave"])
        check("BUG2 nested redo: B on revision 2", ok, row)
        cmd("project.new")

        # ── BUG 1, the last line of defence: a SOURCE file already sitting where the copy would
        # put it. An unsaved project has no folder to refuse, and the destination is legitimate —
        # but the "remove, then copy" of its own source used to delete the only copy there is.
        section("BUG 1 — a source already in the destination (never-saved project)")
        DS = os.path.join(ROOT, "dsrc")
        os.makedirs(os.path.join(DS, "samples", "sources"))
        own = os.path.join(DS, "samples", "sources", "bip.wav")
        shutil.copy(BIP, own)
        size = os.path.getsize(own)
        cmd("project.new")
        cmd("object.add", path=own, lane=0, start=0.0)
        spelt = DS[len("/private"):] if DS.startswith("/private/tmp/") else DS
        r = cmd("project.save_copy", path=spelt)
        check("BUG1 the copy goes through (nothing missing)", r["missing"] == [], r)
        check("BUG1 the source that was already in place survived the copy",
              os.path.isfile(own) and os.path.getsize(own) == size,
              os.path.exists(own) and os.path.getsize(own))
        capdoc = read_json(r["manifest"])
        check("BUG1 the copy names it, relative, where it is",
              [o["kind"].get("filePath") for o in walk_objects(capdoc["items"])]
              == ["samples/sources/bip.wav"], capdoc["items"])

        cmd("project.new")
        print("\nPhase A was %s." % ("FORGED with the new build" if forged else "made by the OLD build"))

finally:
    if legacy_proc is not None:
        legacy_proc.kill()
    if KEEP:
        print("work folder kept: " + ROOT)
    else:
        shutil.rmtree(ROOT, ignore_errors=True)

print("\nALL PASS" if not fails else "\n%d FAILURE(S): %s" % (len(fails), ", ".join(fails)))
sys.exit(0 if not fails else 1)

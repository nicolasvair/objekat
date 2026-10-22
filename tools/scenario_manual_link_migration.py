#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Session format 32: the legacy single-instance manual plugin link is cleared at load — a scenario that ASSERTS
(22 October 2026, `plan_modifiers_rework.md` §7).

    ./scenario_manual_link_migration.py [path/to/objekat.app]

It LAUNCHES its own headless processes (`--headless --api --no-audio --no-recent`), one fresh one per phase.

The file built here is a REAL project saved by the app, then edited as a format-31 file would have been: two
objects carry a reverb each, the two reverbs tied by a manual ⌘-link (`linkGroupID`), a stem plugin carries a
detached residue (`detachedLinkGroupID`), the version is 31; and two other objects share an FX link bin (the only
way left of sharing parameters), whose instances keep their `linkGroupID`.

  PHASE 1  the project is built and saved (format 32); a reference export is taken.
  PHASE 2  the legacy file (version 31 + the manual links) is opened in a fresh process:
             • no plugin outside a bin carries a link any more (`plugin.list` shows no `link_group`, `linked` false),
             • the bin is untouched (instances keep their group, the mirror still works, the stage is in sync),
             • moving a parameter of one formerly linked reverb leaves the other alone,
             • the session is CLEAN (no dirty flag: the file on disk still holds the link until the next save),
             • the export is identical to the reference (to the sample),
             • saved again, the file is format 32 with no link field outside a bin.
  PHASE 3  the saved file reopens clean in another fresh process, and nothing is left to migrate (idempotent).

Exit: 0 if every assertion passes, 1 otherwise.
"""

import json, os, shutil, subprocess, sys, tempfile, time, uuid, wave

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

APP = os.path.join(HERE, "..", "build", "dd", "Build", "Products", "Debug", "objekat.app")
KEEP = False
for a in sys.argv[1:]:
    if a == "--keep":
        KEEP = True
    elif not a.startswith("--"):
        APP = a
EXE = os.path.join(os.path.abspath(APP), "Contents", "MacOS", "objekat")
BIP = os.path.join(HERE, "fixtures", "bip.wav")
TMP = tempfile.mkdtemp(prefix="manlink_")

fails = []
total = 0


def check(label, ok, detail=""):
    global total
    total += 1
    if ok:
        print("ok    " + label)
    else:
        fails.append(label)
        print("FAIL  %s   %s" % (label, detail))


def wav_samples(path):
    with wave.open(path, "rb") as w:
        sw, raw = w.getsampwidth(), w.readframes(w.getnframes())
    if sw != 3:
        raise RuntimeError("expected a 24-bit export, got %d bytes per sample" % sw)
    return [int.from_bytes(raw[i:i + 3], "little", signed=True) for i in range(0, len(raw) - 2, 3)]


class App:
    _n = 0

    def __init__(self):
        App._n += 1
        self.sock = "/tmp/manlink_%d_%d.sock" % (os.getpid(), App._n)
        if os.path.exists(self.sock):
            os.remove(self.sock)
        self.proc = subprocess.Popen([EXE, "--headless", "--api", "--no-audio", "--no-recent",
                                      "--language=en", "--socket=" + self.sock],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(240):
            if os.path.exists(self.sock):
                break
            time.sleep(0.25)
        else:
            self.proc.kill()
            raise RuntimeError("the app did not open its socket: " + self.sock)
        self.client = ObjekatClient(self.sock, timeout=240).connect()
        check("--no-recent honoured", self.cmd("app.info").get("records_recent_projects") is False)
        self.cmd("app.set_dialog_policy", policy="assume_yes")

    def cmd(self, _name, **params):
        return self.client.send(_name, params or None)

    def refused(self, _name, **params):
        try:
            self.client.send(_name, params or None)
            return None
        except ObjekatError as e:
            return e.code

    def idle(self):
        self.cmd("wait_idle", timeout_ms=120000)

    def chain(self, host):
        return self.cmd("plugin.list", host=host)["plugins"]

    def close(self):
        try:
            self.client.close()
        except Exception:
            pass
        self.proc.kill()
        self.proc.wait()
        if os.path.exists(self.sock):
            os.remove(self.sock)

    def render(self, name):
        out = os.path.join(TMP, name)
        r = self.cmd("export.run", format="wav", sample_rate=44100, dithering=False,
                     start=0.0, end=0.6, path=out)
        self.cmd("job.wait", id=r["job_id"], timeout_ms=120000)
        return wav_samples(out)

    def wait_loaded(self, plugin):
        for _ in range(100):
            try:
                if self.cmd("plugin.get_params", plugin=plugin)["count"] > 0:
                    return True
            except ObjekatError:
                pass
            time.sleep(0.1)
        return False

    def param(self, plugin, index):
        for q in self.cmd("plugin.get_params", plugin=plugin)["params"]:
            if q["index"] == index:
                return q
        return None


def find_file(folder):
    return os.path.join(folder, [f for f in os.listdir(folder) if f.endswith(".objekat")][0])


def walk_plugins(doc):
    """Every plugin entry of the file, with (inside_block, where): the three roots of an object (chain,
    instruments, each send's plugins), the group children, and the stems. A block's own members are
    reported with `inside_block` True."""
    out = []

    def chain(ps, where, in_block):
        for k, p in enumerate(ps or []):
            here = "%s[%d]" % (where, k)
            out.append((p, in_block, here))
            if p.get("rack"):
                for v, voice in enumerate(p["rack"].get("voices", [])):
                    chain(voice, "%s.rack[%d]" % (here, v), in_block)
            if p.get("fxBlock"):
                chain(p["fxBlock"].get("plugins"), here + ".fxBlock", True)

    def objs(arr, where):
        for i, o in enumerate(arr):
            here = "%s[%d]" % (where, i)
            chain(o.get("plugins"), here + ".plugins", False)
            chain(o.get("instruments"), here + ".instruments", False)
            for s, snd in enumerate(o.get("sends") or []):
                chain(snd.get("plugins"), "%s.sends[%d]" % (here, s), False)
            kids = (o.get("kind") or {}).get("children")
            if kids:
                objs(kids, here + ".children")

    objs(doc["items"], "items")
    for s, st in enumerate(doc.get("stems") or []):
        chain(st.get("plugins"), "stems[%d]" % s, False)
    return out


def link_fields(doc):
    """(outside_block, inside_block): the plugins holding `linkGroupID` or `detachedLinkGroupID`."""
    outside, inside = [], []
    for p, in_block, where in walk_plugins(doc):
        if p.get("linkGroupID") or p.get("detachedLinkGroupID"):
            (inside if in_block else outside).append(where)
    return outside, inside


def main():
    ref = None
    # ── PHASE 1 — build, save, reference export ─────────────────────────────────────────────
    print("PHASE 1  build the project")
    a = App()
    try:
        a.cmd("project.new")
        o1 = a.cmd("object.add", path=BIP, lane=0, start=0)["id"]
        o2 = a.cmd("object.add", path=BIP, lane=1, start=0)["id"]
        b1 = a.cmd("object.add", path=BIP, lane=2, start=0)["id"]
        b2 = a.cmd("object.add", path=BIP, lane=3, start=0)["id"]
        stem = a.cmd("stem.add", name="Bus", format="stereo")["id"]
        r1 = a.cmd("plugin.add", host=o1, identifier="reverb", format="TracktionInternal")["plugin"]["id"]
        r2 = a.cmd("plugin.add", host=o2, identifier="reverb", format="TracktionInternal")["plugin"]["id"]
        sp = a.cmd("plugin.add", host=stem, identifier="compressor", format="TracktionInternal")["plugin"]["id"]
        e1 = a.cmd("plugin.add", host=b1, identifier="4bandEq", format="TracktionInternal")["plugin"]["id"]
        a.cmd("fxlink.create", objects=[b1, b2], name="pair")
        a.idle()
        check("the bin holds two instances", all(any(p.get("is_fx_block") for p in a.chain(h)) for h in (b1, b2)))
        folder = os.path.join(TMP, "p1")
        os.makedirs(folder)
        a.cmd("project.save_as", path=os.path.join(folder, "p.objekat"))
        a.idle()
        ref = a.render("ref.wav")
        check("the reference export has signal", max(abs(s) for s in ref) > 1000)
        ids = dict(o1=o1, o2=o2, b1=b1, b2=b2, stem=stem, r1=r1, r2=r2, sp=sp)
    finally:
        a.close()

    # ── the legacy file: version 31, two reverbs tied by a manual link, a detached residue ──
    path1 = find_file(folder)
    doc = json.load(open(path1))
    check("a freshly saved file is format 32", doc.get("version") == 32, str(doc.get("version")))
    out, inside = link_fields(doc)
    check("...and holds no link field outside a bin", out == [], str(out))
    check("...while the bin's instances hold theirs", len(inside) >= 2, str(inside))
    group, resid = str(uuid.uuid4()).upper(), str(uuid.uuid4()).upper()
    n_manual = 0
    for p, in_block, where in walk_plugins(doc):
        if in_block:
            continue
        if p["id"].lower() in (ids["r1"].lower(), ids["r2"].lower()):
            p["linkGroupID"] = group
            n_manual += 1
        elif p["id"].lower() == ids["sp"].lower():
            p["detachedLinkGroupID"] = resid
            n_manual += 1
    check("three plugins were given a legacy link field", n_manual == 3, str(n_manual))
    doc["version"] = 31
    legacy = os.path.join(TMP, "legacy")
    shutil.copytree(folder, legacy)
    lpath = find_file(legacy)
    json.dump(doc, open(lpath, "w"), indent=1)
    before = open(lpath, "rb").read()

    # ── PHASE 2 — open the legacy file ──────────────────────────────────────────────────────
    print("PHASE 2  open the format-31 file")
    a = App()
    try:
        a.cmd("project.open", path=lpath)
        a.idle()
        check("the session is CLEAN after the migration", a.cmd("app.info").get("dirty") is False,
              str(a.cmd("app.info").get("dirty")))
        check("the file on disk is untouched by the load", open(lpath, "rb").read() == before)
        objs = {o["id"].lower(): o for o in a.cmd("object.list")["objects"]}
        check("the four objects are there", all(ids[k].lower() in objs for k in ("o1", "o2", "b1", "b2")))
        for k in ("o1", "o2"):
            pl = [p for p in a.chain(ids[k]) if p.get("identifier") == "reverb"]
            check("%s: the reverb is still there" % k, len(pl) == 1)
            check("%s: ...unlinked (no link_group, linked false)" % k,
                  all("link_group" not in p and p["linked"] is False for p in pl), str(pl))
        sp_list = a.cmd("plugin.list", host=ids["stem"])["plugins"]
        check("the stem plugin is still there, with no link residue",
              len(sp_list) >= 1 and all("link_group" not in p for p in sp_list), str(sp_list))
        for k in ("b1", "b2"):
            blocks = [p for p in a.chain(ids[k]) if p.get("is_fx_block")]
            check("%s: the bin's block is intact" % k, len(blocks) == 1 and blocks[0]["plugins"], str(blocks))
        inst1 = next(p for p in a.chain(ids["b1"]) if p.get("is_fx_block"))["plugins"][0]["id"]
        inst2 = next(p for p in a.chain(ids["b2"]) if p.get("is_fx_block"))["plugins"][0]["id"]
        check("the bin's instances keep their link group", all(
            "link_group" in p for p in next(q for q in a.chain(ids["b1"]) if q.get("is_fx_block"))["plugins"]))

        # the formerly linked reverbs no longer mirror
        a.wait_loaded(ids["r1"])
        a.wait_loaded(ids["r2"])
        p2_before = a.param(ids["r2"], 0)["value"]
        p1 = a.param(ids["r1"], 0)
        target = p1["min"] + (p1["max"] - p1["min"]) * (0.2 if p1["value"] > (p1["min"] + p1["max"]) / 2 else 0.8)
        a.cmd("plugin.set_param", plugin=ids["r1"], index=0, value=target)
        time.sleep(0.8)
        check("the first reverb moved", abs(a.param(ids["r1"], 0)["value"] - target) < 1e-3)
        check("...the other one stayed (the manual link is gone)",
              abs(a.param(ids["r2"], 0)["value"] - p2_before) < 1e-4,
              "%s -> %s" % (p2_before, a.param(ids["r2"], 0)["value"]))
        # the bin still mirrors
        a.wait_loaded(inst1)
        a.wait_loaded(inst2)
        q = a.param(inst1, 0)
        t2 = q["min"] + (q["max"] - q["min"]) * (0.3 if q["value"] > (q["min"] + q["max"]) / 2 else 0.7)
        a.cmd("plugin.set_param", plugin=inst1, index=0, value=t2)
        time.sleep(1.0)
        check("the bin still mirrors a parameter to its other member",
              abs(a.param(inst2, 0)["value"] - t2) < max(1e-3, abs(t2) * 1e-3),
              "%s vs %s" % (a.param(inst2, 0)["value"], t2))
        a.cmd("plugin.set_param", plugin=ids["r1"], index=0, value=p1["value"])
        a.cmd("plugin.set_param", plugin=inst1, index=0, value=q["value"])
        time.sleep(0.8)
        audit = a.cmd("debug.plugin_id_audit") if a.refused("debug.plugin_id_audit") is None else None
        if audit is not None:
            check("debug.plugin_id_audit: no duplicate id", not audit.get("duplicates"), str(audit))
        # the export is the reference's, to the sample
        cur = a.render("legacy.wav")
        same = len(cur) == len(ref) and max(abs(x - y) for x, y in zip(cur, ref)) <= 2
        check("the export of the migrated session equals the reference (<= 2 LSB)", same,
              "len %d vs %d, max diff %s" % (len(cur), len(ref),
                                              max(abs(x - y) for x, y in zip(cur, ref)) if len(cur) == len(ref) else "n/a"))
        # saved again: format 32 and no link field outside a bin
        folder2 = os.path.join(TMP, "p2")
        os.makedirs(folder2)
        a.cmd("project.save_as", path=os.path.join(folder2, "p.objekat"))
        a.idle()
    finally:
        a.close()
    doc2 = json.load(open(find_file(folder2)))
    check("the migrated file is saved as format 32", doc2.get("version") == 32, str(doc2.get("version")))
    out2, inside2 = link_fields(doc2)
    check("...with no link field outside a bin", out2 == [], str(out2))
    check("...and the bin's instances still hold theirs", len(inside2) >= 2, str(inside2))

    # ── PHASE 3 — the saved file reopens clean, nothing left to migrate ─────────────────────
    print("PHASE 3  reopen the migrated file")
    a = App()
    try:
        a.cmd("project.open", path=find_file(folder2))
        a.idle()
        check("the reopened session is clean", a.cmd("app.info").get("dirty") is False)
        check("...and still unlinked", all("link_group" not in p for k in ("o1", "o2")
                                           for p in a.chain(ids[k])))
        cur = a.render("again.wav")
        check("...and exports like the reference", len(cur) == len(ref)
              and max(abs(x - y) for x, y in zip(cur, ref)) <= 2)
    finally:
        a.close()

    print("")
    print("%d assertion(s), %d failure(s)" % (total, len(fails)))
    for f in fails:
        print("  FAILED: " + f)
    if not KEEP:
        shutil.rmtree(TMP, ignore_errors=True)
    else:
        print("kept: " + TMP)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())

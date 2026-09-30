#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Plugin ids duplicated between hosts — a scenario that ASSERTS (1 October 2026).

    ./scenario_fxlink_duplicate_ids.py [path/to/objekat.app] [--external=aumf,FQ4p,FabF] [--keep]

It LAUNCHES its own headless processes (`--headless --api --no-audio --no-recent`), one fresh one
per opening — a fresh process is part of the proof: the engine's plugin map must not be able to
hide anything a previous project left in it. DEBUG build only (`debug.plugin_id_audit`): SKIP, exit
0, if the build has no `debug.*` commands.

The bug it guards. `ObjectPlugin.id` is the engine's plugin key, and the engine holds ONE instance per
key. A session whose JSON was touched outside the app — FX link block entries copied from one
object to another with a fresh block id but the SAME instance ids — carried the same key under
two hosts: the last chain to compile moved the instance out of the first host's chain, which then
played DRY, silently (and "switch the link off and on" only moved the theft to the other host).

What it asserts, on a bin shared by A and B plus an ordinary C, corrupted in the exact shape found
in the user's files, with an automation curve on the duplicated instance of B:

  1. opening repairs: `last_load.repaired_plugin_ids == 1`, the audit finds no duplicate, the engine
     refused nothing;
  2. the repaired instance is a new id in the same link group; the curve follows it;
  3. THE assertion of the bug — an export of each object played alone: A, B and C ALL processed,
     like the healthy session's reference (the compressor's output gain, -10 dB, is heard);
  4. the mirror is intact (a parameter set on A arrives on B, and B's render follows);
  5. gestures that recompile a chain (bin off/on, detach, reattach, on A then on B) no longer steal;
  6. a save writes no duplicate, reopening repairs nothing (`repaired_plugin_ids == 0`), same renders;
  7. the ENGINE'S NET, with the repair switched off (`OBJ_NO_PLUGIN_ID_REPAIR=1`): the first host
     keeps the instance, the second plays dry, `engine_foreign_refusals >= 1`, and detaching /
     reattaching the second host never steals A's instance.

With a Pro-Q 4 installed, the same opening test runs on it too (Output Level = 0.2, -21.6 dB).

Never `transport.play` (the real audio device may open despite `--no-audio`); exports are 24-bit
WAVs re-read at peak. Nothing is written outside a temporary folder.

Exit: 0 if every assertion passes (or SKIP), 1 otherwise.
"""

import copy, json, os, shutil, subprocess, sys, tempfile, time, uuid, wave

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

APP = os.path.join(HERE, "..", "build", "dd", "Build", "Products", "Debug", "objekat.app")
EXTERNAL = "aumf,FQ4p,FabF"
KEEP = False
for a in sys.argv[1:]:
    if a.startswith("--external="):
        EXTERNAL = a.split("=", 1)[1]
    elif a == "--keep":
        KEEP = True
    elif not a.startswith("--"):
        APP = a
EXE = os.path.join(os.path.abspath(APP), "Contents", "MacOS", "objekat")
BIP = os.path.join(HERE, "fixtures", "bip.wav")
TMP = tempfile.mkdtemp(prefix="fxdup_")

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


def wav_peak(path):
    with wave.open(path, "rb") as w:
        sw, raw = w.getsampwidth(), w.readframes(w.getnframes())
    if sw != 3:
        raise RuntimeError("expected a 24-bit export, got %d bytes per sample" % sw)
    peak = 0
    for i in range(0, len(raw) - 2, 3):
        peak = max(peak, abs(int.from_bytes(raw[i:i + 3], "little", signed=True)))
    return peak / 8388608.0


# ── one headless process, driven through its socket ─────────────────────────────────────────

class App:
    _n = 0

    def __init__(self, env=None):
        App._n += 1
        self.sock = "/tmp/fxdup_%d_%d.sock" % (os.getpid(), App._n)
        if os.path.exists(self.sock):
            os.remove(self.sock)
        e = dict(os.environ)
        e.update(env or {})
        self.proc = subprocess.Popen([EXE, "--headless", "--api", "--no-audio", "--no-recent",
                                      "--socket=" + self.sock],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=e)
        for _ in range(240):
            if os.path.exists(self.sock):
                break
            time.sleep(0.25)
        else:
            self.proc.kill()
            raise RuntimeError("the app did not open its socket: " + self.sock)
        self.client = ObjekatClient(self.sock, timeout=240).connect()
        info = self.cmd("app.info")
        check("--no-recent honoured", info.get("records_recent_projects") is False)
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

    def close(self):
        try:
            self.client.close()
        except Exception:
            pass
        self.proc.kill()
        self.proc.wait()
        if os.path.exists(self.sock):
            os.remove(self.sock)

    # -- helpers shared by the phases --------------------------------------------------------
    def render(self, name):
        out = os.path.join(TMP, name)
        r = self.cmd("export.run", format="wav", sample_rate=44100, dithering=False,
                     start=0.0, end=0.6, path=out)
        self.cmd("job.wait", id=r["job_id"], timeout_ms=120000)
        return wav_peak(out)

    def solo(self, objs, target, tag):
        """Peak of `target` played alone: every other object muted."""
        self.cmd("object.set_mute", ids=[o for o in objs if o != target], muted=True)
        self.cmd("object.set_mute", ids=[target], muted=False)
        self.idle()
        return self.render("%s_%s.wav" % (tag, target[:6]))

    def unmute_all(self, objs):
        self.cmd("object.set_mute", ids=objs, muted=False)
        self.idle()

    def chain(self, host):
        return self.cmd("plugin.list", host=host)["plugins"]

    def block(self, host):
        return next(p for p in self.chain(host) if p.get("is_fx_block"))

    def block_inst(self, host):
        return self.block(host)["plugins"][0]["id"]

    def plain_inst(self, host):
        return next(p for p in self.chain(host) if not p.get("is_fx_block"))["id"]

    def audit(self):
        return self.cmd("debug.plugin_id_audit")

    def repaired(self):
        return self.cmd("project.load_status").get("last_load", {}).get("repaired_plugin_ids")


def walk_plugin_ids(items):
    """Every plugin id of a session, leaves + carriers + blocks + instruments, group children too."""
    out = []

    def chain(ps):
        for p in ps or []:
            out.append(p["id"])
            for v in (p.get("rack") or {}).get("voices", []):
                chain(v)
            chain((p.get("fxBlock") or {}).get("plugins"))

    def objs(arr):
        for o in arr:
            chain(o.get("plugins"))
            chain(o.get("instruments"))
            kids = o.get("children")
            if kids:
                objs(kids)
    objs(items)
    return out


def load_json(folder):
    path = [f for f in os.listdir(folder) if f.endswith(".objekat")][0]
    return os.path.join(folder, path), json.load(open(os.path.join(folder, path)))


def close_to(v, ref, tol=0.02):
    return ref > 0 and abs(v / ref - 1.0) <= tol


# ── the variants: which plugin, which setting, what it does to the crest ─────────────────────

VARIANTS = [
    dict(name="built-in compressor", ident="compressor", fmt="TracktionInternal",
         index=4, value=-10.0, other=-5.0, ratio=0.316, rtol=0.03, full=True),
]


def available_external():
    a = App()
    try:
        r = a.cmd("plugin.list_available", filter="pro-q")
        return any(p["identifier"] == EXTERNAL for p in r["plugins"])
    finally:
        a.close()


def run_variant(v):
    print("\n── %s ─────────────────────────────────────────────" % v["name"])
    base = os.path.join(TMP, v["name"].replace(" ", "_"))
    healthy, corrupt = os.path.join(base, "healthy"), os.path.join(base, "corrupt")
    os.makedirs(healthy)

    # ── 1. a healthy session: A and B share a bin, C is ordinary, D is dry ─────────────────
    p1 = App()
    try:
        p1.cmd("project.new")
        A = p1.cmd("object.add", path=BIP, lane=0, start=0)["id"]
        B = p1.cmd("object.add", path=BIP, lane=1, start=0)["id"]
        C = p1.cmd("object.add", path=BIP, lane=2, start=0)["id"]
        D = p1.cmd("object.add", path=BIP, lane=3, start=0)["id"]
        objs = [A, B, C, D]
        pa = p1.cmd("plugin.add", host=A, identifier=v["ident"], format=v["fmt"])["plugin"]["id"]
        pc = p1.cmd("plugin.add", host=C, identifier=v["ident"], format=v["fmt"])["plugin"]["id"]
        link = p1.cmd("fxlink.create", host=A, plugins=[pa])["id"]
        p1.cmd("fxlink.attach", link=link, host=B)
        p1.idle()
        ia, ib = p1.block_inst(A), p1.block_inst(B)
        p1.cmd("plugin.set_param", plugin=ia, index=v["index"], value=v["value"])
        p1.cmd("plugin.set_param", plugin=pc, index=v["index"], value=v["value"])
        p1.idle()
        p1.unmute_all(objs)
        p1.cmd("project.save_as", path=os.path.join(healthy, "p.objekat"))
        p1.idle()
    finally:
        p1.close()

    # The reference is measured on a REOPENED healthy session, not on the one just built: a
    # project's first render differs from its reopened one by a flat 3 dB on these mono clips
    # (0.389 against 0.549 on `bip.wav`, seen with no plugin at all — an unrelated matter), and
    # everything below is a reopening, so that is what it has to be compared with.
    p1b = App()
    try:
        p1b.cmd("project.open", path=os.path.join(healthy, "p.objekat"))
        p1b.idle()
        check("[healthy] a sound session repairs nothing", p1b.repaired() == 0)
        objs = [o["id"] for o in p1b.cmd("object.list")["objects"]]
        dry = p1b.solo(objs, D, "h")
        dry0 = dry
        ref = {h: p1b.solo(objs, h, "h") for h in (A, B, C)}
        check("[healthy] the plugin really changes the crest (treated / dry = %.3f)" % (ref[A] / dry),
              abs(ref[A] / dry - v["ratio"]) <= v["rtol"] * v["ratio"] and ref[A] / dry < 0.5,
              "%s / %s" % (ref[A], dry))
        check("[healthy] A, B and C are all processed",
              close_to(ref[B], ref[A]) and close_to(ref[C], ref[A]), str(ref))
        aud = p1b.audit()
        check("[healthy] the audit finds no duplicate and no refusal",
              aud["count"] == 0 and aud["engine_foreign_refusals"] == 0, str(aud))
    finally:
        p1b.close()

    # ── 2. the corruption, in the shape found in the user's files ──────────────────────────
    shutil.copytree(healthy, corrupt)
    path, doc = load_json(corrupt)
    items = {o["id"]: o for o in doc["items"]}
    blk_a = next(p for p in items[A]["plugins"] if p.get("fxBlock"))
    blk_b_idx = next(i for i, p in enumerate(items[B]["plugins"]) if p.get("fxBlock"))
    dup_id = blk_a["fxBlock"]["plugins"][0]["id"]
    b_inst_id = items[B]["plugins"][blk_b_idx]["fxBlock"]["plugins"][0]["id"]
    forged = copy.deepcopy(blk_a)                       # A's entry, in B's chain, instead of B's own
    forged["id"] = str(uuid.uuid4()).upper()            # a NEW block id, the SAME instance ids
    items[B]["plugins"][blk_b_idx] = forged
    items[B]["automation"] = [{"param": {"type": "plugin", "pluginKey": dup_id, "paramID": "probe"},
                               "points": [{"t": 0.0, "v": 0.5, "c": 0.0}, {"t": 0.4, "v": 0.5, "c": 0.0}]}]
    json.dump(doc, open(path, "w"), indent=1)
    ids = walk_plugin_ids(doc["items"])
    check("[corruption] the forged session really carries the duplicate (once too many)",
          ids.count(dup_id) == 2 and b_inst_id != dup_id, "")

    # ── 3. a fresh process opens it: repaired ──────────────────────────────────────────────
    p2 = App()
    repaired_file = os.path.join(base, "repaired")
    try:
        p2.cmd("project.open", path=path)
        p2.idle()
        check("opening repairs exactly one id (last_load.repaired_plugin_ids)", p2.repaired() == 1,
              str(p2.cmd("project.load_status")))
        check("a repaired load leaves the project modified (app.info dirty)",
              p2.cmd("app.info").get("dirty") is True)
        aud = p2.audit()
        check("the audit finds no duplicate after the repair", aud["count"] == 0, str(aud))
        check("the engine refused nothing", aud["engine_foreign_refusals"] == 0, str(aud))
        objs = [o["id"] for o in p2.cmd("object.list")["objects"]]
        ia, ib = p2.block_inst(A), p2.block_inst(B)
        check("the repaired instance is a new id (the first host keeps the original)",
              ia == dup_id and ib != dup_id, "A=%s B=%s" % (ia, ib))
        la = p2.block(A)["plugins"][0].get("link_group")
        lb = p2.block(B)["plugins"][0].get("link_group")
        check("...and stays in the same link group", la is not None and la == lb, "%s / %s" % (la, lb))
        st = {o["id"]: o for o in p2.cmd("project.get_state")["items"]}
        lanes = st[B].get("automation", [])
        check("B's automation curve follows the new id",
              len(lanes) == 1 and lanes[0]["param"].get("pluginKey", "").upper() == ib.upper(),
              str(lanes))

        dry = p2.solo(objs, D, "r")
        now = {h: p2.solo(objs, h, "r") for h in (A, B, C)}
        check("A is processed (was: the victim of the theft)", close_to(now[A], ref[A]), "%s vs %s" % (now[A], ref[A]))
        check("B is processed", close_to(now[B], ref[B]), "%s vs %s" % (now[B], ref[B]))
        check("C is processed", close_to(now[C], ref[C]), "%s vs %s" % (now[C], ref[C]))
        check("D stays dry", close_to(dry, dry0), "%s vs %s" % (dry, dry0))

        if v["full"]:
            # the mirror
            p2.cmd("plugin.set_param", plugin=ia, index=v["index"], value=v["other"])
            p2.idle()
            got = p2.cmd("plugin.get_params", plugin=ib)["params"][v["index"]]["value"]
            check("the mirror is intact: a setting on A arrives on B", abs(got - v["other"]) < 1e-3, str(got))
            nb = p2.solo(objs, B, "m")
            want = dry * (10 ** (v["other"] / 20.0))
            check("...and B's render follows it", close_to(nb, want, 0.03), "%s vs %s" % (nb, want))
            p2.cmd("plugin.set_param", plugin=ia, index=v["index"], value=v["value"])
            p2.idle()

            # gestures that recompile a chain: nobody steals any more
            lk = p2.cmd("fxlink.list")["links"][0]["id"]

            def both(tag):
                pa_, pb_ = p2.solo(objs, A, tag), p2.solo(objs, B, tag)
                return close_to(pa_, ref[A]) and close_to(pb_, ref[B]), (pa_, pb_)

            p2.cmd("fxlink.set_enabled", link=lk, enabled=False)
            p2.cmd("fxlink.set_enabled", link=lk, enabled=True)
            p2.idle()
            ok, det = both("g1")
            check("bin off then on: A and B still processed", ok, str(det))
            for host, nm in ((A, "A"), (B, "B")):
                p2.cmd("fxlink.detach", host=host, link=lk)
                p2.idle()
                p2.cmd("fxlink.reattach", host=host, link=lk)
                p2.idle()
                ok, det = both("g_" + nm)
                check("detach / reattach %s: A and B still processed" % nm, ok, str(det))
            aud = p2.audit()
            check("the audit stays clean after the gestures",
                  aud["count"] == 0 and aud["engine_foreign_refusals"] == 0, str(aud))

            # a save writes the repaired model; reopening repairs nothing
            p2.unmute_all(objs)
            os.makedirs(repaired_file, exist_ok=True)
            p2.cmd("project.save_as", path=os.path.join(repaired_file, "p.objekat"))
            p2.idle()
            rpath, rdoc = load_json(repaired_file)
            rids = walk_plugin_ids(rdoc["items"])
            check("the saved file carries no duplicate any more", len(rids) == len(set(rids)),
                  "%d ids, %d distinct" % (len(rids), len(set(rids))))
            ritems = {o["id"]: o for o in rdoc["items"]}
            rb = ritems[B]["plugins"][blk_b_idx]["fxBlock"]["plugins"][0]["id"]
            check("the saved automation aims at B's new instance id",
                  [l["param"].get("pluginKey", "").upper() for l in ritems[B].get("automation", [])] == [rb.upper()],
                  str(ritems[B].get("automation")))
    finally:
        p2.close()

    if v["full"]:
        p3 = App()
        try:
            p3.cmd("project.open", path=rpath)
            p3.idle()
            check("reopening the repaired file repairs nothing", p3.repaired() == 0)
            check("...and leaves the project clean (app.info dirty)", p3.cmd("app.info").get("dirty") is False)
            objs = [o["id"] for o in p3.cmd("object.list")["objects"]]
            again = {h: p3.solo(objs, h, "o") for h in (A, B, C)}
            check("...and the renders are the same",
                  all(close_to(again[h], ref[h]) for h in (A, B, C)), "%s vs %s" % (again, ref))
        finally:
            p3.close()

        # ── 7. the engine's net, with the repair switched off ─────────────────────────────
        p4 = App(env={"OBJ_NO_PLUGIN_ID_REPAIR": "1"})
        try:
            p4.cmd("project.open", path=path)
            p4.idle()
            check("[net] the repair is off (repaired_plugin_ids == 0)", p4.repaired() == 0)
            aud = p4.audit()
            check("[net] the model still holds the duplicate (audit count >= 1)", aud["count"] >= 1, str(aud))
            check("[net] the engine refused the second claim (engine_foreign_refusals >= 1)",
                  aud["engine_foreign_refusals"] >= 1, str(aud))
            objs = [o["id"] for o in p4.cmd("object.list")["objects"]]
            dry = p4.solo(objs, D, "n")
            na, nb = p4.solo(objs, A, "n"), p4.solo(objs, B, "n")
            check("[net] the first host keeps the instance (A processed)", close_to(na, ref[A]), "%s vs %s" % (na, ref[A]))
            check("[net] the second plays dry, it does not steal (B dry)", close_to(nb, dry, 0.03), "%s vs %s" % (nb, dry))
            lk = p4.cmd("fxlink.list")["links"][0]["id"]
            p4.cmd("fxlink.detach", host=B, link=lk)
            p4.idle()
            p4.cmd("fxlink.reattach", host=B, link=lk)
            p4.idle()
            na2 = p4.solo(objs, A, "n2")
            check("[net] detach / reattach B no longer steals A's instance", close_to(na2, ref[A]), "%s vs %s" % (na2, ref[A]))
            p4.cmd("fxlink.detach", host=A, link=lk)
            p4.idle()
            p4.cmd("fxlink.reattach", host=A, link=lk)
            p4.idle()
            na3 = p4.solo(objs, A, "n3")
            check("[net] the owner can still recompile its own chain (A processed)",
                  close_to(na3, ref[A]), "%s vs %s" % (na3, ref[A]))
        finally:
            p4.close()


def run_external_opening(name, ident, fmt, index, value, ratio):
    """The opening test alone, on an AudioUnit: healthy ratio, corrupt, open, each member treated."""
    v = dict(name=name, ident=ident, fmt=fmt, index=index, value=value, other=value, ratio=ratio,
             rtol=0.06, full=False)
    run_variant(v)


try:
    probe = App()
    try:
        names = [c["name"] if isinstance(c, dict) else c for c in probe.cmd("help")["commands"]]
    finally:
        probe.close()
    if "debug.plugin_id_audit" not in names:
        print("SKIP: no `debug.*` commands in this build (DEBUG only)")
        sys.exit(0)

    for v in VARIANTS:
        run_variant(v)

    if available_external():
        run_external_opening("Pro-Q 4", EXTERNAL, "AudioUnit", 558, 0.2, 0.083)
    else:
        print("\nnote  %s not installed: the AudioUnit variant is skipped" % EXTERNAL)
finally:
    if not KEEP:
        shutil.rmtree(TMP, ignore_errors=True)
    else:
        print("kept: " + TMP)

print("\n%d/%d passed" % (total - len(fails), total))
if fails:
    print("FAILURES:")
    for f in fails:
        print(" - " + f)
    sys.exit(1)

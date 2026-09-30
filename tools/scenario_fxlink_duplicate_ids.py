#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Plugin ids duplicated between hosts — a scenario that ASSERTS (1 October 2026, v2).

    ./scenario_fxlink_duplicate_ids.py [path/to/objekat.app] [--external=aumf,FQ4p,FabF] [--keep]

It LAUNCHES its own headless processes (`--headless --api --no-audio --no-recent`), one fresh one
per opening — a fresh process is part of the proof: the engine's plugin map must not be able to
hide anything a previous project left in it. DEBUG build only (`debug.plugin_id_audit`): SKIP, exit
0, if the build has no `debug.*` commands.

The bug it guards. `ObjectPlugin.id` is the engine's plugin key, and the engine holds ONE instance per
key. A session whose JSON was touched outside the app — FX link block entries copied from one
object to another with a fresh block id but the SAME instance ids — carried the same key under
two hosts: the last chain to compile moved the instance out of the first host's chain, which then
played DRY, silently.

v2: the load DETECTS and never repairs on its own. The decision is the user's — the alert's
"Repair" button, or `repair_plugin_ids: true` on `project.open` / `tab.open`. A project opened
without repair keeps its duplicates, and the engine copes (`_pluginOwnerHost`: the first host to
compile a key keeps the instance, the others play without it, and every operation addressed by
(key, host) is refused for a foreign host).

The session built here: A and B share a bin, C carries an ordinary plugin, D is dry, E sits in a
group, F is routed through a stem. The corruption is the shape found in the user's files (B's block
is A's, with a NEW block id and the SAME instance ids; an automation curve and a touch entry of B aim
at the duplicated instance), plus one more copy of C's plugin in E's chain (a group child) and one in
the stem's chain: 2 duplicated ids, 3 copies to fix.

  PATH A — `project.open` with no option, a fresh process:
    detection (`last_load.duplicate_plugin_id_count`, `duplicate_plugin_ids` whose `json_path`
    resolve in the file on disk, `keeps_id` only on the first site), the LLM report, a project
    that stays clean and a file that stays byte for byte the same, no dialogue (the API never
    asks), the audit and the engine's net: ONE owner per id, which never changes through the
    gestures that used to steal (toggle, remove, bin off/on, detach/reattach, undo, delete the
    dry object). Then a Python "language model" applies the report's steps to a COPY of the file,
    which reopens with no duplicate at all and is otherwise identical.
  PATH B — `project.open {repair_plugin_ids: true}`, a fresh process:
    repaired (3 ids re-keyed), project modified, file untouched until saved, every host processed,
    the mirror intact, a saved file with no `id` value repeated anywhere, reopening clean.
  PATH C — `tab.open` both ways; a tab switch and back repairs and asks nothing more.

Never `transport.play` (the real audio device may open despite `--no-audio`); exports are 24-bit
WAVs re-read at peak; the pasteboard is never touched ("Copy report" is the alert's own button and
no test reaches it). Nothing is written outside a temporary folder.

Exit: 0 if every assertion passes (or SKIP), 1 otherwise.
"""

import copy, hashlib, json, os, re, shutil, subprocess, sys, tempfile, time, uuid, wave

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


def md5(path):
    return hashlib.md5(open(path, "rb").read()).hexdigest()


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

    def audit(self):
        return self.cmd("debug.plugin_id_audit")

    def last_load(self):
        return self.cmd("project.load_status").get("last_load", {})

    def repaired(self):
        return self.last_load().get("repaired_plugin_ids")

    def dirty(self):
        return self.cmd("app.info").get("dirty")

    def dialogs(self):
        return self.cmd("app.dialogs")["dialogs"]

    def alive(self):
        return self.proc.poll() is None and bool(self.cmd("app.info"))


# ── the session file, read as plain JSON ─────────────────────────────────────────────────────

def scan_duplicates(doc):
    """Every plugin id held more than once in the FILE, in the order the app walks it (an object's
    chain, then its instruments, then its children; the stems last), each with its sites
    [(json_path, host_id)] — `sites[0]` is the entry that keeps its id. The same walk as
    `PluginIDUniqueness.duplicateDetails`, written again here on purpose."""
    sites, order = {}, []

    def add(pid, path, host):
        if pid not in sites:
            order.append(pid)
            sites[pid] = []
        sites[pid].append((path, host))

    def chain(ps, path, host):
        for k, p in enumerate(ps or []):
            here = "%s[%d]" % (path, k)
            add(p["id"], here, host)
            rack = p.get("rack")
            if rack:
                for v, voice in enumerate(rack.get("voices", [])):
                    chain(voice, "%s.rack.voices[%d]" % (here, v), host)
            elif p.get("fxBlock"):
                chain(p["fxBlock"].get("plugins"), here + ".fxBlock.plugins", host)

    def objs(arr, path):
        for i, o in enumerate(arr):
            here = "%s[%d]" % (path, i)
            chain(o.get("plugins"), here + ".plugins", o["id"])
            chain(o.get("instruments"), here + ".instruments", o["id"])
            kids = (o.get("kind") or {}).get("children")
            if kids:
                objs(kids, here + ".kind.children")

    objs(doc["items"], "items")
    for s, st in enumerate(doc.get("stems") or []):
        chain(st.get("plugins"), "stems[%d].plugins" % s, st["id"])
    return [(i, sites[i]) for i in order if len(sites[i]) > 1]


def resolve(doc, path):
    """`items[3].kind.children[1].plugins[0].fxBlock.plugins[2]` → the JSON object it names."""
    node = doc
    for name, index in re.findall(r"([A-Za-z_]+)|\[(\d+)\]", path):
        node = node[name] if name else node[int(index)]
    return node


def owner_of(path):
    """The object (or stem) whose chain a path points into: the prefix before `.plugins` /
    `.instruments`. A stem has no automation."""
    m = re.match(r"^(items\[\d+\](?:\.kind\.children\[\d+\])*|stems\[\d+\])\.(?:plugins|instruments)", path)
    return m.group(1)


def find_object(doc, oid):
    def walk(arr):
        for o in arr:
            if o["id"] == oid:
                return o
            kids = (o.get("kind") or {}).get("children")
            if kids:
                r = walk(kids)
                if r:
                    return r
        return None
    return walk(doc["items"])


def all_id_values(node, out=None):
    """Every value of an `id` key, anywhere in the JSON (the `_readme` rule: unique in the project)."""
    out = [] if out is None else out
    if isinstance(node, dict):
        for k, v in node.items():
            if k == "id" and isinstance(v, str):
                out.append(v)
            else:
                all_id_values(v, out)
    elif isinstance(node, list):
        for v in node:
            all_id_values(v, out)
    return out


def load_json(folder):
    path = os.path.join(folder, [f for f in os.listdir(folder) if f.endswith(".objekat")][0])
    return path, json.load(open(path))


def diff_paths(a, b, path=""):
    """Every leaf path where two JSON documents differ."""
    if type(a) != type(b):
        return [path]
    if isinstance(a, dict):
        out = []
        for k in sorted(set(a) | set(b)):
            if k not in a or k not in b:
                out.append("%s.%s" % (path, k))
            else:
                out += diff_paths(a[k], b[k], "%s.%s" % (path, k))
        return out
    if isinstance(a, list):
        if len(a) != len(b):
            return [path + "[len]"]
        out = []
        for i, (x, y) in enumerate(zip(a, b)):
            out += diff_paths(x, y, "%s[%d]" % (path, i))
        return out
    return [] if a == b else [path]


def report_file(report):
    """The path the report names on its `File:` line."""
    m = re.search(r"^File: (.*)$", report, re.M)
    return m.group(1) if m else None


def llm_fix(doc, report):
    """A "language model" that follows the report LITERALLY, steps 3 to 5: a new uppercase UUID for
    every entry marked FIX, and, in the SAME object, the old id replaced by the new one in
    automation[].param.pluginKey and automationTouch[].pluginKey. Nothing else is touched. Returns
    the list of (old, new, path) it applied."""
    fixes, cur_id, cur_kind = [], None, None
    for line in report.splitlines():
        m = re.match(r"^\d+\. id ([0-9A-Fa-f-]{36})", line)
        if m:
            cur_id = m.group(1)
            continue
        m = re.match(r"^   (KEEP|FIX ) ", line)
        if m:
            cur_kind = m.group(1).strip()
            continue
        m = re.match(r"^\s+path: (\S+)\s*$", line)
        if m and cur_kind == "FIX":
            fixes.append((cur_id, m.group(1)))
    applied = []
    for old, path in fixes:
        entry = resolve(doc, path)
        assert entry["id"] == old, "the report's path does not hold the id it names: " + path
        new = str(uuid.uuid4()).upper()
        entry["id"] = new
        owner = owner_of(path)
        if owner.startswith("items"):
            host = resolve(doc, owner)
            for lane in host.get("automation", []) or []:
                if lane["param"].get("pluginKey") == old:
                    lane["param"]["pluginKey"] = new
            for ref in host.get("automationTouch", []) or []:
                if ref.get("pluginKey") == old:
                    ref["pluginKey"] = new
        applied.append((old, new, path))
    return applied


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


class Session:
    """The healthy session and what the corruption made of it."""
    pass


def build_healthy(v, folder):
    """A, B share a bin; C plain; D dry; E a plain plugin on a group child; F through a stem that
    carries a plugin. Saved in `folder`, then REOPENED in another process to take the reference
    renders: a project's first render differs from its reopened one by a flat 3 dB on these mono clips
    (seen with no plugin at all — an unrelated matter), and everything below is a reopening."""
    S = Session()
    p1 = App()
    try:
        p1.cmd("project.new")
        S.A, S.B, S.C, S.D, S.E, S.F = [p1.cmd("object.add", path=BIP, lane=i, start=0)["id"]
                                        for i in range(6)]
        pa = p1.cmd("plugin.add", host=S.A, identifier=v["ident"], format=v["fmt"])["plugin"]["id"]
        S.pc = p1.cmd("plugin.add", host=S.C, identifier=v["ident"], format=v["fmt"])["plugin"]["id"]
        S.pe = p1.cmd("plugin.add", host=S.E, identifier=v["ident"], format=v["fmt"])["plugin"]["id"]
        link = p1.cmd("fxlink.create", host=S.A, plugins=[pa])["id"]
        p1.cmd("fxlink.attach", link=link, host=S.B)
        S.stem = p1.cmd("stem.add", name="Bus")["id"]
        S.ps = p1.cmd("plugin.add", host=S.stem, identifier=v["ident"], format=v["fmt"])["plugin"]["id"]
        p1.cmd("stem.assign", stem=S.stem, ids=[S.F])
        p1.cmd("group.create", ids=[S.E])
        p1.idle()
        ia = p1.block_inst(S.A)
        for pid in (ia, S.pc, S.pe, S.ps):
            p1.cmd("plugin.set_param", plugin=pid, index=v["index"], value=v["value"])
        p1.idle()
        S.objs = [S.A, S.B, S.C, S.D, S.E, S.F]
        p1.unmute_all(S.objs)
        p1.cmd("project.save_as", path=os.path.join(folder, "p.objekat"))
        p1.idle()
    finally:
        p1.close()

    p1b = App()
    try:
        p1b.cmd("project.open", path=os.path.join(folder, "p.objekat"))
        p1b.idle()
        check("[healthy] a sound session has no duplicate and repairs nothing",
              p1b.repaired() == 0 and p1b.last_load().get("duplicate_plugin_id_count") == 0
              and p1b.last_load().get("plugin_id_report") is None and p1b.audit()["count"] == 0)
        check("[healthy] ...and stays clean (not modified)", p1b.dirty() is False)
        S.dry0 = p1b.solo(S.objs, S.D, "h")
        S.ref = {h: p1b.solo(S.objs, h, "h") for h in (S.A, S.B, S.C, S.E, S.F)}
        r = S.ref[S.A] / S.dry0
        check("[healthy] the plugin really changes the crest (treated / dry = %.3f)" % r,
              abs(r - v["ratio"]) <= v["rtol"] * v["ratio"] and r < 0.5, "%s / %s" % (S.ref[S.A], S.dry0))
        check("[healthy] A, B, C, E (group child) and F (stem) are all processed",
              all(close_to(S.ref[h], S.ref[S.A]) for h in S.ref), str(S.ref))
        aud = p1b.audit()
        check("[healthy] the audit finds no duplicate and no refusal",
              aud["count"] == 0 and aud["engine_foreign_refusals"] == 0, str(aud))
    finally:
        p1b.close()
    return S


def corrupt(S, healthy, folder):
    """The shape found in the user's files, plus a copy in a group child and one in a stem."""
    shutil.copytree(healthy, folder)
    path, doc = load_json(folder)
    a, b = find_object(doc, S.A), find_object(doc, S.B)
    blk_a = next(p for p in a["plugins"] if p.get("fxBlock"))
    bi = next(i for i, p in enumerate(b["plugins"]) if p.get("fxBlock"))
    S.dup_bin = blk_a["fxBlock"]["plugins"][0]["id"]
    S.b_own = b["plugins"][bi]["fxBlock"]["plugins"][0]["id"]
    forged = copy.deepcopy(blk_a)                    # A's entry in B's chain, instead of B's own
    forged["id"] = str(uuid.uuid4()).upper()         # a NEW block id, the SAME instance ids
    b["plugins"][bi] = forged
    probe = {"type": "plugin", "pluginKey": S.dup_bin, "paramID": "probe"}
    b["automation"] = [{"param": dict(probe), "points": [{"t": 0.0, "v": 0.5, "c": 0.0},
                                                         {"t": 0.4, "v": 0.5, "c": 0.0}]}]
    b["automationTouch"] = [dict(probe)]
    find_object(doc, S.E)["plugins"][0]["id"] = S.pc              # the group child copies C's plugin
    st = next(x for x in doc["stems"] if x["id"] == S.stem)
    st["plugins"][0]["id"] = S.pc                                 # and so does the stem
    json.dump(doc, open(path, "w"), indent=1)
    S.path, S.doc = path, doc
    S.expected = scan_duplicates(doc)
    S.copies = sum(len(sites) - 1 for _, sites in S.expected)
    S.md5 = md5(path)
    return S


def host_hosts(S):
    """Which render hosts each duplicated id can be heard on."""
    return {S.dup_bin: [S.A, S.B], S.pc: [S.C, S.E, S.F]}


def path_a(v, S, base):
    print("\n── path A: project.open with no option ───────────────────────────────────────")
    rep = None
    a = App()
    try:
        a.cmd("project.open", path=S.path)
        a.idle()
        ll = a.last_load()
        K = len(S.expected)
        check("[A] the file holds 2 duplicated ids and 3 copies (the corruption is what was intended)",
              K == 2 and S.copies == 3, "%d ids, %d copies" % (K, S.copies))
        check("[A] detected: last_load.duplicate_plugin_id_count == %d, repaired 0" % K,
              ll.get("duplicate_plugin_id_count") == K and ll.get("repaired_plugin_ids") == 0, str(ll))
        got = ll.get("duplicate_plugin_ids") or []
        check("[A] the ids, and their sites in file order, are the ones the file holds",
              [d["id"] for d in got] == [i for i, _ in S.expected]
              and [[s["json_path"] for s in d["sites"]] for d in got]
              == [[p for p, _ in sites] for _, sites in S.expected], str(got))
        check("[A] keeps_id is true on the first site of each id and only there",
              all([s["keeps_id"] for s in d["sites"]] == [True] + [False] * (len(d["sites"]) - 1) for d in got))
        check("[A] every json_path resolves, in the file on disk, to an entry holding the duplicated id",
              all(resolve(S.doc, s["json_path"])["id"] == d["id"] for d in got for s in d["sites"]))
        check("[A] host_id / host_kind agree with the file",
              all(s["host_id"] == h and s["host_kind"] == ("stem" if s["json_path"].startswith("stems") else "object")
                  for d, (_, sites) in zip(got, S.expected) for s, (_, h) in zip(d["sites"], sites)))
        check("[A] the bin's name is carried on the block's sites",
              any(s["fx_link"] for d in got for s in d["sites"]), str(got))
        rep = ll.get("plugin_id_report")
        check("[A] the report is a string naming the file that was opened",
              isinstance(rep, str) and report_file(rep) is not None
              and os.path.realpath(report_file(rep)) == os.path.realpath(S.path), str(rep)[:200])
        if isinstance(rep, str):
            lines = rep.splitlines()
            check("[A] ...with %d ids, %d KEEP and %d FIX" % (K, K, S.copies),
                  sum(1 for l in lines if re.match(r"^\d+\. id ", l)) == K
                  and sum(1 for l in lines if l.startswith("   KEEP")) == K
                  and sum(1 for l in lines if l.startswith("   FIX")) == S.copies)
            check("[A] ...and it is plain ASCII", all(ord(c) < 128 for c in rep))
        check("[A] the project is NOT modified (nothing was repaired)", a.dirty() is False)
        check("[A] the file on disk is unchanged", md5(S.path) == S.md5)
        check("[A] the API never asks: no dialogue raised, none journalled", a.dialogs() == [], str(a.dialogs()))
        aud = a.audit()
        check("[A] the audit still sees the duplicates in memory (count == %d)" % K, aud["count"] == K, str(aud))
        check("[A] the engine refused the foreign claims (engine_foreign_refusals >= 1)",
              aud["engine_foreign_refusals"] >= 1, str(aud))

        # which host is heard, per id — exactly one owner each
        hosts = host_hosts(S)
        dry = a.solo(S.objs, S.D, "a")
        now = {h: close_to(a.solo(S.objs, h, "a"), S.ref[h]) for hs in hosts.values() for h in hs}
        owners = {i: [h for h in hs if now[h]] for i, hs in hosts.items()}
        check("[A] each duplicated id is heard on exactly ONE host (first compiler owns)",
              all(len(o) == 1 for o in owners.values()), str(owners))
        check("[A] the others play without it (dry)",
              all(close_to(a.solo(S.objs, h, "a"), dry, 0.03) for i, hs in hosts.items()
                  for h in hs if h not in owners[i]))

        gone = set()    # objects the gestures delete

        def owners_now():
            live = [o for o in S.objs if o not in gone]
            cur = {h: close_to(a.solo(live, h, "g"), S.ref[h]) for hs in hosts.values() for h in hs if h not in gone}
            return {i: [h for h in hs if cur.get(h)] for i, hs in hosts.items()}

        # gestures on a dry copy: the owner stays heard, the process stays alive, the refusals count up
        dry_bin = next(h for h in (S.A, S.B) if h not in owners[S.dup_bin])
        dry_pc = next(h for h in (S.C, S.E, S.F) if h not in owners[S.pc])
        dry_pc_host = S.stem if dry_pc == S.F else dry_pc
        bin_inst = a.block_inst(dry_bin)
        link = a.cmd("fxlink.list")["links"][0]["id"]
        refusals = [a.audit()["engine_foreign_refusals"]]

        def gesture(label, act, strict):
            act()
            a.idle()
            cur = owners_now()
            expected = {i: [h for h in o if h not in gone] for i, o in owners.items()}
            n = a.audit()["engine_foreign_refusals"]
            check("[A] after %s: the owners are unchanged, the process is alive" % label,
                  cur == expected and a.alive(), "%s vs %s" % (cur, expected))
            if strict:
                check("[A] ...and the engine refused something more (%d -> %d)" % (refusals[-1], n),
                      n > refusals[-1])
            else:
                check("[A] ...and the refusals did not go down (%d -> %d)" % (refusals[-1], n), n >= refusals[-1])
            refusals.append(n)

        # An attached bin instance is the BIN's: toggling it silences every member, the owner
        # included — that is the gesture's meaning, not a theft. Off then on, then look.
        gesture("plugin.toggle (off, then on) of the dry bin instance",
                lambda: (a.cmd("plugin.toggle", host=dry_bin, plugin=bin_inst),
                         a.cmd("plugin.toggle", host=dry_bin, plugin=bin_inst)), True)
        gesture("plugin.toggle of the dry copy of C's plugin",
                lambda: a.cmd("plugin.toggle", host=dry_pc_host, plugin=S.pc), True)
        gesture("plugin.remove of the dry copy of C's plugin",
                lambda: a.cmd("plugin.remove", host=dry_pc_host, plugin=S.pc), True)
        gesture("fxlink.set_enabled false then true",
                lambda: (a.cmd("fxlink.set_enabled", link=link, enabled=False),
                         a.cmd("fxlink.set_enabled", link=link, enabled=True)), False)
        gesture("fxlink.detach then reattach of the dry host",
                lambda: (a.cmd("fxlink.detach", host=dry_bin, link=link), a.idle(),
                         a.cmd("fxlink.reattach", host=dry_bin, link=link)), False)

        def undo_all():
            for _ in range(10):
                if a.refused("edit.undo") is not None:
                    break
                a.idle()
        gesture("edit.undo of all of the above", undo_all, False)

        def delete(oid):
            gone.add(oid)
            a.cmd("object.remove", ids=[oid])
        gesture("deleting the dry object of the bin", lambda: delete(dry_bin), False)
        if dry_pc != S.F:
            gesture("deleting the dry object of C's plugin", lambda: delete(dry_pc), False)
        a.cmd("project.new")
        a.idle()
        check("[A] the file on disk is unchanged after all of it and after project.new",
              md5(S.path) == S.md5 and a.alive())
    finally:
        a.close()

    # ── the language model's pass ────────────────────────────────────────────────────────
    print("\n── path A, step 9: a language model follows the report ────────────────────────")
    if not isinstance(rep, str):
        check("[LLM] a report to follow", False)
        return
    fixed = os.path.join(base, "llm")
    shutil.copytree(os.path.dirname(S.path), fixed)
    fpath, fdoc = load_json(fixed)
    original = copy.deepcopy(fdoc)
    applied = llm_fix(fdoc, rep)
    json.dump(fdoc, open(fpath, "w"), indent=1)
    check("[LLM] the report's FIX entries were all applied (%d)" % S.copies, len(applied) == S.copies)
    check("[LLM] the fixed file has no duplicated plugin id left", scan_duplicates(fdoc) == [])
    changed = sorted(diff_paths(original, fdoc))
    check("[LLM] only ids and pluginKeys differ from the original",
          all(c.endswith(".id") or c.endswith(".pluginKey") for c in changed), str(changed))
    check("[LLM] exactly the FIX entries' ids changed (%d)" % S.copies,
          sum(1 for c in changed if c.endswith(".id")) == S.copies, str(changed))
    f = App()
    try:
        f.cmd("project.open", path=fpath)
        f.idle()
        check("[LLM] reopened with no option: no duplicate, nothing repaired",
              f.last_load().get("duplicate_plugin_id_count") == 0 and f.repaired() == 0
              and f.last_load().get("plugin_id_report") is None)
        check("[LLM] ...the project is clean and no dialogue was raised", f.dirty() is False and f.dialogs() == [])
        aud = f.audit()
        check("[LLM] ...audit 0 and no refusal", aud["count"] == 0 and aud["engine_foreign_refusals"] == 0, str(aud))
        all_heard = {h: close_to(f.solo(S.objs, h, "l"), S.ref[h]) for h in S.ref}
        check("[LLM] ...every host is processed", all(all_heard.values()), str(all_heard))
        new_b = next(n for o, n, p in applied if o == S.dup_bin)
        st = {o["id"]: o for o in f.cmd("project.get_state")["items"]}
        lanes = st[S.B].get("automation", [])
        check("[LLM] ...B's automation follows the new id",
              len(lanes) == 1 and lanes[0]["param"].get("pluginKey", "").upper() == new_b.upper(), str(lanes))
    finally:
        f.close()


def path_b(v, S, base):
    print("\n── path B: project.open {repair_plugin_ids: true} ───────────────────────────────")
    b = App()
    try:
        b.cmd("project.open", path=S.path, repair_plugin_ids=True)
        b.idle()
        ll = b.last_load()
        K = len(S.expected)
        check("[B] repaired_plugin_ids == %d (one per copy)" % S.copies, ll.get("repaired_plugin_ids") == S.copies, str(ll))
        check("[B] duplicate_plugin_ids still describes what the file held",
              ll.get("duplicate_plugin_id_count") == K
              and [d["id"] for d in ll.get("duplicate_plugin_ids", [])] == [i for i, _ in S.expected])
        check("[B] the project is modified, the file on disk is not", b.dirty() is True and md5(S.path) == S.md5)
        check("[B] no dialogue", b.dialogs() == [])
        aud = b.audit()
        check("[B] audit 0, no refusal", aud["count"] == 0 and aud["engine_foreign_refusals"] == 0, str(aud))
        heard = {h: close_to(b.solo(S.objs, h, "b"), S.ref[h]) for h in S.ref}
        check("[B] A, B, C, E (group child) and F (stem) are all processed", all(heard.values()), str(heard))
        check("[B] D stays dry", close_to(b.solo(S.objs, S.D, "b"), S.dry0, 0.03))
        ia, ib = b.block_inst(S.A), b.block_inst(S.B)
        check("[B] the first host keeps the original id, the copy has a new one",
              ia == S.dup_bin and ib != S.dup_bin, "A=%s B=%s" % (ia, ib))
        lanes = {o["id"]: o for o in b.cmd("project.get_state")["items"]}[S.B].get("automation", [])
        check("[B] B's automation follows the new id",
              len(lanes) == 1 and lanes[0]["param"].get("pluginKey", "").upper() == ib.upper(), str(lanes))
        if v["full"]:
            p0 = b.solo(S.objs, S.D, "m")
            b.cmd("plugin.set_param", plugin=ia, index=v["index"], value=v["other"])
            b.idle()
            got = b.cmd("plugin.get_params", plugin=ib)["params"][v["index"]]["value"]
            check("[B] the mirror is intact: a setting on A arrives on B", abs(got - v["other"]) < 1e-3, str(got))
            nb = b.solo(S.objs, S.B, "m")
            want = p0 * (10 ** (v["other"] / 20.0))
            check("[B] ...and B's render follows it", close_to(nb, want, 0.03), "%s vs %s" % (nb, want))
            b.cmd("plugin.set_param", plugin=ia, index=v["index"], value=v["value"])
            b.idle()
            lk = b.cmd("fxlink.list")["links"][0]["id"]

            def both(tag):
                pa_, pb_ = b.solo(S.objs, S.A, tag), b.solo(S.objs, S.B, tag)
                return close_to(pa_, S.ref[S.A]) and close_to(pb_, S.ref[S.B]), (pa_, pb_)

            b.cmd("fxlink.set_enabled", link=lk, enabled=False)
            b.cmd("fxlink.set_enabled", link=lk, enabled=True)
            b.idle()
            ok, det = both("g1")
            check("[B] bin off then on: A and B still processed", ok, str(det))
            for host, nm in ((S.A, "A"), (S.B, "B")):
                b.cmd("fxlink.detach", host=host, link=lk)
                b.idle()
                b.cmd("fxlink.reattach", host=host, link=lk)
                b.idle()
                ok, det = both("g_" + nm)
                check("[B] detach / reattach %s: A and B still processed" % nm, ok, str(det))
            aud = b.audit()
            check("[B] the audit stays clean after the gestures",
                  aud["count"] == 0 and aud["engine_foreign_refusals"] == 0, str(aud))
            check("[B] the file on disk is still unchanged before saving", md5(S.path) == S.md5)
            b.unmute_all(S.objs)
            saved = os.path.join(base, "saved")
            os.makedirs(saved, exist_ok=True)
            b.cmd("project.save_as", path=os.path.join(saved, "p.objekat"))
            b.idle()
            spath, sdoc = load_json(saved)
            ids = all_id_values(sdoc)
            check("[B] the saved file repeats no `id` value anywhere", len(ids) == len(set(ids)),
                  "%d ids, %d distinct" % (len(ids), len(set(ids))))
            check("[B] ...and holds no duplicated plugin id", scan_duplicates(sdoc) == [])
            readme = sdoc.get("_readme")
            check("[B] the _readme carries the IDS section", "IDS —" in json.dumps(readme, ensure_ascii=False))
            b_saved = find_object(sdoc, S.B)
            new_b = next(p for p in b_saved["plugins"] if p.get("fxBlock"))["fxBlock"]["plugins"][0]["id"]
            check("[B] ...and B's saved automation and touch aim at its new instance id",
                  [l["param"].get("pluginKey", "").upper() for l in b_saved.get("automation", [])] == [new_b.upper()]
                  and [t.get("pluginKey", "").upper() for t in b_saved.get("automationTouch", [])] == [new_b.upper()],
                  str((b_saved.get("automation"), b_saved.get("automationTouch"))))
            S.saved = spath
    finally:
        b.close()
    if v["full"]:
        r = App()
        try:
            r.cmd("project.open", path=S.saved)
            r.idle()
            check("[B] reopening the saved file: no duplicate, nothing repaired, clean, no dialogue",
                  r.last_load().get("duplicate_plugin_id_count") == 0 and r.repaired() == 0
                  and r.dirty() is False and r.dialogs() == [])
            again = {h: close_to(r.solo(S.objs, h, "o"), S.ref[h]) for h in S.ref}
            check("[B] ...and every host is processed", all(again.values()), str(again))
        finally:
            r.close()


def path_c(v, S, base):
    print("\n── path C: tabs ─────────────────────────────────────────────────────────────")
    K = len(S.expected)
    for repair in (False, True):
        t = App()
        tag = "[C %s]" % ("repair" if repair else "keep")
        try:
            first = t.cmd("tab.list")["tabs"][0]["id"]
            params = dict(path=S.path)
            if repair:
                params["repair_plugin_ids"] = True
            t.cmd("tab.open", **params)
            t.idle()
            ll = t.last_load()
            if repair:
                check(tag + " tab.open repaired every copy", ll.get("repaired_plugin_ids") == S.copies, str(ll))
                check(tag + " ...the tab is modified and the audit is clean",
                      t.dirty() is True and t.audit()["count"] == 0)
            else:
                check(tag + " tab.open left the duplicates (count == %d, repaired 0)" % K,
                      ll.get("duplicate_plugin_id_count") == K and ll.get("repaired_plugin_ids") == 0, str(ll))
                check(tag + " ...the tab is clean and the audit sees the duplicates",
                      t.dirty() is False and t.audit()["count"] == K)
                rep = ll.get("plugin_id_report")
                check(tag + " ...and the report names the file",
                      isinstance(rep, str) and os.path.realpath(report_file(rep) or "") == os.path.realpath(S.path))
            audit0 = t.audit()["count"]
            check(tag + " no dialogue", t.dialogs() == [])
            # to the other tab and back: a restoration neither asks nor repairs
            t.cmd("tab.select", id=first)
            t.idle()
            second = next(x["id"] for x in t.cmd("tab.list")["tabs"] if x["id"] != first)
            t.cmd("tab.select", id=second)
            t.idle()
            check(tag + " back on the tab: the same duplicates, nothing repaired, no dialogue",
                  t.audit()["count"] == audit0 and t.dialogs() == [] and t.alive(),
                  "%s vs %s" % (t.audit()["count"], audit0))
            check(tag + " ...and the dirty state is what it was", t.dirty() is repair)
            check(tag + " the file on disk is unchanged", md5(S.path) == S.md5)
        finally:
            t.close()


def run_variant(v):
    print("\n── %s ─────────────────────────────────────────────" % v["name"])
    base = os.path.join(TMP, v["name"].replace(" ", "_"))
    healthy = os.path.join(base, "healthy")
    os.makedirs(healthy)
    S = build_healthy(v, healthy)
    corrupt(S, healthy, os.path.join(base, "corrupt"))
    check("[corruption] the forged file really carries duplicates (and B's own instance id is distinct)",
          len(S.expected) == 2 and S.b_own != S.dup_bin, str(S.expected))
    if v["full"]:
        path_a(v, S, base)
    path_b(v, S, base)
    if v["full"]:
        path_c(v, S, base)


def run_external_opening(name, ident, fmt, index, value, ratio):
    """Path B alone, on an AudioUnit: healthy ratio, corrupt, open repaired, every host treated."""
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

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""FX link settings survive open + save — a scenario that ASSERTS.

    ./scenario_fxlink_state_persistence.py --app=/path/to/objekat.app [--trials=8] [--jobs=3]
        [--cases=a,b,c,d,e,f] [--work=DIR] [--seed=N] [--fixture-app=/path/to/other.app]
        [--wait=8] [--real=/tmp/copy/of/a/project.objekat] [--keep]

DEBUG build only (it drives `debug.plugin_force_processor_changed`, `debug.plugin_inject_state`).
Unlike its siblings this scenario takes an APP, not a socket: the bug it guards is a RACE of the
first load of a process, so every trial launches its own headless instance
(`--headless --api --no-audio --no-recent`, one socket per instance in /tmp), opens a COPY of a small
synthetic project, and kills it. Nothing of the user's is ever written.

THE BUG. After a load, an AudioUnit can announce late that its "present preset" changed
(`kAudioUnitProperty_PresentPreset`, which JUCE turns into `audioProcessorChanged(programChanged)`).
Tracktion (ExternalPlugin::ProcessorChangedManager) used to react by rebuilding the JUCE parameter
list unconditionally; the recreated parameters hold their DEFAULT value, which
`refreshParameterValues()` then announced as "changed by the plugin"; the FX link's parameter
mirror carried it BY INDEX to the whole group, so the factory settings landed in the other
members' AudioUnits, and the next save froze them (and the bin's definition follows its first
member). Engine patch 0035 only rebuilds the list when the plugin says the LIST changed.

HOW IT IS MADE DETERMINISTIC. The notification is a race in the wild (it arrives ~50 ms after the
load settles, or not, depending on the load). `debug.plugin_force_processor_changed {plugin}` makes
the instance emit exactly that notification, so a trial can fire it on chosen members after the load
has settled: without the patch it corrupts the group EVERY time, with the patch it moves nothing.
The command emulates the two steps JUCE takes on a real "present preset" (re-hand the unit its own
state, lift the values JUCE re-read into Tracktion's parameters), then posts the notification 300 ms
later: the Tracktion parameters must hold the REAL values at that moment (as they do in the wild,
because the unit's own parameter events arrive first), otherwise a rebuilt list announces no change
and nothing is carried. Measured on PHA-979: DelayL/DelayR -> 0 ms, PhaseL -> 0, the definition
following. Pro-Q 4 does not corrupt under this emulation (as in the wild: its list is never rebuilt
late); its chunk is still compared in every case.
The statistical mode (no forcing, a wait, then a save) is kept as a second opinion, but on a small
synthetic project the race rarely shows (see the report of the run).

HOW IT READS. Never `plugin.get_params` (it reads Tracktion's cache, which is wrong after exactly this
bug). It reads `plugin.get_state`, the chunk the AudioUnit itself hands back, DECODED here:
PHA-979 (`aufx,1565,Vxng`): bplist -> "VoxPluginState" -> 'aprs' + zlib -> its numeric records;
Pro-Q 4 (`aumf,FQ4p,FabF`): the 576 floats of "FabFilterPluginState" from byte 12 (never the raw bytes:
the instance label changes without the setting changing). The saved file is read the same way,
instance by instance and definition by definition, with a tolerance of 1e-6.

CASES (each repeated --trials times, a fresh process per trial; the mutation steps run once, then
their result is re-opened --trials times):
  (a) open + save of PHA-979 and Pro-Q 4 links, nothing touched (forced; plus a statistical run);
  (b) change a parameter on the LAST member of a link, save, re-open: every instance AND the
      definition carry the change, and nothing else moved;
  (c) attach / detach (+ edit the detached one) / reattach / remove_block, each saved and re-opened;
  (d) duplicate and copy-paste a linked group: the original does not move, the copy follows the bin;
  (e) three open + save cycles in a row end in the same values as the first;
  (f) ~100 instances (8 PHA links x 10 + 2 Pro-Q links x 10): forced on 10 random members per
      trial, plus statistical trials, and the load time as a performance guard-rail.
  (r) with --real=PATH: an open + save of a COPY of a real project (refused outside a temp dir).

Fixtures are built by --fixture-app (default: --app). To judge a build WITHOUT the patch, build the
fixtures with a patched one: an unpatched builder can corrupt its own fixture, which is itself a
symptom (and is reported).

Exit: 0 if every assertion passes (or a plugin is not installed / not a DEBUG build: SKIP), 1 on a
failure, 2 on a usage error.
"""

import base64, concurrent.futures, json, os, plistlib, random, re, shutil, signal, socket, struct
import subprocess, sys, tempfile, time, zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

BIP = os.path.join(HERE, "fixtures", "bip.wav")
PHA = "aufx,1565,Vxng"
PROQ = "aumf,FQ4p,FabF"
TOL = 1e-6

# ── command line ──────────────────────────────────────────────────────────────────────────────
opts = {"trials": "8", "jobs": "3", "cases": "a,b,c,d,e,f", "seed": "20261004", "wait": "8"}
for a in sys.argv[1:]:
    if a in ("-h", "--help"):
        print(__doc__)
        sys.exit(0)
    if not a.startswith("--"):
        print("unexpected argument: " + a)
        sys.exit(2)
    k, _, v = a[2:].partition("=")
    opts[k] = v if _ else "1"
if "app" not in opts:
    print(__doc__)
    sys.exit(2)
APP = os.path.abspath(opts["app"])
FIXTURE_APP = os.path.abspath(opts.get("fixture-app", APP))
TRIALS = int(opts["trials"])
JOBS = int(opts["jobs"])
CASES = set(opts["cases"].split(","))
SEED = int(opts["seed"])
STAT_WAIT = float(opts["wait"])
KEEP = "keep" in opts
WORK = os.path.abspath(opts["work"]) if "work" in opts else tempfile.mkdtemp(prefix="fxpersist_")
os.makedirs(WORK, exist_ok=True)
for p in (APP, FIXTURE_APP):
    if not os.path.exists(os.path.join(p, "Contents", "MacOS", "objekat")):
        print("not an app bundle: " + p)
        sys.exit(2)

fails = []
notes = []
total = 0


def check(label, ok, detail=""):
    global total
    total += 1
    if ok:
        print("ok    " + label, flush=True)
    else:
        fails.append(label)
        print("FAIL  %s   %s" % (label, detail), flush=True)


def note(text):
    notes.append(text)
    print("note  " + text, flush=True)


# ── decoding the chunks ───────────────────────────────────────────────────────────────────────
JUCE_CH = ".ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+"


def juce_b64_decode(text):
    size, rest = text.split(".", 1)
    acc = bits = 0
    out = bytearray()
    for ch in rest:
        acc |= JUCE_CH.index(ch) << bits
        bits += 6
        while bits >= 8:
            out.append(acc & 255)
            acc >>= 8
            bits -= 8
    return bytes(out[:int(size)])


def pha_fields(raw):
    """Numeric records of a PHA-979 chunk, name -> [doubles] (the two text records left out:
    their payload is not a double)."""
    v = plistlib.loads(raw)["VoxPluginState"]
    j = v.find(b"\x78\x5e")
    body = zlib.decompress(v[j:])
    names = [(m.start(), m.end(), m.group(1).decode()) for m in re.finditer(rb"audio\.modMain\.([\w.\-]+)", body)]
    out = {}
    for i, (s, e, n) in enumerate(names):
        nxt = names[i + 1][0] if i + 1 < len(names) else len(body)
        seg = body[e:nxt]
        try:
            _a, _b, _c, cnt = struct.unpack_from("<4I", seg, 0)
            vals, off = [], 16
            for _ in range(cnt):
                tag, = struct.unpack_from("<I", seg, off)
                if tag != 1:
                    break
                vals.append(struct.unpack_from("<d", seg, off + 4)[0])
                off += 12
            out[n] = vals
        except struct.error:
            out[n] = None
    for skip in ("instance-name", "preset-name"):
        out.pop(skip, None)
    return out


def decode(ident, raw):
    """A comparable value for a chunk: ("pha", {record: [..]}) / ("proq", (576 floats)) / None."""
    try:
        if ident == PHA:
            return ("pha", pha_fields(raw))
        if ident == PROQ:
            return ("proq", struct.unpack_from("<576f", plistlib.loads(raw)["FabFilterPluginState"], 12))
    except Exception as e:                                  # an undecodable chunk is a finding, not a crash
        return ("undecodable", "%s: %s" % (type(e).__name__, e))
    return None


def decode_state_xml(ident, xml):
    m = re.search(r'\sstate="([^"]*)"', xml or "")
    return decode(ident, juce_b64_decode(m.group(1))) if m else None


def close(a, b):
    return abs(a - b) <= TOL


def same(a, b):
    if a is None or b is None:
        return a is b
    if a[0] != b[0]:
        return False
    if a[0] == "pha":
        if set(a[1]) != set(b[1]):
            return False
        for k, va in a[1].items():
            vb = b[1][k]
            if va is None or vb is None:
                if va is not vb:
                    return False
            elif len(va) != len(vb) or any(not close(x, y) for x, y in zip(va, vb)):
                return False
        return True
    if a[0] == "proq":
        return all(close(x, y) for x, y in zip(a[1], b[1]))
    return a == b


def describe(a, b):
    """A short human reading of how two decoded values differ."""
    if a is None or b is None or a[0] != b[0]:
        return "%s vs %s" % (a and a[0], b and b[0])
    if a[0] == "pha":
        ch = []
        for k in sorted(set(a[1]) | set(b[1])):
            va, vb = a[1].get(k), b[1].get(k)
            if va != vb and not (va and vb and len(va) == len(vb) and all(close(x, y) for x, y in zip(va, vb))):
                f = lambda v: "None" if v is None else "[" + ",".join("%.6g" % x for x in v) + "]"
                ch.append("%s %s->%s" % (k, f(va), f(vb)))
        return "; ".join(ch[:3]) + ("; +%d" % (len(ch) - 3) if len(ch) > 3 else "")
    if a[0] == "proq":
        idx = [i for i, (x, y) in enumerate(zip(a[1], b[1])) if not close(x, y)]
        return "%d floats differ (first: %s)" % (len(idx), ", ".join("%d: %.4g->%.4g" % (i, a[1][i], b[1][i]) for i in idx[:3]))
    return str(a)[:80]


# ── the saved file as a snapshot ──────────────────────────────────────────────────────────────
def snapshot(path):
    """{defs: {plugin id: (identifier, value)}, inst: {plugin id: {host, link, grp, ident, val}}}.
    Only the plugins we can decode (PHA-979, Pro-Q 4); everything else is out of the comparison."""
    doc = json.load(open(path))
    defs, inst = {}, {}
    for l in doc.get("fxLinks", []):
        for p in l.get("plugins", []):
            if p.get("identifier") in (PHA, PROQ):
                defs[p["id"]] = (p["identifier"], decode_state_xml(p["identifier"], p.get("stateXML")), l.get("name"))

    def walk(items):
        for it in items:
            for p in it.get("plugins", []):
                blk = p.get("fxBlock")
                plist = blk["plugins"] if blk else [p]
                for q in plist:
                    if q.get("identifier") in (PHA, PROQ):
                        inst[q["id"]] = {"host": it["id"], "link": blk and blk.get("linkID"),
                                         "grp": q.get("linkGroupID"), "ident": q["identifier"],
                                         "val": decode_state_xml(q["identifier"], q.get("stateXML"))}
            kind = it.get("kind") or {}
            if kind.get("type") == "group":
                walk(kind.get("children", []))
    walk(doc.get("items", []))
    return {"defs": defs, "inst": inst}


def snap_diff(a, b):
    """Plugin ids changed / added / removed from snapshot a to snapshot b (definitions included)."""
    out = {"changed": {}, "added": [], "removed": []}
    for part in ("defs", "inst"):
        for i, ra in a[part].items():
            if i not in b[part]:
                out["removed"].append(i)
                continue
            va = ra[1] if part == "defs" else ra["val"]
            vb = b[part][i][1] if part == "defs" else b[part][i]["val"]
            if not same(va, vb):
                out["changed"][i] = describe(va, vb)
        out["added"] += [i for i in b[part] if i not in a[part]]
    return out


def sid(i):
    return i[:6]


# ── one headless instance ─────────────────────────────────────────────────────────────────────
_counter = [0]


class App:
    def __init__(self, app, tag):
        _counter[0] += 1
        self.sock = "/tmp/sfsp_%d_%d.sock" % (os.getpid(), _counter[0])
        self.logpath = os.path.join(WORK, "app_%s.log" % re.sub(r"[^\w.-]", "_", tag))
        self.app = app
        self.proc = None
        self.c = None

    def __enter__(self):
        if os.path.exists(self.sock):
            os.unlink(self.sock)
        self.log = open(self.logpath, "w")
        self.proc = subprocess.Popen([os.path.join(self.app, "Contents", "MacOS", "objekat"), "--headless", "--api",
                                      "--no-audio", "--no-recent", "--socket=" + self.sock],
                                     stdout=self.log, stderr=subprocess.STDOUT)
        for _ in range(150):
            if os.path.exists(self.sock):
                break
            if self.proc.poll() is not None:
                raise RuntimeError("the app died at launch (see %s)" % self.logpath)
            time.sleep(0.2)
        time.sleep(1.5)
        self.c = ObjekatClient(self.sock, timeout=900).connect()
        self.cmd("app.set_dialog_policy", policy="assume_yes")
        return self

    def __exit__(self, *_):
        try:
            self.c.close()
        except Exception:
            pass
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=30)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        self.log.close()
        if os.path.exists(self.sock):
            os.unlink(self.sock)

    def cmd(self, _name, **params):
        return self.c.send(_name, params or None)

    def refused(self, _name, **params):
        try:
            self.c.send(_name, params or None)
            return None
        except ObjekatError as e:
            return e.code

    def idle(self):
        self.cmd("wait_idle", timeout_ms=120000)

    def open(self, manifest):
        t0 = time.time()
        self.cmd("project.open", path=manifest)
        while self.cmd("project.load_status").get("loading"):
            time.sleep(0.3)
        self.idle()
        return time.time() - t0

    # -- readings ------------------------------------------------------------------------------
    def live(self, ids, idents):
        """Decoded live chunk of each plugin id (plugin.get_state, never get_params)."""
        out = {}
        for i in ids:
            try:
                raw = base64.b64decode(self.cmd("plugin.get_state", plugin=i)["state"])
                out[i] = decode(idents[i], raw)
            except ObjekatError as e:
                out[i] = ("error", e.code)
        return out

    def links(self):
        return self.cmd("fxlink.list")["links"]


def attached_instances(link):
    """Instance ids of the ATTACHED members of a link, in the list's order."""
    return [i["id"] for m in link["members"] if not m["detached"] for i in m["instances"]]


# ── building a synthetic project ──────────────────────────────────────────────────────────────
PHA_VALUES = [(0.5372, 0.6000, 0.55), (0.5505, 0.5000, 0.50),     # link 1: R at 0 ms, a LEGITIMATE default
              (0.6308, 0.6038, 0.62), (0.5812, 0.5421, 0.58)]


def build_fixture(dst, n_pha, n_pq, members, label):
    """A project with n_pha PHA-979 links and n_pq Pro-Q 4 links of `members` hosts each (the
    second member onward are attached). Each link gets its own, non-default values."""
    shutil.rmtree(dst, ignore_errors=True)
    os.makedirs(dst)
    manifest = os.path.join(dst, "proj.objekat")
    rng = random.Random(SEED)
    with App(FIXTURE_APP, "build_" + label) as a:
        a.cmd("project.new")
        a.cmd("project.save_as", path=manifest)
        lane = [0]

        def new_host():
            o = a.cmd("object.add", path=BIP, lane=lane[0], start=0)["id"]
            lane[0] += 1
            return a.cmd("group.create", ids=[o])["id"]

        def wait_loaded(pid, timeout=60.0):
            dl = time.time() + timeout
            while time.time() < dl:
                try:
                    if a.cmd("plugin.get_state", plugin=pid, include_chunk=False)["size"] > 0:
                        return
                except ObjekatError:
                    pass
                time.sleep(0.25)
            raise RuntimeError("plugin %s never loaded" % pid)

        idents = {}
        for k in range(n_pha + n_pq):
            is_pha = k < n_pha
            ident = PHA if is_pha else PROQ
            host = new_host()
            p = a.cmd("plugin.add", host=host, identifier=ident, format="AudioUnit")["plugin"]["id"]
            wait_loaded(p)
            if is_pha:
                L, R, ph = PHA_VALUES[k] if k < len(PHA_VALUES) else (round(rng.uniform(0.52, 0.7), 4),
                                                                      round(rng.uniform(0.52, 0.7), 4), 0.5)
                for idx, v in ((8, L), (9, R), (10, ph)):
                    a.cmd("plugin.set_param", plugin=p, index=idx, value=v)
                time.sleep(0.4)
            else:
                st = a.cmd("plugin.get_state", plugin=p)["state"]
                pl = plistlib.loads(base64.b64decode(st))
                blob = bytearray(pl["FabFilterPluginState"])
                fl = struct.unpack_from("<576f", blob, 12)
                ch = {0: 0.0 if fl[0] > 0.5 else 1.0, 553: 0.0 if fl[553] > 0.5 else 1.0,
                      12: 0.2 + 0.1 * (k - n_pha), 20: 0.0 if fl[20] > 0.5 else 1.0, 43: 0.0 if fl[43] > 0.5 else 1.0}
                for i, v in ch.items():
                    struct.pack_into("<f", blob, 12 + 4 * i, v)
                pl["FabFilterPluginState"] = bytes(blob)
                a.cmd("debug.plugin_inject_state", plugin=p,
                      state=base64.b64encode(plistlib.dumps(pl, fmt=plistlib.FMT_BINARY)).decode())
                time.sleep(0.4)
            idents[p] = ident
            link = a.cmd("fxlink.create", host=host, plugins=[p],
                         name=("PHA %d" % k) if is_pha else ("PQ %d" % (k - n_pha)))
            for _ in range(members - 1):
                a.cmd("fxlink.attach", link=link["id"], host=new_host())
        a.idle()
        time.sleep(3.0)
        # the fixture must be coherent BEFORE it is saved: every attached member reads like the first
        bad = []
        for l in a.links():
            ids = attached_instances(l)
            ident = PHA if l["name"].startswith("PHA") else PROQ
            vals = a.live(ids, {i: ident for i in ids})
            for i in ids[1:]:
                if not same(vals[ids[0]], vals[i]):
                    bad.append("%s %s vs %s: %s" % (l["name"], sid(i), sid(ids[0]), describe(vals[ids[0]], vals[i])))
        a.cmd("project.save")
    snap = snapshot(manifest)
    return manifest, snap, bad


def fixture_issues(snap):
    """Link by link, every attached instance and the definition read alike."""
    issues = []
    by_link = {}
    for i, r in snap["inst"].items():
        if r["link"]:
            by_link.setdefault(r["link"], []).append(i)
    for lid, ids in by_link.items():
        ref = snap["inst"][ids[0]]["val"]
        for i in ids[1:]:
            if not same(ref, snap["inst"][i]["val"]):
                issues.append("link %s: instance %s differs from %s (%s)" % (sid(lid), sid(i), sid(ids[0]),
                                                                             describe(ref, snap["inst"][i]["val"])))
    for i, r in snap["inst"].items():
        if r["grp"] and r["grp"] in snap["defs"] and not same(snap["defs"][r["grp"]][1], r["val"]):
            issues.append("instance %s differs from its definition %s" % (sid(i), sid(r["grp"])))
    return issues


# ── a trial: a fresh process, open a copy, (force), save, compare ─────────────────────────────
def copy_project(src_manifest, dst_dir):
    shutil.rmtree(dst_dir, ignore_errors=True)
    shutil.copytree(os.path.dirname(src_manifest), dst_dir)
    return os.path.join(dst_dir, os.path.basename(src_manifest))


def compare_live(live, exp_inst):
    bad = []
    for i, v in live.items():
        e = exp_inst[i]["val"]
        if v is None or v[0] in ("error", "undecodable"):
            bad.append("%s unreadable: %s" % (sid(i), v))
        elif not same(v, e):
            bad.append("%s %s" % (sid(i), describe(e, v)))
    return bad


def trial(src_manifest, tag, mode, rng, expected, force_ids=None, n_random=None, settle=2.0):
    """mode 'force': settle, read, force the notification on one random attached member per link
    (or on n_random random instances), wait, read, save. mode 'wait': settle STAT_WAIT, read, save.
    Returns a dict of what went wrong (empty lists = clean)."""
    res = {"tag": tag, "load": None, "live0": [], "live1": [], "file": [], "forced": [], "err": None}
    work = os.path.join(WORK, tag)
    manifest = copy_project(src_manifest, work)
    try:
        with App(APP, tag) as a:
            res["load"] = a.open(manifest)
            idents = {i: r["ident"] for i, r in expected["inst"].items()}
            ids = list(idents)
            time.sleep(settle if mode == "force" else STAT_WAIT)
            res["live0"] = compare_live(a.live(ids, idents), expected["inst"])
            if mode == "force":
                if n_random:
                    targets = rng.sample(ids, min(n_random, len(ids)))
                else:
                    targets = [rng.choice(attached_instances(l)) for l in a.links() if attached_instances(l)]
                for t in targets:
                    a.cmd("debug.plugin_force_processor_changed", plugin=t)
                res["forced"] = [sid(t) for t in targets]
                time.sleep(2.0)
                a.idle()
                res["live1"] = compare_live(a.live(ids, idents), expected["inst"])
            a.cmd("project.save")
        d = snap_diff(expected, snapshot(manifest))
        res["file"] = ["%s %s" % (sid(i), t) for i, t in d["changed"].items()] \
            + ["%s removed" % sid(i) for i in d["removed"]] + ["%s added" % sid(i) for i in d["added"]]
    except Exception as e:
        res["err"] = "%s: %s" % (type(e).__name__, e)
    return res


def run_trials(label, src_manifest, n, mode, expected, n_random=None):
    """n trials in parallel (JOBS at a time); returns the list of results."""
    def one(k):
        return trial(src_manifest, "%s_%d" % (label, k), mode, random.Random(SEED * 1000 + k), expected, n_random=n_random)
    with concurrent.futures.ThreadPoolExecutor(max_workers=JOBS) as ex:
        return list(ex.map(one, range(n)))


def corrupted(r):
    return bool(r["err"] or r["live0"] or r["live1"] or r["file"])


def report(label, results, what):
    """One check per label: every trial clean. Prints the counts and the first findings."""
    bad = [r for r in results if corrupted(r)]
    loads = [r["load"] for r in results if r["load"]]
    avg = (sum(loads) / len(loads)) if loads else 0
    check("%s: %s — %d/%d trials clean (load %.1f s)" % (label, what, len(results) - len(bad), len(results), avg),
          not bad, "")
    for r in bad[:2]:
        for key in ("err", "live0", "live1", "file"):
            v = r[key]
            if v:
                print("        %s %s%s: %s" % (r["tag"], key, " (forced %s)" % ",".join(r["forced"]) if key == "live1" else "",
                                               v if isinstance(v, str) else "%d plugin(s); %s" % (len(v), "; ".join(v[:3]))))
    if len(bad) > 2:
        print("        … and %d more corrupted trial(s)" % (len(bad) - 2))
    return not bad


# ── a mutation step: a fresh process, open, do something, save ────────────────────────────────
def mutate(src_manifest, dst_dir, tag, fn):
    """Copies the project, opens it in a fresh process, calls fn(a, exp) -> [(label, ok, detail)],
    saves. Returns (new manifest, checks)."""
    manifest = copy_project(src_manifest, dst_dir)
    exp = snapshot(src_manifest)
    with App(APP, tag) as a:
        a.open(manifest)
        time.sleep(2.0)
        checks = fn(a, exp)
        a.idle()
        time.sleep(1.0)
        a.cmd("project.save")
    return manifest, checks


def settle(a, s=1.5):
    a.idle()
    time.sleep(s)


def run_checks(checks):
    for label, ok, detail in checks:
        check(label, ok, detail)


def unexpected(diff, changed=(), added=(), removed=()):
    """What moved beyond the planned ids."""
    out = []
    for i, t in diff["changed"].items():
        if i not in changed:
            out.append("%s changed: %s" % (sid(i), t))
    out += ["%s added" % sid(i) for i in diff["added"] if i not in added]
    out += ["%s removed" % sid(i) for i in diff["removed"] if i not in removed]
    return out


def link_by_name(a, name):
    return next(l for l in a.links() if l["name"] == name)


# ═════════════════════════════════════════════════════════════════════════════════════════════
def main():
    # ── preflight: a DEBUG build, and both plugins installed ───────────────────────────────────
    with App(FIXTURE_APP, "preflight") as a:
        av = {p["identifier"] for p in a.cmd("plugin.list_available", filter="a")["plugins"]}
        miss = [n for n, i in (("PHA-979", PHA), ("Pro-Q 4", PROQ)) if i not in av]
        if miss:
            print("SKIP  not installed: %s" % ", ".join(miss))
            return 0
        if a.refused("debug.link_state") == "unknown_command":
            print("SKIP  debug.* commands absent (not a DEBUG build)")
            return 0
    with App(APP, "preflight_app") as a:
        if a.refused("debug.plugin_force_processor_changed", plugin="00000000-0000-0000-0000-000000000000") == "unknown_command":
            print("SKIP  debug.plugin_force_processor_changed absent in --app (not a DEBUG build of this branch)")
            return 0
    print("app            : %s" % APP)
    print("fixtures built by: %s" % FIXTURE_APP)
    print("work dir       : %s   seed %d   trials %d   jobs %d" % (WORK, SEED, TRIALS, JOBS))

    t_start = time.time()
    # ── the base fixture: 12 hosts = 3 PHA links (PHA 0..2, R of PHA 1 at its default) + 1 Pro-Q link, 3 members each ──
    print("\n-- fixture")
    base_manifest, base, issues = build_fixture(os.path.join(WORK, "fixture"), 3, 1, 3, "base")
    check("the fixture is coherent as built (live)", not issues, "; ".join(issues[:3]))
    fi = fixture_issues(base)
    check("the fixture is coherent as saved (file)", not fi, "; ".join(fi[:3]))
    if issues or fi:
        note("the fixture itself is corrupted by the builder (%s): a build WITHOUT the patch does this on its own; "
             "rebuild with --fixture-app=<patched app> to isolate the later cases" % FIXTURE_APP)
    npha = sum(1 for r in base["inst"].values() if r["ident"] == PHA)
    nproq = sum(1 for r in base["inst"].values() if r["ident"] == PROQ)
    note("fixture: %d hosts, %d PHA-979 + %d Pro-Q 4 instances, %d definitions" % (len(base["inst"]), npha, nproq, len(base["defs"])))
    zero = [i for i, r in base["inst"].items() if r["ident"] == PHA and
            (r["val"][1].get("modPHA979.delay") or [None])[0] in (0, 0.0)]
    check("(precondition) no PHA instance starts at the factory delay of 0", not zero, str([sid(i) for i in zero]))

    # ── (a) ────────────────────────────────────────────────────────────────────────────────────
    if "a" in CASES:
        print("\n-- (a) open + save, nothing touched")
        report("(a) forced", run_trials("a_force", base_manifest, TRIALS, "force", base), "a late processor-changed on one member per link")
        report("(a) wait %gs" % STAT_WAIT, run_trials("a_wait", base_manifest, TRIALS, "wait", base), "no forcing, the race left to chance")

    # ── (b) ────────────────────────────────────────────────────────────────────────────────────
    cur = base_manifest
    cur_snap = base
    if "b" in CASES:
        print("\n-- (b) edit the LAST member of a link, save, reopen")

        def step_b(a, exp):
            out = []
            lp = link_by_name(a, "PHA 0")
            idp = attached_instances(lp)
            last = idp[-1]
            old = a.live([last], {last: PHA})[last]
            a.cmd("plugin.set_param", plugin=last, index=8, value=0.5871)
            settle(a, 1.5)
            vals = a.live(idp, {i: PHA for i in idp})
            new = vals[last]
            out.append(("(b) the edit took on the last member (DelayL moved)", not same(old, new) and
                        abs(new[1]["modPHA979.delay"][0] - (0.5871 - 0.5) * 0.04) < 1e-6, describe(old, new)))
            out.append(("(b) every member of PHA 0 carries the new value (live get_state)",
                        all(same(vals[i], new) for i in idp), "; ".join(sid(i) + " " + describe(new, vals[i]) for i in idp if not same(vals[i], new))))
            lq = link_by_name(a, "PQ 0")
            idq = attached_instances(lq)
            lastq = idq[-1]
            st = a.cmd("plugin.get_state", plugin=lastq)["state"]
            pl = plistlib.loads(base64.b64decode(st))
            blob = bytearray(pl["FabFilterPluginState"])
            fl = struct.unpack_from("<576f", blob, 12)
            struct.pack_into("<f", blob, 12 + 4 * 12, 0.9 if fl[12] < 0.8 else 0.4)
            pl["FabFilterPluginState"] = bytes(blob)
            a.cmd("debug.plugin_inject_state", plugin=lastq,
                  state=base64.b64encode(plistlib.dumps(pl, fmt=plistlib.FMT_BINARY)).decode())
            a.cmd("fxlink.sync", plugin=lastq)
            settle(a, 1.5)
            vq = a.live(idq, {i: PROQ for i in idq})
            out.append(("(b) every member of PQ 0 carries the new Pro-Q value (live get_state)",
                        all(same(vq[i], vq[lastq]) for i in idq), "; ".join(sid(i) + " " + describe(vq[lastq], vq[i]) for i in idq if not same(vq[i], vq[lastq]))))
            return out

        cur, checks = mutate(base_manifest, os.path.join(WORK, "b_fix"), "b_mutate", step_b)
        run_checks(checks)
        new_snap = snapshot(cur)
        d = snap_diff(base, new_snap)
        # the links of the saved file by NAME, through their definitions' registry
        fx = json.load(open(cur))["fxLinks"]
        lid_of = {l["name"]: l["id"] for l in fx}
        want = {i for i, r in new_snap["inst"].items() if r["link"] in (lid_of["PHA 0"], lid_of["PQ 0"])}
        want |= {i for i, dd in new_snap["defs"].items() if dd[2] in ("PHA 0", "PQ 0")}
        extra = unexpected(d, changed=want)
        check("(b) the saved file: exactly PHA 0 and PQ 0 moved, instances AND definitions", not extra and
              want <= set(d["changed"]), "; ".join(extra[:3]) + (" | not moved: %s" % [sid(i) for i in want - set(d["changed"])][:3] if want - set(d["changed"]) else ""))
        fi = fixture_issues(new_snap)
        check("(b) the saved file: every instance reads like its definition", not fi, "; ".join(fi[:3]))
        cur_snap = new_snap
        report("(b) reopen + force", run_trials("b_force", cur, TRIALS, "force", cur_snap), "the edit survives open + save")

    # ── (c) ────────────────────────────────────────────────────────────────────────────────────
    if "c" in CASES:
        print("\n-- (c) attach / detach / reattach / remove_block")
        link_name = "PHA 2"

        def members(a):
            l = link_by_name(a, link_name)
            return l, [m for m in l["members"] if not m["detached"]]

        # c1 — attach a brand new host
        def step_c1(a, exp):
            out = []
            l, ms = members(a)
            before = {i["id"]: None for m in ms for i in m["instances"]}
            idents = {i: PHA for i in before}
            ref = a.live(list(before), idents)
            o = a.cmd("object.add", path=BIP, lane=900, start=0)["id"]
            g = a.cmd("group.create", ids=[o])["id"]
            a.cmd("fxlink.attach", link=l["id"], host=g)
            settle(a, 2.0)
            l2, ms2 = members(a)
            new_ids = [i["id"] for m in ms2 if m["host"] == g for i in m["instances"]]
            out.append(("(c1) the new host got an instance", len(new_ids) == 1, str(new_ids)))
            if new_ids:
                nv = a.live(new_ids, {new_ids[0]: PHA})[new_ids[0]]
                first = next(iter(ref))
                out.append(("(c1) the new instance follows the bin's values", same(nv, ref[first]), describe(ref[first], nv)))
            now = a.live(list(before), idents)
            moved = [sid(i) for i in before if not same(now[i], ref[i])]
            out.append(("(c1) the older members did not move", not moved, str(moved)))
            return out

        c1, checks = mutate(cur, os.path.join(WORK, "c1"), "c1_mutate", step_c1)
        run_checks(checks)
        s1 = snapshot(c1)
        d = snap_diff(cur_snap, s1)
        extra = unexpected(d, added=set(d["added"]))
        check("(c1) the saved file: one instance added, nothing else moved", len(d["added"]) == 1 and not extra, "; ".join(extra[:3]) + " added=%d" % len(d["added"]))
        report("(c1) reopen + force", run_trials("c1_force", c1, TRIALS, "force", s1), "after an attach")

        # c2 — detach a member, then edit the detached copy
        holder = {}

        def step_c2(a, exp):
            out = []
            l, ms = members(a)
            D = ms[1]["host"]
            others = [i["id"] for m in ms if m["host"] != D for i in m["instances"]]
            idents = {i: PHA for i in others}
            ref = a.live(others, idents)
            a.cmd("fxlink.detach", host=D, link=l["id"])
            settle(a, 1.0)
            dinst = next(p for p in a.cmd("plugin.list", host=D)["plugins"] if p.get("is_fx_block"))["plugins"][0]["id"]
            holder["D"], holder["dinst"], holder["link"] = D, dinst, l["id"]
            before = a.live([dinst], {dinst: PHA})[dinst]
            a.cmd("plugin.set_param", plugin=dinst, index=8, value=0.6400)
            settle(a, 1.5)
            after = a.live([dinst], {dinst: PHA})[dinst]
            out.append(("(c2) the detached copy took its own edit", not same(before, after) and
                        abs(after[1]["modPHA979.delay"][0] - 0.0056) < 1e-6, describe(before, after)))
            now = a.live(others, idents)
            moved = [sid(i) for i in others if not same(now[i], ref[i])]
            out.append(("(c2) the rest of the link did not move", not moved, str(moved)))
            return out

        c2, checks = mutate(c1, os.path.join(WORK, "c2"), "c2_mutate", step_c2)
        run_checks(checks)
        s2 = snapshot(c2)
        d = snap_diff(s1, s2)
        extra = unexpected(d, changed={holder["dinst"]})
        check("(c2) the saved file: only the detached instance changed (definition untouched)",
              not extra and holder["dinst"] in d["changed"], "; ".join(extra[:3]))
        report("(c2) reopen + force", run_trials("c2_force", c2, TRIALS, "force", s2), "a detached copy stays apart")

        # c3 — reattach it: it adopts the bin's values
        def step_c3(a, exp):
            out = []
            l, ms = members(a)
            D = holder["D"]
            allm = [m for m in link_by_name(a, link_name)["members"]]
            others = [i["id"] for m in allm if m["host"] != D and not m["detached"] for i in m["instances"]]
            ref = a.live(others, {i: PHA for i in others})
            a.cmd("fxlink.reattach", host=D, link=holder["link"])
            settle(a, 2.0)
            dinst = next(p for p in a.cmd("plugin.list", host=D)["plugins"] if p.get("is_fx_block"))["plugins"][0]["id"]
            holder["dinst"] = dinst
            dv = a.live([dinst], {dinst: PHA})[dinst]
            first = next(iter(ref.values()))
            out.append(("(c3) the reattached host adopts the bin's values (not the reverse)", same(dv, first), describe(first, dv)))
            now = a.live(others, {i: PHA for i in others})
            moved = [sid(i) for i in others if not same(now[i], ref[i])]
            out.append(("(c3) the bin's other members did not move", not moved, str(moved)))
            return out

        c3, checks = mutate(c2, os.path.join(WORK, "c3"), "c3_mutate", step_c3)
        run_checks(checks)
        s3 = snapshot(c3)
        d = snap_diff(s2, s3)
        extra = unexpected(d, changed={holder["dinst"]})
        check("(c3) the saved file: only the reattached instance moved (back to the bin)", not extra, "; ".join(extra[:3]))
        d0 = snap_diff(s1, s3)
        check("(c3) the file is back to the post-attach state, value for value", not d0["changed"] and not d0["removed"] and not d0["added"],
              "; ".join("%s %s" % (sid(i), t) for i, t in list(d0["changed"].items())[:3]))
        report("(c3) reopen + force", run_trials("c3_force", c3, TRIALS, "force", s3), "after a reattach")

        # c4 — remove a member's block
        def step_c4(a, exp):
            out = []
            l, ms = members(a)
            X = ms[-1]["host"]
            xinst = [i["id"] for i in ms[-1]["instances"]]
            holder["xinst"] = xinst
            others = [i["id"] for m in ms if m["host"] != X for i in m["instances"]]
            ref = a.live(others, {i: PHA for i in others})
            a.cmd("fxlink.remove_block", host=X, link=l["id"])
            settle(a, 1.5)
            gone = all(not any(i["id"] in xinst for m in link_by_name(a, link_name)["members"] for i in m["instances"]) for _ in [0])
            out.append(("(c4) the host left the bin (its instance is gone from the link)", gone, ""))
            now = a.live(others, {i: PHA for i in others})
            moved = [sid(i) for i in others if not same(now[i], ref[i])]
            out.append(("(c4) the other members did not move", not moved, str(moved)))
            return out

        c4, checks = mutate(c3, os.path.join(WORK, "c4"), "c4_mutate", step_c4)
        run_checks(checks)
        s4 = snapshot(c4)
        d = snap_diff(s3, s4)
        extra = unexpected(d, removed=set(holder["xinst"]))
        check("(c4) the saved file: only the removed block's instance disappeared", not extra and set(holder["xinst"]) <= set(d["removed"]),
              "; ".join(extra[:3]))
        report("(c4) reopen + force", run_trials("c4_force", c4, TRIALS, "force", s4), "after a remove_block")

    # ── (d) ────────────────────────────────────────────────────────────────────────────────────
    if "d" in CASES:
        print("\n-- (d) duplicate / copy-paste a linked group")

        def step_d(a, exp):
            out = []
            l = link_by_name(a, "PHA 0")
            ms = [m for m in l["members"] if not m["detached"]]
            old_ids = attached_instances(l)
            ref = a.live(old_ids, {i: PHA for i in old_ids})
            first = ref[old_ids[0]]
            # duplicate
            r = a.cmd("object.duplicate", ids=[ms[0]["host"]])
            settle(a, 2.0)
            l2 = link_by_name(a, "PHA 0")
            new1 = [i for i in attached_instances(l2) if i not in old_ids]
            out.append(("(d) object.duplicate: the copy joined the bin (one new instance)", len(new1) == 1 and r.get("count") == 1, str(new1)))
            # copy-paste (far in time: no overlap fragment)
            a.cmd("selection.set", ids=[ms[1]["host"]])
            a.cmd("transport.seek", seconds=60)
            a.cmd("clipboard.copy")
            r2 = a.cmd("clipboard.paste")
            settle(a, 2.0)
            l3 = link_by_name(a, "PHA 0")
            new2 = [i for i in attached_instances(l3) if i not in old_ids and i not in new1]
            out.append(("(d) clipboard.paste: the pasted copy joined the bin (one new instance)", len(new2) == 1 and r2.get("count") == 1, str(new2)))
            nv = a.live(new1 + new2, {i: PHA for i in new1 + new2})
            out.append(("(d) both copies carry the bin's values", all(same(v, first) for v in nv.values()),
                        "; ".join(sid(i) + " " + describe(first, v) for i, v in nv.items() if not same(v, first))))
            now = a.live(old_ids, {i: PHA for i in old_ids})
            moved = ["%s %s" % (sid(i), describe(ref[i], now[i])) for i in old_ids if not same(now[i], ref[i])]
            out.append(("(d) the ORIGINALS did not move (the old 'blank copy zeroes the original' regression)", not moved, "; ".join(moved[:3])))
            return out

        dman, checks = mutate(base_manifest, os.path.join(WORK, "d_fix"), "d_mutate", step_d)
        run_checks(checks)
        sd = snapshot(dman)
        d = snap_diff(base, sd)
        extra = unexpected(d, added=set(d["added"]))
        check("(d) the saved file: two instances added, nothing else moved (definition included)",
              len(d["added"]) == 2 and not extra, "; ".join(extra[:3]) + " added=%d" % len(d["added"]))
        fi = fixture_issues(sd)
        check("(d) the saved file: every instance reads like its definition", not fi, "; ".join(fi[:3]))
        report("(d) reopen + force", run_trials("d_force", dman, TRIALS, "force", sd), "after a duplicate and a paste")

    # ── (e) ────────────────────────────────────────────────────────────────────────────────────
    if "e" in CASES:
        print("\n-- (e) three open + save cycles")

        def chain(k):
            rng = random.Random(SEED * 7000 + k)
            res = []
            src = base_manifest
            for cyc in range(3):
                r = trial(src, "e_%d_c%d" % (k, cyc), "force", rng, base)
                res.append(r)
                src = os.path.join(WORK, "e_%d_c%d" % (k, cyc), os.path.basename(base_manifest))
            return res
        with concurrent.futures.ThreadPoolExecutor(max_workers=JOBS) as ex:
            chains = list(ex.map(chain, range(TRIALS)))
        flat = [r for c in chains for r in c]
        report("(e) 3 cycles", flat, "%d chains of 3 open + force + save, each compared with the ORIGINAL file" % TRIALS)

    # ── (f) ────────────────────────────────────────────────────────────────────────────────────
    if "f" in CASES:
        print("\n-- (f) ~100 instances")
        t0 = time.time()
        big_manifest, big, issues = build_fixture(os.path.join(WORK, "big"), 8, 2, 10, "big")
        note("built the 100-instance fixture in %.0f s" % (time.time() - t0))
        check("(f) the big fixture is coherent as built (live)", not issues, "; ".join(issues[:3]))
        fi = fixture_issues(big)
        check("(f) the big fixture is coherent as saved (file)", not fi, "; ".join(fi[:3]))
        check("(f) it really holds ~100 instances", len(big["inst"]) == 100, str(len(big["inst"])))
        note("random members forced per trial: seed %d, trial k draws with Random(%d*1000+k)" % (SEED, SEED))
        res = run_trials("f_force", big_manifest, TRIALS, "force", big, n_random=10)
        report("(f) forced on 10 random members", res, "100 instances")
        res2 = run_trials("f_wait", big_manifest, 5, "wait", big)
        report("(f) wait %gs, no forcing" % STAT_WAIT, res2, "100 instances, the race left to chance")
        loads = [r["load"] for r in res + res2 if r["load"]]
        if loads:
            note("(f) load time of the 100-instance project: min %.1f s, max %.1f s" % (min(loads), max(loads)))

    # ── (r) a copy of a real project ───────────────────────────────────────────────────────────
    if "real" in opts:
        print("\n-- (r) a copy of a real project")
        src = os.path.abspath(opts["real"])
        ok_dirs = [os.path.realpath(tempfile.gettempdir()), "/tmp", "/private/tmp"]
        if not any(os.path.realpath(src).startswith(d + os.sep) for d in ok_dirs):
            print("refused: --real must point INTO a temp dir (a COPY of the project), got " + src)
            return 2
        size = sum(os.path.getsize(os.path.join(dp, f)) for dp, _, fs in os.walk(os.path.dirname(src)) for f in fs)
        if size > 500 * 1024 * 1024:
            print("refused: %d MB under %s — hand over a light copy (manifest without the audio)" % (size // 2**20, os.path.dirname(src)))
            return 2
        rs = snapshot(src)
        note("the real project holds %d decodable instances and %d definitions" % (len(rs["inst"]), len(rs["defs"])))
        report("(r) forced", run_trials("r_force", src, TRIALS, "force", rs), "real project")
        report("(r) wait %gs" % STAT_WAIT, run_trials("r_wait", src, TRIALS, "wait", rs), "real project, no forcing")

    print("\n%d assertions, %d failed, %.0f s" % (total, len(fails), time.time() - t_start))
    for f in fails:
        print("  FAIL " + f)
    return 1 if fails else 0


if __name__ == "__main__":
    rc = 2
    try:
        rc = main()
    finally:
        if not KEEP and "work" not in opts:
            shutil.rmtree(WORK, ignore_errors=True)
    sys.exit(rc)

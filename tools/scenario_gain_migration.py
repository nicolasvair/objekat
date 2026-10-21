#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Gain stages — the NULL TEST of the load-time migration (docs/plan_synoptic_rework.md, D1 / D.3).

    ./scenario_gain_migration.py <new objekat.app> --base-app <format-24 objekat.app> <work dir> [--only mono|stereo]

Since format 25 a chain has no trims and an FX link has no output section: an old file's trims become
GAIN STAGES (a stage at index 0 for the in, at the end for the out; objects, stems, the Main), its FX link
outputs a `gain_pan_mute` stage in the bin (or in a detached block), and a curve on a trim is re-aimed at
the stage's gain. This proves that an old project SOUNDS THE SAME once migrated:

  1. the BASE app (a build that writes format 24 — the archive of 12 October, or `e2aea50d` built by
     hand) lays the fixture through its OWN API, on a generated 1 kHz + noise source, five kinds of
     sections at distinct times, a built-in compressor with strong settings in every chain (a
     non-linear stage: a gain moved to the wrong side of it CHANGES the output):
       S1  trims -6 / +3 around the compressor;
       S2  a trim in carrying a ramp curve (-18 -> +6);
       S3  an FX link on two objects, output -4.5 dB / pan 0.25, one member DETACHED with a local -6 / muted;
       S4  a stem with trims -3 / +2 (and the Main with a trim in of -1, heard by every section);
       S5  five senders with trims -12 / +6 around the compressor, one per tap — input, chain(0),
           chain(n), pre_fader, post_fader — each to its own aux (one window each: S5a…S5e);
     the trims and the curve are injected into the saved JSON (the base's API sets them only through a
     DEBUG command, and the base is a Release build; the API has no automation door at all), in the
     shape the format-24 decoder reads; the base reopens that file and exports REF;
  2. the NEW app opens it: the `legacy_gain_migration` report must say trims 16, fx_outputs 2,
     automation_lanes 1, clamped 0; `plugin.list` shows the stages where the migration lays them;
     `debug.send_marker_audit` is clean; it exports NEW, saves (format 25, none of the old keys);
  3. a FRESH process of the new app reopens that save and exports NEW2.

Pass: per section, max |REF - NEW| <= 1 LSB (24 bit) after the section's first 20 ms, and NEW2 == NEW
bit for bit. Each section's RMS is printed against a DRY export (the objects alone), and a section that
is silent fails — a null test that passes by silence proves nothing. The whole runs twice: on a MONO
source and on a STEREO one (a mono source is widened by the chain's first plugin, which is where the
trims used to sit: engine patch 0041).

Both apps run headless, `--api --no-recent --language=en`, AUDIO ON (the sends ride the bridge's device
clock): exit 2 if `app.info.audio_running` is false. Exports: 48 kHz / 24 bit, no dither, same options
on both sides. Exit: 0 pass, 1 a failure, 2 no audio, 3 no usable base app (the merge is then BLOCKED —
not skippable).
"""

import json, math, os, random, shutil, signal, subprocess, sys, time, wave

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError
import bridge_scenario_common as B

SR = B.SR
LSB = 1.0 / 8388608.0
WIN = 2.0                 # seconds per section window
SRC_LEN = 1.2             # seconds of source
LEAD = 0.5                # the first window starts here
SECTIONS = ["S1 trims around the compressor", "S2 trim in with a ramp curve", "S3 FX link output + detached local",
            "S4 stem trims (+ Main trim in)", "S5a sender, input tap", "S5b sender, chain(0) tap",
            "S5c sender, chain(n) tap", "S5d sender, pre_fader tap", "S5e sender, post_fader tap"]
EXPECTED_REPORT = {"trims": 16, "fx_outputs": 2, "automation_lanes": 1, "clamped": 0}
LEGACY_OBJECT_KEYS = ("chainInGainDb", "chainOutGainDb")


def usage(code):
    print(__doc__)
    sys.exit(code)


args = sys.argv[1:]
only = None
if "--only" in args:
    i = args.index("--only")
    only = args[i + 1]
    del args[i:i + 2]
base_app = None
if "--base-app" in args:
    i = args.index("--base-app")
    base_app = args[i + 1]
    del args[i:i + 2]
if len(args) != 2:
    usage(2)
NEW_APP, ROOT = args


def exe_of(app):
    return os.path.join(app, "Contents", "MacOS", "objekat") if app.endswith(".app") else app


if not base_app or not os.path.exists(exe_of(base_app)):
    print("NO BASE APP (%s): the null test cannot run — the merge is BLOCKED (exit 3)" % base_app)
    sys.exit(3)
if not os.path.exists(exe_of(NEW_APP)):
    print("no new app at %s" % NEW_APP)
    sys.exit(2)

fails, total = [], 0


def check(label, ok, detail=""):
    global total
    total += 1
    if ok:
        print("ok    " + label)
    else:
        fails.append(label)
        print("FAIL  %s   %s" % (label, detail))


# ── the apps ─────────────────────────────────────────────────────────────────────────────────────

class App:
    """One headless instance, audio ON, on its own short socket; killed on exit."""

    def __init__(self, app, sock, log):
        self.sock = sock
        if os.path.exists(sock):
            os.unlink(sock)
        self.logf = open(log, "w")
        self.proc = subprocess.Popen([exe_of(app), "--headless", "--api", "--no-recent", "--language=en",
                                      "--socket=" + sock], stdout=self.logf, stderr=subprocess.STDOUT)
        deadline = time.time() + 30
        while not os.path.exists(sock):
            if self.proc.poll() is not None or time.time() > deadline:
                raise RuntimeError("the app did not open its socket: %s" % app)
            time.sleep(0.1)
        self.client = ObjekatClient(sock).__enter__()

    def cmd(self, _command, **params):          # not `name`: some commands take a `name` parameter
        return self.client.send(_command, params or None)

    def idle(self):
        self.cmd("wait_idle", timeout_ms=60000)

    def close(self):
        try:
            self.client.__exit__(None, None, None)
        except Exception:
            pass
        self.proc.send_signal(signal.SIGTERM)
        try:
            self.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.proc.kill()
        self.logf.close()


def require_audio(app, who):
    if not app.cmd("app.info").get("audio_running"):
        print("%s: the audio device is not running (app.info.audio_running false) — exit 2" % who)
        app.close()
        sys.exit(2)


def export(app, path, end):
    r = app.cmd("export.run", format="wav", sample_rate=SR, bit_depth=24, dithering=False,
                start=0.0, end=end, path=path)
    app.cmd("job.wait", id=r["job_id"], timeout_ms=180000)
    return B.read_wav(path)


# ── the source ───────────────────────────────────────────────────────────────────────────────────

def make_source(path, channels):
    """1 kHz at -12 dBFS + noise at -30 dBFS (a different noise per channel), 24 bit."""
    rnd = random.Random(25)
    a, nz = 10 ** (-12 / 20.0), 10 ** (-30 / 20.0)
    raw = bytearray()
    for i in range(int(SRC_LEN * SR)):
        s = a * math.sin(2 * math.pi * 1000.0 * i / SR)
        for ch in range(channels):
            v = s * (1.0 if ch == 0 else 0.8) + nz * (rnd.random() * 2 - 1)
            raw += max(-8388608, min(8388607, int(round(v * 8388607)))).to_bytes(3, "little", signed=True)
    with wave.open(path, "wb") as w:
        w.setnchannels(channels)
        w.setsampwidth(3)
        w.setframerate(SR)
        w.writeframes(bytes(raw))


def win_start(k):
    return LEAD + WIN * k


# ── the fixture, through the BASE app's own API ──────────────────────────────────────────────────

def strong_compressor(app, host):
    p = app.cmd("plugin.add", host=host, identifier="compressor", format="TracktionInternal")["plugin"]["id"]
    for name, value in (("Threshold", 0.1), ("Ratio", 0.9), ("Attack", 1.0), ("Release", 50.0)):
        idx = next(q["index"] for q in app.cmd("plugin.get_params", plugin=p)["params"] if q["name"] == name)
        app.cmd("plugin.set_param", plugin=p, index=idx, value=value)
    return p


def build_fixture(app, src, workdir):
    """Lays every section; returns (DRY export, the patch to inject into the saved JSON, metadata)."""
    app.cmd("app.set_dialog_policy", policy="assume_yes")
    app.cmd("project.new")
    os.makedirs(workdir, exist_ok=True)
    ids = {}
    lane = 0

    def add(key, k, offset=0.0):
        nonlocal lane
        ids[key] = app.cmd("object.add", path=src, lane=lane, start=win_start(k) + offset)["id"]
        lane += 1
        return ids[key]

    add("s1", 0)
    add("s2", 1)
    add("s3a", 2)
    add("s3b", 2)
    add("s4", 3)
    taps = [("s5a", "input", None), ("s5b", "chain", 0), ("s5c", "chain", 1), ("s5d", "pre_fader", None),
            ("s5e", "post_fader", None)]
    for j, (key, _, _) in enumerate(taps):
        add(key, 4 + j)
    app.idle()
    end = win_start(len(SECTIONS)) + 0.5
    dry = export(app, os.path.join(workdir, "dry.wav"), end)

    # compressors everywhere
    for key in ("s1", "s2", "s4") + tuple(t[0] for t in taps):
        strong_compressor(app, ids[key])
    # S3: an FX link, output -4.5 dB / pan 0.25, B detached with a local -6 / muted
    comp = strong_compressor(app, ids["s3a"])
    link = app.cmd("fxlink.create", host=ids["s3a"], plugins=[comp], name="Null bin")["id"]
    app.cmd("fxlink.attach", link=link, host=ids["s3b"])
    app.cmd("fxlink.set_output", link=link, gain_db=-4.5, pan=0.25)
    app.idle()
    app.cmd("fxlink.detach", host=ids["s3b"], link=link)
    app.cmd("fxlink.set_local_output", host=ids["s3b"], link=link, gain_db=-6.0, muted=True)
    # S4: a stem
    stem = app.cmd("stem.add", name="Null stem")["id"]
    app.cmd("stem.assign", stem=stem, ids=[ids["s4"]])
    main = app.cmd("stem.list")["main"]
    # S5: one aux per sender, each tap
    for j, (key, position, index) in enumerate(taps):
        aux = app.cmd("aux.create", start=win_start(4 + j), end=win_start(4 + j) + WIN - 0.1, lane=lane)["id"]
        lane += 1
        params = {"id": ids[key], "aux": aux, "position": position}
        if index is not None:
            params["index"] = index
        app.cmd("send.create", **params)
        app.cmd("send.set_level", id=ids[key], aux=aux, db=-6.0)
    app.idle()

    patch = {
        "objects": {ids["s1"]: {"chainInGainDb": -6.0, "chainOutGainDb": 3.0},
                    ids["s2"]: {"chainInGainDb": -18.0,
                                "automation": [{"param": {"type": "chainInGain"},
                                                "points": [{"t": 0.0, "v": -18.0, "c": 0.0},
                                                           {"t": SRC_LEN, "v": 6.0, "c": 0.0}]}]}},
        "stems": {stem: {"chainInGainDb": -3.0, "chainOutGainDb": 2.0}, main: {"chainInGainDb": -1.0}},
    }
    for key, _, _ in taps:
        patch["objects"][ids[key]] = {"chainInGainDb": -12.0, "chainOutGainDb": 6.0}
    return dry, patch, {"ids": ids, "stem": stem, "main": main, "link": link, "end": end}


def find_items(items):
    for o in items:
        yield o
        kind = o.get("kind")
        if isinstance(kind, dict):
            for v in kind.values():
                if isinstance(v, dict) and isinstance(v.get("children"), list):
                    yield from find_items(v["children"])


def inject(path, patch):
    with open(path) as f:
        d = json.load(f)
    objs = {o["id"].upper(): o for o in find_items(d["items"])}
    for oid, fields in patch["objects"].items():
        objs[oid.upper()].update(fields)
    stems = {s["id"].upper(): s for s in d.get("stems") or []}
    for sid, fields in patch["stems"].items():
        stems[sid.upper()].update(fields)
    with open(path, "w") as f:
        json.dump(d, f, indent=1)
    return d


def find_object(d, oid):
    """The encoded object carrying `oid` anywhere in the document (groups are recursive)."""
    if isinstance(d, dict):
        if str(d.get("id", "")).upper() == str(oid).upper() and ("automation" in d or "kind" in d):
            return d
        for x in d.values():
            r = find_object(x, oid)
            if r is not None:
                return r
    elif isinstance(d, list):
        for x in d:
            r = find_object(x, oid)
            if r is not None:
                return r
    return None


def legacy_keys_in(d):
    """Every old key still in an encoded document: trims anywhere, an FX link's output, a block's
    local output, a curve on a trim."""
    found = []

    def walk(v, path):
        if isinstance(v, dict):
            for k in LEGACY_OBJECT_KEYS:
                if k in v:
                    found.append(path + "." + k)
            if v.get("type") in ("chainInGain", "chainOutGain"):
                found.append(path + ".type=" + v["type"])
            for k, x in v.items():
                walk(x, path + "." + k)
        elif isinstance(v, list):
            for i, x in enumerate(v):
                walk(x, "%s[%d]" % (path, i))

    walk(d, "")
    for i, link in enumerate(d.get("fxLinks") or []):
        for k in ("gainDb", "pan", "muted"):
            if k in link:
                found.append("fxLinks[%d].%s" % (i, k))

    def blocks(v, path):
        if isinstance(v, dict):
            fb = v.get("fxBlock")
            if isinstance(fb, dict) and isinstance(fb.get("local"), dict):
                for k in ("gainDb", "pan", "muted"):
                    if k in fb["local"]:
                        found.append(path + ".fxBlock.local." + k)
            for k, x in v.items():
                blocks(x, path + "." + k)
        elif isinstance(v, list):
            for i, x in enumerate(v):
                blocks(x, "%s[%d]" % (path, i))

    blocks(d, "")
    return found


# ── the comparison ───────────────────────────────────────────────────────────────────────────────

def window_maxdiff(a, b, k):
    lo, hi = int((win_start(k) + 0.02) * SR), int((win_start(k) + WIN) * SR)
    worst = 0.0
    for ca, cb in zip(a, b):
        hi2 = min(hi, len(ca), len(cb))
        for i in range(lo, hi2):
            d = abs(ca[i] - cb[i])
            if d > worst:
                worst = d
    return worst


def window_rms_db(a, k):
    vals = [B.rms(ch, win_start(k), win_start(k) + WIN) for ch in a]
    return B.db(math.sqrt(sum(v * v for v in vals) / len(vals))) if vals else -240.0


def stages_of(app, host):
    out = []
    for p in app.cmd("plugin.list", host=host)["plugins"]:
        for q in (p["plugins"] if p.get("is_fx_block") else [p]):
            out.append(("marker" if q.get("is_send_marker") else q["identifier"], q["id"], bool(p.get("is_fx_block"))))
    return out


def gs(app, pid):
    return app.cmd("plugin.gain_stage", plugin=pid)


def approx(a, b, eps=1e-3):
    return abs(a - b) <= eps


# ── one pass ─────────────────────────────────────────────────────────────────────────────────────

def run_pass(tag, channels):
    print("\n=== pass %s (%d channel%s) ===" % (tag, channels, "" if channels == 1 else "s"))
    work = os.path.join(ROOT, tag)
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    src = os.path.join(work, "source.wav")
    make_source(src, channels)
    base_proj = os.path.join(work, "base", "null.objekat")
    new_proj = os.path.join(work, "new", "null.objekat")
    os.makedirs(os.path.dirname(base_proj))
    os.makedirs(os.path.dirname(new_proj))

    # 1. the BASE app: fixture, save (format 24), inject, reopen, REF
    base = App(base_app, "/tmp/ogm_b.sock", os.path.join(work, "base.log"))
    try:
        require_audio(base, "base app")
        dry, patch, meta = build_fixture(base, src, work)
        base.cmd("project.save_as", path=base_proj)
        base.idle()
        with open(base_proj) as f:
            version = json.load(f).get("version")
        if version != 24:
            print("the base app saved format %s, not 24: it is not a usable base — exit 3" % version)
            base.close()
            sys.exit(3)
        check("%s: the base app writes format 24" % tag, True)
        inject(base_proj, patch)
        base.cmd("project.new")
        base.cmd("project.open", path=base_proj)
        base.idle()
        ids = meta["ids"]
        pl = base.cmd("plugin.list", host=ids["s1"])
        check("%s: the base read the injected trims (S1 -6 / +3)" % tag,
              approx(pl.get("chain_in_db", 0), -6) and approx(pl.get("chain_out_db", 0), 3), str(pl)[:300])
        pl = base.cmd("plugin.list", host=meta["stem"])
        check("%s: ...and the stem's (-3 / +2)" % tag,
              approx(pl.get("chain_in_db", 0), -3) and approx(pl.get("chain_out_db", 0), 2), str(pl)[:300])
        ref = export(base, os.path.join(work, "ref.wav"), meta["end"])
    finally:
        base.close()

    # 2. the NEW app: migration, checks, NEW, save
    new = App(NEW_APP, "/tmp/ogm_n.sock", os.path.join(work, "new.log"))
    try:
        require_audio(new, "new app")
        new.cmd("app.set_dialog_policy", policy="assume_yes")
        new.cmd("project.open", path=base_proj)
        new.idle()
        last = new.cmd("project.load_status").get("last_load") or {}
        report = last.get("legacy_gain_migration")
        check("%s: the migration report is what the fixture laid %s" % (tag, EXPECTED_REPORT),
              report == EXPECTED_REPORT, str(report))

        def ident_values(host):
            rows = []
            for ident, pid, in_block in stages_of(new, host):
                if ident in ("objGainStage", "objGainPanMute"):
                    v = gs(new, pid)
                    rows.append((ident, round(v["gain_db"], 3), round(v["pan"], 3), v["muted"], in_block))
                else:
                    rows.append((ident, in_block))
            return rows

        r1 = ident_values(ids["s1"])
        check("%s: S1 = [stage -6, compressor, stage +3]" % tag,
              r1 == [("objGainStage", -6.0, 0.0, False, False), ("compressor", False),
                     ("objGainStage", 3.0, 0.0, False, False)], str(r1))
        r2 = ident_values(ids["s2"])
        check("%s: S2 = [stage, compressor] (the trim in carries the curve)" % tag,
              [r[0] for r in r2] == ["objGainStage", "compressor"], str(r2))
        s2_stage = next((pid for ident, pid, _ in stages_of(new, ids["s2"]) if ident == "objGainStage"), None)
        r3a, r3b = ident_values(ids["s3a"]), ident_values(ids["s3b"])
        check("%s: S3 attached member = bin [compressor, gain+pan+mute -4.5 / 0.25]" % tag,
              r3a == [("compressor", True), ("objGainPanMute", -4.5, 0.25, False, True)], str(r3a))
        # A detach copies the bin's output into the block's local one (pan 0.25 included); the local
        # write then changed only the gain and the mute.
        check("%s: S3 detached member = its own [compressor, gain+pan+mute -6 / 0.25, muted]" % tag,
              r3b == [("compressor", True), ("objGainPanMute", -6.0, 0.25, True, True)], str(r3b))
        rs = ident_values(meta["stem"])
        check("%s: S4 stem = [stage -3, stage +2]" % tag,
              rs == [("objGainStage", -3.0, 0.0, False, False), ("objGainStage", 2.0, 0.0, False, False)], str(rs))
        rm = ident_values(meta["main"])
        check("%s: the Main = [stage -1]" % tag, rm == [("objGainStage", -1.0, 0.0, False, False)], str(rm))
        # The in stage goes BEFORE a chain tap's marker (the old trim in sat before every chain tap),
        # the out stage AFTER it; input / pre / post taps have no marker in the list.
        s_in, s_out, cmp_, mk = (("objGainStage", -12.0, 0.0, False, False), ("objGainStage", 6.0, 0.0, False, False),
                                 ("compressor", False), ("marker", False))
        for key, want in (("s5a", [s_in, cmp_, s_out]), ("s5b", [s_in, mk, cmp_, s_out]),
                          ("s5c", [s_in, cmp_, mk, s_out]), ("s5d", [s_in, cmp_, s_out]), ("s5e", [s_in, cmp_, s_out])):
            r5 = ident_values(ids[key])
            check("%s: %s = %s" % (tag, key, [w[0] for w in want]), r5 == want, str(r5))
        try:
            audit = new.cmd("debug.send_marker_audit")
            check("%s: send_marker_audit clean (5 senders judged)" % tag,
                  audit.get("ok") is True and audit.get("engine_senders_checked") == 5,
                  "%s %s" % (audit.get("violations"), audit.get("engine_senders_checked")))
        except ObjekatError as e:
            check("%s: send_marker_audit available (a DEBUG new app)" % tag, False, e.code)
        newx = export(new, os.path.join(work, "new.wav"), meta["end"])
        new.cmd("project.save_as", path=new_proj)
        new.idle()
        with open(new_proj) as f:
            saved = json.load(f)
        check("%s: the new app saves format 30" % tag, saved.get("version") == 30, saved.get("version"))
        # The API has no automation door: the curve is read from the saved file.
        s2_doc = find_object(saved, ids["s2"])
        lanes = (s2_doc or {}).get("automation") or []
        on_stage = [l for l in lanes if (l.get("param") or {}).get("type") == "plugin"
                    and str((l.get("param") or {}).get("pluginKey", "")).upper() == str(s2_stage).upper()]
        pts = [(round(q.get("t", 0), 3), round(q.get("v", 0), 3)) for q in (on_stage[0]["points"] if on_stage else [])]
        check("%s: S2's curve is re-aimed at its stage's gain, points mapped (dB+24)/48 (%s)" % (tag, pts),
              len(lanes) == 1 and len(on_stage) == 1 and pts == [(0.0, round((-18.0 + 24) / 48, 3)), (round(SRC_LEN, 3), round((6.0 + 24) / 48, 3))],
              json.dumps(lanes)[:300])
        left = legacy_keys_in(saved)
        check("%s: ...with none of the old keys" % tag, left == [], str(left[:10]))
    finally:
        new.close()

    # 3. a FRESH process reopens the save: NEW2
    fresh = App(NEW_APP, "/tmp/ogm_f.sock", os.path.join(work, "fresh.log"))
    try:
        require_audio(fresh, "new app (fresh)")
        fresh.cmd("app.set_dialog_policy", policy="assume_yes")
        fresh.cmd("project.open", path=new_proj)
        fresh.idle()
        last = fresh.cmd("project.load_status").get("last_load") or {}
        check("%s: reopened, nothing left to migrate" % tag,
              last.get("legacy_gain_migration") == {"trims": 0, "fx_outputs": 0, "automation_lanes": 0, "clamped": 0},
              str(last.get("legacy_gain_migration")))
        new2 = export(fresh, os.path.join(work, "new2.wav"), meta["end"])
    finally:
        fresh.close()

    # 4. the comparison
    check("%s: REF and NEW have the same shape" % tag,
          len(ref) == len(newx) and len(ref[0]) == len(newx[0]), "%d×%d / %d×%d" % (len(ref), len(ref[0]), len(newx), len(newx[0])))
    print("       %-36s %9s %9s %9s %8s %12s" % ("section", "dry dBFS", "REF dBFS", "NEW dBFS", "shift", "max|REF-NEW|"))
    for k, name in enumerate(SECTIONS):
        d_db, r_db, n_db = window_rms_db(dry, k), window_rms_db(ref, k), window_rms_db(newx, k)
        md = window_maxdiff(ref, newx, k)
        print("       %-36s %9.2f %9.2f %9.2f %+8.2f %9.2f LSB" % (name, d_db, r_db, n_db, r_db - d_db, md / LSB))
        check("%s %s: not silent (REF %.1f dBFS)" % (tag, name, r_db), r_db > -60.0)
        check("%s %s: |REF - NEW| <= 1 LSB after the first 20 ms" % (tag, name), md <= LSB * 1.0001,
              "%.2f LSB" % (md / LSB))
    same = all(ca == cb for ca, cb in zip(newx, new2)) and len(newx) == len(new2)
    check("%s: NEW2 (a fresh process on the saved file) == NEW bit for bit" % tag, same)


try:
    for tag, channels in (("mono", 1), ("stereo", 2)):
        if only and only != tag:
            continue
        run_pass(tag, channels)
except ObjekatError as e:
    fails.append("command refused: %s" % e)
    print("FAIL  a command was refused: %s" % e)

print()
print("%d checks, %d failed" % (total, len(fails)))
for f in fails:
    print("  FAILED: " + f)
sys.exit(1 if fails else 0)

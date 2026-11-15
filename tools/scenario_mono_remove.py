#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""REMOVING A ONE-INPUT (MONO 1 -> 1) PLUGIN TAKES ITS CHANNEL CHOICE WITH IT — the model, the engine and the SOUND.

The choice of channel on the cable that ENTERS a plugin with ONE input (left / right / sum: what lets a stereo
cable reach it) is that plugin's: it is written outside it — a PICK in the series between two cards, or the
file's own `channelMode` at the head of a stereo clip — and it must LEAVE with the plugin. Before this fix the
pick merged with the next gap (Q6, upstream wins) and the chain downstream stayed mono; at the head the
object stayed in mode C. The rule, checked here with Apple's AULowpass (installed with macOS) laid in mono
(1 -> 1) on a stereo file whose sides cannot be confused (L 440 Hz, R 1000 Hz, -20 dBFS), through gain stages
at 0 dB (bit-transparent: the export of such a chain IS the source):

  A  a mono plugin with NO choice written: its removal leaves a stereo chain (unchanged by the fix).
  B  a pick between two cards: it goes with the plugin, the chain after it is stereo again (L - R != 0),
     the engine lays no ObjChannelMode / fold half any more, the chain IS the source (0 LSB).
  C  the head of a stereo clip (the file's choice Sum, and Left): `channelMode` back to LR, in the model AND
     in the engine, the export is the source.
  D  a STEREO plugin with a pick before it (and a stereo plugin at the head of a clip with a file choice):
     the choice STAYS (same pick id, same sound as the choice alone).
  E  a parallel branch (the pick inside the branch goes) and an FX link bin (the pick of the DEFINITION and of
     both members goes; undo gives it back to both).
  F  a multiple removal (`plugin.remove_selected`): the picks of both plugins, and the file's choice, go in
     ONE step.
  G  undo / redo: ONE step gives the pick (or the file's choice) and the plugin back, the sound is the one
     of before (0 LSB); redo takes them away again (the same 0 LSB as the first removal).
  H  save and reopen (same process, then a new one): no phantom pick, `channelMode` LR, not modified.
  I  no window on the headless pid.

    ./scenario_mono_remove.py /path/to/objekat.app [--only A,B,...]

Headless, `--api --no-recent --language=en`. Exports: 48 kHz / 24 bit, no dither.
Exit: 0 if every assertion passes, 1 otherwise, 2 on bad usage.
"""

import json, math, os, shutil, struct, subprocess, sys, tempfile, time, wave

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

args = sys.argv[1:]
ONLY = None
if "--only" in args:
    i = args.index("--only")
    ONLY = set(args[i + 1].upper().split(","))
    del args[i:i + 2]
if len(args) != 1:
    print(__doc__)
    sys.exit(2)
APP = args[0]
EXE = os.path.join(APP, "Contents", "MacOS", "objekat") if APP.endswith(".app") else APP
if not os.path.exists(EXE):
    print("not an app bundle: %s" % APP)
    sys.exit(2)

WORK = tempfile.mkdtemp(prefix="objmrm_", dir="/tmp")
ok, ko = 0, 0
SKIPPED = []
LP = "AudioUnit:Effects/aufx,lpas,appl"
RV = "AudioUnit:Effects/aufx,rvb2,appl"     # stereo in / stereo out: gives a stereo cable back after a mono plugin
RATE = 48000
SECONDS = 2.0
EDGE = 128      # a clip has a short anti-click fade at each end: the comparisons leave it out
TOL = 2.0
STEREO_MIN = 100000   # max |L - R| of the source is ~ 838860: anything above is "still stereo", 0 is mono
ENGINE_HALVES = ("pick", "fold_in", "fold_out")


def section(title):
    print("\n── %s " % title + "─" * max(4, 74 - len(title)))


def check(label, cond, detail=""):
    global ok, ko
    if cond:
        ok += 1
        print("  OK   %s" % label)
    else:
        ko += 1
        print("  FAIL %s   %s" % (label, detail))


def skip(what):
    SKIPPED.append(what)
    print("  SKIP %s" % what)


# ── audio ─────────────────────────────────────────────────────────────────────────────────────────────

def write_wav(path, channels_hz, db=-20.0):
    amp = 10 ** (db / 20.0)
    frames = bytearray()
    for n in range(int(SECONDS * RATE)):
        for hz in channels_hz:
            frames += struct.pack("<i", int(round(amp * math.sin(2 * math.pi * hz * n / RATE) * 8388607)))[:3]
    with wave.open(path, "wb") as w:
        w.setnchannels(len(channels_hz)); w.setsampwidth(3); w.setframerate(RATE)
        w.writeframes(bytes(frames))


def read_pcm(path):
    with wave.open(path, "rb") as w:
        n_ch = w.getnchannels()
        raw = w.readframes(w.getnframes())
    n = len(raw) // (3 * n_ch)
    return [[int.from_bytes(raw[i * 3 * n_ch + c * 3:i * 3 * n_ch + c * 3 + 3], "little", signed=True) for i in range(n)]
            for c in range(n_ch)]


STEREO = os.path.join(WORK, "stereo_L440_R1000.wav")
write_wav(STEREO, (440.0, 1000.0))
SRC = read_pcm(STEREO)


def fold(choice, src=SRC):
    left, right = src
    if choice == "stereo":
        return [list(map(float, left)), list(map(float, right))]
    if choice == "left":
        return [list(map(float, left)), list(map(float, left))]
    if choice == "right":
        return [list(map(float, right)), list(map(float, right))]
    m = [(a + b) / 2.0 for a, b in zip(left, right)]
    return [m, list(m)]


def plus(a, b):
    return [[x + y for x, y in zip(a[0], b[0])], [x + y for x, y in zip(a[1], b[1])]]


def lr_diff(out):
    n = len(out[0])
    return max(abs(out[0][i] - out[1][i]) for i in range(EDGE, n - EDGE, 7))


def worst(out, exp):
    n = min(len(out[0]), len(exp[0]))
    return (max(max(abs(out[c][i] - exp[c][i]) for i in range(EDGE, n - EDGE)) for c in (0, 1)),
            len(out[0]) - len(exp[0]))


def exp_check(label, out, exp):
    mx, dlen = worst(out, exp)
    check("%s (max %.1f LSB off)" % (label, mx), mx <= TOL and dlen == 0, (mx, dlen))


def same_check(label, a, b):
    mx, dlen = worst(a, b)
    check("%s (max %.1f LSB off, length %+d)" % (label, mx, dlen), mx == 0 and dlen == 0, (mx, dlen))


# ── the instance ────────────────────────────────────────────────────────────────────────────────────

def pid_for_socket(sock_path):
    try:
        out = subprocess.check_output(["lsof", "-t", sock_path], text=True, stderr=subprocess.DEVNULL)
        pids = [int(p) for p in out.split()]
        return pids[0] if pids else None
    except Exception:
        return None


def window_count_for_pid(pid):
    try:
        import Quartz
    except ImportError:
        return None
    info = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionAll, Quartz.kCGNullWindowID)
    return sum(1 for w in info if w.get("kCGWindowOwnerPID") == pid)


class Instance:
    def __init__(self, tag):
        self.sock = os.path.join(WORK, tag + ".sock")
        if os.path.exists(self.sock):
            os.unlink(self.sock)
        self.proc = subprocess.Popen([EXE, "--headless", "--api", "--no-recent", "--language=en",
                                      "--socket=" + self.sock], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(160):
            if os.path.exists(self.sock):
                break
            time.sleep(0.25)
        else:
            self.proc.kill()
            raise RuntimeError("the app did not open its socket")
        self.client = ObjekatClient(self.sock, timeout=240).__enter__()
        self.send = self.client.send
        self.send("app.set_dialog_policy", {"policy": "assume_yes"})
        self.n_export = 0

    def close(self):
        try:
            self.client.__exit__(None, None, None)
        except Exception:
            pass
        self.proc.terminate()
        try:
            self.proc.wait(10)
        except Exception:
            self.proc.kill()

    # the project
    def idle(self):
        self.send("wait_idle")

    def fresh(self, name):
        self.send("project.new")
        manifest = os.path.join(WORK, name + ".objekat")
        self.send("project.save_as", {"path": manifest})
        oid = self.send("object.add", {"path": STEREO, "lane": 0, "start": 0.0})["id"]
        return manifest, oid

    def gs(self, host, series=None, index=None):
        p = {"host": host, "face": "gain"}
        if series is not None:
            p["series"] = series
        if index is not None:
            p["index"] = index
        return self.send("plugin.add_gain_stage", p)["plugin"]["id"]

    def lp(self, host, mono=True):
        """An AULowpass (cutoff wide open), mono 1 -> 1 unless told otherwise."""
        pid = self.send("plugin.add", {"host": host, "identifier": LP})["plugin"]["id"]
        for _ in range(160):
            if self.send("plugin.channel_layouts", {"host": host, "plugin": pid}).get("loaded"):
                break
            time.sleep(0.25)
        for i, q in enumerate(self.send("plugin.get_params", {"plugin": pid})["params"]):
            if "cutoff" in q["name"].lower():
                self.send("plugin.set_param", {"plugin": pid, "index": i, "value": q["max"]})
        if mono:
            self.send("plugin.set_channel_layout", {"host": host, "plugin": pid, "variant": "mono"})
        self.idle()
        return pid

    def rv(self, host):
        pid = self.send("plugin.add", {"host": host, "identifier": RV})["plugin"]["id"]
        self.wait_loaded(host, pid)
        self.idle()
        return pid

    def wait_loaded(self, host, pid):
        for _ in range(160):
            if self.send("plugin.channel_layouts", {"host": host, "plugin": pid}).get("loaded"):
                return
            time.sleep(0.25)

    def set_cable(self, host, index, choice, series=None):
        p = {"host": host, "index": index, "choice": choice}
        if series is not None:
            p["series"] = series
        r = self.send("chain.set_cable", p)
        self.idle()
        return r

    def cables(self, host, series=None):
        self.idle()
        rows = self.send("chain.cables", {"host": host})["cables"]
        return [r for r in rows if series is None or r["series"] == series]

    def entries(self, host):
        return self.send("plugin.list", {"host": host})["plugins"]

    def picks(self, host):
        """[(id, mode)] of every pick of the host's model, at any depth."""
        out = []

        def walk(es):
            for e in es:
                if e.get("is_channel_pick"):
                    out.append((e["id"], e["channel_pick"]["mode"]))
                for v in e.get("voices", []):
                    walk(v)
                if e.get("is_fx_block"):
                    walk(e.get("plugins", []))
        walk(self.entries(host))
        return out

    def shape(self, host):
        def one(e):
            if e.get("is_channel_pick"):
                return "p:" + e["channel_pick"]["mode"]
            if e.get("is_send_marker"):
                return "s"
            if e.get("is_rack"):
                return "[" + "|".join(" ".join(one(x) for x in v) for v in e["voices"]) + "]"
            if e.get("is_fx_block"):
                return "{" + " ".join(one(x) for x in e["plugins"]) + "}"
            return TAGS.get(e["id"], "?")
        return " ".join(one(e) for e in self.entries(host))

    def mode(self, host):
        d = self.send("object.get", {"id": host})
        d = d.get("object", d)
        return d.get("channel_mode"), d.get("engine_channel_mode")

    def engine(self, host):
        self.idle()
        return self.send("debug.engine_chain", {"id": host})["chain"]

    def export(self, tag):
        self.idle()
        self.n_export += 1
        path = os.path.join(WORK, "out_%03d_%s.wav" % (self.n_export, tag))
        r = self.send("export.run", {"format": "wav", "sample_rate": RATE, "bit_depth": 24, "dithering": False,
                                     "start": 0.0, "end": SECONDS, "path": path})
        self.send("job.wait", {"id": r["job_id"], "timeout_ms": 120000})
        if not os.path.exists(path):
            raise RuntimeError("the export %s produced no file" % tag)
        return read_pcm(path)

    def export2(self, tag):
        """The SECOND render: an AudioUnit's first one differs while its filter warms up."""
        self.export(tag + "_warm")
        return self.export(tag)

    def audits(self, label):
        self.idle()
        a = self.send("debug.plugin_id_audit")
        b = self.send("debug.send_marker_audit")
        check("audits clean (%s): no duplicated plugin id, no phantom marker" % label,
              a["count"] == 0 and a["engine_foreign_refusals"] == 0 and b["ok"], (a, b.get("violations")))


TAGS = {}


def tg(inst, host, name, series=None, index=None):
    pid = inst.gs(host, series, index)
    TAGS[pid] = name
    return pid


def tag_lp(inst, host, name, mono=True):
    pid = inst.lp(host, mono)
    TAGS[pid] = name
    return pid


def flat_lists(chain):
    out = [chain]
    for e in chain:
        if e.get("role") == "parallel":
            for b in e["branches"]:
                out.extend(flat_lists(b))
    return out


def engine_halves(inst, host):
    """The roles of the engine's chain that belong to a channel choice (pick, fold_in, fold_out), at any depth."""
    return [e.get("role") for lst in flat_lists(inst.engine(host)) for e in lst if e.get("role") in ENGINE_HALVES]


def clean_engine(label, inst, hosts):
    """No ObjChannelMode and no fold half left in the engine (the fold halves of a removed plugin included)."""
    left = [r for h in hosts for r in engine_halves(inst, h)]
    check("%s: the engine lays no ObjChannelMode and no fold half (no orphan)" % label, left == [], left)


def json_nodes(node, pred, out=None):
    out = [] if out is None else out
    if isinstance(node, dict):
        if pred(node):
            out.append(node)
        for v in node.values():
            json_nodes(v, pred, out)
    elif isinstance(node, list):
        for v in node:
            json_nodes(v, pred, out)
    return out


def widths(inst, host):
    return [r["width_in"] for r in inst.cables(host)]


# ═══════════════════════════════════════════════════════════════════════════════════════════════════════
# A — no choice written
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════

def section_A(inst):
    section("A: a mono plugin with no choice written — the removal leaves a stereo chain (unchanged)")
    _, o = inst.fresh("A")
    TAGS.clear()
    g1 = tg(inst, o, "G1")
    lp = tag_lp(inst, o, "LP")
    check("before: G1 LP, no pick", inst.shape(o) == "G1 LP" and inst.picks(o) == [], inst.shape(o))
    mono = inst.export2("A_before")
    check("before: the chain is MONO (L - R = 0)", lr_diff(mono) == 0, lr_diff(mono))
    inst.send("plugin.remove", {"host": o, "plugin": lp})
    inst.idle()
    check("after: G1", inst.shape(o) == "G1", inst.shape(o))
    out = inst.export("A_after")
    check("after: STEREO again (L - R = %d)" % lr_diff(out), lr_diff(out) > STEREO_MIN, lr_diff(out))
    exp_check("after: the chain is the source", out, fold("stereo"))
    check("after: every cable is stereo", set(widths(inst, o)) == {2}, widths(inst, o))
    clean_engine("after", inst, [o])
    inst.audits("A")


# ═══════════════════════════════════════════════════════════════════════════════════════════════════════
# B — a pick between two cards
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════

def build_B(inst, name, choice="sum"):
    manifest, o = inst.fresh(name)
    TAGS.clear()
    tg(inst, o, "G1")
    lp = tag_lp(inst, o, "LP")
    tg(inst, o, "G3")
    inst.set_cable(o, 1, choice)
    return manifest, o, lp


def section_B(inst):
    section("B: a pick between two cards goes with the mono plugin, the chain after it is stereo again")
    for choice in ("sum", "left", "right"):
        _, o, lp = build_B(inst, "B_" + choice, choice)
        check("[%s] before: G1 p:%s LP G3" % (choice, choice), inst.shape(o) == "G1 p:%s LP G3" % choice, inst.shape(o))
        mono = inst.export2("B_before_" + choice)
        check("[%s] before: the chain is MONO (L - R = 0)" % choice, lr_diff(mono) == 0, lr_diff(mono))
        inst.send("plugin.remove", {"host": o, "plugin": lp})
        inst.idle()
        check("[%s] after: G1 G3, the pick is gone" % choice, inst.shape(o) == "G1 G3" and inst.picks(o) == [],
              (inst.shape(o), inst.picks(o)))
        out = inst.export("B_after_" + choice)
        check("[%s] after: STEREO again (L - R = %d)" % (choice, lr_diff(out)), lr_diff(out) > STEREO_MIN, lr_diff(out))
        exp_check("[%s] after: the chain is the source" % choice, out, fold("stereo"))
        rows = inst.cables(o)
        check("[%s] after: chain.cables sees no pick and every cable stereo" % choice,
              not any(r.get("pick") for r in rows) and {r["width_in"] for r in rows} == {2}, rows)
        clean_engine("[%s] after" % choice, inst, [o])
    inst.audits("B")


# ═══════════════════════════════════════════════════════════════════════════════════════════════════════
# C — the head of a stereo clip: the file's own choice
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════

def build_C(inst, name, choice):
    manifest, o = inst.fresh(name)
    TAGS.clear()
    lp = tag_lp(inst, o, "LP")
    tg(inst, o, "G2")
    inst.set_cable(o, 0, choice)
    return manifest, o, lp


def section_C(inst):
    section("C: the head of a stereo clip — the file's choice goes back to LR with the mono plugin")
    for choice, code in (("sum", "c"), ("left", "l"), ("right", "r")):
        _, o, lp = build_C(inst, "C_" + choice, choice)
        check("[%s] before: channelMode %s, no pick" % (choice, code),
              inst.mode(o)[0] == code and inst.picks(o) == [], (inst.mode(o), inst.picks(o)))
        mono = inst.export2("C_before_" + choice)
        check("[%s] before: the chain is MONO (L - R = 0)" % choice, lr_diff(mono) == 0, lr_diff(mono))
        inst.send("plugin.remove", {"host": o, "plugin": lp})
        inst.idle()
        check("[%s] after: channelMode lr in the model AND in the engine" % choice,
              inst.mode(o) == ("lr", "lr"), inst.mode(o))
        check("[%s] after: G2 alone" % choice, inst.shape(o) == "G2", inst.shape(o))
        out = inst.export("C_after_" + choice)
        check("[%s] after: STEREO again (L - R = %d)" % (choice, lr_diff(out)), lr_diff(out) > STEREO_MIN, lr_diff(out))
        exp_check("[%s] after: the file as it is" % choice, out, fold("stereo"))
        check("[%s] after: the head cable reads Stereo, not explicit" % choice,
              (inst.cables(o)[0]["choice"], bool(inst.cables(o)[0].get("file_level"))) == ("stereo", True),
              inst.cables(o)[0])
        clean_engine("[%s] after" % choice, inst, [o])
    inst.audits("C")


# ═══════════════════════════════════════════════════════════════════════════════════════════════════════
# D — a STEREO plugin: the choice stays
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════

def section_D(inst):
    section("D: a STEREO plugin with a choice in front of it — the choice stays")
    _, o = inst.fresh("D")
    TAGS.clear()
    tg(inst, o, "G1")
    lp = tag_lp(inst, o, "LP", mono=False)
    tg(inst, o, "G3")
    inst.set_cable(o, 1, "sum")
    before = inst.picks(o)
    check("before: G1 p:sum LP G3", inst.shape(o) == "G1 p:sum LP G3" and len(before) == 1, inst.shape(o))
    inst.send("plugin.remove", {"host": o, "plugin": lp})
    inst.idle()
    check("after: G1 p:sum G3 — the pick is KEPT, same id", inst.shape(o) == "G1 p:sum G3" and inst.picks(o) == before,
          (inst.shape(o), inst.picks(o), before))
    exp_check("after: the sound is the choice alone (Sum on both sides)", inst.export("D_after"), fold("sum"))

    _, o2 = inst.fresh("D2")
    TAGS.clear()
    lp2 = tag_lp(inst, o2, "LP", mono=False)
    tg(inst, o2, "G2")
    inst.set_cable(o2, 0, "right")
    check("head, before: channelMode r", inst.mode(o2)[0] == "r", inst.mode(o2))
    inst.send("plugin.remove", {"host": o2, "plugin": lp2})
    inst.idle()
    check("head, after: channelMode STAYS r (model and engine)", inst.mode(o2) == ("r", "r"), inst.mode(o2))
    exp_check("head, after: the file's right side on both", inst.export("D2_after"), fold("right"))
    inst.audits("D")


# ═══════════════════════════════════════════════════════════════════════════════════════════════════════
# E — a parallel branch, an FX link bin
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════

def rack_voices(inst, host):
    return [len(e["voices"]) for e in inst.entries(host) if e.get("is_rack")]


def section_E(inst):
    section("E1: a parallel branch — the pick inside the branch goes with the mono plugin")
    _, o = inst.fresh("E1")
    TAGS.clear()
    tg(inst, o, "G1")
    g2 = tg(inst, o, "G2")
    lp = tag_lp(inst, o, "LP")
    inst.send("plugin.select", {"host": o, "plugins": [g2, lp]})
    block = inst.send("plugin.branch", {"host": o, "plugin": g2})["block"]
    inst.idle()
    series = "voice-%s-0" % block
    inst.set_cable(o, 1, "left", series=series)
    check("before: one pick, inside the branch", len(inst.picks(o)) == 1, (inst.shape(o), inst.picks(o)))
    inst.send("plugin.remove", {"host": o, "plugin": lp})
    inst.idle()
    check("after: no pick anywhere (%s)" % inst.shape(o), inst.picks(o) == [], inst.shape(o))
    clean_engine("after", inst, [o])
    voices = rack_voices(inst, o)
    exp = fold("stereo") if not voices else plus(fold("stereo"), fold("stereo"))
    exp_check("after: the sound is %s" % ("the source (the branch was folded back)" if not voices
                                          else "the branch + the dry one (2 x the source)"),
              inst.export("E1_after"), exp)
    inst.audits("E1")

    section("E2: an FX link bin — the pick of the definition and of every member goes; undo gives it back")
    _, a = inst.fresh("E2")
    TAGS.clear()
    ga = tg(inst, a, "A1")
    lpa = tag_lp(inst, a, "LP")
    link = inst.send("fxlink.create", {"host": a, "plugins": [ga, lpa]})
    lid = link["id"] if "id" in link else link["link"]["id"]
    blk_a = next(e for e in inst.entries(a) if e.get("is_fx_block"))["id"]
    b = inst.send("object.add", {"path": STEREO, "lane": 1, "start": 0.0})["id"]
    inst.send("fxlink.attach", {"link": lid, "host": b})
    inst.idle()
    blk_bE = next(e for e in inst.entries(b) if e.get("is_fx_block"))
    blk_b = blk_bE["id"]
    lpb = next(x["id"] for x in blk_bE["plugins"] if x.get("identifier") == LP)
    inst.wait_loaded(b, lpb)
    inst.set_cable(a, 1, "sum", series="block-" + blk_a)
    rows_b = inst.cables(b, "block-" + blk_b)
    if not (len(rows_b) > 1 and rows_b[1].get("pick") and rows_b[1].get("offered") == ["left", "right", "sum"]):
        skip("E2 (the member's plugin is not a loaded one-input one: %s)" % rows_b)
        return
    check("before: both members hold the pick (a: %s, b: %s)" % (len(inst.picks(a)), len(inst.picks(b))),
          len(inst.picks(a)) == 1 and len(inst.picks(b)) == 1, (inst.picks(a), inst.picks(b)))
    state_before = (inst.shape(a), inst.shape(b))
    inst.send("plugin.remove", {"host": a, "plugin": next(
        x["id"] for x in next(e for e in inst.entries(a) if e.get("is_fx_block"))["plugins"]
        if x.get("identifier") == LP)})
    inst.idle()
    check("after: no pick on either member", inst.picks(a) == [] and inst.picks(b) == [], (inst.shape(a), inst.shape(b)))
    definition = inst.send("fxlink.get", {"link": lid})
    live = json_nodes(definition, lambda d: bool(d.get("channel_pick")) or d.get("is_channel_pick") is True)
    check("after: no pick in the bin's DEFINITION nor in its members", live == [], live)
    clean_engine("after", inst, [a, b])
    exp_check("after: two members, both stereo: 2 x the source", inst.export("E2_after"), plus(fold("stereo"), fold("stereo")))
    inst.audits("E2")
    inst.send("edit.undo")
    inst.idle()
    check("undo (ONE step): the plugin and the pick are back on both (%s | %s)" % (inst.shape(a), inst.shape(b)),
          (inst.shape(a), inst.shape(b)) == state_before and len(inst.picks(a)) == 1 and len(inst.picks(b)) == 1,
          (inst.shape(a), inst.shape(b), state_before))
    inst.send("edit.redo")
    inst.idle()
    check("redo: gone again", inst.picks(a) == [] and inst.picks(b) == [], (inst.shape(a), inst.shape(b)))
    inst.audits("E2 after undo / redo")


# ═══════════════════════════════════════════════════════════════════════════════════════════════════════
# F — a multiple removal
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════

def section_F(inst):
    section("F: a multiple removal — the picks and the file's choice of every mono plugin go, in ONE step")
    _, o = inst.fresh("F")
    TAGS.clear()
    tg(inst, o, "G1")
    lp1 = tag_lp(inst, o, "LP1")
    rv = inst.rv(o); TAGS[rv] = "RV"        # a mono plugin makes the cable after it mono: the reverb makes it stereo again
    lp2 = tag_lp(inst, o, "LP2")
    tg(inst, o, "G5")
    inst.set_cable(o, 1, "left")
    inst.set_cable(o, 3, "right")
    before = "G1 p:left LP1 RV p:right LP2 G5"
    check("before: %s" % before, inst.shape(o) == before, inst.shape(o))
    inst.send("plugin.select", {"host": o, "plugins": [lp1, lp2]})
    r = inst.send("plugin.remove_selected")
    inst.idle()
    check("two removed", r.get("removed") == 2, r)
    check("after: G1 RV G5, no pick left", inst.shape(o) == "G1 RV G5" and inst.picks(o) == [], inst.shape(o))
    check("after: every cable is stereo", set(widths(inst, o)) == {2}, widths(inst, o))
    clean_engine("after", inst, [o])
    inst.send("edit.undo")
    inst.idle()
    check("ONE undo gives the whole batch back", inst.shape(o) == before, inst.shape(o))
    inst.audits("F")

    # the head of the clip AND a pick, a stereo plugin that stays after them
    _, o2 = inst.fresh("F2")
    TAGS.clear()
    lp1 = tag_lp(inst, o2, "LP1")
    rv = inst.rv(o2); TAGS[rv] = "RV"
    lp2 = tag_lp(inst, o2, "LP2")
    st = tag_lp(inst, o2, "ST", mono=False)
    inst.set_cable(o2, 0, "sum")
    inst.set_cable(o2, 2, "right")
    before = "LP1 RV p:right LP2 ST"
    check("head + pick, before: mode c, %s" % before, inst.mode(o2)[0] == "c" and inst.shape(o2) == before,
          (inst.mode(o2), inst.shape(o2)))
    inst.send("plugin.select", {"host": o2, "plugins": [lp1, lp2]})
    inst.send("plugin.remove_selected")
    inst.idle()
    check("head + pick, after: mode lr (model and engine), RV ST, no pick",
          inst.mode(o2) == ("lr", "lr") and inst.shape(o2) == "RV ST" and inst.picks(o2) == [],
          (inst.mode(o2), inst.shape(o2)))
    clean_engine("head + pick", inst, [o2])
    inst.send("edit.undo")
    inst.idle()
    check("head + pick: ONE undo gives back the file's choice, the pick and both plugins",
          inst.mode(o2) == ("c", "c") and inst.shape(o2) == before, (inst.mode(o2), inst.shape(o2)))
    inst.audits("F2")


# ═══════════════════════════════════════════════════════════════════════════════════════════════════════
# G — undo / redo
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════

def section_G(inst):
    section("G: undo / redo — ONE step, the sound of before (0 LSB), then removed again (0 LSB)")
    _, o, lp = build_B(inst, "G_B", "sum")
    pick = inst.picks(o)
    before = inst.export2("G_B_before")
    inst.send("plugin.remove", {"host": o, "plugin": lp})
    inst.idle()
    after = inst.export("G_B_after")
    inst.send("edit.undo")
    inst.idle()
    check("pick between two cards: ONE undo gives back G1 p:sum LP G3 with the SAME pick",
          inst.shape(o) == "G1 p:sum LP G3" and inst.picks(o) == pick, (inst.shape(o), inst.picks(o), pick))
    same_check("…the mono sound is the one of before", inst.export2("G_B_undo"), before)
    check("…and mono (L - R = 0)", lr_diff(inst.export("G_B_undo_m")) == 0)
    inst.send("edit.redo")
    inst.idle()
    check("redo: G1 G3, no pick", inst.shape(o) == "G1 G3" and inst.picks(o) == [], inst.shape(o))
    same_check("…the sound is the one of the first removal", inst.export("G_B_redo"), after)
    clean_engine("redo", inst, [o])
    inst.audits("G / B")

    _, o2, lp2 = build_C(inst, "G_C", "sum")
    before = inst.export2("G_C_before")
    inst.send("plugin.remove", {"host": o2, "plugin": lp2})
    inst.idle()
    after = inst.export("G_C_after")
    check("head: removed, mode lr", inst.mode(o2) == ("lr", "lr"), inst.mode(o2))
    inst.send("edit.undo")
    inst.idle()
    check("head: ONE undo gives back LP and channelMode c (model AND engine)",
          inst.shape(o2) == "LP G2" and inst.mode(o2) == ("c", "c"), (inst.shape(o2), inst.mode(o2)))
    same_check("…the mono sound is the one of before", inst.export2("G_C_undo"), before)
    inst.send("edit.redo")
    inst.idle()
    check("head, redo: G2, mode lr (model AND engine)", inst.shape(o2) == "G2" and inst.mode(o2) == ("lr", "lr"),
          (inst.shape(o2), inst.mode(o2)))
    same_check("…the sound is the one of the first removal", inst.export("G_C_redo"), after)
    clean_engine("head, redo", inst, [o2])
    inst.audits("G / C")


# ═══════════════════════════════════════════════════════════════════════════════════════════════════════
# H — save and reopen
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════

def section_H(inst):
    section("H: save and reopen — no phantom pick, channelMode LR, not modified")
    manifest, o, lp = build_B(inst, "H_B", "sum")
    inst.send("plugin.remove", {"host": o, "plugin": lp})
    inst.idle()
    # a second object of the project: the head case
    o2 = inst.send("object.add", {"path": STEREO, "lane": 1, "start": 0.0})["id"]
    lp2 = tag_lp(inst, o2, "LP")
    tg(inst, o2, "G2")
    inst.set_cable(o2, 0, "sum")
    inst.send("plugin.remove", {"host": o2, "plugin": lp2})
    inst.idle()
    sound = inst.export("H_before")
    inst.send("project.save")
    doc = json.load(open(manifest))
    check("the file holds no channelPick and no channel mode but LR",
          json_nodes(doc, lambda d: "channelPick" in d) == []
          and all(d.get("channelMode") in (None, "lr") for d in json_nodes(doc, lambda d: "channelMode" in d)),
          (len(json_nodes(doc, lambda d: "channelPick" in d)),
           [d.get("channelMode") for d in json_nodes(doc, lambda d: "channelMode" in d)]))
    inst.send("project.open", {"path": manifest})
    inst.idle()
    check("same process: no phantom pick, both objects LR",
          inst.picks(o) == [] and inst.picks(o2) == [] and inst.mode(o2) == ("lr", "lr") and inst.mode(o) == ("lr", "lr"),
          (inst.picks(o), inst.picks(o2), inst.mode(o), inst.mode(o2)))
    same_check("same process: the same sound", inst.export("H_same"), sound)
    clean_engine("same process", inst, [o, o2])
    inst.audits("H, same process")
    check("a project opened as it was is not modified", not inst.send("app.info")["dirty"])

    inst2 = Instance("reopen")
    try:
        inst2.send("project.open", {"path": manifest})
        inst2.idle()
        check("NEW process: no phantom pick, both objects LR",
              inst2.picks(o) == [] and inst2.picks(o2) == [] and inst2.mode(o2) == ("lr", "lr")
              and inst2.mode(o) == ("lr", "lr"), (inst2.picks(o), inst2.picks(o2), inst2.mode(o), inst2.mode(o2)))
        same_check("NEW process: the same sound", inst2.export("H_new"), sound)
        clean_engine("NEW process", inst2, [o, o2])
        check("…and not modified by the load", not inst2.send("app.info")["dirty"])
    finally:
        inst2.close()


# ═══════════════════════════════════════════════════════════════════════════════════════════════════════
# main
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════

inst = Instance("main")
try:
    pid = pid_for_socket(inst.sock)

    def wanted(name):
        return ONLY is None or name in ONLY

    for name, fn in (("A", section_A), ("B", section_B), ("C", section_C), ("D", section_D), ("E", section_E),
                     ("F", section_F), ("G", section_G), ("H", section_H)):
        if wanted(name):
            fn(inst)
    if wanted("I"):
        section("I: no window on the headless pid")
        n = window_count_for_pid(pid) if pid else None
        if n is None:
            skip("I (Quartz or the pid is not available)")
        else:
            check("no window opened by the headless instance (pid %s)" % pid, n == 0, n)
finally:
    inst.close()
    shutil.rmtree(WORK, ignore_errors=True)

print("\n%d passed, %d failed%s" % (ok, ko, ("   (skipped: %d)" % len(SKIPPED)) if SKIPPED else ""))
sys.exit(0 if ko == 0 else 1)

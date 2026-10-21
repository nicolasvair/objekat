#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""A CHOICE OF CHANNEL ON EVERY CABLE (session format 31) — the model, the engine and the SOUND, end to end.

docs/plan_archi_choix_canal_cable.md, test plan, sections A to K. `scenario_channel_picks.py` proves the
structure (the entries of a chain, the engine's instances, the API); this one proves what is HEARD, with a
stereo source whose two sides cannot be confused (L = 440 Hz, R = 1000 Hz, -20 dBFS) and chains made of GAIN
STAGES at 0 dB, which are bit-transparent: the export of a chain with no choice IS the source, so every
other export can be compared SAMPLE FOR SAMPLE with what the choice must produce.

    ./scenario_cable_channels.py /path/to/objekat.app [--base-app /path/to/format-30 objekat.app] [--only B,C,...]

  A  non-regression: a project written by the BASE app (format 30: external one-input plugins with a
     `monoFold` left / right / sum / absent, a bin, a parallel block, a mono -> stereo plugin) is opened by
     the new build. Not modified by the load, no pick invented, the engine lays no ObjChannelMode, a save
     keeps every `monoFold` key as it was, and the export is the BASE's own export (0 LSB). Needs
     `--base-app`; without it the section says so and is skipped.
  B  every kind of cable, Left / Right / Sum then Stereo: head of a stereo clip (the file's own channel mode),
     between two cards, tail of the root, entry / inside / exit of a parallel branch, the empty branch, around
     and inside a bin, the head of a group, a stem's chain, an aux's chain. For each: the model
     (`chain.cables`), the engine (`debug.engine_chain`: one ObjChannelMode of that mode, at that place)
     and the sound (L -> 440 Hz on both sides, R -> 1000 Hz, Sum = (L + R) / 2, Stereo = the original).
  C  the entry of a one-input plugin: left / right / sum only, the choice replaces the plugin's own fold
     (key cleared), only the OUT half is laid, the sound is the chosen side processed.
  D  a mono cable has nothing to choose (a mono file included).
  E  undo / redo: one step per setting, applied in place (no other card is rebuilt), then redone.
  F  moves: a card moved keeps the picks on their cables, a card inserted on a chosen cable receives the choice.
  G  copies: duplicate, copy / paste, cut, card copy (picks not carried), consolidate then export, a bin
     (a new member, detached then reattached, the choice reaches every member), a paste between projects.
  H  save and reopen, in the same process and in a NEW one: same picks, same ids, same sound.
  I  the alias `plugin.set_mono_fold` writes a pick (also proved in C).
  J  a send and a pick on the same cable: the send hears the picked channel; `send.list` does not move.
  K  no window on the headless pid.

Both processes run headless, `--api --no-recent --language=en`, audio ON (the sends ride the bridge's clock;
section J and the aux case of B are skipped, and said so, when no device is running).
Exports: 48 kHz / 24 bit, no dither. Exit: 0 if every assertion passes, 1 otherwise, 2 on bad usage.
"""

import json, math, os, shutil, struct, subprocess, sys, tempfile, time, wave

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

args = sys.argv[1:]
BASE_APP = None
if "--base-app" in args:
    i = args.index("--base-app")
    BASE_APP = args[i + 1]
    del args[i:i + 2]
ONLY = None
if "--only" in args:
    i = args.index("--only")
    ONLY = set(args[i + 1].upper().split(","))
    del args[i:i + 2]
if len(args) != 1:
    print(__doc__)
    sys.exit(2)

APP = args[0]


def exe_of(app):
    return os.path.join(app, "Contents", "MacOS", "objekat") if app.endswith(".app") else app


if not os.path.exists(exe_of(APP)):
    print("not an app bundle: %s" % APP)
    sys.exit(2)

WORK = tempfile.mkdtemp(prefix="objcc_", dir="/tmp")
ok, ko = 0, 0
SKIPPED = []

AU_LOWPASS = "AudioUnit:Effects/aufx,lpas,appl"
AU_REVERB2 = "AudioUnit:Effects/aufx,rvb2,appl"
RATE = 48000
SECONDS = 2.0
CHOICES = ("left", "right", "sum")


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


# ── audio files ─────────────────────────────────────────────────────────────────────────────────────────

def write_wav(path, channels_hz, db=-20.0, seconds=SECONDS):
    amp = 10 ** (db / 20.0)
    frames = bytearray()
    for n in range(int(seconds * RATE)):
        for hz in channels_hz:
            frames += struct.pack("<i", int(round(amp * math.sin(2 * math.pi * hz * n / RATE) * 8388607)))[:3]
    with wave.open(path, "wb") as w:
        w.setnchannels(len(channels_hz))
        w.setsampwidth(3)
        w.setframerate(RATE)
        w.writeframes(bytes(frames))


def read_pcm(path):
    """[[ints of channel 0], [ints of channel 1]] (24-bit, as stored)."""
    with wave.open(path, "rb") as w:
        assert w.getsampwidth() == 3
        n_ch = w.getnchannels()
        raw = w.readframes(w.getnframes())
    n = len(raw) // (3 * n_ch)
    return [[int.from_bytes(raw[i * 3 * n_ch + c * 3:i * 3 * n_ch + c * 3 + 3], "little", signed=True) for i in range(n)]
            for c in range(n_ch)]


STEREO = os.path.join(WORK, "stereo_L440_R1000.wav")
MONO = os.path.join(WORK, "mono_1k.wav")
write_wav(STEREO, (440.0, 1000.0))
write_wav(MONO, (1000.0,))
SRC = read_pcm(STEREO)


def fold(choice, src):
    """The two channels a signal has after `choice` (floats, in 24-bit steps)."""
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


TOL = 2.0       # LSB of 24 bits: a gain stage at 0 dB and a sum are exact to a rounding, a wrong channel is 1000s off
EDGE = 128      # a clip has a short anti-click fade (about 64 samples) at each end: the comparison leaves it out


def worst(out, exp, edge=EDGE):
    n = min(len(out[0]), len(exp[0]))
    return max(max(abs(out[c][i] - exp[c][i]) for i in range(edge, n - edge)) for c in (0, 1)), len(out[0]) - len(exp[0])


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
    """One headless instance of an app, on its own short socket, audio ON."""

    def __init__(self, app, tag):
        self.sock = os.path.join(WORK, tag + ".sock")
        if os.path.exists(self.sock):
            os.unlink(self.sock)
        self.proc = subprocess.Popen([exe_of(app), "--headless", "--api", "--no-recent", "--language=en",
                                      "--socket=" + self.sock], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(160):
            if os.path.exists(self.sock):
                break
            time.sleep(0.25)
        else:
            self.proc.kill()
            raise RuntimeError("the app did not open its socket: %s" % app)
        self.client = ObjekatClient(self.sock, timeout=240).__enter__()
        self.send = self.client.send
        self.send("app.set_dialog_policy", {"policy": "assume_yes"})

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


class Rig:
    """The helpers of one instance."""

    def __init__(self, inst):
        self.inst = inst
        self.send = inst.send
        self.n_export = 0

    # -- the project ----------------------------------------------------------------------------------
    def fresh(self, name, wav=None, lane=0):
        self.send("project.new")
        manifest = os.path.join(WORK, name + ".objekat")
        self.send("project.save_as", {"path": manifest})
        oid = self.send("object.add", {"path": wav or STEREO, "lane": lane, "start": 0.0})["id"]
        return manifest, oid

    def idle(self):
        self.send("wait_idle")

    def gs(self, host, series=None, index=None):
        p = {"host": host, "face": "gain"}
        if series is not None:
            p["series"] = series
        if index is not None:
            p["index"] = index
        return self.send("plugin.add_gain_stage", p)["plugin"]["id"]

    def entries(self, host):
        return self.send("plugin.list", {"host": host})["plugins"]

    # -- export -----------------------------------------------------------------------------------------
    def export(self, tag):
        self.idle()
        self.n_export += 1
        path = os.path.join(WORK, "out_%03d_%s.wav" % (self.n_export, tag))
        r = self.send("export.run", {"format": "wav", "sample_rate": RATE, "bit_depth": 24, "dithering": False,
                                     "start": 0.0, "end": SECONDS, "path": path})
        done = self.send("job.wait", {"id": r["job_id"], "timeout_ms": 120000})
        if not os.path.exists(path):
            raise RuntimeError("the export %s produced no file: %s" % (tag, json.dumps(done)[:400]))
        return read_pcm(path)

    # -- the cables ---------------------------------------------------------------------------------------
    def cables(self, host, series=None):
        self.idle()
        rows = self.send("chain.cables", {"host": host})["cables"]
        return [r for r in rows if series is None or r["series"] == series]

    def set_cable(self, host, index, choice, series=None):
        p = {"host": host, "index": index, "choice": choice}
        if series is not None:
            p["series"] = series
        r = self.send("chain.set_cable", p)
        self.idle()
        return r

    # -- the engine ---------------------------------------------------------------------------------------
    def engine(self, host):
        self.idle()
        return self.send("debug.engine_chain", {"id": host})["chain"]


def flat_lists(chain):
    """Every list of engine entries of a chain (the root, then each parallel branch), depth first."""
    out = [chain]
    for e in chain:
        if e.get("role") == "parallel":
            for b in e["branches"]:
                out.extend(flat_lists(b))
    return out


def engine_picks(chain):
    """[(mode, key, next_fx_key, list_length)] for every pick of the engine chain."""
    out = []
    for lst in flat_lists(chain):
        for i, e in enumerate(lst):
            if e.get("role") == "pick":
                nxt = next((x.get("key") for x in lst[i + 1:] if x.get("role") in ("fx", "parallel")), None)
                out.append((e["mode"], e.get("key"), nxt, len(lst)))
    return out


def lc(x):
    return x.lower() if isinstance(x, str) else x


# ═══════════════════════════════════════════════════════════════════════════════════════════════════════
# B — every kind of cable
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════

CHANNEL_MODE_OF = {"stereo": "lr"}      # the file's own channel mode at the head of a stereo clip


def stereo_exp(choice):
    return fold(choice, SRC)


def doubled(choice):
    f = fold(choice, SRC)
    return plus(f, f)


def with_dry(choice):
    return plus(fold(choice, SRC), fold("stereo", SRC))


def case_head(rig):
    _, o = rig.fresh("head")
    rig.gs(o)
    return dict(host=o, series=None, index=0, file_level=True, enter=None, exp=stereo_exp)


def case_between(rig):
    _, o = rig.fresh("between")
    rig.gs(o)
    g2 = rig.gs(o)
    return dict(host=o, series=None, index=1, enter=g2, exp=stereo_exp)


def case_tail(rig):
    _, o = rig.fresh("tail")
    rig.gs(o)
    return dict(host=o, series=None, index=1, enter=None, exp=stereo_exp)


def make_rack(rig, name):
    """G1, then a parallel block of (G2 G3) and an EMPTY branch. Returns the object, G2, G3, the block."""
    _, o = rig.fresh(name)
    rig.gs(o)
    g2, g3 = rig.gs(o), rig.gs(o)
    rig.send("plugin.select", {"host": o, "plugins": [g2, g3]})
    block = rig.send("plugin.branch", {"host": o, "plugin": g2})["block"]
    return o, g2, g3, block


def voice(block, n):
    return "voice-%s-%d" % (block, n)


def case_branch(index, name):
    def build(rig):
        o, g2, g3, block = make_rack(rig, name)
        enter = {0: g2, 1: g3, 2: None}[index]
        return dict(host=o, series=voice(block, 0), index=index, enter=enter, exp=with_dry)
    return build


def case_empty_branch(rig):
    o, g2, g3, block = make_rack(rig, "emptybranch")
    return dict(host=o, series=voice(block, 1), index=0, enter=None, exp=with_dry)


def case_around_rack(index, name):
    def build(rig):
        o, g2, g3, block = make_rack(rig, name)
        return dict(host=o, series=None, index=index, enter=block if index == 1 else None, exp=doubled,
                    eng_next=block if index == 1 else None)
    return build


def make_bin(rig, name):
    """G0 {bin: G1 G2} G3. Returns the object, the bin block, its two instances."""
    _, o = rig.fresh(name)
    g0, g1, g2, g3 = (rig.gs(o) for _ in range(4))
    link = rig.send("fxlink.create", {"host": o, "plugins": [g1, g2]})
    lid = link["id"] if "id" in link else link["link"]["id"]
    block = next(e for e in rig.entries(o) if e.get("is_fx_block"))
    inst = [m["id"] for m in block["plugins"]]
    root = [e["id"] for e in rig.entries(o)]
    return o, block["id"], inst, root[-1], lid


def case_bin_inside(index, name):
    def build(rig):
        o, block, inst, g3, _ = make_bin(rig, name)
        enter = {0: inst[0], 1: inst[1], 2: None}[index]
        # the engine's chain is flat across a bin: past the bin's tail the next card is the one after the bin
        return dict(host=o, series="block-" + block, index=index, enter=enter, exp=stereo_exp,
                    eng_next=enter if index < 2 else g3)
    return build


def case_around_bin(index, name):
    def build(rig):
        o, block, inst, g3, _ = make_bin(rig, name)
        return dict(host=o, series=None, index=index, enter=block if index == 1 else g3, exp=stereo_exp,
                    eng_next=inst[0] if index == 1 else g3)
    return build


def case_group(index, name):
    def build(rig):
        _, o = rig.fresh(name)
        gid = rig.send("group.create", {"ids": [o]})["id"]
        g = rig.gs(gid)
        return dict(host=gid, series=None, index=index, enter=g if index == 0 else None, exp=stereo_exp)
    return build


def case_stem(rig):
    _, o = rig.fresh("stem")
    sid = rig.send("stem.add", {"name": "S"})["id"]
    rig.send("stem.assign", {"stem": sid, "ids": [o]})
    g = rig.gs(sid)
    return dict(host=sid, series=None, index=0, enter=g, exp=stereo_exp)


def case_aux(rig):
    _, o = rig.fresh("aux")
    aux = rig.send("aux.create", {"start": 0.0, "end": SECONDS, "lane": 3})["id"]
    g = rig.gs(aux)
    rig.send("send.create", {"id": o, "aux": aux})
    rig.send("send.set_level", {"id": o, "aux": aux, "db": 0.0})
    return dict(host=aux, series=None, index=0, enter=g, exp=with_dry)


CASES = [
    ("the head of a stereo clip (the file's own channel mode)", case_head, False),
    ("between two cards", case_between, False),
    ("the tail of the root, before the mixer", case_tail, False),
    ("the entry of a parallel branch", case_branch(0, "bentry"), False),
    ("inside a parallel branch", case_branch(1, "binside"), False),
    ("the exit of a parallel branch", case_branch(2, "bexit"), False),
    ("the EMPTY branch of a parallel block", case_empty_branch, False),
    ("round a parallel block, before it", case_around_rack(1, "rackin"), False),
    ("round a parallel block, after it", case_around_rack(2, "rackout"), False),
    ("the head of a bin", case_bin_inside(0, "bin0"), False),
    ("inside a bin", case_bin_inside(1, "bin1"), False),
    ("the tail of a bin", case_bin_inside(2, "bin2"), False),
    ("round a bin, before it", case_around_bin(1, "binin"), False),
    ("round a bin, after it", case_around_bin(2, "binout"), False),
    ("the head of a group's chain", case_group(0, "group0"), False),
    ("the tail of a group's chain", case_group(1, "group1"), False),
    ("a stem's chain", case_stem, False),
    ("an aux's chain (a send at 0 dB feeds it)", case_aux, True),
]


def run_case(rig, name, build, needs_audio, audio_running):
    section("B: " + name)
    if needs_audio and not audio_running:
        skip("%s (no audio device running: the send rides the bridge's clock)" % name)
        return
    case = build(rig)
    host, series, index = case["host"], case["series"], case["index"]
    series = series or "root"
    rows0 = rig.cables(host, series)
    row0 = rows0[index]
    check("the cable exists and is stereo (2 wide), nothing written", row0["width_in"] == 2 and row0["choice"] == "stereo"
          and not row0["explicit"], row0)
    if case.get("enter"):
        check("it enters the card the case names", lc(row0["entering"]) == lc(case["enter"]), (row0["entering"], case["enter"]))
    check("it offers all four choices", row0["offered"] == ["stereo", "left", "right", "sum"], row0["offered"])
    base = rig.export("base")
    w, dlen = worst(base, case["exp"]("stereo"))
    check("no choice: the export IS the source (gain stages at 0 dB are transparent, within %g LSB)" % TOL,
          w <= TOL and dlen == 0, (w, dlen))
    for choice in CHOICES + ("stereo",):
        r = rig.set_cable(host, index, choice, series)
        check("%s: set_cable answers ok" % choice, r["ok"] and r["changed"] and r["choice"] == choice, r)
        rows = rig.cables(host, series)
        row = rows[index]
        check("%s: the model reads the choice (%s)" % (choice, "explicit" if choice != "stereo" else "nothing written"),
              row["choice"] == choice and row["explicit"] == (choice != "stereo"), row)
        if index + 1 < len(rows):
            nxt = rows[index + 1]
            want = 2 if choice == "stereo" else 1
            check("%s: the cable after it is %d wide%s" % (choice, want, "" if want == 2 else " and offers nothing"),
                  nxt["width_in"] == want and (want == 2 or nxt["offered"] == []), nxt)
        picks = engine_picks(rig.engine(host)) if not case.get("file_level") else []
        if case.get("file_level"):
            mode = rig.send("object.get", {"id": host})["channel_mode"]
            check("%s: the file's own channel mode says so, and the engine lays NO pick" % choice,
                  (mode == "lr") == (choice == "stereo") and not engine_picks(rig.engine(host)), mode)
        elif choice == "stereo":
            check("stereo: the engine lays no pick", not picks, picks)
        else:
            eng_next = case.get("eng_next", case.get("enter"))
            good = (len(picks) == 1 and picks[0][0] == choice and lc(picks[0][1]) == lc(row["pick"])
                    and lc(picks[0][2]) == lc(eng_next))
            check("%s: the engine lays ONE ObjChannelMode (%s), keyed by the pick, right before %s" %
                  (choice, choice, "the card" if eng_next else "nothing (the tail of its list)"), good, picks)
        out = rig.export(choice)
        w, dlen = worst(out, case["exp"](choice))
        tol = TOL
        check("%s: the sound is %s (max %.1f LSB off%s)" % (
            choice, {"left": "L on both sides", "right": "R on both sides", "sum": "(L + R) / 2 on both sides",
                     "stereo": "the original"}[choice], w, "" if dlen == 0 else ", length %+d" % dlen),
              w <= tol and dlen == 0, (w, dlen))


def section_B(rig, audio_running):
    for name, build, needs_audio in CASES:
        run_case(rig, name, build, needs_audio, audio_running)


# ═══════════════════════════════════════════════════════════════════════════════════════════════════════
# helpers shared by the sections below
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════

TAGS = {}


def tg(rig, host, name, series=None, index=None):
    """A gain stage, remembered under a short name."""
    pid = rig.gs(host, series, index)
    TAGS[pid] = name
    return pid


def entries(rig, host):
    return rig.send("plugin.list", {"host": host})["plugins"]


def walk_entries(es):
    for e in es:
        yield e
        for v in e.get("voices", []):
            yield from walk_entries(v)
        if e.get("is_fx_block"):
            yield from walk_entries(e["plugins"])


def pick_list(rig, host):
    """[(id, mode)] of every pick of a host, depth first."""
    return [(e["id"], e["channel_pick"]["mode"]) for e in walk_entries(entries(rig, host)) if e.get("is_channel_pick")]


def pick_modes(rig, host):
    return [m for _, m in pick_list(rig, host)]


def shape(rig, host):
    """The chain as a word: cards by their tag, 'p:left' for a pick, [..|..] for a rack, {..} for a bin."""
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
    return " ".join(one(e) for e in entries(rig, host))


def audits(rig, label):
    rig.idle()
    a = rig.send("debug.plugin_id_audit")
    b = rig.send("debug.send_marker_audit")
    check("audits clean (%s): no duplicated plugin id, no phantom marker" % label,
          a["count"] == 0 and a["engine_foreign_refusals"] == 0 and b["ok"], (a, b.get("violations")))


def fx_instances(chain):
    """{key: engine instance} of the cards, the fader and the window of a ROOT chain (no pick)."""
    return {e["key"] if e.get("key") else e["role"]: e["instance"] for e in chain
            if e.get("role") in ("fx", "fader", "windowFade")}


def roles_of(chain):
    return [e.get("role") for e in flat_lists(chain)[0]]


def exp_check(label, out, exp, edge=EDGE, skips=()):
    n = min(len(out[0]), len(exp[0]))
    mx = 0.0
    for c in (0, 1):
        for i in range(edge, n - edge):
            if any(a <= i < b for a, b in skips):
                continue
            mx = max(mx, abs(out[c][i] - exp[c][i]))
    check("%s (max %.1f LSB off)" % (label, mx), mx <= TOL and len(out[0]) == len(exp[0]), (mx, len(out[0]), len(exp[0])))
    return mx


def tone_db(samples, hz, t0=0.5, t1=1.9):
    a, b = int(t0 * RATE), int(t1 * RATE)
    seg = [x / 8388608.0 for x in samples[a:b]]
    n = len(seg)
    coeff = 2 * math.cos(2 * math.pi * hz / RATE)
    s1 = s2 = 0.0
    for x in seg:
        s0 = x + coeff * s1 - s2
        s2, s1 = s1, s0
    power = s1 * s1 + s2 * s2 - coeff * s1 * s2
    amp = 2 * math.sqrt(max(power, 0.0)) / n
    return 20 * math.log10(amp) if amp > 1e-10 else -200.0


def tones(out):
    return {(side, hz): tone_db(out[i], hz) for i, side in enumerate("LR") for hz in (440.0, 1000.0)}


def near(a, b, tol=0.7):
    return abs(a - b) <= tol


def tone_check(label, out, which):
    """which: 'left' (440 Hz on both sides at -20), 'right' (1000 Hz), 'sum' (both at -26.02), 'stereo'."""
    t = tones(out)
    if which == "left":
        good = all(near(t[s, 440.0], -20) and t[s, 1000.0] < -70 for s in "LR")
    elif which == "right":
        good = all(near(t[s, 1000.0], -20) and t[s, 440.0] < -70 for s in "LR")
    elif which == "sum":
        good = all(near(t[s, hz], -26.02) for s in "LR" for hz in (440.0, 1000.0))
    else:
        good = near(t["L", 440.0], -20) and near(t["R", 1000.0], -20) and t["L", 1000.0] < -70 and t["R", 440.0] < -70
    check("%s: %s" % (label, {"left": "440 Hz on both sides, no 1 kHz", "right": "1 kHz on both sides, no 440 Hz",
                              "sum": "both tones at -26 dBFS on both sides", "stereo": "the original (L 440, R 1 kHz)"}[which]),
          good, {"%s%d" % k: round(v, 1) for k, v in t.items()})


def wait_loaded(rig, host, plugin, timeout=40.0):
    deadline = time.time() + timeout
    r = rig.send("plugin.channel_layouts", {"host": host, "plugin": plugin})
    while not r.get("loaded") and time.time() < deadline:
        time.sleep(0.25)
        r = rig.send("plugin.channel_layouts", {"host": host, "plugin": plugin})
    return r


def layouts(rig, host, plugin):
    rig.idle()
    return rig.send("plugin.channel_layouts", {"host": host, "plugin": plugin})


def add_plugin(rig, host, ident):
    p = rig.send("plugin.add", {"host": host, "identifier": ident})["plugin"]["id"]
    wait_loaded(rig, host, p)
    return p


def open_filter(rig, plugin):
    ps = rig.send("plugin.get_params", {"plugin": plugin})["params"]
    for i, p in enumerate(ps):
        if "cutoff" in p["name"].lower():
            rig.send("plugin.set_param", {"plugin": plugin, "index": i, "value": p["max"]})
            return True
    return False


def export2(rig, tag):
    """The SECOND render: an AudioUnit's first one differs while its filter warms up."""
    rig.export(tag + "_warm")
    return rig.export(tag)


def refused(fn):
    try:
        fn()
        return None
    except ObjekatError as e:
        return e


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


def saved_json(rig, manifest):
    rig.send("project.save")
    return json.load(open(manifest))


def picked(rig, name, mode="left", wav=None):
    """An object with G1 G2 G3 and a pick on the cable between G1 and G2. Returns (manifest, object, [g1, g2, g3])."""
    manifest, o = rig.fresh(name, wav=wav)
    g = [tg(rig, o, "G%d" % (i + 1)) for i in range(3)]
    rig.set_cable(o, 1, mode)
    return manifest, o, g


# ═══════════════════════════════════════════════════════════════════════════════════════════════════════
# C — the entry of a one-input plugin
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════

def section_C(rig):
    section("C: the entry of a one-input plugin (AULowpass folded to mono, 1 -> 1, opened to the top)")
    manifest, o = rig.fresh("oneinput")
    tg(rig, o, "G1")
    lp = add_plugin(rig, o, AU_LOWPASS)
    TAGS[lp] = "LP"
    check("the filter is opened to its top", open_filter(rig, lp))
    rig.send("plugin.set_channel_layout", {"host": o, "plugin": lp, "variant": "mono"})
    rig.idle()
    row = rig.cables(o, "root")[1]
    check("the cable in front of the plugin goes into ONE input: left / right / sum, no stereo",
          row["into_one_input"] and row["offered"] == ["left", "right", "sum"], row)
    check("nothing set by the hand: it reads sum, no pick (the plugin's own fold, as on main)",
          row["choice"] == "sum" and row["pick"] is None, row)
    lay = layouts(rig, o, lp)
    check("the plugin's own fold is sum and is NOT the cable's", lay["mono_fold"] == "sum" and not lay["mono_fold_from_cable"], lay)
    ch = rig.engine(o)
    check("the engine lays both halves (IN and OUT of the fold) and no pick",
          lay["fold_in"] and lay["fold_out"] and not engine_picks(ch)
          and "fold_in" in roles_of(ch) and "fold_out" in roles_of(ch), roles_of(ch))
    implicit = export2(rig, "implicit_sum")
    tone_check("implicit sum", implicit, "sum")

    rig.set_cable(o, 1, "sum")
    row = rig.cables(o, "root")[1]
    pk = engine_picks(rig.engine(o))
    check("sum set by hand: a pick is written on the cable", row["pick"] is not None and row["choice"] == "sum" and row["explicit"], row)
    lay = layouts(rig, o, lp)
    ch = rig.engine(o)
    check("the engine lays the pick and the OUT half only: no IN half any more",
          len(pk) == 1 and pk[0][0] == "sum" and lay["fold_in"] is None and lay["fold_out"] is not None
          and "fold_in" not in roles_of(ch) and "fold_out" in roles_of(ch), (pk, roles_of(ch)))
    explicit = export2(rig, "explicit_sum")
    mx, dlen = worst(explicit, implicit, edge=0)
    check("explicit sum == implicit sum, 0 LSB (the pick does what the plugin's IN half did)", mx == 0 and dlen == 0, (mx, dlen))

    for choice in ("left", "right", "sum"):
        rig.set_cable(o, 1, choice)
        pk = engine_picks(rig.engine(o))
        lay = layouts(rig, o, lp)
        check("%s: ONE pick (%s) before the plugin, the plugin reports it as its fold, no IN half" % (choice, choice),
              len(pk) == 1 and pk[0][0] == choice and lay["mono_fold"] == choice and lay["mono_fold_from_cable"]
              and lay["fold_in"] is None, (pk, lay.get("mono_fold"), lay.get("fold_in")))
        tone_check("%s through the filter" % choice, export2(rig, "lp_" + choice), choice)
    r = refused(lambda: rig.send("chain.set_cable", {"host": o, "index": 1, "choice": "stereo"}))
    check("stereo is refused on a cable into one input (not_offered)", r is not None and "not_offered" in str(r), r)

    section("C: the choice replaces the plugin's own fold in the FILE (monoFold key cleared)")
    rig.set_cable(o, 1, "left")
    doc = saved_json(rig, manifest)
    nodes = json_nodes(doc, lambda d: d.get("id") == lp and "identifier" in d)
    check("the plugin is written once", len(nodes) == 1, len(nodes))
    check("…without a monoFold key (the pick on its cable says it)", nodes and "monoFold" not in nodes[0], nodes[0].keys() if nodes else None)
    picks = json_nodes(doc, lambda d: "channelPick" in d)
    check("…and the pick is written: channelPick {mode: left}", len(picks) == 1 and picks[0]["channelPick"].get("mode") == "left", picks)
    check("the file is format 31", doc.get("version") == 31, doc.get("version"))

    section("C: the same plugin as a STEREO plugin: all four choices again")
    rig.send("plugin.set_channel_layout", {"host": o, "plugin": lp, "variant": "stereo"})
    rig.idle()
    row = rig.cables(o, "root")[1]
    check("a stereo plugin: the cable offers stereo, left, right, sum (the choice stands: left)",
          row["offered"] == ["stereo", "left", "right", "sum"] and row["choice"] == "left" and not row["into_one_input"], row)
    rig.set_cable(o, 1, "stereo")
    row = rig.cables(o, "root")[1]
    check("stereo again: the pick is gone", row["pick"] is None and row["choice"] == "stereo" and not pick_modes(rig, o), row)
    tone_check("stereo plugin, stereo cable", export2(rig, "stereo_back"), "stereo")


# ═══════════════════════════════════════════════════════════════════════════════════════════════════════
# D — a mono cable has nothing to choose
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════

def section_D(rig):
    section("D: a cable that is already mono has nothing to choose")
    _, o = rig.fresh("monocable")
    for n in ("G1", "G2", "G3"):
        tg(rig, o, n)
    rig.set_cable(o, 1, "left")
    rows = rig.cables(o, "root")
    check("after a pick the cables downstream are mono: width 1, nothing offered",
          all(r["width_in"] == 1 and r["offered"] == [] for r in rows[2:]), rows[2:])
    before = shape(rig, o)
    e = refused(lambda: rig.send("chain.set_cable", {"host": o, "index": 2, "choice": "right"}))
    check("a choice on a mono cable is refused (mono)", e is not None and "mono" in str(e).lower(), e)
    check("…and nothing moved", shape(rig, o) == before, shape(rig, o))
    exp_check("the sound is the left side on both", rig.export("mono_cable"), fold("left", SRC))

    section("D: a mono FILE has no choice anywhere")
    _, m = rig.fresh("monofile", wav=MONO)
    tg(rig, m, "G1")
    tg(rig, m, "G2")
    rows = rig.cables(m, "root")
    check("every cable of a mono file is mono and offers nothing", all(r["width_in"] == 1 and r["offered"] == [] for r in rows), rows)
    e = refused(lambda: rig.send("chain.set_cable", {"host": m, "index": 1, "choice": "left"}))
    check("a choice on it is refused", e is not None, e)
    mono = read_pcm(MONO)[0]
    exp_check("a mono file plays on both sides, nothing else changed", rig.export("mono_file"), [mono, list(mono)])

    section("D: a 1 -> 1 plugin makes the cable after it mono")
    _, o2 = rig.fresh("mono11")
    tg(rig, o2, "G1")
    lp = add_plugin(rig, o2, AU_LOWPASS)
    rig.send("plugin.set_channel_layout", {"host": o2, "plugin": lp, "variant": "mono"})
    rig.idle()
    rows = rig.cables(o2, "root")
    check("a 1 -> 1 plugin: the cable after it is mono and offers nothing",
          rows[-1]["width_in"] == 1 and rows[-1]["offered"] == [], rows[-1])


# ═══════════════════════════════════════════════════════════════════════════════════════════════════════
# E — undo / redo
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════

def section_E(rig):
    section("E: undo / redo — one step per setting, applied in place")
    _, o = rig.fresh("undo")
    g = [tg(rig, o, "G%d" % (i + 1)) for i in range(3)]
    base = fx_instances(rig.engine(o))
    check("the chain has its three cards, the fader and the window", len(base) == 5, base)
    rig.set_cable(o, 1, "left")
    check("left: one pick", pick_modes(rig, o) == ["left"], pick_modes(rig, o))
    exp_check("left: heard", rig.export("undo_left"), fold("left", SRC))
    rig.set_cable(o, 1, "right")
    check("right replaces left on the same cable (still one pick, same id)",
          pick_modes(rig, o) == ["right"], pick_modes(rig, o))
    pid = pick_list(rig, o)[0][0]
    inst_after = fx_instances(rig.engine(o))
    check("setting a pick rebuilt NO card: every instance is the one from before",
          inst_after == base, {k: (base.get(k), inst_after.get(k)) for k in base if base.get(k) != inst_after.get(k)})

    rig.send("edit.undo")
    rig.idle()
    check("undo (1): back to left — ONE step per setting", pick_modes(rig, o) == ["left"], pick_modes(rig, o))
    check("…applied in place: no card was rebuilt", fx_instances(rig.engine(o)) == base)
    exp_check("…and it is heard: the left side on both", rig.export("undo_1"), fold("left", SRC))
    rig.send("edit.undo")
    rig.idle()
    check("undo (2): no pick any more", pick_modes(rig, o) == [] and shape(rig, o) == "G1 G2 G3", shape(rig, o))
    check("…applied in place: no card was rebuilt", fx_instances(rig.engine(o)) == base)
    exp_check("…and the original is back", rig.export("undo_2"), fold("stereo", SRC))
    rig.send("edit.redo")
    rig.idle()
    check("redo (1): left again", pick_modes(rig, o) == ["left"], pick_modes(rig, o))
    rig.send("edit.redo")
    rig.idle()
    check("redo (2): right again, with the pick of the first time",
          pick_list(rig, o) and pick_list(rig, o)[0] == (pid, "right"), pick_list(rig, o))
    check("…applied in place", fx_instances(rig.engine(o)) == base)
    exp_check("…and it is heard: the right side on both", rig.export("redo_2"), fold("right", SRC))
    r = rig.set_cable(o, 1, "right")
    check("setting what is already there changes nothing and says so", r["ok"] and not r["changed"], r)
    rig.send("edit.undo")
    rig.idle()
    check("…it took no undo step: one undo goes to left", pick_modes(rig, o) == ["left"], pick_modes(rig, o))
    audits(rig, "after the undo / redo round")


# ═══════════════════════════════════════════════════════════════════════════════════════════════════════
# F — moves
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════

def section_F(rig):
    section("F: a card moved — the picks stay on their cables")
    _, o = rig.fresh("moves")
    g1, g2, g3 = (tg(rig, o, "G%d" % n) for n in (1, 2, 3))
    rig.set_cable(o, 2, "left")
    pid = pick_list(rig, o)[0][0]
    check("start: G1 G2 p:left G3", shape(rig, o) == "G1 G2 p:left G3", shape(rig, o))
    exp_check("start: the sound is the left side", rig.export("f_start"), fold("left", SRC))

    rig.send("plugin.drop_at", {"from": o, "plugin": g1, "host": o, "series": "root", "at": 3})
    rig.idle()
    check("G1 moved to the end: G2 p:left G3 G1 — the pick kept its id and its cable",
          shape(rig, o) == "G2 p:left G3 G1" and pick_list(rig, o) == [(pid, "left")], (shape(rig, o), pick_list(rig, o)))
    pk = engine_picks(rig.engine(o))
    check("the engine follows: the pick right before G3", len(pk) == 1 and lc(pk[0][2]) == lc(g3), pk)
    exp_check("…still the left side", rig.export("f_move_end"), fold("left", SRC))
    rig.send("edit.undo")
    rig.idle()
    check("undo: G1 G2 p:left G3", shape(rig, o) == "G1 G2 p:left G3", shape(rig, o))

    rig.send("plugin.drop_at", {"from": o, "plugin": g1, "host": o, "series": "root", "at": 2})
    rig.idle()
    check("G1 dropped on the chosen cable: it lands after the pick and receives the choice (G2 p:left G1 G3)",
          shape(rig, o) == "G2 p:left G1 G3" and pick_list(rig, o) == [(pid, "left")], shape(rig, o))
    exp_check("…the left side", rig.export("f_move_cable"), fold("left", SRC))
    rig.send("edit.undo")
    rig.idle()

    rig.send("plugin.drop_at", {"from": o, "plugin": g3, "host": o, "series": "root", "at": 0})
    rig.idle()
    check("G3 (after the pick) moved to the head: the pick stays where it was, one pick, same id",
          pick_list(rig, o) == [(pid, "left")] and shape(rig, o).count("p:") == 1, shape(rig, o))
    exp_check("…the sound is still the left side", rig.export("f_move_head"), fold("left", SRC))
    rig.send("edit.undo")
    rig.idle()
    check("undo: G1 G2 p:left G3", shape(rig, o) == "G1 G2 p:left G3", shape(rig, o))

    section("F: a card inserted on a chosen cable receives the choice")
    r = rig.send("plugin.add_gain_stage", {"host": o, "face": "gain", "index": 2})
    n1 = r["plugin"]["id"]
    TAGS[n1] = "N1"
    check("inserted at the cable: G1 G2 p:left N1 G3 (it is fed by the pick)", shape(rig, o) == "G1 G2 p:left N1 G3", shape(rig, o))
    exp_check("…the sound is the left side", rig.export("f_insert"), fold("left", SRC))
    rig.send("edit.undo")
    rig.idle()
    r = rig.send("plugin.add_gain_stage", {"host": o, "face": "gain", "index": 3})
    n2 = r["plugin"]["id"]
    TAGS[n2] = "N2"
    check("inserted at the end (past G3): G1 G2 p:left G3 N2 — the cable it enters is mono (left)",
          shape(rig, o) == "G1 G2 p:left G3 N2" and rig.cables(o, "root")[-2]["width_in"] == 1, shape(rig, o))
    rig.send("edit.undo")
    rig.idle()

    section("F: a card removed between two chosen cables — the upstream pick wins (a 1 -> 2 plugin lets the second cable be stereo)")
    _, o2 = rig.fresh("remove_between")
    h1 = tg(rig, o2, "H1")
    rv = add_plugin(rig, o2, AU_REVERB2)
    TAGS[rv] = "RV"
    rig.send("plugin.set_channel_layout", {"host": o2, "plugin": rv, "variant": "mono_stereo"})
    h3 = tg(rig, o2, "H3")
    rig.idle()
    rows = rig.cables(o2, "root")
    check("after a 1 -> 2 plugin the cable is stereo again", rows[-2]["width_in"] == 2 and rows[-2]["offered"], rows)
    rig.set_cable(o2, 1, "left")
    rig.set_cable(o2, 2, "right")
    check("two picks: H1 p:left RV p:right H3", shape(rig, o2) == "H1 p:left RV p:right H3", shape(rig, o2))
    rig.send("plugin.remove", {"host": o2, "plugin": rv})
    rig.idle()
    check("RV removed: the upstream pick wins, the downstream one goes (H1 p:left H3)",
          shape(rig, o2) == "H1 p:left H3", shape(rig, o2))
    exp_check("…the sound is the left side", rig.export("f_remove"), fold("left", SRC))
    rig.send("edit.undo")
    rig.idle()
    check("undo: both picks and RV are back", shape(rig, o2) == "H1 p:left RV p:right H3", shape(rig, o2))
    audits(rig, "after the moves")


# ═══════════════════════════════════════════════════════════════════════════════════════════════════════
# G — copies
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════

def section_G(rig, audio_running):
    f_left = fold("left", SRC)
    two_left = plus(f_left, f_left)

    section("G: duplicate — the copy has its own picks (fresh ids), in the same places, heard the same")
    _, o, g = picked(rig, "dup")
    saved = pick_list(rig, o)
    dup = rig.send("object.duplicate", {"ids": [o]})["ids"][0]
    rig.idle()
    rig.send("object.move", {"id": dup, "lane": 1, "start": 0.0})
    rig.idle()
    dp = pick_list(rig, dup)
    check("the duplicate holds one pick, left", [m for _, m in dp] == ["left"], dp)
    check("…with an id of its own (the id is the engine's key)", dp and dp[0][0] not in {i for i, _ in saved}, (dp, saved))
    check("the original keeps its pick, unchanged", pick_list(rig, o) == saved, pick_list(rig, o))
    exp_check("both play: 2 x the left side", rig.export("dup"), two_left)
    audits(rig, "after the duplicate")

    section("G: copy / paste of the object")
    _, o, g = picked(rig, "paste")
    saved = pick_list(rig, o)
    rig.send("selection.set", {"ids": [o]})
    rig.send("clipboard.copy")
    rig.send("caret.set", {"lane": 1, "time": 0.0})
    pasted = rig.send("clipboard.paste")["ids"]
    rig.idle()
    check("one object pasted", len(pasted) == 1, pasted)
    pp = pick_list(rig, pasted[0])
    check("the pasted object holds the pick, left, with a fresh id",
          [m for _, m in pp] == ["left"] and pp[0][0] not in {i for i, _ in saved}, (pp, saved))
    objs = rig.send("object.list")["objects"]
    check("two objects, the original untouched", len(objs) == 2 and pick_list(rig, o) == saved, objs)
    exp_check("both play: 2 x the left side", rig.export("paste"), two_left)
    audits(rig, "after the paste")

    section("G: cut — the two halves each hold the pick, with different ids; the sound is continuous")
    _, o, g = picked(rig, "cut")
    saved = pick_list(rig, o)
    rig.send("object.split_at", {"seconds": 1.0, "ids": [o]})
    rig.idle()
    objs = rig.send("object.list")["objects"]
    check("two halves", len(objs) == 2, objs)
    halves = [pick_list(rig, x["id"]) for x in objs]
    check("each half holds one pick, left", all([m for _, m in h] == ["left"] for h in halves), halves)
    check("…and the two ids differ (a key is one instance)", len({h[0][0] for h in halves}) == 2, halves)
    sk = int(1.0 * RATE)
    exp_check("the sound is the left side on both halves", rig.export("cut"), f_left, skips=[(sk - EDGE, sk + EDGE)])
    audits(rig, "after the cut")

    section("G: a card copied to another object — the pick is NOT carried")
    _, o, g = picked(rig, "cardcopy")
    o2 = rig.send("object.add", {"path": STEREO, "lane": 1, "start": 0.0})["id"]
    d1 = tg(rig, o2, "D1")
    rig.send("plugin.copy", {"from": o, "plugins": g, "to": o2})
    rig.idle()
    check("the destination holds its card and the three copies, and no pick",
          pick_modes(rig, o2) == [] and "p:" not in shape(rig, o2), shape(rig, o2))
    check("…the source keeps its pick", pick_modes(rig, o) == ["left"], pick_modes(rig, o))
    exp_check("the destination plays the original (no pick came with the cards), the source the left side",
              rig.export("cardcopy"), plus(f_left, fold("stereo", SRC)))
    audits(rig, "after the card copy")

    section("G: consolidate, then export — identical to the direct export")
    manifest, o, g = picked(rig, "consol")
    direct = rig.export("consol_direct")
    exp_check("direct: the left side", direct, f_left)
    mk = rig.send("consolidate.make", {"id": o})
    rig.send("job.wait", {"id": mk["job_id"], "timeout_ms": 120000})
    rig.idle()
    after = rig.export("consol_baked")
    mx, dlen = worst(after, direct)
    check("the consolidated object plays what the chain played (max %.1f LSB off, length %+d)" % (mx, dlen),
          mx <= TOL and dlen == 0, (mx, dlen))
    audits(rig, "after the consolidation")

    section("G: an FX link bin — the choice made inside it reaches every member, a late member and a re-attached one")
    _, a = rig.fresh("bin")
    ga, gb = tg(rig, a, "A1"), tg(rig, a, "A2")
    link = rig.send("fxlink.create", {"host": a, "plugins": [ga, gb]})
    lid = link["id"] if "id" in link else link["link"]["id"]
    blk_a = next(e for e in entries(rig, a) if e.get("is_fx_block"))["id"]
    b = rig.send("object.add", {"path": STEREO, "lane": 1, "start": 0.0})["id"]
    rig.send("fxlink.attach", {"link": lid, "host": b})
    rig.idle()
    blk_b = next(e for e in entries(rig, b) if e.get("is_fx_block"))["id"]
    rig.set_cable(a, 1, "left", series="block-" + blk_a)
    ra, rb = rig.cables(a, "block-" + blk_a)[1], rig.cables(b, "block-" + blk_b)[1]
    check("set on one member: the OTHER member's cable reads left too",
          ra["choice"] == "left" and rb["choice"] == "left" and rb["pick"] is not None, (ra, rb))
    check("…each member's pick has an id of its own",
          pick_list(rig, a)[0][0] != pick_list(rig, b)[0][0], (pick_list(rig, a), pick_list(rig, b)))
    exp_check("both play: 2 x the left side", rig.export("bin_two"), two_left)

    c_ = rig.send("object.add", {"path": STEREO, "lane": 2, "start": 0.0})["id"]
    rig.send("fxlink.attach", {"link": lid, "host": c_})
    rig.idle()
    blk_c = next(e for e in entries(rig, c_) if e.get("is_fx_block"))["id"]
    rc = rig.cables(c_, "block-" + blk_c)[1]
    check("a member attached LATER is born with the choice", rc["choice"] == "left" and rc["pick"] is not None, rc)
    exp_check("three play: 3 x the left side", rig.export("bin_three"), plus(two_left, f_left))

    rig.send("fxlink.detach", {"host": c_, "block": blk_c})
    rig.idle()
    blk_c = next(e for e in entries(rig, c_) if e.get("is_fx_block"))["id"]
    rc = rig.cables(c_, "block-" + blk_c)[1]
    check("detached: the host keeps an independent copy WITH the choice", rc["choice"] == "left" and rc["pick"] is not None, rc)
    rig.set_cable(a, 1, "right", series="block-" + blk_a)
    rb, rc = rig.cables(b, "block-" + blk_b)[1], rig.cables(c_, "block-" + blk_c)[1]
    check("the bin goes to right: the attached member follows, the detached one stays left",
          rb["choice"] == "right" and rc["choice"] == "left", (rb, rc))
    f_right = fold("right", SRC)
    exp_check("heard: 2 x right + 1 x left", rig.export("bin_detached"), plus(plus(f_right, f_right), f_left))
    rig.send("fxlink.reattach", {"host": c_, "block": blk_c})
    rig.idle()
    blk_c = next(e for e in entries(rig, c_) if e.get("is_fx_block"))["id"]
    rc = rig.cables(c_, "block-" + blk_c)[1]
    check("re-attached: the host realigns on the bin (right)", rc["choice"] == "right", rc)
    exp_check("heard: 3 x right", rig.export("bin_reattached"), plus(plus(f_right, f_right), f_right))
    ids = [i for h in (a, b, c_) for i, _ in pick_list(rig, h)]
    check("no pick id appears twice", len(ids) == len(set(ids)), ids)
    audits(rig, "after the bin")

    section("G: pasted into another project")
    src_manifest, o, g = picked(rig, "xsrc")
    saved = pick_list(rig, o)
    rig.send("project.save")
    tab_dst = rig.send("tab.new")
    dst_manifest = os.path.join(WORK, "xdst.objekat")
    rig.send("project.save_as", {"path": dst_manifest})
    tabs = rig.send("tab.list")["tabs"]
    src_tab = next(t for t in tabs if t["path"] and t["path"].endswith("xsrc.objekat"))
    dst_tab = tab_dst["id"]
    rig.send("tab.select", {"id": src_tab["id"]})
    rig.idle()
    rig.send("selection.set", {"ids": [o]})
    rig.send("clipboard.copy")
    rig.send("tab.select", {"id": dst_tab})
    rig.idle()
    pasted = rig.send("clipboard.paste")["ids"]
    rig.idle()
    pp = pick_list(rig, pasted[0])
    check("the object pasted in the other project holds the pick, left, with a fresh id",
          [m for _, m in pp] == ["left"] and pp[0][0] not in {i for i, _ in saved}, (pp, saved))
    exp_check("…and plays the left side", rig.export("xpaste"), f_left)
    audits(rig, "in the other project")
    rig.send("tab.close", {"id": dst_tab, "discard": True})
    rig.idle()
    check("the source project is untouched", pick_list(rig, o) == saved, pick_list(rig, o))


# ═══════════════════════════════════════════════════════════════════════════════════════════════════════
# H — save and reopen
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════

def snapshot(rig, hosts):
    return {h: ([(i, m) for i, m in pick_list(rig, h)],
                [(r["series"], r["index"], r["choice"], r["explicit"]) for r in rig.cables(h)]) for h in hosts}


def section_H(rig):
    section("H: save and reopen — in the same process, then in a new one")
    manifest, o, g = picked(rig, "reopen", mode="right")
    _, o2 = None, rig.send("object.add", {"path": STEREO, "lane": 1, "start": 0.0})["id"]
    a1, a2 = tg(rig, o2, "B1"), tg(rig, o2, "B2")
    link = rig.send("fxlink.create", {"host": o2, "plugins": [a1, a2]})
    blk = next(e for e in entries(rig, o2) if e.get("is_fx_block"))["id"]
    rig.set_cable(o2, 1, "left", series="block-" + blk)
    hosts = [o, o2]
    before = snapshot(rig, hosts)
    sound = rig.export("h_before")
    f_r, f_l = fold("right", SRC), fold("left", SRC)
    exp_check("before: right (object) + left (bin member)", sound, plus(f_r, f_l))
    audits(rig, "before the save")
    rig.send("project.save")
    doc = json.load(open(manifest))
    check("the file is format 31 and holds two channelPick entries (one in the bin's definition, one in the member)",
          doc.get("version") == 31 and len(json_nodes(doc, lambda d: "channelPick" in d)) >= 2,
          (doc.get("version"), len(json_nodes(doc, lambda d: "channelPick" in d))))
    rig.send("project.open", {"path": manifest})
    rig.idle()
    after = snapshot(rig, hosts)
    check("same process: same picks (ids and modes) and same cables", after == before, (before, after))
    exp_check("…same sound", rig.export("h_same"), plus(f_r, f_l))
    audits(rig, "after the reopening, same process")
    check("a project opened as it was is not modified", not rig.send("app.info")["dirty"])

    inst2 = Instance(APP, "reopen")
    try:
        rig2 = Rig(inst2)
        inst2.send("project.open", {"path": manifest})
        rig2.idle()
        after2 = snapshot(rig2, hosts)
        check("NEW process: same picks (ids and modes) and same cables", after2 == before, (before, after2))
        exp_check("…same sound", rig2.export("h_new"), plus(f_r, f_l))
        audits(rig2, "after the reopening, new process")
        check("…and not modified by the load", not inst2.send("app.info")["dirty"])
    finally:
        inst2.close()


# ═══════════════════════════════════════════════════════════════════════════════════════════════════════
# I — the alias plugin.set_mono_fold
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════

def section_I(rig):
    section("I: plugin.set_mono_fold is an alias — it writes a pick on the cable in front of the plugin, and it is heard")
    manifest, o = rig.fresh("alias")
    tg(rig, o, "G1")
    lp = add_plugin(rig, o, AU_LOWPASS)
    TAGS[lp] = "LP"
    open_filter(rig, lp)
    rig.send("plugin.set_channel_layout", {"host": o, "plugin": lp, "variant": "mono"})
    rig.idle()
    for choice in ("right", "left", "sum"):
        rig.send("plugin.set_mono_fold", {"host": o, "plugin": lp, "fold": choice})
        rig.idle()
        row = rig.cables(o, "root")[1]
        check("%s: the cable in front of the plugin carries a pick" % choice,
              row["pick"] is not None and row["choice"] == choice and row["explicit"], row)
        tone_check("%s, by the alias" % choice, export2(rig, "alias_" + choice), choice)
    e = refused(lambda: rig.send("plugin.set_mono_fold", {"host": o, "plugin": lp, "fold": "middle"}))
    check("a bad fold is refused", e is not None, e)


# ═══════════════════════════════════════════════════════════════════════════════════════════════════════
# J — a send and a pick on the same cable
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════

def section_J(rig, audio_running):
    section("J: a send and a pick on the same cable — the send hears the picked channel")
    if not audio_running:
        skip("J (no audio device running: the send rides the bridge's clock)")
        return
    _, o = rig.fresh("sendpick")
    tg(rig, o, "G1")
    tg(rig, o, "G2")
    aux = rig.send("aux.create", {"start": 0.0, "end": SECONDS, "lane": 3})["id"]
    rig.send("send.create", {"id": o, "aux": aux})
    rig.send("send.set_level", {"id": o, "aux": aux, "db": 0.0})
    rig.send("send.set_position", {"id": o, "aux": aux, "position": "chain", "index": 1})
    rig.idle()
    sends0 = rig.send("send.list", {"id": o})
    check("the send stands in the chain, between the two cards: G1 s G2",
          shape(rig, o) == "G1 s G2" and '"chain"' in json.dumps(sends0), (shape(rig, o), sends0))
    exp_check("no choice: dry + wet = 2 x the original", rig.export("j_base"), plus(fold("stereo", SRC), fold("stereo", SRC)))
    # the cable at index 1 is the one the marker stands on
    rig.set_cable(o, 1, "left")
    sh = shape(rig, o)
    check("a pick on that cable stands BEFORE the marker: G1 p:left s G2", sh == "G1 p:left s G2", sh)
    sends1 = rig.send("send.list", {"id": o})
    check("send.list does not move when a pick is added", sends1 == sends0, (sends0, sends1))
    f = fold("left", SRC)
    exp_check("the send hears the picked channel: dry (left) + wet (left)", rig.export("j_left"), plus(f, f))
    rig.set_cable(o, 1, "right")
    f = fold("right", SRC)
    exp_check("…right: dry (right) + wet (right)", rig.export("j_right"), plus(f, f))
    audits(rig, "send and pick")
    rig.send("edit.undo")
    rig.send("edit.undo")
    rig.idle()
    check("two undos: no pick, the send is where it was", shape(rig, o) == "G1 s G2", shape(rig, o))


# ═══════════════════════════════════════════════════════════════════════════════════════════════════════
# A — non-regression against the BASE build (session format 30)
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════

def mono_fold_table(doc):
    """{plugin id: monoFold or None} for every external plugin entry of a session file."""
    return {d["id"]: d.get("monoFold") for d in json_nodes(doc, lambda d: "identifier" in d and "id" in d and
                                                           str(d.get("identifier", "")).startswith("AudioUnit"))}


def a_build(brig, name, kind):
    """One project written by the BASE app. Returns (manifest, plugin ids that carry a fold)."""
    manifest, o = brig.fresh(name)
    fold_plugins = []
    if kind in ("left", "right", "sum", "absent"):
        tg(brig, o, "G1")
        lp = add_plugin(brig, o, AU_LOWPASS)
        open_filter(brig, lp)
        brig.send("plugin.set_channel_layout", {"host": o, "plugin": lp, "variant": "mono"})
        brig.send("plugin.set_mono_fold", {"host": o, "plugin": lp, "fold": "sum" if kind == "absent" else kind})
        fold_plugins.append(lp)
    elif kind == "head":
        lp = add_plugin(brig, o, AU_LOWPASS)
        open_filter(brig, lp)
        brig.send("plugin.set_channel_layout", {"host": o, "plugin": lp, "variant": "mono"})
        brig.send("plugin.set_mono_fold", {"host": o, "plugin": lp, "fold": "right"})
        fold_plugins.append(lp)
    elif kind == "mono_stereo":
        tg(brig, o, "G1")
        rv = add_plugin(brig, o, AU_REVERB2)
        brig.send("plugin.set_channel_layout", {"host": o, "plugin": rv, "variant": "mono_stereo"})
        brig.send("plugin.set_mono_fold", {"host": o, "plugin": rv, "fold": "left"})
        fold_plugins.append(rv)
    elif kind == "bin":
        tg(brig, o, "G1")
        lp = add_plugin(brig, o, AU_LOWPASS)
        open_filter(brig, lp)
        brig.send("plugin.set_channel_layout", {"host": o, "plugin": lp, "variant": "mono"})
        brig.send("plugin.set_mono_fold", {"host": o, "plugin": lp, "fold": "left"})
        g2 = tg(brig, o, "G2")
        brig.send("fxlink.create", {"host": o, "plugins": [lp, g2]})
        fold_plugins.append(lp)
    elif kind == "parallel":
        tg(brig, o, "G1")
        lp = add_plugin(brig, o, AU_LOWPASS)
        open_filter(brig, lp)
        brig.send("plugin.set_channel_layout", {"host": o, "plugin": lp, "variant": "mono"})
        brig.send("plugin.set_mono_fold", {"host": o, "plugin": lp, "fold": "left"})
        g3 = tg(brig, o, "G3")
        brig.send("plugin.select", {"host": o, "plugins": [lp, g3]})
        brig.send("plugin.branch", {"host": o, "plugin": lp})
        fold_plugins.append(lp)
    brig.idle()
    brig.send("project.save")
    return manifest, fold_plugins


A_KINDS = [("left", "a one-input plugin after a card, fold left"),
           ("right", "…fold right"),
           ("sum", "…fold sum"),
           ("absent", "…a file with NO monoFold key (read as sum)"),
           ("head", "a one-input plugin at the HEAD of the clip, fold right"),
           ("mono_stereo", "a mono -> stereo plugin (reverb), fold left"),
           ("bin", "a one-input plugin inside an FX bin, fold left"),
           ("parallel", "a one-input plugin inside a parallel block, fold left")]


def section_A(rig):
    section("A: non-regression — projects written by the BASE build (format 30), opened by this one")
    if not BASE_APP:
        skip("A (no --base-app: pass the format-30 build to compare against)")
        return
    base_inst = Instance(BASE_APP, "base")
    made = []
    try:
        brig = Rig(base_inst)
        for kind, _ in A_KINDS:
            manifest, fps = a_build(brig, "a_" + kind, kind)
            if kind == "absent":
                doc = json.load(open(manifest))
                for d in json_nodes(doc, lambda d: d.get("id") in fps and "monoFold" in d):
                    del d["monoFold"]
                json.dump(doc, open(manifest, "w"), indent=1)
                brig.send("project.open", {"path": manifest})
                brig.idle()
            doc = json.load(open(manifest))
            table = mono_fold_table(doc)
            out = export2(brig, "base_" + kind)
            made.append((kind, manifest, table, out, doc.get("version")))
    finally:
        base_inst.close()

    for kind, manifest, table, base_out, base_version in made:
        label = dict(A_KINDS)[kind]
        section("A: " + label)
        check("the base wrote format %s (not this build's)" % base_version, base_version is not None and base_version < 31, base_version)
        rig.send("project.open", {"path": manifest})
        rig.idle()
        check("opened by this build: not modified by the load", not rig.send("app.info")["dirty"])
        listing = rig.send("object.list")["objects"]
        hosts = [x["id"] for x in listing]
        check("the project holds its object (and it is not missing)", len(hosts) == 1 and not listing[0].get("missing"), listing)
        picks = [p for h in hosts for p in pick_list(rig, h)]
        check("no pick invented", picks == [], picks)
        engine_roles = [r for h in hosts for r in roles_of(rig.engine(h))]
        check("the engine lays no ObjChannelMode", "pick" not in engine_roles, engine_roles)
        explicit_rows = [r for h in hosts for r in rig.cables(h) if r.get("pick")]
        check("chain.cables sees no pick", explicit_rows == [], explicit_rows)
        out = export2(rig, "new_" + kind)
        mx, dlen = worst(out, base_out, edge=0)
        check("the export is the BASE's own: 0 LSB (max %.1f, length %+d)" % (mx, dlen), mx == 0 and dlen == 0, (mx, dlen))
        rig.send("project.save")
        again = mono_fold_table(json.load(open(manifest)))
        check("a save keeps every monoFold key as it was (%d plugin(s))" % len(table), again == table, (table, again))


# ═══════════════════════════════════════════════════════════════════════════════════════════════════════
# main
# ═══════════════════════════════════════════════════════════════════════════════════════════════════════

inst = Instance(APP, "main")
try:
    rig = Rig(inst)
    info = inst.send("app.info")
    audio_running = bool(info.get("audio_running"))
    print("audio running: %s (%s Hz)" % (audio_running, info.get("sample_rate")))
    pid = pid_for_socket(inst.sock)

    def wanted(name):
        return ONLY is None or name in ONLY

    if wanted("A"):
        section_A(rig)
    if wanted("B"):
        section_B(rig, audio_running)
    if wanted("C"):
        section_C(rig)
    if wanted("D"):
        section_D(rig)
    if wanted("E"):
        section_E(rig)
    if wanted("F"):
        section_F(rig)
    if wanted("G"):
        section_G(rig, audio_running)
    if wanted("H"):
        section_H(rig)
    if wanted("I"):
        section_I(rig)
    if wanted("J"):
        section_J(rig, audio_running)
    if wanted("K"):
        section("K: no window on the headless pid")
        n = window_count_for_pid(pid) if pid else None
        if n is None:
            skip("K (Quartz or the pid is not available)")
        else:
            check("no window opened by the headless instance (pid %s)" % pid, n == 0, n)
finally:
    inst.close()
    shutil.rmtree(WORK, ignore_errors=True)

print("\n%d passed, %d failed%s" % (ok, ko, ("   (skipped: %d)" % len(SKIPPED)) if SKIPPED else ""))
sys.exit(0 if ko == 0 else 1)

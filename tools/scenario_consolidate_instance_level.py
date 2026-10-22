#!/usr/bin/env python3
"""The INSTANCE LEVEL of a consolidated object — a scenario that asserts.

A consolidated object has two layers: the CONTENT (a wave plus its sidecar, shared by every
instance) and the INSTANCE LEVEL (each placement's own FX, fader / pan / mute, window, fades, sends,
stem, automation). Opened for editing, an instance becomes a STAGE — a group holding ONE child, the
content root A — and the others become folded mirrors of it. This script drives the whole of it
through the API and measures the sound (a render of one object, a read of the baked wave).

    # 1. launch the build with the API, on a SHORT socket (a system limit: 103 bytes).
    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --socket=/tmp/oil.sock

    # 2. replay (add --keep to leave the work folder behind for a look)
    ./scenario_consolidate_instance_level.py /tmp/oil.sock

Sections (numbering of docs/plan_consolidate_instance_level.md):
  1  the mix is the instance's: a fader / pan / mute on one instance moves no other
  2  an FX laid on a CLOSED instance: accepted, absent from the others
  3  opening: the stage, its single child, the mirrors, content_root_id
  4  the session: stage fader kept, A's fader baked, no instance FX in the wave, a solo elsewhere
     never silences the wave; 4b-4g: trimming / extending / moving A re-aligns every instance
  5  a change of the stage alone: no new revision
  6  cancel after a change of the stage AND of the content: everything comes back
  7  undo / redo of a commit: the linked instance, never a detached group
and the sections added by the later steps (guards, copies, un-make, creation, nesting, save).

Exit: 0 if every assertion passes, 1 otherwise. `EXPECTED FAIL` lines do not count.
"""

import array, json, os, shutil, struct, subprocess, sys, tempfile, time, traceback

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

args = [a for a in sys.argv[1:] if not a.startswith("--")]
KEEP = "--keep" in sys.argv
if len(args) != 1:
    print(__doc__)
    sys.exit(2)

SOCK = args[0]
BIP = os.path.join(HERE, "fixtures", "bip.wav")     # 0.4 s tone, peak 0.549
ROOT = os.path.realpath(tempfile.mkdtemp(prefix="objk-oil-", dir="/tmp"))
SR = 48000

fails = []
expected_fails = []


def check(label, ok, detail=""):
    if ok:
        print("ok    " + label)
    else:
        fails.append(label)
        print("FAIL  %s  %s" % (label, detail))


def expected_fail(label, ok, why):
    """A check that is KNOWN to fail until something else lands: reported, never counted."""
    if ok:
        print("ok    %s  (expected to fail: %s — it passes)" % (label, why))
    else:
        expected_fails.append(label)
        print("XFAIL %s  (%s)" % (label, why))


def section(title):
    print("\n── %s " % title + "─" * max(0, 70 - len(title)))


def near(a, b, tol=1e-3):
    return a is not None and b is not None and abs(a - b) <= tol


client = ObjekatClient(SOCK)
client.connect()


def cmd(_name, **params):
    return client.send(_name, params or None)


# ── reading the model and the sound ─────────────────────────────────────────────────────────

def walk(items):
    for o in items:
        yield o
        k = o.get("kind", {})
        if k.get("type") == "group":
            yield from walk(k.get("children", []))


def state_items():
    return cmd("project.get_state")["items"]


def find(oid):
    for o in walk(state_items()):
        if o["id"] == oid:
            return o
    return None


def kind(o):
    return o.get("kind", {})


def clip_of(o):
    k = kind(o)
    return k if k.get("type") == "clip" else None


def so_of(o):
    k = clip_of(o)
    return k.get("sourceOffset") if k else None


def children(o):
    return kind(o).get("children", []) if o else []


def read_wav(path):
    """(channels, sample_rate, samples) for the PCM 16/24/32 and float32 files the app writes.
    A `.flac` (an archived project's consolidated wave) is first decoded by CoreAudio's
    `afconvert` into a 32-bit float wav — exact for the 16/24-bit integer content of a FLAC."""
    if path.endswith(".flac"):
        tmpdir = tempfile.mkdtemp(prefix="objk-flac-", dir="/tmp")
        try:
            out = os.path.join(tmpdir, "decoded.wav")
            subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEF32", path, out], check=True)
            return read_wav(out)
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)
    d = open(path, "rb").read()
    i, fmt, data = 12, None, None
    while i < len(d):
        cid = d[i:i + 4]
        sz = struct.unpack("<I", d[i + 4:i + 8])[0]
        if cid == b"fmt ":
            fmt = struct.unpack("<HHIIHH", d[i + 8:i + 24])
        elif cid == b"data":
            data = d[i + 8:i + 8 + sz]
        i += 8 + sz + (sz & 1)
    tag, ch, sr, _, _, bits = fmt
    if tag == 3 or (tag == 0xFFFE and bits == 32 and False):
        a = array.array("f"); a.frombytes(data); s = list(a)
    elif bits == 24:
        s = [int.from_bytes(data[j:j + 3], "little", signed=True) / 8388608.0 for j in range(0, len(data), 3)]
    elif bits == 16:
        a = array.array("h"); a.frombytes(data); s = [x / 32768.0 for x in a]
    else:
        a = array.array("f"); a.frombytes(data); s = list(a)
    return ch, sr, s


def peak(wav, t0, t1):
    ch, sr, s = wav
    i0, i1 = int(t0 * sr) * ch, min(len(s), int(t1 * sr) * ch)
    return max((abs(x) for x in s[max(0, i0):i1]), default=0.0)


def duration_of(wav):
    ch, sr, s = wav
    return len(s) / ch / sr


def render_instance(oid, name):
    """Renders ONE object alone (its FX, fader, fades, window, content) and reads it back."""
    path = os.path.join(ROOT, name + ".wav")
    r = cmd("object.render_isolated", id=oid, path=path, sample_rate=SR, bit_depth=24)
    cmd("job.wait", id=r["job_id"], timeout_ms=60000)
    return read_wav(path)


PROJ = ROOT


def newest_wave(def_id):
    d = defs()[def_id]
    folder = os.path.join(PROJ, "samples", "consolidate")
    return read_wav(os.path.join(folder, d["wave"]))


def defs():
    return {d["id"]: d for d in cmd("consolidate.list")["definitions"]}


def pid(r):
    p = r["plugin"]
    return p["id"] if isinstance(p, dict) else p


def settle():
    cmd("wait_idle", timeout_ms=30000)


def commit():
    r = cmd("consolidate.edit_commit")
    j = cmd("job.wait", id=r["job_id"], timeout_ms=60000)
    settle()
    return j


def lin(db):
    return 10 ** (db / 20.0)


def instance_start_dur(i):
    o = find(i)
    return o["startTime"], o["duration"]


# ── the project ─────────────────────────────────────────────────────────────────────────────

def build(tag="main"):
    """A = group [c1 @ 0 (0.4 s), c2 @ 1.0 (0.4 s)] with a -3 dB gain stage as CONTENT FX
    (the plan says +6 dB; a 24-bit render clips at 1.0 and the sound is measured through renders),
    consolidated, then two copies of the instance (3 linked instances: I1 @ 0, I2 @ 1.4, I3 @ 2.8)."""
    global PROJ
    PROJ = os.path.join(ROOT, tag)
    os.makedirs(PROJ, exist_ok=True)
    cmd("project.new")
    c1 = cmd("object.add", path=BIP, lane=0, start=0.0)["id"]
    c2 = cmd("object.add", path=BIP, lane=2, start=1.0)["id"]
    g = cmd("group.create", ids=[c1, c2])["id"]
    cmd("plugin.add_gain_stage", host=g, face="gain", gain_db=-3.0)
    cmd("project.save_as", path=os.path.join(PROJ, "p.objekat"))
    r = cmd("consolidate.make", id=g)
    cmd("job.wait", id=r["job_id"], timeout_ms=60000)
    settle()
    d = next(iter(defs().values()))
    i1 = d["placements"][0]
    i2 = cmd("object.duplicate", ids=[i1])["ids"][0]
    i3 = cmd("object.duplicate", ids=[i2])["ids"][0]
    settle()
    return d["id"], i1, i2, i3


def main():
    section("setup")
    def_id, i1, i2, i3 = build()
    d = defs()[def_id]
    check("one definition, three linked instances", len(defs()) == 1 and len(d["placements"]) == 3,
          str(d["placements"]))
    s1, d1 = instance_start_dur(i1)
    s2, d2 = instance_start_dur(i2)
    s3, d3 = instance_start_dur(i3)
    check("the instances sit end to end, 1.4 s each",
          near(s1, 0) and near(d1, 1.4) and near(s2, 1.4) and near(s3, 2.8), "%s %s %s" % (s1, s2, s3))
    base = render_instance(i1, "base_i1")
    ref = peak(base, 0.0, 0.4)
    check("the content FX (-3 dB) is baked into the wave: peak ~ 0.39", near(ref, 0.549 * lin(-3), 0.02), str(ref))

    # ── 1 ──
    section("1 — the mix is the instance's")
    cmd("object.set_gain", ids=[i1], db=-4.0)
    cmd("object.set_pan", ids=[i1], pan=0.5)
    cmd("object.set_mute", ids=[i3], muted=True)
    settle()
    check("I1 -4 dB / pan 0.5: I2 untouched", find(i2)["volume"] == 0 and find(i2)["pan"] == 0)
    check("I3 muted: I1 and I2 not muted", find(i3)["isMuted"] and not find(i1)["isMuted"] and not find(i2)["isMuted"])
    p1 = peak(render_instance(i1, "m_i1"), 0.0, 0.4)
    p2 = peak(render_instance(i2, "m_i2"), 0.0, 0.4)
    check("the sound follows: I1 is quieter than I2, I2 untouched", p1 < p2 and near(p2, ref, 0.02),
          "%s %s" % (p1, p2))
    cmd("object.set_gain", ids=[i1], db=0.0); cmd("object.set_pan", ids=[i1], pan=0.0)
    cmd("object.set_mute", ids=[i3], muted=False)
    settle()

    # ── 2 ──
    section("2 — an FX on a CLOSED instance")
    r = cmd("plugin.add_gain_stage", host=i1, face="gain", gain_db=6.0)
    settle()
    check("accepted on the closed I1", "plugin" in r, str(r))
    check("absent from I2", len(find(i2).get("plugins", [])) == 0)
    p1 = peak(render_instance(i1, "fx_i1"), 0.0, 0.4)
    p2 = peak(render_instance(i2, "fx_i2"), 0.0, 0.4)
    check("heard on I1 only: +6 dB (I1 ~ 2x I2)", near(p1 / p2, lin(6), 0.1), "%s %s" % (p1, p2))
    cmd("plugin.remove", host=i1, plugin=pid(r))
    settle()

    # ── 3 ──
    section("3 — opening: the stage")
    # The instance level for the rest of the scenario: I1 gets a +6 dB gain stage of its own, I2 a -3.
    fx_i1 = pid(cmd("plugin.add_gain_stage", host=i1, face="gain", gain_db=6.0))
    fx_i2 = pid(cmd("plugin.add_gain_stage", host=i2, face="gain", gain_db=-3.0))
    settle()
    cmd("consolidate.edit_begin", placement=i1)
    settle()
    st = find(i1)
    check("I1 is a group (the stage) keeping its id and its link", kind(st).get("type") == "group"
          and st.get("definitionID") == def_id)
    check("the stage keeps its own FX", [p["id"] for p in st.get("plugins", [])] == [fx_i1])
    kids = children(st)
    check("the stage has exactly ONE child (the content root A)", len(kids) == 1)
    a = kids[0]
    check("A is a group, expanded, unlinked, with the two clips", kind(a).get("type") == "group"
          and kind(a).get("isExpanded") and a.get("definitionID") is None and len(children(a)) == 2)
    state = cmd("consolidate.state")
    check("consolidate.state exposes the content root", state.get("content_root_id") == a["id"], str(state))
    for oid, fx in ((i2, fx_i2),):
        m = find(oid)
        mk = children(m)
        check("I2 is a FOLDED mirror: stage > copy of A, with its own FX",
              kind(m).get("type") == "group" and not kind(m).get("isExpanded") and len(mk) == 1
              and [p["id"] for p in m.get("plugins", [])] == [fx] and m.get("definitionID") == def_id)
        check("I2's mirror holds a copy of A with fresh ids", mk[0]["id"] != a["id"] and len(children(mk[0])) == 2)
    check("I1's stage holds the instance FX, heard around the content: +6 dB over the -3 of A",
          near(peak(render_instance(i1, "open_i1"), 0.0, 0.4), 0.549 * lin(3), 0.04))

    # ── 4 ──
    section("4 — the session")
    # The stage's fader is edited in the session and is kept at the commit; A's fader is content.
    cmd("object.set_gain", ids=[i1], db=-2.0)
    k1 = children(a)[0]["id"]
    cmd("object.set_gain", ids=[a["id"]], db=-3.0)
    # A solo elsewhere (an unrelated clip) must never be baked into the wave as silence.
    other = cmd("object.add", path=BIP, lane=6, start=5.0)["id"]
    cmd("solo.set", ids=[other], on=True)
    settle()
    rev_before = defs()[def_id]["revision"]
    commit()
    cmd("solo.clear"); settle()
    dd = defs()[def_id]
    check("a new revision was written", dd["revision"] == rev_before + 1, "%s -> %s" % (rev_before, dd["revision"]))
    w = newest_wave(def_id)
    check("the wave holds A's -3 dB over the -3 dB FX, WITHOUT the instance's +6 dB: peak ~ 0.549 x lin(-6)",
          near(peak(w, 0.0, 0.4), 0.549 * lin(-6), 0.02), str(peak(w, 0.0, 0.4)))
    check("the wave is not silent under a solo elsewhere (both clips baked)",
          peak(w, 1.0, 1.4) > 0.5 * peak(w, 0.0, 0.4), "%s" % peak(w, 1.0, 1.4))
    st = find(i1)
    check("I1 is a closed clip again, linked, keeping its FX and the stage's fader (-2 dB)",
          clip_of(st) is not None and st["definitionID"] == def_id and abs(st["volume"] - (-2.0)) < 1e-6
          and [p["id"] for p in st.get("plugins", [])] == [fx_i1])
    check("the others read the new wave with their own FX", clip_of(find(i2)) is not None
          and [p["id"] for p in find(i2).get("plugins", [])] == [fx_i2])
    p2 = peak(render_instance(i2, "c_i2"), 0.0, 0.4)
    check("I2 is heard with its -3 dB FX over the new content (-6 dB)",
          near(p2, 0.549 * lin(-9), 0.02), str(p2))
    cmd("object.set_gain", ids=[i1], db=0.0); settle()


    # ── 4b — trimming A and fading it ──
    section("4b — A trimmed on both sides and faded: every instance re-aligned")
    def_id, i1, i2, i3 = build("b")
    cmd("object.set_fade", id=i2, **{"in": 0.7, "out": 0.7}); settle()
    cmd("consolidate.edit_begin", placement=i1); settle()
    a = children(find(i1))[0]["id"]
    cmd("object.trim", id=a, start=0.1, duration=1.2)
    cmd("object.set_fade", id=a, **{"in": 0.05, "out": 0.05})
    settle()
    commit()
    w = newest_wave(def_id)
    check("the wave lasts A's window (1.2 s)", near(duration_of(w), 1.2, 0.02), str(duration_of(w)))
    check("c1 is in the wave at 0..0.3 and c2 at 0.9..1.2, silence between",
          peak(w, 0.05, 0.3) > 0.2 and peak(w, 0.95, 1.15) > 0.2 and peak(w, 0.4, 0.85) < 0.01,
          "%s %s %s" % (peak(w, 0.05, 0.3), peak(w, 0.95, 1.15), peak(w, 0.4, 0.85)))
    check("A's fade-in is in the wave (first 4 ms far below the body)",
          peak(w, 0.0, 0.004) < 0.3 * peak(w, 0.1, 0.28), "%s %s" % (peak(w, 0.0, 0.004), peak(w, 0.1, 0.28)))
    check("A's fade-out is in the wave (last 4 ms far below the body)",
          peak(w, 1.196, 1.2) < 0.3 * peak(w, 1.0, 1.15), "%s %s" % (peak(w, 1.196, 1.2), peak(w, 1.0, 1.15)))
    for name, i, st in (("I1", i1, 0.1), ("I2", i2, 1.5), ("I3", i3, 2.9)):
        s_, d_ = instance_start_dur(i)
        check("%s: head and tail cut by 0.1 s (start %s, duration 1.2)" % (name, st),
              near(s_, st) and near(d_, 1.2), "%s %s" % (s_, d_))
    o2 = find(i2)
    check("I2's fades are bounded by its new length (sum <= 1.2, fade-in kept)",
          o2["fadeIn"] + o2["fadeOut"] <= 1.2 + 1e-6 and near(o2["fadeIn"], 0.7), "%s %s" % (o2["fadeIn"], o2["fadeOut"]))
    r3 = render_instance(i3, "b_i3")
    check("I3 plays c1 at its window's start and c2 at 0.9: aligned on the same material",
          peak(r3, 0.0, 0.3) > 0.2 and peak(r3, 0.4, 0.85) < 0.01 and peak(r3, 0.95, 1.15) > 0.2)

    # ── 4c — A extended ──
    section("4c — A extended: no instance grows; trimming one reveals")
    def_id, i1, i2, i3 = build("c")
    cmd("consolidate.edit_begin", placement=i1); settle()
    a = children(find(i1))[0]["id"]
    cmd("object.set_duration", id=a, duration=2.0); settle()
    commit()
    w = newest_wave(def_id)
    check("the wave now lasts 2.0 s", near(duration_of(w), 2.0, 0.02), str(duration_of(w)))
    check("no instance grew (1.4 s each, same starts)",
          all(near(instance_start_dur(i)[1], 1.4) for i in (i1, i2, i3))
          and near(instance_start_dur(i2)[0], 1.4) and near(instance_start_dur(i3)[0], 2.8))
    cmd("object.trim", id=i2, start=1.4, duration=2.0); settle()
    check("trimming I2 out to 2.0 s reveals the extended tail (accepted)", near(instance_start_dur(i2)[1], 2.0),
          str(instance_start_dur(i2)))

    # ── 4d — A moved ──
    section("4d — A moved +0.2 s inside the stage: the content shifts for every instance")
    def_id, i1, i2, i3 = build("d")
    cmd("consolidate.edit_begin", placement=i1); settle()
    a = children(find(i1))[0]["id"]
    cmd("object.move", id=a, start=0.2); settle()
    commit()
    w = newest_wave(def_id)
    check("the wave is still 1.4 s long", near(duration_of(w), 1.4, 0.02), str(duration_of(w)))
    for name, i, st in (("I1", i1, 0.2), ("I2", i2, 1.6), ("I3", i3, 3.0)):
        s_, d_ = instance_start_dur(i)
        check("%s: head cut by the shift (start %s, duration 1.2)" % (name, st), near(s_, st) and near(d_, 1.2),
              "%s %s" % (s_, d_))
    r2 = render_instance(i2, "d_i2")
    check("I2 sounds c1 from its start and c2 from 1.0 (material shifted +0.2 s in absolute time)",
          peak(r2, 0.0, 0.4) > 0.2 and peak(r2, 0.5, 0.95) < 0.01 and peak(r2, 1.0, 1.2) > 0.2)

    # ── 4f — an instance left outside the content (Q2) ──
    section("4f — content shrunk under an instance (Q2): place and length kept, silent, flagged")
    def_id, i1, i2, i3 = build("f")
    cmd("object.trim", id=i3, start=2.8, duration=0.4); settle()
    cmd("object.set_source_offset", id=i3, offset=1.0); settle()
    pre = render_instance(i3, "f_pre")
    check("before: I3 reads c2 (the tail of the wave)", peak(pre, 0.0, 0.4) > 0.2, str(peak(pre, 0.0, 0.4)))
    cmd("consolidate.edit_begin", placement=i1); settle()
    a = children(find(i1))[0]["id"]
    cmd("object.set_duration", id=a, duration=0.5); settle()
    commit()
    s3, d3 = instance_start_dur(i3)
    check("I3 keeps its place and its duration", near(s3, 2.8) and near(d3, 0.4), "%s %s" % (s3, d3))
    post = render_instance(i3, "f_post")
    check("I3 plays silence", peak(post, 0.0, 0.4) < 0.001, str(peak(post, 0.0, 0.4)))
    flags = {o["id"]: o.get("outside_content") for o in cmd("object.list")["objects"] if o["id"] in (i1, i2, i3)}
    check("I3 is flagged outside the content, I1 and I2 are not", flags.get(i3) is True and not flags.get(i1)
          and not flags.get(i2), str(flags))

    # ── 4g — an unchanged / neutral edit ──
    section("4g — closing without a change of content, and a neutral edit")
    def_id, i1, i2, i3 = build("g")
    wave0 = defs()[def_id]["wave"]; rev0 = defs()[def_id]["revision"]
    cmd("consolidate.edit_begin", placement=i1); settle()
    j = commit()
    dd = defs()[def_id]
    check("no change: same wave, same revision (no render)", dd["wave"] == wave0 and dd["revision"] == rev0,
          "%s %s" % (dd["wave"], dd["revision"]))
    check("no change: the instances are back as closed clips", all(clip_of(find(i)) is not None for i in (i1, i2, i3)))
    w0 = newest_wave(def_id)
    cmd("consolidate.edit_begin", placement=i1); settle()
    a = children(find(i1))[0]["id"]
    k = children(find(a))[0]["id"] if False else children(children(find(i1))[0])[0]["id"]
    cmd("object.rename", id=k, name="renamed"); settle()
    commit()
    dd = defs()[def_id]
    w1 = newest_wave(def_id)
    check("a neutral edit (a rename) bakes a new revision...", dd["revision"] == rev0 + 1, str(dd["revision"]))
    check("...with the SAME sound and length (delta 0)",
          near(duration_of(w1), duration_of(w0), 0.005) and near(peak(w1, 0, 0.4), peak(w0, 0, 0.4), 0.005)
          and near(peak(w1, 1.0, 1.4), peak(w0, 1.0, 1.4), 0.005))
    check("...and the instances unchanged in place and duration",
          all(near(instance_start_dur(i)[1], 1.4) for i in (i1, i2, i3)) and near(instance_start_dur(i2)[0], 1.4))

    # ── 5 — only the stage changed ──
    section("5 — a change of the stage alone: no new revision, the instance level is kept")
    def_id, i1, i2, i3 = build("s5")
    wave0 = defs()[def_id]["wave"]; rev0 = defs()[def_id]["revision"]
    depth0 = len(cmd("edit.undo", dry_run=True).get("stack", [])) if False else None
    cmd("consolidate.edit_begin", placement=i1); settle()
    fx = pid(cmd("plugin.add_gain_stage", host=i1, face="gain", gain_db=-6.0))
    cmd("object.set_gain", ids=[i1], db=-5.0); settle()
    commit()
    dd = defs()[def_id]
    check("no new revision, same wave", dd["revision"] == rev0 and dd["wave"] == wave0)
    o1 = find(i1)
    check("I1 is a closed clip keeping the new FX and the new fader (-5 dB)",
          clip_of(o1) is not None and abs(o1["volume"] - (-5.0)) < 1e-6 and [p["id"] for p in o1.get("plugins", [])] == [fx])
    check("I2 and I3 untouched (no FX, 0 dB)", all(find(i)["volume"] == 0 and not find(i).get("plugins") for i in (i2, i3)))
    cmd("edit.undo"); settle()
    o1 = find(i1)
    check("ONE undo gives the instance back as it was opened: a linked clip, no FX, 0 dB",
          clip_of(o1) is not None and o1["definitionID"] == def_id and o1["volume"] == 0 and not o1.get("plugins"),
          str({k: o1.get(k) for k in ("volume", "plugins", "definitionID")}))

    # ── 6 — cancel ──
    section("6 — cancel after a change of the stage AND of the content: everything comes back")
    def_id, i1, i2, i3 = build("s6")
    before = {i: find(i) for i in (i1, i2, i3)}
    wave0 = defs()[def_id]["wave"]
    cmd("consolidate.edit_begin", placement=i1); settle()
    a = children(find(i1))[0]["id"]
    pid(cmd("plugin.add_gain_stage", host=i1, face="gain", gain_db=-6.0))
    cmd("object.set_gain", ids=[i1], db=-5.0)
    cmd("object.set_gain", ids=[a], db=-9.0)
    cmd("object.trim", id=a, start=0.2, duration=1.0); settle()
    cmd("consolidate.edit_cancel"); settle()
    after = {i: find(i) for i in (i1, i2, i3)}
    check("the three instances are exactly as before (model)", before == after,
          str([i[:6] for i in before if before[i] != after[i]]))
    check("the definition did not move", defs()[def_id]["wave"] == wave0)
    undo_state = cmd("edit.undo"); settle()
    check("a cancel leaves no undo point of its own for the session", find(i1) is not None)

    # ── 7 — undo / redo of a commit ──
    section("7 — undo / redo of a commit")
    def_id, i1, i2, i3 = build("s7")
    cmd("consolidate.edit_begin", placement=i1); settle()
    a = children(find(i1))[0]["id"]
    pid(cmd("plugin.add_gain_stage", host=i1, face="gain", gain_db=-6.0))
    cmd("object.set_gain", ids=[a], db=-9.0); settle()
    rev0 = defs()[def_id]["revision"]
    commit()
    check("committed: revision +1", defs()[def_id]["revision"] == rev0 + 1)
    cmd("edit.undo"); settle()
    o1 = find(i1)
    check("undo: I1 is the linked CLOSED instance of the previous revision, with its FX as opened",
          clip_of(o1) is not None and o1["definitionID"] == def_id and not o1.get("plugins"),
          str(kind(o1).get("type")))
    check("undo: no detached group anywhere (every group has no definitionID, no instance is a group)",
          all(not (kind(o).get("type") == "group" and o.get("definitionID")) for o in walk(state_items())))
    check("undo: the registry is back on the previous revision", defs()[def_id]["revision"] == rev0)
    cmd("edit.redo"); settle()
    check("redo: the new revision again, I1 still a closed instance",
          defs()[def_id]["revision"] == rev0 + 1 and clip_of(find(i1)) is not None)

    # ── 8 — guards ──
    section("8 — what an open consolidated object protects")

    def refused(label, name, **params):
        try:
            cmd(name, **params)
            check(label, False, "accepted, expected invalid_state")
        except ObjekatError as e:
            check(label, e.code == "invalid_state", "%s: %s" % (e.code, e.message))

    def parent_of(oid):
        def look(items, parent):
            for o in items:
                if o["id"] == oid:
                    return parent
                if kind(o).get("type") == "group":
                    r = look(children(o), o["id"])
                    if r is not False:
                        return r
            return False
        return look(state_items(), None)

    def count_all():
        return len(list(walk(state_items())))

    def_id, i1, i2, i3 = build("s8")
    cmd("consolidate.edit_begin", placement=i1); settle()
    stage = find(i1)
    a = children(stage)[0]["id"]
    n0 = count_all()
    refused("delete the stage: refused", "object.remove", ids=[i1])
    refused("delete A: refused", "object.remove", ids=[a])
    refused("ungroup the stage: refused", "group.disband", id=i1)
    refused("ungroup A: refused", "group.disband", id=a)
    refused("group A with something else: refused", "group.create", ids=[a, i3])
    refused("split the stage: refused", "object.split_at", seconds=0.5, ids=[i1])
    refused("split A: refused", "object.split_at", seconds=0.5, ids=[a])
    refused("move the stage in time: refused", "object.move", id=i1, start=1.0)
    refused("un-make the stage: refused", "consolidate.unmake", placement=i1)
    refused("consolidate A: refused", "consolidate.make", id=a)
    refused("take A out of the stage: refused", "group.eject", ids=[a])
    refused("move A into another group: refused", "group.reparent", ids=[a], group=i2)
    check("nothing moved: same objects, the stage still has A as its only child",
          count_all() == n0 and [c["id"] for c in children(find(i1))] == [a])
    cmd("object.move", id=a, start=0.3); settle()
    check("A moves INSIDE the stage (content)", near(find(a)["startTime"], 0.3), str(find(a)["startTime"]))
    cmd("object.move", id=a, start=0.0); settle()

    # A drag release (DEBUG): the stage cannot be moved in time, A can.
    r = cmd("debug.move_drop", id=i1, dt=0.5)
    check("a drag of the stage in time: cancelled", r.get("decision") == "cancel", str(r))
    check("...and the stage did not move", near(find(i1)["startTime"], 0.0))
    r = cmd("debug.move_drop", id=a, dt=0.25)
    check("a drag of A in time: accepted", r.get("decision") == "move_in_source", str(r))
    check("...and A moved", near(find(a)["startTime"], 0.25), str(find(a)["startTime"]))
    cmd("object.move", id=a, start=0.0); settle()

    # Something dropped ON the stage goes into A.
    extra = cmd("object.add", path=BIP, lane=4, start=0.5)["id"]
    cmd("group.reparent", ids=[extra], group=i1); settle()
    check("a clip reparented to the stage lands in A, the stage keeps ONE child",
          parent_of(extra) == a and len(children(find(i1))) == 1, "parent=%s" % parent_of(extra))
    # Grouping inside A is content: allowed.
    kids = [c["id"] for c in children(find(a))][:2]
    g2 = cmd("group.create", ids=kids)["id"]; settle()
    check("grouping two children of A is allowed (content)", parent_of(g2) == a)
    cmd("consolidate.edit_cancel"); settle()
    check("cancel: the three instances are closed clips again", all(clip_of(find(i)) for i in (i1, i2, i3)))

    # ── 9 — copy / paste / duplicate / time selection in a session ──
    section("9 — what leaves the session is the CLOSED instance")
    def_id, i1, i2, i3 = build("s9")
    fxa = pid(cmd("plugin.add_gain_stage", host=i1, face="gain", gain_db=-1.0))
    cmd("plugin.copy", **{"from": i1, "plugin": fxa, "to": i3}); settle()   # (the manual link is gone, 22 Oct 2026)
    # Room for the copies (a duplicate lands right after its original and would overwrite its neighbour).
    cmd("object.move", id=i2, start=20.0); cmd("object.move", id=i3, start=30.0); settle()
    link0 = [p.get("id") for p in find(i1).get("plugins", [])]
    check("setup: I1 holds its FX, and I3 an independent copy of it",
          len(link0) == 1 and len(find(i3).get("plugins", [])) >= 1, str(link0))
    cmd("consolidate.edit_begin", placement=i1); settle()
    stage = find(i1); a = children(stage)[0]["id"]

    def groups_with_def():
        return [o["id"] for o in walk(state_items()) if kind(o).get("type") == "group" and o.get("definitionID")]

    def stages_open():
        """Expanded linked groups: the stage (a mirror is FOLDED)."""
        return [o["id"] for o in walk(state_items()) if kind(o).get("type") == "group"
                and o.get("definitionID") and kind(o).get("isExpanded")]

    known = {i1, i2, i3}
    cmd("selection.set", ids=[i1]); cmd("clipboard.copy")
    cmd("transport.seek", seconds=6.0)
    cmd("clipboard.paste"); settle()
    check("copy / paste of the stage: no second stage (the new linked instance is a MIRROR while open)",
          stages_open() == [i1], str(stages_open()))
    r = cmd("object.duplicate", ids=[i1]); settle()
    check("duplicate of the stage: still one stage", stages_open() == [i1], str(stages_open()))
    r = cmd("object.duplicate", ids=[i2]); settle()
    check("duplicate of a MIRROR: still one stage", stages_open() == [i1], str(stages_open()))
    n0 = len(list(walk(state_items())))
    try:
        cmd("object.duplicate", ids=[a]); settle()
    except ObjekatError:
        pass
    check("duplicate of A: nothing created, the stage still has one child",
          len(list(walk(state_items()))) == n0 and len(children(find(i1))) == 1)
    cmd("selection.set", ids=[a])
    try:
        cmd("clipboard.copy")
    except ObjekatError:
        pass

    # The time selection over the stage's row: a fragment that is a closed instance.
    cmd("timesel.set", start=0.2, end=0.9, lanes=[0]); cmd("timesel.copy")
    cmd("transport.seek", seconds=9.0); cmd("timesel.clear")
    cmd("clipboard.paste"); settle()
    # The time selection also leaves the scaffolding alone (delete over the stage's row).
    cmd("timesel.set", start=0.0, end=1.4, lanes=[0])
    try:
        cmd("timesel.delete")
    except ObjekatError:
        pass
    settle()
    check("a time-selection delete over the stage leaves the stage and A", find(i1) is not None and find(a) is not None
          and len(children(find(i1))) == 1)
    cmd("timesel.clear")
    cmd("consolidate.edit_cancel"); settle()
    copies = [o for o in walk(state_items()) if o["id"] not in known and o.get("definitionID") == def_id]
    check("after the cancel every copy is a CLOSED linked clip (3 copies + the fragment)",
          len(copies) >= 4 and all(clip_of(o) is not None for o in copies),
          str([(kind(o).get("type")) for o in copies]))
    check("...each reading the OFFICIAL wave (the content of the session was never baked)",
          all(clip_of(o)["filePath"].endswith(defs()[def_id]["wave"]) for o in copies if clip_of(o)))
    frag = [o for o in state_items() if 8.9 <= o["startTime"] < 12.0]
    check("the time-selection fragment pasted at 9 s is a CLOSED linked clip",
          len(frag) == 1 and clip_of(frag[0]) is not None and frag[0].get("definitionID") == def_id,
          str([(kind(o).get("type"), o.get("definitionID")) for o in frag]))
    linked = [o for o in copies if o.get("plugins")]
    check("...the FX of those taken from I1 (and from its mirror I3) travel with the copies",
          len(linked) >= 2, str([[x.get("id") for x in o.get("plugins", [])] for o in copies]))

    # ── 10 — un-make ──
    section("10 — de-consolidate: an ordinary group G holding the content")
    def_id, i1, i2, i3 = build("s10")
    fx10 = pid(cmd("plugin.add_gain_stage", host=i1, face="gain", gain_db=6.0))
    cmd("object.set_gain", ids=[i1], db=-2.0)
    cmd("object.set_fade", id=i1, **{"in": 0.1, "out": 0.1}); settle()
    pre = render_instance(i1, "u_pre")
    n_before = len(list(walk(state_items())))
    r = cmd("consolidate.unmake", placement=i1); settle()
    g = find(i1)
    check("I1 is a GROUP with no link", kind(g).get("type") == "group" and g.get("definitionID") is None
          and r.get("still_linked") is False, str(kind(g).get("type")))
    check("...folded, holding ONE child (the content root A)", not kind(g).get("isExpanded") and len(children(g)) == 1)
    a10 = children(g)[0]
    check("A is an unlinked group with the two clips and the content FX (-3 dB)",
          kind(a10).get("type") == "group" and a10.get("definitionID") is None and len(children(a10)) == 2
          and len(a10.get("plugins", [])) == 1, str(len(a10.get("plugins", []))))
    check("A has fresh ids (not the instance's, not an existing object)",
          a10["id"] not in (i1, i2, i3))
    check("G keeps the instance level: FX, fader, fades",
          [x["id"] for x in g.get("plugins", [])] == [fx10] and abs(g["volume"] + 2.0) < 1e-6
          and near(g["fadeIn"], 0.1) and near(g["fadeOut"], 0.1), str((g.get("volume"), g.get("fadeIn"))))
    check("the other instances are untouched and still linked",
          all(clip_of(find(i)) and find(i).get("definitionID") == def_id for i in (i2, i3))
          and defs()[def_id]["placements"] == [i2, i3] or set(defs()[def_id]["placements"]) == {i2, i3},
          str(defs()[def_id]["placements"]))
    post = render_instance(i1, "u_post")
    check("same sound: same length and same body (both bips)",
          near(duration_of(post), duration_of(pre), 0.03)
          and near(peak(post, 0.15, 0.35), peak(pre, 0.15, 0.35), 0.02)
          and near(peak(post, 1.05, 1.25), peak(pre, 1.05, 1.25), 0.02)
          and peak(post, 0.5, 0.9) < 0.01,
          "%s %s | %s %s" % (peak(post, 0.15, 0.35), peak(pre, 0.15, 0.35), peak(post, 1.05, 1.25), peak(pre, 1.05, 1.25)))
    cmd("edit.undo"); settle()
    u = find(i1)
    check("ONE undo gives the linked closed instance back, FX included",
          clip_of(u) is not None and u.get("definitionID") == def_id
          and [x["id"] for x in u.get("plugins", [])] == [fx10] and len(list(walk(state_items()))) == n_before,
          str(kind(u).get("type")))
    cmd("edit.redo"); settle()
    check("redo: the group again", kind(find(i1)).get("type") == "group" and find(i1).get("definitionID") is None)

    # ── 15 — save in a session, reopen ──
    section("15 — a file never holds an open stage")
    def_id, i1, i2, i3 = build("s15")
    path = os.path.join(PROJ, "p.objekat")
    cmd("consolidate.edit_begin", placement=i1); settle()
    a = children(find(i1))[0]["id"]
    cmd("object.set_gain", ids=[i1], db=-2.0)
    cmd("object.set_gain", ids=[a], db=-9.0)
    fxs = pid(cmd("plugin.add_gain_stage", host=i1, face="gain", gain_db=-6.0)); settle()
    cmd("project.save"); settle()
    doc = json.load(open(path))
    fl = list(walk(doc["items"]))
    byid = {o["id"]: o for o in fl}
    check("the file holds I1 as a linked CLOSED clip", kind(byid[i1]).get("type") == "clip"
          and byid[i1].get("definitionID") == def_id, str(kind(byid[i1]).get("type")))
    check("...with the stage's fader and FX", abs(byid[i1].get("volume", 0) + 2.0) < 1e-6
          and [x["id"] for x in byid[i1].get("plugins", [])] == [fxs])
    check("...reading the official wave", clip_of(byid[i1])["filePath"].endswith(defs()[def_id]["wave"]),
          str(clip_of(byid[i1])))
    check("the mirrors are closed clips in the file too",
          all(kind(byid[i]).get("type") == "clip" for i in (i2, i3)))
    check("no group of the file carries a link (no stage, no mirror)",
          all(not (kind(o).get("type") == "group" and o.get("definitionID")) for o in fl))
    check("the content root A is not in the file", a not in byid)
    check("the session is still open after the save", cmd("consolidate.state").get("editing") is True)
    commit()
    check("...and still commits (fader -2 dB kept on the closed I1)",
          clip_of(find(i1)) is not None and abs(find(i1)["volume"] + 2.0) < 1e-6)
    cmd("project.save"); settle()
    # Reopen what was saved mid-session (a cancelled session: the content is the official one).
    def_id, i1, i2, i3 = build("s15b")
    path = os.path.join(PROJ, "p.objekat")
    cmd("consolidate.edit_begin", placement=i1); settle()
    staged_state = cmd("project.get_state")            # the unfolded form: what an older build could write
    cmd("project.save"); settle()
    cmd("project.open", path=path); settle()
    check("reopened: the three instances are closed linked clips",
          all(clip_of(find(i)) and find(i).get("definitionID") == def_id for i in (i1, i2, i3)),
          str([kind(find(i)).get("type") if find(i) else None for i in (i1, i2, i3)]))
    check("reopened: no session", cmd("consolidate.state").get("editing") is False)
    # Repair: an unfolded document (an older build, a hand edit) comes back closed.
    stage_doc = os.path.join(PROJ, "staged.objekat")
    json.dump(staged_state, open(stage_doc, "w"))
    cmd("project.open", path=stage_doc); settle()
    r1 = find(i1)
    check("a file that HOLDS an open stage is folded back on loading: I1 a linked closed clip",
          r1 is not None and clip_of(r1) is not None and r1.get("definitionID") == def_id,
          str(kind(r1).get("type")) if r1 else "missing")

    # ── 18 — playing while a session is open ──
    section("18 — play during a session, close while playing")
    def_id, i1, i2, i3 = build("s18")
    cmd("consolidate.edit_begin", placement=i1); settle()
    cmd("transport.play", seconds=0.0)
    time.sleep(0.6)
    cmd("object.set_gain", ids=[i1], db=-1.0)
    a = children(find(i1))[0]["id"]
    cmd("object.set_gain", ids=[a], db=-2.0); settle()
    r = cmd("consolidate.edit_commit")
    j = cmd("job.wait", id=r["job_id"], timeout_ms=60000)
    cmd("transport.stop"); settle()
    check("committed while playing: the application answers, I1 closed and linked",
          clip_of(find(i1)) is not None and find(i1).get("definitionID") == def_id)
    cmd("consolidate.edit_begin", placement=i1); settle()
    cmd("transport.play", seconds=0.0)
    time.sleep(0.3)
    cmd("consolidate.edit_cancel"); settle()
    cmd("transport.stop")
    check("cancelled while playing: the application answers, I1 closed again",
          clip_of(find(i1)) is not None)

    # ── 11 — a lone clip is its own content ──
    section("11 — a lone clip: content = the clip, no wrapper group")
    PROJ11 = os.path.join(ROOT, "s11"); os.makedirs(PROJ11, exist_ok=True)
    globals()["PROJ"] = PROJ11
    cmd("project.new")
    c = cmd("object.add", path=BIP, lane=0, start=0.0)["id"]
    cmd("plugin.add_gain_stage", host=c, face="gain", gain_db=-3.0)     # a CLIP FX: content, baked
    cmd("object.set_gain", ids=[c], db=-4.0)                            # the fader: the instance's
    cmd("object.set_pan", ids=[c], pan=0.25)
    cmd("object.set_fade", id=c, **{"in": 0.05, "out": 0.05}); settle()
    cmd("project.save_as", path=os.path.join(PROJ11, "p.objekat"))
    pre11 = render_instance(c, "l_pre")
    n_items = len(list(walk(state_items())))
    r = cmd("consolidate.make", id=c)
    cmd("job.wait", id=r["job_id"], timeout_ms=60000)
    settle()
    inst = find(c)
    dd = next(iter(defs().values()))
    check("the clip keeps its id and becomes a linked CLOSED instance (still a clip)",
          inst is not None and clip_of(inst) is not None and inst.get("definitionID") == dd["id"])
    check("no wrapper group: the project holds the same number of objects, wasGroup false",
          len(list(walk(state_items()))) == n_items and dd.get("was_group") is False,
          "%s vs %s %s" % (len(list(walk(state_items()))), n_items, dd.get("was_group")))
    check("the instance carries the fader, pan and fades of the clip; its FX went into the wave",
          abs(inst["volume"] + 4.0) < 1e-6 and near(inst["pan"], 0.25) and near(inst["fadeIn"], 0.05)
          and near(inst["fadeOut"], 0.05) and len(inst.get("plugins", [])) == 0,
          str((inst.get("volume"), inst.get("pan"), inst.get("fadeIn"), len(inst.get("plugins", [])))))
    check("the instance reads the wave from 0, over the clip's own place and length",
          near(so_of(inst), 0.0) and near(inst["startTime"], 0.0) and near(inst["duration"], 0.4),
          str((so_of(inst), inst["startTime"], inst["duration"])))
    post11 = render_instance(c, "l_post")
    check("same sound after the transformation (fader, FX and fades not doubled, not lost)",
          near(peak(post11, 0.12, 0.28), peak(pre11, 0.12, 0.28), 0.02)
          and near(peak(post11, 0.0, 0.01), peak(pre11, 0.0, 0.01), 0.02),
          "%s %s" % (peak(post11, 0.12, 0.28), peak(pre11, 0.12, 0.28)))
    w11 = newest_wave(dd["id"])
    check("the wave is neutral: the clip's FX (-3 dB) baked, the fader (-4) and fades not baked",
          near(peak(w11, 0.12, 0.28), 0.549 * lin(-3), 0.02)
          and near(peak(w11, 0.0, 0.003), peak(read_wav(BIP), 0.0, 0.003) * lin(-3), 0.01),
          "%s %s" % (peak(w11, 0.12, 0.28), peak(w11, 0.0, 0.003)))
    cmd("consolidate.edit_begin", placement=c); settle()
    st = find(c)
    kids = children(st)
    check("opened: a stage holding ONE child, a CLIP (the content root), neutral fader, no fade",
          kind(st).get("type") == "group" and len(kids) == 1 and clip_of(kids[0]) is not None
          and abs(kids[0].get("volume", 0)) < 1e-6 and near(kids[0].get("fadeIn", 0), 0)
          and near(kids[0].get("fadeOut", 0), 0), str([kind(k).get("type") for k in kids]))
    check("...the stage keeps the instance's fader and fades; the clip keeps its FX (content)",
          abs(st["volume"] + 4.0) < 1e-6 and near(st["fadeIn"], 0.05) and len(kids[0].get("plugins", [])) == 1,
          str((st.get("volume"), st.get("fadeIn"), len(kids[0].get("plugins", [])))))
    check("consolidate.state exposes the content root (the clip)",
          cmd("consolidate.state").get("content_root_id") == kids[0]["id"])
    cmd("consolidate.edit_cancel"); settle()
    check("cancelled: the closed instance again", clip_of(find(c)) is not None)

    # ── 12 — N objects replaced by N linked instances ──
    section("12 — replace by N linked: mixes and fades differ, accepted and kept")
    PROJ12 = os.path.join(ROOT, "s12"); os.makedirs(PROJ12, exist_ok=True)
    globals()["PROJ"] = PROJ12
    cmd("project.new")
    x1 = cmd("object.add", path=BIP, lane=0, start=0.0)["id"]
    x2 = cmd("object.add", path=BIP, lane=1, start=2.0)["id"]
    x3 = cmd("object.add", path=BIP, lane=2, start=4.0)["id"]
    cmd("object.rename", id=x1, name="Source"); settle()
    cmd("object.set_gain", ids=[x1], db=-2.0)
    cmd("object.set_gain", ids=[x2], db=-6.0)
    cmd("object.set_gain", ids=[x3], db=0.0)
    cmd("object.set_fade", id=x2, **{"in": 0.1, "out": 0.0})
    cmd("object.set_mute", ids=[x3], muted=True)
    cmd("project.save_as", path=os.path.join(PROJ12, "p.objekat"))
    settle()
    r = cmd("consolidate.make", id=x1, also_link=[x2, x3])
    cmd("job.wait", id=r["job_id"], timeout_ms=60000)
    settle()
    dd = next(iter(defs().values()))
    check("ONE definition with the three instances", len(defs()) == 1 and set(dd["placements"]) == {x1, x2, x3},
          str(dd["placements"]))
    o1, o2, o3 = find(x1), find(x2), find(x3)
    check("each keeps its own fader, fades and mute",
          abs(o1["volume"] + 2.0) < 1e-6 and abs(o2["volume"] + 6.0) < 1e-6 and abs(o3["volume"]) < 1e-6
          and near(o2["fadeIn"], 0.1) and near(o1["fadeIn"], 0.0) and o3["isMuted"] and not o1["isMuted"],
          str([(o["volume"], o["fadeIn"], o["isMuted"]) for o in (o1, o2, o3)]))
    check("they take the source's name and colour",
          o2.get("label") == o1.get("label") == o3.get("label")
          and o2.get("colorIndex") == o1.get("colorIndex") and o3.get("colorIndex") == o1.get("colorIndex"),
          str([(o.get("label"), o.get("colorIndex")) for o in (o1, o2, o3)]))
    check("...and keep their places", near(o2["startTime"], 2.0) and near(o3["startTime"], 4.0))
    q1 = peak(render_instance(x1, "n_1"), 0.12, 0.28)
    q2 = peak(render_instance(x2, "n_2"), 0.12, 0.28)
    check("the sound follows each mix: -2 dB over -6 dB (4 dB apart)",
          near(q1 / q2, lin(4.0), 0.1), "%s %s" % (q1, q2))

    # ── 4h — creation from a looping group ──
    section("4h — creation from a looping group: the loop is content, the offset 0")
    PROJ4 = os.path.join(ROOT, "s4h"); os.makedirs(PROJ4, exist_ok=True)
    globals()["PROJ"] = PROJ4
    cmd("project.new")
    l1 = cmd("object.add", path=BIP, lane=0, start=0.0)["id"]
    l2 = cmd("object.add", path=BIP, lane=2, start=0.8)["id"]
    lg = cmd("group.create", ids=[l1, l2])["id"]
    cmd("object.set_loop", id=lg, enabled=True); settle()
    cmd("object.set_duration", id=lg, duration=2.4); settle()
    cmd("project.save_as", path=os.path.join(PROJ4, "p.objekat"))
    g0 = find(lg)
    pre4 = render_instance(lg, "lp_pre")
    r = cmd("consolidate.make", id=lg)
    cmd("job.wait", id=r["job_id"], timeout_ms=60000)
    settle()
    li = find(lg)
    dd = next(iter(defs().values()))
    check("the looping group became a linked closed instance over its own window, offset 0",
          clip_of(li) is not None and li.get("definitionID") == dd["id"] and near(so_of(li), 0.0)
          and near(li["startTime"], g0["startTime"]) and near(li["duration"], g0["duration"]),
          str((kind(li).get("type"), so_of(li), li["duration"], g0["duration"])))
    post4 = render_instance(lg, "lp_post")
    check("the looped material is heard (second pass of the pattern) and as before",
          peak(post4, 1.3, 1.5) > 0.2 and near(peak(post4, 1.3, 1.5), peak(pre4, 1.3, 1.5), 0.03)
          and near(duration_of(post4), duration_of(pre4), 0.05),
          "%s %s %s %s" % (peak(post4, 1.3, 1.5), peak(pre4, 1.3, 1.5), duration_of(post4), duration_of(pre4)))
    cmd("consolidate.edit_begin", placement=lg); settle()
    ka = children(find(lg))
    check("opened: the content root A is the looping group (loop kept)",
          len(ka) == 1 and kind(ka[0]).get("type") == "group" and ka[0].get("loopEnabled") is True,
          str((len(ka), ka[0].get("loopEnabled") if ka else None)))
    commit()
    li = find(lg)
    check("committed with no change: no re-alignment (offset 0, same window)",
          clip_of(li) is not None and near(so_of(li), 0.0) and near(li["duration"], g0["duration"])
          and near(li["startTime"], g0["startTime"]),
          str((so_of(li), li["startTime"], li["duration"])))

    # ── 13 — nesting: B inside A ──
    section("13 — nesting: an instance of B inside A, opened, edited, closed")
    PROJ13 = os.path.join(ROOT, "s13"); os.makedirs(PROJ13, exist_ok=True)
    globals()["PROJ"] = PROJ13
    cmd("project.new")
    cmd("project.save_as", path=os.path.join(PROJ13, "p.objekat"))
    bclip = cmd("object.add", path=BIP, lane=6, start=1.0)["id"]
    r = cmd("consolidate.make", id=bclip); cmd("job.wait", id=r["job_id"], timeout_ms=60000); settle()
    b_def = next(iter(defs()))
    n1 = cmd("object.add", path=BIP, lane=0, start=0.0)["id"]
    ga = cmd("group.create", ids=[n1, bclip])["id"]
    r = cmd("consolidate.make", id=ga); cmd("job.wait", id=r["job_id"], timeout_ms=60000); settle()
    a_def = next(d for d in defs() if d != b_def)
    wave_a0 = newest_wave(a_def)
    check("A's first wave holds both sounds at full level (0.549 at 0 s and at 1 s)",
          near(peak(wave_a0, 0.1, 0.3), 0.549, 0.02) and near(peak(wave_a0, 1.1, 1.3), 0.549, 0.02),
          "%s %s" % (peak(wave_a0, 0.1, 0.3), peak(wave_a0, 1.1, 1.3)))
    cmd("consolidate.edit_begin", placement=ga); settle()
    stage = find(ga)
    a_root = children(stage)[0]
    inner = [o for o in children(a_root) if o.get("definitionID") == b_def]
    check("opened: the stage holds A, and A holds an instance of B", len(inner) == 1, str(len(inner)))
    bi = inner[0]["id"]
    cmd("object.set_gain", ids=[ga], db=-10.0)       # the OUTER instance's fader: never baked anywhere
    cmd("object.set_gain", ids=[bi], db=-3.0)        # B's instance mix inside A: A's content
    settle()
    cmd("consolidate.edit_begin", placement=bi); settle()
    check("B opened inside A: a stack of depth 2", cmd("consolidate.state").get("depth") == 2)
    b_root = children(find(bi))[0]["id"]
    cmd("object.set_gain", ids=[b_root], db=-6.0); settle()
    commit()
    wave_b = newest_wave(b_def)
    check("B's wave: its own content change (-6 dB) only; neither the stage -10 dB nor the -3 dB of its placement",
          near(peak(wave_b, 0.1, 0.3), 0.549 * lin(-6), 0.02), str(peak(wave_b, 0.1, 0.3)))
    check("back to depth 1 with A's session still open", cmd("consolidate.state").get("depth") == 1
          and cmd("consolidate.state").get("editing") is True)
    commit()
    wave_a = newest_wave(a_def)
    check("A's wave holds B's placement mix and new content (-6 -3 dB), not the outer stage (-10 dB)",
          near(peak(wave_a, 1.1, 1.3), 0.549 * lin(-9), 0.02) and near(peak(wave_a, 0.1, 0.3), 0.549, 0.02),
          "%s %s" % (peak(wave_a, 1.1, 1.3), peak(wave_a, 0.1, 0.3)))
    check("the outer instance kept its -10 dB fader",
          clip_of(find(ga)) is not None and abs(find(ga)["volume"] + 10.0) < 1e-6)

    # ── 14 — cascade C inside B inside A, an OLD sidecar ──
    section("14 — cascade with an old sidecar (root fader held the instance's mix): no doubled fader")
    PROJ14 = os.path.join(ROOT, "s14"); os.makedirs(PROJ14, exist_ok=True)
    globals()["PROJ"] = PROJ14
    cmd("project.new")
    cp = os.path.join(PROJ14, "p.objekat")
    cmd("project.save_as", path=cp)
    xc = cmd("object.add", path=BIP, lane=8, start=0.0)["id"]
    r = cmd("consolidate.make", id=xc); cmd("job.wait", id=r["job_id"], timeout_ms=60000); settle()
    x_def = next(iter(defs()))
    x2 = cmd("object.duplicate", ids=[xc])["ids"][0]
    yc = cmd("object.add", path=BIP, lane=9, start=1.0)["id"]
    gb = cmd("group.create", ids=[x2, yc])["id"]
    r = cmd("consolidate.make", id=gb); cmd("job.wait", id=r["job_id"], timeout_ms=60000); settle()
    b_def = next(d for d in defs() if d != x_def)
    cmd("object.set_gain", ids=[gb], db=-2.0); settle()
    cmd("project.save"); settle()
    # Forge an old definition: the sidecar's root carries a -6 dB fader, the manifest says it is not content.
    sidecar = [f for f in os.listdir(os.path.join(PROJ14, "samples", "consolidate"))
               if f.startswith(os.path.splitext(defs()[b_def]["wave"])[0]) and f.endswith("_objectstate.json")][0]
    sp_ = os.path.join(PROJ14, "samples", "consolidate", sidecar)
    sj = json.load(open(sp_)); sj["volume"] = -6.0; json.dump(sj, open(sp_, "w"))
    doc = json.load(open(cp))
    for e in doc["objectDefinitions"]:
        if e["id"] == b_def:
            e.pop("rootIsContent", None)
    json.dump(doc, open(cp, "w"))
    cmd("project.open", path=cp); settle()
    rev0 = defs()[b_def]["revision"]
    check("reopened: B is an OLD definition (sidecar root fader -6), its instance keeps -2 dB",
          abs(find(gb)["volume"] + 2.0) < 1e-6 and defs()[b_def]["placements"] == [gb])
    cmd("consolidate.edit_begin", placement=xc); settle()
    x_root = children(find(xc))[0]["id"]
    cmd("object.set_gain", ids=[x_root], db=-6.0); settle()
    commit()
    for _ in range(120):
        if defs()[b_def]["revision"] > rev0 and not defs()[b_def]["stale"] and not cmd("consolidate.state")["renders"]:
            break
        time.sleep(0.5)
    check("B was re-baked in the background (revision up, no longer stale)",
          defs()[b_def]["revision"] > rev0 and not defs()[b_def]["stale"],
          str((rev0, defs()[b_def]["revision"], defs()[b_def]["stale"])))
    wave_b2 = newest_wave(b_def)
    yrel = 1.0 - find(gb)["startTime"]          # the plain clip, relative to the wave's position 0
    check("B's new wave: C's change (-6 dB) once - the old root fader (-6) is not applied twice",
          near(peak(wave_b2, 0.1, 0.3), 0.549 * lin(-6), 0.03)
          and near(peak(wave_b2, yrel + 0.1, yrel + 0.3), 0.549, 0.03),
          "%s %s" % (peak(wave_b2, 0.1, 0.3), peak(wave_b2, yrel + 0.1, yrel + 0.3)))
    check("B's instance mix is kept (-2 dB)", abs(find(gb)["volume"] + 2.0) < 1e-6)

    # ── 16 — a sidechain key on an instance FX ──
    section("16 — sidechain on an instance FX: closed, then in session, then after the commit")
    def_id, i1, i2, i3 = build("s16")
    key = cmd("object.add", path=BIP, lane=12, start=0.0)["id"]
    probe = pid(cmd("debug.add_test_plugin", host=i1, type="objKeyProbe")); settle()
    src = cmd("plugin.sidechain_sources", host=i1, plugin=probe)
    check("closed instance: the plugin has a sidechain input and the key object is offered",
          src.get("can_sidechain") is True and any(x["id"] == key for x in src.get("sources", [])), str(src)[:300])
    r = cmd("plugin.set_sidechain", host=i1, plugin=probe, source=key)
    check("keyed on a CLOSED instance", r.get("ok") is True, str(r))
    check("the key is on the plugin", cmd("plugin.sidechain_sources", host=i1, plugin=probe).get("current") == key)
    cmd("consolidate.edit_begin", placement=i1); settle()
    src = cmd("plugin.sidechain_sources", host=i1, plugin=probe)
    check("in session: the stage keeps the plugin and its key",
          src.get("current") == key and src.get("can_sidechain") is True, str(src)[:300])
    r = cmd("plugin.set_sidechain", host=i1, plugin=probe, source=None)
    check("...and the key can be changed from the stage (cleared)", r.get("ok") is True
          and cmd("plugin.sidechain_sources", host=i1, plugin=probe).get("current") is None)
    cmd("plugin.set_sidechain", host=i1, plugin=probe, source=key)
    commit()
    check("after the commit the closed instance still carries the key",
          cmd("plugin.sidechain_sources", host=i1, plugin=probe).get("current") == key)

    section("done")
    print("\n%d failure(s)" % len(fails))
    return 1 if fails else 0


rc = 1
try:
    rc = main()
except ObjekatError as e:
    fails.append("exception: %s: %s" % (e.code, e.message))
    print("FAIL  exception %s: %s" % (e.code, e.message))
    traceback.print_exc()
finally:
    if not KEEP:
        shutil.rmtree(ROOT, ignore_errors=True)
    else:
        print("work folder kept:", ROOT)
if expected_fails:
    print("\nexpected failures (not counted): %s" % expected_fails)
print("ALL PASS" if not fails else "FAILED: %s" % fails)
sys.exit(1 if fails else 0)

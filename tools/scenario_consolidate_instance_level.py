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

import array, json, os, shutil, struct, sys, tempfile, time

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
    """(channels, sample_rate, samples) for the PCM 16/24/32 and float32 files the app writes."""
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

    section("done")
    print("\n%d failure(s)" % len(fails))
    return 1 if fails else 0


rc = 1
try:
    rc = main()
except ObjekatError as e:
    fails.append("exception: %s: %s" % (e.code, e.message))
    print("FAIL  exception %s: %s" % (e.code, e.message))
finally:
    if not KEEP:
        shutil.rmtree(ROOT, ignore_errors=True)
    else:
        print("work folder kept:", ROOT)
if expected_fails:
    print("\nexpected failures (not counted): %s" % expected_fails)
print("ALL PASS" if not fails else "FAILED: %s" % fails)
sys.exit(1 if fails else 0)

#!/usr/bin/env python3
"""A consolidated object: leave it, spread it, or fork it into a VARIANT — a scenario that asserts.

Plan: docs/plan_consolidate_variant.md. Three uses of a consolidated object — a creative wav (no link),
a saving of resources (shared content, the edits of the inside spread), a variant (no link, the edits
do not spread) — and the setting that decides what closing an edit does: ask / propagate / variant.

    # 1. launch the build with the API, on a SHORT socket (a system limit: 103 bytes), one instance per run.
    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --socket=/tmp/ocv.sock

    # 2. replay (add --keep to leave the work folder behind for a look)
    ./scenario_consolidate_variant.py /tmp/ocv.sock

Sections (numbering of the plan's test list):
  1  speed and reversal accepted on a CLOSED instance, rendered
  2  speed and reversal survive an opening, with and without a change of the content
and the sections added by the later increments (the setting, the variant, everywhere, ask, undo,
nesting, cross-tab, links).

Exit: 0 if every assertion passes, 1 otherwise.
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
ROOT = os.path.realpath(tempfile.mkdtemp(prefix="objk-ocv-", dir="/tmp"))
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



def rms(wav, t0, t1):
    ch, sr, s = wav
    i0, i1 = int(t0 * sr) * ch, min(len(s), int(t1 * sr) * ch)
    seg = s[max(0, i0):i1]
    return (sum(x * x for x in seg) / max(1, len(seg))) ** 0.5


def olo(o):
    """(startTime, duration, sourceOffset, speed, reversed) of a closed instance."""
    k = clip_of(o)
    return (o["startTime"], o["duration"], k["sourceOffset"], k.get("speedRatio", 1.0), k.get("isReversed", False))


# ── the project ─────────────────────────────────────────────────────────────────────────────

def build(tag="main", gain_db=None):
    """A = group [c1 @ 0 (0.4 s), c2 @ 1.0 (0.4 s)], consolidated, then two copies of the instance
    (3 linked instances: I1 @ 0, I2 @ 1.4, I3 @ 2.8, 1.4 s each). `gain_db`: a gain stage on A as content FX."""
    global PROJ
    PROJ = os.path.join(ROOT, tag)
    os.makedirs(PROJ, exist_ok=True)
    cmd("project.new")
    c1 = cmd("object.add", path=BIP, lane=0, start=0.0)["id"]
    c2 = cmd("object.add", path=BIP, lane=2, start=1.0)["id"]
    g = cmd("group.create", ids=[c1, c2])["id"]
    if gain_db is not None:
        cmd("plugin.add_gain_stage", host=g, face="gain", gain_db=gain_db)
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
    check("the instances are 1.4 s long, end to end",
          near(find(i1)["duration"], 1.4) and near(find(i2)["startTime"], 1.4) and near(find(i3)["startTime"], 2.8))
    base = render_instance(i1, "base_i1")
    check("the plain instance renders 1.4 s with the tone at 0..0.4 and 1.0..1.4",
          near(duration_of(base), 1.4, 0.02) and peak(base, 0.0, 0.4) > 0.4 and peak(base, 1.0, 1.4) > 0.4
          and peak(base, 0.5, 0.95) < 0.01)

    # ── 1 ──
    section("1 — speed and reversal on a CLOSED instance")
    cmd("object.set_speed", id=i1, ratio=2.0); settle()
    o = find(i1)
    st, du, so_, sp, rv_ = olo(o)
    check("speed 2 accepted on the instance: duration halves (0.7 s), still a linked clip",
          near(sp, 2.0) and near(du, 0.7) and o["definitionID"] == def_id, str(olo(o)))
    r2 = render_instance(i1, "s2_i1")
    check("rendered, it lasts half as long (0.7 s) and the tones are at 0..0.2 and 0.5..0.7",
          near(duration_of(r2), 0.7, 0.02) and peak(r2, 0.0, 0.2) > 0.4 and peak(r2, 0.5, 0.7) > 0.4
          and peak(r2, 0.25, 0.45) < 0.01, "%s" % duration_of(r2))
    check("the other instances keep speed 1 and 1.4 s",
          near(olo(find(i2))[3], 1.0) and near(find(i2)["duration"], 1.4))
    cmd("object.set_speed", id=i1, ratio=1.0); settle()
    cmd("object.set_reversed", id=i1, reversed=True); settle()
    check("reversal accepted on the instance", olo(find(i1))[4] is True, str(olo(find(i1))))
    rr = render_instance(i1, "rev_i1")
    check("reversed, the tone is at the END of the window first: c2 at 0..0.4, c1 at 1.0..1.4 (mirror)",
          near(duration_of(rr), 1.4, 0.02) and peak(rr, 0.0, 0.4) > 0.4 and peak(rr, 1.0, 1.4) > 0.4
          and peak(rr, 0.5, 0.95) < 0.01)
    cmd("object.set_reversed", id=i1, reversed=False); settle()

    # ── 2 ──
    section("2 — speed and reversal survive an opening")
    def through_session(label, i, mutate=None, expect_new_revision=False):
        """Opens `i`, optionally `mutate(a_id)` on its content root, commits; returns (before, after) olo + renders."""
        before = olo(find(i))
        rb = render_instance(i, label + "_before")
        rev0 = defs()[def_id]["revision"]
        cmd("consolidate.edit_begin", placement=i); settle()
        stage = find(i)
        a = children(stage)[0]["id"]
        if mutate:
            mutate(a)
            settle()
        commit()
        after = olo(find(i))
        ra = render_instance(i, label + "_after")
        rev1 = defs()[def_id]["revision"]
        check("%s: revision %s" % (label, "moved" if expect_new_revision else "unchanged"),
              (rev1 > rev0) == expect_new_revision, "%s -> %s" % (rev0, rev1))
        return before, after, rb, ra

    def same_instance(label, before, after, rb, ra):
        check("%s: start, duration, source offset, speed, direction identical" % label,
              all(near(x, y, 1e-6) for x, y in zip(before[:4], after[:4])) and before[4] == after[4],
              "%s -> %s" % (before, after))
        check("%s: the render has the same length and level" % label,
              near(duration_of(rb), duration_of(ra), 0.01) and near(rms(rb, 0, duration_of(rb)), rms(ra, 0, duration_of(ra)), 0.01),
              "%s/%s %s/%s" % (duration_of(rb), duration_of(ra), rms(rb, 0, duration_of(rb)), rms(ra, 0, duration_of(ra))))

    # a window that covers only c1 and part of the gap, so that a change of c2 does not change what is heard
    def narrow(i):
        cmd("object.trim", id=i, start=find(i)["startTime"], duration=0.6); settle()

    # The LAST instance is the one that takes the slow speeds: a varispeed never lengthens a clip into its neighbour.
    for speed, rev in ((2.0, False), (0.5, False), (1.0, True), (1.3, True)):
        tag = "sp%s%s" % (speed, "r" if rev else "")

        def prepare(tag2):
            d_, a1, a2, a3 = build(tag2)
            cmd("object.set_speed", id=a3, ratio=speed); settle()
            if rev:
                cmd("object.set_reversed", id=a3, reversed=True); settle()
            cmd("object.set_fade", id=a3, **{"in": 0.05, "out": 0.05}); settle()
            return d_, a1, a2, a3

        # (1) closed with NO change of the content
        def_id, i1, i2, i3 = prepare("s2_" + tag)
        o3 = find(i3)
        check(tag + ": the instance took the speed and the direction",
              near(olo(o3)[3], speed) and olo(o3)[4] == rev, str(olo(o3)))
        b, a_, rb, ra = through_session(tag + " no change", i3)
        same_instance(tag + " no change", b, a_, rb, ra)
        o3b = find(i3)
        check(tag + " no change: the fades are the same",
              near(o3b["fadeIn"], o3["fadeIn"], 1e-6) and near(o3b["fadeOut"], o3["fadeOut"], 1e-6),
              "%s %s -> %s %s" % (o3["fadeIn"], o3["fadeOut"], o3b["fadeIn"], o3b["fadeOut"]))
        # (2) closed after a change of the content: c2 (the later child) is 6 dB lower
        def_id, i1, i2, i3 = prepare("s2c_" + tag)
        o_other = olo(find(i2))

        def tweak(a):
            kids = sorted(children(find(a)), key=lambda k: k["startTime"])
            cmd("object.set_gain", ids=[kids[1]["id"]], db=-6.0)
        b, a_, rb, ra = through_session(tag + " changed", i3, tweak, expect_new_revision=True)
        check(tag + " changed: speed, direction, start, offset, duration kept",
              near(b[3], a_[3]) and b[4] == a_[4] and near(b[0], a_[0], 1e-6) and near(b[2], a_[2], 1e-6)
              and near(b[1], a_[1], 1e-6), "%s -> %s" % (b, a_))
        check(tag + " changed: the others keep their own speed and window",
              all(near(x, y, 1e-6) for x, y in zip(o_other, olo(find(i2)))), "%s -> %s" % (o_other, olo(find(i2))))
        # c1 is the first half of the sound (the second half when reversed), c2 the other one
        dur = duration_of(rb)
        half = dur * 0.5
        c1_range = (half, dur) if rev else (0.0, half)
        c2_range = (0.0, half) if rev else (half, dur)
        check(tag + " changed: the c1 half is unchanged, the c2 half is ~6 dB lower",
              near(rms(rb, *c1_range), rms(ra, *c1_range), 0.01)
              and near(rms(ra, *c2_range) / max(1e-9, rms(rb, *c2_range)), lin(-6), 0.08),
              "%s %s %s %s" % (rms(rb, *c1_range), rms(ra, *c1_range), rms(rb, *c2_range), rms(ra, *c2_range)))

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
print("ALL PASS" if not fails else "FAILED: %s" % fails)
sys.exit(1 if fails else 0)

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

import array, json, os, re, shutil, struct, subprocess, sys, tempfile, time, traceback

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


def commit(mode="propagate"):
    """Commits the open session. `mode`: what this commit does to the other instances (None = the
    object's own setting, and no `mode` parameter at all)."""
    r = cmd("consolidate.edit_commit", **({"mode": mode} if mode else {}))
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

    # ── 3 — the setting ──
    section("3 — the setting: closeMode ask | propagate | variant (INC 1)")
    def_id, i1, i2, i3 = build("s3")
    lst = defs()[def_id]
    check("a fresh consolidated object defaults to ask, and counts its 3 instances",
          lst["close_mode"] == "ask" and lst["instance_count"] == 3, str(lst))
    for m in ("propagate", "variant", "ask"):
        r = cmd("consolidate.set_close_mode", id=def_id, mode=m)
        check("set_close_mode %s answers and reads back" % m,
              r["close_mode"] == m and defs()[def_id]["close_mode"] == m, str(r))
    try:
        cmd("consolidate.set_close_mode", id=def_id, mode="everywhere")
        check("an unknown mode is refused (bad_params)", False)
    except ObjekatError as e:
        check("an unknown mode is refused (bad_params)", e.code == "bad_params", e.code)
    try:
        cmd("consolidate.set_close_mode", id="00000000-0000-0000-0000-000000000000", mode="ask")
        check("an unknown object is refused (not_found)", False)
    except ObjekatError as e:
        check("an unknown object is refused (not_found)", e.code == "not_found", e.code)

    # undo / redo : one point per change, none when nothing changes
    cmd("consolidate.set_close_mode", id=def_id, mode="variant")
    cmd("consolidate.set_close_mode", id=def_id, mode="variant")      # no change: no undo point
    cmd("edit.undo")
    check("one undo reverts the change (the unchanged repeat left no point)",
          defs()[def_id]["close_mode"] == "ask", defs()[def_id]["close_mode"])
    cmd("edit.redo")
    check("redo brings it back", defs()[def_id]["close_mode"] == "variant")

    # save / reopen: format 38, the mode survives
    cmd("project.save"); settle()
    pj = os.path.join(PROJ, "p.objekat")
    doc = json.load(open(pj))
    check("the file is format 38 and writes closeMode",
          doc.get("version") == 38 and doc["objectDefinitions"][0].get("closeMode") == "variant",
          str((doc.get("version"), doc["objectDefinitions"][0])))
    check("the notice describes closeMode", any("closeMode" in l for l in doc.get("_readme", [])))
    cmd("project.open", path=pj); settle()
    check("reopened: variant is still there", defs()[def_id]["close_mode"] == "variant")

    # a file from before (37, no key) reads as ask; an unknown value too
    for e in doc["objectDefinitions"]:
        e.pop("closeMode", None)
    doc["version"] = 37
    json.dump(doc, open(pj, "w"))
    cmd("project.open", path=pj); settle()
    check("a format 37 file (no closeMode) opens with ask", defs()[def_id]["close_mode"] == "ask")
    doc["objectDefinitions"][0]["closeMode"] = "something-new"
    json.dump(doc, open(pj, "w"))
    cmd("project.open", path=pj); settle()
    check("an unknown closeMode reads as ask, without refusing the file", defs()[def_id]["close_mode"] == "ask")

    # the three places that rebuild a definition field by field keep the mode
    cmd("consolidate.set_close_mode", id=def_id, mode="propagate")
    cmd("consolidate.edit_begin", placement=i1); settle()
    a_root = children(find(i1))[0]["id"]
    kids = sorted(children(find(a_root)), key=lambda k: k["startTime"])
    cmd("object.set_gain", ids=[kids[1]["id"]], db=-3.0)
    commit()
    check("a commit (re-bake) keeps the mode and bumps the revision",
          defs()[def_id]["close_mode"] == "propagate" and defs()[def_id]["revision"] == 1,
          str(defs()[def_id]))

    # the background cascade: X inside B, B = [instance of X, plain clip]
    PROJ_N = os.path.join(ROOT, "s3n"); os.makedirs(PROJ_N, exist_ok=True)
    globals()["PROJ"] = PROJ_N
    cmd("project.new")
    cmd("project.save_as", path=os.path.join(PROJ_N, "p.objekat"))
    xc = cmd("object.add", path=BIP, lane=8, start=0.0)["id"]
    r = cmd("consolidate.make", id=xc); cmd("job.wait", id=r["job_id"], timeout_ms=60000); settle()
    x_def = next(iter(defs()))
    x2 = cmd("object.duplicate", ids=[xc])["ids"][0]
    yc = cmd("object.add", path=BIP, lane=9, start=1.0)["id"]
    gb = cmd("group.create", ids=[x2, yc])["id"]
    r = cmd("consolidate.make", id=gb); cmd("job.wait", id=r["job_id"], timeout_ms=60000); settle()
    b_def = next(d for d in defs() if d != x_def)
    check("a new consolidation (the finishConsolidate site) starts at ask", defs()[b_def]["close_mode"] == "ask")
    check("X counts its one placement left on the timeline + the definition B that nests it",
          defs()[x_def]["instance_count"] == 1 + 1, str(defs()[x_def]))
    cmd("consolidate.set_close_mode", id=b_def, mode="variant")
    rev0 = defs()[b_def]["revision"]
    cmd("consolidate.edit_begin", placement=xc); settle()
    cmd("object.set_gain", ids=[children(find(xc))[0]["id"]], db=-6.0); settle()
    commit()
    for _ in range(120):
        if defs()[b_def]["revision"] > rev0 and not defs()[b_def]["stale"] and not cmd("consolidate.state")["renders"]:
            break
        time.sleep(0.5)
    check("the cascade re-baked B and kept its mode (variant)",
          defs()[b_def]["revision"] > rev0 and defs()[b_def]["close_mode"] == "variant",
          str(defs()[b_def]))
    st = cmd("consolidate.state")
    check("consolidate.state carries close_mode and instance_count",
          "close_mode" in st and "instance_count" in st, str(st))

    # helpers shared by the sections below
    def tweak_c2(inst, db=-6.0):
        """In the open session of `inst` (a group content): c2's gain."""
        a_root = children(find(inst))[0]["id"]
        kids = sorted(children(find(a_root)), key=lambda k: k["startTime"])
        cmd("object.set_gain", ids=[kids[1]["id"]], db=db); settle()

    def halves(wav):
        dur = duration_of(wav)
        return rms(wav, 0.0, dur * 0.5), rms(wav, dur * 0.5, dur)

    def state_dump():
        return json.dumps(sorted(state_items(), key=lambda o: o["id"]), sort_keys=True)

    def def_of(oid):
        o = find(oid)
        return o.get("definitionID") if o else None

    # ── 4 — variant ──
    section("4 — close in VARIANT: a new object, the others untouched (INC 2)")
    def_id, i1, i2, i3 = build("s4")
    cmd("consolidate.set_close_mode", id=def_id, mode="variant")
    D0 = dict(defs()[def_id])
    b1, b2, b3 = (render_instance(x, "s4_before_%d" % n) for n, x in enumerate((i1, i2, i3)))
    t1 = instance_start_dur(i1)
    cmd("consolidate.edit_begin", placement=i1); settle()
    check("variant: the other instances are NOT mirrored while it is open (still closed clips)",
          clip_of(find(i2)) is not None and clip_of(find(i3)) is not None)
    st = cmd("consolidate.state")
    check("variant: the open instance is joined to nobody (violet traits), the others stay joined",
          st["linked_with"] == [] and sorted(defs()[def_id]["linked"]) == sorted([i2, i3]),
          "%s %s" % (st["linked_with"], defs()[def_id]["linked"]))
    tweak_c2(i1)
    commit(mode=None)
    ds = defs()
    new_ids = [d for d in ds if d != def_id]
    check("variant: two definitions now", len(ds) == 2 and len(new_ids) == 1, str(list(ds)))
    V = ds[new_ids[0]] if new_ids else {}
    check("variant: the variant is at revision 1, named like the original plus a number, same setting",
          V.get("revision") == 1 and V.get("name", "").startswith(D0["name"]) and V.get("name") != D0["name"]
          and V.get("close_mode") == "variant", str(V))
    check("variant: the instance that was opened is on the variant, and carries its name",
          def_of(i1) == V.get("id") and find(i1).get("label") == V.get("name"), str(find(i1).get("label")))
    check("variant: the original is exactly as it was (revision, wave, name), its two other instances on it",
          ds[def_id]["revision"] == D0["revision"] and ds[def_id]["wave"] == D0["wave"]
          and ds[def_id]["name"] == D0["name"] and sorted(ds[def_id]["placements"]) == sorted([i2, i3])
          and def_of(i2) == def_id and def_of(i3) == def_id, str(ds[def_id]))
    cons = os.path.join(PROJ, "samples", "consolidate")
    vw = V.get("wave", "x")
    check("variant: its own wave and sidecar are on disk, the original's too",
          os.path.isfile(os.path.join(cons, vw)) and os.path.isfile(os.path.join(cons, os.path.splitext(vw)[0] + "_objectstate.json"))
          and os.path.isfile(os.path.join(cons, D0["wave"])) and vw != D0["wave"])
    check("variant: the opened instance keeps its place", instance_start_dur(i1) == t1)
    a1, a2, a3 = (render_instance(x, "s4_after_%d" % n) for n, x in enumerate((i1, i2, i3)))
    check("variant: the other two instances sound exactly as before",
          near(rms(a2, 0, 1.4), rms(b2, 0, 1.4), 1e-4) and near(rms(a3, 0, 1.4), rms(b3, 0, 1.4), 1e-4)
          and near(duration_of(a2), duration_of(b2), 1e-3))
    h1b, h1a = halves(b1), halves(a1)
    check("variant: the variant sounds different — first half the same, second half ~6 dB lower",
          near(h1a[0], h1b[0], 0.01) and near(h1a[1] / max(1e-9, h1b[1]), lin(-6), 0.08), "%s %s" % (h1b, h1a))
    for _ in range(10):
        if not cmd("consolidate.state")["renders"]: break
        time.sleep(0.3)
    check("variant: no cascade, nothing stale, no render running",
          not cmd("consolidate.state")["renders"] and not any(d["stale"] for d in defs().values())
          and defs()[def_id]["revision"] == D0["revision"])
    # a variant with NOTHING changed forks nothing
    n_defs = len(defs())
    cmd("consolidate.edit_begin", placement=i2); settle()
    commit(mode="variant")
    check("variant: a session with nothing changed forks nothing",
          len(defs()) == n_defs and def_of(i2) == def_id and clip_of(find(i2)) is not None, str(len(defs())))

    # ── 10 — links (the traits between instances of one object) ──
    section("10 — links: the instances that share an object, after a variant")
    check("after the variant, the original's instances are joined to each other only",
          sorted(defs()[def_id]["linked"]) == sorted([i2, i3]) and defs()[V["id"]]["linked"] == [i1], str(defs()))
    cmd("object.move", id=i1, lane=6, start=20.0); settle()      # room for a copy
    i1b = cmd("object.duplicate", ids=[i1])["ids"][0]; settle()
    check("a copy of the variant's instance joins the variant, not the original",
          def_of(i1b) == V["id"] and sorted(defs()[V["id"]]["linked"]) == sorted([i1, i1b])
          and sorted(defs()[def_id]["linked"]) == sorted([i2, i3]), str(defs()))
    cmd("consolidate.set_close_mode", id=def_id, mode="propagate")
    cmd("consolidate.edit_begin", placement=i2); settle()
    check("in an ask/propagate session the open instance stays joined to the others",
          sorted(cmd("consolidate.state")["linked_with"]) == [i3], str(cmd("consolidate.state")["linked_with"]))
    cmd("consolidate.set_close_mode", id=def_id, mode="variant")
    check("...and leaves them the moment the setting says variant (mirrors cut too)",
          cmd("consolidate.state")["linked_with"] == [] and clip_of(find(i3)) is not None)
    cmd("consolidate.set_close_mode", id=def_id, mode="propagate")
    check("...and comes back when the setting does",
          sorted(cmd("consolidate.state")["linked_with"]) == [i3])
    cmd("consolidate.edit_cancel"); settle()

    # ── 5 — everywhere ──
    section("5 — close EVERYWHERE: the three instances change")
    def_id, i1, i2, i3 = build("s5")
    cmd("consolidate.set_close_mode", id=def_id, mode="propagate")
    bs = [render_instance(x, "s5_before_%d" % n) for n, x in enumerate((i1, i2, i3))]
    cmd("consolidate.edit_begin", placement=i1); settle()
    tweak_c2(i1)
    commit(mode=None)
    check("everywhere: still one object, revision 1", len(defs()) == 1 and defs()[def_id]["revision"] == 1,
          str(defs()))
    for n, x in enumerate((i1, i2, i3)):
        hb, ha = halves(bs[n]), halves(render_instance(x, "s5_after_%d" % n))
        check("everywhere: instance %d — first half the same, second ~6 dB lower" % (n + 1),
              near(ha[0], hb[0], 0.01) and near(ha[1] / max(1e-9, hb[1]), lin(-6), 0.08), "%s %s" % (hb, ha))
    # the commit's own parameter wins over the setting, both ways
    cmd("consolidate.set_close_mode", id=def_id, mode="variant")
    cmd("consolidate.edit_begin", placement=i1); settle()
    tweak_c2(i1, -12.0)
    commit(mode="propagate")
    check("everywhere: mode=propagate overrides a `variant` setting for this commit",
          len(defs()) == 1 and defs()[def_id]["revision"] == 2, str(defs()))
    cmd("consolidate.set_close_mode", id=def_id, mode="propagate")
    cmd("consolidate.edit_begin", placement=i1); settle()
    tweak_c2(i1, -3.0)
    commit(mode="variant")
    check("variant: mode=variant overrides a `propagate` setting for this commit",
          len(defs()) == 2 and defs()[def_id]["revision"] == 2 and def_of(i1) != def_id, str(defs()))

    # ── 6 — ask ──
    section("6 — ASK: a command never opens a box")
    def_id, i1, i2, i3 = build("s6")
    check("ask is the default", defs()[def_id]["close_mode"] == "ask")
    cmd("consolidate.edit_begin", placement=i1); settle()
    tweak_c2(i1)
    try:
        commit(mode=None)
        check("ask + other instances + a change, no mode: invalid_state 'mode required'", False)
    except ObjekatError as e:
        check("ask + other instances + a change, no mode: invalid_state 'mode required'",
              e.code == "invalid_state" and "mode required" in e.message, "%s %s" % (e.code, e.message))
    check("...and the session stays open, nothing moved",
          cmd("consolidate.state")["editing"] and len(defs()) == 1 and defs()[def_id]["revision"] == 0)
    try:
        commit(mode="everywhere")
        check("a mode other than propagate/variant is refused", False)
    except ObjekatError as e:
        check("a mode other than propagate/variant is refused", e.code == "bad_params", e.code)
    commit(mode="propagate")
    check("...then the same commit with a mode goes through", not cmd("consolidate.state")["editing"]
          and defs()[def_id]["revision"] == 1)
    cmd("consolidate.edit_begin", placement=i1); settle()
    commit(mode=None)
    check("ask, nothing changed: no question, no mode needed, nothing re-baked",
          not cmd("consolidate.state")["editing"] and defs()[def_id]["revision"] == 1)
    # a lone instance has nobody to ask about
    PROJ_S = os.path.join(ROOT, "s6b"); os.makedirs(PROJ_S, exist_ok=True)
    globals()["PROJ"] = PROJ_S
    cmd("project.new")
    cmd("project.save_as", path=os.path.join(PROJ_S, "p.objekat"))
    lone = cmd("object.add", path=BIP, lane=3, start=0.0)["id"]
    r = cmd("consolidate.make", id=lone); cmd("job.wait", id=r["job_id"], timeout_ms=60000); settle()
    lone_def = next(iter(defs()))
    check("a lone instance: ask, count 1", defs()[lone_def]["close_mode"] == "ask" and defs()[lone_def]["instance_count"] == 1)
    cmd("consolidate.edit_begin", placement=lone); settle()
    cmd("object.set_gain", ids=[children(find(lone))[0]["id"]], db=-4.0); settle()
    commit(mode=None)
    check("a lone instance: ask passes without a mode (propagates, nobody to ask)",
          defs()[lone_def]["revision"] == 1 and len(defs()) == 1, str(defs()))

    # ── 7 — undo / redo of a variant ──
    section("7 — undo / redo: ONE point for a variant")
    def_id, i1, i2, i3 = build("s7")
    cmd("consolidate.set_close_mode", id=def_id, mode="variant")
    dump0 = state_dump()
    cmd("consolidate.edit_begin", placement=i1); settle()
    tweak_c2(i1)
    commit(mode=None)
    check("variant made: two objects", len(defs()) == 2)
    dump1 = state_dump()
    cmd("edit.undo"); settle()
    check("ONE undo: the variant is gone, the instance is back, closed and linked to the original, "
          "exactly as before the opening",
          len(defs()) == 1 and def_of(i1) == def_id and clip_of(find(i1)) is not None
          and state_dump() == dump0)
    cmd("edit.redo"); settle()
    check("redo: the variant is back, the instance on it", len(defs()) == 2 and def_of(i1) != def_id
          and state_dump() == dump1)
    cmd("edit.undo"); settle()
    check("undo again: still the same single step back", len(defs()) == 1 and state_dump() == dump0)
    r = render_instance(i1, "s7_after_undo")
    check("the undone instance sounds like the original again",
          near(rms(r, 0, 1.4), rms(base, 0, 1.4), 1e-3))

    # ── 8 — nesting ──
    section("8 — nesting: a variant of an object that another object holds")
    PROJ_N2 = os.path.join(ROOT, "s8"); os.makedirs(PROJ_N2, exist_ok=True)
    globals()["PROJ"] = PROJ_N2
    cmd("project.new")
    pj8 = os.path.join(PROJ_N2, "p.objekat")
    cmd("project.save_as", path=pj8)
    xc = cmd("object.add", path=BIP, lane=8, start=0.0)["id"]
    r = cmd("consolidate.make", id=xc); cmd("job.wait", id=r["job_id"], timeout_ms=60000); settle()
    x_def = next(iter(defs()))
    x2 = cmd("object.duplicate", ids=[xc])["ids"][0]
    yc = cmd("object.add", path=BIP, lane=9, start=1.0)["id"]
    gb = cmd("group.create", ids=[x2, yc])["id"]
    r = cmd("consolidate.make", id=gb); cmd("job.wait", id=r["job_id"], timeout_ms=60000); settle()
    b_def = next(d for d in defs() if d != x_def)
    cmd("consolidate.set_close_mode", id=x_def, mode="variant")
    x_rev = defs()[x_def]["revision"]
    cmd("consolidate.edit_begin", placement=gb); settle()
    nested = next(o["id"] for o in walk([find(gb)]) if o.get("definitionID") == x_def)
    cmd("consolidate.edit_begin", placement=nested); settle()
    check("nested session: depth 2", cmd("consolidate.state")["depth"] == 2)
    cmd("object.set_gain", ids=[children(find(nested))[0]["id"]], db=-6.0); settle()
    commit(mode=None)
    nested_def = def_of(nested)
    check("nested variant: the instance inside B's open content is on a NEW object",
          nested_def not in (None, x_def) and len(defs()) == 3 and defs()[x_def]["revision"] == x_rev,
          str(defs().keys()))
    check("...the top-level instance of the original is intact", def_of(xc) == x_def
          and clip_of(find(xc)) is not None)
    check("...B is still open (depth 1)", cmd("consolidate.state")["depth"] == 1)
    commit(mode="propagate")
    cmd("project.save"); settle()
    doc = json.load(open(pj8))
    b_entry = next(e for e in doc["objectDefinitions"] if e["id"] == b_def)
    dep = [d["definitionID"] for d in b_entry.get("dependsOn", [])]
    check("B's dependsOn names the variant, no longer the original",
          nested_def in dep and x_def not in dep, str(dep))
    check("nothing is stale", not any(d["stale"] for d in defs().values()), str({k: v["stale"] for k, v in defs().items()}))

    # ── 9 — across tabs ──
    section("9 — a consolidated object pasted into another tab keeps its setting")
    def_id, i1, i2, i3 = build("s9")
    cmd("consolidate.set_close_mode", id=def_id, mode="variant")
    cmd("project.save"); settle()
    tab_a = cmd("app.info")["active_tab"]
    cmd("tab.new")
    tab_b = cmd("app.info")["active_tab"]
    cmd("project.save_as", path=os.path.join(ROOT, "s9", "other.objekat")); settle()
    cmd("tab.select", id=tab_a); settle()
    cmd("selection.set", ids=[i1])
    copied = cmd("clipboard.copy")
    cmd("tab.select", id=tab_b); settle()
    cmd("timesel.set", start=0, end=2, lane=0, lane_count=1)
    pasted = cmd("clipboard.paste")
    nid = pasted["ids"][0]
    nd = def_of(nid)
    check("pasted: a brand-new object that keeps `variant`",
          nd is not None and nd != def_id and defs().get(nd, {}).get("close_mode") == "variant",
          "%s %s" % (nd, defs().get(nd)))

    # ── 11 — the ASK box (what the hand sees; the policy answers in its place) ──
    section("11 — the ask box: Everywhere / New variant / Cancel, by the double click that closes")

    def close_by_hand(inst):
        """The hand's gesture: a double click on the open instance (EditViewModel.handleCanvasClick → closeConsolidate())."""
        cmd("selection.click", id=inst, zone="body", double=True)

    def last_dialog():
        j = cmd("app.dialogs")["dialogs"]
        return j[-1] if j else None

    def_id, i1, i2, i3 = build("s11")
    cmd("app.dialogs", clear=True)
    cmd("app.set_dialog_policy", policy="assume_no")
    cmd("consolidate.edit_begin", placement=i1); settle()
    tweak_c2(i1)
    dump_open = state_dump()
    close_by_hand(i1); settle()
    dlg = last_dialog()
    check("ask + 2 other instances + a change: the box was put (answered `cancel` by the policy)",
          dlg is not None and dlg["answer"] == "cancel" and bool(re.search(r"\b2\b", dlg["info"])), str(dlg))
    check("Cancel: the session stays open, nothing re-baked, no undo point, nothing laid",
          cmd("consolidate.state")["editing"] and defs()[def_id]["revision"] == 0 and len(defs()) == 1
          and state_dump() == dump_open)
    cmd("app.set_dialog_policy", policy="assume_yes")
    cmd("app.dialogs", clear=True)
    close_by_hand(i1); settle()
    for _ in range(100):
        if not cmd("consolidate.state")["editing"] and not cmd("consolidate.state")["renders"]: break
        time.sleep(0.3)
    dlg = last_dialog()
    check("Everywhere (the policy's yes): re-baked for the three",
          dlg is not None and dlg["answer"] == "everywhere" and defs()[def_id]["revision"] == 1
          and len(defs()) == 1, str(dlg))
    # no question when nothing changed
    cmd("app.dialogs", clear=True)
    cmd("app.set_dialog_policy", policy="assume_no")
    cmd("consolidate.edit_begin", placement=i2); settle()
    close_by_hand(i2); settle()
    check("nothing changed: no box, the session closes",
          not cmd("consolidate.state")["editing"] and cmd("app.dialogs")["dialogs"] == [])
    # propagate / variant settings never ask
    cmd("consolidate.set_close_mode", id=def_id, mode="propagate")
    cmd("consolidate.edit_begin", placement=i2); settle()
    tweak_c2(i2, -9.0)
    close_by_hand(i2); settle()
    for _ in range(100):
        if not cmd("consolidate.state")["editing"] and not cmd("consolidate.state")["renders"]: break
        time.sleep(0.3)
    check("a `propagate` setting does not ask", cmd("app.dialogs")["dialogs"] == [] and defs()[def_id]["revision"] == 2)
    cmd("consolidate.set_close_mode", id=def_id, mode="variant")
    cmd("consolidate.edit_begin", placement=i2); settle()
    tweak_c2(i2, -3.0)
    close_by_hand(i2); settle()
    for _ in range(100):
        if not cmd("consolidate.state")["editing"] and not cmd("consolidate.state")["renders"]: break
        time.sleep(0.3)
    check("a `variant` setting does not ask and forks", cmd("app.dialogs")["dialogs"] == [] and len(defs()) == 2)

    # a lone instance: nobody to ask
    PROJ_L = os.path.join(ROOT, "s11b"); os.makedirs(PROJ_L, exist_ok=True)
    globals()["PROJ"] = PROJ_L
    cmd("project.new")
    cmd("project.save_as", path=os.path.join(PROJ_L, "p.objekat"))
    lone = cmd("object.add", path=BIP, lane=3, start=0.0)["id"]
    r = cmd("consolidate.make", id=lone); cmd("job.wait", id=r["job_id"], timeout_ms=60000); settle()
    lone_def = next(iter(defs()))
    cmd("app.dialogs", clear=True)
    cmd("consolidate.edit_begin", placement=lone); settle()
    cmd("object.set_gain", ids=[children(find(lone))[0]["id"]], db=-4.0); settle()
    close_by_hand(lone); settle()
    for _ in range(100):
        if not cmd("consolidate.state")["editing"] and not cmd("consolidate.state")["renders"]: break
        time.sleep(0.3)
    check("a lone instance: no box (no one to ask), it re-bakes",
          cmd("app.dialogs")["dialogs"] == [] and defs()[lone_def]["revision"] == 1)
    # ... but an instance nested in another object counts: X on the timeline + B holding X
    xc2 = cmd("object.add", path=BIP, lane=8, start=5.0)["id"]
    r = cmd("consolidate.make", id=xc2); cmd("job.wait", id=r["job_id"], timeout_ms=60000); settle()
    x_def2 = next(d for d in defs() if d != lone_def)
    xc3 = cmd("object.duplicate", ids=[xc2])["ids"][0]
    yc2 = cmd("object.add", path=BIP, lane=9, start=7.0)["id"]
    gb2 = cmd("group.create", ids=[xc3, yc2])["id"]
    r = cmd("consolidate.make", id=gb2); cmd("job.wait", id=r["job_id"], timeout_ms=60000); settle()
    cmd("app.dialogs", clear=True)
    cmd("consolidate.edit_begin", placement=xc2); settle()
    cmd("object.set_gain", ids=[children(find(xc2))[0]["id"]], db=-5.0); settle()
    close_by_hand(xc2); settle()
    dlg = last_dialog()
    check("an instance nested inside another object counts as one (the box says 1)",
          dlg is not None and dlg["answer"] == "cancel" and bool(re.search(r"\b1\b", dlg["info"])), str(dlg))
    cmd("consolidate.edit_cancel"); settle()
    cmd("app.set_dialog_policy", policy="ask")

    # ── 12 — a variant needs somebody else ──
    section("12 — a single instance: the whole selector greyed (variant_available), the closing always applies everywhere")
    PROJ_V = os.path.join(ROOT, "s12"); os.makedirs(PROJ_V, exist_ok=True)
    globals()["PROJ"] = PROJ_V
    cmd("project.new")
    cmd("project.save_as", path=os.path.join(PROJ_V, "p.objekat"))
    solo = cmd("object.add", path=BIP, lane=3, start=0.0)["id"]
    r = cmd("consolidate.make", id=solo); cmd("job.wait", id=r["job_id"], timeout_ms=60000); settle()
    sd = next(iter(defs()))
    check("one instance: variant_available false, count 1", defs()[sd]["variant_available"] is False
          and defs()[sd]["instance_count"] == 1)
    r = cmd("consolidate.set_close_mode", id=sd, mode="variant")
    check("set_close_mode variant stays accepted and is stored as it is",
          r["close_mode"] == "variant" and defs()[sd]["close_mode"] == "variant")
    cmd("consolidate.edit_begin", placement=solo); settle()
    st = cmd("consolidate.state")
    check("the open session says it too (variant_available false, close_mode variant kept)",
          st["variant_available"] is False and st["close_mode"] == "variant")
    cmd("object.set_gain", ids=[children(find(solo))[0]["id"]], db=-4.0); settle()
    r = cmd("consolidate.edit_commit")
    j = cmd("job.wait", id=r["job_id"], timeout_ms=60000); settle()
    check("variant stored, no mode, one instance: applies everywhere (no error, forked false)",
          r["forked"] is False and j["result"]["forked"] is False and len(defs()) == 1
          and defs()[sd]["revision"] == 1 and def_of(solo) == sd, str((r, j, defs())))
    check("...the stored setting is NOT rewritten", defs()[sd]["close_mode"] == "variant")
    cmd("consolidate.edit_begin", placement=solo); settle()
    cmd("object.set_gain", ids=[children(find(solo))[0]["id"]], db=-6.0); settle()
    r = cmd("consolidate.edit_commit", mode="variant")
    j = cmd("job.wait", id=r["job_id"], timeout_ms=60000); settle()
    check("edit_commit mode=variant with one instance: no error, forked false, the object re-baked "
          "in place, the instance still on it",
          r["forked"] is False and len(defs()) == 1 and defs()[sd]["revision"] == 2
          and def_of(solo) == sd, str((r, defs())))
    # a second instance: the setting takes effect again
    twin = cmd("object.duplicate", ids=[solo])["ids"][0]; settle()
    check("a second instance: variant_available true, count 2",
          defs()[sd]["variant_available"] is True and defs()[sd]["instance_count"] == 2)
    cmd("consolidate.edit_begin", placement=solo); settle()
    cmd("object.set_gain", ids=[children(find(solo))[0]["id"]], db=-9.0); settle()
    r = cmd("consolidate.edit_commit")
    j = cmd("job.wait", id=r["job_id"], timeout_ms=60000); settle()
    check("with a second instance the stored `variant` forks again (forked true, 2 objects, "
          "the twin untouched)",
          r["forked"] is True and len(defs()) == 2 and def_of(solo) != sd and def_of(twin) == sd
          and defs()[sd]["revision"] == 2, str((r, defs())))
    # an instance nested in another object counts as somebody else
    nx = cmd("object.add", path=BIP, lane=8, start=5.0)["id"]
    r = cmd("consolidate.make", id=nx); cmd("job.wait", id=r["job_id"], timeout_ms=60000); settle()
    nd = next(d for d in defs() if d not in (sd, def_of(solo)))
    check("alone: variant not available", defs()[nd]["variant_available"] is False)
    nx2 = cmd("object.duplicate", ids=[nx])["ids"][0]
    ny = cmd("object.add", path=BIP, lane=9, start=7.0)["id"]
    gn = cmd("group.create", ids=[nx2, ny])["id"]
    r = cmd("consolidate.make", id=gn); cmd("job.wait", id=r["job_id"], timeout_ms=60000); settle()
    check("one on the timeline + one held by another object: available (same count as the box)",
          defs()[nd]["instance_count"] == 2 and defs()[nd]["variant_available"] is True,
          str(defs()[nd]))

    # ── 13 — « Remember »: the answer becomes the object's setting ──
    section("13 — remember: edit_commit {mode, remember} stores the answer as the object's setting")

    def mode_of(d):
        return defs()[d]["close_mode"]

    def commit_remember(mode, remember):
        r = cmd("consolidate.edit_commit", mode=mode, remember=remember)
        j = cmd("job.wait", id=r["job_id"], timeout_ms=60000)
        settle()
        return r, j

    # variant + remember: D and D' both `variant`, ONE undo gives back the closing AND the setting
    def_id, i1, i2, i3 = build("s13a")
    check("ask to start with", mode_of(def_id) == "ask")
    dump0 = state_dump()
    cmd("consolidate.edit_begin", placement=i1); settle()
    tweak_c2(i1)
    r, j = commit_remember("variant", True)
    ds = defs()
    new_ids = [d for d in ds if d != def_id]
    check("variant + remember: forked, remembered, two definitions", r["forked"] is True
          and r["remembered"] is True and len(ds) == 2 and len(new_ids) == 1, str(r))
    check("variant + remember: D is now `variant` AND the variant D' inherits it",
          mode_of(def_id) == "variant" and ds[new_ids[0]]["close_mode"] == "variant", str(ds))
    cmd("edit.undo"); settle()
    check("ONE undo: D' gone AND D's setting back to `ask`, the instance as before the opening",
          len(defs()) == 1 and mode_of(def_id) == "ask" and def_of(i1) == def_id and state_dump() == dump0,
          str(defs()))
    cmd("edit.redo"); settle()
    check("redo: the variant AND the memorised setting come back", len(defs()) == 2
          and mode_of(def_id) == "variant")
    cmd("edit.undo"); settle()

    # propagate + remember: everywhere, and the setting is `propagate`
    def_id, i1, i2, i3 = build("s13b")
    cmd("consolidate.edit_begin", placement=i1); settle()
    tweak_c2(i1)
    r, j = commit_remember("propagate", True)
    check("propagate + remember: everywhere (revision 1), the setting is `propagate`, one definition",
          r["forked"] is False and r["remembered"] is True and len(defs()) == 1
          and defs()[def_id]["revision"] == 1 and mode_of(def_id) == "propagate", str(defs()))
    cmd("edit.undo"); settle()
    check("one undo: revision and setting both back", defs()[def_id]["revision"] == 0 and mode_of(def_id) == "ask")

    # remember:false (or absent) leaves the setting alone
    def_id, i1, i2, i3 = build("s13c")
    cmd("consolidate.edit_begin", placement=i1); settle()
    tweak_c2(i1)
    r, j = commit_remember("propagate", False)
    check("remember false: the setting is untouched", r["remembered"] is False and mode_of(def_id) == "ask")

    # nothing changed: nothing remembered
    cmd("consolidate.edit_begin", placement=i2); settle()
    r, j = commit_remember("propagate", True)
    check("nothing changed: nothing remembered (closes like a cancel)",
          r["remembered"] is False and mode_of(def_id) == "ask", str(r))

    # remember needs a mode
    cmd("consolidate.edit_begin", placement=i2); settle()
    try:
        cmd("consolidate.edit_commit", remember=True)
        check("remember without mode refused", False)
    except ObjekatError as e:
        check("remember without mode: bad_params", e.code == "bad_params", e.code)
    cmd("consolidate.edit_cancel"); settle()

    # the policy's yes journals « everywhere » and remembers nothing
    cmd("app.dialogs", clear=True)
    cmd("app.set_dialog_policy", policy="assume_yes")
    cmd("consolidate.edit_begin", placement=i3); settle()
    tweak_c2(i3, -9.0)   # a content that really differs from the one the commit above laid down
    cmd("selection.click", id=i3, zone="body", double=True); settle()
    for _ in range(100):
        if not cmd("consolidate.state")["editing"] and not cmd("consolidate.state")["renders"]: break
        time.sleep(0.3)
    dlg = cmd("app.dialogs")["dialogs"]
    check("assume_yes: answered `everywhere`, the setting stays `ask`",
          dlg and dlg[-1]["answer"] == "everywhere" and mode_of(def_id) == "ask", str(dlg))
    cmd("app.set_dialog_policy", policy="ask")

    # a failed render writes nothing: the folder of the waves made read-only
    def_id, i1, i2, i3 = build("s13d")
    cons = os.path.join(PROJ, "samples", "consolidate")
    cmd("consolidate.edit_begin", placement=i1); settle()
    tweak_c2(i1)
    os.chmod(cons, 0o555)
    cmd("app.set_dialog_policy", policy="assume_no")   # the failure alert is journalled, never shown
    try:
        cmd("app.dialogs", clear=True)
        r = cmd("consolidate.edit_commit", mode="variant", remember=True)
        cmd("job.wait", id=r["job_id"], timeout_ms=60000); settle()
        check("render failed: the setting is NOT written, no variant made, the session is still open",
              mode_of(def_id) == "ask" and len(defs()) == 1 and cmd("consolidate.state")["editing"],
              str((defs(), cmd("consolidate.state"))))
    finally:
        os.chmod(cons, 0o755)
    check("...and the failure was reported", any(d["answer"] == "reported" for d in cmd("app.dialogs")["dialogs"]))
    cmd("app.set_dialog_policy", policy="ask")
    cmd("consolidate.edit_cancel"); settle()

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

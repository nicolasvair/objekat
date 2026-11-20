#!/usr/bin/env python3
"""A consolidated object, the retours of 2026-11-20 — a scenario that asserts.

Plan: docs/plan_consolidate_feedback_2026-11-20.md. (The selector greyed with one instance, and the
"Remember" box, are asserted by scenario_consolidate_variant.py, sections 12 and 13.)

    # 1. launch the build with the API, on a SHORT socket (a system limit: 103 bytes), one instance per run.
    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --socket=/tmp/ocf.sock

    # 2. replay (add --keep to leave the work folder behind for a look)
    ./scenario_consolidate_feedback.py /tmp/ocf.sock

Sections:
  3  adding a sound to an OPEN consolidated object whose content is a lone clip (file drop, ⌘V,
     reparent from the timeline): the clip is enveloped in a neutral group; a cancel leaves nothing
  4  a content root that is a NEUTRAL group is not shown, and de-consolidating gives ONE level
  5  taking a sound OUT of the open content, and the loss of "put in, then cancel"

Exit: 0 if every assertion passes, 1 otherwise.
"""

import array, json, os, shutil, struct, sys, tempfile, time, traceback, math, wave

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
ROOT = os.path.realpath(tempfile.mkdtemp(prefix="objk-ocf-", dir="/tmp"))
SR = 48000

fails = []


def check(label, ok, detail=""):
    if ok:
        print("ok    " + label)
    else:
        fails.append(label)
        print("FAIL  %s  %s" % (label, detail))


def section(title):
    print("\n── %s " % title + "─" * max(0, 70 - len(title)))


def near(a, b, tol=1e-3):
    return a is not None and b is not None and abs(a - b) <= tol


client = ObjekatClient(SOCK)
client.connect()


def cmd(_name, **params):
    return client.send(_name, params or None)


def fails_with(code, _name, **params):
    """True when the command is refused with this error code."""
    try:
        client.send(_name, params or None)
    except ObjekatError as e:
        return e.code == code
    return False


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


def children(o):
    return kind(o).get("children", []) if o else []


def is_group(o):
    return kind(o).get("type") == "group" if o else False


def parent_of(oid):
    for o in walk(state_items()):
        if any(c["id"] == oid for c in children(o)):
            return o
    return None


def read_wav(path):
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
    if tag == 3:
        a = array.array("f"); a.frombytes(data); s = list(a)
    elif bits == 24:
        s = [int.from_bytes(data[j:j + 3], "little", signed=True) / 8388608.0 for j in range(0, len(data), 3)]
    elif bits == 16:
        a = array.array("h"); a.frombytes(data); s = [x / 32768.0 for x in a]
    else:
        a = array.array("f"); a.frombytes(data); s = list(a)
    return ch, sr, s


def peak(wav_, t0, t1):
    ch, sr, s = wav_
    i0, i1 = int(t0 * sr) * ch, min(len(s), int(t1 * sr) * ch)
    return max((abs(x) for x in s[max(0, i0):i1]), default=0.0)


def rms(wav_, t0, t1):
    ch, sr, s = wav_
    i0, i1 = int(t0 * sr) * ch, min(len(s), int(t1 * sr) * ch)
    seg = s[max(0, i0):i1]
    return (sum(x * x for x in seg) / max(1, len(seg))) ** 0.5


def duration_of(wav_):
    ch, sr, s = wav_
    return len(s) / ch / sr


def make_long(path, seconds=1.5, tone=0.3):
    """A mono 48 kHz wav: a 440 Hz burst of `tone` seconds, then silence up to `seconds`."""
    n = int(seconds * SR)
    frames = array.array("h", [int(0.5 * 32767 * math.sin(2 * math.pi * 440 * i / SR)) if i < tone * SR else 0
                               for i in range(n)])
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes(frames.tobytes())


LONG = os.path.join(ROOT, "long.wav")
make_long(LONG)

PROJ = ROOT


def settle():
    cmd("wait_idle", timeout_ms=30000)


def defs():
    return {d["id"]: d for d in cmd("consolidate.list")["definitions"]}


def render_instance(oid, name):
    path = os.path.join(ROOT, name + ".wav")
    r = cmd("object.render_isolated", id=oid, path=path, sample_rate=SR, bit_depth=24)
    cmd("job.wait", id=r["job_id"], timeout_ms=60000)
    return read_wav(path)


def export_mix(name):
    """The whole mix as the ENGINE has it (a wav read back): what proves the engine followed the model."""
    path = os.path.join(ROOT, name + ".wav")
    r = cmd("export.run", path=path, format="wav", sample_rate=SR, bit_depth=24)
    cmd("job.wait", id=r["job_id"], timeout_ms=120000)
    return read_wav(path)


def state_dump():
    return json.dumps(sorted(state_items(), key=lambda o: o["id"]), sort_keys=True)


def commit(mode="propagate"):
    r = cmd("consolidate.edit_commit", mode=mode)
    cmd("job.wait", id=r["job_id"], timeout_ms=60000)
    settle()


def wait_renders():
    for _ in range(100):
        st = cmd("consolidate.state")
        if not st["editing"] and not st["renders"]:
            break
        time.sleep(0.3)


def new_project(tag):
    global PROJ
    PROJ = os.path.join(ROOT, tag)
    os.makedirs(PROJ, exist_ok=True)
    cmd("project.new")
    cmd("project.save_as", path=os.path.join(PROJ, "p.objekat"))


def lone_clip(tag, path=LONG):
    """A project with ONE sound consolidated alone (the content root is a clip) and a twin instance
    after it. Returns (definition id, instance, twin)."""
    new_project(tag)
    c = cmd("object.add", path=path, lane=0, start=0.0)["id"]
    r = cmd("consolidate.make", id=c)
    cmd("job.wait", id=r["job_id"], timeout_ms=60000)
    settle()
    d = next(iter(defs().values()))
    inst = d["placements"][0]
    twin = cmd("object.duplicate", ids=[inst])["ids"][0]
    settle()
    return d["id"], inst, twin


def group_content(tag):
    """A project with a consolidated GROUP of two sounds and a twin. Returns (def id, instance, twin)."""
    new_project(tag)
    c1 = cmd("object.add", path=BIP, lane=0, start=0.0)["id"]
    c2 = cmd("object.add", path=BIP, lane=2, start=1.0)["id"]
    g = cmd("group.create", ids=[c1, c2])["id"]
    r = cmd("consolidate.make", id=g)
    cmd("job.wait", id=r["job_id"], timeout_ms=60000)
    settle()
    d = next(iter(defs().values()))
    inst = d["placements"][0]
    twin = cmd("object.duplicate", ids=[inst])["ids"][0]
    settle()
    return d["id"], inst, twin


def content_root():
    """(content root object, id) of the open session."""
    cid = cmd("consolidate.state")["content_root_id"]
    return find(cid), cid


def stage_children(stage):
    return children(find(stage))


def is_neutral_wrapper(o):
    return (is_group(o) and near(o.get("volume", 0.0), 0.0) and near(o.get("pan", 0.0), 0.0)
            and not o.get("isMuted", False) and near(o.get("fadeIn", 0.0), 0.0)
            and near(o.get("fadeOut", 0.0), 0.0) and not o.get("plugins"))


def main():
    section("3 — a sound added to the open content of a LONE CLIP (INC 3)")

    # ── 3b-1: the file drop ──
    def_id, i1, twin = lone_clip("s3a")
    pre = state_dump()
    pre_mix = export_mix("s3a_pre")
    cmd("consolidate.edit_begin", placement=i1); settle()
    A0 = cmd("consolidate.state")["content_root_id"]
    a0 = find(A0)
    check("the content root of a lone clip is a CLIP (nowhere to hold a second sound)",
          kind(a0).get("type") == "clip" and len(stage_children(i1)) == 1, str(kind(a0).get("type")))
    r = cmd("debug.file_drop", paths=[BIP], lane=1, start=1.0)
    check("the drop on the content's row lays the sound down (the old build: nothing happened)",
          len(r["placed"]) == 1, str(r))
    root, root_id = content_root()
    check("content_root_id changed: the content is now an ENVELOPING group",
          root_id != A0 and is_group(root), "%s -> %s" % (A0, root_id))
    check("the stage still holds exactly ONE child: the new root",
          [c["id"] for c in stage_children(i1)] == [root_id])
    check("the enveloping group is NEUTRAL (0 dB, centred, unmuted, no fade, no plugin) and takes A's window",
          is_neutral_wrapper(root) and near(root["startTime"], a0["startTime"]) and near(root["duration"], a0["duration"]),
          json.dumps({k: root.get(k) for k in ("volume", "pan", "fadeIn", "fadeOut", "startTime", "duration")}))
    ids_inside = {c["id"] for c in children(root)}
    check("A is still inside it, and so is the new sound (A may be cut where the new one overwrites it)",
          A0 in ids_inside and len(ids_inside) >= 2, str(ids_inside))
    new_ids = [c["id"] for c in children(root) if c["id"] != A0 and kind(c).get("type") == "clip"
               and abs(c["startTime"] - 1.0) < 1e-6]
    check("the new sound is a child of the group at the instant it was dropped", len(new_ids) == 1, str(ids_inside))

    # a second addition does not envelop again
    r = cmd("debug.file_drop", paths=[BIP], lane=1, start=1.2)
    root2, root2_id = content_root()
    check("a second drop goes into the SAME group (no second envelope)",
          root2_id == root_id and len(r["placed"]) == 1)

    # commit: the others hear the new sound
    commit("propagate")
    d = defs()[def_id]
    check("committed: a new revision, the content is a group now", d["revision"] == 1 and d["was_group"] is True, str(d))
    tw = render_instance(twin, "s3a_twin")
    check("the twin plays the sound that was added (tone at 1.0..1.4 s, and A's burst at 0..0.3)",
          peak(tw, 1.0, 1.4) > 0.3 and peak(tw, 0.0, 0.3) > 0.3 and peak(tw, 0.4, 0.9) < 0.01,
          "%s %s" % (peak(tw, 1.0, 1.4), peak(tw, 0.0, 0.3)))

    # ── 3d: a cancel leaves nothing behind, model AND engine ──
    def_id, i1, twin = lone_clip("s3d")
    pre = state_dump()
    pre_mix = export_mix("s3d_pre")
    cmd("consolidate.edit_begin", placement=i1); settle()
    cmd("debug.file_drop", paths=[BIP], lane=1, start=1.0)
    cmd("consolidate.edit_cancel"); settle()
    check("cancel after a drop: the model is exactly as before the opening", state_dump() == pre)
    check("...the instance is a closed clip again, the revision is unchanged",
          kind(find(i1)).get("type") == "clip" and defs()[def_id]["revision"] == 0)
    post_mix = export_mix("s3d_post")
    check("...and the ENGINE holds no residue: the mix is the same length, with the same energy",
          near(duration_of(pre_mix), duration_of(post_mix), 0.01)
          and near(rms(pre_mix, 0, duration_of(pre_mix)), rms(post_mix, 0, duration_of(post_mix)), 1e-4)
          and near(peak(pre_mix, 0, duration_of(pre_mix)), peak(post_mix, 0, duration_of(post_mix)), 1e-4),
          "%s/%s %s/%s" % (duration_of(pre_mix), duration_of(post_mix),
                           rms(pre_mix, 0, duration_of(pre_mix)), rms(post_mix, 0, duration_of(post_mix))))

    # ── 3b-2: a content that is ALREADY a group: nothing is enveloped ──
    def_id, i1, twin = group_content("s3b")
    cmd("consolidate.edit_begin", placement=i1); settle()
    A_group = cmd("consolidate.state")["content_root_id"]
    n_before = len(children(find(A_group)))
    cmd("debug.file_drop", paths=[BIP], lane=1, start=2.0)
    check("a group content takes the sound itself: same content root, one more child",
          cmd("consolidate.state")["content_root_id"] == A_group and len(children(find(A_group))) == n_before + 1,
          "%d -> %d" % (n_before, len(children(find(A_group)))))
    cmd("consolidate.edit_cancel"); settle()

    # ── 3b-3: ⌘V ──
    def_id, i1, twin = lone_clip("s3v")
    src = cmd("object.add", path=BIP, lane=6, start=0.5)["id"]
    cmd("selection.set", ids=[src])
    cmd("clipboard.copy")
    cmd("consolidate.edit_begin", placement=i1); settle()
    A0 = cmd("consolidate.state")["content_root_id"]
    cmd("caret.set", lane=1, time=1.0)
    r = cmd("clipboard.paste")
    root, root_id = content_root()
    check("⌘V on the content's row: the sound is pasted INTO the content (enveloped)",
          root_id != A0 and is_group(root) and r["count"] == 1
          and any(abs(c["startTime"] - 1.0) < 1e-6 and kind(c).get("type") == "clip" for c in children(root)),
          str(r))
    check("...the source object is untouched, at the top level", find(src) is not None and parent_of(src) is None)
    cmd("consolidate.edit_cancel"); settle()

    # ── 3c: reparent from the timeline (group.reparent = the drop's own release) ──
    def_id, i1, twin = lone_clip("s3r")
    mover = cmd("object.add", path=BIP, lane=6, start=0.5)["id"]
    cmd("consolidate.edit_begin", placement=i1); settle()
    A0 = cmd("consolidate.state")["content_root_id"]
    r = cmd("group.reparent", ids=[mover], group=i1, child_lane=1)
    root, root_id = content_root()
    p = parent_of(mover)
    check("a top-level object dropped on the stage goes INTO the content (enveloped), on the lane asked",
          p is not None and p["id"] == root_id and root_id != A0 and find(mover)["lane"] == 1, str(r))
    check("...and A kept its own lane 0 inside the group",
          find(A0) is not None and find(A0)["lane"] == 0 and parent_of(A0)["id"] == root_id)
    commit("propagate")
    tw = render_instance(twin, "s3r_twin")
    check("committed: the twin plays the moved sound too (0.5..0.9 s) on top of A's burst (0..0.3 s)",
          peak(tw, 0.5, 0.9) > 0.3 and peak(tw, 0.0, 0.3) > 0.3, "%s %s" % (peak(tw, 0.5, 0.9), peak(tw, 0.0, 0.3)))

    section("4 — a NEUTRAL content root: read live, and left out when detaching (INC 4)")

    # ── 4a: the predicate, read live through consolidate.state ──
    def_id, i1, twin = group_content("s4a")
    cmd("consolidate.edit_begin", placement=i1); settle()
    st = cmd("consolidate.state")
    root_id = st["content_root_id"]
    check("the content root of a plain group of two sounds is neutral (a mere frame)",
          st["content_root_neutral"] is True, str(st.get("content_root_neutral")))
    cmd("object.set_gain", ids=[root_id], db=-6.0); settle()
    check("a fader on the root makes it visible again (evaluated live)",
          cmd("consolidate.state")["content_root_neutral"] is False)
    cmd("object.set_gain", ids=[root_id], db=0.0); settle()
    check("... and back to 0 dB makes it neutral again", cmd("consolidate.state")["content_root_neutral"] is True)
    cmd("object.set_mute", ids=[root_id], muted=True); settle()
    check("a muted root is not neutral", cmd("consolidate.state")["content_root_neutral"] is False)
    cmd("object.set_mute", ids=[root_id], muted=False); settle()
    cmd("consolidate.edit_cancel"); settle()
    check("no session: the field is null", cmd("consolidate.state")["content_root_neutral"] is None)

    # ── 4b: detaching a neutral root — ONE level of group, the same sound ──
    pre_mix = export_mix("s4b_pre")
    r = cmd("consolidate.unmake", placement=twin); settle()
    g = find(twin)
    kids = children(g)
    check("the detached instance is a group holding the sounds DIRECTLY (no neutral group between)",
          is_group(g) and len(kids) == 2 and all(kind(c).get("type") == "clip" for c in kids),
          json.dumps([kind(c).get("type") for c in kids]))
    check("it is no longer linked to the definition", not r["still_linked"] and not g.get("definitionID"))
    post_mix = export_mix("s4b_post")
    rb, ra = rms(pre_mix, 0.0, duration_of(pre_mix)), rms(post_mix, 0.0, duration_of(post_mix))
    check("the mix is the same (RMS %.5f / %.5f)" % (rb, ra), rb > 0.001 and abs(rb - ra) < 1e-3 * max(rb, 1e-9) + 1e-5)
    cmd("edit.undo"); settle()
    check("one undo brings the linked instance back", find(twin).get("definitionID") == def_id
          and kind(find(twin)).get("type") == "clip")

    # ── 4c: a root that is NOT neutral keeps its level ──
    def_id, i1, twin = group_content("s4c")
    cmd("consolidate.edit_begin", placement=i1); settle()
    root_id = cmd("consolidate.state")["content_root_id"]
    cmd("object.set_gain", ids=[root_id], db=-6.0); settle()
    commit("propagate")
    cmd("consolidate.unmake", placement=twin); settle()
    g = find(twin)
    kids = children(g)
    check("a content root with a fader stays a group under the detached instance",
          len(kids) == 1 and is_group(kids[0]) and abs(kids[0].get("volume", 0.0) + 6.0) < 1e-6,
          json.dumps([(kind(c).get("type"), c.get("volume")) for c in kids]))
    check("... and it still holds its two sounds", len(children(kids[0])) == 2)

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

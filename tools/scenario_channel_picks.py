#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The CHOICE OF CHANNEL written on a cable (`ObjectPlugin.channelPick`, session format 31), driven through the API.

A pick is an entry of a series that is neither a card nor a plugin: it stands on a cable point and says
which channel (left / right / sum) of a stereo cable goes on. Stereo = no entry. This scenario grows with
the steps of docs/plan_canaux_cables (E2 .. E6); what is asserted TODAY:

  * E2, the model: a project file that carries picks (hand-written: nothing creates them yet) is read
    without losing or inventing one; every walk of a chain keeps them where they belong — a copy of the
    host takes them with fresh ids, a parallel branch taken over a run carries the picks between its cards
    and leaves the others on the cables in and out, a card removed between two chosen cables lets the
    UPSTREAM one win, an inserted card lands after the pick (the choice stays upstream), undo / redo / save /
    reopen give the same chain back, a bin made of cards with a pick between them holds the pick in its
    definition AND in its instance, and `debug.send_marker_audit` stays `ok` all along (no phantom: a
    pick is never an empty plugin, never erased by a compile, never listed twice).

    ./scenario_channel_picks.py /path/to/objekat.app [socket]

Exit: 0 if every assertion passes, 1 otherwise, 2 on bad usage.
"""

import json, math, os, shutil, struct, subprocess, sys, tempfile, time, wave

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

if len(sys.argv) not in (2, 3):
    print(__doc__)
    sys.exit(2)

APP = sys.argv[1]
BIN = os.path.join(APP, "Contents", "MacOS", "objekat")
if not os.path.exists(BIN):
    print("not an app bundle: %s" % APP)
    sys.exit(2)

WORK = tempfile.mkdtemp(prefix="objcp_", dir="/tmp")
SOCK = sys.argv[2] if len(sys.argv) == 3 else os.path.join(WORK, "s.sock")
ok, ko = 0, 0


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


def write_wav(path, seconds=2.0, rate=48000, left_hz=1000.0, right_hz=3000.0, db=-20.0):
    amp = 10 ** (db / 20.0)
    frames = bytearray()
    for n in range(int(seconds * rate)):
        for hz in (left_hz, right_hz):
            frames += struct.pack("<i", int(round(amp * math.sin(2 * math.pi * hz * n / rate) * 8388607)))[:3]
    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(3)
        w.setframerate(rate)
        w.writeframes(bytes(frames))


STEREO = os.path.join(WORK, "stereo_L1k_R3k.wav")
write_wav(STEREO)

if os.path.exists(SOCK):
    os.unlink(SOCK)
proc = subprocess.Popen([BIN, "--headless", "--api", "--no-recent", "--no-audio", "--language=en",
                         "--socket=" + SOCK], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    for _ in range(160):
        if os.path.exists(SOCK):
            break
        time.sleep(0.25)
    else:
        print("the app did not open its socket")
        proc.kill()
        sys.exit(1)

    with ObjekatClient(SOCK, timeout=240) as c:
        send = c.send
        send("app.set_dialog_policy", {"policy": "assume_yes"})

        def uid(n):
            return "00000000-0000-4000-8000-%012d" % n

        def pick_entry(n, mode):
            return {"id": uid(n), "name": "", "manufacturer": "", "identifier": "", "formatName": "",
                    "colorIndex": 0, "channelPick": {"mode": mode}}

        def entries(host):
            return send("plugin.list", {"host": host})["plugins"]

        def shape(host, plist=None):
            """The chain as a word: A B C for cards (by their name tag), 'p:left' for a pick, [..|..] for a rack."""
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
            return " ".join(one(e) for e in (plist if plist is not None else entries(host)))

        def pick_ids(host):
            out = []

            def walk(es):
                for e in es:
                    if e.get("is_channel_pick"):
                        out.append(e["id"])
                    for v in e.get("voices", []):
                        walk(v)
                    if e.get("is_fx_block"):
                        walk(e["plugins"])
            walk(entries(host))
            return out

        def audit():
            send("wait_idle")
            return send("debug.send_marker_audit")

        def audit_ok(label):
            a = audit()
            check("audit ok: %s" % label, a["ok"], a["violations"])

        TAGS = {}

        def fresh(name):
            send("project.new")
            manifest = os.path.join(WORK, name + ".objekat")
            send("project.save_as", {"path": manifest})
            return manifest

        def tag(host, names):
            """Adds one built-in EQ per name; remembers the tag of each."""
            ids = []
            for n in names:
                pid = send("plugin.add", {"host": host, "identifier": "4bandEq"})["plugin"]["id"]
                TAGS[pid] = n
                ids.append(pid)
            return ids

        def retouch(manifest, edit):
            """Rewrites the saved project with `edit(doc)` and opens it again."""
            send("project.save")
            doc = json.load(open(manifest))
            edit(doc)
            json.dump(doc, open(manifest, "w"), indent=1)
            send("project.open", {"path": manifest})
            send("wait_idle")

        def first_object_id():
            return send("object.list")["objects"][0]["id"] if "objects" in send("object.list") else None

        # ═══════════════════════════════════════════════════════════════ E2 : the model
        section("E2: a file that carries picks is read without losing or inventing one")
        manifest = fresh("model")
        obj = send("object.add", {"path": STEREO, "lane": 0, "start": 0.0})["id"]
        A, B, C = tag(obj, ["A", "B", "C"])

        def put(doc):
            chain = doc["items"][0]["plugins"]
            ids = [p["id"] for p in chain]
            by = {p["id"]: p for p in chain}
            doc["items"][0]["plugins"] = [by[ids[0]], pick_entry(1, "left"), by[ids[1]],
                                          pick_entry(2, "sum"), by[ids[2]], pick_entry(3, "right")]
        retouch(manifest, put)
        obj = send("object.list")["objects"][0]["id"]
        TAGS_OLD = dict(TAGS)
        word = shape(obj)
        check("read as written: A p:left B p:sum C p:right", word == "A p:left B p:sum C p:right", word)
        check("the ids of the picks survive the load", pick_ids(obj) == [uid(1), uid(2), uid(3)], pick_ids(obj))
        audit_ok("after the load (no phantom, nothing erased by the compile)")
        saved_ids = pick_ids(obj)

        section("E2: the copy of a host takes the picks with fresh ids")
        dup = send("object.duplicate", {"ids": [obj]})["ids"][0]
        send("wait_idle")
        wd = shape(dup, [dict(e, id=e["id"]) for e in entries(dup)])
        dup_picks = pick_ids(dup)
        check("the duplicate holds three picks in the same places",
              wd.count("p:") == 3 and [w for w in wd.split() if w.startswith("p:")] == ["p:left", "p:sum", "p:right"], wd)
        check("…with ids of their own (the id is the engine's key)",
              len(dup_picks) == 3 and not set(dup_picks) & set(saved_ids) and len(set(dup_picks)) == 3, dup_picks)
        check("the original keeps its own", pick_ids(obj) == saved_ids)
        audit_ok("after the duplicate")
        send("edit.undo")
        send("wait_idle")
        check("undo of the duplicate: the original is untouched", pick_ids(obj) == saved_ids)

        section("E2: a card inserted after a pick keeps the choice upstream")
        # plugin.add appends: the tail pick then stands BETWEEN the old last card and the new one.
        D, = tag(obj, ["D"])
        word = shape(obj)
        check("appended card D: the tail pick feeds it (…C p:right D)", word.endswith("C p:right D"), word)
        send("edit.undo")
        send("wait_idle")
        check("undo: back to the three picks", shape(obj) == "A p:left B p:sum C p:right", shape(obj))

        section("E2: a card removed between two chosen cables — the upstream pick wins")
        send("plugin.remove", {"host": obj, "plugin": B})
        word = shape(obj)
        check("B removed: A p:left C p:right (p:sum, downstream, goes)", word == "A p:left C p:right", word)
        audit_ok("after removing B")
        send("edit.undo")
        send("wait_idle")
        check("undo gives the dropped pick back: A p:left B p:sum C p:right", shape(obj) == "A p:left B p:sum C p:right", shape(obj))
        check("…the very same ids", pick_ids(obj) == saved_ids, pick_ids(obj))

        section("E2: a parallel branch over a run carries the picks BETWEEN its cards")
        send("plugin.select", {"host": obj, "plugins": [B, C]})
        r = send("plugin.branch", {"host": obj, "plugin": B})
        word = shape(obj)
        check("B C in parallel with an empty branch: A p:left [B p:sum C|] p:right", word == "A p:left [B p:sum C|] p:right", word)
        check("the three picks are still there, ids untouched", pick_ids(obj) == saved_ids, pick_ids(obj))
        audit_ok("after the branch")
        send("edit.undo")
        send("wait_idle")
        check("undo of the branch: A p:left B p:sum C p:right", shape(obj) == "A p:left B p:sum C p:right", shape(obj))
        send("edit.redo")
        send("wait_idle")
        check("redo: the branch again", shape(obj) == "A p:left [B p:sum C|] p:right", shape(obj))
        send("project.save")
        send("project.open", {"path": manifest})
        send("wait_idle")
        obj = send("object.list")["objects"][0]["id"]
        check("save / reopen: the same chain", shape(obj) == "A p:left [B p:sum C|] p:right", shape(obj))
        check("save / reopen: the same pick ids", pick_ids(obj) == saved_ids, pick_ids(obj))
        audit_ok("after save / reopen")
        # a fresh flat chain, picks written again, for the bin.
        manifest = fresh("bin")
        obj = send("object.add", {"path": STEREO, "lane": 0, "start": 0.0})["id"]
        A, B, C = tag(obj, ["A", "B", "C"])
        retouch(manifest, put)
        obj = send("object.list")["objects"][0]["id"]

        section("E2: a bin made of cards with a pick between them keeps it (definition AND instance)")
        link = send("fxlink.create", {"host": obj, "plugins": [A, B]})
        lid = link["id"] if "id" in link else link["link"]["id"]
        word = shape(obj)
        check("the pick between A and B goes into the bin, the others stay on their cables: {A p:left B} p:sum C p:right",
              word == "{A p:left B} p:sum C p:right", word)
        g = send("fxlink.get", {"link": lid})
        dprobe = [d.get("channel_pick") for d in g["plugins"]]
        check("the definition holds the pick between its two plugins", dprobe == [None, "left", None], dprobe)
        inst = g["members"][0]["instances"]
        iprobe = [i.get("channel_pick") for i in inst]
        check("the chain's own pick became the instance (same id), pointing at the definition's",
              iprobe == [None, "left", None] and inst[1]["definition"] == g["plugins"][1]["id"], inst)
        check("no pick id appears twice in the chain", len(pick_ids(obj)) == len(set(pick_ids(obj))), pick_ids(obj))
        audit_ok("after the bin")
        send("edit.undo")
        send("wait_idle")
        check("undo of the bin: A p:left B p:sum C p:right", shape(obj) == "A p:left B p:sum C p:right", shape(obj))

        section("E2: end")
        audit_ok("end")
finally:
    try:
        proc.kill()
    except Exception:
        pass
    shutil.rmtree(WORK, ignore_errors=True)

print("\n%d passed, %d failed" % (ok, ko))
sys.exit(0 if ko == 0 else 1)

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
  * E3, the engine (`debug.engine_chain`): each pick is an `ObjChannelMode` instance of its own, keyed by
    its model id, laid where the model says (before the plugin it feeds, in the user segment); a card
    removed / a branch / a bin move them with it; against an external one-input plugin a pick right
    before it leaves only the OUT half of the fold.

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

        # ═══════════════════════════════════════════════════════════════ E3 : the engine
        def engine_chain(host):
            send("wait_idle")
            return send("debug.engine_chain", {"id": host})["chain"]

        def lite(chain):
            """The user-visible part of the engine's chain: [(role, tag-or-mode)] for fx and picks, in order."""
            out = []
            low = {k.lower(): v for k, v in TAGS.items()}
            for e in chain:
                if e["role"] == "pick":
                    out.append(("pick", e["mode"]))
                elif e["role"] == "fx":
                    out.append(("fx", low.get(e.get("key", "").lower(), "?")))
                elif e["role"] == "parallel":
                    out.append(("parallel", [lite(b) for b in e["branches"]]))
                elif e["role"] in ("fold_in", "fold_out"):
                    out.append((e["role"], e["mode"]))
            return out

        def eng_until(host, pred, timeout=30.0):
            deadline = time.time() + timeout
            ch = engine_chain(host)
            while not pred(ch) and time.time() < deadline:
                time.sleep(0.25)
                ch = engine_chain(host)
            return ch

        def picks_of(chain):
            return [e for e in chain if e["role"] == "pick"]

        section("E3: the engine lays each pick as an ObjChannelMode, before the plugin it feeds")
        manifest = fresh("engine")
        obj = send("object.add", {"path": STEREO, "lane": 0, "start": 0.0})["id"]
        A, B, C = tag(obj, ["A", "B", "C"])
        retouch(manifest, put)
        obj = send("object.list")["objects"][0]["id"]
        ch = engine_chain(obj)
        want = [("fx", "A"), ("pick", "left"), ("fx", "B"), ("pick", "sum"), ("fx", "C"), ("pick", "right")]
        # the ids of the cards changed with the reload: re-tag them from the model, in order.
        TAGS.clear()
        for name, e in zip("ABC", [e for e in entries(obj) if not e.get("is_channel_pick")]):
            TAGS[e["id"]] = name
        got = lite(ch)
        check("the engine chain reads A p:left B p:sum C p:right", got == want, got)
        check("each pick is keyed by its model id (the engine's key)",
              [p["key"].lower() for p in picks_of(ch)] == [uid(1), uid(2), uid(3)], [p.get("key") for p in picks_of(ch)])
        check("every pick is an instance of its own (never one shared)",
              len({p["instance"] for p in picks_of(ch)}) == 3)
        roles = [e["role"] for e in ch]
        if "fader" in roles:
            last_pick = max(i for i, r in enumerate(roles) if r == "pick")
            check("the tail pick stands in the user segment, before the fader", last_pick < roles.index("fader"), roles)
        audit_ok("engine chain read")

        section("E3: a card removed — the engine follows (upstream pick wins), undo brings the pick back")
        send("plugin.remove", {"host": obj, "plugin": [k for k, v in TAGS.items() if v == "B"][0]})
        got = lite(engine_chain(obj))
        check("B removed: A p:left C p:right in the engine too", got == [("fx", "A"), ("pick", "left"), ("fx", "C"), ("pick", "right")], got)
        send("edit.undo")
        got = lite(engine_chain(obj))
        check("undo: the three picks are back in the engine", got == want, got)
        check("…and still under their own keys",
              [p["key"].lower() for p in picks_of(engine_chain(obj))] == [uid(1), uid(2), uid(3)])

        section("E3: a parallel branch over a run — the pick between its cards goes in the branch")
        send("plugin.select", {"host": obj, "plugins": [k for k, v in TAGS.items() if v in ("B", "C")]})
        send("plugin.branch", {"host": obj, "plugin": [k for k, v in TAGS.items() if v == "B"][0]})
        got = lite(engine_chain(obj))
        check("A p:left [B p:sum C | ...] p:right", len(got) == 4 and got[0] == ("fx", "A") and got[1] == ("pick", "left")
              and got[2][0] == "parallel" and got[3] == ("pick", "right"), got)
        if len(got) == 4 and got[2][0] == "parallel":
            check("branch 0 holds B p:sum C", got[2][1][0] == [("fx", "B"), ("pick", "sum"), ("fx", "C")], got[2][1])
        audit_ok("engine, parallel")
        send("edit.undo")
        send("wait_idle")

        section("E3: a bin keeps its pick in the engine too (the instance, keyed by the chain's pick id)")
        link = send("fxlink.create", {"host": obj, "plugins": [k for k, v in TAGS.items() if v in ("A", "B")]})
        ch = engine_chain(obj)
        pk = [p["key"].lower() for p in picks_of(ch)]
        check("three picks in the engine chain: the bin's one, then the two on the cables", pk == [uid(1), uid(2), uid(3)], pk)
        got = [r for r, _ in lite(ch)]
        check("order fx pick fx pick fx pick", got == ["fx", "pick", "fx", "pick", "fx", "pick"], got)
        audit_ok("engine, bin")
        send("edit.undo")
        send("wait_idle")

        section("E3: against an external one-input plugin, a pick before it leaves only the OUT half of the fold")
        AU_LOWPASS = "AudioUnit:Effects/aufx,lpas,appl"
        manifest = fresh("fold")
        obj = send("object.add", {"path": STEREO, "lane": 0, "start": 0.0})["id"]
        # a pick at the HEAD of a stereo clip root is the clip's own channel mode (one menu): the pick under
        # test therefore stands between a card and the plugin.
        send("plugin.add", {"host": obj, "identifier": "4bandEq"})
        lp = send("plugin.add", {"host": obj, "identifier": AU_LOWPASS})["plugin"]["id"]
        deadline = time.time() + 40
        while not send("plugin.channel_layouts", {"host": obj, "plugin": lp}).get("loaded") and time.time() < deadline:
            time.sleep(0.25)
        send("plugin.set_channel_layout", {"host": obj, "plugin": lp, "variant": "mono"})
        ch = eng_until(obj, lambda c: any(e["role"] == "fold_in" for e in c))
        got = [(e["role"], e.get("mode")) for e in ch if e["role"] in ("fold_in", "fold_out", "fx")]
        check("no pick: IN and OUT halves around the plugin (the default fold, sum)",
              got == [("fx", None), ("fold_in", "sum"), ("fx", None), ("fold_out", "sum")], got)

        for mode in ("left", "sum"):
            def put_pick(doc, mode=mode):
                chain = doc["items"][0]["plugins"]
                doc["items"][0]["plugins"] = [chain[0], pick_entry(7, mode)] + chain[1:]
            retouch(manifest, put_pick)
            obj = send("object.list")["objects"][0]["id"]
            deadline = time.time() + 40
            lp = [e for e in entries(obj) if not e.get("is_channel_pick")][1]["id"]
            while not send("plugin.channel_layouts", {"host": obj, "plugin": lp}).get("loaded") and time.time() < deadline:
                time.sleep(0.25)
            ch = eng_until(obj, lambda c: any(e["role"] == "pick" for e in c) and any(e["role"] == "fold_out" for e in c))
            got = [(e["role"], e.get("mode")) for e in ch if e["role"] in ("pick", "fold_in", "fold_out", "fx")]
            check("pick %s right before the mono plugin: card, pick, plugin, OUT half only (L = R after a pick)" % mode,
                  got == [("fx", None), ("pick", mode), ("fx", None), ("fold_out", "left")], got)
            audit_ok("fold, pick " + mode)
            # put the file back to its pick-less shape for the next round
            def drop_pick(doc):
                doc["items"][0]["plugins"] = [p for p in doc["items"][0]["plugins"] if "channelPick" not in p]
            retouch(manifest, drop_pick)

        section("E3: end")
        audit_ok("end")
finally:
    try:
        proc.kill()
    except Exception:
        pass
    shutil.rmtree(WORK, ignore_errors=True)

print("\n%d passed, %d failed" % (ok, ko))
sys.exit(0 if ko == 0 else 1)

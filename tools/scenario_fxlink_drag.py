#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""FX link — the DRAG gestures (a bin's block, plugins into / out of a bin) — a scenario that ASSERTS.

    # 1. launch the app with the API, on a SHORT socket (a system limit: 103 bytes).
    #    `--no-recent`: the throwaway projects below do not enter "Recent projects".
    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --language=en --socket=/tmp/o.sock

    # 2. run
    ./scenario_fxlink_drag.py /tmp/o.sock

A hand's drag reaches the model through ONE door (`EditViewModel.performPluginDrop`), after ONE resolver
(`pluginDropOutcome`) has told the cursor and the band what the release would do. `plugin.drop` and
`plugin.drop_at` are that door and that resolver (`dry_run`), so this is asserted with no screen. What it is
out to prove, beyond the commands answering:

  • D1  a bin's BLOCK dragged onto another object MOVES: the target joins the bin, the source loses its
        block, the others are untouched — in ONE undo point, with no duplicated plugin id;
  • D2  with ⌥ it is a COPY that stays on the same bin (every copy of a bin is a link): the mirror holds;
  • D3  a DETACHED block travels as it is (its own output section, fresh instance ids);
  • D4  what cannot happen is REFUSED, said by the dry run, and changes nothing — not even an undo point;
  • D5  a plain plugin let go INSIDE a bin joins the definition (same host or another): its instance keeps
        its id, every other member gets one;
  • D6  with ⌥ an independent copy is added to the bin, the source untouched;
  • D7  ⌘ into a bin is refused;
  • D8  an instance let go OUTSIDE its bin leaves it for EVERY member and stays a plain plugin here; ⌥ takes
        an independent copy, ⌘ is refused;
  • D9  an instance dropped on ANOTHER host: a move is refused, ⌥ copies, ⌘ makes that host join the bin;
  • D10 a bus can receive a block and plugins, like an object;
  • D11 the bins survive a save and a reopen;
  • D12 the ENGINE followed, not just the model: an export re-read at RMS (24 bit) after the block moved.

Not covered here, because the API has no way to build one: a PARALLEL block (rack) as a drop source or target.

Exit: 0 if every assertion passes, 1 otherwise.
"""

import array, math, os, shutil, sys, tempfile, wave

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

if len(sys.argv) != 2:
    print(__doc__)
    sys.exit(2)

SOCK = sys.argv[1]
BIP = os.path.join(HERE, "fixtures", "bip.wav")
TMP = tempfile.mkdtemp(prefix="fxdrag_")

fails = []
total = 0


def check(label, ok, detail=""):
    global total
    total += 1
    if ok:
        print("ok    " + label)
    else:
        fails.append(label)
        print("FAIL  %s   %s" % (label, detail))


def wav_samples(path):
    with wave.open(path, "rb") as w:
        sw, raw = w.getsampwidth(), w.readframes(w.getnframes())
    if sw == 2:
        a = array.array("h"); a.frombytes(raw)
        return [v / 32768.0 for v in a]
    if sw == 3:
        return [int.from_bytes(raw[i:i + 3], "little", signed=True) / 8388608.0
                for i in range(0, len(raw) - 2, 3)]
    raise RuntimeError("unexpected sample width %d" % sw)


def wav_rms(path):
    s = wav_samples(path)
    return math.sqrt(sum(v * v for v in s) / len(s)) if s else 0.0


try:
    with ObjekatClient(SOCK) as c:
        def cmd(_name, **params):
            return c.send(_name, params or None)

        def refused(_name, **params):
            try:
                c.send(_name, params or None)
                return None
            except ObjekatError as e:
                return e.code

        def idle():
            cmd("wait_idle", timeout_ms=30000)

        has_audit = refused("debug.plugin_id_audit") is None

        def audit_clean(phase):
            if not has_audit:
                return
            a = cmd("debug.plugin_id_audit")
            check("no duplicated plugin id %s" % phase,
                  a["count"] == 0 and a["engine_foreign_refusals"] == 0, str(a))

        def depth():
            return cmd("perf.census")["undo_depth"]

        info = cmd("app.info")
        check("--no-recent honoured", info.get("records_recent_projects") is False)
        cmd("app.set_dialog_policy", policy="assume_yes")

        def add(host, ident):
            return cmd("plugin.add", host=host, identifier=ident, format="TracktionInternal")["plugin"]["id"]

        def chain(host):
            return cmd("plugin.list", host=host)["plugins"]

        def blocks(host):
            return [p for p in chain(host) if p.get("is_fx_block")]

        def block_of(host, link=None):
            return next(p for p in blocks(host) if link is None or p["link"] == link)

        def inst_ids(host, link=None):
            return [p["id"] for p in block_of(host, link)["plugins"]]

        def idents(host, link=None):
            return [p["identifier"] for p in block_of(host, link)["plugins"]]

        def defs(link):
            return [d["id"] for d in cmd("fxlink.get", link=link)["plugins"]]

        def def_idents(link):
            return [d["identifier"] for d in cmd("fxlink.get", link=link)["plugins"]]

        def param(plugin, index):
            return cmd("plugin.get_params", plugin=plugin)["params"][index]["value"]

        def member(link, host):
            return next((m for m in cmd("fxlink.get", link=link)["members"] if m["host"] == host), None)

        def member_hosts(link):
            return {m["host"] for m in cmd("fxlink.get", link=link)["members"]}

        def drop(**kw):
            return cmd("plugin.drop", **kw)

        def drop_at(**kw):
            return cmd("plugin.drop_at", **kw)

        def dry(**kw):
            return cmd("plugin.drop_at", dry_run=True, **kw)

        def obj(lane):
            return cmd("object.add", path=BIP, lane=lane, start=0)["id"]

        WET = 2     # reverb 'Wet Level'

        # ═════════════════════════════════════════════════════════════════
        # D1 / D2 — a bin's BLOCK onto another object
        # ═════════════════════════════════════════════════════════════════
        cmd("project.new")
        A, B, C = obj(0), obj(1), obj(2)
        eqA, revA, tail = add(A, "4bandEq"), add(A, "reverb"), add(A, "chorus")
        chB = add(B, "compressor")
        LID = cmd("fxlink.create", host=A, plugins=[eqA, revA], name="Bin")["id"]
        cmd("fxlink.attach", link=LID, host=C); idle()
        blockA = block_of(A)["id"]
        old_ids = inst_ids(A)

        d = dry(**{"from": A, "plugin": blockA, "host": B})
        check("D1 dry run: the block onto an object that lacks the bin is a move_block",
              d["outcome"] == "move_block" and d["refused"] is False and d["placed"] is False, str(d))
        check("D1 ...and a dry run changes nothing",
              len(blocks(B)) == 0 and len(blocks(A)) == 1 and member_hosts(LID) == {A, C})

        d0 = depth()
        r = drop(**{"from": A, "plugin": blockA, "to": B})
        idle()
        check("D1 the block dropped on B is a move_block, placed", r["outcome"] == "move_block" and r["placed"], str(r))
        check("D1 B follows the bin now, attached", member(LID, B) is not None and member(LID, B)["detached"] is False)
        check("D1 ...A lost its block (the tail stays)", len(blocks(A)) == 0 and [p["id"] for p in chain(A)] == [tail])
        check("D1 ...C, untouched, still follows", member(LID, C) is not None)
        check("D1 B's chain keeps its own plugin and gains the block",
              [p.get("is_fx_block", False) for p in chain(B)] == [False, True] and chain(B)[0]["id"] == chB,
              str([(p["name"], p.get("is_fx_block")) for p in chain(B)]))
        check("D1 B's instances are its OWN (never A's ids)",
              len(inst_ids(B)) == 2 and not set(inst_ids(B)) & set(old_ids))
        check("D1 ONE undo point for the whole gesture", depth() == d0 + 1, "%s -> %s" % (d0, depth()))
        rb = [p for p in block_of(B)["plugins"] if p["identifier"] == "reverb"][0]["id"]
        rc = [p for p in block_of(C)["plugins"] if p["identifier"] == "reverb"][0]["id"]
        cmd("plugin.set_param", plugin=rc, index=WET, value=0.8); idle()
        check("D1 the mirror holds across the new member", abs(param(rb, WET) - 0.8) < 1e-3, "%s" % param(rb, WET))
        audit_clean("after D1 (block moved)")

        cmd("edit.undo"); idle()
        check("D1 ONE undo gives A its block back and B none",
              len(blocks(A)) == 1 and len(blocks(B)) == 0 and member_hosts(LID) == {A, C}
              and inst_ids(A) == old_ids, str(member_hosts(LID)))
        cmd("edit.redo"); idle()
        check("D1 redo moves it again", len(blocks(A)) == 0 and len(blocks(B)) == 1)
        cmd("edit.undo"); idle()
        audit_clean("after D1 undo / redo / undo")

        # D2 — ⌥ : the copy stays on the same bin
        d0 = depth()
        r = drop(**{"from": A, "plugin": blockA, "to": B, "mode": "copy"})
        idle()
        check("D2 ⌥ on the header: a copy_block, placed", r["outcome"] == "copy_block" and r["placed"], str(r))
        check("D2 the source keeps its block (and its ids), the target joined the SAME bin",
              len(blocks(A)) == 1 and inst_ids(A) == old_ids and member_hosts(LID) == {A, B, C}
              and block_of(B)["link"] == LID)
        check("D2 ONE undo point", depth() == d0 + 1)
        ra = [p for p in block_of(A)["plugins"] if p["identifier"] == "reverb"][0]["id"]
        rb = [p for p in block_of(B)["plugins"] if p["identifier"] == "reverb"][0]["id"]
        cmd("plugin.set_param", plugin=ra, index=WET, value=0.35); idle()
        check("D2 the copy is a LINK: A's parameter reaches B", abs(param(rb, WET) - 0.35) < 1e-3)
        check("D2 ⌘ is a copy too (same bin), and is refused where B already holds it",
              dry(**{"from": A, "plugin": blockA, "host": B, "mode": "link"})["refused"] is True)
        cmd("edit.undo"); idle()
        check("D2 ONE undo takes B's block away, A untouched",
              member_hosts(LID) == {A, C} and inst_ids(A) == old_ids)
        audit_clean("after D2")

        # ═════════════════════════════════════════════════════════════════
        # D3 — a DETACHED block travels as it is
        # ═════════════════════════════════════════════════════════════════
        cmd("fxlink.detach", host=C, link=LID); idle()
        cmd("fxlink.set_local_output", host=C, link=LID, gain_db=-6.0, pan=0.5); idle()
        c_ids = inst_ids(C)
        blockC = block_of(C)["id"]
        D = obj(3)
        d0 = depth()
        r = drop(**{"from": C, "plugin": blockC, "to": D})
        idle()
        check("D3 a detached block dropped on D is a move_block", r["outcome"] == "move_block" and r["placed"], str(r))
        mD = member(LID, D)
        check("D3 D holds it DETACHED, with the source's own output section",
              mD is not None and mD["detached"] is True and abs(mD["local"]["gain_db"] + 6.0) < 1e-6
              and abs(mD["local"]["pan"] - 0.5) < 1e-6, str(mD))
        check("D3 C lost its block", len(blocks(C)) == 0 and member(LID, C) is None)
        check("D3 D's instances are fresh ids", len(inst_ids(D)) == 2 and not set(inst_ids(D)) & set(c_ids))
        check("D3 ONE undo point", depth() == d0 + 1)
        cmd("edit.undo"); idle()
        check("D3 ONE undo gives C its detached block back",
              member(LID, C) is not None and member(LID, C)["detached"] is True and member(LID, D) is None)
        E = obj(4)
        r = drop(**{"from": C, "plugin": blockC, "to": E, "mode": "copy"})
        idle()
        check("D3 a COPY of a detached block makes the target join the bin, attached",
              r["outcome"] == "copy_block" and member(LID, E) is not None and member(LID, E)["detached"] is False
              and member(LID, C) is not None, str(r))
        cmd("edit.undo"); idle()
        cmd("fxlink.reattach", host=C, link=LID); idle()
        audit_clean("after D3")

        # ═════════════════════════════════════════════════════════════════
        # D4 — refusals: said by the dry run, nothing touched
        # ═════════════════════════════════════════════════════════════════
        cmd("fxlink.attach", link=LID, host=B); idle()
        blockA = block_of(A)["id"]
        d = dry(**{"from": A, "plugin": blockA, "host": B})
        check("D4 the target already holds the bin: refused, with a reason",
              d["refused"] is True and d["outcome"] == "refuse" and "already holds" in d.get("reason", ""), str(d))
        d = dry(**{"from": A, "plugin": blockA, "host": A})
        check("D4 onto its own host (no place): refused", d["refused"] is True, str(d))
        F = obj(5)
        fp = add(F, "chorus")
        L2 = cmd("fxlink.create", host=F, plugins=[fp], name="Other")["id"]
        block_F = block_of(F)["id"]
        d = dry(**{"from": A, "plugin": blockA, "host": F, "series": {"block": block_F}})
        check("D4 a bin does not hold a bin: refused", d["refused"] is True and "bin" in d.get("reason", ""), str(d))
        before = (depth(), [p["id"] for p in chain(F)], member_hosts(LID))
        r = drop_at(**{"from": A, "plugin": blockA, "host": B})
        check("D4 a refused drop places nothing, pushes no undo point, changes no chain",
              r["placed"] is False and r["refused"] is True
              and (depth(), [p["id"] for p in chain(F)], member_hosts(LID)) == before, str(r))
        check("D4 an unknown place is refused as such",
              refused("plugin.drop_at", **{"from": A, "plugin": blockA, "host": F,
                                           "series": {"block": "00000000-0000-0000-0000-000000000000"}}) == "not_found")
        audit_clean("after D4")

        # ═════════════════════════════════════════════════════════════════
        # D5 / D6 / D7 — plugins INTO a bin
        # ═════════════════════════════════════════════════════════════════
        cmd("fxlink.remove_block", host=F, link=L2); idle()
        cmd("fxlink.remove_block", host=B, link=LID); idle()
        blockA = block_of(A)["id"]
        n_def = len(defs(LID))
        d = dry(**{"from": A, "plugin": tail, "host": A, "series": {"block": blockA}, "at": 1})
        check("D5 a plain plugin of the SAME host into the bin: adopt_into_bin", d["outcome"] == "adopt_into_bin", str(d))
        d0 = depth()
        r = drop_at(**{"from": A, "plugin": tail, "host": A, "series": {"block": blockA}, "at": 1})
        idle()
        check("D5 placed, one undo point", r["placed"] is True and depth() == d0 + 1, str(r))
        check("D5 the definition gained it at the place, in order",
              def_idents(LID) == ["4bandEq", "chorus", "reverb"], str(def_idents(LID)))
        check("D5 ...A's chain is the block alone, the plugin KEPT its id",
              [p.get("is_fx_block", False) for p in chain(A)] == [True] and inst_ids(A)[1] == tail,
              str(inst_ids(A)))
        check("D5 ...and it is linked to the definition",
              block_of(A)["plugins"][1].get("link_group") == defs(LID)[1])
        check("D5 every other member got an instance of it",
              all(idents(h) == ["4bandEq", "chorus", "reverb"] for h in (A, C)), str(idents(C)))
        audit_clean("after D5 (same host)")
        cmd("edit.undo"); idle()
        check("D5 ONE undo puts it back outside, same id, bin back to its size",
              len(defs(LID)) == n_def and [p["id"] for p in chain(A)][-1] == tail and len(blocks(A)) == 1,
              str([p["name"] for p in chain(A)]))

        # another host's plain plugin
        G = obj(6)
        gG = add(G, "compressor")
        d0 = depth()
        r = drop_at(**{"from": G, "plugin": gG, "host": A, "series": {"block": blockA}})
        idle()
        check("D5 a plugin of ANOTHER host dropped in the bin (end): adopt_into_bin, placed",
              r["outcome"] == "adopt_into_bin" and r["placed"] is True, str(r))
        check("D5 ...it left G, joined the definition at the end, one undo point",
              len(chain(G)) == 0 and def_idents(LID)[-1] == "compressor" and depth() == d0 + 1)
        check("D5 ...and its instance on A has a fresh id, every member has one",
              gG not in inst_ids(A) and all(idents(h)[-1] == "compressor" for h in (A, C)))
        audit_clean("after D5 (another host)")
        cmd("edit.undo"); idle()
        check("D5 ONE undo gives it back to G and takes it out of the bin",
              [p["id"] for p in chain(G)] == [gG] or [p["identifier"] for p in chain(G)] == ["compressor"])
        check("D5 ...bin back to its size", len(defs(LID)) == n_def and all(len(inst_ids(h)) == n_def for h in (A, C)))

        # D6 — ⌥ : an independent copy
        d0 = depth()
        r = drop_at(**{"from": A, "plugin": tail, "host": A, "series": {"block": blockA}, "mode": "copy"})
        idle()
        check("D6 ⌥ into the bin: copy_into_bin, placed", r["outcome"] == "copy_into_bin" and r["placed"], str(r))
        check("D6 the source is untouched (still outside, same id), the bin has one more",
              [p["id"] for p in chain(A)][-1] == tail and len(defs(LID)) == n_def + 1
              and all(len(inst_ids(h)) == n_def + 1 for h in (A, C)))
        check("D6 the copy is independent: its instance is not the source's and carries no link to it",
              tail not in inst_ids(A) and not [p for p in chain(A) if p["id"] == tail][0]["linked"])
        check("D6 ONE undo point", depth() == d0 + 1)
        cmd("edit.undo"); idle()
        check("D6 ONE undo takes the copy out everywhere", len(defs(LID)) == n_def and len(inst_ids(C)) == n_def)

        # D7 — ⌘
        d = dry(**{"from": A, "plugin": tail, "host": A, "series": {"block": blockA}, "mode": "link"})
        check("D7 ⌘ into a bin is refused", d["refused"] is True, str(d))
        d = dry(**{"from": G, "plugin": gG, "host": A, "series": {"block": blockA}, "mode": "link"})
        check("D7 ...from another host too", d["refused"] is True, str(d))
        audit_clean("after D6 / D7")

        # ═════════════════════════════════════════════════════════════════
        # D8 — an instance OUT of its bin
        # ═════════════════════════════════════════════════════════════════
        cmd("plugin.set_param", plugin=revA, index=WET, value=0.7); idle()
        n_def = len(defs(LID))
        d = dry(**{"from": A, "plugin": revA, "host": A, "series": "root", "at": 0})
        check("D8 an instance let go outside its bin (same host): extract_from_bin", d["outcome"] == "extract_from_bin", str(d))
        d0 = depth()
        r = drop_at(**{"from": A, "plugin": revA, "host": A, "series": "root", "at": 0})
        idle()
        check("D8 placed, ONE undo point", r["placed"] is True and depth() == d0 + 1, str(r))
        check("D8 the plugin left the bin for EVERY member", len(defs(LID)) == n_def - 1
              and all(len(inst_ids(h)) == n_def - 1 for h in (A, C)))
        out = chain(A)[0]
        check("D8 ...and stays on A as a PLAIN plugin: same id, no link, at the place",
              out["id"] == revA and out["linked"] is False and "link_group" not in out and not out.get("is_fx_block"),
              str(out))
        check("D8 ...with its live state (the parameter set before)", abs(param(revA, WET) - 0.7) < 1e-3)
        audit_clean("after D8 (extracted)")
        cmd("edit.undo"); idle()
        check("D8 ONE undo puts it back in the bin everywhere",
              len(defs(LID)) == n_def and revA in inst_ids(A) and all(len(inst_ids(h)) == n_def for h in (A, C))
              and not [p for p in chain(A) if p["id"] == revA])
        r = drop_at(**{"from": A, "plugin": revA, "host": A, "series": "root", "at": 0, "mode": "copy"})
        idle()
        check("D8 ⌥ takes an independent COPY and leaves the bin alone",
              r["outcome"] == "copy" and r["placed"] and len(defs(LID)) == n_def and revA in inst_ids(A)
              and chain(A)[0]["id"] != revA and chain(A)[0]["linked"] is False, str(r))
        cmd("edit.undo"); idle()
        check("D8 ⌘ is refused", dry(**{"from": A, "plugin": revA, "host": A, "series": "root", "mode": "link"})["refused"])
        # reordering inside the own bin is still a reorder of the definition, for everyone
        d0 = depth()
        r = drop_at(**{"from": A, "plugin": inst_ids(A)[0], "host": A,
                       "series": {"block": block_of(A)["id"]}, "at": n_def})
        idle()
        check("D8 a drop inside its OWN bin reorders the definition (move)", r["outcome"] == "move" and r["placed"], str(r))
        check("D8 ...for every member, one undo point",
              idents(A) == idents(C) and depth() == d0 + 1, "%s / %s" % (idents(A), idents(C)))
        cmd("edit.undo"); idle()
        audit_clean("after D8")

        # ═════════════════════════════════════════════════════════════════
        # D9 — an instance onto ANOTHER host
        # ═════════════════════════════════════════════════════════════════
        H = obj(7)
        d = dry(**{"from": A, "plugin": revA, "host": H})
        check("D9 a move of an instance onto another host is refused (it would empty the bin here)",
              d["refused"] is True, str(d))
        r = drop(**{"from": A, "plugin": revA, "to": H, "mode": "copy"})
        idle()
        check("D9 ⌥ copies it: an independent plugin on H", r["outcome"] == "copy" and r["placed"]
              and len(chain(H)) == 1 and chain(H)[0]["linked"] is False and not chain(H)[0].get("is_fx_block"), str(r))
        check("D9 ...the bin is untouched", len(defs(LID)) == n_def and revA in inst_ids(A))
        cmd("edit.undo"); idle()
        r = drop(**{"from": A, "plugin": revA, "to": H, "mode": "link"})
        idle()
        check("D9 ⌘ makes H JOIN the bin (the whole bin, not the one plugin)",
              r["outcome"] == "join_bin" and r["placed"] and member(LID, H) is not None
              and len(inst_ids(H)) == n_def, str(r))
        cmd("edit.undo"); idle()
        check("D9 ONE undo takes H out again", member(LID, H) is None and len(chain(H)) == 0)
        audit_clean("after D9")

        # ═════════════════════════════════════════════════════════════════
        # D10 — a BUS receives like an object
        # ═════════════════════════════════════════════════════════════════
        STEM = cmd("stem.add", name="Voice", format="stereo")["id"]
        d0 = depth()
        r = drop(**{"from": A, "plugin": block_of(A)["id"], "to": STEM, "mode": "copy"})
        idle()
        check("D10 a block copied onto a bus: the bus joins the bin",
              r["outcome"] == "copy_block" and r["placed"] and member(LID, STEM) is not None
              and cmd("plugin.list", host=STEM)["is_stem"] and depth() == d0 + 1, str(r))
        check("D10 ...and the bus holds its OWN instances", not set(inst_ids(STEM)) & set(inst_ids(A)))
        sr = [p for p in block_of(STEM)["plugins"] if p["identifier"] == "reverb"][0]["id"]
        cmd("plugin.set_param", plugin=revA, index=WET, value=0.45); idle()
        check("D10 ...mirrored like an object", abs(param(sr, WET) - 0.45) < 1e-3, "%s" % param(sr, WET))
        r = drop(**{"from": A, "plugin": block_of(A)["id"], "to": STEM})
        check("D10 a second drop on the bus is refused (it holds the bin)", r["placed"] is False and r["refused"])
        cmd("fxlink.remove_block", host=STEM, link=LID); idle()
        # a bus's block moved onto an object (the bus is the SOURCE)
        cmd("fxlink.attach", link=LID, host=STEM); idle()
        K = obj(8)
        r = drop(**{"from": STEM, "plugin": block_of(STEM)["id"], "to": K})
        idle()
        check("D10 a bus's block moved onto an object: the object joins, the bus loses it",
              r["outcome"] == "move_block" and member(LID, K) is not None and member(LID, STEM) is None, str(r))
        audit_clean("after D10")

        # ═════════════════════════════════════════════════════════════════
        # D11 — save / reopen
        # ═════════════════════════════════════════════════════════════════
        drop_at(**{"from": A, "plugin": tail, "host": A, "series": {"block": block_of(A)["id"]}, "at": 1}); idle()
        before = cmd("fxlink.get", link=LID)
        proj = os.path.join(TMP, "p.objekat")
        cmd("project.save_as", path=proj); idle()
        cmd("project.new")
        check("D11 a new project has no bin", cmd("fxlink.list")["count"] == 0)
        cmd("project.open", path=proj); idle()
        after = cmd("fxlink.list")
        g = next(x for x in after["links"] if x["id"] == LID)
        check("D11 the bin is back with its definition and every member",
              [d["identifier"] for d in g["plugins"]] == [d["identifier"] for d in before["plugins"]]
              and {m["host"] for m in g["members"]} == {m["host"] for m in before["members"]}, str(g))
        a2 = next(m for m in g["members"] if not m["detached"])
        rr = [i for i in a2["instances"] if i["name"] == "Reverb"][0]["id"]
        others = [next(i for i in m["instances"] if i["name"] == "Reverb")["id"]
                  for m in g["members"] if not m["detached"] and m is not a2]
        cmd("plugin.set_param", plugin=rr, index=WET, value=0.52); idle()
        check("D11 the mirror survives the reopen",
              others and all(abs(param(o, WET) - 0.52) < 1e-3 for o in others), "%s" % others)
        audit_clean("after D11 (save / reopen)")

        # ═════════════════════════════════════════════════════════════════
        # D12 — the ENGINE followed: export re-read at RMS (24 bit)
        # ═════════════════════════════════════════════════════════════════
        cmd("project.new")
        X, Y = obj(0), obj(1)
        eqX = add(X, "4bandEq")
        LX = cmd("fxlink.create", host=X, plugins=[eqX])["id"]
        cmd("fxlink.set_output", link=LX, gain_db=-20.0)
        cmd("object.set_mute", ids=[X], muted=True)
        idle()

        def render(name):
            out = os.path.join(TMP, name)
            r = cmd("export.run", format="wav", sample_rate=44100, bit_depth=24, dithering=False,
                    start=0.0, end=0.6, path=out)
            cmd("job.wait", id=r["job_id"], timeout_ms=60000)
            return wav_rms(out)

        r0 = render("plain_Y.wav")
        check("D12 Y alone, with no bin, plays at unity", r0 > 0.01, "%s" % r0)
        drop(**{"from": X, "plugin": block_of(X)["id"], "to": Y}); idle()
        r1 = render("Y_after_move.wav")
        check("D12 after the block moved onto Y, Y plays the bin's output section (-20 dB, RMS)",
              abs(r1 / r0 - 0.1) < 0.02, "%s / %s" % (r1, r0))
        cmd("edit.undo"); idle()
        r2 = render("Y_after_undo.wav")
        check("D12 ONE undo: the engine gives Y its unity back", abs(r2 / r0 - 1.0) < 0.03, "%s / %s" % (r2, r0))
        cmd("edit.redo"); idle()
        r3 = render("Y_after_redo.wav")
        check("D12 redo: the bin is heard again", abs(r3 / r0 - 0.1) < 0.02, "%s / %s" % (r3, r0))
        audit_clean("after D12")

finally:
    shutil.rmtree(TMP, ignore_errors=True)

print()
print("%d checks, %d failed" % (total, len(fails)))
for f in fails:
    print("  FAILED: " + f)
sys.exit(1 if fails else 0)

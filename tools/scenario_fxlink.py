#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""FX links (bins of shared plugins) — a scenario that ASSERTS rather than replaying.

    # 1. launch the app with the API, on a SHORT socket (a system limit: 103 bytes).
    #    `--no-recent`: the throwaway project below does not enter "Recent projects".
    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --socket=/tmp/o.sock

    # 2. run
    ./scenario_fxlink.py /tmp/o.sock

What it is really out to prove, beyond the commands answering:

  • the members' instances MIRROR the bin: a parameter set on one host's instance arrives on the
    other's, and an instance keeps its id (a live plugin is never reloaded by an edit of the bin);
  • the DEFINITION rules: order, membership and on/off edited once reach every attached member,
    and a gesture aimed at a member's instance (`plugin.toggle`, `plugin.remove`) is a gesture on
    the definition;
  • DETACHING makes an independent copy (nothing propagates either way any more) and REATTACHING
    realigns the host on the bin — order, membership, output section, parameters;
  • ONE undo point per gesture, the registry restoring together with the chains;
  • the bin survives a save and a reopen, mirrors included;
  • and the half only an export can settle — the ENGINE followed, not just the model: the output
    section (volume, mute, common on/off) is heard, per member, detached or not.

Exit: 0 if every assertion passes, 1 otherwise.
"""

import array, os, shutil, sys, tempfile, wave

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

if len(sys.argv) != 2:
    print(__doc__)
    sys.exit(2)

SOCK = sys.argv[1]
BIP = os.path.join(HERE, "fixtures", "bip.wav")
TMP = tempfile.mkdtemp(prefix="fxlink_")

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


def wav_peak(path):
    with wave.open(path, "rb") as w:
        sw, raw = w.getsampwidth(), w.readframes(w.getnframes())
    if sw == 2:
        a = array.array("h"); a.frombytes(raw)
        return max(abs(v) for v in a) / 32768.0 if len(a) else 0.0
    if sw == 3:
        peak = 0
        for i in range(0, len(raw) - 2, 3):
            v = abs(int.from_bytes(raw[i:i + 3], "little", signed=True))
            peak = max(peak, v)
        return peak / 8388608.0
    raise RuntimeError("unexpected sample width %d" % sw)


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

        info = cmd("app.info")
        check("--no-recent honoured", info.get("records_recent_projects") is False)
        cmd("app.set_dialog_policy", policy="assume_yes")
        cmd("project.new")
        check("a fresh project has no bin", cmd("fxlink.list")["count"] == 0)

        def add(host, ident):
            return cmd("plugin.add", host=host, identifier=ident, format="TracktionInternal")["plugin"]["id"]

        def chain(host):
            return cmd("plugin.list", host=host)["plugins"]

        def block_of(host):
            return next(p for p in chain(host) if p.get("is_fx_block"))

        def inst_ids(host):
            return [p["id"] for p in block_of(host)["plugins"]]

        def defs(link):
            return [d["id"] for d in cmd("fxlink.get", link=link)["plugins"]]

        def param(plugin, index):
            return cmd("plugin.get_params", plugin=plugin)["params"][index]["value"]

        def member(link, host):
            return next(m for m in cmd("fxlink.get", link=link)["members"] if m["host"] == host)

        A = cmd("object.add", path=BIP, lane=0, start=0)["id"]
        B = cmd("object.add", path=BIP, lane=1, start=0)["id"]
        C = cmd("object.add", path=BIP, lane=2, start=0)["id"]
        eqA = add(A, "4bandEq")
        revA = add(A, "reverb")
        tail = add(A, "chorus")                     # stays OUTSIDE the bin, after it

        # ── creation ────────────────────────────────────────────────────────
        L = cmd("fxlink.create", host=A, plugins=[eqA, revA], name="Bin")
        LID = L["id"]
        check("the bin carries the chosen name", L["name"] == "Bin")
        check("its definition holds the two plugins, in order",
              [d["identifier"] for d in L["plugins"]] == ["4bandEq", "reverb"])
        ch = chain(A)
        check("the chain is now [block, chorus]",
              [p.get("is_fx_block", False) for p in ch] == [True, False] and ch[1]["id"] == tail,
              str([(p["name"], p.get("is_fx_block")) for p in ch]))
        check("the host's instances KEEP their ids (nothing reloaded)", inst_ids(A) == [eqA, revA])
        check("each instance names its definition plugin",
              [p["link_group"] for p in block_of(A)["plugins"]] == defs(LID))
        check("the host is a member", member(LID, A)["detached"] is False)

        # refusals
        check("a plugin already in a bin cannot enter another",
              refused("fxlink.create", host=A, plugins=[eqA]) == "invalid_state")
        check("an unknown host is refused", refused("fxlink.create", host="00000000-0000-0000-0000-000000000000",
                                                    plugins=[eqA]) == "not_found")

        # ── attaching, and the mirror ───────────────────────────────────────
        cmd("fxlink.attach", link=LID, host=B)
        idle()
        check("B holds a block of the bin", len(cmd("fxlink.get", link=LID)["members"]) == 2)
        bi = inst_ids(B)
        check("B's instances are its OWN (ids differ from A's)",
              len(bi) == 2 and not set(bi) & set(inst_ids(A)))
        check("B's block is in B's chain, alone", len(chain(B)) == 1 and chain(B)[0].get("is_fx_block"))

        WET = 2     # reverb 'Wet Level'
        v0 = param(bi[1], WET)
        cmd("plugin.set_param", plugin=revA, index=WET, value=0.8)
        idle()
        check("a parameter set on A arrives on B", abs(param(bi[1], WET) - 0.8) < 1e-3,
              "%s" % param(bi[1], WET))
        cmd("plugin.set_param", plugin=bi[1], index=WET, value=0.15)
        idle()
        check("and the other way round", abs(param(revA, WET) - 0.15) < 1e-3, "%s" % param(revA, WET))

        cmd("fxlink.attach", link=LID, host=C)
        idle()
        ci = inst_ids(C)
        check("a NEW member is born with the bin's current state",
              abs(param(ci[1], WET) - 0.15) < 1e-3, "%s" % param(ci[1], WET))
        check("attaching twice changes nothing", len(cmd("fxlink.get", link=LID)["members"]) == 3
              and refused("fxlink.attach", link=LID, host=C) is None
              and len(cmd("fxlink.get", link=LID)["members"]) == 3)

        # ── the definition rules ────────────────────────────────────────────
        d_eq, d_rev = defs(LID)
        cmd("fxlink.move_plugin", link=LID, plugin=d_eq, index=1)
        idle()
        check("reordering the definition reorders EVERY member",
              defs(LID) == [d_rev, d_eq]
              and [p["identifier"] for p in block_of(A)["plugins"]] == ["reverb", "4bandEq"]
              and [p["identifier"] for p in block_of(B)["plugins"]] == ["reverb", "4bandEq"]
              and [p["identifier"] for p in block_of(C)["plugins"]] == ["reverb", "4bandEq"])
        check("and the instances keep their ids through it",
              inst_ids(A) == [revA, eqA] and inst_ids(B) == [bi[1], bi[0]])
        check("the mirror still holds after a reorder", (
            cmd("plugin.set_param", plugin=revA, index=WET, value=0.6),
            idle(), abs(param(bi[1], WET) - 0.6) < 1e-3)[2])

        cmd("edit.undo"); idle()
        check("ONE undo puts the order back everywhere",
              defs(LID) == [d_eq, d_rev] and inst_ids(A) == [eqA, revA])
        # the set_param above went through the mirror without an undo point: only the move undid.
        cmd("edit.redo"); idle()
        check("redo restores it", defs(LID) == [d_rev, d_eq])
        cmd("fxlink.move_plugin", link=LID, plugin=d_eq, index=0); idle()

        # on/off: the definition's, hot, and a gesture on an instance IS a gesture on it
        cmd("fxlink.set_plugin_enabled", link=LID, plugin=d_rev, enabled=False)
        check("bypassing a definition plugin bypasses every member's instance",
              all(not next(p for p in block_of(h)["plugins"] if p["link_group"] == d_rev)["enabled"]
                  for h in (A, B, C)))
        cmd("edit.undo")
        check("ONE undo brings it back", all(p["enabled"] for p in block_of(B)["plugins"]))
        cmd("plugin.toggle", host=B, plugin=bi[1])
        check("plugin.toggle on a member's instance reaches the definition and the other members",
              not next(d for d in cmd("fxlink.get", link=LID)["plugins"] if d["id"] == d_rev)["enabled"]
              and not next(p for p in block_of(A)["plugins"] if p["link_group"] == d_rev)["enabled"])
        cmd("edit.undo")

        # adding to the definition
        r = cmd("fxlink.add_plugin", link=LID, identifier="compressor", format="TracktionInternal")
        d_comp = r["definition"]
        idle()
        check("a plugin added to the bin reaches every member",
              all(len(block_of(h)["plugins"]) == 3 for h in (A, B, C))
              and all(block_of(h)["plugins"][-1]["identifier"] == "compressor" for h in (A, B, C)))
        check("...with no id of an existing instance disturbed", inst_ids(A)[:2] == [eqA, revA])
        cmd("plugin.remove", host=C, plugin=inst_ids(C)[2])
        idle()
        check("plugin.remove on a member's instance removes it from the bin, everywhere",
              d_comp not in defs(LID) and all(len(block_of(h)["plugins"]) == 2 for h in (A, B, C)))
        cmd("edit.undo"); idle()
        check("and ONE undo brings it back everywhere",
              d_comp in defs(LID) and all(len(block_of(h)["plugins"]) == 3 for h in (A, B, C)))
        cmd("fxlink.remove_plugin", link=LID, plugin=d_comp); idle()

        # a bin that is off is off everywhere
        cmd("fxlink.set_enabled", link=LID, enabled=False)
        check("the common on/off is the bin's", cmd("fxlink.get", link=LID)["enabled"] is False)
        cmd("edit.undo")
        check("and it is undoable", cmd("fxlink.get", link=LID)["enabled"] is True)

        # ── detaching: an independent copy ─────────────────────────────────
        cmd("plugin.set_param", plugin=revA, index=WET, value=0.5); idle()
        cmd("fxlink.detach", host=B, link=LID)
        idle()
        check("B is detached", member(LID, B)["detached"] is True)
        check("A and C still follow", member(LID, A)["detached"] is False and member(LID, C)["detached"] is False)
        check("B keeps its instances, same ids", set(inst_ids(B)) == set(bi))
        cmd("plugin.set_param", plugin=revA, index=WET, value=0.9); idle()
        cbi = next(p for p in block_of(B)["plugins"] if p["identifier"] == "reverb")["id"]
        check("a change in the bin no longer reaches the detached copy",
              abs(param(cbi, WET) - 0.5) < 1e-3, "%s" % param(cbi, WET))
        cmd("plugin.set_param", plugin=cbi, index=WET, value=0.2); idle()
        check("and the copy's change does not reach the bin", abs(param(revA, WET) - 0.9) < 1e-3)
        check("...while C, a member, still follows A",
              abs(param(next(p for p in block_of(C)["plugins"] if p["identifier"] == "reverb")["id"], WET) - 0.9) < 1e-3)
        check("a detached block refuses the bin's output edit through set_local_output only",
              refused("fxlink.set_local_output", host=A, link=LID, gain_db=-3) == "invalid_state")

        # the definition is edited while B is away
        cmd("fxlink.move_plugin", link=LID, plugin=d_rev, index=0); idle()
        check("B, detached, does not follow the reorder (A: reverb first, B: unchanged)",
              [p["identifier"] for p in block_of(A)["plugins"]] == ["reverb", "4bandEq"]
              and [p["identifier"] for p in block_of(B)["plugins"]] == ["4bandEq", "reverb"],
              str([p["identifier"] for p in block_of(B)["plugins"]]))
        cmd("edit.undo"); idle()
        cmd("edit.undo"); idle()      # the detach itself... (the set_params are not undo points)
        check("undoing the detach reattaches B to the bin", member(LID, B)["detached"] is False, str(member(LID, B)))
        cmd("edit.redo"); idle()
        check("redo detaches it again", member(LID, B)["detached"] is True)

        # ── reattaching: the host realigns on the bin ──────────────────────
        cmd("fxlink.reattach", host=B, link=LID); idle()
        check("B follows again", member(LID, B)["detached"] is False)
        check("...and its order is the bin's",
              [p["identifier"] for p in block_of(B)["plugins"]] == [p["identifier"] for p in block_of(A)["plugins"]])
        rb = next(p for p in block_of(B)["plugins"] if p["identifier"] == "reverb")["id"]
        ra = next(p for p in block_of(A)["plugins"] if p["identifier"] == "reverb")["id"]
        check("...and it ADOPTED the group's settings (it aligns on the bin, not the reverse)",
              abs(param(rb, WET) - param(ra, WET)) < 1e-3 and abs(param(ra, WET) - 0.9) < 1e-3,
              "%s / %s" % (param(rb, WET), param(ra, WET)))
        cmd("plugin.set_param", plugin=ra, index=WET, value=0.33); idle()
        check("the mirror works again", abs(param(rb, WET) - 0.33) < 1e-3)

        # ── release / remove_block / delete ─────────────────────────────────
        cmd("fxlink.release", host=C, link=LID); idle()
        check("a released host keeps its plugins, inline and independent",
              [p["identifier"] for p in chain(C)] == [p["identifier"] for p in block_of(A)["plugins"]]
              and not any(p.get("is_fx_block") for p in chain(C)) and not any(p["linked"] for p in chain(C)))
        check("...and is no longer a member", len(cmd("fxlink.get", link=LID)["members"]) == 2)
        cmd("edit.undo"); idle()
        check("undo puts C back in the bin", len(cmd("fxlink.get", link=LID)["members"]) == 3)

        # a bin on a BUS
        STEM = cmd("stem.add", name="Voice", format="stereo")["id"]
        cmd("fxlink.attach", link=LID, host=STEM); idle()
        check("a bus can be a member", block_of(STEM)["link"] == LID and cmd("plugin.list", host=STEM)["is_stem"])
        sid = inst_ids(STEM)
        cmd("plugin.set_param", plugin=ra, index=WET, value=0.71); idle()
        srev = next(p for p in block_of(STEM)["plugins"] if p["identifier"] == "reverb")["id"]
        check("...and mirrors like an object", abs(param(srev, WET) - 0.71) < 1e-3, "%s" % param(srev, WET))
        cmd("fxlink.remove_block", host=STEM, link=LID); idle()
        check("remove_block drops the block and its instances only",
              not any(p.get("is_fx_block") for p in chain(STEM)) and len(cmd("fxlink.get", link=LID)["members"]) == 3)

        # ── save / reopen ───────────────────────────────────────────────────
        cmd("fxlink.set_output", link=LID, gain_db=-4.5, pan=0.25)
        cmd("fxlink.rename", link=LID, name="Bus FX")
        cmd("fxlink.detach", host=C, link=LID); idle()
        cmd("fxlink.set_local_output", host=C, link=LID, gain_db=-9.0, muted=True)
        before = cmd("fxlink.get", link=LID)
        proj = os.path.join(TMP, "p.objekat")
        cmd("project.save_as", path=proj); idle()
        cmd("project.new")
        check("a new project starts with no bin", cmd("fxlink.list")["count"] == 0)
        cmd("project.open", path=proj); idle()
        after = cmd("fxlink.list")
        check("the bin is back", after["count"] == 1)
        g = after["links"][0]
        check("...with its name, output and definition",
              g["name"] == "Bus FX" and abs(g["gain_db"] + 4.5) < 1e-6 and abs(g["pan"] - 0.25) < 1e-6
              and [d["identifier"] for d in g["plugins"]] == [d["identifier"] for d in before["plugins"]],
              str(g))
        check("...its three members, C detached",
              len(g["members"]) == 3 and sum(1 for m in g["members"] if m["detached"]) == 1)
        check("...and C's own output section",
              any(m.get("local", {}).get("muted") is True and abs(m["local"]["gain_db"] + 9.0) < 1e-6
                  for m in g["members"]))
        # the mirror was re-armed by the load
        a2 = next(m for m in g["members"] if not m["detached"])
        rr = [i for i in a2["instances"] if i["name"] == "Reverb"][0]["id"]
        others = [next(i for i in m["instances"] if i["name"] == "Reverb")["id"]
                  for m in g["members"] if not m["detached"] and m is not a2]
        cmd("plugin.set_param", plugin=rr, index=WET, value=0.44); idle()
        check("the mirror survives a save and a reopen",
              all(abs(param(o, WET) - 0.44) < 1e-3 for o in others) and others, "%s" % others)
        LID = g["id"]
        cmd("fxlink.reattach", link=LID, host=[m for m in g["members"] if m["detached"]][0]["host"]); idle()

        # delete
        cmd("fxlink.delete", link=LID); idle()
        check("deleting the bin leaves the plugins inline on every host",
              cmd("fxlink.list")["count"] == 0
              and all(not any(p.get("is_fx_block") for p in chain(h["id"])) for h in [{"id": A}, {"id": B}, {"id": C}]))
        cmd("edit.undo"); idle()
        check("...and ONE undo gives the bin back", cmd("fxlink.list")["count"] == 1)

        # ── AUTOMATIC creation: a copy of plain plugins joins a bin ───────
        cmd("project.new")
        D = cmd("object.add", path=BIP, lane=0, start=0)["id"]
        add(D, "4bandEq"); add(D, "reverb")
        check("plain plugins, no bin yet", cmd("fxlink.list")["count"] == 0
              and not any(p.get("is_fx_block") for p in chain(D)))

        def hosts_with_blocks():
            return [o["id"] for o in cmd("object.list")["objects"]
                    if any(p.get("is_fx_block") for p in chain(o["id"]))]

        def all_objects():
            return [o["id"] for o in cmd("object.list")["objects"]]

        # 1. a split
        r = cmd("object.split_at", ids=[D], seconds=0.3); idle()
        objs = all_objects()
        lst = cmd("fxlink.list")
        check("a split makes ONE bin", lst["count"] == 1, str(lst["count"]))
        check("...both halves carry its block (the ORIGINAL included)",
              len(objs) == 2 and sorted(hosts_with_blocks()) == sorted(objs), "%s / %s" % (objs, hosts_with_blocks()))
        check("...and the bin has both as attached members",
              len(lst["links"][0]["members"]) == 2 and not any(m["detached"] for m in lst["links"][0]["members"]))
        H1, H2 = objs
        w1 = [i for i in inst_ids(H1)]
        w2 = [i for i in inst_ids(H2)]
        check("...with as many instances as the definition, in its order, ids all distinct",
              len(w1) == 2 and len(w2) == 2 and not set(w1) & set(w2))
        check("the plain plugins were CONVERTED: nothing is left beside the block, no manual link written",
              all(len(chain(h)) == 1 and chain(h)[0].get("is_fx_block") for h in (H1, H2)),
              str([chain(h) for h in (H1, H2)]))
        rv1 = [p for p in block_of(H1)["plugins"] if p["name"] == "Reverb"][0]["id"]
        rv2 = [p for p in block_of(H2)["plugins"] if p["name"] == "Reverb"][0]["id"]
        cmd("plugin.set_param", plugin=rv1, index=WET, value=0.77); idle()
        check("the halves MIRROR each other", abs(param(rv2, WET) - 0.77) < 1e-3, "%s" % param(rv2, WET))
        cmd("edit.undo"); idle()
        check("ONE undo takes the split, the bin and the block away",
              len(all_objects()) == 1 and cmd("fxlink.list")["count"] == 0
              and not any(p.get("is_fx_block") for p in chain(D)), "%s" % chain(D))

        # 2. a duplicate
        cmd("object.duplicate", ids=[D]); idle()
        objs = all_objects()
        lst = cmd("fxlink.list")
        check("a duplicate joins a bin with the original",
              len(objs) == 2 and lst["count"] == 1 and len(lst["links"][0]["members"]) == 2
              and sorted(hosts_with_blocks()) == sorted(objs))
        cmd("edit.undo"); idle()
        check("...and one undo brings the plain chain back",
              len(all_objects()) == 1 and cmd("fxlink.list")["count"] == 0
              and not any(p.get("is_fx_block") for p in chain(D)))

        # 3. copy / paste
        cmd("selection.set", ids=[D])
        cmd("clipboard.copy")
        cmd("caret.set", lane=2, time=0.0)      # elsewhere: a paste over the source would replace it
        cmd("clipboard.paste"); idle()
        objs = all_objects()
        lst = cmd("fxlink.list")
        check("a paste joins a bin with its source",
              len(objs) == 2 and lst["count"] == 1 and len(lst["links"][0]["members"]) == 2
              and sorted(hosts_with_blocks()) == sorted(objs), str(lst["count"]))
        # a second paste: a member of some bin, never a broken chain
        cmd("caret.set", lane=4, time=0.0)
        cmd("clipboard.paste"); idle()
        check("a second paste is a healthy member too (every host holds ONE block)",
              len(all_objects()) == 3
              and all(len(chain(h)) == 1 and chain(h)[0].get("is_fx_block") for h in all_objects()))
        cmd("edit.undo"); cmd("edit.undo"); idle()
        check("two undos give the plain chain back",
              len(all_objects()) == 1 and cmd("fxlink.list")["count"] == 0
              and not any(p.get("is_fx_block") for p in chain(D)))

        # 4. the automatic bin survives a save and a reopen
        cmd("project.new")
        D = cmd("object.add", path=BIP, lane=0, start=0)["id"]
        add(D, "4bandEq"); add(D, "reverb")
        cmd("object.split_at", ids=[D], seconds=0.3); idle()
        proj2 = os.path.join(TMP, "auto.objekat")
        cmd("project.save_as", path=proj2); idle()
        cmd("project.new")
        cmd("project.open", path=proj2); idle()
        lst = cmd("fxlink.list")
        check("the automatic bin survives a save and a reopen",
              lst["count"] == 1 and len(lst["links"][0]["members"]) == 2)

        # ── CROSS-PROJECT paste: the bin is recreated as a NEW one ────────
        cmd("project.new")
        cmd("tab.new"); idle()               # a tab switch keeps the clipboard, a new document does not
        cmd("tab.select", index=1); idle()
        S1 = cmd("object.add", path=BIP, lane=0, start=0)["id"]
        S2 = cmd("object.add", path=BIP, lane=1, start=0)["id"]
        se, sr_ = add(S1, "4bandEq"), add(S1, "reverb")
        SRC = cmd("fxlink.create", host=S1, plugins=[se, sr_], name="Src bin")["id"]
        cmd("fxlink.attach", link=SRC, host=S2)
        cmd("fxlink.set_output", link=SRC, gain_db=-6.0)
        cmd("selection.set", ids=[S1, S2])
        cmd("clipboard.copy")
        cmd("tab.select", index=2); idle()
        cmd("clipboard.paste"); idle()
        lst = cmd("fxlink.list")
        check("a cross-project paste makes ONE new bin in the target",
              lst["count"] == 1 and lst["links"][0]["id"] != SRC, str(lst["count"]))
        g = lst["links"][0]
        check("...named and set as the source's (name, volume), both pasted objects its members",
              g["name"] == "Src bin" and abs(g["gain_db"] + 6.0) < 1e-6 and len(g["members"]) == 2, str(g))
        ti = [next(i for i in m["instances"] if i["name"] == "Reverb")["id"] for m in g["members"]]
        cmd("plugin.set_param", plugin=ti[0], index=WET, value=0.66); idle()
        check("...and it mirrors", abs(param(ti[1], WET) - 0.66) < 1e-3, "%s" % param(ti[1], WET))
        cmd("tab.select", index=1); idle()
        src = cmd("fxlink.list")
        check("the source project keeps its own bin untouched",
              src["count"] == 1 and src["links"][0]["id"] == SRC and len(src["links"][0]["members"]) == 2)
        cmd("tab.close", index=2, discard=True); idle()

        # ── CONSOLIDATE: a bin inside is recreated as a NEW one on opening ─
        cmd("project.new")
        cproj = os.path.join(TMP, "consol.objekat")
        K1 = cmd("object.add", path=BIP, lane=0, start=0)["id"]
        K2 = cmd("object.add", path=BIP, lane=1, start=0)["id"]
        ke = add(K1, "4bandEq")
        KL = cmd("fxlink.create", host=K1, plugins=[ke], name="Inner")["id"]
        cmd("fxlink.attach", link=KL, host=K2)
        cmd("fxlink.set_output", link=KL, gain_db=-9.0)
        grp = cmd("group.create", ids=[K1, K2])["id"]
        cmd("project.save_as", path=cproj); idle()
        r = cmd("consolidate.make", id=grp)
        cmd("job.wait", id=r["job_id"], timeout_ms=120000); idle()
        check("consolidating leaves the timeline with an instance and no bin in sight",
              cmd("fxlink.list")["count"] == 0)
        cmd("consolidate.unmake", placement=grp); idle()
        lst = cmd("fxlink.list")
        check("unmaking gives the content back with a NEW bin (not the old id), both members",
              lst["count"] == 1 and lst["links"][0]["id"] != KL and len(lst["links"][0]["members"]) == 2, str(lst))
        check("...its output section carried through the sidecar (-9 dB)",
              abs(lst["links"][0]["gain_db"] + 9.0) < 1e-6, str(lst["links"][0]))
        check("...and its name",  lst["links"][0]["name"] == "Inner")

        # ── the ENGINE follows: an export re-read ──────────────────────────
        cmd("project.new")
        X = cmd("object.add", path=BIP, lane=0, start=0)["id"]
        Y = cmd("object.add", path=BIP, lane=1, start=0)["id"]
        eqX = add(X, "4bandEq")
        LX = cmd("fxlink.create", host=X, plugins=[eqX])["id"]
        cmd("fxlink.attach", link=LX, host=Y)
        cmd("object.set_mute", ids=[Y], muted=True)
        idle()

        def render(name):
            out = os.path.join(TMP, name)
            r = cmd("export.run", format="wav", sample_rate=44100, dithering=False,
                    start=0.0, end=0.6, path=out)
            cmd("job.wait", id=r["job_id"], timeout_ms=60000)
            return wav_peak(out)

        p0 = render("neutral.wav")
        check("the bin plays (signal through the block)", p0 > 0.05, "%s" % p0)
        cmd("fxlink.set_output", link=LX, gain_db=-20.0)
        p1 = render("minus20.wav")
        check("the bin's volume is HEARD (-20 dB)", abs(p1 / p0 - 0.1) < 0.02, "%s / %s" % (p1, p0))
        cmd("fxlink.set_output", link=LX, muted=True)
        p2 = render("muted.wav")
        check("the bin's mute is HEARD", p2 < p0 * 0.001, "%s" % p2)
        cmd("fxlink.set_output", link=LX, muted=False)
        cmd("fxlink.set_enabled", link=LX, enabled=False)
        p3 = render("off.wav")
        check("a bin that is off bypasses its output stage too (level back to unity)",
              abs(p3 / p0 - 1.0) < 0.05, "%s / %s" % (p3, p0))
        cmd("fxlink.set_enabled", link=LX, enabled=True)
        p4 = render("on.wav")
        check("and back on", abs(p4 / p0 - 0.1) < 0.02, "%s / %s" % (p4, p0))

        # per member: Y is the audible one, X muted; the bin's volume follows to Y, its local one does not
        cmd("object.set_mute", ids=[Y], muted=False)
        cmd("object.set_mute", ids=[X], muted=True)
        idle()
        py = render("member_Y.wav")
        check("the OTHER member hears the bin's volume too", abs(py / p0 - 0.1) < 0.02, "%s / %s" % (py, p0))
        cmd("fxlink.detach", host=Y, link=LX)
        cmd("fxlink.set_local_output", host=Y, link=LX, gain_db=0.0)
        py2 = render("member_Y_detached.wav")
        check("a detached member plays its OWN output section (0 dB, unlike the bin's -20)",
              abs(py2 / p0 - 1.0) < 0.05, "%s / %s" % (py2, p0))
        cmd("fxlink.set_local_output", host=Y, link=LX, muted=True)
        py3 = render("member_Y_localmute.wav")
        check("...its local mute is heard", py3 < p0 * 0.001, "%s" % py3)
        cmd("fxlink.reattach", host=Y, link=LX)
        py4 = render("member_Y_reattached.wav")
        check("reattached, it plays the bin's again", abs(py4 / p0 - 0.1) < 0.02, "%s / %s" % (py4, p0))
        cmd("edit.undo")      # the reattach
        cmd("edit.undo")      # the local mute
        idle()
        py5 = render("member_Y_undone.wav")
        check("undo restores the detached member's local section in the engine (0 dB)",
              abs(py5 / p0 - 1.0) < 0.05, "%s / %s" % (py5, p0))

        # ── the SIGNAL VIEW: a bin's cards carry no link badge of their own ─────
        # (the block does), while the old ⌘-links keep theirs. `synoptic.cards` reads what the view
        # builds from the model, so this is asserted with no screen.
        cmd("project.new")
        SA = cmd("object.add", path=BIP, lane=0, start=0)["id"]
        SB = cmd("object.add", path=BIP, lane=1, start=0)["id"]
        s_eq = add(SA, "4bandEq")
        s_rev = add(SA, "reverb")
        s_solo = add(SA, "chorus")                  # outside the bin
        SL = cmd("fxlink.create", host=SA, plugins=[s_eq, s_rev], name="View")["id"]
        cmd("fxlink.attach", link=SL, host=SB); idle()

        def cards(host):
            return cmd("synoptic.cards", host=host)["cards"]

        ca = cards(SA)
        in_bin = [c for c in ca if c["in_fx_block"]]
        check("the bin's two instances are cards flagged as in the block",
              [c["name"] for c in in_bin] == ["Equalizer", "Reverb"], str(ca))
        check("...and NOT the plugin outside it", [c["in_fx_block"] for c in ca].count(False) == 1)
        check("a card in the block shows NO link badge (though its instance is linked)",
              all(c["link_badge"] is False for c in in_bin)
              and all(next(p for p in block_of(SA)["plugins"] if p["id"] == c["id"])["linked"] for c in in_bin))
        check("...nor the linked emphasis", all(c["linked_style"] is False for c in in_bin))
        cb = cards(SB)
        check("the same holds on every member", len(cb) == 2 and all(not c["link_badge"] for c in cb))
        cmd("fxlink.detach", host=SB, link=SL); idle()
        check("a DETACHED block's cards show no badge either (the block's header carries it)",
              all(not c["link_badge"] and c["in_fx_block"] for c in cards(SB)))
        cmd("fxlink.reattach", host=SB, link=SL); idle()

        # the old manual link keeps its badge
        cmd("plugin.link", **{"from": SA, "plugin": s_solo, "to": SB}); idle()
        legacy = [c for c in cards(SB) if not c["in_fx_block"]]
        check("a legacy ⌘-linked plugin, outside any bin, keeps its badge and its emphasis",
              len(legacy) == 1 and legacy[0]["link_badge"] is True and legacy[0]["linked_style"] is True, str(legacy))
        check("...on its source too", [c for c in cards(SA) if not c["in_fx_block"]][0]["link_badge"] is True)

finally:
    shutil.rmtree(TMP, ignore_errors=True)

print()
print("%d assertion(s), %d failure(s)" % (total, len(fails)))
if fails:
    for f in fails:
        print("  FAILED: " + f)
    sys.exit(1)
print("ALL PASS")

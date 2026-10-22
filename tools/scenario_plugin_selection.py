#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Several plugin cards at once — a scenario that ASSERTS rather than replaying.

Same shape as `scenario_markers.py`, and for the same reason: a JSON-lines scenario cannot
reuse an identifier an earlier command returned, and everything here does.

    # 1. launch the app with the API, on a SHORT socket (a system limit: 103 bytes).
    #    `--no-recent`: the throwaway project below does not enter "Recent projects".
    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --socket=/tmp/o.sock

    # 2. replay
    ./scenario_plugin_selection.py /tmp/o.sock

What it is really out to prove, beyond the commands answering:

  • the ORDER of a batch is the CHAIN's and never the set's — a selection has no order, and
    plugins laid down in the wrong one are a different sound;
  • ONE undo step per gesture, not one per card;
  • an object and a STEM are the same host, in every one of these gestures;
  • ⌘D and ⌘V land just after the LAST selected card, in ITS series, and not at the chain's end;
  • a MOVE really empties the source, where a copy leaves it whole (and ⌘ changes nothing);
  • a DROP lands on a BUS's strip — the only place a stem can be aimed at with the hand — and
    the selection follows its cards there;
  • a PARALLEL BRANCH (`plugin.branch`, the '+' and the card's menu) takes the run the selection says,
    stops at a send's marker, makes an EMPTY branch where there is nothing, refuses a bin's inside, and
    costs ONE undo point.

The half this file cannot reach is the mouse: the rectangle, ⇧ and ⌘ on the canvas are geometry,
and they are asserted on their own in `test_synoptic_marquee.swift`.

Exit: 0 if every assertion passes, 1 otherwise.
"""

import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

if len(sys.argv) != 2:
    print(__doc__)
    sys.exit(2)

SOCK = sys.argv[1]
BIP = os.path.join(HERE, "fixtures", "bip.wav")

fails = []
total = 0


def check(label, ok, detail=""):
    global total
    total += 1
    if ok:
        print("ok    " + label)
    else:
        fails.append(label)
        print("FAIL  %s  %s" % (label, detail))


with ObjekatClient(SOCK) as c:
    def cmd(_name, **params):
        return c.send(_name, params or None)

    info = cmd("app.info")
    check("--no-recent honoured", info.get("records_recent_projects") is False,
          str(info.get("records_recent_projects")))
    cmd("app.set_dialog_policy", policy="assume_yes")
    cmd("project.new")

    A = cmd("object.add", path=BIP, lane=0, start=0)["id"]
    B = cmd("object.add", path=BIP, lane=1, start=0)["id"]
    STEM = cmd("stem.add", name="Voice", format="mono")["id"]

    BUILTINS = ["4bandEq", "reverb", "compressor", "chorus"]

    def fill(host, identifiers=None):
        """Lays a fresh chain on `host` and hands back its ids, IN CHAIN ORDER."""
        for p in cmd("plugin.list", host=host)["plugins"]:
            cmd("plugin.remove", host=host, plugin=p["id"])
        out = []
        # `is None` and not a truth test: `[]` means "leave it empty", and `[] or BUILTINS`
        # would quietly fill the chain instead.
        for ident in (BUILTINS if identifiers is None else identifiers):
            out.append(cmd("plugin.add", host=host, identifier=ident,
                           format="TracktionInternal")["plugin"]["id"])
        return out

    def chain(host):
        """The host's chain as (id, identifier, enabled) triples, in order."""
        return [(p["id"], p["identifier"], p["enabled"])
                for p in cmd("plugin.list", host=host)["plugins"]]

    def idents(host):
        return [p[1] for p in chain(host)]

    eq, rev, comp, cho = fill(A)
    check("four built-ins laid on the object", idents(A) == BUILTINS, str(idents(A)))

    # ── the selection itself ────────────────────────────────────────────────
    # Named out of order ON PURPOSE: what comes back must be the chain's order and not the
    # order they were asked for, nor a set's (which has none at all).
    r = cmd("plugin.select", host=A, plugins=[cho, eq])
    check("a selection is read back in the CHAIN's order, not the caller's",
          r["plugins"] == [eq, cho], str(r["plugins"]))

    sel = cmd("plugin.selection")
    check("the selection names its host", sel["host"] == A, str(sel["host"]))
    check("and it holds the keyboard", sel["has_keyboard"] is True)
    check("its cards come back whole", [p["identifier"] for p in sel["plugins"]] == ["4bandEq", "chorus"],
          str([p["identifier"] for p in sel["plugins"]]))

    r = cmd("plugin.select", host=A, plugins=[comp], mode="add")
    check("mode=add grows it", r["plugins"] == [eq, comp, cho], str(r["plugins"]))
    r = cmd("plugin.select", host=A, plugins=[comp, rev], mode="toggle")
    check("mode=toggle flips each card one by one",
          r["plugins"] == [eq, rev, cho], str(r["plugins"]))

    # Another host ⇒ a fresh selection, never a selection spanning two chains.
    fill(B, ["reverb"])
    bplug = chain(B)[0][0]
    r = cmd("plugin.select", host=B, plugins=[bplug])
    check("aiming at another host replaces rather than grows",
          r["plugins"] == [bplug] and cmd("plugin.selection")["host"] == B, str(r))

    # An EMPTY selection still claims the keyboard: that is what lets ⌘V land in a chain with no
    # card to click on. @see EditViewModel.setPluginSelection
    r = cmd("plugin.select", host=A)
    sel = cmd("plugin.selection")
    check("selecting nothing still claims the keyboard for that chain",
          sel["count"] == 0 and sel["has_keyboard"] is True and sel["host"] == A, str(sel))
    cmd("plugin.deselect")
    sel = cmd("plugin.selection")
    check("deselecting gives the keyboard back to the timeline",
          sel["has_keyboard"] is False and sel["host"] is None, str(sel))

    try:
        cmd("plugin.select", host=A, plugins=[bplug])
        check("a card of ANOTHER chain is refused", False, "no error raised")
    except ObjekatError as e:
        check("a card of ANOTHER chain is refused", "not_found" in str(e), str(e))

    # ── ⌫ : removing a selection, in ONE undo step ──────────────────────────
    eq, rev, comp, cho = fill(A)
    cmd("plugin.select", host=A, plugins=[eq, comp])
    r = cmd("plugin.remove_selected")
    check("⌫ takes every selected card", r["removed"] == 2 and idents(A) == ["reverb", "chorus"],
          str(idents(A)))
    check("and the selection goes with them — the keyboard too",
          cmd("plugin.selection")["has_keyboard"] is False)
    cmd("edit.undo")
    check("ONE undo brings the whole batch back, not one card of it",
          idents(A) == BUILTINS, str(idents(A)))

    # ── on/off over several cards ───────────────────────────────────────────
    eq, rev, comp, cho = fill(A)
    cmd("plugin.select", host=A, plugins=[eq, rev, comp])
    r = cmd("plugin.toggle_selected")
    st = {p[1]: p[2] for p in chain(A)}
    check("the three selected go off together",
          r["enabled"] is False and st["4bandEq"] is False and st["reverb"] is False
          and st["compressor"] is False, str(st))
    check("and the one not selected is left alone", st["chorus"] is True, str(st))
    r = cmd("plugin.toggle_selected")
    st = {p[1]: p[2] for p in chain(A)}
    check("a second press brings them all back",
          r["enabled"] is True and all(st[k] for k in BUILTINS), str(st))

    # A MIXED state: one of the three is off. The gesture resolves towards OFF — "off" is what a
    # hand asks for when it reaches for a bypass over several plugins.
    cmd("plugin.toggle", host=A, plugin=rev)
    r = cmd("plugin.toggle_selected")
    st = {p[1]: p[2] for p in chain(A)}
    check("mixed states go to OFF: one still on turns them all off",
          r["enabled"] is False and not st["4bandEq"] and not st["reverb"] and not st["compressor"],
          str(st))

    # A bypass is UNDOABLE — it changes what is heard, which is the only test that qualifies a
    # gesture for ⌘Z. One point for the whole batch, and one for a single card.
    cmd("edit.undo")
    st = {p[1]: p[2] for p in chain(A)}
    check("ONE ⌘Z gives back every card the batch bypass took down",
          st["4bandEq"] and st["compressor"] and not st["reverb"], str(st))
    cmd("edit.undo")
    st = {p[1]: p[2] for p in chain(A)}
    check("and the single bypass before it is undoable too", st["reverb"] is True, str(st))

    # ── ⌘D : duplicating just after the last selected card ──────────────────
    eq, rev, comp, cho = fill(A)
    cmd("plugin.select", host=A, plugins=[eq])
    made = cmd("plugin.duplicate_selected")["plugins"]
    check("⌘D lands the copy just AFTER its original, not at the chain's end",
          idents(A) == ["4bandEq", "4bandEq", "reverb", "compressor", "chorus"], str(idents(A)))
    check("and the copy becomes the selection, so a second ⌘D chains",
          cmd("plugin.selection")["plugins"][0]["id"] == made[0], str(made))
    check("a duplicate is INDEPENDENT, not linked",
          cmd("plugin.selection")["plugins"][0]["linked"] is False)
    cmd("edit.undo")
    check("one undo for the whole duplication", idents(A) == BUILTINS, str(idents(A)))

    cmd("plugin.select", host=A, plugins=[eq, comp])
    cmd("plugin.duplicate_selected")
    check("several cards duplicate in the chain's order, after the LAST of them",
          idents(A) == ["4bandEq", "reverb", "compressor", "4bandEq", "compressor", "chorus"],
          str(idents(A)))

    # ── ⌘C / ⌘V ─────────────────────────────────────────────────────────────
    eq, rev, comp, cho = fill(A)
    fill(B, ["delay", "phaser"])
    d1, d2 = [p[0] for p in chain(B)]
    cmd("plugin.select", host=A, plugins=[eq, comp])
    check("⌘C puts the selection aside", cmd("plugin.copy_selected")["clipboard"] == 2)
    check("and the clipboard is visible from outside",
          cmd("plugin.selection")["clipboard"] == 2)

    cmd("plugin.select", host=B, plugins=[d1])
    cmd("plugin.paste")
    check("⌘V lands after the selected card of the RECEIVING chain",
          idents(B) == ["delay", "4bandEq", "compressor", "phaser"], str(idents(B)))
    check("the source chain is untouched by a copy", idents(A) == BUILTINS, str(idents(A)))

    # Pasted twice ⇒ two independent sets, never two views of one.
    first = set(p[0] for p in chain(B))
    cmd("plugin.deselect")
    cmd("plugin.paste", host=B)
    check("⌘V with nothing selected lands at the chain's end",
          idents(B) == ["delay", "4bandEq", "compressor", "phaser", "4bandEq", "compressor"],
          str(idents(B)))
    check("pasting twice gives two independent sets",
          len(set(p[0] for p in chain(B)) - first) == 2, str(idents(B)))
    cmd("edit.undo")
    check("one undo for a whole paste", len(chain(B)) == 4, str(idents(B)))

    # ── carrying several cards onto another host ────────────────────────────
    eq, rev, comp, cho = fill(A)
    fill(B, [])
    r = cmd("plugin.move", **{"from": A, "plugins": [cho, eq, comp], "to": B})
    check("a move of several empties the source of exactly those cards",
          idents(A) == ["reverb"], str(idents(A)))
    check("and lays them on the target in the SOURCE chain's order",
          idents(B) == ["4bandEq", "compressor", "chorus"], str(idents(B)))
    check("the command reports what it laid down", r["count"] == 3, str(r))
    cmd("edit.undo")
    check("ONE undo puts the whole move back",
          idents(A) == BUILTINS and idents(B) == [], "%s / %s" % (idents(A), idents(B)))

    eq, rev, comp, cho = fill(A)
    fill(B, [])
    cmd("plugin.copy", **{"from": A, "plugins": [eq, rev], "to": B})
    check("a copy of several leaves the source whole", idents(A) == BUILTINS, str(idents(A)))
    check("and the copies are independent",
          idents(B) == ["4bandEq", "reverb"]
          and all(p["linked"] is False for p in cmd("plugin.list", host=B)["plugins"]),
          str(idents(B)))

    # The single-instance manual link is gone (22 October 2026): the command no longer exists.
    try:
        cmd("plugin.link", **{"from": A, "plugins": [eq, rev], "to": B})
        check("plugin.link no longer exists", False, "no error raised")
    except ObjekatError as e:
        check("plugin.link no longer exists", "unknown_command" in str(e), str(e))
    check("...and nothing was linked by the attempt",
          all(p["linked"] is False for p in cmd("plugin.list", host=A)["plugins"]
              + cmd("plugin.list", host=B)["plugins"]))

    # ── a STEM is a host like any other ─────────────────────────────────────
    s1, s2, s3, s4 = fill(STEM)
    check("a stem carries a chain too", idents(STEM) == BUILTINS, str(idents(STEM)))
    cmd("plugin.select", host=STEM, plugins=[s1, s3])
    check("the selection lives on a stem the same way",
          cmd("plugin.selection")["host"] == STEM)
    cmd("plugin.duplicate_selected")
    check("⌘D on a stem lands after the last selected card",
          idents(STEM) == ["4bandEq", "reverb", "compressor", "4bandEq", "compressor", "chorus"],
          str(idents(STEM)))
    cmd("plugin.select", host=STEM, plugins=[s1, s3])
    cmd("plugin.remove_selected")
    check("⌫ on a stem takes its cards", len(chain(STEM)) == 4, str(idents(STEM)))

    fill(STEM, ["reverb"])
    srev = chain(STEM)[0][0]
    fill(A, ["delay"])
    cmd("plugin.move", **{"from": STEM, "plugins": [srev], "to": A})
    check("a card really LEAVES a stem's chain (it does not live in `items`)",
          idents(STEM) == [] and idents(A) == ["delay", "reverb"],
          "%s / %s" % (idents(STEM), idents(A)))

    # ── the DROP, and a bus's strip as a target ─────────────────────────────
    # `plugin.drop` is the door a HAND comes in by — a timeline object, or a bus's strip in the
    # toolbar, which is the only place a stem can be aimed at (a stem has no block of its own).
    # It reaches the same transfer as `plugin.move`, and what is asserted here is what it adds:
    # the mode read off the modifiers, and the selection following its cards.
    eq, rev, comp, cho = fill(A)
    fill(STEM, [])
    cmd("plugin.select", host=A, plugins=[eq, rev])
    r = cmd("plugin.drop", **{"from": A, "plugins": [eq, rev], "to": STEM})
    check("a drop with no modifier MOVES onto the bus",
          idents(STEM) == ["4bandEq", "reverb"] and idents(A) == ["compressor", "chorus"],
          "%s / %s" % (idents(STEM), idents(A)))
    check("the selection follows its cards into the bus it was dropped on",
          r["selection_host"] == STEM and len(r["selection"]) == 2, str(r))
    check("and one ⌘Z gives the bus's chain back",
          (cmd("edit.undo"), idents(STEM) == [] and idents(A) == BUILTINS)[1],
          "%s / %s" % (idents(STEM), idents(A)))

    fill(A)
    fill(STEM, [])
    eq = chain(A)[0][0]
    cmd("plugin.deselect")
    cmd("plugin.drop", **{"from": A, "plugin": eq, "to": STEM, "mode": "copy"})
    check("⌥ over a strip leaves the source whole",
          idents(A) == BUILTINS and idents(STEM) == ["4bandEq"],
          "%s / %s" % (idents(A), idents(STEM)))
    check("a copy dropped on a bus is INDEPENDENT",
          cmd("plugin.list", host=STEM)["plugins"][0]["linked"] is False)

    fill(STEM, [])
    try:
        cmd("plugin.drop", **{"from": A, "plugin": eq, "to": STEM, "mode": "link"})
        check("a drop in `link` mode is refused (the mode is gone)", False, "no error raised")
    except ObjekatError as e:
        check("a drop in `link` mode is refused (the mode is gone)", "bad_params" in str(e), str(e))
    cmd("plugin.drop", **{"from": A, "plugin": eq, "to": STEM, "mode": "copy_command"})
    src = cmd("plugin.list", host=A)["plugins"][0]
    dst = cmd("plugin.list", host=STEM)["plugins"][0]
    check("⌥⌘ over a strip is a plain ⌥ copy: ⌘ does nothing, nothing is linked",
          idents(A) == BUILTINS and idents(STEM) == ["4bandEq"]
          and not src.get("link_group") and not dst.get("link_group") and dst["linked"] is False, str(dst))
    fill(STEM, [])
    cmd("plugin.drop", **{"from": A, "plugin": eq, "to": STEM, "mode": "move_command"})
    check("⌘ alone over a strip is a plain MOVE", idents(STEM) == ["4bandEq"] and "4bandEq" not in idents(A),
          "%s / %s" % (idents(STEM), idents(A)))
    cmd("edit.undo")

    # The other way round: a bus's card carried back down onto an object.
    fill(STEM, ["reverb"])
    srev = chain(STEM)[0][0]
    fill(B, [])
    cmd("plugin.drop", **{"from": STEM, "plugin": srev, "to": B})
    check("a card is dragged OFF a bus as well as onto one",
          idents(STEM) == [] and idents(B) == ["reverb"],
          "%s / %s" % (idents(STEM), idents(B)))

    try:
        cmd("plugin.drop", **{"from": A, "plugin": eq, "to": B, "mode": "sideways"})
        check("a drop with an unknown mode is refused", False, "no error raised")
    except ObjekatError as e:
        check("a drop with an unknown mode is refused", "bad_params" in str(e), str(e))

    # ── what a batch refuses ────────────────────────────────────────────────
    eq, rev, comp, cho = fill(A)
    before = idents(A)
    r = cmd("plugin.move", **{"from": A, "plugins": [eq], "to": A})
    check("moving a chain onto ITSELF does nothing, and burns no undo step",
          r["count"] == 0 and idents(A) == before, str(idents(A)))
    try:
        cmd("plugin.move", **{"from": A, "plugins": [], "to": B})
        check("an empty list is refused", False, "no error raised")
    except ObjekatError as e:
        check("an empty list is refused", "bad_params" in str(e), str(e))
    try:
        cmd("plugin.select", host=A, plugins=[eq], mode="sideways")
        check("an unknown mode is refused", False, "no error raised")
    except ObjekatError as e:
        check("an unknown mode is refused", "bad_params" in str(e), str(e))

    # ── a send's mini-chain (INC 3): a host like the others, minus the link ─
    AUX = cmd("aux.create", start=0, end=4, lane=4)["id"]
    cmd("send.set_level", id=A, aux=AUX, db=-6)
    SH = next(s_ for s_ in cmd("send.list", id=A)["sends"] if s_["aux"] == AUX)["chain_host"]
    s1, s2 = fill(SH, ["4bandEq", "chorus"])
    r = cmd("plugin.select", host=SH, plugins=[s2, s1])
    check("a selection on a SEND's chain is read back in that chain's order",
          r["plugins"] == [s1, s2], str(r["plugins"]))
    sel = cmd("plugin.selection")
    check("it names the send's chain as its host, not the sender", sel["host"] == SH and SH != A, str(sel["host"]))
    cmd("plugin.duplicate_selected")
    check("duplicating it stays on the send, the copies after the selection (as on a trunk)",
          idents(SH) == ["4bandEq", "chorus", "4bandEq", "chorus"] and idents(A) == BUILTINS,
          "%s / %s" % (idents(SH), idents(A)))
    cmd("edit.undo")
    check("one undo takes the copies back", idents(SH) == ["4bandEq", "chorus"], str(idents(SH)))
    eq = chain(A)[0][0]
    cmd("plugin.drop", **{"from": A, "plugin": eq, "to": SH, "mode": "copy_command"})
    on_send = cmd("plugin.list", host=SH)["plugins"]
    on_trunk = cmd("plugin.list", host=A)["plugins"]
    check("⌥⌘ onto a send is a plain COPY (⌘ does nothing): the source stays, the send gains one",
          len(on_send) == 3 and [p["identifier"] for p in on_trunk] == BUILTINS, str(on_send))
    check("...and nothing is linked, on either side",
          all(not p.get("link_group") for p in on_send + on_trunk), str(on_send + on_trunk))
    cmd("plugin.deselect")

    # ── a parallel branch (§B.2, 13 October 2026): the '+', the card's menu, the selection ─
    # The hand's two doors are `plugin.branch` with `series`/`at` (a drag down-right out of a '+') and with
    # `plugin` (the card's "Create a parallel branch"). ONE undo point each, read on `perf.census` — in a
    # FRESH project, so that the undo history (capped at 50) is far from full and its depth means something.
    cmd("project.new")
    BR = cmd("object.add", path=BIP, lane=2, start=0)["id"]
    p1, p2, p3, p4 = fill(BR)

    def top(host):
        return cmd("plugin.list", host=host)["plugins"]

    def shape(host):
        """The root series: plugin ids, a rack as ("R", [[ids of each branch]]), a send marker as "M"."""
        out = []
        for q in top(host):
            if q.get("is_rack"):
                out.append(("R", [[x["id"] if not x.get("is_rack") else "R" for x in v] for v in q["voices"]]))
            elif q.get("is_send_marker"):
                out.append("M")
            else:
                out.append(q["id"])
        return out

    def depth():
        return cmd("perf.census")["undo_depth"]

    def branch_once(label, expect_ids, expect_shape, **params):
        """One `plugin.branch`: what it took, the chain it left, ONE undo point, and one undo restores."""
        before, d0 = shape(BR), depth()
        r = cmd("plugin.branch", host=BR, **params)
        check(label + ": the run", r["branched"] == expect_ids, str(r["branched"]))
        check(label + ": the chain", shape(BR) == expect_shape, str(shape(BR)))
        check(label + ": ONE undo point", depth() == d0 + 1, "%d -> %d" % (d0, depth()))
        cmd("edit.undo")
        check(label + ": one undo puts the chain back", shape(BR) == before, str(shape(BR)))
        return r

    cmd("plugin.deselect")
    r = branch_once("'+' 1, no selection", [p2], [p1, ("R", [[p2], []]), p3, p4], series="root", at=1)
    check("the answer names the new block", r["block"] is not None and r["empty_branch"] is False, str(r))
    branch_once("head '+', no selection", [p1], [("R", [[p1], []]), p2, p3, p4], at=0)
    branch_once("tail '+', no selection: the element ABOVE it", [p4], [p1, p2, p3, ("R", [[p4], []])], at=4)

    cmd("plugin.select", host=BR, plugins=[p3, p2])
    branch_once("'+' 1, p2 p3 selected: both, in chain order", [p2, p3], [p1, ("R", [[p2, p3], []]), p4], at=1)
    branch_once("'+' 2, p2 p3 selected: from p3 down only", [p3], [p1, p2, ("R", [[p3], []]), p4], at=2)
    branch_once("'+' 0, p1 not selected: p1 alone, the selection ignored", [p1], [("R", [[p1], []]), p2, p3, p4], at=0)
    cmd("plugin.select", host=BR, plugins=[p2, p4])
    branch_once("'+' 1, p2 p4 selected (not contiguous): p2 only", [p2], [p1, ("R", [[p2], []]), p3, p4], at=1)
    cmd("plugin.select", host=BR, plugins=[p3, p4])
    branch_once("tail '+', p3 p4 selected: both (going up)", [p3, p4], [p1, p2, ("R", [[p3, p4], []])], at=4)

    # the card's menu
    cmd("plugin.select", host=BR, plugins=[p2, p3, p4])
    branch_once("menu on p3, p2 p3 p4 selected: the whole run round it", [p2, p3, p4],
                [p1, ("R", [[p2, p3, p4], []])], plugin=p3)
    branch_once("menu on p1, not selected: p1 alone", [p1], [("R", [[p1], []]), p2, p3, p4], plugin=p1)
    cmd("plugin.deselect")
    branch_once("menu on p2, no selection: p2 alone", [p2], [p1, ("R", [[p2], []]), p3, p4], plugin=p2)

    # an EMPTY branch: a '+' with nothing under it — the empty chain, and an empty branch of a block
    EMPTY = cmd("object.add", path=BIP, lane=3, start=0)["id"]
    fill(EMPTY, [])
    r = cmd("plugin.branch", host=EMPTY, at=0)
    rk = [q for q in top(EMPTY) if q.get("is_rack")]
    check("an empty chain: an EMPTY branch (a block of two empty branches)",
          r["branched"] == [] and r["empty_branch"] is True and len(rk) == 1 and rk[0]["voices"] == [[], []]
          and r["block"] is None, str(r))
    cmd("edit.undo")
    check("...one undo takes it back", top(EMPTY) == [], str(top(EMPTY)))
    cmd("plugin.branch", host=BR, at=1)                      # [p1, R[[p2],[]], p3, p4]
    blk = next(q for q in top(BR) if q.get("is_rack"))["id"]
    r = cmd("plugin.branch", host=BR, series={"voice": blk, "index": 1}, at=0)
    inner = next(q for q in top(BR) if q.get("is_rack"))["voices"]
    check("an empty branch of a block: a nested block of two empty branches inside it",
          r["empty_branch"] is True and [x["id"] for x in inner[0]] == [p2] and len(inner[1]) == 1
          and inner[1][0].get("is_rack") and inner[1][0]["voices"] == [[], []], str(inner))
    cmd("edit.undo"); cmd("edit.undo")
    check("...two undos, two points", shape(BR) == [p1, p2, p3, p4], str(shape(BR)))

    # a send's marker is a barrier: a send taken before p3 stays where it is
    AUXB = cmd("aux.create", start=0, end=4, lane=5)["id"]
    cmd("send.create", id=BR, aux=AUXB, position="chain", before_plugin=p3)
    check("a send taps the chain before p3", shape(BR) == [p1, p2, "M", p3, p4], str(shape(BR)))
    cmd("plugin.select", host=BR, plugins=[p2, p3])
    branch_once("p2 p3 selected across a send's marker: the run stops at the marker", [p2],
                [p1, ("R", [[p2], []]), "M", p3, p4], at=1)
    branch_once("view index 2 is p3 (the marker is not counted)", [p3], [p1, p2, "M", ("R", [[p3], []]), p4], at=2)
    cmd("send.remove", id=BR, aux=AUXB)
    cmd("plugin.deselect")

    # refusals: inside a bin, a bin's instance
    q1, q2 = fill(BR, ["4bandEq", "reverb"])
    link = cmd("fxlink.create", host=BR, plugins=[q1, q2])
    blockid = next(q for q in top(BR) if q.get("is_fx_block"))["id"]
    inst = next(q for q in top(BR) if q.get("is_fx_block"))["plugins"][0]["id"]
    d0 = depth()
    for label, params in [("a bin's series", {"series": {"block": blockid}, "at": 0}),
                          ("a bin's instance (menu)", {"plugin": inst})]:
        try:
            cmd("plugin.branch", host=BR, **params)
            check("branching %s is refused" % label, False, "no error raised")
        except ObjekatError as e:
            check("branching %s is refused" % label, "invalid_state" in str(e), str(e))
    check("...and the refusals burn no undo point", depth() == d0, "%d -> %d" % (d0, depth()))
    r = cmd("plugin.branch", host=BR, at=0)
    check("the '+' above a bin branches the bin's block WHOLE", r["branched"] == [blockid], str(r))
    cmd("edit.undo")
    cmd("fxlink.delete", link=link["id"])
    cmd("plugin.deselect")

print("")
if fails:
    print("%d FAILED out of %d:\n  - %s" % (len(fails), total, "\n  - ".join(fails)))
    sys.exit(1)
print("%d assertions, all pass" % total)

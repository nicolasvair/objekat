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
  • a MOVE really empties the source, where a copy and a link leave it whole.

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

    fill(B, [])
    cmd("plugin.link", **{"from": A, "plugins": [eq, rev], "to": B})
    src = {p["identifier"]: p for p in cmd("plugin.list", host=A)["plugins"]}
    dst = {p["identifier"]: p for p in cmd("plugin.list", host=B)["plugins"]}
    check("a link of several ties each card to ITS OWN copy",
          src["4bandEq"]["link_group"] == dst["4bandEq"]["link_group"]
          and src["reverb"]["link_group"] == dst["reverb"]["link_group"], str(dst))
    check("two cards linked in one gesture do NOT end up in the same group",
          src["4bandEq"]["link_group"] != src["reverb"]["link_group"],
          "otherwise an EQ and a reverb would share their parameters")
    check("the cards not named are left unlinked",
          src["compressor"]["linked"] is False and src["chorus"]["linked"] is False)

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

print("")
if fails:
    print("%d FAILED out of %d:\n  - %s" % (len(fails), total, "\n  - ".join(fails)))
    sys.exit(1)
print("%d assertions, all pass" % total)

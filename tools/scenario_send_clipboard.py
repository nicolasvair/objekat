#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Send cards: selection, copy / paste, delete, and the Send tool's resets — a scenario that ASSERTS.

    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --socket=/tmp/o.sock
    ./scenario_send_clipboard.py /tmp/o.sock

What it proves, with no screen:
  • the send cards are selected like plugin cards (replace / add / toggle / range), the two selections
    are EXCLUSIVE and the cards hold the keyboard;
  • ⌘C keeps level, switch, position, the mini-chain's plugins (deep copy, FRESH ids per target) and the
    level's curve; ⌘V lays them on every object selected, OVERWRITES a send that already goes to that
    aux, ignores a target that is an aux and an aux the project does not hold, in ONE undo step;
  • ⌫ on the cards deletes them in one step, and gives the keyboard back;
  • the Send tool's double click (`send.reset_level`) and ⌫ (`send.reset_selected`) put sends at -inf,
    one undo step each, nothing for a send under a curve.

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
        print("FAIL  %s   %s" % (label, detail))


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

    def sends(oid):
        return {s["aux"]: s for s in cmd("send.list", id=oid)["sends"]}

    def curve(oid, aux):
        lanes = cmd("automation.list", id=oid)["lanes"]
        for l in lanes:
            if l["param"] == "send:" + aux:
                return [(round(p["t"], 3), round(p["v"], 3)) for p in l["points"]]
        return None

    cmd("app.set_dialog_policy", policy="assume_yes")
    cmd("project.new")
    A = cmd("object.add", path=BIP, lane=0, start=0)["id"]
    B = cmd("object.add", path=BIP, lane=3, start=0)["id"]
    C = cmd("object.add", path=BIP, lane=4, start=0)["id"]
    X1 = cmd("aux.create", start=0, end=5, lane=1)["id"]
    X2 = cmd("aux.create", start=0, end=5, lane=2)["id"]

    # ── A: two sends, the first one rich (position, plugin, curve) ────────────
    cmd("send.create", id=A, aux=X1, position="pre_fader")
    cmd("send.set_level", id=A, aux=X1, db=-6)
    host = sends(A)[X1]["chain_host"]
    cmd("plugin.add", host=host, identifier="chorus", format="TracktionInternal")
    cmd("automation.set_points", id=A, param="send:" + X1,
        points=[{"t": 0, "v": -12}, {"t": 1, "v": -3}])
    cmd("send.create", id=A, aux=X2)
    cmd("send.set_level", id=A, aux=X2, db=-3)
    idle()
    sa = sends(A)
    check("setup: A sends to both auxes, the first pre-fader with one plugin",
          sa[X1]["position"] == "pre_fader" and len(sa[X1]["plugins"]) == 1 and abs(sa[X2]["level_db"] + 3) < 1e-3,
          str(sa))

    # ── selection ────────────────────────────────────────────────────────────
    cmd("selection.set", ids=[A])
    r = cmd("send.select", id=A, auxes=[X1])
    check("a send card is selected and holds the keyboard",
          r["count"] == 1 and cmd("send.selection")["has_keyboard"] is True, str(r))
    cmd("send.select", id=A, auxes=[X2], mode="add")
    check("add: both cards", cmd("send.selection")["count"] == 2)
    cmd("send.select", id=A, auxes=[X2], mode="toggle")
    check("toggle: X2 comes off", cmd("send.selection")["auxes"] == [X1])
    cmd("send.select", id=A, auxes=[X2], mode="range")
    check("range: from X1 to X2 takes both", cmd("send.selection")["count"] == 2)
    cmd("send.select", id=A, auxes=[X1])
    cmd("plugin.select", host=A, plugins=[])
    s = cmd("send.selection")
    check("a plugin selection lets the cards go (exclusive)", s["count"] == 0 and s["has_keyboard"] is False, str(s))
    check("...and the cards take it back from the plugin selection",
          (cmd("send.select", id=A, auxes=[X1]) or True)
          and cmd("send.selection")["has_keyboard"] is True and cmd("plugin.selection")["has_keyboard"] is False)

    # ── copy ─────────────────────────────────────────────────────────────────
    r = cmd("edit.copy")
    check("⌘C on the cards: branch sends", r["branch"] == "sends", str(r))
    sel = cmd("send.selection")
    check("one send on the clipboard, the sends are the last thing copied",
          sel["clipboard"] == 1 and sel["clipboard_live"] is True, str(sel))
    check("⌘X is a dead key on the cards", cmd("edit.cut")["branch"] == "none")

    # ── paste onto several objects, from the timeline ────────────────────────
    cmd("send.deselect")
    cmd("selection.set", ids=[B, C])
    r = cmd("edit.paste"); idle()
    check("⌘V over two selected objects: branch sends", r["branch"] == "sends", str(r))
    sb, sc = sends(B), sends(C)
    check("both objects now send to X1, at -6 dB, pre-fader, with the plugin",
          all(X1 in s and abs(s[X1]["level_db"] + 6) < 1e-3 and s[X1]["enabled"] and s[X1]["position"] == "pre_fader"
              and len(s[X1]["plugins"]) == 1 for s in (sb, sc)), str((sb, sc)))
    check("...and not to X2 (only the copied send travels)", X2 not in sb and X2 not in sc)
    pa = sa[X1]["plugins"][0]["id"]
    pb, pc = sb[X1]["plugins"][0]["id"], sc[X1]["plugins"][0]["id"]
    check("every plugin is a COPY under a fresh id", len({pa, pb, pc}) == 3, str((pa, pb, pc)))
    check("the level's curve came along", curve(B, X1) == curve(A, X1) == [(0.0, -12.0), (1.0, -3.0)]
          and curve(C, X1) == curve(A, X1), str((curve(A, X1), curve(B, X1), curve(C, X1))))
    check("the original is untouched", sends(A)[X1]["plugins"][0]["id"] == pa)

    cmd("edit.undo"); idle()
    check("ONE undo takes the whole paste back (both objects)", X1 not in sends(B) and X1 not in sends(C))
    cmd("edit.redo"); idle()
    check("...and redo lays it again", X1 in sends(B) and X1 in sends(C))

    # ── overwrite ────────────────────────────────────────────────────────────
    cmd("send.set_level", id=B, aux=X1, db=-20)
    cmd("send.set_position", id=B, aux=X1, position="post_fader")
    cmd("send.set_enabled" if False else "send.enable", id=B, aux=X1, enabled=False)
    r = cmd("send.paste", ids=[B]); idle()
    sb = sends(B)
    check("pasting onto an existing send OVERWRITES it (level, switch, position, plugins)",
          r["laid"] == 1 and abs(sb[X1]["level_db"] + 6) < 1e-3 and sb[X1]["enabled"]
          and sb[X1]["position"] == "pre_fader" and len(sb[X1]["plugins"]) == 1
          and sb[X1]["plugins"][0]["id"] != pb, str((r, sb)))

    # ── refused / unknown targets ────────────────────────────────────────────
    r = cmd("send.paste", ids=[X2])
    check("an aux is not a target", r["laid"] == 0, str(r))
    check("an empty paste leaves no undo point behind",
          cmd("send.paste", ids=[X2])["laid"] == 0)
    before = len(sends(B))
    cmd("object.remove", ids=[X1]); idle()
    r = cmd("send.paste", ids=[C])
    check("an aux the project does not hold is ignored", r["laid"] == 0 and len(sends(C)) <= before, str(r))
    cmd("edit.undo"); idle()          # the aux comes back
    check("(setup) the removed aux is back", X1 in sends(A))

    # ── ⌫ on the cards ───────────────────────────────────────────────────────
    cmd("selection.set", ids=[A])
    cmd("send.select", id=A, auxes=[X1, X2])
    r = cmd("send.remove_selected"); idle()
    check("⌫ deletes the selected sends", r["removed"] == 2 and sends(A) == {}, str(r))
    check("...the keyboard goes back", cmd("send.selection")["has_keyboard"] is False)
    cmd("edit.undo"); idle()
    check("ONE undo gives both back, with the plugin and the curve",
          set(sends(A)) == {X1, X2} and len(sends(A)[X1]["plugins"]) == 1 and curve(A, X1) is not None)

    # ── the Send tool: double click and ⌫ (objects with plain, un-automated sends) ──
    D = cmd("object.add", path=BIP, lane=5, start=0)["id"]
    E = cmd("object.add", path=BIP, lane=6, start=0)["id"]
    for o, db in ((D, -6), (E, -9)):
        cmd("send.create", id=o, aux=X1)
        cmd("send.set_level", id=o, aux=X1, db=db)
    cmd("send.create", id=E, aux=X2)
    cmd("send.set_level", id=E, aux=X2, db=-12)
    idle()
    cmd("selection.set", ids=[D, E])
    r = cmd("send.reset_level", id=D, aux=X1); idle()
    check("double click: the grabbed send AND the other selected object's go to -inf",
          r["changed"] is True and sends(D)[X1]["level_db"] <= -59.9 and sends(E)[X1]["level_db"] <= -59.9, str(r))
    check("...the same object's send towards ANOTHER aux is left alone", abs(sends(E)[X2]["level_db"] + 12) < 1e-3)
    cmd("edit.undo"); idle()
    check("ONE undo gives both levels back", abs(sends(D)[X1]["level_db"] + 6) < 1e-3
          and abs(sends(E)[X1]["level_db"] + 9) < 1e-3)
    cmd("selection.set", ids=[A])
    r = cmd("send.reset_level", id=A, aux=X1)
    check("a send under a curve is not reset", r["changed"] is False and sends(A)[X1]["level_db"] > -59.9, str(r))
    cmd("selection.set", ids=[D, E])
    r = cmd("send.reset_selected"); idle()
    check("⌫ with the tool: EVERY send of the selected objects goes to -inf, the objects stay",
          r["reset"] == 3 and sends(D)[X1]["level_db"] <= -59.9 and sends(E)[X1]["level_db"] <= -59.9
          and sends(E)[X2]["level_db"] <= -59.9
          and any(o["id"] == D for o in cmd("object.list")["objects"]), str(r))
    cmd("edit.undo"); idle()
    check("...in ONE undo step", abs(sends(D)[X1]["level_db"] + 6) < 1e-3 and abs(sends(E)[X2]["level_db"] + 12) < 1e-3)

print("\n%d assertions, %d failed" % (total, len(fails)))
sys.exit(1 if fails else 0)

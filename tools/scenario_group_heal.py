#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Group heal ("Réunir") and the Cut tool's window-only rule for a group — what the model answers.

    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --language=en \
        --socket=/tmp/o.sock
    ./scenario_group_heal.py /tmp/o.sock

What it proves (the gestures themselves — the Cut tool's click and drag, the right-click menu — need
a pointer and are NOT driven here; the model calls underneath them are):

  A. `object.split_at window_only=true` on a group cuts its WINDOW only: two groups, the children
     stay whole in both (the right half carries independent copies, new ids).
  B. `group.heal` on those two pieces gives back EXACTLY the original: the same child ids, the same
     starts, durations and source offsets, the copies gone; ONE undo gives the two pieces back.
  C. A DEEP cut (`object.split_at` default) distributes the children; healing glues the continuous
     halves back into whole clips (same file, source offset continuous) — the sound is unchanged.
  D. Recursion: a sub-group cut with its parent heals with it.
  E. Refusals: a gap, a lone group, different parents, a looping group — each `invalid_state`, and
     nothing moves (no undo point left behind).
  F. The menu: `selection.context_action heal_groups` is offered on two jointive groups (and is
     greyed otherwise); `timesel.heal` joins only the junction a range COVERS.

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


def check(label, ok, detail=""):
    if ok:
        print("ok    " + label)
    else:
        fails.append(label)
        print("FAIL  %s  %s" % (label, detail))


def near(a, b, eps=1e-5):
    return abs(a - b) < eps


with ObjekatClient(SOCK) as c:
    def cmd(name, **params):
        return c.send(name, params or None)

    def refused(name, **params):
        try:
            c.send(name, params or None)
        except ObjekatError as e:
            return e
        return None

    def listing():
        return {o["id"]: o for o in cmd("object.list")["objects"]}

    def children(gid):
        return sorted((o for o in listing().values() if o["parent"] == gid),
                      key=lambda o: (o["lane"], o["start"]))

    def detail(oid):
        return cmd("object.get", id=oid)

    def snapshot(gid):
        """(id, start, duration, source_offset) of every child, sorted."""
        out = []
        for ch in children(gid):
            d = detail(ch["id"])
            out.append((ch["id"], round(ch["start"], 6), round(ch["duration"], 6),
                        round(d["source_offset"], 6)))
        return out

    def new_group(start, spec):
        """A group of clips: spec = [(lane, offset_from_start)], each bip.wav (0.4 s)."""
        ids = []
        for lane, off in spec:
            o = cmd("object.add", path=BIP, lane=lane, start=start + off)
            ids.append(o["id"])
        g = cmd("group.create", ids=ids)["id"]
        cmd("group.expand", id=g, expanded=True)
        return g, ids

    cmd("project.new")

    # ------------------------------------------------------------------ A. window-only cut
    G, (X, Y) = new_group(10.0, [(0, 0.0), (1, 0.3)])      # X 10..10.4, Y 10.3..10.7
    g0 = listing()[G]
    check("A0 group window is the union", near(g0["start"], 10.0) and near(g0["duration"], 0.7),
          str((g0["start"], g0["duration"])))
    before = snapshot(G)
    check("A0 two children", len(before) == 2, str(before))

    cut =cmd("object.split_at", seconds=10.35, ids=[G], window_only=True)
    pieces = cut["ids"]
    check("A1 the cut gives two groups", len(pieces) == 2, str(cut))
    L = G
    R = [p for p in pieces if p != G][0]
    lst = listing()
    check("A2 left window 10..10.35", near(lst[L]["start"], 10.0) and near(lst[L]["duration"], 0.35),
          str((lst[L]["start"], lst[L]["duration"])))
    check("A2 right window 10.35..10.7", near(lst[R]["start"], 10.35) and near(lst[R]["duration"], 0.35),
          str((lst[R]["start"], lst[R]["duration"])))
    cmd("group.expand", id=R, expanded=True)
    lch, rch = children(L), children(R)
    check("A3 left keeps its children WHOLE (ids, durations)",
          sorted(o["id"] for o in lch) == sorted([X, Y]) and all(near(o["duration"], 0.4) for o in lch),
          str([(o["id"][:4], o["duration"]) for o in lch]))
    check("A3 right has whole copies with NEW ids",
          len(rch) == 2 and all(near(o["duration"], 0.4) for o in rch)
          and not ({o["id"] for o in rch} & {X, Y}),
          str([(o["id"][:4], o["duration"]) for o in rch]))
    check("A3 the copies sit where the originals do",
          sorted(round(o["start"], 6) for o in rch) == sorted(round(o["start"], 6) for o in lch))

    # ------------------------------------------------------------------ B. heal restores the original
    r = cmd("group.heal", ids=[L, R])
    check("B1 one group survives, with the left id", r["merged"] == [L] and r["absorbed"] == [R], str(r))
    lst = listing()
    check("B1 the right piece is gone", R not in lst)
    check("B2 window is the union again", near(lst[L]["start"], 10.0) and near(lst[L]["duration"], 0.7),
          str((lst[L]["start"], lst[L]["duration"])))
    after = snapshot(L)
    check("B3 EXACTLY the original children (ids, starts, durations, offsets)", after == before,
          "\n   before=%s\n   after =%s" % (before, after))
    check("B3 the two copies were glued away", r["glued"] == 2 and len(r["removed_children"]) == 2, str(r))
    cmd("edit.undo")
    lst = listing()
    check("B4 ONE undo gives the two pieces back", L in lst and R in lst
          and near(lst[L]["duration"], 0.35) and near(lst[R]["start"], 10.35),
          str(sorted((v["start"], v["duration"]) for v in lst.values() if v["kind"] == "group")))
    cmd("edit.undo")   # the cut
    lst = listing()
    check("B5 and the cut itself undoes to the whole group",
          R not in lst and near(lst[G]["duration"], 0.7))

    # ------------------------------------------------------------------ C. deep cut, then heal
    pieces = cmd("object.split_at", seconds=10.35, ids=[G])["ids"]
    R2 = [p for p in pieces if p != G][0]
    cmd("group.expand", id=R2, expanded=True)
    lch, rch = children(G), children(R2)
    check("C1 a deep cut distributes the children (halves, not whole)",
          all(o["duration"] < 0.4 - 1e-6 for o in lch + rch), str([(o["duration"]) for o in lch + rch]))
    r = cmd("group.heal", ids=[G, R2])
    after = snapshot(G)
    check("C2 healed: the continuous halves are glued back to whole clips", after == before,
          "\n   before=%s\n   after =%s" % (before, after))
    check("C2 two pairs glued", r["glued"] == 2, str(r))
    cmd("edit.undo")
    cmd("edit.undo")

    # ------------------------------------------------------------------ D. recursion
    # A group holding a sub-group (lane 1) and a clip (lane 0); cut deep through both.
    a = cmd("object.add", path=BIP, lane=2, start=20.0)["id"]
    b = cmd("object.add", path=BIP, lane=3, start=20.1)["id"]
    sub = cmd("group.create", ids=[a, b])["id"]
    top = cmd("object.add", path=BIP, lane=1, start=20.0)["id"]
    P = cmd("group.create", ids=[sub, top])["id"]
    cmd("group.expand", id=P, expanded=True)
    cmd("group.expand", id=sub, expanded=True)
    groups_before = sorted(o["id"] for o in listing().values() if o["kind"] == "group")
    cut = cmd("object.split_at", seconds=20.2, ids=[P])
    P2 = [p for p in cut["ids"] if p != P][0]
    groups_cut = [o for o in listing().values() if o["kind"] == "group"]
    check("D1 the deep cut split the sub-group too", len(groups_cut) == len(groups_before) + 2,
          "%d -> %d groups" % (len(groups_before), len(groups_cut)))
    r = cmd("group.heal", ids=[P, P2])
    groups_after = sorted(o["id"] for o in listing().values() if o["kind"] == "group")
    check("D2 the sub-groups were healed with their parent", groups_after == groups_before,
          "%s vs %s" % (len(groups_after), len(groups_before)))
    cmd("edit.undo")
    cmd("edit.undo")

    # ------------------------------------------------------------------ E. refusals
    G2, _ = new_group(30.0, [(0, 0.0)])
    G3, _ = new_group(31.0, [(0, 0.0)])            # 30..30.4 and 31..31.4: a gap
    # Different parents: one of two jointive groups lives inside another group.
    H1, _ = new_group(40.0, [(0, 0.0)])            # 40..40.4
    inner = cmd("object.add", path=BIP, lane=0, start=40.4)["id"]
    H2 = cmd("group.create", ids=[inner])["id"]    # 40.4..40.8
    partner = cmd("object.add", path=BIP, lane=5, start=40.4)["id"]
    cmd("group.create", ids=[H2, partner])
    # A looping group beside a jointive one.
    K1, _ = new_group(50.0, [(0, 0.0)])
    K2, _ = new_group(50.4, [(0, 0.0)])
    cmd("object.set_loop", id=K1, enabled=True)

    def state():
        return sorted((o["id"], round(o["start"], 6), round(o["duration"], 6), o["parent"])
                      for o in cmd("object.list")["objects"])

    frozen = state()
    e = refused("group.heal", ids=[G])
    check("E1 a lone group is refused", e is not None and e.code == "invalid_state", str(e))
    e = refused("group.heal", ids=[G2, G3])
    check("E2 a gap is refused", e is not None and e.code == "invalid_state", str(e))
    e = refused("group.heal", ids=[H1, H2])
    check("E3 different parents are refused", e is not None and e.code == "invalid_state", str(e))
    e = refused("group.heal", ids=[K1, K2])
    check("E4 a looping group is refused", e is not None and e.code == "invalid_state", str(e))
    check("E5 the refusals touched nothing", state() == frozen)

    # ------------------------------------------------------------------ F. menu and time selection
    M, _ = new_group(60.0, [(0, 0.0)])
    pieces = cmd("object.split_at", seconds=60.2, ids=[M], window_only=True)["ids"]
    M2 = [p for p in pieces if p != M][0]
    cmd("selection.set", ids=[M, M2])
    dry = cmd("selection.context_action", action="heal_groups", dry_run=True)
    check("F1 the menu offers heal_groups on two jointive groups", dry.get("action") == "heal_groups", str(dry))
    # A range that does NOT reach the junction heals nothing; one that covers it does.
    lane = listing()[M]["display_lane"]
    cmd("timesel.set", start=60.05, end=60.15, lanes=[lane])
    e = refused("timesel.heal")
    check("F2 a range that misses the junction heals nothing", e is not None and e.code == "invalid_state", str(e))
    cmd("timesel.set", start=60.1, end=60.3, lanes=[lane])
    r = cmd("timesel.heal")
    check("F3 a range covering the junction heals", r["merged"] == [M], str(r))
    lst = listing()
    check("F3 one group 60..60.4", M2 not in lst and near(lst[M]["duration"], 0.4),
          str(lst.get(M)))

if fails:
    print("\n%d FAILED:" % len(fails))
    for f in fails:
        print("  - " + f)
    sys.exit(1)
print("\nALL PASS")

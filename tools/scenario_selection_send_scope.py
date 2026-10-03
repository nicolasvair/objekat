#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The multiple selection's caches against the reference they replaced — a scenario that ASSERTS.

`parentIDMap()`, `allAuxes`, `sendScope(forSenders:)` and `multiSelectionSnapshot` (what the
inspector reads about a multiple selection) are CACHES: each is dropped by a hook, and a hook that
misses one case answers a stale scope with no symptom. `debug.selection_send_scope` puts the cached
path next to the tree walk it replaced (`_reference…`: no cache, no map, no index) for the LIVE
selection and lists every disagreement. This scenario drives it:

  • ~200 random selections over a project with stems, groups (nested), finite and infinite auxes,
    an aux inside a group, an aux on another stem;
  • and, around each kind of mutation that has to invalidate something, the same question asked
    BEFORE (so the caches are warm), AFTER, after the UNDO and after the REDO: moving an aux, a
    stem assignment, a stem reorder, group.create / disband / eject / reparent, an aux made
    infinite, a deletion, a duplicate, a split, tab.new / tab.select / tab.close, a Save As then
    project.open.

    # 1. a DEBUG build (the command does not exist in Release), headless is enough: nothing here
    #    is drawn. A SHORT socket path (a system limit: 103 bytes).
    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --socket=/tmp/o.sock

    # 2. replay (ROOT: a scratch folder for the Save As, it need not exist yet)
    ./scenario_selection_send_scope.py /tmp/o.sock /tmp/trial_sendscope [--seed 7] [--selections 200]

Exit: 0 if every assertion passes, 1 otherwise.
"""

import argparse, os, random, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

ap = argparse.ArgumentParser()
ap.add_argument("socket")
ap.add_argument("root")
ap.add_argument("--seed", type=int, default=7)
ap.add_argument("--selections", type=int, default=200)
args = ap.parse_args()

rnd = random.Random(args.seed)
BIP = os.path.join(HERE, "fixtures", "bip.wav")
fails = []
total = 0
nontrivial = 0           # selections where at least one aux was in scope
mixed_scope = 0          # …and where the scope differed between senders

c = ObjekatClient(args.socket)
c.connect()


def check(label, ok, detail=""):
    global total
    total += 1
    if not ok:
        print("FAIL  " + label + "   " + str(detail))
        fails.append(label)


def objects():
    return c.send("object.list")["objects"]


def expand_all():
    """Every group open, to any depth (a closed group's children are not in object.list)."""
    for _ in range(6):
        closed = [o["id"] for o in objects() if o["kind"] == "group"]
        changed = False
        for gid in closed:
            r = c.send("group.expand", {"id": gid, "expanded": True})
            changed = changed or r["expanded"]
        if not changed:
            break


def oracle(label, quiet=False):
    global nontrivial, mixed_scope
    r = c.send("debug.selection_send_scope", {"parent_sample": 500})
    check(label, r["ok"], r["mismatches"])
    if r["ok"] and not quiet:
        if r["auxes_in_scope"] > 0:
            nontrivial += 1
    return r


def select(ids):
    c.send("selection.set", {"ids": list(ids)})


def random_selection(pool, lo=1, hi=None):
    hi = hi or min(len(pool), 80)
    return rnd.sample(pool, rnd.randint(min(lo, len(pool)), min(hi, len(pool))))


def pool_ids():
    return [o["id"] for o in objects()]


# ------------------------------------------------------------------------------------------------
# The fixture
# ------------------------------------------------------------------------------------------------
print("fixture")
drums = c.send("stem.add", {"name": "Drums", "color_index": 3})["id"]
fx = c.send("stem.add", {"name": "FX", "color_index": 5})["id"]

adds = []
for lane in range(6):
    for t in range(12):
        adds.append({"cmd": "object.add", "params": {"path": BIP, "lane": lane, "start": t * 1.5 + lane * 0.2}})
c.send("batch", {"commands": adds})
clips = [o["id"] for o in objects() if o["kind"] == "clip"]
check("72 clips laid", len(clips) >= 60, len(clips))

auxes = []
for i, (s, e, lane) in enumerate([(0, 6, 6), (4, 14, 7), (10, 20, 8), (16, 24, 9)]):
    auxes.append(c.send("aux.create", {"start": float(s), "end": float(e), "lane": lane})["id"])
# one aux on another stem, one infinite
c.send("stem.assign", {"stem": drums, "ids": [auxes[1]]})
c.send("object.set_infinite", {"id": auxes[3], "on": True})

# two groups, one holding a sub-group and an aux
g1_members = clips[:10]
g1 = c.send("group.create", {"ids": g1_members})["id"]
g2 = c.send("group.create", {"ids": clips[20:28]})["id"]
expand_all()
sub = c.send("group.create", {"ids": [o["id"] for o in objects() if o["kind"] == "clip" and o["parent"] == g1][:4]})["id"]
expand_all()
aux_in_g = c.send("aux.create", {"start": 1.0, "end": 8.0, "lane": 0})["id"]
c.send("group.reparent", {"ids": [aux_in_g], "group": g1})
expand_all()
c.send("stem.assign", {"stem": fx, "ids": clips[40:50]})

print("  groups:", [(o["id"][:6], (o["parent"] or "-")[:6]) for o in objects() if o["kind"] == "group"], "sub=", sub[:6])
pool = pool_ids()
print("  %d objects, %d groups, %d auxes" % (len(pool), len([o for o in objects() if o["kind"] == "group"]),
                                              len([o for o in objects() if o["kind"] == "aux"])))
select([o['id'] for o in objects() if o['kind'] == 'clip'][:5])
r = oracle("the fixture reads the same both ways")
check("the oracle sees the project", r["objects_total"] >= 60 and r["aux_total"] >= 4, r)

# ------------------------------------------------------------------------------------------------
# Random selections, no mutation (the selection alone must drop the snapshot)
# ------------------------------------------------------------------------------------------------
print("random selections")
for i in range(args.selections):
    pool = pool_ids()
    select(random_selection(pool))
    oracle("random selection #%d" % i)
    if i % 40 == 0:
        # the same selection, asked twice in a row: the second answer comes off the cache
        oracle("the same selection again (cache hit) #%d" % i, quiet=True)
print("  %d of %d selections had an aux in scope" % (nontrivial, args.selections))
check("the random selections exercised the scope", nontrivial >= args.selections // 4, nontrivial)

# ------------------------------------------------------------------------------------------------
# Mutations: before / after / undo / redo
# ------------------------------------------------------------------------------------------------


def around(label, mutate, selection=None, undo=True):
    """Warm the caches on a selection, mutate, ask; undo, ask; redo, ask."""
    pool = pool_ids()
    sel = selection() if callable(selection) else (selection or random_selection(pool, 8, 60))
    select(sel)
    oracle("%s — before (caches warm)" % label)
    try:
        mutate()
    except ObjekatError as e:
        check("%s — the mutation was accepted" % label, False, e)
        return
    oracle("%s — after" % label)
    # the selection may have lost objects to the mutation: warm again on what is left, then mutate nothing
    if undo:
        c.send("edit.undo")
        oracle("%s — after undo" % label)
        c.send("edit.redo")
        oracle("%s — after redo" % label)


print("mutations")
cur_aux = lambda: [o for o in objects() if o["kind"] == "aux"]
top_clips = lambda: [o["id"] for o in objects() if o["kind"] == "clip" and not o["parent"]]

for rep in range(3):
    # an aux moves in time — the overlap changes
    a = rnd.choice(auxes[:3])
    around("move aux in time #%d" % rep, lambda a=a: c.send("object.move", {"id": a, "start": float(rnd.randint(0, 20))}))
    # an aux moves to another lane
    around("move aux to another lane #%d" % rep, lambda a=a: c.send("object.move", {"id": a, "lane": rnd.randint(6, 12)}))

around("assign a sender to a stem", lambda: c.send("stem.assign", {"stem": drums, "ids": rnd.sample(top_clips(), 12)}))
around("assign an aux to the FX stem", lambda: c.send("stem.assign", {"stem": fx, "ids": [auxes[0]]}))
around("assign back to Main", lambda: c.send("stem.assign", {"stem": c.send("stem.list")["main"], "ids": rnd.sample(top_clips(), 10)}))
around("reorder the stems", lambda: c.send("stem.move", {"id": fx, "index": 1}))
around("an aux becomes infinite", lambda: c.send("object.set_infinite", {"id": auxes[0], "on": True}))
around("an aux stops being infinite", lambda: c.send("object.set_infinite", {"id": auxes[3], "on": False}))

# groups: create / disband / eject / reparent
members = lambda: rnd.sample(top_clips(), 6)
made = {}


def create_group():
    made["g"] = c.send("group.create", {"ids": members()})["id"]


around("group.create", create_group)
around("group.reparent into a group", lambda: c.send("group.reparent", {"ids": rnd.sample(top_clips(), 3), "group": g2}))
kids_of = lambda gid: [o["id"] for o in objects() if o["parent"] == gid]
around("group.eject", lambda: c.send("group.eject", {"ids": kids_of(g2)[:2]}))
around("group.disband (the sub-group)", lambda: c.send("group.disband", {"id": sub}))
around("group.disband (a root group)", lambda: c.send("group.disband", {"id": g2}))
expand_all()

# deletion, duplicate, split
around("object.remove an aux", lambda: c.send("object.remove", {"ids": [auxes[2]]}))
around("object.remove clips", lambda: c.send("object.remove", {"ids": rnd.sample(top_clips(), 4)}))
around("object.duplicate", lambda: c.send("object.duplicate", {"ids": rnd.sample(top_clips(), 5)}))
around("object.split_at", lambda: c.send("object.split_at", {"seconds": 6.0, "ids": rnd.sample(top_clips(), 6)}))
expand_all()

# selection edits with the items untouched (⌘-click style growth), warm each time
pool = pool_ids()
sel = set(random_selection(pool, 3, 10))
for _ in range(25):
    select(sel)
    oracle("incremental selection (%d)" % len(sel), quiet=True)
    sel ^= {rnd.choice(pool)}
    if not sel:
        sel = {rnd.choice(pool)}

# ------------------------------------------------------------------------------------------------
# Tabs and reopening: the caches belong to a document, not to the process
# ------------------------------------------------------------------------------------------------
print("tabs and reopening")
pool = pool_ids()
select(random_selection(pool, 8, 40))
oracle("tab — before")
first_tab = c.send("tab.list")
first_id = next(t["id"] for t in first_tab["tabs"] if t.get("active"))
c.send("tab.new")
oracle("tab — a NEW tab (empty, nothing selected)")
c.send("object.add", {"path": BIP, "lane": 0, "start": 0})
c.send("aux.create", {"start": 0.0, "end": 5.0, "lane": 1})
newpool = pool_ids()
select(newpool)
oracle("tab — the new tab holds its own two objects")
c.send("tab.select", {"id": first_id})
oracle("tab — back on the first tab (its selection restored)")
second_id = next(t["id"] for t in c.send("tab.list")["tabs"] if t["id"] != first_id)
c.send("tab.close", {"id": second_id, "discard": True})
oracle("tab — second tab closed")

os.makedirs(args.root, exist_ok=True)
saved = os.path.join(args.root, "sendscope.objekat")
select(random_selection(pool_ids(), 8, 40))
oracle("reopen — before")
c.send("project.save_as", {"path": saved})
c.send("project.open", {"path": saved})
expand_all()
select(random_selection(pool_ids(), 8, 40))
oracle("reopen — after project.open (a brand-new tree)")
for i in range(20):
    select(random_selection(pool_ids()))
    oracle("reopen — random selection #%d" % i, quiet=True)

print("\n%d assertions" % total)
if fails:
    print("%d FAILED:" % len(fails))
    for f in fails[:30]:
        print("  - " + f)
    sys.exit(1)
print("ALL PASS")

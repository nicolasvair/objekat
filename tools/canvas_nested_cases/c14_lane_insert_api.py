#!/usr/bin/env python3
"""c14 — INSERTING between two lanes (the move released in the GAP between two rows, not on a row).
Headless twin of `tools/test_lane_insertion.swift`: it replays the same kind of table through
`debug.move_drop` with `insert_row` (DEBUG build only), which goes through the very function the
drag handler calls on release (`EditViewModel.commitMoveDrop` -> `LaneInsertion.plan`).

The semantics under test (a LIST reorder, not a canvas drop): the lanes BELOW the gap go down by the
number of lanes the selection takes, the lanes the selection empties CLOSE UP, nothing is overwritten,
the comments of the lanes follow the objects, and the whole thing is ONE undo step.

Every clip lives at 0..2 s so that nothing but the lane decides. After EVERY case: the number of
objects is the one expected (+N for a copy), no duration moved, no non-moved object sits on the lanes
the block landed on, ONE `edit.undo` gives back exactly the tree AND the comments from before (the
undo depth went up by exactly one), and a second undo does not replay the gesture.
Usage: c14_...py [socket]
"""
import sys, json, os
sys.path.insert(0, __file__.rsplit('/canvas_nested_cases', 1)[0])
import scenario_canvas_nested as s
from objekat_cli import ObjekatClient

c = ObjekatClient(sys.argv[1] if len(sys.argv) > 1 else '/tmp/cc501/t.sock'); c.connect()
fails = []
def check(label, ok, detail=""):
    print(("ok    " + label) if ok else ("FAIL  " + label + "  " + str(detail)))
    if not ok: fails.append(label)

os.makedirs('/tmp/cc501/nested', exist_ok=True)
W = '/tmp/cc501/nested/depth1.wav'
if not os.path.exists(W): s.write_wav(W, 4.0, 220, 1)

def new_project():
    c.send("project.new"); c.send("project.set_snap", {"enabled": False}); s.settle(c)

def clip(I, n, lane):
    I[n] = c.send("object.add", {"path": W, "lane": lane, "start": 0, "duration": 2})["id"]

def build_root(names=("a", "b", "c", "d")):
    """Root clips on lanes 0..n-1, named in order."""
    new_project()
    I = {}
    for lane, n in enumerate(names): clip(I, n, lane)
    s.settle(c, 300)
    return I

def build_group():
    """G{g0 lane 0, g1 lane 1} at root lane 0 (rows: G 0, g0 1, g1 2, drop row 3), t at root lane 1
    (row 4). Everything is laid at the ROOT while the group is folded, then grouped, then opened:
    `object.add` takes a DISPLAY lane."""
    new_project()
    I = {}
    clip(I, "g0", 0); clip(I, "g1", 1)
    I["G"] = c.send("group.create", {"ids": [I["g0"], I["g1"]]})["id"]
    clip(I, "t", 1)
    c.send("group.expand", {"id": I["G"], "expanded": True})
    s.settle(c, 300)
    return I

def tree(): return s.tree_index(c.send("project.get_state")["items"])
def comments(): return c.send("comment.list")["comments"]
def depth(): return c.send("perf.census").get("undo_depth")
def U(x): return (x or "").upper()

def run(label, I, gid, insert_row, expect, ids=(), alt=False, expect_count_delta=0,
        landed=None, expect_insert=True, comment_ids=None, expect_comments=None):
    """Replays one gesture. `expect`: name -> (parent name or None, lane) for the NAMED objects.
    `landed`: (parent name or None, [lanes]) the block landed on: nobody else may sit there."""
    before_t = tree(); before_items = s.items_state(c); before_comments = json.dumps(comments(), sort_keys=True)
    d0 = depth()
    params = {"id": I[gid], "insert_row": insert_row}
    if ids: params["ids"] = [I[n] for n in ids]
    if alt: params["alt"] = True
    r = c.send("debug.move_drop", params); s.settle(c, 300)
    t = tree()
    ins = r.get("insert")
    if expect_insert:
        check("%s: insert answered (%s)" % (label, r), isinstance(ins, dict), r)
    else:
        check("%s: insert is null, normal drop done (%s)" % (label, r), "insert" in r and ins is None, r)
    for n, (pname, lane) in expect.items():
        got = t.get(I[n])
        ok = got is not None and got['lane'] == lane and U(got['parent']) == U(I[pname] if pname else None)
        check("%s: %s at %s lane %d" % (label, n, pname or "root", lane), ok, got)
    check("%s: object count %d -> %d (expected %+d)" % (label, len(before_t), len(t), expect_count_delta),
          len(t) - len(before_t) == expect_count_delta)
    check("%s: no duration changed" % label,
          all(abs(t[i]['duration'] - v['duration']) < 1e-9 for i, v in before_t.items() if i in t))
    if landed:
        pname, lanes = landed
        named = {I[n] for n in ids} | {I[gid]}
        intruders = [i for i, v in t.items()
                     if U(v['parent']) == U(I[pname] if pname else None) and v['lane'] in lanes
                     and i not in named and (alt is False or i in before_t)]
        # with ⌥ the new copies are the ones that landed: they are the objects absent before
        new_ids = [i for i in t if i not in before_t]
        intruders = [i for i in intruders if i not in new_ids]
        check("%s: nobody else on the landed lanes %s" % (label, lanes), not intruders, intruders)
    if expect_comments is not None:
        got = {cm['id']: cm['lane'] for cm in comments()}
        check("%s: comments %s" % (label, expect_comments),
              all(got.get(comment_ids[n]) == l for n, l in expect_comments.items()), got)
    d1 = depth()
    check("%s: exactly ONE undo point (%s -> %s)" % (label, d0, d1), d1 == d0 + 1, (d0, d1))
    c.send("edit.undo"); s.settle(c, 300)
    check("%s: ONE undo gives the tree back" % label, s.items_state(c) == before_items)
    check("%s: ... and the comments" % label, json.dumps(comments(), sort_keys=True) == before_comments)
    check("%s: the undo stack is back to %s" % (label, d0), depth() == d0, depth())
    c.send("edit.undo"); s.settle(c, 300)
    check("%s: a second undo does not replay the gesture" % label,
          s.items_state(c) != before_items or depth() < d0)
    return r

# S1 — root a0 b1 c2 d3: d into the gap before row 1 (between a and b)
I = build_root()
r = run("S1 d between a and b", I, "d", 1,
        {"a": (None, 0), "d": (None, 1), "b": (None, 2), "c": (None, 3)}, landed=(None, [1]))
check("S1: insert.lane = 1, count = 1 (%s)" % r.get("insert"),
      (r.get("insert") or {}).get("lane") == 1 and (r.get("insert") or {}).get("count") == 1)

# S2 — the same with ⌥: a copy of d lands at 1, the originals are pushed (d included) and kept
I = build_root()
before = tree()
r = run("S2 ⌥ copy of d between a and b", I, "d", 1,
        {"a": (None, 0), "b": (None, 2), "c": (None, 3), "d": (None, 4)}, alt=True, expect_count_delta=1,
        landed=(None, [1]))

# S3 — b and d together, to the very top (before row 0): b0 d1 a2 c3
I = build_root()
r = run("S3 b+d to the top", I, "d", 0,
        {"b": (None, 0), "d": (None, 1), "a": (None, 2), "c": (None, 3)}, ids=("b",), landed=(None, [0, 1]))
check("S3: count = 2 (%s)" % r.get("insert"), (r.get("insert") or {}).get("count") == 2)

# S4 — t from the root into G between g0 and g1 (B = g1's row 2): G g0 0, t 1, g1 2
I = build_group()
run("S4 t into G between g0 and g1", I, "t", 2,
    {"g0": ("G", 0), "t": ("G", 1), "g1": ("G", 2), "G": (None, 0)}, landed=("G", [1]))

# S5 — at the head of the band (B = G's row + 1 = 1): t on lane 0 of G, the children go down
I = build_group()
run("S5 t at the head of G", I, "t", 1,
    {"t": ("G", 0), "g0": ("G", 1), "g1": ("G", 2)}, landed=("G", [0]))

# S6 — g0 ejected into the gap before t (B = 4) at the root: g1 closes up to 0 in G, t goes down
I = build_group()
run("S6 g0 ejected before t", I, "g0", 4,
    {"g0": (None, 1), "t": (None, 2), "g1": ("G", 0), "G": (None, 0)}, landed=(None, [1]))

# S7 — after the last row: nobody below, so no insertion: the normal drop (dl = 0 -> stays on lane 3)
I = build_root()
before_t = tree()
r = c.send("debug.move_drop", {"id": I["d"], "insert_row": 4}); s.settle(c, 300)
t = tree()
check("S7: insert is null after the last row (%s)" % r, "insert" in r and r["insert"] is None, r)
check("S7: normal decision, d stays on lane 3 and nothing else moved (%s)" % r,
      r.get("decision") == "root" and all(t[I[n]]['lane'] == before_t[I[n]]['lane'] for n in "abcd"), r)
c.send("edit.undo"); s.settle(c, 300)

# S7b — inside a piano roll there is no gap either: not tested here (needs a MIDI clip); the pure
# test T5 covers it.

# S8 — a comment on root lane 2 follows the objects: insertion before row 1 pushes it to lane 3
I = build_root()
cid = c.send("comment.create", {"from": 0, "to": 2, "lane": 2, "text": "note"})["comment"]
run("S8 comment pushed with its lane", I, "d", 1,
    {"a": (None, 0), "d": (None, 1), "b": (None, 2), "c": (None, 3)},
    comment_ids={"note": cid}, expect_comments={"note": 3}, landed=(None, [1]))

print("ALL PASS" if not fails else "FAILED: %s" % fails)
sys.exit(1 if fails else 0)

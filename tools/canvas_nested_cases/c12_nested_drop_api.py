#!/usr/bin/env python3
"""c12 — a clip carried to a DEEP group lands where the preview drew it (point D of the 2026-10-02
feedback: dropped into C, itself in B, itself in A, it used to overwrite "as if dropped on A").
Headless twin of `tools/test_nested_drop_target.swift`: it replays the same table through
`debug.move_drop` (DEBUG build only), which calls the very function the drag handler calls on release
(`EditViewModel.commitMoveDrop` -> `MoveDropResolution`).

Scene, A > B > C all open (every clip lives at 0..2 s so that nothing but the lane decides):

    row 0  A (root lane 0)         row 5   Y  (B lane 1)
    row 1    B (A lane 0)          row 6   . B's drop row
    row 2      C (B lane 0)        row 7   X  (A lane 1)
    row 3        Z (C lane 0)      row 8   . A's drop row
    row 4        . C's drop row    row 9 T (root lane 1)

After EVERY gesture: the object is where the table says (parent, lane), A, B and C keep their
duration, the whole tree still holds every object (nothing lost) — except where the drop lands ON a
clip (lane 0 of C = Z), which overwrites it by design, so there the count may drop —, and ONE
`edit.undo` gives the exact pre-gesture tree back. Usage: c12_...py [socket]
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

def build(extra_group=False, x2=False):
    """Everything is laid at the ROOT while the groups are folded, then grouped bottom-up: `object.add`
    takes a DISPLAY lane, so adding under an already open group would land inside / over it."""
    c.send("project.new"); c.send("project.set_snap", {"enabled": False}); s.settle(c)
    I = {}
    def clip(n, lane): I[n] = c.send("object.add", {"path": W, "lane": lane, "start": 0, "duration": 2})["id"]
    clip("z", 0); I["C"] = c.send("group.create", {"ids": [I["z"]]})["id"]
    clip("y", 1); I["B"] = c.send("group.create", {"ids": [I["C"], I["y"]]})["id"]
    clip("x", 1)
    members = [I["B"], I["x"]]
    if x2:            # a second child of A, on lane 2 (below x)
        clip("x2", 2); members.append(I["x2"])
    if extra_group:   # a CLOSED group G in A, below B (rank 2 after the compaction)
        clip("g1", 3); I["G"] = c.send("group.create", {"ids": [I["g1"]]})["id"]; members.append(I["G"])
    I["A"] = c.send("group.create", {"ids": members})["id"]
    clip("t", 1)
    s.settle(c, 300)
    return I

def tree(): return s.tree_index(c.send("project.get_state")["items"])

def open_all(I):
    for n in ("A", "B", "C"):
        c.send("group.expand", {"id": I[n], "expanded": True})
    s.settle(c, 300)

# (label, grabbed, dl, expected parent, expected lane in that frame, expected decision)
CASES = [
    ("T (root) -> C's drop row",              "t", -5, "C", 1, "reparent"),
    ("X (in A, below open B) -> C's drop row", "x", -3, "C", 1, "reparent"),
    ("X (in A, below open B) -> Z's row in C", "x", -4, "C", 0, "reparent"),
    ("Y (in B, below open C) -> C's drop row", "y", -1, "C", 1, "reparent"),
    ("Y (in B, below open C) -> Z's row in C", "y", -2, "C", 0, "reparent"),
    ("T (root) -> B's drop row",              "t", -3, "B", 2, "reparent"),
    ("X (in A) -> B's drop row",              "x", -1, "B", 2, "reparent"),
]

for label, g, dl, parent, lane, decision in CASES:
    I = build(); open_all(I)
    before_t = tree(); before_items = s.items_state(c)
    n_before = len(before_t)
    r = c.send("debug.move_drop", {"id": I[g], "dl": dl}); s.settle(c, 300)
    t = tree()
    check("%s: decision %s into %s lane %d (row %s)" % (label, decision, parent, lane, r.get("row")),
          r.get("decision") == decision and r.get("group", "").upper() == I[parent].upper() and r.get("lane") == lane, r)
    check("%s: the object is a child of %s at lane %d" % (label, parent, lane),
          I[g] in t and (t[I[g]]['parent'] or '').upper() == I[parent].upper() and t[I[g]]['lane'] == lane,
          t.get(I[g]))
    check("%s: A, B and C keep their duration" % label,
          all(abs(t[I[n]]['duration'] - before_t[I[n]]['duration']) < 1e-9 for n in "ABC"),
          [(n, before_t[I[n]]['duration'], t[I[n]]['duration']) for n in "ABC"])
    lost = n_before - len(t)
    # landing on lane 0 of C is landing ON Z (same time): Z is overwritten by design
    check("%s: nothing lost from the tree (%d -> %d objects)" % (label, n_before, len(t)),
          lost <= (1 if lane == 0 else 0), lost)
    c.send("edit.undo"); s.settle(c, 300)
    check("%s: ONE undo gives the tree back" % label, s.items_state(c) == before_items)

# a CLOSED group of A, below the open B, carried into C — the same fault as a clip
I = build(extra_group=True); open_all(I)
before_items = s.items_state(c); bt = tree()
r = c.send("debug.move_drop", {"id": I["G"], "dl": -4}); s.settle(c, 300)
t = tree()
check("G (closed group of A, below open B) -> C: reparent (%s)" % r,
      r.get("decision") == "reparent" and r.get("group", "").upper() == I["C"].upper(), r)
check("G is a child of C; A, B, C keep their duration",
      (t[I["G"]]['parent'] or '').upper() == I["C"].upper()
      and all(abs(t[I[n]]['duration'] - bt[I[n]]['duration']) < 1e-9 for n in "ABC"))
c.send("edit.undo"); s.settle(c, 300)
check("G: ONE undo gives the tree back", s.items_state(c) == before_items)

# a drop on the moved group's OWN band: cancelled, nothing touched, NO undo point pushed
I = build(); open_all(I)
before_items = s.items_state(c)
depth = c.send("project.get_state").get("undo_depth")
r = c.send("debug.move_drop", {"id": I["A"], "dl": 3}); s.settle(c, 200)
check("root A dropped onto its own band: cancel, tree untouched (%s)" % r,
      r.get("decision") == "cancel" and s.items_state(c) == before_items, r)

# dl = 0 (let go without moving) keeps every object on its own lane, wherever it sits
I = build(); open_all(I)
before_t = tree()
for n in ("x", "y", "z"):
    r = c.send("debug.move_drop", {"id": I[n], "dl": 0}); s.settle(c, 100)
t = tree()
check("dl = 0 keeps X, Y, Z on their lanes and in their groups",
      all(t[I[n]]['lane'] == before_t[I[n]]['lane'] and t[I[n]]['parent'] == before_t[I[n]]['parent'] for n in "xyz"),
      [(n, before_t[I[n]]['lane'], t[I[n]]['lane']) for n in "xyz"])

# two selected children on either side of an open sub-group move TOGETHER keeping their model gap:
# X (A lane 1) and a second child of A on lane 2, carried onto C's drop row
I = build(x2=True); open_all(I)
before_items = s.items_state(c)
t0 = tree()
r = c.send("debug.move_drop", {"id": I["x"], "ids": [I["x2"]], "dl": -3}); s.settle(c, 300)
t = tree()
check("two children of A (lanes %s, %s) -> C: both in C, gap kept (%s)" % (t0[I["x"]]['lane'], t0[I["x2"]]['lane'], r),
      all((t[I[n]]['parent'] or '').upper() == I["C"].upper() for n in ("x", "x2"))
      and t[I["x2"]]['lane'] - t[I["x"]]['lane'] == t0[I["x2"]]['lane'] - t0[I["x"]]['lane'],
      {n: (t[I[n]]['parent'], t[I[n]]['lane']) for n in ("x", "x2")})
c.send("edit.undo"); s.settle(c, 300)
check("two children: ONE undo gives the tree back", s.items_state(c) == before_items)

print("ALL PASS" if not fails else "FAILED: %s" % fails)
sys.exit(1 if fails else 0)

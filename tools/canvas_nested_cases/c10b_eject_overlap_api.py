#!/usr/bin/env python3
"""c10b — the headless twin of c10 (the API door `group.eject`, which calls the SAME `ejectFromGroup` as the
hand's drop): B1 (child of G2, 1..7 s) is brought up to root lane 15, where the CLOSED group G9 (4..6.5 s)
sits. A pose overwrites (the rule of reparent / same-level move / ⌥-eject): G9 lies entirely under B1, so it
goes, and B1 is alone on the lane. ONE `edit.undo` gives the whole scene back (items byte-identical).
A second case ejects C1 (2..6 s) onto the lane of the root clip P1 (0..3 s): P1 is trimmed to 0..2, C1 stays whole.
Before the fix: both objects kept their full extent, superposed. Usage: c10b_eject_overlap_api.py [socket]"""
import sys, json
sys.path.insert(0, __file__.rsplit('/canvas_nested_cases', 1)[0])
import scenario_canvas_nested as s
from objekat_cli import ObjekatClient
c = ObjekatClient(sys.argv[1] if len(sys.argv) > 1 else '/tmp/cc501/t.sock'); c.connect()
sc = json.load(open('/tmp/cc501/nested/scene.json')); I = sc['ids']
fails = []
def check(label, ok, detail=""):
    print(("ok    " if ok else "FAIL  ") + label + ("" if ok else "  " + str(detail)))
    if not ok: fails.append(label)

def root(c):
    return {o['id']: o for o in c.send('object.list')['objects'] if o['depth'] == 0}

# ── case 1: B1 over the closed group G9 (lane 15) ───────────────────────────────────────────────
s.open_scene(c, sc)
for g in ("G5", "G8", "G3"): c.send("group.expand", {"id": I[g], "expanded": False})
before = s.items_state(c)
undo_depth = len(json.loads(before))
c.send("group.eject", {"ids": [I['B1']], "lane": 15}); s.settle(c, 500)
tree = s.tree_index(c.send("project.get_state")["items"])
b1 = tree[I['B1']]
check("c1: B1 is at the root, lane 15, 1..7 s", b1['parent'] is None and b1['lane'] == 15
      and abs(b1['start'] - 1) < 1e-6 and abs(b1['duration'] - 6) < 1e-6, b1)
check("c1: G9 (4..6.5, fully covered) overwritten, with its children", I['G9'] not in tree
      and I['Q1'] not in tree and I['Q2'] not in tree, [k for k in ('G9', 'Q1', 'Q2') if I[k] in tree])
others = [i for i, v in tree.items() if v['parent'] is None and v['lane'] == 15]
check("c1: nobody else on root lane 15", others == [I['B1']], others)
c.send("edit.undo"); s.settle(c, 500)
check("c1: ONE undo gives the whole scene back", s.items_state(c) == before)

# ── case 2: C1 (2..6 s, depth 3) over the root clip P1 (0..3 s, lane 14) ────────────────────────
s.open_scene(c, sc)
for g in ("G5", "G8"): c.send("group.expand", {"id": I[g], "expanded": False})
before = s.items_state(c)
c.send("group.eject", {"ids": [I['C1']], "lane": 14}); s.settle(c, 500)
tree = s.tree_index(c.send("project.get_state")["items"])
c1, p1 = tree[I['C1']], tree[I['P1']]
check("c2: C1 at the root, lane 14, whole (2..6 s)", c1['parent'] is None and c1['lane'] == 14
      and abs(c1['start'] - 2) < 1e-6 and abs(c1['duration'] - 4) < 1e-6, c1)
check("c2: P1 trimmed to 0..2 s (its end gave way)", abs(p1['start']) < 1e-6 and abs(p1['duration'] - 2) < 1e-6, p1)
c.send("edit.undo"); s.settle(c, 500)
check("c2: ONE undo gives the whole scene back", s.items_state(c) == before)
print("ALL PASS" if not fails else "FAILED: %s" % fails)
sys.exit(1 if fails else 0)

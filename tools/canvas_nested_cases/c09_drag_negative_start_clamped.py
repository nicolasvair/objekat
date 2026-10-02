#!/usr/bin/env python3
"""c09 — REAL DRAG (input.drag; needs an UNLOCKED screen, the window key) of child N1 (G5, start -2 s) by
+50 px at 50 pps (= +1 s): it lands at -1 (the rule: clamped at 0 except inside a group — the GROUP is the
clamped one; ZeroClamp.swift). Before: `max(0, anchor.start + dt)` and the drag wall forced +2 s -> 0.
Then ONE edit.undo gives the tree back, and G5 never moved. Usage: c09_...py [socket]"""
import sys, json
sys.path.insert(0, __file__.rsplit('/canvas_nested_cases', 1)[0])
import scenario_canvas_nested as s
from objekat_cli import ObjekatClient
c = ObjekatClient(sys.argv[1] if len(sys.argv) > 1 else '/tmp/cc501/t.sock'); c.connect()
sc = json.load(open('/tmp/cc501/nested/scene.json')); I = sc['ids']
s.open_scene(c, sc); c.send("view.reveal", {"ids": [I['N1']]}); s.settle(c, 400)
before = s.items_state(c)
x, y = s.find_zone(c, I['N1'], "move")
c.send("input.drag", {"x": x, "y": y, "dx": 50, "dy": 0, "duration_ms": 500})
s.settle(c, 500)
t = s.tree_index(c.send("project.get_state")["items"])
ok = abs(t[I['N1']]["start"] + 1) < 1e-6 and abs(t[I['G5']]["start"]) < 1e-6
print("N1 start after drag:", t[I['N1']]["start"], "G5:", t[I['G5']]["start"], "(expected -1 and 0)")
c.send("edit.undo"); s.settle(c, 400)
ok2 = s.items_state(c) == before
print("ONE undo gives the tree back:", ok2)
print("ALL PASS" if ok and ok2 else "FAILED"); sys.exit(0 if ok and ok2 else 1)

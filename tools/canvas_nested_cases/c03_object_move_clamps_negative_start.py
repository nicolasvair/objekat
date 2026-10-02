#!/usr/bin/env python3
"""c03 — the rule "clamped at zero, EXCEPT inside a group: then the GROUP is clamped, and its objects may
start before 0" (ZeroClamp.swift), through the API door (`object.move`, `object.trim`). Run after
`scenario_canvas_nested.py build`. Usage: c03_object_move_clamps_negative_start.py [socket]

  child N1 (G5, start -2) +1 s            -> -1 (it was clamped to 0 before); G5 stays at 0
  child N1 to -5                          -> -5 (no wall); G5 stays at 0
  root clip P1 to -1                      -> 0  (a root object keeps its wall)
  root group G5 +1 s then back to -3      -> G5 1 then 0 (the group is the clamped one); its children
                                             follow by the distance the GROUP really travelled
  child N1 trimmed at -1 (head cropped)   -> start -1 (was 0)
each followed by ONE edit.undo that gives the whole tree back."""
import sys, json
sys.path.insert(0, __file__.rsplit('/canvas_nested_cases', 1)[0])
import scenario_canvas_nested as s
from objekat_cli import ObjekatClient
c = ObjekatClient(sys.argv[1] if len(sys.argv) > 1 else '/tmp/cc501/t.sock'); c.connect()
sc = json.load(open('/tmp/cc501/nested/scene.json')); I = sc['ids']
fails = []
def check(label, ok, detail=""):
    print(("ok    " + label) if ok else ("FAIL  " + label + "  " + str(detail)))
    if not ok: fails.append(label)
def st(name):
    return c.send("object.get", {"id": I[name]})["start"]
def near(a, b): return abs(a - b) < 1e-6

s.open_scene(c, sc)
base = s.items_state(c)

c.send("object.move", {"id": I['N1'], "start": st('N1') + 1}); s.settle(c, 300)
check("child N1 -2 + 1 s lands at -1", near(st('N1'), -1), st('N1'))
check("... and its group G5 has not moved", near(st('G5'), 0), st('G5'))
c.send("edit.undo"); s.settle(c, 300)
check("... ONE undo gives the tree back", s.items_state(c) == base)

c.send("object.move", {"id": I['N1'], "start": -5}); s.settle(c, 300)
check("child N1 to -5 stays at -5 (no wall)", near(st('N1'), -5), st('N1'))
check("... G5 still at 0", near(st('G5'), 0), st('G5'))
c.send("edit.undo"); s.settle(c, 300)
check("... ONE undo", s.items_state(c) == base)

c.send("object.move", {"id": I['P1'], "start": -1}); s.settle(c, 300)
check("root clip P1 to -1 is clamped to 0", near(st('P1'), 0), st('P1'))
check("... which moved nothing, so left NO undo step", s.items_state(c) == base)

c.send("object.move", {"id": I['G5'], "start": 1}); s.settle(c, 300)
check("root group G5 +1 s -> 1, children carried (N1 -1)", near(st('G5'), 1) and near(st('N1'), -1),
      (st('G5'), st('N1')))
c.send("object.move", {"id": I['G5'], "start": -3}); s.settle(c, 300)
check("root group G5 to -3: the GROUP stops at 0", near(st('G5'), 0), st('G5'))
check("... children followed the real travel (N1 -2 again)", near(st('N1'), -2), st('N1'))
c.send("edit.undo"); s.settle(c, 300); c.send("edit.undo"); s.settle(c, 300)
check("... two undos give the tree back", s.items_state(c) == base)

c.send("object.trim", {"id": I['N1'], "start": -1, "duration": 3}); s.settle(c, 300)
o = c.send("object.get", {"id": I['N1']})
check("child N1 trimmed at -1: start -1, 3 s long", near(o['start'], -1) and near(o['duration'], 3), o)
c.send("edit.undo"); s.settle(c, 300)
check("... ONE undo", s.items_state(c) == base)
print("ALL PASS" if not fails else "FAILED: %s" % fails)
sys.exit(1 if fails else 0)

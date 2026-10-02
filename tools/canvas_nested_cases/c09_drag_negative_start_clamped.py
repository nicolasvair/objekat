#!/usr/bin/env python3
"""c09 — REAL DRAG (input.drag) of child N1 (start -2 s) by +50 px at 50 pps (=+1 s) lands at 0, expected -1
(+2 s moved). Cause by reading: TimelineView+DragHandler.swift:~1392 `let newStart = max(0, anchor.start + dt)`.
Same clamp as c03 (object.move). Pre-existing (not Canvas-related: the commit/release path is shared)."""
import sys, json
sys.path.insert(0, __file__.rsplit('/canvas_nested_cases', 1)[0])
import scenario_canvas_nested as s
from objekat_cli import ObjekatClient
c = ObjekatClient(sys.argv[1]); c.connect()
sc = json.load(open('/tmp/cc501/nested/scene.json')); I = sc['ids']
s.open_scene(c, sc); c.send("view.reveal", {"ids": [I['N1']]}); s.settle(c, 400)
x, y = s.find_zone(c, I['N1'], "move")
c.send("input.drag", {"x": x, "y": y, "dx": 50, "dy": 0, "duration_ms": 500})
s.settle(c, 500)
print("N1 start after drag:", s.tree_index(c.send("project.get_state")["items"])[I['N1']]["start"], "(expected -1)")

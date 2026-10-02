#!/usr/bin/env python3
"""c03 — object.move of a child at start -2 s by +1 s lands at 0 (expected -1): updateStartTime
clamps `max(0, ...)` (EditViewModel+Edit.swift:101). API door; the hand's drag path is NOT verified
(window not key). Run after `scenario_canvas_nested.py build`. Expected: start == -1; observed 0."""
import sys, json
sys.path.insert(0, __file__.rsplit('/canvas_nested_cases', 1)[0])
import scenario_canvas_nested as s
from objekat_cli import ObjekatClient
c = ObjekatClient(sys.argv[1]); c.connect()
sc = json.load(open('/tmp/cc501/nested/scene.json')); I = sc['ids']
s.open_scene(c, sc)
o = c.send("object.get", {"id": I['N1']}); print("before", o["start"])
c.send("object.move", {"id": I['N1'], "start": o["start"] + 1})
print("after", c.send("object.get", {"id": I['N1']})["start"], "(expected -1)")

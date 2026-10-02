#!/usr/bin/env python3
"""c10 — REAL DRAG of B1 (child of G2, 1..7 s) onto the lane of CLOSED root group G9 (4..6.5 s): B1 is ejected to root
lane 15 and OVERLAPS G9 on the same lane, nothing resolved (both keep 1..7 / 4..6.5). `ejectFromGroup`
(EditViewModel+Groups.swift:688) never calls resolveOverlaps; the handler's eject branch (DragHandler ~1382) neither.
Pre-existing (code of 2026-06/09), not Canvas. Setup: G5,G8,G3 collapsed, block_height 16 so both are visible."""
import sys, json
sys.path.insert(0, __file__.rsplit('/canvas_nested_cases', 1)[0])
import scenario_canvas_nested as s
from objekat_cli import ObjekatClient
c = ObjekatClient(sys.argv[1]); c.connect()
sc = json.load(open('/tmp/cc501/nested/scene.json')); I = sc['ids']
s.open_scene(c, sc)
for g in ("G5","G8","G3"): c.send("group.expand", {"id": I[g], "expanded": False})
c.send("view.set", {"pps": 50, "block_height": 16, "scroll_x": 0, "scroll_y": 0}); s.settle(c, 500)
c.send("view.reveal", {"ids": [I['B1']]}); s.settle(c, 300); g = s.geometry(c)
x, y = s.find_zone(c, I['B1'], "move"); _, ty, _, _ = s.block_rect(c, I['G9'], g)
c.send("input.drag", {"x": x, "y": y, "dx": 0, "dy": ty + g['bh']*0.75 - y, "duration_ms": 500}); s.settle(c, 700)
print([(o['id'][:4], o['start'], o['duration'], o['lane']) for o in c.send('object.list')['objects'] if o['depth'] == 0 and o['lane'] == 15])

#!/usr/bin/env python3
"""c02 — the part of a child that sticks out of its group's window (out-of-range veil) answers NOTHING.
Scene: G2's window is 1..5 s, its child B1 lasts 1..7 s. Hovering B1 at 2 s and 4.5 s (inside) reads B1;
at 6 s and 6.9 s (under the veil) it must read nobody (before the fix: B1, with its move zone and cursor).
B1's left edge is INSIDE the window: its trim-left handle keeps working; its right edge (7 s) is under the
veil: no resize handle there. With the screen unlocked, a drag on the veiled part is tried
too (it must not move B1 nor select it). Usage: c02_...py [socket]"""
import sys, json
sys.path.insert(0, __file__.rsplit('/canvas_nested_cases', 1)[0])
import scenario_canvas_nested as s
from objekat_cli import ObjekatClient, ObjekatError
c = ObjekatClient(sys.argv[1] if len(sys.argv) > 1 else '/tmp/cc501/t.sock', timeout=300); c.connect()
sc = json.load(open('/tmp/cc501/nested/scene.json')); I = sc['ids']
fails = []
def check(label, ok, detail=""):
    print(("ok    " + label) if ok else ("FAIL  " + label + "  " + str(detail)))
    if not ok: fails.append(label)
s.open_scene(c, sc)
c.send("view.reveal", {"ids": [I['B1']]}); s.settle(c, 300)
g = s.geometry(c)
x, y, w, h = s.block_rect(c, I['B1'], g)
yy = y + h * 0.75
def hov(t, dx=0.0):
    c.send("input.hover", {"x": t * g['pps'] - g['sx'] + dx, "y": yy})
    return c.send("view.state.hover")
def is_b1(hv): return (hv.get("hovered_id") or "").upper() == I['B1'].upper()
for t in (2, 4.5):
    hv = hov(t); check("t=%.1f s (inside the window): B1 hovered, zone %s" % (t, hv.get("zone")), is_b1(hv), hv)
for t in (6, 6.9):
    hv = hov(t); check("t=%.1f s (under the veil): nobody hovered" % t, not hv.get("hovered_id") and not hv.get("zone"), hv)
hv = hov(1, 3); check("left edge (inside the window): trim handle still there", is_b1(hv) and hv.get("zone") == "trimLeft", hv)
hv = hov(7, -3); check("right edge (under the veil): no resize handle", not is_b1(hv), hv)
# the same masked hover with another tool (cut: no cut line on the veil)
c.send("tool.set", {"tool": "cut"})
hv = hov(6); check("cut tool, under the veil: no cut hover", not is_b1(hv) and not hv.get("cut_hover"), hv)
c.send("tool.set", {"tool": "selection"})
# click / drag on the veil (real mouse events: need the window key, i.e. an unlocked screen)
try:
    before = s.items_state(c)
    c.send("selection.clear")
    c.send("input.drag", {"x": 6 * g['pps'] - g['sx'], "y": yy, "dx": 50, "dy": 0, "duration_ms": 400}); s.settle(c, 400)
    check("drag under the veil moves nothing", s.items_state(c) == before)
    check("... and selects nothing of B1", I['B1'].upper() not in json.dumps(c.send("selection.get")).upper())
except Exception as e:
    print("SKIP  real click/drag (%s)" % str(e)[:140])
print("ALL PASS" if not fails else "FAILED: %s" % fails)
sys.exit(1 if fails else 0)

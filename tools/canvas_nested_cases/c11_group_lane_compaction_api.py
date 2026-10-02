#!/usr/bin/env python3
"""c11 — grouping brings the children's lanes back to 0, 1, 2 (no holes): objects on lanes 1, 3, 6 become
relative lanes 0, 1, 2; two objects sharing a lane (3) still share their relative lane (1); the order is kept.
Three doors, each followed by ONE `edit.undo` that gives the whole tree back, and invariants checked after the
grouping (gain, pan, name, file, the send towards an aux):
  1. group.create on root objects          2. timesel.group (a time selection over lanes 1, 3, 6)
  3. group.create on two children of one group (the sub-group's lanes) — scene G2 > B1 (lane 0), L1 (lane 5)
Before the fix the children kept 0, 2, 5 (and 0, 5 in the sub-group). `ungroup` is NOT asserted to restore the
holes (it restores group lane + the compacted lanes). Usage: c11_...py [socket]"""
import sys, json, os
sys.path.insert(0, __file__.rsplit('/canvas_nested_cases', 1)[0])
import scenario_canvas_nested as s
from objekat_cli import ObjekatClient
c = ObjekatClient(sys.argv[1] if len(sys.argv) > 1 else '/tmp/cc501/t.sock'); c.connect()
fails = []
def check(label, ok, detail=""):
    print(("ok    " + label) if ok else ("FAIL  " + label + "  " + str(detail)))
    if not ok: fails.append(label)

W = '/tmp/cc501/nested/depth1.wav'
def build():
    c.send("project.new"); c.send("project.set_snap", {"enabled": False}); s.settle(c)
    ids = {}
    for n, lane, st, du in (("a", 1, 0, 2), ("b", 3, 1, 2), ("c", 6, 2, 2), ("d", 3, 3.5, 1.5)):
        ids[n] = c.send("object.add", {"path": W, "lane": lane, "start": st, "duration": du})["id"]
    ids["aux"] = c.send("aux.create", {"start": 0, "end": 6, "lane": 9})["id"]
    c.send("object.set_gain", {"ids": [ids["a"]], "db": -6})
    c.send("object.set_pan", {"ids": [ids["b"]], "pan": 0.5})
    c.send("object.rename", {"id": ids["c"], "name": "ccc"})
    c.send("send.set_level", {"id": ids["a"], "aux": ids["aux"], "db": -12}); s.settle(c, 300)
    return ids

def lanes(ids, names):
    t = s.tree_index(c.send("project.get_state")["items"])
    return {n: t[ids[n]]['lane'] for n in names}, t

def invariants(ids, tag, group):
    c.send("group.expand", {"id": group, "expanded": True}); s.settle(c, 200)   # object.get reads the open tree
    a = c.send("object.get", {"id": ids["a"]}); b = c.send("object.get", {"id": ids["b"]})
    cc = c.send("object.get", {"id": ids["c"]})
    sends = c.send("send.list", {"id": ids["a"]})["sends"]
    check(tag + ": gain / pan / name / file kept",
          abs(a["volume_db"] + 6) < 1e-6 and abs(b["pan"] - 0.5) < 1e-6 and cc["name"] == "ccc" and a["file"] == W,
          (a["volume_db"], b["pan"], cc["name"]))
    check(tag + ": the send of `a` towards the aux kept (-12 dB)",
          len(sends) == 1 and sends[0]["aux"].upper() == ids["aux"].upper() and abs(sends[0]["level_db"] + 12) < 1e-6, sends)

# ── 1. group.create on root objects ────────────────────────────────────────────────────────────
ids = build(); before = s.items_state(c)
g = c.send("group.create", {"ids": [ids[n] for n in "abcd"]})["id"]; s.settle(c, 300)
ln, t = lanes(ids, "abcd")
check("1: lanes 1, 3, 6, 3 -> 0, 1, 2, 1", ln == {"a": 0, "b": 1, "c": 2, "d": 1}, ln)
check("1: all four are children of the new group", all(t[ids[n]]['parent'] == g for n in "abcd"))
invariants(ids, "1", g)
c.send("edit.undo"); s.settle(c, 300)
check("1: ONE undo gives the tree back (original lanes 1, 3, 6, 3)", s.items_state(c) == before
      and lanes(ids, "abcd")[0] == {"a": 1, "b": 3, "c": 6, "d": 3})

# ── 2. time selection over lanes 1, 3, 6 ──────────────────────────────────────────────────────
c.send("timesel.set", {"start": 0, "end": 5.5, "lanes": [1, 3, 6]})
g = c.send("timesel.group")["id"]; s.settle(c, 300)
ln, t = lanes(ids, "abcd")
check("2: time selection -> lanes 0, 1, 2, 1", ln == {"a": 0, "b": 1, "c": 2, "d": 1}, ln)
check("2: all four children of the new group", all(t[ids[n]]['parent'] == g for n in "abcd"), {n: t[ids[n]]['parent'] for n in "abcd"})
invariants(ids, "2", g)
c.send("edit.undo"); s.settle(c, 300)
check("2: ONE undo gives the tree back", s.items_state(c) == before)

# ── 3. a sub-group inside a group: B1 (lane 0) + L1 (lane 5) of G2 ───────────────────────────
sc = json.load(open('/tmp/cc501/nested/scene.json')); I = sc['ids']
s.open_scene(c, sc); before = s.items_state(c)
sg = c.send("group.create", {"ids": [I['B1'], I['L1']]})["id"]; s.settle(c, 300)
t = s.tree_index(c.send("project.get_state")["items"])
check("3: sub-group lanes 0 and 5 -> 0 and 1", t[I['B1']]['lane'] == 0 and t[I['L1']]['lane'] == 1,
      (t[I['B1']]['lane'], t[I['L1']]['lane']))
check("3: both inside the new sub-group, which sits in G2", t[I['B1']]['parent'] == sg and t[sg]['parent'] == I['G2'])
c.send("edit.undo"); s.settle(c, 300)
check("3: ONE undo gives the tree back", s.items_state(c) == before)
print("ALL PASS" if not fails else "FAILED: %s" % fails)
sys.exit(1 if fails else 0)

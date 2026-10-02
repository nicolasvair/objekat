#!/usr/bin/env python3
"""c13 — a crossfade DRAG lays its frame down in ONE batch (point A of the 2026-10-02 feedback: "it lags
WHILE I drag a crossfade").

`debug.crossfade_drag` (DEBUG build only) calls the very per-frame function the gesture calls
(`EditViewModel.driveCrossfadeFrame`) with a list of travels, and answers what it cost in OPERATIONS
(`items_writes`, `lane_entries_rebuilds`, both O(N) per rebuild) — a count, not a clock. `batched: false`
is the way it was laid before the fix: one write at a time, one `rebuildLaneEntries` each.

Part 1 — equivalence on random layouts: for N seeded scenes (several lanes, chains of crossfaded clips,
random widths, random part / crop band / bend / ⌥ / travels including past the shut seam and past the
other side), the model after the UNBATCHED drag and after the BATCHED one are byte for byte the same
(`project.get_state` items, and `crossfade.list`), and one `edit.undo` gives the start back, each time.

Part 2 — cost on a big scene (fillers on other lanes), with 1, 3 and every zone following: rebuilds per
frame must be 1 whatever the number of zones, and the writes per frame, the rebuilds and the
milliseconds are printed before (unbatched) / after (batched).

Usage: c13_...py [socket]
"""
import sys, os, json, random
sys.path.insert(0, __file__.rsplit('/canvas_nested_cases', 1)[0])
import scenario_canvas_nested as s
from objekat_cli import ObjekatClient

c = ObjekatClient(sys.argv[1] if len(sys.argv) > 1 else '/tmp/cc501/t.sock'); c.connect()
fails = []
def check(label, ok, detail=""):
    print(("ok    " + label) if ok else ("FAIL  " + label + "  " + str(detail)))
    if not ok: fails.append(label)

HERE = __file__.rsplit('/canvas_nested_cases', 1)[0]
BIP = os.path.join(HERE, "fixtures", "bip.wav")
D = 0.4

def chain(lane, n, x0, width, ids_out):
    """`n` clips butted along `lane`, 0.2 D of file hidden behind both edges of each (opening a seam
    re-exposes hidden matter), then every seam opened to `width`. Laid far away first, then moved: an
    object dropped on a neighbour overwrites it."""
    ids = []
    for i in range(n):
        home = 1000 + 3 * (lane * 40 + i)
        o = c.send("object.add", {"path": BIP, "lane": lane, "start": home})["id"]
        c.send("object.trim", {"id": o, "start": home + 0.2 * D, "duration": 0.6 * D})
        c.send("object.move", {"id": o, "start": x0 + i * 0.6 * D})
        ids.append(o)
    for i in range(n - 1):
        c.send("crossfade.open", {"left": ids[i], "right": ids[i + 1], "width": width})
    ids_out.extend(ids)

def state(): return json.dumps(c.send("project.get_state")["items"], sort_keys=True)
def zones(): return c.send("crossfade.list")["crossfades"]

PARTS = ["both", "move", "sideStart", "sideEnd"]

def random_drag(rnd, zs):
    part = rnd.choice(PARTS)
    k = rnd.randint(1, len(zs))
    chosen = rnd.sample(zs, k)
    chosen.sort(key=lambda z: z["start"])
    # the grabbed zone must be the first of the list (the command takes `lefts[0]` as the grabbed one)
    rnd.shuffle(chosen)
    frames = rnd.randint(4, 12)
    travel = rnd.choice([0.04, 0.12, 0.3])
    dxs, x = [], 0.0
    for _ in range(frames):
        x += rnd.uniform(-travel, travel)
        dxs.append(x)
    prm = {"lefts": [z["left"] for z in chosen], "rights": [z["right"] for z in chosen],
           "part": part, "dx": dxs, "via_edge_band": part in ("sideStart", "sideEnd") and rnd.random() < 0.4}
    if part == "both":
        prm["overshoot_y"] = rnd.choice([0, 0, 25, -40, 90])
        prm["s_curve"] = rnd.random() < 0.3
    return prm

# ---------------------------------------------------------------- part 1: equivalence
N_SCENES = 14
for seed in range(N_SCENES):
    rnd = random.Random(seed)
    c.send("project.new"); c.send("project.set_snap", {"enabled": False}); s.settle(c, 100)
    ids = []
    for lane in range(rnd.randint(1, 4)):
        chain(lane, rnd.randint(2, 5), rnd.choice([0, 0.3, 2.0]), rnd.choice([0.05, 0.08, 0.12]), ids)
    s.settle(c, 150)
    zs = zones()
    if not zs:
        check("seed %d: scene has crossfades" % seed, False); continue
    start = state(); zs0 = json.dumps(zs, sort_keys=True)
    ok = True
    for rep in range(3):                       # three random drags per scene, one after the other
        zs = zones()
        if not zs: break
        prm = random_drag(rnd, zs)
        before = state()
        ru = c.send("debug.crossfade_drag", dict(prm, batched=False))
        su, zu = state(), json.dumps(zones(), sort_keys=True)
        if ru["undo_pushes"]: c.send("edit.undo"); s.settle(c, 60)
        undone = state()
        rb = c.send("debug.crossfade_drag", dict(prm, batched=True))
        sb, zb = state(), json.dumps(zones(), sort_keys=True)
        if rb["undo_pushes"]: c.send("edit.undo"); s.settle(c, 60)
        undone_b = state()
        label = "seed %d drag %d (%s, %d zone(s), %d frames%s)" % (
            seed, rep, prm["part"], len(prm["lefts"]), len(prm["dx"]),
            ", crop band" if prm["via_edge_band"] else "")
        check(label + ": batched == unbatched, octet for octet (model)", su == sb,
              "differs" if su != sb else "")
        check(label + ": same crossfades afterwards", zu == zb)
        check(label + ": ONE undo each (%s / %s points) restores the start" % (ru["undo_pushes"], rb["undo_pushes"]),
              ru["undo_pushes"] == rb["undo_pushes"] and ru["undo_pushes"] in (0, 1)
              and undone == before and undone_b == before)
        check(label + ": batched costs 1 rebuild per frame at most (%s)" % rb["rebuilds_per_frame"],
              rb["rebuilds_per_frame"] <= 1.0 + 1e-9, rb)
        # leave the scene changed for the next drag of the same scene (re-run batched, keep it)
        c.send("debug.crossfade_drag", dict(prm, batched=True)); s.settle(c, 60)

# ---------------------------------------------------------------- part 2: cost on a big scene
def big_scene(fillers_lanes=30, per_lane=14):
    c.send("project.new"); c.send("project.set_snap", {"enabled": False}); s.settle(c, 100)
    ids = []
    for lane in range(6):                      # six chains of 5 clips = 24 zones
        chain(lane, 5, 0, 0.08, ids)
    W = os.path.join(HERE, "fixtures", "bip.wav")
    for lane in range(6, 6 + fillers_lanes):   # fillers: the N that every rebuild walks
        for i in range(per_lane):
            c.send("object.add", {"path": W, "lane": lane, "start": i * 0.5})
    s.settle(c, 400)
    return ids

big_scene()
n_objs = c.send("perf.census")["objects_total"]
zs = sorted(zones(), key=lambda z: (z["lane"], z["start"]))
print("big scene: %d objects, %d zones" % (n_objs, len(zs)))
FR = [0.01 * i for i in range(1, 21)]          # 20 frames, 0 .. 0.2 s of travel
print("%-8s %-10s %12s %14s %12s %12s" % ("zones", "laying", "writes/frame", "rebuilds/frame", "ms/frame", "undo points"))
rows = {}
for k in (1, 3, len(zs)):
    group = zs[:k]
    for batched in (False, True):
        r = c.send("debug.crossfade_drag", {"lefts": [z["left"] for z in group], "rights": [z["right"] for z in group],
                                            "part": "move", "dx": FR, "batched": batched})
        c.send("edit.undo"); s.settle(c, 60)
        rows[(k, batched)] = r
        print("%-8d %-10s %12.1f %14.2f %12.2f %12d" % (k, "batched" if batched else "one by one",
              r["writes_per_frame"], r["rebuilds_per_frame"], r["ms_per_frame"], r["undo_pushes"]))
    check("%d zone(s): batched is 1 rebuild per frame, whatever the zone count" % k,
          abs(rows[(k, True)]["rebuilds_per_frame"] - 1.0) < 1e-9, rows[(k, True)])
    check("%d zone(s): rebuilds per frame divided (%.1f -> %.1f)" % (k, rows[(k, False)]["rebuilds_per_frame"], rows[(k, True)]["rebuilds_per_frame"]),
          rows[(k, True)]["rebuilds_per_frame"] < rows[(k, False)]["rebuilds_per_frame"])

print("ALL PASS" if not fails else "FAILED: %s" % fails)
sys.exit(1 if fails else 0)

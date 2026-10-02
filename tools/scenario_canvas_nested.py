#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Nested groups (3-4 levels) under the batched Canvas: a scene, pictures, drags — for the test plan
`tools/test_plan_canvas_nested.md`. No verdict on looks: it lays the scene, takes the pictures and
the model states, and prints what differs; the eye (an agent opening the PNGs) does the rest.

    # a DEBUG build in UI mode (view.snapshot and the debug.* switches exist in Debug only)
    A=build/dd/Build/Products/Debug/objekat.app/Contents/MacOS/objekat
    $A --api --no-recent --no-audio --socket=/tmp/cc501/n.sock &

    ./scenario_canvas_nested.py /tmp/cc501/n.sock build --scene /tmp/cc501/nested/scene.json
    ./scenario_canvas_nested.py /tmp/cc501/n.sock snap  --scene ... --out /tmp/cc501/nested/snap
    ./scenario_canvas_nested.py /tmp/cc501/n.sock drag  --scene ... --out /tmp/cc501/nested/drag [--only D1,D3]
    ./scenario_canvas_nested.py /tmp/cc501/n.sock perf-scene --pieces 480     # for bench_navigation

`build` lays ONE project (saved under the scene file's folder), roles by name:

    G1 (open, depth 0)
      A1 | A2           clips in crossfade (A1/A2 siblings, 0.5 s zone)
      G2 (open, CROPPED: its window ends before B1 does -> out-of-range mask at depth 1)
        B1              clip, distinct file (depth 2)
        G3 (open, own colour)
          C1            clip with its own colour, bent fades (depth 3)
          G4 (CLOSED)   D1 clip + D2 MIDI clip (depth 4 inside the composite)
          X1            bounded aux
        L1 (CLOSED, LOOPING, muted) B2 inside
    G5 (open) > G6 (open) > N2,  G5 > N1   -> children at NEGATIVE absolute time (-2 s)
    G8 (open, INFINITE group — an infinite bus is top-level only): E1 clip + E2 bounded aux
    P1 plain root clip (drop neighbour), G9 CLOSED group (Q1, Q2) as a drop target

Each depth reads a DIFFERENT wav, so `perf.waveforms` can tell whether the deep files were loaded.

`snap`: for pps 5 / 50 / 400 and three selections (none / [A1, C1, G3] / [B1]), the visible timeline
in production (Canvas) and with `debug.force_rich_blocks` on (rich views), then the tools Volume,
Pan, Aux with and without `debug.force_rich_tools`. Writes `<case>_canvas.png`, `<case>_rich.png`,
`<case>_diff.png` (red = differing pixel) and `snap_report.json`; prints the differing-pixel count
per case. Method: `cache` (NSView.cacheDisplay; `window` gave a blank image on 2 Oct 2026).

`drag`: the critical real-mouse drags (`input.drag`), each from a fresh `project.open` of the scene:
the state UNDER the held gesture (perf.census, a Canvas picture, the same with
`debug.force_rich_previews`, and the MODEL must not have moved), then the release, the model
diff, ONE `edit.undo` that must give back the exact pre-drag `project.get_state` items.
"""

import argparse, array, json, math, os, random, shutil, sys, time, wave

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

RATE = 48000
BLOCK_H = 40.0
SNAP_METHOD = "cache"


# ----------------------------------------------------------------------------- helpers

def settle(c, ms=400):
    c.send("wait_idle", {"timeout_ms": 120000, "settle_ms": ms})


def write_wav(path, seconds, freq, seed):
    rnd = random.Random(seed)
    n = int(RATE * seconds)
    data = array.array("h")
    for i in range(n):
        t = i / RATE
        env = 0.25 + 0.75 * abs(math.sin(math.pi * t / 1.7))
        v = 0.55 * math.sin(2 * math.pi * freq * t) + 0.25 * (rnd.random() * 2 - 1)
        data.append(int(max(-1, min(1, v * env)) * 30000))
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE)
        w.writeframes(data.tobytes())
    return path


def items_state(c):
    """The model's tree, comparable: `project.get_state` items (the whole tree, closed groups
    included — `object.list` only walks the lane entries)."""
    return json.dumps(c.send("project.get_state")["items"], sort_keys=True)


def flat(c):
    """id -> (start, duration, lane, parent, depth, display_lane) for every listed entry."""
    out = {}
    for o in c.send("object.list")["objects"]:
        out[o["id"]] = (round(o["start"], 4), round(o["duration"], 4), o["lane"],
                        o.get("parent"), o["depth"], o["display_lane"])
    return out


def tree_index(items, parent=None, depth=0, out=None):
    """id -> {parent, depth, start, duration, lane} from `project.get_state` items (closed groups too)."""
    out = {} if out is None else out
    for it in items:
        iid = it.get("id")
        st = it.get("startTime", it.get("start"))
        out[iid] = {"parent": parent, "depth": depth, "start": st, "duration": it.get("duration"),
                    "lane": it.get("lane")}
        kind = it.get("kind") or {}
        children = kind.get("children") if isinstance(kind, dict) else None
        if children:
            tree_index(children, iid, depth + 1, out)
    return out


def geometry(c):
    vs = c.send("view.state")
    vsnap = vs.get("vsnap") or {}
    return {"pps": vs["pps"], "sx": vs["scroll_x"], "sy": vs["scroll_y"],
            "ruler": vsnap.get("ruler_h", 50), "step": vsnap.get("lane_step", vs["block_height"] + 4),
            "bh": vs["block_height"], "vw": vs["viewport_w"], "vh": vs["viewport_h"]}


def block_rect(c, oid, g=None):
    """The block's rect in VIEWPORT points (x, y, w, h), from the model + view (canvas -> viewport)."""
    g = g or geometry(c)
    o = c.send("object.get", {"id": oid})
    ent = next(e for e in c.send("object.list")["objects"] if e["id"].upper() == oid.upper())
    x = ent["start"] * g["pps"] - g["sx"]
    y = g["ruler"] + ent["display_lane"] * g["step"] - g["sy"]
    return x, y, max(2.0, o.get("duration", ent["duration"]) * g["pps"]), g["bh"]


def find_zone(c, oid, zone, prefer="center"):
    """A viewport point over `oid` whose hover zone reads `zone` (move, trimLeft, resizeRight, fadeIn,
    fadeOut, timeSelect) and whose hovered block is `oid`. Scans a grid over the visible part."""
    g = geometry(c)
    x, y, w, h = block_rect(c, oid, g)
    x0, x1 = max(2, x), min(g["vw"] - 2, x + w)
    y0, y1 = max(g["ruler"] + 2, y), min(g["vh"] - 2, y + h)
    if x1 <= x0 or y1 <= y0:
        raise RuntimeError("%s not visible (rect %s)" % (oid, (x, y, w, h)))
    xs = {"trimLeft": [x0 + d for d in (1, 2, 3, 4, 6, 8)],
          "fadeIn": [x0 + d for d in (2, 4, 6, 8, 12)],
          "resizeRight": [x1 - d for d in (1, 2, 3, 4, 6, 8)],
          "fadeOut": [x1 - d for d in (2, 4, 6, 8, 12)]}.get(
        zone, [x0 + (x1 - x0) * f for f in (0.5, 0.4, 0.6, 0.3, 0.7)])
    ys = [y0 + (y1 - y0) * f for f in ((0.75, 0.85, 0.65, 0.95) if zone in ("move", "trimLeft", "resizeRight")
                                         else (0.08, 0.15, 0.25, 0.4))]
    for yy in ys:
        for xx in xs:
            c.send("input.hover", {"x": xx, "y": yy})
            hv = c.send("view.state.hover")
            if hv.get("zone") == zone and (hv.get("hovered_id") or "").upper() == oid.upper():
                return xx, yy
    raise RuntimeError("no '%s' zone found on %s" % (zone, oid))


def snapshot(c, path):
    settle(c, 300)
    return c.send("view.snapshot", {"path": path, "method": SNAP_METHOD})


def diff_png(a, b, out, tol=24):
    """Differing pixels between two PNGs (max channel delta > tol); a red-on-grey diff picture."""
    try:
        from PIL import Image
        import numpy as np
    except ImportError:
        return {"error": "PIL/numpy missing"}
    A = np.asarray(Image.open(a).convert("RGB")).astype(int)
    B = np.asarray(Image.open(b).convert("RGB")).astype(int)
    if A.shape != B.shape:
        return {"error": "size %s vs %s" % (A.shape, B.shape)}
    mask = np.abs(A - B).max(axis=2) > tol
    n = int(mask.sum())
    pic = (A.mean(axis=2, keepdims=True).repeat(3, axis=2) * 0.35).astype("uint8")
    pic[mask] = [255, 40, 40]
    Image.fromarray(pic).save(out)
    bbox = None
    if n:
        ys, xs = np.nonzero(mask)
        bbox = [int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max())]
    return {"diff_px": n, "diff_frac": round(n / mask.size, 6), "bbox_px": bbox}


# ----------------------------------------------------------------------------- build

def build(c, scene_path):
    folder = os.path.dirname(os.path.abspath(scene_path))
    os.makedirs(folder, exist_ok=True)
    wav = {d: write_wav(os.path.join(folder, "depth%d.wav" % d), 8.0, 110 * (d + 1), d) for d in range(5)}
    c.send("project.new")
    try:
        c.send("tool.set", {"tool": "selection"})
    except ObjekatError:
        pass
    c.send("project.set_snap", {"enabled": False})
    settle(c)
    ids = {}

    def add(name, d, lane, start, dur):
        r = c.send("object.add", {"path": wav[d], "lane": lane, "start": start, "duration": dur})
        ids[name] = r["id"]
        return r["id"]

    def group(name, members):
        r = c.send("group.create", {"ids": [ids[m] for m in members]})
        ids[name] = r["id"]
        return r["id"]

    # --- G1 tree, bottom-up on root lanes 0..6 (relative lanes become child lanes)
    add("A1", 1, 0, 0.0, 4.0)
    add("A2", 1, 0, 3.5, 4.0)          # overlaps A1 by 0.5 s -> crossfade after grouping
    add("B1", 2, 1, 1.0, 6.0)
    add("C1", 3, 2, 2.0, 4.0)
    add("D1", 4, 3, 2.5, 2.0)
    r = c.send("midi.create_clip", {"start": 2.5, "end": 4.5, "lane": 4})
    ids["D2"] = r["id"]
    c.send("midi.add_note", {"id": ids["D2"], "pitch": 60, "start_beat": 0, "length_beats": 1, "velocity": 90})
    r = c.send("aux.create", {"start": 3.0, "end": 5.0, "lane": 5})
    ids["X1"] = r["id"]
    add("B2", 2, 6, 1.0, 2.0)
    group("G4", ["D1", "D2"])
    group("G3", ["C1", "G4", "X1"])
    group("L1", ["B2"])
    c.send("object.set_loop", {"id": ids["L1"], "enabled": True})
    c.send("object.set_loop_range", {"id": ids["L1"], "start": 0.0, "end": 1.0})
    c.send("object.set_duration", {"id": ids["L1"], "duration": 4.0})
    c.send("object.set_mute", {"ids": [ids["L1"]], "muted": True})
    group("G2", ["B1", "G3", "L1"])
    group("G1", ["A1", "A2", "G2"])
    # object.get / trim read the lane entries: open the tree before touching its inside
    for g in ("G1", "G2", "G3"):
        c.send("group.expand", {"id": ids[g], "expanded": True})
    # crossfade A1/A2 (siblings in G1)
    try:
        c.send("crossfade.open", {"left": ids["A1"], "right": ids["A2"], "width": 0.5})
    except ObjekatError as e:
        print("  ! crossfade.open:", e, file=sys.stderr)
    # G2 cropped: its window ends at 5 s while B1 runs to 7 s
    g2 = c.send("object.get", {"id": ids["G2"]})
    c.send("object.trim", {"id": ids["G2"], "start": g2["start"], "duration": 5.0 - g2["start"]})
    # look: colours, fades
    c.send("object.set_color", {"ids": [ids["C1"]], "color_index": 5})
    c.send("object.set_color", {"ids": [ids["G3"]], "color_index": 9})
    c.send("object.set_fade", {"id": ids["C1"], "in": 0.6, "out": 0.8})
    try:
        c.send("object.set_fade_curve", {"id": ids["C1"], "in": "convex", "in_bend": 0.7,
                                         "out": "sCurve", "out_bend": 0.6})
    except ObjekatError as e:
        print("  ! set_fade_curve:", e, file=sys.stderr)

    # object.add's lane is a DISPLAY lane: with G1 open, a new object would land INSIDE it
    c.send("group.expand", {"id": ids["G1"], "expanded": False})

    # --- negative time: G5 > (N1, G6 > N2), cropped from the left then brought back to 0
    add("N1", 1, 8, 0.0, 4.0)
    add("N2", 2, 9, 0.0, 4.0)
    group("G6", ["N2"])
    group("G5", ["N1", "G6"])
    for g in ("G5", "G6"):
        c.send("group.expand", {"id": ids[g], "expanded": True})
    c.send("object.trim", {"id": ids["G5"], "start": 2.0, "duration": 2.0})
    c.send("object.move", {"id": ids["G5"], "start": 0.0})
    c.send("group.expand", {"id": ids["G5"], "expanded": False})

    # --- an infinite bus is TOP LEVEL ONLY (the app refuses one inside a group): an infinite
    # GROUP holding a clip and a bounded aux — the "bus in the tree" case that exists
    add("E1", 1, 11, 0.0, 3.0)
    r = c.send("aux.create", {"start": 0.5, "end": 2.5, "lane": 12})
    ids["E2"] = r["id"]
    group("G8", ["E1", "E2"])
    try:
        c.send("object.set_infinite", {"id": ids["G8"], "on": True})
    except ObjekatError as e:
        print("  ! set_infinite:", e, file=sys.stderr)

    # --- drop neighbours: a plain root clip, a CLOSED group
    add("P1", 0, 14, 0.0, 3.0)
    add("Q1", 0, 15, 4.0, 2.0)
    add("Q2", 0, 16, 4.5, 2.0)
    group("G9", ["Q1", "Q2"])

    for g in ("G1", "G2", "G3", "G5", "G6", "G8"):
        c.send("group.expand", {"id": ids[g], "expanded": True})
    for g in ("G4", "L1", "G9"):
        c.send("group.expand", {"id": ids[g], "expanded": False})
    c.send("selection.clear")
    proj = os.path.join(folder, "nested.objekat")
    c.send("project.save_as", {"path": proj})
    settle(c, 800)
    tree = tree_index(c.send("project.get_state")["items"])
    scene = {"project": proj, "ids": ids, "wavs": wav,
             "depths": {k: tree.get(v, {}).get("depth") for k, v in ids.items()},
             "parents": {k: next((n for n, i in ids.items() if i == tree.get(v, {}).get("parent")), None)
                         for k, v in ids.items()}}
    with open(scene_path, "w") as f:
        json.dump(scene, f, indent=1)
    print("scene:", scene_path)
    for k in sorted(ids):
        print("  %-3s depth=%s parent=%s" % (k, scene["depths"][k], scene["parents"][k]))
    census = c.send("perf.census")
    print("census:", json.dumps({k: census.get(k) for k in ("objects_total", "max_group_depth")}))
    return scene


def open_scene(c, scene, pps=50, sx=0, sy=0):
    c.send("project.open", {"path": scene["project"]})
    settle(c, 800)
    try:
        c.send("tool.set", {"tool": "selection"})
    except ObjekatError:
        pass
    c.send("project.set_snap", {"enabled": False})
    c.send("view.set", {"pps": pps, "block_height": BLOCK_H, "scroll_x": sx, "scroll_y": sy})
    c.send("selection.clear")
    settle(c, 600)


def set_rich(c, blocks=None, tools=None, previews=None):
    if blocks is not None:
        c.send("debug.force_rich_blocks", {"enabled": blocks})
    if tools is not None:
        c.send("debug.force_rich_tools", {"enabled": tools})
    if previews is not None:
        c.send("debug.force_rich_previews", {"enabled": previews})


# ----------------------------------------------------------------------------- snap

def snap(c, scene, out):
    os.makedirs(out, exist_ok=True)
    ids = scene["ids"]
    report = {}
    open_scene(c, scene)
    w = c.send("perf.waveforms")
    report["waveforms_after_open"] = w
    selections = {"none": [], "mixed": [ids["A1"], ids["C1"], ids["G3"]], "deepchild": [ids["B1"]]}

    def pair(name, flip):
        a = os.path.join(out, name + "_canvas.png")
        b = os.path.join(out, name + "_rich.png")
        snapshot(c, a)
        census_a = c.send("perf.census").get("regimes")
        flip(True)
        settle(c, 500)
        snapshot(c, b)
        census_b = c.send("perf.census").get("regimes")
        flip(False)
        d = diff_png(a, b, os.path.join(out, name + "_diff.png"))
        d["census_canvas"] = {k: census_a.get(k) for k in ("clips_canvas", "clips_rich", "groups_canvas", "groups_rich",
                                                          "group_bands_canvas", "group_bands_rich")} if census_a else None
        d["census_rich"] = {k: census_b.get(k) for k in ("clips_rich", "groups_rich", "group_bands_rich")} if census_b else None
        report[name] = d
        print("  %-28s diff_px=%-7s bbox=%s" % (name, d.get("diff_px", d.get("error")), d.get("bbox_px")))

    for pps in (5, 50, 400):
        c.send("view.set", {"pps": pps, "block_height": BLOCK_H, "scroll_x": 0, "scroll_y": 0})
        for sname, sel in selections.items():
            if sel:
                c.send("selection.set", {"ids": sel})
            else:
                c.send("selection.clear")
            settle(c, 300)
            pair("p%d_%s" % (pps, sname), lambda on: set_rich(c, blocks=on))
    c.send("selection.set", {"ids": [ids["A1"], ids["C1"]]})
    c.send("view.set", {"pps": 50, "block_height": BLOCK_H, "scroll_x": 0, "scroll_y": 0})
    for tool in ("volume", "pan", "aux"):
        c.send("tool.set", {"tool": tool})
        settle(c, 300)
        pair("tool_%s" % tool, lambda on: set_rich(c, tools=on))
    c.send("tool.set", {"tool": "selection"})
    # a mid-height scroll: the vertical cull (cullScrollY) with the open bands
    c.send("view.set", {"pps": 50, "block_height": BLOCK_H, "scroll_x": 37, "scroll_y": 333})
    c.send("selection.clear")
    pair("scrolled_mid", lambda on: set_rich(c, blocks=on))
    with open(os.path.join(out, "snap_report.json"), "w") as f:
        json.dump(report, f, indent=1)
    print("report:", os.path.join(out, "snap_report.json"))


# ----------------------------------------------------------------------------- drag

# Each case: (name, object grabbed, zone, how far in px (dx, dy) — dy in LANES —, what to check)
DRAG_CASES = [
    ("D1_deep_child_out_one_level", "C1", "move", (60, 2), "C1 leaves G3 (parent changes or lane changes), one undo"),
    ("D2_child_into_closed_group", "B1", "move", (0, None), "B1 dropped on the CLOSED G9 lane (not inside it: closed)"),
    ("D3_move_open_group_with_subgroups", "G2", "move", (80, 0), "G2 and ALL descendants shift by the same dt"),
    ("D4_deep_child_trim_left", "C1", "trimLeft", (25, 0), "C1 start +0.5 s, end fixed, source offset +0.5"),
    ("D5_deep_child_resize_right", "C1", "resizeRight", (-30, 0), "C1 end -0.6 s"),
    ("D6_group_trim_left_nested", "G3", "trimLeft", (30, 0), "G3 window start +0.6 s, children unchanged"),
    ("D7_crossfaded_child_move", "A2", "move", (40, 0), "A2 +0.8 s; the A1/A2 crossfade follows or closes"),
    ("D8_negative_child_move", "N1", "move", (50, 0), "N1 from -2 s to -1 s, still in G5"),
    ("D9_fade_in_deep", "C1", "fadeIn", (20, 0), "C1 fade in grows, nothing else moves"),
]


def run_drag(c, scene, out, only=None):
    os.makedirs(out, exist_ok=True)
    ids = scene["ids"]
    results = {}
    for name, who, zone, (dx, dlanes), expect in DRAG_CASES:
        if only and name.split("_")[0] not in only:
            continue
        print("==", name, "-", expect)
        res = {"expect": expect}
        try:
            open_scene(c, scene)
            c.send("view.reveal", {"ids": [ids[who]]})
            settle(c, 400)
            g = geometry(c)
            x, y = find_zone(c, ids[who], zone)
            if dlanes is None:   # D2: aim at G9's row
                _, ty, _, _ = block_rect(c, ids["G9"], g)
                dy = ty + g["bh"] * 0.75 - y
            else:
                dy = dlanes * g["step"]
            before = items_state(c)
            tree_before = tree_index(json.loads(before))
            r = c.send("input.drag", {"x": x, "y": y, "dx": dx, "dy": dy, "duration_ms": 500, "release": False})
            res["drag"] = {"from": [x, y], "dx": dx, "dy": dy, "contaminated": r.get("contaminated")}
            settle(c, 300)
            res["census_held"] = (c.send("perf.census").get("regimes") or {}).get("rich_reasons")
            res["model_untouched_while_held"] = items_state(c) == before
            a = os.path.join(out, name + "_held_canvas.png")
            b = os.path.join(out, name + "_held_rich.png")
            snapshot(c, a)
            set_rich(c, previews=True)
            settle(c, 400)
            snapshot(c, b)
            set_rich(c, previews=False)
            res["held_diff"] = diff_png(a, b, os.path.join(out, name + "_held_diff.png"))
            c.send("input.release")
            settle(c, 600)
            after = items_state(c)
            tree_after = tree_index(json.loads(after))
            res["changed"] = {k: {"before": tree_before.get(v), "after": tree_after.get(v)}
                              for k, v in ids.items() if tree_before.get(v) != tree_after.get(v)}
            snapshot(c, os.path.join(out, name + "_after.png"))
            c.send("edit.undo")
            settle(c, 500)
            res["undo_one_step_restores"] = items_state(c) == before
            print("   held model untouched:", res["model_untouched_while_held"],
                  "| held diff px:", res["held_diff"].get("diff_px"),
                  "| changed:", sorted(res["changed"]), "| undo restores:", res["undo_one_step_restores"])
        except Exception as e:
            res["error"] = repr(e)
            print("   ERROR", e)
            try:
                c.send("input.release")
            except Exception:
                pass
        results[name] = res
    with open(os.path.join(out, "drag_report.json"), "w") as f:
        json.dump(results, f, indent=1, default=str)
    print("report:", os.path.join(out, "drag_report.json"))


# ----------------------------------------------------------------------------- perf scene

def perf_scene(c, pieces, out_dir):
    """`pieces` clips of 0.5 s in 4 levels: root group > 4 groups > 3 groups each > clips, all open.
    Saved for an A/B with the archive (same project opened by both builds)."""
    os.makedirs(out_dir, exist_ok=True)
    wav = write_wav(os.path.join(out_dir, "perf.wav"), 300.0, 220, 7)
    c.send("project.new")
    c.send("project.set_snap", {"enabled": False})
    clip = c.send("object.add", {"path": wav, "lane": 0, "start": 0})
    n = pieces
    lanes = 12
    cuts = [round(i * 0.5, 6) for i in range(1, n)]
    r = c.send("object.explode", {"id": clip["id"], "cuts": cuts, "lanes": [i % lanes for i in range(n)],
                                   "group_lanes": True})
    subs = r["lane_groups"]                  # 12 sub-groups (depth 1), the outer one is depth 0
    # the sub-groups are only addressable by group.create while the outer group is OPEN
    # (otherwise "invalid_state: no group created")
    c.send("group.expand", {"id": r["group"], "expanded": True})
    # depth 2 and 3: pair the sub-groups, then group the pairs in threes
    pairs = [c.send("group.create", {"ids": subs[i:i + 2]})["id"] for i in range(0, len(subs), 2)]
    tops = [c.send("group.create", {"ids": pairs[i:i + 3]})["id"] for i in range(0, len(pairs), 3)]
    tree = tree_index(c.send("project.get_state")["items"])
    for gid, info in tree.items():
        pass
    for e in list(tree):
        try:
            c.send("group.expand", {"id": e, "expanded": True})
        except ObjekatError:
            pass
    c.send("selection.clear")
    path = os.path.join(out_dir, "perf_nested_%d.objekat" % pieces)
    c.send("project.save_as", {"path": path})
    settle(c, 1500)
    census = c.send("perf.census")
    print("perf scene:", path, "objects:", census.get("objects_total"), "max depth:", census.get("max_group_depth"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("socket")
    ap.add_argument("what", choices=["build", "snap", "drag", "perf-scene"])
    ap.add_argument("--scene", default="/tmp/cc501/nested/scene.json")
    ap.add_argument("--out", default="/tmp/cc501/nested/out")
    ap.add_argument("--only", default="")
    ap.add_argument("--pieces", type=int, default=480)
    a = ap.parse_args()
    c = ObjekatClient(a.socket, timeout=600)
    c.connect()
    c.send("app.set_dialog_policy", {"policy": "assume_no"})
    if a.what == "build":
        build(c, a.scene)
    elif a.what == "perf-scene":
        perf_scene(c, a.pieces, a.out)
    else:
        scene = json.load(open(a.scene))
        if a.what == "snap":
            snap(c, scene, a.out)
        else:
            run_drag(c, scene, a.out, set(x for x in a.only.split(",") if x) or None)


if __name__ == "__main__":
    main()

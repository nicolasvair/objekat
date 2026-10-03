#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Multiple-selection benchmark — what it costs the main thread to SELECT K objects, to COMPARE two builds.

No thresholds and no verdict: a figure from here means something only next to another one taken the
same way (a build against the next, Debug against Release). The cost it measures is the inspector's
multiple-selection column (`ObjectInspectorView`), which is what a selection of hundreds used to
freeze for tens of seconds — the timeline's own drawing is held out of it by running every K twice,
once with the blocks on screen and once with the view scrolled far away from them.

    # 1. an instance in UI MODE (never --headless: no inspector is drawn there, nothing would be
    #    measured), RELEASE unless Debug is what is being compared (they differ by ×40). Keep the
    #    socket path short (a UNIX socket path is limited to ~100 bytes).
    #    a. the REAL project: a copy-on-write COPY of the folder, never the original —
    #         cp -c -R "<folder of the project>" /some/where/copy
    #         objekat.app/Contents/MacOS/objekat --api --no-recent --socket=/tmp/oinsp.sock \\
    #                                            --project=/some/where/copy/<name>.objekat
    #    b. the SYNTHETIC fixture: an empty project, the script lays it down itself
    #         objekat.app/Contents/MacOS/objekat --api --no-recent --socket=/tmp/oinsp.sock
    #
    # 2. measure, keep the result
    ./bench_selection.py /tmp/oinsp.sock --label before --out before.json
    ./bench_selection.py /tmp/oinsp.sock --fixture synthetic --label before-synth --out bs.json
    #    … change something, relaunch …
    ./bench_selection.py /tmp/oinsp.sock --label after --out after.json
    #
    # 3. compare
    ./bench_selection.py --compare before.json after.json

Real project (`--group Voix`): the group of that name with the most direct children is found in the
project FILE (`app.info` names it), its chain of ancestors is opened (`group.expand`) so the children
are on the timeline, then K of them are selected with `selection.set` — K ∈ {1, 10, 50, 100, all}
by default, `--repeat` times each (default 3), the median of each metric kept.
Synthetic fixture: 12 × 50 clips of `fixtures/bip.wav`, 3 auxes, and a group nested two levels deep
holding 200 children (an aux among them).
`--pan` adds the inspector's own gesture: 20 `object.adjust_pan` with the whole group selected.

Metrics (per K and view): `model_ms` — the command itself; `busy_total` / `busy_max` — what the main
thread did over the next second (the frame meter, SwiftUI's passes included); `frame_ms` —
`perf.measure`'s own "time to come back to the loop".
"""

import argparse, json, os, statistics, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient

BIP = os.path.join(HERE, "fixtures", "bip.wav")
START = {"pps": 100, "block_height": 121.5, "scroll_x": 0, "scroll_y": 0}
FAR = {"pps": 100, "block_height": 121.5, "scroll_x": 200000, "scroll_y": 0}

METRICS = [
    ("model_ms",   "model ms"),
    ("frame_ms",   "frame ms"),
    ("busy_total", "busy total ms"),
    ("busy_max",   "busy max ms"),
]


def find_group(items, label):
    """The group named `label` with the most direct children, and the chain of its ancestors."""
    best = None

    def walk(arr, chain):
        nonlocal best
        for o in arr:
            kind = o.get("kind") or {}
            if kind.get("type") == "group":
                kids = kind.get("children") or []
                if (o.get("label") or "").strip().lower() == label.lower():
                    if best is None or len(kids) > len(best[1]):
                        best = (chain + [o["id"]], [k["id"] for k in kids])
                walk(kids, chain + [o["id"]])

    walk(items, [])
    return best


def select_and_measure(c, ids, view, settle_s):
    c.send("selection.clear")
    time.sleep(0.8)
    c.send("view.set", view)
    time.sleep(0.4)
    c.send("perf.frames.start")
    r = c.send("perf.measure", {"commands": [{"cmd": "selection.set", "params": {"ids": ids}}],
                                "wait_idle": False})
    time.sleep(settle_s)
    f = c.send("perf.frames.stop")["frames"]
    return {"model_ms": r["model_ms"]["median"], "frame_ms": r["frame_ms"]["median"],
            "busy_total": f["main_busy_total_ms"], "busy_max": f["main_busy_ms"]["max"]}


def run_ks(c, result, tag, ids, ks, repeat, views, settle_s):
    for k in ks:
        k = min(k, len(ids))
        for vname, view in views:
            runs = [select_and_measure(c, ids[:k], view, settle_s) for _ in range(repeat)]
            row = {m: statistics.median(x[m] for x in runs) for m, _ in METRICS}
            row["k"] = k
            key = "%s:K=%d:%s" % (tag, k, vname)
            result["steps"][key] = row
            print("  %-34s model %8.1f   frame %8.1f   busy total %9.1f   busy max %9.1f"
                  % (key, row["model_ms"], row["frame_ms"], row["busy_total"], row["busy_max"]))
    c.send("selection.clear")


def pan_gesture(c, result, tag, ids, repeat, settle_s):
    """The inspector's own continuous gesture: the whole group selected, 20 pan deltas in a row."""
    c.send("view.set", START)
    c.send("selection.set", {"ids": ids})
    time.sleep(2.0 + len(ids) * 0.02)
    cmds = [{"cmd": "object.adjust_pan", "params": {"by": 0.1 if i % 2 == 0 else -0.1}} for i in range(20)]
    runs = []
    for _ in range(repeat):
        c.send("perf.frames.start")
        r = c.send("perf.measure", {"commands": cmds, "wait_idle": False})
        time.sleep(settle_s)
        f = c.send("perf.frames.stop")["frames"]
        runs.append({"model_ms": r["model_ms"]["median"], "frame_ms": r["frame_ms"]["median"],
                     "busy_total": f["main_busy_total_ms"], "busy_max": f["main_busy_ms"]["max"]})
    row = {m: statistics.median(x[m] for x in runs) for m, _ in METRICS}
    row["k"] = len(ids)
    key = "%s:pan20:K=%d" % (tag, len(ids))
    result["steps"][key] = row
    print("  %-34s model %8.1f   frame %8.1f   busy total %9.1f   busy max %9.1f"
          % (key, row["model_ms"], row["frame_ms"], row["busy_total"], row["busy_max"]))
    c.send("selection.clear")


def build_fixture(c):
    """12 × 50 clips, 3 auxes, and a group nested two levels deep holding 200 children (one aux)."""
    c.send("batch", {"commands": [{"cmd": "object.add", "params": {"path": BIP, "lane": l, "start": t * 1.0}}
                                  for l in range(12) for t in range(50)]})
    for i in range(3):
        c.send("aux.create", {"start": i * 10.0, "end": i * 10.0 + 25.0, "lane": 12 + i})
    # Two more blocks of 200 clips, lanes above the first twelve, to be grouped.
    inner_ids, outer_ids = [], []
    base = {o["id"] for o in c.send("object.list")["objects"]}
    c.send("batch", {"commands": [{"cmd": "object.add", "params": {"path": BIP, "lane": 16 + l, "start": t * 1.0}}
                                  for l in range(4) for t in range(50)]})
    now = c.send("object.list")["objects"]
    inner_ids = [o["id"] for o in now if o["id"] not in base and o.get("kind") == "clip"]
    aux = c.send("aux.create", {"start": 0.0, "end": 60.0, "lane": 20})["id"]
    inner_ids.append(aux)
    inner = c.send("group.create", {"ids": inner_ids})["id"]
    base = {o["id"] for o in c.send("object.list")["objects"]}
    c.send("batch", {"commands": [{"cmd": "object.add", "params": {"path": BIP, "lane": 22 + l, "start": t * 1.0}}
                                  for l in range(4) for t in range(50)]})
    now = c.send("object.list")["objects"]
    outer_ids = [o["id"] for o in now if o["id"] not in base and o.get("kind") == "clip"] + [inner]
    outer = c.send("group.create", {"ids": outer_ids})["id"]
    c.send("group.expand", {"id": outer, "expanded": True})
    c.send("group.expand", {"id": inner, "expanded": True})
    time.sleep(2.0)
    kids = [o["id"] for o in c.send("object.list")["objects"]
            if o.get("parent") == inner and o.get("kind") == "clip"]
    return outer, inner, kids


def measure(sock, label, args):
    c = ObjekatClient(sock, timeout=900)
    c.connect()
    info = c.send("app.info")
    census = c.send("perf.census")
    result = {"label": label, "when": time.strftime("%Y-%m-%d %H:%M:%S"),
              "project": info.get("project_path"), "objects": census.get("objects_total"),
              "steps": {}}
    views = [("visible", START), ("away", FAR)]
    ks = [int(x) for x in args.ks.split(",")]

    if args.fixture == "synthetic":
        outer, inner, kids = build_fixture(c)
        print("fixture: %d objects, inner group %s holds %d clips" % (c.send("perf.census")["objects_total"],
                                                                      inner[:8], len(kids)))
        result["objects"] = c.send("perf.census")["objects_total"]
        c.send("view.reveal", {"ids": kids[:3]})
        time.sleep(1.5)
        run_ks(c, result, "synthetic", kids, ks, args.repeat, views, args.settle)
        # Top-level senders: the 12 × 50 clips, with three auxes in scope.
        tops = [o["id"] for o in c.send("object.list")["objects"]
                if o.get("kind") == "clip" and not o.get("parent")][:600]
        run_ks(c, result, "synthetic-top", tops, [1, 50, 200, 600], args.repeat, views, args.settle)
        if args.pan:
            pan_gesture(c, result, "synthetic", kids, args.repeat, args.settle)
        return result

    path = info.get("project_path")
    with open(path, encoding="utf-8") as fh:
        doc = json.load(fh)
    found = find_group(doc["items"], args.group)
    if not found:
        raise SystemExit("no group named %r in %s" % (args.group, path))
    chain, kids = found
    print("group %r: %d children, chain of %d group(s)" % (args.group, len(kids), len(chain)))
    for gid in chain:
        c.send("group.expand", {"id": gid, "expanded": True})
    time.sleep(2.0)
    c.send("view.reveal", {"ids": kids[:3]})
    time.sleep(2.0)
    run_ks(c, result, "real", kids, ks, args.repeat, views, args.settle)
    if args.pan:
        pan_gesture(c, result, "real", kids, args.repeat, args.settle)
    return result


def compare(a, b):
    print("A = %s (%s objects)   B = %s (%s objects)" % (a["label"], a.get("objects"), b["label"], b.get("objects")))
    for key in a["steps"]:
        sb = b["steps"].get(key)
        if not sb:
            continue
        sa = a["steps"][key]
        print("\n%s" % key)
        for m, label in METRICS:
            va, vb = sa.get(m), sb.get(m)
            if va is None or vb is None:
                continue
            ratio = ("×%.3f" % (vb / va)) if va else "—"
            print("  %-14s %11.1f %11.1f   %s" % (label, va, vb, ratio))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("socket", nargs="?")
    ap.add_argument("--label", default="run")
    ap.add_argument("--out")
    ap.add_argument("--repeat", type=int, default=3)
    ap.add_argument("--ks", default="1,10,50,100,178")
    ap.add_argument("--group", default="Voix")
    ap.add_argument("--fixture", choices=["real", "synthetic"], default="real")
    ap.add_argument("--pan", action="store_true", help="also 20 object.adjust_pan with the whole group selected")
    ap.add_argument("--settle", type=float, default=1.0, help="seconds to let the main thread finish")
    ap.add_argument("--compare", nargs=2, metavar=("A.json", "B.json"))
    args = ap.parse_args()
    if args.compare:
        with open(args.compare[0]) as fa, open(args.compare[1]) as fb:
            compare(json.load(fa), json.load(fb))
        return 0
    if not args.socket:
        ap.print_usage()
        return 2
    result = measure(args.socket, args.label, args)
    if args.out:
        with open(args.out, "w") as f:
            json.dump(result, f, indent=1)
        print("→ %s" % args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Crossfade grabbed by a fade handle, and several crossfades dragged as one — what the model
answers to the calls the GESTURE makes.

The gesture itself (a mouse drag on the timeline) cannot be driven from here: the headless API has
no pointer. What this proves is the half underneath it, and it is the half the bug lived in:

  * a pair stays a crossfade (`isCrossfadePair`, which `crossfade.list` is derived from) after
    `crossfade.open` — the primitive the gesture lays every frame down with — for each of the four
    parts of a zone, with the arguments the gesture computes (`CrossfadeGrab.target`);
  * a fade changed ALONE breaks the pair, which is exactly what the handle band outside the zone
    used to do and why that grab is now routed to the crossfade;
  * several zones given the SAME travel each keep their own width and place and stay crossfades;
  * `crossfade.close` (what the double click does, in the zone and now outside it too) zeroes
    BOTH fades and leaves the two clips meeting.

The decision tables themselves (which pair, which side, which zones follow) are asserted by
`tools/test_crossfade_grab.swift`, standalone.

    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --socket=/tmp/o.sock
    ./scenario_crossfade_grab.py /tmp/o.sock

Exit: 0 if every assertion passes, 1 otherwise.
"""

import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient

if len(sys.argv) != 2:
    print(__doc__)
    sys.exit(2)

SOCK = sys.argv[1]
BIP = os.path.join(HERE, "fixtures", "bip.wav")
fails = []


def check(label, ok, detail=""):
    if ok:
        print("ok    " + label)
    else:
        fails.append(label)
        print("FAIL  %s  %s" % (label, detail))


def near(a, b, eps=1e-6):
    return abs(a - b) < eps


with ObjekatClient(SOCK) as c:
    def cmd(name, **params):
        return c.send(name, params or None)

    cmd("project.new")
    D = 0.4  # bip.wav is 0.4 s long

    def chain(lane, n):
        """`n` clips butted along one lane, each trimmed so that 0.2 D of file is hidden behind
        BOTH its edges (opening a seam re-exposes hidden matter: untouched clips could not open)."""
        ids = []
        for i in range(n):
            # Laid far from the others first: dropped on a neighbour, an object overwrites it.
            home = 100 + 2 * i
            o = cmd("object.add", path=BIP, lane=lane, start=home)
            oid = o["id"]
            cmd("object.trim", id=oid, start=home + 0.2 * D, duration=0.6 * D)
            cmd("object.move", id=oid, start=i * 0.6 * D)
            ids.append(oid)
        return ids

    def zones():
        return cmd("crossfade.list")["crossfades"]

    def zone(l, r):
        for z in zones():
            if z["left"] == l and z["right"] == r:
                return z
        return None

    def get(i):
        return cmd("object.get", id=i)

    # ── one pair, the four parts ─────────────────────────────────────────────────────────────
    a, b = chain(3, 2)
    w0 = 0.2 * D
    cmd("crossfade.open", left=a, right=b, width=w0)
    z = zone(a, b)
    check("crossfade.open makes a pair that isCrossfadePair recognises (crossfade.list)",
          z is not None and near(z["width"], w0), str(z))
    ga, gb = get(a), get(b)
    check("…both fades equal the overlap",
          near(ga["fade_out"], z["width"]) and near(gb["fade_in"], z["width"]),
          "%s / %s vs %s" % (ga["fade_out"], gb["fade_in"], z["width"]))

    # The plain per-block fade on ONE side is what the handle band outside the zone used to do.
    cmd("object.set_fade", id=a, out=w0 / 2)
    check("a fade changed ALONE dissolves the pair (the bug the grab is routed away from)",
          zone(a, b) is None, str(zones()))
    cmd("crossfade.open", left=a, right=b, width=w0)
    check("…and opening the seam again restores it", zone(a, b) is not None)

    s0, e0 = z["start"], z["end"]

    def frame(l, r, part, anchor_start, anchor_end, shift):
        """The call one frame of the gesture makes (@see CrossfadeGrab.target)."""
        w = anchor_end - anchor_start
        if part == "move":
            raw, start, pin = w, anchor_start + shift, None
        elif part == "both":
            raw = w + 2 * shift
            start, pin = (anchor_start + anchor_end) / 2 - max(0, raw) / 2, None
        elif part == "sideStart":
            raw = w - shift
            start, pin = anchor_end - max(0, raw), "end"
        else:  # sideEnd
            raw, start, pin = w + shift, anchor_start, "start"
        params = dict(left=l, right=r, width=max(0, raw), start=start)
        if pin == "end":
            params["pin"] = "end"
            params["start"] = anchor_end - max(0, raw)
        elif pin == "start":
            params["pin"] = "start"
        return cmd("crossfade.open", **params)

    shift = 0.01
    frame(a, b, "sideEnd", s0, e0, shift)
    z = zone(a, b)
    check("end side: the zone still IS a crossfade, its start stayed, it grew by the shift",
          z is not None and near(z["start"], s0) and near(z["width"], w0 + shift), str(z))
    cmd("crossfade.open", left=a, right=b, width=w0, start=s0)  # back to the anchors

    frame(a, b, "sideStart", s0, e0, shift)
    z = zone(a, b)
    check("start side: still a crossfade, its END stayed, it lost the shift",
          z is not None and near(z["end"], e0) and near(z["width"], w0 - shift), str(z))
    cmd("crossfade.open", left=a, right=b, width=w0, start=s0)

    frame(a, b, "both", s0, e0, shift)
    z = zone(a, b)
    check("whole zone: symmetric, centre kept, twice the shift wider",
          z is not None and near(z["width"], w0 + 2 * shift)
          and near((z["start"] + z["end"]) / 2, (s0 + e0) / 2), str(z))
    cmd("crossfade.open", left=a, right=b, width=w0, start=s0)

    frame(a, b, "move", s0, e0, shift)
    z = zone(a, b)
    check("body: width kept, slid by the shift",
          z is not None and near(z["width"], w0) and near(z["start"], s0 + shift), str(z))

    # ── the double click: both fades, and the clips meet ──────────────────────────────────────
    cmd("crossfade.close", left=a, right=b)
    ga, gb = get(a), get(b)
    check("close: no crossfade is left", zone(a, b) is None)
    check("…BOTH fades are zero (not one of them, which is what the old fall-through did)",
          near(ga["fade_out"], 0) and near(gb["fade_in"], 0),
          "%s / %s" % (ga["fade_out"], gb["fade_in"]))
    check("…and the two clips meet without a gap or an overlap",
          near(ga["start"] + ga["duration"], gb["start"]),
          "%s vs %s" % (ga["start"] + ga["duration"], gb["start"]))

    # ── several zones, one travel ─────────────────────────────────────────────────────────────
    p, q, r = chain(4, 3)
    wab, wbc = 0.15 * D, 0.25 * D
    cmd("crossfade.open", left=p, right=q, width=wab)
    cmd("crossfade.open", left=q, right=r, width=wbc)
    zab, zbc = zone(p, q), zone(q, r)
    check("two zones sharing the clip Q", zab is not None and zbc is not None, str(zones()))
    ab0, bc0 = dict(zab), dict(zbc)

    # The selection holds P, Q, R and the hand is on AB's end side: every selected object with a
    # crossfade on ITS right brings it along — P's (AB, the grabbed one) and Q's (BC). Same shift.
    shift = 0.01
    frame(p, q, "sideEnd", ab0["start"], ab0["end"], shift)
    frame(q, r, "sideEnd", bc0["start"], bc0["end"], shift)
    zab, zbc = zone(p, q), zone(q, r)
    check("both zones are still crossfades after one shared travel",
          zab is not None and zbc is not None, str(zones()))
    check("each kept its own width and gained the SAME delta",
          near(zab["width"], wab + shift) and near(zbc["width"], wbc + shift),
          "%s / %s" % (zab["width"], zbc["width"]))
    check("each start stayed where it was (end side)",
          near(zab["start"], ab0["start"]) and near(zbc["start"], bc0["start"]),
          "%s / %s" % (zab["start"], zbc["start"]))

    # And the whole-zone parts: the same shift slides BOTH seams by the same travel.
    ab1, bc1 = dict(zab), dict(zbc)
    dq0 = get(q)["duration"]
    frame(p, q, "move", ab1["start"], ab1["end"], shift)
    frame(q, r, "move", bc1["start"], bc1["end"], shift)
    zab, zbc = zone(p, q), zone(q, r)
    check("body of two zones: both slid by the same travel, widths kept",
          zab is not None and zbc is not None
          and near(zab["start"], ab1["start"] + shift) and near(zbc["start"], bc1["start"] + shift)
          and near(zab["width"], ab1["width"]) and near(zbc["width"], bc1["width"]),
          "%s / %s" % (zab, zbc))
    check("Q, held by both zones, kept its length (its two edges travelled by the same shift)",
          near(get(q)["duration"], dq0), "%s -> %s" % (dq0, get(q)["duration"]))

    # Undo is ONE point per command here (the bus); the gesture's own single undo point is the
    # view's and cannot be asserted from this side.

    cmd("object.remove", ids=[a, b, p, q, r])

print()
if fails:
    print("FAILED: %d" % len(fails))
    sys.exit(1)
print("ALL PASS")

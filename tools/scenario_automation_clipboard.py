#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Copy / cut / paste of an automation passage, through the edit shortcuts — headless.

    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --language=en \
        --socket=/tmp/o.sock
    ./scenario_automation_clipboard.py /tmp/o.sock

@see EditViewModel+AutomationClipboard / +AutomationZone / +EditMenu, Shared/AutomationZoneFilter.

  B1  a row is reached by its LANE and by its TIME: two objects on one lane (consecutive clips, the
      consecutive children of a group) have bands that share a lane number and nothing else.
      Copy from A is ONE row, the paste lands on B, A is left intact — hidden points included — and
      the point selection / ⌘X never takes the points of the other object. Both insertion orders.
  B2  ⌘V after a plain click in a band (a caret, no zone) lays the passage there even when an
      OBJECT clipboard is full; ⌘C on a caret alone is unchanged.
  B3  the zone recreated after a paste follows the rows as they are NOW: a paste that empties a row
      moves the rows after it, and the second ⌘V must aim at the same (object, parameter).

Cases: an object outside any group; two clips on one lane outside a group; two children of one
sub-lane in a group; a nested group; negative time; varispeed 1.5; the undo (ONE point per paste).

Exit: 0 if every assertion passes, 1 otherwise.
"""

import os, struct, sys, tempfile

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient

if len(sys.argv) != 2:
    print(__doc__)
    sys.exit(2)

SOCK = sys.argv[1]
WORK = tempfile.mkdtemp(prefix="objekat_autoclip_")
SR = 48000
FILE_SECONDS = 20.0
fails = []
count = 0


def check(label, ok, detail=""):
    global count
    count += 1
    if ok:
        print("ok    " + label)
    else:
        fails.append(label)
        print("FAIL  %s  %s" % (label, detail))


def write_tone(path):
    n = int(FILE_SECONDS * SR)
    x = 0.2 * np.sin(2 * np.pi * 220 * np.arange(n) / SR)
    i = np.round(x * (2 ** 23 - 1)).astype(np.int32)
    b = np.stack([i & 255, (i >> 8) & 255, (i >> 16) & 255], axis=1).astype(np.uint8)
    data = np.repeat(b, 2, axis=0).tobytes()
    with open(path, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVE")
        f.write(b"fmt " + struct.pack("<IHHIIHH", 16, 1, 2, SR, SR * 6, 6, 24))
        f.write(b"data" + struct.pack("<I", len(data)) + data)


TONE = os.path.join(WORK, "tone.wav")
write_tone(TONE)

with ObjekatClient(SOCK) as c:
    def cmd(name, **params):
        return c.send(name, params or None)

    def clear():
        ids = [o["id"] for o in cmd("object.list")["objects"] if not o.get("parent")]
        if ids:
            cmd("object.remove", ids=ids)
        cmd("timesel.clear")
        cmd("selection.clear")

    def clip(start, dur, lane=0, group=None):
        kw = dict(path=TONE, start=start, duration=dur)
        if group:
            kw["group"] = group
            kw["lane"] = lane
        else:
            kw["lane"] = lane
        return cmd("object.add", **kw)["id"]

    def setcurve(oid, pts, param="volume"):
        cmd("automation.set_points", id=oid, param=param,
            points=[{"t": t, "v": v} for t, v in pts])

    def curve(oid, param="volume"):
        for lane in cmd("automation.list", id=oid)["lanes"]:
            if lane["param"] == param:
                return sorted((round(p["t"], 5), round(p["v"], 3)) for p in lane["points"])
        return []

    def rows():
        return cmd("automation.rows")

    def row(oid, param="volume"):
        for r in rows()["rows"]:
            if r["object"] == oid and r["param"] == param:
                return r
        return None

    def zone(oid, a, b, param="volume"):
        r = row(oid, param)
        assert r is not None, "no row for %s %s" % (oid, param)
        cmd("timesel.set", start=a, end=b, lanes=[r["lane"]])

    def covered():
        return [r["object"] for r in rows()["covered"]]

    def pasted(passage, anchor):
        return sorted((round(anchor + t, 5), v) for t, v in passage)

    def wipe_and_add(orig, lo, hi, add):
        keep = [(t, v) for t, v in orig if not (lo - 1e-9 <= t <= hi + 1e-9)]
        return sorted(keep + add)

    def count_objects():
        return len(cmd("object.list")["objects"])

    cmd("project.set_snap", enabled=False)

    # ------------------------------------------------------------------------------------------
    # An object outside any group, and the undo (ONE point per paste)
    # ------------------------------------------------------------------------------------------
    clear()
    a = clip(2.0, 4.0, lane=0)
    b = clip(10.0, 4.0, lane=2)
    pa = [(0.5, -6.0), (1.5, -12.0), (3.0, -3.0)]
    pb = [(1.0, -20.0), (2.0, -30.0), (5.0, -40.0)]          # t = 5 is past B's end: hidden
    setcurve(a, pa)
    setcurve(b, pb)
    cmd("automation.open", id=a, open=True)
    cmd("automation.open", id=b, open=True)
    ra, rb = row(a), row(b)
    check("S1 the rows are on screen, their origin is their object's start",
          ra and rb and abs(ra["origin"] - 2.0) < 1e-9 and abs(rb["origin"] - 10.0) < 1e-9, str((ra, rb)))
    check("S1 the span of a row is its object's window",
          abs(ra["span_start"] - 2.0) < 1e-9 and abs(ra["span_end"] - 6.0) < 1e-9, str(ra))
    zone(a, 2.0, 6.0)
    check("S1 a zone over A reaches A only", covered() == [a], str(covered()))
    r = cmd("edit.copy")
    check("S1 edit.copy goes to the automation band", r["branch"] == "automation", str(r))
    zone(b, 10.0, 14.0)
    check("S1 a zone over B reaches B only", covered() == [b], str(covered()))
    r = cmd("edit.paste")
    check("S1 edit.paste goes to the automation band", r["branch"] == "automation", str(r))
    want = wipe_and_add(pb, 0.0, 4.0, pasted(pa, 0.0))
    check("S1 the passage lands in B, relative to B's start; B's hidden point stays",
          curve(b) == want, "%s != %s" % (curve(b), want))
    check("S1 A is left as it was", curve(a) == sorted(pa), str(curve(a)))
    sel = cmd("selection.get").get("time_selection", {})
    check("S1 the frame lands on the passage, on B's row",
          sel and abs(sel["start"] - 10.0) < 1e-9 and abs(sel["end"] - 14.0) < 1e-9
          and sel["lanes"] == [row(b)["lane"]], str(sel))
    # ONE undo point: the first undo gives B back, the second goes on to the step BEFORE the paste
    # (the curve laid by set_points), which a doubled point would have hidden.
    cmd("edit.undo")
    check("S9 one undo takes the paste back", curve(b) == sorted(pb), str(curve(b)))
    cmd("edit.undo")
    check("S9 the second undo goes past the paste (one point per paste)", curve(b) != sorted(pb), str(curve(b)))

    # ------------------------------------------------------------------------------------------
    # Two clips on the SAME lane, outside a group — both insertion orders
    # ------------------------------------------------------------------------------------------
    for order in ("A then B", "B then A"):
        clear()
        if order == "A then B":
            a = clip(2.0, 4.0, lane=0)
            b = clip(8.0, 4.0, lane=0)
        else:
            b = clip(8.0, 4.0, lane=0)
            a = clip(2.0, 4.0, lane=0)
        pa = [(0.5, -6.0), (1.5, -12.0), (3.0, -3.0), (7.0, -9.0)]    # t = 7 -> abs 9, under B
        pb = [(-3.0, -15.0), (1.0, -20.0), (2.0, -30.0)]              # t = -3 -> abs 5, under A
        setcurve(a, pa)
        setcurve(b, pb)
        cmd("automation.open", id=a, open=True)
        cmd("automation.open", id=b, open=True)
        ra, rb = row(a), row(b)
        tag = "S2 (%s)" % order
        check(tag + " the two rows share one lane number", ra["lane"] == rb["lane"], str((ra, rb)))
        zone(a, 2.0, 6.0)
        check(tag + " a zone over A reaches ONE row, A's", covered() == [a], str(covered()))
        sel_pts = rows()["selected_points"]
        check(tag + " the point selection holds A's visible points only (not B's hidden one)",
              sorted(p["index"] for p in sel_pts if p["object"] == a) == [0, 1, 2]
              and not any(p["object"] == b for p in sel_pts), str(sel_pts))
        cmd("edit.copy")
        zone(b, 8.0, 12.0)
        check(tag + " a zone over B reaches ONE row, B's", covered() == [b], str(covered()))
        sel_pts = rows()["selected_points"]
        check(tag + " the selection takes B's points and not A's hidden one (t = 7)",
              not any(p["object"] == a for p in sel_pts)
              and len([p for p in sel_pts if p["object"] == b]) == 2, str(sel_pts))
        cmd("edit.paste")
        want = wipe_and_add(pb, 0.0, 4.0, pasted([(0.5, -6.0), (1.5, -12.0), (3.0, -3.0)], 0.0))
        check(tag + " the passage (A's three points, not its hidden one) lands in B",
              curve(b) == want, "%s != %s" % (curve(b), want))
        check(tag + " A is intact, its hidden point included", curve(a) == sorted(pa), str(curve(a)))
        # ⌘X over A's zone: A's visible points go, nothing of B does
        zone(a, 2.0, 6.0)
        b_before = curve(b)
        r = cmd("edit.cut")
        check(tag + " edit.cut goes to the automation band", r["branch"] == "automation", str(r))
        check(tag + " the cut takes A's visible points, keeps its hidden one",
              curve(a) == [(7.0, -9.0)], str(curve(a)))
        check(tag + " the cut leaves B alone", curve(b) == b_before, str(curve(b)))

    # ------------------------------------------------------------------------------------------
    # Two children of the SAME sub-lane in a group, then a nested group
    # ------------------------------------------------------------------------------------------
    for nested in (False, True):
        clear()
        tag = "S3 (group)" if not nested else "S4 (nested group)"
        x = clip(2.0, 4.0, lane=0)
        y = clip(8.0, 4.0, lane=0)
        g1 = cmd("group.create", ids=[x, y])["id"]
        top = g1
        if nested:
            z = clip(1.0, 3.0, lane=1)
            top = cmd("group.create", ids=[g1, z])["id"]
            cmd("group.expand", id=top, expanded=True)
        cmd("group.expand", id=g1, expanded=True)
        kids = {o["id"]: o for o in cmd("object.list")["objects"]}
        check(tag + " the two children share a sub-lane",
              kids[x]["lane"] == kids[y]["lane"] and kids[x]["parent"] == g1 == kids[y]["parent"],
              str((kids[x]["lane"], kids[y]["lane"])))
        px = [(0.5, -6.0), (1.5, -12.0), (3.0, -3.0), (7.0, -9.0)]
        py = [(-3.0, -15.0), (1.0, -20.0), (2.0, -30.0)]
        setcurve(x, px)
        setcurve(y, py)
        cmd("automation.open", id=x, open=True)
        cmd("automation.open", id=y, open=True)
        rx, ry = row(x), row(y)
        check(tag + " both rows are on screen at the same lane",
              rx and ry and rx["lane"] == ry["lane"], str((rx, ry)))
        check(tag + " their origins are ABSOLUTE starts",
              abs(rx["origin"] - kids[x]["start"]) < 1e-9 and abs(ry["origin"] - kids[y]["start"]) < 1e-9,
              str((rx["origin"], ry["origin"], kids[x]["start"], kids[y]["start"])))
        sx = kids[x]["start"]
        sy = kids[y]["start"]
        zone(x, sx, sx + 4.0)
        check(tag + " a zone over X reaches X only", covered() == [x], str(covered()))
        cmd("edit.copy")
        zone(y, sy, sy + 4.0)
        check(tag + " a zone over Y reaches Y only", covered() == [y], str(covered()))
        r = cmd("edit.paste")
        want = wipe_and_add(py, 0.0, 4.0, pasted([(0.5, -6.0), (1.5, -12.0), (3.0, -3.0)], 0.0))
        check(tag + " the passage lands in Y", curve(y) == want, "%s != %s" % (curve(y), want))
        check(tag + " X is intact", curve(x) == sorted(px), str(curve(x)))

    # ------------------------------------------------------------------------------------------
    # Negative time: a child that starts before 0
    # ------------------------------------------------------------------------------------------
    clear()
    p0 = clip(4.0, 4.0, lane=0)
    g = cmd("group.create", ids=[p0])["id"]
    cmd("group.expand", id=g, expanded=True)
    n = clip(-1.0, 4.0, lane=0, group=g)
    kids = {o["id"]: o for o in cmd("object.list")["objects"]}
    check("S5 a child starts before zero", abs(kids[n]["start"] - (-1.0)) < 1e-9, str(kids[n]["start"]))
    pn = [(0.5, -6.0), (1.5, -12.0), (3.0, -3.0)]      # abs -0.5 (before the zone), 0.5, 2.0
    setcurve(n, pn)
    setcurve(p0, [(1.0, -20.0)])
    cmd("automation.open", id=n, open=True)
    cmd("automation.open", id=p0, open=True)
    check("S5 the origin of the row is negative", abs(row(n)["origin"] - (-1.0)) < 1e-9, str(row(n)))
    zone(n, 0.0, 3.0)
    check("S5 a zone [0, 3] reaches the negative-start child only", covered() == [n], str(covered()))
    cmd("edit.copy")
    zone(p0, 4.0, 7.0)
    check("S5 a zone over the next child reaches it only", covered() == [p0], str(covered()))
    cmd("edit.paste")
    # the passage [0, 3] of N holds abs 0.5 (v -12) and abs 2.0 (v -3): relative to the passage, 0.5 and 2.0
    want = wipe_and_add([(1.0, -20.0)], 0.0, 3.0, [(0.5, -12.0), (2.0, -3.0)])
    check("S5 the passage lands relative to the zone's start, not to a negative origin",
          curve(p0) == want, "%s != %s" % (curve(p0), want))
    check("S5 the negative-start child keeps its point before the zone", curve(n) == sorted(pn), str(curve(n)))

    # ------------------------------------------------------------------------------------------
    # Varispeed 1.5: the span is the (shortened) window, the passage stays in timeline seconds
    # ------------------------------------------------------------------------------------------
    clear()
    a = clip(2.0, 3.0, lane=0)
    cmd("object.set_speed", id=a, ratio=1.5)
    da = cmd("object.get", id=a)["duration"]
    check("S6 the clip is shorter at 1.5", abs(da - 2.0) < 1e-6, str(da))
    b = clip(2.0 + da, 4.0, lane=0)                        # laid exactly where A ends
    pa = [(0.25, -6.0), (1.0, -12.0)]
    pb = [(0.5, -20.0), (3.0, -30.0)]
    setcurve(a, pa)
    setcurve(b, pb)
    cmd("automation.open", id=a, open=True)
    cmd("automation.open", id=b, open=True)
    ra = row(a)
    check("S6 the span of A is its stretched window", abs(ra["span_end"] - (2.0 + da)) < 1e-6, str(ra))
    zone(b, 2.0 + da, 2.0 + da + 3.0)
    check("S6 a zone over B, which starts where A ends, reaches B only", covered() == [b], str(covered()))
    zone(a, 2.0, 2.0 + da)
    check("S6 a zone over A, which ends where B starts, reaches A only", covered() == [a], str(covered()))
    cmd("edit.copy")
    zone(b, 2.0 + da, 2.0 + da + da)
    cmd("edit.paste")
    want = wipe_and_add(pb, 0.0, da, pasted(pa, 0.0))
    check("S6 the passage keeps its timeline seconds (no varispeed scaling)",
          curve(b) == want, "%s != %s" % (curve(b), want))

    # ------------------------------------------------------------------------------------------
    # B2 — a caret in a band, ⌘V with an OBJECT clipboard full
    # ------------------------------------------------------------------------------------------
    for in_group in (False, True):
        clear()
        tag = "S7 (in a group)" if in_group else "S7 (no group)"
        a = clip(2.0, 4.0, lane=0)
        b = clip(10.0, 4.0, lane=2)
        other = clip(16.0, 2.0, lane=4)
        if in_group:
            g = cmd("group.create", ids=[a, b])["id"]
            cmd("group.expand", id=g, expanded=True)
        kids = {o["id"]: o for o in cmd("object.list")["objects"]}
        sa, sb = kids[a]["start"], kids[b]["start"]
        pa = [(0.5, -6.0), (1.5, -12.0), (3.0, -3.0)]
        pb = [(1.0, -20.0), (2.0, -30.0), (3.5, -35.0)]
        setcurve(a, pa)
        setcurve(b, pb)
        cmd("automation.open", id=a, open=True)
        cmd("automation.open", id=b, open=True)
        zone(a, sa, sa + 4.0)
        cmd("edit.copy")                                   # the AUTOMATION clipboard
        cmd("selection.set", ids=[other])
        cmd("clipboard.copy")                              # the OBJECT clipboard, full
        cmd("timesel.clear")
        n_objects = count_objects()
        # the click in B's band: a caret on its row, the cursor at the instant
        cmd("caret.set", lane=row(b)["lane"], time=sb + 1.0)
        check(tag + " the caret sits in B's row", (rows()["caret"] or {}).get("object") == b, str(rows()["caret"]))
        r = cmd("edit.paste")
        check(tag + " edit.paste on a caret in a band goes to the band", r["branch"] == "automation_caret", str(r))
        check(tag + " no object was pasted", count_objects() == n_objects, "%d vs %d" % (count_objects(), n_objects))
        want = wipe_and_add(pb, 1.0, 5.0, pasted(pa, 1.0))
        check(tag + " the passage lands at the caret's instant", curve(b) == want, "%s != %s" % (curve(b), want))
        check(tag + " A is untouched", curve(a) == sorted(pa), str(curve(a)))
        cmd("edit.undo")
        check(tag + " one undo takes it back", curve(b) == sorted(pb), str(curve(b)))
        # a caret OUTSIDE the band's span: the objects' paste, as before
        cmd("caret.set", lane=row(b)["lane"], time=sb + 30.0)
        check(tag + " a caret past the band's window names no row", rows()["caret"] is None, str(rows()["caret"]))
        r = cmd("edit.paste")
        check(tag + " ... and ⌘V falls back on the objects", r["branch"] == "objects", str(r))
        cmd("edit.undo")
        # ⌘C on a caret alone is unchanged
        cmd("caret.set", lane=row(b)["lane"], time=sb + 1.0)
        r = cmd("edit.copy")
        check(tag + " ⌘C on a caret alone does nothing (no surface holds the keyboard)",
              r["branch"] == "none", str(r))
        cmd("selection.set", ids=[b])
        r = cmd("edit.copy")
        check(tag + " ⌘C with the object selected copies the object", r["branch"] == "objects", str(r))

    # ------------------------------------------------------------------------------------------
    # B3 — the frame follows the rows after a paste that empties one
    # ------------------------------------------------------------------------------------------
    clear()
    a = clip(2.0, 6.0, lane=0)
    pv = [(0.5, -6.0), (1.5, -12.0), (3.0, -3.0)]
    pp = [(4.0, 0.5)]                                       # pan: nothing before t = 4
    setcurve(a, pv)
    setcurve(a, pp, param="pan")
    cmd("automation.open", id=a, open=True)
    rv, rp = row(a, "volume"), row(a, "pan")
    check("S8 two rows, volume then pan", rv and rp and rp["lane"] == rv["lane"] + 1, str((rv, rp)))
    # copy an EMPTY passage of the pan row (nothing in [2, 5] local 0..3)
    zone(a, 2.0, 5.0, param="pan")
    r = cmd("edit.copy")
    check("S8 an empty passage can be copied", r["branch"] == "automation", str(r))
    zone(a, 2.0, 5.0, param="volume")
    cmd("edit.paste")
    check("S8 the paste wipes the volume curve", curve(a, "volume") == [], str(curve(a, "volume")))
    sel = cmd("selection.get").get("time_selection")
    rv2 = row(a, "volume")
    if rv2 is not None:
        check("S8 the frame follows the volume row to where it is now",
              sel and sel["lanes"] == [rv2["lane"]], "%s vs %s" % (sel, rv2))
    else:
        check("S8 the row is gone: no frame left over the row that took its lane", sel is None, str(sel))
    pan_before = curve(a, "pan")
    cmd("edit.paste")
    check("S8 a second paste does not reach the pan row", curve(a, "pan") == pan_before, str(curve(a, "pan")))
    check("S8 the pan row is where it was", row(a, "pan") is not None, str(rows()["rows"]))

    clear()

print("\n%d assertions, %d failed" % (count, len(fails)))
print("ALL PASS" if not fails else "FAILED:\n  " + "\n  ".join(fails))
sys.exit(1 if fails else 0)

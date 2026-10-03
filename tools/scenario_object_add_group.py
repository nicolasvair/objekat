#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""`object.add {group}` — a clip laid INSIDE a group, whatever its depth and its fold.

It is what the "External edit" script needs to bring a retouched file back next to its source:
a root object comes back on a new root row, a CHILD of a group comes back as a child of the SAME
group (a new sub-lane after the last one).

    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --socket=/tmp/o.sock
    ./scenario_object_add_group.py /tmp/o.sock

Exit: 0 if every assertion passes, 1 otherwise.
"""

import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

if len(sys.argv) != 2:
    print(__doc__)
    sys.exit(2)

SOCK = sys.argv[1]
BIP = os.path.join(HERE, "fixtures", "bip.wav")

fails = []
total = 0


def check(label, ok, detail=""):
    global total
    total += 1
    print(("ok    " if ok else "FAIL  ") + label + ("" if ok else "   " + str(detail)))
    if not ok:
        fails.append(label)


with ObjekatClient(SOCK, timeout=60) as c:

    def cmd(name, **params):
        return c.send(name, params or None)

    def obj(oid):
        # What is on screen: a child of a FOLDED group is not listed (the API reads `laneEntries`).
        return next((o for o in cmd("object.list")["objects"] if o["id"] == oid), None)

    def refuses(**params):
        try:
            cmd("object.add", **params)
            return False
        except ObjekatError:
            return True

    cmd("project.new")
    a = cmd("object.add", path=BIP, lane=0, start=1.0)
    b = cmd("object.add", path=BIP, lane=1, start=1.0)
    g = cmd("group.create", ids=[a["id"], b["id"]])["id"]
    cmd("group.expand", id=g, expanded=False)
    cmd("group.expand", id=g, expanded=True)
    before_lane = max(obj(a["id"])["lane"], obj(b["id"])["lane"])
    cmd("group.expand", id=g, expanded=False)

    # 1. a FOLDED group: the clip lands inside it, on a new sub-lane after the last one.
    r = cmd("object.add", path=BIP, group=g, start=4.0)
    check("folded group: answered parent = the group", r.get("parent") == g, r)
    cmd("group.expand", id=g, expanded=True)
    o = obj(r["id"])
    check("folded group: the clip is a child of the group", o is not None and o["parent"] == g, o)
    check("folded group: default sub-lane = after the last one", o and o["lane"] == before_lane + 1, o)
    check("folded group: start kept as given", o and abs(o["start"] - 4.0) < 1e-6, o)

    # 2. an EXPANDED group, an explicit sub-lane.
    r2 = cmd("object.add", path=BIP, group=g, lane=0, start=6.0)
    o2 = obj(r2["id"])
    check("expanded group: child of the group", o2 is not None and o2["parent"] == g, o2)
    check("expanded group: explicit sub-lane honoured", o2 and o2["lane"] == 0, o2)

    # 3. a child may start before 0 (the wall at 0 is the group's, not the child's).
    r3 = cmd("object.add", path=BIP, group=g, start=-0.5)
    o3 = obj(r3["id"])
    check("child: a negative start is not clamped", o3 is not None and o3["start"] < 0, o3)

    # 4. a nested group.
    inner = cmd("group.create", ids=[r["id"], r2["id"]])["id"]
    r4 = cmd("object.add", path=BIP, group=inner, start=2.0)
    cmd("group.expand", id=inner, expanded=True)
    o4 = obj(r4["id"])
    check("nested group: child of the INNER group", o4 is not None and o4["parent"] == inner, o4)

    # 5. refusals and the unchanged root behaviour.
    check("an unknown group is refused", refuses(path=BIP, group="00000000-0000-0000-0000-000000000000"))
    check("a clip is not a group", refuses(path=BIP, group=a["id"]))
    r5 = cmd("object.add", path=BIP, lane=40, start=-3.0)
    o5 = obj(r5["id"])
    check("root add: no parent", o5 is not None and o5["parent"] is None, o5)
    check("root add: start clamped at 0", o5 and o5["start"] >= 0, o5)

    # 6. one undo takes the clip back out.
    r6 = cmd("object.add", path=BIP, group=g, start=9.0)
    check("the add exists", obj(r6["id"]) is not None)
    cmd("edit.undo")
    check("one undo removes it", obj(r6["id"]) is None)

print()
print("%d assertions, %d failed" % (total, len(fails)))
if fails:
    print("FAILED: " + "; ".join(fails))
    sys.exit(1)
print("ALL PASS")

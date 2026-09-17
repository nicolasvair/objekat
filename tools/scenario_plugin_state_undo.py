#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Undoing a plugin's state no longer destroys the object that carries it.

What it is out to prove — and what it CANNOT reach, which is worth saying first: the gesture
this was written for is an automation curve drawn on a plugin parameter, and the command API
has no `automation.*` door. So the scenario takes the same road by the other end: a plugin's
STATE is what an automation gesture used to move (a curve lives in the plugin's tree), and
changing a parameter moves exactly the same thing. The ORDER is what matters and is reproduced
here — the snapshot is taken BEFORE the state changes, so the undo finds it different:

    object.move        → the bus pushes the undo snapshot (the plugin's state as it stands)
    plugin.set_param   → the state moves, outside any snapshot
    edit.undo          → the state to restore differs from the live one

That used to make the object UNRECOVERABLE: it was destroyed and its plugin reloaded whole —
594 ms measured for a UADx Anthem Synth, and the object's whole chain rebuilt around it. The
state is now re-applied to the LIVE instance.

Three things are asserted, for a built-in and for an external plugin alike:

  • the value really comes back (the undo undoes);
  • the undo is INSTANT — a reload of an external plugin cannot hide under 150 ms, where every
    measurement of that path sat between 590 and 760 ms;
  • the plugin answers straight away afterwards. A rebuilt object reloads its plugin
    asynchronously, and `plugin.get_params` then returns nothing for as long as it takes.

    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --socket=/tmp/o.sock
    ./scenario_plugin_state_undo.py /tmp/o.sock /tmp/trial/project.objekat.json [--external=IDENTIFIER]

Exit: 0 if every assertion passes, 1 otherwise.
"""

import sys, os, time, json

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

if len(sys.argv) < 3:
    print(__doc__)
    sys.exit(2)

SOCK, PROJ = sys.argv[1], sys.argv[2]
EXTERNAL = None
for a in sys.argv[3:]:
    if a.startswith("--external="):
        EXTERNAL = a.split("=", 1)[1]

BIP = os.path.join(HERE, "fixtures", "bip.wav")
fails = []
total = 0


def check(label, ok, detail=""):
    global total
    total += 1
    print(("ok    " if ok else "FAIL  ") + label + ("" if ok else "   " + str(detail)))
    if not ok:
        fails.append(label)


def settled_params(c, plugin, want=1, timeout=30.0):
    """The parameters of a live instance, waited for. Used to LOAD, never to assert."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            ps = c.send("plugin.get_params", {"plugin": plugin})["params"]
        except ObjekatError:
            ps = []
        if len(ps) >= want:
            return ps
        time.sleep(0.25)
    return []


def round_trip(c, kind, obj, plugin, index):
    """One move / one param change / one undo, and the three questions asked of it."""
    ps = settled_params(c, plugin, want=index + 1)
    if not ps:
        check("%s: the instance answers" % kind, False, "no parameter read")
        return
    p = ps[index]
    before = p["value"]
    target = p["min"] + (p["max"] - p["min"]) * (0.9 if before < (p["min"] + p["max"]) / 2 else 0.1)

    c.send("object.move", {"id": obj, "start": 4})     # the snapshot is taken HERE
    c.send("plugin.set_param", {"plugin": plugin, "index": index, "value": target})
    c.send("wait_idle", {"timeout_ms": 30000})
    moved = c.send("plugin.get_params", {"plugin": plugin})["params"][index]["value"]
    check("%s: the parameter did move" % kind, abs(moved - before) > 1e-4,
          "before %s, after %s" % (before, moved))

    t0 = time.time()
    c.send("edit.undo")
    c.send("wait_idle", {"timeout_ms": 30000})
    ms = (time.time() - t0) * 1000

    straight_away = c.send("plugin.get_params", {"plugin": plugin})["params"]
    check("%s: the plugin answers straight away" % kind, len(straight_away) >= index + 1,
          "%d parameters" % len(straight_away))
    if len(straight_away) >= index + 1:
        check("%s: the value comes back" % kind,
              abs(straight_away[index]["value"] - before) < 1e-3,
              "expected %s, got %s" % (before, straight_away[index]["value"]))
    check("%s: the undo is instant (%.0f ms)" % (kind, ms), ms < 150.0,
          "a reload cannot hide under 150 ms")
    check("%s: the object is back where it was" % kind,
          abs(c.send("object.get", {"id": obj})["start"]) < 1e-6)


os.makedirs(os.path.dirname(PROJ), exist_ok=True)
with ObjekatClient(SOCK, timeout=180) as c:
    c.send("app.set_dialog_policy", {"policy": "assume_yes"})
    c.send("project.new")
    c.send("project.save_as", {"path": PROJ})

    # --- a built-in: its parameters ARE the properties of its tree
    a = c.send("object.add", {"path": BIP, "lane": 0, "start": 0})["id"]
    eq = c.send("plugin.add", {"host": a, "identifier": "4bandEq"})["plugin"]["id"]
    c.send("wait_idle", {"timeout_ms": 10000})
    round_trip(c, "built-in", a, eq, 0)

    # --- an external one: a binary chunk, and an instance that costs seconds to reload
    if EXTERNAL:
        m = c.send("midi.create_clip", {"start": 0, "end": 8, "lane": 1})["id"]
        inst = c.send("instrument.set", {"id": m, "identifier": EXTERNAL})["instrument"]["id"]
        c.send("wait_idle", {"timeout_ms": 60000})
        round_trip(c, "external", m, inst, 3)
    else:
        print("      (no --external=… : the external half is not run)")

print("\n%d assertion(s), %s" % (total,
                                 "ALL PASS" if not fails else "%d FAILED: %s" % (len(fails), fails)))
sys.exit(1 if fails else 0)

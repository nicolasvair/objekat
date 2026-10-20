#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The FX tool (F): what its strip shows for an object, read through `tool.fx_strip`.

The hover itself (the strip coming up over the block, staying up on the way onto it) cannot be
driven from here: the headless instance has no timeline view. What this proves is the half under
it — the strip's MODEL: the chain's order left to right, a gain stage with no power button, a
parallel block as one box, an FX link's block as a framed group, a send's marker skipped — and
that the strip's power button (the signal view's own function) is one undo point. The geometry
is asserted by `tools/test_fx_strip_layout.swift`.

    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --socket=/tmp/o.sock
    ./scenario_fx_tool.py /tmp/o.sock

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


def check(label, ok, detail=""):
    if ok:
        print("ok    " + label)
    else:
        fails.append(label)
        print("FAIL  %s  %s" % (label, detail))


with ObjekatClient(SOCK) as c:
    def cmd(_name, **params):
        return c.send(_name, params or None)

    cmd("project.new")
    X = cmd("object.add", path=BIP, lane=0, start=0.0)["id"]

    # --- the tool ---------------------------------------------------------------------------------
    t = cmd("tool.set", tool="fx")
    check("tool.set fx arms the FX tool, locked", t["tool"] == "fx" and t["locked"] is True, str(t))
    check("tool.get reads it back", cmd("tool.get")["tool"] == "fx")

    def strip(i=X):
        return cmd("tool.fx_strip", id=i)

    s = strip()
    check("an object with no plugin: an empty strip", s["entries"] == [] and s["bins"] == [], str(s))
    check("…which still has a size (its 'no plugin' box)", s["size"]["w"] > 0 and s["size"]["h"] > 0)

    def add(ident):
        return cmd("plugin.add", host=X, identifier=ident, format="TracktionInternal")["plugin"]["id"]

    eq = add("4bandEq")
    rev = add("reverb")
    cmd("plugin.add_gain_stage", host=X, face="gain")
    comp = add("compressor")

    def top():
        return [p for p in cmd("plugin.list", host=X)["plugins"]]

    s = strip()
    ids = [e["id"] for e in s["entries"]]
    chain_ids = [p["id"] for p in top() if not p.get("is_rack")]
    check("the strip reads the chain left to right, in its order", ids == chain_ids, "%s vs %s" % (ids, chain_ids))
    kinds = {e["id"]: e for e in s["entries"]}
    check("a plugin: a power button and an editor",
          kinds[eq]["kind"] == "plugin" and kinds[eq]["toggle"] and kinds[eq]["editor"], str(kinds[eq]))
    gs = [e for e in s["entries"] if e["kind"] == "gain_stage"]
    check("a gain stage: a box with NO power button and no editor",
          len(gs) == 1 and not gs[0]["toggle"] and not gs[0]["editor"], str(gs))

    # --- on / off through the strip's door (the signal view's) -----------------------------------
    cmd("plugin.toggle", host=X, plugin=eq)
    check("off: the strip shows it off",
          next(e for e in strip()["entries"] if e["id"] == eq)["enabled"] is False)
    cmd("edit.undo")
    check("ONE undo gives it back", next(e for e in strip()["entries"] if e["id"] == eq)["enabled"] is True)

    # --- a parallel block: ONE box ----------------------------------------------------------------
    order = [p["id"] for p in top()]
    cmd("plugin.branch", host=X, at=order.index(comp))
    s = strip()
    racks = [e for e in s["entries"] if e["kind"] == "rack"]
    check("a parallel block is one box, with its branch count, no power button",
          len(racks) == 1 and racks[0]["branches"] == 2 and not racks[0]["toggle"] and not racks[0]["editor"],
          str(racks))
    check("…and its plugins are not boxes of their own", comp not in [e["id"] for e in s["entries"]])

    # --- an FX link block: a framed group --------------------------------------------------------
    cmd("fxlink.create", host=X, plugins=[rev], name="Bin")
    s = strip()
    check("one bin, named", len(s["bins"]) == 1 and s["bins"][0]["name"] == "Bin"
          and s["bins"][0]["detached"] is False, str(s["bins"]))
    inbin = [e for e in s["entries"] if e["bin"] == 0]
    check("the bin's plugin sits in it, with its power button",
          len(inbin) == 1 and inbin[0]["name"] and inbin[0]["toggle"], str(inbin))
    check("the trunk's boxes are outside it", all(e["bin"] is None for e in s["entries"] if e not in inbin))
    h_bins = s["size"]["h"]
    check("a strip with a bin is taller (its name band)", h_bins > strip(cmd("object.add", path=BIP, lane=2, start=0.0)["id"])["size"]["h"])
    # The bin's toggle goes through the bin (the definition): the instance shows it.
    cmd("plugin.toggle", host=X, plugin=inbin[0]["id"])
    check("a bin plugin turned off through the strip's door reads off",
          next(e for e in strip()["entries"] if e["id"] == inbin[0]["id"])["enabled"] is False)
    cmd("edit.undo")

    # --- a send's place on the trunk is not a plugin ---------------------------------------------
    A = cmd("aux.create", start=0.0, end=3.0, lane=4)["id"]
    before = [e["id"] for e in strip()["entries"]]
    cmd("send.create", id=X, aux=A, position="chain", index=1)
    after = [e["id"] for e in strip()["entries"]]
    has_marker = any(p.get("send_marker") or p.get("is_send_marker") for p in top())
    check("a send in the chain adds no box", before == after, "%s vs %s (marker in list: %s)" % (before, after, has_marker))

    # Errors.
    try:
        cmd("tool.fx_strip", id="00000000-0000-0000-0000-000000000000")
        check("an unknown object is refused", False)
    except ObjekatError:
        check("an unknown object is refused", True)

    cmd("tool.set", tool="selection")

print("\n%d failed" % len(fails) if fails else "\nALL PASS")
sys.exit(1 if fails else 0)

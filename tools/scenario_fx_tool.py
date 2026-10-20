#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The FX tool (F): what its mini signal view shows for an object, read through `tool.fx_strip`.

The hover itself (the mini view drawn inside the hovered block) cannot be driven from here: the
headless instance has no timeline view. What this proves is the half under it — the MODEL: the
chain's order left to right, a gain stage with no power button, a parallel block as its branches
(each plugin a box of its own, stacked by branch), an FX link's block as a framed group, a send's
marker skipped — the LAYOUT at a few block sizes (labeled → dots → "n FX"), and that the power
button (the signal view's own function) is one undo point. The geometry is asserted by
`tools/test_fx_strip_layout.swift`.

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
    check("an object with no plugin: no entries", s["entries"] == [] and s["bins"] == [], str(s))
    check("…which still has a size (its 'no plugins' line)", s["size"]["w"] > 0 and s["size"]["h"] > 0)
    check("…and an empty tree", s["tree"] == [])

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

    # --- a parallel block: its branches, stacked ------------------------------------------------
    order = [p["id"] for p in top()]
    cmd("plugin.branch", host=X, at=order.index(comp))
    s = strip()
    racks = [i for i, e in enumerate(s["entries"]) if e["kind"] == "rack"]
    check("a parallel block: one carrier entry, with its branch count, no power button",
          len(racks) == 1 and s["entries"][racks[0]]["branches"] == 2
          and not s["entries"][racks[0]]["toggle"] and not s["entries"][racks[0]]["editor"], str(racks))
    inner = [e for e in s["entries"] if e["rack"] == (racks[0] if racks else -1)]
    check("…and its plugins ARE entries, with their branch and a power button",
          comp in [e["id"] for e in inner] and all(e["branch"] is not None for e in inner)
          and any(e["toggle"] for e in inner), str(inner))
    tree_racks = [n for n in s["tree"] if isinstance(n, dict)]
    check("the tree holds the block with its branches",
          len(tree_racks) == 1 and len(tree_racks[0]["branches"]) == 2, str(s["tree"]))
    # The layout at three sizes.
    big = cmd("tool.fx_strip", id=X, w=900, h=90)["layout"]
    check("a tall wide block: labeled boxes", big["detail"] == "labeled" and len(big["boxes"]) >= 4, str(big)[:200])
    byentry = {b["entry"]: b for b in big["boxes"]}
    ci = [i for i, e in enumerate(s["entries"]) if e["id"] == comp][0]
    trunk = [i for i, e in enumerate(s["entries"]) if e["rack"] is None and e["kind"] != "rack"]
    check("…the branch's plugin sits off the trunk's row (stacked)",
          ci in byentry and any(byentry[t]["y"] != byentry[ci]["y"] for t in trunk if t in byentry))
    small = cmd("tool.fx_strip", id=X, w=200, h=12)["layout"]
    check("a thin block: dots, no power zone", small["detail"] in ("dots", "folded_dots")
          and not any(b["power"] for b in small["boxes"]), str(small)[:200])
    tiny = cmd("tool.fx_strip", id=X, w=40, h=18)["layout"]
    check("a narrow block: n FX", tiny["detail"] == "count", str(tiny))
    E = cmd("object.add", path=BIP, lane=6, start=0.0)["id"]
    check("an object with no plugin: the 'no plugins' line",
          cmd("tool.fx_strip", id=E, w=200, h=30)["layout"]["detail"] == "empty")
    # On / off of a branch's plugin through the same door.
    cmd("plugin.toggle", host=X, plugin=comp)
    check("a branch's plugin turned off reads off",
          next(e for e in strip()["entries"] if e["id"] == comp)["enabled"] is False)
    cmd("edit.undo")
    check("…and ONE undo gives it back",
          next(e for e in strip()["entries"] if e["id"] == comp)["enabled"] is True)

    # --- an FX link block: a framed group --------------------------------------------------------
    cmd("fxlink.create", host=X, plugins=[rev], name="Bin")
    s = strip()
    check("one bin, named", len(s["bins"]) == 1 and s["bins"][0]["name"] == "Bin"
          and s["bins"][0]["detached"] is False, str(s["bins"]))
    inbin = [e for e in s["entries"] if e["bin"] == 0]
    check("the bin's plugin sits in it, with its power button",
          len(inbin) == 1 and inbin[0]["name"] and inbin[0]["toggle"], str(inbin))
    check("the trunk's boxes are outside it", all(e["bin"] is None for e in s["entries"] if e not in inbin))
    lb = cmd("tool.fx_strip", id=X, w=900, h=90)["layout"]
    check("the labeled layout frames the bin", lb["bins"] == 1, str(lb["bins"]))
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

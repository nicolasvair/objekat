#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""OBJEKAT's plugin PRESETS (`preset.*`) — a scenario that asserts, against a headless instance.

    objekat.app/Contents/MacOS/objekat --headless --api --no-recent --no-audio --language=en --socket=/tmp/opr.sock
    ./scenario_presets.py /tmp/opr.sock

What it proves, on a built-in plugin (its parameters are readable with no window):
  • the library of a `--no-recent` process lives in the temporary directory, never in the user's;
  • `preset.save` stores the live state; a parameter moved afterwards marks the status `modified`;
  • `preset.load` lays it back on the LIVE instance (same id, no rebuild), as ONE undo point, and
    keeps the instance's own bypass;
  • a DEFAULT preset is laid on a FRESH insertion only: a duplicate keeps its own state;
  • loading on a linked plugin carries the state to the linked instance;
  • delete takes the default with it; refusals answer `not_found`.
Exit: 0 if every assertion passes, 1 otherwise.
"""

import math, os, sys, tempfile, wave

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

if len(sys.argv) != 2:
    print(__doc__)
    sys.exit(2)

SOCK = sys.argv[1]
TMP = tempfile.mkdtemp(prefix="presets_")
SRC = os.path.join(TMP, "tone.wav")
with wave.open(SRC, "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(48000)
    w.writeframes(b"".join(int(8000 * math.sin(2 * math.pi * 440 * i / 48000)).to_bytes(2, "little", signed=True)
                           for i in range(48000)))

fails, total = [], 0


def check(label, ok, detail=""):
    global total
    total += 1
    print(("ok    " if ok else "FAIL  ") + label + ("" if ok else "   " + str(detail)))
    if not ok:
        fails.append(label)


USER_LIB = os.path.expanduser("~/Library/Application Support/Objekat/Presets")
user_lib_before = os.path.exists(USER_LIB) and sorted(os.listdir(USER_LIB))

with ObjekatClient(SOCK) as c:
    def cmd(_name, **params):
        return c.send(_name, params or None)

    def refused(_name, **params):
        try:
            c.send(_name, params or None)
            return None
        except ObjekatError as e:
            return e.code

    def idle():
        cmd("wait_idle", timeout_ms=30000)

    cmd("app.set_dialog_policy", policy="assume_yes")
    cmd("project.new")
    root = cmd("preset.library")["root"]
    check("the library of a --no-recent process is temporary",
          root.startswith(tempfile.gettempdir().rstrip("/")) or "/T/" in root or root.startswith("/var") or root.startswith("/private"),
          root)
    check("...and is not the user's", not root.startswith(os.path.expanduser("~/Library")), root)

    av = cmd("plugin.list_available")["plugins"]
    internal = [p for p in av if p.get("format") == "TracktionInternal" or p.get("format_name") == "TracktionInternal"]
    pick = next((p for p in internal if p["identifier"] in ("4bandEq", "lowpass", "reverb")), internal[0] if internal else None)
    if pick is None:
        print("no built-in plugin in the catalogue"); sys.exit(2)
    ident = pick["identifier"]

    A = cmd("object.add", path=SRC, lane=0, start=0)["id"]
    B = cmd("object.add", path=SRC, lane=1, start=0)["id"]
    idle()
    P = cmd("plugin.add", host=A, identifier=ident, format="TracktionInternal")["plugin"]["id"]
    idle()

    def params(pid):
        return cmd("plugin.get_params", plugin=pid)["params"]

    prm = params(P)
    check("the built-in has parameters", len(prm) > 0, prm)
    k = prm[0]["index"]
    lo, hi = prm[0]["min"], prm[0]["max"]
    v1, v2 = lo + 0.3 * (hi - lo), lo + 0.7 * (hi - lo)

    def value(pid):
        return next(p["value"] for p in params(pid) if p["index"] == k)

    def near(a, b):
        return abs(a - b) <= 1e-3 * max(1.0, abs(hi - lo))

    cmd("plugin.set_param", plugin=P, index=k, value=v1)
    check("set_param took", near(value(P), v1), value(P))
    s = cmd("preset.save", plugin=P, name="  Bright  ")
    check("save trims the name", s["name"] == "Bright", s)
    check("save names the status, unmodified", s["status"] == {"name": "Bright", "factory": False, "modified": False}, s)
    lst = cmd("preset.list", plugin=P)
    check("list shows it", lst["presets"] == ["Bright"], lst)
    check("no default yet", lst["default"] is None, lst)
    check("a built-in has no factory programs", lst["factory"] == [], lst)

    cmd("plugin.set_param", plugin=P, index=k, value=v2)
    check("a moved parameter marks the preset modified",
          cmd("preset.list", plugin=P)["status"]["modified"] is True)

    cmd("preset.load", plugin=P, name="bright")          # case-insensitive, like the files
    check("load lays the stored value back", near(value(P), v1), value(P))
    check("load clears the modified mark", cmd("preset.list", plugin=P)["status"]["modified"] is False)
    chain = cmd("plugin.list", host=A)["plugins"]
    check("the instance is the same one (no rebuild)", [p["id"] for p in chain if p["id"] == P] == [P], chain)
    cmd("edit.undo")
    idle()
    check("ONE undo point gives the previous value back", near(value(P), v2), value(P))
    cmd("edit.redo")
    idle()
    check("redo lays the preset again", near(value(P), v1), value(P))

    # bypass is the instance's, never the preset's
    cmd("plugin.toggle", host=A, plugin=P)
    cmd("plugin.set_param", plugin=P, index=k, value=v2)
    cmd("preset.load", plugin=P, name="Bright")
    en = next(p["enabled"] for p in cmd("plugin.list", host=A)["plugins"] if p["id"] == P)
    check("a preset load keeps the bypass", en is False, en)
    cmd("plugin.toggle", host=A, plugin=P)

    # the default, on a fresh insertion only
    d = cmd("preset.set_default", plugin=P, name="Bright")
    check("set_default answers the default", d["default"] == "Bright", d)
    Q = cmd("plugin.add", host=B, identifier=ident, format="TracktionInternal")["plugin"]["id"]
    idle()
    check("a FRESH insertion starts on the default preset", near(value(Q), v1), value(Q))
    check("...and its status names it", (cmd("preset.list", plugin=Q)["status"] or {}).get("name") == "Bright")
    def leaves(host):
        out = []
        for p in cmd("plugin.list", host=host)["plugins"]:
            out += p["plugins"] if p.get("is_fx_block") else [p]
        return out

    # a duplicate carries its source's state (a copy becomes an FX link's member: the bin is shared)
    cmd("plugin.set_param", plugin=P, index=k, value=v2)
    before = {o["id"] for o in cmd("object.list")["objects"]}
    cmd("object.duplicate", ids=[A])
    idle()
    new_ids = [o["id"] for o in cmd("object.list")["objects"] if o["id"] not in before]
    dp = leaves(new_ids[0]) if new_ids else []
    check("a DUPLICATE keeps its source's state, not the default", bool(dp) and near(value(dp[0]["id"]), v2),
          dp and value(dp[0]["id"]))
    P = next(q["id"] for q in leaves(A))            # the original's instance (inside the bin now)
    cmd("preset.load", plugin=P, name="Bright")
    check("a load on an FX link member carries to the other member", bool(dp) and near(value(dp[0]["id"]), v1),
          dp and value(dp[0]["id"]))

    # a ⌘-linked instance follows a load
    C = cmd("object.add", path=SRC, lane=3, start=0)["id"]
    R = cmd("object.add", path=SRC, lane=4, start=0)["id"]
    idle()
    PC = cmd("plugin.add", host=C, identifier=ident, format="TracktionInternal")["plugin"]["id"]
    idle()
    L = cmd("plugin.link", **{"from": C, "plugin": PC, "to": R})["plugins"][0]
    idle()
    cmd("plugin.set_param", plugin=PC, index=k, value=v2)
    cmd("plugin.set_param", plugin=L, index=k, value=v2)
    cmd("preset.load", plugin=PC, name="Bright")
    check("a load on a linked plugin carries to the linked instance", near(value(L), v1), value(L))
    check("...whose status names it too", (cmd("preset.list", plugin=L)["status"] or {}).get("name") == "Bright")

    # an EXTERNAL plugin (Apple's AULowpass): its state carries `base64:layout`, which XMLDocument alone
    # refuses — "Save as" answered noState on every AU / VST3 until the prefix was masked.
    AU = "aufx,lpas,appl"
    if any(p["identifier"] == AU for p in av):
        D = cmd("object.add", path=SRC, lane=5, start=0)["id"]
        idle()
        PA = cmd("plugin.add", host=D, identifier=AU)["plugin"]["id"]
        idle()
        # Tracktion's own wrapper levels ("Dry Level" / "Wet Level") are not the AU's: a real one.
        ka = next(q for q in params(PA) if q["name"] not in ("Dry Level", "Wet Level"))
        alo, ahi = ka["min"], ka["max"]
        a1, a2 = alo + 0.25 * (ahi - alo), alo + 0.75 * (ahi - alo)

        def avalue():
            return next(p["value"] for p in params(PA) if p["index"] == ka["index"])

        cmd("plugin.set_param", plugin=PA, index=ka["index"], value=a1)
        try:
            sa = cmd("preset.save", plugin=PA, name="AU low")
            check("AU: save works (no more noState)", sa["name"] == "AU low", sa)
        except ObjekatError as e:
            check("AU: save works (no more noState)", False, e)
        cmd("plugin.set_param", plugin=PA, index=ka["index"], value=a2)
        cmd("preset.load", plugin=PA, name="AU low")
        check("AU: load lays the stored value back", abs(avalue() - a1) <= 1e-3 * max(1.0, ahi - alo), avalue())
        st = cmd("project.get_state")
        import json as _json
        blob = _json.dumps(st)
        check("AU: the state kept in the model has no masked prefix", "objekat_b64_" not in blob)
        cmd("preset.delete", plugin=PA, name="AU low")
    else:
        print("note  AULowpass not installed: the AU block is skipped")

    # deletion
    check("loading a missing preset is not_found", refused("preset.load", plugin=P, name="Nope") == "not_found")
    check("an unknown plugin is not_found",
          refused("preset.list", plugin="00000000-0000-0000-0000-000000000000") == "not_found")
    cmd("preset.delete", plugin=P, name="Bright")
    lst = cmd("preset.list", plugin=P)
    check("delete removes it and its default", lst["presets"] == [] and lst["default"] is None, lst)
    Z = cmd("plugin.add", host=B, identifier=ident, format="TracktionInternal")["plugin"]["id"]
    idle()
    check("no default once deleted: no status on a fresh insertion", cmd("preset.list", plugin=Z)["status"] is None)

user_lib_after = os.path.exists(USER_LIB) and sorted(os.listdir(USER_LIB))
check("the user's library was not touched", user_lib_before == user_lib_after)

print("\n%d/%d OK" % (total - len(fails), total))
sys.exit(1 if fails else 0)

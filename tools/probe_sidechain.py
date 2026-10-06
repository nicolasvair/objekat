#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Sidechain probe — phase 0 of `plan_sidechain.md`. Changes no sound, asserts nothing.

The one question it answers: hosted HERE, does a given AU really enable its sidechain bus?
Tracktion's `ExternalPlugin` calls `enableAllBuses()`, but an AU may refuse it, expose it as
mono, or come back with it disabled. Everything the sidechain plan builds rests on this, so it
is measured on real plugins before a line of the engine is written.

For each plugin matched, the script puts it on a fresh object, waits for the instance to load,
reads `debug.plugin_buses` (DEBUG build only) and prints one line:

    OK        a second input bus, enabled, with channels — the key can be fed
    DISABLED  a second input bus exists but JUCE left it disabled
    NONE      a single input bus: this plugin has no sidechain input
    PENDING   the instance never finished loading within the timeout

    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --socket=/tmp/o.sock
    ./probe_sidechain.py /tmp/o.sock /tmp/probe/project.objekat --filter=Pro-C --filter=Pro-G
    ./probe_sidechain.py /tmp/o.sock /tmp/probe/project.objekat --all-effects [--format=VST3]
        [--json=/tmp/probe/buses.json]

`--filter` matches the name OR the manufacturer (case-insensitive), as `plugin.list_available`
does; repeat it to probe several. `--all-effects` probes every non-instrument plugin of the
format (AudioUnit by default) — it can take a while. `--json` writes every raw answer.

Exit: 0 once every plugin was probed (whatever the verdicts), 2 on bad usage.
"""

import sys, os, time, json

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

if len(sys.argv) < 3:
    print(__doc__)
    sys.exit(2)

SOCK, PROJ = sys.argv[1], sys.argv[2]
FILTERS, FORMAT, ALL, JSON_OUT, TIMEOUT = [], "AudioUnit", False, None, 30.0
for a in sys.argv[3:]:
    if a.startswith("--filter="):
        FILTERS.append(a.split("=", 1)[1])
    elif a.startswith("--format="):
        FORMAT = a.split("=", 1)[1]
    elif a == "--all-effects":
        ALL = True
    elif a.startswith("--json="):
        JSON_OUT = a.split("=", 1)[1]
    elif a.startswith("--timeout="):
        TIMEOUT = float(a.split("=", 1)[1])
    else:
        print("unknown argument: " + a)
        sys.exit(2)
if not FILTERS and not ALL:
    print("give at least one --filter=… or --all-effects")
    sys.exit(2)

BIP = os.path.join(HERE, "fixtures", "bip.wav")


def verdict(info):
    if not info.get("loaded"):
        return "PENDING"
    ins = info.get("input_buses") or []
    if len(ins) < 2:
        return "NONE"
    side = ins[1:]
    if any(b["enabled"] and b["channels"] > 0 for b in side):
        return "OK"
    return "DISABLED"


def describe(info):
    ins = info.get("input_buses")
    if ins is None:
        return "buses unknown"
    buses = " | ".join("%s %dch%s" % (b["name"] or "?", b["channels"],
                                      "" if b["enabled"] else " (off)") for b in ins)
    return "in[%s]  total_in=%s  te_in=%d  can_sidechain=%s" % (
        buses, info.get("total_input_channels"), len(info.get("te_input_channels") or []),
        info.get("can_sidechain"))


def probe(c, host, plugin):
    try:
        added = c.send("plugin.add", {"host": host, "identifier": plugin["identifier"],
                                      "format": plugin["format"]})["plugin"]
    except ObjekatError as e:
        return {"error": str(e)}
    pid = added["id"]
    info = {}
    deadline = time.time() + TIMEOUT
    while time.time() < deadline:
        try:
            info = c.send("debug.plugin_buses", {"plugin": pid})
        except ObjekatError:
            info = {}
        if info.get("loaded"):
            break
        time.sleep(0.25)
    try:
        c.send("plugin.remove", {"host": host, "plugin": pid})
    except ObjekatError:
        pass
    return info


os.makedirs(os.path.dirname(os.path.abspath(PROJ)), exist_ok=True)
results = []
with ObjekatClient(SOCK, timeout=180) as c:
    if c.send("app.info").get("records_recent_projects") is not False:
        print("      (warning: this instance records recent projects — launch it with --no-recent)")
    c.send("app.set_dialog_policy", {"policy": "assume_yes"})
    c.send("project.new")
    c.send("project.save_as", {"path": PROJ})
    host = c.send("object.add", {"path": BIP, "lane": 0, "start": 0})["id"]

    catalogue = c.send("plugin.list_available", {})["plugins"]
    chosen = []
    for p in catalogue:
        if p["is_instrument"] or p["format"] != FORMAT:
            continue
        text = (p["name"] + " " + p["manufacturer"]).lower()
        if ALL or any(f.lower() in text for f in FILTERS):
            chosen.append(p)
    if not chosen:
        print("no %s effect matches — run plugin.scan, or check --format" % FORMAT)

    for p in chosen:
        info = probe(c, host, p)
        v = "ERROR" if "error" in info else verdict(info)
        label = "%s — %s" % (p["manufacturer"], p["name"])
        print("%-9s %-48s %s" % (v, label[:48], info.get("error") or describe(info)))
        results.append({"plugin": p, "verdict": v, "buses": info})

if JSON_OUT:
    with open(JSON_OUT, "w") as f:
        json.dump(results, f, indent=2)
    print("\nraw answers: " + JSON_OUT)

counts = {}
for r in results:
    counts[r["verdict"]] = counts.get(r["verdict"], 0) + 1
print("\n%d plugin(s): %s" % (len(results),
                             ", ".join("%s %d" % kv for kv in sorted(counts.items())) or "none"))
sys.exit(0)

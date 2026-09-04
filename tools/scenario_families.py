#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""A smoke scenario over the command families (increment 5).

What this file brings over `tools/smoke.jsonl`: a JSON-lines scenario cannot
REUSE an identifier returned by an earlier command. Yet almost everything here depends on that
(grouping the object just added, sending to the aux just created). Hence a Python
driver, which chains the commands while keeping the identifiers to hand.

    # 1. launch the app with the API, on a SHORT socket (a system limit: 103 bytes).
    #    `--no-recent`: the throwaway project created below does not enter "Recent projects".
    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --socket=/tmp/o.sock

    # 2. replay the scenario
    ./scenario_families.py /tmp/o.sock /tmp/trial/project.objekat.json

The second argument is the project path to create: sound objects require a project
folder (samples/objects/). Exit: 0 if everything passes, 1 as soon as one command fails.
"""

import sys, os, json

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

if len(sys.argv) != 3:
    print(__doc__)
    sys.exit(2)

SOCK = sys.argv[1]
PROJ = sys.argv[2]
BIP  = os.path.join(HERE, "fixtures", "bip.wav")

ok, ko = 0, 0
def step(label, fn):
    global ok, ko
    try:
        r = fn()
        ok += 1
        print("  OK   %-28s %s" % (label, json.dumps(r, ensure_ascii=False)[:150]))
        return r
    except ObjekatError as e:
        ko += 1
        print("  FAIL %-28s %s" % (label, e.args[0]))
        return None

with ObjekatClient(SOCK) as c:
    n = len(c.send("help")["commands"])
    print("commands registered:", n)

    c.send("app.set_dialog_policy", {"policy": "assume_yes"})
    c.send("project.new")
    c.send("project.save_as", {"path": PROJ})

    a = step("object.add A",  lambda: c.send("object.add", {"path": BIP, "lane": 0, "start": 0}))
    b = step("object.add B",  lambda: c.send("object.add", {"path": BIP, "lane": 1, "start": 0}))
    ida, idb = a["id"], b["id"]

    # --- object attributes
    step("object.get",        lambda: c.send("object.get", {"id": ida}))
    step("object.rename",     lambda: c.send("object.rename", {"id": ida, "name": "Bip A"}))
    step("object.set_fade",   lambda: c.send("object.set_fade", {"id": ida, "in": 0.05, "out": 0.1}))
    step("object.set_speed",  lambda: c.send("object.set_speed", {"id": ida, "ratio": 2.0}))
    step("object.set_reversed", lambda: c.send("object.set_reversed", {"id": ida}))
    step("object.set_pan",    lambda: c.send("object.set_pan", {"ids": [ida], "pan": -0.5}))
    step("object.set_mute",   lambda: c.send("object.set_mute", {"ids": [idb], "muted": True}))
    step("object.set_duration", lambda: c.send("object.set_duration", {"id": idb, "duration": 0.3}))
    step("object.trim",       lambda: c.send("object.trim", {"id": idb, "start": 0.1, "duration": 0.2}))
    step("object.set_source_offset", lambda: c.send("object.set_source_offset", {"id": idb, "offset": 0.01}))

    # --- stems
    s = step("stem.add",      lambda: c.send("stem.add", {"name": "Voice", "format": "mono"}))
    sid = s["id"]
    step("stem.list",         lambda: c.send("stem.list"))
    step("stem.assign",       lambda: c.send("stem.assign", {"stem": sid, "ids": [ida]}))
    step("stem.set_gain",     lambda: c.send("stem.set_gain", {"id": sid, "db": -3}))
    step("stem.mute",         lambda: c.send("stem.mute", {"id": sid, "muted": True}))
    step("stem.mute off",     lambda: c.send("stem.mute", {"id": sid, "muted": False}))
    step("stem.route_to_main", lambda: c.send("stem.route_to_main", {"id": sid, "on": False}))
    step("stem.rename",       lambda: c.send("stem.rename", {"id": sid, "name": "Lead voice"}))
    step("stem.recolor",      lambda: c.send("stem.recolor", {"id": sid, "color_index": 5}))
    step("stem.level",        lambda: c.send("stem.level"))

    # --- groups
    g = step("group.create",  lambda: c.send("group.create", {"ids": [ida, idb]}))
    gid = g["id"]
    step("group.expand",      lambda: c.send("group.expand", {"id": gid, "expanded": True}))
    step("group.eject",       lambda: c.send("group.eject", {"ids": [ida], "lane": 3}))
    step("group.reparent",    lambda: c.send("group.reparent", {"ids": [ida], "group": gid}))
    step("group.disband",     lambda: c.send("group.disband", {"id": gid}))

    # --- time selection + aux + sends
    step("timesel.set",       lambda: c.send("timesel.set", {"start": 0, "end": 2, "lane": 5}))
    aux = step("aux.create",  lambda: c.send("aux.create", {"start": 0, "end": 2, "lane": 5}))
    step("aux.list",          lambda: c.send("aux.list"))
    if aux:
        step("send.set_level", lambda: c.send("send.set_level", {"id": ida, "aux": aux["id"], "db": -6}))
        step("send.enable",   lambda: c.send("send.enable", {"id": ida, "aux": aux["id"], "enabled": False}))
        step("send.list",     lambda: c.send("send.list", {"id": ida}))

    # --- MIDI
    m = step("midi.create_clip", lambda: c.send("midi.create_clip", {"start": 4, "end": 6, "lane": 6}))
    if m:
        mid = m["id"]
        note = step("midi.add_note", lambda: c.send("midi.add_note",
                    {"id": mid, "pitch": 60, "start_beat": 0, "length_beats": 1}))
        step("midi.list_notes", lambda: c.send("midi.list_notes", {"id": mid}))
        if note:
            nid = note["note"]["id"]
            step("midi.update_note", lambda: c.send("midi.update_note",
                 {"id": mid, "note_id": nid, "velocity": 80, "pitch": 64}))
            step("midi.transpose", lambda: c.send("midi.transpose",
                 {"semitones": 12, "note_ids": [nid]}))
            step("midi.delete_notes", lambda: c.send("midi.delete_notes",
                 {"id": mid, "note_ids": [nid]}))

    # --- plugins (a cached catalogue, no scan)
    av = step("plugin.list_available", lambda: c.send("plugin.list_available"))
    if av and av["count"]:
        name = av["plugins"][0]["identifier"]
        added = step("plugin.add", lambda: c.send("plugin.add", {"host": ida, "identifier": name}))
        step("plugin.list",   lambda: c.send("plugin.list", {"host": ida}))
        if added:
            pid = added["plugin"]["id"]
            step("plugin.get_params", lambda: c.send("plugin.get_params", {"plugin": pid}))
            step("plugin.toggle", lambda: c.send("plugin.toggle", {"host": ida, "plugin": pid}))
            step("plugin.copy",  lambda: c.send("plugin.copy", {"from": ida, "plugin": pid, "to": sid}))
            step("plugin.remove", lambda: c.send("plugin.remove", {"host": ida, "plugin": pid}))
    else:
        print("  (empty plugin catalogue — the plugin family is not exercised)")

    # --- clipboard
    step("selection.set",     lambda: c.send("selection.set", {"ids": [ida]}))
    step("clipboard.copy",    lambda: c.send("clipboard.copy"))
    step("clipboard.paste",   lambda: c.send("clipboard.paste"))
    step("timesel.set 2",     lambda: c.send("timesel.set", {"start": 0, "end": 1, "lanes": [0, 1]}))
    step("timesel.copy",      lambda: c.send("timesel.copy"))
    step("timesel.delete",    lambda: c.send("timesel.delete"))
    step("edit.undo",         lambda: c.send("edit.undo"))

    # --- sound objects (an asynchronous bake)
    step("selection.set B",   lambda: c.send("selection.set", {"ids": [idb]}))
    sh = step("definition.make",  lambda: c.send("definition.make", {"id": idb}))
    if sh:
        step("job.wait",      lambda: c.send("job.wait", {"id": sh["job_id"], "timeout_ms": 30000}))
        lst = step("definition.list", lambda: c.send("definition.list"))
        if lst and lst["count"]:
            pl = lst["definitions"][0]["placements"]
            if pl:
                step("definition.edit_begin", lambda: c.send("definition.edit_begin", {"placement": pl[0]}))
                step("definition.state",  lambda: c.send("definition.state"))
                step("definition.edit_cancel", lambda: c.send("definition.edit_cancel"))
                step("definition.detach", lambda: c.send("definition.detach", {"placement": pl[0]}))

    # --- the format notice and export (an asynchronous render)
    step("project.schema",    lambda: c.send("project.schema"))
    # One export at a time (the API refuses the second): every render is waited for.
    def render(label, params):
        r = step(label, lambda: c.send("export.run", params))
        if r:
            step("  job.wait", lambda: c.send("job.wait", {"id": r["job_id"], "timeout_ms": 60000}))
        return r

    out = lambda n: os.path.join(os.path.dirname(PROJ), n)
    render("export.run", {})
    step("export.status",     lambda: c.send("export.status"))
    render("export.run range", {"format": "wav", "sample_rate": 48000,
                                "start": 0.0, "end": 0.5, "path": out("range.wav")})
    # Musical times + laying the markers, then rendering the IN/OUT zone thus laid.
    render("export.run bars", {"format": "wav", "set_markers": True,
                               "start": "1:1:0", "end": "2:1:0", "path": out("bars.wav")})
    render("export.run inout", {"format": "wav", "range": "inout", "path": out("io.wav")})

    step("wait_idle",         lambda: c.send("wait_idle", {"timeout_ms": 10000}))
    step("perf.census",       lambda: c.send("perf.census"))
    step("app.dialogs",       lambda: c.send("app.dialogs"))

print("\n=== %d OK, %d FAILED ===" % (ok, ko))
sys.exit(1 if ko else 0)

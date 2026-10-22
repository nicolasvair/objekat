#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The modifiers rework (22 October 2026, `plan_modifiers_rework.md`) — the KEYBOARD half, a scenario that
ASSERTS, in UI MODE (`input.key` goes through the real key monitor of the timeline).

    objekat.app/Contents/MacOS/objekat --api --no-recent --language=en --socket=/tmp/o.sock
    ./scenario_modifiers.py /tmp/o.sock

One meaning per modifier: ⇧ = fine, ⌘ = the big step (or the zoom), ⌥ = the transport's pause and the
vertical zoom. What it proves, through the same door a hand uses:

  • M1  Volume tool: ↑/↓ = ±1 dB, ⇧ = ±0.5 dB, ⌘ = ±3 dB, a tenth of a dB kept by the model and by the file;
  • M2  Pan tool: ↑/↓ = ±0.1 (the detent), ⇧ = ±0.01 (the detent lifted), ⌘ = ±0.5;
  • M3  ⌃ no longer blocks the FX tool's key (⌃⇧F arms it), ⌘ and ⌥ still do;
  • M4  ⌃ + a digit holds a stem tool, ⌥ and ⌘ do not;
  • M5  ⌥space pauses / resumes in place, ⇧space does not (it is not the transport's any more);
  • M6  ↑/↓ on the time selection ignore ⌘ (a lane step has no big step);
  • M7  ⌥T / ⌥R = the VERTICAL zoom, bare T / R = the horizontal one, ⇧T no longer vertical;
  • M8  ⌘ + wheel zooms (`input.zoom` default `via`), ⇧ + wheel does not;
  • M9  the held-key chords: a stem digit + S = stem N's solo (no temporary solo), S + Esc = leave the solo and
        nothing else, F + Esc = hide / show the plugin editors and nothing else.

What it cannot reach (and says so): whether F + Esc really hides the editors' windows (no command opens or
reads a plugin editor, by the API's contract: only the negative half of the chord is asserted), the piano roll's ⌘↑ octave (no door selects notes), the BPM / dB boxes' arrow
steps (a box claims the keyboard by a click), the re-anchoring of ⇧ pressed in the middle of a drag (a synthetic
drag cannot change the HARDWARE modifiers the drag handlers read).

Exit: 0 if every assertion passes, 1 otherwise.
"""

import os, sys, time, threading

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

if len(sys.argv) != 2:
    print(__doc__)
    sys.exit(2)

fails = []
count = 0


def check(cond, label, detail=""):
    global count
    count += 1
    print(("  OK   " if cond else "  FAIL ") + label + (("  [" + str(detail) + "]") if detail != "" and not cond else ""))
    if not cond:
        fails.append(label)


c = ObjekatClient(sys.argv[1])
c.connect()
c2 = ObjekatClient(sys.argv[1])
c2.connect()
BIP = os.path.join(HERE, "fixtures", "bip.wav")

try:
    c.send("view.state")
except ObjekatError as e:
    print("this scenario needs the UI mode (input.key is a real event): %s" % e)
    sys.exit(2)

c.send("project.new")
c.send("debug.resize_window", {"width": 1400, "height": 1000})
oid = c.send("object.add", {"path": BIP, "lane": 0, "start": 0.0})["id"]
c.send("view.set", {"pps": 100, "scroll_x": 0, "scroll_y": 0})
time.sleep(1.5)       # a cold instance swallows the very first keys while its window settles


def key(k, mods=(), **kw):
    p = {"key": k}
    if mods:
        p["modifiers"] = list(mods)
    p.update(kw)
    return c.send("input.key", p)


def obj():
    return c.send("object.get", {"id": oid})


def select_obj():
    c.send("selection.set", {"ids": [oid]})


def tool():
    return c.send("tool.get")["tool"]


def approx(a, b, tol):
    return abs(a - b) <= tol


# ── M1 — the Volume tool's arrows ───────────────────────────────────────────────────────────────────
print("M1  Volume tool arrows")
c.send("tool.set", {"tool": "volume"})
select_obj()
c.send("object.set_gain", {"ids": [oid], "db": 0.0})
v0 = obj()["volume_db"]
key("up")
v1 = obj()["volume_db"]
check(approx(v1 - v0, 1.0, 0.02), "up = +1 dB", v1 - v0)
key("down")
v2 = obj()["volume_db"]
check(approx(v2 - v1, -1.0, 0.02), "down = -1 dB", v2 - v1)
key("up", ["shift"])
v3 = obj()["volume_db"]
check(approx(v3 - v2, 0.5, 0.02), "shift+up = +0.5 dB (the model keeps a tenth of a dB)", v3 - v2)
key("down", ["shift"])
v4 = obj()["volume_db"]
check(approx(v4 - v3, -0.5, 0.02), "shift+down = -0.5 dB", v4 - v3)
# A value off the whole dB is conserved as it is (no rounding in the model), and the bare step goes on from it.
c.send("object.set_gain", {"ids": [oid], "db": -2.5})
check(approx(obj()["volume_db"], -2.5, 0.001), "set_gain -2.5 reads back -2.5 (a tenth is kept)", obj()["volume_db"])
c.send("object.set_gain", {"ids": [oid], "db": -2.34})
check(approx(obj()["volume_db"], -2.3, 0.001), "set_gain -2.34 is kept to the tenth (-2.3)", obj()["volume_db"])
key("up")
check(approx(obj()["volume_db"], -1.3, 0.02), "a bare step from -2.3 lands on -1.3 (no re-snap to whole dB)", obj()["volume_db"])
c.send("object.set_gain", {"ids": [oid], "db": -2.5})
tmp = "/tmp/objekat_modifiers_%d.objekat" % os.getpid()
c.send("project.save_as", {"path": tmp})
c.send("project.open", {"path": tmp})
time.sleep(1.0)
oid = c.send("object.list")["objects"][0]["id"]
check(approx(obj()["volume_db"], -2.5, 0.001), "-2.5 dB survives a save and a reopen", obj()["volume_db"])
try:
    os.remove(tmp)
except OSError:
    pass
c.send("tool.set", {"tool": "volume"})
select_obj()
c.send("object.set_gain", {"ids": [oid], "db": 0.0})
v4 = obj()["volume_db"]
key("up", ["cmd"])
v5 = obj()["volume_db"]
check(approx(v5 - v4, 3.0, 0.02), "cmd+up = +3 dB (big step)", v5 - v4)
key("down", ["cmd"])
v6 = obj()["volume_db"]
check(approx(v6 - v5, -3.0, 0.02), "cmd+down = -3 dB (big step)", v6 - v5)
key("up", ["cmd", "shift"])
v7 = obj()["volume_db"]
check(approx(v7 - v6, 3.0, 0.02), "cmd+shift+up = the big step (the explicit ask wins)", v7 - v6)
key("down", ["cmd", "shift"])

# ── M2 — the Pan tool's arrows ──────────────────────────────────────────────────────────────────────
print("M2  Pan tool arrows")
c.send("tool.set", {"tool": "pan"})
select_obj()
c.send("object.set_pan", {"ids": [oid], "pan": 0.0})
key("up")
p1 = obj()["pan"]
check(approx(p1, 0.1, 0.005), "up = +0.1", p1)
key("down")
p2 = obj()["pan"]
check(approx(p2, 0.0, 0.005), "down = -0.1", p2)
key("up", ["shift"])
p3 = obj()["pan"]
check(approx(p3, 0.01, 0.002), "shift+up = +0.01 (the detent is lifted)", p3)
key("up", ["shift"], repeat=4)
p4 = obj()["pan"]
check(approx(p4, 0.05, 0.003), "shift+up x4 more = 0.05, off every tenth", p4)
c.send("object.set_pan", {"ids": [oid], "pan": 0.0})
key("up", ["cmd"])
p5 = obj()["pan"]
check(approx(p5, 0.5, 0.005), "cmd+up = +0.5", p5)
key("down", ["cmd"], repeat=2)
p6 = obj()["pan"]
check(approx(p6, -0.5, 0.005), "cmd+down x2 = -0.5", p6)
c.send("object.set_pan", {"ids": [oid], "pan": 0.0})

# ── M3 — the FX tool's key, ⌃ no longer excluded ────────────────────────────────────────────────────
print("M3  F key")
c.send("tool.set", {"tool": "selection"})
key("f", ["ctrl", "shift"])
check(tool() == "fx", "ctrl+shift+F arms the FX tool (ctrl is no longer excluded)", tool())
c.send("tool.set", {"tool": "selection"})
key("f", ["cmd", "shift"])
check(tool() == "selection", "cmd+shift+F does not (cmd still excluded)", tool())
key("f", ["alt", "shift"])
check(tool() == "selection", "alt+shift+F does not (alt still excluded)", tool())
key("f", ["shift"])
check(tool() == "fx", "shift+F still arms it", tool())
c.send("tool.set", {"tool": "selection"})

# ── M4 — ⌃ + a digit holds a stem tool ──────────────────────────────────────────────────────────────
print("M4  digits")
if len(c.send("stem.list")["stems"]) < 2:
    c.send("stem.add", {"name": "Stem A"})
nstems = len(c.send("stem.list")["stems"])


def held_tool_during(k, mods):
    """The tool seen from a second connection while `k` is held down for 700 ms."""
    seen = []

    def presser():
        try:
            key(k, mods, hold_ms=700)
        except Exception as e:  # pragma: no cover
            seen.append("err:" + str(e))

    th = threading.Thread(target=presser)
    th.start()
    time.sleep(0.35)
    seen.append(c2.send("tool.get")["tool"])
    th.join()
    time.sleep(0.2)
    seen.append(c2.send("tool.get")["tool"])
    return seen


if nstems >= 2:
    seen = held_tool_during("2", [])
    check(seen[0] == "stem" and seen[-1] == "selection", "bare 2 holds the stem tool, released on keyUp", seen)
    seen = held_tool_during("2", ["ctrl"])
    check(seen[0] == "stem" and seen[-1] == "selection", "ctrl+2 holds the stem tool too (ctrl no longer excluded)", seen)
    seen = held_tool_during("2", ["alt"])
    check(seen[0] == "selection", "alt+2 does not", seen)
    seen = held_tool_during("2", ["cmd"])
    check(seen[0] == "selection", "cmd+2 does not", seen)
else:
    check(False, "the project has at least 2 stems (Main + 1)", nstems)

# ── M5 — the transport: ⌥space pauses, ⇧space does not ──────────────────────────────────────────────
print("M5  transport")
c.send("transport.seek", {"seconds": 0.0})
c.send("transport.play")
time.sleep(0.4)
check(c.send("transport.state")["playing"], "playing")
key("space", ["alt"])
time.sleep(0.4)
st = c.send("transport.state")
check((not st["playing"]) and st.get("paused_at") is not None, "alt+space pauses in place", st)
key("space", ["alt"])
time.sleep(0.4)
st = c.send("transport.state")
check(st["playing"] and st.get("paused_at") is None, "alt+space again resumes", st)
key("space", ["shift"])
time.sleep(0.4)
st = c.send("transport.state")
check(st.get("paused_at") is None, "shift+space is no longer a pause", st)
c.send("transport.stop")
time.sleep(0.2)

# ── M6 — ↑/↓ on the time selection ignore ⌘ ─────────────────────────────────────────────────────────
print("M6  lane steps")
c.send("selection.clear")
for l in (1, 2, 3):
    c.send("object.add", {"path": BIP, "lane": l, "start": 0.0})
c.send("timesel.set", {"start": 0.0, "end": 0.2, "lanes": [1]})
key("down")
lanes = c.send("selection.get")["time_selection"]["lanes"]
check(lanes == [2], "down moves the passage one lane", lanes)
# A modifier on a lane step is LEFT ALONE (unchanged behaviour: bare arrows only): no big step.
key("down", ["cmd"])
lanes = c.send("selection.get")["time_selection"]["lanes"]
check(lanes == [2], "cmd+down does nothing to the lanes (no big step for lanes)", lanes)
key("up", ["cmd"])
lanes = c.send("selection.get")["time_selection"]["lanes"]
check(lanes == [2], "cmd+up likewise", lanes)
key("up", ["shift"])
lanes = c.send("selection.get")["time_selection"]["lanes"]
check(lanes == [2], "shift+up likewise (modifier = nothing, as before)", lanes)
key("up")
lanes = c.send("selection.get")["time_selection"]["lanes"]
check(lanes == [1], "bare up still steps one lane", lanes)
c.send("selection.clear")

# ── M7 — the zoom keys ──────────────────────────────────────────────────────────────────────────────
print("M7  zoom keys")
c.send("view.set", {"pps": 100, "scroll_x": 0, "scroll_y": 0})
time.sleep(0.3)
s0 = c.send("view.state")
key("t")
time.sleep(0.4)
s1 = c.send("view.state")
check(s1["pps"] > s0["pps"] * 1.2 and approx(s1["block_height"], s0["block_height"], 0.5),
      "bare T zooms in HORIZONTALLY only", (s0["pps"], s1["pps"], s0["block_height"], s1["block_height"]))
key("r", ["alt"])
time.sleep(0.6)
s2 = c.send("view.state")
check(s2["block_height"] < s1["block_height"] * 0.9 and approx(s2["pps"], s1["pps"], 0.5),
      "alt+R zooms out VERTICALLY only", (s1["block_height"], s2["block_height"], s1["pps"], s2["pps"]))
key("t", ["alt"])
time.sleep(0.6)
s3 = c.send("view.state")
check(s3["block_height"] > s2["block_height"] * 1.1 and approx(s3["pps"], s2["pps"], 0.5),
      "alt+T zooms in VERTICALLY only", (s2["block_height"], s3["block_height"], s2["pps"], s3["pps"]))
key("t", ["shift"])
time.sleep(0.4)
s4 = c.send("view.state")
check(approx(s4["block_height"], s3["block_height"], 0.5),
      "shift+T no longer zooms vertically", (s3["block_height"], s4["block_height"]))

# ── M8 — the wheel: ⌘ zooms, ⇧ does not ─────────────────────────────────────────────────────────────
print("M8  wheel")
c.send("view.set", {"pps": 100, "scroll_x": 0, "scroll_y": 0})
time.sleep(0.3)
d = c.send("input.zoom", {"axis": "horizontal", "factor": 1.5})
check(d["achieved_factor"] > 1.2, "input.zoom (cmd + wheel, the default) zooms in", d["achieved_factor"])
check(not d.get("contaminated", False), "no real input interfered")
d = c.send("input.scroll", {"direction": "down", "distance_px": 200, "style": "wheel", "modifiers": ["shift"]})
after = d["view_after"]
check(approx(after["pps"], c.send("view.state")["pps"], 0.01), "shift + wheel leaves the zoom alone")

# ── M9 — the held-key chords: F+Esc, N+S, S+Esc ────────────────────────────────────────────────────
print("M9  held-key chords")


def during_hold(hold_key, second_key, mods=(), after=0.4, hold=1200, probe=None):
    """Holds `hold_key` for `hold` ms on connection `c`, presses `second_key` on `c2` once `after` seconds
    have passed, and returns whatever `probe()` reads while the first key is STILL down (and once more after
    its release)."""
    seen = []

    def presser():
        try:
            key(hold_key, hold_ms=hold)
        except Exception as e:  # pragma: no cover
            seen.append("err:" + str(e))

    th = threading.Thread(target=presser)
    th.start()
    time.sleep(after)
    p = {"key": second_key}
    if mods:
        p["modifiers"] = list(mods)
    c2.send("input.key", p)
    time.sleep(0.15)
    seen.append(probe() if probe else None)
    th.join()
    time.sleep(0.25)
    seen.append(probe() if probe else None)
    return seen


def sel_ids(cl=None):
    return (cl or c).send("selection.get").get("ids", [])


def tool2():
    return c2.send("tool.get")["tool"]


stems = c.send("stem.list")["stems"]
c.send("solo.clear")
c.send("tool.set", {"tool": "selection"})
if len(stems) >= 2:
    stem2 = stems[1]["id"]

    # N + S: digit FIRST, then S → stem N's solo is toggled, and S arms nothing else.
    select_obj()
    seen = during_hold("2", "s", probe=lambda: c2.send("solo.get"))
    st = seen[0]
    check(stem2 in st["stems"], "2 held + S soloes stem 2", st["stems"])
    check(st["temporary"] is None, "... and S armed NO temporary solo (beginHeldSolo)", st["temporary"])
    check(st["confirmed"] == [], "... nor a confirmed one", st["confirmed"])
    seen = during_hold("2", "s", probe=lambda: c2.send("solo.get"))
    check(stem2 not in seen[0]["stems"], "2 held + S again un-soloes it (a toggle)", seen[0]["stems"])
    c.send("solo.clear")

    # The OLDER chord keeps working: S first, then the digit.
    seen = during_hold("s", "2", probe=lambda: c2.send("solo.get"))
    check(stem2 in seen[0]["stems"], "S held + 2 still soloes stem 2 (the older chord)", seen[0]["stems"])
    check(seen[0]["temporary"] is not None, "... on top of the temporary solo of the held S", seen[0]["temporary"])
    c.send("solo.clear")

    # The control: S ALONE does arm the temporary solo (what N + S must not do), and it ends on release.
    select_obj()
    seen = []
    th = threading.Thread(target=lambda: key("s", hold_ms=700))
    th.start()
    time.sleep(0.35)
    seen.append(c2.send("solo.get"))
    th.join()
    time.sleep(0.25)
    seen.append(c2.send("solo.get"))
    check(seen[0]["temporary"] is not None, "S alone arms the temporary solo (control)", seen[0]["temporary"])
    check(seen[1]["temporary"] is None and not seen[1]["active"], "... and releasing it lifts it", seen[1])
else:
    check(False, "the project has at least 2 stems (Main + 1)", len(stems))

# S + Esc: leaves the solo and does NOTHING else (the selection and the tool stay).
select_obj()
c.send("tool.set", {"tool": "volume"})
seen = during_hold("s", "escape", probe=lambda: (c2.send("solo.get"), sel_ids(c2), tool2()))
solo_now, sel_now, tool_now = seen[0]
check(not solo_now["active"], "S held + Esc turns every solo off", solo_now)
check(oid in sel_now, "... and leaves the selection alone (Esc alone would clear it)", sel_now)
check(tool_now == "volume", "... and the tool", tool_now)
c.send("solo.clear")

# F + Esc: the plugin editors' toggle — and Esc does NOTHING else. No door opens or reads a plugin editor
# (the API's contract), so what is asserted is the negative half: the bare Esc's own effects do not happen.
select_obj()
c.send("tool.set", {"tool": "selection"})
seen = during_hold("f", "escape", probe=lambda: (sel_ids(c2), tool2()))
sel_now, tool_now = seen[0]
check(oid in sel_now, "F held + Esc leaves the selection alone", sel_now)
check(tool_now == "fx", "... and the FX tool stays armed while F is held", tool_now)
check(seen[1][1] == "selection", "... then F's release gives the selection tool back", seen[1])
# The control: a bare Esc still does its usual reset.
select_obj()
c.send("tool.set", {"tool": "volume"})
key("escape")
time.sleep(0.2)
check(sel_ids() == [] and tool() == "selection", "a bare Esc still clears the selection and the tool",
      (sel_ids(), tool()))

c.send("tool.set", {"tool": "selection"})
print("")
print("%d assertions, %d failed" % (count, len(fails)))
for f in fails:
    print("  FAILED: " + f)
sys.exit(1 if fails else 0)

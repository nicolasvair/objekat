#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Resting-state sync of the members of an FX link / a link group — a scenario that ASSERTS.

    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --socket=/tmp/o.sock
    ./scenario_fxlink_state_sync.py /tmp/o.sock /tmp/trial/proj.objekat \
        [--external=aumf,FQ4p,FabF] [--log=/path/to/instance-stderr.log] [--pid=N]

DEBUG build only (it drives `debug.plugin_inject_state`, `debug.link_state_tick`, `debug.link_state`).

The bug it guards: a FabFilter Pro-Q 4 keeps settings that the host cannot see (a dynamic band's
"Spectral" switch, its threshold, its side-chain range) in its binary chunk alone, and a native GUI
changes them without telling the host. The parameter mirror of an FX link therefore never carried
them to the other members. The engine now also compares CHUNKS, at rest.

HOW A SILENT CHANGE IS MADE HERE. Injecting a state (`debug.plugin_inject_state`) makes the AU
notify what changed, and the parameter mirror hands it to the other member at once: that alone
reproduces nothing (measured on Pro-Q 4: every float a state can move is carried, A follows within
one call). A native GUI, on the contrary, changes some settings without a word. The scenario makes
the injection silent by using the echo rule of the sync itself: a member that has just RECEIVED a
chunk ignores its own notifications for 600 ms. So `hidden_change(B, other=A)` first lays A's state
on B (`fxlink.sync {plugin: A}`), then injects into B at once: B's notifications are dropped as an
echo, A stays behind, and only the resting-state sync can bring it back. (Measured: without that
step A follows immediately; with it, A lags for good.) It is a harness device, and the one place
where this scenario is only as faithful as that rule.

Two members' chunks are never byte-identical (a plugin re-encodes what it is given): the scenario
compares FLOATS, with a tolerance, and only ones it knows the meaning of.

Exit: 0 if every assertion passes (or Pro-Q is not installed: SKIP), 1 otherwise.
"""

import base64, json, os, plistlib, re, struct, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

if len(sys.argv) < 3:
    print(__doc__)
    sys.exit(2)

SOCK, PROJ = sys.argv[1], sys.argv[2]
EXTERNAL = "aumf,FQ4p,FabF"
LOG = None
PID = None
for a in sys.argv[3:]:
    if a.startswith("--external="):
        EXTERNAL = a.split("=", 1)[1]
    elif a.startswith("--log="):
        LOG = a.split("=", 1)[1]
    elif a.startswith("--pid="):
        PID = int(a.split("=", 1)[1])

BIP = os.path.join(HERE, "fixtures", "bip.wav")
TOL = 1e-5
HIDDEN = (0, 553)                       # the two floats tracked (flipped between 0 and 1)
REPORT = (12, 17, 18, 20, 35, 40, 41, 43)   # the real report's floats (threshold, SC range, Spectral)

fails = []
notes = []
total = 0


def check(label, ok, detail=""):
    global total
    total += 1
    if ok:
        print("ok    " + label)
    else:
        fails.append(label)
        print("FAIL  %s   %s" % (label, detail))


def note(text):
    notes.append(text)
    print("note  " + text)


# ── the chunk: bplist → FabFilterPluginState blob (FFBS) → 576 floats at byte 12 ──────────────
def blob_floats(state_b64=None, raw=None):
    if raw is None:
        raw = base64.b64decode(state_b64)
    pl = plistlib.loads(raw)
    return pl, struct.unpack_from("<576f", pl["FabFilterPluginState"], 12)


JUCE_CH = ".ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+"


def juce_b64_decode(text):
    size, rest = text.split(".", 1)
    acc = bits = 0
    out = bytearray()
    for ch in rest:
        acc |= JUCE_CH.index(ch) << bits
        bits += 6
        while bits >= 8:
            out.append(acc & 255)
            acc >>= 8
            bits -= 8
    return bytes(out[:int(size)])


def state_xml_floats(xml):
    m = re.search(r'state="([^"]*)"', xml)
    return blob_floats(raw=juce_b64_decode(m.group(1)))[1]


def close(a, b):
    return abs(a - b) <= TOL


try:
    c = ObjekatClient(SOCK, timeout=180).connect()
except Exception as e:
    print("cannot connect to %s: %s" % (SOCK, e))
    sys.exit(2)


def cmd(_name, **params):
    return c.send(_name, params or None)


def refused(_name, **params):
    try:
        c.send(_name, params or None)
        return None
    except ObjekatError as e:
        return e.code


def idle():
    cmd("wait_idle", timeout_ms=60000)


def available():
    r = cmd("plugin.list_available", filter="pro-q")
    return any(p["identifier"] == EXTERNAL for p in r["plugins"])


if not available():
    print("SKIP  %s is not in plugin.list_available (Pro-Q 4 absent)" % EXTERNAL)
    sys.exit(0)

try:
    cmd("debug.link_state")
except ObjekatError:
    print("SKIP  debug.* commands absent (not a DEBUG build)")
    sys.exit(0)

cmd("app.set_dialog_policy", policy="assume_yes")


# ── helpers over the API ──────────────────────────────────────────────────────────────────────
def floats(plugin):
    return blob_floats(cmd("plugin.get_state", plugin=plugin)["state"])[1]


def inject(plugin, changes):
    """Lays the live chunk of `plugin` back on itself with some floats changed (nothing announced)."""
    st = cmd("plugin.get_state", plugin=plugin)["state"]
    pl, _ = blob_floats(st)
    blob = bytearray(pl["FabFilterPluginState"])
    for i, v in changes.items():
        struct.pack_into("<f", blob, 12 + 4 * i, v)
    pl["FabFilterPluginState"] = bytes(blob)
    cmd("debug.plugin_inject_state", plugin=plugin,
        state=base64.b64encode(plistlib.dumps(pl, fmt=plistlib.FMT_BINARY)).decode())


def flip(v):
    return 0.0 if v > 0.5 else 1.0


def hidden_change(plugin, other=None, extra=True):
    """Changes two floats (and, as the report did, the Spectral / threshold ones) on `plugin`.
    With `other`, the change is SILENT (see the docstring); without, the mirror carries it.
    Returns {index: new value} for the two tracked floats."""
    if other:
        cmd("fxlink.sync", plugin=other)
    f = floats(plugin)
    ch = {i: flip(f[i]) for i in HIDDEN}
    if extra:
        ch[20] = flip(f[20])
        ch[43] = flip(f[43])
        ch[12] = 1.0 if f[12] < 0.9 else 0.5
    inject(plugin, ch)
    return {i: ch[i] for i in HIDDEN}


def tick(plugin, force=False):
    return cmd("debug.link_state_tick", plugin=plugin, force=force)


def state():
    return cmd("debug.link_state")


def pushes_total():
    return state()["pushes_total"]


def settle(ms=800):
    idle()
    time.sleep(ms / 1000.0)


def drain(*plugins):
    """Brings the engine to rest: forced ticks, then out of the 600 ms deaf window."""
    for p in plugins:
        tick(p, force=True)
    time.sleep(0.8)
    for p in plugins:
        tick(p, force=True)
    time.sleep(0.8)


def at(plugin, values):
    f = floats(plugin)
    return all(close(f[i], v) for i, v in values.items())


def instance(host, want_block=True):
    """The (first) plugin instance of a host, inside its FX-link block or not."""
    for p in cmd("plugin.list", host=host)["plugins"]:
        if p.get("is_fx_block"):
            return p["plugins"][0]["id"]
        if not want_block:
            return p["id"]
    return None


def pro_q(host):
    return cmd("plugin.add", host=host, identifier=EXTERNAL, format="AudioUnit")["plugin"]["id"]


def wait_loaded(plugin, timeout=30.0):
    dl = time.time() + timeout
    while time.time() < dl:
        try:
            if cmd("plugin.get_state", plugin=plugin, include_chunk=False)["size"] > 0:
                return True
        except ObjekatError:
            pass
        time.sleep(0.25)
    return False


def log_size():
    return os.path.getsize(LOG) if LOG and os.path.exists(LOG) else 0


def log_since(offset):
    if not LOG or not os.path.exists(LOG):
        return None
    with open(LOG, "rb") as f:
        f.seek(offset)
        return f.read().decode("utf-8", "replace")


def find_pid():
    if PID:
        return PID
    try:
        out = subprocess.run(["pgrep", "-f", "--", "--socket=" + SOCK],
                             capture_output=True, text=True).stdout.split()
        return int(out[0]) if out else None
    except Exception:
        return None


def saved_states(path):
    """Floats of the definition and of every member instance in the saved session."""
    d = json.load(open(path))
    defs = {}
    for l in d.get("fxLinks", []):
        for p in l.get("plugins", []):
            if p.get("stateXML"):
                defs[p["id"]] = state_xml_floats(p["stateXML"])
    members = []

    def walk(items):
        for it in items:
            for p in it.get("plugins", []):
                blk = p.get("fxBlock")
                if blk:
                    for q in blk.get("plugins", []):
                        if q.get("stateXML"):
                            members.append((it["id"], q["id"], q.get("linkGroupID"),
                                            state_xml_floats(q["stateXML"])))
            walk(it.get("children", []))
    walk(d.get("items", []))
    return defs, members


os.makedirs(os.path.dirname(os.path.abspath(PROJ)), exist_ok=True)
cmd("project.new")
cmd("project.save_as", path=PROJ)

# ═════════════════════════════════════════════════════════════════════════════════════════════
# (1) montage : deux groupes A (vide de plugin propre) et B, Pro-Q sur A, bin, attach sur B
# ═════════════════════════════════════════════════════════════════════════════════════════════
print("\n-- (1) setup")
a = cmd("object.add", path=BIP, lane=0, start=0)["id"]
b = cmd("object.add", path=BIP, lane=1, start=0)["id"]
GA = cmd("group.create", ids=[a])["id"]
GB = cmd("group.create", ids=[b])["id"]
check("A holds no plugin before the montage", len(cmd("plugin.list", host=GA)["plugins"]) == 0)
PA = pro_q(GA)
check("Pro-Q 4 loads on A", wait_loaded(PA))
L = cmd("fxlink.create", host=GA, plugins=[PA], name="ProQ bin")
LID = L["id"]
DEF = L["plugins"][0]["id"]
cmd("fxlink.attach", link=LID, host=GB)
idle()
PB = instance(GB)
check("B holds a block of the bin with its own instance", PB is not None and PB != PA)
check("B's instance loads", wait_loaded(PB))
lg = {p["id"]: p.get("link_group") for h in (GA, GB)
      for blk in cmd("plugin.list", host=h)["plugins"] if blk.get("is_fx_block") for p in blk["plugins"]}
check("both instances carry linkGroupID == the definition plugin",
      lg.get(PA) == DEF and lg.get(PB) == DEF, str(lg))
check("A keeps its instance id (nothing reloaded)", instance(GA) == PA)
settle()
drain(PA, PB)
check("no editor open: the timer is not running", state()["timer_running"] is False)
check("no gesture open", state()["gesture_open"] == {} or all(v == 0 for v in state()["gesture_open"].values()))

# ═════════════════════════════════════════════════════════════════════════════════════════════
# (2) le miroir de paramètres n'est pas régressé
# ═════════════════════════════════════════════════════════════════════════════════════════════
print("\n-- (2) parameter mirror")
WET = 1
pv0 = cmd("plugin.get_params", plugin=PA)["params"][WET]["value"]
target = 0.5 if pv0 > 0.75 else 0.9
cmd("plugin.set_param", plugin=PB, index=WET, value=target)
t0 = time.time()
seen = None
while time.time() - t0 < 0.3:
    seen = cmd("plugin.get_params", plugin=PA)["params"][WET]["value"]
    if abs(seen - target) < 1e-3:
        break
    time.sleep(0.02)
check("plugin.set_param on B: A follows within 300 ms (%.0f ms)" % ((time.time() - t0) * 1000),
      seen is not None and abs(seen - target) < 1e-3, "A reads %s, wanted %s" % (seen, target))
cmd("plugin.set_param", plugin=PB, index=WET, value=pv0)
settle()
drain(PA, PB)

# ═════════════════════════════════════════════════════════════════════════════════════════════
# (3) reproduction : un changement d'état invisible au miroir, fait sur B, sans tick
# ═════════════════════════════════════════════════════════════════════════════════════════════
print("\n-- (3) reproduction (no tick)")
fa0 = floats(PA)
new = hidden_change(PB, other=PA)
fb = floats(PB)
check("the injected state is really B's (hidden floats moved)",
      all(close(fb[i], v) for i, v in new.items()), str([(i, fb[i], v) for i, v in new.items()]))
time.sleep(1.0)
fa1 = floats(PA)
check("after 1 s with NO tick, A is unchanged on the hidden floats (the bug, reproduced)",
      all(close(fa1[i], fa0[i]) for i in HIDDEN), str([(i, fa0[i], fa1[i]) for i in HIDDEN]))
carried = [i for i in REPORT if not close(fa1[i], fa0[i])]
note("floats of the report carried at once by the parameter mirror on injection: %s" % carried)

# ═════════════════════════════════════════════════════════════════════════════════════════════
# (4) debounce : 1er tick sans force → pending ; 2e → pushed [A]
# ═════════════════════════════════════════════════════════════════════════════════════════════
print("\n-- (4) debounce")
p0 = pushes_total()
r1 = tick(PB)
check("first tick (no force): nothing pushed, pending", r1["pushed"] == [] and r1["pending"] is True, str(r1))
check("A still unchanged after the first tick",
      all(close(floats(PA)[i], fa0[i]) for i in HIDDEN))
r2 = tick(PB)
check("second tick: A is pushed", r2["pushed"] == [PA] and r2["pending"] is False, str(r2))
fa2 = floats(PA)
check("A's state now reflects the change (hidden floats)",
      all(close(fa2[i], v) for i, v in new.items()), str([(i, fa2[i], v) for i, v in new.items()]))
check("A's state reflects the report's floats too",
      all(close(fa2[i], floats(PB)[i]) for i in (12, 20, 43)),
      str([(i, fa2[i], floats(PB)[i]) for i in (12, 20, 43)]))
check("the push is counted (by source B)", pushes_total() == p0 + 1 and state()["pushes"].get(PB, 0) >= 1,
      str(state()["pushes"]))

# ═════════════════════════════════════════════════════════════════════════════════════════════
# (5) pas de ping-pong
# ═════════════════════════════════════════════════════════════════════════════════════════════
print("\n-- (5) no ping-pong")
time.sleep(1.0)                              # out of A's 600 ms deaf window
p0 = pushes_total()
ra = [tick(PA), tick(PA)]
rb = [tick(PB), tick(PB)]
check("ticks on A then on B push nothing", all(r["pushed"] == [] for r in ra + rb), str(ra + rb))
check("the counters did not move", pushes_total() == p0)
time.sleep(0.9)
rr = [tick(PA), tick(PB), tick(PA), tick(PB)]
check("nor a second round later", all(r["pushed"] == [] for r in rr) and pushes_total() == p0, str(rr))

# ═════════════════════════════════════════════════════════════════════════════════════════════
# (6) flush avant capture d'un snapshot d'undo
# ═════════════════════════════════════════════════════════════════════════════════════════════
print("\n-- (6) flush before an undo snapshot")
# The flush covers what is PENDING (a first tick has seen a difference and waits for stability) and
# every member whose editor is open — never a plugin nothing has noticed. Headless there is no
# editor, so the pending mark is laid by one unforced tick; the literal variant (no tick at all)
# is recorded first, as a measure of that boundary.
fa0 = floats(PA)
new = hidden_change(PB, other=PA, extra=False)
check("(precondition) A is behind", not all(close(floats(PA)[i], v) for i, v in new.items()))
time.sleep(0.7)
cmd("object.move", id=GB, start=1.0)
time.sleep(0.1)
lit = all(close(floats(PA)[i], v) for i, v in new.items())
note("literal variant (no tick, no editor): a snapshot flush %s a change nothing had noticed"
     % ("DID carry" if lit else "did NOT carry"))
cmd("object.move", id=GB, start=0.0)
time.sleep(0.7)
r = tick(PB)
check("(precondition) one unforced tick lays the pending mark", r["pending"] is True and r["pushed"] == [], str(r))
cmd("object.move", id=GB, start=1.0)          # the bus pushes the undo snapshot: flush first
time.sleep(0.1)
check("object.move on a pending change: A received B's state", all(close(floats(PA)[i], v) for i, v in new.items()),
      str([(i, floats(PA)[i], v) for i, v in new.items()]))
cmd("object.move", id=GB, start=0.0)
settle()
drain(PA, PB)

# ═════════════════════════════════════════════════════════════════════════════════════════════
# (7) sauvegarde sans tick : définition, A et B cohérents dans le JSON
# ═════════════════════════════════════════════════════════════════════════════════════════════
print("\n-- (7) save with no tick")
new = hidden_change(PB, other=PA, extra=False)
check("(precondition) A is still behind", not all(close(floats(PA)[i], v) for i, v in new.items()))
time.sleep(0.7)                               # out of B's echo window: a tick inside it is ignored
r = tick(PB)                                  # the pending mark (no editor headless): see (6)
check("(precondition) the change is pending", r["pending"] is True and r["pushed"] == [], str(r))
cmd("project.save")
idle()
defs, members = saved_states(PROJ)
mem = {m[1]: m for m in members}
check("the saved session holds the definition and both members", DEF in defs and PA in mem and PB in mem,
      "defs=%s members=%s" % (list(defs), [m[1] for m in members]))
if DEF in defs and PA in mem and PB in mem:
    check("the saved B carries the change", all(close(mem[PB][3][i], v) for i, v in new.items()))
    check("the saved A carries it too", all(close(mem[PA][3][i], v) for i, v in new.items()),
          str([(i, mem[PA][3][i], v) for i, v in new.items()]))
    check("the saved definition agrees", all(close(defs[DEF][i], v) for i, v in new.items()),
          str([(i, defs[DEF][i], v) for i, v in new.items()]))
drain(PA, PB)

# ═════════════════════════════════════════════════════════════════════════════════════════════
# (8) fxlink.sync répare une session divergée
# ═════════════════════════════════════════════════════════════════════════════════════════════
print("\n-- (8) fxlink.sync")
cmd("project.save")
idle()
info = cmd("app.info")
clean = info.get("dirty") is False
new = hidden_change(PB, other=PA, extra=False)
check("(precondition) A has drifted from B", not all(close(floats(PA)[i], v) for i, v in new.items()))
r = cmd("fxlink.sync", plugin=PB)
check("fxlink.sync lists A as overwritten", r["pushed"] == [PA], str(r))
check("A now agrees with B on the hidden floats", all(close(floats(PA)[i], v) for i, v in new.items()))
if clean:
    check("fxlink.sync marks the project modified", cmd("app.info").get("dirty") is True)
else:
    note("app.info.dirty was not False after project.save: the 'marks modified' check is skipped")
ghost = "00000000-0000-0000-0000-000000000000"
try:
    rg = cmd("fxlink.sync", plugin=ghost)
    check("fxlink.sync of an unknown plugin pushes nothing", rg["pushed"] == [], str(rg))
except ObjekatError:
    check("fxlink.sync of an unknown plugin is refused", True)
drain(PA, PB)

# ═════════════════════════════════════════════════════════════════════════════════════════════
# (9) un membre détaché n'est pas touché ; le rattachement réaligne
# ═════════════════════════════════════════════════════════════════════════════════════════════
print("\n-- (9) detach / reattach")
cmd("fxlink.detach", host=GB, link=LID)
idle()
PB2 = instance(GB)
check("the detached host still has an instance", PB2 is not None)
wait_loaded(PB2)
settle()
drain(PA, PB2)
fa0 = floats(PA)
new = hidden_change(PB2, extra=False)
rr = [tick(PB2, force=True), tick(PB2, force=True)]
check("a detached member pushes nothing", all(r["pushed"] == [] for r in rr), str(rr))
check("A is not touched by the detached B", all(close(floats(PA)[i], fa0[i]) for i in HIDDEN))
fb0 = floats(PB2)
newA = hidden_change(PA, extra=False)
rr = [tick(PA), tick(PA), tick(PA, force=True)]
check("A's change does not reach the detached B", all(close(floats(PB2)[i], fb0[i]) for i in HIDDEN),
      str([(i, floats(PB2)[i], fb0[i]) for i in HIDDEN]))
check("A pushes nothing to it", all(r["pushed"] == [] for r in rr), str(rr))
cmd("fxlink.reattach", host=GB, link=LID)
idle()
PB3 = instance(GB)
wait_loaded(PB3)
settle(1200)
tick(PA, force=True); tick(PB3, force=True)
time.sleep(0.8)
fa, fb3 = floats(PA), floats(PB3)
ok = all(close(fa[i], fb3[i]) for i in HIDDEN)
check("reattach realigns B on the bin (hidden floats equal A's)", ok,
      str([(i, fa[i], fb3[i]) for i in HIDDEN]))
PB = PB3
drain(PA, PB)

# ═════════════════════════════════════════════════════════════════════════════════════════════
# (10) même chose avec deux clips audio (bin créé sur des objets)
# ═════════════════════════════════════════════════════════════════════════════════════════════
print("\n-- (10) two audio clips")
c1 = cmd("object.add", path=BIP, lane=4, start=0)["id"]
c2 = cmd("object.add", path=BIP, lane=5, start=0)["id"]
pc1 = pro_q(c1)
wait_loaded(pc1)
L2 = cmd("fxlink.create", objects=[c1, c2], name="clips")
idle()
i1, i2 = instance(c1), instance(c2)
check("both clips hold an instance of the bin", i1 is not None and i2 is not None and i1 != i2)
wait_loaded(i1); wait_loaded(i2)
settle()
drain(i1, i2)
f1 = floats(i1)
new = hidden_change(i2, other=i1)
time.sleep(1.0)
check("clips: no tick, the first clip is unchanged", all(close(floats(i1)[i], f1[i]) for i in HIDDEN))
r1, r2 = tick(i2), tick(i2)
check("clips: two ticks push the first clip", r1["pushed"] == [] and r2["pushed"] == [i1], str((r1, r2)))
check("clips: the first clip reflects the change", all(close(floats(i1)[i], v) for i, v in new.items()))

# ═════════════════════════════════════════════════════════════════════════════════════════════
# (11) ⌘-link classique (plugin.link)
# ═════════════════════════════════════════════════════════════════════════════════════════════
print("\n-- (11) classic link (plugin.link)")
d1 = cmd("object.add", path=BIP, lane=6, start=0)["id"]
d2 = cmd("object.add", path=BIP, lane=7, start=0)["id"]
pd1 = pro_q(d1)
wait_loaded(pd1)
placed = cmd("plugin.link", **{"from": d1, "plugin": pd1, "to": d2})["plugins"]
idle()
pd2 = placed[0] if placed else None
check("plugin.link laid a linked copy on the other host", pd2 is not None and pd2 != pd1)
wait_loaded(pd2)
settle()
drain(pd1, pd2)
f1 = floats(pd1)
new = hidden_change(pd2, other=pd1)
time.sleep(1.0)
check("linked: no tick, the other side is unchanged", all(close(floats(pd1)[i], f1[i]) for i in HIDDEN))
r1, r2 = tick(pd2), tick(pd2)
check("linked: two ticks push the other side", r1["pushed"] == [] and r2["pushed"] == [pd1], str((r1, r2)))
check("linked: it reflects the change", all(close(floats(pd1)[i], v) for i, v in new.items()))

# ═════════════════════════════════════════════════════════════════════════════════════════════
# (12) undo après sync : pas de reconstruction
# ═════════════════════════════════════════════════════════════════════════════════════════════
print("\n-- (12) undo after a sync")
drain(pd1, pd2)
off = log_size()
cmd("object.move", id=d1, start=2.0)             # the snapshot is taken here
new = hidden_change(pd2, other=pd1)
tick(pd2, force=True)                            # the sync lays the state on pd1 (outside any snapshot)
time.sleep(0.7)
t0 = time.time()
cmd("edit.undo")
idle()
ms = (time.time() - t0) * 1000
check("the object is back where it was", abs(cmd("object.get", id=d1)["start"]) < 1e-6)
check("the plugin answers straight away after the undo",
      len(cmd("plugin.get_params", plugin=pd1)["params"]) > 0)
check("the undo is instant (%.0f ms; a reload of an AU cannot hide under 150 ms)" % ms, ms < 300.0)
txt = log_since(off)
if txt is None:
    note("no --log: the [UNDO] 'patched' / 'instantiated' lines were not read (timing only)")
else:
    undo = [l for l in txt.splitlines() if "[UNDO]" in l]
    inst = [l for l in txt.splitlines() if "instantiated" in l]
    check("log: an [UNDO] line says 'patched'", any("patched" in l for l in undo), "\n".join(undo[-3:]))
    check("log: the undo rebuilt nothing ('0 rebuilt')", all(("0 rebuilt" in l) or ("rebuilt" not in l) for l in undo),
          "\n".join(undo[-3:]))
    check("log: no plugin was instantiated by the undo", inst == [], "\n".join(inst[-3:]))

# ═════════════════════════════════════════════════════════════════════════════════════════════
# (13) built-in 4bandEq dans un bin : pas de poussée d'état
# ═════════════════════════════════════════════════════════════════════════════════════════════
print("\n-- (13) built-in in a bin")
e1 = cmd("object.add", path=BIP, lane=8, start=0)["id"]
e2 = cmd("object.add", path=BIP, lane=9, start=0)["id"]
eq = cmd("plugin.add", host=e1, identifier="4bandEq", format="TracktionInternal")["plugin"]["id"]
cmd("fxlink.create", objects=[e1, e2], name="eq")
idle()
ea, eb = instance(e1), instance(e2)
check("the built-in bin has two instances", ea is not None and eb is not None and ea != eb)
p0 = pushes_total()
rr = [tick(eb), tick(eb), tick(eb, force=True), tick(ea, force=True)]
check("ticks on a built-in push nothing", all(r["pushed"] == [] for r in rr), str(rr))
check("the counters did not move", pushes_total() == p0)
check("plugin.get_state refuses a built-in", refused("plugin.get_state", plugin=eb) == "invalid_state")
pr = cmd("plugin.get_params", plugin=eb)["params"][0]
goal = pr["min"] + (pr["max"] - pr["min"]) * (0.7 if pr["value"] < (pr["min"] + pr["max"]) / 2 else 0.3)
cmd("plugin.set_param", plugin=eb, index=0, value=goal)
idle()
time.sleep(0.3)
v = cmd("plugin.get_params", plugin=ea)["params"][0]["value"]
check("the built-in's parameter mirror still works", abs(v - goal) < 1e-2 * max(1.0, abs(goal)),
      "A reads %s, wanted %s (B: %s)" % (v, goal, cmd("plugin.get_params", plugin=eb)["params"][0]["value"]))
check("and the sync pushed nothing for it", pushes_total() == p0)

# ═════════════════════════════════════════════════════════════════════════════════════════════
# (14) la fenêtre d'écho de 600 ms ne concerne que la propagation de PARAMÈTRES : la synchro
#      d'ÉTAT (y compris forcée : snapshot, sauvegarde, fermeture d'éditeur) n'en a pas
# ═════════════════════════════════════════════════════════════════════════════════════════════
print("\n-- (14) state sync inside the 600 ms echo window")
ECHO_S = 0.6


def receive_on_b():
    """A is made silently ahead of B, then A's state is laid on B (`fxlink.sync {A}`, forced).
    From that instant B is a member that has just RECEIVED a chunk. Returns (A's new floats, t0)."""
    nw = hidden_change(PA, other=PB, extra=False)
    cmd("fxlink.sync", plugin=PA)
    t0 = time.time()
    return nw, t0


# T1 — a forced (or unforced) sync of the RECEIVER right after the reception pushes nothing false:
#      what B renders is what it was just given, the post-push baseline says so.
drain(PA, PB)
newA, t0 = receive_on_b()
check("(precondition) B received A's state", all(close(floats(PB)[i], v) for i, v in newA.items()))
p0 = pushes_total()
rr = [tick(PB, force=True), tick(PB), tick(PB), tick(PB, force=True)]
el = time.time() - t0
check("T1: the receiver's sync ticks came inside the echo window (%.0f ms)" % (el * 1000), el < ECHO_S)
check("T1: forced and unforced syncs of the receiver push nothing", all(r["pushed"] == [] for r in rr), str(rr))
check("T1: the counters did not move", pushes_total() == p0)
check("T1: A kept its own state (nothing false was pushed back)",
      all(close(floats(PA)[i], v) for i, v in newA.items()))
check("T1: B still holds what it received", all(close(floats(PB)[i], v) for i, v in newA.items()))
drain(PA, PB)

# T2 — a setting changed on the receiver ~100 ms after a reception is taken into account by a
#      forced sync (before the fix the echo test of the state sync dropped it for 600 ms).
drain(PA, PB)
newA, t0 = receive_on_b()
check("(precondition) B received A's state", all(close(floats(PB)[i], v) for i, v in newA.items()))
time.sleep(0.1)
fb = floats(PB)
mine = {i: flip(fb[i]) for i in HIDDEN}          # B's own setting, distinct from what A holds
inject(PB, mine)
check("(precondition) the setting is B's and A is still behind",
      all(close(floats(PB)[i], v) for i, v in mine.items())
      and all(close(floats(PA)[i], v) for i, v in newA.items()))
r = tick(PB, force=True)
el = time.time() - t0
check("T2: the forced sync came inside the echo window (%.0f ms)" % (el * 1000), el < ECHO_S)
check("T2: the forced sync pushes B's setting to A", r["pushed"] == [PA], str(r))
check("T2: A carries B's setting", all(close(floats(PA)[i], v) for i, v in mine.items()),
      str([(i, floats(PA)[i], v) for i, v in mine.items()]))
drain(PA, PB)

# T2b — same, through the flush that precedes an undo snapshot (a pending mark laid by one
#       unforced tick, then a gesture that pushes a snapshot).
newA, t0 = receive_on_b()
time.sleep(0.1)
fb = floats(PB)
mine = {i: flip(fb[i]) for i in HIDDEN}
inject(PB, mine)
r = tick(PB)
check("T2b: an unforced tick inside the window lays the pending mark", r["pending"] is True and r["pushed"] == [], str(r))
cmd("object.move", id=GB, start=1.0)             # the bus pushes a snapshot: flush first
el = time.time() - t0
time.sleep(0.1)
check("T2b: the snapshot came inside the echo window (%.0f ms)" % (el * 1000), el < ECHO_S)
check("T2b: the snapshot flush carried B's setting to A", all(close(floats(PA)[i], v) for i, v in mine.items()),
      str([(i, floats(PA)[i], v) for i, v in mine.items()]))
cmd("object.move", id=GB, start=0.0)
settle()
drain(PA, PB)

# ═════════════════════════════════════════════════════════════════════════════════════════════
# (15) aucune fenêtre sur le pid
# ═════════════════════════════════════════════════════════════════════════════════════════════
print("\n-- (15) no window")
pid = find_pid()
if pid is None:
    note("pid not found (pass --pid=N): the window check was skipped")
else:
    try:
        import Quartz
        wins = [w for w in (Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionAll,
                                                              Quartz.kCGNullWindowID) or [])
                if w.get("kCGWindowOwnerPID") == pid]
        check("CGWindowListCopyWindowInfo: no window on pid %d" % pid, wins == [], str(wins)[:200])
    except ImportError:
        note("Quartz (pyobjc) unavailable: the window check was skipped")

print("\n%d assertion(s), %s" % (total, "ALL PASS" if not fails else "%d FAILED: %s" % (len(fails), fails)))
for n in notes:
    print("  note: " + n)
sys.exit(1 if fails else 0)

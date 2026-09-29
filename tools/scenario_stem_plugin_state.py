#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The state of a plugin on a BUS (a stem, the Main) is written into the session, and does not
leak from one project into the next.

Two defects, both already on HEAD, and this is what guards them:

  (a) `projectDocument` handed the raw model's `stems` to the file: a plugin freshly added to a
      bus has `stateXML == nil` in the model, and one tweaked in its own editor never passes
      through it. Every writer (save, save-as, `project.get_state`, "Save a copy", parking a tab)
      wrote a bus plugin at its FACTORY settings — a FabFilter Pro-L at +12 dB came back at 0.
  (b) the Main's plugins leaked between projects. `setMasterStemKey` purged the Main's chain only
      when the key CHANGED, but V1/V2, Save As, copies and the tabs of one lineage share the Main's
      UUID (and its plugins'): the live instance was then reused WITHOUT the file's state being
      applied, and a project with no plugin on the Main inherited the previous one's.
      A second door to the same leak: an instance taken back from the plugin PARKING is
      matched on the chunk of its TREE, which is only flushed on a save — a setting made since,
      in the plugin's own editor, came back with it.

Sections (each on its OWN fresh instance — an instance leaks state between unrelated runs):

  A   a plugin on the Main, set, then saved / read through `project.get_state` / reopened in the
      same process / reopened in a NEW process: the value is written and comes back.
  B   the same Main key twice (Save As B, same UUIDs): set a second value in B WITHOUT saving,
      open A — the file's value, not the live one.
  C   A copy without the plugin: open A, change the value, open C — the Main's chain is EMPTY
      (`plugin.list`, `stem.list`) and an export re-read at 24 bits has the RMS of the reference
      without any FX.
  C2  tabs: the V1 and the V2 of a project (same UUIDs) side by side through `tab.open`; each tab
      shows its own value on every switch, and a value changed and left unsaved survives the
      round trip.
  D   an EXTERNAL plugin (default Pro-Q 4), if installed: the value written and reloaded, and the
      parking case — a setting made on the live instance after a save, then the project reopened:
      the instance taken back from the parking gets the FILE's state.

    ./scenario_stem_plugin_state.py --app=/path/to/objekat.app [--external=aumf,FQ4p,FabF]

The scenario launches its own headless instances (`--headless --api --no-audio --no-recent`) in
a temporary folder. Debug or Release alike. Exit: 0 if every assertion passes, 1 otherwise.
"""

import base64, json, math, os, plistlib, re, shutil, signal, struct, subprocess, sys, tempfile, time
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

APP = None
EXTERNAL = "aumf,FQ4p,FabF"
for a in sys.argv[1:]:
    if a.startswith("--app="):
        APP = a.split("=", 1)[1]
    elif a.startswith("--external="):
        EXTERNAL = a.split("=", 1)[1]
if not APP:
    print(__doc__)
    sys.exit(2)
BIN = os.path.join(APP, "Contents", "MacOS", "objekat")
BIP = os.path.join(HERE, "fixtures", "bip.wav")

WORK = tempfile.mkdtemp(prefix="objekat_ssps_")
V1, V2, V3 = 300.0, 15000.0, 8000.0     # the lowpass's cutoff, in Hz (default 4000)
fails = []
total = 0
instances = []


def check(label, ok, detail=""):
    global total
    total += 1
    if ok:
        print("ok    " + label)
    else:
        fails.append(label)
        print("FAIL  %s   %s" % (label, detail))


# ── instances ─────────────────────────────────────────────────────────────────────────────────
class Instance:
    def __init__(self, name):
        self.name = name
        self.sock = "/tmp/o_ssps_%s.sock" % name
        if os.path.exists(self.sock):
            os.remove(self.sock)
        self.log = open(os.path.join(WORK, "%s.log" % name), "wb")
        self.proc = subprocess.Popen(
            [BIN, "--headless", "--api", "--no-audio", "--no-recent", "--socket=" + self.sock],
            stdout=self.log, stderr=subprocess.STDOUT)
        instances.append(self)
        for _ in range(120):
            if os.path.exists(self.sock):
                break
            time.sleep(0.5)
        self.c = ObjekatClient(self.sock, timeout=180).connect()
        self.c.send("app.set_dialog_policy", {"policy": "assume_yes"})
        self.cmd("app.info")   # the socket answers

    def cmd(self, name, **params):
        return self.c.send(name, params or None)

    def idle(self, ms=60000):
        self.cmd("wait_idle", timeout_ms=ms)

    def refused(self, name, **params):
        try:
            self.cmd(name, **params)
            return None
        except ObjekatError as e:
            return e.code

    def windows(self):
        """On-screen windows of this process — must stay empty (headless)."""
        try:
            import Quartz
        except ImportError:
            return None
        info = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionAll, Quartz.kCGNullWindowID)
        return [w for w in info if w.get("kCGWindowOwnerPID") == self.proc.pid
                and w.get("kCGWindowIsOnscreen")]

    def stop(self):
        try:
            self.c.close()
        except Exception:
            pass
        self.proc.send_signal(signal.SIGTERM)
        try:
            self.proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            self.proc.kill()
        if os.path.exists(self.sock):
            os.remove(self.sock)


def stop_all():
    for i in instances:
        try:
            i.stop()
        except Exception:
            pass


# ── reading things ────────────────────────────────────────────────────────────────────────────
def main_id(i):
    return i.cmd("stem.list")["main"]


def chain(i, host):
    return i.cmd("plugin.list", host=host)["plugins"]


def value(i, plugin, index=0):
    ps = i.cmd("plugin.get_params", plugin=plugin)["params"]
    return ps[index]["value"] if len(ps) > index else None


def await_value(i, plugin, want, index=0, tol=0.5, timeout=8.0):
    """The parameter's value once it is what we want — or the last one read. An external plugin
    re-asserts its state on a timer, so a right answer may take a moment; a WRONG one never
    changes, and costs the timeout."""
    dl = time.time() + timeout
    v = None
    while time.time() < dl:
        try:
            v = value(i, plugin, index)
        except ObjekatError:
            v = None
        if v is not None and abs(v - want) <= tol:
            return v
        time.sleep(0.25)
    return v


def approx(v, want, tol=0.5):
    return v is not None and abs(v - want) <= tol


def stateful(xml, want, rel=1e-3):
    """True if some attribute of the plugin's XML state is a number close to `want`."""
    if not xml:
        return False
    try:
        root = ET.fromstring(xml)
    except ET.ParseError:
        return False
    for el in root.iter():
        for v in el.attrib.values():
            try:
                f = float(v)
            except ValueError:
                continue
            if abs(f - want) <= rel * max(1.0, abs(want)):
                return True
    return False


def bus_state_from_state(i):
    """The Main's plugins as `project.get_state` serialises them."""
    return i.cmd("project.get_state")["stems"][0]["plugins"]


def bus_state_from_file(path):
    with open(path) as f:
        return json.load(f)["stems"][0]["plugins"]


def rms24(path):
    import wave
    with wave.open(path, "rb") as w:
        sw, ch, raw = w.getsampwidth(), w.getnchannels(), w.readframes(w.getnframes())
    if sw != 3:
        raise RuntimeError("expected 24-bit, got %d bytes/sample" % sw)
    acc, n = 0.0, 0
    for k in range(0, len(raw) - 2, 3):
        v = int.from_bytes(raw[k:k + 3], "little", signed=True) / 8388608.0
        acc += v * v
        n += 1
    return math.sqrt(acc / n) if n else 0.0


def render(i, name):
    """Exports the whole project as a 24-bit undithered WAV and returns its RMS."""
    out = os.path.join(WORK, name)
    r = i.cmd("export.run", format="wav", sample_rate=44100, bit_depth=24, dithering=False, path=out)
    i.cmd("job.wait", id=r["job_id"], timeout_ms=120000)
    return rms24(out)


def add_lowpass(i, host):
    return i.cmd("plugin.add", host=host, identifier="lowpass",
                 format="TracktionInternal")["plugin"]["id"]


def path_of(name):
    d = os.path.join(WORK, name)
    os.makedirs(d, exist_ok=True)
    return os.path.join(d, name + ".objekat")


def build_project_a(i, path):
    """A project holding a bip and a lowpass on the Main at V1. Saved to `path`."""
    i.cmd("project.new")
    i.cmd("project.save_as", path=path)
    i.cmd("object.add", path=BIP, lane=0, start=0)
    m = main_id(i)
    p = add_lowpass(i, m)
    i.idle(30000)
    i.cmd("plugin.set_param", plugin=p, index=0, value=V1)
    i.idle(30000)
    i.cmd("project.save")
    return m, p


PATH_A = path_of("A")

try:
    # ══════════════════════════════════════════════════════════════════════════════════════════
    print("\n-- A: the state is written, and comes back")
    ia = Instance("a1")
    M, P = build_project_a(ia, PATH_A)
    check("the plugin sits on the Main (stem.list: plugin_count 1)",
          ia.cmd("stem.list")["stems"][0]["plugin_count"] == 1)
    check("the live value is V1", approx(value(ia, P), V1), value(ia, P))

    st = bus_state_from_state(ia)
    check("project.get_state: the bus plugin's stateXML is not null",
          len(st) == 1 and bool(st[0].get("stateXML")), st and list(st[0].keys()))
    check("project.get_state: the stateXML carries V1",
          len(st) == 1 and stateful(st[0].get("stateXML"), V1), (st[0].get("stateXML") or "")[:200])

    f = bus_state_from_file(PATH_A)
    check("the session file: the bus plugin's stateXML is not null",
          len(f) == 1 and bool(f[0].get("stateXML")))
    check("the session file: the stateXML carries V1",
          len(f) == 1 and stateful(f[0].get("stateXML"), V1))

    # a value changed and NOT saved: the next capture must see it (a live setting, not the model's)
    ia.cmd("plugin.set_param", plugin=P, index=0, value=V3)
    ia.idle()
    check("get_state after an unsaved change carries the NEW value (live capture)",
          stateful(bus_state_from_state(ia)[0].get("stateXML"), V3))
    ia.cmd("plugin.set_param", plugin=P, index=0, value=V1)
    ia.idle()

    # a plugin added and never touched: its state must reach the file too
    lp2 = add_lowpass(ia, M)
    ia.idle()
    fresh = bus_state_from_state(ia)
    check("a freshly added, untouched bus plugin has a state too",
          len(fresh) == 2 and all(bool(p.get("stateXML")) for p in fresh),
          [bool(p.get("stateXML")) for p in fresh])
    ia.cmd("plugin.remove", host=M, plugin=lp2)
    ia.idle()

    # reopen in the same process (project.new first: another Main key in between)
    ia.cmd("project.new")
    ia.cmd("project.open", path=PATH_A)
    ia.idle()
    m2 = main_id(ia)
    ch = chain(ia, m2)
    check("reopened (same process): the plugin is on the Main", len(ch) == 1, len(ch))
    if ch:
        check("reopened (same process): the value is V1",
              approx(value(ia, ch[0]["id"]), V1), value(ia, ch[0]["id"]))
    check("headless: no window (instance a1)", ia.windows() in (None, []), ia.windows())
    ia.stop()

    ia2 = Instance("a2")
    ia2.cmd("project.open", path=PATH_A)
    ia2.idle()
    ch = chain(ia2, main_id(ia2))
    check("reopened (NEW process): the plugin is on the Main", len(ch) == 1, len(ch))
    if ch:
        check("reopened (NEW process): the value is V1",
              approx(value(ia2, ch[0]["id"]), V1), value(ia2, ch[0]["id"]))
    ia2.stop()

    # ══════════════════════════════════════════════════════════════════════════════════════════
    print("\n-- B: two projects sharing the Main's UUID")
    ib = Instance("b1")
    ib.cmd("project.open", path=PATH_A)
    ib.idle()
    mA = main_id(ib)
    PATH_B = path_of("B")
    ib.cmd("project.save_as", path=PATH_B)
    ib.idle()
    check("Save As keeps the Main's UUID (the premise of the leak)", main_id(ib) == mA)
    pB = chain(ib, mA)[0]["id"]
    ib.cmd("plugin.set_param", plugin=pB, index=0, value=V2)     # NOT saved
    ib.idle()
    check("B's live value is V2", approx(value(ib, pB), V2), value(ib, pB))
    ib.cmd("project.open", path=PATH_A)
    ib.idle()
    chA = chain(ib, main_id(ib))
    check("opening A: one plugin on the Main", len(chA) == 1, len(chA))
    if chA:
        v = value(ib, chA[0]["id"])
        check("opening A after B (same Main key): the FILE's value, not the live one (%s)" % v,
              approx(v, V1), v)
    ib.stop()

    # ══════════════════════════════════════════════════════════════════════════════════════════
    print("\n-- C: a copy WITHOUT the plugin")
    ic = Instance("c1")
    # The reference: a bip and nothing else, SAVED AND REOPENED — the same regime as C, which
    # is opened from a file. (Measured on 29 September, on HEAD as well: the same project renders
    # 3 dB louder once reopened than in the session that built it — an object added in the
    # session is not the object loaded from the file. Comparing C with a session-built
    # reference would fail for that reason alone, and say nothing about plugins.)
    ic.cmd("project.new")
    PATH_REF = path_of("REF")
    ic.cmd("project.save_as", path=PATH_REF)
    ic.cmd("object.add", path=BIP, lane=0, start=0)
    ic.cmd("project.save")
    ic.cmd("project.open", path=PATH_REF)
    ic.idle()
    rms_ref = render(ic, "ref.wav")

    ic.cmd("project.open", path=PATH_A)
    ic.idle()
    rms_a = render(ic, "a.wav")
    check("precondition: the lowpass changes the render (ref %.4f, A %.4f)" % (rms_ref, rms_a),
          rms_ref > 0.01 and abs(rms_a - rms_ref) > 0.05 * rms_ref)

    PATH_C = path_of("C")
    mC = main_id(ic)
    ic.cmd("project.save_as", path=PATH_C)
    ic.idle()
    ic.cmd("plugin.remove", host=mC, plugin=chain(ic, mC)[0]["id"])
    ic.idle()
    ic.cmd("project.save")
    check("C is saved with an empty Main chain", bus_state_from_file(PATH_C) == [])

    ic.cmd("project.open", path=PATH_A)
    ic.idle()
    pC = chain(ic, main_id(ic))[0]["id"]
    # a cutoff that is plainly audible on the bip: a leaked lowpass would change the render a lot
    ic.cmd("plugin.set_param", plugin=pC, index=0, value=100.0)
    ic.idle()
    ic.cmd("project.open", path=PATH_C)
    ic.idle()
    mc = main_id(ic)
    check("opening C: same Main key as A (the premise)", mc == mC)
    check("opening C: plugin.list of the Main is EMPTY", chain(ic, mc) == [], chain(ic, mc))
    check("opening C: stem.list says plugin_count 0",
          ic.cmd("stem.list")["stems"][0]["plugin_count"] == 0)
    rms_c = render(ic, "c.wav")
    check("opening C: the render has the RMS of the reference without FX (%.5f vs %.5f)"
          % (rms_c, rms_ref), abs(rms_c - rms_ref) <= 1e-4 * max(rms_ref, 1e-9), (rms_c, rms_ref))
    check("headless: no window (instance c1)", ic.windows() in (None, []), ic.windows())
    ic.stop()

    # ══════════════════════════════════════════════════════════════════════════════════════════
    print("\n-- C2: tabs, V1 and V2 of one project")
    it = Instance("t1")
    it.cmd("project.open", path=PATH_A)
    it.idle()
    mT = main_id(it)
    PATH_V2 = path_of("V2")
    it.cmd("project.save_as", path=PATH_V2)
    it.idle()
    pV2 = chain(it, mT)[0]["id"]
    it.cmd("plugin.set_param", plugin=pV2, index=0, value=V2)
    it.idle()
    it.cmd("project.save")
    check("V2's file carries V2", stateful(bus_state_from_file(PATH_V2)[0].get("stateXML"), V2))
    r = it.cmd("tab.open", path=PATH_A)
    it.idle()
    check("tab 2 (V1) opened as a new tab", r.get("already_open") is False, r)
    check("both tabs share the Main's UUID", main_id(it) == mT)
    pV1 = chain(it, mT)[0]["id"]
    v = await_value(it, pV1, V1)
    check("tab V1 shows V1, not V2's live value (%s)" % v, approx(v, V1), v)
    it.cmd("plugin.set_param", plugin=pV1, index=0, value=V3)      # unsaved, in the V1 tab
    it.idle()

    it.cmd("tab.select", index=1)
    it.idle()
    p1 = chain(it, mT)[0]["id"]
    v = await_value(it, p1, V2)
    check("back on tab V2: V2 (%s)" % v, approx(v, V2), v)
    it.cmd("tab.select", index=2)
    it.idle()
    p2 = chain(it, mT)[0]["id"]
    v = await_value(it, p2, V3)
    check("back on tab V1: the UNSAVED V3 survived the round trip (%s)" % v, approx(v, V3), v)
    it.cmd("tab.select", index=1)
    it.idle()
    p1 = chain(it, mT)[0]["id"]
    v = await_value(it, p1, V2)
    check("and on tab V2 again: still V2 (%s)" % v, approx(v, V2), v)
    check("headless: no window (instance t1)", it.windows() in (None, []), it.windows())
    it.stop()

    # ══════════════════════════════════════════════════════════════════════════════════════════
    print("\n-- E: undoing a value changed on a bus plugin")
    ie = Instance("e1")
    ie.cmd("project.open", path=PATH_A)
    ie.idle()
    mE = main_id(ie)
    pE = chain(ie, mE)[0]["id"]
    obj = ie.cmd("object.list")["objects"][0]["id"]
    ie.cmd("object.move", id=obj, start=1.0)          # the undo snapshot is taken HERE (plugin at V1)
    ie.cmd("plugin.set_param", plugin=pE, index=0, value=V2)
    ie.idle()
    check("E: the value did move to V2", approx(value(ie, pE), V2), value(ie, pE))
    ie.cmd("edit.undo")
    ie.idle()
    chE = chain(ie, mE)
    check("E: the plugin is still on the Main after the undo", len(chE) == 1, len(chE))
    if chE:
        v = value(ie, chE[0]["id"])
        check("E: the undo gives the bus plugin's value back (%s)" % v, approx(v, V1), v)
        check("E: the plugin was patched, not rebuilt (same id)", chE[0]["id"] == pE)
    ie.stop()

    # ══════════════════════════════════════════════════════════════════════════════════════════
    print("\n-- D: an external plugin (%s)" % EXTERNAL)
    idd = Instance("d1")
    avail = any(p["identifier"] == EXTERNAL for p in idd.cmd("plugin.list_available")["plugins"])
    try:
        idd.cmd("debug.link_state")
        debug_build = True
    except ObjekatError:
        debug_build = False
    if not avail or not debug_build:
        print("SKIP  section D not run (%s)" %
              ("%s is not installed" % EXTERNAL if not avail else "needs a DEBUG build: debug.plugin_inject_state"))
    else:
        # A native GUI edits the plugin's CHUNK and tells nobody; `plugin.set_param` moves an AU
        # parameter that Pro-Q's chunk does not follow. So the settings are laid as chunks:
        # `debug.plugin_inject_state`, the way scenario_fxlink_state_sync.py does it.
        def float0(i, plugin):
            pl = plistlib.loads(base64.b64decode(i.cmd("plugin.get_state", plugin=plugin)["state"]))
            return struct.unpack_from("<f", pl["FabFilterPluginState"], 12)[0]

        def inject0(i, plugin, v):
            pl = plistlib.loads(base64.b64decode(i.cmd("plugin.get_state", plugin=plugin)["state"]))
            blob = bytearray(pl["FabFilterPluginState"])
            struct.pack_into("<f", blob, 12, v)
            pl["FabFilterPluginState"] = bytes(blob)
            i.cmd("debug.plugin_inject_state", plugin=plugin,
                  state=base64.b64encode(plistlib.dumps(pl, fmt=plistlib.FMT_BINARY)).decode())

        def await_float0(i, plugin, want, timeout=20.0):
            dl = time.time() + timeout
            v = None
            while time.time() < dl:
                try:
                    v = float0(i, plugin)
                except (ObjekatError, KeyError):
                    v = None
                if v is not None and abs(v - want) < 1e-4:
                    return v
                time.sleep(0.25)
            return v

        def file_float0(path):
            xml = bus_state_from_file(path)[0]["stateXML"]
            m = re.search(r'state="([^"]*)"', xml)
            size, rest = m.group(1).split(".", 1)
            ch = ".ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+"
            acc = bits = 0
            out = bytearray()
            for c_ in rest:
                acc |= ch.index(c_) << bits
                bits += 6
                while bits >= 8:
                    out.append(acc & 255)
                    acc >>= 8
                    bits -= 8
            pl = plistlib.loads(bytes(out[:int(size)]))
            return struct.unpack_from("<f", pl["FabFilterPluginState"], 12)[0]

        idd.cmd("project.new")
        PATH_D = path_of("D")
        idd.cmd("project.save_as", path=PATH_D)
        idd.cmd("object.add", path=BIP, lane=0, start=0)
        mD = main_id(idd)
        pD = idd.cmd("plugin.add", host=mD, identifier=EXTERNAL, format="AudioUnit")["plugin"]["id"]
        dl = time.time() + 40
        while time.time() < dl:
            try:
                if len(idd.cmd("plugin.get_params", plugin=pD)["params"]) > 2:
                    break
            except ObjekatError:
                pass
            time.sleep(0.25)
        idd.idle()
        f0 = float0(idd, pD)
        # Float 0 of the chunk is a switch: only 0 and 1 hold (0.5 is snapped back).
        S1 = 1.0 if f0 > 0.5 else 0.0          # where the plugin starts
        S0 = 1.0 - S1                          # the other one
        inject0(idd, pD, S0)
        idd.idle()
        v = await_float0(idd, pD, S0, 5.0)
        check("external: the chunk moved to S0", v is not None and abs(v - S0) < 1e-4, (v, S0))
        idd.cmd("project.save")
        f = bus_state_from_file(PATH_D)
        check("external: the bus plugin's chunk is in the file",
              len(f) == 1 and len(f[0].get("stateXML") or "") > 100)
        check("external: and it carries S0", abs(file_float0(PATH_D) - S0) < 1e-4, file_float0(PATH_D))

        # the parking door: a setting made AFTER the save, on the live instance (the tree keeps S0)
        inject0(idd, pD, S1)
        idd.idle()
        v = await_float0(idd, pD, S1, 5.0)
        check("external: the live chunk moved to S1, unsaved", v is not None and abs(v - S1) < 1e-4, (v, S1))
        idd.cmd("project.open", path=PATH_D)
        idd.idle(120000)
        pD2 = chain(idd, main_id(idd))[0]["id"]
        v = await_float0(idd, pD2, S0)
        check("external: reopening gives the FILE's state, not the live S1 (%s)" % v,
              v is not None and abs(v - S0) < 1e-4, (v, S0, S1))
        idd.stop()

        idd2 = Instance("d2")
        idd2.cmd("project.open", path=PATH_D)
        idd2.idle(120000)
        pD3 = chain(idd2, main_id(idd2))[0]["id"]
        v = await_float0(idd2, pD3, S0)
        check("external: reopened in a NEW process: S0 (%s)" % v, v is not None and abs(v - S0) < 1e-4, (v, S0))
        check("headless: no window (instance d2)", idd2.windows() in (None, []), idd2.windows())
        idd2.stop()
finally:
    stop_all()
    if not fails:
        shutil.rmtree(WORK, ignore_errors=True)
    else:
        print("(work folder kept for inspection: %s)" % WORK)

print("\n%d assertion(s), %s" % (total,
                                 "ALL PASS" if not fails else "%d FAILED: %s" % (len(fails), fails)))
sys.exit(1 if fails else 0)

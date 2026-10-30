#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""E7 of docs/plan_groupes_midi.md : the FX of an empty clip, and of a sub-group below a host, are PASSIVE (plan 2.5, P11).

The model keeps the user's choice (`enabled` as listed by `plugin.list`), the engine gets `enabled && !passive`
(`debug.plugin_buses`, DEBUG builds). What is asserted:

  U1  an effect on an EMPTY clip of H: on in the model, OFF in the engine
  U2  the same effect on a clip with its OWN instrument: ON in the engine (control, nothing changed for it)
  U3  an effect on a PLAIN group (no host above): ON in the engine (control)
  U4  an effect on a sub-group of H: OFF in the engine; the host's instrument removed -> ON again; put back -> OFF again
  U5  an effect toggled off then on by the user on an empty clip: the model follows, the engine stays OFF
  U6  undo of the instrument removal brings the sub-group's effect back to OFF
  U7  the sub-group ejected from the host: ON ; put back in: OFF

    ./scenario_group_ui.py /path/to/objekat.app

Exit: 0 if every assertion passes, 1 otherwise, 2 on bad usage.
"""

import json, math, os, struct, subprocess, sys, tempfile, time, traceback, wave

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

if len(sys.argv) < 2:
    print(__doc__)
    sys.exit(2)

APP = sys.argv[1]
BIN = os.path.join(APP, "Contents", "MacOS", "objekat")
if not os.path.exists(BIN):
    print("not an app bundle: %s" % APP)
    sys.exit(2)

WORK = tempfile.mkdtemp(prefix="objk-gui-")
FAILS = []
TOTAL = [0]


def check(label, ok, detail=""):
    TOTAL[0] += 1
    if ok:
        print("ok    " + label)
    else:
        FAILS.append(label)
        print("FAIL  %s  %s" % (label, detail))


def tone(name, seconds=1.0):
    path = os.path.join(WORK, name)
    w = wave.open(path, "wb")
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(48000)
    n = int(48000 * seconds)
    w.writeframes(b"".join(struct.pack("<h", int(8000 * math.sin(2 * math.pi * 440 * i / 48000))) for i in range(n)))
    w.close()
    return path


class App:
    def __init__(self):
        self.sock = "/tmp/objk-gui-%d.sock" % os.getpid()
        if os.path.exists(self.sock):
            os.remove(self.sock)
        self.err = os.path.join(WORK, "app.err")
        self.proc = subprocess.Popen(
            [BIN, "--headless", "--api", "--no-recent", "--language=en", "--virtual-audio", "--virtual-midi",
             "--socket=" + self.sock],
            stdout=subprocess.DEVNULL, stderr=open(self.err, "w"), env=dict(os.environ, OBJ_SKIP_REAL_CARD="1"))
        for _ in range(240):
            if os.path.exists(self.sock):
                break
            time.sleep(0.25)
        self.c = ObjekatClient(self.sock).connect()
        self.c.send("project.new")
        insts = self.c.send("plugin.list_available", {"instruments_only": True})["plugins"]
        dls = next(p for p in insts if p["name"] == "DLSMusicDevice")
        self.inst = {"identifier": dls["identifier"], "format": dls["format"]}

    def close(self):
        try:
            self.c.close()
        except Exception:
            pass
        self.proc.terminate()
        try:
            self.proc.wait(15)
        except Exception:
            self.proc.kill()
        if os.path.exists(self.sock):
            os.remove(self.sock)

    # --- reading
    def state(self):
        return json.dumps(self.c.send("project.get_state"), sort_keys=True)

    def _depth(self):
        return self.c.send("perf.census")["undo_depth"]

    def dialogs(self):
        return self.c.send("app.dialogs")["dialogs"]

    def objects(self):
        return {o["id"]: o for o in self.c.send("object.list")["objects"]}

    def parent(self, oid):
        return self.objects().get(oid, {}).get("parent")



def midi_clip(app, start, end, lane):
    return app.c.send("midi.create_clip", {"start": start, "end": end, "lane": lane})["id"]


def make_group(app, ids):
    return app.c.send("group.create", {"ids": ids})["id"]


def add_fx(app, host):
    c = app.c
    fx = next(p for p in c.send("plugin.list_available")["plugins"]
              if p["format"] == "AudioUnit" and not p.get("is_instrument") and p["name"].startswith("AU"))
    return c.send("plugin.add", {"host": host, "identifier": fx["identifier"], "format": fx["format"]})["plugin"]["id"]


def model_enabled(app, host, pid):
    plugs = app.c.send("plugin.list", {"host": host})["plugins"]
    return next(p for p in plugs if p["id"] == pid).get("enabled")


def engine_enabled(app, pid):
    return app.c.send("debug.plugin_buses", {"plugin": pid}).get("enabled")


def main():
    app = App()
    try:
        c = app.c
        a = midi_clip(app, 0, 4, 0)
        h = make_group(app, [a])
        c.send("instrument.set", {"id": h, **app.inst})
        fa = add_fx(app, a)
        check("U1 empty clip: the model keeps the user's choice (on)", model_enabled(app, a, fa) is True)
        check("U1 empty clip: the engine has it OFF", engine_enabled(app, fa) is False, str(engine_enabled(app, fa)))

        own = midi_clip(app, 0, 4, 5)
        c.send("instrument.set", {"id": own, **app.inst})
        fo = add_fx(app, own)
        check("U2 clip with its own instrument: engine ON", engine_enabled(app, fo) is True, str(engine_enabled(app, fo)))

        m = midi_clip(app, 0, 4, 6)
        plain = make_group(app, [m])
        fp = add_fx(app, plain)
        check("U3 plain group, no host: engine ON", engine_enabled(app, fp) is True, str(engine_enabled(app, fp)))

        s_member = midi_clip(app, 0, 4, 7)
        s = make_group(app, [s_member])
        c.send("group.expand", {"id": h, "expanded": True})
        c.send("group.reparent", {"ids": [s], "group": h, "child_lane": 3})
        check("U4 setup: S is a sub-group of H", app.parent(s) == h)
        fs = add_fx(app, s)
        check("U4 sub-group of H: engine OFF", engine_enabled(app, fs) is False, str(engine_enabled(app, fs)))
        check("U4 ... the model still says on", model_enabled(app, s, fs) is True)
        c.send("instrument.remove", {"id": h})
        check("U4 host's instrument removed: the sub-group's effect is back ON", engine_enabled(app, fs) is True,
              str(engine_enabled(app, fs)))
        check("U4 ... the empty clip's one stays OFF (an empty clip is always passive)", engine_enabled(app, fa) is False)
        c.send("instrument.set", {"id": h, **app.inst})
        check("U4 instrument put back: OFF again", engine_enabled(app, fs) is False, str(engine_enabled(app, fs)))

        c.send("plugin.toggle", {"host": a, "plugin": fa})
        c.send("plugin.toggle", {"host": a, "plugin": fa})
        check("U5 toggled twice: the model follows (on)", model_enabled(app, a, fa) is True)
        check("U5 ... the engine stays OFF", engine_enabled(app, fa) is False)

        c.send("instrument.remove", {"id": h})
        check("U6 setup: effect ON after the removal", engine_enabled(app, fs) is True)
        c.send("edit.undo")
        check("U6 undo of the removal: OFF again", engine_enabled(app, fs) is False, str(engine_enabled(app, fs)))

        c.send("group.eject", {"ids": [s], "lane": 9})
        check("U7 setup: S left H", app.parent(s) is None)
        check("U7 sub-group ejected from the host: its effect is ON", engine_enabled(app, fs) is True,
              str(engine_enabled(app, fs)))
        c.send("group.expand", {"id": h, "expanded": True})
        c.send("group.reparent", {"ids": [s], "group": h, "child_lane": 4})
        check("U7 sub-group put back into the host: OFF again", engine_enabled(app, fs) is False,
              str(engine_enabled(app, fs)))
    finally:
        app.close()


try:
    main()
except Exception:
    traceback.print_exc()
    FAILS.append("exception")

print("\n%d assertions, %d failed" % (TOTAL[0], len(FAILS)))
for f in FAILS:
    print("  FAIL " + f)
sys.exit(1 if FAILS else 0)

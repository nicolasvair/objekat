#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""E5 of docs/plan_groupes_midi.md : the DOORS of a group that carries an instrument (D1..D16).

A group with an instrument takes only EMPTY MIDI clips (and groups of them): no audio, no aux, no consolidated instance,
no second instrument on the chain, no audio recording input. Every door a gesture can come in by asks the same pure rule
(GroupInstrumentRule) BEFORE it touches anything, and a refusal is all-or-nothing. For every refusal this asserts:

  - the command answers `invalid_state` with `details.reason` = the refusal's name,
  - the model is UNCHANGED (get_state, byte for byte),
  - the undo stack is UNCHANGED (`undo_depth`),
  - the notification is journalled (`app.dialogs`, title "Gesture refused").

Cases:
  D1  reparent an audio clip into H                    audioChild
  D2  reparent an aux into H                           auxChild
  D3  reparent a MIDI clip that has its own instrument childWithInstrument
  D4  reparent a group holding audio                   audioChild
  D5  reparent another instrument group                childWithInstrument
  D6  object.add (audio file) straight into H          audioChild
  D7  aux.create on a row of H                         auxChild
  D8  paste an audio clip on a row of H                audioChild
  D9  instrument.set on a group holding audio          audioChild
  D10 instrument.set on a sub-group of H               insideInstrumentGroup
  D11 instrument.set on an empty clip of H             childWithInstrument
  D12 rec.assign (audio input) on H                    audioInput
  D13 mixed selection (empty clip + audio) -> H        audioChild, the empty clip stays where it was too
  D14 CONTROL: an empty clip goes into H, undo gives it back
  D17 DRAG an audio clip onto a row of H (the release of a move) audioChild
  D18 the same with the option key (copy), from another group audioChild
  D15 reparent a consolidated instance                 consolidatedChild
  D16 an instrument group dropped into a plain group is fine (the rule only bites below an instrument)

    ./scenario_group_instrument_doors.py /path/to/objekat.app

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

WORK = tempfile.mkdtemp(prefix="objk-doors-")
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
        self.sock = "/tmp/objk-doors-%d.sock" % os.getpid()
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


def refused(app, label, reason, call):
    """Runs `call` (a thunk sending ONE command) and asserts a clean refusal."""
    before, depth, dlg = app.state(), app._depth(), len(app.dialogs())
    code = det = None
    try:
        call()
    except ObjekatError as e:
        code, det = e.code, e.details
        if code != "invalid_state":
            print("      %s: %s" % (e.code, e.message))
    check("%s: invalid_state" % label, code == "invalid_state", "got %r" % code)
    got = det.get("reason") if isinstance(det, dict) else None
    check("%s: reason %s" % (label, reason), got == reason, "got %r" % (det,))
    check("%s: model unchanged" % label, app.state() == before)
    check("%s: undo stack unchanged" % label, app._depth() == depth, "%s -> %s" % (depth, app._depth()))
    dl = app.dialogs()
    check("%s: notification journalled" % label,
          len(dl) == dlg + 1 and dl[-1]["title"] == "Gesture refused", "%d -> %d" % (dlg, len(dl)))


def midi_clip(app, start, end, lane):
    return app.c.send("midi.create_clip", {"start": start, "end": end, "lane": lane})["id"]


def make_group(app, ids):
    return app.c.send("group.create", {"ids": ids})["id"]


def reparent(app, ids, group, lane=0):
    # `child_lane` matters: dropped on a lane that is taken at the same instant, an object replaces what is there.
    return app.c.send("group.reparent", {"ids": ids, "group": group, "child_lane": lane})


def main():
    app = App()
    try:
        wav = tone("tone.wav")
        c = app.c
        # H: the host, an empty clip A inside, an instrument on it.
        a = midi_clip(app, 0, 4, 0)
        h = make_group(app, [a])
        c.send("instrument.set", {"id": h, **app.inst})
        c.send("group.expand", {"id": h, "expanded": True})
        # The things that must be refused.
        z = c.send("object.add", {"path": wav, "lane": 6, "start": 0})["id"]          # audio clip at the root
        x = c.send("aux.create", {"start": 0, "end": 2, "lane": 7})["id"]              # aux at the root
        m = midi_clip(app, 0, 4, 8)                                                     # a clip with its own instrument
        c.send("instrument.set", {"id": m, **app.inst})
        z2 = c.send("object.add", {"path": wav, "lane": 9, "start": 0})["id"]
        g_audio = make_group(app, [z2])                                                 # a group holding audio
        c2 = midi_clip(app, 0, 4, 10)
        k = make_group(app, [c2])                                                       # another instrument group
        c.send("instrument.set", {"id": k, **app.inst})
        a2 = midi_clip(app, 0, 4, 11)                                                   # an empty clip at the root

        print("\n── refusals ──")
        refused(app, "D1  audio clip -> H", "audioChild", lambda: reparent(app, [z], h))
        refused(app, "D2  aux -> H", "auxChild", lambda: reparent(app, [x], h))
        refused(app, "D3  MIDI clip with an instrument -> H", "childWithInstrument", lambda: reparent(app, [m], h))
        refused(app, "D4  group holding audio -> H", "audioChild", lambda: reparent(app, [g_audio], h))
        refused(app, "D5  instrument group -> H", "childWithInstrument", lambda: reparent(app, [k], h))
        refused(app, "D6  object.add into H", "audioChild",
                lambda: c.send("object.add", {"path": wav, "group": h}))
        a_row = app.objects()[a]["display_lane"]
        refused(app, "D7  aux.create on a row of H", "auxChild",
                lambda: c.send("aux.create", {"start": 0, "end": 2, "lane": a_row}))
        c.send("selection.set", {"ids": [z]})
        c.send("clipboard.copy")
        c.send("timesel.set", {"start": 0, "end": 2, "lanes": [a_row]})
        refused(app, "D8  paste an audio clip on a row of H", "audioChild", lambda: c.send("clipboard.paste"))
        c.send("timesel.clear")
        refused(app, "D9  instrument on a group holding audio", "audioChild",
                lambda: c.send("instrument.set", {"id": g_audio, **app.inst}))

        # A plain sub-group of H (a control: it is accepted), then an instrument on it.
        a3 = midi_clip(app, 0, 4, 12)
        s = make_group(app, [a3])
        before = app.parent(s)
        try:
            reparent(app, [s], h, 3)
            ok = app.parent(s) == h
        except ObjekatError as e:
            ok = False
            print("      %s %s" % (e.code, e.message))
        check("D10 control: an empty sub-group goes into H", ok and before is None)
        refused(app, "D10 instrument on a sub-group of H", "insideInstrumentGroup",
                lambda: c.send("instrument.set", {"id": s, **app.inst}))
        refused(app, "D11 instrument on an empty clip of H", "childWithInstrument",
                lambda: c.send("instrument.set", {"id": a, **app.inst}))
        refused(app, "D12 audio input on H", "audioInput",
                lambda: c.send("rec.assign", {"group": h, "first": 0, "count": 1}))
        refused(app, "D13 mixed selection -> H", "audioChild", lambda: reparent(app, [a2, z], h))
        check("D13 the empty clip of the mixed selection stayed where it was", app.parent(a2) is None)

        row = lambda oid: app.objects()[oid]["display_lane"]
        refused(app, "D17 drag an audio clip onto a row of H", "audioChild",
                lambda: c.send("debug.move_drop", {"id": z, "dl": row(a) - row(z)}))
        # The option-drag of a ROOT object never enters a group (it copies at the root): the copy path that does is
        # the one that comes from another group.
        c.send("group.expand", {"id": g_audio, "expanded": True})
        refused(app, "D18 option-drag (copy) an audio clip of another group onto a row of H", "audioChild",
                lambda: c.send("debug.move_drop", {"id": z2, "dl": row(a) - row(z2), "alt": True}))

        print("\n── controls ──")
        depth = app._depth()
        try:
            reparent(app, [a2], h, 4)
            ok = app.parent(a2) == h
        except ObjekatError as e:
            ok = False
            print("      %s %s" % (e.code, e.message))
        check("D14 an empty clip goes into H", ok)
        check("D14 ... as ONE undo point", app._depth() == depth + 1, "%s -> %s" % (depth, app._depth()))
        c.send("edit.undo")
        check("D14 ... and undo gives it back", app.parent(a2) is None)
        # A group with an instrument into a PLAIN group is nobody's business.
        plain_member = midi_clip(app, 0, 4, 13)
        plain = make_group(app, [plain_member])
        c.send("group.expand", {"id": plain, "expanded": True})
        try:
            reparent(app, [k], plain, 2)
            ok = app.parent(k) == plain
        except ObjekatError as e:
            ok = False
            print("      %s %s" % (e.code, e.message))
        check("D16 an instrument group goes into a plain group", ok)
        c.send("edit.undo")

        print("\n── consolidated instance ──")
        proj = os.path.join(WORK, "proj")
        c.send("project.save_as", {"path": os.path.join(proj, "doors.objekat")})
        z3 = c.send("object.add", {"path": wav, "lane": 14, "start": 0})["id"]
        r = c.send("consolidate.make", {"id": z3})
        job = c.send("job.wait", {"id": r["job_id"], "timeout_ms": 180000})
        res = job.get("result", {})
        if res.get("phase") == "failed" or "error" in res:
            print("SKIP  D15 consolidated instance (consolidation failed: %s)" % res)
        else:
            instance = next((i for i, o in app.objects().items() if o.get("definition")), None)
            check("D15 an instance exists", instance is not None)
            if instance:
                refused(app, "D15 consolidated instance -> H", "consolidatedChild", lambda: reparent(app, [instance], h))
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

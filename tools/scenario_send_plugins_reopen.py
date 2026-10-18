#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Plugins on a send, saved, then reopened in a REAL NEW PROCESS (docs/plan_sends_rework.md, D.2.G,
"Lot 3").

`scenario_bridge_sends.py` (section Z3) reopens a project in the process that saved it: whatever the
app keeps in memory — plugin instances, caches, the bridge's maps — can hide a state that never
reached the file. Here the instance that saved is KILLED and another one is launched:

  PROCESS A — four senders (a 1 kHz tone each), one per send position (post-fader, pre-fader, input,
  in the chain after a trunk plugin), each to its own aux, each send carrying a TUNED built-in Low
  Pass; two of them also carry a real Audio Unit (Apple's AULowpass, when this machine has it), tuned
  too. The wet of each aux is measured by export, the project is saved, the process is killed.

  PROCESS B — opens the file. Same positions, same plugins under the same ids in the same order, same
  parameters, and the same wet at the export, aux by aux. Then ONE parameter of an Audio Unit is
  changed (of the built-in when there is no AU), the wet is measured, the project saved, the process
  killed.

  PROCESS C — opens the file again: the changed parameter and its wet are there.

Every instance is headless, WITH audio (the bridge reads the device's clock), `--no-recent`, and is
killed in a `finally`. Nothing is opened on screen.

    ./scenario_send_plugins_reopen.py /path/to/objekat.app [work directory]

Exit: 0 if every assertion passes, 1 as soon as one fails, 2 on bad usage.
"""

import json, os, shutil, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError
import bridge_scenario_common as B

if len(sys.argv) not in (2, 3):
    print(__doc__)
    sys.exit(2)
APP = sys.argv[1]
BIN = os.path.join(APP, "Contents", "MacOS", "objekat")
if not os.path.exists(BIN):
    print("not an app bundle: %s" % APP)
    sys.exit(2)
WORK = os.path.abspath(sys.argv[2]) if len(sys.argv) == 3 else tempfile.mkdtemp(prefix="objekat_send_reopen_")
os.makedirs(WORK, exist_ok=True)
SOCK = "/tmp/objekat_send_reopen_%d.sock" % os.getpid()
PROJ = os.path.join(WORK, "P", "project.objekat")
SR = B.SR
APPLE_AU = "aufx,lpas,appl"

T = B.Tally(ObjekatError)
step, check = T.step, T.check
PROCS = []


def launch(tag):
    if os.path.exists(SOCK):
        os.remove(SOCK)
    log = open(os.path.join(WORK, "app_%s.log" % tag), "w")
    proc = subprocess.Popen([BIN, "--headless", "--api", "--no-recent", "--language=en", "--socket=" + SOCK],
                            stdout=subprocess.DEVNULL, stderr=log)
    PROCS.append(proc)
    for _ in range(160):
        if os.path.exists(SOCK):
            return proc
        time.sleep(0.25)
    proc.kill()
    raise RuntimeError("the app did not open its socket: " + SOCK)


def stop(proc):
    """KILLED, not asked to quit: nothing the app does on the way out may help the file."""
    try:
        proc.kill()
        proc.wait(timeout=20)
    except Exception:
        pass
    if os.path.exists(SOCK):
        os.remove(SOCK)


def settle(c, long=False):
    c.send("wait_idle")
    time.sleep(1.2 if long else 0.3)
    c.send("wait_idle")


def wake(c):
    """Plays a moment: the playback graph is only allocated at the first play, and until then a hosted
    Audio Unit sits at 44.1 kHz. Apple's AULowpass derives the RANGE of its cutoff from its sample rate,
    so the same cutoff in Hz reads as another normalised value before and after (measured: 228 Hz is
    0.01000 before the first play and 0.00459 after, at 96 kHz; the unit's state — the Hz — does not
    move, on a send as in an object's chain). The parameters are set and compared with the graph awake."""
    c.send("transport.play", {})
    time.sleep(0.6)
    c.send("transport.stop")
    settle(c)


def render(c, name):
    c.send("wait_idle")
    path = os.path.join(WORK, name)
    r = c.send("export.run", {"format": "wav", "sample_rate": SR, "dithering": False, "start": 0.0, "end": 3.0, "path": path})
    c.send("job.wait", {"id": r["job_id"], "timeout_ms": 180000})
    return B.read_wav(path)[0]


def sub(a, b):
    return [a[i] - b[i] for i in range(min(len(a), len(b)))]


def wets(c, tag, auxes):
    """The wet each aux receives, in dBFS RMS over [1 s, 2 s]: the export, minus the export with that
    aux muted. Also returns the full export."""
    on = render(c, tag + "_on.wav")
    out = []
    for i, a in enumerate(auxes):
        c.send("object.set_mute", {"ids": [a], "muted": True})
        settle(c)
        off = render(c, "%s_off%d.wav" % (tag, i))
        c.send("object.set_mute", {"ids": [a], "muted": False})
        settle(c)
        out.append(B.db(B.rms(sub(on, off), 1.0, 2.0)))
    return out, on


def describe(c, cast):
    """What must survive: per sender, the send's position and its plugins (id, name, parameters)."""
    rows = []
    for x, a in cast:
        r = [s for s in c.send("send.list", {"id": x})["sends"] if s["aux"] == a]
        row = r[0] if r else {}
        plugins = []
        for p in row.get("plugins", []):
            prm = c.send("plugin.get_params", {"plugin": p["id"]}).get("params", [])
            shown = [q.get("display") for q in prm]
            try:                                   # an AU / VST only: a built-in has no opaque state to read
                st = c.send("plugin.get_state", {"plugin": p["id"]})
            except ObjekatError:
                st = {}
            plugins.append({"id": p["id"], "name": p.get("name"), "format": p.get("format"), "enabled": p.get("enabled"),
                            "params": [round(q["value"], 5) for q in prm], "shown": shown, "state_size": st.get("size")})
        rows.append({"position": row.get("position"), "index": row.get("index"), "level_db": row.get("level_db"),
                     "plugins": plugins})
    return rows


def audits(c, label):
    r = c.send("debug.plugin_id_audit")
    check(label + ": plugin_id_audit count 0", r.get("count") == 0 and r.get("engine_foreign_refusals", 0) == 0, r)
    settle(c)
    m = c.send("debug.send_marker_audit")
    check(label + ": send_marker_audit (model + engine) ok", m.get("ok") is True, m.get("violations"))
    check(label + ": no send plugin is linked", m.get("linked_send_plugins") == [], m.get("linked_send_plugins"))
    return m


def au_cutoff_index(c, pid):
    for prm in c.send("plugin.get_params", {"plugin": pid}).get("params", []):
        if "cutoff" in prm["name"].lower():
            return prm["index"]
    return None


POSITIONS = (("post_fader", {"position": "post_fader"}, 300.0, None),
             ("pre_fader", {"position": "pre_fader"}, 500.0, 0.01),
             ("input", {"position": "input"}, 800.0, None),
             ("chain", {"position": "chain", "index": 1}, 1200.0, 0.02))

rc = 1
try:
    B.make_sine(os.path.join(WORK, "sine1k.wav"), seconds=4.0, hz=1000.0, dbfs=-12.0)

    # ------------------------------------------------------------------------------------ process A
    print("\n--- A  build, measure, save — then the process is KILLED")
    pa = launch("A")
    with ObjekatClient(SOCK) as c:
        B.require_audio(c)
        c.send("app.set_dialog_policy", {"policy": "assume_yes"})
        pid_a = c.send("app.info").get("pid")
        av = c.send("plugin.list_available", {})
        av = av.get("plugins", av) if isinstance(av, dict) else av
        has_au = any(p.get("identifier") == APPLE_AU for p in av)
        print("       Apple AULowpass on this machine: %s" % ("yes" if has_au else "NO — the Audio Unit half is skipped"))
        c.send("project.new")
        os.makedirs(os.path.dirname(PROJ), exist_ok=True)
        c.send("project.save_as", {"path": PROJ})
        cast, changed = [], None
        woke = False
        for i, (name, prm, hz, au) in enumerate(POSITIONS):
            x = c.send("object.add", {"path": os.path.join(WORK, "sine1k.wav"), "lane": i, "start": 0.0})["id"]
            a = c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": 5 + i})["id"]
            c.send("object.set_gain", {"ids": [x], "db": -10.0})          # post-fader hears it, the three others do not
            if not woke:
                wake(c)
                woke = True
            if name == "chain":
                t = c.send("plugin.add", {"host": x, "identifier": "lowpass"})["plugin"]["id"]
                settle(c)
                c.send("plugin.set_param", {"plugin": t, "index": 0, "value": 15000.0})
            c.send("send.create", {"id": x, "aux": a, "position": "post_fader"})
            c.send("send.set_level", {"id": x, "aux": a, "db": -3.0})
            c.send("send.set_position", dict({"id": x, "aux": a}, **prm))
            settle(c)
            h = [s for s in c.send("send.list", {"id": x})["sends"] if s["aux"] == a][0].get("chain_host")
            lp = step("A %s: a built-in Low Pass on the send, tuned to %d Hz" % (name, hz),
                      lambda: c.send("plugin.add", {"host": h, "identifier": "lowpass"}))["plugin"]["id"]
            settle(c)
            c.send("plugin.set_param", {"plugin": lp, "index": 0, "value": hz})
            if au is not None and has_au:
                r = step("A %s: Apple AULowpass on the send too" % name, lambda: c.send("plugin.add", {"host": h, "identifier": APPLE_AU}))
                aid = r["plugin"]["id"]
                settle(c, long=True)
                k = au_cutoff_index(c, aid)
                c.send("plugin.set_param", {"plugin": aid, "index": k, "value": au})
                if changed is None:
                    changed = (i, aid, k, "au")
            elif changed is None and not has_au and name == "pre_fader":
                changed = (i, lp, 0, "builtin")
            settle(c)
            cast.append((x, a))
        auxes = [a for _, a in cast]
        audits(c, "A")
        desc_a = describe(c, cast)
        for (name, _, _, _), d in zip(POSITIONS, desc_a):
            print("       A %-10s position %s/%s, plugins %s" % (name, d["position"], d["index"],
                  [(p["name"], p["params"][:4], p["shown"][:4]) for p in d["plugins"]]))
        check("A: the four sends are at the four positions",
              [d["position"] for d in desc_a] == [p[0] for p in POSITIONS], [d["position"] for d in desc_a])
        c.send("project.save")
        saved = json.load(open(PROJ))
        check("A: the file is format 26", saved.get("version") == 26, saved.get("version"))
        wet_a, on_a = wets(c, "A", auxes)
        print("       A wet per aux (dBFS, 1 kHz tone at -12): %s" % " / ".join("%.3f" % v for v in wet_a))
        check("A: the four wets are four different figures (each send is heard for what it carries)",
              len({round(v, 1) for v in wet_a}) == 4, wet_a)
    stop(pa)
    check("A: the process is gone", pa.poll() is not None)

    # ------------------------------------------------------------------------------------ process B
    print("\n--- B  a NEW process opens the file")
    pb = launch("B")
    with ObjekatClient(SOCK) as c:
        B.require_audio(c)
        c.send("app.set_dialog_policy", {"policy": "assume_yes"})
        pid_b = c.send("app.info").get("pid")
        check("B: another process (pid %s, was %s)" % (pid_b, pid_a), pb.pid != pa.pid and (pid_b is None or pid_b != pid_a), (pid_a, pid_b))
        step("B: project.open", lambda: c.send("project.open", {"path": PROJ}))
        settle(c, long=True)
        wake(c)
        settle(c, long=True)
        audits(c, "B")
        desc_b = describe(c, cast)
        for (name, _, _, _), da, db_ in zip(POSITIONS, desc_a, desc_b):
            check("B %s: same position (%s/%s)" % (name, da["position"], da["index"]),
                  (db_["position"], db_["index"]) == (da["position"], da["index"]), (db_["position"], db_["index"]))
            check("B %s: same send level" % name, db_["level_db"] == da["level_db"], (db_["level_db"], da["level_db"]))
            check("B %s: same plugins, same ids, same order (%d)" % (name, len(da["plugins"])),
                  [(p["id"], p["name"], p["format"], p["enabled"]) for p in db_["plugins"]]
                  == [(p["id"], p["name"], p["format"], p["enabled"]) for p in da["plugins"]], db_["plugins"])
            for p0, p1 in zip(da["plugins"], db_["plugins"]):
                same = len(p0["params"]) == len(p1["params"]) and all(abs(u - v) <= 1e-4 * max(1.0, abs(u)) for u, v in zip(p0["params"], p1["params"]))
                check("B %s: %s (%s): the live parameters are the saved ones %s" % (name, p0["name"], p0["format"], p0["shown"][:4]),
                      same and p0["shown"] == p1["shown"], (p0["params"], p1["params"], p1["shown"]))
                if p0["format"] == "AudioUnit":
                    check("B %s: %s: the hosted unit gives its state (%s bytes, was %s)" % (name, p0["name"], p1["state_size"], p0["state_size"]),
                          bool(p1["state_size"]) and p1["state_size"] == p0["state_size"], (p0["state_size"], p1["state_size"]))
        wet_b, on_b = wets(c, "B", auxes)
        print("       B wet per aux: %s" % " / ".join("%.3f" % v for v in wet_b))
        print("       B - A:         %s dB;  whole export, max |B - A| = %.2e" % (" / ".join("%+.3f" % (v - u) for u, v in zip(wet_a, wet_b)),
                                                                                  max(abs(v) for v in sub(on_a, on_b))))
        for (name, _, _, _), u, v in zip(POSITIONS, wet_a, wet_b):
            check("B %s: the SAME wet as before the kill (0.05 dB)" % name, abs(u - v) <= 0.05, (u, v))
        check("B: the whole export is the one of process A (max difference under -80 dBFS)",
              max(abs(v) for v in sub(on_a, on_b)) <= 1e-4, max(abs(v) for v in sub(on_a, on_b)))

        # one parameter changed, saved by THIS process
        wet_b2, kind = None, None
        if changed is not None:
            i, plug, k, kind = changed
            new = 0.003 if kind == "au" else 250.0
            c.send("plugin.set_param", {"plugin": plug, "index": k, "value": new})
            settle(c)
            shown = [q for q in c.send("plugin.get_params", {"plugin": plug})["params"] if q["index"] == k][0]
            wet_b2, _ = wets(c, "B2", auxes)
            print("       B: %s parameter of the %s send changed (now shows %s): its wet %.3f -> %.3f dBFS"
                  % ("the Audio Unit's" if kind == "au" else "the built-in's", POSITIONS[i][0], shown.get("display"), wet_b[i], wet_b2[i]))
            check("B: the change is heard (more than 3 dB)", abs(wet_b2[i] - wet_b[i]) > 3.0, (wet_b[i], wet_b2[i]))
            desc_b2 = describe(c, cast)
            c.send("project.save")
    stop(pb)
    check("B: the process is gone", pb.poll() is not None)

    # ------------------------------------------------------------------------------------ process C
    if changed is not None and wet_b2 is not None:
        print("\n--- C  a third process: the parameter changed in B is in the file")
        pc = launch("C")
        with ObjekatClient(SOCK) as c:
            B.require_audio(c)
            c.send("app.set_dialog_policy", {"policy": "assume_yes"})
            step("C: project.open", lambda: c.send("project.open", {"path": PROJ}))
            settle(c, long=True)
            wake(c)
            settle(c, long=True)
            audits(c, "C")
            desc_c = describe(c, cast)
            i, plug, k, kind = changed
            p_b = [p for p in desc_b2[i]["plugins"] if p["id"] == plug][0]
            p_c = [p for p in desc_c[i]["plugins"] if p["id"] == plug]
            check("C: the plugin is there under its id", len(p_c) == 1, desc_c[i]["plugins"])
            if p_c:
                check("C: its parameter is the one set in B (%s, shown %s)" % (p_b["params"][k], p_b["shown"][k]),
                      abs(p_c[0]["params"][k] - p_b["params"][k]) <= 1e-4 * max(1.0, abs(p_b["params"][k])) and p_c[0]["shown"][k] == p_b["shown"][k],
                      (p_c[0]["params"], p_c[0]["shown"], p_b["params"]))
            wet_c, _ = wets(c, "C", auxes)
            print("       C wet per aux: %s" % " / ".join("%.3f" % v for v in wet_c))
            for (name, _, _, _), u, v in zip(POSITIONS, wet_b2, wet_c):
                check("C %s: the wet measured in B after the change (0.05 dB)" % name, abs(u - v) <= 0.05, (u, v))
        stop(pc)

    T.finish()
    rc = 1 if T.ko else 0
finally:
    for p in PROCS:
        if p.poll() is None:
            p.kill()
    if os.path.exists(SOCK):
        os.remove(SOCK)
    if len(sys.argv) != 3 and rc == 0:
        shutil.rmtree(WORK, ignore_errors=True)
sys.exit(rc)

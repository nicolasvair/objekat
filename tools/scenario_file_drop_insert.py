#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Files let go BETWEEN two lanes are INSERTED there (`EditViewModel.commitFileDrop`) — asserted headless
through `debug.file_drop` (DEBUG build only), the very function the timeline's drop calls once the files are
read. Whatever carries the files (the Finder, the library tab) arrives at the same `handleDrop`.

    ./scenario_file_drop_insert.py /path/to/objekat.app

The hover's line, ghost and HUD are drawn from the same plan (`fileDropInsertionPlan`); they need a screen
and are not covered here — what is covered is what the RELEASE does.

Cases:
  F1  stacked, 2 files, insert_row = 1 on a0 b1 c2     -> new rows 1-2, old b, c on 3-4, a stays
  F2  that one undo point gives it all back; redo does it again
  F3  sequential (one lane, end to end), 2 files        -> ONE row (1), b, c on 2-3, starts chained
  F4  a FOLDER                                          -> ONE row, a group, b, c pushed by one
  F5  inside an open group (between its two children)   -> the files are children, the root does not move
  F6  nothing below (after the last lane)               -> insert null, the normal drop on `lane`
  F7  an instrument group's band                        -> refused, model and undo stack untouched
  F8  saved and reopened                                -> the same rows
  F9  an open consolidated object                       -> insert null, the normal drop
  F10 insert_row = 0 (above the first lane)             -> everything goes down

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

WORK = os.path.realpath(tempfile.mkdtemp(prefix="objk-filedrop-"))
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
    os.makedirs(os.path.dirname(path), exist_ok=True)
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
        self.sock = "/tmp/objk-fdrop-%d.sock" % os.getpid()
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

    def send(self, name, params=None):
        return self.c.send(name, params)

    def settle(self, ms=200):
        self.c.send("wait_idle", {"timeout_ms": 120000, "settle_ms": ms})

    def objects(self):
        return {o["id"]: o for o in self.c.send("object.list")["objects"]}

    def rows(self, ids):
        objs = self.objects()
        return [objs[i]["display_lane"] if i in objs else None for i in ids]

    def lanes(self, ids):
        objs = self.objects()
        return [objs[i]["lane"] if i in objs else None for i in ids]

    def depth(self):
        return self.c.send("perf.census")["undo_depth"]

    def state(self):
        return json.dumps(self.c.send("project.get_state"), sort_keys=True)

    def dialogs(self):
        return self.c.send("app.dialogs")["dialogs"]

    def fresh(self):
        self.send("project.new")
        self.send("project.set_snap", {"enabled": False})
        self.settle()

    def root3(self, wav):
        """a0 b1 c2 at the root, all starting at 0."""
        ids = [self.send("object.add", {"path": wav, "lane": l, "start": 0.0})["id"] for l in range(3)]
        self.settle()
        return ids


def drop(app, paths, **kw):
    params = {"paths": paths}
    params.update(kw)
    r = app.send("debug.file_drop", params)
    app.settle()
    return r


def main():
    app = App()
    try:
        w1 = tone("one.wav", 1.0)
        w2 = tone("two.wav", 2.0)
        w3 = tone("three.wav", 0.5)

        # ── F1 / F2 ───────────────────────────────────────────────────────────────────────────
        print("\n── F1 stacked, 2 files between row 0 and row 1 ──")
        app.fresh()
        a, b, c = app.root3(w1)
        depth0 = app.depth()
        before = app.state()
        r = drop(app, [w2, w3], mode="stacked", insert_row=1, start=1.5)
        placed = [p["id"] for p in r["placed"]]
        check("F1 not refused", r["refused"] is False)
        check("F1 insert reported: root, boundary 1, lane 1, 2 lanes",
              r["insert"] is not None and r["insert"]["group"] is None and r["insert"]["boundary"] == 1
              and r["insert"]["lane"] == 1 and r["insert"]["count"] == 2, str(r["insert"]))
        check("F1 the two files land on rows 1 and 2", app.rows(placed) == [1, 2], str(app.rows(placed)))
        check("F1 a stays on row 0, b and c go down by 2 (3, 4)", app.rows([a, b, c]) == [0, 3, 4],
              str(app.rows([a, b, c])))
        check("F1 the files start together at 1.5 (stacked)",
              all(abs(p["start"] - 1.5) < 1e-6 for p in r["placed"]), str(r["placed"]))
        check("F1 exactly ONE undo point", app.depth() == depth0 + 1, "%s -> %s" % (depth0, app.depth()))
        after = app.state()

        print("── F2 one undo gives it all back ──")
        app.send("edit.undo"); app.settle()
        check("F2 undo: a b c back on 0 1 2", app.rows([a, b, c]) == [0, 1, 2], str(app.rows([a, b, c])))
        check("F2 undo: the files are gone", all(p not in app.objects() for p in placed))
        check("F2 undo: the model is what it was", app.state() == before)
        app.send("edit.redo"); app.settle()
        check("F2 redo: inserted again", app.rows([a, b, c]) == [0, 3, 4] and len(app.objects()) == 5,
              str(app.rows([a, b, c])))

        # ── F8 saved and reopened ─────────────────────────────────────────────────────────────
        print("\n── F8 saved and reopened ──")
        proj = os.path.join(WORK, "proj", "p.objekat")
        os.makedirs(os.path.dirname(proj), exist_ok=True)
        app.send("project.save_as", {"path": proj}); app.settle()
        rows_before = sorted(o["display_lane"] for o in app.objects().values())
        app.send("project.open", {"path": proj}); app.settle()
        rows_after = sorted(o["display_lane"] for o in app.objects().values())
        check("F8 the same rows after reopening", rows_before == rows_after == [0, 1, 2, 3, 4],
              "%s / %s" % (rows_before, rows_after))

        # ── F3 sequential ─────────────────────────────────────────────────────────────────────
        print("\n── F3 sequential: ONE lane, end to end ──")
        app.fresh()
        a, b, c = app.root3(w1)
        r = drop(app, [w2, w3], mode="sequential", insert_row=1, start=1.0)
        placed = [p["id"] for p in r["placed"]]
        check("F3 count 1 lane", r["insert"] is not None and r["insert"]["count"] == 1, str(r["insert"]))
        check("F3 both files on row 1", app.rows(placed) == [1, 1], str(app.rows(placed)))
        starts = [p["start"] for p in r["placed"]]
        check("F3 end to end: 1.0 then 3.0 (the first lasts 2 s)",
              abs(starts[0] - 1.0) < 1e-6 and abs(starts[1] - 3.0) < 1e-6, str(starts))
        check("F3 b and c go down by ONE (2, 3)", app.rows([a, b, c]) == [0, 2, 3], str(app.rows([a, b, c])))

        # ── F4 a folder ───────────────────────────────────────────────────────────────────────
        print("\n── F4 a folder: ONE row ──")
        app.fresh()
        a, b, c = app.root3(w1)
        folder = os.path.join(WORK, "kit")
        tone("kit/k1.wav", 0.4); tone("kit/k2.wav", 0.6); tone("kit/k3.wav", 0.8)
        r = drop(app, [folder], mode="stacked", insert_row=1)
        placed = [p["id"] for p in r["placed"]]
        objs = app.objects()
        check("F4 one group laid down", len(placed) == 1 and objs[placed[0]]["kind"] == "group", str(r["placed"]))
        check("F4 count 1 lane", r["insert"] is not None and r["insert"]["count"] == 1, str(r["insert"]))
        check("F4 the group is on row 1, b and c go down by one", app.rows(placed + [a, b, c]) == [1, 0, 2, 3],
              str(app.rows(placed + [a, b, c])))
        # a folder AND two files: three entries, three lanes
        app.fresh()
        a, b, c = app.root3(w1)
        r = drop(app, [w2, folder, w3], mode="stacked", insert_row=1)
        check("F4 file + folder + file: 3 lanes", r["insert"] is not None and r["insert"]["count"] == 3
              and app.rows([p["id"] for p in r["placed"]]) == [1, 2, 3], str(r["insert"]))

        # ── F5 inside an open group ───────────────────────────────────────────────────────────
        print("\n── F5 inside an open group ──")
        app.fresh()
        g0 = app.send("object.add", {"path": w1, "lane": 0, "start": 0.0})["id"]
        g1 = app.send("object.add", {"path": w1, "lane": 1, "start": 0.0})["id"]
        g = app.send("group.create", {"ids": [g0, g1]})["id"]
        t = app.send("object.add", {"path": w1, "lane": 1, "start": 0.0})["id"]
        app.send("group.expand", {"id": g, "expanded": True}); app.settle()
        rows0 = app.rows([g, g0, g1, t])
        check("F5 setup: G 0, g0 1, g1 2, t on row 4 (after the drop row)", rows0 == [0, 1, 2, 4], str(rows0))
        t_lane = app.lanes([t])[0]
        r = drop(app, [w2, w3], mode="stacked", insert_row=2)
        placed = [p["id"] for p in r["placed"]]
        objs = app.objects()
        check("F5 insert in the group", r["insert"] is not None and r["insert"]["group"] == g
              and r["insert"]["lane"] == 1 and r["insert"]["count"] == 2, str(r["insert"]))
        check("F5 the files are CHILDREN of G", all(objs[p]["parent"] == g for p in placed), str([objs[p]["parent"] for p in placed]))
        check("F5 on rows 2 and 3, g0 stays on 1, g1 goes to 4", app.rows(placed + [g0, g1]) == [2, 3, 1, 4],
              str(app.rows(placed + [g0, g1])))
        check("F5 the root's t keeps its own lane (only its row follows the taller band)",
              app.lanes([t])[0] == t_lane, str(app.lanes([t])))

        # ── F6 nothing below ──────────────────────────────────────────────────────────────────
        print("\n── F6 nothing below: the normal drop ──")
        app.fresh()
        a, b, c = app.root3(w1)
        depth0 = app.depth()
        r = drop(app, [w2], insert_row=3, lane=5, start=2.0)
        placed = [p["id"] for p in r["placed"]]
        check("F6 insert is null", r["insert"] is None, str(r["insert"]))
        check("F6 normal drop on the lane asked (5); the others untouched",
              app.rows(placed) == [5] and app.rows([a, b, c]) == [0, 1, 2], str(app.rows(placed + [a, b, c])))
        check("F6 one undo point", app.depth() == depth0 + 1)

        # ── F10 above the first lane ──────────────────────────────────────────────────────────
        print("\n── F10 above the first lane ──")
        app.fresh()
        a, b, c = app.root3(w1)
        r = drop(app, [w2], insert_row=0)
        placed = [p["id"] for p in r["placed"]]
        check("F10 the file on row 0, everything goes down", app.rows(placed + [a, b, c]) == [0, 1, 2, 3],
              str(app.rows(placed + [a, b, c])))

        # ── F7 an instrument group refuses ────────────────────────────────────────────────────
        print("\n── F7 an instrument group takes no audio ──")
        app.fresh()
        insts = app.send("plugin.list_available", {"instruments_only": True})["plugins"]
        dls = next(p for p in insts if p["name"] == "DLSMusicDevice")
        m0 = app.send("midi.create_clip", {"start": 0, "end": 4, "lane": 0})["id"]
        m1 = app.send("midi.create_clip", {"start": 0, "end": 4, "lane": 1})["id"]
        h = app.send("group.create", {"ids": [m0, m1]})["id"]
        app.send("instrument.set", {"id": h, "identifier": dls["identifier"], "format": dls["format"]})
        app.send("group.expand", {"id": h, "expanded": True}); app.settle()
        before, depth0, dlg0 = app.state(), app.depth(), len(app.dialogs())
        code = reason = None
        try:
            drop(app, [w1], insert_row=2)      # between the host's two children
        except ObjekatError as e:
            code = e.code
            reason = e.details.get("reason") if isinstance(e.details, dict) else None
        check("F7 refused: invalid_state, reason audioChild (the command bus turns the refusal into an error)",
              code == "invalid_state" and reason == "audioChild", "%r %r" % (code, reason))
        check("F7 model unchanged", app.state() == before)
        check("F7 undo stack unchanged", app.depth() == depth0, "%s -> %s" % (depth0, app.depth()))
        check("F7 the refusal is journalled", len(app.dialogs()) == dlg0 + 1, "%d -> %d" % (dlg0, len(app.dialogs())))

        # ── F9 an open consolidated object ────────────────────────────────────────────────────
        print("\n── F9 a consolidated object open: the normal drop ──")
        app.fresh()
        x0 = app.send("object.add", {"path": w1, "lane": 0, "start": 0.0})["id"]
        x1 = app.send("object.add", {"path": w1, "lane": 1, "start": 0.0})["id"]
        gg = app.send("group.create", {"ids": [x0, x1]})["id"]
        app.send("project.save_as", {"path": os.path.join(WORK, "cons", "p.objekat")}); app.settle()
        mk = app.send("consolidate.make", {"id": gg})
        app.send("job.wait", {"id": mk["job_id"], "timeout_ms": 60000}); app.settle()
        defs = app.send("consolidate.list")["definitions"]
        placement = defs[0]["placements"][0]
        t1 = app.send("object.add", {"path": w1, "lane": 3, "start": 0.0})["id"]
        app.settle()
        app.send("consolidate.edit_begin", {"placement": placement}); app.settle()
        r = drop(app, [w2], insert_row=1, lane=7)
        check("F9 insert is null while a consolidated object is open", r["insert"] is None, str(r["insert"]))
        app.send("consolidate.edit_commit", {"mode": "propagate"}); app.settle()
        r = drop(app, [w2], insert_row=1, lane=7)
        check("F9 control: the same drop, the session closed, INSERTS", r["insert"] is not None, str(r["insert"]))

        print("\n%d/%d OK" % (TOTAL[0] - len(FAILS), TOTAL[0]))
    except Exception:
        traceback.print_exc()
        FAILS.append("exception")
    finally:
        app.close()
    sys.exit(1 if FAILS else 0)


main()

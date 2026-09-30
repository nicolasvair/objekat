#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The `regions` scope of the export: one file per ticked region, named after it.

What this asserts, with no screen:

  • the LIST (`export.regions`): every region of the marker band in start-time order — a hidden row
    included, flagged — with its tick, the file it would write and its warnings (an empty name, a
    duplicate). A region renamed or removed shows at once, which is what the picker relies on;
  • the TICKS (`export.set_regions`): select / deselect / only / all / none / invert, and that an
    unticked region does not take part in the naming;
  • the RENDER: for the ticked regions only, one file each, named as announced ("Verse.wav",
    "Verse (2).wav", "Region 3.wav"), each as long as its region, and — re-read as 24-bit — with
    signal where the master has signal and silence where it has none;
  • the BATCH: progress that only moves forward, per-region results, the overwrite question asked
    ONCE, `regions` given explicitly leaving the ticks alone, and a cancel that stops the batch
    cleanly (the region under way interrupted, the next ones never started, no working file left);
  • a script opens no window: `CGWindowListCopyWindowInfo` on the pid is empty.

    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --language=en \\
        --socket=/tmp/o.sock
    ./scenario_export_regions.py /tmp/o.sock /tmp/trial/project.objekat

`--language=en` matters: the fallback name of an unnamed region ("Region 3") is localised.

Exit: 0 if everything passes, 1 as soon as one assertion fails.
"""

import sys, os, json, time, wave, array, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

if len(sys.argv) != 3:
    print(__doc__)
    sys.exit(2)

SOCK = sys.argv[1]
PROJ = sys.argv[2]
BIP = os.path.join(HERE, "fixtures", "bip.wav")
OUTDIR = os.path.join(os.path.dirname(PROJ), "regions-out")

fails = []


def check(label, ok, detail=""):
    if ok:
        print("ok    " + label)
    else:
        fails.append(label)
        print("FAIL  %s  %s" % (label, detail))


def pid_for_socket(sock_path):
    try:
        out = subprocess.check_output(["lsof", "-t", sock_path], text=True,
                                      stderr=subprocess.DEVNULL)
        pids = [int(p) for p in out.split()]
        return pids[0] if pids else None
    except Exception:
        return None


def window_count_for_pid(pid):
    try:
        import Quartz
    except ImportError:
        return None
    info = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionAll, Quartz.kCGNullWindowID)
    return sum(1 for w in info if w.get("kCGWindowOwnerPID") == pid)


def wav_samples(path):
    """(samples as floats in -1…1, channels, frame rate) of a 16- or 24-bit WAV. A 24-bit file is
    read by hand — `wave` hands the bytes over as they are (the CLI's own 24-bit caution)."""
    with wave.open(path, "rb") as w:
        sw, ch, rate, raw = w.getsampwidth(), w.getnchannels(), w.getframerate(), w.readframes(w.getnframes())
    if sw == 2:
        a = array.array("h"); a.frombytes(raw)
        return [v / 32768.0 for v in a], ch, rate
    if sw == 3:
        return [int.from_bytes(raw[i:i + 3], "little", signed=True) / 8388608.0
                for i in range(0, len(raw) - 2, 3)], ch, rate
    raise RuntimeError("unexpected sample width: %d" % sw)


def wav_stats(path):
    """(duration s, peak, rms) of a WAV."""
    s, ch, rate = wav_samples(path)
    frames = len(s) // ch
    peak = max((abs(v) for v in s), default=0.0)
    rms = (sum(v * v for v in s) / len(s)) ** 0.5 if s else 0.0
    return frames / float(rate), peak, rms


with ObjekatClient(SOCK) as c:
    def cmd(_cmd_name, **params):
        return c.send(_cmd_name, params or None)

    def fails_with(code, _cmd_name, **params):
        try:
            c.send(_cmd_name, params or None)
            return False, "it answered"
        except ObjekatError as e:
            return e.code == code, e.code

    info = cmd("app.info")
    check("--no-recent honoured", info.get("records_recent_projects") is False,
          str(info.get("records_recent_projects")))
    cmd("app.set_dialog_policy", policy="assume_yes")
    cmd("project.new")
    os.makedirs(os.path.dirname(PROJ), exist_ok=True)
    cmd("project.save_as", path=PROJ)
    os.makedirs(OUTDIR, exist_ok=True)
    for f in os.listdir(OUTDIR):
        os.remove(os.path.join(OUTDIR, f))

    # ── material: three bips, each 0.4 s, inside regions 1, 2 and 3 ────────────────────────────
    for lane, start in enumerate([1.0, 3.0, 5.0]):
        cmd("object.add", path=BIP, lane=lane, start=start)

    # ── no region yet ──────────────────────────────────────────────────────────────────────────
    r0 = cmd("export.regions", format="wav", folder=OUTDIR)
    check("no region, empty list", r0["count"] == 0 and r0["regions"] == [], r0)
    ok, detail = fails_with("invalid_state", "export.run", scope="regions", format="wav", folder=OUTDIR)
    check("export with no region is refused", ok, detail)

    # ── regions: duplicate name, empty name, an illegal character, a hidden row ─────────────────
    lane_a = cmd("marker_lane.create", name="Takes")["lane"]
    lane_h = cmd("marker_lane.create", name="Hidden")["lane"]
    cmd("marker_lane.set_visible", lane=lane_h, visible=False)
    R1 = cmd("marker.add", lane=lane_a, at=0.5, duration=1.4, name="Verse")["marker"]
    R2 = cmd("marker.add", lane=lane_a, at=2.5, duration=1.4, name="Verse")["marker"]
    R3 = cmd("marker.add", lane=lane_a, at=4.5, duration=1.4, name="")["marker"]
    R4 = cmd("marker.add", lane=lane_a, at=7.0, duration=1.0, name="Skip/me")["marker"]
    R5 = cmd("marker.add", lane=lane_h, at=9.0, duration=1.0, name="Hidden one")["marker"]
    cmd("marker.add", lane=lane_a, at=6.0, name="a point, not a region")   # must not be listed

    lst = cmd("export.regions", format="wav", folder=OUTDIR)
    regs = lst["regions"]
    check("five regions, the point left out", lst["count"] == 5 and len(regs) == 5, lst["count"])
    check("listed in start-time order",
          [r["id"] for r in regs] == [R1, R2, R3, R4, R5], [r["name"] for r in regs])
    check("all ticked the first time", all(r["selected"] for r in regs) and lst["selected_count"] == 5)
    check("a hidden row's region is listed and flagged",
          regs[4]["lane_visible"] is False and regs[0]["lane_visible"] is True
          and regs[4]["lane_name"] == "Hidden", regs[4])
    check("each region carries its span",
          abs(regs[0]["start"] - 0.5) < 1e-9 and abs(regs[0]["end"] - 1.9) < 1e-9
          and abs(regs[0]["duration"] - 1.4) < 1e-9, regs[0])
    names = [r["file_name"] for r in regs]
    check("file names: the duplicate is numbered, the empty one falls back, / is stripped",
          names == ["Verse.wav", "Verse (2).wav", "Region 3.wav", "Skipme.wav", "Hidden one.wav"], names)
    check("warnings: duplicate and empty name",
          "duplicate_name" in regs[1]["warnings"] and "empty_name" in regs[2]["warnings"]
          and regs[0]["warnings"] == [], [r["warnings"] for r in regs])

    # ── ticks ──────────────────────────────────────────────────────────────────────────────────
    s = cmd("export.set_regions", action="deselect", regions=[R4, R5])
    check("deselect two", s["selected_count"] == 3 and set(s["selected"]) == {R1, R2, R3}, s)
    regs = cmd("export.regions", format="wav", folder=OUTDIR)["regions"]
    check("an unticked region writes no file", regs[3]["file_name"] is None and regs[4]["file_name"] is None)
    check("the others keep their names",
          [r["file_name"] for r in regs[:3]] == ["Verse.wav", "Verse (2).wav", "Region 3.wav"])

    # Names are made unique among the TICKED regions only: untick the first "Verse" and the second
    # becomes "Verse" — a file that will not be written cannot collide.
    cmd("export.set_regions", action="deselect", regions=[R1])
    regs = cmd("export.regions", format="wav", folder=OUTDIR)["regions"]
    check("unticking one frees its name", regs[1]["file_name"] == "Verse.wav"
          and "duplicate_name" not in regs[1]["warnings"], regs[1])
    cmd("export.set_regions", action="select", regions=[R1])

    s = cmd("export.set_regions", action="none")
    check("select none", s["selected_count"] == 0 and s["selected"] == [], s)
    ok, detail = fails_with("invalid_state", "export.run", scope="regions", format="wav", folder=OUTDIR)
    check("nothing ticked: the export is refused", ok, detail)
    s = cmd("export.set_regions", action="invert")
    check("invert from none selects all", s["selected_count"] == 5)
    s = cmd("export.set_regions", action="only", regions=[R1, R2, R3])
    check("only: exactly these", set(s["selected"]) == {R1, R2, R3} and s["selected_count"] == 3, s)
    s = cmd("export.set_regions", action="all")
    check("select all", s["selected_count"] == 5)
    cmd("export.set_regions", action="only", regions=[R1, R2, R3])
    ok, detail = fails_with("not_found", "export.set_regions", action="select",
                            regions=["00000000-0000-0000-0000-000000000000"])
    check("an unknown region is refused", ok, detail)
    ok, detail = fails_with("bad_params", "export.set_regions", action="sideways")
    check("an unknown action is refused", ok, detail)

    # ── live: a region renamed, added, removed shows at once ───────────────────────────────────
    cmd("marker.rename", lane=lane_a, marker=R3, name="Outro")
    regs = cmd("export.regions", format="wav", folder=OUTDIR)["regions"]
    check("a renamed region is renamed in the list",
          regs[2]["name"] == "Outro" and regs[2]["file_name"] == "Outro.wav", regs[2])
    cmd("marker.rename", lane=lane_a, marker=R3, name="")
    extra = cmd("marker.add", lane=lane_a, at=20.0, duration=1.0, name="Late")["marker"]
    lst = cmd("export.regions", format="wav", folder=OUTDIR)
    late = [r for r in lst["regions"] if r["id"] == extra]
    check("a region added later is listed, and ticked by default",
          lst["count"] == 6 and late and late[0]["selected"] is True, late)
    cmd("marker.remove", lane=lane_a, marker=extra)
    lst = cmd("export.regions", format="wav", folder=OUTDIR)
    check("a removed region is gone", lst["count"] == 5 and lst["selected_count"] == 3, lst["count"])

    # ── refusals that do not depend on the render ──────────────────────────────────────────────
    ok, detail = fails_with("bad_params", "export.run", scope="regions", format="wav",
                            folder=OUTDIR, path=os.path.join(OUTDIR, "x.wav"))
    check("'path' is refused in this scope", ok, detail)
    ok, detail = fails_with("bad_params", "export.run", scope="regions", format="wav",
                            folder=OUTDIR, start=0.0, end=1.0)
    check("'start'/'end' are refused in this scope", ok, detail)
    ok, detail = fails_with("bad_params", "export.run", scope="regions", range="inout",
                            format="wav", folder=OUTDIR)
    check("'scope' and 'range' may not disagree", ok, detail)
    ok, detail = fails_with("not_found", "export.run", scope="regions", format="wav", folder=OUTDIR,
                            regions=["00000000-0000-0000-0000-000000000000"])
    check("an unknown region id is refused", ok, detail)
    ok, detail = fails_with("invalid_state", "export.run", scope="regions", format="wav",
                            folder=os.path.join(OUTDIR, "nope"))
    check("a missing folder is refused", ok, detail)

    # ── the render, for the three ticked regions ───────────────────────────────────────────────
    run = cmd("export.run", scope="regions", format="wav", sample_rate=44100, bit_depth=24,
              folder=OUTDIR)
    check("the answer names the files to come",
          [r["file"] for r in run["regions"]] == ["Verse.wav", "Verse (2).wav", "Region 3.wav"]
          and os.path.realpath(run["destination"]) == os.path.realpath(OUTDIR), run)

    seen, phases = [], []
    deadline = time.time() + 120
    while time.time() < deadline:
        st = cmd("export.status")
        b = st.get("batch")
        if b:
            seen.append(b["current"])
            phases.append(b["progress"])
        if not st.get("running") and not (b and b["active"]):
            break
        time.sleep(0.02)
    cmd("job.wait", id=run["job_id"], timeout_ms=120000)
    check("the batch's current region only moves forward", all(y >= x for x, y in zip(seen, seen[1:])), seen)
    check("the batch's progress only moves forward", all(y >= x - 1e-9 for x, y in zip(phases, phases[1:])), phases)

    st = cmd("export.status")
    b = st.get("batch")
    check("status carries the batch", b is not None and b["total"] == 3 and b["active"] is False, b)
    check("three done, none failed",
          b and b["done"] == 3 and b["failed"] == 0 and b["current"] == 3
          and [r["status"] for r in b["results"]] == ["done"] * 3, b and b["results"])
    check("the job finished", st.get("phase") == "finished", st.get("phase"))
    check("the panel was not opened by a script", st.get("panel_open") is False, st)

    files = sorted(os.listdir(OUTDIR))
    check("exactly the announced files, no working file left",
          files == ["Region 3.wav", "Verse (2).wav", "Verse.wav"], files)
    check("the unticked region wrote nothing", not os.path.exists(os.path.join(OUTDIR, "Skipme.wav")))

    for name in ["Verse.wav", "Verse (2).wav", "Region 3.wav"]:
        dur, peak, rms = wav_stats(os.path.join(OUTDIR, name))
        check("%s is as long as its region" % name, abs(dur - 1.4) < 0.02, dur)
        check("%s has the bip in it (24-bit re-read)" % name, peak > 0.001 and rms > 1e-4,
              "peak %.5f rms %.6f" % (peak, rms))

    # ── `regions` given explicitly: used as they are, the ticks left alone ─────────────────────
    before = cmd("export.regions", format="wav", folder=OUTDIR)
    run = cmd("export.run", scope="regions", format="wav", sample_rate=44100, bit_depth=24,
              folder=OUTDIR, regions=[R4])
    cmd("job.wait", id=run["job_id"], timeout_ms=60000)
    check("the explicit region was written", os.path.exists(os.path.join(OUTDIR, "Skipme.wav")))
    dur, peak, rms = wav_stats(os.path.join(OUTDIR, "Skipme.wav"))
    check("Skipme.wav is 1 s of silence", abs(dur - 1.0) < 0.02 and peak < 0.0001,
          "dur %.3f peak %.6f" % (dur, peak))
    after = cmd("export.regions", format="wav", folder=OUTDIR)
    check("the ticks were left alone",
          [r["selected"] for r in before["regions"]] == [r["selected"] for r in after["regions"]])
    check("an existing file shows as a warning",
          "file_exists" in after["regions"][0]["warnings"], after["regions"][0])
    os.remove(os.path.join(OUTDIR, "Skipme.wav"))

    # ── the overwrite question is asked ONCE for the whole batch, and 'no' touches nothing ─────
    mtimes = {f: os.path.getmtime(os.path.join(OUTDIR, f)) for f in os.listdir(OUTDIR)}
    cmd("app.set_dialog_policy", policy="assume_no")
    ok, detail = fails_with("engine_error", "export.run", scope="regions", format="wav",
                            sample_rate=44100, bit_depth=24, folder=OUTDIR)
    check("overwrite refused: the export does not start", ok, detail)
    check("and no file was touched",
          mtimes == {f: os.path.getmtime(os.path.join(OUTDIR, f)) for f in os.listdir(OUTDIR)})
    cmd("app.set_dialog_policy", policy="assume_yes")
    time.sleep(1.1)
    run = cmd("export.run", scope="regions", format="wav", sample_rate=44100, bit_depth=24, folder=OUTDIR)
    cmd("job.wait", id=run["job_id"], timeout_ms=60000)
    newer = {f: os.path.getmtime(os.path.join(OUTDIR, f)) for f in os.listdir(OUTDIR)}
    check("overwrite accepted: the files are replaced",
          all(newer[f] > mtimes[f] for f in mtimes), {f: newer[f] - mtimes[f] for f in mtimes})

    # ── cancel: the region under way is interrupted, the next ones never start ─────────────────
    # Long regions (600 s of mostly silence) so the render outlasts the round trip of the cancel.
    L1 = cmd("marker.add", lane=lane_a, at=30.0, duration=600.0, name="Long A")["marker"]
    L2 = cmd("marker.add", lane=lane_a, at=640.0, duration=600.0, name="Long B")["marker"]
    L3 = cmd("marker.add", lane=lane_a, at=1250.0, duration=600.0, name="Long C")["marker"]
    run = cmd("export.run", scope="regions", format="wav", sample_rate=44100, bit_depth=24,
              folder=OUTDIR, regions=[L1, L2, L3])
    deadline = time.time() + 30
    while time.time() < deadline:
        if cmd("export.status").get("phase") == "rendering":
            break
        time.sleep(0.02)
    cmd("export.cancel")
    cmd("job.wait", id=run["job_id"], timeout_ms=120000)
    st = cmd("export.status")
    b = st.get("batch") or {}
    statuses = [r["status"] for r in b.get("results", [])]
    check("cancel: the batch records the request", b.get("cancel_requested") is True, b)
    check("cancel: the last region never started", statuses and statuses[-1] == "cancelled", statuses)
    check("cancel: nothing is left running", st.get("running") is False and b.get("active") is False, st)
    leftovers = [f for f in os.listdir(OUTDIR) if f.startswith(".objekat-export") or f.startswith("Long")]
    check("cancel: no working file and no half-written region left", leftovers == [], leftovers)
    ok, detail = fails_with("invalid_state", "export.cancel")
    check("cancel with nothing running is refused", ok, detail)

    # ── a script opens no window ───────────────────────────────────────────────────────────────
    pid = pid_for_socket(SOCK)
    wins = window_count_for_pid(pid) if pid else None
    if wins is None:
        print("..    window check skipped (no Quartz, or no pid)")
    else:
        check("no window on the headless pid", wins == 0, wins)

print("")
if fails:
    print("%d FAILURE(S):" % len(fails))
    for f in fails:
        print("  - " + f)
    sys.exit(1)
print("ALL PASS")
sys.exit(0)

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Opening a project must not write ITS waveform caches into the PREVIOUS project's folder.

Found on 17 October 2026 in a real folder: `TRIO CABEZONIA - COPY/waveforms/` held the `.wfc` of
the sounds of `LOUIEGITES - EP 4`, written two seconds BEFORE the same files landed in EP 4's own
folder. The cause: a load replaces `items` first and `projectURL` only once it is over, so for
the whole load the cache's folder is still the OLD project's while `referencedPaths` already
names the NEW project's sounds — every peak computed during a breath of the load (the Canvas
draws the new blocks and asks for them) was written into the wrong folder.

Two instances, both in UI MODE (headless has no Canvas, so nothing would ever be computed and
the scenario would pass for the wrong reason; @see scenario_waveform_cache.py):

  1. the first builds project A (one sound) and project B (fresh sounds + enough Apple Audio Units (AUMatrixReverb) that its
     load has a long plugins phase), saves both and quits;
  2. the second — an EMPTY memory cache, so B's sounds really have to be computed — opens A,
     then opens B asynchronously and lets the Canvas draw during the load.

Asserts: A's `waveforms/` holds A's `.wfc` and nothing else; B's holds B's.

    ./scenario_waveform_open_spill.py /path/to/objekat.app

Exit: 0 if every assertion passes, 1 otherwise, 2 on a usage / launch error.
"""

import os, shutil, subprocess, sys, tempfile, time, wave, array, math

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient

if len(sys.argv) != 2:
    print(__doc__)
    sys.exit(2)

APP = sys.argv[1]
BIN = os.path.join(APP, "Contents", "MacOS", "objekat")
SOCK = "/tmp/o-spill.sock"
B_SOUNDS = 8           # distinct files in B, never seen by the second instance
B_OBJECTS = 10         # objects of B carrying plugins
B_PLUGINS_EACH = 15    # plugins per object: the plugins phase is where the breaths happen

fails = []


def check(label, ok, detail=""):
    print(("ok    " if ok else "FAIL  ") + label + ("" if ok else "  " + str(detail)))
    if not ok:
        fails.append(label)


def make_wav(path, seconds, freq, rate=48000):
    n = int(seconds * rate)
    data = array.array("h", (int(9000 * math.sin(2 * math.pi * freq * i / rate)) for i in range(n)))
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(data.tobytes())


def wfc(folder):
    d = os.path.join(folder, "waveforms")
    return sorted(f for f in os.listdir(d) if f.endswith(".wfc")) if os.path.isdir(d) else []


def launch():
    if os.path.exists(SOCK):
        os.remove(SOCK)
    proc = subprocess.Popen([BIN, "--api", "--no-recent", "--language=en", "--socket=" + SOCK],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(200):
        if os.path.exists(SOCK):
            break
        time.sleep(0.1)
    else:
        proc.kill()
        print("the app did not open its socket")
        sys.exit(2)
    time.sleep(1.0)
    return proc


def stop(proc):
    proc.terminate()
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()


root = os.path.realpath(tempfile.mkdtemp(prefix="objekat-spill-"))
try:
    folder_a = os.path.join(root, "A")
    folder_b = os.path.join(root, "B")
    os.makedirs(folder_a)
    os.makedirs(folder_b)
    a_wav = os.path.join(folder_a, "a_sound.wav")
    make_wav(a_wav, 2.0, 330.0)
    b_wavs = []
    for i in range(B_SOUNDS):
        p = os.path.join(folder_b, "b_sound_%d.wav" % i)
        make_wav(p, 4.0, 200.0 + 40 * i)
        b_wavs.append(p)
    path_a = os.path.join(folder_a, "A.objekat")
    path_b = os.path.join(folder_b, "B.objekat")

    # 1. Build A and B. B's sounds are computed here too, but in THIS process's memory only.
    proc = launch()
    try:
        with ObjekatClient(SOCK) as c:
            cmd = lambda name, **p: c.send(name, p or None)
            cmd("project.new")
            cmd("object.add", path=a_wav, lane=0, start=0.0)
            cmd("project.save_as", path=path_a)
            cmd("project.new")
            ids = []
            for i in range(B_OBJECTS):
                r = cmd("object.add", path=b_wavs[i % B_SOUNDS], lane=i, start=0.0)
                ids.append(r["id"])
            for oid in ids:
                for _ in range(B_PLUGINS_EACH):
                    cmd("plugin.add", host=oid, identifier="aufx,rvb2,appl")
            cmd("project.save_as", path=path_b)
            cmd("wait_idle", timeout_ms=30000)
    finally:
        stop(proc)

    # Only what the scenario is about: B's folder is emptied of B's own `.wfc` so they must be
    # computed again, and A's keeps its own.
    shutil.rmtree(os.path.join(folder_b, "waveforms"), ignore_errors=True)
    check("A starts with its own .wfc only", wfc(folder_a) == ["a_sound.wav.wfc"], wfc(folder_a))

    # 2. A fresh process: open A, then B, letting the Canvas draw B's blocks during the load.
    proc = launch()
    try:
        with ObjekatClient(SOCK) as c:
            cmd = lambda name, **p: c.send(name, p or None)
            cmd("project.open", path=path_a)
            cmd("wait_idle", timeout_ms=30000)
            cmd("project.open", path=path_b, **{"async": True})
            saw_plugins = False
            deadline = time.time() + 120
            while time.time() < deadline:
                st = cmd("project.load_status")
                if st.get("phase") == "plugins":
                    saw_plugins = True
                if not st.get("loading"):
                    break
                time.sleep(0.05)
            check("B's load went through a plugins phase", saw_plugins)
            cmd("wait_idle", timeout_ms=60000)
            st = cmd("project.load_status")
            pw = cmd("perf.waveforms")
            print("info  load %s ms, mipmaps computed before preload: %s" % (
                (st.get("last_load") or {}).get("duration_ms"), pw.get("mipmaps_computed")))
            cmd("waveform.preload")
            # Let every compute in flight finish and land.
            for _ in range(100):
                stats = cmd("perf.waveforms")
                if stats.get("in_flight", 0) == 0:
                    break
                time.sleep(0.2)
            time.sleep(1.0)
    finally:
        stop(proc)

    a_after = wfc(folder_a)
    b_after = wfc(folder_b)
    check("A's waveforms/ received none of B's sounds", a_after == ["a_sound.wav.wfc"], a_after)
    expected_b = sorted(os.path.basename(p) + ".wfc" for p in b_wavs[:min(B_SOUNDS, B_OBJECTS)])
    check("B's waveforms/ holds B's sounds", b_after == expected_b, b_after)
finally:
    shutil.rmtree(root, ignore_errors=True)

print()
print("ALL PASS" if not fails else "FAILED: %d" % len(fails))
sys.exit(1 if fails else 0)

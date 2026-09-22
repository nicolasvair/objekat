#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The waveform cache's disk flush (C3) — a scenario that ASSERTS rather than replaying.

Same shape as `scenario_markers.py` / `scenario_relink.py`, and for the same reason: a
JSON-lines scenario cannot reuse an identifier an earlier command returned, and everything
here does — a project folder, an object id, a `.wfc` path.

    # 1. launch the app with the API, in UI MODE — NEVER --headless. Without a Canvas,
    #    `ensureWaveformsLoaded` never fires and `waveform.preload` answers `available: false`,
    #    which would make every assertion below pass for the wrong reason (nothing computed, so
    #    nothing written anywhere). @see PLAN-WAVEFORM.md, section D, pitfall 1.
    objekat.app/Contents/MacOS/objekat --api --no-recent --socket=/tmp/o.sock

    # 2. replay
    ./scenario_waveform_cache.py /tmp/o.sock

What it is really out to prove, beyond the commands answering:

  • a project's `waveforms/` folder receives ONLY the `.wfc` of files THAT PROJECT names — a
    brand new, empty project saved into a virgin folder must not inherit another project's
    peaks just because they happened to sit in the shared memory cache (measured before this
    fix: a 92 MB `.wfc` of a file the new project had never heard of);
  • a file computed BEFORE the first save is not lost — the intent the flush exists to serve —
    and is written once the folder becomes known, with no recompute;
  • the memory cache stays genuinely SHARED across projects: reopening one already seen serves
    its peaks from RAM, no disk read and no recompute;
  • a stale `.wfc` (an old format version) is rejected and silently replaced, never read as if
    it matched;
  • a WRITE started before a Save As lands in the folder that was current when the decode
    FINISHED, not the one that was current when it started (@see PLAN-WAVEFORM.md, pitfall 3
    in the C3 section — `writeTarget` is re-read on the MainActor right before the write).

Exit: 0 if every assertion passes, 1 otherwise.
"""

import os, shutil, struct, subprocess, sys, tempfile, time, wave, array

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

if len(sys.argv) != 2:
    print(__doc__)
    sys.exit(2)

SOCK = sys.argv[1]
BIP = os.path.join(HERE, "fixtures", "bip.wav")

# How long the "big" file of step 8 is: long enough that its decode is still running by the
# time the Save As that follows `waveform.preload` reaches the app — the whole point of that
# step. Tune upward if a fast machine / an optimised build wins the race too often to catch it
# (this scenario cannot know which build it is being run against).
BIG_SECONDS = 300.0
BIG_RATE = 48000

fails = []
roots = []


def check(label, ok, detail=""):
    if ok:
        print("ok    " + label)
    else:
        fails.append(label)
        print("FAIL  %s  %s" % (label, detail))


def tmproot(tag):
    """A temporary folder, remembered so the `finally` below can take it away again. REALPATH
    for the same reason `scenario_relink.py`'s own `tmproot` gives: macOS's `/tmp` resolves
    through `/private`, and a path this scenario hands the app should read back the same way a
    path the app discovers on its own would."""
    folder = tempfile.mkdtemp(prefix="objekat-wfcache-%s-" % tag)
    roots.append(folder)
    return os.path.realpath(folder)


def wfc_files(project_folder):
    d = os.path.join(project_folder, "waveforms")
    if not os.path.isdir(d):
        return []
    return sorted(f for f in os.listdir(d) if f.endswith(".wfc"))


def make_long_wav(path, seconds, rate=BIG_RATE, freq=220.0):
    """A mono 16-bit WAV of exactly `seconds` — long enough that decoding it takes visible
    real time, which is what step 8's race needs. Content is beside the point (a sine, so the
    file is not silence — not that this cache cares about VALUES, only about timing)."""
    folder = os.path.dirname(path)
    if folder:
        os.makedirs(folder, exist_ok=True)
    n = int(round(seconds * rate))
    import math
    samples = array.array("h", (
        int(12000 * math.sin(2 * math.pi * freq * i / rate)) for i in range(n)))
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(samples.tobytes())
    return path


def make_v2_wfc(path, sample_rate, duration, file_size, mtime, densities):
    """Hand-crafts a `.wfc` at FORMAT VERSION 2 (raw float32 peaks), with the exact identity
    (size, mtime) of a real file on disk — everything about it valid EXCEPT the version, which
    is the one thing this test means to catch. Same binary layout `WaveformCache.writeToDisk`
    writes, field by field (@see `Shared/WaveformCache.swift`'s own format comment,
    little-endian throughout): magic, version, sampleRate, duration, fileSize, mtime,
    levelCount, then per level (density, count), then the raw peak dump — 8 bytes/peak at v2
    (lo f32, hi f32) where v3 packs 4 (lo i16, hi i16), which is exactly what this test's last
    assertion tells apart."""
    with open(path, "wb") as f:
        f.write(b"WFC1")
        f.write(struct.pack("<I", 2))                      # version 2 — the fact under test
        f.write(struct.pack("<d", sample_rate))
        f.write(struct.pack("<d", duration))
        f.write(struct.pack("<Q", file_size))
        f.write(struct.pack("<d", mtime))
        f.write(struct.pack("<I", len(densities)))
        counts = []
        for density in densities:
            count = max(1, round(density * duration))
            counts.append(count)
            f.write(struct.pack("<d", density))
            f.write(struct.pack("<I", count))
        for count in counts:
            f.write(b"\x00\x00\x00\x00" * count)           # count × PeakPair(lo f32=0, hi f32=0)


def read_wfc_header(path):
    """Parses just enough of a `.wfc` to check its shape — magic, version, and the level table
    — without assuming anything about the peak payload's own width, which is exactly the field
    under test."""
    with open(path, "rb") as f:
        raw = f.read()
    head_fmt = "<4sIddQdI"
    magic, version, sample_rate, duration, file_size, mtime, level_count = \
        struct.unpack_from(head_fmt, raw, 0)
    offset = struct.calcsize(head_fmt)
    counts = []
    for _ in range(level_count):
        _density, count = struct.unpack_from("<dI", raw, offset)
        offset += struct.calcsize("<dI")
        counts.append(count)
    return {
        "magic": magic, "version": version, "level_count": level_count,
        "counts": counts, "payload_offset": offset, "total_size": len(raw),
    }


def wait_waveforms_idle(cmd, timeout_s=60.0, settle_polls=3):
    """Polls `perf.waveforms` until `in_flight` is 0 and STAYS there for a few consecutive
    polls (@see PLAN-WAVEFORM.md section E4's own protocol) — a single `in_flight == 0` reading
    can land in the gap between one decode finishing and the next one, requested a moment
    later, starting."""
    deadline = time.time() + timeout_s
    stable = 0
    stats = None
    while time.time() < deadline:
        stats = cmd("perf.waveforms")
        if stats["in_flight"] == 0:
            stable += 1
            if stable >= settle_polls:
                return stats
        else:
            stable = 0
        time.sleep(0.05)
    raise TimeoutError("waveform cache never settled: %r" % (stats,))


def find_pid_for_socket(sock_path):
    """The process listening on this UNIX socket — the app was not asked to launch itself (a
    UI instance needs a real window server session, which is the caller's to set up), so its
    pid is recovered from the one thing it is known to hold open."""
    try:
        out = subprocess.check_output(["lsof", "-t", sock_path],
                                       text=True, stderr=subprocess.DEVNULL)
        pids = [int(p) for p in out.split()]
        return pids[0] if pids else None
    except Exception:
        return None


def window_count_for_pid(pid):
    """Whether macOS shows an on-screen window for this process — the exact INVERSE of the
    project's own headless guard (CLAUDE.md: 'with --headless, NOTHING may open a window',
    verified there via the same call on an EMPTY list). A UI instance must have at least one."""
    import Quartz
    info = Quartz.CGWindowListCopyWindowInfo(
        Quartz.kCGWindowListOptionAll, Quartz.kCGNullWindowID)
    return sum(1 for w in info if w.get("kCGWindowOwnerPID") == pid)


try:
    with ObjekatClient(SOCK) as c:
        def cmd(_cmd_name, **params):
            return c.send(_cmd_name, params or None)

        # ── the guardrails that protect the METHOD, before anything else is asserted ──
        # (@see PLAN-WAVEFORM.md section D, pitfall 1 — this is the whole reason it exists)
        info = cmd("app.info")
        check("--no-recent honoured", info.get("records_recent_projects") is False,
              str(info.get("records_recent_projects")))

        cmd("project.new")
        preload_probe = cmd("waveform.preload")
        available = preload_probe.get("available")
        check("waveform.preload is available — this is a UI instance, not a headless one",
              available is True,
              "available=%r: run this against `--api` with NO --headless (@see the pitfall "
              "this exact assertion guards against, PLAN-WAVEFORM.md section D.1)" % available)
        if available is not True:
            print("\nABORTING: nothing below would prove anything against a headless instance.")
            sys.exit(1)

        pid = find_pid_for_socket(SOCK)
        if pid is not None:
            try:
                wc = window_count_for_pid(pid)
                check("a UI instance owns at least one on-screen window", wc > 0, "windows=%d" % wc)
            except ImportError:
                print("  (skipped: pyobjc/Quartz is not importable in this environment)")
        else:
            print("  (skipped: could not resolve the pid behind the socket)")

        # ── 4. the flush: a project's waveforms/ receives ONLY what that project names ──
        folder_a = tmproot("a")
        path_a = os.path.join(folder_a, "a.objekat.json")
        cmd("project.new")
        wav1 = os.path.join(folder_a, "one.wav")
        shutil.copyfile(BIP, wav1)   # the tiny fixture: this step is about WHERE, not how long
        cmd("object.add", path=wav1, lane=0, start=0.0)
        cmd("project.save_as", path=path_a)
        cmd("waveform.preload")
        wait_waveforms_idle(cmd)
        check("A/waveforms holds exactly the one file it names",
              wfc_files(folder_a) == [os.path.basename(wav1) + ".wfc"], str(wfc_files(folder_a)))

        folder_b = tmproot("b")
        path_b = os.path.join(folder_b, "b.objekat.json")
        cmd("project.new")
        cmd("project.save_as", path=path_b)
        check("a virgin project's waveforms/ receives nothing at all — NOT the peaks still "
              "sitting in the shared memory cache from project A",
              wfc_files(folder_b) == [], str(wfc_files(folder_b)))

        # ── 5. the original intent still holds: an UNSAVED compute is not lost ──
        before_5 = cmd("perf.waveforms")
        cmd("project.new")
        folder_c_src = tmproot("c-src")   # hosts the source file before any project folder exists
        wav2 = os.path.join(folder_c_src, "two.wav")
        shutil.copyfile(BIP, wav2)
        cmd("object.add", path=wav2, lane=0, start=0.0)
        cmd("waveform.preload")
        after_preload = wait_waveforms_idle(cmd)
        check("computed even with no project folder yet",
              after_preload["mipmaps_computed"] == before_5["mipmaps_computed"] + 1,
              "%r -> %r" % (before_5["mipmaps_computed"], after_preload["mipmaps_computed"]))
        check("but nothing was written — there was nowhere to write it to",
              after_preload["mipmaps_written"] == before_5["mipmaps_written"],
              "%r -> %r" % (before_5["mipmaps_written"], after_preload["mipmaps_written"]))

        folder_c = tmproot("c")
        path_c = os.path.join(folder_c, "c.objekat.json")
        cmd("project.save_as", path=path_c)
        # The flush is deliberately fire-and-forget (.utility, @see setWaveformsDirectory) — no
        # command confirms it finished, so this polls for the file itself rather than guessing
        # a fixed sleep.
        deadline = time.time() + 5.0
        while time.time() < deadline and not wfc_files(folder_c):
            time.sleep(0.05)
        check("the folder receives the already-computed peaks once it becomes known",
              wfc_files(folder_c) == [os.path.basename(wav2) + ".wfc"], str(wfc_files(folder_c)))
        after_save = cmd("perf.waveforms")
        check("...without recomputing them",
              after_save["mipmaps_computed"] == after_preload["mipmaps_computed"],
              "%r -> %r" % (after_preload["mipmaps_computed"], after_save["mipmaps_computed"]))

        # ── 6. the memory cache's own benefit is not collateral damage ──
        before_6 = cmd("perf.waveforms")
        cmd("project.new")
        cmd("project.open", path=path_a)
        cmd("wait_idle", timeout_ms=5000)
        cmd("waveform.preload")
        after_6 = wait_waveforms_idle(cmd)
        check("reopening a project already seen recomputes nothing",
              after_6["mipmaps_computed"] == before_6["mipmaps_computed"],
              "%r -> %r" % (before_6["mipmaps_computed"], after_6["mipmaps_computed"]))
        check("...and reads nothing off disk either — served from RAM alone",
              after_6["mipmaps_read_from_disk"] == before_6["mipmaps_read_from_disk"],
              "%r -> %r" % (before_6["mipmaps_read_from_disk"], after_6["mipmaps_read_from_disk"]))

        # ── 7. a stale format version is rejected, never read as if it matched ──
        folder_v = tmproot("version")
        path_v = os.path.join(folder_v, "v.objekat.json")
        cmd("project.new")
        cmd("project.save_as", path=path_v)   # gives this project a real waveforms/ to seed
        wav3 = os.path.join(folder_v, "three.wav")
        shutil.copyfile(BIP, wav3)
        size = os.path.getsize(wav3)
        mtime = os.path.getmtime(wav3)
        with wave.open(wav3, "rb") as wf:
            sample_rate = float(wf.getframerate())
            duration = wf.getnframes() / sample_rate
        waveforms_dir = os.path.join(folder_v, "waveforms")
        os.makedirs(waveforms_dir, exist_ok=True)
        wfc_path = os.path.join(waveforms_dir, os.path.basename(wav3) + ".wfc")
        # `[100, 1000]`: today's `effectiveDensitiesPerSecond` (@see C1b) — plausible even if
        # the version guard were ever bypassed by mistake, so this test still isolates the ONE
        # thing it means to prove.
        make_v2_wfc(wfc_path, sample_rate, duration, size, mtime, densities=[100.0, 1000.0])

        before_7 = cmd("perf.waveforms")
        cmd("object.add", path=wav3, lane=0, start=0.0)
        cmd("waveform.preload")
        after_7 = wait_waveforms_idle(cmd)
        check("a v2 `.wfc` is rejected and recomputed rather than read",
              after_7["mipmaps_computed"] == before_7["mipmaps_computed"] + 1
              and after_7["mipmaps_read_from_disk"] == before_7["mipmaps_read_from_disk"],
              "computed %r->%r, read_from_disk %r->%r" % (
                  before_7["mipmaps_computed"], after_7["mipmaps_computed"],
                  before_7["mipmaps_read_from_disk"], after_7["mipmaps_read_from_disk"]))

        header = read_wfc_header(wfc_path)
        check("the file rewritten on disk is WFC1", header["magic"] == b"WFC1", str(header["magic"]))
        check("...at version 3", header["version"] == 3, str(header["version"]))
        expected_size = header["payload_offset"] + sum(n * 4 for n in header["counts"])
        check("...sized for int16 pairs (4 bytes/peak), not the old float32 (8)",
              header["total_size"] == expected_size,
              "%d vs %d (counts=%r)" % (header["total_size"], expected_size, header["counts"]))

        # ── 8. a write started before a Save As lands where the project ENDED UP ──
        folder_start = tmproot("start")
        path_start = os.path.join(folder_start, "start.objekat.json")
        folder_d = tmproot("d")
        path_d = os.path.join(folder_d, "d.objekat.json")

        cmd("project.new")
        cmd("project.save_as", path=path_start)
        big_wav = os.path.join(folder_start, "big.wav")
        make_long_wav(big_wav, seconds=BIG_SECONDS)
        cmd("object.add", path=big_wav, lane=0, start=0.0)
        cmd("waveform.preload")               # fires the async compute and returns at once
        cmd("project.save_as", path=path_d)   # retargets the project WHILE the decode runs
        wait_waveforms_idle(cmd, timeout_s=120.0)
        check("the peaks land in the folder current when the decode FINISHED",
              wfc_files(folder_d) == [os.path.basename(big_wav) + ".wfc"], str(wfc_files(folder_d)))
        check("...and never in the one current when it STARTED",
              wfc_files(folder_start) == [], str(wfc_files(folder_start)))

        # The app must not be left holding the temporary files while they are taken away.
        cmd("project.new")

finally:
    for folder in roots:
        shutil.rmtree(folder, ignore_errors=True)

print("\nALL PASS" if not fails else "\n%d FAILURE(S): %s" % (len(fails), ", ".join(fails)))
sys.exit(0 if not fails else 1)

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""A source file rewritten on disk — a scenario that ASSERTS rather than replaying.

Same shape as `scenario_relink.py`, and for the same reason: a JSON-lines scenario cannot reuse an
identifier an earlier command returned, and everything here does.

    # 1. launch the app with the API on a SHORT socket (a system limit: 103 bytes).
    #    `--no-recent`: the throwaway projects below do not enter "Recent projects".
    #    Headless is enough for everything but the waveform checks of section A, which need a
    #    CANVAS (`waveform.preload` answers `available: false` without one, and those checks are then
    #    reported as skipped — run it once in UI mode, without --headless, to have them).
    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --socket=/tmp/o.sock

    # 2. replay
    ./scenario_file_changed.py /tmp/o.sock

It makes its own audio files in a temporary folder and REWRITES them under the app's feet — the only
honest way to test this: a changed file is a fact of the file system, not a flag one can set. The
detection is driven through `files.check_changes` (the very function the three real triggers —
opening, returning to the foreground, returning to a tab — call), and what it did is read back from
the answer and from `perf.waveforms`' `file_change_*` counters.

What it is out to prove:

  A. a wav rewritten with other content is reloaded ONCE, silently: the engine plays the new file
     (a render re-read at RMS), the model follows (`file_duration`, `file_size`), nothing is put on
     the undo stack and the project is not made dirty; in UI mode the `.wfc` is rewritten with
     other peaks;
  B. a SHORTER file crops the window like a relink does (slide back, then cut), the fades staying
     valid; a longer one leaves the window alone;
  C. a REVERSED clip, a FLAC and an MP3 (reversed or not) play the new file — Tracktion's derived
     files are keyed by a hash of the PATH, so without the purge they would play the old one;
  D. nothing changed → 0 reloads and one `stat` per DISTINCT path; the foreground trigger has its
     2 s anti-bounce;
  E. a change DURING PLAYBACK is put off and applied at the stop, not under the hand listening;
  F. two tabs sharing the file: each tab is brought up to date against what IT knew, the one in
     front at once, the other when it comes back to the front;
  G. what the app writes itself (`samples/sources`) is never scanned, a PLAIN clip whose file lies
     in `samples/consolidate` is, and an opening catches a file changed while the project was closed.

Exit: 0 if every assertion passes, 1 otherwise.
"""

import array, json, math, os, shutil, struct, subprocess, sys, tempfile, time, wave

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

if len(sys.argv) != 2:
    print(__doc__)
    sys.exit(2)

SOCK = sys.argv[1]
RATE = 48000

fails = []
roots = []


def check(label, ok, detail=""):
    if ok:
        print("ok    " + label)
    else:
        fails.append(label)
        print("FAIL  %s  %s" % (label, detail))


def approx(a, b, eps=1e-3):
    try:
        return abs(float(a) - float(b)) < eps
    except (TypeError, ValueError):
        return False


def tmproot(tag):
    """A temporary folder, REALPATH'd (macOS keeps /tmp under /private; a path the app discovers on
    its own comes back resolved, and the two must speak the same path)."""
    folder = tempfile.mkdtemp(prefix="objekat-fchg-%s-" % tag)
    roots.append(folder)
    return os.path.realpath(folder)


def make_wav(path, segments, rate=RATE):
    """A mono 16-bit wav made of `segments`: [(seconds, amplitude 0..1, freq Hz), ...]. The
    ENVELOPE is what the assertions read (the RMS of each half), so two files can have the same
    length and sound different, and one file reversed is told from its original."""
    folder = os.path.dirname(path)
    if folder:
        os.makedirs(folder, exist_ok=True)
    samples = array.array("h")
    for seconds, amp, freq in segments:
        n = int(round(seconds * rate))
        samples.extend(int(32767 * amp * math.sin(2 * math.pi * freq * i / rate)) for i in range(n))
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(samples.tobytes())
    return path


def rewrite_with(path, segments):
    """Rewrites `path` in place with other content, making sure its mtime really moves even on a
    fast disk (the size may be the same: only the time then tells)."""
    before = os.stat(path).st_mtime_ns
    make_wav(path, segments)
    if os.stat(path).st_mtime_ns == before:
        os.utime(path, ns=(before + 1_000_000_000, before + 1_000_000_000))


def read_wav(path):
    """(samples as floats, channels) of a 16- or 24-bit wav."""
    with wave.open(path, "rb") as w:
        width, ch, raw = w.getsampwidth(), w.getnchannels(), w.readframes(w.getnframes())
    if width == 2:
        vals = [v / 32768.0 for v in array.array("h", raw)]
    elif width == 3:
        vals = [int.from_bytes(raw[i:i + 3], "little", signed=True) / 8388608.0
                for i in range(0, len(raw) - 2, 3)]
    else:
        raise RuntimeError("unexpected sample width: %d" % width)
    return vals, ch


def rms(vals):
    return math.sqrt(sum(v * v for v in vals) / len(vals)) if vals else 0.0


def span_rms(path, t0, t1):
    """RMS of the render between t0 and t1 seconds (all channels)."""
    vals, ch = read_wav(path)
    frames = len(vals) // ch
    a, b = int(t0 * RATE), min(frames, int(t1 * RATE))
    return rms(vals[a * ch:b * ch])


def wait_waveforms_idle(cmd, timeout_s=60.0, settle_polls=3):
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


def read_wfc(path):
    with open(path, "rb") as f:
        raw = f.read()
    head = "<4sIddQdII"
    magic, version, sr, duration, size, mtime, lanes, levels = struct.unpack_from(head, raw, 0)
    off = struct.calcsize(head) + levels * struct.calcsize("<dI")
    payload = raw[off:]
    shorts = struct.unpack("<%dh" % (len(payload) // 2), payload[:len(payload) // 2 * 2])
    return {"size": size, "mtime": mtime, "payload": payload,
            "peak": max((abs(v) for v in shorts), default=0), "raw": raw}


try:
    with ObjekatClient(SOCK) as c:
        def cmd(_cmd_name, **params):
            return c.send(_cmd_name, params or None)

        def settle():
            cmd("wait_idle", timeout_ms=15000)

        def obj(oid):
            return cmd("object.get", id=oid)

        def counters():
            return cmd("perf.waveforms")

        def reset_counters():
            cmd("perf.waveforms", reset=True)

        def scan(**kw):
            """One detection pass, to the end."""
            r = cmd("files.check_changes", **kw)
            settle()
            return r

        render_count = [0]

        def render(out, t1, fmt="wav"):
            # A fresh name every time: in UI mode a render over an existing file asks to overwrite,
            # and the question is a modal alert that would hold the command for ever.
            if fmt == "wav":
                render_count[0] += 1
                out = "%s-%d.wav" % (out[:-4], render_count[0])
            args = dict(format=fmt, sample_rate=48000, start=0.0, end=t1, path=out)
            if fmt == "wav":
                args.update(dithering=False, bit_depth=24)
            job = cmd("export.run", **args)["job_id"]
            done = cmd("job.wait", id=job, timeout_ms=60000)
            if not os.path.exists(out):
                raise RuntimeError("export failed: %s" % json.dumps(done))
            return out

        info = cmd("app.info")
        check("--no-recent honoured", info.get("records_recent_projects") is False,
              str(info.get("records_recent_projects")))
        ui = cmd("waveform.preload").get("available") is True
        print("  (instance: %s)" % ("UI — the waveform checks run" if ui else
                                    "headless — the waveform checks are skipped"))

        LOUD, QUIET = 0.5, 0.05
        TONE_A = [(1.0, LOUD, 440.0), (1.0, QUIET, 440.0)]     # loud, then quiet   (2 s)
        TONE_B = [(1.0, QUIET, 660.0), (1.0, LOUD, 660.0)]     # quiet, then loud   (2 s)

        # ── A. one wav rewritten: the engine, the model, the undo stack, the waveform ──
        cmd("project.new")
        d = tmproot("a")
        proj_dir = os.path.join(d, "proj")
        os.makedirs(proj_dir)
        proj = os.path.join(proj_dir, "a.objekat")
        cmd("project.save_as", path=proj)
        wav = make_wav(os.path.join(d, "s", "take.wav"), TONE_A)
        a1 = cmd("object.add", path=wav, lane=0, start=0.0)["id"]
        a2 = cmd("object.add", path=wav, lane=1, start=0.0)["id"]       # a second object, same file
        cmd("object.set_fade", id=a1, **{"in": 0.1})
        settle()
        if ui:
            cmd("waveform.preload")
            wait_waveforms_idle(cmd)
            wfc_path = os.path.join(proj_dir, "waveforms", os.path.basename(wav) + ".wfc")
            check("(UI) the .wfc of the take exists before the change", os.path.exists(wfc_path))
            wfc0 = read_wfc(wfc_path) if os.path.exists(wfc_path) else None
        first = scan()
        check("the first scan LEARNS the file: nothing reloaded (one stat for two objects)",
              first["scanned"] == 1 and first["changed"] == [] and first["reloaded_objects"] == 0,
              str(first))
        out0 = render(os.path.join(d, "r0.wav"), 2.0)
        check("(before) the render plays the old file: loud first half, quiet second",
              span_rms(out0, 0.1, 0.9) > 5 * span_rms(out0, 1.1, 1.9),
              "%.4f / %.4f" % (span_rms(out0, 0.1, 0.9), span_rms(out0, 1.1, 1.9)))
        cmd("project.save")
        check("(the project is clean before the change)", cmd("app.info")["dirty"] is False)

        reset_counters()
        old_size = os.path.getsize(wav)
        rewrite_with(wav, TONE_B)                       # same length, other content
        r = scan()
        check("a rewritten file is found: ONE path, TWO objects rebuilt",
              r["changed"] == [wav] and r["reloaded_paths"] == [wav] and r["reloaded_objects"] == 2
              and r["deferred_by"] is None, str(r))
        ctr = counters()
        check("counters: one scan, one stat, ONE reload for two objects",
              ctr["file_change_scans"] == 1 and ctr["file_change_stats"] == 1
              and ctr["file_change_reloads"] == 1, str({k: v for k, v in ctr.items() if k.startswith("file_change")}))
        out1 = render(os.path.join(d, "r1.wav"), 2.0)
        check("(after) the render plays the NEW file: quiet first half, loud second",
              span_rms(out1, 1.1, 1.9) > 5 * span_rms(out1, 0.1, 0.9),
              "%.4f / %.4f" % (span_rms(out1, 0.1, 0.9), span_rms(out1, 1.1, 1.9)))
        g1 = obj(a1)
        check("the model follows: file_duration and the fade are right", approx(g1["file_duration"], 2.0)
              and approx(g1["fade_in"], 0.1) and approx(g1["duration"], 2.0), str(g1))
        check("the reload did NOT make the project dirty", cmd("app.info")["dirty"] is False)
        undone = cmd("edit.undo")
        check("…and left no undo point: the top of the stack is still the user's own fade",
              approx(obj(a1)["fade_in"], 0.0), str(undone))
        cmd("edit.redo")
        again = scan()
        check("a second scan finds nothing more (the identity was learned)",
              again["changed"] == [] and again["reloaded_objects"] == 0, str(again))

        # the same size, only the time moves
        rewrite_with(wav, TONE_A)
        same_size = os.path.getsize(wav)
        r = scan()
        check("a rewrite with the SAME size is found through the modification time alone",
              r["changed"] == [wav] and same_size == os.path.getsize(wav), str(r))

        if ui:
            cmd("waveform.preload")
            wait_waveforms_idle(cmd)
            wfc1 = read_wfc(wfc_path)
            ctr = counters()
            check("(UI) the .wfc was rewritten for the new file (its header names the new size and time)",
                  wfc1["size"] == os.path.getsize(wav) and wfc1["mtime"] != wfc0["mtime"],
                  "%s vs %s" % (wfc1["size"], os.path.getsize(wav)))
            # TONE_A was written back last, so the peaks come back to the first file's: compare with
            # the loud-and-quiet shape rather than with `wfc0` byte for byte (the quantiser is the same).
            check("(UI) the cache was emptied and recomputed (invalidations and mipmaps_computed move)",
                  ctr["invalidations"] >= 2 and ctr["mipmaps_computed"] >= 2, str(ctr))
            # a decisive content change: loud everything vs very quiet everything
            rewrite_with(wav, [(2.0, 0.9, 300.0)])
            scan()
            cmd("waveform.preload")
            wait_waveforms_idle(cmd)
            wfc2 = read_wfc(wfc_path)
            check("(UI) other content → other peaks in the .wfc (the peak value rises)",
                  wfc2["payload"] != wfc1["payload"] and wfc2["peak"] > wfc1["peak"],
                  "%d vs %d" % (wfc2["peak"], wfc1["peak"]))
        else:
            print("  (skipped: the waveform checks of section A need a UI instance)")

        # ── B. a shorter file crops the window, a longer one leaves it ──
        cmd("project.new")
        d = tmproot("b")
        long4 = make_wav(os.path.join(d, "long.wav"), [(4.0, 0.3, 440.0)])
        b1 = cmd("object.add", path=long4, lane=0, start=0.0, duration=2.5)["id"]
        cmd("object.set_source_offset", id=b1, offset=1.0)             # reads [1.0, 3.5]
        cmd("object.set_fade", id=b1, **{"in": 0.5, "out": 0.5})
        b2 = cmd("object.add", path=long4, lane=1, start=0.0, duration=0.5)["id"]
        cmd("object.set_source_offset", id=b2, offset=3.0)             # reads [3.0, 3.5]
        settle()
        scan()                                                         # learns
        rewrite_with(long4, [(2.0, 0.3, 440.0)])                       # 4 s → 2 s
        r = scan()
        check("a shortened file is reloaded", r["reloaded_paths"] == [long4] and r["reloaded_objects"] == 2, str(r))
        g1, g2 = obj(b1), obj(b2)
        check("the window longer than the file is cropped to the file, from its start",
              approx(g1["source_offset"], 0.0) and approx(g1["duration"], 2.0)
              and approx(g1["file_duration"], 2.0), str(g1))
        check("…the fades stay valid (in + out within the new length, none negative)",
              g1["fade_in"] >= 0 and g1["fade_out"] >= 0
              and g1["fade_in"] + g1["fade_out"] <= g1["duration"] + 1e-6
              and approx(g1["fade_in"], 0.5), str(g1))
        check("a short window past the new end slides BACK and keeps its length",
              approx(g2["source_offset"], 1.5) and approx(g2["duration"], 0.5), str(g2))
        out = render(os.path.join(d, "rb.wav"), 3.0)
        check("the render reads no further than the new end (the last second is silent)",
              span_rms(out, 2.2, 2.9) < 1e-3 and span_rms(out, 0.2, 1.8) > 0.05,
              "%.5f / %.5f" % (span_rms(out, 2.2, 2.9), span_rms(out, 0.2, 1.8)))
        rewrite_with(long4, [(5.0, 0.3, 440.0)])                       # 2 s → 5 s
        r = scan()
        g1, g2 = obj(b1), obj(b2)
        check("a LONGER file updates file_duration and leaves the window alone",
              approx(g1["file_duration"], 5.0) and approx(g1["duration"], 2.0)
              and approx(g2["source_offset"], 1.5) and approx(g2["duration"], 0.5), str((g1, g2)))

        # ── C. reversed clip, FLAC, MP3: the derived files must not outlive the content ──
        def halves(path, t=2.0):
            h = t / 2
            return span_rms(path, 0.1, h - 0.1), span_rms(path, h + 0.1, t - 0.1)

        d = tmproot("c")
        src_a = make_wav(os.path.join(d, "fx", "A.wav"), TONE_A)
        src_b = make_wav(os.path.join(d, "fx", "B.wav"), TONE_B)
        flac_a = os.path.join(d, "fx", "A.flac")
        flac_b = os.path.join(d, "fx", "B.flac")
        for s, t in ((src_a, flac_a), (src_b, flac_b)):
            subprocess.check_call(["afconvert", "-f", "flac", "-d", "flac", s, t])
        # The MP3s are made by the app itself (it carries an encoder; macOS has none).
        mp3_a = os.path.join(d, "fx", "A.mp3")
        mp3_b = os.path.join(d, "fx", "B.mp3")
        for s, t in ((src_a, mp3_a), (src_b, mp3_b)):
            cmd("project.new")
            cmd("object.add", path=s, lane=0, start=0.0)
            settle()
            render(t, 2.0, fmt="mp3")

        def case(name, ext_a, ext_b, play_path, reverse):
            """`play_path` first holds A's content, then B's; `reverse` = played backwards."""
            os.makedirs(os.path.dirname(play_path), exist_ok=True)
            shutil.copyfile(ext_a, play_path)
            cmd("project.new")
            oid = cmd("object.add", path=play_path, lane=0, start=0.0)["id"]
            if reverse:
                cmd("object.set_reversed", id=oid, reversed=True)
            settle()
            time.sleep(0.5)                       # a derived file (the reversed render) is made async
            scan()                                # learns
            h1 = (0.0, 0.0)
            for attempt in range(40):
                h1 = halves(render(os.path.join(d, "%s-1.wav" % name), 2.0))
                if max(h1) > 0.01:
                    break
                time.sleep(0.25)
            shutil.copyfile(ext_b, play_path)
            os.utime(play_path)                   # a copy already has a new mtime; be explicit
            r = scan()
            # A reversed compressed clip is silent for a moment after the reload: its derived file
            # (the proxy, then the reversed render) is made again, asynchronously, as it is the
            # first time a clip is reversed. Polled until it plays, and the delay reported.
            t_reload = time.time()
            h2 = (0.0, 0.0)
            for attempt in range(40):
                o2 = render(os.path.join(d, "%s-2.wav" % name), 2.0)
                h2 = halves(o2)
                if max(h2) > 0.01:
                    break
                time.sleep(0.25)
            delay = time.time() - t_reload
            loud_first_1 = h1[0] > 3 * h1[1]
            loud_second_1 = h1[1] > 3 * h1[0]
            # A is loud-then-quiet; played forward the first half is loud, reversed the second is.
            expect_before = (loud_second_1 if reverse else loud_first_1)
            check("%s: before the change it plays A (%s)" % (name, "reversed" if reverse else "forward"),
                  expect_before, "%.4f / %.4f" % h1)
            new_loud_first = h2[0] > 3 * h2[1]
            new_loud_second = h2[1] > 3 * h2[0]
            # B is quiet-then-loud: forward the second half is loud, reversed the first is.
            expect_after = (new_loud_first if reverse else new_loud_second)
            check("%s: after the change it plays B, not the stale derived file (audible %.2f s after the scan)"
                  % (name, delay),
                  expect_after and r["reloaded_objects"] == 1, "%.4f / %.4f  %s" % (h2 + (r,)))

        case("wav-reversed", src_a, src_b, os.path.join(d, "play", "r.wav"), True)
        case("flac-forward", flac_a, flac_b, os.path.join(d, "play", "f.flac"), False)
        case("flac-reversed", flac_a, flac_b, os.path.join(d, "play", "fr.flac"), True)
        case("mp3-forward", mp3_a, mp3_b, os.path.join(d, "play", "m.mp3"), False)
        case("mp3-reversed", mp3_a, mp3_b, os.path.join(d, "play", "mr.mp3"), True)

        # ── D. nothing changed: no reload, one stat per DISTINCT path, a quick scan ──
        cmd("project.new")
        d = tmproot("d")
        wavs = [make_wav(os.path.join(d, "n%d.wav" % i), [(0.5, 0.2, 200.0 + 50 * i)]) for i in range(3)]
        for i in range(6):
            cmd("object.add", path=wavs[i % 3], lane=i, start=0.0)
        settle()
        scan()                                                         # learns
        reset_counters()
        t0 = time.time()
        r = scan()
        wall = time.time() - t0
        ctr = counters()
        check("nothing changed: scanned 3 distinct paths for 6 objects, 0 reloads",
              r["scanned"] == 3 and r["changed"] == [] and r["reloaded_objects"] == 0, str(r))
        check("counters: one scan, 3 stats, 0 reloads",
              ctr["file_change_scans"] == 1 and ctr["file_change_stats"] == 3
              and ctr["file_change_reloads"] == 0, str({k: v for k, v in ctr.items() if k.startswith("file_change")}))
        check("the scan is fast (stats %.2f ms, whole command %.0f ms)" % (ctr["file_change_stat_seconds"] * 1000, wall * 1000),
              ctr["file_change_stat_seconds"] < 0.05 and wall < 1.0)
        time.sleep(2.2)                                                # clear any scan's anti-bounce window
        f1 = scan(reason="foreground")
        f2 = scan(reason="foreground")
        check("the foreground trigger: a first scan runs, a second inside 2 s is swallowed",
              f1["skipped"] is None and f1["scanned"] == 3 and f2["skipped"] == "anti_bounce", str((f1, f2)))
        time.sleep(2.2)
        f3 = scan(reason="foreground")
        check("…and runs again after the 2 s", f3["skipped"] is None, str(f3))
        # a vanished file is not 'changed' (that is the missing-files machinery's business)
        os.rename(wavs[0], wavs[0] + ".gone")
        r = scan()
        check("a vanished file is not reloaded (and nothing is reported changed)",
              r["changed"] == [] and r["reloaded_objects"] == 0, str(r))
        os.rename(wavs[0] + ".gone", wavs[0])

        # ── E. a change during playback waits for the stop ──
        cmd("project.new")
        d = tmproot("e")
        play = make_wav(os.path.join(d, "play.wav"), [(3.0, 0.3, 440.0)])
        e1 = cmd("object.add", path=play, lane=0, start=0.0)["id"]
        settle()
        scan()
        reset_counters()
        cmd("transport.play")
        rewrite_with(play, [(1.5, 0.3, 440.0)])
        r = cmd("files.check_changes")
        check("during playback the scan is put off (nothing read, nothing reloaded)",
              r["deferred_by"] == "transport" and r["reloaded_objects"] == 0 and r["scanned"] == 0, str(r))
        check("…the model still says the old file", approx(obj(e1)["file_duration"], 3.0))
        time.sleep(0.5)
        check("…even half a second later (no polling during playback)",
              approx(obj(e1)["file_duration"], 3.0) and counters()["file_change_reloads"] == 0)
        cmd("transport.stop")
        settle()
        g = obj(e1)
        ctr = counters()
        check("at the STOP the change is applied (file_duration 1.5, one reload)",
              approx(g["file_duration"], 1.5) and approx(g["duration"], 1.5)
              and ctr["file_change_reloads"] == 1 and ctr["file_change_deferred"] >= 1,
              str((g["file_duration"], g["duration"], {k: v for k, v in ctr.items() if k.startswith("file_change")})))

        # ── F. two tabs sharing the file ──
        d = tmproot("f")
        shared = make_wav(os.path.join(d, "shared.wav"), [(3.0, 0.3, 440.0)])
        os.makedirs(os.path.join(d, "one"))
        os.makedirs(os.path.join(d, "two"))
        p1 = os.path.join(d, "one", "one.objekat")
        p2 = os.path.join(d, "two", "two.objekat")
        cmd("project.new")
        cmd("object.add", path=shared, lane=0, start=0.0)
        cmd("project.save_as", path=p1)
        settle()
        scan()                                                          # tab one learns the take
        t2 = cmd("tab.new")
        cmd("object.add", path=shared, lane=0, start=0.0)
        cmd("project.save_as", path=p2)
        settle()
        scan()                                                          # tab two learns it too
        tabs = cmd("tab.list")
        check("two tabs, the second one in front", tabs["count"] == 2 and tabs["tabs"][1]["active"], str(tabs))
        tab_one_id = tabs["tabs"][0]["id"]
        tab_two_id = tabs["tabs"][1]["id"]
        reset_counters()
        rewrite_with(shared, [(1.0, 0.3, 440.0)])                       # 3 s → 1 s, under both tabs
        r = scan()
        two_obj = cmd("object.list")["objects"][0]["id"]
        check("the tab in front is brought up to date at once (1 object, file_duration 1.0)",
              r["reloaded_objects"] == 1 and approx(obj(two_obj)["file_duration"], 1.0), str(r))
        before_reloads = counters()["file_change_reloads"]
        cmd("tab.select", id=tab_one_id)
        settle()
        one_obj = cmd("object.list")["objects"][0]["id"]
        g = obj(one_obj)
        ctr = counters()
        check("returning to the other tab brings IT up to date too, against what IT knew",
              approx(g["file_duration"], 1.0) and approx(g["duration"], 1.0)
              and ctr["file_change_reloads"] == before_reloads + 1,
              str((g["file_duration"], g["duration"], ctr["file_change_reloads"], before_reloads)))
        cmd("tab.select", id=tab_two_id)
        settle()
        cmd("tab.select", id=tab_one_id)
        settle()
        check("…and going back and forth reloads nothing more",
              counters()["file_change_reloads"] == ctr["file_change_reloads"],
              str((counters()["file_change_reloads"], ctr["file_change_reloads"])))
        cmd("tab.close", id=tab_two_id, discard=True)
        settle()

        # ── G. the app's own folders are never scanned; an opening catches a change made while closed ──
        cmd("project.new")
        d = tmproot("g")
        pdir = os.path.join(d, "proj")
        os.makedirs(os.path.join(pdir, "samples", "sources"))
        gproj = os.path.join(pdir, "g.objekat")
        cmd("project.save_as", path=gproj)
        mine = make_wav(os.path.join(pdir, "samples", "sources", "own.wav"), [(1.0, 0.3, 440.0)])
        ext = make_wav(os.path.join(d, "ext", "ext.wav"), [(1.0, 0.3, 330.0)])
        cmd("object.add", path=mine, lane=0, start=0.0)
        g_ext = cmd("object.add", path=ext, lane=1, start=0.0)["id"]
        settle()
        r = scan()
        check("a file under samples/sources is not scanned (1 path asked of the disk, not 2)",
              r["scanned"] == 1, str(r))
        rewrite_with(mine, [(2.0, 0.3, 440.0)])
        r = scan()
        check("…and when it changes nothing is reloaded", r["changed"] == [] and r["reloaded_objects"] == 0, str(r))
        cons = make_wav(os.path.join(pdir, "samples", "consolidate", "plain.wav"), [(1.0, 0.3, 550.0)])
        g_cons = cmd("object.add", path=cons, lane=2, start=0.0)["id"]
        settle()
        r = scan()
        check("a PLAIN clip under samples/consolidate is scanned (2 paths now)", r["scanned"] == 2, str(r))
        rewrite_with(cons, [(1.4, 0.3, 550.0)])
        r = scan()
        check("…and reloaded when its file changes",
              r["changed"] == [cons] and r["reloaded_objects"] == 1
              and approx(obj(g_cons)["file_duration"], 1.4), str(r))
        cmd("project.save")
        cmd("project.new")                                              # the project is CLOSED…
        settle()
        rewrite_with(ext, [(1.7, 0.3, 330.0)])                          # …and the take is re-saved elsewhere
        reset_counters()
        cmd("project.open", path=gproj)
        settle()
        ctr = counters()
        ext_id = [o["id"] for o in cmd("object.list")["objects"] if o["file"] == ext][0]
        check("opening a project catches a file changed while it was closed (size recorded in the file)",
              approx(obj(ext_id)["file_duration"], 1.7) and ctr["file_change_reloads"] >= 1,
              str((obj(ext_id)["file_duration"], {k: v for k, v in ctr.items() if k.startswith("file_change")})))

        # ── the headless guard ──
        pid = None
        try:
            out = subprocess.check_output(["lsof", "-t", SOCK], text=True, stderr=subprocess.DEVNULL)
            pid = int(out.split()[0])
        except Exception:
            pass
        if pid is not None and not ui:
            try:
                import Quartz
                wins = [w for w in Quartz.CGWindowListCopyWindowInfo(
                    Quartz.kCGWindowListOptionAll, Quartz.kCGNullWindowID)
                    if w.get("kCGWindowOwnerPID") == pid]
                check("no window on the headless pid", len(wins) == 0, "windows=%d" % len(wins))
            except ImportError:
                print("  (skipped: Quartz is not importable)")

except Exception as e:                                   # noqa: BLE001
    import traceback
    traceback.print_exc()
    fails.append("exception: %r" % (e,))
finally:
    for r in roots:
        shutil.rmtree(r, ignore_errors=True)

print()
if fails:
    print("FAILED: %d" % len(fails))
    for f in fails:
        print(" - " + f)
    sys.exit(1)
print("ALL PASS")

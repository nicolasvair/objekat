#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The waveform cache's cold-open cost, measured — one JSON line per run, comparable across
commits (@see PLAN-WAVEFORM.md section E4, the table this script exists to fill in).

Launches a FRESH UI instance of the app per point (never `--headless` — without a Canvas
`ensureWaveformsLoaded` never fires and `waveform.preload` answers `available: false`, which
would silently measure nothing), points it at an EXISTING project, times a cold
`waveform.preload` from a wiped `waveforms/` folder, and appends one line of numbers to a
`.jsonl` log tagged with the git commit — so a run on commit A and a run on commit B are two
rows of the same file rather than two runs one has to remember by hand.

    ./bench_waveform_cache.py /path/to/objekat.app /path/to/project/session.objekat.json \\
        --label C2a

Protocol, identical at every point (this is what makes the numbers comparable):

  1. `rm -rf <project>/waveforms` — a cold cache; measuring a warm one measures a disk read.
  2. launch the app, in UI mode, on its own socket.
  3. a thread samples `ps -o rss= -p <pid>` every 100 ms and keeps the MAXIMUM.
  4. `perf.waveforms {reset: true}` — the counters are process-wide statics, zeroed here so
     this run's own numbers are not polluted by whatever `project.open` itself computes (should
     be nothing — nothing is on screen yet — but the reset makes that an observation and not an
     assumption).
  5. `project.open`, then `waveform.preload` — TOP CHRONO.
  6. poll `perf.waveforms` until `in_flight == 0` and a few consecutive polls agree — CHRONO
     STOPPED.
  7. record `wall_ms`, `mipmap_compute_seconds`, `peak_concurrency`, `rss_max_mb`,
     `du -sk waveforms/`, and the full `perf.waveforms` snapshot.

The measurement set the plan's own table was built from: the 7 large files (1.78 GB) and the
21-file / 5.3 GB project under `/Users/nicolasvair/work/LOUIE MEDIA/` (files > 50 MB) — this
script does not build that project, it only measures whatever project path it is given, so the
same project folder is reused, point after point, across commits.

For the A/B comparison of the two C1 commits (quantisation alone vs. quantisation + fewer
levels — @see PLAN-WAVEFORM.md section E5, point 7): give each build its OWN COPY of the
project folder. Two builds pointed at the same folder invalidate each other's `.wfc` on every
launch (a mismatched `formatVersion` or density array is rejected and recomputed), and the
numbers this script prints would describe that thrash, not either build on its own.

Exit: 0 if the point was measured and appended, 1 on any failure (the app not answering, the
socket never appearing, `perf.waveforms` never settling).
"""

import argparse
import json
import os
import socket as socket_module
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient


def git_sha():
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "--short", "HEAD"], cwd=HERE, text=True,
            stderr=subprocess.DEVNULL).strip()
    except Exception:
        return None


def rss_kb(pid):
    """The process's resident set, in KB, via `ps` — no dependency beyond what macOS ships."""
    try:
        out = subprocess.check_output(["ps", "-o", "rss=", "-p", str(pid)],
                                       text=True, stderr=subprocess.DEVNULL)
        return int(out.strip())
    except Exception:
        return None


class RSSSampler:
    """Polls `ps` every 100 ms on a background thread and keeps the running maximum — a
    profiler would be the honest tool, but `ps` needs no entitlement and no attach, which
    matters for a script meant to run unattended and repeatedly."""

    def __init__(self, pid, interval_s=0.1):
        self.pid = pid
        self.interval_s = interval_s
        self.max_kb = 0
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)

    def start(self):
        self._thread.start()
        return self

    def stop(self):
        self._stop.set()
        self._thread.join(timeout=2.0)

    def _run(self):
        while not self._stop.is_set():
            v = rss_kb(self.pid)
            if v is not None and v > self.max_kb:
                self.max_kb = v
            self._stop.wait(self.interval_s)


def wait_for_socket(sock_path, timeout_s=20.0):
    """Polls until the app's UNIX socket accepts a connection — the app takes a moment to boot
    AppKit and start the command server after the process itself exists."""
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if os.path.exists(sock_path):
            s = socket_module.socket(socket_module.AF_UNIX, socket_module.SOCK_STREAM)
            try:
                s.settimeout(0.2)
                s.connect(sock_path)
                s.close()
                return True
            except OSError:
                pass
            finally:
                s.close()
        time.sleep(0.05)
    return False


def wait_waveforms_idle(cmd, timeout_s=600.0, settle_polls=3):
    """Same protocol as `scenario_waveform_cache.py`'s own helper: `in_flight == 0` has to hold
    for a few consecutive polls, not just one reading, since a reading can land in the gap
    between one decode finishing and the next one starting."""
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


def du_sk(path):
    """`du -sk`'s own first column (KB), or 0 if the folder does not exist — a fresh project
    whose `waveforms/` was never created is a legitimate zero, not an error."""
    if not os.path.isdir(path):
        return 0
    try:
        out = subprocess.check_output(["du", "-sk", path], text=True, stderr=subprocess.DEVNULL)
        return int(out.split()[0])
    except Exception:
        return None


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("app_path", help="Path to objekat.app")
    ap.add_argument("project_path", help="Path to an EXISTING project's <name>.objekat.json")
    ap.add_argument("--label", default=None,
                     help="Free-form tag for this point (e.g. 'C2a', 'main'). Defaults to the "
                          "git commit sha alone.")
    ap.add_argument("--out", default=os.path.join(HERE, "bench_waveform_cache.jsonl"),
                     help="Output .jsonl (appended, one line per run).")
    ap.add_argument("--socket", default=None,
                     help="Explicit socket path (must stay under the ~104-byte UNIX limit). "
                          "Defaults to a short one under /tmp.")
    ap.add_argument("--launch-timeout", type=float, default=20.0,
                     help="Seconds to wait for the app's socket to come up.")
    ap.add_argument("--idle-timeout", type=float, default=600.0,
                     help="Seconds to wait for the waveform cache to settle before giving up.")
    args = ap.parse_args()

    if not os.path.exists(args.project_path):
        print("error: no project at %s" % args.project_path, file=sys.stderr)
        return 1

    project_dir = os.path.dirname(os.path.abspath(args.project_path))
    waveforms_dir = os.path.join(project_dir, "waveforms")

    sock_path = args.socket or os.path.join(
        tempfile.gettempdir(), "objekat-bench-%d.sock" % os.getpid())
    if len(sock_path.encode("utf-8")) >= 104:
        print("error: socket path too long for a UNIX socket: %s" % sock_path, file=sys.stderr)
        return 1
    if os.path.exists(sock_path):
        os.remove(sock_path)

    binary = os.path.join(args.app_path, "Contents", "MacOS", "objekat")
    if not os.path.exists(binary):
        print("error: no executable at %s" % binary, file=sys.stderr)
        return 1

    # ── 1. cold cache ──────────────────────────────────────────────────────
    if os.path.isdir(waveforms_dir):
        subprocess.run(["rm", "-rf", waveforms_dir], check=False)

    # ── 2. launch, UI mode — NEVER --headless (@see this file's own docstring) ──
    proc = subprocess.Popen(
        [binary, "--api", "--no-recent", "--socket=%s" % sock_path],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    sampler = None
    try:
        if not wait_for_socket(sock_path, timeout_s=args.launch_timeout):
            print("error: the app never opened its socket at %s" % sock_path, file=sys.stderr)
            return 1

        # ── 3. RSS sampling starts as soon as the process exists, not just during the decode —
        # the plan's own reference numbers (e.g. 3.76 GB) were the peak of the WHOLE run,
        # AppKit's own footprint included, not the decode's marginal cost alone.
        sampler = RSSSampler(proc.pid).start()

        with ObjekatClient(sock_path) as c:
            def cmd(_cmd_name, **params):
                return c.send(_cmd_name, params or None)

            cmd("project.new")   # a project must be open before `waveform.preload` answers at all
            available = cmd("waveform.preload").get("available")
            if available is not True:
                print("error: waveform.preload answered available=%r — this instance is "
                      "headless, or has no interface; nothing here would measure anything "
                      "(@see PLAN-WAVEFORM.md section D, pitfall 1)" % available, file=sys.stderr)
                return 1

            # ── 4. zero the counters — this run's own numbers, not whatever came before ──
            cmd("perf.waveforms", reset=True)

            # ── 5. TOP CHRONO ──
            t0 = time.time()
            cmd("project.open", path=os.path.abspath(args.project_path))
            preload = cmd("waveform.preload")
            if preload.get("available") is not True:
                print("error: waveform.preload answered available=%r after opening the "
                      "project" % preload.get("available"), file=sys.stderr)
                return 1

            # ── 6. CHRONO STOPPED once the cache is idle and stays idle ──
            stats = wait_waveforms_idle(cmd, timeout_s=args.idle_timeout)
            wall_s = time.time() - t0

        sampler.stop()

        # ── 7. record ───────────────────────────────────────────────────────
        record = {
            "sha": git_sha(),
            "label": args.label,
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "project": os.path.abspath(args.project_path),
            "preloaded_paths": preload.get("paths"),
            "wall_ms": round(wall_s * 1000, 1),
            "mipmap_compute_seconds": stats.get("mipmap_compute_seconds"),
            "disk_read_seconds": stats.get("disk_read_seconds"),
            "region_decode_seconds": stats.get("region_decode_seconds"),
            "peak_concurrency": stats.get("peak_concurrency"),
            "mipmaps_computed": stats.get("mipmaps_computed"),
            "mipmaps_read_from_disk": stats.get("mipmaps_read_from_disk"),
            "mipmaps_written": stats.get("mipmaps_written"),
            "bytes_written": stats.get("bytes_written"),
            "peak_bytes_in_memory": stats.get("peak_bytes_in_memory"),
            "rss_max_kb": sampler.max_kb,
            "rss_max_mb": round(sampler.max_kb / 1024.0, 1) if sampler.max_kb else None,
            "waveforms_dir_kb": du_sk(waveforms_dir),
            "format_version": stats.get("format_version"),
            "densities": stats.get("densities"),
            "sample_mode_threshold": stats.get("sample_mode_threshold"),
        }

    finally:
        if sampler is not None:
            sampler.stop()
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=10)
        if os.path.exists(sock_path):
            os.remove(sock_path)

    with open(args.out, "a") as f:
        f.write(json.dumps(record, ensure_ascii=False) + "\n")

    print(json.dumps(record, ensure_ascii=False, indent=2))
    print("\nappended to %s" % args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())

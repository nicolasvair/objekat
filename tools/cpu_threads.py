#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""CPU per THREAD of a running process — "is the load on one core, or spread over several?"

Plan multi-coeur, step 0 (measurement, nothing in the app changes). The question this answers: while
a project plays, how many threads of objekat are really busy, and is ONE of them (the audio thread
or a worker) pinned near 100 % — the signature of serialised work (a group's children are processed
one after the other on a single thread).

    # the app, with the audio probe if you also want the callback figures (see below)
    OBJ_AUDIO_PROBE=1 objekat.app/Contents/MacOS/objekat --api --no-recent --socket=/tmp/o.sock

    # start the playback, then sample 20 s (default: pgrep -n objekat, every 500 ms, 10 s)
    ./cpu_threads.py --duration 20
    ./cpu_threads.py --pid 12345 --interval 0.5 --threshold 20 --json /tmp/threads.json

Reads, every `--interval` seconds:
  * `libproc` (default when it answers): thread ids, thread NAMES, priority and the exact cumulative
    CPU time of each thread; the % is the delta between two samples, so it is INSTANTANEOUS.
  * `ps -M -p <pid>` (`--source ps`, or the fallback): what the plan asked for. Caveats: no thread
    id nor name (a thread is its row index, stable only while no thread is created or destroyed),
    and its %CPU column is a decaying average (a few seconds), so the % shown here is rather
    computed from the STIME+UTIME columns (10 ms resolution -> +-2 % at 500 ms).

Output: process CPU (100 % = one core), threads above `--threshold` (default 20 %) per sample (mean /
max), then per thread (mean, max, share of samples above the threshold, priority), the busiest one
first. A realtime audio thread shows priority ~97 and the name of the device's I/O thread.

Combine it with the engine's own view (same moment, same run):

    ./objekat_cli.py --socket /tmp/o.sock perf.audio_probe --action reset
    ... play, run cpu_threads.py ...
    ./objekat_cli.py --socket /tmp/o.sock perf.audio_probe --action stats   # CPU mean/p99/max, late callbacks,
                                                                            # muted blocks, worker threads, workgroup
    ./objekat_cli.py --socket /tmp/o.sock perf.census                       # `parallelism`: plugins per track / root group

A/B in ONE build (environment variables read at launch): OBJ_AUDIO_WORKGROUP=0 (no workgroup),
OBJ_AUDIO_THREADS=N (compute threads, audio thread included), OBJ_THREAD_POOL_STRATEGY=<name|0-5>.

---- Manual recipes (finer than this script; none needs Xcode open) --------------------------------

  1. `sample` — call stacks of every thread, 1 ms apart, 5 s; the file lists threads by name with the
     time they spend in each function (is a thread stuck in a plugin? waiting on a semaphore?):

         sample $(pgrep -n objekat) 5 1 -file /tmp/objekat.sample.txt

  2. Instruments / xctrace "System Trace" — WHICH core runs each thread (P vs E), when, and the
     scheduling gaps. The reference for "is the workgroup working":

         xctrace record --template 'System Trace' --attach $(pgrep -n objekat) \
                 --time-limit 10s --output /tmp/objekat.trace
         open /tmp/objekat.trace          # Instruments: "CPU" track by core, "Threads" track by thread
         xctrace export --input /tmp/objekat.trace --toc    # lists the exportable tables

     In Instruments, filter the process, expand the threads: the audio I/O thread and the worker
     threads should sit on the Performance cores, and the worker bars should line up with the audio
     thread's (same workgroup = same deadline). Without the workgroup, workers drift onto the E cores.

  3. "Time Profiler" template, same command with `--template 'Time Profiler'`: where the CPU goes,
     per function, if System Trace says a thread is saturated.

Exit: 0 on success, 2 on bad usage / process not found.
"""

import argparse
import ctypes
import ctypes.util
import json
import re
import subprocess
import sys
import time
from collections import defaultdict


# ---------------------------------------------------------------------------------------- sources

class LibprocSource:
    """proc_pidinfo(PROC_PIDLISTTHREADS / PROC_PIDTHREADINFO): ids, names, exact CPU time (ns)."""

    class _ThreadInfo(ctypes.Structure):          # struct proc_threadinfo, 112 bytes
        _fields_ = [("user", ctypes.c_uint64), ("system", ctypes.c_uint64),
                    ("cpu", ctypes.c_int32), ("policy", ctypes.c_int32),
                    ("run_state", ctypes.c_int32), ("flags", ctypes.c_int32),
                    ("sleep_time", ctypes.c_int32), ("cur_pri", ctypes.c_int32),
                    ("pri", ctypes.c_int32), ("max_pri", ctypes.c_int32),
                    ("name", ctypes.c_char * 64)]

    name = "libproc"

    def __init__(self, pid):
        path = ctypes.util.find_library("proc")
        if not path:
            raise OSError("libproc not found")
        self._lib = ctypes.CDLL(path, use_errno=True)
        self._lib.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                                           ctypes.c_void_p, ctypes.c_int]
        self.pid = pid
        if not self.sample():
            raise OSError("proc_pidinfo returned no thread (process gone, or not ours)")

    def sample(self):
        """-> {thread key: (cumulative cpu seconds, label, priority)} or {} if unreadable."""
        ids = (ctypes.c_uint64 * 2048)()
        n = self._lib.proc_pidinfo(self.pid, 6, 0, ids, ctypes.sizeof(ids))   # PROC_PIDLISTTHREADS
        out = {}
        for i in range(max(n, 0) // 8):
            info = self._ThreadInfo()
            got = self._lib.proc_pidinfo(self.pid, 5, ids[i], ctypes.byref(info),   # PROC_PIDTHREADINFO
                                         ctypes.sizeof(info))
            if got != ctypes.sizeof(info):
                continue                                   # the thread ended between the two calls
            label = info.name.decode("utf-8", "replace") or "(unnamed)"
            out[ids[i]] = ((info.user + info.system) / 1e9, label, info.pri)
        return out

    @staticmethod
    def key_label(key):
        return "tid 0x%x" % key


class PsSource:
    """`ps -M -p <pid>`: one row per thread, no id, no name -> keyed by row index."""

    name = "ps"
    _time = re.compile(r"^(?:(\d+):)?(\d+):(\d+(?:\.\d+)?)$")

    def __init__(self, pid):
        self.pid = pid
        if not self.sample():
            raise OSError("ps -M listed no thread for pid %d" % pid)

    @classmethod
    def _seconds(cls, text):
        m = cls._time.match(text)
        if not m:
            return 0.0
        h, mnt, sec = m.groups()
        return int(h or 0) * 3600 + int(mnt) * 60 + float(sec)

    def sample(self):
        res = subprocess.run(["ps", "-M", "-p", str(self.pid)], capture_output=True, text=True)
        lines = res.stdout.splitlines()[1:]                # skip the header
        out = {}
        for index, line in enumerate(lines):
            tokens = line.split()
            if not line[:1].isspace():                     # first row: USER PID TT %CPU STAT PRI STIME UTIME CMD
                if len(tokens) < 8:
                    continue
                pri, stime, utime = tokens[5], tokens[6], tokens[7]
            else:                                          # PID %CPU STAT PRI STIME UTIME
                if len(tokens) < 6:
                    continue
                pri, stime, utime = tokens[3], tokens[4], tokens[5]
            digits = re.match(r"\d+", pri)
            out[index] = (self._seconds(stime) + self._seconds(utime),
                          "(ps: no name)", int(digits.group()) if digits else 0)
        return out

    @staticmethod
    def key_label(key):
        return "row %d" % key


def find_pid(name):
    res = subprocess.run(["pgrep", "-n", "-x", name], capture_output=True, text=True)
    if res.returncode != 0 or not res.stdout.strip():
        res = subprocess.run(["pgrep", "-n", name], capture_output=True, text=True)
    return int(res.stdout.split()[0]) if res.stdout.strip() else None


# ------------------------------------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description="CPU per thread of a process (plan multi-coeur, step 0).")
    ap.add_argument("--pid", type=int, help="process id (default: the newest process called --name)")
    ap.add_argument("--name", default="objekat", help="process name for pgrep (default objekat)")
    ap.add_argument("--duration", type=float, default=10.0, help="seconds of sampling (default 10)")
    ap.add_argument("--interval", type=float, default=0.5, help="seconds between samples (default 0.5)")
    ap.add_argument("--threshold", type=float, default=20.0, help="a thread is 'busy' above this %% (default 20)")
    ap.add_argument("--source", choices=["auto", "libproc", "ps"], default="auto")
    ap.add_argument("--json", metavar="PATH", help="also write the result as JSON")
    ap.add_argument("--top", type=int, default=12, help="threads listed in the table (default 12)")
    args = ap.parse_args()

    pid = args.pid or find_pid(args.name)
    if not pid:
        print("no process called %r (launch the app, or pass --pid)" % args.name, file=sys.stderr)
        return 2

    source = None
    for cls in ([LibprocSource, PsSource] if args.source == "auto"
                else [LibprocSource] if args.source == "libproc" else [PsSource]):
        try:
            source = cls(pid)
            break
        except OSError as err:
            print("source %s unavailable: %s" % (cls.name, err), file=sys.stderr)
    if source is None:
        return 2

    print("pid %d, source %s, %.1f s every %.0f ms, busy threshold %.0f %%"
          % (pid, source.name, args.duration, args.interval * 1000, args.threshold))

    previous = source.sample()
    previous_t = time.monotonic()
    per_thread = defaultdict(lambda: {"cpu": [], "label": "", "pri": 0})
    samples = []                                           # (process %, threads above threshold)
    deadline = previous_t + args.duration
    while time.monotonic() < deadline:
        time.sleep(args.interval)
        now = source.sample()
        now_t = time.monotonic()
        dt = now_t - previous_t
        if not now or dt <= 0:
            print("process %d gone" % pid, file=sys.stderr)
            break
        total, busy = 0.0, 0
        for key, (cpu_s, label, pri) in now.items():
            before = previous.get(key)
            pct = 100.0 * max(0.0, cpu_s - before[0]) / dt if before else 0.0
            rec = per_thread[key]
            rec["cpu"].append(pct)
            rec["label"], rec["pri"] = label, pri
            total += pct
            busy += pct > args.threshold
        samples.append((total, busy))
        previous, previous_t = now, now_t

    if not samples:
        print("no sample taken", file=sys.stderr)
        return 2

    n = len(samples)
    busy_counts = [b for _, b in samples]
    totals = [t for t, _ in samples]
    rows = []
    for key, rec in per_thread.items():
        c = rec["cpu"]
        rows.append({"thread": source.key_label(key), "name": rec["label"], "priority": rec["pri"],
                     "mean_pct": sum(c) / n, "max_pct": max(c),
                     "busy_share": sum(x > args.threshold for x in c) / n})
    rows.sort(key=lambda r: r["mean_pct"], reverse=True)
    top = rows[0]
    result = {
        "pid": pid, "source": source.name, "samples": n, "interval_s": args.interval,
        "threshold_pct": args.threshold,
        "process_cpu_mean_pct": sum(totals) / n, "process_cpu_max_pct": max(totals),
        "busy_threads_mean": sum(busy_counts) / n, "busy_threads_max": max(busy_counts),
        "busy_threads_median": sorted(busy_counts)[n // 2],
        "busiest_thread": top, "threads": rows,
    }

    print("\nprocess CPU          mean %6.0f %%   max %6.0f %%   (100 %% = one core)"
          % (result["process_cpu_mean_pct"], result["process_cpu_max_pct"]))
    print("threads > %.0f %%      mean %6.2f      median %d     max %d     (of %d threads, %d samples)"
          % (args.threshold, result["busy_threads_mean"], result["busy_threads_median"],
             result["busy_threads_max"], len(rows), n))
    print("busiest thread       %s  \"%s\"  mean %.0f %%  max %.0f %%  priority %d"
          % (top["thread"], top["name"], top["mean_pct"], top["max_pct"], top["priority"]))
    print("\n  %-16s %-34s %7s %7s %7s %4s" % ("thread", "name", "mean %", "max %", "busy", "pri"))
    for r in rows[:args.top]:
        print("  %-16s %-34s %7.1f %7.1f %6.0f%% %4d"
              % (r["thread"], r["name"][:34], r["mean_pct"], r["max_pct"], 100 * r["busy_share"], r["priority"]))
    if len(rows) > args.top:
        rest = sum(r["mean_pct"] for r in rows[args.top:])
        print("  ... %d other threads, together %.1f %%" % (len(rows) - args.top, rest))

    if args.json:
        with open(args.json, "w") as f:
            json.dump(result, f, indent=2)
        print("\nwritten: %s" % args.json)
    return 0


if __name__ == "__main__":
    sys.exit(main())

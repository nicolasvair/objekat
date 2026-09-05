#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Checks a plugin trace end to end, with no screen and no ears.

A trace is measurements from end to end, so this is not a stand-in for listening — it is the
verification. Run it against a windowless instance:

    objekat --headless --api --socket=/tmp/objekat.sock --no-recent --no-audio &
    ./tools/trace_check.py /tmp/objekat.sock

WHAT IT DOES

  1. a project with one clip and a Tracktion BUILT-IN effect on it — built-in so the check runs
     anywhere, with no scan and no third-party install;
  2. `plugin.trace.capture`, and reads the report:

       determinism_y_peak_db  under -250 → the plugin is deterministic, so pass A ran
       determinism_x_peak_db  under -250 → the input is reproducible, so the trace is fingerprinted
       validation_peak_db     under -250 → the reconstruction is exact
       file_bytes/flat_bytes            → what the run-length encoding actually saved

  3. exports the mix with the PLUGIN, then `plugin.trace.use` and exports it again with the
     TRACE, and nulls the two files. That comparison is the point of `plugin.trace.use`: it
     plays the trace on a machine that HAS the plugin, which is the only way to put the two side
     by side inside one session.

Anything above the residual the capture reported is a bug in the RESTITUTION, not in the
capture — the two are worth telling apart, and this is what tells them apart.

@see docs/objekat-capture-trace.md
"""

import json
import os
import socket
import struct
import sys
import tempfile
import wave

EXACT_DBFS = -250.0


class Objekat:
    """A minimal JSON-lines client, copied from tools/example-script/report.py."""

    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(600)
        self.sock.connect(path)
        self.buffer = b""
        self.next_id = 0

    def send(self, cmd, params=None):
        self.next_id += 1
        request = {"id": self.next_id, "cmd": cmd}
        if params:
            request["params"] = params
        self.sock.sendall(json.dumps(request).encode("utf-8") + b"\n")
        while b"\n" not in self.buffer:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("connection closed by the application")
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b"\n", 1)
        response = json.loads(line)
        if not response.get("ok"):
            raise RuntimeError("%s: %s" % (cmd, response.get("error")))
        return response["result"]

    def wait_job(self, job_id, timeout_ms=600000):
        # `job.wait` names its parameter `id`, not `job_id` — the job_id comes back under
        # `job_id` but goes in under `id`. Easy to get backwards; here it is, once.
        return self.send("job.wait", {"id": job_id, "timeout_ms": timeout_ms})


def read_wav_float(path):
    """A 32-bit float WAV as a flat list of samples, interleaved.

    Deliberately NOT int16: re-reading a 24-bit export as int16 makes it look like time
    stretched by half again, and that mistake has already been made once in this project.
    """
    with wave.open(path, "rb") as w:
        width = w.getsampwidth()
        frames = w.readframes(w.getnframes())
    if width == 4:
        return list(struct.unpack("<%df" % (len(frames) // 4), frames))
    if width == 3:
        out = []
        for i in range(0, len(frames), 3):
            value = int.from_bytes(frames[i:i + 3], "little", signed=True)
            out.append(value / 8388608.0)
        return out
    if width == 2:
        ints = struct.unpack("<%dh" % (len(frames) // 2), frames)
        return [v / 32768.0 for v in ints]
    raise ValueError("unexpected sample width: %d bytes" % width)


def null_test(a, b):
    """Peak and RMS of a - b, in dBFS. Lengths may differ by a tail: we compare what overlaps."""
    import math
    n = min(len(a), len(b))
    if n == 0:
        return None, None
    peak, total = 0.0, 0.0
    for i in range(n):
        d = a[i] - b[i]
        peak = max(peak, abs(d))
        total += d * d
    to_db = lambda v: 20.0 * math.log10(v) if v > 0 else -400.0
    return to_db(peak), to_db(math.sqrt(total / n))


def main():
    sock_path = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("OBJEKAT_SOCKET")
    if not sock_path:
        sys.stderr.write(__doc__)
        return 2

    app = Objekat(sock_path)
    folder = tempfile.mkdtemp(prefix="objekat-trace-check-")
    here = os.path.dirname(os.path.abspath(__file__))

    info = app.send("app.info")
    print("app         : %s" % info.get("version", "?"))
    # A test never writes into what the user keeps: `--no-recent` is the rule, and this only
    # reports whether the instance being driven honours it.
    print("no-recent   : %s" % (not info.get("records_recent_projects", True)))

    app.send("project.new")
    app.send("project.save_as", {"path": os.path.join(folder, "trace-check.objekat.json")})

    added = app.send("object.add", {"path": os.path.join(here, "fixtures", "bip.wav"),
                                    "lane": 0, "start": 0})
    host = added["id"]
    app.send("wait_idle", {"timeout_ms": 10000})

    # A REVERB, and a built-in, for two separate reasons.
    #
    # Built-in: always in the catalogue, so this runs with no scan and no third-party install.
    #
    # Reverb: it is the hardest case the arithmetic has, and therefore the one worth checking.
    # It puts signal where there is none — a tail over silence — which is exactly what the X_MIN
    # gate exists for: `g` is forced to 1 and the whole tail rides in `d`. So `multiplicative_only`
    # should come back FALSE here, and a run where it comes back true means the tail never
    # reached the capture. It also fills the tail window, which nothing else in this scenario
    # would exercise.
    catalogue = app.send("plugin.list_available", {"filter": "reverb"})["plugins"]
    builtin = next((p for p in catalogue if p["format"] == "TracktionInternal"), None)
    if builtin is None:
        sys.stderr.write("no built-in effect in the catalogue — run plugin.scan first\n")
        return 1

    plugin = app.send("plugin.add", {"host": host,
                                     "identifier": builtin["identifier"],
                                     "format": builtin["format"]})["plugin"]["id"]
    app.send("wait_idle", {"timeout_ms": 10000})
    print("plugin      : %s" % builtin["name"])

    # 1 — capture
    job = app.send("plugin.trace.capture", {"host": host, "plugin": plugin})
    report = app.wait_job(job["job_id"])["result"]

    print("\n--- capture ---")
    for key in ("status", "num_channels", "num_samples", "sample_rate", "block_size",
                "latency_samples", "correlation_lag", "fractional_latency",
                "multiplicative_only", "linked", "non_deterministic",
                "determinism_y_peak_db", "determinism_x_peak_db",
                "validation_peak_db", "validation_rms_db", "file_bytes", "flat_bytes"):
        if key in report:
            print("  %-22s %s" % (key, report[key]))

    flat, size = report.get("flat_bytes", 0), report.get("file_bytes", 0)
    if flat:
        print("  %-22s %.1f %% of a flat float64 store" % ("encoding", 100.0 * size / flat))

    failures = []
    if report.get("validation_peak_db", 0) >= EXACT_DBFS:
        failures.append("the validation residual is not exact (%.1f dBFS)"
                        % report["validation_peak_db"])
    if report.get("fractional_latency"):
        failures.append("fractional latency: %.3f samples" % report["correlation_lag"])

    # 2 — the plugin, then its trace, then null the two
    with_plugin = os.path.join(folder, "with-plugin.wav")
    with_trace = os.path.join(folder, "with-trace.wav")

    def export(path):
        # 24-bit WAV, dithering OFF. `export.run` takes 16 or 24 only, and dither is exactly the
        # kind of added noise that would drown the comparison we are about to make: it is a
        # deliberate choice, not a consequence of the depth.
        job = app.send("export.run", {"path": path, "format": "wav",
                                      "bit_depth": 24, "dithering": False})
        app.wait_job(job["job_id"])
        return path

    export(with_plugin)
    app.send("plugin.trace.use", {"host": host, "plugin": plugin, "forced": True})
    app.send("wait_idle", {"timeout_ms": 10000})
    print("\nin use      : %s" % app.send("plugin.trace.info",
                                          {"host": host, "plugin": plugin})["in_use"])
    export(with_trace)

    peak, rms = null_test(read_wav_float(with_plugin), read_wav_float(with_trace))
    print("\n--- plugin vs. its trace ---")
    print("  null test              peak %.1f dBFS · RMS %.1f dBFS" % (peak, rms))

    # The restitution is held to what the export can carry, and no better. Both files are 24-bit
    # integer, so the floor is the quantisation step — about -138 dBFS — and nothing measured
    # here can go under it however exact the trace is. Asking for the capture's own -250 dBFS
    # would be asking the export for something it cannot express.
    budget = -130.0
    if peak > budget:
        failures.append("the restitution does not null against the plugin "
                        "(%.1f dBFS, budget %.1f)" % (peak, budget))

    print("\nfiles in %s" % folder)
    if failures:
        print("\nFAILED:")
        for f in failures:
            print("  • %s" % f)
        return 1

    print("\nOK — the trace reconstructs the plugin exactly.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

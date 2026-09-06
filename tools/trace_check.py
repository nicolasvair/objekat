#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Checks a plugin trace end to end, with no screen and no ears.

A trace is measurements from end to end, so this is not a stand-in for listening — it is the
verification. Run it against a windowless instance:

    objekat --headless --api --socket=/tmp/objekat.sock --no-recent --no-audio &
    ./tools/trace_check.py /tmp/objekat.sock            # a compressor (multiplicative)
    ./tools/trace_check.py /tmp/objekat.sock reverb     # a reverb (additive: a tail over silence)

WHAT IT DOES

  1. a project with one clip and a Tracktion BUILT-IN effect on it — built-in so the check runs
     anywhere, with no scan and no third-party install. Which one is the second argument
     (`compressor` by default, `reverb` for the additive case);
  2. `plugin.trace.capture`, and reads the report:

       determinism_y_peak_db  under -250 → the plugin is deterministic, so pass A ran
       determinism_x_peak_db  under -250 → the input is reproducible, so the trace is fingerprinted
       fixed_gain             the plugin's own broadband gain, factored out of g
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
    # Which built-in to trace. `compressor` is the default: see the comment at the choice below.
    want = sys.argv[2] if len(sys.argv) > 2 else "compressor"

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

    # A BUILT-IN, so this runs with no scan and no third-party install. WHICH built-in is the
    # second argument, because the two interesting cases do not test the same thing:
    #
    #   compressor (the default) — a gain that MOVES with the signal and nothing else. It is the
    #     multiplicative case in its pure form. What it exercises is `g[n]` as a signal, sample
    #     by sample, and what it should show is an encoding of a few percent of the flat store.
    #     `multiplicative_only` does NOT come back true any more, and that is expected: `d` is
    #     now computed as `y - g·x` in every branch rather than assumed zero, so it holds the
    #     handful of samples where the division does not round back exactly. That is the price
    #     of a validation residual that measures the codec instead of measuring float64.
    #
    #   reverb — the additive case: it puts signal where there is none, a tail over silence,
    #     which is what the X_MIN gate exists for (`g` forced to 1, the tail riding in `d`).
    #     `multiplicative_only` should come back FALSE, and a run where it comes back true means
    #     the tail never reached the capture.
    catalogue = app.send("plugin.list_available", {"filter": want})["plugins"]
    builtin = next((p for p in catalogue
                    if p["format"] == "TracktionInternal" and p["identifier"] == want), None)
    if builtin is None:
        sys.stderr.write("no built-in '%s' in the catalogue — run plugin.scan first\n" % want)
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
                "fixed_gain",
                "latency_samples", "correlation_lag", "fractional_latency",
                "multiplicative_only", "linked", "non_deterministic",
                "determinism_y_peak_db", "determinism_x_peak_db",
                "validation_peak_db", "validation_rms_db", "file_bytes", "flat_bytes"):
        if key in report:
            print("  %-22s %s" % (key, report[key]))

    flat, size = report.get("flat_bytes", 0), report.get("file_bytes", 0)
    if flat:
        print("  %-22s %.1f %% of a flat float64 store" % ("encoding", 100.0 * size / flat))

    failures, warnings = [], []
    if report.get("validation_peak_db", 0) >= EXACT_DBFS:
        failures.append("the validation residual is not exact (%.1f dBFS)"
                        % report["validation_peak_db"])
    # A fractional lag is REPORTED, never a failure — the engine takes the same line, and says so
    # where it measures it (@see objtrace::correlationLag). The affine model is exact whatever the
    # alignment, so what a real misalignment costs is the trace's weight, not its exactness; and
    # this run has a far stronger alignment verdict a few lines below, in the null test against
    # the plugin itself.
    #
    # On this fixture the measurement is degenerate anyway, and worth knowing about before
    # believing it: bip.wav is a pure 440 Hz sine, so at 44.1 kHz its period is 100.2 samples —
    # and the correlation is taken in ABSOLUTE value, which makes every half period a tied
    # maximum (an anti-phase peak scores exactly as high as an in-phase one). The 250.6 samples
    # it comes back with are 2.501 periods: a tie broken at random, not a latency.
    if report.get("fractional_latency"):
        warnings.append("fractional lag measured: %.3f samples (on a pure tone, see the note in "
                        "the source — the null test below is the alignment verdict)"
                        % report["correlation_lag"])

    # 2 — the plugin, then its trace, then null the two
    with_plugin = os.path.join(folder, "with-plugin.wav")
    with_trace = os.path.join(folder, "with-trace.wav")

    # AT THE TRACE'S OWN SAMPLE RATE, and this is not a detail. `g[n]` and `d[n]` are SIGNALS,
    # not curves: a trace read at any other rate describes nothing, and the restitution node
    # refuses to play it (it goes transparent — @see OBJTracePlaybackPlugin::isUsableAt). Export
    # at the wrong rate and the comparison below measures "the plugin against no plugin at all",
    # which looks exactly like a broken restitution and is not one.
    #
    # The two defaults have no reason to agree on their own: the capture takes the device's rate
    # and falls back to 48000 with no device, while `export.run` defaults to 44100. So we ask.
    rate = report.get("sample_rate") or 44100

    def export(path):
        # 24-bit WAV, dithering OFF. `export.run` takes 16 or 24 only, and dither is exactly the
        # kind of added noise that would drown the comparison we are about to make: it is a
        # deliberate choice, not a consequence of the depth.
        job = app.send("export.run", {"path": path, "format": "wav", "sample_rate": rate,
                                      "bit_depth": 24, "dithering": False})
        app.wait_job(job["job_id"])
        return path

    export(with_plugin)
    app.send("plugin.trace.use", {"host": host, "plugin": plugin, "forced": True})
    app.send("wait_idle", {"timeout_ms": 10000})
    print("\nexport rate : %g Hz (the trace's own)" % rate)
    print("in use      : %s" % app.send("plugin.trace.info",
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
    if warnings:
        print("\nWARNINGS:")
        for w in warnings:
            print("  • %s" % w)
    if failures:
        print("\nFAILED:")
        for f in failures:
            print("  • %s" % f)
        return 1

    print("\nOK — the trace reconstructs the plugin exactly.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

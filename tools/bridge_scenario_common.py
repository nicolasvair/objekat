# -*- coding: utf-8 -*-
"""What the two audio-bridge scenarios share (stdlib only): the fixtures they generate, a reader for
the 24-bit exports they make, and the small bookkeeping of a scenario (`step`, `check`).

Fixtures are GENERATED, never committed: 48 kHz, 24-bit, mono, so that a sample index means the same
thing in the file, in the engine and in the assertion (docs/plan_sidechain.md §6, step 1.12).
"""

import json, math, os, subprocess, sys, wave

SR = 48000


def _write24(path, samples):
    """`samples`: floats in [-1, 1]. 24-bit PCM written by hand (`wave` takes bytes)."""
    raw = bytearray()
    for v in samples:
        n = max(-8388608, min(8388607, int(round(v * 8388607.0))))
        raw += int(n).to_bytes(3, "little", signed=True)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(3)
        w.setframerate(SR)
        w.writeframes(bytes(raw))


def make_impulse(path, seconds=3.0, at=SR):
    """One sample at 0.9, at index `at` (1 s by default), silence elsewhere."""
    n = int(seconds * SR)
    s = [0.0] * n
    s[at] = 0.9
    _write24(path, s)


def make_sine(path, seconds=4.0, hz=220.0, dbfs=-12.0):
    a = 10.0 ** (dbfs / 20.0)
    _write24(path, [a * math.sin(2 * math.pi * hz * i / SR) for i in range(int(seconds * SR))])


def make_bursts(path, seconds=4.0, hz=1000.0, dbfs=-3.0, windows=((1.0, 1.5), (2.5, 3.0))):
    """1 kHz bursts at the given windows (seconds), silence elsewhere."""
    a = 10.0 ** (dbfs / 20.0)
    n = int(seconds * SR)
    s = [0.0] * n
    for lo, hi in windows:
        for i in range(int(lo * SR), min(n, int(hi * SR))):
            s[i] = a * math.sin(2 * math.pi * hz * i / SR)
    _write24(path, s)


def read_wav(path):
    """The channels of a PCM WAV as lists of floats in [-1, 1] (16 or 24 bits)."""
    with wave.open(path, "rb") as w:
        ch, sw, n, raw = w.getnchannels(), w.getsampwidth(), w.getnframes(), w.readframes(w.getnframes())
    if sw not in (2, 3):
        raise RuntimeError("unexpected sample width: %d" % sw)
    scale = 32768.0 if sw == 2 else 8388608.0
    out = [[0.0] * n for _ in range(ch)]
    for i in range(n * ch):
        v = int.from_bytes(raw[i * sw:(i + 1) * sw], "little", signed=True)
        out[i % ch][i // ch] = v / scale
    return out


def rms(samples, t0, t1):
    a, b = int(t0 * SR), int(t1 * SR)
    seg = samples[a:b]
    return math.sqrt(sum(v * v for v in seg) / len(seg)) if seg else 0.0


def tone_rms(samples, t0, t1, hz):
    """RMS of the component of the segment at `hz` (a single-bin correlation, in-phase and quadrature)."""
    a, b = int(t0 * SR), int(t1 * SR)
    seg = samples[a:b]
    if not seg:
        return 0.0
    w = 2.0 * math.pi * hz / SR
    re = sum(v * math.cos(w * (a + i)) for i, v in enumerate(seg))
    im = sum(v * math.sin(w * (a + i)) for i, v in enumerate(seg))
    return math.sqrt(2.0) * math.hypot(re, im) / len(seg)


def db(x):
    return 20.0 * math.log10(max(x, 1e-12))


def peak_index(samples):
    """Index of the largest magnitude (the first one on a tie), or None for silence."""
    best, idx = 0.0, None
    for i, v in enumerate(samples):
        if abs(v) > best:
            best, idx = abs(v), i
    return idx if best > 1e-6 else None


def pid_for_socket(sock_path):
    try:
        out = subprocess.check_output(["lsof", "-t", sock_path], text=True, stderr=subprocess.DEVNULL)
        pids = [int(p) for p in out.split()]
        return pids[0] if pids else None
    except Exception:
        return None


def window_count_for_pid(pid):
    """Windows the process owns, off the WindowServer's list. None if Quartz is not there."""
    try:
        import Quartz
    except ImportError:
        return None
    info = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionAll, Quartz.kCGNullWindowID)
    return sum(1 for w in info if w.get("kCGWindowOwnerPID") == pid)


def require_audio(client):
    """The bridge's clock is the device's: with `--no-audio` there is none. Exit 2 with one line."""
    info = client.send("app.info")
    if not info.get("audio_running"):
        print("this scenario needs the audio device running: launch the app without --no-audio "
              "(app.info.audio_running is false)")
        sys.exit(2)


class Tally:
    """`step` runs a command and records it, `check` records a condition."""

    def __init__(self, error_type):
        self.ok = 0
        self.ko = 0
        self._err = error_type

    def step(self, label, fn):
        try:
            r = fn()
            self.ok += 1
            print("  OK   %-52s %s" % (label, json.dumps(r, ensure_ascii=False)[:110]))
            return r
        except self._err as e:
            self.ko += 1
            print("  FAIL %-52s %s" % (label, e.args[0]))
            return None

    def check(self, label, cond, detail=""):
        if cond:
            self.ok += 1
            print("  OK   %-52s" % label)
        else:
            self.ko += 1
            print("  FAIL %-52s %s" % (label, detail))

    def expect_error(self, label, fn, code=None, reason=None):
        """The command must be refused; optionally with that code and `details.reason`."""
        try:
            fn()
        except self._err as e:
            good = (code is None or e.code == code) and \
                   (reason is None or (e.details or {}).get("reason") == reason)
            self.check(label, good, "%s %s" % (e.code, e.details))
            return
        self.check(label, False, "it was accepted")

    def finish(self):
        print("\n=== %d OK, %d FAILED ===" % (self.ok, self.ko))
        return 1 if self.ko else 0

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Retouche 2026-11-15 — a WAV carrying an `acid` chunk with a ROOT NOTE must not crash the engine.

The bug ("Guiro Piola 1.wav"): `ClipOwner::getClipDefaults` / `ClipOwner::insertClip` set
`autoPitch = true` on any clip whose file has a loop-info root note (`loopInfo.getRootNote() != -1`).
`configureFreshClip` used to cancel `autoTempo` but not `autoPitch`: `EditNodeBuilder` then built a
`PitchAdjustReader` (SyncPitch::yes) on a time-stretch reader that does not exist (no time-stretch
library is compiled in) — a null dereference on the first render (SingleInputAudioReader::getNumChannels).

The fix: `clip->setAutoPitch(false)` next to `setAutoTempo(false)` in `configureFreshClip`.

The scenario generates, with no dependency, 16-bit mono 48 kHz sines at 440 Hz carrying:

    acid_root57     acid chunk, flags 0x02 (root note set), root 57
    acid_noroot     acid chunk, flags 0x00
    acid_oneshot    acid chunk, flags 0x03 (one-shot + root note), root 57
    aiff_root       an AIFF with an Apple `basc` chunk, root note 57

and, when it exists on this machine, the real "Guiro Piola 1.wav" (copied to a temp folder).

For each one: `object.add` then `export.run` — the process stays alive, the sine stays at 440 Hz
(NO transposition) and the audible length is the file's length. Then, on the files with a root note:
a cut + export, a duplicate + export, save / close / reopen + export, undo / redo + export.

It launches ITS OWN instance (`--headless --api --no-audio --no-recent`) on its own socket.

    ./scenario_acid_loopinfo.py /path/to/objekat.app

Exit: 0 if every assertion passes, 1 otherwise, 2 on bad usage.
"""

import math, os, shutil, struct, subprocess, sys, tempfile, time, wave

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

if len(sys.argv) != 2:
    print(__doc__)
    sys.exit(2)

APP = sys.argv[1]
BIN = os.path.join(APP, "Contents", "MacOS", "objekat")
if not os.path.exists(BIN):
    print("not an app bundle: %s" % APP)
    sys.exit(2)

WORK = tempfile.mkdtemp(prefix="objacid_", dir="/tmp")   # short: a UNIX socket path is capped at ~103 bytes
SOCK = os.path.join(WORK, "s.sock")
RATE = 48000
SECS = 2.0
FREQ = 440.0
ok, ko = 0, 0

GUIRO_CANDIDATES = [
    "/Users/nicolasvair/Sons/Samples/Drums Sample/0 - Drum Kits/ CUMBIA/Pack Cumbia Villera/Guiro Piola 1.wav",
    "/Users/nicolasvair/Sons/Samples/Drums Sample/0 - Drum Kits/ CUMBIA/MegaCumbiaPack2017/ONE SHOTS/Guiro/Guiro Piola 1.wav",
]


def section(title):
    print("\n── %s " % title + "─" * max(4, 74 - len(title)))


def check(label, cond, detail=""):
    global ok, ko
    if cond:
        ok += 1
        print("  OK   %s" % label)
    else:
        ko += 1
        print("  FAIL %s   %s" % (label, detail))


# ───────────────────────────────────────────────────────────────────── file writers
def sine_pcm16(seconds=SECS):
    n = int(seconds * RATE)
    return b"".join(struct.pack("<h", int(round(0.5 * 32767 * math.sin(2 * math.pi * FREQ * i / RATE))))
                    for i in range(n))


def write_wav_with_acid(path, flags, root):
    """RIFF/WAVE, 16-bit mono 48 kHz, then an `acid` chunk (24 bytes) AFTER the data chunk."""
    pcm = sine_pcm16()
    fmt = struct.pack("<HHIIHH", 1, 1, RATE, RATE * 2, 2, 16)
    # flags, rootNote, reserved1, reserved2, numBeats, meterDenominator, meterNumerator, tempo
    acid = struct.pack("<IHHfIHHf", flags, root, 0x8000, 0.0, 4, 4, 4, 120.0)
    body = (b"WAVE"
            + b"fmt " + struct.pack("<I", len(fmt)) + fmt
            + b"data" + struct.pack("<I", len(pcm)) + pcm
            + b"acid" + struct.pack("<I", len(acid)) + acid)
    with open(path, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", len(body)) + body)


def write_aiff_with_root(path, root):
    """AIFF, 16-bit mono 48 kHz, plus an Apple `basc` chunk (84 bytes) holding the root note."""
    n = int(SECS * RATE)
    pcm = b"".join(struct.pack(">h", int(round(0.5 * 32767 * math.sin(2 * math.pi * FREQ * i / RATE))))
                   for i in range(n))
    ext48000 = bytes([0x40, 0x0E, 0xBB, 0x80, 0, 0, 0, 0, 0, 0])   # 80-bit IEEE extended, 48000 Hz
    comm = struct.pack(">hIh", 1, n, 16) + ext48000
    ssnd = struct.pack(">II", 0, 0) + pcm
    # flags, numBeats, rootNote, key, timeSigNum, timeSigDen, oneShot, then padding up to 84 bytes
    basc = struct.pack(">IIHHHHH", 0, 4, root, 2, 4, 4, 1)
    basc += b"\x00" * (84 - len(basc))
    body = (b"AIFF"
            + b"COMM" + struct.pack(">I", len(comm)) + comm
            + b"basc" + struct.pack(">I", len(basc)) + basc
            + b"SSND" + struct.pack(">I", len(ssnd)) + ssnd)
    with open(path, "wb") as f:
        f.write(b"FORM" + struct.pack(">I", len(body)) + body)


def read_wav(path):
    """(rate, left channel as floats) of a 24-bit stereo WAV."""
    with wave.open(path, "rb") as w:
        assert w.getsampwidth() == 3 and w.getnchannels() == 2, (w.getsampwidth(), w.getnchannels())
        rate = w.getframerate()
        raw = w.readframes(w.getnframes())
    n = len(raw) // 6
    left = [int.from_bytes(raw[i * 6:i * 6 + 3], "little", signed=True) / 8388608.0 for i in range(n)]
    return rate, left


def analyse(path):
    """(active seconds, frequency in Hz over the active zone, peak) of the left channel."""
    rate, left = read_wav(path)
    active = [i for i, v in enumerate(left) if abs(v) > 1e-3]
    if not active:
        return 0.0, 0.0, 0.0
    a, b = active[0], active[-1]
    seg = left[a:b + 1]
    crossings = sum(1 for i in range(1, len(seg)) if seg[i - 1] <= 0.0 < seg[i])
    dur = (b - a + 1) / float(rate)
    return dur, crossings / dur, max(abs(v) for v in seg)


# ───────────────────────────────────────────────────────────────────── the files
FILES = {}   # name -> (path, has_root_note, expected_freq or None)
p = os.path.join(WORK, "acid_root57.wav");    write_wav_with_acid(p, 0x02, 57); FILES["acid_root57"] = (p, True, FREQ)
p = os.path.join(WORK, "acid_noroot.wav");    write_wav_with_acid(p, 0x00, 0);  FILES["acid_noroot"] = (p, False, FREQ)
p = os.path.join(WORK, "acid_oneshot.wav");   write_wav_with_acid(p, 0x03, 57); FILES["acid_oneshot"] = (p, True, FREQ)
p = os.path.join(WORK, "aiff_root.aiff");     write_aiff_with_root(p, 57);      FILES["aiff_root"] = (p, True, FREQ)
for cand in GUIRO_CANDIDATES:
    if os.path.exists(cand):
        p = os.path.join(WORK, "Guiro Piola 1.wav")
        shutil.copyfile(cand, p)
        FILES["guiro_piola_real"] = (p, True, None)
        break

LOG = os.path.join(WORK, "app.log")
logf = open(LOG, "wb")
proc = subprocess.Popen([BIN, "--headless", "--api", "--no-audio", "--no-recent",
                         "--language=en", "--socket=" + SOCK],
                        stdout=logf, stderr=subprocess.STDOUT)


def alive():
    return proc.poll() is None


try:
    for _ in range(160):
        if os.path.exists(SOCK):
            break
        time.sleep(0.25)
    else:
        print("the app did not open its socket")
        proc.kill()
        sys.exit(1)

    with ObjekatClient(SOCK) as c:
        send = c.send
        send("app.set_dialog_policy", {"policy": "assume_yes"})

        exports = {"n": 0}

        def render(tag, end=3.0):
            exports["n"] += 1
            path = os.path.join(WORK, "out_%02d_%s.wav" % (exports["n"], tag))
            r = send("export.run", {"format": "wav", "sample_rate": 48000, "bit_depth": 24,
                                    "dithering": False, "start": 0.0, "end": end, "path": path})
            send("job.wait", {"id": r["job_id"], "timeout_ms": 120000})
            return analyse(path)

        def fresh(name):
            send("project.new")
            manifest = os.path.join(WORK, name + ".objekat")
            send("project.save_as", {"path": manifest})
            return manifest

        def expect_sine(label, got, secs, freq=FREQ):
            dur, f, peak = got
            check("%s: alive" % label, alive())
            check("%s: audible length %.2f s" % (label, secs), abs(dur - secs) < 0.02, "%.4f s" % dur)
            if freq:
                check("%s: %.0f Hz, no transposition" % (label, freq), abs(f - freq) < freq * 0.01, "%.2f Hz" % f)
            check("%s: not silent (peak %.2f)" % (label, peak), peak > 0.2, peak)

        # ══════════════════════════════════════════════════════ add + export, every file
        section("add + export: the process lives, 440 Hz stays 440 Hz")
        for name, (path, has_root, freq) in FILES.items():
            fresh("add_" + name)
            try:
                oid = send("object.add", {"path": path, "lane": 0, "start": 0.0})["id"]
                got = render("add_" + name)
            except Exception as e:
                check("%s: add + export went through" % name, False, "%s: %r (process alive: %s)" % (type(e).__name__, e, alive()))
                if not alive():
                    print("  the process died with code %s — the rest cannot run" % proc.returncode)
                    raise SystemExit(1)
                continue
            if freq:
                expect_sine(name, got, SECS, freq)
            else:
                check("%s: alive" % name, alive())
                check("%s: not silent (peak %.2f)" % (name, got[2]), got[2] > 0.01, got)
            g = send("object.get", {"id": oid})
            check("%s: object duration = the file's" % name,
                  freq is None or abs(g.get("duration", SECS) - SECS) < 0.01, g.get("duration"))

        # ══════════════════════════════════════════════════════ the operations, files with a root note
        for name, (path, has_root, freq) in FILES.items():
            if not has_root or not freq:
                continue
            section("operations on %s" % name)

            # cut -> export, then undo
            fresh("cut_" + name)
            oid = send("object.add", {"path": path, "lane": 0, "start": 0.0})["id"]
            cut = send("object.split_at", {"seconds": 1.0, "ids": [oid]})
            check("%s: the cut made two pieces" % name, len(cut["ids"]) == 2, cut)
            expect_sine("%s after the cut" % name, render("cut_" + name), SECS)
            send("edit.undo")
            expect_sine("%s after undo of the cut" % name, render("cut_undo_" + name), SECS)

            # duplicate
            fresh("dup_" + name)
            oid = send("object.add", {"path": path, "lane": 0, "start": 0.0})["id"]
            d = send("object.duplicate", {"ids": [oid]})
            check("%s: duplicate made one copy" % name, d["count"] == 1, d)
            dur, f, peak = render("dup_" + name, end=5.0)
            check("%s: alive after duplicate + export" % name, alive())
            check("%s: duplicate, 440 Hz" % name, abs(f - freq) < freq * 0.01, f)
            check("%s: duplicate, two clips back to back or stacked (>= %.2f s audible)" % (name, SECS),
                  dur >= SECS - 0.02, dur)

            # save / reopen
            manifest = fresh("reopen_" + name)
            oid = send("object.add", {"path": path, "lane": 0, "start": 0.0})["id"]
            send("project.save")
            send("project.new")
            send("project.open", {"path": manifest})
            send("wait_idle", {"timeout_ms": 60000})
            expect_sine("%s after save + reopen" % name, render("reopen_" + name), SECS)

            # undo / redo of the add
            fresh("undo_" + name)
            oid = send("object.add", {"path": path, "lane": 0, "start": 0.0})["id"]
            send("edit.undo")
            listed = send("object.list")
            n_objs = len(listed.get("objects", listed.get("items", []))) if isinstance(listed, dict) else len(listed)
            check("%s: after undo of the add, the project is empty" % name, n_objs == 0, listed)
            check("%s: alive after the undo" % name, alive())
            send("edit.redo")
            expect_sine("%s after redo" % name, render("redone_" + name), SECS)

    # the process must still be alive at the end
    section("end")
    check("the process survived the whole scenario", alive(), "return code %s" % proc.returncode)
except SystemExit:
    pass
except Exception as e:
    check("scenario ran to the end", False, "%s: %r (process alive: %s, code %s)" % (type(e).__name__, e, alive(), proc.returncode))
finally:
    if proc.poll() is not None:   # it died: say how, and show the last lines of its journal
        print("\n  the application exited with code %s; end of its journal:" % proc.returncode)
        try:
            with open(LOG, "rb") as f:
                for line in f.read().decode("utf-8", "replace").splitlines()[-12:]:
                    print("    | " + line)
        except Exception:
            pass
    try:
        proc.terminate()
        proc.wait(timeout=20)
    except Exception:
        proc.kill()
    shutil.rmtree(WORK, ignore_errors=True)

print("\n%d ok, %d failed" % (ok, ko))
print("ALL PASS" if ko == 0 else "FAILURES")
sys.exit(0 if ko == 0 else 1)

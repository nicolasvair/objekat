#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""FLAC as an ARCHIVE format, not as a render format.

Internal renders (consolidations, bakes) are 32-bit float WAVs again, so nothing ever clips in silence.
FLAC lives at two doors only, both lossless by construction:

  A  a consolidation writes a `.wav` in 32-bit FLOAT (format tag 3), a level above 0 dBFS is kept as it
     is (no clipping), and no « clipped » dialogue is raised any more;
  B  the FLAC export renders a WAV first and converts it: once decoded it is SAMPLE-FOR-SAMPLE the WAV
     export of the same range (24 and 16 bits, 96 kHz), no intermediate file is left behind, and the
     render in progress can be listened to (the preview sees a growing WAV, not a FLAC with no length);
  C  `project.convert_to_flac` (the unused-files window's option): a dry run writes nothing and says
     what it would do; the real run turns the 24-bit WAV source and the float render under 0 dBFS into
     FLACs (the first bit-exact, the second within one 24-bit step), LEAVES the float render that goes
     past 0 dBFS as a WAV and says why, never touches a file outside the project folder, never deletes
     an original, marks the project modified, re-aims the clips AND the consolidated definition, plays
     the same mix afterwards (export compared sample for sample), survives a save and a reopening, and
     leaves the old WAVs to the existing clean-up.

    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --language=en --socket=/tmp/f.sock
    ./scenario_flac_archive.py /tmp/f.sock

KNOWN FAILURE (18 October 2026), C3/C5: the FLACs read back EQUAL to their WAVs (CoreAudio, and the converter's
own verification), yet the engine PLAYS a FLAC 2 samples later than the same WAV — measured on a FLAC written
by CoreAudio AND on one written by JUCE (`render_isolated` into `.flac`), so it is the reading side, not the
converter. The archive therefore shifts the converted objects by 2 samples; C3/C5 say so, with the measured lag.

Decoding goes through `afconvert` (CoreAudio).
Exit: 0 if every assertion passes, 1 otherwise.
"""

import array, hashlib, math, os, shutil, struct, subprocess, sys, tempfile, time, wave

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

args = [a for a in sys.argv[1:] if not a.startswith("--")]
KEEP = "--keep" in sys.argv
if len(args) != 1:
    print(__doc__)
    sys.exit(2)

SOCK = args[0]
BIP = os.path.join(HERE, "fixtures", "bip.wav")     # 0.4 s tone, peak 0.549
ROOT = os.path.realpath(tempfile.mkdtemp(prefix="objk-flacarch-", dir="/tmp"))
STEP24 = 1.0 / 8388608.0
fails = []


def check(label, ok, detail=""):
    if ok:
        print("ok    " + label)
    else:
        fails.append(label)
        print("FAIL  %s  %s" % (label, detail))


def section(title):
    print("\n── %s " % title + "─" * max(0, 70 - len(title)))


def near(a, b, tol=1e-3):
    return a is not None and b is not None and abs(a - b) <= tol


# ── files ────────────────────────────────────────────────────────────────────────────────────

def magic(path):
    with open(path, "rb") as f:
        return f.read(4)


def sha(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()


def wav_fmt(path):
    """(format tag, bits) of a RIFF wave: tag 1 = integer PCM, 3 = IEEE float."""
    d = open(path, "rb").read()
    i = 12
    while i < len(d):
        cid = d[i:i + 4]
        sz = struct.unpack("<I", d[i + 4:i + 8])[0]
        if cid == b"fmt ":
            tag, _ch, _sr, _br, _ba, bits = struct.unpack("<HHIIHH", d[i + 8:i + 24])
            return tag, bits
        i += 8 + sz + (sz & 1)
    return None, None


def read_wav(path):
    """(channels, sample_rate, samples) of a PCM 16/24 or float32 wav."""
    d = open(path, "rb").read()
    i, fmt, data = 12, None, None
    while i < len(d):
        cid = d[i:i + 4]
        sz = struct.unpack("<I", d[i + 4:i + 8])[0]
        if cid == b"fmt ":
            fmt = struct.unpack("<HHIIHH", d[i + 8:i + 24])
        elif cid == b"data":
            data = d[i + 8:i + 8 + sz]
        i += 8 + sz + (sz & 1)
    tag, ch, sr, _, _, bits = fmt
    if tag == 3:
        a = array.array("f"); a.frombytes(data); s = list(a)
    elif bits == 24:
        s = [int.from_bytes(data[j:j + 3], "little", signed=True) / 8388608.0 for j in range(0, len(data), 3)]
    elif bits == 16:
        a = array.array("h"); a.frombytes(data); s = [x / 32768.0 for x in a]
    else:
        a = array.array("f"); a.frombytes(data); s = list(a)
    return ch, sr, s


def read_audio(path):
    """Like read_wav, for a `.flac` too (decoded by afconvert into 32-bit float, exact for 16/24 bits)."""
    if not path.endswith(".flac"):
        return read_wav(path)
    tmp = tempfile.mkdtemp(prefix="objk-dec-", dir="/tmp")
    try:
        out = os.path.join(tmp, "d.wav")
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEF32", path, out], check=True)
        return read_wav(out)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def flac_bits(path):
    """The bit depth the FLAC declares (afinfo: 'source bit depth: I24')."""
    out = subprocess.run(["afinfo", path], capture_output=True, text=True).stdout
    for line in out.splitlines():
        if "source bit depth" in line:
            return int(line.split(":")[1].strip().lstrip("I").lstrip("F"))
    return None


def peak(snd, t0=0.0, t1=None):
    ch, sr, s = snd
    i0 = int(t0 * sr) * ch
    i1 = len(s) if t1 is None else min(len(s), int(t1 * sr) * ch)
    return max((abs(x) for x in s[max(0, i0):i1]), default=0.0)


def maxdiff(a, b):
    if a[0] != b[0] or a[1] != b[1] or len(a[2]) != len(b[2]):
        return 1e9
    return max((abs(x - y) for x, y in zip(a[2], b[2])), default=0.0)


def best_lag(a, b, t0, t1, span=8):
    """(lag in samples, max diff) that best aligns `b` on `a` over [t0, t1), channel 0. A diagnosis:
    a FLAC that reads back equal but PLAYS shifted shows here as a non-zero lag with a tiny diff."""
    ch, sr, sa = a
    sb = b[2]
    i0, i1 = int(t0 * sr), int(t1 * sr)
    best = None
    for lag in range(-span, span + 1):
        if i0 + lag < 0 or (i1 + lag) * ch > len(sb):
            continue
        e = max(abs(sa[i * ch] - sb[(i + lag) * ch]) for i in range(i0, i1))
        if best is None or e < best[1]:
            best = (lag, e)
    return best


def write_tone(path, bits, rate, seconds, amp, channels=2):
    """A deterministic tone + noise, integer PCM at `bits` (16 or 24)."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    n = int(rate * seconds)
    seed = 12345
    frames = bytearray()
    scale = (1 << (bits - 1)) - 1
    for i in range(n):
        seed = (seed * 1664525 + 1013904223) & 0xFFFFFFFF
        noise = ((seed >> 8) / float(1 << 24) - 0.5) * 0.2
        v = int(round(amp * (0.8 * math.sin(2 * math.pi * 440 * i / rate) + noise) * scale))
        for _ in range(channels):
            frames += v.to_bytes(bits // 8, "little", signed=True)
    with wave.open(path, "wb") as w:
        w.setnchannels(channels); w.setsampwidth(bits // 8); w.setframerate(rate)
        w.writeframes(bytes(frames))


def main(c):
    def cmd(_name, **p):
        return c.send(_name, p or None)

    def wait(r, ms=120000):
        return cmd("job.wait", id=r["job_id"], timeout_ms=ms)

    def idle():
        cmd("wait_idle", timeout_ms=60000)

    cmd("app.set_dialog_policy", policy="assume_yes")

    def export(name, fmt, rate=44100, depth=24, start=0.0, end=0.4, dith=False, **extra):
        path = os.path.join(ROOT, name)
        r = cmd("export.run", path=path, format=fmt, sample_rate=rate, bit_depth=depth,
                dithering=dith, start=start, end=end, **extra)
        j = wait(r)
        return path, j

    def dirty():
        return cmd("app.info").get("dirty")

    P = os.path.join(ROOT, "proj")
    os.makedirs(P)
    SRC24 = os.path.join(P, "samples", "sources", "tone24.wav")      # inside the project folder, 24-bit
    EXT16 = os.path.join(ROOT, "external", "ext16.wav")               # outside the project folder
    write_tone(SRC24, 24, 48000, 0.5, 0.4)
    write_tone(EXT16, 16, 44100, 0.5, 0.3)
    ext_hash = sha(EXT16)

    cmd("project.new")
    src = cmd("object.add", path=SRC24, lane=0, start=0.0)["id"]
    ext = cmd("object.add", path=EXT16, lane=1, start=0.6)["id"]
    quiet = cmd("object.add", path=BIP, lane=2, start=1.2)["id"]
    loud = cmd("object.add", path=BIP, lane=3, start=2.0)["id"]
    cmd("plugin.add_gain_stage", host=loud, face="gain", gain_db=12.0)       # +12 dB: ~ +6.8 dBFS
    cmd("project.save_as", path=os.path.join(P, "proj.objekat"))
    idle()

    # ═══ A — consolidations are float WAVs again ═════════════════════════════════════════════
    section("A — a consolidation writes a 32-bit float WAV")
    wait(cmd("consolidate.make", id=loud))
    idle()
    wait(cmd("consolidate.make", id=quiet))
    idle()
    defs = cmd("consolidate.list")["definitions"]
    check("A0 two definitions", len(defs) == 2, defs)
    by_pl = {d["placements"][0]: d for d in defs if d.get("placements")}
    dl, dq = by_pl.get(loud), by_pl.get(quiet)
    check("A0 each placement is an instance of its own definition", dl is not None and dq is not None, defs)
    cons = os.path.join(P, "samples", "consolidate")
    wl, wq = os.path.join(cons, dl["wave"]), os.path.join(cons, dq["wave"])
    check("A1 the waves are .wav", dl["wave"].endswith(".wav") and dq["wave"].endswith(".wav"), (dl["wave"], dq["wave"]))
    check("A1 real RIFF files", magic(wl) == b"RIFF" and magic(wq) == b"RIFF", (magic(wl), magic(wq)))
    check("A1 32-bit float (format tag 3)", wav_fmt(wl) == (3, 32) and wav_fmt(wq) == (3, 32), (wav_fmt(wl), wav_fmt(wq)))
    check("A1 no .flac written by a consolidation",
          not [x for x in os.listdir(cons) if x.endswith(".flac")], os.listdir(cons))
    check("A1 sidecars are named after the wave",
          os.path.isfile(os.path.join(cons, os.path.splitext(dl["wave"])[0] + "_objectstate.json")))
    pl = peak(read_wav(wl))
    check("A2 the loud render goes past 0 dBFS and is NOT clipped (peak %.2f)" % pl, pl > 1.5, pl)
    check("A2 the quiet render keeps its level (0.549)", near(peak(read_wav(wq)), 0.549, 0.01), peak(read_wav(wq)))
    dl_open = cmd("app.dialogs")["dialogs"]
    check("A3 no « clipped » dialogue any more", not any("0 dBFS" in x.get("title", "") for x in dl_open), dl_open)

    # ═══ B — the FLAC export goes through a WAV ═════════════════════════════════════════════
    section("B — the FLAC export renders a WAV, then converts it")
    END = 2.6
    wav24, j = export("b24.wav", "wav", depth=24, end=END)
    check("B0 the WAV export works (reference)", j["state"] == "done" and os.path.isfile(wav24), j)
    f24, j = export("b24.flac", "flac", depth=24, end=END)
    check("B1 FLAC 24: done, a real fLaC stream, 24 bits",
          j["state"] == "done" and os.path.isfile(f24) and magic(f24) == b"fLaC" and flac_bits(f24) == 24,
          (j, flac_bits(f24)))
    check("B1 sample for sample the WAV export", maxdiff(read_wav(wav24), read_audio(f24)) < 1e-9,
          maxdiff(read_wav(wav24), read_audio(f24)))
    wav16, _ = export("b16.wav", "wav", depth=16, end=END)
    f16, j = export("b16.flac", "flac", depth=16, end=END)
    check("B2 FLAC 16: declares 16 bits and equals the 16-bit WAV",
          j["state"] == "done" and flac_bits(f16) == 16 and maxdiff(read_wav(wav16), read_audio(f16)) < 1e-9,
          (j, flac_bits(f16)))
    f96, j = export("b96.flac", "flac", rate=96000, depth=24, end=END)
    f = read_audio(f96) if os.path.isfile(f96) else (0, 0, [])
    check("B3 FLAC at 96 kHz", j["state"] == "done" and f[1] == 96000, (j, f[:2]))
    left = [x for x in os.listdir(ROOT) if x.startswith(".objekat-export-")]
    check("B4 no intermediate file left behind", not left, left)

    # the listening: the file in progress is a WAV, so its length is known while it renders
    LONG = 900.0
    r = cmd("export.run", path=os.path.join(ROOT, "b_long.flac"), format="flac", sample_rate=44100,
            bit_depth=24, background=False, start=0.0, end=LONG)
    seen = []
    t_end = time.time() + 180
    while time.time() < t_end:
        st = cmd("export.status")
        if not st.get("running"):
            break
        try:
            seen.append((st.get("phase"), cmd("export.preview")))
        except ObjekatError:
            break
        time.sleep(0.03)
    wait(r, 240000)
    aud = [p.get("audible_seconds", 0) for _ph, p in seen]
    print("info  B5 %d previews taken while it rendered; audible_seconds: %s" % (len(seen), aud[:12]))
    check("B5 never claims more than the range", all(a <= LONG + 0.5 for a in aud), aud[:6])
    if len(seen) >= 3:
        check("B5 something is audible BEFORE the end of a FLAC export", any(a > 0 for a in aud), aud[:12])
    else:
        print("info  B5 the render ended before three previews could be taken: audibility not asserted")
    done = cmd("export.preview")
    check("B6 once finished, the whole file is audible", abs(done.get("audible_seconds", 0) - LONG) < 1.0, done)

    # ═══ C — the archive conversion ═════════════════════════════════════════════════════════
    section("C — project.convert_to_flac")
    cmd("project.save")
    idle()
    before_mix, j = export("c_before.wav", "wav", depth=24, end=END)
    check("C0 reference mix exported", j["state"] == "done", j)
    check("C0 the saved project is clean", dirty() is False, dirty())
    wav_files_before = sorted(os.listdir(cons)) + sorted(os.listdir(os.path.dirname(SRC24)))

    dry = cmd("project.convert_to_flac")
    print("info  C1 dry run: %d convertible, %d kept, outside %s"
          % (dry["count"], len(dry["kept"]), dry["outside_count"]))
    conv_paths = sorted(x["path"] for x in dry["converted"])
    check("C1 dry run: dry_run true and the two convertible files named",
          dry["dry_run"] is True and dry["count"] == 2 and
          conv_paths == sorted(["samples/sources/tone24.wav", "samples/consolidate/" + dq["wave"]]), (dry["converted"]))
    roles = {x["path"]: x["role"] for x in dry["converted"]}
    check("C1 roles: the source and the consolidated render",
          roles.get("samples/sources/tone24.wav") == "source" and roles.get("samples/consolidate/" + dq["wave"]) == "consolidated_wave",
          roles)
    bits = {x["path"]: x["bits"] for x in dry["converted"]}
    check("C1 both would be written at 24 bits", set(bits.values()) == {24}, bits)
    kept = {x["path"]: x for x in dry["kept"]}
    kl = kept.get("samples/consolidate/" + dl["wave"])
    check("C1 the render past 0 dBFS stays a WAV, reason float_over_full_scale with its peak",
          kl is not None and kl["reason"] == "float_over_full_scale" and kl.get("peak_db", 0) > 5.0, kept)
    check("C1 files outside the project folder are only counted", dry["outside_count"] >= 1, dry["outside_count"])
    check("C1 a dry run writes nothing",
          wav_files_before == sorted(os.listdir(cons)) + sorted(os.listdir(os.path.dirname(SRC24)))
          and not [x for x in os.listdir(cons) + os.listdir(os.path.dirname(SRC24)) if x.endswith(".flac")])
    check("C1 a dry run leaves the project clean", dirty() is False, dirty())

    src_wav_hash = sha(SRC24)
    quiet_wav_before = read_wav(wq)
    src_before = read_wav(SRC24)
    real = cmd("project.convert_to_flac", dry_run=False)
    idle()
    check("C2 real run: two files converted", real["dry_run"] is False and real["count"] == 2, real)
    check("C2 bytes_after < bytes_before", 0 < real["bytes_after"] < real["bytes_before"],
          (real["bytes_before"], real["bytes_after"]))
    fsrc = SRC24[:-4] + ".flac"
    fq = wq[:-4] + ".flac"
    check("C2 the FLACs exist beside the originals", os.path.isfile(fsrc) and os.path.isfile(fq))
    check("C2 they are real FLAC streams, 24 bits", magic(fsrc) == b"fLaC" and magic(fq) == b"fLaC"
          and flac_bits(fsrc) == 24 and flac_bits(fq) == 24, (flac_bits(fsrc), flac_bits(fq)))
    check("C2 the 24-bit WAV source became a FLAC BIT-EXACT", maxdiff(src_before, read_audio(fsrc)) == 0.0,
          maxdiff(src_before, read_audio(fsrc)))
    check("C2 the float render under 0 dBFS within one 24-bit step",
          maxdiff(quiet_wav_before, read_audio(fq)) <= STEP24 * 1.01, maxdiff(quiet_wav_before, read_audio(fq)))
    check("C2 the originals are NOT deleted", os.path.isfile(SRC24) and os.path.isfile(wq) and os.path.isfile(wl)
          and sha(SRC24) == src_wav_hash)
    check("C2 the loud float render is still a float WAV, untouched", wav_fmt(wl) == (3, 32) and not os.path.exists(wl[:-4] + ".flac"))
    check("C2 the file OUTSIDE the project folder is untouched",
          sha(EXT16) == ext_hash and not os.path.exists(EXT16[:-4] + ".flac"))
    check("C2 no temporary file left", not [x for x in os.listdir(cons) + os.listdir(os.path.dirname(SRC24))
                                              if x.startswith(".objekat-flac-")])
    check("C2 the project is MODIFIED", dirty() is True, dirty())
    check("C2 the clip now reads the FLAC", cmd("object.get", id=src)["file"].endswith("tone24.flac"),
          cmd("object.get", id=src).get("file"))
    check("C2 the outside clip still reads its WAV", cmd("object.get", id=ext)["file"] == EXT16,
          cmd("object.get", id=ext).get("file"))
    dd = {d["id"]: d for d in cmd("consolidate.list")["definitions"]}
    check("C2 the quiet definition names the FLAC wave, the loud one its WAV",
          dd[dq["id"]]["wave"].endswith(".flac") and dd[dl["id"]]["wave"].endswith(".wav"),
          (dd[dq["id"]]["wave"], dd[dl["id"]]["wave"]))
    check("C2 the quiet instance reads the FLAC", cmd("object.get", id=quiet)["file"].endswith(".flac"),
          cmd("object.get", id=quiet).get("file"))
    check("C2 nothing is missing", cmd("project.missing_files")["path_count"] == 0, cmd("project.missing_files"))

    after_mix, j = export("c_after.wav", "wav", depth=24, end=END)
    d = maxdiff(read_wav(before_mix), read_wav(after_mix))
    check("C3 the project replays the same mix (max diff %.2e <= 3e-7)" % d, j["state"] == "done" and d <= 3e-7, d)
    if d > 3e-7:
        # @see the head: Tracktion plays a FLAC 2 samples LATER than the same WAV (whoever wrote it).
        bm, am = read_wav(before_mix), read_wav(after_mix)
        print("info  C3 shift after conversion: source (48 kHz, resampled) %s, consolidated wave (44.1 kHz) %s"
              % (best_lag(bm, am, 0.05, 0.45), best_lag(bm, am, 1.25, 1.55)))
    check("C3 the mix is not silent", peak(read_wav(after_mix), 0.0, 0.5) > 0.3 and peak(read_wav(after_mix), 1.2, 1.6) > 0.5)

    again = cmd("project.convert_to_flac")
    check("C4 a second run finds nothing left to convert (the WAVs are no longer read)",
          again["count"] == 0, again)
    check("C4 the loud render is still reported", any(x["reason"] == "float_over_full_scale" for x in again["kept"]), again["kept"])

    # save, reopen: the FLAC waves are the project's now
    cmd("project.save")
    idle()
    check("C5 saved: clean again", dirty() is False, dirty())
    mp = os.path.join(P, "proj.objekat")
    cmd("project.new")
    idle()
    cmd("project.open", path=mp)
    idle()
    check("C5 reopened: nothing missing", cmd("project.missing_files")["path_count"] == 0, cmd("project.missing_files"))
    ds = {d["id"]: d["wave"] for d in cmd("consolidate.list")["definitions"]}
    check("C5 reopened: the FLAC wave is the definition's", ds.get(dq["id"], "").endswith(".flac"), ds)
    reopened_mix, j = export("c_reopened.wav", "wav", depth=24, end=END)
    d = maxdiff(read_wav(before_mix), read_wav(reopened_mix))
    check("C5 reopened: same mix again, with FLAC waves read from disk (max diff %.2e)" % d, j["state"] == "done" and d <= 3e-7, d)

    # the existing clean-up now finds the original WAVs unused: that is how the space comes back
    du = cmd("project.disk_usage", scope="session")
    unused = sorted(u["path"] for u in du["cleanable"])
    print("info  C6 cleanable after the save: %s" % unused)
    check("C6 the clean-up offers the original source WAV", "samples/sources/tone24.wav" in unused, unused)
    check("C6 it does not offer the loud render (still read)", ("samples/consolidate/" + dl["wave"]) not in unused, unused)

    # a re-bake of a definition whose wave is a FLAC writes a WAV revision beside it
    pl_q = cmd("consolidate.list")["definitions"]
    qd = next(x for x in pl_q if x["id"] == dq["id"])
    cmd("consolidate.edit_begin", placement=qd["placements"][0])
    kids = [o for o in cmd("object.list")["objects"] if o.get("parent") == qd["placements"][0] and o["kind"] == "clip"]
    if kids:
        cmd("object.set_gain", ids=[kids[0]["id"]], db=-6)
    wait(cmd("consolidate.edit_commit"))
    idle()
    nq = next(x for x in cmd("consolidate.list")["definitions"] if x["id"] == dq["id"])
    nw = os.path.join(cons, nq["wave"])
    check("C7 re-baking a FLAC-waved definition writes a float WAV revision (%s)" % nq["wave"],
          nq["wave"].endswith(".wav") and nq["revision"] == 1 and wav_fmt(nw) == (3, 32), (nq, wav_fmt(nw) if os.path.isfile(nw) else None))
    check("C7 the FLAC revision 0 is left in place (no migration, no GC)", os.path.isfile(fq))
    check("C7 the new revision holds the -6 dB content (peak ~ 0.275)", near(peak(read_wav(nw)), 0.549 * 10 ** (-6 / 20.0), 0.02),
          peak(read_wav(nw)))


if __name__ == "__main__":
    try:
        with ObjekatClient(SOCK, timeout=240) as c:
            main(c)
    except Exception:
        import traceback
        traceback.print_exc()
        fails.append("exception")
    print()
    if not KEEP:
        shutil.rmtree(ROOT, ignore_errors=True)
    else:
        print("kept: " + ROOT)
    if fails:
        print("%d FAILED:" % len(fails))
        for f in fails:
            print("  - " + f)
        sys.exit(1)
    print("ALL OK")

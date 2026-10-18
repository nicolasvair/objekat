#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The FLAC renders, taken back: internal renders are 32-bit float WAVs again, FLAC is an export format.

The branch `feat/flac-renders` (18 October 2026) made every internal render a FLAC; `feat/flac-archive` took
that back — an integer file clips whatever goes past 0 dBFS, and a bake must never clip. FLAC stays at the
export (rendered as a WAV, then converted) and at the archive conversion (`scenario_flac_archive.py`). What
is asserted here, with no screen and no ear:

  A  the mix export in FLAC: a real `fLaC` file, 24 and 16 bits, 44.1 and 96 kHz; once decoded it is
     SAMPLE-FOR-SAMPLE the WAV export of the same range (dithering off);
  B  a consolidation writes a 32-bit FLOAT `.wav` wave and a sidecar named after it; the sound is the same;
     an export launched the very instant after the consolidation hears the new wave, nested bakes too;
  C  a level above 0 dBFS is KEPT by the float wave (no clipping, no dialogue any more); and
     `object.render_isolated` into a `.flac` still answers `peak_linear`/`clipped` (the caller's choice);
  D  a project whose consolidated wave is a `.flac` (written by the FLAC-render build, or archived) still
     opens, the instance still plays it, and a re-bake writes a `.wav` revision beside it;
  E  the file in progress of a FLAC export is a WAV: the listening has something to play BEFORE the end.

    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --language=en --socket=/tmp/f.sock
    ./scenario_flac_renders.py /tmp/f.sock

Decoding goes through `afconvert` (CoreAudio).
Exit: 0 if every assertion passes, 1 otherwise.
"""

import array, json, os, shutil, struct, subprocess, sys, tempfile, time

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
ROOT = os.path.realpath(tempfile.mkdtemp(prefix="objk-flac-", dir="/tmp"))
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


# ── reading a file the app wrote ────────────────────────────────────────────────────────────

def magic(path):
    with open(path, "rb") as f:
        return f.read(4)


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
    """(channels, sample_rate, samples) of a PCM 16/24/32 or float32 wav."""
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


def lin(db):
    return 10 ** (db / 20.0)


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

    P = os.path.join(ROOT, "proj")
    os.makedirs(P)
    cmd("project.new")
    clip = cmd("object.add", path=BIP, lane=0, start=0.0)["id"]
    cmd("project.save_as", path=os.path.join(P, "proj.objekat"))
    idle()

    # ═══ A — the mix export ═════════════════════════════════════════════════════════════════
    section("A — the mix export in FLAC")
    wav24, j = export("a24.wav", "wav", depth=24)
    check("A0 the WAV export works (reference)", j["state"] == "done" and os.path.isfile(wav24), j)
    f24, j = export("a24.flac", "flac", depth=24)
    check("A1 FLAC 24 bits: job done, file written", j["state"] == "done" and os.path.isfile(f24), j)
    check("A1 it is a real FLAC stream (fLaC)", os.path.isfile(f24) and magic(f24) == b"fLaC", magic(f24))
    check("A1 it declares 24 bits", flac_bits(f24) == 24, flac_bits(f24))
    w, f = read_wav(wav24), read_audio(f24)
    check("A1 same length and rate as the WAV", w[0] == f[0] and w[1] == f[1] and len(w[2]) == len(f[2]),
          (w[:2], f[:2], len(w[2]), len(f[2])))
    diff = max((abs(a - b) for a, b in zip(w[2], f[2])), default=1.0)
    check("A1 sample for sample the WAV export (dither off)", diff < 1e-6, diff)
    check("A1 the mix is not silent", peak(f) > 0.4, peak(f))

    wav16, _ = export("a16.wav", "wav", depth=16)
    f16, j = export("a16.flac", "flac", depth=16)
    check("A2 FLAC 16 bits: written, declares 16", j["state"] == "done" and flac_bits(f16) == 16, (j, flac_bits(f16)))
    w, f = read_wav(wav16), read_audio(f16)
    diff = max((abs(a - b) for a, b in zip(w[2], f[2])), default=1.0)
    check("A2 sample for sample the 16-bit WAV", len(w[2]) == len(f[2]) and diff < 1e-6, diff)

    f96, j = export("a96.flac", "flac", rate=96000, depth=24)
    f = read_audio(f96) if os.path.isfile(f96) else (0, 0, [])
    check("A3 FLAC at 96 kHz", j["state"] == "done" and f[1] == 96000, (j, f[:2]))

    fd, j = export("ad.flac", "flac", depth=16, dith=True)
    check("A4 FLAC 16 bits with dithering renders", j["state"] == "done" and os.path.isfile(fd), j)

    try:
        cmd("export.run", path=os.path.join(ROOT, "bad.x"), format="ogg", start=0.0, end=0.4)
        check("A5 an unknown format is refused", False, "it went through")
    except ObjekatError as e:
        check("A5 an unknown format is refused, naming flac among the accepted ones",
              e.code == "bad_params" and "flac" in e.message, (e.code, e.message))

    regs = cmd("export.regions", format="flac", folder=ROOT)
    check("A6 export.regions accepts flac", "regions" in regs, regs)

    # ═══ B — consolidation ══════════════════════════════════════════════════════════════════
    section("B — a consolidation writes a 32-bit float WAV")
    job = cmd("consolidate.make", id=clip)
    wait(job)
    idle()
    d = cmd("consolidate.list")["definitions"]
    check("B1 one definition", len(d) == 1, d)
    wave = d[0]["wave"]
    wpath = os.path.join(P, "samples", "consolidate", wave)
    side = os.path.join(P, "samples", "consolidate", os.path.splitext(wave)[0] + "_objectstate.json")
    check("B1 the wave is a .wav", wave.endswith(".wav"), wave)
    check("B1 the file exists and is a real RIFF", os.path.isfile(wpath) and magic(wpath) == b"RIFF", wpath)
    check("B1 32-bit float (format tag 3)", wav_fmt(wpath) == (3, 32), wav_fmt(wpath))
    check("B1 the sidecar is named after the wave", os.path.isfile(side), side)
    bw = read_audio(wpath)
    check("B1 the baked sound is the clip's (peak 0.549)", near(peak(bw), 0.549, 0.01), peak(bw))
    check("B1 no .flac written by a consolidation",
          not [x for x in os.listdir(os.path.join(P, "samples", "consolidate")) if x.endswith(".flac")],
          os.listdir(os.path.join(P, "samples", "consolidate")))
    quiet = [x for x in cmd("app.dialogs")["dialogs"]] if True else []
    check("B1 no clipping warning for a clean level", not any("0 dBFS" in x["title"] for x in quiet), quiet)

    # the very next render hears the new wave
    t0 = time.time()
    imm, j = export("b_imm.wav", "wav", depth=24)
    f = read_wav(imm)
    check("B2 an export launched at once hears the new wave (%.1f s after)" % (time.time() - t0),
          j["state"] == "done" and near(peak(f), 0.549, 0.01), peak(f))
    inst_id = d[0]["placements"][0]
    # a bake that READS the new wave: group it with another clip (not overlapping) and consolidate the group
    clip2 = cmd("object.add", path=BIP, lane=1, start=1.0)["id"]
    gid = cmd("group.create", ids=[clip2, inst_id])["id"]
    wait(cmd("consolidate.make", id=gid))
    # ... and a render on a COPY of the Edit launched at once (the clone reads the new waves)
    bg, j = export("b_bg.wav", "wav", depth=24, end=1.5, background=True)
    idle()
    defs2 = cmd("consolidate.list")["definitions"]
    nested = [x for x in defs2 if x["id"] != d[0]["id"]]
    check("B3 the nested bake wrote a .wav too", len(nested) == 1 and nested[0]["wave"].endswith(".wav"), defs2)
    if len(nested) == 1:
        nw = read_audio(os.path.join(P, "samples", "consolidate", nested[0]["wave"]))
        check("B3 it heard BOTH sources: 0.549 at 0 s and at 1 s",
              near(peak(nw, 0.0, 0.4), 0.549, 0.02) and near(peak(nw, 1.0, 1.4), 0.549, 0.02),
              (peak(nw, 0.0, 0.4), peak(nw, 1.0, 1.4)))
    f = read_wav(bg)
    check("B4 a background (copy) export right after reads the new waves",
          j["state"] == "done" and near(peak(f, 0.0, 0.4), 0.549, 0.02) and near(peak(f, 1.0, 1.4), 0.549, 0.02),
          (j, peak(f, 0.0, 0.4), peak(f, 1.0, 1.4)))

    # A LONG wave, read at once by the next renders (kept from the FLAC-render days, when Tracktion read the
    # FLAC through a proxy decoded in the background). 90 s stereo tone, lane 7.
    import math, wave as wavemod
    LONG = 90.0
    longwav = os.path.join(ROOT, "long_tone.wav")
    with wavemod.open(longwav, "wb") as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(48000)
        n = int(LONG * 48000)
        block = 48000
        for off in range(0, n, block):
            a = array.array("h")
            for i in range(off, min(n, off + block)):
                v = int(0.3 * 32767 * math.sin(2 * math.pi * 440 * i / 48000))
                a.append(v); a.append(v)
            w.writeframes(a.tobytes())
    big = cmd("object.add", path=longwav, lane=7, start=100.0)["id"]
    t0 = time.time()
    wait(cmd("consolidate.make", id=big), ms=240000)
    big_def = next(x for x in cmd("consolidate.list")["definitions"] if big in x["placements"])
    print("info  B5 %.0f s tone consolidated in %.1f s -> %s" % (LONG, time.time() - t0, big_def["wave"]))
    # the end of the long wave, rendered on a copy at once: a missing proxy would read silence there
    tail, j = export("b5_tail.wav", "wav", depth=24, start=100.0 + LONG - 3.0, end=100.0 + LONG - 1.0,
                     background=True)
    tp = peak(read_wav(tail))
    check("B5 the tail of a 90 s wave is heard by an export on a copy launched at once (peak ~0.3)",
          j["state"] == "done" and near(tp, 0.3, 0.02), (j, tp))
    mid_g = cmd("group.create", ids=[big, cmd("object.add", path=BIP, lane=8, start=100.0)["id"]])["id"]
    wait(cmd("consolidate.make", id=mid_g), ms=240000)
    idle()
    big2 = next(x for x in cmd("consolidate.list")["definitions"] if x["id"] not in
                [big_def["id"]] and x["wave"].endswith(".wav") and x["was_group"] and mid_g in x["placements"])
    bw2 = read_audio(os.path.join(P, "samples", "consolidate", big2["wave"]))
    check("B5 a bake READING the 90 s wave right after it was written heard its end (peak ~0.3 at 86..89 s)",
          near(peak(bw2, LONG - 4.0, LONG - 1.0), 0.3, 0.02), peak(bw2, LONG - 4.0, LONG - 1.0))

    # ═══ C — a level above 0 dBFS ═══════════════════════════════════════════════════════════
    section("C — above 0 dBFS: kept by the float wave, never clipped")
    cmd("app.dialogs", clear=True)
    loud = cmd("object.add", path=BIP, lane=3, start=5.0)["id"]
    cmd("object.set_gain", ids=[loud], db=12.0)
    # the FX is what the consolidation bakes: a gain STAGE (a fader level stays on the instance)
    cmd("plugin.add_gain_stage", host=loud, face="gain", gain_db=12.0)
    idle()
    wait(cmd("consolidate.make", id=loud))
    idle()
    dl = cmd("app.dialogs")
    hits = [x for x in dl["dialogs"] if "0 dBFS" in x["title"]]
    check("C1 no « clipped » dialogue any more", not hits, dl)
    ld = next(x for x in cmd("consolidate.list")["definitions"] if loud in x["placements"])
    lw = os.path.join(P, "samples", "consolidate", ld["wave"])
    lpk = peak(read_wav(lw))
    check("C1 the loud wave is a float WAV that keeps its level past 0 dBFS (peak %.2f, ~ +6.8 dBFS)" % lpk,
          wav_fmt(lw) == (3, 32) and lpk > 1.5, (wav_fmt(lw), lpk))

    # the isolated render: flac = measured, wav = not
    clean = cmd("object.add", path=BIP, lane=6, start=30.0)["id"]
    ip = os.path.join(ROOT, "iso_clean.flac")
    j = wait(cmd("object.render_isolated", id=clean, path=ip, start=30.0, end=30.4, sample_rate=44100, bit_depth=24))
    res = j.get("result", j)
    check("C2 render_isolated into a .flac: a FLAC, not clipped, peak reported",
          magic(ip) == b"fLaC" and res.get("clipped") is False and near(res.get("peak_linear"), 0.549, 0.02), (res, magic(ip)))
    cmd("object.set_gain", ids=[loud], db=18.0)
    lp = os.path.join(ROOT, "iso_loud.flac")
    j = wait(cmd("object.render_isolated", id=loud, path=lp, start=5.0, end=5.4, sample_rate=44100, bit_depth=24))
    res = j.get("result", j)
    check("C3 render_isolated of a loud object: clipped=true with the real peak (> 1)",
          res.get("clipped") is True and (res.get("peak_linear") or 0) > 1.5, res)
    wp = os.path.join(ROOT, "iso_loud.wav")
    j = wait(cmd("object.render_isolated", id=loud, path=wp, start=5.0, end=5.4, sample_rate=44100, bit_depth=24))
    res = j.get("result", j)
    check("C4 the same into a .wav: nothing measured (WAV keeps its own behaviour)",
          "clipped" not in res and magic(wp) == b"RIFF", (res, magic(wp)))

    # ═══ D — an old project: .wav consolidated waves ════════════════════════════════════════
    section("D — a project with a .flac consolidated wave still opens")
    # a definition of its own, so that nothing else in the project depends on the wave being turned back
    oc = cmd("object.add", path=BIP, lane=5, start=20.0)["id"]
    wait(cmd("consolidate.make", id=oc))
    idle()
    wave = next(x for x in cmd("consolidate.list")["definitions"] if oc in x["placements"])["wave"]
    wpath = os.path.join(P, "samples", "consolidate", wave)
    cmd("project.save")
    idle()
    # turn that definition's wave into a FLAC 24 (as the FLAC-render build, or an archive, left it)
    cons = os.path.join(P, "samples", "consolidate")
    base = os.path.splitext(wave)[0]
    old_wave = os.path.join(cons, base + ".flac")
    i24 = os.path.join(ROOT, "d_i24.wav")
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI24", wpath, i24], check=True)
    subprocess.run(["afconvert", "-f", "flac", "-d", "flac", i24, old_wave], check=True)
    os.remove(wpath)
    mpath = os.path.join(P, "proj.objekat")
    man = json.load(open(mpath)) if mpath.endswith(".json") else None
    # the manifest names the version file; rewrite every occurrence of the wave name in it
    for fn in os.listdir(P):
        fp = os.path.join(P, fn)
        if os.path.isfile(fp) and fn.endswith((".objekat", ".json")):
            txt = open(fp, encoding="utf-8").read()
            if wave in txt:
                open(fp, "w", encoding="utf-8").write(txt.replace(wave, base + ".flac"))
    cmd("project.new")
    idle()
    for fn in sorted(os.listdir(P)):
        if fn.endswith(".objekat"):
            mp = os.path.join(P, fn)
            break
    cmd("project.open", path=mp)
    idle()
    miss = cmd("project.missing_files")
    check("D1 reopened: nothing missing", miss["path_count"] == 0, miss)
    dd = {x["id"]: x for x in cmd("consolidate.list")["definitions"]}
    old = [x for x in dd.values() if x["wave"].endswith(base + ".flac")]
    check("D1 the definition records the .flac name", len(old) == 1, [x["wave"] for x in dd.values()])
    pl0 = old[0]["placements"][0]
    iso = os.path.join(ROOT, "d_iso.wav")
    j = wait(cmd("object.render_isolated", id=pl0, path=iso, start=20.0, end=20.4, sample_rate=44100, bit_depth=24))
    f = read_wav(iso)
    check("D2 the instance plays the .flac wave (peak 0.549)", j["state"] == "done" and near(peak(f), 0.549, 0.02), peak(f))
    # a re-bake of that definition writes a float WAV next to it, the .flac stays
    pl = old[0]["placements"][0] if old and old[0].get("placements") else None
    if pl:
        cmd("consolidate.edit_begin", placement=pl)
        kids = [o for o in cmd("object.list")["objects"] if o.get("parent") == pl and o["kind"] == "clip"]
        if kids:
            cmd("object.set_gain", ids=[kids[0]["id"]], db=-6)
        wait(cmd("consolidate.edit_commit"))
        idle()
        nd = {x["id"]: x for x in cmd("consolidate.list")["definitions"]}[old[0]["id"]]
        check("D3 a re-bake of the FLAC-waved definition writes a float WAV revision",
              nd["wave"].endswith("_v1.wav") and nd["revision"] == 1
              and wav_fmt(os.path.join(cons, nd["wave"])) == (3, 32), nd)
        check("D3 the .flac is left in place (no migration, no GC)", os.path.isfile(old_wave))
        f = read_audio(os.path.join(cons, nd["wave"]))
        check("D3 the new revision holds the -6 dB content (peak ~ 0.275)", near(peak(f), 0.549 * lin(-6), 0.02), peak(f))

    # ═══ E — the listening while a FLAC renders ═════════════════════════════════════════════
    section("E — preview of a FLAC export in progress")
    long_end = 240.0
    r = cmd("export.run", path=os.path.join(ROOT, "e_long.flac"), format="flac", sample_rate=44100,
            bit_depth=24, background=False, start=0.0, end=long_end)
    seen = []
    t_end = time.time() + 120
    while time.time() < t_end:
        st = cmd("export.status")
        if not st.get("running"):
            break
        try:
            seen.append(cmd("export.preview"))
        except ObjekatError:
            break
        time.sleep(0.05)
    wait(r)
    print("  ..   %d previews taken while rendering" % len(seen))
    aud = [p.get("audible_seconds", 0) for p in seen]
    check("E1 the waveform still grows", any(0 < p["peaks_filled"] < p["peaks_total"] for p in seen) or len(seen) < 2,
          [(p["peaks_filled"], p["peaks_total"]) for p in seen[:4]])
    check("E1 the listening never claims more than rendered (audible <= range)", all(a <= long_end + 0.5 for a in aud), aud[:6])
    print("info  E1 audible_seconds while rendering: %s" % aud[:12])
    if len(seen) >= 3:
        check("E1 something is audible BEFORE the end (the file in progress is a WAV)", any(a > 0 for a in aud), aud[:12])
    done = cmd("export.preview")
    check("E2 once finished, the whole FLAC is audible", abs(done.get("audible_seconds", 0) - long_end) < 1.0, done)


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

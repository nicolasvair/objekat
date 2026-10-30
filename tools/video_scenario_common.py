#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Shared pieces of the `scenario_video_*.py` scenarios (plan-video §9.1, §9.3). Not a scenario itself.

What it gives:

  * `make_fixtures(folder)` — builds the self-checking video corpus with `tools/make_video_fixtures.swift`
    (a barcode of the frame number in every picture, ONE audio impulse at a known instant per track)
    through a tiny driver compiled on the fly. The files stay OUTSIDE the repository: pass a scratch
    folder. Idempotent: an existing file is kept.
  * `Checker` — `check(label, ok, detail)` in the house style (`ok    ...` / `FAIL  ...`).
  * `barcode_of_png(path)` — the frame number a rendered still carries (`video.render_frame`), `None`
    for a black frame (no picture there). A tiny PNG reader on `zlib`: no Pillow.
  * `export_mix(c, path, ...)` / `read_wav(path)` — the REAL engine road: the mix is rendered by
    `export.run` (24-bit WAV) and read back.
  * `impulses(x, sr)` — the sample index of every click of a mix.

Nothing here touches the user's projects: every scenario works in a temporary folder it creates.
"""

import json
import os
import struct
import subprocess
import sys
import tempfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError  # noqa: E402,F401

SR = 48000

# ---------------------------------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------------------------------

_DRIVER = r'''
import Foundation
import AVFoundation

@main struct Gen {
    static func main() async throws {
        let out = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        func spec(_ name: String, container: AVFileType = .mp4, fps: Int = 24, seconds: Double = 10,
                  codec: AVVideoCodecType = .h264, audio: [VideoFixtureSpec.Audio]) -> VideoFixtureSpec {
            var s = VideoFixtureSpec(url: out.appendingPathComponent(name))
            s.container = container; s.fps = fps; s.seconds = seconds; s.codec = codec; s.audio = audio
            return s
        }
        func a(_ kind: VideoFixtureSpec.Audio.Kind = .aac, impulse: Double = 2.0, start: Double = 0,
               sr: Double = 48000) -> VideoFixtureSpec.Audio {
            var x = VideoFixtureSpec.Audio(); x.kind = kind; x.impulseSeconds = impulse
            x.startSeconds = start; x.sampleRate = sr; return x
        }
        // Every impulse sits at 2.0 s of the MOVIE unless the name says otherwise.
        let specs: [VideoFixtureSpec] = [
            spec("aac_mp4.mp4", audio: [a(.aac)]),
            spec("aac_mov.mov", container: .mov, audio: [a(.aac)]),
            spec("pcm16.mov", container: .mov, audio: [a(.pcm16)]),
            spec("pcm24.mov", container: .mov, audio: [a(.pcm24)]),
            spec("pcm32f.mov", container: .mov, audio: [a(.pcm32f)]),
            spec("late_audio.mp4", audio: [a(.aac, impulse: 4.0, start: 1.5)]),          // impulse at 4.0, audio from 1.5
            spec("late_audio_pcm.mov", container: .mov, audio: [a(.pcm24, impulse: 4.0, start: 1.5)]),
            spec("late_aac.mov", container: .mov, audio: [a(.aac, impulse: 4.0, start: 1.5)]),
            spec("silent.mp4", audio: []),
            spec("disabled.mov", container: .mov, audio: [a(.pcm16, impulse: 2.0), { var x = a(.pcm16, impulse: 5.0); x.enabled = false; return x }()]),
            spec("multi.mov", container: .mov, audio: [a(.pcm16, impulse: 2.0), a(.pcm16, impulse: 5.0)]),
            spec("hevc.mov", container: .mov, codec: .hevc, audio: [a(.aac)]),
            spec("sr44.mov", container: .mov, audio: [a(.pcm16, sr: 44100)]),
            spec("long30.mov", container: .mov, fps: 30, seconds: 150, audio: [a(.pcm16, impulse: 100.0)]),
        ]
        for s in specs where !FileManager.default.fileExists(atPath: s.url.path) {
            try await VideoFixtures.make(s)
            print("made", s.url.lastPathComponent)
        }
    }
}
'''


def make_fixtures(folder):
    """Builds the corpus into `folder` (kept if already there) and returns the folder."""
    os.makedirs(folder, exist_ok=True)
    marker = os.path.join(folder, ".built")
    if os.path.exists(marker):
        return folder
    work = tempfile.mkdtemp(prefix="vfx-gen-")
    with open(os.path.join(work, "gen_main.swift"), "w") as fh:
        fh.write(_DRIVER)
    exe = os.path.join(work, "genfx")
    lib = os.path.join(HERE, "make_video_fixtures.swift")
    subprocess.run(["swiftc", "-O", "-parse-as-library", lib, os.path.join(work, "gen_main.swift"), "-o", exe],
                   check=True, capture_output=True)
    subprocess.run([exe, folder], check=True)
    # Not-a-video files, for the refusal scenario.
    refuse = os.path.join(folder, "refuse")
    os.makedirs(refuse, exist_ok=True)
    with open(os.path.join(refuse, "fake.mkv"), "wb") as fh:
        fh.write(b"\x1a\x45\xdf\xa3 not really a matroska file")
    with open(os.path.join(refuse, "garbage.mp4"), "wb") as fh:
        fh.write(os.urandom(2000))
    open(os.path.join(refuse, "empty.mov"), "wb").close()
    with open(os.path.join(refuse, "notvideo.txt"), "w") as fh:
        fh.write("hello\n")
    # A real MP4 whose picture codec FourCC is changed to one nobody decodes.
    with open(os.path.join(folder, "aac_mp4.mp4"), "rb") as fh:
        raw = bytearray(fh.read())
    i = raw.find(b"avc1")
    if i >= 0:
        raw[i:i + 4] = b"zzz1"
        with open(os.path.join(refuse, "badcodec.mp4"), "wb") as fh:
            fh.write(raw)
    open(marker, "w").close()
    subprocess.run(["rm", "-rf", work])
    return folder


# ---------------------------------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------------------------------

class Checker:
    def __init__(self):
        self.fails = []
        self.total = 0

    def check(self, label, ok, detail=""):
        self.total += 1
        if ok:
            print("ok    " + label)
        else:
            self.fails.append(label)
            print("FAIL  %s  %s" % (label, detail))

    def finish(self):
        passed = self.total - len(self.fails)
        print("\n%d/%d passed" % (passed, self.total))
        if self.fails:
            print("FAILED: " + "; ".join(self.fails))
        return 0 if not self.fails else 1


# ---------------------------------------------------------------------------------------------------
# Pictures
# ---------------------------------------------------------------------------------------------------

def read_png(path):
    """(width, height, rows) of an 8-bit non-interlaced RGB / RGBA / gray PNG; rows = bytes per pixel row."""
    with open(path, "rb") as fh:
        raw = fh.read()
    assert raw[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    pos, idat, w = 8, b"", None
    while pos < len(raw):
        n, kind = struct.unpack(">I4s", raw[pos:pos + 8])
        body = raw[pos + 8:pos + 8 + n]
        if kind == b"IHDR":
            w, h, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", body)
            assert depth == 8 and interlace == 0, "unsupported PNG layout"
            bpp = {0: 1, 2: 3, 4: 2, 6: 4}[ctype]
        elif kind == b"IDAT":
            idat += body
        pos += 12 + n
    data = zlib.decompress(idat)
    stride = w * bpp
    rows, prev = [], bytearray(stride)
    p = 0
    for _ in range(h):
        ft = data[p]
        line = bytearray(data[p + 1:p + 1 + stride])
        p += 1 + stride
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]
            c_ = prev[i - bpp] if i >= bpp else 0
            if ft == 1:
                line[i] = (line[i] + a) & 255
            elif ft == 2:
                line[i] = (line[i] + b) & 255
            elif ft == 3:
                line[i] = (line[i] + ((a + b) >> 1)) & 255
            elif ft == 4:
                pa, pb, pc = abs(b - c_), abs(a - c_), abs(a + b - 2 * c_)
                pr = a if pa <= pb and pa <= pc else (b if pb <= pc else c_)
                line[i] = (line[i] + pr) & 255
        rows.append(line)
        prev = line
    return w, h, bpp, rows


def barcode_of_png(path):
    """The frame number of a rendered still, or None when the frame is black (no picture)."""
    w, h, bpp, rows = read_png(path)

    def px(x, y):
        return rows[y][x * bpp]
    # Fixture pictures are mid-gray (128) outside the barcode; a black frame has no gray anywhere.
    if px(w // 2, h // 2) < 40 and px(w // 2, h - 8) < 40:
        return None
    sx = w / 320.0   # the barcode is 16 bits of 8-pixel blocks on a 320-wide picture
    idx = 0
    for bit in range(16):
        if px(int((bit * 8 + 4) * sx), max(0, int(8 * sx))) > 128:
            idx |= 1 << bit
    return idx


def frame_at(c, t, folder, name="f.png"):
    """Renders the timeline picture at `t` and returns (barcode or None, render_frame answer)."""
    p = os.path.join(folder, name)
    r = c.send("video.render_frame", {"time": t, "path": p})
    return (barcode_of_png(p) if r.get("layers", 0) > 0 and r.get("decoded", 0) > 0 else None), r


# ---------------------------------------------------------------------------------------------------
# Sound
# ---------------------------------------------------------------------------------------------------

def read_wav(path):
    """16 / 24 / 32-bit-float PCM WAV -> float array (frames, channels), plus the sample rate."""
    import numpy as np
    with open(path, "rb") as fh:
        raw = fh.read()
    pos, fmt, data = 12, None, b""
    while pos + 8 <= len(raw):
        cid, size = raw[pos:pos + 4], struct.unpack("<I", raw[pos + 4:pos + 8])[0]
        body = raw[pos + 8:pos + 8 + size]
        if cid == b"fmt ":
            fmt = struct.unpack("<HHIIHH", body[:16])
        elif cid == b"data":
            data = body
        pos += 8 + size + (size & 1)
    tag, ch, sr, _, _, bits = fmt
    if tag == 3 and bits == 32:
        x = np.frombuffer(data[:len(data) // 4 * 4], dtype="<f4").astype(np.float64)
    elif bits == 24:
        n = len(data) // 3
        b = np.frombuffer(data[:n * 3], dtype=np.uint8).reshape(n, 3).astype(np.int32)
        v = b[:, 0] | (b[:, 1] << 8) | (b[:, 2] << 16)
        x = np.where(v >= 1 << 23, v - (1 << 24), v) / float(1 << 23)
    elif bits == 16:
        x = np.frombuffer(data[:len(data) // 2 * 2], dtype="<i2").astype(np.float64) / 32768.0
    else:
        raise ValueError("unsupported WAV: tag %s bits %s" % (tag, bits))
    return x.reshape(-1, ch), sr


def export_mix(c, path, start=None, end=None, timeout_ms=120000):
    """Renders the mix through the engine's real export (24-bit, 48 kHz WAV) and reads it back."""
    params = {"path": path, "format": "wav", "sample_rate": SR, "bit_depth": 24}
    if start is not None:
        params["start"] = start
    if end is not None:
        params["end"] = end
        params.setdefault("start", 0)
    job = c.send("export.run", params)
    res = c.send("job.wait", {"id": job["job_id"], "timeout_ms": timeout_ms})
    if res.get("state") != "done":
        raise RuntimeError("export failed: %s" % json.dumps(res)[:300])
    x, sr = read_wav(path)
    assert sr == SR, sr
    return x


def impulses(x, thr=0.2, gap_s=0.05):
    """Sample index of the peak of every click in `x` (frames, channels): clusters of samples above `thr`
    separated by more than `gap_s`. Returns [(index, peak)]."""
    import numpy as np
    m = np.max(np.abs(x), axis=1) if x.ndim == 2 else np.abs(x)
    idx = np.nonzero(m > thr)[0]
    out, i = [], 0
    gap = int(gap_s * SR)
    while i < len(idx):
        j = i
        while j + 1 < len(idx) and idx[j + 1] - idx[j] <= gap:
            j += 1
        seg = idx[i:j + 1]
        k = int(seg[np.argmax(m[seg])])
        out.append((k, float(m[k])))
        i = j + 1
    return out


def objects(c):
    """Every object (children included: the groups are opened first, nested ones too) as a dict id -> row."""
    opened = set()
    while True:
        rows = c.send("object.list")["objects"]
        todo = [o["id"] for o in rows if o["kind"] == "group" and o["id"] not in opened]
        if not todo:
            return {o["id"]: o for o in rows}
        for gid in todo:
            c.send("group.expand", {"id": gid, "expanded": True})
            opened.add(gid)


def children_of(rows, gid):
    return [o for o in rows.values() if o["parent"] == gid]


def new_saved_project(c, folder, name="p"):
    """project.new + save_as into `folder` (created); returns the project path."""
    c.send("project.new")
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, name + ".objekat")
    c.send("project.save_as", {"path": path})
    return path


def state_flat(c):
    """The saved document's items flattened (children included): id -> raw item. The raw item carries
    `video` for a picture object, `startTime` / `duration` / `kind.filePath`..."""
    out = {}

    def walk(items, parent):
        for it in items:
            it = dict(it)
            it["_parent"] = parent
            out[it["id"]] = it
            kind = it.get("kind") or {}
            if isinstance(kind, dict) and kind.get("children"):
                walk(kind["children"], it["id"])
    walk(c.send("project.get_state")["items"], None)
    return out


def pictures(flat):
    return [i for i in flat.values() if i.get("video")]

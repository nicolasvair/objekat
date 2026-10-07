"""Minimal WAV reader / writer for the spectral-editor script (numpy and the standard library only).

Reads RIFF and RF64 files, PCM 16 / 24 / 32 bit integer, IEEE float 32 / 64, plain or
WAVE_FORMAT_EXTENSIBLE headers. Writes pcm16, pcm24 or f32, atomically.

Conventions
- Sample arrays are shaped (frames, channels), always 2-D.
- `read_wav` returns float64 in [-1, 1): an integer sample is divided by 2**(bits-1).
- `read_wav_int` returns the integer samples untouched (int32 for 16 / 24 / 32 bit PCM).
- `write_wav` multiplies by 2**(bits-1), rounds to nearest even (`np.rint`), clips to the integer
  range and RETURNS THE NUMBER OF SAMPLES that had to be clipped (a full-scale +1.0 counts: its
  integer, 2**(bits-1), does not exist). No dither, ever. f32 is written as is and never clips.
"""
import mmap
import os
import struct
from collections import namedtuple

import numpy as np

WavInfo = namedtuple("WavInfo", "sample_rate channels bit_depth kind frames")
# kind: "pcm_int" or "pcm_float"

_FORMAT_PCM = 1
_FORMAT_FLOAT = 3
_FORMAT_EXTENSIBLE = 0xFFFE


class WavError(ValueError):
    """The file is not a WAV this module understands."""


def _parse(data):
    """Return (info, data_offset, data_bytes) from the raw bytes of a file."""
    if len(data) < 12:
        raise WavError("file too short for a WAV header")
    magic = data[0:4]
    if magic not in (b"RIFF", b"RF64") or data[8:12] != b"WAVE":
        raise WavError("not a RIFF/RF64 WAVE file")
    rf64 = magic == b"RF64"
    ds64_data_size = None
    fmt = None
    pos = 12
    n = len(data)
    while pos + 8 <= n:
        cid = data[pos:pos + 4]
        size = struct.unpack("<I", data[pos + 4:pos + 8])[0]
        body = pos + 8
        if cid == b"ds64":
            if size < 24:
                raise WavError("ds64 chunk too short")
            ds64_data_size = struct.unpack("<Q", data[body + 8:body + 16])[0]
        elif cid == b"fmt ":
            if size < 16:
                raise WavError("fmt chunk too short")
            tag, ch, sr, _byte_rate, _align, bits = struct.unpack("<HHIIHH", data[body:body + 16])
            if tag == _FORMAT_EXTENSIBLE:
                if size < 40:
                    raise WavError("extensible fmt chunk too short")
                tag = struct.unpack("<H", data[body + 24:body + 26])[0]  # first 2 bytes of the sub-format GUID
            fmt = (tag, ch, sr, bits)
        elif cid == b"data":
            if fmt is None:
                raise WavError("data chunk before fmt chunk")
            if rf64 and size == 0xFFFFFFFF:
                if ds64_data_size is None:
                    raise WavError("RF64 file without ds64 chunk")
                size = ds64_data_size
            size = min(size, n - body)  # tolerate a truncated or oversized header
            tag, ch, sr, bits = fmt
            if ch < 1:
                raise WavError("zero channels")
            if tag == _FORMAT_PCM and bits in (16, 24, 32):
                kind = "pcm_int"
            elif tag == _FORMAT_FLOAT and bits in (32, 64):
                kind = "pcm_float"
            else:
                raise WavError("unsupported WAV format (tag %d, %d bits)" % (tag, bits))
            frame_bytes = ch * bits // 8
            frames = size // frame_bytes
            return WavInfo(sr, ch, bits, kind, frames), body, size
        pos = body + size + (size & 1)
    raise WavError("no data chunk")


def _decode_int(raw, info):
    bits, ch, frames = info.bit_depth, info.channels, info.frames
    nbytes = frames * ch * bits // 8
    raw = raw[:nbytes]
    if bits == 16:
        a = np.frombuffer(raw, dtype="<i2").astype(np.int32)
    elif bits == 32:
        a = np.frombuffer(raw, dtype="<i4").astype(np.int32)
    else:  # 24
        b = np.frombuffer(raw, dtype=np.uint8).reshape(-1, 3).astype(np.int32)
        a = b[:, 0] | (b[:, 1] << 8) | (b[:, 2] << 16)
        a = np.where(a & 0x800000, a - 0x1000000, a).astype(np.int32)
    return a.reshape(frames, ch)


def read_wav_info(path):
    """Header information only (the file is memory-mapped, not read)."""
    with open(path, "rb") as f:
        if os.fstat(f.fileno()).st_size == 0:
            raise WavError("empty file")
        with mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as m:
            return _parse(m)[0]


def read_wav_int(path):
    """(int samples shaped (frames, channels), WavInfo). Float files raise WavError."""
    with open(path, "rb") as f:
        data = f.read()
    info, off, size = _parse(data)
    if info.kind != "pcm_int":
        raise WavError("not an integer PCM file")
    return _decode_int(data[off:off + size], info), info


def read_wav(path):
    """(float64 samples shaped (frames, channels), WavInfo)."""
    with open(path, "rb") as f:
        data = f.read()
    info, off, size = _parse(data)
    raw = data[off:off + size]
    if info.kind == "pcm_int":
        a = _decode_int(raw, info).astype(np.float64) / float(1 << (info.bit_depth - 1))
    else:
        dt = "<f4" if info.bit_depth == 32 else "<f8"
        nbytes = info.frames * info.channels * info.bit_depth // 8
        a = np.frombuffer(raw[:nbytes], dtype=dt).astype(np.float64).reshape(info.frames, info.channels)
    return a, info


def _as_2d(x):
    x = np.asarray(x)
    if x.ndim == 1:
        x = x[:, None]
    if x.ndim != 2 or x.shape[1] < 1:
        raise ValueError("samples must be shaped (frames,) or (frames, channels)")
    return x


def write_wav(path, x, sample_rate, kind="pcm24"):
    """Write `x` (float, nominal range [-1, 1]) as pcm16 / pcm24 / f32. Returns the clipped count."""
    if kind not in ("pcm16", "pcm24", "f32"):
        raise ValueError("kind must be pcm16, pcm24 or f32")
    x = _as_2d(x)
    frames, ch = x.shape
    clipped = 0
    if kind == "f32":
        bits = 32
        payload = np.ascontiguousarray(x, dtype="<f4").tobytes()
    else:
        bits = 16 if kind == "pcm16" else 24
        scale = float(1 << (bits - 1))
        lo, hi = -(1 << (bits - 1)), (1 << (bits - 1)) - 1
        q = np.rint(np.asarray(x, dtype=np.float64) * scale)
        q = np.nan_to_num(q, nan=0.0, posinf=hi + 1.0, neginf=lo - 1.0)
        clipped = int(np.count_nonzero((q > hi) | (q < lo)))
        q = np.clip(q, lo, hi).astype(np.int32)
        if bits == 16:
            payload = q.astype("<i2").tobytes()
        else:
            le = q.astype("<i4").view(np.uint8).reshape(-1, 4)[:, :3]
            payload = np.ascontiguousarray(le).tobytes()
    data_size = len(payload)
    is_float = kind == "f32"
    fmt_size = 18 if is_float else 16
    fact = struct.pack("<4sII", b"fact", 4, frames) if is_float else b""
    riff_size = 4 + (8 + fmt_size) + len(fact) + 8 + data_size + (data_size & 1)
    if riff_size >= 0xFFFFFFFF:
        raise ValueError("file too large for a RIFF WAV (4 GB)")
    block_align = ch * bits // 8
    fmt = struct.pack("<4sIHHIIHH", b"fmt ", fmt_size, _FORMAT_FLOAT if is_float else _FORMAT_PCM,
                      ch, int(sample_rate), int(sample_rate) * block_align, block_align, bits)
    if is_float:
        fmt += struct.pack("<H", 0)
    header = struct.pack("<4sI4s", b"RIFF", riff_size, b"WAVE") + fmt + fact + struct.pack("<4sI", b"data", data_size)
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(header)
        f.write(payload)
        if data_size & 1:
            f.write(b"\0")
    os.replace(tmp, path)
    return clipped

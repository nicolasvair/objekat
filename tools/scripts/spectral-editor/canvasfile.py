"""Raw image files for `script.canvas.*` (plan 3.1): OBJKCNV1 (indexed 8-bit + palette + value
range) and OBJKRGB1 (premultiplied RGBA8). Little-endian, row-major, row 0 = the TOP of the image
(y max), column 0 = x min. numpy and `struct` only. Writes are atomic (`.tmp` + `os.replace`).

OBJKCNV1: "OBJKCNV1", u32 W, u32 H, f32 value of index 0, f32 value of index 255, u32 0 (reserved),
          256 x RGB palette (768 bytes), W*H uint8 indices.   Size = 796 + W*H exactly.
OBJKRGB1: "OBJKRGB1", u32 W, u32 H, 8 zero bytes, W*H RGBA (premultiplied).   Size = 24 + 4*W*H.

Caps (the app's too): W <= 16384, H <= 4096, W*H <= 32 M.
"""
import math
import os
import struct

import numpy as np

CNV_MAGIC = b"OBJKCNV1"
RGB_MAGIC = b"OBJKRGB1"
CNV_HEADER = 796
RGB_HEADER = 24
MAX_WIDTH = 16384
MAX_HEIGHT = 4096
MAX_PIXELS = 32 * 1024 * 1024


class CanvasFileError(ValueError):
    pass


def _check_dims(w, h):
    if w < 1 or h < 1:
        raise CanvasFileError("zero dimension")
    if w > MAX_WIDTH or h > MAX_HEIGHT or w * h > MAX_PIXELS:
        raise CanvasFileError("image %dx%d is over the caps" % (w, h))


def _atomic_write(path, parts):
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        for p in parts:
            f.write(p)
    os.replace(tmp, path)


def write_cnv(path, indices, v0, v255, palette):
    """indices: uint8 array (H, W); palette: 768 bytes (256 x RGB)."""
    a = np.asarray(indices)
    if a.dtype != np.uint8 or a.ndim != 2:
        raise CanvasFileError("indices must be a 2-D uint8 array")
    h, w = a.shape
    _check_dims(w, h)
    palette = bytes(palette)
    if len(palette) != 768:
        raise CanvasFileError("palette must be 768 bytes")
    for v in (v0, v255):
        if not math.isfinite(v):
            raise CanvasFileError("value range is not finite")
    header = CNV_MAGIC + struct.pack("<IIffI", w, h, float(v0), float(v255), 0)
    _atomic_write(path, [header, palette, np.ascontiguousarray(a).tobytes()])


def write_rgb(path, rgba):
    """rgba: uint8 array (H, W, 4), already premultiplied."""
    a = np.asarray(rgba)
    if a.dtype != np.uint8 or a.ndim != 3 or a.shape[2] != 4:
        raise CanvasFileError("rgba must be a (H, W, 4) uint8 array")
    h, w = a.shape[:2]
    _check_dims(w, h)
    header = RGB_MAGIC + struct.pack("<II", w, h) + b"\0" * 8
    _atomic_write(path, [header, np.ascontiguousarray(a).tobytes()])


def read_cnv(path):
    """(indices (H, W) uint8, v0, v255, palette bytes). Raises CanvasFileError if malformed."""
    with open(path, "rb") as f:
        data = f.read()
    if len(data) < CNV_HEADER or data[:8] != CNV_MAGIC:
        raise CanvasFileError("not an OBJKCNV1 file")
    w, h, v0, v255, _reserved = struct.unpack("<IIffI", data[8:28])
    _check_dims(w, h)
    if len(data) != CNV_HEADER + w * h:
        raise CanvasFileError("size does not match the header")
    idx = np.frombuffer(data, dtype=np.uint8, offset=CNV_HEADER).reshape(h, w).copy()
    return idx, v0, v255, data[28:28 + 768]


def read_rgb(path):
    """RGBA premultiplied (H, W, 4) uint8. Raises CanvasFileError if malformed."""
    with open(path, "rb") as f:
        data = f.read()
    if len(data) < RGB_HEADER or data[:8] != RGB_MAGIC:
        raise CanvasFileError("not an OBJKRGB1 file")
    w, h = struct.unpack("<II", data[8:16])
    _check_dims(w, h)
    if len(data) != RGB_HEADER + 4 * w * h:
        raise CanvasFileError("size does not match the header")
    return np.frombuffer(data, dtype=np.uint8, offset=RGB_HEADER).reshape(h, w, 4).copy()

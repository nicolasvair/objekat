"""Writes the two format fixtures to tools/fixtures/spectral/ (default) or to a given folder.

They exist only to pin the FILE FORMATS (the Swift parser's standalone test reads them); there is
no gain mathematics in them. Both are 4 columns x 3 rows, and every pixel is distinct and known:

  fixture.objkcnv   OBJKCNV1, value 0 = -100, value 255 = 0, palette = MAGMA,
                    index(c, r) = (r * 4 + c) * 21                          (0 ... 231)
  fixture.objkrgb   OBJKRGB1, premultiplied RGBA, with a = 40 * (c + r) + 55,
                    pixel(c, r) = (a * c // 3, a * r // 2, a // 2, a)        (every colour <= a)

c = column (0 = left / x min), r = row (0 = top / y max). Usage: python3 make_fixture.py [folder]
"""
import os
import sys

import numpy as np

import canvasfile
import colormap

WIDTH = 4
HEIGHT = 3
V0 = -100.0
V255 = 0.0
FILES = ("fixture.objkcnv", "fixture.objkrgb")


def cnv_indices():
    r, c = np.mgrid[0:HEIGHT, 0:WIDTH]
    return ((r * WIDTH + c) * 21).astype(np.uint8)


def rgb_pixels():
    r, c = np.mgrid[0:HEIGHT, 0:WIDTH]
    a = 40 * (c + r) + 55
    out = np.empty((HEIGHT, WIDTH, 4), dtype=np.uint8)
    out[..., 0] = a * c // 3
    out[..., 1] = a * r // 2
    out[..., 2] = a // 2
    out[..., 3] = a
    return out


def default_folder():
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.normpath(os.path.join(here, "..", "..", "fixtures", "spectral"))


def write_fixtures(folder):
    os.makedirs(folder, exist_ok=True)
    canvasfile.write_cnv(os.path.join(folder, FILES[0]), cnv_indices(), V0, V255, colormap.MAGMA)
    canvasfile.write_rgb(os.path.join(folder, FILES[1]), rgb_pixels())
    return [os.path.join(folder, f) for f in FILES]


if __name__ == "__main__":
    for p in write_fixtures(sys.argv[1] if len(sys.argv) > 1 else default_folder()):
        print(p)

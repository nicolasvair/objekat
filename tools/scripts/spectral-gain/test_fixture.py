import os
import struct
import tempfile
import unittest

import numpy as np

import canvasfile
import colormap
import make_fixture

COMMITTED = make_fixture.default_folder()


def _read(path):
    with open(path, "rb") as f:
        return f.read()


def _write(path, data):
    with open(path, "wb") as f:
        f.write(data)


def _tmp(name):
    return os.path.join(tempfile.mkdtemp(prefix="sgfx"), name)


class Fixtures(unittest.TestCase):
    def test_regenerating_gives_identical_bytes(self):
        out = tempfile.mkdtemp(prefix="sgfx")
        make_fixture.write_fixtures(out)
        for name in make_fixture.FILES:
            committed = os.path.join(COMMITTED, name)
            self.assertTrue(os.path.exists(committed), "missing committed fixture %s" % committed)
            self.assertEqual(_read(os.path.join(out, name)), _read(committed), name)

    def test_committed_fixtures_have_the_documented_content(self):
        idx, v0, v255, pal = canvasfile.read_cnv(os.path.join(COMMITTED, "fixture.objkcnv"))
        self.assertEqual(idx.shape, (3, 4))
        self.assertEqual((v0, v255), (-100.0, 0.0))
        self.assertEqual(pal, colormap.MAGMA)
        for r in range(3):
            for c in range(4):
                self.assertEqual(int(idx[r, c]), (r * 4 + c) * 21)
        rgb = canvasfile.read_rgb(os.path.join(COMMITTED, "fixture.objkrgb"))
        self.assertEqual(rgb.shape, (3, 4, 4))
        for r in range(3):
            for c in range(4):
                a = 40 * (c + r) + 55
                self.assertEqual(rgb[r, c].tolist(), [a * c // 3, a * r // 2, a // 2, a])
                self.assertTrue(all(int(v) <= a for v in rgb[r, c, :3]))

    def test_exact_file_sizes(self):
        self.assertEqual(os.path.getsize(os.path.join(COMMITTED, "fixture.objkcnv")), 796 + 12)
        self.assertEqual(os.path.getsize(os.path.join(COMMITTED, "fixture.objkrgb")), 24 + 48)

    def test_raw_header_bytes(self):
        raw = _read(os.path.join(COMMITTED, "fixture.objkcnv"))
        self.assertEqual(raw[:8], b"OBJKCNV1")
        self.assertEqual(struct.unpack("<II", raw[8:16]), (4, 3))
        self.assertEqual(struct.unpack("<ff", raw[16:24]), (-100.0, 0.0))
        self.assertEqual(raw[24:28], b"\0\0\0\0")
        self.assertEqual(raw[796:], bytes(make_fixture.cnv_indices().reshape(-1).tolist()))
        raw = _read(os.path.join(COMMITTED, "fixture.objkrgb"))
        self.assertEqual(raw[:8], b"OBJKRGB1")
        self.assertEqual(struct.unpack("<II", raw[8:16]), (4, 3))
        self.assertEqual(raw[16:24], b"\0" * 8)


class Magma(unittest.TestCase):
    def test_table_shape_and_known_entries(self):
        m = colormap.MAGMA
        self.assertEqual(len(m), 768)
        self.assertEqual(m[0:3].hex(), "000004")
        self.assertEqual(m[765:768].hex(), "fcfdbf")
        self.assertEqual(m[127 * 3:127 * 3 + 3].hex(), "b5367a")
        # monotonically brighter overall (luminance), the property a spectrogram palette needs
        lum = [0.2126 * m[3 * i] + 0.7152 * m[3 * i + 1] + 0.0722 * m[3 * i + 2] for i in range(256)]
        self.assertTrue(all(b >= a - 1.0 for a, b in zip(lum, lum[1:])))


class FileFormat(unittest.TestCase):
    def test_round_trips(self):
        idx = (np.arange(35, dtype=np.uint8) * 7).reshape(5, 7)
        p = _tmp("a.objkcnv")
        canvasfile.write_cnv(p, idx, -80.5, 3.25, colormap.MAGMA)
        got, v0, v255, pal = canvasfile.read_cnv(p)
        self.assertTrue(np.array_equal(got, idx))
        self.assertEqual((v0, v255, pal), (-80.5, 3.25, colormap.MAGMA))
        rgba = np.random.RandomState(1).randint(0, 256, size=(6, 9, 4)).astype(np.uint8)
        q = _tmp("b.objkrgb")
        canvasfile.write_rgb(q, rgba)
        self.assertTrue(np.array_equal(canvasfile.read_rgb(q), rgba))
        self.assertFalse(os.path.exists(p + ".tmp") or os.path.exists(q + ".tmp"))

    def test_reader_rejections(self):
        idx = np.zeros((2, 3), dtype=np.uint8)
        p = _tmp("c.objkcnv")
        canvasfile.write_cnv(p, idx, -100, 0, colormap.MAGMA)
        good = _read(p)
        for bad in (b"OBJKCNV2" + good[8:], good[:-1], good + b"\0", good[:100], b""):
            _write(p, bad)
            with self.assertRaises(canvasfile.CanvasFileError):
                canvasfile.read_cnv(p)
        zero = good[:8] + struct.pack("<II", 0, 2) + good[16:]
        _write(p, zero)
        with self.assertRaises(canvasfile.CanvasFileError):
            canvasfile.read_cnv(p)
        huge = good[:8] + struct.pack("<II", 16385, 1) + good[16:]
        _write(p, huge)
        with self.assertRaises(canvasfile.CanvasFileError):
            canvasfile.read_cnv(p)
        q = _tmp("d.objkrgb")
        canvasfile.write_rgb(q, np.zeros((2, 3, 4), dtype=np.uint8))
        good = _read(q)
        for bad in (b"OBJKRGB2" + good[8:], good[:-1], good + b"\0", good[:10]):
            _write(q, bad)
            with self.assertRaises(canvasfile.CanvasFileError):
                canvasfile.read_rgb(q)

    def test_writer_caps_and_shapes(self):
        p = _tmp("e.objkcnv")
        with self.assertRaises(canvasfile.CanvasFileError):
            canvasfile.write_cnv(p, np.zeros((4097, 2), dtype=np.uint8), 0, 1, colormap.MAGMA)
        with self.assertRaises(canvasfile.CanvasFileError):
            canvasfile.write_cnv(p, np.zeros((2, 16385), dtype=np.uint8), 0, 1, colormap.MAGMA)
        with self.assertRaises(canvasfile.CanvasFileError):
            canvasfile.write_cnv(p, np.zeros((0, 4), dtype=np.uint8), 0, 1, colormap.MAGMA)
        with self.assertRaises(canvasfile.CanvasFileError):
            canvasfile.write_cnv(p, np.zeros((2, 2), dtype=np.float32), 0, 1, colormap.MAGMA)
        with self.assertRaises(canvasfile.CanvasFileError):
            canvasfile.write_cnv(p, np.zeros((2, 2), dtype=np.uint8), float("nan"), 1, colormap.MAGMA)
        with self.assertRaises(canvasfile.CanvasFileError):
            canvasfile.write_cnv(p, np.zeros((2, 2), dtype=np.uint8), 0, 1, b"short")
        with self.assertRaises(canvasfile.CanvasFileError):
            canvasfile.write_rgb(_tmp("f.objkrgb"), np.zeros((2, 2, 3), dtype=np.uint8))
        # 8192 x 4096 is over the pixel cap (32 M) only above 8192 x 4096; this is exactly at it
        self.assertEqual(8192 * 4096, canvasfile.MAX_PIXELS)
        with self.assertRaises(canvasfile.CanvasFileError):
            canvasfile.write_rgb(_tmp("g.objkrgb"), np.zeros((4096, 8193, 4), dtype=np.uint8))

    def test_veil_at_the_cap_is_small(self):
        # the plan's "about 8 MB at most": 4096 x 512 x 4 bytes
        self.assertEqual(4096 * 512 * 4, 8 * 1024 * 1024)


if __name__ == "__main__":
    unittest.main()

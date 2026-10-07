import math
import os
import struct
import tempfile
import unittest

import numpy as np

import canvasfile
import colormap
import dsp
import image


def _read(path):
    with open(path, "rb") as f:
        return f.read()


def _write(path, data):
    with open(path, "wb") as f:
        f.write(data)


def tone(freq, sr, seconds, amp=1.0):
    t = np.arange(int(sr * seconds)) / float(sr)
    return amp * np.sin(2 * np.pi * freq * t)


class Header(unittest.TestCase):
    def test_indexed_header_and_size(self):
        sr = 48000
        x = tone(1000, sr, 1.0, 0.5)
        p = os.path.join(tempfile.mkdtemp(), "base.objkcnv")
        w, h = image.write_base_image(p, x, sr, 2048, 4)
        raw = _read(p)
        self.assertEqual(raw[:8], b"OBJKCNV1")
        W, H, v0, v255, reserved = struct.unpack("<IIffI", raw[8:28])
        self.assertEqual((W, H, v0, v255, reserved), (w, h, -100.0, 0.0, 0))
        self.assertEqual(H, 1024)
        self.assertEqual(W, len(x) // dsp.hop_for(2048, 4) + 1)
        self.assertEqual(raw[28:796], colormap.MAGMA)
        self.assertEqual(len(raw), 796 + W * H)
        idx, a, b, pal = canvasfile.read_cnv(p)
        self.assertEqual(idx.shape, (1024, W))
        self.assertEqual((a, b), (-100.0, 0.0))


class Content(unittest.TestCase):
    def test_tone_lands_on_its_row(self):
        for sr, f, n, k in ((48000, 1000, 2048, 4), (44100, 5000, 4096, 4), (96000, 3000, 8192, 3), (48000, 15000, 1024, 2)):
            idx = image.build_image(tone(f, sr, 1.5), sr, n, k)
            col = idx[:, idx.shape[1] // 2]
            want = image.row_of_frequency(f, sr)
            self.assertLessEqual(abs(int(col.argmax()) - want), 1, (sr, f, n, k, int(col.argmax()), want))

    def test_low_tone_is_only_as_sharp_as_the_fft(self):
        # at 220 Hz with a 11.7 Hz bin spacing a row is 1.5 Hz wide: the peak can sit up to half a
        # bin (about 4 rows) from the tone. That is the FFT's resolution, not an indexing error.
        sr, n, f = 96000, 8192, 220.0
        idx = image.build_image(tone(f, sr, 1.5), sr, n, 3)
        col = idx[:, idx.shape[1] // 2]
        row_hz = f * math.log(2) * math.log2((sr / 2.0) / 20.0) / 1024
        tol = 1 + int(math.ceil(0.5 * (sr / float(n)) / row_hz))
        self.assertLessEqual(abs(int(col.argmax()) - image.row_of_frequency(f, sr)), tol)

    def test_full_scale_is_near_the_top_of_the_scale(self):
        idx = image.build_image(tone(1000, 48000, 1.0, 1.0), 48000, 2048, 4)
        self.assertGreaterEqual(int(idx.max()), 250)
        # a bin-centred tone is exactly 0 dB: sr / n = 23.4375 Hz, bin 64 = 1500 Hz
        idx = image.build_image(tone(1500, 48000, 1.0, 1.0), 48000, 2048, 4)
        self.assertGreaterEqual(int(idx.max()), 254)

    def test_levels_follow_the_dB_scale(self):
        sr = 48000
        full = image.build_image(tone(1500, sr, 1.0, 1.0), sr, 2048, 4).max()
        for db in (-20.0, -40.0, -60.0):
            idx = image.build_image(tone(1500, sr, 1.0, 10 ** (db / 20.0)), sr, 2048, 4).max()
            want = (100.0 + db) / 100.0 * 255.0
            self.assertAlmostEqual(float(idx), want, delta=1.5, msg=db)
        self.assertGreater(int(full), 250)

    def test_silence_is_zero(self):
        idx = image.build_image(np.zeros(48000), 48000, 2048, 4)
        self.assertEqual(int(idx.max()), 0)
        self.assertEqual(idx.dtype, np.uint8)

    def test_stereo_takes_the_louder_channel(self):
        sr = 48000
        left = tone(500, sr, 1.0, 0.3)
        right = tone(4000, sr, 1.0, 0.9)
        idx = image.build_image(np.stack([left, right], axis=1), sr, 2048, 4)
        col = idx[:, idx.shape[1] // 2]
        top = np.argsort(col)[-1]
        self.assertLessEqual(abs(int(top) - image.row_of_frequency(4000, sr)), 1)
        self.assertGreater(int(col[image.row_of_frequency(500, sr)]), 150)  # the quieter one is there too
        only_right = image.build_image(np.stack([np.zeros(sr), right], axis=1), sr, 2048, 4)
        self.assertEqual(int(only_right.max()), int(image.build_image(right, sr, 2048, 4).max()))

    def test_columns_are_capped_at_8192(self):
        sr = 8000
        rng = np.random.RandomState(1)
        x = rng.uniform(-0.1, 0.1, 2300000)
        idx = image.build_image(x, sr, 1024, 4)
        self.assertEqual(idx.shape, (1024, 8192))
        short = image.build_image(x[:20000], sr, 1024, 4)
        self.assertEqual(short.shape[1], 20000 // 256 + 1)

    def test_a_click_survives_max_pooling(self):
        sr, n, k = 8000, 1024, 4
        h = dsp.hop_for(n, k)
        length = 2300000
        x = np.zeros(length)
        pos = 1000 * h  # exactly a frame centre
        x[pos] = 1.0
        idx = image.build_image(x, sr, n, k)
        self.assertEqual(idx.shape[1], 8192)
        col = image.column_of_time(pos / float(sr), sr, length, 8192)
        # the frame centred on the click sees |X| = w[N/2] = 1 on every bin: dB = -20 log10(N / 4)
        expect = (100.0 - 20 * math.log10(n / 4.0)) / 100.0 * 255.0
        column = idx[:, col]
        self.assertGreaterEqual(int(column.min()), int(expect) - 1)
        self.assertLessEqual(int(column.max()), int(round(expect)) + 3)
        # while the rest of the picture is silent (the neighbours may share the frame's stretch)
        others = np.delete(idx, [c for c in (col - 1, col, col + 1) if 0 <= c < 8192], axis=1)
        self.assertLess(int(others.max()), int(expect))

    def _click_image(self, n, k, sr, seconds, p):
        length = int(sr * seconds)
        x = np.zeros(length)
        x[p] = 1.0
        return image.build_image(x, sr, n, k), length

    def test_click_appears_in_the_column_containing_its_time(self):
        # N = 2048, k = 4 (hop 512) and N = 32768, k = 2 (hop 16384, a third of a second)
        sr = 48000
        for n, k, seconds in ((2048, 4, 3.0), (32768, 2, 10.0)):
            h = dsp.hop_for(n, k)
            for p in [q for q in (7 * h, int(5.123 * sr), int(0.9 * sr) + 17, 3 * h + h // 2) if q < seconds * sr]:
                idx, length = self._click_image(n, k, sr, seconds, p)
                width = idx.shape[1]
                col = image.column_of_time(p / float(sr), sr, length, width)
                profile = idx.max(axis=0).astype(int)
                self.assertEqual(int(profile[col]), int(profile.max()), (n, k, p, col, int(profile.argmax())))
                # and the picture is quiet well away from the click (3 columns and 2 frames)
                far = [c for c in range(width) if abs(c - col) > 3 + (2 * h * width) // length]
                if far:
                    self.assertLess(int(profile[far].max()), int(profile.max()) - 20, (n, k, p))

    def test_old_half_frame_lateness_is_gone(self):
        # a click exactly on a frame centre: that frame's column must contain the click time. With the
        # drawing convention of column c over [c, c+1) * T / W and frame j put in column j, the click
        # at t = j H / sr sat on the LEFT edge of column j and was read H/2 late.
        sr, n, k = 48000, 32768, 2
        h = dsp.hop_for(n, k)
        for m in (3, 11, 20):
            idx, length = self._click_image(n, k, sr, 10.0, m * h)
            width = idx.shape[1]
            profile = idx.max(axis=0).astype(int)
            hot = np.nonzero(profile == profile.max())[0]
            t = m * h / float(sr)
            lo = hot.min() * length / float(sr) / width
            hi = (hot.max() + 1) * length / float(sr) / width
            self.assertLessEqual(lo, t)
            self.assertGreaterEqual(hi, t)
            # the brightest columns straddle the time: the time is not at the far edge of them
            self.assertLessEqual(len(hot), 2)

    def test_no_empty_columns_for_a_steady_tone(self):
        for n, k, seconds in ((2048, 4, 2.0), (32768, 2, 10.0), (1024, 3, 1.5)):
            idx = image.build_image(tone(1500, 48000, seconds), 48000, n, k)
            self.assertTrue(np.all(idx.max(axis=0) > 100), (n, k))

    def test_frame_columns_cover_the_time_axis_exactly(self):
        hop, length = 512, 100000
        width = image.column_count(length, hop)
        j = np.arange(dsp.frame_count(length, hop))
        lo, hi = image.frame_columns(j, hop, length, width)
        covered = np.zeros(width, dtype=bool)
        for a, b in zip(lo, hi):
            covered[a:b + 1] = True
        self.assertTrue(covered.all())
        self.assertTrue(np.all(np.diff(lo) >= 0) and np.all(np.diff(hi) >= 0))
        self.assertEqual(int(lo[0]), 0)
        self.assertEqual(int(hi[-1]), width - 1)
        # the frame that is nearest to a time feeds the column containing it
        for t_samples in (0, 1, 777, 50000, 99999):
            nearest = int(round(t_samples / float(hop)))
            c = int(t_samples * width // length)
            self.assertLessEqual(lo[nearest], c)
            self.assertGreaterEqual(hi[nearest], c)

    def test_empty_signal_is_refused(self):
        with self.assertRaises(ValueError):
            image.build_image(np.zeros(0), 48000, 2048, 4)

    def test_rows_without_bins_interpolate(self):
        # at low frequencies a row is narrower than a bin: no hole, no repeated stair
        idx = image.build_image(tone(100, 48000, 1.0), 48000, 2048, 4)
        col = idx[:, idx.shape[1] // 2].astype(int)
        r = image.row_of_frequency(100, 48000)
        self.assertGreater(col[r], 200)
        self.assertTrue(np.all(np.abs(np.diff(col[r - 30:r + 30])) < 60))

    def test_row_bands_cover_every_bin_once(self):
        starts, groups, interp, i0, i1, wt, first = image.row_bands(48000, 2048)
        self.assertEqual(len(groups) + len(interp), 1024)
        self.assertEqual(len(set(groups.tolist()) & set(interp.tolist())), 0)
        self.assertTrue(np.all(np.diff(starts) > 0))
        self.assertTrue(np.all((wt >= 0) & (wt <= 1)))
        self.assertEqual(first, 1)  # bin 1 is 23.4 Hz, the first at or above 20 Hz


if __name__ == "__main__":
    unittest.main()

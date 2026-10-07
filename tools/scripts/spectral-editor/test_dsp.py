import math
import unittest

import numpy as np

import dsp

RNG = np.random.RandomState(7)


def _unit(j0, j1, n):
    return np.ones((j1 - j0, n // 2 + 1))


def _db(err, ref):
    return 20 * math.log10(max(err, 1e-300) / ref)


class Basics(unittest.TestCase):
    def test_hop_table(self):
        table = {(1024, 2): 512, (2048, 4): 512, (2048, 3): 683, (2048, 5): 410, (2048, 6): 341,
                 (2048, 7): 293, (2048, 8): 256, (2048, 9): 228, (2048, 10): 205, (32768, 10): 3277,
                 (1024, 3): 341, (4096, 7): 585}
        for (n, k), h in table.items():
            self.assertEqual(dsp.hop_for(n, k), h, (n, k))
            self.assertEqual(dsp.hop_for(n, k), int(math.floor(n / k + 0.5)))

    def test_hann_is_periodic(self):
        w = dsp.hann(8)
        self.assertAlmostEqual(w[0], 0.0)
        self.assertAlmostEqual(w[4], 1.0)
        self.assertAlmostEqual(w[2], 0.5)
        self.assertAlmostEqual(w[1], w[7])
        self.assertAlmostEqual(w[1], 0.5 - 0.5 * math.cos(2 * math.pi / 8))

    def test_frame_count(self):
        self.assertEqual(dsp.frame_count(1000, 250), 5)
        self.assertEqual(dsp.frame_count(1001, 250), 6)
        self.assertEqual(dsp.frame_count(1, 250), 2)


class Identity(unittest.TestCase):
    def test_identity_all_sizes_and_overlaps_float64(self):
        x = RNG.uniform(-1, 1, 40000)
        worst = -999.0
        for n in (1024, 2048, 4096, 8192, 16384, 32768):
            for k in range(2, 11):
                y = dsp.process(x, 48000, n, k, lambda a, b, n=n: _unit(a, b, n), np.float64)
                self.assertEqual(y.shape, x.shape)
                worst = max(worst, _db(float(np.max(np.abs(y - x))), 1.0))
        print("identity worst error: %.1f dB" % worst)
        self.assertLessEqual(worst, -120.0)

    def test_float32_path(self):
        x = RNG.uniform(-1, 1, 30001).astype(np.float32)
        for n, k in ((2048, 4), (1024, 3), (8192, 10)):
            y = dsp.process(x, 48000, n, k, lambda a, b, n=n: _unit(a, b, n), np.float32)
            self.assertEqual(y.dtype, np.float32)
            err = float(np.max(np.abs(y.astype(np.float64) - x.astype(np.float64))))
            self.assertLessEqual(err, 4e-7, (n, k, err))

    def test_lengths_not_multiple_of_hop_and_tiny(self):
        for length in (1, 2, 5, 511, 512, 513, 1500, 2049, 4097):
            x = RNG.uniform(-1, 1, length)
            y = dsp.process(x, 48000, 1024, 4, lambda a, b: _unit(a, b, 1024), np.float64)
            self.assertEqual(len(y), length)
            self.assertLessEqual(float(np.max(np.abs(y - x))), 1e-12, length)

    def test_empty_signal(self):
        y = dsp.process(np.zeros(0), 48000, 1024, 4, lambda a, b: _unit(a, b, 1024), np.float64)
        self.assertEqual(len(y), 0)

    def test_mono_and_stereo_shapes(self):
        x = RNG.uniform(-1, 1, (7000, 2))
        y = dsp.process(x, 48000, 1024, 4, lambda a, b: _unit(a, b, 1024), np.float64)
        self.assertEqual(y.shape, (7000, 2))
        self.assertLessEqual(float(np.max(np.abs(y - x))), 1e-12)
        ym = dsp.process(x[:, 0], 48000, 1024, 4, lambda a, b: _unit(a, b, 1024), np.float64)
        self.assertEqual(ym.shape, (7000,))
        self.assertLessEqual(float(np.max(np.abs(ym - y[:, 0]))), 1e-13)
        # channels are processed independently with the same mask
        mask = lambda a, b: np.full((b - a, 513), 0.5) * (np.arange(513) < 100)
        ys = dsp.process(x, 48000, 1024, 4, mask, np.float64)
        y0 = dsp.process(x[:, 0], 48000, 1024, 4, mask, np.float64)
        self.assertLessEqual(float(np.max(np.abs(ys[:, 0] - y0))), 1e-13)


class Masking(unittest.TestCase):
    def test_block_size_independence(self):
        x = RNG.uniform(-1, 1, 30000)
        n, k = 2048, 4
        bins = n // 2 + 1

        def mask(a, b):
            j = np.arange(a, b)[:, None]
            f = np.arange(bins)[None, :]
            return 0.3 + 0.7 * np.abs(np.sin(0.013 * j + 0.0071 * f))

        ref = dsp.process(x, 48000, n, k, mask, np.float64, block=256)
        for blk in (1, 3, 7, 64, 1000):
            y = dsp.process(x, 48000, n, k, mask, np.float64, block=blk)
            self.assertLessEqual(float(np.max(np.abs(y - ref))), 1e-12, blk)

    def test_constant_minus_6_db_is_exact_gain(self):
        x = RNG.uniform(-1, 1, 25000)
        g = 10 ** (-6 / 20)
        for n, k in ((2048, 4), (1024, 2), (4096, 7)):
            y = dsp.process(x, 48000, n, k, lambda a, b, n=n: np.full((b - a, n // 2 + 1), g), np.float64)
            self.assertLessEqual(float(np.max(np.abs(y - x * g))), 1e-12, (n, k))

    def test_mask_removes_a_band(self):
        sr, n = 48000, 2048
        t = np.arange(sr) / sr
        x = 0.4 * np.sin(2 * np.pi * 3000 * t) + 0.4 * np.sin(2 * np.pi * 300 * t)
        f = np.arange(n // 2 + 1) * sr / n
        m = np.where((f > 2000) & (f < 4500), 10 ** (-24 / 20), 1.0)
        y = dsp.process(x, sr, n, 4, lambda a, b: np.tile(m, (b - a, 1)), np.float64)
        mid = slice(sr // 4, 3 * sr // 4)

        def amp(sig, hz):
            c = np.exp(-2j * np.pi * hz * t[mid])
            return 2 * abs(np.mean(sig[mid] * c))

        self.assertAlmostEqual(20 * math.log10(amp(y, 3000) / amp(x, 3000)), -24, delta=0.3)
        self.assertAlmostEqual(20 * math.log10(amp(y, 300) / amp(x, 300)), 0, delta=0.05)

    def test_bad_mask_shape_raises(self):
        with self.assertRaises(ValueError):
            dsp.process(np.zeros(5000), 48000, 1024, 4, lambda a, b: np.ones((1, 1)), np.float64)

    def test_analysis_blocks_match_a_direct_stft(self):
        x = RNG.uniform(-1, 1, (5000, 2))
        n, k = 1024, 4
        h = dsp.hop_for(n, k)
        w = dsp.hann(n)
        got = {}
        for j0, spec in dsp.analysis_blocks(x, n, k, block=5):
            self.assertEqual(spec.shape[0], 2)
            for i in range(spec.shape[1]):
                got[j0 + i] = spec[:, i, :]
        self.assertEqual(len(got), dsp.frame_count(5000, h))
        for j in (0, 1, 7, len(got) - 1):
            for c in range(2):
                seg = np.zeros(n)
                for i in range(n):
                    p = j * h - n // 2 + i
                    if 0 <= p < 5000:
                        seg[i] = x[p, c]
                self.assertLessEqual(float(np.max(np.abs(np.fft.rfft(seg * w) - got[j][c]))), 1e-9)
        # a 1-D input still yields a channel axis
        for _, spec in dsp.analysis_blocks(x[:, 0], n, k):
            self.assertEqual(spec.shape[0], 1)
            break


if __name__ == "__main__":
    unittest.main()

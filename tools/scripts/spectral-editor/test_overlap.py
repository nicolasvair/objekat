"""The overlap factor, end to end (revision 5: "does the Recouvrement setting work?").

What is pinned, for EVERY FFT size and EVERY overlap 2..10 (the whole Expert range):
- the null test: no operation -> the result is the original within -90 dB (it is -300 dB in practice),
  through the very path the script uses (`mask.stft_gain_block_fn` with no step, float32 storage);
- the gain test: a rectangle at -24 dB over a tone attenuates it by -24 dB and leaves the others at 0 dB
  (a wrong window normalisation or a COLA flaw at some hop would show as a level change here);
- ONE hop for the picture and for the processing (`dsp.hop_for`): the image has one column per hop, and
  the mask is sampled at the frames of the same hop;
- the time placement of a rectangle's edge does not depend on the overlap beyond the window itself;
- the setting reaches the transform: `analysis_settings` clamps to 2..10, and the editor, told of a new
  overlap, redraws the picture and the audio at once with the history kept (test_editor.py).
"""
import math
import unittest

import numpy as np

import dsp
import image
import mask
import spectral_editor as sg

SR = 48000
SIZES = (1024, 2048, 4096, 8192, 16384, 32768)
OVERLAPS = tuple(range(2, 11))
LENGTH = int(1.5 * SR)


def world_for(length, sr=SR):
    return {"x": {"min": 0.0, "max": length / float(sr), "unit": "s", "mapping": "lin"},
            "y": {"min": 20.0, "max": sr / 2.0, "unit": "Hz", "mapping": "log"}}


def tones(length=LENGTH, sr=SR):
    t = np.arange(length) / float(sr)
    return t, (0.4 * np.sin(2 * np.pi * 3000 * t) + 0.3 * np.sin(2 * np.pi * 300 * t)).astype(np.float32)


def amp(sig, t, hz, a, b):
    s = slice(int(a * SR), int(b * SR))
    return 2 * abs(np.mean(sig[s].astype(np.float64) * np.exp(-2j * np.pi * hz * t[s])))


def db(ratio):
    return 20 * math.log10(max(ratio, 1e-300))


class NullTest(unittest.TestCase):
    def test_no_operation_gives_back_the_original_for_every_size_and_overlap(self):
        rng = np.random.RandomState(11)
        x = (0.5 * rng.uniform(-1, 1, 40001)).astype(np.float32)  # not a multiple of any hop
        world = world_for(len(x))
        worst = -999.0
        for n in SIZES:
            for k in OVERLAPS:
                fn = mask.stft_gain_block_fn([], [], None, world, SR, n, k, {})
                y = dsp.process(x, SR, n, k, fn, np.float32)
                self.assertEqual(y.shape, x.shape)
                err = float(np.max(np.abs(y.astype(np.float64) - x.astype(np.float64))))
                self.assertLessEqual(db(err / 0.5), -90.0, (n, k))      # the float32 the script writes
                y64 = dsp.process(x, SR, n, k, fn, np.float64)           # and the arithmetic before rounding
                err = float(np.max(np.abs(y64 - x.astype(np.float64))))
                worst = max(worst, db(err / 0.5))
        print("overlap null test, worst error over %d sizes x %d overlaps: %.1f dB (before float32 rounding)"
              % (len(SIZES), len(OVERLAPS), worst))
        self.assertLessEqual(worst, -90.0)

    def test_stereo_and_a_tail_shorter_than_one_frame(self):
        rng = np.random.RandomState(12)
        for length in (300, 5000):
            x = (0.5 * rng.uniform(-1, 1, (length, 2))).astype(np.float32)
            for n, k in ((2048, 2), (2048, 7), (1024, 10), (8192, 3)):
                fn = mask.stft_gain_block_fn([], [], None, world_for(length), SR, n, k, {})
                y = dsp.process(x, SR, n, k, fn, np.float32)
                self.assertLessEqual(float(np.max(np.abs(y - x))) / 0.5, 10 ** (-90 / 20.0), (length, n, k))


class GainTest(unittest.TestCase):
    def test_a_rectangle_at_minus_24_db_is_minus_24_for_every_size_and_overlap(self):
        t, x = tones()
        world = world_for(len(x))
        op = {"id": 1, "kind": "rect", "tool": "rect", "x0": 0.0, "x1": world["x"]["max"], "y0": 2000.0,
              "y1": 4500.0, "params": {}}
        steps = [([op], {"gain": -24, "feather_ms": 10, "feather_st": 1})]
        for n in SIZES:
            for k in OVERLAPS:
                fn = mask.stft_gain_block_fn(steps, [], None, world, SR, n, k, {})
                y = dsp.process(x, SR, n, k, fn, np.float32)
                hi = db(amp(y, t, 3000, 0.5, 1.0) / amp(x, t, 3000, 0.5, 1.0))
                lo = db(amp(y, t, 300, 0.5, 1.0) / amp(x, t, 300, 0.5, 1.0))
                self.assertAlmostEqual(hi, -24.0, delta=0.1, msg=(n, k, hi))
                self.assertAlmostEqual(lo, 0.0, delta=0.05, msg=(n, k, lo))

    def test_the_edge_of_a_rectangle_lands_where_it_was_drawn_at_every_overlap(self):
        """A 3 kHz tone attenuated by 24 dB between 0.8 s and 1.2 s: the -12 dB crossing of the envelope
        lies within 15 ms of the edge, whatever the overlap (the window, 43 ms long at 2048, is what
        smears an edge; the hop only samples the mask)."""
        t = np.arange(2 * SR) / float(SR)
        x = (0.4 * np.sin(2 * np.pi * 3000 * t)).astype(np.float32)
        world = world_for(len(x))
        op = {"id": 1, "kind": "rect", "tool": "rect", "x0": 0.8, "x1": 1.2, "y0": 2000.0, "y1": 4500.0,
              "params": {}}
        steps = [([op], {"gain": -24, "feather_ms": 10, "feather_st": 1})]
        carrier = np.exp(-2j * np.pi * 3000 * t)
        kernel = np.ones(96) / 96.0
        for k in OVERLAPS:
            fn = mask.stft_gain_block_fn(steps, [], None, world, SR, 2048, k, {})
            y = dsp.process(x, SR, 2048, k, fn, np.float32)
            env = 2 * np.abs(np.convolve(y.astype(np.float64) * carrier, kernel, mode="same")) / 0.4
            lo, hi = int(0.6 * SR), int(1.0 * SR)
            cross = t[lo + int(np.argmax(env[lo:hi] < 10 ** (-12 / 20.0)))]
            self.assertLessEqual(abs(cross - 0.8), 0.015, (k, cross))
            self.assertAlmostEqual(db(float(np.mean(env[int(0.95 * SR):int(1.05 * SR)]))), -24.0, delta=0.3)
            self.assertAlmostEqual(db(float(np.mean(env[int(0.2 * SR):int(0.6 * SR)]))), 0.0, delta=0.05)


class OneHop(unittest.TestCase):
    def test_the_picture_has_one_column_per_hop(self):
        t, x = tones(2 * SR)
        widths = []
        for k in OVERLAPS:
            h = dsp.hop_for(2048, k)
            im = image.build_image(x, SR, 2048, k)
            self.assertEqual(im.shape[1], image.column_count(len(x), h), k)
            self.assertEqual(im.shape[1], len(x) // h + 1, k)
            widths.append(im.shape[1])
        self.assertEqual(widths, sorted(widths))          # more overlap, more columns...
        self.assertGreater(widths[-1], 4 * widths[0] - 8)   # ... about k times as many (2 -> 10: x5)

    def test_a_click_lands_in_its_column_at_every_overlap(self):
        x = np.zeros(2 * SR, dtype=np.float32)
        x[SR] = 1.0
        for k in OVERLAPS:
            im = image.build_image(x, SR, 2048, k)
            peaks = im.max(axis=0).astype(int)
            want = image.column_of_time(1.0, SR, len(x), im.shape[1])
            # The frame centred nearest the click feeds the column that contains it: that column holds the
            # peak (within one level of 8 bits: a Hann window is flat near its centre).
            self.assertGreaterEqual(int(peaks[want]), int(peaks.max()) - 1, (k, int(peaks[want]), int(peaks.max())))

    def test_the_mask_is_sampled_at_the_hop_of_the_transform(self):
        """The cell j of the mask is evaluated at j * hop / sr, the frame j of the transform is centred at the
        same time: a mask that is one near t = 0.5 s and zero elsewhere (a feather-free sliver) is heard
        at 0.5 s whatever the overlap."""
        x = np.ones(SR, dtype=np.float32) * 0.0
        t = np.arange(SR) / float(SR)
        x = (0.4 * np.sin(2 * np.pi * 3000 * t)).astype(np.float32)
        world = world_for(len(x))
        op = {"id": 1, "kind": "rect", "tool": "rect", "x0": 0.45, "x1": 0.55, "y0": 2000.0, "y1": 4500.0,
              "params": {}}
        steps = [([op], {"gain": -60, "feather_ms": 0, "feather_st": 0})]
        for k in (2, 3, 4, 7, 10):
            fn = mask.stft_gain_block_fn(steps, [], None, world, SR, 1024, k, {})
            y = dsp.process(x, SR, 1024, k, fn, np.float32)
            env = np.abs(np.convolve(y.astype(np.float64) * np.exp(-2j * np.pi * 3000 * t), np.ones(96) / 96, mode="same"))
            lowest = t[int(np.argmin(env[int(0.2 * SR):int(0.8 * SR)])) + int(0.2 * SR)]
            self.assertLessEqual(abs(lowest - 0.5), 0.03, (k, lowest))


class SettingsReachTheTransform(unittest.TestCase):
    def test_overlap_is_clamped_to_2_to_10_and_rounded(self):
        for given, want in ((2, 2), (10, 10), (1, 2), (0, 2), (11, 10), (99, 10), (6.4, 6), (6.6, 7), ("5", 5),
                            (None, 4), ("x", 4)):
            self.assertEqual(sg.analysis_settings({"fft_size": "2048", "overlap": given})[1], want, given)

    def test_the_hop_table_of_the_expert_range(self):
        for n in SIZES:
            for k in OVERLAPS:
                self.assertEqual(dsp.hop_for(n, k), int(math.floor(n / float(k) + 0.5)))
                self.assertGreaterEqual(dsp.hop_for(n, k), 1)


if __name__ == "__main__":
    unittest.main()

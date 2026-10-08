"""The two largest FFT sizes of the Expert range (16384 and 32768), and everything that leans on the size.

What is pinned here (the null / -24 dB tests for every size and every overlap live in test_overlap.py):
- the choice: the list of the side bar offers 1024 .. 32768, the default stays 2048, and what an OLDER version
  remembered (any size it offered) is still a valid size, while an unknown one falls back on the default;
- an object SHORTER than the window (a window of 32768 is 0.68 s at 48 kHz) is not refused and not clamped: the
  transform zero-pads, the null test holds, a rectangle still gives its gain, the picture is simply coarse
  (one column per hop, never fewer than one);
- the picture: always 1024 rows, within the app's caps (width <= 16384, height <= 4096, width x height <= 32 M)
  even for the longest object the script accepts (600 s) at the finest overlap;
- the log-frequency axis: whatever the rate, the rows partition into "a bin falls inside" and "interpolate",
  with valid bin indices, although a bin is only 1.46 Hz (32768 at 48 kHz) wide.
"""
import math
import unittest

import numpy as np

import canvasfile
import decide
import dsp
import image
import mask
import spectral_editor as sg

SR = 48000
BIG = (16384, 32768)
WINDOW_S = {n: n / float(SR) for n in BIG}


def world_for(length, sr=SR):
    return {"x": {"min": 0.0, "max": length / float(sr), "unit": "s", "mapping": "lin"},
            "y": {"min": 20.0, "max": sr / 2.0, "unit": "Hz", "mapping": "log"}}


def db(ratio):
    return 20 * math.log10(max(ratio, 1e-300))


class TheChoice(unittest.TestCase):
    def test_the_side_bar_offers_every_size_and_the_default_is_unchanged(self):
        self.assertEqual(sg.FFT_SIZES, (1024, 2048, 4096, 8192, 16384, 32768))
        self.assertEqual(sg.DEFAULT_FFT, 2048)
        self.assertEqual(sg.DEFAULT_OVERLAP, 4)
        c = {c["id"]: c for c in sg.canvas_controls()}["fft_size"]
        self.assertEqual(c["kind"], "choice")
        self.assertEqual([o["id"] for o in c["options"]], ["1024", "2048", "4096", "8192", "16384", "32768"])
        self.assertEqual(c["value"], "2048")
        self.assertTrue(c["advanced"])

    def test_every_size_remembered_by_an_older_version_is_still_valid(self):
        # the app stores the choice as the string of its id; an older version offered 1024 .. 32768 too, and
        # earlier ones less: every one of them reads back as itself
        for n in sg.FFT_SIZES:
            for given in (str(n), n, float(n)):
                self.assertEqual(sg.analysis_settings({"fft_size": given, "overlap": 4})[0], n, given)

    def test_an_unknown_size_falls_back_on_the_default(self):
        for given in ("65536", 65536, "3000", "x", None, "", 0):
            self.assertEqual(sg.analysis_settings({"fft_size": given, "overlap": 4})[0], sg.DEFAULT_FFT, given)
        self.assertEqual(sg.analysis_settings({})[0], sg.DEFAULT_FFT)

    def test_the_analysis_is_what_makes_the_picture_stale_not_the_live_values(self):
        # a change of the size is the loop's own business (a new base image): decide ignores it as a live key
        before = {"gain": -12, "feather_ms": 10, "feather_st": 1, "fft_size": "2048"}
        for n in BIG:
            after = dict(before, fft_size=str(n))
            self.assertEqual(decide.preview_dirty(before, after, 1), set())


class ShortObjects(unittest.TestCase):
    LENGTHS = (1, 7, 300, 5000, 20000, 33000)   # samples: from one sample to about one 32768 window

    def test_the_window_is_longer_than_these_objects(self):
        self.assertGreater(WINDOW_S[32768], 0.68)
        self.assertGreater(WINDOW_S[16384], 0.34)

    def test_null_test_on_an_object_shorter_than_the_window(self):
        rng = np.random.RandomState(21)
        worst = -999.0
        for n in BIG:
            for k in (2, 4, 10):
                for length in self.LENGTHS:
                    x = (0.5 * rng.uniform(-1, 1, (length, 2))).astype(np.float32)
                    fn = mask.stft_gain_block_fn([], [], None, world_for(length), SR, n, k, {})
                    y = dsp.process(x, SR, n, k, fn, np.float64)
                    self.assertEqual(y.shape, x.shape)
                    worst = max(worst, db(float(np.max(np.abs(y - x.astype(np.float64)))) / 0.5))
        self.assertLessEqual(worst, -90.0)

    def test_a_rectangle_over_a_short_object_still_gives_its_gain(self):
        length = int(0.3 * SR)          # 0.3 s: under both windows
        t = np.arange(length) / float(SR)
        x = (0.4 * np.sin(2 * np.pi * 3000 * t) + 0.3 * np.sin(2 * np.pi * 300 * t)).astype(np.float32)
        op = {"id": 1, "kind": "rect", "tool": "rect", "x0": 0.0, "x1": length / float(SR), "y0": 2000.0,
              "y1": 4500.0, "params": {}}
        steps = [([op], {"gain": -24, "feather_ms": 10, "feather_st": 1})]

        def amp(sig, hz):
            s = slice(int(0.1 * SR), int(0.2 * SR))
            return 2 * abs(np.mean(sig[s].astype(np.float64) * np.exp(-2j * np.pi * hz * t[s])))

        for n in BIG:
            for k in (2, 4):
                fn = mask.stft_gain_block_fn(steps, [], None, world_for(length), SR, n, k, {})
                y = dsp.process(x, SR, n, k, fn, np.float32)
                self.assertAlmostEqual(db(amp(y, 3000) / amp(x, 3000)), -24.0, delta=0.2, msg=(n, k))
                self.assertAlmostEqual(db(amp(y, 300) / amp(x, 300)), 0.0, delta=0.1, msg=(n, k))

    def test_the_picture_of_a_short_object_is_coarse_but_never_empty(self):
        rng = np.random.RandomState(22)
        for n in BIG:
            for k in (2, 4, 10):
                h = dsp.hop_for(n, k)
                for length in self.LENGTHS:
                    x = (0.5 * rng.uniform(-1, 1, (length, 2))).astype(np.float32)
                    idx = image.build_image(x, SR, n, k)
                    self.assertEqual(idx.shape, (image.ROWS, max(1, length // h + 1)), (n, k, length))
                    self.assertEqual(idx.dtype, np.uint8)
        self.assertEqual(image.column_count(1, 16384), 1)


class ThePictureWithinItsCaps(unittest.TestCase):
    def test_the_longest_accepted_object_fits_the_caps_at_every_size_and_overlap(self):
        length = int(decide.REFUSE_SECONDS * SR)       # 600 s: above this the script refuses
        for n in sg.FFT_SIZES:
            for k in range(2, 11):
                w = image.column_count(length, dsp.hop_for(n, k))
                self.assertGreaterEqual(w, 1)
                self.assertLessEqual(w, image.MAX_COLS)
                self.assertLessEqual(w, canvasfile.MAX_WIDTH)
                self.assertLessEqual(image.ROWS, 4096)
                self.assertLessEqual(w * image.ROWS, 32 * 1024 * 1024)

    def test_a_bigger_window_never_makes_a_wider_picture(self):
        length = 120 * SR
        for k in (2, 4, 10):
            widths = [image.column_count(length, dsp.hop_for(n, k)) for n in sg.FFT_SIZES]
            self.assertEqual(widths, sorted(widths, reverse=True), (k, widths))

    def test_a_real_picture_is_written_and_read_back_at_the_big_sizes(self):
        import os
        import tempfile
        x = (0.3 * np.sin(2 * np.pi * 1000 * np.arange(3 * SR) / float(SR))).astype(np.float32)
        for n in BIG:
            p = os.path.join(tempfile.mkdtemp(), "b.objkcnv")
            w, h = image.write_base_image(p, x, SR, n, 4)
            self.assertEqual((w, h), (3 * SR // dsp.hop_for(n, 4) + 1, 1024))
            with open(p, "rb") as f:
                raw = f.read()
            self.assertEqual(raw[:8], b"OBJKCNV1")
            self.assertEqual(len(raw), 28 + 768 + w * h)


class TheLogFrequencyAxis(unittest.TestCase):
    def test_the_rows_partition_into_bins_and_interpolation_at_every_rate(self):
        for sr in (8000, 44100, 48000, 96000, 192000):
            for n in BIG:
                starts, group_rows, interp_rows, i0, i1, wt, first = image.row_bands(sr, n)
                nb = n // 2 + 1
                self.assertEqual(sorted(list(group_rows) + list(interp_rows)), list(range(image.ROWS)), (sr, n))
                if len(interp_rows):
                    self.assertGreaterEqual(int(i0.min()), 0)
                    self.assertLessEqual(int(i1.max()), nb - 1)
                    self.assertTrue(np.all((wt >= 0.0) & (wt <= 1.0)), (sr, n))
                # the bins under the 20 Hz of the axis are not drawn: the first one drawn is the first >= 20 Hz
                self.assertGreaterEqual(first * sr / float(n), image.F_MIN - 1e-9)
                self.assertLess((first - 1) * sr / float(n), image.F_MIN)

    def test_the_bins_are_1_5_and_2_9_hz_at_48_khz(self):
        self.assertAlmostEqual(SR / 32768.0, 1.4648, places=3)
        self.assertAlmostEqual(SR / 16384.0, 2.9297, places=3)

    def test_a_tone_at_the_bottom_of_the_axis_is_drawn_on_its_row(self):
        # 40 Hz: a bin every 1.46 Hz resolves it at 32768, and the bright row is the one of 40 Hz (+- a few rows)
        t = np.arange(4 * SR) / float(SR)
        x = (0.5 * np.sin(2 * np.pi * 40.0 * t)).astype(np.float32)
        for n in BIG:
            idx = image.build_image(x, SR, n, 4)
            want = image.row_of_frequency(40.0, SR)
            got = int(np.argmax(idx[:, idx.shape[1] // 2].astype(int)))
            self.assertLessEqual(abs(got - want), 12, (n, got, want))


class ClickTimeAtTheBigSizes(unittest.TestCase):
    def test_a_click_lands_in_the_column_of_its_time_at_every_overlap(self):
        seconds = 10.0
        length = int(SR * seconds)
        for n in BIG:
            for k in (2, 3, 4, 7, 10):
                h = dsp.hop_for(n, k)
                x = np.zeros(length, dtype=np.float32)
                p = 9 * h + h // 3
                x[p] = 1.0
                idx = image.build_image(x, SR, n, k)
                col = image.column_of_time(p / float(SR), SR, length, idx.shape[1])
                profile = idx.max(axis=0).astype(int)
                self.assertGreaterEqual(int(profile[col]), int(profile.max()) - 1, (n, k, col, int(profile.argmax())))


if __name__ == "__main__":
    unittest.main()

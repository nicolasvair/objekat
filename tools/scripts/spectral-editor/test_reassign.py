"""The focused (reassigned) display, `reassign.py` (revision 7): display only, same grid as `image.build_db`.

A sine is a line within a few Hz, a click lands within a column, a chirp is followed; two sines that the window cannot
resolve are NOT drawn as two (physics, documented below); everything is finite; the result does not depend on the thread
count; the levels do not depend on the compute size."""
import math
import unittest

import numpy as np

import image
import reassign

SR = 48000
OCTAVES = math.log2((SR / 2.0) / image.F_MIN)


def row_freq(row):
    """The centre frequency of a picture row (row 0 = the top)."""
    return image.F_MIN * 2.0 ** (((image.ROWS - 1 - row) + 0.5) / image.ROWS * OCTAVES)


def tone(freq, seconds=2.0, amp=0.5, phase=0.3):
    t = np.arange(int(SR * seconds)) / float(SR)
    return amp * np.sin(2 * np.pi * freq * t + phase)


def profile(db, lo=0.2, hi=0.8):
    """The energy of each row summed over the middle of the picture."""
    w = db.shape[1]
    return (10.0 ** (db[:, int(w * lo):int(w * hi)] / 10.0)).sum(axis=1)


def centroid_hz(prof, row, half=12):
    lo, hi = max(0, row - half), min(len(prof), row + half + 1)
    r = np.arange(lo, hi)
    return row_freq(float((prof[lo:hi] * r).sum() / prof[lo:hi].sum()))


class Line(unittest.TestCase):
    def test_an_isolated_sine_is_a_line_within_2_hz_where_the_normal_picture_has_a_190_hz_lobe(self):
        x = tone(440.0)
        db = reassign.build_db(x, SR, 512, 4096, 8)
        self.assertEqual(db.shape[0], image.ROWS)
        for col in (db.shape[1] // 4, db.shape[1] // 2, 3 * db.shape[1] // 4):
            r = int(np.argmax(db[:, col]))
            self.assertLess(abs(row_freq(r) - 440.0), 2.0, (col, row_freq(r)))
        self.assertLess(abs(centroid_hz(profile(db), int(np.argmax(profile(db)))) - 440.0), 1.0)
        lit = int((db[:, db.shape[1] // 2] > db[:, db.shape[1] // 2].max() - 20.0).sum())
        normal = image.build_db(x, SR, 512, 4)
        nlit = int((normal[:, normal.shape[1] // 2] > normal[:, normal.shape[1] // 2].max() - 20.0).sum())
        self.assertLessEqual(lit, 5)          # a few rows (3 Hz each at 440 Hz)
        self.assertGreaterEqual(nlit, 40)     # the lobe: ~190 Hz either side, i.e. 60+ rows around 440 Hz

    def test_the_level_reads_like_the_normal_picture_0_db_is_a_full_scale_sine(self):
        for amp in (0.5, 0.1):
            db = reassign.build_db(tone(1000.0, amp=amp), SR, 512, 4096, 8)
            peak = db[:, db.shape[1] // 2].max()
            want = 20 * math.log10(amp)
            self.assertGreater(peak, want - 3.5)        # a line astride two rows reads up to -3 dB on each
            self.assertLess(peak, want + 0.5)
            # the energy of the whole line (the two rows together) is the sine's
            col = 10.0 ** (db[:, db.shape[1] // 2] / 10.0)
            self.assertAlmostEqual(10 * math.log10(col.sum()), want, delta=0.5)

    def test_the_compute_size_moves_neither_the_line_nor_its_level(self):
        x = tone(2000.0)
        ref = reassign.build_db(x, SR, 512, 1024, 8)
        for pad in (4096, 16384):
            db = reassign.build_db(x, SR, 512, pad, 8)
            c = db.shape[1] // 2
            self.assertAlmostEqual(row_freq(int(np.argmax(db[:, c]))), row_freq(int(np.argmax(ref[:, c]))), delta=8.0)
            self.assertAlmostEqual(10 * math.log10((10.0 ** (db[:, c] / 10)).sum()),
                                   10 * math.log10((10.0 ** (ref[:, c] / 10)).sum()), delta=0.5)

    def test_a_linear_chirp_is_followed(self):
        t = np.arange(SR) / float(SR)
        x = 0.5 * np.sin(2 * np.pi * (1000 * t + 1000 * t ** 2))        # 1000 -> 3000 Hz
        db = reassign.build_db(x, SR, 512, 4096, 8)
        for tt in (0.2, 0.4, 0.6, 0.8):
            r = int(np.argmax(db[:, int(tt * db.shape[1])]))
            want = 1000 + 2000 * tt
            self.assertLess(abs(row_freq(r) - want) / want, 0.01, (tt, row_freq(r)))

    def test_a_click_lands_within_one_column_of_its_time(self):
        for n0 in (24037, 9000, 40001):
            x = np.zeros(SR)
            x[n0] = 0.8
            db = reassign.build_db(x, SR, 512, 4096, 8)
            w = db.shape[1]
            col = int(np.argmax((10.0 ** (db / 10.0)).sum(axis=0)))
            self.assertLessEqual(abs(col - int(n0 * w / SR)), 1, (n0, col))


class NotTwo(unittest.TestCase):
    """55 Hz and 61.7 Hz are 6.7 Hz apart; a 512 window has bins of 94 Hz. Reassignment does not invent the resolution
    the window did not keep: the picture is one blur, with no valley between the two true frequencies."""

    def setUp(self):
        t = np.arange(SR * 3) / float(SR)
        self.x = (0.3 * np.sin(2 * np.pi * 55.0 * t) + 0.3 * np.sin(2 * np.pi * 61.7 * t)).astype(np.float32)

    def valley(self, db):
        """min of the (9-row smoothed) row profile between the two true rows / the smaller of the two ends."""
        p = np.convolve(profile(db), np.ones(9) / 9.0, mode="same")
        a, b = image.row_of_frequency(55.0, SR), image.row_of_frequency(61.7, SR)
        lo, hi = min(a, b), max(a, b)
        return float(p[lo:hi + 1].min() / min(p[a], p[b]))

    def test_the_focused_512_picture_has_no_valley_between_them(self):
        self.assertGreaterEqual(self.valley(reassign.build_db(self.x, SR, 512, 4096, 8)), 1.0)

    def test_it_is_only_a_longer_window_that_resolves_them(self):
        self.assertGreaterEqual(self.valley(image.build_db(self.x, SR, 512, 4)), 1.0)
        self.assertLess(self.valley(image.build_db(self.x, SR, 32768, 4)), 0.5)


class LowTones(unittest.TestCase):
    def test_below_two_bins_of_the_window_a_line_is_smeared_a_longer_window_fixes_it(self):
        """Documented limit: the negative-frequency image of a real tone lies inside the mainlobe. 55 Hz is 0.6 bin of a
        512 window and 5 bins of a 2048 one."""
        x = tone(55.0, seconds=3.0)
        near = lambda db: (lambda p: p[max(0, int(np.argmax(p)) - 3):int(np.argmax(p)) + 4].sum() / p.sum())(profile(db))
        self.assertLess(near(reassign.build_db(x, SR, 512, 4096, 8)), 0.5)
        sharp = reassign.build_db(x, SR, 2048, 8192, 8)
        self.assertGreater(near(sharp), 0.9)
        self.assertLess(abs(row_freq(int(np.argmax(profile(sharp)))) - 55.0), 2.0)


class Robust(unittest.TestCase):
    def test_every_value_is_finite_and_the_shape_is_the_normal_grids(self):
        rng = np.random.RandomState(0)
        signals = {
            "noise stereo": (0.3 * rng.randn(SR // 2, 2)).astype(np.float32),
            "silence": np.zeros(SR // 4),
            "dc": np.full(SR // 4, 0.5),
            "square": np.sign(np.sin(2 * np.pi * 300 * np.arange(SR // 4) / SR)),
            "one sample": np.array([0.5]),
            "shorter than the window": (0.3 * rng.randn(100)),
            "mono column": (0.3 * rng.randn(SR // 8, 1)),
        }
        for name, x in signals.items():
            for window, pad in ((512, 4096), (256, 256), (4096, 1024)):     # pad below the window is lifted
                db = reassign.build_db(x, SR, window, pad, 8)
                w = reassign.column_count(np.asarray(x).shape[0], window, 8)
                self.assertEqual(db.shape, (image.ROWS, w), (name, window))
                self.assertTrue(np.isfinite(db).all(), (name, window, pad))
                self.assertLess(float(db.max()), 3.1, (name, window))       # nothing above a full-scale sine (+ rounding)

    def test_silence_is_the_floor_and_the_blank_picture_has_the_same_shape(self):
        db = reassign.build_db(np.zeros(SR // 2), SR, 512, 4096, 8)
        self.assertLess(float(db.max()), -200.0)
        self.assertEqual(reassign.blank_db(SR // 2, 512, 8).shape, db.shape)
        self.assertEqual(reassign.blank_db(1, 4096, 2).shape, reassign.build_db(np.array([0.1]), SR, 4096, 4096, 2).shape)

    def test_the_grid_is_the_normal_one_columns_capped_at_8192(self):
        self.assertEqual(reassign.column_count(SR * 120, 512, 8), 8192)
        self.assertEqual(reassign.column_count(SR, 512, 8), SR // 64 + 1)
        self.assertEqual(reassign.column_count(SR, 512, 8), image.column_count(SR, 64))
        h = reassign.effective_hop(SR * 120, 512, 8, 8192)
        self.assertTrue(64 <= h <= 256, h)          # lifted to bound the work, never above window / 2

    def test_stereo_draws_the_louder_channel_at_each_cell(self):
        left, right = tone(440.0), tone(2000.0)
        both = reassign.build_db(np.stack([left, right], axis=1), SR, 512, 4096, 8)
        for x in (left, right):
            mono = reassign.build_db(x, SR, 512, 4096, 8)
            c = mono.shape[1] // 2
            r = int(np.argmax(mono[:, c]))
            self.assertAlmostEqual(float(both[r, c]), float(mono[r, c]), delta=0.01)

    def test_the_threshold_keeps_faint_noise_out_of_the_picture(self):
        rng = np.random.RandomState(2)
        x = tone(1000.0, seconds=1.0, amp=1.0) + 1e-5 * rng.randn(SR)      # a faint hiss, -100 dB under the sine
        lit = lambda thr: int((reassign.build_db(x, SR, 512, 2048, 8, thr) > -150.0).sum())
        self.assertLess(lit(-60.0), 0.05 * lit(-120.0))                    # above it the hiss is not reassigned at all
        self.assertGreater(lit(-120.0), 20000)

    def test_the_thread_count_changes_nothing(self):
        rng = np.random.RandomState(3)
        x = (0.2 * rng.randn(SR, 2)).astype(np.float32)
        old = reassign.THREADS
        self.addCleanup(setattr, reassign, "THREADS", old)
        reassign.THREADS = 1
        one = reassign.build_db(x, SR, 512, 2048, 8)
        reassign.THREADS = 5
        five = reassign.build_db(x, SR, 512, 2048, 8)
        self.assertLess(float(np.abs(one - five).max()), 1e-6)

    def test_a_signal_of_any_length_and_the_float32_input_do_not_change_the_grid(self):
        x = tone(300.0, seconds=0.7).astype(np.float32)
        a = reassign.build_db(x, SR, 1024, 4096, 4)
        b = reassign.build_db(x.astype(np.float64), SR, 1024, 4096, 4)
        self.assertEqual(a.shape, b.shape)
        self.assertLess(float(np.abs(a - b).max()), 1e-3)

    def test_settings_are_made_safe(self):
        self.assertEqual(reassign.settings(512, 100, 8), (512, 512, 8))      # the transform cannot be shorter than the window
        self.assertEqual(reassign.settings(511, 4096, 1), (512, 4096, 2))
        with self.assertRaises(ValueError):
            reassign.build_db(np.zeros(0), SR)


if __name__ == "__main__":
    unittest.main()

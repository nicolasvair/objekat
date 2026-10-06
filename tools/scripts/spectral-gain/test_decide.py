"""Tests of the pure decisions: depth classes, rates, durations, mono detection, names."""
import os
import tempfile
import unittest

import numpy as np

import decide


class TestDepth(unittest.TestCase):
    def test_classes(self):
        self.assertEqual(decide.depth_class("pcm_int", 16), 16)
        self.assertEqual(decide.depth_class("pcm_int", 24), 24)
        self.assertEqual(decide.depth_class("pcm_float", 32), "f32")

    def test_everything_else_is_24(self):
        for fmt, bits in (("pcm_int", 32), ("pcm_float", 64), ("compressed", None), ("compressed", 16),
                          (None, None), ("pcm_int", 8), ("pcm_float", 16)):
            self.assertEqual(decide.depth_class(fmt, bits), 24, (fmt, bits))

    def test_decide_is_the_highest(self):
        self.assertEqual(decide.decide_depth([16, 16]), 16)
        self.assertEqual(decide.decide_depth([16, 24]), 24)
        self.assertEqual(decide.decide_depth([24, 16, 24]), 24)
        self.assertEqual(decide.decide_depth([16, "f32"]), "f32")
        self.assertEqual(decide.decide_depth([24, "f32", 16]), "f32")
        self.assertEqual(decide.decide_depth(["f32"]), "f32")

    def test_no_source_is_24(self):
        self.assertEqual(decide.decide_depth([]), 24)

    def test_render_depth(self):
        self.assertEqual(decide.render_depth(16), 16)
        self.assertEqual(decide.render_depth(24), 24)
        self.assertEqual(decide.render_depth("f32"), 24)

    def test_write_kind(self):
        self.assertEqual([decide.write_kind(c) for c in (16, 24, "f32")], ["pcm16", "pcm24", "f32"])


class TestRates(unittest.TestCase):
    def test_counts(self):
        self.assertEqual(decide.rate_counts([48000, 48000, 44100]), {48000: 2, 44100: 1})
        self.assertEqual(decide.rate_counts([]), {})

    def test_unreadable_files_are_ignored(self):
        self.assertEqual(decide.rate_counts([None, 44100, 0, None]), {44100: 1})


class TestDuration(unittest.TestCase):
    def test_boundaries(self):
        self.assertEqual(decide.duration_verdict(0.5), "ok")
        self.assertEqual(decide.duration_verdict(120.0), "ok")
        self.assertEqual(decide.duration_verdict(120.01), "warn")
        self.assertEqual(decide.duration_verdict(600.0), "warn")
        self.assertEqual(decide.duration_verdict(600.01), "refuse")
        self.assertEqual(decide.duration_verdict(7200), "refuse")


class TestMono(unittest.TestCase):
    def test_one_channel(self):
        self.assertTrue(decide.is_mono(np.zeros((10, 1))))
        self.assertTrue(decide.is_mono(np.zeros(10)))

    def test_identical_channels(self):
        a = np.random.RandomState(1).randn(100)
        self.assertTrue(decide.is_mono(np.stack([a, a], axis=1)))

    def test_one_sample_apart_is_stereo(self):
        a = np.random.RandomState(1).randn(100)
        b = a.copy()
        b[57] += 1e-12  # exact comparison, not a tolerance
        self.assertFalse(decide.is_mono(np.stack([a, b], axis=1)))

    def test_integers_too(self):
        a = np.arange(50, dtype=np.int32)
        self.assertTrue(decide.is_mono(np.stack([a, a], axis=1)))
        self.assertFalse(decide.is_mono(np.stack([a, a + 1], axis=1)))


class TestNames(unittest.TestCase):
    def test_output_name(self):
        self.assertEqual(decide.output_name("tone"), "tone (spectral)")

    def test_safe_name(self):
        self.assertEqual(decide.safe_name("a/b:c*d"), "a_b_c_d")
        self.assertEqual(decide.safe_name("  . "), "object")
        self.assertEqual(decide.safe_name("é voix"), "é voix")
        self.assertEqual(len(decide.safe_name("x" * 200)), 60)

    def test_unique_path(self):
        with tempfile.TemporaryDirectory() as d:
            p1 = decide.unique_path(d, "tone", " (spectral)")
            self.assertEqual(p1, os.path.join(d, "tone (spectral).wav"))
            open(p1, "w").close()
            p2 = decide.unique_path(d, "tone", " (spectral)")
            self.assertEqual(p2, os.path.join(d, "tone (spectral) 2.wav"))
            open(p2, "w").close()
            self.assertEqual(decide.unique_path(d, "tone", " (spectral)"), os.path.join(d, "tone (spectral) 3.wav"))


if __name__ == "__main__":
    unittest.main()

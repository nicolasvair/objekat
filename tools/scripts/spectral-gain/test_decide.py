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


class TestPreviewDirty(unittest.TestCase):
    BASE = {"gain": -12.0, "feather_ms": 10.0, "feather_st": 1.0, "fft_size": "2048", "overlap": 4, "size_px": 32,
            "quantity": 25.0, "hardness": 50.0}

    def dirty(self, pending, **changes):
        values = dict(self.BASE)
        values.update(changes)
        return decide.preview_dirty(dict(self.BASE), values, pending)

    def test_live_keys(self):
        self.assertEqual(decide.LIVE_KEYS, ("gain", "feather_ms", "feather_st"))

    def test_nothing_pending_nothing_stale(self):
        for changes in ({}, {"gain": -6.0}, {"feather_ms": 50.0}, {"feather_st": 3.0},
                        {"gain": 0.0, "feather_ms": 0.0, "feather_st": 0.0}, {"fft_size": "4096"}):
            self.assertEqual(self.dirty(0, **changes), set(), changes)

    def test_nothing_changed(self):
        self.assertEqual(self.dirty(1), set())
        self.assertEqual(self.dirty(4), set())

    def test_gain_alone_is_audio_only(self):
        self.assertEqual(self.dirty(1, gain=-6.0), {"audio"})
        self.assertEqual(self.dirty(3, gain=12.0), {"audio"})

    def test_a_feather_is_both(self):
        self.assertEqual(self.dirty(1, feather_ms=50.0), {"selection", "audio"})
        self.assertEqual(self.dirty(1, feather_st=2.5), {"selection", "audio"})
        self.assertEqual(self.dirty(2, feather_ms=50.0, feather_st=0.0), {"selection", "audio"})

    def test_a_feather_with_the_gain_is_still_both(self):
        self.assertEqual(self.dirty(1, gain=-3.0, feather_ms=5.0), {"selection", "audio"})

    def test_the_other_values_are_not_a_live_preview(self):
        for changes in ({"fft_size": "4096"}, {"overlap": 6}, {"size_px": 80}, {"quantity": 60.0}, {"hardness": 10.0}):
            self.assertEqual(self.dirty(2, **changes), set(), changes)

    def test_int_and_float_of_one_value_are_equal(self):
        self.assertEqual(decide.preview_dirty({"gain": -12}, {"gain": -12.0}, 1), set())

    def test_never_seen_before_counts_as_all_changed(self):
        self.assertEqual(decide.preview_dirty(None, dict(self.BASE), 1), {"selection", "audio"})
        self.assertEqual(decide.preview_dirty(None, dict(self.BASE), 0), set())

    def test_a_key_absent_from_both_is_not_a_change(self):
        self.assertEqual(decide.preview_dirty({"gain": -12}, {"gain": -12}, 1), set())
        self.assertEqual(decide.preview_dirty({"gain": -12}, {"gain": -6}, 1), {"audio"})


if __name__ == "__main__":
    unittest.main()

"""Operations drawn while listening to the DIFFERENCE (revision 6, plan 12).

An op carries the slot the hand was listening to (`slot`: original | result | delta). Drawn on "delta" it acts
on the difference D = original - result = original * (1 - G): a step of linear gain g there makes
D' = D * g, so G' = 1 - (1 - G) * g, and the result and the difference stay complementary.
What is pinned here:
- which op/step targets the difference (the first op decides, anything but "delta" is the result);
- the formula, pointwise, and the grid against the pointwise reference (steps and a pending selection);
- the order of the steps matters, and a result-only history is bit for bit what it was before;
- a boost of the difference floors the result at -300 dB, never below;
- through the real transform: Result + Difference = Original, the difference is `original * (1 - G)`, and
  attenuating the difference by g gives back that much of the original in the result.
"""
import math
import unittest

import numpy as np

import dsp
import mask

SR = 48000
AUDIO = {"x": {"min": 0.0, "max": 10.0, "mapping": "lin"}, "y": {"min": 20.0, "max": 24000.0, "mapping": "log"}}


def rect(x0, x1, y0, y1, slot=None, polarity="add", oid=1):
    op = {"id": oid, "kind": "rect", "tool": "rect", "polarity": polarity,
          "x0": x0, "x1": x1, "y0": y0, "y1": y1, "params": {}}
    if slot:
        op["slot"] = slot
    return op


def brush(points, slot=None, oid=1):
    op = {"id": oid, "kind": "stroke", "tool": "brush", "polarity": "add",
          "points": [list(p) for p in points], "size_pt": 32, "size_x": 0.8, "size_y": 1.0,
          "params": {"quantity": 60.0, "hardness": 40.0}}
    if slot:
        op["slot"] = slot
    return op


def step(ops, gain, fms=0.0, fst=0.0):
    return (list(ops), {"gain": gain, "feather_ms": fms, "feather_st": fst})


def lin(db):
    return 10.0 ** (db / 20.0)


class Target(unittest.TestCase):
    def test_delta_is_the_difference_everything_else_the_result(self):
        self.assertEqual(mask.op_target({"slot": "delta"}), "difference")
        for slot in ("original", "result", None, "", "anything"):
            self.assertEqual(mask.op_target({"slot": slot} if slot is not None else {}), "result", slot)

    def test_a_step_takes_the_target_of_its_first_op(self):
        d, r = rect(1, 2, 100, 1000, "delta"), rect(1, 2, 100, 1000, "result")
        self.assertEqual(mask.step_target([d, r]), "difference")
        self.assertEqual(mask.step_target([r, d]), "result")
        self.assertEqual(mask.step_target([]), "result")


class Formula(unittest.TestCase):
    def test_result_only_history_is_the_db_sum_as_before(self):
        steps = [step([rect(2, 6, 300, 3000)], -9, fms=40, fst=2), step([brush([(1, 500), (5, 700)], "result", 2)], 4)]
        for x, y in ((3.0, 800.0), (1.9, 400.0), (5.0, 650.0), (9.0, 50.0)):
            self.assertEqual(mask.linear_gain_at(x, y, steps, AUDIO),
                             10.0 ** (max(mask.gain_at(x, y, steps, AUDIO), -300.0) / 20.0))

    def test_attenuating_the_difference_restores_the_original(self):
        # result -6 dB, then -12 dB on the difference: G' = 1 - (1 - G) * g
        a, b = rect(2, 6, 300, 3000, "result", oid=1), rect(2, 6, 300, 3000, "delta", oid=2)
        steps = [step([a], -6), step([b], -12)]
        g1, g2 = lin(-6), lin(-12)
        got = mask.linear_gain_at(4.0, 1000.0, steps, AUDIO)
        self.assertAlmostEqual(got, 1.0 - (1.0 - g1) * g2, places=12)
        self.assertGreater(got, g1)               # more of the original is back
        self.assertLess(got, 1.0)
        # the difference is what was multiplied by g
        self.assertAlmostEqual(1.0 - got, (1.0 - g1) * g2, places=12)

    def test_a_difference_step_on_an_untouched_zone_changes_nothing(self):
        # D = 0 there: attenuating nothing gives nothing
        steps = [step([rect(2, 6, 300, 3000, "delta")], -20)]
        self.assertAlmostEqual(mask.linear_gain_at(4.0, 1000.0, steps, AUDIO), 1.0, places=12)

    def test_pro_rata_on_the_difference(self):
        # a feathered edge: S = 0.5 at the edge, so g = lin(gain * 0.5)
        a = rect(2, 6, 300, 3000, "result", oid=1)
        b = rect(2, 6, 300, 3000, "delta", oid=2)
        steps = [step([a], -12), step([b], -12, fms=1000)]
        x_edge, y = 2.0, 1000.0                    # the left edge, 1000 ms feather: S = 0.5
        s = mask.selection_at(x_edge, y, [b], AUDIO, 1000.0, 0.0)
        self.assertAlmostEqual(s, 0.5, places=9)
        g_res = lin(-12.0 * mask.selection_at(x_edge, y, [a], AUDIO, 0.0, 0.0))
        got = mask.linear_gain_at(x_edge, y, steps, AUDIO)
        self.assertAlmostEqual(got, 1.0 - (1.0 - g_res) * lin(-6.0), places=9)

    def test_the_order_of_the_steps_matters(self):
        a, b = rect(2, 6, 300, 3000, "result", oid=1), rect(2, 6, 300, 3000, "delta", oid=2)
        ab = mask.linear_gain_at(4.0, 1000.0, [step([a], -6), step([b], -12)], AUDIO)
        ba = mask.linear_gain_at(4.0, 1000.0, [step([b], -12), step([a], -6)], AUDIO)
        self.assertAlmostEqual(ba, lin(-6), places=12)       # nothing to restore yet, then -6 on the result
        self.assertNotAlmostEqual(ab, ba, places=3)

    def test_a_result_step_after_a_difference_step_multiplies(self):
        a, b, c = (rect(2, 6, 300, 3000, s, oid=i) for i, s in ((1, "result"), (2, "delta"), (3, "original")))
        steps = [step([a], -6), step([b], -12), step([c], -3)]
        g = 1.0 - (1.0 - lin(-6)) * lin(-12)
        self.assertAlmostEqual(mask.linear_gain_at(4.0, 1000.0, steps, AUDIO), g * lin(-3), places=12)

    def test_the_pending_selection_is_composed_last_on_its_own_target(self):
        a, b = rect(2, 6, 300, 3000, "result", oid=1), rect(2, 6, 300, 3000, "delta", oid=2)
        live = {"gain": -12.0, "feather_ms": 0.0, "feather_st": 0.0}
        got = mask.linear_gain_at(4.0, 1000.0, [step([a], -6)], AUDIO, [b], live)
        self.assertAlmostEqual(got, 1.0 - (1.0 - lin(-6)) * lin(-12), places=12)
        # the same selection drawn on the result: the plain sum
        c = rect(2, 6, 300, 3000, "result", oid=3)
        self.assertAlmostEqual(mask.linear_gain_at(4.0, 1000.0, [step([a], -6)], AUDIO, [c], live), lin(-18), places=12)

    def test_boosting_the_difference_cannot_go_below_the_floor(self):
        a, b = rect(2, 6, 300, 3000, "result", oid=1), rect(2, 6, 300, 3000, "delta", oid=2)
        got = mask.linear_gain_at(4.0, 1000.0, [step([a], -6), step([b], 12)], AUDIO)   # D = 0.5, x3.98 -> beyond 1
        self.assertEqual(got, mask.LINEAR_FLOOR)
        # a boost that stays short of the whole original is an ordinary composition
        got = mask.linear_gain_at(4.0, 1000.0, [step([a], -24), step([b], 0.5)], AUDIO)
        self.assertAlmostEqual(got, 1.0 - (1.0 - lin(-24)) * lin(0.5), places=12)
        self.assertGreater(got, mask.LINEAR_FLOOR)


class Grid(unittest.TestCase):
    def test_the_grid_equals_the_pointwise_reference(self):
        ops = [rect(2, 6, 300, 3000, "result", oid=1),
               brush([(1, 500), (5, 700), (8, 4000)], "result", oid=2),
               rect(0, 5, 1000, 24000, "delta", oid=3),
               brush([(2, 2000), (9, 2100)], "delta", oid=4),
               rect(3, 9, 100, 5000, "original", oid=5),
               rect(1, 8, 200, 8000, "delta", oid=6)]
        steps = [step(ops[:2], -9, fms=40, fst=2), step(ops[2:4], -7, fms=10, fst=1), step(ops[4:5], 3)]
        draft, live = ops[5:], {"gain": -15.0, "feather_ms": 25.0, "feather_st": 0.5}
        xw = np.linspace(-0.5, 10.5, 41)
        yw = np.log2(np.exp(np.linspace(math.log(15), math.log(26000), 37)))
        g = mask.linear_gain_grid(steps, xw, yw, AUDIO, draft, live)
        self.assertEqual(g.shape, (41, 37))
        worst = 0.0
        for i, x in enumerate(xw):
            for j, y in enumerate(yw):
                worst = max(worst, abs(g[i, j] - mask.linear_gain_at_warped(x, y, steps, AUDIO, draft, live)))
        self.assertLessEqual(worst, 1e-12)
        self.assertGreater(float(np.abs(g - 1.0).max()), 0.3)          # not vacuous
        self.assertLess(float(g.min()), 0.9)

    def test_without_a_difference_step_the_grid_is_the_old_db_grid_exactly(self):
        ops = [rect(2, 6, 300, 3000, "result", oid=1), brush([(1, 500), (5, 700)], "original", oid=2)]
        steps = [step(ops[:1], -9, fms=40), step(ops[1:], 4)]
        xw = np.linspace(0, 10, 30)
        yw = np.log2(np.geomspace(20, 24000, 25))
        self.assertTrue(np.array_equal(mask.linear_gain_grid(steps, xw, yw, AUDIO),
                                       mask.to_linear(mask.gain_grid(steps, xw, yw, AUDIO))))


def amp(sig, hz, a, b):
    t = np.arange(len(sig)) / float(SR)
    s = slice(int(a * SR), int(b * SR))
    return 2 * abs(np.mean(sig[s].astype(np.float64) * np.exp(-2j * np.pi * hz * t[s])))


class Complementarity(unittest.TestCase):
    """Through the real transform: 2 s of 3 kHz + 300 Hz; the high band is attenuated on the result, then on
    the difference."""

    @classmethod
    def setUpClass(cls):
        n, k = 2048, 4
        t = np.arange(2 * SR) / float(SR)
        cls.x = (0.4 * np.sin(2 * np.pi * 3000 * t) + 0.3 * np.sin(2 * np.pi * 300 * t)).astype(np.float32)
        cls.world = {"x": {"min": 0.0, "max": 2.0, "mapping": "lin"},
                     "y": {"min": 20.0, "max": SR / 2.0, "mapping": "log"}}
        high = lambda slot, oid: rect(0, 2, 2000, 5000, slot, oid=oid)   # noqa: E731
        cls.steps = [step([high("result", 1)], -24), step([high("delta", 2)], -12)]
        cls.fns = (mask.stft_gain_block_fn(cls.steps, [], None, cls.world, SR, n, k, {}),)   # a tuple: not bound as a method
        cls.y = dsp.process(cls.x, SR, n, k, cls.fns[0], np.float32)
        cls.delta = cls.x - cls.y
        cls.n, cls.k = n, k

    def test_result_plus_difference_is_the_original(self):
        back = self.y.astype(np.float64) + self.delta.astype(np.float64)
        self.assertLess(float(np.max(np.abs(back - self.x.astype(np.float64)))), 1e-6)

    def test_the_difference_is_the_original_through_one_minus_g(self):
        comp = dsp.process(self.x, SR, self.n, self.k, lambda a, b: 1.0 - self.fns[0](a, b), np.float32)
        err = float(np.max(np.abs(comp.astype(np.float64) - self.delta.astype(np.float64))))
        self.assertLess(err, 1e-5)                                       # about -100 dB re full scale

    def test_levels_are_those_of_the_formula(self):
        g = 1.0 - (1.0 - lin(-24)) * lin(-12)          # the result's gain on the high band
        d = (1.0 - lin(-24)) * lin(-12)                # the difference's, relative to the original
        x3 = amp(self.x, 3000, 0.5, 1.5)
        self.assertAlmostEqual(amp(self.y, 3000, 0.5, 1.5) / x3, g, delta=0.002)
        self.assertAlmostEqual(amp(self.delta, 3000, 0.5, 1.5) / x3, d, delta=0.002)
        # the untouched band is untouched in the result and absent from the difference
        self.assertAlmostEqual(amp(self.y, 300, 0.5, 1.5) / amp(self.x, 300, 0.5, 1.5), 1.0, delta=0.002)
        self.assertLess(amp(self.delta, 300, 0.5, 1.5) / amp(self.x, 300, 0.5, 1.5), 0.002)

    def test_attenuating_the_difference_brings_the_original_back_into_the_result(self):
        before = dsp.process(self.x, SR, self.n, self.k,
                             mask.stft_gain_block_fn(self.steps[:1], [], None, self.world, SR, self.n, self.k, {}), np.float32)
        x3 = amp(self.x, 3000, 0.5, 1.5)
        self.assertGreater(amp(self.y, 3000, 0.5, 1.5), amp(before, 3000, 0.5, 1.5) * 3.0)
        # the difference was divided by 4 (-12 dB): what the first step took away is now a quarter of it
        d_before = amp(self.x - before, 3000, 0.5, 1.5) / x3
        d_after = amp(self.delta, 3000, 0.5, 1.5) / x3
        self.assertAlmostEqual(d_after / d_before, lin(-12), delta=0.002)


if __name__ == "__main__":
    unittest.main()

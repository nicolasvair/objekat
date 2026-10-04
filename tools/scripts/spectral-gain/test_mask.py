import math
import unittest

import numpy as np

import mask

LIN = {"x": {"min": 0.0, "max": 100.0, "mapping": "lin"}, "y": {"min": 0.0, "max": 100.0, "mapping": "lin"}}
AUDIO = {"x": {"min": 0.0, "max": 10.0, "mapping": "lin"}, "y": {"min": 20.0, "max": 24000.0, "mapping": "log"}}
RNG = np.random.RandomState(3)


def eraser(points, size_x=1.0, size_y=1.0, amount=-3.0, hardness=50.0, oid=1):
    return {"id": oid, "kind": "stroke", "tool": "eraser", "points": [list(p) for p in points],
            "size_pt": 32, "size_x": size_x, "size_y": size_y,
            "params": {"amount": amount, "hardness": hardness}}


def rect(x0, x1, y0, y1, gain=-12.0, fms=0.0, fst=0.0, oid=1):
    return {"id": oid, "kind": "rect", "tool": "rect", "x0": x0, "x1": x1, "y0": y0, "y1": y1,
            "params": {"gain": gain, "feather_ms": fms, "feather_st": fst}}


def centre_line(op, xs, y=50.0, world=LIN):
    return np.array([mask.gain_at(x, y, [op], world) for x in xs])


class Profile(unittest.TestCase):
    def test_values(self):
        self.assertEqual(mask.profile(0.0, 0.0), 1.0)
        self.assertEqual(mask.profile(1.0, 0.0), 0.0)
        self.assertEqual(mask.profile(1.5, 0.5), 0.0)
        self.assertAlmostEqual(mask.profile(0.5, 0.0), 0.5)
        self.assertAlmostEqual(mask.profile(0.75, 0.5), 0.5)
        self.assertEqual(mask.profile(0.4, 0.5), 1.0)
        self.assertEqual(mask.profile(0.5, 0.5), 1.0)
        self.assertEqual(mask.profile(0.99, 1.0), 1.0)
        self.assertEqual(mask.profile(1.0, 1.0), 0.0)
        self.assertAlmostEqual(mask.profile(0.25, 0.0), 0.5 + 0.5 * math.cos(math.pi * 0.25))

    def test_per_dab(self):
        self.assertAlmostEqual(mask.per_dab_db(-3, 0.0), -1.5)
        self.assertAlmostEqual(mask.per_dab_db(-3, 0.5), -3 * mask.spacing_for(0.5) / 0.75)
        self.assertAlmostEqual(mask.per_dab_db(-3, 1.0), -3.0 / 64.0)
        self.assertAlmostEqual(mask.per_dab_db(-8, 0.3), -8 * 0.5 / 1.3)

    def test_ramp(self):
        self.assertEqual(mask.ramp(-1), 0.0)
        self.assertEqual(mask.ramp(0), 0.0)
        self.assertEqual(mask.ramp(1), 1.0)
        self.assertEqual(mask.ramp(2), 1.0)
        self.assertAlmostEqual(mask.ramp(0.5), 0.5)
        self.assertAlmostEqual(mask.ramp(0.25), 0.5 - 0.5 * math.cos(math.pi / 4))


def ripple_percent(hardness, amount=-3.0):
    """Worst deviation from `amount`, in % of amount, on the centre line of a long straight stroke,
    over one dab period of phases (offset so that no sample sits on a profile discontinuity)."""
    s = mask.spacing_for(hardness / 100.0)
    op = eraser([(10, 50), (90, 50)], amount=amount, hardness=hardness)
    xs = np.arange(30.0, 30.0 + s, s / 97.0) + 0.00123
    g = centre_line(op, xs)
    return 100.0 * float(np.max(np.abs(g - amount))) / abs(amount), float(np.mean(g))


class Spacing(unittest.TestCase):
    def test_values(self):
        self.assertEqual(mask.spacing_for(0.0), 0.25)
        self.assertEqual(mask.spacing_for(0.3), 0.25)
        self.assertEqual(mask.spacing_for(1.0), 1.0 / 64.0)
        self.assertAlmostEqual(mask.spacing_for(0.65), (0.25 + 1.0 / 64.0) / 2.0)
        self.assertEqual(mask.spacing_for(-1.0), 0.25)
        self.assertEqual(mask.spacing_for(7.0), 1.0 / 64.0)

    def test_monotone_and_continuous(self):
        hs = np.arange(0.0, 1.0001, 0.001)
        sp = [mask.spacing_for(h) for h in hs]
        self.assertTrue(all(b <= a + 1e-15 for a, b in zip(sp, sp[1:])))
        self.assertLess(max(abs(a - b) for a, b in zip(sp, sp[1:])), 0.001)

    def test_dab_density(self):
        # a stroke of 4 diameters: 4 / spacing dabs
        for hp, n in ((0, 16), (30, 16), (100, 256)):
            p = mask.eraser_from_op(eraser([(0, 50), (4, 50)], hardness=float(hp)), LIN)
            self.assertEqual(len(p["dabs"]), n, hp)
            self.assertAlmostEqual(p["spacing"], mask.spacing_for(hp / 100.0))

    def test_per_dab_amount_follows_the_spacing(self):
        for h in (0.0, 0.3, 0.5, 1.0):
            self.assertAlmostEqual(mask.per_dab_db(-3, h), -3 * mask.spacing_for(h) / (0.5 * (1 + h)))
        self.assertAlmostEqual(mask.per_dab_db(-3, 1.0), -3.0 / 64.0 / 1.0)


class Calibration(unittest.TestCase):
    PHASES = np.arange(30.0, 30.25, 0.0125)  # one soft-brush lattice period, on the centre line

    def test_ripple_is_at_most_2_percent_for_every_hardness(self):
        worst = {}
        for hp in list(range(0, 101, 10)) + [5, 15, 25, 35, 45, 55, 65, 75, 85, 95, 98, 99]:
            worst[hp], mean = ripple_percent(float(hp))
            self.assertLessEqual(worst[hp], 2.0, hp)
            self.assertAlmostEqual(mean, -3.0, delta=1e-3, msg=hp)
        print("eraser ripple %% by hardness: " + ", ".join(
            "%d: %.2f" % (k, v) for k, v in sorted(worst.items()) if k % 10 == 0))

    def test_ripple_on_a_fine_hardness_sweep(self):
        for hp in range(0, 101, 2):
            self.assertLessEqual(ripple_percent(float(hp))[0], 2.0, hp)

    def test_exact_where_the_lattice_is_commensurate(self):
        # soft brushes keep the historical spacing and the historical exactness
        for hp in (0.0, 25.0):
            self.assertLessEqual(ripple_percent(hp)[0], 1e-7, hp)

    def test_amount_scales_linearly(self):
        for amount in (-0.5, -3.0, -24.0):
            for hp in (0.0, 50.0, 90.0, 100.0):
                self.assertLessEqual(ripple_percent(hp, amount)[0], 2.0, (amount, hp))

    def test_within_2_percent_for_h_03(self):
        op = eraser([(10, 50), (90, 50)], hardness=30.0)
        g = centre_line(op, self.PHASES)
        self.assertLessEqual(float(np.max(np.abs(g + 3.0))) / 3.0, 0.02)

    def test_hard_brush_on_a_grid_aligned_stroke_has_no_cell_jumps(self):
        # h = 1 is a box: a cell lying exactly on its edge used to flip by a whole dab. With 64 dabs
        # per diameter the worst a single flip can do is 1/64 of the amount.
        op = eraser([(10, 50), (90, 50)], hardness=100.0)
        xs = np.arange(30.0, 31.0, 1.0 / 64.0)  # lattice-aligned samples
        g = centre_line(op, xs)
        self.assertLessEqual(float(np.max(np.abs(g + 3.0))) / 3.0, 1.0 / 64.0 + 1e-9)

    def test_oblique_stroke_and_anisotropic_sizes(self):
        op = eraser([(10, 20), (80, 80)], size_x=2.0, size_y=3.0, hardness=50.0)
        t = np.arange(0.4, 0.6, 0.001)
        g = np.array([mask.gain_at(10 + 70 * s, 20 + 60 * s, [op], LIN) for s in t])
        self.assertLessEqual(float(np.max(np.abs(g + 3.0))) / 3.0, 0.02)

    def test_calibration_on_a_log_axis_in_octaves(self):
        # size_y = 1 octave, a horizontal stroke at 3 kHz: -3 dB on the line, 0 one half-octave away
        op = eraser([(-1, 3000.0), (11, 3000.0)], size_x=0.5, size_y=1.0, hardness=50.0)
        world = {"x": {"min": -5.0, "max": 15.0, "mapping": "lin"}, "y": AUDIO["y"]}
        for x in (3.0, 5.0, 5.013, 7.77):
            self.assertAlmostEqual(mask.gain_at(x, 3000.0, [op], world), -3.0, delta=0.06)
        self.assertAlmostEqual(mask.gain_at(5.0, 3000.0 * 2 ** 0.5, [op], world), 0.0, delta=1e-12)
        self.assertAlmostEqual(mask.gain_at(5.0, 3000.0 / 2 ** 0.5, [op], world), 0.0, delta=1e-12)
        self.assertLess(mask.gain_at(5.0, 3000.0 * 2 ** 0.25, [op], world), 0.0)


class Accumulation(unittest.TestCase):
    def test_out_and_back_is_double_three_passes_triple(self):
        for hp in (0.0, 50.0, 100.0):
            xs = np.arange(40.0, 60.0, 0.173)
            one = eraser([(10, 50), (90, 50)], hardness=hp)
            two = eraser([(10, 50), (90, 50), (10, 50)], hardness=hp)
            three = eraser([(10, 50), (90, 50), (10, 50), (90, 50)], hardness=hp)
            for op, k in ((one, 1), (two, 2), (three, 3)):
                self.assertLessEqual(float(np.max(np.abs(centre_line(op, xs) + 3 * k))) / (3 * k), 0.02, (hp, k))

    def test_two_separate_strokes_add_up(self):
        a = eraser([(10, 50), (90, 50)], oid=1)
        b = eraser([(20, 50), (80, 50)], oid=2, amount=-5.0)
        for x in (35.0, 50.0, 61.3):
            self.assertAlmostEqual(mask.gain_at(x, 50, [a, b], LIN), -8.0, delta=0.16)
            self.assertAlmostEqual(mask.gain_at(x, 50, [a, b], LIN),
                                   mask.gain_at(x, 50, [a], LIN) + mask.gain_at(x, 50, [b], LIN), delta=1e-12)

    def test_crossing_strokes_add_at_the_crossing(self):
        a = eraser([(10, 50), (90, 50)], oid=1)
        b = eraser([(50, 10), (50, 90)], oid=2)
        self.assertAlmostEqual(mask.gain_at(50, 50, [a, b], LIN), -6.0, delta=0.12)


class Stillness(unittest.TestCase):
    def test_still_hand_deposits_nothing(self):
        self.assertEqual(mask.dab_centres([5.0] * 10, [5.0] * 10), [])
        self.assertEqual(mask.dab_centres([1.0], [2.0]), [])
        self.assertEqual(mask.dab_centres([], []), [])
        op = eraser([(50, 50)] * 5)
        self.assertEqual(mask.gain_at(50, 50, [op], LIN), 0.0)

    def test_first_dab_is_at_an_eighth_of_a_diameter(self):
        self.assertEqual(mask.dab_centres([0.0, 0.1], [0.0, 0.0]), [])
        d = mask.dab_centres([0.0, 0.13], [0.0, 0.0])
        self.assertEqual(len(d), 1)
        self.assertAlmostEqual(d[0][0], 0.125)
        d = mask.dab_centres([0.0, 1.0], [0.0, 0.0])
        self.assertEqual([round(p[0], 12) for p in d], [0.125, 0.375, 0.625, 0.875])

    def test_dense_resampling_gives_the_same_dabs(self):
        u = [0.0, 1.31, 1.9, 0.7, 3.3]
        v = [0.0, 0.4, 1.7, 2.2, 0.31]
        ref = mask.dab_centres(u, v)
        du, dv = [u[0]], [v[0]]
        for i in range(1, len(u)):
            seg = math.hypot(u[i] - u[i - 1], v[i] - v[i - 1])
            m = int(seg / 0.007) + 1
            for s in range(1, m + 1):
                t = s / float(m)
                du.append(u[i - 1] + t * (u[i] - u[i - 1]))
                dv.append(v[i - 1] + t * (v[i] - v[i - 1]))
        dense = mask.dab_centres(du, dv)
        self.assertEqual(len(dense), len(ref))
        self.assertLessEqual(max(math.hypot(a[0] - b[0], a[1] - b[1]) for a, b in zip(ref, dense)), 1e-9)

    def test_duplicate_points_change_nothing(self):
        u = [0.0, 0.0, 1.0, 1.0, 1.0]
        v = [0.0, 0.0, 0.0, 0.0, 0.0]
        self.assertEqual(mask.dab_centres(u, v), mask.dab_centres([0.0, 1.0], [0.0, 0.0]))


class Rectangle(unittest.TestCase):
    def test_gain_inside_zero_outside(self):
        op = rect(2, 4, 200, 2000)
        self.assertAlmostEqual(mask.gain_at(3, 600, [op], AUDIO), -12.0)
        self.assertEqual(mask.gain_at(5, 600, [op], AUDIO), 0.0)
        self.assertEqual(mask.gain_at(3, 100, [op], AUDIO), 0.0)
        self.assertEqual(mask.gain_at(3, 3000, [op], AUDIO), 0.0)
        # without a feather the bounds are inclusive
        self.assertAlmostEqual(mask.gain_at(2, 200, [op], AUDIO), -12.0)
        self.assertAlmostEqual(mask.gain_at(4, 2000, [op], AUDIO), -12.0)

    def test_half_the_gain_at_a_feathered_edge(self):
        op = rect(2, 4, 200, 2000, fms=10, fst=0)
        self.assertAlmostEqual(mask.gain_at(2, 600, [op], AUDIO), -6.0, delta=1e-9)
        self.assertAlmostEqual(mask.gain_at(4, 600, [op], AUDIO), -6.0, delta=1e-9)
        self.assertEqual(mask.gain_at(2 - 0.005, 600, [op], AUDIO), 0.0)
        self.assertAlmostEqual(mask.gain_at(2 + 0.005, 600, [op], AUDIO), -12.0, delta=1e-9)
        self.assertAlmostEqual(mask.gain_at(2 - 0.0025, 600, [op], AUDIO), -12 * mask.ramp(0.25), delta=1e-9)
        # the feather is centred on the drawn edge, so the plateau is narrower by F
        self.assertAlmostEqual(mask.gain_at(3, 600, [op], AUDIO), -12.0)

    def test_feather_on_the_frequency_axis_is_in_semitones(self):
        op = rect(2, 4, 200, 2000, fms=0, fst=1)
        self.assertAlmostEqual(mask.gain_at(3, 200, [op], AUDIO), -6.0, delta=1e-9)
        self.assertEqual(mask.gain_at(3, 200 * 2 ** (-1 / 24.0), [op], AUDIO), 0.0)
        self.assertAlmostEqual(mask.gain_at(3, 200 * 2 ** (1 / 24.0), [op], AUDIO), -12.0, delta=1e-9)
        # corner: both feathers multiply
        op = rect(2, 4, 200, 2000, fms=10, fst=1)
        self.assertAlmostEqual(mask.gain_at(2, 200, [op], AUDIO), -12 * 0.25, delta=1e-9)

    def test_open_edges_have_no_ramp_and_extend(self):
        # x covers the whole axis: no ramp at 0 or 10, whatever the feather
        op = rect(0, 10, 200, 2000, fms=200, fst=0)
        self.assertAlmostEqual(mask.gain_at(0, 600, [op], AUDIO), -12.0)
        self.assertAlmostEqual(mask.gain_at(10, 600, [op], AUDIO), -12.0)
        self.assertAlmostEqual(mask.gain_at(0.0001, 600, [op], AUDIO), -12.0)
        # a grid point BEYOND the world (a window's padding) still gets the gain
        self.assertAlmostEqual(mask.gain_at(-3.0, 600, [op], AUDIO), -12.0)
        self.assertAlmostEqual(mask.gain_at(14.0, 600, [op], AUDIO), -12.0)
        # top of the frequency axis is open, bottom is not
        op = rect(2, 4, 2000, 24000, fms=0, fst=12)
        self.assertAlmostEqual(mask.gain_at(3, 24000, [op], AUDIO), -12.0)
        self.assertAlmostEqual(mask.gain_at(3, 30000, [op], AUDIO), -12.0)
        self.assertAlmostEqual(mask.gain_at(3, 2000, [op], AUDIO), -6.0, delta=1e-9)
        # within 1e-9 of the span counts as on the bound
        op = rect(1e-10, 10 - 1e-10, 200, 2000, fms=100)
        self.assertAlmostEqual(mask.gain_at(0.0, 600, [op], AUDIO), -12.0)
        op = rect(1e-6, 4, 200, 2000, fms=100)
        self.assertAlmostEqual(mask.gain_at(0.0, 600, [op], AUDIO), -6.0, delta=1e-3)  # not open: it ramps

    def test_overlapping_rects_add(self):
        a = rect(2, 6, 200, 2000, gain=-6, oid=1)
        b = rect(4, 8, 200, 2000, gain=-6, oid=2)
        self.assertAlmostEqual(mask.gain_at(5, 600, [a, b], AUDIO), -12.0)
        self.assertAlmostEqual(mask.gain_at(3, 600, [a, b], AUDIO), -6.0)
        self.assertAlmostEqual(mask.gain_at(7, 600, [a, b], AUDIO), -6.0)

    def test_minus_60_is_minus_60_and_boosts_are_not_capped(self):
        self.assertAlmostEqual(mask.gain_at(3, 600, [rect(2, 4, 200, 2000, gain=-60)], AUDIO), -60.0)
        self.assertAlmostEqual(mask.gain_at(3, 600, [rect(2, 4, 200, 2000, gain=12)], AUDIO), 12.0)
        many = [rect(2, 4, 200, 2000, gain=12, oid=i) for i in range(5)]
        self.assertAlmostEqual(mask.gain_at(3, 600, many, AUDIO), 60.0)

    def test_sorted_and_clamped(self):
        op = rect(4, 2, 2000, 200)
        self.assertAlmostEqual(mask.gain_at(3, 600, [op], AUDIO), -12.0)
        op = rect(-5, 4, 200, 99999)
        p = mask.rect_from_op(op, AUDIO)
        self.assertTrue(p["open_lo_x"])
        self.assertTrue(p["open_hi_y"])
        self.assertFalse(p["open_hi_x"])

    def test_linear_floor_at_minus_300_db(self):
        g = np.array([-1000.0, -300.0, -6.0, 0.0, 6.0])
        lin = mask.to_linear(g)
        self.assertAlmostEqual(float(lin[0]), 10 ** (-300 / 20.0), delta=1e-30)
        self.assertEqual(float(lin[0]), float(lin[1]))
        self.assertAlmostEqual(float(lin[2]), 10 ** (-6 / 20.0))
        self.assertAlmostEqual(float(lin[4]), 10 ** (6 / 20.0))


class Grid(unittest.TestCase):
    def _ops(self):
        return [
            rect(2, 6, 300, 3000, gain=-9, fms=40, fst=2, oid=1),
            rect(0, 4, 1000, 24000, gain=4, fms=10, fst=1, oid=2),
            eraser([(1, 500), (5, 700), (8, 4000)], size_x=0.6, size_y=0.8, amount=-4, hardness=30, oid=3),
            eraser([(2, 2000), (9, 2100)], size_x=0.3, size_y=0.5, amount=-2, hardness=100, oid=4),
            eraser([(3, 100), (3.4, 9000)], size_x=0.5, size_y=1.5, amount=-6, hardness=0, oid=5),
            {"id": 6, "tool": "something-else", "kind": "point", "x": 1, "y": 1, "params": {}},
        ]

    def test_grid_equals_pointwise(self):
        ops = self._ops()
        xw = np.linspace(-0.5, 10.5, 53)
        f = np.exp(np.linspace(math.log(15), math.log(26000), 47))
        yw = np.log2(f)
        g = mask.gain_grid(ops, xw, yw, AUDIO)
        self.assertEqual(g.shape, (53, 47))
        worst = 0.0
        for i, x in enumerate(xw):
            for j, y in enumerate(yw):
                ref = mask.gain_at_warped(x, y, ops, AUDIO)
                worst = max(worst, abs(g[i, j] - ref))
        self.assertLessEqual(worst, 1e-9)
        self.assertGreater(float(np.max(np.abs(g))), 3.0)  # the test is not vacuous

    def test_grid_with_interpreted_ops_matches_compiled(self):
        ops = self._ops()
        xw = np.linspace(0, 10, 40)
        yw = np.log2(np.geomspace(20, 24000, 30))
        cache = {}
        a = mask.gain_grid(ops, xw, yw, AUDIO)
        b = mask.gain_grid(None, xw, yw, AUDIO, compiled=mask.compile_ops(ops, AUDIO, cache))
        self.assertTrue(np.array_equal(a, b))
        self.assertEqual(sorted(cache.keys()), [1, 2, 3, 4, 5, 6])
        c = mask.gain_grid(None, xw, yw, AUDIO, compiled=mask.compile_ops(ops, AUDIO, cache))
        self.assertTrue(np.array_equal(a, c))

    def test_open_edges_extend_to_the_grid_ends_in_the_grid_path(self):
        op = rect(0, 10, 200, 2000, fms=200)
        xw = np.array([-2.0, 0.0, 5.0, 10.0, 12.0])
        yw = np.log2(np.array([100.0, 600.0, 5000.0]))
        g = mask.gain_grid([op], xw, yw, AUDIO)
        self.assertTrue(np.allclose(g[:, 1], -12.0))
        self.assertTrue(np.allclose(g[:, 0], 0.0))

    def test_no_feather_inclusive_bounds_in_the_grid(self):
        op = rect(2, 4, 200, 2000)
        xw = np.array([1.999, 2.0, 3.0, 4.0, 4.001])
        yw = np.log2(np.array([199.0, 200.0, 600.0, 2000.0, 2001.0]))
        g = mask.gain_grid([op], xw, yw, AUDIO)
        for i, x in enumerate(xw):
            for j, y in enumerate(yw):
                self.assertAlmostEqual(g[i, j], mask.gain_at_warped(x, y, [op], AUDIO), delta=1e-12)

    def test_empty_ops_and_empty_grid(self):
        g = mask.gain_grid([], [0.0, 1.0], [1.0, 2.0, 3.0], AUDIO)
        self.assertEqual(g.shape, (2, 3))
        self.assertEqual(float(np.abs(g).max()), 0.0)
        self.assertEqual(mask.gain_grid([rect(2, 4, 200, 2000)], [], [1.0], AUDIO).shape, (0, 1))

    def test_stft_block_dc_copies_bin_one(self):
        sr, n, k = 48000, 1024, 4
        ops = [rect(0, 10, 20, 24000, gain=-6, oid=1),
               eraser([(0.0, 40.0), (3.0, 40.0)], size_x=0.5, size_y=2.0, amount=-9, hardness=50, oid=2)]
        fn = mask.stft_gain_block_fn(ops, AUDIO, sr, n, k)
        m = fn(0, 40)
        self.assertEqual(m.shape, (40, n // 2 + 1))
        self.assertTrue(np.array_equal(m[:, 0], m[:, 1]))
        h = 256
        for (j, b) in ((5, 1), (20, 10), (39, 300), (11, 512)):
            xw = j * h / float(sr)
            yw = math.log2(b * sr / float(n))
            ref = 10 ** (mask.gain_at_warped(xw, yw, ops, AUDIO) / 20.0)
            self.assertAlmostEqual(float(m[j, b]), ref, delta=1e-12)
        # a block is the same wherever it is cut
        part = fn(10, 15)
        self.assertTrue(np.allclose(part, m[10:15], atol=1e-14))

    def test_stft_block_clamps_at_minus_300_db(self):
        ops = [rect(0, 10, 20, 24000, gain=-1000, oid=1)]
        m = mask.stft_gain_block_fn(ops, AUDIO, 48000, 1024, 4)(0, 3)
        self.assertTrue(np.all(m > 0))
        self.assertAlmostEqual(float(m.min()), 10 ** (-15.0), delta=1e-27)


class OpInterpretation(unittest.TestCase):
    def test_rect_reads_params(self):
        p = mask.rect_from_op(rect(1, 3, 100, 1000, gain=-24, fms=50, fst=6), AUDIO)
        self.assertEqual(p["gain_db"], -24.0)
        self.assertAlmostEqual(p["fx"], 0.05)
        self.assertAlmostEqual(p["fy"], 0.5)
        self.assertAlmostEqual(p["lo_y"], math.log2(100))
        self.assertAlmostEqual(p["hi_y"], math.log2(1000))
        self.assertAlmostEqual(p["lo_x"], 1.0)

    def test_eraser_reads_params_and_sizes(self):
        op = eraser([(1, 1000), (3, 1000)], size_x=0.5, size_y=2.0, amount=-8, hardness=30)
        p = mask.eraser_from_op(op, AUDIO)
        self.assertAlmostEqual(p["h"], 0.3)
        self.assertAlmostEqual(p["a"], -8 * 0.5 / 1.3)
        self.assertEqual((p["size_x"], p["size_y"]), (0.5, 2.0))
        # normalisation: u = x / size_x, v = log2(y) / size_y ; stroke of 2 s = 4 diameters -> 16 dabs
        self.assertEqual(len(p["dabs"]), 16)
        self.assertAlmostEqual(p["dabs"][0][0], (1 + 0.125 * 0.5) / 0.5)
        self.assertAlmostEqual(p["dabs"][0][1], math.log2(1000) / 2.0)

    def test_params_changes_do_not_leak_between_ops(self):
        a = eraser([(10, 50), (90, 50)], amount=-3, oid=1)
        b = eraser([(10, 50), (90, 50)], amount=-6, oid=2)
        self.assertAlmostEqual(mask.gain_at(50, 50, [a], LIN), -3.0, delta=0.06)
        self.assertAlmostEqual(mask.gain_at(50, 50, [b], LIN), -6.0, delta=0.12)
        self.assertAlmostEqual(mask.gain_at(50, 50, [a, b], LIN), -9.0, delta=0.18)
        self.assertAlmostEqual(mask.gain_at(50, 50, [a, b], LIN),
                               mask.gain_at(50, 50, [a], LIN) + mask.gain_at(50, 50, [b], LIN), delta=1e-12)

    def test_missing_or_non_finite_params_raise(self):
        bad = rect(1, 3, 100, 1000)
        del bad["params"]["feather_ms"]
        with self.assertRaises(ValueError):
            mask.gain_at(2, 500, [bad], AUDIO)
        bad = eraser([(1, 500), (3, 500)])
        bad["params"]["amount"] = float("nan")
        with self.assertRaises(ValueError):
            mask.gain_at(2, 500, [bad], AUDIO)
        bad = eraser([(1, 500), (3, 500)])
        bad["size_x"] = float("inf")
        with self.assertRaises(ValueError):
            mask.eraser_from_op(bad, AUDIO)

    def test_unknown_tools_and_degenerate_sizes_contribute_nothing(self):
        other = {"id": 1, "tool": "lasso", "kind": "point", "x": 1, "y": 2, "params": {}}
        self.assertEqual(mask.gain_at(1, 2, [other], AUDIO), 0.0)
        self.assertEqual(mask.compile_ops([other], AUDIO), [])
        flat = eraser([(1, 500), (3, 500)], size_x=0.0)
        self.assertIsNone(mask.eraser_from_op(flat, AUDIO))
        self.assertEqual(mask.gain_at(2, 500, [flat], AUDIO), 0.0)

    def test_active_ops_is_the_cursor_prefix(self):
        hist = {"rev": 3, "cursor": 2, "count": 3, "ops": [{"id": 1}, {"id": 2}, {"id": 3}]}
        self.assertEqual([o["id"] for o in mask.active_ops(hist)], [1, 2])
        hist["cursor"] = 0
        self.assertEqual(mask.active_ops(hist), [])

    def test_hardness_is_clamped_to_0_100(self):
        self.assertEqual(mask.eraser_from_op(eraser([(1, 500), (3, 500)], hardness=250), AUDIO)["h"], 1.0)
        self.assertEqual(mask.eraser_from_op(eraser([(1, 500), (3, 500)], hardness=-5), AUDIO)["h"], 0.0)

    def test_is_open(self):
        self.assertTrue(mask.is_open(0.0, 0.0, 10.0))
        self.assertTrue(mask.is_open(1e-10, 0.0, 10.0))
        self.assertFalse(mask.is_open(1e-7, 0.0, 10.0))


if __name__ == "__main__":
    unittest.main()

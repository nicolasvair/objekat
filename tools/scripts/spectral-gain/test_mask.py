import math
import unittest

import numpy as np

import mask

LIN = {"x": {"min": 0.0, "max": 100.0, "mapping": "lin"}, "y": {"min": 0.0, "max": 100.0, "mapping": "lin"}}
AUDIO = {"x": {"min": 0.0, "max": 10.0, "mapping": "lin"}, "y": {"min": 20.0, "max": 24000.0, "mapping": "log"}}
RNG = np.random.RandomState(3)


def brush(points, size_x=1.0, size_y=1.0, quantity=25.0, hardness=50.0, polarity="add", oid=1):
    return {"id": oid, "kind": "stroke", "tool": "brush", "polarity": polarity,
            "points": [list(p) for p in points], "size_pt": 32, "size_x": size_x, "size_y": size_y,
            "params": {"quantity": quantity, "hardness": hardness}}


def rect(x0, x1, y0, y1, polarity="add", oid=1):
    return {"id": oid, "kind": "rect", "tool": "rect", "polarity": polarity,
            "x0": x0, "x1": x1, "y0": y0, "y1": y1, "params": {}}


def P(gain=-12.0, fms=0.0, fst=0.0):
    """The params of a step (or the live values): the three that can be tuned while a selection is pending."""
    return {"gain": gain, "feather_ms": fms, "feather_st": fst}


def step(ops, gain=-12.0, fms=0.0, fst=0.0):
    return (list(ops), P(gain, fms, fst))


def S_line(ops, xs, y=50.0, world=LIN, fms=0.0, fst=0.0):
    return np.array([mask.selection_at(x, y, ops, world, fms, fst) for x in xs])


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

    def test_per_dab_weight(self):
        self.assertAlmostEqual(mask.per_dab_weight(0.0), 0.5)
        self.assertAlmostEqual(mask.per_dab_weight(0.5), mask.spacing_for(0.5) / 0.75)
        self.assertAlmostEqual(mask.per_dab_weight(1.0), 1.0 / 64.0)
        self.assertAlmostEqual(mask.per_dab_weight(0.3), 0.5 / 1.3)

    def test_ramp(self):
        self.assertEqual(mask.ramp(-1), 0.0)
        self.assertEqual(mask.ramp(0), 0.0)
        self.assertEqual(mask.ramp(1), 1.0)
        self.assertEqual(mask.ramp(2), 1.0)
        self.assertAlmostEqual(mask.ramp(0.5), 0.5)
        self.assertAlmostEqual(mask.ramp(0.25), 0.5 - 0.5 * math.cos(math.pi / 4))


def ripple_percent(hardness, quantity=25.0):
    """Worst deviation from the quantity, in % of it, of S on the centre line of a long straight stroke,
    over one dab period of phases (offset so that no sample sits on a profile discontinuity); and the mean."""
    s = mask.spacing_for(hardness / 100.0)
    op = brush([(10, 50), (90, 50)], quantity=quantity, hardness=hardness)
    xs = np.arange(30.0, 30.0 + s, s / 97.0) + 0.00123
    q = quantity / 100.0
    g = S_line([op], xs)
    return 100.0 * float(np.max(np.abs(g - q))) / q, float(np.mean(g)) / q


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
            p = mask.brush_from_op(brush([(0, 50), (4, 50)], hardness=float(hp)), LIN)
            self.assertEqual(len(p["dabs"]), n, hp)
            self.assertAlmostEqual(p["spacing"], mask.spacing_for(hp / 100.0))

    def test_per_dab_weight_follows_the_spacing(self):
        for h in (0.0, 0.3, 0.5, 1.0):
            self.assertAlmostEqual(mask.per_dab_weight(h), mask.spacing_for(h) / (0.5 * (1 + h)))
        self.assertAlmostEqual(mask.per_dab_weight(1.0), 1.0 / 64.0 / 1.0)


class Calibration(unittest.TestCase):
    PHASES = np.arange(30.0, 30.25, 0.0125)  # one soft-brush lattice period, on the centre line

    def test_one_crossing_deposits_the_quantity_whatever_the_hardness(self):
        worst = {}
        for hp in list(range(0, 101, 10)) + [5, 15, 25, 35, 45, 55, 65, 75, 85, 95, 98, 99]:
            worst[hp], mean = ripple_percent(float(hp))
            self.assertLessEqual(worst[hp], 2.0, hp)
            self.assertAlmostEqual(mean, 1.0, delta=4e-4, msg=hp)
        print("brush ripple %% by hardness (q 25 %%): " + ", ".join(
            "%d: %.2f" % (k, v) for k, v in sorted(worst.items()) if k % 10 == 0))

    def test_ripple_on_a_fine_hardness_sweep(self):
        for hp in range(0, 101, 2):
            self.assertLessEqual(ripple_percent(float(hp))[0], 2.0, hp)

    def test_exact_where_the_lattice_is_commensurate(self):
        # soft brushes keep the historical spacing and the historical exactness
        for hp in (0.0, 25.0):
            self.assertLessEqual(ripple_percent(hp)[0], 1e-7, hp)

    def test_quantity_scales_linearly(self):
        for quantity in (1.0, 25.0, 60.0, 100.0):
            for hp in (0.0, 50.0, 90.0, 100.0):
                self.assertLessEqual(ripple_percent(hp, quantity)[0], 2.0, (quantity, hp))

    def test_centre_line_value_is_q_at_25_percent(self):
        op = brush([(10, 50), (90, 50)], hardness=30.0)
        g = S_line([op], self.PHASES)
        self.assertLessEqual(float(np.max(np.abs(g - 0.25))) / 0.25, 0.02)

    def test_hard_brush_on_a_grid_aligned_stroke_has_no_cell_jumps(self):
        # h = 1 is a box: a cell lying exactly on its edge used to flip by a whole dab. With 64 dabs
        # per diameter the worst a single flip can do is 1/64 of the quantity.
        op = brush([(10, 50), (90, 50)], hardness=100.0)
        xs = np.arange(30.0, 31.0, 1.0 / 64.0)  # lattice-aligned samples
        g = S_line([op], xs)
        self.assertLessEqual(float(np.max(np.abs(g - 0.25))) / 0.25, 1.0 / 64.0 + 1e-9)

    def test_oblique_stroke_and_anisotropic_sizes(self):
        op = brush([(10, 20), (80, 80)], size_x=2.0, size_y=3.0, hardness=50.0)
        t = np.arange(0.4, 0.6, 0.001)
        g = np.array([mask.selection_at(10 + 70 * s, 20 + 60 * s, [op], LIN) for s in t])
        self.assertLessEqual(float(np.max(np.abs(g - 0.25))) / 0.25, 0.02)

    def test_calibration_on_a_log_axis_in_octaves(self):
        # size_y = 1 octave, a horizontal stroke at 3 kHz: 0.25 on the line, 0 one half-octave away
        op = brush([(-1, 3000.0), (11, 3000.0)], size_x=0.5, size_y=1.0, hardness=50.0)
        world = {"x": {"min": -5.0, "max": 15.0, "mapping": "lin"}, "y": AUDIO["y"]}
        for x in (3.0, 5.0, 5.013, 7.77):
            self.assertAlmostEqual(mask.selection_at(x, 3000.0, [op], world), 0.25, delta=0.005)
        self.assertAlmostEqual(mask.selection_at(5.0, 3000.0 * 2 ** 0.5, [op], world), 0.0, delta=1e-12)
        self.assertAlmostEqual(mask.selection_at(5.0, 3000.0 / 2 ** 0.5, [op], world), 0.0, delta=1e-12)
        self.assertGreater(mask.selection_at(5.0, 3000.0 * 2 ** 0.25, [op], world), 0.0)


class Accumulation(unittest.TestCase):
    XS = np.arange(40.0, 60.0, 0.173)

    def _crossings(self, k, hp, quantity=25.0):
        pts = [(10, 50), (90, 50)]
        for i in range(2, k + 1):
            pts.append((10, 50) if i % 2 == 0 else (90, 50))
        return brush(pts, hardness=hp, quantity=quantity)

    def test_out_and_back_is_double_and_three_passes_triple(self):
        for hp in (0.0, 50.0, 100.0):
            for k in (1, 2, 3):
                s = S_line([self._crossings(k, hp)], self.XS)
                self.assertLessEqual(float(np.max(np.abs(s - 0.25 * k))) / (0.25 * k), 0.02, (hp, k))

    def test_out_and_back_is_half_at_25_percent(self):
        s = S_line([self._crossings(2, 50.0)], self.XS)
        self.assertLessEqual(float(np.max(np.abs(s - 0.5))), 0.01)

    def test_five_crossings_are_capped_at_one(self):
        for hp in (0.0, 50.0, 100.0):
            s = S_line([self._crossings(5, hp)], self.XS)
            self.assertEqual(float(s.max()), 1.0, hp)
            self.assertEqual(float(s.min()), 1.0, hp)  # 1.25 +- 2 % everywhere on the centre line
            for k in (7, 12):  # and stays there
                self.assertEqual(float(S_line([self._crossings(k, hp)], self.XS).max()), 1.0)

    def test_the_cap_is_per_op_not_global(self):
        a = brush([(10, 50), (90, 50)], quantity=100.0, oid=1)
        b = brush([(20, 50), (80, 50)], quantity=60.0, oid=2)
        # a alone reaches 1 (within the ripple); b adds on top: capped at exactly 1
        self.assertEqual(float(mask.selection_at(50, 50, [a, b], LIN)), 1.0)

    def test_two_separate_strokes_add_up(self):
        a = brush([(10, 50), (90, 50)], oid=1)
        b = brush([(20, 50), (80, 50)], oid=2, quantity=50.0)
        for x in (35.0, 50.0, 61.3):
            self.assertAlmostEqual(mask.selection_at(x, 50, [a, b], LIN), 0.75, delta=0.015)
            self.assertAlmostEqual(mask.selection_at(x, 50, [a, b], LIN),
                                   mask.selection_at(x, 50, [a], LIN) + mask.selection_at(x, 50, [b], LIN), delta=1e-12)

    def test_crossing_strokes_add_at_the_crossing(self):
        a = brush([(10, 50), (90, 50)], oid=1)
        b = brush([(50, 10), (50, 90)], oid=2)
        self.assertAlmostEqual(mask.selection_at(50, 50, [a, b], LIN), 0.5, delta=0.01)


class Polarity(unittest.TestCase):
    A = brush([(10, 50), (90, 50)], quantity=50.0, oid=1)

    def test_subtract_alone_floors_at_zero(self):
        sub = brush([(10, 50), (90, 50)], quantity=50.0, polarity="subtract", oid=1)
        for x in (20.0, 50.0, 80.0):
            self.assertEqual(mask.selection_at(x, 50, [sub], LIN), 0.0)
        r = rect(0, 100, 0, 100, polarity="subtract")
        self.assertEqual(mask.selection_at(50, 50, [r], LIN), 0.0)

    def test_add_then_subtract_more_floors_at_zero(self):
        sub = brush([(10, 50), (90, 50)], quantity=100.0, polarity="subtract", oid=2)
        self.assertEqual(mask.selection_at(50, 50, [self.A, sub], LIN), 0.0)

    def test_draw_then_erase_is_not_erase_then_draw(self):
        sub = brush([(10, 50), (90, 50)], quantity=25.0, polarity="subtract", oid=2)
        draw_erase = mask.selection_at(50, 50, [self.A, sub], LIN)      # 0.5 - 0.25
        erase_draw = mask.selection_at(50, 50, [sub, self.A], LIN)      # max(0, -0.25) then + 0.5
        self.assertAlmostEqual(draw_erase, 0.25, delta=0.01)
        self.assertAlmostEqual(erase_draw, 0.5, delta=0.01)
        self.assertGreater(erase_draw - draw_erase, 0.2)

    def test_partial_erase_keeps_the_remainder(self):
        sub = brush([(10, 50), (90, 50)], quantity=25.0, polarity="subtract", oid=2)
        s = S_line([self.A, sub], np.arange(40.0, 60.0, 0.173))
        self.assertLessEqual(float(np.max(np.abs(s - 0.25))), 0.01)

    def test_erase_a_selection_it_does_not_reach_changes_nothing(self):
        far = brush([(10, 10), (90, 10)], quantity=100.0, polarity="subtract", oid=2)
        self.assertEqual(mask.selection_at(50, 50, [self.A, far], LIN), mask.selection_at(50, 50, [self.A], LIN))

    def test_missing_polarity_means_add_and_unknown_raises(self):
        a = brush([(10, 50), (90, 50)])
        del a["polarity"]
        self.assertAlmostEqual(mask.selection_at(50, 50, [a], LIN), 0.25, delta=0.01)
        a["polarity"] = "toggle"
        with self.assertRaises(ValueError):
            mask.selection_at(50, 50, [a], LIN)
        r = rect(1, 3, 100, 1000)
        r["polarity"] = 3
        with self.assertRaises(ValueError):
            mask.rect_from_op(r, AUDIO)


class Stillness(unittest.TestCase):
    def test_still_hand_deposits_nothing(self):
        self.assertEqual(mask.dab_centres([5.0] * 10, [5.0] * 10), [])
        self.assertEqual(mask.dab_centres([1.0], [2.0]), [])
        self.assertEqual(mask.dab_centres([], []), [])
        op = brush([(50, 50)] * 5, quantity=100.0)
        self.assertEqual(mask.selection_at(50, 50, [op], LIN), 0.0)
        # the grid path, too: nothing, and no crash on an empty list of dabs
        g = mask.selection_grid([op], np.arange(0.0, 100.0, 5.0), np.arange(0.0, 100.0, 5.0), LIN)
        self.assertEqual(float(g.max()), 0.0)

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
    def test_one_inside_zero_outside(self):
        op = rect(2, 4, 200, 2000)
        self.assertEqual(mask.selection_at(3, 600, [op], AUDIO), 1.0)
        self.assertEqual(mask.selection_at(5, 600, [op], AUDIO), 0.0)
        self.assertEqual(mask.selection_at(3, 100, [op], AUDIO), 0.0)
        self.assertEqual(mask.selection_at(3, 3000, [op], AUDIO), 0.0)
        # without a feather the bounds are inclusive
        self.assertEqual(mask.selection_at(2, 200, [op], AUDIO), 1.0)
        self.assertEqual(mask.selection_at(4, 2000, [op], AUDIO), 1.0)

    def test_half_at_a_feathered_edge(self):
        op = rect(2, 4, 200, 2000)
        s = lambda x, y, fms, fst: mask.selection_at(x, y, [op], AUDIO, fms, fst)  # noqa: E731
        self.assertAlmostEqual(s(2, 600, 10, 0), 0.5, delta=1e-9)
        self.assertAlmostEqual(s(4, 600, 10, 0), 0.5, delta=1e-9)
        self.assertEqual(s(2 - 0.005, 600, 10, 0), 0.0)
        self.assertAlmostEqual(s(2 + 0.005, 600, 10, 0), 1.0, delta=1e-9)
        self.assertAlmostEqual(s(2 - 0.0025, 600, 10, 0), mask.ramp(0.25), delta=1e-9)
        # the feather is centred on the drawn edge, so the plateau is narrower by F
        self.assertAlmostEqual(s(3, 600, 10, 0), 1.0)

    def test_feather_on_the_frequency_axis_is_in_semitones(self):
        op = rect(2, 4, 200, 2000)
        s = lambda x, y, fms, fst: mask.selection_at(x, y, [op], AUDIO, fms, fst)  # noqa: E731
        self.assertAlmostEqual(s(3, 200, 0, 1), 0.5, delta=1e-9)
        self.assertEqual(s(3, 200 * 2 ** (-1 / 24.0), 0, 1), 0.0)
        self.assertAlmostEqual(s(3, 200 * 2 ** (1 / 24.0), 0, 1), 1.0, delta=1e-9)
        # corner: both feathers multiply
        self.assertAlmostEqual(s(2, 200, 10, 1), 0.25, delta=1e-9)

    def test_open_edges_have_no_ramp_and_extend(self):
        # x covers the whole axis: no ramp at 0 or 10, whatever the feather
        op = rect(0, 10, 200, 2000)
        s = lambda x, y, op, fms, fst: mask.selection_at(x, y, [op], AUDIO, fms, fst)  # noqa: E731
        self.assertEqual(s(0, 600, op, 200, 0), 1.0)
        self.assertEqual(s(10, 600, op, 200, 0), 1.0)
        self.assertEqual(s(0.0001, 600, op, 200, 0), 1.0)
        # a grid point BEYOND the world (a window's padding) still gets the selection
        self.assertEqual(s(-3.0, 600, op, 200, 0), 1.0)
        self.assertEqual(s(14.0, 600, op, 200, 0), 1.0)
        # top of the frequency axis is open, bottom is not
        op = rect(2, 4, 2000, 24000)
        self.assertEqual(s(3, 24000, op, 0, 12), 1.0)
        self.assertEqual(s(3, 30000, op, 0, 12), 1.0)
        self.assertAlmostEqual(s(3, 2000, op, 0, 12), 0.5, delta=1e-9)
        # within 1e-9 of the span counts as on the bound
        op = rect(1e-10, 10 - 1e-10, 200, 2000)
        self.assertEqual(s(0.0, 600, op, 100, 0), 1.0)
        op = rect(1e-6, 4, 200, 2000)
        self.assertAlmostEqual(s(0.0, 600, op, 100, 0), 0.5, delta=1e-3)  # not open: it ramps

    def test_overlapping_rects_do_not_add_in_s(self):
        a = rect(2, 6, 200, 2000, oid=1)
        b = rect(4, 8, 200, 2000, oid=2)
        for x in (3.0, 5.0, 7.0):
            self.assertEqual(mask.selection_at(x, 600, [a, b], AUDIO), 1.0)

    def test_rect_add_takes_the_max_with_a_brush_selection(self):
        a = brush([(10, 50), (90, 50)], quantity=50.0, oid=1)
        r = rect(30, 60, 0, 100, oid=2)
        self.assertEqual(mask.selection_at(45, 50, [a, r], LIN), 1.0)           # the rect wins inside
        self.assertAlmostEqual(mask.selection_at(75, 50, [a, r], LIN), 0.5, delta=0.01)  # the brush stays outside

    def test_rect_subtract_is_min_with_one_minus_w(self):
        a = rect(0, 100, 0, 100, oid=1)
        inner = rect(30, 60, 20, 80, polarity="subtract", oid=2)
        self.assertEqual(mask.selection_at(45, 50, [a, inner], LIN), 0.0)
        self.assertEqual(mask.selection_at(10, 50, [a, inner], LIN), 1.0)
        # feathered (5000 ms = 5 units on this axis): half cleared at the drawn edge
        self.assertAlmostEqual(mask.selection_at(30.0, 50, [a, inner], LIN, 5000.0, 0.0), 0.5, delta=1e-9)
        # over a half-intensity brush selection, the rect clears what it covers and nothing else
        half = brush([(10, 50), (90, 50)], quantity=50.0, oid=1)
        clear = rect(30, 60, 0, 100, polarity="subtract", oid=2)
        self.assertEqual(mask.selection_at(45, 50, [half, clear], LIN), 0.0)
        self.assertAlmostEqual(mask.selection_at(75, 50, [half, clear], LIN), 0.5, delta=0.01)

    def test_sorted_and_clamped(self):
        op = rect(4, 2, 2000, 200)
        self.assertEqual(mask.selection_at(3, 600, [op], AUDIO), 1.0)
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


class ProRata(unittest.TestCase):
    """The gain applies pro rata to the selection: G = gain * S, then summed over steps."""

    def test_instant_rect_is_gain_times_the_weight(self):
        op = rect(2, 4, 200, 2000)
        self.assertAlmostEqual(mask.gain_at(3, 600, [step([op], -12)], AUDIO), -12.0)
        self.assertEqual(mask.gain_at(5, 600, [step([op], -12)], AUDIO), 0.0)
        # at a feathered edge W = 0.5: half the gain, as before the selection model existed
        self.assertAlmostEqual(mask.gain_at(2, 600, [step([op], -12, fms=10)], AUDIO), -6.0, delta=1e-9)

    def test_minus_12_on_half_a_selection_is_minus_6_and_on_a_full_one_minus_12(self):
        half = brush([(10, 50), (90, 50)], quantity=50.0, hardness=0.0)   # centre line: exactly 0.5
        full = rect(0, 100, 0, 100)
        self.assertAlmostEqual(mask.gain_at(50, 50, [step([half], -12)], LIN), -6.00, delta=1e-7)
        self.assertAlmostEqual(mask.gain_at(50, 50, [step([full], -12)], LIN), -12.00, delta=1e-9)
        self.assertAlmostEqual(mask.gain_at(50, 50, [step([half], 6)], LIN), 3.00, delta=1e-7)  # a boost, pro rata too

    def test_brush_pass_default_is_minus_3_at_gain_minus_12_quantity_25(self):
        op = brush([(10, 50), (90, 50)], quantity=25.0, hardness=0.0)
        self.assertAlmostEqual(mask.gain_at(50, 50, [step([op], -12)], LIN), -3.0, delta=1e-7)
        out_back = brush([(10, 50), (90, 50), (10, 50)], quantity=25.0, hardness=0.0)
        self.assertAlmostEqual(mask.gain_at(50, 50, [step([out_back], -12)], LIN), -6.0, delta=1e-7)

    def test_one_stroke_is_capped_at_the_gain_and_successive_strokes_add(self):
        many = brush([(10, 50), (90, 50)] * 6, quantity=25.0, hardness=0.0)  # 11 crossings
        self.assertAlmostEqual(mask.gain_at(50, 50, [step([many], -12)], LIN), -12.0, delta=1e-9)
        one = brush([(10, 50), (90, 50)], quantity=25.0, hardness=0.0)
        steps = [step([one], -12)] * 3
        self.assertAlmostEqual(mask.gain_at(50, 50, steps, LIN), -9.0, delta=1e-7)

    def test_two_steps_add_in_db(self):
        a = rect(2, 6, 200, 2000, oid=1)
        b = rect(4, 8, 200, 2000, oid=2)
        steps = [step([a], -6), step([b], -6)]
        self.assertAlmostEqual(mask.gain_at(5, 600, steps, AUDIO), -12.0)
        self.assertAlmostEqual(mask.gain_at(3, 600, steps, AUDIO), -6.0)
        self.assertAlmostEqual(mask.gain_at(7, 600, steps, AUDIO), -6.0)

    def test_minus_60_is_minus_60_and_boosts_are_not_capped(self):
        a = rect(2, 4, 200, 2000)
        self.assertAlmostEqual(mask.gain_at(3, 600, [step([a], -60)], AUDIO), -60.0)
        self.assertAlmostEqual(mask.gain_at(3, 600, [step([a], 12)], AUDIO), 12.0)
        self.assertAlmostEqual(mask.gain_at(3, 600, [step([a], 12)] * 5, AUDIO), 60.0)

    def test_a_step_uses_its_own_params_and_the_draft_the_live_ones(self):
        r = rect(2, 6, 200, 2000, oid=1)
        d = rect(4, 8, 200, 2000, oid=2)
        steps = [step([r], -6, fms=0)]
        for live_gain in (-3.0, -12.0, -30.0):
            live = P(live_gain)
            # in the step alone region: its own -6, whatever the live gain
            self.assertAlmostEqual(mask.gain_at(3, 600, steps, AUDIO, [d], live), -6.0)
            # in the draft alone region: the live gain
            self.assertAlmostEqual(mask.gain_at(7, 600, steps, AUDIO, [d], live), live_gain)
            # overlap: both
            self.assertAlmostEqual(mask.gain_at(5, 600, steps, AUDIO, [d], live), -6.0 + live_gain)
        # a step keeps ITS feather, the draft takes the live one
        steps = [step([r], -6, fms=1000)]
        self.assertAlmostEqual(mask.gain_at(2, 600, steps, AUDIO, [d], P(-12, fms=0)), -3.0, delta=1e-9)
        self.assertAlmostEqual(mask.gain_at(4, 600, steps, AUDIO, [d], P(-12, fms=1000)), -6.0 - 6.0, delta=1e-9)
        # no draft: the live values are not even read
        self.assertAlmostEqual(mask.gain_at(3, 600, steps, AUDIO, [], None), -6.0)
        self.assertAlmostEqual(mask.gain_at(3, 600, steps, AUDIO, None, None), -6.0)

    def test_missing_step_params_raise(self):
        r = rect(2, 6, 200, 2000)
        with self.assertRaises(ValueError):
            mask.gain_at(3, 600, [([r], {"gain": -6.0})], AUDIO)
        with self.assertRaises(ValueError):
            mask.gain_at(3, 600, [([r], P(-6))], AUDIO, [r], None)
        with self.assertRaises(ValueError):
            mask.gain_at(3, 600, [([r], {"gain": float("nan"), "feather_ms": 0, "feather_st": 0})], AUDIO)


class SplitHistory(unittest.TestCase):
    @staticmethod
    def _step(i, ops, params=None):
        return {"id": i, "kind": "step", "active_since": i, "params": params or P(-6), "ops": ops}

    @staticmethod
    def _draft(i, op):
        return {"id": i, "kind": "draft", "active_since": i, "ops": [op]}

    def test_every_shape(self):
        o = [{"id": k} for k in range(1, 8)]
        s1, s2 = self._step(1, [o[0]], P(-6)), self._step(2, [o[1], o[2]], P(-12, 5, 1))
        d1, d2 = self._draft(3, o[3]), self._draft(4, o[4])
        split = lambda entries, cursor: mask.split_history({"entries": entries, "cursor": cursor})  # noqa: E731
        self.assertEqual(split([], 0), ([], []))
        self.assertEqual(split([s1, s2], 2), ([([o[0]], P(-6)), ([o[1], o[2]], P(-12, 5, 1))], []))   # only steps
        self.assertEqual(split([d1, d2], 2), ([], [o[3], o[4]]))                                       # only drafts
        self.assertEqual(split([s1, s2, d1, d2], 4), ([([o[0]], P(-6)), ([o[1], o[2]], P(-12, 5, 1))], [o[3], o[4]]))
        # the cursor inside the tail: only what is active counts
        self.assertEqual(split([s1, s2, d1, d2], 3), ([([o[0]], P(-6)), ([o[1], o[2]], P(-12, 5, 1))], [o[3]]))
        self.assertEqual(split([s1, s2, d1, d2], 2)[1], [])
        self.assertEqual(split([s1, s2, d1, d2], 1), ([([o[0]], P(-6))], []))
        self.assertEqual(split([s1, s2, d1, d2], 0), ([], []))

    def test_it_copies_what_it_returns(self):
        op = {"id": 1}
        entry = self._step(1, [op], P(-6))
        steps, draft = mask.split_history({"entries": [entry], "cursor": 1})
        steps[0][1]["gain"] = 99.0
        steps[0][0].append({"id": 2})
        self.assertEqual(entry["params"]["gain"], -6)
        self.assertEqual(entry["ops"], [op])

    def test_a_draft_below_a_step_or_an_unknown_kind_raises(self):
        with self.assertRaises(ValueError):
            mask.split_history({"entries": [self._draft(1, {"id": 1}), self._step(2, [{"id": 2}])], "cursor": 2})
        with self.assertRaises(ValueError):
            mask.split_history({"entries": [{"id": 1, "kind": "ops", "ops": []}], "cursor": 1})

    def test_entries_absent_means_empty(self):
        self.assertEqual(mask.split_history({"cursor": 0, "rev": 4}), ([], []))


class Grid(unittest.TestCase):
    def _ops(self):
        return [
            rect(2, 6, 300, 3000, oid=1),
            rect(0, 4, 1000, 24000, oid=2),
            brush([(1, 500), (5, 700), (8, 4000)], size_x=0.6, size_y=0.8, quantity=40, hardness=30, oid=3),
            brush([(2, 2000), (9, 2100)], size_x=0.3, size_y=0.5, quantity=20, hardness=100, oid=4),
            brush([(3, 100), (3.4, 9000)], size_x=0.5, size_y=1.5, quantity=80, hardness=0, oid=5),
            {"id": 6, "tool": "something-else", "kind": "point", "x": 1, "y": 1, "params": {}},
            brush([(1, 600), (6, 800)], size_x=0.6, size_y=0.8, quantity=50, hardness=50, polarity="subtract", oid=7),
            rect(3, 5, 500, 6000, polarity="subtract", oid=8),
            rect(1, 9, 150, 400, oid=9),
        ]

    def _axes(self):
        xw = np.linspace(-0.5, 10.5, 53)
        f = np.exp(np.linspace(math.log(15), math.log(26000), 47))
        return xw, np.log2(f)

    def test_selection_grid_equals_pointwise(self):
        ops = self._ops()
        xw, yw = self._axes()
        for fms, fst in ((0.0, 0.0), (40.0, 2.0)):
            s = mask.selection_grid(ops, xw, yw, AUDIO, fms, fst)
            self.assertEqual(s.shape, (53, 47))
            worst = 0.0
            for i, x in enumerate(xw):
                for j, y in enumerate(yw):
                    worst = max(worst, abs(s[i, j] - mask.selection_at_warped(x, y, ops, AUDIO, fms, fst)))
            self.assertLessEqual(worst, 1e-9)
            self.assertGreater(float(s.max()), 0.99)             # the test is not vacuous: saturated somewhere...
            self.assertGreater(float(((s > 0.05) & (s < 0.95)).sum()), 20)  # ...partial elsewhere
            self.assertGreaterEqual(float(s.min()), 0.0)
            self.assertLessEqual(float(s.max()), 1.0)

    def test_gain_grid_equals_pointwise_with_steps_and_a_draft(self):
        ops = self._ops()
        steps = [step(ops[:3], -9, fms=40, fst=2), step(ops[3:6], 4, fms=10, fst=1), step(ops[6:8], -6)]
        draft, live = ops[8:], P(-15, fms=25, fst=0.5)
        xw, yw = self._axes()
        g = mask.gain_grid(steps, xw, yw, AUDIO, draft, live)
        self.assertEqual(g.shape, (53, 47))
        worst = 0.0
        for i, x in enumerate(xw):
            for j, y in enumerate(yw):
                worst = max(worst, abs(g[i, j] - mask.gain_at_warped(x, y, steps, AUDIO, draft, live)))
        self.assertLessEqual(worst, 1e-9)
        self.assertGreater(float(np.max(np.abs(g))), 3.0)
        # without the draft the grid is the steps only
        self.assertTrue(np.array_equal(mask.gain_grid(steps, xw, yw, AUDIO), mask.gain_grid(steps, xw, yw, AUDIO, [], live)))

    def test_grid_with_compiled_ops_matches_interpreted(self):
        ops = self._ops()
        xw = np.linspace(0, 10, 40)
        yw = np.log2(np.geomspace(20, 24000, 30))
        cache = {}
        a = mask.selection_grid(ops, xw, yw, AUDIO, 20.0, 1.0)
        b = mask.selection_grid(None, xw, yw, AUDIO, 20.0, 1.0, compiled=mask.compile_ops(ops, AUDIO, cache))
        self.assertTrue(np.array_equal(a, b))
        self.assertEqual(sorted(cache.keys()), [1, 2, 3, 4, 5, 6, 7, 8, 9])
        c = mask.selection_grid(None, xw, yw, AUDIO, 20.0, 1.0, compiled=mask.compile_ops(ops, AUDIO, cache))
        self.assertTrue(np.array_equal(a, c))
        # the compiled geometry serves every feather: the cache is not keyed by it
        d = mask.selection_grid(None, xw, yw, AUDIO, 80.0, 3.0, compiled=mask.compile_ops(ops, AUDIO, cache))
        self.assertTrue(np.array_equal(d, mask.selection_grid(ops, xw, yw, AUDIO, 80.0, 3.0)))
        self.assertFalse(np.array_equal(a, d))

    def test_cache_shared_by_steps_and_gain_grid(self):
        ops = self._ops()
        xw = np.linspace(0, 10, 40)
        yw = np.log2(np.geomspace(20, 24000, 30))
        cache = {}
        steps = [step(ops[:4], -6, fms=10)]
        a = mask.gain_grid(steps, xw, yw, AUDIO, ops[4:6], P(-8, 5), cache)
        self.assertEqual(sorted(cache.keys()), [1, 2, 3, 4, 5, 6])
        b = mask.gain_grid(steps, xw, yw, AUDIO, ops[4:6], P(-8, 5))
        self.assertTrue(np.array_equal(a, b))

    def test_zero_gain_step_costs_nothing_and_is_zero(self):
        ops = self._ops()
        xw = np.linspace(0, 10, 20)
        yw = np.log2(np.geomspace(20, 24000, 10))
        g = mask.gain_grid([step(ops, 0.0)], xw, yw, AUDIO)
        self.assertEqual(float(np.abs(g).max()), 0.0)

    def test_open_edges_extend_to_the_grid_ends_in_the_grid_path(self):
        op = rect(0, 10, 200, 2000)
        xw = np.array([-2.0, 0.0, 5.0, 10.0, 12.0])
        yw = np.log2(np.array([100.0, 600.0, 5000.0]))
        s = mask.selection_grid([op], xw, yw, AUDIO, 200.0, 0.0)
        self.assertTrue(np.allclose(s[:, 1], 1.0))
        self.assertTrue(np.allclose(s[:, 0], 0.0))

    def test_no_feather_inclusive_bounds_in_the_grid(self):
        op = rect(2, 4, 200, 2000)
        xw = np.array([1.999, 2.0, 3.0, 4.0, 4.001])
        yw = np.log2(np.array([199.0, 200.0, 600.0, 2000.0, 2001.0]))
        s = mask.selection_grid([op], xw, yw, AUDIO)
        for i, x in enumerate(xw):
            for j, y in enumerate(yw):
                self.assertAlmostEqual(s[i, j], mask.selection_at_warped(x, y, [op], AUDIO), delta=1e-12)

    def test_empty_ops_and_empty_grid(self):
        g = mask.gain_grid([], [0.0, 1.0], [1.0, 2.0, 3.0], AUDIO)
        self.assertEqual(g.shape, (2, 3))
        self.assertEqual(float(np.abs(g).max()), 0.0)
        self.assertEqual(mask.selection_grid([rect(2, 4, 200, 2000)], [], [1.0], AUDIO).shape, (0, 1))
        self.assertEqual(mask.gain_grid([step([rect(2, 4, 200, 2000)])], [], [1.0], AUDIO).shape, (0, 1))
        empty_brush = brush([(1, 500), (2, 500)], size_x=0.5, size_y=1.0)
        self.assertEqual(float(mask.selection_grid([empty_brush], [3.0, 4.0], [5.0], AUDIO).max()), 0.0)

    def test_stft_block_dc_copies_bin_one(self):
        sr, n, k = 48000, 1024, 4
        ops1 = [rect(0, 10, 20, 24000, oid=1)]
        ops2 = [brush([(0.0, 40.0), (3.0, 40.0)], size_x=0.5, size_y=2.0, quantity=90, hardness=50, oid=2)]
        draft = [brush([(1.0, 200.0), (4.0, 3000.0)], size_x=0.7, size_y=1.0, quantity=60, hardness=20, oid=3)]
        steps = [step(ops1, -6), step(ops2, -9, fms=30)]
        live = P(-4, fms=15, fst=1)
        fn = mask.stft_gain_block_fn(steps, draft, live, AUDIO, sr, n, k)
        m = fn(0, 40)
        self.assertEqual(m.shape, (40, n // 2 + 1))
        self.assertTrue(np.array_equal(m[:, 0], m[:, 1]))
        h = 256
        for (j, b) in ((5, 1), (20, 10), (39, 300), (11, 512), (14, 40)):
            xw = j * h / float(sr)
            yw = math.log2(b * sr / float(n))
            ref = 10 ** (mask.gain_at_warped(xw, yw, steps, AUDIO, draft, live) / 20.0)
            self.assertAlmostEqual(float(m[j, b]), ref, delta=1e-12)
        # a block is the same wherever it is cut
        part = fn(10, 15)
        self.assertTrue(np.allclose(part, m[10:15], atol=1e-14))
        # no step and no draft: unity gain
        flat = mask.stft_gain_block_fn([], [], None, AUDIO, sr, n, k)(0, 3)
        self.assertTrue(np.array_equal(flat, np.ones((3, n // 2 + 1))))

    def test_stft_block_takes_live_values_at_call_time_of_construction(self):
        # the function is built per (steps, draft, live): a new `live` means a new function
        sr, n, k = 48000, 1024, 4
        draft = [rect(0, 10, 20, 24000, oid=1)]
        a = mask.stft_gain_block_fn([], draft, P(-6), AUDIO, sr, n, k)(0, 2)
        b = mask.stft_gain_block_fn([], draft, P(-12), AUDIO, sr, n, k)(0, 2)
        self.assertAlmostEqual(float(a[1, 100]), 10 ** (-6 / 20.0), delta=1e-12)
        self.assertAlmostEqual(float(b[1, 100]), 10 ** (-12 / 20.0), delta=1e-12)

    def test_stft_block_clamps_at_minus_300_db(self):
        steps = [step([rect(0, 10, 20, 24000, oid=1)], -1000)]
        m = mask.stft_gain_block_fn(steps, [], None, AUDIO, 48000, 1024, 4)(0, 3)
        self.assertTrue(np.all(m > 0))
        self.assertAlmostEqual(float(m.min()), 10 ** (-15.0), delta=1e-27)


class OpInterpretation(unittest.TestCase):
    def test_rect_geometry_and_feather_axes(self):
        p = mask.rect_from_op(rect(1, 3, 100, 1000), AUDIO)
        self.assertEqual(p["sign"], 1)
        self.assertAlmostEqual(p["lo_y"], math.log2(100))
        self.assertAlmostEqual(p["hi_y"], math.log2(1000))
        self.assertAlmostEqual(p["lo_x"], 1.0)
        self.assertEqual(mask.rect_from_op(rect(1, 3, 100, 1000, polarity="subtract"), AUDIO)["sign"], -1)
        fx, fy = mask.feather_axes(50.0, 6.0)
        self.assertAlmostEqual(fx, 0.05)
        self.assertAlmostEqual(fy, 0.5)
        self.assertEqual(mask.feather_axes(-3.0, -1.0), (0.0, 0.0))

    def test_step_values_clamp_the_feathers(self):
        self.assertEqual(mask.step_values({"gain": -6, "feather_ms": -5, "feather_st": 2, "size_px": 32, "fft_size": "2048"}),
                         (-6.0, 0.0, 2.0))

    def test_brush_reads_params_and_sizes(self):
        op = brush([(1, 1000), (3, 1000)], size_x=0.5, size_y=2.0, quantity=40, hardness=30)
        p = mask.brush_from_op(op, AUDIO)
        self.assertAlmostEqual(p["h"], 0.3)
        self.assertAlmostEqual(p["q"], 0.4)
        self.assertAlmostEqual(p["w"], 0.5 / 1.3)
        self.assertEqual((p["size_x"], p["size_y"]), (0.5, 2.0))
        # normalisation: u = x / size_x, v = log2(y) / size_y ; stroke of 2 s = 4 diameters -> 16 dabs
        self.assertEqual(len(p["dabs"]), 16)
        self.assertAlmostEqual(p["dabs"][0][0], (1 + 0.125 * 0.5) / 0.5)
        self.assertAlmostEqual(p["dabs"][0][1], math.log2(1000) / 2.0)

    def test_quantity_is_a_property_of_the_gesture(self):
        a = brush([(10, 50), (90, 50)], quantity=10, oid=1)
        b = brush([(10, 50), (90, 50)], quantity=40, oid=2)
        self.assertAlmostEqual(mask.selection_at(50, 50, [a], LIN), 0.10, delta=0.003)
        self.assertAlmostEqual(mask.selection_at(50, 50, [b], LIN), 0.40, delta=0.008)
        self.assertAlmostEqual(mask.selection_at(50, 50, [a, b], LIN), 0.50, delta=0.011)

    def test_missing_or_non_finite_params_raise(self):
        bad = brush([(1, 500), (3, 500)])
        del bad["params"]["quantity"]
        with self.assertRaises(ValueError):
            mask.selection_at(2, 500, [bad], AUDIO)
        bad = brush([(1, 500), (3, 500)])
        bad["params"]["quantity"] = float("nan")
        with self.assertRaises(ValueError):
            mask.selection_at(2, 500, [bad], AUDIO)
        bad = brush([(1, 500), (3, 500)])
        bad["size_x"] = float("inf")
        with self.assertRaises(ValueError):
            mask.brush_from_op(bad, AUDIO)
        bad = rect(1, 3, 100, 1000)
        bad["x0"] = float("nan")
        with self.assertRaises(ValueError):
            mask.rect_from_op(bad, AUDIO)

    def test_a_rect_needs_no_params_of_its_own(self):
        op = rect(1, 3, 100, 1000)
        op.pop("params")
        self.assertEqual(mask.selection_at(2, 300, [op], AUDIO), 1.0)

    def test_unknown_tools_and_degenerate_sizes_contribute_nothing(self):
        other = {"id": 1, "tool": "lasso", "kind": "point", "x": 1, "y": 2, "params": {}}
        self.assertEqual(mask.selection_at(1, 2, [other], AUDIO), 0.0)
        self.assertEqual(mask.compile_ops([other], AUDIO), [])
        # the old tool id is gone: an "eraser" op is just an unknown tool now
        old = brush([(1, 500), (3, 500)])
        old["tool"] = "eraser"
        self.assertEqual(mask.compile_ops([old], AUDIO), [])
        flat = brush([(1, 500), (3, 500)], size_x=0.0)
        self.assertIsNone(mask.brush_from_op(flat, AUDIO))
        self.assertEqual(mask.selection_at(2, 500, [flat], AUDIO), 0.0)

    def test_hardness_and_quantity_are_clamped_to_0_100(self):
        self.assertEqual(mask.brush_from_op(brush([(1, 500), (3, 500)], hardness=250), AUDIO)["h"], 1.0)
        self.assertEqual(mask.brush_from_op(brush([(1, 500), (3, 500)], hardness=-5), AUDIO)["h"], 0.0)
        self.assertEqual(mask.brush_from_op(brush([(1, 500), (3, 500)], quantity=250), AUDIO)["q"], 1.0)
        self.assertEqual(mask.brush_from_op(brush([(1, 500), (3, 500)], quantity=-5), AUDIO)["q"], 0.0)

    def test_is_open(self):
        self.assertTrue(mask.is_open(0.0, 0.0, 10.0))
        self.assertTrue(mask.is_open(1e-10, 0.0, 10.0))
        self.assertFalse(mask.is_open(1e-7, 0.0, 10.0))


if __name__ == "__main__":
    unittest.main()

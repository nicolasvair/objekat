import math
import os
import struct
import tempfile
import unittest

import numpy as np

import canvasfile
import mask
import selection

WORLD = {"x": {"min": 0.0, "max": 2.0, "mapping": "lin"}, "y": {"min": 20.0, "max": 24000.0, "mapping": "log"}}


def _read(path):
    with open(path, "rb") as f:
        return f.read()


def _write(path, data):
    with open(path, "wb") as f:
        f.write(data)


def rect(x0, x1, y0, y1, gain=-12.0, fms=10.0, fst=1.0, oid=1):
    """A STEP [(ops, params)] of one rect: the gain and the feathers belong to the step, not to the op."""
    op = {"id": oid, "kind": "rect", "tool": "rect", "polarity": "add", "x0": x0, "x1": x1, "y0": y0, "y1": y1,
          "params": {}}
    return ([op], {"gain": gain, "feather_ms": fms, "feather_st": fst})


def brush(points, size_x, size_y, quantity=25.0, hardness=50.0, gain=-12.0, oid=1):
    """A STEP of one brush stroke (gain -12 and quantity 25 % make the historical -3 dB per pass)."""
    op = {"id": oid, "kind": "stroke", "tool": "brush", "polarity": "add", "points": [list(p) for p in points],
          "size_pt": 32, "size_x": size_x, "size_y": size_y,
          "params": {"quantity": quantity, "hardness": hardness}}
    return ([op], {"gain": gain, "feather_ms": 0.0, "feather_st": 0.0})


def world_t(seconds):
    return {"x": {"min": 0.0, "max": seconds, "mapping": "lin"}, "y": WORLD["y"]}


class Grid(unittest.TestCase):
    def test_dimensions(self):
        self.assertEqual(selection.grid_dims(world_t(2.0)), (400, 512))
        self.assertEqual(selection.grid_dims(world_t(0.5)), (256, 512))
        self.assertEqual(selection.grid_dims(world_t(20.48)), (4096, 512))
        self.assertEqual(selection.grid_dims(world_t(120.0)), (4096, 512))
        self.assertEqual(selection.grid_dims(world_t(1.2501)), (256, 512))
        xw, yw = selection.grid_axes(WORLD)
        self.assertEqual((len(xw), len(yw)), (400, 512))
        self.assertTrue(np.all(np.diff(xw) > 0) and np.all(np.diff(yw) > 0))
        self.assertAlmostEqual(xw[0], 0.5 * 2.0 / 400)
        self.assertAlmostEqual(xw[-1], 2.0 - 0.5 * 2.0 / 400)
        span = math.log2(24000 / 20.0)
        self.assertAlmostEqual(yw[0], math.log2(20) + 0.5 * span / 512)
        self.assertAlmostEqual(yw[-1], math.log2(24000) - 0.5 * span / 512)

    def test_selection_grid_row_of_a_frequency_matches_the_base_image(self):
        # a row of the selection grid covers the same band as a row of the 1024-row base image pair
        import image
        r_base = image.row_of_frequency(3000, 48000)
        r_grid = 511 - int((math.log2(3000 / 20.0) / math.log2(24000 / 20.0)) * 512)
        self.assertEqual(r_base // 2, r_grid)


class TimeAlignment(unittest.TestCase):
    """The selection layer and the audio sample the same continuous G(t), each at the CENTRE time of its cell
    (a column's middle, an STFT frame's centre j H / sr), so what is drawn is what is heard."""

    def test_columns_sample_g_at_their_centre_time(self):
        op = rect(0.9, 1.4, 200, 4000, gain=-18, fms=100, fst=3)
        xw, yw = selection.grid_axes(WORLD)
        g = mask.gain_grid([op], xw, yw, WORLD)
        wc = 2.0 / len(xw)
        for c in (0, 100, 180, 200, 240, 399):
            self.assertAlmostEqual(float(xw[c]), (c + 0.5) * wc, delta=1e-12)
            y = float(yw[250])
            self.assertAlmostEqual(float(g[c, 250]), mask.gain_at_warped(float(xw[c]), y, [op], WORLD), delta=1e-9)

    def test_selection_grid_and_stft_mask_agree_on_where_a_sharp_edge_is(self):
        sr, n, k = 48000, 2048, 4
        h = 512
        op = rect(1.0, 2.0, 100, 20000, gain=-12, fms=0, fst=0)
        # audio side: the first STFT frame whose centre is at or after 1.0 s is the first attenuated one
        fn = mask.stft_gain_block_fn([op], [], None, WORLD, sr, n, k)
        m = fn(0, 200)
        attenuated = [j for j in range(200) if m[j, 100] < 0.99]
        self.assertEqual(attenuated[0], int(math.ceil(1.0 * sr / h)))
        self.assertGreaterEqual(attenuated[0] * h / float(sr), 1.0)
        self.assertLess((attenuated[0] - 1) * h / float(sr), 1.0)
        # picture side: same rule at the cell centres
        xw, yw = selection.grid_axes(WORLD)
        g = mask.gain_grid([op], xw, yw, WORLD)
        col = int(np.nonzero(g[:, 300] < -1.0)[0][0])
        self.assertGreaterEqual(float(xw[col]), 1.0)
        self.assertLess(float(xw[col - 1]), 1.0)
        # the two sides never disagree about a time by more than half of the coarser cell
        self.assertLessEqual(abs(float(xw[col]) - attenuated[0] * h / float(sr)), max(h / float(sr), 2.0 / 400))


def draft_rect(x0, x1, y0, y1, polarity="add", oid=1):
    """A bare OP (a pending selection gesture), as the draft entries carry them."""
    return {"id": oid, "kind": "rect", "tool": "rect", "polarity": polarity, "x0": x0, "x1": x1,
            "y0": y0, "y1": y1, "params": {}}


def draft_brush(points, size_x, size_y, quantity=25.0, hardness=50.0, polarity="add", oid=1):
    return {"id": oid, "kind": "stroke", "tool": "brush", "polarity": polarity,
            "points": [list(p) for p in points], "size_pt": 32, "size_x": size_x, "size_y": size_y,
            "params": {"quantity": quantity, "hardness": hardness}}


class SelectionRender(unittest.TestCase):
    def _pixel(self, s):
        return selection.render_selection(np.full((3, 2), float(s)))[0, 0]

    def test_amber_premultiplied_alpha_is_06_s(self):
        self.assertEqual(self._pixel(0.0).tolist(), [0, 0, 0, 0])
        for s in (0.5, 1.0, 0.25, 0.93):
            a = 0.6 * s
            want = [round(1.0 * a * 255), round(0.85 * a * 255), round(0.25 * a * 255), round(a * 255)]
            self.assertEqual(self._pixel(s).tolist(), want, s)
        self.assertEqual(self._pixel(1.0).tolist(), [153, 130, 38, 153])
        self.assertEqual(int(self._pixel(0.5)[3]), 76)   # 0.3 * 255 = 76.5, rounded to even
        self.assertTrue(all(int(c) <= int(self._pixel(0.7)[3]) for c in self._pixel(0.7)[:3]))   # premultiplied

    def test_out_of_range_is_clamped(self):
        self.assertEqual(self._pixel(3.0).tolist(), self._pixel(1.0).tolist())
        self.assertEqual(self._pixel(-1.0).tolist(), [0, 0, 0, 0])

    def test_orientation_row_zero_is_the_top_and_dims_are_the_grids(self):
        s = np.zeros((4, 3))
        s[:, 2] = 1.0   # the highest row from the bottom
        img = selection.render_selection(s)
        self.assertEqual(img.shape, (3, 4, 4))
        self.assertEqual(int(img[0, 0, 3]), 153)
        self.assertEqual(int(img[2, 0, 3]), 0)
        s = np.zeros((4, 3))
        s[3, :] = 1.0   # the last column
        img = selection.render_selection(s)
        self.assertEqual(int(img[0, 3, 3]), 153)
        self.assertEqual(int(img[0, 0, 3]), 0)
        xw, yw = selection.grid_axes(WORLD)
        grid = mask.selection_grid([draft_rect(0.5, 1.5, 1000, 5000)], xw, yw, WORLD)
        self.assertEqual(selection.render_selection(grid).shape, (512, 400, 4))

    def test_alpha_of_a_rect_selection_at_one_second_3_khz(self):
        # what the end-to-end test will check: a rect over 2-4.5 kHz, 1 s in, 3 kHz: alpha ~ 0.6; 300 Hz: 0
        xw, yw = selection.grid_axes(WORLD)
        grid = mask.selection_grid([draft_rect(0, 2, 2000, 4500)], xw, yw, WORLD)
        img = selection.render_selection(grid)
        col = 200
        row_3k = 511 - int((math.log2(3000 / 20.0) / math.log2(24000 / 20.0)) * 512)
        row_300 = 511 - int((math.log2(300 / 20.0) / math.log2(24000 / 20.0)) * 512)
        self.assertAlmostEqual(img[row_3k, col, 3] / 255.0, 0.6, delta=0.005)
        self.assertEqual(int(img[row_300, col, 3]), 0)

    def test_file_header_and_size(self):
        xw, yw = selection.grid_axes(WORLD)
        grid = mask.selection_grid([draft_rect(0.5, 1.5, 1000, 5000)], xw, yw, WORLD)
        p = os.path.join(tempfile.mkdtemp(), "selection-1.objkrgb")
        selection.write_selection(p, grid)
        raw = _read(p)
        self.assertEqual(raw[:8], b"OBJKRGB1")
        self.assertEqual(struct.unpack("<II", raw[8:16]), (400, 512))
        self.assertEqual(len(raw), 24 + 4 * 400 * 512)
        self.assertEqual(canvasfile.read_rgb(p).shape, (512, 400, 4))


class SelectionCacheTests(unittest.TestCase):
    FMS, FST = 10.0, 1.0

    def _drafts(self, n):
        out = []
        for i in range(n):
            polarity = "subtract" if i % 4 == 3 else "add"
            if i % 2 == 0:
                out.append(draft_rect(0.1 * i, 0.1 * i + 0.8, 200 * (i + 1), 900 * (i + 1), polarity=polarity, oid=i + 1))
            else:
                out.append(draft_brush([(0.1 * i, 300), (0.1 * i + 1.0, 4000)], 0.1, 1.0, quantity=40.0,
                                       polarity=polarity, oid=i + 1))
        return out

    def _full(self, ops, world=WORLD, fms=FMS, fst=FST):
        xw, yw = selection.grid_axes(world)
        return mask.selection_grid(ops, xw, yw, world, fms, fst)

    def test_incremental_equals_full_exactly(self):
        ops = self._drafts(8)
        c = selection.SelectionCache()
        for n in range(1, 9):
            s = c.update(ops[:n], WORLD, self.FMS, self.FST)
            self.assertTrue(np.array_equal(s, self._full(ops[:n])), n)
        self.assertEqual((c.full_recomputes, c.incremental_updates), (1, 7))
        self.assertGreater(float(s.max()), 0.5)
        self.assertLess(float(s.max()), 1.0 + 1e-12)

    def test_same_list_is_free_undo_recomputes_and_redo_is_incremental(self):
        ops = self._drafts(5)
        c = selection.SelectionCache()
        c.update(ops, WORLD, self.FMS, self.FST)
        c.update(ops, WORLD, self.FMS, self.FST)
        self.assertEqual((c.full_recomputes, c.incremental_updates), (1, 0))
        s = c.update(ops[:3], WORLD, self.FMS, self.FST)   # undo of two drafts
        self.assertEqual(c.full_recomputes, 2)
        self.assertTrue(np.array_equal(s, self._full(ops[:3])))
        s = c.update(ops[:4], WORLD, self.FMS, self.FST)   # a gesture drawn again: appended
        self.assertEqual((c.full_recomputes, c.incremental_updates), (2, 1))
        self.assertTrue(np.array_equal(s, self._full(ops[:4])))

    def test_a_feather_change_recomputes(self):
        ops = self._drafts(4)
        c = selection.SelectionCache()
        s0 = c.update(ops, WORLD, 10.0, 1.0).copy()
        s1 = c.update(ops, WORLD, 80.0, 3.0)
        self.assertEqual(c.full_recomputes, 2)
        self.assertTrue(np.array_equal(s1, self._full(ops, fms=80.0, fst=3.0)))
        self.assertFalse(np.array_equal(s0, s1))
        c.update(ops, WORLD, 80.0, 3.0)
        self.assertEqual(c.full_recomputes, 2)   # unchanged feathers: free
        c.update(ops, WORLD, 80.0, 0.0)          # either one counts
        self.assertEqual(c.full_recomputes, 3)

    def test_an_empty_selection_is_a_clear_grid(self):
        c = selection.SelectionCache()
        s = c.update([], WORLD, self.FMS, self.FST)
        self.assertEqual(float(np.abs(s).max()), 0.0)
        self.assertEqual(s.shape, (400, 512))

    def test_the_same_op_id_with_other_content_is_not_trusted(self):
        a = draft_rect(0.2, 0.6, 100, 300, oid=1)
        b = draft_rect(0.2, 0.6, 100, 900, oid=1)
        c = selection.SelectionCache()
        c.update([a], WORLD, self.FMS, self.FST)
        s = c.update([b, draft_rect(1, 1.5, 100, 300, oid=2)], WORLD, self.FMS, self.FST)
        self.assertEqual(c.full_recomputes, 2)
        self.assertTrue(np.array_equal(s, self._full([b, draft_rect(1, 1.5, 100, 300, oid=2)])))

    def test_world_change_recomputes_with_new_dimensions(self):
        c = selection.SelectionCache()
        c.update([draft_rect(0.1, 0.5, 100, 300)], WORLD, self.FMS, self.FST)
        s = c.update([draft_rect(0.1, 0.5, 100, 300)], world_t(10.0), self.FMS, self.FST)
        self.assertEqual(s.shape, (2000, 512))
        self.assertEqual(c.full_recomputes, 2)

    def test_a_subtract_that_empties_what_it_covers(self):
        base = draft_rect(0.2, 1.8, 200, 8000, oid=1)
        erase = draft_rect(0.6, 1.0, 400, 2000, polarity="subtract", oid=2)
        c = selection.SelectionCache()
        c.update([base], WORLD, 0.0, 0.0)
        s = c.update([base, erase], WORLD, 0.0, 0.0)
        self.assertEqual(c.incremental_updates, 1)
        xw, yw = selection.grid_axes(WORLD)
        i, j = int(np.argmin(np.abs(xw - 0.8))), int(np.argmin(np.abs(yw - math.log2(900))))
        self.assertEqual(float(s[i, j]), 0.0)
        i2 = int(np.argmin(np.abs(xw - 1.5)))
        self.assertEqual(float(s[i2, j]), 1.0)


if __name__ == "__main__":
    unittest.main()

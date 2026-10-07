"""The Editor's conversation with the app, against a fake app (no socket): which messages it sends, and when.

Revision 4: the committed steps are shown by the spectrogram itself (`set_image` with the history rev),
never by an overlay; the audio opens on the result; a live tweak redraws nothing."""
import shutil
import tempfile
import unittest

import numpy as np

import spectral_editor as sg

SR = 8000
VALUES = {"gain": -12, "feather_ms": 10, "feather_st": 1, "fft_size": "1024", "overlap": 4}


class FakeApp:
    def __init__(self):
        self.calls = []

    def send(self, cmd, params=None):
        self.calls.append((cmd, dict(params or {})))
        return {}

    def named(self, cmd):
        return [p for c, p in self.calls if c == cmd]

    def bases(self):
        """The set_image calls that carry the BASE image (the result's picture)."""
        return [p for p in self.named("script.canvas.set_image") if "slot" not in p]

    def slots(self, slot):
        """The set_image calls that carry the picture of an audio slot."""
        return [p for p in self.named("script.canvas.set_image") if p.get("slot") == slot]


def op(oid, kind="rect"):
    return {"id": oid, "kind": kind, "tool": "rect", "polarity": "add", "x0": 0.2, "x1": 0.6, "y0": 200.0,
            "y1": 2000.0, "params": {}}


def answer(entries, cursor=None, values=None, rev=1):
    cursor = len(entries) if cursor is None else cursor
    pending = sum(1 for e in entries[:cursor] if e["kind"] == "draft")
    return {"state": "open", "rev": rev, "values": dict(values or VALUES),
            "history": {"rev": rev, "cursor": cursor, "count": len(entries), "pending": pending, "entries": entries}}


def step(oid):
    return {"id": oid, "kind": "step", "ops": [op(oid)], "params": {"gain": -12, "feather_ms": 10, "feather_st": 1}}


def draft(oid):
    return {"id": oid, "kind": "draft", "ops": [op(oid)]}


class EditorProtocol(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.work, True)
        rng = np.random.RandomState(1)
        x = (0.1 * rng.randn(SR, 2)).astype(np.float32)
        self.app = FakeApp()
        self.ed = sg.Editor(self.app, "cid", self.work, x, SR, "")

    def start(self):
        self.ed.send_base(self.ed.x, 1024, 4, [], 0)
        self.ed.app.send("script.canvas.set_audio", {"listen": "result"})
        self.ed.result_key = self.ed.audio_key = (0, 1024, 4, None)
        self.ed.fft = (1024, 4)
        self.ed.original_fft = (1024, 4)             # the pictures of a first display: Original, and silence
        self.ed.delta_key = ([], 1024, 4)
        self.app.calls.clear()

    def test_a_committed_step_refreshes_the_picture_with_the_rev_and_sends_no_layer(self):
        self.start()
        self.ed.sync(answer([step(1)], rev=1))
        images = self.app.bases()
        self.assertEqual(len(images), 1)
        self.assertEqual(images[0]["history_rev"], 1)
        self.assertEqual(self.app.named("script.canvas.set_layer"), [])  # no veil, no selection
        self.assertEqual(len(self.app.named("script.canvas.set_audio")), 1)
        self.assertEqual(self.app.named("script.canvas.set_audio")[0]["history_rev"], 1)

    def test_the_picture_shows_the_attenuation(self):
        import image
        self.start()
        self.ed.sync(answer([step(1)], rev=1))
        y = self.ed.committed[3]
        before = image.build_image(self.ed.x, SR, 1024, 4)
        after = image.build_image(y, SR, 1024, 4)
        self.assertFalse(np.array_equal(before[0] if isinstance(before, tuple) else before,
                                        after[0] if isinstance(after, tuple) else after))

    def test_the_audio_and_the_picture_share_one_computation(self):
        self.start()
        calls = []
        real = sg.dsp.process
        sg.dsp.process = lambda *a, **k: (calls.append(1), real(*a, **k))[1]
        self.addCleanup(setattr, sg.dsp, "process", real)
        self.ed.sync(answer([step(1)], rev=1))
        self.assertEqual(len(calls), 1)

    def test_undo_redraws_the_original_and_redo_the_result(self):
        self.start()
        entries = [step(1)]
        self.ed.sync(answer(entries, rev=1))
        self.app.calls.clear()
        self.ed.sync(answer(entries, cursor=0, rev=2))
        self.assertEqual(len(self.app.bases()), 1)
        self.assertEqual(self.app.bases()[0]["history_rev"], 2)
        self.assertEqual(self.ed.image_steps, [])

    def test_a_live_tweak_with_a_pending_selection_redraws_no_picture(self):
        self.start()
        entries = [draft(1)]
        self.ed.sync(answer(entries, rev=1))
        images = len(self.app.named("script.canvas.set_image"))
        self.assertEqual(images, 0)  # a draft is not applied: no picture at all is redrawn (Original, Difference, Result)
        self.assertEqual(len(self.app.named("script.canvas.set_layer")), 1)
        self.app.calls.clear()
        self.ed.sync(answer(entries, values=dict(VALUES, gain=-20), rev=2))
        self.assertEqual(self.app.named("script.canvas.set_image"), [])
        self.assertEqual(len(self.app.named("script.canvas.set_audio")), 1)

    def test_apply_replaces_the_selection_layer_by_the_refreshed_picture(self):
        self.start()
        self.ed.sync(answer([draft(1)], rev=1))
        self.app.calls.clear()
        self.ed.sync(answer([step(1)], rev=2))   # the app sealed the draft into a step
        cmds = [c for c, _ in self.app.calls]
        self.assertLess(cmds.index("script.canvas.set_image"), cmds.index("script.canvas.set_layer"))
        layer = self.app.named("script.canvas.set_layer")[0]
        self.assertIsNone(layer["path"])  # the amber layer goes, nothing blue replaces it

    def test_a_new_overlap_redraws_the_picture_and_the_audio_at_once_with_the_history_kept(self):
        import struct
        self.start()
        entries = [step(1)]
        self.ed.sync(answer(entries, rev=1))
        self.app.calls.clear()
        self.ed.sync(answer(entries, values=dict(VALUES, overlap=8), rev=2))   # the hand moved the slider
        images, audios = self.app.bases(), self.app.named("script.canvas.set_audio")
        self.assertEqual((len(images), len(audios)), (1, 1))
        # a new analysis redraws the Original's picture and the Difference's too (they follow the ear)
        self.assertEqual((len(self.app.slots("original")), len(self.app.slots("delta"))), (1, 1))
        self.assertEqual(self.ed.fft, (1024, 8))
        with open(images[0]["path"], "rb") as f:
            width = struct.unpack("<I", f.read(12)[8:12])[0]
        self.assertEqual(width, SR // sg.dsp.hop_for(1024, 8) + 1)   # one column per NEW hop
        self.assertEqual(len(self.ed.image_steps), 1)                # the step is still applied
        y = self.ed.committed[3]
        self.assertEqual(self.ed.committed[1:3], (1024, 8))
        self.assertGreater(float(np.abs(y - self.ed.x).max()), 1e-3)             # and still attenuates
        self.app.calls.clear()
        self.ed.sync(answer(entries, values=dict(VALUES, overlap=8), rev=2))      # nothing changed: nothing sent
        self.assertEqual(self.app.calls, [])

    def test_each_listening_state_has_its_own_picture(self):
        """Revision 5: the Original's picture is made once per analysis (and never redrawn by a step), the
        Result's is the base image, the Difference's is the original minus the committed result."""
        import struct
        self.start()
        self.ed.sync(answer([step(1)], rev=1))
        self.assertEqual(len(self.app.bases()), 1)
        self.assertEqual(self.app.slots("original"), [])           # unchanged by a step: sent once, at the start
        deltas = self.app.slots("delta")
        self.assertEqual(len(deltas), 1)
        self.assertEqual(deltas[0]["history_rev"], 1)
        self.assertNotIn("x", deltas[0])                           # a slot's picture covers the base image's world
        self.assertEqual(self.app.calls[-1][0], "script.canvas.set_image")   # the difference comes last: busy is off
        busy = [p.get("busy") for c, p in self.app.calls if c == "script.canvas.update"]
        self.assertEqual(busy[-1], False)
        import image
        # the delta image is NOT black once a step removed something, and IS black with no step
        def body(path):
            with open(path, "rb") as f:
                head = f.read(796)
                w, h = struct.unpack("<II", head[8:16])
                return w, h, np.frombuffer(f.read(w * h), dtype=np.uint8)
        w, h, px = body(deltas[0]["path"])
        self.assertGreater(int(px.max()), 0)
        self.app.calls.clear()
        self.ed.sync(answer([step(1)], cursor=0, rev=2))           # undone: silence
        w, h, px = body(self.app.slots("delta")[0]["path"])
        self.assertEqual(int(px.max()), 0)
        self.assertEqual(w, SR // sg.dsp.hop_for(1024, 4) + 1)

    def test_the_original_picture_is_sent_with_the_first_display_and_follows_the_analysis(self):
        self.ed.app.calls.clear()
        self.ed.send_base(self.ed.x, 1024, 4, [], 0)               # the first display
        base, orig = self.app.bases(), self.app.slots("original")
        self.assertEqual((len(base), len(orig)), (1, 1))
        self.assertNotEqual(base[0]["path"], orig[0]["path"])      # a file of its own (the base ones are recycled)
        with open(base[0]["path"], "rb") as a, open(orig[0]["path"], "rb") as b:
            self.assertEqual(a.read(), b.read())                   # ... with no step it is the same picture
        self.ed.send_base(self.ed.x, 1024, 4, [], 0)
        self.assertEqual(len(self.app.slots("original")), 1)       # same analysis: not sent again
        self.ed.send_base(self.ed.x, 1024, 6, [], 0)
        self.assertEqual(len(self.app.slots("original")), 2)       # a new overlap: redrawn

    # -- revision 6: the display range ---------------------------------------------------------

    def header(self, path):
        import struct
        with open(path, "rb") as f:
            return struct.unpack("<ff", f.read(28)[16:24])

    def pixels(self, path):
        import struct
        with open(path, "rb") as f:
            head = f.read(796)
            w, h = struct.unpack("<II", head[8:16])
            return np.frombuffer(f.read(w * h), dtype=np.uint8)

    def test_a_new_range_recolours_the_three_pictures_from_memory_with_no_transform(self):
        self.start()
        self.ed.sync(answer([step(1)], rev=1))
        calls = []
        real = sg.dsp.process
        sg.dsp.process = lambda *a, **k: (calls.append(1), real(*a, **k))[1]
        self.addCleanup(setattr, sg.dsp, "process", real)
        real_stft = sg.dsp.analysis_blocks
        sg.dsp.analysis_blocks = lambda *a, **k: (calls.append(2), real_stft(*a, **k))[1]
        self.addCleanup(setattr, sg.dsp, "analysis_blocks", real_stft)
        self.app.calls.clear()
        self.ed.sync(answer([step(1)], values=dict(VALUES, db_floor=-60, db_ceiling=-10), rev=1))
        self.assertEqual(calls, [])                               # no new transform, no audio recomputed
        self.assertEqual(self.app.named("script.canvas.set_audio"), [])
        self.assertEqual(self.app.named("script.canvas.set_layer"), [])
        base, orig, delta = self.app.bases(), self.app.slots("original"), self.app.slots("delta")
        self.assertEqual((len(base), len(orig), len(delta)), (1, 1, 1))
        for p in (base[0], orig[0], delta[0]):
            self.assertEqual(self.header(p["path"]), (-60.0, -10.0))
        self.assertEqual(base[0]["history_rev"], 1)               # the same stamp: what the app does with traces is unchanged
        self.assertEqual(delta[0]["history_rev"], 1)
        self.assertEqual(base[0]["value_unit"], "dB")
        self.app.calls.clear()
        self.ed.sync(answer([step(1)], values=dict(VALUES, db_floor=-60, db_ceiling=-10), rev=1))
        self.assertEqual(self.app.calls, [])                      # the same range again: nothing sent

    def test_the_recoloured_picture_is_the_one_a_fresh_build_would_give(self):
        import image
        self.start()
        self.ed.sync(answer([step(1)], rev=1))
        self.app.calls.clear()
        self.ed.sync(answer([step(1)], values=dict(VALUES, db_floor=-80, db_ceiling=-20), rev=1))
        want = image.build_image(self.ed.committed[3], SR, 1024, 4, floor=-80.0, ceil=-20.0)
        got = self.pixels(self.app.bases()[0]["path"])
        self.assertLessEqual(int(np.abs(got.astype(int) - want.ravel(order="C").astype(int)).max()), 1)
        orig = self.pixels(self.app.slots("original")[0]["path"])
        want_o = image.build_image(self.ed.x, SR, 1024, 4, floor=-80.0, ceil=-20.0)
        self.assertLessEqual(int(np.abs(orig.astype(int) - want_o.ravel().astype(int)).max()), 1)

    def test_a_new_picture_is_written_for_the_current_range_and_only_the_others_are_recoloured(self):
        self.start()
        vals = dict(VALUES, db_floor=-90, db_ceiling=-5)
        self.ed.sync(answer([step(1)], values=vals, rev=1))      # range changed AND a step committed together
        base, orig, delta = self.app.bases(), self.app.slots("original"), self.app.slots("delta")
        self.assertEqual((len(base), len(orig), len(delta)), (1, 1, 1))   # each sent once, not twice
        self.assertEqual(self.header(base[0]["path"]), (-90.0, -5.0))
        self.assertEqual(self.header(orig[0]["path"]), (-90.0, -5.0))
        self.assertEqual(self.header(delta[0]["path"]), (-90.0, -5.0))

    def test_the_range_leaves_the_audio_and_the_selection_alone(self):
        self.start()
        self.ed.sync(answer([draft(1)], rev=1))
        self.app.calls.clear()
        self.ed.sync(answer([draft(1)], values=dict(VALUES, db_floor=-70), rev=1))
        self.assertEqual(self.app.named("script.canvas.set_audio"), [])
        self.assertEqual(self.app.named("script.canvas.set_layer"), [])
        self.assertEqual(self.app.named("script.canvas.update"), [])      # not even a busy flash
        self.assertGreaterEqual(len(self.app.named("script.canvas.set_image")), 1)

    def test_the_range_controls_are_view_settings_with_their_limits(self):
        ctl = {c["id"]: c for c in sg.canvas_controls()}
        self.assertEqual((ctl["db_floor"]["min"], ctl["db_floor"]["max"], ctl["db_floor"]["value"]), (-120, -20, -100))
        self.assertEqual((ctl["db_ceiling"]["min"], ctl["db_ceiling"]["max"], ctl["db_ceiling"]["value"]), (-60, 0, 0))
        self.assertTrue(ctl["db_floor"]["advanced"] and ctl["db_ceiling"]["advanced"])

    def test_the_gain_is_a_row_of_preset_buttons_not_a_slider(self):
        ctl = {c["id"]: c for c in sg.canvas_controls()}["gain"]
        self.assertEqual(ctl["kind"], "number")
        self.assertEqual(ctl["presets"], [-60, -24, -12, -6, -3, 3])          # exactly these, in this order
        self.assertEqual(ctl["value"], -12)                                    # the default is one of them
        self.assertIn(ctl["value"], ctl["presets"])
        self.assertTrue(all(ctl["min"] <= p <= ctl["max"] for p in ctl["presets"]))   # the app refuses otherwise
        self.assertEqual(len(set(ctl["presets"])), len(ctl["presets"]))
        self.assertFalse(ctl.get("advanced", False))                           # not behind Expert

    def test_the_feather_range_goes_to_one_second_and_the_defaults_are_unchanged(self):
        ctl = {c["id"]: c for c in sg.canvas_controls()}
        self.assertEqual((ctl["feather_ms"]["min"], ctl["feather_ms"]["max"], ctl["feather_ms"]["value"]), (0, 1000, 10))

    def test_the_remember_key_comes_from_the_environment_for_tests(self):
        import os
        old = os.environ.get("OBJEKAT_SPECTRAL_REMEMBER")
        try:
            os.environ["OBJEKAT_SPECTRAL_REMEMBER"] = "k.test"
            self.assertEqual(sg.remember_key(), "k.test")
            del os.environ["OBJEKAT_SPECTRAL_REMEMBER"]
            self.assertTrue(sg.remember_key())
        finally:
            if old is not None:
                os.environ["OBJEKAT_SPECTRAL_REMEMBER"] = old


if __name__ == "__main__":
    unittest.main()

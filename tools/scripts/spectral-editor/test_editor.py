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
        self.app.calls.clear()

    def test_a_committed_step_refreshes_the_picture_with_the_rev_and_sends_no_layer(self):
        self.start()
        self.ed.sync(answer([step(1)], rev=1))
        images = self.app.named("script.canvas.set_image")
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
        self.assertEqual(len(self.app.named("script.canvas.set_image")), 1)
        self.assertEqual(self.app.named("script.canvas.set_image")[0]["history_rev"], 2)
        self.assertEqual(self.ed.image_steps, [])

    def test_a_live_tweak_with_a_pending_selection_redraws_no_picture(self):
        self.start()
        entries = [draft(1)]
        self.ed.sync(answer(entries, rev=1))
        images = len(self.app.named("script.canvas.set_image"))
        self.assertEqual(images, 0)  # a draft is not applied: the picture is the original's, unchanged
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
        images, audios = self.app.named("script.canvas.set_image"), self.app.named("script.canvas.set_audio")
        self.assertEqual((len(images), len(audios)), (1, 1))
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

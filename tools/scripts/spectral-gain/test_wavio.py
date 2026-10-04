import os
import struct
import tempfile
import unittest

import numpy as np

import wavio


def _tmp(name):
    return os.path.join(tempfile.mkdtemp(prefix="sgwav"), name)


def _signal(frames, ch, seed=1):
    rng = np.random.RandomState(seed)
    return (rng.uniform(-0.9, 0.9, size=(frames, ch))).astype(np.float64)


class RoundTrip(unittest.TestCase):
    def _rt(self, kind, ch, bits, tol):
        x = _signal(1001, ch)
        p = _tmp("a.wav")
        clipped = wavio.write_wav(p, x, 44100, kind)
        self.assertEqual(clipped, 0)
        y, info = wavio.read_wav(p)
        self.assertEqual((info.sample_rate, info.channels, info.bit_depth, info.frames), (44100, ch, bits, 1001))
        self.assertEqual(y.shape, (1001, ch))
        self.assertLessEqual(float(np.max(np.abs(x - y))), tol)
        self.assertFalse(os.path.exists(p + ".tmp"))
        return p, info

    def test_pcm16_mono_stereo(self):
        for ch in (1, 2):
            _, info = self._rt("pcm16", ch, 16, 0.5 / 32768 + 1e-12)
            self.assertEqual(info.kind, "pcm_int")

    def test_pcm24_mono_stereo(self):
        for ch in (1, 2):
            _, info = self._rt("pcm24", ch, 24, 0.5 / 8388608 + 1e-12)
            self.assertEqual(info.kind, "pcm_int")

    def test_f32_mono_stereo(self):
        for ch in (1, 2):
            p, info = self._rt("f32", ch, 32, 1e-7)
            self.assertEqual(info.kind, "pcm_float")
            raw = open(p, "rb").read()
            self.assertIn(b"fact", raw)

    def test_f32_is_bit_exact_for_float32_input(self):
        x = _signal(500, 2).astype(np.float32)
        p = _tmp("b.wav")
        wavio.write_wav(p, x, 48000, "f32")
        y, _ = wavio.read_wav(p)
        self.assertTrue(np.array_equal(y.astype(np.float32), x))

    def test_int_read_exact_24(self):
        ints = np.array([[0], [1], [-1], [8388607], [-8388608], [123456], [-654321]], dtype=np.int64)
        x = ints / 8388608.0
        p = _tmp("c.wav")
        wavio.write_wav(p, x, 48000, "pcm24")
        got, info = wavio.read_wav_int(p)
        self.assertTrue(np.array_equal(got, ints))
        self.assertEqual(info.bit_depth, 24)

    def test_int_read_16(self):
        ints = np.array([[0, 1], [-32768, 32767], [-5, 7]])
        p = _tmp("d.wav")
        wavio.write_wav(p, ints / 32768.0, 8000, "pcm16")
        got, _ = wavio.read_wav_int(p)
        self.assertTrue(np.array_equal(got, ints))

    def test_int_read_rejects_float(self):
        p = _tmp("e.wav")
        wavio.write_wav(p, np.zeros((4, 1)), 8000, "f32")
        with self.assertRaises(wavio.WavError):
            wavio.read_wav_int(p)

    def test_1d_input_accepted(self):
        p = _tmp("f.wav")
        wavio.write_wav(p, np.zeros(10), 8000, "pcm16")
        self.assertEqual(wavio.read_wav_info(p).channels, 1)


class Clipping(unittest.TestCase):
    def test_count_and_values(self):
        x = np.array([0.0, 0.5, 1.0, 1.5, -1.0, -1.5, 0.999999], dtype=np.float64)
        p = _tmp("g.wav")
        n = wavio.write_wav(p, x, 48000, "pcm16")
        # 1.0 (32768), 1.5, -1.5 are out of range; -1.0 is exactly the minimum; 0.999999 rounds to 32767.97 -> 32768 clipped
        self.assertEqual(n, 4)
        got, _ = wavio.read_wav_int(p)
        self.assertEqual(got[:, 0].tolist(), [0, 16384, 32767, 32767, -32768, -32768, 32767])

    def test_f32_never_clips(self):
        p = _tmp("h.wav")
        self.assertEqual(wavio.write_wav(p, np.array([2.0, -3.0]), 48000, "f32"), 0)
        y, _ = wavio.read_wav(p)
        self.assertEqual(y[:, 0].tolist(), [2.0, -3.0])

    def test_no_dither_is_deterministic(self):
        x = _signal(300, 1)
        a, b = _tmp("i.wav"), _tmp("j.wav")
        wavio.write_wav(a, x, 44100, "pcm24")
        wavio.write_wav(b, x, 44100, "pcm24")
        self.assertEqual(open(a, "rb").read(), open(b, "rb").read())


def _build_wave(fmt_chunk, data, rf64=False, extra=b""):
    if rf64:
        ds64 = struct.pack("<4sIQQQI", b"ds64", 28, 0, len(data), len(data) // 4, 0)
        body = b"WAVE" + ds64 + fmt_chunk + extra + struct.pack("<4sI", b"data", 0xFFFFFFFF) + data
        return b"RF64" + struct.pack("<I", 0xFFFFFFFF) + body
    body = b"WAVE" + fmt_chunk + extra + struct.pack("<4sI", b"data", len(data)) + data
    return b"RIFF" + struct.pack("<I", len(body)) + body


def _fmt_ext(ch, sr, bits, subtag, valid_bits=None):
    guid = struct.pack("<H", subtag) + bytes.fromhex("000000001000800000aa00389b71")
    align = ch * bits // 8
    return (struct.pack("<4sIHHIIHH", b"fmt ", 40, 0xFFFE, ch, sr, sr * align, align, bits)
            + struct.pack("<HHI", 22, valid_bits or bits, 3) + guid)


class Headers(unittest.TestCase):
    def test_extensible_pcm24(self):
        ints = np.array([100, -200, 300, -400], dtype=np.int32)
        raw = b"".join(struct.pack("<i", int(v))[:3] for v in ints)
        p = _tmp("k.wav")
        open(p, "wb").write(_build_wave(_fmt_ext(2, 96000, 24, 1), raw))
        got, info = wavio.read_wav_int(p)
        self.assertEqual((info.channels, info.sample_rate, info.bit_depth, info.kind), (2, 96000, 24, "pcm_int"))
        self.assertEqual(got.reshape(-1).tolist(), ints.tolist())

    def test_extensible_float32(self):
        v = np.array([0.25, -0.5], dtype="<f4")
        p = _tmp("l.wav")
        open(p, "wb").write(_build_wave(_fmt_ext(1, 48000, 32, 3), v.tobytes()))
        y, info = wavio.read_wav(p)
        self.assertEqual(info.kind, "pcm_float")
        self.assertEqual(y[:, 0].tolist(), [0.25, -0.5])

    def test_rf64(self):
        ints = np.array([1, -2, 3, -4, 5, -6], dtype="<i2")
        fmt = struct.pack("<4sIHHIIHH", b"fmt ", 16, 1, 2, 44100, 44100 * 4, 4, 16)
        p = _tmp("m.wav")
        open(p, "wb").write(_build_wave(fmt, ints.tobytes(), rf64=True))
        got, info = wavio.read_wav_int(p)
        self.assertEqual((info.frames, info.channels), (3, 2))
        self.assertEqual(got.reshape(-1).tolist(), ints.tolist())

    def test_unknown_chunks_and_odd_padding_skipped(self):
        ints = np.array([7, 8], dtype="<i2")
        fmt = struct.pack("<4sIHHIIHH", b"fmt ", 16, 1, 1, 8000, 16000, 2, 16)
        junk = struct.pack("<4sI", b"LIST", 3) + b"abc" + b"\0"
        p = _tmp("n.wav")
        open(p, "wb").write(_build_wave(fmt, ints.tobytes(), extra=junk))
        got, _ = wavio.read_wav_int(p)
        self.assertEqual(got[:, 0].tolist(), [7, 8])

    def test_pcm32(self):
        ints = np.array([2 ** 31 - 1, -2 ** 31, 5], dtype="<i4")
        fmt = struct.pack("<4sIHHIIHH", b"fmt ", 16, 1, 1, 8000, 32000, 4, 32)
        p = _tmp("o.wav")
        open(p, "wb").write(_build_wave(fmt, ints.tobytes()))
        got, info = wavio.read_wav_int(p)
        self.assertEqual(info.bit_depth, 32)
        self.assertEqual(got[:, 0].tolist(), ints.tolist())

    def test_errors(self):
        p = _tmp("p.wav")
        open(p, "wb").write(b"not a wave file at all")
        with self.assertRaises(wavio.WavError):
            wavio.read_wav(p)
        fmt = struct.pack("<4sIHHIIHH", b"fmt ", 16, 85, 1, 8000, 16000, 2, 16)  # mp3 tag
        open(p, "wb").write(_build_wave(fmt, b"\0\0"))
        with self.assertRaises(wavio.WavError):
            wavio.read_wav(p)

    def test_info_without_reading(self):
        p = _tmp("q.wav")
        wavio.write_wav(p, np.zeros((12345, 2)), 44100, "pcm16")
        info = wavio.read_wav_info(p)
        self.assertEqual((info.frames, info.channels, info.sample_rate), (12345, 2, 44100))


if __name__ == "__main__":
    unittest.main()

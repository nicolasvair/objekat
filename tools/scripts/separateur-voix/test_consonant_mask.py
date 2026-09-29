#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Standalone test of the CONSONANTS block of the evaluation (`detect.sibilant_zones` — SS/CH and the
others, one set of settings —, its own hole filling and text criterion (near a WORD), the priority
rule, the independence of the two blocks) and of the panel the script declares — the twin of
`test_breath_mask.py`. No Whisper, no socket. Run with the venv's own python3:

    python3 test_consonant_mask.py
"""

import math
import sys

import numpy as np

import detect
import separateur_voix as sv
from test_detect import make_signal, SR, DURATION

FAILS = []


def check(label, ok, detail=""):
    if ok:
        print("ok    " + label)
    else:
        FAILS.append(label)
        print("FAIL  %s  %s" % (label, detail))


def make_voiced_fricative(buzz):
    """The synthetic voice plus a VOICED fricative ('z') at [2.45, 2.57]: the same 5-9 kHz noise as
    the 's', with a 140 Hz buzz added under it — `buzz` is its amplitude. At 0.1 the voicing score
    reads ~0.45 and the HF / LF ratio ~ +1 dB: a z as the historical detector could not keep."""
    sig = make_signal()
    rng = np.random.default_rng(5)
    n = int(round(0.12 * SR))
    i0 = int(round(2.45 * SR))
    t = np.arange(n) / SR
    noise = rng.standard_normal(n)
    sp = np.fft.rfft(noise)
    sp[(np.fft.rfftfreq(n, 1 / SR) < 5000) | (np.fft.rfftfreq(n, 1 / SR) > 9000)] = 0
    noise = np.fft.irfft(sp, n)
    noise = noise / np.max(np.abs(noise)) * 0.28
    tone = buzz * (np.sin(2 * np.pi * 140 * t) + 0.5 * np.sin(2 * np.pi * 280 * t))
    w = np.ones(n)
    e = int(n * 0.03)
    w[:e] = np.linspace(0, 1, e)
    w[-e:] = np.linspace(1, 0, e)
    sig[i0:i0 + n] = (noise + tone) * w
    return sig


def cov(regions):
    g = np.arange(0, DURATION, 0.001)
    m = np.zeros(g.shape, dtype=bool)
    for lo, hi in regions:
        m |= (g >= lo) & (g < hi)
    return m


sig = make_signal()
ef = detect.compute_eval_features(sig, SR)
hop = ef.hop_s


def sib(feats=None, **kw):
    """SS / CH alone (the breaths off), no text unless a `words` list is given."""
    values = {"b_on": False, "s_text_on": False}
    values.update({("s_" + k if k in ("fill_on", "fill", "text_on", "tolerance") else k): v for k, v in kw.items()})
    words = values.pop("words", None)
    if words is not None:
        values["s_text_on"] = True
    s = detect.EvalSettings.from_values(values)
    return detect.eval_zones(feats or ef, s, DURATION, words, values.pop("language", "fr"))["sibilant"]


def near(zone, lo, hi, tol=0.015):
    return abs(zone[0] - lo) < tol and abs(zone[1] - hi) < tol


# ── defaults, and the synthetic truth ──
d = detect.SibilantEval()
check("defaults: friction criteria ON, 'not voiced' OFF, hf/lf -6 dB, zcr 0.12, HF +10 dB, 30 ms, refine 12 dB",
      (d.unvoiced_on, d.hf_ratio_on, d.zcr_on, d.hf_energy_on, d.min_len_on, d.refine_on) == (False, True, True, True, True, True)
      and (d.hf_ratio, d.zcr, d.hf_energy, d.min_len, d.refine) == (-6.0, 0.12, 10.0, 30.0, 12.0))
zones = sib()
truth = [(0.40, 0.52), (1.80, 1.90), (2.10, 2.22)]
check("the two 's' and the 'ch' are found, edges within 15 ms: %s" % [(round(a, 3), round(b, 3)) for a, b in zones],
      len(zones) == 3 and all(near(z, *t) for z, t in zip(zones, truth)), zones)
check("the breath [1.20, 1.45] is NOT taken for a fricative", not any(1.1 < z[0] < 1.5 for z in zones))

# ── the voiced fricative: the known fault of the historical detector ──
zsig = make_voiced_fricative(0.1)
zf = detect.compute_eval_features(zsig, SR)
k = int(round(2.51 / hop))
check("the synthetic z is VOICED enough to matter (voicing %.2f, ratio %.1f dB, zcr %.2f)"
      % (zf.voicing[k], zf.hf_db[k] - zf.lf_db[k], zf.zcr[k]),
      zf.voicing[k] > 0.35 and (zf.hf_db[k] - zf.lf_db[k]) < 6.0)
kept = [z for z in sib(zf) if 2.4 < z[0] < 2.65]
check("with the defaults the voiced z IS found: %s" % kept, len(kept) == 1 and near(kept[0], 2.45, 2.57, 0.02), kept)
gone = [z for z in sib(zf, s_unvoiced_on=True, s_unvoiced=0.3) if 2.4 < z[0] < 2.65]
check("...and the optional 'not voiced' criterion (0.3) drops it again", gone == [], gone)
old = [z for z in sib(zf, s_hf_ratio=4.0) if 2.4 < z[0] < 2.65]
check("...as the historical +4 dB ratio would have (the z reads +1 dB)", old == [], old)
check("the unvoiced 's' survive the 'not voiced' criterion",
      len([z for z in sib(zf, s_unvoiced_on=True, s_unvoiced=0.3) if z[0] < 2.4]) == 3)

# ── each criterion, off, never REMOVES coverage; all off = the whole signal ──
bare = dict(s_min_len_on=False, s_refine_on=False, fill_on=False)
base = cov(sib(**bare))
for crit in ("s_hf_ratio", "s_zcr", "s_hf_energy"):
    off = cov(sib(**bare, **{crit + "_on": False}))
    check("switching '%s' off never removes coverage (%d -> %d ms)" % (crit, base.sum(), off.sum()),
          bool((off | ~base).all()))
off = cov(sib(**bare, s_unvoiced_on=True, s_unvoiced=0.3))
check("switching 'not voiced' ON never adds coverage", bool((base | ~off).all()))
allon = cov(sib(s_hf_ratio_on=False, s_zcr_on=False, s_hf_energy_on=False, **bare))
check("with every criterion off the zone is the whole signal", allon.all())

# raising a threshold never adds coverage
for name, values in (("s_hf_ratio", (-20, -6, 0, 6, 20)), ("s_zcr", (0.05, 0.12, 0.2, 0.3, 0.4)),
                     ("s_hf_energy", (0, 10, 20, 30))):
    cs = [cov(sib(**bare, **{name: float(v)})).sum() for v in values]
    check("raising '%s' never adds coverage %s" % (name, cs), cs == sorted(cs, reverse=True))
counts = [len(sib(s_min_len=float(m), s_refine_on=False, fill_on=False)) for m in (10, 30, 60, 100, 150)]
check("raising the minimum length never adds zones %s" % counts, counts == sorted(counts, reverse=True))
lens = [min(h - l for l, h in (sib(s_min_len=float(m), s_refine_on=False, fill_on=False) or [(0, 9)]))
        for m in (30, 100)]
check("every zone kept is at least the minimum length (before refinement) %s" % lens,
      lens[0] * 1000 >= 30 - 1e-6 and (lens[1] * 1000 >= 100 - 1e-6 or len(sib(s_min_len=100.0, s_refine_on=False)) == 0))

# ── the refinement onto the HF peak ──
raw = cov(sib(s_refine_on=False))
tight = cov(sib(s_refine_on=True, s_refine=6.0))
loose = cov(sib(s_refine_on=True, s_refine=30.0))
check("a refined zone lies inside the unrefined one, and a wider drop never shrinks it (%d <= %d <= %d ms)"
      % (tight.sum(), loose.sum(), raw.sum()),
      bool((raw | ~tight).all()) and bool((loose | ~tight).all()) and bool((raw | ~loose).all()))

# ── THE HOLE FILLING, on a hand-made grid (SS/CH side) ──
def hand_features(pattern):
    n = len(pattern)
    return detect.EvalFeatures(times=np.arange(n) * 0.0025, voicing=np.zeros(n),
                               lp_db=np.zeros((n, len(detect.EVAL_CUTOFFS)), dtype=np.float16),
                               cutoffs=detect.EVAL_CUTOFFS.copy(), hop_s=0.0025,
                               hf_db=np.full(n, -60.0, dtype=np.float32), lf_db=np.full(n, -60.0, dtype=np.float32),
                               zcr=np.where(np.array(pattern) == 1, 0.3, 0.0).astype(np.float32))


def two(hole_frames, **kw):
    pat = [0] * 20 + [1] * 40 + [0] * hole_frames + [1] * 40 + [0] * 20
    f = hand_features(pat)
    values = {"b_on": False, "s_text_on": False, "s_hf_ratio_on": False, "s_hf_energy_on": False,
              "s_min_len_on": False, "s_refine_on": False, **{('s_' + k if k in ('fill_on', 'fill') else k): v for k, v in kw.items()}}
    return detect.eval_zones(f, detect.EvalSettings.from_values(values), len(pat) * 0.0025, None, "fr")["sibilant"]


check("hole filling: a 15 ms hole is bridged at 20 ms, and at exactly 15 ms",
      len(two(6, fill_on=True, fill=20)) == 1 and len(two(6, fill_on=True, fill=15)) == 1)
check("hole filling: a 30 ms hole stays open at 20 ms; a 15 ms one at 12.5 ms; nothing bridged with the box off",
      len(two(12, fill_on=True, fill=20)) == 2 and len(two(6, fill_on=True, fill=12.5)) == 2
      and len(two(6, fill_on=False, fill=100)) == 2)
check("...the hole filling is EACH block's own: the panel has b_fill and s_fill, and no shared 'fill'",
      sorted(c["id"] for c in sv.panel_controls("en", {m: m for m in sv.tr.MODEL_IDS}) if c["id"].endswith("fill"))
      == ["b_fill", "s_fill"])
n_off = len(sib(fill_on=False))
n_on = len(sib(fill_on=True, fill=100))
check("on the real signal the filling only ever merges zones (%d -> %d)" % (n_off, n_on), n_on <= n_off)

# ── THE TEXT: a zone is kept only within the tolerance of a WORD (no spelling filter) ──
from test_detect import WORDS
check("with the words of the synthetic voice, the three zones stay (each sits in a word)",
      len(sib(words=WORDS, tolerance=50)) == 3, sib(words=WORDS, tolerance=50))
plain = [{"word": "ta", "start": 0.35, "end": 0.65}, {"word": "toto", "start": 1.7, "end": 2.3}]
check("NO spelling filter: 'ta' (no s, no ch) keeps the zone it wraps; a word lying elsewhere keeps none",
      len(sib(words=plain[:1], tolerance=50)) >= 1 and len(sib(words=plain[:1], tolerance=50)) < 3
      and sib(words=[{"word": "ta", "start": 2.9, "end": 2.95}], tolerance=50) == [])
check("no word at all... is 'no text', not 'no place': nothing dropped",
      len(sib(words=[])) == 3)
one = [{"word": "sa", "start": 0.38, "end": 0.62}]
check("one word with an 's' wrapping the first zone: only that zone at 50 ms (%s)" % sib(words=one, tolerance=50),
      len(sib(words=one, tolerance=50)) == 1 and near(sib(words=one, tolerance=50)[0], 0.40, 0.52))
far = [{"word": "sa", "start": 0.90, "end": 1.00}]      # any word: the spelling is not read
check("a zone 380 ms from the word: dropped at 300 ms, kept at 400 ms",
      len(sib(words=far, tolerance=300)) == 0 and len(sib(words=far, tolerance=400)) == 1)
check("text OFF, or no words at all, changes nothing",
      len(sib(text_on=False)) == 3 and len(sib(words=None)) == 3)

# ── the priority between categories: SS/CH wins ──
loose_b = {"b_unvoiced_on": False, "b_below_speech_on": False, "b_text_on": False, "s_text_on": False}
both = detect.eval_zones(ef, detect.EvalSettings.from_values(loose_b), DURATION, None, "fr")
check("the categories never overlap, SS/CH keeps its whole zone",
      not (cov(both["breath"]) & cov(both["sibilant"])).any() and both["sibilant"] == zones)
check("a breath remnant shorter than the breath minimum is dropped with the overlap (all >= 120 ms)",
      all((h - l) * 1000 >= 120 - 1e-6 for l, h in both["breath"]), both["breath"])
short_min = detect.eval_zones(ef, detect.EvalSettings.from_values({**loose_b, "b_min_len_on": False}), DURATION, None, "fr")
check("...with the minimum off the remnants stay", len(short_min["breath"]) >= len(both["breath"]))

# ── the panel the script declares ──
labels = {m: m for m in sv.tr.MODEL_IDS}
for lang in ("fr", "en", "es"):
    controls = sv.panel_controls(lang, labels)
    ids = [c["id"] for c in controls]
    check("panel (%s): unique ids, every enabled_by names a bool, kinds are known" % lang,
          len(ids) == len(set(ids))
          and all(c.get("enabled_by") is None or next(x for x in controls if x["id"] == c["enabled_by"])["kind"] == "bool"
                  for c in controls)
          and {c["kind"] for c in controls} <= {"bool", "number", "choice", "progress", "section"})
controls = sv.panel_controls("en", labels)
byid = {c["id"]: c for c in controls}
check("panel: global model + progress, then two blocks — breaths, consonants",
      [c["id"] for c in controls if c["kind"] == "section"] == ["sec_breath", "sec_sib"]
      and ids.index("model") < ids.index("progress") < ids.index("sec_breath") < ids.index("b_unvoiced") < ids.index("sec_sib") < ids.index("s_zcr"))
check("panel: a progress bar, indeterminate at the start", byid["progress"]["kind"] == "progress" and byid["progress"]["value"] is None)
expected = {  # id: (min, max, default)
    "b_unvoiced": (0.2, 0.6, 0.4), "b_below_speech": (3, 15, 10), "b_cutoff": (100, 1000, 200),
    "b_min_len": (80, 200, 120), "b_fill": (0, 100, 20), "b_tolerance": (50, 800, 500),
    "s_fill": (0, 100, 20), "s_tolerance": (50, 800, 500),
    "s_unvoiced": (0.3, 0.9, 0.7), "s_hf_ratio": (-20, 20, -6), "s_zcr": (0.05, 0.4, 0.12),
    "s_hf_energy": (0, 30, 10), "s_min_len": (10, 150, 30), "s_refine": (3, 30, 12)}
check("panel: every slider's range and default are the ones decided",
      all((byid[i]["min"], byid[i]["max"], byid[i]["value"]) == e for i, e in expected.items()),
      {i: (byid[i]["min"], byid[i]["max"], byid[i]["value"]) for i in expected})
check("panel: no end-margin control any more", not any("margin" in c["id"] for c in controls))
values = {c["id"]: c["value"] for c in controls if c["kind"] in ("bool", "number")}
check("panel defaults == the dataclass defaults (a panel left alone detects with the tested defaults)",
      detect.EvalSettings.from_values(values) == detect.EvalSettings(detect.BreathEval(), detect.SibilantEval()))
check("panel: the default model is Whisper + alignment when it is installed (else the next best)",
      byid["model"]["value"] == "align" and [o["id"] for o in byid["model"]["options"]] == list(sv.tr.MODEL_IDS))
check("panel: Parakeet says it is for English (fr / en / es)",
      "anglais" in sv.panel_text("fr")["models"]["parakeet"]
      and "English" in sv.panel_text("en")["models"]["parakeet"] and "inglés" in sv.panel_text("es")["models"]["parakeet"])
check("lanes: only the categories that are ON get one",
      sv.eval_lanes(detect.EvalSettings.from_values({})) == {"voice": 0, "breath": 1, "sibilant": 2}
      and sv.eval_lanes(detect.EvalSettings.from_values({"b_on": False})) == {"voice": 0, "sibilant": 1}
      and sv.eval_lanes(detect.EvalSettings.from_values({"s_on": False})) == {"voice": 0, "breath": 1}
      and sv.eval_lanes(detect.EvalSettings.from_values({"b_on": False, "s_on": False})) == {"voice": 0})

# ── INDEPENDENCE: a setting of one block never moves the other block's zones ──
words_i = [{"word": "sa", "start": 0.38, "end": 0.62}, {"word": "la", "start": 1.6, "end": 1.9}]
def both_blocks(**kw):
    return detect.eval_zones(ef, detect.EvalSettings.from_values(kw), DURATION, words_i, "fr")
ref = both_blocks()
for k, v in (("b_tolerance", 50), ("b_text_on", False), ("b_fill", 0), ("b_unvoiced", 0.6), ("b_min_len", 200),
             ("b_cutoff", 500), ("b_below_speech", 4)):
    check("breath setting %s=%s leaves the consonant zones untouched" % (k, v),
          both_blocks(**{k: v})["sibilant"] == ref["sibilant"])
alone = both_blocks(s_on=False)["breath"]
for k, v in (("s_tolerance", 50), ("s_text_on", False), ("s_fill", 0), ("s_zcr", 0.3), ("s_min_len", 150),
             ("s_refine", 3), ("s_hf_energy", 30)):
    z = both_blocks(**{k: v})
    # the consonants' own tolerance / filling / criteria never touch the breaths beyond the priority rule:
    # the breath zones are exactly the breath-alone zones with this block's zones cut out
    want = detect.subtract_zones(alone, z["sibilant"])
    want = [x for x in want if (x[1] - x[0]) * 1000.0 >= 120 - 1e-6]
    check("consonant setting %s=%s changes the breaths only through the priority rule" % (k, v),
          [(round(a, 6), round(b, 6)) for a, b in z["breath"]] == [(round(a, 6), round(b, 6)) for a, b in want])
tight = both_blocks(b_tolerance=50, s_tolerance=800)
check("tolerances are per block: 50 ms on the breaths, 800 ms on the consonants at once",
      tight["sibilant"] == both_blocks(s_tolerance=800)["sibilant"]
      and tight["sibilant"] != both_blocks(s_tolerance=50)["sibilant"])

print()
if FAILS:
    print("%d FAILED" % len(FAILS))
    sys.exit(1)
print("ALL PASS")

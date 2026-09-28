# Voice separator

An OBJEKAT third-party script (@see `plan_separateur_voix.md`, the architecture decisions
`D1`-`D6`). Right-click a spoken audio clip → **Scripts → "Separate voice / breaths / SS-CH"**.

It cuts the clip — no sound changed, nothing re-rendered — into a new group on the object's own
lane, with three sub-lanes: **Voice**, **Breaths**, **SS/CH**. The boundaries come from Whisper's
own word timestamps (a rough guide to WHERE) refined against the file's own energy/spectrum at
10 ms resolution (WHICH kind of sound, and exactly where it starts/ends) — no forced aligner, no
Kaldi, no conda: the precision a phonetic aligner buys is not needed here, since separating does
not correct anything — a boundary a few milliseconds off does not change what is heard, the pieces
stay jointive.

## Evaluate breaths (interactive)

Right-click the object → Scripts → **Evaluate breaths…** opens a small floating panel and lays the
breaths the detector finds over the object as white zones (and, with Whisper, the words over the
block). Move a setting and the zones follow — nothing is cut, nothing is in the undo history. **Apply**
then cuts exactly what is shown (a group with two sub-lanes, Voice and Breaths, one undo); **Cancel**,
the window's ✕ or the script dying leave the project untouched.

Each criterion is a checkbox and a slider; an unchecked box drops the criterion out of the rule
(the slider greys). A breath is a stretch of frames where ALL the checked criteria hold:

| setting | default | meaning |
|---|---|---|
| Gap between words ≥ | 120 ms | only look in the spaces Whisper leaves between words at least this long (off = anywhere; no effect with `--no-asr`) |
| Voicing < | 0.45 | the autocorrelation score under which a frame counts as unvoiced |
| Energy > floor + | 6 dB | louder than the file's noise floor (its 5th percentile) by at least this |
| Energy < speech − | 10 dB | quieter than the median of the voiced frames by at least this |
| Flatness > | 0.08 | how noise-like the 300–4000 Hz band is (1 = white noise) |
| Highs/lows < | 6 dB | 4–10 kHz over 80 Hz–1 kHz: under this it is not a sibilant |
| Length ≥ | 80 ms | the shortest run kept (off = 0) |
| Fill holes | 20 ms | a hole this short inside a run is bridged (off = 0) |
| End margin | 15 ms | kept clear before the next word (off = 0) |

The analysis (Whisper + features) is cached under `~/Library/Caches/Objekat/separateur-voix/` —
keyed on the file (path, modification time, size), the portion played, the language and the model —
so re-opening the panel on the same object is instant; moving a setting only re-runs a mask over
the cached features (a few milliseconds for ten minutes of audio).

Same refusals as the other entry (not a clip, missing file, looping, changed speed, reversed).
Command line: `OBJEKAT_SOCKET=… python3 separateur_voix.py --breaths-eval --object <uuid> [--no-asr] [--lang fr|en|es]`.

## Install

```
./install.sh
```

Creates a dedicated venv (`~/Library/Application Support/Objekat/venvs/separateur-voix`), installs
`mlx-whisper`/`numpy`/`scipy`/`soundfile`, pre-downloads the `mlx-community/whisper-large-v3-turbo`
model, and symlinks this folder into OBJEKAT's own `Plugins/` directory. Apple Silicon only
(`mlx-whisper`). Reload the scripts in OBJEKAT afterwards (Scripts menu → Reload, or relaunch).

## Use

Right-click the object → Scripts → Separate voice / breaths / SS-CH. Refused, with a clear reason
on stderr (surfaced by OBJEKAT as a notification): not an audio clip, missing source file, a
looping object, a changed speed, or reversed playback — none of these leave the file positions
Whisper reports lined up with what `object.explode` would cut.

## Command line (debugging / testing)

```
OBJEKAT_SOCKET=/tmp/objekat.sock OBJEKAT_OBJECT_IDS=<uuid> python3 separateur_voix.py --dry-run
OBJEKAT_SOCKET=... OBJEKAT_OBJECT_IDS=<uuid> python3 separateur_voix.py --no-asr
OBJEKAT_SOCKET=... OBJEKAT_OBJECT_IDS=<uuid> python3 separateur_voix.py --segments-json segs.json
```

- `--lang fr|en|es` — forces the language (default: `OBJEKAT_LANGUAGE`, the app's own UI language).
- `--no-asr` — skips Whisper, acoustic criteria alone (wider tolerance; also the fallback path).
- `--segments-json <file>` — short-circuits detection entirely: a JSON array of
  `{"start": …, "duration": …, "label": "voice"|"breath"|"sibilant"}`, used by
  `tools/scenario_voice_split.py` to drive `object.explode` deterministically.
- `--dry-run` — prints the detected segments, calls no command that changes the project.

## Tests

`test_detect.py` — the pure detection module (`detect.py`) against a synthetic signal, no Whisper,
no socket:

```
<venv>/bin/python3 test_detect.py
<venv>/bin/python3 test_breath_mask.py    # vectorised features == the old loops; breath_mask; the cache
```

`tools/scenario_breath_eval.py <socket>` (headless instance) drives the app side and this script
end to end: the sample-exact cut, the overlay, the panel, Apply / Cancel / a killed script.

## Licences

`mlx-whisper` (MIT), the Whisper model weights (MIT), `numpy`/`scipy` (BSD), `soundfile` (BSD;
links `libsndfile`, LGPL, dynamically, outside the app) — all AGPLv3-compatible. Nothing here is
embedded in the OBJEKAT bundle; the venv lives entirely under Application Support.

## Not verified

@see CLAUDE.md's entry for this script and `validations-en-attente.md`: no real recording has
been run through Whisper by this session, the panel and the zones have never been seen on screen, no separated piece has been listened to, and the
context-menu entry has not been seen on screen in any of the three languages.

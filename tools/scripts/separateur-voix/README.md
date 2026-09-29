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
zones the detector finds over the object as white areas. Move a setting and the zones follow —
nothing is cut, nothing is in the undo history. **Apply** then cuts exactly what is shown (a group
with two sub-lanes, Voice and Breaths, one undo); **Cancel**, the window's ✕ or the script dying
leave the project untouched.

**Four criteria**, each a checkbox and a slider (an unchecked box drops the criterion; the slider
greys). A zone is a run of frames where ALL the checked frame criteria hold. No word, no floor, no
flatness: the words are only displayed.

| setting | default | meaning |
|---|---|---|
| Voicing < | 0.45 | a frame is excluded when its voicing score (autocorrelation, 25 ms window) is above this |
| Energy < speech − | 10 dB | the frame's energy, **measured after a low-pass**, is at least this far under the speech level — the median of the voiced frames, measured the same way |
| Low-pass cutoff | 6000 Hz (100–8000) | the low-pass both energies are measured after; greyed with the energy box |
| Minimum length | 80 ms | the shortest zone kept |
| Margin before voice | 5 ms | a zone stops this long before the FIRST VOICED FRAME that follows it |

**Temporal precision.** The frames sit on a 2.5 ms grid, centred on their instant, and the energy is
read on a 12 ms window (the voicing needs its 25 ms one). The low-pass is not a filter run over the
audio: it is a cumulative sum over each frame's own spectrum, stored for every 100 Hz cutoff, so
moving the cutoff costs nothing and refilters nothing. On the synthetic test signal the edges of a
250 ms breath land within 4 ms; the analysis is ~0.7 s per minute of audio and 19 MB per ten minutes
in the cache; moving a slider re-runs in ~7 ms for ten minutes of audio.

**Why 6 kHz.** On a French `say -v Thomas` voice with four real pauses, cutoffs up to 3 kHz flagged
13 zones (the unvoiced consonants — *ch*, *ss* — are quiet under a low-pass and pass for breaths);
from 6 kHz the fricatives' own energy is counted as speech and the zones fall to the pauses
themselves (5). Lower it if a real breath is being missed. Note that silence is ALSO a zone here:
nothing in these four criteria distinguishes a pause from a breath.

**Text shown** (a choice in the panel — display only, the detection never reads it): None, or a
model whose words are laid over the block, to compare their timing:

| model | what | licences (code / weights) |
|---|---|---|
| Whisper large-v3-turbo (mlx) | installed by default | MIT / MIT |
| Parakeet TDT v3 (`parakeet-mlx`) | a token-timed transducer; a subprocess of the same venv (`parakeet_worker.py`, no ffmpeg needed) | Apache-2.0 / CC-BY-4.0 |
| Whisper + wav2vec2 alignment | Whisper's text re-timed by forced CTC alignment against `jonatasgrosman/wav2vec2-large-xlsr-53-{french,english,spanish}` (numpy Viterbi, no torchaudio, no WhisperX) | Apache-2.0 / Apache-2.0 |

Choosing a model transcribes in the BACKGROUND (the panel stays live; the status line says
"transcribing…", then the word count and the time taken); each model's words are cached on disk
under their own key, so going back to one is instant. A model that is not installed is labelled so
in the menu and in the status line — nothing crashes.

The features are cached under `~/Library/Caches/Objekat/separateur-voix/` — keyed on the file
(path, modification time, size) and the portion played, never on a model.

Same refusals as the other entry (not a clip, missing file, looping, changed speed, reversed).
Command line: `OBJEKAT_SOCKET=… python3 separateur_voix.py --breaths-eval --object <uuid> [--model none|whisper|parakeet|align] [--lang fr|en|es]`.

## Install

```
./install.sh
```

Creates a dedicated venv (`~/Library/Application Support/Objekat/venvs/separateur-voix`), installs
`mlx-whisper`/`numpy`/`scipy`/`soundfile`, pre-downloads the `mlx-community/whisper-large-v3-turbo`
model, and symlinks this folder into OBJEKAT's own `Plugins/` directory. Apple Silicon only
(`mlx-whisper`). Reload the scripts in OBJEKAT afterwards (Scripts menu → Reload, or relaunch).

ONE venv for everything, on a Python ≥ 3.10 that `install.sh` finds by itself (PATH, then
Homebrew's prefixes) — macOS's own 3.9 cannot host `parakeet-mlx`; with none found it says
`brew install python@3.12`, and a venv left on 3.9 by an older install is rebuilt.
Two heavy models are opt-in, for the text comparison: `./install.sh --with-align` (adds `torch` and
`transformers`, downloads the wav2vec2 model of each language in `ALIGN_LANGS`, default `fr`, ~1.3 GB
each) and `./install.sh --with-parakeet` (`parakeet-mlx` plus ~2.5 GB of weights). Either is
SKIPPED with a message when the disk lacks room.

First comparison (Thomas's `say` voice, 12 s, 27 words, two 1.4 s pauses, no ground truth; Whisper /
Parakeet / alignment: transcription 4.1 / 4.1 / 17.1 s cold, 1.4 / 1.8 / 2.5 s warm). At the first
pause (energy silence 3.44–4.82 s) the last word ends at 3.36 / 4.00 / 3.42 s and the next begins at
4.44 / 4.64 / 4.90 s: the alignment is the tightest on both edges, Whisper starts words early, and
Parakeet's tokens stretch over the silence (its word ends run late).

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
<venv>/bin/python3 test_breath_mask.py    # vectorised features == the old loops; the eval grid, its four criteria, the low-pass, the margin; CTC alignment; the caches
```

`tools/scenario_breath_eval.py <socket>` (headless instance) drives the app side and this script
end to end: the sample-exact cut, the overlay, the panel (including the `choice` control), Apply / Cancel / a killed script.

## Licences

`mlx-whisper` (MIT), the Whisper model weights (MIT), `numpy`/`scipy` (BSD), optionally `parakeet-mlx` (Apache-2.0) with the Parakeet weights (CC-BY-4.0, attribution: NVIDIA) and `transformers` (Apache-2.0) with the wav2vec2 weights (Apache-2.0), `soundfile` (BSD;
links `libsndfile`, LGPL, dynamically, outside the app) — all AGPLv3-compatible. Nothing here is
embedded in the OBJEKAT bundle; the venv lives entirely under Application Support.

## Not verified

@see CLAUDE.md's entry for this script and `validations-en-attente.md`: no real recording has
been run through Whisper by this session, the panel and the zones have never been seen on screen, no separated piece has been listened to, and the
context-menu entry has not been seen on screen in any of the three languages.

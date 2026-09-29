# Voice separator

An OBJEKAT third-party script (@see `plan_separateur_voix.md`, the architecture decisions
`D1`-`D6`). Right-click a spoken audio clip → **Scripts → "Separate voice / breaths / consonants…"** (the direct, no-panel entry was removed: the panel below is the only menu entry).

It cuts the clip — no sound changed, nothing re-rendered — into a new group on the object's own
lane, with three sub-lanes: **Voice**, **Breaths**, **Consonants**. The boundaries come from Whisper's
own word timestamps (a rough guide to WHERE) refined against the file's own energy/spectrum at
10 ms resolution (WHICH kind of sound, and exactly where it starts/ends) — no forced aligner, no
Kaldi, no conda: the precision a phonetic aligner buys is not needed here, since separating does
not correct anything — a boundary a few milliseconds off does not change what is heard, the pieces
stay jointive.

## The panel (the only entry)

Right-click the object → Scripts → **Separate voice / breaths / consonants…** opens a floating panel and lays the
zones the detector finds over the object: **breaths in white, consonants (SS/CH and others) in yellow**. Move a setting and
the zones follow — nothing is cut, nothing is in the undo history. **Apply** then cuts exactly what is
shown (a group with one sub-lane per block that is ON — Voice, Breaths, Consonants — one undo);
**Cancel**, the window's ✕ or the script dying leave the project untouched.

Every criterion is a checkbox and a value (an unchecked box drops the criterion from the conjunction
and greys the value). A zone is a run of frames where ALL the checked frame criteria hold.

**The panel** — what a first use needs: **Create groups** (checked by default: each category's pieces
are gathered into a group of its own — Voice / Breaths / Consonants — so the result is three blocks
and not hundreds, which the timeline can draw at a decent frame rate), the **spoken language**
(defaults to the interface language, remembered with the rest), the text model and the progress bar.
Everything below is a detection setting, hidden behind the **Expert** button. Then TWO fully independent blocks. Each block owns everything it detects with — its
criteria, hole filling, minimum length, text box and tolerance — and nothing is shared between them.

| block | control | range | default | meaning |
|---|---|---|---|---|
| Global | Text (model) | menu | Whisper + alignment (else Whisper, else none) | the words, displayed AND usable by each block's text criterion; *Parakeet is labelled "English"* |
| | progress bar | — | — | the signal analysis, then the transcription |
| Breaths | Detect breaths | box | on | |
| | Voicing < | 0.2–0.6 | 0.4 | a frame is a candidate when its voicing score (autocorrelation, 25 ms window) is at most this |
| | Energy under speech · gap | 3–15 dB | 10 | the frame's energy, **measured after a low-pass**, is at least this far under the speech level (median of the voiced frames, measured the same way) |
| | · low-pass | 100–1000 Hz | 200 | the low-pass both energies are measured after; greyed with the energy box |
| | Minimum length | 80–200 ms | 120 | the shortest zone kept |
| | Hole filling | 0–100 ms | on · 20 | a hole of candidate frames this short or shorter, between two candidate stretches, is bridged |
| | Use the text · Tolerance | 50–800 ms | on · 100 | @see "The text" below |
| Consonants (SS/CH and others) | Detect consonants | box | on | ONE set of settings for s, ch, z, j, f, v, plosive bursts… — no sub-category, no per-sound setting |
| | Not voiced (voicing <) | 0.3–0.9 | **off** · 0.7 | optional, and OFF: z, j and v are voiced and a voicing ceiling drops them (the historical detector's known fault) |
| | High / low > | −20…+20 dB | −6 | energy 4–10 kHz over energy 80 Hz–1 kHz. Negative on purpose: a voiced z has its voicebar in the low band and reads −3 to −5 dB (an s reads +30); vowels read −15 to −35 and are kept out by the next criterion |
| | Zero crossings > | 0.05–0.4 | 0.12 | crossings per sample: noise at 5–9 kHz is 0.25–0.3, a vowel is 0.02–0.05 |
| | HF energy > floor + | 0–30 dB | 10 | the 4–10 kHz energy above its own 5th percentile |
| | Minimum length | 10–150 ms | 30 | |
| | Refine on the HF peak (−) | 3–30 dB | 12 | each zone is tightened onto the frames within this of its own HF peak (applied after the minimum length) |
| | Hole filling | 0–100 ms | on · 20 | as above, this block's own |
| | Use the text · Tolerance | 50–800 ms | on · 100 | @see "The text" below |

Control ids: `b_…` for the breaths, `s_…` for the consonants (the historical SS/CH prefix, kept), so
`b_fill` / `s_fill`, `b_tolerance` / `s_tolerance`, and so on; only `model` and `progress` are bare.

The end margin the breaths used to have is gone.

**The text.** With a block's *Use the text* checked and a model's words available (none selected, still
transcribing or failed: no effect at all), a candidate zone of THAT block is kept only when it lies
within THAT block's *Tolerance* of a place the text allows it — distance 0 when it overlaps:

- a **breath** — of a **gap between two words** (also before the first word and after the last one;
  any gap over 1 ms). A model whose words run into each other (Parakeet stretches word ends over the
  silence) leaves few gaps, so its text filters breaths hard;
- a **consonant** — of a **word** (any word: no spelling filter, since the block covers s, ch, z, f, v,
  bursts… and a grapheme table could never name them all; the signal criteria still have to fire).
  What the text removes here is friction lying in a silence, far from any speech.

At 500 ms the criterion is loose (the words' own timing is loose: tens to hundreds of ms);
tighten it to make the text bite.

**Overlap between the blocks — the ONLY coupling: Consonants win.** A breath is defined by what it lacks (voicing, low
energy) and a fricative lacks the same things; a fricative is defined by what it HAS (a high-frequency
excess, fast zero crossings), which a breath does not — so the better evidence sits on that side. The
overlap is taken out of the breath zone (which may split in two), and a remnant shorter than the
breath minimum length goes with it.

**Progress bar** (the panel's `progress` control): the signal analysis reports per chunk of frames
(real). For the transcription, what each model gives:

| model | progress |
|---|---|
| Whisper (mlx) | real, but coarse: `mlx_whisper` counts mel frames per **30 s window**, so a file under 30 s is indeterminate then jumps to 100 %; a 10-minute file moves 20 times |
| Parakeet | indeterminate for a file up to 2 min (one pass, ~2 s); beyond it the worker transcribes in 2-min chunks (15 s overlap) and reports per chunk |
| Whisper + alignment | Whisper's share (35 %, as above), an indeterminate stretch while the wav2vec2 model loads, then per **segment** (one forward pass each) |

**Temporal precision.** The frames sit on a 2.5 ms grid, centred on their instant, and the energies
are read on a 12 ms window (the voicing needs its 25 ms one). The low-pass is a classic filter run
over the audio: a Butterworth of order 4, applied forwards then backwards (`sosfiltfilt`, zero phase,
so it adds no delay and an edge stays at its instant), on the signal with its DC offset removed and
resampled to 4 kHz. It is computed once per 100 Hz cutoff (100–1000 Hz) at analysis time (~2 s for
ten minutes), so moving the cutoff refilters nothing. Being a real filter it RINGS: the lower the
cutoff, the longer its impulse response, so a 100 Hz low-pass smears an edge by a few tens of ms where
1 kHz barely does. The HF / LF energies and the zero-crossing rate still come from each frame's own
spectrum. On the synthetic test signal the edges of a 250 ms breath and of the
`s` / `ch` land within 10 ms; the analysis is ~0.7 s per minute of audio and ~35 MB per ten minutes in
the cache; moving a slider re-runs both blocks in ~30 ms for ten minutes.

**Note.** Silence is ALSO a breath zone here: nothing in the breath criteria distinguishes a pause
from a breath. The Consonants block picks up every frication and burst (s, ch, z, j, f, v, plosives): high zero
crossings, high HF — it is one block on purpose.

**Text shown / used** (a choice in the panel): None, or a model whose words are laid over the block:

| model | what | licences (code / weights) |
|---|---|---|
| Whisper large-v3-turbo (mlx) | installed by default | MIT / MIT |
| Parakeet TDT v3 (`parakeet-mlx`) | a token-timed transducer, **for English** (v3 is multilingual but this is the tested use); a subprocess of the same venv (`parakeet_worker.py`, no ffmpeg needed) | Apache-2.0 / CC-BY-4.0 |
| Whisper + wav2vec2 alignment | Whisper's text re-timed by forced CTC alignment against `jonatasgrosman/wav2vec2-large-xlsr-53-{french,english,spanish}` (numpy Viterbi, no torchaudio, no WhisperX) | Apache-2.0 / Apache-2.0 |

Choosing a model transcribes in the BACKGROUND (the panel stays live; the status line says
"transcribing…", then the word count and the time taken); each model's words are cached on disk
under their own key, so going back to one is instant. A model that is not installed is labelled so
in the menu and in the status line — nothing crashes.

The features are cached under `~/Library/Caches/Objekat/separateur-voix/` — keyed on the file
(path, modification time, size) and the portion played, never on a model.

Same refusals as the other entry (not a clip, missing file, looping, changed speed, reversed).
Command line: `OBJEKAT_SOCKET=… python3 separateur_voix.py --eval-separation --object <uuid> [--model none|whisper|parakeet|align] [--lang fr|en|es]` (`--breaths-eval` is the old name and still works).

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

Right-click the object → Scripts → Separate voice / breaths / consonants… (the sub-lanes read Voice / Breaths / Consonants). Refused, with a clear reason
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

## The panel remembers

The evaluation panel is opened with `remember: "separateur-voix.eval"`: the app keeps the values
last **validated** (never on Cancel) and starts the next opening on them; its **Reset** button
returns every control to the values `panel_controls` declares. Generic, app side — the script
stores nothing (`command_api.md`, "A panel that remembers"). A remembered `model` wins over the
`--no-asr` / `--model` initial choice.

## Tests

`test_detect.py` — the pure detection module (`detect.py`) against a synthetic signal, no Whisper,
no socket:

```
<venv>/bin/python3 test_detect.py
<venv>/bin/python3 test_breath_mask.py    # vectorised features == the old loops; the eval grid, the breath criteria, the low-pass, the hole filling, the text, the priority; CTC alignment; the caches
<venv>/bin/python3 test_consonant_mask.py  # consonant criteria (incl. a voiced z), refinement, the text near a word, the panel's ranges and defaults, the independence of the two blocks
```

`tools/scenario_breath_eval.py <socket>` (headless instance) drives the app side and this script
end to end: the sample-exact cut, the overlay, the panel (`choice`, `progress`, `section`), both blocks, the hole filling seen in the overlay, Apply on 3 / 2 lanes, Cancel / a killed script, and a real `say -v Thomas` pass with a transcription model.

## Licences

`mlx-whisper` (MIT), the Whisper model weights (MIT), `numpy`/`scipy` (BSD), optionally `parakeet-mlx` (Apache-2.0) with the Parakeet weights (CC-BY-4.0, attribution: NVIDIA) and `transformers` (Apache-2.0) with the wav2vec2 weights (Apache-2.0), `soundfile` (BSD;
links `libsndfile`, LGPL, dynamically, outside the app) — all AGPLv3-compatible. Nothing here is
embedded in the OBJEKAT bundle; the venv lives entirely under Application Support.

## Not verified

@see CLAUDE.md's entry for this script and `validations-en-attente.md`: no real recording has
been run through Whisper by this session, the panel and the zones have never been seen on screen, no separated piece has been listened to, and the
context-menu entry has not been seen on screen in any of the three languages.

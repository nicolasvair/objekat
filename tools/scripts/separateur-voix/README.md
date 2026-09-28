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
```

## Licences

`mlx-whisper` (MIT), the Whisper model weights (MIT), `numpy`/`scipy` (BSD), `soundfile` (BSD;
links `libsndfile`, LGPL, dynamically, outside the app) — all AGPLv3-compatible. Nothing here is
embedded in the OBJEKAT bundle; the venv lives entirely under Application Support.

## Not verified

@see CLAUDE.md's entry for this script and `validations-en-attente.md`: no real recording has
been run through Whisper by this session, no separated piece has been listened to, and the
context-menu entry has not been seen on screen in any of the three languages.

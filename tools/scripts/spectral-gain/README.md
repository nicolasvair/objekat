# Spectral gain

An OBJEKAT third-party script (spec: `OBJEKAT - claude project/docs/spec_spectral_editor.md`,
technical plan: `plan_spectral_gain.md`, same folder). Right-click ONE object → **Scripts → "Spectral
edit…"**.

It opens a floating window with the **spectrogram** of the object (logarithmic frequency axis), lets
the hand **attenuate — or boost — regions of time × frequency**, lets the ear compare, and brings the
result back into the session. In the spirit of iZotope RX, restricted to **gain**: no spectral repair,
no de-noise, no pitch editing.

The script computes everything (numpy only); the window, the gestures, the history and the playback
belong to the app (`script.canvas.*`, `command_api.md`). The app knows nothing about FFTs or dB.

## Install

```
tools/scripts/spectral-gain/install.sh
```

Creates a venv at `~/Library/Application Support/Objekat/venvs/spectral-gain`, installs numpy in it
(no model, no download beyond numpy), and symlinks this folder into
`~/Library/Application Support/Objekat/Plugins/spectral-gain`. Then **reload the scripts** in OBJEKAT
(Scripts menu → Reload) or relaunch the app.

## Use

1. Right-click one object (a clip, or a group) → **Scripts → Spectral
   edit…**. The object is **rendered** exactly as `retouche-externe` renders it: its own plugins,
   gain, pan, fades, window and speed (a group's content included), and nothing around it (no parent
   chain, no master, no sends).
2. The window shows the spectrogram. Tools:
   - **Rectangle**: drag a box over time × frequency. Side bar: **Gain** (−60…+12 dB, default −12),
     **feather in time** (ms) and **in frequency** (semitones) so a box does not ring.
   - **Eraser**: draw over the picture; each pass takes away **Amount** dB (default −3), with a
     **Size** (screen pixels, stored in time × frequency so zooming does not change its meaning) and a
     **Hardness**. Cumulative like a spray can in negative: crossing a place again attenuates it again;
     a hand held still deposits nothing.
   - Everything is cumulative (gains in dB add up), one operation = one history step.
   - A cyan veil shows where the signal is attenuated, a green one where it is boosted.
3. Listen, independently of the project transport: **play/stop** from the clicked point, **A/B**
   between the original and the result at the same position, **Delta** to hear only what the operations
   take away. ⌘Z / ⇧⌘Z walk the history (the window's own; nothing reaches the project's undo stack
   before Validate).
4. **Expert** (side bar): FFT size (1024…32768, default 2048) and overlap (2…10, default 4). Changing
   them recomputes the picture and the preview; the operations made are kept (they are stored in
   seconds and Hz, not in bins).
5. **Validate** writes the result as a wav, lays it on a **new row at the same instant** (inside the
   same group if there is one), named **"<name> (spectral)"**, and **mutes the original** (it is not
   deleted). ONE project undo step takes it all back. **Cancel** (or closing the window) leaves the
   session untouched.

## What comes back

- **Sample rate and bit depth of the edited object's source file**: 16-bit → 16-bit, 24-bit → 24-bit,
  32-bit float → float; anything else (mp3, aac, 32-bit integer…) → 24-bit. A group whose files differ in
  rate asks which one to use (Cancel stops before any render); a group mixing depths takes the highest.
- **Channels follow the render**: a render whose two channels are identical sample for sample is written
  **mono**, otherwise stereo. One mask serves both channels (linked L+R).
- No dither. Samples that had to be clipped (a boost) are counted and printed on stdout.
- The wav goes to `<project>/samples/spectral/` (or `~/Library/Application Support/Objekat/Spectral/` for
  a project never saved), never overwriting an earlier one (" 2", " 3"…).

## Limits

- v1 targets objects of **up to 2 minutes**. Above that the script **warns** (the resolution of the
  single picture degrades, the computing is slower); above **10 minutes** it **refuses**.
- A bus (aux, infinite group), an object whose file is missing and an empty object are refused. One
  object at a time.
- The veil is a fixed grid (at most 4096 × 512 cells): a very small eraser stroke looks blocky at a
  strong zoom. The result does not: the audio is computed on the STFT grid.
- Memory: about 0.5 GB of float32 at the 10-minute ceiling at 96 kHz stereo.

## Files

| file | role |
|---|---|
| `spectral_gain.py` | the script: one connection, one loop (wait → compute → update) |
| `run.sh`, `install.sh`, `manifest.json`, `requirements.txt` | packaging |
| `mask.py` | **the only home of the gain mathematics** (rectangle, eraser dabs, cumulative G in dB) |
| `dsp.py` | STFT / ISTFT with a time-frequency gain, streamed in blocks |
| `image.py`, `veil.py`, `canvasfile.py`, `colormap.py` | the base spectrogram, the veil layer, the two raw image formats |
| `wavio.py` | WAV reader / writer (RIFF / RF64, PCM 16 / 24 / 32, float) |
| `decide.py` | the small pure decisions: depth class, rates, durations, mono, names |
| `make_fixture.py` | writes the two image-format fixtures to `tools/fixtures/spectral/` |
| `test_*.py`, `run_tests.sh` | the unit tests (`./run_tests.sh [python]`) |

End to end, headless: `tools/scenario_spectral_gain.py` (sections c, d, e drive this script through the
real app).

## Testing hooks

`--object ID` (instead of `OBJEKAT_OBJECT_IDS`), `OBJEKAT_SPECTRAL_CACHE` (the work folder, default
`~/Library/Caches/Objekat/spectral-gain/<uuid>`, removed when the script ends),
`OBJEKAT_SPECTRAL_PYTHON` (the interpreter `run.sh` uses, default the venv's).

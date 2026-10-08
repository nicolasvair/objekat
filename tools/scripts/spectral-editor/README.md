# Spectral editor

(Folder and id: `spectral-editor`; the script was called `spectral-gain` until 7 October 2026, revision 4.)

An OBJEKAT third-party script (spec: `OBJEKAT - claude project/docs/spec_spectral_editor.md`,
technical plan: `plan_spectral_editor.md`, same folder). Right-click ONE object → **Scripts → "Spectral
editor…"**.

It opens a floating window with the **spectrogram** of the object (logarithmic frequency axis), lets
the hand **attenuate — or boost — regions of time × frequency**, lets the ear compare, and brings the
result back into the session. In the spirit of iZotope RX, restricted to **gain**: no spectral repair,
no de-noise, no pitch editing.

The script computes everything (numpy only); the window, the gestures, the history and the playback
belong to the app (`script.canvas.*`, `command_api.md`). The app knows nothing about FFTs or dB.

## Install

```
tools/scripts/spectral-editor/install.sh
```

Creates a venv at `~/Library/Application Support/Objekat/venvs/spectral-editor`, installs numpy in it
(no model, no download beyond numpy), and symlinks this folder into
`~/Library/Application Support/Objekat/Plugins/spectral-editor`. Then **reload the scripts** in OBJEKAT
(Scripts menu → Reload) or relaunch the app.

## Use

1. Right-click one object (a clip, or a group) → **Scripts → Spectral
   editor…**. The object is **rendered** exactly as `retouche-externe` renders it: its own plugins,
   gain, pan, fades, window and speed (a group's content included), and nothing around it (no parent
   chain, no master, no sends).
2. The window shows the spectrogram. One **Gain** — a row of buttons, −60 / −24 / −12 / −6 / −3 / +3 dB, default −12 — serves both tools, with the
   rectangle's **feathers** (in time, ms; in frequency, semitones). Tools:
   - **Rectangle**: drag a box over time × frequency; a soft edge so the box does not ring.
   - **Brush** (Pinceau): draw over the picture, like a spray can. A pass deposits **Amount per pass**
     (default 25 %) of the gain — at the default −12 dB, −3 dB — up to 100 % in one stroke; **Size** (screen
     pixels, stored in time × frequency so zooming does not change its meaning) and **Hardness**. Crossing
     a place again deposits again; a hand held still deposits nothing.
   - Two **modes**. **Instant**: each gesture is applied at once, one history step. **Selection**: gestures
     build a weighted **selection** (0–100 % at every point, drawn in amber, opacity = intensity) over as many
     gestures as you want — a rectangle sets 100 %, a brush pass adds its amount; **Draw / Erase** (⌘ held
     flips it) adds or removes; **move the Gain or a feather and the sound follows live**, no history step.
     **Apply** then makes ONE history step at the current values and clears the selection. The gain applies
     pro rata: at −12 dB a 50 % zone gets −6 dB. Apply is not Validate.
   - Steps are cumulative (gains in dB add up). **What is applied is IN the spectrogram**: after each step
     (Instant gesture, Apply, undo, redo) the picture is recomputed from the result, so an attenuated
     region simply gets darker; there is no overlay on committed steps. Only a pending selection keeps its
     amber layer. Refreshing costs a fraction of a second on a short object (about 0.2 s more per step
     on 30 s of stereo).
   - **Remembered between sessions** (per user): FFT size, overlap, mode (Instant / Selection), tool
     (Rectangle / Brush), gain, both feathers, brush size, amount per pass and hardness. They are kept as you
     change them (Cancel included); **Reset** gives the defaults back. The time feather goes from 0 to 1 s.
3. Listen, independently of the project transport: **play/stop** from the point you right-click (or click in
   the time ruler), and ONE switch **Original / Result / Difference** (it opens on **Result**) — instantly, at the same position —
   the last being only what the operations take away. ⌘Z / ⇧⌘Z walk the history one entry back (the
   last selection gesture, then whole applied steps; the window's own, nothing reaches the project's undo
   stack before Validate). **In Selection mode, ⌘Z on an applied step brings its selection back** as the
   pending (amber) one, with its gain and feathers back in the controls: tweak it and Apply again (⇧⌘Z right
   after puts the step back as it was; with a selection pending, ⌘Z still removes the last gesture; Instant
   mode is unchanged).
   - **Working on the Difference.** The Difference is exactly Original − Result (Result + Difference =
     Original). With the switch on **Difference**, a gesture acts on it: a gesture of gain *g* leaves
     *g* × what the Difference held, so the Result gets back the rest — `G' = 1 − (1 − G)·g` (−12 dB
     on the Difference's content is the same as taking 12 dB off what you had removed). A step drawn on
     the Difference then on the Result (or the reverse) composes in the order drawn. A Selection step takes the view of its first gesture.
     Boosting the Difference beyond what it holds cannot go below silence for the Result (floor −300 dB).
4. **Expert** (side bar): FFT size (1024…32768, default 2048) and overlap (2…10, default 4). Changing
   them recomputes the picture and the preview; the operations made are kept (they are stored in
   seconds and Hz, not in bins). Also **Display**: the spectrogram's **floor** (−120…−20 dB, default −100)
   and **ceiling** (−60…0 dB, default 0) — the levels drawn black and white, for the Original, the
   Result and the Difference alike. Display only (no effect on the sound), instant (the pictures are
   re-coloured from memory, no new analysis), remembered with the other settings; the ceiling is kept at
   least 6 dB above the floor.
5. **Validate** writes what you HEAR (a selection still pending asks first: Apply, Ignore or Cancel) as a wav, lays it on a **new row at the same instant** (inside the
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
- The amber selection layer is a fixed grid (at most 4096 × 512 cells): a very small brush stroke looks
  blocky at a strong zoom. The result does not: the audio is computed on the STFT grid.
- Memory: about 0.5 GB of float32 at the 10-minute ceiling at 96 kHz stereo.
- The two largest FFT sizes (16384, 32768) trade time for frequency resolution: a window of 0.34 s / 0.68 s at 48 kHz
  smears an edge over that time, and an object shorter than the window gets a picture of a few columns (it still takes
  its gestures; nothing is refused). They need more memory (about 1.2 GB peak for 120 s stereo at 32768) and are as
  fast as 2048 otherwise. See `plan_spectral_editor.md`, section 13.

## Files

| file | role |
|---|---|
| `spectral_editor.py` | the script: one connection, one loop (wait → compute → update) |
| `run.sh`, `install.sh`, `manifest.json`, `requirements.txt` | packaging |
| `mask.py` | **the only home of the gain mathematics** (rectangle, brush dabs, the weighted selection, pro rata gain in dB) |
| `dsp.py` | STFT / ISTFT with a time-frequency gain, streamed in blocks |
| `image.py`, `selection.py`, `canvasfile.py`, `colormap.py` | the base spectrogram (of the result), the selection layer, the two raw image formats |
| `wavio.py` | WAV reader / writer (RIFF / RF64, PCM 16 / 24 / 32, float) |
| `decide.py` | the small pure decisions: depth class, rates, durations, mono, names |
| `make_fixture.py` | writes the two image-format fixtures to `tools/fixtures/spectral/` |
| `test_*.py`, `run_tests.sh` | the unit tests (`./run_tests.sh [python]`) |

End to end, headless: `tools/scenario_spectral_editor.py` (sections c, d, e, g, j drive this script through the
real app).

## Testing hooks

`--object ID` (instead of `OBJEKAT_OBJECT_IDS`), `OBJEKAT_SPECTRAL_CACHE` (the work folder, default
`~/Library/Caches/Objekat/spectral-editor/<uuid>`, removed when the script ends),
`OBJEKAT_SPECTRAL_PYTHON` (the interpreter `run.sh` uses, default the venv's), `OBJEKAT_SPECTRAL_REMEMBER`
(the key under which the app remembers the controls, default `spectral-editor`; a test gives its own).

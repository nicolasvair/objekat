# Spectral editor — functional spec (DRAFT, to be confirmed)

Status: draft of 4 October 2026, written with the user before any code. Decisions already taken
are marked **[decided]**; defaults I proposed and that still need a yes are marked **[proposed]**.

## 1. What it is

A third-party script, **"Spectral gain"**, reached from an object's right click
(Scripts ▸ "Spectral edit…"), that opens a spectrogram of the object in a floating window, lets the
hand attenuate (or boost) regions of time × frequency, lets the ear compare, and brings the result
back into the session. In the spirit of iZotope RX, restricted to **gain**: no spectral repair, no
de-noise, no pitch editing.

It is made of TWO deliverables, and the split is the point **[decided]**:

1. **A generic app surface, `script.canvas.*`** — a native window a script declares and the app
   draws: an image with axes, zoom/pan, editing tools that produce an operation history, and
   playback of audio files the script provides. Nothing in it knows about FFTs: a future script
   (an annotated sonagram, a detector's view, a chromagram…) uses it as is.
2. **The script `tools/scripts/spectral-gain/`** — all the DSP, in Python (numpy/scipy), separate
   process, like every script (a crash costs the script, never the sound).

## 2. Workflow

1. Right click on ONE object → Scripts ▸ "Spectral edit…". **[decided]**
2. The object is **rendered** exactly as `retouche-externe` renders it (its own plugins, gain, pan,
   fades, window, speed; a group's content; not the parent's chain, the master, sends). **[decided]**
3. The script computes the STFT and opens the canvas window with the spectrogram.
4. The hand edits; every step is an undo/redo step; the ear compares (§5).
5. **Validate**: the result is written as a 24-bit wav, laid on a new row at the same instant (inside
   the same group if any), named "<name> (spectral)", and the original is **muted**, not deleted —
   `retouche-externe`'s exact return path. **Cancel** leaves the session untouched. **[decided]**

v1 targets objects of **≤ ~2 minutes**: the spectrogram is ONE image the app zooms into. The API
reserves room for "detail on demand" (the app asks for a region at higher resolution) but v1 does
not implement it. Beyond the limit: the script warns and still opens (resolution degrades), or
refuses above a hard ceiling **[proposed: warn above 2 min, refuse above 10 min]**.

## 3. The window

A floating, resizable window (same family as the script panel window), **[decided]**:

- **Main area**: the spectrogram, time horizontally, frequency vertically.
  - Frequency axis **logarithmic** by default **[proposed]**, with a lin/log toggle **[proposed]**
    (the image is re-sent by the script on toggle, or the app remaps — architect to decide).
  - Rulers: time (s / min:s) and frequency (Hz / kHz); a readout of time, frequency and level
    under the pointer **[proposed]**.
  - Zoom and pan on both axes (wheel / trackpad, ⇧ for zoom as in the timeline **[proposed]**).
  - The operations drawn ON TOP, immediately, by the app (the mask preview), before the script has
    recomputed anything.
  - A playhead.
- **Side bar**: the script's own controls, same vocabulary as `script.panel` (number, bool, choice,
  button, progress, section), plus Validate / Cancel.
- **Tool bar**: tool choice (Rectangle / Eraser / Hand-pan), transport (play/stop, A/B, delta),
  undo/redo.

## 4. Tools — the gain is SUBTRACTIVE first

The model is an **ordered list of operations**, each one a step of the history. The mask applied to
the audio is the product of all operations, in order (gains in dB add up). Linked L+R: ONE mask for
both channels, the display shows the channels combined **[decided; proposed: max of L and R]**.

### Rectangle **[decided]**
- Drag a box over time × frequency → one operation.
- Parameters, taken from the side bar at the moment of the gesture: **gain** (dB, range
  −∞ … +12 dB **[proposed]**, default −12 dB **[proposed]**), **feather in time** (ms) and
  **feather in frequency** (in semitones/octaves on a log axis **[proposed]**) — a soft edge, so a
  box does not ring.
- Cumulative like everything else: two overlapping boxes at −6 dB give −12 dB where they overlap.

### Eraser (cumulative) **[decided]**
An eraser rather than a brush: it exists to take away.
- A stroke = one operation (one undo step).
- Parameters: **size** (diameter, in screen pixels at the time of the stroke **[proposed]** —
  stored in time × frequency units so it does not change meaning when zooming), **attenuation per
  pass** (dB, default −3 dB **[proposed]**), **hardness** (the feather of the brush tip).
- **Cumulative**: passing again over the same place in a NEW stroke attenuates further
  (−3, −6, −9 …), floor −∞. Within ONE stroke, a place crossed twice is attenuated ONCE
  **[proposed]** — otherwise a hand that wobbles would carve holes.
- The app draws the accumulated attenuation as a veil on the image, so one sees where one has
  already been.

### Not in v1
Lasso / free shapes, magic wand, harmonic selection, editing an existing operation's parameters
after the fact (the history is undo/redo only) **[proposed]**.

## 5. Listening **[decided]**

Inside the window, independently of the project's transport (which is stopped on play **[proposed]**):
- **Play / stop** from the point clicked in the view, with a playhead.
- **A/B**: switch instantly between the ORIGINAL and the RESULT while playing, same position.
- **Delta**: hear only what the operations take away (original − result), to check one is not
  damaging the sound.
- The result follows the history: after an operation (or an undo/redo), the script recomputes and
  hands the app a new preview file; the app swaps it at the same position. Until then the status
  line says "computing…" and the previous audio keeps playing **[proposed]**.

## 6. Undo / redo **[decided]**

Every operation is a step; ⌘Z / ⇧⌘Z inside the window walk the history, and the ear follows (§5),
so one can compare step by step. This is the window's OWN history: nothing reaches the project's
undo stack until Validate (which is ONE project undo step, as in `retouche-externe`).

## 7. DSP defaults **[proposed]**

- STFT: Hann window, size 2048, hop 512 (75 % overlap) at the render's rate; weighted
  overlap-add so that an empty history gives back the input bit for bit (to −120 dB).
- Display: magnitude in dB, range −100 … 0 dBFS, a perceptual colormap (e.g. magma).
- Mask smoothing: feather applied in the mask domain, before the ISTFT.
- FFT size exposed as an advanced choice (1024 / 2048 / 4096)? **[question]**

## 8. Generic surface — what the app must offer any script

(The architect turns this into a command family; this is the requirement, not the API.)
- Open / close a canvas window bound to the calling connection (same lifetime as `script.panel`:
  the script dying closes it), optionally bound to an object.
- Set an image (file path) with its axes: x and y ranges, units, lin/log mapping.
- Declare which tools are offered and their parameters (sidebar controls).
- Report the operation history (ordered list, with the undo cursor) by long poll; never an edit of
  the project, never dirty, never in the project's undo stack.
- Draw the operations as overlays (rectangles with feather, strokes with size/hardness, cumulative
  veil).
- Play audio files the script provides, with A/B/delta slots, a playhead, seek, and a swap that keeps
  the position.
- Headless: the canvas exists, no window opens; an `input`-style door lets a test inject gestures.

## 9. Verification plan

- Python: STFT/ISTFT round trip (identity to −120 dB), mask arithmetic (cumulative eraser, feather,
  one-stroke-once), against synthetic signals — runnable on this Linux machine.
- App: a headless scenario driving `script.canvas.*` and the script end to end (inject a rectangle,
  undo, validate, check the new object and the mute; an export re-read at RMS proving the band was
  attenuated).
- **Not verifiable here**: this machine is Linux with no compiler. The Swift half will be written
  blind and must be built and run on the Mac (Debug build against the warning baseline, then the
  scenario, then the eye and the ear).

# Spectral editor — functional spec (CONFIRMED)

Status: CONFIRMED by the user on 4 October 2026 — every **[proposed]** below was accepted as is (read them as decided).
All points were confirmed by the user; **[decided]** and **[proposed]** only record who first said them.

**Revision 3 (6 October 2026), decided by the user after trying it:** one Original / Result / Difference
switch; two modes, Instant and Selection (a weighted selection, then Apply); a Draw / Erase switch in
Selection mode (⌘ held flips it); right click = playhead; no Hand tool; the Eraser is renamed **Brush**.
The sections below are updated; the technical side is `plan_spectral_gain.md` §9. Points marked
**[r3 default]** are the architect's defaults awaiting the user's answer (plan §9.7).

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
5. **Validate**: the result is written as a wav at the **same sample rate and bit depth as the
   edited object's source file** **[decided]** (the render itself is made at that rate and depth;
   a non-PCM source — mp3, aac — falls back to 24-bit; a group whose files differ asks which rate,
   as `retouche-externe` does). **Channels follow the RENDER** **[decided]**: a render whose two
   channels are identical sample for sample is written mono, otherwise stereo — so a mono source
   panned or through a stereo plugin comes back stereo. The file is laid on a new row at the same instant (inside
   the same group if any), named "<name> (spectral)", and the original is **muted**, not deleted —
   `retouche-externe`'s exact return path. **Cancel** leaves the session untouched. **[decided]**

v1 targets objects of **≤ ~2 minutes**: the spectrogram is ONE image the app zooms into. The API
reserves room for "detail on demand" (the app asks for a region at higher resolution) but v1 does
not implement it. Beyond the limit: the script warns and still opens (resolution degrades), or
refuses above a hard ceiling **[proposed: warn above 2 min, refuse above 10 min]**.

## 3. The window

A floating, resizable window (same family as the script panel window), **[decided]**:

- **Main area**: the spectrogram, time horizontally, frequency vertically.
  - Frequency axis **logarithmic**, no linear mode **[decided]**.
  - Rulers: time (s / min:s) and frequency (Hz / kHz); a readout of time, frequency and level
    under the pointer **[proposed]**.
  - Zoom and pan on both axes (wheel / trackpad, ⇧ for zoom as in the timeline **[proposed]**), pinch,
    Fit. There is no Hand tool **[r3]**.
  - Left click in the spectrogram only DRAWS; **right click** (or ⌃-click) only moves the playhead; a left
    click in the time ruler also moves it **[r3]**.
  - The operations drawn ON TOP, immediately, by the app (the mask preview), before the script has
    recomputed anything.
  - A playhead.
- **Side bar**: the script's own controls, same vocabulary as `script.panel` (number, bool, choice,
  button, progress, section), plus Validate / Cancel.
- **Tool bar**: tool choice (Rectangle / Brush), the mode (Instant / Selection), Draw / Erase (Selection
  mode only), undo/redo, play/stop, ONE listening switch Original / Result / Difference, Fit **[r3]**.
- **Apply** (Selection mode): in the side bar, above Cancel / Validate, distinct from Validate **[r3]**.

## 4. Tools — the gain is SUBTRACTIVE first

The model is an **ordered history of steps**. The mask applied to the audio is the sum, in dB, of every
applied step. Linked L+R: ONE mask for both channels, the display shows the channels combined **[decided;
proposed: max of L and R]**.

### Two modes **[r3, decided]**
- **Instant**: each gesture is applied at once with the current settings and becomes one history step;
  its trace gives way to the veil. There is no Erase in Instant: ⌘Z corrects.
- **Selection**: gestures build a **weighted selection** that stays on screen, over as many gestures as
  wanted. The hand changes the settings while listening (try −6, then −12 dB): the preview follows live and
  no history step is added. **Apply** makes ONE history step from the selection at the current settings and
  clears it. Apply is not Validate (which closes the window).
- Mode at opening: Instant. Switching mode while a selection is pending is not allowed until it is applied or
  undone **[r3 default]**. Validate with a pending selection includes it, as heard **[r3 default]**.

### The weighted selection **[r3, decided]**
- An intensity from 0 to 100 % at every point of time × frequency, shown by the selection overlay's opacity.
- A **Brush** pass adds intensity according to its **Quantity** (%, per pass), capped at 100 %; an
  **Erase** pass subtracts it, floor 0 %.
- A **Rectangle** sets 100 % inside, with feathered edges; in Erase it clears the inside **[r3 default]**.
- The **gain** applies pro rata: at −12 dB, a 50 % zone gets −6 dB, a 100 % zone −12 dB.
- Changing the gain or the feathers while a selection exists re-renders the preview live.
- **Draw / Erase** switch, Selection mode only; holding **⌘** flips it while held (as in Photoshop).

### Rectangle **[decided]**
- Drag a box over time × frequency.
- Settings: the shared **gain** (dB, −60 … +12, default −12), **feather in time** (ms) and **feather in
  frequency** (semitones) — a soft edge, so a box does not ring. In Instant they are taken at the gesture;
  in Selection, at Apply.
- Cumulative across steps: two overlapping applied boxes at −6 dB give −12 dB where they overlap.

### Brush (formerly "Eraser") **[decided; renamed r3]**
- A stroke = one gesture (one step in Instant, one selection gesture in Selection).
- Settings: **size** (diameter in screen points at the time of the stroke, stored in time × frequency units),
  **quantity per pass** (%, default 25 % **[r3 default]**: with the default gain −12 dB, one pass = −3 dB),
  **hardness** (the feather of the tip). The gain is the shared one **[r3 default]**.
- **Like a spray can**: the stroke deposits DABS along the path the hand travels, each weighted by the tip
  profile; crossing the same place several times in one stroke deposits several times, up to 100 % of the
  gain for that stroke. **Distance, not time** **[decided]**: a hand held still deposits nothing. One straight
  crossing deposits exactly the quantity at the tip's centre, whatever the spacing.
- In Instant, successive strokes still add up in dB (−3, −6, −9 … across strokes).
- The app draws the applied attenuation as a veil, and the pending selection as its own overlay.

### Not in v1
Lasso / free shapes, magic wand, harmonic selection **[proposed]**; editing an existing operation's
parameters after the fact — the history is undo/redo only **[decided]**.

## 5. Listening **[decided]**

Inside the window, independently of the project's transport (which is stopped on play **[proposed]**):
- **Play / stop** from the caret (set by a right click in the view, or a click in the time ruler), with a playhead.
- **ONE switch Original / Result / Difference** **[r3]**: switch instantly, same position, between the
  original, the result, and only what the operations take away (original − result), to check one is not
  damaging the sound.
- The result follows the history: after an operation (or an undo/redo), the script recomputes and
  hands the app a new preview file; the app swaps it at the same position. Until then the status
  line says "computing…" and the previous audio keeps playing **[proposed]**.

## 6. Undo / redo **[decided]**

Every applied step (an Instant gesture, or an Apply) is a history entry; in Selection mode each pending
selection gesture is one too. ⌘Z goes back ONE entry: the last selection gesture alone while a selection is
pending, otherwise a whole applied step — whose selection does not come back **[r3]**. ⇧⌘Z goes forward the
same way. ⌘Z / ⇧⌘Z inside the window walk the history, and the ear follows (§5), so one can compare step by step. This is the window's OWN history: nothing reaches the project's
undo stack until Validate (which is ONE project undo step, as in `retouche-externe`).

## 7. DSP

- Defaults **[proposed]**: Hann window, FFT size 2048, overlap 4 (hop = N/4), at the render's rate;
  weighted overlap-add (normalised by Σ window²) so that an empty history gives back the input to
  −120 dB, whatever the overlap.
- **Expert settings** (behind the side bar's Expert button) **[decided]**:
  - **FFT size**: 1024 / 2048 / 4096 / 8192 / 16384 / 32768.
  - **Overlap factor**: an integer 2 … 10 — `k` = k FFTs of size N overlapping, each shifted by
    N/k (2 = two FFTs shifted by N/2). The hop is `round(N/k)`; the normalisation above keeps the
    reconstruction exact for every k.
  - **Window**: Hann only for now **[decided]** (the setting is kept in the model so other windows
    can be added later, but no choice is shown).
  - Changing any of them recomputes the display and the preview; the operations already made are
    KEPT, since they are stored in seconds and Hz, not in bins.
- Display: magnitude in dB, range −100 … 0 dBFS, a perceptual colormap (magma) **[proposed]**.
- Mask smoothing: feather applied in the mask domain, before the ISTFT.

## 8. Generic surface — what the app must offer any script

(The architect turns this into a command family; this is the requirement, not the API.)
- Open / close a canvas window bound to the calling connection (same lifetime as `script.panel`:
  the script dying closes it), optionally bound to an object.
- Set an image (file path) with its axes: x and y ranges, units, lin/log mapping.
- Declare which tools are offered and their parameters (sidebar controls); optionally the two modes
  (Instant / Selection with Apply), which give each gesture a polarity (add / subtract) and seal selection
  gestures into one step — the app knows the shape of the history, never what a step means **[r3]**.
- Report the operation history (ordered list, with the undo cursor) by long poll; never an edit of
  the project, never dirty, never in the project's undo stack.
- Draw a raw trace of each operation until the script's layers (the veil, the selection) reflect it.
- Play audio files the script provides, with original / result / delta slots heard through ONE
  three-state switch, a playhead, seek (right click), and a swap that keeps the position.
- Headless: the canvas exists, no window opens; an `input`-style door lets a test inject gestures.

## 9. Verification plan

- Python: STFT/ISTFT round trip (identity to −120 dB), mask arithmetic (cumulative brush, weighted selection, feather,
  one-stroke-once), against synthetic signals — runnable on this Linux machine.
- App: a headless scenario driving `script.canvas.*` and the script end to end (inject a rectangle,
  undo, validate, check the new object and the mute; an export re-read at RMS proving the band was
  attenuated).
- **Not verifiable here**: this machine is Linux with no compiler. The Swift half will be written
  blind and must be built and run on the Mac (Debug build against the warning baseline, then the
  scenario, then the eye and the ear).

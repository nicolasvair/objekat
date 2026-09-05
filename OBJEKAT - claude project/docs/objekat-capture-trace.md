# Capture trace — freezing what a plugin does to one signal

*Specification. The authority for the feature; the code follows it, not the other way round.*

---

## What it is for

A session stops being portable the moment it leans on an AudioUnit. Open it on another
machine — a collaborator's, a studio's, your own in five years — and the plugin is missing,
the slot errors out, and the mix is not the mix any more.

**Capturing a trace** records what a given plugin does *to this precise signal*, so that the
result can be reproduced without the plugin. For one plugin sitting on an object or on a
group, we describe its action sample by sample, in affine form:

```
y[n] = g[n] · x[n] + d[n]
```

where `x[n]` is what enters the plugin, `y[n]` what leaves it, `g[n]` a time-varying gain and
`d[n]` an additive term. The model is **exact by construction** for any deterministic
processing — compression, saturation, a non-linear EQ, a whole chain — for as long as the
input signal stays the same. It is not an approximation of the plugin; it is a recording of
one of its performances.

The trace then replaces the plugin in the graph.

---

## Vocabulary

| symbol | name | nature |
|---|---|---|
| `x[n]` | input | the signal entering the plugin |
| `y[n]` | output | the signal leaving the plugin |
| `g[n]` | multiplicative component | a full signal, one value per sample and per channel |
| `d[n]` | additive component | a full signal, likewise |
| `d_free[n]` | **free-running component** | what the plugin emits *on its own*, fed with digital silence |

`d_free` is **not a constant**. It is a complete signal over the whole captured length —
region plus tail — and it may perfectly well vary in time: modelled 50 Hz hum, slow drift, a
noise floor, self-oscillation. Storage and arithmetic treat it as a signal throughout; nowhere
is it collapsed to a scalar. (An earlier draft called it `d_static`, which invited exactly that
mistake.)

`d[n]`, the term that actually gets stored, is not the same thing as `d_free[n]`: it carries
both the free-running component *and* the numerical relief valve near the zeros of `x` (see
**Computing the trace**).

---

## The way in

In the signal view, right-click a plugin — on an object or on a group — → **“Capture trace”**.

During the capture: a progress indicator, cancellable. At the end: the validation report (see
below) shown to the user, with the residual level.

Once a trace is captured, the plugin slot gains a state of its own, visible in the signal
view: `traced`. On a machine where the plugin is absent, the slot loads in trace mode instead
of showing an error.

---

## Capture procedure

Offline renders, all in the same graph context, at the same sample rate and with the same
block size. **All arithmetic in float64.**

The order matters, and it is not the obvious one. The determinism test comes **first**,
because its answer decides whether the null-input pass should be run at all.

### a. Pass B — the real signal, twice

The plugin receives `x[n]`: the output of everything upstream in the chain (for a group, the
sum of the sources after their own processing). We capture `x[n]` at the insertion point,
before the plugin, and `y[n]` after it, in the same render. Then we do it again, identically.

Call the two results `(x₁, y₁)` and `(x₂, y₂)`.

### b. The null test, between the two B passes

Subtract, measure peak and RMS. Two separate verdicts, and they say different things:

- **`y₁ − y₂`** — the plugin itself. Above the threshold, the plugin holds some randomness:
  modelled analogue drift, noise, a free-running oscillator. This is what selects the mode
  below.
- **`x₁ − x₂`** — everything *upstream* of the plugin. A non-null residual here means the
  input is not reproducible either, which does not stop the capture but does void the input
  fingerprint (see **Format**): there is no stable `x` to take the hash of, so staleness can no
  longer be detected. Report it as its own diagnostic; do not fold it into the plugin's verdict.

The threshold is the same **−250 dBFS** as the “exact” tier of the validation report. One
constant, one meaning: below it, two float32 renders are the same render.

### c. Branch on the result

#### Deterministic mode — `y` residual under −250 dBFS

- Run **pass A**: the plugin receives strict digital silence over the whole length, and we
  capture `d_free[n]`.
- If `d_free` is zero everywhere, raise `multiplicative_only` and take `d = 0`.
- Otherwise `g[n] = (y[n] − d_free[n]) / x[n]`, as intended.

Most plugins will answer silence to silence, `d_free` will be null, and detecting that is what
keeps the trace small — it is the normal case, not the exception.

#### Non-deterministic mode — `y` residual above the threshold

- **Do not run pass A, and do not subtract anything.**
- The reason is not economy, it is correctness: the realisation captured in pass A would be a
  *different* draw from the one in pass B. Subtracting it would add a second source of noise
  instead of removing one.
- Set `d[n] = 0` and compute `g[n] = y[n] / x[n]` directly, noise included in the numerator.
  The reconstruction stays exact: we are freezing one realisation, which is precisely the
  point.
- Raise the `non_deterministic` flag in the header, and tell the user plainly: **the render is
  frozen.** It will not be re-randomised on each playback the way the live plugin would be.
  That is a change in behaviour, not a defect, and it is theirs to accept.

`y` and `x` are taken from the **first** B pass in both modes. The second exists only to be
subtracted.

### Constraints common to every pass

- Reset the plugin completely before each pass (`reset()`), then run it over a **pre-roll of
  silence of at least 2 seconds** before the start of the useful region, so that detectors,
  filters and smoothing cells settle.
- Capture a **tail after the end of the region: 5 seconds minimum, configurable**. Long
  releases and reverb tails leave through there.
- **No parameter may move between passes.** If automation exists on the plugin it must be
  replayed identically — record it in the trace's metadata.
- **Freeze the block size.** Some plugins behave differently per block.

---

## Alignment

Critical, and the first cause of failure.

1. Ask the plugin for its declared latency and compensate for it (the existing PDC
   infrastructure of the ContainerClip backend applies here).
2. **Verify** by cross-correlating `x` and `y` over a stretch with a strong transient. The peak
   must land on a whole-sample delay.
3. If the peak is fractional, the plugin oversamples internally and its latency is not a whole
   multiple of the sample period. Two options: reject the capture with an explicit message, or
   resample `x` through a fractional all-pass before dividing. Implement the detection first;
   refusing cleanly is acceptable in v1.
4. Record the delay used in the metadata.

---

## Computing the trace

Per channel, independently — even when the plugin is stereo-linked. We assume nothing.

Two configurable thresholds:

| constant | default | what it guards |
|---|---|---|
| `X_MIN` | −100 dBFS | the input is too quiet for a ratio to mean anything |
| `G_MAX` | 64.0 | the ratio is real but absurdly large |

```
num[n] = y[n] − d_free[n]        (deterministic mode)
num[n] = y[n]                    (non-deterministic mode: d_free is not captured)
```

Then, in this order — the gate first, and it is exclusive:

- **`|x[n]| < X_MIN` → gate.** Force `g[n] = 1` and `d[n] = num[n] − x[n]`.

  This is the case where the plugin produces signal out of silence: noise, a tail, hum. Without
  the gate, `g` has to explode to represent it and the `G_MAX` clamp then tips the whole thing
  into the additive term anyway — the right answer, reached by accident, through absurd
  intermediate values. Make it explicit instead. It also keeps the trace readable: `g` stays at
  1 across silences instead of wandering over six orders of magnitude, which is exactly what
  makes the run-length encoding below worth anything.

- Otherwise, `|num[n] / x[n]| > G_MAX` → **clamp** `g[n]` to `G_MAX` with the original sign,
  and tip the difference into the additive term: `d[n] = num[n] − g[n]·x[n]`.

- Otherwise → `g[n] = num[n] / x[n]`, and `d[n] = d_free[n]` (deterministic) or `0`
  (non-deterministic).

So `d[n]` serves three purposes at once — the processing's own free-running output, the gate's
output over silence, and the numerical relief valve near the zeros of `x`. They coexist without
conflict: each sample falls in exactly one branch.

### Detecting the simple cases

- `d[n]` zero everywhere → do not store `d`, flag the trace `multiplicative_only`.
- `g[n]` bit-identical across channels → store a single channel, flag it `linked`.

---

## Format

A binary file beside the session, referenced by the plugin slot's identifier.

### Header (JSON or structured binary, either way)

- the slot's identifier; the original plugin's name, AU identifier and version
- sample rate, channel count, block size used
- the start offset in the timeline, the total length (region + tail)
- the pre-roll and tail actually applied
- the alignment delay applied
- `X_MIN` and `G_MAX` used
- flags `multiplicative_only`, `linked`, `non_deterministic`
- the fingerprint of the input signal (a hash of `x[n]`), for invalidation — **absent** when
  the `x` null test failed, since there is then no stable input to fingerprint
- the null-test residuals, on `y` and on `x`, in dBFS
- the residual level measured at validation
- the plugin's automation over the captured span, if any

### Data — run-length encoded

`g` and `d` are stored **as segments, not as flat arrays**. On a typical trace `g[n]` is
exactly 1 over long stretches — silences, passages below a compressor's threshold — and `d[n]`
is 0 everywhere outside the gated zones. Stored flat, a trace costs 8 bytes per sample per
channel, most of it spent writing ones and zeros: a stereo minute at 48 kHz is 92 MB of which
the overwhelming majority carries no information.

Per signal and per channel:

```
float64  defaultValue        (1.0 for g, 0.0 for d)
uint32   numSegments
numSegments × { uint64 startSample; uint64 numSamples; }
then, concatenated in segment order, the float64 samples of every segment
```

Everything outside a segment reads back as `defaultValue`. A signal that never departs from its
default writes zero segments — that is how `multiplicative_only` shows up in the file rather
than only in a flag.

The comparison against the default is **exact** (`== 1.0`, `== 0.0`), never approximate: a
tolerance here would be lossy compression, and this format's whole point is exactness. It costs
nothing in practice, because the values that compress are the ones we *assign* — the gate's
`g = 1`, the deterministic branch's `d = 0` — not ones we hope will land on a round number.

Two runs separated by a gap shorter than **16 samples** are merged into one. A segment header
costs 16 bytes, about two samples; below that the encoding loses on bytes as well as on lookup
cost, and a pathological alternation would otherwise produce a segment table with millions of
one-sample entries.

Do not decimate, do not compress to float32. Exactness is the target; the saving comes from not
storing what is not there.

---

## Restitution

A light processing node that replaces the plugin in the graph and applies `g[n]·x[n] + d[n]`
sample by sample, in float64, reading the segment lists directly.

The hash of `x[n]` in the header invalidates the trace if anything changes upstream: the slot
then goes to `traced (stale)` in the signal view, coloured as a warning, and the reconstruction
is no longer guaranteed. A trace captured with no fingerprint (a non-deterministic upstream)
can never be checked this way — say so in the slot's tooltip rather than pretending it is
fresh.

---

## Automatic validation after capture

Reconstruct `g[n]·x[n] + d[n]`, subtract from `y[n]`, measure the peak and RMS of the residual.

| residual | verdict |
|---|---|
| under −250 dBFS | exact — green status |
| −250 to −120 dBFS | acceptable — worth reporting |
| above −120 dBFS | a problem |

Above −120 dBFS it is almost always a fractional alignment. Show the diagnosis, not a bare
failure.

Note that the validation stays meaningful in non-deterministic mode: `g = y/x` is exact against
the *frozen* realisation, so a residual there still points at the alignment or the arithmetic,
never at the plugin's randomness — that was already measured, in step b, and reported
separately.

---

## Limits to state in the interface

- A trace is valid **for this input signal only**. Any change upstream — a fader, an edit,
  another plugin — invalidates it.
- On a group, `g[n]` only redistributes onto the individual sources if the plugin introduces no
  distortion. A memoryless non-linearity does not distribute over a sum. That is a
  mathematical limit, not an implementation one.
- A non-deterministic plugin's trace is a **frozen performance**. It will not vary from one
  playback to the next the way the plugin did.
- A trace is heavy: float64 at full rate, 8 bytes per sample per channel before encoding.
  Plan for disk-space management and a purge option.

---

## Suggested order of implementation

1. Offline render of the passes with pre-roll and tail, mono first
2. Alignment + fractional-latency detection (a clean refusal in v1)
3. The determinism null test and the two-mode branch
4. Computing the trace, with the `X_MIN` gate and the `G_MAX` clamp
5. Validation by null test, and the report
6. The restitution node
7. The context-menu entry, and the visual states in the signal view
8. Multichannel, the invalidation hash, the run-length encoding and the simple-case detection

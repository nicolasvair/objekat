# Spectral editor: technical plan, revision 2 (`script.canvas.*` and `tools/scripts/spectral-gain/`)

This revision replaces the whole of `OBJEKAT - claude project/docs/plan_spectral_gain.md`. It applies your review:
- The canvas is now truly generic. All brush, rectangle and gain logic lives only in Python.
- The rectangle gain slider runs −60…+12 dB and −60 means −60 dB.
- On stop, the playhead returns to the caret.
- Every other default I proposed is now decided.

**Inputs**
- The confirmed spec: `OBJEKAT - claude project/docs/spec_spectral_editor.md`, which is the authority.
- `CLAUDE.md`.
- `command_api.md`: Undo/`batch`, Export/`object.render_isolated`, Third-party scripts, `overlay.*`, `script.panel.*`.
- Swift models: `objekat/Shared/ScriptPanelStore.swift`, `ScriptOverlayStore.swift` (it holds `CommandCallContext`), `ScriptPanelMemory.swift`, `objekat/CommandAPI/Commands+ScriptPanel.swift`, `objekat/Inspector/ScriptPanelWindow.swift`, `objekat/EditViewModel/EditViewModel+ScriptOverlay.swift`, `CommandServer.swift`, `objekat/Export/ExportAudition.swift`.
- Scripts and tests: `tools/scripts/retouche-externe/`, `tools/scripts/separateur-voix/`, `tools/scenario_breath_eval.py`.

**Repository facts the executor must know**
1. **New files compile without project edits.** The Xcode project uses synchronized folders, so any new `.swift` file under `objekat/` is compiled into the app with no `pbxproj` change.
2. **Pure code must opt out of MainActor.** Default actor isolation is MainActor. Declare pure code `nonisolated enum` / `nonisolated struct`, as `SessionFile` and `CustomColorBatch` already do.
3. **Name clash.** The app's own `TimelineView` struct shadows SwiftUI's. Always write `SwiftUI.TimelineView`.
4. **No non-finite numbers in JSON.** `JSONEncoder` throws on them, so `inf` and `NaN` must never reach a payload.
5. **The timeline monitors leak into other windows.**
   - The key, scroll and magnify monitors in `objekat/Timeline/TimelineKeyHandler.swift` are app-wide and never check which window the event came from.
   - With the canvas window key, ⌘Z would therefore undo the PROJECT. Step 8 guards this.
   - `TimeRulerView`'s mouseDown monitor converts points from any window, so it needs the same guard.
6. **One connection, one loop.** A connection serves its requests one after another. A script therefore runs a single loop: wait, compute, update.
7. **Validate must be a single batch.** `batch` gives one undo, but a sub-command cannot use an earlier sub-command's result. `object.add` therefore gains a `name` parameter.
8. **Source format is missing.** `object.get` has no sample rate or bit depth today. Step 6 adds them.
9. **No numpy on this Linux machine.** Before step 1, create a venv in the scratchpad:
   `python3 -m venv $SCRATCH/sgvenv && $SCRATCH/sgvenv/bin/pip install numpy`
   If the proxy blocks pip, read `/root/.ccr/README.md`.
   `tools/i18n/xcstrings.py` needs no numpy.

---

## 1. Architecture decisions

**D1. The canvas is a new window kind with its own store. It is not an extension of `script.panel`.**
- A panel is a form sized to its content. A canvas is a resizable plot with gestures, its own ⌘Z, an op history, image layers and audio.
- A canvas needs ONE long poll that returns both the sidebar values and the history. Two waits on one serial connection would block each other.
- The new types are `ScriptCanvasStore` and `ScriptCanvasWindows`.
- A connection may hold one panel and one canvas at the same time.
- The control vocabulary and its form are shared by extraction, with no change in behaviour:
  - `ScriptControls` (parse, apply, remember);
  - `ScriptControlsForm` (the SwiftUI rows);
  - `ScriptPanelMemory`, reused as is.

**D2. The app knows gestures, layers, history and playback. It knows nothing about gain.**
- **Tools are gesture kinds:**
  - `rect`: a box in data units;
  - `stroke`: a polyline in data units, with a diameter in screen points read from a bound control and converted to data units when the gesture starts;
  - `point`: a click;
  - `hand`: the app's own navigation tool, always present.
- **Each op records:** the gesture geometry, plus a `params` dictionary snapshotting the values of the controls the tool declares, at the moment of the gesture. The app attaches no meaning to them. The script interprets them.
- **The app draws only a raw TRACE** of each op the script has not yet reflected:
  - `rect`: an outline;
  - `stroke`: semi-transparent dark discs of the brush size, laid every `spacing_for(h)` diameters along the path (§3.3: ¼ for a soft brush, down to 1/64 for a hard one). The app has no notion of hardness, so a stroke tool may declare an optional `hardness_control` (a `number` control read as 0…100 %, a purely visual hint); the trace then uses `spacing_for(value / 100)`, and without it ¼. Passing again darkens more. This is purely visual; there is no dB anywhere in the app.
  - `point`: a small ring.
- The app also owns undo/redo (cursor, ⌘Z guard) and the transport.

**D3. The script supplies every image: the base, plus overlay LAYERS.**
- The mask veil is an RGBA layer the script renders after recomputing the mask. The target is 50–200 ms, and it is sent before the audio.
- A layer may carry a `history_rev`. The app hides the trace of an op once a layer covering that op's activation has arrived. Exact rule in §2.4.

**D4. The brush, rectangle and dab algorithm exists only in Python (`mask.py`) and is tested there.** There is no Swift twin and no gain cross-check.

**D5. Two raw image formats, both written with numpy and `struct` only (§3.1):**
- `OBJKCNV1`: indexed 8-bit with a palette and a value range. It feeds the readout.
- `OBJKRGB1`: premultiplied RGBA8.
- Any file ImageIO can read is also accepted, with no readout.
- The base is drawn as an indexed `CGImage`, so no conversion loop is needed.
- Caps: width ≤ 16384, height ≤ 4096, width × height ≤ 32 M.

**D6. Axes take a mapping, `lin` or `log`.**
- Lengths are expressed in warped units: axis units on a `lin` axis, octaves on a `log` axis.
- This is what turns the brush diameter into data units.

**D7. Audio uses a second `AVAudioEngine` with three player nodes (original, result, delta), all started at the same host time.**
- A/B and delta switching are node volumes, so a switch is instant.
- When a slot's file changes, that one node is re-scheduled aligned to the others; the fallback is to restart all nodes at the same position.
- Output goes to the card OBJEKAT itself has open, through `ExportAudition`'s device resolvers.
- **Headless:** no audio engine at all. The store runs a wall-clock transport model.

**D8. Return path: one `batch`.**
- `object.add {path, start, group | lane, name}`, then `object.set_mute {ids: [orig], muted: true}`.
- Placement is exactly retouche-externe's. The whole return is one project undo step.

**D9. Source format is read through `object.get`, which gains `source_sample_rate`, `source_bit_depth` and `source_format`.** No engine patch and no ObjC++ change anywhere in this plan.

**Swift size estimate.** About 1,500–1,700 new or moved lines, down from about 2,200 in revision 1.

| part | lines |
|---|---|
| store | ~420 |
| commands | ~420 |
| window and SwiftUI | ~330 |
| plot NSView with traces | ~380 |
| audio | ~230 |
| pure geometry | ~180 |
| image file parsing and loading | ~170 |
| control extraction (moved code) | ~250 |

---

## 2. The `script.canvas.*` contract

**Common rules**
- Every command is `undo: .none`. Nothing marks the project dirty, nothing is saved, nothing enters an undo snapshot.
- The owner is `CommandCallContext.caller`.

**Lifetime: same as a panel.** A canvas ends when:
- `script.canvas.close` is called;
- its owner's connection closes (the record is then removed);
- its `object` disappears (`pruneScriptOverlays`);
- the document changes (`resetScriptSessionState`).

Ending a canvas stops its audio and closes its window. A second `open` on the same connection replaces the first canvas, which ends `closed`.

**Headless mode**
- The canvas exists, but no window opens and no audio device is touched.
- The viewport is a nominal plot of 1000 × 500 points, fitted to the world.
- The transport is the store's clock.

### 2.1 Opening and image

**`script.canvas.open {title?, object?, controls?, tools, status?, busy?, remember?}`** → `{canvas_id, rev: 0}`
- `controls`: exactly the `script.panel.open` vocabulary.
- `tools`: an array of `{id, kind: "rect"|"stroke"|"point", label, icon?, params?: [control ids], size_control?}`.
  - `label` is the script's own text, already localised.
  - `icon` is an SF Symbol name. When absent: `rect` → `rectangle.dashed`, `stroke` → `scribble`, `point` → `smallcircle.filled.circle`.
  - `params` lists the hand-value controls (number, bool or choice) snapshotted into each op.
  - `hardness_control` is optional for `stroke` and forbidden otherwise. It must name a `number` control (0…100). It only sets the spacing of the raw trace (§3.3's `spacing_for`); the app gives it no other meaning. The eraser declares `hardness_control: "hardness"`.
  - `size_control` is required for `stroke` and forbidden otherwise. It must name a `number` control giving the diameter in screen points, clamped to 1…1000 when used.
  - The id `"hand"` is reserved. The Hand tool is always present and is labelled `L("canvas.tool.hand")`.
- `remember`: as for panels. Validate stores the values, `press: "reset"` restores the declared ones, the key is `scriptPanel.<key>`, and it is ephemeral under `--no-recent` or `--headless`.
- `bad_params` (in addition to the panel's control errors):
  - a duplicate tool id, an unknown tool kind, or a tool id equal to `"hand"`;
  - an unknown control in `params`, or one that is not a hand-value control;
  - a missing or bad `size_control`.
- `not_found`: unknown object.
- The first declared tool is active; if there is none, the Hand.

**`script.canvas.set_image {canvas_id, path, x: {min, max, unit?, mapping?}, y: {...}, value_unit?}`** → `{width, height, has_values}`
- Sets the BASE image and the world.
- `unit`: `"s"` gives time rulers, `"Hz"` gives Hz/kHz rulers, anything else is shown as a number plus that unit.
- `mapping` defaults to `"lin"`. `"log"` requires `min > 0`.
- If the axes are unchanged, the view and the layers are kept. Otherwise the view is refitted and every layer is dropped.
- Errors:
  - `not_found`: the file is missing;
  - `bad_params`: bad format or size, over the caps, `min >= max`, non-finite numbers;
  - `invalid_state`: the canvas is not open.

### 2.2 Layers

**`script.canvas.set_layer {canvas_id, layer, path?, history_rev?, opacity?, z?}`** → `{layers: [{layer, width, height, z, opacity, history_rev}]}`
- `layer` is a non-empty string id.
- `path` is an `OBJKRGB1`, `OBJKCNV1` or ImageIO file. `path: null` removes the layer.
- A layer always covers the world rectangle exactly. Its pixels are uniform in warped coordinates and row 0 is the top. Any size is allowed and the app scales it.
- `z` is an integer, default 0. Layers are drawn above the base in ascending `z`.
- `opacity` is 0…1, default 1.
- `history_rev` is the history revision the layer reflects (§2.4).
- An existing id is replaced: same z and opacity unless given, `history_rev` as given.
- At most 8 layers.
- `invalid_state`: no base image yet. `bad_params` and `not_found`: as for `set_image`.

### 2.3 Audio

**`script.canvas.set_audio {canvas_id, original?, result?, delta?, offset?, history_rev?}`** → `{slots, durations, playing, position, caret}`
- Each slot is a path, or `null` to clear it. An absent slot is kept.
- Each file is opened with `AVAudioFile` in both modes. Errors: `not_found` if missing, `bad_params` if unreadable.
- `offset` is the x value at which the file's sample 0 plays, default 0.
- `history_rev` is the history revision the files reflect. While `history.rev > audio_history_rev`, the window shows `L("canvas.status.computing")`.
- If a playing slot's path changes, it is swapped at the same position.
- Clearing the slot being heard falls back to `original`. Clearing `original` stops playback.

### 2.4 History, traces and their reflection

- **Each op carries `active_since`:** the history rev at which it last became active, set when it is added and again when it is redone.
- **`reflected_rev`** = the maximum `history_rev` over the layers that carry one, or −1 if none does.
- **Visible traces:** an active op has a visible trace iff `active_since > reflected_rev`.
- **Undo:** the undone op's trace disappears at once. The veil still shows that op until the script sends a new layer. The computing indicator is on during that gap.
- **Payload:** `history.unreflected` lists the ids of active ops whose trace is visible, so the rule is testable headless.

### 2.5 Reading and waiting

**`script.canvas.get {canvas_id, known_history_rev?}`** and **`script.canvas.wait {canvas_id, since_rev, timeout_ms?, known_history_rev?}`**
- `wait` is the panel's long poll:
  - it answers as soon as `rev > since_rev`, or as soon as the state is no longer `open`;
  - at the timeout (at most 5000 ms, default 1000) it answers the current state with no error.
- Reading drains `events`.

```json
{"canvas_id","rev","state":"open|validated|cancelled|closed","values":{},"events":[{"button":"id"}],
 "status","busy","remember":null,"tool":"rect",
 "history":{"rev":3,"cursor":2,"count":3,"unreflected":[8],"ops":[...]},
 "image":{"path","width","height","has_values"}|null,
 "layers":[{"layer","path","width","height","z","opacity","history_rev"}],
 "world":{"x":{"min","max","unit","mapping"},"y":{...}}|null,
 "view":{"x0","x1","y0","y1","width","height"},
 "transport":{"playing","position","caret","listen":"original|result","delta":false,
              "slots":{"original":null,"result":null,"delta":null},"durations":{},"audio_history_rev":null}}
```

- `history.ops` lists every op, including undone ones. The active ops are `ops[:cursor]`.
- `history.ops` is omitted when `known_history_rev == history.rev`.

**Op JSON.** `id` is a monotonic integer per canvas. `params` is the snapshot of the tool's declared controls.

```json
{"id":7,"kind":"rect","tool":"rect","x0":…,"x1":…,"y0":…,"y1":…,"params":{"gain":-12,"feather_ms":10,"feather_st":1},"active_since":5}
{"id":8,"kind":"stroke","tool":"eraser","points":[[x,y],…],"size_pt":32,"size_x":…,"size_y":…,"params":{…},"active_since":6}
{"id":9,"kind":"point","tool":"…","x":…,"y":…,"params":{…},"active_since":7}
```

- `size_x` and `size_y` are the diameter in warped units: `size_pt / pointsPerX` and `size_pt / pointsPerY`, frozen when the gesture starts.

### 2.6 The hand's door

**`script.canvas.input {canvas_id, values?, press?, tool?, view?, op?, undo?, redo?, seek?, listen?, delta?, play?}`** → `{rev, history_rev, cursor, added}`

The window goes through exactly the same store functions. Fields are applied in this order: values, tool, view, op, undo, redo, seek, listen, delta, play, press.

- **`op`:**
  - `{kind:"rect", x0, x1, y0, y1}`: sorted and clamped to the world. Zero area gives `added: false`.
  - `{kind:"stroke", points: [[x,y], ...], view_scale?: {x, y}}`:
    - 2 to 20000 points;
    - `view_scale` is points per warped unit; the default is the current viewport;
    - a path shorter than 1 point on screen gives `added: false`.
  - `{kind:"point", x, y}`.
  - The op uses the active tool if its kind matches, otherwise the first tool of that kind.
  - Errors:
    - `invalid_state`: no world yet, or no tool of that kind;
    - `bad_params`: non-finite values, or too few or too many points.
- **`undo` / `redo`:** a no-op at either end of the history, answering `added: false`.
- **`view`:** `{x0, x1, y0, y1}` in data units, clamped.
- **`seek`:** sets the caret and, if playing, jumps there. It is clamped to [0, the longest slot duration].
- **`listen`:** `"original"` or `"result"`. `invalid_state` if that slot is empty.
- **`delta`:** a bool. `invalid_state` if there is no delta slot.
- **`play`:**
  - `true` starts at the caret. `invalid_state` if there is no `original` slot. It also stops the PROJECT transport.
  - `false` stops, and the position returns to the caret.
- **`press`:** a button id, `"validate"`, `"cancel"`, or `"reset"` (only on remember canvases).
- **When `rev` moves:**
  - it moves on a values change, an added op, undo, redo, or a press;
  - it does not move on a tool, view or transport change.
- `invalid_state` if the canvas is not open.

### 2.7 Other commands

- **`script.canvas.update {canvas_id, status?, busy?, values?, labels?}`**: as for panels. It **never moves `rev`**.
- **`script.canvas.close {canvas_id}`** → `{closed: true}`.
- **`script.canvas.list`** → `{canvases: [{canvas_id, title, state, object}]}`. It calls `vm.pruneScriptOverlays()` first.
- **Reserved, not implemented:** detail on demand. A future `events` entry `{"detail": {...}}` and a `region` field on `set_image` and `set_layer`. v1 never emits them.

### 2.8 Transport model

The same model drives the store, the window and the headless clock.

**State:** `playing`, `caret`, `anchor` (`position`, `since: Date?`), `listen`, `delta`, `slots`, `durations`, `offset`, `audioHistoryRev`.

**Position:** while playing, `position = anchor.position + (now − since)`. When stopped, `position = caret`.

| event | effect |
|---|---|
| play | anchor = caret; the PROJECT transport is stopped |
| stop | `playing = false`, position = caret |
| reaching the end (longest slot) | same as stop |
| seek while stopped | caret = target |
| seek while playing | caret = target, anchor = target (playback jumps) |
| listen or delta change | nothing in the clock; node volumes only |

---

## 3. Data formats

### 3.1 Image files (little-endian)

**`OBJKCNV1`, indexed**

| offset | size | field |
|---|---|---|
| 0 | 8 | `b"OBJKCNV1"` |
| 8 | 4 | uint32 W |
| 12 | 4 | uint32 H |
| 16 | 4 | float32 value of index 0 |
| 20 | 4 | float32 value of index 255 |
| 24 | 4 | uint32 0 (reserved) |
| 28 | 768 | palette: 256 × RGB |
| 796 | W·H | uint8 indices |

- The file size must be exactly 796 + W·H.
- Readout: `v = v0 + idx·(v255 − v0)/255`. Index 0 is shown as "≤ v0".

**`OBJKRGB1`, premultiplied RGBA8**

| offset | size | field |
|---|---|---|
| 0 | 8 | `b"OBJKRGB1"` |
| 8 | 4 | uint32 W |
| 12 | 4 | uint32 H |
| 16 | 8 | 0 (reserved) |
| 24 | 4·W·H | RGBA, premultiplied |

- The file size must be exactly 24 + 4·W·H.
- The app builds `CGImage(… bitmapInfo: premultipliedLast …)`.

**Common to both**
- Rows are row-major, row 0 = the TOP (y max), column 0 = x min.
- Rows and columns are uniform in warped coordinates. Row r has its centre at `ywmax − (r+0.5)·span/H`.
- Extensions: `.objkcnv` and `.objkrgb`.
- A small committed fixture of each format is the only shared fixture. It checks the file format only; there is no gain mathematics in it.

### 3.2 Axes and viewport (Swift and Python)

- `warp(v) = log2(v)` on a log axis, `v` on a lin axis.
- The viewport holds `x0w, x1w, y0w, y1w` in warped units and `width, height` in points. y is flipped, 0 at the top:
  - `sx = (xw − x0w)·W/(x1w − x0w)`
  - `sy = (y1w − yw)·H/(y1w − y0w)`
  - `pointsPerX = W/(x1w − x0w)`, `pointsPerY = H/(y1w − y0w)`
- **Zoom** keeps the anchor's warped value fixed.
- **Clamp:** the span is at most the world span and at least world/10000 on x, world/1000 on y, and the window stays inside the world.
- **Stroke diameter:** `size_x = size_pt / pointsPerX`, `size_y = size_pt / pointsPerY`, computed at mouseDown. "Pixels" means points.

### 3.3 Gain mathematics (Python `mask.py` only)

All mask terms are in dB and add up.

**Rectangle** (tool `rect`, params `gain`, `feather_ms`, `feather_st`)
- Values: `gain_db = params["gain"]` (−60 is applied as −60 dB), `Fx = feather_ms/1000` seconds, `Fy = feather_st/12` octaves.
- `ramp(t)` is 0 for t ≤ 0, 1 for t ≥ 1, and `0.5 − 0.5·cos(πt)` between.
- One-dimensional weight on warped coordinates, with `lo = warp(x0)` and `hi = warp(x1)`:
  - if F = 0: w = 1 when `lo ≤ v ≤ hi`, else 0;
  - otherwise `w = min(ramp((v − (lo − F/2))/F), ramp(((hi + F/2) − v)/F))`, i.e. the feather is centred on the drawn edge.
- **Open edges:** an edge within 1e-9·span of the world bound (in data units) has no ramp and extends without limit.
- Contribution: `G += gain_db · wx · wy`.

**Eraser** (tool `stroke` id `eraser`, params `amount`, `hardness`; diameter from the op's `size_x`, `size_y`)
- Constants: `R = 0.5`, `SPACING_MAX = 0.25`, `SPACING_MIN = 1/64`, `SPACING_KNEE_H = 0.3`.
- **Spacing depends on hardness.** `spacing_for(h)` (h clamped to [0, 1]) is `0.25` for `h ≤ 0.3`, then a straight line down to `1/64` at `h = 1`:
  `spacing_for(h) = 0.25 − (0.25 − 1/64)·(h − 0.3)/0.7`. A fixed ¼ left a ripple along the stroke that grew with hardness (14 % at h = 0.7, 25 % at h = 1: a hard profile is nearly a box and sampling it coarsely beats against the dab lattice). Mirrored in Swift by the trace (`CanvasStrokeTrace`), which must call the same formula.
- Normalise each point: `u = warp_x(x)/size_x`, `v = warp_y(y)/size_y`.
- Dab centres sit at arc lengths `(k + 0.5)·spacing`, with `spacing = spacing_for(h)` and k an integer. Use `sqrt(du·du + dv·dv)`:

```python
acc = 0.0; k = 0
for i in range(1, n):
    du = u[i]-u[i-1]; dv = v[i]-v[i-1]
    L = math.sqrt(du*du + dv*dv)
    if L <= 0: continue
    while (k + 0.5)*spacing <= acc + L:
        t = ((k + 0.5)*spacing - acc) / L
        dabs.append((u[i-1] + t*du, v[i-1] + t*dv)); k += 1
    acc += L
```

  A still hand deposits nothing.
- Profile, with `h = hardness/100` and `ρ = dist/R`: 0 if ρ ≥ 1; 1 if ρ ≤ h; otherwise `0.5 + 0.5·cos(π(ρ − h)/(1 − h))`.
- Per dab: `a = amount · spacing/(R·(1 + h))`, `spacing = spacing_for(h)` (the profile integrates to `R·(1 + h)` across the centre line). It is `amount · 0.5/(1 + h)` for `h ≤ 0.3`.
- **Calibration:** one straight crossing deposits `amount` on the centre line. The mean along the line is exactly `amount` for every h, and the ripple around it (a dab-lattice beat) is at most 1.4 % of `amount` for every h in [0, 1] (measured: 0, 1.2, 1.05, 1.3, 0.87, 0.35, 0.93, 0.81, 0.29, 0.99, 0 % at h = 0, 0.1 … 1.0; exactly 0 at h = 0 and 0.25). Cost: 4 dabs per diameter for `h ≤ 0.3`, 64 at `h = 1`. Contributions add up within a stroke and across strokes.
- **Field:** `G += Σ a·p(ρ)`, with ρ computed in the normalised (u, v) space.

**Total**
- `G` is the sum over the active ops, clamped to `≥ −300` before `10^(G/20)`. There is no ceiling on boosts.
- Clipping is counted at the final write.

### 3.4 STFT and the base image (Python `dsp.py`, `image.py`)

**STFT**
- Periodic Hann window, `w[n] = 0.5 − 0.5·cos(2πn/N)`. Hop `H = floor(N/k + 0.5)`.
- Frames are centred: frame j covers `[jH − N/2, jH + N/2)`, with `J = ceil(L/H) + 1` frames and zero padding.
- Analysis: `rfft(w·seg)`.
- Synthesis: `y += w·irfft(M·X)` and `wsum += w²`. Output `y/wsum` wherever `wsum > 1e-12`, cropped to `[0, L)`.
- Processing streams in blocks of 256 frames, keeping an N-sample tail. Storage is float32 and arithmetic float64.

**Mask grid**
- `xw = jH/sr` and `yw = log2(k·sr/N)`.
- The DC bin copies bin 1.
- One mask serves both channels (linked L+R).

**Base image**
- Magnitude: `max(|X_L|, |X_R|)`.
- Rows: 1024, log-spaced over the world's y range [20, sr/2]. A row takes the max of the bin magnitudes inside its band; if no bin falls inside, it interpolates linearly at the row centre.
- Columns: `W = min(floor(L/H) + 1, 8192)`, tiling the world x range `[0, L/sr]` uniformly (column c covers `[c, c+1)·(L/sr)/W`).
- A frame j is centred at `t_j = jH/sr` and answers for the stretch `[t_j − H/2, t_j + H/2)`; a column is the max over every frame whose stretch touches it (exact integer arithmetic, clamped). So the frame nearest to a time always feeds the column that contains that time (no half-frame lateness), no column is empty, and a click survives the pooling. `image.frame_columns` and `image.column_of_time` are the definitions.
- Levels: `dB = 20·log10(max(m, 1e-12)/(N/4))`, mapped to `idx = clip(round((dB + 100)/100·255), 0, 255)` with v0 = −100 and v255 = 0. Written as `OBJKCNV1` with the magma palette.

### 3.5 Veil layer (Python `veil.py`)

**Grid**
- Columns: `min(4096, max(256, ceil(T/0.005)))` over the world x range. A cell's G is evaluated at its CENTRE time `(c + ½)·T/columns`, exactly as the STFT mask is evaluated at frame centres `jH/sr`, so veil and audio read the same G(t).
- Rows: 512, log-spaced over [20, sr/2].
- G is evaluated on cell centres with the functions of §3.3.

**Colours (premultiplied)**
- Attenuation, G < 0: colour (0, 0.75, 1), alpha `0.75·(1 − 10^(G/20))`.
- Boost, G > 0: colour (0.4, 1, 0.3), alpha `0.5·min(1, (10^(G/20) − 1)/3)`.

**Delivery**
- Written as `OBJKRGB1`, about 8 MB at most.
- Sent with `set_layer {layer: "veil", z: 1, history_rev}` before the audio.

**Incremental cache**
- If the new active list equals the previous one plus appended ops, add only the new contributions to the cached G.
- Otherwise recompute the whole grid.

---

## 4. Swift: files, types and hooks

| file | new or touched | content |
|---|---|---|
| `objekat/Shared/ScriptCanvasGeometry.swift` | new, pure, `nonisolated` | `CanvasAxisMapping`; `CanvasAxis` (warp, unwarp); `CanvasWorld`; `CanvasViewport` (fit, `zoomedX/Y(by:anchor:in:)`, `panned`, `clamped`, screen ↔ warped); `CanvasStrokeTrace.discCentres(points:sizeX:sizeY:world:) -> [CanvasPoint]` (resampling every `spacing_for(h)` diameters, with `h` the hardness, for drawing only; `spacing_for` is a pure Swift mirror of `mask.spacing_for`); `CanvasTicks` (1-2-5 steps ≥ 70 pt apart; log axes in decades × {1,2,5}, denser {1…9} when zoomed); `CanvasFormat` (time `m:ss.mmm`, Hz/kHz, value plus unit); `CanvasPoint` |
| `objekat/Shared/ScriptCanvasImageFile.swift` | new, pure | `nonisolated enum ScriptCanvasImageFile { enum Kind { indexed(v0, v255, palette), rgba }; struct Parsed { kind; width; height; pixelRange: Range<Int> }; static func parse(_ data: Data) throws -> Parsed }`, with its own `ParseError` |
| `objekat/Shared/ScriptCanvasImage.swift` | new | `final class ScriptCanvasImage { path; cgImage; width; height; indices: Data?; v0; v255; generation; static func load(path:) throws }`. Throws `CommandError` (`not_found` / `bad_params`). An indexed `CGImage` for CNV1, premultiplied RGBA for RGB1, `CGImageSource` otherwise; `value(column:row:)` |
| `objekat/Shared/ScriptControls.swift` | new, extraction | `parse`, `applyHand`, `applyScript`, `handValues`, `rememberKey`: code moved verbatim from `Commands+ScriptPanel.parseControls` and `ScriptPanelStore.input` / `update` / `handValues`, with the same messages |
| `objekat/Shared/ScriptPanelStore.swift`, `objekat/CommandAPI/Commands+ScriptPanel.swift` | touched | call `ScriptControls` |
| `objekat/Inspector/ScriptControlsForm.swift` | new, extraction | `struct ScriptControlsForm: View { controls; values; expert; labelWidth = 200; set: (String, JSONValue, Bool) -> Void; press: (String) -> Void }`, rows moved from `ScriptPanelView` |
| `objekat/Inspector/ScriptPanelWindow.swift` | touched | `ScriptPanelView` uses `ScriptControlsForm` |
| `objekat/Shared/ScriptCanvasStore.swift` | new | see "Store" below |
| `objekat/CommandAPI/Commands+ScriptCanvas.swift` | new | `registerScriptCanvasCommands()` with the 10 commands of §2; helpers `canvasPayload`, `opPayload`, `parseTools`, `parseAxis` |
| `objekat/CommandAPI/CommandRegistry.swift` | touched | register after `registerScriptPanelCommands()` (about line 258) |
| `objekat/EditViewModel/EditViewModel.swift` | touched | see "View-model" below |
| `objekat/EditViewModel/EditViewModel+ScriptOverlay.swift` | touched | `pruneScriptOverlays` → `scriptCanvases.closeWhereObjectGone`; `scriptSessionEnded` → `connectionClosed`; `resetScriptSessionState` → `closeAll(reason: .closed)` |
| `objekat/Inspector/ScriptCanvasWindow.swift` | new | see "Window" below |
| `objekat/Inspector/ScriptCanvasPlotView.swift` | new | see "Plot" below |
| `objekat/Inspector/ScriptCanvasAudition.swift` | new | see "Audio" below |
| `objekat/Export/ExportAudition.swift` | touched, visibility only | `outputDeviceIDs`, `defaultOutputDeviceID`, `outputDeviceID(named:)` become `static`; `deviceName` becomes `static` instead of `fileprivate` |
| `objekat/Timeline/TimelineKeyHandler.swift` | touched | first line of the scroll (l.24), magnify (l.351) and key (l.975) monitor closures: `if event.window is ScriptCanvasPanel { return event }`. The right-click monitor is already guarded. |
| `objekat/Timeline/TimeRulerView.swift` | touched | in `monitorDown` (l.387): `guard event.window === self.window else { return event }` |
| `objekat/SoundObject/ClipSourceFormat.swift` | new | see "Source format" below |
| `objekat/CommandAPI/Commands+Object.swift` | touched | `object.get`, `.clip` branch: `source_sample_rate`, `source_bit_depth`, `source_format`; `null` for anything that is not a clip |
| `objekat/CommandAPI/Commands+Core.swift` | touched | `object.add`: `ParamSpec("name", "string", required: false, …)`; `if let n = try p.optionalString("name"), !n.isEmpty { object.label = n }` before placement, so no second undo entry |
| `objekat/Resources/Localizable.xcstrings` | touched | the keys listed below |

**Store (`ScriptCanvasStore.swift`)**
- Types:
  - `ScriptCanvasState`;
  - `CanvasToolKind {rect, stroke, point}`;
  - `CanvasTool {id, kind, label, icon, params: [String], sizeControl: String?}`;
  - `CanvasOpShape {rect(x0, x1, y0, y1), stroke(points, sizePt, sizeX, sizeY), point(x, y)}`;
  - `CanvasOp {id, tool, shape, params: [String: JSONValue], activeSince}`;
  - `CanvasLayer {id, image, z, opacity, historyRev: Int?}`;
  - `CanvasSlot`, `CanvasListen`, `ScriptCanvasTransport` (§2.8);
  - `ScriptCanvas` (controls, values, tools, activeTool, rev, state, events, status, busy, rememberKey, declared, ops, cursor, historyRev, nextOpID, image, world, layers, transport).
- `@Observable final class ScriptCanvasStore`, with `@ObservationIgnored` storage for `viewports` and the clock anchors.
- Hooks: `canvasOpened`, `canvasEnded`, `viewportChanged`, `transportChanged`, `stopProjectTransport`.
- Methods: `open`, `end`, `connectionClosed`, `closeWhereObjectGone`, `closeAll`, `input(values:press:coalesced:)` (the panel's 30 Hz coalescing, copied), `update`, `read`, `setImage`, `setLayer`, `setAudio`, `selectTool`, `viewport` / `setViewport`, `addRect`, `addStroke(points:scale:)`, `addPoint`, `undo`, `redo`, `play`, `stop`, `seek`, `setListen`, `setDelta`, `position`, `reflectedRev`, `unreflectedOpIDs`.
- Adding an op: drop `ops[cursor...]`, append, `cursor = count`, `historyRev += 1`, set `activeSince = historyRev`, bump `rev`.

**View-model (`EditViewModel.swift`)**

```swift
let scriptCanvases: ScriptCanvasStore = {
    let s = ScriptCanvasStore()
    s.stopProjectTransport = { if let x = CommandContext.shared.session, x.isPlaying { x.stop() } }
    ScriptCanvasWindows.attach(to: s)
    return s
}()
```

**Window (`ScriptCanvasWindow.swift`)**
- `ScriptCanvasPanel: NSPanel`:
  - `performKeyEquivalent`: ⌘Z → `undo`, ⇧⌘Z → `redo`; read the letter from `charactersIgnoringModifiers`.
  - `keyDown`: Space with no held modifier toggles play.
  - Return and Esc are not bound.
- `ScriptCanvasWindows`:
  - `show` is guarded by `!LaunchArguments.process.headless`;
  - window style `[.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel]`, floating, `hidesOnDeactivate`, `becomesKeyOnlyIfNeeded = false`;
  - size 1100 × 660, minimum 720 × 420;
  - `windowWillClose` presses Cancel;
  - it owns the audition and is notified through `transportChanged`.
- `ScriptCanvasView` (SwiftUI):
  - **Toolbar:** Hand plus the script's tools (icon and label); undo / redo; play / stop; an Original / Result segmented control; a Delta toggle; Fit; the playhead time through `SwiftUI.TimelineView(.periodic(from: .now, by: 0.1))`; the computing indicator.
  - **Plot**, then a 300 pt **sidebar**: `ScrollView { ScriptControlsForm(labelWidth: 110) }`, the status line, and Expert / Reset / Cancel / Validate. Validate is disabled while busy or computing.
  - **Bottom bar:** the pointer readout (time, frequency, value), fed by an `@Observable` `ScriptCanvasPointer`.

**Plot (`ScriptCanvasPlotView.swift`)**
- `ScriptCanvasPlotNSView`: flipped, `acceptsFirstMouse` true. A 56 pt left ruler and a 22 pt top ruler.
- **Draw order:** black, base image (cropped to whole pixels, `interpolationQuality = .low`), layers by z with their opacity, traces of `unreflectedOpIDs`, the in-progress gesture, playhead, caret marker, rulers.
- **Trace drawing:**
  - rect: a 1 pt white outline;
  - stroke: discs filled black at 0.15 alpha, centred on `CanvasStrokeTrace.discCentres`, as ellipses of `size_x × size_y` mapped to the current zoom;
  - point: a ring.
- **Mouse, by tool:**
  - rect: rubber band, then `addRect`;
  - stroke: points closer than 0.5 pt are dropped, the scale is frozen at mouseDown, discs are drawn live, then `addStroke`;
  - point: `addPoint`;
  - hand: a drag pans; a click with less than 3 pt of travel seeks;
  - a click in the time ruler always seeks.
- **Scroll wheel:** plain = pan. ⇧ = zoom on the axis locked by `TimelineView.ScrollAxisLock`, with factors `exp(dx·0.01)` and `exp(dy·0.012)`, anchored at the pointer. Magnify zooms time.
- **Cursor:** on `mouseEntered`, call `TimelineCursorKeeper.relinquish()`. The cursor comes from `.cursorZone(toolCursor)` on a `Color.clear` frame over the plot surface: a crosshair, a circle sized to the stroke's `size_pt`, or the open hand. Never call `NSCursor.set()` directly.
- A 30 Hz timer redraws while playing.

**Audio (`ScriptCanvasAudition.swift`)**
- Three player nodes into the main mixer; the output device is set the way `ExportAudition.applyOutputDevice` does it.
- `play(from:)` calls `scheduleSegment` on each node, then `play(at: hostTime + 0.05 s)` on all of them.
- `setAudible` sets the volumes.
- `swap(slot:)` re-schedules that node aligned on `lastRenderTime` plus a 0.1 s lead; otherwise it restarts every node at the same position.
- Also `stop` and `position`.

**Source format (`ClipSourceFormat.swift`)**
- `nonisolated enum ClipSourceFormat { struct Info { sampleRate; bitDepth: Int?; kind } }`.
- Read from `AVAudioFile.fileFormat.streamDescription`: `kAudioFormatLinearPCM` gives `pcm_int` or `pcm_float` with `mBitsPerChannel`; anything else is `"compressed"` with no depth.
- Cached the way `ClipChannels` caches.

**i18n keys (fr / en / es)**

| key | fr | en | es |
|---|---|---|---|
| `canvas.title.default` | Toile du script | Script canvas | Lienzo del script |
| `canvas.tool.hand` | Main | Hand | Mano |
| `canvas.undo.help` | Annuler la dernière opération (⌘Z) | Undo the last operation (⌘Z) | Deshacer la última operación (⌘Z) |
| `canvas.redo.help` | Rétablir l'opération (⇧⌘Z) | Redo the operation (⇧⌘Z) | Rehacer la operación (⇧⌘Z) |
| `canvas.play` | Lire | Play | Reproducir |
| `canvas.stop` | Arrêter | Stop | Detener |
| `canvas.listen.original` | Original | Original | Original |
| `canvas.listen.result` | Résultat | Result | Resultado |
| `canvas.listen.delta` | Différence | Delta | Diferencia |
| `canvas.listen.delta.help` | N'écouter que ce que les opérations retirent | Hear only what the operations take away | Escuchar solo lo que quitan las operaciones |
| `canvas.fit` | Tout afficher | Fit all | Ver todo |
| `canvas.status.computing` | Calcul… | Computing… | Calculando… |
| `canvas.status.waitingImage` | En attente de l'image… | Waiting for the image… | Esperando la imagen… |

- Reused keys: `scriptpanel.validate`, `common.cancel`, `scriptpanel.expert`, `scriptpanel.reset`.
- Tool labels are the script's own data.
- `xcstrings.py set` refuses unknown keys. Add the new entries with a one-off Python snippet that imports `load` / `save` from `tools/i18n/xcstrings.py`, then run `check` and `orphans`.
- Glossary rows to add:
  - toile (d'un script) / script canvas / lienzo;
  - calque / layer / capa;
  - gomme / eraser / borrador;
  - original / résultat / différence;
  - spectrogramme / spectrogram / espectrograma.

---

## 5. Python: `tools/scripts/spectral-gain/` (numpy only)

**Packaging**
- `requirements.txt`: `numpy`.
- `install.sh`: as separateur-voix, without models. The venv lives at `~/Library/Application Support/Objekat/venvs/spectral-gain`, and a symlink is made in `Plugins/`.
- `run.sh`: checks `import numpy`, then runs the script.
- `manifest.json`:
  - "Spectral gain", context `object`, menu "Spectral edit…";
  - `requires`: app.info, object.get, object.list, object.add, object.set_mute, solo.get, solo.set, solo.clear, object.render_isolated, job.wait, batch, script.panel.open / wait / close, script.canvas.open / wait / update / set_image / set_layer / set_audio / close.
- `README.md`.

**Pure modules (no socket)**
- `wavio.py`:
  - reads RIFF/RF64, PCM 16/24/32, float32 and the extensible header;
  - `read_wav_int` returns the integer samples;
  - `write_wav(kind = pcm16 | pcm24 | f32)` rounds, clips (returns the count), applies no dither, adds a `fact` chunk for f32, and writes atomically through `.tmp` + `os.replace`.
- `dsp.py`: `hop_for`, `hann`, `frame_count`, `process(x, sr, N, k, gain_block_fn, out_dtype, block = 256)`, `analysis_blocks`.
- `mask.py`, the only home of the gain mathematics:
  - pure Python: `SPACING_MAX` / `SPACING_MIN` / `spacing_for`, `warp`, `profile`, `per_dab_db`, `dab_centres`, `ramp`, `rect_weight_1d`, `is_open`, `gain_at(x, y, ops, world)`, `active_ops`;
  - interpretation: `rect_from_op` and `eraser_from_op` read `params` and the `size_*` fields;
  - numpy part (imported lazily): `gain_grid(ops, xw, yw, world)`, using `searchsorted` patches.
- `image.py`: `build_image` (§3.4).
- `veil.py`: `veil_grid(world)`, `render_veil(G) -> RGBA`, `VeilCache`.
- `canvasfile.py`: `write_cnv`, `write_rgb`, `read_cnv`, `read_rgb`.
- `colormap.py`: `MAGMA`, 768 bytes.
  - Generate it once in a throwaway venv with matplotlib: `cm.magma(np.linspace(0, 1, 256))`, scaled to 0–255.
  - Mark it CC0 in a comment.
  - If matplotlib cannot be installed, stop and ask; never invent a table.
- `decide.py`:
  - `depth_class`: pcm_int 16 → 16; pcm_int 24 → 24; pcm_float 32 → `f32`; anything else → 24;
  - `decide_depth`: the highest;
  - `render_depth`: 16 for the 16 class, 24 otherwise;
  - `rate_counts`;
  - `duration_verdict`: refuse above 600 s, warn above 120 s;
  - `is_mono`: exact L == R;
  - `output_name`: `"%s (spectral)"`;
  - `safe_name`, `unique_path`.
- `make_fixture.py`: writes the two format fixtures to `tools/fixtures/spectral/`.

**`spectral_gain.py`: one connection, one thread**
- The client and `Failure` class are copied from retouche.
- `tr(fr, en, es)` follows `OBJEKAT_LANGUAGE`.
- `--object ID` exists for tests.
- `OBJEKAT_SPECTRAL_CACHE` overrides the work folder, which is `~/Library/Caches/Objekat/spectral-gain/<uuid>`, removed in a `finally`.

1. **Check the object.**
   - Exactly one id.
   - Refuse an aux, an infinite bus, a missing file, a non-positive duration.
   - `duration_verdict` refuses above 600 s.
2. **Read the source formats.** Walk the descendants and call `object.get` on each clip.
   - If the rates disagree, ask with retouche's `choose_rate` panel; Cancel exits 0.
   - With no clips: 48000 Hz, 24-bit.
3. **Open the canvas.** `script.canvas.open` with the controls below, and:
   - tools:
     - `{id: "rect", kind: "rect", label: tr(Rectangle), params: ["gain", "feather_ms", "feather_st"]}`;
     - `{id: "eraser", kind: "stroke", label: tr(Gomme / Eraser / Borrador), icon: "eraser", params: ["amount", "hardness"], size_control: "size_px", hardness_control: "hardness"}`;
   - `object`, `remember: "spectral-gain"`, `busy: true`, status "Rendering…".

   | id | kind | range | default |
   |---|---|---|---|
   | `sec_rect` | section | — | — |
   | `gain` | number, dB | −60…12, step 0.5 | −12 |
   | `feather_ms` | number, ms | 0…200, step 1 | 10 |
   | `feather_st` | number, st | 0…12, step 0.1 | 1 |
   | `sec_eraser` | section | — | — |
   | `size_px` | number, px | 4…200, step 1 | 32 |
   | `amount` | number, dB | −24…−0.5, step 0.5 | −3 |
   | `hardness` | number, % | 0…100, step 1 | 50 |
   | `sec_analysis` | section, advanced | — | — |
   | `fft_size` | choice, advanced | 1024…32768 | "2048" |
   | `overlap` | number, advanced | 2…10, step 1 | 4 |

4. **Render.** Use retouche's solo dance and `object.render_isolated` at the chosen rate and `render_depth`, into `original.wav`.
   - Read it back.
   - Mono = exact L == R; then keep one channel.
5. **First display.**
   - `set_image` with x = `[0, L/sr]` in `"s"`, lin, and y = `[20, sr/2]` in `"Hz"`, log, `value_unit: "dB"`.
   - `set_audio {original: render, result: render, history_rev: 0}`.
   - Status: the long-object warning when `warn`, otherwise the op count.
6. **Loop** on `wait(since_rev, timeout_ms 2000, known_history_rev)`.
   - State no longer `open`: leave the loop.
   - `fft_size` or `overlap` changed: rebuild the base image under a new file name and mark the audio dirty. The veil does not depend on the STFT.
   - History changed:
     1. `update busy`;
     2. compute the veil G (cached) → write `veil-<n>.objkrgb` → `set_layer {layer: "veil", z: 1, history_rev}`;
     3. run `process` → write `result-<n>.wav` and `delta-<n>.wav` (f32, delta = x − y) → `set_audio(result, delta, history_rev)`;
     4. delete files older than n − 1;
     5. `busy false`.
7. **Validate.**
   - Recompute if the result is not current.
   - Write `unique_path(<project>/samples/spectral or ~/Library/Application Support/Objekat/Spectral, safe_name, " (spectral)")` as pcm16, pcm24 or f32, mono or stereo. Report clipped samples on stdout.
   - Re-read `object.get` for the start and the parent.
   - `batch`: `object.add {path, start, group | lane = next_free_lane, name: "<name> (spectral)"}`, then `object.set_mute {ids: [id], muted: true}`.
8. **Cancel or closed:** do nothing. In every case, `finally` closes the canvas and removes the work folder.

---

## 6. Tests

**Python, runs on Linux** (`run_tests.sh [python]`)
- `test_dsp.py`:
  - identity for N from 1024 to 32768 and k from 2 to 10, at ≤ −120 dB in the float64 path;
  - float32 path: error ≤ 4e-7;
  - `hop_for` table;
  - the result does not depend on the block size;
  - a constant −6 dB mask gives exactly `x · 10^(−6/20)`;
  - mono and stereo; lengths that are not a multiple of the hop.
- `test_mask.py`:
  - **profile:** its values;
  - **spacing:** `spacing_for` values, monotone, continuous; **calibration:** the mean of a straight stroke is `amount` for every h and its ripple is ≤ 2 % for every h in [0, 1] (swept in steps of 0.02);
  - **accumulation:** out-and-back gives 2× and three passes 3×; two separate strokes add up;
  - **stillness:** a still hand gives 0 dabs, and dense resampling gives the same dabs to 1e-9;
  - **rectangle:** gain inside, 0 outside, half the gain at an edge with feather, no ramp at open edges, two overlapping −6 dB rects give −12, −60 is applied as −60;
  - **grid:** `gain_grid` equals `gain_at`; the DC bin copies bin 1;
  - **op interpretation:** reading `params` and `size_*`.
- `test_image.py`: the indexed header; a 1 kHz tone lands on its row ±1; 0 dBFS gives an index ≥ 250; silence gives 0; the 8192-column cap; a click survives max pooling.
- `test_veil.py`:
  - the RGBA header and size;
  - the premultiplied alpha formula at G = 0, −6, −60 and +6;
  - grid dimensions;
  - the incremental cache equals a full recompute;
  - the veil for a 2-minute history is computed in under 200 ms (reported, not a hard failure).
- `test_wavio.py`: round trips in 16, 24 and f32, mono and stereo; extensible header; clipping count.
- `test_decide.py`: depth classes; rates; durations at 120, 120.01, 600 and 600.01 s; mono detection.
- `test_fixture.py`: regenerating the format fixtures gives identical bytes.

**Swift standalone, compiled on the Mac from `tools/`**
- `tools/test_script_canvas_geometry.swift`:
  - build: `swiftc -parse-as-library ../objekat/Shared/ScriptCanvasGeometry.swift test_script_canvas_geometry.swift -o /tmp/scg && /tmp/scg`;
  - asserts: warp/unwarp; viewport fit, zoom with a fixed anchor, pan, clamp and minimum span; `size_x = size_pt / pointsPerX`; trace disc spacing of `spacing_for(h)` diameters (¼ at h = 0.3 and below, 1/64 at h = 1), with no discs for a still path; tick count and spacing; the format strings.
- `tools/test_script_canvas_image.swift`:
  - built against `ScriptCanvasImageFile.swift`;
  - asserts: both fixtures parse with the right header fields and the right pixel at (c, r); a wrong magic, a truncated file or a zero dimension throws.

**Headless scenario: `tools/scenario_spectral_gain.py SOCK`**
- Standard library only.
- `SECTIONS=` selects sections.
- Test WAVs are written with `wave` / `struct`; Goertzel and the RGBA reader are pure Python.
- The end-to-end sections are skipped if the script's venv is missing.

- **a. API additions**
  - `object.get` returns `source_*` for a 48 kHz/24-bit file and a 44.1 kHz/16-bit file, and `null` for a group.
  - `object.add` with `name` shows that name.
  - `batch [add, mute]` followed by one `edit.undo` removes the new object and unmutes the original.
- **b. Canvas contract** (the test client plays the script)
  - **Opening:** every `bad_params` case of `open`, including `size_control` missing, on a non-number control, or on a rect.
  - **`set_image`:** a 4 × 2 CNV1 echoes its size; wrong size → `bad_params`; missing file → `not_found`; log axis with min 0 → `bad_params`.
  - **Ops:**
    - rect input → op geometry sorted and clamped, `params` equal the controls;
    - change `gain`, the next op snapshots the new value and the earlier op is unchanged;
    - stroke with `view_scale {x: 500, y: 100}` and `size_px` 32 → `size_x = 0.064`, `size_y = 0.32`, points stored as given;
    - a stroke shorter than 1 pt → `added: false` and `rev` unchanged;
    - point op.
  - **History:** undo and redo move the cursor; a new op after an undo truncates the redo tail.
  - **Layers and reflection:**
    - `set_layer` without a base → `invalid_state`;
    - an RGB1 layer is listed;
    - replacing it keeps z;
    - `path: null` removes it;
    - after adding ops 1 and 2, `unreflected = [1, 2]`;
    - a layer with `history_rev` = the rev after op 1 → `unreflected = [2]`;
    - with the layer at the current rev → `[]`;
    - undo then redo of op 2 → `[2]` again (`active_since` refreshed);
    - a world change drops the layers.
  - **Rev and wait:** `values` moves `rev`, `update` does not; `wait` times out with the same `rev`, then returns at once after an input; `known_history_rev` omits the ops.
  - **Audio and transport:**
    - `set_audio` reports the durations;
    - play: `position` advances by ≥ 0.2 s after 0.3 s;
    - switching to `listen: result` keeps the position (Δ < 0.05);
    - seek while playing jumps and moves the caret;
    - **stop returns `position` to the caret**, and running past the end does the same;
    - delta without a slot → `invalid_state`;
    - project `transport.play` followed by canvas play leaves the project stopped.
  - **Remember:** Validate stores; a re-open shows the values; reset restores the declared ones.
  - **No trace in the project:** `is_dirty` is unchanged and `edit.undo` leaves the canvas alone.
  - **Lifetime:** removing the object closes the canvas; closing the second connection removes its canvas; `project.new` closes it.
- **c. End to end**
  - Signal: 2 s, 48 kHz, 24-bit mono, 0.25 sin 300 Hz + 0.25 sin 3000 Hz.
  - Launch `run.sh --object ID`; wait for the canvas, the base image and the `original` slot.
  - Check the world (x [0, 2] lin, y [20, 24000] log) and the defaults 2048 / 4.
  - **Rect:**
    - set `gain` to −24 and draw a rect over x [0, 2], y [2000, 4500];
    - wait until the veil layer's `history_rev` equals `history.rev` and `unreflected` is empty, then until `audio_history_rev` catches up;
    - the veil pixel at (1 s, 3 kHz) has an alpha around 0.75·(1 − 10^(−24/20)) ≈ 0.70 (±0.05), and a pixel at (1 s, 300 Hz) has an alpha of 0;
    - Goertzel on the result: 3 kHz at −24 ± 1 dB, 300 Hz within ±0.2 dB.
  - **Undo:** the result is back within ±0.2 dB.
  - **Eraser calibration end to end:**
    - with gain −24 undone, a stroke at 3000 Hz from x −0.2 to 2.2 with `view_scale {x: 400, y: 32}` (`size_y` = 1 octave);
    - over the middle second, 3 kHz is at −3 ± 0.4 dB;
    - the same stroke again gives −6 ± 0.5 dB.
  - **Expert change:** overlap 8 → the image path changes and the ops are kept.
  - **Validate:**
    - the script exits 0, one new object "tone (spectral)" lies at the same start, the original is muted;
    - a WAV export over the span, compared by Goertzel with a baseline export made before, matches the state at Validate: about 3 kHz down by the eraser's two passes, 300 Hz within ±0.3 dB;
    - one `edit.undo` removes the new object and unmutes the original; the canvas is gone.
- **d. Formats**
  - 44.1 kHz 16-bit mono in → a 44100 Hz, 16-bit, 1-channel file out.
  - Stereo with L ≠ R → 2 channels.
  - Stereo with L == R → 1 channel.
- **e. Refusals and endings**
  - A group spanning 601 s → exit ≠ 0 with the message on stderr, and no canvas.
  - Cancel → the project is unchanged.
  - SIGKILL → the canvas is gone within 10 s.
- **f. No window on the headless pid,** checked with `CGWindowListCopyWindowInfo`.

---

## 7. Ordered commits (branch `feature/spectral-gain`)

| # | commit | verified on |
|---|---|---|
| 1 | `wavio.py`, `dsp.py`, `requirements.txt`, `test_wavio.py`, `test_dsp.py`, `run_tests.sh` | **Linux** |
| 2 | `mask.py` (all gain mathematics) and `test_mask.py` | **Linux** |
| 3 | `canvasfile.py`, `image.py`, `veil.py`, `colormap.py`, `make_fixture.py`, the two format fixtures, `test_image.py`, `test_veil.py`, `test_fixture.py` | **Linux** |
| 4 | Pure Swift: `ScriptCanvasGeometry.swift`, `ScriptCanvasImageFile.swift`, and both standalone tests | written on Linux; **Mac**: tests and a Debug build |
| 5 | Refactor: `ScriptControls` and `ScriptControlsForm`, panel behaviour unchanged | **Mac**: build, `scenario_breath_eval.py` sections b, c, g (and d if the venv exists) |
| 6 | `ClipSourceFormat`, `object.get source_*`, `object.add name`, their docs; scenario section a | **Mac** |
| 7 | `ScriptCanvasImage`, `ScriptCanvasStore`, `Commands+ScriptCanvas`, registration, view-model lifetime hooks. Headless-complete; `ScriptCanvasWindows.attach` comes in step 8. Also the `command_api.md` section and scenario section b | **Mac**: build and section b |
| 8 | Window, plot, traces, cursors, monitor guards, i18n keys, glossary | **Mac**: build, sections b and f, `xcstrings.py check` (which also runs on Linux); then the user's eye |
| 9 | `ScriptCanvasAudition` and the `ExportAudition` visibility change | **Mac**: build; then the user's ear |
| 10 | `spectral_gain.py`, `decide.py`, `test_decide.py`, manifest, `run.sh`, `install.sh`, README; scenario sections c, d, e | unit tests on **Linux**; `py_compile` of the scenario on Linux; end to end on the **Mac** after `install.sh` |
| 11 | `command_api.md` "clients provided" rows; a `CLAUDE.md` entry saying what was verified and what was NOT seen or heard | — |

**`command_api.md` section outline** ("A canvas a script asks for: `script.canvas.*`", placed after `script.panel.*`):
1. purpose and genericity: the app knows gestures, never gain;
2. lifetime and headless behaviour;
3. controls;
4. tools (`rect`, `stroke`, `point`, `hand`), `params`, `size_control` and the conversion from points;
5. axes, mapping and warped lengths;
6. the two image formats and ImageIO;
7. layers and `history_rev`, traces and the `unreflected` rule;
8. op JSON;
9. audio slots and transport, including the caret;
10. each command with its parameters, answer and errors;
11. what is reserved.

Also document the new `object.get` fields next to `channel_mode` (around l.1062), and `object.add`'s `name`.

---

## 8. Risks and open questions

**Risks**
- **R1. About 1,600 lines of Swift written without a compiler** (steps 4–9). The pure code is isolated and tested standalone, the refactor has its own commit, and each layer has its own scenario section.
- **R2. Veil latency.** Writing an RGBA layer of up to 8 MB per history change, then reading it in the app, should stay within 200 ms. `test_veil.py` measures the Python half; the app half is a single file read.
- **R3. Keyboard and mouse leaking between windows.** The step 8 guards cover it. Any future app-wide monitor must also check the window.
- **R4. The aligned audio swap** may click; the fallback is restart-all.
- **R5. Memory.** At the 10-minute ceiling at 96 kHz stereo, about 0.5 GB of float32.
- **R6. The cursor zone over an NSView** may need tuning.

**Decided:**
- Q3: the gain slider runs −60…+12 dB and −60 means −60 dB; feather 10 ms / 1 semitone; size 32 px (4…200); hardness 50 %; per pass −0.5…−24 dB.
- Q7: stop returns to the caret.
- Every other default from revision 1 stands: Q1, Q2, Q4, Q5, Q6, Q8 to Q14.

**New questions for the user** (each with the default applied until you say otherwise):
- **N1. Veil resolution.** It is a fixed grid of at most 4096 columns × 512 rows (about 5 ms per column on short objects, about 29 ms per column at 2 minutes), so a small eraser stroke looks blocky at strong zoom. Default: accept this in v1 and leave the sharper version to detail on demand.
- **N2. Undo while the veil is being recomputed.** For 50–200 ms the old veil still shows the undone op, and the computing indicator is on. Default: accept. Alternative: the app hides layers whose `history_rev` is behind until the new veil arrives.
- **N3. Traces once reflected.** Default: they disappear entirely and the veil alone shows the result. Alternative: keep a faint permanent outline of each active rectangle.
- **N4. Tool icons.** The script names an SF Symbol (`eraser`, `rectangle.dashed`). Default: accept; an unknown name falls back to the kind's icon.
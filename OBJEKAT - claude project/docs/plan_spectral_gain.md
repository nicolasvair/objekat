# Spectral editor: technical plan (`script.canvas.*` and `tools/scripts/spectral-gain/`)

**Inputs read:**
- spec `OBJEKAT - claude project/docs/spec_spectral_editor.md` (confirmed; it is the authority)
- `CLAUDE.md`
- `command_api.md`, sections Undo/batch, Export/`render_isolated`, Third-party scripts, `overlay.*`, `script.panel.*`
- Swift: `ScriptPanelStore.swift`, `ScriptOverlayStore.swift` (holds `CommandCallContext`), `ScriptPanelMemory.swift`, `Commands+ScriptPanel.swift`, `Inspector/ScriptPanelWindow.swift`, `EditViewModel+ScriptOverlay.swift`, `CommandServer.swift`, `Export/ExportAudition.swift`, `TimelineKeyHandler.swift`, `TimeRulerView.swift`, `FirstClickThrough.swift`, `CursorClaim.swift`, `TimelineCursors.swift`, `Commands+Export.swift`, `Commands+Core.swift`, `Commands+Object.swift`, `Commands+Runtime.swift` (batch)
- scripts and tests: `tools/scripts/retouche-externe/*`, `tools/scripts/separateur-voix/*`, `tools/scenario_breath_eval.py`

**Facts that shape the plan:**
- The Xcode project uses synchronized folders. A new `.swift` file under `objekat/` is compiled into the app with no `pbxproj` edit.
- Default actor isolation is MainActor. Pure code is declared `nonisolated enum/struct`, as in `SessionFile` and `CustomColorBatch`.
- The app's `TimelineView` struct shadows SwiftUI's. Always write `SwiftUI.TimelineView`.
- `JSONEncoder` throws on non-finite doubles. No `inf` or `NaN` may ever reach a payload.
- The timeline's local key, scroll and magnify monitors are app-wide and do **not** check the window. With the canvas window key, ⌘Z would undo the PROJECT. This must be guarded (step 8).
- `TimeRulerView`'s mouseDown monitor converts points from any window. It needs a window guard too.
- One connection serves its requests in series, so a script runs one loop: wait → compute → update.
- `batch` gives one undo, but sub-commands cannot reference earlier results. `object.add` therefore needs a `name` param so Validate is a single batch.
- `object.get` has no sample rate or bit depth today. Minimal addition in step 6.
- No numpy on this Linux box. The executor must create a venv in its scratchpad: `python3 -m venv $SCRATCH/sgvenv && $SCRATCH/sgvenv/bin/pip install numpy`. If pip is blocked by the proxy, read `/root/.ccr/README.md`.

---

## 1. Architecture decisions

**D1. A new window kind and store, not an extension of `script.panel`. The control vocabulary and its form are shared by extraction.**
- A panel is a fit-to-content, non-resizable, keyboard-agnostic form whose payload is `values` plus `events`.
- A canvas has things a panel has no business carrying: a resizable window with a plot, gestures, its own ⌘Z/⇧⌘Z, an op history, an image, audio and transport.
- It also needs its own long poll that returns sidebar values AND the history in one answer. Two waits on one serial connection would deadlock the script's loop.
- Store and window are therefore separate: `ScriptCanvasStore` / `ScriptCanvasWindows`. One canvas per connection, independent of that connection's panel.
- Sharing, by extraction with no behaviour change:
  - `ScriptControls`: parse, apply hand values, apply script values, remember key.
  - `ScriptControlsForm`: the SwiftUI rows.
  - `ScriptPanelMemory`: reused as is.
- So `advanced`/Expert, `remember`, Reset, `enabled_by`, `choice`, `progress` and `section` behave identically in both surfaces.

**D2. The app owns the history; ops are stored in data units.**
- Ops are an ordered list plus a `cursor` (number of active ops), with ⌘Z/⇧⌘Z in the window and `input` in headless mode.
- The app resolves tool parameters from the sidebar controls the tool is BOUND to, at gesture time. Each op carries those final values in data units, so the script never re-derives them.
- `x` and `y` are in axis units (seconds, Hz). Lengths (feather, brush diameter) are in **warped units**: axis units on a `lin` axis, **octaves** (log2 ratio) on a `log` axis.
- Expert changes (FFT size, overlap) therefore never invalidate an op.

**D3. Generic axes take `mapping: "lin"|"log"`.**
- Cost is one function pair (warp/unwarp). It keeps the surface generic (spec §8).
- The spectral script only uses x `lin` and y `log`.

**D4. Image file = a tiny raw indexed format (`OBJKCNV1`) carrying the palette and the value range. Any ImageIO file (PNG, JPEG, TIFF) is also accepted, without a value readout.**
- Python writes it with `struct` and numpy only: no PIL, no matplotlib, no zlib.
- The app builds an **indexed `CGImage` directly** (`CGColorSpace(indexedBaseSpace:last:colorTable:)`), with no conversion loop, which matters for Debug performance.
- The pointer readout reads the index byte.
- The colormap lives in the file, so the app stays colormap-agnostic.

**D5. Image caps: width ≤ 16384, height ≤ 4096, width × height ≤ 32 M.**
- The script writes H = 1024 log rows and W = min(frames, 8192) columns (max-pooled over frames).
- A 2-min image at defaults is about 8192 × 1024 = 8 MB.
- No tiling in v1.

**D6. The veil is computed by the app from the ops (not from the script), as a coarse raster of the visible area.**
- One cell = 2 × 2 points. The raster is drawn into the screen rect of the data window it was computed for.
- During pan/zoom the stale raster therefore stays correctly placed at no cost, and is recomputed debounced (60 ms) on a detached task (pure `nonisolated` code).
- A stroke in progress is splatted incrementally, only its new dabs.

**D7. The shared brush and rectangle definition lives in two places:**
- Swift: `ScriptCanvasGeometry.swift`.
- Python: `mask.py`, whose scalar path is pure Python, so a scenario can import it without numpy.
- A committed JSON fixture generated by Python is checked by both a Python test and a standalone Swift test.
- `script.canvas.probe` exposes the app's own field value at a point, so the end-to-end scenario cross-checks app against Python live.

**D8. Audio in the app is a second `AVAudioEngine` with three `AVAudioPlayerNode`s (original, result, delta), started at the same host time.**
- A/B and delta are just node volumes, so switching is instant and sample-aligned.
- A slot's file swap is an aligned re-schedule of that node (play-at a future node time), falling back to restart-all-at-position.
- Output device: the card OBJEKAT itself has open, through `ExportAudition`'s resolvers. Their visibility is widened from `private`; nothing else changes there.
- **Headless: no audio engine at all.** Transport is a wall-clock model in the store, so tests can assert play, seek and A/B.

**D9. Return path = one `batch`:**
- `object.add {path, start, group|lane, name}`, then `object.set_mute {ids:[orig], muted:true}`.
- This needs the additive `name` param on `object.add`, which sets `label` before placement, so no second undo entry.
- It is retouche-externe's placement exactly, but one project undo (spec §6).

**D10. Source format via `object.get` (additive):** `source_sample_rate`, `source_bit_depth`, `source_format` (`"pcm_int"|"pcm_float"|"compressed"`, or `null` for non-clips). Read with `AVAudioFile`. No ObjC++, no engine change.

**No engine patch and no ObjC++ change anywhere in this plan.**

---

## 2. The `script.canvas.*` contract

Every command: `undo: .none`, never dirty, never saved, never in a snapshot. The owner is `CommandCallContext.caller`.

**Lifetime (same as panels):** a canvas ends when:
- `script.canvas.close` is called;
- the owner connection closes (the record is removed);
- its `object` disappears (`pruneScriptOverlays`);
- the document changes (`resetScriptSessionState`).

Ending a canvas also stops its audio and closes its window. A second `open` on the same connection replaces the first canvas (state `closed`).

**Headless:**
- The canvas exists; no window and no audio engine.
- The viewport is a nominal plot of **1000 × 500 points** fitted to the world.
- Transport is simulated by the clock.

### `script.canvas.open {title?, object?, controls?, tools, status?, busy?, remember?}` → `{canvas_id, rev: 0}`
- `controls`: same vocabulary as `script.panel.open`, plus a new optional **`min_label`** (string) on `number`: shown instead of the formatted value when value == min, e.g. "−∞". It is also added to panels.
- `tools`: `[{id, kind: "rect"|"eraser", bind?: {param: "<control id>" | {control, scale}}}]`.
  - Ids are unique, kinds are unique, and the array may be empty.
  - **Hand is always present** (navigation, not an edit) under the reserved tool id `"hand"`.
  - The app names tools by kind through L() keys; tools carry no labels.
  - Semantic params, with their defaults when unbound (value = control value × `scale`, default scale 1):
    - `rect`: `gain_db` (−12), `feather_x` (0, warped-x units), `feather_y` (0, warped-y units).
    - `eraser`: `size_px` (24, clamped 1…1000 points), `amount_db` (−3), `hardness` (0.5, clamped 0…1).
  - Feathers are clamped ≥ 0.
- `remember`: as in panels. Validate stores the hand values, `press: "reset"` restores them, storage is `scriptPanel.<key>`, and it is ephemeral under `--no-recent` or `--headless`.
- `bad_params`, in addition to the control errors:
  - unknown or duplicate tool kind or id;
  - a tool id of `"hand"`;
  - a bind to an unknown or non-`number` control;
  - an unknown param name;
  - a non-finite or zero `scale`.
- `not_found`: unknown object.
- The active tool is the first declared tool, else `"hand"`.

### `script.canvas.set_image {canvas_id, path, x:{min,max,unit?,mapping?}, y:{…}, value_unit?}` → `{width, height, has_values}`
- `unit`: `"s"` gives time ruler formatting, `"Hz"` gives Hz/kHz, anything else is shown as number plus unit. `mapping` defaults to `"lin"`; `"log"` requires `min > 0`.
- The world = these axes. If the world is unchanged, the view is kept (an Expert recompute keeps the zoom); otherwise the view is refit.
- The file is decoded in both modes.
- Errors:
  - `not_found`: missing file;
  - `bad_params`: bad magic or size, dimensions over the caps, `min >= max`, log with `min <= 0`, a non-finite number, ImageIO failure;
  - `invalid_state`: canvas not open.
- Ops are kept.

### `script.canvas.set_audio {canvas_id, original?, result?, delta?, offset?, history_rev?}` → `{slots:{original,result,delta}, durations:{…}, playing, position}`
- Each slot is a path, `null` to clear it, or absent to keep it. Each file is opened with `AVAudioFile` in both modes (`not_found`, or `bad_params` if unreadable).
- `offset`: the x value where file sample 0 plays (default 0).
- `history_rev`: the history revision these files reflect. While `history.rev > audio_history_rev`, the window shows L("canvas.status.computing").
- If playing and a slot's path changed, the slot is swapped at the same position (D8).
- Clearing the slot being heard falls back to listening to `original`; clearing `original` stops playback.

### `script.canvas.update {canvas_id, status?, busy?, values?, labels?}` → `{ok:true}`
Same semantics as `script.panel.update`. **Never moves `rev`.**

### `script.canvas.get {canvas_id, known_history_rev?}` and `script.canvas.wait {canvas_id, since_rev, timeout_ms?, known_history_rev?}`
- `wait` is a long poll identical to the panel's: it answers when `rev > since_rev` or the state is not `open`; at the timeout (≤ 5000, default 1000) it answers without error.
- Reading drains `events`.
- Payload:

```json
{"canvas_id","rev","state":"open|validated|cancelled|closed","values":{},"events":[{"button":"id"}],
 "status","busy","remember":null,"tool":"rect",
 "history":{"rev":3,"cursor":2,"count":3,"ops":[...]},
 "image":{"path","width","height","has_values"}|null,
 "world":{"x":{"min","max","unit","mapping"},"y":{...}}|null,
 "view":{"x0","x1","y0","y1","width","height"},
 "transport":{"playing","position","listen":"original|result","delta":false,
              "slots":{"original":null,"result":null,"delta":null},"durations":{},"audio_history_rev":null}}
```

- `history.ops` lists ALL ops, including undone ones; the active ops are `ops[:cursor]`.
- `ops` is OMITTED when `known_history_rev == history.rev`.
- `view` uses data units, with the plot size in points.
- Op JSON:
  - `{"id":7,"kind":"rect","tool":"rect","x0","x1","y0","y1","gain_db","feather_x","feather_y"}`
  - `{"id":8,"kind":"eraser","tool":"eraser","points":[[x,y],…],"size_x","size_y","size_px","amount_db","hardness"}`
- `id`: a monotonic int per canvas.

### `script.canvas.input {canvas_id, values?, press?, tool?, view?, op?, undo?, redo?, seek?, listen?, delta?, play?}` → `{rev, history_rev, cursor, added}`
This is the HAND's door: the window calls the same store functions. Applied in this order: values, tool, view, op, undo, redo, seek, listen, delta, play, press.

- `op`:
  - `{kind:"rect", x0,x1,y0,y1}` (data units): sorted, clamped to the world, zero-area gives `added:false`.
  - `{kind:"eraser", points:[[x,y]…] (2…20000 points), view_scale?:{x,y}}`, where `view_scale` is points per warped unit (default: the current viewport). A stroke with 0 dabs gives `added:false` and no rev move.
  - Errors: `invalid_state` without a world, or without a tool of that kind; `bad_params` for non-finite values or too few points.
- `undo` / `redo` (bool): no-op at the ends, `added:false`.
- `view` `{x0,x1,y0,y1}`: clamped.
- Transport:
  - `seek`: clamped to [0, the longest slot duration] (offset ignored for the clamp).
  - `listen` `"original"|"result"`: `invalid_state` if that slot is empty.
  - `delta` (bool): `invalid_state` if there is no delta slot.
  - `play` (bool): `invalid_state` if there is no original slot. Play also stops the PROJECT transport.
- `press`: a button id, `"validate"`, `"cancel"`, or `"reset"` (remember canvases only).
- `rev` moves on values, op added, undo, redo and press. It does **not** move on tool, view or transport changes.
- `invalid_state` if the canvas is not open.

### Other commands
- **`script.canvas.probe {canvas_id, x, y}`** → `{gain_db, value}`. `gain_db` is the app's own field (D6/D7) at a data point for the active ops. `value` is the image value there, or `null` (no image, no values, or outside).
- **`script.canvas.close {canvas_id}`** → `{closed:true}`.
- **`script.canvas.list`** → `{canvases:[{canvas_id,title,state,object}]}`. It calls `vm.pruneScriptOverlays()` first, like the panel list.

**Reserved, not implemented:** detail on demand. A future event `{"detail":{x0,x1,y0,y1,width,height}}` in `events` and a `region` field on `set_image`. Document it as reserved; v1 never emits it.

---

## 3. Data formats and shared math

### 3.1 Image file `OBJKCNV1` (little-endian)

| offset | size | field |
|---|---|---|
| 0 | 8 | magic `b"OBJKCNV1"` |
| 8 | 4 | uint32 width W (columns) |
| 12 | 4 | uint32 height H (rows) |
| 16 | 4 | float32 value of index 0 |
| 20 | 4 | float32 value of index 255 |
| 24 | 4 | uint32 reserved = 0 |
| 28 | 768 | palette, 256 × (R,G,B) uint8 |
| 796 | W·H | uint8 indices, row-major, **row 0 = TOP (y max)**, column 0 = x min |

- File size must be exactly 796 + W·H. Extension `.objkcnv`.
- Readout: `v = v0 + idx·(v255 − v0)/255`; index 0 is shown as "≤ v0".
- Rows are uniform in the y axis's WARPED space: row centre `yw = ywmax − (r+0.5)(ywmax − ywmin)/H`. Columns are uniform in warped x.

### 3.2 Axis mapping and viewport
- `warp(v) = log2(v)` for log, `v` for lin; `unwarp` is the inverse.
- Viewport: `x0w,x1w,y0w,y1w` (warped) plus `width,height` (points, y flipped so 0 is the top).
  - `sx = (xw − x0w)·width/(x1w − x0w)`
  - `sy = (y1w − yw)·height/(y1w − y0w)`
  - `pointsPerX = width/(x1w−x0w)`, `pointsPerY = height/(y1w−y0w)`
- Zoom by factor f > 1 (in) around a screen anchor: the anchor's warped value stays fixed, the span is divided by f.
- Clamp: span ≤ world span, span ≥ world span/10000 (x) and /1000 (y), window inside the world.
- **Brush size at gesture start:** `size_x = size_px / pointsPerX`, `size_y = size_px / pointsPerY`. Here "pixels" are points, frozen at mouseDown.

### 3.3 Rectangle field (gain in dB, additive)
- `ramp(t) = 0` for t ≤ 0, `1` for t ≥ 1, else `0.5 − 0.5·cos(π t)`.
- 1-D weight on warped coordinates with `lo = warp(x0)`, `hi = warp(x1)`, feather F:
  - if F == 0: `w = 1` if `lo ≤ v ≤ hi`, else 0;
  - otherwise `w = min(Rlo, Rhi)`, with `Rlo = ramp((v − (lo − F/2))/F)` and `Rhi = ramp(((hi + F/2) − v)/F)`.
  - The feather is **centred on the drawn edge** (open question Q4).
- **Open edges:** an edge on or beyond the world bound in DATA units is open: no ramp, infinite extent.
  - `x0 ≤ world.x.min + 1e-9·(world.x.max − world.x.min)` makes the low edge open; likewise for x1 against the max, and for y.
  - Open low: `Rlo ≡ 1`. Open high: `Rhi ≡ 1`.
- `G += gain_db · wx(xw) · wy(yw)`.

### 3.4 Eraser (cumulative spray in negative), exact shared algorithm
Constants: `SPACING = 0.25` (fraction of the diameter), radius `R = 0.5` in normalised units.

1. Normalise points: `u = warp_x(x)/size_x`, `v = warp_y(y)/size_y` (float64).
2. Dab centres along the polyline at arc lengths `L_k = (k + 0.5)·SPACING`, k = 0, 1, … (k is an integer, never accumulated by repeated addition):

```
acc = 0.0; k = 0
for i in 1..<n:
    du = u[i]-u[i-1]; dv = v[i]-v[i-1]
    L = sqrt(du*du + dv*dv)          # sqrt, NOT hypot, in both languages
    if L <= 0: continue
    while (k + 0.5)*SPACING <= acc + L:
        t = ((k + 0.5)*SPACING - acc) / L
        out.append((u[i-1] + t*du, v[i-1] + t*dv)); k += 1
    acc += L
```

   A still hand deposits nothing. A stroke shorter than SPACING/2 gives 0 dabs, so no op.
3. Tip profile with hardness h ∈ [0,1] and `rho = dist/R`:

```
if rho >= 1: 0
elif rho <= h: 1
else: 0.5 + 0.5*cos(pi*(rho-h)/(1-h))
```

4. Per dab, in dB: `a = amount_db · SPACING / (R·(1 + h)) = amount_db · 0.5/(1+h)`.
   - Calibration: one straight crossing gives `amount_db` at the centre line (∫ p = R(1+h) per side pair, divided by the spacing).
   - Exact for h = 0, 0.5 and 1 (tested away from measure-zero offsets).
   - About 1 % ripple for other h.
5. Field: `G(xw,yw) += Σ_dabs a · p(hypot_norm((xw/size_x − u_d), (yw/size_y − v_d))/R, h)`, computed as `sqrt(du*du + dv*dv)`.
6. Total mask = the sum of all active ops' fields, in dB. Floor −∞: clamp `G ≥ −300` before `10^(G/20)`. No upper cap (Q16).

### 3.5 Veil (presentation only)
- Attenuation (G < 0): RGBA (0, 0.75, 1) with alpha = `0.75·(1 − 10^(G/20))`.
- Boost (G > 0): (0.4, 1, 0.3) with alpha = `0.5·min(1, (10^(G/20) − 1)/3)`.
- Active rect ops get a 1 pt dashed white outline at 60 % alpha.
- In-progress rect: solid outline. In-progress eraser: dabs splatted live.

### 3.6 STFT, mask, image (Python)
- Hann periodic: `w[n] = 0.5 − 0.5 cos(2πn/N)`. `H = floor(N/k + 0.5)`.
- Frames are centred: frame j covers `[jH − N/2, jH + N/2)`, `J = ceil(L/H) + 1`, zero padded. Frame centre time `t_j = jH/sr` (x axis 0 = render start).
- Analysis: `X_j = rfft(w·seg)`. Synthesis: `y += w·irfft(M_j·X_j, N)`, `wsum += w²`. Output `y/wsum` where `wsum > 1e-12`, cropped to [0, L).
- **Streaming in blocks** of 256 frames: finalise samples before the next block's first frame start, keeping only an N-sample tail. Inputs and outputs stored as float32 (C, L); per-block maths in float64 (memory note R5).
- Mask grid: `xw = t_j`; `yw = log2(k·sr/N)` for k ≥ 1; **the DC bin copies bin 1's gain**. The same G for every channel (linked L+R).
- Bins in `yw` are sorted ascending, so dab and rect patches are found by `searchsorted` on the frame times and bin `yw`.
- Image:
  - magnitude per frame per bin = `max(|X_L|, |X_R|)`;
  - each row takes the max over the bins whose centre frequency falls in its [lo, hi) band; if there is none, linear interpolation in magnitude at the row centre frequency;
  - columns are max-pooled over frames `[floor(cJ/W), floor((c+1)J/W))`;
  - `dB = 20·log10(max(m, 1e-12)/(N/4))` (full-scale sine ≈ 0 dB);
  - `idx = clip(round((dB+100)/100·255), 0, 255)`, v0 = −100, v255 = 0, `value_unit "dB"`, palette = magma.
- World for spectral-gain: x [0, L/sr] `"s"` lin; y [20, sr/2] `"Hz"` log. Constant across Expert changes.

### 3.7 Fixtures (committed, generated by `make_fixture.py`)
- `tools/fixtures/spectral/canvas_ops_fixture.json`:
  - `world`;
  - `profile_cases` `[{rho,h,p}]`;
  - `dab_cases` `[{points, size_x, size_y, centres_uv}]` (≥ 6 cases: straight line, zigzag, out-and-back, still points, a single point, dense resampled line);
  - `field_cases` `[{ops:[op JSON], points:[[x,y]…], gain_db:[…]}]` (rects with feather and open edges, eraser at h = 0, 0.5, 1, overlapping ops).
- `tools/fixtures/spectral/canvas_image_small.objkcnv`: 5 × 3, known indices, ramp palette, v0 = −100, v255 = 0.

---

## 4. Swift: files, types, hooks

| file | new / touch | content |
|---|---|---|
| `objekat/Shared/ScriptCanvasGeometry.swift` | new, pure, `nonisolated` | see the type list below |
| `objekat/Shared/ScriptCanvasImageFile.swift` | new, pure | `nonisolated enum ScriptCanvasImageFile { struct Header {width,height,v0,v255,palette:[UInt8]}; static func parse(_ data: Data) throws -> (Header, Range<Int> /*indices*/) }`. Its own `enum ParseError: Error { case magic, size, dims }`; no CommandError, so it compiles standalone |
| `objekat/Shared/ScriptCanvasImage.swift` | new | `final class ScriptCanvasImage { let path; let cgImage: CGImage; let width, height; let indices: Data?; let v0, v255: Float?; let generation: Int; static func load(path:) throws(CommandError) }`. Indexed CGImage for OBJKCNV1, `CGImageSourceCreateWithURL` otherwise. `func value(atColumn:row:) -> Double?` |
| `objekat/Shared/ScriptControls.swift` | new (extraction) | `enum ScriptControls { static func parse(_:) throws -> ([ScriptPanelControl],[String:JSONValue]); static func applyHand(_:to:controls:) throws; static func applyScript(values:labels:to:controls:) throws; static func handValues(_:controls:) -> [String:JSONValue]; static func rememberKey(_ raw: JSONValue?, title: String) throws -> String? }`. Code moved verbatim from `Commands+ScriptPanel.parseControls` and `ScriptPanelStore.input/update/handValues`, same messages, plus `min_label` |
| `objekat/Shared/ScriptPanelStore.swift` | touch | `ScriptPanelControl` gains `var minLabel: String? = nil`. `input` and `update` call `ScriptControls` |
| `objekat/CommandAPI/Commands+ScriptPanel.swift` | touch | use `ScriptControls.parse` / `rememberKey`; ParamSpec text mentions `min_label` |
| `objekat/Inspector/ScriptControlsForm.swift` | new (extraction) | `struct ScriptControlsForm: View { controls; values; expert: Bool; labelWidth: CGFloat = 200; set: (String, JSONValue, Bool /*coalesced*/) -> Void; press: (String) -> Void }`. Rows moved from `ScriptPanelView` (`rows(of:)`, `controlRow`, `inlineGate`, `format`), and `format` honours `minLabel` via `Text(verbatim:)` |
| `objekat/Inspector/ScriptPanelWindow.swift` | touch | `ScriptPanelView` keeps `@State expert` and its bottom bar; its row loop becomes `ScriptControlsForm(...)` |
| `objekat/Shared/ScriptCanvasStore.swift` | new | see "Store" below |
| `objekat/CommandAPI/Commands+ScriptCanvas.swift` | new | `extension CommandRegistry { func registerScriptCanvasCommands() }`: the 10 commands; helpers `canvasPayload(_:includeOps:position:)`, `opPayload(_:)`, `parseTools(_:controls:)`, `parseAxis(_:)` |
| `objekat/CommandAPI/CommandRegistry.swift` | touch | call `registerScriptCanvasCommands()` after `registerScriptPanelCommands()` (line ~258) |
| `objekat/EditViewModel/EditViewModel.swift` | touch | next to `scriptPanels` (line ~249), see the snippet below |
| `objekat/EditViewModel/EditViewModel+ScriptOverlay.swift` | touch | `pruneScriptOverlays`: `scriptCanvases.closeWhereObjectGone`; `scriptSessionEnded`: `scriptCanvases.connectionClosed`; `resetScriptSessionState`: `scriptCanvases.closeAll(reason: .closed)` |
| `objekat/Inspector/ScriptCanvasWindow.swift` | new | see "Window" below |
| `objekat/Inspector/ScriptCanvasPlotView.swift` | new | see "Plot view" below |
| `objekat/Inspector/ScriptCanvasAudition.swift` | new | see "Audio" below |
| `objekat/Export/ExportAudition.swift` | touch (visibility only) | `outputDeviceIDs`, `defaultOutputDeviceID`, `outputDeviceID(named:)` from `private static` to `static`; `deviceName` from `fileprivate` to `static` |
| `objekat/Timeline/TimelineKeyHandler.swift` | touch | first line of the scroll (l.24), magnify (l.351) and key (l.975) monitor closures: `if event.window is ScriptCanvasPanel { return event }` (right click is already window-guarded) |
| `objekat/Timeline/TimeRulerView.swift` | touch | `monitorDown` (l.387): `guard event.window === self.window else { return event }` |
| `objekat/SoundObject/ClipSourceFormat.swift` | new | see "Source format" below |
| `objekat/CommandAPI/Commands+Object.swift` | touch | in `object.get`'s `.clip` branch: `source_sample_rate`, `source_bit_depth`, `source_format` (all `null` otherwise) |
| `objekat/CommandAPI/Commands+Core.swift` | touch | `object.add`: `ParamSpec("name","string",required:false,"Name of the new object (empty = default name)")`; `if let n = try p.optionalString("name"), !n.isEmpty { object.label = n }` before placing |
| `objekat/Resources/Localizable.xcstrings` | touch | new keys, see the i18n list below |

**`ScriptCanvasGeometry.swift` types:**
- `CanvasAxisMapping`, `CanvasAxis {min,max,unit,mapping; warp/unwarp; warpedMin/Max}`, `CanvasWorld {x,y}`.
- `CanvasViewport` (§3.2): `fit`, `zoomedX(by:anchorScreenX:in:)`, `zoomedY`, `panned(dxPoints:dyPoints:in:)`, `clamped(to:)`, screen↔warped conversions.
- `CanvasPoint`, `CanvasRectOp`, `CanvasEraserOp`, `CanvasOpShape`, `CanvasOp {id, tool, shape}`.
- `enum CanvasBrush { spacing, profile(rho:hardness:), perDabDb(amountDb:hardness:), centres(points:sizeX:sizeY:world:) -> [CanvasPoint] /*normalised u,v*/ }`.
- `enum CanvasGainField`:
  - `ramp`, `rectWeight1D(_:lo:hi:feather:openLo:openHi:)`;
  - `gainDb(x:y:ops:world:)` for a data point;
  - `struct Grid {cols, rows, x0w, x1w, y0w, y1w}`;
  - `rasterize(ops:world:grid:) -> [Float]`;
  - `splatRect(_:world:into:grid:)`, `splatDabs(_:sizeX:sizeY:perDabDb:hardness:into:grid:)`.
- `enum CanvasVeil { static func rgba(_ db: [Float]) -> [UInt8] }`.
- `enum CanvasTicks`: nice 1-2-5 ticks for lin and time, ≥ 70 pt apart; on log, decades × {1,2,5} and denser {1…9} when zoomed.
- `enum CanvasFormat`: `time(_:step:)` as `m:ss.mmm` / `s.mmm`; `hertz` as Hz / kHz; `value(_:unit:)`.

**Store (`ScriptCanvasStore.swift`).** Model after `ScriptPanelStore`:
- Types: `ScriptCanvasState`; `CanvasToolKind {rect, eraser}`; `CanvasBinding {control, scale}`; `CanvasTool {id, kind, bindings:[String:CanvasBinding]}`; `CanvasSlot {original,result,delta}`; `CanvasListen {original,result}`; `ScriptCanvasTransport {playing, listen, delta, slots, durations, offset, audioHistoryRev}`; `struct ScriptCanvas {…all observed fields: controls, values, tools, activeTool, rev, state, pendingEvents, status, busy, rememberKey, declared, ops, cursor, historyRev, nextOpID, image, world, transport}`.
- `@Observable final class ScriptCanvasStore` with `private(set) var canvases`.
- `@ObservationIgnored` storage: `viewports: [UUID: CanvasViewport]` and `clocks: [UUID:(anchor: Double, since: Date?)]`. These stay out of observation so pan and the playhead do not re-render the sidebar.
- Hooks: `canvasOpened`, `canvasEnded`, `viewportChanged`, `historyChanged`, `transportChanged: ((UUID) -> Void)?`, `stopProjectTransport: (() -> Void)?`.
- Methods: `open`, `end(_:as:)`, `connectionClosed`, `closeWhereObjectGone`, `closeAll`, `input(_:values:press:coalesced:)` (copy the panel's 30 Hz coalescing), `update`, `read`, `setImage`, `setAudio`, `selectTool`, `viewport(_:)`, `setViewport(_:_:)`, `addRect`, `addEraser(points:scale:)`, `undo`, `redo`, `play`, `stop`, `seek`, `setListen`, `setDelta`, `position(_:)` (auto-stops at the end), `probe`, `boundValue(_:kind:param:)`.
- Appending an op: truncate `ops[cursor...]`, append, `cursor = count`, `historyRev += 1`, immediate rev bump.

**EditViewModel snippet:**

```swift
let scriptCanvases: ScriptCanvasStore = {
    let s = ScriptCanvasStore()
    s.stopProjectTransport = {
        if let session = CommandContext.shared.session, session.isPlaying { session.stop() }
    }
    ScriptCanvasWindows.attach(to: s)
    return s
}()
```

**Window (`ScriptCanvasWindow.swift`):**
- `final class ScriptCanvasPanel: NSPanel`:
  - overrides `performKeyEquivalent`: ⌘Z → `store.undo`, ⇧⌘Z → `store.redo`, return true; read the letter via `charactersIgnoringModifiers`, per the ⌥ trap;
  - overrides `keyDown`: Space (keyCode 49, `flags ∩ heldModifiers` empty) toggles play;
  - `canBecomeKey = true`.
- `@MainActor final class ScriptCanvasWindows: NSObject, NSWindowDelegate`:
  - `static shared`, `attach(to:)`;
  - `show` is guarded by `!LaunchArguments.process.headless`;
  - window style `[.titled,.closable,.resizable,.utilityWindow,.nonactivatingPanel]`, floating, `hidesOnDeactivate`, `becomesKeyOnlyIfNeeded = false`, size 1100 × 660, minimum 720 × 420;
  - `windowWillClose` presses `"cancel"`;
  - owns one `ScriptCanvasAudition` per canvas, created only in `show`; `transportChanged` syncs it; `dismiss` stops it.
- `struct ScriptCanvasView: View`, laid out as:
  - toolbar: tool segmented control (rect / eraser / hand) | undo / redo | play-stop, Original/Result segmented, Delta toggle | Fit | `SwiftUI.TimelineView(.periodic(from:.now, by:0.1))` playhead time | computing indicator;
  - `HStack`: the plot, then a 300 pt sidebar (`ScrollView{ScriptControlsForm(labelWidth:110)}`, status line plus `busy` spinner, Expert / Reset / Cancel / Validate);
  - bottom bar: pointer readout from `@State ScriptCanvasPointer` (`@Observable` x, y, value, gain).
  - Validate is disabled while `busy` or computing. **No Return/Esc shortcuts** (Q8).

**Plot view (`ScriptCanvasPlotView.swift`):**
- `ScriptCanvasPlot: NSViewRepresentable` wrapping `ScriptCanvasPlotNSView: NSView` (`isFlipped`, `acceptsFirstMouse → true`).
- Contents: left ruler 56 pt, top ruler 22 pt, then the surface.
- Draw order: black, image (cropped to integer pixels, `interpolationQuality = .low`), veil CGImage drawn into the screen rect of its grid's data rect, outlines, gesture, playhead, rulers.
- Mouse by tool:
  - rect: rubber band, then `addRect`;
  - eraser: points deduped below 0.5 pt, `scale` frozen at mouseDown, live splat, then `addEraser`;
  - hand: drag pans; a click under 3 pt of travel seeks;
  - a click in the time ruler always seeks.
- `scrollWheel`: plain = pan (dx time, dy frequency); ⇧ = zoom on the axis locked by `TimelineView.ScrollAxisLock` with the timeline's factors (`exp(dx·0.01)`, `exp(dy·0.012)`), anchored at the pointer. `magnify`: time zoom.
- `mouseEntered`: `TimelineCursorKeeper.relinquish()`, so the timeline's late cursor guard cannot fight ours.
- Cursor: in the SwiftUI ZStack, a `Color.clear` frame over the surface only, with `.cursorZone(toolCursor)`. Tool cursors: crosshair, a custom circle `NSCursor` of `size_px` (clamped 4…256), openHand. **Never `NSCursor.set()`**.
- A 30 Hz timer while playing redraws the playhead. Veil recompute is debounced 60 ms on view, size or history change via `Task.detached`, with a generation check.

**Audio (`ScriptCanvasAudition.swift`):**
- `@MainActor final class ScriptCanvasAudition`, with three players → `mainMixer`; device set like `ExportAudition.applyOutputDevice`.
- `play(slots:from:offset:audible:)`: open AVAudioFiles, `scheduleSegment(file, startingFrame:, frameCount:, at:nil)`, then `play(at: AVAudioTime(hostTime: now + hostTime(forSeconds: 0.05)))` on every node.
- `setAudible`: volumes.
- `swap(slot:url:)`: aligned re-schedule from `lastRenderTime` + 0.1 s lead with `play(at: AVAudioTime(sampleTime:atRate:))`; fallback is restart-all.
- `stop`, `position()`.

**Source format (`ClipSourceFormat.swift`):** `nonisolated enum ClipSourceFormat { struct Info {sampleRate:Int; bitDepth:Int?; kind:String}; static func read(atPath:) -> Info? }`.
- Uses `AVAudioFile.fileFormat.streamDescription`: `kAudioFormatLinearPCM` gives pcm_int or pcm_float (via `kAudioFormatFlagIsFloat`) with `mBitsPerChannel`; anything else is `"compressed"` with depth nil.
- Cached on success, like `ClipChannels`.

**i18n keys (fr / en / es):**

| key | fr | en | es |
|---|---|---|---|
| `canvas.title.default` | Toile du script | Script canvas | Lienzo del script |
| `canvas.tool.rect` | Rectangle | Rectangle | Rectángulo |
| `canvas.tool.eraser` | Gomme | Eraser | Borrador |
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

- Reused: `scriptpanel.validate`, `common.cancel`, `scriptpanel.expert`, `scriptpanel.reset`.
- `xcstrings.py set` refuses unknown keys. Add the entries with a one-off Python snippet that imports `tools/i18n/xcstrings.py` `load`/`save` (same JSON format), then run `check` and `orphans`.
- Glossary rows: toile (d'un script) / script canvas / lienzo; gomme / eraser / borrador; original / résultat / différence; spectrogramme / spectrogram / espectrograma.

---

## 5. Python: `tools/scripts/spectral-gain/`

**Dependencies:** numpy only (scipy is not needed). Python ≥ 3.9.

**Plumbing files:**
- `requirements.txt`: `numpy`.
- `install.sh`: like separateur-voix minus the models. Venv at `~/Library/Application Support/Objekat/venvs/spectral-gain`, the first `python3.13…3.9` found, symlink into `Plugins/spectral-gain`.
- `run.sh`: like separateur-voix, checks `import numpy`.
- `manifest.json`:
  - name "Spectral gain", `executable: run.sh`, `context: object`, `menu: [{"title":"Spectral edit…"}]`;
  - `requires`: app.info, object.get, object.list, object.add, object.set_mute, solo.get, solo.set, solo.clear, object.render_isolated, job.wait, batch, script.panel.open/wait/close, script.canvas.open/wait/update/set_image/set_audio/close.
- `README.md`.

**Pure modules (no socket):**
- `wavio.py`:
  - `read_wav(path) -> (float32 (C,L), sr, info{fmt:"pcm"|"float", bits})` handles RIFF/RF64, PCM 16/24/32, float32, `WAVE_FORMAT_EXTENSIBLE`, 24-bit sign extension;
  - `read_wav_int(path)` for exact comparisons;
  - `write_wav(path, data, sr, kind="pcm16"|"pcm24"|"f32") -> clipped_count`: round-to-nearest, clip, no dither, f32 written with a `fact` chunk, atomic via `.tmp` + `os.replace`.
- `dsp.py`: `hop_for(N,k)`, `hann(N)`, `frame_count(L,H)`, `process(x, sr, N, k, gain_block_fn, out_dtype=np.float32, block=256)` (streaming WOLA, §3.6), `analysis_blocks(x, N, k, block)` (yields `(j0, mags_maxLR)` for the image).
- `mask.py`:
  - top level is pure Python (`math`): `SPACING`, `warp`, `profile`, `per_dab_db`, `dab_centres`, `ramp`, `rect_weight_1d`, `is_open`, `gain_at(x, y, ops, world)`, `active_ops(history)`, `op_from_json`;
  - numpy part (imported inside): `gain_grid(ops, times, freqs, world) -> (frames, bins) dB` with bbox `searchsorted` patches and the DC copy.
- `image.py`: `row_bands(H, fmin, fmax)`, `build_image(x, sr, N, k, H=1024, max_cols=8192) -> uint8 (H,W)`, `write_canvas_image(path, idx, v0, v255, palette)`, `read_canvas_image(path)`.
- `colormap.py`: `MAGMA = bytes(768)`.
  - Generate once with matplotlib in a throwaway venv: `(cm.magma(np.linspace(0,1,256))[:,:3]*255).round()`, then embed it as hex.
  - Comment: matplotlib's magma data is CC0 (Smith / van der Walt), AGPL-compatible.
  - If matplotlib cannot be installed, stop and ask; do not invent a table.
- `decide.py`:
  - `depth_class(info)`: pcm_int 16 → 16, pcm_int 24 → 24, pcm_float 32 → `"f32"`, anything else → 24;
  - `decide_depth(infos)`: highest of 16 < 24 < f32;
  - `rate_counts(infos)`;
  - `render_depth(cls)`: 16 if cls is 16, else 24;
  - `duration_verdict(d)`: `"refuse"` if d > 600, `"warn"` if d > 120, else `"ok"`;
  - `is_mono(int_data)`: `C == 1 or array_equal(L, R)`;
  - `output_name(name)`: `"%s (spectral)"`;
  - `safe_name`, `unique_path`.
- `make_fixture.py`: writes both fixtures under `../../fixtures/spectral/`.

**`spectral_gain.py` (main, a single connection, a single thread):**
- Objekat client and `Failure` copied from retouche. `tr(fr, en, es)` driven by `OBJEKAT_LANGUAGE`. `--object ID` overrides `OBJEKAT_OBJECT_IDS` for tests. `OBJEKAT_SPECTRAL_CACHE` overrides the work dir (default `~/Library/Caches/Objekat/spectral-gain/<uuid4>`, removed in `finally`).

1. Exactly one id, else Failure. Refuse aux, infinite bus, missing file, duration ≤ 0. `duration_verdict`: refuse gives a Failure.
2. Formats: walk `object.list` descendants (as retouche) and call `object.get` on each clip for `source_*`. If several rates, run retouche's `choose_rate` panel (Cancel → exit 0). If there are no clips, 48000 / 24.
3. `script.canvas.open`:
   - controls (labels via `tr`): see the table below;
   - tools: `rect` bind `{gain_db:"gain", feather_x:{control:"feather_ms",scale:0.001}, feather_y:{control:"feather_st",scale:1/12}}`; `eraser` bind `{size_px:"size_px", amount_db:"amount", hardness:{control:"hardness",scale:0.01}}`;
   - `object`, `remember: "spectral-gain"`, `busy: true`, status "Rendering…".
4. Render with retouche's solo dance at the chosen rate and `render_depth` into `workdir/original.wav`. Read it. `mono = is_mono(int data)` (if mono, keep one channel).
5. Analysis: `build_image`, `set_image` (x `[0, L/sr]` `"s"` lin; y `[20, sr/2]` `"Hz"` log; `value_unit:"dB"`), `set_audio {original: render, result: render, delta: null, history_rev: 0}`. Status: the long-object warning if `"warn"`, else the op count. `busy: false`.
6. Loop: `wait(since_rev, timeout 2000, known_history_rev)`.
   - State not open: exit the loop.
   - `(fft_size, overlap)` changed: rebuild the image (new file name `image-<n>.objkcnv`), mark audio dirty.
   - History rev changed (or dirty): `update busy`, then `process`, write `result-<n>.wav` and `delta-<n>.wav` (f32, x − y), `set_audio(result, delta, history_rev)`, delete files older than n − 1, `busy false`.
   - "−∞" rule: an op with `gain_db ≤ −60` is evaluated at −120 dB (script semantics, README).
7. Validate:
   - recompute if not current;
   - `cls = decide_depth`; write `unique_path(<project dir>/samples/spectral or ~/Library/Application Support/Objekat/Spectral, safe_name, " (spectral)")` with kind pcm16, pcm24 or f32 (mono if mono); report the clip count on stdout;
   - **re-read** `object.get` (start and parent may have moved);
   - `batch [object.add{path,start,group|lane=next_free_lane,name:"<name> (spectral)"}, object.set_mute{ids:[id],muted:true}]`.
8. Cancel or closed: nothing. `finally`: `script.canvas.close`, rmtree workdir.

**Script controls:**

| id | kind and range | default |
|---|---|---|
| `sec_rect` | section | — |
| `gain` | number −60…12, step 0.5, dB, `min_label` "−∞" | −12 |
| `feather_ms` | number 0…200, step 1, ms | 10 |
| `feather_st` | number 0…12, step 0.1, st | 1 |
| `sec_eraser` | section | — |
| `size_px` | number 4…200, step 1, px | 32 |
| `amount` | number −24…−0.5, step 0.5, dB | −3 |
| `hardness` | number 0…100, step 1, % | 50 |
| `sec_analysis` | section, advanced | — |
| `fft_size` | choice 1024…32768, advanced | "2048" |
| `overlap` | number 2…10, step 1, advanced | 4 |

---

## 6. Tests

**Python (Linux).** Run with `tools/scripts/spectral-gain/run_tests.sh [python]`.
- `test_dsp.py`:
  - identity for N ∈ {1024…32768} × k ∈ 2…10: error ≤ −120 dB relative (float64 path); float32 path max abs error ≤ 4e-7;
  - `hop_for` table;
  - block-size independence (bitwise equal for block 64 and 256);
  - constant −6 dB mask: output = x · 10^(−6/20) to 1e-9;
  - mono and stereo shapes; L not a multiple of H.
- `test_mask.py`:
  - profile values;
  - calibration: a straight stroke through a point (offset 0.1 · s) gives exactly `amount` for h = 0, 0.5, 1 (1e-9) and within 2 % for h = 0.3;
  - out-and-back gives 2 × amount; three passes give 3 × amount;
  - a still stroke has 0 dabs; a dense collinear resampling gives the same dabs (1e-9);
  - two ops add up;
  - rect inside = gain, outside = 0, edge with feather = gain/2, open edges at world bounds have no ramp, two overlapping −6 dB rects give −12;
  - `gain_grid` equals `gain_at` at sampled grid points;
  - DC copy.
- `test_image.py`: header bytes; size; palette; a 1 kHz tone's brightest row = `row_of(1000) ± 1`; 0 dBFS sine gives index ≥ 250; silence gives 0; column cap (W ≤ 8192 for a long input); max-pool keeps a single-frame click.
- `test_wavio.py`: round trips 16/24/f32 mono and stereo; extensible header; clip count.
- `test_decide.py`: depth classes; group max; rate counts; duration 120 / 120.01 / 600 / 600.01; `is_mono` exact vs L ≠ R by one LSB; names.
- `test_fixture.py`: regenerating both fixtures equals the committed files (JSON numbers to 1e-12, image bytes equal).

**Swift standalone (Mac):**
- `tools/test_script_canvas_geometry.swift`. Build from `tools/`: `swiftc -parse-as-library ../objekat/Shared/ScriptCanvasGeometry.swift test_script_canvas_geometry.swift -o /tmp/scg && /tmp/scg fixtures/spectral/canvas_ops_fixture.json`. Assertions:
  - the fixture's profile, dabs and field (1e-9);
  - calibration;
  - warp / unwarp;
  - viewport fit, zoom-anchor invariance, pan and clamp, min span;
  - `rasterize` equals `gainDb` at cell centres;
  - incremental `splatDabs` equals a full `rasterize`;
  - veil alpha at G = 0, −6, −∞, +6;
  - ticks (count and spacing ≥ 70 pt, log decades);
  - `CanvasFormat` strings.
- `tools/test_script_canvas_image.swift`. Build with `swiftc -parse-as-library ../objekat/Shared/ScriptCanvasImageFile.swift test_script_canvas_image.swift`. Assertions: the fixture header, the index at (c, r), and throws on wrong magic, truncation and zero dimensions.

**Headless scenario `tools/scenario_spectral_gain.py SOCK`.** Same style as `scenario_breath_eval.py`: stdlib only; `SECTIONS=` env; test WAVs written with `wave`/`struct`; Goertzel in pure Python; float-wav reader by `struct`; end-to-end sections skipped when `VENV_PY` is absent.
- **a. API additions:**
  - `object.get` `source_*` for 48k/24, 44.1k/16 and a group (null);
  - `object.add name` is shown in `name`;
  - `batch[add+mute]`, then one `edit.undo`: new object gone and original unmuted.
- **b. Canvas contract (the test client is the "script"):**
  - every `bad_params` case of open;
  - `set_image`:
    - an in-test OBJKCNV1 4 × 2 echoes its size;
    - wrong size gives `bad_params`;
    - a missing file gives `not_found`;
    - log with min 0 gives `bad_params`;
  - rect `input` op:
    - the op fields equal the controls × scale;
    - `probe` inside = gain;
    - `probe` at the edge = gain/2;
  - eraser op with `view_scale`:
    - `size_x = size_px / scale.x`;
    - two identical points give `added:false` and no rev move;
  - undo/redo cursor; truncation of redo by a new op;
  - `values` moves rev, `update` does not;
  - `wait` times out with the same rev, then returns at once after an `input`;
  - `known_history_rev` omits ops;
  - `set_audio` durations;
  - transport:
    - play: position advances by ≥ 0.2 s after 0.3 s of sleep;
    - listen=result keeps the position (Δ < 0.05);
    - seek is clamped;
    - delta without a slot gives `invalid_state`;
    - `transport.play`, then canvas play: `transport.state.playing` is false;
  - `remember` (Validate stores, a re-open shows the values, reset);
  - `is_dirty` unchanged, and `edit.undo` after canvas ops does not touch the canvas;
  - lifetime:
    - object removed: state closed;
    - a second connection's canvas is gone after that connection closes;
    - `project.new`: closed.
- **c. Script end to end** (2 s 48k 24-bit mono, 0.25 sin 300 Hz + 0.25 sin 3000 Hz):
  - Launch `run.sh --object ID`. Wait for the canvas, the image and the `original` slot.
  - World x [0, 2] lin, y [20, 24000] log. Defaults fft 2048, overlap 4.
  - Set gain −24, input rect x [0, 2] y [2000, 4500]. Wait until `audio_history_rev == history.rev`.
  - Goertzel on the result file: 3 kHz at −24 ± 1 dB, 300 Hz within ±0.2 dB.
  - Eraser cross-check: input an eraser stroke, then compare `probe gain_db` at 5 points with `mask.gain_at` (imported from the script dir) to 1e-9.
  - Undo (result back: 3 kHz within ±0.2 dB of the original), redo.
  - Overlap 8: the image path changes, ops kept.
  - Validate: exit 0; one new object named "tone (spectral)" at the same start; original muted.
  - `export.run` wav 48k/24 over the span, Goertzel against a baseline export made before: 3 kHz down 24 ± 1.5 dB, 300 Hz ± 0.3 dB.
  - One `edit.undo`: new object gone, original unmuted. No canvas left.
- **d. Format and channels:**
  - a 44.1k 16-bit mono source gives an output file of 44100 Hz, 16-bit, 1 channel;
  - a stereo source with L ≠ R gives 2 channels;
  - a stereo source with L == R gives 1 channel.
- **e. Refusals and endings:**
  - a group of two short clips at 0 s and 601 s gives exit ≠ 0, stderr mentions the limit, no canvas;
  - Cancel: exit 0, project unchanged;
  - SIGKILL: the canvas disappears from the list within 10 s.
- **f. No window:** `Quartz.CGWindowListCopyWindowInfo` on the headless pid returns an empty list.

---

## 7. Ordered commits (branch `feature/spectral-gain`)

| # | commit | verifiable on |
|---|---|---|
| 1 | Python DSP core: `wavio.py`, `dsp.py`, `requirements.txt`, `test_wavio.py`, `test_dsp.py`, `run_tests.sh` | **Linux** (venv + numpy) |
| 2 | Shared brush/rect definition: `mask.py`, `test_mask.py`, `make_fixture.py`, `tools/fixtures/spectral/canvas_ops_fixture.json`, `test_fixture.py` | **Linux** |
| 3 | Image: `image.py`, `colormap.py` (magma CC0), the image fixture, `test_image.py` | **Linux** |
| 4 | Pure Swift: `ScriptCanvasGeometry.swift`, `ScriptCanvasImageFile.swift`, both `tools/test_*.swift` | written on Linux; **Mac**: both standalone tests plus a Debug build |
| 5 | Refactor: `ScriptControls` + `ScriptControlsForm` + `min_label` (panel behaviour unchanged) plus the doc line | **Mac**: build, `scenario_breath_eval.py` (b, c, g; d if venv) |
| 6 | API additions: `ClipSourceFormat`, `object.get source_*`, `object.add name`, docs; scenario sections a | **Mac** |
| 7 | `ScriptCanvasStore` + `Commands+ScriptCanvas` + registration + vm lifetime hooks (headless-complete, no window yet; `ScriptCanvasWindows.attach` stubbed in step 8, so here the store is built without attach); `command_api.md` section; scenario section b | **Mac**: build + scenario b |
| 8 | Window: `ScriptCanvasWindow.swift`, `ScriptCanvasPlotView.swift`, cursors, monitor guards (`TimelineKeyHandler`, `TimeRulerView`), i18n keys + glossary | **Mac**: build, `xcstrings.py check` (also runs on Linux), scenario b + f; then the user's eye |
| 9 | Audio: `ScriptCanvasAudition.swift`, `ExportAudition` visibility, project-transport stop | **Mac**: build; user's ear |
| 10 | The script: `spectral_gain.py`, `decide.py` + `test_decide.py`, manifest, `run.sh`, `install.sh`, README; scenario sections c, d, e | unit tests on **Linux**; `py_compile` the scenario; end to end on the **Mac** after `install.sh` |
| 11 | Docs and memo: `command_api.md` "clients provided" rows, a `CLAUDE.md` "Current state" entry saying what was verified and what was NOT seen or heard | — |

**`command_api.md` text outline** (new subsection after `script.panel.*`: "A canvas a script asks for: `script.canvas.*`"):
1. what it is, and why it is generic;
2. lifetime and headless mode (the nominal 1000 × 500 viewport, the clock transport, no audio device);
3. controls (same vocabulary + `min_label`);
4. tools and bindings table;
5. axes, mapping, warped length units;
6. image formats (OBJKCNV1 table, ImageIO);
7. op JSON;
8. the brush and rectangle definitions (§3.3–3.4 verbatim, with the calibration sentence);
9. veil = presentation;
10. audio slots, A/B/delta, swap, project transport stopped;
11. each command with params, answer and errors;
12. reserved detail-on-demand.

Also: a `min_label` line in the panel section; the new `object.get` fields next to the `channel_mode` paragraph (l.1062); `object.add name`.

---

## 8. Risks, and the questions only the user can decide

**Risks:**
- **R1. About 2 000 lines of Swift written blind** (steps 4–9). Mitigation: pure code isolated and tested standalone, the refactor in its own commit, a scenario per layer.
- **R2. Debug performance of the veil and of the indexed image draw.** Mitigation: 2 pt cells, detached and debounced raster, and a stale raster that stays correctly placed. Fallback if too slow: 4 pt cells while gesturing.
- **R3. Keyboard and mouse leaks between windows.** The guards of step 8 cover them. Any future app-wide monitor must also check the window.
- **R4. The aligned audio swap** (`play(at:)` with a node sample time) may glitch. Fallback: restart all at the same position, with a ~50 ms gap.
- **R5. Memory at the 10-min ceiling at 96 kHz stereo** (about 0.5 GB of float32 buffers). Acceptable for v1, but say so.
- **R6. The CursorZone overlay over an NSView** may need tuning. `TimelineCursorKeeper` is relinquished on entering the plot.

**Questions for the user (each has a default the plan applies until told otherwise):**
- **Q1.** A 32-bit float source: write a 32-bit float result (render at 24) [default], or 24-bit? Other formats (8-bit, 32-bit int, compressed) → 24.
- **Q2.** A group whose files have different bit depths: the highest [default]?
- **Q3.** Defaults and ranges the spec leaves open:
  - feather 10 ms / 1 semitone;
  - eraser size 32 px (4…200), hardness 50 %, per pass −0.5…−24 dB;
  - rectangle gain slider −60…+12, where −60 is shown "−∞" and applied as −120 dB.
- **Q4.** Feather position: centred on the drawn edge [default], or inside or outside the box?
- **Q5.** The image always shows the ORIGINAL spectrogram plus the veil [default]; should there be a "show result" toggle?
- **Q6.** Should starting the PROJECT's transport stop the canvas playback? (Default: no; only the reverse, which the spec asks for.)
- **Q7.** On stop, the playhead stays where it stopped [default], or returns to where play started?
- **Q8.** Keys:
  - Space toggles play, click in the time ruler seeks, and a Hand click without drag seeks [all default].
  - Return and Esc are NOT bound to Validate and Cancel, unlike `script.panel`, so a long editing session cannot be lost by a key [default].
- **Q9.** Validate with an empty history lays an identical copy and mutes the original [default]; or refuse, or treat it as Cancel?
- **Q10.** 16-bit output written without dither (consistent with `render_isolated`) [default], or with TPDF dither?
- **Q11.** The suffix "(spectral)" is kept literal in all three languages, as the spec writes it [default], or localised like retouche's "(retouché)"?
- **Q12.** Brush size counted in screen POINTS, not physical Retina pixels [default].
- **Q13.** Output folder `<project>/samples/spectral/` [default].
- **Q14.** Boosts add up with no ceiling, and samples clipped at the final write are only counted and reported [default]; or cap the sum at +12 dB?

### Critical Files for Implementation
- /home/user/objekat/objekat/Shared/ScriptPanelStore.swift
- /home/user/objekat/objekat/CommandAPI/Commands+ScriptPanel.swift
- /home/user/objekat/objekat/Inspector/ScriptPanelWindow.swift
- /home/user/objekat/objekat/Timeline/TimelineKeyHandler.swift
- /home/user/objekat/tools/scripts/retouche-externe/retouche_externe.py
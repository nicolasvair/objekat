# OBJEKAT — the command API

*The contract for external driving. A living document: `help` is the authority, this file explains.*

---

## What it is

A UNIX socket speaking JSON-lines, through which **everything the interface does can be
asked for from the outside**: a script, a test harness, an assistant. The API is not a
layer running alongside the model — every command calls the method the corresponding
button already calls. That is the condition for it never to lie: there are not two
paths that could diverge.

**Enabling it**: Settings ▸ "Enable the command API" (unchecked by default), or `--api` at
launch (which does not touch the persisted setting — that is the form a harness uses).

**Socket**: `~/Library/Application Support/Objekat/objekat.sock`, or `--socket=<path>`.

> ⚠️ **Two limits that cost dear if ignored.**
> 1. Arguments with a value are written **`--key=value`**, never `--key value`: `NSUserDefaults`
>    pairs each `-` token with the next, the leftover becomes a "file to open"
>    for AppKit, and the app starts **with no window at all**.
> 2. A socket path must be **under 104 bytes** (`sockaddr_un.sun_path`). Beyond that,
>    the system reports nothing whatsoever; the app now refuses explicitly.

---

## The protocol

One request per line, one response per line, UTF-8.

```json
{"id": 1, "cmd": "object.add", "params": {"path": "/sounds/kick.wav", "lane": 2, "start": 4}}
{"id": 1, "ok": true, "result": {"id": "…", "lane": 2, "start": 4, "duration": 1.83}}
```

The parameters can also be laid **flat** beside `cmd`, purely as command-line
ergonomics (`{"cmd": "transport.seek", "seconds": 3}`). As soon as `params` is present, that is
what counts.

On failure:

```json
{"id": 1, "ok": false, "error": {"code": "not_found", "message": "unknown object: …"}}
```

### Error codes — a stable contract

A script must branch on the `code`, never on the `message` (which is English meant for
a human and may be rewritten).

| code | meaning |
|---|---|
| `unknown_command` | the name does not exist in the registry |
| `bad_params` | a parameter is missing, mistyped, or out of range |
| `not_found` | the object, stem, plugin or job named does not exist |
| `invalid_state` | the app is not in a state that allows the operation |
| `engine_error` | the audio engine refused or failed |
| `timeout` | the wait expired (`wait_idle`, `job.wait`) |
| `internal_error` | an untyped error reported by an adapter |

---

## Describing itself

```
help                    → every command, its parameters, its undo policy
help {"name": "…"}      → the detail of a single one
```

**`help` is the source of truth.** The MCP shim generates its tools from it, and nothing in the
repository copies the list out — a duplicated list diverges at the first addition, and nobody
notices before a call fails.

**Hidden aliases.** A command family renamed keeps its old names answering, transparently —
today that is the `consolidate.*` family, whose names were `definition.*` before 24 September
2026. `execute` resolves an alias to its target before dispatch, so behaviour and undo policy are
identical either way; a bare `help` never lists an alias (a script discovering the API fresh is
only ever offered the current name), and `help {"name": "definition.make"}` answers
`consolidate.make`'s own description with an added `"alias_of": "consolidate.make"`, which is how
a script can find the name to move to. Nothing else in the repository is aliased at the moment.

The rename only ever touches what a reader sees — commands, labels, error messages. The
`consolidate.*` family's own response fields, and the session's JSON keys, are a DATA CONTRACT
and keep their historical names on purpose: `consolidate.list`'s `definitions` / `placements`,
`consolidate.state`'s `definition`, `perf.census`'s `object_definitions` / `object_instances`, and
the session file's `definitionID` / `objectDefinitions` / `dependsOn[].definitionID` (@see
`SessionSchema`). A script written against any of these needs no change.

---

## Undo is carried by the bus

A script **never** has to worry about laying an undo entry. Each command declares (and
`help` publishes) one of three policies:

| policy | what happens |
|---|---|
| `none` | a pure read, or a gesture the interface itself does not make undoable |
| `bus` | the bus lays the undo beforehand, and **removes it if nothing moved** |
| `handled` | the method called already pushes its own; wrapping it would make two entries for one gesture |

Two useful consequences: a command that changes nothing does not pollute the stack, **and does not
cost the pending redo** (redoing stays possible after a no-op — the interface does not go that far).

Two gestures are deliberately on `none` although they modify something:
`group.expand` (the interface does not make opening a group undoable) and
`plugin.set_param` (the state lives in the engine instance, it is only captured into the model at
the serialisation points — an undo would put nothing back there, and claiming otherwise would be worse
than abstaining).

---

## Determinism: `wait_idle`, jobs, batches

### `wait_idle`

The model defers a lot of work (sound-object mirrors, re-bake cascades, plugin
scanning). So a read launched just after a write can observe an intermediate state.

```json
{"cmd": "wait_idle", "params": {"timeout_ms": 5000, "settle_ms": 0}}
```

Quiescence **reads the existing state** (`bakingIDs`, `recomputingConsolidateIDs`,
`isCascadingRebake`, `isScanning`, the pending debounced work) instead of instrumenting the
hot paths: no counter to unbalance. In exchange, **the engine's deferred work
stays invisible** — that would take modifying `OBJEngineCore`. Hence `settle_ms`: a grace delay to
ask for explicitly when the measurement that follows depends on the audio graph and not on the model alone.

A `timeout` returns in `details` **what was still in flight**: a wait that expires without
saying what it was waiting for cannot be diagnosed.

### Jobs

Long commands return a `job_id` at once rather than lie about unfinished
work: `plugin.scan`, `consolidate.make`, `consolidate.edit_commit`.

```json
{"cmd": "consolidate.make", "params": {"id": "…"}}      → {"job_id": "job-1"}
{"cmd": "job.wait", "params": {"id": "job-1", "timeout_ms": 30000}}
```

`job.status`, `job.list` complete the set.

**How far a consolidated render has got.** While a bake runs, `consolidate.state` answers
`renders`: one entry per render in flight, `{"kind": "bake", "object": …, "progress": …}` for a
bake or a commit (the object wearing the veil), `{"kind": "rebake", "definition": …, "progress":
…}` for a cascade's automatic re-bake (keyed by the definition, whose instances all show it).
`progress` is 0…1, rounded to the hundredth, `null` until the engine has answered for that render,
and it is the value the filling circle on the block DRAWS — the one store the circles read, not a
second reading of the engine. The list is empty once no render runs. It is the engine's own
`EditRenderer` count (the export's), polled at 10 Hz, so a render shorter than a tick may never
show a reading at all.

### `batch`

Runs a sequence under **a single undo**.

```json
{"cmd": "batch", "params": {"commands": [{"cmd": "…"}, {"cmd": "…"}], "stop_on_error": true}}
```

> ⚠️ **`coalesce` is `false` by default, and must stay so.** Under coalescence, the lane
> flattening cache is frozen for the whole length of the batch: a command that reads it
> works on a stale photograph and **does nothing without saying so** (observed: a coalesced
> `object.duplicate` returns "ok, failed=0" and duplicates nothing). That cache is read in
> around a hundred sites — selection, cut, clipboard, groups, aux, MIDI, sound objects.
> Coalescing gains one cache rebuild; it costs a command that lies.
> Only turn it on for a batch of **pure independent writes**.

### Loading a project — progress, cancellation, reentrance

`project.open`'s contract is unchanged: by default it waits for the whole load (teardown,
structure, plugins, stems/routing, finalise) before answering, exactly as before the progress
overlay existed.

```json
{"cmd": "project.open", "params": {"path": "/…/Project.objekat"}}
→ {"path": "…", "name": "Project", "object_count": 42}
```

`repair_plugin_ids: true` (default `false`) re-keys plugin ids that the file holds under several
hosts — see "Duplicated plugin ids" below.

Pass `"async": true` to get an immediate answer instead, and follow the load with
`project.load_status` and/or `wait_idle`:

```json
{"cmd": "project.open", "params": {"path": "/…/Project.objekat", "async": true}}
→ {"path": "…", "status": "loading"}

{"cmd": "project.load_status"}
→ {"loading": true, "phase": "plugins", "fraction": 0.62,
   "project_name": "Project", "elapsed_ms": 1840,
   "plugin_index": 7, "plugin_total": 11, "current_plugin": "Saturn 2"}

{"cmd": "wait_idle", "params": {"timeout_ms": 30000}}   // also blocks on a load in flight
```

`fraction` is **monotonic** over the whole load (0…1); the weights behind it are fixed
(`0.05`/object, `1` per FX chain compiled, `2` per instrument, `2` for teardown-per-plugin and
finalise) and are **never learned or remembered** from one load to the next. `phase` is one of
`teardown`, `structure`, `plugins`, `stems_routing`, `finalize`; `plugin_index`/`plugin_total`/
`current_plugin` are only present during `plugins`. Once the load is over, `loading` goes back to
`false` and a `last_load` object appears (`success`, `cancelled`, `duration_ms`, `path`, and
`error` on a decode failure) — read it if a poll arrives after the load has already ended.
**Duplicated plugin ids — detected at every load, repaired only on request.** A session whose JSON
was edited outside the app can carry the same `ObjectPlugin.id` under several hosts; the engine holds
ONE instance per id, so only one of them gets the plugin and the others play dry. The load always
DETECTS it and never repairs on its own: `project.open` and `tab.open` take `repair_plugin_ids`
(bool, default `false`). `false` leaves the file's duplicates in the model (the engine copes: the first
host to compile an id keeps the instance, the others play without it, and the operations addressed by
(plugin, host) are refused for a foreign host); `true` gives a fresh id to every later occurrence
(the first keeps its id, the host's automation follows) and the project opens **modified**
(`app.info` `dirty: true`; nothing is written until a save). The API NEVER raises the alert the
interface shows (Repair / Copy report / Don't repair), with or without a window, so `app.dialogs`
stays empty. There is no command to repair after the load: reopen with `repair_plugin_ids: true`.
`last_load` carries:

- `repaired_plugin_ids`: the ids re-keyed (`0` for a sound file, or when not asked to repair);
- `duplicate_plugin_id_count`: how many ids the FILE held more than once (repaired or not);
- `duplicate_plugin_ids`: `[{id, sites: [{host_id, host_kind ("object" | "stem"), host_name,
  plugin_name, fx_link, fx_link_id, json_path, keeps_id}]}]`, in file order — `json_path` is a path
  from the root of the manifest (`items[3].kind.children[1].plugins[0].fxBlock.plugins[2]`,
  `stems[2].plugins[4]`, `….rack.voices[0][2]`, `….instruments[0]`), and `keeps_id` is true on the
  first site only (the entry that keeps its id);
- `plugin_id_report`: a plain-ASCII English text (`null` when the file is sound) that tells a language
  model how to fix the file by hand (new UUID per FIX entry, that object's own automation re-pointed,
  nothing else touched). It is what the alert's "Copy report" puts on the pasteboard.

**While a project is loading, almost every other command answers `invalid_state` ("project
loading")** — the model is being rewritten under it. The only exceptions: `app.info`,
`project.load_status`, `wait_idle`, `app.dialogs`, and `project.cancel_load` (below). `wait_idle`'s
`in_flight` also names `"project loading"` explicitly.

`project.cancel_load` requests that a load in flight stop at its next SAFE point — between two
plugin compiles, never mid-compile — and settle on an empty, coherent project (the same teardown
`project.new` uses). It is an addition to the command surface made to verify the overlay's Annuler
button headlessly; it was not in the original plan's own list of API changes.

```json
{"cmd": "project.cancel_load"}   → {"ok": true}
```

Internally, the engine's graph reallocation is inhibited for the whole of a load
(`OBJEngineCore.beginBulkLoad`/`endBulkLoad`, a thin wrapper around Tracktion's own
`TransportControl::ReallocationInhibitor` — no engine patch). How it gates, read in the
source (24 September 2026): every rebuild request (`Edit::restartPlayback` → its debounce timer →
`TransportControl::editHasChanged`) checks `reallocationInhibitors` first and, while one lives,
only sets `isDelayedChangePending`; `endBulkLoad` then reallocates once
(`ensureContextAllocated` + `restartPlayback`). (`isAllowedToReallocate()` being called from only
two places is beside the point: `editHasChanged` reads the counter directly.) With
`--headless --no-audio` the `[GRAPH] rebuild` log only shows a trivial 2-node placeholder graph
(no device attached, `perf.census.engine_nodes` = null), so the real per-track graph's single
rebuild is established by reading the code, not measured — headless
testing cannot reach it. Each phase's own duration is logged as `[LOAD] <phase> <ms> ms` (the
plugin phase adds `, <n> plugins`), plus `[LOAD] total <ms> ms` at the end
(`[LOAD] cancelled after <ms> ms` on a cancellation) — English, machine-facing, not through `L()`.

### Tabs (`tab.*`) — several projects, one engine

**One `OBJEngineCore`, one `EditViewModel`, several project documents taking turns being the
active one.** A per-tab engine was ruled out: `OBJEngineCore`'s callbacks are
`__unsafe_unretained`, so a second instance — or tearing the one there is down and rebuilding it —
is exactly the crash the project's engine rule exists to prevent. A tab switch is therefore always
the same three moves: park the outgoing document, load the incoming one through the very door a
project opening uses (non-cancellable), unpark what it carried (undo history, selection, cursor,
caret, time selection, loop, viewport).

**The context stays the ACTIVE tab.** Every command outside this family — `object.*`, `plugin.*`,
`transport.*`, `project.get_state`… — keeps reading and writing the session exactly as before;
`tab.*` is the only door onto the workspace itself. `app.info` carries `tab_count` and
`active_tab` alongside its usual fields.

```json
{"cmd": "tab.list"}
→ {"tabs": [{"id": "…", "index": 1, "name": "Mix 1", "path": "/…/Mix 1.objekat",
             "dirty": false, "active": true},
            {"id": "…", "index": 2, "name": "Untitled", "path": null,
             "dirty": true, "active": false}],
   "count": 2}

{"cmd": "tab.new"}                          → the new tab's own object (as above), now active
{"cmd": "tab.select", "params": {"index": 2}}   → that tab's object, now active
{"cmd": "tab.select", "params": {"id": "…"}}    → same, by id

{"cmd": "tab.open", "params": {"path": "/…/Other.objekat"}}           // + "repair_plugin_ids": true, see "Loading a project"
→ {…, "already_open": false}        // opened in a NEW tab
→ {…, "already_open": true}         // was already open elsewhere: switched to it instead

{"cmd": "tab.move", "params": {"index": 3, "to": 1}}   → the moved tab's object, "index": 1
{"cmd": "tab.move", "params": {"id": "…", "to": 2}}    // same, by id

{"cmd": "tab.close"}                             // the active tab, if clean
→ {"ok": true}
{"cmd": "tab.close", "params": {"discard": true}}   // even if modified
{"cmd": "tab.close", "params": {"id": "…", "discard": true}}   // a specific, inactive tab
```

`tab.select`/`tab.close` accept `id` (from `tab.list`) or a 1-based `index` in the SAME order
`tab.list` shows. `tab.close` on the last remaining tab, or on a modified tab without
`"discard": true`, answers `invalid_state`. A switch refused because a render, a DIRECT export (or
any export still `preparing` — a background render on its own copy does NOT block, @see "Tabs and
exports" in the Export section) or a consolidated-object edit is under way (`tab.select`/`tab.new`/`tab.open` all check this BEFORE
touching anything, so a refusal never half-parks a tab) also answers `invalid_state`, naming the
reason in English (`"tab switch refused: an export is running"`, …) — the same four conditions
`Quiescence.inFlight()` already reports for `wait_idle`.

`tab.move` is the tab bar's drag-to-reorder without the hand: the tab named by `id`/`index` ends
up at the 1-based position `to` (`1…count`, anything else is `bad_params`), the others closing up
around it. It changes the ORDER and nothing else — the active tab stays the active one, no
document is parked or loaded — and everything that names a tab by position (`index` here,
⌘1…9, ⌃⇥ / ⌃⇧⇥ in the app) reads the new order straight away. Moving a tab to where it already
is succeeds and changes nothing. It is not refused by an export, a render or a
consolidated-object edit (a reorder touches no document); it IS refused, `invalid_state`, during
the short span of a tab switch itself, when the workspace is between parking one document and
restoring another.

Two commands outside this family are tabs-AWARE without becoming part of it, for backward
compatibility: `project.open` on a path already open in ANOTHER tab switches to that tab instead
of loading a second copy (`{"already_open": true, "tab": "…"}`, everything else unchanged —
reopening the ACTIVE tab's own file still reloads it in place, exactly as before tabs existed);
`project.save_as` onto a path another tab already has open answers `invalid_state` rather than
write over it (writing there would silently orphan whatever that other tab still holds in memory
the next time IT saves).

`tab.list` is one of the few commands still answered while a project is loading (alongside
`app.info`, `wait_idle`, `app.dialogs`, `project.load_status`, `project.cancel_load`) — the tab
strip itself must stay readable through a switch. `wait_idle`'s `in_flight` names `"tab switch"`
for the short span between parking the outgoing tab and the incoming one's own load actually
starting, which `project loading` alone does not cover.

All `tab.*` commands carry undo policy `.none`: switching, opening or closing a tab is a WORKSPACE
operation, with nothing an `EditSnapshot` has anything to say about.

### Measurement

`perf.measure` separates `model_ms` (the model's work) from `frame_ms` (the time during which
the main loop stayed busy afterwards: SwiftUI invalidations, relayout). That
distinction is the heart of the project's measuring method. `perf.census` counts the project.

`perf.census` also carries `regimes`: which regime the timeline's VISIBLE blocks were last drawn in
(`Shared/TimelineRegimeMeter.swift`). A block reaches the screen as a row of the batched Canvas or
as a rich SwiftUI view of its own, and the two cost very differently, so this is the number every
"it is slow with many objects" question starts with. Fields: `clips_canvas`, `clips_rich` (every
block that is not a group and kept a SwiftUI view — an aux and a MIDI clip always do),
`groups_canvas`, `groups_rich` (a group's block, or an infinite group's band), `group_bands_canvas`,
`group_bands_rich` (the tinted inline bands of the open groups — one per OPEN group, culled or not; they are in `group_bands_canvas` in production, `group_bands_rich` only under the Debug A/B switch) — all of them the
counts of the LAST evaluation of the blocks layer, never summed across frames, visible blocks only
(the viewport plus an 80 px margin) — and the two cumulative `passes` (evaluations of the blocks
layer) and `canvas_draws` (draws of the batched Canvas), zeroed by `perf.census {reset: true}`.
`groups_canvas` counts the groups drawn by the Canvas; a group stays rich (`groups_rich`) when it is an infinite bus, renamed, baking, an open consolidated object, under the volume / pan / aux tools (or hovered under the stem tool), previewing a drag / trim / resize / fade, or having one of its loop bounds dragged — and ALL of them under the Debug A/B switch. Zero everywhere in
`--headless` mode: nothing is drawn there. `tools/bench_groups.py` prints them on its `setup` line.

`regimes.rich_reasons` says WHY the rich blocks are rich: a histogram with one entry per block
(`clips_rich + groups_rich` in all), counted in the same loop as the partition, from the very
answer that put the block there — the FIRST rule met, in the order `TimelineView.clipRichReason` /
`groupRichReason` test them, so a block that is both renamed and under the Volume tool counts as
`rename`. Every key is present, at 0 when unused: `tool` (Volume / Pan / Aux armed), `stem_hover`
(Stem tool armed and the pointer on the block), `preview` (a drag / trim / resize / fade under
way — 0 since E7: the Canvas draws the previews, the reason only exists with the fallback
`objekat.timeline.richPreviews` on), `spill` (the neighbour of a spilling fade; same), `midi` (a MIDI clip whose piano roll is open),
`aux` (never produced any more: an aux is drawn by the Canvas, an infinite one counts as `infinite`),
`consolidate` (an instance whose definition is being re-baked), `rename`, `bake`, `loop` (a group
whose IN / OUT bound is being dragged; only with the same fallback), `infinite` (an infinite bus, group or aux), `editing` (an open consolidated object), `force_rich` (the Debug A/B
switch; always 0 in Release). `regimes.foreach_layers` / `foreach_total` give the element count of
each `ForEach` layer of the timeline's body that is evaluated on every pass (`rich_blocks`,
`piano_rolls`, `automation_bands`, `automation_bezels`, `alt_ghosts` — the ⌥-copy's ghosts, 0 unless the
E7 fallback `objekat.timeline.richPreviews` is on) and their sum — an element is the root of
one SwiftUI subtree, so this is the number a layer is paid in. The layers that used to be there and
are now ONE Canvas each, culled to the viewport, no longer report (`lane_rows` and `range_masks` and
`piano_roll_tints` since E1).

`perf.waveforms` snapshots the waveform cache's own counters (mipmaps computed vs. read from
disk, bytes written, region decodes/evictions, in-flight/peak concurrency), plus the current
densities, sample-mode threshold, `.wfc` format version and the project's `waveforms/` folder.
`stereo_mipmaps` counts, among the mipmaps computed or read, those that carry TWO lanes — a
stereo source, drawn as two stacked waveforms (left above, right below); a mono file and a file
of three channels or more carry one. A stereo file weighs twice a mono one in
`peak_bytes_in_memory`, in `bytes_written` and in `region_bytes_in_memory`. Format version 4
(since 25 September 2026) is the one that stores the lanes; a v3 `.wfc` is rejected and
recomputed once.
It answers even with no project open — the counters are process-wide statics — and `reset: true`
zeroes them first, for a bench that wants to measure from a known zero.

`waveform.preload` is the one door a script has onto the peaks: the timeline only ever computes
a waveform when its block is drawn on a Canvas, so a headless run — or a UI run that has simply
never scrolled a file into view — would otherwise measure an empty cache and conclude, wrongly,
that there is nothing to compute. It returns `available: false` (and computes nothing) when the
instance has no interface; `available: true` with a `paths` count otherwise.

---

## Synthetic navigation and frame measurement (`view.*`, `input.*`, `perf.frames.*`)

What these commands are for: **comparing** how the timeline behaves under a scroll or a zoom
in two situations (50 objects against 500, one build against the next). They report raw
distributions and never a verdict.

**UI mode only.** Every command in this family needs the timeline on screen. In `--headless`
there is nothing to scroll and nothing is drawn, so they answer `invalid_state`. By default
each gesture brings the window to the front (`activate: true`); with `activate: false` the
gesture refuses a window that is not key. While a gesture runs, keep your hands off the
trackpad and the mouse: any real event the monitors see during it sets `contaminated: true`
(with `real_events_seen`).

### The hand's own path

A gesture is not a call into the view model. Each command builds real `CGEvent`s: continuous
pixel scrolls with their `began/changed/ended` phases and optional momentum, or keyDown/keyUp
with modifiers. It dates every event on a schedule kept by a dedicated thread, and posts it
through `NSApp.postEvent`. So the events go through the same local `NSEvent` monitors
(`TimelineKeyHandler`) and the same `NSScrollView` as a finger's, including the timeline's
dead zone, its axis lock and the scroll view's own deceleration.

Three facts the implementation depends on, all found by measurement:

- **`CGEvent.postToPid` never delivers** (macOS 15). The `cgevent` route is kept only so that
  `input.selftest` can go on reporting it. `post` is the working route and the default.
- An `NSEvent` built from a `CGEvent` has **no window** unless the event carries one: its
  `window` is nil and the scroll view ignores it, even though the monitors see it. Two fields
  fix this: the raw `CGEventField` 51 (the window number `NSEvent(cgEvent:)` reads) and the
  location in the window, set through the private `CGEventSetWindowLocation` (resolved with
  `dlsym`, and skipped silently if it is ever missing). **These are private API.** If a
  future macOS breaks them, `input.selftest` is the first thing to fail.
- AppKit reads a pixel scroll's deltas as **integer points**. The shapes therefore carry the
  rounding error forward from one event to the next, so the total matches what was requested.
  The **timestamps matter** too: the scroll view uses them for its velocity, so an event left
  undated travels differently (1503 px against 2200 for the same swipe).

`input.selftest` sends a 40 pt swipe on every route and then brings the view back. For each
route it reports whether every event was seen, whether the phases came through, whether the
deltas were precise and whether the view moved. Later gestures use the first route that passes
(`auto`).

**Hover (option B).** A modifier+scroll zoom only applies while the pointer is over the
timeline, and a synthetic event cannot move the real cursor. So `input.scroll` / `input.zoom`
first **lay a hover** through a test hook (`TrackerView.simulateHover`) at `x`, `y` (viewport
points, centre by default), using the same `onHover` path the tracking area uses.
`hover: false` leaves that out: a ⇧-scroll then zooms nothing, exactly as for a hand off the
timeline. `input.hover {x, y}` or `{leave: true}` sets or clears it by hand.

**Settle.** A command answers only once the view is **at rest**: every posted event has been
seen, and then the scroll offset, pps and block height have stayed the same for 150 ms (4 s at
most). The scroll view keeps coasting for about 0.5 s after the last event. `settle_ms` says how
long that took, and `view_after` is read after it.

### The commands

| command | what it does |
|---|---|
| `view.state` | `pps` (6 decimals), `min_pps` / `max_pps` (the zoom bounds: `min_pps` = viewport / max(session end × 1.05, 60 s), floor 1e-4), `block_height`, `scroll_x/y` (read from the view itself), `model_scroll_x/y`, viewport and content size, `visible_time`, `window_key`, `app_active` |
| `view.set` | puts `pps` / `block_height` / `scroll_x` / `scroll_y` directly, not a gesture: the starting point of a measurement. A `pps` outside the bounds is clamped to them (`view.state` answers the result) |
| `view.reveal` | `ids` — brings those objects into view exactly as selecting them in the sound list does (the selection is not touched). The groups hiding them are unfolded (`unfolded` names them; an open automation band is closed to give the content back). One object: scroll only, never a zoom; several that fit in the window: scroll; several that do not: zoom out to ~80 % of the width (within `min_pps` / `max_pps`) then centre. A box already entirely visible moves nothing. Vertically: no zoom, the first lane is brought in (framed by the lane snap when it is active). Answers `view_before` and `view` (a `view.state`). UI mode only: `invalid_state` with `--headless`; `not_found` for an unknown id |
| `input.scroll` | `direction` (`up/down/left/right`) + `distance_px`, or raw `dx`/`dy`; `style: trackpad` (`duration_ms`, `rate_hz`, `momentum`) or `wheel` (`notches`, `interval_ms`); `modifiers` |
| `input.zoom` | `factor`, `axis` (`horizontal/vertical`), `via: shift_scroll` (the timeline's law, e^(0.01·dx), e^(0.012·dy) vertically) or `keys` (`t`/`r` = ×/÷1.5, ⇧ for vertical); answers `requested_factor`, `achieved_factor`, `presses` |
| `input.key` | `key`, `modifiers`, `repeat`, `interval_ms`, `hold_ms`; `claimed` / `claimed_by` says whether a text field or a `KeyboardClaim` owner took it before the timeline |
| `view.state.hover` | what the hover has resolved at the pointer: `position` (canvas) / `viewport` (visible area), the active `tool`, `hovered_id` (the block aimed at, resolved by whichever tool keeps it: `tool_hovered_id` under Volume / Pan / Stem, the block of `zone` under the selection tool — `fadeIn`, `fadeOut`, `trimLeft`, `resizeRight`, `timeSelect`, `move`, `loopIn`, `loopOut` — and `cut_hover {id, local_x}` under Cut; each is null under the other tools), `send_focus` (Aux), `help`, the `cursor` the timeline wants (a name: `arrow`, `iBeam`, `openHand`, `resizeUpDown`, `edge_open_LR`, `fade_in`…, `custom`) and `cursor_owned`. Read-only. The hover resolves inside the hover callback itself, but its redraw does not — `wait_idle` before reading what is on screen. UI mode only |
| `input.hover` | lays or clears the hover (see above) |
| `input.record.start` / `.stop` | records what the timeline's monitors see (real or synthetic), with `t` relative to the first event |
| `input.replay` | replays a recording through the same pump (`speed` stretches time) |
| `input.scenario` | `steps: [{cmd, params} | {wait_ms}]`, measured as a whole plus a report per step (the steps' own `measure` is forced off) |
| `input.drag` / `input.release` | a left-button drag and the release of one kept down (see the E7 note below) |
| `input.selftest` | see above, plus the drag canary |
| `perf.frames.start` / `.stop` | a frame recording wrapped around anything, for long tests (`samples: true` adds every interval) |

Shared parameters of the gestures: `x`, `y`, `route`, `activate`, `hover`, `measure`
(default true), `samples`. Every gesture answers `route`, `events_posted`, `events_seen`,
`pump_duration_ms`, `pump_max_lateness_ms`, `settle_ms`, `contaminated`, `view_before`,
`view_after`, `frames` and `build` (`debug`/`release`: Debug draws the timeline up to ×40
slower, so never compare across the two).

### The vertical lane snap (`vsnap`)

Once a lane's block passes **70 %** of the available height (`viewportHeight − rulerHeight`,
the block measured against — never `laneStep`, the 4 pt gap is not "the lane"), the vertical
view snaps lane to lane instead of scrolling continuously: it settles framed on one, and moving
walks it to the next. The vertical zoom itself is clamped so a lane can never exceed **90 %**.
Completely independent of the TIME snap (`snapEnabled` / `project.set_snap`): nothing about it
reads or writes the grid. The arithmetic lives in `objekat/Timeline/VerticalLaneSnap.swift`
(no view, no model — asserted alone by `tools/test_vertical_lane_snap.swift`); the door onto a
hand's own gesture is the scroll monitor, exactly as ⇧-zoom is.

`view.state` (hence every gesture's `view_before`/`view_after`) carries a `vsnap` object, `null`
with no interface:

| field | meaning |
|---|---|
| `available_h` | the lane area under the sticky header |
| `max_block_height` | the 90 % cap for `available_h` as it stands |
| `lane_step` | `block_height` + the 4 pt gap |
| `ratio` | `block_height / available_h` |
| `active` | `ratio > 0.70` |
| `lane` | the display row currently framed (nearest to the scroll position); `null` when not active |
| `on_grid` | whether the scroll position sits exactly on that lane's own target |
| `pending` | an end-of-gesture re-frame is armed and has not landed yet — `waitViewAtRest` also waits on this, otherwise a test can sample mid-settle |
| `ruler_h` | the sticky header's height, marker rows included |

A trackpad gesture steps **one lane per gesture** (24 pt of travel, momentum swallowed for the
rest of it); a wheel steps **one lane per notch**, notches arriving mid-animation accumulating
onto its target. A horizontal-dominant gesture is left to the ordinary `NSScrollView` untouched.
`caret.step_lane` / `timesel.step_lane` (↑ / ↓) FRAME the lane in snap mode rather than scrolling
the least it takes. `project.save_as` / `project.open` / `tab.*` keep the FRAMED LANE across a
reopen, not the raw scroll pixel it was saved at.

**`debug.resize_window`** (`#if DEBUG`, `Commands+Runtime.swift`) resizes the document window's
frame — the only door a script has onto `available_h` changing (a marker row shown/hidden moves
it too, with no command needed: it is read live). There is no `window_h` on `view.set` — this
already does exactly that, so the plan for this feature does not duplicate it.

**`debug.force_rich_blocks {enabled}`** (`#if DEBUG`, `Commands+Runtime.swift`) is the A/B switch of
the "everything rich" switch of the batched-Canvas work (`Shared/DebugRenderSwitches.swift`): `true`
forces every SELECTED clip back onto the rich SwiftUI view it used to be drawn with, EVERY group block back onto `GroupBlockView`, AND the bands of
the OPEN groups (tint, rise, '+') back onto their old SwiftUI layers; `false` is the production
behaviour (both drawn in the Canvas). It is volatile — it
writes nothing into the user's settings, as a test must not — and answers `{was, enabled}`. The
persistent form is the preference `objekat.debug.forceRichBlocks`, read once at launch:
`defaults write org.labelpeche.objekat objekat.debug.forceRichBlocks -bool YES` then relaunch
(`defaults delete …` to go back), or `-objekat.debug.forceRichBlocks YES` for a single launch.
A Release build has neither the switch nor the command.

**`debug.force_rich_tools {enabled}`** (`#if DEBUG`, `Commands+Runtime.swift`) is the same A/B switch for
the Volume / Pan / Aux tool overlays (`Shared/DebugRenderSwitches.swift`): `true` puts every block
back on its rich view under those tools — the regime before the Canvas drew the overlays, census
reason `tool` — and keeps the Stem tool's old rule (a group hovered, a clip only if selected as well);
`false` is the production behaviour, where only the block aimed at (`tool_hover`) and the blocks a
viewport edge can cut (`tool_span`) stay rich. Volatile, answers `{was, enabled}`; the persistent form
is the preference `objekat.debug.forceRichTools`. A Release build has neither.

**`debug.force_rich_previews {enabled}`** (`#if DEBUG`) flips, volatilely, the fallback of E7
(`Shared/RenderPreferences.swift`): `true` puts the gestures' previews (move, trim, resize, fade,
spill, loop-bound drag) back on the rich views, census reasons `preview` / `spill` / `loop`; `false`
(production) draws them in the batched Canvas from `BlockPreviewGeometry`. Unlike the two switches
above, the persistent form is readable in a RELEASE build: the preference
`objekat.timeline.richPreviews`, read at launch (`defaults write org.labelpeche.objekat
objekat.timeline.richPreviews -bool YES`, or `-objekat.timeline.richPreviews YES` for one launch).

### The frame report

A `CADisplayLink` on the timeline's own view gives one tick per refresh of **that** screen. The
expected interval is read from the link (`targetTimestamp - timestamp`) and never assumed to be
16.7 ms, since ProMotion screens run at 120 Hz. A `CFRunLoopObserver` measures how long each turn
of the main run loop stayed busy, which explains *why* a frame came late. Fields: `frames`,
`duration_ms`, `expected_frame_ms`, `refresh_hz`, `fps_mean`, `frame_ms` (count / p50 / p95 /
p99 / max / mean), `late_frames` (intervals of 2 frames or more), `dropped_frames_est`,
`hitch_ms_per_s`, `main_busy_ms` (a distribution), `main_busy_total_ms`. Each recording is also an
`OSSignposter` interval (subsystem `com.objekat.perf`), so it can be viewed in Instruments.

### Variance, measured (24 September 2026)

- A plain swipe lands on the **same pixel 5 times out of 6**, and one event away otherwise
  (1090 / 1077).
- A ⇧-zoom falls short of the requested factor by at most the timeline's 3-point dead zone
  (×1.954 for ×2). The keys are exact.
- Replaying a recording lands on the **same zoom**. The scroll lands within ±3.5 % when the
  swipe had momentum, in steps of exactly one finger event. The pump's schedule is exact to a
  millisecond or two, so the spread comes from the scroll view folding one event into a
  different frame, and a hand is subject to that too.

### The tool and the colour a harness needs (`tool.*`, `object.set_color`)

Two things nothing headless could set before, and that decide how the timeline draws its blocks
(@see `perf.census.regimes.rich_reasons`): the ACTIVE TOOL and an object's CUSTOM COLOUR (the latter no longer decides the regime).

- `tool.set {tool, stem?}` arms `selection | cut | volume | pan | aux | stem` and writes exactly
  what the ⇧ branches of the key handler (and the palette's buttons) write: `activeTool`,
  `isToolPermanent = true`, `heldToolKeyCode = nil`. It is the LOCKED form on purpose: a held key
  is released by a key-up, and a script has no key to release. `tool.set {tool: "selection"}` is how
  a tool is released; Esc also does. `stem` (1-based, 1 = Main; default 1) goes with `stem` alone.
  `tool.get` answers `tool`, `locked`, `held_by_key`, and for the stem tool `stem` / `stem_name`.
  Session state: undo policy `.none`, never saved.
- `object.set_color {color_index?, ids?}` is `setObjectColor(ids:colorIndex:)` — one undo point for
  the whole batch — with `color_index` 0…15 into the object palette, or absent / null to go back to
  the stem's colour. A coloured clip is drawn by the batched Canvas like any other (its name band and
  its border are part of phase 1), so painting 600 clips no longer puts anything on the rich path.
- **`input.drag` / `input.release` (E7).** A synthetic left-button drag through the app's queue,
  the way `input.scroll` goes: a press, `dragged` events along a straight line, a release. They are
  real `CGEvent`s (`leftMouseDown/Dragged/Up`, click state 1, pressure 1 then 0, one event number per
  gesture) stamped with the same raw field 51 and the private `CGEventSetWindowLocation` as the
  scroll, so `NSApp.sendEvent` hands them to the timeline's window, which hit-tests
  `locationInWindow` and gives them to the same SwiftUI `DragGesture` as a hand's. Parameters:
  `x`, `y` (where the button goes down), `to_x`/`to_y` or `dx`/`dy` (both inside the VISIBLE
  timeline), `duration_ms` (default 600), `rate_hz` (120), `hold_ms` (0), `release` (default true),
  `modifiers`. `release: false` keeps the button down at the end, so the state UNDER the gesture
  can be read (`perf.census`, `view.state.hover`, `object.get`…); `input.release` then lets go at
  the point the drag ended on and answers once the view is at rest. The answer is the usual gesture
  report (`frames` cover the press and the moves, not the release when it is deferred) plus `drag`.
  Traps: (1) the window must be KEY — a press on a window that is not is a "first mouse" that AppKit
  swallows; with the screen locked or the display asleep the app cannot come to the front and the
  command answers `invalid_state` (and `perf.frames` would count 0 frames anyway: `caffeinate -u`
  wakes the display, an unlock is the user's). A merely background app is brought to the front by `open <path>/objekat.app` (LaunchServices; `NSApp.activate` no longer steals the focus on macOS 14+). (2) The drag handlers read the HARDWARE's modifiers
  (`NSEvent.modifierFlags`) and the events' own flags do not change them: a ⌥-copy or a ⇧-drag
  cannot be driven from here. (3) The zone the press falls on decides the gesture, exactly as for a
  hand (the upper half of a block is the time-selection zone, the lower half moves it): aim with
  `view.state.hover`. (4) The mouse monitor that counts the events is installed only while a
  command listens. `input.selftest` ends with a drag canary (`drag` in its answer): a 60 pt drag on an
  empty spot that must reach the monitors, carry the right window and point, and start a gesture (a
  time selection appears; it, the caret, the selection and the cursor are put back); `ran: false`,
  `ok: null` when there is no empty spot or the selection tool is not armed.

### The tools

- `tools/scenario_navigation.py SOCKET`: 43 assertions (the selftest, the directions,
  repeatability, the ⇧-zoom law, no hover means no zoom, the keys, record → replay, perf.frames,
  scenario).
- `tools/bench_navigation.py SOCKET --label L --out F.json [--repeat N]`, then
  `--compare A.json B.json`: the same eight-step walk (scroll in four directions, zoom in and
  out on each axis), each step started from the same view, keeping the median of each metric.
  It warns when the two runs come from different builds.

---

## Dialogues: not freezing a script on a modal

An `NSAlert.runModal()` waits for a click nobody will make. Hence an explicit policy,
carried by the session:

```json
{"cmd": "app.set_dialog_policy", "params": {"policy": "assume_yes"}}
```

`ask` (the default, the interface's behaviour) · `assume_yes` (yes / carry on) · `assume_no`
(no / cancel). To be laid down **at the head of a script**.

Removing the modals and nothing more would be replacing a freeze with a silence: every dialogue settled
automatically is **journalled** and re-readable through `app.dialogs`.

One case is worth knowing: on the "project modified" guard, `assume_yes` means
**carry on without saving**, and not "save". A script that asks to continue wants
to move on; triggering a write it did not ask for would be the opposite of predictable
driving. The explicit path exists (`project.save`, then the operation).

---

## The windowless mode

"No UI" means **no window**, not no AppKit: JUCE requires an `NSApplication` and its
run loop. So the app is indeed there, simply invisible (`.prohibited`), with no SwiftUI scene.

```bash
objekat.app/Contents/MacOS/objekat --headless --no-audio --no-recent \
    --project=/path/project.objekat --exec=scenario.jsonl
objekat.app/Contents/MacOS/objekat --headless --api --socket=/tmp/o.sock
```

| argument | effect |
|---|---|
| `--headless` | no window |
| `--api` | starts the command server |
| `--socket=<path>` | an explicit socket (several instances side by side) |
| `--project=<path>` | opens a project on startup |
| `--exec=<script.jsonl>` | replays a JSON-lines scenario (`#` for a comment, `{DIR}` = the script's folder) |
| `--no-audio` | opens no output device |
| `--no-recent` | writes nothing into "Recent projects" (with or without a window); also keeps the script panels' `remember` memory in the process instead of `UserDefaults` (as `--headless` does) |
| `--language=<fr\|en\|es>` | forces the interface's language for this launch |

Exit codes: `0` success · `1` a command of the script failed · `2` a usage error
(an unreadable project, neither `--api` nor `--exec`, an impossible socket).

### Not polluting "Recent projects"

A test opens and saves throwaway projects. Each one enters "Recent projects", which keeps
only ten: a few scenarios are enough to chase the user's real projects out of it.
`--no-recent` cuts the registering for that launch — the existing list stays **readable** (the
sub-menu still serves to open a real project) but **nothing is written into it**, neither on opening, nor
on saving, nor on clearing. The persisted setting comes back intact on the next launch.

The argument is not reserved for the windowless mode: a trial by hand deserves the same discretion
as an automated harness. `app.info` returns `records_recent_projects` (`false` under `--no-recent`),
enough to check that a discreet instance is indeed the one being driven before having it open anything at
all.

### The interface's language

The app follows the system's language and falls back on English if it is neither French nor
Spanish. `--language=` forces it for ONE launch, which makes a test reproducible whatever
the machine that runs it:

```
objekat.app/Contents/MacOS/objekat --headless --api --socket=/tmp/o.sock --language=es
```

Nothing is persisted: the value lives only in the argument domain of `NSUserDefaults`, which
dies with the process — a test does not move the user's language, just as it does not write
into their "Recent projects". `app.info` returns `language` (the code actually in force).

The API's responses, for their part, are NEVER translated: error messages, command
descriptions and the dialogue journal stay in English whatever the interface's language.
It is a machine contract — a script that tests a response must not depend on the settings of
the machine that hosts it.

**A known reservation**: exiting in the windowless mode goes through `exit()` without
`shutdownJuce_GUI()`; JUCE's leak detector protests in Debug on quitting.
That is end-of-process noise, with no effect on the result.

---

## The command families

`help` gives the exact list. An overview:

| family | what it covers |
|---|---|
| `app.*` | version, current project, engine state, dialogue policy, journal |
| `project.*` | new, open, save, save as, **save a copy with the audio files**, serialised state, the snap, the format notice |
| `transport.*` | play, stop, seek, state (including the **displayed** position: `playhead` is the red line, `displayed` what the time readout shows — the playhead while playing or paused, the cursor while stopped) |
| `selection.*` | all, clear, set, read, **context_click** (the decision of a right click on an object or an empty lane, minus the menu) |
| `object.*` | add, delete, move, duplicate, cut, gain, pan, mute, **colour**, fades **and their shapes**, speed, direction, duration, trim, slip, rename, **infinite**, detail |
| `tool.*` | the timeline's active tool: `tool.set` arms selection / cut / volume / pan / aux / stem, LOCKED as ⇧ + the key does (a script holds no key), `tool.get` reads it |
| `group.*` | create, dissolve, open/close, bring in, take out |
| `stem.*` | list, create, delete, rename, recolour, **reorder**, assign, gain, mute, routing to the Main, level |
| `solo.*` | the confirmed solo: read, set / unset objects, clear — and which windows a direct solo holds open |
| `plugin.*` / `instrument.*` | catalogue, chain, add, remove, bypass, move, copy, link, unlink, parameters, **a selection of several cards** |
| `fxlink.*` | **FX links**: a named bin of plugins several objects or buses share — create, edit the definition, output section, attach / detach / reattach / release |
| `aux.*` / `send.*` | create an auxiliary, lay and set sends |
| `midi.*` | create a clip, list/add/delete/modify notes, transpose |
| `consolidate.*` | consolidated objects: creation, editing, deconsolidating (the old `definition.*` names still answer, as hidden aliases — see below) |
| `export.*` | render the mix into a file (or one file per region), follow the progress and the waveform as it grows, cancel |
| `crossfade.*` | open the seam between two neighbours into a crossfade, resize it, shut it, list them |
| `marker_lane.*` / `marker.*` | the rows of the marker band, and the markers and regions on them — including picking several (`marker.select`, `marker.selection`, `marker.remove_selected`) |
| `object.add_marker` … | the markers an OBJECT carries, in its own frame of reference |
| `comment.*` | free texts laid over a span of the timeline |
| `timesel.*` / `clipboard.*` | time selection, copy, cut, delete, **ripple delete**, group, paste |
| `audio.*` | the output device really in use — status, the list, switching device / rate / buffer |
| `wait_idle`, `batch`, `job.*`, `perf.*` | determinism and measurement |

### A selection of plugin cards

The signal view picks several cards at once — a rectangle drawn on the canvas, ⇧ for the box that
holds them, ⌘ one by one — and then acts on the lot. What the mouse does there is geometry and
stays in the view; what it RESULTS IN is a selection that lives in the model, which is what these
commands drive.

| | |
|---|---|
| `plugin.select` | `host` + `plugins` (a list) + `mode`: `replace` (default) · `add` · `toggle` |
| `plugin.selection` | what is selected, IN THE CHAIN'S ORDER, plus `host`, `has_keyboard`, `clipboard` |
| `plugin.deselect` | clears it, and gives the keyboard back to the timeline |
| `plugin.remove_selected` | ⌫ — every selected card, in one undo step |
| `plugin.toggle_selected` | on/off over the lot, in one undo step. Mixed states go to OFF: one still on turns them all off |
| `plugin.duplicate_selected` | ⌘D — independent copies, just after the LAST selected card, in ITS series |
| `plugin.copy_selected` / `plugin.paste` | ⌘C / ⌘V, through a clipboard of their own |
| `plugin.drop` | the DROP itself — `mode` move/copy/link — onto an object or onto a bus's strip; `plugin` may also be an FX link's BLOCK id (what the bin's header carries); answers `outcome`, `refused`, `reason` |
| `plugin.drop_at` | the same drop at a PLACE of a host's chain — `series` (`"root"`, `{"block": id}` = into a bin, `{"voice": id, "index": n}` = a parallel branch) and `at` — with `dry_run` returning the resolver's `outcome` and refusal `reason` without touching anything |

Three things are worth knowing before driving them:

- **The order of a batch is the CHAIN's, never the caller's.** A selection has no order of its own,
  and plugins laid down in the wrong one are a different sound. `plugin.selection` therefore answers
  in reading order, parallel branches walked in place — not in the order they were named.
- **One undo step per gesture, not one per card.** `plugin.move` with three plugins is one `edit.undo`
  away from being back — and so is a bypass over five, which since 15 September 2026 pushes a point
  where it used to push none. A realtime flag is not an edit on the graph, but it changes what is
  HEARD, and that is what qualifies a gesture for ⌘Z (`plugin.toggle` likewise, and it moved from
  `undo: .bus` to `.handled` because the method now pushes its own).
- **A bus is aimed at by its STRIP.** A stem has no block of its own in the timeline, so the strip
  in the toolbar is the only thing a hand can drop a card on; `plugin.drop` is that door for both
  targets, and what it adds over `plugin.move|copy|link` is the modifier reading and the selection
  following its cards into the chain it landed in.
- **The selection carries the KEYBOARD.** As long as it names a host, ⌫ ⌘C ⌘V ⌘D aim at the cards
  rather than at the timeline's objects. `plugin.select` with an empty list therefore means something
  precise — claim the keyboard for that chain, choose nothing — which is what lets `plugin.paste`
  land in a chain that has no card yet to click on. `has_keyboard` reports it.

**What a drop does — one resolver, for the hand and the API alike** (`pluginDropOutcome`; the cursor, the
band at the bottom of the timeline and the drop itself all read it, so what the hand is told is what
happens). `outcome` is one of `move`, `copy`, `link` (a plain plugin: nothing / ⌥ / ⌘; within ONE chain ⌘ is
a plain move), `join_bin` (an instance of an FX link dropped with ⌘ on another host: that host joins the
WHOLE bin), `move_block` / `copy_block` (a block dragged by its header: the target joins the bin and the
source loses its block, or — ⌥ / ⌘ — keeps it; every copy of a bin stays on the bin; a DETACHED block
moves as it is, local output and all, with fresh instance ids), `adopt_into_bin` (a plain plugin let go
INSIDE an attached bin joins its definition: its instance keeps its id, every other member gets one —
from another host it is moved first), `copy_into_bin` (⌥: an independent copy is added to the definition),
`extract_from_bin` (an instance let go OUTSIDE its bin leaves it for EVERY member and stays a plain
plugin: same id, live state) or `refuse` (`reason` says why: ⌘ into a bin, an instance moved onto another
host, a bin onto a host that already holds it or into another bin, a plugin that is linked or already in
a block). A refused drop places nothing and pushes no undo point. Every other outcome is ONE `edit.undo`.

`plugin.move`, `plugin.copy` and `plugin.link` take **`plugins`** (a list) in place of `plugin`: one
card or a whole selection, the same three gestures either way. A link of several ties each card to
its OWN copy — an EQ and a reverb dragged together do not end up sharing their parameters.

### FX links (`fxlink.*`)

An **FX link** is a named bin of plugins that several hosts (objects, or buses) share. What is worth
knowing before driving one:

- **The design is MIRROR INSTANCES**, not one processor fed by many. Every host keeps its OWN engine
  instances of the bin's plugins; the parameters travel through the existing link machinery (an
  instance carries `link_group == the definition plugin's id`). So `plugin.set_param` on any member's
  instance reaches the others, and editing the bin never reloads a live plugin (an instance keeps its id).
- **In a host's chain the bin is ONE entry**, a block (`is_fx_block: true`, with `link`, `detached`
  and its instances under `plugins`). It is placed anywhere between the trims and reordered like any
  other plugin (`fxlink.move_block`, or the synoptic's drop). It carries an **output section** —
  volume, pan, mute — and a **common on/off**, both the bin's while the block follows it.
- **Two kinds of id**, and telling them apart is the family's trap: the DEFINITION plugin's id
  (`plugins[].id` of a link — what `add_plugin` returns and `remove_plugin` / `move_plugin` /
  `set_plugin_enabled` take) and the INSTANCE's id (`members[].instances[].id` — an ordinary plugin of
  one host, the id `plugin.*` and the automation address). `instances[].definition` names the one
  a given instance mirrors.
- **Order, add, remove and on/off are linked to every attached member**; a gesture aimed at an
  attached instance (`plugin.toggle`, `plugin.remove`, a reorder in the synoptic) is a gesture on the
  DEFINITION. An instance is never edited on its own.
- **Detaching is per host** (`fxlink.detach`): the block stays where it is but stops following; the host
  keeps an independent copy with the settings of the moment, and its own output section
  (`fxlink.set_local_output`). `fxlink.reattach` realigns the host on the bin — it adopts the bin's
  settings, never the reverse. `fxlink.release` leaves for good and keeps the plugins as plain ones;
  `fxlink.remove_block` drops the block and its plugins from this host; `fxlink.delete` dissolves the
  bin everywhere (every block replaced by its plugins, inline and independent).
- **Creation**: `fxlink.create {host, plugins}` makes the plugins of ONE series of one host (plain,
  with no manual ⌘-link, none already in a bin) the definition, the host's own instances becoming its
  block at the place of the first (nothing reloads). `fxlink.create {objects}` — the timeline menu's
  last entry — takes the first object (timeline order) with plain plugins as the source, and the
  others receive a block of it at the END of their chain, their own plugins untouched.
- **Automatic creation.** A cut / split, a duplicate, ⌥-copy, a paste or an overlap's fragment of an
  object whose plugins are plain no longer writes a `link_group` on them: the copy joins a NEW bin and
  the original joins it too. (The old manual ⌘-links and their `link_group` are untouched, and cohabit.)
- **Crossing a project** (paste into another tab) and **consolidating** never share a bin: they
  recreate a NEW one from the plugins' states as they were.
- **Undo**: every mutator pushes ONE point (`undo: handled`), the registry restoring with the chains.
  `fxlink.set_output` and `fxlink.set_local_output` are hot (no recompile) — a drag's frames.
- **A resting-state sync backs the parameter mirror up** (external plugins only, same plugin model,
  instance loaded). The mirror carries what the plugin PUBLISHES to the host; a plugin like FabFilter
  Pro-Q 4 keeps other settings (86 parameters the host cannot write, such as a dynamic band's
  "Spectral" switch) in its binary chunk alone, and rewrites some parameters without notifying. So the
  engine also compares CHUNKS: when a member's chunk differs from the reference it held (its chunk at
  the last sync, or at editor opening), that chunk is laid on the other members of its group
  (`restorePluginStateFromValueTree`, then the host-visible parameters are re-read). It is triggered
  ~300 ms after a parameter gesture ends, every 500 ms while an editor of a group of two or more is
  open (the timer only runs then), when such an editor closes, and before every undo snapshot, save and
  copy (`flushLinkedStateSync`). Without `force` it demands STABILITY (no gesture open, same chunk as the
  previous tick — hence two ticks) and skips a plugin model whose two successive reads differ
  ("unstable", learned once); with `force` (close, snapshot, save) it pushes as is. A member that has
  just received a chunk is deaf for 600 ms (its parameter notifications are the echo of the write).
  **Two members' chunks are not byte-comparable**: a plugin re-encodes what it is given (Pro-Q's reads
  back 2798 vs 2802 bytes for the same settings), so assert on a CHANGE propagating, never on equal
  chunks. `flushLinkedStateSync` is not an API command; `fxlink.sync {plugin}` is its repair form for
  a bin whose members had already drifted apart (that instance's chunk prevails, whatever the reference
  says; `pushed` lists the instances overwritten; `undo: none`, marks the project modified).
  `plugin.get_state {plugin, include_chunk?}` reads an external instance's LIVE chunk (`state`: standard
  base64, `size` in bytes; `invalid_state` for a built-in or an unloaded instance). DEBUG builds add
  `debug.plugin_inject_state {plugin, state}` (lays a chunk with no sync and no reference: a change of
  state nothing announced, like a native GUI's), `debug.link_state_tick {plugin, force?}` (one sync tick
  on one instance: `{pushed: [ids], pending}` — wait > 600 ms after a previous push to that instance,
  and call it twice without `force`) and `debug.link_state {}` (`pushes_total`, `pushes` by source,
  `baselines` = reference chunk size per instance, `gesture_open`, `pending`, `unstable_types`,
  `timer_running`). None of them opens an editor, so headless can drive the whole path except the
  editor-bound triggers (timer, close).
  DEBUG builds also add `debug.plugin_id_audit {}` → `{duplicates: [{id, hosts}], count,
  engine_foreign_refusals}`: every plugin id held more than once in the live project (leaves, rack
  carriers, bin blocks and their instances, instruments, bus chains) with the hosts holding it, and
  the number of compiles the engine refused because another host's chain still held the key. A sound
  project answers `0` and `0`; a non-zero `count` mid-session means an in-app path minted a copy
  without fresh ids — or that the project was opened with its duplicates left as they are (the
  default of `project.open`): then `count` is what the file held and `engine_foreign_refusals`
  counts the operations the engine refused for a foreign host.
- **`synoptic.cards {host}`** reads back how the signal view DRAWS each card of a host's chain, in
  reading order: `enabled` (its own bypass), `in_fx_block`, `link_badge` and `linked_style`. Inside a
  bin's block — attached or detached — a card carries no link badge and no linked emphasis (the
  block's frame and header carry the link); a legacy ⌘-linked plugin outside any bin keeps both.
  `greyed` is true for the cards of a block whose common on/off is OFF (the bin's while attached, the
  block's own while detached): the card keeps its own `enabled` and its identity colours and is drawn
  greyed — the plugin's own bypass is never touched.
- **`plugin.link_overlay {plugin}`** answers what the timeline's link overlay (the halo and the star drawn
  while a plugin's editor is open) shows for that plugin: `source` (its object), `members` (the objects
  joined to it), `color_index` (a palette index) and `fx_link` (the bin, or null). For a plugin held by a
  bin's block the colour is the BIN's (`fxlink.set_color`) and the members are the hosts sharing the bin
  through an ATTACHED block (a detached block stands alone, in the bin's colour); for a ⌘-linked or plain
  plugin it is the plugin's own colour (`color_index` on every plugin payload) and its link group.
- `fxlink.list` lists only the bins some block still refers to (an orphan is what a deleted object
  leaves for the undo). Every answer carries `members[]` with `host`, `is_stem`, `block`, `detached`,
  `instances` and, when detached, `local`.

Persisted as the optional `fxLinks` registry of the session file (**format 17**; a file with no key
opens as before; an older build has no notion of the block entry, so a project holding bins is not
meant to be edited by one). `tools/scenario_fxlink.py` (headless, the export + RMS proof that the
ENGINE followed) is the reference for every rule above; `tools/scenario_fxlink_drag.py` (headless, 91
assertions: block and plugin drags, refusals by dry run, one undo each, save / reopen, export at 24 bit)
is the one for the drag gestures.

### Fade shapes

A fade has a length (`object.set_fade`) and a SHAPE (`object.set_fade_curve`), and the two are
independent: a shape laid on an object with no fade changes nothing audible and shows up the moment
one is pulled. A shape is itself two things — a **family**, which way the curve leaves the straight
line, and a **bend**, how far it leaves it:

| | |
|---|---|
| `in` / `out` | the family: `linear`, `convex`, `concave`, `sCurve`, `sCurveInverse` |
| `in_bend` / `out_bend` | 0…1. `0` is the straight line whatever the family, `1` the extreme |

A family with no bend means the full bend; a bend with no family bends the family already there,
which is what lets a script open one curve progressively without naming it again at every step.
`object.get` reports the four as `fade_in_curve` / `fade_out_curve` and `fade_in_bend` /
`fade_out_bend`.

The bend is a **continuum and not five values**: the gesture that lays it down is a vertical travel,
and the curve follows it pixel by pixel. `bend` is what the hand says, 0…1 of that travel; the curve
is driven by the exponent it maps to, `8 ^ bend` — geometric rather than proportional, because that
is what the eye and the ear read as an even progression.

They are **closed forms evaluated per sample**, never automation points: a fade drawn with points
would cost memory proportional to its length, would quantise exactly what the ear hears best (the
start of a fade in), and would have to be redrawn at every trim. A power `a^p` rather than a
quarter-sine or a logarithm: a whole family where those are single shapes, so the bend has somewhere
to go, and it still reaches exactly 0 and 1 at its ends with no clamp pulled out of nowhere at the
silent end.

The convention that makes the vocabulary hold on both edges: the argument is the fade's
**progress**, 0 = silence and 1 = full level, so the outgoing edge reads the time it has LEFT.
`convex` therefore means the same thing entering and leaving — the curve that stands ABOVE the
diagonal, the level reached at once. `concave` is its exact reflection through the diagonal, and the
two S's are the same power applied to each half with the second one turned over (`sCurve` = hollow
then bulge, `sCurveInverse` = the other way round).

Every object wears them, clip and group alike: in this engine ALL fades live in
`ObjWindowFadePlugin` at the tail of the object's chain, and Tracktion's own clip fades are held at
zero on purpose (@see OBJEngineCore.mm) — so there is one shape implementation and not two.

**Two gestures shorten an object, and they do NOT treat its fades alike** — which is worth knowing
before asserting on one.

*Moving an EDGE* — `object.set_duration`, `object.trim`, and the crop / trim handles under the hand
— **does not change the size of a fade**. A fade belongs to the edge it is anchored to and travels
with it: crop an object whose fade-out lasts a second and it still lasts a second, against the new
end. The only thing that can shorten it there is the object becoming too short to hold both fades,
which is a physical limit and not a rule of its own. Pulling the edge back OUT likewise leaves the
fade alone.

*Taking MATTER away* — `timesel.delete` over an object's head or tail, `object.ripple_cut --keep
left`, a relink onto a shorter file — **shortens the fade by exactly what went**. A fade-out starts
at a point IN the sound, not at a distance from the edge: that point stays opposite the same
material and the fade ends earlier, still reaching silence; a fade-in keeps the instant it reaches
full level and starts later. A deletion PAST the curve's far end leaves no fade at all — the whole
of it was inside the piece that went. In both cases the SHAPE is untouched (`fade_in_curve` /
`fade_out_curve` are separate fields): a shorter fade is the same curve read over less room.

*DIVIDING the matter* — `object.split_at`, the cut by dragging, a hole pierced by `timesel.delete`
or by an object dropped over another — is neither. Each half keeps the edge it already had, fade
and SHAPE, and gains a NEW one at the cut: the fade-out goes with the right-hand half, the one that
still ends where it ended, the fade-in with the left, and the two faces of the cut are born bare.
Bare means the shape too (`fade_out_curve` / `fade_out_bend` back to `linear` / `0` on the left
half, `fade_in_*` on the right): a curve left on a fade of no length shows nowhere and would come
out bent the first time that edge was pulled. It is the rule of the double click that clears a
fade, which clears its shape with its length.

**A division does not re-aim the SELECTION either — the selection follows the matter.** An object
that was not selected has none of its pieces selected afterwards: a cut is not a pick. An object
that WAS selected hands its selection to whichever piece survives it; when an oriented cut (`keep`)
leaves only one, that one gets it, there being no other candidate. When BOTH halves survive (a
plain division, `keep` absent), the selection goes to the SHORTER one — cutting is most often done
to throw a small scrap away (a breath, a click, a count-in), and handing the selection to the piece
about to be discarded saves the click that would otherwise follow. A tie goes LEFT, and costs
nothing: the left half always keeps the object's own id (every branch of the split hands the fresh
UUID to the right piece, never the left), so "equal duration → left" does not even touch
`selection.get`'s answer. An object selected but not itself among the ones cut is left exactly as
it was. The rule holds for `object.split_at` (oriented or not) and for `object.ripple_cut` alike —
neither empties the selection outright the way a naive "cut clears the selection" would.

`object.split_at` takes an optional `keep` (`"left"` / `"right"`, same vocabulary as
`object.ripple_cut`'s) for the oriented cut — absent, it is a plain division and both halves stay.
Its answer keeps `ids` naming the PIECES the cut produced, as it always has (not the selection,
which the cut may or may not have touched), and gains a `selection` field — the selection as it
stands right after, for a caller that wants to check the rule above without a screen.

### The channel choice of a stereo clip (`object.set_channel_mode`)

A stereo audio clip — a file of **exactly two channels** — can be heard through one of its channels
only, non-destructively and per clip:

| `mode` | what is heard |
|---|---|
| `lr` | the clip as it is (the default) |
| `l` | the LEFT channel alone, on both sides |
| `r` | the RIGHT channel alone, on both sides |
| `c` | the mono sum `(L + R) / 2`, on both sides |

`object.set_channel_mode {id, mode}` refuses anything that is not a stereo audio clip with
`invalid_state` and a message naming the failed condition (a mono or multichannel file, a group, an
aux, a MIDI clip, a consolidated instance, a file that cannot be read); an unknown `mode` is
`bad_params`. `lr` is a way back and is accepted on any clip. One undo point, and none at all when
nothing changes (`undo: handled`). `object.get` answers `channel_mode` (the model), `channels` (the
SOURCE file's channel count, `null` for anything that has no file) and `engine_channel_mode` (what
the engine is really playing, on a clip) — a script can assert that the model and the engine agree,
after an undo above all.

The engine carries it as a small service plugin, `ObjChannelMode`, at the HEAD of the clip's chain —
before the trims, the effects and the fader, so what follows works on the channel that was chosen. It
exists only while the mode is not `lr`. Export and consolidation therefore follow with nothing to
do: they render the engine's graph, and a consolidated wave carries the choice baked in (its
placement is `lr` again). The choice follows the clip through a cut, a duplication, a paste
(cross-project included) and a session save/reopen. It is stored as `channelMode` on the clip,
written **only when it is not `lr`** (session format **18**; no key = `lr`, so every earlier file
opens as before, and an earlier build simply ignores the key).

The engine attenuates a centred stereo signal by 3 dB (its pan law), so compare renders **against
the `lr` export of the same clip** and not against absolute levels: `l` and `r` put the kept channel
on both sides at the level that side had in `lr`, and `c` sits 6 dB under `l` for a signal that lives
in one channel only. `tools/scenario_channel_mode.py` is the reference.

### Exploding an object into sub-lanes

**`object.explode {id, cuts:[…], lanes:[…], names?:[…], group_name?, group_lanes?, fade_ms?}`** cuts a plain audio clip at
several instants and gathers the `cuts.count + 1` pieces into a **fresh group**, one sub-lane per
piece — **ONE undo** for the whole thing. Written for the "voice separator" script
(`tools/scripts/separateur-voix/`), generic to any "cut this object into several tagged pieces"
gesture:

| param | meaning |
|---|---|
| `id` | the clip to explode |
| `cuts` | absolute timeline instants, strictly increasing, each strictly inside the object |
| `lanes` | `cuts.count + 1` values — the sub-lane (0-based, **relative to the new group**) each piece lands on; several pieces may share a sub-lane, they simply follow one another on it |
| `names` | optional, one name **per sub-lane** (size = the highest value in `lanes` + 1) — a piece takes the name of the sub-lane it lands on, which is what makes the group's own composed name come out right for free |
| `group_name` | optional, the new group's own label; absent = the composed name |
| `group_lanes` | optional (default false): each sub-lane's pieces are gathered into a collapsed group of their own (labelled by `names`, on that sub-lane), so the new group holds one block per sub-lane instead of hundreds — the timeline draws and hit-tests every block of an open group. The sub-group carries the label; the pieces keep whatever label the source clip had, and `pieces[].child_lane` still names the SUB-LANE of the outer group (each piece sits on row 0 of its own sub-group, so `object.get` on a piece reads `lane: 0`). |
| `fade_ms` | optional number ≥ 0 (default 0 = bare edges, exactly as before): a **crossfade** of that length on every internal cut — see below |

Answers `{"group": <uuid>, "lane_groups": [<uuid>…] (empty unless `group_lanes`), "pieces": [{"id", "start", "duration", "child_lane", "fade_in_ms", "fade_out_ms", "fade_applied_ms"}, …]}`.
`start` / `duration` are the pieces' FINAL geometry (extended by the overlap when `fade_ms` > 0).
`fade_in_ms` / `fade_out_ms` are the crossfade laid on the cut that opens / closes the piece (0 for
the first piece's left edge, the last one's right edge, or with no `fade_ms`); `fade_applied_ms` is
the larger of the two.

**`fade_ms` — the one exception to "interior edges are born bare".** On each internal cut `c`,
`f = min(fade_ms/1000, min(left piece duration, right piece duration) / 3)` (the ceiling `d/3`
keeps a piece's fade-in and fade-out from ever meeting), `h = f/2`. The left piece grows by `h`
to the right and carries a **linear, bend-0** fade-out of `f`; the right piece grows by `h` to
the left (`start -= h`, `sourceOffset -= h × speed`) and carries a linear fade-in of `f`, so the two
overlap by `f` centred on the cut and their gains sum to unity: the group renders the original
sample for sample (a null test). The first piece keeps the original's fade-in and the last one its
fade-out. A **reversed** clip gets no crossfade (`f = 0`); a source offset that could not go back
by `h` shrinks the fade instead of going negative. Everything is done on the pieces' copies before
the group reaches the engine — the fades live in `ObjWindowFadePlugin` as always, no engine patch —
and it is still ONE undo.

Why an app command rather than N × `object.split_at` driven by the script: each cut manufactures
the id the next one has to aim at, so N separate script-driven calls could never be chained into a
single ⌘Z; hundreds of cuts stay one round trip, one `beginPlaybackEdit`, one rebuild; and the
geometry (sub-lanes, fades) stays with the model, which the script does not have to know about.
The chain of splits targets the RIGHT half of the previous cut, in increasing order — the same
edges rule as `object.split_at` applies at each one: the fade-in stays on the very first piece, the
fade-out on the very last, every interior edge is born bare. **Refuses** (`bad_params` /
`invalid_state`): a group or a MIDI clip (only a plain audio clip, v1), a missing file, a looping
object, `cuts` not strictly increasing or one outside the object, `lanes`/`names` the wrong size,
or a resulting piece shorter than 5 ms. It does **not** refuse a changed `speed` or a reversed
clip — `object.split_at`'s own machinery already recomputes source offsets correctly for either;
a caller with a narrower need (like the voice separator, whose detection would not line up with a
resampled or reversed file) enforces that itself before calling, reading `speed` and `reversed` off
`object.get` — which also gained a plain `loop` (bool) field for exactly this: a script refusing a
looping object on its own account, without going through `object.set_loop` (which WRITES the flag
rather than reading it).

### Crossfades

A crossfade is **the zone two neighbours share**, and nothing else. There is no crossfade object and
no flag saying a pair is crossfaded: two objects of one lane overlap, the left one fades out right
across the common zone and the right one fades in across it, and that IS the crossfade. Because it
is pure geometry, saving, reloading and undo carry it with no help, and `crossfade.list` derives it
rather than reads it back.

It is born from the **seam** and from nowhere else. Dropping an object onto another still overwrites
it, exactly as before — the overwrite policy has not moved. What creates a crossfade is taking the
join between two ADJACENT objects and opening it:

    crossfade.open --left UUID --right UUID --width 2.0
    crossfade.open --at 4.0 --lane 0 --width 2.0      # the seam nearest that time
    crossfade.open --left UUID --right UUID --width 0 # shut, same as crossfade.close

Opening is free because OBJEKAT's trim is **non-destructive**: a clip's window is a view on the file
(`sourceOffset` + `fileDuration`), so the matter an earlier trim or overwrite hid is still there.
Opening re-exposes it, it does not fabricate any. Hence the rules a script has to expect:

- the zone opens **symmetrically** when both sides have file left, each giving half the width;
- when one side has none, the other gives the **whole** width — the seam slides rather than refusing;
- when neither has any, it refuses (`no material left on either side`). A group or a MIDI clip has
  no file and therefore no limit: a group opened past its content crossfades into silence, which is
  the answer that was asked for, not an error;
- the width is **clamped, never refused for being too big**: a width is what a hand pulls and a hand
  pulls past the end. Compare `requested_width` with the `zone.width` you were handed. The ceiling
  also keeps each object some matter of its own — a zone that swallowed one whole would not be a
  crossfade but one object hidden under another;
- a **looping** container refuses it, the same rule as the ripple's and for the same reason.

An edge engaged in a crossfade **has no fade length of its own** any more: the zone commands, and
setting the width sets both fades. The SHAPE stays each edge's own business — `object.set_fade_curve`
on each side — which is what lets a crossfade be equal-gain or equal-power at will. The default,
`linear` on both, is equal-gain: the amplitudes sum to exactly 1 across the zone (measured). Exact
equal-**power** is `convex` at a bend of ⅓: the exponent is then 8^(1/3) = 2 and the gain √α, so
α + (1−α) = 1 the whole way (measured, power sum flat to 3·10⁻⁴).

The same moves exist as a gesture on the timeline, and `start` is what expresses them: the zone's
**body** slides the seam (same width, new start) and its **edges** widen or narrow it (new width,
the opposite edge kept). A **vertical** drag bends both curves at once, measured from the object's
own row exactly as on a fade, ⌥ flipping them to the S.

An edge can be taken by two different doors, and they part company at the LIMIT. Taken by the fade
triangle above, the travel left past the shut seam grows a plain fade on the object being held —
the road that made the crossfade, walked backwards. Taken by the CROP band in the lower half, the
same edge is merely being cropped, and cropping grows no fade anywhere in OBJEKAT: it goes on
cropping, and opens the gap a crop opens. Both wear a block's own edge cursor there, arrows
included, and an arrow goes out when the file — or the object's own length — has nothing more to
give.

A crop can push an object clean out of its own crossfade, and coming BACK had to be possible in the
same movement. So a fade pulled outwards looks for a neighbour within its own file's REACH and not
only one it already touches: the travel crosses the gap as an ordinary extension, and only what is
left over opens a zone. `cross_gap: "left"` / `"right"` says the same thing to a script — that
object's facing edge travels across the gap first — and without it a gap is still refused, since two
objects that do not meet have no seam. It is what stopped an edge pulled towards a neighbour it
could not see from simply running over it and having `resolveOverlaps` eat it.

Either way the OPPOSITE edge is **pinned**, and `pin` is what says so. Given only a width, the seam
gives what it can and takes the rest out of whichever side still has it: that is right for opening a
seam — it is what lets a side with no file left still get a crossfade — and wrong under a hand
holding an edge, which watched the zone go on growing out of the end it was not touching. `pin:
"start"` or `pin: "end"` holds that edge of the zone described by `start` and `width`, and clamps
the WIDTH instead. Compare `requested_width` with `zone.width` to know that it bit.

Two more facts about the gesture, neither of which a script can reach (the API has no pointer) —
the arithmetic underneath them is `crossfade.open` with `start`/`pin`, asserted by
`tools/scenario_crossfade_grab.py`. A **fade handle of an object engaged in a crossfade is that
crossfade's side, wherever on the handle band the hand lands**: the band is a quarter of the block
(up to 50 px), the zone is often narrower, and the part of the band beyond the zone used to change
ONE fade and leave the other at the old overlap — which stops the pair being a crossfade. Its
fade-in is the zone's start side, its fade-out the end side; a double click there closes the
crossfade (both fades) like a double click in the zone. And with **several objects selected**, a
drag of a crossfade takes the others of the selection along, by the SAME travel, each keeping its
own width and place: a side drives every selected object's crossfade on that same side, the whole
zone (top and bottom triangles) every crossfade touching a selected object; a zone grabbed with
the object that owns what is held unselected (a side's edge belongs to one object, the whole zone
to both) moves alone, as a fade grabbed on an unselected object does. One undo point for the whole
drag. The decisions are
`Shared/CrossfadeGrab.swift`, asserted by `tools/test_crossfade_grab.swift`.

A crossfade is **created by pulling a fade out past its object's edge** onto the neighbour it
touches: the fade overflows the join, and the overlap it makes IS the crossfade. The join itself is
not a target — it is a line with no surface, exactly where the two blocks' own trim and resize
handles already meet, whereas the fade handle is visible, already under the hand, and says what it
is about to do. Past that edge the travel is bounded by what the CROSSFADE can hold and not by the
object's own file, so a side with nothing left still opens the zone from the other side.

A zone **FOLLOWS the objects that hold it**. `object.move`, `object.trim` and `object.set_duration`
each note the pairs the object belongs to before touching it and re-form them after: move the right
one of a pair 20 px to the right and the overlap loses 20 px off its LEFT — the left object has not
budged, and the zone shortens rather than sliding. **Cropping** that same edge takes exactly as much
off it, for exactly the same reason: a zone is the span the two have in common, and it cannot tell a
displaced edge from a cropped one. It is the same arithmetic in every direction, so acting on the
left object changes the zone off its right instead, and cropping an object's FAR end leaves the zone
alone. Three ends to that:

- shrunk to **nothing** — the objects merely meet — the crossfade is gone and what is left is an
  ordinary join, then an ordinary gap;
- widened past what the pair can hold (one object swallowing the other, or a lane or container
  change) the fades go too, and `resolveOverlaps` takes over with its normal overwrite;
- carried PAST its neighbour, right through to the far side, the crossfade ends there as well. The
  two ids are a ROLE each and not a sort order: an object that crosses over would need its outgoing
  edge to become an incoming one, which would put a fade nobody asked for on each of their opposite
  ends;
- anywhere in between, both fades are reset to the new overlap, equal on the two sides.

The fades go **with** the zone in the first two cases, and that is the point of doing it here: an
edge engaged in a crossfade has no fade length of its own, so a crop that ended the zone and left
the old fade standing would leave a two-second fade inside an object overlapping nothing — a fade
that looks as though it had grown, the object's edge having come to meet it.

`resolveOverlaps` leaves such a zone alone — it recognises it by that same geometry, so a drop that
merely LANDS on an object, having no matching fades, still overwrites.

### Markers, regions and comments

Purely visual, all of it: not one command in these families changes a sample of what is heard. A
script that has just moved a region and hears no difference has not found a bug.

A **region is a marker that has an end**. One type, one set of commands: `duration` 0 = a point,
greater than zero = a span (`is_region` says which in the answers). There is no `region.*` family,
and that is a decision rather than an omission.

They live on **rows** (`marker_lane.*`) one can show or hide, because a project passes through
several hands and each pass wants to leave its own marks without erasing the previous ones.
`marker_lane.set_visible` gives a row's pixels back while keeping everything on it — it is
`marker_lane.remove` that deletes.

**Two frames of reference, and this is the trap.** A marker on a ROW carries an ABSOLUTE time. A
marker carried by an OBJECT (`object.add_marker`) carries a time RELATIVE to that object's start,
exactly like an automation point and for the same reason: the object is then free to move, change
lane or have its right edge trimmed at no cost. `object.list_markers` returns both readings —
`time` (stored, in the object's frame) and `absolute_time` (the same instant on the timeline,
container nesting included) — so that no caller has to do the sum itself.

An object's markers **follow its matter** through the editing gestures, through the same five
transformations as its curves: a cut distributes them and rebases the right-hand ones on the cut
(a region straddling it is divided, both halves keeping the name), a trim of the left edge rebases
them, a reverse mirrors them, a varispeed scales them, a ripple takes out those whose passage has
gone. A marker pushed BEHIND an edge is not lost: it keeps a negative time and comes back if the
edge is reopened, which is what `audible: false` reports.

A **comment** (`comment.*`) is a free text laid over a span. It is not a sound object: it has no
engine object at all, and the price of that is that it inherits nothing — it does not move with a
ripple, a cut or a dragged object. Its text is markdown, inline only (bold, italic, code, links).

Its `lane` is a **base row**, the same frame as `object.add`'s and not the visual row index, so
that opening a group above it pushes the comment down with everything else instead of leaving the
note beside somebody else's lane. `comment.list` answers with both: `lane` as stored, and
`display_lane` as it is actually drawn once every unfolded zone above it — an open group's
children, an open piano roll, the automation bands — has taken its rows.

**A comment can live INSIDE a group, recursively** (`parent`, on `comment.create` and
`comment.move`; `parent: null` in an answer = the timeline). Inside a group it changes FRAME,
exactly as the group's children do: its stored `start` / `end` become relative to the group's own
start and its `lane` becomes a row of the group's band (0 = the first row under it). That is what
makes it follow the group when it is moved or copied — and what makes it go with the group when
that is deleted. `comment.list` answers with `abs_start` / `abs_end` beside the stored pair, and
`display_lane` is **null** when the comment is not on screen at all (its group is folded, or is
showing its automation band, so there is no row for it). `comment.create`'s `from` / `to` and
`comment.move`'s `at` are always ABSOLUTE — the frame is applied on the way in. On `comment.move`,
`parent` absent leaves the frame alone and an explicit `null` brings the comment back onto the
timeline.

**Colour is INHERITED until it is asked for**, and `color_index: null` in an answer says so —
null is not "no colour", it is "the one I take from what carries me": its ROW for a mark of the
band (`marker_lane.set_color` therefore recolours a whole layer at once), and WHITE for a comment
and for a mark carried by an object. White is the point, for a comment: it is not in the object
palette, so a note never reads as one more object laid on the lane. To go back to inheriting, send
`marker.set_color` / `object.set_marker_color` / `comment.set_color` **with no `color_index`** —
absent and null are one thing here.

`marker.set_lane` moves a mark to another row **keeping its identity**: the same id, hence the same
handle for a script holding it, and the same time — a row is a layer of reading, not a place on the
timeline.

`marker.move` carries both bounds: `at` alone moves a mark, `at` + `duration` **crops** a region,
which is also the hand's gesture since 16 September (its two ends pull, the far one anchoring, the
same vocabulary a clip and a comment speak). It answers with the mark's real `at` and `duration`
after the move. With `snap: true` both bounds go through the timeline's own snap, and the mark is
left **out of its own targets** — the door the band's drag uses, and the reason the flag exists:
the drag writes into the model on every frame, so a mark left in its own list would be its own
magnet and would refuse to move at all.

`object.move_marker` is the same gesture for a mark an OBJECT carries, and it takes both readings:
`at` for the instant a hand would point at, `rel` for the object's own frame — it is stored relative
either way. `snap` behaves exactly as `marker.move`'s, the mark left out of its own targets. A
negative `rel` is legal and is NOT clamped here: that is a mark pushed behind an edge, kept and not
drawn. The HAND's drag clamps to the object's window instead, because a mark that vanished under
the hand moving it would have no way back but ⌘Z.

**Several marks can be selected at once** — markers and regions of the band, markers carried by
objects, comments — and the three commands below speak exactly what the hand's clicks do (they call
`handleMarkBandClick` and `removeAnnotations`, the code of the click and of ⌫):

- `marker.select {items, mode}` — `items` are `{lane, marker}` (band), `{object, marker}` (carried
  by an object) or `{comment}`. `mode: replace` (default): the first item is a plain click — the
  selection becomes it alone, and for a mark of the band the **cursor goes to its start** — and
  the others are ⌘-clicks; an empty list is a click on nothing and lets go of everything.
  `toggle`: each item is a ⌘-click (in or out, the cursor left alone). `extend`: each item is a
  ⇧-click — the marks of the band between the **anchor** (the last plain or ⌘ clicked mark) and
  the item, in time (a region counts when it overlaps the span) AND in rows, replace the
  selection; the anchor holds still, so a second ⇧-click aimed back inside shortens it. With no
  usable anchor it just adds the mark. An unknown mark is refused (`not_found`).
- `marker.selection` — the marks selected, in the order they were picked (`kind` =
  `lane_marker` / `object_marker` / `comment`, plus their ids — the shape `marker.select` takes
  back), the `anchor` and the `cursor`.
- `marker.remove_selected` — deletes them all: **one undo step**, whatever their kinds.

The selection is **exclusive with the objects'** (`selection.get` answers empty while marks are
selected, and selecting an object lets go of the marks) and is **pruned** when its targets go —
an undo, a cut that moved a mark onto another half, a deleted row or group, a new project. The
hand's drag of a group (in time only, one undo) and the right-click menu are not reachable from
here.

`tools/scenario_markers.py` asserts all of the above against a running instance.

### An infinite bus changes row

`object.set_infinite` turns an aux's or a group's infinite on or off — top level only, a child of a
group is refused (`invalid_state`) rather than answered with the interface's alert, an alert being a
window. Turning it on gives the bus a row of ITS OWN, inserted just below, so the lane in the answer
is not always the one it set off from. `object.get` reports the state as `infinite`.

An infinite bus has neither a start nor an end: its band takes the whole width of its row, so the
only thing a move can mean for it is a change of ROW. `object.move` with a `lane` is that move, and
it answers by the band's own rule rather than writing the lane as given:

- an **empty** row takes it;
- a row holding **one other infinite bus and nothing else** SWAPS with it — the two full-width
  bands trade rows, which is what reordering a stack of buses needs and what would otherwise
  require a free row to shuffle through;
- any other occupied row **refuses** it (`invalid_state`), and nothing moves at all. A bus set down
  on a clip would cover it whole, which is exactly what `moveInfiniteBusToOwnLane` exists to avoid
  when one is created.

Asking for the row it already sits on is a no-op and answers its current lane. A `start` sent
ALONGSIDE a `lane` is left alone — a band has nowhere to start — while a `start` on its own still
writes the stored window, which is the one a bus goes back to when its infinite is turned off. The
same rule is what the hand's vertical drag on the band obeys, and it is one definition, not two.

### The snap belongs to the project

`project.set_snap` turns it on or off, and it is **saved with the file**: a session built off the
grid reopens off the grid, without anyone having to turn the snap off again on every open. A file
with no `snapEnabled` key — anything written before format 13 — opens WITH the snap, which is also
where the app and a fresh project start. Read it back from `project.get_state`, field `snapEnabled`.

What the snap LANDS ON, besides the grid: the two edges of every top-level object, and the **marks**
— a marker's instant, a region's two bounds, and the marks an object carries, converted into edit
time. A mark names an instant in the piece; an edge one has to eyeball onto it is a mark doing half
its job. Only VISIBLE rows count (a hidden row keeps its content but has stopped saying anything),
and a mark pushed behind an edge by a trim does not count either — it is not drawn, so it must not
pull. The tolerance is 8 px, so it follows the zoom.

`object.move` and `marker.move` take a `snap` flag, **false** by default: the API positions exactly
unless asked otherwise. A mark asking for the snap excludes ITSELF from the targets — see
`marker.move` above.

It does NOT decide any VALUE, and that is a rule and not an exception for the pan. The snap is the
GRID's, hence TIME's: it says where a thing is PLACED — an object, a mark, an automation point. What
a thing is WORTH answers to a DETENT of its own, which is **unconditional**: the pan's tenth, the
whole dB of a volume, of a send level and of an automation curve laid on either. A detent is there
to lower the precision, which is wanted whether or not one is working on the grid, and ⌘ does not
lift it — a modifier that leaves 13 % or -3.4 dB behind in the file is the intermediate value under
another name. Until 19 September 2026 the automation band's VERTICAL axis was wired to
`project.set_snap` along with its horizontal one: turning the snap off to place a point freely also
took the dB off their round figures. It no longer is.

The detent lives at the HAND's doors, and the machine's write what they are given: `object.set_pan`,
`object.set_send_level`, and what a curve pushes to the engine. A plugin parameter has no detent at
all — its 0…1 is normalised, so there is no unit to round to. The one exception is
**`object.set_gain`**, whose whole dB lives in the model rather than at the door and therefore
applies to a script too: `updateVolume` has rounded since long before this doctrine was written, and
moving it would silently change what every existing scenario reads back.

### The pan clicks onto the tenths, always

`object.adjust_pan` moves the pan BY a delta — the path every hand gesture takes (the Pan tool, the
inspector's box, the ±0.1 arrows, the wheel) — and each held object's result lands on the nearest
TENTH, however many are held. The detent is **unconditional**: it answers neither to `project.set_snap`
nor to ⌘, because the values between the tenths are not wanted at all. What this is NOT is the
quantum that used to live in the model and cancelled a multiple drag outright: that one compounded,
rounding each ~0.0125 delta back onto the tenth it came from until nothing moved at all. Here the
gesture works from ANCHORS and hands over its TOTAL travel, so the rounding lands on the result and
never feeds the next frame — a slow drag simply waits until the total crosses the half-step.
Accepted cost: an object whose pan was not on a tenth is brought onto one, so the spread between
objects can shift by up to half a step.

`object.set_pan` is the other door, and it stays EXACT: it sets an absolute value, writes it as
given, and never quantises — a script asking for 0.37 gets 0.37, as does a pan automation curve. The
detent belongs to the hand.

### An automated send does not answer the hand

The same split, one family along. As soon as a send's level carries an automation point, the CURVE
is what is heard and the static value is no longer — that is the whole automation doctrine, no
offset and no composition. So a hand that went on lowering that send would be turning a knob that
changes nothing, which is the one thing an interface must never offer.

`send.list` says so, per send: **`automated`** beside `level_db`, `enabled` and `routed`.

`send.adjust_level` is the HAND's door — relative, over the current selection (or the `ids` given),
the path the Send tool's knob, the wheel and the inspector's box all take. It leaves an automated
send alone and names it: the answer carries `moved` and `locked` side by side, so a script can tell
"out of scope" from "held by a curve".

`send.set_level` is the machine's door and stays EXACT, under a curve as anywhere else: it writes
the static value as given — which is also how an automation lays its own starting point down.

The on/off SWITCH is deliberately outside all this. Cutting a send is an explicit intention of
silence and keeps the last word over any curve, so `send.enable` answers under automation exactly
as it does without.

### Sliding the time selection

`timesel.step_lane` (`by`: -1 one row up, +1 one row down, any step) moves **THE TRACED PASSAGE and
nothing else**: the range keeps its span of time and its height — three rows stay three rows — it
simply lands on other lanes. Not one object changes lane, nothing sounds different, and no undo is
pushed. It is the bare ↑ / ↓ arrows of the interface.

It travels over **displayed** rows, and an EMPTY row is a row like any other here — unlike an object
selection, a time range on an empty lane means something: it is where a paste lands and where a
comment is laid. At the two ends — row 0, and the last row the timeline draws (one free row under
the lowest object, the open groups' children and the unfolded bands counted in) — nothing moves and
the selection is kept whole rather than clipped.

With **objects selected and no range traced**, the frame they FILL is adopted and travels instead:
from the first one's start to the last one's end, over the display rows they sit on. An object is a
passage one can see, so one selects it rather than tracing over it — the same reading `ripple_delete`
makes of an object selection. That first call materialises the frame AND moves it, in one step, and
the objects are **deselected**: the frame has left them, and objects still selected under a range
lying elsewhere would give `⌫` two answers. Not one of them changes lane for all that. An INFINITE
BUS is left out of the frame — its band has neither start nor end, and the window it still stores is
not a passage anybody traced.

With neither a time selection nor a usable object selection it answers `invalid_state`. At an end it
returns having touched NOTHING, the object selection included. The answer is the selection payload,
plus `moved`.

### What a carried time selection lands on

Dragging a traced range by its body (without ⌥ it moves the matter it covers, with ⌥ it copies) goes
through ONE snap whose subject is the **range**, not the object grabbed inside it. The precedence,
the first step that finds something deciding:

1. a **real mark** — an object's edge, a marker, a region's bound; the grid is *not* one — within
   8 px of the range's **start** (the caret) or of its **end**. The nearer wins and a tie goes to the
   start. A real mark is never beaten by the grid, even a nearer one;
2. else a real mark within reach of the **grabbed object's** edges (clipped to the range) — what an
   object's own move has always done, now second;
3. else the **grid**, on the range's start or end (again the nearer, ties to the start).

With the snap off (or ⌘ held, which inverts it) the range follows the hand. The range itself stops at
**zero**: it is the selection that is walled, so an object lying later than the range's start does not
limit the travel. Without ⌥ the scraps the cut leaves at the two bounds are kept out of the targets
(otherwise the range would stick to a travel of zero, a magnet on itself); with ⌥ nothing is cut, the
originals stay in place and **are** targets.

`timesel.snap_probe` (`dt`, optional `copy`, `grab`, `snap`) asks that snap without touching anything
— no move, no undo, no change of selection — over the current time selection. It answers `dt` (the
travel the drag would apply), `guide_time` (where the guide line would stand), `on_target` (a real
mark was hit: the yellow guide), `edge` (`start` | `end` | `object_start` | `object_end`), `clamped`
(the wall at zero stopped it) and the range's bounds after the travel (`start`, `end`).
`invalid_state` without a time selection. The decision table is asserted alone by
`tools/test_selection_move_snap.swift`, the model half by `tools/scenario_selection_snap.py`. What
neither reaches is the gesture itself.

### What a right click decides

`selection.context_click` (`id`, optional `zone` `time` | `body`, `lane`, `time`, `apply`) plays the part
of the timeline's right-click monitor that comes BEFORE the menu is built: `ContextMenuPlan` (pure,
asserted alone by `tools/test_context_menu_plan.swift`) and the selection a click on an object's BODY
makes (`EditViewModel.selectForContextClick`, the left click's own: range cleared, object selected,
cursor on its absolute start).

With `id`, the click is on that object: `zone` is the half of the block (the upper half is TIME, the
lower the OBJECT); the point's lane is the object's display lane and `time` its instant (default: the
object's middle). Without `id`, the click is on an EMPTY lane (no object under the point, which the
caller states): `lane` (the display row) and `time` are then both required, and `zone` is ignored.

It answers `layout` — `range_menu` (today's menu: group, aux clip, MIDI clip, comment. The point lies
INSIDE the time selection, or it lands on NO object while a time selection exists ANYWHERE, inside the
range or not, on its lanes or not — a click on an empty lane has never cared where the range lies),
`group_selection_menu` ('Group the clip / the selection (N)' alone: an empty lane, NO time selection,
and at least one clip or MIDI clip that is not a consolidated instance selected — the click selects
nothing, the selection is what the menu is about), `object_time_menu` (upper half: the object marker
only), `object_body_menu` (lower half: the object's own menu) or `nothing` (no menu, the event goes on
to the views: an empty lane with no time selection and nothing groupable selected) — plus `selects_object`, `offers_object_marker`, `offers_comment`, `applied` and the resulting
`selection`. On an OBJECT, a range lying elsewhere does not drive the menu. An object ALREADY selected
is never re-selected (the multiple selection is kept, the range too); a click on an empty lane never
selects. `apply: false` only asks. The menu itself is not reachable from here;
`tools/scenario_context_click.py` asserts the rest.

### Walking the insertion caret

With **nothing selected at all** the arrows are not idle: a plain click in the timeline lays a
CARET — a point of insertion, a row and an instant — and `caret.step_lane` (`by`: -1 up, +1 down) is
what the bare ↑ / ↓ then move. The same road as above: displayed rows, empty ones counted, a stop at
row 0 and at the last row the timeline draws, nothing modified and no undo. The ⇧-extension origin
travels with the caret, keeping its instant, so a following ⇧-click traces from where the caret
actually is. It answers `invalid_state` when there is no caret, and when a range or an object
selection is holding the arrows — that case is `timesel.step_lane`'s.

`caret.set` (`lane`, optional `time`) lays the caret as a plain click does: the selections are let
go of, and `time` moves the cursor with it. The selection payload now carries **`caret`**
(`lane` + `time`) whenever there is one.

### Ripple

`timesel.ripple_delete`, `object.ripple_delete` and `object.ripple_cut` do not merely remove
matter: they **close the gap behind it**, everything that followed sliding back onto the hole's
left edge. What makes them worth a command of their own is their **scope**, which is the container
and nothing wider: a ripple laid inside a group moves objects of that group, and leaves the group's
neighbours, its parent and the rest of the timeline exactly where they were.

What a script has to know about:

- **Only the SELECTED lanes are hollowed out and slide back** — the lanes of the time selection
  (`timesel.ripple_delete`), the lanes the given objects sit on (`object.ripple_delete`), the lane
  of the object cut (`object.ripple_cut`). The other lanes of the container stay exactly as they
  were. This is a deliberate choice, and its **cost is that the synchronisation between the lanes
  is no longer guaranteed**: an object on an unselected lane that straddles the hole is spared, so
  the selected lanes can end up out of step with it. (Until 29 September 2026 every lane of the
  scope was hollowed out.) A ripple on ALL the lanes of a container gives the old behaviour back.
- What slides is decided per selected lane, by **unit**: the shallowest object whose row is
  selected goes whole, with everything under it — a group whose own row is selected is one unit,
  its children's rows selected or not. A sub-group only **partially** selected (some of its
  children's rows, not its own) keeps its window where it is, and the selected children slide
  inside it in absolute time (so one may slide out past the window's start).
- The container's own window **shrinks only if every lane of the scope was selected** (an infinite
  bus does not count). Otherwise it does not move.
- The scope is the **shallowest** container the gesture touches; selected lanes outside it are left
  alone. `timesel.ripple_delete` and `object.ripple_delete` return it as `container` (`null` = the
  whole timeline): read it back rather than assuming it.
- `object.ripple_cut` reads the hole off the object it is given — `keep: "left"` removes
  `[seconds, that object's end]`, `keep: "right"` removes `[its start, seconds]`. The answer says
  which span went, in `removed_from` / `removed_to`.

A ripple whose scope is a **looping** group is refused (`false`, no undo step): that group's window
is a porthole onto a repeating pattern, and shortening the pattern would change every repeat at
once, including those the gesture never aimed at.

`object.ripple_cut` no longer empties the selection. It goes through no separate id at all — the
surviving matter is TRIMMED in place, never re-split — so the grabbed object simply keeps answering
to its own id, and, if it was selected, to its own selection too. Same rule as an ordinary division
(@see "DIVIDING the matter" above): the selection follows the matter, and a ripple does not touch
it when the object it is given was not selected to begin with.

### Solo, and the windows it holds open

`solo.set` puts objects into the **confirmed** solo layer (`on: false` takes them out), exactly as
the inspector's solo button does, one object at a time through the same door; `ids` defaults to the
selection. `solo.clear` is Esc: every solo off, confirmed and temporary. `solo.get` reads the state
without changing it. The three answer the same object: `active`, `confirmed`, `stems`, `temporary`
(`null` unless the "s" key is being held — a script holds no key, so it can read that layer but
never lay it), `audible` (the closure the dimming reads) and `opened_windows`. Undo policy `none`:
a solo is a listening state, outside the undo and never saved.

`opened_windows` is the half of the rule no fader shows. A group's window cuts its content, and a
child can hang past it (a window is a frame over absolute positions, not a crop of the children).
A **direct** solo — the object itself among the roots — is heard whatever stands in its way: the
mute of a group it goes through (since 24 August) and, since 25 September, that group's **window**:
for as long as the solo lasts, the engine window of every group on the path is pushed open the way
an infinite group's is, together with the auxes those groups host, and put back when the solo
moves off. The model's window is not touched — `object.get` still answers the bounds that were
set. Two exceptions: a **looping** group keeps its window (a porthole onto a pattern, not an edge),
and an **inherited** solo opens nothing — soloing a group or a stem is asking to hear it as it is,
window included. The cost: while a child is soloed, its ancestors' own fades are not heard, a fade
belonging to the edge the solo has lifted. `tools/scenario_export_preview.py` re-reads the rendered
files to prove the engine followed.

### The audio device (`audio.*`)

`audio.status` answers the device REALLY in use — read from the open `juce::AudioIODevice`, never
the requested `AudioDeviceSetup` (JUCE may have picked the nearest rate/buffer to what was asked)
and never the user's persisted choice (`AudioOutputDevice.shared`, which survives an unplug). It is
the SAME object the window shows beside the project's name, in grey. `device: null` means no output
device is OPEN — under `--no-audio`, `getCurrentAudioDevice()` can be non-null with a real name
although nothing plays; the truth test is `isOpen()`. `running` tells an open-but-dead device (a
restart gap, a device that died) from one really producing sound. `live` re-reads the engine at the
instant of the call, so a script can assert it agrees with the cached fields the title bar shows —
they are refreshed only on a real `juce::AudioDeviceManager` change message (device opened/closed/
restarted, rate or buffer changed, device list changed), never on a timer: `generation` bumps on
every such change and stays put otherwise, which is what a script checks to tell "nothing changed"
from "the reading missed something".

**`window_subtitle` is not `NSWindow.subtitle`.** Measured (a `debug.titlebar` diagnostic command
walking the title bar's `NSTextField`s) that `NSWindow.subtitle` draws INLINE on the SAME field as
the title, one colour for both — no way to grey only the device half and leave the project's own
name exactly as AppKit draws it. So the device text lives in a SECOND `NSTextField`, laid by hand
clamped to the title bar's RIGHT edge, apart from the title (`TitleBarDeviceLabel`, white at 25 % —
tuned for a dark title bar — the title's own font, never closer than 16 pt to the title's end), and
`window.subtitle` itself is set to `""` and never anything else. `window_subtitle` answers that
label's OWN displayed string — `"Device — 48k — 512"`, no leading separator — and `null`
when nothing is actually shown (no title field found in a macOS whose title-bar internals differ
from the ones measured here — fails silent rather than draw something misplaced; or the window too
narrow to fit even a truncated word of it, which the label detects on its own and hides). Never the
text that was ASKED for if the hand would see nothing of it — `audio.status.text` is that request;
`window_subtitle` is the answer. `debug.titlebar` (DEBUG builds only) additionally reports the
label's own frame, colour and hidden state, and the title field's frame it is laid beside, in WINDOW
coordinates — enough for a script to assert the label starts at or after the title's trailing edge
and shares its vertical centre, without which "beside the title" is merely asserted, not measured.

`audio.devices` lists what the engine currently offers (outputs, sample rates, buffer sizes),
re-scanned live. `audio.set_buffer_size` / `audio.set_sample_rate` / `audio.set_device` apply
through the SAME setters the wrench menu uses (never `AudioOutputDevice.shared` — a script must
not write the user's persisted choice) and wait (up to 3 s, `settled: false` past that) for
`generation` to move before answering the new status. **They touch the real hardware**:
`set_sample_rate` changes the device's nominal rate for the WHOLE system (CoreAudio), not only for
OBJEKAT, and every one of the three rewrites `~/Library/objekat/Settings.xml` — a script that
changes them is responsible for setting them back before it quits.

A known, pre-existing limitation, found alongside this family and NOT fixed by it (out of scope —
it sits in Tracktion's own device restore, not in anything above): once
`~/Library/objekat/Settings.xml` holds a saved device with no explicit channel-count attributes
(the normal case after any real run — `useDefaultOutputChannels` then wins), `--no-audio` fails to
keep the engine from opening the real device. So on a machine that has ever run the app for real,
`audio.status.device` / `app.info.output_device` can stay non-null even under `--no-audio`. Both
fields still answer the truth of whatever the engine actually opened; it is `--no-audio`'s own
guarantee that is short here. `tools/scenario_audio_device.py`'s phase A detects this and adapts
its assertions rather than failing on a machine where it is present.

### Export

`export.run` returns a `job_id`: the render runs on its own thread, and `job.wait` closes the
loop. Its defaults are **not** the window's — MP3 44.1 kHz over the whole project, where
it offers WAV 48/24. The window serves to deliver, the API to check quickly.

The API **neither reads nor writes** any preference. The window, for its part, picks up the settings of the last
manual export: if a command inherited them, a script's result would depend on what was
ticked the day before. And symmetrically, a script rendering a check MP3 has no business changing what
the window will offer next (`runExport(_:persistingPreferences:)`).

Since 2026-08-18, the window starts from the **same defaults**: MP3 44.1 kHz, 320 kbit/s. That only
concerns the first export — after that, the last format kept takes precedence.

**Everything the window sets, the API sets.**

| window | command |
|---|---|
| Span: The whole project / IN–OUT / Regions | `range: "project"` (default) / `"inout"` / `"regions"` (`scope` is an alias) |
| The IN and OUT fields | `start` / `end` |
| The Time / BPM unit selector | the shape of `start` and `end` (see below) |
| WAV / MP3 format | `format` |
| Rate | `sample_rate` |
| 16 / 24 bits | `bit_depth` (WAV) |
| Dithering | `dithering` (WAV) |
| Location + Name | `path` (regions scope: the folder, `folder`) |
| Render in the background | `background` |

`start` and `end` accept the three notations of the window's fields, told apart by the number
of colons: a **number** means seconds, `"1:30,5"` is a clock time, `"3:1:0"` a
**bar:beat:tick** position converted at the project's tempo. Refusing the string would force every
musical script to redo that conversion in its own corner — that is to say, to get it wrong one day.

Giving `start` and `end` imposes the span **without touching the IN/OUT markers**. The window, for its part,
moves them as soon as you type in its fields: `set_markers: true` reproduces that behaviour when
it is really wanted. The default stays the opposite — a script has no business leaving traces in the
project in order to produce a file.

Two of the window's settings have **no** equivalent, and deliberately so: the Time/BPM selector
is only an input unit (it changes nothing in the render — here it is the shape of `start` that says
so), and the "Choose…" button opens a folder picker, which has no purpose when `path` already carries
the path.

Format constraints, refused with a message that names the values allowed: MP3 knows
only 44 100 and 48 000 Hz and its bitrate is fixed at 320 kbit/s (the window does not set it either);
depth (16/24) and dithering exist in WAV only.

#### The `regions` scope: one file per region

The span selector has a third value beside *whole project* and *IN–OUT*: **Regions**. The window then
lists every region of the project with a checkbox, and the export renders the **master** over each
ticked region's own span — exactly the way the IN–OUT scope renders its range (same engine path, same
format, rate, bit depth, dither and MP3 settings) — into **one file per region**, named after it, in
the chosen **folder**. The "Location" row is the destination folder; there is no name field.

**Which regions.** A region is a marker with a length (`duration > 0`) on a row of the marker band.
Rows that are **hidden** count: hiding a row is a display choice, not a deletion — the picker flags
them with a slashed eye (`lane_visible: false`). Plain markers (points) and the marks an object
carries are not regions for this purpose. They are listed in **start-time order** (a total order: start,
end, the row's place in the band, then the id), grouped by row in the window.

**Which are ticked.** All of them the first time, and a region laid later is ticked too — the state is
kept as the set of *unticked* regions. The ticks live in the session's memory only (not in the project
file, no format bump), and are emptied whenever a project is loaded or a tab is switched to. The window
makes it plain which files will be written: each region is one line (checkbox, output file name with its
extension, the region's duration), a ticked row is lit and an unticked one dimmed, and each marker lane's
header has one all/none button for that lane's regions. The list is read live, so a region renamed,
added or removed while the window is open shows at once.

**File names** (`objekat/Export/RegionExportNaming.swift`, asserted by `tools/test_region_export_naming.swift`).
The region's name, with `/` `:` `\`, control characters and leading dots stripped, trimmed, and cut to
100 characters and 200 bytes. An empty result falls back on `Region <n>` (localised; `n` is the region's
place among ALL the project's regions, so it does not change when another one is ticked). Names that still
collide take ` (2)`, ` (3)`… in start-time order; the comparison ignores case and Unicode form, because
APFS does. Collisions are resolved among the **ticked** regions only — a file that will not be written
cannot collide, so unticking the first "Verse" makes the second one "Verse". Warnings shown on a row (and
returned as `warnings`): `empty_name`, `duplicate_name`, `file_exists` (a file of that name is already in
the folder). The overwrite question is asked **once** for the whole batch (`dialog policy` applies as
for any export), never once per region.

**The batch.** Regions are rendered **one after the other** — never two at once, and the Edit is not
modified during an export. Each region is an ordinary export job; the batch sits above them and pins the
active document for its whole length (even a render on a copy: every region clones the live Edit afresh, so
`tab.*`, `project.new` and `project.open` answer `invalid_state` until it is over). A region that fails does
not stop the others: the batch goes on, then reports which ones failed. **Cancel** (`export.cancel`, the
window's button) interrupts the region under way and never starts the following ones (`cancelled`); the files
already written stay, and no working file or half-written region is left behind.

| command | what it does |
|---|---|
| `export.regions {format?, folder?}` | Lists the regions: `id`, `lane`, `lane_name`, `lane_visible`, `name`, `start`, `end`, `duration`, `number`, `selected`, `file_name` (with extension; `null` if unticked) and `warnings`. `format` (default mp3) decides the extension, `folder` (default: the project folder) is what `file_exists` is checked against. Read-only. |
| `export.set_regions {action, regions?}` | `action`: `select` / `deselect` (with `regions`), `only` (ticks exactly `regions`), `all`, `none`, `invert`. Answers `selected_count` and `selected`. `not_found` for an unknown id. |
| `export.run {scope: "regions", folder?, regions?, …}` | Launches the batch. `regions` (marker ids) is used as given and **leaves the ticks alone**; absent, the ticked regions. `folder` must exist (default: the project folder). `path`, `start` and `end` are refused (`bad_params`): each region brings its own span and the files are named after the regions. `invalid_state` if nothing is ticked, `not_found` for an unknown id, `engine_error` if the launch is refused (an overwrite turned down by the dialogue policy). Answers `job_id`, `destination` (the folder) and `regions` (`id`, `name`, `file`, `start`, `end` — the files to come). `job.wait` resolves when the **whole batch** is over. |
| `export.status` | Gains `batch` while a regions export exists (and until it is cleared): `active`, `total`, `current` (1-based, the region under way; `total` when over), `name`, `file`, `progress` (0…1 over the whole batch), `done` / `failed` / `cancelled`, `cancel_requested`, `folder`, and `results` (per region: `id`, `name`, `file`, `path`, `start`, `end`, `status` = pending / running / done / failed / cancelled, `error`). The top-level `phase` / `progress` / `destination` are those of the region under way; once the batch is over `phase` is `finished` if every region was written and `failed` (with `error` = the summary) if any failed or was cancelled. |

The `job.wait` result of an `export.run` carries the same `batch` object. A script never opens a window
here either: `export.run` keeps the export panel, it does not open one, and on an instance with no
interface the picker is state only (`tools/scenario_export_regions.py` asserts no window on the pid).
The scenario also re-reads the written files at 24 bits: each as long as its region, signal where the
master has signal and silence where it has none.

#### Where a render shows itself, and what it shows

`export.panel` opens or closes the export window, and that decides where a render is WATCHED: with
the window open, a **direct** render stays in it — the waveform grows there, the progress runs
along its bottom edge, and one can listen to the file while it is written. A **background** render
closes it and the strip under the transport takes over. Closing the window by hand during a direct
render falls back to the strip too: the rule is one and the same, the strip shows whenever a job
exists with no window to show it in. `export.status` answers `panel_open` for that.

`panel_open` is a **state** — what `export.panel` set, what the strip reads — not a statement
about the screen. `panel_visible` is the reality: `panel_open` AND an interface able to show a
window, so it is always `false` with `--headless` (where `export.panel {open: true}` still sets
`panel_open`, on purpose: the scenarios read the state through it) and equals `panel_open` in the
UI mode. A script that wants to know whether somebody can SEE the panel reads `panel_visible`.

`export.run` **keeps** a window, it never opens one — same doctrine as the plugin editors: an
export driven by a script must not put a window on the screen of whoever is working.

**Bringing the window back onto a running render** (the strip's *Show* button): while a job runs,
`export.panel {open: true}` does not open on fresh settings and does not refuse with "already
running" — it brings the window back onto THAT render. The window then shows the job's own settings
and span (greyed, frozen at the launch), never the active tab's: the render may have been launched
from another one. On an instance with no interface (`--headless`) it only sets the state, readable as
`export.status.panel_open` (with `panel_visible: false`); no window ever appears there (`CGWindowListCopyWindowInfo` on the pid
returns nothing, and `tools/scenario_tabs.py` / `scenario_export_preview.py` assert it). With no
job, or a finished one, `open: true` is the window's ordinary opening on fresh settings.

`export.status` (and the result of `job.wait` on an `export.run`) carries `project_name` — the
project the render was **launched from**, frozen, so it still says so after the hand has moved to
another tab — and `background` (the regime).

**Tabs and exports.** A render on a **copy** (`background: true`) owns its own Edit once it is under
way: `tab.new`, `tab.select`, `tab.open` and `tab.close` all work while it renders, and it finishes
as if nothing had happened (the file is the same sound, sample for sample, as one rendered without
moving — asserted by `scenario_tabs.py`). Two cases pin the document in front and answer
`invalid_state`, for `tab.*` **and** for `project.new` / `project.open` (which tear the active Edit
down exactly as a switch does): a **direct** render (it reads the live Edit end to end) and the
`preparing` phase of any render (the clone is being made; a switch slipping in before it existed would
have the wrong project cloned).

`export.preview` reports what the window draws, read from the engine and from the file rather than
from the display's own cache:

| field | what it says |
|---|---|
| `peaks_filled` / `peaks_total` | how far the waveform has grown. The engine taps every rendered block (`OBJEngineCore.exportPeaks`); the buckets are a fixed resolution over the whole range, so the memory does not depend on the length. |
| `peak_amplitude` | the loudest sample seen so far, 0…1. It is the FILE's own peak — that is what makes the drawing checkable. |
| `audible_seconds` | how much can be listened to right now. |
| `rendered_duration` | the range being rendered, frozen at the start. |
| `source` | the file being listened to: the render's temporary wave, then the final file. |
| `output_device` | the sound card the listening goes out on, READ BACK from the listening engine's own AudioUnit (`null` if unreadable). It is OBJEKAT's card — the name `audio.status` publishes — not the system's default output; a name that cannot be resolved falls back on the default output, said in the log (`[EXPORT-AUDITION]`). |

`export.preview` also takes an optional `listen` (bool): `true` starts the listening from the start
of the range, `false` stops it — the machine's door onto the listen button, and it **really plays**
on the card. If OBJEKAT's card changes while one listens, the pass stops, is reconfigured on the
new card and resumes at the same position. `tools/scenario_export_preview.py` compares
`output_device` with `audio.status.device` whenever a device is open, and skips that block when
none is (`--no-audio`).

`audible_seconds` is deliberately **not** the progress: the render runs ahead of the writer, which
flushes its header every six seconds of audio (`numSamplesPerFlush`). That flush is what makes the
file in progress a VALID wave one can open and play — no engine patch, no partial-header parsing.

Nothing of a render exists while it **prepares**: the engine's tap is only remade when the render
is really launched, and only zeroed when its graph is built, so it still answers the previous
export's shape in between. `peaks_filled` is 0 throughout that phase rather than the last render's
count.

**Loudness while it renders (ITU-R BS.1770-4 / EBU R128, Tech 3341 / 3342).** The same tap that
draws the waveform measures the loudness of every rendered block, after dithering and just before the
write: K-weighting computed for the render's actual sample rate, energy per 100 ms sub-block, true peak
at 4× oversampling (BS.1770-4 Annex 2 FIR). The signal half is `objekat/Shared/OBJLoudness.h` (plain C, one
implementation shared with `tools/test_loudness.swift`); the windows and gates are
`Export/LoudnessAnalysis.swift`. The engine hands the sub-blocks over incrementally
(`OBJEngineCore.exportLoudnessBlocksFrom:`), lock-free (release / acquire), in memory sized once when the
render starts. The result survives the end of the render, like the peaks, and — like them — nothing of
it shows while the export **prepares**.

`export.status.loudness` (an object; `null` when there is no export at all):

| field | what it says |
|---|---|
| `integrated` | LUFS. Blocks of 400 ms every 100 ms, gated at −70 LUFS (absolute) then −10 LU under the power mean of what survived (relative). |
| `lra` | LU. The short-term (3 s) values gated at −70 LUFS and −20 LU (relative), then the spread between their 10th and 95th percentiles. `null` until 3 s of material have passed the gates. |
| `true_peak` | dBTP, the loudest of all channels over the whole render so far. |
| `momentary` / `short_term` | the LATEST 400 ms / 3 s windows, LUFS. `null` until the window has filled. |
| `momentary_max` / `short_term_max` | the highest of each so far, LUFS. |
| `blocks` | how many 100 ms sub-blocks have been measured (the render's progress in tenths of a second; a final partial one is dropped). |

Any value that does not exist yet **or is silence (−∞)** is `null` — JSON has no infinity. The gated
readings sit in 0.1 LU histograms (as libebur128 does), each bin keeping the exact sum of the energies
it holds: the mean over the kept bins is exact, only the gate thresholds are quantised (≤ 0.1 LU).

`export.loudness {points?}` (1…5000, default 200) returns the three curves cut down to at most `points`
samples, evenly spread over the sub-blocks: `times` (s, the instant each window **ends**), `momentary`,
`short_term`, and `integrated` (the gated value as it stood at that instant — what the meter would have
read had the render stopped there), all in LUFS and `null` where the window has not filled or the value
is silence; plus `blocks`, `duration` and `summary` (the same object as `export.status.loudness`).
`invalid_state` with no export. `tools/scenario_loudness.py` asserts all of it against generated WAVs
(a 997 Hz stereo sine at −23 dBFS reads −23.0 LUFS; two levels 10 LU apart read an LRA of 10).

### Saving a copy with the audio files

`project.save_copy {path}` is the menu's "Save a copy with audio files…" without its panel: `path`
is the capsule's **folder** (created if absent), and the manifest inside is named after it
(`/x/My copy/` → `/x/My copy/My copy.objekat`). The command **waits for the last write** before it
answers — no job, no polling:

```json
{"cmd": "project.save_copy", "params": {"path": "/tmp/capsule"}}
→ {"path": "/tmp/capsule", "manifest": "/tmp/capsule/capsule.objekat",
   "copied_files": 3, "missing": []}
```

What goes in is what the project **plays**, and nothing more. The source files are copied into
`samples/sources/` (de-duplicated by name). The consolidated objects are carried by transitive
closure through their sidecars (a consolidated object nested in another one comes along), each wave
copied from **wherever it is actually read** — `samples/consolidate/`, the legacy
`samples/objects/`, or another project's folder — into the capsule's `samples/consolidate/`, with
its sidecar rewritten to name the capsule's paths. The copy is therefore what **normalises** a
project from before the consolidate rename: the capsule never has a `samples/objects/`. Orphan
waves (older revisions, a consolidation undone) and definitions without an instance stay behind.
The `.wfc` caches of the included files travel along when they exist.

It copies the project **as it is in memory**, unsaved changes included. The current project is not
touched: it stays the open one, with the same path and the same dirty flag — this is not a Save As.

- `missing`: what could not be carried (an absent source, a sidecar, a definition); the copy still
  succeeds and those links are left as they were.
- A write failure throws `invalid_state` with `details.errors`; the capsule is then incomplete.
- `bad_params` (with `details.source`) if `path` overlaps a folder the copy **reads** from — the
  project's own folder, a folder inside it, a folder containing it, or the folder of an older
  project whose consolidated waves are still read (after a Save As). A copy there would remove each
  wave before copying it from itself: that was a real data loss through the menu. Identity is the
  file system's, so another case (APFS), a symbolic link, `..` or `/tmp` vs `/private/tmp` are all
  seen through. The refusal is the menu's own and records its alert. Nothing is read or written.
- A source file that already sits exactly where the copy would put it (an unsaved project playing
  `<dest>/samples/sources/x.wav`) is left in place, never removed "to be replaced".
- The end-of-copy report goes through the dialogue policy like any other (`app.dialogs` under a
  script, a modal under `ask`).

### Missing files, and repairing a link

A clip names a file on disk, and that file can go: a drive unplugged, a folder moved, a take
renamed outside the project. The engine already draws its own conclusion — a file it cannot open
makes the clip give up **before it is created**, so an object whose file went missing is a ghost
down there: no clip, no chain, no fades, no sends, no plugins. Two consequences a script has to
know about:

- **a repair CREATES the object, it does not correct a path.** The whole clip is born again on the
  new file and given back everything the birth does not carry, so a relink is never a cheap write;
- **it is therefore visible** — `object.get` and `object.list` carry `missing` (a bool) and
  `missing_reason` (`absent`, `volumeOffline`, or `null`) on every object, whether or not it names
  a file at all. A script does not have to know which kinds can be missing.

**`missing` is a lookup, never a disk access.** The predicate is read by the timeline's canvas once
per block per frame, so the file system is asked in exactly ONE place: `project.rescan_missing`.
Everything else — `project.missing_files`, the two fields above — reads what that scan found.

| | |
|---|---|
| `project.rescan_missing` | asks the disk again about every path the project names; answers `path_count` and `object_count` |
| `project.missing_files` | the detail of the LAST scan: `files` (`path`, `reason`, `object_count`), plus `path_count` and `object_count` |
| `project.relink_preview` | `from` + `to`: what that pair would teach and what else it would mend. Changes nothing |
| `project.relink_path` | `from` + `to` (+ `propagate`): repairs a missing path, and optionally the others it resolves |
| `project.relink_folder` | `folder`: sweeps it and repairs every missing path whose FILE NAME is found there |
| `object.replace_source` | `id` + `path`: points ONE clip at another file. The deliberate gesture |

**The unit of a repair is the PATH, not the object**, which is why two of the four are named
`project.*` although they mend clips: one file lost breaks the N objects that name it, and putting
it back mends all N in **one undo point**. Hence the two figures every answer keeps apart —
`path_count` is what a repair works in, `object_count` is what a human counts ("four sounds are
broken"). A command taking an object id would be lying about what it does.

**A group is never `missing`** — it owns no file, whatever its content. It answers the separate
question instead: `object.get` carries `missing_descendant`, true when anything in its sub-tree is
broken, so a group folded shut can say that something inside it needs attention. The two are kept
apart on purpose: only the clips the first one counts can be relinked, never the group. A clip
nested in a folded group is scanned, counted and repaired exactly like a top-level one.

**Two gestures, and the line between them is the design.** `object.replace_source` is "I have
re-edited that sound outside": one object, deliberate, **never propagated, never a question**, and
available whether or not the current file is missing. `project.relink_path` is "that file is gone":
an accident — and accidents come by packets, so a repair can propagate what it learned.

**Propagation is a prefix substitution.** Repairing `/Volumes/SSD/sessions/x/bell.wav` onto
`/Users/n/Sons/x/bell.wav` teaches `/Volumes/SSD/sessions` → `/Users/n/Sons`: the two paths are
compared BY COMPONENTS and the longest common suffix — the part the move did not touch, and
therefore the part that says nothing — is taken away. The substitution is reported as
`{"from": …, "to": …}`, or `null` when the pair teaches nothing generalisable: two differently
named files (that is a replacement, not a repair), or a suffix covering the whole of one of the
two paths, which would give a rule matching every path in the session.

`propagate: true` then applies it to the **other missing paths**, and only to those it resolves
onto a file that **really exists** — relinking onto the wrong file is worse than leaving it
missing, since a missing file says so and a wrong one simply plays. The match is on a component
boundary, never on the raw characters: `Sons2` is not inside `Sons`. The whole thing, the
propagated paths included, is **one `edit.undo` away** from what it was.

`project.relink_preview` is that same computation with nothing written: the substitution, and each
other missing path it would mend with `path`, `new_path` and `object_count`. It is what the
interface's propagation prompt shows, and what makes the propagation assertable with no screen.

**The sweep** (`project.relink_folder`) matches on the file NAME alone, and settles homonyms by the
file's **size**, recorded when the clip was laid down (`fileSize`, **session format 14**; absent in
anything written before it, and the sweep then falls back on the name). Best candidate first, and
a path with no match is simply left missing — finding nothing is a legitimate answer and not an
error. The walk is **bounded** (eight levels below the folder, four thousand directories) because
it runs on the main thread: pointing it at a whole drive would freeze the app, so it stops instead.
A package (`.app`, `.logicx`) is never entered.

**The window is fitted to the new file, never past its end.** A repaired or replaced clip may come
out SHORTER, in two steps and in this order: the window first **slides back** as far as it must —
the length that was chosen is worth more than the exact place it was taken from — and only if the
file is shorter than the window ITSELF is the **length cut**, the window then starting at the very
beginning of the file. `object.replace_source` answers `clamped: true` when either happened, beside
`duration`, `source_offset` and `file_duration`. The arithmetic reads the file range a clip
consumes, `[source_offset, source_offset + duration × speed]`, so the speed counts and the playback
direction does not. A length that cannot be read clamps nothing at all.

Two refusals worth branching on: `object.replace_source` on an **instance of a consolidated
object** is `invalid_state` (it reads its definition's wave, and the next re-bake would silently
put that wave back), and so is pointing a clip at the file it already reads. Everything else
missing — the object, the file, the folder — is `not_found`.

**`volumeOffline` is not `absent`**: a path under a `/Volumes/<name>` that is not mounted says the
file is on a disk in a drawer, not that it is lost. The app watches the mount notifications and
rescans by itself when the drive comes back, so that state mends itself with nobody asking. The
boot volume never reads as offline.

`tools/scenario_relink.py` asserts all of the above against a running instance, making and moving
its own wav files on disk.

### The session file: `.objekat`, which is JSON

A session is written as `<name>.objekat` since 25 September 2026 — **the content is the same JSON
it always was**. The extension exists so that the file belongs to OBJEKAT: the app's `Info.plist`
exports the type `org.labelpeche.objekat.session` (conforming to `public.json`, so anything that
reads JSON still reads it) and claims it as its owner, which is what makes a double-click in the
Finder open the session in OBJEKAT rather than in a text editor. One definition in the code,
`SessionFile` (`objekat/EditViewModel/SessionFile.swift`), which the plist must stay in step with.

- **A legacy `<name>.json` still opens** — from File › Open (the panel accepts both), from
  "Recent projects", through `project.open` / `tab.open` / `--project=`. It is never renamed
  behind the user's back: `project.save` (and ⌘S) write where they read, so a `.json` stays a
  `.json` until somebody gives it a NEW name.
- **A new name takes `.objekat`**: the menu's Save As (the name typed is a plain name, the
  extension is laid by the app) and `project.save_copy`'s manifest (`<folder>.objekat`).
- **The API writes the path it is given**, whatever its extension, as it always has:
  `project.save_as {"path": "/x/session.json"}` writes `session.json`. Scripts that name their
  files `*.json` keep working unchanged.
- The name shown for a project strips ONE of the two extensions, in any case: `Mix.objekat` and
  `Mix.json` are both "Mix", and a `p.objekat.json` stays "p.objekat".
- **Opening from the Finder** (double-click, a file dropped on the Dock icon, `open -a`) follows
  `tab.open`'s rules: the same file is never opened twice (its tab is brought forward), and it opens
  in a NEW tab — except over an untouched "Untitled" tab (no file, not modified, empty), which is
  reused, the ordinary case of a cold launch by a double-click. A refusal (a load, an export under
  way…) or an unreadable file is reported by an alert, the hand being in the Finder. There is no
  command for it: it is AppKit's own door, and `tab.open` already is its scripted equivalent.

### Reading a project without the app

Every manifest (`<name>.objekat`, or `<name>.json` before 25 September 2026) carries its own notice, under the `_readme` key, **at the head of the file**:
the keys are sorted on writing and "_" comes before the lowercase letters, so it falls first
under a reader's eye — human or model. It says the essential of what the file does not show:
that `items` is a tree, that the times are in seconds **except MIDI, in musical time**,
that `lane` is not the displayed row, that the paths are relative to the project folder.

`project.schema` serves **the same text**, from the same constant (`SessionSchema`): the API cannot
describe a format the files no longer follow. And `ProjectDocument.version` derives from it —
bumping the format forces you to open the file that carries the notice.

Cost: ~3 kB per version file. Negligible on a real project, visible on an empty one.

A few points of vocabulary that save mistakes:

- **A time selection's lanes are DISPLAY lanes.** An open group shifts everything
  below it. `object.list` returns `display_lane` beside `lane` — the first is the one to
  aim at.
- **An FX chain host is indifferently an object or a stem.** "A reverb on the Voice
  stem" and "on this clip" are the same gesture, with the same host identifier.
- **A send can be laid out of scope**: the model keeps it, silent, until a
  change of stem makes it routable. So `send.*` returns `routed` beside `enabled` — and
  `automated`, which says a curve holds the level and no hand may move it.
- **MIDI notes are counted in beats**, never in seconds: it is the only unit that survives
  a change of tempo.
- **No command opens a plugin editor.** With no graphics context allocated, that would
  only lead to a crash. Parameters are set through `plugin.set_param`.
- **There is no `freeze.*`.** Freezing is no longer a user action; `shared.*` replaces it.

---

## The clients provided

| file | role |
|---|---|
| `tools/objekat_cli.py` | a command-line client, stdlib only, which also serves as usage documentation |
| `tools/objekat_mcp.py` | a stdio MCP server, **its tools generated from `help`** |
| `tools/smoke.jsonl` | an `--exec` scenario (with no identifiers reused) |
| `tools/scenario_families.py` | a non-regression scenario, 131 steps and assertions over the eight families |
| `tools/scenario_markers.py` | markers / regions / comments: 78 assertions, including a cut, a reverse, an undo, a reload, the marks as snap targets, a region cropped and a mark that does not catch on itself |
| `tools/scenario_plugin_selection.py` | several plugin cards at once: 58 assertions (order, one undo per batch, stems, move/copy/link) |
| `tools/scenario_plugin_state_undo.py` | undoing a plugin's state: 10 assertions, a built-in and (with `--external=IDENTIFIER`) an AU — the value comes back, the plugin answers straight away, and the undo stays under 150 ms, which no reload can |
| `tools/scenario_stem_plugin_state.py` | the state of a plugin on a bus (Main, stem) is written into the file and does not leak between projects sharing the Main's UUID (V1/V2, Save As, copies, tabs): 39 assertions, launches its own headless instances (`--app=PATH`); the external half (Pro-Q 4 by default) needs a DEBUG build |
| `tools/scenario_selection_snap.py` | what a carried time selection lands on, through `timesel.snap_probe`: 21 assertions (the range's start on a mark, real mark over grid, object edge second, the end, snap off, the wall at zero, ⌥ and the cut scraps) |
| `tools/scenario_context_click.py` | what a right click decides, through `selection.context_click`: 50 assertions (the body selects like a left click, an already-selected object changes nothing, the upper half selects nothing, a point inside the range keeps today's menu, an empty lane gives the range's menu wherever the range lies, 'Group the selection' when clips are selected and no range, and no menu otherwise, a child, an infinite bus) |
| `tools/test_selection_move_snap.swift` | the precedence of that snap, compiled standalone: 19 assertions, no app needed |
| `tools/test_send_columns.swift` | the Send tool's knob columns, compiled standalone: 22 assertions, no app needed |
| `tools/test_synoptic_marquee.swift` | the marquee and ⇧'s box, compiled standalone: 21 assertions, no app needed |
| `tools/test_piano_roll_framing.swift` | where a piano roll opens — the notes framed, the window on a C: 31 assertions, no app needed |
| `tools/example-script/` | an example third-party script, to be copied into the scripts folder |

The MCP is declared like this on the client side:

```json
{"mcpServers": {"objekat": {"command": "/path/to/tools/objekat_mcp.py"}}}
```

MCP tool names not allowing the dot, `object.set_gain` becomes `object_set_gain`; the
reverse correspondence is kept in a table, never guessed.

---

## Third-party scripts

A script is **not** run inside the app: it is a separate process that connects to the
socket like any other client. That choice is structural — embedding an interpreter would put
third-party code in the thread that drives the audio engine, where an exception or an infinite loop
would cost the sound. Here, the worst a script can do is die.

**Location**: `~/Library/Application Support/Objekat/Plugins/<name>/manifest.json`
(the Scripts ▸ "Open the scripts folder" menu leads there).

```json
{
  "name": "Project report",
  "description": "Writes a summary of the open project and shows it.",
  "version": "1.0",
  "executable": "report.py",
  "arguments": [],
  "requires": ["app.info", "perf.census"],
  "menu": [
    { "title": "Project report", "arguments": [] },
    { "title": "Detailed report", "arguments": ["--detail"] }
  ]
}
```

| field | rule |
|---|---|
| `executable` | **relative to the script's folder**, must stay in it (`..` refused) and carry the execute bit |
| `requires` | the commands needed, checked against the registry **at load time**: an entry one of whose commands is missing is greyed out, with the reason in a tooltip |
| `context` | `"app"` (the default, absent = `"app"`) or `"object"` — where the entry shows (see below). Set on the manifest (every entry) or on one `menu` entry (that entry alone, overriding the manifest's) |
| `menu` | absent ⇒ a single entry, carrying the script's name |

The app reads the manifests **at launch**; Scripts ▸ "Reload the scripts" reads them again.

### `context`: the bar, or an object's own menu

An `"app"` entry (the default) shows in the bar's **Scripts** menu and receives no target — it
would have none to give it. An `"object"` entry has no business there either (nothing selected,
nothing to hand it): it shows instead in a **"Scripts"** submenu of an object's own context menu,
and is the one shape that receives `OBJEKAT_OBJECT_IDS` below. A manifest can mix the two, one
entry of each, or declare `context` once for all its entries.

The script receives environment variables:

| variable | content |
|---|---|
| `OBJEKAT_SOCKET` | the path of the socket to connect to |
| `OBJEKAT_PLUGIN_DIR` | its own folder (to write its files into) |
| `OBJEKAT_OBJECT_IDS` | **`"object"`-context entries only** — comma-separated uuids: the effective selection if the object right-clicked is part of it, otherwise the object right-clicked alone |
| `OBJEKAT_LANGUAGE` | the app's own UI language (`fr`/`en`/`es`), a default for anything the script itself localises |

The socket path goes through the environment and **never hard-coded**: that is what lets a
script work under `--socket=` too, hence facing several instances.

The app **does not wait** for the script to finish (it may work for minutes; blocking the main
loop would freeze the interface **and** the socket it is trying to use). If the API is not
enabled, the menu entry says so instead of leaving the script to fail on a "connection refused"
in its own error output.

### A failure is surfaced, not merely logged

A non-zero exit code is **reported to the user**, through the same dialogue mechanism as
anything else (`app.dialogs` in headless mode) — not left in the console for nobody to read. The
convention a script is asked to follow: **write your human-readable message on stderr, and exit
≠ 0**. The app captures an 8 KB rolling tail of stderr; on a non-zero exit it shows
`script.run.failed` with that tail, or `script.error.exitCode` (just the code) when stderr said
nothing at all.

### Driving a script from another client (`script.*`)

The same door a menu click uses, open to a script or to a headless test — without it, an
`"object"`-context entry and its `OBJEKAT_OBJECT_IDS` could only be exercised by a real click in a
real menu, which `--headless` has none of.

- **`script.list`** — the installed scripts (manifests read at launch, or since the last reload):
  `{"scripts": [{"name", "display_name", "available", "unavailable_reason", "entries": [{"title",
  "context"}]}]}`.
- **`script.run {script, entry?, ids?}`** — launches a script exactly as a menu click would: a
  **separate process**, not waited for (`{"started": true}` on success — no `pid`, nothing here
  tracks the launch beyond that; a failure is reported through `app.dialogs`, never by this call's
  own return, which only reports a **failure to start**, e.g. an unknown script or entry). `ids`
  (an array of uuids) feeds `OBJEKAT_OBJECT_IDS` for an `"object"`-context entry.

### What a script shows: `overlay.*`

A layer of PRESENTATION laid over an object by a script — words a transcription found, passages a
detector marked. Not an edit: `undo: none`, the project is not made dirty, nothing is written to
the session file or into an undo snapshot. Times are seconds **relative to the object's start**
(the frame an object's own marks live in), so the layer travels with the object.

**Lifetime.** A layer belongs to the **socket connection** that laid it (a task-local
`CommandCallContext.connectionID`; commands run by `--exec` share one owner). It is cleared by
`overlay.clear`, by that connection closing (a script that crashed or was killed leaves nothing
behind), by the object disappearing (deleted, undone, exploded) and by a document change (project
load, tab switch).

- **`overlay.set {id, texts?, zones?, replace?}`** — `texts`: `[{start, end, text}]`; `zones`:
  `[{start, end, color?, opacity?}]` with `color` one of `white|red|yellow|green|blue` (default
  white) and `opacity` 0…1 (default 0.3). A field that is **absent is kept**; a field that is
  present **replaces** that field; `replace: ["texts"|"zones"]` empties the named fields even when
  no new value comes with them (so a script can send only its zones at every setting, and only
  once the thousands of words). Sorted by the app. Answers `{id, texts, zones, rev}` (counts).
  `not_found` for an unknown object; `bad_params` for `start > end`, an unknown colour, or more
  than 20 000 elements in a field.
- **`overlay.clear {id?}`** → `{cleared: n}`; with no `id`, every overlay the **calling connection**
  laid.
- **`overlay.get {id, detail?}`** → `{id, texts: n, zones: [{start, end, color, opacity}], rev,
  owner_is_caller}`; `detail: true` adds `words`. `not_found` when there is none.
- **`overlay.list`** → `{overlays: [{id, texts, zones}]}`.

### A window a script asks for: `script.panel.*`

A script has no window (it is a separate process); it **declares** a panel and the app draws it — a
floating `NSPanel`, hidden with the app, opened only when there is an interface (**headless: the
panel exists and no window opens**). One panel per connection (a second `open` replaces the first).
Nothing here is an edit. Same lifetime as the overlays; also closed when its `object` disappears.

Controls: `{id, kind: "bool"|"number"|"button"|"choice"|"progress"|"section", label, value?, min?, max?, step?, unit?,
enabled_by?, options?, advanced?}`. A `number` needs `min < max` and `step > 0` and a `value` in range (default
`min`); a `choice` (drawn as a pop-up menu) needs a non-empty `options: [{id, label}]` (unique ids),
its `value` is an option **id** (default: the first option) and `values[id]` reads back that id as a
string — `input` / `update` refuse an id that is not one of the options (`bad_params`), and the
option labels, like every label, are the script's own data; a `bool` defaults to false; `enabled_by` names a `bool` control whose being unchecked greys this
one ("a box and a threshold" — the window draws that pair inline). `advanced: true` hides a control until the hand presses the window's **Expert** button (presentation only: the value is still read back, remembered and settable through `input`). The labels are the SCRIPT's own
data; the app's only texts are Validate / Cancel / Reset / Expert and the default title.

Two kinds are the script's own drawing and hold nothing a hand can set (`input` refuses them):
a `progress` is a bar the script drives — `value` 0…1, or `null` for "working, no idea how far"
(absent = 0); `script.panel.update` moves it (`values: {id: 0.4}` / `{id: null}`, clamped to 0…1)
and can rename what it says it is doing (`labels: {id: "Transcribing…"}`) — and a `section` is a
heading (a divider and its label) that groups the rows under it. Both are read back in `values`
(`section` has none).

- **`script.panel.open {title?, controls, object?, status?, busy?, remember?}`** → `{panel_id, rev: 0}`.
  `remember` (a key string, or `true` = the title): see "A panel that remembers" below; `get` answers it as `remember`.
  `bad_params`: duplicate id, `min >= max`, `step <= 0`, value out of range, `enabled_by` not a
  bool, a `choice` with no / duplicate options or a value outside them.
- **`script.panel.get {panel_id}`** → `{panel_id, rev, state: "open"|"validated"|"cancelled"|"closed",
  values, events: [{button}], status, busy}`. **Reading drains `events`.**
- **`script.panel.wait {panel_id, since_rev, timeout_ms?}`** — a **long poll**: answers as soon as
  `rev > since_rev` or the state is no longer `open`; at the timeout (≤ 5000, default 1000) it
  answers the current state, **no error** (the timeout is the script's heartbeat — it loops). The
  other connections keep being served while it waits.
- **`script.panel.update {panel_id, status?, busy?, values?, labels?}`** — the script writes back a status
  line, the busy flag, recalibrated values, progress values, control labels. **Never moves `rev`**: it would wake the script's own
  next `wait`. `rev` moves only when the hand acts.
- **`script.panel.close {panel_id}`** → `{closed: true}`; the connection closing does the same.
- **`script.panel.input {panel_id, values?, press?}`** — the HAND's door, for a headless test (the
  window goes through the same store function): sets values (numbers clamped to their range) and/or
  presses a button id, `"validate"` or `"cancel"`. Moves `rev` at once; the window's own slider
  drag coalesces `rev` to 30 Hz with a trailing bump so the last value is never lost.
- **`script.panel.list`** → `{panels: [{panel_id, title, state, object}]}`.

**A panel that remembers (`remember`).** Each validated setting becomes the default of the next
opening — the memory is the APP's and generic, the script writes nothing. (1) On `open`, every
hand-settable control (bool, number, choice — never a button, a progress or a section) takes the
remembered value if there is one and it still fits: same id, same kind of value, a number within
`min…max`, a choice among the current options; anything else is ignored value by value.
`values` in the answer of `get` already carry them. (2) Only **Validate** stores (`input`
`press: "validate"`); Cancel and the window closing store nothing. (3) The app adds a **Reset**
button to such panels (`input` `press: "reset"`, refused as `bad_params` on a panel without
`remember`): every control returns to the value the script DECLARED, `rev` moves like any hand's
input so the script re-reads them, and the stored entry is erased. (4) Storage: `UserDefaults`,
key `scriptPanel.<remember>`, a flat `{control id: bool | number | string}`. **Under `--no-recent`
or `--headless` nothing is read from or written to the real domain**: the entries live in a
dictionary of the process, with the same behaviour, so a scenario can assert it
(`tools/scenario_breath_eval.py`, section g, also checks that `defaults read` of the bundle shows
no `scriptPanel` key).

---

## Known reservations

- **Two concurrent clients can interleave their undos** on the asynchronous commands with the
  `bus` policy (laying the undo, then `await`). Harmless in sequential use. The fix
  would be a serialised queue **in the registry**, not a patch in the adapters.
- **The engine's deferred work is not observable** from Swift (see `wait_idle`).
- **`engine_nodes` is `null`** in `perf.census`: the audio graph's node count lives on the
  engine side and exposing it would take modifying `OBJEngineCore`.

# PROMPT — the command API / headless driving of OBJEKAT

> To be pasted as it is into a fresh Claude Code session, at the root of the repository.
>
> *A historical document: this is the prompt that produced the command API, kept as a record of
> the intent. What the API actually became is described by `command_api.md`, and `help` is the
> authority.*

---

## The goal

Add to OBJEKAT a **layer of named commands** allowing the model to be read and driven
from outside the process. Four uses aimed at, in order of priority:

1. **That Claude Code can test and measure the app on its own**, without my having to click.
2. Scripting the app in Python/bash (batch processing, generating sessions).
3. Driving the app through an LLM (via an MCP shim).
4. Opening the app **with no UI**, and letting third parties add functions through scripts/plugins.

A strong constraint: **break nothing of the existing app**. Everything added is additive;
the only refactors allowed are those listed in increment 3, and they must have
strictly identical UI behaviour.

---

## What you must know about the code before starting (already checked, do not re-explore it)

Xcode project: `objekat/objekat.xcodeproj`, target `objekat` (macOS, Swift 6 + SwiftUI).
The application code is in `objekat/objekat/`. The git repository = `objekat/` (branch `main`).
⚠️ `objekat-containerclip/` at the root is an **old stale clone**: do not touch it.

**The architecture is already favourable, and that is the starting point:**

- `EditViewModel` (`objekat/objekat/EditViewModel/`, 24 files, ~348 functions) carries **all**
  the model's mutation logic. It is `@MainActor @Observable` and references **no** state
  owned by a view (checked: no `@Environment`, no `GeometryReader`). It is the command
  layer; only addressing by name is missing.
- `OBJEngineCore` (`objekat/objekat/OBJEngineCore.h/.mm`, ~120 ObjC++ methods) is the only point
  of contact with Tracktion. A flat API, scalar parameters + UUIDs as `NSString`.
- `EditViewModel.engine` is wired **from the view**: `App/ContentView.swift:167`
  (`viewModel.engine = engine`), inside an `.onAppear`.
- The transport state lives **in the view too**: `isPlaying`, `playheadPosition`, `pausedAt`,
  `tempSoloEnd`, `tracktionLoopActive` are `@State` of `ContentView`, along with the playhead
  polling (`.onReceive(playheadTimer)`, lines ~124-162) and the Tracktion loop logic.
- Persistence is already `Codable`: `ProjectDocument`, `SoundObject`, `Stem`, `ObjectPlugin`,
  `MidiNote`… `EditViewModel+Project.swift` already has `encodedSession()`, `writeSession(to:)` (private)
  and `loadProject(from url:) -> Bool` (non-modal). That is the convention to generalise.
- The app is **not sandboxed** (`objekat.entitlements` has no `com.apple.security.app-sandbox`)
  ⇒ a free Unix socket, no app group to configure.
- The entry point: `App/objekatApp.swift`, `@main struct objekatApp: App` with a `WindowGroup` +
  `NSApplicationDelegateAdaptor`.
- The Tracktion engine is a **submodule**; the engine modifications are saved in
  `objekat/engine-patches/3.5/` (0001 to 0029). If you have to touch the engine — which is not planned here —
  you regenerate a patch, otherwise the code is lost.

**The modal sites to deal with (they block any UI-less mode) — an exhaustive list, already taken:**

| File | Line | Type |
|---|---|---|
| `EditViewModel+Project.swift` | 50 | `NSAlert` (opening a missing recent) |
| `EditViewModel+Project.swift` | 95 | `NSSavePanel` (`saveAs`) |
| `EditViewModel+Project.swift` | 201 | `NSOpenPanel` (`loadProject`) |
| `EditViewModel+Project.swift` | 266 | `NSAlert` (`confirmDiscardIfDirty`) |
| `EditViewModel+Project.swift` | 430 | `NSAlert` (`reportMissingPlugins`) |
| `EditViewModel+SaveCopy.swift` | 20 | `NSSavePanel` |
| `EditViewModel+SaveCopy.swift` | 322 | `NSAlert` |
| `EditViewModel+Bake.swift` | 177 | `NSAlert` (`bakeAlert`) |
| `EditViewModel+Plugins.swift` | 33 | `NSAlert` (missing plugins) |
| `EditViewModel+Stems.swift` | 44 | `NSAlert` |

---

## Design decisions already taken — apply them, do not re-litigate them

1. **Transport = a Unix socket, the JSON-lines protocol** (one JSON request per line, one JSON
   response per line). Path: `~/Library/Application Support/Objekat/objekat.sock`. No TCP, no
   HTTP, no external dependency: `Network.framework` (`NWListener` with
   `NWEndpoint.unix(path:)`) is enough. The server is **not** started by default: it is turned on by
   the "command API" preference (see increment 1) or by the `--api` argument.
2. **High-level commands, not a 1:1 mirror of the ViewModel.** Stable verbs
   (`object.split_at`, `object.set_gain`, `group.create`) that survive internal refactors.
   Each command is an adapter written by hand (Swift has no reflection over methods:
   there is no way to expose what exists automatically — do not waste time looking).
3. **Third-party scripts out of process**, speaking the same protocol. **No embedded interpreter**
   (no JS, no Lua): a third-party script must not be able to bring the audio engine down.
4. **Undo is carried by the bus, never by the caller.** The project's convention:
   `pushUndo` BEFORE the first mutation (and pop if nothing moved). A mutating command
   applies it itself; a script must never have to think about it.
5. **Every response is structured**: `{"id":…, "ok":true, "result":…}` or
   `{"id":…, "ok":false, "error":{"code":…, "message":…}}`. Never free text.

---

## The work, in increments

Each increment ends with a **build that passes** and a summary. Do not move to the next
increment without the build being green. **Stop after increment 2 and hand back to me for
runtime validation** before attacking 3 (which touches the existing app).

Build:
```
xcodebuild -project objekat/objekat.xcodeproj -scheme objekat -configuration Debug build
```

---

### Increment 1 — The bus and the transport

A new folder `objekat/objekat/CommandAPI/`:

- **`CommandRegistry.swift`** — a `[String: CommandHandler]` registry. One command =
  `(name, paramsSchema, handler: (JSON) async throws -> JSON)`. Plan from the start for:
  - execution systematically hopped onto `@MainActor`;
  - a typed error (`CommandError`) with stable codes: `unknown_command`,
    `bad_params`, `not_found`, `invalid_state`, `engine_error`, `timeout`;
  - a `help` command listing the commands and their parameters (introspection: that is what
    will let the MCP shim and third-party scripts generate themselves).
- **`CommandServer.swift`** — an `NWListener` on a Unix socket, one connection = one JSON-lines stream,
  several simultaneous clients allowed. Deletes the stale socket file on startup. Shuts down
  cleanly when the app quits.
- **`Commands+Core.swift`** — the first batch, ~20 commands:
  - `app.info` (version, current project path, engine state)
  - `project.new`, `project.open {path}`, `project.save`, `project.save_as {path}`,
    `project.get_state` (⇒ reuse `encodedSession()`, do not reinvent a serialisation)
  - `transport.play`, `transport.stop`, `transport.seek {seconds}`, `transport.state`
  - `selection.all`, `selection.clear`, `selection.set {ids}`, `selection.get`
  - `object.list` (id, kind, lane, start, duration, name, parent)
  - `object.add {path, lane, start}`, `object.remove {ids}`, `object.move {id, lane, start}`,
    `object.set_gain {ids, db}`, `object.duplicate {ids}`, `object.split_at {ids, seconds}`
  - `edit.undo`, `edit.redo`

  Wire them onto the ViewModel's existing methods (`newProject`, `loadProject(from:)`,
  `selectAll`, `clearSelection`, `selectIDs`, `removeSelected`, `duplicateSelected`,
  `splitAtCaret`/`split`, `updateVolume`, `adjustVolumeDB`, `undo`, `redo`…). If a method
  only exists in a "current selection" variant, the command lays the selection then calls it —
  do not duplicate the business logic in the adapter.

- **`ObjekatPreferences`**: a checkbox "Enable the command API" (off by default),
  plus handling of `--api` as a launch argument.

- **`tools/objekat_cli.py`** — a minimal Python client (stdlib only, zero dependency):
  `objekat_cli.py transport.play`, `objekat_cli.py object.add --path … --lane 2`, and a
  `--batch file.jsonl` mode. It is also the usage documentation.

---

### Increment 2 — Quiescence, batch and measurement *(the most important for use no. 1)*

Without this, every script is non-deterministic: the model defers a lot of work (a 120 ms
damper on the engine-side graph rebuild, the sound-object mirror debounce in
`EditViewModel+Objects.swift` ~line 1097, `needsChainCompile` → `syncPlugins`, the asynchronous
renders `renderGroupToFileAsync` / `renderClipToFileAsync` with completion blocks,
the waveform render in the background).

- **`Quiescence.swift`** — a counter of work in flight (`beginWork`/`endWork`) fed by:
  the ViewModel's debounces, the engine's render jobs, the re-bake cascades
  (`isCascadingRebake`, `recomputingDefinitionIDs`, `freezingIDs`).
  Command **`wait_idle {timeout_ms}`**: returns when nothing is in flight any more AND one turn
  of the main loop has gone by. A `timeout` error otherwise, with the list of what is still in flight
  (indispensable for diagnosing).
- **Asynchronous jobs**: the long commands (`render`, `bake`, `scan_plugins`)
  return `{job_id}` at once; `job.status {id}` and `job.wait {id, timeout_ms}` complete the set.
- **`batch`** — `{"cmd":"batch","commands":[…]}` run **inside a single**
  `viewModel.batchItemsMutation { … }` (it already exists, `EditViewModel.swift`) and under **a single**
  `pushUndo`. Without this, N commands = N rebuilds of the engine graph: exactly the
  performance regression we have just spent weeks eliminating.
- **`perf.measure {commands, repeat}`** — runs a sequence, returns the timings. Wire it
  onto the **already existing** instrumentation: `UIPerf.measure` / `UIPerf.measureFrom`
  (`EditViewModel.swift`, at the head) and the `OBJ_GRAPH_CENSUS` count on the engine side. Do not
  reimplement any timing, capture that one. Return **model time** and **frame time**
  separately — the distinction is the heart of the project's measuring method.
- **`perf.census`** — the graph's node count, the track count, the object count by type.

**⇒ A stopping point. A green build + a summary, and I validate at runtime.**

---

### Increment 3 — Removing the modals and extracting the session

A pure refactor, **UI behaviour unchanged**.

- For each of the 10 modal sites listed above: split into `func x()` (UI, opens the panel
  or the alert, calls the core) and `func x(url:)` / `func x(decision:)` (the core, with no AppKit).
  The model to follow: `loadProject()` vs `loadProject(from:)`, already in place.
  The confirmation alerts take an injected **policy**
  (`enum DialogPolicy { case ask, assumeYes, assumeNo }`) carried by the session, not a global
  boolean scattered about.
- **`ObjekatSession.swift`** — an object owning `OBJEngineCore` + `EditViewModel` + the transport
  state today stuck in `ContentView` (`isPlaying`, `playheadPosition`, `pausedAt`,
  `tempSoloEnd`, `tracktionLoopActive`, the playhead polling and the Tracktion loop sync).
  `ContentView` **observes** the session instead of owning that state; `objekatApp` instantiates the
  session. No visible change on screen, no keyboard shortcut modified.
  Check in particular: the temporary solo over a selection (stopping at the end of the window), the
  deferred activation of the Tracktion loop when the playhead enters the region, and the restoration of the
  persisted output device at launch.

---

### Increment 4 — The UI-less mode

- Replace `@main` on `objekatApp` with an explicit `main.swift` that reads the arguments:
  - with no argument → the normal SwiftUI app, identically;
  - `--headless` → `NSApplication.shared.setActivationPolicy(.prohibited)`, instantiate
    `ObjekatSession`, start the command server, enter the run loop **with no window**.
    JUCE needs an `NSApplication` and its run loop (`initialiseJuce_GUI()` is called in
    `-[OBJEngineCore init]`): "no UI" means "no window", not "no AppKit".
    Do not try to do without it.
- Arguments: `--headless`, `--project <path>`, `--exec <script.jsonl>`, `--api`,
  `--socket <path>`, `--no-audio` (a null device, for a machine with no sound card: the engine does
  `getDeviceManager().initialise(0, 2)` at init, so plan for the case where no device is available).
- A non-zero exit code if a command of the script fails.

---

### Increment 5 — Widening the commands

Purely mechanical and incremental, in order of usefulness. One command = one adapter.
- **groups**: `group.create` (from the selection / from a time selection), `group.disband`,
  `group.reparent`, `group.eject`, `group.expand`
- **stems**: `stem.add`, `stem.remove`, `stem.rename`, `stem.assign`, `stem.set_gain`,
  `stem.mute`, `stem.route_to_main`, `stem.level`
- **plugins**: `plugin.list_available`, `plugin.add`, `plugin.remove`, `plugin.move`,
  `plugin.toggle`, `plugin.get_params`, `plugin.set_param`, `plugin.link`, `plugin.unlink`
- **aux/sends**: `aux.create`, `send.set_level`, `send.enable`
- **MIDI**: `midi.add_note`, `midi.delete_note`, `midi.update_note`, `midi.transpose`,
  `instrument.set`, `instrument.remove`
- **fades / speed / reverse / pan**: `object.set_fade`, `object.set_speed`,
  `object.set_reversed`, `object.set_pan`
- **sound objects**: `object.make` (an asynchronous job), `object.open`, `object.close`,
  `object.cancel`, `object.detach`, `object.list`
- **time selection**: `timesel.set`, `timesel.copy`, `timesel.cut`, `timesel.delete`

---

### Increment 6 — Integrations

- **`tools/objekat_mcp.py`** — an MCP server on top of the socket, which **generates its tools from
  `help`** (no hard-coded list to maintain in duplicate).
- **Third-party plugins**: a folder `~/Library/Application Support/Objekat/Plugins/<name>/` with a
  `manifest.json` (name, description, menu entries, executable, required commands). The app reads
  the manifests at launch and adds the entries to a "Scripts" menu; running one launches the
  third-party process, which connects to the socket. Document the contract in
  `OBJEKAT - claude project/docs/command_api.md`.

---

## Working rules

- **French** in the code, the comments and the commit messages, like the whole project.
  *(A rule of its time: the project moved to English in September 2026 with a view to open
  sourcing it — see `CLAUDE.md`. Kept here as it was written.)*
  Dense comments explaining the *why*, in the style of the existing files.
- **Do not touch the engine** (`tracktion_engine/`): nothing here requires it. If you think
  otherwise, stop and explain why to me first.
- Respect the project's conventions: `pushUndo` before a mutation, `needsChainCompile` →
  `syncPlugins`, `derivedCopy`, coalescing continuous gestures.
- Known JUCE traps, already paid for once: no `toRawUTF8()` on a temporary;
  `getAutomatableParameters` by value; `String(const char*)` → `fromUTF8`; do not open
  a plugin editor with no context allocated.
- After each increment: a Debug build, a summary of what changed, and **tell me explicitly what
  is left to validate at runtime** (you cannot judge in my place what is heard).
- Separate commits per increment, on `main`.

## What I want your opinion on, not your silence

If while implementing you discover that one of my decisions above costs more than expected
(typically: quiescence if the deferred work turns out not to be cleanly instrumentable, or
the session extraction if the transport is more entangled in the view than it looks), say so
straight away with the cost observed, rather than working around it in silence.

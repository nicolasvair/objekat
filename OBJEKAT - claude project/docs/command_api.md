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

Quiescence **reads the existing state** (`freezingIDs`, `recomputingDefinitionIDs`,
`isCascadingRebake`, `isScanning`, the pending debounced work) instead of instrumenting the
hot paths: no counter to unbalance. In exchange, **the engine's deferred work
stays invisible** — that would take modifying `OBJEngineCore`. Hence `settle_ms`: a grace delay to
ask for explicitly when the measurement that follows depends on the audio graph and not on the model alone.

A `timeout` returns in `details` **what was still in flight**: a wait that expires without
saying what it was waiting for cannot be diagnosed.

### Jobs

Long commands return a `job_id` at once rather than lie about unfinished
work: `plugin.scan`, `definition.make`, `definition.edit_commit`.

```json
{"cmd": "definition.make", "params": {"id": "…"}}      → {"job_id": "job-1"}
{"cmd": "job.wait", "params": {"id": "job-1", "timeout_ms": 30000}}
```

`job.status`, `job.list` complete the set.

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

### Measurement

`perf.measure` separates `model_ms` (the model's work) from `frame_ms` (the time during which
the main loop stayed busy afterwards: SwiftUI invalidations, relayout). That
distinction is the heart of the project's measuring method. `perf.census` counts the project.

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
    --project=/path/project.objekat.json --exec=scenario.jsonl
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
| `--no-recent` | writes nothing into "Recent projects" (with or without a window) |
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
| `project.*` | new, open, save, save as, serialised state, the format notice |
| `transport.*` | play, stop, seek, state (including the **displayed** position) |
| `selection.*` | all, clear, set, read |
| `object.*` | add, delete, move, duplicate, cut, gain, pan, mute, fades, speed, direction, duration, trim, slip, rename, detail |
| `group.*` | create, dissolve, open/close, bring in, take out |
| `stem.*` | list, create, delete, rename, recolour, assign, gain, mute, routing to the Main, level |
| `plugin.*` / `instrument.*` | catalogue, chain, add, remove, bypass, move, copy, link, unlink, parameters |
| `plugin.trace.*` | capture a plugin's trace, play it in the plugin's place, list, purge |
| `aux.*` / `send.*` | create an auxiliary, lay and set sends |
| `midi.*` | create a clip, list/add/delete/modify notes, transpose |
| `definition.*` | reusable sound objects: creation, editing, detaching |
| `export.*` | render the mix into a file, follow the progress, cancel |
| `timesel.*` / `clipboard.*` | time selection, copy, cut, delete, group, paste |
| `wait_idle`, `batch`, `job.*`, `perf.*` | determinism and measurement |

### Plugin traces

`plugin.trace.capture` freezes what a plugin does to the signal it currently receives —
`y[n] = g[n]·x[n] + d[n]`, sample by sample — so that the session plays on a machine where the
plugin is absent. It is two or three offline renders, so it returns a `job_id` and `job.wait`
closes the loop. The job's result is the validation report: the residual, the flags, the weight.

The whole family matters more here than elsewhere, because **a trace can be judged with no
screen and no ears.** It is measurements from end to end: the null test between the two capture
passes says whether the plugin holds randomness, and the validation residual says whether the
reconstruction can be trusted. A script reads exactly what the panel shows.

`plugin.trace.use` has no equivalent in the interface's ordinary path, and it is the one to
reach for when checking the feature: it plays a slot from its trace on a machine that **has**
the plugin. That is the only way to compare, inside one session, what the plugin does against
what its trace does —

```
plugin.trace.capture   host=… plugin=…      # then job.wait
export.run             …/with-plugin.wav    # the plugin
plugin.trace.use       host=… plugin=… forced=true
export.run             …/with-trace.wav     # its trace
```

— and null the two files. Anything above the residual the capture reported is a bug in the
restitution, not in the capture.

`tools/trace_check.py` does exactly that, end to end, against a windowless instance:

```
objekat --headless --api --socket=/tmp/objekat.sock --no-recent --no-audio &
./tools/trace_check.py /tmp/objekat.sock
```

It traces a built-in **reverb** on purpose: a reverb puts signal where there is none, which is
the one case the `X_MIN` gate exists for, and it fills the tail window that nothing else would
exercise.

`plugin.trace.info` also reads the header back **from the file**, so it says what is on disk and
not only what the model believes. `plugin.trace.list` names every traced slot plus the trace
files nothing references any more; `plugin.trace.purge` deletes those. A trace is heavy — 8
bytes per sample per channel before encoding — and nothing else removes them: dropping a trace
from a slot deliberately leaves the file, because dropping a reference is undoable and deleting
a file is not.

The full specification, thresholds included, is in `docs/objekat-capture-trace.md`.

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
| Span: The whole project / IN–OUT | `range: "project"` (default) / `"inout"` |
| The IN and OUT fields | `start` / `end` |
| The Time / BPM unit selector | the shape of `start` and `end` (see below) |
| WAV / MP3 format | `format` |
| Rate | `sample_rate` |
| 16 / 24 bits | `bit_depth` (WAV) |
| Dithering | `dithering` (WAV) |
| Location + Name | `path` |
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

### Reading a project without the app

Every `.objekat.json` carries its own notice, under the `_readme` key, **at the head of the file**:
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
  change of stem makes it routable. So `send.*` returns `routed` beside `enabled`.
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
| `tools/scenario_families.py` | a non-regression scenario, 64 steps over the eight families |
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
| `menu` | absent ⇒ a single entry, carrying the script's name |

The app reads the manifests **at launch**; Scripts ▸ "Reload the scripts" reads them again.

The script receives two environment variables:

| variable | content |
|---|---|
| `OBJEKAT_SOCKET` | the path of the socket to connect to |
| `OBJEKAT_PLUGIN_DIR` | its own folder (to write its files into) |

The socket path goes through the environment and **never hard-coded**: that is what lets a
script work under `--socket=` too, hence facing several instances.

The app **does not wait** for the script to finish (it may work for minutes; blocking the main
loop would freeze the interface **and** the socket it is trying to use). The exit code is
journalled when it arrives. If the API is not enabled, the menu entry says so instead of
leaving the script to fail on a "connection refused" in its own error output.

---

## Known reservations

- **Two concurrent clients can interleave their undos** on the asynchronous commands with the
  `bus` policy (laying the undo, then `await`). Harmless in sequential use. The fix
  would be a serialised queue **in the registry**, not a patch in the adapters.
- **The engine's deferred work is not observable** from Swift (see `wait_idle`).
- **`engine_nodes` is `null`** in `perf.census`: the audio graph's node count lives on the
  engine side and exposing it would take modifying `OBJEngineCore`.

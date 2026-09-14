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
| `object.*` | add, delete, move, duplicate, cut, gain, pan, mute, fades **and their shapes**, speed, direction, duration, trim, slip, rename, detail |
| `group.*` | create, dissolve, open/close, bring in, take out |
| `stem.*` | list, create, delete, rename, recolour, assign, gain, mute, routing to the Main, level |
| `plugin.*` / `instrument.*` | catalogue, chain, add, remove, bypass, move, copy, link, unlink, parameters |
| `aux.*` / `send.*` | create an auxiliary, lay and set sends |
| `midi.*` | create a clip, list/add/delete/modify notes, transpose |
| `definition.*` | reusable sound objects: creation, editing, detaching |
| `export.*` | render the mix into a file, follow the progress, cancel |
| `crossfade.*` | open the seam between two neighbours into a crossfade, resize it, shut it, list them |
| `marker_lane.*` / `marker.*` | the rows of the marker band, and the markers and regions on them |
| `object.add_marker` … | the markers an OBJECT carries, in its own frame of reference |
| `comment.*` | free texts laid over a span of the timeline |
| `timesel.*` / `clipboard.*` | time selection, copy, cut, delete, **ripple delete**, group, paste |
| `wait_idle`, `batch`, `job.*`, `perf.*` | determinism and measurement |

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

`tools/scenario_markers.py` asserts all of the above against a running instance.

### Ripple

`timesel.ripple_delete` and `object.ripple_cut` do not merely remove matter: they **close the gap
behind it**, everything that followed sliding back onto the hole's left edge. What makes them worth
a command of their own is their **scope**, which is the container and nothing wider: a ripple laid
inside a group moves that group's objects, shrinks the group's own window by as much, and leaves the
group's neighbours, its parent and the rest of the timeline exactly where they were.

Three consequences a script has to know about:

- **Every lane of the scope is hollowed out**, not just those the time selection covered — that is
  what keeps the scope's internal synchronisation. So a ripple destroys matter the selection never
  named. `timesel.delete` is the gesture that does not.
- The scope is the **shallowest** container the gesture touches. `timesel.ripple_delete` returns it
  as `container` (`null` = the whole timeline): read it back rather than assuming it.
- `object.ripple_cut` reads the hole off the object it is given — `keep: "left"` removes
  `[seconds, that object's end]`, `keep: "right"` removes `[its start, seconds]`. The answer says
  which span went, in `removed_from` / `removed_to`.

A ripple whose scope is a **looping** group is refused (`false`, no undo step): that group's window
is a porthole onto a repeating pattern, and shortening the pattern would change every repeat at
once, including those the gesture never aimed at.

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
| `tools/scenario_markers.py` | markers / regions / comments: 39 assertions, including a cut, a reverse, an undo and a reload |
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

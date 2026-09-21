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
    --project=/path/project.json --exec=scenario.jsonl
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
| `project.*` | new, open, save, save as, serialised state, the snap, the format notice |
| `transport.*` | play, stop, seek, state (including the **displayed** position) |
| `selection.*` | all, clear, set, read |
| `object.*` | add, delete, move, duplicate, cut, gain, pan, mute, fades **and their shapes**, speed, direction, duration, trim, slip, rename, **infinite**, detail |
| `group.*` | create, dissolve, open/close, bring in, take out |
| `stem.*` | list, create, delete, rename, recolour, assign, gain, mute, routing to the Main, level |
| `plugin.*` / `instrument.*` | catalogue, chain, add, remove, bypass, move, copy, link, unlink, parameters, **a selection of several cards** |
| `aux.*` / `send.*` | create an auxiliary, lay and set sends |
| `midi.*` | create a clip, list/add/delete/modify notes, transpose |
| `definition.*` | reusable sound objects: creation, editing, detaching |
| `export.*` | render the mix into a file, follow the progress and the waveform as it grows, cancel |
| `crossfade.*` | open the seam between two neighbours into a crossfade, resize it, shut it, list them |
| `marker_lane.*` / `marker.*` | the rows of the marker band, and the markers and regions on them |
| `object.add_marker` … | the markers an OBJECT carries, in its own frame of reference |
| `comment.*` | free texts laid over a span of the timeline |
| `timesel.*` / `clipboard.*` | time selection, copy, cut, delete, **ripple delete**, group, paste |
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
| `plugin.drop` | the DROP itself — `mode` move/copy/link — onto an object or onto a bus's strip |

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

`plugin.move`, `plugin.copy` and `plugin.link` take **`plugins`** (a list) in place of `plugin`: one
card or a whole selection, the same three gestures either way. A link of several ties each card to
its OWN copy — an EQ and a reverb dragged together do not end up sharing their parameters.

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

#### Where a render shows itself, and what it shows

`export.panel` opens or closes the export window, and that decides where a render is WATCHED: with
the window open, a **direct** render stays in it — the waveform grows there, the progress runs
along its bottom edge, and one can listen to the file while it is written. A **background** render
closes it and the strip under the transport takes over. Closing the window by hand during a direct
render falls back to the strip too: the rule is one and the same, the strip shows whenever a job
exists with no window to show it in. `export.status` answers `panel_open` for that.

`export.run` **keeps** a window, it never opens one — same doctrine as the plugin editors: an
export driven by a script must not put a window on the screen of whoever is working.

`export.preview` reports what the window draws, read from the engine and from the file rather than
from the display's own cache:

| field | what it says |
|---|---|
| `peaks_filled` / `peaks_total` | how far the waveform has grown. The engine taps every rendered block (`OBJEngineCore.exportPeaks`); the buckets are a fixed resolution over the whole range, so the memory does not depend on the length. |
| `peak_amplitude` | the loudest sample seen so far, 0…1. It is the FILE's own peak — that is what makes the drawing checkable. |
| `audible_seconds` | how much can be listened to right now. |
| `rendered_duration` | the range being rendered, frozen at the start. |
| `source` | the file being listened to: the render's temporary wave, then the final file. |

`audible_seconds` is deliberately **not** the progress: the render runs ahead of the writer, which
flushes its header every six seconds of audio (`numSamplesPerFlush`). That flush is what makes the
file in progress a VALID wave one can open and play — no engine patch, no partial-header parsing.

Nothing of a render exists while it **prepares**: the engine's tap is only remade when the render
is really launched, and only zeroed when its graph is built, so it still answers the previous
export's shape in between. `peaks_filled` is 0 throughout that phase rather than the last render's
count.

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

Two refusals worth branching on: `object.replace_source` on an **instance of a sound object** is
`invalid_state` (it reads its definition's wave, and the next re-bake would silently put that wave
back), and so is pointing a clip at the file it already reads. Everything else missing — the object,
the file, the folder — is `not_found`.

**`volumeOffline` is not `absent`**: a path under a `/Volumes/<name>` that is not mounted says the
file is on a disk in a drawer, not that it is lost. The app watches the mount notifications and
rescans by itself when the drive comes back, so that state mends itself with nobody asking. The
boot volume never reads as offline.

`tools/scenario_relink.py` asserts all of the above against a running instance, making and moving
its own wav files on disk.

### Reading a project without the app

Every manifest (`<name>.json`, `<name>.objekat.json` before September 2026) carries its own notice, under the `_readme` key, **at the head of the file**:
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

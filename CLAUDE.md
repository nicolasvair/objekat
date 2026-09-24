# Continuity memo — OBJEKAT

The crossing point between Claude Code sessions. Under this name and at the root, it is **loaded
automatically** at the start of a session: no more hoping somebody thinks to open it.

The documents that are the authority, to be opened as needed:

- `README.md` (at the root, and what GitHub shows) — the project, its concept, its progress.
- `OBJEKAT - claude project/docs/architecture_decisions.md` — the architecture decisions.
- `OBJEKAT - claude project/docs/command_api.md` — the command API, the launch arguments,
  driving by script.
- `OBJEKAT - claude project/docs/glossary.md` — the vocabulary, FR → EN → ES.

And the session memory (`MEMORY.md` + the notes), which carries the detail of the projects: this
memo keeps only the state and the traps.

---

## Current state (19 September 2026)

Branch: `main`, and **the repository is open source** at `github.com/nicolasvair/objekat`.
What the public sees is **ONE commit** (`c89bfb0`): on 4 September 2026 the history was
squashed for publication. It is not lost — it is here, and only here. `git log` shows 728
commits on this machine because a **graft** (`git replace`, `refs/replace/`) hangs the old
history under the initial commit. That graft is local by nature and is NEVER pushed; the
branch `history` holds the old tip so that a `git gc` cannot take it. The consequence for a
session: **never `git push --mirror`** on this repository — it would send the graft, hence the
whole history. A second copy lives outside the repository, in
`../objekat-historique-avant-greffe-2026-09-04.bundle`.
Four local branches are published NOWHERE and must stay that way: `history`,
`sav-moteur-en-pistes`, `claude/tracktion-au-seamless-swap-j2t708` and
`claude/multilingual-ui-translation-1x8d35` (the last two are stale, the first two are not).
Engine base **tracktion 3.5**, in `tracktion_engine/` — the folder carried the version in its
name until 3 September 2026 (`tracktion_engine-3.2.0/`, wrong since the 3.5 bump); it no
longer does, so it can no longer go stale. The fork's branch is at `5a6855565a9` since
17 September 2026 (`f7fd2e9fd45` before it, when its own history was rewritten on 4 September);
`494e91d2ff5` is still its ancestor.
An engine series of **30** patches in `engine-patches/3.5/`, numbered `0001`→`0032` with two
holes: `0004` and `0010`, the only JUCE ones, were set aside on 3 September 2026 into `pending/`
(see its README). The next one will be `0033`. It is the ONLY series left: the four archives of
the 3.2 base went out on 4 September and were DELETED the same day, archive folder included —
they insured only `sav-moteur-en-pistes`, which is published nowhere. Nothing is lost for all
that: the engine branch they rebuilt, `objekat-patches` (head `8d4f23711df`, base Tracktion
v3.2.0), is still in the local clone `tracktion_engine/` of this machine, and that clone is now
its ONLY copy — a `git branch -D objekat-patches` there would be the point of no return.

What has landed since mid-August, in order:

- **The command API** (18 August) — a JSON-lines UNIX socket, ~105 commands, the windowless mode
  (`--headless --api --socket=`), third-party scripts, MCP. It is the test harness for everything else.
  The contract: `docs/command_api.md`. The details and traps: [[objekat-commands-api]].
- **Automation** (19 August, 5 steps) — a `ParamRef` model + points in time RELATIVE to the object,
  a curve editor in a band that REPLACES the content, pushed to the engine wholesale, a target
  selector founded on "touching = grabbing", and the curves surviving a cut / reverse /
  varispeed / copy / bake. Verified through an export + RMS, **not by ear**.
  The complete design: [[automations-conception-socle]].
- **An object's loop** (20 → 25 August, 4 rounds) — non-reversed audio clips, bounded groups,
  MIDI clips; IN/OUT bounds; a folded waveform and a dedicated cursor; the engine patch `0030` to
  disarm the local playhead's loop. The rule that comes out of it: **a looping group no longer has an
  edge, its window is a porthole onto a pattern** — the cut AND the time selection respect it.
  [[loop-item-plan]].
- **Time-selection gestures** (24 August) — ⌥ copies the SELECTION and not the whole object, and it is what
  you GRAB that decides; ⌥ pressed mid-drag flips the gesture; slipping no longer asks
  for a selection; dissolving a group makes room for its content; a direct solo pierces the
  muted groups it goes through.
- **The sound library** (24 August) — multiple import repaired: the batch goes through `public.json` and is laid down by
  the files' paths, with a single drop path (the Finder's).
- **Plugins** (19 → 25 August) — a plugin really does leave a stem's bus; an instrument
  bypasses, drags and links like any other plugin; the editor opens on adding; a
  movable window for the built-ins; reworked colours and plugin identity.
- **`--no-recent`** (30 August) — a test session no longer enters "Recent projects".
- **The timeline's hem** (30 August) and **a cursor that holds during playback** (31 August) —
  the latter with an expensive AppKit lesson, to be read before touching the cursor:
  [[curseur-timeline-appkit]].
- **The three languages, then English everywhere** (1 September) — the interface is localised in
  French, English and Spanish through a String Catalog with SYMBOLIC keys (see the permanent
  points below). Then the whole repository moved to English with a view to open sourcing it: Swift
  comments, tooling, documentation, this memo. The file and folder names followed
  (`OBJEKAT - claude project/`, `docs/command_api.md`, `tools/scenario_families.py`,
  `tools/example-script/`). The vocabulary is fixed by `docs/glossary.md`, which keeps its
  three columns — the French column stays the source, since that is where the vocabulary was born.
  **Nothing has been seen or heard**: the change touches only comments, documentation and
  the catalogue, and the machine that did it had no compiler.
- **Every hardcoded label routed into the catalogue** (2 September) — the 31 literals Xcode's
  extraction had poured into `Localizable.xcstrings` were sorted: real words through `L()`
  (9 new keys, values from `docs/glossary.md`), glyphs / units / numbers through
  `Text(verbatim:)`, deliberately empty labels through the new `noLabel`. Not one literal
  `Text("…")` is left in the project, and `check` answers `357 keys, 3 languages, nothing
  missing` again — which is the point: saturated, it could no longer say what was really
  missing. The trap itself is written up in the permanent points below, because it comes back
  at every build launched from the IDE.
  **This machine HAS a compiler** (Xcode 26.2): a build is from now on part of what can be
  verified with no screen, and it was run. Seen on screen: still nothing.
- **A first public release, `v0.1.0-alpha`** (5 September) — and the build settings it forced out
  into the open. The `Release` configuration carried NO optimisation level at all: neither
  `GCC_OPTIMIZATION_LEVEL` nor `SWIFT_OPTIMIZATION_LEVEL` was set, so the compilers fell back on
  their own defaults — `-O0` and `-Onone`. A "Release" that ran at Debug's pace. `NDEBUG` was
  missing too, and JUCE draws a precise conclusion from that: without it `juce_TargetPlatform.h`
  sets `JUCE_DEBUG = 1`, so the whole engine believed it was a debug build in the configuration
  meant for distribution. Now `-O3` / `-O` / `NDEBUG=1`, `wholemodule` having been there already.
  `MARKETING_VERSION` went from `1.0` to `0.1.0`, which is what the debt below actually deserves.
  Two ZIPs on the release, one slice each (arm64, x86_64), signed ad hoc and NOT notarised — the
  notes carry the `xattr -dr com.apple.quarantine` without which macOS says "damaged".
  Verified with no screen on the optimised binary: `tools/smoke.jsonl` passes whole, and a
  48 kHz / 24-bit WAV export re-read at RMS gives real signal. **Nothing has been seen or heard**
  of this build either. The procedure and its traps: [[publication-release-github]].

- **Ripple editing, bounded by the container** (9 September 2026) — ⌥⌫ over a time selection, and
  ⌥ + the Cut tool's drag: the passage goes AND the time it took goes with it, what followed
  sliding back. Its whole point is the SCOPE, which is the container and nothing wider: done
  inside a group it moves that group's objects, shrinks the group's own window by as much, and
  leaves the neighbours, the parent and the rest of the timeline where they were. Three rules that
  are not obvious and are written above `EditViewModel+Ripple`: EVERY lane of the scope is hollowed
  out (otherwise the internal synchronisation goes, which is ripple's whole reason for existing —
  so the gesture destroys matter the selection never named, and `timesel.delete` stays the one that
  does not); the scope is the SHALLOWEST container touched; a LOOPING container refuses the gesture
  (its window is a porthole onto a pattern). `deleteTimeSelection` was split in two for it —
  `carveTimeRange` removes the matter, the caller owns the transaction. Verified with no screen:
  build, eight cases through the API, and an export re-read at RMS proving the ENGINE followed and
  not just the model. Commands: `timesel.ripple_delete`, `object.ripple_cut`.
  **Not seen on screen**: the ⌥ preview band of the cut by dragging, and the two new cheat-sheet rows.
  Completed the same day by the ripple one reaches for FIRST: ⌥⌫ with OBJECTS selected and no range
  traced — an object is a passage one can see, so one selects it rather than tracing over it. It was
  falling back on the plain delete, which takes the matter and leaves the hole gaping. Same doctrine
  throughout, plus two rules of its own: the objects are rippled from the LAST to the FIRST (closing
  a gap only moves what comes after, so those still to do keep the position just read), and the
  selection is read through `effectiveSelectedIDs` (a child whose parent is selected too is dropped,
  otherwise the same gap closes twice). ⌥ wins over the Volume/Pan tools there — the modifier is an
  explicit demand, whereas resetting a value is what the BARE ⌫ means.
  Command: `object.ripple_delete`.

- **Shaped fades** (9 September 2026) — a fade now has a SHAPE beside its length: a FAMILY —
  straight, bulged, hollowed, and the two S's — and a BEND saying how far it leaves the straight
  line. One gesture carries all of it: the fade handle's HORIZONTAL travel says how long, its
  VERTICAL says how bent, and the origin is the object's own ROW rather than a number of pixels —
  while the hand stays on the block the fade is straight, leaving the row upwards bulges it and
  downwards hollows it, ⌥ turning the chosen family into the S that STARTS with it. A gesture whose
  limit one can SEE beats one calibrated in pixels.
  The bend is CONTINUOUS, and that is the point (it was five fixed shapes for a few hours on
  9 September, and snapping threw away everything the hand said past the first pixel outside the
  row): the first pixel outside barely departs from the line, the whole bend axis spans one
  block-height of travel, and the drag HUD reads the percentage so one can come back to the same
  curve twice. It is also RELATIVE — the vertical ADDS to the bend the fade already had, frozen at
  the gesture's start — so lengthening a bulged fade leaves it bulged, and only a hand that leaves
  the row touches the shape at all. ⌥ FLIPS the S rather than imposing it, since an anchored bend
  starts as often as not from a curve that is already one. And the double click that erased a
  fade's length erases its SHAPE with it — with the bend anchored, nothing else in the gesture
  brings a curve back to the straight line, and a bend left behind a cleared fade would lie in wait
  for the next time one pulled that edge. The same reasoning reaches every edge a CUT opens —
  the scissors, the cut by dragging, a hole pierced by a time selection or by an object dropped
  over another (`EditViewModel.freshCutCurve`, 21 September 2026): each half keeps the edge it
  already had, fade AND shape, and the two faces of the cut are born bare, the shape cleared with
  the length. A fade merely SHORTENED by matter going is not one of them — there the edge is the
  old one with less room, and it keeps its curve. What
  gives the travel somewhere to GO is the family being a power `a^p` and not the quarter-sine it
  started with: `bend` maps to the exponent as `8 ^ bend` — geometric, which is what the eye and the
  ear read as an even progression — so the sine's whole bend now sits at about a third of the
  travel. The power keeps what made the sine beat a logarithm (it reaches exactly 0 and 1 at its
  ends, no clamp pulled out of nowhere at the silent end) and adds what the sine did not have:
  `a^p` and `a^(1/p)` are exact reflections through the diagonal, so bulged and hollowed are the
  same amount of bend seen from either side.
  The fact that makes this cheap, and that is worth knowing before touching a fade anywhere:
  **every fade in OBJEKAT already lives in `ObjWindowFadePlugin`** at the tail of the object's
  chain — clip, MIDI, group and aux alike — and Tracktion's own clip fades are held at zero on
  purpose (`OBJEngineCore.mm`, `updateGroupWindow:`), otherwise the graph's `FadeInOutNode` would
  apply them a second time. So the shape went into ONE `envelopeGain`, with no engine patch and no
  second implementation. Closed forms per sample, never automation points — and the exponent is
  computed once per BLOCK, never per sample. `FadeCurve.gain` and `ObjWindowFadePlugin::curveGain`
  are mirrors, and `WaveformShaping.fadeEnvelope` reads the first: the drawn waveform, the veil on
  the block and what is heard all come from one definition — so "is it only the display?" always
  has the same answer, no.
  Verified with no screen: **a build, and nothing more** — the five shapes at full bend had been
  rendered and measured against independent formulas before the bend became continuous, but the
  power family that replaced them has been HEARD by nobody and MEASURED nowhere. Command:
  `object.set_fade_curve` (`in` / `out` for the family, `in_bend` / `out_bend` 0…1).
  **Not seen on screen**: the veil bent to the curve, the drag HUD naming the shape and its
  percentage, the cheat-sheet row.

- **Markers, regions and comments** (14 September 2026) — three levels of mark, and one type behind
  two of them: a marker and a region are the SAME `Marker`, `duration == 0` making it a point. That
  is what keeps the drawing, the hit-testing, the renaming, the deletion, the persistence and the
  API surface single instead of doubled. A band under the ruler holds the lane marks, one row per
  MARKER LANE, shown and hidden one by one from the clamp at its right — so each person passing
  through a project can have their own row without hiding anyone else's. An object carries its own
  markers, and they are stored in the object's frame like automation points, so they go through the
  same five primitives (`shiftedInTime`, `timeScaled`, `mirroredInTime`, `splitInTime`,
  `splicedInTime`) and survive a cut, a reverse, a varispeed, a copy and a bake. A comment is a text
  laid on the timeline with NO engine object at all — the first item in OBJEKAT with none, which is
  why it went into a separate annotation layer rather than becoming a `SoundObject.Kind` (measured:
  `case .aux` reaches 22 files / 62 sites, and an aux still has an engine object). The accepted cost
  is written above `TimelineComment`: a comment inherits nothing from the gestures.
  Three rules worth knowing. Creation is the RIGHT CLICK's alone — a band that laid a marker at every
  click would fill with marks nobody meant; a region and a comment take their span from the TIME
  SELECTION, because the timeline already has a way of saying "this passage" and no second gesture
  was invented for it; and the selection is ONE slot (`AnnotationSel`), held exclusive by a `didSet`
  on `selectedIDs`, so ⌫ and ⌘R gain one branch each rather than three.
  The trap it had to fix, which will come back for anything else laid in the header: both AppKit
  monitors captured `rulerHeight` ONCE at registration, and that height now GROWS with the rows
  shown. They read it live, through an allocation-free `visibleMarkerLaneCount`.
  Verified with no screen: a build, 21 assertions on `Marker.swift` compiled standalone, and the 39
  assertions of `tools/scenario_markers.py` against a headless instance. Session format 10 → 11.
  Commands: `marker_lane.*`, `marker.*`, `object.*_marker*`, `comment.*`.
  **Not seen on screen**: the band itself and every pixel of it — the rows, the clamp menu, the
  markers on the blocks, the comments and their markdown, and the eleven new labels in three
  languages.

- **The marks answer to the hand** (14 September 2026, the same day, after a first reading on
  screen) — six things the band was missing once one had actually used it. **Deselecting leaves the
  inline field**: it hangs off a `didSet` on `selectedAnnotation` rather than off the dozen places
  that deselect, and leaving COMMITS what was typed rather than dropping it (a latch in the two
  field views, since Esc, Return and the field's disappearance all end the edit and the last fires
  on the way out of the other two). **A mark of the band is dragged**, on ONE AXIS at a time — the
  first few pixels say which, and it does not change for the rest of the gesture: a row is 17 px
  tall and a marker is a hairline, so a hand aiming sideways would cross two rows on its way.
  Left/right moves it in time (on the timeline's own snap), up/down changes ROW — a real move,
  `moveMarkerToLane`, keeping the id so the selection and the undo follow. **Colour**: a mark, a
  region and a comment each take a hue by right click, and the hue is INHERITED until it is asked
  for — a mark of the band takes its ROW's (so a right click on the row's colour DOT recolours the
  whole layer), a comment and a mark on an object are WHITE. White for a comment is the point of
  it: it is not in the object palette, so a note never reads as one more object on the lane.
  **A comment is dragged and cropped** like a clip — body moves, the two ends crop, the same
  cursors. **Creating a row left the band's menu**: it belongs to the lanes' button and there only.
  And that button is now a flag (`flag.square.fill`) rather than a filter glyph that said 'narrow a
  list down'.
  The trap, and it is general: an AppKit LOCAL monitor sees a right click BEFORE the view hierarchy
  does, so an `NSView` overlay laid on the lane's colour dot would never be reached — the dot is
  hit-tested geometrically like everything else in the canvas (`markerLaneDotHit`), against a
  `dotXRange` the header view declares and both places read.
  Verified with no screen: a build, and the API suites — `scenario_markers.py` grown to 57
  assertions (all pass), `smoke.jsonl` and `scenario_families.py` (74 OK) clean. New commands:
  `marker_lane.set_color`, `marker.set_color`, `marker.set_lane`, `object.set_marker_color`,
  `comment.set_color`; `color_index: null` in an answer means 'inherited'.
  **Not seen on screen, nor felt**: every one of the gestures — the axis lock, the snap under the
  hand, the row change, the comment's crop handles and their cursors — and every colour they lay
  down, the white of a comment included.

- **A comment follows its lane** (14 September 2026) — it stored the DISPLAY row it was drawn on,
  so opening a group, a piano roll or an automation band above it pushed every lane down and left
  the note behind, beside somebody else's material. It stores a BASE row now — `SoundObject.lane`'s
  own frame — and the conversion happens at the three places that need it: the drawing, the
  hit-testing and the vertical half of its drag (where the hand travels in DISPLAY rows and the
  result is converted back, otherwise the note jumps over as many rows as an open group has
  children). It is one more case of the project's oldest recurring bug, so the forward conversion
  moved into the view-model beside its own inverse — `displayLane(forBase:)` next to
  `baseLaneForDisplay` — where the two cannot drift apart. Verified with no screen, which it can now
  be: `comment.list` answers with `display_lane` beside `lane`, and three assertions of
  `scenario_markers.py` open a group and watch the comment move down and come back.

- **Right widens, and the selection walks** (14 September 2026) — three small things read off the
  same day's use. **A crossfade's top triangle now has ONE meaning**: to the right widens the fade,
  to the left narrows it, wherever inside the zone the hand came down. It used to push the NEARER
  EDGE outwards, so the gesture's meaning flipped at the zone's midline and the same travel
  widened or narrowed depending on where one had taken hold — a gesture whose direction one has to
  work out is a gesture one does not trust. The symmetric widening is what it always was, both
  edges moving by `dx` each, so only the sign changed: `rawWidth = anchorWidth + 2 * dx`, and
  `widenSign` (with the `alpha` that fed it) is gone from the drag state.
  **↑ / ↓ move the TIME SELECTION and not the matter** — the traced passage slides onto the lane
  above or below, keeping its span of time and its height, and not one object changes lane. No undo
  step: nothing moved. (Written for the OBJECT selection first, on a misreading; and then, once
  re-aimed, the arrows still beeped because their condition was `flags.isEmpty` — see the permanent
  point below, an arrow is never bare. Both times the symptom was the same beep, and both times it
  said the same thing: the key had fallen THROUGH every branch, so what to read was the condition,
  not the body.) An EMPTY row is a row like any other here, unlike an object selection:
  a range on an empty lane means something, it is where a paste lands and where a comment is laid.
  At row 0 and at the last row the timeline draws it stops, keeping the selection whole rather than
  clipping it.
  **And the marks entered the notice the session file carries**, which is the whole point of that
  notice — the format was writing `markerLanes` and `comments` that nothing described. Format 11 →
  12, the rows and the marks with their field lists, the two frames of reference (the band's times
  are ABSOLUTE, an object's are RELATIVE to it and can go negative behind an edge), and the two
  exceptions worth a line each: a mark's `colorIndex` is written ONLY when it was asked for
  (no key = inherited), and a comment's `lane` is a BASE row.
  Verified with no screen: a build, `scenario_markers.py` (60 assertions, all pass, the format one
  now reading 12), `smoke.jsonl` clean, `scenario_families.py` 81 OK with five new assertions on
  the arrows — including that **not one object moved** while the passage travelled.
  New command: `timesel.step_lane`.
  The arrows were FELT on 15 September and they work — the one thing still unseen there is the
  bottom stop, whose ceiling `displayLane(forBase: maxLane + 1)` is the model's half of
  `TimelineView.visibleLanes`, two calculations nothing compares (and a range traced BELOW the
  lowest object used to send ↓ upwards, the ceiling having gone negative — clamped at zero since).
  **Not felt**: the crossfade gesture under the hand.

- **The snap belongs to the project, and the pan gets its detent back** (15 September 2026) — two
  things read off the same session's use. **The snap is saved with the file**: it starts ON (the
  app's start and a fresh project both), but a session built OFF the grid reopens off it, instead of
  asking for the same toggle at every open. It is a PROJECT's setting and not a preference of the
  app, which is why it went into the document (`snapEnabled`, format 12 → 13) rather than into
  `UserDefaults` — and a file written before that has no key, so it opens with the snap, the default
  and not a decision.
  **The pan clicks onto the tenths again — for any number of objects.** Taking the quantum out of
  the model on 12 September was right, but it took the DETENT away with it, and the detent is what
  one aims the centre and the two edges with. It comes back in the GESTURE and not in the model:
  `applyPanDelta` rounds when the snap is on, ⌘ (or the snap off) giving the fine adjustment back.
  What made the old quantum cancel a multiple drag outright was not the rounding, it was
  COMPOUNDING: each ~0.0125 delta was added to the STORED value and rounded straight back onto the
  tenth it came from, so the travel was thrown away on every frame and the gesture moved nothing,
  for ever. The gesture holds ANCHORS and hands over its TOTAL travel since, so the rounding lands
  on the result and never feeds the next frame — a slow drag simply waits until the total crosses
  the half-step, which is what a detent IS. Accepted cost, and it is the reason the first version of
  this kept multiple selections continuous: an object whose pan was not on a tenth is brought onto
  one, so the spread can shift by up to half a step. Round values won that one. The Pan TOOL's drag
  was running its own loop beside all this: it goes through `applyPanDelta` now, which is how the
  tool and the inspector's box came to disagree in the first place.
  Verified with no screen: a build, `scenario_markers.py` (63 assertions — the snap written into
  the file, a new project back on the grid, the project reopening off it),
  `scenario_families.py` 90 OK, `smoke.jsonl` clean, i18n 393 keys. What no suite can reach is the
  drag's own invariant — one anchor held for the whole gesture, the total travel handed over each
  frame — since every call of `object.adjust_pan` takes a fresh anchor. Only the hand sees that one.
  New commands: `project.set_snap`, `object.adjust_pan`.

- **And the pan's detent is UNCONDITIONAL** (15 September 2026, the same day, read off the hand) —
  hanging it on the grid's snap was wrong twice over. A session built OFF the grid — which the same
  day's other change made persistent — had no detent at all; and the snap never reached the control
  one actually pans a SINGLE object with, the synoptic's box, which SETS an absolute value through
  `updatePan` instead of adding a delta. So a lone object slid continuously, 13 %, 17 %, and its
  ↑ / ↓ arrows walked in HALF-tenths (`keyStep: 0.05`) besides. The rule now: **a pan a hand lays
  down is on a tenth, always** — no snap, no ⌘ escape, since a modifier that leaves 13 % behind in
  the file is the intermediate value under another name. It lives at the two doors a hand comes in
  by, both of them going through one definition (`EditViewModel.detentedPan`): `applyPanDelta` for
  everything that ADDS (the Pan tool, the inspector's box, the ±0.1 arrows, the wheel) and
  `setPanFromHand` for what SETS (the synoptic's box). `updatePan` stays exact, because it is the
  machine's door (`object.set_pan`) and the automation's — a script asking for 0.37 gets 0.37, a
  curve plays what it draws. The inspector's box quantises its own displayed value too: `relPan` is
  a local accumulator nothing reads back from the objects, so a display left continuous would read
  13 % over a model sitting on 10 %.
  Two things the inspector's box was reading wrong, found on the same reading. In RELATIVE mode (a
  selection whose pans differ, so the box shows a travel and not a position) it dropped the unit and
  printed `-0.50` — where the row above it says `+3 dB`, and where the direct entry parses a
  PERCENTAGE, one typing 50 for a half. It reads `-50%` now. And the absolute label TRUNCATED
  instead of rounding (`Int(-p*100)`): a tenth held as a `Float` is 0.69999…, so a pan set to 70 %
  displayed `R 69%` — the synoptic's own label had been rounding all along, which is why only one of
  the two lied.
  Verified with no screen: a build, `scenario_families.py` 92 OK (the tenth with the snap ON and the
  snap OFF, `object.set_pan` still exact, several objects, and ten steps landing on the edge),
  `scenario_markers.py` ALL PASS, `scenario_plugin_selection.py` 48 assertions, `smoke.jsonl` clean,
  i18n 393 keys.
  **Not felt**: the detent under the hand in the synoptic's box and under the Pan tool, and whether
  losing the fine adjustment is ever missed.

- **Several plugin cards at once** (15 September 2026) — the signal view held ONE selected card, in
  a `@State` of its own view. It holds a SET now, and that set lives in the VIEW-MODEL
  (`selectedPluginIDs` + `selectedPluginHostID`), for two reasons that are the whole design: every
  batch gesture needs the chain's READING ORDER, which only the model knows — a `Set` has none, and
  plugins laid down in the wrong order are a different sound — and a selection nothing can drive is
  a selection nothing can verify with no screen. On the lot: ⌫, on/off, ⌘D, ⌘C/⌘V, and the drag
  onto another object speaking the same three gestures it always did (nothing = move, ⌥ = an
  independent copy, ⌘ = a copy that stays linked). An object and a STEM are the same host
  throughout — free, everything going through `chainPlugins`/`updateChainPlugins`.
  **One undo per gesture, not per card**, which is what forced the shape: `transferPlugins` is the
  real implementation and `movePlugin` / `copyPlugin` / `linkAcrossObjects` are now three one-line
  doors onto it, rather than two places for the link, the colour and the live state to be got
  subtly wrong. A link of several ties each card to its OWN group (an EQ and a reverb dragged
  together must not come to share their parameters).
  Picking cards is GEOMETRY, and it went into a unit that knows nothing else —
  `SynopticMarquee`, an id and a rectangle, no view, no model, no layout — precisely so that the
  half of the feature with nothing behind it can be compiled alone and asserted:
  `tools/test_synoptic_marquee.swift`. Two rules, and they deliberately DIFFER: a marquee takes
  what it contains ENTIRELY (the clips' rubber band, word for word — on a canvas where branches sit
  side by side, taking what one merely brushed sweeps up the neighbouring branch), while ⇧ takes
  what its box INTERSECTS (the clips' `extendSelectionTo`, word for word too — a box deduced from
  cards has its edges ON them, never around them). ⇧ adds during a drag, ⌘ flips, and the three
  things a marquee decides — whether there is one at all, what the modifiers mean, and what was
  already held — are decided at the FIRST pixel and never again.
  The trap, and it is the one this whole feature had to answer: **the keyboard**. ⌫ ⌘C ⌘V ⌘D
  were the timeline's, and the objects' selection is what SHOWS the signal view — so the usual
  exclusivity (`selectedAnnotation`) was not available, clearing it would have taken the chain off
  the screen under the hand. The rule is the SELECTION ITSELF as the claim, with no separate focus
  flag: a host recorded (a card clicked, or merely the view's empty space) takes the four keys, and
  the FIRST click back in the timeline gives them all back — `clearPluginSelection`, called at the
  door of the tap and drag handlers rather than in their dozen branches. The host is kept EVEN FOR
  AN EMPTY SET, so ⌘V can land in a chain that has no card yet to click on; the price is a handful
  of keys that do nothing while the view holds them with no card chosen, which is the harmless half
  of the alternative — the other half was ⌫ deleting the OBJECT with the hand plainly elsewhere.
  An INSTRUMENT is not in this selection: it lives in `SoundObject.instruments`, not one batch
  gesture can touch it, and letting it into the set would arm them all over something they cannot
  reach. It keeps a highlight slot of its own.
  Three things came out of USING it, the same day. The power button and the ✕ of a card that is IN
  the selection now speak for the WHOLE selection (a card outside it still speaks for itself — the
  drag's rule, and the clips' before it): without that the batch on/off existed in the model and in
  the API and was **unreachable from the hand**, which is its own lesson — a model function with no
  door onto it reads as finished and is not. And **a bypass became undoable**, all three of them:
  one card, the instrument, a whole selection (ONE point for the batch). None of them pushed one,
  on the reasoning that a realtime flag honoured by `PluginNode` is not an edit — nothing is
  recompiled, the graph keeps its shape. Wrong reasoning, and the test is the ear: a bypass CHANGES
  WHAT IS HEARD, which is the only thing that qualifies a gesture for ⌘Z. `plugin.toggle` and
  `plugin.toggle_selected` moved from `undo: .bus` to `.handled` with it — the bus used to push the
  point the method lacked, so the API path had a ⌘Z the BUTTON never had.
  And **a card is dropped on a BUS's strip** in the toolbar. A stem has no block of its own in the
  timeline — its band is infinite and belongs to a group or an aux, the Main has nothing drawn at
  all — so the strip is the only thing a hand can aim a bus with, and without it the whole drag
  vocabulary stopped at the objects: a chain built on an object could not be carried up onto a bus,
  which is half of what one builds stems FOR. What a drop DOES is now one function,
  `acceptPluginDrop` (+ `PluginDrop.receive` for the pasteboard half), the timeline's own branch
  having moved into it rather than being copied — the modifiers are read at the drop and carried
  into the async load, because a payload arrives after the hand has let go of ⌥. An instrument
  dropped on a strip does nothing, and needs no guard of its own: `transferInstrument` already asks
  for a MIDI object. `plugin.drop` is the same door for a script, which is what makes any of this
  assertable with no screen — `plugin.move|copy|link` reach the transfer directly and never touch it.
  Read off the hand straight after, and it is the general lesson of the whole thing: **a drop
  target carries its own feedback, in its own layer.** The strip first used SwiftUI's convenience
  `.onDrop(of:isTargeted:perform:)`, which proposes `.copy` to everything — so it badged a '+' on a
  MOVE, where the timeline shows none, and the same gesture read differently depending on where the
  hand was taking it. Only a `DropDelegate`'s `dropUpdated`, called again on every movement, can
  say what the cursor shows; the rule itself is now one function both doors read
  (`PluginDrop.operation`). And the ⌘ maillon is drawn BY THE STRIP rather than by the timeline's
  canvas: the timeline's `pluginLinkDropLocation` badge lives in the main window, and a popover is
  another WINDOW above it — nothing drawn down there can come in front, which is exactly what the
  stem's own FX popover was hiding it behind. Same glyph, same `LinkColor.plugin`, and it FOLLOWS
  THE CURSOR as the timeline's does: `DropInfo.location` is already in the drop view's own
  coordinates, so the strip draws it with nothing converted — which is the whole reason it is the
  strip that draws it and not the bar. The one difference is a clamp, and it comes from the size of
  the thing: a strip is some 23 pt tall, so the timeline's (+18, −18) would put the maillon over
  the window's chrome instead of beside the pointer. Inside those bounds it still tracks the
  horizontal, which is the axis one travels along a bar of buses, and the clamp lets go by itself
  if a strip ever grows. The border turns that yellow with it.
  **And the marquee takes what it TOUCHES**, not what it contains. Containment was the clips' rule
  carried over, and the reasoning for it (a rectangle down one branch would sweep up the neighbour
  it grazes) lost to the hand on the first day: a card is 124 pt wide in a narrow column, so asking
  for the whole of it means drawing AROUND it, and a short drag over one card chose nothing at all.
  A brushed neighbour costs one ⌘+click. The two rules of `SynopticMarquee` agree now, and the only
  difference left between them is where the rectangle comes from.
  Verified with no screen: a build, 21 standalone assertions on the geometry, 58 on
  `tools/scenario_plugin_selection.py` against a headless instance (order, one undo per batch,
  stems, move/copy/link, the drop onto a bus and back off it, what a batch refuses, the ⌘Z of a
  bypass), `smoke.jsonl` clean, `scenario_families.py` 92 OK,
  `scenario_markers.py` ALL PASS, i18n 393 keys, and `CGWindowListCopyWindowInfo` on the headless
  pid: no window.
  Commands: `plugin.select` / `selection` / `deselect` / `remove_selected` / `toggle_selected` /
  `duplicate_selected` / `copy_selected` / `paste` / `drop`; `plugin.move|copy|link` take `plugins`
  (a list) in place of `plugin`.
  **Not seen on screen, nor felt**: the rectangle's veil under the hand and the accent border a
  strip takes while a card hovers over it; ⇧'s box and whether what it sweeps up across two
  branches is what one meant; ⌘ one by one; and above all the hand-over of the keyboard between
  the two surfaces — whether a click in the timeline really does feel like giving it back.

- **Five things read off one session's use** (15 September 2026) — four gestures and a label, each
  small, and each one a place where what was drawn and what answered the hand had come apart.
  **A crossfade no longer hides the send knobs.** The Send tool lays its columns at the block's
  LEFT EDGE, and a crossfade zone is the span two objects SHARE — so the right-hand one's knobs
  were drawn over pixels its neighbour occupies too, and the click went to whichever of the pair
  the hit-test met first. They start after the shared span now, on the first pixel that belongs to
  this object alone. The geometry moved out into a unit of its own (`SendColumns.swift`,
  `sendColumnIndex`) so the display and the hit-testing read ONE definition — a knob one can see
  and cannot turn is what happens the day those two drift — and it can be asserted with no screen:
  `tools/test_send_columns.swift`, 22 assertions (written, never run — see below). The hit-test also asks EVERY candidate under the
  point instead of the first: over a zone there are two, and `first(where:)` was picking by the
  model's own order.
  **An infinite bus is carried to another row.** Its band has neither start nor end, so a drag on
  it did nothing but select; what it does have is a ROW, and that is the gesture — vertical only,
  the horizontal travel read by nobody. The rule is the band's own, and it is ONE definition
  (`infiniteBusLanding`) that the drag and `object.move` both go through: an empty row takes it, a
  row holding ONE other infinite bus SWAPS with it (reordering a stack of buses needs no free row
  to shuffle through), any other occupied row refuses it — a full-width band set down on a clip
  would cover it whole, which is what `moveInfiniteBusToOwnLane` exists to avoid at creation. The
  preview band says the refusal while the hand can still go elsewhere, and the ↕ cursor over a bus
  replaces the trim/fade/move zones `selectionZoneHover` was carving its stored window into —
  three gestures the drag never performed. New command: `object.set_infinite` (there was no door
  onto the infinite at all, so none of this could be verified with no screen).
  **The view goes past the last object, by 40 %.** Downwards: empty ROWS and not a padding, so
  many that the lowest row can be scrolled up to 40 % of the lane area — they take their
  alternating band, they can be aimed at, a range traced on them means something. Rightwards: the
  canvas keeps 60 % of the window empty after the last object, and the same number bounds the zoom
  out — `minZoom = viewportWidth / totalDuration` has a fixed point at `0.4 · viewportWidth /
  contentEnd`, the scale at which the project fills the first 40 % of the screen, which is the rule
  asked for falling out of the arithmetic rather than being clamped on top of it. The headroom is
  added to `totalDuration` and NOT to `contentDuration`: the sticky length goes on answering to the
  objects alone, otherwise it would grow and shrink at every wheel notch. The 60 s floor keeps its
  say for a short project.
  **↑ / ↓ read an object selection too.** They moved the traced passage and nothing else; with
  objects selected and no range traced the key fell through every branch unconsumed, which is the
  arrow that beeps, one family of bug up. The frame the objects FILL is
  adopted now — an object is a passage one can SEE, so one selects it rather than tracing over it,
  the same reading ⌥⌫ makes — and that first press materialises the frame AND moves it in one
  step, the objects being let go of as it leaves them (objects still selected under a range lying
  elsewhere would give ⌫ two answers). At an end it still touches NOTHING, the object selection
  included. An infinite bus is left out of the frame: its stored window is not a passage anybody
  traced.
  And the export's **"Reveal" became "Show in Finder"** in the three languages.
  Verified with no screen: **nothing was built or run** — this machine has no compiler and no
  macOS. `tools/i18n/xcstrings.py check` answers `393 keys, 3 languages, nothing missing` and
  `orphans` is empty; that is the whole of it.
  **Not seen, not heard, not felt, not compiled**: every line above. The send columns under a real
  crossfade; the bus's vertical drag, its preview band and its refusal; the swap; whether 40 % of
  empty room below and 60 % to the right is the right amount under the hand; the arrows on an
  object selection; and "Montrer dans le Finder" in a `.controlSize(.small)` button of the export
  bar, which is a long label for a narrow row.

- **Four things read off the hand** (16 September 2026) — three gestures that answered late or not
  at all, and one click that was being spent on nothing.
  **An infinite bus is carried like everything else.** Its band stayed at its row while an empty
  rectangle was drawn at the target one: the only gesture of the canvas one had to READ rather than
  recognise. The band travels under the hand now (`infiniteBusPreviewDY`, the counterpart of
  `previewOffset`), and `clipRect` follows it — everything hung off that rect, the send links first
  of all, was staying at the row the bus had just left. What a block has NO equivalent of is the
  refusal (an overlap is resolved at the drop, whereas a full-width band set down on somebody's
  matter would cover it whole), so the refusal is said ON the band, in red, where the eye already is.
  And the cursor over a bus is the OPEN HAND, a block's own, in place of the ↕ put there the day
  before: the ↕ named the one axis the gesture has, which is true and is not what a hand arriving
  asks — it asks whether this can be taken hold of at all, and a resize cursor on a full-width band
  reads as an edge one could pull. Never `dragCopy` under ⌥ though: there is no copy of a bus at the
  end of that gesture.
  **The click that comes home from a plugin's window.** Touching a plugin's UI takes the key away
  from the main window — an AU/VST editor is JUCE's own window, a built-in one is an NSWindow of
  ours — and AppKit then treats the next click down here as a FIRST MOUSE: it makes the window key
  and THROWS THE EVENT AWAY unless the view under the point accepts it, which no SwiftUI view does.
  Every gesture had to be made twice, all day, for anyone working with a plugin open. The fix is one
  local monitor (`Shared/FirstClickThrough.swift`): monitors run inside `NSApp.sendEvent`, ahead of
  the window's own `sendEvent:`, so making the clicked window key THERE means the first-mouse
  question no longer has anything to ask by the time it is put — and the event is returned, not
  consumed, so it goes on to whoever was going to get it. Bounded on purpose: only while this app is
  ACTIVE (the click that activates an app from another one is a system convention, not our
  business), never a panel (popovers, menus and tool windows choose their own key policy) and never
  under a modal. Worth knowing generally — ANY window of ours opened beside the main one puts this
  trap back, and it is not the window's fault but the hit view's.
  **A fade is HEARD while it is being made.** The drag drew the curve on every frame and pushed it
  to the engine only at the drop, so one was adjusting a fade from the memory of what the last
  attempt sounded like. It previews live now, and it costs almost nothing for the reason that makes
  everything about fades cheap here: they all live in ONE plugin at the tail of the chain, so a
  preview is two doubles written into it (`setFades`, `previewFadesIn:out:forID:`) — no clip moved,
  no window reposed, no graph recompiled, where the committing path re-reads the clip's position
  and, for a group, lays the whole window down again. The MODEL is not touched (@see
  `EditViewModel.previewFade`): no undo point, no dirty flag, the gesture still commits once at the
  end. And the preview is bounded by the object's CURRENT window — a fade pulled out past its edge
  will grow the object at the drop, but until then that matter does not exist and a fade longer than
  the window would open part-way down its own curve.
  **Deleting the end no longer deletes the fade.** ONE rule — `fadeOutAnchoredAtStart` — at the
  three doors where an end goes: the crop (`updateDuration`), a time selection deleted off the tail
  (`carveTimeRange`) and the Cut tool's keep-the-left. A fade-out starts at a point IN the sound,
  not at a distance from the edge: its start stays put and the fade ends earlier with the edge,
  still reaching silence. A crop PAST that start leaves no fade at all (the whole curve was in the
  piece that went), and pulling the end back OUT leaves the fade alone — what is revealed is matter
  the fade never covered, and a fade that grew with it would be a shape nobody drew. A plain SPLIT
  keeps the old rule and must: the fade goes with the RIGHT-hand half, the one that still ends where
  it ended.
  **CORRECTED on 21 September 2026 — the crop is NOT one of those doors.** Read on screen: moving an
  EDGE and taking MATTER away are two gestures, and only the second shortens a fade. Under the hand
  on a trim handle (`updateDuration` / `updateTrim`, hence `object.resize` / `object.trim` and the
  crossfade's edge travel) a fade keeps its SIZE and travels with the edge it is anchored to — the
  clamps against the object's own length stay the last word, and that is a physical limit, not a
  rule. `fadeOutAnchoredAtStart` and `fadeInAnchoredAtEnd` are now reserved for matter REMOVED:
  `carveTimeRange`, the Cut tool's keep-the-left, a relink onto a shorter file. The fade-in half of
  the 21 September morning's `adfa52d8` was undone in `updateTrim` for the same reason, and kept in
  `carveTimeRange`, which is where it was asked for.
  Verified with no screen: a build; `scenario_families.py` 127 OK, with nine new assertions on the
  four doors (crop, lengthen, crop past the start, tail deleted, cut keeping the left, plain split);
  `scenario_markers.py` ALL PASS; `scenario_plugin_selection.py` 58; `smoke.jsonl` clean; i18n 393
  keys; no window on the headless pid. And an export re-read at RMS, which is what proves the ENGINE
  followed and not just the model: an object cropped so that its fade-out is halved renders a tail
  8.6 × quieter than the same render with that fade cleared by hand.
  Three debts of 15 September were paid along the way, that day's machine having had no compiler:
  everything written then COMPILES, `test_send_columns.swift` (22 assertions) was RUN for the first
  time and passes, and so was the infinite-bus block of `scenario_families.py` — the empty row, the
  swap, and the refusal that moves nothing.
  **Not seen, not heard, not felt**: the band travelling under the hand and its red refusal; the
  click that comes home (AppKit's rule is certain, the feel of it is not); and above all the fade
  heard while it is being drawn, which is the whole point of that change — including whether the
  preview stopping at the object's edge, while the block itself grows past it, reads as a limit or
  as a fault.

- **Seven things read off one session's use, and one question answered** (16 September 2026) —
  clicks that did the wrong thing, names that ran over their neighbours, and a rule that was written
  down but only half applied.
  **The marks became snap targets, and the guide always shows.** That one is two changes, and the
  second is why the first was invisible: `snappedTimePure` knew the grid and the objects' edges and
  nothing else, so an edge had to be eyeballed onto a marker — a mark naming an instant, with
  nothing able to land on it, is a mark doing half its job. A marker's instant, a region's BOTH
  bounds, and the marks an object carries (converted into edit time) are all targets now, through
  one list, `snapTargets`. Two exclusions, and they say the same thing: a HIDDEN row pulls nothing
  (it keeps its content but has stopped saying anything) and neither does a mark pushed behind an
  edge by a trim (it is not drawn — the very bound `ObjectMarkersOverlay` draws by). And the guide
  line, which existed already and only lit up when a snap landed on an object's edge, is now drawn
  for the WHOLE of a move / crop / trim: what one wants to know while pulling an edge is precisely
  whether one is aligned YET, and a line that appears only once the answer is yes cannot be asked
  the question. The colour carries the answer — **dashed grey** while the edge merely follows the
  hand or the grid, **solid yellow** the moment it lands on a mark. Dashed and not merely grey
  because the selection cursor is grey too and one pixel wider: two grey hairlines on one canvas,
  one of them moving under the hand, is a reading nobody should have to make. `snappedTime` returns
  the pair (`time`, `onTarget`), a grid line that FALLS on a mark counting as landing on it —
  the eye sees an alignment there and a guide staying grey over it would be lying.
  **An automated send no longer answers the hand** — which was the question asked, "who wins?".
  The answer was already written: as soon as a parameter carries a point the curve is the authority
  and the static value is no longer heard, no offset and no composition. The signal view had been
  applying it (`automationLocked` greys the knob), the TIMELINE had not: the Send tool's knob, the
  wheel and the inspector's box all went on lowering a send that could not be heard to move. The
  rule now lives at the hand's doors and only there — `selectedSendersWithFreeLevel`, which
  `adjustSendLevelSelected` / `setSendLevelSelected` and the knob's drag read — while
  `setSendLevel(from:to:)` stays exact, being the machine's door and the one an automation writes
  its own static value through. The same split as `updatePan` / `setPanFromHand`. The on/off SWITCH
  is deliberately left out: cutting a send is an explicit intention of silence and keeps the last
  word over any curve (@see `syncSendEngine`). New in the API: `send.list` carries `automated`, and
  `send.adjust_level` is the hand's own door, naming what it `moved` and what it left `locked`.
  **The piano roll opens on its own notes.** It opened on C3 whatever the clip held, so a roll
  written two octaves up looked EMPTY and the first thing one did was hunt for one's own material
  with oct +/-. The notes are centred when they fit in the height available, and otherwise read
  from a semitone under the lowest — a span taller than the window has to be read from somewhere,
  and one reads a keyboard upwards from the bass. An empty clip keeps C3, there being nothing to
  frame. The framing is WRITTEN DOWN on appearing, and that is not an optimisation: oct +/- adds an
  octave to the STORED value, so a window only ever computed would have sent the first press back
  to C3 — a jump away from what one is looking at, made by the one button whose whole promise is a
  single octave.
  **A click in an automation band moves the cursor**, as a click on a lane does. The band was inert
  — a hole in the canvas, the same gesture one row lower doing nothing — and a curve is read against
  the moment it plays at, so going to listen at that instant is the one thing a bare click there is
  for. It follows the RULER's contract and not a lane's: the grey line over its whole height, no
  caret (`caretLane = nil`), the click having been aimed at a curve and not at a row. Anywhere in
  the band, the dead space between the rows included.
  **And a click on a FADE moves nothing at all.** A fade handle falls in the block's upper half,
  where a bare click deselects and sends the cursor away — so a gesture begun a pixel short of
  moving took the cursor off what one was listening to. The same reading the crossfade's three
  gesture parts already had: a click that merely lands on a gesture is not an order.
  **A mark's name takes the room available and not one pixel more.** Zoomed out far enough two
  marks come within a few pixels of each other, and the first name lay straight across the second
  mark, its flag and its own name. Each name now stops at the next mark on its row (or the row's
  end; on an object, at the block's own right edge) and is cut to fit with an ellipsis — measured
  with `GraphicsContext.resolve(_:).measure(in:)` rather than guessed, `MarkerBandGeometry.labelWidth`
  being an approximation that is fine for a grab zone and shows in a drawing. One function,
  `fittedMarkerLabel`, shared by the band and by the marks carried on an object: the same drawing,
  hence the same bug, hence one fix.
  **And a click in the timeline leaves an inline rename.** The one rename nothing closed was a
  marker ROW's name: the annotation selection carries the others out with it through
  `selectedAnnotation`'s `didSet`, but a row is not an annotation and its field stayed open under
  every later click. `renamingID = nil` at the DOOR of `handleCanvasTap`, beside
  `clearPluginSelection` and for the same reason — a guard in the dozen branches below is a guard
  the next branch forgets — and before them, the marker band's own double click setting it again a
  few lines down. Leaving is not cancelling: what was typed is committed on the way out.
  **The question about the Documents prompt, answered: it is per BUILD, not per launch, and it is
  the ad-hoc signature.** `codesign -d -r-` on the built app prints `designated => cdhash H"…"` —
  with no team, the designated requirement IS the hash of that exact binary, and TCC keys its grant
  to the requirement. Every rebuild is therefore a different app as far as macOS is concerned, and
  the same binary relaunched never asks twice. It is the price of `CODE_SIGN_IDENTITY = "-"` and an
  empty `DEVELOPMENT_TEAM`, which are deliberate (see the permanent points) — so it is not a bug to
  fix in the repository. Whoever is tired of the prompt signs locally with their own team ID and
  **does not commit it**.
  Verified with no screen: a build; `scenario_markers.py` 70 assertions all pass, with seven new
  ones on the snap targets (the grid still winning with nothing there, a marker beating the grid
  line beside it, out of reach pulling nothing, a region's start AND its end, a hidden row catching
  nothing, an object's mark pulling at its EDIT time); `scenario_families.py` 131 OK with the send
  block grown; `scenario_plugin_selection.py` 58; `test_send_columns.swift` 22 and
  `test_synoptic_marquee.swift` 21; `smoke.jsonl` clean; i18n 393 keys, no orphans; and
  `CGWindowListCopyWindowInfo` on the headless pid: no window.
  **What no suite could reach, and it is worth knowing why**: the send LOCK itself. The command API
  has no door onto the automations at all — there is no `automation.*` family — so nothing headless
  can lay the point that would close the lock. `send.list`'s `automated` and `send.adjust_level`'s
  `locked` are asserted in their FREE state only. An automation door is the debt that pays this one.
  **Not seen, not heard, not felt**: every pixel of it — the dashed grey guide and the moment it
  turns yellow on a marker; the greyed knob and its automation glyph under the Send tool; the roll
  opening on its own octave; the cursor answering in an automation band; a fade handle that now
  swallows a click; the names cut with an ellipsis; and whether a click in the canvas really does
  read as leaving a rename rather than as losing what one typed.

- **A render one can watch, and hear while it is being made** (16 September 2026) — four things
  asked of the export, and one fact that made three of them cheap. **A DIRECT render stays in the
  window that launched it**: it used to close on the Export button and hand everything to a
  one-line strip — a percentage, and nothing of what was coming out. The settings grey out, the
  waveform grows at the bottom, the progress runs along the bottom edge. The strip becomes the
  FALLBACK and not a second display: it shows whenever a job exists with no window to show it in —
  a background render (which closes the window, as the setting says) or a direct one whose window
  was closed by hand. And `export.run` KEEPS a window, it never OPENS one: same doctrine as
  `hasInterface` guarding the plugin editors, an export driven by a script must not put a window on
  the screen of whoever is working.
  **The waveform grows as it is made**, at no cost to the engine: `EditRenderer::render` already
  takes an `IncomingDataReceiver` and `NodeRenderContext` hands it EVERY rendered block, after
  dithering and just before the write. `OBJExportTap` takes min/max from it into a FIXED number of
  buckets (1024, whatever the length — the memory does not depend on the duration), through relaxed
  atomics and no lock: a lock would make the render wait for a drawing. It is the data's LENGTH
  that says how far the drawing has got, so nothing has to be kept in step with a second number.
  **And the file is LISTENED to while it is written** — the fact that makes this cheap, and worth
  knowing before touching a render anywhere: the engine's temporary wave is a VALID wave from end
  to end. Tracktion's `AudioFileWriter` rewrites its header with the current length every six
  seconds of audio (`numSamplesPerFlush = 48000 * 6`) and seeks back to go on writing, so an
  `AVAudioFile` opened on the file in progress reads exactly what has been flushed, and opening it
  again later sees more. No engine patch, no partial-header parsing, no second copy of the audio in
  memory: **the file IS the buffer**. The price is granularity (nothing before the first flush) and
  starving (a render slower than real time lets the play head catch the writer up — said on screen
  rather than hidden). A separate `AVAudioEngine`, never the project's own. `audible_seconds` is
  deliberately NOT the progress: the render runs ahead of the flush.
  **The trap it turned up, and it is general**: the engine's tap is only remade when the render is
  really launched, and only zeroed by its `reset`, at the end of the graph's construction. Read in
  between, it answers the PREVIOUS render's shape, whole — a second export flashed the first one's
  waveform for some 600 ms. The PHASE is what knows there is nothing of this render yet, so it is
  what says so: `readExportPeaks` answers empty throughout `.preparing`.
  The strip's icon is `waveform` rather than `square.and.arrow.up`, which is macOS's word for 'hand
  this to another app' and not for 'make a sound', and it now names what is being made — "Rendering
  “session”" — since with the window closed nothing else on screen says so.
  Verified with no screen: a build, and `tools/scenario_export_preview.py`, 35 assertions all
  passing — the window kept by a direct render and given up by a background one, a script opening
  none, the waveform caught IN FLIGHT (strictly between nothing and all of it) and never going
  back, nothing shown while preparing, something audible before the end and never past the render,
  the flush lagging the render, a silent render drawing flat, and **the peaks checked against the
  FILE re-read** (the tap's peak against the 24-bit WAV's, under 0.01 apart). Plus
  `scenario_families.py` 131 OK, `scenario_markers.py` ALL PASS, `scenario_plugin_selection.py` 58,
  the two standalone Swift suites 22 and 21, `smoke.jsonl` clean, i18n 397 keys with no orphans,
  and no window on the headless pid. New commands: `export.panel`, `export.preview`;
  `export.status` answers `panel_open`.
  **Not seen, not heard, not felt**: every pixel and every second of it — the waveform growing and
  whether 1024 buckets read well across 420 px, the veil over what is not yet audible, the play
  head, the click and drag that go and listen elsewhere; and above all THE LISTENING itself —
  whether the sound comes out, whether the first flush is long enough to annoy, whether the
  hand-over from the temporary wave to the final file can be heard (in MP3 above all, where it is
  not the same file), and whether "waiting for the render" reads as an explanation or as a fault.

- **Four corrections read off the hand** (16 September 2026, the same day, after the seven above had
  been used) — each one a place where the answer given that morning was right about the problem and
  wrong about the remedy.
  **A click on a FADE goes back to moving the cursor.** Swallowing it was the morning's reading, and
  it took one session to see the cost: a fade handle sits in the block's upper half, which is TIME
  like every other pixel of the canvas, and a click there had always meant "listen from here". Over
  a strip nothing announces as special, the one gesture the whole timeline shares stopped answering.
  What made the swallowing unnecessary is already in the wiring: the tap is an `onTapGesture` beside
  a `DragGesture(minimumDistance: 3)`, so a hand that TRAVELS never fires the tap at all — pulling a
  fade has never moved the cursor, and only a hand that changed nothing was being punished. The
  crossfade's three parts keep their return, and for a reason of their own: they carry a SELECTION.
  **A piano roll opens on a C.** The framing added that morning showed the notes and put the bottom
  row wherever the arithmetic landed — G♯2, D4 — so the octave labels named no octave, the black
  keys fell in a pattern nobody recognises, and oct +/- carried the offset for the rest of the
  session. The reference beats the perfect centring: the ideal window is snapped onto one of the two
  C's framing it, and **the one showing more of the notes wins** (a tie to the lower, one reads a
  keyboard upwards from the bass). The ceiling is the subtle half and it rounds UPWARDS — the lowest
  C from which the window still reaches 127, not the highest whose window fits underneath, which
  looks tidier and puts the last eight semitones out of reach for ever; the keyboard simply ENDS, and
  `normalRowPitches` draws no row past 127. It went into a unit of its own, `PianoRollFraming`, for
  the reason `SendColumns` and `SynopticMarquee` are units: it is the half of the feature with
  nothing behind it, so it can be compiled alone and asserted — `tools/test_piano_roll_framing.swift`,
  31 assertions. `EditViewModel.basePitchOnC` is the door the octave buttons and the display's own
  clamp go through, which is what keeps the reference once it has been found.
  **The dashed guide follows a MARK too, and a region crops.** The guide was lit for a move, a crop
  and a trim, and not for the band's own drag — yet a marker and a region are placed against the
  same material an object's edge is placed against. `dragActive` takes `markerBandDrag` and
  `commentDrag` now. The half of it that only shows once a mark is DRAGGED: the band's drag writes
  into the model on every frame, so the mark stands where the hand last put it, and left in its own
  target list it was its own magnet — inside the eight pixels of tolerance, winning every time, the
  mark refusing to move until the hand tore it away. `snapTargets(excluding:)` takes a mark's id as
  readily as an object's since. And a REGION can be cropped at last, by either end, the far one
  anchoring: it is a passage, and a passage whose bounds can only be set at the moment it is created
  is a passage one re-creates rather than adjusts. No vertical for it — cropping is an edge
  travelling in time, and a hand that changed row mid-crop would be answering two questions at once.
  The floor of 0.05 s is not cosmetic: `duration == 0` is what MAKES a point marker, so a region
  cropped to nothing would silently become another kind of mark. `marker.move` gained `snap`, which
  is what makes any of this assertable with no screen.
  **And a row's NAME gives way to the marks.** Capping each mark's own label at the next mark
  (that morning's fix) left the collision that actually shows: the row names are PINNED to the
  viewport while the band scrolls under them, so zooming out piles every mark against the left edge
  under the name that says whose row it is. The name gives way — it is the one thing there that can
  be read from a fragment — and progressively: the room there is, then an ellipsis, then nothing at
  all. The dot stays whatever happens, being the row's colour and the target of the right click that
  changes it. The trap worth knowing: the header needs the LIVE scroll, which no view body may read
  (`cullScrollX` moves in notches of 512 px, far too coarse here). It takes the `TimelineScrollAnchor`
  as an OBJECT and touches `.x` inside its own body — exactly what `StickyToViewportTop` does with
  the vertical — so a scrolling frame invalidates those few rows and not the timeline.
  Verified with no screen: a build; `scenario_markers.py` 78 assertions all pass, seven of them new
  (a marker that does not catch on itself, that still catches on somebody else's mark, a region's
  two ends pulled, both bounds snapped, and the crop as ONE undo); `test_piano_roll_framing.swift`
  31; `scenario_families.py` 131 OK; `scenario_export_preview.py` 35; `scenario_plugin_selection.py`
  58; `test_send_columns.swift` 22 and `test_synoptic_marquee.swift` 21; `smoke.jsonl` clean; i18n
  397 keys, no orphans; and no window on the headless pid.
  **Not seen on screen, nor felt**: every pixel of it — the fade click that gives the cursor back and
  the drag that still leaves it alone; the roll opening on a C, and whether losing the exact centring
  is ever noticed; the dashed line under a mark being dragged and the moment it turns yellow; the
  region's two crop handles, their cursor and the floor they stop at; and the row name shrinking,
  ellipsising and disappearing as one zooms out — including whether a name that vanishes reads as
  making room or as a row that has lost its label.

- **Two faults behind one crash, on undoing an automation** (17 September 2026) — ⌘Z over a curve
  drawn on a PLUGIN parameter was killing the app. Two independent defects came out of the log,
  and only one of them is proven to be lethal.
  **The graph probe was corrupting the heap** (engine patch `0032`). `prepareToPlay` runs on
  SEVERAL threads at once — one Edit rebuilding its graph while another player rebuilds its own —
  and the probe's own journal has always said so: the indices come out in disorder, a heavy `#145`
  finishing after the `#146`…`#162` that overtook it. Its state, though, lives in FUNCTION
  statics, hence shared: `objPreviousCensus` is a `std::map` one thread assigns while another
  reads it. A measuring probe that kills the process it measures — and the plantage is not even
  the worst of it, since it lands anywhere, long afterwards, and poisons the diagnosis of every
  other Debug crash (the `SIGABRT` of 15 September, in `tiny_free_list_remove_ptr` on the way out,
  has that signature). A mutex covers the statics AND the two writes. Debug only, so a Release was
  never concerned — which is also how to test it: if a crash survives in Release, it is not this.
  **And a curve was travelling inside its plugin's state.** A plugin-parameter curve lives IN the
  plugin's tree (`AutomationCurve::checkParenthoodStatus` hangs it there at the first point), so it
  went out in the `stateXML` the model keeps of every plugin — while the model is the SOLE
  authority on curves. The cost was not tidiness: the undo snapshot compares field by field to
  rebuild only what differs (@see `isPatchable`), so the least point laid, moved or deleted made
  the object UNRECOVERABLE — the ⌘Z destroyed it and reloaded its plugin, 757 ms measured for a
  UADx Anthem Synth, for a curve `pushAutomation` lays down again anyway. `getPluginStateXML` now
  strips the `AUTOMATIONCURVE` children from a COPY. Two side effects, both wanted: a curve is no
  longer written twice into the session file, and a copied plugin no longer smuggles a curve the
  model cannot see.
  Measured on the way, and it is what pins the cause: two hammers of 25 undos on the same AU, the
  only difference being the ORDER. State changed INSIDE the snapshot's window → 25 patched, no
  reload. State differing ACROSS it — a curve's own order — → 25 rebuilds, 26 instantiations. And
  those 25 teardowns did NOT crash: headless, with no audio device and no interface, on a 22-node
  graph where the crashing session had 111. So the AU's teardown is not suicidal by itself, and
  what the crash owes to the probe's race cannot be settled from here.
  Verified with no screen: a build; `scenario_families.py` 131 OK, `scenario_plugin_selection.py`
  58, `scenario_markers.py` ALL PASS, `scenario_export_preview.py` 35 OK, `smoke.jsonl` clean; and
  a plugin-state round trip written for the occasion (a param set, saved, reopened: identical).
  **Not proven**: that the crash is gone. Neither fix can be asserted on the gesture itself — the
  API still has no `automation.*` door, which is the debt that would pay this one. In the app it
  reads in one line: after ⌘Z on a plugin curve, `[UNDO]` must say `1 patched` and no
  `[PERF] instrument … instantiated` may follow.
  **Left standing for an hour, then taken down too**: undoing a plugin's parameter VALUE still
  rebuilt the object and reloaded the AU, the state there really having to be restored. That is
  the entry below.

- **A plugin's state is put back, the plugin is not put back together** (17 September 2026, the
  same day) — the question that ended the entry above, asked as it should be: why rebuild an
  object whose plugin nobody deleted, when all that has to travel is a value? Undoing any setting
  of any plugin destroyed the object and reloaded its instance — 757 ms of AU for a knob — to end
  up, at the end of that load, applying exactly the state one could have handed it on its own.
  Three pieces. An engine door, `applyPluginStateXML:forPlugin:`, the counterpart of
  `getPluginStateXML:`; `isPatchable` accepting a difference CONFINED to the states
  (@see `adoptingPluginStates`, which refuses as soon as the chain's shape moves — a plugin
  added, removed, reordered, a rack facing a plain plugin — so the strict equality by subtraction
  closes on everything else as before); and `pushPatch` pushing the state of the leaves whose
  chunk has actually moved, and of those only.
  The two traps were where they were expected, and a third was not.
  **An EXTERNAL plugin already knows how**: `restorePluginStateFromValueTree` on the live
  instance, plus the reassert the reloading path already schedules, an AU not yet initialised
  refusing `setStateInformation` in silence.
  **A BUILT-IN wants its properties copied**, and copying them is not enough: it must be a
  REPLACEMENT. A `CachedValue` with a default writes NOTHING until somebody sets it, so a
  parameter still at its factory value is ABSENT from the saved tree — recopying what the tree
  HAS would leave standing precisely the settings being undone. A property the saved state lacks
  is therefore REMOVED, which drops the `CachedValue` back onto its default, which IS the value to
  restore. Never the whole tree: that would carry the identity (`id`, the live instance's
  EditItemID) and the children (the automation curves, which belong to the model).
  **And writing the property does not move the parameter.** `AutomatableParameter::valueTreePropertyChanged`
  refreshes the `CachedValue` and stops there on purpose, to avoid a loop with the reverse race —
  so `currentValue`, the one the audio reads and `getPluginParams` reports, stayed where it was.
  `updateFromAttachedValue()` on every automatable parameter is the door, and it is what every
  internal `restorePluginStateFromValueTree` does after its own copy (@see `EqualiserPlugin`).
  The one that cost the most to find has nothing to do with plugins: `automationTouchOrder`. It is
  a UI memory the engine knows nothing about, persisted, and recorded WITHOUT an undo point on
  purpose — touching a fader is not an edit. So it moves between two undo points, and left out of
  the probe's whitelist it alone made every object unrecoverable: the object was rebuilt for the
  MEMORY of having touched a parameter. Anything else recorded outside the undo stack will do the
  same, and the symptom says nothing — it is a rebuild, not an error.
  Verified with no screen: a build; `tools/scenario_plugin_state_undo.py`, 10 assertions, written
  for this and passing for a built-in AND for a real AU (`--external=aumu,UI15,UADx`) — the value
  comes back, the plugin answers straight away (a rebuilt object's does not, it reloads
  asynchronously), the object is back where it was, and the undo takes **1 ms and 3 ms** where
  every measurement of the old path sat between 590 and 760 ms. The engine log says the rest:
  `0 rebuilt, 1 patched`, and not one `instantiated` after the first. Plus `scenario_families.py`
  131 OK, `scenario_markers.py` ALL PASS, `scenario_plugin_selection.py` 58,
  `scenario_export_preview.py` 35 OK, the three standalone Swift suites 22 / 21 / 31,
  `smoke.jsonl` clean, i18n 397 keys.
  **Still not proven, and it is the same debt**: the GESTURE this was written for. The command API
  has no `automation.*` door, so the scenario takes the same road by the other end — a parameter
  set outside the snapshot's window moves exactly what a curve moves, the plugin's tree. In the
  app it reads in one line, as above: `[UNDO] … 1 patched`, and no `[PERF] … instantiated` behind it.

- **The sound list becomes a table of contents, and a lost file can be found again**
  (19 September 2026, ON THE BRANCH `claude/sound-list-left-panel-tz0nww`, NOT on `main`;
  written blind, COMPILED AND RUN the same day — see the last paragraph) — the left panel had columns saying in figures what the timeline says in
  pixels one row further right, and the app had no word at all for the thing that actually breaks
  a session: a wav that is no longer where it was.
  **The list.** No more columns, no more sort headers — a sort one can change is a sort one has to
  re-establish. What is left is the order things HAPPEN in and the shape the project really has:
  the tree of its groups, sorted PER LEVEL OF SIBLINGS (earliest first, the higher row winning a
  tie, the original index settling the last one — `sort` is not stable in Swift and two objects at
  the same instant on the same lane would swap places from one recomputation to the next). The
  chevron IS the timeline's fold: one state, two views. An icon per kind, a sound object being a
  `.clip` that carries a `definitionID` and nothing else telling it from an ordinary sound.
  Colours are the BLOCK's rule turned through 90° — a 3 px strip down the left edge in
  `customColor ?? stemColor` where the block puts its name band, the row's ground in the stem at
  the block's own opacities to the digit. `soundListRows` sits beside `buildLaneEntries` and the
  head of the file names their divergence rather than hiding it: two walks of one tree drift
  unless they are read together.
  **A missing file is a GHOST, and that is the fact everything else follows from**: a file it
  cannot open makes `addSoundObject` give up BEFORE the clip exists (`OBJEngineCore.mm:1634`), so
  the object sits in the model with no clip, no chain, no fades, no sends and no plugins — and
  until now, with nothing said about it anywhere. Hence a repair CREATES the object rather than
  correcting a path: `rebuildClip` is `applyDefinitionWave`'s sequence word for word, plus
  `pushFadeCurveTree`; the plugins come back on their own, `engineAddClip` ending by compiling the
  chain of any object that has one.
  **The trap the detection is built around**: the predicate is read by the canvas once per block
  per frame, so a `FileManager` call in `isMissing` would put a stat() — on a network volume, a
  stat() that BLOCKS for seconds — inside the drawing pass. The disk is read in ONE function,
  `rescanMissingFiles()`, at the doors where the answer can have changed; everything that draws
  reads a dictionary keyed by PATH, deduplicated before the stat and written back only if it
  DIFFERS (the property is observed — an equal dictionary reassigned on every mount notification
  would invalidate the timeline for nothing).
  **An unmounted volume is not a lost file.** `/Volumes/<name>` missing as a directory answers
  `volumeOffline`, the menu names the drive instead of offering a search, and a watch on
  NSWorkspace's mount notifications makes the state mend itself.
  **Accidents come by packets**, which is the whole of `PathRelink`: repairing one path teaches a
  prefix, compared BY COMPONENTS with the longest common suffix taken away, and taken as far as it
  goes so the rule holds for the file's siblings and not for that one file. Applied on a COMPONENT
  BOUNDARY, never on the raw string — `hasPrefix` would match `/Users/n/Sons2` under
  `/Users/n/Sons` and rewrite a folder nobody named. Only what resolves onto a file that EXISTS is
  kept, so the count offered is a count of things that will work. **The question comes BEFORE the
  repair** (`resolvableByPropagation` changes nothing), then ONE `repairPath(…, propagate:)`:
  asking afterwards would put two undo points where the hand made one gesture.
  **Repairing is not replacing**, and they are two menu entries because they are two intentions —
  replacing is deliberate, acts on one object, propagates nothing, and is offered whether or not
  anything is missing.
  **The clamp**, when the new file is shorter: the window SLIDES BACK first (the length one chose
  is worth more than the exact place it was taken from), and only a window longer than the whole
  file has its LENGTH cut. Shorter beats reading emptiness, and one ⌘Z gives back what there was.
  The file range a clip consumes is `[offset, offset + duration × speed]` whether it plays
  forwards or in reverse — reversing decides where the material is heard, not how much there is.
  **The red is drawn in FOUR places**, which is what the search for it turned up: the two rich
  views, the batched `Canvas` past a hundred objects, and `InfiniteBusBandView`, which REPLACES a
  group's block once the bus is infinite and would have dropped the red the day one was. Hence
  `Shared/MissingFileLabel`, which the four read and the sound list makes a fifth reader of. And
  the red alone was NOT legible: a name band is white plus a tint, one of the ten stems IS red
  (≈1.3:1, which is not a poor contrast but none at all) and the object pastels include salmon —
  so a white halo, the band's base being white whatever the tint, and the only remedy that costs
  no layout.
  Session format 13 → 14 (`fileSize` on a clip, read BY PATH because the sites that copy a clip
  rebuild it field by field and would drop it). i18n 421 keys, three languages, no orphan.
  New commands: `project.missing_files`, `project.rescan_missing`, `object.replace_source`,
  `project.relink_path`, `project.relink_preview`, `project.relink_folder`; `object.get` /
  `object.list` gain `missing` and `missing_reason`.
  **Written with no compiler, no macOS and no screen** — the only thing executed at the time was
  `python3 -m py_compile` on `tools/scenario_relink.py`, a syntax check that proves nothing about
  what it asserts. **Settled since, on a machine that has all three** (19 September, the entry
  below): it COMPILES, in Debug and in Release, with no new warning; `tools/test_path_relink.swift`
  passes its 36 assertions and `tools/scenario_relink.py` its 46, both run for the first time.
  Two of those assertions could not pass as written, and both are worth knowing: the marker suite
  still pinned session format 13 against the 14 this branch bumps to, and the relink suite compared
  a path the app DISCOVERED (resolved by `FileManager`, `/private/var`) against its own `mkdtemp`
  root (`/var`) — the macOS symlink, failing on a thing that says nothing about the relink. The app
  was right in both cases; the suites were fixed.
  **Still not settled, and it is the whole design**: whether a relinked object actually SOUNDS.
  Nothing here proves the ENGINE followed rather than the model alone — the export re-read at RMS
  is what would, and it has not been written. Then every pixel: the strip and the indentation, the
  badge in three languages in a 240 pt panel, the red on a red stem band and on a salmon pastel
  with its halo, the two context menus, the three panels and the propagation alert.
  One reading left open on purpose: in the list, a double click on a sound object OPENS it for
  editing (the timeline's own gesture). It could instead mean "show me its N placements", which is
  what the request literally said. Cheap to change, and the eye decides.

- **The list and the timeline say the same thing, and a group says what it holds**
  (19 September 2026, ON THE SAME BRANCH, after the entry above had been used for the first time)
  — six things read off the hand, and one owed for a while.
  **A glyph per kind, on BOTH sides of the window.** The list had icons and the timeline had none,
  so nothing tied a row to the block it names. One definition for FIVE readers,
  `Shared/ObjectKindIcon` — the four places a block's name is drawn (`SoundBlockView`,
  `GroupBlockView`, `InfiniteBusBandView`, the batched `Canvas`) plus the list — for exactly the
  reason `MissingFileLabel` sits beside it. In the `Canvas` the glyph travels INSIDE the resolved
  text (`Text(Image(systemName:))` lays out as a character): one resolve, one cache entry, one
  draw, cropped with the name, where a second image would need its own width and its own clip per
  block per frame — in the regime that exists because there are too many blocks to afford that.
  The cache key carries the icon AND the name, two clips being able to share a name and not a kind.
  **A sound object is a waveform in a circle, and STAYS one while open.** That is the subtle half
  and the trap worth keeping: opening one materialises its content, so its `kind` genuinely becomes
  `.group` and `restoredSubtree` clears its `definitionID` ON PURPOSE. Nothing on the object can
  tell it from a plain group, so the glyph turned into a folder on the double click and back on
  closing. Only the view model knows (`isInObjectEditStack`), so it is passed in — a block is pure
  presentation and is told.
  **The colour strip is 16 px and not 3.** A hairline separates two rows, which is not the job: it
  must name a colour one RECOGNISES against the ten stems and the object pastels, and 3 px of
  salmon and 3 px of pink are the same stripe.
  **Selecting an object brings it into view in the list** — a table of contents that does not
  follow the hand stops being one. Anchored CENTRE (what one wants is what sits AROUND the thing
  selected), and three deliberate silences: only when the object to look at CHANGES, so ⇧ and ⌘
  leave the view where the eye is; never for a selection of several, there being no one row to show
  and no right to choose one; never while one is typing in the search field.
  **A group takes the name of what it holds** — `Kick + Snare + Hat`, read from the HIGHEST lane
  downwards, which is the order the eye takes a stack of lanes in. "Group" says what a thing IS and
  never which one; thirty groups were thirty rows carrying one word. A MIDI clip takes its
  INSTRUMENT's name. A name somebody typed always wins, and clearing the label gives the composed
  name back. The arithmetic is its own unit, `ComposedName` — the half with nothing behind it,
  hence assertable with no screen (`tools/test_composed_name.swift`, 27). Fifty characters, at most
  five names, then `+3` (how many are not shown, not merely that some are not). `50/N` is a FLOOR
  and not a rule: a name shorter than its share hands the remainder back and the surplus goes round
  again, so `Kick` pays for `Contrabass_ambiance` instead of spending ten characters on blanks —
  repeated until nothing more can be given back, one pass leaving the second-longest cropped while
  the shortest's budget sits unused. The ellipsis is counted INSIDE the limit, which is what makes
  the budget honest. The sort is TOTAL — lane, then instant, then stored order — the same trap
  `soundListRows` carries a comment about: `sort` is not stable in Swift, and a group that renamed
  itself between two recomputations would be worse than one called "Group".
  **And the list has a right click → Show in Finder**, reusing `export.reveal` — the same sentence
  about the same gesture, already in three languages. Withheld where it would lie: a group, an aux
  and a MIDI clip own no file, and a MISSING one would open the Finder on the folder that no longer
  holds it, contradicting the relink entries just above it in the same menu.
  Verified with no screen: Debug AND Release build, no new warning (the nine non-nullability ones
  in touched files were blamed to their origin commits and all pre-date the branch);
  `test_composed_name.swift` 27, including a sweep over 72 input shapes proving the 50-character
  budget is never overrun (worst case exactly 50); the naming driven end to end through the API —
  three sounds on lanes 2/0/1 grouped reading top-down with the long name absorbing what the short
  ones returned, a manual name winning, a 57-character instrument cropped to exactly 50. Plus every
  suite: relink 46, markers 78, families 131, plugin-selection 58, export-preview 35,
  plugin-state-undo 5, the four other standalone Swift suites 36/22/21/31, `smoke.jsonl` clean,
  i18n 421 keys, no window on the headless pid.
  **The MIDI half could not be driven the ordinary way**, and it is a debt of the same shape the
  repo already knows: `setInstrument` exists in the view model with NO API door onto it, so nothing
  headless can put an instrument on a clip. It was verified through the door that does exist — a
  session saved, an instrument injected into the file, the project reopened — which works and is
  not the gesture. A `midi.set_instrument` would pay it.
  **Not seen on screen**: every pixel — the 16 px strip against the pastels and the ten stems, the
  glyphs at 9 pt in BOTH drawing regimes (the rich views and the `Canvas`, which is where a glyph
  silently differing would show), the scroll that follows the selection, the composed names on real
  material, and the Finder entry in a narrow menu in three languages.
  **One cost measured nowhere**: `displayName` on a group now sorts its children and builds a
  string on every read, and it is read while drawing. Groups are far fewer than the hundred-object
  threshold so it is expected to be invisible, but no screen here could measure it. Left UNCACHED
  deliberately — a second cache is above all a second cache to invalidate (@see the head of
  `EditViewModel+ListRows`).

- **The snap is the grid's, the detent is the value's** (19 September 2026) — read off the hand: an
  automation value landed on whole dB only when the SNAP was on, which was a misreading of what was
  asked for. The two are not one switch. The snap is the GRID, hence TIME: it says where a thing is
  PLACED — an object, a mark, an automation point — and turning it off is how one places something
  between the lines. A DETENT says what a thing is WORTH, and it exists to lower the precision, so
  that one does not have to decide between -3.0 and -3.4 dB. That is wanted whether or not one is
  working on the grid, so it answers to nothing: not the snap button, not ⌘. Exactly the rule the
  pan was given on 15 September, and it was already written down there — the automation band simply
  had not read it. `snappedV` / `snappedStep` became `detentedValue` / `detentedDelta` and lost
  their `snapOn` guard; `snappedT` keeps it, being the axis the grid is actually about. A plugin
  parameter still has no detent at all, and that is not an oversight: its 0…1 is normalised, so
  there is no unit to round to (@see ParamRef.valueStep).
  **The sweep the correction asked for**: every reader of `snapEnabled` / `effectiveSnapEnabled` /
  `effectiveSnapGrid` in the app was read, and the automation band's vertical axis was the ONLY
  non-temporal one. The rest are the ruler, the timeline's drag and guide, the piano roll (its
  PITCH never having been snapped), the paste position, and the persistence. The inspector's and
  the synoptic's boxes have their own always-on rounding (`DragValueBox.snap`), which never was the
  grid's.
  One adjacent gap came out of it and is fixed here: the **Send tool's knob** was the only hand
  laying down a dB with no step at all — `setSendLevel` being the machine's door — while the
  inspector's box for the same send rounds and `ParamRef.valueStep` declares a whole dB for its
  curve. One send, three controls, two answers. `setSendLevelFromHand` is the door now, and the
  drag works from anchors, which is what makes rounding the result safe (@see EditViewModel+Pan for
  the day compounding cost a whole gesture). `adjustSendLevelSelected` deliberately stays exact: it
  READS the stored value and adds, so rounding there would throw away every delta smaller than half
  a step and freeze the ⌘-fine of the inspector's box.
  Verified with no screen: a build; `scenario_families.py` 131 OK, `scenario_markers.py` ALL PASS,
  `scenario_plugin_selection.py` 58, `scenario_export_preview.py` 35 OK, `scenario_relink.py` ALL
  PASS, `scenario_plugin_state_undo.py` 5, the three geometry suites 22 / 21 / 31, `smoke.jsonl`
  clean, i18n 421 keys with no orphans, and no window on the headless pid.
  **What no suite can reach, and it is the same debt as ever**: the command API has no
  `automation.*` family, so nothing headless can lay a point and read back what it is worth. Nor
  can it drive the Send tool's knob — `send.adjust_level` goes through the door that stays exact.
  Both changes are the HAND's doors, and only the hand sees them.
  **Not felt**: a curve dragged with the snap OFF and landing on whole dB all the same; the Send
  tool's knob clicking from dB to dB; and whether the dB still left between the steps by ⌘ in the
  inspector's and the synoptic's boxes is wanted or is one more value nobody meant to type.

- **A cut does not re-aim the selection: the selection follows the matter** (22 September 2026) —
  `EditViewModel+Cut.swift:116` used to write `selectedIDs = result` outright, `result` being BOTH
  halves of a plain division (or the survivor, for an oriented one). So cutting with nothing
  selected left two objects selected out of nowhere, and cutting object B while A was selected
  quietly took A off the selection. The rule now: an object never selected keeps none of its
  pieces selected; an object that WAS selected hands its selection to whichever piece survives it,
  and to the SHORTER one when both do (a plain division) — cutting is most often done to throw a
  small scrap away (a breath, a click, a count-in), and pre-selecting that scrap saves the click
  that follows. A tie goes LEFT, and costs nothing: the left half always keeps the object's own id
  (every branch of `_splitInternal` hands the fresh UUID to the right piece, never the left), so
  "equal duration → left" does not even touch `selectedIDs`. An object selected but not itself cut
  is left exactly as it was — read off `selectedIDs` BRUT, before the split, which is what the eye
  actually sees in surbrillance.
  The arithmetic went into its own unit, `Shared/CutSelection.swift` (`cutSelectionSide`), for the
  reason `SendColumns` / `SynopticMarquee` / `PianoRollFraming` / `ComposedName` are units: it has
  no model behind it, so it can be compiled and asserted alone — `tools/test_cut_selection.swift`.
  `cut(ids:atTime:keeping:)` now RETURNS the pieces it produced (`@discardableResult`), which is
  NOT the same thing as the selection any more — `object.split_at`'s answer keeps `ids` naming the
  pieces (so `tools/scenario_families.py`'s pre-existing split fixture, which reads
  `halves["ids"]`, did not have to change) and gains a `selection` field for the new rule. The same
  function also closes two things left dangling by a cut: a `selectedAnnotation` naming a marker
  the cut swallowed (the same pruning `applySnapshot` already does after an undo), and a
  `selectedCrossfade` naming one of the objects cut — left standing, ⌫ would have aimed at a zone
  that may no longer exist. `object.ripple_cut` had the same fault in its own shape
  (`EditViewModel+Ripple.swift`, an outright `selectedIDs = []`) and lost it the same way: what
  `carveTimeRange` swallows is pruned by `remove(id:)`, what survives keeps its id (`keep: "left"`
  truncates it in place, `"right"` only advances its start), so the selection simply has nothing
  to rewrite.
  The one trap worth knowing for whoever next touches a ripple from a script: its scope with NO
  container is the WHOLE TIMELINE (documented already, easy to forget) — a ripple test fixture
  left at the top level reaches every other lane's matter at that instant, which is exactly what
  broke three unrelated, pre-existing assertions the first time this was tested (an old split
  fixture on another lane vanished into a ripple's hole 300 ms away). Fixed by giving each such
  fixture its OWN one-member group first, and by sweeping every object this session's new test
  block introduces before it hands back to the rest of the file (an object.list diff, taken before
  and after) — a stray fixture at a high lane number shifts where the pre-existing "last row"
  assertions expect the floor to be, which is its own lesson: **a test fixture that outlives its
  own test is a fixture the NEXT test has to know about.**
  Verified with no screen: a Debug build, no new warning; `tools/test_cut_selection.swift`, 15
  assertions (the arithmetic alone: 80%/20%/exact-middle splits, the 1e-9 tolerance either side of
  a tie, a negative-start object, `keeping` overriding duration outright, a six-case sweep);
  `tools/scenario_families.py` grown to 185 OK (18 new assertions driving the rule end to end
  through the API — nothing selected, the untouched neighbour, the shorter piece inheriting a
  plain division, the tie, a whole multi-object selection, an object selected but not cut, `ids`
  vs `selection` in the same answer, `keep: "left"/"right"`, `object.ripple_cut` both ways, a
  GROUP, a CHILD of an open group, and an undo bringing the object back whole); `scenario_markers.py`
  ALL PASS; `scenario_plugin_selection.py` 58; `scenario_export_preview.py` 35 OK;
  `scenario_relink.py` ALL PASS; `scenario_plugin_state_undo.py` 5; the five other standalone Swift
  suites 22 / 21 / 31 / 27 / 36; `smoke.jsonl` clean; i18n 429 keys, no orphans; and no window on
  the headless pid.
  **Not seen, not felt**: every pixel of it — the Cut tool's drag (nothing/⌥/⌘ orientation), a
  marker or a crossfade zone actually catching the loss on screen rather than through
  `annotationExists`/`selectedCrossfade` read back over the socket, and whether losing the
  selection on a bare, unselected cut (the case the whole rule was written for) reads as help or as
  one fewer thing confirmed by the eye.

- **The waveform cache stops costing what the sounds cost** (22-23 September 2026) — three
  complaints, one cache: it weighed almost as much as the sources it described, it was slow on a
  first open, and a project's `waveforms/` folder received `.wfc` of sounds that project had never
  heard of. Eleven commits, each buildable and revertable alone, because the two levers on SIZE had
  to stay SEPARABLE — the representation (int16) and the resolution (one mipmap level fewer) touch
  no function in common, so either can be reverted on its own and the two compared by eye.
  **int8 was the plan and int8 is wrong**, and the arithmetic is worth keeping because it will come
  back the next time somebody wants the cache smaller: `maxBlockHeight` is the VIEWPORT's height, so
  a block reaches ~900 px and `mid ≈ 450`; `maxWaveformDB` is 24 and the gain multiplies `mid`. Half
  a quantisation step × gain × mid puts int8 at **28 px of stair-stepping** and int16 at 0.11 px —
  and those 28 px land in the QUIET material, which is precisely what the gain exists to inspect. No
  arrangement of 8 bits escapes it (the question was asked): what the drawing needs is RELATIVE
  precision, because `clampY` hides the error on loud values, and 1/900 relative is ~10 bits of
  mantissa. A minifloat gives 14 px; *block floating point* gives 1.8 px until a transient sits
  beside its own tail, which is the material this program is for. **~14-15 bits is what the problem
  demands, which is what int16 is**, and the prize for going to 8 bits would have been 12 MB.
  **Dropping the 10 000 peaks/s level** (90% of a mipmap's weight) hands the 3 000–30 000 px/s band
  to the PCM path that already existed and costs nothing to store. It needed a prerequisite nobody
  had noticed: the samples mode drew ONE interpolated point per pixel — true at 1.6 samples/px, an
  alias at 16 — so the waveform would have THINNED on crossing the new threshold, with moire on the
  scroll. Hence a real min/max envelope per pixel, degenerating to the old interpolation under one
  sample per pixel so nothing changes where the mode used to start. And with it a region LRU keyed
  by `(path, slice)` instead of by path alone: at 3 000 px/s the canvas shows 20-40 lanes at once,
  where 30 000 px/s showed 0.05 s of timeline and one region per file was enough.
  **The spill was real** and was proven in isolation — a new project with ZERO objects, saved into a
  virgin folder, received a 92 MB `.wfc` of a file it had never opened, because
  `waveformsDirectory.didSet` wrote the WHOLE memory cache into whichever folder became current. The
  memory cache stays shared between projects on purpose (that is a benefit, not the bug); the flush
  is filtered through what the INCOMING project names, and `load` re-reads the target folder on the
  main actor JUST BEFORE writing — a big file takes a second, and a second is enough for a Save As
  to move the target.
  **And the envelope read channel 0 alone** while its comment claimed a mono mixdown. A mixdown
  would be worse, not better: out-of-phase channels cancel, so it would draw SILENCE over real
  sound. Peaks take the UNION of the channels' envelopes, a sample region takes the channel of
  largest magnitude with its sign, so the two paths agree either side of the threshold. Visible on
  existing projects: stereo material sitting on one side now draws LOUDER than it did.
  **The bug the testing found**, and the one to remember: a region is about as wide as the slot it
  is filed under, so a replacement is the ORDINARY case — and its memory was freed without the byte
  count hearing about it. The count climbed on memory nobody held, crossed `regionByteCap`, and from
  then on every region was evicted the instant it was decoded, each eviction forcing the re-decode
  that inflated the count again. Its signature is an eviction for EVERY decode: 18 705 of each at
  10 000 px/s with 40 lanes, where the regions actually resident came to 15 MB against a 48 MB cap.
  The widened-window constants were the suspect and were innocent.
  **The trap every test here is built around, and it produced a false negative during the
  investigation**: `--headless` proves NOTHING about this cache. With no Canvas,
  `ensureWaveformsLoaded` never fires, so nothing is computed and a headless run concludes there is
  no problem with a cache it never touched. `waveform.preload` exists for that, and answers
  `available: false` in headless so a scenario can refuse to pretend.
  Measured, RELEASE build, real 1.2 GB project, cache emptied first, driven over the API in UI mode:
  `waveforms/` **485 MB → 19.7 MB (÷24.6)**, RSS max 3.76 GB → **968 MB**, mipmap compute 1.82 s
  cumulative. Thrash at 10 000 px/s / 40 lanes: 18 705 decodes → **258**, decode work 106.4 s →
  **2.57 s**. `tools/test_waveform_peaks.swift` 54/54 including the assertion that IS the int16
  decision (`maxAbsoluteError × 15.85 × 450 < 0.5` px); the `.wfc` header checked byte by byte.
  Non-regression: smoke clean, families 185, markers ALL PASS, plugin-selection 58, export-preview
  35, relink ALL PASS, plugin-state-undo 5, the six standalone Swift suites, i18n 429 keys, no
  orphans, no visible string added. Session format untouched; `.wfc` format 2 → **3**, a v2 file
  being rejected and recomputed once per project, which is what `loadFromDisk` has always done.
  New commands: `perf.waveforms`, `waveform.preload`.
  **A figure NOT to trust, and why**: no comparison against `main` under this protocol is possible,
  the bench reading instrumentation `main` does not have. The 3.14 s quoted during the investigation
  came from standalone benchmarks of the compute stage alone and is NOT comparable to the 5.45 s
  wall measured here. What IS comparable is Debug against Release on one protocol: the compute stage
  runs **40× faster optimised** (72.1 s → 1.82 s). A lag felt at high zoom from Xcode's Play is
  largely that — `sampleEnvelope` costs 185 ms/frame at `-Onone` and 0.91 ms at `-O`.
  **Not seen on screen — not one pixel of any of it.** The reading that DECIDES: a dense, bright
  sound (cymbal, noise), block stretched to full height, the waveform pill at **+24 dB**, compared
  between the int16-only build and the complete one — no stair-stepping expected, and if there is
  any, the arithmetic above is wrong. Then the 3 000 → 30 000 px/s band by steps with scroll,
  watching the envelope's THICKNESS on crossing 3 000 (a sudden thinning means the aliasing is not
  solved), holes, and moire. Then two clips of one take at distant source offsets, a compressed
  source, and an open group in deep zoom — its composite band has NO samples path
  (`GroupWaveformView`), so it caps at 1 000 peaks/s and will show steps where top-level blocks are
  smooth; that is the main argument if the eye rejects the level removal, and the documented
  fallback is `[100, 1000, 3000]`, the same one-line array. **For an A/B, give each build its OWN
  copy of the project folder** (`cp -R`): two builds on one folder invalidate each other's cache at
  every launch.
  **Still doubted besides**: one assertion of `tools/scenario_waveform_cache.py` FAILS reproducibly
  — reopening a project already seen in the same process reads one mipmap off disk where zero was
  expected (waste, not a wrong result; the suspect is the macOS `/private/var` vs `/var` split
  showing as two spellings of one path in a dictionary keyed by string, the class of bug
  `PathRelink` already knows — a hypothesis, not a proof). `regionMinSpan`'s constants (×8, ceiling
  6 s) were chosen and never measured. Orphaned `.wfc` are NOT collected, deliberately: the cause is
  closed and the existing files are left alone, so they become ~80% of a `waveforms/` folder — an
  ugly ratio over an absolute size that no longer grows. And a `.wfc` is still named by BASENAME
  alone, so two sources sharing a file name share a cache file and invalidate each other:
  pre-existing, out of scope, worth knowing the day an unexplained recompute appears.

- **Automation is selected by a STRETCH OF TIME, and transformed as a block** (22-23 September
  2026, merged into `main` on the 23rd, then rebuilt the same day on the first real use).
  A curve was read point by point, so halving a crescendo meant taking every point by hand:
  deciding on a NUMBER where the ear only asked for a RATIO. One draws round a portion now and
  transforms it whole, with the eight grips the timeline's other surfaces already have.
  **The selection is a STRETCH OF TIME, and it is the TIMELINE'S OWN** — there is no second kind,
  and the day there briefly was one is the lesson: ↑ and ↓ moved one frame or the other depending
  on what had last been touched, and nothing on screen said which. It collapses on a fact already
  in the model — `SoundObject.automationSpan` says "one row = one lane", and a band's row `i` is
  laid at `entry.displayLane + 1 + i` — so a curve's row is nameable by `TimeSelection.lanes`
  exactly as an object's lane is. `stepTimeSelectionLanes` then walks onto it and off it again,
  the caret appears there and playback starts from it, none of which had to be written.
  A rectangle would frame THE MATTER IT FOUND; a stretch of time goes on existing when it is
  EMPTY, which is the only reason a passage of automation can be copied at all — a bounding box of
  points has no length to replace and nowhere to put a silence.
  **What belongs to automation is a READING, not a state**: `automationRowsOnScreen()` says which
  rows are unfolded and at which lane, `automationRowsInTimeSelection()` filters them. Empty means
  the selection is on objects, and that is how the keys tell the two apart — nothing stored,
  nothing to keep in step. The point selection stays stored (points can also be picked one by one)
  and is read off the frame by ONE hook, `timeSelection`'s own `didSet`: tracing, ⇧-extending,
  the arrows and undo all pass through that property, so none of them can forget to bring the
  points along. Picking points on their own clears the frame BEFORE laying them down, since that
  hook would otherwise undo the very call making it.
  Times travel in ABSOLUTE timeline seconds; a row's zero is its object's start, so the conversion
  lives at one door (`AutomationRowOnScreen.origin`), taken the way the LAYOUT takes it — an
  infinite bus has no start and its band begins at the timeline's zero whatever its object says.
  **⌫ is gated on `automationSurfaceHasKeyboard` and not on the point set**, and that is a trap
  rather than a nicety: a selection lying on automation rows must SWALLOW ⌫ even holding no point,
  because falling through hands those lanes to the object deletion, which resolves a display lane
  back to a BASE lane — and the base lane of a row inside a band is the band's OWNER.
  **The CLICK rules are the timeline's, called and not copied** —
  `EditViewModel.handleTimeSelectionClick` holds the caret, ⇧ and ⌘ for both surfaces, lifted out
  of the tap handler where they sat between two hit tests. A plain click lays the caret on the lane
  aimed at (so `onSeekToTime` no longer clears it: the ruler's "no caret on a lane" contract is
  what a row being a lane retires, and the caret is where the arrows and ⌘V start from); ⇧ extends
  from an anchor that does not move, so a second ⇧-click aimed back inside SHORTENS the range; ⌘
  toggles one lane. Clicking a POINT keeps priority over all three — the hand was aiming at a
  point, not an instant — which is the ordering the drag already used.
  **A TIME SELECTION HOLDS ONE KIND OF LANE**, decided by where the gesture started
  (`EditViewModel.confine`). Not tidiness: object lanes and automation rows answer the same keys
  differently (⌘C copies clips or a passage of curve, ⌫ deletes objects or points), so a mixed
  selection has to pick one and silently drop the other — and before the rule, a rubber band
  dragged over objects whose bands happened to be open quietly became a selection of automation
  points. The cost is stated: no passage can cover a clip AND its own curve, and nothing will be
  able to express that without lifting the rule.
  **The grips show over the ZONE**, not over any row the box crosses — a row runs the band's whole
  width, and the old reading lit eight squares up with the hand screens away from them.
  **Copy / cut / paste** sit beside the MIDI notes' clipboard and are modelled on it. A passage
  lands ON THE SELECTION — its rows and its start — which is what makes the arrows worth having:
  copy a passage of volume, walk the frame down onto pan, paste, and the curve arrives at the SAME
  INSTANT on the other parameter. The range is REPLACED, not added to (an automation is a function
  of time: two sets of points over one stretch interleave into a curve that is neither); onto the
  same parameter the values are exact, onto a different one they keep their PROPORTIONS.
  **A pre-existing bug repaired on the way**, and it is the one to remember:
  `updateAutomationPoints` clamped `t` to zero across the WHOLE lane rather than on the points
  touched, so moving a single point on an object cropped at the left piled silently onto zero
  everything waiting behind the edge — material `AutomationPoint` and `shifted(by:)` both declare
  legitimate (@see the negative-time convention). Clamping time belongs to the GESTURE. With it
  came `updateAutomationRows`: `pushAutomation` pushes ALL of an object's curves, so N rows
  mutated one by one cost N × M engine writes per frame on a gesture running at screen speed.
  Decisions worth keeping. **ONE `DragGesture`** — the zone and the transform are MODES of the one
  that existed, concurrent `DragGesture`s firing about half the time on macOS. The ORDER of
  `beginDrag`'s branching is half the feature: grip, then point, then line, then a zone — the grip
  tested BEFORE the row, a bottom grip being able to fall a pixel outside the band, and hit-tested
  on the box that is DRAWN (with a zone the two rectangles differ). `beginAutomationEdit` is
  SKIPPED for a zone (selecting must not leave an empty undo entry), the snap applies to the
  GRIP'S TARGET and never to the points one by one, and **no box is drawn for a SINGLE point** —
  eight grips round one point say nothing a point does not already say. ⌘ does not flip a
  selection during a drag; it inverts the SNAP, as everywhere else in the band. Points are
  addressed by STORAGE INDEX, as the whole existing API already does; the price is paid in one
  place and in full — the selection is PURGED at any structural change, undo included.
  **⌥ is what tells LOOKING from EDITING over a curve, on the wheel as on the drag** (23
  September). The wheel bent whatever segment the pointer rested on with no modifier at all, so
  scrolling to READ the timeline edited it — and by accident far more often than on purpose. The
  drag had always told the two apart (plain = move a point, ⌥ = bend the segment); the wheel now
  reads the same key, and without it is not swallowed at all. One key, one meaning, whatever the
  hand is doing. And **a passage traced in the band puts the caret on its start**: playback reads
  `viewModel.cursorPosition` and nothing else (@see `ObjekatSession.play`), so the band — the only
  surface that made a time selection without moving the cursor — let one select a stretch of curve
  and then hear somewhere else. It now ends on `onSeekToTime(range.lowerBound)`, as the timeline's
  own rubber band does, and at the END of the drag only: the cursor is not something to drag about.
  Verified: Debug build clean; `tools/test_automation_transform.swift` 62 assertions;
  `scenario_families.py` 185 OK, `scenario_markers.py` ALL PASS, `scenario_plugin_selection.py`
  58, `smoke.jsonl` clean; i18n 433 keys, three languages, nothing missing.
  **What no machine here can reach is the gesture itself**: the command API still has no
  `automation.*` family, so nothing headless can lay a point and read back what it is worth (the
  oldest debt in this memo, and the fourth entry to name it). The assertions prove the
  ARITHMETIC of the box, the half with no model behind it. Standing questions for the eye: whether a SNAPPED zone helps or
  gets in the way at a coarse grid (⌘ inverts it, but the first reflex on a zone that took
  nothing will not be to reach for ⌘); whether 4 px points are right or now too heavy on a
  sixteen-pixel row; whether pasting onto the same instant of another row is the gesture wanted,
  or whether the hand will expect the playhead more often than the frame; whether ⌘ toggling a
  WHOLE row reads as useful on a band of two or three; and that the arrows now walk the frame OUT
  of the band and on down the timeline — the consistency that was asked for,
  and also a passage leaving the curve it was taken from in one keystroke.

- **"Sound object" (the baked/shared kind) becomes "consolidated object"** (24 September 2026, ON
  THE BRANCH `refactor/consolidate`, NOT on `main`) — a pure rename, decided ahead of time in
  `plan_consolidate.md`: what a reader sees, the command names and the Swift/ObjC identifiers all
  move to "consolidate/consolidated/deconsolidate"; `SoundObject` (the type) and "sound object" in
  its GENERIC sense (any object on the timeline, Schaeffer's own term) are UNCHANGED — the two
  senses had shared one English word since July, and that is exactly what made the vocabulary hard
  to read. **The disk key never moves**: `definitionID` / `objectDefinitions` /
  `dependsOn[].definitionID` stay those exact JSON keys forever (an explicit `CodingKeys` mapping
  pins each one by hand, e.g. `case consolidateID = "definitionID"` — cas E7 of the plan, the whole
  reason blind renaming was safe). New bakes land in `samples/consolidate/`; a project from before
  this branch keeps its content in `samples/objects/`, read by a 3-candidate resolver
  (`ConsolidateFolders.swift`) that also falls back on an existing instance's own folder (Q3,
  fixing a Save-As-to-a-new-folder trap). The old `definition.*` command family answers as hidden
  aliases (`CommandRegistry.aliases`, resolved by `execute`, absent from bare `help`, named via
  `alias_of`). Session format 15 → 16 for the `_readme` text alone — no old build can EDIT a
  consolidated object made by a new one (its wave sits in a folder the old build never reads), but
  it plays the project whole; accepted, forward incompatibility only.
  Nine steps, one commit each: (1) the resolver + its standalone test,
  `tools/test_consolidate_folders.swift`, 17/17; (2) the Swift identifier rename (`\b`-bounded,
  longest names first) + the three CodingKeys pins + three file `git mv`s
  (`ObjectDefinition.swift` → `ConsolidateDefinition.swift` among them); (3) the ObjC bridge
  (`OBJEngineCore.h`/`.mm`) — including its **auto-synthesized backing ivars**, which a renamed
  `@property` moves silently and would otherwise have failed to compile; (4) the `consolidate.*`
  command family + the alias mechanism; (5) 20 `Localizable.xcstrings` keys renamed, 2 rewritten in
  place, 2 new tooltips (`menu.context.consolidate.help` / `.deconsolidate.help`) — `check` 435
  keys clean, `orphans` empty, a JSON diff against `main` confirming nothing else in the catalogue
  moved; (6) the format bump, and a bug this same rename surfaced: step 2's blind identifier
  substitution had also renamed a PROSE sentence in `SessionSchema`'s own `_readme` text into
  saying the JSON key was `consolidateDefinitions` — it never was and never will be, so the note
  was actively lying about the file format until this step corrected it back to `objectDefinitions`;
  (7) this entry, plus `glossary.md`, `command_api.md` (incl. fixing a pre-existing `freezingIDs` →
  `bakingIDs` drift), `architecture_decisions.md`, `README.md:12`.
  **Deviation worth knowing**: step 2's own bare-word `\bmakeObject\b` substitution (needed for the
  Swift FUNCTION `makeObject` → `consolidate`) silently reached into ONE xcstrings key reference
  living inside a Swift string literal, `L("menu.context.makeObject")` →
  `L("menu.context.consolidate")`, a whole step ahead of the i18n step that was supposed to own
  that rename. It happened to land on exactly the name step 5 needed, verified by diffing against
  `main`, so nothing broke — but it is the kind of accident a word shared between an identifier
  table and a string literal will keep producing, worth watching for on the next such rename.
  Verified with no screen, through step 7: a Debug build after every step, no new warning;
  `tools/scenario_families.py` grown with three assertions on the alias mechanism, 191 OK; the
  xcstrings check/orphans above. **Not yet run, at the time of this entry** (done since — see the
  next entry): the dedicated
  migration scenario (`tools/scenario_consolidate.py`, T3 of the plan — an old-format project
  built with `objects/`, opened and edited by the new build) and `project.save_copy`, both still to
  come as steps 8–9 of the same plan. **Not seen, not heard**: every pixel of the rename — the
  "Consolider" / "Dé-consolider" menu entries and their tooltips in the three languages, the
  synoptic's badges on a closed consolidated object, dé-consolidating a nested instance while its
  parent is open, and a real user project opened on a copy.

- **Consolidate, steps 8–9 and three older bugs fixed** (24 September 2026, still ON THE BRANCH
  `refactor/consolidate`, not merged, nothing pushed). Step 9 = `project.save_copy {path}` (the
  menu's "Save a copy with audio files" without its panel, awaits the last write, answers a
  `SaveCopyReport`). Step 8 = `tools/scenario_consolidate.py`: phase A has the ARCHIVED OLD BUILD
  (`../objekat 2026-09-23 13-00-42.app`) make a real `samples/objects/` project (A, A nested in B,
  C), phase B drives the new build through B1–B14 of the plan plus X-checks. It found two bugs of
  the rename, fixed in their own commits: `consolidate.list` ordered by name only over a dictionary
  (flaky B6 — now name then id), and E17 (a read-only project ended its commit on a bare "render
  failed" — `ensureConsolidateFolder` now throws and the session stays open). Then three bugs
  OLDER than the rename (reproduced on the 23 September build), one commit each:
  1. **Data loss — "Save a copy" onto the project's own folder erased its consolidated waves.**
     The copy writes "remove the destination, then copy the source"; there, the destination of
     each wave IS its source. `performSaveCopy` (so the menu, and the API through it) now refuses
     a destination that is, lies inside, or contains a folder the copy READS from — the project
     folder AND the old project folder waves are still read from after a Save As (Q3) — with a
     localised alert (5 keys `saveCopy.error.destination.*`, 440 keys, check/orphans clean);
     identity by `fileResourceIdentifier`, so case (APFS), symlinks, `..`, `/tmp` vs
     `/private/tmp` are seen through. Last line of defence in the I/O loop: a file whose
     destination is the same file is left in place. API: `bad_params` + `details.source`
     (was `invalid_state`, equality only).
  2. **Undoing `consolidate.edit_commit` detached the instance** (a plain group). The commit's
     `pushUndo()` ran while the placement was still MATERIALISED, and the session is not in the
     snapshot. Now the commit's undo point is the state with the session CANCELLED (the linked
     instance from before the opening, root curves kept), taken after the mirrors are back and
     before the registry moves — other instances and nested definitions return to their previous
     revision; redo gives the committed state. Each `ConsolidateEditSession` records
     `undoDepthAtOpen`; commit AND cancel cut the stack back to it (a materialised snapshot must
     never outlive its session — the undo after a cancel had the same flaw). Consequence to know:
     gestures made OUTSIDE the content during a session fold into the commit's single undo point;
     a nested session cuts only its own points. `edit.undo` over the API INSIDE an open session
     still restores items without touching the session stack (the UI's ⌘Z cancels instead) —
     tested only for the nested-commit case, where it is coherent.
  3. **The copy lost `snapEnabled` and `viewport`**: `performSaveCopy` built its own
     `ProjectDocument` and the initialiser defaults them to nil. One builder now,
     `projectDocument(items:consolidateDefinitions:)`, shared by save/get_state and the copy.
  **Verified with no screen** (Debug build after each fix, no new warning):
  `scenario_consolidate.py` ALL PASS, 137 checks, phase A made by the real old build, the
  former KNOWN check now strict; T2 — `smoke.jsonl` (`--exec`) rc 0, `scenario_families` 191 OK,
  `scenario_markers` 93 ALL PASS, `scenario_relink` 46 ALL PASS, `scenario_plugin_selection` 58,
  `scenario_plugin_state_undo` 5 ALL PASS; the nine standalone Swift tests of `tools/` all pass.
  **Not verified**: the save panel itself and the alert on screen (the refusal is exercised
  through the same `performSaveCopy`, the alert only as a recorded dialogue); the viewport's
  SCROLL end to end (restored by the TimelineView, absent headless — only the zoom is checked
  through a reopening; a headless save writes scroll 0, pre-existing); ⌘Z in the UI around a
  session; the "no window on the headless pid" check of the plan; and everything the previous
  entry lists as never seen or heard.

- **Scroll and zoom driven by script, and the frames they cost** (24 September 2026, on `main`)
  — `view.*`, `input.*`, `perf.frames.*`: a scroll or zoom from a script now goes the hand's
  own way, through real `CGEvent`s posted with `NSApp.postEvent`, so it passes the timeline's
  `NSEvent` monitors, the dead zone, the axis lock and the scroll view's deceleration. A
  `CADisplayLink` on the timeline's view and a run-loop observer then measure what it cost.
  There are no thresholds and no verdicts: the reports give distributions, meant for comparing
  two situations. Pinch was left out because ⇧+scroll does the same. The contract and the
  measured variance are in `command_api.md` ("Synthetic navigation"). Three facts found along the
  way, because they apply beyond this feature:
  1. **`postToPid` never delivers** on macOS 15.
  2. **An `NSEvent` made from a `CGEvent` has no window** unless raw field 51 and the private
     `CGEventSetWindowLocation` are set. Without them the monitors see the event but the view
     never moves. This is **private API**, and `input.selftest` is the canary for it.
  3. **A synthetic event's timestamp changes how far it scrolls**: the same swipe travelled
     1503 px undated and 2200 px dated.

  The ⇧-zoom needs a hover. A synthetic event cannot move the cursor, so a test hook lays the
  hover (`TrackerView.simulateHover`). Every gesture answers only once the view is at rest.
  **UI mode only**: in headless mode these commands answer `invalid_state`.
  Verified with no screen: Debug and Release builds with no new warning;
  `tools/scenario_navigation.py`, 43 assertions ALL PASS against a Release instance in UI mode;
  `smoke.jsonl` clean. A first comparison with `tools/bench_navigation.py` (Release, 1 object
  against 480), which **the numbers say and no one has yet looked at**:
  - **zooming is what gives way**: horizontal zoom falls from 117 to 14.5 fps, with frame p95
    8 → 159 ms and busy p95 ×16–32. Vertical zoom falls to 25 fps.
  - scrolling holds its p95 but adds 11–12 late frames per horizontal pass, which look like
    ~120 ms stalls. The unconfirmed suspect is the 512 px notches of `cullScrollX`.

  **Not seen, not felt**: whether a real trackpad gesture, recorded with `input.record.*` and
  then replayed, feels like the original. The only recordings made so far were of synthetic
  events.

### What is owed

**The debt is listening, not code.** Everything implemented without ever having been
heard or seen is gathered into a single list: **[[validations-en-attente]]**. Do not keep
a second one elsewhere. The most exposed points:

- denormalising a curve onto a **built-in** plugin parameter (a `lowpass` runs from 10 to
  22000 Hz, and a 0…1 curve would be crushed there onto 10 Hz);
- the signal path corrected on 12 August: a group's tap post-fades, the FX tail cut at the
  bounds, a stem mute that also cuts the wet;
- `ContainerClipNode` only cuts the AUDIO at its bounds, not the MIDI — **to be listened to before
  fixing it pre-emptively**;
- the temporary `[MIXFOCUS]` logs in `Inspector/Synoptic/SynopticView.swift` (4 `NSLog`s), to be
  removed as soon as the volume/pan fix is confirmed at runtime;
- the three languages of the interface, never seen on screen: neither the layout under a longer
  text, nor the plurals, nor `--language=`. The labels of 2 September sharpen the point, since
  they live in narrow pills: "rogner" / "recortar" against "crop" in the piano-roll's band,
  "invertido" against "reverse" in a 9 pt pill of the synoptic.

### Scope rules worth knowing (they are surprising)

- **An object's window cuts its chain, fades included.** A container has the same chain tail
  as a clip (`ObjGain` then `ObjWindowFade`). A bus that must let its tail ring declares itself
  **infinite**. A corollary: the fades OF a container's CLIP are held at zero, otherwise they
  would apply twice.
- **The scope of a top-level send: the same stem, OR an aux of the Main.** A send goes UP, it does not go
  down, and two sibling stems cannot see each other. That is what makes a single reverb shared by
  several stems possible — at the Main and there only. An accepted cost: the wet leaves its
  stem, so "Σ stems = mix" assumes the Main is delivered as a stem. The complete rule is
  commented above `canRouteSend` (`EditViewModel+Aux.swift`).
- **What will never cross a container's boundary**: a child of a sub-group does not reach
  the parent group's aux (the way round: put the send on the sub-group, which IS a sibling).
- Sends out of scope stay in the model, silent. We merely stop offering them.

### A parked project

`claude/tracktion-au-seamless-swap-j2t708` — "switching an FX with no seam". One unmerged
commit, laid on 19 August: plan a **rebase**, not a blind merge. It is now **local only** —
it left the remote when the history was squashed — and it shares no ancestor with the
published `main`, so a cherry-pick is the likely tool rather than a merge.
[[tracktion-au-seamless-swap]].

---

## Permanent points of attention

- **No visible sentence lives in a `.swift`.** Every interface text goes through `L("key")`
  (or `Ln("key", n, …)` for a singular/plural), and the keys are SYMBOLIC —
  `export.panel.title`, never the sentence. The values live in
  `objekat/Resources/Localizable.xcstrings`; `tools/i18n/xcstrings.py check` says what is missing,
  `orphans` what is no longer used — and `check` also compares the `%@` / `%d` of one language
  against another: a translation that has not got the same ones reads the argument stack askew.
  A missing key shows as it is: the oversight is visible. The vocabulary is fixed by
  `docs/glossary.md`.
  What does NOT go through it: the `NSLog`s, the perf labels, the session file's header, and everything
  the command API returns — that is a machine contract, it stays in English and monolingual.
- **A literal inside a `Text(…)` is a translation KEY, not a string** — and Xcode pours it into
  the catalogue by itself. SwiftUI types `Text("infini")` as a `LocalizedStringKey`: it looks the
  word up, finds nothing, and displays it as it is. It works — in all three languages, which IS
  the bug, and one that only shows the day the interface is read in English. Then Xcode's
  extraction harvests every such literal at build time and WRITES it into the catalogue: a
  `Localizable.xcstrings` that changed with no session having touched it comes from a build
  launched in the IDE. The cost is not tidiness, it is that `check` then reports those keys as
  untranslated for ever, and the one real oversight hides among the noise. Three fixes, sorted by
  a single question — does this text mean anything to translate?
    - yes (`infini`, `crop`) → `L("key")`;
    - no — a glyph (`—`, `⌘`, `›`), a unit (`dB`, `%`, `bpm`), a number or a format
      (`"\(n) dB"`) → `Text(verbatim:)`, which says "this is a `String`, show it as it is";
    - a label deliberately left empty (`TextField("")`, `Picker("")`, `Toggle("")`) →
      `TextField(noLabel, …)`: a `String` variable picks SwiftUI's `StringProtocol` overload
      instead, so no `LocalizedStringKey` is ever formed. Nothing changes on screen — what
      changes is which overload Swift resolves to. Same trap and same fix for
      `Label("\(prefix)\(name)", systemImage:)`, which yields a `%@%@`.
  A format is the dangerous one: `"%lld dB"` is a template with a hole in it, and a translation
  that loses its `%lld` makes `String(format:)` read the argument stack askew.
- **`--language=fr|en|es`** forces the language for one launch (a volatile argument domain, nothing
  is persisted); `app.info` returns `language`.

- **Every test launch goes through `--no-recent`** — an `--exec` scenario, an `--api` socket, or a trial
  by hand in the app: a test's throwaway projects have NO business in "Recent
  projects", which keeps only ten and loses that many of the user's real projects. The flag
  holds with or without `--headless`; `app.info` returns `records_recent_projects` to check
  the instance being driven BEFORE having it open anything at all. The same spirit for everything
  persisted outside the project: a test does not write into the user's settings.
- **OBJEKAT is under the AGPLv3** (`LICENSE`, `NOTICE`, copyright Nicolas Vair). The Affero clause
  is inherited, not chosen: Tracktion cannot run without JUCE, and the free option of JUCE 8 is
  the AGPLv3, which the GPLv3 §13 bridge carries over to the whole. The practical consequence
  for a session: **every new dependency must be AGPLv3-compatible** — no MIT-only-in-appearance
  library whose transitive dependencies are not, and nothing under a licence that forbids
  redistribution. In doubt, ask rather than add.
  The legal notice an interactive programme owes its user — copyright, absence of warranty,
  licence, where the sources are — lives in the build setting
  `INFOPLIST_KEY_NSHumanReadableCopyright`, and macOS shows it in the "About OBJEKAT" panel it
  offers for free. It is the ONE visible sentence that does NOT go through `L()`: it is not a
  `.swift`, and a legal notice is not translated lightly. Leave it in English, and keep it in
  step with `NOTICE`.
- **The engine comes down on its own since 3 September 2026** — `git clone --recurse-submodules`
  and nothing else. The submodule points at the fork `nicolasvair/tracktion_engine_for_objekat`,
  which carries `objekat-patches-3.5`; `modules/juce` stays on the official `37c894f83d3`. Before
  that, the gitlink named a branch pushed nowhere and a third-party clone got `upload-pack: not
  our ref`. The consequence for a session: **after any engine commit, the branch has to be pushed
  to the fork and the gitlink realigned** (`tools/publish-engine-forks.sh`), otherwise the clone
  breaks again for everyone but this machine. `engine-patches/3.5/` is now the safety net rather
  than the way in — `tools/rebuild-engine.sh` reconstitutes everything. The procedure and the
  traps: `INSTALL.md`.
- **The project signs ad hoc, with no development team, and that is deliberate.** `DEVELOPMENT_TEAM`
  is empty and `CODE_SIGN_IDENTITY` is `"-"` so that anyone can build with no Apple account. A
  team ID committed into `project.pbxproj` would stop every contributor at the signing step. If
  Xcode writes one back in (it does as soon as you touch Signing & Capabilities), **do not commit
  it**. The entitlements are hardened-runtime exceptions for hosting plugins, and need no
  provisioning profile — verified, they survive the ad-hoc signature.
- **With `--headless`, NOTHING may open a window** — and the trap is that opening one is a SIDE
  EFFECT of a gesture that is about something else: adding a plugin opens its editor, so a plain
  `plugin.add` from a script put a plugin's UI on the screen of whoever was working (found and
  fixed 14 September 2026, a built-in `4bandEq` added by `scenario_families.py`; the API's own
  contract had said "no command opens a plugin editor" since day one, which is exactly how nobody
  noticed). The guard is at the TWO functions that open an editor — `openPluginEditor` and
  `openBuiltInPluginEditor`, through `EditViewModel.hasInterface` — and not at their callers: a
  guard at each caller is a guard the next caller forgets. Anything else that shows a window has to
  do the same.
  It can be VERIFIED with no screen: `CGWindowListCopyWindowInfo` filtered on the headless process's
  pid must return an empty list (`python3 -c "import Quartz; …"`, no permission needed, unlike
  System Events).
- **Launch arguments as `--key=value`** only — an orphan argument starts the
  app with NO window, silently.
- **Visual and aural verification belongs to the user.** I verify what can be verified with no
  screen (a build + a headless CLI test), then I say explicitly what has NOT been seen or heard.
  No testing by screenshot, no reading meters. An export re-read in the CLI is in
  **24 bits**: re-reading it as `int16` makes it look like time stretched by a factor of 1.5.
- **A letter shortcut read from `event.characters` loses ⌥.** macOS composes: with ⌥ held, the C
  key gives `"ç"`, not `"c"`. The `case` never matches, the key goes back unconsumed and AppKit
  **beeps** — and the beep is only the symptom: no ⌥+letter shortcut is reachable at all, which is
  how the Cut tool became unreachable under ⌥, i.e. exactly the ripple-cut gesture (found
  9 September 2026). The fix is NOT to read the whole switch from `charactersIgnoringModifiers`:
  that also undoes ⇧, and ⇧ is what MAKES `<` and `>` on most layouts. A **letter** is read without
  its modifiers, **punctuation** with them. Same family of trap as the digits, which are identified
  by their PHYSICAL keyCode because AZERTY needs ⇧ for them — other remedy, same lesson: what a key
  MEANS and what it TYPES are two different questions.
- **An arrow key is NEVER "bare": macOS stamps it `.function` + `.numericPad`** (`0xA00000`), and
  caps lock leaves its own flag on besides. So `flags.isEmpty` as the test for "no modifier held" is
  false for ↑ ↓ ← → whatever the hand does — the branch never fires, the key goes back to AppKit
  unconsumed, and it BEEPS (found 15 September 2026, on the ↑ / ↓ that slide the time selection; and
  the beep is the same one the ⌥+letter trap makes, one family of bug up). The test is an EMPTY
  INTERSECTION with the modifiers a hand actually holds: `flags.intersection(heldModifiers).isEmpty`
  (`TimelineKeyHandler.heldModifiers` = ⌘⇧⌥⌃). Lesson shared with the ⌥+letter trap: a key that
  beeps has been consumed by nobody — read the condition before the body.
- **Never lay a cursor with `NSCursor.set()` / `push()` / `pop()`** — go through
  `objekat/Shared/CursorClaim.swift`. It does not hold otherwise.
- `toRawUTF8()`: always on a local `juce::String` variable, never on a temporary.
- Thread safety: Tracktion mutations from the main thread only.
- Rendering: do not modify the Edit during an export.
- **A slow gesture is almost always an AudioUnit instantiation on the main thread** —
  not the view, not the graph, not the undo. All three have been measured innocent. And an AU
  CANNOT be instantiated off the main thread: it is a JUCE constraint, measured.
- Timeline performance: ZStack+offset is fine up to ~100 objects, a Canvas is required beyond that.
- `NSEvent.addLocalMonitorForEvents`: a `@State` token, removed in `.onDisappear`.
- **A click that makes a window key is THROWN AWAY unless the view under it accepts it** — and no
  SwiftUI view does (`acceptsFirstMouse` is false by default). So any window of ours opened beside
  the main one — a plugin editor above all, JUCE's or our own — costs the next click made back in
  the main window, spent on nothing. The remedy is laid once and app-wide in
  `Shared/FirstClickThrough.swift`: a local monitor makes the clicked window key BEFORE the event
  is dispatched (a monitor runs inside `NSApp.sendEvent`, ahead of the window's `sendEvent:`) and
  returns the event untouched. It holds only while the app is ACTIVE, and leaves panels and modals
  alone. Nothing to do when adding a window — but everything to know the day a click is lost again.
- The sources in `objekat/` + the Xcode project `objekat.xcodeproj`; the documentation in `OBJEKAT - claude project/`.
- SourceKit's "Cannot find type … in scope" diagnostics = false positives (isolated indexing);
  only `xcodebuild` is the authority.
- Timeline blocks = pure presentation; tap/drag/click resolved geometrically by the parent canvas
  (`TimelineView+TapHandler`).

---

## History — where the current model comes from

Condensed; the detail is in `architecture_decisions.md` and in the memory notes.

- **July 2026 — the "sound objects" rework** (renamed "consolidated objects" on 24 September 2026 —
  see Current state; the type `SoundObject` and the term's GENERIC sense are untouched, only the
  shared/baked kind's own name moved). A sound object is a group that can be instantiated in N
  places. Two accepted regimes: **baked** (a closed object, every instance reads a wave) and
  **live** (an open object, the other instances are mirrors of the origin, with no render).
  Opening on a double-click, cancelling with `Esc` / `⌘Z`. Freezing was taken out of the UI, but its
  machinery still carries the bake — and the `freeze` vocabulary was renamed `bake`.
- **8 → 13 August 2026 — the containerclip base.** A group is ONE clip
  (`ContainerClip` + `ContainerClipNode`), no longer a `FolderTrack` + N tracks: 1000 groups of which only
  one plays cost one group (measured). In the same run: decoupling lane from track, MIDI inside a
  container, the PDC of the send taps and of the lanes, the stems rewired as a submix `FolderTrack`, inter-stem
  auxes. A constraint never to be violated: **no policy may make the number of
  tracks proportional to the number of objects.**

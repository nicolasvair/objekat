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

## Current state (5 September 2026)

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
longer does, so it can no longer go stale. The fork's branch is at `f7fd2e9fd45` since its
own history was rewritten on 4 September; `494e91d2ff5` is still its ancestor.
An engine series of **29** patches in `engine-patches/3.5/`, numbered `0001`→`0031` with two
holes: `0004` and `0010`, the only JUCE ones, were set aside on 3 September 2026 into `pending/`
(see its README). The next one will be `0032`. It is the ONLY series left: the four archives of
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
  for the next time one pulled that edge. What
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
  step: nothing moved. (It was written for the OBJECT selection first, on a misreading, and the
  arrows then beeped for the very gesture they were meant for — with only a range traced and no
  object held, the branch never fired and the key went back to AppKit unconsumed. The lesson is the
  older one about beeps: a key that beeps has fallen THROUGH every branch, so look at the branch's
  condition before its body.) An EMPTY row is a row like any other here, unlike an object selection:
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
  **Not felt**: the crossfade gesture under the hand, and the arrows on a real timeline.

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
- The sources in `objekat/` + the Xcode project `objekat.xcodeproj`; the documentation in `OBJEKAT - claude project/`.
- SourceKit's "Cannot find type … in scope" diagnostics = false positives (isolated indexing);
  only `xcodebuild` is the authority.
- Timeline blocks = pure presentation; tap/drag/click resolved geometrically by the parent canvas
  (`TimelineView+TapHandler`).

---

## History — where the current model comes from

Condensed; the detail is in `architecture_decisions.md` and in the memory notes.

- **July 2026 — the "sound objects" rework.** A sound object is a group that can be instantiated in N
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

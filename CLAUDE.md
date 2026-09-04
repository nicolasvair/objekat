# Continuity memo — OBJEKAT

The crossing point between Claude Code sessions. Under this name and at the root, it is **loaded
automatically** at the start of a session: no more hoping somebody thinks to open it.

The documents that are the authority, to be opened as needed:

- `OBJEKAT - claude project/README.md` — the project, its concept, its progress.
- `OBJEKAT - claude project/docs/architecture_decisions.md` — the architecture decisions.
- `OBJEKAT - claude project/docs/command_api.md` — the command API, the launch arguments,
  driving by script.
- `OBJEKAT - claude project/docs/glossary.md` — the vocabulary, FR → EN → ES.

And the session memory (`MEMORY.md` + the notes), which carries the detail of the projects: this
memo keeps only the state and the traps.

---

## Current state (4 September 2026)

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
- **Launch arguments as `--key=value`** only — an orphan argument starts the
  app with NO window, silently.
- **Visual and aural verification belongs to the user.** I verify what can be verified with no
  screen (a build + a headless CLI test), then I say explicitly what has NOT been seen or heard.
  No testing by screenshot, no reading meters. An export re-read in the CLI is in
  **24 bits**: re-reading it as `int16` makes it look like time stretched by a factor of 1.5.
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

# Feedback of 4 November 2026: the plan

The user wrote ten requests in French (verbatim at the end, §Z). This plan splits them into **independent LOTS**,
ordered from least to most risky: pure UI first, engine last. Every lot builds on its own and makes one commit (or a
few). Line references are to `main` @ `79698a8`. A line marked *(inferred)* has not been read in the code and must
be checked before it is relied on.

Rules that hold for every lot (from `CLAUDE.md`):

- No visible text in a `.swift` file: use `L("key")` with symbolic keys in `objekat/Resources/Localizable.xcstrings`,
  in fr / en / es. Check from the repository root with `python3 tools/i18n/xcstrings.py check` and `orphans`. `check`
  already reports one empty key `""` under `es`. That noise comes from an IDE extraction and is left alone.
- Glyphs, units and numbers go through `Text(verbatim:)`.
- Tracktion is only mutated on the main thread. Nothing allocates or takes a lock on the audio thread.
- One undo point per gesture. Nothing is recorded outside the undo stack if the snapshot compares it.
- With `--headless`, nothing opens a window. Every test launch uses `--no-recent`.
- No engine (Tracktion) patch is needed by any lot. The next free number stays `0051`.
- **Lots that touch `OBJEngineCore.h/.mm`: L10 and L11 only.** The file is MRC (manual reference counting): a block
  stored in C++ needs `Block_copy`. The header needs complete nullability annotations.
- Commit titles take the form `Feedback 2026-11-04, Ln: …`. Each commit message ends with the attribution lines the
  session gives.
- Only the user's eye and ear can verify on screen and by ear. Each lot ends with what is owed to them.

---

## L1 — Remove the keyboard button from the transport bar (request 1)

**Commit:** `Feedback 2026-11-04, L1: no computer-keyboard button in the transport bar`

- `objekat/App/TransportView.swift:121-137`: delete the comment and the whole `Button { viewModel.toggleComputerKeyboardMode() } …`
  including its `.overlay`. Change nothing else; the bar's density probe measures itself.
- Delete the key `transport.keyboard.help` from the catalogue, since it becomes an orphan.
- `objekat/Inputs/ComputerKeyboardRowControls.swift:6`: the doc comment says "the transport bar's button reads and
  writes the same two". Rewrite it: the row is now the only way in.
- The mode stays reachable through the Inputs row (L5) and `midi.keyboard.set`. Still **no shortcut**.
- **Verify:** build; `xcstrings.py orphans` must not list `transport.keyboard.help`; `tools/scenario_computer_keyboard.py`
  must stay green.
- **User's eye:** the bar without the button, at every density.

## L2 — Esc disarms every zone (request 10)

**Commit:** `Feedback 2026-11-04, L2: Esc disarms every recording zone`

- Door in `objekat/EditViewModel/EditViewModel+RecordZones.swift`, beside `setArmed` (l.91):
  `func disarmAllRecordZones() { if !armedGroupIDs.isEmpty { armedGroupIDs = [] } }`. The `didSet`
  (`EditViewModel.swift:1361`) already re-syncs the engine.
- `objekat/Timeline/TimelineKeyHandler.swift:717-731` (the BARE-Esc `DispatchQueue.main.async` block): add
  `vm.disarmAllRecordZones()` at its end.
- The earlier branches are not touched and do not disarm: the held-key chords, `routePick` and the consolidated edit.
  Each `return`s first.
- **Decision:** Esc also disarms WHILE recording.
  - Why it is safe: the recording runs on `recordingZones`, which are frozen at the press
    (`EditViewModel+Recording.swift:207`). `syncArmedInputs` is guarded by `!isRecording` (l.126). The engine keeps
    `setMidiZones` as it is while recording (`OBJEngineCore.h`, doc of `setMidiZones:`).
  - Effect: the take in progress finishes normally. The zones are not armed for the next take.
- API, in `CommandAPI/Commands+Record.swift` beside `rec.arm` (l.446): add `rec.disarm_all` (no parameters,
  `undo: .none`). It returns `Self.recordStatusJSON(vm)`.
- Cheat sheet (`Timeline/ShortcutCheatsheet.swift`): add one row `ShortcutRow(keys: "⎋", label: L("cheatsheet.record.escDisarm"))`
  in the section that lists ⌘⇧R.
- **i18n:** `cheatsheet.record.escDisarm` — fr « Désarmer toutes les zones d'enregistrement », en « Disarm every recording zone »,
  es « Desarmar todas las zonas de grabación ».
- **Test:** add a section to `tools/scenario_record_zones.py`: arm two zones, call `rec.disarm_all`, then
  `rec.status.armed == []`. A second call answers the same.
- **User's eye:** Esc in the timeline makes every blink stop; the cheat sheet row.

## L3 — The audio menu becomes a real tree (request 3, clarified by the user)

User: « Menu audio vers un proposer arborescent, utiliser le menu du sidechain mais ajouter l'arborescence ».

History:
- Before `fcb7e5a` (Lot D step 2), the wrench was a native `Menu` with three `Picker`s, so three native SUBMENUS.
- It is now a `TreePickerPopover` with FLAT sections that are always open (`AudioMenuModel.swift:80-118`,
  `collapsible: false`). With many cards it becomes one long list.

**Decision:** keep the shared picker (it stays open across clicks, which is why it replaced the native `Menu`) and
give it BRANCHES that expand INLINE, one at a time (an accordion).

Why inline and not cascading flyouts:
- A popover is ONE window. Cascading flyouts would need child popovers with hover timing, and they would close on
  focus changes.
- Inline keeps the 420 pt scroll (`TreePickerPopover.swift:131`) and the shared row style.

**Commit:** `Feedback 2026-11-04, L3: the audio menu as a tree (branches in the shared tree picker)`

### The model half (`objekat/Shared/TreePickerPopover.swift`, pure part l.1-99)

1. `TreePickerNode.Role` gains `.branch`, a row that ONLY opens and closes its children and is never chosen. Add two
   fields:
   - `var detail: String? = nil`: grey text at the row's right (the current value).
   - `var startsOpen: Bool = false`.

   Add `static func branch(_ id: String, _ name: String, detail: String?, startsOpen: Bool = false, children: [TreePickerNode]) -> TreePickerNode`
   (`selectable: false`, `role: .branch`). `isChoosable` (l.36) already answers false, because `role != .choice`.
2. `TreePickerModel.seed(_:opensCheckedBranches: Bool = true)` (l.65):
   - A `.branch` node is inserted into `nodes` when `startsOpen`, or when `opensCheckedBranches && containsChecked`.
   - `.choice` groups behave as today. The sidechain passes nothing, so nothing changes for it.
3. New pure function:
   `static func toggled(_ id: String, expanded: Set<String>, siblings: [String], accordion: Bool) -> Set<String>`.
   - If `id` is open, remove it. Otherwise insert it, and when `accordion` is true also remove every other id of
     `siblings`.
4. `widest` (l.88) measures `name` plus, when there is a `detail`, `12 + measure(detail)`. The width stays stable
   whether a branch is folded or open.

### The view half

- `TreePickerPopover` gains two init parameters: `accordion: Bool = false` and `opensCheckedBranches: Bool = true`.
- `nodes(_:depth:)` (l.181) handles `case .branch:`. It draws `branchRow(n, depth:, siblings: list.map(\.id))`, then,
  when `expanded.contains(n.id)`, `nodes(n.children, depth: depth + 1)`.
- `branchRow`: ONE `Button` over the whole row with `TreePickerRowStyle` (hover highlight). Its action is
  `expanded = TreePickerModel.toggled(...)`. Its label is an `HStack(spacing: 4)` holding:
  - the chevron (`chevron.right` or `.down`, 9 pt bold, width 14);
  - `Text(verbatim: name)` at 11 pt semibold;
  - a `Spacer`;
  - `Text(verbatim: detail)` at 11 pt `.secondary`, `lineLimit(1)`, `truncationMode(.middle)`.

  Leading padding is `depth * 14`, the same as `row`.
- `seed(list)` (l.147) passes `opensCheckedBranches` through.

### The audio menu's tree (`objekat/Shared/AudioMenuModel.swift:80-118`)

`sections` returns ONE untitled section (`id: "audio"`, `title: nil`) holding these branches, in this order.

| Branch id | Name (label, existing key) | `detail` | Children (existing ids, unchanged) |
|---|---|---|---|
| `branch.output` | `labels.output` | `currentOutput ?? labels.noOutputDevice` | `outputID(name)` per device; when there is none, `.note("output.none", noOutputDevice)` |
| `branch.input` | `labels.input` | the ticked card's name, else `labels.sameInputCard` | `inputID(nil)` + one per card + `inputNote` as `.note`; `startsOpen: inputNote != nil` |
| `branch.rate` (only if rates exist) | `labels.sampleRate` | `formatRate(currentSampleRate)` | the rates + `sampleRateNote`; `startsOpen: sampleRateNote != nil` |
| `branch.buffer` (only if buffers exist) | `labels.buffer` | `formatBuffer(currentBufferSize, sampleRate:)` | `usefulBufferSizes(...)` |

- `action(forID:)` is unchanged: an id starting with `branch.` matches no prefix and returns nil.
- `AudioTitleBar.swift:72` passes `accordion: true, opensCheckedBranches: false`. The popover therefore opens on four
  folded lines, each saying its current value.
- A choice keeps the popover AND its branch open (`closesOnChoose: false`, unchanged), and the detail re-ticks
  through observation.
- The sidechain picker (`Inspector/SidechainStripView.swift:113`) is unchanged.
- **i18n:** no new key. The branch titles reuse `audio.menu.device`, `.input`, `.sampleRate` and `.buffer`.
- **Tests (compile lines are in each file's header):**
  - `tools/test_tree_picker_model.swift`: a branch is not choosable; a seed with `opensCheckedBranches: false` opens
    only `startsOpen` branches; `toggled` with `accordion` closes the siblings; `toggled` without it keeps them;
    `widest` counts `detail`.
  - `tools/test_audio_menu_model.swift`: four branches in order; the details; the children's ids; the two notes
    inside their branches; `startsOpen` follows the notes; no outputs gives a note child; the old `action(forID:)`
    assertions still pass.
- **User's eye:** the four folded lines, opening and folding (one at a time), long device names truncated in the
  middle, and choosing a buffer then a rate without the popover closing.

## L4 — The computer keyboard is named after the layout (request 2)

**Commit:** `Feedback 2026-11-04, L4: the computer keyboard input is named after the keyboard layout (AZERTY, QWERTY…)`

- **Pure unit** `objekat/Shared/KeyboardLayoutName.swift`:
  - `enum KeyboardLayoutFamily: String { case azerty, qwerty, qwertz }`.
  - `static func family(topRow: String) -> KeyboardLayoutFamily?`. `topRow` is the lowercased characters of the
    physical keyCodes `[12, 13, 14, 15, 17, 16]` (the Q W E R T Y positions). It matches `"azerty"`, `"qwerty"` and
    `"qwertz"`, and anything else returns nil.
  - `var title: String` returns `"AZERTY"`, `"QWERTY"` or `"QWERTZ"`. These are proper names, not translated.
  - `static func displayName(family:localizedLayoutName:) -> String?`: the family's title, else the layout's
    localized name, else nil.
- **Platform half** `objekat/Shared/KeyboardLayoutWatcher.swift`, `@MainActor @Observable final class` with a `shared`
  singleton. It needs `import Carbon` (an Apple system framework, so the AGPL rule is unaffected).
  - Reading the layout:
    - `TISCopyCurrentKeyboardLayoutInputSource()`, falling back to
      `TISCopyCurrentASCIICapableKeyboardLayoutInputSource()` when `kTISPropertyUnicodeKeyLayoutData` is missing
      (input methods).
    - `UCKeyTranslate(layout, keyCode, kUCKeyActionDisplay, 0, UInt32(LMGetKbdType()), kUCKeyTranslateNoDeadKeysBit, …)`
      for each keyCode.
  - Published state:
    - `private(set) var name: String?`, built from `displayName` and `kTISPropertyLocalizedName`.
    - `private(set) var family: KeyboardLayoutFamily?`.
    - `func label(forKeyCode: UInt16) -> String`: the uppercased character, or `"?"`.
  - Refreshed at `init` and on `DistributedNotificationCenter.default()` for
    `kTISNotifySelectedKeyboardInputSourceChanged as String` (`queue: .main`, body under `MainActor.assumeIsolated`).
- `objekat/EditViewModel/EditViewModel+RecordMidi.swift:72` and `:185`: the name for `isComputerKeyboard` becomes
  `KeyboardLayoutWatcher.shared.name.map { L("midi.computer_keyboard.layout", $0) } ?? L("midi.computer_keyboard")`.
  `MidiInputInfo.displayName` already lives in a MainActor extension, since `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
  The internal name `Computer Keyboard` stays the contract.
- **Tooltips that name the real letters:**
  - `ComputerKeyboardRowControls` builds `keys` with `ComputerKeyboardMap.noteOffsets` sorted by offset, mapped
    through `label(forKeyCode:)`, lowercased and joined with `" "`.
  - It builds `down` / `up` from `octaveDownKeyCode` / `octaveUpKeyCode`.
- **API:** `midi.keyboard.status` (`computerKeyboardPayload`, `Commands+ComputerKeyboard.swift:121`) gains
  `layout_family` (string or null) and `layout_name` (string or null).
- **i18n:**
  - New: `midi.computer_keyboard.layout` — fr « Clavier %@ », en « %@ keyboard », es « Teclado %@ ».
  - Changed values, which gain a format:
    - `inputs.keyboard.toggle.help`: fr « Les touches jouent des notes sur cette entrée (%1$@ ; %2$@ / %3$@ : octave).
      Les raccourcis à lettre passent par ⇧ + lettre tant qu'il est allumé. », with en and es on the same pattern and
      the same `%1$@ %2$@ %3$@`.
    - `inputs.keyboard.octave.down.help`: « Octave plus bas (touche %@) ».
    - `inputs.keyboard.octave.up.help`: « Octave plus haut (touche %@) ».
  - `check` must show the same specifiers in all three languages.
- **Tests:**
  - `tools/test_keyboard_layout_name.swift`: the three families, a Dvorak row (`"',.pyf"`) returns nil, mixed case,
    and `displayName` falls back on the localized name.
  - `scenario_computer_keyboard.py`: assert that both new keys exist (string or null). Their value depends on the
    machine.
- **User's eye:** the name in the Inputs tab, the synoptic's Entrée menu and the zone names, in the three languages;
  switching the layout in the menu bar renames it live; the tooltips' letters on AZERTY and QWERTY.

## L5 — The input strips (request 5)

**Commit:** `Feedback 2026-11-04, L5: input strips in the Main's colour, a bigger number, the meter under the name, the keyboard button on the left`

Five changes in `objekat/Inputs/InputStrip.swift:20-102`, `InputRowStyle.swift`, `ComputerKeyboardRowControls.swift`,
`MidiInputsSection.swift:73-126`, `InputsPanelView.swift:227-275` and `Shared/FeatureBadgeViews.swift:34-53`.

1. **Colour of the Main.** Add `var mainStemColor: Color { stems.first?.color ?? ObjekatPalette.stem(0) }` to
   `EditViewModel`. `stems.first` is the Main (`mainStemID`, `EditViewModel.swift:437`). `InputStrip` takes
   `let tint: Color` and passes it to `.stripChrome(tint:…)` (l.59). Both callers pass `viewModel.mainStemColor`, and
   so does `InputStripPopup`'s header background (l.192). `DormantInputStrip` keeps `StripStyle.inputTint`: grey
   means absent.
2. **New layout.** Replace `body` (l.41-61) with:
   ```
   HStack(alignment: .center, spacing: InputRowStyle.controlSpacing) {
       leading().frame(width: InputRowStyle.leadingWidth, alignment: .center)
       VStack(alignment: .leading, spacing: InputRowStyle.lineSpacing) {
           NameWithFeatureBadges(badges:…, size: 9, color: .secondary, keepsBadges: true) { nameView }
           meter().frame(height: 5)
       }
       .frame(maxWidth: .infinity, alignment: .leading)
       listenButton            // 15 pt glyph, 24×24 frame
       gain()
   }
   ```
   - The meter now ENDS under the name, never under the speaker or gain. The speaker and gain are vertically centred
     on the strip's two lines.
   - `InputStrip` loses `glyph:` and `extra:` and gains `@ViewBuilder let leading: () -> Leading` (generic parameter
     `Leading: View`).
   - `InputStripGlyphView(glyph:)` is extracted from `glyphView` (l.63-75). The number uses
     `InputRowStyle.numberFont = .system(size: 13, weight: .semibold, design: .monospaced)` in `.secondary`. The keys
     glyph is 14 pt.
   - `InputRowStyle`: `leadingWidth = 56` replaces `numberWidth = 30`, and `meterLeading` goes away.
   - **Decision:** one width for every strip, so the names stay aligned. 56 pt holds the « 13-14 » key at 13 pt and
     the octave selector.
   - `listenButton` (l.90-101): font 15, frame 24×24.
   - `InputMonitorGainBox` is unchanged (`DragValueBox` width 44).
   - `DormantInputStrip` follows the same leading width.
3. **The FX badge stays.** `NameWithFeatureBadges` gains `var keepsBadges = false`. When true, the `ViewThatFits` is
   replaced by `HStack(spacing: spacing) { name().lineLimit(1).truncationMode(.tail); FeatureBadgeGlyphs(...).layoutPriority(1) }`:
   the name truncates and the badges stay whole. **Decision:** only the input strips pass `true`. The timeline blocks
   and the sound list (`SoundBlockView:453`, `GroupBlockView:308`, `InfiniteBusBandView:164`,
   `SoundObjectListView:583`) keep the "name first" rule, which suits their narrow blocks.
4. **Computer keyboard row.** `ComputerKeyboardRowControls` becomes a VERTICAL leading column, passed as `leading:`
   for `d.isComputerKeyboard` in `MidiInputsSection.row` (l.96 moves there). The other MIDI rows pass
   `InputStripGlyphView(.keys)`.
   - **Top:** a toggle that reads as a button. `Button { toggleComputerKeyboardMode() } label: { Image(systemName: "keyboard").font(.system(size: 15)).frame(width: 46, height: 22) }`,
     `.buttonStyle(.plain)`, with a background `RoundedRectangle(cornerRadius: 5).fill(on ? Color.accentColor : Color.secondary.opacity(0.18))`
     plus a 1 pt stroke `Color.secondary.opacity(0.5)`. The foreground is white when on and `.primary` when off.
     `.help(...)` as in L4.
   - **Below:** the octave selector `‹ C4 ›` (chevrons 8 pt, frame 12; name 9 pt monospaced, minWidth 22), within
     the 56 pt column.
   - The strip's own tap gesture must not fire from these buttons. SwiftUI buttons take the click, as today.
5. **Meter of a MIDI row:** the meter slot holds L11's `MidiActivityMeter`. Until L11 lands it keeps `VULevelBar`.

- **i18n:** none (L4's keys).
- **Tests:** `tools/test_object_feature_badges.swift` stays green. No layout logic is pure, so nothing else is
  asserted.
- **User's eye:** blue strips, which follow a change of the Main's colour; the meter stopping under the name; the
  bigger number, speaker and gain; the FX badge kept on a long name; the keyboard button on the left reading as a
  button, with its octave under it; the three languages.

## L6 — The notes of MIDI children inside a group's block (request 8)

**Commit:** `Feedback 2026-11-04, L6: a group's block draws its MIDI takes' notes`

- `objekat/Timeline/GroupWaveformView.swift`, `GroupWaveformDrawing`:
  - `expand` (l.82-131): the `.midiClip` case stops being skipped (l.109-110). It appends a
    `MidiInstance(clip: o, shift: shift, winLo: lo, winHi: hi)` to a second `inout [MidiInstance]`. Muted children
    stay skipped (l.97), the same rule as the audio composite: **only what is heard is drawn**.
  - `draw(...)` gains `secPerBeat: Double`.
  - After the audio instances, it draws the notes:
    - Compute ONE pitch range for the whole group over the notes of every `MidiInstance`, through a new pure
      `MidiNotesDrawing.layout(pitchRange: ClosedRange<Int>, size:) -> Layout`, which applies the same margins and
      `minSpan` as `layout(notes:…)`.
    - For each instance, call a new overload `MidiNotesDrawing.forEachNote(..., layout: Layout, _ emit:)`. The
      existing overload delegates to it.
    - Pass `xOffset = (clip.startTime - groupStartTime + shift) * pixelsPerSecond`,
      `loopRange: clip.loopMarkerLocalRange` and `visibleX` = the instance's window ∩ the visible window.
    - Fill with `stemColor` at `MidiNotesDrawing.opacity(velocity:muted: rootMuted)`; grey when `rootMuted`, as the
      waveform is.
  - Keep `maxInstances`, shared between both kinds.
- The three call sites gain `secPerBeat: 60.0 / viewModel.tempo`, the expression `TimelineView` already uses (l.2800):
  - `GroupBlockView.swift:170`, through a new stored `secPerBeat`;
  - `GroupBlocksCanvas.swift:356`;
  - `InfiniteBusBandView.swift:91`.
- **Tests:** `tools/test_midi_notes_drawing.swift` gains the overload with a given layout (the same rects as the old
  path on one clip) and `layout(pitchRange:)`.
- **User's eye:** a closed MIDI zone showing its audible take's notes; an open group; muted takes absent; a looped
  MIDI child; both regimes (fewer and more than 100 objects).

## L7 — Instruments dropped like FX in the signal view (request 4)

What "like the FX" means, from the code:
- An FX card can be dropped on timeline objects, on stem and input strips, AND on any place of the SIGNAL VIEW: on a
  card or a cable (`PluginDropDelegate`, `SynopticCardViews.swift:554-626`).
- An instrument card is already dragged to timeline objects and to MIDI input strips (`pluginDropOutcome`,
  `EditViewModel+PluginDrop.swift:189-205`, `transferInstrument`).
- The signal view's instrument SLOT takes no drop (`SynopticView.swift:812-853`: the empty slot is a bare `Button`,
  the filled card has no `onDropPlugin`). So an instrument cannot be moved from an input's popup onto the inspector's
  group, nor between two signal views.

**Decision:** the slot (empty or filled) becomes a drop target for instruments. The plugin browser (a modal sheet)
and the "+" directions stay without instruments, as they are for FX today. **To confirm.**

**Commit:** `Feedback 2026-11-04, L7: the instrument slot of the signal view takes a dropped instrument`

- `Inspector/Synoptic/SynopticActions.swift`, `struct SynopticActions`: add
  - `var instrumentSlotDropOutcome: ((_ flags: NSEvent.ModifierFlags) -> PluginDropOutcome?)? = nil`;
  - `var onInstrumentSlotDrop: ((_ payload: PluginDragPayload, _ flags: NSEvent.ModifierFlags) -> Void)? = nil`.
- `SynopticBoundView.swift`, in the actions block (near l.335):
  ```
  instrumentSlotDropOutcome: { flags in
      guard let p = PluginDragSession.shared.current else { return nil }
      guard viewModel.isInstrument(p.pluginID, of: p.sourceObjectID) else { return .refuse("the instrument slot takes an instrument") }
      return viewModel.pluginDropOutcome(p, toHost: objectID, at: .hostEnd, flags: flags)
  },
  onInstrumentSlotDrop: { p, flags in
      guard viewModel.isInstrument(p.pluginID, of: p.sourceObjectID) else { return }
      viewModel.acceptPluginDrop(p, on: objectID, modifiers: flags)   // mounts an input host if needed, one undo
  },
  ```
  The same view serves the inputs' popups (`InputStrip.swift:195`), so an object's instrument dropped on an input's
  slot (and the reverse) needs nothing more: `pluginDropOutcome` handles a MIDI input target (l.193-196).
- `SynopticView.swift:812-853`:
  - The filled card passes `dropOutcome: { actions.instrumentSlotDropOutcome?($0) ?? nil }` and
    `onDropPlugin: actions.onInstrumentSlotDrop`. `SynopticCardView` already lays its drop layer (l.220-230).
  - The empty-slot `Button` gets
    `.onDrop(of: [.plainText], delegate: PluginDropDelegate(isTargeted: $instrumentSlotTargeted, hintKey: "instrumentSlot", outcome: { actions.instrumentSlotDropOutcome?($0) ?? nil }, onDrop: { actions.onInstrumentSlotDrop?($0, $1) }))`.
  - `@State private var instrumentSlotTargeted = false`: when true, draw the dashed stroke in `Color.accentColor` at
    lineWidth 2.
  - When `instrumentSlotRefusal != nil` (the slot is closed), add no drop at all.
- An FX dragged onto the slot is refused (forbidden cursor). An instrument dragged onto the FX chain stays refused,
  as today.
- **i18n:** none. Refusal reasons are machine strings, and the hint band shows nothing for a refusal.
- **Tests:** in `tools/scenario_input_chains.py`, add a dry run with `plugin.drop_at` (`Commands+Plugins.swift:636`)
  of an input's instrument toward a MIDI group (`move`, and `copy` with option); then the drop; then `edit.undo`
  gives it back.
- **User's eye:** the slot lighting up; the cursor (move / ⌥ copy / forbidden for an FX); the drop between the
  inputs' popup and the inspector.

## L8 — Loop recording: one ⌘Z per pass, and MIDI takes that can be stretched (request 6)

Today, the whole loop recording is ONE undo point. `beginRecording` pushes it (`EditViewModel+Recording.swift:198`),
and `completeRecording` adds every take to it (l.368-384).

**What is wanted:** ⌘Z removes the LAST pass only. Its lane goes, and the previous pass becomes the top lane again,
audible again in "mute" mode: exactly the state "stopped after the previous pass". The next ⌘Z does the same with the
pass before. The FILE (or the MIDI sequence) is kept, so the remaining takes can still be trimmed into the rest.

This holds by construction:
- An audio take keeps `fileDuration = file.length` (l.325), hence `contentRoomAfter`.
- `midiSequences` is outside the undo (`EditViewModel.swift:1333`).

**Commit:** `Feedback 2026-11-04, L8: loop recording, one undo step per pass; no undo while recording; a stretched MIDI take shows its notes while dragging`

### a) Pure rules (`objekat/SoundObject/RecordLoopPlanner.swift`)

- `static func passSteps(passes: [Int], cap: Int = 16) -> [[Int]]`. It takes the sorted pass indices that gave at
  least one take (across every zone) and returns the steps. When there are more than `cap`, the earliest passes
  merge into the FIRST step, so that the 50-entry stack (`EditViewModel+UndoRedo.swift:48`) is not flushed.
- `static func prefixLayout(takeCount k: Int, baseLane: Int, mutesPrevious: Bool) -> [(lane: Int, audible: Bool)]`.
  For n in `0..<k`: `lane = baseLane + (k-1-n)`, `audible = !mutesPrevious || n == k-1`. These are `plan()`'s rules
  (l.168-175) applied to a prefix.
- Tests in `tools/test_record_loop_planner.swift`:
  - steps of 1, 3 and 20 passes;
  - the cap;
  - `prefixLayout(k)` equals the lanes and audibility of `plan()` on the first k crossing segments, for both modes.

### b) `completeRecording` (`EditViewModel+Recording.swift:281-394`)

Restructure without changing any single-pass result.

1. Phase 1 computes `madeTakes` for each zone exactly as today (l.304-363), but applies nothing.
2. When EVERY zone has at most one take, or one has `outsideWindow`, run phase 2 = the current code (l.364-384),
   unchanged.
3. Otherwise, phase 2 runs by steps:
   ```
   steps = RecordLoopPlanner.passSteps(passes: sorted union of m.take.pass)
   for (si, step) in steps.enumerated():
       if si == 0 { if !pushed { pushUndo(); pushed = true } } else { pushUndo() }   // the state of step si-1 becomes a ⌘Z point
       let cutoff = step.max()!
       for each zone z:
           present = z.madeTakes.filter { $0.take.pass <= cutoff }        // oldest first
           guard !present.isEmpty else { continue }
           if si == 0 || first time z has a take: setMuted(z.muteIDs minus early, true); setMuted(z.unmuteIDs, false);
               register z.newSequence once
           layout = prefixLayout(takeCount: present.count, baseLane: z.baseLane, mutesPrevious: z.mode.mutesPrevious)
           existing children: lane = originalLane + present.count   (updateMany on the delta since the previous step)
           takes already added: update lane / isMuted to layout (updateMany for lanes; setMuted for audibility changes → pushMix)
           takes of this step: set lane / isMuted on the object, then addChild (oldest first)
   ```
   - `z.baseLane = RecordTakePlanner.takeLane(children: kids)`, read BEFORE any change.
   - Track each zone's applied shift to compute the deltas. Never re-read lanes from the model between steps for the
     planner.
4. The reports (`lastRecordingTakes`) are those of the final state, as today.
5. `pushUndo` captures the live plugin states at each step (`currentSnapshot`, l.99). The cost is accepted:
   ≤ 16 steps, once, at the stop.

### c) No ⌘Z while recording

The recording's bookkeeping (`recordingMuteLog.undoDepthAfterPush`) assumes the stack is not moved under it.

- In `performUndoShortcut` (`EditViewModel+EditMenu.swift:29`), add `guard !isRecording else { NSSound.beep(); return }`.
- `edit.undo` and `edit.redo` (`Commands+Core.swift:1030-1046`) throw `invalid_state` "recording" while recording.

### d) A stretched MIDI take shows its notes

- The model already reveals notes (`resolveMidiSequenceWindow`, `EditViewModel+Edit.swift:178`), and
  `tools/scenario_record_loop_midi.py:170-190` asserts it through `object.trim`.
- During the DRAG, the block still draws its old notes. They appear only on release *(inferred from
  `SoundBlockView.swift:177` and `TimelineView.swift:3563`, which draw `object.midiNotes`; to confirm on screen)*.
- Add a read with no side effect:
  `func previewMidiWindowNotes(of obj: SoundObject, startShiftSeconds: Double, duration: Double) -> [MidiNote]?`.
  It returns `MidiSequenceWindow.resolved(...)?.notes` with `shiftedByBeats: beatsFromSeconds(startShiftSeconds)`,
  and nil when the clip is not a live take.
- The two drawing sites pass it instead of `object.midiNotes` while a trim or resize preview is active on that id
  (`previewTrimDX` / `previewResizeDX`).
- In the sequence branch of `resolveMidiSequenceWindow` (l.188), set `lengthBeats = max(1.0, beatsFromSeconds(obj.duration))`.
  This is the creation rule (`EditViewModel+RecordMidi.swift:164`); today a right-hand stretch leaves the old
  `lengthBeats`. Check first whether `syncMidiNotes` bounds the engine's MidiList by `lengthBeats` *(inferred)*.

### e) Test

New `tools/scenario_record_loop_undo.py`, with `--virtual-audio` and `--virtual-midi`:
1. A zone on a loop of 1 s, recorded for 3.5 s, gives 4 takes.
2. `edit.undo` leaves 3 takes: the top lane is pass 2, audible in mute mode, and the lanes are contiguous. Another
   `edit.undo` leaves 2. `edit.redo` brings 3 back.
3. `object.trim` on the remaining top take beyond the window is accepted (room) for audio, and for MIDI the notes
   count grows.
4. `edit.undo` during `rec.start` answers `invalid_state`.
5. The same scenario in "add" mode.
6. A single-pass recording keeps ONE undo, already covered by `scenario_record.py`, which stays green.

- **User's eye:** ⌘Z after a loop recording, pass by pass; the MIDI notes appearing under the hand while stretching.

## L9 — During the recording, everything moves down one lane (request 9, without engine)

**Decision:**
- The shift is REAL, in the model. It happens inside the undo point that `beginRecording` already pushes before its
  first change (l.198). A ⌘Z after the stop undoes it with the rest, and a recording with no take gives it back.
- A display-only offset would mean a transient lane per zone inside `buildLaneEntries` and `childLaneCount`, read in
  64 places.
- Through a loop, each finished pass that crossed the window pushes the existing takes down ONE more lane, and leaves
  a "ghost" of that pass in the lane just below the current one. This is the final layout, built as it grows.

**Commit:** `Feedback 2026-11-04, L9: recording opens an empty lane on top of the zone; each finished pass of a loop leaves its ghost`

1. `RecordingMuteLog` gains `var laneShiftByZone: [UUID: Int] = [:]`.
2. `beginRecording` (l.185-201): for each zone with children whose window the press can reach, run
   `updateMany(Set(children ids)) { $0.lane += 1 }` and set `laneShiftByZone[id] = 1`. "Can reach" is
   `RecordLoopPlanner.reachableRange(startPosition:loop:)` overlapping the window. Push the undo point before it,
   shared with the mutes (`if log.undoDepthAfterPush == nil { pushUndo(); … }`). No engine call is needed: lanes
   inside a group are model-only, like `completeRecording:374`.
3. `giveBackMutes` (l.246) and both "no take" branches of `completeRecording` (l.301, l.365) give the shift back
   (`lane -= shift`).
4. `completeRecording`:
   - The planner reads the children with `lane - shift` for that zone. Add an optional `laneShift: Int = 0`
     parameter to `takePlannerChildren`.
   - The shift applied (L8's single and step paths) becomes `down - shift`. Through a loop, `shift` already holds
     `1 + finished crossing passes`.
5. **Laps:** a 10 Hz `Timer` (`@ObservationIgnored var recordingTimer`, started at the end of `beginRecording` and
   invalidated in `completeRecording`) calls `recordingTick()`. That function reads `engine.recordPassNow()`
   (`OBJEngineCore.h`, `laps`, `start`). When `laps` grows, for each zone the finished pass crossed
   (`RecordProgress.span` non-nil on [previous start, loop end]):
   - `updateMany(children) { lane += 1 }`;
   - `laneShiftByZone += 1`;
   - append the finished span to `@ObservationIgnored var recordingDoneSpans: [UUID: [RecordProgress.Span]]`.

   L10 also uses this tick.
6. `recordProgressBlocks(head:)` (l.259-274):
   - The current block's lane is `RecordProgress.displayLane(... takeLane: takeLane(children with lane - shift))`.
     The top lane is now empty.
   - It adds one ghost per done span, at lane `top + (L - i)`.
   - `RecordProgressBlock` gains `current: Bool`.
   - **Decision:** a ghost is drawn only when its lane is among the rows the open zone reserves
     (`< e.item.childLaneCount`). An EMPTY zone (no previous take) therefore shows the current pass only.
7. `RecordingProgressOverlay` (`Timeline/RecordZoneOverlays.swift:65-88`): the current block is unchanged
   (red 0.30 / stroke 0.75). Ghosts use red 0.15, stroke 0.40, dashed `[3, 2]`.
8. `rec.status.progress[]` gains `current` (bool) and `pass` (int). Document it in `command_api.md`.

- **Tests:**
  - `tools/test_record_progress.swift`: the lane with a shift, the ghosts, the clamp on reserved rows.
  - `scenario_record.py` (a new section): during `rec.start`, `object.get` of the previous take reads lane +1; after
    `rec.stop` the lanes equal today's; a recording that gives nothing gives the lanes back; one `edit.undo` puts
    everything back.
  - `scenario_record_loop_proof.py`: the lanes after 3 laps equal the final layout.
- **User's eye:** the empty top lane in red at the press; the ghosts going down at each lap; nothing jumping at the
  stop.

## L10 — The meter of a MIDI input: blue activity, the instrument's output (request 7) — touches `OBJEngineCore.mm`

**Decision:** this is the meter of the MIDI rows of the Inputs tab (the only MIDI meter in the app). The zone's red
block is L11.

**Commit:** `Feedback 2026-11-04, L10: a MIDI input's meter, blue for the notes, the instrument's output when it has one`

- **Swift, new `objekat/Shared/MidiActivityMeter.swift`.** It holds a view
  `MidiActivityMeter(activity: Bool, level: Double?)`. `Color.accentColor` is the keyboard icon's blue
  (`ComputerKeyboardRowControls.swift:23`).
  - With `level == nil` (no instrument): the pale capsule track, plus a `Capsule().fill(Color.accentColor)` 6 pt
    wide, 3 pt tall, at the LEFT while `activity` is true. It is a few pixels, never a full bar.
  - With an instrument: a `VStack(spacing: 1)` holding the 2 pt tall blue mark above (6 pt wide, at the left, while
    `activity`), then `VULevelBar(level:, height: 3)`.
- **`MidiInputsSection.tick`** (l.142-156):
  - `activity[d.id] = 4` (ticks of 0.07 s, about 280 ms) when `seen[d.id] > 0`. Decrement otherwise.
  - `level[d.id]`: when the row has an instrument and is heard, read
    `viewModel.pluginAudioLevel(objectID: host, pluginID: instrumentID)` (`EditViewModel+Plugins.swift:854`),
    smoothed by `VUBallistics`. Otherwise nil.
  - On appear, register with `viewModel.setMeteredPlugins(owner: "inputs.midi", objectID: host, ids: [instrument ids of every listed device])`.
    Withdraw on disappear with `ids: []`. One owner suffices if the engine keys on the plugin id. Otherwise use one
    owner per host (`"inputs.midi.\(d.id)"`).
- **Engine (`OBJEngineCore.mm:10785-10813`, `audioLevelForPluginKey:forObjectID:`):** line 10808 reads 0 when the
  transport is stopped. A live input is heard while stopped. Skip the `isCurrentlyPlaying` condition when the key's
  owner host (`_pluginOwnerHost`, l.2297) is an input host (`_midiInputTracks.count(host) || _audioInputHosts.count(host)`,
  l.2130-2131). *(Inferred: the hidden input track's graph runs while the transport is stopped, since monitoring is
  heard then. The scenario below proves or disproves it.)*
- **API:** `input.levels.midi_activity` (`Commands+RecordMidi.swift:29`) gains, per device, `instrument_level`
  (0…1 or null).
- **Test** (`scenario_input_chains.py` or `scenario_computer_keyboard.py`), with `--virtual-midi` and DLSMusicDevice
  (as `scenario_computer_keyboard.py:263`), transport STOPPED:
  1. Monitor on, send notes (`midi.virtual.send`), poll: `instrument_level > 0`.
  2. Monitor off: `instrument_level` is 0 or null.
  3. The transport-playing behaviour of the synoptic cards is unchanged: `scenario_plugin_expert.py` and the
     synoptic VU checks stay green.
- **User's eye:** the blue pixels with no instrument; the VU of the instrument with the blue mark above it; while
  stopped and while playing.

## L11 — The take being recorded draws its notes and its waveform (request 9, live data) — touches `OBJEngineCore.mm`

**Commit:** `Feedback 2026-11-04, L11: live notes and live waveform in the take being recorded`

### Engine

1. **MIDI events.** `OBJMidiActivity` (`OBJEngineCore.mm:1550-1563`) gains:
   - a fixed ring `std::array<OBJLiveMidiEvent, 1024>` with `{uint8 pitch, uint8 velocity, bool on, double ms}`;
   - `std::atomic<bool> capturing{false}`;
   - a `juce::SpinLock lock`.

   `handleNoteOn` / `handleNoteOff` push when `capturing`, under `juce::SpinLock::ScopedTryLockType`. If the lock is
   busy or the ring is full, the event is DROPPED: the producer never blocks. The listener runs on the thread that
   delivered the message (the CoreMIDI thread, the main thread for the computer keyboard, possibly several threads
   for "All MIDI Ins") *(inferred from `handleIncomingMidiMessage`, l.12923-12945)*. `ms = juce::Time::getMillisecondCounterHiRes()`.
2. **Audio peaks.** `OBJInputMeter` (l.1428-1459) gains `std::array<std::atomic<float>, kMax> recPeak`, updated in the
   same callback as `peak` (relaxed max). This is a SEPARATE accumulator, so reading it never steals the meters'
   peaks (`audioInputPeaksDb` does `exchange(0)`, l.11989).
3. **Header (`OBJEngineCore.h`, near `recordPassNow`):**
   - `- (NSDictionary<NSString*, NSArray<NSDictionary<NSString*, NSNumber*>*>*>* _Nonnull)drainLiveRecordMidi;`. Per
     device id, the events since the last drain: `{pitch, velocity, on, age_ms}`, where
     `age_ms = now - ms` at the drain. It reads under the lock on the main thread.
   - `- (NSArray<NSNumber*>* _Nonnull)audioInputRecordPeaksDb;`. Per device channel, the peak since the last call
     (exchange 0), in dB with a floor of -120.
   - `capturing` is set true in `startRecordingInputs:` for the MIDI devices it records, and false at the finish.

### Swift

- New `objekat/Shared/RecordLiveCapture.swift`, PURE. It defines:
  - `struct LiveNote { pitch, velocity, start: Double, end: Double? }`;
  - `struct RecordLiveCapture` with `notes: [LiveNote]` and `peaks: [(time: Double, db: Float)]`;
  - `mutating func ingest(events: [(pitch, velocity, on, ageSeconds)], head: Double)`: time = head - age; a note-off
    closes the last open note of that pitch;
  - `mutating func ingest(peakDb: Float, head: Double)`;
  - `mutating func newPass()`: moves the current capture into `done` (L9's ghosts) and starts empty;
  - caps of 20 000 notes and 60 000 peak points (the oldest are dropped).
- `EditViewModel.recordingTick()` (L9's timer, raised to 30 Hz):
  - drain both;
  - feed `@ObservationIgnored var recordingLive: [UUID: RecordLiveCapture]`, one per zone (the device or channels of
    `zone.source`; a stereo zone takes the max of its two channels);
  - at a lap, call `newPass()`;
  - bump `var recordingLiveRevision = 0` (observable; only the overlay reads it).
- `RecordingProgressOverlay` reads `viewModel.recordingLiveRevision`. Inside each block (current and ghosts) it draws
  one `Canvas`:
  - **Audio:** a symmetric envelope (`10^(db/20) · blockHeight/2` around the middle), filled `RecordZoneIcon.red`
    at 0.85, clipped to [block.start, block.end].
  - **MIDI:** the notes through `MidiNotesDrawing` with `layout(pitchRange:)` (L6) over the capture's pitches,
    filled red at 0.9. An open note runs to the head.
  - This is the "simplified representation" the user allowed: peaks at UI rate, not the file's waveform.
- `rec.status.progress[]` gains `live_notes` (count) and `live_peaks` (count).
- **Tests:**
  - `tools/test_record_live_capture.swift`: note on/off pairing, the timing from ages, a pass reset, the caps.
  - `scenario_record_loop_midi.py` and `scenario_record.py`: during `rec.start`, `live_notes` > 0 after
    `midi.virtual.send`, and `live_peaks` grows with the virtual card's signal; after `rec.stop` the files and takes
    are identical to the previous run (byte-identical WAV with the same input). This proves the tap does not touch
    the recording.
  - The calibration sections of `scenario_record.py` (F, F2, R) stay at an error of 0 samples.
- **User's eye:** the notes and the waveform growing in red; the ghosts keeping theirs; no stutter of the timeline
  while recording.

## L12 — Documentation

**Commit:** `Feedback 2026-11-04, L12: docs (command API, decisions, continuity memo)`

- `OBJEKAT - claude project/docs/command_api.md`: `rec.disarm_all`, `midi.keyboard.status.layout_*`,
  `input.levels.midi_activity.instrument_level`, `rec.status.progress[].current|pass|live_*`, and `edit.undo` refused
  while recording.
- `architecture_decisions.md`: the tree picker's branches, the real lane shift at the press, one undo per pass.
- `CLAUDE.md`: one entry listing what has not been seen or heard.

---

## Summary

| Lot | Title | Risk | `OBJEngineCore` |
|---|---|---|---|
| L1 | No keyboard button in the transport bar | trivial | no |
| L2 | Esc disarms every zone (+ `rec.disarm_all`) | low | no |
| L3 | The audio menu as a tree (branches in `TreePickerPopover`) | low | no |
| L4 | The keyboard named AZERTY / QWERTY / … (Carbon TIS) | low | no |
| L5 | Input strips: Main colour, layout, badge, number, keyboard button | low (UI only) | no |
| L6 | MIDI notes inside group blocks | medium (drawing in both regimes) | no |
| L7 | Instruments dropped on the signal view's slot | medium | no |
| L8 | One ⌘Z per loop pass, no undo while recording, MIDI stretch preview | medium-high (undo) | no |
| L9 | Recording opens an empty top lane; ghosts of the passes | high (model during a take) | no |
| L10 | MIDI meter: blue activity + instrument output | medium | yes (one condition) |
| L11 | Live notes and live waveform in the red block | high (cross-thread data) | yes |
| L12 | Docs | — | no |

Order of dependencies:
- L5 before L10 (L10 fills the meter slot L5 makes).
- L6 before L11 (L11 uses `layout(pitchRange:)`).
- L8 before L9 (L9 adjusts L8's shift arithmetic).
- L9 before L11 (the tick and the ghosts).

**Decisions for the user to confirm:**

1. **L3:** branches open INLINE, one at a time (an accordion), never cascading flyouts. They start folded, each
   showing its current value.
2. **L2:** Esc disarms even during a recording. The take in progress is unaffected.
3. **L5:** one leading column of 56 pt for every strip, so the names stay aligned. The "badges never drop" rule
   applies to the input strips only, not to the timeline blocks.
4. **L7:** "like the FX" is read as "the instrument slot of the signal view takes drops". No drag from the plugin
   browser and no instrument on the "+" directions, as for FX today.
5. **L8:** passes beyond 16 merge into the first ⌘Z step (stack of 50). ⌘Z and redo are refused while recording.
6. **L9:** the lane shift is a REAL model change inside the recording's undo point, not a display offset. In an empty
   zone, the ghosts of previous laps are not shown.
7. **L10:** the meter changed is the one on the MIDI rows of the Inputs tab. "Instrument output" means the
   instrument plugin's own output, before its FX and the listening gain.
8. **L11:** the live waveform is a peak envelope at UI rate (a simplified representation), not the file's waveform.

---

## Z. The user's requests (verbatim, French)

1. Enlever icone clavier dans la barre de titre
2. Renommer « clavier ordinateur » en clavier azerty ou qwerty ou autre selon le clavier utilisé par l'utilisateur
3. Menu comme avant avec « sous-menu » sinon, problématique si beaucoup d'entrées — clarified: « Menu audio vers un
   proposer arborescent, utiliser le menu du sidechain mais ajouter l'arborescence »
4. Pouvoir drag n drop instruments midi comme les fxs
5. Visuel inputs : passe en bleu comme le main au lieu du gris ; Vu-metre ne va pas jusqu'au bout, il s'arrête sous le
   nom (pas sous l'icône monitor et gain, du coup ces icônes peuvent etre un peu plus grandes) ; Le badge fx ne doit
   pas disparaitre si le nom est trop long ; Le numéro de l'entrée à gauche doit etre plus grand ; Le bouton clavier
   ordi doit etre à gauche, à la place de l'icone midi, plus grand, et plus compréhensible que c'est un bouton, le
   sélecteur d'octave passe en dessous de cette icone, donc à gauche, enfin, même remarque sur le vu metre
6. Record loop : Un cmd z annule uniquement la dernière prise (et la précédente), du coup on peut revenir en arrière,
   mais on peut toujours « trim » la prise pour aller piocher dans la suite, car elle fait partie du même fichier,
   c'est juste la lane qui est enlevée ; Pour le midi, il faut pouvoir « étirer » une lane pour montrer la suite (qui
   est dans la lane du dessus)
7. Record : Si midi uniquement, le vu metre doit etre quelques pixels de bleu (le même que l'icône clavier), et pas
   une barre entièrement remplie, si il y a un instrument, le vu metre représente la sortie de l'instrument, et le
   bleu en + (au dessus) pour représenter le midi
8. Si le groupe est midi, représenter les notes comme sur un clip midi, les reprises
9. Pendant le record : Tout se décale d'une lane, pour représenter le rec en rouge dans la lane vide (lane enlevée si
   cmd z) ; On représente le midi en rouge un peu transparent (type le rectangle actuel, mais avec les notes en +) ;
   On représente le rec audio en rouge un peu transparent (type le rectangle actuel, mais avec la waveform en +),
   possibilité d'avoir une représentation simplifiée si méthode actuelle non applicable ou complexe
10. Echap —> tous les groupes passent en « non armés »

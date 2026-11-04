# Review of `claude/retours-2026-11-04` (L1–L12) against `plan_retours_2026-11-04.md`

The range is `18ae1ca..59fb022`, 62 files. It was read as a compiler would read it. **Nothing was compiled or run**:
this machine has no Swift toolchain.

What was run here:
- `python3 -m py_compile` on the 8 scenarios that changed: all pass.
- `tools/i18n/xcstrings.py check`: it reports only the empty key `""` under en and es. That key exists at the base
  too, so it is noise from an IDE extraction.
- `orphans`: it lists `plugins.section.external`, `preset.menu.factory` and `preset.menu.setDefault`. This branch did
  not touch them. `transport.keyboard.help` is gone, as planned.

Severities:
- **C** = certain compile error.
- **L** = likely compile error / build risk.
- **B** = logic bug against the spec.
- **R** = robustness or threading.
- **N** = note.

## Compile errors

**C: none found.** Every call site I checked matches its declaration:
- memberwise inits, in field order: `TreePickerNode.branch`, `TreePickerPopover`, `InputStrip`, `GroupBlockView`,
  `InfiniteBusBandView`, `GroupWaveformView`, `SoundBlockView.previewMidiNotes`, `RecordProgressBlock`,
  `PluginDropDelegate`, `SynopticCardView`;
- every caller of `GroupWaveformDrawing.draw` and `drawComposites` (3 sites) passes `secPerBeat`;
- the exhaustive `switch`es over `TreePickerNode.Role` and `SoundObject.Kind`;
- `ForEach(blocks)`: `RecordProgressBlock` is `Identifiable`;
- the `private struct`s `MadeTake` and `ZoneTakes` are file-scoped and only used by private or internal members of
  the same file.

The Carbon calls in `Shared/KeyboardLayoutWatcher.swift` match the SDK signatures:
- `TISCopyCurrent…InputSource()` returns `Unmanaged<TISInputSource>!`, consumed by `takeRetainedValue`;
- `TISGetInputSourceProperty` returns a raw pointer, read through `Unmanaged<CFString/CFData>.fromOpaque`;
- `UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeys, buffer.count, &length, &buffer)`;
- `kTISNotifySelectedKeyboardInputSourceChanged as String`.

`@Observable` with only `AppKit` and `Carbon` imported compiles: `Shared/AudioDeviceStatus.swift` and
`App/Workspace.swift` already do the same.

The `OBJEngineCore.h` and `.mm` declarations match:
- `audioInputRecordPeaksDb` and `drainLiveRecordMidi` carry `_Nonnull` in the header;
- the C++ aggregate init of `OBJLiveMidiEvent` with default member initialisers is valid C++14 and later;
- `juce::SpinLock::ScopedTryLockType::isLocked()` is const.

| # | Sev | Where | Finding | Fix |
|---|---|---|---|---|
| 1 | L (low) | `Inputs/MidiInputsSection.swift`, the `meter:` closure, `instrumentLevels[d.id].map(Double.init)` | `Double.init` has many overloads. With a `Float` argument the type checker normally picks `init(_: Float)`. It is the one expression in the diff where overload resolution can fail. | If the build complains: `.map { Double($0) }`. |

## Logic, against the spec

| # | Sev | Where | Finding | Fix |
|---|---|---|---|---|
| 2 | B (medium) | `EditViewModel+Recording.swift:216-220` (press) and `:255-272` (`retakeRecordingMutes`) | The press shifts the lanes only for zones the head can reach AT THE PRESS. When a loop edit later brings the head into a zone, `retakeRecordingMutes` mutes but does not shift. The red block then overlaps the top take again (the old behaviour), and no ghost appears, because the tick requires `laneShiftByZone[zone] != nil` (l.373). | In `retakeRecordingMutes`, for each zone with children and no `laneShiftByZone` entry whose window is now reachable: `shiftChildLanes(of:by: 1)` and `laneShiftByZone[zone] = 1`, inside the same undo point (create it if absent, as the function already does). `completeRecording` handles the difference. |
| 3 | B (low) | `EditViewModel+RecordMidi.swift`, `midiInstrumentLevel(of:heard:)` | It returns nil when the input has an instrument but is not heard. The row then shows the "no instrument" look (blue pixels only). Spec L10 says "with an instrument: the VU of its output + the blue mark". | Return `0` (not nil) when an instrument exists but is not heard. Keep nil for "no instrument". The API's `instrument_level` doc ("null while not heard") changes with it: say `0`. |
| 4 | N | `completeRecording`, the `byPasses` condition (l.575) | When one zone has an out-of-window take, EVERY zone falls back to a single undo point, including zones that looped. This matches the spec ("one has `outsideWindow` → single step"). It is noted because it is visible to the hand. | None, or document it in `command_api.md`. |
| 5 | N (pre-existing, amplified) | `completeRecording`, `pushed` (l.487) | Undo is refused while recording, but a gesture is not (a move, a mute). Each pushes its own point above the start's. `pushed` stays true, so the takes are added without a point of their own, and one ⌘Z after the stop undoes the takes AND that gesture. L9 makes this likelier, because the model is now shifted during the take. | Out of scope. If wanted: when `undoStack.count > log.undoDepthAfterPush`, push a fresh point before laying the takes. |
| 6 | N | `Timeline/MidiNotesDrawing.swift`, `forEachNote(layout:)` | The `f.plays(base:)` guard was removed and the repeat range now starts at `kFirst`. For a clip's own block nothing should change (`put` still clips to `[0, width)`), but this is the shared drawing of every MIDI block. | Run `tools/test_midi_notes_drawing.swift` before trusting it. Watch a looped MIDI clip trimmed on the left. |
| 7 | N | `EditViewModel+RecordMidi.swift:207-212` | The computer keyboard's `displayName` now reads the layout ("Clavier AZERTY"), and `input.list.midi_inputs` returns it. The API was already localised there (`midi.computer_keyboard`, pre-existing), which goes against the "the API stays English" rule. | Optional: have the API return `name` (the internal `Computer Keyboard`) and expose `display_name` beside it. |

## Threading and audio-thread safety (L10, L11, `OBJEngineCore.mm`)

The core is sound:
- `OBJMidiActivity::push` takes the lock with a TRY-lock only, drops the event when the lock is busy or the ring is
  full, and allocates nothing. It is safe even if `MidiKeyboardState` calls it from the audio thread *(inferred)*.
- `recPeak` is a separate `std::atomic<float>` array, written with the same relaxed max as `peak`. Reading it never
  touches the meters.
- `setCapturing`, `drain` and `drainLiveRecordMidi` run on the main thread.
- The `audioLevelForPluginKey:` change reads only `std::map::count` on the main thread.

| # | Sev | Where | Finding | Fix |
|---|---|---|---|---|
| 8 | R (low) | `OBJMidiActivity::drain`, `out.assign(...)` under `ScopedLockType` | The vector may reallocate while the lock is held. A MIDI producer that tries the lock meanwhile drops its event. It never blocks, so this is not a safety problem, but it is a needless loss. | `events.reserve(OBJMidiActivity::kLiveRing)` once, before the loop in `drainLiveRecordMidi`. Or copy `ringCount` and swap into a pre-reserved buffer. |
| 9 | R (low) | `midiDevicesChanged` (`OBJEngineCore.mm`, `_midiActivity[id] = make_unique…` when the device pointer changes) | A device list change during a recording replaces that device's `OBJMidiActivity` with a fresh one whose `capturing` is false. The live notes of that zone stop until the stop. The recording itself is unaffected. | Keep `std::set<std::string> _liveCaptureDevices` (filled in `startRecordingInputs:`, cleared in `finishRecording`), and `setCapturing(true)` on a re-created listener whose id is in it. |
| 10 | R (low) | `Shared/KeyboardLayoutWatcher.swift:65,68` | `TISCopyCurrentKeyboardLayoutInputSource()` and `TISCopyCurrentASCIICapableKeyboardLayoutInputSource()` return an implicitly unwrapped Optional. A nil (no input source: some login or sandbox situations, theoretically headless) would crash on `.takeRetainedValue()`. | `guard let s = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return (nil, [:]) }`, and the same for the ASCII fallback. |
| 11 | N | `audioLevelForPluginKey:` (`OBJEngineCore.mm`, after l.10861) | The transport bypass relies on `uuid` being the input host's id. That holds because `pluginAudioLevel` passes `engineHostKey(hostID)`, which returns the host itself for an input host (`EditViewModel+SendChain.swift:45`). Still *(inferred)*: whether the hidden track's graph meters the instrument while the transport is stopped. The L10 scenario must show `instrument_level > 0` while stopped. | None. Run the scenario. |

## Checked and matching the spec

- **L1:** the button is removed and the key deleted.
- **L2:** the door, the bare-Esc branch only, `rec.disarm_all`, the cheat sheet row and its key in 3 languages.
- **L3:** the branch role, `detail`, `startsOpen`, the seed flag, the pure `toggled`, the width with the detail, the
  accordion. The four branches are in order and the click ids are unchanged. Headers still show their children.
- **L4:** the pure family plus the watcher; the help formats have the same `%1$@ %2$@ %3$@` / `%@` in fr, en and es;
  the two API fields exist.
- **L5:**
  - Main colour on the strips and the popup header; dormant strips stay grey.
  - One 56 pt leading column, the 13 pt number, the meter under the name only, speaker and gain at 24 pt.
  - The `keepsBadges` rule is used by the input strips only.
  - The keyboard toggle sits left, with the octave selector under it.
- **L6:** muted children are skipped, one pitch range for the group, the attack must fall inside the window, the body
  is cut at the window's end, and all 3 call sites are updated.
- **L7:** both slot faces, an FX is refused, the drop goes through `acceptPluginDrop` (one undo, an input host
  mounted), a closed slot takes nothing.
- **L8:**
  - `passSteps` with a cap of 16 and `prefixLayout`, which equals `plan()` on the full count.
  - The deltas are computed without re-reading the lanes.
  - The mutes are applied once, on a zone's first step.
  - ⌘Z, `edit.undo` and `edit.redo` are refused while recording.
  - `previewMidiWindowNotes` is a pure read and is wired in both regimes; the `lengthBeats` rule was fixed.
- **L9:**
  - The press shift sits in the start's undo point and is given back on failure or when there is no take.
  - The planner reads the lanes with the shift taken off; at the stop the children move by `down - shift`.
  - Ghost lanes are `top + L - i`, clamped to the reserved rows.
- **L11:**
  - The capture is split around a lap.
  - Ghost captures are kept only when a ghost is drawn, so the index of `done` matches the ghost's `pass`.
  - A binary search finds the visible peaks, and the caps hold.

## What I could not check

- Whether it builds: needs `xcodebuild`, against the 1550-warning baseline.
- The new and changed standalone Swift tests (`test_tree_picker_model`, `test_audio_menu_model`,
  `test_keyboard_layout_name`, `test_midi_notes_drawing`, `test_record_loop_planner`, `test_record_progress`,
  `test_record_live_capture`) and every scenario.
- Everything on screen and by ear that the plan lists.

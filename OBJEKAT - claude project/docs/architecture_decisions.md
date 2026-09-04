# OBJEKAT — architecture decisions

*A living document. Updated at every phase.*

---

## Phase 0 — Toolchain & the audio bridge (May 2026)

### Integrating the Tracktion Engine

**Decision: JUCE modules compiled by hand in Xcode, with no CMake.**

Tracktion Engine 3.2.0 is vendored into `tracktion_engine/`. JUCE (commit `19edd538`, required by Tracktion 3.2.0 — master is incompatible) is in `tracktion_engine/modules/juce/`.

Rather than going through CMake (which would have generated a parallel Xcode project, hard to maintain), each JUCE/Tracktion module is compiled as an independent translation unit inside a `JUCEModules/` folder of the Xcode target.

**Why:** JUCE forbids unity builds (each module must be its own TU). CMake would have added a layer of complexity to a project that does not need one at this stage.

**The key configuration entries in `objekat.xcodeproj/project.pbxproj`:**

- `CLANG_ENABLE_OBJC_ARC = NO` — JUCE uses MRC (manual retain/release), ARC is incompatible
- `ENABLE_APP_SANDBOX = NO` — required for access to local audio files
- `GCC_PREPROCESSOR_DEFINITIONS`: `JUCE_GLOBAL_MODULE_SETTINGS_INCLUDED=1`, `JUCE_STANDALONE_APPLICATION=1`
- `HEADER_SEARCH_PATHS`: `$(SRCROOT)/../tracktion_engine/modules` and `.../juce/modules`
- `OTHER_LDFLAGS`: CoreAudio, AudioToolbox, CoreMIDI, AVFoundation, Accelerate, CoreServices, IOKit, AppKit, QuartzCore, CoreGraphics, CoreFoundation, Foundation, CoreAudioKit, WebKit

**The modules compiled in `JUCEModules/`:**

JUCE (13 .mm): `juce_core`, `juce_events`, `juce_data_structures`, `juce_graphics`, `juce_gui_basics`, `juce_gui_extra`, `juce_audio_basics`, `juce_audio_formats`, `juce_audio_devices`, `juce_audio_processors`, `juce_audio_utils`, `juce_dsp`, `juce_osc`

JUCE extras: `juce_core_compilationtime_impl.mm` (the `juce_compilationDate` symbol), `juce_graphics_harfbuzz_impl.mm`, `juce_graphics_sheenbidi_impl.c` (**.c** is mandatory — SheenBidi must be compiled as pure C, not C++)

Tracktion (11 .mm): `tracktion_graph`, `tracktion_engine_utils`, `tracktion_engine_audio_files`, `tracktion_engine_model_1`, `tracktion_engine_model_2`, `tracktion_engine_playback`, `tracktion_engine_plugins`, `tracktion_engine_timestretch`, `tracktion_engine_airwindows_1/2/3`

---

### The Swift ↔ Tracktion bridge

**Decision: an Objective-C++ wrapper (`OBJEngineCore.mm`) + a bridging header. Zero JUCE/Tracktion type visible in Swift.**

```
Swift (ContentView) → OBJEngineCore (an ObjC interface) → OBJEngineCore.mm (C++) → Tracktion Engine
```

`OBJEngineCore.h` exposes only Foundation types (`NSString`, `NSArray`). Swift does not know JUCE exists.

**Naming:** the `OBJ` prefix for the ObjC++ bridge's classes. The `OBJEKAT` prefix is reserved for the Swift types exposed in the following phases.

---

### Initialising the engine

**Decision: `initialise()` called in `init`, not in `startAudio`.**

`DeviceManager::initialise()` triggers an asynchronous rebuild of the wave device list (through `prepareToStartCaller->triggerAsyncUpdate()`). If `initialise()` is called and then `transport.play()` in the same frame (the same button), `waveOutputs` is empty at the moment Tracktion builds the audio graph → silence.

By initialising the device in the constructor (`init`), the rebuild has time to finish before the first user interaction.

```objc
- (instancetype)init {
    juce::initialiseJuce_GUI();        // initialises JUCE's MessageManager
    _engine = make_unique<Engine>();
    _engine->getDeviceManager().initialise(0, 2);  // here, not at Play
}
```

---

### Choosing the sound card

**Decision: the UI picker calls `setOutputDevice:` directly. Play does not touch it.**

`setAudioDeviceSetup` restarts the device asynchronously. If Play calls `setOutputDevice` immediately before `playHardcodedFile`, the same race condition as at startup → silence.

The device is configured through the picker (onChange). Playback only has to play. If the device changes mid-playback, the edit is destroyed then relaunched through `dispatch_async` (two run loop cycles to let `prepareToStart` finish).

**A known limitation (to be addressed in Phase 1):** changing device during playback interrupts the sound. Workaround: Stop → change device → Play.

---

### Mapping `SoundObject` ↔ Tracktion (settled in Phase 2)

**Decision: 1 AudioTrack + 1 WaveAudioClip per sound object. A single global Edit.**

The Edit is rebuilt entirely on every press of Play (`playSoundObjects:`). No session file — everything is in memory. This approach is simple and leaves no residual state between sessions.

Benchmarking 100/500/1000 objects deferred to Phase 3+.

---

## Phase 2 — Wiring the audio (May 2026)

### The Swift ↔ Tracktion bridge API

**Decision: an `OBJSoundObjectData` transfer class (ObjC) as the serialisation layer.**

Swift builds `OBJSoundObjectData`s in `ContentView.handlePlay()` and passes them to `playSoundObjects:`. No JUCE/Tracktion type comes back up into Swift.

```
Swift SoundObject → OBJSoundObjectData → playSoundObjects: → AudioTrack + WaveAudioClip
```

### The playhead

**Decision: a SwiftUI Timer polling `currentPlaybackPosition` at 50 ms.**

The alternative (KVO or a Tracktion callback) set aside — more complex for Phase 2, unnecessary at 50 ms. If the precision becomes insufficient for Phase 5 (automation), move to a Tracktion callback.

### Drag and drop

**Decision: a SwiftUI `.onDrop` on the timeline's ZStack, the duration through AVFoundation.**

The duration is read with `AVURLAsset.duration` (synchronous for local files). A fallback to 5.0 s if the duration is null or invalid.

### stopPlayback vs stopAudio

**Decision: two levels of stop.**

- `stopPlayback` — a soft stop: stop the transport + reset the edit, with the devices left open. Used by the Stop button.
- `stopAudio` — a full teardown: the above + `closeDevices()`. Kept for Phase 0 compatibility and for an emergency stop.

### Volume / pan through VolumeAndPanPlugin (settled in Phase 2)

Every Tracktion `AudioTrack` automatically has a `VolumeAndPanPlugin` at the head of its chain. Access:

```cpp
for (auto* p : track->pluginList) {
    if (auto* vap = dynamic_cast<te::VolumeAndPanPlugin*>(p)) {
        vap->volParam->setParameter((double)volume, juce::dontSendNotification);
        vap->panParam->setParameter((double)pan,    juce::dontSendNotification);
        break;
    }
}
```

Called on adding and on every `updateVolume:pan:forID:`.

### A live Edit vs a rebuild (settled in Phase 2)

**Decision: a persistent Tracktion Edit, mutated incrementally.**

The "rebuild on every Play" approach was rejected: jarring (the playhead resets), and it makes hearing changes in real time impossible.

The architecture kept:
- the Edit created in `init`, never destroyed (except in `dealloc`)
- `std::unordered_map<std::string, te::AudioTrack*>` + `std::unordered_map<std::string, te::WaveAudioClip::Ptr>` in `OBJEngineCore`
- the key = the `SoundObject`'s UUID string
- `addSoundObject:withID:` — idempotent (removes it if it already exists)
- `removeSoundObjectWithID:` — `deleteTrack` + erasing from the maps
- `updatePosition:duration:forID:` — `clip->setPosition(ClipPosition)`
- `updateVolume:pan:forID:` — `VolumeAndPanPlugin`
- `play` / `stop` / `seekTo:` — the transport only

`setOutputDevice:`: stop the transport → change the device → restart the transport. The Edit stays intact.

### The `toRawUTF8()` trap (solved in Phase 2)

`juce::String::toRawUTF8()` returns a `const char*` pointing at the String's internal buffer. On a temporary, that pointer is dangling as soon as the expression ends → `EXC_BAD_ACCESS`.

**The rule:** always store the `juce::String` in a local variable before `toRawUTF8()`.

```cpp
// ❌ crashes
NSLog(@"%s", audioFile.getFileName().toRawUTF8());

// ✅ correct
auto name = audioFile.getFileName();
NSLog(@"%s", name.toRawUTF8());
```

### The lane (settled in Phase 1-2)

The `lane` is a pure Swift property — with no Tracktion counterpart. It serves only the 2D visual placement in `TimelineView`. Tracktion ignores the order of the tracks for playback.

---

## Phase 3 — Loose selection + the tool system (May 2026)

### Multiple selection (`Set<UUID>`)

**Decision: `selectedIDs: Set<UUID>` in `EditViewModel` (replacing `selectedID: UUID?`).**

`selectedID: UUID?` is kept as a computed property (`selectedIDs.first`) for inspector compatibility. `isSelected(_ id:)` is used by `SoundBlockView`.

### The rubber band

**Decision: a DragGesture on the container ZStack (not on a dedicated child).**

In SwiftUI, gestures on the children of a ZStack take priority over those of the container. So the rubber band on the ZStack only activates over empty space. No dedicated background layer is needed.

`DragGesture(minimumDistance: 0)` with a manual check at 4 px — unifying the tap (deselect) and the drag (rubber band) into a single gesture.

### Moving as a group

**Decision: `groupDragOffset: CGSize` as `@State` in TimelineView, shared visually across every selected block.**

When a selected block is dragged and `selectedCount > 1`, it calls `onGroupDrag(offset)` → TimelineView updates `groupDragOffset` → every selected block uses it for its visual offset. At the end of the drag, `viewModel.moveSelected(deltaTime:deltaLane:)` commits the positions.

### Keyboard shortcuts

**Decision: a global `NSEvent.addLocalMonitorForEvents` registered in TimelineView's `.onAppear`.**

The `.onKeyPress` alternative (macOS 14+) was set aside — it requires explicit focus. The event monitor is global within the window, which is the expected behaviour for a DAW (shortcuts active without having to click the timeline).

The token is stored in `@State private var keyMonitor: Any?`, and removed in `.onDisappear`.

### The active tool

**Decision: `activeTool: ActiveTool` in `EditViewModel` (not in TimelineView).**

Reachable from any view. The tool is a global session state, not a purely visual one.

---

## Phase 4 — Scissors + Groups (May 2026)

### The Scissors tool — splitting `ClipPosition.offset`

**Decision: use `ClipPosition.offset` (a TimeDuration) to position the right-hand clip inside the file.**

`ClipPosition` has two fields: `time` (a TimeRange on the timeline) and `offset` (a TimeDuration — the offset inside the source file). The right-hand clip gets `offset = origOffset + splitRel` so as to play the right portion of the file.

A rollback is implemented: if `insertNewAudioTrack` or `insertWaveClip` fails, `setPosition(origPos)` restores the original clip.

```cpp
rightPos.time   = te::TimeRange(fromSeconds(splitTime), fromSeconds(origEnd));
rightPos.offset = te::TimeDuration::fromSeconds(origOffset + splitRel);
```

### Groups — a pure Swift model (Phase 4)

**Decision: groups as a Swift/UI model only, with no Tracktion routing.**

`SoundObjectGroup` (id, name, memberIDs, colorIndex) in `SoundObject.swift`. Tracktion bus routing (a subgroup) is deferred to Phase 5 — too complex for no immediate added value to the interface.

A corollary: a group can hold objects from different lanes. The group's audio coherence (a common gain, and so on) is Phase 5's business.

### A scissors tap with a local position

**Decision: `onTapGesture(count:coordinateSpace: .local)` to recover the click's position inside the block.**

The `.local` coordinate space gives `location.x` in pixels from the block's left edge (0 = the start of the clip). `splitTime = object.startTime + location.x / pixelsPerSecond`.

---

## Sound objects — reworking the paradigm (July 2026)

A **sound object** = a group that can be instantiated in N places on the timeline, recorded as an `ObjectDefinition` (in the project registry `objectDefinitions`). The baked wave lives in `samples/objects/`, the original editable sub-tree in a sidecar `<wave>_objectstate.json` beside it. An automatic transitive cascade when A ⊂ B ⊂ C (a fixed point over freshness).

### Decision: two regimes, live and baked (August 2026, the containerclip branch)

A sound object exists in one regime or the other, never in both.

- **Baked** — the object is CLOSED. Each instance is a `.clip` placement (`SoundObject.definitionID`) that reads the definition's wave. N instances cost N file reads, nothing more.
- **Live** — the object is OPEN. The content is materialised on the instance opened, and the OTHERS become **mirrors** of it: the same sub-tree, put back at their position, with their mix and their window. They all refer to the same origin, **with no render at all**.

The live → baked passage is the CLOSING (`closeObject`: one single render, then every instance comes back to the wave). Cancelling (`cancelObjectEdit`) brings each one back to its snapshot from before the session.

What this replaces: the debounced live preview, which re-rendered the sub-tree offline every 300 ms to hot-swap the other instances onto throwaway waves (`samples/temp/`). No more temporary files, no more generations to invalidate, no more rendering while you edit.

What makes it possible: the **ContainerClip**. On the folder model, a group was a FolderTrack + N AudioTracks — there was no single node to lay down elsewhere, hence the detour through baking. A group is now ONE clip, hence a content that can be laid down identically.

The CPU cost holds because only one sound object is open at a time, and because a track's `CombiningNode` only handles a container where it crosses the current block.

Details that matter:

- A mirror is **folded**: `buildLaneEntries` only descends into open groups, so its content is neither visible nor hit-testable, and nothing in it is modified behind the origin's back. It is neither editable nor detachable (`isLiveMirror`).
- The re-mirroring is **debounced at 0.6 s and conditioned on the signature** of the content: laying a mirror again rebuilds its engine sub-tree, hence re-instantiates its plugins.
- Each mirror aligns on its **snapshot** from before the session, never on its current state: once mirrored it is a group, it no longer has a `sourceOffset` or a `speedRatio` to question, and the alignment would drift on every pass.
- The mirrors become baked clips again **before the closing's `pushUndo`**: otherwise, undoing a closing would resurrect N live copies of the content, orphans of any session.

The key files: `EditViewModel+Objects.swift`, `EditViewModel+Bake.swift` (the bake primitives: the render span, the copy with fresh ids, realigning a restored sub-tree), `SoundObject/ObjectDefinition.swift`, `Timeline/SoundBlockView.swift` / `GroupBlockView.swift`, `Timeline/TimelineView+TapHandler.swift`, `Timeline/TimelineKeyHandler.swift`, `Inspector/Synoptic/SynopticView.swift`.

### Decision: the render isolates through `allowedClips`, no longer by amputating the clone (August 2026)

`renderObjectToFileAsync` isolated the object to be baked by removing every other clip from the cloned track. A track's clip list holds only its **direct** clips: for an object living inside a group, that loop removed the ancestor carrying it and rendered an empty track — a silent wave, published with no error since the file existed. Every bake of a nested object was silent: a sound object created from a sub-group, closing a nested instance, re-baking a child of a group.

The isolation is now **declared to the renderer**: `Renderer::Parameters::allowedClips` receives the target **and its chain of ancestor containers** (`renderChainForKey:`). The ancestors are indispensable — `createNodeForContainerClip` passes the same `CreateNodeParams` to `createNodeForClips`, so the filter also applies *inside* the container: a container not allowed has no node, and its content does not exist.

The clone is now touched only for what the renderer cannot know: bypassing the target's chain tail (the fader + window/fades, kept live on the baked clip), and making the **ancestors transparent** — their window opened over the render range, their fades cancelled, their whole chain disabled. Without this the parent's window would trim the target, and the parent's processing would be baked into the wave *and then* reapplied on playback.

### A corollary: the target's content is NOT an ancestor

`renderChainForKey:` returns **two** lists, not one. The renderer's allow list (`allowed`) carries the target, **all of its content** *and* its ancestors — it needs all three, for the reason above. But only the **ancestors** (`ancestors`) are made transparent on the clone. As long as the chain arrived flattened, `prepare` treated "everything that is not the target" as an ancestor, so it also disabled the plugins **of the content** — that is to say, exactly what is being baked:

- **a MIDI object**: its instrument is a plugin of its `ContainerClip` (@see "MIDI inside a `ContainerClip`"). Wrapped in the group of one that "Create a sound object" creates, it became content — its instrument disabled, not a single source of audio left in the group, and the renderer failed on *Didn't find any audio to render*;
- **a group**: the fader / window / FX of its children went to bypass and the sub-groups' bounds opened over the whole range, against the rule above (sub-groups keep their bounds and fades: they are part of the content being baked).

The same blind spot, the same campaign: flushing the plugins' state before cloning and re-asserting it on the clone (`forcePluginStatesForRenderClone:`) went through `te::getAllPlugins`, which sweeps only a track's **direct** clips. Every plugin living inside a container — hence of every grouped object, MIDI instruments included — started again from its last serialised state, often the factory settings. Hence `objAllPluginsDeep`, which descends into the `ClipOwner`s.

### Decision: instantiating an AudioUnit is THE cost, and it can be counted (August 2026)

A measuring campaign on a bake that froze the interface for 6.9 s showed that 5.9 s went into building the clone. The decisive figure: **6 AudioUnits instantiated, only one of them useful**. Two fixes came out of it, and one rule.

**The clone loads only what it renders.** `Edit::EditRole::forRendering` only means `playDisabled` — it is `forExporting` that carries `pluginsDisabled` — so a render clone loads *every* plugin of the Edit, and `ExternalPlugin`'s constructor calls `callBlocking (startPluginInstanceCreation)`: on the main thread, at ~2.4 s per instance for a UADx. Yet the target track is detached at the root and `useMasterPlugins` is false: stem plugins and other objects' plugins cannot enter the wave. So `OBJEngineBehaviour::shouldLoadPlugin` filters the loading during the building of the clone alone, by walking up the PLUGIN node's ancestors to the first CLIP or TRACK. Walking up, and not looking at the direct parent: a parallel-block plugin lives under the PLUGIN that hosts it.

**A removed plugin is put in storage instead of being reloaded.** Many gestures take an object out of the graph to put an identical one back: opening a sound object, wrapping a MIDI clip, cut/paste, undoing. The mechanism for avoiding that is already native — `PluginList::insertPlugin (ValueTree)` goes through `PluginCache::getOrCreatePluginFor`, which returns the **already live** plugin whose state it is, and the cache only releases a plugin when nobody else holds it any more. Detaching a plugin does not destroy its instance. So keeping a `Plugin::Ptr` for the length of the round trip is enough: it is `moveClipToOwner` applied to plugins. Paired on the model + the state chunk, with a 20 s TTL.

What the storage cannot serve: a real duplication (two simultaneous instances = two instances, that is DSP physics) and the render clone, which is another Edit.

**Measured, to close the question: an AudioUnit CANNOT be instantiated off the main thread.** This is not caution, it is a JUCE constraint, verified on two UADx. `AudioPluginFormat::createInstanceFromDescription` tests the calling thread: called from a background thread, it routes to `createPluginInstanceAsync`, which does `postMessage (new AsyncCreateMessage (…))` — so the creation runs on the **message thread** whatever the caller, and the caller waits on its `WaitableEvent`. Recorded with a 10 ms timer as a responsiveness probe: creating a UADx Opal from a background thread blocked the main thread for **1497 ms, that is to say exactly the duration of the creation**. The destructor does the same in reverse (an `AUDeleter` posted to the message thread, and waited on) — an AU destroyed off the message thread deadlocks if JUCE's queue is not being served.

The consequence: moving the clone's construction into a thread removes nothing, it moves the freeze. The only way to stop freezing is to **have no AU to instantiate** — that is to say, to render from the live graph, as `AudioTrack::freezeTrack` does natively.

**The rule that comes out of it, to be applied before accusing anything else:** in this application, a slow gesture is almost always an AudioUnit instantiation on the main thread — not the view, not the graph, not the undo capture. All three were measured innocent here (a frame of 63 to 481 ms against 3000 to 6800 ms of model; graph rebuilds at 2 ms; a snapshot at 15 ms). `UIPerf.measure` separates the model's cost from the frame's, and `renderTrackToFileAsync`'s milestones break the bake down: start there.

### Decision: a sound object is ALWAYS a group

"Create a sound object" is only offered on a group. On a lone clip/MIDI, `makeObjectWrappingClip` first wraps it in a **group of one** (the existing grouping primitive, with the nesting preserved: a sub-group if it is already inside a group) and then makes a sound object of it.

### Decision: editing on a double-click (right-clicking no longer modifies anything)

- **Double-click** on a sound object = OPEN; **double-clicking again** on the open object = CLOSE (a new bake). It takes priority over unfolding a group and over the MIDI piano roll; resolved geometrically in `handleCanvasTap` (the block stays pure presentation). The children keep their double-click once the object is open.
- **Cancelling with a rollback**: `Esc`, `⌘Z`, or the arrow button (`arrow.uturn.backward.circle.fill`) at the top right of the block being edited (the click detected geometrically, in the top-right zone).
- **Right-click**: keeps only "Create a sound object" (an ordinary group/clip) and "Detach this instance" (an instance). No "Open" / "Close" / "Cancel" entry.

### Decision: explicit states on the block

A discreet spinner during the automatic re-bake (`recomputingDefinitionIDs`), then a **transient green ✓ for 15 s** when an instance is resynchronised (a timestamped `resyncedBadgeDeadline`, robust to overlapping re-bakes). For as long as an object is open, it carries the "other instances are following me live" indicator (`hasLiveMirrors`).

### Decision: the synoptic's FX are read-only outside an edit

On a **closed** sound object, the synoptic's FX (cards, "+" inserts, parallel branchings, branch/chain gains) are greyed out/disabled with an "Open to edit" tooltip (`SynopticView.fxReadOnly`). The mix (volume/pan/mute), the source and the stems stay interactive. Once the object is open, the instance is materialised (it is no longer `isObjectInstance`) → the FX are fully interactive, with no dedicated code.

### A fix: the "digit → Search field" bug (editing volume/pan)

Typing a digit into a `DragValueBox` while a search/filter field ("Search…" / "Filter…") kept the **AppKit first responder** sent the keystroke into that field: SwiftUI only gave the box a visual focus, and the global keyboard monitor (`TimelineKeyHandler`) bails as soon as the first responder is an `NSTextView`. `grabKeyFocus()` (on tap / at the start of a drag) takes the first responder away from the third-party field so that the keystroke does start the input in the box. Temporary `[MIXFOCUS]` diagnostic logs are in place until the fix is validated at runtime.

---

## Decoupling lane from track (August 2026)

### Decision: the lane is a fact of display, the track a scheduling resource

"A lane = a track" is **abandoned** as an invariant. It never aimed at the lanes: it served as a proxy for "few tracks", after the "1 object = 1 AudioTrack" model had shown that the graph's cost must not follow the number of objects. The proxy was a bad one — 30 visible lanes = 30 tracks even if three objects are playing — and it bounded nothing, since each MIDI clip added its dedicated track.

What a track **is** in this model, and nothing else:

- the only unit the root player parallelises (`numCPUs − 1` threads) — a `CombiningNode` serialises all of its `TimedNode`s onto the thread that handles it;
- two virtual input devices Tracktion creates behind its back, whose aliases swelled `Settings.xml` (see the 50 s startup);
- the only object in the engine that has an **output** (`getOutput()`), and the target of an offline render.

So it carries no identity, no shown name, no plugin, no setting.

**A single decision point: `trackSlotForKey:lane:`** (`OBJEngineCore.mm`). The policy in force is still "one compartment per lane", so the behaviour is unchanged — the decoupling is a refactor at constant behaviour, validated as such (a build + no difference in the number of tracks). Changing it (one compartment per stem, a pool bounded by the cores, a compartment reserved for high-latency objects) touches only that method.

**The constraint that does remain:** no policy may make the number of tracks proportional to the number of **objects**.

### Decision: an object's carrying track is DEDUCED, no longer remembered

`_objectLaneMap` (object → engine lane) is removed. `trackForKey:` walks the clip up from container to container to its track (`objOwningTrack`; a `ContainerClip` is both a `Clip` and a `ClipOwner`, and `Clip::getTrack()` only answers for a clip laid directly on a track). The graph is the only truth: a parallel table was only an opportunity to drift — and it drifted already, a detached object still being able to resolve there to a track it no longer lived on.

The direct consequences: `setLane:forID:` becomes "re-evaluate the allocation" (an early-out on the clip's real parent, no longer on a remembered lane); `disbandGroupFolder:` no longer has a destination lane to reconstitute, and the members come out at the container's owner; the split now only copies membership of a container, the only thing that cannot be deduced.

### What it reopens: the stems

The decoupling also removes the one reason that made the number of tracks grow with the number of objects: a **MIDI clip's dedicated track** (@see "MIDI inside a ContainerClip" below).

The stem buses have been no-ops since the containerclip switch **because** membership was expressed by moving a track, which "a lane = a track" made impossible (one track carried objects of different stems). The premise falls: "an object's track is that of its stem" becomes the natural expression again, and with it the bus FX chain, the gain, the mute, the meter, **detaching from the Main** (`setOutputToDeviceID({})`) and the stem render — all native, all already written in the disabled code. The alternative (stems = root buses fed by taps, a generalisation of the top-level aux) keeps a finer parallelism and would allow a group child's own stem, but it takes a new mechanism and makes "Σ stems = mix" rest on the PDC alignment of the taps. The arbitration was settled in favour of the first branch: @see "The stems rewired" below.

---

## MIDI inside a ContainerClip (August 2026)

### Decision: a MIDI object = a ContainerClip whose only child is its MidiClip

A MIDI clip used to live on a dedicated `AudioTrack`. That was not a choice: a `MidiClip` is not an `AudioClipBase`, it has **neither a plugin list nor fades** — so the object's chain had to live elsewhere, and "elsewhere" could only be a track, a `ContainerClip` refusing MIDI (`canContainMIDI`, `tracktion_ClipOwner.cpp`).

That refusal was the **only** lock: `createNodeForClip` already dispatches `MidiClip` from a container's internal `CombiningNode`, and `ContainerClipNode::process` passes `pc.buffers.midi` to its local player — so the MIDI does come out of the container and cross its plugin list. The engine patch `0021` lifts it in one line, in the image of `canContainAudio` just below. (The app comment "the container cannot host a MIDI clip" was **out of date**: it described the `USE_DYNAMIC_OFFSET_CONTAINER_CLIP` branch, since abandoned.)

What that passage did not say: that `pc.buffers.midi` is **the node's member buffer**, and it is the node's job to clear it. `ContainerClipNode` declares `ClearBuffers::no` — so `Node::process` clears neither its audio buffer nor its MIDI one — and its local player only *adds* into it (`NodePlayer`: `mergeFrom`). For the audio the contract is picked up downstream (`CombiningNode`, `TimedNode`), never for the MIDI: the previous block's messages left again on the next block, timestamp included, and the instrument received the same note-on on every block until it saturated. The engine patch `0026` adds the missing `clear()`, before the window guard. That defect is as old as the node; `0021` is simply what made it audible, by making the container the first thing to produce MIDI.

A MIDI object is now a `ContainerClip` with, as its only child, its `MidiClip`, and **the virtual instrument at index 0 of the container's plugin list**.

**One container per MIDI object**, and not the instrument laid on a group's container: a VSTi *writes* its buffer, it does not add into it — it would crush the sum of the group's audio children.

**The chain keeps its `ObjWindowFade`**, unlike a group's: it is what cuts the instrument's tail at the end of the object, exactly as the track's chain used to. A group, for its part, deliberately lets its FX tail ring on.

### What it repairs (silent until now)

`assignObject:toGroupFolder:` left a MIDI clip on its track: audible, but **outside the group's bus**. Consequences never reported to the user:

- baking a group that held a MIDI clip **lost the MIDI** (`renderChainForKey` only collects the container's clips) — the same for a sound object built on such a group;
- a send from a MIDI clip that was a child of a group was refused (its chain was not swept by the container's aux return).

### What it gains

One track fewer per MIDI clip — the last thing making the number of tracks proportional to the number of objects — and an instrument that no longer runs on **every block** of the session (as a track plugin) but only within its object's activation window. Incidentally, a MIDI object becomes an object like any other: chain, window, fades, lane, group, aux, sound object. **Every object in Objekat is now a clip, and only a clip.**

### Still open

**Real-time MIDI recording**: a `ContainerClip` is not an input destination. It will take recording onto a buffer track then moving the resulting clip into its container.

---

## The stems rewired (August 2026)

### Decision: a stem = a submix `FolderTrack`, membership = the track

The stem buses had been **no-ops** since the containerclip switch. The reason was single and well identified: membership was expressed by moving an object's track into the stem's folder, and "a lane = a track" made one and the same track carry objects of different stems. The lane / track decoupling lifts exactly that premise — the pool's compartment becomes **(stem, lane)**, and moving an object to another stem means moving its **clip** to the compartment of the same lane in the other stem.

The arbitration against the "stems = root buses fed by taps" alternative: its only advantage of its own (a group child's stem, independent of its group) is **moot** — the Swift model already forbids assigning a stem to a child (`assignStem` bails on `parentGroup != nil`), a child feeding its group's submix. So what was left was a comparison of costs, which the submix wins: the bus FX chain, gain, mute, meter, detaching from the Main and rendering per track are **native**, where the taps took a new mechanism whose correctness would rest on the PDC alignment.

What Tracktion does on its own: `createNodeForSubmixTrack` sums the child tracks then applies the folder's plugin list and its output; `createNodeForTrack` returns `{}` for a track that `isPartOfSubmix()`, so nothing is counted twice. **"Σ stems = mix" is true by construction**: an object takes only one path, there is no parallel branch to realign.

### Three points of implementation

- **The stem is not remembered, it is deduced** (`stemKeyForKey:`): the folder carrying the object's track **is** its stem. The same doctrine as the carrying track (@see "the carrying track is DEDUCED") — a parallel table would only be an opportunity to drift. A useful consequence: changing lane keeps the object in its stem, and an object created before its bus exists is born at the Main, where `assignObjects:toStemID:` comes to fetch it.
- **A single gesture of membership**, `moveObjectKey:toStemKey:`; `assignObjects:`, `moveObject:fromStemID:toStemID:` and `disbandStemBus:` all come back to it. `fromStemID` is ignored: where an object comes from is read off its clip, not off a parameter.
- **Detaching a stem from the Main** = `getOutput()->setOutputToDeviceID({})`. The track stays **processed** (the graph wraps it in a `SinkNode`): its meter goes on living although nothing reaches the master any more.

### What has no stem

- **A child of a group**: it lives inside the container, hence on the group's track, hence in the group's stem. Explicitly skipped by the moves.
- **An AUX**: its return is built **above every track** (`createTopLevelAuxReturns`), not inside a bus's submix — laying it in a folder would send nothing there, it would only add a silent node. Refused on the model side **and** on the engine side rather than showing a membership the audio would not follow.

### The undo hole, plugged along the way

`applySnapshot` recreated the stems' model but **never their buses**: for as long as the stems were no-ops, it did not show. Now the order matters — the buses first, the objects after, otherwise `syncAdd` assigns towards a bus that does not exist and the objects of a restored stem come out at the Main in silence. Symmetrically, a bus absent from the snapshot (undoing an "add a stem") is undone, otherwise orphan `FolderTrack`s pile up.

### What it bounds

The pool goes from "occupied lanes" to "stems × occupied lanes" — and the empty compartments are collected (`pruneEmptyPoolTracks`), so the factor is only paid where objects really live. The underlying constraint still holds: **no policy may make the number of tracks proportional to the number of objects.**

---

## Latency: the numbers are read off the graph (August 2026)

### Decision: what delays is the NODE — never a reconstitution on the model side

Two PDC bugs found a few hours apart, of different families, with the **same** cause: an alignment computed from a **model** value where the real delay is produced by the **graph**. The rule that comes out of it: every compensation is computed on `node->getNodeProperties().latencyNumSamples`, read off the node concerned once it is built.

**Patch `0022` — the send taps.** A tap is taken in the *middle* of the graph (the end of its sender's chain), whereas all the equalisation happens downstream. So the wet copy lacked that delay, and **by an amount different per sender**. The rule of the fix: delay tap `i` by `reference − tapLatency_i` and **declare** `reference` (the latency of the content node the return will be summed with); it is enough for `tapLatency_i + delay_i` to equal the declared latency for the downstream equalisation to land right, whatever the correctness of the upstream PDC.

**Patch `0023` — the lane equalisation.** `createNodeForClips` used `Clip::getPluginLatencySeconds()`, which counts only **the clip's** plugin list. Exact as long as a clip was only a source and its chain; wrong ever since a `ContainerClip` also declares the latency of its **content**. A group carrying a latency plugin was therefore not equalised with its track siblings — and since the `CombiningNode` does report the real max, it is the sibling **without** latency that came out early (≈ 21 ms at 48 kHz for 1000 samples, audible on a transient). The nodes are now built first, `laneLatency` is the max of their latencies, and each branch is padded by `lane − its own node latency`.

**Why the duplication existed**: `getPluginLatencySeconds()` is *available before* the graph is built, hence convenient. That does not make it the same quantity — and the day a clip stopped being a plain source, the two diverged in silence. The fix costs nothing: `PluginNode` knows its latency from its constructor onwards (`initialisePlugin`), so a node's properties are readable as soon as it is built.

**A consequence for what follows**: "Σ stems = mix, to the sample" rests on neither of those two alignments — an object takes only one path inside a submix. Those fixes serve the **dry vs wet** (the auxes) and **the clips of one and the same track against one another**.

---

## Automation (August 2026)

### Decision: the points are in time RELATIVE to the start of the object

`AutomationPoint = { t (seconds since the start of the object), v, c }` — the exact counterpart of MIDI
notes in relative beats. So moving or trimming an object touches **no** point.

**Why it is the structuring decision**: it is what makes the automation travel with the sound
object. An object is a thing you move, not a position on a tape — a curve in absolute time
would have made automation a property of the timeline, against the whole paradigm.

**What it costs, and it is the only cost**: every site that CHANGES the start or CUTS an object has to
realign and trim the points itself. `derivedCopy` inherits `automation` as it is — right for
copies with identical geometry (copy/paste, duplicate), wrong for the right-hand half of a cut.

### Decision: "no point = no automation", and an empty row is a FADER

A row with no point is neither stored nor encoded: the model's static value goes on ruling
alone, and the "automation to come" row is COMPUTED, not reserved. The obligatory ergonomic
corollary: a drag on a row with no point sets the **static** value and creates no
point; only a double-click creates one. Without this, "no point" would become a state impossible to
get back to the moment a row is brushed.

### Decision: the band REPLACES the content

`expandedSpan` becomes dynamic (= the number of rows shown), and automation takes precedence over a
group's children as over a MIDI clip's piano roll. The switch goes through
**`showsChildrenInline` / `showsPianoRollInline`**, not through `isExpanded` / `pianoRollOpen`.

**Why that lever**: `laneEntries` no longer emits the children of a group in automation mode, which
removes them at a stroke from ALL the geometry — rendering, hover, tap, drag, keyboard, cut, drop
target. Neutralising their hit-testing any other way would have meant touching the four handlers one by
one. **Every new layout site must test `showsChildrenInline`**; testing `isExpanded` there
names objects that are no longer on screen.

### Decision: a curve is pushed WHOLESALE, and the model is the authority

`AutomationCurve::clear` + one `addPoint` per point, with a null `UndoManager` (the undoing is held on the
Swift side); an empty list = erase the curve. A fine-grained reconciliation would cost more than
replacement for curves of a few dozen points. **Measured**: 200 complete pushes =
31–48 ms in Debug, and **zero** extra `restartPlayback` — editing a plugin's ValueTree does not
rebuild the graph.

The single wiring point is `syncPosition`, the one way through for every geometry change (a move,
a trim, a lane, entering/leaving a group). The relative time → edit time conversion is `startTime + t`
**at any depth**: a group's ContainerClip carries an offset equal to its start, so local time
= edit time.

### Decision: the curvature `c` is a PORT of the engine's, not an imitation

`AutomationCurveMath` (Swift) is the line-by-line translation of `tracktion_Bezier.h` +
`AutomationCurve::getValueAt`, checked against a C++ binary built on the engine's header. So what
the editor draws is what the engine plays, and `c` goes into the parameter curve as it is.
A consequence worth knowing: a FLAT segment does not curve (the engine returns a straight line whatever
`c` is) — the gesture refuses it rather than store an invisible curvature.

### Decision: plugin parameter curves are normalised 0…1 — a convention of OURS

Tracktion normalises the parameters of an **external** plugin, not those of a **built-in** (a
`lowpass` runs from 10 to 22000 Hz, and the engine clamps to it: a 0…1 curve would be crushed there onto
10 Hz). Hence a denormalisation at push time, against the range the engine announces, through a
cache per plugin. It is the most exposed point of the project and **it has never been heard**.

### Decision: the composed silence wins over the curve

On an object muted or left out by a solo, an EMPTY curve is pushed: the fader stays at -96 dB, and
the curve comes back as it is when the object becomes audible again. Everywhere else it is the opposite —
the curve is the authority and the static setting is neutralised, greyed out in the synoptic.

### What the project did NOT need to do

No `AutomationCurveModifier` is instantiated: the project writes straight into the parameter
curves. So the engine fix considered as a prerequisite (making `visitAllTrackItems` /
`findClipForState` recursive inside containers) was **abandoned**, for want of a consumer —
a vendored patch that is not exercised is a debt paid at the next bump, not a safeguard.

---

## An object's loop (August 2026)

### Decision: a looping group no longer has an edge — its window is a PORTHOLE onto a pattern

This is the rule everything else follows from. A looping group no longer reads as "a content with
bounds" but as "a window open onto a pattern that repeats indefinitely". So cutting such a
group gives **two portholes onto the same pattern**, not two halves of content; and a time
selection copied over it copies the content shifted by a **whole** number of periods, with the
IN/OUT bounds rebased (often negative).

**What not seeing this straight away cost**: the rule at first held only for the cut.
The time selection ignored it — copying a selection laid over a looping group gave a group whose
content was OUTSIDE its bounds, hence silent; cutting it emptied it. When the left edge advances, the
local bounds rebase by `−delta` so as to leave the IN point at its **absolute** place: that is what
keeps the phase, the engine reading `loopStart` in edit seconds.

### Decision: reverse is EXCLUDED, not "not done yet"

`offsetSourceSecs` serves as the anchor both for the offset and for the loop, and is recomputed in
reverse from `duration` — and it is precisely `duration` that becomes unlimited under a loop. Once
the material is exhausted, the period computed equals the window itself: the "loop" never loops.
Guarded at two levels (the model's `canLoop`, and the engine), and switching to reverse cuts an active
loop. Repairable by giving the anchor a fixed point independent of `duration`; not done.

### The engine patch that came out of it (`0030`)

`ContainerClipNode::process()` only knew how to ARM the local playhead's loop, never to disarm it.
Since the `PlayerContext` is taken over from one graph to the next by `prepareToPlay`, cutting a group's
loop left the container folding indefinitely. **The general rule to remember**: faced with an engine
symptom that "stays stuck" after a model change, look first at what a container's
`PlayerContext` keeps from one graph to the next.

---

## External driving (August 2026)

### Decision: the API is not a parallel layer, it calls the same methods as the interface

A UNIX socket speaking JSON-lines exposes ~105 commands. Every command calls the method the
corresponding button already calls — that is the condition for it never to lie: there are
not two paths to keep in agreement. The corollary imposed on the app's code: **not a single `NSAlert`
left outside the dialogue module**, otherwise a headless command would freeze on a window
nobody can close.

It is also what makes the API the **project's test harness**: a render through `export.run`
analysed in the CLI replaces reading meters and taking screenshots.

### Decision: the API neither READS nor WRITES the user's preferences

A script must be reproducible, and a test must leave no trace in somebody's working
session. Hence: the export no longer picks up the last manual setting and no longer persists
its own (`runExport(_:persistingPreferences:)`, false from a command); `--api` forces the server
without touching the preference; `--no-recent` stops a throwaway project entering "Recent
projects", which keeps only ten.

### Two platform traps, paid for once

- **An orphan launch argument opens the app with NO window**, silently: `NSUserDefaults`
  pairs each token starting with "-" with the next, and AppKit takes the leftover for a
  file to open. Hence the **`--key=value`** form everywhere. The behaviour predates the API
  project.
- **A socket path under 104 bytes** (`sun_path`): beyond that, `NWListener` raises nothing and no
  socket appears.

---

## The phases to come — decisions to take

*The three entries that stood here are settled and were removed on 2026-08-31: fades and automation
are delivered (the sections above), `AVURLAsset.duration` moved to an async `asset.load(.duration)`,
and the rendering of the timeline blocks moved to SwiftUI's `Canvas`.*

- **Real-time MIDI recording** — a `ContainerClip` is not an input destination: it
  will take a buffer track then a move of the clip. It is the only step of the MIDI plan left
  open.
- **A loop in reverse** — deliberately excluded (see "An object's loop"); to be reopened by giving the
  anchor a fixed point independent of `duration`.
- **Multi-threading the containers** — feasible, set aside. Three obstacles not to underestimate: a
  pool of real threads per container (unthinkable with "1000 groups"), nested pools,
  and propagating the sound card's `AudioWorkgroup`. Only to be reopened if a profile shows
  that a GROUP is saturating a core.
- **Rendering from the live graph** — the only way to stop freezing the interface at bake time, since
  the cost is the instantiation of AudioUnits and it cannot leave the main thread
  (see "instantiating an AudioUnit is THE cost"). It is what `freezeTrack` does natively.

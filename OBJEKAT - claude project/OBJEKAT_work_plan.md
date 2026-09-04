# OBJEKAT — the 2026 work plan

**Subject:** the plan for prototyping the object-oriented audio editor after the 2016 ENS Louis Lumière thesis (`OBJEKAT_thesis_digest.md`). The project is thought of as the **basis of an eventual product**, so the architectural choices are structuring ones.

**Decisions settled with Nico (May 2026):**
- The thesis's concept kept whole, with no prior revision.
- **MVP V1**: a `sound` object + an editing area + playback + basic volume/pan. No groups, no plugins.
- **UI stack**: Swift / SwiftUI (native macOS).
- **Target OS**: macOS 15.6 (Sequoia). Swift 6 / modern SwiftUI — no backward-compatibility constraint towards older macOS at this stage.
- **Audio engine**: Tracktion Engine 3.2.0 (C++ / JUCE) — already present in the project folder's `tracktion_engine/`. ⚠️ The JUCE submodule has to be fetched before the first build (`git clone --recurse-submodules` or `git submodule update --init --recursive`).
- **The bridge**: an Objective-C++ wrapper exposed to Swift (a proven approach, in the same process).
- **User tests (a panel of editors)**: not before V3-V4. Phases 0-2 (up to the MVP) and Phase 3 (loose selection + tools) are validated by Nico alone. The panel arrives when there is something complete enough for an editor to cut a real scene on it — typically after Phase 4 (stems + groups).
- **The git repository**: to be created anew. No existing Xcode project to pick up.

---

## 1. The vision and the guiding principles

### The long-term vision
A macOS audio editor where the primitive unit is the **sound object**, and where the UI is designed for film sound editors. Clean code, a decoupled architecture, able to grow into a complete product (groups, stems, automation, 3D object audio formats).

### The project's guiding principles
1. **The sound object is the primitive everywhere** — the Swift model, the bridge's API, the structure inside the engine. If the "object" primitive gets contaminated with Tracktion's notion of a track as early as the UI layer, the benefit of the concept will be lost.
2. **A strict UI ↔ engine decoupling** — the Swift layer has no direct dependency on JUCE / Tracktion. Everything goes through the bridge's API. The consequence: the engine can be changed (Tracktion vs something else) without rewriting the UI, and conversely.
3. **Readable code before fast code** — we will optimise once we have something that works.
4. **Short iterations** in the Lean Startup spirit, as in 2016 — one working deliverable at each milestone, testable in real conditions.
5. **Test on real editing sessions as soon as possible** — the conclusion of the 2016 thesis was clear: only prolonged use reveals the inconsistencies. Do not stay on artificial test cases too long.

---

## 2. The MVP V1 scope

### What is in V1
- **A single kind of sound object: `Sound`** (an audio file + a position in time + volume + pan).
- **The editing area**: a horizontal timeline, rows (with no routing meaning), drag and drop to move an object, changing the in/out points by dragging the handles.
- **The exploration area**: a minimal `Sound library` tab — a browser of local files, drag and drop into the editing area to import.
- **The object area**: a minimal synoptic for the selected `Sound` — the audio file → the volume attribute → the pan attribute → the Main stem.
- **A toolbar + transport**: Play / Pause / Stop / the playback position, an indicator of the active tool.
- **Real audio playback** through the Tracktion Engine, with an animated playhead.
- **Selection**: clicking an object selects it (highlights it, shows it in the object area).
- **Real-time modification**: adjusting the volume/pan of a selected object from the object area, audible at once.

### What is explicitly out of V1
- Groups.
- Multiple stems (just a hard-coded `Main`).
- Held-key tools (Volume `V`, Pan `P`, Stem digits, Lock `L`, Mark `M`, Focus `F`).
- Loose selection (multi-object, time selection, the shift/cmd/alt modifiers).
- Plugins.
- Automation.
- Fades.
- Multiple tabs.
- Markers.
- Link, sound objects.
- Export.
- Video / a reference picture.

### Why this scope
MVP V1 proves **the complete chain** Swift UI → the bridge API → Tracktion → audio. It is the technically riskiest dependency. Once that backbone is standing, adding features is incremental.

Conversely, starting with the held-key tools or the loose selection — which are the interface's conceptual innovation — without having proved the audio chain means risking discovering late that the bridge's architecture does not hold, and having to start over.

---

## 3. The target architecture

### An overview

```
┌────────────────────────────────────────────────────────┐
│                                                        │
│   OBJEKAT.app  (Swift / SwiftUI)                       │
│                                                        │
│   ┌──────────────────────────────────────────────┐     │
│   │ Views (SwiftUI)                              │     │
│   │  EditingZone / ExplorationZone / ObjectZone  │     │
│   │  Toolbar / Transport                         │     │
│   └──────────────────────────────────────────────┘     │
│                       ▲                                │
│                       │                                │
│   ┌──────────────────────────────────────────────┐     │
│   │ ViewModels / State (Swift, ObservableObject) │     │
│   │  SessionStore — the UI's source of truth     │     │
│   │  observes through Combine what the bridge    │     │
│   │  returns                                     │     │
│   └──────────────────────────────────────────────┘     │
│                       ▲                                │
│                       │                                │
│   ┌──────────────────────────────────────────────┐     │
│   │ Bridge layer (a Swift façade)                │     │
│   │  OBJEngine, OBJSoundObject (Swift wrappers)  │     │
│   └──────────────────────────────────────────────┘     │
│                       ▲                                │
│            imported through a bridging header          │
│                       │                                │
│   ┌──────────────────────────────────────────────┐     │
│   │ Bridge layer (Obj-C++ .mm)                   │     │
│   │  OBJEngineCore.mm — an ObjC façade over      │     │
│   │  Tracktion: init the engine, load an Edit,   │     │
│   │  create a track, import a clip, play, etc.   │     │
│   └──────────────────────────────────────────────┘     │
│                       ▲                                │
│                       │  direct C++ calls              │
│   ┌──────────────────────────────────────────────┐     │
│   │ Tracktion Engine (C++ / JUCE)                │     │
│   │  vendored as a git submodule                 │     │
│   └──────────────────────────────────────────────┘     │
│                                                        │
└────────────────────────────────────────────────────────┘
```

### The conceptual mapping sound object ↔ Tracktion

Tracktion organises its world around `Edit` (= a session), `Track` (= a track), `Clip` (= a clip in a track), and the plugins through `PluginList`. The challenge is to map our **sound object** onto that without letting the Tracktion concept come back up into the UI.

**A proposal for `Sound` (MVP V1):**
- A `Sound` sound object on the Swift side ↔ a `tracktion::WaveAudioClip` placed in a dedicated `Track`, *invisible* on the UI side.
- The Tracktion track serves only as a technical container to carry the clip; its properties (the track's volume, track plugins) stay at their neutral values and are **never** exposed to the UI.
- The object's volume is carried by Tracktion's **clip gain** (the equivalent of Pro Tools's clip gain).
- The pan is carried either by a `VolumeAndPanPlugin` on the track (to be checked), or by a pan plugin at the head of the track.
- Once we have the stems, each stem = a Tracktion bus / sub-track the individual tracks route to.

**To be evaluated in phase 0 (the technical study):**
- Does Tracktion easily support having 1 track per clip, or is there a prohibitive overhead when there are 200 objects in a session?
- If so, can several `Sound`s (not simultaneous on the same UI row) be grouped into the same Tracktion track without breaking the concept? That would be an optimisation invisible on the UI side.
- How does Tracktion handle `panLaw` and multichannel spatialisation.

It is the project's most structuring architectural decision. **Phase 0 must settle it.**

### The bridge API's contract (a sketch for MVP V1)

```objc
// OBJEngineCore.h (exposed to Swift)
@interface OBJEngineCore : NSObject
- (instancetype)init;
- (void)startAudio;
- (void)stopAudio;

// Edit / Session
- (NSString *)createEdit; // returns an editID
- (void)closeEdit:(NSString *)editID;

// Sound objects
- (NSString *)importSoundFromURL:(NSURL *)url
                       intoEdit:(NSString *)editID
                       atTime:(double)seconds; // returns a soundObjectID
- (void)moveSoundObject:(NSString *)objectID toTime:(double)seconds;
- (void)setVolume:(double)dB forSoundObject:(NSString *)objectID;
- (void)setPan:(double)pan forSoundObject:(NSString *)objectID;
- (void)deleteSoundObject:(NSString *)objectID;

// Transport
- (void)play;
- (void)pause;
- (void)stop;
- (void)seekTo:(double)seconds;
- (double)currentTime;
@end
```

On the Swift side, that gets wrapped in strongly typed types:

```swift
final class OBJEngine {
    private let core = OBJEngineCore()
    func importSound(url: URL, at time: TimeInterval) -> SoundObjectID { ... }
    // etc.
}

struct SoundObject: Identifiable, Equatable {
    let id: SoundObjectID
    var startTime: TimeInterval
    var duration: TimeInterval
    var volume: Double  // dB
    var pan: Double     // -1.0 ... 1.0
}
```

The central idea: **the bridge exposes neither Track, nor Clip, nor Tracktion's Edit — only sound objects and their operations**. The leaking abstraction is the enemy.

---

## 4. Phases and milestones

Five phases, each with a testable deliverable. The estimate is in *working sessions* rather than calendar days, because the pace depends on you.

### Phase 0 — A technical spike & validating the architecture
**Goal:** prove the technical stack stands up, lift the riskiest unknowns before investing.

- [ ] Fetch the missing JUCE submodule into `tracktion_engine/modules/juce/` (it is referenced but the folder is empty — the zip did not hold the submodules).
- [ ] Build Tracktion's `DemoRunner` (the `examples/DemoRunner` folder) to validate the macOS 15.6 / Xcode / C++20 toolchain.
- [ ] Create a minimal Swift/SwiftUI `OBJEKAT.app` Xcode project, alongside `tracktion_engine/` (in the same OBJEKAT parent folder).
- [ ] Integrate JUCE + the Tracktion Engine as a dependency. Two paths to evaluate: (a) CMake producing a static lib linked into Xcode; (b) adding `modules/tracktion_engine` and the necessary JUCE modules directly to the Xcode project as JUCE modules. Path (a) is cleaner for maintenance.
- [ ] Write a first `OBJEngineCore.mm` that:
  - Initialises a `tracktion::Engine`.
  - Loads an audio file (a hard-coded path).
  - Creates an Edit, a Track, a WaveAudioClip.
  - Plays the clip through `TransportControl`.
- [ ] Call that from a SwiftUI button ("Play hardcoded sound").
- [ ] **A decision**: 1 track per clip, or grouping? A performance measurement with 100, 500, 1000 dummy clips.

**Phase 0's deliverable:** a SwiftUI app with a button that plays an audio file through Tracktion. Plus a memo `docs/architecture_decisions.md` that freezes the choices.

**The phase's exit criteria:** You can launch the app and hear the sound. You know which Tracktion mapping model you will use from then on. You know how Tracktion is built in your project.

---

### Phase 1 — A UI skeleton with no audio (a dynamic "paper" prototype)
**Goal:** lay down the whole SwiftUI structure with a pure Swift data model (not yet wired to Tracktion). It is the equivalent of the 2016 paper mock-up, but interactive.

- [ ] The Swift model: `SoundObject`, `EditingSession`, `EditingState`.
- [ ] **The editing area**: `EditingZoneView` — a horizontal scrollable display, rows (several), a mocked waveform (a coloured rectangle for now), a drag to reposition.
- [ ] **The exploration area (the sound library only)**: `ExplorationZoneView` — a macOS file browser, drag and drop into the EditingZone which creates a virtual `SoundObject`.
- [ ] **The object area**: `ObjectZoneView` — a minimal synoptic: a frame, a square for the file, a volume slider, a pan knob, a "Main stem" block.
- [ ] **A toolbar + transport**: static icons, Play/Pause/Stop (only triggering a playhead animation).
- [ ] Layout: 5 areas side by side / one above the other, resizable.
- [ ] Selection: clicking an object → a `selectedObjectID` state shared between the Edit and Object areas.
- [ ] The playhead: animated by a 30 Hz Swift Timer (not real playback yet).

**Phase 1's deliverable:** a complete, fluid UI, with no sound played at all. A file can be imported, placed, selected, its synoptic seen, the volume slider moved — but nothing is heard.

**The phase's exit criteria:** The concept passes the "if you put this in front of an editor, they understand where they are" test.

---

### Phase 2 — Wiring the audio (MVP V1)
**Goal:** wire the Phase 1 UI onto the Tracktion engine validated in Phase 0. That is where the **MVP V1** is.

- [ ] Implement the complete `OBJEngineCore.mm` façade (the API sketched above).
- [ ] Replace the mocked `SoundObject`s with wrappers calling the bridge.
- [ ] A real `importSound(url:at:)` → a dropped file does create a Tracktion clip that plays.
- [ ] A real `moveSoundObject` → a drag in the UI repositions the clip in Tracktion.
- [ ] `setVolume` / `setPan` in real time during playback (reactive sliders).
- [ ] The playhead driven by the Tracktion transport's `currentTime` (no longer by a fake Swift Timer).
- [ ] A real waveform drawn from the audio file's data.

**Phase 2's deliverable = MVP V1:** import an audio file, place it in the editing area, move it, listen to it, change its volume and its pan in real time.

**The phase's exit criteria:** You can use the app to do a *real* mini-edit (place 5 sounds at precise positions, adjust their relative volume, listen to the result). It must work for 30 minutes without crashing.

---

### Phase 3 — Loose selection and the tool system
**Goal:** introduce the thesis's interaction innovation. It is the moment when OBJEKAT starts to look like OBJEKAT and no longer like a miniaturised classic DAW. **User testing: you alone at this stage — the panel of editors will come later, from V3-V4 (typically after Phase 4).**

- [ ] Loose selection with 2 graphical zones on the objects (a time zone / an object zone).
- [ ] The `shift`, `cmd`, `alt` modifiers (extend, one-off, forced object mode).
- [ ] Held-key tools: `Edit` (E, the default), `Volume` (V), `Pan` (P).
- [ ] Showing the overlays on the objects when a tool is active.
- [ ] Compound shortcuts: `V + M` mutes, `V + up/down`, `V + backspace`, `P + left/right`, and so on.
- [ ] An indicator of the active tool in the corner of the editing area.
- [ ] `Esc` to come back to Edit.

**Phase 3's deliverable:** a user test (you first, then ideally 1 or 2 professional editors) on the tools. The only way to validate is to get your hands on it.

---

### Phase 4 — Stems, groups
**Goal:** introduce the three kinds of object and the stems, which turn the tool into something usable for a real edit.

- [ ] **Stems**: a multiple structure (at least Main + 2 others), colours, the Stem tool (the number keys), routing.
- [ ] **Groups**: the modelling, creation (`cmd + G`), opening/closing, handling the inside of a group.
- [ ] **The Stem tool** (the number keys).

**Phase 4's deliverable:** a complete session can be cut — sounds, groups, stems. **It is probably at this stage that we invite the first panel of editors to validate the innovations still untested in 2016 (Link, Lock).**

---

### Phase 5+ — The rest
Left to attack after that (in no fixed order):

- Plugins (AU/VST3 integration through JUCE).
- Automation on attributes and plugin parameters (with curvature).
- Fades (including curvature through a vertical drag).
- Markers (3 kinds) and multiple timelines.
- Tabs and synchronisation between tabs.
- The Lock tool + snapping grids.
- The Mark tool.
- The Focus tool (persistent + immediate).
- Link (synchronising attributes between objects).
- Sound objects (a reusable bake, opening / closing).
- A reference video for syncing to picture.
- Conforming to a new picture edit.
- Audio export (stems, an object format for 3D audio).
- Persistence (saving / opening sessions, a proprietary format).

---

## 5. Structuring technical choices and arbitrations

### Why Swift / SwiftUI rather than JUCE in C++
- A more readable codebase, faster to iterate on for the UI.
- Native access to the macOS conventions (Finder drag and drop, accessibility, system shortcuts).
- SwiftUI handles reactive state well — ideal for a UI where the selected object drives several areas at once.
- **An accepted trade-off**: the extra cost of writing the bridge. But that bridge becomes the engine's API, which is healthy.

### Why Objective-C++ rather than direct Swift C++ interop
- The Tracktion Engine and JUCE use C++ templates intensively. Swift C++ interop (5.9+) stays limited on them.
- Obj-C++ is well worn in, supports all of C++, and allows a very simple ObjC API to be exposed to Swift through the bridging header.
- **An accepted trade-off**: a little `.mm` boilerplate to write. It is also a well-defined zone of control.
- To be reconsidered later if Swift C++ interop becomes mature enough and if Tracktion lends itself to it.

### Why not XPC (a separate audio process) straight away
- More initial complexity (serialisation, life-cycle management).
- An audio crash that does not take the UI with it is a benefit **but** Tracktion is globally stable, and before V1 it is a premature investment.
- **Migrating to XPC later is possible**: if the bridge's API has been well isolated, an in-process implementation can be replaced by an XPC one without touching the UI.

### How to version / save a session
To be deferred. For V1, sessions in memory only. A reflection to be had in Phase 4 on:
- Reusing Tracktion's session format (XML, rich, but Tracktion source code).
- Or defining an OBJEKAT format of our own (JSON / Protobuf), with Tracktion as the execution layer.
- The link to be made with the interchange formats (AAF, OMF) that editors use.

---

## 6. Risks and unknowns

| Risk | Impact | Mitigation |
|---|---|---|
| Tracktion badly suited to the 1 track / 1 clip model | High — it would touch the whole architecture | A Phase 0 spike: a performance bench. Plan B: multi-clip/track grouping with virtualisation on the UI side. |
| Multichannel spatialisation badly supported for 2D pan | Medium | Defer multichannel pan until after Phase 4. V1 in stereo is enough. |
| The ObjC++ bridge becomes an API bottleneck | Medium | Keep the API small and command-oriented. Version it. Integration tests on the API. |
| SwiftUI not reactive enough for a timeline with 1000+ objects | Medium | Virtualising the views (showing only what is visible), tested in Phase 1. |
| Audio latency on a volume/pan change | Low-Medium | Tracktion handles that natively; to be validated in Phase 2. |
| A non-standardised session format → a painful migration | Medium | Defer that choice as late as possible, keep an isolated serialisation layer. |
| Wanting to reintroduce the track "on the sly" for implementation reasons | High (philosophical) | Discipline: no Tracktion `Track` comes back up into the bridge's API. Careful code review. |

---

## 7. Concrete next steps (week 1-2)

1. **Setting up the dev environment**
   - Xcode up to date, Swift 5.10+ / Swift 6, target macOS 14+ (to be confirmed against what you use).
   - Clone the Tracktion Engine, build it, run an example.
   - A git repository for OBJEKAT (probably `~/Documents/Claude/Projects/OBJEKAT/code` or a dedicated folder beside it).

2. **A first spike**
   - An empty Swift/SwiftUI app.
   - Add the Tracktion Engine as a dependency.
   - Write a minimal `OBJEngineCore.mm` that plays a hard-coded audio file.
   - A SwiftUI "Play" button.

3. **The Tracktion architecture decision**
   - Test 1 track per clip with 100, 500, 1000 clips.
   - Decide on the `Sound ↔ Tracktion entities` mapping.
   - Document it in `docs/architecture_decisions.md`.

4. **Open questions — settled in May 2026**
   - ~~The minimum macOS target?~~ → macOS 15.6 (Sequoia).
   - ~~A panel of editors?~~ → Yes, but from V3-V4 onwards (after Phase 4).
   - ~~An existing git repository?~~ → No, we start a new one.

---

## 8. Resources

### Tracktion Engine
- The repository: https://github.com/Tracktion/tracktion_engine
- The developer forum (useful for usage patterns): https://forum.juce.com/c/general-juce-related-discussion/tracktion

### JUCE
- The repository: https://github.com/juce-framework/JUCE
- The documentation: https://docs.juce.com/

### Swift C++ interop (for information, plan B)
- https://www.swift.org/documentation/cxx-interop/

### UI inspiration
- Native macOS apps using a C++ JUCE engine as a backend: Logic Pro (Apple, closed), Sound Particles (Mac, JUCE), Spitfire Audio (custom apps). Study their choices visually.

---

*A living plan — to be updated at the end of every phase.*

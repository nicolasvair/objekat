# OBJEKAT — a digest of the thesis

**Source:** *"објекат", an object-oriented audio editor* — Nicolas Vercambre, ENS Louis Lumière, Sound department, class of 2016 (137 pages, in French).
**Supervisors:** Sylvain Lambinet (internal), Vincent Mayol (external). **Reader:** Jean Rouchouse.

This document extracts, condenses and structures the thesis's concepts so that they serve as a reference during the prototype phase. It does not carry over the iterative-evolution commentary attached to each feature (present in the original PDF) except where it throws light on a decision still to be settled.

---

## 1. The problem and the founding hypothesis

### The observation
Today's DAWs (Pro Tools, Ableton, Reaper, Samplitude…) have for 25 years reproduced the analogue duality of a **multitrack recorder + a mixing console**, tools designed respectively in the 1930s (BBC) and in 1955 (Ampex). As a consequence:

- The **audio track** has remained the structuring unit, although it existed initially for physical constraints (an audio stream goes through a signal path fixed by electronic components in real time).
- In the digital world, the sound is discretised and stored in files: the real-time constraint disappears. Yet the architecture of DAWs goes on imposing its old constraints.
- In film sound editing (as opposed to music recording, where a track = a microphone), each track holds sounds of heterogeneous natures: the concept of a track becomes a handicap rather than a help.

### The hypothesis
> An audio editor can be thought out not around **tracks** but around **sound objects** — each carrying its own attributes (audio file, position in time, volume, pan, plugins, sends, routing). That rework brings the tool closer to sound editors' real mental models and frees the interface from constraints inherited from the analogue world.

### The prior validation
The thesis does not start from an intuition: it validates that hypothesis through an **experiment in sound editing with no graphical interface** (5 subjects, professional editors and novices, an imposed scenario, Nicolas driving an invisible Ableton at their dictation). The conclusion: *not one* subject, expert or novice, referred to the notion of a track over the 5 hours of the experiment. The subjects verbalise their work in **sound objects and sub-objects**, naturally organised into **structures** (gestalt).

---

## 2. The conceptual frame

### The sound object after Schaeffer
Taken in the broad sense: a **sound phenomenon perceived as a unit**, which may itself be composed of other objects (gestalt). In music, it is a note or a phrase. In film, the "ambience" is a sound object composed of many other sound objects chosen by the editor.

The sound object exists **only in perception** — it is a product of the human brain. In an audio editor, *every sound or grouping of sounds is a potential sound object*.

### The three modes of listening (Chion, after Schaeffer)
- **Causal**: "the sound of a bicycle" — attaching the phenomenon to its cause.
- **Semantic**: "the sound that expresses idea X" — bearing on the meaning.
- **Reduced**: "the low continuous sound" — focused on the intrinsic characteristics.

The software must accommodate all three (an object can be named causally, tagged semantically, handled on its intrinsic properties).

### Ergonomics: intuition vs efficiency
Every creative tool must serve two profiles:

- The **novice user** favours intuitiveness (drag and drop to the bin).
- The **expert user** favours speed (cmd+backspace).

A structuring conclusion: for every frequent feature, **offer two modes of access — one intuitive, one efficient**.

### Direct manipulation
A central principle: the interface must lean on mental models of the real world. You act *on* the objects, the result is visible at once, and every action must be undoable.

---

## 3. The state of the "object" art in existing DAWs

| DAW | Object-oriented features | Limitation |
|---|---|---|
| **Pro Tools** | Clip gain, AudioSuite, automation over the clip's duration | The automation is tied to the track's time, not to the object → a recurring bug: moving a clip crushes the target automation |
| **Ableton** | Volume / pitch / loop / time-stretch / envelopes per clip, track groups | Still structured around tracks |
| **Samplitude** | Pitch, volume, pan, plugins, sends on the objects | Features added after the fact into track-based software → sub-optimal ergonomics |
| **Reaper** | Many object functions | Relegated to the background (3 interactions to change a clip's plugin) |

**The observation:** the object function exists everywhere, but it stays incidental. Nobody has refounded the interface *around* it.

### 3D audio / object formats (Dolby Atmos, MPEG-H)
The object formats for spatialised sound (3D audio) are conceptually very close: an object = an audio file + metadata (position, gain) + a reference listening system. Yet the current production workflow goes through object tracks + an Atmos plugin — a model very far from the users' mental models. **An object-oriented editor would be natively aligned with those formats.**

---

## 4. The central concept: three kinds of sound object

A sound object is a **container** that merges the current concepts of an **audio clip** (position in time, in/out point) and of an **audio track** (plugins, volume, pan, sends, routing). All of those become **attributes** of the object.

### 4.1 The "sound"
The simplest object: an audio file + attributes. A rectangular shape in the editing area.

### 4.2 The "group"
Several sound objects gathered into one. Rounded corners to tell it apart visually. Behaviours:

- A group is handled like an object (moving, processing, attributes).
- It **opens** on a double-click — the user can then act on its children. A group can stay open.
- The objects it holds are routed to the group by default, but can be routed straight to a stem (the group then becomes a plain editing tool with no effect on the signal).
- Creation: `cmd + G` on a multiple selection.

**Uses:** assembling a composite sound (an explosion, an impact), processing one kind of sound together (all the voice-overs), creating "strata" of processing by baking the heavy processing into a sound object.

### 4.3 The "auxiliary"
Receives signal sent by other objects. Represented by a clip *with no waveform*. **A key innovation: an auxiliary has a start and an end in time** (unlike classic auxiliary tracks). The consequence: when the Send tool is triggered, only the auxiliaries *simultaneous* with the object are offered — the interface simplifies drastically.

**Uses:** a reverb of its own for a scene, processing shared between several objects without having to group them. The possibility of "extending" an auxiliary over the whole session to get the classic behaviour back.

### An important note
The possibility of unifying the three kinds into one (an object that can hold either an audio file or other objects) was considered but set aside — it raised too many unresolved questions (can an audio file exist outside an object? have attributes of its own?). The `sound / group / auxiliary` distinction is therefore a considered choice, to be kept in the prototype.

---

## 5. The stems

The stems are the **output buses** the objects are routed to. Since the objects are no longer constrained to audio tracks, each object has to be routed explicitly (on creation it goes into the `Main` stem by default). A stem is identified by a **colour** the object inherits — so the routing information is legible at a glance without opening the object area.

**The `Main` stem** is created with every session and also serves as the listening bus.

**A stem's properties:** colour, format (mono / stereo / multichannel / an object format), output routing, insert plugins (thought out for mastering: EQ, multiband, limiter), focus/mute/visibility.

**An idea considered and not kept:** showing a stem as an object in the editing area (drag and drop from the stem's icon) so as to be able to handle it like any other object. To be evaluated in the prototype.

---

## 6. The interface's structure — the 5 areas

```
┌────────────────────────────────────────────────────┐
│  Menu bar                                          │  (5)
├────────────────────────────────────────────────────┤
│  Toolbar         |  transport / zoom / timecode    │  (4)
├──────────┬─────────────────────────────────────────┤
│          │                                         │
│  Explo-  │         Editing area                    │
│  ration  │         (a horizontal timeline,         │  (1)
│  (2)     │          rows ≠ tracks)                 │
│          │                                         │
├──────────┴─────────────────────────────────────────┤
│  Object area  (the synoptic of the selected object)│  (3)
└────────────────────────────────────────────────────┘
```

### 6.1 The editing area (centre)
A left→right representation of time, organised into **rows** (not into tracks). A row has no routing meaning: moving an object from one row to another changes nothing in the signal. So the user organises their space freely: spreading out, stacking dozens of sounds when necessary, adapting to each scene. The waveform is kept (a universal standard). Icons: `Fx` for an object holding plugins, a "send" icon for an object with active sends. Each session = one tab.

### 6.2 The exploration area (left)
Four tabs by default (`Sound library`, `Plugs`, `Objects`, `Mark`) plus personal folders. The behaviour is inspired by web browsers.

- **Sound library:** an audio file browser, a search field with operators (`-`, `+`, `""`), a history, a mini-player with a waveform, **I/O/S points** (in / out / sync) modifiable by dragging before importing. Drag and drop or a double-click to import. Marking with a star (grey = for the session, black = persistent).
- **Plugs:** the plugin list, the same interactions as the sound library.
- **Objects:** lists every object present in the session. Lets you find an object again (by name, kind, tag, position in time), re-select it, copy its attributes onto another.
- **Mark:** the list of the markers created by the Mark tool.

### 6.3 The object area (bottom)
Shows the **synoptic of the signal path** of the selected object. A black frame = the object's boundary. From left to right: the audio file (a black square) → the plugins (in parallel when stacked vertically) → the attributes (focus, mute, volume, pan, sends, tags) → the output stem. Creating a sound object makes the processing definitive in a new file (saving CPU), while staying reversible: reopening the object gives access to the content again.

It is the **synoptic** that makes the signal path legible — something absent from today's DAWs (where the routing is coded into a tiny corner of the track).

### 6.4 The toolbar
The tools on the left, the transport and the displays on the right (timecode, zoom, play/pause/loop).

### 6.5 The menu bar
Access to the standard features.

---

## 7. The tool system — the main interaction innovation

It is the software's most original interaction concept.

### The principle
Each tool corresponds to a **mouse interaction mode**, turned on by a **held key** (the left hand) while the mouse acts in the editing area (the right hand). Inspired by the Adobe software (selecting a tool).

- **Temporary activation**: you enter the mode by pressing, you leave it by releasing.
- **Permanent activation**: a click on the tool's icon, or `shift + the key`.
- **Back to `Edit`**: `Esc` or a click on its icon.

### The letters as extended modifiers
A tool's letter behaves like a modifier. So:

- `V + up` / `V + down`: volume ±
- `V + M`: mute
- `V + backspace`: reset to 0 dB
- `P + left` / `P + right`: pan
- `S + up` / `S + down`: the send level
- The `alt`, `cmd`, `shift` modifiers go on working on top.

That grammar lets the user **guess** the shortcuts (`the first letter of the function`). A discovery that becomes a system.

### The tool catalogue

| Tool | Key | Role |
|---|---|---|
| **Edit** | E (the default) | Loose selection, moving, I/O points, fades by dragging (length horizontally, curvature vertically, an S with alt) |
| **Volume** | V | A frame appears on hover: mute / vol+ / vol− / a vertical fader |
| **Pan** | P (or `<`) | A knob; 2D if the stem is multichannel; a recap view of the pans with `P + A` |
| **Send** | S | Shows the simultaneous auxiliaries, with a visible graphical link; `S + A` for the overview |
| **Stem** | 1…9, # | Hover → a square offers the routing; a click or drag and drop to assign |
| **Lock** | L | A time lock (vertical movement only) + grids (Objects, Frame, Bar) |
| **Mark** | M (or Q) | Lays markers: an event (a click), a sequence (`M + S` on a selection), a comment (`M + C` on a selection) |
| **Focus** | F | Replaces solo. A persistent mode per object or an immediate mode tied to the selection (`F + space`) |

### Loose selection (the Edit tool, an important detail)
The selection mixes **time and object**. Each object is divided into two graphical zones:

- **The time zone** (top): a click → the playhead; a drag → a time selection.
- **The object zone** (bottom): a click → selects the object; a drag → moves the object.

Modifiers:

- `shift`: extends the selection.
- `cmd`: adds/removes one particular element (a row or an object).
- `alt`: forces the grab into "object" mode independently of the zone clicked; `alt + drag` = a multiple selection of objects.
- Combined: `alt + cmd + drag` adds to the selection, `alt + shift + drag` extends to objects.

The cursor changes shape according to the zone — essential visual feedback.

### Why this system is central
With no tracks, an efficient way is needed to change the volume, the pan, the routing of *each object individually*. Going into the object area every time is too costly (a large mouse movement, precision required). The tools turn that operation into a left-hand-keyboard + right-hand-mouse gesture: extremely fast once learnt, and learnt fast because the shortcuts follow a mnemonic grammar.

---

## 8. Cross-cutting features

### 8.1 Automation
A double-click on an object → the opening of an automation area internal to the object (a mechanism analogous to opening a group).

- The parameter chosen through a target icon (midi-learn style).
- Points created by a double-click, moved by dragging.
- Curves rather than straight lines with `alt + drag` from a point.
- A pencil icon → writing automation in real time during playback.
- Inside a group: `Tab` switches between the groups view and the automation view.

**The crucial difference from Pro Tools:** the automation is tied to the **object**, not to the track's time zone. Moving the object moves its automation, with no risk of crushing another object's.

### 8.2 Playback modes
- **Play / Pause** (space): playback starts again from the initial playhead (the iterative listen/retouch/relisten mode — *replay*).
- **Resuming from a pause** (`shift + space`): starts again from where it was paused (continuous playback mode).

### 8.3 Focus (formerly solo)
- **Persistent focus**: turned on per object (`F + click` or drag and drop, or through the object area). The other objects are shown transparent.
- **Immediate focus**: `F + space` plays only the selection (time or object) without fixing it as a solo. `alt + F + space` plays *everything except* the selection.

### 8.4 Attributes and plugins — multiple selection and Link
The attributes in the object area are selectable exactly like the objects (click, shift, cmd). You can:

- Copy and paste attributes between objects (`cmd + C` / `cmd + V` or drag and drop).
- Reset (`backspace`), increase/decrease (`up`/`down`).
- **Link (`alt + drag`)**: synchronising an attribute (or a plugin's state) across several objects. Every change propagates. Useful for applying a common treatment to several objects with different routings (different stems, different spatialisation).

### 8.5 Tabs
Each session lives in a tab (web-browser style). It allows:

- Having several versions of an edit open in parallel.
- Creating temporary workspaces for pre-editing.
- Having the shoot's AAF version beside the edit under way.
- Importing a tab's content by drag and drop.

### 8.6 Multiple timelines
A session can show several timelines (each with its own markers):

- A common timeline for the sequence/event markers.
- A personal timeline for working comments.

A timeline can also show those of another tab — the playhead is then synchronised between the two tabs, which makes moving from one session to the other trivial. Combined with the Lock tool, transferring objects between sessions becomes a drag and drop that preserves the timecode.

### 8.7 Markers (3 kinds)
- **An event**: a point in time, a single click. If placed on an object, it *belongs to the object* and moves with it.
- **A sequence**: a time selection → `M + S`. Marks a scene / sequence of the film.
- **A comment**: a time selection → `M + C`. Becomes a text area shown in the editing area (an answer to the common editors' trick of creating an empty group with a name = text).

A marker can be tied to an `M + letter` shortcut (`123` in the Mark tab) — hence direct access to a precise point in the film.

---

## 9. Structuring ergonomic principles

To be kept carefully, they sum up OBJEKAT's philosophy:

1. **The sound object is the primitive.** Everything else (the editing area, the object area, the tools, the selection) follows from that decision.
2. **No tracks, hence routing per object** — shown by the colour (the stem) and the synoptic (the object area).
3. **Two modes of access per common feature**: intuitive (the mouse + the object area) and efficient (a tool + a shortcut).
4. **Temporary tools** turned on by a held key → the left hand stays on the keyboard, the right on the mouse.
5. **Letters as extended modifiers** → a guessable grammar of interactions (`V+M` = mute, `S+up` = send +, and so on).
6. **Direct manipulation**: you act on the objects, the result is visible at once, every action is undoable.
7. **Selection as a shared primitive**: the same grammar of selection (click, shift, cmd, alt) works in the editing area *and* in the object area's attributes.
8. **No graphical overload**: information shown only when the tool is active (the send links only appear with the Send tool, the volume overlays only appear with V, and so on).
9. **Adapting to the three user profiles**: novice (occasional, intuitiveness), middling (quickly productive), expert (shortcuts everywhere).
10. **Mental compatibility with the existing DAWs**: enough familiar landmarks (a horizontal timeline, the waveform, fades) for the transition not to be brutal.

---

## 10. The design methodology (Lean Startup)

The author explicitly followed a short iterative cycle:

1. **Initial hypotheses** — formulated from the preliminary observations.
2. **Observations** — editing with no graphical interface (5 subjects) + professional editors in situ (2 professionals + 3 students).
3. **Paper mock-up 1** — the division into 3 areas, the object concept, attributes, processing, mixing.
4. **Paper mock-up 2** — adding fades, groups, stems, auxiliaries, markers, multiple timelines, lock, automation.
5. **A software prototype** — made in Max (the UI in JavaScript, the processing in modular programming). Focused on the *new* interactions (selection, mixing tools, routing, groups, playback modes, focus). The features already proven (time editing, importing, fades, automation, processing) are not implemented in the prototype.

At each iteration: a presentation to a panel of users (professional editors + students + novices), the feedback noted, integrated into the next version.

**A practical note:** that mode of validation through a user panel is relevant to the 2026 prototype too — it is what made the quality of the original design and it would be a pity to abandon it.

---

## 11. The thesis's assessment and the points left open

### What is validated (through user feedback)
- The general concept of the sound object.
- The groups (the feature the editors found most exciting).
- The object area's synoptic.
- The held-key tool system (tested on the Max prototype — its efficiency confirmed).
- The two-zone loose selection.
- Fades by dragging, with curvature.
- The clip gain replaced by the object's volume attribute.
- The playback modes (replay / resuming from a pause).
- The tabs and the use of timelines to synchronise between tabs.

### What was left to validate in 2016
- The auxiliary object (mixed, divided opinions).
- Link on attributes/plugins (not tested enough).
- The idea of **dragging a stem into the editing area** to handle it like an object (never tested).
- The Lock tool (the lock + the grids) — implemented late, not tested with a panel.
- Showing automation and the inside of a group at the same time.

### Features outside the 2016 scope
- **Conforming** to a new picture edit (the editors' number one need).
- **Audio export** (stems, the final mix, an object format for 3D audio).
- **Importing data** between sessions (other than by drag and drop between tabs).
- Any network / real-time collaboration feature.
- Handling **video** (a picture reference for syncing).

### The author's conclusion (2016)
> "It seems to me that I have reached the limits of what I could do from a paper mock-up and a partial prototype; it is now essential to build a complete prototype before going further. Only use over many hours would let the inconsistencies still present be identified."

**That is exactly the starting point of the 2026 project.**

---

## 12. Notes for what follows (the transition to the work plan)

These points are not in the thesis but come out of the digest — they are to be confirmed in the work plan document:

- The sound object as defined is **structurally very close to the Tracktion Engine's `AudioClipBase` / `Clip` concept** (which already carries a file, plugins, volume through a PluginList, a position in time). The main difference: Tracktion organises the Clips inside `Tracks`. The prototype's abstraction layer will have to **decouple** the notion of an object from that of a Tracktion track (an object can be implemented as a Clip placed in an invisible track, or otherwise).
- The **group** concept is less immediate in Tracktion — it will have to be evaluated whether `FolderTracks` / `ClipSlots` or a custom subsystem suits better.
- The **auxiliaries in time** (which have a start/end) are a real innovation over Tracktion — to be modelled bespoke.
- For the Swift/SwiftUI UI prototype, the sound object concept is the **contract's API** between the Swift layer and the C++ engine (Tracktion). Defining that API clearly is the first technical step.

---

*The end of the digest. The detailed work plan is in `OBJEKAT_work_plan.md`.*

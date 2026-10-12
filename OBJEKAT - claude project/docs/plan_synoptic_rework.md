# Plan — the signal view (synoptic) rework

Branch `feat/synoptic-rework` (from `main` `e2aea50d`). Architect's plan, written 12 October 2026, BEFORE any
code; **revision 2 the same day, after the user's answers to Q1–Q8** (section E records them). Nothing below
is implemented. Three NEW points came out of the answers and need a word from the user (section E.2, N1–N3);
the plan assumes the recommended answer until told otherwise and says where (`→ Nn`).

## The request (the user's words, translated; the French is the source)

1. Draw the object's limits: a rectangle in the style of an FX link's block, in the OBJECT's colour; at
   the top the audio clip (or the source), at the bottom the mixer, both straddling the edges.
2. A new "+": the current "+" disappears and shows only when the hand hovers the line. With no plugin
   at all, the "+" stays as it is today.
3. From a "+" (always there with no plugin, or on hover): drag to the RIGHT → a gain stage, ±20 dB
   centred on 0; keep going right → a gain + pan + mute stage (like an FX link's output).
4. Same principle: drag right and DOWN (−30°) → a parallel branch (replaces the branch icon).
5. Drag right and UP (+30°) → a send taken from that place (so also from the wire going to the stems,
   for a post-fader send).
6. No more default pre/post-FX gains (they are added in one gesture); the clip's output stage
   (volume / pan / mute / solo) stays.
7. The clip's options (pitch, channels, etc.) folded in a zone opened by a chevron or a double-click;
   loop and reverse stay reachable with the zone folded.
8. The same for the FX link: no pan / volume / mute (but the "+" drag adds one quickly), and a foldable
   zone for the inside of the FX link.
9. An FX link takes the name of the object it is created from.
10. Remove the diagnostic at the very bottom.
11. A plugin on a send looks like a plugin of the chain.
12. Sends go back BELOW, under "stem", but the line showing where the send is taken from stays: it runs
    out to the LEFT, then down to the send's name at the bottom. A send is moved by dragging its box onto
    the place it should be taken from, or by dragging the send's SOURCE point.

## The user's decisions (12 October 2026, summarised; they override anything older in this file)

- **D1 — the old gains are CONVERTED at load and DISAPPEAR.** The pre/post-FX gains (`chainInGainDb` /
  `chainOutGainDb`, objects AND stems / Main) and the FX link's output section (`FXLink.gainDb/pan/muted`,
  `FXLinkBlock.local`) stop being engine points. At load, a value that is not neutral becomes a gain stage
  BEFORE (pre) or AFTER (post) the plugins, same dB; an FX link output becomes the gain+pan+mute variant at
  the END of the bin (pan and mute carried over); a trim's automation moves to the stage's parameter. Then
  the model fields, the UI, the engine's anchor `ObjGain`s and the FX link's `#fxout` gain are deleted. The
  send positions `input` / `preFader` are re-anchored WITH THE SAME SOUND. "It is just a gain before or
  after the plugins, same dB." A null / level test proves identity before / after.
- **D2 — the gain stage**: ±20 dB for both faces; thresholds 6 / 80 pt; ±15°; automatable, copyable, counts in
  the limit, NO bypass. On the wire mixer → stems: send only.
- **D3 — branch**: the element under the "+"; on the tail "+" the element above; refused on an empty chain.
- **D4 — FX link name**: FOLLOWS the source object's renaming as long as the user has not renamed the bin;
  duplicates "Kick 2"; several objects → the first in time.
- **D5 — folding**: clip options folded by default, with a pill when a hidden setting is not neutral; FX link
  unfolded by default; one global memory for the session; the DOUBLE CLICK opens / closes, on the clip AND on
  the FX link; renaming the FX link moves to ⌘R (→ N1: ⌘R is taken).
- **D6 — sends below**: reverse order (nesting), the "+ Send to…" button kept, moved by the box AND by the
  source point.
- **D7 — frame**: objects, groups and auxes; NOT in the stem / Main popover.
- **D8 — section F accepted**, except "engine gains kept", replaced by D1.

---

# A. What exists (verified in the code at `e2aea50d`)

| Element | Where it is drawn / lives | Model / engine |
|---|---|---|
| Layout engine (pure) | `Inspector/Synoptic/SynopticLayout.swift` (`measure`, `place`, `diagram`) | — |
| Graph types (pure) | `Inspector/Synoptic/SynopticGraph.swift` (`SynopticNode`, `SynopticPlugin`, `SynopticFXLink`, `SynopticSend`, `SynopticSendSlot`) | — |
| The view, all of it | `Inspector/Synoptic/SynopticView.swift`, **3891 lines**: `SynopticActions` (l.46), `SynopticView` + canvas + `draw` (l.360–954), `FXBlockHeaderView` / `FXBlockMixView` (956–1236), `SynopticCardView` (1240), drop delegates, `ParallelBranchButton` (1686), `GainDbControl` (1754), `DragValueBox` (1814), `AudioFileZoneView` (2012), `ClipMixZoneView` (2266), send rows / cards / boxes (2402–2902), `BusHeadZoneView`, `StemsZoneView`, `GroupRoutingZoneView`, `SynopticBoundView` (3128–3800) | — |
| Pre/post-FX gains ("trims") | `SynopticLayout.diagram` → `chainInGain` / `chainOutGain` (`chainGainGap` 56 pt); `GainDbControl` in the canvas l.604–622 | see A.1 |
| "+" (series insert) | canvas l.547–571: a `Button` per `InsertZone`, always visible; right click on a trunk "+" = "Send here" | `onInsertSeries` → browser sheet → `synopticInsert` (SynopticModelMapping.swift l.122) |
| Parallel branch icon | `ParallelBranchButton` at `+.x + 26` (element AFTER the "+") | `synopticBranch(objectID:elementID:)` |
| Clip options | `AudioFileZoneView`: title (loop · reverse), channel mode (stereo), speed, semitones, bpm | `speedRatio`, `baseBPM`, `channelMode`, `isReversed`, `loopEnabled` |
| FX link block | header card, body, mix box `FXBlockMixView` (pan · volume −96…+40 · mute) | see A.1 |
| FX link name | `uniqueFXLinkName(nil)` → "FX link N" (`EditViewModel+FXLinkEdit.swift` l.141), from `createFXLink`, `createEmptyFXLink`, `copiedRun` (`+FXLinkAuto.swift` l.68) | `FXLink.name` |
| Diagnostic | `ObjectInspectorView.swift` l.86–103, key `inspector.diagnostic` | dead `SynopticActions.onDiagnose` (l.3336 of the view) |
| Send cards | a column RIGHT of the trunk, wires to the right, three `SendSlotDropView` | `AuxSend` (`tap`, `plugins`), `ObjectPlugin.sendMarker` |
| Plugins on a send | `SendBoxView` + `SendPluginRowView` 22 pt rows | `AuxSend.plugins` |
| Object frame | none | colour = `customColor ?? stemColor(for:)` |
| Hosts | inspector (`ObjectInspectorView` l.89) and the stem / Main popover (`StemStripsToolbarView` l.697) | — |
| ⌘R | `Timeline/TimelineKeyHandler.swift` l.895: ⌘R renames the ONE selected object, else the selected annotation (marker / region / comment) | **taken** (→ N1) |

## A.1 The engine and model map of what D1 removes (complete grep, `OBJEngineCore.mm` / `.h` and Swift)

**Engine trims.** `ObjectChain.trimIn` / `.trimOut` (`te::Plugin::Ptr`, struct l.~475), created ONCE per compiled
chain by `ensureTrim` in `compileUserRackForObjectID:…chainInDb:chainOutDb:` (l.8686–8691), never destroyed:
`[ channel mode? | instrument? | trimIn | FX… | trimOut | fader | window-fade | sends… ]`. Readers:
- `userInsertIndexForKey:in:` l.3028 (`indexBefore(pl, trimOut)`, then fader, stem gain, master anchor, end);
- `compileSeries:… anchor:chain.trimOut` (l.~8697);
- `applySendPositionsForKey:` l.4949–5084 (`input` = before trimIn — before the fader when no chain is
  materialised —, `preFader` = after trimOut, `endAnchor`, `prev = trimIn`);
- the send-layout roles audit l.5346–5373 and l.8749–8750 (roles `trimIn` / `trimOut`), mirrored in Swift by
  `SendMarkerAudit.swift` (l.115–161) and asserted by `tools/test_send_position.swift` l.506 and
  `tools/scenario_bridge_sends.py` l.1310–1321;
- `setMasterStemKey:` l.3100–3101 (the MAIN has trims too: purged with the master chain);
- the ARA / channel-mode comment l.3487 ("Index 0: BEFORE trimIn");
- `setChainGain…` l.8811 (+ `debug.set_chain_gain`, Commands+Plugins.swift; used 8× by `scenario_bridge_sends.py`);
- automation targets `OBJAutomationTargetTrimIn/TrimOut` (`.h` l.512–513, `.mm` l.8843–8846);
- l.8357–8371, 8410, 8718 (compile bookkeeping).

**Engine FX output.** `fxOutputKey(block) = block+"#fxout"` (l.561); `parseCompileSeries` appends an `isGain`
node after a `kind:"fxlink"` block's leaves (l.505–580); `compileSeries` applies it (l.~8434–8448:
`setGainDb`, `setPan`, `setEnabled`); a setter l.8797; the send mini-chain filter `!n.isGain` (compile).

**Master anchor — KEPT, it is not a user gain.** `_masterAnchorGain` (l.1530) is a NEUTRAL 0 dB `ObjGain`
laid once at the head of the master list (`setMasterStemKey:` l.3112–3118); the Main's user chain is inserted
BEFORE it so the master VU stays post-FX (`userInsertIndexForKey` l.3038). It carries no user value, nothing
to migrate. The stem fader `_stemGainMap` (l.1521, the stem strip's volume) is the stem's OUTPUT stage: KEPT.

**Sidechain / bridge.** Grep: no bridge, sidechain or tap code reads `trimIn`, `trimOut` or the master anchor.
The sidechain tap sits at the END of the source's chain (post-fader, post-window); sends are placed ONLY by
`applySendPositionsForKey:`. So D1 touches the bridge exactly at the send positions (B.0.4), nowhere else.

**Three `ObjGainPlugin` traps that decide the new plugin's class** (all `dynamic_cast<te::ObjGainPlugin*>`):
- `setMasterStemKey:` l.3114 `findFirstPluginOfType<te::ObjGainPlugin>()` — re-adopts the anchor after a
  reload: a user stage of that class at the master's head would be ADOPTED AS THE ANCHOR;
- `renderObjectToFileAsync:` l.4052 `bypassTail` — DISABLES every `ObjGain` of the ancestors' lists, and of the
  target's own list when `!keepOwnTail` (so today's trims are bypassed in those bakes: → N3);
- l.7053 the consolidate-edit live listener skips `ObjGain` as a "system plugin".
**⇒ the gain stage must NOT be an `ObjGainPlugin` nor a subclass of it.**

**Swift side.** `SoundObject.chainInGainDb/chainOutGainDb` (objects; encoded only ≠ 0, l.1338 / 1392) and the
same on stems (l.47–48, 66, 80, 90–91); `needsChainCompile` l.659–662; `ParamRef.chainInGain/.chainOutGain`
(`Automation.swift` l.23–119, −24…24 dB, "trim in/out"); `fallbackAutomationOrder` (~l.964),
`resolvesAutomationTarget`; `EditViewModel+Plugins` (`chainGains`, `setChainGainModel`, `setChainGain`,
`compileRack(chainInDb:chainOutDb:)`, `diagnosticPluginStates`); `+Automation` (l.75, 157, 339–340, 403–404);
`+AutomationEngine` (l.42–43); `+Consolidate` l.659; `SessionSchema.swift` l.135 (and `formatVersion = 24`
l.21); `CrossProjectImport.swift` l.249 (and the sidecar freezing an attached block's output into `local`);
`FXLink.swift` (`FXLinkOutput`, `FXLink.gainDb/pan/muted`, `output`, `FXLinkBlock.local`); FX output readers
in `+FXLink`, `+FXLinkEdit`, `+FXLinkUI`, `+Bake`, `Commands+FXLink` (`fxlink.set_output`,
`fxlink.set_local_output`), `Commands+Plugins`, `SynopticGraph` (`SynopticFXLink`), `SynopticView`.
Decoders of a stored object: `EditViewModel+Project.swift` l.446 (the session) and
`EditViewModel+ProjectPaths.swift` l.150 (a stored SUBTREE: the consolidate sidecar).
Tests using them: `scenario_fxlink.py` (14 calls), `scenario_fxlink_drag.py` (l.231, 472),
`scenario_bridge_sends.py` (8× `set_chain_gain` + the roles), `test_send_position.swift`,
`test_synoptic_send_cards.swift`, `test_cross_project_import.swift`.

---

# B. Design

## B.0 Migration and engine (D1) — the risky part

### B.0.1 The gain stage plugin (`objekat/OBJGainStagePlugin.h`, app code, no engine patch)

- A NEW class `ObjGainStagePlugin : public te::Plugin` (NOT derived from `ObjGainPlugin`, A.1), registered
  under TWO type names — `objGainStage` (face "gain") and `objGainPanMute` (face "gain+pan+mute") — with ONE
  identical parameter list so `OBJParamMirror` (match by INDEX) can never mismatch: index 0 `gain` (dB), 1 `pan`
  (−1…1), 2 `mute` (0/1, stepped).
- DSP: a VERBATIM copy of `ObjGainPlugin`'s gain / pan / mute-ramp processing (comment: "mirror of
  ObjGainPlugin::applyToBuffer — keep in step"), so a migrated trim is the SAME arithmetic at the same place.
  The smoother is set to its target on creation and on state restore (`setCurrentAndTargetValue`), or a
  migrated render would ramp from 0 dB over its first milliseconds.
- **Engine range of `gain`: −24…+24 dB, LINEAR** (→ N2). It holds every legacy trim exactly (their range was
  −24…24) and gives a plugin-automation curve (stored 0…1, denormalised by the engine's range) a readable
  scale. The HAND is clamped to ±20 dB (D2) — the box's range — a stored value outside ±20 is shown as it is.
  A legacy FX output outside ±24 (that range was −96…+40; mute is separate) is CLAMPED at migration and the
  load reports it (→ N2).
- Registered beside `ObjGainPlugin` (`createBuiltInType`, l.~1723); NOT in `tracktionBuiltInPluginList`
  (never in the browser); `openBuiltInPluginEditor` refuses it; no sidechain input; "no bypass": the card has
  no power button and `plugin.toggle` / `toggle_selected` skip / refuse it (`invalid_state`, `gain_stage_no_bypass`).
  A bin's common on/off still bypasses it with the rest of the bin (as it did `#fxout`).
- In the MODEL it is an ordinary `ObjectPlugin` leaf (`formatName "TracktionInternal"`, `identifier`
  `objGainStage` | `objGainPanMute`, name "Gain" | "Gain · Pan"): copies, cut, `copiedPlugins` → FX link
  auto-creation, cross-project paste, consolidate / bake, state capture / undo, id audit, sends' mini-chains,
  FX link definitions (mirrored), automation (`ParamRef.plugin`) — all existing walkers, no new code. It counts
  in the 20-entry engine list (`chainFull`).

### B.0.2 Migration (`objekat/SoundObject/LegacyGainMigration.swift`, PURE)

```swift
enum LegacyGainMigration {
    struct Report: Equatable { var trims = 0, fxOutputs = 0, automationLanes = 0, clamped = 0 }
    static func migrate(_ doc: inout ProjectDocument) -> Report     // objects, groups (recursive), stems, Main,
                                                                    // consolidate definitions, FX link registry
    static func migrate(_ subtree: inout SoundObject) -> Report      // a sidecar subtree (no registry)
}
```
- **Presence-driven, idempotent**: it acts when a legacy key was DECODED (the decoders keep reading
  `chainInGainDb` / `chainOutGainDb` / `gainDb` / `pan` / `muted` / `local` into a transient `legacy…` value
  that is never encoded), whatever the file's format number; a second run finds nothing.
- Object or stem / Main chain: `trimIn ≠ 0` OR a `chainInGain` lane with points → a NEW `objGainStage` leaf
  INSERTED AT ARRAY INDEX 0 of `plugins` (before every plugin AND every `sendMarker`); `trimOut` likewise →
  APPENDED at the END of `plugins` (after every trailing marker). Index placement is what keeps the sound of
  in-chain sends: a marker that sat after trimIn stays after the pre stage, one that sat before trimOut stays
  before the post stage (B.0.4).
- A trim at 0 dB with NO curve → nothing (a neutral trim was inaudible).
- Automation: the `chainInGain` lane becomes `ParamRef.plugin(<stage id>, gain)`, each point's dB mapped to
  `(dB + 24) / 48` (exact: linear range, B.0.1); `automationTouchOrder` entries re-aimed the same way.
- FX link (definition in the registry): output not neutral (`gainDb ≠ 0 ∨ pan ≠ 0 ∨ muted`) → an
  `objGainPanMute` DEFINITION leaf appended at the end of the bin's `plugins` (gain, pan, mute in its state),
  and in EVERY attached host's block an instance of it (fresh id, `linkGroupID` = the definition's id) appended
  at the end of the block's instances — i.e. exactly what "add a stage to a bin" does live. A DETACHED block
  with a non-neutral `local` → an independent `objGainPanMute` at its end. `FXLink.isEnabled` is untouched.
- Fresh UUIDs (never derived from an existing id: the plugin-id uniqueness rule).
- Called in ONE funnel per decoder: the session (`EditViewModel+Project.swift` l.446, before
  `PluginIDUniqueness` detection) and the sidecar subtree (`+ProjectPaths.swift` l.150). The load journals it
  and `project.load_status.last_load` gains `legacy_gain_migration: {trims, fx_outputs, automation_lanes,
  clamped}`. **The load stays CLEAN** (not dirty): nothing changed to the ear; a later save writes format 25.
- Session format **24 → 25** (`SessionSchema.formatVersion`, `_readme`: the gain stage, the end of trims and FX
  outputs, the FX link's name source, B.0.6). An old build opening a format-25 file will not know
  `objGainStage` (accepted, forward incompatibility as for every bump).

### B.0.3 Engine removal

- `ObjectChain.trimIn/trimOut`, `ensureTrim`, `setChainGain`, the two automation targets, the `chainInDb` /
  `chainOutDb` parameters of `compileUserRackForObjectID:` (ObjC + Swift caller), the master purge lines
  l.3100–3101, the `isGain` node and `fxOutputKey`, the FX output setter: DELETED.
- `compileSeries:… anchor:` receives `[self userSegmentEndAnchorForKey:key in:*pl]` (fader → stem gain →
  master anchor → nullptr = append; the fader may not exist yet on a first compile, which `installObjectChainTail:`
  appends after, same as today's fallback).
- `userInsertIndexForKey:in:` loses its trim branch (fader → stem gain → master anchor → end).
- Done when `grep -n 'trimIn\|trimOut\|fxOutputKey\|isGain\|TrimIn\|TrimOut' objekat/OBJEngineCore.*` is empty.

### B.0.4 Send positions re-anchored, same sound

In `applySendPositionsForKey:` (the ONE place sends are placed):
- `input` = immediately BEFORE the first entry of the user segment = the first plugin of `chain.rootOrder`
  present in the list (plugins and `@sender|aux` tokens); none → before the fader (today's "no chain" rule).
  Channel mode / instrument stay before it (they were before trimIn).
- `preFader` = immediately BEFORE the fader (after every user entry, the post stage included).
- `chain(i)` unchanged (markers in the model).
**Why it sounds the same.** Old `input` tapped before trimIn; the pre stage is now the user segment's first
entry and `input` sits before it → same signal. Old `preFader` tapped after trimOut; the post stage is the last
user entry and `preFader` sits after it → same signal. In-chain markers keep their side of each stage (B.0.2).
Bridge send plugins COPY the signal and do not alter it, so their mutual order at one boundary is inaudible.
Roles audit (l.5346, 8749), `SendMarkerAudit.swift` and the tests asserting roles lose `trimIn` / `trimOut`
(the segment boundaries are reported as `segmentStart` / `segmentEnd` indices instead).

### B.0.5 API changes (all in `command_api.md`)

- DELETED: `debug.set_chain_gain`, `fxlink.set_output`, `fxlink.set_local_output` (and the output fields of
  `fxlink.*` / `plugin.list` payloads).
- NEW `plugin.add_gain_stage {host, face: "gain"|"gain_pan_mute", series?: "root"|{voice:{block,index}}|{block}|{send: aux}, index?, gain_db?, pan?, muted?}`
  → the plugin payload; the SAME view-model door as the gesture (`insertGainStage`), `undo: .handled`;
  refusals `chainFull`, unknown series, `gain_db` outside ±20.
- NEW `plugin.gain_stage {plugin}` → `{face, gain_db, pan, muted}`; writes through the existing
  `plugin.set_param` (indices 0 / 1 / 2).
- `plugin.list` rows gain `gain_stage: "gain"|"gain_pan_mute"|null`.
- `project.load_status.last_load.legacy_gain_migration` (B.0.2).

### B.0.6 FX link name source (model part, lands with the format bump)

`FXLink` gains `nameSourceID: UUID?` (the object whose name it follows) and `userNamed: Bool` (both optional
keys, format 25). Behaviour in L3 (B.9).

## B.1 (moved to B.0.1)

## B.2 The "+" gestures (pure classifier)

A pure unit `Inspector/Synoptic/SynopticPlusGesture.swift`:

```swift
enum PlusGestureResult: Equatable { case none, gain, gainPanMute, branch, send }
static func classify(_ translation: CGSize, allowed: Set<PlusGestureResult>) -> PlusGestureResult
```
Under 6 pt = a CLICK (the browser, as today). θ from the horizontal, positive upward; `dx ≤ 0` → none;
|θ| < 15° → `dx` 6…80 pt `.gain`, ≥ 80 pt `.gainPanMute`; θ ≤ −15° `.branch`; θ ≥ +15° `.send`; a result not in
`allowed` → `.none` (the ghost says "not here").

| "+" of… | gain | gain+pan+mute | branch | send |
|---|---|---|---|---|
| the trunk | yes | yes | yes (D3) | yes, at that position (B.6) |
| a parallel branch | yes | yes | yes | no |
| an FX link's series | yes (joins the DEFINITION) | yes | no | no |
| a send's mini-chain | yes | yes | no | no |
| the wire mixer → stems (new "+") | no | no | no | yes, post-fader (D2) |

Branch (D3): the element under the "+"; tail "+" → the element above; empty chain → refused (not in `allowed`).
A ghost while dragging; `.send` opens the existing "Send to…" menu with that "+"'s slot; one undo per gesture.

## B.3 The "+" on hover (pure hit test)

`SynopticLayout` gains `insertHoverRects` and a pure `insertZone(at:)`; ONE `.onContinuousHover` sets
`hoveredInsert`; a "+" shows when hovered, OR its series is empty, OR a drag is in flight from it. The "+"
becomes a `DragGesture(minimumDistance: 0)` view whose rect joins the marquee's `blockers`.
`ParallelBranchButton/Glyph` are deleted; the right click "Send here" stays.

## B.4 The gain stage's card

A face of `SynopticCardView`, card height: `.gain` = grip · `DragValueBox` dB (±20, double click / ⌫ = 0 dB) ·
✕ on hover; `.gainPanMute` = pan · volume · mute (the old mix box as a card, width `fxMixW`). No power button.
Values read from the engine (`gainStageValues(pluginID)`), written through `setPluginParam` with an undo point
at the drag's start; a parameter with a curve greys its box; touching names the automation row.

## B.5 The object frame (D7)

`Diagram.objectFrame` for an OBJECT host — clip, MIDI, group, aux — (nil for the stem / Main popover): from the
head zone's midline to the mixer's midline, full content width + `fxPad`, drawn like an FX link body (fill 0.10,
1.5 pt stroke, corner 12) in `customColor ?? stemColor`; head and mixer opaque, straddling. The trims' 56 pt
gaps go for good (there are no trims any more).

## B.6 Sends below the stems, wired by the left (D6)

Boxes stacked BELOW the stems / group-routing zone, left-aligned on the frame; the send tapped HIGHEST takes the
OUTERMOST left gutter and the LOWEST box (nesting → no crossing); "+ Send to…" at the bottom of the stack.
Wire: tap dot → left, out of the frame → down the gutter → into the box's top row. Moving: the box (today's
`sendDragProvider`) AND the tap dot (same `SendDragPayload`). Slot of each "+": head ≡ `.input`, tail ≡
`.preFader`, between i−1 and i ≡ `.chain(i)`, mixer → stems ≡ `.postFader`. Plugins on a send = real cards
(request 11), hover "+" with gain gestures only, the send's line at the box's bottom.

## B.7 Folding (D5)

- State: `SynopticUIState` (NEW `@Observable` app-wide object, session memory, not saved, not in undo):
  `clipOptionsExpanded: Bool = false`, `collapsedFXLinks: Set<UUID> = []` (unfolded by default),
  `renamingFXLinkID: UUID?` (B.9).
- Clip zone folded: one row — title, loop, reverse, chevron — plus a pill when a hidden option is not neutral
  (`−3 st`, `×1.07`, `L`, `→ 120`). A DOUBLE CLICK anywhere on the zone except a value box (where double click is
  already "reset") toggles; the chevron too.
- FX link: chevron in the header; a DOUBLE CLICK on the header (its name included — rename moves to ⌘R / the
  menu) toggles; folded = header + a one-line body ("3 plugins"), the wire runs through, a drop on the header
  lands at the bin's end.

## B.8 FX link without output section

`FXBlockMixView` and its geometry go; the body ends `fxPad` under the series' tail "+". A quick gain on a bin =
a stage dragged from the bin's own "+" (joins the definition, mirrored).

## B.9 FX link name (D4) and its renaming (D5, → N1)

- Creation: `createFXLink(from:)` / `createEmptyFXLink(on:)` → the host's `displayName` (a stem → its name),
  `nameSourceID` = host; `createFXLinkFromObjects` → the FIRST object in time; `copiedRun` → the copied
  object (source = the ORIGINAL). Explicit `name:` (API) → `userNamed = true`. Empty name → "FX link N".
- Uniqueness: `uniqueFXLinkName(base, excluding:)` → "Kick", "Kick 2", "Kick 3"…
- Following: in `renameObject(id:label:)` (EditViewModel.swift l.1559) and the stem rename door, every bin with
  `nameSourceID == id && !userNamed` is renamed through the same uniqueness (same undo point as the rename). A
  composed group name that changes because its CHILDREN changed is not a rename: not followed. Source deleted →
  the name freezes.
- Renaming by hand (`fxlink.rename`, the inline field) sets `userNamed = true` for good.
- ⌘R (→ N1, recommended): CONTEXTUAL — when the signal view holds the keyboard (`selectedPluginHostID != nil`)
  and the selection designates ONE bin (its header clicked, or every selected card inside one bin), ⌘R sets
  `SynopticUIState.renamingFXLinkID`; otherwise ⌘R does what it does today. Plus a "Rename" entry in the
  header's context menu (discoverable path).

## B.10 Diagnostic

Button, row and key `inspector.diagnostic` go; dead `onDiagnose` goes; `diagnosticPluginStates` stays.

---

# C. Implementation lots

Rule for every lot: Debug build green, no new warning on a touched line, `xcstrings.py check` / `orphans`
clean, visible strings through `L()`, one commit per lot (or per numbered step inside M), attribution lines,
**nothing pushed**. **Wave rule: a lot of wave 1 never DELETES a symbol that a file of another lot uses — it
neutralises it (always nil / neutral); deletions happen in the owner's later lot or in L8.**

```
L0 (serial) ──► wave 1: M ∥ L2 ──► gate G1 (M's null test green, merged) ──► wave 2: L3 ∥ L4 ∥ L5 ∥ L6 ∥ L7 ──► L8 (serial)
```

**Does the migration lot come first? Not alone, but it GATES wave 2.** M is the riskiest lot and every UI lot
of wave 2 compiles against its door (`insertGainStage`, `gainStageValues`, the deleted fields). It runs in
wave 1 in parallel with L2 (disjoint files) and must be merged with its null test green (gate G1) before wave 2
starts. Its engine and model commits (M.1–M.3) may start at once, before L0; only M.4 (which edits
`SynopticBoundView.swift`, moved by L0) waits for L0. Recommended model for M: Opus (refactor across engine,
model and API).

### L0 — split `SynopticView.swift` (SERIAL, ~1 h, no behaviour change)

Pure moves (synchronized folders: no pbxproj edit): `SynopticActions.swift` (actions + small structs + View
helpers, l.6–356), `SynopticFXBlockViews.swift`, `SynopticCardViews.swift`, `SynopticZoneViews.swift`,
`SynopticSendViews.swift`, `SynopticBoundView.swift`; `SynopticView.swift` keeps the canvas. Plus B.10 (the
diagnostic: `ObjectInspectorView.swift`, `Localizable.xcstrings`). Gate: build + `test_synoptic_*` green.

### Wave 1

**M — gain stage, migration, removal of trims and `#fxout` (engine + model + API).** Commits:
- **M.1** `OBJGainStagePlugin.h` (NEW), registration and editor refusal in `OBJEngineCore.mm`;
  `EditViewModel+GainStage.swift` (NEW: `isGainStage`, `gainStageFace`, `insertGainStage(host:series:index:face:values:)`,
  `gainStageValues`, the no-bypass guard); `Commands+GainStage.swift` (NEW) + one line in `CommandRegistry.swift`;
  `gain_stage` in the `Commands+Plugins.swift` payload; `tools/scenario_gain_stage.py` (NEW).
- **M.2** `LegacyGainMigration.swift` (NEW, pure) + the legacy decode-only keys in `SoundObject.swift`
  (objects and stems) and `FXLink.swift` (+ `nameSourceID` / `userNamed`, B.0.6); the two call sites
  (`EditViewModel+Project.swift`, `EditViewModel+ProjectPaths.swift`); the load report; `SessionSchema.swift`
  format 25 + `_readme`; `tools/test_legacy_gain_migration.swift` (NEW).
- **M.3** engine removal and re-anchoring (B.0.3, B.0.4) in `OBJEngineCore.h/.mm`; `SendMarkerAudit.swift`;
  `tools/test_send_position.swift` (roles).
- **M.4** Swift removal: `SoundObject.swift`, `FXLink.swift` (stored fields go, decode-only keys stay),
  `Automation.swift` (`ParamRef.chainInGain/.chainOutGain` stay DECODABLE for M.2 only, never produced),
  `EditViewModel+Plugins / +Automation / +AutomationEngine / +Consolidate / +Bake / +FXLink / +FXLinkEdit /
  +FXLinkUI.swift`, `CrossProjectImport.swift` (no more freezing into `local`), `Commands+FXLink.swift`,
  `Commands+Plugins.swift` (`debug.set_chain_gain`); NEUTRALISE in `SynopticBoundView.swift` and
  `SynopticModelMapping.swift` (no trim closures wired, `SynopticFXLink` fed neutral values);
  `tools/test_cross_project_import.swift`.
- **M.5** tests and docs: `tools/scenario_gain_migration.py` (NEW, the null test, D.3);
  `scenario_fxlink.py` and `scenario_fxlink_drag.py` (output proofs rewritten as a `gain_pan_mute` stage in the
  bin, same RMS expectations); `scenario_bridge_sends.py` (§Q2 and the 8 `set_chain_gain` calls → stages via
  `plugin.add_gain_stage` + `plugin.set_param`; the roles check l.1310); `docs/command_api.md`.
- **M.6** (verification, no code unless it finds something) the bake check of N3, reported in the journal.

**L2 — the pure layer.** `SynopticLayout.swift` (hover rects, frame, sends below + gutters, post-fader "+",
folded zone heights, folded FX block, no mix box, gain-stage card widths; `chainInGain/chainOutGain` kept as
ALWAYS-nil properties, deleted in L8), `SynopticGraph.swift` (ADD `SynopticPlugin.gainStage`, keep
`SynopticFXLink`'s output fields until L8), NEW `SynopticPlusGesture.swift`, `SynopticActions.swift` (the
wave-2 contract: `onPlusGesture(seriesID, index, PlusGestureResult)`, `onSetGainStage(pluginID, gain?, pan?,
muted?)`, `onToggleClipOptions`, `onToggleFXFold(blockID)`, `onRenameFXLink`, optional, default nil),
`SynopticSendMapping.swift`, `SendDrop.swift` if needed, NEW `objekat/Inspector/Synoptic/SynopticUIState.swift`
(B.7); tests: rewrite `test_synoptic_fxblock.swift` and `test_synoptic_send_cards.swift` (list of dropped
assertions in the lot report), NEW `test_synoptic_object_frame.swift`, NEW `test_synoptic_plus_gesture.swift`.

### Wave 2 (after G1)

- **L3 — FX link name and ⌘R** (B.9): `EditViewModel+FXLinkEdit.swift`, `EditViewModel+FXLinkAuto.swift`,
  `EditViewModel.swift` (the follow hook in `renameObject`; the stem rename door if it lives elsewhere, named in
  the report), `Timeline/TimelineKeyHandler.swift` (contextual ⌘R, → N1), `Commands+FXLink.swift` (`userNamed`
  in payloads), `scenario_fxlink.py` (names).
- **L4 — the canvas** (`SynopticView.swift`): frame, hover "+" + drag + ghost + blockers, branch icon gone, trims
  call sites gone, left-gutter wires, tap dot as drag source, post-fader "+", mix-box call gone, gain-stage
  cards dispatched.
- **L5 — the zones** (`SynopticZoneViews.swift`): folded / unfolded clip zone, pill, double click, opaque
  straddling head and mixer.
- **L6 — FX block + cards** (`SynopticFXBlockViews.swift`, `SynopticCardViews.swift`): header chevron + double
  click = fold, inline rename driven by `renamingFXLinkID`, "Rename" menu entry, folded body, `FXBlockMixView`
  deleted, gain-stage card faces.
- **L7 — the sends' views** (`SynopticSendViews.swift`): plugin cards in the box, hover "+" (gain gestures).

### L8 — integration (SERIAL)

`SynopticBoundView.swift` (closures → M / L3 doors, gain-stage values, fold state, slot of each "+"), deletion
of the neutralised symbols (`diagram.chainInGain/OutGain`, `SynopticFXLink` output fields, dead i18n keys such
as the trims' and the branch button's help), `StemStripsToolbarView.swift` untouched (no frame there, D7),
`CLAUDE.md` entry, `architecture_decisions.md` (no more trims nor FX output; gain stage = leaf; send anchors =
segment bounds), `glossary.md` (étage de gain / gain stage / etapa de ganancia), the full plan D.

### Parallelism, how

Wave 1: M ∥ L2; wave 2: L3 ∥ L4 ∥ L5 ∥ L6 ∥ L7; no file owned twice in one wave (checked against the lists
above: `EditViewModel+FXLinkEdit.swift` and `Commands+FXLink.swift` are M's in wave 1 and L3's in wave 2;
`SynopticBoundView.swift` is M's in wave 1 (neutralise only) and L8's). Each agent in its own APFS clone
(`cp -c -R objekat objekat-Lx`), branch `feat/synoptic-rework-Lx`, its own `-derivedDataPath
/tmp/objekat-dd-Lx`; the integrator merges with `--no-ff` and builds once.

---

# D. Test plan (budget ≤ 10 min of EXECUTION; builds excluded)

## D.1 Builds (not counted)

```sh
cd /Users/nicolasvair/Documents/Xcode/Objekat/objekat
xcodebuild -project objekat.xcodeproj -scheme objekat -configuration Debug \
  -derivedDataPath /tmp/objekat-dd-synoptic build 2>&1 | grep -E "error:|warning:|BUILD" | sort | uniq -c | tail -40
APP=/tmp/objekat-dd-synoptic/Build/Products/Debug/objekat.app
python3 tools/i18n/xcstrings.py check && python3 tools/i18n/xcstrings.py orphans
```
**The BASE app for the null test** (built once, outside the budget). First choice: the archive
`"/Users/nicolasvair/Documents/Xcode/Objekat/historique builds/objekat 2026-10-12 12-15-59.app"`, accepted only
if a project it saves carries `"formatVersion": 24` (the scenario checks and refuses otherwise). Fallback:
```sh
cp -c -R /Users/nicolasvair/Documents/Xcode/Objekat/objekat /tmp/objekat-base
cd /tmp/objekat-base && git checkout --detach e2aea50d && git submodule update
xcodebuild -project objekat.xcodeproj -scheme objekat -configuration Debug -derivedDataPath /tmp/objekat-dd-base build
BASE=/tmp/objekat-dd-base/Build/Products/Debug/objekat.app
```

## D.2 Pure tests (~2.5 min, in parallel)

```sh
cd /Users/nicolasvair/Documents/Xcode/Objekat/objekat/tools
S=../objekat/Inspector/Synoptic
( swiftc -parse-as-library -o /tmp/t_plus  $S/SynopticPlusGesture.swift test_synoptic_plus_gesture.swift && /tmp/t_plus ) &
( swiftc -parse-as-library -o /tmp/t_frame $S/SynopticGraph.swift $S/SynopticPlusGesture.swift $S/SynopticLayout.swift test_synoptic_object_frame.swift && /tmp/t_frame ) &
( swiftc -parse-as-library -o /tmp/t_fx    $S/SynopticGraph.swift $S/SynopticPlusGesture.swift $S/SynopticLayout.swift test_synoptic_fxblock.swift && /tmp/t_fx ) &
( swiftc -parse-as-library -o /tmp/t_sc    $S/SynopticGraph.swift $S/SynopticPlusGesture.swift $S/SynopticLayout.swift test_synoptic_send_cards.swift && /tmp/t_sc ) &
( swiftc -parse-as-library -o /tmp/t_sd    $S/SynopticGraph.swift $S/SendDrop.swift test_send_drop.swift && /tmp/t_sd ) &
( swiftc -parse-as-library -o /tmp/t_mq    $S/SynopticMarquee.swift test_synoptic_marquee.swift && /tmp/t_mq ) &
wait
# model-level tests: the exact source list is in each file's header (same list as test_cross_project_import.swift)
for t in test_legacy_gain_migration test_cross_project_import test_send_position; do
  sed -n '1,20p' $t.swift | grep -A8 "swiftc" ; done   # read the line, then run it
```
What they assert (beyond the unchanged ones):
- `test_legacy_gain_migration` (NEW): trim in −6 → a stage at index 0 with −6, BEFORE an existing marker;
  trim out +3 → a stage at the end AFTER a trailing marker; 0 dB without a curve → nothing; 0 dB with a curve →
  a stage; the curve's points mapped `(dB+24)/48` and the `ParamRef` re-aimed (touch order too); a stem and the
  Main; a group's children recursively; a consolidate definition; an FX link: one definition leaf +
  one linked instance per ATTACHED host, a detached `local` → an independent stage; `isEnabled` kept; an output
  of −40 dB clamped to −24 and counted; idempotence (second run = empty report, identical document); every new
  id fresh (uniqueness audit on the result); the encoded result contains none of the legacy keys.
- `test_send_position`: roles without `trimIn` / `trimOut`; `segmentStart` / `segmentEnd`.
- `test_cross_project_import`: no output freezing; a stage travels as a leaf.
- `test_synoptic_plus_gesture`, `test_synoptic_object_frame`, `test_synoptic_fxblock`, `test_synoptic_send_cards`:
  as in revision 1 (thresholds and ±15° both sides, `dx ≤ 0`, `allowed`; frame bounds, straddling, stems and
  sends outside, no frame for a bus host, no 56 pt gap; no mix rect, folded block; boxes below in nesting order,
  NO two wires cross for 1–6 sends at every slot mix, card rows `insertIndex(at:)`), plus: the mixer → stems "+"
  allows `.send` only; branch on an empty chain → none.

## D.3 Headless scenarios (~7 min; each on its OWN fresh instance, `--no-recent`)

```sh
APPX=$APP/Contents/MacOS/objekat
$APPX --headless --api --no-recent --no-audio --language=en --socket=/tmp/ogs.sock & sleep 4
time python3 tools/scenario_gain_stage.py /tmp/ogs.sock                       # NEW, ~90 s
kill %1
time python3 tools/scenario_gain_migration.py $APP --base-app "$BASE" /tmp/trial_gm   # NEW null test, ~2 min, audio ON, launches both apps itself
$APPX --headless --api --no-recent --no-audio --language=en --socket=/tmp/ofx.sock & sleep 4
time python3 tools/scenario_fxlink.py /tmp/ofx.sock                           # ~80 s
kill %1; $APPX --headless --api --no-recent --no-audio --language=en --socket=/tmp/ops.sock & sleep 4
time python3 tools/scenario_plugin_selection.py /tmp/ops.sock                 # ~40 s
kill %1
time $APPX --headless --no-recent --no-audio --language=en --exec=tools/smoke.jsonl
time python3 tools/scenario_send_plugins_reopen.py $APP /tmp/trial_spr        # ~60 s
```

**`scenario_gain_migration.py` — the null test (D1's proof).** Both apps headless, `--api --no-recent
--language=en`, **audio ON** (no `--no-audio`: sends ride the bridge's device clock; exit 2 if
`app.info.audio_running` is false), exports 48 kHz / 24-bit with the same options on both sides, re-read in
24 bits. Fixture built THROUGH THE BASE APP'S OWN API, sections laid at distinct times on a generated 1 kHz +
noise source (`bridge_scenario_common`), a built-in compressor with strong settings in each chain (a
non-linear stage, so a gain moved to the wrong side of it CHANGES the output):
1. trims −6 / +3 around the compressor; 2. trim in with a ramp curve (−18 → +6; the lane injected into the saved
JSON by the script, in the shape `Automation.swift` encodes, since the API has no automation door); 3. an FX
link on two objects, output −4.5 dB / pan 0.25, one member DETACHED with a local −6 / muted; 4. a stem with
trims −3 / +2 and the Main with trim in −1; 5. five senders with trims −12 / +6 around the compressor, one per
tap: `input`, `chain(0)`, `chain(n)`, `pre_fader`, `post_fader`, each to its own aux.
Steps: base saves (assert `formatVersion == 24`), reopens the patched file, exports REF; the new app opens it
(assert the `legacy_gain_migration` report equals what the fixture laid — trims 16, fx_outputs 2, automation_lanes 1, clamped 0; `plugin.list`
shows the stages where B.0.2 says; `debug.send_marker_audit` clean), exports NEW, saves (assert format 25, no
legacy key in the file), reopens in a fresh process, exports NEW2.
Pass: per section, max |REF − NEW| ≤ 1 LSB (24 bit) after the section's first 20 ms, and NEW2 == NEW bit for bit;
each section's RMS printed with the expected dB shift against a dry export (so a test that "passes" by silence
is caught). **If no base app is available, the scenario stops with exit 3 and the merge is blocked** (not
skippable).

**`scenario_gain_stage.py` (NEW)** — on a 1 kHz fixture, exports re-read in 24 bits: add `gain` on a clip
(`plugin.list` shows it, no window on the pid); `set_param gain −6` → −6 ± 0.05 dB; `mute` → < −90 dBFS;
`gain_pan_mute` pan −1 → right < −60 dB; `gain_db 21` refused; `plugin.toggle` refused; one undo point per add /
set, undo → null against the reference; in an FX link → every member gets an instance, a set on one moves the
others; on a send's mini-chain → accepted (wet measured only if audio is on, else a printed skip); cut → both
halves carry it; save → reopen → same values; 16 user plugins + one stage → `chainFull`; `debug.plugin_id_audit`
→ 0.

`scenario_fxlink.py` — the output-section proofs now go through a `gain_pan_mute` stage in the bin (same RMS
expectations as before); names: a bin from "Kick" → "Kick", a second → "Kick 2", renaming "Kick" to "Kik" →
"Kik" and "Kik 2", a bin renamed by hand then the object renamed → the bin keeps its name, an explicit `name` →
kept.

**Budget**: ~2.5 (pure) + ~7 (scenarios) ≈ 9.5 min, measured with `time` and written in the journal. Over 10
min → drop in this order: `scenario_send_plugins_reopen.py`, `smoke.jsonl`, `scenario_plugin_selection.py`.
NEVER drop `scenario_gain_migration.py`, `scenario_gain_stage.py`, `scenario_fxlink.py`.

**Outside the budget, REQUIRED before merging into `main`**: `scenario_bridge_sends.py <sock> <project>` in
full (audio ON; §Q2 rewritten with stages, the roles check updated), `scenario_fxlink_drag.py`,
`scenario_consolidate.py`, `scenario_cross_paste.py`, `scenario_families.py`, `scenario_sidechain.py`
(the sidechain tap must be unchanged), each on a fresh instance.

## D.4 What only the user can verify (said, not tested)

The frame and its colours on objects, groups, auxes; the straddling head / mixer; the hover "+" (no flicker);
the four drag gestures, thresholds and ghosts; the click still opening the browser; the gain-stage cards and
their automation greying; the folded clip zone, its pill, chevron and double click; the folded FX link, its
double click, ⌘R and the menu rename; the sends below and their left wires with 4–6 sends; dragging a send by its
box and by its dot; a send's plugin cards; BY EAR: an old project with trims and FX outputs, opened in the new
build, sounding the same (the null test proves the export, not the live graph); a stage's mute (no click).

---

# E. Questions

## E.1 Answered 12 October 2026 (Q1–Q8 of revision 1) — see "The user's decisions" at the top.

## E.2 New points the answers raised (to settle before M.2 / L3; the plan assumes the recommendation)

**N1 — ⌘R is already taken.** In the timeline ⌘R renames the selected object (or the selected marker / region /
comment) — `TimelineKeyHandler.swift` l.895. Options: **A (rec.)** contextual: ⌘R renames the FX link when the
signal view holds the keyboard and the selection designates one bin, otherwise as today; plus "Rename" in the
bin header's menu. B. another shortcut (⌥⌘R) for the bin. C. ⌘R always renames the bin when the inspector shows
one (changes today's object rename — not recommended).

**N2 — the stage's range vs old FX outputs.** Old trims are −24…+24 dB, an old FX output −96…+40. Options:
**A (rec.)** the stage's engine range is −24…+24 (hand ±20): trims migrate exactly, an automation curve stays
readable; an FX output outside ±24 is clamped and reported (rare: a muted output is the `mute`, not −96 dB).
B. engine range −96…+40 like the fader: nothing is ever clamped, but a stage's curve is spread over 136 dB.

**N3 — bakes.** Today a bake that drops its own tail (`keepOwnTail == false`) disables every `ObjGain` of the
object's list, trims INCLUDED, while the FX are rendered — so a trim may be absent from such a bake (M.6 will
measure it on the base build before anything is decided). The stage is a plugin and will be treated like the
FX. Options: **A (rec.)** accept: the stage behaves like any plugin in a bake (if M.6 shows the old trim was
dropped, that was an accident of its class, and the journal says which bakes now differ). B. reproduce the old
behaviour (skip pre/post stages in those bakes) — needs a marker of "migrated stage", not recommended.

---

# F. Settled by the architect (reversible, say so if not)

- The gain stage is a NEW built-in class (not an `ObjGainPlugin`), two type names, one parameter list, DSP
  copied verbatim; adding it never opens an editor.
- Migration presence-driven and idempotent, in the two decoders, load NOT marked dirty, format 25.
- Send anchors = the user segment's bounds (`input` before its first entry, `preFader` before the fader); the
  master anchor and the stem fader stay.
- Slot of each "+": head = input, tail = pre-fader, middle = chain(i), mixer → stems = post-fader.
- Hover by one `.onContinuousHover` and a pure hit test.
- Fold state and the rename target in `SynopticUIState`, app-wide, session memory; FX folds per bin id.
- The FX link name follows explicit renames only (not a group's composed name).
- `diagnosticPluginStates` stays; the `[MIXFOCUS]` logs are not touched.

# G. Risks

- **Identity of the migration** — the null test covers the export of five sections; the LIVE graph's
  equivalence is argued (same class of arithmetic, same position) and left to the ear (D.4).
- **The smoother's start**: a stage restored at −6 dB must not ramp from 0 (B.0.1); the null test's 20 ms skip
  would hide a ramp — the scenario also compares the first 20 ms and PRINTS the max (no pass / fail).
- Every `dynamic_cast<te::ObjGainPlugin*>` site (A.1) assumes "ObjGain = system plugin": a stage must never be
  one — enforced by the class, asserted by `scenario_gain_stage` (a stage on the Main survives a reload as a
  user plugin, the anchor stays neutral).
- A plugin-parameter automation shows 0…1 with no unit: a migrated trim curve loses its "dB" labels in the
  automation band (the sound is exact). A unit for the stage's `ParamRef` is a follow-up, not in this plan.
- Forward incompatibility: a format-25 file in an old build loses its stages (unknown built-in type).
- SwiftUI gesture arbitration ("+" drag vs marquee vs drop delegates) → blockers; fallback hover rectangles.
- `OBJParamMirror` by INDEX: one class, one parameter list (asserted in `scenario_gain_stage`).
- Old geometry tests rewritten: dropped assertions listed in L2's report.

# H. Journal

(empty — lot by lot: commit, build, tests and their measured durations, deviations)

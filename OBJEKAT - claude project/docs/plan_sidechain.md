# Plan — sidechain for AU/VST3 plugins (branch `feature/sidechain`)

Status: phase 0 WRITTEN (not compiled — written on a Linux machine), phases 1–3 PLAN ONLY.
Written 4 October 2026, from an architecture exploration that READ the code (the fork at
`17215d464fb`, JUCE at `37c894f83d3`, the app tree) — nothing was prototyped. The engine line
numbers below are the fork's at that commit.

## The request

> A plugin's sidechain input fed by another object's signal — a compressor on the bass keyed by
> the kick — and it has to work ACROSS stems and ACROSS groups.

OBJEKAT has no tracks a user sees, only objects, so the key source is an OBJECT (or a stem), and
the destination is a plugin in ANY chain (an object's, a stem bus's, the Main's).

## Decisions taken (4 October 2026)

| # | Question | Decision |
|---|---|---|
| D1 | Where the key is tapped | **Post-fader, post-window** — what is HEARD of the source, the point the sends tap. A pre-fader option comes later. |
| D2 | Scope | **Everything allowed** except what is impossible: the destination's own ancestors (its group, its stem, the Main) and cycles. Complex cases (aux sources…) later. |
| D3 | Cycles | **Refused.** The source menu does not offer a source that would close a loop. |
| D4 | Source kinds | Objects (clip, group, MIDI) and **stems** in the MVP. Auxes later (cycle-prone). Main never (the ancestor of everything). |
| D5 | Bake / consolidate | **Include the key sources** (built, heard by the key only, never mixed into the render) — phase 3. |
| D6 | UI | **From the plugin**: a "Sidechain" menu on the card of a plugin that has a sidechain input. |
| D7 | Rank tiers (extra hidden pool tracks) | Explained 4 October; **to confirm** — see §3.3. |

Consequences of D1 worth knowing BEFORE using it, since mute is −96 dB on the fader
(`OBJEngineCore.h:12,122`):
- a MUTED source no longer keys — the compressor stops compressing;
- SOLOING the destination silences its key too (solo pushes everything else to −96 dB). This will
  be met the first time a keyed compressor is tuned in solo; it is the argument for the pre-fader
  tap (which, the fader sitting BEFORE `ObjWindowFade`, also means pre-window — FX tails past the
  window — unless the tail is reordered window → fader).

---

## 1. What exists (read before touching anything)

**The plugin side is already complete in Tracktion.**
- `ExternalPlugin::completePluginInstanceCreation` → `enableAllBuses()`
  (`plugins/external/tracktion_ExternalPlugin.cpp:1960`); `restoreChannelLayout` (:563-610)
  re-applies a SAVED `IDs::layout` if there is one (which could keep a sidechain bus off).
- `applyToBuffer` (:1423ff) processes `max(totalIn, totalOut)` channels and zero-pads the missing
  ones; JUCE's AU host sets a render callback on EVERY input element, element 1 = sidechain
  (`juce_AudioUnitPluginFormatImpl.h:1243-1252`, :1382). So channels 2..3 of the PluginNode
  buffer ARE the AU's key.
- `Plugin::canSidechain()` (`tracktion_Plugin.cpp:238-248`): false in a rack, else
  `ins > 2 || ins > outs`. Wires (`IDs::SIDECHAINCONNECTIONS`), `guessSidechainRouting`
  (:295-331), `setSidechainSourceID` (`tracktion_Plugin.h:554`).
- `EditNodeBuilder::createSidechainInputNodeForPlugin` (:1471-1521) builds
  `ReturnNode(busID) → ChannelRemappingNode`, summed with the direct input — the sum is what aligns
  the key's latency with the main input's. `createNodeForPlugin` (:1523-1611) trims the output
  back to the main bus.

**Why the native path cannot be used as is.**
- Its sources are AudioTracks only, and OBJEKAT's tracks are scheduling compartments with no
  plugins (`trackSlotForKey:` `OBJEngineCore.mm:2121`).
- It travels through `SendNode`/`ReturnNode`, i.e. graph EDGES, and a container is a closed local
  graph (`ContainerClipNode::getDirectInputNodes/getInternalNodes` return `{}`, patch 0006): no edge
  enters or leaves a group. Inside a clip chain, a `ReturnNode` would be wired by the outer
  transform to an input nobody orders — the trap that killed `LatencyMaskingNode` (patch 0019).
- A cyclic send is dropped silently by `ReturnNode` (`tracktion_TestNodes.h:~693-705`).

**The template to follow: the aux sends.** `ObjAuxSendPlugin` (`objekat/OBJAuxSendPlugin.h`,
interface `ContainerAuxSend`, patches 0019/0022) is a PLUGIN that owns its tap buffer, filled in
the source's chain; its age at the tap is recorded at build (`createPluginNodeForList`) and the
return compensates it. A buffer held by a plugin crosses container boundaries where an edge cannot.

---

## 2. The difficulties the design answers

1. **Order.** The key must be written before it is read in the same block. The outer player is
   multithreaded across pool tracks; inside a container's `CombiningNode`, clips are processed
   sorted by START, with a `break` past the block end. Ordering per TRACK creates false cycles
   (A on T1 keyed by B on T2, C on T2 keyed by D on T1: acyclic per object, cyclic per track).
2. **Cycles** — detected in the model (D3).
3. **Latency.** Key age `L_s` at the tap, main input age `L_d` at the destination. `L_s ≤ L_d`:
   delay the key. `L_s > L_d`: the MAIN path must be delayed and that latency DECLARED at build.
4. **The window.** Outside its window a group's inner graph does not run, so its tap is not
   written: a key must read SILENCE then, never last block's buffer → a block STAMP
   (`referenceSampleRange.start`, identical across `ContainerClipNode` and `TimedNode`).
5. **One source, several readers** — no `getAndClear`; the stamp decides staleness.
6. **Export** clones the Edit and uses the same builder: works if buffers are per plugin instance.
   **Bake / consolidate** builds only `allowedClips`: key sources are absent → silent key (D5 → phase 3).
7. **Undo** (`isPatchable`): the key must be a field pushed on its own, or every key change
   rebuilds the destination object and reloads its AU.

---

## 3. The design — a key tap held by a plugin, a key reader, and rank tiers

### 3.1 The tap — `ObjKeyTapPlugin` (app) + `ContainerKeyTap` (engine interface)
- Engine-only plugin, ONE per source object/stem that keys something, appended at the tap point
  (D1: after `ObjWindowFade`, beside the aux sends — `OBJEngineCore.mm:4405-4413`). Keyed like
  `_auxSendMap`; never in the model, so no new model plugin ids (the uniqueness rule is untouched).
- Writes `{buffer, numSamples, stamp}`; its age is recorded in `createPluginNodeForList` on the
  same line as the aux send's.
- A stem's tap sits at the end of its FolderTrack plugin list.

### 3.2 The reader — `ObjKeyReturnNode` (engine)
- In `createSidechainInputNodeForPlugin`: when `sidechainSourceID` names no track
  (`findTrackForID` null), build `ObjKeyReturnNode` in place of `ReturnNode`. Everything after it
  — wires, `ChannelRemappingNode`, the sum, the AU bus handling — is reused unchanged.
- A LEAF node holding the tap's `Plugin::Ptr`: copies the tap when the stamp matches, else
  silence; runs a delay line of `max(0, L_d − L_s)`.
- The bridge sets `sidechainSourceID` to the tap plugin's `EditItemID` and calls
  `guessSidechainRouting` at each compile; the property is stripped from `stateXML` like the
  automation curves are (`objStripAutomationCurves`) — the MODEL is the authority.

### 3.3 Order — rank tiers (decision D7, to confirm)
Each object gets a RANK computed in Swift: 0 = keys nothing from anyone; r = 1 + max rank of its
key sources. Ranks cannot form cycles by construction (D3 refuses the cyclic ones first).
- **Root level:** the pool slot becomes `(stem, lane, rank)` — one line in `trackSlotForKey:`.
  A pool track of rank r > 0 gets an `ObjKeyOrderNode` whose `transform()` collects the rank < r
  markers edit-wide (the way `ReturnNode::findSendNodes` collects sends), as ORDERING-ONLY inputs.
  The track count is bounded by stems × lanes × max rank — never by the number of objects.
- **Inside a container:** `createNodeForContainerClip` splits the children into one
  `CombiningNode` per rank, rank r depending on rank < r (shared_ptr + ConnectedNode, the shape of
  `createAuxReturns`), then summed.
- **Destination on the Main:** nothing to do (everything is upstream). **On a stem bus:** an order
  wrapper on the folder's track sum, before its plugin list.
- Costs: less parallelism; changing a key can change an object's rank, hence its pool track, hence
  a graph rebuild.

### 3.4 Model, persistence, undo
- `ObjectPlugin.sidechain: SidechainSource?` = `{sourceID: UUID}` (a point field joins it with the
  pre-fader option). Session format 18 → 19, optional key.
- Ranks and taps are DERIVED, never stored, never recorded outside the undo stack (the
  `automationTouchOrder` lesson).
- `isPatchable`: a key change is pushed on its own (`setPluginSidechain:` on the bridge), like
  `automation` — no object rebuild.
- Copies (`copiedPlugins`, `deepFreshCopy`, cross-project paste): a source inside the copied set is
  remapped; one outside is kept (same project) or dropped (cross-project).
- FX link bins: the key belongs to the DEFINITION (`fxDefinition(ofInstance:on:)`); each host's
  instance gets its own reader.
- A source deleted: the key is dropped with it (same doctrine as a dangling send).

### 3.5 Scope and cycle rules (Swift, pure, testable alone)
A unit `Shared/SidechainScope.swift` — no model, no view, the reason `CutSelection`/`SendColumns`
are units — answers `allowedSources(for destination)` and `rank(of:)` from a small graph description:
- excluded: the destination's host itself, its ancestors (groups, stem, Main), auxes (D4), the Main;
- excluded: any source whose own key chain reaches the destination (D3).
Asserted by `tools/test_sidechain_scope.swift`.

### 3.6 UI (D6)
On a card whose plugin has a sidechain input (`can_sidechain`, or a second enabled input bus): a
"Sidechain" entry → a menu of the allowed sources (objects by `displayName`, stems by name), plus
"None". The card shows the chosen source's name; a key whose source has gone out of scope is shown
as such (never silently dropped from the model). i18n keys `plugin.sidechain.*`.

### 3.7 API
`plugin.set_sidechain {plugin, source | null}` (`undo: .handled`), `plugin.sidechain_sources
{plugin}` (the menu's list), `plugin.list` gains `sidechain`; DEBUG `debug.sidechain_report`
(ranks, taps, ages, misalignments).

---

## 4. Phases

**Phase 0 — the probe (WRITTEN, not compiled).** Does a real AU, hosted here, enable its sidechain bus?
- `OBJEngineCore pluginBusesInfo:` + DEBUG `debug.plugin_buses {plugin}` (documented in
  `command_api.md`): Tracktion's view (`can_sidechain`, channel names, source, wires) and JUCE's
  (every bus: channels, enabled, enabled by default, main, layout).
- `tools/probe_sidechain.py` — puts each matched plugin on an object, waits for the load, prints
  `OK` / `DISABLED` / `NONE` / `PENDING`.
- To run on the Mac: a Debug build (against the 1550-warning baseline), then the probe on the
  sidechain plugins actually used (FabFilter Pro-C/Pro-G/Pro-MB, the Apple AUs, …). **A `DISABLED`
  verdict on a plugin that matters changes the plan**: the bridge would have to negotiate the
  layout itself (`setBusesLayout`) before anything else.

**Phase 1 — MVP.** Engine patch `0037` (the `ContainerKeyTap` interface, `ObjKeyReturnNode`, the tap
age, the rank split in containers, the root/folder order wrappers). App: `ObjKeyTapPlugin`, the
model field (format 19), the bridge, the rank in `trackSlotForKey:`, `SidechainScope` + its test,
the card menu, the API. Latency: `L_s > L_d` clamped and REPORTED by `debug.sidechain_report`.
Proof: `tools/scenario_sidechain.py` — a compressor keyed by a click in ANOTHER stem and in ANOTHER
group, ducking measured by **export + RMS** (24-bit re-read), the key silent outside the source's
window, a cyclic source refused, one undo per key change with no AU reload, save/reopen.

**Phase 2.** The main path delayed when `L_s > L_d` (declared latency + a convergence rebuild via
`checkLatencyAndRebuild`, `OBJEngineCore.mm:1727`); the pre-fader tap (and the window → fader tail
question); aux sources where acyclic; FX link bins; copy remapping.

**Phase 3.** Bake / consolidate and per-stem export with the key sources built key-only
(`keyOnlyClips` in `CreateNodeParams`, wrapped in `SinkNode`; `OBJRenderPluginFilter`).

## 5. Risks and open questions
- AUs that refuse the sidechain bus, or expose it mono (3 channels) — phase 0 says.
- A clip flagged `compensatesOwnPluginLatency()` reads ahead: its tap age may differ from the
  declared latency (inferred, not verified).
- The `TimedNode` readiness of a leaf reader (it must answer ready at once).
- Rank changes → pool-track moves → rebuilds: measure on a real project.
- The engine submodule was not checked out on the exploring machine; every engine reference was
  read from the published fork. The patch must be written against a real checkout.

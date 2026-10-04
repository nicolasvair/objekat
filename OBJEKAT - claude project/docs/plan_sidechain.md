# Plan — the audio bridge: sidechain, then sends across boundaries (branch `feature/sidechain`)

Status: phase 0 WRITTEN (not compiled). Phase 1 steps 1.1–1.5 WRITTEN on 4 October (the pure core and its test
— 65 assertions, run; the engine side as patch `0037`, applies cleanly onto `17215d464fb`, NOT compiled: no JUCE here).
Phases 1–3 are SPECIFIED below, down to the step an executor
codes without taking a design decision. Written 4 October 2026 against a REAL checkout of the engine
(`tracktion_engine/` at fork commit `17215d464fb`, JUCE `37c894f83d3` not checked out) and of the app.
Every engine line number below is that commit's; every app line number is `feature/sidechain` at
`75b89ac`. "Inferred" marks what was reasoned and not read.

## The request

> A plugin's sidechain input fed by another object's signal — a compressor on the bass keyed by
> the kick — and it has to work ACROSS stems and ACROSS groups.

Extended the same day: the same mechanism must later carry the SENDS that are impossible today —
between sibling stems, and from a child of a group to an aux outside that group (or inside another
group). And **latency compensation is part of the first deliverable**, in both directions.

OBJEKAT has no tracks a user sees, only objects, so a key source is an OBJECT (or a stem), and a
destination is a plugin in ANY chain (an object's, an aux's, a stem bus's, the Main's).

## Decisions

| # | Question | Decision |
|---|---|---|
| D1 | Where the key is tapped | **Post-fader, post-window** — what is HEARD of the source, the point the sends tap. A pre-fader option comes later (phase 3). |
| D2 | Scope | **Everything allowed** except what is impossible: the destination host itself, its ancestors (its groups, its stem, the Main) and cycles. |
| D3 | Cycles | **Refused.** The source menu does not offer a source that would close a loop. |
| D4 | Source kinds | Objects (clip, group, MIDI) and **stems** in the MVP. Auxes later (phase 3). Main never. |
| D5 | Bake / consolidate | **Include the key sources** (built key-only, never mixed into the render) — phase 3. |
| D6 | UI | **From the plugin**: a "Sidechain" menu on the card of a plugin that has a sidechain input. |
| D7 | Rank tiers (extra hidden pool tracks) | **Accepted** (4 October): pool slot `(stem, lane, rank)`, bounded by stems × lanes × ranks, rebuild on a rank change. |
| D8 | Sends across boundaries | **The same bridge**, generic from phase 1: a tap, a reader, ranks, cycle detection, latency — with two consumers, a plugin's sidechain input (phase 1) and an aux's input (phase 2). In-scope sends (`canRouteSend`) STAY on their current mechanism; the bridge serves only routes outside today's scope. |
| D9 | Latency | **First-class in phase 1**: the key is sample-aligned with the destination's main input whether the key is younger OR older (§4). |

Consequences of D1 worth knowing BEFORE using it, since mute is −96 dB on the fader
(`OBJEngineCore.h:12,122`):
- a MUTED source no longer keys — the compressor stops compressing;
- SOLOING the destination silences its key too (solo pushes everything else to −96 dB);
- but a child of a MUTED GROUP still keys: a group's mute is its own fader, which multiplies its
  content downstream of the child's tap (`EditViewModel+Audibility.swift:13-18`). Same for a
  muted STEM if the stem mute is the bus fader and not each object's (inferred — open question Q6).

---

## 1. What exists (read before touching anything)

**The plugin side is complete in Tracktion.**
- `ExternalPlugin::completePluginInstanceCreation` → `enableAllBuses()`
  (`plugins/external/tracktion_ExternalPlugin.cpp:1960`); `restoreChannelLayout` (:563-610)
  re-applies a SAVED `IDs::layout` if there is one (which could keep a sidechain bus off).
- `applyToBuffer` (:1423ff) processes `max(totalIn, totalOut)` channels and zero-pads the missing
  ones; JUCE's AU host renders every input element, element 1 = sidechain
  (`juce_AudioUnitPluginFormatImpl.h:1243-1252`, :1382). So channels 2..3 of the PluginNode
  buffer ARE the AU's key.
- `Plugin::canSidechain()` (`plugins/tracktion_Plugin.cpp:238-248`): false in a Tracktion rack,
  else `ins > 2 || ins > outs`. OBJEKAT's parallel blocks are `<BRANCH>` lists, not Tracktion racks,
  so a plugin in a branch CAN sidechain. Wires: `IDs::SIDECHAINCONNECTIONS` child
  (`tracktion_Plugin.cpp:93-96, 194-202`), `makeConnection` (:204-216), `guessSidechainRouting`
  (:295-331), `sidechainSourceID` (`referTo` at :108, `tracktion_Plugin.h:554-555`).
- `createSidechainInputNodeForPlugin` (`playback/graph/tracktion_EditNodeBuilder.cpp:1471-1521`)
  builds `ReturnNode(busID) → ChannelRemappingNode(wires)` and sums it with the direct input
  through `makeSummingNode` (:1518). `createNodeForPlugin` (:1523-1610) leaves `maxNumChannels`
  unlimited when a source is set and trims the output back to the main bus.
- **Tracktion's own `CompressorPlugin` ("compressor", already in OBJEKAT's built-in list,
  `OBJEngineCore.mm:4948`) has a sidechain**: `getChannelNames` adds "Sidechain Trigger"
  (`plugins/effects/tracktion_Compressor.cpp:63-69`, so `canSidechain()` is true), and it detects on
  channel 3 when `IDs::sidechainTrigger` is true (:97, :116). This is what makes the ducking
  assertable headless with no AU at all.
- **Tracktion's `LatencyPlugin` ("latencyTester")** delays by `IDs::time` seconds and DECLARES it
  (`plugins/effects/tracktion_LatencyPlugin.h:38`, `.cpp:129-139`). Not registered by default
  (tests call `createBuiltInType<LatencyPlugin>()`). It is the tool for every alignment proof.

**Why the native sidechain path cannot be used as is.**
- Its sources are AudioTracks only (`isSidechainSource(Track&)`, `tracktion_EditNodeBuilder.cpp:90-98`,
  `SendNode` at :2021-2022), and OBJEKAT's tracks are scheduling compartments with no plugins
  (`trackSlotForKey:lane:` `OBJEngineCore.mm:2121`, `trackForSlot:` :2126ff).
- It travels through `SendNode`/`ReturnNode` EDGES found by `ReturnNode::transform`
  (`tracktion_graph/tracktion_TestNodes.h:593-602, 665-737`), and a container is a closed local
  graph: `ContainerClipNode::getDirectInputNodes/getInternalNodes` return `{}`
  (`tracktion_ContainerClipNode.cpp:60-89`, patch 0006), and its content is played by its OWN
  player (`:96-129`, `setNumThreads (0)` at :101). No edge enters or leaves a group.
- `CombiningNode::getDirectInputNodes()` returns `{}` (`tracktion_CombiningNode.cpp:323-326`): the
  chains of its `TimedNode`s are not in the enclosing graph's `postOrderedNodes`, so a
  `ReturnNode` inside a clip chain would find no send, and a node there referenced by an outer edge
  would be scheduled twice (the trap that killed `LatencyMaskingNode`, patch 0019).

**The template: the aux sends.** `ObjAuxSendPlugin` (`objekat/OBJAuxSendPlugin.h`, interface
`ContainerAuxSend`, `plugins/tracktion_PluginList.h:185-226`) owns its tap buffer; its age at the
tap is recorded at build (`createPluginNodeForList`, `tracktion_EditNodeBuilder.cpp:1733-1735`) and
`ObjAuxReturnNode` compensates it (`tracktion_ContainerClipNode.cpp:308-312`). A buffer held by an
object that outlives the graph crosses boundaries where an edge cannot.

**A defect found on the way (out of scope, reported):** a plugin processed by `PluginNode` is
called in 128-sample sub-blocks as soon as one of its parameters is automated
(`shouldUseFineGrainAutomation`, `tracktion_PluginNode.cpp:17-26, 123-124, 209-246`), each call
receiving a buffer that starts at 0. `ObjAuxSendPlugin::applyToBuffer` copies the buffer into
`tap[0..n)` and overwrites `tapNumSamples` on every call (`OBJAuxSendPlugin.h:128-166`), so an
AUTOMATED send level should hand its return only the LAST sub-block, laid at the start of the
block. Inferred from the code, not measured: an export + RMS of an automated send settles it (Q8).
The bridge tap below is a NODE, not a plugin, partly for this reason.

---

## 2. The difficulties the design answers

1. **Order.** The key must be written before it is read in the same block. The outer player is
   multithreaded across pool tracks; inside a container's `CombiningNode`, clips are processed
   sorted by START with a `break` past the block end (`tracktion_CombiningNode.cpp:386-415`).
   Ordering per TRACK creates false cycles (A on T1 keyed by B on T2, C on T2 keyed by D on T1).
2. **Cycles** — detected in the model (D3), at the granularity the scheduler really has (§5.5).
3. **Latency** — §4, the core of this document.
4. **The window.** Outside its window a group's inner graph does not run (`ContainerClipNode::process`
   returns early, `tracktion_ContainerClipNode.cpp:174-176`), so its tap is not written: a key must
   read SILENCE then, never an old buffer.
5. **One source, several readers**, possibly with different delays.
6. **Export** clones the Edit and builds with the same builder; **bake / consolidate** builds only
   `allowedClips` (`tracktion_EditNodeBuilder.cpp:1190-1191`): key sources absent → silent key
   (D5 → phase 3).
7. **Undo** (`isPatchable`, `EditViewModel+UndoRedo.swift:280-341`): a key change must not rebuild
   the destination object (and reload its AU).

---

## 3. Vocabulary used below

- **Stream sample** — the monotonic reference time of the device stream, `pc.referenceSampleRange`
  (`tracktion_Node.h:240-250`). It is the ONLY clock every node of every graph (root, containers'
  local players) shares in a block: `ContainerClipNode` hands `pc.referenceSampleRange` to its local
  player unchanged (`tracktion_ContainerClipNode.cpp:259-261`), and `TracktionNodePlayer` splits a
  block into CONTIGUOUS sub-ranges of it (loop end, tempo change — `tracktion_TracktionNodePlayer.h:83-104,
  225-245`). Edit time is NOT common: a looped container's local time folds.
- **Age** of a signal at a point = `NodeProperties::latencyNumSamples` of the node feeding that point:
  the signal there is the material the timeline played `age` stream samples ago.
- **Tap** — where the bridge copies a source (end of the source's chain, D1). **Reader** — where it
  delivers the copy (a plugin's sidechain input; phase 2: an aux's input). **Route** = (source,
  destination host, consumer).
- `L_s` — the tap's age. `L_d` — the reference age at the reader: the age of the destination
  plugin's DIRECT input (sidechain), or of the aux's content (aux input). `X` — the latency the
  reader DECLARES. `D` — the delay it applies.

---

## 4. The latency model

### 4.1 How Tracktion computes and compensates latency (facts)

- Every node reports `latencyNumSamples`, PROPAGATED, never measured: a `PluginNode` adds the
  plugin's latency to its input's (`tracktion_PluginNode.cpp:96`), the plugin latency being frozen
  at node construction (`initialisePlugin`, :307-312 — `getLatencySeconds() × sampleRate`). A
  `LatencyNode` adds its delay (`nodes/tracktion_LatencyNode.h:47-58`). A `ChannelRemappingNode`
  passes its input's (`tracktion_ChannelRemappingNode.cpp:56-58`).
- **Alignment happens only at sums.** `SummingNode::getNodeProperties` reports the MAX of its inputs
  (`nodes/tracktion_SummingNode.h:68-92`, cached), and `SummingNode::transform` →
  `createLatencyNodes` inserts a `LatencyNode(max − own)` on every shorter input (:100-112, 266-320).
  This is the definition of "declaring a latency" in this graph: a node whose output really is
  `X` old and says `X` lands right at every downstream sum.
- **The transform runs only over nodes reachable through `getDirectInputNodes`**
  (`transformNodes`, `tracktion_Node.h:452-482`). `CombiningNode` exposes no direct input, so a clip
  chain inside a `TimedNode` is NOT transformed by the enclosing graph; the `TimedNode` transforms its
  own chain, and only when it branches (`tracktion_CombiningNode.cpp:44-58`, patches 0009/0011). A
  sidechain sum branches, so it IS transformed locally — `createLatencyNodes` works inside a clip
  chain.
- **Lane equalisation** (patches 0013/0023): `createNodeForClips` builds every clip node first,
  takes `laneLatency = max(node latencies)` (`tracktion_EditNodeBuilder.cpp:1186-1201`), pads each
  clip with `LatencyNode(lane − own)` (:1215-1218), widens its activation window by `lane` before and
  `2·lane` after (:1220-1221), gags the first `lane` samples after a non-contiguous resume
  (`LatencyPrimingNode`, :1229-1236) and declares `laneLatency` through the `CombiningNode`
  (`addInput`, `tracktion_CombiningNode.cpp:245-251`). The padding sits AFTER the clip's chain.
- **Containers**: `ContainerClipNode` declares its content's latency, read once at construction
  (`tracktion_ContainerClipNode.h:57`), and plays its content with NO read-ahead since patch 0017
  (`pluginLatencyNumSamples = 0`, `tracktion_EditNodeBuilder.cpp:1071`). The local time equals
  edit time (`refreshContainerSpanForKey:` and its note, `OBJEngineCore.mm:417-422`; folded under a loop). So an
  age measured inside a container is in the SAME stream-sample frame as an age measured at the root.
- **Read-ahead clips**: `Clip::compensatesOwnPluginLatency()` defaults to false
  (`model/clips/tracktion_Clip.h:241`) and NOTHING overrides it any more (grep: the base and its one
  caller, `tracktion_EditNodeBuilder.cpp:1194`). No node anywhere reads ahead today. The bridge's age
  model REQUIRES that invariant (§4.7).
- **Pool tracks and stems**: a pool track is an `AudioTrack` whose clips node is one `CombiningNode`
  (`createClipsNode`, :1378-1415); stems are submix `FolderTrack`s summing their tracks in a
  `SummingNode` (`createNodeForSubmixTrack`, :2043-2112), then their aux returns, chain and mute.
  The root sums every track and folder per device (`createNodeForEdit`, :2497-2700; a stem detached
  from the Main enters wrapped in a `SinkNode`, :2541-2563), then top-level aux returns and the master
  chain (:2632-2647). All of these are `SummingNode`s: every path is equalised by `createLatencyNodes`.
- **Aux taps (patch 0022)**: `createPluginNodeForList` records on each `ContainerAuxSend` the age of
  its INPUT node (`tracktion_EditNodeBuilder.cpp:1733-1735`). `ObjAuxReturnNode` is built after the
  content, so it knows every tap age at construction: it delays tap `i` by `reference − tapLatency_i`
  (`tracktion_ContainerClipNode.cpp:308-312`) and DECLARES `reference` = the content node's latency
  (:323, and `createAuxReturns` passes `contentProps.latencyNumSamples`, `tracktion_EditNodeBuilder.cpp:970-978`).
  `reference` is a max over paths that contain the taps, so the delays are never negative. The
  aux's window is read on the MATERIAL's age: clip range `+ referenceLatency` (:510).
- **Plugin latency changing at runtime**: frozen in the `PluginNode` until the next build. OBJEKAT's
  `checkLatencyAndRebuild` polls the sum of user-plugin latencies every 250 ms and calls
  `restartPlayback()` on a change (`OBJEngineCore.mm:1634-1640, 1727-1743`).

### 4.2 The bridge rule

A route's tap sits in the source's graph at age `L_s`; its reader sits in the destination's graph,
where the signal it must match is at age `L_d`. Both are stream-sample ages in ONE frame (§4.1,
containers included). The reader:

1. **declares** `X = max(L_d, L_s)`;
2. **delays** the key by `D = X − L_s ≥ 0`, by reading the tap's history `D` stream samples back
   (§5.2: the tap writes into a ring indexed by stream sample — the ring IS the delay line).

Case A — **key younger** (`L_s ≤ L_d`): `X = L_d`, `D = L_d − L_s`. The reader's output is exactly
as old as the direct input; the sidechain `SummingNode` (`makeSummingNode`, :1518) inserts nothing;
the graph's latencies are unchanged.

Case B — **key older** (`L_s > L_d`): `X = L_s`, `D = 0`. The reader declares MORE than the direct
input; the sidechain `SummingNode`'s own `createLatencyNodes` inserts `LatencyNode(L_s − L_d)` on the
DIRECT path. The plugin's input is therefore `L_s` old on both buses, its output `L_s + P`, and
because that is DECLARED (the `PluginNode` adds `P` to its input's `X`), the clip's node latency
rises, `createNodeForClips` pads its lane siblings and widens its pre-roll and priming by the new
amount, and every sum downstream re-aligns. Nothing else has to know.

Worked example (48 kHz). Kick K in stem A, chain: look-ahead limiter `P_K = 1000`, then fader and
window → tap `L_s = 1000`. Bass B in stem C, chain: compressor first, keyed by K → `L_d = 0`.
`X = 1000`, `D = 0`; sum inserts `LatencyNode(1000)` before the compressor. B's node latency
`1000 + P_comp`; B's lane, stem C and the root sum all equalise on it. K's dry reaches the root
sum at `≥ 1000`; both stems are aligned at the device sum. ✓
Same bass with a linear-phase EQ (`1500`) before the compressor: `L_d = 1500`, `X = 1500`,
`D = 500`: the key is read 500 samples back; no graph change. ✓

### 4.3 When are the ages known — the build-order problem

`X` must be known WHEN THE READER IS CONSTRUCTED: the sidechain sum caches its properties on first
read (`SummingNode.h:70-71`) and the clip node's latency is consumed during construction by
`createNodeForClips` (:1194) — the declared latency propagates through construction, not after it.
But `L_s` is known only once the TAP is constructed, and the builder visits tracks in
`getAllTracks` order (:2507), descending into containers recursively (:1078-1079): a destination
can be built before its source, in another track, at another depth. Nothing orders construction by
route.

Options weighed:

| Option | Verdict |
|---|---|
| Compute `L_s` on the model side before the build | **Rejected.** Patch 0023's lesson: the node is the single source of truth; a model-side sum of `getLatencySeconds()` misses container content, parallel blocks, lane padding. |
| Build in topological route order | **Rejected.** The builder is recursive over tracks and containers; a source inside group G1 on track T1 and a destination inside G2 on T2 cannot be ordered without rewriting `createNodeForEdit`. |
| Always build twice (pass 1 measures, pass 2 builds) | **Rejected.** Doubles every rebuild, and a rebuild already costs ~70 ms of message thread on a large session (`OBJEngineCore.mm:1755-1767`). |
| Build once, let the app's timer detect and rebuild (convergence via `checkLatencyAndRebuild`) | **Rejected as primary.** A render clone is built ONCE (no timer), so an export would carry a misaligned key; live, a misaligned key is heard for up to 250 ms + a rebuild. |
| **Optimistic build with cached ages + verified re-pass inside `createNodeForEdit`** | **Chosen.** |

**The chosen mechanism.**
1. Each tap PLUGIN remembers the age its node had at the previous build (`cachedAgeNumSamples`,
   a C++ member written on the message thread; scaled if the sample rate changed). A tap node
   constructed in the current pass overwrites it at once, so a reader constructed AFTER its tap in
   the same pass reads the fresh value, one constructed BEFORE reads the previous build's.
2. A reader declares `X = max(L_d, cachedAge)`.
3. **At the END of construction** — all taps of the pass now exist, inside containers too, since a
   container's content is constructed synchronously by `createNodeForContainerClip` — a per-build
   object, `BridgeBuild`, resolves every reader on the message thread: true `L_s` known, so `D`,
   status, ring capacity. If some reader is LATE (`L_s > X`) or OVER-DECLARED
   (`X > max(L_d, L_s)`), the pass is discarded and `createNodeForEdit` builds again: the tap
   plugins now cache the true ages. Bounded at 8 passes.
4. **Cost**: zero extra pass in steady state (ages unchanged since the last build) and for every
   key that is younger than its destination (case A never needs a re-pass, since `X = L_d` there);
   one extra pass the first time a route is laid or when a source's latency changes; one more per
   RANK level whose ages depend on a lower rank's declared latency (a source that is itself keyed).
   Convergence: ages depend only on lower ranks (§5.5), so pass `k` settles rank `k`.
5. Renders converge inside their own `createNodeForEdit` (clone and live alike): an export is never
   misaligned for want of a timer.
6. Runtime latency changes go through the EXISTING path: `checkLatencyAndRebuild` →
   `restartPlayback()` → `createNodeForEdit` → passes. Between the change and the rebuild (≤ 250 ms +
   the 120 ms damper) the whole PDC is stale, the bridge included — the doctrine is unchanged.

Discarding a pass is safe (inferred, verified on the Mac by step 1.12): nothing of a pass is
prepared before the end of `createNodeForEdit`; `PluginNode`'s constructor initialises the plugin
and its destructor de-initialises it (`tracktion_PluginNode.cpp:30-53`, refcounted
`baseClassInitialise/Deinitialise`, `tracktion_Plugin.cpp:503-564`), `ContainerClipNode` creates its
player only at `prepareToPlay`, `CombiningNode` looks at the old graph only at `prepareToPlay`.

### 4.4 Where the key meets the direct input (sidechain) — alignment proof

The meeting point is the plugin's input: the sidechain `SummingNode` built by
`createSidechainInputNodeForPlugin` (:1518). Its inputs are the direct path (age `L_d`, true and
declared) and the reader (true age `L_s + D = X`, declared `X`). The sum (transformed in the
`TimedNode` or in the root/container graph) delays the younger by `|X − L_d|`: both buses carry the
material of the same timeline instant. ∎ The proof needs only that the reader's TRUE output age
equals its declared one, which `D = X − L_s` guarantees whenever the build converged.

### 4.5 Where the wet meets the dry (sends, phase 2) — alignment proof

A bridge send from sender `S` to aux `A`: the wet is read in `A`'s return (inside `A`'s mounting
level: a container's local graph, a stem's submix, the root), goes through `A`'s FX (`F`) and fades,
and is summed with that level's content in `createAuxReturns`' `SummingNode`
(`tracktion_EditNodeBuilder.cpp:998`). `S`'s dry reaches the mix through its own path. **They
meet at the first `SummingNode` both paths reach**: for sibling stems, the root device sum; for a
child of group G sending to an aux outside G, the sum of the level where G's pool track and `A`'s
return are both summed.

Rule (generalising 0022): `A`'s return declares `R' = max(R, max_i cachedAge_i)` where `R` is the
content latency and `i` ranges over the bridge senders; in-scope taps are delayed by
`R' − tapLatency_i`, bridge readers by `R' − L_s,i`; the aux window uses `R'`. At convergence every
input of the return is `R'` old and says so; `createAuxReturns`' sum delays the dry content by
`R' − R + F` where needed; the level's output declares the max; every sum up to the meeting point
aligns, and at the meeting point the dry of `S` (age = its path's declared latency) and the wet
(age = `A`'s level's declared latency) are equalised by `createLatencyNodes`. ∎

Worked example: `S` in stem S1 with an EQ of 300 → tap 300. `A` in stem S2, S2 content 0, `A`'s FX 500.
`R = 0`, `R' = 300`: return 300, after FX 800; S2's content delayed 800, S2 out 800; root sum delays
S1 by 500. The dry and the wet of `S` leave the device at the same sample. ✓

### 4.6 Ordering vs latency

They are independent: ranks (§5.5) make sure the tap's CURRENT block is written before a reader with
`D < block` reads it; latency is entirely in the declared `X` and the read position. A reader with
`D ≥ block size` would not even need the order — not relied upon.

### 4.7 Invariants the model rests on (each one checked somewhere)

- I1. No node reads ahead (`compensatesOwnPluginLatency()` false everywhere). Re-checked by step 1.4
  with a grep; a clip that ever overrides it must make its taps report `age − readAhead`.
- I2. Stream samples are contiguous across a block's sub-ranges and across graph swaps (the device
  clock, `tracktion_EditPlaybackContext.cpp:296-305, 455-459`). If `blockLengthScaleFactor ≠ 1`
  (speed compensation) the reference length differs from `numSamples` (:300-306): the tap then starts
  a new run every block, so a reader with `D > 0` reads silence (degraded, reported, never wrong).
- I3. A render of an Edit frees that Edit's playback context first (`Edit::ScopedRenderStatus`,
  `model/edit/tracktion_Edit.cpp:793-800`, used by `tracktion_Renderer.cpp:615, 774, 902`): two graphs
  of one Edit never run at once, so a tap plugin's ring has ONE writer at a time. A clone has its own
  plugins, hence its own rings.

### 4.8 Failure modes, and what `debug.bridge_report` exposes

| # | Failure | Effect | How it shows |
|---|---|---|---|
| F1 | Late key (passes exhausted, or the ≤ 370 ms window after a runtime latency change) | key late by `L_s − X` | reader `status: "late"`, `alignment_error_samples > 0`; build `converged: false` |
| F2 | Over-declared (cached age dropped) and passes exhausted | unnecessary latency, still aligned | `status: "over_declared"` |
| F3 | Missing order (a gate missing or refused because it would cycle) | reader reads the current block before the tap wrote it: zeros | `blocks_uncovered` climbs while the source plays; build `gate_refused > 0` |
| F4 | Torn read (concurrent writer, only possible with F3) | one block of zeros | `blocks_torn` |
| F5 | Source not built (restricted render, disabled clip, tap plugin missing) | silent key | `status: "source_absent"` / `"tap_missing"` |
| F6 | Source outside its window | silent key (correct) | `blocks_uncovered` (expected) |
| F7 | Transport jump | `D` samples of silent key after the jump (the tap starts a new run) | — (by design: silence rather than the pre-jump material) |
| F8 | Ring grown at a rebuild | `D` samples of key history lost once | tap `ring_generation` increments |
| F9 | A plugin misreports its latency | misaligned like any PDC | not bridge-specific |

`debug.bridge_report` (DEBUG) returns:
- `build`: `id`, `passes`, `converged`, `sample_rate`, `block_size`, `gate_edges`, `gate_refused`;
- `taps[]`: `tap` (EditItemID), `source` (model UUID), `rank`, `age`, `cached_age`, `ring_capacity`,
  `ring_generation`, `latest_end` (stream sample), `runs` (`[[start,end]…]`);
- `readers[]`: `plugin` (model UUID), `dest_instance` (hex pointer of the live plugin — proves no
  reload across an undo), `tap`, `consumer`, `rank`, `l_ref` (= `L_d`), `declared` (= `X`),
  `source_age` (= `L_s`), `delay` (= `D`), `status`, `alignment_error_samples`, `blocks_read`,
  `blocks_uncovered`, `blocks_torn`;
- `model`: the Swift plan (ranks, refused routes and reasons).

The static numbers say what the graph BELIEVES. What the ear hears is measured by export: §7.

---

## 5. The bridge — design

### 5.1 Overview

```
 source chain … ObjGain → ObjWindowFade → [sends] → ObjBridgeTap plugin  (app, engine-only, one per source)
                                                     │ built as BridgeTapNode (engine): pass-through,
                                                     │ writes the block into Ring[stream sample]
                                                     ▼
                         objbridge::Ring  (owned by the tap PLUGIN, survives rebuilds)
                                                     ▲ read at [s − D, s − D + n)
 destination chain … ─┬─ direct (L_d) ───────────────┤
                      └─ BridgeReaderNode (declares X, delay D) → ChannelRemappingNode(wires) ┘→ Σ → PluginNode
 ordering: rank tiers → CombiningNode / reader gates (BridgeGateNode), never an edge to a tap
```

### 5.2 Engine — pure core (C++17, no JUCE): `tracktion_ObjBridgeCore.h`

File `tracktion_engine/modules/tracktion_engine/plugins/tracktion_ObjBridgeCore.h`. Header-only,
`#include <atomic> <array> <vector> <cstdint> <algorithm>` and nothing else, namespaced
`namespace tracktion { inline namespace engine { namespace objbridge {` (the C++17 spelling — the
`tracktion::inline engine` spelling is C++20 and the Linux test compiles in C++17). It is compiled
by the engine AND by `tools/test_bridge_core.cpp` on any machine.

```cpp
struct Run { std::atomic<int64_t> start { 0 }, end { 0 }; };

class Ring
{
public:
    // Message thread / prepare only. capacity rounded UP to a power of two; numChannels clamped to [1, 2].
    Ring (int numChannels, int capacity);
    int  getCapacity() const noexcept;
    int  getNumChannels() const noexcept;
    int64_t getLatestEnd() const noexcept;          // end of the newest run, 0 if none

    // AUDIO THREAD, single writer. Writes src[c][0..numFrames) at stream samples
    // [streamStart, streamStart + numFrames). A source with ONE channel is duplicated on channel 1;
    // channels beyond numChannels are ignored. Starts a NEW run when streamStart != newest run's end
    // or when forceNewRun (transport jump). Never allocates, never locks.
    void write (int64_t streamStart, int numFrames, const float* const* src, int numSrcChannels,
                bool forceNewRun) noexcept;

    struct ReadResult { int framesCovered = 0; bool torn = false; };
    // AUDIO THREAD, any number of readers. Fills dest[c][0..numFrames) with what was written for
    // [streamStart, streamStart + numFrames); ZERO where no run covers it or where the ring has
    // already overwritten it (older than getLatestEnd() − capacity). dest channels beyond the ring's
    // are zeroed. torn = a write happened during the read (seqlock) → dest is zeroed entirely.
    ReadResult read (int64_t streamStart, int numFrames, float* const* dest, int numDestChannels) const noexcept;

private:
    static constexpr int maxRuns = 4;   // newest first
    std::vector<float> data;            // channel-major, numChannels × capacity
    int numChannels = 2, capacity = 0;
    std::array<Run, maxRuns> runs;
    std::atomic<int> numRuns { 0 };
    std::atomic<uint32_t> seq { 0 };    // odd while writing
};
```
Write: `seq.fetch_add(1, relaxed)` (odd) + `atomic_thread_fence(release)`; update runs (shift down on
a new run) and data (index `(uint64_t) s & (capacity − 1)`, two slices on wrap); `seq.fetch_add(1,
release)` (even). Read: `s1 = seq.load(acquire)`; odd → torn; read runs; copy intersections,
newest run first; `atomic_thread_fence(acquire)`; `s2 = seq.load(relaxed)`; `s1 != s2` → torn.
The float payload is plain memory (as `ObjAuxSendPlugin`'s tap): the graph's ordering makes writer
and readers of one block sequential; the seqlock only DETECTS an ordering bug.

```cpp
enum class ReaderStatus { aligned, late, overDeclared, sourceAbsent };
struct ReaderResolution { int delay = 0; ReaderStatus status = ReaderStatus::sourceAbsent; int alignmentError = 0; };

// X = max(L_ref, cachedAge); cachedAge < 0 means "unknown" → treated as 0.
int declaredLatency (int referenceLatency, int cachedSourceAge) noexcept;
// sourceBuilt false → {0, sourceAbsent, 0}. trueAge > declared → {0, late, trueAge − declared}.
// Else delay = declared − trueAge; status overDeclared iff declared > max(referenceLatency, trueAge).
ReaderResolution resolve (int referenceLatency, int declared, bool sourceBuilt, int trueAge) noexcept;
// Phase 2 (aux input): every reader of one aux shares one declared X = max(ref, max cached);
// the group is late/over-declared as a whole. Signature reserved now, implemented in step 2.1.
// Ring sizing: next power of two ≥ maxDelay + 2 × blockSize, and ≥ 4 × blockSize.
int requiredRingCapacity (int maxDelay, int blockSize) noexcept;
// A cached age taken at another sample rate: round (age × newRate / oldRate); oldRate <= 0 → -1.
int scaleCachedAge (int cachedAge, double cachedRate, double newRate) noexcept;
```

### 5.3 Engine — public interface: `tracktion_ObjBridge.h` / `.cpp`

New public header `tracktion_engine/modules/tracktion_engine/plugins/tracktion_ObjBridge.h`,
included from `tracktion_engine.h` right after `plugins/tracktion_PluginList.h` (line 518). It
includes `tracktion_ObjBridgeCore.h`. Its `.cpp` is compiled by adding
`#include "plugins/tracktion_ObjBridge.cpp"` to `tracktion_engine_playback.cpp` after line 261
(the EditNodeBuilder `.cpp`).

```cpp
namespace tracktion::inline engine
{
namespace objbridge_ids
{
    inline const juce::Identifier rank   ("objBridgeRank");   // int: on pool AudioTracks, child clips, aux clips,
                                                              // tap plugins, destination plugins. Absent = 0 (tap: -1).
    inline const juce::Identifier source ("objBridgeSource"); // string: the model UUID a tap plugin serves (report only)
}

/** Implemented by an app plugin that marks a TAP point. The builder never processes it through a
    PluginNode: it builds a BridgeTapNode in its place (createPluginNodeForList). */
struct BridgeTapSource
{
    virtual ~BridgeTapSource() = default;
    // Message thread only (builder + app), never the audio thread.
    int    cachedAgeNumSamples = -1;           // -1 = never built
    double cachedAgeSampleRate = 0.0;
    std::shared_ptr<objbridge::Ring> ring;     // swapped only when it must GROW; old graphs keep theirs
    int    ringGeneration = 0;
    // Phase 2 — a bridge SEND: the aux it targets (invalid for a sidechain tap), and whether the
    // tap must run the plugin on its copy (the send level).
    virtual EditItemID getBridgeTargetAuxClipID() const     { return {}; }
    virtual bool processesTapCopy() const                   { return false; }
};

/** A node the gates may wait for: pool-track / per-rank CombiningNodes, stem BridgeTapNodes.
    getBridgeRank() < 0 means "never a gate target" (object taps, which live inside TimedNodes). */
struct BridgeRankedNode
{
    virtual ~BridgeRankedNode() = default;
    virtual int getBridgeRank() const = 0;
};

struct BridgeReport { /* plain structs mirroring §4.8: Build, Tap, Reader — std::vector + juce::String */ };

/** One per construction PASS of createNodeForEdit. Created and finalised on the message thread;
    read-only afterwards except the per-reader atomic counters. */
class BridgeBuild
{
public:
    BridgeBuild (Edit&, uint64_t buildID, int passIndex, double sampleRate, int blockSize);

    // ---- construction (message thread) ----
    void registerTap (Plugin& tapPlugin, BridgeTapSource&, int ageNumSamples, int rank);
    // Looks the tap plugin up by id (Edit::getPluginCache().getPluginFor, checked still in this
    // Edit). Returns the reader's index; X is computed NOW from the tap's cached age.
    enum class Consumer { sidechain, auxInput };
    int  registerReader (EditItemID tapPluginID, EditItemID destPluginID, Plugin* destPlugin,
                         Consumer, int referenceLatency, uint64_t groupKey);
    int  getDeclaredLatency (int readerIndex) const;
    bool hasTap (EditItemID tapPluginID) const;            // a BridgeTapSource plugin exists in the Edit

    void noteGateEdges (int added, int refused);           // from BridgeGateNode::transform

    // ---- end of pass (message thread) ----
    // Resolves every reader (objbridge::resolve), sizes every ring (adopts the tap plugin's ring if
    // its capacity suffices, else allocates a new Ring and stores it — ringGeneration++), returns
    // TRUE if another pass is needed (any reader late or over-declared).
    bool finalise();
    void publish();                                        // becomes latestFor(edit)

    // ---- after finalise (prepare/audio thread, read-only) ----
    struct ReaderPlan { std::shared_ptr<objbridge::Ring> ring; int delay = 0; objbridge::ReaderStatus status; };
    ReaderPlan readerPlan (int readerIndex) const;
    std::shared_ptr<objbridge::Ring> ringForTap (EditItemID) const;
    struct Counters { std::atomic<uint32_t> blocksRead { 0 }, blocksUncovered { 0 }, blocksTorn { 0 }; };
    Counters& counters (int readerIndex) const;            // stable address (std::deque / unique_ptr)

    // ---- the app ----
    static std::shared_ptr<const BridgeBuild> latestFor (const Edit&);   // mutex-guarded static map Edit* → weak_ptr
    BridgeReport getReport() const;                                      // message thread
};
}
```
Notes the executor must respect:
- `latestFor`'s map is a FUNCTION-LOCAL static guarded by a `std::mutex` (patch 0032: function
  statics are shared between threads that build graphs concurrently).
- A reader whose tap plugin is not built in this pass resolves to `sourceAbsent` and does NOT ask
  for another pass.
- `buildID` comes from a static `std::atomic<uint64_t>` incremented once per `createNodeForEdit`
  call (not per pass).

`CreateNodeParams` (`playback/graph/tracktion_EditNodeBuilder.h:22-48`) gains, last:
`std::shared_ptr<BridgeBuild> bridgeBuild; /**< Objekat — the bridge's per-pass registry. Null outside createNodeForEdit: taps then pass through and readers are not built. */`

### 5.4 Engine — nodes: `tracktion_ObjBridgeNodes.h` / `.cpp`

Private to playback: `playback/graph/tracktion_ObjBridgeNodes.h` included in
`tracktion_engine_playback.cpp` after line 186 (`ContainerClipNode.h`), `.cpp` after line 224.

**`BridgeTapNode`** — `final : graph::Node, TracktionEngineNode, BridgeRankedNode`
- ctor `(ProcessState&, std::unique_ptr<Node> input, Plugin::Ptr tapPlugin, BridgeTapSource&,
  std::shared_ptr<BridgeBuild>, int rank)`; `setOptimisations ({ ClearBuffers::no, AllocateAudioBuffer::yes })`.
- `getNodeProperties()` = input's (latency UNCHANGED), `nodeID` = input's hashed with the tap's itemID.
- `getDirectInputNodes()` = `{ input.get() }`; `isReadyToProcess()` = `input->hasProcessed()`.
- `prepareToPlay` → `ring = build ? build->ringForTap (id) : nullptr` (no allocation here).
- `process`: `copyIfNotAliased` input audio → output (in a linear `TimedNode` chain the two views
  are the same buffer, `tracktion_CombiningNode.cpp:76-90`), MIDI `copyFrom`; then if `ring`:
  `ring->write (pc.referenceSampleRange.getStart(), pc.numSamples, channel pointers,
  numChannels, getPlayHeadState().didPlayheadJump())`. `didPlayheadJump` excludes loop wraps
  (`tracktion_PlayHeadState.h:36-45`) — a folding container keeps one run.
- `getBridgeRank()` = `rank` (−1 for an object tap).
- Never relies on `numOutputNodes` (−1 inside a `TimedNode`: the `LatencyMaskingNode` trap).
- Phase 2 only: when `tapSource.processesTapCopy()`, a scratch buffer allocated in `prepareToPlay`
  receives the copy, `plugin->prepareForNextBlock (getEditTimeRange().getStart())` in `prefetchBlock`,
  `plugin->applyToBufferWithAutomation (…)` on the scratch ONCE per block (no sub-blocks — see the
  defect in §1), and the scratch is what is written; the node's ctor/dtor call
  `baseClassInitialise/Deinitialise` like `PluginNode` (`tracktion_PluginNode.cpp:51-53, 307-312`).

**`BridgeReaderNode`** — `final : graph::Node, TracktionEngineNode`
- ctor `(ProcessState&, std::shared_ptr<BridgeBuild>, int readerIndex, int rank, size_t nodeID)`.
  If `rank >= 1` it owns `std::unique_ptr<BridgeGateNode> gate` (rank, nodeID ^ 0x6A7E).
- `getNodeProperties()`: `hasAudio = true`, `hasMidi = false`, `numberOfChannels = 2`,
  `latencyNumSamples = build->getDeclaredLatency (readerIndex)` (fixed at construction), `nodeID`.
- `getDirectInputNodes()` = `gate ? { gate.get() } : {}`; `isReadyToProcess()` = `! gate || gate->hasProcessed()`
  (inside a `TimedNode` it is a LEAF and must be ready at once — `TimedNode::isReadyToProcess`
  polls leaves, `tracktion_CombiningNode.cpp:118-127`).
- `prepareToPlay` → `plan = build->readerPlan (readerIndex)`; `setOptimisations ({ ClearBuffers::no, AllocateAudioBuffer::yes })`.
- `process`: `if (! plan.ring || plan.status == sourceAbsent)` → clear, return. Else
  `r = plan.ring->read (start − plan.delay, numSamples, dest ptrs, 2)`; counters: `blocksRead++`,
  `framesCovered < numSamples → blocksUncovered++`, `torn → blocksTorn++`. No allocation, no lock.
- If `pc.referenceSampleRange.getLength() != pc.numSamples` (I2): read with `delay` anyway (it is
  the run logic that makes it silent) — nothing special to code, documented.

**`BridgeGateNode`** — `final : graph::Node`
- ctor `(int rank, size_t nodeID, std::shared_ptr<BridgeBuild>)`; zero channels, no audio, latency 0.
- `transform (options)`: ONCE (flag, as `ReturnNode::findSendNodes`, `tracktion_TestNodes.h:665-737`):
  collect from `options.postOrderedNodes` every node `n` with `auto rn = dynamic_cast<BridgeRankedNode*> (n)`,
  `0 <= rn->getBridgeRank() < rank`, `n != this`; cache that list in `options.cache` under a fixed
  key (as `ReturnNode` caches its sends) to keep it linear; for each candidate, `visitNodes (*n, …)`
  and REFUSE it if the visit reaches `this` (a would-be cycle — the app's ranks are trusted but a
  wrong rank must never hang the player); `build->noteGateEdges (added, refused)`. Returns
  `connectionsMade` if anything was added.
- `getDirectInputNodes()` = collected; `isReadyToProcess()` = all collected `hasProcessed()`;
  `process` does nothing.
- In a `TimedNode`'s local transform it finds nothing (no ranked node in a clip chain — object
  taps report −1) and stays an always-ready leaf. That is intended: readers in clip chains are
  ordered by their enclosing combiner's gate.

**`CombiningNode` changes** (`tracktion_CombiningNode.h:21-80`, `.cpp`) — it becomes a
`BridgeRankedNode`:
- members `int bridgeRank = 0; std::unique_ptr<tracktion::graph::Node> orderingGate;`
- `void setBridgeRank (int)`, `void setOrderingGate (std::unique_ptr<Node>)` (construction only);
  `int getBridgeRank() const override { return bridgeRank; }`.
- `getDirectInputNodes()` returns `{ orderingGate.get() }` when set, else `{}` as before.
- `isReadyToProcess()` = `(! orderingGate || orderingGate->hasProcessed()) && isReadyToProcessBlock`.
  With no gate the behaviour is byte-identical (every existing graph).
- `process` ignores the gate's output. Default rank 0: every existing pool track becomes a gate
  target for rank ≥ 1, which is what makes "everything below me" correct without the app naming it.

### 5.5 Ranks — the scheduling order

The scheduler's real granularity is the UNIT, per SCOPE:
- **root scope** — the top-level non-aux objects (each lives in one pool track's combiner), the
  top-level auxes (their return), and the stems' buses (`stemBus(S)`: the folder's chain, its
  readers and its tap). Main is not a unit (everything is upstream of it).
- **container scope C** — C's direct children (non-aux: in C's combiners; aux: their return in C's
  local graph). A container is processed atomically by its parent's node.

Dependencies ("u must run after v"):
- **data edges** (weight 0): `stemBus(S)` → every top-level non-aux object of S and every top-level
  aux mounted in S; a top-level aux mounted in S → every top-level non-aux object of S; a Main aux →
  every top-level non-aux object and every `stemBus`; in scope C, an aux child → every non-aux child.
- **key edges** (weight 1): for a route source → host, walk both up to their LOWEST COMMON SCOPE:
  at the root, `unit(x)` = `stemBus(x)` for a stem, else the top-level ancestor object; if host is
  the Main → no edge; if both map to the same top-level object C, descend into C and repeat with
  C's children; if the host IS the scope's container (a keyed plugin on group G's own chain, source
  inside G) → no edge (the container's chain runs after its content). Else the edge
  `unit(host) → unit(source)` lives in that scope.

`rank(u) = max( max over key deps (rank + 1), max over data deps (rank) )` — the longest path with
those weights. Every scope's graph must be a DAG (D3); a scope's processing is atomic for its parent,
so per-scope acyclicity is sufficient (argued: an inner edge orders nothing outside its container).

Mapping onto the engine:
- top-level non-aux object of rank r → pool slot `(stem, lane, r)`; the pool track's state carries
  `objBridgeRank = r`; its combiner gets `setBridgeRank (r)` and, if r ≥ 1, a gate of rank r;
- child of container C with rank r → `objBridgeRank = r` on the child clip's state;
  `createNodeForContainerClip` builds one combiner per rank (§5.6) — rank 0 keeps C's own itemID;
- top-level aux of rank r → `objBridgeRank = r` on its ContainerClip state (phase 2: its return's
  gate; phase 1: readers in its chain carry their own rank);
- stem S → its tap plugin's `objBridgeRank = rank(stemBus(S))`, readers in its chain get the same;
- every reader → `objBridgeRank` on the destination plugin's state = the rank of the unit hosting
  it at the root (stems: `rank(stemBus)`; Main: 0; a child: its inner rank — harmless, its gate
  finds nothing in a `TimedNode`).

Why the gates cannot cycle: every dependency goes from a rank to an equal-or-lower rank, and a gate
of rank r only waits for ranked nodes of rank < r. The would-cycle check in `BridgeGateNode` is a
safety net for a wrong rank, never the mechanism. Pool tracks are bounded by
stems × lanes × (max rank + 1) — never by the number of objects (CLAUDE.md's absolute rule).

### 5.6 Engine — builder integration (`tracktion_EditNodeBuilder.cpp`)

1. **Tap** — `createPluginNodeForList` (:1721-1782): as the FIRST branch of the `if … else if` chain
   (before `LevelMeterPlugin`, :1737): `if (auto tap = dynamic_cast<BridgeTapSource*> (p))` →
   `age = node->getNodeProperties().latencyNumSamples`; `rank = p->state.getProperty (objbridge_ids::rank, -1)`;
   `tap->cachedAgeNumSamples = age; tap->cachedAgeSampleRate = params.sampleRate;`;
   `if (params.bridgeBuild) params.bridgeBuild->registerTap (*p, *tap, age, rank);`
   `node = makeNode<BridgeTapNode> (params.processState, std::move (node), p, *tap, params.bridgeBuild, rank);`
   (`node` is never null here in practice; if it is, `continue`.)
2. **Reader** — `createSidechainInputNodeForPlugin` (:1471) gains a `const CreateNodeParams&` third
   parameter (its one caller, :1581, passes `params`). After the wire maps are built (:1484-1502),
   BEFORE `makeNode<ReturnNode>` (:1511): if `params.bridgeBuild && params.bridgeBuild->hasTap (sidechainSourceID)`:
   `idx = registerReader (sidechainSourceID, plugin.itemID, &plugin, Consumer::sidechain,
   directInput->getNodeProperties().latencyNumSamples, plugin.itemID.getRawID())`;
   `rank = plugin.state.getProperty (objbridge_ids::rank, 0)`;
   `sidechainInput = makeNode<BridgeReaderNode> (params.processState, params.bridgeBuild, idx, rank, hash (0x0B71D6E5, plugin.itemID))`;
   the `ChannelRemappingNode` and the sum that follow are UNCHANGED. Otherwise the native
   `ReturnNode` path runs as today (a sidechain naming a track still works). `L_d` is read on
   `directInput` AFTER its channel pre-conversion (:1572-1579) — a `ChannelRemappingNode` keeps latency.
3. **Pool-track rank** — `createClipsNode` (:1378-1415): right after `createNodeForClips` returns
   (:1385), `applyBridgeRank (*clipsNode, (int) at.state.getProperty (objbridge_ids::rank, 0), params)`:
   a static helper that `dynamic_cast`s to `CombiningNode`, calls `setBridgeRank`, and if rank ≥ 1
   `setOrderingGate (std::make_unique<BridgeGateNode> (rank, hash (0x0B76A7E0, at.itemID, rank), params.bridgeBuild))`.
4. **Container rank split** — `createNodeForContainerClip` (:1001-1102): after `clips` is filled
   (:1012-1018), partition it by `(int) c->state.getProperty (objbridge_ids::rank, 0)`. If every
   rank is 0 → the existing line (:1078-1080) unchanged. Else: for each rank r ascending,
   `id_r = r == 0 ? clip.itemID : EditItemID::fromRawID (clip.itemID.getRawID() ^ (0x0B51D6E000000000ull + (uint64_t) r))`;
   `n_r = createNodeForClips (id_r, clips_r, trackMuteState, params)`; `applyBridgeRank (*n_r, r, params)`;
   content = `std::make_unique<SummingNode> (std::move (nodes))` (it equalises the rank combiners
   exactly as one combiner padded its lanes), passed to `createAuxReturns` as before. `senderPluginLists (clips)`
   keeps the FULL `clips` list.
5. **The pass loop** — both `createNodeForEdit` overloads (:2497 and :2703): rename each body to a
   `static` `createNodeForEditPass (…)` in the anonymous namespace (identical code, taking `const
   CreateNodeParams&`), and make the public functions:
   ```cpp
   // render overload only: the implicit submix children are added ONCE, before the loop (:2709-2710).
   const auto buildID = nextBridgeBuildID();
   std::unique_ptr<Node> node;
   for (int pass = 0;; ++pass)
   {
       auto build = std::make_shared<BridgeBuild> (edit, buildID, pass, params.sampleRate, params.blockSize);
       auto passParams = params;
       passParams.bridgeBuild = build;
       node = createNodeForEditPass (…, passParams);
       const bool again = build->finalise();
       if (! again || pass + 1 >= kMaxBridgePasses /* 8 */) { build->publish(); break; }
       node.reset();   // never prepared: safe to drop on the message thread
   }
   return node;
   ```
6. **Invariant I1 check** — a `jassert` in `createNodeForClips` next to :1194: if
   `clip->compensatesOwnPluginLatency()` and `params.bridgeBuild` holds a tap → DBG log
   "[BRIDGE] read-ahead clip carries a tap: its age is wrong". Never fires today (§4.1).

### 5.7 Threading and memory — summary

| What | Thread | Allocation / lock |
|---|---|---|
| `BridgeBuild` ctor, register*, `finalise`, `publish`, ring allocation | message | yes (allowed) |
| `latestFor` map | message + render threads | `std::mutex`, never on the audio thread |
| Gate `transform`, `visitNodes` | message (root) / prepare thread (container local graphs) | vectors, allowed |
| `prepareToPlay` of the three nodes | prepare thread | reads `BridgeBuild` (immutable after finalise) |
| `Ring::write`, `Ring::read`, counters | audio | none, wait-free |
| Tap plugin's `ring` pointer / cached age | message only | — |

A ring is never resized in place: growth allocates a NEW ring that only the new graph references
(the old graph keeps its `shared_ptr` until it is destroyed). Continuity across rebuilds is the
point of keeping the ring on the persistent PLUGIN (as `PluginNode` hands its latency FIFO over,
`tracktion_PluginNode.cpp:324-350`).

### 5.8 App — engine side (`OBJEngineCore`)

**New plugin types** (registered next to the others, `OBJEngineCore.mm:1567-1575`):
- `objekat/OBJBridgeTapPlugin.h` — `te::ObjBridgeTapPlugin : Plugin, BridgeTapSource`,
  `xmlTypeName = "objBridgeTap"`, pass-through (`getBusses()` = `singlePassThrough()`,
  `getNumOutputChannelsGivenInputs (n)` = `jmax (2, n)`), `applyToBuffer` empty (never called — the
  builder replaces it), `shouldMeasureCpuUsage()` false. `create()` like `ObjAuxSendPlugin::create`
  (`OBJAuxSendPlugin.h:56-61`).
- `objekat/OBJKeyProbePlugin.h` — `te::ObjKeyProbePlugin : Plugin`, `xmlTypeName = "objKeyProbe"`,
  a MEASURING tool (registered in every build, only reachable through a DEBUG command):
  `getChannelNames` → ins `{"Left","Right","Key L","Key R"}`, outs `{"Left","Right"}` (so
  `canSidechain()` is true); `getBusses()` = `singleStereoInOut()`; `getNumOutputChannelsGivenInputs`
  → 2; `applyToBuffer`: if the buffer has ≥ 3 channels, copy channel 2 (key L) over channel 1 — the
  output's LEFT is the direct signal, its RIGHT the key, sample for sample.
- `te::LatencyPlugin` — `createBuiltInType<te::LatencyPlugin>()` (measuring tool, DEBUG command only).
None of the three is added to `tracktionBuiltInPluginList()` (:4944-4955): nothing new in the UI.

**State** (instance variables beside `_auxSendMap`, `OBJEngineCore.mm:1360`):
`std::unordered_map<std::string, te::Plugin::Ptr> _bridgeTapMap;` (source key → tap plugin),
`std::unordered_set<std::string> _bridgeKeyedPlugins, _bridgeRankedKeys, _bridgeTouched;`
`std::unordered_set<std::string> _bridgePendingWires;` `bool _bridgeDirty = false;`
`uint64_t _bridgeLastReportedBuild = 0;`

**Pool slot rank** — `OBJTrackSlot` (:1127) and `OBJPoolTrack` (:1136) gain `int rank = 0`.
- `trackSlotForKey:lane:` (:2121) returns `{ stemKeyForKey, lane, [self currentRankForKey:key] }`
  where `currentRankForKey:` = rank of `slotOfTrack (objOwningTrack (clip))`, 0 if none — the rank
  is DEDUCED from where the clip lives, like the stem (the doctrine of :2109-2116).
- `trackForSlot:` matches `(stemKey, lane, rank)`; a created track gets
  `track->state.setProperty (te::objbridge_ids::rank, slot.rank, nullptr)` before `applyStemRouting`.
- `slotOfTrack:` returns the rank; `moveObjectKey:toStemKey:` (:4498-4525) keeps `current.rank`.
- New `- (void)setBridgeRank:(NSInteger)rank forID:(NSString*)uuid` — a CHILD (`_childOwnerMap`):
  set `objBridgeRank` on its clip's state if it differs (`removeProperty` when 0), mark
  `_bridgeDirty`; a top-level AUX: same on its ContainerClip state; any other top-level object:
  `dest = trackForSlot ({ stemKeyForKey, current.lane, rank })`, `moveClipToOwner` (as `setLane:`,
  :2998-3020), `pruneEmptyPoolTracks`, mark dirty. Always `_bridgeRankedKeys.insert / _bridgeTouched.insert`.

**Bridge transaction** (all main thread):
- `- (void)beginBridgeSync` — `_bridgeTouched.clear()`.
- `- (void)ensureBridgeTapForSource:(NSString*)sourceKey rank:(NSInteger)rank` — `pl =
  userPluginListForKey` (:2814; a stem returns its folder list, the Main is refused); if
  `_bridgeTapMap[key]` exists AND is still in `pl` (the `stillInList` check of `addSend`,
  :4382-4392) → update `objBridgeRank` (dirty only if changed); else insert
  `ObjBridgeTapPlugin::create()` at `pl->size()` (after the window and the sends: post-fader,
  post-window — D1; for a stem: after the bus `ObjGain` and the `LevelMeter`, :4478-4492), set
  `objBridgeRank` and `objBridgeSource`, store, dirty.
- `- (void)setSidechainForPlugin:(NSString*)pluginKey source:(NSString* _Nullable)sourceKey rank:(NSInteger)rank`
  — the live plugin from `_pluginMap`, else `_instrumentMap`; target id = `_bridgeTapMap[source]->itemID`
  (nil source or no tap → `resetToDefault`). If `getSidechainSourceID()` differs: set it; clear the
  wires (remove the `SIDECHAINCONNECTIONS` child, `nullptr` undo manager); if the plugin is loaded
  (not `isInitialisingAsync`) `guessSidechainRouting()`, else `_bridgePendingWires.insert`; for a
  `te::CompressorPlugin`, `useSidechainTrigger = (source != nil)`; set/remove `objBridgeRank`;
  dirty. `_bridgeKeyedPlugins` / `_bridgeTouched` updated.
- `- (void)commitBridgeSync` — every key in `_bridgeKeyedPlugins` not touched → clear its sidechain
  (same code, nil source); every key in `_bridgeRankedKeys` not touched → `setBridgeRank:0`; every
  tap in `_bridgeTapMap` not touched → `removeFromParent`, erase; then `if (_bridgeDirty)
  _edit->restartPlayback()` (ONE rebuild for the whole sync), `_bridgeDirty = false`.
- In `checkLatencyAndRebuild` (:1727): for every key in `_bridgePendingWires` whose plugin finished
  loading → `guessSidechainRouting()`, erase, `restartPlayback()` once.
- `- (NSDictionary* _Nullable)bridgeReport` — `te::BridgeBuild::latestFor (*_edit)->getReport()`
  converted to NSDictionary (field names of §4.8).
- `- (BOOL)pluginCanSidechain:(NSString*)pluginKey` — `canSidechain()` on the live instance.
- DEBUG tools: `- (NSString* _Nullable)debugAddTestPlugin:(NSString*)type toHost:(NSString*)hostKey`
  is NOT needed — test plugins go through the model (§5.10); `- (BOOL)debugSetPluginProperty:(NSString*)property
  value:(double)v forPlugin:(NSString*)pluginKey` sets a numeric property on the live plugin's state
  (used for `latencyTester`'s `time`).
All new methods are declared in `OBJEngineCore.h` WITH nullability annotations on every pointer (the
header's nullability-completeness trap: one unannotated pointer makes every other one in the file warn).

**The model stays the authority.** `getPluginStateXML:` (:5357-5390) strips, on its COPY, beside the
automation curves: properties `sidechainSourceID`, `objBridgeRank`, child `SIDECHAINCONNECTIONS`, and
for `type == "compressor"` the property `sidechainTrigger` — new `objStripBridgeState (tree)` next to
`objStripAutomationCurves` (:5348). `applyPluginStateXML:forPlugin:` (:7486) treats those same names
as identity in its built-in branch (`isIdentity`, :7514-7515) so a state restore never removes them;
`ExternalPlugin::restorePluginStateFromValueTree` does not touch them (`tracktion_ExternalPlugin.cpp:1156ff`).

### 5.9 App — model (Swift)

- `SoundObject/SoundObject.swift`: `struct SidechainSource: Codable, Equatable { var sourceID: UUID }`;
  `ObjectPlugin` (:106) gains `var sidechain: SidechainSource? = nil`, an init parameter
  `sidechain: SidechainSource? = nil` (LAST, so every existing call compiles), a coding key
  `sidechain`, `decodeIfPresent`. Encoded only when non-nil (synthesised `encodeIfPresent`
  behaviour — verify the struct uses the synthesised encoder; if it has a custom `encode`, add
  `try c.encodeIfPresent (sidechain, forKey: .sidechain)`).
- `SessionSchema.swift`: `formatVersion` 18 → **19** (:21), and in `note` after the `plugins /
  instruments` lines (:61-62):
  `"sidechain — on a plugin entry, { sourceID }: the object or stem whose sound feeds that plugin's",`
  `"  sidechain input, tapped after its fader and its window (what is heard of it). The source must",`
  `"  not contain the plugin's host, and no chain of keys may loop. A key whose source is gone or out",`
  `"  of scope stays written and is silent. Absent = no sidechain (every session before format 19).",`
- **Validity is DERIVED, never stored** (the `automationTouchOrder` lesson): ranks, taps, active /
  refused all come from `BridgeScope.plan` on every sync.
- **Undo**: `adoptingPluginStates` (`EditViewModel+UndoRedo.swift:355-386`) copies `sidechain` from
  `new` on a plain leaf (`out[i].sidechain = new[i].sidechain` beside `stateXML`, :372) and on fxBlock
  instances (through its recursion). A key change is then PATCHABLE: no rebuild, no AU reload; the
  sync that follows every restore (§5.11) pushes it. `set_sidechain` is one `pushUndo()`.
- **A source deleted**: the key STAYS in the model, inactive (refusal `unknownSource`), shown on the
  card. Undoing the deletion makes it active again with nothing else to restore. (This replaces the
  earlier "dropped" idea: a silent write to OTHER objects on a delete is exactly what `isPatchable`
  would then have to see.)
- **Copies** — the 30 `ObjectPlugin(id:` sites (grep), classified:

| Site | Rule |
|---|---|
| `EditViewModel+Plugins.swift:683` `copyLeaf`, `:648` `copiedInstruments`, `:440` instrument transfer | carry `sidechain: p.sidechain` |
| `EditViewModel+PluginSelection.swift:290` (move), `:299` (copy), `:303` (link), `:364` `independentCopy` | carry |
| `Inspector/Synoptic/SynopticModelMapping.swift:222` `synopticCopyPlugin` | carry |
| `EditViewModel+FXLinkAuto.swift:61` (bin definition from a leaf), `:76` (instance) | carry `leaf.sidechain` on the definition AND on each instance (a split must keep the key — `copiedPlugins` converts both halves into a bin) |
| `EditViewModel+FXLinkEdit.swift:226`, `:545` (bin from leaves: definition + instances) | carry `leaf.sidechain` on both |
| `EditViewModel+FXLinkEdit.swift:493` (detach: independent instances) | carry `inst.sidechain` |
| `SoundObject/FXLink.swift:125` (instance created from a definition `d`) | carry `d.sidechain` |
| `EditViewModel+Bake.swift:89`, `:120`, `:127` (`deepFreshCopy`) | carry, REMAPPED through `idMap` when the source is inside the sub-tree |
| `SoundObject/CrossProjectImport.swift:144`, `:158`, `:207`, `:256` | carry ONLY if `objectIDMap[source]` exists (remapped); else nil. A stem source is always dropped (everything lands on Main) |
| `EditViewModel+Plugins.swift:303`, `:358`, `:718` (rack carrier), `Synoptic…:115`, `:292` (rack carrier), `FXLinkEdit.swift:632`, `:654`, `Commands+FXLink.swift:230`, `FXLink.swift:137` (block entry) | new plugin / not a leaf → nil (default, no change) |

  Plus: `EditViewModel+Clipboard.swift:207` `remappingSends` ALSO remaps every plugin's
  `sidechain.sourceID` present in `idMap` (plugins, instruments, rack voices, fxBlock instances,
  recursively) — all six call sites (`Clipboard.swift:143, 312, 460, 1052, 1089`, `Cut.swift:802`)
  then remap keys inside a copied batch for free. Copies whose source is outside the batch keep it
  (same project): a duplicated bass is keyed by the same kick.
- **FX link bins**: the key belongs to the DEFINITION (`FXLink.plugins[i].sidechain`), mirrored on
  every attached instance; `setSidechain` on an attached instance writes the definition and every
  attached instance (`fxDefinition(ofInstance:on:)`, `EditViewModel+FXLinkEdit.swift:796`); on a
  detached instance, only that instance. Validity is per HOST (each instance is its own route).

### 5.10 Scope and cycles — pure Swift unit

`objekat/Shared/BridgeScope.swift` (no model, no view, Foundation only):
```swift
enum BridgeScope {
    enum Kind: String, Codable { case object, group, aux, stem, main }
    struct Node: Codable, Equatable { let id: UUID; let kind: Kind; let parent: UUID?; let stem: UUID? }
        // parent: the GROUP holding it (nil = top level). stem: for a TOP-LEVEL object/group/aux,
        // its stem (nil = Main). Ignored for children (they follow their top-level ancestor) and stems.
    enum Consumer: Codable, Equatable { case sidechain(plugin: UUID); case auxInput(sender: UUID) }
    struct Route: Codable, Equatable { let source: UUID; let host: UUID; let consumer: Consumer }
        // host: the object / aux / stem / Main whose chain holds the reader (auxInput: the aux)
    enum Refusal: String, Codable { case unknownSource, unknownHost, selfSource, ancestorSource,
                                     auxSource, mainSource, cycle }
    struct Plan: Equatable {
        var refused: [Int: Refusal] = [:]     // route index → why; absent = active
        var rootRanks: [UUID: Int] = [:]      // top-level non-aux objects, rank > 0 only
        var auxRanks: [UUID: Int] = [:]       // top-level auxes, rank > 0 only
        var innerRanks: [UUID: Int] = [:]     // group children, rank > 0 only
        var stemRanks: [UUID: Int] = [:]      // stems that are a source or host a reader
        var readerRanks: [Int: Int] = [:]     // active route index → its reader's rank (> 0 only)
        var taps: [UUID: Int] = [:]           // active sources → tap rank (-1 object, stem rank for a stem)
    }
    static func plan(nodes: [Node], routes: [Route]) -> Plan
    /// Candidates for a reader on `host` (replacing route `replacing` if given), each either allowed or refused.
    static func candidates(host: UUID, nodes: [Node], routes: [Route], replacing: Int?) -> [(id: UUID, refusal: Refusal?)]
}
```
Algorithm (deterministic):
1. Index nodes; static refusals per route, in order: unknown source/host; `source == host` →
   `selfSource`; source kind `.main` → `mainSource`; source kind `.aux` → `auxSource` (D4); source
   is an ancestor of host (walk `parent` up from host; for a stem source: host's top-level ancestor's
   stem — nil meaning Main — equals the source, or host IS the source) → `ancestorSource`. The Main
   as HOST is allowed.
2. Accept routes GREEDILY in input order: map the route to its (scope, edge) by §5.5 (`nil` = no edge
   needed); tentatively add the edge to its scope's graph (data edges + accepted key edges); if that
   scope gets a cycle (iterative DFS, three colours) → refuse `cycle`, drop the edge. Input order =
   the model walk order (§5.11), so the same model always yields the same plan.
3. Ranks per scope by memoised longest path (key weight 1, data weight 0).
4. Fill `Plan` (zero ranks omitted).

Verification on two machines:
- `tools/fixtures/bridge_scope_cases.json` — the case table: `{name, nodes, routes, expect: {refused,
  rootRanks, auxRanks, innerRanks, stemRanks, readerRanks, taps}}`, UUIDs written as short
  readable strings mapped to deterministic UUIDs by both test programs (`"00000000-0000-0000-0000-" +
  12-hex of a counter`).
- `tools/test_bridge_scope_reference.py` — a ~150-line Python mirror of the algorithm, run on Linux
  against the table (stdlib only). It proves the TABLE is right.
- `tools/test_bridge_scope.swift` — reads the same JSON, runs `BridgeScope.plan` and `.candidates`,
  asserts equality (Mac: `swiftc -parse-as-library objekat/Shared/BridgeScope.swift tools/test_bridge_scope.swift`).
- Cases (at least): same stem; sibling stems; source in a group → destination at root and vice
  versa; both in one group (inner ranks); two levels of nesting with the LCA in the middle; the
  false-cycle example of §2.1 (A on lane 1 keyed by B, C keyed by D, lanes crossed — accepted, ranks
  split); the container cycle (G holds A and D, X holds B and C, A←B and C←D → second refused
  `cycle`); self; group-as-source with a child host (`ancestorSource`); stem-as-source with a member
  host (`ancestorSource`); stem-as-source to another stem's member; destination on a stem bus keyed by
  its own member (accepted, no edge); destination on the Main (accepted, rank 0); aux as source
  (`auxSource`); keyed source (a chain of three: ranks 0/1/2); unknown source (deleted).

### 5.11 App — `EditViewModel+Bridge.swift`

- `func bridgeTopology() -> (nodes: [BridgeScope.Node], routes: [BridgeScope.Route], routeOwners: [(host: UUID, plugin: UUID)])`:
  walk `items` depth-first in array order (kinds: `.group` for `case .group`, `.aux` if `isAux`,
  else `.object`; top-level `stem = (obj.stemID == nil || obj.stemID == mainStemID) ? nil : obj.stemID`),
  then `stems` (`.main` for `mainStemID`, else `.stem`). Routes: for each host in the same walk
  (objects, then stems) and each leaf of its chain — `plugins` recursively through `rack.voices` and
  `fxBlock.plugins`, then `instruments` — with `sidechain != nil`:
  `Route(source: s.sourceID, host: hostID, consumer: .sidechain(plugin: leaf.id))`.
- `private(set) var bridgePlan = BridgeScope.Plan()` + `bridgeRouteStatus: [UUID (plugin): BridgeScope.Refusal?]`
  for the UI and the API.
- `func syncBridge()`: compute topology + plan; if there is no route AND `bridgeEngineIsEmpty` (the
  previous plan had no tap) → return (the common case costs one tree walk). Else
  `engine.beginBridgeSync()`; `ensureBridgeTap` for every `plan.taps`; `setSidechainForPlugin` for
  every route (active → source, refused → nil) with `readerRanks[i] ?? 0`; `setBridgeRank` for every
  `rootRanks`, `auxRanks`, `innerRanks`; `commitBridgeSync()`.
- `func scheduleBridgeSync()`: coalesces to ONE `syncBridge()` per main run-loop turn
  (`bridgeSyncScheduled` flag + `DispatchQueue.main.async`). Called from `items`' `didSet`
  (`EditViewModel.swift:41`), `stems`' `didSet` (add one if absent, :324), the end of both
  `compileRack` overloads (`EditViewModel+Plugins.swift:232, 259`: a recompiled AU is a NEW instance
  with the sidechain stripped), and directly (`syncBridge()`, synchronous) at the end of
  `resyncAllSends()` (`EditViewModel+Aux.swift:409-423` — the meeting point of load, undo/redo,
  grouping, stem changes and paste).
- `func setSidechain(host: UUID, plugin: UUID, source: UUID?) throws` — refuses (throws) when the
  plugin is not a leaf of `host`'s chain, when `source` is refused by
  `BridgeScope.candidates(host:…replacing:)`, or when the live instance cannot sidechain
  (`engine.pluginCanSidechain`); then `pushUndo()`, writes the key (bins: §5.9), `isDirty = true`,
  `syncBridge()`.
- `func sidechainCandidates(host: UUID, plugin: UUID) -> [(id: UUID, kind: BridgeScope.Kind, name: String, refusal: BridgeScope.Refusal?)]`.

### 5.12 API (`CommandAPI/Commands+Plugins.swift`, documented in `docs/command_api.md`)

- `plugin.list` — each plugin payload (`CommandAdapters.pluginPayload`) gains
  `sidechain: null | { source, active, reason }` (`reason` = the refusal's raw value or null).
- `plugin.sidechain_sources {host, plugin}` → `{ can_sidechain, current, sources: [{id, kind, name}],
  refused: [{id, kind, name, reason}] }`. `undo: .none`.
- `plugin.set_sidechain {host, plugin, source}` (`source` a UUID or `null`) → `{ ok, active, reason }`;
  `invalid_params` with the reason when refused. `undo: .handled`.
- DEBUG `debug.bridge_report` → `{ engine: <bridgeReport>, model: <plan> }`.
- DEBUG `debug.add_test_plugin {host, type: "latencyTester"|"objKeyProbe", latency_ms?}` → adds
  through the NORMAL model path (an `AvailablePlugin(name:, manufacturer: "Tracktion", identifier: type,
  formatName: "TracktionInternal")` into `addPlugin`), then for `latencyTester` sets `time =
  latency_ms / 1000` with `debugSetPluginProperty`. Answers `{ plugin }`. (It relies on the compile
  path resolving a TracktionInternal identifier by type name, as it does for "compressor" — to check
  in step 1.10 by reading `resolvedPluginTreeForInfo:`.)
- DEBUG `debug.set_plugin_property {plugin, property, value}` — the generic setter behind it.

### 5.13 UI (D6) — `Inspector/Synoptic/SynopticView.swift`

- `SynopticActions` (:24) gains `sidechainMenu: ((UUID) -> SidechainMenuModel?)? = nil` and
  `onSetSidechain: ((UUID, UUID?) -> Void)? = nil`, wired where the actions are built (~:2723) to
  `vm.sidechainCandidates` / `vm.setSidechain` for the inspected host.
- The card's `.contextMenu` (:424-427): when the card is NOT part of a multi-selection and
  `sidechainMenu(id)` is non-nil (plugin can sidechain, host not a closed consolidated object —
  `fxReadOnly`), add `Menu(L("plugin.sidechain.menu"))` with: `L("plugin.sidechain.none")` (checked
  when none), then sections `L("plugin.sidechain.selected")` (objects selected in the timeline),
  `L("plugin.sidechain.overlapping")` (objects whose span overlaps the host's, sorted by start, at most
  40; omitted for a stem / Main host), `L("plugin.sidechain.stems")`; refused candidates are shown
  disabled with the reason as `.help`.
- The card shows one line under its name: `L("plugin.sidechain.badge", name)` when active,
  `L("plugin.sidechain.inactive", reason)` when refused.
- i18n keys (FR / EN / ES), exact values:
  `plugin.sidechain.menu` Sidechain / Sidechain / Sidechain ·
  `plugin.sidechain.none` Aucune / None / Ninguna ·
  `plugin.sidechain.selected` Sélection / Selection / Selección ·
  `plugin.sidechain.overlapping` Objets simultanés / Objects at the same time / Objetos simultáneos ·
  `plugin.sidechain.stems` Stems / Stems / Stems ·
  `plugin.sidechain.badge` "Clé : %@" / "Key: %@" / "Clave: %@" ·
  `plugin.sidechain.inactive` "Clé inactive : %@" / "Key inactive: %@" / "Clave inactiva: %@" ·
  `plugin.sidechain.reason.unknownSource` source introuvable / source not found / fuente no encontrada ·
  `.selfSource` même objet / same object / mismo objeto ·
  `.ancestorSource` la source contient ce plugin / the source contains this plugin / la fuente contiene este plugin ·
  `.auxSource` un aux ne peut pas être une source / an aux cannot be a source / un aux no puede ser una fuente ·
  `.mainSource` le Main ne peut pas être une source / the Main cannot be a source / el Main no puede ser una fuente ·
  `.cycle` boucle / loop / bucle.
  Add "clé (sidechain) → key → clave" to `docs/glossary.md`.

### 5.14 Export, bake, consolidate

- **Export (whole mix, clone or live)**: every tap and reader is built; renders converge in their own
  `createNodeForEdit`. A live render frees the live graph first (I3). Works in phase 1.
- **Bake / consolidate / restricted renders** (`allowedClips`): a source outside the restricted set
  is not built → `sourceAbsent` → silent key, reported. Phase 3 (D5) builds key sources key-only.
- **Aux returns in restricted renders** stay absent (`shouldBuildAuxReturns`, :2395-2401) — bridge
  sends follow the same rule in phase 2.

---

## 6. Execution plan

Rules for the executor:
- One step = one commit (superproject), plus at most one commit in the submodule for an engine step.
- ENGINE: work in `tracktion_engine/` on a LOCAL branch created once:
  `git -C tracktion_engine switch -c objekat-bridge-3.5 17215d464fb`. Commit there (author as the
  repository's convention, the attribution lines of CLAUDE.md). **Never `git add tracktion_engine`
  in the superproject; never `git submodule update`; never push.** The gitlink stays `17215d464fb`.
- Every step lists what is checked on this Linux machine (no Xcode, no JUCE checkout) and what the
  Mac must check. A step whose Linux check fails is not committed.
- Comments in English; no visible sentence in a `.swift` outside `L()`; no `NSLog` of user content.

### Phase 0 — the probe (WRITTEN 4 October, not compiled)

`OBJEngineCore pluginBusesInfo:` (`OBJEngineCore.mm:6380`) + DEBUG `debug.plugin_buses {plugin}`
(`Commands+Plugins.swift:637`) + `tools/probe_sidechain.py` (verdicts `OK` / `DISABLED` / `NONE` /
`PENDING`). To run FIRST on the Mac: a Debug build against the 1550-warning baseline, then the probe on
the sidechain plugins actually used. A `DISABLED` verdict on a plugin that matters inserts a step
before 1.6: the bridge negotiates the layout (`setBusesLayout`) when it sets a source.

### Phase 1 — sidechain over the bridge, latency-correct both ways (engine patch `0037`)

**1.1 — Pure core + its test.**
Files: `tracktion_engine/modules/tracktion_engine/plugins/tracktion_ObjBridgeCore.h` (submodule
commit "objekat bridge 1/4: pure core"); `tools/test_bridge_core.cpp` (superproject).
Write §5.2 exactly. Test (style of `tools/test_sample_rate_policy.cpp`): exact write/read; read with
a delay across a block boundary and across the ring wrap; two writes in contiguous sub-ranges form
ONE run; a gap starts a new run and the gap reads zero; `forceNewRun` splits; an overwritten region
(older than `latestEnd − capacity`) reads zero; a mono source fills both channels; > 4 runs drops the
oldest; `read` before any write → zeros and `framesCovered == 0`; `resolve` for: younger key (delay
= L_d − L_s, aligned), older key at X = L_s (delay 0, aligned), late (X < L_s), over-declared,
source absent; `declaredLatency` with cached −1; `requiredRingCapacity` (powers of two, minimum
4 × block); `scaleCachedAge` (44.1 → 48 k rounding, unknown rate → −1).
Linux: `clang++ -std=c++17 -Wall -Wextra -Werror -I tracktion_engine/modules/tracktion_engine/plugins tools/test_bridge_core.cpp -o /tmp/bc && /tmp/bc` → exit 0;
also `-fsanitize=address,undefined`. Mac: the same command.

**1.2 — Public interface, `BridgeBuild`, `CreateNodeParams` field.**
Files (submodule, commit 2/4): `plugins/tracktion_ObjBridge.h` + `.cpp` (§5.3), include lines in
`tracktion_engine.h` (after :518) and `tracktion_engine_playback.cpp` (after :261),
`playback/graph/tracktion_EditNodeBuilder.h` (the field). `BridgeBuild::finalise` uses
`objbridge::resolve` / `requiredRingCapacity` only — no arithmetic of its own.
Linux: `grep -n "juce\|JUCE" plugins/tracktion_ObjBridgeCore.h` → nothing; re-run 1.1's test;
`git -C tracktion_engine diff --check`. Mac: a Debug build of the app (it compiles the engine) —
**warnings: 1550, unchanged**.

**1.3 — Nodes + `CombiningNode` gate support.**
Files (submodule, commit 3/4): `playback/graph/tracktion_ObjBridgeNodes.h/.cpp` (§5.4), includes in
`tracktion_engine_playback.cpp` (after :186 and :224), `tracktion_CombiningNode.h/.cpp` (§5.4).
Linux: read-through checklist written into the commit message — no `new`/`resize`/`push_back`/`std::function`
construction/`lock` inside any `process`/`Ring::read`/`Ring::write`; `CombiningNode` with no gate:
`getDirectInputNodes` still returns `{}` and `isReadyToProcess` reduces to the old expression.
Mac: Debug build, 1550 warnings; `smoke.jsonl` clean (nothing uses the bridge yet: behaviour must be
byte-identical).

**1.4 — Builder integration and the pass loop.**
Files (submodule, commit 4/4): `tracktion_EditNodeBuilder.cpp` — §5.6 items 1–6.
Linux: `grep -rn compensatesOwnPluginLatency tracktion_engine/modules` → still only the base
declaration and its one caller (I1); `git diff --check`.
Mac: Debug build, 1550 warnings; `scenario_families.py` 261 OK, `scenario_markers.py` ALL PASS,
`scenario_export_preview.py`, `scenario_fxlink.py`, `scenario_consolidate.py`, `scenario_tabs.py` —
all as before (no route yet → one pass, no gate, identical graphs).

**1.5 — Export patch `0037`.**
Squash the four submodule commits into one (`git -C tracktion_engine reset --soft 17215d464fb &&
git -C tracktion_engine commit` — message: "feat(graph): pont audio Objekat — taps, lecteurs, rangs,
PDC" + body summarising §4/§5), then
`git -C tracktion_engine format-patch -1 --start-number 37 -o ../engine-patches/3.5/`.
Add the `0037` entry to `engine-patches/3.5/README.md` (style of the existing entries: what, why, the
two latency cases, the pass loop, the gates). Superproject commit: the patch file + README.
Linux: `git -C tracktion_engine worktree add /tmp/te37 17215d464fb && git -C /tmp/te37 am --keep-cr
<abs path>/engine-patches/3.5/0037-*.patch` applies cleanly; `ls engine-patches/3.5/0*.patch | wc -l` → 35;
remove the worktree. Do NOT run `publish-engine-forks.sh` (the gitlink moves only at the merge, by the user).

**1.6 — App engine side.**
Files: `objekat/OBJBridgeTapPlugin.h`, `objekat/OBJKeyProbePlugin.h` (new; add both to the Xcode
target in `objekat.xcodeproj/project.pbxproj` the way `OBJAuxSendPlugin.h` is referenced — headers
only, no new compile unit), `objekat/OBJEngineCore.mm` and `.h` (§5.8: registrations, pool-slot rank,
`setBridgeRank:forID:`, the transaction, pending wires in `checkLatencyAndRebuild`, `bridgeReport`,
`pluginCanSidechain:`, `debugSetPluginProperty:…`, `objStripBridgeState`, the `applyPluginStateXML`
identity set).
Linux: `grep -n "_Nullable\|_Nonnull" objekat/OBJEngineCore.h` covers every new pointer;
`git diff --check`. Mac: Debug build, 1550 warnings; `smoke.jsonl`; `scenario_plugin_state_undo.py`
(the identity-set change must not break state restore).

**1.7 — `BridgeScope` + tests.**
Files: `objekat/Shared/BridgeScope.swift`, `tools/fixtures/bridge_scope_cases.json`,
`tools/test_bridge_scope_reference.py`, `tools/test_bridge_scope.swift` (§5.10).
Linux: `python3 tools/test_bridge_scope_reference.py` → ALL PASS. Mac:
`swiftc -parse-as-library objekat/Shared/BridgeScope.swift tools/test_bridge_scope.swift -o /tmp/bs && /tmp/bs` → ALL PASS.

**1.8 — Model field, format 19, copies, undo.**
Files: `SoundObject/SoundObject.swift`, `EditViewModel/SessionSchema.swift`,
`EditViewModel/EditViewModel+UndoRedo.swift` (`adoptingPluginStates`), `EditViewModel+Clipboard.swift`
(`remappingSends`), every site of the §5.9 table, `SoundObject/CrossProjectImport.swift`,
`tools/test_cross_project_import.swift` (+ assertions: a key whose source is in the batch is remapped;
outside → nil; a stem source → nil).
Linux: `grep -rn "ObjectPlugin(id:" objekat --include=*.swift | wc -l` = 30 and every "carry" site of
the table contains `sidechain:`; `python3 -m json.tool` on nothing (no JSON changed). Mac: build;
`test_cross_project_import.swift` passes; `scenario_cross_paste.py`, `scenario_consolidate.py`,
`scenario_fxlink.py` unchanged; `scenario_markers.py` (it pins the format number — update its
expected value to 19 in the same commit, the precedent of 19 September).

**1.9 — `EditViewModel+Bridge.swift` and the hooks.** (§5.11)
Mac: build; a manual headless check through the API is step 1.12.

**1.10 — API.** (§5.12) Files: `CommandAPI/Commands+Plugins.swift`, `CommandAPI/CommandAdapters` (the
payload), `docs/command_api.md`. Read `resolvedPluginTreeForInfo:` and confirm a TracktionInternal
identifier is resolved by type name; if it is not, `debug.add_test_plugin` builds the ValueTree
with `IDs::type` itself — state which in the commit message.
Linux: none beyond `git diff --check`. Mac: build; `objekat_cli.py` `help` lists the commands.

**1.11 — UI + i18n.** (§5.13) Files: `Inspector/Synoptic/SynopticView.swift`,
`objekat/Resources/Localizable.xcstrings`, `docs/glossary.md`.
Linux: `python3 tools/i18n/xcstrings.py check` → nothing missing; `orphans` → empty.
Mac: build; the eye (§7, not scripted).

**1.12 — Scenarios.** Files: `tools/scenario_sidechain.py`, `tools/scenario_bridge_latency.py`.
Both headless (`--headless --api --no-audio --no-recent --language=en`), stdlib only, fixtures
GENERATED into a temp dir with `wave` at **48 kHz, 24-bit** (impulse: mono, 3 s, one sample at 0.9 at
index 48000; sine: 220 Hz −12 dBFS, 4 s; bursts: 1 kHz −3 dBFS at 1.00–1.50 s and 2.50–3.00 s);
exports `export.run format=wav sample_rate=48000 dithering=False`, re-read in 24 bits.
`scenario_sidechain.py` asserts:
- structure: `plugin.sidechain_sources` on a compressor lists stems and objects, excludes the host,
  its group, its stem, the Main; refuses a group source for its child (`ancestorSource`); after A←B,
  refuses B←A (`cycle`); the container cycle of §5.10 refused;
- engine: `debug.bridge_report` shows one tap and one reader, `converged`, `passes == 1` for a
  younger key;
- **ducking by export + RMS**: Y = sine with the built-in compressor (threshold = its `min`, ratio =
  its `min` — `r *= (thresh + (level − thresh) · rat) / level`, `tracktion_Compressor.cpp:140, 167`),
  X = bursts in a stem routed AWAY from the Main (`stem.route_to_main false`: X keys, is not heard);
  RMS of Y's export in the burst windows ≤ RMS outside − 6 dB; key cleared → the two within 0.5 dB;
  X muted (`object.set_mute`) → no ducking (D1);
- across groups (X inside a group in its stem, Y inside a group in another) and with a STEM source
  (the detached stem itself) — same ducking assertion;
- undo: `set_sidechain` then `edit.undo` → `plugin.list` shows no key, the report no reader, and
  `dest_instance` UNCHANGED (no rebuild of the destination); `edit.redo` → back;
- persistence: save, reopen → the same key, active, same report;
- copies: duplicate Y → the copy is keyed by X; duplicate a group holding X and Y → the copy's Y is
  keyed by the copy's X; split Y → both halves keyed; delete X → key inactive (`unknownSource`),
  undo → active;
- `debug.plugin_id_audit` clean; no window on the headless pid (`CGWindowListCopyWindowInfo`).
`scenario_bridge_latency.py` — **sample alignment**, with `objKeyProbe` on Y (output L = Y's direct,
R = the key) and `latencyTester` plugins; peaks found by arg-max per channel; X always in a stem
detached from the Main:
- A: no latency anywhere → `idx(L) == idx(R)`;
- B (key older): `latencyTester` 20 ms on X (960 samples) → `idx(L) == idx(R)`; report: `declared ==
  source_age == 960`, `delay == 0`; second render after a rebuild: `passes == 1` (cache warm);
- C (key younger): 30 ms before the probe on Y, 20 ms on X → aligned; report `delay == 480`;
- D: X and Y in different stems; E: both inside groups, one of them two levels deep;
  F: the source is a STEM with a `latencyTester` on its bus; G: the probe on a STEM BUS keyed by X;
- H: change X's latency 20 → 40 ms with `debug.set_plugin_property`, poll `debug.bridge_report`
  until `build.id` changes (≤ 3 s), render → aligned; the first build after the change reports
  `passes == 2`;
- I: X outside Y's span → R silent (peak < 1e−6);
- J (absolute PDC): a calibration render of Y alone through a 20 ms `latencyTester` tells whether
  the renderer compensates output latency (its impulse at index 48000 or not); if it does, assert
  `idx(L)` at index 48000 in every case above; print which.
Linux: `python3 -m py_compile` both. Mac: both ALL PASS; then the whole non-regression list of 1.4,
plus `scenario_plugin_selection.py`, `scenario_cross_paste.py`, `scenario_relink.py`, the standalone
Swift tests; i18n check.

**1.13 — Documentation.** `CLAUDE.md` "Current state" entry (what landed, what was verified where,
what was NOT seen/heard; "the next engine patch is `0038`"), this plan's status line,
`docs/architecture_decisions.md` (one entry: the bridge, the pass loop, ranks),
`docs/command_api.md` (done in 1.10).

### Phase 2 — sends over the bridge (engine patch `0038`)

**2.1 — Engine.** `objbridge` group resolution in the core (+ tests in `test_bridge_core.cpp`);
`BridgeTapNode` tap processing (§5.4, phase-2 bullet); `ObjAuxReturnNode`
(`tracktion_ContainerClipNode.h:109-176`, `.cpp:280-525`) gains bridge readers: `createAuxReturns`
(:909-999) asks `BridgeBuild` for the bridge-send taps targeting `auxClip->itemID` (one plugin-cache
scan per pass, cached in the build), registers one reader each with `Consumer::auxInput`, reference =
`contentProps.latencyNumSamples`, group = the aux's itemID; the return declares the group's `X`
(§4.5), delays in-scope taps by `X − tapLatency_i` and reads bridge readers at `X − L_s,i`, clears
its window on `X`; a gate of the aux clip's `objBridgeRank` when ≥ 1. Export `0038` like 1.5.
**2.2 — App.** `objekat/OBJBridgeSendPlugin.h` (`BridgeTapSource` + the level parameter of
`ObjAuxSendPlugin`, target aux id, `processesTapCopy() == true`); `OBJEngineCore` `addBridgeSend /
removeBridgeSend / setBridgeSendLevel` + `_bridgeSendMap`, and the send-automation lookup
(`OBJEngineCore.mm:7405`) extended to it.
**2.3 — Swift.** `BridgeScope` routes with `.auxInput(sender:)` (host = the aux); `canRouteSendOverBridge`
in `EditViewModel+Aux.swift` (= not `canRouteSend` AND accepted by the plan); `syncSendEngine`
(:392-401): in-scope → as today, bridge-valid → bridge, else remove both; `sendScope` /
`overlappingAuxes` offer the newly reachable auxes. Tests: cases added to the JSON table.
**2.4 — Scenario** `tools/scenario_bridge_sends.py`: sender X impulse panned hard LEFT, aux A panned
hard RIGHT, so the export's L is the dry and R the wet: sibling stems, child of a group → aux at the
root, → aux in another group; latencies on X before the tap, on A's FX, on A's level content →
`idx(L) == idx(R)` every time; send level −6 dB heard as −6 dB (RMS); an automated level heard;
in-scope sends unchanged (`scenario_families.py`, `scenario_selection_send_scope.py`).

### Phase 3

Bake / consolidate with key sources built key-only (`keyOnlyClips` in `CreateNodeParams`, their nodes
wrapped in `SinkNode`, `OBJRenderPluginFilter` letting their plugins load); the pre-fader tap (and the
window → fader order question); auxes as sources where acyclic.

---

## 7. What the Mac — and only the Mac, with a person — verifies

Scripted (listed per step above): the build against **1550 warnings**, the standalone tests, the
scenarios, the export + RMS ducking proofs and the impulse alignment proofs.

Not scriptable — say it was not done until a person does it:
- **listening**: a real kick keying a real bass through a real AU compressor (FabFilter Pro-C 2 /
  Pro-G / Pro-MB), with and without a look-ahead limiter on the kick: no flam between the duck and
  the kick; stop/start and loops: no stale key at the loop start; seeking: no burst;
- the phase-0 probe on the sidechain AUs actually used (a `DISABLED` verdict changes the plan: the
  bridge would have to negotiate `setBusesLayout` first);
- the card menu, its sections, the disabled entries and their reasons, the badge, in three languages;
- CPU of the live graph on a real session with a few routes (rank tiers reduce parallelism).

---

## 8. Review of steps 1.1–1.5 (4 October 2026)

Read as a compiler would (nothing builds here): engine branch `objekat-bridge-0037` at `495323ed79a`,
patch `0037` re-applied on `17215d464fb` in a scratch worktree with an empty diff against it;
`tools/test_bridge_core.cpp` re-run, 65 assertions pass. No certain compile error found (overloads,
unity-build order — `ObjBridgeNodes.h` after `TracktionEngineNode.h`/`CombiningNode.h`, before
`EditNodeBuilder.cpp`; `tracktion_ObjBridge.cpp` after `EditNodeBuilder.cpp`, its anonymous-namespace
names collide with nothing in that TU; `makeNode` returns `unique_ptr<Node>`; `float**` →
`const float* const*` is a legal qualification conversion; `std::deque` of non-movable `Counters`
only uses `emplace_back`). No allocation or lock in any `process`, `Ring::read`, `Ring::write`.

Deviations, ruled: 1 accepted (it also covers a stream that restarts lower after a new playback
context); 2–10 accepted. Fixes requested:
- **R1 (before 1.6)** — rings are sized and swapped in `BridgeBuild::finalise` even on a pass that is
  about to be DISCARDED (`tracktion_ObjBridge.cpp:156-180`): a discarded pass can replace the tap
  plugin's ring (bumping `ringGeneration`, dropping the key history) only for the next pass to
  replace it again. Move step 2 into `void BridgeBuild::allocateRings()` (same body), call it from
  `buildWithBridgePasses` immediately before `build->publish()` (`tracktion_EditNodeBuilder.cpp`,
  the `if (! anotherPassNeeded || …)` branch), and keep `finalise()` to step 1. `ringForTap` /
  `readerPlan` are only read at `prepareToPlay`, which follows `publish`.
- **R2 (before 1.6)** — a bridge reader with NO direct channel
  (`if (! hasDirectChannels) return sidechainInput;`) would sit alone in a LINEAR `TimedNode` chain,
  where every node shares one buffer and `ChannelRemappingNode`'s explicit mapping ADDS into its
  destination (`tracktion_ChannelRemappingNode.cpp:118-139`) — the key would be summed into itself.
  `guessSidechainRouting` always wires 0→0/1→… so the app never produces it; guard it anyway: in the
  bridge branch of `createSidechainInputNodeForPlugin`, `if (! hasDirectChannels) { DBG ("[BRIDGE]
  reader without a direct channel: refused"); return directInput; }` placed BEFORE `registerReader`.
- Gate cost (open point): `visitNodes` per candidate is O(subgraph) and a stem tap's subgraph is its
  whole stem, so a build pays O(gates × root nodes) — gates are few (ranked pool tracks + outer
  readers) and `TimedNode` internals are not visited. Accepted; measure with `OBJ_GRAPH_PROFILE`
  on the 1.12 scenarios.
- Minor, left: the live-Edit render path writes the tap plugins' `cachedAge`/`ring` from the render's
  build thread; I3 (the playback context is freed) makes it the only writer, and the app must not
  sync the bridge during an export (the existing "do not modify the Edit during an export" rule).

Verdict: proceed to 1.6 once R1 and R2 are committed (on `objekat-bridge-0037-steps`, then
re-squashed and `0037` re-exported).

## 9. Risks and open questions

- **Q1 — AUs that refuse the sidechain bus** or expose it mono (3 channels) — phase 0 answers; mono
  is handled by the wires (`guessSidechainRouting`, 3 ins → 2,3 summed into 2).
- **Q2 — a saved `IDs::layout` keeping the sidechain bus off** (`restoreChannelLayout`,
  `tracktion_ExternalPlugin.cpp:563-610`): the model's `stateXML` may carry such a layout from a
  session saved before the bus was wanted. Not settled from the code.
- **Q3 — discarding a pass — SETTLED from the code (review of 1.1–1.5, 4 October).** Every node that
  registers itself somewhere undoes it in its destructor: `LiveMidiInjectingNode` adds itself as a
  track listener in its constructor and removes it in its destructor
  (`tracktion_LiveMidiInjectingNode.cpp:15-27`), so the `hasRealListener` test of pass 2
  (`tracktion_EditNodeBuilder.cpp:2055-2064` on the patched file) sees no ghost of pass 1; the input
  device nodes register as consumers only in `prepareToPlay` and deregister in their destructors
  (`tracktion_WaveInputDeviceNode.cpp:22-42`, `tracktion_MidiInputDeviceNode.cpp:23-62`,
  `tracktion_HostedMidiInputDeviceNode.cpp:20-36`); `PluginNode` balances `baseClassInitialise`
  (refcounted). What remains unproven is only the Debug run of case B (asserts on).
- **Q4 — MIDI note-offs across a rank change inside a container**: per-rank combiners have derived
  ids, so a MIDI child moved to another rank during playback loses `queueNoteOffsForClipsNoLongerPresent`
  (`tracktion_CombiningNode.cpp:346-355, 447-478`) — possible stuck note. Rank 0 keeps the container's
  id, so routes added only on audio objects never trigger it.
- **Q5 — rank changes move clips between pool tracks** (one rebuild); a project with many routes
  could create many pool tracks (bounded, but measure on a real project).
- **Q6 — mute semantics**: D1 says "what is HEARD". A child of a muted group, and (to verify) an object
  of a muted stem, still key, because those mutes sit downstream of the source's own fader. Does the
  user want that? The alternative (key silenced by any muted ancestor) needs the app to fold ancestor
  mutes into each tap's gain.
- **Q7 — `blockLengthScaleFactor ≠ 1`** (I2): keys with `D > 0` go silent. Whether OBJEKAT ever runs
  with speed compensation was not established.
- **Q8 — the automated-send sub-block defect** of §1 (existing sends, not the bridge): to be confirmed
  by an export and reported as its own task.
- **Q9 — `dest_instance` as proof of "no reload"** is a pointer: a rebuilt plugin could reuse the
  address. Good enough for a scenario (combined with the undo log `[UNDO] … patched`), not a proof.
- **Q10 — UI listing on huge projects**: the menu shows the selection, at most 40 overlapping objects
  and the stems; any object stays reachable through the API. Whether that is the gesture wanted is the
  eye's call.
- **Q11 — `checkLatencyAndRebuild` only watches user plugins** (`_pluginMap`, `_instrumentMap`):
  a latency change inside a plugin that is neither (none today) would not trigger the re-pass.

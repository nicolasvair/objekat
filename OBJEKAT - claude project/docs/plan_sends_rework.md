# Plan — the sends rework: wider scope, a tap anywhere on the trunk, plugins on the send

Status (9 October 2026): INC 1 IN PROGRESS on `feature/sends-inc1-scope` (see the recorded numbers and the journal at the end of section B). INC 2 and INC 3 are not started.
Written against `main` at `f3c805c4` and the engine fork at `efff893e684` (branch `objekat-ara-0038`,
i.e. `17215d464fb` + patches `0037` + `0038`). Every line number below is that checkout's. "Inferred"
marks what was reasoned and not read; "to verify" marks what the executor must check before leaning
on it. This plan SUPERSEDES decision D8 and "Phase 2" of `docs/plan_sidechain.md` (§A.2 says why);
everything else in that document — the latency model §4, the ranks §5.5, the threading table §5.7 —
is the foundation and is not repeated here.

## The request

1. A send is no longer limited to the sender's own group: wider scope, "with the sidechain's logic".
2. A send can be tapped anywhere along the chain, in the signal view.
3. Plugins can be laid on the send itself (a low-pass before the reverb, for this sender only).

## Decisions taken by the user (not reopened here)

| # | Subject | Decision |
|---|---|---|
| U1 | Scope | An object reaches any aux of ITS stem or of the MAIN, at any group depth, including an aux stored inside another group (the return then comes out in that group and goes through its FX). Two sibling stems still do not see each other. Aux and Main cannot send. |
| U2 | Multiplicity | ONE send per (object, aux). The identity (sender, auxID) is kept; the send gains a position and a mini-chain. The Aux tool (A), `ParamRef.send(auxID:)` and the `send.*` API stay valid. |
| U3 | Positions, v1 | On the TRUNK (before / between / after the plugins, before or after the chain gains trimIn / trimOut) and post-fader / post-window (today's position, which stays the default). NOT in a branch of a parallel block, NOT in an FX link bin. |
| U4 | Increments | Three, each on its own branch, tested by export + measurement, validated by ear before the next: INC 1 scope, INC 2 position + send card, INC 3 plugins on the send. |
| U5 | Assumptions announced, not contested | Existing sends stay post-fader (same sound on opening an old project); the send ends as a card in the signal view (level, on/off, target, mini-chain); the target is chosen as for the sidechain (a list + the "pick an object" mode on the timeline). |

## Decisions taken by the user AFTER this plan was written (9 October 2026) — they PREVAIL over the text below

| # | Subject | Decision | Consequence for INC 1 |
|---|---|---|---|
| Q-U1 | Mute of a group | YES: the mute of a group silences the sends of its children towards an aux OUTSIDE that group. | Step 1.6 is DONE (not droppable). |
| Q-U1b | Group fader / FX / fades | Accepted: they do not act on that send (the tap is upstream of them). | Said in the documentation. |
| Q-U2 | Old projects | The sends that were silent because out of scope are LEFT TO SOUND. No `enabled = false` at migration. | §A.5's "planned default" and the matching half of step 1.7 are REMOVED; the migration keeps only the purge of dangling sends (with their automation, same undo point). Scenario section P changes accordingly. |
| Q-U3 | Aux tool (A), sends zone of the signal view, multi-selection inspector | They show ALL the reachable auxes (still filtered by time overlap as today), in this order: first those of the SAME group as the sender, then the other auxes of the stem, then those of the Main. | `near` stops being an offer filter. The "Send to…" menu and the "pick" mode of step 1.8 are POSTPONED to INC 2 (not implemented in INC 1). Kept from 1.8: inactive rows greyed with their refusal reason, and correct wires sender -> aux when the aux is inside a group (wire to the visible group when it is closed). |
| Q-U4 | New send | A newly created send starts at -inf (silent). | Hand doors create at `sendMinDb`. |
| Q-U10 | Scheduling loop | Accepted: the send is refused, the reason is shown. | As planned. |
| Q-U11 | Detached stem | Unchanged: a stem detached from the Main still feeds a Main aux. | As planned. |

## Decisions taken in this plan (the architect's, each justified below)

| # | Subject | Decision |
|---|---|---|
| P1 | Engine mechanism | **Everything on the bridge.** One send = one engine plugin that is a `BridgeTapSource` writing a ring; one aux return = N bridge readers sharing one declared latency. The legacy `ObjAuxSendPlugin` / `ContainerAuxSend` path stays COMPILED for INC 1 only, behind `OBJ_SENDS_LEGACY=1`, as the null-test oracle; it is deleted at the start of INC 2. |
| P2 | Who names the senders of an aux | The APP, not a scan: the aux clip's state carries `objBridgeSends` (the list of its send plugins' ids), written in the bridge transaction. Same shape as `sidechainSourceID` on a keyed plugin. |
| P3 | Where the level is applied | At the TAP (on the copy, once per block), never at the reader: an automated level must be aligned with the material it scales. Settles Q8 for every send. |
| P4 | The scope rule | ONE pure definition in `Shared/BridgeScope.swift` (static refusals for an `auxInput` route + the cycle check), read by every site through one cached index. The engine keeps NO copy of the rule. |
| P5 | Model, target | `AuxSend` stays THE store, keyed by `auxID`. INC 2 adds `tap` (`postFader` / `preFader` / `input`) and a thin MARKER entry in the chain array for an in-chain tap; INC 3 adds `plugins` (the mini-chain) on `AuxSend`. INC 1 changes no field. |
| P6 | INC 3 branch | The send's mini-chain is a real graph branch: fan-out through a `ConnectedNode`, the mini-chain as `PluginNode`s, the tap at its end, the branch SUNK and summed with the dry (`SummingNode { dry, SinkNode (wet) }`). Its latency delays the sender's dry locally and is compensated by the ordinary PDC. |
| P7 | Dangling sends | Purged with their automation when their aux is deleted (same undo point) and at load. |
| P8 | dB floor | The new send plugin treats `≤ −60 dB` as exact silence, as the model already says (`sendMinDb`). |
| P9 | Session format | 21 at INC 1 (migration marker, §A.5), 22 at INC 2, 23 at INC 3. |

---

# A. Overall design

## A.1 What exists (verified)

**Model.** `AuxSend {auxID, levelDb, enabled}` (`SoundObject/SoundObject.swift:304-329`),
`SoundObject.sends` (:423). `sendMinDb = −60` is "−∞", `sendMaxDb = +6`. A send is ALIVE when
`enabled && (level > −∞ || its level is automated)` (`syncSendEngine`, `EditViewModel+Aux.swift:392-401`).
Session format is **20** (`EditViewModel/SessionSchema.swift:21`).

**The scope today**, written out in: `canRouteSend` (`EditViewModel+Aux.swift:68-83`), its batch form
`reachableAuxes` (:118-145), the engine's `-isSend:routableToAux:` (`OBJEngineCore.mm:4405-4418`) and
`pruneOutOfScopeSends` (:5069), plus the test oracle `_referenceCanRouteSend`
(`EditViewModel+MultiSelectionReference.swift:31-41`). It is also IMPLICIT in the fork: which
plugin lists each mounting level searches (`senderPluginLists`, `collectAuxClipsAndSenders`,
`tracktion_EditNodeBuilder.cpp:901-910, 2499-2528`). Rule: same parent group; at the top level, the
same stem or an aux of the Main.

**Engine, legacy path.** `addSend` inserts an `ObjAuxSendPlugin` at `pl->size()`
(`OBJEngineCore.mm:4552-4608`), registry `_auxSendMap["sender|aux"]`. The plugin copies its input,
scaled, into ITS OWN buffer `tap[0..n)` (`OBJAuxSendPlugin.h:128-166`). `createAuxReturns`
(`tracktion_EditNodeBuilder.cpp:912-1002`; mounted at :1140 for a container, :2574 for the root,
:2607 for a stem's submix) builds one `ObjAuxReturnNode` per aux, which sums the taps of the senders
it was handed, each through a delay line of `reference − tapLatency`
(`tracktion_ContainerClipNode.cpp:282-312, 438-525`), and declares `reference`.

**Engine, bridge (patch 0037).** `BridgeTapSource` plugin → `BridgeTapNode` → `objbridge::Ring`
(indexed by STREAM sample) → `BridgeReaderNode`; `BridgeBuild` per construction pass, re-pass when a
reader is late or over-declared; rank tiers and `BridgeGateNode`. App side:
`beginBridgeSync … commitBridgeSync` (`OBJEngineCore.mm:4649-4885`), ONE `restartPlayback` per
transaction. Rules in `Shared/BridgeScope.swift`. The phase-2 hooks exist and are read by nothing:
`getBridgeTargetAuxClipID()`, `processesTapCopy()` (`tracktion_ObjBridge.h:51-52`),
`Consumer::auxInput` (only printed in the report, `tracktion_ObjBridge.cpp:290`), `groupKey` (stored
at :117, never used by `finalise`), `BridgeScope.Consumer.auxInput(sender:)`.

**Chain.** Engine layout `[ channel mode? | instrument? | trimIn | FX… | trimOut | fader ObjGain |
ObjWindowFade | (sends) | (bridge tap) ]` (`OBJEngineCore.mm:1529, 8216`). `compileUserRackForObjectID`
(:8220) reconciles ONLY `[trimIn … trimOut]` by plugin key. The trims are two SCALAR fields of the
model (`chainInGainDb`, `chainOutGainDb`, `SoundObject.swift:402-403`), not entries of
`plugins: [ObjectPlugin]`. A parallel block is an `ObjParallelBlockPlugin` holding one `PluginList`
per branch, unfolded by `createNodeForParallelBlock` (`tracktion_EditNodeBuilder.cpp:1794-1835`) into
`SummingNode { ConnectedNode (shared input) → branch … }`.

## A.2 The mechanism: everything on the bridge (P1)

Two options were on the table.

**(i) D8 — two paths.** In-scope sends stay on `ObjAuxSendPlugin`; only out-of-scope routes use the
bridge. **(ii) One path** — every send is a bridge route.

What the wider scope needs, case by case:

| Route | Order | Legacy path able? |
|---|---|---|
| Siblings (today's scope) | free: the return depends on its level's content | yes |
| UPWARD through containers (child of G → aux at the top level of its stem / the Main; grandchild → an aux of an ancestor group) | free, same edge | only on paper: a recursive `sendersFor` would find the plugin, but its buffer is BLOCK-RELATIVE. A container's local player splits a block at a loop end or a tempo change; the plugin is then called several times, each call overwriting `tap[0..n)` and `tapNumSamples`. The outer return would read the last fragment, laid at the start of the block. Same family as Q8. |
| ACROSS (aux inside G, sender not under G) | needs a rank: G's unit must run after the sender's | no — nothing orders two pool tracks |

So the bridge is required for two of the three, and option (i) means: two plugin types, two
registries, a return node mixing two kinds of tap under one declared latency, a send that CHANGES
mechanism (a new plugin instance, its curve re-pushed, a rebuild) whenever a grouping moves it across
the old boundary, and INC 2 / INC 3 implemented twice. Option (ii) costs one thing: every existing
session's sends move to a new path.

**Decision: (ii).** The points the brief asked to weigh:

- **Latency / PDC shared per aux.** §4.5 of the sidechain plan already proves it: the return declares
  `X = max(R, max_i age_i)` (`R` = its level's content latency), reads reader `i` at `X − age_i`,
  gates its window on `X`. For every route whose sender is UNDER the aux's mounting level,
  `age_i ≤ R` by construction (the tap is upstream of that content), so `X = R`: exactly what patch
  0022 does today, and NO extra pass even with an unknown cached age (`X = max(R, 0)`). Only an
  ACROSS route with a tap older than the host level's content raises `X` (case B) and may cost one
  re-pass, once.
- **`restartPlayback`.** Both paths rebuild on add / remove. The bridge transaction rebuilds ONCE per
  sync; today `resyncAllSends` calls `addSend` per send, each asking for its own rebuild (damped).
  A level change stays hot (no rebuild) in both.
- **Cost.** Per send: one ring (2 channels × next power of two ≥ 4 blocks: ~16 KB at 512), one
  write, one read. The legacy path costs one buffer copy and, as soon as a latency differs, its own
  delay line. Equivalent. No rank, no gate, no extra pool track for any route the data graph already
  orders — which is every route except ACROSS.
- **Q8.** The legacy plugin runs inside a `PluginNode`, which calls it in 128-sample sub-blocks as
  soon as its level is automated (`tracktion_PluginNode.cpp:17-26, 123, 256`). A bridge send is a
  NODE: it applies the level on its copy ONCE per block (P3) and writes by stream sample. Q8
  disappears by construction — and is measured before and after (§C.3, section M).
- **Risk.** The regression risk of (ii) is real and is answered by a NULL TEST: INC 1 keeps the legacy
  path alive behind `OBJ_SENDS_LEGACY=1` (read once at launch), and the scenario exports the same
  in-scope sessions on both paths and subtracts them (§C.3, section O). The switch is all-or-nothing,
  so the return node never mixes the two kinds of tap.
- **I2 (speed compensation).** A reader with a delay goes silent when `blockLengthScaleFactor ≠ 1`.
  In the fork that factor is moved only by `setTempoAdjustment`, called only from
  `tracktion_AbletonLink.cpp:196`; the app calls neither (grep). Step 1.0 re-checks it; if Link is
  ever enabled, sends with a delay would go silent — reported by `blocks_uncovered`.

**Does (ii) carry INC 2 and INC 3?**

- INC 2: `createPluginNodeForList` builds a `BridgeTapNode` wherever a `BridgeTapSource` sits in a
  list (`tracktion_EditNodeBuilder.cpp:1858-1873`) and records the age of ITS input. A send plugin
  moved to another index of the sender's top-level list needs no engine change.
- INC 3 (P6): the send plugin gains one `PluginList` (its mini-chain), declared through a small
  interface next to `ParallelPluginBlock`. The builder, at that plugin:

  ```
  shared = input
  dry    = ConnectedNode (shared)
  wet    = ConnectedNode (shared) → createPluginNodeForList (miniChain) → BridgeTapNode (level, ring)
  result = SummingNode { dry, SinkNode (wet) }
  ```
  This is the parallel block's unfolding (patches 0009 / 0011 / 0012: a branching `TimedNode` chain
  is transformed locally, `createLatencyNodes` runs) with one branch that is never re-summed.
  `SinkNode` is already used the same way for a stem detached from the Main. **Effect of the
  mini-chain's latency `P` on the direct signal:** the sum pads the DRY by `P`, the object's declared
  latency rises by `P`, lane equalisation and every downstream sum follow — the same thing a
  latency plugin in a parallel branch does today. Nothing audible offline; the session's total
  latency rises by `P` when `P` exceeds the slack. The tap's age is `L + P ≤` its level's content
  latency, so an upward send still needs no re-pass. The alternative (a custom join node hiding `P`
  from the dry and letting the reader declare it) gives the same global latency through a node that
  lies about its inputs; rejected.
  The mini-chain's plugins are ordinary `_pluginMap` entries compiled by `compileSeries`, so
  `checkLatencyAndRebuild` watches them (Q11 not concerned).

INC 1 therefore fixes, once: the engine plugin type (`ObjBridgeSendPlugin`), the tap node's copy
mode, the aux return's readers and group latency, the app-declared sender list, the Swift rule and
the sync. INC 2 moves a plugin; INC 3 gives it a list.

## A.3 The scope rule (P4) — stated once

A send is a bridge route `Route(source: sender, host: aux, consumer: .auxInput(sender:))`. It is
ACTIVE iff no static refusal applies AND the greedy plan does not refuse it as a cycle.

**Static refusals for an `auxInput` route**, in this order (first hit wins):

1. `unknownSource` / `unknownHost` — the sender or the aux is not in the model (a dangling send).
2. `hostNotAux` (new) — the host is not an aux.
3. `selfSource` — same id.
4. `auxSource` — the sender is an aux. `mainSource` / `stemSource` (new) — the sender is the Main or
   a stem (a stem can key a sidechain; it cannot send).
5. `ancestorSource` — the sender is an ancestor of the aux (a group sending to an aux it contains, at
   any depth): the wet would come back into the sender's own content.
6. `outOfStem` (new) — `stemOf(top(aux))` is neither the Main nor `stemOf(top(sender))`. A child
   follows its top-level ancestor; `stem == nil` means the Main.

**Cycle** — unchanged machinery (`BridgeScope.accepted`): the route's key edge is laid in its lowest
common scope unless the data graph already implies it. With rule 6, the edge is ALWAYS implied when
the aux's parent container is an ancestor of the sender or the aux is at the top level (aux after the
objects of its stem; Main aux after everything; an aux child after its non-aux siblings). An edge is
really laid only for an ACROSS route: "the unit holding the aux (a group) runs after the unit holding
the sender". That unit gets rank + 1 (a pool slot `(stem, lane, rank)` at the root, a per-rank
combiner inside a container) exactly as for a sidechain. Sends and sidechain keys share ONE plan, so
a send can be refused `cycle` because of a key and vice versa.

`existing keyEdge` handles `host.kind == .aux` correctly as written (traced on the eight cases of
§C.1); the changes to `BridgeScope` are the static rules, `Plan.taps` (must NOT receive `auxInput`
sources — a send is one tap per PAIR, not per source), and a `sendCandidates` entry point
(`candidates` hard-codes a `.sidechain` probe, :152).

**Offer vs. validity.** Three different sets, each with one definition:

- `reachable(sender)` — auxes passing the static rules. What a send MAY target.
- `near(sender)` — today's rule (same parent; top level: same stem or Main), kept as
  `BridgeScope.isNear`. Used by the migration (§A.5) and, pending Q-U3, by the Aux tool.
- time overlap — unchanged (`reachableAuxes`: an infinite aux overlaps everything).

**Every site that must agree** (all read the one index, §B step 1.4):

| Site | File | Today | After |
|---|---|---|---|
| `canRouteSend` | `EditViewModel+Aux.swift:68` | own copy | static rule via `sendScopeIndex` |
| `reachableAuxes` (batch) | :118 | own copy | same index, plus the offer filter |
| `syncSends` | `EditViewModel.swift:2064-2071` | calls `addSend` per send | removed: `syncBridge` lays sends |
| `syncSendEngine` / `resyncAllSends` | `EditViewModel+Aux.swift:392, 409` | per-send engine calls | hot level path or `syncBridge` |
| `activeSenders(toAux:)` | :257 | `canRouteSend` | plan status (active routes only) |
| solo closure | `EditViewModel+Solo.swift:335` | `canRouteSend` | plan status |
| inspector snapshot | `EditViewModel+MultiSelection.swift:120` | `sendScope` | unchanged call, new rule |
| `-isSend:routableToAux:`, `pruneOutOfScopeSends`, the check in `addSend` | `OBJEngineCore.mm:4405, 5069, 4561` | engine copy | DELETED on the bridge path (kept only under `OBJ_SENDS_LEGACY`) |
| sender lists per mounting level | fork, `tracktion_EditNodeBuilder.cpp:901, 2499` | implicit scope | legacy only; the bridge path reads `objBridgeSends` |
| `_referenceCanRouteSend` | `EditViewModel+MultiSelectionReference.swift:31` | old rule, naive | NEW rule, written naively (two tree walks) — it must stay an independent oracle |
| `remappingSends` comment, `assignStem` comments, `OBJAuxSendPlugin.h` header, `OBJEngineCore.h:171` | — | describe the old rule | rewritten |
| `send.list` `routed` | `Commands+Aux.swift:70` | `isSendRouted` = enabled ∧ level, scope NOT consulted despite its comment | the plan's status |

**Limit cases.**

| Case | Outcome |
|---|---|
| A group sends to an aux it contains (any depth) | refused `ancestorSource`, stays in the model, silent |
| Aux A inside G, an ancestor P of G sends to A | same (`ancestorSource`) |
| X in G1 → aux in G2 AND Y in G2 → aux in G1 | no signal loop, but a scheduling one (a container is atomic): the second in model walk order is refused `cycle`. UI doors refuse to CREATE it (beep + reason); a regrouping can still produce it |
| Sender is a child of a MUTED group, aux outside that group | the group's mute is the group's own fader, downstream of the child's tap: the send would stay audible. See Q-U1 — INC 1 plans a per-send GATE folded from the audibility composition (step 1.6) |
| Muted stem, soloed-elsewhere | already pushed as −96 dB on each object's own fader (`EditViewModel+Audibility`): a post-fader tap falls silent. No change in INC 1; INC 2 reuses the gate for pre-fader taps |
| Group's fader LEVEL, FX and fades vs. a child's send to an outside aux | not applied to that send (the tap is upstream of them) — the classic "post-fader send of a track routed to a subgroup". Q-U1b |
| Stem detached from the Main | unchanged: its objects still reach a Main aux, and the wet goes to the Main (the folder enters the root sum in a `SinkNode`, the taps are written all the same) |
| Sender or aux changes stem | `assignStem` → `resyncAllSends` → `syncBridge`: the route becomes `outOfStem` (silent, kept) or comes back |
| A send that becomes refused | stays in `sends`, level and curve intact, shown inactive with its reason; never deleted by a scope change |
| Aux deleted | its sends are purged with their `.send(auxID)` automation, same undo point (P7) |
| Aux inside a group with NO other child | must now receive from outside: `createNodeForContainerClip` returns `{}` when there is no non-aux child (`tracktion_EditNodeBuilder.cpp:1044-1046`) — patch 0039 builds a silent content instead when such an aux has senders |
| Sender outside the HOST GROUP's span | silent: a container's inner graph only runs inside its span, the aux's window lies inside it. Inherent to "the return comes out in that group" |
| Restricted render (bake, consolidate, object render) | `shouldBuildAuxReturns` is false (:2532-2538): no return, as today; the tap writes a ring nobody reads |
| Export | the clone has its own plugins, hence its own rings and unknown cached ages; it converges inside its own `createNodeForEdit` |

## A.4 The model, target (P5)

```swift
struct AuxSend {                       // SoundObject.sends — THE store, one entry per auxID
    var auxID: UUID
    var levelDb: Float                 // -60 = -inf … +6
    var enabled: Bool
    var tap: SendTapPoint = .postFader // INC 2. Encoded only when != .postFader
    var plugins: [ObjectPlugin] = []   // INC 3. The mini-chain. Encoded only when non-empty
}
enum SendTapPoint: String, Codable { case postFader, preFader, input }
    // postFader = after the fader AND the window (today's point)
    // preFader  = after trimOut, before the fader
    // input     = before trimIn (after the channel-mode plugin, the instrument, the ARA source)

struct SendMarker: Codable, Equatable { var auxID: UUID }   // INC 2
extension ObjectPlugin { var sendMarker: SendMarker? }       // a THIRD container kind, childSeries == []
```

**Why a marker in the chain array for an in-chain tap, and not an anchor ("after plugin X").** The
chain array is rewritten by many gestures — reorder, delete, wrap in a parallel block, join / leave a
bin, `transferPlugins`, and `copiedRun`, which turns runs of leaves into FX link blocks on every cut
and copy. An array POSITION survives all of them for free; an anchor needs a remap at each, and its
failure mode is silent (the send moves by itself: an audible bug with no symptom in the model). A
marker's failure mode is structural and loud. Declared as a container with no series
(`isContainer == true`, `childSeries == []`), every leaf walk that goes through the centralised
traversals skips it; it naturally breaks a `copiedRun` run (U3: never inside a bin). The sites that
switch on the container kind BY HAND must be taught the third case — at least `bridgeTopology`'s
`collectLeaves`, `settingSidechain`, `bridgeLeafExists` (`EditViewModel+Bridge.swift:38-44, 166-203`),
which do not use `childSeries`, and the compile spec builder. Step 2.0 of INC 2 lists them all
(`grep fxBlock`) before a line is written.

**One truth per state.** The effective tap of a send = `.chain` if a marker naming its aux exists at
the TOP LEVEL of the object's `plugins`, else `send.tap`. A marker without a send, a second marker
for the same aux, a marker below the top level or on a bus (stem, Main, aux) are meaningless and are
dropped by one pure function `SoundObject.sanitisingSends()` (load, paste, transfer). No state is
uninterpretable.

**The two taps at the same point are equivalent** (a send does not alter the signal): their order is
cosmetic. This is what makes "one send per (object, aux)" sufficient for the model.

**Rules that follow, all for INC 2 / 3:**

- **Ids.** A marker has an id like any chain entry (unique in the project, audited by
  `debug.plugin_id_audit`). The mini-chain's plugins are ordinary `ObjectPlugin`s: every site that
  walks "all the plugins of an object" (`plugins` + `instruments`) gains a third root,
  `sends.flatMap(\.plugins)`.
- **Copies** (`derivedCopy`, cut, duplicate, split): sends travel with the object as today; markers
  with the chain; the mini-chain's plugins get fresh ids through the same primitive as the chain's
  (`copiedPlugins(of:)`), and are NEVER turned into a bin by `copiedRun` in v1 (a send's mini-chain
  is per sender by definition).
- **State capture** (`withCapturedPluginStates`): third root.
- **Undo.** Level and on/off: as today. Tap move: one point. A mini-chain edit: the plugin doors'
  own points. Whether a tap move is PATCHABLE (`isPatchable`) — to decide in INC 2 from what
  `adoptingPluginStates` needs.
- **Cross-project paste** (`CrossProjectImport.plan`, :280): already remaps or drops sends by aux; it
  must drop the marker with the send and give the mini-chain fresh ids.
- **Bake / consolidate.** Baking a chain destroys the point an in-chain tap named. Q-U6.
- **Automation.** `ParamRef.send(auxID:)` is unchanged (U2). Mini-chain parameters are
  `ParamRef.plugin` on the sender, free.

INC 1 writes none of this. It only must not contradict it — and does not: the store, the identity
and the engine plugin are the same.

## A.5 Session format and compatibility (P9)

- **21 (INC 1).** No field changes. On LOAD of a version < 21, the wider scope revives sends that
  have been silent since a regrouping. DECIDED (Q-U2, 9 Oct): they are LEFT TO SOUND — no
  `enabled = false`, no migration of the sends at all. Dangling sends are purged (P7). The session
  notice (`SessionSchema`) gains the scope paragraph (including that sends once silent by scope now
  sound).
- **22 (INC 2).** `tap` on `AuxSend`, `sendMarker` on `ObjectPlugin`. Absent keys = post-fader:
  an older session reads identically.
- **23 (INC 3).** `plugins` on `AuxSend`.
- An OLDER build opening a newer file ignores the unknown keys and plays every send post-fader with no
  mini-chain; a marker would be read as a plugin with an empty identifier and dropped by the compile
  (`failed`). Accepted; said in the notice.

---

# B. INC 1 — the wider scope: implementation plan

Branches: app `feature/sends-inc1-scope` (from `main` `f3c805c4`); engine `objekat-sends-0039` (from
`efff893e684`). Session format 21. Engine patch `engine-patches/3.5/0039-…`.

Order: tests first (1.0–1.1), pure rules (1.2), engine (1.3), app engine side (1.4), view-model
(1.5–1.7), UI (1.8), API (1.9), docs (1.10). Each step builds; steps 1.2 and 1.3a are testable on any
machine.

### 1.0 — Preliminaries (no product code)

- Debug build of `main`; note the `warning:` count as THIS branch's baseline (the memo's 1550 / 1551
  is older than ARA).
- Grep-check the invariants the design rests on: I1 `compensatesOwnPluginLatency()` overridden
  nowhere; I2 no call to `setTempoAdjustment` / `setSpeedCompensation` from `objekat/`, AbletonLink
  never enabled.
- To verify in the code, and write the answer in this plan: (a) `refreshContainerSpanForKey:`
  (`OBJEngineCore.mm:2404`) includes an AUX child in a group's span; (b) what an INFINITE aux inside a
  group does to that span (the "never an infinite container" rule, :432-440); (c) how
  `linkTarget(for:)` (`TimelineView.swift:1739`) behaves for an aux inside a CLOSED group (it returns
  nil: no lane entry).

### 1.1 — The scenario, written before the change

`tools/scenario_bridge_sends.py` (§C.3), built on `tools/bridge_scenario_common.py`. Sections A, M
(the Q8 measurement) and the reference exports of O are run against `main` AS IS and their numbers
recorded in this plan: they are the only description of how sends sound today.

### 1.2 — Pure rules: `objekat/Shared/BridgeScope.swift`

- `Refusal` gains `hostNotAux`, `stemSource`, `outOfStem`.
- `World.staticRefusal` branches on the consumer: the sidechain rules as they are; the `auxInput`
  rules of §A.3.
- `plan`: an `auxInput` route never writes `plan.taps`; `Plan` gains `sendRoutes: [Int]` (active
  `auxInput` route indices, ascending). `readerRanks` is not written for them (an aux return needs no
  gate: §A.3).
- `static func sendCandidates(sender:nodes:routes:among:) -> [(id: UUID, refusal: Refusal?)]` — one
  entry per aux node; same construction as `candidates` (routes laid once, one static check and one
  reachability query per candidate).
- `struct SendIndex` — built once from `nodes`: per id its top-level ancestor, that ancestor's stem,
  its ancestor set, its parent. `func staticRefusal(sender:aux:) -> Refusal?` and
  `func isNear(sender:aux:) -> Bool` in O(depth). This is what the batch sites read.
- `tools/fixtures/bridge_scope_cases.json`: the cases of §C.1; `tools/test_bridge_scope_reference.py`
  and `tools/test_bridge_scope.swift` extended (the JSON consumer already carries a `kind`).

### 1.3 — Engine: patch `0039` (fork branch `objekat-sends-0039`)

a. **Core** (`plugins/tracktion_ObjBridgeCore.h`, tested by `tools/test_bridge_core.cpp`):
   `int declaredGroupLatency (int referenceLatency, const int* cachedAges, int n)` =
   `max (ref, max cached)` (unknown = 0); `GroupResolution resolveGroup (int ref, int declared,
   const int* trueAges, const bool* built, int n)` → per reader `{delay = declared − age, status}`,
   the GROUP `late` if any built age > declared, `overDeclared` if `declared > max (ref, max built
   age)`. A reader whose tap is not built is `sourceAbsent` and asks for nothing.

b. **`BridgeBuild`** (`plugins/tracktion_ObjBridge.h/.cpp`):
   `std::vector<int> registerAuxReaders (EditItemID auxClipID, const std::vector<EditItemID>& tapIDs,
   int referenceLatency)` — one `ReaderEntry` each (`Consumer::auxInput`, `groupKey` = the aux's raw
   id, `destID` = the aux clip), all with the SAME `declared`. `finalise` resolves `auxInput` readers
   per group (step a), the others as today. The report gains `aux` and the group's `declared`.

c. **`BridgeTapNode`** (`playback/graph/tracktion_ObjBridgeNodes.h/.cpp`) — the copy mode, when
   `tapSource.processesTapCopy()`: a scratch buffer (2 channels × block size) allocated in
   `prepareToPlay`; ctor / dtor call `baseClassInitialise` / `baseClassDeinitialise` on the plugin as
   `PluginNode` does (`tracktion_PluginNode.cpp:54, 307`); `process`: pass the input through
   UNCHANGED, copy it to the scratch (mono duplicated), `plugin->prepareForNextBlock (edit time)`,
   `plugin->applyToBufferWithAutomation (…)` on the scratch ONCE for the whole block, write the
   scratch to the ring. A disabled plugin writes silence (a covered run of zeros). The edit time
   handed over is moved back by the node's latency, as `PluginNode` does, so a level curve lands on
   the material it was drawn against.

d. **`ObjAuxReturnNode`** (`playback/graph/tracktion_ContainerClipNode.h:109-176`, `.cpp:282-525`):
   an extra ctor argument `(std::shared_ptr<BridgeBuild>, std::vector<int> readerIndices)`. With
   readers: `referenceLatency` becomes the group's declared `X` (`getNodeProperties`, the window
   clear at :510); `prepareToPlay` fetches each `readerPlan`; `process` reads each ring at
   `referenceSampleRange.start − delay` into a scratch and adds it, updating the reader's counters.
   The `dependency` edge is kept: it is what orders every sender of the level. The legacy `senders`
   vector and its delay lines are untouched (empty on the bridge path).

e. **`createAuxReturns`** (`tracktion_EditNodeBuilder.cpp:912`): for each aux clip, read
   `auxClip->state[objbridge_ids::sends]` (new identifier `"objBridgeSends"`, a comma-separated list
   of `EditItemID`s); keep the ids for which `params.bridgeBuild->hasTap (id)` and whose
   `getBridgeTargetAuxClipID()` equals the aux's id (the declared hook, used as a consistency check);
   `registerAuxReaders` with `contentProps.latencyNumSamples`. No bridge build (a render outside
   `createNodeForEdit`) or an empty list → the legacy `sendersFor` path, byte-identical to today.

f. **A group whose only children are auxes** (`createNodeForContainerClip`, :1044-1046): when
   `clips.isEmpty()` but an aux of `auxClips` carries a non-empty `objBridgeSends`, build a silent
   2-channel content node instead of returning `{}`. To verify: which silent node is usable here
   (`tracktion_graph`'s `SilentNode` lives in `tracktion_TestNodes.h:182`).

g. Export the patch by the README's procedure (`engine-patches/3.5/README.md`), add its entry there,
   publish the fork branch, move the gitlink. The fork's own history is the ONLY other copy.

### 1.4 — App, engine side

- **`objekat/OBJBridgeSendPlugin.h`** — `te::ObjBridgeSendPlugin : Plugin, BridgeTapSource`,
  `xmlTypeName = "objBridgeSend"`; the level parameter of `ObjAuxSendPlugin` (same
  `ObjGainDbParameter`, id `"level"`, so the automation push at `OBJEngineCore.mm:8395` finds it
  unchanged), `auxClip` property; `processesTapCopy()` true; `getBridgeTargetAuxClipID()`;
  `applyToBuffer` scales the buffer IT IS GIVEN (the node hands it the scratch) through the 50 ms
  smoother; `≤ −60 dB` is exact silence (P8). Registered at `OBJEngineCore.mm:1709`.
- **`OBJEngineCore`**, inside the bridge transaction (`MARK: - The audio bridge`):
  `- (void)ensureBridgeSendFrom:(NSString*)sender toAux:(NSString*)aux levelDb:(float)db gated:(BOOL)gated`
  — registry `_bridgeSendMap["sender|aux"]`, touched-set `_bridgeTouchedSends`; the same three cases
  as `ensureBridgeTapForSource:` (still in the list → update; present but unregistered → adopt, by
  its `auxClip`; else insert at `pl->size()`); RETARGETS when the aux clip's id changed (an aux
  rebuilt by an undo — the special case of `EditViewModel+UndoRedo.swift:240-247` then has nothing
  left to do); sets `objBridgeRank` −1 and `objBridgeSource`.
  `commitBridgeSync`: removes the sends the sync did not touch; then, for every key of `_auxKeys`,
  rewrites `objBridgeSends` on its clip from the registry (sorted, written only on change) — each
  change sets `_bridgeDirty`.
  `setSendLevel:toAux:levelDb:` (hot, no rebuild) and a new `setSendGated:` look in the new registry.
  `removeAux:` (:4514) drops the registry entries aimed at it. The automation lookup (:8395) reads
  the new registry. `bridgeReport` passes the new fields through.
- **Legacy switch.** `OBJ_SENDS_LEGACY=1` (environment, read once): `ensureBridgeSend…` forwards to
  the old `addSend:` (with its `-isSend:routableToAux:` check), nothing is written to
  `objBridgeSends`. Without it, `addSend:` / `removeSend:` / `-isSend:routableToAux:` /
  `pruneOutOfScopeSends` are not called at all. They are deleted in INC 2.

### 1.5 — View-model: topology and sync (`EditViewModel+Bridge.swift`, `+Aux.swift`)

- `bridgeTopology()`: after an object's key routes, one route per ALIVE send
  (`enabled && (!isSilent || isAutomated(.send))`), in `sends` order;
  `routeOwners` becomes an enum (`.plugin(host:, plugin:)`, `.send(sender:, aux:)`). Not-alive sends
  are not routes (they cost nothing and block nothing).
- `syncBridge()`: for each `plan.sendRoutes` → `engine.ensureBridgeSend(from:toAux:levelDb:gated:)`;
  refused or absent ones are removed by the commit. `bridgeEngineHasTaps` also counts sends.
  New published state `sendRouteStatus: [SendKey: BridgeScope.Refusal]` (written only on change).
  After the commit, when the SET of laid sends changed, push the automation of the senders that carry
  a `.send` curve (a send laid by this sync is a brand-new plugin).
- `syncSendEngine(objectID:auxID:)`: if the send's alive-state equals what the last sync laid →
  `engine.setSendLevel` (the knob's per-frame path: no plan, no rebuild); else
  `scheduleBridgeSync()`.
- `resyncAllSends()`: `syncBridge()` FIRST, then `pushAllAutomation()` (today the order is the
  reverse, :421-426, which was right only because `addSend` had already run in the walk above).
- `syncSends(_:)` (`EditViewModel.swift:2064`) and its three callers in `syncAdd`, plus
  `EditViewModel+Groups.swift:111`: replaced by `scheduleBridgeSync()`.
- `canRouteSend`, `reachableAuxes`: read `sendScopeIndex` (a cached `BridgeScope.SendIndex`,
  invalidated beside `parentIDCache` in `items.didSet` and in `stems.didSet`).
  `sendStatus(from:to:) -> .off | .active | .refused(Refusal)` is what `isSendRouted`, the API's
  `routed`, `activeSenders` and the solo closure read.
- Doors of the HAND (`setSendLevelFromHand`, the selection setters, the new menu and pick): refuse to
  create a send that `sendCandidates` refuses (beep, reason shown). `setSendLevel` / `setSendEnabled`
  stay exact and unconditional (the machine's door, as today).
- `_referenceCanRouteSend` rewritten for the new rule, naively.

### 1.6 — Audibility gate (isolated: its behaviour is Q-U1)

`AudibilitySnapshot` gains `func sendIsGated(sender:aux:) -> Bool`: true when an ancestor group of
the sender is silenced (muted and not reopened by a direct solo) and is NOT an ancestor of the aux.
Pushed by `refreshAudibility` / `pushMixTree` through `engine.setSendGated` (hot), and at
`ensureBridgeSend`. If the user answers "a group's mute does not reach its children's outside
sends", this step is dropped and nothing else changes.

### 1.7 — Load migration and dangling sends

- `EditViewModel+ProjectLoad.swift` (before `resyncAllSends`, :363): for `version < 21`, the
  migration of §A.5 (Q-U2), then `sanitise` (dangling sends and their curves).
- Deleting an aux (`EditViewModel+Edit.swift:81` and the paths that reach it): purge the sends and
  `.send(auxID)` lanes aimed at it, inside the gesture's undo point.
- `SessionSchema.formatVersion = 21` and the notice; `scenario_markers.py` pins the format number.

### 1.8 — UI, the minimum

- **Sends zone of the signal view** (`SendsZoneView`, `SynopticView.swift:2299`; rows built at
  :2637-2645 from `sendToolAuxes`): rows = `near` auxes ∪ auxes the object already has a send to
  (overlapping in time); a refused one is greyed with its reason as a tooltip. Under the rows, a
  "Send to…" control: a menu of the reachable auxes that overlap, grouped Main / stem / group path
  (refused entries disabled with their reason, as the Sidechain menu), and "Pick on the timeline".
- **Pick mode**: `SidechainPick` (`EditViewModel+SidechainStrip.swift:5, 140-180`) generalised to a
  `RoutePick` enum (`.sidechain(host:, plugin:)`, `.send(sender:)`); the timeline's veil, HUD and Esc
  (`TimelineView.swift:1034, 1637, 4356-4376`, `TimelineKeyHandler.swift:599`,
  `TimelineView+TapHandler.swift:26`) read the enum; in send mode only auxes are valid targets and a
  click creates the send enabled at 0 dB (Q-U4).
- **Aux tool (A)** and **multi-selection inspector**: `sendToolAuxes` / `sendScope` return
  `near ∪ existing sends` (Q-U3). No geometry change (`SendColumns.swift`).
- **Wires** (`drawSendLinks`, `TimelineView.swift:1759`): a wire to an aux inside a CLOSED group
  lands on the nearest visible ancestor's block instead of not being drawn.
- **An aux's "received" list**: nothing to do (`activeSenders`), far senders appear.
- i18n: reasons (`outOfStem`, `hostNotAux`), "Send to…", "Pick on the timeline", the HUD line — three
  languages, `tools/i18n/xcstrings.py check`.

### 1.9 — API (`CommandAPI/Commands+Aux.swift`, `docs/command_api.md`)

- `send.list`: `routed` becomes what the plan wires; adds `status` (`off` / `active` / `refused`),
  `refusal`, `reachable_auxes` (static rule) beside `available_auxes` (the offer).
- `send.candidates {id}` → `[{aux, name, group_path, stem, overlaps, refusal}]`.
- `send.remove {id, aux}` (there is no way to delete an entry today).
- `send.set_level`, `send.adjust_level`, `send.enable`: unchanged contracts.
- `debug.bridge_report`: `readers[].consumer == "auxInput"`, `aux`, the group's `declared`;
  `model.send_routes`.
- `app.info` (or `debug.bridge_report.build`): `sends_path: "bridge" | "legacy"`.

### 1.10 — Documentation

`CLAUDE.md` (a "Current state" entry: what landed, what was measured where, what was NOT heard or
seen; next engine patch `0040`; the stale "next one will be `0038`" line), this plan's status line
and the recorded numbers of 1.1, `docs/plan_sidechain.md` (D8 and Phase 2 marked superseded, Q8
closed with its measurement), `docs/architecture_decisions.md` (one entry: sends on the bridge, the
rule in one place), `docs/command_api.md`, `engine-patches/3.5/README.md` (`0039`), the scope comment
block of `EditViewModel+Aux.swift:40-65`, `OBJEngineCore.mm:4364-4381`, `OBJEngineCore.h:171`,
`OBJAuxSendPlugin.h`.

---

# C. INC 1 — test plan

Run by the test agent after implementation, in this order. Everything is a Debug build unless said.

## C.1 Pure tests (any machine)

Case table `tools/fixtures/bridge_scope_cases.json`, read by both programs. New cases (`S*` senders,
`A*` auxes, `G*` groups, `X` / `Y` stems), each with the expected `refused`, ranks and `sendRoutes`:

| # | Case | Expect |
|---|---|---|
| 1 | siblings at the Main | active, no rank |
| 2 | siblings in stem X | active, no rank |
| 3 | sender in stem X → aux at the Main | active, no rank |
| 4 | sender at the Main → aux in stem X | `outOfStem` |
| 5 | sender in X → aux in Y | `outOfStem` |
| 6 | siblings inside G | active, no rank |
| 7 | child of G → aux at the top level (same stem; then the Main) | active, no rank |
| 8 | grandchild (G › H › S) → aux child of G | active, no rank |
| 9 | grandchild → aux at the Main | active, no rank |
| 10 | top-level S → aux inside G2 | active, `rootRanks[G2] = 1` |
| 11 | child of G1 → aux inside G2 | active, `rootRanks[G2] = 1` |
| 12 | S child of G → aux inside H, H child of G | active, `innerRanks[H] = 1` |
| 13 | child of G1 (stem X) → aux inside G2 (Main) | active, `rootRanks[G2] = 1` |
| 14 | child of G1 (Main) → aux inside G2 (stem X) | `outOfStem` |
| 15 | G → aux it contains; and one level deeper | `ancestorSource` |
| 16 | P (ancestor of G) → aux inside G | `ancestorSource` |
| 17 | aux → aux; stem → aux; Main → aux | `auxSource`, `stemSource`, `mainSource` |
| 18 | host is not an aux | `hostNotAux` |
| 19 | X∈G1 → aux∈G2 and Y∈G2 → aux∈G1 | second `cycle` |
| 20 | send S∈G1 → aux∈G2 plus a sidechain key G1 ← object in G2 | the later in input order `cycle` |
| 21 | chain: S → aux∈G2, T∈G2 → aux∈G3 | ranks 0 / 1 / 2 |
| 22 | deleted aux; deleted sender | `unknownHost`; `unknownSource` |
| 23 | `sendCandidates` equals "a full plan with the candidate appended last" on cases 1–22 | equality |
| 24 | `SendIndex.staticRefusal` equals `World.staticRefusal` on every (object, aux) pair of every case; `isNear` equals the legacy rule | equality |

```sh
cd /Users/nicolasvair/Documents/Xcode/Objekat/objekat
python3 tools/test_bridge_scope_reference.py
swiftc -parse-as-library objekat/Shared/BridgeScope.swift tools/test_bridge_scope.swift -o /tmp/bs && /tmp/bs
clang++ -std=c++17 -Wall -Wextra -Werror -I tracktion_engine/modules/tracktion_engine/plugins \
    tools/test_bridge_core.cpp -o /tmp/bc && /tmp/bc
```
`test_bridge_core.cpp` gains the group cases: all younger (`X = ref`, no re-pass); one older
(`X = age`, the others delayed); cached too low → `late`; cached too high → `overDeclared`; one tap
not built → `sourceAbsent`, the group still resolves; n = 0.

## C.2 Build

`xcodebuild -project objekat.xcodeproj -scheme objekat -configuration Debug build` — warnings against
the baseline of 1.0, none on a line this branch added. `python3 tools/i18n/xcstrings.py check`.

## C.3 `tools/scenario_bridge_sends.py` — the audio proof

Launch (its OWN fresh instance, audio ON — the bridge reads the device clock; the script exits 2 if
`app.info.audio_running` is false):

```sh
<Debug>/objekat.app/Contents/MacOS/objekat --headless --api --no-recent --language=en --socket=/tmp/os.sock
python3 tools/scenario_bridge_sends.py /tmp/os.sock /tmp/trial_sends/project.objekat
```

**Method.** Fixtures generated (48 kHz / 24-bit): an impulse at 1 s, a 1 kHz sine. The wet is
measured by DIFFERENCE, never by panning (a hard-left sender into a hard-right aux depends on the pan
law, and a mono object is duplicated left → right at the end of its chain — the trap that made
`scenario_bridge_latency` vacuous once): export E_on, export E_off with the send disabled,
`wet = E_on − E_off`, `dry = E_off`. Offline renders of these built-ins are deterministic; the script
first asserts it (two identical exports subtract to zero). Then: `idx(peak wet) == idx(peak dry)`
(aligned to the sample), `20·log10 (peak wet / peak dry) == send level ± 0.05 dB` with a unity aux.
Latency comes from the engine's `latencyTester` (`debug.add_test_plugin`). After each case,
`debug.bridge_report`: `build.converged`, every `auxInput` reader `aligned`,
`alignment_error_samples == 0`, `blocks_torn == 0`.

| § | What | Assertion |
|---|---|---|
| A | In-scope, as today: siblings at the Main, in a stem, inside a group; send at −6 dB | level and index; `passes == 1` |
| B | Upward: child → Main aux; grandchild → Main aux; child of a group of stem X → top-level aux of X; grandchild → aux of its grandparent group | level and index; no rank (`gate_edges == 0`) |
| C | Across: top-level → aux inside G2; child of G1 → aux inside G2; the return goes THROUGH G2's chain (G2 trimOut −12 dB → wet 12 dB lower) | level, index, `gate_edges > 0`, G2 on a rank-1 slot |
| D | Latency, 20 ms `latencyTester`: on the sender before the tap; on the aux's FX; on the sender's group; on a sibling of the sender; on G2's chain; on an unrelated object of the aux's level; all at once | `idx(wet) == idx(dry)` in every case; the across case with an OLDER tap reports `passes == 2` on its first build, then 1 |
| E | Stem limit: sender in X → aux in Y: `send.candidates` says `outOfStem`; forced through `send.set_level`: entry kept, `status: refused`, wet < 1e−6; sibling-stem sends untouched | — |
| F | Refusals: group → its own aux; aux as sender; the two-group cycle (second refused and silent, first unchanged) | status + silence |
| G | Undo / redo: lay a send (E1), undo (no wet), redo (subtracts to zero against E1); same for a level change and an on/off | null |
| H | Save, reopen (`project.save_as`, reopen): export subtracts to zero against E1; `send.list` identical | null |
| I | Duplicate the sender (wet +6.02 dB ± 0.05); split the sender across the impulse (one wet, same index); split the AUX (`duplicateSendsTarget`: both halves fed) | level, index |
| J | Group the sender alone (send stays ACTIVE and identical — it went silent under the old rule); ungroup; group sender + aux; move the aux into another group (wet now through that group's chain); dissolve | level, index, status after each |
| K | Stem change: sender to stem Y (send to X's aux → `outOfStem`, silent), back (identical); aux to the Main (reachable from Y) | status, null |
| L | Mute the sender (wet silent); mute its STEM; solo another object; mute the sender's GROUP with the aux outside it (silent if Q-U1 = yes); a direct solo of the sender opens the aux | silence / presence |
| M | **Q8.** 1 kHz sine, send level AUTOMATED: (1) a flat curve at −6 dB: the wet's RMS over every 10 ms window equals the dry's − 6 dB ± 0.1; (2) a ramp −30 → 0 dB over 1 s: the wet's envelope follows it within 1 dB (the 50 ms smoother) and has no hole. Run on `main` first — the numbers are recorded as Q8's answer — then on the branch, where both must pass | RMS per window |
| N | Sub-block splits: the sender inside a LOOPING group (loop shorter than the group), sending to a Main aux: the wet of each loop turn has the same RMS, no hole at the wrap; and a transport loop over the whole session | RMS per turn |
| O | **Null test, legacy vs bridge.** The sessions of A and of D restricted to in-scope routes, exported by an instance launched with `OBJ_SENDS_LEGACY=1`, then by a normal one: `max |difference| ≤ 1 LSB` (24-bit) | null |
| P | Migration: a hand-written format-20 session with an enabled send that the old rule did not route: on open `enabled == false`, level kept, no wet; a dangling send is gone | model + silence |
| Q | Windows: sender outside the aux's window (silent); an infinite aux; a sender outside the HOST group's span (silent) | silence / presence |
| R | A group holding ONLY an aux, fed from outside | wet present, level |
| S | Rebuild cost: 200 objects each with one send to a Main aux: steady-state `passes == 1`, ONE `build.id` increment for a `resyncAllSends`; no `late`, no `over_declared` | counters |
| T | Live graph: play 2 s, `debug.bridge_report`: `blocks_read > 0`, `blocks_torn == 0` on every `auxInput` reader | counters |

Mutants the scenario must catch (run once, by hand, and noted in the plan): a return that ignores the
reader's delay (D fails); a level applied at the reader (M2 misaligned with a latency before the
tap); `outOfStem` removed (E fails).

## C.4 Non-regression — each against its OWN fresh instance

```sh
APP=<Debug>/objekat.app/Contents/MacOS/objekat
# audio OFF is fine for these:
$APP --headless --api --no-recent --no-audio --language=en --socket=/tmp/o.sock &
python3 tools/scenario_selection_send_scope.py /tmp/o.sock /tmp/trial_sendscope --seed 7 --selections 200
python3 tools/scenario_families.py /tmp/o.sock /tmp/trial/project.objekat.json
python3 tools/scenario_markers.py /tmp/o.sock
python3 tools/scenario_plugin_state_undo.py /tmp/o.sock /tmp/trial/project.objekat.json
python3 tools/scenario_plugin_selection.py /tmp/o.sock
python3 tools/scenario_export_preview.py /tmp/o.sock /tmp/trial/project.objekat.json
python3 tools/scenario_fxlink.py /tmp/o.sock
python3 tools/scenario_consolidate.py /tmp/oc.sock
python3 tools/scenario_tabs.py /tmp/o.sock /tmp/trial_tabs
python3 tools/scenario_cross_paste.py /tmp/o.sock /tmp/trial_cross_paste
python3 tools/scenario_relink.py /tmp/o.sock
python3 tools/scenario_channel_mode.py <Debug>/objekat.app
python3 tools/scenario_ara.py <Debug>/objekat.app
$APP --headless --no-recent --no-audio --language=en --exec=tools/smoke.jsonl
# audio ON (they exit 2 otherwise):
$APP --headless --api --no-recent --language=en --socket=/tmp/o.sock &
python3 tools/scenario_sidechain.py /tmp/o.sock /tmp/trial/project.objekat
python3 tools/scenario_bridge_latency.py /tmp/o.sock /tmp/trial/project.objekat
# standalone Swift tests touched by this branch:
swiftc … tools/test_cross_project_import.swift     # compile line in its header
swiftc … tools/test_send_columns.swift
swiftc … tools/test_tool_overlay_partition.swift
```
`scenario_selection_send_scope.py` is the one that MUST change with the rule: its oracle
(`_reference…`) is rewritten in step 1.5, and it gains nested and cross-group fixtures.
`scenario_families.py` asserts send behaviour through the API; every assertion that encoded the old
scope is listed in the report, not silently edited. Then `debug.plugin_id_audit` (0) and
`CGWindowListCopyWindowInfo` on the headless pid (no window).

## C.5 What only a person verifies (the gate before INC 2)

A reverb at the Main fed by clips inside groups, in a real session: the sound, stop / start, a loop,
seeking; the group moved while playing; mute and solo of a group whose children send outside; the
"Send to…" menu and the pick mode; the wires to an aux in a closed group; an OLD project opened (same
sound; the previously silent sends shown off); CPU with a few across routes (rank tiers reduce
parallelism).

---

# D. Sketches

## D.1 INC 2 — a positionable send, the send card (branch `feature/sends-inc2-tap`, format 22)

**Steps.**
0. Inventory: every site that switches on `rack` / `fxBlock` by hand or assumes a non-container
   entry is a plugin; delete the legacy send path and its switch.
1. Model: `AuxSend.tap`, `ObjectPlugin.sendMarker`, `sanitisingSends`, `effectiveTap`; the hand-rolled
   walks moved onto `childSeries`.
2. Compile: `rackSpec` emits a `send` node for a marker; `compileSeries` (`OBJEngineCore.mm:8007`)
   places the `ObjBridgeSendPlugin` there, keyed `"send|sender|aux"`, reused across recompiles like
   any plugin key; `input` / `preFader` / `postFader` are placed against the chain's anchors
   (`trimIn`, the fader, the end). The transaction of INC 1 keeps owning existence and level; the
   compile owns POSITION. To settle: one owner for the insertion, so that a recompile and a bridge
   sync never fight (proposal: the bridge sync creates, `compileUserRack` only reorders, and a tap
   move triggers a compile).
3. Gate: with a pre-fader tap, the object's own mute / stem mute / solo no longer silence the send
   through the fader — the INC 1 gate (step 1.6) becomes the general rule "a silenced sender sends
   nothing".
4. Signal view: the send CARD on the trunk (`SynopticLayout`, `SynopticModelMapping`,
   `SynopticView`): level, on/off, target (menu + pick), its wire leaving the trunk; drag along the
   trunk and to the three fixed points; drop refused inside a parallel block or a bin; the foot zone
   becomes the post-fader slot. A send card is NOT part of `selectedPluginIDs` (as an instrument is
   not): it has its own highlight.
5. API: `send.set_tap {id, aux, tap | after: pluginID | index}`, `tap` in `send.list`.
6. Tests: marker geometry and sanitising (standalone Swift); the scenario's sections re-run with the
   tap at each point — a gain plugin of −12 dB before / after the tap proves WHERE it taps, a
   `latencyTester` before / after proves the alignment; `copiedRun` after a cut keeps the tap between
   the same two plugins; one undo per move.

**Risks.** The hand-rolled chain walks (a marker read as a plugin is dropped by the compile's
`failed` list → the model loses it); two owners of one engine plugin; `maxPluginsOnClip = 45` now
shared with sends (a session with many sends per object); the Aux tool and the card being two doors
onto the same level.

**Open questions (the user's).** Q-U5 a mid-chain tap is taken BEFORE the object's window and fades:
does the send follow the object's fades anyway? Q-U6 baking / consolidating an object with an
in-chain send: the tap point is destroyed — refuse, fall back to post-fader with a notice, or bake the
send's side too? Q-U7 the card's look and where a post-fader send is drawn (a card after the fader,
or the foot zone as today).

## D.2 INC 3 — plugins on the send (branch `feature/sends-inc3-chain`, format 23, engine patch `0040`)

**Steps.**
1. Engine `0040`: `BridgeSendBranch { PluginList* getSendChain(); }` beside `ParallelPluginBlock`;
   the unfolding of §A.2 in `createPluginNodeForList`; no mini-chain → the INC 1 node, unchanged.
2. App: `ObjBridgeSendPlugin` owns one `PluginList` (a `<BRANCH>` child, as
   `ObjParallelBlockPlugin`); `compileSeries` recurses into it with the send plugin's own level as
   the anchor (plugins before the level, like a branch's gain).
3. Model: `AuxSend.plugins`; the third root in every "all plugins of an object" walk (state capture,
   id audit, link groups, sidechain routes, `checkLatencyAndRebuild`'s map, cross-project import,
   copies with fresh ids).
4. Signal view: the card unfolds its mini-chain (a short series, the bin's drawing reused); drop a
   plugin on the card; the picker's "+" on it; editors open as usual.
5. Tests: a −12 dB gain in the mini-chain lowers the wet by 12 dB and the dry by 0; a 20 ms
   `latencyTester` in it keeps `idx(wet) == idx(dry)` and raises the object's declared latency; two
   senders to one aux, a filter on one only (the other's wet unchanged — the point of the feature);
   undo, save / reopen, duplicate, cut; a keyed (sidechain) plugin inside a mini-chain.

**Risks.** A mini-chain with latency delays its sender's dry (compensated, but the session's total
latency rises — to say in the UI?); a reverb's tail in a mini-chain is cut at the object's end like
any chain plugin's; plugin count per clip; an AU instantiated per sender (a mini-chain is not
shared — sharing would be an FX link bin, excluded in v1).

**Open questions (the user's).** Q-U8 can a mini-chain plugin be LINKED (⌘) to the same plugin on
another sender's send, or be an FX link bin, so that "the same low-pass on every send to this reverb"
is one setting? Q-U9 a parallel block inside a mini-chain: allowed or series only?

---

# E. Open questions

## For the user — audible or visible behaviour, not decided here

| # | Question | What the plan assumes until answered |
|---|---|---|
| Q-U1 | A child of a MUTED group sends to an aux OUTSIDE that group. Does the group's mute silence that send? | ANSWERED 9 Oct: YES (step 1.6 is built, no longer droppable). |
| Q-U1b | Same child: do the group's FADER LEVEL, FX and fades act on that send? Technically they cannot without tapping after the group; the classic answer is no. | No — said in the documentation. |
| Q-U2 | Old projects hold sends that went silent after a regrouping and that the new scope would revive. On opening: keep them silent (switched off, visible) or let them sound again? | ANSWERED 9 Oct: LET THEM SOUND (no `enabled = false` at migration). |
| Q-U3 | The Aux tool (A) and the inspector: one knob per REACHABLE aux (possibly dozens per block) or only the near ones plus the sends that already exist, the far ones being created from the signal view? | ANSWERED 9 Oct: ALL reachable auxes (time-overlap filtered), ordered same group / rest of the stem / Main. Menu and pick postponed to INC 2. |
| Q-U4 | A send created by the menu or the pick mode starts at 0 dB, or at −∞ waiting for the knob? | ANSWERED 9 Oct: -inf (silent). |
| Q-U5 | (INC 2) A mid-chain tap is before the object's fades: follow the fades anyway? | Not assumed — blocks INC 2 step 2. |
| Q-U6 | (INC 2) Bake / consolidate with an in-chain send. | Not assumed. |
| Q-U7 | (INC 2) The card: where a post-fader send is drawn. | Foot zone, as today. |
| Q-U8, Q-U9 | (INC 3) Linking / bins and parallel blocks in a mini-chain. | Neither in v1. |
| Q-U10 | Two groups each sending into an aux of the other is refused (a scheduling loop, no signal loop). Acceptable, with the reason shown? | ANSWERED 9 Oct: accepted, reason shown. |
| Q-U11 | A stem DETACHED from the Main still feeds a Main aux today (unchanged by this plan). Wanted? | ANSWERED 9 Oct: unchanged. |

## Settled by this plan (reversible, listed so they can be contested)

P1–P9 above; the wet is measured by difference; the legacy path survives INC 1 only; the hand's
doors refuse a cycle-closing send while the machine's door stores it; refused sends are shown
inactive rather than hidden; `send.remove` exists.

## Technical, to verify during INC 1 (no user decision)

- T1 the span of a group holding an aux, and an infinite aux inside a group (step 1.0).
- T2 the silent content node for a group of auxes only (step 1.3f).
- T3 `applyToBufferWithAutomation` called outside a `PluginNode`: what `PluginRenderContext` it
  needs, and that the level parameter's automation stream advances once per block.
- T4 a transport jump: the reader's `D` samples after it (silence by design in the sidechain plan,
  F7) versus the legacy delay line, which played the pre-jump material — heard on a reverb? Section N
  measures the loop case; the jump is for the ear.
- T5 rank changes move a group to another pool track (one rebuild); Q4 of the sidechain plan (a MIDI
  child changing rank while playing) now also reachable through a send.
- T6 `maxBridgePasses = 8` against chains of across sends (case 21): one pass per rank level.

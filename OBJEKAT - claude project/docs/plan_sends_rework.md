# Plan — the sends rework: wider scope, a tap anywhere on the trunk, plugins on the send

Status (9 October 2026): INC 1 IMPLEMENTED and MEASURED on `feature/sends-inc1-scope` (nothing merged, nothing pushed; engine patch `0039` on the fork branch `objekat-sends-0039`, `fb0ae39e631`). Remains: the eye and the ear (section C.5). INC 2 and INC 3 are not started.
Status (10 October 2026): INC 2 IMPLEMENTED, MEASURED and tried on screen by the user ("works very well") on `feature/sends-inc2-position` (journal D.1.F; nothing merged, nothing pushed), plus the refusal to consolidate an object carrying a pre-fader send (`2fc674e5`). INC 3 is DESIGNED in section D.2 (design, steps, tests, questions) and NOT started; D.2 supersedes decision P6 and the "INC 3 (P6)" paragraph of §A.2.
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

**Second round, same day, for INC 2** (detailed in section D.1):

| # | Subject | Decision | Consequence for INC 2 |
|---|---|---|---|
| Q-U5 | Fades and window on a mid-chain send | A send taken anywhere in the chain FOLLOWS the object's fades and window (attenuated by fade-in / fade-out, cut outside the window). The object's volume and pan do NOT apply to a pre-fader send. | D.1.A.e: the window-fade envelope is applied to the sent copy; the direct signal is untouched. |
| Q-U6 | Consolidate / bake of an object carrying a mid-chain send | "Ask the user." Read by the launcher as: an alert at the moment of the operation offering fold back to post-fader / delete the send / cancel. **INTERPRETATION TO CONFIRM.** | D.1.A.i and step 2.8, isolated; headless: explicit parameter, default `refuse`. |
| Q-U7 | Where sends are drawn | ALL sends are cards in the signal view. A post-fader send is a card UNDER the pan / volume zone; dragging it upwards moves it into the chain. The fixed "aux" zone at the foot disappears for outgoing sends. | D.1.A.j. The aux bus head (received sends) is not concerned. |
| — | Choosing the target of a new send | As for the sidechain: a "Send to…" menu (reachable auxes, order same group / rest of the stem / Main, refused ones greyed with the reason) and the "choose an object" mode on the timeline. The Aux tool (A) and the multi-selection inspector keep setting the level per (object, aux), whatever the position. | Step 2.11 (`SidechainPick` generalised). |

**Third round (confirmed by the user through the coordinator, during the INC 2 implementation) — the three
hypotheses below are DECISIONS now; the text of D.1 that calls them hypotheses or "interpretation to
confirm" is superseded by this table:**

| # | Subject | Decision | Consequence for INC 2 |
|---|---|---|---|
| Q-U12 | Mute / solo of an object sending taken before the fader | CONFIRMED as planned: an object that is muted, or silenced by another's solo or by its stem's mute, feeds no aux, even pre-fader / in the chain / at the input. | Step 2.5 stands as written (`sendIsGated` also true when the sender itself is silenced and its tap is not post-fader). |
| Q-U6 | Consolidate / bake with a mid-chain send | CONFIRMED as planned: an alert at the moment of consolidating (fold to post-fader / delete the send / cancel); API parameter `mid_chain_sends` = `refuse` (default) / `fold` / `remove`. | Step 2.8 stands as written. |
| Q-U13 | Which sends the signal view draws | CONFIRMED: only the sends that exist are drawn as cards; the other reachable auxes are reached through "Send to…". | Steps 2.9–2.11 stand as written. |

**Fourth round (10 October 2026, after INC 2 was tried on screen):**

| # | Subject | Decision | Consequence |
|---|---|---|---|
| Q-U7b | Where the send cards are drawn | ACCEPTED as built: a column to the RIGHT of the trunk, each card wired to the trunk at its position. | D.1.F's deviation from A.j is the reference; INC 3 builds on that column (D.2.A.l). |
| Q-U14 | Where "Send to…" is reached | ACCEPTED as built: the right-click on a "+" of the trunk. | Nothing to do. |
| Q-U6b | Consolidating an object that carries a `pre_fader` send | REFUSED, with an alert, "for the moment" (the bake renders the fader into the wave, so the send would not hear the same level afterwards). `input` / `chain` sends keep the alert Fold / Delete / Cancel. | Built in `2fc674e5` (`SendBakePolicy.preFaderBlockers`; API `invalid_state` `pre_fader_send`, whatever `mid_chain_sends`). Supersedes "a `pre_fader` send is not concerned" in D.1.A.i and in Q-U6 of section E. Only the object's OWN sends count (not a baked group's children); a placement that is already an instance never blocks. |
| — | Limit observed | 20 entries per object chain: 16 plugins without a send, each send takes one entry; beyond, the send is refused (`chainFull`). | Known and accepted; a send's plugins (INC 3) do not count in it (D.2.A.f). |

## Decisions taken in this plan (the architect's, each justified below)

| # | Subject | Decision |
|---|---|---|
| P1 | Engine mechanism | **Everything on the bridge.** One send = one engine plugin that is a `BridgeTapSource` writing a ring; one aux return = N bridge readers sharing one declared latency. The legacy `ObjAuxSendPlugin` / `ContainerAuxSend` path stays COMPILED for INC 1 only, behind `OBJ_SENDS_LEGACY=1`, as the null-test oracle; it is deleted at the start of INC 2. |
| P2 | Who names the senders of an aux | The APP, not a scan: the aux clip's state carries `objBridgeSends` (the list of its send plugins' ids), written in the bridge transaction. Same shape as `sidechainSourceID` on a keyed plugin. |
| P3 | Where the level is applied | At the TAP (on the copy, once per block), never at the reader: an automated level must be aligned with the material it scales. Settles Q8 for every send. |
| P4 | The scope rule | ONE pure definition in `Shared/BridgeScope.swift` (static refusals for an `auxInput` route + the cycle check), read by every site through one cached index. The engine keeps NO copy of the rule. |
| P5 | Model, target | `AuxSend` stays THE store, keyed by `auxID`. INC 2 adds `tap` (`postFader` / `preFader` / `input`) and a thin MARKER entry in the chain array for an in-chain tap; INC 3 adds `plugins` (the mini-chain) on `AuxSend`. INC 1 changes no field. |
| P6 | INC 3 branch | **REVISED 10 October 2026 — see D.2.A.b–A.d: the mini-chain is a side (wet) input of the tap node, its latency ages the TAP and never delays the sender's direct signal. The text that follows is the original decision, kept as the documented FALLBACK.** The send's mini-chain is a real graph branch: fan-out through a `ConnectedNode`, the mini-chain as `PluginNode`s, the tap at its end, the branch SUNK and summed with the dry (`SummingNode { dry, SinkNode (wet) }`). Its latency delays the sender's dry locally and is compensated by the ordinary PDC. |
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
- INC 3 (P6) — **SUPERSEDED by D.2.A.b–A.d (10 October 2026): the dry is NOT delayed; what follows
  is the fallback only.** The send plugin gains one `PluginList` (its mini-chain), declared through a small
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

## B.J Journal of INC 1 (recorded as it was done)

### 1.0 / 1.1 — recorded on `main` AS IS (9 October 2026, headless Debug instance WITH audio)

`tools/scenario_bridge_sends.py --ref` against `main` (`f3c805c4`, legacy `ObjAuxSendPlugin`). Fixtures: an
impulse at 0.2 (not 0.9: dry + wet at −6 dB clipped the export), a 1 kHz sine at −12 dBFS. Wet = E_on − E_off;
every case first asserts that two identical exports subtract to exactly zero (offline renders are
deterministic).

| Case | Measured on `main` |
|---|---|
| A1 siblings at the Main, A2 siblings in a stem, A3 siblings inside a group; send −6 dB | peak wet and peak dry at the same sample (48000); level −6.000 dB in all three |
| D, 20 ms `latencyTester` on the sender / on the aux / on a sibling, send −6 dB | wet @48000 = dry @48000, level −6.000 dB in all three (the legacy delay line is exact in scope) |
| **M1 (Q8), level AUTOMATED flat at −6 dB** | (wet − dry) − curve over 360 windows of 10 ms: **min −6.99 dB, mean −6.05 dB, max −5.52 dB**. The automated wet sits ~6 dB UNDER its own curve and wobbles by 1.5 dB from window to window. |
| **M2 (Q8), automated ramp −30 → 0 dB over 1 s** | min −8.26 dB, mean −6.29 dB, max −4.96 dB; no hole (no window < −90 dB) |
| O references | `O_A1/A2/A3/Dsender/Daux/Dsibling_main.wav`, bit-identical across two runs (0.00 LSB) |

Q8 is therefore CONFIRMED and larger than the plan assumed: the legacy path is not merely "a bit coarse
when automated", it delivers a wet about 6 dB too low and unsteady. The bridge send applies the level once
per block on the copy, which removes the cause (§A.2).

Step 1.0 answers (code read, nothing run):
- Invariant I1: `compensatesOwnPluginLatency()` is overridden nowhere (`ContainerClip.h:65` says so; only the
  `Clip` base returns false). Invariant I2: no `setTempoAdjustment` / `setSpeedCompensation` / Link call in
  `objekat/`.
- (a) `refreshContainerSpanForKey:` (`OBJEngineCore.mm:2404`): for a BOUNDED group the span IS the model
  window (`_groupBoundsMap`), so an aux child counts exactly as far as the model's window counts it; for an
  INFINITE group the envelope skips aux children (`isObjAuxBus`).
- (b) An infinite aux inside a group: its own bounds are clamped to `[start, start + kOpenWindowSecs]`
  (never 1e9) and it is skipped by the envelope, so it never inflates its group's span.
- (c) `linkTarget(for:)` resolves through `laneEntry(forID:)`, which is `nil` for an object with no lane
  entry: step 1.8 must therefore draw the wire to the visible ancestor group when the aux is hidden.

### INC 1 — what was done, step by step (9 October 2026, Debug, headless, WITH audio)

| Step | State | Commit |
|---|---|---|
| 1.0 preliminaries | done (answers above) | `ca012e27`, `b8ea4a45` |
| 1.1 scenario, written before the change | done: sections A to T (223 checks), `--ref` against `main` for the numbers above | `b8ea4a45`, `90d07759` |
| 1.2 pure rules `BridgeScope.swift` | done | `4d1eadd3` |
| 1.3 engine patch `0039` | done; patch equals fork commit `fb0ae39e631` | `f7573ca9` (app side), fork `objekat-sends-0039` |
| 1.4 app, engine side (`ObjBridgeSendPlugin`, `ensureBridgeSend`, `setSendGated`, `OBJ_SENDS_LEGACY`) | done | `f7573ca9` |
| 1.5 view-model: topology and sync | done | `03f308ef` |
| 1.6 audibility gate (group mute) | done, measured in section L | `03f308ef` |
| 1.7 load migration, dangling sends, format 21 | done | `03f308ef` |
| 1.8 UI, the minimum | done; wires to the visible group, greyed rows with the reason (Aux tool, signal view, multi-selection inspector), tier ordering. Seen on screen: NOT | `7332891a` |
| 1.9 API | done (`send.list`, `send.candidates`, `send.remove`, `debug.bridge_report`) | `03f308ef` |
| 1.10 documentation | done (`CLAUDE.md`, `architecture_decisions.md`, `command_api.md`, `plan_sidechain.md`, `engine-patches/3.5/README.md`) | this commit |

Numbers (all executed):
- pure tests: `test_bridge_scope_reference.py` 95 / 0; `test_bridge_scope.swift` 101 / 0; `test_bridge_core.cpp` 74 / 0.
- `scenario_bridge_sends.py` A to T: **223 OK, 0 FAILED**.
- Q8: M1 (flat −6 dB) min / mean / max of (wet − dry) − curve = 0.00 / 0.00 / 0.00 dB (was −6.99 / −6.05 / −5.52 on `main`);
  M2 (ramp −30 → 0 dB) min −1.41, mean −0.30, max +0.02 dB, best lag 45 ms, worst error 0.19 dB, no hole (was −8.26 / −6.29 / −4.96).
- null test `OBJ_SENDS_LEGACY=1` vs bridge, six in-scope cases (A1, A2, A3, D sender / aux / sibling): **0.00 LSB**.
- 200 send readers: one build pass; a stem change: one rebuild.
- non-regression, each against its own fresh instance: `scenario_sidechain.py` 55 / 0, `scenario_bridge_latency.py` 66 / 0,
  `scenario_families.py` 261 / 0, `scenario_selection_send_scope.py` 345 / 0, markers, plugin_state_undo (5), plugin_selection (58),
  export_preview 83 / 0, fxlink, tabs 106, cross_paste 31, relink: all pass; `tools/smoke.jsonl` 15 / 15 ok.
- the scenarios `consolidate`, `channel_mode`, `ara`, `spectral_editor` pinned session format 20: pins moved to 21 (`9b98ad67`).
- `xcstrings.py check`: 642 keys, 3 languages, nothing missing.

Deviations and open points: see the report to the architect; the two known ones are that the legacy null test is run from
the same Debug build with `OBJ_SENDS_LEGACY=1` (not from a `main` build), and that no mutant of C.3 was run by hand.

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

## D.1 INC 2 — a positionable send, the send card (branch `feature/sends-inc2-position`, format 22)

Detailed on 9 October 2026 from the code of `feature/sends-inc1-scope` (HEAD `68aa0799`), after the
user's answers Q-U5 / Q-U6 / Q-U7 (table at the top of this document). It replaces the one-page
sketch. Nothing below is implemented. The branch name of the sketch (`feature/sends-inc2-tap`) is
superseded by `feature/sends-inc2-position`.

### D.1.A Design

#### A.a Vocabulary: four positions, two of them stored on the send, one in the chain

The signal view is read top to bottom; the engine's list of an object is
`[channel mode? | instrument? | trimIn | FX… | trimOut | fader | window-fade | sends]`.

| Position (API name) | In the signal view | In the engine's list | Stored as |
|---|---|---|---|
| `input` | between the head (file / instrument / source) and the chain's IN gain | just before `trimIn` (after the channel mode and the instrument) | `AuxSend.tap = .input` |
| `chain`, index `i` | on the trunk, before the root entry `i` (`i == count` = after the last one, still before the OUT gain) | among the user plugins, between `trimIn` and `trimOut` | a MARKER entry in `plugins` (top level) |
| `pre_fader` | between the chain's OUT gain and the pan / volume / mute zone | just after `trimOut`, before the fader | `AuxSend.tap = .preFader` |
| `post_fader` (default) | a card UNDER the pan / volume zone (Q-U7) | at the end of the list, after the window-fade — today's place | `AuxSend.tap` absent |

"Before or after the chain gains" (U3) is therefore exact: `input` / `chain 0` are the two sides of
the IN gain, `chain count` / `pre_fader` the two sides of the OUT gain.

#### A.b Model

```swift
enum SendTapPoint: String, Codable { case postFader, preFader, input }

struct AuxSend {                 // unchanged identity: one per (object, auxID)
    var auxID: UUID
    var levelDb: Float
    var enabled: Bool
    var tap: SendTapPoint = .postFader     // encoded ONLY when != .postFader
}

struct SendMarker: Codable, Equatable { var auxID: UUID }

struct ObjectPlugin {            // third container kind, beside `rack` and `fxBlock`
    var sendMarker: SendMarker? = nil      // encoded only when present
    // isContainer == true, childSeries == [] for a marker
}
```

- **Effective position** (one pure function, `SoundObject.sendPosition(auxID:)`): a top-level marker
  naming the aux exists → `.chain(index)`; otherwise `send.tap`. A marker WINS over `tap`; moving a
  send out of the chain removes its marker and writes `tap`; moving it into the chain inserts the
  marker and resets `tap` to `.postFader` (so that losing the marker — a bake, a hand-edited file —
  falls back to the oldest, best-known behaviour).
- **`SoundObject.sanitisingSends()`** (pure, idempotent; run on load, after every paste / import, and
  asserted by the audit): a marker without a send entry is removed; two markers for one aux → the
  first is kept; a marker NESTED in a rack branch or a bin is HOISTED to the top level, just after
  its top-level ancestor (less destructive than dropping it; U3 forbids it inside); a marker on an
  aux object or on a stem / Main host is removed (aux and Main do not send).
- **The marker's `id`** is a fresh UUID like any entry's (the id-uniqueness audit walks it through
  `childSeries`, unchanged). It is NOT the engine key: the engine plugin stays keyed
  `sender|aux` in `_bridgeSendMap`, so a marker re-created with another id finds the same instance.

**Why a marker and not an anchor ("after plugin P") — verified on the code.** The array position
survives every reorder for free. It BREAKS the eligible runs of the automatic FX bins
(`isFXLinkEligible` is `!isContainer && no link`): a cut on `[A, tap, B]` gives the bins `{A}`,
`{B}` with the tap still between them, where an anchor on `A` would land INSIDE a bin, which U3
forbids. The price is an audit, and it is the main risk of the increment:

- ~200 occurrences of `rack` / `fxBlock` / `isContainer` / `childSeries` in 25 files.
- Sites that already go through `isContainer` / `childSeries` are safe as they are: `flattenLeaves`,
  `pluginLeaves`, `collectPluginRefs`, `capturingPluginStates`, `pluginDisplayNames`,
  `changedPluginStates`, the id-uniqueness walk, `isFXLinkEligible`, `fxLinkEligibleRuns`.
- Sites written `if rack … else if fxBlock … else LEAF` read a marker as a PLUGIN and must be taught
  it: `rackSpec`, `copiedPlugins` (`copySeries` / `copyLeaf`), `SynopticMapping.buildSeries`,
  `bridgeTopology.collectLeaves`, `settingSidechain`, `bridgeLeafExists`, `CrossProjectImport`
  (`cloneLeaf`), `deepFreshCopy` (`freshPlugins`), the clipboard's plugin copy
  (`EditViewModel+Clipboard.swift` ~209), `adoptingPluginStates`, the API's plugin payload and its
  counts (`Commands+Helpers` ~258, `Commands+Runtime` ~184), `removingPlugins`, `locate` /
  `inserting`, `transferPlugins` and the plugin selection, `PluginDrop`, the FX-link editing.
- 31 field-by-field `ObjectPlugin(id: …)` constructions would silently DROP the new field. Hence:
  `sendMarker` is an init parameter with a default; every construction site that COPIES an entry is
  listed in step 2.0 and either passes it or is proven never to see a marker.
- The failure mode that makes this dangerous: an unresolved leaf of the compile comes back in
  `failed` and `compileRack` REMOVES it from the model. A marker read as a plugin is not only
  ignored, it is erased. Counter-measure: `rackSpec` never emits a marker as a leaf (step 2.3), and
  `debug.send_marker_audit` (step 2.2) is asserted by the scenario after every phase.

#### A.c Session format 22 and compatibility

- `SessionSchema.formatVersion = 22`. Two optional keys: `tap` on a send, `sendMarker` on a chain
  entry. Absent = post-fader: a format-21 file decodes to exactly the INC 1 model and re-encodes
  without either key (byte-comparable objects when nothing was moved).
- A format-22 file opened by an older build: the marker entry decodes as a plugin with an empty
  identifier and is dropped by that build's compile. Accepted (no downgrade promise in this
  project), said in the notice.
- The session notice (the text an LLM reads before retouching the JSON) gains the two keys and the
  bijection rule; `sanitisingSends` on load repairs a retouched file (same spirit as the duplicate
  plugin-id repair).

#### A.d Engine: who lays the tap, who orders it — no engine patch

Facts (read in `tracktion_EditNodeBuilder.cpp` and `tracktion_ObjBridgeNodes.cpp`):
`createPluginNodeForList` turns ANY `BridgeTapSource` found in a plugin list into a `BridgeTapNode`
AT ITS INDEX and records the age (accumulated latency) of its input; the node passes its input
through untouched and writes a COPY to the ring. So a send plugin moved to another index of the
object's list is tapped there by the fork as it is. **Patch `0040` is NOT needed for INC 2** (it
stays reserved for INC 3's mini-chain).

One owner each (the sketch's open point, settled):

- **Existence, level, gate: the bridge sync** (`syncBridge` → `ensureBridgeSendFrom…` →
  `commitBridgeSync`), exactly as in INC 1.
- **Position: one engine function, `applySendPositionsForKey:`**, called from BOTH ends so that a
  recompile and a sync cannot fight:
  - `ensureBridgeSendFrom:toAux:levelDb:gated:` gains `position:` (`postFader` / `preFader` /
    `input` / `chain`) and, for `chain`, nothing else: the index comes from the recorded root order.
  - `rackSpec` emits, at the ROOT only, `{kind: "send", key: "<sender>|<aux>"}` for a marker.
    `parseCompileSeries` keeps it as an ordering token: never created, never destroyed, never put in
    `failed`, and part of the wanted keys so that the compile's clean-up ignores it. The compile
    stores the root order including the tokens (`chain.rootOrder`) and resolves a token through
    `_bridgeSendMap` when ordering; a token whose plugin does not exist yet is skipped.
  - `applySendPositionsForKey:` moves each send plugin of the object to: `input` → before `trimIn`
    when the chain is materialised, else before the fader (same signal: no plugin, no trim);
    `chain` → per `rootOrder`, else before the fader; `preFader` → before the fader (after
    `trimOut` by construction); `postFader` → the end of the list. It moves only when the order is
    wrong (`plugins:areInOrderIn:before:`), like `compileSeries`.
  - It is called at the end of `compileUserRackForObjectID` and from `commitBridgeSync` for every
    touched sender; a move that changed an index is ONE `restartPlayback`, inside the transaction
    that already has one.
- A position change from the model side = `scheduleChainCompile` (only when a marker is involved) +
  `scheduleBridgeSync`. Order of arrival is indifferent by construction; the scenario exercises both.
- The limit `maxPluginsOnClip = 45` (5 system + 40 user) is already shared with the send plugins
  since INC 1; INC 2 changes nothing to the count. Step 2.0 reads what `ensureBridgeSend` answers on
  a full list and makes it a `sendStatus` refusal with a reason rather than a silent absence.
- The fork still carries the legacy `ContainerAuxSend` node code. It is left DORMANT (no app plugin
  implements the interface any more), not removed: a deletion-only patch would spend `0040`. Step
  2.0 checks with `OBJ_GRAPH_CENSUS` that the dormant scan costs nothing; if it does, its removal
  rides with INC 3's `0040`.

#### A.e Fades and window on the sent copy (Q-U5) — the direct signal untouched

A tap taken before the fader is upstream of `ObjWindowFadePlugin`. Q-U5: the send follows the
object's fades and window anyway; volume and pan do not apply.

- `ObjWindowFadePlugin::applyToBuffer` is stateless per block (cached values, edit time from the
  render context, window counted in samples). Its body is extracted into
  `applyEnvelope (buffer, start, numSamples, editTime)`, public; `applyToBuffer` calls it.
- `ObjBridgeSendPlugin` gains `setEnvelopeSource (te::Plugin::Ptr windowFade)` (a ref-counted
  pointer, set on the message thread by `applySendPositionsForKey:` BEFORE the restart that makes
  the new position live: null for `postFader`, the object's own `_windowFadeMap[key]` otherwise).
  In `applyToBuffer` — which already receives the node's scratch COPY and an edit time moved back
  by the tap's age — it applies `envelope` THEN `level`. The direct signal is never written.
- Consequences that come for free: the fade preview and the head-cut rule follow (same plugin, same
  values); a fade edited while playing is heard on the send at once; a pre-fader send is cut outside
  a group's window exactly where the group is.
- A post-fader send is after the window-fade and keeps today's behaviour, bit for bit (no envelope
  source set).
- Both classes are app-side headers (`objekat/OBJWindowFadePlugin.h`, `objekat/OBJBridgeSendPlugin.h`):
  no fork change. To verify in step 2.4: `_windowFadeMap[key]` is written only in
  `installObjectChainTail`; a rebuilt tail must be followed by `applySendPositionsForKey:` (add the
  call there) or the send would hold the previous plugin — alive thanks to the `Ptr`, but stale.

#### A.f Latency

Nothing to build. The tap's age is the latency accumulated BEFORE it; `ObjAuxReturnNode` delays each
reader by `X − age_i`. A tap before a 20 ms plugin is simply 20 ms younger than a post-fader one and
is delayed that much more at the return; the wet stays sample-aligned with the dry at every
position. The level automation and the envelope are evaluated at the edit time of the tapped
material (the node already shifts it). Proven by section V of the scenario.

#### A.g Mute, solo, the INC 1 gate

Today mute and solo are −96 dB pushed on each object's OWN fader (`engineVolume`). A post-fader send
is silenced by it; a pre-fader send would keep sounding from a muted object. This is a real choice
(consoles differ) → **Q-U12**, with the provisional hypothesis **"a muted or solo-silenced object
sends nothing, wherever its tap is"**, consistent with Q-U1.

Under that hypothesis: `sendIsGated(sender:aux:)` (`EditViewModel+Audibility.swift`) becomes
"an ancestor group not holding the aux is silenced (INC 1) OR the sender itself is silenced and its
tap is not post-fader"; `pushMix` pushes the gates for any object owning a non-post-fader send, not
only for groups. Stem mute: a stem's mute already silences its objects through the same fader path —
same rule. The gate keeps its 50 ms smoother. Isolated in one step (2.5) so that the other answer to
Q-U12 is a two-line change.

#### A.h Copies, cut, paste, undo

- **Duplicate, copy / paste in the project, cut:** the marker is an entry of `plugins` and travels
  with the array ONCE the copy sites of A.b are taught it; `sends` travels as today. After a cut,
  both halves carry the send at the same position; the automatic bins are `{A}`, `{B}` around it.
- **Plugin-only transfers** (drag of a plugin or of a selection to another object, with or without
  ⌥ / ⌘): markers are NOT plugins — never selected, never in a payload; a run dragged away leaves
  the marker where it is.
- **Wrapping by hand** (parallel block or bin made from a selection that straddles a marker): the
  marker is not eligible; the bins split around it (`fxLinkEligibleRuns`), and a parallel block is
  created without it, the marker left just after the block (the hoisting rule of `sanitisingSends`).
- **Cross-project paste** (`CrossProjectImport.plan`, pure): a send whose aux is in the pasted lot is
  remapped (the marker's `auxID` with it), otherwise the send AND its marker are dropped — today's
  rule, extended to the marker and to `tap`.
- **Undo / redo:** one undo point per gesture (`pushUndo` before the first modification). A marker
  added, moved or removed changes the chain's shape, so `adoptingPluginStates` refuses and the
  object is REBUILT on undo — correct, but it reloads every AU of the object. Step 2.7 makes two
  chains that differ ONLY by their markers patchable (compile + bridge sync, instances kept),
  proven by the `[UNDO] 1 patched` trace.
- **Deleting the card = deleting the send:** `removeSend(from:to:)` removes the entry, its marker and
  the automation lane aimed at it, in one undo point (the INC 1 door, extended).

#### A.i Consolidate / bake (Q-U6) — INTERPRETATION TO CONFIRM

What the code does today: a consolidated placement is created with `plugins: []` and
`sends: live.sends`; the chain is baked into the wave, the sends survive on the placement. A marker
dies with the chain; an `input` tap loses its meaning (there is nothing left before the chain). A
`pre_fader` tap survives unchanged (the baked wave IS the pre-fader signal) and is NOT concerned.

The user's answer is "ask the user". Planned as the launcher understood it, **not confirmed**:
when the object to consolidate (or to bake) carries at least one send at `input` or `chain`, an
alert at the moment of the operation offers **Fold back to post-fader / Delete the send(s) /
Cancel**. One pure function, `SendBakePolicy.resolve(object, choice)`, does the folding or the
deletion on the model BEFORE the existing path runs; the existing path is otherwise untouched.

Headless and API (no alert is ever possible, `hasInterface`): `consolidate.make` and the bake
commands gain `mid_chain_sends: "refuse" | "fold" | "remove"`, default **`refuse`** — the command
fails with `mid_chain_sends` and the list of sends, nothing is changed. `refuse` is the safe
default because both other choices change what is heard without anyone having seen it.

Everything of this paragraph lives in step 2.8, isolated, so that another reading of "ask the user"
(a preference, a per-send choice, a third option "bake the wet too") replaces one step.

Out of this question, unchanged from INC 1: the sends of the CHILDREN of a baked group (rendered
inside when their aux is inside, lost with the children otherwise).

#### A.j Signal view (Q-U7): every send is a card

- `SynopticNode.Kind` gains `.send(auxID)`; `SynopticMapping.buildSeries` maps a top-level marker to
  it. `SynopticLayout.Diagram` loses `sendsZone` for outgoing sends and gains three fixed slots:
  `inputSends` (between the head / ARA card and the IN gain), `preFaderSends` (between the OUT gain
  and the pan / volume zone), `postFaderSends` (under the pan / volume zone, above the stems zone).
  Several cards in one slot stack vertically in the order of `sends`.
- The card: the aux's name and colour, level (same control and same doors as today's row:
  `setSendLevelFromHand`), on / off, a cross (= delete the send), a menu (Change target…, Fold to
  post-fader, Delete), its wire leaving the trunk sideways towards the aux. Greyed with the reason
  when the send is refused or the aux no longer overlaps the sender in time (`sendReasonText`).
- A send card is NOT in `selectedPluginIDs` (like the instrument): own highlight, own drag payload
  (`SendDragPayload { sender, aux }`), ignored by the marquee.
- **Consequence of Q-U7 to be seen by the user (Q-U13):** the zone used to list EVERY reachable aux
  as a row, existing send or not. Cards exist only for entries of `sends`; the reachable auxes
  without a send are reached through "Send to…".
- **Creating:** a "+ Send to…" button in the post-fader slot (creates post-fader), and the same
  entry in the "+" of a trunk insert point (creates at that point). Both open the same menu: the
  reachable auxes in the Q-U3 order (same group / rest of the stem / Main), the refused ones greyed
  with their reason, then "Choose an object on the timeline…". New send at −∞, on
  (`setSendEnabled(true)` is the existing door that creates `AuxSend(−∞, enabled: true)`).
- **Pick mode:** `SidechainPick` is generalised into
  `enum RoutePick { case sidechain(host:, plugin:), send(sender:, position:) }`; the timeline's
  readers (highlight, cursor, click, Esc, the banner) switch on it; the refusal text for a send
  comes from `sendCreationRefusal`. Only auxes are valid targets in send mode.
- **Drag and drop of a card** (no modifier: one send per pair, so no copy):

  | Drop on | Result | Banner |
  |---|---|---|
  | a trunk insert point (root series) | `chain`, that index | "Send taken here" |
  | the input slot / the pre-fader slot / the post-fader slot | that position | "Send taken at the input / before the fader / after the fader" |
  | a branch of a parallel block, an FX link bin | REFUSED | "A send cannot be taken inside a parallel block / an FX link" |
  | another object, a stem strip, the timeline | REFUSED | "A send stays on its object" |
  | an aux bus head, the Main | REFUSED (they do not send) | same |

  The banners are new contexts of the existing `PluginDropHint`.
- The aux bus head (`BusHeadZoneView`, the RECEIVED sends) is not touched: it lists senders and their
  level, which the position does not change. One addition, cheap: each received row shows the
  position's short name when it is not post-fader.
- The Aux tool (A) and the multi-selection inspector are unchanged: they set the level of the pair
  whatever the position, and a send they create is post-fader.

#### A.k API

- `send.list`: each send gains `position` (`post_fader` / `pre_fader` / `input` / `chain`), and for
  `chain`: `index`, `after_plugin`, `before_plugin` (ids or null), plus `follows_window` (bool).
- `send.set_position {id, aux, position, index? | after? | before?}` — undoable (`.bus`); refuses
  `chain` aimed inside a block / bin (`bad_params` with the reason), an unknown plugin id, an aux or
  Main sender.
- `send.create {id, aux, position?…}` — the hand's creation door (−∞, on), so that scenarios stop
  creating through `set_level`. `send.set_level` keeps creating post-fader.
- `send.retarget {id, aux, to}` — the card's "Change target…": renames `auxID` on the send, its
  marker, its automation lane and the touch order; refused when a send to `to` exists or `to` is
  refused by the scope.
- `consolidate.make` / bake: `mid_chain_sends` (A.i).
- DEBUG: `debug.send_marker_audit` (model bijection marker ↔ send, nesting, hosts; AND engine: for
  every live send, its index in the object's list against the position the model asks, and whether
  an envelope source is set); `debug.bridge_report` gains `list_index` and `age_samples` per send;
  `debug.add_test_plugin` gains the type `gainTester` (fixed gain, `gain_db`) — the identifiable
  plugin of the position proof.

#### A.l Settled here (technical, reversible) — not questions

Marker rather than anchor; marker wins over `tap`; nested marker hoisted, not dropped; sync creates
and compile orders through one function; no patch `0040`; envelope then level on the copy; `input`
of a MIDI object is after its instrument, `input` of a group is the sum of its children before the
group's FX; an unmaterialised chain puts every non-post-fader tap just before the fader; `refuse` as
the headless default of Q-U6; the fork's legacy node code left dormant; plugin transfers never carry
a marker; no copy modifier on a card drag.

### D.1.B Implementation plan

Branch `feature/sends-inc2-position`, created from `feature/sends-inc1-scope` (INC 1 is not merged:
merging INC 1 first, after the eye / ear gate C.5, is preferable; if not, INC 2 stacks on it). One
commit per step, build + the step's tests green before the next. Hand strings through `L("…")`, the
three languages in the same commit as the string.

**2.0 — Branch, legacy removal, inventory (no behaviour change).**
- Delete the legacy send path and its switch: `OBJAuxSendPlugin.h`; in `OBJEngineCore.mm/.h` the
  legacy AUX-send section (`addSend` / `removeSend` / `_auxSendMap`, `-isSend:routableToAux:`,
  `pruneOutOfScopeSends`, the legacy half of `forgetObjectBookkeeping`); in Swift every
  `Self.sendsLegacy` branch and `legacyCanRouteSend` (`EditViewModel+Aux.swift`,
  `EditViewModel.swift` `syncSends`, `+Bridge`, `+Groups`, `+Cut`, `+Clipboard`, `+Overlaps`,
  `+Relink`, `+MultiSelection*`, `Commands+Plugins.swift`); the two calls that survived OUTSIDE the
  switch and still reach the legacy engine door: `dropStaleSends` (`EditViewModel+UndoRedo.swift`
  ~240) and `consolidateWrappingClip` (`EditViewModel+Consolidate.swift` ~528, `engine.removeSend`
  + `syncSends`) — both become a `scheduleBridgeSync()`. The 18 files of the grep
  `sendsLegacy|OBJ_SENDS_LEGACY|legacyCanRouteSend|addSend|removeSend|_auxSendMap|ObjAuxSendPlugin`
  must answer only the model's `removeSend(from:to:)` afterwards.
- `tools/scenario_bridge_sends.py`: the null-test section against the legacy path is removed; its
  numbers stay in the journal B.J.
- Inventory, written into this document as a table (site, file:line, "safe through childSeries" /
  "to teach" / "never sees a marker, why"): every hand-rolled chain walk and every `ObjectPlugin(`
  construction (A.b). What `ensureBridgeSend` answers on a full plugin list. Whether a MIDI
  object's instrument is in `plugins` (it decides what `chain 0` means there).
  `OBJ_GRAPH_CENSUS` before / after the removal.
- Gate: build, 0 new warning; `tools/scenario_bridge_sends.py` and the C.4 list green.

**2.1 — Model (pure).** `SoundObject/SoundObject.swift`: `SendTapPoint`, `AuxSend.tap`, `SendMarker`,
`ObjectPlugin.sendMarker` (init parameter, default nil; `isContainer`, `childSeries` in
`FXLink.swift`), `sendPosition(auxID:)`, `settingSendPosition(auxID:, _:)`, `sanitisingSends()`.
`SessionSchema.swift`: format 22 + notice. Load path: `sanitisingSends` next to
`purgingDanglingSends` (`EditViewModel+SendPurge.swift`). New `tools/test_send_position.swift`
(C.1). No engine or UI effect yet: a marker in a file is carried and ignored.

**2.2 — The audit, before the walks are touched.** `debug.send_marker_audit` (model half) in
`CommandAPI/Commands+Aux.swift`; then teach the "to teach" sites of the 2.0 table, one commit per
family: (a) compile-facing (`rackSpec` — the marker is emitted as nothing for now —,
`compileRack`'s `failed` handling, `removingPlugins`, `locate` / `inserting`); (b) bridge-facing
(`bridgeTopology.collectLeaves`, `settingSidechain`, `bridgeLeafExists`); (c) copies
(`copiedPlugins`, clipboard, `deepFreshCopy`, `restoredSubtree`, `CrossProjectImport`,
`copiedRun` / FX-link editing, `transferPlugins`, `PluginDrop`); (d) API payloads and counts.
A pure test per transformation: "a chain `[A, marker, B]` through X still holds the marker between
A and B (or X is documented to drop it with its send)".

**2.3 — Engine: position.** `OBJEngineCore.mm/.h`: the `send` token in `parseCompileSeries` /
`collectCompileKeys`, `chain.rootOrder`, `applySendPositionsForKey:`, the `position:` argument of
`ensureBridgeSendFrom…`, the calls from `compileUserRackForObjectID`, `commitBridgeSync` and
`installObjectChainTail`. Swift: `rackSpec` emits the token; `syncBridge` passes the position;
`setSendPosition(from:to:_:)` (machine door) and `setSendPositionFromHand` (pushUndo, refusals) in
`EditViewModel+Aux.swift`; `needsChainCompile` unchanged (a marker alone does not materialise the
chain: A.d's fallback). API: `send.set_position`, `send.create`, `position` in `send.list`; the
engine half of `debug.send_marker_audit`; `list_index` / `age_samples` in `debug.bridge_report`;
`gainTester` in `debug.add_test_plugin`. Scenario sections Q, R, V.

**2.4 — Engine: fades and window on the copy (Q-U5).** `OBJWindowFadePlugin.h` (`applyEnvelope`
extracted, `applyToBuffer` calls it — the direct path must stay bit-identical: section T),
`OBJBridgeSendPlugin.h` (`setEnvelopeSource`, envelope then level), set from
`applySendPositionsForKey:`. Scenario section S.

**2.5 — Gate (Q-U12, hypothesis).** `EditViewModel+Audibility.swift`: `sendIsGated`, `pushMix`.
Scenario section U. Isolated.

**2.6 — Copies end to end.** Duplicate, cut, copy / paste, cross-project paste, group / ungroup of
an object carrying sends at the four positions: the scenario's section W drives the real commands
and asserts the audit after each. Fix what 2.2's pure tests did not catch.

**2.7 — Undo.** `EditViewModel+UndoRedo.swift`: `isPatchable` / `adoptingPluginStates` accept chains
differing only by markers; `pushPatch` then calls `scheduleChainCompile` + `scheduleBridgeSync`.
Section X (one undo per move, `[UNDO] 1 patched`, the AU instance pointer unchanged in
`debug.plugin_id_audit` or the plugin report).

**2.8 — Consolidate / bake (Q-U6) — INTERPRETATION TO CONFIRM, isolated.**
`SendBakePolicy` (pure, `Shared/`), the alert (hand path only, `hasInterface`), the
`mid_chain_sends` parameter (`Commands+Consolidate.swift`, bake commands), hooked at the entry of
`consolidate(groupID:)`, `consolidateWrappingClip`, `consolidateEachInSelection`,
`consolidateSelectionAsLinkedInstances` and the bake entry. Section Y.

**2.9 — Signal view: cards.** `Inspector/Synoptic/SynopticGraph.swift` (`.send`),
`SynopticModelMapping.swift`, `SynopticLayout.swift` (three slots, card size, wires),
`SynopticView.swift` (the card view from `SynopticSendRow`'s controls; `SendsZoneView` removed for
outgoing sends; `BusHeadZoneView` kept, position label added). `tools/test_synoptic_send_cards.swift`
(layout: a card per send, slot per position, no card in a branch).

**2.10 — Signal view: drag and drop, deletion.** `SendDragPayload`, the drop sites
(`SynopticDropTarget`, `dropSite`), the refusals and the `PluginDropHint` contexts, the cross and
the card menu. i18n.

**2.11 — "Send to…" and the pick mode.** The menu builder (pure: `sendCandidates` + `offerTier` →
ordered entries with reasons; tested); `RoutePick` replacing `SidechainPick`
(`EditViewModel+SidechainStrip.swift`, `EditViewModel.swift:341`, `TimelineView.swift`,
`TimelineKeyHandler.swift`, `TimelineView+TapHandler.swift`, `TimelineView+DragHandler.swift`,
`SidechainStripView.swift`); `send.retarget`. The sidechain's own scenario must stay green
(non-regression of the generalisation).

**2.12 — Documentation.** `CLAUDE.md` (INC 2 entry, the marker rule among the permanent points),
`docs/command_api.md`, `docs/architecture_decisions.md` (marker vs anchor; one owner for position;
envelope on the copy), this document's journal, the session notice, `engine-patches/3.5/README.md`
(no new patch; the dormant legacy node code).

i18n keys (fr / en / es, `tools/i18n/xcstrings.py check` and `orphans` at each UI step): card menu
(3), "+ Send to…", "Choose an object on the timeline…", the four position names, five drop banners,
the pick-mode banner, the Q-U6 alert (title, text, three buttons), the refusal "chain full".

### D.1.C Test plan

Rules of INC 1 kept: each scenario against its OWN fresh instance, `--no-recent`, audio ON for the
bridge scenarios, exports re-read in 24 bits, the wet measured by difference (`E_on − E_off`), two
identical exports must subtract to exactly zero before any measure is trusted.

**C.a Pure (no app, any machine).**
- `tools/test_send_position.swift`: decode a format-21 object → all post-fader, re-encode without
  the new keys; round trip of the four positions; marker wins over `tap`; `settingSendPosition`
  between all 4×4 pairs keeps the bijection; `sanitisingSends`: orphan marker, duplicate, nested in a
  rack branch, nested in a bin, on an aux — and idempotence; indices after a plugin is inserted,
  removed, reordered around a marker.
- "Marker survives" per transformation (2.2): `copiedPlugins` (fresh ids, marker kept),
  `copiedRun` / `fxLinkEligibleRuns` on `[A, m, B]` → two runs, `adoptingPluginStates`,
  `capturingPluginStates`, `deepFreshCopy` (aux remapped in the marker too), `removingPlugins(A)`
  leaves `[m, B]`.
- `tools/test_cross_project_import.swift` extended: marker remapped with its send; dropped with it.
- `tools/test_bridge_scope.swift`: unchanged, must stay green (the scope does not depend on position).
- `tools/test_synoptic_send_cards.swift` (2.9), the menu builder test (2.11), `SendBakePolicy` (2.8).
- `tools/test_bridge_core.cpp`: unchanged, green.

**C.b `tools/scenario_bridge_sends.py`, new sections** (X = a clip of noise bursts with a click, A =
an aux without FX unless said; `G(−12)` = `gainTester` at −12 dB; `L(20)` = `latencyTester` 20 ms).
After EVERY section: `debug.send_marker_audit` answers no violation.

| § | Set-up | Assertion |
|---|---|---|
| Q | X with `[G(−12)]`, send at 0 dB, moved through `input`, `chain 0`, `chain 1`, `pre_fader`, `post_fader`; then IN gain −6, OUT gain −3, fader −20 | wet level = the sum of the gains UPSTREAM of the tap, each within 0.05 dB: `input` 0; `chain 0` −6; `chain 1` −18; `pre_fader` −21; `post_fader` −41. The audit's engine `list_index` matches. |
| R | `[G(−12), G(−7)]`, tap between them; then reorder the two plugins by the API; then delete the first | −12, then −7 (the marker kept its array place), then 0 after deletion — the position follows the ARRAY, as designed |
| S | X with a 0.5 s fade-in and a 0.5 s fade-out, fader −20 dB, send `pre_fader` 0 dB; same in `chain`, `input` | the wet's envelope equals the fade curve (10 ms RMS windows against `curve_db`, 0.5 dB); the wet is 20 dB ABOVE the dry (pre-fader proven); a group cropped by its window: wet exactly 0 outside the window; pan hard left on X: the wet stays centred |
| T | the same project exported (1) without any send, (2) with a mid-chain send at −∞, (3) with a mid-chain send at 0 dB into a MUTED aux, (4) after step 2.4 with a post-fader send only | (1) − (2) == 0 and (1) − (3) == 0 EXACTLY (the direct signal is bit-identical); (4) equals the INC 1 reference export kept from before the `applyEnvelope` extraction |
| V | `[L(20), G(−12), L(10)]`, tap at each of the four trunk points and the three fixed ones | `peak_index(wet) == peak_index(dry)` at every position; `age_samples` of the tap = 0 / 20 ms / 20 ms / 30 ms in the report; the level proves the place as in Q |
| U | X muted, then X silenced by another object's solo, then X's stem muted — send `pre_fader` and `chain` | wet == 0 (hypothesis Q-U12); un-mute: wet back, same level; `gate_edges` shows the 50 ms ramp, no click |
| W | duplicate X; cut X in two; copy / paste; group then ungroup; cross-project paste with the aux in the lot, then without | each resulting object: same `position` in `send.list`, same wet level as §Q for its position; without the aux: no send, no marker; after the cut the bins are `{G}`,`{G}` and the tap still measures −12 |
| X | one move = one undo; undo / redo through the five positions; undo of a card deletion | `send.list` and the measured level come back at each step; trace `[UNDO] 1 patched` (2.7), plugin instances unchanged |
| Y | `consolidate.make` on X with a `chain` send: default; `fold`; `remove`; and with a `pre_fader` send | default → error `mid_chain_sends`, model unchanged (hash); `fold` → placement's send is `post_fader`; `remove` → no send; `pre_fader` → accepted without the parameter, wet unchanged within 0.05 dB |
| Z | save, close, reopen (the five positions, a retargeted send, an automated level on a mid-chain send) | `send.list` identical, exports identical to before the save (difference == 0) |
| P′ | a format-21 project saved by the INC 1 build (fixture committed with its reference export) | opens without notice, every send `post_fader`, export − reference == 0; re-saved: format 22, objects without `tap` / `sendMarker` keys |

Kept from INC 1 and re-run with the tap at `chain` and at `pre_fader` (a loop over the position
parameter, not new code): A (level and alignment), M (automated level aligned with the material),
B / C (group mute gate), N (loop), the pass counters.

**C.c Non-regression — exact commands** (each on its own fresh instance; the launch line is the one
of section C.4, unchanged):

```
swiftc -O tools/test_send_position.swift … && ./test_send_position
swiftc -O tools/test_bridge_scope.swift … && ./test_bridge_scope
python3 tools/test_bridge_scope_reference.py
swiftc -O tools/test_cross_project_import.swift … && ./test_cross_project_import
swiftc -O tools/test_synoptic_fxblock.swift … ; tools/test_synoptic_marquee.swift ; tools/test_send_columns.swift ; tools/test_synoptic_send_cards.swift
clang++ -std=c++20 tools/test_bridge_core.cpp -o test_bridge_core && ./test_bridge_core
python3 tools/scenario_bridge_sends.py            # all sections, audio ON
python3 tools/scenario_selection_send_scope.py
python3 tools/scenario_cross_paste.py ; python3 tools/scenario_tabs.py ; python3 tools/scenario_navigation.py
the sidechain scenarios and the FX-link scenarios of section C.4 (the walks and the pick mode were touched)
python3 tools/i18n/xcstrings.py check ; python3 tools/i18n/xcstrings.py orphans
xcodebuild … Debug build: 0 new warning against the baseline
```

(The `…` source lists are those already written in C.1 / C.4 for each test; they are copied there
when the files exist.) A MUTANT run is added, which INC 1 did not have: `applySendPositionsForKey:`
compiled as a no-op must turn §Q, §R, §V red; `setEnvelopeSource` never called must turn §S red.

**C.d What only a person validates.** The card's look, its wire, the three slots, the stacking of
several cards; the drag (lift, insert-point highlight, banners, refusals) — SwiftUI gestures are not
reachable by the scenario; the "Send to…" menu and the pick mode on the timeline (cursor, highlight,
Esc); the Q-U6 alert; a reverb fed pre-fader from a clip with a long fade-out, heard; moving a card
while playing (one restart: a click or not?); the mute of an object sending pre-fader (Q-U12 by ear);
an old project opened and looking the same apart from rows that became cards.

### D.1.D Open questions for INC 2 (the user's) — see section E for the table

Q-U6 (confirm the interpretation and the headless default), Q-U12 (mute / solo of a pre-fader
sender), Q-U13 (cards only for existing sends), Q-U14 (where "+ Send to…" lives), Q-U15 (a send
whose aux no longer overlaps: card kept, greyed?), Q-U16 ("Change target…" on the card, in INC 2 or
not).

### D.1.E Risks, frankly

1. **Silent loss of a marker** (a walk or a field-by-field copy missed): high probability of at
   least one miss, contained by the 2.0 table, the pure "marker survives" tests and the audit after
   every scenario phase. The failure is visible (the send falls back to post-fader), never a crash.
2. **Two code paths ordering one plugin**: closed by the single `applySendPositionsForKey:`, but the
   order-of-arrival cases (sync before compile, compile before sync, tail rebuilt) must each be in
   the scenario; medium.
3. **The envelope source going stale** after a tail rebuild: low once the call is in
   `installObjectChainTail`; section S after a forced tail rebuild covers it.
4. **Undo rebuilding AUs** if 2.7 slips: functional but slow on heavy objects (hundreds of ms per AU).
5. **The signal view** (2.9–2.11) is the largest part by volume and the only one no scenario can
   see: the layout is tested pure, the gestures are not. The memory of this project holds several
   SwiftUI drag pitfalls; expect iterations with the user at the screen.
6. **INC 1 has not been seen or heard yet.** INC 2 stacks on an increment whose eye / ear gate (C.5)
   is open; a finding there lands under INC 2.
7. Q-U6 and Q-U12 are built on hypotheses; both are isolated in one step each.

### D.1.F Journal of INC 2 (recorded as it was done, 9 October 2026, Debug, headless, WITH audio)

#### 2.0 — legacy removal, the real inventory, the measures

Commits: `a2ec19b1` (the pre-bridge send path deleted), then the "chain full" refusal below. After the
removal `tools/scenario_bridge_sends.py` = 223 OK, 0 FAILED; sidechain 55, bridge_latency 66,
families 261, fxlink ALL PASS, consolidate ALL PASS, plugin_selection 58, cross_paste 31.

**Measures that corrected the plan**

| Question of 2.0 | Answer, measured |
|---|---|
| What does `ensureBridgeSend` answer on a full list? | The list cap is **20 entries**, not 45 (`maxPluginsOnTrack = 20` is the one that bites: an object's chain lives on a TRACK in this architecture). Fixed entries: trimIn, trimOut, fader, window-fade = 4, so **16 user plugins without a send, 15 with one** (probe: the 16th `objKeyProbe` is refused with a send, the 17th without). With 16 plugins in place and a send created afterwards, `insertPlugin` returned null: the engine logged `insertion refusée` and the model kept saying `status: active, routed: true` while no reader existed (silent absence). Fixed in 2.0: the engine answers `-1`, the sync writes `BridgeScope.Refusal.chainFull` into `sendRouteStatus` (merged with the plan's refusals, ONE write per sync), `send.list` says `status: refused, refusal: chainFull`; key `send.reason.chainFull` (fr/en/es). Scenario F2: send refused at 16 plugins, laid as soon as a slot is freed, level -6.000 dB, aligned to the sample. NOTE for 2.3: the three send positions that add no plugin keep costing one slot; a marker costs none (it is not an engine entry). |
| Is a MIDI object's instrument in `plugins`? | No: `SoundObject.instruments` is a separate array (copied by `copiedInstruments`, cloned by `CrossProjectImport` apart from `cloneSeries`). `chain 0` therefore means "before the first user plugin, after the instrument", and `input` is "after the instrument, before trimIn". |
| `OBJ_GRAPH_CENSUS` before / after | NOT measured: it is a compile-time macro of the fork (`OBJ_GRAPH_PROFILE`), a Debug engine rebuild with the flag is needed. The removal touched app-side code only and no node of the fork's graph: the dormant `ContainerAuxSend` scan in the fork is a type test that no app plugin satisfies any more. To measure only if INC 3's `0040` is built anyway. |

**Inventory of the sites that walk a chain or build an `ObjectPlugin`** (marker = `ObjectPlugin` with
`sendMarker != nil`, `isContainer == true`, `childSeries == []`, no `rack`, no `fxBlock`)

*Safe through `isContainer` / `childSeries` / `mappingChildSeries` (the marker has no child series: seen, left as it is)*

| Site | File:line |
|---|---|
| `collectPluginRefs` | `EditViewModel+Plugins.swift:59` |
| `pluginDisplayNames` | `EditViewModel+Plugins.swift:286` |
| `removingPlugins` (a marker id is never in `ids`) | `EditViewModel+Plugins.swift:298` |
| `flattenLeaves`, `settingEnabled`, `settingLinkGroup`, `settingDetachedLinkGroup`, `settingStateXML`, `branchingEmpty`, `settingVoiceGain/Mute`, `removingVoice`, unwrap helpers | `SynopticModelMapping.swift:109, 310, 326, 346, 357, 369, 397, 429, 441, 454, 463, 472` |
| `updatingBlock` / `replacingBlock` / `fxBlocks(in:)` / `enclosingFXBlock` / `rewriting` | `EditViewModel+FXLinkEdit.swift:33,48`, `EditViewModel+FXLink.swift:27,68,170` |
| `isFXLinkEligible` (`!isContainer`: the marker is NOT eligible, the bins split around it) | `EditViewModel+FXLinkEdit.swift:56` |
| `fxAddPluginCopies`, `fxAddPlugin` (refuse a container) | `EditViewModel+FXLinkEdit.swift:629, 654` |
| FX-link divergence walks | `FXLinkDivergence.swift:96, 202` (`p.rack != nil`: a marker is a leaf-less no-op) |
| Id-uniqueness walk | `PluginIDUniqueness.swift:52` (`childSeries`), `:141-154` (hand `rack`/`fxBlock` for the path text: a marker falls to the LEAF case and is reported by its own id, which is right: the marker has a fresh id) |
| `containsPlugin`, `pluginLeaves` | `SoundObject.swift:957, 1165` |
| Automation search, project walk | `EditViewModel+Automation.swift:108`, `EditViewModel+Project.swift:633` |
| Undo walk `walk(a, b)` | `EditViewModel+UndoRedo.swift:390` |
| Clipboard `remappingSidechain` (a `var q = p` copy: every field, the marker included, is kept) | `EditViewModel+Clipboard.swift:205-217` |

*TO TEACH (hand-rolled `if rack … else if fxBlock … else LEAF`: the marker would be read as a PLUGIN)*

| Site | File:line | What happens untaught | Family (2.2) |
|---|---|---|---|
| `rackSpec` | `EditViewModel+Plugins.swift:196-228` | emitted as a `plugin` with an empty identifier: unresolved, comes back in `failed`, `compileRack` REMOVES it from the model | a |
| `compileRack` `failed` handling, `locate` / `inserting` / `simplifyTree` | `EditViewModel+Plugins.swift:~230`, `SynopticModelMapping.swift:250-260` (`inserting`), `buildSeries` `:50, :64` | a marker would be drawn / indexed as a card or leaf; an insert index would count it | a |
| `bridgeTopology.collectLeaves` | `EditViewModel+Bridge.swift:66-70` | listed as a leaf (harmless today, wrong once keys are counted) | b |
| `bridgeLeafExists.has` | `EditViewModel+Bridge.swift:245-250` | a marker id would answer "is a plugin" | b |
| `settingSidechain` | `EditViewModel+Bridge.swift:261-277` | the `p.id == pluginID` leaf branch would accept a marker's id | b |
| `copiedPlugins` (`copySeries` / `copyLeaf`) | `EditViewModel+Plugins.swift:755-805` | a copy of the object holds an EMPTY-identifier plugin instead of the marker | c |
| `CrossProjectImport` `cloneSeries` / `cloneLeaf` | `CrossProjectImport.swift:213-229, 140-157` | same, in another project; also `auxID` must be remapped | c |
| `deepFreshCopy` `freshPlugins` (bake / restore) | `EditViewModel+Bake.swift:126-142` | same | c |
| `PluginDrop` payload checks | `EditViewModel+PluginDrop.swift:203-258` | `findBlock` only: a marker is never a payload (not selectable) — to confirm by the test, not to patch | c |
| API: plugin payload + counts | `Commands+Helpers.swift:258-267`, `Commands+Runtime.swift:184` | listed as a plugin / counted in `pluginCount` | d |
| `adoptingPluginStates` (patchability) | `EditViewModel+UndoRedo.swift:340-370` | a chain whose markers differ is "not patchable" → object rebuilt (correct, expensive: step 2.7) | 2.7 |

*NEVER sees a marker (and why)*

| Site | File:line | Why |
|---|---|---|
| Fresh plugin from an `AvailablePlugin` | `EditViewModel+Plugins.swift:308, 363`, `SynopticModelMapping.swift:114`, `EditViewModel+ARA.swift:65`, `Commands+FXLink.swift:230` | built from a catalogue entry |
| `copiedInstruments`, `CrossProjectImport` instruments, `placed` (instrument drag) | `EditViewModel+Plugins.swift:445, 722`, `CrossProjectImport.swift:167, 273` | the instrument slot is not `plugins` and never holds a container |
| Plugin-only transfers `.move / .copy / .link`, `independentCopy` | `EditViewModel+PluginSelection.swift:290-304, 366` | built from the SELECTED leaves; a marker is not a leaf (`flattenLeaves` yields none) so is never selectable |
| `copiedRun`, FX-link `instanceSeries`, `fxMake…`, wrap into a bin | `EditViewModel+FXLinkAuto.swift:61,76`, `FXLink.swift:125,137`, `EditViewModel+FXLinkEdit.swift:226,494,546,634,656` | fed by eligible runs (`isFXLinkEligible` excludes the marker) or by selected leaves |
| `synopticCopyPlugin`, `rackCarrier` | `SynopticModelMapping.swift:222, 293` | a copy of a SELECTED leaf; the carrier is a new container |
| `Bake` bin definitions | `EditViewModel+Bake.swift:97` | definitions of a bin hold plugins only |

Totals: 33 lines construct an `ObjectPlugin(` in the app (tools tests excluded). Field-by-field COPIES of an existing entry that can meet a marker: `copiedPlugins` (`copyLeaf`, the rack branch), `CrossProjectImport` (`cloneLeaf`, the rack branch), `Bake.freshPlugins` — these are the constructions to teach; every other one is built from a catalogue entry, from a selected leaf, from an instrument, or is a container. The pure test per family in 2.2 proves each row.

#### 2.1 to 2.12 — what was done, commit by commit (all local, nothing pushed, no engine patch)

| Step | Commit | What it is | Proof actually run |
|---|---|---|---|
| 2.0 | `a2ec19b1`, `a379786e` | legacy deleted; inventory; `chainFull` refusal | above |
| 2.1 | `51695ae3` | model: `SendTapPoint`, `AuxSend.tap`, `SendMarker`, `sendPosition` / `settingSendPosition` / `sanitisingSends`, format 22 | `test_send_position.swift` 55 at the commit (83 at the end of INC 2) |
| 2.2 | `ef6bce72` | the chain walks taught the marker, family by family; `debug.send_marker_audit` (model half) | `test_send_position` 70, `test_cross_project_import` 51 |
| 2.3 | `2345708b` | the engine places each send (`applySendPositionsForKey:`), `send.create` / `send.set_position`, sections Q2 R2 V2 K2 | measured in the table below |
| 2.4 | `71cc3c35` | pre-fader / in-chain / input sends follow the window and fades (envelope on the copy) | sections S2 and T2 (+ T2REF on the INC 1 app) |
| 2.5 | `55659120` | a silenced sender feeds no aux wherever its send taps (Q-U12) | section U2 |
| 2.6 | `09d9f6a6` | duplicate, cut, paste, group, cross-project keep position, marker and wet | section W2, 212 checks, 0 failed (no code fix needed) |
| 2.7 | `6dc4e6f9` | undo / redo of a position is PATCHED in place | section X2: five moves, five undos, five redos, each "0 rebuilt, 1 patched" |
| 2.8 | `67f26c24` | consolidating asks about mid-chain sends (Q-U6): `SendBakePolicy`, alert, `mid_chain_sends` | section Y2, `test_send_bake_policy.swift` |
| 2.9 | `fd536202` (+`ff2fdbc5`) | signal view: every outgoing send is a card in a side column | `test_synoptic_send_cards.swift` 71, `test_synoptic_fxblock.swift` 246 (unchanged) |
| 2.10 | `bbbbb9e4` | drag a card to move it (insertion points and the three fixed slots; refusals with their line) | `test_send_drop.swift` 21 |
| 2.11 | `83a26886` | "Send to..." (pure builder + NSMenu), "+" button, `RoutePick`, "Change target...", `send.retarget` | `test_send_target_menu.swift` 14; section RT2 42 / 0; `scenario_sidechain` 55 / 0 |
| 2.12 | this commit | docs | `xcstrings.py check` 685 keys, nothing missing; orphans none |

**Measured values that differ from the plan's expectations**

- R2 (the marker keeps its array place, the wet of a position stacked on measuring gains): the wet reads -19, -12 and 0 dB
  at the three tested places, not the plan's round figures; each equals the sum of the gains UPSTREAM of the tap, which is
  the property the section asserts (the plan's figures were illustrative). A constant -0.733 dB pipeline offset is present
  in every reading of the bridge (same on INC 1).
- T2REF: a post-fader send's export equals the INC 1 build's bit for bit (the reference was rendered with `--only T2REF` on
  the INC 1 app, the INC 2 build compared to it): the default position changed nothing.
- RT2: wet -18.000 dB at the old and at the new aux after a retarget; the "Send to..." menu tiers are [0, 2] on the fixture
  (same group, the Main).

**Deviations from the plan and why**

1. **Cards in a side column, not stacked on the trunk axis.** The plan said "a card per send on the axis"; with four
   anchors and N cards the axis has no room, and a send is a branch, not a step. The column is to the right of the
   trunk at `columnX = margin + contentW + sendColumnGap`, packed top to bottom without overlap, wired to the anchor.
2. **No `.send` node kind in `SynopticNode`.** Sends are passed to `SynopticLayout.diagram` beside the nodes
   (`SynopticSend`, `SynopticSendSlot`), because a send is not a node of the series tree: it is a branch hung on it.
3. **The trunk "+" entry is a right-click context menu**, "Send to... (taken here)", only for the root series. A left-click
   "+" already opens the plugin picker; overloading it was worse. The user's Q-U14 hypothesis said "an entry in the + of
   each trunk insertion point": the entry is there, through the secondary click.
4. **The "Send to..." menu is an imperative `NSMenu` built at the click** (`SendTargetMenuPresenter`), because a SwiftUI
   `Menu` evaluates its content eagerly and the candidate list is not free on a big project. The builder
   (`SendTargetMenu`) is pure and tested.
5. **The slot drop bands overlap the card column**, cards on top. Needs the eye.
6. **Slot drops inside an FX group** are disabled on a closed consolidated object (its chain is a wave).
7. **Two debug doors added**: `debug.route_pick`, `debug.send_target_menu` (the pick and the menu could not be driven
   headless otherwise). `send.create` / `send.set_position` exist from 2.3.
8. **Fold costs an extra undo point**: on the clip path a consolidate with "fold" takes three undos to come back
   (the fold point, then the bake's own two). Accepted: the fold is a deliberate, separate edit.
9. **`rackSpec` marker token** is `{kind: "send", aux}` (the plan said "nothing for now" in 2.2; 2.3 gave the compile an
   ordering token so the engine knows the root order).
10. **Cap**: the engine list holds 20 entries; every send costs one slot whatever its position, and a marker costs none (it is not an engine entry).

**Findings to decide (not fixed on purpose)**

- **Pre-fader and the consolidate fader.** The plan says a pre-fader send's wet is unchanged by a consolidate. Measured:
  it is only true when the clip's fader is at 0 dB. With the fader at -20 dB the wet goes -21 -> -41 dB, (cause not
  investigated further; the likely reading is that the bake renders the clip's fader into the wave, so a "pre-fader" send of
  the instance taps a signal that is already faded). Needs a decision (fold the fader out of the bake? warn?). Not changed.
- `tab.new` empties the clipboard (observed in W2); a paste after a new tab finds nothing. Pre-existing.
- `pruneOrphanSends` does not trigger a chain recompile when the marker of a deleted send disappears: harmless
  (the next sync fixes it), noted.

**Not verified** (and why): the 50 ms gate-ramp "no click" claim of U2 (a ramp, not heard); every signal-view drag, drop,
menu, cursor, band and veil (a headless instance has no window); the card's look in three languages; `OBJ_GRAPH_CENSUS`.

#### The final gate of INC 2 (10 October 2026, Debug, headless, WITH audio on the built-in output, one fresh instance per scenario)

| Run | Result |
|---|---|
| Debug build, clean (`-derivedDataPath` empty) | BUILD SUCCEEDED, 1541 `warning:` lines; 230 distinct file:line, 3 of them on a line the INC 2 diff touched: `consolidate(groupID groupID:` (the same warning at the same signature, base line 484, the line only gained a parameter) and `decode(PluginDragPayload.self` (base line 1516, moved by the 2.10 refactor): **0 new warning**, the two are the pre-existing ones |
| `scenario_bridge_sends.py`, all sections | **881 OK, 0 FAILED** (INC 1's A to T = 223; INC 2's F2 8, Q2 54, R2 20, V2 42, K2 17, S2 25, T2 18, U2 68, W2 212, X2 67, Y2 32, RT2 42, Z2 35, PF 18). X2's 10 undo / redo trace checks read the app log, so they run only with `APP_LOG` set: the first full run (with it) had them pass. |
| `test_send_position` | 83/83 |
| `test_send_bake_policy` | 24/24 |
| `test_synoptic_send_cards` | 71/71 |
| `test_send_drop` | 21/21 |
| `test_send_target_menu` | 14/14 |
| `test_synoptic_fxblock` | ALL PASS (246) |
| `test_synoptic_marquee` / `test_send_columns` | 28 / 110 |
| `test_cross_project_import` | 51/51 |
| `test_plugin_id_uniqueness` | 67/67 (its header's compile line is stale: it needs the same 22 files as `test_cross_project_import`) |
| `test_bridge_scope.swift` / `test_bridge_core.cpp` / `test_bridge_scope_reference.py` | 101 / 74 / 95 checks, all pass |
| `scenario_sidechain` / `scenario_bridge_latency` | 55 / 66, 0 failed (the latency one with the live graph at 96 kHz) |
| `scenario_families` | 261 OK |
| `scenario_fxlink` | 132 assertions, ALL PASS |
| `scenario_consolidate` | ALL PASS (139 `ok` lines) |
| `scenario_plugin_selection` | 58 |
| `scenario_cross_paste` | 31 |
| `scenario_selection_send_scope` | 345 assertions, ALL PASS |
| `scenario_tabs` | 106 |
| `scenario_markers`, `scenario_relink`, `scenario_plugin_state_undo` (5), `scenario_export_preview` (83), `scenario_channel_mode` (50), `smoke.jsonl` (15 of 15 ok) | all pass |
| `xcstrings.py check` / `orphans` | 685 keys, 3 languages, nothing missing / none |
| `scenario_navigation.py` | NOT run: it needs a UI instance (a window), never `--headless` |

**Mutants (run once by hand on the Debug build, source restored afterwards, `git diff` empty).**

- **A. `applySendPositionsForKey:` made a no-op** (`return NO` at its entry): `--only Q2,R2,V2` = 76 OK, **40 FAILED** (Q2 19, R2 5, V2 16). Signature: every send stays at the END of the list (index 5, after the window fade), the wet reads -41.0 dB for input, chain 0, chain 1 and pre-fader instead of 0 / -6 / -18 / -21, the audit reports `index_before_*` violations, and `age_samples` is 2880 at every position.
- **B. `setEnvelopeSource` never called**: `--only S2` = 19 OK, **6 FAILED** (for pre-fader, chain and input: "wet = dry +20 dB in every window, fades included" measured 38.752 dB off, and "envelope source set" false).
- C (a third mutant): not run, the plan lists two.

**Two test-side findings of the gate.** (1) V2 counted the tap age in 48 kHz samples; the machine's output device is now at **96 kHz** (the live graph follows the device, the exports stay 48 kHz), so every age doubled and five checks failed. The test now reads the graph's rate from `debug.bridge_report`; the app was right. (2) A section checking "no `tap`/`sendMarker` in the file" must read the `items`, not the whole file: the `_readme` names both keys in prose.

## D.2 INC 3 — plugins on the send (branch `feature/sends-inc3-plugins`, format 23, engine patch `0040`)

Detailed on 10 October 2026 against `feature/sends-inc2-position` at `2fc674e5` (INC 2 + the
pre-fader consolidation refusal) and the fork at `objekat-sends-0039`. NOTHING of this section is
coded. It REPLACES the sketch that stood here and SUPERSEDES decision P6 and the "INC 3 (P6)"
paragraph of §A.2 (see D.2.A.d for the proof). The branch name of the sketch
(`feature/sends-inc3-chain`) is replaced by `feature/sends-inc3-plugins`, taken from
`feature/sends-inc2-position`; the fork branch is `objekat-sends-0040`, taken from
`objekat-sends-0039`.

What the user gets: plugins that process ONLY what one object sends to one aux — a low-pass on the
signal going to the reverb — without touching the object's direct signal, nor the aux as heard by
the other senders. The send keeps its identity (one per (object, aux)), its four positions, its
level, its switch, its curve.

### D.2.A Design

#### A.a The signal order of a send, once and for all

```
tap (a COPY of the signal at the send's position; the direct signal passes through untouched)
  → envelope (the sender's fades and window — only when the tap is not post-fader, Q-U5)
  → the send's plugins, in order
  → the send's level (smoothed, automated) and its gate (mute / solo, Q-U1 / Q-U12)
  → the ring → the aux return
```

- **Envelope BEFORE the plugins.** A post-fader send has the window and the fades upstream of its
  tap by construction (they are in the main path). Putting the envelope first at the other three
  positions makes the four positions the same thing to the plugins: with the fader at 0 dB and the
  pan centred, moving a send from post-fader to pre-fader changes nothing in what is heard,
  mini-chain included. The other order would make a compressor on a send react differently
  according to where the send is taken.
- **Level and gate AFTER the plugins.** (1) `-inf`, a mute and a solo give EXACT silence at the
  ring whatever the plugins do (P8, Q-U12) — a delay with feedback on a muted sender's send does not
  leak. (2) One automated stage, at the place where it is already aligned (P3). (3) It is the
  console's convention: inserts before the fader.
- **Audible, and therefore asked (Q-U17):** the order is inaudible for a linear plugin (a filter, an
  EQ) and audible for a non-linear or time-based one. Level last means that a compressor or a
  saturator on the send is NOT driven by the send's level, and that lowering the send lowers a
  delay's tail at once. Hypothesis: level last. The other order is a 10-line change in the patch;
  step 3.4 keeps it in one place.
- **Proof.** Section O3 of the scenario, with a hard clipper (`clipTester`, new, app-side): the two
  orders differ by 6 dB (D.2.C).

#### A.b Engine: patch `0040` — what it contains

All in the fork, on top of `0039`; no file of the fork other than these three is touched.

1. `plugins/tracktion_ObjBridge.h` — `BridgeTapSource` gains two virtuals, both with a neutral
   default so that `ObjBridgeTapPlugin` (the sidechain tap) is untouched:
   ```cpp
   /// The plugins this tap runs on its COPY before recording it (a send's mini-chain). nullptr = none.
   virtual PluginList* getTapChain()                                   { return nullptr; }
   /// What the tap applies to its copy BEFORE the chain (a send: its sender's window and fades),
   /// at the edit time the signal was made. Called once per block, in both modes.
   virtual void processTapHead (juce::AudioBuffer<float>&, int start, int numSamples,
                                TimeRange editTime)                    {}
   ```
2. `playback/graph/tracktion_ObjBridgeNodes.h/.cpp`
   - `BridgeTapHeadNode` (new, ~60 lines): one input, an OWNED 2-channel buffer; copies its input,
     calls `source.processTapHead` at `editTime − input latency` (the adjustment the tap node does
     today), reports its input's properties. It is the fan-out's second consumer.
   - `BridgeTapNode` gains an optional second input, `wet`. `input` becomes a `std::shared_ptr`
     (the dry is shared with the head node). `getDirectInputNodes()` returns both;
     `getNodeProperties()` still returns the DRY input's (the node's output IS the dry, untouched —
     that is what it declares). Copy mode, per block:
     - no `wet` input (no chain): copy the dry into the scratch, `processTapHead`, then
       `applyToBufferWithAutomation` (level + gate) — the same operations in the same order as
       INC 2, the envelope simply called from the node instead of from inside `applyToBuffer`;
     - a `wet` input: copy the WET into the scratch, then level + gate, with the automation time
       moved back by the WET's latency (`L + P`), not the dry's.
     Ring write unchanged (`referenceSampleRange.start`, `didPlayheadJump`).
3. `playback/graph/tracktion_EditNodeBuilder.cpp`, `createPluginNodeForList`, the
   `BridgeTapSource` branch (today ~l.1900):
   ```
   chain = tap->getTapChain()
   if p->isEnabled() and chain and chain has at least one enabled plugin:
       shared = node                                   (std::shared_ptr)
       wet    = BridgeTapHeadNode (ConnectedNode-style reader of shared, *tap)
       wet    = createPluginNodeForList (*chain, …, wet)          (ordinary PluginNodes)
       if wet latency > 0: wet = LatencyPrimingNode (wet)         (gags the residue, as a clip's)
       age    = wet->getNodeProperties().latencyNumSamples        (L + P)
       registerTap (*p, *tap, age, rank)
       node   = BridgeTapNode (shared, wet, …)
   else:
       the INC 1 / INC 2 construction, unchanged (age = L)
   ```
   plus the `initialiseFully` recursion into the chain's plugins (as `ObjParallelBlockPlugin` does
   for its branches) and the Debug assertion I1 unchanged.

No change to `BridgeBuild`, to the readers, to `createAuxReturns`, to `PluginList` (the mini-chain
is a `PluginList` over a `<BRANCH>` child, which `PluginList::initialise` already accepts).

**No mini-chain, or a disabled send = exactly the INC 2 node.** Proved by section P3 (a reference
export recorded at step 3.0, compared sample for sample after the patch).

#### A.c The node inside a `TimedNode` — why a side input is legitimate (read, not inferred)

A clip's chain is processed by `CombiningNode::TimedNode`: a de-duplicated post-order walk over
`getDirectInputNodes()`; as soon as the chain is not linear it goes through `transformNodes` and
gives each node its own buffer; only SUMMING nodes equalise their inputs' latency
(`createLatencyNodes`). `createNodeForParallelBlock` already relies on all three (a shared input,
one `ConnectedNode` per branch). A `BridgeTapNode` with a dry and a wet input is therefore processed
after both, and its wet is NOT padded, because the node is not a sum. **To verify first** (step
3.0, probe b): that `transformNodes` leaves a non-summing two-input node alone, with a throwaway
build of the patch and a 20 ms `latencyTester` in the mini-chain. If the probe fails, the fallback
is P6 as originally written (`SummingNode { dry, SinkNode (wet) }`): same model, same UI, same
tests except the three assertions marked "hide only" in D.2.C.

#### A.d Latency of the mini-chain: it ages the TAP, it does not delay the dry (P6 revised)

Question asked: can the mini-chain's latency `P` be added at the return only, without delaying the
object's direct signal? **Yes — and that is what is built.** Read in the bridge:

1. The age of a tap is a FREE argument of `BridgeBuild::registerTap (plugin, source, age, rank)`;
   the tap node itself reports its input's properties. Nothing ties the age to the node's own
   declared latency.
2. `registerAuxReaders (auxClipID, sendIDs, referenceLatency)` computes the return's group latency
   `X = max (R, every tap's cached age)`, and each reader delays its ring by `X − age`. A tap OLDER
   than the content of the aux's level (`age > R`) is the existing "case B": the content is padded
   by `X − R` at the return's sum. `finalise()` re-passes (at most 8) when a reader turns out late
   or over-declared. Exercised today by `scenario_bridge_latency` B / H and by INC 1's across
   routes.
3. So with `age = L + P`: when `L + P ≤ R` (the aux's level already carries that much latency)
   nothing moves anywhere; when `L + P > R`, the aux return — and only it — declares `L + P`, and
   the ordinary PDC of its level follows. The sender's lane, its direct signal, its declared
   latency, its own sidechain tap's age, its bake: untouched.

Compared with P6 (the dry delayed by `P`): the session's latency is `max (R, L + P)` here against
`max (R', L + P + M)` there (`M` = what follows the send in the sender's chain) — never worse. P6's
rejection of this option ("a node that lies about its inputs") does not hold: the node declares
its OUTPUT, which is the dry; the wet leaves the graph through the ring with its true age, which is
exactly what a bridge tap is.

Costs, stated:
- **One more build pass, sometimes.** `cachedAgeNumSamples` is not state: the first build after a
  mini-chain's latency changes, and EVERY export (a clone), starts with the previous or a zero age;
  when `L + P > R` the reader is found late and `finalise` runs one more pass. Assertion of the
  scenario: `passes ≤ 2`, `converged`, `blocks_uncovered == 0`.
- **The wet's activation.** A clip's nodes run only on `[start − head, end + tail]`, and
  `Clip::getHead()` / `getTail()` sum `getLatencySeconds()` over the clip's list. So
  `ObjBridgeSendPlugin::getLatencySeconds()` returns its mini-chain's series latency: the clip
  starts `P` earlier and stops `2P` later, which is what the wet needs. The only readers of that
  number are head / tail and `primeSamples` (read, `tracktion_Clip.cpp:420-439`,
  `createNodeForClips`): the lane's equalisation uses NODE latencies, where `P` does not appear.
- **Known limit.** A child whose send's mini-chain has latency `P`, ending exactly at the hard end
  of its PARENT group: the last `P` of its wet is not flushed (the parent's tail ignores a hidden
  latency). `P` is milliseconds; noted, not fixed.

`checkLatencyAndRebuild` already sums `getLatencySeconds()` over `_pluginMap`; the mini-chain's
plugins are `_pluginMap` entries, so a plugin that changes its latency on a send provokes the same
rebuild as on the trunk.

#### A.e Tails

The mini-chain runs while the sender's clip is active — its window plus its head / tail. A reverb
or a delay laid ON a send is therefore cut at the object's end, exactly as it is when laid on the
object's chain ("an object's window cuts its chain"); at the next activation the residue is gagged
like a trunk plugin's. To let an effect ring: put it on the aux (that is what an aux is for), or
send from an infinite bus. Audible, and therefore asked (Q-U18); hypothesis: accepted, same rule as
the chain. The alternative (keeping the wet branch alive after the clip) needs the branch OUT of
the clip's `TimedNode` — another architecture, not planned.

#### A.f Where the plugins live; limits; who owns what

- **Owner.** `ObjBridgeSendPlugin` owns ONE `PluginList` over a `<BRANCH>` child of its state
  (`ParallelPluginBlock::branchTreeType`, reused as a tree type only — the send plugin does NOT
  implement `ParallelPluginBlock`, or the builder would unfold it as a parallel block). Built as
  `ObjParallelBlockPlugin::rebuildBranchLists` does: `setTrackAndClip (getOwnerTrack(),
  getOwnerClip())`, `initialise (branch)`; `initialiseFully` recurses; `getTapChain()` returns it.
- **Limits.** `PluginList::canInsertPlugin` counts per LIST: the mini-chain has its own limit, and
  its plugins do NOT count in the 20 entries of the object's chain. The send itself still costs one
  entry there, with or without plugins. The number for a `<BRANCH>` list owned by a clip is to be
  read by probe (step 3.0, probe a: expected 20, could be 45 — `OBJEngineBehaviour::getEditLimits`).
  Beyond it the door answers `chainFull`, as the trunk does.
- **Bookkeeping.** A mini-chain plugin is an ordinary keyed instance: `_pluginMap[pluginKey]`,
  `_pluginOwnerHost[pluginKey] = sender`, listed in the SENDER's `_objectChainMap[key].pluginKeys`.
  Editors, parameter doors, state capture, `OBJParamMirror` links, VU and `checkLatencyAndRebuild`
  all work by key and need nothing new. It is NOT in `rootOrder` (that is the trunk's).
- **Rebuild.** Adding, removing or reordering a mini-chain plugin is a compile of the sender's
  chain: `restartPlayback` once, with `_latencyResyncPending`, exactly as for a trunk plugin. An AU
  instantiated on the main thread stays the slow gesture; nothing is made worse.

#### A.g The materialisation rule (new — a consequence the sketch did not see)

Today a DEAD send (switched off, or at `-inf` with no curve, or refused) has NO engine plugin:
`syncBridge` lays only `isSendAlive` sends and `commitBridgeSync` removes every send it did not
confirm. With a mini-chain that is wrong twice: dragging the level to `-inf` would destroy the
send's AU instances (and their un-captured state), and a NEW send starts at `-inf` (Q-U4), so the
plugin just laid on it could not open its editor.

**Rule: a send's engine plugin exists iff the send is alive OR carries plugins.** Its engine
`enabled` flag = alive. Consequences, each in one place:
- `ensureBridgeSendFrom:toAux:levelDb:gated:position:` gains `alive:`; a not-alive send is laid
  (confirmed, positioned), disabled, and NOT listed in `objBridgeSends` (no reader, ring null).
- The builder builds no wet branch for a disabled tap (A.b): the instances exist, loaded, with
  their editors, and are not processed. Becoming alive is a change of the graph's shape: one
  restart, no instantiation.
- `isSendAlive` keeps its meaning for `BridgeScope` (a not-alive send is no route, blocks nothing).
- A send REFUSED by the scope or by `chainFull` while carrying plugins: the plugin is not laid, its
  mini-chain is not instantiated (the model keeps the states), the cards are greyed with the
  refusal's reason. Same thing as a plugin whose host is not in the engine.
- A not-alive send with plugins costs one entry of the object's 20, like an alive one.
- Every site that REMOVES a send plugin first purges its mini-chain's keys (`teardownPluginLink`,
  `_editorWindows`, `_pluginMap`, `_pluginOwnerHost`, the sender's `pluginKeys`): the unconfirmed
  loop of `commitBridgeSync`, `removeAux` (which removes the sends aimed at it),
  `forgetObjectBookkeeping`, `closeEditorsAndPurgePluginsForObjectID:`. One helper,
  `-purgeSendChainOf:`, called by the four.

#### A.h Compile and sync: who owns what

- **The compile owns the CONTENT.** `rackSpec` gains, beside the trunk tree, one entry per send
  that carries plugins, whatever its position:
  `compileUserRackForObjectID:tree:sendChains:chainInDb:chainOutDb:` with
  `sendChains = [{ "aux": <uuid>, "plugins": [<series tokens>] }]`. For each, the compile makes sure
  the send plugin exists (the helper it shares with `ensureBridgeSend`: created disabled, at the
  end, if the sync has not laid it yet) and runs the reentrant
  `compileSeries:into:anchor:order:failed:` INTO the send's list with a nil anchor — instances
  reused by key, parked when they leave, state re-asserted, reordered only when needed: the same
  code as a parallel branch. A send whose model chain is empty gets its list emptied.
- **The sync owns the ROUTE**: existence for an alive send, target, level, gate, liveness,
  position, `objBridgeSends`. It never touches a mini-chain's content, and after INC 3 it never
  removes a send that carries plugins in the model (it is always confirmed).
- **Order of the two** does not matter (each creates the send plugin if the other has not), which
  is the property the INC 2 marker rule already needed.
- **Retarget** (`send.retarget`, "Change target…"): the plugins STAY (given). The engine re-keys in
  place — a new `-retargetBridgeSendFrom:oldAux:newAux:` renames `_bridgeSendMap["sender|aux"]` and
  calls `setTargetAuxClip` — BEFORE the sync, so that no instance is destroyed and re-created. To
  verify at 3.0 (probe d) how INC 2's retarget reaches the engine today (expected: remove + lay
  again, which would re-instantiate every AU of the mini-chain).

#### A.i Model and session format 23

```swift
struct AuxSend {
    var auxID: UUID
    var levelDb: Float
    var enabled: Bool
    var tap: SendTapPoint
    var plugins: [ObjectPlugin] = []     // INC 3: the mini-chain, in processing order
}
```
- `init` gains `plugins:` with a default; `decodeIfPresent`; ENCODED ONLY WHEN NON-EMPTY — a
  session without any send plugin differs from its format-22 self by the version number only.
- **Format 23.** A format-21 / 22 file reads identically (absent key = no plugin). An OLDER build
  opening a 23 file ignores the key: the send plays without its plugins, and saving from that build
  loses them (and leaves the automation lanes aimed at them orphaned — probe e at 3.0 says what the
  loader does with a lane whose plugin id is unknown; expected: kept, inert). Said in the
  `SessionSchema` notice.
- **v1 content rule, enforced by ONE pure function** (`SendChain.sanitised`, called at decode and
  by `updateChainPlugins`): leaves only. Dropped with a log: a parallel block, an FX link bin, a
  send marker, an instrument, an ARA source. Technical reasons: a marker in a mini-chain would be a
  send of a send; a bin's instances belong to a definition shared across HOSTS and every bin site
  resolves `fxDefinition(ofInstance:on:)` by object or stem; an instrument needs MIDI at its input.
  A parallel block would work in the engine (the builder recurses) but not in the card (Q-U9).
- **Ids.** A mini-chain plugin's id is as unique as any plugin's: `PluginIDUniqueness` (walk,
  detection, repair) and `debug.plugin_id_audit` gain the third root.
- **Automation.** A mini-chain plugin's parameters are `ParamRef.plugin(id:param:)` lanes of the
  SENDER object, as for a trunk plugin: the automation targets list and the push learn the third
  root; nothing else changes.
- **NO LINK ON A SEND — decided by the user on 10 October, REPLACING the hypotheses of Q-U8 and
  Q-U8b** (he means to retire the FX links eventually): a plugin of a send's mini-chain NEVER carries
  a `linkGroupID` (nor a detached one). No FX link bin (unchanged), and no ⌘ link either. A linked
  plugin of the trunk that is moved or copied into a send arrives UNLINKED. Every copy of an object
  (duplicate, cut, split, copy / paste inside a project or across two) copies its send plugins
  INDEPENDENT: fresh ids, the state copied, no link created — unlike the trunk's own default, which
  is NOT touched. Enforced in ONE pure place, `SendChain.sanitised` (decode, `sanitisingSends`,
  `SendChain.mapping`, every write of a send host): it clears both memberships, so no door, copier
  or file can keep or create one; `rewireLinkGroups` does not walk the third root, `setLinkGroups`
  ignores a send plugin, `copiedSends` builds unlinked copies and the automatic FX link bins
  (`copiedRun`) never see a send's plugins. The ⌘ gesture: dragging with ⌘ to or from a send falls
  back on a PLAIN COPY (⌘ = "copy + link", minus the link) and the banner says "copy" there, never
  the link's glyph; the explicit machine door `plugin.link` with a send host on either side is
  refused (`invalid_state`, `send_plugins_never_linked`). Proved by `test_send_chain` ("no link"
  block) and checked by `debug.send_marker_audit` (`linked_send_plugins`, always empty).
- **Sidechain key on a mini-chain plugin**: the reader sits in a `PluginNode` of the wet branch, in
  the sender's clip — the same case as a keyed leaf of the trunk, with an input latency of `L + P'`
  instead of `L`. `bridgeTopology`, `bridgeLeafExists`, `settingSidechain` learn the third root (the
  route's host is the SENDER). Allowed in v1 IF probe f (step 3.0) and section K3 measure the key
  aligned; otherwise refused with a reason in v1. Not a user question.

#### A.j Addressing: a send's mini-chain is a third kind of CHAIN HOST

Every plugin gesture of the app is written against a chain host — an object or a stem — through
four primitives (`chainPlugins`, `updateChainPlugins`, `chainGains`, the engine key). A mini-chain
becomes the third kind, so that selection, drag and drop, copy / paste, the doors and the whole
`plugin.*` API work on it WITHOUT a parallel family of functions:

- `Shared/SendChain.swift` (new, pure): `SendChain.hostID(sender:aux:)` — a UUID DERIVED from the
  pair (SHA-256 of `"objekat.sendchain|<sender>|<aux>"`, truncated, version / variant bits set).
  Nothing is persisted; a copy of the object, a retarget, an undo all get the right host for free.
- `EditViewModel.sendChainHosts: [UUID: SendKey]` — a lazy index, invalidated by `items.didSet`
  (the same pattern as `sendScopeIndexCache`), giving the reverse lookup.
- `chainPlugins(hostID)` answers the send's `plugins`; `updateChainPlugins(hostID)` writes them
  through `update(id: sender)`, sanitised; `chainGains` answers `(0, 0)`; `isStemHost` false;
  **`engineHostKey(hostID)`** (new) answers the SENDER's id for a send host and the host itself
  otherwise — every `forObjectID:` call that receives a host goes through it; `compileRack(send
  host)` compiles the sender; `scheduleChainCompile(send host)` schedules the sender's.
- What a send host is NOT: it is not found by `find(id:)`. That is the danger of the approach, and
  the reason for the audit of step 3.6: every site that takes a host and then assumes "object or
  stem" (a nil `find` falling through to a stem branch, a silent return) is listed and tested.

The alternative (an explicit `enum ChainRef { object, stem, send }` threaded through every
signature) is cleaner on paper and touches ~120 call sites for the same behaviour; rejected for
v1, kept as the natural clean-up if a fourth host ever appears.

#### A.k Copies, split, paste, consolidate, deletion, retarget

The trap is the same everywhere: `sends` is copied BY VALUE at a dozen sites, which until now was
right (a send held no identity of its own). With `plugins` inside, a by-value copy duplicates
plugin ids — two objects claiming one engine instance, the defect of the "duplicate plugin ids"
incident. Rule: **a copy of an object copies its sends' plugins through the same primitive as its
chain's** (`copiedPlugins(of:)` for a live copy, the cold clone of `CrossProjectImport` for a
frozen one), with the same id remap feeding the automation lanes.

| Operation | What happens to the send's plugins |
|---|---|
| Duplicate, copy / paste, ⌥ drag, time-selection copy | Fresh ids, states captured, automation lanes remapped. INDEPENDENT copies: never linked (decision of 10 October). |
| Cut / split of the object | Both halves keep the send; the right half's plugins are INDEPENDENT copies. |
| Split of an AUX (`duplicateSendsTarget`) | The senders gain a send to the new half: position and plugins COPIED (fresh ids, independent). Today this site drops the position — see D.2.F, deviation 1, fixed in step 3.7. |
| Cross-project paste | Cold clone from the frozen `stateXML`, fresh ids, NO link (not even inside the batch); a send whose aux is not in the batch is dropped with its plugins (existing rule). |
| Bake of a group (`deepFreshCopy`) / un-bake | Fresh ids through `freshPlugins`, `pluginRemap` extended; the restore takes the wrapper's sends (existing). |
| Consolidate, `input` / `chain` send, choice **Fold** | The send goes post-fader WITH its plugins, level and curves (a fold changes where the send is taken, not what it is). |
| Consolidate, choice **Delete** | The send goes with its plugins and every automation lane aimed at them or at its level; one undo point. |
| Consolidate, `pre_fader` send | Refused (decision of 10 October), plugins or not. |
| Consolidate, `post_fader` send | Carried onto the placement as today, plugins included (the placement has no chain but keeps its sends; its mini-chains are compiled like any object's). The sidecar must NOT keep a second copy of those plugins — probe c, step 3.0. |
| Delete the send (card ×, `send.remove`, aux deleted, orphan purge) | Plugins, their editors and their automation lanes go with it; states captured first so that undo brings back the same sound. |
| Retarget | Plugins, level, position, curves stay (given); no instance is re-created (A.h). |
| Move the send to another position | Plugins stay; the envelope rule of A.a follows the position. |
| Switch off / `-inf` | Plugins stay loaded, unprocessed (A.g). |

**Undo.** A plugin gesture on a mini-chain is the plugin doors' own point (pushUndo before the
first modification, as everywhere). `isPatchable` / `adoptingPluginStates` / `changedPluginStates`
learn the third root: without it a parameter undo on a send plugin rebuilds the whole object (D.2.F,
deviation 2). `withCapturedPluginStates` / `capturingPluginStates` capture the third root, or a
save would write stale states.

#### A.l Signal view — ONE layout recommended

Today an outgoing send is a 28-pt card in a column to the right of the trunk, wired to the trunk at
its position. **Decided by the user on 10 October (Q-U19) — the literal order of the signal: the
plugins ON TOP, the header line AT THE BOTTOM** (the first version of this section had the header on
top; it is superseded):

```
 trunk ──┐
         ├──▶ ┌───────────────────────────────┐
              │ ● Low-pass              ⛓  × │   one compact row per plugin, in processing order
              │ ● Saturator                 × │
              │ +                             │   after the last plugin, just above the level line
              ├───────────────────────────────┤
              │ ↳ Reverb A        -12 dB  (●) │   the send's line: today's card (aux, level, on/off)
              └───────────────────────────────┘
```

- **The card becomes a box**: one row per plugin (22 pt) — bypass dot, name, the × on hover (no link pastille: a send's plugin is never linked) — then the "+", then, at the BOTTOM, the header line (today's card, same
  height, same controls). A send without plugins is drawn exactly as today (plus the "+" on hover,
  above the line).
- **Reading order**: top to bottom is the signal — the tap, the rows in processing order, then the
  level of the bottom line, then the aux. The wire from the trunk's tap point therefore arrives at
  the TOP of the box (its first row; the line itself when there is no plugin), and the insertion
  slots of a drop are counted from the top: slot 0 above the first row, slot N between the last row
  and the "+" / the level line.
- **Variable height**: `SendCardPlacement` (pure) takes each box's height instead of a constant;
  stacking, wire anchors and the canvas height follow. The column's width does not change.
- **Gestures**, all through the existing chain-host code (A.j):
  - "+" → the plugin picker, targeted at the send host; right-click on the box → the same entry.
  - Drag a plugin card FROM the trunk (or from another object, or from the explorer) ONTO a box or
    between two of its rows: nothing = move, ⌥ = copy; ⌘ (copy + link elsewhere) is a PLAIN COPY
    as soon as a send is the source or the target (no link on a send). Drag a row out to the trunk, to another send's box, to another object: same.
    `PluginDropSite` gains `.sendChain(aux:index:)`; `PluginDropHint` draws the insertion line in
    the box. Refused with a hint: an instrument, a parallel block, a bin's card, a send card.
  - Reorder by dragging a row inside its box.
  - Click selects a row (plugin selection, host = the send host; ⇧ / ⌘ extend inside the box);
    ⌫ deletes; ⌘C / ⌘V as on the trunk; double-click opens the editor; the dot bypasses.
  - Dragging the HEADER still moves the send along the trunk (INC 2), rows following.
- **A greyed box** (send refused, or host not in the engine): rows greyed, editors not openable,
  the refusal's reason as tooltip (existing string).
- **VU**: none per row in v1 (the trunk's cards have none either beyond what exists); the send has
  no meter today and gains none.
- **The aux's head** (received sends): the row gains a small "fx" mark when the sender's send
  carries plugins; nothing editable there.
- Not in v1: collapsing a box; the multi-selection inspector and the Aux tool show nothing of the
  mini-chain (they set levels).

#### A.m API

No new family: the mini-chain is a host.

- `send.list` / `send.get` entries gain `chain_host` (the derived host id — always present, so a
  script can lay the first plugin) and `plugins` (`[{id, name, enabled}]` — never a link group).
- Every `plugin.*` command that takes `host` accepts a send host: `plugin.list`, `plugin.add`,
  `plugin.remove`, `plugin.toggle`, `plugin.move`, `plugin.copy`, `plugin.link`, `plugin.unlink`,
  `plugin.drop`, `plugin.drop_at`, `plugin.paste`, `plugin.get_params`, `plugin.set_param`,
  `plugin.get_state`, the selection commands. Refusals are `invalid_state` with a reason:
  `send_chain_leaves_only` (block, bin, instrument, marker), `chainFull`.
- `debug.add_test_plugin` accepts a send host, and gains `clipTester` (`ceiling_db`).
- `debug.send_marker_audit` and `debug.plugin_id_audit` count the third root;
  `debug.bridge_report` gains, per send tap, `chain_plugins` and `chain_latency_samples`.
- `object.get` / `runtime` plugin counts: stated explicitly whether they include send plugins
  (they do: `plugins_on_sends` beside the existing count, the existing number unchanged).

#### A.n i18n, documentation

- Strings (symbolic keys, three languages, through `L()`): the "+" tooltip, "applied after the
  send's plugins", the three drop refusals, the "fx" mark's tooltip, the picker's title for a send
  ("Add a plugin on the send to %@"). No sentence is assembled from pieces.
- `CLAUDE.md`: the INC 3 entry; the PERMANENT rule "an object's plugins have THREE roots —
  `plugins`, `instruments`, and each send's `plugins` — walk them through `SendChain.allRoots`,
  never by hand" beside the marker rule.
- `docs/command_api.md` (send and plugin sections), `docs/architecture_decisions.md` (P6 revised,
  the materialisation rule, the host), `SessionSchema` notice (format 23),
  `engine-patches/3.5/README.md` (`0040`), this document's journal (D.2.G, to be opened).

#### A.o Settled here (technical, reversible) — not questions

The hide design of A.d, with P6 as its fallback; envelope before the plugins; the mini-chain's own
entry limit; the materialisation rule; compile = content, sync = route; the derived host id; leaves
only in v1; NO link of any kind on a send (10 October); a sidechain key allowed if measured aligned; automation
lanes on the sender; fold keeps the plugins; no per-row VU; plugins of a refused send not
instantiated.

### D.2.B Implementation plan

One commit per step at least; nothing pushed; the fork branch pushed only at the end, with the
patch file regenerated into `engine-patches/3.5/` (the patch is the only backup of the engine code).

**3.0 — Preliminaries (no product code).** Branches. A full run of `scenario_bridge_sends.py` on
`feature/sends-inc2-position`, its exports kept as the P3 reference. The real inventory (table
below) by `grep`, counts written in the journal. Six probes, each a few lines, results in the
journal before anything is designed around them:
  a. the entry limit of a `<BRANCH>` list owned by a clip (20 or 45);
  b. a non-summing two-input node inside a `TimedNode` (A.c) — throwaway patch;
  c. what the consolidation sidecar and the `ConsolidateDefinition` keep of `sends`, and whether
     `PluginIDUniqueness` walks them;
  d. how INC 2's retarget reaches the engine (remove + lay, or in place);
  e. what the loader does with an automation lane aimed at an unknown plugin id;
  f. a `objKeyProbe` in a hand-built wet branch: is the key aligned (A.i).

**3.1 — The scenario first.** Sections A3, L3, O3, P3 of D.2.C written and FAILING (or skipped with
the reason "no door yet") before the feature exists.

**3.2 — Pure model.** `AuxSend.plugins` (init, Codable, `==`); format 23 in `SessionSchema`;
`Shared/SendChain.swift`: `hostID(sender:aux:)`, `sanitised(_:)`, `allRoots(of:)` (the ONE walker:
trunk leaves, instruments, each send's plugins), `mapPluginIDs`. `tools/test_send_chain.swift`.

**3.3 — The third root in every pure walker and copier.** `PluginIDUniqueness` (:58, :165, :238),
`PluginIDReport` (:68), `SendMarkerAudit` (:61), `CrossProjectImport` (:278 and the `sends` map at
:286), `SoundObject.derivedCopy` (`pluginIDRemap`, :1160), `SendPosition.swift` (retarget keeps
`plugins`; `sanitisingSends` calls `SendChain.sanitised`), `SendBakePolicy.resolve` (fold keeps,
remove returns the plugin ids whose lanes must go). Tests extended:
`test_plugin_id_uniqueness`, `test_cross_project_import`, `test_send_position`,
`test_send_bake_policy`.

**3.4 — Engine patch `0040`** (A.b), on `objekat-sends-0040`. Built alone first; `scenario_bridge_
latency.py`, `scenario_sidechain.py` and section P3 green BEFORE the app uses the new virtuals.

**3.5 — App, engine side** (`OBJBridgeSendPlugin.h`, `OBJEngineCore.mm`, `OBJGainTesterPlugin.h`).
The send plugin owns its list (`rebuildChainList`, `valueTreeChildAdded/Removed`,
`initialiseFully`, `getTapChain`, `getLatencySeconds`); the envelope moves from `applyToBuffer`
into `processTapHead`; `ensureBridgeSend…alive:` and the materialisation rule; `-purgeSendChainOf:`
and its four callers; `-retargetBridgeSendFrom:oldAux:newAux:`; `parseCompileSeries` /
`compileUserRackForObjectID:tree:sendChains:…`; `debug.bridge_report` fields; `clipTester`.

**3.6 — View-model: the third host.** `sendChainHosts` index; `chainPlugins` /
`updateChainPlugins` / `chainGains` / `engineHostKey`; `rackSpec` + `compileRack`;
`syncBridge` (lays alive-or-carrying sends, passes `alive:`); `collectPluginRefs`;
`withCapturedPluginStates` / `capturingPluginStates`; `isPatchable` / `adoptingPluginStates` /
`changedPluginStates`; `rewireLinkGroups`; automation targets and push; `bridgeTopology` /
`bridgeLeafExists` / `settingSidechain`; `copiedPlugins(of:)` callers; `deepFreshCopy`. THE AUDIT
of this step: every row of the inventory below, each closed by a named test.

**3.7 — The doors.** `addPlugin`, remove, move, toggle, `transferPlugins`, `performPluginDrop`
(`.sendChain`), plugin paste, on a send host; the refusals of A.i; `removeSend` (states captured,
lanes removed, same undo point); retarget; `duplicateSendsTarget` rewritten on a value copy +
`copiedPlugins` (fixes deviation 1); `pruneOrphanSends`.

**3.8 — API** (A.m) and the scenario helpers (`add_test(c, host=send_host, …)`).

**3.9 — Signal view, pure.** `SynopticSend.plugins`, `SynopticSendMapping`, `SendCardPlacement`
with heights, the box's row rects and insertion slots in `SynopticLayout`, `SendDrop`.
`test_synoptic_send_cards`, `test_send_drop` extended.

**3.10 — Signal view, drawn.** The box, the rows, "+", selection, drag sources and targets,
`PluginDropHint`, the picker's target, the "fx" mark at the aux's head. i18n keys.

**3.11 — The rest of the scenario, the mutants, the non-regression** (D.2.C).

**3.12 — Documentation** (A.n), patch file, README, journal D.2.G; `debug.plugin_id_audit` = 0 and
`debug.send_marker_audit` ok on the trial project; warning recount.

**The inventory — every site that must learn where a send's plugins live.** Same method as INC 2's
marker inventory: the count is taken by `grep` at 3.0, each line is classified (concerned / not,
with the reason), and each concerned family is closed by a test that proves the plugins SURVIVE the
transformation (or die with it, when that is the rule). Counts below are those of `2fc674e5`.

| Family | How to find it | Sites (lines / files) | What it must learn | Closed by |
|---|---|---|---|---|
| The second root (`instruments`) — the template of the third | `grep -rn '\.instruments' --include='*.swift'` | 56 / 19 | Wherever the instruments are walked beside `plugins`, the sends' plugins are too — through `SendChain.allRoots` | `test_send_chain` + each row below |
| Sends copied by value | `grep -rn '\.sends' --include='*.swift'` | 85 / 28 | A copy that creates a NEW object freshens the ids; a move does not | C3, `test_plugin_id_uniqueness` |
| `AuxSend(` built field by field | `grep -rn 'AuxSend('` | 3 (all `+Aux.swift`: 390, 425, 553) | :553 must copy, not rebuild | section C3 (aux split) |
| Chain-host readers | `chainPlugins(` | 82 / 15 | Works on a send host; no "object or stem" assumption after it | H3 |
| Chain-host writers | `updateChainPlugins(` | 36 / 7 | Sanitised write through the sender | H3, `test_send_chain` |
| Engine calls keyed by host | `forObjectID:` | 42 / 10 | `engineHostKey` | H3 (editor opens, param set) |
| Leaf walks | `flattenLeaves(` | 26 / 10 | Third root where the walk means "all plugins of the object" | audit + U3 |
| State capture | `withCapturedPluginStates(`, `capturingPluginStates` | 21 / 6 | Third root | Z3 (save), U3 (undo) |
| Undo patching | `isPatchable`, `adoptingPluginStates`, `changedPluginStates` | `+UndoRedo.swift` 272–403 | Third root | U3 ("state undo does not rebuild") |
| Live copies | `copiedPlugins(of` | 25 / 6 | Called for each send's plugins | C3 |
| Links | `linkGroupID`, `rewireLinkGroups` | 81 / 16 | NOT the third root: a send plugin is never linked (10 October) — `sanitised` clears, `rewireLinkGroups` skips | `test_send_chain` "no link", C3, the audit |
| Cold copies | `CrossProjectImport`, `deepFreshCopy.freshPlugins / rebuild`, `derivedCopy` | 3 files | Fresh ids + remap | `test_cross_project_import`, B3 |
| Id audit / repair | `PluginIDUniqueness`, `PluginIDReport` | 2 files | Third root | `test_plugin_id_uniqueness` |
| Automation | `+Automation.swift` 116 / 365, `+AutomationTargets.swift` 161 | 3 | Targets list and push include send plugins | U3 (a curve on a send plugin's parameter, measured) |
| Sidechain | `+Bridge.swift` 86 / 280 / 353 | 3 | Third root, host = sender | K3 |
| Consolidate / bake | `+Consolidate.swift` 559–579, 658–674, 742, 775, 1076; `+Bake.swift` 126–170, 212; `SendBakePolicy` | 3 files | The table of A.k | B3 |
| Engine removal sites | `commitBridgeSync`, `removeAux`, `forgetObjectBookkeeping`, `closeEditorsAndPurgePluginsForObjectID:` | 4 | Purge the mini-chain first | M3 (no dangling key: `debug.plugin_id_audit` + editor count) |
| Engine latency watch | `checkLatencyAndRebuild` | 1 | Nothing (by `_pluginMap`) — verified by test | L3 |
| API payloads and counts | `Commands+Plugins` 75 / 1043 / 1060, `Commands+Object` 68, `Commands+Runtime` 183, `Commands+Aux` | 4 files | A.m | H3 |
| Signal view | `SynopticView.swift` (7 `instruments` sites), `SynopticSendMapping`, `SynopticLayout`, `SendDrop` | 4 files | A.l | `test_synoptic_send_cards`, the eye |
| Project load | `+ProjectLoad.swift` 136 / 368 | 2 | Sanitise, instantiate, re-assert states | Z3 |

A line classified "not concerned" is written with its reason in the journal (INC 2 found 6 real
omissions out of ~40 sites this way).

### D.2.C Test plan

Conventions unchanged (C.3, D.1.C): Debug build, headless, `--no-recent`, audio ON, one fresh
instance per scenario, exports re-read in 24-bit at 48 kHz, the wet measured BY DIFFERENCE (export
with the aux, export with the aux muted), levels read against a reference taken in the same section
(the pipeline's constant offset cancels), the live graph's rate read from `debug.bridge_report`.

**Pure (any machine).**
- `tools/test_send_chain.swift` (new): `hostID` deterministic, distinct for distinct pairs, never
  equal to either id; `sanitised` drops a block, a bin, a marker, an instrument, keeps leaves in
  order; `allRoots` yields trunk leaves, instruments and every send's plugins exactly once;
  Codable — no `plugins` key when empty, round trip when not, a format-22 payload decodes to empty
  chains; a retarget keeps `plugins`; `settingSendPosition` keeps them at the four positions.
- `test_plugin_id_uniqueness`: a duplicate between a trunk plugin and a send plugin, and between
  two sends' plugins, is detected and repaired; a `derivedCopy` and a `deepFreshCopy` of an object
  with a mini-chain share NO id with the original, and the automation lanes follow the remap.
- `test_cross_project_import`: an object with a mini-chain and its aux in the batch (plugins cloned,
  fresh ids, INDEPENDENT — a link is dropped even inside the batch); aux outside the batch (send and plugins dropped, no
  orphan lane).
- `test_send_bake_policy`: fold keeps the plugins and their lanes; remove names the lanes to
  delete; a pre-fader send with plugins still blocks.
- `test_synoptic_send_cards`, `test_send_drop`: box heights, stacking of two boxes at neighbouring
  slots without overlap, insertion index from a point, the refusals.

**`tools/scenario_bridge_sends.py`, new sections** (suffix 3; `--only` works as today).

| Section | What it proves | Measure |
|---|---|---|
| P3 | No mini-chain = INC 2, to the sample | The INC 2 sections' exports against the reference of step 3.0: `maxabs(diff) == 0`. |
| A3 | THE feature: a send plugin acts on this sender's wet only | X1 (0–1 s) and X2 (1.5–2.5 s) both send to aux A at -6 dB. `gainTester -12 dB` on X1's send. (1) dry export (aux muted) identical to the dry export before the plugin: `maxabs == 0` — "hide only": with the P6 fallback, "identical after alignment". (2) wet in X1's window: -12.00 ± 0.05 dB against the reference. (3) wet in X2's window: `maxabs(diff) == 0` against the reference. (4) the same plugin on X1's TRUNK instead lowers the dry too (the control). Repeated at the four positions. |
| L3 | Sample alignment with latency on the send | A click source; `latencyTester 20 ms` on the send. `idx(wet peak) == idx(dry peak)` in the export; `bridge_report`: tap `age_samples == L + P` at the graph's rate, `chain_latency_samples == P`, `passes ≤ 2`, `converged`, `blocks_uncovered == 0`; the dry export bit-exact with the one without the plugin ("hide only"); with a 30 ms latency plugin on the AUX (`R > L + P`): one pass, nothing padded. Then the latency changed to 5 ms while laid: realigned after `checkLatencyAndRebuild`. A second sender to the same aux without mini-chain: its wet still aligned. |
| O3 | Order: envelope → plugins → level | Sine at -6 dBFS peak, `clipTester` ceiling -12 dBFS on the send, send level -6 dB: wet peak -18.0 ± 0.1 dB relative (the other order gives -12). Pre-fader send, 1 s fade-in, read where the envelope is -6 dB: -12 - 6 (level) relative, i.e. the clipper sees the FADED signal (the other order gives 6 dB less). Post-fader with fader 0 dB = pre-fader, to 0.05 dB, clipper laid. |
| G3 | Level, mute, solo, gate still give silence | Send at `-inf` with a `gainTester +24 dB` on it: wet `maxabs == 0`. Sender muted / silenced by another's solo / stem muted / parent group muted (Q-U1, Q-U12), at each position: wet `≤ 1e-6` after the 50 ms smoother. Send switched off: silence, and the plugins still answer `plugin.get_state`. |
| M3 | Materialisation | A new send (`-inf`): `plugin.add` on its host succeeds, `plugin.get_params` answers, `bridge_report` lists no reader for it. Level raised: one build, no new instance (state set before is read back). Level back to `-inf`, switch off, on: state intact each time. Send removed: `debug.plugin_id_audit` 0, no engine key left for its plugins. Object chain filled to its limit: a send with plugins refused `chainFull`, its plugins not instantiated, laid again when a slot frees. |
| X3 | Limits | The mini-chain accepts plugins up to its own limit (the number of probe a) while the object's chain is unchanged; the object's chain still takes 16 plugins + 1 send carrying N plugins. |
| U3 | Undo / redo | Add, remove, reorder, bypass, parameter change, move trunk → send, ⌥ copy (⌘ = the same plain copy): each one undo point, the wet measured before / after / undone / redone. A parameter undo on a send plugin does NOT rebuild the object (`debug` build counter unchanged). A curve on a send plugin's parameter: measured in the wet, survives undo of an unrelated gesture. |
| Z3 | Save / reopen | Save, `--no-recent` fresh instance, reopen: wet identical to 0.01 dB, states read back, ids unchanged, `"version": 23`, no `plugins` key on sends without plugins. A format-22 project of INC 2 (the Z2 fixture) reopened and re-saved: `items` identical. A 23 file with a block, a bin, a marker inside a send's `plugins` (hand-written): sanitised at load, logged, no crash, audit ok. |
| C3 | Copies | Duplicate, copy / paste, split of the sender, split of the aux, ⌥ drag: every copy has its mini-chain, NO shared id (`debug.plugin_id_audit` 0), each wet measured; a parameter changed on the original after a copy NEVER changes the copy's wet (send plugins are copied independent, whatever the gesture); the audit's `linked_send_plugins` stays empty. |
| R3 | Retarget and position | `send.retarget` to aux B: the plugins, their state, the level and the curve are on the new send; wet arrives in B and no longer in A; no instance re-created (state set through the editor door, not saved in the model, is still there). The send moved across the four positions: plugins kept, wet level per position as in INC 2's Q2 minus the plugin's gain. |
| T3 | Window and tails | A `latencyTester` used as a 200 ms delay on the send of an object ending at 1 s: the wet stops at the object's end (+ tail) — the documented rule of A.e, measured so that a change of it is seen. A cropped object: nothing is sent from outside its window, plugin laid. |
| B3 | Consolidate / bake | `input` send with a plugin, `mid_chain_sends: fold`: the placement's send is post-fader, carries the plugin, the wet is the baked signal through the plugin. `remove`: send, plugin and lanes gone, one undo restores the three. `pre_fader`: refused. Bake of a group whose child has a mini-chain, then un-bake: ids fresh, audit 0, wet as before. |
| K3 | Sidechain key inside a mini-chain (if kept, A.i) | `objKeyProbe` on the send: left = the sent signal, right = the key, aligned to the sample. |
| H3 | Addressing | Every `plugin.*` command of A.m on a send host; `send.list` gives `chain_host` and `plugins`; a block / bin / instrument refused with `send_chain_leaves_only`; an unknown host `not_found`. |

**Mutants** (by hand on the Debug build, source restored, `git diff` empty), three run:
- **A. the builder ignores `getTapChain()`** → A3 (2), L3, O3 fail; P3 stays green (it must — that
  is what shows the mutant hits the mini-chain only).
- **B. `registerTap` given `L` instead of `L + P`** → L3 fails by exactly `P` samples, A3 stays
  green.
- **C. `deepFreshCopy` / `derivedCopy` copy `sends` by value again** → `test_plugin_id_uniqueness`
  and C3 fail (shared ids).
- (D, optional: `processTapHead` called after the chain → O3's fade assertion fails.)

**Non-regression — each against its OWN fresh instance** (the list of C.4, plus what INC 2 added):

```sh
APP=<Debug>/objekat.app/Contents/MacOS/objekat
# audio ON (they exit 2 otherwise):
$APP --headless --api --no-recent --language=en --socket=/tmp/o.sock &
python3 tools/scenario_bridge_sends.py /tmp/o.sock /tmp/trial_sends            # everything, INC 1 + 2 + 3
python3 tools/scenario_bridge_latency.py /tmp/o.sock /tmp/trial/project.objekat
python3 tools/scenario_sidechain.py /tmp/o.sock /tmp/trial/project.objekat
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
# standalone Swift tests (compile line in each header):
tools/test_send_chain.swift  tools/test_send_position.swift  tools/test_send_bake_policy.swift
tools/test_send_drop.swift   tools/test_send_columns.swift   tools/test_send_target_menu.swift
tools/test_synoptic_send_cards.swift  tools/test_synoptic_fxblock.swift
tools/test_plugin_id_uniqueness.swift tools/test_cross_project_import.swift
```
The exact socket and project arguments are those of the INC 2 gate (D.1.F); a script whose
invocation differs from this list is run as ITS header says, and the difference is written in the
journal. Then `debug.plugin_id_audit` (0), `debug.send_marker_audit` (ok), the i18n audit (0), the
warning recount (0 new), and `CGWindowListCopyWindowInfo` on the headless pid (no window).
`scenario_cross_paste.py` and `scenario_plugin_selection.py` each gain one case with a mini-chain.

**What only a person verifies.**
- A low-pass on ONE object's send to a real reverb: the reverb darkens for that object only; the
  object's direct sound and the other senders' reverb do not move.
- The box: rows, "+", the picker's title, the insertion line while dragging, the three gestures
  (move, ⌥, ⌘) from the trunk to a send, from a send to the trunk, between two sends, between two
  objects (⌘ = a plain copy there, the banner saying "copy"); reorder; bypass; ⌫; ⌘C / ⌘V.
- An AU editor opened from a row, on a send at `-inf`, on a send switched off; closed and reopened.
- A compressor on a send while the send's level is ridden (Q-U17), a delay on a send at the
  object's end (Q-U18): is it what is wanted.
- Stacked boxes at neighbouring positions; a long plugin name; a greyed box.
- Play / stop / loop / seek with a latency plugin on a send: no click, the reverb in time.
- An old project (format 22) opened and saved; the same project reopened.
- The three languages.

### D.2.D Open questions for INC 3 (the user's) — see section E for the table

Only what is heard or seen and cannot be deduced. Each has the hypothesis the plan is built on, so
that work can start before the answers.

- **Q-U17** The send's LEVEL acts after the send's plugins (a compressor on the send is not driven
  by the send level; lowering the send lowers a delay's tail at once). Or before?
  *Hypothesis: after.* **ANSWERED 10 Oct: after.**
- **Q-U18** A reverb or a delay laid on a send stops with the object, like a plugin of its chain
  (to ring, the effect goes on the aux). Accepted? *Hypothesis: yes.* **ANSWERED 10 Oct: yes.**
- **Q-U19** The drawing: the send's card becomes a box, header on top (aux, level, switch), one row
  per plugin under it. Or the rows above the header (literal signal order)? *Hypothesis: header on
  top.* **ANSWERED 10 Oct: the other half — plugins on top, the header line at the bottom, the "+"
  after the last plugin (just above the level line); a send without plugins keeps today's card.**
- **Q-U8** (restated) "The same low-pass on every send to this reverb": v1 offers the ⌘ LINK
  between send plugins (and between a send plugin and any other of the same type); an FX link bin
  on a send is NOT in v1. Enough for v1? *Hypothesis: yes.* **SUPERSEDED on 10 October: NO link at
  all on a send's plugins, bin or ⌘ (D.2.A.i).**
- **Q-U8b** When an object is duplicated, cut or copy-pasted, its send plugins follow the same
  default as its chain's plugins (linked by default on cut / split / copy-paste). Or always
  independent on a send? *Hypothesis: same default as the chain.* **ANSWERED 10 October: ALWAYS
  INDEPENDENT on a send.**
- **Q-U9** A parallel block inside a send's plugins: not in v1 (series only). *Hypothesis: not in
  v1.*

Not asked, because given or deducible: retarget keeps the plugins; folding at consolidation keeps
them; deleting a send deletes them (undoable, no confirmation — a send is deleted today without
one); a send at `-inf` or switched off keeps its plugins loaded.

### D.2.E Risks, frankly

1. **The side input in a `TimedNode`** (A.c) is read, not run. Probe b decides at 3.0; the fallback
   (P6) is known and costs the dry's bit-exactness with a latency plugin, nothing else.
2. **The third root is the INC 2 marker problem again, larger**: ~20 families of sites, and a
   miss is SILENT (a state not saved, an id shared, an undo that rebuilds). The inventory and the
   "survives the transformation" tests are the only defence; the id audit catches the worst
   (shared ids) but not a lost state.
3. **The derived host id** makes a send host invisible to `find(id:)`. A site that takes a host and
   silently returns on nil will "work" by doing nothing. H3 calls every command; the UI paths are
   the eye's.
4. **The materialisation rule changes INC 1's invariant** "a dead send has no engine plugin": one
   more entry in the 20 for a switched-off send that carries plugins, and `commitBridgeSync`'s
   removal loop now has a precondition (purge). A miss = an AU destroyed with its editor open (the
   `~AudioProcessor` crash already met once in this project).
5. **Retarget in place** is new engine bookkeeping (`_bridgeSendMap` re-keyed); if probe d shows
   INC 2 removes and re-lays, the level's automation path must be re-checked after the change.
6. **An extra build pass on every export** when `L + P > R` (the cached age is not state). Counted
   by the scenario; if it weighs, the age can be seeded from the list's latency before the first
   pass — not planned.
7. **CPU**: a mini-chain is per sender. Twenty objects each with a low-pass on their send = twenty
   instances, each set on its own (no link on a send since 10 October). Sharing = a bin, not in v1.
8. **The sidecar of a consolidated object** may keep a second copy of the send plugins (probe c):
   harmless while cold, a duplicate id if anything ever reads it back beside the placement.
9. **Box heights** make the send column's layout variable; stacked boxes at neighbouring trunk
   positions can push each other far from their anchor. Pure tests cover overlap, not legibility.
10. **Not measurable headless**: every gesture of A.l, the editors, the picker. INC 2 had the same
    gap and it held; it is still a gap.

### D.2.F What the delivered code (INC 1 + INC 2 + the 10 October fix) leaves for INC 3

1. `duplicateSendsTarget(from:to:)` (`EditViewModel+Aux.swift:547`) rebuilds `AuxSend(auxID:
   levelDb:enabled:)` field by field: after an AUX split the senders' new send is POST-FADER
   whatever the original's position (an INC 2 gap, not covered by a test), and it would drop
   `plugins`. Fixed in 3.7; the position half could be fixed today, independently.
2. `isPatchable` (`+UndoRedo.swift:280`) neutralises only `tap` when it compares sends.
3. `deepFreshCopy.rebuild` (`+Bake.swift:158`) and `CrossProjectImport` (:286) copy `sends` by
   value — correct today, a duplicate-id factory the day `plugins` exists.
4. A dead send has no engine plugin, and a new send is dead (Q-U4) — hence A.g.
5. P6 and §A.2's INC 3 paragraph are superseded by A.d; §A.4's sketch of `plugins` stands.
6. `SendBakePolicy` looks at the object's OWN sends only; the children of a baked group are not
   inspected, neither for `chain` nor for `pre_fader` (the 10 October fix kept that). With
   mini-chains, a child's send plugins are baked away or lost with the child exactly like its
   sends are today — unchanged, but now it is plugins that silently go. Listed in B3.
7. A send at a level above `-inf` whose aux is silent still processes its copy; with a mini-chain
   it processes its plugins too. No change planned.
8. `pruneOrphanSends` removes sends in the model without scheduling a chain compile: with plugins
   on the pruned send, their engine instances would stay until the next compile. Step 3.7 makes it
   call the same door as `removeSend`.
9. §D.1.A.d says the list's cap is 45; the measured cap is 20 entries (D.1.F). The number that
   matters for a mini-chain is probe a's.
10. The compile line in the header of `tools/test_plugin_id_uniqueness.swift` is stale (to refresh
    when the test is extended in 3.3).

### D.2.G Journal of INC 3

**Start-up (10 October).** Branch `feature/sends-inc3-plugins` from `feature/sends-inc2-position`
(`2fc674e5`); fork branch `objekat-sends-0040` from `objekat-sends-0039` (`fb0ae39e631`). Plan
committed first (`e458e474`). The user's answers to Q-U17 / Q-U18 / Q-U19 arrived during 3.0 and are
written in sections A.l, D.2.D and E (`9073ec9a`): level after the plugins, the tail stops with the
object, and — different from the hypothesis — the box has its PLUGINS ON TOP and the level line at
the bottom.

**First fix, isolated (`7f4df032`) — D.2.F 1, the position half.** `duplicateSendsTarget` rebuilt the
send field by field: after the split of an aux, the senders' send to the new half was post-fader
whatever the original's position. Now a pure `SoundObject.duplicatingSend(from:to:)` (value copy, the
marker laid just after the original's) + `recompileForSendMarker`. `test_send_position` 118/118;
scenario section **I4** (aux split with the send at each of the four positions, `[gainTester -12]`,
fader -20): wet -12.000 / 0.000 / 0.000 / -32.000 dB re source in BOTH halves, audit clean; I + I4 =
39 OK. The "red before the fix" run was reasoned, not executed.

#### 3.0 — Preliminaries

**Reference run.** `scenario_bridge_sends.py`, complete, on the Debug build of `7f4df032`, headless,
audio ON (device at 96 kHz, exports at 48 kHz): **945 OK, 0 FAILED** in 12 min 30 s. Its 521 exports
are the P3 reference. Determinism checked on the way: the 25 exports of a second run of I / I4
against the reference are identical SAMPLE FOR SAMPLE (the files differ byte for byte — a header
field — so P3 compares samples, never bytes).

**Inventory, counts at `7f4df032`** (the plan's were taken at `2fc674e5`; differences noted):

| Family | Count (lines / files) | Plan said |
|---|---|---|
| `.instruments` | 56 / 19 | 56 / 19 |
| `.sends` | 84 / 28 | 85 / 28 (one line gone with the first fix) |
| `AuxSend(` | 2 / 1 (`+Aux.swift` 390, 425) | 3 (:553 is now the pure copy) |
| `chainPlugins(` | 82 / 15 | 82 / 15 |
| `updateChainPlugins(` | 36 / 7 | 36 / 7 |
| `forObjectID:` (Swift) | 29 / 8 | 42 / 10 — the plan counted the `.mm` declarations too |
| `flattenLeaves(` | 26 / 10 | 26 / 10 |
| `withCapturedPluginStates(` / `capturingPluginStates` | 26 / 6 | 21 / 6 |
| `copiedPlugins(of` | 25 / 6 | 25 / 6 |
| `linkGroupID` / `rewireLinkGroups` | 95 / 18 | 81 / 16 |

**Classification of the `.instruments` sites** (the template of the third root):

| Site | Concerned? | Why / what |
|---|---|---|
| `PluginIDUniqueness` 58, 165, 238; `PluginIDReport` 68 | YES | detection, path, repair, the report's legend |
| `SendMarkerAudit` 61 | YES | a marker inside a send's plugins is a defect to report |
| `CrossProjectImport` 278 (and the `sends` map at 286) | YES | cold clone, fresh ids |
| `SoundObject` 1160 (`derivedCopy` remap) | YES | the copy's automation follows the send plugins' new ids |
| `SoundObject` 936 (`resolvesAutomationTarget`) — NOT in the plan's list, found by reading | YES | a lane aimed at a send plugin resolves; but `automationTargetIsBakedIntoRender` must answer NO for it (a send is not rendered: the curve stays on the placement) |
| `SoundObject` 1098, 1261, 1306 | no | the `instruments` field itself (init, Codable) |
| `+Plugins` 50 (`collectPluginRefs`) | YES | editors / engine keys of the object |
| `+Plugins` 727 (`copiedPlugins`-side instrument copy), 889, 916 (`rewireLinkGroups`, link members) | YES | links and copies |
| `+Plugins` 928, 936 (plugin lookup / write by id on a host) | YES | through the send host |
| `+Plugins` 341–466 (instrument slot: set, clear, move) | no | the instrument slot only; a send's plugins are never an instrument |
| `+Automation` 116, 365; `+AutomationTargets` 161 | YES | targets list, push, lookup |
| `+UndoRedo` 272, 275, 403 | YES | `isPatchable`, `adoptingPluginStates`, `changedPluginStates` |
| `+Clipboard` 245 (`remappingSidechain`) and 232 (`sends` aux remap) | YES | a keyed send plugin follows the paste's id map |
| `+Bake` 157, 170 (`deepFreshCopy`) | YES | fresh ids + `pluginRemap` |
| `+Project` 613–614 (`capturingPluginStates` at save) | YES | or a save writes stale states |
| `+Bridge` 86, 280, 353–354 | YES | sidechain routes of a send plugin; host = sender |
| `+Consolidate` 658 (eligibility of a batch of identical clips) | YES (through `a.sends == b.sends`, 674) | two clips whose sends carry plugins are never "identical" (distinct ids): the batch falls back to the ordinary path — nothing to write, noted |
| `+ProjectLoad` 136, 368 (load weights and labels) | YES, weight only | send plugins count as plugin entries of the progress bar |
| `SynopticView` 2838, 3045–3051 (instrument card) | no | the instrument card |
| `SynopticView` 339, 3267, 3280 (plugin lookup for a selection / an editor) | YES | a row of a send box is selectable and opens its editor |
| `Commands+Plugins` 75; `Commands+Object` 68; `Commands+Runtime` 183 | YES | payloads and counts (A.m) |
| `Commands+Plugins` 1043, 1060 (instrument commands) | no | instrument-only commands |

**`.sends` sites that COPY** (the others read a level, a switch or a target and are not concerned):
`CrossProjectImport` 286; `SendPosition` 231 (`duplicatingSend`); `+Consolidate` 559–579 (clip →
wrapper: a MOVE, ids kept), 742 / 775 / 1076 (the placement takes `live.sends`: a move); `+Bake` 158
(`deepFreshCopy`: a COPY, fresh ids needed), 212 (`restoredSubtree`: takes the wrapper's, a move);
`+Clipboard` 232; `+UndoRedo` 280–283 (`isPatchable` neutralises `tap` only); `+SendPurge` 39–42
(removal: the plugins' lanes must go too); `SendBakePolicy` 63–103.

**The six probes.**

- **a. Entry limit of a `<BRANCH>` list owned by a clip: 20.** Run (throwaway hook, removed): a
  list built as `ObjParallelBlockPlugin` does (`setTrackAndClip (getOwnerTrack(), getOwnerClip())`)
  has BOTH owners set and accepted exactly 20 `gainTester`s, refused the 21st. The mini-chain's
  limit is 20, its own.
- **b. A non-summing two-input node inside a `TimedNode`: WORKS — no fallback, the hide design of
  A.d stands.** Run with the patch of A.b written for real (working tree, not yet committed) and a
  hand-built mini-chain laid by a throwaway hook on every new send, impulse at 1 s, send at -6 dB,
  the four positions × a 0 / 10 ms `latencyTester` on the sender's trunk:
  - `latencyTester 20 ms` in the mini-chain: the WHOLE export (dry + wet) is identical sample for
    sample to the export of the same project without the mini-chain (`maxabs == 0`, 8 cases), and
    so is the dry alone; wet peak at sample 48000 = dry peak; live graph (96 kHz): tap
    `age == L + P` (1920 with nothing upstream, 2880 with the 10 ms plugin upstream of the tap,
    1920 at `input` where the tap is before it), reader `aligned`, error 0, `passes == 1`,
    `converged`, `blocks_uncovered == 0`.
  - `gainTester -12 dB` in the mini-chain: wet -12.000 dB against the same project without it, at
    the 8 cases; dry `maxabs == 0`.
- **c. Consolidation and `sends` (read).** `ConsolidateDefinition` (the registry) keeps nothing of
  the sends. The SIDECAR does: it encodes the whole root through `asConsolidateDefinition`, which
  filters the automation only — so the root's sends, and tomorrow their plugins WITH THEIR IDS,
  would be written a second time. `restoredSubtree` discards them on reopening
  (`restored.sends = wrapper.sends`), but the HEADLESS RE-BAKE materialises the sidecar's subtree in
  the engine beside the live placement: a send plugin there would claim the same engine key as the
  placement's. `PluginIDUniqueness` deliberately does not walk sidecars. Consequence for 3.3:
  `asConsolidateDefinition` drops the ROOT's send plugins (they belong to the instance, like the
  root's own curves); the children's sends stay (they are content) and are freshened by
  `deepFreshCopy`.
- **d. INC 2's retarget reaches the engine by REMOVE + LAY** (read): `retargetSend` rewrites the
  model, then `syncSendEngine(old)` / `syncSendEngine(new)` / `scheduleBridgeSync`; the engine's
  registry is keyed `"sender|aux"`, so the old key is unconfirmed (removed by `commitBridgeSync`)
  and a new plugin is inserted (`ensureBridgeSend` returns 2, the curve is pushed again). With a
  mini-chain that would re-instantiate every plugin: the in-place re-key of A.h is needed.
- **e. An automation lane aimed at an unknown plugin id (read): kept, inert.** The decoder keeps
  every lane; nothing sanitises a `.plugin` lane at load (only `.send` lanes aimed at a deleted aux
  are purged); the encoder writes every lane that has points. `automationTouchOrder` alone is
  filtered by `resolvesAutomationTarget` at save. So a format-23 file saved by an older build loses
  the send plugins and keeps their curves as dead rows.
- **f. `objKeyProbe` in a wet branch: NOT hand-built at 3.0** — the key's route comes from the
  model (`bridgeTopology`), which a throwaway engine hook cannot feed. Deferred to the moment the
  third root exists in `bridgeTopology` (step 3.6), measured there as section K3 before the door is
  opened; refused in v1 if not aligned, as the plan says.

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
| Q-U5 | (INC 2) A mid-chain tap is before the object's fades: follow the fades anyway? | ANSWERED 9 Oct: YES, fades and window apply to the send at every position; volume and pan do not apply pre-fader. |
| Q-U6 | (INC 2) Bake / consolidate with an in-chain send. | ANSWERED 9 Oct: "ask the user". **To confirm:** is it an alert at the moment of the operation with fold to post-fader / delete the send / cancel? And for the API, which cannot ask: the plan REFUSES by default (`mid_chain_sends: refuse`) and takes `fold` / `remove` explicitly. A `pre_fader` send is not concerned (the baked wave is the pre-fader signal). **CONFIRMED (third round); and since 10 Oct a `pre_fader` send is no longer "not concerned": it makes the consolidation REFUSED (Q-U6b).** |
| Q-U7 | (INC 2) The card: where a post-fader send is drawn. | ANSWERED 9 Oct: every send is a card; post-fader = a card under the pan / volume zone; the foot zone disappears for outgoing sends. |
| Q-U12 | (INC 2) An object is MUTED (or silenced by another's solo, or by its stem's mute) and has a send taken BEFORE its fader. Mute is the fader today, so that send would keep feeding the reverb. Should it? | NO: a muted or solo-silenced object sends nothing, wherever the send is taken (consistent with Q-U1). Step 2.5, isolated. |
| Q-U13 | (INC 2) Consequence of Q-U7: the foot zone listed EVERY reachable aux as a row, send or not. With cards, only the sends that exist are drawn; the other auxes are reached through "Send to…". Acceptable? | Yes. (The Aux tool and the inspector still list all reachable auxes.) |
| Q-U14 | (INC 2) Where "Send to…" is reached in the signal view. | ANSWERED 10 Oct: accepted as built — the right-click on a "+" of the trunk (and the "+ Send to…" button of the column). |
| Q-U15 | (INC 2) A send exists but its aux no longer overlaps the object in time (or the send is refused by the scope). The foot zone used to hide a non-overlapping aux. | The card stays, greyed, with the reason; nothing disappears from the chain by moving an object. |
| Q-U16 | (INC 2) "Change target…" on a card (same position, level and automation, another aux): in INC 2, or delete-and-recreate is enough? | In INC 2 (card menu + `send.retarget`), droppable without consequence. |
| Q-U8 | (INC 3) "The same low-pass on every send to this reverb" as one setting. | ANSWERED 10 Oct: NO link of any kind on a send's plugins — no bin, no ⌘ link (the FX links are meant to go eventually). ⌘-dragging to or from a send is a plain copy. |
| Q-U8b | (INC 3) Duplicating / cutting / copy-pasting an object: are its send plugins linked to the original's by default? | ANSWERED 10 Oct: NO — always independent copies (fresh ids, state copied, no link), unlike the chain's default, which is unchanged. |
| Q-U9 | (INC 3) A parallel block inside a send's plugins. | Not in v1: series only. |
| Q-U17 | (INC 3) The send's LEVEL acts after the send's plugins or before? Inaudible for a filter; audible for a compressor / saturator (driven or not by the send level) and for a delay (its tail drops at once or not). | ANSWERED 10 Oct: AFTER the plugins (D.2.A.a), as planned. |
| Q-U18 | (INC 3) A reverb / delay laid ON a send stops with the object, like a plugin of its chain (to ring, the effect goes on the aux). Accepted? | ANSWERED 10 Oct: YES, the tail stops with the object (D.2.A.e), as planned. |
| Q-U19 | (INC 3) The send's card becomes a box: header (aux, level, switch) on top, one row per plugin under it — or the rows above the header (literal signal order)? | ANSWERED 10 Oct, DIFFERENT from the plan's hypothesis: the PLUGINS are ON TOP and the header line (aux, level, on/off) is AT THE BOTTOM — the literal order of the signal. The "+" stays after the last plugin, i.e. just above the level line. A send without plugins keeps today's card. The wire to the tap point and the drop zones follow that orientation (D.2.A.l, revised). |
| Q-U10 | Two groups each sending into an aux of the other is refused (a scheduling loop, no signal loop). Acceptable, with the reason shown? | ANSWERED 9 Oct: accepted, reason shown. |
| Q-U11 | A stem DETACHED from the Main still feeds a Main aux today (unchanged by this plan). Wanted? | ANSWERED 9 Oct: unchanged. |

## Settled by this plan (reversible, listed so they can be contested)

P1–P9 above (P6 revised by D.2.A.d); for INC 3, the list of D.2.A.o; the wet is measured by difference; the legacy path survives INC 1 only; the hand's
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

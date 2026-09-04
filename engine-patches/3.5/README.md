# Engine patches — the tracktion 3.5 base

This is the **live** series: `main` has been running on it since 2026-08-08. The app is on
**tracktion 3.5.0** (`origin/develop` of the official repository, base `494e91d2ff5`) and JUCE
**8.0.13** (`37c894f`). It is also the ONLY series this repository carries: the four archives
of the abandoned 3.2 base left on 2026-09-04, when the repository was opened — they insured
nothing but the local branch `sav-moteur-en-pistes`, which is published nowhere. They were not
destroyed: they sit, with the engine branch they rebuild, in `objekat-archive-3.2/` beside the
repository on the author's machine.

The submodule pointer is tracked by git, so:

```sh
git checkout main && git submodule update --init --recursive
```

is enough to switch the engine, **including on a fresh clone** — since 3 September 2026. The
submodule points at the fork `nicolasvair/tracktion_engine_for_objekat`, which carries the
`objekat-patches-3.5` branch; `modules/juce` stays on the official `37c894f83d3`, public at
juce-framework.

Until that day the gitlink named a branch pushed nowhere, and a third-party clone got
`upload-pack: not our ref` — these archives were then the only way in. They are now a **safety
net**: what makes it possible to reconstitute the engine if a fork moves, is renamed or goes
private. `tools/rebuild-engine.sh` automates the "from scratch" procedure below, and
`tools/publish-engine-forks.sh` republishes the result.

## Contents

The 3.5 ports of the three performance patches of the old 3.2 branch (its `0003`, `0004` and
`0005`, now in the archive outside this repository).
Checked as still biting: `develop` still had the linear `std::find`.

- `0001` — removes two N²s in the rebuilding of the graph (`VisitedNodes` with a
  hash set, `findNodeWithID` through `equal_range`), a real shock absorber on
  `restartPlayback`, plus the `OBJ_GRAPH_PROFILE` probe.
- `0002` — a 120 ms damper and an `OBJ_GRAPH_CENSUS` count of the nodes by type.
- `0003` — removes the useless `LiveMidiOutputNode` / `LiveMidiInjectingNode` (~18% of the graph).
- `0004` — **set aside**, see `pending/`: froze the JUCE pin on the patched JUCE. It existed
  only to record `0010`.
- `0005` — switches `USE_DYNAMIC_OFFSET_CONTAINER_CLIP` to 0 (step 1) and makes it overridable
  from the build settings.
- `0006` — `ContainerClipNode::getInternalNodes()` returns `{}`: the enclosing graph kept
  in `sortedNodes` raw pointers to nodes belonging to the container's local
  graph. A crash on grouping (`EXC_BAD_ACCESS` in `findNode`).
- `0007` — the container's internal PDC through reading ahead (phase 1 of step 2). The content
  is read `L` samples early, `getHead()`/`getTail()` widen the activation window,
  `LatencyMaskingNode` declares 0 towards the outside and `Clip::compensatesOwnPluginLatency()`
  takes those clips out of the `clipsHaveLatency` test. Without this, a single latency plugin on a group
  made the whole track fall back on a `SummingNode` processed continuously.
- `0008` — fixes `0007`, which cut the group's first `L` milliseconds off.
  `PluginNode` moves the edit time back by the upstream latency; that no longer holds inside a container
  that reads ahead, where the material of block `t` belongs to `t + L - Lc`.
  `setReadAheadNumSamples` restores that time — indispensable as soon as a plugin uses
  `PluginRenderContext::editTime` as a gate. It also replaces `LatencyMaskingNode`
  (inserted into a `TimedNode` chain, where `numOutputNodes` is `-1`: an invalid buffer share,
  and a node seen by two schedulers) with an `ignoreLatency` flag on
  `CombiningNode::addInput`.
- `0009` — `CombiningNode::TimedNode` accepts branching chains: a de-duplicated post-order DFS
  instead of the linear descent (`assert (inputNodes.size() == 1)`), readiness over every
  leaf, and a buffer of its own for each node when the chain branches — the single shared
  buffer is only valid in series. A prerequisite for the parallel plugin block (step 2b).
- `0010` — **set aside**, see `pending/`: the only JUCE patch, removing the
  `jassert (factory != nullptr)` from the VST3 scan.
- `0031` — names juce over **HTTPS** in tracktion's own `.gitmodules`, which inherited
  `git@github.com:` from upstream. Without it a `git clone --recurse-submodules` gets
  tracktion from the fork and then fails on juce, for want of an SSH key. Same repository,
  same commit — only the way of naming it changes.
- `0011` — unfolding a parallel plugin block: a `ParallelPluginBlock` interface,
  expansion into `SummingNode { branch… }` with fan-out through `ConnectedNode`, latency = the longest
  branch. Completes `0009` by transforming a `TimedNode`'s chain when it
  branches, without which `SummingNode::createLatencyNodes()` would never run. The code moved from
  `juce_audio_processors/format_types/juce_VST3PluginFormat.cpp` to
  `juce_audio_processors_headless/format_types/juce_VST3PluginFormatImpl.h`.
- `0012` — fixes `0009`: the branching path left each node to allocate its buffer, but
  `NodePlayer` **adds into** them and ~15 types declare `ClearBuffers::no` counting on the
  `CombiningNode` to clear. Nobody cleared any more → accumulation block after block, feedback
  as soon as a parallel branch appeared. The `TimedNode` owns and clears those buffers.
- `0013` — removes the fallback to a `SummingNode` when a clip has latency, which took
  the whole lane out of the `CombiningNode` (hence out of lazy processing) for a single clip. Replaced
  by: `Clip::getHead/getTail` generalised (an L pre-roll, a 2L tail, what `ContainerClip`
  already did), latency declared normally + a global PDC, and the inputs equalised against
  one another by `LatencyNode` in `createNodeForClips`.
- `0014` — completes `0013`: purging a latency FIFO is not silent, what gets chased out of it
  is the tail of the previous activation and it came out during the pre-roll, hence **before** the
  clip (audible when replaying the same place twice). The pre-roll is set to zero up to
  "start + the latency reported to the outside" by a `FadeInOutNode` with empty fades.
- `0015` — fixes `0014`: that gag was set on a **position** in the Edit, so it
  struck at every turn of the loop and the start of the loop went silent. The tail
  held in the FIFOs is not always illegitimate — at a loop's join it *is*
  what should be heard. The criterion becomes **continuity**: `LatencyPrimingNode` counts
  the samples processed without interruption and only gags the first N that follow
  a non-contiguous resumption. Looping is not one.
- `0016` — on a transport loop (in/out), the `ContainerClipNode` realigned its local playhead
  with `setPosition()`, hence with a `userInteraction()`: the internal `WaveNode`s saw a
  jump and purged their readers, silence + a fade exactly at the start of the loop, at every
  turn. `isContiguousWithPreviousBlock()` is false on a loop although nothing has jumped — the
  correct criterion is `didPlayheadJump()`.
- `0017` — **undoes the reading ahead of `0007`/`0008`.** Reading `L` early assumes having
  run `L` before the group; on coming back from a loop whose IN falls on the start of the group,
  that run-up does not exist and the first `L` milliseconds were missing at every turn. Reading
  ahead served only to have the container report a null latency so as to escape
  `clipsHaveLatency`, removed in `0013`: the container now declares its latency like any
  clip. `PluginNode::setReadAheadNumSamples` and the `ContainerClipNode` parameter stay in
  place but are no longer used.

- `0018` — the `jassert` of `PluginList::initialise` enumerates the legitimate hosts of a
  plugin chain (tracks, clips, master); since `0011` a branch of a parallel
  block is one too, its chain living in a `<BRANCH>` child of the plugin's
  state. So every creation of a parallel block broke in the debugger in Debug,
  although the path is right. The tag becomes a declaration of the interface
  (`ParallelPluginBlock::branchTreeType`) instead of a literal copied out on either
  side of the app/engine boundary.

- `0019` — an aux bus INTERNAL to a `ContainerClip`. A child marked `objAuxBus` is no longer
  a source: `createNodeForContainerClip` takes it out of its siblings' `CombiningNode` and
  substitutes a return branch for it — `ObjAuxReturnNode` (the sum of the send taps) → the aux's FX
  → its fades — summed with the dry output through a `SummingNode`. The return declares the
  `CombiningNode` as a DIRECT INPUT although it consumes none of its audio: that edge alone
  guarantees that the sends have written before they are read (two siblings of a `SummingNode`
  have no relative order). The send is a PLUGIN (a `ContainerAuxSend` interface) and not a
  node, because `CombiningNode::getInternalNodes()` exposes to the enclosing graph every
  node of the clip chains — the trap that had killed `LatencyMaskingNode`. Scope:
  the sender and the aux being DIRECT children of the same container; the container is a graph
  boundary and nothing crosses it.

- `0020` — the same arrangement, but for **top-level** auxes, grafted at the ROOT of the Edit:
  above the sum of the tracks, just before the master chain. Why there and not track by
  track: "a lane = a track", so a top-level sender and the aux it aims at are on different
  `AudioTrack`s — depending on each sending track would take a fan-out per track
  and would open cycles (lane 3 → the lane 0 aux while lane 0 → the lane 3 aux, whereupon
  `areThereAnyCycles` asserts). Depending on the sum of the tracks makes cycles impossible by
  construction. `createAuxReturns` is factored out between the two levels, and now looks for the
  sends in `PluginList`s rather than in clips (at the top level, a MIDI clip's chain
  lives on its dedicated track). A restricted render (baking an object) has no returns.
  **An accepted cost:** a top-level return is scheduled on every block — one cost per top-level
  aux, not per group. It cannot be gated inside a `TimedNode`: that chain is
  not scheduled by the enclosing graph although it is exposed to it (the
  `LatencyMaskingNode` trap), and a sleeping return would stop consuming the taps (the `0014` trap).

- `0021` — a `ContainerClip` can host **MIDI**. `canContainMIDI` refused it whereas
  `canContainAudio`, just below, accepts it: that was the only lock. Everything else was
  already there — `createNodeForClip` dispatches `MidiClip` from the container's INTERNAL
  `CombiningNode`, and `ContainerClipNode::process` passes `pc.buffers.midi` to its local player, so the
  MIDI comes out and crosses the container's plugin list, where the app lays the virtual instrument at
  index 0. An Objekat MIDI object thus becomes an object like any other (chain, window,
  fades, lane, group, aux, bake, sharing) instead of a dedicated `AudioTrack` — and above all it can
  ENTER a group's container, which repairs a bake that lost the MIDI in silence.
  With: a null guard on `MidiClip::scaleVerticallyToFit` (no carrying track inside a
  container) and an update of the comment on `createTopLevelAuxReturns`, which invoked "a
  MIDI clip's dedicated track" — it no longer exists on the app side.

- `0022` — **PDC alignment of the send taps.** A tap is taken in the MIDDLE of the graph (the end of
  its sender's chain) whereas all the latency equalisation happens downstream: the
  padding that brings the clips of a lane into agreement with one another, then the `SummingNode`'s
  `LatencyNode`s. So the wet copy lacked that delay, and by an amount *different per
  sender* — a sender with 1000 samples of latency came out 1000 samples behind
  its own dry, while its neighbour with no plugin landed right. The rule of the fix: delay tap
  `i` by `reference − tapLatency_i` and **declare** `reference` (= the latency of the content node
  the return will be summed with); it is enough for `tapLatency_i + delay_i` to equal the declared
  latency for the downstream equalisation to land right. `createPluginNodeForList` reads
  `tapLatency_i` off the send's input node — the graph's number, not a reconstruction
  on the model side. `ObjAuxReturnNode` carries a circular delay line per send (allocated
  only if the delay is non-null, and which advances on every block even with no tap), and now
  reads the bounds of the aux's window off the age of the MATERIAL.

- `0023` — **lane equalisation on NODE latencies.** The same family as `0022`, the same broken
  criterion, elsewhere. `createNodeForClips` computed `laneLatency` and its padding with
  `Clip::getPluginLatencySeconds()`, which counts only THE CLIP's plugin list — exact as long as a
  clip was only a source and its chain, wrong ever since a `ContainerClip` also declares the
  latency of its CONTENT (`ContainerClipNode::nodeProperties = input->getNodeProperties()`, and
  nothing overrides `getPluginLatencySeconds()` for it). A group carrying a latency plugin
  was therefore not equalised with its track siblings, although the `CombiningNode` reported the REAL
  max: it is the sibling WITHOUT latency that came out early by that latency (1000 samples
  ≈ 21 ms at 48 kHz). The nodes are now built first, `laneLatency` is the max of their
  `latencyNumSamples`, and each branch is padded by `lane − its own node latency` —
  the node is the single source of truth, and it is the node that delays. The priming follows (after
  padding, every branch that is not self-compensated delays by exactly `lane`), and the
  special "a single clip" path, identical to the general case, disappears.

- `0024` — **a stem's aux buses are mounted INSIDE its submix folder.** `0020` grafted every
  top-level return at the root, above the sum of ALL the tracks — hence above the
  submix `FolderTrack`s. The wet of an object assigned to a stem came out outside that stem:
  absent from its meter and from its bounce, and above all deaf to its mute and to its "to the Main"
  (cutting the bus let through the reverb of the objects it held). "Σ stems = mix" became
  false as soon as one send existed. A return's mounting level is now that of the bus that
  carries the aux: `createNodeForSubmixTrack` grafts the returns of the auxes of ITS sub-tree onto the
  sum of its child tracks, upstream of the folder's chain, of its meter and of its
  `TrackMutingNode`; `createTopLevelAuxReturns` now sees only the tracks with no submix ancestor.
  It is the exact transposition of what a container does for its internal auxes. The scheduling
  constraint follows the same move — the return depends on the sum of the tracks of ITS
  folder, so only the senders of that folder are guaranteed upstream: the scope of a top-level
  send becomes "the same stem", which the app enforces on both sides
  (`canRouteSend` / `-isSend:routableToAux:`). As at the root, depending on a sum makes
  cycles impossible by construction.
- `0025` — **an aux at the root recruits its senders from the stems.** The "same stem" of
  `0024` forbade a single reverb shared by several stems, a common case. An aux's level
  does not move — it stays its folder — but its recruitment reaches down:
  `createTopLevelAuxReturns` gathers the senders across the whole Edit and keeps as auxes only
  those of the root tracks. This is the graph's asymmetry and not a favour: a stem's submix
  folder is one of the inputs of the sum that return depends on (`createNodeForEdit` pushes it
  into the output device's vector, and even detached from the Main it enters it wrapped in a
  `SinkNode`), so everything that lives inside a stem is upstream by construction. The reverse stays
  impossible — a sender at the root is not upstream of the sum of a stem's child tracks,
  and two sibling stems cannot see each other: `createSubmixAuxReturns` still counts only
  its own tracks. The PDC has nothing to add (`0022` aligns on the reference latency, which
  the downstream equalisation makes land right whatever the crossing). An accepted cost:
  the wet leaves the sender's stem, so "Σ stems = mix" assumes the Main is delivered as a
  stem.
- `0026` — **the container clears its output MIDI buffer.** The same family as `0012`, on the MIDI
  side. `ContainerClipNode` declares `ClearBuffers::no`, which exempts `Node::process` from clearing
  BOTH of the node's buffers — audio *and* midi — and `midiBuffer` is a MEMBER of the node, persisting from one
  block to the next. The "somebody else clears" contract was honoured for the audio only: the
  `CombiningNode` does `tempAudioBuffer.clear()`, the `TimedNode` of `0012` clears its `ownedBuffers`;
  neither touches the MIDI. Yet the local player only **adds** into it
  (`NodePlayer`: `pc.buffers.midi.mergeFrom`). So the previous block's messages stayed in
  place with their timestamp — sitting in `[0, block size)`, hence always valid — and
  left again on the next block: the instrument laid at the head of the container's plugin list received
  the same note-on on **every** block (~90/s at 512 samples), the list grew without bound
  (O(N²) in messages), the voices piled up and it saturated. The clearing is done **before** the window
  guard, otherwise a block outside the window — which returns writing nothing — would re-emit the last block
  played (the pending-tap trap of `0014`). Scope: one single `clear()` at the head of
  `ContainerClipNode::process`, nothing else is touched. The bug is as old as the node but
  is only audible since `0021` — before, no container produced MIDI and its `midiBuffer`
  stayed empty; so it strikes every MIDI object, inside a group or not, since it is the same node
  in both cases. An alternative set aside: putting the node back on `ClearBuffers::yes`, which would also cover
  an arrangement outside a `CombiningNode` but would pay a redundant audio `clear()` on every block —
  and `createNodeForClips` always returns a `CombiningNode`, so the non-combiner arrangement does not
  exist.

- `0027` — **`findClipForID` descends into nested containers.** The function promises "the
  clip of this ID if it is in the Edit" but only descended ONE level: it sweeps the
  `ContainerClip`s laid DIRECTLY on the track (`getTrackItemsOfType` does not recurse), then
  delegated to the `findClipForID (ClipOwner&, EditItemID)` overload, flat as well. Depth
  0 and 1: found; depth ≥ 2: `nullptr`, silently — the caller loses the clip's
  properties without anything failing. Yet two groups grouped into a third put the clips at
  depth 2. `Plugin::getOwnerClip()` is the most exposed consumer (it delegates
  straight here): `ObjGainPlugin` no longer saw the channel configuration of the carrying clip there,
  `sourceIsMono` stayed false, and a mono file never went to the right — the symptom "my
  mono samples go to the left when I group two groups". `createNodeForPlugin` likewise loses
  its `maxNumChannels` ceiling there. A local recursive helper, a short circuit at the first match, a
  descent on `dynamic_cast<ClipOwner*>` to follow the idiom of `getClipsOfTypeRecursive`. The
  `ClipOwner&` overload is NOT touched: its documentation says "if the ClipOwner contains it", and its
  callers do ask that question. **Still affected by the same defect**, not fixed for want
  of being able to measure the effects: `visitAllTrackItems` (hence `findClipForState (const Edit&,
  ValueTree)`, which derives from it) and `containsClip`.
  On the app side, the workaround laid in `ObjGainPlugin::initialise` (reading the channel count off
  the graph) stays in place and keeps its value: it is reliable at any depth and depends
  on no engine patch.

- `0028` — **the tempo remap descends into nested containers.** The same defect as `0027`,
  elsewhere: `EditTimecodeRemapperSnapshot::savePreChangeState` takes the snapshot in beats of
  everything that will have to move, but only descended ONE level into the container clips. The
  direct children of a group entered it, those of a sub-group did not — and a clip absent from
  the snapshot is never repositioned by `remapEdit`. The symptom: in bpm grid mode,
  changing the tempo realigned everything EXCEPT the clips of a sub-group, which kept their earlier
  seconds. The descent made recursive (`addClipTree`), over the track clips as over those of the
  clip slots.

- `0029` — **an aux purges its tail when its blocks no longer follow one another.** An aux's FX live
  in the INTERNAL graph of the `ContainerClip` that hosts it (`createAuxReturns` grafts the branch
  above the children's `CombiningNode`), and that graph is only processed within the container's
  window. Outside the window an aux's reverb does not decay: it FREEZES, and starts again as it was at
  the next reactivation. In a loop, with a group shorter than the loop, the previous turn's tail was
  heard again on the next. `ObjAuxReturnNode` now holds the list of the plugins
  of its aux's chain and `reset()`s them as soon as the end of the last block processed no longer coincides
  with the start of the current block — one single test for three discontinuities: looping, a transport
  jump, leaving the window. Neutralised when stopped, where the transport replays the same slice of
  time block after block.
- `0030` — **disarming the local playhead's loop when the range becomes empty.**
  `ContainerClipNode::process` only knew how to ARM (`if (! loopRangeSamples.isEmpty() && …)
  setLoopRange (true, …)`); an empty range — the way the model says "no more loop" —
  triggered nothing. Of no consequence if the playhead died with the graph, but it belongs
  to the `PlayerContext` that `prepareToPlay` takes over from the previous graph for continuity: it
  SURVIVES rebuilds. Cutting a group's loop did rebuild the graph and did lay
  `ContainerClip::setLoopRange({})` again, and the container went on folding — in a
  loop until the app was restarted. An `else if (localPlayHead.isLooping())` restores the
  symmetry: what arms disarms.

**Not carried over:** the 3.2 series' `0002-wavenode-dynamic-offset-time-for-varispeed` (in the
archive outside this repository, its only copy) and the commit
"A dynamic time offset for clips in nested groups". They serve only the
`DynamicOffsetNode` path, which this branch abandons in favour of `ContainerClipNode`
(step 1). `develop` has its own `setDynamicOffsetBeats` anyway.

## Rebuilding the engine branch from scratch

The series is a **history**, not a set of independent fixes: it applies
whole and in order. Several patches undo or fix an earlier one
(`0017` undoes `0007`/`0008`, `0015` fixes `0014`, `0012` fixes `0009`); skipping
one does not give an engine missing that feature, it simply does not apply.

**Every patch in the active series is tracktion.** The only two that touched juce, `0004` and
`0010`, were set aside on 3 September 2026 — see `pending/README.md` for what they did and what
it costs to be without them. There is therefore only one repository to rebuild, and `modules/juce`
simply stays on the commit the base already pins.

```sh
# the pinned base (develop at 2026-08-08) + the whole active series
git -C tracktion_engine checkout -b objekat-patches-3.5 494e91d2ff5
git -C tracktion_engine am --keep-cr $(ls engine-patches/3.5/0*.patch | sed 's|^|../|')
```

**`--keep-cr` is belt and braces, not a requirement — since 3 September 2026.** The option
protects the CRs of CRLF sources: without it, the `mailinfo` of `git am` strips them from the
body of the patch, which then stops matching the file, and you get a `patch does not apply` on a
patch that is perfectly sound (`git apply` accepts it, for its part, which makes the diagnosis
confusing). Only the JUCE sources were in that case, and `0010` was the only patch to touch
them. Verified on the active series: the 28 patches apply with **and without** the option. It is
kept anyway, so that putting `0010` back does not silently break the procedure.

The other snag on a fresh clone **used to be** the tracktion `.gitmodules`, which named juce as
`git@github.com:juce-framework/JUCE.git`, over SSH — needing a key registered on GitHub. That
broke a plain `git clone --recurse-submodules` one level down, and `tools/rebuild-engine.sh`
only papered over it (it rewrites URLs at rebuild time, `--ssh` to stop it) — a recursive clone
does not go through the script. Patch `0031` settles it in the branch itself: juce is named over
HTTPS, same repository, same commit.

Verification: `git -C tracktion_engine log --oneline 494e91d2ff5..HEAD | wc -l`
must give as many as there are archives in the active series — today **29**. That number moves
with every patch added and with every one set aside; `ls engine-patches/3.5/0*.patch | wc -l`
says it without getting it wrong.

There is **no gitlink to realign any more**: with `0004` set aside, `modules/juce` stays on the
commit the base pins, `37c894f83d379179b2070d437ccd0f1cd9af9576`, which is public at
juce-framework. That was the whole point of taking those two patches out — see `pending/README.md`.

What has not changed is that the tracktion HEAD obtained cannot equal `main`'s gitlink:

```sh
git -C tracktion_engine rev-parse HEAD   # DIFFERENT from main's gitlink, that is normal
```

`git am` remakes the commits with a different committer and a different date, so the SHAs are
necessarily other than the original machine's.

The submodule will therefore stay "modified" in `git status`. Do not commit that change, and
above all **never run `git submodule update` again**: it would go back to the original commit,
unfindable on any server, and would lose the rebuilt branch.

### After a new engine commit

Regenerate the archive and add it to the series, otherwise the commit exists only in the
local submodule and disappears at the first `git submodule update`:

```sh
git -C tracktion_engine format-patch -1 --start-number <N> -o ../engine-patches/3.5
```

## On the Xcode project side

JUCE 8.0.13 forces three adaptations, already committed on this branch:

- the `juce_audio_processors_headless` module (new, and `juce_audio_processors` depends on it) →
  `objekat/JUCEModules/juce_audio_processors_headless_impl.mm`;
- `juce_gui_basics` split into 5 compilation units →
  `juce_gui_basics_{2,3,4,5}_impl.mm`;
- the VST3 SDK followed the headless module → the path added to `HEADER_SEARCH_PATHS`
  (the old one is kept, so that the project stays valid on both versions).

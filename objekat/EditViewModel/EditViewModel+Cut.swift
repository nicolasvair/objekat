import Foundation

extension EditViewModel {

    // MARK: - The source offsets of a cut

    /// The source offsets of the two halves of a clip cut at `splitTime` (absolute time). Each
    /// half is a trim of the original window — hence the same reverse mirroring as a trim:
    /// played forwards the left keeps the offset and the right advances, in reverse it is the opposite
    /// (@see WaveformShaping.retrimmedSourceOffset). Without this, cutting a reversed clip made
    /// the content of both pieces jump.
    func splitSourceOffsets(of clip: SoundObject, at splitTime: Double) -> (left: Double, right: Double) {
        let s = clip.startTime, d = clip.duration
        let so = clip.sourceOffset, sr = clip.speedRatio, rev = clip.isReversed
        return (WaveformShaping.retrimmedSourceOffset(so, oldStart: s, oldDuration: d,
                                                      newStart: s, newDuration: splitTime - s,
                                                      speedRatio: sr, isReversed: rev),
                WaveformShaping.retrimmedSourceOffset(so, oldStart: s, oldDuration: d,
                                                      newStart: splitTime, newDuration: s + d - splitTime,
                                                      speedRatio: sr, isReversed: rev))
    }

    // MARK: - Splitting the MIDI notes

    /// Distributes the notes of a MIDI clip either side of `splitBeat` (beats relative to the
    /// start of the clip): left = the notes starting before the bound, TRUNCATED at the bound;
    /// right = the notes starting at/after the bound, REBASED to 0 (fresh ids — note ids
    /// have to stay unique across every clip, see `selectedMidiNoteIDs`). The DAW
    /// convention: a note straddling the bound belongs to the left half, and its tail is not re-triggered
    /// on the right. Used by the note-aware split/truncation (the same behaviour as audio clips).
    static func splitMidiNotes(_ notes: [MidiNote], atBeat splitBeat: Double)
        -> (left: [MidiNote], right: [MidiNote]) {
        var left: [MidiNote] = [], right: [MidiNote] = []
        for n in notes {
            if n.startBeat < splitBeat {
                var ln = n
                ln.lengthBeats = min(n.lengthBeats, max(0.01, splitBeat - n.startBeat))
                left.append(ln)
            } else {
                right.append(MidiNote(pitch: n.pitch,
                                      startBeat: n.startBeat - splitBeat,
                                      lengthBeats: n.lengthBeats,
                                      velocity: n.velocity))
            }
        }
        return (left, right)
    }

    /// Converting timeline seconds → beats at the current tempo (MIDI clips = beats-based).
    func beatsFromSeconds(_ secs: Double) -> Double {
        secs * (engine?.getTempo() ?? 120) / 60.0
    }

    // MARK: - Scissors (split)

    func split(id: UUID, atTime splitTime: Double) {
        cut(ids: [id], atTime: splitTime, keeping: nil)
    }

    /// Cuts ONE OR SEVERAL objects at the same instant. `keeping == nil` = a plain division (both
    /// halves stay); otherwise the opposite half is deleted — that is the Cut tool's "cut by
    /// pulling" gesture (pulling right keeps the left, and vice versa).
    ///
    /// A cut does not re-aim the selection: the selection follows the MATTER. An object that was
    /// not selected has none of its pieces selected afterwards — a cut is not a pick. An object
    /// that WAS selected hands its selection to whichever piece survives it; when BOTH pieces
    /// survive (a plain division), it goes to the SHORTER one — a cut is most often made to throw
    /// a small scrap away (a breath, a click, a count-in), and pre-selecting that scrap saves the
    /// click that would otherwise follow. Ties go LEFT, which costs nothing: the left half always
    /// keeps the object's own id (@see `_splitInternal`), so the selection simply does not move.
    /// An object cut but never selected in the first place is left alone throughout. The actual
    /// side is decided by `cutSelectionSide` (`Shared/CutSelection.swift`), which is the whole
    /// reason that unit exists on its own — asserted with no screen, no model behind it.
    ///
    /// Returns the pieces the cut produced (both halves of a division, or the one survivor of an
    /// oriented cut) — NOT the selection, which may differ or may be untouched. A caller that
    /// wants to know what came out of the matter (@see `object.split_at`) needs that, independently
    /// of what the eye is watching.
    @discardableResult
    func cut(ids: [UUID], atTime splitTime: Double, keeping: CutKeepSide?) -> Set<UUID> {
        guard !ids.isEmpty else { return [] }
        pushUndo()
        // The crossfades the cut objects are in, noted while they still stand — and this one
        // cannot simply be wrapped like a move (@see withCrossfadeRefit), because a split hands
        // the seam to a fragment that did not exist a moment ago.
        //
        // A zone is made of two EDGES: the left object's right edge, the right object's left one.
        // Splitting the LEFT member gives its right edge to the new half, so the pair is renamed
        // as the cut goes; splitting the RIGHT member leaves its left edge with the old id, so
        // there is nothing to rename. Then the geometry decides as usual — cut far from the zone
        // and the crossfade simply follows onto the fragment that carries it; cut THROUGH it and
        // the two are no longer side by side, so the fades go.
        var pairs = crossfadePairs(around: Set(ids))
        var result: Set<UUID> = []
        for id in ids {
            // An object already carried off by the cut of an ancestor no longer exists: it is skipped.
            guard let before = find(id: id) else { continue }
            // Read BRUT, before the split touches anything — the rule is about what the eye sees
            // in surbrillance at the moment of the cut, not about what remains reachable after.
            let wasSelected = selectedIDs.contains(id)
            // The fade-out the left half is OWED if the right one is about to be thrown away.
            // A split gives the fade to the right piece and leaves the left with none, which is
            // right for a division — but 'keep the left' is not a division, it is the END being
            // deleted, and there the fade stays, ending earlier (@see fadeOutAnchoredAtStart).
            // Its SHAPE comes back with it: the split clears both on the edge it opens (@see
            // freshCutCurve) and here the edge is not a new one — it is the object's own end,
            // arriving earlier, and a fade that keeps its length keeps its curve.
            let keptFadeOut = EditViewModel.fadeOutAnchoredAtStart(
                oldDuration: before.duration, oldFadeOut: before.fadeOut,
                newDuration: splitTime - before.startTime)
            let keptFadeOutCurve = before.fadeOutCurve
            guard let newID = _splitInternal(id: id, atTime: splitTime) else { continue }
            pairs = pairs.map {
                $0.left == id ? CrossfadePair(left: newID, right: $0.right) : $0
            }
            switch keeping {
            case nil:      result.formUnion([id, newID])
            case .left?:   remove(id: newID)
                           if keptFadeOut > 0 {
                               updateFadeOut(id: id, fadeOut: keptFadeOut)
                               updateFadeCurve(id: id, fadeOut: keptFadeOutCurve)
                           }
                           result.insert(id)
            case .right?:  remove(id: id);    result.insert(newID)
            }
            // The selection follows the matter, and only for an object it was already watching.
            // The `.left` case writes NOTHING: the left half already carries the id `selectedIDs`
            // names, so touching the set here would only cost an `@Observable` invalidation and,
            // for a lone selected annotation elsewhere, nothing at all — deliberately minimal.
            guard wasSelected else { continue }
            if cutSelectionSide(objectStart: before.startTime, objectDuration: before.duration,
                                splitTime: splitTime, keeping: keeping) == .right {
                selectedIDs.remove(id)      // no-op if `remove(id:)` above already pruned it
                selectedIDs.insert(newID)
            }
        }
        // A half thrown away takes its seam with it: `refitCrossfade` then clears what is left.
        for p in pairs { refitCrossfade(leftID: p.left, rightID: p.right) }
        guard !result.isEmpty else {
            _ = undoStack.popLast()
            return []
        }
        // A marker or a region left on a piece the cut swallowed no longer names anything —
        // the same pruning `applySnapshot` does after an undo (@see EditViewModel+UndoRedo).
        if let sel = selectedAnnotation, !annotationExists(sel) { selectedAnnotation = nil }
        // And a crossfade zone naming one of the cut objects: the zone it named may no longer
        // exist (cut through, or one member gone), and ⌫ must not aim at it regardless
        // (@see TimelineKeyHandler).
        if let xf = selectedCrossfade, ids.contains(xf.left) || ids.contains(xf.right) {
            selectedCrossfade = nil
        }
        isDirty = true
        // While playing, the 120 ms damper on graph rebuilds is HEARD: the left half is already
        // shorter, and the right one only enters the graph at the rebuild — a hole of 170-220 ms
        // on a heavy project when the cut lands under the playhead. Rebuilt now instead (a single
        // block of silence remains, @see engine-patches/3.5 `0033`). Stopped, the damper is kept.
        engine?.rebuildGraphNowIfPlaying()
        return result
    }

    /// The objects concerned by a cut triggered on `id`. Alone → it. In a multiple selection it
    /// is part of → every selected object the cut instant crosses (the
    /// descendants of a selected object are excluded: cutting the parent already cuts them).
    func cutTargetIDs(hit id: UUID, atTime t: Double) -> [UUID] {
        let selected = effectiveSelectedIDs
        guard selected.count > 1, selected.contains(id) else { return [id] }
        return laneEntries
            .filter { selected.contains($0.item.id) }
            .filter { $0.absStart < t && $0.absStart + $0.item.duration > t }
            .map(\.item.id)
    }

    /// A cut from the keyboard — "C then ⏎". A time SELECTION laid down takes precedence: it is cut at its
    /// two bounds (see `splitAtTimeSelectionBounds`). Otherwise the cut is at the CARET (the black cursor),
    /// aimed at the object selection, failing that at the caret's lane.
    func splitAtCaret() {
        if timeSelection != nil { splitAtTimeSelectionBounds(); return }
        let t = cursorPosition
        let crossing = laneEntries.filter {
            $0.absStart < t - 0.001 && $0.absStart + $0.item.duration > t + 0.001
        }
        let selected = effectiveSelectedIDs
        let targets: [LaneEntry]
        if !selected.isEmpty {
            targets = crossing.filter { selected.contains($0.item.id) }
        } else if let cl = caretLane {
            targets = crossing.filter { $0.displayLane == cl }
        } else {
            targets = []
        }
        guard !targets.isEmpty else { return }
        cut(ids: targets.map(\.item.id), atTime: t, keeping: nil)
    }

    /// Cuts at BOTH bounds of the time selection: entry AND exit. What is inside the selection
    /// becomes an object in its own right (and comes out selected, ready to be moved, deleted,
    /// grouped); what overruns stays either side. A single undo for both cuts.
    func splitAtTimeSelectionBounds() {
        guard let sel = timeSelection else { return }
        let t1 = sel.timeRange.lowerBound, t2 = sel.timeRange.upperBound
        guard t2 > t1 + 0.001 else { return }
        pushUndo()
        var didSplit = false
        // The RIGHT bound first: the left half keeps the original id, so the second cut
        // finds its targets as they were.
        for t in [t2, t1] {
            let targets = laneEntries
                .filter { sel.lanes.contains($0.displayLane) }
                .filter { $0.absStart < t - 0.001 && $0.absStart + $0.item.duration > t + 0.001 }
                .map(\.item.id)
            for id in targets where find(id: id) != nil {
                if _splitInternal(id: id, atTime: t) != nil { didSplit = true }
            }
        }
        guard didSplit else { _ = undoStack.popLast(); return }
        selectedIDs = Set(laneEntries
            .filter { sel.lanes.contains($0.displayLane) }
            .filter { $0.absStart > t1 - 0.001 && $0.absStart + $0.item.duration < t2 + 0.001 }
            .map(\.item.id))
        isDirty = true
        engine?.rebuildGraphNowIfPlaying()
    }

    // MARK: - Cutting a detached sub-tree (the content of a group being split)

    /// Cuts a sub-tree at `splitTime` (absolute time): what stays on the left, what goes to
    /// the right. Works on VALUES already detached from the model and the engine — it is the
    /// content of a group whose folder has just been removed (case 3 of `_splitInternal`).
    ///
    ///  • a straddling clip / MIDI clip → split at the bound (note-aware for MIDI); the right
    ///    half gets cloned plugins, the sub-tree's engine instances having been
    ///    destroyed (the `stateXML` fallback of `copiedPlugins` restores the settings);
    ///  • a straddling GROUP → cut RECURSIVELY: its children are distributed, and themselves
    ///    cut if they straddle the bound. Cutting a group that holds others therefore cuts
    ///    all of its content and gives two groups, one on each side — instead of sending each
    ///    sub-group whole to the side where it weighed the most;
    ///  • a straddling AUX → stays WHOLE on the majority side. An aux is a bus, not matter:
    ///    cutting it finely is the dedicated gesture of case 2bis.
    ///
    /// `rightIDMap` accumulates the origin → right-half correspondences: the caller uses it
    /// to rewire the internal sends onto the copies.
    func splitSubtree(_ child: SoundObject, at splitTime: Double,
                      rightIDMap: inout [UUID: UUID])
        -> (left: SoundObject?, right: SoundObject?) {

        let childStart = child.startTime
        let childEnd   = childStart + child.duration
        if childEnd   <= splitTime { return (child, nil) }
        if childStart >= splitTime { return (nil, child) }

        // The curves are cut at the same instant as the matter, in time RELATIVE to the object, with
        // an interpolated point on each side (@see AutomationLane.split).
        let (autoL, autoR) = child.automation.splitInTime(at: splitTime - childStart)
        // The markers are cut at the same instant and in the same frame — a region straddling the
        // cut goes to both halves, like the object's own label (@see Array where Element == Marker).
        let (markL, markR) = child.markers.splitInTime(at: splitTime - childStart)

        switch child.kind {
        case .clip(let fp, _, let fd, let sr, let rev):
            let offsets = splitSourceOffsets(of: child, at: splitTime)
            var lc = child
            lc.duration = splitTime - childStart
            // The two faces of the cut are born bare, shape included (@see freshCutCurve); the
            // edges the cut did not touch keep theirs.
            lc.fadeOut      = 0
            lc.fadeOutCurve = Self.freshCutCurve
            lc.automation = autoL
            lc.markers    = markL
            lc.sourceOffset = offsets.left
            // derivedCopy: sends/chain gains/consolidated link inherited.
            let rc = child.derivedCopy(
                startTime: splitTime, duration: childEnd - splitTime, lane: child.lane,
                fadeIn: 0, fadeOut: child.fadeOut,
                fadeInCurve: Self.freshCutCurve,
                plugins: copiedPlugins(of: child),
                automation: autoR,
                markers: markR,
                kind: .clip(filePath: fp, sourceOffset: offsets.right,
                            fileDuration: fd, speedRatio: sr, isReversed: rev))
            rightIDMap[child.id] = rc.id
            return (lc, rc)

        case .midiClip(let notes, let lengthBeats):
            let splitBeat = beatsFromSeconds(splitTime - childStart)
            let (leftNotes, rightNotes) = Self.splitMidiNotes(notes, atBeat: splitBeat)
            var lc = child
            lc.duration = splitTime - childStart
            lc.fadeOut      = 0
            lc.fadeOutCurve = Self.freshCutCurve   // @see freshCutCurve
            lc.automation = autoL
            lc.markers    = markL
            lc.kind = .midiClip(notes: leftNotes,
                                lengthBeats: max(0.01, min(lengthBeats, splitBeat)))
            let rc = child.derivedCopy(
                startTime: splitTime, duration: childEnd - splitTime, lane: child.lane,
                fadeIn: 0, fadeOut: child.fadeOut,
                fadeInCurve: Self.freshCutCurve,
                plugins: copiedPlugins(of: child),
                instruments: copiedInstruments(of: child),
                automation: autoR,
                markers: markR,
                kind: .midiClip(notes: rightNotes,
                                lengthBeats: max(0.01, lengthBeats - splitBeat)))
            rightIDMap[child.id] = rc.id
            return (lc, rc)

        case .aux:
            if splitTime - childStart >= childEnd - splitTime { return (child, nil) }
            return (nil, child)

        case .group(let grandchildren, let isExpanded):
            // A LOOPING sub-group: two portholes onto the same pattern, its content not distributed.
            if let looped = loopedGroupRightHalf(child, children: grandchildren,
                                                 at: splitTime, idMap: &rightIDMap) {
                var lg = child
                lg.duration = splitTime - childStart
                lg.fadeIn   = min(child.fadeIn, lg.duration)
                lg.fadeOut      = 0
                lg.fadeOutCurve = Self.freshCutCurve   // @see freshCutCurve
                lg.automation = autoL
                lg.markers    = markL
                var rg = child.derivedCopy(
                    startTime: splitTime, duration: childEnd - splitTime, lane: child.lane,
                    fadeIn: 0, fadeOut: min(child.fadeOut, childEnd - splitTime),
                    fadeInCurve: Self.freshCutCurve,
                    plugins: copiedPlugins(of: child),
                    automation: autoR,
                    markers: markR,
                    kind: .group(children: looped.children, isExpanded: isExpanded))
                rg.loopRangeStart = looped.loopStart
                rg.loopRangeEnd   = looped.loopEnd
                rightIDMap[child.id] = rg.id
                return (lg, rg)
            }

            var innerLeft:  [SoundObject] = []
            var innerRight: [SoundObject] = []
            for grandchild in grandchildren {
                let (gl, gr) = splitSubtree(grandchild, at: splitTime, rightIDMap: &rightIDMap)
                if let gl { innerLeft.append(gl) }
                if let gr { innerRight.append(gr) }
            }
            // The left half keeps the sub-group's identity (id, plugins already captured);
            // only the right one is a copy, with new plugin UUIDs.
            var lg = child
            lg.duration = splitTime - childStart
            lg.fadeIn   = min(child.fadeIn, lg.duration)
            lg.fadeOut      = 0
            lg.fadeOutCurve = Self.freshCutCurve   // @see freshCutCurve
            lg.automation = autoL
            lg.markers    = markL
            lg.kind     = .group(children: innerLeft, isExpanded: isExpanded)
            let rg = child.derivedCopy(
                startTime: splitTime, duration: childEnd - splitTime, lane: child.lane,
                fadeIn: 0, fadeOut: min(child.fadeOut, childEnd - splitTime),
                fadeInCurve: Self.freshCutCurve,
                plugins: copiedPlugins(of: child),
                automation: autoR,
                markers: markR,
                kind: .group(children: innerRight, isExpanded: isExpanded))
            rightIDMap[child.id] = rg.id
            return (lg, rg)
        }
    }

    // MARK: - Windowing a detached sub-tree (the content of a fragmented group)

    /// Restricts a DETACHED sub-tree to the window [lo, hi] (absolute times): two
    /// `splitSubtree` cuts, keeping only what falls between the two. This is the time selection's
    /// cut applied to the CONTENT of a fragmented group — the same rules, the same code: clips
    /// and MIDI trimmed at the bounds, sub-groups cut recursively, an aux whole on the
    /// majority side, a looping sub-group treated as a porthole.
    ///
    /// `idMap` accumulates origin → fragment to rewire the internal sends (@see
    /// remappingSends). Only the LEFT cut feeds it: on the right, the half that goes is
    /// thrown away — recording it would aim at an object that exists nowhere.
    func windowedSubtree(_ children: [SoundObject], from lo: Double, to hi: Double,
                         idMap: inout [UUID: UUID]) -> [SoundObject] {
        var out: [SoundObject] = []
        for child in children {
            guard let afterLo = splitSubtree(child, at: lo, rightIDMap: &idMap).right else { continue }
            var discarded: [UUID: UUID] = [:]
            guard let inside = splitSubtree(afterLo, at: hi, rightIDMap: &discarded).left else { continue }
            out.append(inside)
        }
        return out
    }

    // MARK: - Cutting a LOOPING group

    /// True if the object is a group whose loop is ACTIVE and bounded: its window is no longer
    /// an edge but a porthole laid on a repeating pattern. So its content is never
    /// cut — only the porthole is moved or narrowed (@see loopedGroupRightHalf).
    func isLoopedGroupPorthole(_ obj: SoundObject) -> Bool {
        guard obj.isGroup, obj.loopEnabled, obj.canLoop,
              let a = obj.loopRangeStart, let b = obj.loopRangeEnd else { return false }
        return b - a > 0.001
    }

    /// The content and IN/OUT bounds of the RIGHT half of a **looping** group cut at
    /// `splitTime` — `nil` if the group does not loop (an ordinary cut, with the content distributed).
    ///
    /// A looping group no longer has an edge: its window is a porthole laid on a repeating
    /// pattern (@see [[loop-item-plan]]). Cutting in the middle of a repeat must therefore NOT
    /// distribute the children either side — the cut most often falls after the
    /// content, and the right half ended up empty — but lay TWO portholes onto the same
    /// pattern. The left keeps the content as it is (it sounds exactly as before); the
    /// right gets a copy of it, shifted by a WHOLE number of periods so that the IN point
    /// falls back as close as possible TO THE LEFT of the cut. The engine then derives an offset equal to the
    /// current phase (@see refreshContainerSpanForKey:): the repeat under way carries on
    /// identically across the cut.
    ///
    /// The corollary: the bounds returned are NEGATIVE or zero — the IN point of the right
    /// half precedes its own start. It is the same freedom as the "sampler-style" loop points
    /// of an audio clip (@see SoundObject.loopRangeStart); the display can draw
    /// repeats set on an origin earlier than the block (@see GroupWaveformView).
    ///
    /// `idMap` accumulates origin → copy so that the internal sends follow (@see
    /// remappingSends), as for an ordinary cut.
    func loopedGroupRightHalf(_ group: SoundObject, children: [SoundObject],
                              at splitTime: Double,
                              idMap: inout [UUID: UUID])
        -> (children: [SoundObject], loopStart: Double, loopEnd: Double)? {

        guard group.loopEnabled, group.canLoop,
              let a = group.loopRangeStart, let b = group.loopRangeEnd else { return nil }
        let period = b - a
        guard period > 0.001 else { return nil }

        let inAbs = group.startTime + a                       // the IN point, in timeline time
        let k     = max(0, ((splitTime - inAbs) / period).rounded(.down))
        let shift = k * period

        let copies = children.map { makeCopy($0, startTime: $0.startTime + shift,
                                             lane: $0.lane, idMap: &idMap) }
        let newInAbs = inAbs + shift
        return (copies, newInAbs - splitTime, newInAbs - splitTime + period)
    }

    @discardableResult
    func _splitInternal(id: UUID, atTime splitTime: Double) -> UUID? {
        // An instance of a consolidated object IS a clip: the split is allowed. Both halves
        // stay linked to the same definition. NB: detaching one half restores the WHOLE
        // original sub-tree (the sidecar stands for the whole), positioned at the start of the half — so it
        // can overrun. An accepted behaviour.

        // Case 1: a top-level clip
        if let i = items.firstIndex(where: { $0.id == id }),
           case .clip(let filePath, _, let fileDuration,
                      let speedRatio, let isReversed) = items[i].kind {

            let original = items[i]
            let splitRel = splitTime - original.startTime
            guard splitRel > 0, splitRel < original.duration else { return nil }
            let offsets = splitSourceOffsets(of: original, at: splitTime)

            let newID = UUID()
            guard let engine,
                  engine.splitSoundObject(withID: id.uuidString,
                                          atTime: splitTime,
                                          newID: newID.uuidString) else { return nil }

            // Cutting the curves: the left half keeps its frame of reference, the right is rebased on
            // the cut, each with an interpolated point at the bound (@see AutomationLane.split).
            let (autoL, autoR) = original.automation.splitInTime(at: splitRel)
            let (markL, markR) = original.markers.splitInTime(at: splitRel)

            items[i].duration = splitRel
            items[i].automation = autoL
            items[i].markers = markL
            items[i].sourceOffset = offsets.left
            let leftFadeIn  = min(items[i].fadeIn, splitRel)
            let leftFadeOut = 0.0
            items[i].fadeIn  = leftFadeIn
            items[i].fadeOut = leftFadeOut
            // The left half's new right edge: no length, and no SHAPE either — the engine keeps
            // the window plugin of the object as it was, curve included (@see freshCutCurve).
            items[i].fadeOutCurve = Self.freshCutCurve
            engine.updateFade(in: leftFadeIn, fadeOut: leftFadeOut, forID: id.uuidString)

            let rightFadeOut = min(original.fadeOut, original.duration - splitRel)
            // derivedCopy: the right half inherits the sends/chain gains/consolidated link
            // (it stays an instance of the same definition). The left clip keeps the original
            // (its engine instances intact); the right-hand piece gets plugins cloned with
            // the state captured live, for a split identical in sound.
            let rightObject = original.derivedCopy(
                id: newID,
                startTime: splitTime,
                duration: original.duration - splitRel,
                lane: original.lane,
                fadeIn: 0,
                fadeOut: rightFadeOut,
                fadeInCurve: Self.freshCutCurve,
                plugins: copiedPlugins(of: original),
                automation: autoR,
                markers: markR,
                kind: .clip(
                    filePath: filePath,
                    // sourceOffset in source seconds: the edge advances by splitRel on the timeline →
                    // splitRel×speed in the source. And in reverse, the roles of the two edges
                    // swap over (@see splitSourceOffsets).
                    sourceOffset: offsets.right,
                    fileDuration: fileDuration,
                    speedRatio: speedRatio,
                    isReversed: isReversed
                )
            )
            items.append(rightObject)
            engine.updateFade(in: 0, fadeOut: rightFadeOut, forID: newID.uuidString)
            syncSends(rightObject)   // the right half feeds the same auxes as the left

            if !rightObject.plugins.isEmpty { syncPlugins(rightObject) }
            // The two halves now carry DIFFERENT curves, and `splitSoundObject`
            // has copied only the engine clip: both have to be pushed again. LAST,
            // once the sends are wired and the right half's rack is compiled — with no carrier,
            // a send or plugin curve would have nowhere to write itself.
            pushAutomation(items[i])
            pushAutomation(rightObject)
            // And the SHAPES: nothing on this path relays them (no `syncPosition`, and
            // `setWindowForKey` says nothing of the curve), so the engine would keep the shape the
            // object had on the very edge the cut has just cleared.
            pushFadeCurveTree(items[i])
            pushFadeCurveTree(rightObject)
            return newID
        }

        // Case 2: a clip that is the child of a group (at any depth of nesting)
        if let group = parentGroup(for: id),
           let child = find(id: id),
           case .clip(let fp, _, let fd, let sr, let rev) = child.kind {

            let splitRelChild = splitTime - child.startTime
            guard splitRelChild > 0.01, splitRelChild < child.duration - 0.01 else { return nil }
            let offsets = splitSourceOffsets(of: child, at: splitTime)

            guard let engine else { return nil }
            // The folder model: a child = its own track. A direct engine split (the track
            // supports splitSoundObject), then the right fragment is reassigned into the folder.
            // gain/pan/speed/pitch/reverse are copied by splitSoundObject; the fades and the
            // plugins (cloned with a frozen state) are restored on the Swift side.
            let captured = withCapturedPluginStates(child)

            let (autoL, autoR) = child.automation.splitInTime(at: splitRelChild)
            let (markL, markR) = child.markers.splitInTime(at: splitRelChild)

            var leftChild = captured
            leftChild.duration = splitRelChild
            leftChild.fadeIn   = min(child.fadeIn, splitRelChild)
            leftChild.fadeOut      = 0
            leftChild.fadeOutCurve = Self.freshCutCurve   // @see freshCutCurve
            leftChild.automation = autoL
            leftChild.markers    = markL
            leftChild.sourceOffset = offsets.left

            let rightID = UUID()
            // derivedCopy: sends/chain gains/consolidated link inherited by the right half.
            let rightChild = child.derivedCopy(
                id: rightID,
                startTime: splitTime,
                duration: child.startTime + child.duration - splitTime,
                lane: child.lane,
                fadeIn: 0, fadeOut: min(child.fadeOut, child.startTime + child.duration - splitTime),
                fadeInCurve: Self.freshCutCurve,
                plugins: copiedPlugins(of: captured),
                automation: autoR,
                markers: markR,
                kind: .clip(filePath: fp, sourceOffset: offsets.right,
                            fileDuration: fd, speedRatio: sr, isReversed: rev)
            )

            guard engine.splitSoundObject(withID: id.uuidString,
                                          atTime: splitTime,
                                          newID: rightID.uuidString) else { return nil }
            engine.assignObject(rightID.uuidString, toGroupFolder: group.id.uuidString)
            syncSends(rightChild)

            update(id: group.id) { obj in
                guard case .group(var children, let isExpanded) = obj.kind,
                      let ci = children.firstIndex(where: { $0.id == id }) else { return }
                children[ci] = leftChild
                children.insert(rightChild, at: ci + 1)
                obj.kind = .group(children: children, isExpanded: isExpanded)
            }

            // The fades of both fragments (splitSoundObject does not set them).
            engine.updateFade(in: leftChild.fadeIn, fadeOut: 0, forID: leftChild.id.uuidString)
            engine.updateFade(in: 0, fadeOut: rightChild.fadeOut, forID: rightChild.id.uuidString)

            if !rightChild.plugins.isEmpty { syncPlugins(rightChild) }
            // As in case 1, and for the same reason: last, with the carriers in place.
            pushAutomation(leftChild)
            pushAutomation(rightChild)
            pushFadeCurveTree(leftChild)    // the cleared shapes, as in case 1
            pushFadeCurveTree(rightChild)

            isDirty = true
            return rightID
        }

        // Case 2bis: an aux (top-level or a child) — split into TWO windows.
        // Left = the original aux (id/bus/sends kept), its window trimmed to [start, split].
        // Right = a new aux (cloned plugins); the senders that fed the original
        // feed the right half TOO → the reverb stays continuous either side.
        if let original = find(id: id), case .aux = original.kind {
            let splitRel = splitTime - original.startTime
            guard splitRel > 0.01, splitRel < original.duration - 0.01 else { return nil }
            let parent = parentGroup(for: id)

            // copiedPlugins backfills a linkGroupID onto the ORIGINAL's plugins (in items)
            // → the right half is linked to the left. To be called BEFORE re-reading `left`,
            // otherwise that backfill would be crushed.
            let rightPlugins = copiedPlugins(of: original)
            let (autoL, autoR) = original.automation.splitInTime(at: splitRel)
            let (markL, markR) = original.markers.splitInTime(at: splitRel)
            guard var left = find(id: id) else { return nil }   // the FRESHLY linked original
            left.duration = splitRel
            left.fadeOut      = 0
            left.fadeOutCurve = Self.freshCutCurve   // @see freshCutCurve
            left.automation = autoL
            left.markers    = markL

            let rightID = UUID()
            let right = original.derivedCopy(
                id: rightID, startTime: splitTime, duration: original.duration - splitRel,
                lane: original.lane,
                fadeIn: 0, fadeOut: original.fadeOut,
                fadeInCurve: Self.freshCutCurve,
                plugins: rightPlugins,
                automation: autoR,
                markers: markR,
                kind: .aux
            )

            // Model: replace the original with `left`, insert `right` just after.
            if let parent {
                update(id: parent.id) { obj in
                    guard case .group(var ch, let e) = obj.kind,
                          let i = ch.firstIndex(where: { $0.id == id }) else { return }
                    ch[i] = left
                    ch.insert(right, at: i + 1)
                    obj.kind = .group(children: ch, isExpanded: e)
                }
            } else {
                if let i = items.firstIndex(where: { $0.id == id }) { items[i] = left }
                items.append(right)
            }

            // Engine: left = a simple window update (track/plugins/bus unchanged);
            // right = a new aux, put back into the group if the original was in one.
            syncAuxWindow(left)
            pushAutomation(left)   // the left is not re-added: its trimmed curve is still to be pushed
            pushFadeCurveTree(left)   // …and its cleared fade-out shape, which the window says nothing of
            engineAddAux(right)
            pushFadeCurveTree(right)
            if let parent { engine?.assignObject(rightID.uuidString, toGroupFolder: parent.id.uuidString) }

            // The sends targeting the original aux target the right half too.
            duplicateSendsTarget(from: id, to: rightID)

            isDirty = true
            return rightID
        }

        // Case 2ter: a MIDI clip (top-level or a child) — a note-aware split, the same behaviour
        // as audio clips. No engine splitSoundObject: the right half = a complete NEW MIDI
        // object (a cloned instrument, cloned+linked plugins), the notes distributed/rebased through
        // splitMidiNotes (a straddling note is truncated on the left, not re-triggered on the right).
        if let original = find(id: id),
           case .midiClip(let notes, let lengthBeats) = original.kind {

            let splitRel = splitTime - original.startTime
            guard splitRel > 0.01, splitRel < original.duration - 0.01 else { return nil }
            let parent = parentGroup(for: id)

            let splitBeat = beatsFromSeconds(splitRel)
            let (leftNotes, rightNotes) = Self.splitMidiNotes(notes, atBeat: splitBeat)

            // copiedPlugins backfills a linkGroupID onto the ORIGINAL (see the aux case) → re-read
            // `left` AFTER. The right instrument = a new instance (its state captured live).
            let rightPlugins     = copiedPlugins(of: original)
            let rightInstruments = copiedInstruments(of: original)
            let (autoL, autoR)   = original.automation.splitInTime(at: splitRel)
            let (markL, markR)   = original.markers.splitInTime(at: splitRel)
            guard var left = find(id: id) else { return nil }
            left.duration = splitRel
            left.fadeIn   = min(left.fadeIn, splitRel)
            left.fadeOut      = 0
            left.fadeOutCurve = Self.freshCutCurve   // @see freshCutCurve
            left.automation = autoL
            left.markers    = markL
            left.kind     = .midiClip(notes: leftNotes,
                                      lengthBeats: max(0.01, min(lengthBeats, splitBeat)))

            let rightID = UUID()
            let right = original.derivedCopy(
                id: rightID, startTime: splitTime, duration: original.duration - splitRel,
                lane: original.lane,
                fadeIn: 0, fadeOut: min(original.fadeOut, original.duration - splitRel),
                fadeInCurve: Self.freshCutCurve,
                plugins: rightPlugins, instruments: rightInstruments,
                automation: autoR,
                markers: markR,
                kind: .midiClip(notes: rightNotes,
                                lengthBeats: max(0.01, lengthBeats - splitBeat)))

            // Model: replace the original with `left`, insert `right` just after.
            if let parent {
                update(id: parent.id) { obj in
                    guard case .group(var ch, let e) = obj.kind,
                          let i = ch.firstIndex(where: { $0.id == id }) else { return }
                    ch[i] = left
                    ch.insert(right, at: i + 1)
                    obj.kind = .group(children: ch, isExpanded: e)
                }
            } else {
                if let i = items.firstIndex(where: { $0.id == id }) { items[i] = left }
                items.append(right)
            }

            // Engine: left = the same object (its window + truncated notes pushed again);
            // right = a complete new MIDI object, put back into the group or the stem.
            syncPosition(left)
            syncMidiNotes(left)
            engine?.updateFade(in: left.fadeIn, fadeOut: 0, forID: id.uuidString)
            engineAddMidiClip(right)
            if let parent {
                engine?.assignObject(rightID.uuidString, toGroupFolder: parent.id.uuidString)
            } else if let sid = right.stemID {
                engine?.assignObjects([rightID.uuidString], toStemID: sid.uuidString)
            }
            engine?.updateFade(in: 0, fadeOut: right.fadeOut, forID: rightID.uuidString)
            pushFadeCurveTree(right)   // `syncPosition(left)` has already relayed the left's
            syncSends(right)

            isDirty = true
            return rightID
        }

        // Case 3: a group (top-level or nested)
        if let original = find(id: id),
           case .group(let children, let isExpanded) = original.kind {

            let splitRel = splitTime - original.startTime
            guard splitRel > 0, splitRel < original.duration else { return nil }

            // Captures the plugin state of the WHOLE sub-tree BEFORE removeFromEngine
            // (which destroys the engine instances of the group and its descendants).
            // The captured children are then distributed: they keep their UUIDs +
            // frozen stateXML, so the engine re-sync restores their settings.
            let capturedOriginal = withCapturedPluginStates(original)
            let splitChildren = { () -> [SoundObject] in
                if case .group(let c, _) = capturedOriginal.kind { return c }
                return children
            }()

            // Engine removal (removeFromEngine: descendants + folder, whatever the
            // nesting), THEN model removal.
            let parent = parentGroup(for: id)
            removeFromEngine(original)
            if let parent {
                update(id: parent.id) { obj in
                    guard case .group(let pChildren, let pExpanded) = obj.kind else { return }
                    obj.kind = .group(children: pChildren.filter { $0.id != id },
                                      isExpanded: pExpanded)
                }
            } else {
                items.removeAll { $0.id == id }
            }

            var leftChildren:  [SoundObject] = []
            var rightChildren: [SoundObject] = []
            var rightIDMap: [UUID: UUID] = [:]

            // A LOOPING group: the content is not distributed, the two halves are two
            // portholes onto the same pattern (@see loopedGroupRightHalf).
            let looped = loopedGroupRightHalf(original, children: splitChildren,
                                              at: splitTime, idMap: &rightIDMap)
            if let looped {
                leftChildren  = splitChildren
                rightChildren = looped.children
            } else {
                for child in splitChildren {
                    let (l, r) = splitSubtree(child, at: splitTime, rightIDMap: &rightIDMap)
                    if let l { leftChildren.append(l) }
                    if let r { rightChildren.append(r) }
                }
            }
            // The internal sends follow the cut: in the right half, what aimed at an
            // object of the group now aims at ITS right half (@see remappingSends). Without this,
            // the right-hand children went on feeding the auxes left behind on the left — sends
            // the engine refuses to wire, the container's boundary having changed.
            rightChildren = rightChildren.map { Self.remappingSends($0, using: rightIDMap) }

            let rightID = UUID()
            // derivedCopy: BOTH halves of the group inherit the sends/chain gains (a
            // group can send towards an aux — before this fix the sends survived the split on the
            // model side nowhere). The engine wiring of the sends goes through syncAddGroup.
            // The GROUP's curves are cut like a clip's; those of its children
            // have already been cut by `splitSubtree`, each in its own child's frame of reference.
            let (autoL, autoR) = original.automation.splitInTime(at: splitRel)
            let (markL, markR) = original.markers.splitInTime(at: splitRel)
            let left = original.derivedCopy(
                id: original.id, startTime: original.startTime, duration: splitRel,
                lane: original.lane,
                fadeIn: min(original.fadeIn, splitRel), fadeOut: 0,
                fadeOutCurve: Self.freshCutCurve,
                plugins: copiedPlugins(of: capturedOriginal),
                automation: autoL,
                markers: markL,
                kind: .group(children: leftChildren, isExpanded: isExpanded)
            )
            var right = original.derivedCopy(
                id: rightID, startTime: splitTime, duration: original.duration - splitRel,
                lane: original.lane,
                fadeIn: 0, fadeOut: min(original.fadeOut, original.duration - splitRel),
                fadeInCurve: Self.freshCutCurve,
                plugins: copiedPlugins(of: capturedOriginal),
                automation: autoR,
                markers: markR,
                kind: .group(children: rightChildren, isExpanded: isExpanded)
            )
            // IN/OUT bounds rebased on the new start: the loop resumes in phase
            // (@see loopedGroupRightHalf).
            if let looped {
                right.loopRangeStart = looped.loopStart
                right.loopRangeEnd   = looped.loopEnd
            }

            if let parent {
                // Reinsertion into the parent: addChild handles the model AND the recursive
                // engine sync (a nested folder + its descendants).
                addChild(left,  toGroupID: parent.id)
                addChild(right, toGroupID: parent.id)
            } else {
                items.append(left)
                items.append(right)
                syncAdd(left)
                syncAdd(right)
            }
            isDirty = true
            return rightID
        }

        return nil
    }
}

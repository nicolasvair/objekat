import Foundation

// MARK: - Clipboard

struct ClipboardContent {
    var clips: [SoundObject]
    var originTime: Double
    var originLane: Int    // the display lane of the first item
    var selectionDuration: Double?
    var lanes: Set<Int>?   // the display lanes of the time selection
}

extension EditViewModel {

    // MARK: - Unified placement helpers

    /// Converts a display lane into a base lane by counting the extra lanes reserved above it.
    ///
    /// This is the INVERSE of `displayLane(for:)` (display = base + Σ expandedSpan of the lanes < base).
    /// The two MUST count the same amount, otherwise the there-and-back mapping is wrong.
    /// A historic bug: only the `childLaneCount` of expanded groups was counted here, forgetting
    /// the other zones unfolded inline (a MIDI clip with the piano roll open = `pianoRollLaneSpan`).
    /// The consequence: an object dropped UNDER an open MIDI clip fell `pianoRollLaneSpan` (=2)
    /// lanes too low, because the piano roll's sub-lanes were not subtracted on the way back.
    /// `expandedSpan` unifies group + MIDI (see SoundObject.expandedSpan), exactly like
    /// `displayLane(for:)` and `buildLaneEntries`.
    func baseLaneForDisplay(_ target: Int) -> Int {
        var b = 0
        while b < 512 {
            let extra = items.reduce(0) { acc, item in
                item.lane < b ? acc + item.expandedSpan : acc
            }
            if b + extra >= target { return b }
            b += 1
        }
        return b
    }

    /// Places a clip (absolute startTime, lane = a display lane) according to `snapshot`'s state.
    /// - If the display lane falls inside the child range of an expanded group → addChild.
    /// - Otherwise → add top-level with the corresponding base lane.
    /// `excludingGroups`: groups forbidden as a target (anti-cycle when an existing item
    /// is being replaced — a group must not land inside itself or a descendant).
    /// Returns the clip as it was placed (its final coordinates).
    @discardableResult
    func placeClip(_ clip: SoundObject, snapshot: [LaneEntry],
                   excludingGroups: Set<UUID> = []) -> SoundObject {
        let targetDL       = clip.lane
        let targetAbsStart = clip.startTime

        // The INNERMOST expanded group whose child range contains the target display lane.
        let groupEntry = snapshot
            .filter { e in
                guard e.item.showsChildrenInline,
                      !excludingGroups.contains(e.item.id) else { return false }
                return targetDL >= e.displayLane + 1
                    && targetDL <= e.displayLane + e.item.childLaneCount
            }
            .max(by: { $0.displayLane < $1.displayLane })

        var placed = clip
        if let gEntry = groupEntry {
            placed.lane      = targetDL - (gEntry.displayLane + 1)
            placed.startTime = targetAbsStart
            addChild(placed, toGroupID: gEntry.item.id)
        } else {
            placed.lane      = baseLaneForDisplay(targetDL)
            placed.startTime = targetAbsStart
            add(placed)
        }
        return placed
    }

    // MARK: - Deep copy (new UUIDs, recursively)

    /// A copy for an alt-drag: a copied group is folded (simpler to handle/display).
    func makeAltCopy(_ item: SoundObject, startTime: Double, lane: Int) -> SoundObject {
        var copy = makeCopy(item, startTime: startTime, lane: lane)
        if case .group(let children, _) = copy.kind {
            copy.kind = .group(children: children, isExpanded: false)
        }
        return copy
    }

    /// A deep copy (a new id) through `derivedCopy`: the copy inherits ALL the mix/routing/identity
    /// attributes (sends, chain gains, baseBPM, sound-object link…) — a copy
    /// of a sound-object instance stays an instance of the same definition.
    /// The sends INTERNAL to the sub-tree are rewired onto the copies (@see remappingSends).
    func makeCopy(_ item: SoundObject, startTime: Double, lane: Int) -> SoundObject {
        var idMap: [UUID: UUID] = [:]
        let copy = makeCopy(item, startTime: startTime, lane: lane, idMap: &idMap)
        return Self.remappingSends(copy, using: idMap)
    }

    /// The same copy, but one that FEEDS an `origin → copy` table instead of rewriting the sends.
    /// To be used for a BATCH (paste, multiple duplication): the table must cover the whole batch
    /// before the rewriting, since a sender and the aux it aims at may be two distinct items.
    /// The caller finishes with `remappingSends` on each copy.
    func makeCopy(_ item: SoundObject, startTime: Double, lane: Int,
                  idMap: inout [UUID: UUID]) -> SoundObject {
        let copy: SoundObject
        switch item.kind {
        case .clip(let fp, let so, let fd, let sr, let rev):
            copy = item.derivedCopy(
                startTime: startTime, duration: item.duration, lane: lane,
                fadeIn: item.fadeIn, fadeOut: item.fadeOut,
                plugins: copiedPlugins(of: item),
                kind: .clip(filePath: fp, sourceOffset: so, fileDuration: fd,
                            speedRatio: sr, isReversed: rev)
            )
        case .midiClip(let notes, let lengthBeats):
            copy = item.derivedCopy(
                startTime: startTime, duration: item.duration, lane: lane,
                fadeIn: item.fadeIn, fadeOut: item.fadeOut,
                plugins: copiedPlugins(of: item),
                instruments: copiedInstruments(of: item),
                // Fresh note ids: without them, the copy and the original shared the identity
                // of every note — selecting then transposing / deleting in one of them
                // did it in ALL of them. @see EditViewModel.freshNoteIDs
                kind: .midiClip(notes: Self.freshNoteIDs(notes), lengthBeats: lengthBeats)
            )
        case .aux:
            copy = item.derivedCopy(
                startTime: startTime, duration: item.duration, lane: lane,
                fadeIn: item.fadeIn, fadeOut: item.fadeOut,
                plugins: copiedPlugins(of: item),
                kind: .aux
            )
        case .group(let children, let isExpanded):
            let dt = startTime - item.startTime
            var copiedChildren: [SoundObject] = []
            copiedChildren.reserveCapacity(children.count)
            for child in children {
                copiedChildren.append(makeCopy(child, startTime: child.startTime + dt,
                                               lane: child.lane, idMap: &idMap))
            }
            copy = item.derivedCopy(
                startTime: startTime, duration: item.duration, lane: lane,
                fadeIn: item.fadeIn, fadeOut: item.fadeOut,
                plugins: copiedPlugins(of: item),
                kind: .group(children: copiedChildren, isExpanded: isExpanded)
            )
        }
        idMap[item.id] = copy.id
        return copy
    }

    /// Rewrites the sends of a copied sub-tree: a send that aimed at an object PRESENT in the
    /// table now aims at its copy. What is not in it — an aux left outside — is
    /// left as it is: the send stays valid there as long as the sender is its sibling.
    ///
    /// Without this pass, duplicating a group that holds its own aux gave a copy whose
    /// children went on feeding the ORIGINAL's aux — a send the engine refuses
    /// to wire (nothing crosses a container's boundary, @see canRouteSend), hence a silent aux
    /// in the copy and a send scheme to redo by hand.
    static func remappingSends(_ obj: SoundObject, using idMap: [UUID: UUID]) -> SoundObject {
        guard !idMap.isEmpty else { return obj }
        var o = obj
        for i in o.sends.indices {
            if let mapped = idMap[o.sends[i].auxID] { o.sends[i].auxID = mapped }
        }
        // The send CURVES aim at the aux by identifier too: without this, the send
        // rewired onto the aux's copy ended up driven by a curve left on the
        // original — hence no longer driven at all.
        o.automation = o.automation.map {
            AutomationLane(param: $0.param.remappingAux(using: idMap), points: $0.points)
        }
        o.automationTouchOrder = o.automationTouchOrder.map { $0.remappingAux(using: idMap) }
        if case .group(let children, let isExpanded) = o.kind {
            o.kind = .group(children: children.map { remappingSends($0, using: idMap) },
                            isExpanded: isExpanded)
        }
        return o
    }

    // MARK: - Copy / Cut / Paste

    /// Copies the selected items into the clipboard.
    /// Always stores (absStart, displayLane) — a uniform space, with no knowledge of the group.
    func copySelected() {
        guard !selectedIDs.isEmpty else { return }

        let entries = laneEntries.filter { effectiveSelectedIDs.contains($0.item.id) }
        guard !entries.isEmpty else { return }

        // The plugin state (stateXML) is frozen NOW: for a cut→paste, the original
        // engine instances will be destroyed before the paste, so copiedPlugins' live
        // capture would fail and the fallback onto this frozen stateXML is needed.
        let clips = entries.map { entry -> SoundObject in
            var abs = withCapturedPluginStates(entry.item)
            abs.startTime = entry.absStart
            abs.lane      = entry.displayLane
            return abs
        }

        clipboard = ClipboardContent(
            clips: clips,
            originTime: clips.map(\.startTime).min()!,
            originLane: clips.map(\.lane).min()!,
            selectionDuration: nil,
            lanes: nil
        )
    }

    func cutSelected() {
        guard !selectedIDs.isEmpty else { return }
        copySelected()
        removeSelected()
    }

    /// Pastes the clipboard.
    /// - With no time selection: the same lanes, at the cursor's position.
    /// - With a time selection: the selection's lanes (preserving the relative offsets),
    ///   starting from the beginning of the selection.
    func paste() {
        guard let cb = clipboard else { return }
        let snapshot = laneEntries

        // The time anchor and the lane shift according to the state of the selection
        let pasteTime: Double
        let laneShift: Int

        if let sel = timeSelection {
            pasteTime = sel.timeRange.lowerBound
            laneShift = (sel.lanes.min() ?? cb.originLane) - cb.originLane
        } else {
            pasteTime = cursorPosition
            laneShift = caretLane.map { $0 - cb.originLane } ?? 0
        }

        typealias PasteTarget = (copy: SoundObject, groupID: UUID?, lane: Int)
        var targets: [PasteTarget] = []
        var maxAbsEnd = pasteTime
        // The origin → copy table of the WHOLE batch: an aux pasted at the same time as its senders
        // must receive from them, not stay plugged into the original aux (@see remappingSends).
        var idMap: [UUID: UUID] = [:]

        for src in cb.clips {
            let newAbsStart = pasteTime + (src.startTime - cb.originTime)
            let targetDL    = src.lane + laneShift
            let copy        = makeCopy(src, startTime: newAbsStart, lane: targetDL, idMap: &idMap)
            maxAbsEnd       = max(maxAbsEnd, newAbsStart + src.duration)

            if let gEntry = snapshot
                .filter({ e in
                    guard e.item.showsChildrenInline else { return false }
                    return targetDL >= e.displayLane + 1 && targetDL <= e.displayLane + e.item.childLaneCount
                })
                .max(by: { $0.displayLane < $1.displayLane }) {
                targets.append((copy, gEntry.item.id, targetDL - (gEntry.displayLane + 1)))
            } else {
                targets.append((copy, nil, baseLaneForDisplay(targetDL)))
            }
        }

        var allPasted: [SoundObject] = []
        batchItemsMutation {
            for (copy, groupID, lane) in targets {
                var placed = Self.remappingSends(copy, using: idMap)
                placed.lane = lane
                if let gid = groupID { addChild(placed, toGroupID: gid) } else { add(placed) }
                allPasted.append(placed)
            }
        }
        // A sender added BEFORE the aux it aims at could not be wired along the way: the
        // final reconciliation catches the order up (it is idempotent).
        resyncAllSends()

        // The "one infinite per row" rule: an infinite pasted onto a lane that already has one
        // becomes an ordinary bounded bus again.
        sanitizeInfiniteConflicts(newlyPlaced: allPasted.map(\.id))

        for obj in allPasted { resolveOverlaps(for: obj.id) }
        selectedIDs = Set(allPasted.map(\.id))

        if let dur = cb.selectionDuration {
            let end = pasteTime + dur
            seekRequest   = end
            timeSelection = TimeSelection(
                timeRange: pasteTime...end,
                lanes: cb.lanes.map { Set($0.map { $0 + laneShift }) } ?? [cb.originLane + laneShift]
            )
        } else {
            seekRequest   = maxAbsEnd
            timeSelection = nil
        }
    }

    // MARK: - Time selection

    func makeTimeSelectionFragments(lo: Double, hi: Double, lanes: Set<Int>) -> [SoundObject] {
        var capturedGroupIDs: Set<UUID> = []
        var fragments: [SoundObject] = []

        for entry in laneEntries {
            guard lanes.contains(entry.displayLane) else { continue }
            let s = entry.absStart
            let e = s + entry.item.duration
            guard s < hi && e > lo else { continue }
            // Excluded if ANY ancestor has already been captured (the recursive group fragment).
            var ancestor = parentGroup(for: entry.item.id)
            var coveredByAncestor = false
            while let a = ancestor {
                if capturedGroupIDs.contains(a.id) { coveredByAncestor = true; break }
                ancestor = parentGroup(for: a.id)
            }
            if coveredByAncestor { continue }

            let fragStart = max(s, lo)
            let fragEnd   = min(e, hi)
            // The fragment starts at `fragStart` whereas the matter, for its part, has not moved:
            // its curves rebase on that new start, exactly like the MIDI notes
            // just below (@see AutomationLane.shifted). A fragment starting at the object's
            // edge → a null shift.
            let fragAutomation = entry.item.automation.shiftedInTime(by: -(fragStart - s))

            switch entry.item.kind {

            case .clip(let fp, let so, let fd, let sr, let rev):
                // The sound-object link is ALWAYS kept (even trimmed): any piece of an
                // instance stays linked to its definition (consistent with the split).
                fragments.append(entry.item.derivedCopy(
                    startTime: fragStart, duration: fragEnd - fragStart,
                    lane: entry.displayLane,
                    fadeIn:  fragStart == s ? entry.item.fadeIn  : 0,
                    fadeOut: fragEnd   == e ? entry.item.fadeOut : 0,
                    plugins: copiedPlugins(of: entry.item),
                    automation: fragAutomation,
                    kind: .clip(filePath: fp, sourceOffset: so + (fragStart - s) * sr,
                                fileDuration: fd, speedRatio: sr, isReversed: rev)
                ))

            case .midiClip(let notes, _):
                // A note-aware fragment (the same semantics as audio clips): the fragment
                // carries EXACTLY the notes of the selection, rebased on its start — pasting the
                // fragment replays what was heard in the selection (the notes are relative
                // to the start of the clip: keeping them intact made them slide on pasting).
                let loBeat  = beatsFromSeconds(fragStart - s)
                let lenBeat = beatsFromSeconds(fragEnd - fragStart)
                let subNotes = Self.splitMidiNotes(
                    Self.splitMidiNotes(notes, atBeat: loBeat).right, atBeat: lenBeat).left
                fragments.append(entry.item.derivedCopy(
                    startTime: fragStart, duration: fragEnd - fragStart,
                    lane: entry.displayLane,
                    fadeIn:  fragStart == s ? entry.item.fadeIn  : 0,
                    fadeOut: fragEnd   == e ? entry.item.fadeOut : 0,
                    plugins: copiedPlugins(of: entry.item),
                    instruments: copiedInstruments(of: entry.item),
                    automation: fragAutomation,
                    kind: .midiClip(notes: subNotes, lengthBeats: max(0.01, lenBeat))
                ))

            case .aux:
                fragments.append(entry.item.derivedCopy(
                    startTime: fragStart, duration: fragEnd - fragStart,
                    lane: entry.displayLane,
                    fadeIn:  fragStart == s ? entry.item.fadeIn  : 0,
                    fadeOut: fragEnd   == e ? entry.item.fadeOut : 0,
                    plugins: copiedPlugins(of: entry.item),
                    automation: fragAutomation,
                    kind: .aux
                ))

            case .group(let children, let isExpanded):
                capturedGroupIDs.insert(entry.item.id)
                // Plugin states captured over the WHOLE sub-tree (copiedPlugins' stateXML
                // fallback at paste time, the engine instances being destroyed at cut time).
                let capturedChildren: [SoundObject] = {
                    if case .group(let c, _) = withCapturedPluginStates(entry.item).kind { return c }
                    return children
                }()
                // The content is CUT at the fragment's bounds, by the cut's own
                // functions (@see windowedSubtree/splitSubtree): what the fragment carries off
                // is exactly what the selection showed. A non-destructive windowing — whole
                // children, kept outside the folder's bounds — gave a copied group whose
                // content lived beside its window.
                //
                // Except for a LOOPING group: it no longer has an edge, its window is a porthole
                // onto a repeating pattern. The selection there almost always falls in a repeat,
                // hence AFTER the content — trimming it would have left it empty. The fragment is then
                // ANOTHER porthole onto the same pattern: the content copied, shifted by a whole number of
                // periods, the IN/OUT bounds rebased on the fragment's start. Exactly what
                // cutting a looping group does (@see loopedGroupRightHalf).
                var idMap: [UUID: UUID] = [:]
                let looped = loopedGroupRightHalf(entry.item, children: capturedChildren,
                                                  at: fragStart, idMap: &idMap)
                let fragChildren = (looped?.children
                    ?? windowedSubtree(capturedChildren, from: fragStart, to: fragEnd, idMap: &idMap))
                    .map { Self.remappingSends($0, using: idMap) }
                var frag = entry.item.derivedCopy(
                    startTime: fragStart, duration: fragEnd - fragStart,
                    lane: entry.displayLane,
                    fadeIn:  fragStart == s ? entry.item.fadeIn  : 0,
                    fadeOut: fragEnd   == e ? entry.item.fadeOut : 0,
                    plugins: copiedPlugins(of: entry.item),
                    automation: fragAutomation,
                    kind: .group(children: fragChildren, isExpanded: isExpanded)
                )
                if let looped {
                    frag.loopRangeStart = looped.loopStart
                    frag.loopRangeEnd   = looped.loopEnd
                }
                fragments.append(frag)
            }
        }
        return fragments
    }

    /// Copies the fragments in the time selection (display lanes).
    func copyTimeSelection() {
        guard let sel = timeSelection else { return }
        let lo = sel.timeRange.lowerBound
        let hi = sel.timeRange.upperBound
        let fragments = makeTimeSelectionFragments(lo: lo, hi: hi, lanes: sel.lanes)
        guard !fragments.isEmpty else { return }
        clipboard = ClipboardContent(
            clips: fragments,
            originTime: lo,
            originLane: sel.lanes.min()!,
            selectionDuration: hi - lo,
            lanes: sel.lanes
        )
    }

    func cutTimeSelection() {
        copyTimeSelection()
        deleteTimeSelection()
    }

    /// Deletes the content of the time selection (with no copy to the clipboard).
    func deleteTimeSelection() {
        guard let sel = timeSelection else { return }

        let lo = sel.timeRange.lowerBound
        let hi = sel.timeRange.upperBound

        let affectedAll = laneEntries.filter { e in
            return sel.lanes.contains(e.displayLane)
                && e.absStart < hi
                && e.absStart + e.item.duration > lo
        }.sorted { $0.depth < $1.depth }
        let affectedGroupIDs = Set(affectedAll.compactMap { e -> UUID? in
            guard case .group = e.item.kind else { return nil }
            return e.item.id
        })
        let affected = affectedAll.filter { e in
            // Excluded if ANY ancestor is already affected (it will take care of it itself).
            var ancestor = parentGroup(for: e.item.id)
            while let a = ancestor {
                if affectedGroupIDs.contains(a.id) { return false }
                ancestor = parentGroup(for: a.id)
            }
            return true
        }
        guard !affected.isEmpty else { return }

        pushUndo()

        for entry in affected {
            let id = entry.item.id
            let s  = entry.absStart
            let e  = s + entry.item.duration
            guard find(id: id) != nil else { continue }

            // A LOOPING group: its window is a porthole onto a repeating pattern, not an
            // edge. Removing the selection therefore cuts NOTHING of its content — only the porthole is moved
            // or narrowed, exactly as with the cut (@see loopedGroupRightHalf).
            // Without this, a selection laid in a repeat (the common case: it falls after the
            // content) emptied the group.
            let porthole = isLoopedGroupPorthole(entry.item)

            if s >= lo && e <= hi {
                remove(id: id)

            } else if s < lo && e <= hi {
                update(id: id) { $0.duration = lo - s; $0.fadeOut = 0 }
                if let obj = find(id: id) {
                    syncPosition(obj)
                    if obj.isClip || obj.isMIDI {
                        engine?.updateFade(in: obj.fadeIn, fadeOut: 0, forID: id.uuidString)
                    } else if case .group = obj.kind, !porthole {
                        _cutGroupChildren(groupID: id, cutLo: lo, cutHi: e)
                    }
                }

            } else if s >= lo && e > hi {
                let delta = hi - s
                update(id: id) { obj in
                    obj.startTime    += delta
                    obj.sourceOffset += delta * obj.speedRatio  // timeline delta → source = delta×speed
                    obj.duration      = e - hi
                    obj.fadeIn        = 0
                    // The start has advanced, the matter has not: the curves realign on it
                    // (the same rule as `updateTrim`).
                    obj.automation    = obj.automation.shiftedInTime(by: -delta)
                    // A porthole: the IN/OUT bounds are LOCAL to the block, yet the block has just
                    // advanced without the pattern moving — rebasing them by the same delta leaves the
                    // IN point at its ABSOLUTE place, hence the loop in phase. They become
                    // negative, like the right half of a cut (@see loopedGroupRightHalf).
                    if porthole {
                        obj.loopRangeStart = (obj.loopRangeStart ?? 0) - delta
                        obj.loopRangeEnd   = (obj.loopRangeEnd   ?? 0) - delta
                    }
                }
                if let obj = find(id: id) {
                    syncPosition(obj)
                    if obj.isClip || obj.isMIDI {
                        engine?.updateFade(in: 0, fadeOut: obj.fadeOut, forID: id.uuidString)
                    } else if case .group = obj.kind, !porthole {
                        _cutGroupChildren(groupID: id, cutLo: s, cutHi: hi)
                    }
                }

            } else {
                if _splitInternal(id: id, atTime: hi) == nil {
                    // A safety net (split refused: degenerate bounds…): truncate at the
                    // selection's left edge rather than do nothing.
                    update(id: id) { $0.duration = lo - s; $0.fadeOut = 0 }
                    if let obj = find(id: id) {
                        syncPosition(obj)
                        engine?.updateFade(in: obj.fadeIn, fadeOut: 0, forID: id.uuidString)
                    }
                    continue
                }
                update(id: id) { $0.duration = lo - s; $0.fadeOut = 0 }
                if let obj = find(id: id) {
                    syncPosition(obj)
                    if case .clip = obj.kind {
                        engine?.updateFade(in: obj.fadeIn, fadeOut: 0, forID: id.uuidString)
                    } else if case .group = obj.kind, !porthole {
                        // A porthole: `_splitInternal` has already laid the right half in phase,
                        // and the left keeps its pattern intact — nothing to remove between the two.
                        _cutGroupChildren(groupID: id, cutLo: lo, cutHi: hi)
                    }
                }
            }
        }

        selectedIDs   = []
        timeSelection = nil
        isDirty       = true
    }

    /// Removes the range [cutLo, cutHi] (absolute) from the DIRECT children of `groupID`,
    /// at any depth of nesting. Child groups touched are
    /// deleted / truncated recursively; a child covering the whole range is
    /// split in two (a clip) or has its descendants in the range removed (a group,
    /// whose container bounds then straddle a silent hole).
    func _cutGroupChildren(groupID: UUID, cutLo: Double, cutHi: Double) {
        guard let group = find(id: groupID),
              case .group(let children, _) = group.kind else { return }

        var updated:         [SoundObject] = []
        var needsPosResync:  [UUID]        = []
        var needsMidiResync: [UUID]        = []   // notes + fades to push again (trimmed MIDI clips)

        for child in children {
            let absStart = child.startTime
            let absEnd   = absStart + child.duration

            // Outside the cut range: unchanged
            if absEnd <= cutLo || absStart >= cutHi {
                updated.append(child)
                continue
            }

            switch child.kind {
            case .clip(let fp, let so, let fd, let sr, let rev):
                if absStart >= cutLo && absEnd <= cutHi {
                    // entirely inside the range: deleted
                    engine?.removeSoundObject(withID: child.id.uuidString)
                    selectedIDs.remove(child.id)

                } else if absStart < cutLo && absEnd <= cutHi {
                    // overlaps cutLo: truncate the end at cutLo
                    var c = child
                    c.duration = cutLo - absStart
                    c.fadeOut  = 0
                    let loopBounds = clipLoopFileBounds(c)
                    engine?.updatePosition(c.startTime, duration: c.duration,
                                           sourceOffset: so, loopEnabled: c.loopEnabled,
                                           loopRangeStart: loopBounds.start, loopRangeEnd: loopBounds.end,
                                           forID: c.id.uuidString)
                    engine?.updateFade(in: c.fadeIn, fadeOut: 0, forID: c.id.uuidString)
                    pushAutomation(c)   // the start is unchanged, but the curve follows the geometry pushed
                    updated.append(c)

                } else if absStart >= cutLo && absEnd > cutHi {
                    // overlaps cutHi: truncate the start at cutHi
                    let delta = cutHi - absStart
                    var c = child
                    c.startTime     = cutHi
                    c.sourceOffset += delta * sr
                    c.duration      = absEnd - cutHi
                    c.fadeIn        = 0
                    c.automation    = child.automation.shiftedInTime(by: -delta)
                    let loopBounds = clipLoopFileBounds(c)
                    engine?.updatePosition(c.startTime, duration: c.duration,
                                           sourceOffset: so + delta * sr, loopEnabled: c.loopEnabled,
                                           loopRangeStart: loopBounds.start, loopRangeEnd: loopBounds.end,
                                           forID: c.id.uuidString)
                    engine?.updateFade(in: 0, fadeOut: c.fadeOut, forID: c.id.uuidString)
                    pushAutomation(c)   // the start has moved → so has the edit time of the points
                    updated.append(c)

                } else {
                    // covers the whole range: a left + right split
                    let (autoL, autoR) = child.automation.splitInTime(at: cutLo - absStart)
                    var left = child
                    left.duration   = cutLo - absStart
                    left.fadeOut    = 0
                    left.automation = autoL
                    let loopBounds = clipLoopFileBounds(left)
                    engine?.updatePosition(left.startTime, duration: left.duration,
                                           sourceOffset: so, loopEnabled: left.loopEnabled,
                                           loopRangeStart: loopBounds.start, loopRangeEnd: loopBounds.end,
                                           forID: left.id.uuidString)
                    engine?.updateFade(in: left.fadeIn, fadeOut: 0, forID: left.id.uuidString)
                    pushAutomation(left)
                    updated.append(left)

                    // derivedCopy: the right half inherits the sends/chain gains/sound-object
                    // link (a piece of an instance stays linked to its definition).
                    // The right half picks the cut up at `cutLo` AND THEN jumps the hole: its
                    // curves rebase on its real start, `cutHi`.
                    let right = child.derivedCopy(
                        startTime: cutHi, duration: absEnd - cutHi, lane: child.lane,
                        fadeIn: 0, fadeOut: child.fadeOut,
                        plugins: copiedPlugins(of: child),
                        automation: autoR.shiftedInTime(by: -(cutHi - cutLo)),
                        kind: .clip(filePath: fp, sourceOffset: so + (cutHi - absStart) * sr,
                                    fileDuration: fd, speedRatio: sr, isReversed: rev)
                    )
                    engineAddClip(right)   // the clip is absolute on its track
                    engine?.assignObject(right.id.uuidString, toGroupFolder: groupID.uuidString)
                    syncSends(right)
                    pushAutomation(right)
                    updated.append(right)
                }

            case .midiClip(let notes, let lengthBeats):
                // Note-aware, the same rules as audio clips: truncating moves/truncates the
                // notes (otherwise they SLIDE, notes being relative to the start of the clip);
                // covering the whole range = a left + right split.
                if absStart >= cutLo && absEnd <= cutHi {
                    removeFromEngine(child)
                    selectedIDs.remove(child.id)

                } else if absStart < cutLo && absEnd <= cutHi {
                    // overlaps cutLo: truncate the end at cutLo (notes cut at the bound)
                    var c = child
                    let keepBeat = beatsFromSeconds(cutLo - absStart)
                    c.duration = cutLo - absStart
                    c.fadeOut  = 0
                    c.kind = .midiClip(notes: Self.splitMidiNotes(notes, atBeat: keepBeat).left,
                                       lengthBeats: max(0.01, min(lengthBeats, keepBeat)))
                    needsPosResync.append(c.id)
                    needsMidiResync.append(c.id)
                    updated.append(c)

                } else if absStart >= cutLo && absEnd > cutHi {
                    // overlaps cutHi: truncate the start at cutHi (notes rebased)
                    var c = child
                    let dropBeat = beatsFromSeconds(cutHi - absStart)
                    c.startTime  = cutHi
                    c.duration   = absEnd - cutHi
                    c.fadeIn     = 0
                    c.automation = child.automation.shiftedInTime(by: -(cutHi - absStart))
                    c.kind = .midiClip(notes: Self.splitMidiNotes(notes, atBeat: dropBeat).right,
                                       lengthBeats: max(0.01, lengthBeats - dropBeat))
                    needsPosResync.append(c.id)
                    needsMidiResync.append(c.id)
                    updated.append(c)

                } else {
                    // covers the whole range: a left + right split (like an audio clip)
                    let loBeat = beatsFromSeconds(cutLo - absStart)
                    let hiBeat = beatsFromSeconds(cutHi - absStart)
                    let (autoL, autoR) = child.automation.splitInTime(at: cutLo - absStart)
                    var left = child
                    left.duration   = cutLo - absStart
                    left.fadeOut    = 0
                    left.automation = autoL
                    left.kind = .midiClip(notes: Self.splitMidiNotes(notes, atBeat: loBeat).left,
                                          lengthBeats: max(0.01, min(lengthBeats, loBeat)))
                    needsPosResync.append(left.id)
                    needsMidiResync.append(left.id)
                    updated.append(left)

                    let right = child.derivedCopy(
                        startTime: cutHi, duration: absEnd - cutHi, lane: child.lane,
                        fadeIn: 0, fadeOut: child.fadeOut,
                        plugins: copiedPlugins(of: child),
                        instruments: copiedInstruments(of: child),
                        automation: autoR.shiftedInTime(by: -(cutHi - cutLo)),
                        kind: .midiClip(notes: Self.splitMidiNotes(notes, atBeat: hiBeat).right,
                                        lengthBeats: max(0.01, lengthBeats - hiBeat)))
                    engineAddMidiClip(right)
                    engine?.assignObject(right.id.uuidString, toGroupFolder: groupID.uuidString)
                    engine?.updateFade(in: 0, fadeOut: right.fadeOut, forID: right.id.uuidString)
                    syncSends(right)
                    pushAutomation(right)
                    updated.append(right)
                }

            case .aux:
                if absStart >= cutLo && absEnd <= cutHi {
                    removeFromEngine(child)   // entirely inside the range → deleted
                    selectedIDs.remove(child.id)
                } else {
                    // truncates the window; the internal hole stays silent through track gating.
                    var c = child
                    if absStart < cutLo && absEnd <= cutHi {
                        c.duration = cutLo - absStart
                    } else if absStart >= cutLo && absEnd > cutHi {
                        c.startTime  = cutHi
                        c.duration   = absEnd - cutHi
                        c.automation = child.automation.shiftedInTime(by: -(cutHi - absStart))
                    }
                    needsPosResync.append(c.id)   // syncPosition → window
                    updated.append(c)
                }

            case .group:
                if absStart >= cutLo && absEnd <= cutHi {
                    // a sub-group entirely inside the range: deleted completely (recursively)
                    removeFromEngine(child)
                    selectedIDs.remove(child.id)
                } else {
                    // truncated or holed: cut its own children in the range first,
                    // then adjust its bounds if they encroach.
                    _cutGroupChildren(groupID: child.id, cutLo: cutLo, cutHi: cutHi)
                    var c = find(id: child.id) ?? child
                    if absStart < cutLo && absEnd <= cutHi {
                        c.duration = cutLo - absStart
                    } else if absStart >= cutLo && absEnd > cutHi {
                        c.startTime  = cutHi
                        c.duration   = absEnd - cutHi
                        c.automation = c.automation.shiftedInTime(by: -(cutHi - absStart))
                    }
                    // covers the whole range → bounds unchanged (a silent internal hole)
                    needsPosResync.append(c.id)
                    updated.append(c)
                }
            }
        }

        update(id: groupID) { obj in
            guard case .group(_, let isExpanded) = obj.kind else { return }
            obj.kind = .group(children: updated, isExpanded: isExpanded)
        }
        for cid in needsPosResync {
            if let obj = find(id: cid) { syncPosition(obj) }
        }
        for cid in needsMidiResync {
            guard let obj = find(id: cid) else { continue }
            syncMidiNotes(obj)
            engine?.updateFade(in: obj.fadeIn, fadeOut: obj.fadeOut, forID: cid.uuidString)
        }
    }

    // MARK: - Translating the time selection

    /// Prepares the move of a time selection's content: splits at both bounds
    /// everything that overlaps them (clips, groups, children — ancestors first), then
    /// returns the entries entirely contained in the selection, ancestors excluded
    /// (a contained group moves with its children).
    func prepareTimeSelectionTranslate(_ sel: TimeSelection) -> [LaneEntry] {
        let lo = sel.timeRange.lowerBound
        let hi = sel.timeRange.upperBound

        for t in [lo, hi] {
            var done: Set<UUID> = []
            while true {
                let candidates = laneEntries
                    .filter { e in
                        !done.contains(e.item.id)
                            && sel.lanes.contains(e.displayLane)
                            && e.absStart < t
                            && e.absStart + e.item.duration > t
                    }
                    .sorted { $0.depth < $1.depth }
                guard let e = candidates.first else { break }
                done.insert(e.item.id)
                _ = _splitInternal(id: e.item.id, atTime: t)
            }
        }

        let insideAll = laneEntries.filter { e in
            sel.lanes.contains(e.displayLane)
                && e.absStart >= lo
                && e.absStart + e.item.duration <= hi
        }
        let insideIDs = Set(insideAll.map(\.item.id))
        return insideAll.filter { e in
            var ancestor = parentGroup(for: e.item.id)
            while let a = ancestor {
                if insideIDs.contains(a.id) { return false }
                ancestor = parentGroup(for: a.id)
            }
            return true
        }
    }

    /// The final move of a time-selection translate, cut/paste style:
    /// each item (anchors: absolute startTime, lane = the original DISPLAY lane) is
    /// removed from its current position (top-level or a child, at any depth) then
    /// put back at (start + dt, displayLane + dl) through placeClip — so it can change
    /// lane, enter a group or leave one freely.
    func moveTranslatedItems(_ anchors: [UUID: (start: Double, lane: Int)],
                             dt: Double, dl: Int) {
        let snapshot = laneEntries

        // Anti-cycle: a moved item (or a descendant of a moved group) cannot
        // serve as the target group.
        var excluded = Set(anchors.keys)
        func collectDescendants(_ objs: [SoundObject]) {
            for o in objs {
                excluded.insert(o.id)
                if case .group(let ch, _) = o.kind { collectDescendants(ch) }
            }
        }
        for id in anchors.keys {
            if let obj = find(id: id), case .group(let ch, _) = obj.kind {
                collectDescendants(ch)
            }
        }

        var placed: [SoundObject] = []
        for (id, anchor) in anchors {
            guard var obj = find(id: id) else { continue }

            // Removal from the current position (the engine first — removeFromEngine
            // leans on parentGroup, so the item must still be in the model).
            removeFromEngine(obj)
            if let parent = parentGroup(for: id) {
                update(id: parent.id) { p in
                    guard case .group(let ch, let e) = p.kind else { return }
                    p.kind = .group(children: ch.filter { $0.id != id }, isExpanded: e)
                }
            } else {
                removeFromItems(id: id)
            }

            // The new position (a group's descendants shifted by the same delta).
            let newStart = max(0, anchor.start + dt)
            let dStart   = newStart - obj.startTime
            obj.startTime = newStart
            if case .group(var ch, let e) = obj.kind, dStart != 0 {
                EditViewModel.shiftStartTimes(&ch, by: dStart)
                obj.kind = .group(children: ch, isExpanded: e)
            }
            obj.lane = max(0, anchor.lane + dl)

            placed.append(placeClip(obj, snapshot: snapshot, excludingGroups: excluded))
        }

        for obj in placed { resolveOverlaps(for: obj.id) }
        selectedIDs = Set(placed.map(\.id))
        isDirty = true
    }

    /// Places the fragments of an alt-translate of a time selection (a copy):
    /// a shift of (dt, dl display lanes) then routing through placeClip (top-level or a group).
    func placeTranslatedFragments(_ frags: [SoundObject], dt: Double, dl: Int) -> Set<UUID> {
        let snapshot = laneEntries
        var placed: [SoundObject] = []
        for frag in frags {
            let f = makeCopy(frag,
                             startTime: max(0, frag.startTime + dt),
                             lane: max(0, frag.lane + dl))
            placed.append(placeClip(f, snapshot: snapshot))
        }
        for obj in placed { resolveOverlaps(for: obj.id) }
        return Set(placed.map(\.id))
    }

    func duplicateSelected() {
        if let sel = timeSelection {
            // ── The time-selection branch ─────────────────────────────────────────
            let lo  = sel.timeRange.lowerBound
            let hi  = sel.timeRange.upperBound
            let dur = hi - lo

            let fragments = makeTimeSelectionFragments(lo: lo, hi: hi, lanes: sel.lanes)
            guard !fragments.isEmpty else { return }

            let snapshot = laneEntries
            var placed: [SoundObject] = []

            batchItemsMutation {
                // Two stages: all the copies first (the origin → copy table must cover
                // the whole batch), then laying them down once the sends are rewired onto the copies.
                var idMap: [UUID: UUID] = [:]
                var copies: [SoundObject] = []
                for frag in fragments {
                    // makeCopy recursively shifts ALL the descendants (sub-groups included)
                    // by the same delta (hi - lo); indispensable ever since the fragments
                    // started including nested sub-groups.
                    copies.append(makeCopy(frag, startTime: hi + (frag.startTime - lo),
                                           lane: frag.lane, idMap: &idMap))
                }
                for copy in copies {
                    placed.append(placeClip(Self.remappingSends(copy, using: idMap),
                                            snapshot: snapshot))
                }
            }
            resyncAllSends()

            sanitizeInfiniteConflicts(newlyPlaced: placed.map(\.id))
            for obj in placed { resolveOverlaps(for: obj.id) }
            selectedIDs = Set(placed.map(\.id))
            seekRequest = hi + dur
            timeSelection = TimeSelection(timeRange: hi...(hi + dur), lanes: sel.lanes)

        } else {
            // ── The item-selection branch ─────────────────────────────────────────
            guard !selectedIDs.isEmpty else { return }

            let entries = laneEntries.filter { effectiveSelectedIDs.contains($0.item.id) }
            guard !entries.isEmpty else { return }

            let originTime = entries.map(\.absStart).min()!
            let endTime    = entries.map { $0.absStart + $0.item.duration }.max()!
            let snapshot   = laneEntries
            var added:      [SoundObject] = []
            var maxAbsEnd:  Double        = endTime

            batchItemsMutation {
                // Two stages, like the time-selection branch: the copies first (a complete origin →
                // copy table), then laying them down with the sends rewired onto the copies.
                var idMap: [UUID: UUID] = [:]
                var copies: [SoundObject] = []
                for entry in entries {
                    let newAbsStart = endTime + (entry.absStart - originTime)
                    copies.append(makeCopy(entry.item, startTime: newAbsStart,
                                           lane: entry.displayLane, idMap: &idMap))
                    maxAbsEnd = max(maxAbsEnd, newAbsStart + entry.item.duration)
                }
                for copy in copies {
                    added.append(placeClip(Self.remappingSends(copy, using: idMap),
                                           snapshot: snapshot))
                }
            }
            resyncAllSends()

            sanitizeInfiniteConflicts(newlyPlaced: added.map(\.id))
            // Every kind, as with paste (resolveOverlaps handles clips, MIDI, auxes and groups).
            for dup in added { resolveOverlaps(for: dup.id) }
            selectedIDs = Set(added.map(\.id))
            seekRequest = maxAbsEnd
        }
    }
}

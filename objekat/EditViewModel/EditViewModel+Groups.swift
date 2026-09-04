import Foundation

extension EditViewModel {

    // MARK: - Internal engine sync

    /// Pushes the group's window to the engine (the [start,end] bounds + fades) onto the
    /// window+fade plugin at the end of the folder's chain. Restores the non-destructive windowing of
    /// the old ContainerClip + the bus fade (post-returns). To be called at creation, at
    /// move/resize (through syncPosition) and at a change of fade.
    /// A group marked INFINITE ignores its bounds: a [0, ∞) window with no fades — its inside
    /// is open onto the whole timeline (like an infinite aux, see `syncAuxWindow`). Without this the
    /// folder's gate went on cutting the children at the group's old bounds.
    func syncGroupWindow(_ group: SoundObject) {
        guard case .group = group.kind else { return }
        if group.isInfinite {
            // No window = nothing to overrun: the loop means nothing here, even if the
            // model still carried it (@see setObjectInfinite, which turns it off along the way).
            engine?.updateGroupWindow(group.id.uuidString,
                                      start: 0, end: Self.infiniteWindowEnd,
                                      fadeIn: 0, fadeOut: 0, loopEnabled: false,
                                      loopStart: 0, loopEnd: 0)
        } else {
            // IN/OUT bounds converted into ABSOLUTE EDIT seconds (+ startTime): the model carries
            // them LOCALLY (0 = the start of the group), but a group's container has its own
            // start as its offset — local time = EDIT time, and its children live there at their
            // absolute position. Giving the range in local terms therefore pointed at a region of the timeline where
            // there is nothing (the group fell entirely silent as soon as it did not start at 0).
            // @see SoundObject.loopRangeStart, refreshContainerSpanForKey:, [[loop-item-plan]]
            engine?.updateGroupWindow(group.id.uuidString,
                                      start: group.startTime,
                                      end: group.startTime + group.duration,
                                      fadeIn: group.fadeIn,
                                      fadeOut: group.fadeOut, loopEnabled: group.loopEnabled,
                                      loopStart: group.startTime + (group.loopRangeStart ?? 0),
                                      loopEnd: group.startTime + (group.loopRangeEnd ?? group.duration))
        }
    }

    /// Rebuilds a group in the engine on the folder model: a submix FolderTrack,
    /// its child clips moved into it (each on its own track, at an absolute position), its sub-groups
    /// = nested folders. `absoluteParentStart` is no longer used (absolute positions);
    /// kept for the callers' compatibility.
    func syncAddGroup(_ group: SoundObject,
                      children: [SoundObject],
                      parentGroupID: String?,
                      absoluteParentStart: Double) {
        guard let engine else { return }

        // The group is a ContainerClip laid on the track of ITS lane (the parent's when it
        // is nested: it will be moved into the parent container just afterwards anyway).
        engine.createGroupFolder(group.id.uuidString, lane: group.lane)
        // The bus fader (gain/pan) = an ObjGainPlugin on the folder.
        engine.updateVolume(engineVolume(for: group), pan: group.pan,
                            forID: group.id.uuidString)
        // The group's window (bounds) + fades = the window+fade plugin at the end of the folder's chain.
        syncGroupWindow(group)

        // Children: each object is born on a track of the pool at its absolute position, then is
        // moved into the container; a sub-group = a nested container (recursion).
        for child in children {
            switch child.kind {
            case .clip:
                // the GROUP's lane: the clip is born on a track that already exists, before being
                // moved into the container (its model lane is relative to the group).
                engineAddClip(child, lane: group.lane)
                engine.assignObject(child.id.uuidString, toGroupFolder: group.id.uuidString)
                syncSends(child)
            case .midiClip:
                // the GROUP's lane, like a clip: the MIDI object is born on a track that already
                // exists, before being moved into the container.
                engineAddMidiClip(child, lane: group.lane)
                engine.assignObject(child.id.uuidString, toGroupFolder: group.id.uuidString)
                syncSends(child)
            case .aux:
                // the GROUP's lane, as for a clip: the aux only passes through an
                // existing track before assignObject moves it into the container.
                engineAddAux(child, lane: group.lane)
                engine.assignObject(child.id.uuidString, toGroupFolder: group.id.uuidString)
            case .group(let grandchildren, _):
                syncAddGroup(child, children: grandchildren,
                             parentGroupID: group.id.uuidString,
                             absoluteParentStart: group.startTime)
            }
        }

        // The routing of the folder ITSELF: into the parent folder (nesting) or into its stem.
        // Done AFTER the children are added → the children follow the folder as it moves.
        if let parentID = parentGroupID {
            engine.assignObject(group.id.uuidString, toGroupFolder: parentID)
        } else if let sid = group.stemID {
            engine.assignObjects([group.id.uuidString], toStemID: sid.uuidString)
        }

        if group.needsChainCompile { syncPlugins(group) }
        // The sends of the group ITSELF (a group can send towards an aux). Idempotent; if
        // the target aux does not exist yet (a full rebuild), addSend is a no-op and
        // resyncAllSends rewires at the end of the load/undo.
        syncSends(group)

        // A second pass over the children: a send is only wired between siblings, so a
        // sender listed BEFORE the aux it aims at failed on the first round. Idempotent.
        for child in children where !child.sends.isEmpty { syncSends(child) }
    }

    func allDescendantEngineIDs(of children: [SoundObject]) -> [String] {
        var ids: [String] = []
        for child in children {
            ids.append(child.id.uuidString)
            if case .group(let grandchildren, _) = child.kind {
                ids.append(contentsOf: allDescendantEngineIDs(of: grandchildren))
            }
        }
        return ids
    }

    /// The IMMEDIATE parent group of an object, at any depth of
    /// nesting (nil if the object is top-level). The parent's startTime
    /// returned is absolute (the model's convention).
    func parentGroup(for childID: UUID) -> SoundObject? {
        func search(in arr: [SoundObject]) -> SoundObject? {
            for item in arr {
                guard case .group(let children, _) = item.kind else { continue }
                if children.contains(where: { $0.id == childID }) { return item }
                if let found = search(in: children) { return found }
            }
            return nil
        }
        return search(in: items)
    }

    /// True if `nodeID` is `ancestorID` itself or one of its descendants.
    func isSelfOrDescendant(_ nodeID: UUID, of ancestorID: UUID) -> Bool {
        if nodeID == ancestorID { return true }
        var p = parentGroup(for: nodeID)
        while let g = p {
            if g.id == ancestorID { return true }
            p = parentGroup(for: g.id)
        }
        return false
    }

    // MARK: - Adding a child (model + engine)

    func addChild(_ child: SoundObject, toGroupID: UUID) {
        guard let group = find(id: toGroupID) else { return }
        var child = child
        child.stemID = group.stemID
        // …and its WHOLE sub-tree: a descendant has no bus of its own, it follows the root
        // group. Without the recursion, an incoming sub-group kept the bus it came from
        // in its own children — invisible until you read the scope of a send,
        // which is read from the stemID. @see assignStem
        if case .group(let grandchildren, let isExpanded) = child.kind {
            child.kind = .group(children: Self.propagatingStemID(group.stemID, in: grandchildren),
                                isExpanded: isExpanded)
        }
        update(id: toGroupID) { obj in
            guard case .group(let children, let isExpanded) = obj.kind else { return }
            obj.kind = .group(children: children + [child], isExpanded: isExpanded)
        }
        switch child.kind {
        case .clip:
            engineAddClip(child)   // the clip is absolute on its track
            engine?.assignObject(child.id.uuidString, toGroupFolder: toGroupID.uuidString)
            syncSends(child)
        case .midiClip:
            engineAddMidiClip(child)
            engine?.assignObject(child.id.uuidString, toGroupFolder: toGroupID.uuidString)
            syncSends(child)
        case .aux:
            engineAddAux(child)
            engine?.assignObject(child.id.uuidString, toGroupFolder: toGroupID.uuidString)
        case .group(let grandchildren, _):
            // A child group: a nested folder + a recursive sync of the descendants.
            syncAddGroup(child, children: grandchildren,
                         parentGroupID: toGroupID.uuidString,
                         absoluteParentStart: group.startTime)
        }
        // The carrying plugins have just been born (and the sends just wired): the sub-tree's curves
        // are to be pushed again, as `syncAdd` does for a top-level object.
        pushAutomationTree(child)
        isDirty = true
    }

    // MARK: - Creating a group

    /// The open group whose band of sub-lanes contains ALL the target display lanes
    /// (the innermost one when nested); nil if the selection overruns to the root.
    /// This is the time selection's "where am I", the same rule as `placeClip`.
    func containerGroupEntry(forDisplayLanes lanes: Set<Int>) -> LaneEntry? {
        guard !lanes.isEmpty else { return nil }
        return laneEntries
            .filter { e in
                guard e.item.showsChildrenInline else { return false }
                let lo = e.displayLane + 1
                let hi = e.displayLane + e.item.childLaneCount
                return lanes.allSatisfy { $0 >= lo && $0 <= hi }
            }
            .max(by: { $0.displayLane < $1.displayLane })
    }

    func createGroupFromTimeSelection(_ sel: TimeSelection) {
        let t1 = sel.timeRange.lowerBound
        let t2 = sel.timeRange.upperBound
        guard t2 > t1 else { return }

        // A selection entirely INSIDE an open group → the new group is born inside it, as
        // the aux and the MIDI clip already are through `placeClip`. Without this, encapsulating a selection taken
        // inside a group manufactured a top-level group (empty, since the target objects
        // are children) laid alongside — you left the group without having asked to.
        if let container = containerGroupEntry(forDisplayLanes: sel.lanes) {
            createGroupFromTimeSelection(sel, inGroupEntry: container)
            return
        }

        // sel.lanes = display lanes. The TOP-LEVEL objects (audio clips, MIDI clips,
        // auxes — not groups) whose display lane is in the selection are grouped: an open group
        // shifts the display lanes of the items below it, so comparing obj.lane (a base
        // lane) to sel.lanes would be wrong. An object overlapping a bound is split first
        // (audio, MIDI note-aware, aux); only the part entirely inside the selection comes in.
        func topLevelClipIDsInSelection() -> [UUID] {
            laneEntries.compactMap { e in
                guard e.parentID == nil,
                      e.item.isClip || e.item.isMIDI || e.item.isAux,
                      sel.lanes.contains(e.displayLane) else { return nil }
                return e.item.id
            }
        }

        // The group's bus: asked for BEFORE the first split, so that "Cancel" does not leave
        // already cut objects behind it. The halves coming out of the splits carry the bus of
        // the object they came from — questioning the original objects comes to the same thing.
        let candidates = topLevelClipIDsInSelection().compactMap { find(id: $0) }
            .filter { $0.startTime < t2 && $0.startTime + $0.duration > t1 }
        guard case .stem(let groupStem) = stemForNewGroup(from: candidates) else { return }

        pushUndo()

        // Splitting the clips crossing the bounds. The list is recomputed after each pass:
        // _splitInternal creates a new top-level item on the same lane.
        for id in topLevelClipIDsInSelection() {
            guard let c = find(id: id),
                  c.startTime < t1, c.startTime + c.duration > t1 else { continue }
            _ = _splitInternal(id: id, atTime: t1)
        }
        for id in topLevelClipIDsInSelection() {
            guard let c = find(id: id),
                  c.startTime < t2, c.startTime + c.duration > t2 else { continue }
            _ = _splitInternal(id: id, atTime: t2)
        }

        let inside: [SoundObject] = topLevelClipIDsInSelection().compactMap { id in
            guard let c = find(id: id),
                  c.startTime >= t1, c.startTime + c.duration <= t2 else { return nil }
            return c
        }

        // The group's lane = the base lane of the top of the selection; baseLaneForDisplay handles the
        // shift of open groups for the (rare) case of a selection with no clip.
        let minChildLane = inside.map(\.lane).min() ?? baseLaneForDisplay(sel.lanes.min() ?? 0)
        // Captures the plugin state BEFORE the engine removal further down (otherwise syncAddGroup
        // recreates them at their default values). See copiedPlugins / withCapturedPluginStates.
        let children: [SoundObject] = Self.propagatingStemID(groupStem, in: inside.map { clip in
            var c = withCapturedPluginStates(clip); c.lane -= minChildLane; return c
        })

        let insideIDs = Set(inside.map(\.id))
        for clip in inside { engine?.removeSoundObject(withID: clip.id.uuidString) }
        items.removeAll { insideIDs.contains($0.id) }
        selectedIDs.subtract(insideIDs)

        let group = SoundObject(
            startTime: t1, duration: t2 - t1,
            lane: minChildLane,
            stemID: groupStem,
            kind: .group(children: children, isExpanded: false)
        )
        items.append(group)
        syncAdd(group)
        // The group's bus may have changed the scope of a send. @see canRouteSend
        resyncAllSends()
        selectedIDs = [group.id]
        timeSelection = nil
        isDirty = true
    }

    /// The same gesture as `createGroupFromTimeSelection`, but the selection is taken INSIDE an open
    /// group: its direct children are encapsulated (not the top-level objects, which are not
    /// in this group) and the resulting sub-group stays inside the parent.
    private func createGroupFromTimeSelection(_ sel: TimeSelection, inGroupEntry container: LaneEntry) {
        let t1       = sel.timeRange.lowerBound
        let t2       = sel.timeRange.upperBound
        let parentID = container.item.id

        // The DIRECT children of the group whose display lane is in the selection. Re-read on each pass:
        // a split inserts a new child on the same lane (see `_splitInternal`, case 2). Sub-groups
        // are excluded, as at the top level.
        func childIDsInSelection() -> [UUID] {
            laneEntries.compactMap { e in
                guard e.parentID == parentID,
                      e.item.isClip || e.item.isMIDI || e.item.isAux,
                      sel.lanes.contains(e.displayLane) else { return nil }
                return e.item.id
            }
        }

        pushUndo()

        for id in childIDsInSelection() {
            guard let c = find(id: id),
                  c.startTime < t1, c.startTime + c.duration > t1 else { continue }
            _ = _splitInternal(id: id, atTime: t1)
        }
        for id in childIDsInSelection() {
            guard let c = find(id: id),
                  c.startTime < t2, c.startTime + c.duration > t2 else { continue }
            _ = _splitInternal(id: id, atTime: t2)
        }

        let insideIDs = Set(childIDsInSelection().filter { id in
            guard let c = find(id: id) else { return false }
            return c.startTime >= t1 && c.startTime + c.duration <= t2
        })

        // A selection with no child at all: the sub-group is born all the same (empty), on the top lane of
        // the selection brought back into the parent's coordinates — the same stance as at the top level.
        let fallbackLane = max(0, (sel.lanes.min() ?? 0) - (container.displayLane + 1))
        guard let newID = makeSubgroup(from: insideIDs, in: parentID,
                                       bounds: t1...t2, fallbackLane: fallbackLane) else { return }
        selectedIDs   = [newID]
        timeSelection = nil
        isDirty       = true
    }

    func createGroup(from ids: Set<UUID>) {
        // The selected top-level items: clips AND groups.
        let members = items.filter { ids.contains($0.id) }
        guard !members.isEmpty else { return }

        // The group's bus: that of the members if they share it, otherwise we ask. Decided BEFORE
        // any mutation — the question can be answered "Cancel". @see stemForNewGroup
        guard case .stem(let groupStem) = stemForNewGroup(from: members) else { return }

        pushUndo()

        let groupStart   = members.map(\.startTime).min()!
        let groupEnd     = members.map { $0.startTime + $0.duration }.max()!
        let groupLane    = members.min(by: { $0.startTime < $1.startTime })?.lane ?? 0
        let minChildLane = members.map(\.lane).min() ?? 0

        // Children: their lane relative to the new group, their startTime kept (absolute), their bus aligned on
        // the group's (a child has no bus of its own). The groups included keep their
        // own children/isExpanded. Captures the plugin state BEFORE removeFromEngine (otherwise
        // syncAddGroup recreates them at their default values).
        let children: [SoundObject] = Self.propagatingStemID(groupStem, in: members.map { m in
            var c = withCapturedPluginStates(m); c.lane -= minChildLane; return c
        })

        // Engine removal (removeFromEngine handles a clip AND a group = descendants + folder),
        // then the model. syncAdd rebuilds the whole sub-tree on the folder model.
        for m in members {
            if let obj = find(id: m.id) { removeFromEngine(obj) }
        }
        items.removeAll { ids.contains($0.id) }
        selectedIDs.subtract(ids)

        let group = SoundObject(
            startTime: groupStart,
            duration: groupEnd - groupStart,
            lane: groupLane,
            stemID: groupStem,
            kind: .group(children: children, isExpanded: false)
        )
        items.append(group)
        syncAdd(group)
        // The group's bus may have changed the scope of a send (it is read from the stem at the
        // top level). resyncAllSends reconciles both ways. @see canRouteSend
        resyncAllSends()
        isDirty = true
    }

    /// The cmd+G entry point on an item selection (outside a TimeSelection).
    /// Routes: a sub-group inside a common parent, otherwise a top-level group (the existing one).
    func createGroupFromSelection(_ ids: Set<UUID>) {
        // An item one of whose ANCESTORS is itself selected already leaves with that ancestor:
        // keeping it would make two different parents count (the group and the root) and would send
        // everybody back to the top level — the new group was then born outside the group being
        // worked in. The same convention as `effectiveSelectedIDs`.
        let members: Set<UUID> = ids.filter { id in
            var ancestor = parentGroup(for: id)
            while let a = ancestor {
                if ids.contains(a.id) { return false }
                ancestor = parentGroup(for: a.id)
            }
            return true
        }
        guard !members.isEmpty else { return }
        let parentIDs = Set(members.map { parentGroup(for: $0)?.id })
        if parentIDs.count == 1, let common = parentIDs.first, let commonParent = common {
            createGroup(from: members, in: commonParent)   // all children of ONE SAME group
        } else {
            createGroup(from: members)                     // top-level or a mixture → unchanged
        }
    }

    /// cmd+G on children of ONE SAME group: creates a sub-group INSIDE the parent.
    func createGroup(from ids: Set<UUID>, in parentID: UUID) {
        guard let parent = find(id: parentID),
              case .group(let parentChildren, _) = parent.kind,
              parentChildren.contains(where: { ids.contains($0.id) }) else { return }
        pushUndo()
        guard let newID = makeSubgroup(from: ids, in: parentID,
                                       bounds: nil, fallbackLane: 0) else { return }
        selectedIDs = [newID]
        isDirty = true
    }

    /// Manufactures a sub-group INSIDE `parentID` from its direct children `ids` (already
    /// split if need be). `bounds` imposes the group's bounds (the time-selection case);
    /// nil = the span of the children kept. `fallbackLane` serves when no child is kept.
    /// Does NOT push an undo: the caller did so before its own mutations.
    @discardableResult
    private func makeSubgroup(from ids: Set<UUID>, in parentID: UUID,
                              bounds: ClosedRange<Double>?, fallbackLane: Int) -> UUID? {
        guard let parent = find(id: parentID),
              case .group(let parentChildren, _) = parent.kind else { return nil }
        let selected = parentChildren.filter { ids.contains($0.id) }
        guard bounds != nil || !selected.isEmpty else { return nil }

        // Children in absolute startTime: the sub-group's bounds.
        let groupStart = bounds?.lowerBound ?? selected.map(\.startTime).min()!
        let groupEnd   = bounds?.upperBound ?? selected.map { $0.startTime + $0.duration }.max()!
        let minLane    = selected.map(\.lane).min() ?? fallbackLane   // lanes relative to the parent

        // The sub-group's children: their lane relative to the sub-group, their startTime kept (absolute).
        // Captures the plugin state BEFORE removeFromEngine (a re-sync through addChild otherwise defaults).
        let subChildren: [SoundObject] = selected.map { child in
            var c = withCapturedPluginStates(child); c.lane -= minLane; c.stemID = nil; return c
        }

        // Removing the selected children from the parent (the engine first — they are still nested —
        // then the model).
        for child in selected {
            if let obj = find(id: child.id) { removeFromEngine(obj) }
        }
        update(id: parentID) { obj in
            guard case .group(let children, let isExpanded) = obj.kind else { return }
            obj.kind = .group(children: children.filter { !ids.contains($0.id) },
                              isExpanded: isExpanded)
        }
        selectedIDs.subtract(ids)

        // The sub-group: its lane relative to the parent, its startTime absolute; addChild re-syncs the engine.
        let subgroup = SoundObject(
            startTime: groupStart,
            duration: groupEnd - groupStart,
            lane: minLane,
            kind: .group(children: subChildren, isExpanded: false)
        )
        addChild(subgroup, toGroupID: parentID)
        return subgroup.id
    }

    // MARK: - Dissolving a group

    func disbandGroup(id: UUID) {
        guard let group = find(id: id),
              case .group(let children, _) = group.kind else { return }
        guard !isBaking(id) else { return }   // a bake under way: the sub-tree is locked
        pushUndo()

        // The children's tracks PERSIST: disbandGroupFolder brings the direct members up
        // to the folder's parent (the enclosing folder, the stem, or the root) and deletes the folder.
        // No engine re-sync → no capture/restoration of plugins needed.
        let directChildIDs = children.map { $0.id.uuidString }
        engine?.disbandGroupFolder(id.uuidString, memberIDs: directChildIDs)

        // Model: the children brought up. Their lane made absolute (+ group.lane), their startTime already absolute,
        // their stemID aligned on the group's (consistent with the engine: they inherit the parent folder's).
        let restored: [SoundObject] = children.map {
            var c = $0; c.lane += group.lane; c.stemID = group.stemID; return c
        }

        // The group took up only ONE model lane; its content claims as many as its
        // lowest inner row. The unfolded children therefore fell onto the lanes of what
        // lived below — an invisible stacking for as long as the group existed (unfolded, the
        // room was made for it by `expandedSpan`, which counts for the DISPLAY only). So
        // everything that follows is pushed down by the number of lanes added: the
        // layout stays the one that was in front of your eyes before dissolving.
        let extraLanes = max(0, children.map(\.lane).max() ?? 0)

        if let parent = parentGroup(for: id) {
            update(id: parent.id) { obj in
                guard case .group(let pChildren, let isExpanded) = obj.kind else { return }
                let pushed = pChildren.filter { $0.id != id }.map { sib -> SoundObject in
                    guard sib.lane > group.lane else { return sib }
                    var s = sib; s.lane += extraLanes; return s
                }
                obj.kind = .group(children: pushed + restored, isExpanded: isExpanded)
            }
        } else {
            removeFromItems(id: id)
            if extraLanes > 0 {
                for i in items.indices where items[i].lane > group.lane {
                    items[i].lane += extraLanes
                }
            }
            items.append(contentsOf: restored)
        }
        // The membership has changed: a send between siblings can become routable or stop
        // being so. resyncAllSends reconciles both ways.
        resyncAllSends()
        isDirty = true
    }

    // MARK: - Expansion

    func toggleGroupExpansion(id: UUID) {
        // The automation band is open: it takes the children's place. Toggling `isExpanded`
        // would then change nothing on screen — the gesture would look dead. The content is given back
        // first, the unfolded state being found again as it was left.
        if find(id: id)?.automationOpen == true {
            setAutomationOpen(id: id, false)
            return
        }
        let willExpand = !isGroupExpanded(id)
        update(id: id) { obj in
            guard case .group(let children, let isExpanded) = obj.kind else { return }
            obj.kind = .group(children: children, isExpanded: !isExpanded)
        }
        // Two groups open on the SAME lane unfold their insides onto the same band of
        // sub-lanes: the two contents overlap and neither is legible any more. As long as there
        // is no stacking of the bands, exclusivity settles it — opening one closes the
        // neighbour. Nothing to do with nesting: a group INSIDE a group stays possible,
        // only siblings on the same lane exclude each other.
        if willExpand { collapseGroupsSharingLane(with: id) }
    }

    /// Closes the open groups sharing `id`'s lane inside the same container
    /// (siblings in `items` at the first level, siblings of the same child list otherwise).
    private func collapseGroupsSharingLane(with id: UUID) {
        guard let target = find(id: id) else { return }
        let siblings: [SoundObject]
        if let parent = parentGroup(for: id), case .group(let children, _) = parent.kind {
            siblings = children
        } else {
            siblings = items
        }
        for sibling in siblings where sibling.id != id && sibling.lane == target.lane {
            // `showsChildrenInline`: a sibling switched to automation already no longer shows its
            // children. Folding its `isExpanded` behind its back would be invisible at the time and
            // would be discovered later, on coming back to the content — a group closed for no reason.
            guard sibling.showsChildrenInline else { continue }
            update(id: sibling.id) { obj in
                guard case .group(let children, _) = obj.kind else { return }
                obj.kind = .group(children: children, isExpanded: false)
            }
        }
    }

    func isGroupExpanded(_ id: UUID) -> Bool {
        guard let item = find(id: id), case .group(_, let e) = item.kind else { return false }
        return e
    }

    // MARK: - Moves (drag)

    func reparentToGroup(
        clipIDs: Set<UUID>, groupID: UUID,
        anchors: [UUID: (start: Double, lane: Int)],
        grabbedID: UUID, grabbedChildLane: Int, dt: Double
    ) {
        guard let group = find(id: groupID), case .group = group.kind else { return }
        guard let grabbedBaseLane = anchors[grabbedID]?.lane else { return }

        var moved: [SoundObject] = []
        for clipID in clipIDs {
            guard let obj = find(id: clipID), let anchor = anchors[clipID] else { continue }
            if isSelfOrDescendant(groupID, of: clipID) { continue }   // anti-cycle
            var child = withCapturedPluginStates(obj)   // freezes the state before the engine round trip
            let newStart = max(0, anchor.start + dt)
            let dStart   = newStart - obj.startTime
            child.startTime = newStart
            child.lane = max(0, grabbedChildLane + (anchor.lane - grabbedBaseLane))
            child.stemID = group.stemID
            if case .group(var gch, let e) = child.kind, dStart != 0 {
                EditViewModel.shiftStartTimes(&gch, by: dStart)
                child.kind = .group(children: gch, isExpanded: e)
            }
            moved.append(child)
        }
        guard !moved.isEmpty else { return }

        let movedIDs = Set(moved.map(\.id))
        for id in movedIDs {
            if let obj = find(id: id) { removeFromEngine(obj) }   // the original top level
            removeFromItems(id: id)
        }
        selectedIDs.subtract(movedIDs)

        for child in moved { addChild(child, toGroupID: groupID) }
        for child in moved { resolveOverlaps(for: child.id) }
        // The membership has changed: a send between siblings can become routable or stop
        // being so. resyncAllSends reconciles both ways.
        resyncAllSends()
        isDirty = true
    }

    func ejectFromGroup(
        childIDs: Set<UUID>, groupID: UUID,
        anchors: [UUID: (start: Double, lane: Int)],
        grabbedID: UUID, dt: Double, baseLane: Int
    ) {
        guard let group = find(id: groupID),
              case .group(let children, let isExpanded) = group.kind else { return }
        guard let grabbedBaseLane = anchors[grabbedID]?.lane else { return }

        var ejected: [SoundObject] = []
        for childID in childIDs {
            guard let child = children.first(where: { $0.id == childID }),
                  let anchor = anchors[childID] else { continue }
            var top = withCapturedPluginStates(child)   // freezes the state before the engine round trip
            let newStart = max(0, anchor.start + dt)
            let dStart   = newStart - child.startTime
            top.startTime = newStart
            top.lane = max(0, baseLane + (anchor.lane - grabbedBaseLane))
            if case .group(var gch, let e) = top.kind, dStart != 0 {
                EditViewModel.shiftStartTimes(&gch, by: dStart)
                top.kind = .group(children: gch, isExpanded: e)
            }
            ejected.append(top)
        }

        // Engine removal of the sub-tree BEFORE mutating the model (removeFromEngine: the track for
        // a clip, descendants + folder for a group).
        for childID in childIDs {
            if let obj = find(id: childID) { removeFromEngine(obj) }
        }
        update(id: groupID) { obj in
            obj.kind = .group(children: children.filter { !childIDs.contains($0.id) },
                              isExpanded: isExpanded)
        }
        for obj in ejected {
            items.append(obj)
            syncAdd(obj)
            if obj.isClip || obj.isMIDI {
                engine?.updateFade(in: obj.fadeIn, fadeOut: obj.fadeOut, forID: obj.id.uuidString)
            }
        }
        // The membership has changed: a send between siblings can become routable or stop
        // being so. resyncAllSends reconciles both ways.
        resyncAllSends()
        isDirty = true
    }

    func reparentChildBetweenGroups(
        childIDs: Set<UUID>, sourceGroupID: UUID, targetGroupID: UUID,
        anchors: [UUID: (start: Double, lane: Int)],
        grabbedID: UUID, grabbedChildLane: Int, dt: Double
    ) {
        guard let source = find(id: sourceGroupID),
              case .group(let srcChildren, _) = source.kind,
              let target = find(id: targetGroupID), case .group = target.kind else { return }
        guard let grabbedBaseLane = anchors[grabbedID]?.lane else { return }

        var moved: [SoundObject] = []
        for childID in childIDs {
            guard let child = srcChildren.first(where: { $0.id == childID }),
                  let anchor = anchors[childID] else { continue }
            if isSelfOrDescendant(targetGroupID, of: childID) { continue }   // anti-cycle
            var c = withCapturedPluginStates(child)   // freezes the state before the engine round trip
            let newStart = max(0, anchor.start + dt)
            let dStart   = newStart - child.startTime
            c.startTime = newStart
            c.lane = max(0, grabbedChildLane + (anchor.lane - grabbedBaseLane))
            c.stemID = target.stemID
            if case .group(var gch, let e) = c.kind, dStart != 0 {
                EditViewModel.shiftStartTimes(&gch, by: dStart)
                c.kind = .group(children: gch, isExpanded: e)
            }
            moved.append(c)
        }
        guard !moved.isEmpty else { return }
        let movedIDs = Set(moved.map(\.id))

        // Engine removal of the sub-tree BEFORE mutating the model (still in the source).
        for id in movedIDs {
            if let obj = find(id: id) { removeFromEngine(obj) }
        }
        update(id: sourceGroupID) { obj in
            guard case .group(let children, let isExpanded) = obj.kind else { return }
            obj.kind = .group(children: children.filter { !movedIDs.contains($0.id) },
                              isExpanded: isExpanded)
        }
        for child in moved { addChild(child, toGroupID: targetGroupID) }
        for child in moved { resolveOverlaps(for: child.id) }
        // The membership has changed: a send between siblings can become routable or stop
        // being so. resyncAllSends reconciles both ways.
        resyncAllSends()
        isDirty = true
    }

    // MARK: - Alt-copy from a group

    @discardableResult
    func altEjectFromGroup(
        childIDs: Set<UUID>, groupID: UUID,
        anchors: [UUID: (start: Double, lane: Int)],
        grabbedID: UUID, dt: Double, baseLane: Int
    ) -> Set<UUID> {
        guard let group = find(id: groupID),
              case .group(let children, _) = group.kind else { return [] }
        guard let grabbedBaseLane = anchors[grabbedID]?.lane else { return [] }
        var copies: [SoundObject] = []
        for childID in childIDs {
            guard let child = children.first(where: { $0.id == childID }),
                  let anchor = anchors[childID] else { continue }
            copies.append(makeAltCopy(child,
                startTime: max(0, anchor.start + dt),
                lane: max(0, baseLane + (anchor.lane - grabbedBaseLane))))
        }
        for obj in copies { add(obj) }
        // Every kind, as with paste (resolveOverlaps handles clips, MIDI, auxes and groups).
        for obj in copies { resolveOverlaps(for: obj.id) }
        // The membership has changed: a send between siblings can become routable or stop
        // being so. resyncAllSends reconciles both ways.
        resyncAllSends()
        isDirty = true
        return Set(copies.map(\.id))
    }

    @discardableResult
    func altReparentChildBetweenGroups(
        childIDs: Set<UUID>, sourceGroupID: UUID, targetGroupID: UUID,
        anchors: [UUID: (start: Double, lane: Int)],
        grabbedID: UUID, grabbedChildLane: Int, dt: Double
    ) -> Set<UUID> {
        guard let source = find(id: sourceGroupID),
              case .group(let srcChildren, _) = source.kind,
              find(id: targetGroupID) != nil else { return [] }
        guard let grabbedBaseLane = anchors[grabbedID]?.lane else { return [] }
        var copies: [SoundObject] = []
        for childID in childIDs {
            guard let child = srcChildren.first(where: { $0.id == childID }),
                  let anchor = anchors[childID] else { continue }
            let copyStart = max(0, anchor.start + dt)
            copies.append(makeAltCopy(child,
                startTime: copyStart,
                lane: max(0, grabbedChildLane + (anchor.lane - grabbedBaseLane))))
        }
        for copy in copies { addChild(copy, toGroupID: targetGroupID) }
        for copy in copies { resolveOverlaps(for: copy.id) }
        // The membership has changed: a send between siblings can become routable or stop
        // being so. resyncAllSends reconciles both ways.
        resyncAllSends()
        isDirty = true
        return Set(copies.map(\.id))
    }

    @discardableResult
    func altCopyChildrenInGroup(
        childIDs: Set<UUID>, groupID: UUID,
        anchors: [UUID: (start: Double, lane: Int)],
        grabbedID: UUID, dt: Double, dl: Int
    ) -> Set<UUID> {
        guard let group = find(id: groupID),
              case .group(let children, _) = group.kind else { return [] }
        var copies: [SoundObject] = []
        for childID in childIDs {
            guard let child = children.first(where: { $0.id == childID }),
                  let anchor = anchors[childID] else { continue }
            copies.append(makeAltCopy(child,
                startTime: max(0, anchor.start + dt),
                lane: max(0, anchor.lane + dl)))
        }
        for copy in copies { addChild(copy, toGroupID: groupID) }
        for copy in copies { resolveOverlaps(for: copy.id) }
        // The membership has changed: a send between siblings can become routable or stop
        // being so. resyncAllSends reconciles both ways.
        resyncAllSends()
        isDirty = true
        return Set(copies.map(\.id))
    }
}

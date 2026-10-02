import Foundation

// MARK: - The release of a MOVE (clips and groups, no time selection)
//
// The drag handler used to hold all of this in `handleCanvasDrag`'s `phase == .ended`. It lives
// here so that the gesture AND a script (`debug.move_drop`, DEBUG only) go through the very same
// code — the nested-drop fault of 2 October 2026 could only be replayed headless that way. WHERE
// the objects land is decided by the pure `MoveDropResolution`; this function only carries the
// decision out through the existing primitives (reparent / eject / move in the group / root move),
// each of which owns its own crossfade refit, overlap settling, engine sync and send resync.

extension EditViewModel {

    /// Lets go of a move of `anchors` carried by `dt` seconds and `dl` DISPLAY rows.
    ///
    /// - `grabbedDisplayLane`: the row the grabbed block was drawn on when the hand took it.
    /// - `sourceGroupID`: the group the moved objects are children of (nil = root objects).
    /// - Returns what was done. `.cancel` = a drop onto the moved objects' own subtree: nothing
    ///   was touched and NO undo point was pushed. Otherwise exactly ONE undo point is pushed,
    ///   BEFORE the first change (the project's undo convention).
    @discardableResult
    func commitMoveDrop(ids: Set<UUID>,
                        anchors: [UUID: (start: Double, lane: Int)],
                        grabbedID: UUID,
                        grabbedDisplayLane: Int,
                        sourceGroupID: UUID?,
                        isAltCopy: Bool,
                        dt: Double, dl: Int) -> MoveDropResolution.Decision {
        guard let grabbedAnchor = anchors[grabbedID] else { return .cancel }
        let row = MoveDropResolution.finalRow(grabbedDisplayLane: grabbedDisplayLane, dl: dl)

        // The open groups whose band holds the row — nothing else matters to the resolution.
        var openGroups: [MoveDropResolution.OpenGroup] = []
        for e in laneEntries where e.item.showsChildrenInline {
            let span = e.item.childLaneCount
            let cl = row - e.displayLane - 1
            guard cl >= 0 && cl < span else { continue }
            var kids: [MoveDropResolution.Lane] = []
            if case .group(let children, _) = e.item.kind {
                kids = children.map { MoveDropResolution.Lane(lane: $0.lane, span: $0.expandedSpan) }
            }
            openGroups.append(MoveDropResolution.OpenGroup(
                id: e.item.id, displayLane: e.displayLane, childLaneCount: span,
                isMoved: ids.contains { isSelfOrDescendant(e.item.id, of: $0) },
                children: kids))
        }
        let decision = MoveDropResolution.resolve(
            row: row,
            sourceGroupID: sourceGroupID,
            // An ⌥ copy from the ROOT lands on the root only (it always did); from inside a group
            // it may enter another group.
            allowsGroupTarget: !isAltCopy || sourceGroupID != nil,
            openGroups: openGroups,
            rootSiblings: items.map { MoveDropResolution.Lane(lane: $0.lane, span: $0.expandedSpan) })

        switch decision {
        case .cancel:
            return decision

        case .reparent(let groupID, let lane):
            pushUndo()
            if let sgID = sourceGroupID {
                if isAltCopy {
                    selectedIDs = altReparentChildBetweenGroups(
                        childIDs: ids, sourceGroupID: sgID, targetGroupID: groupID,
                        anchors: anchors, grabbedID: grabbedID,
                        grabbedChildLane: lane, dt: dt)
                } else {
                    reparentChildBetweenGroups(
                        childIDs: ids, sourceGroupID: sgID, targetGroupID: groupID,
                        anchors: anchors, grabbedID: grabbedID,
                        grabbedChildLane: lane, dt: dt)
                }
            } else {
                reparentToGroup(
                    clipIDs: ids, groupID: groupID,
                    anchors: anchors, grabbedID: grabbedID,
                    grabbedChildLane: lane, dt: dt)
            }

        case .eject(let rootLane):
            guard let sgID = sourceGroupID else { return .cancel }
            pushUndo()
            if isAltCopy {
                selectedIDs = altEjectFromGroup(
                    childIDs: ids, groupID: sgID,
                    anchors: anchors, grabbedID: grabbedID,
                    dt: dt, baseLane: rootLane)
            } else {
                ejectFromGroup(
                    childIDs: ids, groupID: sgID,
                    anchors: anchors, grabbedID: grabbedID, dt: dt,
                    baseLane: rootLane)
            }

        case .moveInSource(let lane):
            guard let sgID = sourceGroupID else { return .cancel }
            pushUndo()
            // The grabbed object's travel in MODEL lanes of the source group's frame: every
            // anchor keeps its own model gap to it, whatever open sub-groups lie between them.
            let dLane = lane - grabbedAnchor.lane
            if isAltCopy {
                selectedIDs = altCopyChildrenInGroup(
                    childIDs: ids, groupID: sgID,
                    anchors: anchors, grabbedID: grabbedID,
                    dt: dt, dl: dLane)
            } else {
                // The crossfades FOLLOW: the zone is the span the two have in common,
                // and moving one of them changes that span, nothing more. What is refitted
                // is then invisible to `resolveOverlaps` below; what is not, it settles.
                withCrossfadeRefit(around: ids) {
                    for (id, anchor) in anchors {
                        // Children of ONE group: no wall at 0 (@see ZeroClamp).
                        let newStart = anchor.start + dt
                        update(id: id) { item in
                            let d = newStart - item.startTime
                            item.startTime = newStart
                            if case .group(var children, let isExpanded) = item.kind, d != 0 {
                                EditViewModel.shiftStartTimes(&children, by: d)
                                item.kind = .group(children: children, isExpanded: isExpanded)
                            }
                        }
                        updateLane(id: id, lane: max(0, anchor.lane + dLane))
                        if let obj = find(id: id) { syncPosition(obj) }
                    }
                }
                for id in anchors.keys { resolveOverlaps(for: id) }
            }

        case .root(let lane):
            pushUndo()
            // `lane` is the root lane of the row under the hand; the grabbed object's travel in
            // root MODEL lanes carries every anchor with its own gap.
            let dActual = lane - grabbedAnchor.lane
            if isAltCopy {
                var copies: [SoundObject] = []
                for (id, anchor) in anchors {
                    guard let obj = find(id: id) else { continue }
                    copies.append(makeAltCopy(obj,
                                              startTime: anchor.start + dt,
                                              lane: max(0, anchor.lane + dActual)))
                }
                for obj in copies { add(obj) }
                for obj in copies where { if case .clip = obj.kind { return true }; return false }() {
                    resolveOverlaps(for: obj.id)
                }
                selectedIDs = Set(copies.map(\.id))
            } else {
                // The crossfades FOLLOW the objects that carry them (@see refitCrossfade).
                withCrossfadeRefit(around: ids) {
                    for (id, anchor) in anchors {
                        updateStartTime(id: id, newStart: anchor.start + dt)
                        updateLane(id: id, lane: max(0, anchor.lane + dActual))
                    }
                }
                for id in anchors.keys { resolveOverlaps(for: id) }
            }
        }
        return decision
    }
}

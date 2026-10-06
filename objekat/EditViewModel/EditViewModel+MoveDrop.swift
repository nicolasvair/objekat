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
    /// - `insertionRow`: the block was let go in the GAP before this display row (@see
    ///   LaneInsertion): the objects are INSERTED there — the lanes below go down, the lanes the
    ///   selection empties close up — instead of being dropped on a lane. Re-planned here from the
    ///   real model; nil, or a plan that no longer holds, is the normal drop.
    /// - Returns what was done. `.cancel` = a drop onto the moved objects' own subtree: nothing
    ///   was touched and NO undo point was pushed. Otherwise exactly ONE undo point is pushed,
    ///   BEFORE the first change (the project's undo convention) — an insertion included: its
    ///   shift of the neighbours and the drop itself are the same undo step.
    @discardableResult
    func commitMoveDrop(ids: Set<UUID>,
                        anchors rawAnchors: [UUID: (start: Double, lane: Int)],
                        grabbedID: UUID,
                        grabbedDisplayLane: Int,
                        sourceGroupID: UUID?,
                        isAltCopy: Bool,
                        dt: Double, dl: Int,
                        insertionRow: Int? = nil) -> MoveDropResolution.Decision {
        guard rawAnchors[grabbedID] != nil else { return .cancel }

        // An insertion hands the primitives the selection brought to RANKS (0, 1, 2… without
        // holes) and the base lane `plan.lane + rank(grabbed)`: every one of them places an anchor
        // at `base + (anchor.lane − grabbed.lane)`, i.e. exactly `plan.lane + rank`.
        var anchors = rawAnchors
        var plan: LaneInsertion.Plan? = nil
        let decision: MoveDropResolution.Decision
        if let ir = insertionRow,
           let p = laneInsertionPlan(row: ir, ids: ids, anchors: rawAnchors,
                                     sourceGroupID: sourceGroupID, isAltCopy: isAltCopy) {
            plan = p
            let ranks = LaneInsertion.movedRanks(rawAnchors.mapValues { $0.lane })
            anchors = rawAnchors.reduce(into: [:]) { out, kv in
                out[kv.key] = (start: kv.value.start, lane: ranks[kv.key] ?? 0)
            }
            let lane = p.lane + (ranks[grabbedID] ?? 0)
            if let target = p.parentID {
                decision = target == sourceGroupID ? .moveInSource(lane: lane)
                                                   : .reparent(groupID: target, lane: lane)
            } else {
                decision = sourceGroupID == nil ? .root(lane: lane) : .eject(rootLane: lane)
            }
        } else {
            decision = resolveMoveDrop(ids: ids, grabbedDisplayLane: grabbedDisplayLane,
                                       sourceGroupID: sourceGroupID, isAltCopy: isAltCopy, dl: dl)
        }
        guard let grabbedAnchor = anchors[grabbedID] else { return .cancel }

        // Nothing is touched before the guards: a `cancel`, or a decision that needs a source
        // group the objects do not have, leaves no undo point behind.
        switch decision {
        case .cancel: return decision
        case .eject, .moveInSource: if sourceGroupID == nil { return .cancel }
        case .reparent, .root: break
        }
        pushUndo()
        if let p = plan { applyLaneChanges(p.laneChanges) }

        switch decision {
        case .cancel:
            return decision

        case .reparent(let groupID, let lane):
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
                // `dt` is ONE travel, already snapped by the gesture off the grabbed object (and
                // already stopped by the wall at 0): it is applied as is to every anchor, NEVER
                // re-snapped per object — that rounded each start to its own grid line and broke
                // the gaps between the moved objects (@see updateStartTime's `snap`).
                withCrossfadeRefit(around: ids) {
                    for (id, anchor) in anchors {
                        updateStartTime(id: id, newStart: anchor.start + dt, snap: false)
                        updateLane(id: id, lane: max(0, anchor.lane + dActual))
                    }
                }
                for id in anchors.keys { resolveOverlaps(for: id) }
            }
        }
        return decision
    }

    /// The normal drop's decision: WHERE the release lands, from the row under the hand
    /// (@see MoveDropResolution). Extracted unchanged from `commitMoveDrop`.
    private func resolveMoveDrop(ids: Set<UUID>, grabbedDisplayLane: Int, sourceGroupID: UUID?,
                                 isAltCopy: Bool, dl: Int) -> MoveDropResolution.Decision {
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
        return MoveDropResolution.resolve(
            row: row,
            sourceGroupID: sourceGroupID,
            // An ⌥ copy from the ROOT lands on the root only (it always did); from inside a group
            // it may enter another group.
            allowsGroupTarget: !isAltCopy || sourceGroupID != nil,
            openGroups: openGroups,
            rootSiblings: items.map { MoveDropResolution.Lane(lane: $0.lane, span: $0.expandedSpan) })
    }
}

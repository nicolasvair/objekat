import Foundation

// MARK: - Inserting a move BETWEEN two lanes
//
// The rule itself is pure (`LaneInsertion`, asserted by `tools/test_lane_insertion.swift`). This
// file only flattens what the model knows into its `Sibling`s and `Frame`s, and carries the
// plan's lane changes out. The objects THEMSELVES are placed by the very primitives the normal
// drop uses (`commitMoveDrop`), which is why none of the refit / overlap / send / engine work is
// duplicated here.

extension EditViewModel {

    /// What inserting the moved objects BEFORE display row `row` would do, or nil when the normal
    /// drop applies (nothing below to push, a row inside a piano roll, the moved group's own
    /// band…). Read off the real model at the moment of the call: the drag handler may cache it
    /// per `(row, ⌥)`, but the release always asks again.
    func laneInsertionPlan(row: Int,
                           ids: Set<UUID>,
                           anchors: [UUID: (start: Double, lane: Int)],
                           sourceGroupID: UUID?,
                           isAltCopy: Bool) -> LaneInsertion.Plan? {
        guard row >= 0, !ids.isEmpty else { return nil }
        let frames = laneInsertionFrames(row: row, ids: ids, sourceGroupID: sourceGroupID,
                                         isAltCopy: isAltCopy)
        var movedLanes: [UUID: Int] = [:]
        for id in ids { if let a = anchors[id] { movedLanes[id] = a.lane } }

        return LaneInsertion.plan(
            boundaryRow: row, openGroups: frames.openGroups, root: frames.root, source: frames.source,
            movedLanes: movedLanes, isCopy: isAltCopy,
            // An ⌥ copy from the ROOT lands on the root only (as `commitMoveDrop` always said).
            allowsGroupTarget: !isAltCopy || sourceGroupID != nil)
    }

    /// What inserting `laneCount` NEW lanes before display row `row` would do for FILES let go there
    /// (the drop from the Finder or from the library: they come from nowhere, nothing closes up), or
    /// nil when the normal drop applies — nothing below to push, a row inside a piano roll or an
    /// automation band, or a consolidated object open (its stage is protected, @see
    /// sessionMoveDropGate: files laid in it go where the normal drop puts them). Asked by the hover
    /// (the line and the ghost) and asked again by the drop, from the real model.
    func fileDropInsertionPlan(row: Int, laneCount: Int) -> LaneInsertion.Plan? {
        guard row >= 0, laneCount > 0, consolidateEditStack.isEmpty else { return nil }
        let frames = laneInsertionFrames(row: row, ids: [], sourceGroupID: nil, isAltCopy: false)
        return LaneInsertion.insertPlan(boundaryRow: row, openGroups: frames.openGroups,
                                        root: frames.root, laneCount: laneCount)
    }

    /// The lanes of the root and of the open groups whose band may hold `row`, flattened into the
    /// pure rule's `Frame`s (what both plans above read), plus the frame the moved objects come
    /// from. `ids` are the moved objects (none for a file drop).
    private func laneInsertionFrames(row: Int,
                                     ids: Set<UUID>,
                                     sourceGroupID: UUID?,
                                     isAltCopy: Bool)
        -> (openGroups: [LaneInsertion.Frame], root: LaneInsertion.Frame, source: LaneInsertion.Frame?) {

        func siblings(of children: [SoundObject], parentID: UUID?) -> [LaneInsertion.Sibling] {
            var out = children.map {
                LaneInsertion.Sibling(id: $0.id, lane: $0.lane, span: $0.expandedSpan,
                                      isMoved: !isAltCopy && ids.contains($0.id))
            }
            // A comment is a sibling of its frame that never moves and unfolds nothing: it is
            // pushed like an object, and a lane that carries one is never closed.
            for c in comments where c.parentID == parentID {
                out.append(LaneInsertion.Sibling(id: c.id, lane: c.lane, span: 0, isMoved: false))
            }
            return out
        }

        // The open groups whose band holds the row (the same walk as `commitMoveDrop`).
        var openGroups: [LaneInsertion.Frame] = []
        for e in laneEntries where e.item.showsChildrenInline {
            let span = e.item.childLaneCount
            let cl = row - e.displayLane - 1
            guard cl >= 0 && cl < span else { continue }
            var kids: [SoundObject] = []
            if case .group(let children, _) = e.item.kind { kids = children }
            openGroups.append(LaneInsertion.Frame(
                parentID: e.item.id, origin: e.displayLane + 1, rowCount: span,
                isMoved: ids.contains { isSelfOrDescendant(e.item.id, of: $0) },
                siblings: siblings(of: kids, parentID: e.item.id)))
        }
        let root = LaneInsertion.Frame(parentID: nil, origin: 0, rowCount: Int.max,
                                       siblings: siblings(of: items, parentID: nil))
        var source: LaneInsertion.Frame? = root
        if let sg = sourceGroupID {
            if let g = find(id: sg), case .group(let children, _) = g.kind {
                source = LaneInsertion.Frame(parentID: sg, origin: 0, rowCount: Int.max,
                                             siblings: siblings(of: children, parentID: sg))
            } else {
                source = nil
            }
        }
        return (openGroups, root, source)
    }

    /// Carries out the lane changes of a plan — objects AND comments — in ONE batch (a single
    /// rebuild of the lane cache). No undo point here: the caller pushed its own, before.
    /// Does not read `laneEntries` inside the batch.
    func applyLaneChanges(_ changes: [UUID: Int]) {
        guard !changes.isEmpty else { return }
        batchItemsMutation {
            for (id, lane) in changes {
                if let i = comments.firstIndex(where: { $0.id == id }) {
                    comments[i].lane = max(0, lane)
                } else {
                    updateLane(id: id, lane: lane)
                }
            }
        }
        isDirty = true
    }
}

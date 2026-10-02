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
        var movedLanes: [UUID: Int] = [:]
        for id in ids { if let a = anchors[id] { movedLanes[id] = a.lane } }

        return LaneInsertion.plan(
            boundaryRow: row, openGroups: openGroups, root: root, source: source,
            movedLanes: movedLanes, isCopy: isAltCopy,
            // An ⌥ copy from the ROOT lands on the root only (as `commitMoveDrop` always said).
            allowsGroupTarget: !isAltCopy || sourceGroupID != nil)
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

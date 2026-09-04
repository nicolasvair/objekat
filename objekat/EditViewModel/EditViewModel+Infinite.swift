import Foundation

// MARK: - "Infinite" bus (an aux / group with no start/end)
//
// An aux or a group can be marked "infinite": it loses its start/end window and spans the WHOLE
// project, becoming a "normal" processing bus (e.g. a reverb active from beginning to end, or a
// permanent group submix). Reserved for the TOP LEVEL (a bus that runs the length of the
// timeline) and to ONE PER LANE — two infinites on the same row is impossible.

extension EditViewModel {

    /// True if there is ALREADY an infinite bus on this top-level lane (`excluding` aside).
    func laneHasInfiniteBus(lane: Int, excluding id: UUID? = nil) -> Bool {
        items.contains { $0.lane == lane && $0.id != id && $0.isInfiniteBus }
    }

    /// True if infinite can be turned on for `id`: a top-level aux/group. A neighbour already infinite
    /// is no longer an obstacle — the new bus gets a row of its own (see `moveInfiniteBusToOwnLane`).
    func canMakeInfinite(_ id: UUID) -> Bool {
        guard let obj = find(id: id), obj.canBeInfinite,
              items.contains(where: { $0.id == id }) else { return false }   // top level only
        return true
    }

    /// Turns infinite on / off for a top-level aux or group.
    func setObjectInfinite(id: UUID, on: Bool) {
        guard let obj = find(id: id), obj.canBeInfinite else { return }
        // An infinite is a top-level bus (it runs the length of the timeline): no infinite on a
        // child of a group.
        guard items.contains(where: { $0.id == id }) else {
            bakeAlert(L("infinite.error.title"), L("infinite.error.info"))
            return
        }
        guard obj.isInfinite != on else { return }
        pushUndo()
        update(id: id) {
            $0.isInfinite = on
            // An infinite no longer has a window (nothing to overrun): the loop no longer means anything
            // (@see SoundObject.canLoop, [[loop-item-plan]]).
            if on { $0.loopEnabled = false }
        }
        // An infinite bus takes up the full width of its row: it would cover whatever was already
        // there. So it is given ITS row, inserted just below (the bus stays where the eye expects
        // it, its former neighbours keep theirs). Nothing to do if it was already alone there.
        if on { moveInfiniteBusToOwnLane(id: id) }
        // Applied to the engine: aux and group alike open/close their gate window
        // (infinite ↔ real start/end). For a group it is the folder's ObjWindowFade gate:
        // without this push, the inside of a group turned infinite stayed cut at the old bounds.
        if let updated = find(id: id) {
            if updated.isAux { syncAuxWindow(updated) } else { syncGroupWindow(updated) }
        }
        isDirty = true
    }

    /// Moves an infinite bus onto an EMPTY row, inserted just under its current one: every
    /// top-level object on the following rows moves down a notch. A no-op if it is already alone on
    /// its own. No undo of its own: called inside `setObjectInfinite`'s transaction.
    func moveInfiniteBusToOwnLane(id: UUID) {
        guard let obj = find(id: id), items.contains(where: { $0.id == id }) else { return }
        let lane = obj.lane
        guard items.contains(where: { $0.id != id && $0.lane == lane }) else { return }
        batchItemsMutation {
            for other in items where other.id != id && other.lane > lane {
                update(id: other.id) { $0.lane += 1 }
            }
            update(id: id) { $0.lane = lane + 1 }
        }
    }

    /// Toggles infinite (context menu / inspector).
    func toggleObjectInfinite(id: UUID) {
        guard let obj = find(id: id) else { return }
        setObjectInfinite(id: id, on: !obj.isInfinite)
    }

    /// After a paste / a duplication: gives ITS row to every freshly placed infinite bus that
    /// lands on an already occupied row — an infinite bus covers the full width, two on the same
    /// row would overlap. It keeps its infinite (before, it lost it and went back to being a
    /// bounded aux/group). To be called in the same transaction as the placement (no undo of its own).
    /// Returns the buses that were moved.
    @discardableResult
    func sanitizeInfiniteConflicts(newlyPlaced ids: [UUID]) -> [UUID] {
        var moved: [UUID] = []
        for id in ids {
            guard let obj = find(id: id), obj.isInfiniteBus,
                  items.contains(where: { $0.id == id }) else { continue }
            if items.contains(where: { $0.lane == obj.lane && $0.id != id }) {
                moveInfiniteBusToOwnLane(id: id)
                moved.append(id)
            }
        }
        return moved
    }
}

import Foundation

extension EditViewModel {

    // MARK: - Selection

    func selectAll() {
        // A contextual Cmd+A: if we are "inside" a group (a child selected, or the
        // caret laid within the group's lane range) → selects its direct children.
        if let group = contextGroup(), case .group(let children, _) = group.kind {
            selectedIDs = Set(children.map(\.id))
            timeSelection = nil
            return
        }
        selectedIDs = Set(items.map(\.id))
    }

    /// The "current" group for a contextual Cmd+A, or nil if we are at the root level.
    /// - From the selection: if every selected item shares the same immediate
    ///   parent group (not the root), that is the one.
    /// - Otherwise, with no selection: the expanded group whose display-lane range
    ///   contains `caretLane` (the deepest one when nested).
    func contextGroup() -> SoundObject? {
        if !selectedIDs.isEmpty {
            let parentIDs = Set(selectedIDs.map { parentGroup(for: $0)?.id })
            if parentIDs.count == 1, let pid = parentIDs.first, let pid {
                return find(id: pid)
            }
            return nil
        }
        if let cl = caretLane {
            return laneEntries
                .filter { e in
                    // `showsChildrenInline`: a group switched to automation no longer shows its
                    // children — so its band can no longer serve as context for ⌘A, otherwise the
                    // shortcut would select invisible objects.
                    guard e.item.showsChildrenInline else { return false }
                    return cl >= e.displayLane + 1 && cl <= e.displayLane + e.item.childLaneCount
                }
                .max(by: { $0.displayLane < $1.displayLane })?
                .item
        }
        return nil
    }

    func select(_ id: UUID?, additive: Bool = false) {
        // Any selection of OBJECTS puts a selected crossfade out: the two are exclusive, and
        // there is exactly one place that says so rather than one per call site.
        selectedCrossfade = nil
        guard let id else { clearSelection(); return }
        if additive {
            if selectedIDs.contains(id) { selectedIDs.remove(id) }
            else { selectedIDs.insert(id) }
        } else {
            selectedIDs = [id]
        }
    }

    func selectIDs(_ ids: Set<UUID>) { selectedCrossfade = nil; selectedIDs = ids }

    /// Moves the SELECTION one displayed row up (`-1`) or down (`+1`). The selection alone: not one
    /// object moves, nothing sounds different, and no undo is pushed — this is the eye walking down
    /// the timeline, not the hand editing it. (Moving the MATTER between lanes is the drag, and ⌥⌫
    /// and the rest; nothing here touches it.)
    ///
    /// Three rules, all of them about what "the row above" means when the timeline is not a grid:
    ///
    ///   - it walks DISPLAY rows, so an open group's children are rows like any other — the eye
    ///     sees them, the arrow visits them;
    ///   - an EMPTY row is stepped over rather than stopping the walk. A row with nothing on it
    ///     cannot hold a selection, and stopping there would mean pressing the key twice for a gap
    ///     one can see is empty;
    ///   - on arriving, the object taken is the one that SHARES TIME with the one left behind, and
    ///     failing that the nearest in time. Anything else would send the selection to the start of
    ///     the row, miles from what one was looking at.
    ///
    /// With several objects selected, the row one leaves from is the FAR EDGE of the selection in
    /// the direction asked — so a second press goes on in the same direction rather than coming
    /// back inside the block one has just left.
    ///
    /// Returns the object now selected, nil when the walk found nothing (the edge of the content).
    @discardableResult
    func stepSelectionLane(by delta: Int) -> UUID? {
        guard delta != 0 else { return nil }
        let held = laneEntries.filter { selectedIDs.contains($0.item.id) }
        guard let from = delta < 0 ? held.min(by: { $0.displayLane < $1.displayLane })
                                   : held.max(by: { $0.displayLane < $1.displayLane })
        else { return nil }

        let anchorStart = from.absStart
        let anchorEnd   = from.absStart + from.item.duration
        // 0 = they share time, otherwise the gap between them. An infinite bus spans everything,
        // so it always shares.
        func gap(_ e: LaneEntry) -> Double {
            if e.item.isInfiniteBus { return 0 }
            let s = e.absStart, t = e.absStart + e.item.duration
            if t >= anchorStart && s <= anchorEnd { return 0 }
            return s > anchorEnd ? s - anchorEnd : anchorStart - t
        }

        guard let lastRow = laneEntries.map(\.displayLane).max() else { return nil }
        var row = from.displayLane + delta
        while row >= 0 && row <= lastRow {
            let onRow = laneEntries.filter { $0.displayLane == row }
            if let best = onRow.min(by: { a, b in
                let ga = gap(a), gb = gap(b)
                if ga != gb { return ga < gb }
                // Both share the time: the one whose start is nearest, so the eye lands where it
                // was looking rather than at the row's first object.
                return abs(a.absStart - anchorStart) < abs(b.absStart - anchorStart)
            }) {
                selectIDs([best.item.id])
                return best.item.id
            }
            row += delta
        }
        return nil
    }

    /// Selects a marker, a region or a comment — exclusive with the objects, the crossfade, the
    /// time range and the notes, so that ⌫ and ⌘R have exactly one thing in front of them.
    /// @see AnnotationSel, which says why this is a slot of its own.
    func selectAnnotation(_ sel: AnnotationSel?) {
        selectedIDs = []
        selectedCrossfade = nil
        timeSelection = nil
        selectedMidiNoteIDs = []
        selectedAnnotation = sel
    }

    /// Selects a crossfade — the zone, not its two objects. Exclusive with the object selection,
    /// so ⌫ can mean "this crossfade" without ever meaning "these two objects" as well.
    func selectCrossfade(left: UUID, right: UUID) {
        selectedIDs = []
        timeSelection = nil
        selectedMidiNoteIDs = []
        selectedAnnotation = nil
        selectedCrossfade = (left, right)
    }

    func clearSelection() {
        selectedCrossfade = nil
        selectedIDs = []
        timeSelection = nil
        selectedAnnotation = nil
    }

    /// The effective IDs for multi-item operations: excludes any item one of whose direct
    /// ancestors is itself selected (avoids a double move / double copy).
    var effectiveSelectedIDs: Set<UUID> {
        let selected = selectedIDs
        return selected.filter { id in
            // Excluded if ANY ancestor (parent, grandparent…) is selected.
            var ancestor = parentGroup(for: id)
            while let a = ancestor {
                if selected.contains(a.id) { return false }
                ancestor = parentGroup(for: a.id)
            }
            return true
        }
    }

    /// Returns the current TimeSelection, or the bounding box of the selected items.
    func baseTimeSelection() -> TimeSelection? {
        if let existing = timeSelection { return existing }
        let selected = items.filter { selectedIDs.contains($0.id) }
        guard let tMin = selected.map(\.startTime).min(),
              let tMax = selected.map({ $0.startTime + $0.duration }).max(),
              let lMin = selected.map(\.lane).min(),
              let lMax = selected.map(\.lane).max() else { return nil }
        return TimeSelection(timeRange: tMin...tMax, lanes: Set(lMin...lMax))
    }
}

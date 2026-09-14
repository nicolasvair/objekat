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

    /// Moves the TIME SELECTION one displayed row up (`-1`) or down (`+1`) — the passage travels
    /// across the lanes while keeping the same span of time, and NOTHING moves with it: no object
    /// changes lane, nothing sounds different, no undo is pushed. This is the frame one has traced
    /// being slid onto another lane, not an edit. (Moving the MATTER is the drag, ⌥⌫ and the rest.)
    ///
    /// The selection keeps its HEIGHT: a range traced across three rows stays three rows tall.
    ///
    /// It travels over DISPLAY rows, and EMPTY ones are rows like any other — unlike an object
    /// selection, a time range on an empty lane means something (it is where a paste lands, where a
    /// comment is laid). So the walk does not skip anything, and it stops at the two ends: row 0 at
    /// the top, and at the bottom the last row the timeline actually draws — one free row under the
    /// lowest object, the group children and the open bands counted in. At the edge nothing moves
    /// and the selection is kept.
    ///
    /// Returns true when it did travel.
    @discardableResult
    func stepTimeSelectionLanes(by delta: Int) -> Bool {
        guard delta != 0, let sel = timeSelection,
              let lo = sel.lanes.min(), let hi = sel.lanes.max() else { return false }

        // The last row the canvas draws: one row past the lowest object, plus everything unfolded
        // above it. @see TimelineView.visibleLanes, of which this is the model-side half.
        let lastRow = displayLane(forBase: (items.map(\.lane).max() ?? 0) + 1)
        let step = delta < 0 ? max(delta, -lo) : min(delta, lastRow - hi)
        guard step != 0 else { return false }

        timeSelection = TimeSelection(timeRange: sel.timeRange,
                                      lanes: Set(sel.lanes.map { $0 + step }))
        caretLane = lo + step
        return true
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

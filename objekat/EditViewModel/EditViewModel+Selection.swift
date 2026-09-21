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
    /// With OBJECTS selected and no range traced, the frame is the one the objects FILL (@see
    /// `selectedObjectsFrame`): an object is a passage one can see, so one selects it rather than
    /// tracing over it — the same reading ⌥⌫ makes of an object selection. That first press
    /// materialises the frame AND moves it, in one step, and the objects are let go of: the frame
    /// has left them, and objects still selected under a range lying elsewhere would give ⌫ two
    /// answers. Nothing moves on the row they were on — this stays a gesture that edits nothing.
    ///
    /// Returns true when it did travel. At an end it returns false having touched NOTHING, the
    /// object selection included: a press that goes nowhere is a press that changes nothing.
    @discardableResult
    func stepTimeSelectionLanes(by delta: Int) -> Bool {
        guard delta != 0 else { return false }
        let adopting = timeSelection == nil
        guard let sel = timeSelection ?? selectedObjectsFrame(),
              let lo = sel.lanes.min(), let hi = sel.lanes.max() else { return false }

        // The last row the canvas draws: one row past the lowest object, plus everything unfolded
        // above it. @see TimelineView.visibleLanes, of which this is the model-side half.
        // A selection can legitimately sit BELOW it — one traces a range on the empty lanes the
        // canvas still covers down to the viewport's foot — so the room left underneath is clamped
        // at zero. Without that `lastRow - hi` goes negative and ↓ TELEPORTS the range upwards,
        // which is exactly what a bare `min(delta, …)` did.
        let lastRow = displayLane(forBase: (items.map(\.lane).max() ?? 0) + 1)
        let step = delta < 0 ? max(delta, -lo) : min(delta, max(0, lastRow - hi))
        guard step != 0 else { return false }

        // Adopted from an object selection: the objects are let go of as the frame leaves them.
        if adopting { selectedIDs = [] }
        timeSelection = TimeSelection(timeRange: sel.timeRange,
                                      lanes: Set(sel.lanes.map { $0 + step }))
        caretLane = lo + step
        // The row the passage is travelling TOWARDS — its leading edge, and not the caret's: a
        // range three rows tall pushed downwards is followed by its foot. @see pendingLaneReveal.
        pendingLaneReveal = delta < 0 ? lo + step : hi + step
        return true
    }

    /// Moves the INSERTION CARET one displayed row up (`-1`) or down (`+1`) — the case where
    /// NOTHING is selected: a plain click has laid a point of insertion, and the arrows walk THAT
    /// point across the rows instead of falling through every branch and beeping.
    ///
    /// The same road as the time selection (@see stepTimeSelectionLanes), and for the same
    /// reasons: DISPLAY rows, the empty ones counted (a caret on an empty lane is where a paste
    /// lands), stopping at row 0 and at the last row the timeline draws, and NO undo — a caret is
    /// where one is ABOUT to work, not something one has changed.
    ///
    /// The clamp is written as a step and not as a `min` on the target, for the trap the range
    /// hit: a caret laid in the bottom headroom sits BELOW `lastRow`, and a `min(…, lastRow)`
    /// would teleport it upwards instead of leaving it where it is.
    ///
    /// The ⇧-click origin travels WITH it, keeping its instant: the origin IS the point the last
    /// click laid the caret at (@see timeSelectionOrigin), so an origin left on the row one has
    /// just walked off would make the next ⇧-click trace a range from a row nobody is on.
    @discardableResult
    func stepCaretLane(by delta: Int) -> Bool {
        guard delta != 0, timeSelection == nil, selectedIDs.isEmpty, let lane = caretLane else {
            return false
        }
        let lastRow = displayLane(forBase: (items.map(\.lane).max() ?? 0) + 1)
        let step = delta < 0 ? max(delta, -lane) : min(delta, max(0, lastRow - lane))
        guard step != 0 else { return false }
        caretLane = lane + step
        pendingLaneReveal = lane + step      // it must stay in sight. @see pendingLaneReveal
        if let origin = timeSelectionOrigin {
            timeSelectionOrigin = (lane: lane + step, time: origin.time)
        }
        return true
    }

    /// The frame a set of selected OBJECTS fills: from the first one's start to the last one's end,
    /// over the DISPLAY rows they sit on — the rows, because that is the space the range travels
    /// in, and a child of an open group has no row of its own in the model's lanes.
    ///
    /// An INFINITE BUS is left out of it: its band has neither start nor end, and the window it
    /// still stores is not a passage anybody traced. A selection holding nothing else answers nil,
    /// and the arrows then do nothing rather than moving a frame nobody could see the sense of.
    func selectedObjectsFrame() -> TimeSelection? {
        let rows = laneEntries.filter { selectedIDs.contains($0.item.id) && !$0.item.isInfiniteBus }
        guard let t0 = rows.map(\.absStart).min(),
              let t1 = rows.map({ $0.absStart + $0.item.duration }).max(),
              let lo = rows.map(\.displayLane).min(),
              let hi = rows.map(\.displayLane).max() else { return nil }
        return TimeSelection(timeRange: t0...t1, lanes: Set(lo...hi))
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

    /// The origin a ⇧-click extends the time selection FROM, or nil when there is none to trust.
    ///
    /// SELF-VALIDATING rather than book-kept, and that is the whole reason it is a function: the
    /// anchor is good while nothing else has taken the selection over — either nothing at all is
    /// selected (the caret alone, which is the case ⇧ was missing entirely), or the range traced
    /// still hangs off this very point. A range made by a rubber band, or the bounding box read
    /// off an object selection, therefore answers nil and the old extension takes it (@see
    /// `TimelineView.handleCanvasTap`) — so no drag, no command and no undo has to remember to
    /// clear anything, which is exactly how a second anchor would go stale.
    func timeSelectionExtendOrigin() -> (lane: Int, time: Double)? {
        guard let a = timeSelectionOrigin else { return nil }
        guard let sel = timeSelection else { return baseTimeSelection() == nil ? a : nil }
        let onBound = abs(sel.timeRange.lowerBound - a.time) < 1e-9
                   || abs(sel.timeRange.upperBound - a.time) < 1e-9
        return onBound && sel.lanes.contains(a.lane) ? a : nil
    }
}

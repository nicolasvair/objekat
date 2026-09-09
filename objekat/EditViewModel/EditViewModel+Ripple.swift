import Foundation

// MARK: - Ripple editing, bounded by the container
//
// Removing a passage and closing the gap behind it: what came after slides back onto the hole's
// left edge. Reaper's "ripple edit", with one difference that is the whole point here — it is
// BOUNDED BY THE CONTAINER. Doing it inside a group moves every object OF THAT GROUP and nothing
// else: the group's neighbours, its parent and the rest of the timeline stay exactly where they
// are. A group is a closed world in time, so its inner montage can be reworked without the whole
// session sliding.
//
// Three decisions the gesture rests on, none of them obvious:
//
//  • ALL the lanes of the scope are hollowed out, not just those the time selection covered.
//    Ripple's reason for existing is to preserve the internal synchronisation: if an object on
//    another lane of the group straddled the hole and were spared, everything after it would
//    move away from it. Closing the gap therefore implies cutting the range everywhere it runs.
//  • The scope is the SHALLOWEST container the gesture touches. One top-level lane in the time
//    selection and the scope is the whole timeline — an unfolded group is then an object among
//    others, carried whole. The rule reads in one sentence, which is what one wants of a
//    destructive gesture.
//  • The container's own WINDOW shrinks by as much. Otherwise the gap comes back as silence at
//    the end of the group, and one would have to trim it by hand behind every ripple.

extension EditViewModel {

    /// The time remapping a ripple applies: what precedes the hole does not move, what follows it
    /// slides back by its length, and what falls INSIDE collapses onto its left edge.
    static func rippleMap(_ x: Double, removing lo: Double, _ hi: Double) -> Double {
        if x <= lo { return x }
        if x >= hi { return x - (hi - lo) }
        return lo
    }

    /// The container a ripple laid on these DISPLAY lanes acts in — `nil` = the whole timeline.
    /// The SHALLOWEST entry touched decides (@see the header): its parent is the scope.
    func rippleContainerID(forLanes lanes: Set<Int>) -> UUID? {
        var best: (depth: Int, parent: UUID?)? = nil
        for e in laneEntries where lanes.contains(e.displayLane) {
            if best == nil || e.depth < best!.depth { best = (e.depth, e.parentID) }
        }
        return best?.parent
    }

    /// Every display lane belonging to `container`'s sub-tree — `nil` = every lane there is.
    /// It is what widens a time selection to the whole scope before hollowing it out.
    func rippleLanes(in container: UUID?) -> Set<Int> {
        guard let container else { return Set(laneEntries.map(\.displayLane)) }
        var parentOf: [UUID: UUID?] = [:]
        for e in laneEntries { parentOf[e.item.id] = e.parentID }
        var lanes = Set<Int>()
        for e in laneEntries {
            var p = e.parentID
            while let pid = p {
                if pid == container { lanes.insert(e.displayLane); break }
                p = parentOf[pid] ?? nil
            }
        }
        return lanes
    }

    // MARK: - The primitive

    /// Takes the span [lo, hi] out of `container` and closes the gap: every lane of the scope is
    /// hollowed out, then what is left standing after `hi` comes back onto `lo`, and the
    /// container's own window shrinks by as much. `container == nil` ⇒ the whole timeline.
    ///
    /// Returns false if the gesture would change nothing (a degenerate range, an empty scope with
    /// nothing to slide) — the caller then drops its undo rather than leaving an empty step.
    ///
    /// Pushes NO undo and clears no selection: the caller owns the transaction, as with
    /// `carveTimeRange`, whose matter-removing work this reuses whole.
    @discardableResult
    func rippleRemoveTimeRange(lo: Double, hi: Double, container: UUID?) -> Bool {
        let hole = hi - lo
        guard hole > 0.001 else { return false }

        // A porthole scope is refused: the window of a LOOPING group is laid on a repeating
        // pattern, not on an edge (@see isLoopedGroupPorthole). Shortening the pattern under the
        // porthole would change every repeat at once, including those the gesture never touched.
        if let container, let obj = find(id: container), isLoopedGroupPorthole(obj) { return false }

        let lanes = rippleLanes(in: container)
        let carved = carveTimeRange(lo: lo, hi: hi, lanes: lanes, skippingInfiniteBuses: true)

        // AFTER the carve: it creates objects (the right half of a straddling object, laid down at
        // `hi`), and those are precisely the ones that have to slide.
        let toShift = rippleDirectChildren(of: container)
            .filter { !$0.isInfiniteBus && $0.startTime >= hi - 1e-6 }
            .map(\.id)

        guard carved || !toShift.isEmpty else { return false }

        batchItemsMutation {
            for id in toShift {
                update(id: id) { o in
                    o.startTime -= hole
                    // An object's own curves are held in time RELATIVE to it: they travel with it,
                    // there is nothing to rebase. Its children, on the other hand, carry ABSOLUTE
                    // starts and have to follow their group by hand (@see shiftStartTimes).
                    if case .group(var ch, let ex) = o.kind {
                        EditViewModel.shiftStartTimes(&ch, by: -hole)
                        o.kind = .group(children: ch, isExpanded: ex)
                    }
                }
            }
        }
        for id in toShift {
            if let o = find(id: id) { syncPosition(o) }
        }

        if let container { rippleShrinkContainer(container, lo: lo, hi: hi) }
        return true
    }

    /// The objects a ripple slides: the DIRECT children of the scope (their own descendants travel
    /// with them). `nil` = the top-level objects.
    private func rippleDirectChildren(of container: UUID?) -> [SoundObject] {
        guard let container else { return items }
        guard let obj = find(id: container), case .group(let children, _) = obj.kind else { return [] }
        return children
    }

    /// Shrinks the scope's own window by what the hole took from it, so that the gap is really
    /// closed rather than turned into silence at the end of the group. Nothing OUTSIDE moves: the
    /// group's neighbours and its parent keep their positions, only the group's end comes back.
    private func rippleShrinkContainer(_ id: UUID, lo: Double, hi: Double) {
        guard let obj = find(id: id) else { return }
        let s = obj.startTime, e = s + obj.duration
        let ns = Self.rippleMap(s, removing: lo, hi)
        let ne = Self.rippleMap(e, removing: lo, hi)
        // A hole that swallowed the whole group leaves an EMPTY group rather than none: making the
        // very container the gesture was aimed at vanish under one's hands would be a surprise, and
        // deleting it is one keystroke away.
        let dur = max(0.01, ne - ns)
        guard abs(ns - s) > 1e-9 || abs(dur - obj.duration) > 1e-9 else { return }

        update(id: id) { o in
            // The window's curves are spliced, not divided: the group keeps one identity, and its
            // automation has to lose the same slice as its content (@see splicedInTime). In time
            // relative to the object, hence the two bounds rebased on its OLD start.
            o.automation = o.automation.splicedInTime(removing: lo - s, to: hi - s)
            // A LOOPING container is refused upstream; a group whose loop is merely armed keeps
            // bounds expressed locally — remapped in ABSOLUTE terms, they stay opposite the same
            // material.
            if let a = o.loopRangeStart { o.loopRangeStart = Self.rippleMap(s + a, removing: lo, hi) - ns }
            if let b = o.loopRangeEnd   { o.loopRangeEnd   = Self.rippleMap(s + b, removing: lo, hi) - ns }
            o.startTime = ns
            o.duration  = dur
            o.fadeIn    = min(o.fadeIn, dur)
            o.fadeOut   = min(o.fadeOut, dur - o.fadeIn)
        }
        if let updated = find(id: id) { syncPosition(updated) }
    }

    // MARK: - The two gestures

    /// ⌥⌫ over a time selection: the passage goes, and the scope closes up behind it.
    func rippleDeleteTimeSelection() {
        guard let sel = timeSelection else { return }
        let lo = sel.timeRange.lowerBound
        let hi = sel.timeRange.upperBound
        let container = rippleContainerID(forLanes: sel.lanes)
        pushUndo()
        guard rippleRemoveTimeRange(lo: lo, hi: hi, container: container) else {
            _ = undoStack.popLast()
            return
        }
        selectedIDs   = []
        timeSelection = nil
        isDirty       = true
    }

    /// The hole an ⌥ cut-by-dragging would close: the half the gesture throws away, read off the
    /// object one GRABBED. Pulling right keeps the left, so what goes is [the cut → that object's
    /// end]; pulling left is its mirror image. `nil` if the object has gone or the half is empty.
    ///
    /// It is the grabbed object that gives the length, and not the widest of the selection: a
    /// gesture has one grip, and it is what one is holding that has to answer for what it does.
    func rippleCutRange(grabbedID: UUID, atTime t: Double, keeping: CutKeepSide) -> (lo: Double, hi: Double)? {
        guard let obj = find(id: grabbedID) else { return nil }
        let s = obj.startTime, e = s + obj.duration
        let range = keeping == .left ? (lo: t, hi: e) : (lo: s, hi: t)
        return range.hi > range.lo + 0.001 ? range : nil
    }

    /// ⌥ + cut by dragging: the half pulled away goes, and the scope closes up over its span. The
    /// scope is read the same way as for the time selection — the shallowest of the objects the
    /// cut aims at.
    func rippleCut(ids: [UUID], grabbedID: UUID, atTime t: Double, keeping: CutKeepSide) {
        guard let range = rippleCutRange(grabbedID: grabbedID, atTime: t, keeping: keeping) else { return }
        let lanes = Set(laneEntries.filter { ids.contains($0.item.id) }.map(\.displayLane))
        let container = rippleContainerID(forLanes: lanes)
        pushUndo()
        guard rippleRemoveTimeRange(lo: range.lo, hi: range.hi, container: container) else {
            _ = undoStack.popLast()
            return
        }
        selectedIDs   = []
        timeSelection = nil
        isDirty       = true
    }
}

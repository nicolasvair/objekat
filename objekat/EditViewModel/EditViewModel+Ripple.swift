import Foundation

// MARK: - Ripple editing, bounded by the container, aimed at the lanes one selected
//
// Removing a passage and closing the gap behind it: what came after slides back onto the hole's
// left edge. Reaper's "ripple edit", with one difference that is the whole point here — it is
// BOUNDED BY THE CONTAINER. Doing it inside a group moves objects OF THAT GROUP and nothing
// else: the group's neighbours, its parent and the rest of the timeline stay exactly where they
// are. A group is a closed world in time, so its inner montage can be reworked without the whole
// session sliding.
//
// Four decisions the gesture rests on, none of them obvious:
//
//  • ONLY the lanes one SELECTED are hollowed out and slide back — the lanes of the time
//    selection, or the lanes the selected / cut objects sit on. The other lanes of the container
//    stay exactly as they were. This is a DELIBERATE choice of the user, and it has a cost that
//    is written here so nobody discovers it by ear: until 29 September 2026 EVERY lane of the
//    scope was hollowed out, because ripple's reason for existing is to preserve the internal
//    synchronisation — an object on an unselected lane straddling the hole would otherwise be
//    spared while everything after it moved away from it. Now that lane is spared on purpose, so
//    **the synchronisation between the lanes is no longer guaranteed**: the ripple can pull the
//    selected lanes out of step with the ones left alone, and doing it on ALL the lanes is what
//    gives the old behaviour back.
//  • The scope is still the SHALLOWEST container the gesture touches. One top-level lane in the
//    time selection and the scope is the whole timeline — an unfolded group is then an object
//    among others, carried whole. The lanes are then intersected with the scope's: a selected lane
//    that lies outside it is left alone.
//  • What slides is decided per selected LANE, by unit: the shallowest object whose row is
//    selected, carried whole with everything under it (a group whose own row is selected is one
//    unit, its children rows or not). A sub-group only PARTIALLY selected — some of its children's
//    rows and not its own — keeps its window where it is, and the selected children slide inside
//    it in absolute time; the cost is that a child may slide out past the window's start.
//  • The container's own WINDOW shrinks by as much ONLY when every lane of the scope was selected
//    (which is the old behaviour, window included). Otherwise it does not move: the unselected
//    lanes still need the room, and shrinking would cut their tail.
//
// A row is named here by what it IS, not by where it is drawn — `RippleRow`, a parent and a base
// lane. The display lane of an object moves under the gesture's own hands (a group's rows follow
// the lanes its children occupy, and the carve can empty one), so the selection is translated
// into rows once, before anything is touched, and read back through them.

extension EditViewModel {

    /// The time remapping a ripple applies: what precedes the hole does not move, what follows it
    /// slides back by its length, and what falls INSIDE collapses onto its left edge.
    static func rippleMap(_ x: Double, removing lo: Double, _ hi: Double) -> Double {
        if x <= lo { return x }
        if x >= hi { return x - (hi - lo) }
        return lo
    }

    /// The container a ripple acts in — `nil` = the whole timeline. The SHALLOWEST entry it
    /// touches decides (@see the header): that entry's parent is the scope.
    ///
    /// ONE reading for the two ways of aiming a ripple. A time selection names display LANES and
    /// an object selection names OBJECTS, but the rule that turns either into a scope is the same
    /// sentence, and a rule a destructive gesture rests on is one to write once.
    private func rippleScope(touching: (LaneEntry) -> Bool) -> UUID? {
        var best: (depth: Int, parent: UUID?)? = nil
        for e in laneEntries where touching(e) {
            if best == nil || e.depth < best!.depth { best = (e.depth, e.parentID) }
        }
        return best?.parent
    }

    /// The scope of a ripple laid on these DISPLAY lanes.
    func rippleContainerID(forLanes lanes: Set<Int>) -> UUID? {
        rippleScope { lanes.contains($0.displayLane) }
    }

    /// A row of the timeline, named by what it is and not by where it is drawn: the object it hangs
    /// under (`nil` = the top level) and its BASE lane there. The display lane is a function of the
    /// whole structure and changes as the gesture proceeds; this one does not.
    struct RippleRow: Hashable {
        let parent: UUID?
        let lane: Int
    }

    /// The rows the given DISPLAY lanes name.
    func rippleRows(forLanes lanes: Set<Int>) -> Set<RippleRow> {
        Set(laneEntries.filter { lanes.contains($0.displayLane) }
            .map { RippleRow(parent: $0.parentID, lane: $0.item.lane) })
    }

    /// Every entry belonging to `container`'s sub-tree — `nil` = every entry there is.
    private func rippleScopeEntries(in container: UUID?) -> [LaneEntry] {
        guard let container else { return laneEntries }
        var parentOf: [UUID: UUID?] = [:]
        for e in laneEntries { parentOf[e.item.id] = e.parentID }
        var out: [LaneEntry] = []
        for e in laneEntries {
            var p = e.parentID
            while let pid = p {
                if pid == container { out.append(e); break }
                p = parentOf[pid] ?? nil
            }
        }
        return out
    }

    /// What a ripple aimed at `onLanes` really takes, inside `scope`: the entries on those lanes,
    /// and everything under one of them — an object whose row is selected is a unit, and the carve
    /// reaches its whole content (@see `carveTimeRange`, `_cutGroupChildren`).
    private func rippleTaken(scope: [LaneEntry], onLanes: Set<Int>, container: UUID?) -> [LaneEntry] {
        let byID = Dictionary(scope.map { ($0.item.id, $0) }, uniquingKeysWith: { a, _ in a })
        return scope.filter { e in
            var cur: LaneEntry? = e
            while let x = cur {
                if onLanes.contains(x.displayLane) { return true }
                guard let p = x.parentID, p != container else { return false }
                cur = byID[p]
            }
            return false
        }
    }

    /// The display lanes of `scope` the rows name.
    private func rippleOnLanes(scope: [LaneEntry], rows: Set<RippleRow>) -> Set<Int> {
        Set(scope.filter { rows.contains(RippleRow(parent: $0.parentID, lane: $0.item.lane)) }
            .map(\.displayLane))
    }

    /// The display lanes a ripple aimed at `lanes` would take — what the ⌥ cut's preview band
    /// paints. The same reading the gesture itself makes, so the band cannot promise what the
    /// ripple will not do.
    func rippleTakenLanes(forLanes lanes: Set<Int>) -> Set<Int> {
        let container = rippleContainerID(forLanes: lanes)
        let scope = rippleScopeEntries(in: container)
        let on = rippleOnLanes(scope: scope, rows: rippleRows(forLanes: lanes))
        return Set(rippleTaken(scope: scope, onLanes: on, container: container).map(\.displayLane))
    }

    // MARK: - The primitive

    /// Takes the span [lo, hi] out of the given ROWS of `container` and closes the gap: those rows
    /// are hollowed out, then what is left standing after `hi` on them comes back onto `lo`, and
    /// the container's own window shrinks by as much — but only if the rows are every row of the
    /// container (@see the header). `container == nil` ⇒ the whole timeline.
    ///
    /// Returns false if the gesture would change nothing (a degenerate range, no row of the scope
    /// selected, nothing to slide) — the caller then drops its undo rather than leaving an empty
    /// step.
    ///
    /// Pushes NO undo and clears no selection: the caller owns the transaction, as with
    /// `carveTimeRange`, whose matter-removing work this reuses whole.
    @discardableResult
    func rippleRemoveTimeRange(lo: Double, hi: Double, container: UUID?, rows: Set<RippleRow>) -> Bool {
        let hole = hi - lo
        guard hole > 0.001 else { return false }

        // A porthole scope is refused: the window of a LOOPING group is laid on a repeating
        // pattern, not on an edge (@see isLoopedGroupPorthole). Shortening the pattern under the
        // porthole would change every repeat at once, including those the gesture never touched.
        if let container, let obj = find(id: container), isLoopedGroupPorthole(obj) { return false }

        // Read BEFORE anything moves: the display lanes are about to change under us.
        let scope = rippleScopeEntries(in: container)
        let onLanes = rippleOnLanes(scope: scope, rows: rows)
        guard !onLanes.isEmpty else { return false }
        let takenIDs = Set(rippleTaken(scope: scope, onLanes: onLanes, container: container).map { $0.item.id })
        // An infinite bus is never carved nor slid, so it cannot be required to be selected.
        let coversScope = scope.allSatisfy { $0.item.isInfiniteBus || takenIDs.contains($0.item.id) }

        let carved = carveTimeRange(lo: lo, hi: hi, lanes: onLanes, skippingInfiniteBuses: true)

        // AFTER the carve: it creates objects (the right half of a straddling object, laid down at
        // `hi`), and those are precisely the ones that have to slide.
        var toShift: [UUID] = []
        func collect(_ children: [SoundObject], parent: UUID?) {
            for c in children where !c.isInfiniteBus {
                if rows.contains(RippleRow(parent: parent, lane: c.lane)) {
                    // A unit: its row is selected, so it goes whole, everything under it too.
                    if c.startTime >= hi - 1e-6 { toShift.append(c.id) }
                } else if c.showsChildrenInline, case .group(let ch, _) = c.kind {
                    // Only PARTIALLY selected: its window stays, its selected children slide.
                    collect(ch, parent: c.id)
                }
            }
        }
        collect(rippleDirectChildren(of: container), parent: container)

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

        // The window only comes back when EVERY lane of the container went through the ripple:
        // otherwise the lanes left alone still run to the old end.
        if let container, coversScope { rippleShrinkContainer(container, lo: lo, hi: hi) }
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
            // The markers lose the same slice: one that named the removed passage named material
            // that has gone, and is dropped rather than slid onto its neighbour.
            o.markers    = o.markers.splicedInTime(removing: lo - s, to: hi - s)
            // A LOOPING container is refused upstream; a group whose loop is merely armed keeps
            // bounds expressed locally — remapped in ABSOLUTE terms, they stay opposite the same
            // material.
            if let a = o.loopRangeStart { o.loopRangeStart = Self.rippleMap(s + a, removing: lo, hi) - ns }
            if let b = o.loopRangeEnd   { o.loopRangeEnd   = Self.rippleMap(s + b, removing: lo, hi) - ns }
            o.startTime = ns
            o.duration  = dur
            // The window has shrunk, so the fades have to come back inside it — through the same
            // `clampFades` every other window-shortening path uses (the carve just above, the
            // overlap policy). Written by hand here, it clamped in the other order, and the two
            // disagreed about which fade gives way when they no longer both fit.
            EditViewModel.clampFades(&o)
        }
        if let updated = find(id: id) { syncPosition(updated) }
    }

    // MARK: - The two gestures

    /// ⌥⌫ over a time selection: the passage goes, and the scope closes up behind it.
    ///
    /// When the selection was traced in the RULER (its time half or its BPM half — one band, one
    /// gesture, @see `timeSelectionFromRuler`), it is TIME that goes, not just the matter on the
    /// lanes: the marks of the band follow (@see `rippleMarkerLanes`). The same range covering
    /// every lane but traced in the timeline leaves them where they are — the rubber band names
    /// lanes, the ruler names the timeline itself.
    func rippleDeleteTimeSelection() {
        guard let sel = timeSelection else { return }
        let lo = sel.timeRange.lowerBound
        let hi = sel.timeRange.upperBound
        let container = rippleContainerID(forLanes: sel.lanes)
        let rows = rippleRows(forLanes: sel.lanes)
        // Read BEFORE anything writes `timeSelection` (its didSet drops the ruler origin). The
        // band's marks live on the TIMELINE: a ripple scoped inside a group never moves them.
        let marksFollow = timeSelectionFromRuler && container == nil
        pushUndo()
        let rippled = rippleRemoveTimeRange(lo: lo, hi: hi, container: container, rows: rows)
        // `||` in this order on purpose: the marks move even when no object did (a ruler range
        // over an empty stretch with only marks after it is still time being removed).
        let marksMoved = marksFollow && rippleMarkerLanes(removing: lo, hi)
        guard rippled || marksMoved else {
            _ = undoStack.popLast()
            return
        }
        selectedIDs   = []
        timeSelection = nil
        isDirty       = true
    }

    /// The marker band's share of a ruler ripple: the span [lo, hi] is taken out of every row,
    /// hidden ones included (hiding a row is not opting out of the timeline's time). Same rule as
    /// an object's own markers under a ripple (`splicedInTime`): a mark AFTER the hole slides back
    /// by its length; a point marker INSIDE it disappears (it named material that has gone); a
    /// region loses the part overlapping the hole and keeps the rest, and disappears if wholly
    /// swallowed. Pushes no undo — the ripple's own transaction holds it. Returns true if anything
    /// changed.
    @discardableResult
    func rippleMarkerLanes(removing lo: Double, _ hi: Double) -> Bool {
        guard hi - lo > 0.001 else { return false }
        var changed = false
        var survivors = Set<UUID>()
        for i in markerLanes.indices {
            let spliced = markerLanes[i].markers.splicedInTime(removing: lo, to: hi)
            survivors.formUnion(spliced.map(\.id))
            if spliced != markerLanes[i].markers {
                markerLanes[i].markers = spliced
                changed = true
            }
        }
        // A mark swallowed by the hole must not stay selected (⌫ would aim at nothing).
        if changed {
            let pruned = selectedAnnotations.filter {
                if case .laneMarker(_, let m) = $0 { return survivors.contains(m) }
                return true
            }
            if pruned != selectedAnnotations { selectedAnnotations = pruned }
        }
        return changed
    }

    /// The scope of a ripple laid on OBJECTS.
    ///
    /// Read off `laneEntries`, hence off what is ON SCREEN, and that is why the callers filter
    /// their ids through `rippleVisibleIDs` first: an object with no display row would answer
    /// `nil` here — the whole timeline — for something that plainly lives inside a group.
    func rippleContainerID(forObjects ids: Set<UUID>) -> UUID? {
        rippleScope { ids.contains($0.item.id) }
    }

    /// The ones of `ids` that have a display row. A ripple is a DISPLAYED gesture from end to end:
    /// its scope comes from `laneEntries`, and the lanes it hollows out come from there too.
    ///
    /// The filter is not tidiness, it is the difference between a ripple and a wreck. A selection
    /// survives its group being folded — collapsing prunes nothing, and opening a group folds the
    /// sibling on its lane by itself — so a child one can no longer see stays perfectly selectable.
    /// Rippled as it is, it answers no container at all: the range would be carved out of the
    /// WHOLE session and would split the very group the object sits inside. And even given its
    /// true container by hand, the scope's lanes are not on screen either, so nothing would be
    /// carved while the group's children slid anyway — matter left standing, moved.
    ///
    /// Refusing is the honest answer rather than a repair: a ripple that names its lanes by what
    /// is on screen has nothing to name for an object one cannot see, and a scope one cannot see
    /// is collateral one cannot see coming. Unfolding the group puts the gesture back within reach.
    func rippleVisibleIDs(_ ids: Set<UUID>) -> Set<UUID> {
        let shown = Set(laneEntries.map(\.item.id))
        return ids.intersection(shown)
    }

    /// ⌥⌫ with objects selected and NO time selection: each one's span goes, and the scope closes
    /// over it. It is the ripple a hand reaches for first — an object is a passage one can see, so
    /// one selects it rather than tracing a range over it — and without this branch ⌥⌫ fell back
    /// on the plain delete, which removes the matter and leaves the hole gaping.
    ///
    /// The objects are taken from the LAST to the FIRST: closing a gap only ever moves what comes
    /// AFTER it, so those still to be done keep the positions just read. The other way round we
    /// would be guessing where they had slid to.
    @discardableResult
    func rippleDeleteSelectedObjects() -> Bool {
        // `effectiveSelectedIDs`, not `selectedIDs`: a child whose ancestor is selected too is
        // dropped. Its span is already inside its parent's, and rippling it in the parent's own
        // scope would close the same gap twice.
        var remaining = rippleVisibleIDs(effectiveSelectedIDs)
        guard !remaining.isEmpty else { return false }
        let container = rippleContainerID(forObjects: remaining)
        // The rows the SELECTED objects sit on, read once: the objects go one by one and the rows
        // are what stays (@see RippleRow).
        let rows = rippleRows(forLanes: Set(laneEntries.filter { remaining.contains($0.item.id) }.map(\.displayLane)))
        pushUndo()
        var closed = false
        // Re-read at every step rather than take a snapshot: a removal can have trimmed or
        // destroyed an object still on the list (two selected objects overlapping in time, on two
        // lanes of the same scope). An id that no longer resolves is simply dropped.
        while let obj = remaining.compactMap({ find(id: $0) }).max(by: { $0.startTime < $1.startTime }) {
            remaining.remove(obj.id)
            if rippleRemoveTimeRange(lo: obj.startTime, hi: obj.startTime + obj.duration,
                                     container: container, rows: rows) { closed = true }
        }
        guard closed else { _ = undoStack.popLast(); return false }
        selectedIDs = []
        isDirty     = true
        return true
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
        let rows = rippleRows(forLanes: lanes)
        engine?.beginPlaybackEdit()           // @see cut(ids:atTime:keeping:)
        defer { engine?.endPlaybackEdit() }
        pushUndo()
        guard rippleRemoveTimeRange(lo: range.lo, hi: range.hi, container: container, rows: rows) else {
            _ = undoStack.popLast()
            return
        }
        // No `selectedIDs = []` here: the selection follows the matter, same rule as an ordinary
        // cut (@see EditViewModel+Cut). Whatever `carveTimeRange` swallows is pruned by
        // `remove(id:)`; what survives keeps its id — `keeping: .left` truncates it in place,
        // `.right` only advances its start — so a selected grabbed object is simply still there,
        // still named the same, with nothing to rewrite.
        timeSelection = nil
        isDirty       = true
    }
}

import Foundation

// MARK: - A click in the lanes — ONE rule, whatever the depth of the object

/// What a point of the lanes lands on: the object under it (any depth — a top-level block, a child
/// of an open group, a sub-group's child, an infinite bus over its whole lane), which half of the
/// block it is in, the display row and the instant. Found ONCE by `TimelineView.lanePointProbe`,
/// and read by the left click (`handleLaneClick`), by the right click (the context menu) and by
/// the command API (`selection.click`, `selection.context_click`) — so the three cannot disagree
/// about what lies under the hand.
struct LaneClickHit {
    /// The object under the point, nil on an empty lane (or in the gap between two rows).
    let entry: LaneEntry?
    /// The upper half of the block is TIME, the lower half is the OBJECT (@see
    /// `ContextMenuPlan.BlockZone`). nil exactly when `entry` is.
    let zone: ContextMenuPlan.BlockZone?
    /// The display row aimed at.
    let lane: Int
    /// The instant aimed at, in absolute seconds, NOT snapped (`handleLaneClick` snaps it where a
    /// click lays something down; the right click compares it as the drag compares a range's
    /// bounds).
    let time: Double
}

extension EditViewModel {

    /// The left click on the lanes (select tool), once the view has resolved WHAT is under the
    /// point. One `switch` on the object aimed at, with no distinction of depth: a child of an open
    /// group is selected, extended, toggled, opened and double-clicked exactly like a top-level
    /// object — there is no second selection method inside a group (it used to be one: the
    /// top-level objects were read off `items`, the children off `laneEntries`, and the two
    /// branches had drifted apart, ⇧ and ⌘ included).
    ///
    /// The caret, ⇧ and ⌘ on TIME go first and are the shared rules (@see
    /// `handleTimeSelectionClick`): they lay the caret whatever happens and answer true only when
    /// they have made a RANGE. On the lower half of a block ⇧ and ⌘ belong to the object
    /// (`allowsRange: false`), which is the only place the two readings differ.
    ///
    /// No undo point: selecting is not an edit.
    func handleLaneClick(_ hit: LaneClickHit, shift: Bool, cmd: Bool, option: Bool,
                         isDoubleTap: Bool, isPlaying: Bool,
                         onMoveCursor: (Double) -> Void) {
        let tapTime = snapTime(max(0, hit.time))
        let inBody = hit.zone == .body

        if handleTimeSelectionClick(lane: hit.lane, time: tapTime, shift: shift, cmd: cmd,
                                    allowsRange: !inBody, onMoveCursor: onMoveCursor) {
            return
        }

        // Nothing under the point: the click is on time. The selection goes, the cursor comes.
        guard let entry = hit.entry else {
            clearSelection()
            onMoveCursor(tapTime)
            return
        }
        let item = entry.item

        // ⌥ + double click = OPEN / CLOSE the automation band, on ANY object. It is the ONLY path
        // for a consolidated object instance, whose bare double click is already taken (it opens the
        // object, see just below) and which, folded, shows no selector at all. Elsewhere it is a
        // shortcut: it saves opening the content only to reach the selector afterwards.
        if isDoubleTap, option {
            timeSelection = nil
            toggleAutomation(id: item.id)
            return
        }

        // A consolidated object TAKES PRIORITY (a design decision): a double click = OPEN the
        // object; a double click again on the open object = CLOSE (a new bake). With priority over
        // unfolding a group / the MIDI piano roll. The children keep their double click once the
        // object is open (we fall through further down).
        if isDoubleTap {
            if editingPlacementID == item.id {
                timeSelection = nil
                closeConsolidate()
                return
            }
            if item.isConsolidateInstance {
                timeSelection = nil
                openConsolidate(viaPlacementID: item.id)
                return
            }
        }

        // A double click on a MIDI clip → opens/closes its inline piano roll, from either half.
        if item.isMIDI && isDoubleTap {
            timeSelection = nil
            togglePianoRoll(id: item.id)
            return
        }

        // A double click on an audio clip or an aux → opens/closes its AUTOMATION band: nothing was
        // using it. A group keeps its own (unfolding), and flips afterwards through the selector.
        // Only on the BODY: the upper half is time, and a double click there stays a click of time
        // (it falls through to the cursor below).
        if isDoubleTap, !item.isGroup, inBody {
            timeSelection = nil
            toggleAutomation(id: item.id)
            return
        }

        // The upper half: time. The selection goes, the cursor comes.
        guard inBody else {
            clearSelection()
            onMoveCursor(tapTime)
            return
        }

        // The body: the object.
        timeSelection = nil
        if item.isGroup, isDoubleTap {
            doubleClickGroup(id: item.id)
        } else if cmd {
            toggleSelection(of: entry, isPlaying: isPlaying, onMoveCursor: onMoveCursor)
        } else if shift {
            extendSelectionTo(item.id, isPlaying: isPlaying, onMoveCursor: onMoveCursor)
        } else {
            selectOnBodyClick(item.id, cursorAt: entry.absStart,
                              isPlaying: isPlaying, onMoveCursor: onMoveCursor)
        }
    }

    /// ⌘ on an object's body: it goes into or out of the selection, and the cursor follows the
    /// EARLIEST selected start (so the cursor, the caret's instant, keeps naming the beginning of
    /// what is selected): an object added BEFORE the selection pulls it back to its own start, an
    /// object taken out moves it to the new earliest one when that changed. Read off the display
    /// list in ABSOLUTE time, so it holds for the children of an open group as for anything else.
    func toggleSelection(of entry: LaneEntry, isPlaying: Bool,
                         onMoveCursor: (Double) -> Void) {
        let id = entry.item.id
        func earliestSelectedStart() -> Double? {
            laneEntries.filter { selectedIDs.contains($0.item.id) }.map(\.absStart).min()
        }
        func moveCursor(to start: Double) {
            let t = max(0, start)
            if !isPlaying { engine?.seek(to: t) }
            onMoveCursor(t)
        }
        selectedCrossfade = nil
        let prevMin = earliestSelectedStart() ?? Double.infinity
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
            if let newMin = earliestSelectedStart(), newMin != prevMin { moveCursor(to: newMin) }
        } else {
            selectedIDs.insert(id)
            if entry.absStart < prevMin { moveCursor(to: entry.absStart) }
        }
    }

    /// ⇧ on an object's body: the selection extends to the object clicked, over the rectangle of
    /// display lanes × absolute time (`laneEntries`) — it works for clips, groups and nested
    /// children alike. Nothing selected yet: it is a plain selection of that object.
    func extendSelectionTo(_ id: UUID, isPlaying: Bool, onMoveCursor: (Double) -> Void) {
        let entries = laneEntries
        guard let target = entries.first(where: { $0.item.id == id }) else { return }

        let selectedEntries = entries.filter { selectedIDs.contains($0.item.id) }
        guard !selectedEntries.isEmpty else {
            select(id, additive: false)
            let t = max(0, target.absStart)
            if !isPlaying { engine?.seek(to: t) }
            onMoveCursor(t)
            return
        }

        let prevMin = selectedEntries.map(\.absStart).min()!
        let timeMin = min(prevMin, target.absStart)
        let timeMax = max(selectedEntries.map { $0.absStart + $0.item.duration }.max()!,
                          target.absStart + target.item.duration)
        let laneMin = min(selectedEntries.map(\.displayLane).min()!, target.displayLane)
        let laneMax = max(selectedEntries.map(\.displayLane).max()!, target.displayLane)

        selectedIDs = Set(
            entries.filter { e in
                e.absStart < timeMax
                && e.absStart + e.item.duration > timeMin
                && e.displayLane >= laneMin
                && e.displayLane <= laneMax
            }.map(\.item.id)
        )
        if target.absStart < prevMin {
            let t = max(0, target.absStart)
            if !isPlaying { engine?.seek(to: t) }
            onMoveCursor(t)
        }
    }
}

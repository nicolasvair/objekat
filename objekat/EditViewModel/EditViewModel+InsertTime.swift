import AppKit
import Foundation

// MARK: - Insert time: the mirror of the ripple delete
//
// A blank opens at `lo` and everything on the selected rows that comes AFTER it slides forward by
// its length — Reaper's "insert time", the exact counterpart of `rippleRemoveTimeRange`, and it
// borrows its whole vocabulary: the same scope (the SHALLOWEST container the rows touch, `nil` =
// the whole timeline), the same rows (`RippleRow`, read BEFORE anything moves because the display
// lanes change under the gesture's own hands), the same refusals. The user's rulings, each of
// which has a line below:
//
//  • An object STRADDLING `lo` is cut there and its right half slides (a clip, a MIDI clip, an
//    aux: `_splitInternal`). A GROUP is cut in depth, like `carveTimeRange` does — its content is
//    divided either side, never just its window (`cutCore`, `windowOnly: false`).
//  • An INFINITE bus (an aux or a group with no start and no end) is neither cut nor moved: it has
//    no edge. Its automation takes the blank (its curves are time passing like any other), and its
//    FINITE children slide like any object — by their own row when the bus shows them inline, by
//    the bus's row when it is folded and they have none.
//  • The container's own window GROWS by the blank, but only when every row of the scope took part
//    (the mirror of the ripple's shrinking rule); its own curves and marks take the blank too.
//  • Triggered from the RULER only (`timeSelectionFromRuler`, the ruler's right-click menu): the
//    marker band, the timeline's comments and the playback loop are time as well and follow.
//
// The primitive pushes NO undo and clears no selection — the caller owns the transaction, as with
// the ripple — and `insertTimeAtTimeSelection` is the gesture that does.

extension EditViewModel {

    /// What an insertion did, for the callers that report it. `changed` is the answer to "is there
    /// an undo step to keep": a blank opened over nothing that moves is no edit at all.
    struct InsertTimeOutcome {
        /// Objects divided at `lo` (both halves count once).
        var cut = 0
        /// Units that slid forward (the halves a cut produced included).
        var shifted = 0
        /// Infinite buses (or an infinite container) whose automation received the blank.
        var blanked = 0
        var changed: Bool { cut > 0 || shifted > 0 || blanked > 0 }
    }

    // MARK: - The primitive

    /// Opens a blank of `length` at `lo` on the given ROWS of `container` (`nil` = the whole
    /// timeline): what straddles `lo` is cut there, what stands at or after it slides forward, and
    /// the container's own window grows by as much when the rows are every row of the container.
    ///
    /// Returns false if the gesture would change nothing (a degenerate length, a refusal, no row of
    /// the scope selected, nothing to move) — the caller then drops its undo. Pushes NO undo and
    /// clears no selection.
    @discardableResult
    func rippleInsertTimeRange(at lo: Double, length: Double, container: UUID?,
                               rows: Set<RippleRow>) -> Bool {
        rippleInsertTime(at: lo, length: length, container: container, rows: rows).changed
    }

    /// `rippleInsertTimeRange` with the counts: the one implementation, the Bool above being its
    /// short form (the API wants the figures).
    func rippleInsertTime(at lo: Double, length: Double, container: UUID?,
                          rows: Set<RippleRow>) -> InsertTimeOutcome {
        var outcome = InsertTimeOutcome()
        guard length > 0.001 else { return outcome }
        if insertTimeRefused(container: container) { return outcome }

        // Read BEFORE anything moves: the display lanes are about to change under us.
        let scope = rippleScopeEntries(in: container)
        let onLanes = rippleOnLanes(scope: scope, rows: rows)
        guard !onLanes.isEmpty else { return outcome }
        let takenIDs = Set(rippleTaken(scope: scope, onLanes: onLanes, container: container)
            .map { $0.item.id })
        // An infinite bus is never cut nor slid, so it cannot be required to be selected.
        let coversScope = scope.allSatisfy { $0.item.isInfiniteBus || takenIDs.contains($0.item.id) }

        // 1. The cut. The units standing ACROSS `lo`, divided there. A unit that cannot be divided
        //    (an edge a few milliseconds from `lo`, which `_splitInternal` refuses) is left where it
        //    is: it neither splits nor slides.
        let before = insertionUnits(container: container, rows: rows)
        let straddling = before.units.filter {
            $0.startTime < lo - 1e-6 && $0.startTime + $0.duration > lo + 1e-6
        }.map(\.id)
        let toCut = cuttableIDs(straddling)
        if !toCut.isEmpty {
            let pieces = cutCore(ids: toCut, atTime: lo, keeping: nil, windowOnly: false)
            outcome.cut = pieces.count / 2
        }

        // 2. AFTER the cut: it creates objects (the right half of a straddling one, laid down at
        //    `lo`), and those are precisely the ones that have to slide.
        let after = insertionUnits(container: container, rows: rows)
        let movers = after.units.filter { $0.startTime >= lo - 1e-6 }.map(\.id)

        batchItemsMutation {
            for id in movers {
                update(id: id) { o in
                    o.startTime += length
                    // An object's own curves and marks are held in time RELATIVE to it: they travel
                    // with it. Its children carry ABSOLUTE starts and follow by hand.
                    if case .group(var ch, let ex) = o.kind {
                        EditViewModel.shiftStartTimes(&ch, by: length)
                        o.kind = .group(children: ch, isExpanded: ex)
                    }
                }
            }
        }
        for id in movers {
            if let o = find(id: id) { syncPosition(o) }
        }
        outcome.shifted = movers.count

        // 3. The infinite buses on a selected row: no edge to move, but the curves are time.
        for id in after.blankedBuses where insertBlank(inAutomationOf: id, at: lo, length: length) {
            outcome.blanked += 1
        }

        // Nothing moved, nothing was cut, no curve took a blank: no edit, so the container's window
        // does not grow either.
        guard outcome.changed else { return outcome }

        // The window only grows when EVERY row of the container took part: otherwise the rows left
        // alone are untouched and their extent is what the window still describes.
        if let container, coversScope { growContainer(container, at: lo, length: length) }
        return outcome
    }

    /// The refusals of an insertion, said with a beep: the same two as the ripple's, which for a
    /// gesture that is asked for by a menu entry deserve to be heard (the entry looks available).
    ///  • a consolidated object open for editing, at the root or in its stage — time cannot be
    ///    inserted there (@see `sessionRefusal(.moveInTime)`);
    ///  • a LOOPING container: its window is a porthole onto a repeating pattern, and growing it
    ///    would change every repeat at once.
    func insertTimeRefused(container: UUID?) -> Bool {
        if !consolidateEditStack.isEmpty, container == nil || sessionStageIDs.contains(container!) {
            NSSound.beep()
            return true
        }
        if let container, let obj = find(id: container), isLoopedGroupPorthole(obj) {
            NSSound.beep()
            return true
        }
        return false
    }

    /// The UNITS an insertion acts on, read straight off the model (so the same walk serves before
    /// and after the cut): the shallowest object whose row is selected, carried whole with
    /// everything under it, plus the infinite buses whose own row is selected.
    ///
    /// The same reading as the ripple's `collect`, with the infinite bus handled instead of skipped:
    /// a bus is never a unit, but its finite children are — through their own rows when the bus
    /// shows them inline, through the bus's row when it is folded (they then have none).
    func insertionUnits(container: UUID?, rows: Set<RippleRow>)
        -> (units: [SoundObject], blankedBuses: [UUID]) {
        var units: [SoundObject] = []
        var buses: [UUID] = []
        func walk(_ children: [SoundObject], parent: UUID?) {
            for c in children {
                let selected = rows.contains(RippleRow(parent: parent, lane: c.lane))
                if c.isInfiniteBus {
                    if selected { buses.append(c.id) }
                    guard case .group(let ch, _) = c.kind else { continue }
                    if c.showsChildrenInline {
                        walk(ch, parent: c.id)
                    } else if selected {
                        units.append(contentsOf: ch.filter { !$0.isInfiniteBus })
                    }
                } else if selected {
                    // A unit: its row is selected, so it goes whole, everything under it too.
                    units.append(c)
                } else if c.showsChildrenInline, case .group(let ch, _) = c.kind {
                    // Only PARTIALLY selected: its window stays, its selected children slide.
                    walk(ch, parent: c.id)
                }
            }
        }
        walk(rippleDirectChildren(of: container), parent: container)
        return (units, buses)
    }

    /// Opens the blank in the automation of ONE object, whose curve times are relative to its
    /// start. Returns true if a curve changed (pushed to the engine then).
    ///
    /// The origin is the object's `startTime`, which is what the ENGINE reads a curve against
    /// (@see `modelCurvePoints`) — the automation band of an infinite bus is drawn from the
    /// timeline's zero whatever its object says, an inconsistency that predates this gesture and is
    /// harmless as long as such a bus starts at 0.
    @discardableResult
    private func insertBlank(inAutomationOf id: UUID, at lo: Double, length: Double) -> Bool {
        guard let obj = find(id: id) else { return false }
        let blanked = obj.automation.insertingTime(at: lo - obj.startTime, length: length)
        guard blanked != obj.automation else { return false }
        update(id: id) { $0.automation = blanked }
        if let o = find(id: id) { pushAutomation(o) }
        return true
    }

    /// The container's own share of an insertion (the mirror of `rippleShrinkContainer`).
    ///
    ///  • A container that STARTS at or after `lo` rides forward whole — window only: its own curves
    ///    and marks are relative to it and its content was moved by the primitive.
    ///  • One that starts BEFORE `lo` keeps its start; its end goes on by the blank when the blank
    ///    falls inside the window (an end exactly at `lo` belongs to what precedes the blank), and
    ///    its curves and marks take the blank at `lo` in their own frame. The IN/OUT bounds of an
    ///    armed loop are mapped in absolute terms, so they stay opposite the same material (a
    ///    LOOPING container is refused upstream).
    ///  • An infinite container has no window: only its automation takes the blank.
    private func growContainer(_ id: UUID, at lo: Double, length: Double) {
        guard let obj = find(id: id) else { return }
        if obj.isInfiniteBus {
            insertBlank(inAutomationOf: id, at: lo, length: length)
            return
        }
        let s = obj.startTime, e = s + obj.duration
        update(id: id) { o in
            if s >= lo {
                o.startTime = s + length
            } else {
                let at = lo - s
                o.automation = o.automation.insertingTime(at: at, length: length)
                o.markers    = o.markers.insertingTime(at: at, length: length)
                if let a = o.loopRangeStart, a >= at { o.loopRangeStart = a + length }
                if let b = o.loopRangeEnd,   b >  at { o.loopRangeEnd   = b + length }
                if e > lo { o.duration += length }
            }
        }
        if let updated = find(id: id) { syncPosition(updated) }
    }

    // MARK: - The gesture

    /// "Insert time" over the time selection TRACED IN THE RULER (its menu entry): a blank the
    /// length of the range opens at its start, and everything after it slides forward.
    ///
    /// Triggered from the RULER, it is TIME that opens, not just the matter on the lanes: the marks
    /// of the band, the timeline's comments and the playback loop follow (@see `rippleDeleteTimeSelection`
    /// for the symmetrical rule). A range traced in the timeline (the API only — the user left it
    /// without an entry in this first version) acts on its lanes and leaves them where they are.
    ///
    /// ONE undo step. Afterwards the selection is the BLANK (the same range and lanes — and still the
    /// ruler's, if it was), the caret at its start, nothing else selected: one sees where the room
    /// opened and can fill it. The playback loop is NOT in the undo snapshot, so ⌘Z gives back
    /// everything except a loop that followed.
    ///
    /// Returns what was done, `nil` if nothing was (then no undo step was kept).
    @discardableResult
    func insertTimeAtTimeSelection() -> InsertTimeReport? {
        guard let sel = timeSelection else { return nil }
        let lo = sel.timeRange.lowerBound
        let length = sel.timeRange.upperBound - lo
        guard length > 0.001 else { return nil }
        let container = rippleContainerID(forLanes: sel.lanes)
        let rows = rippleRows(forLanes: sel.lanes)
        // Read BEFORE anything writes `timeSelection` (its didSet drops the ruler origin). The
        // band's marks live on the TIMELINE: an insertion scoped inside a group never moves them.
        let fromRuler = timeSelectionFromRuler
        let marksFollow = fromRuler && container == nil
        if insertTimeRefused(container: container) { return nil }

        // While playing, the cut is HEARD at once and the graph rebuilt at the end (@see `cut`).
        engine?.beginPlaybackEdit()
        defer { engine?.endPlaybackEdit() }
        pushUndo()
        let outcome = rippleInsertTime(at: lo, length: length, container: container, rows: rows)
        var marksMoved = false
        if marksFollow {
            let band  = insertMarkerLanes(at: lo, length: length)
            let notes = insertComments(at: lo, length: length)     // all three run: no short-circuit
            let loop  = insertLoopRegion(at: lo, length: length)
            marksMoved = band || notes || loop
        }
        guard outcome.changed || marksMoved else {
            _ = undoStack.popLast()
            return nil
        }
        selectedIDs = []
        // The blank stays selected, as the ruler left it.
        if fromRuler {
            if timeSelection != sel || !timeSelectionFromRuler { setTimeSelectionFromRuler(sel) }
        } else if timeSelection != sel {
            timeSelection = sel
        }
        cursorPosition = lo
        if !isTransportPlaying { engine?.seek(to: lo) }
        isDirty = true
        return InsertTimeReport(outcome: outcome, marksFollow: marksFollow, container: container)
    }

    /// What `insertTimeAtTimeSelection` did, for the API.
    struct InsertTimeReport {
        let outcome: InsertTimeOutcome
        let marksFollow: Bool
        let container: UUID?
    }

    // MARK: - What follows time besides the objects

    /// The marker band's share of a ruler insertion: a mark at or after `lo` slides forward, a
    /// region that contains `lo` is lengthened (@see `[Marker].insertingTime`). Hidden rows
    /// included — hiding a row is not opting out of the timeline's time. Pushes no undo; returns
    /// true if anything changed.
    @discardableResult
    func insertMarkerLanes(at lo: Double, length: Double) -> Bool {
        guard length > 0.001 else { return false }
        var changed = false
        for i in markerLanes.indices {
            let opened = markerLanes[i].markers.insertingTime(at: lo, length: length)
            if opened != markerLanes[i].markers {
                markerLanes[i].markers = opened
                changed = true
            }
        }
        return changed
    }

    /// The timeline's comments' share (@see `[TimelineComment].insertingTime`): one starting at or
    /// after `lo` slides forward. Pushes no undo (comments are in the snapshot); returns true if
    /// anything changed.
    @discardableResult
    func insertComments(at lo: Double, length: Double) -> Bool {
        guard length > 0.001 else { return false }
        let opened = comments.insertingTime(at: lo, length: length)
        guard opened != comments else { return false }
        comments = opened
        return true
    }

    /// The playback loop's share: it slides when it starts at or after `lo`, and is LENGTHENED when
    /// it contains `lo` (the passage it names has grown). Returns true if it changed. The loop is
    /// not in the undo snapshot — this is the one part of the gesture ⌘Z does not give back.
    @discardableResult
    func insertLoopRegion(at lo: Double, length: Double) -> Bool {
        guard length > 0.001, let r = loopRegion else { return false }
        let moved = r.insertingTime(at: lo, length: length)
        guard moved != r else { return false }
        loopRegion = moved
        return true
    }
}

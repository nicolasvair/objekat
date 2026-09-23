import Foundation

// THE CLICK RULES OF A TIME SELECTION, written once and used by both surfaces that have one: the
// timeline's canvas and an automation band.
//
// They were the timeline's, spelled out inside its tap handler between two hit tests. An
// automation row being a display lane like any other (@see EditViewModel+AutomationZone), the band
// needs exactly the same three — a plain click lays the caret, ⇧ extends from an anchor, ⌘ toggles
// a lane in or out — and a second copy of them would be the same mistake as a second kind of
// selection: they would drift, and the surface one happened to be on would decide what ⇧ meant.
extension EditViewModel {

    /// Answers a click on a surface that carries a time selection. Returns true when it has
    /// ANSWERED — the caller then stops; false for a plain click, which each surface reads its own
    /// way (the timeline goes on to its hit tests, the band drops its points and seeks).
    ///
    /// The caret is laid whatever happens, BEFORE the branches, exactly as the timeline laid it:
    /// the ⇧ and ⌘ branches take it back off again when they make a range instead.
    ///
    /// `allowsRange` is the timeline's `inUpperZone`: on the lower half of a block, ⇧ and ⌘ belong
    /// to other gestures. A band has no such half, and passes true.
    @discardableResult
    func handleTimeSelectionClick(lane: Int, time: Double, shift: Bool, cmd: Bool,
                                  allowsRange: Bool,
                                  onMoveCursor: (Double) -> Void) -> Bool {
        let kind = laneKind(lane)
        // Read BEFORE the caret moves — a plain click lays the anchor down, a ⇧-click reads it and
        // leaves it exactly where it was, which is what makes a second ⇧-click re-extend from the
        // same point.
        let extendOrigin = shift ? timeSelectionExtendOrigin() : nil
        caretLane = lane
        if !shift { timeSelectionOrigin = (lane: lane, time: time) }

        // An automation band reads ONLY a traced range: `baseTimeSelection`'s fallback is the
        // bounding box of the selected OBJECTS, in base lanes, which names nothing in a band — and
        // editing a curve selects its object, so that fallback is always there to be picked up.
        let base = kind == .automation ? timeSelection : baseTimeSelection()

        // ⌘ toggles the lane clicked in or out of the range.
        if cmd, allowsRange, var b = base {
            caretLane = nil
            if b.lanes.contains(lane) { b.lanes.remove(lane) } else { b.lanes.insert(lane) }
            b.lanes = confine(b.lanes, to: kind)
            selectedIDs = []
            timeSelection = b.lanes.isEmpty ? nil : b
            if let ts = timeSelection { selectObjectsInDisplayLanes(ts) }
            return true
        }

        // ⇧ with an anchor: the passage BETWEEN the anchor and the point clicked — the gesture a
        // text has, on a surface that says "this passage" in time × rows, so it covers the rows
        // crossed on the way as well.
        //
        // Before the growth below and not after it, because the two answer different questions: a
        // union GROWS a range from whichever end is nearer, while this one is ANCHORED — the origin
        // does not move, so a second ⇧-click aimed back inside the range SHORTENS it, which a union
        // can never do. An anchor of the other kind is refused rather than crossed: that is the
        // no-mixing rule, and here it reads as "⇧ does not reach out of the surface one is on".
        if shift, allowsRange, let origin = extendOrigin, laneKind(origin.lane) == kind {
            let tLo = min(origin.time, time), tHi = max(origin.time, time)
            // A ⇧-click back onto the anchor itself: there is no passage between a point and
            // itself. The caret laid above stands, and nothing else moves.
            guard tHi - tLo > 1e-9 else { return true }
            let laneLo = min(origin.lane, lane), laneHi = max(origin.lane, lane)
            let lanes = confine(Set(laneLo...laneHi), to: kind)
            guard !lanes.isEmpty else { return true }
            let sel = TimeSelection(timeRange: tLo...tHi, lanes: lanes)
            caretLane = nil
            selectedIDs = []
            timeSelection = sel
            selectObjectsInDisplayLanes(sel)
            onMoveCursor(tLo)
            return true
        }

        // ⇧ on a range already traced: it GROWS, in time and in rows.
        if shift, allowsRange, let b = base {
            caretLane = nil
            let tLo     = min(time, b.timeRange.lowerBound)
            let tHi     = max(time, b.timeRange.upperBound)
            let laneMin = min(lane, b.lanes.min() ?? lane)
            let laneMax = max(lane, b.lanes.max() ?? lane)
            let lanes   = confine(Set(laneMin...laneMax), to: kind)
            guard !lanes.isEmpty else { return true }
            let sel = TimeSelection(timeRange: tLo...tHi, lanes: lanes)
            selectedIDs = []
            timeSelection = sel
            selectObjectsInDisplayLanes(sel)
            onMoveCursor(sel.timeRange.lowerBound)
            return true
        }

        return false
    }

    /// The objects a time selection ENCLOSES — wholly, both edges inside. Moved off the view so the
    /// rule above can call it; `TimelineView.selectInDisplayLanes` is now the thin wrapper.
    /// On automation lanes it selects nothing, no object living there, which is what lets the one
    /// rule serve both surfaces without a branch.
    func selectObjectsInDisplayLanes(_ sel: TimeSelection) {
        let t1 = sel.timeRange.lowerBound
        let t2 = sel.timeRange.upperBound
        selectedIDs = Set(
            laneEntries
                .filter { sel.lanes.contains($0.displayLane) }
                .filter { $0.absStart >= t1 && $0.absStart + $0.item.duration <= t2 }
                .map    { $0.item.id }
        )
    }
}

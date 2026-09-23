import Foundation

// AN AUTOMATION ROW IS A DISPLAY LANE — which is why there is no second kind of time selection.
//
// There briefly was one. It read well on its own and was wrong the moment both existed: ↑ and ↓
// moved one frame or the other depending on what had last been touched, and no rule on screen
// said which. Two selections that look identical and answer the same keys differently are worse
// than either.
//
// The whole thing collapses on one fact already in the model: `SoundObject.automationSpan` says
// "one row = one lane", and a band's row `i` is laid at `entry.displayLane + 1 + i` (@see
// TimelineView.automationBandRect). So a row of automation is nameable by `TimeSelection.lanes`
// exactly as an object's lane is, and the timeline's own selection reaches it with nothing added:
// `stepTimeSelectionLanes` walks onto it and off it again, the caret follows, and playback starts
// from there — none of which had to be written, and all of which the automation-only version had
// to have re-implemented before it could match.
//
// What is left here is a READING, not a state: which rows on screen a time selection covers, and
// which points those rows hold inside it. The point selection stays stored, because points can
// also be picked one by one; everything else is derived.
extension EditViewModel {

    /// One automation row as it sits on screen.
    struct AutomationRowOnScreen {
        var objectID: UUID
        var param:    ParamRef
        /// The DISPLAY lane, the same number `TimeSelection.lanes` speaks in.
        var lane:     Int
        /// The absolute instant of the row's zero. An `AutomationPoint.t` counts from the start of
        /// its object, a `TimeSelection` in timeline seconds; this is the difference between them,
        /// and the one conversion this file exists to keep in a single place.
        var origin:   Double
    }

    /// Every automation row currently unfolded, in display order.
    func automationRowsOnScreen() -> [AutomationRowOnScreen] {
        var out: [AutomationRowOnScreen] = []
        for e in laneEntries where e.item.automationOpen {
            for (i, param) in e.item.automationRows.enumerated() {
                // The origin is the band's x = 0 read as an instant, and it is taken the way
                // `TimelineView.automationBandRect` lays the band out — an INFINITE bus has no
                // start, so its band begins at the timeline's zero whatever its object says. Two
                // different answers here and in the layout would show as a zone drawn a few
                // seconds from the points it holds.
                out.append(AutomationRowOnScreen(
                    objectID: e.item.id, param: param, lane: e.displayLane + 1 + i,
                    origin: e.item.isInfiniteBus ? 0 : e.absStart))
            }
        }
        return out
    }

    /// The automation rows the time selection covers. Empty when the selection is on objects —
    /// which is exactly how the keys tell the two apart, with nothing to store and nothing to
    /// keep in step.
    func automationRowsInTimeSelection() -> [AutomationRowOnScreen] {
        guard let sel = timeSelection else { return [] }
        return automationRowsOnScreen().filter { sel.lanes.contains($0.lane) }
    }

    /// Reads the point selection off the time selection. Called from `timeSelection`'s own
    /// `didSet`, which is the ONE hook: tracing a zone, ⇧-extending it, walking it with ↑ / ↓ and
    /// undoing all go through that property, so none of them can forget to bring the points along.
    ///
    /// A selection that has moved OFF automation empties the set rather than leaving it behind —
    /// the frame is what says what is taken, and matter still lit under a frame that has gone
    /// elsewhere is the exact confusion this file was written to end.
    func syncAutomationSelectionToTimeSelection() {
        guard let sel = timeSelection else { return }
        var refs: Set<AutomationPointRef> = []
        for r in automationRowsInTimeSelection() {
            let lo = sel.timeRange.lowerBound - r.origin
            let hi = sel.timeRange.upperBound - r.origin
            for (i, p) in automationPoints(r.objectID, r.param).enumerated()
            where p.t >= lo && p.t <= hi {
                refs.insert(AutomationPointRef(objectID: r.objectID, param: r.param, index: i))
            }
        }
        if !refs.isEmpty, !selectedMidiNoteIDs.isEmpty { selectedMidiNoteIDs.removeAll() }
        if selectedAutomationPoints != refs { selectedAutomationPoints = refs }
    }

    /// Is the keyboard talking to an automation band? A zone holding NO point still answers YES,
    /// and that is why this reads the ROWS and not the points: an EMPTY stretch is a thing one
    /// copies — to wipe the same stretch elsewhere — and walks across the rows with the arrows.
    var automationSurfaceHasKeyboard: Bool {
        !automationRowsInTimeSelection().isEmpty || !selectedAutomationPoints.isEmpty
    }

    /// The rows a LOOSE point selection touches — no zone, points picked one by one. Same shape as
    /// the reading above so the clipboard has one kind of source and not two.
    func automationRowsOfPointSelection() -> [AutomationRowOnScreen] {
        let touched = Set(selectedAutomationPoints.map { RowKey($0.objectID, $0.param) })
        return automationRowsOnScreen().filter { touched.contains(RowKey($0.objectID, $0.param)) }
    }

    /// `ParamRef` + object, hashable, for the lookup just above. A named type rather than a tuple:
    /// tuples are not `Hashable`.
    struct RowKey: Hashable {
        let objectID: UUID
        let param: ParamRef
        init(_ o: UUID, _ p: ParamRef) { objectID = o; param = p }
    }
}

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
        /// The window the row exists over, in absolute seconds: its object's, unbounded for an
        /// infinite bus. Two objects on the same lane share a lane NUMBER and nothing else — this is
        /// what tells their rows apart (@see AutomationZoneFilter).
        var span:     ClosedRange<Double>
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
                    origin: e.item.isInfiniteBus ? 0 : e.absStart,
                    span: AutomationZoneFilter.span(origin: e.absStart, duration: e.item.duration,
                                                    isInfinite: e.item.isInfiniteBus)))
            }
        }
        return out
    }

    /// The automation rows the time selection covers. Empty when the selection is on objects —
    /// which is exactly how the keys tell the two apart, with nothing to store and nothing to
    /// keep in step.
    ///
    /// A row is covered by its LANE and by its TIME: two objects on one lane (consecutive children
    /// of a group, say) have bands that share a lane number and nothing else, and a zone over one
    /// must not reach the other (@see AutomationZoneFilter).
    func automationRowsInTimeSelection() -> [AutomationRowOnScreen] {
        guard let sel = timeSelection else { return [] }
        return AutomationZoneFilter.rows(automationRowsOnScreen(), lanes: sel.lanes,
                                         zone: sel.timeRange, lane: { $0.lane }, span: { $0.span })
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

    // MARK: - The two kinds of lane

    /// The display lanes that are automation rows.
    var automationLanes: Set<Int> { Set(automationRowsOnScreen().map(\.lane)) }

    /// What a display lane IS. There are exactly two kinds, and every lane is one of them.
    enum LaneKind { case objects, automation }

    func laneKind(_ lane: Int) -> LaneKind {
        automationLanes.contains(lane) ? .automation : .objects
    }

    /// A set of lanes cut down to ONE kind.
    ///
    /// A TIME SELECTION NEVER MIXES an object's lane with a curve's row, and the kind is decided by
    /// where the gesture STARTED. Not a restriction for tidiness: the two answer the same keys
    /// differently — ⌘C copies objects or a passage of automation, ⌫ deletes clips or points — and
    /// a selection holding both would have to pick one and silently drop the other. A rubber band
    /// dragged across the timeline over a few objects whose bands happen to be open would then
    /// quietly turn into an automation selection.
    func confine(_ lanes: Set<Int>, to kind: LaneKind) -> Set<Int> {
        let auto = automationLanes
        return kind == .automation ? lanes.intersection(auto) : lanes.subtracting(auto)
    }

    /// Is the keyboard talking to an automation band? A zone holding NO point still answers YES,
    /// and that is why this reads the ROWS and not the points: an EMPTY stretch is a thing one
    /// copies — to wipe the same stretch elsewhere — and walks across the rows with the arrows.
    ///
    /// It reads the LANES of the zone and not the rows it reaches in TIME: a zone traced on a band's
    /// lane, over a stretch where that band's object is not, still belongs to the band. Letting it go
    /// would hand ⌫ to the object deletion, which resolves a display lane back to a BASE lane — and
    /// the base lane of a row inside a band is the band's OWNER (@see the head of this file).
    var automationSurfaceHasKeyboard: Bool {
        if let sel = timeSelection, !sel.lanes.isDisjoint(with: automationLanes) { return true }
        return !selectedAutomationPoints.isEmpty
    }

    /// The row the CARET sits in: a plain click in a band leaves no zone, only the caret on the row's
    /// lane and the cursor at the instant clicked. Two objects can share the lane, so the instant picks
    /// the band that contains it (the selected one when several do — a click selects its object).
    func automationCaretRow() -> AutomationRowOnScreen? {
        guard timeSelection == nil, let lane = caretLane else { return nil }
        let t = cursorPosition
        let candidates = automationRowsOnScreen().filter { $0.lane == lane && $0.span.contains(t) }
        return candidates.first(where: { selectedIDs.contains($0.objectID) }) ?? candidates.first
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

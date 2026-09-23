import Foundation

// A TIME ZONE traced on an object's automation rows — and the rule that it OWNS the point
// selection.
//
// The band used to select by rectangle: one drew a box in two dimensions and it took the points
// it covered. That reads as a selection of POINTS, and it is not what the rest of the timeline
// does — there, one sweeps a passage of TIME over a set of lanes and works on what falls inside.
// The two gestures look alike under the hand and are not the same idea at all: a rectangle frames
// the matter it found, a zone frames a STRETCH OF TIME that goes on existing when it is empty.
// The second is what lets one copy a passage, walk it onto another row with the arrows and paste
// it there, which a bounding box of points can never do — it has nowhere to put an emptiness.
//
// So a zone is `TimeSelection` (timeRange × lanes) transposed onto one object's rows, and the
// invariant that keeps the two ideas from fighting is written once, here: A ZONE OWNS THE POINT
// SELECTION. The points inside it are selected because it says so, and a gesture that picks
// points on their own (clicking one, ⇧-clicking another) DROPS the zone rather than leaving a
// frame that no longer describes what is taken.

/// A stretch of time over some of an object's automation rows.
///
/// The rows are NAMED (`[ParamRef]`), not numbered. A row index is only true of the band that was
/// on screen when it was read: a curve losing its last point takes its row out of
/// `automationRows` altogether ('no point = no automation'), and every index below it shifts. The
/// order of the array is that of `automationRows`, which is what the arrows walk along.
struct AutomationTimeSelection: Equatable {
    var objectID: UUID
    var timeRange: ClosedRange<Double>
    var params: [ParamRef]
}

extension EditViewModel {

    /// Is the keyboard talking to an automation band? A zone with NO point in it still answers
    /// YES, and that is the whole reason this is a name and not `!selectedAutomationPoints.isEmpty`
    /// spelled out at each of the five keys: an EMPTY stretch is a thing one copies (to wipe the
    /// same stretch elsewhere) and walks across the rows with the arrows. Read off the points
    /// alone, those two would silently do nothing on exactly the passage they were built for.
    var automationSurfaceHasKeyboard: Bool {
        automationTimeSelection != nil || !selectedAutomationPoints.isEmpty
    }

    // MARK: - Laying a zone down

    /// Lays a zone and selects what it contains. THE ONE DOOR: every gesture that traces, moves or
    /// pastes a zone comes through here, so "the selection is what the zone contains" cannot be
    /// true of one path and false of another.
    ///
    /// It does NOT go through `setAutomationPointSelection`, although it holds the same
    /// exclusivity — because that function's job is to DROP the zone, which is the other half of
    /// the invariant and the thing that makes a click on a point clear the frame. Calling it here
    /// would clear the zone and lay it straight back down: two writes to an observed property per
    /// frame of a drag, which on this timeline is not a detail (@see the note on `laneEntries`).
    /// Hence the equality guards, and hence the exclusivity spelled out once more below.
    func setAutomationZone(objectID: UUID, timeRange: ClosedRange<Double>, params: [ParamRef]) {
        let zone = AutomationTimeSelection(objectID: objectID, timeRange: timeRange,
                                           params: params)
        let refs = pointsInside(zone)
        if !refs.isEmpty, !selectedMidiNoteIDs.isEmpty { selectedMidiNoteIDs.removeAll() }
        if selectedAutomationPoints != refs { selectedAutomationPoints = refs }
        if automationTimeSelection != zone { automationTimeSelection = zone }
    }

    /// The points a zone holds. A row of the zone carrying none is not an error and not an
    /// omission: an empty stretch is exactly what one copies to wipe the same stretch elsewhere.
    func pointsInside(_ zone: AutomationTimeSelection) -> Set<AutomationPointRef> {
        var out: Set<AutomationPointRef> = []
        for param in zone.params {
            for (i, p) in automationPoints(zone.objectID, param).enumerated()
            where zone.timeRange.contains(p.t) {
                out.insert(AutomationPointRef(objectID: zone.objectID, param: param, index: i))
            }
        }
        return out
    }

    // MARK: - Walking it across the rows

    /// ↑ / ↓: the zone slides one row up or down — THE FRAME TRAVELS AND THE MATTER DOES NOT,
    /// word for word `stepTimeSelectionLanes`, of which this is the automation band's half.
    /// Landing on a row, it takes what that row holds in the same stretch of time. That is the
    /// whole point of the gesture: copy a passage of volume, walk the frame down onto pan, paste.
    ///
    /// With no zone but points selected, their own extent is ADOPTED as one — the same courtesy
    /// `stepTimeSelectionLanes` extends to an object selection, and for the same reason: the hand
    /// that reaches for an arrow has already said what it means by the frame.
    @discardableResult
    func stepAutomationZoneRows(by delta: Int) -> Bool {
        guard delta != 0 else { return false }
        guard let zone = automationTimeSelection ?? adoptedAutomationZone() else { return false }
        guard let obj = find(id: zone.objectID) else { return false }

        let all = obj.automationRows
        let idx = zone.params.compactMap { p in all.firstIndex(of: p) }
        // The bounding is `AutomationTransform.stepRows`, asserted with no screen: a frame moved
        // as a block stops on its FOOT, and the bound that gets this wrong fails by REVERSING.
        guard let moved = AutomationTransform.stepRows(idx, count: all.count, by: delta)
        else { return false }

        setAutomationZone(objectID: zone.objectID, timeRange: zone.timeRange,
                          params: moved.map { all[$0] })
        return true
    }

    /// The zone a loose point selection implies: its own time extent, over the rows it touches.
    /// nil unless the selection is on ONE object — a zone belongs to an object's band, and a
    /// selection spanning two of them names no single band to walk across.
    func adoptedAutomationZone() -> AutomationTimeSelection? {
        let refs = selectedAutomationPoints
        guard !refs.isEmpty else { return nil }
        let ids = Set(refs.map(\.objectID))
        guard ids.count == 1, let objectID = ids.first, let obj = find(id: objectID)
        else { return nil }

        var lo = Double.greatestFiniteMagnitude, hi = -Double.greatestFiniteMagnitude
        for ref in refs {
            let pts = automationPoints(objectID, ref.param)
            guard pts.indices.contains(ref.index) else { continue }
            lo = min(lo, pts[ref.index].t)
            hi = max(hi, pts[ref.index].t)
        }
        guard lo <= hi else { return nil }
        let touched = Set(refs.map(\.param))
        return AutomationTimeSelection(objectID: objectID, timeRange: lo...hi,
                                        params: obj.automationRows.filter { touched.contains($0) })
    }
}

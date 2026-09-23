import Foundation

// COPYING A PASSAGE OF AUTOMATION — and it is the time selection, not the points, that makes this
// possible.
//
// A bounding box of points cannot be copied usefully: it has no beginning and no end of its own,
// only the matter it happened to contain, and nothing to say about the emptiness around it. A
// passage has a LENGTH, which is what gives a paste somewhere to put itself and something to
// replace.
//
// Times travel in ABSOLUTE timeline seconds and are made relative to the passage's start. That is
// not ceremony: a row's zero is its object's start (@see AutomationRowOnScreen.origin), so a
// passage copied from one object and pasted onto another would land displaced by the difference
// between them if the conversion happened anywhere but at this door.
extension EditViewModel {

    /// A copied passage. Times relative to its START, values ABSOLUTE and carrying the parameter
    /// they were read from — which is what lets a paste onto another row know it has a conversion
    /// to do.
    struct AutomationClipboard {
        struct Row {
            var param:  ParamRef
            var points: [AutomationPoint]
        }
        var rows: [Row]
        /// The passage's length. Kept even when it is zero: it is what the paste WIPES at the far
        /// end, and a length read back off the points would lose the silence at the edges —
        /// exactly the part one copies a passage for.
        var duration: Double
    }

    /// Where a copy or a paste acts: the rows the time selection covers, or failing that the rows
    /// a loose point selection touches. One reading for both, so the clipboard has one kind of
    /// source and not two.
    private func automationTarget() -> (rows: [AutomationRowOnScreen], start: Double,
                                        duration: Double)? {
        let zoned = automationRowsInTimeSelection()
        if let sel = timeSelection, !zoned.isEmpty {
            return (zoned, sel.timeRange.lowerBound,
                    max(0, sel.timeRange.upperBound - sel.timeRange.lowerBound))
        }
        let loose = automationRowsOfPointSelection()
        guard !loose.isEmpty else { return nil }
        var lo = Double.greatestFiniteMagnitude, hi = -Double.greatestFiniteMagnitude
        for r in loose {
            let pts = automationPoints(r.objectID, r.param)
            for ref in selectedAutomationPoints
            where ref.objectID == r.objectID && ref.param == r.param
                && pts.indices.contains(ref.index) {
                lo = min(lo, pts[ref.index].t + r.origin)
                hi = max(hi, pts[ref.index].t + r.origin)
            }
        }
        guard lo <= hi else { return nil }
        return (loose, lo, hi - lo)
    }

    // MARK: - Copying

    /// ⌘C. A row of the passage holding NO point is copied all the same, as an empty row. That is
    /// not an edge case tolerated, it is the feature: copying an empty stretch and pasting it over
    /// a busy one is how a passage gets wiped, and the only way to say "nothing, for this long".
    @discardableResult
    func copyAutomationSelection() -> Bool {
        guard let t = automationTarget() else { return false }
        let zoned = !automationRowsInTimeSelection().isEmpty
        let taken = selectedAutomationPoints

        var rows: [AutomationClipboard.Row] = []
        for r in t.rows {
            let pts = automationPoints(r.objectID, r.param)
            // From a ZONE, everything inside it; from a loose selection, what is actually taken —
            // a ⇧-click picks points one by one and must not drag their neighbours along.
            let kept = pts.indices.filter { i in
                let abs = pts[i].t + r.origin
                return zoned
                    ? abs >= t.start && abs <= t.start + t.duration
                    : taken.contains(AutomationPointRef(objectID: r.objectID,
                                                        param: r.param, index: i))
            }
            rows.append(.init(param: r.param,
                              points: kept.map { i in
                                  var c = pts[i]; c.t = pts[i].t + r.origin - t.start; return c
                              }.sorted { $0.t < $1.t }))
        }
        guard !rows.isEmpty else { return false }
        automationClipboard = AutomationClipboard(rows: rows, duration: t.duration)
        return true
    }

    /// ⌘X. Copies, then takes the passage out — which over a zone means every point it covers, and
    /// not merely the ones a click had picked. The selection is already what the zone holds
    /// (@see syncAutomationSelectionToTimeSelection), so there is nothing to widen first.
    func cutAutomationSelection() {
        guard copyAutomationSelection() else { return }
        deleteSelectedAutomationPoints()
    }

    // MARK: - Pasting

    /// True when ⌘V has both something to lay down and somewhere to lay it.
    var canPasteAutomation: Bool { automationClipboard != nil && automationTarget() != nil }

    /// ⌘V. The passage lands ON THE SELECTION — its rows and its start — which is what makes
    /// ↑ / ↓ worth having: copy a passage of volume, walk the frame down onto pan, paste, and the
    /// curve arrives at the SAME INSTANT on the other parameter.
    ///
    /// With no zone, the playhead gives the instant and the loose selection's rows the
    /// destination — the fallback `pasteMidiNotes` already uses, snapped to the grid like it.
    ///
    /// Three rules, each a decision and not a default:
    ///
    /// - THE RANGE IS REPLACED, not added to. An automation is a function of time: two sets of
    ///   points over one stretch do not layer, they interleave into a curve that is neither.
    /// - ONTO THE SAME PARAMETER the values are kept EXACTLY; onto a different one they are kept
    ///   in PROPORTION. -96…+40 dB and -1…+1 are not the same ruler, and a volume curve pasted
    ///   raw onto a pan would flatten onto the bound and arrive as a straight line.
    /// - Rows pair UP IN ORDER, as many as both sides have.
    func pasteAutomation() {
        guard let cb = automationClipboard, !cb.rows.isEmpty, let t = automationTarget()
        else { return }

        let anchorAbs: Double = {
            if !automationRowsInTimeSelection().isEmpty { return t.start }
            let g = effectiveSnapGrid
            return (effectiveSnapEnabled && g > 0)
                ? (cursorPosition / g).rounded() * g : cursorPosition
        }()

        let pairs = zip(cb.rows, t.rows).map { ($0, $1) }
        guard !pairs.isEmpty else { return }

        pushUndo()
        // A hair of tolerance on the wiped range: a point laid exactly on an edge by a snapped
        // gesture is INSIDE the passage that replaces it, and a strict comparison on a double that
        // has been through a conversion leaves it behind as a duplicate.
        let eps = 1e-9
        for objectID in Set(pairs.map { $0.1.objectID }) {
            update(id: objectID) { obj in
                for (row, dst) in pairs where dst.objectID == objectID {
                    let anchor = anchorAbs - dst.origin
                    let sr = row.param.valueRange, tr = dst.param.valueRange
                    let same = row.param == dst.param
                    let mapped = row.points.map { p -> AutomationPoint in
                        var c = p
                        c.t = anchor + p.t
                        if !same {
                            let n = AutomationTransform.normalized(Double(p.v),
                                                                   lo: Double(sr.lowerBound),
                                                                   hi: Double(sr.upperBound))
                            c.v = Float(AutomationTransform.denormalized(
                                n, lo: Double(tr.lowerBound), hi: Double(tr.upperBound)))
                        }
                        c.v = c.v.clamped(to: tr)
                        return c
                    }
                    if let li = obj.automation.firstIndex(where: { $0.param == dst.param }) {
                        obj.automation[li].points.removeAll {
                            $0.t >= anchor - eps && $0.t <= anchor + cb.duration + eps
                        }
                        obj.automation[li].points.append(contentsOf: mapped)
                    } else if !mapped.isEmpty {
                        obj.automation.append(AutomationLane(param: dst.param, points: mapped))
                    }
                }
                // 'No point = no automation': a row left empty by the wipe goes, rather than
                // lingering as a curve that draws nothing and outranks the static value.
                obj.automation.removeAll { $0.points.isEmpty }
            }
            // A send that has just gained or lost its curve needs its plugin wired BEFORE the push,
            // exactly as `deleteSelectedAutomationPoints` orders it.
            for (_, dst) in pairs where dst.objectID == objectID {
                if case .send(let auxID) = dst.param {
                    syncSendEngine(objectID: objectID, auxID: auxID)
                }
            }
            pushAutomation(objectID)
        }
        // The frame lands where the passage did, and the points are read back OFF IT — so a second
        // ⌘V after an arrow goes on reading the same way, and the eye sees what was laid down.
        timeSelection = TimeSelection(timeRange: anchorAbs...(anchorAbs + cb.duration),
                                      lanes: Set(pairs.map { $0.1.lane }))
        isDirty = true
    }
}

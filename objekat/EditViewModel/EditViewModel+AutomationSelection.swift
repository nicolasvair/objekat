import Foundation

// A SELECTION of automation points — reading it, clearing it, deleting it, and transforming it.
//
// The selection itself is one flat set of `AutomationPointRef` on the view-model (@see
// EditViewModel.selectedAutomationPoints, which says why it cannot live in the band's view). What
// this file adds is everything that has to VALIDATE it: a storage index is only true of the curve
// it was read off, so every read here drops what the model no longer carries rather than handing
// a stale index on to a caller that would index straight into an array with it.
extension EditViewModel {

    /// The selected points of ONE row, sorted by storage index. The read that VALIDATES: an index
    /// the curve no longer carries is dropped here rather than crashing a caller.
    func selectedIndices(objectID: UUID, param: ParamRef) -> [Int] {
        let count = automationPoints(objectID, param).count
        return selectedAutomationPoints
            .filter { $0.objectID == objectID && $0.param == param && $0.index < count }
            .map(\.index)
            .sorted()
    }

    /// The rows the selection touches, one entry per (object, curve). Read by the band's drawing
    /// and by the transform, and no longer a GATE on anything: the eight grips work over as many
    /// rows as the selection spans.
    func selectedAutomationRows() -> [(objectID: UUID, param: ParamRef)] {
        var seen: [(objectID: UUID, param: ParamRef)] = []
        for ref in selectedAutomationPoints
        where !seen.contains(where: { $0.objectID == ref.objectID && $0.param == ref.param }) {
            seen.append((objectID: ref.objectID, param: ref.param))
        }
        return seen
    }

    /// Sets the point selection, and takes the MIDI note selection out with it. The exclusivity is
    /// the point: ⌫ must have exactly one thing in front of it, and the two surfaces are both
    /// inside the timeline, where no other claim separates them.
    /// It also DROPS THE ZONE, and that is the load-bearing half of the invariant: a frame that no
    /// longer describes what is taken is worse than no frame, and putting the clearing here means
    /// no caller — a click on a point, a ⇧-click on the next — has to remember it. The zone's own
    /// path lays the frame back down straight after (@see setAutomationZone).
    func setAutomationPointSelection(_ refs: Set<AutomationPointRef>) {
        if !refs.isEmpty, !selectedMidiNoteIDs.isEmpty { selectedMidiNoteIDs.removeAll() }
        if automationTimeSelection != nil { automationTimeSelection = nil }
        if selectedAutomationPoints != refs { selectedAutomationPoints = refs }
    }

    /// Empties the point selection. Called from every STRUCTURAL change of a curve as well as from
    /// the usual deselecting gestures — an index that outlives the point it named now names
    /// somebody else (@see AutomationPointRef).
    func clearAutomationPointSelection() {
        if automationTimeSelection != nil { automationTimeSelection = nil }
        if !selectedAutomationPoints.isEmpty { selectedAutomationPoints.removeAll() }
    }

    /// ⌫ on the selection. Removes by DESCENDING index inside each row so the indices behind stay
    /// valid, drops a row left with no point ('no point = no automation'), and clears the
    /// selection — every index it held now names something else. Pushes its own undo, like
    /// `deleteSelectedMidiNotes`.
    func deleteSelectedAutomationPoints() {
        guard !selectedAutomationPoints.isEmpty else { return }
        var byRow: [UUID: [ParamRef: [Int]]] = [:]
        for ref in selectedAutomationPoints {
            byRow[ref.objectID, default: [:]][ref.param, default: []].append(ref.index)
        }
        guard !byRow.isEmpty else { clearAutomationPointSelection(); return }

        pushUndo()
        for (objectID, rows) in byRow {
            update(id: objectID) { obj in
                for (param, indices) in rows {
                    guard let li = obj.automation.firstIndex(where: { $0.param == param })
                    else { continue }
                    for i in indices.sorted(by: >)
                    where obj.automation[li].points.indices.contains(i) {
                        obj.automation[li].points.remove(at: i)
                    }
                }
                obj.automation.removeAll { $0.points.isEmpty }
            }
            // A send whose curve has just lost its last point falls back to its static level, and
            // a static level at -∞ has no plugin on the engine side: the wiring has to follow —
            // BEFORE the push, exactly as `removeAutomationPoint` orders it for one point.
            for (param, _) in rows {
                if case .send(let auxID) = param {
                    syncSendEngine(objectID: objectID, auxID: auxID)
                }
            }
            pushAutomation(objectID)
        }
        clearAutomationPointSelection()
        isDirty = true
    }

    /// The transformation, applied to the ORIGINAL points each row captured at the grab. ONE
    /// `Request` for every row: it speaks in normalised ratios, and each row converts through its
    /// own `valueRange` — the same proportions, never the same values.
    ///
    /// Goes through `updateAutomationRows`, and that is NOT an optimisation: a per-row
    /// `updateAutomationPoints` calls `pushAutomation(objectID)` once per row, and that call
    /// pushes EVERY curve of the object — N rows selected = N × M engine writes, per frame, on a
    /// gesture that runs at screen rate.
    ///
    /// No `pushUndo`: the gesture pushed one at the grab (@see beginAutomationEdit). And no
    /// composition — the originals are read afresh on every frame, which is what makes the whole
    /// gesture non-destructive (@see AutomationTransform.apply).
    func applyAutomationTransform(objectID: UUID,
                                  rows: [(param: ParamRef, indices: [Int],
                                          original: [AutomationPoint])],
                                  request: AutomationTransform.Request) {
        guard !rows.isEmpty else { return }
        updateAutomationRows(objectID: objectID) { lanes in
            for row in rows {
                guard let li = lanes.firstIndex(where: { $0.param == row.param }) else { continue }
                let range = row.param.valueRange
                let lo = Double(range.lowerBound), hi = Double(range.upperBound)
                let taken = row.indices.filter {
                    row.original.indices.contains($0) && lanes[li].points.indices.contains($0)
                }
                let samples = taken.map { i -> AutomationSample in
                    let p = row.original[i]
                    return AutomationSample(t: p.t,
                                            n: AutomationTransform.normalized(Double(p.v),
                                                                              lo: lo, hi: hi))
                }
                let out = AutomationTransform.apply(request, to: samples)
                for (k, i) in taken.enumerated() {
                    lanes[li].points[i].t = out[k].t
                    lanes[li].points[i].v =
                        Float(AutomationTransform.denormalized(out[k].n, lo: lo, hi: hi))
                }
            }
        }
    }
}

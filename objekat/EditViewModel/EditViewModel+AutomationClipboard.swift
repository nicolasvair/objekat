import Foundation

// COPYING A PASSAGE OF AUTOMATION — and it is the ZONE, not the points, that makes this possible.
//
// A bounding box of points cannot be copied usefully: it has no beginning and no end of its own,
// only the matter it happened to contain, and nothing to say about the emptiness around it. A
// zone has a LENGTH, which is what gives a paste somewhere to put itself and something to
// replace. That is the whole reason the selection became a stretch of time
// (@see EditViewModel+AutomationZone).
extension EditViewModel {

    /// A copied passage. Times are relative to the passage's START, values are ABSOLUTE and carry
    /// the parameter they were read from — which is what lets a paste onto another row know it has
    /// a conversion to do.
    struct AutomationClipboard {
        struct Row {
            var param:  ParamRef
            var points: [AutomationPoint]
        }
        var rows: [Row]
        /// The passage's length. Kept even when it is zero (a single instant): it is what the
        /// paste WIPES at the far end, and a length read back off the points would lose the
        /// silence at the edges — exactly the part one copies a zone for.
        var duration: Double
    }

    // MARK: - Copying

    /// ⌘C. The zone if there is one, otherwise the extent of the loose point selection.
    ///
    /// A row of the zone holding NO point is copied all the same, as an empty row. That is not an
    /// edge case tolerated, it is the feature: copying an empty stretch and pasting it over a busy
    /// one is how a passage gets wiped, and it is the only way to say "nothing, for this long".
    @discardableResult
    func copyAutomationSelection() -> Bool {
        guard let src = automationTimeSelection ?? adoptedAutomationZone() else { return false }
        let origin = src.timeRange.lowerBound
        let taken  = selectedAutomationPoints

        var rows: [AutomationClipboard.Row] = []
        for param in src.params {
            let pts = automationPoints(src.objectID, param)
            // From a ZONE, what is inside it; from an adopted selection, what is actually taken —
            // a ⇧-click picks points one by one and must not drag their neighbours along.
            let kept = pts.indices.filter { i in
                automationTimeSelection != nil
                    ? src.timeRange.contains(pts[i].t)
                    : taken.contains(AutomationPointRef(objectID: src.objectID,
                                                        param: param, index: i))
            }
            rows.append(.init(param: param,
                              points: kept.map { i in
                                  var c = pts[i]; c.t = pts[i].t - origin; return c
                              }.sorted { $0.t < $1.t }))
        }
        guard !rows.isEmpty else { return false }
        automationClipboard = AutomationClipboard(
            rows: rows,
            duration: max(0, src.timeRange.upperBound - src.timeRange.lowerBound))
        return true
    }

    /// ⌘X. Copies, then takes the passage out — which for a zone means every point it covers, and
    /// not merely the ones a click had picked.
    func cutAutomationSelection() {
        guard copyAutomationSelection() else { return }
        if let zone = automationTimeSelection {
            setAutomationPointSelection(pointsInside(zone))
        }
        deleteSelectedAutomationPoints()
    }

    // MARK: - Pasting

    /// True when ⌘V has both something to lay down and somewhere to lay it.
    var canPasteAutomation: Bool {
        automationClipboard != nil
            && (automationTimeSelection ?? adoptedAutomationZone()) != nil
    }

    /// ⌘V. The passage lands ON THE ZONE — its rows and its start — which is what makes the
    /// gesture the arrows were asked for: copy a passage of volume, walk the frame down onto pan
    /// with ↓, paste, and the curve arrives at the SAME INSTANT on the other parameter.
    ///
    /// With no zone, the playhead gives the instant and the loose selection's rows give the
    /// destination — the fallback `pasteMidiNotes` already uses, snapped to the grid like it.
    ///
    /// Three rules, each of which is a decision and not a default:
    ///
    /// - THE RANGE IS REPLACED, not added to. An automation is a function of time: two sets of
    ///   points over one stretch do not layer, they interleave into a curve that is neither. So
    ///   everything already inside [anchor, anchor + duration] goes first.
    /// - ONTO THE SAME PARAMETER the values are kept EXACTLY; onto a different one they are kept
    ///   in PROPORTION. -96…+40 dB and -1…+1 are not the same ruler, and a volume curve pasted
    ///   raw onto a pan would flatten onto the bound and arrive as a straight line. The shape is
    ///   what one copies.
    /// - Rows pair UP IN ORDER, as many as both sides have. A passage copied from two rows lands
    ///   on the zone's first two; one copied from one row lands on the first.
    func pasteAutomation() {
        guard let cb = automationClipboard, !cb.rows.isEmpty,
              let dst = automationTimeSelection ?? adoptedAutomationZone(),
              find(id: dst.objectID) != nil else { return }

        let anchor: Double = {
            if automationTimeSelection != nil { return dst.timeRange.lowerBound }
            // No zone: the playhead, read in the object's own time base, exactly as a MIDI paste
            // reads it in the clip's (@see pasteMidiNotes).
            let g = effectiveSnapGrid
            let abs = (effectiveSnapEnabled && g > 0)
                ? (cursorPosition / g).rounded() * g : cursorPosition
            return abs - (find(id: dst.objectID)?.startTime ?? 0)
        }()

        let pairs = zip(cb.rows, dst.params).map { ($0, $1) }
        guard !pairs.isEmpty else { return }

        pushUndo()
        // A hair of tolerance on the wiped range: a point laid exactly on an edge by a snapped
        // gesture is INSIDE the passage that replaces it, and a strict comparison on a double
        // that has been through a conversion leaves it behind as a duplicate.
        let eps = 1e-9
        update(id: dst.objectID) { obj in
            for (row, target) in pairs {
                let sr = row.param.valueRange, tr = target.valueRange
                let convert = row.param == target
                let mapped = row.points.map { p -> AutomationPoint in
                    var c = p
                    c.t = anchor + p.t
                    if !convert {
                        let n = AutomationTransform.normalized(Double(p.v),
                                                               lo: Double(sr.lowerBound),
                                                               hi: Double(sr.upperBound))
                        c.v = Float(AutomationTransform.denormalized(n,
                                                                     lo: Double(tr.lowerBound),
                                                                     hi: Double(tr.upperBound)))
                    }
                    c.v = c.v.clamped(to: tr)
                    return c
                }
                if let li = obj.automation.firstIndex(where: { $0.param == target }) {
                    obj.automation[li].points.removeAll {
                        $0.t >= anchor - eps && $0.t <= anchor + cb.duration + eps
                    }
                    obj.automation[li].points.append(contentsOf: mapped)
                } else if !mapped.isEmpty {
                    obj.automation.append(AutomationLane(param: target, points: mapped))
                }
            }
            // 'No point = no automation': a row left empty by the wipe goes, rather than lingering
            // as a curve that draws nothing and outranks the static value.
            obj.automation.removeAll { $0.points.isEmpty }
        }
        // A send that has just gained or lost its curve needs its plugin wired before the push,
        // exactly as `deleteSelectedAutomationPoints` orders it.
        for (_, target) in pairs {
            if case .send(let auxID) = target {
                syncSendEngine(objectID: dst.objectID, auxID: auxID)
            }
        }
        pushAutomation(dst.objectID)
        // The frame lands where the passage did — so a second ⌘V, after an arrow, goes on reading
        // the same way, and so the eye sees what has just been laid down.
        setAutomationZone(objectID: dst.objectID,
                          timeRange: anchor...(anchor + cb.duration),
                          params: pairs.map { $0.1 })
        isDirty = true
    }
}

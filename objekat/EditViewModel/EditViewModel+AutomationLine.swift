import Foundation

// Moving an automation LINE in value — the ONE implementation behind every hand that does it.
//
// The band's drag (@see AutomationBandView.beginDrag / applyDrag) and the mouse wheel over a
// highlighted line (@see TimelineKeyHandler.registerScrollMonitor) are two ways into the SAME
// operation, so they go through the same two functions: `automationLineGrab` decides WHAT a hand
// aimed at the line takes hold of (and what the selection does about it), and `shiftAutomationLine`
// carries it by a vertical travel in pixels. Detent, clamping, the selection's semantics and the
// engine push live here and nowhere else; a wheel that re-implemented them would drift from the
// drag the first time either was touched.

/// One row of a group move: which curve, which of its points, and what the WHOLE lane was when
/// the gesture began (the anchors every frame is recomputed from — never compounded).
struct AutomationMovedRow {
    let param:      ParamRef
    let row:        Int                  // display row: geometry and nothing else
    let indices:    [Int]                // storage indices, validated at the grab
    let origPoints: [AutomationPoint]
}

/// What a hand grabbed when it took hold of a line, FROZEN at the grab.
enum AutomationLineGrab {
    /// A row with no point: the model's static value.
    case staticValue(orig: Float)
    /// A segment (or a plateau) of a curve: the storage indices of the points holding it, the
    /// lane as it was, and the whole selection when what was grabbed belongs to it.
    case segment(indices: [Int], orig: [AutomationPoint], carried: [AutomationMovedRow]?)
}

extension EditViewModel {

    // MARK: - The value's detent

    /// A value brought onto the parameter's DETENT — a whole dB, pan by 10 % (@see
    /// ParamRef.valueStep). UNCONDITIONAL: it never reads the grid's snap (@see the automation
    /// band's 19 September 2026 correction). A plugin parameter has no step and stays exact.
    static func automationDetentedValue(_ v: Float, ref: ParamRef) -> Float {
        guard let step = ref.valueStep, step > 0 else { return v }
        return ((v / step).rounded() * step).clamped(to: ref.valueRange)
    }

    /// The same detent, for a DIFFERENCE: no bounding to the range, a difference is not a value.
    static func automationDetentedDelta(_ dv: Float, ref: ParamRef) -> Float {
        guard let step = ref.valueStep, step > 0 else { return dv }
        return (dv / step).rounded() * step
    }

    // MARK: - Taking hold of a line

    /// The whole selection, when what was grabbed belongs to it — otherwise nil AND the selection
    /// dropped. "What one grabs decides", the rule the crossfades and the plugin cards follow.
    func carriedAutomationRows(containing grabbed: Set<AutomationPointRef>,
                               object: SoundObject, rows: [ParamRef]) -> [AutomationMovedRow]? {
        guard !grabbed.isEmpty, grabbed.isSubset(of: selectedAutomationPoints) else {
            clearAutomationPointSelection()
            return nil
        }
        var out: [AutomationMovedRow] = []
        for (i, ref) in rows.enumerated() {
            let idx = selectedIndices(objectID: object.id, param: ref)
            if !idx.isEmpty {
                let pts = object.automation.first(where: { $0.param == ref })?.points ?? []
                out.append(AutomationMovedRow(param: ref, row: i, indices: idx, origPoints: pts))
            }
        }
        return out
    }

    /// What a hand at `p` (the band's local coordinates) takes hold of on this row's LINE — nil if
    /// the line is not under it. It is exactly the condition under which the band highlights the
    /// line: a row with no point is grabbed ON its static line, a POINT wins over the line carrying
    /// it (so nil here), and a curve is grabbed within the band of `nearLine` around it.
    ///
    /// Side effect, on purpose and shared: grabbing a segment OUTSIDE the selection drops the
    /// selection (@see carriedAutomationRows). Call it only when the gesture really begins.
    func automationLineGrab(object: SoundObject, rows: [ParamRef], geo: AutomationBandGeometry,
                            row: Int, at p: CGPoint) -> AutomationLineGrab? {
        guard rows.indices.contains(row) else { return nil }
        let ref = rows[row]
        let pts = object.automation.first(where: { $0.param == ref })?.points ?? []
        if pts.isEmpty {
            // A plugin parameter has no static value on the model's side: nothing to set.
            guard let sv = automationStaticValue(ref, on: object),
                  geo.nearLine(p, lineY: geo.y(of: sv, ref: ref, row: row)) else { return nil }
            return .staticValue(orig: sv)
        }
        if geo.pointHit(at: p, row: row, ref: ref, points: pts) != nil { return nil }
        guard let lineY = geo.curveY(atX: p.x, ref: ref, row: row, points: pts),
              geo.nearLine(p, lineY: lineY),
              let seg = geo.segment(atX: p.x, points: pts), !seg.movedPoints.isEmpty else { return nil }
        let carried = carriedAutomationRows(
            containing: Set(seg.movedPoints.map {
                AutomationPointRef(objectID: object.id, param: ref, index: $0)
            }), object: object, rows: rows)
        return .segment(indices: seg.movedPoints, orig: pts, carried: carried)
    }

    // MARK: - Carrying it

    /// Carries a grabbed line by a vertical travel `dy` (pixels, downwards positive, from the
    /// grab's anchors — a TOTAL, never a per-frame delta, so rounding lands on the result and
    /// never feeds the next frame). Returns the value to show in the readout, nil if nothing moved.
    /// No undo point: the gesture pushes one, once, at its start.
    @discardableResult
    func shiftAutomationLine(_ grab: AutomationLineGrab, objectID: UUID, param ref: ParamRef,
                             row: Int, dy: Double, geo: AutomationBandGeometry) -> Float? {
        switch grab {
        case .staticValue(let orig):
            let v = Self.automationDetentedValue(
                (orig + geo.valueDelta(dy: dy, ref: ref)).clamped(to: ref.valueRange), ref: ref)
            setAutomationStaticValue(ref, on: objectID, to: v)
            return v

        case .segment(let idxs, let orig, let carried):
            // Dragging a straight whose two ends are taken moves the WHOLE selection, and not just
            // that straight: the line is a handle on the matter.
            if let carried {
                return moveAutomationRows(carried, objectID: objectID, dt: 0, dy: dy,
                                          startedRow: row, geo: geo)
            }
            let origs = idxs.compactMap { orig.indices.contains($0) ? orig[$0].v : nil }
            guard let lo = origs.min(), let hi = origs.max() else { return nil }
            // The segment moves by a SINGLE difference: clamping it point by point would flatten it
            // against the bound instead of holding it whole. The DIFFERENCE is rounded, not each
            // value: a segment sitting on round figures stays there.
            let range = ref.valueRange
            let dv = Self.automationDetentedDelta(geo.valueDelta(dy: dy, ref: ref), ref: ref)
                .clamped(to: (range.lowerBound - lo)...(range.upperBound - hi))
            updateAutomationPoints(objectID: objectID, param: ref) { pts in
                for i in idxs where pts.indices.contains(i) && orig.indices.contains(i) {
                    pts[i].v = orig[i].v + dv
                }
            }
            return origs[0] + dv
        }
    }

    /// Moving a whole SELECTION — the shared body of a point drag and of a segment drag when what
    /// was grabbed belongs to it. `dt` is the common time delta (zero for a segment); `dy` the raw
    /// vertical travel, read differently on either side of ONE branch:
    ///
    /// - a selection inside ONE row: the difference in the PARAMETER's own unit, detent included,
    ///   bounded so the row holds its internal differences instead of flattening against a bound;
    /// - a selection spanning SEVERAL rows: a NORMALISED difference, per row and WITHOUT a detent
    ///   (a common delta "of one dB" would move a pan row by half its range).
    @discardableResult
    func moveAutomationRows(_ trows: [AutomationMovedRow], objectID: UUID, dt: Double, dy: Double,
                            startedRow: Int, geo g: AutomationBandGeometry) -> Float? {
        let multi = trows.count > 1
        let dn = multi ? g.normalizedDelta(dy: dy) : 0
        var shown: Float? = nil
        updateAutomationRows(objectID: objectID) { lanes in
            for tr in trows {
                guard let li = lanes.firstIndex(where: { $0.param == tr.param }) else { continue }
                let taken = tr.indices.filter {
                    tr.origPoints.indices.contains($0) && lanes[li].points.indices.contains($0)
                }
                guard !taken.isEmpty else { continue }

                var dv: Float = 0
                if !multi {
                    let origs = taken.map { tr.origPoints[$0].v }
                    let range = tr.param.valueRange
                    let low  = range.lowerBound - (origs.min() ?? 0)
                    let high = range.upperBound - (origs.max() ?? 0)
                    dv = Self.automationDetentedDelta(g.valueDelta(dy: dy, ref: tr.param), ref: tr.param)
                    // A selection already spanning the parameter's WHOLE range leaves no room to
                    // move at all, and the bounds cross: then nothing moves.
                    if low <= high { dv = dv.clamped(to: low...high) }
                    else           { dv = 0 }
                }

                for i in taken {
                    let o = tr.origPoints[i]
                    lanes[li].points[i].t = o.t + dt
                    lanes[li].points[i].v = multi
                        ? g.denormalized((g.normalized(o.v, ref: tr.param) + dn).clamped(to: 0...1),
                                         ref: tr.param)
                        : o.v + dv
                }
                if tr.row == startedRow, let first = taken.first {
                    shown = lanes[li].points[first].v
                }
            }
        }
        return shown
    }

    // MARK: - The wheel's door

    /// The travel of ONE wheel step, in the parameter's own unit: its detent (a whole dB, 10 % of
    /// pan — the volume / pan / send wheels' own step), or a hundredth of the range for a
    /// parameter with none.
    static func automationWheelStepValue(_ ref: ParamRef) -> Float {
        if let s = ref.valueStep, s > 0 { return s }
        let r = ref.valueRange
        return (r.upperBound - r.lowerBound) / 100
    }

    /// The wheel's way into `shiftAutomationLine`: `steps` (TOTAL since the gesture's grab, upwards
    /// positive) become the vertical travel a drag of the same amount would have made, so
    /// everything downstream — detent, clamping, selection, push — is the drag's own code. Shows the
    /// value where the hover would (@see automationLineWheelReadout).
    func wheelShiftAutomationLine(_ grab: AutomationLineGrab,
                                  objectID: UUID, param ref: ParamRef, row: Int,
                                  steps: Int, geo: AutomationBandGeometry) {
        let r = ref.valueRange
        let span = Double(r.upperBound - r.lowerBound)
        guard span > 0 else { return }
        let dy = -(Double(steps) * Double(Self.automationWheelStepValue(ref))) / span * geo.usableHeight
        if let v = shiftAutomationLine(grab, objectID: objectID, param: ref, row: row, dy: dy, geo: geo) {
            automationLineWheelGeneration &+= 1
            let generation = automationLineWheelGeneration
            automationLineWheelReadout = (objectID: objectID, param: ref, value: v)
            // A figure read stays on screen no longer than the hand that asked for it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                guard let self, self.automationLineWheelGeneration == generation else { return }
                self.automationLineWheelReadout = nil
            }
        }
    }
}

import Foundation

/// The geometry of an automation band: the conversion between the band's LOCAL coordinates
/// (x = 0 at the object's start, y = 0 at the band's top) and the model (row, time, value).
///
/// It lives apart from the view because it has TWO clients: `AutomationBandView` (drawing, tap,
/// drag) and the timeline's wheel monitor (@see TimelineKeyHandler), which resolves the same
/// hovered point without going through SwiftUI. Two copies of this computation would drift, and
/// the wheel would end up bending a segment other than the one drawn under the cursor.
///
/// An automation row is LOW (one lane, sometimes 16 px): so every grab zone is bounded in
/// pixels, never in fractions of the height, so as to stay grabbable.
struct AutomationBandGeometry {
    let rows: [ParamRef]
    let pixelsPerSecond: Double
    /// A row's vertical pitch (the drawn height plus the gutter).
    let laneStep: Double
    /// A row's DRAWN height (= `blockHeight`).
    let rowHeight: Double
    /// The band's width — the object's, or the whole timeline for an infinite bus.
    let bandWidth: Double

    /// The top/bottom margin inside a row: a value at the top of its range has to stay visible
    /// and not be confused with the edge.
    static let vInset: Double = 3

    /// The maximum time reachable in this band. It reads off the WIDTH, not off the object's
    /// length: an infinite bus has no end and its band covers the whole timeline.
    var maxT: Double { pixelsPerSecond > 0 ? bandWidth / pixelsPerSecond : 0 }

    /// The band's height. A band with NO row still keeps one lane, like the rectangle the parent
    /// reserves for it (@see SoundObject.automationSpan, bounded at 1): otherwise the interaction
    /// layer would shrink to one pixel and the right click — the only way to open a row when
    /// nothing is on offer — would become unaimable.
    var bandHeight: Double { Double(max(1, rows.count)) * laneStep }

    /// The height the band REALLY takes: the last gutter does not belong to it.
    /// It is the height of the rectangle the parent computes (@see TimelineView.automationBandRect)
    /// and therefore the one to give the interaction layer — otherwise the band would catch the
    /// clicks of the few pixels between its last row and the next lane.
    var interactiveHeight: Double { max(1, bandHeight - (laneStep - rowHeight)) }

    // MARK: - Rows

    func rowTop(_ row: Int) -> Double { Double(row) * laneStep }

    /// The row under a y. The gutter between two rows is attached to the nearest row rather than
    /// treated as a dead zone: on a low band, a few pixels lost between two rows are felt at once.
    func rowIndex(atY y: Double) -> Int? {
        guard !rows.isEmpty, y >= 0, y < bandHeight else { return nil }
        return Int((y / laneStep).rounded(.down)).clamped(to: 0...(rows.count - 1))
    }

    // MARK: - Time ↔ x

    func x(ofT t: Double) -> Double { t * pixelsPerSecond }

    func t(atX x: Double) -> Double {
        guard pixelsPerSecond > 0 else { return 0 }
        return (x / pixelsPerSecond).clamped(to: 0...max(0, maxT))
    }

    // MARK: - Value ↔ y

    /// A row's usable height, in pixels: what the parameter's WHOLE range covers.
    var usableHeight: Double { max(1, rowHeight - 2 * Self.vInset) }

    func y(of value: Float, ref: ParamRef, row: Int) -> Double {
        let range = ref.valueRange
        let span  = Double(range.upperBound - range.lowerBound)
        let norm  = span > 0 ? Double(value.clamped(to: range) - range.lowerBound) / span : 0.5
        return rowTop(row) + Self.vInset + usableHeight * (1 - norm)
    }

    func value(atY y: Double, ref: ParamRef, row: Int) -> Float {
        let range = ref.valueRange
        let span  = Double(range.upperBound - range.lowerBound)
        let norm  = (1 - (y - rowTop(row) - Self.vInset) / usableHeight).clamped(to: 0...1)
        return (range.lowerBound + Float(norm * span)).clamped(to: range)
    }

    /// A vertical movement in pixels → a difference in value (upwards = a rising value).
    func valueDelta(dy: Double, ref: ParamRef) -> Float {
        let range = ref.valueRange
        let span  = Double(range.upperBound - range.lowerBound)
        return Float(-dy / usableHeight * span)
    }

    // MARK: - Grabbing

    /// Half the width / half the height of a point's grab zone. Bounded in pixels: on a tall row,
    /// a point must not capture all the space above and below it (that is where the segment
    /// slips in); on a low row, it has to stay catchable.
    ///
    /// Deliberately wide: a point is a 5 px disc, and aiming at its exact surface with the mouse is
    /// a jeweller's job. The hover says so (@see AutomationBandView, which lays a halo as soon as
    /// the cursor comes in here), so the zone can be generous without becoming a trap.
    var pointGrabX: Double { 10 }
    var pointGrabY: Double { min(12, max(6, rowHeight * 0.5)) }

    /// Half the height of the zone that grabs THE CURVE itself (dragging a segment, or the static
    /// value of an empty row): 15 % of the row's height on either side of the line, so 30 % in
    /// all. Bounded in pixels like the rest.
    ///
    /// Without it, a drag anywhere in the row moved the segment: one could no longer hover a row
    /// without risking knocking it out. The curve is now grabbed WHERE IT IS — the rest of the row
    /// answers to nothing.
    var curveGrabY: Double { min(28, max(8, rowHeight * 0.15)) }

    /// A row's points sorted by time, with their STORAGE index — the only stable identifier of a
    /// point during a gesture (@see EditViewModel.updateAutomationPoints).
    func ordered(_ points: [AutomationPoint]) -> [(index: Int, point: AutomationPoint)] {
        points.enumerated()
            .map { (index: $0.offset, point: $0.element) }
            .sorted { $0.point.t < $1.point.t }
    }

    /// The storage index of the point grabbed at `p`, if there is one. The nearest wins when two
    /// points overlap.
    func pointHit(at p: CGPoint, row: Int, ref: ParamRef, points: [AutomationPoint]) -> Int? {
        var best: (index: Int, dist: Double)? = nil
        for (i, pt) in points.enumerated() {
            let dx = p.x - x(ofT: pt.t)
            let dy = p.y - y(of: pt.v, ref: ref, row: row)
            guard abs(dx) <= pointGrabX, abs(dy) <= pointGrabY else { continue }
            let d = hypot(dx, dy)
            if best == nil || d < best!.dist { best = (i, d) }
        }
        return best?.index
    }

    /// The y of the LINE at an x, plateaux and curvature included — exactly what
    /// `AutomationBandView` draws, since it is the same function the engine uses.
    /// nil on a row with no point (its line is that of the static value, which only the view
    /// knows).
    func curveY(atX x: Double, ref: ParamRef, row: Int, points: [AutomationPoint]) -> Double? {
        let sorted = ordered(points).map(\.point)
        guard let first = sorted.first else { return nil }
        let v = AutomationCurveMath.value(at: t(atX: x), in: sorted, default: first.v)
        return y(of: v, ref: ref, row: row)
    }

    /// Does the point `p` fall inside the grab band of the line drawn at `lineY`?
    func nearLine(_ p: CGPoint, lineY: Double) -> Bool { abs(p.y - lineY) <= curveGrabY }

    /// The curve segment under an x, named by the STORAGE indices of its ends.
    ///
    /// Both PLATEAUX count as segments: before the first point (`left == nil`) and after the last
    /// (`right == nil`). Dragging them raises/lowers the point holding them — that is the natural
    /// gesture there, and without it both ends of a curve would be inert.
    /// Only a segment with two ends carries a CURVATURE (that of its left-hand point).
    struct Segment {
        var left:  Int?
        var right: Int?
        /// The storage index of the point carrying the curvature, nil on a plateau.
        var curveOwner: Int? { (left != nil && right != nil) ? left : nil }
        /// The storage indices of the points a vertical drag moves.
        var movedPoints: [Int] { [left, right].compactMap { $0 } }
    }

    func segment(atX x: Double, points: [AutomationPoint]) -> Segment? {
        let pts = ordered(points)
        guard !pts.isEmpty else { return nil }
        let t = self.t(atX: x)
        if t <= pts[0].point.t { return Segment(left: nil, right: pts[0].index) }
        if let last = pts.last, t >= last.point.t { return Segment(left: last.index, right: nil) }
        for i in 0..<(pts.count - 1) where t >= pts[i].point.t && t < pts[i + 1].point.t {
            return Segment(left: pts[i].index, right: pts[i + 1].index)
        }
        return nil
    }
}

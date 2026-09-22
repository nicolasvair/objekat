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

    // MARK: - Selecting points, and the box that transforms them

    /// Half-side of the square a marquee has to touch to take a point. NOT `pointGrabX` (10 pt): a
    /// rectangle drawn BETWEEN two points fifteen pixels apart would take both without touching
    /// either, and a selection one did not draw is worse than one that takes an extra click to
    /// finish. A grab zone has to be generous because it answers a single click; a rectangle
    /// already says its own extent.
    var pointMarqueeInset: Double { 4 }

    /// Half-side of a transform grip's catching square. The grip is drawn smaller than that: what
    /// is aimed at here is a corner of a box on a sixteen-pixel row.
    var handleGrab: Double { 6 }

    /// Where a point sits, in the band's coordinates — the one conversion `pointsTouching` and the
    /// ⇧+click box both need, and the reason neither of them has to know about `ParamRef`.
    func center(of p: AutomationPoint, ref: ParamRef, row: Int) -> CGPoint {
        CGPoint(x: x(ofT: p.t), y: y(of: p.v, ref: ref, row: row))
    }

    /// The square a rectangle has to touch to take this point — what ⇧+click unions into a box
    /// (@see AutomationBandView.handleTap).
    func marqueeRect(of p: AutomationPoint, ref: ParamRef, row: Int) -> CGRect {
        let c = center(of: p, ref: ref, row: row)
        return CGRect(x: c.x - pointMarqueeInset, y: c.y - pointMarqueeInset,
                      width: pointMarqueeInset * 2, height: pointMarqueeInset * 2)
    }

    /// The STORAGE indices of the points of ONE row a rectangle takes. The rule itself lives in
    /// `AutomationTransform.touching` — which is where the flat-rectangle divergence from
    /// `SynopticMarquee` is argued and asserted; all that is left here is the wiring.
    func pointsTouching(_ rect: CGRect, row: Int, ref: ParamRef,
                        points: [AutomationPoint]) -> [Int] {
        AutomationTransform.touching(rect,
                                     points: points.map { center(of: $0, ref: ref, row: row) },
                                     inset: pointMarqueeInset)
    }

    // MARK: - Normalised values

    /// A parameter's value → NORMALISED (0 = the bottom of its range, 1 = its top). A two-line
    /// wrapper over `AutomationTransform.normalized`, whose only job is the `ParamRef` lookup:
    /// the arithmetic stays in the unit that can be asserted with no screen.
    func normalized(_ v: Float, ref: ParamRef) -> Double {
        let r = ref.valueRange
        return AutomationTransform.normalized(Double(v), lo: Double(r.lowerBound),
                                              hi: Double(r.upperBound))
    }

    func denormalized(_ n: Double, ref: ParamRef) -> Float {
        let r = ref.valueRange
        return Float(AutomationTransform.denormalized(n, lo: Double(r.lowerBound),
                                                      hi: Double(r.upperBound)))
    }

    /// The normalised value a y asks for, WITHOUT clamping — and that is the whole point: asking
    /// for more than 1 is how a selection whose top point already sits at the ceiling raises the
    /// others while that one stays put. `value(atY:)` clamps, and would have frozen the gesture the
    /// moment one point reached the top.
    ///
    /// It no longer feeds the transform grips — those read a ratio of pixels off the box itself
    /// (@see AutomationTransform.boxFactor), which holds the same requirement one level up and
    /// leaves no per-row clamp to forget. It is kept because the requirement is the same wherever
    /// the pointer is read, and because a row's own normalised height is the natural unit here.
    func rawNormalized(atY y: Double, row: Int) -> Double {
        1 - (y - rowTop(row) - Self.vInset) / usableHeight
    }

    /// A vertical travel in pixels → a NORMALISED difference. The group move's own unit as soon as
    /// the selection spans two rows: a common delta in dB means nothing to a pan row, where the
    /// whole range is two units wide.
    func normalizedDelta(dy: Double) -> Double { -dy / usableHeight }

    // MARK: - The transform box

    /// The shortest side the box is ever drawn with, in X. A selection of ONE point has no time
    /// extent at all, and a box of zero width carries no grip one could aim at. In Y nothing needs
    /// inflating: the box covers at least one whole row.
    static let boxMinSide: Double = 10

    /// The transform box, in the band's coordinates. X = the selection's time envelope, every row
    /// together. Y = the TOP of the highest row the selection touches down to the BOTTOM of the
    /// lowest — deliberately NOT the points' vertical extent.
    ///
    /// THE TWO AXES ARE ASYMMETRIC, on purpose. In X the box HUGS THE MATERIAL (the points' own
    /// time envelope), so the pulled edge follows the hand; in Y it COVERS THE ROWS, so the travel
    /// is linear over the parameter's whole range. Time has a natural EXTENT — the material's; a
    /// value has a natural RANGE — the parameter's. Each grip acts on the natural thing of its own
    /// axis.
    ///
    /// nil on an empty selection: nothing to draw, nothing to grab.
    func selectionBox(_ sel: [(row: Int, ref: ParamRef, indices: [Int],
                               points: [AutomationPoint])]) -> CGRect? {
        var lo = Double.greatestFiniteMagnitude, hi = -Double.greatestFiniteMagnitude
        var minRow = Int.max, maxRow = Int.min
        for r in sel {
            for i in r.indices where r.points.indices.contains(i) {
                lo = Swift.min(lo, x(ofT: r.points[i].t))
                hi = Swift.max(hi, x(ofT: r.points[i].t))
                minRow = Swift.min(minRow, r.row)
                maxRow = Swift.max(maxRow, r.row)
            }
        }
        guard minRow <= maxRow else { return nil }
        if hi - lo < Self.boxMinSide {
            let mid = (lo + hi) / 2
            lo = mid - Self.boxMinSide / 2
            hi = mid + Self.boxMinSide / 2
        }
        let top    = rowTop(minRow)
        let bottom = rowTop(maxRow) + rowHeight
        return CGRect(x: lo, y: top, width: hi - lo, height: bottom - top)
    }

    /// The eight grips, in the box's own coordinates. It takes a plain `CGRect` and knows nothing
    /// of rows — which is why a box spanning several of them needed no change here at all.
    static func handleCenters(of box: CGRect) -> [(AutomationTransform.Handle, CGPoint)] {
        [(.topLeft,     CGPoint(x: box.minX, y: box.minY)),
         (.top,         CGPoint(x: box.midX, y: box.minY)),
         (.topRight,    CGPoint(x: box.maxX, y: box.minY)),
         (.left,        CGPoint(x: box.minX, y: box.midY)),
         (.right,       CGPoint(x: box.maxX, y: box.midY)),
         (.bottomLeft,  CGPoint(x: box.minX, y: box.maxY)),
         (.bottom,      CGPoint(x: box.midX, y: box.maxY)),
         (.bottomRight, CGPoint(x: box.maxX, y: box.maxY))]
    }

    /// The grip under a point, if any. The CORNERS are tested first: on a box barely wider than a
    /// grip they overlap the edge grips, and a corner is the harder of the two to aim at.
    func handleHit(at p: CGPoint, box: CGRect) -> AutomationTransform.Handle? {
        let all = Self.handleCenters(of: box)
        let corners = all.filter { h, _ in
            h == .topLeft || h == .topRight || h == .bottomLeft || h == .bottomRight
        }
        for (h, c) in corners + all
        where abs(p.x - c.x) <= handleGrab && abs(p.y - c.y) <= handleGrab {
            return h
        }
        return nil
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

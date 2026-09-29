import Foundation

// Where the timeline's view has to go so that a SELECTION MADE IN THE SOUND LIST is seen.
//
// Selecting a row of the left panel is a way of saying "show me that". The list scrolls itself
// onto the row (@see SoundObjectListView.rowToReveal); this is the other half — the timeline
// answering. It is arithmetic and nothing else: a box in time × display lanes, a description of
// what the view shows now, and what has to change so that the box is in it. No view, no model,
// no scroll view — the half of the feature with nothing behind it, hence assertable with no
// screen (`tools/test_timeline_reveal.swift`), like `PianoRollFraming` and `VerticalLaneSnap`.
//
//     swiftc -parse-as-library ../objekat/Timeline/TimelineReveal.swift test_timeline_reveal.swift \
//         -o /tmp/tlreveal && /tmp/tlreveal
//
// THE RULES, one per axis, and they are independent:
//
//   Nothing to do when the box is ALREADY entirely visible on that axis — a view that moves under
//   a selection one can already see is a view one has to re-find. (Decision validated with the
//   user; it is also what makes a repeated click on the same row harmless.)
//
//   HORIZONTAL. A box that fits in the window width is brought in by CENTRING it. A box that does
//   not fit is a different question and depends on how many objects it is made of: a SINGLE
//   object is never zoomed onto (its length is the object's own, and zooming to see all of it is
//   a decision to make by hand) — it is brought in by putting its start just inside the left
//   edge, and left alone if any of it is already on screen; SEVERAL objects are framed by zooming
//   out until the box takes `fitFraction` of the width, bounded by the timeline's own zoom
//   limits, and then centred (centring is done after the bound, so a box a zoom-out limit cannot
//   contain is still centred rather than left wherever it was).
//
//   VERTICAL. No vertical zoom, ever: the block height is the user's. With the lane snap active
//   the answer is a LANE to frame (`frameLane`, the one door every snap gesture converges on —
//   this file does not know its arithmetic); free, it is a scroll that centres the box's rows if
//   they fit under the header, and otherwise puts the FIRST row just under it, the top being where
//   a passage is read from.
//
// All of it in the timeline's own coordinates: seconds and points, scroll offsets as the scroll
// view reports them (the sticky header is INSIDE the content, `rulerHeight` tall).
enum TimelineReveal {

    /// What has to be shown: a stretch of time and a stretch of DISPLAY lanes (inclusive). The
    /// time is nil when there is none to speak of — a selection made only of infinite buses,
    /// whose band has neither start nor end.
    struct Box: Equatable {
        var timeRange: ClosedRange<Double>?
        var laneRange: ClosedRange<Int>
        /// One object selected. It changes the horizontal answer for a box wider than the window.
        var isSingleObject: Bool
    }

    /// What the view shows now, and the limits it must stay within.
    struct View {
        var viewportWidth: Double
        var scrollX: Double
        var pixelsPerSecond: Double
        /// The timeline's own zoom bounds (`minZoom` / `maxZoom`), never a number of ours.
        var minPixelsPerSecond: Double
        var maxPixelsPerSecond: Double
        /// The furthest the view scrolls right at a GIVEN zoom. A function because the canvas's
        /// width depends on the zoom (its headroom is a fraction of the window).
        var maxScrollX: (Double) -> Double

        var viewportHeight: Double
        var scrollY: Double
        var maxScrollY: Double
        var rulerHeight: Double
        var laneStep: Double
        var blockHeight: Double
        /// The vertical lane snap is on (@see VerticalLaneSnap.isActive).
        var snapActive: Bool
    }

    /// What to change. nil = leave that as it is.
    struct Frame: Equatable {
        var pixelsPerSecond: Double? = nil
        var scrollX: Double? = nil
        /// Free vertical mode: the scroll to go to.
        var scrollY: Double? = nil
        /// Snap mode: the display lane to frame.
        var frameLane: Int? = nil

        var isEmpty: Bool {
            pixelsPerSecond == nil && scrollX == nil && scrollY == nil && frameLane == nil
        }
    }

    /// A box that has to be zoomed onto takes this much of the window width.
    static let fitFraction: Double = 0.8
    /// A single object wider than the window comes in with its start this far from the left
    /// edge, as a fraction of the width.
    static let leadingMargin: Double = 0.06
    /// Half a point: below it a scroll is not a scroll, and a "visible" edge is visible.
    static let tolerance: Double = 0.5

    static func frame(box: Box, view v: View) -> Frame {
        var out = Frame()
        if let range = box.timeRange {
            let h = horizontal(range, v, allowZoom: !box.isSingleObject)
            out.pixelsPerSecond = h.pixelsPerSecond
            out.scrollX = h.scrollX
        }
        let vert = vertical(box.laneRange, v)
        out.scrollY = vert.scrollY
        out.frameLane = vert.frameLane
        return out
    }

    // MARK: - Horizontal

    static func horizontal(_ range: ClosedRange<Double>, _ v: View,
                           allowZoom: Bool) -> (pixelsPerSecond: Double?, scrollX: Double?) {
        let vw = v.viewportWidth, pps = v.pixelsPerSecond
        guard vw > 0, pps > 0, range.lowerBound.isFinite, range.upperBound.isFinite else { return (nil, nil) }
        let x0 = range.lowerBound * pps, x1 = range.upperBound * pps
        let width = x1 - x0
        let eps = tolerance

        if width <= vw + eps {
            // It fits: already in, or bring it in by centring.
            if x0 >= v.scrollX - eps, x1 <= v.scrollX + vw + eps { return (nil, nil) }
            return (nil, scroll(toCentre: range, pps: pps, v))
        }

        // Wider than the window.
        guard allowZoom else {
            // A single object: never zoomed onto. Left alone if any of it is in view.
            if x1 > v.scrollX, x0 < v.scrollX + vw { return (nil, nil) }
            let target = clampScroll(x0 - leadingMargin * vw, pps: pps, v)
            return (nil, abs(target - v.scrollX) < eps ? nil : target)
        }

        let span = max(range.upperBound - range.lowerBound, 1e-9)
        let wanted = fitFraction * vw / span
        let newPPS = min(max(wanted, v.minPixelsPerSecond), v.maxPixelsPerSecond)
        let target = scroll(toCentre: range, pps: newPPS, v)
        return (abs(newPPS - pps) > 1e-12 * max(1, pps) ? newPPS : nil, target)
    }

    /// The scroll that centres `range` at `pps`, bounded. nil when it is where it already is at
    /// the CURRENT zoom — but always returned when the zoom changes, since the offset a new scale
    /// needs is never the old one.
    private static func scroll(toCentre range: ClosedRange<Double>, pps: Double, _ v: View) -> Double? {
        let centre = (range.lowerBound + range.upperBound) / 2 * pps
        let target = clampScroll(centre - v.viewportWidth / 2, pps: pps, v)
        if pps == v.pixelsPerSecond, abs(target - v.scrollX) < tolerance { return nil }
        return target
    }

    private static func clampScroll(_ x: Double, pps: Double, _ v: View) -> Double {
        min(max(0, v.maxScrollX(pps)), max(0, x))
    }

    // MARK: - Vertical

    static func vertical(_ lanes: ClosedRange<Int>, _ v: View) -> (scrollY: Double?, frameLane: Int?) {
        guard v.laneStep > 0, v.viewportHeight > 0 else { return (nil, nil) }
        let top = v.rulerHeight + Double(lanes.lowerBound) * v.laneStep
        let bottom = v.rulerHeight + Double(lanes.upperBound) * v.laneStep + v.blockHeight
        let eps = tolerance
        // The header is sticky and INSIDE the content: what is really visible starts under it.
        if top >= v.scrollY + v.rulerHeight - eps, bottom <= v.scrollY + v.viewportHeight + eps {
            return (nil, nil)
        }
        if v.snapActive { return (nil, lanes.lowerBound) }

        let available = max(0, v.viewportHeight - v.rulerHeight)
        let target: Double
        if bottom - top <= available {
            target = (top + bottom) / 2 - v.rulerHeight - available / 2
        } else {
            target = top - v.rulerHeight
        }
        let clamped = min(max(0, v.maxScrollY), max(0, target))
        return (abs(clamped - v.scrollY) < eps ? nil : clamped, nil)
    }
}

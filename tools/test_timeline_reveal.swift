// "Selecting in the sound list brings the timeline's view to it" — the arithmetic behind it,
// asserted with no screen. `TimelineReveal` (`Timeline/TimelineReveal.swift`) has no view and no
// model behind it, which is why it can be compiled and run alone, exactly like `PianoRollFraming`
// and `VerticalLaneSnap` before it.
//
//     swiftc -parse-as-library \
//         ../objekat/Timeline/TimelineReveal.swift test_timeline_reveal.swift \
//         -o /tmp/tlreveal && /tmp/tlreveal
//
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation

var fails: [String] = []
var total = 0

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    total += 1
    if ok { print("ok    " + label) }
    else { fails.append(label); print("FAIL  \(label)  \(detail)") }
}

func near(_ a: Double?, _ b: Double, _ tol: Double = 1e-6) -> Bool {
    guard let a else { return false }
    return abs(a - b) <= tol
}

/// A 1000 pt wide window, 100 pps, scrolled to x = 2000 (so it shows 20 s … 30 s). Canvas: 600 s
/// wide. 400 pt tall, ruler 40, lanes 40 + 4 gap, scrolled to 0. Free vertical mode.
func makeView(scrollX: Double = 2000, pps: Double = 100, scrollY: Double = 0,
              snap: Bool = false, blockHeight: Double = 40, laneStep: Double = 44,
              viewportHeight: Double = 400, maxScrollY: Double = 2000) -> TimelineReveal.View {
    TimelineReveal.View(viewportWidth: 1000, scrollX: scrollX, pixelsPerSecond: pps,
                        minPixelsPerSecond: 0.5, maxPixelsPerSecond: 200_000,
                        maxScrollX: { p in max(0, 600 * p - 1000) },
                        viewportHeight: viewportHeight, scrollY: scrollY, maxScrollY: maxScrollY,
                        rulerHeight: 40, laneStep: laneStep, blockHeight: blockHeight,
                        snapActive: snap)
}

func box(_ t: ClosedRange<Double>?, _ lanes: ClosedRange<Int>, single: Bool = true) -> TimelineReveal.Box {
    TimelineReveal.Box(timeRange: t, laneRange: lanes, isSingleObject: single)
}

@main
enum TimelineRevealTest {
  static func main() {

    // MARK: - Already visible: nothing moves

    do {
        let f = TimelineReveal.frame(box: box(22...25, 1...1), view: makeView())
        check("an object entirely in view changes nothing at all", f.isEmpty, "\(f)")
    }
    do {
        // Flush against both edges of the window still counts as visible.
        let f = TimelineReveal.frame(box: box(20...30, 0...0, single: false), view: makeView())
        check("a box exactly filling the window is visible: no zoom, no scroll", f.isEmpty, "\(f)")
    }
    do {
        let f = TimelineReveal.frame(box: box(22...28, 0...2, single: false), view: makeView())
        check("several objects that fit and are in view change nothing", f.isEmpty, "\(f)")
    }

    // MARK: - One object out of view: centred, never zoomed

    do {
        let f = TimelineReveal.frame(box: box(100...104, 0...0), view: makeView())
        check("a single object to the right is centred (scroll only)", near(f.scrollX, 102 * 100 - 500), "\(f)")
        check("…and the zoom is untouched", f.pixelsPerSecond == nil)
    }
    do {
        let f = TimelineReveal.frame(box: box(2...4, 0...0), view: makeView())
        check("a single object to the left is centred", near(f.scrollX, 300 - 500 < 0 ? 0 : 300 - 500), "\(f)")
        check("…bounded at zero on the left", near(f.scrollX, 0), "\(f)")
    }
    do {
        // Partly visible: not "entirely visible", so it is brought in.
        let f = TimelineReveal.frame(box: box(28...34, 0...0), view: makeView())
        check("an object half out of view is brought in, centred", near(f.scrollX, 31 * 100 - 500), "\(f)")
    }
    do {
        let f = TimelineReveal.frame(box: box(599...600, 0...0), view: makeView())
        check("centring is bounded by the canvas's right end", near(f.scrollX, 600 * 100 - 1000), "\(f)")
    }

    // MARK: - A single object wider than the window: never zoomed onto

    do {
        let f = TimelineReveal.frame(box: box(100...130, 0...0), view: makeView())
        check("a single 30 s object (3000 pt) is not zoomed onto", f.pixelsPerSecond == nil, "\(f)")
        check("its start comes in just inside the left edge", near(f.scrollX, 100 * 100 - 60), "\(f)")
    }
    do {
        // It covers the whole window already (starts before, ends after): something is in view.
        let f = TimelineReveal.frame(box: box(10...50, 0...0), view: makeView())
        check("a single huge object already filling the view is left alone", f.isEmpty, "\(f)")
    }

    // MARK: - Several objects

    do {
        // 100 s at 100 pps = 10 000 pt, far wider than the window: zoom to 80 % and centre.
        let f = TimelineReveal.frame(box: box(100...200, 0...3, single: false), view: makeView())
        check("several objects too wide zoom out to 80 % of the width",
              near(f.pixelsPerSecond, 0.8 * 1000 / 100), "\(f)")
        // 8 pps: canvas = 600 × 8 = 4800, max scroll 3800. Centre 150 s → 1200 - 500 = 700.
        check("…then are centred at the new scale", near(f.scrollX, 150 * 8 - 500), "\(f)")
    }
    do {
        // Fits but out of view: scroll, no zoom.
        let f = TimelineReveal.frame(box: box(100...108, 0...0, single: false), view: makeView())
        check("several objects that fit but are out of view only scroll", f.pixelsPerSecond == nil, "\(f)")
        check("…centred", near(f.scrollX, 104 * 100 - 500), "\(f)")
    }
    do {
        // Zoom-out limit: 600 s at 0.5 pps min = 300 pt; ask for 600 s at 100 pps → wanted 1.33 pps.
        // Force a floor above the wanted one.
        var v = makeView()
        v.minPixelsPerSecond = 5
        let f = TimelineReveal.frame(box: box(0...600, 0...0, single: false), view: v)
        check("the zoom-out is bounded by the timeline's own minimum", near(f.pixelsPerSecond, 5), "\(f)")
        check("…and the box is still centred after the bound", f.scrollX != nil)
    }
    do {
        // A tiny box that "does not fit" cannot happen; but the upper bound must hold anyway.
        var v = makeView(pps: 100)
        v.maxPixelsPerSecond = 50   // absurd: below the current zoom
        let f = TimelineReveal.frame(box: box(0...100, 0...0, single: false), view: v)
        check("the result never exceeds the maximum zoom", (f.pixelsPerSecond ?? 0) <= 50, "\(f)")
    }
    do {
        // Already at the wanted scale: no zoom reported, scroll still centres.
        let f = TimelineReveal.frame(box: box(100...200, 0...0, single: false), view: makeView(scrollX: 0, pps: 8))
        check("a zoom already at the target is reported as unchanged", f.pixelsPerSecond == nil, "\(f)")
    }

    // MARK: - An infinite bus alone has no time

    do {
        let f = TimelineReveal.frame(box: box(nil, 0...0), view: makeView())
        check("no time range: the horizontal axis is untouched", f.pixelsPerSecond == nil && f.scrollX == nil, "\(f)")
    }

    // MARK: - Vertical, free mode

    do {
        // Lane 1: top = 40 + 44 = 84, bottom = 124 — inside [40, 400].
        let f = TimelineReveal.frame(box: box(22...25, 1...1), view: makeView())
        check("a lane in view is not scrolled to", f.scrollY == nil && f.frameLane == nil, "\(f)")
    }
    do {
        // Lane 30: top = 40 + 1320 = 1360, bottom 1400. Available = 360. Centre = 1380 - 40 - 180.
        let f = TimelineReveal.frame(box: box(22...25, 30...30), view: makeView())
        check("a lane far below is centred under the header", near(f.scrollY, 1380 - 40 - 180), "\(f)")
        check("…without any vertical zoom (the block height is not a field of the answer)", f.frameLane == nil)
    }
    do {
        // Rows 30…33 = 4 rows: top 1360, bottom = 40 + 33×44 + 40 = 1532 → 172 tall ≤ 360: centred.
        let f = TimelineReveal.frame(box: box(22...25, 30...33, single: false), view: makeView())
        check("rows that fit under the header are centred as a whole", near(f.scrollY, (1360.0 + 1532) / 2 - 40 - 180), "\(f)")
    }
    do {
        // Rows 10…30: 21 rows = 924 pt, taller than the 360 available: first row goes to the top.
        let f = TimelineReveal.frame(box: box(22...25, 10...30, single: false), view: makeView())
        check("rows taller than the window put the FIRST row just under the header",
              near(f.scrollY, (40 + 10 * 44) - 40), "\(f)")
    }
    do {
        // Above the window: scrolled down to 1000, lane 2 is above.
        let f = TimelineReveal.frame(box: box(22...25, 2...2), view: makeView(scrollY: 1000))
        // top 128 bottom 168, centre 148 - 40 - 180 = -72 → clamped to 0.
        check("scrolling back up is bounded at zero", near(f.scrollY, 0), "\(f)")
    }
    do {
        // Bounded at the bottom of the canvas.
        let f = TimelineReveal.frame(box: box(22...25, 30...30), view: makeView(maxScrollY: 1000))
        check("the vertical scroll is bounded by the canvas's height", near(f.scrollY, 1000), "\(f)")
    }
    do {
        // A row hidden UNDER the sticky header is not visible (its top is above scrollY + ruler).
        // scrollY = 100 → visible content from 140. Lane 1 spans 84…124: hidden under the header.
        let f = TimelineReveal.frame(box: box(22...25, 1...1), view: makeView(scrollY: 100))
        check("a row lying under the sticky header counts as out of view", f.scrollY != nil, "\(f)")
    }

    // MARK: - Vertical, snap mode

    do {
        // Snap on, block 300, laneStep 304, ruler 40, window 400: lane 0 spans 40…340, visible.
        let v = makeView(snap: true, blockHeight: 300, laneStep: 304)
        let f = TimelineReveal.frame(box: box(22...25, 0...0), view: v)
        check("snap: the lane already framed is not moved", f.isEmpty, "\(f)")
    }
    do {
        let v = makeView(snap: true, blockHeight: 300, laneStep: 304)
        let f = TimelineReveal.frame(box: box(22...25, 5...5), view: v)
        check("snap: another lane asks for the frame, and gives no scroll of its own",
              f.frameLane == 5 && f.scrollY == nil, "\(f)")
    }
    do {
        let v = makeView(snap: true, blockHeight: 300, laneStep: 304)
        let f = TimelineReveal.frame(box: box(22...25, 4...9, single: false), view: v)
        check("snap: a box taller than one lane frames its FIRST lane", f.frameLane == 4, "\(f)")
    }

    // MARK: - Both axes at once

    do {
        let f = TimelineReveal.frame(box: box(100...104, 30...30), view: makeView())
        check("horizontal and vertical are answered independently",
              near(f.scrollX, 102 * 100 - 500) && near(f.scrollY, 1380 - 40 - 180), "\(f)")
    }
    do {
        // In view horizontally, out of view vertically: only the vertical moves.
        let f = TimelineReveal.frame(box: box(22...25, 30...30), view: makeView())
        check("an object visible in time but not in rows only scrolls vertically",
              f.scrollX == nil && f.pixelsPerSecond == nil && f.scrollY != nil, "\(f)")
    }

    // MARK: - Degenerate views

    do {
        var v = makeView()
        v.viewportWidth = 0
        let f = TimelineReveal.frame(box: box(100...104, 0...0), view: v)
        check("an unmeasured window (width 0) answers nothing horizontal", f.scrollX == nil && f.pixelsPerSecond == nil, "\(f)")
    }
    do {
        // A zero-length object is a point: it fits.
        let f = TimelineReveal.frame(box: box(100...100, 0...0), view: makeView())
        check("a zero-duration object is centred like any other", near(f.scrollX, 100 * 100 - 500), "\(f)")
    }

    print("\n\(total - fails.count)/\(total) assertions passed")
    if !fails.isEmpty { print("FAILED: \(fails)"); exit(1) }
  }
}

// The spatial index behind the timeline's hover hit-test (`Shared/LaneEntryIndex.swift`), asserted
// with no screen: on random layouts, every answer must be STRICTLY the one the brute force gives —
// `first(where:)` over the flat list, the predicate the hover sites write by hand.
//
//     swiftc -parse-as-library \
//         ../objekat/Shared/LaneEntryIndex.swift test_lane_entry_index.swift \
//         -o /tmp/laneidx && /tmp/laneidx
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

/// A deterministic generator, so a failure replays.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

typealias Box = LaneEntryIndex.Box

// MARK: - The oracles: the predicates, as written at the call sites

func bruteBlock(_ boxes: [Box], x: Double, y: Double, pps: Double,
                ruler: Double, step: Double, bh: Double) -> Int? {
    boxes.firstIndex(where: { e in
        let bx = e.start * pps
        let bw = max(e.duration * pps, 2)
        let by = ruler + Double(e.displayLane) * step
        return x >= bx && x <= bx + bw && y >= by && y <= by + bh
            && LaneClip.unmasked(x: x, clipLo: e.clipLo, clipHi: e.clipHi, pixelsPerSecond: pps)
    })
}

func bruteCovers(_ boxes: [Box], lane: Int, t: Double, margin: Double) -> Bool {
    boxes.contains { e in
        e.displayLane == lane
            && t >= e.start + margin
            && t <= e.start + e.duration - margin
    }
}

// MARK: - Layout generators

enum Shape: CaseIterable {
    case sparse          // a few clips on a long timeline
    case dense           // lots of overlapping clips on few lanes
    case crossfades      // chains of clips overlapping their neighbour by a short zone
    case nested          // a group's children one lane under it, depth 1…3 (seen through the group's window)
    case clipped         // random windows, some missing the block altogether (the out-of-range veil)
    case infinite        // infinite buses: a huge stored window on a lane
    case degenerate      // zero-length, negative-length, identical, ±inf, NaN
}

/// Builds the flat list the way `buildLaneEntries` does: each entry gets a display lane, the result
/// is sorted by display lane (stable, so the model's order survives inside a lane).
func makeBoxes(_ shape: Shape, _ rng: inout SplitMix) -> [Box] {
    var out: [Box] = []
    func r(_ lo: Double, _ hi: Double) -> Double { Double.random(in: lo...hi, using: &rng) }
    func ri(_ lo: Int, _ hi: Int) -> Int { Int.random(in: lo...hi, using: &rng) }

    switch shape {
    case .sparse:
        for _ in 0..<ri(1, 40) { out.append(Box(displayLane: ri(0, 12), start: r(0, 600), duration: r(0.05, 30))) }
    case .dense:
        for _ in 0..<ri(100, 600) { out.append(Box(displayLane: ri(0, 5), start: r(0, 120), duration: r(0.1, 60))) }
    case .crossfades:
        for lane in 0..<ri(1, 6) {
            var t = r(0, 5)
            for _ in 0..<ri(5, 80) {
                let d = r(0.5, 12)
                out.append(Box(displayLane: lane, start: t, duration: d))
                t += d - r(0.05, 0.4)         // the next one starts inside this one: a crossfade zone
            }
        }
    case .nested:
        var lane = 0
        // Children are seen through the window of their group(s), exactly as `buildLaneEntries` does.
        func group(depth: Int, at lane: Int, start: Double, dur: Double, clip: LaneClip.Window) {
            out.append(Box(displayLane: lane, start: start, duration: dur, clipLo: clip.lo, clipHi: clip.hi))
            guard depth < 3 else { return }
            let inner = LaneClip.narrowed(clip, groupStart: start, groupDuration: dur, infinite: false)
            var t = start
            for _ in 0..<ri(1, 5) {
                // Children may stick out of the window (that is the point of the veil).
                let d = r(0.2, max(0.3, dur))
                if ri(0, 2) == 0 { group(depth: depth + 1, at: lane + 1, start: t, dur: d, clip: inner) }
                else { out.append(Box(displayLane: lane + 1, start: t, duration: d, clipLo: inner.lo, clipHi: inner.hi)) }
                t += d * r(0.3, 1)
            }
        }
        for _ in 0..<ri(1, 6) {
            group(depth: 0, at: lane, start: r(0, 60), dur: r(4, 50), clip: LaneClip.open)
            lane += ri(1, 5)
        }
    case .clipped:
        for _ in 0..<ri(20, 200) {
            let st = r(0, 100), d = r(0.1, 40)
            let lo = ri(0, 3) == 0 ? -Double.infinity : r(-10, 110)
            let hi = ri(0, 3) == 0 ? Double.infinity : lo.isFinite ? lo + r(0, 60) : r(-10, 110)
            out.append(Box(displayLane: ri(0, 4), start: st, duration: d, clipLo: lo, clipHi: hi))
        }
    case .infinite:
        for _ in 0..<ri(3, 25) { out.append(Box(displayLane: ri(0, 6), start: r(0, 100), duration: r(0.1, 40))) }
        for _ in 0..<ri(1, 4) {
            // An infinite bus keeps a stored window; some editors store a 24 h one.
            out.append(Box(displayLane: ri(0, 6), start: 0, duration: [86400, 1e9, 3600].randomElement(using: &rng)!))
        }
    case .degenerate:
        let specials: [Double] = [0, -3, 1e-9, .infinity, -.infinity, .nan, 1e300, -1e300, 1e15]
        for _ in 0..<ri(10, 60) {
            let s = ri(0, 3) == 0 ? specials.randomElement(using: &rng)! : r(-5, 40)
            let d = ri(0, 3) == 0 ? specials.randomElement(using: &rng)! : r(0, 10)
            out.append(Box(displayLane: ri(-2, 6), start: s, duration: d))
        }
        // exact duplicates: same window, same lane — the FIRST in the list must win
        if let b = out.first { out.append(b); out.append(b) }
    }
    // The model's order is the base order; the flat list is then sorted by display lane. Swift's sort
    // is stable in practice, which is what `buildLaneEntries` relies on.
    return out.sorted { $0.displayLane < $1.displayLane }
}

// MARK: - The run

@main
enum LaneEntryIndexTest {
  static func main() {
    var rng = SplitMix(state: 0xC0FFEE)
    var blockQueries = 0, hitsFound = 0, coverQueries = 0, coversTrue = 0
    var firstBadBlock = ""
    var firstBadCover = ""
    var badBlock = 0, badCover = 0, badID = 0

    for shape in Shape.allCases {
        for layout in 0..<60 {
            let boxes = makeBoxes(shape, &rng)
            let ids = boxes.map { _ in UUID() }
            let index = LaneEntryIndex(boxes: boxes, ids: ids)

            // Metrics like the timeline's (laneStep = blockHeight + laneGap), over zooms from a
            // whole-project view to a few ms per screen.
            let ppsChoices: [Double] = [0.5, 2, 10, 40, 100, 500, 3000, 20000]
            let blockHeight = [24.0, 36.0, 60.0].randomElement(using: &rng)!
            let step = blockHeight + [0.0, 4.0, 8.0].randomElement(using: &rng)!
            let ruler = [0.0, 28.0, 40.0].randomElement(using: &rng)!
            let maxLane = (boxes.map(\.displayLane).max() ?? 0) + 2

            // Probes: random points, plus points ON the edges (the inclusive bounds are where an
            // index would slip), plus points one ulp either side of an edge.
            for _ in 0..<150 {
                let pps = ppsChoices.randomElement(using: &rng)!
                var x = Double.random(in: -50...(700 * pps), using: &rng)
                var y = Double.random(in: 0...(ruler + Double(maxLane) * step), using: &rng)
                if let b = boxes.randomElement(using: &rng), Int.random(in: 0..<2, using: &rng) == 0 {
                    // an exact edge of a real box
                    let edgeX = [b.start * pps, b.start * pps + max(b.duration * pps, 2)].randomElement(using: &rng)!
                    if edgeX.isFinite {
                        x = [edgeX, edgeX.nextUp, edgeX.nextDown].randomElement(using: &rng)!
                    }
                    let edgeY = ruler + Double(b.displayLane) * step
                    y = [edgeY, edgeY + blockHeight, edgeY.nextUp, edgeY.nextDown,
                         (edgeY + blockHeight).nextUp, (edgeY + blockHeight).nextDown,
                         edgeY + blockHeight / 2].randomElement(using: &rng)!
                }
                let want = bruteBlock(boxes, x: x, y: y, pps: pps, ruler: ruler, step: step, bh: blockHeight)
                let got = index.firstBlock(atX: x, y: y, pixelsPerSecond: pps,
                                           rulerHeight: ruler, laneStep: step, blockHeight: blockHeight)
                blockQueries += 1
                if want != nil { hitsFound += 1 }
                if want != got {
                    badBlock += 1
                    if firstBadBlock.isEmpty {
                        firstBadBlock = "\(shape) #\(layout) x=\(x) y=\(y) pps=\(pps) want=\(String(describing: want)) got=\(String(describing: got))"
                    }
                }
            }

            // blockCovers: the caret margin is half the caret's width in seconds.
            for _ in 0..<100 {
                let pps = ppsChoices.randomElement(using: &rng)!
                let margin = 1.0 / pps
                let lane = Int.random(in: -1...maxLane, using: &rng)
                var t = Double.random(in: -5...700, using: &rng)
                if let b = boxes.randomElement(using: &rng), Int.random(in: 0..<2, using: &rng) == 0 {
                    let edge = [b.start + margin, b.start + b.duration - margin].randomElement(using: &rng)!
                    if edge.isFinite { t = [edge, edge.nextUp, edge.nextDown].randomElement(using: &rng)! }
                }
                let wantC = bruteCovers(boxes, lane: lane, t: t, margin: margin)
                let gotC = index.laneCovers(displayLane: lane, at: t, margin: margin)
                coverQueries += 1
                if wantC { coversTrue += 1 }
                if wantC != gotC {
                    badCover += 1
                    if firstBadCover.isEmpty {
                        firstBadCover = "\(shape) #\(layout) lane=\(lane) t=\(t) margin=\(margin) want=\(wantC) got=\(gotC)"
                    }
                }
            }

            // id → FIRST position (ids are unique here, so also: the right one)
            for (p, id) in ids.enumerated() where index.firstPosition(forID: id) != p { badID += 1 }
        }
    }

    check("block hit-test equals first(where:) on every random probe (\(blockQueries) probes, \(hitsFound) hits)",
          badBlock == 0, firstBadBlock)
    check("the probes really hit something (not a vacuous test)", hitsFound > blockQueries / 10,
          "\(hitsFound)/\(blockQueries)")
    check("blockCovers equals contains(where:) on every random probe (\(coverQueries) probes, \(coversTrue) covered)",
          badCover == 0, firstBadCover)
    check("blockCovers probes cover both answers", coversTrue > coverQueries / 20 && coversTrue < coverQueries,
          "\(coversTrue)/\(coverQueries)")
    check("firstPosition(forID:) returns each entry's own position", badID == 0, "\(badID) wrong")

    // MARK: - Hand-made cases: the semantics worth naming

    func idx(_ boxes: [Box]) -> LaneEntryIndex { LaneEntryIndex(boxes: boxes, ids: boxes.map { _ in UUID() }) }
    let ruler = 28.0, bh = 36.0, step = 40.0, pps = 10.0
    func probe(_ i: LaneEntryIndex, _ x: Double, _ y: Double) -> Int? {
        i.firstBlock(atX: x, y: y, pixelsPerSecond: pps, rulerHeight: ruler, laneStep: step, blockHeight: bh)
    }

    // Overlap: the FIRST of the list wins, whichever starts earlier or ends later.
    let overlap = idx([Box(displayLane: 0, start: 5, duration: 10),     // 0: 5…15 s
                       Box(displayLane: 0, start: 0, duration: 20)])    // 1: 0…20 s (contains 0)
    check("overlap: the first in the list wins (not the earliest start)", probe(overlap, 80, 40) == 0)
    check("overlap: where only the second reaches, the second answers", probe(overlap, 30, 40) == 1)

    // A crossfade: two clips sharing a zone — the first of the list owns it.
    let xfade = idx([Box(displayLane: 0, start: 0, duration: 10), Box(displayLane: 0, start: 8, duration: 10)])
    check("crossfade zone belongs to the first clip", probe(xfade, 90, 40) == 0)
    check("past the crossfade zone the second answers", probe(xfade, 120, 40) == 1)

    // A nested group: the child on the row under the group, the group on its own row.
    let nested = idx([Box(displayLane: 0, start: 0, duration: 30), Box(displayLane: 1, start: 2, duration: 5)])
    check("nested: the group's row answers the group", probe(nested, 100, 40) == 0)
    check("nested: the next row answers the child", probe(nested, 40, 80) == 1)
    check("nested: beside the child on its row, nothing", probe(nested, 200, 80) == nil)

    // The out-of-range veil (case c02): G2 shows 1…5 s, its child B1 lasts 1…7 s. The part of B1 past
    // 5 s answers nothing (the model's `first(where:)` plus the window), what is inside still does.
    let w2 = LaneClip.narrowed(LaneClip.open, groupStart: 1, groupDuration: 4, infinite: false)
    check("window of a group = [start, start + duration]", w2.lo == 1 && w2.hi == 5)
    let w3 = LaneClip.narrowed(w2, groupStart: 2, groupDuration: 4, infinite: false)
    check("nested windows intersect (G3 2…6 inside G2 1…5 -> 2…5)", w3.lo == 2 && w3.hi == 5)
    check("an infinite bus adds no veil",
          LaneClip.narrowed(w2, groupStart: 0, groupDuration: 86400, infinite: true) == w2
          || (LaneClip.narrowed(w2, groupStart: 0, groupDuration: 86400, infinite: true).lo == 1
              && LaneClip.narrowed(w2, groupStart: 0, groupDuration: 86400, infinite: true).hi == 5))
    let veil = idx([Box(displayLane: 0, start: 1, duration: 4),                                   // G2
                    Box(displayLane: 1, start: 1, duration: 6, clipLo: w2.lo, clipHi: w2.hi)])    // B1
    check("masked: inside the window the child answers", probe(veil, 30, 28 + 40 + 10) == 1)
    check("masked: the window's end itself still answers (inclusive)", probe(veil, 50, 28 + 40 + 10) == 1)
    check("masked: past the window's end the child answers NOTHING", probe(veil, 60, 28 + 40 + 10) == nil)
    check("masked: even at the child's far end", probe(veil, 69, 28 + 40 + 10) == nil)
    check("masked: the group's own row is unaffected", probe(veil, 30, 28 + 10) == 0)
    // What lies underneath answers instead: an unmasked block on the same row, further down the list.
    let under = idx([Box(displayLane: 1, start: 1, duration: 6, clipLo: w2.lo, clipHi: w2.hi),
                     Box(displayLane: 1, start: 5.5, duration: 3)])
    check("masked: the entry underneath takes the hit", probe(under, 60, 28 + 40 + 10) == 1)
    check("closed window (lo == hi) masks all but its edge point",
          probe(idx([Box(displayLane: 0, start: 0, duration: 10, clipLo: 3, clipHi: 3)]), 50, 40) == nil)

    // An infinite bus: a 24 h stored window answers anywhere on its row.
    let bus = idx([Box(displayLane: 2, start: 0, duration: 86400)])
    check("infinite bus: answers far to the right on its row", probe(bus, 600_000, 28 + 2 * 40 + 10) == 2 - 2)
    check("infinite bus: nothing on another row", probe(bus, 600_000, 28 + 40 + 10) == nil)

    // A block narrower than 2 px is still 2 px wide.
    let tiny = idx([Box(displayLane: 0, start: 10, duration: 0)])
    check("a zero-length block still answers within its 2 px", probe(tiny, 100 + 1.5, 40) == 0)
    check("…and not beyond them", probe(tiny, 100 + 2.5, 40) == nil)

    // The inclusive bounds, and the gap between two rows.
    let edges = idx([Box(displayLane: 0, start: 1, duration: 2)])
    check("left edge is inclusive", probe(edges, 10, 28) == 0)
    check("right edge is inclusive", probe(edges, 30, 28 + 36) == 0)
    check("the gap between rows is nothing", probe(edges, 20, 28 + 36 + 1) == nil)
    check("above the first row is nothing", probe(edges, 20, 27) == nil)

    // Degenerate inputs fall back to the plain walk and still agree.
    let weird = idx([Box(displayLane: 0, start: 0, duration: 10)])
    check("a NaN point answers nil, like the brute force",
          weird.firstBlock(atX: .nan, y: 40, pixelsPerSecond: pps, rulerHeight: ruler, laneStep: step, blockHeight: bh) == nil)
    check("pps 0 falls back and agrees with the brute force",
          weird.firstBlock(atX: 0, y: 40, pixelsPerSecond: 0, rulerHeight: ruler, laneStep: step, blockHeight: bh)
            == bruteBlock([Box(displayLane: 0, start: 0, duration: 10)], x: 0, y: 40, pps: 0, ruler: ruler, step: step, bh: bh))
    check("an empty list answers nil", probe(idx([]), 10, 40) == nil)

    // Scale: the point of the index. 20 000 blocks, 2 000 probes, equality AND a speed margin.
    var big: [Box] = []
    for lane in 0..<50 { for k in 0..<400 {
        big.append(Box(displayLane: lane, start: Double(k) * 3 + Double.random(in: 0...1, using: &rng),
                       duration: Double.random(in: 0.5...6, using: &rng)))
    } }
    let bigIdx = idx(big)
    var mismatch = 0
    var tBrute = 0.0, tIndex = 0.0
    for _ in 0..<2000 {
        let x = Double.random(in: 0...12000, using: &rng) * 10
        let y = Double.random(in: 0...(28 + 50 * 40), using: &rng)
        var t0 = CFAbsoluteTimeGetCurrent()
        let want = bruteBlock(big, x: x, y: y, pps: pps, ruler: ruler, step: step, bh: bh)
        tBrute += CFAbsoluteTimeGetCurrent() - t0
        t0 = CFAbsoluteTimeGetCurrent()
        let got = bigIdx.firstBlock(atX: x, y: y, pixelsPerSecond: pps, rulerHeight: ruler, laneStep: step, blockHeight: bh)
        tIndex += CFAbsoluteTimeGetCurrent() - t0
        if want != got { mismatch += 1 }
    }
    check("20 000 blocks: 2 000 probes all equal the brute force", mismatch == 0, "\(mismatch) differ")
    print(String(format: "      brute %.1f ms, index %.1f ms for 2000 probes on 20 000 blocks (x%.0f)",
                 tBrute * 1000, tIndex * 1000, tBrute / max(tIndex, 1e-9)))
    check("the index is faster than the walk at that size", tIndex < tBrute)

    print("\n\(total - fails.count)/\(total) assertions passed")
    exit(fails.isEmpty ? 0 : 1)
  }
}

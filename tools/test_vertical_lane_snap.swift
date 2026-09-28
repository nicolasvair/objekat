// The vertical lane snap's arithmetic — asserted with no screen.
//
// `VerticalLaneSnap` depends on nothing at all, which is the whole reason it is a unit of its
// own: it is the half of the feature with no view, no model and no scroll behind it. What is
// pinned down here: the 90 % clamp, the 70 % threshold, the centred framing (and its one
// exception at lane 0), the round trip `nearestLane(scrollY(forLane: i)) == i`, the neighbour
// walk at the two ends, the on-grid tolerance, and the resize keeping the ratio.
//
//     swiftc -parse-as-library \
//         ../objekat/Timeline/VerticalLaneSnap.swift test_vertical_lane_snap.swift \
//         -o /tmp/vlanesnap && /tmp/vlanesnap
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

func near(_ a: Double, _ b: Double, _ tol: Double = 1e-6) -> Bool { abs(a - b) <= tol }

@main
enum VerticalLaneSnapTest {
  static func main() {

    // MARK: - maxBlockHeight

    check("90% of the available height", near(VerticalLaneSnap.maxBlockHeight(available: 1000, minBlockHeight: 16), 900))
    check("floors at minBlockHeight on a tiny window",
          VerticalLaneSnap.maxBlockHeight(available: 10, minBlockHeight: 16) == 16)
    check("never above available",
          VerticalLaneSnap.maxBlockHeight(available: 500, minBlockHeight: 16) < 500)

    // MARK: - isActive

    check("false at exactly 0.70", !VerticalLaneSnap.isActive(blockHeight: 700, available: 1000))
    check("true just above 0.70", VerticalLaneSnap.isActive(blockHeight: 700.1, available: 1000))
    check("false well under", !VerticalLaneSnap.isActive(blockHeight: 300, available: 1000))
    check("false on a zero available (no crash, no division)",
          !VerticalLaneSnap.isActive(blockHeight: 100, available: 0))

    // MARK: - scrollY(forLane:) — centred framing

    do {
        let bh = 800.0, ls = 804.0, avail = 1000.0, maxY = 5000.0
        check("lane 0 is always 0 (cannot be centred upward)",
              VerticalLaneSnap.scrollY(forLane: 0, blockHeight: bh, laneStep: ls, available: avail, maxScrollY: maxY) == 0)
        let y1 = VerticalLaneSnap.scrollY(forLane: 1, blockHeight: bh, laneStep: ls, available: avail, maxScrollY: maxY)
        let expected1 = 1 * ls + bh / 2 - avail / 2
        check("lane 1 centres: top + bh/2 - avail/2", near(y1, expected1), "\(y1) vs \(expected1)")
        let margin = (avail - bh) / 2
        check("the margin either side matches (avail-bh)/2", near(y1 - 1 * ls, -margin), "\(y1 - 1*ls) vs \(-margin)")
    }

    // Bottom lanes clamp to maxScrollY.
    do {
        let bh = 200.0, ls = 204.0, avail = 1000.0, maxY = 300.0
        let yBig = VerticalLaneSnap.scrollY(forLane: 50, blockHeight: bh, laneStep: ls, available: avail, maxScrollY: maxY)
        check("a far bottom lane clamps to maxScrollY", yBig == maxY, "\(yBig)")
        let yNeg = VerticalLaneSnap.scrollY(forLane: 1, blockHeight: bh, laneStep: ls, available: 2000, maxScrollY: maxY)
        check("a raw negative target clamps to 0", yNeg >= 0, "\(yNeg)")
    }

    // MARK: - nearestLane round-trips scrollY(forLane:)

    do {
        let bh = 750.0, ls = 754.0, avail = 1000.0
        let laneCount = 20
        let maxY = Double(laneCount) * ls
        for i in 0..<laneCount {
            let y = VerticalLaneSnap.scrollY(forLane: i, blockHeight: bh, laneStep: ls, available: avail, maxScrollY: maxY)
            let n = VerticalLaneSnap.nearestLane(scrollY: y, blockHeight: bh, laneStep: ls, available: avail,
                                                 maxScrollY: maxY, laneCount: laneCount)
            check("nearestLane(scrollY(forLane: \(i))) == \(i)", n == i, "got \(n)")
        }
    }

    // Ties resolve consistently (lower index).
    do {
        let bh = 700.0, ls = 704.0, avail = 1000.0, maxY = 0.0   // every target clamps to 0
        let n = VerticalLaneSnap.nearestLane(scrollY: 0, blockHeight: bh, laneStep: ls, available: avail,
                                             maxScrollY: maxY, laneCount: 5)
        check("a tie among clamped targets resolves to the lowest index", n == 0, "\(n)")
    }

    // MARK: - neighbour

    do {
        let bh = 750.0, ls = 754.0, avail = 1000.0
        let laneCount = 10
        let maxY = Double(laneCount) * ls
        check("neighbour(0, up) is nil", VerticalLaneSnap.neighbour(of: 0, direction: -1, blockHeight: bh,
              laneStep: ls, available: avail, maxScrollY: maxY, laneCount: laneCount) == nil)
        check("neighbour(0, down) is 1", VerticalLaneSnap.neighbour(of: 0, direction: 1, blockHeight: bh,
              laneStep: ls, available: avail, maxScrollY: maxY, laneCount: laneCount) == 1)
        check("neighbour(5, up) is 4", VerticalLaneSnap.neighbour(of: 5, direction: -1, blockHeight: bh,
              laneStep: ls, available: avail, maxScrollY: maxY, laneCount: laneCount) == 4)
        check("neighbour(direction: 0) is nil", VerticalLaneSnap.neighbour(of: 3, direction: 0, blockHeight: bh,
              laneStep: ls, available: avail, maxScrollY: maxY, laneCount: laneCount) == nil)
    }

    // At the bottom, several rows clamp to the same target: neighbour must skip them, not stall.
    do {
        let bh = 200.0, ls = 204.0, avail = 1000.0, maxY = 300.0
        let laneCount = 20
        // lanes near the end all clamp onto maxY; the neighbour walk downward from one of them
        // must return nil rather than a lane with an indistinguishable target.
        let n = VerticalLaneSnap.neighbour(of: laneCount - 2, direction: 1, blockHeight: bh, laneStep: ls,
                                           available: avail, maxScrollY: maxY, laneCount: laneCount)
        check("no distinct target left at the bottom → nil", n == nil, "\(String(describing: n))")
    }

    // MARK: - isOnGrid

    do {
        let bh = 750.0, ls = 754.0, avail = 1000.0, maxY = 5000.0
        let target = VerticalLaneSnap.scrollY(forLane: 3, blockHeight: bh, laneStep: ls, available: avail, maxScrollY: maxY)
        check("on the exact target", VerticalLaneSnap.isOnGrid(scrollY: target, blockHeight: bh, laneStep: ls,
              available: avail, maxScrollY: maxY, laneCount: 20))
        check("0.4pt off is still on grid (tolerance 0.5)", VerticalLaneSnap.isOnGrid(scrollY: target + 0.4,
              blockHeight: bh, laneStep: ls, available: avail, maxScrollY: maxY, laneCount: 20))
        check("0.6pt off is NOT on grid", !VerticalLaneSnap.isOnGrid(scrollY: target + 0.6,
              blockHeight: bh, laneStep: ls, available: avail, maxScrollY: maxY, laneCount: 20))
    }

    // MARK: - resizedBlockHeight preserves the ratio and re-clamps

    do {
        let bh = VerticalLaneSnap.resizedBlockHeight(blockHeight: 800, oldAvailable: 1000, newAvailable: 500,
                                                      minBlockHeight: 16)
        check("halving the window halves the block (ratio kept)", near(bh, 400), "\(bh)")
        // A ratio already at 100% growing with the window would exceed 90% and must re-clamp.
        let grown = VerticalLaneSnap.resizedBlockHeight(blockHeight: 800, oldAvailable: 800, newAvailable: 1000,
                                                         minBlockHeight: 16)
        check("a ratio above 90% re-clamps to the new 90% cap",
              near(grown, VerticalLaneSnap.maxBlockHeight(available: 1000, minBlockHeight: 16)), "\(grown)")
        let same = VerticalLaneSnap.resizedBlockHeight(blockHeight: 800, oldAvailable: 1000, newAvailable: 1000,
                                                        minBlockHeight: 16)
        check("an unchanged window keeps the height", near(same, 800), "\(same)")
        let zero = VerticalLaneSnap.resizedBlockHeight(blockHeight: 800, oldAvailable: 0, newAvailable: 1000,
                                                        minBlockHeight: 16)
        check("a zero old available leaves the height untouched (no division by zero)", zero == 800, "\(zero)")
    }

    // MARK: - Sweep: consecutive targets strictly increase until the clamp

    for avail in stride(from: 200.0, through: 1400.0, by: 200.0) {
        for ratio in stride(from: 0.71, through: 0.90, by: 0.05) {
            let bh = ratio * avail
            let ls = bh + 4
            let laneCount = 40
            let maxY = Double(laneCount) * ls
            var prev = VerticalLaneSnap.scrollY(forLane: 0, blockHeight: bh, laneStep: ls, available: avail, maxScrollY: maxY)
            var clamped = false
            for i in 1..<laneCount {
                let y = VerticalLaneSnap.scrollY(forLane: i, blockHeight: bh, laneStep: ls, available: avail, maxScrollY: maxY)
                if y >= maxY - 1e-9 { clamped = true }
                check("avail=\(avail) ratio=\(ratio) lane \(i) target ≥ previous",
                      y >= prev - 1e-9 || clamped, "\(y) < \(prev)")
                prev = y
            }
        }
    }

    print(fails.isEmpty ? "\nALL PASS (\(total))"
                        : "\n\(fails.count) FAILURE(S) of \(total): \(fails.joined(separator: ", "))")
    exit(fails.isEmpty ? 0 : 1)
  }
}

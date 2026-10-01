// "The cached crossfade zones are the old zones" — `CrossfadeZoneIndex` against the algorithm it
// replaces, on random layouts, with no screen. The index (`Shared/CrossfadeZoneIndex.swift`) has no
// view and no model behind it, so it compiles and runs alone, like `CrossfadeGrab` / `SendColumns`.
//
//     swiftc -parse-as-library \
//         ../objekat/Shared/CrossfadeZoneIndex.swift ../objekat/Timeline/LaneCulling.swift \
//         test_crossfade_zone_cache.swift -o /tmp/xfcache && /tmp/xfcache
//
// What is asserted: for every random layout (nesting, equal starts, near-misses of the fade length,
// out-of-order rows) the index returns, in the same ORDER, exactly what the old
// `visibleCrossfadeZones` returned — for every row together, for each row on its own, and for a
// window of rows × time (the culled reading, which must be the old list filtered, never anything
// else). And `LaneCulling.firstIndex` — the binary search `blockCovers` stands on — agrees with a
// linear scan.
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

// MARK: - The old algorithm, verbatim (EditViewModel+Crossfade.swift), over a stand-in object

let seamEpsilon: Double = 1e-4

struct Obj {
    let lane: Int
    let startTime: Double
    let duration: Double
    let fadeIn: Double
    let fadeOut: Double
}

struct Entry {
    let id: UUID
    let displayLane: Int
    let item: Obj
    let absStart: Double
    let parentID: UUID?
}

/// `isCrossfadePair`, copied word for word.
func isCrossfadePair(_ a: Obj, _ b: Obj) -> Bool {
    guard a.lane == b.lane else { return false }
    let (left, right) = a.startTime <= b.startTime ? (a, b) : (b, a)
    let leftEnd = left.startTime + left.duration
    let rightEnd = right.startTime + right.duration
    guard right.startTime > left.startTime, rightEnd > leftEnd else { return false }
    let overlap = leftEnd - right.startTime
    guard overlap > seamEpsilon else { return false }
    return abs(left.fadeOut - overlap) <= seamEpsilon
        && abs(right.fadeIn - overlap) <= seamEpsilon
}

/// `visibleCrossfadeZones(onDisplayLane:)`, copied word for word.
func legacyVisibleZones(_ laneEntries: [Entry], onDisplayLane wanted: Int? = nil) -> [CrossfadeZoneRecord] {
    var zones: [CrossfadeZoneRecord] = []
    let lanes = wanted.map { [$0] } ?? Set(laneEntries.map(\.displayLane)).sorted()
    for lane in lanes {
        let row = laneEntries.filter { $0.displayLane == lane }
                             .sorted { $0.absStart < $1.absStart }
        for (a, b) in zip(row, row.dropFirst()) where isCrossfadePair(a.item, b.item) {
            zones.append(CrossfadeZoneRecord(leftID: a.id, rightID: b.id,
                                             containerID: a.parentID, lane: lane,
                                             start: b.absStart, end: a.absStart + a.item.duration))
        }
    }
    return zones
}

func sameZone(_ x: CrossfadeZoneRecord, _ y: CrossfadeZoneRecord) -> Bool {
    x.leftID == y.leftID && x.rightID == y.rightID && x.containerID == y.containerID
        && x.lane == y.lane && x.start == y.start && x.end == y.end
}

func sameList(_ x: [CrossfadeZoneRecord], _ y: [CrossfadeZoneRecord]) -> Bool {
    x.count == y.count && zip(x, y).allSatisfy { sameZone($0, $1) }
}

// MARK: - Random layouts

struct Layout {
    var entries: [Entry]    // sorted by displayLane, like `laneEntries`
    var maxLane: Int
    var maxTime: Double
}

func randomLayout(_ rng: inout SystemRandomNumberGenerator) -> Layout {
    var entries: [Entry] = []
    let laneCount = Int.random(in: 1...12, using: &rng)
    let groups = (0..<Int.random(in: 0...3, using: &rng)).map { _ in UUID() }
    var maxTime = 10.0
    for dl in 0..<laneCount {
        // A few rows are left empty, a few are dense.
        let n = [0, 1, 2, 5, 12, 30].randomElement(using: &rng)!
        var cursor = Double.random(in: 0...5, using: &rng)
        let parent: UUID? = Bool.random(using: &rng) ? groups.randomElement(using: &rng) : nil
        let offset = parent == nil ? 0.0 : Double.random(in: -3...8, using: &rng)
        var prev: (start: Double, dur: Double)? = nil
        var row: [Entry] = []
        for _ in 0..<n {
            let dur = Double.random(in: 0.2...6, using: &rng)
            var start = cursor
            var fadeIn = 0.0, fadeOut = 0.0
            var mustFixPrevFadeOut: Double? = nil
            if let p = prev, Int.random(in: 0..<10, using: &rng) < 6 {
                // Overlap the previous object. Mostly a genuine crossfade (both fades == overlap),
                // sometimes a near miss, sometimes one inside the other (an overwrite).
                let overlap = Double.random(in: 0.01...min(1.5, p.dur * 0.9), using: &rng)
                start = p.start + p.dur - overlap
                switch Int.random(in: 0..<10, using: &rng) {
                case 0:  fadeIn = overlap + 0.01                 // near miss: not a pair
                case 1:  fadeIn = overlap + 5e-5; mustFixPrevFadeOut = overlap   // within epsilon
                default: fadeIn = overlap; mustFixPrevFadeOut = overlap
                }
            } else if Int.random(in: 0..<12, using: &rng) == 0, let p = prev {
                start = p.start                                   // equal starts (a tie)
            }
            if let m = mustFixPrevFadeOut, let last = row.last {
                let o = last.item
                row[row.count - 1] = Entry(id: last.id, displayLane: last.displayLane,
                                           item: Obj(lane: o.lane, startTime: o.startTime,
                                                     duration: o.duration, fadeIn: o.fadeIn, fadeOut: m),
                                           absStart: last.absStart, parentID: last.parentID)
            }
            fadeOut = Bool.random(using: &rng) ? 0 : Double.random(in: 0...0.5, using: &rng)
            row.append(Entry(id: UUID(), displayLane: dl,
                             item: Obj(lane: dl, startTime: start, duration: dur, fadeIn: fadeIn, fadeOut: fadeOut),
                             absStart: start + offset, parentID: parent))
            prev = (start, dur)
            cursor = start + dur + Double.random(in: 0...2, using: &rng)
            maxTime = max(maxTime, cursor + offset)
        }
        // The row's own order is NOT by start (the model's order is the user's), as in `laneEntries`.
        row.shuffle(using: &rng)
        entries += row
    }
    return Layout(entries: entries, maxLane: laneCount, maxTime: maxTime)
}

@main
enum CrossfadeZoneCacheTest {
  static func main() {
    var rng = SystemRandomNumberGenerator()

    // --- A fixed case first, so a failure of the random ones has a reference point.
    do {
        let l = UUID(), r = UUID()
        let a = Entry(id: l, displayLane: 2, item: Obj(lane: 2, startTime: 0, duration: 4, fadeIn: 0, fadeOut: 1),
                      absStart: 0, parentID: nil)
        let b = Entry(id: r, displayLane: 2, item: Obj(lane: 2, startTime: 3, duration: 4, fadeIn: 1, fadeOut: 0),
                      absStart: 3, parentID: nil)
        let es = [b, a]
        let cands = es.map { CrossfadeZoneIndex.Candidate(id: $0.id, displayLane: $0.displayLane,
                                                          absStart: $0.absStart, duration: $0.item.duration,
                                                          parentID: $0.parentID) }
        let idx = CrossfadeZoneIndex(candidates: cands) { isCrossfadePair(es[$0].item, es[$1].item) }
        check("one pair: one zone", idx.all.count == 1)
        check("zone is [3, 4] on row 2", idx.all.first.map { $0.start == 3 && $0.end == 4 && $0.lane == 2 } == true)
        check("zones(onDisplayLane: 2) has it, 1 and 3 do not",
              idx.zones(onDisplayLane: 2).count == 1 && idx.zones(onDisplayLane: 1).isEmpty
                && idx.zones(onDisplayLane: 3).isEmpty)
        check("window on the zone finds it", idx.zones(inLanes: 0..<5, from: 3.5, to: 3.6).count == 1)
        check("window before it does not", idx.zones(inLanes: 0..<5, from: 0, to: 2.9).isEmpty)
        check("window after it does not", idx.zones(inLanes: 0..<5, from: 4.1, to: 9).isEmpty)
        check("window on other rows does not", idx.zones(inLanes: 3..<9, from: 0, to: 9).isEmpty)
        check("empty index", CrossfadeZoneIndex().all.isEmpty && CrossfadeZoneIndex().zones(onDisplayLane: 0).isEmpty)
    }

    // --- Random layouts against the old algorithm.
    var layouts = 0, nonTrivial = 0
    var badAll = 0, badLane = 0, badWindow = 0, badBlock = 0
    var zonesSeen = 0
    for _ in 0..<1500 {
        let lay = randomLayout(&rng)
        layouts += 1
        let es = lay.entries
        let cands = es.map { CrossfadeZoneIndex.Candidate(id: $0.id, displayLane: $0.displayLane,
                                                          absStart: $0.absStart, duration: $0.item.duration,
                                                          parentID: $0.parentID) }
        let idx = CrossfadeZoneIndex(candidates: cands) { isCrossfadePair(es[$0].item, es[$1].item) }
        let old = legacyVisibleZones(es)
        zonesSeen += old.count
        if !old.isEmpty { nonTrivial += 1 }
        if !sameList(idx.all, old) { badAll += 1 }

        // Each row on its own (including rows with nothing and rows beyond the end).
        for lane in -1...(lay.maxLane + 1) {
            if !sameList(idx.zones(onDisplayLane: lane), legacyVisibleZones(es, onDisplayLane: lane)) { badLane += 1 }
        }

        // A window of rows × time == the old list, filtered.
        for _ in 0..<6 {
            let l0 = Int.random(in: -1...lay.maxLane, using: &rng)
            let l1 = l0 + Int.random(in: 0...(lay.maxLane + 2), using: &rng)
            let t0 = Double.random(in: -2...lay.maxTime, using: &rng)
            let t1 = t0 + Double.random(in: 0...(lay.maxTime), using: &rng)
            let expected = old.filter { $0.lane >= l0 && $0.lane < l1 && $0.end >= t0 && $0.start <= t1 }
            if !sameList(idx.zones(inLanes: l0..<l1, from: t0, to: t1), expected) { badWindow += 1 }
        }

        // `blockCovers` by binary search == the linear `contains`.
        let margin = 0.75 / Double.random(in: 5...2000, using: &rng)
        for _ in 0..<8 {
            let lane = Int.random(in: -1...(lay.maxLane + 1), using: &rng)
            let t = Double.random(in: -1...lay.maxTime, using: &rng)
            let linear = es.contains { e in
                e.displayLane == lane && t >= e.absStart + margin && t <= e.absStart + e.item.duration - margin
            }
            var bsearch = false
            var i = LaneCulling.firstIndex(atOrAfterLane: lane, count: es.count) { es[$0].displayLane }
            while i < es.count, es[i].displayLane == lane {
                let e = es[i]
                if t >= e.absStart + margin && t <= e.absStart + e.item.duration - margin { bsearch = true; break }
                i += 1
            }
            if linear != bsearch { badBlock += 1 }
        }
    }
    check("the layouts are not all empty (\(nonTrivial)/\(layouts) hold zones, \(zonesSeen) zones)", nonTrivial > layouts / 4)
    check("1500 layouts: all zones, same order", badAll == 0, "\(badAll) mismatches")
    check("1500 layouts: every row on its own", badLane == 0, "\(badLane) mismatches")
    check("9000 windows: culled == old, filtered", badWindow == 0, "\(badWindow) mismatches")
    check("12000 caret probes: binary search == linear contains", badBlock == 0, "\(badBlock) mismatches")

    print("\n\(total - fails.count)/\(total) assertions pass")
    exit(fails.isEmpty ? 0 : 1)
  }
}

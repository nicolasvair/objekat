import Foundation

// MARK: - The crossfade zones, indexed
//
// `visibleCrossfadeZones` used to rebuild every zone of the timeline on EVERY call: for each display
// row, a filter over all the entries and a sort of the row — O(lanes × N) — and it is called by the
// canvas on every pass and by the hover / hit-test / drag on every movement. The zones only change
// when `laneEntries` does, so they are built ONCE per rebuild of it and served from here.
//
// The index is pure — no model, no view — so that it can be compiled alone and compared, on random
// layouts, with the algorithm it replaces (`tools/test_crossfade_zone_cache.swift`). The one thing
// it does not own is what makes two objects a crossfade (`isCrossfadePair`, which reads the
// objects' own fades): the builder is handed it as a closure over the candidates' indices.

/// The common zone of two siblings on one lane: the crossfade itself. Derived, never stored.
/// (`EditViewModel.CrossfadeZone` is this type.)
struct CrossfadeZoneRecord {
    let leftID:  UUID
    let rightID: UUID
    /// `nil` = the two live at the top level.
    let containerID: UUID?
    let lane:  Int
    let start: Double
    let end:   Double
    var width: Double { end - start }
}

struct CrossfadeZoneIndex {

    /// What the index needs to know of one object laid on a display row: where it is, nothing more.
    struct Candidate {
        let id: UUID
        let displayLane: Int
        let absStart: Double
        let duration: Double
        let parentID: UUID?
    }

    /// Every zone, in the order the old reading produced them: display rows ascending, and inside a
    /// row by the right-hand object's start.
    private(set) var all: [CrossfadeZoneRecord] = []
    /// The rows that hold at least one zone, ascending, each with its slice of `all`.
    private var laneSpans: [(lane: Int, range: Range<Int>)] = []

    init() {}

    /// Buckets the candidates by display row — keeping their order, exactly what the old
    /// `laneEntries.filter { $0.displayLane == lane }` kept — sorts each row by `absStart` with the
    /// same comparator, and keeps every consecutive pair `isPair` accepts. One pass, O(N log N).
    init(candidates c: [Candidate], isPair: (Int, Int) -> Bool) {
        var byLane: [Int: [Int]] = [:]
        for i in c.indices { byLane[c[i].displayLane, default: []].append(i) }
        for lane in byLane.keys.sorted() {
            let row = byLane[lane]!.sorted { c[$0].absStart < c[$1].absStart }
            let begin = all.count
            for (a, b) in zip(row, row.dropFirst()) where isPair(a, b) {
                all.append(CrossfadeZoneRecord(leftID: c[a].id, rightID: c[b].id,
                                               containerID: c[a].parentID, lane: lane,
                                               start: c[b].absStart,
                                               end: c[a].absStart + c[a].duration))
            }
            if all.count > begin { laneSpans.append((lane, begin..<all.count)) }
        }
    }

    /// The index of the first span whose row is >= `lane` (`laneSpans.count` when none is).
    private func firstSpan(atOrAfter lane: Int) -> Int {
        var lo = 0, hi = laneSpans.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if laneSpans[mid].lane < lane { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// The zones of ONE display row.
    func zones(onDisplayLane lane: Int) -> [CrossfadeZoneRecord] {
        let i = firstSpan(atOrAfter: lane)
        guard i < laneSpans.count, laneSpans[i].lane == lane else { return [] }
        return Array(all[laneSpans[i].range])
    }

    /// The zones of the rows `lanes` that meet `[t0, t1]` (absolute seconds), in the same order as
    /// `all`. Cost: O(log rows + the zones of those rows) — what is SHOWN, not what is held.
    func zones(inLanes lanes: Range<Int>, from t0: Double, to t1: Double) -> [CrossfadeZoneRecord] {
        guard !lanes.isEmpty else { return [] }
        var out: [CrossfadeZoneRecord] = []
        var i = firstSpan(atOrAfter: lanes.lowerBound)
        while i < laneSpans.count, laneSpans[i].lane < lanes.upperBound {
            for k in laneSpans[i].range {
                let z = all[k]
                // Starts ascend inside a row: nothing after this one can meet the window either.
                if z.start > t1 { break }
                if z.end >= t0 { out.append(z) }
            }
            i += 1
        }
        return out
    }
}

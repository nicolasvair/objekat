// "The crossfade pairs of a drag are the old pairs" — `CrossfadePartnerFinder` against the walk it
// replaces (`seamNeighbourAndGap` + `crossfadeZone` + `crossfadePairs`, EditViewModel+Crossfade.swift),
// and the drag's displayed zones (TimelineView.displayedCrossfadeZones, E8) against the same composition
// fed by the old pairs, on random layouts and random gestures, with no screen. The finder has no view and
// no model behind it, so it compiles and runs alone, like `CrossfadeZoneIndex` / `CrossfadeGrab`.
//
//     swiftc -parse-as-library ../objekat/Shared/CrossfadePartnerFinder.swift \
//         test_crossfade_pairs.swift -o /tmp/xfpairs && /tmp/xfpairs
//
// What is asserted, for every random project (nested groups, several lanes, near-misses of the fade
// length, EQUAL starts and starts a hair apart so that several siblings fit the same object, rows that
// are not in start order, ids unknown to the model):
//   1. per object and per side, the partner the old walk names — the first sibling in the model's order
//      whose pair satisfies `isCrossfadePair` — is the one the finder names (and none where none forms a
//      zone), for every object of the tree;
//   2. `crossfadePairs(around:)` returns the SAME ARRAY, in the same order, for random sets of ids;
//   3. `reshapedCrossfadeFade`'s neighbour test (the partner, then "the gesture holds one of the two")
//      answers like the old one for every object, side and random drag set;
//   4. the zones a drag DISPLAYS (the model's zones minus the touched pairs, plus each pair re-projected
//      through `projectedCrossfade` under a random move / crop / resize) are the same list, in the same
//      order, with the old pairs and with the new ones.
//
// The old functions below are copied word for word from the app, over a stand-in object; the new side
// calls `CrossfadePartnerFinder.partnerMap` itself, as `EditViewModel.buildCrossfadePartners` does.
//
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation

var fails: [String] = []
var total = 0

func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    total += 1
    if !ok {
        fails.append(label)
        if fails.count <= 20 { print("FAIL  \(label)  \(detail())") }
    }
}

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

// MARK: - The model's stand-in and the old algorithm, verbatim

let seamEpsilon: Double = 1e-4
let crossfadeMinDuration: Double = 0.05

struct Obj {
    let id: UUID
    var lane: Int
    var startTime: Double
    var duration: Double
    var fadeIn: Double
    var fadeOut: Double
    var children: [Obj]?          // nil = a clip, non-nil = a group
}

struct Model {
    var items: [Obj]

    func find(id: UUID) -> Obj? {
        func search(in arr: [Obj]) -> Obj? {
            for item in arr {
                if item.id == id { return item }
                if let kids = item.children, let found = search(in: kids) { return found }
            }
            return nil
        }
        return search(in: items)
    }

    /// `parentGroup(for:)`, word for word.
    func parentGroup(for childID: UUID) -> Obj? {
        func search(in arr: [Obj]) -> Obj? {
            for item in arr {
                guard let children = item.children else { continue }
                if children.contains(where: { $0.id == childID }) { return item }
                if let found = search(in: children) { return found }
            }
            return nil
        }
        return search(in: items)
    }

    func crossfadeSiblings(of id: UUID) -> [Obj] {
        guard let parent = parentGroup(for: id), let children = parent.children else { return items }
        return children
    }

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

    func seamNeighbour(of id: UUID, onRight: Bool, within reach: Double = 0) -> UUID? {
        seamNeighbourAndGap(of: id, onRight: onRight, within: reach)?.id
    }

    func seamNeighbourAndGap(of id: UUID, onRight: Bool,
                             within reach: Double = 0) -> (id: UUID, gap: Double)? {
        guard let me = find(id: id) else { return nil }
        let myEnd = me.startTime + me.duration
        var best: (id: UUID, gap: Double)? = nil
        for other in crossfadeSiblings(of: id) where other.id != id && other.lane == me.lane {
            let otherEnd = other.startTime + other.duration
            let gap: Double
            if onRight {
                guard other.startTime > me.startTime, otherEnd > myEnd else { continue }
                if isCrossfadePair(me, other) { return (other.id, 0) }
                gap = other.startTime - myEnd
            } else {
                guard other.startTime < me.startTime, otherEnd < myEnd else { continue }
                if isCrossfadePair(other, me) { return (other.id, 0) }
                gap = me.startTime - otherEnd
            }
            guard gap >= -seamEpsilon, gap <= reach + seamEpsilon else { continue }
            if best == nil || gap < best!.gap { best = (other.id, max(0, gap)) }
        }
        return best
    }

    struct Zone: Equatable {
        let leftID: UUID, rightID: UUID
        let start: Double, end: Double
        let lane: Int
    }

    func crossfadeZone(leftID: UUID, rightID: UUID) -> Zone? {
        guard let a = find(id: leftID), let b = find(id: rightID), isCrossfadePair(a, b) else {
            return nil
        }
        let (left, right) = a.startTime <= b.startTime ? (a, b) : (b, a)
        return Zone(leftID: left.id, rightID: right.id, start: right.startTime,
                    end: left.startTime + left.duration, lane: left.lane)
    }

    struct Pair: Hashable { let left: UUID; let right: UUID }

    /// `crossfadePairs(around:)`, the OLD one, word for word.
    func oldPairs(around ids: Set<UUID>) -> [Pair] {
        var pairs: [Pair] = []
        var seen = Set<Pair>()
        func note(_ l: UUID, _ r: UUID) {
            let pair = Pair(left: l, right: r)
            if seen.insert(pair).inserted { pairs.append(pair) }
        }
        for id in ids {
            if let n = seamNeighbour(of: id, onRight: true),
               crossfadeZone(leftID: id, rightID: n) != nil { note(id, n) }
            if let n = seamNeighbour(of: id, onRight: false),
               crossfadeZone(leftID: n, rightID: id) != nil { note(n, id) }
        }
        return pairs
    }

    typealias Placement = (start: Double, duration: Double, lane: Int, container: UUID?)

    /// `projectedCrossfade`, word for word.
    func projectedCrossfade(leftID: UUID, rightID: UUID, placement: (UUID) -> Placement?)
        -> (leftID: UUID, rightID: UUID, start: Double, end: Double, lane: Int)? {
        guard let a = find(id: leftID), let b = find(id: rightID),
              let pa = placement(leftID), let pb = placement(rightID) else { return nil }
        guard pa.lane == pb.lane, pa.container == pb.container else { return nil }
        let aEnd = pa.start + pa.duration
        let bEnd = pb.start + pb.duration
        let overlap = aEnd - pb.start
        guard overlap > seamEpsilon else { return nil }
        let minDur = crossfadeMinDuration
        guard pb.start > pa.start, bEnd > aEnd,
              overlap <= pa.duration - max(a.fadeIn, minDur),
              overlap <= pb.duration - max(b.fadeOut, minDur)
        else { return nil }
        return (a.id, b.id, pb.start, aEnd, pa.lane)
    }
}

// MARK: - The new side, as EditViewModel builds it

struct NewSide {
    let partners: [UUID: (left: UUID?, right: UUID?)]

    init(_ m: Model) {
        partners = CrossfadePartnerFinder.partnerMap(
            roots: m.items,
            id: { $0.id },
            children: { $0.children ?? [] },
            box: { CrossfadePartnerFinder.Box(lane: $0.lane, start: $0.startTime, duration: $0.duration) },
            isPair: { m.isCrossfadePair($0, $1) })
    }

    /// `crossfadePairs(around:)`, the NEW one.
    func pairs(around ids: Set<UUID>) -> [Model.Pair] {
        var pairs: [Model.Pair] = []
        var seen = Set<Model.Pair>()
        func note(_ l: UUID, _ r: UUID) {
            let pair = Model.Pair(left: l, right: r)
            if seen.insert(pair).inserted { pairs.append(pair) }
        }
        for id in ids {
            guard let p = partners[id] else { continue }
            if let n = p.right { note(id, n) }
            if let n = p.left { note(n, id) }
        }
        return pairs
    }
}

// MARK: - Random projects

func randomProject(_ rng: inout SplitMix) -> Model {
    func makeRow(lane: Int, count: Int, depth: Int) -> [Obj] {
        var row: [Obj] = []
        var cursor = Double.random(in: 0...3, using: &rng)
        var prev: Obj? = nil
        for _ in 0..<count {
            let dur = Double.random(in: 0.2...5, using: &rng)
            var start = cursor
            var fadeIn = 0.0, fadeOut = 0.0
            var fixPrev: Double? = nil
            let roll = Int.random(in: 0..<20, using: &rng)
            if let p = prev, roll < 9 {
                // Overlap the previous: mostly a genuine crossfade, sometimes a near miss, sometimes
                // inside (an overwrite).
                let overlap = Double.random(in: 0.01...min(1.5, p.duration * 0.9), using: &rng)
                start = p.startTime + p.duration - overlap
                switch Int.random(in: 0..<10, using: &rng) {
                case 0: fadeIn = overlap + 0.01
                case 1: fadeIn = overlap + 5e-5; fixPrev = overlap
                default: fadeIn = overlap; fixPrev = overlap
                }
            } else if let p = prev, roll == 9 {
                start = p.startTime                       // an exact tie
            } else if let p = prev, roll == 10 {
                start = p.startTime + Double.random(in: 1e-6...9e-5, using: &rng)   // a hair apart
            }
            if let m = fixPrev, !row.isEmpty { row[row.count - 1].fadeOut = m }
            fadeOut = Bool.random(using: &rng) ? 0 : Double.random(in: 0...0.5, using: &rng)
            var o = Obj(id: UUID(), lane: lane, startTime: start, duration: dur, fadeIn: fadeIn,
                        fadeOut: fadeOut, children: nil)
            if depth < 2, Int.random(in: 0..<14, using: &rng) == 0 {
                o.children = randomSiblings(depth: depth + 1)
            }
            row.append(o)
            // A TWIN: a second object that fits the same crossfade within the epsilon (a hair
            // apart in start), laid before or after the first in the model's order — the only way
            // two siblings can both be the "first" partner of one object.
            if o.fadeIn > 0.05, Int.random(in: 0..<3, using: &rng) == 0 {
                let twin = Obj(id: UUID(), lane: o.lane,
                               startTime: o.startTime + Double.random(in: -4e-5...4e-5, using: &rng),
                               duration: o.duration, fadeIn: o.fadeIn, fadeOut: o.fadeOut, children: nil)
                if Bool.random(using: &rng) { row.insert(twin, at: row.count - 1) } else { row.append(twin) }
            }
            prev = o
            cursor = start + dur + Double.random(in: -0.3...2, using: &rng)
        }
        return row
    }
    func randomSiblings(depth: Int) -> [Obj] {
        var all: [Obj] = []
        for lane in 0..<Int.random(in: 1...5, using: &rng) {
            all += makeRow(lane: lane, count: [0, 1, 3, 8, 20].randomElement(using: &rng)!, depth: depth)
        }
        // The model's order is the user's, not the start order.
        all.shuffle(using: &rng)
        return all
    }
    return Model(items: randomSiblings(depth: 0))
}

func allObjects(_ items: [Obj]) -> [Obj] {
    items.flatMap { [$0] + allObjects($0.children ?? []) }
}

// MARK: - The run

@main
enum CrossfadePairsTest {
    static func main() {
        let seed = UInt64(CommandLine.arguments.dropFirst().first.flatMap { UInt64($0) } ?? 20261002)
        var rng = SplitMix(state: seed)
        var projects = 0, withZones = 0, withTies = 0

        for _ in 0..<400 {
            let m = randomProject(&rng)
            projects += 1
            let all = allObjects(m.items)
            guard !all.isEmpty else { continue }
            let new = NewSide(m)

            // 1. the partner of every object, both sides.
            var anyPair = false
            for o in all {
                for onRight in [true, false] {
                    var oldPartner: UUID? = nil
                    if let n = m.seamNeighbour(of: o.id, onRight: onRight),
                       m.crossfadeZone(leftID: onRight ? o.id : n, rightID: onRight ? n : o.id) != nil {
                        oldPartner = n
                    }
                    let np = new.partners[o.id].flatMap { onRight ? $0.right : $0.left }
                    if oldPartner != nil { anyPair = true }
                    check("partner \(onRight ? "right" : "left")", oldPartner == np,
                          "seed \(seed) old \(String(describing: oldPartner)) new \(String(describing: np))")
                }
            }
            if anyPair { withZones += 1 }

            // 2. the pairs, as an ordered array, for random id sets (unknown ids included).
            for _ in 0..<6 {
                var ids = Set<UUID>()
                let k = Int.random(in: 0...min(all.count, 40), using: &rng)
                for o in all.shuffled(using: &rng).prefix(k) { ids.insert(o.id) }
                if Bool.random(using: &rng) { ids.insert(UUID()) }
                if Int.random(in: 0..<4, using: &rng) == 0 { ids = Set(all.map(\.id)) }
                let a = m.oldPairs(around: ids), b = new.pairs(around: ids)
                check("pairs", a == b, "seed \(seed) old \(a.count) new \(b.count)")

                // 3. reshapedCrossfadeFade's gate.
                for o in all {
                    for onRight in [true, false] {
                        var old: UUID? = nil
                        if let n = m.seamNeighbour(of: o.id, onRight: onRight),
                           ids.contains(o.id) || ids.contains(n),
                           m.crossfadeZone(leftID: onRight ? o.id : n, rightID: onRight ? n : o.id) != nil {
                            old = n
                        }
                        var nu: UUID? = nil
                        if let p = new.partners[o.id], let n = onRight ? p.right : p.left,
                           ids.contains(o.id) || ids.contains(n) { nu = n }
                        check("reshaped gate", old == nu, "seed \(seed)")
                    }
                }

                // 4. the displayed zones under a random gesture.
                let dt = Double.random(in: -4...4, using: &rng)
                let dl = Int.random(in: -1...1, using: &rng)
                let dStart = Double.random(in: -0.8...0.8, using: &rng)
                let dDur = Double.random(in: -0.8...0.8, using: &rng)
                let mode = Int.random(in: 0..<3, using: &rng)
                // The placement as `dragPlacement` gives it: the object's own spot (container's time
                // here, standing for absolute) plus the gesture's travel when it is under the hand.
                let parentOf: [UUID: UUID?] = Dictionary(uniqueKeysWithValues: all.map {
                    ($0.id, m.parentGroup(for: $0.id)?.id) })
                let placement: (UUID) -> Model.Placement? = { id in
                    guard let o = m.find(id: id) else { return nil }
                    var p: Model.Placement = (o.startTime, o.duration, o.lane, parentOf[id] ?? nil)
                    guard ids.contains(id) else { return p }
                    switch mode {
                    case 0: p.start += dt; p.lane = max(0, p.lane + dl)
                    case 1: p.start += dStart; p.duration -= dStart
                    default: p.duration += dDur
                    }
                    return p
                }
                // A stand-in for the index's windowed model zones: every zone of the project.
                var modelZones: [Model.Zone] = []
                for o in all { if let n = new.partners[o.id]?.right,
                                  let z = m.crossfadeZone(leftID: o.id, rightID: n) { modelZones.append(z) } }
                func displayed(_ pairs: [Model.Pair]) -> [(UUID, UUID, Double, Double, Int)] {
                    guard !pairs.isEmpty else {
                        return modelZones.map { ($0.leftID, $0.rightID, $0.start, $0.end, $0.lane) }
                    }
                    let touched = Set(pairs)
                    var shown = modelZones.filter { !touched.contains(Model.Pair(left: $0.leftID, right: $0.rightID)) }
                        .map { ($0.leftID, $0.rightID, $0.start, $0.end, $0.lane) }
                    for p in pairs {
                        if let z = m.projectedCrossfade(leftID: p.left, rightID: p.right, placement: placement) {
                            shown.append((z.leftID, z.rightID, z.start, z.end, z.lane))
                        }
                    }
                    return shown
                }
                let da = displayed(a), db = displayed(b)
                check("displayed zones", da.count == db.count
                      && zip(da, db).allSatisfy { $0 == $1 }, "seed \(seed)")
            }
        }
        // A layout with a tie that matters: both b1 and b2 start together and fit a's fade.
        do {
            let a = Obj(id: UUID(), lane: 0, startTime: 0, duration: 10, fadeIn: 0, fadeOut: 2, children: nil)
            let b1 = Obj(id: UUID(), lane: 0, startTime: 8, duration: 5, fadeIn: 2, fadeOut: 0, children: nil)
            let b2 = Obj(id: UUID(), lane: 0, startTime: 8, duration: 6, fadeIn: 2, fadeOut: 0, children: nil)
            for order in [[a, b1, b2], [a, b2, b1], [b2, a, b1], [b1, b2, a]] {
                let m = Model(items: order)
                let new = NewSide(m)
                let old = m.seamNeighbour(of: a.id, onRight: true)
                check("tie: first in the model's order", new.partners[a.id]?.right == old,
                      "old \(String(describing: old))")
                check("tie: left side of b1", new.partners[b1.id]?.left == m.seamNeighbour(of: b1.id, onRight: false))
                withTies += 1
            }
        }
        // The empty and single cases.
        check("empty project", NewSide(Model(items: [])).partners.isEmpty)
        let lone = Obj(id: UUID(), lane: 0, startTime: 0, duration: 1, fadeIn: 0, fadeOut: 0, children: nil)
        check("a lone object", NewSide(Model(items: [lone])).partners.isEmpty)

        print("\(projects) projects (\(withZones) with at least one crossfade, \(withTies) hand-made ties), \(total) assertions")
        if fails.isEmpty { print("ALL PASS"); exit(0) }
        print("\(fails.count) FAILED"); exit(1)
    }
}

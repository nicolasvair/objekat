// The insertion between two lanes (`Shared/LaneInsertion.swift`), asserted with no screen.
//
//     swiftc -parse-as-library ../objekat/Shared/LaneCompaction.swift ../objekat/Shared/MoveDropResolution.swift \
//         ../objekat/Shared/LaneInsertion.swift test_lane_insertion.swift -o /tmp/lanein && /tmp/lanein

import Foundation

var fails = 0
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { print("ok    " + label) } else { fails += 1; print("FAIL  " + label + "  " + detail()) }
}

typealias LI = LaneInsertion

/// A scene made of named siblings: `n` letter -> UUID.
final class Scene {
    var ids: [String: UUID] = [:]
    func id(_ n: String) -> UUID { if let i = ids[n] { return i }; let i = UUID(); ids[n] = i; return i }
    func name(_ i: UUID) -> String { ids.first { $0.value == i }?.key ?? "?" }
    func sib(_ n: String, _ lane: Int, span: Int = 0, moved: Bool = false) -> LI.Sibling {
        LI.Sibling(id: id(n), lane: lane, span: span, isMoved: moved)
    }
    /// The final lanes of every name of `sibs` once `plan.laneChanges` is applied.
    func finals(_ sibs: [LI.Sibling], _ plan: LI.Plan) -> [String: Int] {
        var out: [String: Int] = [:]
        for s in sibs where !s.isMoved { out[name(s.id)] = plan.laneChanges[s.id] ?? s.lane }
        return out
    }
}

func movedLanes(_ sibs: [LI.Sibling]) -> [UUID: Int] {
    var m: [UUID: Int] = [:]
    for s in sibs where s.isMoved { m[s.id] = s.lane }
    return m
}

func rootFrame(_ sibs: [LI.Sibling]) -> LI.Frame {
    LI.Frame(parentID: nil, origin: 0, rowCount: Int.max, siblings: sibs)
}

@main
enum LaneInsertionTest {
  static func main() {
    // T1 — the gap under the block, and the width of the band
    do {
        let hb = LI.halfBand(laneStep: 125)
        check("T1 halfBand(125) = 14/125", abs(hb - 14.0 / 125.0) < 1e-9, "\(hb)")
        check("T1 halfBand(40) = 4.8/40", abs(LI.halfBand(laneStep: 40) - 4.8 / 40.0) < 1e-9)
        check("T1 halfBand(20) = 4/20 (floor of 4 px)", abs(LI.halfBand(laneStep: 20) - 4.0 / 20.0) < 1e-9)
        check("T1 (3; 0.5) -> 4", LI.boundaryRow(grabbedDisplayLane: 3, rawRows: 0.5, halfBand: hb) == 4)
        check("T1 (3; 0.4) -> 4", LI.boundaryRow(grabbedDisplayLane: 3, rawRows: 0.4, halfBand: hb) == 4)
        check("T1 (3; 0.3) -> nil", LI.boundaryRow(grabbedDisplayLane: 3, rawRows: 0.3, halfBand: hb) == nil)
        check("T1 (3; -0.5) -> 3", LI.boundaryRow(grabbedDisplayLane: 3, rawRows: -0.5, halfBand: hb) == 3)
        check("T1 (0; -0.5) -> 0", LI.boundaryRow(grabbedDisplayLane: 0, rawRows: -0.5, halfBand: hb) == 0)
        check("T1 (0; -1.5) -> nil (above the top)", LI.boundaryRow(grabbedDisplayLane: 0, rawRows: -1.5, halfBand: hb) == nil)
        check("T1 (3; 0) -> nil (centred on a row)", LI.boundaryRow(grabbedDisplayLane: 3, rawRows: 0, halfBand: hb) == nil)
    }

    // T2 — root a0 b1 c2 d3, d dragged between a and b
    do {
        let S = Scene()
        let sibs = [S.sib("a", 0), S.sib("b", 1), S.sib("c", 2), S.sib("d", 3, moved: true)]
        let root = rootFrame(sibs)
        let p = LI.plan(boundaryRow: 1, openGroups: [], root: root, source: root,
                        movedLanes: movedLanes(sibs), isCopy: false, allowsGroupTarget: true)
        check("T2 plan exists, lane 1, k 1, root", p?.lane == 1 && p?.count == 1 && p?.parentID == nil, "\(String(describing: p))")
        if let p = p {
            let f = S.finals(sibs, p)
            check("T2 a0 b2 c3 (lane 3 closed, d on 1)", f == ["a": 0, "b": 2, "c": 3], "\(f)")
            check("T2 laneBefore = 1", p.laneBefore == 1 && p.boundaryRow == 1)
        }
    }

    // T3 — before the first lane
    do {
        let S = Scene()
        let sibs = [S.sib("a", 0), S.sib("b", 1), S.sib("c", 2), S.sib("d", 3, moved: true)]
        let root = rootFrame(sibs)
        let p = LI.plan(boundaryRow: 0, openGroups: [], root: root, source: root,
                        movedLanes: movedLanes(sibs), isCopy: false, allowsGroupTarget: true)
        check("T3 B = 0 -> lane 0", p?.lane == 0)
        if let p = p { check("T3 everything goes down", S.finals(sibs, p) == ["a": 1, "b": 2, "c": 3]) }
    }

    // T4 — after the last lane: nobody to push
    do {
        let S = Scene()
        let sibs = [S.sib("a", 0), S.sib("b", 1), S.sib("c", 2), S.sib("d", 3, moved: true)]
        let root = rootFrame(sibs)
        let p = LI.plan(boundaryRow: 4, openGroups: [], root: root, source: root,
                        movedLanes: movedLanes(sibs), isCopy: false, allowsGroupTarget: true)
        check("T4 after the last row -> nil", p == nil)
        let p3 = LI.plan(boundaryRow: 3, openGroups: [], root: root, source: root,
                         movedLanes: movedLanes(sibs), isCopy: false, allowsGroupTarget: true)
        check("T4b before the moved last lane (nobody below) -> nil", p3 == nil)
    }

    // T5 — variable heights: lane 0 is a MIDI clip with an open piano roll (span 2, rows 0-2), lane 1 on row 3
    do {
        let S = Scene()
        let sibs = [S.sib("m", 0, span: 2), S.sib("x", 1), S.sib("y", 2, moved: true)]
        let root = rootFrame(sibs)
        func plan(_ B: Int) -> LI.Plan? {
            LI.plan(boundaryRow: B, openGroups: [], root: root, source: root,
                    movedLanes: movedLanes(sibs), isCopy: false, allowsGroupTarget: true)
        }
        check("T5 B = 1 (inside the piano roll) -> nil", plan(1) == nil)
        check("T5 B = 2 (inside the piano roll) -> nil", plan(2) == nil)
        check("T5 B = 3 -> lane 1", plan(3)?.lane == 1, "\(String(describing: plan(3)))")
    }

    // T6 — an open group G (root lane 0) holding g0, g1 (rows 1-2, drop row 3), t on root lane 1 (row 4)
    let S6 = Scene()
    let gID = S6.id("G")
    do {
        let S = S6
        let kids = [S.sib("g0", 0), S.sib("g1", 1)]
        let G = LI.Frame(parentID: gID, origin: 1, rowCount: 3, siblings: kids)
        let rootSibs = [S.sib("G", 0, span: 3), S.sib("t", 1, moved: true)]
        let root = rootFrame(rootSibs)
        func plan(_ B: Int) -> LI.Plan? {
            LI.plan(boundaryRow: B, openGroups: [G], root: root, source: root,
                    movedLanes: movedLanes(rootSibs), isCopy: false, allowsGroupTarget: true)
        }
        check("T6 B = 1 -> G lane 0", plan(1)?.parentID == gID && plan(1)?.lane == 0, "\(String(describing: plan(1)))")
        check("T6 B = 2 -> G lane 1", plan(2)?.parentID == gID && plan(2)?.lane == 1)
        check("T6 B = 3 (the drop row) -> nil", plan(3) == nil)
        // B = 4 is the row of t itself: nobody else below
        check("T6 B = 4 -> nil (t is the moved one)", plan(4) == nil)
        // with a non-moved root object below
        let rs2 = [S.sib("G", 0, span: 3), S.sib("t", 1), S.sib("u", 2, moved: true)]
        let root2 = rootFrame(rs2)
        let p4 = LI.plan(boundaryRow: 4, openGroups: [G], root: root2, source: root2,
                         movedLanes: movedLanes(rs2), isCopy: false, allowsGroupTarget: true)
        check("T6 B = 4 -> root lane 1", p4?.parentID == nil && p4?.lane == 1, "\(String(describing: p4))")
        let p0 = LI.plan(boundaryRow: 0, openGroups: [G], root: root2, source: root2,
                         movedLanes: movedLanes(rs2), isCopy: false, allowsGroupTarget: true)
        check("T6 B = 0 -> root lane 0", p0?.parentID == nil && p0?.lane == 0)
        // T6b: t from the root into G between g0 and g1: root lane of t closed, G's g1 shifted
        let rs3 = [S.sib("G", 0, span: 3), S.sib("t", 1, moved: true), S.sib("u", 2)]
        let root3 = rootFrame(rs3)
        let pg = LI.plan(boundaryRow: 2, openGroups: [G], root: root3, source: root3,
                         movedLanes: movedLanes(rs3), isCopy: false, allowsGroupTarget: true)
        check("T6b into G lane 1: g1 -> 2, root u -> 1 (closed)",
              pg?.lane == 1 && pg?.laneChanges[S.id("g1")] == 2 && pg?.laneChanges[S.id("u")] == 1
              && pg?.laneChanges[S.id("g0")] == nil, "\(String(describing: pg))")
    }

    // T7 — A ⊃ B, both open, insertion in B: only B's children change
    do {
        let S = Scene()
        let aID = S.id("A"), bID = S.id("B")
        // rows: A 0 | B 1 | b0 2, b1 3, (B drop row 4) | A's x on lane 1 -> row 6 ... keep simple
        let Bf = LI.Frame(parentID: bID, origin: 2, rowCount: 3, siblings: [S.sib("b0", 0), S.sib("b1", 1)])
        let Af = LI.Frame(parentID: aID, origin: 1, rowCount: 5, siblings: [S.sib("B", 0, span: 3), S.sib("x", 1)])
        let rs = [S.sib("A", 0, span: 5), S.sib("t", 1, moved: true), S.sib("u", 2)]
        let root = rootFrame(rs)
        let p = LI.plan(boundaryRow: 3, openGroups: [Af, Bf], root: root, source: root,
                        movedLanes: movedLanes(rs), isCopy: false, allowsGroupTarget: true)
        check("T7 inserted in B", p?.parentID == bID && p?.lane == 1, "\(String(describing: p))")
        let names = Set((p?.laneChanges.keys.map { S.name($0) }) ?? [])
        check("T7 only B's children and the closed root lane change", names.isSubset(of: ["b1", "u"]) && names.contains("b1"), "\(names)")
    }

    // T8 — a moved group, B inside its own band -> nil
    do {
        let S = Scene()
        let gID = S.id("G")
        let G = LI.Frame(parentID: gID, origin: 1, rowCount: 3, isMoved: true, siblings: [S.sib("g0", 0), S.sib("g1", 1)])
        let rs = [S.sib("G", 0, span: 3, moved: true), S.sib("t", 1)]
        let root = rootFrame(rs)
        let p = LI.plan(boundaryRow: 2, openGroups: [G], root: root, source: root,
                        movedLanes: movedLanes(rs), isCopy: false, allowsGroupTarget: true)
        check("T8 B in the moved group's own band -> nil", p == nil)
    }

    // T9 — several moved: a0 b1(m) c2 d3(m) e4, B = 0
    do {
        let S = Scene()
        let sibs = [S.sib("a", 0), S.sib("b", 1, moved: true), S.sib("c", 2), S.sib("d", 3, moved: true), S.sib("e", 4)]
        let root = rootFrame(sibs)
        let p = LI.plan(boundaryRow: 0, openGroups: [], root: root, source: root,
                        movedLanes: movedLanes(sibs), isCopy: false, allowsGroupTarget: true)
        check("T9 lane 0, k 2", p?.lane == 0 && p?.count == 2)
        if let p = p {
            check("T9 laneChanges = {a:2, c:3} (e stays on 4)",
                  p.laneChanges == [S.id("a"): 2, S.id("c"): 3], "\(p.laneChanges.mapKeys { S.name($0) })")
            let ranks = LI.movedRanks(movedLanes(sibs))
            check("T9 ranks b0 d1", ranks[S.id("b")] == 0 && ranks[S.id("d")] == 1)
        }
    }

    // T10 — simultaneous: two moved objects on the same lane 2 arrive on the same new lane
    do {
        let S = Scene()
        let sibs = [S.sib("a", 0), S.sib("p", 2, moved: true), S.sib("q", 2, moved: true), S.sib("z", 3)]
        let root = rootFrame(sibs)
        let p = LI.plan(boundaryRow: 0, openGroups: [], root: root, source: root,
                        movedLanes: movedLanes(sibs), isCopy: false, allowsGroupTarget: true)
        let r = LI.movedRanks(movedLanes(sibs))
        check("T10 k = 1 and the two share rank 0", p?.count == 1 && r[S.id("p")] == 0 && r[S.id("q")] == 0)
        if let p = p { check("T10 a -> 1, z -> 3 (lane 2 closes to 2, then is pushed)", S.finals(sibs, p) == ["a": 1, "z": 3], "\(S.finals(sibs, p))") }
    }

    // T11 — copy of T9: nothing closes, everything goes down, lane 0
    do {
        let S = Scene()
        let sibs = [S.sib("a", 0), S.sib("b", 1), S.sib("c", 2), S.sib("d", 3), S.sib("e", 4)]
        let root = rootFrame(sibs)
        let moved: [UUID: Int] = [S.id("b"): 1, S.id("d"): 3]
        let p = LI.plan(boundaryRow: 0, openGroups: [], root: root, source: root,
                        movedLanes: moved, isCopy: true, allowsGroupTarget: true)
        check("T11 copy: lane 0, k 2", p?.lane == 0 && p?.count == 2)
        if let p = p { check("T11 copy: a2 b3 c4 d5 e6", S.finals(sibs, p) == ["a": 2, "b": 3, "c": 4, "d": 5, "e": 6], "\(S.finals(sibs, p))") }
    }

    // T12 — comments: shifted like objects; a comment on a vacated lane keeps the lane open
    do {
        let S = Scene()
        let sibs = [S.sib("a", 0), S.sib("b", 1), S.sib("note", 2), S.sib("d", 3, moved: true)]
        let root = rootFrame(sibs)
        let p = LI.plan(boundaryRow: 0, openGroups: [], root: root, source: root,
                        movedLanes: movedLanes(sibs), isCopy: false, allowsGroupTarget: true)
        check("T12 a comment is shifted like an object", p?.laneChanges[S.id("note")] == 3, "\(String(describing: p))")
        // the moved object d shares lane 3 with a comment: lane 3 must stay
        let sibs2 = [S.sib("a", 0), S.sib("b", 1), S.sib("note", 3), S.sib("d", 3, moved: true), S.sib("e", 4)]
        let root2 = rootFrame(sibs2)
        let p2 = LI.plan(boundaryRow: 1, openGroups: [], root: root2, source: root2,
                         movedLanes: movedLanes(sibs2), isCopy: false, allowsGroupTarget: true)
        // b' = 1 (nothing closed below), b -> 2, note stays lane 3 -> 4, e 4 -> 5
        check("T12b a lane carrying a comment is not closed", p2?.laneChanges[S.id("note")] == 4 && p2?.laneChanges[S.id("e")] == 5,
              "\(String(describing: p2?.laneChanges.mapKeys { S.name($0) }))")
    }

    // T13 — ejection: G{g0(m), g1}, target the root
    do {
        let S = Scene()
        let gID = S.id("G")
        let kids = [S.sib("g0", 0, moved: true), S.sib("g1", 1)]
        let Gsrc = LI.Frame(parentID: gID, origin: 1, rowCount: 3, siblings: kids)
        let rs = [S.sib("G", 0, span: 3), S.sib("t", 1)]
        let root = rootFrame(rs)
        // B = 4 is the row of t (G rows 0..3): insert before t at the root
        let p = LI.plan(boundaryRow: 4, openGroups: [Gsrc], root: root, source: Gsrc,
                        movedLanes: [S.id("g0"): 0], isCopy: false, allowsGroupTarget: true)
        check("T13 root target, lane 1", p?.parentID == nil && p?.lane == 1, "\(String(describing: p))")
        check("T13 g1 -> 0 in G (closed), t -> 2 at the root",
              p?.laneChanges[S.id("g1")] == 0 && p?.laneChanges[S.id("t")] == 2, "\(String(describing: p?.laneChanges.mapKeys { S.name($0) }))")
    }

    // T14 — X between its two neighbours: nothing changes lane
    do {
        let S = Scene()
        let sibs = [S.sib("a", 0), S.sib("X", 1, moved: true), S.sib("c", 2)]
        let root = rootFrame(sibs)
        let p = LI.plan(boundaryRow: 2, openGroups: [], root: root, source: root,
                        movedLanes: movedLanes(sibs), isCopy: false, allowsGroupTarget: true)
        check("T14 laneChanges empty, lane 1", p != nil && p!.laneChanges.isEmpty && p!.lane == 1, "\(String(describing: p))")
    }

    // T15 — allowsGroupTarget = false with B inside a band
    do {
        let S = Scene()
        let gID = S.id("G")
        let G = LI.Frame(parentID: gID, origin: 1, rowCount: 3, siblings: [S.sib("g0", 0), S.sib("g1", 1)])
        let rs = [S.sib("G", 0, span: 3), S.sib("t", 1, moved: true)]
        let root = rootFrame(rs)
        let p = LI.plan(boundaryRow: 2, openGroups: [G], root: root, source: root,
                        movedLanes: movedLanes(rs), isCopy: true, allowsGroupTarget: false)
        check("T15 ⌥ copy from the root never inserts inside a group", p == nil)
    }

    // T16 — 200 random scenes, fixed seed
    do {
        struct LCG { var s: UInt64
            mutating func next() -> Int { s = s &* 6364136223846793005 &+ 1442695040888963407; return Int((s >> 33) & 0x7fffffff) }
            mutating func below(_ n: Int) -> Int { next() % n } }
        var rng = LCG(s: 0xC0FFEE)
        var bad: [String] = []
        var planCount = 0
        for scene in 0..<200 {
            let S = Scene()
            // root: 3..7 siblings on lanes 0..5, some spans, sometimes one open group G with children
            let n = 3 + rng.below(5)
            var rootSibs: [LI.Sibling] = []
            let gLane = rng.below(4)
            let hasG = rng.below(2) == 0
            let nKids = 2 + rng.below(3)
            var kidSibs: [LI.Sibling] = []
            for i in 0..<nKids { kidSibs.append(S.sib("k\(i)", rng.below(4))) }
            let kidMaxLane = (kidSibs.map(\.lane).max() ?? 0)
            let gSpan = kidMaxLane + 2
            for i in 0..<n {
                var lane = rng.below(6)
                if hasG && lane == gLane { lane = (lane + 1) % 6 }
                let span = rng.below(5) == 0 ? 1 : 0
                rootSibs.append(S.sib("r\(i)", lane, span: span))
            }
            if hasG { rootSibs.append(S.sib("G", gLane, span: gSpan)) }
            // choose the source frame and the moved subset (never G itself when it is the source of kids)
            let fromKids = hasG && rng.below(3) == 0
            func mark(_ sibs: [LI.Sibling]) -> [LI.Sibling] {
                var out = sibs.map { LI.Sibling(id: $0.id, lane: $0.lane, span: $0.span, isMoved: rng.below(3) == 0) }
                if !out.contains(where: { $0.isMoved }) { let i = rng.below(out.count); let o = out[i]
                    out[i] = LI.Sibling(id: o.id, lane: o.lane, span: o.span, isMoved: true) }
                return out
            }
            var movedGroupMoved = false
            if fromKids { kidSibs = mark(kidSibs) } else {
                rootSibs = mark(rootSibs)
                movedGroupMoved = rootSibs.contains { $0.isMoved && $0.id == S.id("G") }
            }
            // the display origin of G's children
            var gRow = 0
            if hasG { gRow = gLane + rootSibs.filter { $0.lane < gLane }.map(\.span).reduce(0, +) }
            let gID = S.id("G")
            let Gf = LI.Frame(parentID: gID, origin: gRow + 1, rowCount: gSpan, isMoved: movedGroupMoved, siblings: kidSibs)
            let root = rootFrame(rootSibs)
            let source: LI.Frame = fromKids ? Gf : root
            let isCopy = rng.below(4) == 0
            let totalRows = 12 + gSpan
            for B in 0...totalRows {
                let moved = fromKids ? movedLanes(kidSibs) : movedLanes(rootSibs)
                guard let p = LI.plan(boundaryRow: B, openGroups: hasG ? [Gf] : [], root: root, source: source,
                                      movedLanes: moved, isCopy: isCopy, allowsGroupTarget: true) else { continue }
                planCount += 1
                let target = p.parentID == nil ? root : Gf
                let tag = "scene \(scene) B \(B)"
                func final(_ s: LI.Sibling) -> Int { p.laneChanges[s.id] ?? s.lane }
                // no moved id is changed
                if p.laneChanges.keys.contains(where: { k in
                    !isCopy && (rootSibs + kidSibs).contains { $0.id == k && $0.isMoved } }) { bad.append(tag + " moved id in laneChanges") }
                // lanes >= 0
                if p.laneChanges.values.contains(where: { $0 < 0 }) { bad.append(tag + " negative lane") }
                // all changed ids belong to the source or the target frame
                let known = Set((target.siblings + source.siblings).map(\.id))
                if !p.laneChanges.keys.allSatisfy({ known.contains($0) }) { bad.append(tag + " foreign id") }
                // relative order kept within each frame, and nothing non-moved on b'...b'+k-1 of the target
                for frame in [target, source] {
                    let stay = frame.siblings.filter { isCopy || !$0.isMoved }
                    for x in stay { for y in stay {
                        if x.lane < y.lane && !(final(x) < final(y)) { bad.append(tag + " order broken") }
                        if x.lane == y.lane && final(x) != final(y) { bad.append(tag + " equal lanes split") }
                    } }
                }
                for s in target.siblings where isCopy || !s.isMoved {
                    let f = final(s)
                    if f >= p.lane && f < p.lane + p.count { bad.append(tag + " object on the inserted lanes") }
                }
            }
        }
        check("T16 200 random scenes: invariants hold (\(planCount) plans checked)", bad.isEmpty && planCount > 100, bad.prefix(5).joined(separator: " | "))
    }

    print(fails == 0 ? "ALL PASS" : "\(fails) FAILED")
    exit(fails == 0 ? 0 : 1)
  }
}

extension Dictionary {
    func mapKeys<K: Hashable>(_ f: (Key) -> K) -> [K: Value] {
        var out: [K: Value] = [:]
        for (k, v) in self { out[f(k)] = v }
        return out
    }
}

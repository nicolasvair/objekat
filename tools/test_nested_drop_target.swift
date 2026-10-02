// Where a MOVE lands on release, for objects nested 2-3 groups deep — asserted with no screen.
//
// Point D of the 2026-10-02 Canvas feedback ("a clip dropped into group C, itself in B, itself in A,
// overwrites as if it had been dropped on A"). This file copies, as PURE functions over a stand-in
// tree, the three pieces of `TimelineView+DragHandler.swift` (phase == .ended of the move,
// ~l.1325-1431) and of the model that decide it:
//
//   - `buildLaneEntries` / `occupiedLanes` / `childLaneCount` / `expandedSpan` (EditViewModel.swift,
//     SoundObject.swift) — the display rows;
//   - `grabbedFinalAbsDL` — the row the release believes the hand is on;
//   - `groupDropEntry` — the innermost open group holding that row, then the branch taken
//     (reparent / eject / move inside the source group) and the MODEL lane written.
//
// `current` is the code as it is at f24773db; `fixed` is the proposed correction (the row is the
// grabbed ENTRY's display lane + dl, exactly what the preview draws; every display row is turned
// back into a model lane of the frame that receives it). The preview is the reference: the hand
// SEES the block at `entry.displayLane + dl` (`previewOffset`), so the release must land there.
//
//     swiftc -parse-as-library test_nested_drop_target.swift -o /tmp/nesteddrop && /tmp/nesteddrop
//
// Exit 0 = every `fixed` case lands where the preview showed AND every `current` case reproduces
// the diagnosed fault (so the file also pins the diagnosis; once the app is fixed, flip the
// `current` expectations).

import Foundation

var fails = 0
func check(_ label: String, _ ok: Bool) {
    if ok { print("ok    " + label) } else { fails += 1; print("FAIL  " + label) }
}

// MARK: - Stand-in model

final class Node {
    let name: String
    var lane: Int
    var children: [Node]?          // nil = clip
    var expanded: Bool
    init(_ name: String, lane: Int, children: [Node]? = nil, expanded: Bool = true) {
        self.name = name; self.lane = lane; self.children = children; self.expanded = expanded
    }
    var isGroup: Bool { children != nil }
    var showsChildrenInline: Bool { isGroup && expanded }
    // SoundObject.expandedSpan (no automation band, no piano roll here)
    var expandedSpan: Int { showsChildrenInline ? childLaneCount : 0 }
    // SoundObject.childLaneCount
    var childLaneCount: Int {
        guard let c = children else { return 0 }
        let base = max(1, Node.occupiedLanes(c))
        return expanded ? base + 1 : base
    }
    // SoundObject.occupiedLanes
    static func occupiedLanes(_ children: [Node]) -> Int {
        var spanOfLane: [Int: Int] = [:]
        for c in children { spanOfLane[c.lane, default: 0] += c.expandedSpan }
        var above: [Int: Int] = [:]; var running = 0
        for l in spanOfLane.keys.sorted() { above[l] = running; running += spanOfLane[l]! }
        var maxBottom = 0
        for c in children { maxBottom = max(maxBottom, c.lane + (above[c.lane] ?? 0) + 1 + c.expandedSpan) }
        return maxBottom
    }
}

struct Entry { let displayLane: Int; let node: Node; let parent: Node? }

// EditViewModel.buildLaneEntries
func buildLaneEntries(_ items: [Node], parent: Node?, offset: Int) -> [Entry] {
    var spanByLane: [Int: Int] = [:]
    for it in items { spanByLane[it.lane, default: 0] += it.expandedSpan }
    var prefix: [Int: Int] = [:]; var running = 0
    for l in spanByLane.keys.sorted() { prefix[l] = running; running += spanByLane[l]! }
    var out: [Entry] = []
    for it in items {
        let dl = offset + it.lane + (prefix[it.lane] ?? 0)
        out.append(Entry(displayLane: dl, node: it, parent: parent))
        if it.showsChildrenInline { out += buildLaneEntries(it.children!, parent: it, offset: dl + 1) }
    }
    return out.sorted { $0.displayLane < $1.displayLane }
}

func isSelfOrDescendant(_ n: Node, of a: Node) -> Bool {
    if n === a { return true }
    for c in a.children ?? [] where isSelfOrDescendant(n, of: c) { return true }
    return false
}

/// What the release does, in words a test can compare.
enum Outcome: Equatable, CustomStringConvertible {
    case reparent(into: String, lane: Int)     // reparentToGroup / reparentChildBetweenGroups
    case moveInSource(lane: Int)               // the in-group branch (target == source or nil)
    case eject(topLane: Int)                   // ejectFromGroup
    case topMove(lane: Int)                    // a root object staying at the root
    case cancelled
    var description: String {
        switch self {
        case .reparent(let g, let l): return "reparent→\(g) lane \(l)"
        case .moveInSource(let l):   return "move in source, lane \(l)"
        case .eject(let l):          return "eject to root lane \(l)"
        case .topMove(let l):        return "root move, lane \(l)"
        case .cancelled:             return "cancelled"
        }
    }
}

// EditViewModel.displayLane(forBase:) / baseLaneForDisplay — the ROOT frame
func displayLane(forBase b: Int, roots: [Node]) -> Int {
    b + roots.reduce(0) { $0 + ($1.lane < b ? $1.expandedSpan : 0) }
}
/// EditViewModel.baseLaneForDisplay(_:inParent:) — any frame (origin = the parent's row + 1, or 0)
func baseLane(forDisplay target: Int, origin: Int, siblings: [Node]) -> Int {
    var b = 0
    while b < 512 {
        let extra = siblings.reduce(0) { $0 + ($1.lane < b ? $1.expandedSpan : 0) }
        if origin + b + extra >= target { return b }
        b += 1
    }
    return b
}

/// The innermost open group whose child rows hold `row`, the movers' own subtree excluded.
func groupDrop(_ entries: [Entry], row: Int, moved: Node) -> Entry? {
    entries.filter { e in
        guard e.node.showsChildrenInline, !isSelfOrDescendant(e.node, of: moved) else { return false }
        let cl = row - e.displayLane - 1
        return cl >= 0 && cl < e.node.childLaneCount
    }.max { $0.displayLane < $1.displayLane }
}

/// A single object `grabbed`, dragged by `dl` DISPLAY rows (dt irrelevant here), no ⌥, no range.
func release(roots: [Node], grabbed: Node, dl: Int, fixed: Bool) -> Outcome {
    let entries = buildLaneEntries(roots, parent: nil, offset: 0)
    guard let me = entries.first(where: { $0.node === grabbed }) else { return .cancelled }
    let source = me.parent
    let anchorLane = grabbed.lane

    // ── grabbedFinalAbsDL ──
    let row: Int
    if fixed {
        row = me.displayLane + dl                                   // what previewOffset draws
    } else if let sg = source, let sgDL = entries.first(where: { $0.node === sg })?.displayLane {
        row = sgDL + 1 + anchorLane + dl                            // DragHandler l.1328
    } else {
        row = displayLane(forBase: anchorLane, roots: roots) + dl   // DragHandler l.1330
    }

    let target = groupDrop(entries, row: row, moved: grabbed)
    if target == nil, entries.contains(where: { e in
        e.node.showsChildrenInline && isSelfOrDescendant(e.node, of: grabbed)
            && (0..<e.node.childLaneCount).contains(row - e.displayLane - 1) }) { return .cancelled }

    func childLane(in t: Entry) -> Int {
        fixed ? baseLane(forDisplay: row, origin: t.displayLane + 1, siblings: t.node.children!)
              : row - t.displayLane - 1                             // grabbedFinalAbsDL - gDL - 1
    }

    if let sg = source {
        if let t = target, t.node !== sg { return .reparent(into: t.node.name, lane: childLane(in: t)) }
        let sgEntry = entries.first { $0.node === sg }!
        if fixed {
            if let t = target, t.node === sg { return .moveInSource(lane: childLane(in: t)) }
            return .eject(topLane: baseLane(forDisplay: max(0, row), origin: 0, siblings: roots))
        }
        let newRelLane = anchorLane + dl                            // l.1373: model lane + DISPLAY delta
        if target == nil, newRelLane < 0 || newRelLane >= sg.childLaneCount {
            // l.1404: the lane of whatever entry sits on that row, else the root conversion
            let base = entries.first { $0.displayLane == max(0, row) }?.node.lane
                ?? baseLane(forDisplay: max(0, row), origin: 0, siblings: roots)
            return .eject(topLane: base)
        }
        _ = sgEntry
        return .moveInSource(lane: max(0, anchorLane + dl))         // l.1425
    }
    if let t = target { return .reparent(into: t.node.name, lane: childLane(in: t)) }
    return .topMove(lane: baseLane(forDisplay: max(0, row), origin: 0, siblings: roots))
}

// MARK: - The scene (the one reported: A ⊃ B ⊃ C, all open)
//
//   row 0  A (root lane 0)
//   row 1    B (A lane 0)
//   row 2      C (B lane 0)
//   row 3        Z (C lane 0)
//   row 4        · C's drop row
//   row 5      Y (B lane 1)          ← below C: extraAbove(B frame) = C.span = 2
//   row 6      · B's drop row
//   row 7    X (A lane 1)            ← below B: extraAbove(A frame) = B.span = 5
//   row 8    · A's drop row
//   row 9  T (root lane 1)           ← below A: root extraAbove = A.span = 8
func scene() -> (roots: [Node], A: Node, B: Node, C: Node, X: Node, Y: Node, Z: Node, T: Node) {
    let Z = Node("Z", lane: 0)
    let C = Node("C", lane: 0, children: [Z])
    let Y = Node("Y", lane: 1)
    let B = Node("B", lane: 0, children: [C, Y])
    let X = Node("X", lane: 1)
    let A = Node("A", lane: 0, children: [B, X])
    let T = Node("T", lane: 1)
    return ([A, T], A, B, C, X, Y, Z, T)
}

@main
enum NestedDropTargetTest {
  static func main() {
    let s = scene()
    let rows = buildLaneEntries(s.roots, parent: nil, offset: 0).map { "\($0.displayLane):\($0.node.name)" }
    check("scene rows are A0 B1 C2 Z3 Y5 X7 T9 (\(rows.joined(separator: " ")))",
          rows == ["0:A", "1:B", "2:C", "3:Z", "5:Y", "7:X", "9:T"])

    // Each case: (label, grabbed, dl, what the PREVIEW shows = the expected fixed outcome,
    //             what the CURRENT code does = the diagnosed fault)
    let cases: [(String, Node, Int, Outcome, Outcome)] = [
        // 1. A ROOT clip into C (row 9 → row 4, C's drop row): fine today.
        ("T (root) → C's drop row", s.T, -5, .reparent(into: "C", lane: 1), .reparent(into: "C", lane: 1)),
        // 2. A clip of A, sitting BELOW the open B, into C: the release thinks the hand is 5 rows
        //    higher (B's span is missing) — above A itself → EJECTED to the root at A's lane, and
        //    resolveOverlaps(root) then cuts / holes / deletes A. "Overwrites as if dropped on A."
        ("X (in A, below open B) → C's drop row", s.X, -3, .reparent(into: "C", lane: 1), .eject(topLane: 0)),
        ("X (in A, below open B) → onto Z's row in C", s.X, -4, .reparent(into: "C", lane: 0), .eject(topLane: 0)),
        // 3. A clip of B, below the open C, one row up into C: the release lands on C's OWN row,
        //    which belongs to B → "move inside B" to model lane 0 = C's lane → overwrites C.
        ("Y (in B, below open C) → C's drop row", s.Y, -1, .reparent(into: "C", lane: 1), .moveInSource(lane: 0)),
        //    Two rows up, the release lands on B's own row, which belongs to A → Y is REPARENTED
        //    INTO A at model lane 0 = B's lane, and A's resolveOverlaps cuts / holes / deletes B.
        ("Y (in B, below open C) → Z's row in C", s.Y, -2, .reparent(into: "C", lane: 0), .reparent(into: "A", lane: 0)),
        // 4. Into B BELOW the open C (B's drop row): the child lane written is a DISPLAY offset
        //    (4 instead of 2) — the object lands C.span rows lower than shown. Not an overwrite, a drift.
        ("T (root) → B's drop row (below open C)", s.T, -3, .reparent(into: "B", lane: 2), .reparent(into: "B", lane: 4)),
        // 5. The 2-level form of the same fault: X one row up = B's drop row, inside B.
        ("X (in A) → B's drop row", s.X, -1, .reparent(into: "B", lane: 2), .moveInSource(lane: 0)),
    ]
    for (label, g, dl, want, now) in cases {
        let f = release(roots: s.roots, grabbed: g, dl: dl, fixed: true)
        let c = release(roots: s.roots, grabbed: g, dl: dl, fixed: false)
        check("FIXED   \(label): \(f) (preview: \(want))", f == want)
        check("CURRENT \(label): \(c) (diagnosed: \(now))", c == now)
    }

    // A GROUP behaves the same as a clip when it sits below an open sibling: the fault is the
    // SOURCE position, not the kind. G = a closed group of A below B.
    let s2 = scene()
    let G = Node("G", lane: 2, children: [Node("g1", lane: 0)], expanded: false)
    s2.A.children!.append(G)                                     // row 8 (A's drop row moves to 9)
    let fG = release(roots: s2.roots, grabbed: G, dl: -4, fixed: true)
    let cG = release(roots: s2.roots, grabbed: G, dl: -4, fixed: false)
    check("FIXED   G (closed group in A, below open B) → C's drop row: \(fG)", fG == .reparent(into: "C", lane: 1))
    check("CURRENT G (closed group, same gesture): \(cG) — same fault as a clip", cG == .eject(topLane: 0))
    // …while a group ABOVE everything open (or at the root) is untouched, which is probably why
    // "a group dragged into C looks fine".
    let s3 = scene()
    let H = Node("H", lane: 2, children: [Node("h1", lane: 0)], expanded: false)
    let roots3 = s3.roots + [H]                                  // root lane 2, row 10
    let cH = release(roots: roots3, grabbed: H, dl: -6, fixed: false)
    check("CURRENT H (ROOT closed group) → C's drop row: \(cH) — fine", cH == .reparent(into: "C", lane: 1))

    print(fails == 0 ? "ALL PASS" : "\(fails) FAILED")
    exit(fails == 0 ? 0 : 1)
  }
}

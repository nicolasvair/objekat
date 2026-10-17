import SwiftUI

// Standalone test of the run a new parallel branch takes (docs/plan_synoptic_rework.md §B.2, the user's rules of
// 13 October 2026; @see SynopticBranchRun): the element under the "+" with no selection; the selected run that
// starts there; the tail "+" going up; an empty series = an empty branch; a card's menu = the selected run round
// it, else the card alone; a non-contiguous selection keeps the part that touches the start; a send's marker is
// a barrier. And the layout agrees: with no selection, the run of a "+" starts at its `branchTargetID` (D3).
//
//     swiftc -parse-as-library -o /tmp/t_branch \
//         ../objekat/Inspector/Synoptic/SynopticGraph.swift \
//         ../objekat/Inspector/Synoptic/SynopticPlusGesture.swift \
//         ../objekat/Inspector/Synoptic/SynopticPlusShortcuts.swift \
//         ../objekat/Inspector/Synoptic/SynopticLayout.swift \
//         ../objekat/Inspector/Synoptic/SynopticBranchRun.swift test_synoptic_branch_run.swift \
//         && /tmp/t_branch

func L(_ key: String, _ args: CVarArg...) -> String { key }

var failures = 0
var total = 0
func check(_ ok: Bool, _ what: String) {
    total += 1
    if !ok { failures += 1; print("FAIL: \(what)") }
}

@main
struct Main {
    static func main() {
        typealias R = SynopticBranchRun
        typealias E = SynopticBranchRun.Element
        let ids = (0..<6).map { _ in UUID() }
        let (a, b, c, d, e, f) = (ids[0], ids[1], ids[2], ids[3], ids[4], ids[5])
        func series(_ sel: Set<UUID>, barrierAt: Set<UUID> = []) -> [E] {
            ids.map { E(id: $0, isBarrier: barrierAt.contains($0), isSelected: sel.contains($0)) }
        }

        // MARK: from a "+", no selection: the element under it (D3)
        let none = series([])
        check(R.forPlus(at: 0, in: none) == [a], "head '+': the first element")
        check(R.forPlus(at: 2, in: none) == [c], "a middle '+': the element under it")
        check(R.forPlus(at: 6, in: none) == [f], "the tail '+': the element above it")
        check(R.forPlus(at: 99, in: none) == [f], "past the tail: the last element")
        check(R.forPlus(at: 0, in: []) == [], "an empty series: nothing (an empty branch)")

        // MARK: the selected run that starts at the "+"
        check(R.forPlus(at: 1, in: series([b, c, d])) == [b, c, d], "b c d selected, '+' above b: all three")
        check(R.forPlus(at: 2, in: series([b, c, d])) == [c, d], "'+' above c: from c downward only")
        check(R.forPlus(at: 0, in: series([b, c, d])) == [a], "the element under the '+' is not selected: it alone")
        check(R.forPlus(at: 1, in: series([b, c, e])) == [b, c], "not contiguous: the part touching the start (e stays)")
        check(R.forPlus(at: 1, in: series([b])) == [b], "one selected: itself")
        check(R.forPlus(at: 0, in: series(Set(ids))) == ids, "everything selected, head '+': the whole series")
        // the tail '+': going UP from the last element
        check(R.forPlus(at: 6, in: series([d, e, f])) == [d, e, f], "tail '+', d e f selected: the three, in order")
        check(R.forPlus(at: 6, in: series([d, e])) == [f], "tail '+', the last one not selected: it alone")
        check(R.forPlus(at: 6, in: series([b, e, f])) == [e, f], "tail '+': the contiguous part touching the last one")

        // MARK: a send's marker is a barrier (the trunk)
        let withMarker = series([b, c, d, e], barrierAt: [d])     // d is a marker between c and e
        check(R.forPlus(at: 1, in: withMarker) == [b, c], "a run stops at a send's marker")
        // view indices skip the marker: a b c | e f → index 3 is e
        check(R.forPlus(at: 3, in: withMarker) == [e], "view index 3 is e (the marker is not counted), its run stops at nothing selected after")
        check(R.forPlus(at: 5, in: withMarker) == [f], "the tail '+' of 5 shown entries: f")
        check(R.forPlus(at: 0, in: [E(id: a, isBarrier: true)]) == [], "a series of markers only: empty (an empty branch)")

        // MARK: from a card's menu
        check(R.around(c, in: series([])) == [c], "no selection: the card alone")
        check(R.around(c, in: series([a, b])) == [c], "the card is not selected: it alone (the selection is elsewhere)")
        check(R.around(c, in: series([b, c, d])) == [b, c, d], "the card in a selected run: the whole run, both ways")
        check(R.around(c, in: series([a, c, d, f])) == [c, d], "not contiguous: the run touching the card")
        check(R.around(b, in: series([a, b, c, d, e], barrierAt: [d])) == [a, b, c], "a marker bounds the run")
        check(R.around(d, in: series([], barrierAt: [d])) == nil, "a marker has no menu")
        check(R.around(UUID(), in: series([])) == nil, "a card of another series: nil")

        // MARK: the layout's D3 agrees: with no selection, a "+"'s run starts at its branchTargetID
        func plug(_ id: UUID, _ name: String) -> SynopticNode {
            SynopticNode(id: id, kind: .plugin(SynopticPlugin(id: id, name: name, category: .utility)))
        }
        let trunk = SynopticNode.series(ids.enumerated().map { plug($1, "P\($0)") })
        let dg = SynopticLayout.diagram(for: trunk, mix: true, stems: true, objectFrame: true)
        let ins = dg.placement.inserts.filter { $0.seriesID == trunk.id }
        check(ins.count == 7, "seven '+' on six entries")
        for z in ins {
            check(R.forPlus(at: z.insertIndex, in: none) == [z.branchTargetID!], "'+' \(z.insertIndex): the layout's D3 target is the run")
            check(z.allowedGestures.contains(.branch), "'+' \(z.insertIndex): a branch is offered")
            check(z.command(for: CGSize(width: 60, height: 35)) == .branch(z.key), "'+' \(z.insertIndex): down-right asks for a branch at that '+'")
        }
        // an empty trunk: the branch IS offered now (an empty branch)
        let empty = SynopticNode.series([])
        let de = SynopticLayout.diagram(for: empty, mix: true, stems: true, objectFrame: true)
        let ez = de.placement.inserts.first!
        check(ez.allowedGestures.contains(.branch), "an empty chain: the branch is offered (an empty branch)")
        check(ez.command(for: CGSize(width: 60, height: 35)) == .branch(ez.key), "an empty chain: down-right asks for it")
        check(R.forPlus(at: ez.insertIndex, in: []) == [], "an empty chain: the run is empty")
        // a bin's series: never
        let bin = SynopticNode(kind: .series([plug(UUID(), "X")]))
        var binNode = bin
        binNode.fxLink = SynopticFXLink(blockID: bin.id, name: "Bin", color: .blue, isDetached: false,
                                        isEnabled: true, memberCount: 2)
        let db = SynopticLayout.diagram(for: .series([binNode]), mix: true, stems: true, objectFrame: true)
        for z in db.placement.inserts where z.role == .fxSeries {
            check(!z.allowedGestures.contains(.branch), "a bin's '+': no branch")
        }

        print(failures == 0 ? "ALL PASS (\(total) assertions)" : "failures: \(failures) of \(total)")
        exit(failures == 0 ? 0 : 1)
    }
}

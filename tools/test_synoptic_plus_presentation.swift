import Foundation

// Standalone test of how the signal view PRESENTS a "+" (docs/plan_synoptic_rework.md §B.2, §B.3, lot L4):
//  - shown while its line is hovered, always in an empty series, and while a drag leaves from it — and,
//    during a drag, no other hovered "+" lights up;
//  - a command whose `SynopticActions` closure is missing becomes `.none` (the ghost then says "not here");
//  - the tooltip lists only the gestures really offered;
//  - what the ghost says along the way;
//  - the STABLE names: a parallel's branches get fresh series ids at every build of the tree (the bound view
//    rebuilds it ~14 times a second), and the "+" held by the hover or by a drag must survive that.
//
//     swiftc -parse-as-library -o /tmp/t_plus_pres \
//         ../objekat/Inspector/Synoptic/SynopticGraph.swift \
//         ../objekat/Inspector/Synoptic/SynopticPlusGesture.swift \
//         ../objekat/Inspector/Synoptic/SynopticPlusShortcuts.swift \
//         ../objekat/Inspector/Synoptic/SynopticLayout.swift \
//         ../objekat/Inspector/Synoptic/SynopticPlusPresentation.swift ../objekat/Shared/FeatureIcons.swift test_synoptic_plus_presentation.swift \
//         && /tmp/t_plus_pres

func L(_ key: String, _ args: CVarArg...) -> String { key }

var failures = 0
var total = 0
func check(_ ok: Bool, _ what: String) {
    total += 1
    if !ok { failures += 1; print("FAIL: \(what)") }
}

func plug(_ name: String) -> SynopticNode { .plugin(SynopticPlugin(name: name, category: .utility)) }

/// The tree the bound view would build: a STABLE root and parallel id, FRESH branch series ids.
func build(root: UUID, parallel: UUID) -> SynopticNode {
    SynopticNode(id: root, kind: .series([
        plug("EQ"),
        SynopticNode(id: parallel, kind: .parallel([
            .series([plug("Comp")]),          // fresh id
            .series([]),                      // fresh id, an EMPTY branch
        ])),
        plug("Limiter"),
    ]))
}

@main
struct Main {
    static func main() {
        typealias P = SynopticPlusPresentation
        let a = SynopticStablePlus.series("A", 0)
        let b = SynopticStablePlus.series("A", 1)
        let e = SynopticStablePlus.series("E", 0)

        // MARK: shown
        check(!P.isShown(a, hovered: nil, dragging: nil, alwaysVisible: []), "hidden at rest")
        check(P.isShown(a, hovered: a, dragging: nil, alwaysVisible: []), "shown while hovered")
        check(!P.isShown(b, hovered: a, dragging: nil, alwaysVisible: []), "a neighbour stays hidden")
        check(P.isShown(e, hovered: nil, dragging: nil, alwaysVisible: [e]), "an empty series' '+' always shows")
        check(P.isShown(e, hovered: a, dragging: b, alwaysVisible: [e]), "…even during somebody else's drag")
        check(P.isShown(a, hovered: nil, dragging: a, alwaysVisible: []), "the dragged '+' shows, hover gone")
        check(!P.isShown(b, hovered: b, dragging: a, alwaysVisible: []), "during a drag, a hovered other stays hidden")
        check(P.isShown(.postFader, hovered: .postFader, dragging: nil, alwaysVisible: []), "post-fader on hover")

        // MARK: available
        let s = UUID(), aux = UUID(), el = UUID()
        let k = SynopticPlusKey.series(s, 1)
        let all = SynopticPlusAvailability.all
        let none = SynopticPlusAvailability()
        let commands: [SynopticPlusCommand] = [
            .openBrowser(k), .openBrowser(.sendChain(aux: aux, index: 0)),
            .insertGainStage(k, .gain), .insertGainStage(k, .gainPanMute),
            .insertGainStage(.sendChain(aux: aux, index: 2), .gain),
            .branch(.series(el, 1)), .send(.chain(1)), .send(.postFader),
        ]
        for c in commands { check(P.available(c, all) == c, "\(c) is carried out when everything is wired") }
        check(P.available(.openBrowser(k), none) == .openBrowser(k), "a click on a series '+' is never lost (onInsertSeries)")
        for c in commands.dropFirst() { check(P.available(c, none) == .none, "\(c) → none with nothing wired") }
        check(P.available(.insertGainStage(.postFader, .gain), all) == .none, "never a gain after the fader")
        var onlyBranch = SynopticPlusAvailability(); onlyBranch.branch = true
        check(P.available(.branch(.series(el, 1)), onlyBranch) == .branch(.series(el, 1)), "branch wired alone")
        check(P.available(.insertGainStage(k, .gain), onlyBranch) == .none, "gain not wired → none")
        var onlySendGain = SynopticPlusAvailability(); onlySendGain.sendGainStage = true
        check(P.available(.insertGainStage(.sendChain(aux: aux, index: 0), .gain), onlySendGain) != .none,
              "a send's gain stage needs onSendPlusGesture only")
        check(P.available(.insertGainStage(k, .gain), onlySendGain) == .none,
              "…and the trunk's needs onPlusGesture")

        // MARK: offered (the tooltip)
        let every: Set<PlusGestureResult> = [.gain, .gainPanMute, .branch, .send]
        check(P.offered(every, key: k, all) == every, "everything offered when wired")
        check(P.offered(every, key: k, none).isEmpty, "nothing offered when nothing is wired")
        check(P.offered(every, key: k, onlyBranch) == [.branch], "only the branch")
        check(P.offered([.gain, .gainPanMute], key: .postFader, all).isEmpty, "no gain after the fader")
        check(P.offered([.send], key: .postFader, all) == [.send], "the post-fader '+' offers the send")
        check(P.offered([.gain, .none], key: .sendChain(aux: aux, index: 0), onlySendGain) == [.gain],
              "`.none` is never listed")

        // MARK: ghost
        let far = CGSize(width: 120, height: 0)
        check(P.ghost(for: .insertGainStage(k, .gain), translation: CGSize(width: 3, height: 1)) == .none,
              "nothing drawn under the click threshold")
        check(P.ghost(for: .none, translation: CGSize(width: 3, height: 0)) == .none, "…even for a refusal")
        check(P.ghost(for: .insertGainStage(k, .gain), translation: far) == .gain, "gain")
        check(P.ghost(for: .insertGainStage(k, .gainPanMute), translation: far) == .gainPanMute, "gain · pan · mute")
        check(P.ghost(for: .branch(.series(el, 1)), translation: far) == .branch, "branch")
        check(P.ghost(for: .send(.chain(0)), translation: far) == .send, "send")
        check(P.ghost(for: .none, translation: far) == .notHere, "a refused drag says 'not here'")
        check(P.ghost(for: .openBrowser(k), translation: far) == .none, "the browser is a click's, never a ghost")

        // The whole chain, as the canvas runs it: a gain drag with `onPlusGesture` missing reads "not here".
        check(P.ghost(for: P.available(.insertGainStage(k, .gain), none), translation: far) == .notHere,
              "an unwired gain reads 'not here'")

        // MARK: stable names
        let rootID = UUID(), parID = UUID()
        let t1 = build(root: rootID, parallel: parID)
        let t2 = build(root: rootID, parallel: parID)
        let n1 = P.seriesNames(of: t1), n2 = P.seriesNames(of: t2)
        check(n1[rootID] == rootID.uuidString && n2[rootID] == rootID.uuidString, "the root keeps its id as its name")
        check(n1.count == 3 && n2.count == 3, "three series: the root and two branches")
        check(Set(n1.values) == Set(n2.values), "the same names across two builds")
        check(Set(n1.keys) != Set(n2.keys), "…although the branch ids differ (the premise)")
        check(Set(n1.values).contains("\(parID.uuidString)#0") && Set(n1.values).contains("\(parID.uuidString)#1"),
              "a branch is named by its parallel and its index")

        // Against the LAYOUT: every '+' of the first build has a twin with the same stable name in the second,
        // at the same place.
        let d1 = SynopticLayout.diagram(for: t1), d2 = SynopticLayout.diagram(for: t2)
        let s1 = d1.placement.inserts.map { (P.stable($0.key, names: n1), $0.center) }
        let s2 = Dictionary(d2.placement.inserts.map { (P.stable($0.key, names: n2), $0.center) },
                            uniquingKeysWith: { x, _ in x })
        check(!s1.isEmpty && s1.count == s2.count, "as many '+' in both builds (\(s1.count))")
        check(Set(s1.map(\.0)).count == s1.count, "no two '+' share a stable name")
        for (name, c) in s1 {
            check(s2[name].map { abs($0.x - c.x) < 1e-6 && abs($0.y - c.y) < 1e-6 } == true,
                  "'+' \(name) found again at the same place")
        }
        let raw1 = Set(d1.placement.inserts.map(\.key)), raw2 = Set(d2.placement.inserts.map(\.key))
        check(raw1 != raw2, "the RAW keys do change between builds (what the stable names are for)")
        // The empty branch's '+' is always visible, and still so by name after the rebuild.
        let always1 = Set(d1.alwaysVisiblePlusKeys.map { P.stable($0, names: n1) })
        let always2 = Set(d2.alwaysVisiblePlusKeys.map { P.stable($0, names: n2) })
        check(always1.contains(.series("\(parID.uuidString)#1", 0)), "the empty branch's '+' is always shown")
        check(always1 == always2, "the always-shown set survives the rebuild")

        // A key the table does not know keeps its own id (never crashes, never collides with a name).
        let stray = UUID()
        check(P.stable(.series(stray, 2), names: n1) == .series(stray.uuidString, 2), "unknown series → its own id")
        check(P.stable(.postFader, names: n1) == .postFader, "post-fader")
        check(P.stable(.sendChain(aux: aux, index: 3), names: n1) == .sendChain(aux, 3), "a send's chain")

        // The zones round a dragged "+": what it offers HERE (a missing closure takes its zone away).
        let trunkZones = P.sectors(allowed: [.gain, .gainPanMute, .branch, .send], key: k, all,
                                   translation: CGSize(width: -50, height: 0))
        check(trunkZones.sectors.map(\.result) == [.gain, .gainPanMute, .branch, .send] && trunkZones.highlighted.map { trunkZones.sectors[$0].result } == .send,
              "the trunk: four zones, left lights the send")
        var noBranch = SynopticPlusAvailability.all; noBranch.branch = false
        let nb = P.sectors(allowed: [.gain, .gainPanMute, .branch, .send], key: k, noBranch,
                           translation: CGSize(width: 50, height: 29))
        check(!nb.sectors.contains { $0.result == .branch } && nb.highlighted == nil,
              "no onBranch: no branch zone, and down-right lights nothing")
        let sc = P.sectors(allowed: [.gain, .gainPanMute], key: .sendChain(aux: aux, index: 0), all,
                           translation: CGSize(width: 90, height: 0))
        check(sc.sectors.map(\.result) == [.gain, .gainPanMute] && sc.highlighted.map { sc.sectors[$0].result } == .gainPanMute, "a send's chain: the gain zones")
        check(P.sectors(allowed: [.send], key: .postFader, all, translation: CGSize(width: 2, height: 0)).highlighted == nil,
              "a click lights nothing")
        // one icon per result, shared by the zones and the ghost
        let icons = [PlusGestureResult.gain, .gainPanMute, .branch, .send].map { P.symbol(for: $0) }
        check(Set(icons).count == 4, "four distinct icons")
        check(P.symbol(for: .send) == FeatureIcons.auxSend && P.symbol(for: .branch) == "arrow.triangle.branch"
              && P.symbol(for: .gain) == "dial.medium" && P.symbol(for: .gainPanMute) == "slider.horizontal.3",
              "the app's own symbols")

        print(failures == 0 ? "ALL PASS (\(total) checks)" : "\(failures) FAILED of \(total)")
        exit(failures == 0 ? 0 : 1)
    }
}

import Foundation

// Standalone test of the user-customisable directions of the signal view's "+" (PlusShortcutMap and what the
// gesture, the layout and the presentation do with a NON-default map): the eight fixed directions and their
// boundaries, the defaults, the swap rule, the stored form (round trip, unknown kinds, duplicates), the plugin
// identity, and a few maps moved around — a plugin on up-right, a send moved up, a gain stage on the vertical,
// a plugin no longer installed.
//
//     swiftc -parse-as-library -o /tmp/t_plus_sc \
//         ../objekat/Inspector/Synoptic/SynopticGraph.swift \
//         ../objekat/Inspector/Synoptic/SynopticPlusShortcuts.swift \
//         ../objekat/Inspector/Synoptic/SynopticPlusGesture.swift \
//         ../objekat/Inspector/Synoptic/SynopticLayout.swift \
//         ../objekat/Inspector/Synoptic/SynopticPlusPresentation.swift test_synoptic_plus_shortcuts.swift \
//         && /tmp/t_plus_sc

/// The layout's labels go through `L()`; a stub here (the key itself), the catalogue being the app's.
func L(_ key: String, _ args: CVarArg...) -> String { key }

var failures = 0
var total = 0
func check(_ ok: Bool, _ what: String) {
    total += 1
    if !ok { failures += 1; print("FAIL: \(what)") }
}

/// A translation of length `r` at `deg` degrees, POSITIVE UPWARD (the screen's y grows downward).
func polar(_ r: Double, _ deg: Double) -> CGSize {
    let a = deg * .pi / 180
    return CGSize(width: r * cos(a), height: -r * sin(a))
}

typealias G = SynopticPlusGesture
typealias P = SynopticPlusPresentation

@main
struct Main {
    static func main() {
        let eq = PlusPluginRef(format: "AudioUnit", identifier: "AudioUnit:Effects/aufx,FQ4p,FabF",
                               name: "Pro-Q 4", manufacturer: "FabFilter")
        let verb = PlusPluginRef(format: "VST3", identifier: "VST3-Valhalla-1234", name: "VintageVerb",
                                 manufacturer: "Valhalla")

        // MARK: The directions
        for d in PlusDirection.allCases {
            check(PlusDirection.at(angle: d.angle) == d, "\(d) at its own axis")
            check(PlusDirection.at(angle: d.angle + 14.9) == d && PlusDirection.at(angle: d.angle - 14.9) == d,
                  "\(d): ±14.9° inside")
        }
        check(PlusDirection.allCases.count == 8, "eight directions")
        check(Set(PlusDirection.allCases.map(\.arrow)).count == 8, "eight distinct arrows")
        // the historical boundaries: right open, the diagonals closed, left open
        check(PlusDirection.at(angle: 15) == .upRight && PlusDirection.at(angle: -15) == .downRight,
              "±15° belongs to the diagonal, not to the right")
        check(PlusDirection.at(angle: 165) == .upLeft && PlusDirection.at(angle: -165) == .downLeft,
              "±165° belongs to the diagonal, not to the left")
        check(PlusDirection.at(angle: -45) == .downRight && PlusDirection.at(angle: -45.01) == nil,
              "the branch's far edge at −45°, closed")
        check(PlusDirection.at(angle: -180) == .left && PlusDirection.at(angle: 179.9) == .left, "left either side of 180°")
        check(PlusDirection.at(angle: 75) == .up && PlusDirection.at(angle: 105) == .up, "up closed at 75° and 105°")
        for dead in [50.0, 60, 70, 110, 120, 130, -50, -60, -70, -110, -120, -130] {
            check(PlusDirection.at(angle: dead) == nil, "\(dead)°: dead angle")
        }
        check(G.direction(CGSize(width: 3, height: 0)) == nil, "a click has no direction")

        // MARK: The defaults
        let def = PlusShortcutMap.defaults
        check(def.action(.right) == .gainStage && def.action(.downRight) == .branch && def.action(.left) == .send,
              "defaults: right gain stage, down-right branch, left send")
        check([PlusDirection.down, .downLeft, .upLeft, .up, .upRight].allSatisfy { def.action($0) == .none },
              "defaults: the five other directions ask for nothing")
        check(def.isDefault && PlusShortcutMap().action(.right) == .none, "an empty map is not the default")
        check(def.pluginRefs.isEmpty, "no plugin by default")
        // the default map classifies as the map-less classifier always did
        let every = G.everything
        for r in stride(from: 10.0, through: 150, by: 20) {
            for deg in stride(from: -180.0, to: 180, by: 2.5) {
                let t = polar(r, deg)
                check(G.classify(t, allowed: every, map: def) == G.classify(t, allowed: every),
                      "defaults = the historical classifier at \(deg)°, \(r) pt")
            }
        }

        // MARK: assign = a swap
        var m = def
        m.assign(.send, to: .up)
        check(m.action(.up) == .send && m.action(.left) == .none, "the send moved up; left took up's nothing")
        m.assign(.branch, to: .right)
        check(m.action(.right) == .branch && m.action(.downRight) == .gainStage, "branch ↔ gain stage swapped")
        m.assign(.plugin(eq), to: .upRight)
        check(m.action(.upRight) == .plugin(eq) && m.pluginRefs == [eq], "a plugin on up-right")
        m.assign(.plugin(eq), to: .down)
        check(m.action(.down) == .plugin(eq) && m.action(.upRight) == .none, "a plugin is bound ONCE: it moved down")
        m.assign(.plugin(verb), to: .down)
        check(m.action(.down) == .plugin(verb) && m.direction(of: .plugin(eq)) == nil,
              "a plugin put over another one replaces it (nobody else held the new one)")
        m.assign(.none, to: .up)
        check(m.action(.up) == .none && m.action(.right) == .branch, "none clears one direction, nothing else")
        m.swap(.right, .left)
        check(m.action(.left) == .branch && m.action(.right) == .none, "swap")
        m.unbind(verb)
        check(m.pluginRefs.isEmpty, "unbind")
        m.reset()
        check(m == def, "reset brings the defaults back")
        var g = def
        g.assign(.gain, to: .up)
        check(g.action(.up) == .gain && g.action(.right) == .gainStage, "gain and gain stage are two actions")

        // MARK: Plugin identity
        let eqShort = PlusPluginRef(format: "AudioUnit", identifier: "aufx,FQ4p,FabF", name: "renamed")
        check(eqShort == eq && eqShort.hashValue == eq.hashValue, "an AU is the same plugin with or without its type prefix")
        check(PlusPluginRef(format: "VST3", identifier: eq.identifier, name: "x") != eq, "the format is part of the identity")
        check(PlusPluginRef(format: "VST3", identifier: "a/b", name: "x").key == "VST3|a/b", "only an AU is normalised")

        // MARK: The stored form
        var s = def
        s.assign(.plugin(eq), to: .upRight)
        s.assign(.gainPanMute, to: .down)
        let data = try! JSONEncoder().encode(s)
        let back = try! JSONDecoder().decode(PlusShortcutMap.self, from: data)
        check(back == s && back.action(.upRight).pluginRef?.name == "Pro-Q 4"
              && back.action(.upRight).pluginRef?.manufacturer == "FabFilter", "round trip, the plugin's name kept")
        let json = String(data: data, encoding: .utf8)!
        check(json.contains("\"version\":1") && json.contains("\"upRight\""), "the stored form: version, directions by name")
        func decode(_ text: String) -> PlusShortcutMap? { try? JSONDecoder().decode(PlusShortcutMap.self, from: Data(text.utf8)) }
        let unknown = decode(#"{"version":2,"directions":{"right":{"kind":"warp"},"left":{"kind":"send"},"sideways":{"kind":"branch"}}}"#)
        check(unknown?.action(.right) == PlusAction.none && unknown?.action(.left) == .send,
              "an unknown kind → nothing; an unknown direction is ignored; the rest is read")
        let dup = decode(#"{"directions":{"left":{"kind":"send"},"up":{"kind":"send"}}}"#)
        check(dup?.action(.left) == .send && dup?.action(.up) == PlusAction.none,
              "a duplicated action: the first direction in order keeps it")
        let badPlugin = decode(#"{"directions":{"up":{"kind":"plugin","plugin":{"format":"VST3","identifier":"","name":"x","manufacturer":""}}}}"#)
        check(badPlugin?.action(.up) == PlusAction.none, "a plugin with no identifier → nothing")
        check(decode(#"{"version":1}"#)?.action(.right) == PlusAction.none, "no directions: everything asks for nothing")

        // MARK: The gesture under a moved map
        var u = def
        u.assign(.plugin(eq), to: .upRight)
        u.assign(.send, to: .up)
        u.assign(.gainStage, to: .down)
        check(G.classify(polar(60, 30), allowed: every, pluginAllowed: true, map: u) == .plugin(eq), "up-right: the plugin")
        check(G.classify(polar(60, 30), allowed: every, pluginAllowed: false, map: u) == .none,
              "a '+' that inserts no plugin: nothing")
        check(G.classify(polar(60, 90), allowed: every, map: u) == .send && G.classify(polar(60, 180), allowed: every, map: u) == .none,
              "the send moved up: left asks for nothing")
        check(G.classify(polar(60, -90), allowed: every, map: u) == .gain
              && G.classify(polar(100, -90), allowed: every, map: u) == .gainPanMute,
              "a gain stage down: the 80 pt cut along the vertical")
        check(G.classify(polar(85, -80), allowed: every, map: u) == .gainPanMute
              && G.classify(polar(79, -80), allowed: every, map: u) == .gain,
              "the cut is the travel ALONG the direction (85·cos 10° ≈ 83.7 > 80; 79 < 80)")
        check(G.classify(polar(60, 0), allowed: every, map: u) == .none, "right gave its gain stage away: nothing")

        // The zones = the classifier, for the moved map (every sampled point of a zone classifies to it).
        let zones = G.sectors(allowed: every, pluginAllowed: true, map: u)
        check(zones.map(\.direction) == [.downRight, .down, .down, .up, .upRight], "zones in the directions' order")
        check(zones.map(\.result) == [.branch, .gain, .gainPanMute, .send, .plugin(eq)], "one zone per action, two for the gain stage")
        for z in zones {
            for a in stride(from: z.fromAngle + 0.5, to: z.toAngle, by: 2) {
                let r0 = z.inner.distance(at: a), r1 = z.outer.distance(at: a)
                for f in [0.1, 0.5, 0.9] {
                    let t = PlusSector.offset(a, r0 + (r1 - r0) * f)
                    check(G.classify(t, allowed: every, pluginAllowed: true, map: u) == z.result,
                          "\(z.result) zone at \(a)°: classifies to its result")
                }
            }
        }
        let downGain = zones[1]
        check(downGain.outer == .across(G.panMuteThreshold, axis: -90), "the vertical gain stage's cut")
        check(abs(downGain.iconOffset.width) < 1e-6 && downGain.iconOffset.height > 0, "its icon sits below the '+'")
        check(G.highlightedIndex(polar(60, 30), in: zones, map: u) == 4, "the hand up-right lights the plugin's zone")
        check(G.highlightedIndex(polar(100, -90), in: zones, map: u) == 2, "far down lights gain · pan · mute")
        check(G.highlightedIndex(polar(60, 0), in: zones, map: u) == nil, "right lights nothing")
        // two directions with the same RESULT: only the one the hand is in lights up
        var two = def
        two.assign(.gain, to: .up)
        let tz = G.sectors(allowed: every, map: two)
        let iUp = G.highlightedIndex(polar(40, 90), in: tz, map: two)
        let iRight = G.highlightedIndex(polar(40, 0), in: tz, map: two)
        check(iUp != nil && iRight != nil && iUp != iRight && tz[iUp!].direction == .up && tz[iRight!].direction == .right,
              "a gain up and a gain right are two zones, lit one at a time")

        // MARK: The layout's commands
        let series = UUID()
        let trunk = SynopticLayout.InsertZone(seriesID: series, insertIndex: 2, branchElementID: nil,
                                              center: .zero, sendSlot: .chain(2))
        check(trunk.command(for: polar(60, 30), map: u) == .insertPlugin(.series(series, 2), eq), "trunk '+': insert the plugin there")
        check(trunk.command(for: polar(60, 90), map: u) == .send(.chain(2)), "trunk '+': the send, moved up")
        check(trunk.command(for: CGSize(width: 2, height: 1), map: u) == .openBrowser(.series(series, 2)), "a click: the browser")
        var bin = trunk; bin.role = .fxSeries
        check(bin.command(for: polar(60, -30), map: u) == .none, "a bin's '+' has no branch, moved or not")
        check(bin.command(for: polar(60, 30), map: u) == .insertPlugin(.series(series, 2), eq), "a bin's '+' inserts the plugin")
        let aux = UUID()
        let sendZone = SynopticLayout.InsertZone(seriesID: aux, insertIndex: 0, branchElementID: nil, center: .zero,
                                                 role: .sendChain)
        check(sendZone.command(for: polar(60, 30), map: u) == .insertPlugin(.sendChain(aux: aux, index: 0), eq),
              "a send's chain '+' inserts the plugin in the send")
        check(sendZone.command(for: polar(60, 90), map: u) == .none, "no send from a send, whatever the map")
        let post = SynopticLayout.PostFaderPlus(center: .zero, hoverRect: .zero)
        check(post.command(for: polar(60, 90), map: u) == .send(.postFader) && post.command(for: polar(60, 180), map: u) == .none,
              "the post-fader '+': its send follows the map")
        check(post.command(for: polar(60, 30), map: u) == .none, "the post-fader '+' inserts no plugin")
        check(post.command(for: CGSize(width: 1, height: 1), map: PlusShortcutMap()) == .send(.postFader),
              "the post-fader click stays the send, even with no direction holding it")

        // MARK: The presentation: a plugin not installed
        var a = SynopticPlusAvailability.all
        let key = SynopticPlusKey.series(series, 2)
        let raw = trunk.command(for: polar(60, 30), map: u)
        check(P.available(raw, a) == raw, "installed: carried out")
        check(P.ghost(raw: raw, a, translation: polar(60, 30)) == .plugin("Pro-Q 4"), "its ghost names it")
        a.missingPlugins = [eq]
        check(P.available(raw, a) == SynopticPlusCommand.none, "not installed: letting go does nothing")
        check(P.ghost(raw: raw, a, translation: polar(60, 30)) == .pluginMissing("Pro-Q 4"), "its ghost says it is missing")
        let zs = P.sectors(allowed: trunk.allowedGestures, key: key, a, translation: polar(60, 30), map: u)
        if let i = zs.sectors.firstIndex(where: { $0.result == .plugin(eq) }) {
            check(!zs.sectors[i].isAvailable && zs.highlighted == i, "its zone is drawn, unavailable, and lit under the hand")
        } else {
            check(false, "the missing plugin keeps its zone")
        }
        check(zs.sectors.filter { $0.result != .plugin(eq) }.allSatisfy(\.isAvailable), "the other zones stay available")
        var noInsert = SynopticPlusAvailability.all; noInsert.insertPlugin = false
        check(!P.sectors(allowed: trunk.allowedGestures, key: key, noInsert, translation: .zero, map: u).sectors
                .contains { $0.result == .plugin(eq) }, "nobody wired to insert: no plugin zone")
        check(P.available(raw, noInsert) == SynopticPlusCommand.none
              && P.ghost(raw: raw, noInsert, translation: polar(60, 30)) == .notHere, "…and the ghost says not here")
        var noSendInsert = SynopticPlusAvailability.all; noSendInsert.sendInsertPlugin = false
        let rawSend = sendZone.command(for: polar(60, 30), map: u)
        check(P.available(rawSend, noSendInsert) == SynopticPlusCommand.none, "a send's chain needs its own closure")

        // MARK: The tooltip's lines follow the map
        let help = P.helpEntries(allowed: trunk.allowedGestures, key: key, .all, map: u)
        check(help.map(\.direction) == [.downRight, .down, .up, .upRight], "one line per direction that does something")
        check(help.map(\.action) == [.branch, .gainStage, .send, .plugin(eq)], "…with its action")
        check(P.helpEntries(allowed: trunk.allowedGestures, key: key, .all).map(\.direction) == [.right, .downRight, .left],
              "the default map: right, down-right, left")
        check(P.helpEntries(allowed: SynopticLayout.sendChainGestures, key: .sendChain(aux: aux, index: 0), .all, map: u)
                .map(\.action) == [.gainStage, .plugin(eq)], "a send's chain: the gain stage and the plugin only")

        print(failures == 0 ? "ALL PASS (\(total) assertions)" : "\(failures) FAILED of \(total)")
        exit(failures == 0 ? 0 : 1)
    }
}

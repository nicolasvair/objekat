import Foundation

// Standalone test of the user-customisable directions of the signal view's "+" (PlusShortcutMap and what the
// gesture, the layout and the presentation do with a NON-default map): the eight fixed directions and their
// boundaries, the two LEVELS of each (near, far from 80 pt along the direction), the defaults (which must
// classify exactly as the historical "+" did), the swap rule per slot, an empty far slot doing what the near
// one does, the stored form (v2 round trip, unknown kinds, duplicates, and the MIGRATION of a v1 map), the
// plugin identity, and a few maps moved around — a plugin on up-right, a send moved up, gain and gain · pan ·
// mute down, a plugin on a far slot alone, a plugin no longer installed.
//
//     swiftc -parse-as-library -o /tmp/t_plus_sc \
//         ../objekat/Inspector/Synoptic/SynopticGraph.swift \
//         ../objekat/Inspector/Synoptic/SynopticPlusShortcuts.swift \
//         ../objekat/Inspector/Synoptic/SynopticPlusGesture.swift \
//         ../objekat/Inspector/Synoptic/SynopticLayout.swift \
//         ../objekat/Inspector/Synoptic/SynopticPlusPresentation.swift ../objekat/Shared/FeatureIcons.swift test_synoptic_plus_shortcuts.swift \
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

func S(_ d: PlusDirection, _ l: PlusLevel = .near) -> PlusSlot { PlusSlot(d, l) }

/// The "+" as it was before any map existed, written out by hand (the reference the default map must match
/// to the bit): right (|θ| < 15°, open) = a gain stage, gain · pan · mute from 80 pt of HORIZONTAL travel;
/// down-right (−45°…−15°, closed) = a branch; left (|θ| > 165°, open) = a send; anything else nothing.
func legacy(_ t: CGSize, allowed: Set<PlusGestureResult>) -> PlusGestureResult {
    guard hypot(t.width, t.height) >= G.clickThreshold else { return .none }
    let deg = atan2(Double(-t.height), Double(t.width)) * 180 / .pi
    let r: PlusGestureResult
    if abs(deg) < 15 { r = t.width < 80 ? .gain : .gainPanMute }
    else if deg >= -45 && deg <= -15 { r = .branch }
    else if abs(deg) > 165 { r = .send }
    else { r = .none }
    return allowed.contains(r) ? r : .none
}

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

        // MARK: The slots and the levels
        check(PlusSlot.allCases.count == 16, "sixteen slots")
        check(Array(PlusSlot.allCases.prefix(4)) == [S(.right), S(.right, .far), S(.downRight), S(.downRight, .far)],
              "slots in the directions' order, near before far")
        check(G.level(CGSize(width: 79.9, height: 0), along: .right) == .near
              && G.level(CGSize(width: 80, height: 0), along: .right) == .far, "the right direction's cut at 80 pt, exactly")
        check(G.level(CGSize(width: 79.9, height: -40), along: .right) == .near,
              "the right cut is the HORIZONTAL travel (the historical vertical line)")
        check(G.level(polar(85, -80), along: .down) == .far && G.level(polar(79, -80), along: .down) == .near,
              "the cut is the travel ALONG the direction (85·cos 10° ≈ 83.7 > 80; 79 < 80)")
        for d in PlusDirection.allCases {
            check(G.level(polar(79.9, d.angle), along: d) == .near && G.level(polar(80.1, d.angle), along: d) == .far,
                  "\(d): near under 80 pt along its axis, far from there")
        }

        // MARK: The defaults
        let def = PlusShortcutMap.defaults
        check(def.action(S(.right)) == .gain && def.action(S(.right, .far)) == .gainPanMute,
              "defaults: right gain, further gain · pan · mute")
        check(def.action(S(.downRight)) == .branch && def.action(S(.left)) == .send, "defaults: down-right branch, left send")
        check(def.action(S(.downRight, .far)) == PlusAction.none && def.action(S(.left, .far)) == PlusAction.none,
              "defaults: the branch and the send have an empty far slot")
        check([PlusDirection.down, .downLeft, .upLeft, .up, .upRight].allSatisfy {
            def.action(S($0)) == .none && def.action(S($0, .far)) == .none }, "defaults: the five other directions ask for nothing")
        check(def.isDefault && PlusShortcutMap().action(S(.right)) == .none, "an empty map is not the default")
        check(def.pluginRefs.isEmpty, "no plugin by default")
        // The default map classifies EXACTLY as the historical "+" did (written out by hand above), over the
        // whole circle and from the click threshold to beyond the zones, for every subset a "+" offers.
        let every = G.everything
        var swept = 0
        for allowed in [every, SynopticLayout.sendChainGestures, SynopticLayout.postFaderGestures, [.gain, .branch]] {
            for r in [3.0, 6, 10, 30, 50, 70, 79, 79.99, 80, 80.01, 81, 100, 130, 150, 300] {
                for deg in stride(from: -180.0, to: 180, by: 0.5) {
                    let t = polar(r, deg)
                    swept += 1
                    check(G.classify(t, allowed: allowed, map: def) == legacy(t, allowed: allowed),
                          "defaults = the historical classifier at \(deg)°, \(r) pt, \(allowed)")
                }
            }
            // Exactly on the cut and on the boundaries.
            for t in [CGSize(width: 80, height: 0), CGSize(width: 80, height: -21.4), CGSize(width: 79.999, height: 21),
                      polar(100, 15), polar(100, -15), polar(100, -45), polar(100, 165), polar(100, -165)] {
                check(G.classify(t, allowed: allowed, map: def) == legacy(t, allowed: allowed), "edge \(t), \(allowed)")
            }
        }
        check(swept > 40000, "the sweep covered the circle")

        // MARK: An empty far slot does what the near one does
        check(def.effective(.downRight, .far) == S(.downRight) && def.effective(.right, .far) == S(.right, .far),
              "effective: an empty far slot falls back on the near one")
        check(G.classify(polar(150, -30), allowed: every, map: def) == .branch
              && G.classify(polar(150, 180), allowed: every, map: def) == .send, "a branch or a send at any distance")

        // MARK: assign = a swap, per slot
        var m = def
        m.assign(.gainPanMute, to: S(.right))
        check(m.action(S(.right)) == .gainPanMute && m.action(S(.right, .far)) == .gain, "near ↔ far of one direction swapped")
        m.assign(.send, to: S(.up, .far))
        check(m.action(S(.up, .far)) == .send && m.action(S(.left)) == .none, "the send moved to up-far; left took its nothing")
        m.assign(.branch, to: S(.right, .far))
        check(m.action(S(.right, .far)) == .branch && m.action(S(.downRight)) == .gain, "branch ↔ gain, across directions and levels")
        m.assign(.plugin(eq), to: S(.upRight))
        check(m.action(S(.upRight)) == .plugin(eq) && m.pluginRefs == [eq], "a plugin on up-right")
        m.assign(.plugin(eq), to: S(.down, .far))
        check(m.action(S(.down, .far)) == .plugin(eq) && m.action(S(.upRight)) == .none, "a plugin is bound ONCE: it moved down-far")
        m.assign(.plugin(verb), to: S(.down, .far))
        check(m.action(S(.down, .far)) == .plugin(verb) && m.slot(of: .plugin(eq)) == nil,
              "a plugin put over another one replaces it (nobody else held the new one)")
        check(m.slot(of: .plugin(verb)) == S(.down, .far) && m.slot(of: PlusAction.none) == nil, "slot(of:)")
        m.clear(S(.up, .far))
        check(m.action(S(.up, .far)) == .none && m.action(S(.right, .far)) == .branch, "clear empties one slot, nothing else")
        m.swap(S(.right), S(.left, .far))
        check(m.action(S(.left, .far)) == .gainPanMute && m.action(S(.right)) == .none, "swap of two slots")
        m.unbind(verb)
        check(m.pluginRefs.isEmpty, "unbind")
        m.reset()
        check(m == def, "reset brings the defaults back")

        // MARK: Plugin identity
        let eqShort = PlusPluginRef(format: "AudioUnit", identifier: "aufx,FQ4p,FabF", name: "renamed")
        check(eqShort == eq && eqShort.hashValue == eq.hashValue, "an AU is the same plugin with or without its type prefix")
        check(PlusPluginRef(format: "VST3", identifier: eq.identifier, name: "x") != eq, "the format is part of the identity")
        check(PlusPluginRef(format: "VST3", identifier: "a/b", name: "x").key == "VST3|a/b", "only an AU is normalised")

        // MARK: The stored form, v2
        func decode(_ text: String) -> PlusShortcutMap? { try? JSONDecoder().decode(PlusShortcutMap.self, from: Data(text.utf8)) }
        var s = def
        s.assign(.plugin(eq), to: S(.upRight, .far))
        s.assign(.branch, to: S(.down))
        let data = try! JSONEncoder().encode(s)
        let back = try! JSONDecoder().decode(PlusShortcutMap.self, from: data)
        check(back == s && back.action(S(.upRight, .far)).pluginRef?.name == "Pro-Q 4"
              && back.action(S(.upRight, .far)).pluginRef?.manufacturer == "FabFilter", "round trip, the plugin's name kept")
        let json = String(data: data, encoding: .utf8)!
        check(json.contains("\"version\":2") && json.contains("\"slots\"") && json.contains("\"far\"")
              && !json.contains("\"directions\""), "the stored form: version 2, slots by direction and level")
        check(try! JSONDecoder().decode(PlusShortcutMap.self, from: JSONEncoder().encode(def)) == def, "the defaults round-trip")
        let unknown = decode(#"{"version":2,"slots":{"right":{"near":{"kind":"warp"},"middle":{"kind":"send"}},"left":{"far":{"kind":"send"}},"sideways":{"near":{"kind":"branch"}}}}"#)
        check(unknown?.action(S(.right)) == PlusAction.none && unknown?.action(S(.left, .far)) == .send
              && unknown?.action(S(.left)) == PlusAction.none && unknown?.slot(of: .branch) == nil,
              "v2: an unknown kind → nothing; an unknown level or direction is ignored; the rest is read")
        let dup = decode(#"{"version":2,"slots":{"left":{"far":{"kind":"send"}},"right":{"near":{"kind":"send"}}}}"#)
        check(dup?.action(S(.right)) == .send && dup?.action(S(.left, .far)) == PlusAction.none,
              "v2: a duplicated action — the first slot in order keeps it")
        let badPlugin = decode(#"{"version":2,"slots":{"up":{"near":{"kind":"plugin","plugin":{"format":"VST3","identifier":"","name":"x","manufacturer":""}}}}}"#)
        check(badPlugin?.action(S(.up)) == PlusAction.none, "a plugin with no identifier → nothing")
        check(decode(#"{"version":2}"#) == PlusShortcutMap(), "no slots: everything asks for nothing")
        check(decode(#"{"version":2,"slots":{"up":{"near":{"kind":"gainStage"}}}}"#)?.action(S(.up)) == PlusAction.none,
              "v2 has no gainStage kind: nothing")

        // MARK: The stored form, v1 → v2 migration (an existing user map is kept)
        // What version 1 wrote for the defaults: every direction, a "gainStage" on the right.
        let v1Defaults = #"{"version":1,"directions":{"right":{"kind":"gainStage"},"downRight":{"kind":"branch"},"down":{"kind":"none"},"downLeft":{"kind":"none"},"left":{"kind":"send"},"upLeft":{"kind":"none"},"up":{"kind":"none"},"upRight":{"kind":"none"}}}"#
        check(decode(v1Defaults) == def, "v1 defaults → the v2 defaults")
        let v1User = decode(#"{"version":1,"directions":{"right":{"kind":"none"},"down":{"kind":"gainStage"},"left":{"kind":"branch"},"up":{"kind":"send"},"upRight":{"kind":"plugin","plugin":{"format":"AudioUnit","identifier":"aufx,FQ4p,FabF","name":"Pro-Q 4","manufacturer":"FabFilter"}}}}"#)
        check(v1User?.action(S(.down)) == .gain && v1User?.action(S(.down, .far)) == .gainPanMute,
              "v1 gainStage → near gain, far gain · pan · mute (on the direction it was on)")
        check(v1User?.action(S(.left)) == .branch && v1User?.action(S(.left, .far)) == PlusAction.none
              && v1User?.action(S(.up)) == .send && v1User?.action(S(.upRight)) == .plugin(eq),
              "v1 other actions → the near slot, far empty (the same action at any distance, as v1 did)")
        check(v1User?.action(S(.right)) == PlusAction.none && v1User?.action(S(.right, .far)) == PlusAction.none,
              "v1 nothing on the right → both right slots empty")
        // Order matters only for a collision: down-right (before down) asked for gain · pan · mute, which the
        // gain stage on down ALSO yields after migration; the first slot in order keeps it.
        let v1Collide = decode(#"{"version":1,"directions":{"downRight":{"kind":"gainPanMute"},"down":{"kind":"gainStage"}}}"#)
        check(v1Collide?.action(S(.downRight)) == .gainPanMute && v1Collide?.action(S(.down)) == .gain
              && v1Collide?.action(S(.down, .far)) == PlusAction.none,
              "v1 collision: gain · pan · mute stays on the first direction in order, the stage keeps its gain")
        let v1Unknown = decode(#"{"directions":{"right":{"kind":"warp"},"left":{"kind":"send"},"sideways":{"kind":"branch"}}}"#)
        check(v1Unknown?.action(S(.right)) == PlusAction.none && v1Unknown?.action(S(.left)) == .send
              && v1Unknown?.slot(of: .branch) == nil, "v1: unknown kind → nothing, unknown direction ignored")
        let mixed = decode(#"{"version":2,"slots":{"up":{"near":{"kind":"send"}}},"directions":{"left":{"kind":"branch"}}}"#)
        check(mixed?.action(S(.up)) == .send && mixed?.slot(of: .branch) == nil, "slots present: the v1 key is not read")
        // A v1 map read then written is v2 from then on.
        let rewritten = String(data: try! JSONEncoder().encode(decode(v1Defaults)!), encoding: .utf8)!
        check(rewritten.contains("\"version\":2") && !rewritten.contains("gainStage"), "a migrated map is written as v2")

        // MARK: The gesture under a moved map
        var u = def
        u.assign(.plugin(eq), to: S(.upRight))           // a plugin on up-right
        u.assign(.send, to: S(.up))                       // the send moved up (left near takes up's nothing)
        u.assign(.gain, to: S(.down))                     // gain moved down (right near takes down's nothing)
        u.assign(.gainPanMute, to: S(.down, .far))        // and its far partner (right far takes nothing)
        u.assign(.plugin(verb), to: S(.left, .far))       // a plugin on a far slot ALONE
        check(G.classify(polar(60, 30), allowed: every, pluginAllowed: true, map: u) == .plugin(eq), "up-right: the plugin")
        check(G.classify(polar(150, 30), allowed: every, pluginAllowed: true, map: u) == .plugin(eq), "…at any distance")
        check(G.classify(polar(60, 30), allowed: every, pluginAllowed: false, map: u) == .none,
              "a '+' that inserts no plugin: nothing")
        check(G.classify(polar(60, 90), allowed: every, map: u) == .send, "the send moved up")
        check(G.classify(polar(60, -90), allowed: every, map: u) == .gain
              && G.classify(polar(100, -90), allowed: every, map: u) == .gainPanMute, "down: near gain, far gain · pan · mute")
        check(G.classify(polar(85, -80), allowed: every, map: u) == .gainPanMute
              && G.classify(polar(79, -80), allowed: every, map: u) == .gain, "the cut ALONG the vertical")
        check(G.classify(polar(60, 0), allowed: every, map: u) == .none
              && G.classify(polar(120, 0), allowed: every, map: u) == .none, "right gave both slots away: nothing")
        check(G.classify(polar(60, 180), allowed: every, pluginAllowed: true, map: u) == .none
              && G.classify(polar(100, 180), allowed: every, pluginAllowed: true, map: u) == .plugin(verb),
              "left: an empty near slot does nothing, the far one inserts its plugin")
        check(G.classify(polar(100, 180), allowed: every, pluginAllowed: false, map: u) == .none,
              "a far slot not offered here: nothing (the near slot does not take over)")

        // The zones = the classifier, for the moved map (every sampled point of a zone classifies to it).
        let zones = G.sectors(allowed: every, pluginAllowed: true, map: u)
        check(zones.map(\.direction) == [.downRight, .down, .down, .left, .up, .upRight], "zones in the directions' order")
        check(zones.map(\.level) == [.near, .near, .far, .far, .near, .near], "near before far; an empty far = one zone")
        check(zones.map(\.result) == [.branch, .gain, .gainPanMute, .plugin(verb), .send, .plugin(eq)], "the zones' results")
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
        check(zones[0].inner == .radius(G.sectorInnerRadius) && zones[0].outer == .radius(G.sectorOuterRadius),
              "an empty far slot: ONE zone, disc to end")
        check(zones[1].outer == .across(G.panMuteThreshold, axis: -90) && zones[2].inner == .across(G.panMuteThreshold, axis: -90),
              "two zones split by the line across the direction at 80 pt")
        check(zones[3].inner == .across(G.panMuteThreshold, axis: 180), "a far slot alone: its zone starts at the cut")
        check(abs(zones[1].iconOffset.width) < 1e-6 && zones[1].iconOffset.height > 0, "the down zone's icon sits below the '+'")
        check(G.highlightedIndex(polar(60, 30), in: zones, map: u) == 5, "the hand up-right lights the plugin's zone")
        check(G.highlightedIndex(polar(60, -90), in: zones, map: u) == 1, "near down lights gain")
        check(G.highlightedIndex(polar(100, -90), in: zones, map: u) == 2, "far down lights gain · pan · mute")
        check(G.highlightedIndex(polar(100, 180), in: zones, map: u) == 3, "far left lights the far plugin")
        check(G.highlightedIndex(polar(40, 180), in: zones, map: u) == nil, "near left lights nothing")
        check(G.highlightedIndex(polar(60, 0), in: zones, map: u) == nil, "right lights nothing")
        check(G.highlightedIndex(polar(150, -30), in: zones, map: u) == 0, "far down-right lights the one branch zone")
        // the default map's zones: as the "+" always drew them
        let dz = G.sectors(allowed: every, map: def)
        check(dz.map(\.result) == [.gain, .gainPanMute, .branch, .send] && dz[0].outer == .across(G.panMuteThreshold, axis: 0),
              "default zones: gain | gain · pan · mute split at the vertical 80 pt line, branch, send")
        // a far zone not offered here: the near zone stays, nothing beyond
        let sz = G.sectors(allowed: every, pluginAllowed: false, map: u)
        check(!sz.contains { $0.direction == .left }, "a plugin-only far slot on a '+' that inserts none: no zone")
        // two slots with the same RESULT kind in two directions: only the one the hand is in lights up
        var two = def
        two.assign(.plugin(eq), to: S(.up))
        two.assign(.plugin(verb), to: S(.right, .far))
        let tz = G.sectors(allowed: every, pluginAllowed: true, map: two)
        let iUp = G.highlightedIndex(polar(40, 90), in: tz, map: two)
        let iRightFar = G.highlightedIndex(polar(100, 0), in: tz, map: two)
        check(iUp != nil && iRightFar != nil && iUp != iRightFar && tz[iUp!].direction == .up
              && tz[iRightFar!].direction == .right && tz[iRightFar!].level == .far, "two plugin zones, lit one at a time")
        check(two.action(S(.up, .far)) == .none, "the far of up stayed empty")

        // MARK: The layout's commands
        let series = UUID()
        let trunk = SynopticLayout.InsertZone(seriesID: series, insertIndex: 2, branchElementID: nil,
                                              center: .zero, sendSlot: .chain(2))
        check(trunk.command(for: polar(60, 30), map: u) == .insertPlugin(.series(series, 2), eq), "trunk '+': insert the plugin there")
        check(trunk.command(for: polar(100, 180), map: u) == .insertPlugin(.series(series, 2), verb), "trunk '+': the far plugin")
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
              "the post-fader click stays the send, even with no slot holding it")
        var farSend = def
        farSend.assign(.send, to: S(.up, .far))
        check(post.command(for: polar(60, 90), map: farSend) == .none && post.command(for: polar(100, 90), map: farSend) == .send(.postFader),
              "a send on a far slot: only from 80 pt")

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
                .contains { if case .plugin = $0.result { return true } else { return false } }, "nobody wired to insert: no plugin zone")
        check(P.available(raw, noInsert) == SynopticPlusCommand.none
              && P.ghost(raw: raw, noInsert, translation: polar(60, 30)) == .notHere, "…and the ghost says not here")
        var noSendInsert = SynopticPlusAvailability.all; noSendInsert.sendInsertPlugin = false
        let rawSend = sendZone.command(for: polar(60, 30), map: u)
        check(P.available(rawSend, noSendInsert) == SynopticPlusCommand.none, "a send's chain needs its own closure")

        // MARK: The tooltip's lines follow the map, one per slot
        let help = P.helpEntries(allowed: trunk.allowedGestures, key: key, .all, map: u)
        check(help.map(\.slot) == [S(.downRight), S(.down), S(.down, .far), S(.left, .far), S(.up), S(.upRight)],
              "one entry per slot that does something")
        check(help.map(\.action) == [.branch, .gain, .gainPanMute, .plugin(verb), .send, .plugin(eq)], "…with its action")
        check(P.helpEntries(allowed: trunk.allowedGestures, key: key, .all).map(\.slot)
                == [S(.right), S(.right, .far), S(.downRight), S(.left)], "the default map: right near and far, down-right, left")
        check(P.helpEntries(allowed: SynopticLayout.sendChainGestures, key: .sendChain(aux: aux, index: 0), .all, map: u)
                .map(\.action) == [.gain, .gainPanMute, .plugin(verb), .plugin(eq)], "a send's chain: the gain stages and the plugins only")

        print(failures == 0 ? "ALL PASS (\(total) assertions)" : "\(failures) FAILED of \(total)")
        exit(failures == 0 ? 0 : 1)
    }
}

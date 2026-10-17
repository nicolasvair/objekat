import Foundation

// Standalone test of the "+" gesture classifier of the signal view (docs/plan_synoptic_rework.md §B.2, the
// user's decisions of 12, 13 and 17 October 2026): under 6 pt a click; eight EQUAL sectors of 45° tiling the
// circle; right = a gain, beyond the 80 pt CIRCLE gain + pan + mute; −45° (down-right) = a parallel branch;
// LEFT (180°) = a send; the five other directions = nothing (default map); a result the "+" does not offer =
// nothing; a category = offered with the plugins.
//
//     swiftc -parse-as-library -o /tmp/t_plus \
//         ../objekat/Inspector/Synoptic/SynopticPlusShortcuts.swift \
//         ../objekat/Inspector/Synoptic/SynopticPlusGesture.swift test_synoptic_plus_gesture.swift \
//         && /tmp/t_plus

var failures = 0
var total = 0
func check(_ ok: Bool, _ what: String) {
    total += 1
    if !ok { failures += 1; print("FAIL: \(what)") }
}

/// A translation of length `r` at `deg` degrees from the horizontal, POSITIVE UPWARD (the screen's y grows
/// downward, hence the minus).
func polar(_ r: Double, _ deg: Double) -> CGSize {
    let a = deg * .pi / 180
    return CGSize(width: r * cos(a), height: -r * sin(a))
}

@main
struct Main {
    static func main() {
        typealias G = SynopticPlusGesture
        let every = G.everything

        // The constants are the user's.
        check(G.clickThreshold == 6 && G.panMuteThreshold == 80, "thresholds 6 pt / 80 pt")
        check(G.angleTolerance == 22.5, "eight sectors of 45°")
        check(every == [.gain, .gainPanMute, .branch, .send], "the trunk offers everything")

        // A click.
        for t in [CGSize(width: 0, height: 0), CGSize(width: 5.9, height: 0), CGSize(width: 0, height: -5.9), CGSize(width: 4, height: 4)] {
            check(G.isClick(t) && G.classify(t, allowed: every) == .none, "\(t) is a click")
            check(G.rawSlot(t) == nil && G.direction(t) == nil, "\(t): no direction, no slot")
        }
        check(!G.isClick(CGSize(width: 6, height: 0)), "6 pt is no longer a click")
        check(G.classify(CGSize(width: 6, height: 0), allowed: every) == .gain, "6 pt right: a gain")

        // The angle is positive UPWARD.
        check(abs(G.angle(CGSize(width: 10, height: -10)) - 45) < 1e-9, "up-right is +45°")
        check(abs(G.angle(CGSize(width: 10, height: 10)) + 45) < 1e-9, "down-right is −45°")

        // No dead angle: every direction of a drag names a direction, and the eight sectors are 45° each.
        var counts: [PlusDirection: Int] = [:]
        for i in 0..<3600 {
            let deg = -180 + Double(i) * 0.1
            if let d = G.direction(polar(60, deg)) { counts[d, default: 0] += 1 }
            else { check(false, "\(deg)°: no direction") }
        }
        check(counts.count == 8 && counts.values.allSatisfy { $0 == 450 }, "eight equal sectors: \(counts)")
        let axes: [(PlusDirection, Double)] = [(.right, 0), (.upRight, 45), (.up, 90), (.upLeft, 135), (.left, 180),
                                               (.downLeft, -135), (.down, -90), (.downRight, -45)]
        for (d, a) in axes {
            check(d.angle == a, "\(d) points at \(a)°")
            for off in [-22.4, -10, 0, 10, 22.4] {
                check(G.direction(polar(60, a + off)) == d, "\(a + off)°: \(d)")
            }
        }

        // The level is the DISTANCE (the 80 pt circle), in every direction.
        check(G.classify(CGSize(width: 79.9, height: 0), allowed: every) == .gain, "79.9 pt: gain")
        check(G.classify(CGSize(width: 80, height: 0), allowed: every) == .gainPanMute, "80 pt: gain + pan + mute")
        check(G.classify(polar(79.9, 20), allowed: every) == .gain, "79.9 pt at 20°: still near")
        check(G.classify(polar(80.1, 20), allowed: every) == .gainPanMute, "80.1 pt at 20°: far (a circle, not a line)")
        check(G.classify(polar(80.1, -20), allowed: every) == .gainPanMute, "80.1 pt at −20°: far")
        for (d, _) in axes {
            check(G.level(polar(79.9, d.angle + 15)) == .near && G.level(polar(80.01, d.angle - 15)) == .far, "\(d): the 80 pt circle")
        }

        // Default map: the branch round −45°, the send round 180°, nothing elsewhere.
        for deg in [-22.6, -30, -45, -60, -67.4] {
            check(G.classify(polar(60, deg), allowed: every) == .branch, "\(deg)°: a branch")
            check(G.classify(polar(200, deg), allowed: every) == .branch, "\(deg)°, far: still a branch (far empty)")
        }
        for deg in [157.5, 170, 180, -180, -170, -157.6] {
            check(G.classify(polar(60, deg), allowed: every) == .send, "\(deg)°: a send (left)")
        }
        check(G.classify(CGSize(width: -6, height: 0), allowed: every) == .send, "6 pt left: a send (the click threshold)")
        check(G.classify(CGSize(width: -5.9, height: 0), allowed: every) == .none, "5.9 pt left: a click")
        for deg in [22.5, 45, 67, 90, 135, -90, -135, -112.5] {
            check(G.classify(polar(60, deg), allowed: every) == .none, "\(deg)°: nothing")
        }

        // `allowed`: a result the "+" does not offer is nothing (the ghost says "not here").
        let gainsOnly: Set<PlusGestureResult> = [.gain, .gainPanMute]
        let sendOnly: Set<PlusGestureResult> = [.send]
        check(G.classify(polar(60, -45), allowed: gainsOnly) == .none, "a bin / a send's chain: no branch")
        check(G.classify(polar(60, 180), allowed: gainsOnly) == .none, "a bin / a send's chain: no send")
        check(G.classify(CGSize(width: 40, height: 0), allowed: gainsOnly) == .gain, "a bin: a gain")
        check(G.classify(CGSize(width: 40, height: 0), allowed: sendOnly) == .none, "mixer -> stems: no gain")
        check(G.classify(polar(60, 180), allowed: sendOnly) == .send, "mixer -> stems: the send, to the left")
        check(G.intent(polar(60, -45)) == .branch && G.intent(polar(60, 180)) == .send, "intent is the raw direction")

        // An empty NEAR slot with a far one: nothing short of the circle, the far action beyond it.
        var m = PlusShortcutMap()
        m.assign(.branch, to: PlusSlot(.up, .far))
        check(G.classify(polar(60, 90), allowed: every, map: m) == .none, "near empty, under 80 pt: nothing")
        check(G.classify(polar(90, 90), allowed: every, map: m) == .branch, "near empty, beyond 80 pt: the far action")
        // A category rides with the plugins.
        m.assign(.category(3), to: PlusSlot(.down, .near))
        check(G.classify(polar(60, -90), allowed: every, pluginAllowed: true, map: m) == .category(3), "a category, plugins offered")
        check(G.classify(polar(60, -90), allowed: every, pluginAllowed: false, map: m) == .none, "a category, plugins not offered")

        // rawSlot ignores the map: what a drop on the browser's page aims at.
        check(G.rawSlot(polar(50, 90)) == PlusSlot(.up, .near) && G.rawSlot(polar(100, -135)) == PlusSlot(.downLeft, .far),
              "rawSlot = direction + distance")

        // MARK: the zones drawn round a dragged "+" ARE the classifier
        let zones = G.sectors(allowed: every)
        check(zones.map(\.result) == [.gain, .gainPanMute, .branch, .send], "the trunk draws four zones, in order")
        check(G.sectors(allowed: [.gain, .gainPanMute]).map(\.result) == [.gain, .gainPanMute], "a send's chain: the two gain zones only")
        check(G.sectors(allowed: [.send]).map(\.result) == [.send], "mixer -> stems: the send zone only")
        check(G.sectors(allowed: []).isEmpty, "nothing offered: no zone")
        var sampled = 0
        func sample(_ zs: [PlusSector], map: PlusShortcutMap, plugins: Bool) {
            for z in zs {
                check(z.fromAngle < z.toAngle && abs(z.toAngle - z.fromAngle - 45) < 1e-9, "\(z.result): 45° wide")
                for ai in 0...20 {
                    let deg = z.fromAngle + 0.5 + (z.toAngle - z.fromAngle - 1) * Double(ai) / 20
                    let rIn = z.inner.distance(at: deg) + 0.5, rOut = z.outer.distance(at: deg) - 0.5
                    for ri in 0...10 {
                        let r = rIn + (rOut - rIn) * CGFloat(ri) / 10
                        let t = PlusSector.offset(deg, r)
                        sampled += 1
                        let c = G.classify(t, allowed: every, pluginAllowed: plugins, map: map)
                        if c != z.result { check(false, "\(z.result): the point \(t) inside the zone classifies to \(c)") }
                        if G.highlighted(t, in: zs, map: map) != z.result { check(false, "\(z.result): the point \(t) lights up its zone") }
                    }
                }
                check(G.classify(z.iconOffset, allowed: every, pluginAllowed: plugins, map: map) == z.result, "\(z.result): its icon sits in its zone")
                let o = z.outline(steps: 8)
                check(o.count == 16, "\(z.result): the outline = inner + outer boundaries")
                check(o.allSatisfy { hypot($0.width, $0.height) >= G.sectorInnerRadius - 1e-6
                                     && hypot($0.width, $0.height) <= G.sectorOuterRadius + 1e-6 }, "\(z.result): within the ring")
            }
        }
        sample(zones, map: .defaults, plugins: false)
        sample(G.sectors(allowed: every, pluginAllowed: true, map: m), map: m, plugins: true)
        // the gain / gain+pan+mute cut is the 80 pt circle
        check(zones[0].outer == .radius(G.panMuteThreshold) && zones[1].inner == .radius(G.panMuteThreshold), "the cut is the 80 pt circle")
        check(zones[2].iconOffset.width > 0 && zones[2].iconOffset.height > 0, "the branch icon: down-right")
        check(zones[3].iconOffset.width < 0 && abs(zones[3].iconOffset.height) < 1e-6, "the send icon: left")
        check(G.highlighted(CGSize(width: 3, height: 0), in: zones) == nil, "a click lights nothing")
        check(G.highlighted(polar(60, 45), in: zones) == nil, "up-right lights nothing")
        check(G.highlighted(CGSize(width: 100, height: 0), in: zones) == .gainPanMute, "past 80 pt: the gain + pan + mute zone")

        // The page's sixteen zones: every slot, each holding exactly the points rawSlot names it for.
        let all = G.slotSectors(map: .defaults)
        check(all.count == 16, "sixteen zones")
        check(zip(all, PlusSlot.allCases).allSatisfy { $0.direction == $1.direction && $0.level == $1.level }, "in slot order")
        check(all.filter { $0.result != .none }.count == 4, "four of them hold something by default")
        for z in all {
            for ai in 0...10 {
                let deg = z.fromAngle + 0.5 + (z.toAngle - z.fromAngle - 1) * Double(ai) / 10
                for r in [z.inner.distance(at: deg) + 0.5, z.outer.distance(at: deg) - 0.5] {
                    sampled += 1
                    if G.rawSlot(PlusSector.offset(deg, r)) != PlusSlot(z.direction, z.level) {
                        check(false, "page zone \(z.direction)/\(z.level) @\(deg)° r\(r)")
                    }
                }
            }
        }
        print("  zones: \(sampled) points sampled")

        print(failures == 0 ? "ALL PASS (\(total) assertions)" : "failures: \(failures) of \(total)")
        exit(failures == 0 ? 0 : 1)
    }
}

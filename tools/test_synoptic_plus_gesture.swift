import Foundation

// Standalone test of the "+" gesture classifier of the signal view (docs/plan_synoptic_rework.md §B.2, the
// user's decisions of 12 and 13 October 2026): under 6 pt a click; right = a gain, past 80 pt gain + pan +
// mute; −30° (down-right) = a parallel branch; LEFT (180°) = a send; ±15° round each direction; up-right,
// too steep, or anything else = nothing; a result the "+" does not offer = nothing.
//
//     swiftc -parse-as-library -o /tmp/t_plus \
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
        check(G.diagonalAngle == 30 && G.angleTolerance == 15, "±30°, ±15° of tolerance")
        check(every == [.gain, .gainPanMute, .branch, .send], "the trunk offers everything")

        // A click.
        for t in [CGSize(width: 0, height: 0), CGSize(width: 5.9, height: 0), CGSize(width: 0, height: -5.9), CGSize(width: 4, height: 4)] {
            check(G.isClick(t) && G.classify(t, allowed: every) == .none, "\(t) is a click")
        }
        check(!G.isClick(CGSize(width: 6, height: 0)), "6 pt is no longer a click")
        check(G.classify(CGSize(width: 6, height: 0), allowed: every) == .gain, "6 pt right: a gain")

        // The angle is positive UPWARD.
        check(abs(G.angle(CGSize(width: 10, height: -10)) - 45) < 1e-9, "up-right is +45°")
        check(abs(G.angle(CGSize(width: 10, height: 10)) + 45) < 1e-9, "down-right is −45°")

        // Right: gain, then gain + pan + mute from 80 pt of HORIZONTAL travel.
        check(G.classify(CGSize(width: 40, height: 0), allowed: every) == .gain, "40 pt right: gain")
        check(G.classify(CGSize(width: 79.9, height: 0), allowed: every) == .gain, "79.9 pt: gain")
        check(G.classify(CGSize(width: 80, height: 0), allowed: every) == .gainPanMute, "80 pt: gain + pan + mute")
        check(G.classify(CGSize(width: 200, height: 10), allowed: every) == .gainPanMute, "200 pt, slightly down: gain + pan + mute")
        check(G.classify(polar(50, 14.9), allowed: every) == .gain, "+14.9°: still a gain")
        check(G.classify(polar(50, -14.9), allowed: every) == .gain, "−14.9°: still a gain")

        // The branch, ±15° round −30°; the send, ±15° round 180° (LEFT).
        check(G.sendAngle == 180, "the send points left")
        for deg in [15.01, 17.5, 20, 25, 30, 35, 40, 44.99] {
            check(G.classify(polar(60, -deg), allowed: every) == .branch, "−\(deg)°: a branch")
            check(G.classify(polar(60, deg), allowed: every) == .none, "+\(deg)° (up-right): nothing any more")
        }
        check(G.classify(polar(60, -30), allowed: every) == .branch, "−30° exactly: a branch")
        for deg in [165.01, 170.0, 175, 180, -180, -175, -170, -165.01] {
            check(G.classify(polar(60, deg), allowed: every) == .send, "\(deg)°: a send (left)")
        }
        check(G.classify(CGSize(width: -60, height: 0), allowed: every) == .send, "straight left: a send")
        check(G.classify(CGSize(width: -6, height: 0), allowed: every) == .send, "6 pt left: a send (the click threshold)")
        check(G.classify(CGSize(width: -5.9, height: 0), allowed: every) == .none, "5.9 pt left: a click")
        check(G.classify(CGSize(width: -200, height: 30), allowed: every) == .send, "far left, slightly down: still a send")
        check(G.classify(polar(60, 164.9), allowed: every) == .none, "164.9°: just outside the send's sector")
        check(G.classify(polar(60, -164.9), allowed: every) == .none, "−164.9°: just outside the send's sector")
        // the right fan −45°…+15° and the left sector 165°…195° ask for something; nothing else does
        for deg in stride(from: -45.0, through: 14.5, by: 0.5) {
            check(G.intent(polar(60, deg)) != .none, "\(deg)°: inside the right fan, something is asked for")
        }
        for deg in stride(from: 165.5, through: 194.5, by: 0.5) {
            check(G.intent(polar(60, deg)) == .send, "\(deg)°: inside the left sector, a send")
        }
        for deg in [15.5, 46.0, 60, 89, 90, 120, 150, 164, -164, -150, -135, -90, -60, -46] {
            check(G.classify(polar(60, deg), allowed: every) == .none, "\(deg)°: nothing")
        }
        check(G.classify(CGSize(width: 0, height: -60), allowed: every) == .none, "straight up: nothing")
        check(G.classify(CGSize(width: -60, height: -60), allowed: every) == .none, "up-left: nothing")
        check(G.classify(CGSize(width: 0, height: 60), allowed: every) == .none, "straight down: nothing")

        // `allowed`: a result the "+" does not offer is nothing (the ghost says "not here").
        let gainsOnly: Set<PlusGestureResult> = [.gain, .gainPanMute]
        let sendOnly: Set<PlusGestureResult> = [.send]
        let branchWithout: Set<PlusGestureResult> = [.gain, .gainPanMute, .send]   // the trunk of an EMPTY chain
        check(G.classify(polar(60, -30), allowed: gainsOnly) == .none, "a bin / a send's chain: no branch")
        check(G.classify(polar(60, 180), allowed: gainsOnly) == .none, "a bin / a send's chain: no send")
        check(G.classify(CGSize(width: 40, height: 0), allowed: gainsOnly) == .gain, "a bin: a gain")
        check(G.classify(CGSize(width: 40, height: 0), allowed: sendOnly) == .none, "mixer -> stems: no gain")
        check(G.classify(CGSize(width: 120, height: 0), allowed: sendOnly) == .none, "mixer -> stems: no gain + pan + mute")
        check(G.classify(polar(60, -30), allowed: sendOnly) == .none, "mixer -> stems: no branch")
        check(G.classify(polar(60, 180), allowed: sendOnly) == .send, "mixer -> stems: the send, to the left")
        check(G.classify(polar(60, 30), allowed: sendOnly) == .none, "mixer -> stems: up-right is nothing any more")
        check(G.classify(polar(60, -30), allowed: branchWithout) == .none, "an empty chain: the branch is refused")
        check(G.classify(polar(60, -30), allowed: []) == .none, "nothing offered: nothing")
        // intent ignores `allowed`
        check(G.intent(polar(60, -30)) == .branch && G.intent(polar(60, 180)) == .send, "intent is the raw direction")

        // MARK: the zones drawn round a dragged "+" ARE the classifier
        let zones = G.sectors(allowed: every)
        check(zones.map(\.result) == [.gain, .gainPanMute, .branch, .send], "the trunk draws four zones, in order")
        check(G.sectors(allowed: [.gain, .gainPanMute]).map(\.result) == [.gain, .gainPanMute], "a send's chain: the two gain zones only")
        check(G.sectors(allowed: [.send]).map(\.result) == [.send], "mixer -> stems: the send zone only")
        check(G.sectors(allowed: [.gain, .gainPanMute, .branch]).allSatisfy { $0.result != .send }, "a branch's '+': no send zone (absent)")
        check(G.sectors(allowed: []).isEmpty, "nothing offered: no zone")
        var sampled = 0
        for z in zones {
            check(z.fromAngle < z.toAngle, "\(z.result): a proper angular range")
            // every point strictly inside the zone classifies to the zone's result
            for ai in 0...20 {
                let deg = z.fromAngle + 0.5 + (z.toAngle - z.fromAngle - 1) * Double(ai) / 20
                let rIn = z.inner.distance(at: deg) + 0.5, rOut = z.outer.distance(at: deg) - 0.5
                check(rIn < rOut, "\(z.result) @\(deg)°: the inner boundary is inside the outer one")
                for ri in 0...10 {
                    let r = rIn + (rOut - rIn) * CGFloat(ri) / 10
                    let t = PlusSector.offset(deg, r)
                    sampled += 1
                    if G.classify(t, allowed: every) != z.result {
                        check(false, "\(z.result): the point \(t) inside the zone classifies to \(G.classify(t, allowed: every))")
                    }
                    if G.highlighted(t, in: zones) != z.result {
                        check(false, "\(z.result): the point \(t) lights up its zone")
                    }
                }
            }
            // the icon is inside its zone, and the outline closes round it
            check(G.classify(z.iconOffset, allowed: every) == z.result, "\(z.result): its icon sits in its zone")
            let o = z.outline(steps: 8)
            check(o.count == 16, "\(z.result): the outline = inner + outer boundaries")
            check(o.allSatisfy { hypot($0.width, $0.height) >= G.sectorInnerRadius - 1e-6 }, "\(z.result): never over the '+' disc")
            check(o.allSatisfy { hypot($0.width, $0.height) <= G.sectorOuterRadius / CGFloat(cos(G.angleTolerance * .pi / 180)) + 1e-6 },
                  "\(z.result): within the outer radius")
        }
        // the gain / gain+pan+mute cut is the classifier's vertical line at 80 pt
        let gz = zones[0], pz = zones[1]
        check(gz.outer == .vertical(G.panMuteThreshold) && pz.inner == .vertical(G.panMuteThreshold), "the cut is the 80 pt line")
        check(abs(gz.outer.distance(at: 10) * CGFloat(cos(10 * Double.pi / 180)) - 80) < 1e-6, "the 80 pt line, at 10°")
        // placement: gain right, branch down-right, send left (screen coordinates, y down)
        check(gz.iconOffset.width > 0 && abs(gz.iconOffset.height) < 1e-6, "the gain icon: right of the '+'")
        check(zones[2].iconOffset.width > 0 && zones[2].iconOffset.height > 0, "the branch icon: down-right")
        check(zones[3].iconOffset.width < 0 && abs(zones[3].iconOffset.height) < 1e-6, "the send icon: left")
        // the highlight: nothing for a click or a direction with no zone; the zone's result otherwise
        check(G.highlighted(CGSize(width: 3, height: 0), in: zones) == nil, "a click lights nothing")
        check(G.highlighted(polar(60, 30), in: zones) == nil, "up-right lights nothing")
        check(G.highlighted(polar(60, 180), in: G.sectors(allowed: [.gain])) == nil, "a send where only a gain is offered lights nothing")
        check(G.highlighted(CGSize(width: 100, height: 0), in: zones) == .gainPanMute, "past 80 pt: the gain + pan + mute zone")
        print("  zones: \(sampled) points sampled")

        print(failures == 0 ? "ALL PASS (\(total) assertions)" : "failures: \(failures) of \(total)")
        exit(failures == 0 ? 0 : 1)
    }
}

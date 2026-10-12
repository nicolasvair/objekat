import Foundation

// Standalone test of the "+" gesture classifier of the signal view (docs/plan_synoptic_rework.md §B.2, the
// user's decisions of 12 October 2026): under 6 pt a click; right = a gain, past 80 pt gain + pan + mute;
// −30° (down-right) = a parallel branch; +30° (up-right) = a send; ±15° round each direction; left, or too
// steep = nothing; a result the "+" does not offer = nothing.
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

        // The two diagonals, ±15° round ±30°.
        for deg in [15.01, 17.5, 20, 25, 30, 35, 40, 44.99] {
            check(G.classify(polar(60, deg), allowed: every) == .send, "+\(deg)°: a send")
            check(G.classify(polar(60, -deg), allowed: every) == .branch, "−\(deg)°: a branch")
        }
        check(G.classify(polar(60, 30), allowed: every) == .send, "+30° exactly: a send")
        check(G.classify(polar(60, -30), allowed: every) == .branch, "−30° exactly: a branch")
        // the three sectors tile −45°…+45° without a hole: every angle in there asks for something
        for deg in stride(from: -45.0, through: 45.0, by: 0.5) {
            check(G.intent(polar(60, deg)) != .none, "\(deg)°: inside the fan, something is asked for")
        }
        // beyond ±45° (too steep), or going left, nothing
        for deg in [46.0, 60, 89, 90, 120, 180, -46, -60, -90, -135, -179] {
            check(G.classify(polar(60, deg), allowed: every) == .none, "\(deg)°: nothing")
        }
        check(G.classify(CGSize(width: 0, height: -60), allowed: every) == .none, "straight up: nothing")
        check(G.classify(CGSize(width: -60, height: 0), allowed: every) == .none, "left: nothing")
        check(G.classify(CGSize(width: -60, height: -30), allowed: every) == .none, "up-left: nothing")
        check(G.classify(CGSize(width: 0, height: 60), allowed: every) == .none, "straight down: nothing")

        // `allowed`: a result the "+" does not offer is nothing (the ghost says "not here").
        let gainsOnly: Set<PlusGestureResult> = [.gain, .gainPanMute]
        let sendOnly: Set<PlusGestureResult> = [.send]
        let branchWithout: Set<PlusGestureResult> = [.gain, .gainPanMute, .send]   // the trunk of an EMPTY chain
        check(G.classify(polar(60, -30), allowed: gainsOnly) == .none, "a bin / a send's chain: no branch")
        check(G.classify(polar(60, 30), allowed: gainsOnly) == .none, "a bin / a send's chain: no send")
        check(G.classify(CGSize(width: 40, height: 0), allowed: gainsOnly) == .gain, "a bin: a gain")
        check(G.classify(CGSize(width: 40, height: 0), allowed: sendOnly) == .none, "mixer -> stems: no gain")
        check(G.classify(CGSize(width: 120, height: 0), allowed: sendOnly) == .none, "mixer -> stems: no gain + pan + mute")
        check(G.classify(polar(60, -30), allowed: sendOnly) == .none, "mixer -> stems: no branch")
        check(G.classify(polar(60, 30), allowed: sendOnly) == .send, "mixer -> stems: the send")
        check(G.classify(polar(60, -30), allowed: branchWithout) == .none, "an empty chain: the branch is refused")
        check(G.classify(polar(60, -30), allowed: []) == .none, "nothing offered: nothing")
        // intent ignores `allowed`
        check(G.intent(polar(60, -30)) == .branch && G.intent(polar(60, 30)) == .send, "intent is the raw direction")

        print(failures == 0 ? "ALL PASS (\(total) assertions)" : "failures: \(failures) of \(total)")
        exit(failures == 0 ? 0 : 1)
    }
}

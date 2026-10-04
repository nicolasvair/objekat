// The automation band's hand travel — asserted with no screen.
//
// `AutomationHandTravel` depends on nothing at all: pure arithmetic, the half of the feature with
// no view and no model behind it. Pinned down: zero at zero, identity on a row already coarser
// than the fine rate, the fine slope inside the knee, odd symmetry, continuity at the knee and a
// slope of 1 past it (the whole range stays reachable).
//
//     swiftc -parse-as-library \
//         ../objekat/Shared/AutomationHandTravel.swift test_automation_hand_travel.swift \
//         -o /tmp/ahandtravel && /tmp/ahandtravel
//
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation

var fails: [String] = []
var total = 0

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    total += 1
    if ok { print("ok    " + label) }
    else { fails.append(label); print("FAIL  \(label)  \(detail)") }
}
func near(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool { abs(a - b) <= tol }

@main
enum AutomationHandTravelTest {
  static func main() {
    let r = 0.849      // a volume row: ~0.85 px per dB
    func f(_ dy: Double, _ rate: Double = r) -> Double {
        AutomationHandTravel.rowTravel(handDy: dy, rowPxPerStep: rate)
    }
    let knee = AutomationHandTravel.fineSteps * AutomationHandTravel.pxPerStep

    check("f(0) = 0", f(0) == 0)
    check("identity when the row is coarser (5.8 px/step)", near(f(10, 5.8), 10) && near(f(-37, 5.8), -37))
    check("identity at exactly the fine rate", near(f(10, AutomationHandTravel.pxPerStep), 10))
    check("identity for a degenerate rate", near(f(10, 0), 10) && near(f(10, -1), 10))
    check("4 px of hand = one detent step on the row", near(f(4), r), "\(f(4))")
    check("odd symmetry", near(f(-4), -f(4)) && near(f(-50), -f(50)) && near(f(-10), -f(10)))
    check("continuity at the knee", near(f(knee - 1e-9), f(knee + 1e-9), 1e-6))
    check("knee lands on six steps", near(f(knee), 6 * r), "\(f(knee))")
    check("slope 1 past the knee", near(f(34) - f(30), 4))
    check("monotonic", (0..<200).allSatisfy { f(Double($0)) <= f(Double($0) + 1) })

    // The wheel over a line (precise deltas): steps read off the gesture's TOTAL travel.
    typealias H = AutomationHandTravel
    func w(_ t: Double) -> Int { H.wheelSteps(travel: t) }
    let f0 = H.wheelFirstPt, fs = H.wheelFinePtPerStep, cs = H.wheelCoarsePtPerStep
    let knee = f0 + Double(H.wheelFineSteps - 1) * fs
    check("wheel: nothing under the first threshold", w(0) == 0 && w(f0 - 0.1) == 0 && w(-(f0 - 0.1)) == 0)
    check("wheel: first step at the threshold", w(f0) == 1 && w(-f0) == -1)
    check("wheel: fine zone spaced", w(f0 + fs - 0.1) == 1 && w(f0 + fs) == 2 && w(knee) == H.wheelFineSteps,
          "\(w(f0 + fs)) \(w(knee))")
    check("wheel: coarse past the knee",
          w(knee + cs) == H.wheelFineSteps + 1 && w(knee + 10 * cs) == H.wheelFineSteps + 10)
    check("wheel: odd symmetry", (0..<200).allSatisfy { w(-Double($0) * 0.7) == -w(Double($0) * 0.7) })
    check("wheel: monotonic", (0..<400).allSatisfy { w(Double($0) * 0.5) <= w(Double($0) * 0.5 + 0.5) })
    check("wheel: one step per event in the fine zone",
          H.wheelStepDelta(travel: knee + 40, applied: 0) == 1 && H.wheelStepDelta(travel: -(knee + 40), applied: 2) == -1)
    check("wheel: free past the fine zone", H.wheelStepDelta(travel: knee + 10 * cs, applied: H.wheelFineSteps) == 10)
    check("wheel: nothing to add when caught up", H.wheelStepDelta(travel: f0 + fs, applied: 2) == 0)

    print(fails.isEmpty ? "\nALL PASS (\(total))"
                        : "\n\(fails.count) FAILURE(S) of \(total): \(fails.joined(separator: ", "))")
    exit(fails.isEmpty ? 0 : 1)
  }
}

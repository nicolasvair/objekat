// The automation band's hand travel — asserted with no screen.
//
// `AutomationHandTravel` depends on nothing at all: pure arithmetic, the half of the feature with
// no view and no model behind it. Pinned down: zero at zero, identity on a row already coarser
// than the fine rate, the fine slope inside the knee, odd symmetry, continuity at the knee and a
// slope of 1 past it (the whole range stays reachable). And the pencil's drag: one constant rate,
// re-anchored at the parameter's bounds.
//
//     swiftc -parse-as-library \
//         ../objekat/Shared/AutomationHandTravel.swift ../objekat/Shared/FineAdjust.swift \
//         test_automation_hand_travel.swift \
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
    let nf = H.wheelFineSteps, span = Double(nf - 1) * fs
    check("wheel: nothing under the first threshold", w(0) == 0 && w(f0 - 0.1) == 0 && w(-(f0 - 0.1)) == 0)
    check("wheel: first step at the threshold", w(f0) == 1 && w(-f0) == -1)
    check("wheel: fine zone spaced", w(f0 + fs - 0.1) == 1 && w(f0 + fs) == 2 && w(f0 + span) == nf)
    check("wheel: coarse past the knee", w(f0 + span + cs) == nf + 1 && w(f0 + span + 10 * cs) == nf + 10)
    check("wheel: odd symmetry", (0..<300).allSatisfy { w(-Double($0) * 0.7) == -w(Double($0) * 0.7) })
    check("wheel: monotonic", (0..<600).allSatisfy { w(Double($0) * 0.5) <= w(Double($0) * 0.5 + 0.5) })
    check("wheel: one step per event in the fine zone",
          H.wheelStepDelta(travel: f0 + span + 100, applied: 0) == 1
          && H.wheelStepDelta(travel: -(f0 + span + 100), applied: 2) == -1)
    check("wheel: free past the fine zone", H.wheelStepDelta(travel: f0 + span + 10 * cs, applied: nf) == 10)
    check("wheel: nothing to add when caught up", H.wheelStepDelta(travel: f0 + fs, applied: 2) == 0)

    // The pencil's drag (live write): ONE rate everywhere, anchored, re-anchored at the bounds.
    let pp = H.pencilPxPerStep
    do {
        var d = H.PencilDrag(startValue: -12)
        let range: ClosedRange<Double> = -96...40
        check("pencil: zero at zero", d.value(handDy: 0, step: 1, range: range) == -12)
        check("pencil: one step per pencilPxPerStep, up = rising",
              near(d.value(handDy: -pp, step: 1, range: range), -11))
        // The same hand travel moves the value by the same amount wherever it happens.
        var deltas: [Double] = []
        var prev = d.value(handDy: 0, step: 1, range: range)
        for i in 1...60 {
            let v = d.value(handDy: -Double(i) * 3, step: 1, range: range)
            deltas.append(v - prev); prev = v
        }
        check("pencil: constant rate, no knee",
              deltas.allSatisfy { near($0, 3 / pp, 1e-9) }, "\(deltas.prefix(4))")
    }
    do {
        // Overshooting the top, then coming back: the value answers at the first pixel back.
        var d = H.PencilDrag(startValue: 38)
        let range: ClosedRange<Double> = -96...40
        let top = d.value(handDy: -200, step: 1, range: range)
        check("pencil: clamped at the top", top == 40)
        let back = d.value(handDy: -200 + pp, step: 1, range: range)
        check("pencil: no dead travel after the bound", near(back, 39), "\(back)")
        let bottom = d.value(handDy: 5000, step: 1, range: range)
        check("pencil: clamped at the bottom", bottom == -96)
        check("pencil: no dead travel at the bottom either",
              near(d.value(handDy: 5000 - 2 * pp, step: 1, range: range), -94))
    }
    do {
        // ⇧ (fine): a tenth of the travel, and no jump when it flips mid-gesture.
        var d = H.PencilDrag(startValue: 0)
        let range: ClosedRange<Double> = -96...40
        let a = d.value(handDy: -4 * pp, step: 1, range: range)
        let atPress = d.value(handDy: -4 * pp, step: 1, range: range, fine: true)
        check("pencil ⇧: pressing at rest does not jump", near(a, atPress), "\(a) vs \(atPress)")
        let f = d.value(handDy: -14 * pp, step: 1, range: range, fine: true)
        check("pencil ⇧: ten steps of travel are worth one", near(f, 4 + 1), "\(f)")
        let r = d.value(handDy: -14 * pp, step: 1, range: range, fine: false)
        check("pencil ⇧: releasing at rest does not jump", near(r, f), "\(r)")
        var held = H.PencilDrag(startValue: 0, fine: true)
        check("pencil ⇧: held from the press, the whole drag is fine",
              near(held.value(handDy: -10 * pp, step: 1, range: range, fine: true), 1))
        // Overshooting a bound while fine: the first pixel back answers at the fine rate.
        var top = H.PencilDrag(startValue: 39.5, fine: true)
        let clamped = top.value(handDy: -100 * pp, step: 1, range: range, fine: true)
        check("pencil ⇧: clamped at the top", clamped == 40)
        check("pencil ⇧: no dead travel after the bound",
              near(top.value(handDy: -100 * pp + 10 * pp, step: 1, range: range, fine: true), 39),
              "\(top.value(handDy: -100 * pp + 10 * pp, step: 1, range: range, fine: true))")
    }
    do {
        // The rate is the parameter's STEP per pencilPxPerStep, never the row's height.
        var pan = H.PencilDrag(startValue: 0)
        check("pencil: pan moves a tenth per step",
              near(pan.value(handDy: -pp, step: 0.1, range: -1...1), 0.1))
    }

    print(fails.isEmpty ? "\nALL PASS (\(total))"
                        : "\n\(fails.count) FAILURE(S) of \(total): \(fails.joined(separator: ", "))")
    exit(fails.isEmpty ? 0 : 1)
  }
}

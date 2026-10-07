// The rule of a number control that has `presets` (revision 6b), asserted with no app and no JSON:
// the nearest preset, what makes a declared list acceptable, the text of a button.
//
//     swiftc -parse-as-library \
//         objekat/Shared/ScriptControlPresets.swift tools/test_script_control_presets.swift \
//         -o /tmp/scp && /tmp/scp
//
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation

var fails: [String] = []
var total = 0

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    total += 1
    if ok { print("ok    " + label) }
    else { print("FAIL  " + label + (detail.isEmpty ? "" : "  [" + detail + "]")); fails.append(label) }
}

@main struct Test {
    static func main() {
        let gain: [Double] = [-60, -24, -12, -6, -3, 3]
        func near(_ v: Double, _ p: [Double] = gain) -> Double? { ScriptControlPresets.nearest(v, in: p) }

        // nearest
        for p in gain { check("a preset snaps to itself (\(p))", near(p) == p) }
        check("-7 snaps to -6", near(-7) == -6)
        check("-33 snaps to -24 (the nearer one)", near(-33) == -24)
        check("-43 snaps to -60 (17 away, against 19)", near(-43) == -60)
        check("-0.5 snaps to -3 (2.5 away, against 3.5 for +3)", near(-0.5) == -3)
        check("+12 snaps to +3 (the last)", near(12) == 3)
        check("-96 snaps to -60 (the first)", near(-96) == -60)
        check("a tie goes to the one listed first (-9 between -12 and -6)", near(-9) == -12)
        check("a tie goes to the one listed first, descending list", near(-9, [-6, -12]) == -6)
        check("a single preset is always the answer", near(42, [7]) == 7)
        check("NaN has no nearest", near(.nan) == nil)
        check("infinity has no nearest", near(.infinity) == nil)
        check("an empty list has no nearest", near(0, []) == nil)

        // problem
        check("the gain list is acceptable in -60…12", ScriptControlPresets.problem(gain, min: -60, max: 12) == nil)
        check("an empty list is refused", ScriptControlPresets.problem([], min: 0, max: 1) != nil)
        check("a preset below min is refused", ScriptControlPresets.problem([-61, 0], min: -60, max: 12) != nil)
        check("a preset above max is refused", ScriptControlPresets.problem([0, 13], min: -60, max: 12) != nil)
        check("the bounds themselves are fine", ScriptControlPresets.problem([-60, 12], min: -60, max: 12) == nil)
        check("a duplicate is refused", ScriptControlPresets.problem([1, 2, 1], min: 0, max: 5) != nil)
        check("NaN is refused", ScriptControlPresets.problem([.nan], min: 0, max: 5) != nil)
        check("infinity is refused", ScriptControlPresets.problem([.infinity], min: 0, max: .infinity) != nil)

        // label
        check("-60 reads with a true minus sign", ScriptControlPresets.label(-60) == "\u{2212}60")
        check("+3 reads with an explicit plus", ScriptControlPresets.label(3) == "+3")
        check("0 reads as 0", ScriptControlPresets.label(0) == "0")
        check("a fraction keeps its decimals", ScriptControlPresets.label(-0.5) == "\u{2212}0.5")
        check("a positive fraction", ScriptControlPresets.label(1.5) == "+1.5")

        print("\(total - fails.count)/\(total) assertions")
        exit(fails.isEmpty ? 0 : 1)
    }
}

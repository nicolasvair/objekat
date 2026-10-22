// `FineAdjust` — the one rule of the ⇧ fine adjustment: a tenth of the travel, and no jump when ⇧
// is pressed or released in the middle of a gesture. Pure, no screen. Run from `tools/`:
//
//     cd tools && swiftc -parse-as-library \
//         ../objekat/Shared/FineAdjust.swift \
//         test_fine_adjust.swift \
//         -o /tmp/fa && /tmp/fa
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
func near(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool { abs(a - b) <= eps }

@main
enum FineAdjustTest {
    static func main() {

        check("the factor is a tenth", FineAdjust.factor == 0.1)

        // Bare and fine from the start: pure scaling.
        do {
            var f = FineAdjust()
            check("bare: the travel is the travel", near(f.effective(10, fine: false), 10))
            check("bare: still linear", near(f.effective(-4, fine: false), -4))
        }
        do {
            var f = FineAdjust(fine: true)
            check("fine from the first pixel: a tenth", near(f.effective(10, fine: true), 1))
            check("... and negative travel too", near(f.effective(-30, fine: true), -3))
        }

        // The switch: continuity.
        do {
            var f = FineAdjust()
            let before = f.effective(20, fine: false)        // 20 earned bare
            let atSwitch = f.effective(20, fine: true)       // ⇧ pressed, hand has not moved
            check("pressing ⇧ does not jump", near(before, atSwitch), "\(before) vs \(atSwitch)")
            let after = f.effective(30, fine: true)          // 10 more raw = 1 effective
            check("after pressing ⇧ the slope is a tenth", near(after, 21), "\(after)")
            let back = f.effective(30, fine: false)          // ⇧ released
            check("releasing ⇧ does not jump", near(back, 21), "\(back)")
            let more = f.effective(40, fine: false)
            check("after releasing ⇧ the slope is 1 again", near(more, 31), "\(more)")
        }
        do {
            // Fine first, then bare, then fine again, the hand going back and forth.
            var f = FineAdjust(fine: true)
            var v = f.effective(50, fine: true)              // 5
            check("fine leg", near(v, 5))
            v = f.effective(50, fine: false)                 // release at the same place
            check("release at rest: no jump", near(v, 5))
            v = f.effective(10, fine: false)                 // hand returns 40 bare: 5 - 40
            check("bare leg backwards", near(v, -35), "\(v)")
            v = f.effective(10, fine: true)
            check("press at rest: no jump", near(v, -35))
            v = f.effective(110, fine: true)                 // +100 raw fine = +10
            check("fine leg forwards", near(v, -25), "\(v)")
        }
        do {
            // Many flips never drift: the total equals the sum of the legs.
            var f = FineAdjust()
            var expected = 0.0, raw = 0.0, fine = false
            var ok = true
            for k in 0..<200 {
                let step = Double((k * 7) % 13) - 6
                raw += step
                expected += step * (fine ? 0.1 : 1)
                let got = f.effective(raw, fine: fine)
                if !near(got, expected, 1e-6) { ok = false }
                if k % 5 == 4 { fine.toggle(); _ = f.effective(raw, fine: fine) }
            }
            check("200 frames, a flip every fifth: the total never drifts", ok)
        }

        // Stateless helpers.
        check("scaled: bare", near(FineAdjust.scaled(3, fine: false), 3))
        check("scaled: fine", near(FineAdjust.scaled(3, fine: true), 0.3))
        check("step: bare", FineAdjust.step(1, fine: false) == 1)
        check("step: fine default is step x factor", near(FineAdjust.step(1, fine: true), 0.1))
        check("step: fine, the caller names its own", FineAdjust.step(0.1, fine: true, fineStep: 0.01) == 0.01)
        check("step: bare ignores the fine step", FineAdjust.step(0.1, fine: false, fineStep: 0.01) == 0.1)

        // The box's detent follows the slope.
        check("snapped: bare rounds to the unit", FineAdjust.snapped(2.46, to: 1, fine: false) == 2)
        check("snapped: fine rounds to a tenth", near(FineAdjust.snapped(2.46, to: 1, fine: true), 2.5))
        check("snapped: fine, a quantum of 0.5", near(FineAdjust.snapped(1.23, to: 0.5, fine: true), 1.25))
        check("snapped: a null quantum leaves the value", FineAdjust.snapped(1.234, to: 0, fine: false) == 1.234)

        print("\n\(total - fails.count)/\(total) assertions passed")
        if !fails.isEmpty { print("FAILED: \(fails)"); exit(1) }
    }
}

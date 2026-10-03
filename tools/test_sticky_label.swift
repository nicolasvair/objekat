// A block's name anchored to the start of its VISIBLE part (`Shared/StickyLabel.swift`),
// asserted with no screen.
//
//     swiftc -parse-as-library ../objekat/Shared/StickyLabel.swift test_sticky_label.swift -o /tmp/stickylabel && /tmp/stickylabel
//
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation
import CoreGraphics

var fails: [String] = []
var total = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    total += 1
    if ok { print("ok    " + label) } else { fails.append(label); print("FAIL  \(label)  \(detail)") }
}

@main struct Runner { static func main() {
    let inset = StickyLabel.edgeInset

    // x(natural:viewportLeft:rightLimit:)
    check("block wholly on screen: the name stays where it was",
          StickyLabel.x(natural: 500, viewportLeft: 100, rightLimit: 900) == 500)
    check("name left of the viewport: clamped on the edge (+ inset)",
          StickyLabel.x(natural: 50, viewportLeft: 300, rightLimit: 900) == 300 + inset)
    check("exactly at the clamp: unchanged",
          StickyLabel.x(natural: 306, viewportLeft: 300, rightLimit: 900) == 306)
    check("never pushed LEFT of its natural place",
          (StickyLabel.x(natural: 400, viewportLeft: 300, rightLimit: 900) ?? 0) >= 400)
    check("room left but small: still drawn (>= minVisible)",
          StickyLabel.x(natural: 50, viewportLeft: 300, rightLimit: 306 + StickyLabel.minVisiblePx) == 306)
    check("no room left before the block's end: not drawn",
          StickyLabel.x(natural: 50, viewportLeft: 300, rightLimit: 306 + StickyLabel.minVisiblePx - 1) == nil)
    check("a clamp that is not needed is never refused for lack of room",
          StickyLabel.x(natural: 500, viewportLeft: 100, rightLimit: 505) == 500)

    // leading(natural:visibleX:blockWidth:) — the rich views
    check("rich: whole block visible -> natural padding",
          StickyLabel.leading(natural: 8, visibleX: 0, blockWidth: 400) == 8)
    check("rich: visible part starts 120 px in -> padding follows it",
          StickyLabel.leading(natural: 8, visibleX: 120, blockWidth: 400) == 120 + inset)
    check("rich: nearly nothing visible -> natural padding (no push)",
          StickyLabel.leading(natural: 8, visibleX: 395, blockWidth: 400) == 8)
    check("rich: a fade's wider natural padding is never reduced",
          StickyLabel.leading(natural: 60, visibleX: 20, blockWidth: 400) == 60)

    // isLive
    let step = 512.0
    check("live: a wide block straddling the left edge",
          StickyLabel.isLive(naturalX: 100, blockX: 92, blockWidth: 900, cullScrollX: 512, step: step))
    check("live: a block starting inside the notch window",
          StickyLabel.isLive(naturalX: 900, blockX: 892, blockWidth: 200, cullScrollX: 512, step: step))
    check("not live: starts beyond the window where the edge can be",
          !StickyLabel.isLive(naturalX: 1100, blockX: 1092, blockWidth: 200, cullScrollX: 512, step: step))
    check("not live: wholly left of the window (nothing to see)",
          !StickyLabel.isLive(naturalX: 8, blockX: 0, blockWidth: 300, cullScrollX: 512, step: step))
    check("not live: too narrow to carry a name that follows the scroll",
          !StickyLabel.isLive(naturalX: 600, blockX: 592, blockWidth: 39, cullScrollX: 512, step: step))

    // The two passes PARTITION the labels: for any block, exactly one of them draws it.
    let ordinary = StickyLabelPass(exactScrollX: nil, cullScrollX: 512, step: 512)
    var partitionOK = true
    var detail = ""
    for exact in stride(from: 512.0, to: 1024.0, by: 37.0) {
        let sticky = StickyLabelPass(exactScrollX: CGFloat(exact), cullScrollX: 512, step: 512)
        for blockX in stride(from: 0.0, through: 3000.0, by: 53.0) {
            for width in [10.0, 39.0, 40.0, 150.0, 900.0, 5000.0] {
                let natural = blockX + 8
                let a = ordinary.placement(naturalX: natural, blockX: blockX, blockWidth: width, rightLimit: blockX + width)
                let b = sticky.placement(naturalX: natural, blockX: blockX, blockWidth: width, rightLimit: blockX + width)
                // never drawn twice
                if a != nil && b != nil { partitionOK = false; detail = "twice x=\(blockX) w=\(width) exact=\(exact)" }
                // when only the sticky pass could draw it, it never goes LEFT of natural
                if let b, b < natural { partitionOK = false; detail = "left of natural" }
                // a label the ordinary pass declines is either drawn by the sticky pass or has no room
                // (nil) — never silently lost while its natural place is on screen
                if a == nil && b == nil {
                    let visibleStart = max(blockX, exact)
                    let room = blockX + width - (exact + inset)
                    let naturalOnScreen = natural >= exact + inset
                    if naturalOnScreen || room >= StickyLabel.minVisiblePx {
                        if blockX + width > exact { partitionOK = false; detail = "lost x=\(blockX) w=\(width) exact=\(exact) vis=\(visibleStart)" }
                    }
                }
            }
        }
    }
    check("the passes never draw a label twice nor lose one that has room", partitionOK, detail)
    check("ordinary pass: a non-live label is at its natural place",
          ordinary.placement(naturalX: 2000, blockX: 1992, blockWidth: 300, rightLimit: 2292) == 2000)
    check("ordinary pass: a live label is left to the sticky layer",
          ordinary.placement(naturalX: 600, blockX: 592, blockWidth: 300, rightLimit: 892) == nil)

    print("\n\(total) assertions, \(fails.count) failed")
    if !fails.isEmpty { exit(1) }
    print("ALL PASS")
} }

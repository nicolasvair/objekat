// The rules of the Finder's automatic preview (`Shared/FinderAutoPreview.swift`), asserted with no
// screen.
//
//     swiftc -parse-as-library ../objekat/Shared/FinderAutoPreview.swift test_finder_auto_preview.swift \
//         -o /tmp/finderautopreview && /tmp/finderautopreview
//
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation

var fails: [String] = []
var total = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    total += 1
    if ok { print("ok    " + label) } else { fails.append(label); print("FAIL  \(label)  \(detail)") }
}
func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

@main struct Runner { static func main() {
    typealias A = FinderAutoPreview
    let me = UUID(), other = UUID()

    // ── The start, once the debounce has elapsed ───────────────────────────────────────────
    check("a file under the cursor, feature on: starts",
          A.shouldStart(enabled: true, cancelled: false, cursorID: me, nodeID: me, isDirectory: false))
    check("a FOLDER never starts",
          !A.shouldStart(enabled: true, cancelled: false, cursorID: me, nodeID: me, isDirectory: true))
    check("the cursor moved on before the delay: cancelled",
          !A.shouldStart(enabled: true, cancelled: false, cursorID: other, nodeID: me, isDirectory: false))
    check("no cursor at all: nothing",
          !A.shouldStart(enabled: true, cancelled: false, cursorID: nil, nodeID: me, isDirectory: false))
    check("the wait was cancelled (a stop): nothing",
          !A.shouldStart(enabled: true, cancelled: true, cursorID: me, nodeID: me, isDirectory: false))
    check("the feature turned off during the wait: nothing",
          !A.shouldStart(enabled: false, cancelled: false, cursorID: me, nodeID: me, isDirectory: false))
    check("the debounce is short (a tenth of a second or so)", A.debounce > 0.05 && A.debounce < 0.3)

    // ── The stop timer and its generation ──────────────────────────────────────────────────
    check("a timer armed in generation 3 cuts generation 3", A.timerApplies(armed: 3, current: 3))
    check("a STALE timer (armed in 3, the preview is now 4) cuts nothing", !A.timerApplies(armed: 3, current: 4))

    // ── The end of the preview ─────────────────────────────────────────────────────────────
    check("point O set after point I: the end is point O", near(A.endPoint(pointI: 0, pointO: 2.5, playerDuration: 9), 2.5))
    check("an explicit I and O: remaining = O - I", near(A.remaining(pointI: 1, pointO: 3.5, playerDuration: 9), 2.5))
    check("point O still 0 (length not loaded): the end is the player's duration",
          near(A.endPoint(pointI: 0, pointO: 0, playerDuration: 4.2), 4.2))
    check("point O still 0: NO immediate stop (remaining = the whole file)",
          near(A.remaining(pointI: 0, pointO: 0, playerDuration: 4.2), 4.2))
    check("point O not after point I: falls back on the player's duration",
          near(A.endPoint(pointI: 2, pointO: 2, playerDuration: 6), 6))
    check("remaining never negative", near(A.remaining(pointI: 5, pointO: 0, playerDuration: 3), 0))

    print("\n\(total - fails.count)/\(total) ok")
    exit(fails.isEmpty ? 0 : 1)
} }

// The rules of the Finder's automatic preview (`Shared/FinderAutoPreview.swift`), asserted with no
// screen: the MODE a hand turns on by launching a preview (and that an explicit stop turns off), what an
// arrow plans while it is on, the debounce, the stale stop timer, the end of the preview.
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

    // ── The mode starts OFF: the arrows play nothing by themselves ──────────────────────────
    var m = A.Mode()
    check("a fresh mode is off", !m.isOn)
    check("OFF: an arrow landing on a file plans nothing", !m.shouldSchedule(isDirectory: false))
    check("OFF: nothing starts even with the cursor still on the file",
          !m.shouldStart(cancelled: false, cursorID: me, nodeID: me, isDirectory: false))
    m.started(byHand: false)
    check("a start the mode did not owe to a hand does not turn it on", !m.isOn)
    m.stopped(.automatic)
    check("an automatic stop of an off mode leaves it off", !m.isOn)
    m.stopped(.explicit)
    check("an explicit stop of an off mode leaves it off", !m.isOn)

    // ── The hand launches a preview: the mode turns on ──────────────────────────────────────
    m.started(byHand: true)
    check("a preview launched by the hand turns the mode on", m.isOn)
    check("ON: an arrow landing on a FILE plans a start", m.shouldSchedule(isDirectory: false))
    check("ON: an arrow landing on a FOLDER plans nothing", !m.shouldSchedule(isDirectory: true))

    // ── What happens once the debounce has elapsed ──────────────────────────────────────────
    check("ON, a file under the cursor, not cancelled: plays",
          m.shouldStart(cancelled: false, cursorID: me, nodeID: me, isDirectory: false))
    check("a FOLDER never starts",
          !m.shouldStart(cancelled: false, cursorID: me, nodeID: me, isDirectory: true))
    check("the cursor moved on before the delay: cancelled",
          !m.shouldStart(cancelled: false, cursorID: other, nodeID: me, isDirectory: false))
    check("no cursor at all: nothing",
          !m.shouldStart(cancelled: false, cursorID: nil, nodeID: me, isDirectory: false))
    check("the wait was cancelled (a stop): nothing",
          !m.shouldStart(cancelled: true, cursorID: me, nodeID: me, isDirectory: false))
    check("the debounce is short (a tenth of a second or so)", A.debounce > 0.05 && A.debounce < 0.3)

    // ── An automatic stop keeps the mode ("locked") ─────────────────────────────────────────
    m.stopped(.automatic)
    check("the sound ended by itself: the mode STAYS on", m.isOn)
    check("…and the next arrow still plans its file", m.shouldSchedule(isDirectory: false))
    m.started(byHand: false)
    check("an arrow's own start keeps it on", m.isOn)
    m.stopped(.automatic)
    check("one file giving way to the next keeps it on", m.isOn)
    m.stopped(.automatic)
    m.stopped(.automatic)
    check("any number of automatic stops keeps it on", m.isOn)

    // ── An explicit stop ends it ─────────────────────────────────────────────────────────────
    m.stopped(.explicit)
    check("an explicit stop turns the mode OFF", !m.isOn)
    check("…then an arrow plans nothing again", !m.shouldSchedule(isDirectory: false))
    check("…and a wait that was already planned does not go ahead",
          !m.shouldStart(cancelled: false, cursorID: me, nodeID: me, isDirectory: false))

    // ── A whole walk, in the order the view model does it ───────────────────────────────────
    var w = A.Mode()
    w.started(byHand: true)                  // the second click on a file
    w.stopped(.automatic)                    // the end of the file
    check("walk: after the natural end, an arrow plans the next file", w.shouldSchedule(isDirectory: false))
    w.stopped(.automatic)                    // the cursor changes row (focusCursor)
    check("walk: folders are passed over, the mode goes on", !w.shouldSchedule(isDirectory: true) && w.isOn)
    w.started(byHand: false)                 // the auto start
    w.stopped(.explicit)                     // a folder is left (navigate), or the tab (onDisappear)
    check("walk: leaving the folder or the tab ends it", !w.isOn)
    w.started(byHand: true)
    check("walk: a new launch by the hand turns it on again", w.isOn)

    // ── The stop timer and its generation ──────────────────────────────────────────────────
    check("a timer armed in generation 3 cuts generation 3", A.timerApplies(armed: 3, current: 3))
    check("a STALE timer (armed in 3, the preview is now 4) cuts nothing", !A.timerApplies(armed: 3, current: 4))
    check("a timer armed in the future is not this one either", !A.timerApplies(armed: 5, current: 4))

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

    // ── The end of a preview whose head was placed by a click or a scrub ───────────────────
    check("head inside I–O: it ends at O", near(A.endPoint(from: 2, pointO: 5, playerDuration: 9), 5))
    check("head inside I–O: remaining = O - head", near(A.remaining(from: 2, pointO: 5, playerDuration: 9), 3))
    check("head BEFORE I (outside I–O): it still ends at O", near(A.endPoint(from: 0.5, pointO: 5, playerDuration: 9), 5))
    check("head PAST O: it ends at the end of the file", near(A.endPoint(from: 6, pointO: 5, playerDuration: 9), 9))
    check("head PAST O: remaining = file end - head", near(A.remaining(from: 6, pointO: 5, playerDuration: 9), 3))
    check("head exactly ON O: the end of the file (O is no longer ahead)",
          near(A.endPoint(from: 5, pointO: 5, playerDuration: 9), 9))
    check("head at the very end: nothing left", near(A.remaining(from: 9, pointO: 5, playerDuration: 9), 0))
    check("head beyond the file: never negative", near(A.remaining(from: 12, pointO: 5, playerDuration: 9), 0))
    check("the point-I forms agree with the head forms",
          near(A.remaining(pointI: 1, pointO: 3.5, playerDuration: 9), A.remaining(from: 1, pointO: 3.5, playerDuration: 9))
          && near(A.endPoint(pointI: 2, pointO: 2, playerDuration: 6), A.endPoint(from: 2, pointO: 2, playerDuration: 6)))

    // ── Where a point of the waveform lands in the file ────────────────────────────────────
    check("headTime: the left edge is 0", near(A.headTime(x: 0, width: 200, duration: 10), 0))
    check("headTime: the middle is half the duration", near(A.headTime(x: 100, width: 200, duration: 10), 5))
    check("headTime: the right edge is the duration", near(A.headTime(x: 200, width: 200, duration: 10), 10))
    check("headTime: left of the waveform clamps to 0", near(A.headTime(x: -30, width: 200, duration: 10), 0))
    check("headTime: right of the waveform clamps to the duration", near(A.headTime(x: 999, width: 200, duration: 10), 10))
    check("headTime: an empty waveform or an unknown duration is 0",
          near(A.headTime(x: 50, width: 0, duration: 10), 0) && near(A.headTime(x: 50, width: 200, duration: 0), 0))
    check("headTime: NaN is 0", near(A.headTime(x: .nan, width: 200, duration: 10), 0))

    // ── Previous / next: folders are passed over ───────────────────────────────────────────
    //                          0      1     2      3      4     5
    let rows: [Bool] = [true, false, true, true, false, false]    // dir, file, dir, dir, file, file
    check("next from a file skips the folders in between", A.adjacentFileIndex(isDirectory: rows, from: 1, step: 1) == 4)
    check("previous from a file skips the folders in between", A.adjacentFileIndex(isDirectory: rows, from: 4, step: -1) == 1)
    check("next from the file right before another is that file", A.adjacentFileIndex(isDirectory: rows, from: 4, step: 1) == 5)
    check("next from the last file: nowhere", A.adjacentFileIndex(isDirectory: rows, from: 5, step: 1) == nil)
    check("previous from the first file (only a folder above): nowhere", A.adjacentFileIndex(isDirectory: rows, from: 1, step: -1) == nil)
    check("a current row that does not exist: nowhere", A.adjacentFileIndex(isDirectory: rows, from: 9, step: 1) == nil)
    check("a zero step: nowhere", A.adjacentFileIndex(isDirectory: rows, from: 1, step: 0) == nil)
    check("a list of folders only: nowhere", A.adjacentFileIndex(isDirectory: [true, true, false], from: 2, step: -1) == nil)

    print("\n\(total - fails.count)/\(total) ok")
    exit(fails.isEmpty ? 0 : 1)
} }

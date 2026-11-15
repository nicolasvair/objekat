// The carve-up of a block under the selection tool (`Shared/ClipEditZone.swift`), asserted with no
// screen — above all the share-out of an EDGE between the loop marker that sits on it and the
// trim / resize handle (the upper half is the marker's, the lower half the edge's).
//
//     swiftc -parse-as-library ../objekat/Shared/ClipEditZone.swift test_clip_edit_zone.swift -o /tmp/zones && /tmp/zones
//
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation

var fails: [String] = []
var total = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    total += 1
    if ok { print("ok    " + label) } else { fails.append(label); print("FAIL  \(label)  \(detail)") }
}

let bw = 400.0, bh = 60.0, hw = 40.0
let upperY = 10.0, lowerY = 45.0

func zone(_ x: Double, _ y: Double, inPx: Double? = nil, outPx: Double? = nil,
          fi: Double = 0, fo: Double = 0) -> ClipEditZone {
    ClipEditZone.resolve(localX: x, localY: y, blockWidth: bw, blockHeight: bh, handleW: hw,
                         fadeInPx: fi, fadeOutPx: fo, loopInPx: inPx, loopOutPx: outPx)
}

@main struct Runner { static func main() {
    // ── No loop: the carve-up is what it always was ────────────────────────────────────────────
    check("no loop: upper left = fade in", zone(2, upperY) == .fadeIn)
    check("no loop: lower left = trim", zone(2, lowerY) == .trimLeft)
    check("no loop: lower right = resize", zone(398, lowerY) == .resizeRight)
    check("no loop: centre upper = time select, lower = move",
          zone(200, upperY) == .timeSelect && zone(200, lowerY) == .move)

    // ── A marker clear of the edges keeps its FULL height ──────────────────────────────────────
    check("IN at 100 px: upper", zone(102, upperY, inPx: 100) == .loopIn)
    check("IN at 100 px: lower too", zone(102, lowerY, inPx: 100) == .loopIn)
    check("OUT at 300 px: both halves", zone(298, upperY, outPx: 300) == .loopOut && zone(298, lowerY, outPx: 300) == .loopOut)
    check("IN at 100 px: 6 px away is not the marker", zone(106.5, lowerY, inPx: 100) != .loopIn)

    // ── IN ON the left edge: the marker keeps the upper half, the edge the lower ──────────────
    check("IN at 0: upper half grabs the marker", zone(2, upperY, inPx: 0) == .loopIn)
    check("IN at 0: lower half trims", zone(2, lowerY, inPx: 0) == .trimLeft)
    check("IN at 0: the handle's own span is unchanged below", zone(30, lowerY, inPx: 0) == .trimLeft)
    check("IN at 3 px (within the tolerance of the edge): lower half trims", zone(4, lowerY, inPx: 3) == .trimLeft)
    check("IN at 3 px: upper half is the marker", zone(4, upperY, inPx: 3) == .loopIn)
    check("IN at -25 px (outside the block): the edge is the edge", zone(2, lowerY, inPx: -25) == .trimLeft
          && zone(2, upperY, inPx: -25) == .fadeIn)

    // ── OUT ON the right edge ────────────────────────────────────────────────────────────────
    check("OUT at bw: upper half grabs the marker", zone(398, upperY, outPx: bw) == .loopOut)
    check("OUT at bw: lower half resizes", zone(398, lowerY, outPx: bw) == .resizeRight)
    check("OUT at bw - 4: lower half resizes", zone(397, lowerY, outPx: bw - 4) == .resizeRight)

    // ── Both markers, a loop whose period is the block ───────────────────────────────────────
    check("IN 0 / OUT bw: left lower = trim, right lower = resize",
          zone(2, lowerY, inPx: 0, outPx: bw) == .trimLeft && zone(398, lowerY, inPx: 0, outPx: bw) == .resizeRight)
    check("IN 0 / OUT bw: left upper = IN, right upper = OUT",
          zone(2, upperY, inPx: 0, outPx: bw) == .loopIn && zone(398, upperY, inPx: 0, outPx: bw) == .loopOut)
    check("IN 0 / OUT 150: the OUT in the middle keeps its full height", zone(150, lowerY, inPx: 0, outPx: 150) == .loopOut)

    print("\n\(total) assertions, \(fails.count) failed")
    print(fails.isEmpty ? "ALL PASS" : "FAILED:\n  " + fails.joined(separator: "\n  "))
    exit(fails.isEmpty ? 0 : 1)
} }

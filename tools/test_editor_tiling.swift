// Laying out several plugin editors opened together — the geometry behind it, asserted with no
// screen. `EditorTiling` (`objekat/Shared/EditorTiling.swift`) has no AppKit behind it.
//
//     swiftc -parse-as-library \
//         ../objekat/Shared/EditorTiling.swift test_editor_tiling.swift \
//         -o /tmp/editortiling && /tmp/editortiling
//
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation
import CoreGraphics

var fails: [String] = []
var total = 0

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    total += 1
    if ok { print("ok    " + label) }
    else { fails.append(label); print("FAIL  \(label)  \(detail)") }
}

func pt(_ p: CGPoint, _ x: CGFloat, _ y: CGFloat) -> Bool { abs(p.x - x) < 0.001 && abs(p.y - y) < 0.001 }

func inside(_ o: CGPoint, _ s: CGSize, _ a: CGRect) -> Bool {
    o.x >= a.minX - 0.001 && o.x + s.width <= a.maxX + 0.001
        && o.y >= a.minY - 0.001 && o.y + s.height <= a.maxY + 0.001
}

@main
enum EditorTilingTest {
  static func main() {
    // A screen's visible frame, AppKit coordinates (origin bottom-left, a Dock below).
    let area = CGRect(x: 0, y: 80, width: 1600, height: 900)   // maxX 1600, maxY 980

    // MARK: - Everything fits → rows

    let small = [CGSize](repeating: CGSize(width: 500, height: 400), count: 4)
    let r = EditorTiling.layout(sizes: small, in: area)
    check("4 small: rows", r.mode == .rows)
    check("rows: 1st at top-left", pt(r.origins[0], 0, 580))
    check("rows: 2nd beside, 8 px gap", pt(r.origins[1], 508, 580))
    check("rows: 3rd beside", pt(r.origins[2], 1016, 580))
    check("rows: 4th on the next row", pt(r.origins[3], 0, 172), "\(r.origins[3])")
    var overlap = false
    for i in 0..<4 { for j in (i+1)..<4 {
        let a = CGRect(origin: r.origins[i], size: small[i]), b = CGRect(origin: r.origins[j], size: small[j])
        if a.intersects(b) { overlap = true }
    } }
    check("rows: no overlap", !overlap)
    check("rows: all inside", zip(r.origins, small).allSatisfy { inside($0, $1, area) })
    check("one window: rows, top-left", {
        let l = EditorTiling.layout(sizes: [CGSize(width: 800, height: 600)], in: area)
        return l.mode == .rows && pt(l.origins[0], 0, 380)
    }())

    // MARK: - 4 big windows → 4 corners

    let big = [CGSize](repeating: CGSize(width: 1000, height: 700), count: 4)
    let c = EditorTiling.layout(sizes: big, in: area)
    check("4 big: corners", c.mode == .corners)
    check("corner 1 top-left", pt(c.origins[0], 0, 280), "\(c.origins[0])")
    check("corner 2 top-right", pt(c.origins[1], 600, 280), "\(c.origins[1])")
    check("corner 3 bottom-left", pt(c.origins[2], 0, 80), "\(c.origins[2])")
    check("corner 4 bottom-right", pt(c.origins[3], 600, 80), "\(c.origins[3])")
    check("corners: all inside", zip(c.origins, big).allSatisfy { inside($0, $1, area) })

    // The whole batch flips: 3 small ones that fit + 1 too big → corners for all four.
    let mixed = small.prefix(3) + [CGSize(width: 1700, height: 300)]
    check("one misfit flips the whole batch", EditorTiling.layout(sizes: Array(mixed), in: area).mode == .corners)
    // A rows layout is prefix-stable (an arrival never moves the earlier ones).
    let r3 = EditorTiling.layout(sizes: Array(small.prefix(3)), in: area)
    check("rows prefix-stable", r3.origins == Array(r.origins.prefix(3)))

    // MARK: - 7 windows → piles, 28 px towards the centre

    let seven = [CGSize](repeating: CGSize(width: 900, height: 600), count: 7)
    let p = EditorTiling.layout(sizes: seven, in: area)
    check("7: corners", p.mode == .corners)
    check("5th: top-left, +28 / -28", pt(p.origins[4], 28, 380 - 28), "\(p.origins[4])")
    check("6th: top-right, -28 / -28", pt(p.origins[5], 700 - 28, 380 - 28), "\(p.origins[5])")
    check("7th: bottom-left, +28 / +28", pt(p.origins[6], 28, 80 + 28), "\(p.origins[6])")
    check("7: all inside", zip(p.origins, seven).allSatisfy { inside($0, $1, area) })
    // 9 → depth 2 in the top-left corner.
    let nine = [CGSize](repeating: CGSize(width: 900, height: 600), count: 9)
    check("9th: depth 2", pt(EditorTiling.layout(sizes: nine, in: area).origins[8], 56, 380 - 56))

    // Stacking: no title bar covered. Top-left pile: 1 behind 5 (5 is lower → in front);
    // bottom-left pile: 7 behind 3 (7 is higher → behind).
    let rank = Dictionary(uniqueKeysWithValues: p.backToFront.enumerated().map { ($1, $0) })
    check("top corner: deeper in front", rank[4]! > rank[0]!)
    check("bottom corner: deeper behind", rank[6]! < rank[2]!)
    check("backToFront is a permutation", Set(p.backToFront) == Set(0..<7))
    // Every title bar (28 px strip at the top) not entirely covered by a window in front of it.
    var allBarsSeen = true
    for (pos, i) in p.backToFront.enumerated() {
        let bar = CGRect(x: p.origins[i].x, y: p.origins[i].y + seven[i].height - 28,
                         width: seven[i].width, height: 28)
        for j in p.backToFront[(pos+1)...] {
            if CGRect(origin: p.origins[j], size: seven[j]).contains(bar) { allBarsSeen = false }
        }
    }
    check("no title bar entirely covered", allBarsSeen)

    // MARK: - Bigger than the screen → title bar on screen

    let huge = CGSize(width: 2000, height: 1200)
    let h = EditorTiling.layout(sizes: [huge, huge, huge, huge, huge], in: area)
    check("huge: corners", h.mode == .corners)
    for (i, o) in h.origins.enumerated() {
        check("huge #\(i+1): top edge at the area's top", abs(o.y + huge.height - area.maxY) < 0.001, "\(o)")
        check("huge #\(i+1): left edge at the area's left", abs(o.x - area.minX) < 0.001, "\(o)")
    }
    // Only too tall: keeps its corner's side horizontally, title bar on screen.
    let tall = CGSize(width: 400, height: 1200)
    let t = EditorTiling.layout(sizes: [tall, tall, tall, tall], in: area)
    check("too tall, bottom-right: right edge kept", abs(t.origins[3].x + 400 - area.maxX) < 0.001)
    check("too tall, bottom-right: title bar on screen", abs(t.origins[3].y + 1200 - area.maxY) < 0.001)
    // A deep pile never pushes a window off screen.
    let many = [CGSize](repeating: CGSize(width: 900, height: 600), count: 80)
    check("80 windows: all inside", zip(EditorTiling.layout(sizes: many, in: area).origins, many)
        .allSatisfy { inside($0, $1, area) })

    print("\n\(total - fails.count)/\(total) passed")
    exit(fails.isEmpty ? 0 : 1)
  }
}

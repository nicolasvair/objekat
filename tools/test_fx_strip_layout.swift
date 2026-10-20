// The FX tool's strip, its geometry alone (objekat/Timeline/FXStripLayout.swift): the boxes in one
// row in chain order, a bin's frame around its boxes, where the strip goes against its block, and
// the rule that keeps it up while the pointer travels from the block onto it.
//
//     cd tools && swiftc -parse-as-library \
//         ../objekat/Timeline/FXStripLayout.swift test_fx_strip_layout.swift \
//         -o /tmp/fxstrip && /tmp/fxstrip
//
// Exit: 0 if every assertion passes, 1 otherwise.

import CoreGraphics
import Foundation

typealias L = FXStripLayout

var passed = 0
var failed: [String] = []
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    if ok { passed += 1; print("ok    \(label)") } else { failed.append(label); print("FAIL  \(label)  \(detail)") }
}

func entry(_ kind: FXStripEntry.Kind = .plugin, bin: Int? = nil, on: Bool = true) -> FXStripEntry {
    FXStripEntry(id: UUID(), kind: kind, name: "x", isEnabled: on, bin: bin)
}

func testRow() {
    let m = FXStripModel(entries: [entry(.instrument), entry(), entry(.gainStage), entry(.rack(branches: 2))])
    let r = L.layout(m)
    check("one box per entry", r.boxes.count == 4)
    check("boxes in chain order, left to right",
          zip(r.boxes, r.boxes.dropFirst()).allSatisfy { $0.rect.maxX < $1.rect.minX && $0.entry < $1.entry })
    check("one row: every box at the same y", Set(r.boxes.map { $0.rect.minY }).count == 1)
    check("the gap between two boxes", r.boxes[1].rect.minX - r.boxes[0].rect.maxX == L.gap)
    check("no bin = no frame and no header band", r.bins.isEmpty && r.boxes[0].rect.minY == L.padding)
    check("the size wraps the boxes with the padding",
          r.size.width == r.boxes.last!.rect.maxX + L.padding
          && r.size.height == L.boxHeight + 2 * L.padding, "\(r.size)")
    check("toggle on instrument and plugin only",
          m.entries.map { $0.hasToggle } == [true, true, false, false])
    check("editor on instrument and plugin only",
          m.entries.map { $0.opensEditor } == [true, true, false, false])
}

func testBins() {
    // trunk, bin 0 (two boxes), bin 1 (one box), trunk
    let m = FXStripModel(entries: [entry(), entry(bin: 0), entry(bin: 0), entry(bin: 1), entry()],
                         bins: [FXStripBin(id: UUID(), name: "A", isDetached: false),
                                FXStripBin(id: UUID(), name: "B", isDetached: true)])
    let r = L.layout(m)
    check("one frame per run of a bin", r.bins.map { $0.bin } == [0, 1])
    let f0 = r.bins[0].rect, f1 = r.bins[1].rect
    check("a frame holds its boxes with binPad",
          f0.minX == r.boxes[1].rect.minX - L.binPad && f0.maxX == r.boxes[2].rect.maxX + L.binPad,
          "\(f0) \(r.boxes[1].rect) \(r.boxes[2].rect)")
    check("a frame holds its boxes vertically, with a header band above",
          f0.minY == L.padding && f0.maxY == r.boxes[1].rect.maxY + L.binPad
          && r.boxes[1].rect.minY - f0.minY == L.binHeader + L.binPad)
    check("frames do not touch each other nor the trunk boxes",
          r.boxes[0].rect.maxX < f0.minX && f0.maxX < f1.minX && f1.maxX < r.boxes[4].rect.minX)
    check("frame to box gap = gap", f0.minX - r.boxes[0].rect.maxX == L.gap
          && r.boxes[4].rect.minX - f1.maxX == L.gap)
    check("with a bin every box shares the header band's y", Set(r.boxes.map { $0.rect.minY }).count == 1)
    check("the strip wraps the frames",
          r.size.width == r.boxes[4].rect.maxX + L.padding && r.size.height == f0.maxY + L.padding, "\(r.size)")
    let only = L.layout(FXStripModel(entries: [entry(bin: 0)], bins: m.bins))
    check("a strip that is one bin starts its frame at the padding",
          only.bins.first?.rect.minX == L.padding && only.size.width == only.bins[0].rect.maxX + L.padding)
    // Two adjacent different bins.
    let two = L.layout(FXStripModel(entries: [entry(bin: 0), entry(bin: 1)], bins: m.bins))
    check("two adjacent bins = two frames, a gap apart",
          two.bins.count == 2 && two.bins[1].rect.minX - two.bins[0].rect.maxX == L.gap)
}

func testEmpty() {
    let r = L.layout(FXStripModel())
    check("empty strip: no box, one box's room", r.boxes.isEmpty && r.size.width == L.emptyWidth + 2 * L.padding)
}

func testPlacement() {
    let visible = CGRect(x: 0, y: 30, width: 1000, height: 500)
    let size = CGSize(width: 200, height: 34)
    let block = CGRect(x: 100, y: 200, width: 600, height: 60)
    let p = L.placement(size: size, block: block, anchorX: 400, visible: visible)
    check("above the block, overlapping its top by `overlap`",
          p.maxY == block.minY + L.overlap && p.size == size, "\(p)")
    check("centred on the anchor", p.midX == 400)
    let left = L.placement(size: size, block: block, anchorX: 90, visible: visible)
    check("kept inside the block on the left", left.minX == block.minX)
    let right = L.placement(size: size, block: block, anchorX: 690, visible: visible)
    check("kept inside the block on the right", right.maxX == block.maxX)
    let narrow = CGRect(x: 100, y: 200, width: 50, height: 60)
    let n = L.placement(size: size, block: narrow, anchorX: 120, visible: visible)
    check("a block narrower than the strip: the strip starts at its left edge", n.minX == narrow.minX)
    let edge = CGRect(x: 900, y: 200, width: 50, height: 60)
    let e = L.placement(size: size, block: edge, anchorX: 920, visible: visible)
    check("…but never past the visible right edge", e.maxX == visible.maxX, "\(e)")
    let scrolled = CGRect(x: -300, y: 200, width: 400, height: 60)
    let s = L.placement(size: size, block: scrolled, anchorX: -250, visible: visible)
    check("never before the visible left edge", s.minX == visible.minX, "\(s)")
    let top = CGRect(x: 100, y: 40, width: 600, height: 60)
    let t = L.placement(size: size, block: top, anchorX: 400, visible: visible)
    check("no room above: below the block, overlapping its bottom by `overlap`",
          t.minY == top.maxY - L.overlap, "\(t)")
    let exact = CGRect(x: 100, y: visible.minY + size.height - L.overlap, width: 600, height: 60)
    check("exactly enough room above: above",
          L.placement(size: size, block: exact, anchorX: 400, visible: visible).minY == visible.minY)
}

func testKeep() {
    let block = CGRect(x: 100, y: 200, width: 600, height: 60)
    let strip = L.placement(size: CGSize(width: 200, height: 34), block: block, anchorX: 400,
                            visible: CGRect(x: 0, y: 0, width: 1000, height: 600))
    check("on the block: kept", L.keeps(CGPoint(x: 150, y: 250), overlay: strip, block: block))
    check("on the strip: kept", L.keeps(CGPoint(x: strip.midX, y: strip.minY + 2), overlay: strip, block: block))
    check("just outside the strip, within the margin: kept",
          L.keeps(CGPoint(x: strip.maxX + L.keepMargin - 0.5, y: strip.midY), overlay: strip, block: block))
    check("past the margin: let go",
          !L.keeps(CGPoint(x: strip.maxX + L.keepMargin + 1, y: strip.minY + 1), overlay: strip, block: block))
    // The path from the block straight up onto the strip never leaves both.
    var continuous = true
    for y in stride(from: block.midY, through: strip.minY + 1, by: -0.5)
    where !L.keeps(CGPoint(x: strip.midX, y: y), overlay: strip, block: block) { continuous = false }
    check("the way up from the block onto the strip never leaves both", continuous)
    check("elsewhere: let go", !L.keeps(CGPoint(x: 900, y: 500), overlay: strip, block: block))
}

func testBoxHit() {
    let r = L.layout(FXStripModel(entries: [entry(), entry()]))
    check("a point in a box finds it", L.box(at: CGPoint(x: r.boxes[1].rect.midX, y: r.boxes[1].rect.midY), in: r)?.entry == 1)
    check("the gap finds nothing", L.box(at: CGPoint(x: r.boxes[0].rect.maxX + L.gap / 2, y: r.boxes[0].rect.midY), in: r) == nil)
}

@main
struct Main {
    static func main() {
        testRow(); testBins(); testEmpty(); testPlacement(); testKeep(); testBoxHit()
        print("\n\(passed)/\(passed + failed.count) passed")
        if !failed.isEmpty { print("FAILED: \(failed)"); exit(1) }
    }
}

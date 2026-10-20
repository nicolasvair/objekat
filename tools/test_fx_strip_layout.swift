// The FX tool's mini signal view, its geometry alone (objekat/Timeline/FXStripLayout.swift): boxes
// left to right in chain order joined by wires, a parallel block's branches stacked, an FX link's
// frame, the degradation with the room (labeled → dots → folded dots → "n FX" → nothing), and the
// hit-test the canvas reads (the power zone, the box).
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

func entry(_ kind: FXStripEntry.Kind = .plugin, bin: Int? = nil, on: Bool = true,
           rack: Int? = nil, branch: Int? = nil) -> FXStripEntry {
    FXStripEntry(id: UUID(), kind: kind, name: "Plugin name", isEnabled: on, bin: bin,
                 rack: rack, branch: branch)
}

/// instrument, plugin, gain stage — a plain series.
func plainModel() -> FXStripModel {
    FXStripModel(entries: [entry(.instrument), entry(), entry(.gainStage)], bins: [],
                 root: [.leaf(0), .leaf(1), .leaf(2)])
}

/// plugin, rack[ [A, B], [C], [] ], plugin
func rackModel() -> FXStripModel {
    var e: [FXStripEntry] = [entry()]
    e.append(entry(.rack(branches: 3)))                    // 1
    e.append(entry(rack: 1, branch: 0))                    // 2 A
    e.append(entry(rack: 1, branch: 0))                    // 3 B
    e.append(entry(rack: 1, branch: 1))                    // 4 C
    e.append(entry())                                      // 5
    return FXStripModel(entries: e, bins: [],
                        root: [.leaf(0), .rack(1, [[.leaf(2), .leaf(3)], [.leaf(4)], []]), .leaf(5)])
}

func inside(_ r: CGRect, _ area: CGRect) -> Bool { area.insetBy(dx: -0.5, dy: -0.5).contains(r) }

func testPlain() {
    let area = CGRect(x: 100, y: 50, width: 600, height: 60)
    let r = L.layout(plainModel(), in: area)
    check("plain: labeled with room", r.detail == .labeled, "\(r.detail)")
    check("plain: one box per entry, in chain order",
          r.boxes.map(\.entry) == [0, 1, 2] && zip(r.boxes, r.boxes.dropFirst()).allSatisfy { $0.rect.maxX < $1.rect.minX })
    check("plain: all inside the area", r.boxes.allSatisfy { inside($0.rect, area) } && inside(r.bounds, area))
    check("plain: one row (same centre)", Set(r.boxes.map { $0.rect.midY }).count == 1)
    check("plain: power on instrument and plugin, none on the gain stage",
          r.boxes[0].power != nil && r.boxes[1].power != nil && r.boxes[2].power == nil)
    check("plain: a wire before each box and one after", r.wires.count == 4, "\(r.wires.count)")
    check("plain: boxes capped at the max width", r.boxes.allSatisfy { $0.rect.width <= L.labeledMetrics.maxBox })
    check("plain: centred", abs(r.bounds.midX - area.midX) <= 1)
    // Hit-test.
    let b1 = r.boxes[1]
    let onPower = L.hit(CGPoint(x: b1.power!.midX, y: b1.rect.midY), in: r)
    check("hit: power zone", onPower == L.Hit(entry: 1, onPower: true), "\(String(describing: onPower))")
    let onBody = L.hit(CGPoint(x: b1.rect.maxX - 2, y: b1.rect.midY), in: r)
    check("hit: box body", onBody == L.Hit(entry: 1, onPower: false))
    check("hit: between boxes, nothing",
          L.hit(CGPoint(x: (r.boxes[0].rect.maxX + r.boxes[1].rect.minX) / 2, y: b1.rect.midY), in: r) == nil)
}

func testRack() {
    let area = CGRect(x: 0, y: 0, width: 700, height: 80)
    let r = L.layout(rackModel(), in: area)
    check("rack: labeled with room", r.detail == .labeled, "\(r.detail)")
    let by = Dictionary(uniqueKeysWithValues: r.boxes.map { ($0.entry, $0.rect) })
    check("rack: the carrier is not a box", by[1] == nil)
    check("rack: its plugins are boxes", by[2] != nil && by[3] != nil && by[4] != nil)
    check("rack: a branch's plugins on ONE row", by[2]!.midY == by[3]!.midY && by[2]!.maxX < by[3]!.minX)
    check("rack: branches STACKED", by[4]!.minY >= by[2]!.maxY)
    check("rack: before and after the block on the trunk's centre",
          by[0]!.midY == by[5]!.midY && by[0]!.maxX < by[2]!.minX && by[5]!.minX > by[3]!.maxX)
    check("rack: everything inside", r.boxes.allSatisfy { inside($0.rect, area) })
    let verticals = r.wires.filter { $0.count == 2 && $0[0].x == $0[1].x && $0[0].y != $0[1].y }
    check("rack: a split and a join (vertical wires)", verticals.count == 2, "\(verticals.count)")
    check("rack: leaves of a rack carry power", r.boxes.first { $0.entry == 4 }?.power != nil)
}

func testDegradation() {
    let m = rackModel()
    // Tall enough for dots with stacked branches but not labels.
    let dots = L.layout(m, in: CGRect(x: 0, y: 0, width: 400, height: 28))
    check("degrade: short → dots, branches still stacked", dots.detail == .dots, "\(dots.detail)")
    check("degrade: dots have no power zone", dots.boxes.allSatisfy { $0.power == nil })
    // Too short for stacked rows: folded.
    let folded = L.layout(m, in: CGRect(x: 0, y: 0, width: 400, height: 12))
    check("degrade: very short → racks folded", folded.detail == .foldedDots, "\(folded.detail)")
    check("degrade: the folded rack is one box", folded.boxes.contains { $0.entry == 1 && $0.folded }
          && !folded.boxes.contains { $0.entry == 2 })
    // Too narrow for dots: count.
    let count = L.layout(m, in: CGRect(x: 0, y: 0, width: 30, height: 20))
    check("degrade: narrow → n FX", count.detail == .count && count.textRect != nil, "\(count.detail)")
    check("degrade: nothing at all in a sliver", L.layout(m, in: CGRect(x: 0, y: 0, width: 10, height: 4)).detail == .none)
    check("count: every box but the carrier", m.plugInCount == 5)
    // Wide but short: labels in a single-row chain.
    let one = L.layout(plainModel(), in: CGRect(x: 0, y: 0, width: 400, height: 20))
    check("degrade: a single-row chain keeps labels at 20 px", one.detail == .labeled, "\(one.detail)")
    // Narrow single row: dots.
    let narrow = L.layout(plainModel(), in: CGRect(x: 0, y: 0, width: 80, height: 30))
    check("degrade: narrow single row → dots", narrow.detail == .dots, "\(narrow.detail)")
    check("degrade: dots inside", narrow.boxes.allSatisfy { inside($0.rect, CGRect(x: 0, y: 0, width: 80, height: 30)) })
}

func testEmptyAndBins() {
    let e = L.layout(FXStripModel(), in: CGRect(x: 0, y: 0, width: 200, height: 30))
    check("empty: the 'no plugins' line", e.detail == .empty && e.textRect != nil)
    check("empty: nothing in a sliver", L.layout(FXStripModel(), in: CGRect(x: 0, y: 0, width: 200, height: 5)).detail == .none)
    let m = FXStripModel(entries: [entry(), entry(bin: 0), entry(bin: 0), entry()],
                         bins: [FXStripBin(id: UUID(), name: "Bin", isDetached: false)],
                         root: [.leaf(0), .leaf(1), .leaf(2), .leaf(3)])
    let r = L.layout(m, in: CGRect(x: 0, y: 0, width: 600, height: 40))
    check("bins: ONE frame around the two boxes of the bin", r.bins.count == 1)
    if let f = r.bins.first {
        check("bins: the frame holds its boxes and not the others",
              f.rect.contains(r.boxes[1].rect) && f.rect.contains(r.boxes[2].rect)
              && !f.rect.intersects(r.boxes[0].rect) && !f.rect.intersects(r.boxes[3].rect))
    }
    let size = L.labeledSize(m)
    let atSize = L.layout(m, in: CGRect(origin: .zero, size: size))
    check("labeledSize: the labeled reading fits exactly there", atSize.detail == .labeled, "\(size) \(atSize.detail)")
}

@main
struct Main {
    static func main() {
        testPlain()
        testRack()
        testDegradation()
        testEmptyAndBins()
        print(failed.isEmpty ? "\nALL PASS (\(passed))" : "\n\(failed.count) FAILED, \(passed) passed")
        exit(failed.isEmpty ? 0 : 1)
    }
}

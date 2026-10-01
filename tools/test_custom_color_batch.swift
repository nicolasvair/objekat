// The two-zone background of a clip with its own colour — the geometry, asserted with no screen.
//
// `CustomColorBatch` is what the batched Canvas draws from (`TimelineView.plainBlocksCanvas`, phase
// 1) and what `SoundBlockView.body` does with a VStack of two `UnevenRoundedRectangle`s: the band is
// 20 % of the block's height, never under 3 pt, never over the block, and band + body tile the block
// with no gap and no overlap.
//
//     swiftc -parse-as-library \
//         ../objekat/Timeline/CustomColorBatch.swift test_custom_color_batch.swift \
//         -o /tmp/ccb && /tmp/ccb
//
// Exit: 0 if every assertion passes, 1 otherwise.

import SwiftUI

var fails: [String] = []
var total = 0

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    total += 1
    if ok { print("ok    " + label) }
    else { fails.append(label); print("FAIL  \(label)  \(detail)") }
}

@main
enum CustomColorBatchTest {
  static func main() {
    // MARK: - The band's height
    check("20 % of a 60 pt block", abs(CustomColorBatch.bandHeight(blockHeight: 60) - 12) < 1e-9)
    check("20 % of a 100 pt block", abs(CustomColorBatch.bandHeight(blockHeight: 100) - 20) < 1e-9)
    check("a 10 pt block: 3 pt floor", abs(CustomColorBatch.bandHeight(blockHeight: 10) - 3) < 1e-9)
    check("a 15 pt block: exactly 3 pt", abs(CustomColorBatch.bandHeight(blockHeight: 15) - 3) < 1e-9)
    check("a 2 pt block: never over the block", abs(CustomColorBatch.bandHeight(blockHeight: 2) - 2) < 1e-9)
    check("a 0 pt block: nothing", CustomColorBatch.bandHeight(blockHeight: 0) == 0)

    // MARK: - One block
    var b = CustomColorBatch()
    let rect = CGRect(x: 100, y: 40, width: 200, height: 60)
    b.add(rect, radius: 4, blockHeight: 60)
    let full = b.full.boundingRect, band = b.band.boundingRect, body = b.body.boundingRect
    check("the whole path is the block", full == rect, "\(full)")
    check("the band starts at the block's top", abs(band.minY - 40) < 1e-6 && abs(band.minX - 100) < 1e-6)
    check("the band is 12 pt tall and full width", abs(band.height - 12) < 1e-6 && abs(band.width - 200) < 1e-6)
    check("the body starts where the band ends", abs(body.minY - 52) < 1e-6, "\(body)")
    check("the body ends at the block's bottom", abs(body.maxY - 100) < 1e-6)
    check("band + body tile the block", abs(band.height + body.height - rect.height) < 1e-6)

    // MARK: - Accumulation
    b.add(CGRect(x: 400, y: 40, width: 50, height: 60), radius: 4, blockHeight: 60)
    check("a second block extends the union to its right edge", abs(b.full.boundingRect.maxX - 450) < 1e-6)
    check("…and the band's too", abs(b.band.boundingRect.maxX - 450) < 1e-6)

    // MARK: - A big radius (an aux) on a short block
    var a = CustomColorBatch()
    a.add(CGRect(x: 0, y: 0, width: 300, height: 60), radius: 20, blockHeight: 60)
    check("radius 20: the band stays inside the block",
          a.band.boundingRect.minY >= -1e-6 && a.band.boundingRect.maxY <= 12 + 1e-6)

    // MARK: - Keys
    let k1 = CustomColorKey(custom: .red, stem: .blue)
    let k2 = CustomColorKey(custom: .red, stem: .blue)
    let k3 = CustomColorKey(custom: .red, stem: .green)
    check("equal colours make one key", k1 == k2 && k1.hashValue == k2.hashValue)
    check("another stem makes another key", k1 != k3)

    print("")
    if fails.isEmpty {
        print("\(total) assertions, all pass")
        exit(0)
    } else {
        print("\(fails.count) FAILED: \(fails.joined(separator: " · "))")
        exit(1)
    }
  }
}

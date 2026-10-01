// The icon chequerboard's tile layout — asserted with no screen.
//
// `GlyphTileDrawing.forEachTile` is what `GlyphTilePattern` (rich) and the batched Canvas both
// walk. The first version drew EVERY tile its loop produced, including those wholly outside the
// block (clipped away afterwards); this one skips them, and the assertions pin that what is skipped
// is invisible and what is kept is where the original put it.
//
//     swiftc -parse-as-library \
//         ../objekat/Timeline/GlyphTileDrawing.swift test_glyph_tile_drawing.swift \
//         -o /tmp/gtd && /tmp/gtd
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

func near(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool { abs(a - b) < eps }

func tiles(_ size: CGSize, tile: CGFloat = 30, glyph: CGFloat = 17,
           visibleX: ClosedRange<Double>? = nil) -> [CGPoint] {
    var out: [CGPoint] = []
    GlyphTileDrawing.forEachTile(size: size, tile: tile, glyphSize: glyph, visibleX: visibleX) { out.append($0) }
    return out
}

/// The ORIGINAL loop (GlyphTilePattern before the extraction), every tile it produced.
func originalTiles(_ size: CGSize, tile: CGFloat, glyph: CGFloat) -> [CGPoint] {
    var out: [CGPoint] = []
    var row = 0
    var y: CGFloat = tile / 2
    while y < size.height + tile {
        let xOffset: CGFloat = (row % 2 == 0) ? 0 : tile / 2
        var x = tile / 2 + xOffset
        while x < size.width + tile {
            out.append(CGPoint(x: x, y: y))
            x += tile
        }
        y += tile
        row += 1
    }
    return out
}

@main
enum GlyphTileDrawingTest {
  static func main() {
    let size = CGSize(width: 300, height: 100)

    // MARK: - Layout
    let t = tiles(size)
    check("the first tile is centred half a tile in", near(t[0].x, 15) && near(t[0].y, 15))
    check("tiles are one tile apart along a row", near(t[1].x - t[0].x, 30))
    let row2 = t.filter { near($0.y, 45) }
    check("odd rows are shifted by half a tile", near(row2[0].x, 30), "\(row2.first as Any)")
    check("rows are one tile apart", Set(t.map { $0.y }).sorted() == [15, 45, 75, 105])

    // MARK: - Only invisible tiles are skipped
    let reach = GlyphTileDrawing.reach(glyphSize: 17)
    let orig = originalTiles(size, tile: 30, glyph: 17)
    let kept = Set(t.map { "\($0.x),\($0.y)" })
    let dropped = orig.filter { !kept.contains("\($0.x),\($0.y)") }
    check("every tile kept was in the original", t.allSatisfy { p in orig.contains { $0 == p } })
    check("every tile dropped lies wholly outside the block",
          dropped.allSatisfy { $0.x - reach >= size.width || $0.y - reach >= size.height },
          "\(dropped)")
    check("the original's overhanging tiles are the ones dropped", dropped.count == orig.count - t.count)
    check("a tile reaching into the block is kept", t.contains { near($0.x, 285) && near($0.y, 15) })

    // MARK: - A narrow block (a zoomed-out aux)
    let narrow = tiles(CGSize(width: 2.5, height: 100))
    check("a 2.5 px block keeps at most its first column", Set(narrow.map { $0.x }).count <= 2)
    let none = tiles(CGSize(width: 0, height: 100))
    check("a zero-width block has no tiles", none.isEmpty)

    // MARK: - The window
    let wide = CGSize(width: 3000, height: 60)
    let all = tiles(wide)
    let win = tiles(wide, visibleX: 1000...1200)
    check("a window keeps the tiles whose glyph reaches it",
          win.allSatisfy { $0.x + reach >= 1000 && $0.x - reach <= 1200 } && !win.isEmpty)
    check("…and all of them",
          win.count == all.filter { $0.x + reach >= 1000 && $0.x - reach <= 1200 }.count)
    check("a window past the block has no tile", tiles(wide, visibleX: 5000...6000).isEmpty)

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

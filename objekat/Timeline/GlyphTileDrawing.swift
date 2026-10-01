import SwiftUI

// The icon chequerboard of a block with no waveform (a "receives" aux, an infinite bus): one glyph
// repeated in staggered rows (odd rows shifted by half a tile, the first row centred half a tile
// down). ONE definition for the rich `GlyphTilePattern` and for the batched Canvas.
//
// What the first version did, and this one does not: it built the glyph's `Text` and handed it to
// `ctx.draw` once PER TILE, so every draw re-resolved the symbol (font lookup, layout, rasterisation)
// — a few dozen times per block per frame. The glyph is resolved ONCE and kept across frames
// (`GlyphResolveCache`, the same precedent as `ToolOverlayResolveCache`), and a tile whose glyph
// lies wholly outside the block (or outside the window being drawn) is not drawn at all.

/// The resolved glyphs, kept across frames. The colour is baked into the text before it is resolved
/// (as `CanvasLabelCache` does for the labels) and is part of the key: stems and custom colours are
/// a few dozen at most.
nonisolated final class GlyphResolveCache: @unchecked Sendable {
    static let shared = GlyphResolveCache()
    /// A handful of (icon, size, colour) triples are ever asked for; the cap is only a safety net.
    static let capacity = 128

    private struct Key: Hashable {
        let name: String
        let color: Color
        let size: Int       // point size × 10
        let scale: Int      // display scale × 100
    }

    private let lock = NSLock()
    private var glyphs: [Key: GraphicsContext.ResolvedText] = [:]

    var entryCount: Int { lock.lock(); defer { lock.unlock() }; return glyphs.count }

    func removeAll() { lock.lock(); defer { lock.unlock() }; glyphs.removeAll(keepingCapacity: true) }

    /// The SF symbol `name` at `size` pt, semibold, in `color`, as text (so it keeps the rich view's
    /// rendering).
    func glyph(_ name: String, size: CGFloat, color: Color,
               in ctx: GraphicsContext) -> GraphicsContext.ResolvedText {
        let key = Key(name: name, color: color, size: Int((size * 10).rounded()),
                      scale: Int((ctx.environment.displayScale * 100).rounded()))
        lock.lock()
        if let hit = glyphs[key] { lock.unlock(); return hit }
        lock.unlock()
        // Resolved OUTSIDE the lock: it is the slow part and needs nothing the lock guards.
        let resolved = ctx.resolve(Text(Image(systemName: name))
            .font(.system(size: size, weight: .semibold))
            .foregroundColor(color))
        lock.lock(); defer { lock.unlock() }
        if glyphs.count >= Self.capacity { glyphs.removeAll(keepingCapacity: true) }
        glyphs[key] = resolved
        return resolved
    }
}

nonisolated enum GlyphTileDrawing {
    /// How far from a tile's centre its glyph can reach, with room to spare for the symbol's own
    /// bounds (a 17 pt symbol is ~19 pt wide): a tile whose centre is further than this from the
    /// block is invisible.
    static func reach(glyphSize: CGFloat) -> Double { Double(glyphSize) * 0.6 }

    /// The tile centres of a block `size` wide and tall, in the block's own coordinates, bounded to
    /// `visibleX` (nil = no bound), in the order the rich view drew them (row by row).
    static func forEachTile(size: CGSize, tile: CGFloat, glyphSize: CGFloat,
                            visibleX: ClosedRange<Double>? = nil, _ body: (CGPoint) -> Void) {
        guard tile > 0, size.width > 0, size.height > 0 else { return }
        let reach = reach(glyphSize: glyphSize)
        var row = 0
        var y: Double = Double(tile) / 2
        while y < Double(size.height) + Double(tile) {
            if y - reach < Double(size.height) {
                let stagger: Double = (row % 2 == 0) ? 0 : Double(tile) / 2
                var x = Double(tile) / 2 + stagger
                while x < Double(size.width) + Double(tile) {
                    if x - reach < Double(size.width) {
                        if let v = visibleX {
                            if x + reach >= v.lowerBound && x - reach <= v.upperBound { body(CGPoint(x: x, y: y)) }
                        } else {
                            body(CGPoint(x: x, y: y))
                        }
                    }
                    x += Double(tile)
                }
            }
            y += Double(tile)
            row += 1
        }
    }

    /// Draws the chequerboard into `ctx`, whose origin is the block's top-left corner. The caller
    /// clips to the block's shape.
    static func draw(into ctx: GraphicsContext, size: CGSize, color: Color, tile: CGFloat,
                     glyphSize: CGFloat, iconName: String, visibleX: ClosedRange<Double>? = nil) {
        let glyph = GlyphResolveCache.shared.glyph(iconName, size: glyphSize, color: color, in: ctx)
        forEachTile(size: size, tile: tile, glyphSize: glyphSize, visibleX: visibleX) { p in
            ctx.draw(glyph, at: p)
        }
    }
}

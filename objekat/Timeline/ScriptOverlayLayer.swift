import SwiftUI

// MARK: - What a script shows over the objects

/// The layer a third-party script draws on — words and coloured zones over an object — as ONE
/// Canvas laid above the blocks, at the same place and for the same reason as
/// `ObjectMarkersOverlay`: the timeline draws its blocks by three different paths (rich views,
/// group views, a batched Canvas past a hundred objects), and a layer written once here covers all
/// of them, blocks left as the pure presentation they are.
///
/// It reads only the lane entries, the store and the scroll. Only objects that HAVE an overlay are
/// looked at, and for each only what falls in the visible stretch of time — a binary search in the
/// sorted arrays, never a walk through thousands of words per frame.
///
/// PURE PRESENTATION: it takes no hit (`allowsHitTesting(false)` by the caller) — a script's
/// layer must never stand between the hand and a block.
struct ScriptOverlayLayer: View {
    /// A cap on the words MEASURED per frame (a measure resolves a `Text`, which is the expensive
    /// part). Past it, the words are drawn as their tick only.
    static let maxMeasuredTexts = 600
    /// Under this width a word has no room to be read: its tick alone says where it starts.
    static let minTextWidth: Double = 12

    let store: ScriptOverlayStore
    let entries: [LaneEntry]
    let pixelsPerSecond: Double
    let rulerHeight: Double
    let laneStep: Double
    let blockHeight: Double
    var scrollOffsetX: CGFloat = 0
    var viewportWidth: CGFloat = 0
    var previews: [UUID: ObjectMarkersOverlay.Preview] = [:]
    let width: Double
    let height: Double

    private static func tint(_ c: OverlayColor) -> Color {
        switch c {
        case .white:  return .white
        case .red:    return Color(red: 0.95, green: 0.25, blue: 0.22)
        case .yellow: return Color(red: 0.98, green: 0.82, blue: 0.20)
        case .green:  return Color(red: 0.30, green: 0.80, blue: 0.40)
        case .blue:   return Color(red: 0.30, green: 0.55, blue: 0.95)
        }
    }

    var body: some View {
        // The one read of the store, HERE: a script rewriting its zones invalidates this Canvas and
        // nothing else (@see ScriptOverlayStore).
        let overlays = store.overlays
        Canvas { context, _ in
            guard !overlays.isEmpty else { return }
            let visX0 = Double(scrollOffsetX) - 50
            let visX1 = viewportWidth > 0
                ? Double(scrollOffsetX) + Double(viewportWidth) + 50
                : Double.greatestFiniteMagnitude
            var measured = 0

            for e in entries {
                guard let o = overlays[e.item.id] else { continue }
                let p = previews[e.item.id] ?? ScriptOverlayLayer.emptyPreview
                let by = rulerHeight + Double(e.displayLane) * laneStep + p.dy
                let startPx = e.absStart * pixelsPerSecond + p.dx
                let blockEndPx = startPx + e.item.duration * pixelsPerSecond + p.dRight
                let windowStartPx = startPx + p.dLeft
                // The visible stretch, in the object's own seconds.
                let px0 = max(visX0, windowStartPx), px1 = min(visX1, blockEndPx)
                guard px1 > px0 else { continue }
                let t0 = (px0 - startPx) / pixelsPerSecond
                let t1 = (px1 - startPx) / pixelsPerSecond

                // Zones: a full-height veil, its two edges drawn as a hairline.
                var i = o.zones.firstIndex(startingAtOrAfter: t0 - o.maxZoneSpan, key: { $0.start })
                while i < o.zones.count, o.zones[i].start <= t1 {
                    let z = o.zones[i]; i += 1
                    guard z.end >= t0 else { continue }
                    let x0 = max(startPx + z.start * pixelsPerSecond, windowStartPx)
                    let x1 = min(startPx + z.end * pixelsPerSecond, blockEndPx)
                    guard x1 > x0 else { continue }
                    let color = Self.tint(z.color)
                    context.fill(Path(CGRect(x: x0, y: by, width: x1 - x0, height: blockHeight)),
                                 with: .color(color.opacity(z.opacity)))
                    var edges = Path()
                    for x in [x0, x1] {
                        edges.move(to: CGPoint(x: x, y: by))
                        edges.addLine(to: CGPoint(x: x, y: by + blockHeight))
                    }
                    context.stroke(edges, with: .color(color.opacity(0.9)), lineWidth: 1)
                }

                // Words: a strip under the block's name band, a tick at each word's start and the
                // word fitted (ellipsis) to the room it has before the next one.
                guard !o.texts.isEmpty else { continue }
                let ty = by + 15
                var j = o.texts.firstIndex(startingAtOrAfter: t0 - o.maxTextSpan, key: { $0.start })
                while j < o.texts.count, o.texts[j].start <= t1 {
                    let w = o.texts[j]
                    let next = j + 1 < o.texts.count ? o.texts[j + 1].start : Double.greatestFiniteMagnitude
                    j += 1
                    guard w.end >= t0 else { continue }
                    let x = startPx + w.start * pixelsPerSecond
                    guard x >= windowStartPx - 0.5, x <= blockEndPx else { continue }
                    var tick = Path()
                    tick.move(to: CGPoint(x: x, y: ty))
                    tick.addLine(to: CGPoint(x: x, y: ty + 11))
                    context.stroke(tick, with: .color(.white.opacity(0.85)), lineWidth: 1)

                    let endT = min(w.end, next)
                    let room = min(startPx + endT * pixelsPerSecond, blockEndPx) - x - 3
                    guard room >= Self.minTextWidth, measured < Self.maxMeasuredTexts else { continue }
                    measured += 1
                    guard let label = fittedMarkerLabel(w.text, size: 9, weight: .medium,
                                                        maxWidth: room, context: context)
                    else { continue }
                    context.draw(label.foregroundStyle(Color.white),
                                 at: CGPoint(x: x + 2, y: ty + 6), anchor: .leading)
                }
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }

    private static let emptyPreview = ObjectMarkersOverlay.Preview()
}

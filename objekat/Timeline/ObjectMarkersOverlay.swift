import SwiftUI

// MARK: - The markers an object carries

/// The markers laid INSIDE the objects, drawn as ONE layer over every lane.
///
/// One layer rather than a strip inside each block, and that is the reason this file is short.
/// The timeline draws its blocks by three different paths — `SoundBlockView`, `GroupBlockView`, and
/// a single Canvas that batches the simple ones for speed — so putting the markers in the blocks
/// would mean writing them three times and keeping the three in step. Here it is written once, and
/// it covers clips, MIDI clips, groups and auxes alike, at every depth, whichever path drew them.
///
/// PURE PRESENTATION: the clicks are resolved by `TimelineView.objectMarkerHit`, geometrically,
/// like everything else in the canvas.
struct ObjectMarkersOverlay: View {
    /// The height of the strip at the top of a block that belongs to the markers. It bounds the
    /// drawing AND the grab zone (@see TimelineView.objectMarkerHit): the rest of the block's
    /// surface belongs to the object, and a marker must not make a block harder to grab.
    static let grabStripHeight: Double = 11

    let entries: [LaneEntry]
    let pixelsPerSecond: Double
    let rulerHeight: Double
    let laneStep: Double
    let blockHeight: Double
    var selected: AnnotationSel? = nil
    var renamingID: UUID? = nil
    var scrollOffsetX: CGFloat = 0
    var viewportWidth: CGFloat = 0
    let width: Double
    let height: Double
    /// nil = cancelled (Esc). Otherwise the new name, for the marker being renamed.
    var onRename: (UUID, String?) -> Void = { _, _ in }

    var body: some View {
        ZStack(alignment: .topLeading) {
            canvas
            // The rename field: it exists only for the marker being renamed, so the layer takes no
            // hit at any other time and never stands between the hand and a block.
            if let id = renamingID,
               let hit = entries.compactMap({ e -> (LaneEntry, Marker)? in
                   e.item.markers.first { $0.id == id }.map { (e, $0) }
               }).first {
                MarkerRenameField(initial: hit.1.name, onCommit: { onRename(id, $0) })
                    .frame(width: 120, height: 14)
                    .offset(x: (hit.0.absStart + hit.1.time) * pixelsPerSecond + 6,
                            y: rulerHeight + Double(hit.0.displayLane) * laneStep + 1)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }

    private var canvas: some View {
        Canvas { context, _ in
            let visX0 = Double(scrollOffsetX) - 200
            let visX1 = viewportWidth > 0
                ? Double(scrollOffsetX) + Double(viewportWidth) + 200
                : Double.greatestFiniteMagnitude

            for e in entries {
                guard !e.item.markers.isEmpty else { continue }
                let by = rulerHeight + Double(e.displayLane) * laneStep
                for m in e.item.markers {
                    // Behind an edge: kept in the model, not drawn. A left trim or the right half of
                    // a cut pushes a marker out of the window, where it waits for the edge to be
                    // reopened (@see Array where Element == Marker). Drawing it would put it on top
                    // of a neighbour it has nothing to do with.
                    guard m.time >= -1e-9, m.time <= e.item.duration + 1e-9 else { continue }
                    let x = (e.absStart + m.time) * pixelsPerSecond
                    if x < visX0 || x > visX1 { continue }
                    let sel = selected == .objectMarker(object: e.item.id, marker: m.id)
                    let tint = sel ? Color.accentColor : Color.white
                    let alpha = sel ? 1.0 : 0.75

                    // A hairline through the whole block, so the marker names an instant in the
                    // MATTER and not merely a spot on its rim.
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: by))
                    line.addLine(to: CGPoint(x: x, y: by + blockHeight))
                    context.stroke(line, with: .color(tint.opacity(sel ? 0.95 : 0.5)),
                                   lineWidth: sel ? 1.5 : 1)

                    var tab = Path()
                    tab.move(to: CGPoint(x: x, y: by))
                    tab.addLine(to: CGPoint(x: x + 5, y: by))
                    tab.addLine(to: CGPoint(x: x, y: by + 6))
                    tab.closeSubpath()
                    context.fill(tab, with: .color(tint.opacity(alpha)))

                    guard !m.name.isEmpty, renamingID != m.id else { continue }
                    context.draw(Text(m.name)
                                    .font(.system(size: 8, weight: sel ? .bold : .medium))
                                    .foregroundStyle(sel ? Color.accentColor : Color.black.opacity(0.65)),
                                 at: CGPoint(x: x + 7, y: by + 5), anchor: .leading)
                }
            }
        }
        .frame(width: width, height: height)
        .allowsHitTesting(false)
    }
}

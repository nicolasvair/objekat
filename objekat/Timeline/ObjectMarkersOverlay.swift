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
    /// The height of the strip at the top of a block the markers answer in (@see
    /// `TimelineView.objectMarkerHit`): the rest of the block's surface belongs to the object, and
    /// a marker must not make a block harder to grab. It bounds the GRAB only — the drawing goes
    /// on using the whole block height for the tick, which is what names an instant in the matter.
    ///
    /// 14 px, raised from 11 on 21 September 2026 after the marks were found unreachable: the
    /// pennant and its name occupy the first 9 or so, and a band row — the thing this is meant to
    /// feel like — is 17 px of which every pixel grabs. 14 keeps the block's upper half in the
    /// majority (a fade handle and a traced range still live there) while leaving a few pixels of
    /// slack under the name, which is what a hand aiming at a 6 px pennant needs.
    static let grabStripHeight: Double = 14

    /// What a GESTURE UNDER WAY does to a block, in canvas px, so the marks travel with the matter
    /// they name. It is the very preview the block is drawn with, read from the one place that
    /// holds it (@see `TimelineView.previewOffset` / `previewTrimDX` / `previewResizeDX`) rather
    /// than a second channel that would have to be kept in step.
    ///
    /// The two halves do NOT do the same thing, and that is the whole point:
    /// • `dx` / `dy` — a MOVE. The object travels, and its marks travel with it; without this they
    ///   stayed at the model's position and only jumped to their (correct) place on release.
    /// • `dLeft` / `dRight` — a TRIM or a CROP. The window moves, the material does NOT, so a mark
    ///   keeps its x and only the BOUNDS of what is drawn change: the edge is pulled in over a
    ///   mark and the mark goes out, pulled back open and it comes back, live.
    ///
    /// Empty outside a gesture, which is also what keeps this layer diffable: the dictionary is
    /// Equatable, so the Canvas is not redrawn for a preview nobody asked for.
    struct Preview: Equatable {
        var dx: Double = 0
        var dy: Double = 0
        var dLeft: Double = 0
        var dRight: Double = 0
    }

    let entries: [LaneEntry]
    let pixelsPerSecond: Double
    let rulerHeight: Double
    let laneStep: Double
    let blockHeight: Double
    var selected: AnnotationSel? = nil
    var renamingID: UUID? = nil
    var scrollOffsetX: CGFloat = 0
    var viewportWidth: CGFloat = 0
    /// objectID → the gesture preview its block is drawn with. Empty while nothing is being
    /// dragged. @see `Preview`
    var previews: [UUID: Preview] = [:]
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
                // The gesture under way, if this object is in one. A move carries the marks along
                // (dx/dy); a trim only moves the WINDOW, so the marks keep their x. @see Preview
                let p = previews[e.item.id] ?? Preview()
                let by = rulerHeight + Double(e.displayLane) * laneStep + p.dy
                let startPx = e.absStart * pixelsPerSecond + p.dx
                // The wall each name stops at, in canvas px: the next mark of THIS object, or the
                // object's own right edge. The same rule as the band's (@see fittedMarkerLabel) —
                // a name laid over the mark that follows it names the wrong instant, and on a
                // block it would also run out over the neighbouring clip.
                let edgesPx = e.item.markers
                    .map { startPx + $0.time * pixelsPerSecond }.sorted()
                let blockEndPx = startPx + e.item.duration * pixelsPerSecond + p.dRight
                let windowStartPx = startPx + p.dLeft
                for m in e.item.markers {
                    // Behind an edge: kept in the model, not drawn. A left trim or the right half of
                    // a cut pushes a marker out of the window, where it waits for the edge to be
                    // reopened (@see Array where Element == Marker). Drawing it would put it on top
                    // of a neighbour it has nothing to do with.
                    //
                    // Read against the PREVIEWED window rather than the model's, so the closing and
                    // the reopening of an edge are seen while the hand is still on it.
                    let x = startPx + m.time * pixelsPerSecond
                    guard x >= windowStartPx - 0.5, x <= blockEndPx + 0.5 else { continue }
                    if x < visX0 || x > visX1 { continue }
                    let sel = selected == .objectMarker(object: e.item.id, marker: m.id)
                    // White by default here rather than a row's hue — a mark laid ON matter has no
                    // row to take one from, and white is what reads against any waveform under it.
                    // A hue asked for outright is honoured (@see Marker.colorIndex).
                    let own = m.colorIndex.map(ObjectColorPalette.color(at:)) ?? Color.white
                    let tint = sel ? Color.accentColor : own
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

                    guard renamingID != m.id else { continue }
                    let wall = min(edgesPx.first { $0 > x + 0.5 } ?? blockEndPx, blockEndPx)
                    guard let label = fittedMarkerLabel(m.name, size: 8,
                                                        weight: sel ? .bold : .medium,
                                                        maxWidth: wall - (x + 7) - 2,
                                                        context: context)
                    else { continue }
                    context.draw(label
                                    .foregroundStyle(sel ? Color.accentColor : Color.black.opacity(0.65)),
                                 at: CGPoint(x: x + 7, y: by + 5), anchor: .leading)
                }
            }
        }
        .frame(width: width, height: height)
        .allowsHitTesting(false)
    }
}

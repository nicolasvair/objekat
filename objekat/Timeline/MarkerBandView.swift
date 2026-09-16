import SwiftUI
import AppKit

// MARK: - Geometry of the marker band
//
// The SINGLE source, because four places have to agree on it to the pixel: the drawing below, the
// hit-testing in the tap handler, `TimelineView.rulerHeight` (from which EVERY lane offset in the
// timeline is measured) and the two AppKit event monitors, which cannot read the view's own
// properties. A disagreement of one row between any two of them puts every block in the project
// 17 px away from where it is clicked.
enum MarkerBandGeometry {
    /// The RULER proper — graduations, loop band, its IN/OUT markers. Fixed.
    static let rulerCoreHeight: Double = 50
    /// One row of the band.
    static let rowHeight: Double = 17
    /// How far from a marker's tick a click still takes it. A point marker is a hairline: without
    /// a tolerance it could only be caught by luck.
    static let grabPx: Double = 6

    /// The whole header: the ruler, plus one row per VISIBLE row of the band. Hiding a row gives
    /// its pixels back to the content, which is the whole point of being able to hide one.
    static func headerHeight(visibleLanes: Int) -> Double {
        rulerCoreHeight + Double(visibleLanes) * rowHeight
    }

    /// A rough width for a label drawn at 9 pt. Used only to widen a marker's grab zone onto its
    /// name — one aims at the word one reads, not at the hairline beside it. Being approximate
    /// costs nothing: the worst case is a click landing a few pixels outside a name.
    static func labelWidth(_ name: String) -> Double {
        name.isEmpty ? 0 : Double(name.count) * 5.2 + 6
    }
}

/// A mark's name cut down to the room it has been given, with an ellipsis when it had to give
/// ground — nil when there is not even room for that.
///
/// It exists because a mark's name is drawn FREE, beside its tick and not inside a box: zoomed out
/// far enough, two marks come within a few pixels of each other and the first name lay straight
/// across the second mark, its flag and its own name. A title takes the room available and not one
/// pixel more. Shared by the band and by the marks carried on an object — the same drawing, hence
/// the same bug, hence one fix.
///
/// Measured rather than guessed: `MarkerBandGeometry.labelWidth` approximates, which is all a grab
/// zone needs, but a drawing that is a character out shows.
func fittedMarkerLabel(_ name: String, size: Double, weight: Font.Weight,
                       maxWidth: Double, context: GraphicsContext) -> Text? {
    guard maxWidth >= 6, !name.isEmpty else { return nil }
    let box = CGSize(width: .greatestFiniteMagnitude, height: size * 3)
    func make(_ str: String) -> Text { Text(str).font(.system(size: size, weight: weight)) }
    func fits(_ t: Text) -> Bool { context.resolve(t).measure(in: box).width <= maxWidth }

    let whole = make(name)
    if fits(whole) { return whole }
    var chars = Array(name)
    while !chars.isEmpty {
        chars.removeLast()
        let t = make(String(chars) + "…")
        if fits(t) { return t }
    }
    return nil
}

// MARK: - The band

/// The rows of markers, drawn under the ruler and sticky with it.
///
/// PURE PRESENTATION, like the timeline's blocks: not one gesture lives here. Clicks are resolved
/// geometrically by the parent canvas (@see TimelineView+TapHandler), which is the project's rule
/// — the band would otherwise fight the canvas for every event that crosses it.
///
/// The one exception is the rename field, exactly as in `SoundBlockView`: a text field has to BE
/// there to take the keyboard, so it exists only for the marker being renamed and takes hits only
/// then.
struct MarkerBandView: View {
    let lanes: [MarkerLane]
    let pixelsPerSecond: Double
    let totalDuration: Double
    /// The notched culling window: the band can be thousands of markers long, and only what is on
    /// screen is worth drawing. The same mechanism as the ruler's.
    var scrollOffsetX: CGFloat = 0
    var viewportWidth: CGFloat = 0
    var selected: AnnotationSel? = nil
    /// The marker being renamed, if any (compared against `EditViewModel.renamingID`).
    var renamingID: UUID? = nil
    var onRename: (UUID, String?) -> Void = { _, _ in }

    private var rowHeight: Double { MarkerBandGeometry.rowHeight }

    private func color(_ lane: MarkerLane) -> Color { ObjectColorPalette.color(at: lane.colorIndex) }

    /// A mark's hue: its own if it asked for one, otherwise the row's. The fallback is what makes
    /// recolouring a row recolour everything on it (@see Marker.colorIndex).
    private func color(_ m: Marker, on lane: MarkerLane) -> Color {
        m.colorIndex.map(ObjectColorPalette.color(at:)) ?? color(lane)
    }

    private func isSelected(_ lane: MarkerLane, _ m: Marker) -> Bool {
        selected == .laneMarker(lane: lane.id, marker: m.id)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                let visX0 = Double(scrollOffsetX) - 200
                let visX1 = viewportWidth > 0
                    ? Double(scrollOffsetX) + Double(viewportWidth) + 200
                    : Double.greatestFiniteMagnitude

                context.fill(Path(CGRect(origin: .zero, size: size)),
                             with: .color(Color(nsColor: .windowBackgroundColor)))

                for (row, lane) in lanes.enumerated() {
                    let y = Double(row) * rowHeight
                    let tint = color(lane)      // the ROW's hue: its ground, and the marks' default

                    // The row's own ground: enough for the eye to separate two rows, not enough to
                    // compete with the markers laid on it.
                    context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: rowHeight)),
                                 with: .color(tint.opacity(row % 2 == 0 ? 0.07 : 0.11)))
                    var sep = Path()
                    sep.move(to: CGPoint(x: 0, y: y))
                    sep.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(sep, with: .color(.primary.opacity(0.10)), lineWidth: 0.5)

                    // Every mark's LEADING edge on this row, in reading order: the wall each name
                    // stops at. A name is drawn to the right of its tick, so what it may not reach
                    // is the next mark along, whatever kind it is — and the row's own right edge
                    // when there is no next one.
                    let edgesPx = lane.markers.map { $0.time * pixelsPerSecond }.sorted()

                    // Regions FIRST, markers over them: a point that falls inside a span must stay
                    // readable, and it is the point that is the finer mark.
                    for m in lane.sortedMarkers where m.isRegion {
                        let x0 = m.time * pixelsPerSecond
                        let x1 = m.endTime * pixelsPerSecond
                        if x1 < visX0 || x0 > visX1 { continue }
                        draw(region: m, lane: lane, x0: x0, x1: x1, y: y,
                             tint: color(m, on: lane), context: &context)
                    }
                    for m in lane.sortedMarkers where !m.isRegion {
                        let x = m.time * pixelsPerSecond
                        if x < visX0 || x > visX1 { continue }
                        let wall = edgesPx.first { $0 > x + 0.5 } ?? size.width
                        draw(marker: m, lane: lane, x: x, y: y, limitX: wall,
                             tint: color(m, on: lane), context: &context)
                    }
                }
            }
            .frame(width: totalDuration * pixelsPerSecond,
                   height: Double(lanes.count) * rowHeight)

            // The rename field: it exists only for the marker being renamed, so nothing else in the
            // band ever takes a hit (@see the note on the type).
            if let id = renamingID,
               let hit = lanes.enumerated().compactMap({ row, lane -> (Int, MarkerLane, Marker)? in
                   lane.markers.first { $0.id == id }.map { (row, lane, $0) }
               }).first {
                MarkerRenameField(initial: hit.2.name,
                                  onCommit: { onRename(id, $0) })
                    .frame(width: 130, height: rowHeight - 3)
                    .offset(x: hit.2.time * pixelsPerSecond + (hit.2.isRegion ? 4 : 8),
                            y: Double(hit.0) * rowHeight + 1.5)
            }
        }
    }

    private func draw(region m: Marker, lane: MarkerLane, x0: Double, x1: Double, y: Double,
                      tint: Color, context: inout GraphicsContext) {
        let sel = isSelected(lane, m)
        let rect = CGRect(x: x0, y: y + 2, width: max(2, x1 - x0), height: rowHeight - 4)
        let shape = Path(roundedRect: rect, cornerRadius: 3)
        context.fill(shape, with: .color(tint.opacity(sel ? 0.55 : 0.30)))
        context.stroke(shape,
                       with: .color(sel ? .accentColor : tint.opacity(0.85)),
                       lineWidth: sel ? 1.5 : 0.75)
        guard rect.width > 16,
              // A name must not run past the span it names, otherwise it would read as belonging
              // to whatever follows. Cut to fit rather than clipped flat: the ellipsis says the
              // name goes on, where a letter sliced down the middle says nothing.
              let label = fitted(m.name, weight: .medium, maxWidth: rect.width - 8,
                                 context: context)
        else { return }
        context.drawLayer { inner in
            inner.clip(to: shape)
            inner.draw(label.foregroundStyle(Color.primary.opacity(0.85)),
                       at: CGPoint(x: rect.minX + 4, y: rect.midY), anchor: .leading)
        }
    }

    private func fitted(_ name: String, weight: Font.Weight, maxWidth: Double,
                        context: GraphicsContext) -> Text? {
        fittedMarkerLabel(name, size: 9, weight: weight, maxWidth: maxWidth, context: context)
    }

    /// `limitX` — where this name has to stop: the next mark on the row, or the row's end.
    private func draw(marker m: Marker, lane: MarkerLane, x: Double, y: Double,
                      limitX: Double = .greatestFiniteMagnitude,
                      tint: Color, context: inout GraphicsContext) {
        let sel = isSelected(lane, m)
        let stroke = sel ? Color.accentColor : tint
        // A pennant: the tick carries the time, the flag carries the eye. Drawn to the RIGHT of the
        // tick, in the direction the name reads, so that the mark and its name are one shape.
        var tick = Path()
        tick.move(to: CGPoint(x: x, y: y + 1))
        tick.addLine(to: CGPoint(x: x, y: y + rowHeight - 1))
        context.stroke(tick, with: .color(stroke), lineWidth: sel ? 1.8 : 1.1)

        var flag = Path()
        flag.move(to: CGPoint(x: x, y: y + 1.5))
        flag.addLine(to: CGPoint(x: x + 6, y: y + 4.5))
        flag.addLine(to: CGPoint(x: x, y: y + 7.5))
        flag.closeSubpath()
        context.fill(flag, with: .color(stroke.opacity(sel ? 1.0 : 0.85)))

        // 3 px of air before the next mark: a name that ran right into the following tick would
        // read as belonging to it.
        guard let label = fitted(m.name, weight: sel ? .semibold : .regular,
                                 maxWidth: limitX - (x + 8) - 3, context: context) else { return }
        context.draw(label.foregroundStyle(sel ? Color.accentColor : Color.primary.opacity(0.8)),
                     at: CGPoint(x: x + 8, y: y + rowHeight / 2 + 2), anchor: .leading)
    }
}

// MARK: - The rename field

/// The inline field, shared by a marker and a row's name. Split out of the band because the two
/// use it and a `@FocusState` cannot be handed around: it has to live in the view that owns the
/// field.
struct MarkerRenameField: View {
    let initial: String
    /// nil = cancelled (Esc). Otherwise the new text.
    let onCommit: (String?) -> Void

    @State private var text: String = ""
    /// One way out, once. Esc, Return and the field's DISAPPEARANCE all end the edit, and the
    /// last of the three fires on its way out of every other: without the latch, a Return would
    /// commit, take the field off screen and commit a second time.
    @State private var done = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField(noLabel, text: $text)
            .font(.system(size: 9, weight: .medium))
            .textFieldStyle(.plain)
            .padding(.horizontal, 3)
            .background(RoundedRectangle(cornerRadius: 3).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.accentColor, lineWidth: 1))
            .focused($focused)
            .onSubmit { finish(text) }
            .onExitCommand { finish(nil) }
            // Deselecting takes the field away (@see EditViewModel.selectedAnnotation): what was
            // typed is KEPT rather than dropped. Clicking elsewhere is how one normally leaves a
            // field, and a click that silently threw the name away would be a trap.
            .onDisappear { finish(text) }
            .onAppear {
                text = initial
                // One turn later: the field has to EXIST before the focus reaches it, exactly as in
                // SoundBlockView — setting the flag in the same turn changes nothing and the field
                // never takes the keyboard.
                DispatchQueue.main.async { focused = true }
            }
    }

    private func finish(_ value: String?) {
        guard !done else { return }
        done = true
        onCommit(value)
    }
}

// MARK: - The rows' names, pinned to the viewport

/// The names of the band's rows, and the button that governs them.
///
/// PINNED, not scrolled: a row's name is its identity, and an identity that goes off with the
/// horizontal scroll stops naming anything. It therefore lives in the timeline's overlay layer —
/// the same one the tool indicator uses — and not in the canvas.
struct MarkerLaneHeaderView: View {
    let lanes: [MarkerLane]
    let allLanes: [MarkerLane]
    /// The band's scale and the scroll, which together say where a row's first mark stands under
    /// these pinned names. @see `nameWidth`.
    var pixelsPerSecond: Double = 1
    /// The LIVE scroll, read here and nowhere else in a body: passed as the object, its `x` is
    /// touched inside this view, so a scrolling frame invalidates these few rows and not the
    /// timeline. Exactly what `StickyToViewportTop` does with the vertical. @see TimelineScrollAnchor
    var anchor: TimelineScrollAnchor? = nil
    var renamingID: UUID? = nil
    var onToggle: (UUID) -> Void = { _ in }
    var onCreate: () -> Void = {}
    var onDelete: (UUID) -> Void = { _ in }
    var onBeginRename: (UUID) -> Void = { _ in }
    var onRename: (UUID, String?) -> Void = { _, _ in }
    var onRecolor: (UUID, Int) -> Void = { _, _ in }

    private var rowHeight: Double { MarkerBandGeometry.rowHeight }

    static let dotSize: Double = 10
    /// Where a row's colour dot sits, measured from the LEFT EDGE OF THE VIEWPORT — these headers
    /// are PINNED there, not laid on the content. It is what the right-click monitor turns a click
    /// into a row with (@see TimelineView.markerLaneDotHit); a couple of pixels of slack either
    /// side, because one aims at a 10 px disc with a mouse.
    ///
    /// 3 (the row's leading padding) + 5 (the pill's own) = the dot's left edge at 8.
    static let dotXRange: ClosedRange<Double> = 1...22

    /// Where a row's NAME begins, from the viewport's left edge: the row's own leading padding (3),
    /// the pill's (5), the dot (10) and the gap after it (4). The same arithmetic `dotXRange` is
    /// built on, one step further along.
    private static let nameX: Double = 3 + 5 + dotSize + 4
    /// The widest a name is ever drawn, whatever room it has.
    private static let nameMaxWidth: Double = 110
    /// Under this there is not even room for an ellipsis: the name gives up its place entirely.
    private static let nameMinWidth: Double = 12

    /// The room a row's name has: from where it starts to the first mark of that row standing to
    /// the right of it.
    ///
    /// A PINNED name and a SCROLLING band eventually collide, and zooming out is what brings it on
    /// — every mark of a project piles up towards the left edge, under the names that say whose
    /// rows they are. The name is what gives way. It is the one thing here that can still be read
    /// from a fragment, where a mark cut in half is a mark one can no longer aim at; and it gives
    /// way PROGRESSIVELY — the room there is, then an ellipsis, then nothing — rather than
    /// vanishing at a threshold.
    ///
    /// The dot stays whatever happens: it carries the row's colour and it is the target of the
    /// right click that changes it (@see `dotXRange`). A mark that ends up beneath it is the price,
    /// and it is 10 px wide against a name three times that.
    ///
    /// Marks standing to the LEFT of the name pull nothing: they are behind the dot, or scrolled
    /// past, and there is no width that would avoid them.
    private func nameWidth(_ lane: MarkerLane) -> Double {
        guard !lane.markers.isEmpty else { return Self.nameMaxWidth }
        let scroll = Double(anchor?.x ?? 0)
        var wall = Double.greatestFiniteMagnitude
        for m in lane.markers {
            let x = m.time * pixelsPerSecond - scroll
            if x > Self.nameX, x < wall { wall = x }
        }
        guard wall < .greatestFiniteMagnitude else { return Self.nameMaxWidth }
        // The pill's trailing padding, then the 3 px of air a mark's own name already keeps ahead
        // of the next mark (@see `draw(marker:)`).
        return min(Self.nameMaxWidth, max(0, wall - Self.nameX - 5 - 3))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(lanes) { lane in
                    row(lane, width: nameWidth(lane))
                        .frame(height: rowHeight, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
            clampButton
        }
        .padding(.top, MarkerBandGeometry.rulerCoreHeight)
        .allowsHitTesting(true)
    }

    @ViewBuilder
    private func row(_ lane: MarkerLane, width: Double) -> some View {
        HStack(spacing: 4) {
            // The dot IS the row's colour, so it is where one goes to change it: a RIGHT CLICK on
            // it opens the palette, and what that sets is the row's DEFAULT — every mark on the row
            // follows, except those given a hue of their own.
            //
            // The click itself is not taken here. It is resolved geometrically by the right-click
            // monitor (@see TimelineView.markerLaneDotHit), like everything else in the timeline,
            // and for a reason that is not style: an AppKit LOCAL monitor sees the event before the
            // view hierarchy does, so an `NSView` overlay laid here would never be reached. Hence
            // `dotXRange` below — the one thing the two places have to agree on.
            Circle()
                .fill(ObjectColorPalette.color(at: lane.colorIndex))
                .frame(width: Self.dotSize, height: Self.dotSize)
                .help(L("markers.lane.color.help"))
            if renamingID == lane.id {
                // A field keeps its full width whatever is under it: one is TYPING, and a box that
                // shrank to nothing would leave the keyboard with nowhere to go. It is transient,
                // and the mark it covers comes back the moment the name is committed.
                MarkerRenameField(initial: lane.name) { onRename(lane.id, $0) }
                    .frame(width: Self.nameMaxWidth)
            } else if width >= Self.nameMinWidth {
                Text(lane.name)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: width, alignment: .leading)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 3).fill(.regularMaterial).opacity(0.92))
        .padding(.leading, 3)
        // A double click renames, exactly as it does on an object and on a marker.
        .onTapGesture(count: 2) { onBeginRename(lane.id) }
    }

    private var clampButton: some View {
        Menu {
            // A Toggle rather than a Button with a tick glued in front of the name: AppKit then
            // draws the checkmark itself, and — the real reason — an interpolated string handed to
            // a `Label`/`Button` is read as a translation KEY and poured into the catalogue by
            // Xcode's extraction (@see CLAUDE.md, the `%@%@` trap).
            ForEach(allLanes) { lane in
                Toggle(isOn: Binding(get: { lane.isVisible },
                                     set: { _ in onToggle(lane.id) })) {
                    Text(verbatim: lane.name)
                }
            }
            if !allLanes.isEmpty { Divider() }
            Button(L("markers.lane.new")) { onCreate() }
            if !allLanes.isEmpty {
                Menu(L("markers.lane.deleteMenu")) {
                    ForEach(allLanes) { lane in
                        Button(lane.name) { onDelete(lane.id) }
                    }
                }
            }
        } label: {
            // A flag: the band's own sign, the shape already drawn on every point marker in it.
            // The filter glyph it replaced said 'narrow a list down', which is not what this does.
            Image(systemName: "flag.square.fill")
                .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 26)
        .padding(.trailing, 6)
        .help(L("markers.lane.menu.help"))
    }
}

import SwiftUI
import AppKit

/// An object's AUTOMATION band, unfolded INLINE under it (in the band of sub-lanes
/// `SoundObject.expandedSpan` reserves). Rendered as an overlay positioned by `TimelineView`,
/// exactly like `PianoRollView`: its width = the object's, its height = the band.
///
/// ONE ROW = ONE `ParamRef`, in the order of `SoundObject.automationRows`: first the parameters
/// really automated, then the 'future automation' row — the one to lay the first point on. That
/// last one is drawn muted: it offers, it does not assert. It carries the LAST PARAMETER TOUCHED
/// on this object, whatever it is — the fader, pan, a trim, a send level, or a knob turned in a
/// plugin (@see SoundObject.pendingAutomationParam). Laying a point on it promotes it to a full
/// automation, and the waiting row slides of its own accord onto the parameter touched just
/// before. It disappears when there is nothing left to offer (everything is already automated).
///
/// Local geometry: x = 0 is the object's START, and the points are in time relative to that
/// start (@see AutomationPoint) — so the conversion is `t * pixelsPerSecond`, never going
/// through `startTime`. That is the whole point of relative time: moving the object changes not
/// one pixel of this view. All the coordinate computation lives in `AutomationBandGeometry`,
/// shared with the timeline's wheel monitor.
///
/// ─── Editing conventions (step 2) ──────────────────────────────────────────────────────────
/// - a double click in empty space → creates a point;
/// - a double click on a point     → deletes it (the last point removed gives the row back to
///   its static value: 'no point = no automation');
/// - dragging a point              → its value AND its time (the time snapped to the grid; ⌘
///   inverts the snap, DURING the gesture too);
/// - dragging a segment, in the band that borders it → raises or lowers the WHOLE segment; both
///   plateaux (before the first point, after the last) count as segments and move the point that
///   holds them;
/// - ⌥dragging, or the wheel, on a segment → its CURVATURE (`AutomationPoint.c`, bounded -1…+1);
/// - dragging a row with NO POINT AT ALL → sets the model's STATIC value (the fader equivalent)
///   and creates NO point. A knowing decision: without it, 'no point = no automation' would
///   become a state impossible to get back to as soon as one brushed the row.
///
/// A curve is grabbed WHERE IT IS: the segment and static-value gestures only start from a
/// narrow band around the line (@see AutomationBandGeometry.curveGrabY), and a point lights up
/// with a halo as soon as the cursor comes into its zone. The rest of the row answers to
/// nothing — one can hover it without fear of knocking it out.
///
/// Gestures: A SINGLE (high-priority) `DragGesture` branching on the starting zone plus ⌥, plus
/// a plain `SpatialTapGesture` with manual double-click detection — the piano roll's
/// architecture, for the same reason: competing `DragGesture`s only fire half the time (see the
/// header comment of `PianoRollView`).
///
/// Every mutation goes to the engine (step 3): a curve edited here IS HEARD, on an object inside
/// a group too. A corollary visible elsewhere: as soon as a row carries a point, the matching
/// static setting is greyed out in the signal view — the curve is what counts, with no offset.
///
/// A RIGHT click on the band: opening the row of a parameter one has not touched recently — the
/// model's targets flat, a plugin's parameters in a submenu per plugin. The first point is born
/// on the current static value, so with no jump in the sound. It is the CATCH-UP path; the
/// normal way is to touch the parameter, which then offers itself.
struct AutomationBandView: View {
    var viewModel: EditViewModel
    let object: SoundObject
    let pixelsPerSecond: Double
    /// The band's width. Supplied by the parent: it is the object's width, EXCEPT for an infinite
    /// bus, which has no end and spans the whole timeline.
    let bandWidth: Double
    let laneStep: Double
    /// A row's DRAWN height (= `blockHeight`): `laneStep` minus the gutter, so that two neighbouring
    /// rows do not touch.
    let rowHeight: Double

    private var rows: [ParamRef] { object.automationRows }
    private var pending: ParamRef? { object.pendingAutomationParam }
    private var tint: Color { object.customColor ?? viewModel.stemColor(for: object.id) }

    private var geo: AutomationBandGeometry {
        AutomationBandGeometry(rows: rows, pixelsPerSecond: pixelsPerSecond,
                               laneStep: laneStep, rowHeight: rowHeight,
                               bandWidth: max(1, bandWidth))
    }

    /// The effective snap, REREAD ON EVERY STEP of the gesture: ⌘ has to be able to invert the snap
    /// once the drag has begun, not only before engaging it. We ask the real keyboard rather than
    /// `viewModel.cmdKeyHeld` — the monitor feeding it does not see modifier changes that happen
    /// while a mouse button is held down, and the snap stayed frozen on its state at the start of
    /// the gesture. `cmdKeyHeld` is still useful for REFRESHING without moving the mouse (@see body),
    /// where the monitor, for its part, misses it.
    private var snapOn: Bool { viewModel.snapEnabled != NSEvent.modifierFlags.contains(.command) }
    private var snapGrid: Double { viewModel.effectiveSnapGrid }       // in SECONDS

    /// The vertical movement (px) that sweeps the whole curvature range (-1 → +1). Fixed, and not
    /// proportional to the row's height: a low band has to stay adjustable to the finger, not
    /// become ten times twitchier than a tall one.
    private static let curveDragTravel: Double = 60

    @State private var lastTap: (time: Date, loc: CGPoint) = (.distantPast, .zero)
    @State private var drag: BandDrag? = nil
    /// The value shown during a gesture: on a row some fifteen pixels tall, the eye reads no
    /// precision at all — that figure is the only usable feedback.
    @State private var readout: (row: Int, x: Double, text: String)? = nil
    /// The HOVERED point (its row plus its storage index): the one that would answer the click. It
    /// carries a white halo, the same promise as the veil over an object's six zones (@see
    /// ClipEditZonesOverlay) — the view lights up where the hand is about to act, before one presses.
    @State private var hoverPoint: (row: Int, index: Int)? = nil
    /// The hovered line: the row, and the x where the cursor met it. The curve lights up there
    /// over a few dozen pixels — the counterpart of a point's halo, for a gesture that plays out
    /// along the line (a segment, or the static value of an empty row).
    @State private var hoverLine: (row: Int, x: Double)? = nil

    /// The gesture under way. The mode is decided ONCE, on the first movement, from the zone
    /// grabbed and ⌥; the points are named by their STORAGE index, stable even if the drag takes a
    /// point past its neighbour (@see AutomationBandGeometry.ordered).
    private struct BandDrag {
        enum Mode {
            case point(Int)         // the value plus the time of the grabbed point
            case segment([Int])     // the value of the points holding the segment (1 on a plateau)
            case curve(Int)         // the curvature carried by the segment's left-hand point
            case staticValue        // a row with no point: the model's static value
        }
        let ref:  ParamRef
        let row:  Int
        let mode: Mode
        let origPoints: [AutomationPoint]
        let origStatic: Float
        let start: CGPoint
        /// The last known cursor position: it allows REPLAYING the gesture without a mouse movement,
        /// when ⌘ flips the snap along the way.
        var last: CGPoint
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                for (i, ref) in rows.enumerated() { draw(row: i, ref: ref, in: &ctx) }
            }
            .allowsHitTesting(false)

            // The interaction layer: it catches taps and drags over the whole band.
            Color.clear
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { handleTap(at: $0.location) })
                .highPriorityGesture(
                    DragGesture(minimumDistance: 3)
                        .onChanged { handleDragChanged($0) }
                        .onEnded   { _ in drag = nil; readout = nil; clearHover() }
                )
                .onContinuousHover { phase in
                    guard drag == nil else { return }
                    switch phase {
                    case .active(let p): updateCursor(at: p)
                    // No cursor is put back here: the hover that follows sets its own, and leaving
                    // the timeline goes through the tracking view's `mouseExited`. This `.ended`
                    // can arrive AFTER the hover that succeeds it — it would take its claim away
                    // from it.
                    case .ended:         clearHover()
                    }
                }
                .contextMenu { newLaneMenu }
        }
        .frame(width: max(1, bandWidth), height: geo.interactiveHeight, alignment: .topLeading)
        // ⌘ pressed or released WITHOUT moving the mouse: the gesture under way is replayed in place,
        // so that the snap flips before one's eyes instead of waiting for the next pixel travelled.
        .onChange(of: viewModel.cmdKeyHeld) { _, _ in
            if let d = drag { applyDrag(at: d.last) }
        }
        // The value of a PLUGIN parameter on the offered row: an engine query, so read here — when the
        // row changes — and never from the drawing (@see refreshPluginParamValue).
        .onAppear { if let pending { viewModel.refreshPluginParamValue(pending) } }
        .onChange(of: pending) { _, ref in
            if let ref { viewModel.refreshPluginParamValue(ref) }
        }
    }

    /// The 'add a row' menu: the model's targets flat (they can be counted on one's fingers), then
    /// ONE SUBMENU PER PLUGIN — a single AU brings three hundred parameters, and putting them at the
    /// same level would make the menu unusable. Those already automated are left out (their row
    /// exists); when everything is, SwiftUI shows nothing.
    ///
    /// It is the CATCH-UP path: the normal way to a parameter is to touch it, which brings it of
    /// its own accord onto the 'future automation' row.
    @ViewBuilder
    private var newLaneMenu: some View {
        ForEach(viewModel.automatableParams(for: object), id: \.self) { ref in
            Button(viewModel.automationLabel(ref, on: object)) {
                viewModel.beginAutomationLane(objectID: object.id, param: ref)
            }
        }
        let byPlugin = viewModel.automatablePluginParams(for: object)
        if !byPlugin.isEmpty { Divider() }
        ForEach(byPlugin, id: \.plugin.id) { entry in
            Menu(entry.plugin.name) {
                ForEach(entry.params, id: \.ref) { p in
                    Button(p.name) {
                        viewModel.beginAutomationLane(objectID: object.id, param: p.ref)
                    }
                }
            }
        }
    }

    // MARK: - Access to the model

    /// A row's STORED points (in storage order). Empty = a row that is not automated, hence a
    /// static-value row.
    private func points(_ ref: ParamRef) -> [AutomationPoint] {
        object.automation.first(where: { $0.param == ref })?.points ?? []
    }

    /// The value an EMPTY row shows: the model's static value, or failing that the resting value
    /// (a plugin parameter, whose value does not live in the model).
    private func staticValue(_ ref: ParamRef) -> Float {
        viewModel.automationStaticValue(ref, on: object) ?? ref.neutralValue
    }

    /// The LINE's value at a given instant: the curve if the row carries one, otherwise the value
    /// its dotted line shows — a row with no point IS its line. nil when the row has no line at all
    /// (a plugin parameter whose value never reached us).
    private func lineValue(atT t: Double, ref: ParamRef, points pts: [AutomationPoint]) -> Float? {
        guard !pts.isEmpty else { return viewModel.automationDisplayValue(ref, on: object) }
        let sorted = geo.ordered(pts).map(\.point)
        guard let first = sorted.first else { return nil }
        return AutomationCurveMath.value(at: t, in: sorted, default: first.v)
    }

    // MARK: - Rendering

    private func draw(row: Int, ref: ParamRef, in ctx: inout GraphicsContext) {
        let g        = geo
        let top      = g.rowTop(row)
        let rect     = CGRect(x: 0, y: top, width: max(1, bandWidth), height: rowHeight)
        let pts      = points(ref)
        let isFuture = ref == pending && pts.isEmpty

        // The background: the object's tint, well in the background — the row has to read as a work
        // area, not as one more block.
        ctx.fill(Path(rect), with: .color(tint.opacity(isFuture ? 0.05 : 0.10)))

        // The dotted line says only ONE thing: where the parameter stands BEFORE any automation. So it
        // belongs to the offered row alone, and disappears as soon as a curve rules — a resting-value
        // mark served no purpose there, and that of a plugin parameter (0.5) did not even mean
        // anything.
        let current = viewModel.automationDisplayValue(ref, on: object)
        if isFuture, let current {
            let markY = g.y(of: current, ref: ref, row: row)
            var mark = Path()
            mark.move(to: CGPoint(x: 0, y: markY))
            mark.addLine(to: CGPoint(x: rect.maxX, y: markY))
            // THAT line is DRAGGED (it carries the static value): it lights up on hover like a curve,
            // and over its whole length — it is the whole row the gesture moves.
            if viewModel.automationStaticValue(ref, on: object) != nil { drawLineHover(mark, row: row, in: &ctx) }
            ctx.stroke(mark, with: .color(tint.opacity(0.5)),
                       style: StrokeStyle(lineWidth: 1.5, dash: [3, 4]))
        }

        // The parameter's name, set at the head of the row. The offered row announces itself as such
        // and carries the parameter's value: it does not show a curve, it shows a state.
        let label = viewModel.automationLabel(ref, on: object)
        let title: String = {
            guard isFuture else { return label }
            let v = current.map { " · " + viewModel.automationReadout(ref, value: $0, on: object) }
            return L("automation.lastTouched", label + (v ?? ""))
        }()
        let text = Text(title)
            .font(.system(size: 10, weight: isFuture ? .regular : .medium))
            .foregroundStyle(Color.primary.opacity(isFuture ? 0.45 : 0.62))
        ctx.draw(ctx.resolve(text), at: CGPoint(x: 6, y: top + 3), anchor: .topLeading)

        // A row with NO point: the dotted line above IS its line — it already carries the value the
        // drag changes. Nothing more to draw (a second solid line in the same place would say
        // nothing it does not already say), and nothing at all when a plugin parameter's value has
        // not reached us yet: better a bare row than an invented figure.
        if !pts.isEmpty {
            drawCurve(pts, row: row, ref: ref, rect: rect, in: &ctx)
        }

        drawReadout(row: row, rect: rect, in: &ctx)
    }

    /// The curve's polyline, CURVATURE INCLUDED. Straight segments (`c == 0`) are drawn in one
    /// stroke; the others are sampled by the engine's own function (@see AutomationCurveMath) —
    /// what is drawn here is exactly what the engine will play once the bridge is laid.
    ///
    private func drawCurve(_ pts: [AutomationPoint], row: Int, ref: ParamRef,
                           rect: CGRect, in ctx: inout GraphicsContext) {
        let g       = geo
        let ordered = g.ordered(pts).map(\.point)
        var line    = Path()

        let firstY = g.y(of: ordered[0].v, ref: ref, row: row)
        line.move(to: CGPoint(x: 0, y: firstY))                       // the left-hand plateau
        line.addLine(to: CGPoint(x: g.x(ofT: ordered[0].t), y: firstY))

        for i in 0..<(ordered.count - 1) {
            let a = ordered[i], b = ordered[i + 1]
            let xb = g.x(ofT: b.t)
            let yb = g.y(of: b.v, ref: ref, row: row)
            if a.c == 0 || a.v == b.v || b.t <= a.t {
                line.addLine(to: CGPoint(x: xb, y: yb))
                continue
            }
            // Sampling every 2 px: beyond that, the eye no longer tells the segments apart.
            let xa    = g.x(ofT: a.t)
            let steps = max(2, min(256, Int((xb - xa) / 2)))
            let pair  = [a, b]
            for s in 1...steps {
                let t = a.t + (b.t - a.t) * Double(s) / Double(steps)
                let v = AutomationCurveMath.value(at: t, in: pair, default: a.v)
                line.addLine(to: CGPoint(x: g.x(ofT: t), y: g.y(of: v, ref: ref, row: row)))
            }
            line.addLine(to: CGPoint(x: xb, y: yb))
        }

        let lastY = g.y(of: ordered[ordered.count - 1].v, ref: ref, row: row)
        line.addLine(to: CGPoint(x: rect.maxX, y: lastY))             // the right-hand plateau
        if let affected = hoveredSegmentPath(row: row, ref: ref, points: pts, rect: rect) {
            drawLineHover(affected, row: row, in: &ctx)
        }
        ctx.stroke(line, with: .color(tint.opacity(0.95)),
                   style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))

        // The points, the one being held a little bigger — on a low row, it is the only way to
        // know which one is following the mouse.
        let held: Int? = {
            guard let d = drag, d.row == row, case .point(let i) = d.mode else { return nil }
            return i
        }()
        let hovered: Int? = hoverPoint.flatMap { $0.row == row ? $0.index : nil }
        for (idx, p) in pts.enumerated() {
            let c = CGPoint(x: g.x(ofT: p.t), y: g.y(of: p.v, ref: ref, row: row))
            // The hover halo: the point lights up as soon as the cursor comes into ITS grab zone —
            // so one knows it will answer the click before pressing. A gradient down to zero, like
            // the veil over an object's six zones: no edge, nothing that looks like a permanent
            // selection.
            if idx == hovered || idx == held {
                let hr = g.pointGrabX
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - hr, y: c.y - hr,
                                                width: hr * 2, height: hr * 2)),
                         with: .radialGradient(
                            Gradient(colors: [.white.opacity(0.32), .white.opacity(0)]),
                            center: c, startRadius: 0, endRadius: hr))
            }
            let r = idx == held ? 4.0 : 2.5
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                     with: .color(tint))
            if idx == held {
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                           with: .color(.white.opacity(0.8)), lineWidth: 1)
            }
        }
    }

    /// A white halo laid on the PORTION OF LINE the gesture would move, and nothing else: the
    /// hovered segment, an end plateau, or the whole row when it is the static value one is
    /// holding. Lighting the whole curve up would promise a gesture one has not got.
    private func drawLineHover(_ path: Path, row: Int, in ctx: inout GraphicsContext) {
        guard let h = hoverLine, h.row == row else { return }
        ctx.stroke(path, with: .color(.white.opacity(0.30)),
                   style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
    }

    /// Drawing the portion of curve the hover names — the segment under the cursor, its curvature
    /// included, or one of the two end plateaux. nil if nothing is hovered on that row.
    ///
    /// Resolved from the GRAB x, frozen during the gesture: dragging a segment moves no point in
    /// TIME, so the portion held stays the same from beginning to end.
    private func hoveredSegmentPath(row: Int, ref: ParamRef,
                                    points pts: [AutomationPoint], rect: CGRect) -> Path? {
        guard let h = hoverLine, h.row == row,
              let seg = geo.segment(atX: h.x, points: pts) else { return nil }
        let g = geo
        var path = Path()
        switch (seg.left, seg.right) {
        case (nil, .some(let r)):                                   // the left-hand plateau
            guard pts.indices.contains(r) else { return nil }
            let y = g.y(of: pts[r].v, ref: ref, row: row)
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: g.x(ofT: pts[r].t), y: y))
        case (.some(let l), nil):                                   // the right-hand plateau
            guard pts.indices.contains(l) else { return nil }
            let y = g.y(of: pts[l].v, ref: ref, row: row)
            path.move(to: CGPoint(x: g.x(ofT: pts[l].t), y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        case (.some(let l), .some(let r)):                          // a segment between two points
            guard pts.indices.contains(l), pts.indices.contains(r) else { return nil }
            let a = pts[l], b = pts[r]
            let xa = g.x(ofT: a.t), xb = g.x(ofT: b.t)
            path.move(to: CGPoint(x: xa, y: g.y(of: a.v, ref: ref, row: row)))
            let yb = g.y(of: b.v, ref: ref, row: row)
            if a.c == 0 || a.v == b.v || b.t <= a.t {
                path.addLine(to: CGPoint(x: xb, y: yb))
            } else {
                // The same sampling as the curve itself: the halo hugs the curvature.
                let steps = max(2, min(256, Int((xb - xa) / 2)))
                let pair  = [a, b]
                for s in 1...steps {
                    let t = a.t + (b.t - a.t) * Double(s) / Double(steps)
                    let v = AutomationCurveMath.value(at: t, in: pair, default: a.v)
                    path.addLine(to: CGPoint(x: g.x(ofT: t), y: g.y(of: v, ref: ref, row: row)))
                }
                path.addLine(to: CGPoint(x: xb, y: yb))
            }
        case (nil, nil):
            return nil
        }
        return path
    }

    /// The figure for the gesture under way, laid above the cursor and kept inside the band.
    private func drawReadout(row: Int, rect: CGRect, in ctx: inout GraphicsContext) {
        guard let r = readout, r.row == row else { return }
        let text = Text(r.text)
            .font(.system(size: 9, weight: .semibold).monospacedDigit())
            .foregroundStyle(Color.white.opacity(0.9))
        let resolved = ctx.resolve(text)
        let size = resolved.measure(in: CGSize(width: 200, height: 20))
        let x = (r.x + 10).clamped(to: 0...max(0, rect.maxX - size.width - 4))
        let y = rect.minY + 2
        let box = CGRect(x: x - 3, y: y - 1, width: size.width + 6, height: size.height + 2)
        ctx.fill(Path(roundedRect: box, cornerRadius: 3), with: .color(.black.opacity(0.55)))
        ctx.draw(resolved, at: CGPoint(x: x, y: y), anchor: .topLeading)
    }

    // MARK: - Cursor

    /// The cursors go through `TimelineCursorKeeper`: it is what has AppKit claim the point,
    /// without which the arrow would come back as soon as the mouse stopped during playback
    /// (@see CursorClaim).
    private func updateCursor(at p: CGPoint) {
        guard let row = geo.rowIndex(atY: p.y) else { clearHover(); TimelineCursorKeeper.set(.arrow); return }
        let ref = rows[row]
        let pts = points(ref)
        if pts.isEmpty {
            // A static-value row: adjustable only if the model carries that value — a plugin
            // parameter's is not there, and its empty row waits for a point.
            // And as everywhere else, it is grabbed ON its line, not anywhere in the row.
            if let sv = viewModel.automationStaticValue(ref, on: object),
               geo.nearLine(p, lineY: geo.y(of: sv, ref: ref, row: row)) {
                setHover(point: nil, line: (row: row, x: Double(p.x)))
                TimelineCursorKeeper.set(.resizeUpDown)
            } else {
                clearHover()
                TimelineCursorKeeper.set(.arrow)
            }
            return
        }
        // A point wins over the line carrying it: it is what one catches where the two zones
        // overlap, and it alone should light up.
        if let i = geo.pointHit(at: p, row: row, ref: ref, points: pts) {
            setHover(point: (row: row, index: i), line: nil)
            TimelineCursorKeeper.set(.openHand)
            return
        }
        guard let lineY = geo.curveY(atX: p.x, ref: ref, row: row, points: pts),
              geo.nearLine(p, lineY: lineY) else { clearHover(); TimelineCursorKeeper.set(.arrow); return }
        setHover(point: nil, line: (row: row, x: Double(p.x)))
        if NSEvent.modifierFlags.contains(.option), curvableSegment(atX: p.x, ref: ref, points: pts) != nil {
            TimelineCursorKeeper.set(.crosshair)      // ⌥ = curvature
        } else {
            TimelineCursorKeeper.set(.resizeUpDown)
        }
    }

    /// Sets what is hovered, without rewriting the state when nothing changes — the hover runs on
    /// every pixel travelled, and one write per pixel would redraw the band for nothing.
    /// The line's x, on the other hand, MUST follow the cursor: it is what walks the halo along.
    private func setHover(point: (row: Int, index: Int)?, line: (row: Int, x: Double)?) {
        if hoverPoint?.row != point?.row || hoverPoint?.index != point?.index { hoverPoint = point }
        if hoverLine?.row != line?.row || hoverLine?.x != line?.x { hoverLine = line }
    }

    private func clearHover() { setHover(point: nil, line: nil) }

    // MARK: - Taps (creating / deleting)

    private func handleTap(at p: CGPoint) {
        let now = Date()
        let isDouble = now.timeIntervalSince(lastTap.time) < 0.35
            && hypot(p.x - lastTap.loc.x, p.y - lastTap.loc.y) < 18
        lastTap = (now, p)

        guard let row = geo.rowIndex(atY: p.y) else { return }
        let ref = rows[row]
        let pts = points(ref)

        if isDouble {
            if let i = geo.pointHit(at: p, row: row, ref: ref, points: pts) {
                viewModel.removeAutomationPoint(objectID: object.id, param: ref, at: i)
            } else {
                // A row's first point: the curve takes over from the static value at that precise
                // instant (a curve with a single point is a plateau — that is what the engine will
                // make of it).
                //
                // ON THE LINE — where the halo lights up — the point is born EXACTLY on it, and with
                // no rounding: to within a few pixels, the hand was aiming at the curve, not at a
                // neighbouring value. Elsewhere in the row, the height clicked governs, at the
                // parameter's step.
                let t = snappedT(atX: p.x)
                let hitLine = lineValue(atT: geo.t(atX: p.x), ref: ref, points: pts)
                    .map { geo.nearLine(p, lineY: geo.y(of: $0, ref: ref, row: row)) } ?? false
                let onLine = hitLine ? lineValue(atT: t, ref: ref, points: pts) : nil
                viewModel.addAutomationPoint(
                    objectID: object.id, param: ref, t: t,
                    v: onLine ?? snappedV(geo.value(atY: p.y, ref: ref, row: row), ref: ref))
            }
            return
        }

        // A plain click: it selects the carrying object (the inspector follows), and consumes the
        // click so that it does not fall through onto the timeline's canvas.
        viewModel.select(object.id, additive: false)
    }

    // MARK: - Dragging

    private func handleDragChanged(_ value: DragGesture.Value) {
        if drag == nil { beginDrag(value) }
        guard drag != nil else { return }
        drag?.last = value.location
        applyDrag(at: value.location)
    }

    /// Applies the gesture at a given position. Separated from receiving the drag so as to be
    /// REPLAYABLE: ⌘ pressed without moving the mouse flips the snap back at the same position.
    private func applyDrag(at location: CGPoint) {
        guard let d = drag else { return }

        let dy  = location.y - d.start.y
        let dx  = location.x - d.start.x
        let g   = geo
        let ref = d.ref

        switch d.mode {
        case .point(let i):
            guard d.origPoints.indices.contains(i) else { return }
            let o = d.origPoints[i]
            let t = snappedT(atX: g.x(ofT: o.t) + dx)
            let v = snappedV((o.v + g.valueDelta(dy: dy, ref: ref)).clamped(to: ref.valueRange), ref: ref)
            viewModel.updateAutomationPoints(objectID: object.id, param: ref) { pts in
                guard pts.indices.contains(i) else { return }
                pts[i].t = t
                pts[i].v = v
            }
            setReadout(row: d.row, x: location.x, ref: ref, value: v)

        case .segment(let idxs):
            let origs = idxs.compactMap { d.origPoints.indices.contains($0) ? d.origPoints[$0].v : nil }
            guard let lo = origs.min(), let hi = origs.max() else { return }
            // The segment moves by a SINGLE difference: clamping it point by point would flatten it
            // against the bound instead of holding it whole.
            let range = ref.valueRange
            // The DIFFERENCE is rounded, not each value: a segment sitting on round figures stays
            // there, and one that was not keeps its internal differences.
            let dv = snappedStep(g.valueDelta(dy: dy, ref: ref), ref: ref)
                .clamped(to: (range.lowerBound - lo)...(range.upperBound - hi))
            viewModel.updateAutomationPoints(objectID: object.id, param: ref) { pts in
                for i in idxs where pts.indices.contains(i) && d.origPoints.indices.contains(i) {
                    pts[i].v = d.origPoints[i].v + dv
                }
            }
            setReadout(row: d.row, x: location.x, ref: ref, value: origs[0] + dv)

        case .curve(let i):
            guard d.origPoints.indices.contains(i) else { return }
            let dc = curveDelta(dy: dy, leftIndex: i, points: d.origPoints)
            let c  = (d.origPoints[i].c + dc).clamped(to: -1...1)
            viewModel.updateAutomationPoints(objectID: object.id, param: ref) { pts in
                guard pts.indices.contains(i) else { return }
                pts[i].c = c
            }
            readout = (row: d.row, x: Double(location.x),
                       text: String(format: L("automation.curveReadout"), c))

        case .staticValue:
            let v = snappedV((d.origStatic + g.valueDelta(dy: dy, ref: ref)).clamped(to: ref.valueRange), ref: ref)
            viewModel.setAutomationStaticValue(ref, on: object.id, to: v)
            setReadout(row: d.row, x: location.x, ref: ref, value: v)
        }
    }

    /// Decides the mode on the FIRST movement — the only instant when the zone grabbed and ⌥ are
    /// both known (the drag starts at 3 px, hence after the click).
    private func beginDrag(_ value: DragGesture.Value) {
        let p = value.startLocation
        guard let row = geo.rowIndex(atY: p.y) else { return }
        let ref = rows[row]
        let pts = points(ref)
        let option = NSEvent.modifierFlags.contains(.option)

        // The curve (and the static value of an empty row) is only grabbed IN ITS BAND — 15 % of
        // the row's height above and below the line (@see AutomationBandGeometry.curveGrabY).
        // Before, a drag anywhere in the row moved it: one could no longer hover it without
        // risking knocking it out.
        let mode: BandDrag.Mode
        if pts.isEmpty {
            // A row with no point = a fader. A plugin parameter has no static value on the model's
            // side: its empty row cannot be set, it waits for its first point.
            guard let sv = viewModel.automationStaticValue(ref, on: object),
                  geo.nearLine(p, lineY: geo.y(of: sv, ref: ref, row: row)) else { return }
            mode = .staticValue
        } else if let i = geo.pointHit(at: p, row: row, ref: ref, points: pts) {
            mode = .point(i)
        } else if let lineY = geo.curveY(atX: p.x, ref: ref, row: row, points: pts),
                  geo.nearLine(p, lineY: lineY) {
            if option, let owner = curvableSegment(atX: p.x, ref: ref, points: pts) {
                mode = .curve(owner)
            } else if let seg = geo.segment(atX: p.x, points: pts), !seg.movedPoints.isEmpty {
                mode = .segment(seg.movedPoints)
            } else {
                return
            }
        } else {
            return
        }

        // The halo freezes on what is held, and stays there for the whole gesture: on a POINT it is
        // its own halo that speaks (@see drawCurve), on a segment it is the portion grabbed.
        switch mode {
        case .point: setHover(point: hoverPoint, line: nil)
        default:     setHover(point: nil, line: (row: row, x: Double(p.x)))
        }

        viewModel.select(object.id, additive: false)
        viewModel.beginAutomationEdit()
        drag = BandDrag(ref: ref, row: row, mode: mode, origPoints: pts,
                        origStatic: staticValue(ref), start: p, last: p)
    }

    // MARK: - Curvature

    /// The storage index of the point carrying the curvature of the segment under `x`, if it is
    /// bendable. A FLAT segment is not: the engine returns a straight line whatever the value of
    /// `c` (@see AutomationCurveMath.bezierY), and storing an invisible curvature would bring it
    /// back later, at the first move of an end point.
    private func curvableSegment(atX x: Double, ref: ParamRef, points pts: [AutomationPoint]) -> Int? {
        guard let seg = geo.segment(atX: x, points: pts),
              let owner = seg.curveOwner, let right = seg.right,
              pts.indices.contains(owner), pts.indices.contains(right),
              pts[owner].v != pts[right].v else { return nil }
        return owner
    }

    /// The curvature difference for a vertical movement. The SIGN depends on the segment's
    /// direction: in the engine's model, a positive `c` hollows a rising segment but bulges a
    /// falling one. We compensate here so that the gesture keeps a single promise — the curve
    /// follows the cursor, upwards as downwards.
    private func curveDelta(dy: Double, leftIndex: Int, points pts: [AutomationPoint]) -> Float {
        guard let seg = geo.segment(atX: geo.x(ofT: pts[leftIndex].t) + 0.5, points: pts),
              let right = seg.right, pts.indices.contains(right) else { return 0 }
        let ascending = pts[right].v > pts[leftIndex].v
        let sign: Double = ascending ? 1 : -1
        return Float(sign * dy * 2 / Self.curveDragTravel)
    }

    // MARK: - Time and grid

    /// The value rounded to the parameter's step — a whole dB, pan by 10 % (@see
    /// ParamRef.valueStep), the same steps as the inspector's boxes. Driven by the SAME switch as
    /// time: when the snap is on, a curve lands on round figures; ⌘ frees both axes at once, for
    /// fine adjustment.
    private func snappedV(_ v: Float, ref: ParamRef) -> Float {
        guard snapOn, let step = ref.valueStep, step > 0 else { return v }
        return ((v / step).rounded() * step).clamped(to: ref.valueRange)
    }

    /// The same rounding, for a DIFFERENCE: no bounding to the range, a difference is not a value.
    private func snappedStep(_ dv: Float, ref: ParamRef) -> Float {
        guard snapOn, let step = ref.valueStep, step > 0 else { return dv }
        return (dv / step).rounded() * step
    }

    /// A local x → the time relative to the object, snapped to the GLOBAL grid (snapping is
    /// reasoned in absolute time, as in the piano roll: it is the timeline's grid one aims at, not
    /// a grid belonging to the object).
    private func snappedT(atX x: Double) -> Double {
        let t = geo.t(atX: x)
        guard snapOn, snapGrid > 0 else { return t }
        let absT = object.startTime + t
        let snapped = (absT / snapGrid).rounded() * snapGrid
        return (snapped - object.startTime).clamped(to: 0...max(0, geo.maxT))
    }

    private func setReadout(row: Int, x: Double, ref: ParamRef, value: Float) {
        readout = (row, x, viewModel.automationReadout(ref, value: value, on: object))
    }
}

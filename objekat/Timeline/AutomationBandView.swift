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
/// with a halo AND SAYS ITS VALUE as soon as the cursor comes into its zone — the same badge as
/// the one a gesture shows, so that reading and moving speak alike. The rest of the row answers to
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
    /// The EDIT time of the band's left edge — the object's start, or 0 for an infinite bus, whose
    /// band spans the whole timeline. The band's own geometry is relative (@see the note above), so
    /// this is the one number needed to turn a click in it back into a moment of the piece.
    var bandStartTime: Double = 0
    /// Moves the cursor (a plain click), in EDIT time. The counterpart of `PianoRollView`'s
    /// `onSeekToTime`: the parent owns the snap, the seek and the transport.
    var onSeekToTime: (Double) -> Void = { _ in }

    private var rows: [ParamRef] { object.automationRows }
    private var pending: ParamRef? { object.pendingAutomationParam }
    private var tint: Color { object.customColor ?? viewModel.stemColor(for: object.id) }

    private var geo: AutomationBandGeometry {
        AutomationBandGeometry(rows: rows, pixelsPerSecond: pixelsPerSecond,
                               laneStep: laneStep, rowHeight: rowHeight,
                               bandWidth: max(1, bandWidth))
    }

    /// The effective snap — of TIME, and of time alone: it decides where a point is PLACED, never
    /// what it is WORTH (the value has a detent of its own, unconditional — @see detentedValue).
    /// REREAD ON EVERY STEP of the gesture: ⌘ has to be able to invert the snap
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

    /// The badge's clearance from the point it names (@see drawReadout): to its right by `dx`, and
    /// `gap` clear of it vertically. WIDER under a gesture than under a hover — dragging, the
    /// pointer sits ON the point and its glyph spills down and to the right of its hotspot, so the
    /// figure has to step aside further to stay readable.
    private static let readoutOffset: (hover: (dx: Double, gap: Double), drag: (dx: Double, gap: Double))
        = (hover: (10, 5), drag: (18, 11))
    /// The badge's height, as guessed BEFORE drawing — `beginDrag` has to choose its side without a
    /// `GraphicsContext` to measure in (@see BandDrag.badgeBelow). A 9 pt line, rounded up.
    private static let readoutHeightGuess: Double = 12

    @State private var lastTap: (time: Date, loc: CGPoint) = (.distantPast, .zero)
    @State private var drag: BandDrag? = nil
    /// The value shown during a gesture — and, with no gesture, that of the point HOVERED (@see
    /// showPointValue): on a row some fifteen pixels tall, the eye reads no precision at all, and
    /// that figure is the only usable feedback. ONE state for the two, deliberately: the gesture
    /// writes over it and has priority as long as it lasts.
    ///
    /// `y` is the height to read it at: that of the point (hovered or dragged), so the figure is
    /// where the eye already is. nil = pinned at the TOP of the row, which is left to the
    /// CURVATURE alone — it names a bend, not a value, and has no point to sit by (@see
    /// drawReadout).
    @State private var readout: (row: Int, x: Double, y: Double?, text: String)? = nil
    /// The HOVERED point (its row plus its storage index): the one that would answer the click. It
    /// carries a white halo, the same promise as the veil over an object's six zones (@see
    /// ClipEditZonesOverlay) — the view lights up where the hand is about to act, before one presses.
    @State private var hoverPoint: (row: Int, index: Int)? = nil
    /// The hovered line: the row, and the x where the cursor met it. The curve lights up there
    /// over a few dozen pixels — the counterpart of a point's halo, for a gesture that plays out
    /// along the line (a segment, or the static value of an empty row).
    @State private var hoverLine: (row: Int, x: Double)? = nil
    /// The row the cursor is simply IN — not a point, not a line. The transform box can span rows,
    /// and its grips have to show the moment the hand comes anywhere over it; `hoverPoint` /
    /// `hoverLine` are nil in a row's dead space, which is precisely where one aims a grip.
    @State private var hoverRowIndex: Int? = nil

    /// One row under a transform: which curve, which of its points, and what the WHOLE lane was.
    /// The lane whole and not just the selected points, exactly as `BandDrag.origPoints` already
    /// does for the single-row modes — the mutation writes the lane back, by storage index.
    private struct TransformRow {
        let param:      ParamRef
        let row:        Int                  // display row: geometry and nothing else
        let indices:    [Int]                // storage indices, validated at the grab
        let origPoints: [AutomationPoint]
    }

    /// The gesture under way. The mode is decided ONCE, on the first movement, from the zone
    /// grabbed and ⌥; the points are named by their STORAGE index, stable even if the drag takes a
    /// point past its neighbour (@see AutomationBandGeometry.ordered).
    private struct BandDrag {
        enum Mode {
            case point(Int)         // the value plus the time of the grabbed point
            case segment([Int])     // the value of the points holding the segment (1 on a plateau)
            case curve(Int)         // the curvature carried by the segment's left-hand point
            case staticValue        // a row with no point: the model's static value
            /// A stretch of TIME being traced over the rows the drag crosses — not a rectangle
            /// laid over the points it happens to cover (@see EditViewModel+AutomationZone, which
            /// says why the difference decides what can be copied). `base` = the zone already
            /// there when ⇧ was held at the first pixel, which the new one is UNIONED with; nil
            /// otherwise, and the zone simply replaces. Read once, at the first pixel: a hand
            /// letting go of ⇧ mid-drag is resting a finger, not changing its mind.
            case timeZone(base: AutomationTimeSelection?)
            /// A grip of the transform box. Everything is FROZEN at the grab: the transformation
            /// always recomputes from the originals (the non-destructive rule), and re-reading the
            /// selection mid-gesture would let a stale index through.
            case transform(handle: AutomationTransform.Handle,
                           rows: [TransformRow],
                           box: CGRect)      // pixels; its Y is what `boxFactor` measures against
        }
        let ref:  ParamRef
        /// The row the gesture STARTED in. For the single-row modes it is the row it acts on; for
        /// `.timeZone` and `.transform`, which cross rows, it serves only to place the badge
        /// (@see drawReadout, badgeBelow).
        let row:  Int
        let mode: Mode
        let origPoints: [AutomationPoint]
        let origStatic: Float
        /// The WHOLE selection this gesture carries, frozen at the grab — non-nil only when the
        /// point (or the segment) grabbed was part of it. nil = the gesture acts on its own row
        /// alone, which is what it has always done.
        let groupRows: [TransformRow]?
        let start: CGPoint
        /// Which side of the point the badge sits on, FROZEN at the grab. Recomputing it at every
        /// step would have it leap over the point the moment the drag skims the height where the
        /// rule changes sides; decided once, it holds for the whole gesture (@see drawReadout).
        let badgeBelow: Bool
        /// The last known cursor position: it allows REPLAYING the gesture without a mouse movement,
        /// when ⌘ flips the snap along the way.
        var last: CGPoint
        /// What the grip is asking for RIGHT NOW — written on every step of a `.transform`, and
        /// read by the drawing alone. The gesture does not consult it: the transformation still
        /// recomputes from the originals, and a request read back would be the first link of the
        /// feedback loop `transformBox` exists to prevent.
        var live: AutomationTransform.Request? = nil
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                for (i, ref) in rows.enumerated() { draw(row: i, ref: ref, in: &ctx) }
                // The zone and the transform box, above every row and below the badge: they
                // BELONG to no row — the rectangle is traced across them and the box spans as many
                // of them as the selection touches.
                drawSelection(in: &ctx)
                // The badge LAST, over every row: anchored on a hovered point it leans out of its
                // own row (@see drawReadout), and the next row's background would paint over it.
                drawReadout(in: &ctx)
            }
            .allowsHitTesting(false)

            // The interaction layer: it catches taps and drags over the whole band.
            Color.clear
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { handleTap(at: $0.location) })
                .highPriorityGesture(
                    DragGesture(minimumDistance: 3)
                        .onChanged { handleDragChanged($0) }
                        .onEnded   { _ in settleZoneAfterTransform(); drag = nil; readout = nil; clearHover() }
                )
                .onContinuousHover { phase in
                    guard drag == nil else { return }
                    switch phase {
                    case .active(let p): updateCursor(at: p)
                    // No cursor is put back here: the hover that follows sets its own, and leaving
                    // the timeline goes through the tracking view's `mouseExited`. This `.ended`
                    // can arrive AFTER the hover that succeeds it — it would take its claim away
                    // from it.
                    case .ended:         clearHover(); hoverRowIndex = nil
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

    // MARK: - The point selection

    /// The selection as the geometry and the transform want it: one entry per ROW OF THIS BAND,
    /// carrying the display row, the storage indices VALIDATED against what the curve holds now,
    /// and the row's whole point list.
    ///
    /// Recomputed rather than cached, and that is deliberate: a storage index is only true of the
    /// curve it was read off (@see AutomationPointRef), so the one place it may be turned into an
    /// actual point is the moment it is used.
    private func selectedRows()
        -> [(row: Int, ref: ParamRef, indices: [Int], points: [AutomationPoint])] {
        guard !viewModel.selectedAutomationPoints.isEmpty else { return [] }
        var out: [(row: Int, ref: ParamRef, indices: [Int], points: [AutomationPoint])] = []
        for (i, ref) in rows.enumerated() {
            let idx = viewModel.selectedIndices(objectID: object.id, param: ref)
            if !idx.isEmpty { out.append((row: i, ref: ref, indices: idx, points: points(ref))) }
        }
        return out
    }

    /// The box that MEASURES. FROZEN during a transform (@see BandDrag.Mode.transform): a box
    /// recomputed from points the gesture is itself moving runs away under the hand — the classic
    /// exponential blow-up of a scale by grip. Everywhere else it follows the material, which is
    /// what makes a group move read as carrying the box along.
    ///
    /// It is also the box the HIT TEST and the cursor read, both of which happen outside a drag,
    /// where frozen and live are the same thing.
    private func transformBox() -> CGRect? {
        if let d = drag, case .transform(_, _, let box) = d.mode { return box }
        if let r = zoneRect() { return r }
        // NO BOX FOR A SINGLE POINT. Eight grips round one point say nothing a point does not
        // already say — it is dragged, and that is the gesture of always. The box is what appears
        // when there is a RELATION to act on: several points, or a stretch of time.
        let sel = selectedRows()
        guard sel.reduce(0, { $0 + $1.indices.count }) >= 2 else { return nil }
        return geo.selectionBox(sel)
    }

    /// The zone's own rectangle: its time range in X, the rows it names in Y. nil when there is no
    /// zone on THIS object's band.
    ///
    /// Unlike `selectionBox`, both axes are the FRAME and neither is the matter — which is the
    /// whole difference between a zone and a bounding box, and the reason a grip pulled sideways
    /// now stretches the passage rather than the points' own envelope.
    private func zoneRect() -> CGRect? {
        guard let z = viewModel.automationTimeSelection, z.objectID == object.id else { return nil }
        let idx = z.params.compactMap { rows.firstIndex(of: $0) }
        guard let lo = idx.min(), let hi = idx.max() else { return nil }
        var x0 = geo.x(ofT: z.timeRange.lowerBound)
        var x1 = geo.x(ofT: z.timeRange.upperBound)
        if x1 - x0 < AutomationBandGeometry.boxMinSide {
            let mid = (x0 + x1) / 2
            x0 = mid - AutomationBandGeometry.boxMinSide / 2
            x1 = mid + AutomationBandGeometry.boxMinSide / 2
        }
        let top = geo.rowTop(lo), bottom = geo.rowTop(hi) + rowHeight
        return CGRect(x: x0, y: top, width: x1 - x0, height: bottom - top)
    }

    /// The box that is DRAWN, as four corners: the frozen box put through the request the hand is
    /// making. Splitting it from the one above is what stops the rectangle letting go of the
    /// fingers holding it — the pulled edge lands ON the pointer, since `k` is by definition the
    /// ratio that takes it there (@see AutomationTransform.drawnQuad).
    ///
    /// Outside a transform it is the plain rectangle's four corners, so the drawing has one path
    /// and not two.
    private func transformQuad() -> [CGPoint]? {
        guard let box = transformBox() else { return nil }
        guard let d = drag, case .transform = d.mode, let req = d.live else {
            return [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                    CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
        }
        let g = geo
        return AutomationTransform.drawnQuad(req, box: box,
                                             t0: g.t(atX: box.minX), t1: g.t(atX: box.maxX),
                                             xOfT: { g.x(ofT: $0) })
    }

    /// The selection's TIME envelope, taken from the points FROZEN at the grab rather than read
    /// back off the box's pixels: the same numbers the transform will write, with no round trip
    /// through a coordinate conversion that bounds at the band's edges.
    private func transformSpan(_ trows: [TransformRow]) -> AutomationTransform.TimeSpan {
        // A ZONE speaks for itself: its edges are the frame one took hold of, so a sideways grip
        // stretches the PASSAGE and its silences with it. Reading the points' envelope here
        // instead would make the box's left edge and the pivot two different instants — one would
        // pull an edge and watch the matter move against it.
        if let z = viewModel.automationTimeSelection, z.objectID == object.id {
            return AutomationTransform.TimeSpan(t0: z.timeRange.lowerBound,
                                                t1: z.timeRange.upperBound)
        }
        var lo = Double.greatestFiniteMagnitude, hi = -Double.greatestFiniteMagnitude
        for r in trows {
            for i in r.indices where r.origPoints.indices.contains(i) {
                lo = min(lo, r.origPoints[i].t)
                hi = max(hi, r.origPoints[i].t)
            }
        }
        return AutomationTransform.TimeSpan(t0: lo, t1: hi)
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
        let selected = Set(viewModel.selectedIndices(objectID: object.id, param: ref))
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
            // A point RESTING is barely there — small and translucent. It is a handle, not
            // matter: the curve is what one reads, and a row of solid dots competes with the line
            // it is supposed to describe. It comes up to full only when it has something to say —
            // hovered (it will answer the click), held (it is following the mouse), or taken.
            let speaks = idx == held || idx == hovered || selected.contains(idx)
            let r = idx == held ? 6.0 : 4.0
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                     with: .color(tint.opacity(speaks ? 0.95 : 0.4)))
            if idx == held {
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                           with: .color(.white.opacity(0.8)), lineWidth: 1)
            }
            // A SELECTED point wears a RING, and the colour is the piano roll's yellow rather than
            // the white halo one row above: the halo says "this would answer the click", which is
            // a promise about the next instant, and a selection says "this is taken", which is a
            // state. Two different things must not share a vocabulary on the same pixels.
            if selected.contains(idx) {
                let rr = r + 2.5
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr,
                                                  width: rr * 2, height: rr * 2)),
                           with: .color(.yellow), lineWidth: 1.2)
            }
        }
    }

    /// The zone being traced, or the transform box and its eight grips. Drawn ABOVE every row
    /// because neither belongs to one: a rectangle is traced across the rows and the box spans as
    /// many of them as the selection touches.
    private func drawSelection(in ctx: inout GraphicsContext) {
        // While a zone is being traced it is the only thing that speaks, and what is drawn is the
        // ZONE — whole rows, edges snapped — and not the pixels the hand swept. Drawing the raw
        // sweep would promise a rectangle, which is exactly the reading this gesture left behind.
        if let d = drag, case .timeZone = d.mode, let r = zoneRect() {
            ctx.fill(Path(r), with: .color(Color.accentColor.opacity(0.14)))
            ctx.stroke(Path(r), with: .color(Color.accentColor.opacity(0.7)), lineWidth: 1)
            return
        }

        guard let box = transformBox(), let quad = transformQuad() else { return }
        // A settled zone keeps a veil: it is a stretch of time that goes on existing when it holds
        // nothing, and an outline alone on an empty passage reads as a stray frame.
        if drag == nil, let r = zoneRect() {
            ctx.fill(Path(r), with: .color(Color.accentColor.opacity(0.10)))
        }
        // The OUTLINE shows as soon as a selection exists: it is what says the eight grips are
        // somewhere to be had. The GRIPS themselves only show when the hand is over the box —
        // eight white squares standing permanently on a sixteen-pixel row would read as matter.
        var outline = Path()
        outline.addLines(quad)
        outline.closeSubpath()
        ctx.stroke(outline, with: .color(.white.opacity(0.45)),
                   style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        guard showsHandles(box: box) else { return }
        for c in AutomationTransform.quadHandles(quad) {
            let s = 2.5
            let square = CGRect(x: c.x - s, y: c.y - s, width: s * 2, height: s * 2)
            ctx.fill(Path(square), with: .color(.white.opacity(0.92)))
            ctx.stroke(Path(square), with: .color(.black.opacity(0.55)), lineWidth: 0.5)
        }
    }

    /// Are the grips shown? The hover is shut off for the whole of a drag (@see body), so a
    /// transform under way has to say so itself — without that clause the grips would vanish the
    /// instant one took hold of one.
    private func showsHandles(box: CGRect) -> Bool {
        if let d = drag, case .transform = d.mode { return true }
        guard let hr = hoverRowIndex else { return false }
        let top = geo.rowTop(hr)
        return top + rowHeight > box.minY && top < box.maxY
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

    /// The figure for the gesture under way — or for the point hovered. One badge, one wording,
    /// ONE anchor: the point's own height, hover and gesture alike. Only the clearance differs
    /// (@see readoutOffset), the pointer sitting on the point during a gesture. The curvature is
    /// the exception: no value, no point — it stays at the top of the row.
    ///
    /// Kept whole inside the band, never inside the ROW alone: on a fifteen-pixel row a badge
    /// clamped to the row would climb back onto the point it names. It leans above the point, and
    /// flips underneath when there is no room left over it — a choice FROZEN for the whole of a
    /// gesture (@see BandDrag.badgeBelow), since under the hand it is the point that moves.
    private func drawReadout(in ctx: inout GraphicsContext) {
        guard let r = readout, rows.indices.contains(r.row) else { return }
        let rect = CGRect(x: 0, y: geo.rowTop(r.row), width: max(1, bandWidth), height: rowHeight)
        let text = Text(r.text)
            .font(.system(size: 9, weight: .semibold).monospacedDigit())
            .foregroundStyle(Color.white.opacity(0.9))
        let resolved = ctx.resolve(text)
        let size = resolved.measure(in: CGSize(width: 200, height: 20))
        let off = drag == nil ? Self.readoutOffset.hover : Self.readoutOffset.drag
        let x = (r.x + off.dx).clamped(to: 0...max(0, rect.maxX - size.width - 4))
        let y: Double = {
            guard let py = r.y else { return rect.minY + 2 }
            // Above the point by a hair — enough not to cover it nor the curve running through it;
            // underneath when the top of the band is in the way. Under a gesture the side was
            // settled at the grab and does not change any more.
            let below = drag?.badgeBelow ?? (py - size.height - off.gap < 3)
            let placed = below ? py + off.gap : py - size.height - off.gap
            return placed.clamped(to: 3...max(3, geo.interactiveHeight - size.height - 3))
        }()
        let box = CGRect(x: x - 3, y: y - 1, width: size.width + 6, height: size.height + 2)
        ctx.fill(Path(roundedRect: box, cornerRadius: 3), with: .color(.black.opacity(0.55)))
        ctx.draw(resolved, at: CGPoint(x: x, y: y), anchor: .topLeading)
    }

    // MARK: - Cursor

    /// The cursors go through `TimelineCursorKeeper`: it is what has AppKit claim the point,
    /// without which the arrow would come back as soon as the mouse stopped during playback
    /// (@see CursorClaim).
    private func updateCursor(at p: CGPoint) {
        // The row the hand is merely IN, written before anything else: it is what decides whether
        // the transform box shows its grips, and the dead space of a row — where `hoverPoint` and
        // `hoverLine` are both nil — is precisely where one aims one.
        let inRow = geo.rowIndex(atY: p.y)
        if hoverRowIndex != inRow { hoverRowIndex = inRow }

        // A GRIP answers before everything else, in the same order `beginDrag` branches in: a
        // cursor that did not say "grip" where the grip is would promise a gesture the click then
        // fails to start.
        if let box = transformBox(), let h = geo.handleHit(at: p, box: box) {
            clearHover()
            TimelineCursorKeeper.set(handleCursor(h))
            return
        }

        guard let row = inRow else { clearHover(); TimelineCursorKeeper.set(.arrow); return }
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
            showPointValue(row: row, index: i, ref: ref, points: pts)
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

    /// The cursor a grip wears. The two edges of an axis say which axis they travel on; a CORNER
    /// says neither, because it belongs to both — it scales the value with a gradient in time —
    /// and the crosshair is the glyph this band already uses for "two things at once" (⌥ on a
    /// segment, which bends it).
    private func handleCursor(_ h: AutomationTransform.Handle) -> NSCursor {
        switch h {
        case .top, .bottom:   return .resizeUpDown
        case .left, .right:   return .resizeLeftRight
        default:              return .crosshair
        }
    }

    /// Sets what is hovered, without rewriting the state when nothing changes — the hover runs on
    /// every pixel travelled, and one write per pixel would redraw the band for nothing.
    /// The line's x, on the other hand, MUST follow the cursor: it is what walks the halo along.
    private func setHover(point: (row: Int, index: Int)?, line: (row: Int, x: Double)?) {
        if hoverPoint?.row != point?.row || hoverPoint?.index != point?.index { hoverPoint = point }
        if hoverLine?.row != line?.row || hoverLine?.x != line?.x { hoverLine = line }
    }

    /// Leaving a point puts its halo out, and with it the figure it was showing — a value read
    /// stays on screen no longer than the hand that asked for it. The gesture's own figure is out
    /// of reach here: the hover is shut off for the whole of a drag (@see body), so this clears a
    /// HOVER readout only; the guard says so.
    private func clearHover() {
        setHover(point: nil, line: nil)
        if drag == nil, readout != nil { readout = nil }
    }

    // MARK: - Taps (creating / deleting)

    private func handleTap(at p: CGPoint) {
        let now = Date()
        let isDouble = now.timeIntervalSince(lastTap.time) < 0.35
            && hypot(p.x - lastTap.loc.x, p.y - lastTap.loc.y) < 18
        lastTap = (now, p)

        if isDouble, let row = geo.rowIndex(atY: p.y) {
            let ref = rows[row]
            let pts = points(ref)
            if let i = geo.pointHit(at: p, row: row, ref: ref, points: pts) {
                viewModel.removeAutomationPoint(objectID: object.id, param: ref, at: i)
                // The point is gone: its halo and its figure name nothing any more, and no mouse
                // movement will necessarily come to correct them (the hand may very well stay put).
                clearHover()
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
                    v: onLine ?? detentedValue(geo.value(atY: p.y, ref: ref, row: row), ref: ref))
            }
            return
        }

        // A click ON A POINT is a SELECTION, and it does NOT move the cursor — an assumed change:
        // the hand was aiming at a point, not at an instant, and a seek is what the rest of the
        // band is for. The double click keeps working on top of it (the first click selects, the
        // second deletes), the two branches never competing for the same event.
        if let row = geo.rowIndex(atY: p.y) {
            let ref = rows[row]
            let pts = points(ref)
            if let i = geo.pointHit(at: p, row: row, ref: ref, points: pts) {
                let target = AutomationPointRef(objectID: object.id, param: ref, index: i)
                let flags = NSEvent.modifierFlags
                if flags.contains(.command) {
                    // ⌘ toggles ONE point in or out — the only way to correct a rectangle that
                    // brushed a neighbour.
                    var s = viewModel.selectedAutomationPoints
                    if s.contains(target) { s.remove(target) } else { s.insert(target) }
                    viewModel.setAutomationPointSelection(s)
                } else if flags.contains(.shift) {
                    viewModel.setAutomationPointSelection(extendedSelection(to: target))
                } else {
                    viewModel.setAutomationPointSelection([target])
                }
                viewModel.select(object.id, additive: false)
                return
            }
        }

        // A plain click: it selects the carrying object (the inspector follows), and consumes the
        // click so that it does not fall through onto the timeline's canvas.
        //
        // It also drops the point selection. Clicking in the void is how one lets go of a
        // selection everywhere else in the timeline, and a box left standing over points nothing
        // points at any more would go on taking ⌫ from the objects.
        viewModel.clearAutomationPointSelection()
        viewModel.select(object.id, additive: false)
        // ... and it moves the cursor, exactly as a click on a lane does. A curve is read against
        // the moment it plays at, so the one thing one comes here to do with a bare click is to go
        // and listen at that instant. The band being inert was a hole in the canvas: the same
        // gesture, one row lower, did nothing.
        //
        // Below and between the rows too — a double click there creates nothing (there is no row
        // to create it on) and falls through to here: the band is a stretch of the timeline all the
        // way across, and one part of it answering while the next does not is the hole again.
        onSeekToTime(bandStartTime + p.x / pixelsPerSecond)
    }

    /// ⇧+click GROWS the selection to the box holding what was already taken plus the point aimed
    /// at, and everything that box touches comes with it. The rule is not written here: it is
    /// `SynopticMarquee.boundingBox`, word for word and already asserted
    /// (@see tools/test_synoptic_marquee.swift) — the same gesture on another canvas of the same
    /// application, and two copies of it would drift.
    ///
    /// The only thing this function does is lend the rule the identity it speaks: that unit knows
    /// `UUID`s, an automation point is named by its storage slot, so a throwaway id is minted per
    /// point for the length of one click. A ⇧+click is a rare gesture and this is what keeps the
    /// rule single.
    private func extendedSelection(to target: AutomationPointRef) -> Set<AutomationPointRef> {
        var cards: [SynopticMarquee.Card] = []
        var byCard: [UUID: AutomationPointRef] = [:]
        var held: Set<UUID> = []
        var targetID: UUID? = nil
        for (i, ref) in rows.enumerated() {
            for (k, pt) in points(ref).enumerated() {
                let pointRef = AutomationPointRef(objectID: object.id, param: ref, index: k)
                let id = UUID()
                byCard[id] = pointRef
                cards.append(SynopticMarquee.Card(
                    id: id, frame: geo.marqueeRect(of: pt, ref: ref, row: i)))
                if viewModel.selectedAutomationPoints.contains(pointRef) { held.insert(id) }
                if pointRef == target { targetID = id }
            }
        }
        guard let targetID else { return [target] }
        return Set(SynopticMarquee.boundingBox(of: held, extendedTo: targetID, cards: cards)
                    .compactMap { byCard[$0] })
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
            // The point grabbed was part of the selection: the whole of it travels, by ONE common
            // 2D delta. The TIME half is snapped on the grabbed point and the difference handed to
            // the others — snapping each of them in turn would destroy the curve's internal
            // rhythm, which is the same rule `PianoRollView.moveBody` applies to a chord.
            if let trows = d.groupRows {
                applyGroupMove(trows, dt: t - o.t, dy: dy, x: location.x, startedRow: d.row, ref: ref)
                return
            }
            let v = detentedValue((o.v + g.valueDelta(dy: dy, ref: ref)).clamped(to: ref.valueRange), ref: ref)
            viewModel.updateAutomationPoints(objectID: object.id, param: ref) { pts in
                guard pts.indices.contains(i) else { return }
                pts[i].t = t
                pts[i].v = v
            }
            setReadout(row: d.row, x: location.x, ref: ref, value: v)

        case .segment(let idxs):
            // Dragging a straight whose two ends are taken moves the WHOLE selection, and not just
            // that straight: the line is a handle on the matter, and "drag by the line" is how one
            // moves a stretch of curve without aiming at any single point of it.
            if let trows = d.groupRows {
                applyGroupMove(trows, dt: 0, dy: dy, x: location.x, startedRow: d.row, ref: ref)
                return
            }
            let origs = idxs.compactMap { d.origPoints.indices.contains($0) ? d.origPoints[$0].v : nil }
            guard let lo = origs.min(), let hi = origs.max() else { return }
            // The segment moves by a SINGLE difference: clamping it point by point would flatten it
            // against the bound instead of holding it whole.
            let range = ref.valueRange
            // The DIFFERENCE is rounded, not each value: a segment sitting on round figures stays
            // there, and one that was not keeps its internal differences.
            let dv = detentedDelta(g.valueDelta(dy: dy, ref: ref), ref: ref)
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
            readout = (row: d.row, x: Double(location.x), y: nil,
                       text: String(format: L("automation.curveReadout"), c))

        case .staticValue:
            let v = detentedValue((d.origStatic + g.valueDelta(dy: dy, ref: ref)).clamped(to: ref.valueRange), ref: ref)
            viewModel.setAutomationStaticValue(ref, on: object.id, to: v)
            setReadout(row: d.row, x: location.x, ref: ref, value: v)

        case .timeZone(let base):
            // X = a stretch of time, SNAPPED like every other time this band lays down (⌘ inverts
            // it, @see snappedT). Y = the rows the sweep crosses, WHOLE — a zone owns rows, it
            // does not cut into them, which is what `TimeSelection` means by lanes.
            let t0 = min(snappedT(atX: d.start.x), snappedT(atX: location.x))
            let t1 = max(snappedT(atX: d.start.x), snappedT(atX: location.x))
            let band = max(0, g.bandHeight - 1)
            let r0 = g.rowIndex(atY: min(d.start.y, location.y).clamped(to: 0...band)) ?? d.row
            let r1 = g.rowIndex(atY: max(d.start.y, location.y).clamped(to: 0...band)) ?? d.row
            var params = Array(rows[min(r0, r1)...max(r0, r1)])
            var range  = t0...t1
            // ⇧: the new sweep is UNIONED with the zone that was there — the same "extend what is
            // already taken" ⇧ means everywhere else, transposed onto a frame that has two axes.
            if let b = base, b.objectID == object.id {
                range = min(t0, b.timeRange.lowerBound)...max(t1, b.timeRange.upperBound)
                let all = Set(params).union(b.params)
                params = rows.filter { all.contains($0) }
            }
            viewModel.setAutomationZone(objectID: object.id, timeRange: range, params: params)

        case .transform(let handle, let trows, let box):
            // The box is a DIAL: `k` is read as a ratio of pixels between the pulled edge and the
            // anchored one, so it is 1 at rest, 0 on the anchor and unbounded past the grip — and
            // no point has a say in it (@see AutomationTransform.boxFactor).
            let pulled   = handle.pullsTop ? box.minY : box.maxY
            let opposite = handle.pullsTop ? box.maxY : box.minY
            let req = AutomationTransform.request(
                handle,
                span: transformSpan(trows),
                verticalK: AutomationTransform.boxFactor(pulled: pulled, opposite: opposite,
                                                         pointer: Double(location.y)),
                // The snap applies to the TARGET OF THE GRIP and not to the points one by one:
                // snapping each of them would flatten the curve's internal rhythm onto the grid.
                targetT: snappedT(atX: location.x),
                fineTune: NSEvent.modifierFlags.contains(.shift))
            drag?.live = req
            viewModel.applyAutomationTransform(
                objectID: object.id,
                rows: trows.map { (param: $0.param, indices: $0.indices, original: $0.origPoints) },
                request: req)
            readout = (row: d.row, x: Double(location.x), y: nil, text: transformReadout(req))
        }
    }

    /// Moving a whole SELECTION — the shared body of `.point` and `.segment` when what was grabbed
    /// belongs to it. `dt` is the common time delta (zero for a segment, which does not travel in
    /// time); `dy` is the raw vertical travel, read differently on either side of ONE branch:
    ///
    /// - a selection inside ONE row keeps exactly what it has always had: the difference in the
    ///   PARAMETER's own unit, detent included, bounded so the row holds its internal differences
    ///   instead of flattening against a bound;
    /// - a selection spanning SEVERAL rows moves by a NORMALISED difference, applied per row and
    ///   WITHOUT a detent. The branch is necessary and not a refinement: a common delta "of one
    ///   dB" would move a pan row by half its whole range, and a proportion has no unit to round
    ///   to anyway — the rows' own `valueStep`s differ.
    private func applyGroupMove(_ trows: [TransformRow], dt: Double, dy: Double,
                                x: Double, startedRow: Int, ref: ParamRef) {
        let g = geo
        let multi = trows.count > 1
        let dn = multi ? g.normalizedDelta(dy: dy) : 0
        var shown: Float? = nil
        viewModel.updateAutomationRows(objectID: object.id) { lanes in
            for tr in trows {
                guard let li = lanes.firstIndex(where: { $0.param == tr.param }) else { continue }
                let taken = tr.indices.filter {
                    tr.origPoints.indices.contains($0) && lanes[li].points.indices.contains($0)
                }
                guard !taken.isEmpty else { continue }

                var dv: Float = 0
                if !multi {
                    let origs = taken.map { tr.origPoints[$0].v }
                    let range = tr.param.valueRange
                    let low  = range.lowerBound - (origs.min() ?? 0)
                    let high = range.upperBound - (origs.max() ?? 0)
                    dv = detentedDelta(g.valueDelta(dy: dy, ref: tr.param), ref: tr.param)
                    // A selection already spanning the parameter's WHOLE range leaves no room to
                    // move at all, and the bounds cross: then nothing moves, rather than a range
                    // built the wrong way round.
                    if low <= high { dv = dv.clamped(to: low...high) }
                    else           { dv = 0 }
                }

                for i in taken {
                    let o = tr.origPoints[i]
                    lanes[li].points[i].t = o.t + dt
                    lanes[li].points[i].v = multi
                        ? g.denormalized((g.normalized(o.v, ref: tr.param) + dn).clamped(to: 0...1),
                                         ref: tr.param)
                        : o.v + dv
                }
                if tr.row == startedRow, let first = taken.first {
                    shown = lanes[li].points[first].v
                }
            }
        }
        if let v = shown { setReadout(row: startedRow, x: x, ref: ref, value: v) }
    }

    /// The figure a transform shows: ×k and nothing else — the one thing common to every row the
    /// selection spans, and exactly what the gesture carries (the `Request` itself). A time grip
    /// says ×kt, or the delta when the selection has no extent to stretch. A CORNER says ×k too:
    /// the gradient is what the eye reads off the curve, and a second figure for it would name
    /// something no row can be pointed at for.
    private func transformReadout(_ r: AutomationTransform.Request) -> String {
        switch r.time {
        case .scale(_, let k): return String(format: L("automation.timeStretchReadout"), k)
        case .shift(let d):    return String(format: L("automation.timeShiftReadout"), d)
        case .none:
            return r.skew == nil
                ? String(format: L("automation.scaleReadout"), r.valueK)
                : String(format: L("automation.skewReadout"), r.valueK)
        }
    }

    /// Decides the mode on the FIRST movement — the only instant when the zone grabbed and ⌥ are
    /// both known (the drag starts at 3 px, hence after the click).
    /// Decides the mode on the FIRST movement. THE ORDER OF THE BRANCHING IS HALF THE FEATURE:
    ///
    /// 1. a GRIP of the transform box — first, and before the row test itself. A grip laid over a
    ///    point would otherwise be unreachable, and a grip on the bottom edge of the last row can
    ///    fall a pixel outside `bandHeight`, where `rowIndex(atY:)` answers nil;
    /// 2. a POINT. If it is IN the selection the whole selection travels; otherwise the selection
    ///    is dropped and this is the gesture of always;
    /// 3. a LINE / a segment, under the same rule: both its ends taken ⇒ the selection travels;
    /// 4. ⌥ + a line ⇒ the curvature, untouched;
    /// 5. anything else ⇒ a MARQUEE. Those are exactly the two bare `return`s this function used
    ///    to end on — a drag in a row's dead space did nothing at all.
    private func beginDrag(_ value: DragGesture.Value) {
        let p = value.startLocation
        let option = NSEvent.modifierFlags.contains(.option)

        // 1. A grip of the box.
        let sel = selectedRows()
        // `transformBox()` and NOT `geo.selectionBox(sel)`: with a zone the two are different
        // rectangles — the zone's frame and the points' envelope — and a grip drawn on one while
        // being caught on the other is a grip that answers a click several pixels from where it
        // is. It is also what withholds the grips from a lone point, which has none to offer.
        if let box = transformBox(), let handle = geo.handleHit(at: p, box: box),
           let anchorRow = sel.first {
            let trows = sel.map { TransformRow(param: $0.ref, row: $0.row,
                                               indices: $0.indices, origPoints: $0.points) }
            beginDrag(ref: anchorRow.ref, row: geo.rowIndex(atY: p.y) ?? anchorRow.row,
                      mode: .transform(handle: handle, rows: trows, box: box),
                      points: anchorRow.points, groupRows: nil, at: p, edits: true)
            return
        }

        guard let row = geo.rowIndex(atY: p.y) else { return }
        let ref = rows[row]
        let pts = points(ref)

        // The curve (and the static value of an empty row) is only grabbed IN ITS BAND — 15 % of
        // the row's height above and below the line (@see AutomationBandGeometry.curveGrabY).
        // Before, a drag anywhere in the row moved it: one could no longer hover it without
        // risking knocking it out.
        let mode: BandDrag.Mode
        var groupRows: [TransformRow]? = nil

        if pts.isEmpty {
            // A row with no point = a fader. A plugin parameter has no static value on the model's
            // side: its empty row cannot be set, it waits for its first point.
            if let sv = viewModel.automationStaticValue(ref, on: object),
               geo.nearLine(p, lineY: geo.y(of: sv, ref: ref, row: row)) {
                mode = .staticValue
            } else {
                mode = zoneMode()
            }
        } else if let i = geo.pointHit(at: p, row: row, ref: ref, points: pts) {
            groupRows = carriedSelection(containing:
                [AutomationPointRef(objectID: object.id, param: ref, index: i)], sel)
            mode = .point(i)
        } else if let lineY = geo.curveY(atX: p.x, ref: ref, row: row, points: pts),
                  geo.nearLine(p, lineY: lineY) {
            if option, let owner = curvableSegment(atX: p.x, ref: ref, points: pts) {
                mode = .curve(owner)
            } else if let seg = geo.segment(atX: p.x, points: pts), !seg.movedPoints.isEmpty {
                groupRows = carriedSelection(
                    containing: Set(seg.movedPoints.map {
                        AutomationPointRef(objectID: object.id, param: ref, index: $0)
                    }), sel)
                mode = .segment(seg.movedPoints)
            } else {
                mode = zoneMode()
            }
        } else {
            mode = zoneMode()
        }

        // The halo freezes on what is held, and stays there for the whole gesture: on a POINT it is
        // its own halo that speaks (@see drawCurve), on a segment it is the portion grabbed. A
        // zone lights nothing up: what it is about to take it has not taken yet.
        switch mode {
        case .point:   setHover(point: hoverPoint, line: nil)
        case .timeZone: setHover(point: nil, line: nil)
        default:       setHover(point: nil, line: (row: row, x: Double(p.x)))
        }

        // A MARQUEE modifies NOTHING, so it pushes no undo point: an empty entry is one ⌘Z spent
        // on nothing, and on a gesture one makes ten times in a row that is ten of them between
        // the hand and the edit it means to take back. Selecting the carrying object stays —
        // that is what a click anywhere in this band has always meant.
        let edits: Bool = { if case .timeZone = mode { return false } else { return true } }()
        beginDrag(ref: ref, row: row, mode: mode, points: pts, groupRows: groupRows,
                  at: p, edits: edits)
    }

    /// The whole selection, when what was grabbed belongs to it — otherwise nil AND the selection
    /// dropped. "What one grabs decides", the rule the crossfades and the plugin cards already
    /// follow: taking hold of something outside the selection is how one says one has finished
    /// with it.
    private func carriedSelection(
        containing grabbed: Set<AutomationPointRef>,
        _ sel: [(row: Int, ref: ParamRef, indices: [Int], points: [AutomationPoint])]
    ) -> [TransformRow]? {
        guard !grabbed.isEmpty, grabbed.isSubset(of: viewModel.selectedAutomationPoints) else {
            viewModel.clearAutomationPointSelection()
            return nil
        }
        return sel.map { TransformRow(param: $0.ref, row: $0.row,
                                      indices: $0.indices, origPoints: $0.points) }
    }

    /// A sideways grip stretches the passage, and the FRAME has to land where the matter did —
    /// otherwise the box snaps back to its old edges the instant the mouse comes up, and the next
    /// ⌘C copies a length nobody asked for. Done at the END and not on every step: the request is
    /// always read against the zone frozen at the grab, and moving that zone mid-gesture is the
    /// first link of the feedback loop `transformBox` exists to prevent.
    private func settleZoneAfterTransform() {
        guard let d = drag, case .transform = d.mode, let r = d.live,
              let z = viewModel.automationTimeSelection, z.objectID == object.id else { return }
        let lo = AutomationTransform.movedT(r, z.timeRange.lowerBound)
        let hi = AutomationTransform.movedT(r, z.timeRange.upperBound)
        guard lo != z.timeRange.lowerBound || hi != z.timeRange.upperBound else { return }
        viewModel.setAutomationZone(objectID: z.objectID, timeRange: min(lo, hi)...max(lo, hi),
                                    params: z.params)
    }

    /// A zone starting. What it decides HERE, at the first pixel, and never again: whether the
    /// sweep EXTENDS the zone already there (⇧) or replaces it, and which zone that was — so that
    /// widening and narrowing the sweep both recompute from the same ground instead of piling up.
    ///
    /// ⌘ NO LONGER FLIPS. It inverts the SNAP, as it does on every other time this band lays down
    /// (@see snappedT), and one key cannot mean two things inside one gesture. What ⌘ used to buy
    /// — taking points away from a selection — belongs to clicking them, where it still works;
    /// what a zone is for is a passage, and a passage with holes in it is not one.
    private func zoneMode() -> BandDrag.Mode {
        let base = NSEvent.modifierFlags.contains(.shift)
            ? viewModel.automationTimeSelection : nil
        return .timeZone(base: base)
    }

    /// Lays the gesture's state down — the one place `BandDrag` is built, so the undo rule and the
    /// badge's frozen side cannot be forgotten by one branch out of six.
    private func beginDrag(ref: ParamRef, row: Int, mode: BandDrag.Mode,
                           points pts: [AutomationPoint], groupRows: [TransformRow]?,
                           at p: CGPoint, edits: Bool) {
        viewModel.select(object.id, additive: false)
        if edits { viewModel.beginAutomationEdit() }
        drag = BandDrag(ref: ref, row: row, mode: mode, origPoints: pts,
                        origStatic: staticValue(ref), groupRows: groupRows, start: p,
                        badgeBelow: p.y - Self.readoutHeightGuess - Self.readoutOffset.drag.gap < 3,
                        last: p)
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

    /// The value brought onto the parameter's DETENT — a whole dB, pan by 10 % (@see
    /// ParamRef.valueStep), the same steps as the inspector's boxes.
    ///
    /// UNCONDITIONAL, and that is the correction of 19 September 2026: it used to be driven by the
    /// same switch as time, so turning the snap off gave -3.4 dB curves and ⌘ freed an axis nobody
    /// had asked to free. The snap is about the GRID, hence about TIME — where a point is PLACED —
    /// and a value has nothing to place itself against; the step is there to lower the precision,
    /// which is wanted whether or not one is working on the grid. The same rule and the same
    /// reasoning as the pan's detent (@see EditViewModel+Pan, which says why a modifier leaving
    /// 13 % behind in the file is the intermediate value under another name).
    ///
    /// It lives HERE, at the hand's door, and never in the model: a plugin parameter has no step
    /// (a normalised 0…1 has no unit to round to), `setAutomationStaticValue` goes on through the
    /// exact doors, and what a curve pushes to the engine is untouched.
    private func detentedValue(_ v: Float, ref: ParamRef) -> Float {
        guard let step = ref.valueStep, step > 0 else { return v }
        return ((v / step).rounded() * step).clamped(to: ref.valueRange)
    }

    /// The same detent, for a DIFFERENCE: no bounding to the range, a difference is not a value.
    private func detentedDelta(_ dv: Float, ref: ParamRef) -> Float {
        guard let step = ref.valueStep, step > 0 else { return dv }
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

    /// The gesture's badge, at the height of the VALUE being set — the same anchor as the hover's
    /// (@see showPointValue): the figure follows the point instead of waiting at the top of the row
    /// while the eye is elsewhere. Only the clearance differs, the pointer being on the point here
    /// (@see readoutOffset).
    private func setReadout(row: Int, x: Double, ref: ParamRef, value: Float) {
        readout = (row, x, geo.y(of: value, ref: ref, row: row),
                   viewModel.automationReadout(ref, value: value, on: object))
    }

    /// The figure a point shows ON PLAIN HOVER — the same badge and the same words as the
    /// gesture's (@see drawReadout, automationReadout): on a row some fifteen pixels tall the eye
    /// reads no value at all, and reading one must not say something other than moving it. It
    /// changes nothing and creates no undo: it only puts into words the point the halo is already
    /// naming.
    ///
    /// Anchored on the POINT — its x AND its height: a badge at the top of the row while the eye
    /// is on a point halfway down it names it from too far away. Only the POSITION differs from
    /// the gesture's badge; the wording and the look are the same, so that the two read as one
    /// piece of information. The badge does not shiver under the hand either, and the state is
    /// written once per point hovered instead of once per pixel travelled (the same concern as
    /// `setHover`).
    private func showPointValue(row: Int, index: Int, ref: ParamRef, points pts: [AutomationPoint]) {
        guard pts.indices.contains(index) else { return }
        let p = pts[index]
        let x = geo.x(ofT: p.t)
        let y = geo.y(of: p.v, ref: ref, row: row)
        let text = viewModel.automationReadout(ref, value: p.v, on: object)
        if readout?.row != row || readout?.x != x || readout?.y != y || readout?.text != text {
            readout = (row: row, x: x, y: y, text: text)
        }
    }
}

import AppKit
import SwiftUI

// MARK: - What the pointer is over

/// The pointer readout the canvas window shows under the plot: the x and y under the pointer in the
/// axes' own units, and the base image's value there when the image carries one (@see
/// ScriptCanvasImage.value). Written by the plot, read by the window's bottom bar. Strings, already
/// formatted (@see CanvasFormat): the bar has nothing to compute.
@Observable final class ScriptCanvasPointer {
    var xText = ""
    var yText = ""
    var valueText = ""

    func set(x: String, y: String, value: String) {
        if xText != x { xText = x }
        if yText != y { yText = y }
        if valueText != value { valueText = value }
    }

    func clear() { set(x: "", y: "", value: "") }
}

// MARK: - The plot

/// The surface a script canvas is drawn and driven on (plan §4 "Plot"): the base image, the layers
/// the script laid over it, the raw TRACE of every gesture the script has not yet reflected, the
/// gesture in progress, a playhead and a caret, and two rulers. Flipped (0 at the top, like the
/// viewport's screen y), 56 pt of ruler on the left and 22 pt on top.
///
/// The view decides NOTHING about what a gesture means. It turns the hand into the store's three
/// doors — `addRect`, `addStroke`, `addPoint` — and into a pan, a zoom or a seek; the geometry is
/// `CanvasViewport`'s (@see ScriptCanvasGeometry), the history, the layers and the transport the
/// store's. It holds no copy of any of it: every draw reads the store again, and the store being
/// `@Observable`, an observation armed on `canvases` is what says "redraw" (the viewports are not
/// observed — the window layer forwards `viewportChanged`).
///
/// The cursor is NOT set here (a permanent point of the project: @see CursorClaim) — the window lays
/// a `.cursorZone` over the plot's area. Entering the plot hands the timeline's own cursor back.
@MainActor
final class ScriptCanvasPlotNSView: NSView {

    static let leftRuler: CGFloat = 56
    static let topRuler: CGFloat = 22
    /// The alpha of one disc of a stroke's raw trace. Purely visual (the script's veil replaces the
    /// trace as soon as it arrives), and cumulative: passing again darkens more.
    static let traceDiscAlpha: CGFloat = 0.15
    /// A click that travels less than this (points) is a click, not a drag.
    static let clickSlop: CGFloat = 3

    let store: ScriptCanvasStore
    let canvasID: UUID
    let pointer: ScriptCanvasPointer

    private enum Gesture {
        /// The Hand: `moved` once the travel is over the slop (then it pans, until the button goes up).
        case pan(start: CGPoint, last: CGPoint, moved: Bool)
        case rect(start: CGPoint, current: CGPoint)
        /// `points` are in DATA units (kept as the hand draws them, whatever the view does meanwhile);
        /// `last` is the last SAMPLED screen point; the brush and the scale are frozen at mouseDown.
        case stroke(points: [CanvasPoint], last: CGPoint, sizeX: Double, sizeY: Double,
                    scaleX: Double, scaleY: Double)
    }

    private var gesture: Gesture? = nil
    private var trackingArea: NSTrackingArea? = nil
    private var observing = false
    private var timer: Timer? = nil
    private var lastMarks: [CGFloat] = []
    private var scrollLock = TimelineView.ScrollAxisLock()

    init(store: ScriptCanvasStore, canvasID: UUID, pointer: ScriptCanvasPointer) {
        self.store = store
        self.canvasID = canvasID
        self.pointer = pointer
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has no place here") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Geometry

    /// Where the image is drawn, the rulers excluded. View coordinates.
    private var plotRect: CGRect {
        CGRect(x: Self.leftRuler, y: Self.topRuler,
               width: max(0, bounds.width - Self.leftRuler), height: max(0, bounds.height - Self.topRuler))
    }

    /// The store's viewport, in the plot's REAL size (the store may still hold the nominal one, or the
    /// one of the window before it was resized).
    private func viewport() -> CanvasViewport? {
        let r = plotRect
        guard r.width > 1, r.height > 1, let v = store.viewport(canvasID) else { return nil }
        return v.resized(width: Double(r.width), height: Double(r.height))
    }

    /// Brings the store's idea of the plot's size into line with the real one. Not a loop: the
    /// store answers `viewportChanged`, which finds the sizes equal and stops.
    private func syncViewportSize() {
        let r = plotRect
        guard r.width > 1, r.height > 1, let v = store.viewport(canvasID) else { return }
        if abs(v.width - Double(r.width)) > 0.5 || abs(v.height - Double(r.height)) > 0.5 {
            store.setViewport(canvasID, v.resized(width: Double(r.width), height: Double(r.height)))
        }
    }

    override func layout() {
        super.layout()
        syncViewportSize()
        needsDisplay = true
    }

    // MARK: Redrawing

    /// Called by the window layer when the viewport moved (a script-side change of world, `view` from
    /// the hand's door, Fit).
    func viewportDidChange() {
        syncViewportSize()
        needsDisplay = true
    }

    /// The canvas changed (any of it): redraw, and follow the transport.
    func stateDidChange() {
        needsDisplay = true
        syncTimer()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            arm()
            syncTimer()
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    /// An observation armed on the store's canvases: it fires ONCE, on the first change, and is armed
    /// again after the hop (the change is read on `willSet`, so the redraw waits for the new value).
    private func arm() {
        guard !observing else { return }
        observing = true
        withObservationTracking {
            _ = store.canvases[canvasID]
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.observing = false
                    guard self.window != nil else { return }
                    self.stateDidChange()
                    self.arm()
                }
            }
        }
    }

    /// A 30 Hz tick while the transport runs: it moves the playhead (only a strip of the plot is
    /// invalidated — the images underneath are not redrawn) and lets the store notice the end.
    private func syncTimer() {
        let playing = store.canvases[canvasID]?.transport.playing ?? false
        if playing, timer == nil {
            let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !playing, timer != nil {
            timer?.invalidate()
            timer = nil
            needsDisplay = true   // the playhead goes back to the caret
        }
    }

    private func tick() {
        store.settleTransport(canvasID)
        guard let c = store.canvases[canvasID], let world = c.world, let vp = viewport() else { return }
        let x = plotRect.minX + CGFloat(vp.screenX(forWarped: world.x.warp(store.position(of: canvasID))))
        // The old and the new place of the playhead.
        for old in lastMarks { setNeedsDisplay(CGRect(x: old - 7, y: 0, width: 14, height: bounds.height)) }
        setNeedsDisplay(CGRect(x: x - 7, y: 0, width: 14, height: bounds.height))
        lastMarks = [x]
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let gc = NSGraphicsContext.current else { return }
        let ctx = gc.cgContext
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        guard let c = store.canvases[canvasID] else { return }
        let plot = plotRect
        guard plot.width > 1, plot.height > 1 else { return }

        ctx.saveGState()
        ctx.clip(to: plot)
        NSColor.black.setFill()
        plot.fill()
        if let world = c.world, let vp = viewport() {
            ctx.interpolationQuality = .low
            if let base = c.image { drawImage(base, alpha: 1, in: ctx, world: world, vp: vp) }
            for layer in ScriptCanvasStore.layersInDrawOrder(c.layers) {
                drawImage(layer.image, alpha: CGFloat(layer.opacity), in: ctx, world: world, vp: vp)
            }
            drawTraces(c, in: ctx, world: world, vp: vp)
            drawGesture(c, in: ctx, world: world, vp: vp)
            drawMarks(c, in: ctx, world: world, vp: vp)
        }
        ctx.restoreGState()

        if let world = c.world, let vp = viewport() {
            drawRulers(c, in: ctx, world: world, vp: vp)
            drawMarkTriangles(c, in: ctx, world: world, vp: vp)
        }
    }

    /// An image that covers the WORLD, drawn into the visible window. The source is cropped to whole
    /// pixels (a pixel is never split), and the destination is the cropped rectangle's own place — so
    /// the pixels stay where the axes say they are, at every zoom.
    private func drawImage(_ img: ScriptCanvasImage, alpha: CGFloat, in ctx: CGContext,
                           world: CanvasWorld, vp: CanvasViewport) {
        let wSpanX = world.x.warpedSpan, wSpanY = world.y.warpedSpan
        guard wSpanX > 0, wSpanY > 0, vp.spanX > 0, vp.spanY > 0 else { return }
        let w = Double(img.width), h = Double(img.height)
        // The visible window, in pixels of this image (row 0 = the top = y max).
        let px0 = (vp.x0w - world.x.warpedLo) / wSpanX * w
        let px1 = (vp.x1w - world.x.warpedLo) / wSpanX * w
        let py0 = (world.y.warpedHi - vp.y1w) / wSpanY * h
        let py1 = (world.y.warpedHi - vp.y0w) / wSpanY * h
        let ix0 = max(0, Int(floor(px0))), ix1 = min(img.width, Int(ceil(px1)))
        let iy0 = max(0, Int(floor(py0))), iy1 = min(img.height, Int(ceil(py1)))
        guard ix1 > ix0, iy1 > iy0, px1 > px0, py1 > py0,
              let crop = img.cgImage.cropping(to: CGRect(x: ix0, y: iy0, width: ix1 - ix0, height: iy1 - iy0))
        else { return }
        let plot = plotRect
        let dx0 = (Double(ix0) - px0) / (px1 - px0) * vp.width
        let dx1 = (Double(ix1) - px0) / (px1 - px0) * vp.width
        let dy0 = (Double(iy0) - py0) / (py1 - py0) * vp.height
        let dy1 = (Double(iy1) - py0) / (py1 - py0) * vp.height
        let dest = CGRect(x: plot.minX + dx0, y: plot.minY + dy0, width: dx1 - dx0, height: dy1 - dy0)
        guard dest.width > 0, dest.height > 0, dest.width.isFinite, dest.height.isFinite else { return }
        ctx.saveGState()
        ctx.setAlpha(alpha)
        // The view is flipped, `CGContext.draw` is not: turn the image over inside its own rectangle.
        ctx.translateBy(x: dest.minX, y: dest.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: dest.width, height: dest.height))
        ctx.restoreGState()
    }

    /// A point in DATA units, on screen (view coordinates).
    private func screen(_ p: CanvasPoint, world: CanvasWorld, vp: CanvasViewport) -> CGPoint {
        let plot = plotRect
        return CGPoint(x: plot.minX + vp.screenX(forWarped: world.x.warp(p.x)),
                       y: plot.minY + vp.screenY(forWarped: world.y.warp(p.y)))
    }

    /// The raw trace of every active op the script has not yet reflected (@see
    /// ScriptCanvas.unreflectedOpIDs): the veil the script sends replaces it.
    private func drawTraces(_ c: ScriptCanvas, in ctx: CGContext, world: CanvasWorld, vp: CanvasViewport) {
        let unreflected = c.unreflectedOps
        guard !unreflected.isEmpty else { return }
        for op in unreflected {
            switch op.shape {
            case .rect(let x0, let x1, let y0, let y1):
                let a = screen(CanvasPoint(x: x0, y: y0), world: world, vp: vp)
                let b = screen(CanvasPoint(x: x1, y: y1), world: world, vp: vp)
                strokeOutline(CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                                     width: abs(b.x - a.x), height: abs(b.y - a.y)), in: ctx)
            case .stroke(let points, _, let sizeX, let sizeY):
                drawDiscs(points: points, sizeX: sizeX, sizeY: sizeY, in: ctx, world: world, vp: vp)
            case .point(let x, let y):
                let s = screen(CanvasPoint(x: x, y: y), world: world, vp: vp)
                ctx.setStrokeColor(NSColor.white.cgColor)
                ctx.setLineWidth(1)
                ctx.strokeEllipse(in: CGRect(x: s.x - 6, y: s.y - 6, width: 12, height: 12))
            }
        }
    }

    private func strokeOutline(_ r: CGRect, in ctx: CGContext) {
        guard r.origin.x.isFinite, r.origin.y.isFinite, r.width.isFinite, r.height.isFinite else { return }
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(r.insetBy(dx: 0.5, dy: 0.5))
    }

    /// Dark translucent discs of the brush, a quarter of a diameter apart along the path (@see
    /// CanvasStrokeTrace) — as ellipses of `sizeX × sizeY` WARPED units mapped to the current zoom, so
    /// a brush drawn before a zoom keeps its meaning.
    private func drawDiscs(points: [CanvasPoint], sizeX: Double, sizeY: Double, in ctx: CGContext,
                           world: CanvasWorld, vp: CanvasViewport) {
        let centres = CanvasStrokeTrace.discCentres(points: points, sizeX: sizeX, sizeY: sizeY, world: world)
        let w = sizeX * vp.pointsPerX, h = sizeY * vp.pointsPerY
        guard w.isFinite, h.isFinite, w > 0, h > 0 else { return }
        let plot = plotRect
        ctx.setFillColor(NSColor.black.withAlphaComponent(Self.traceDiscAlpha).cgColor)
        for centre in centres {
            let s = screen(centre, world: world, vp: vp)
            let r = CGRect(x: s.x - w / 2, y: s.y - h / 2, width: w, height: h)
            if r.intersects(plot) { ctx.fillEllipse(in: r) }
        }
    }

    /// The gesture under the hand: the rubber band of a rectangle, the discs of a stroke so far.
    private func drawGesture(_ c: ScriptCanvas, in ctx: CGContext, world: CanvasWorld, vp: CanvasViewport) {
        switch gesture {
        case .rect(let a, let b)?:
            let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.08).cgColor)
            ctx.fill(r)
            strokeOutline(r, in: ctx)
        case .stroke(let points, _, let sizeX, let sizeY, _, _)?:
            drawDiscs(points: points, sizeX: sizeX, sizeY: sizeY, in: ctx, world: world, vp: vp)
        default:
            break
        }
    }

    /// The caret (where playback restarts) and, while playing, the playhead. Lines in the plot; the
    /// triangles on the ruler are `drawMarkTriangles`.
    private func markXs(_ c: ScriptCanvas, world: CanvasWorld, vp: CanvasViewport)
        -> (caret: CGFloat, head: CGFloat?) {
        let plot = plotRect
        let caret = plot.minX + CGFloat(vp.screenX(forWarped: world.x.warp(c.transport.caret)))
        guard c.transport.playing else { return (caret, nil) }
        let head = plot.minX + CGFloat(vp.screenX(forWarped: world.x.warp(store.position(of: canvasID))))
        return (caret, head)
    }

    private func drawMarks(_ c: ScriptCanvas, in ctx: CGContext, world: CanvasWorld, vp: CanvasViewport) {
        let plot = plotRect
        let (caret, head) = markXs(c, world: world, vp: vp)
        ctx.setLineWidth(1)
        if caret >= plot.minX, caret <= plot.maxX {
            ctx.setStrokeColor(NSColor.systemYellow.withAlphaComponent(head == nil ? 0.9 : 0.5).cgColor)
            ctx.move(to: CGPoint(x: caret.rounded() + 0.5, y: plot.minY))
            ctx.addLine(to: CGPoint(x: caret.rounded() + 0.5, y: plot.maxY))
            ctx.strokePath()
        }
        if let head, head >= plot.minX, head <= plot.maxX {
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
            ctx.move(to: CGPoint(x: head.rounded() + 0.5, y: plot.minY))
            ctx.addLine(to: CGPoint(x: head.rounded() + 0.5, y: plot.maxY))
            ctx.strokePath()
        }
        lastMarks = [head ?? caret]
    }

    private func drawMarkTriangles(_ c: ScriptCanvas, in ctx: CGContext, world: CanvasWorld, vp: CanvasViewport) {
        let plot = plotRect
        let (caret, head) = markXs(c, world: world, vp: vp)
        func triangle(at x: CGFloat, color: NSColor) {
            guard x >= plot.minX, x <= plot.maxX else { return }
            ctx.setFillColor(color.cgColor)
            ctx.move(to: CGPoint(x: x - 5, y: Self.topRuler - 8))
            ctx.addLine(to: CGPoint(x: x + 5, y: Self.topRuler - 8))
            ctx.addLine(to: CGPoint(x: x, y: Self.topRuler))
            ctx.closePath()
            ctx.fillPath()
        }
        triangle(at: caret, color: .systemYellow)
        if let head { triangle(at: head, color: .white) }
    }

    // MARK: Rulers

    private func drawRulers(_ c: ScriptCanvas, in ctx: CGContext, world: CanvasWorld, vp: CanvasViewport) {
        let plot = plotRect
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.5),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        ctx.setStrokeColor(NSColor.separatorColor.cgColor)
        ctx.setLineWidth(1)

        // Time (top): ticks hang from the bottom edge of the ruler, labels sit right of the tick.
        ctx.saveGState()
        ctx.clip(to: CGRect(x: plot.minX, y: 0, width: plot.width, height: Self.topRuler))
        let xs = CanvasTicks.ticks(for: world.x, visibleLo: world.x.unwarp(vp.x0w),
                                   visibleHi: world.x.unwarp(vp.x1w), length: vp.width)
        let xStep = world.x.mapping == .lin ? CanvasTicks.linearStep(pointsPerUnit: vp.pointsPerX) : 1
        for t in xs {
            let sx = plot.minX + CGFloat(vp.screenX(forWarped: world.x.warp(t.value)))
            guard sx.isFinite else { continue }
            let len: CGFloat = t.isMajor ? 8 : 4
            ctx.move(to: CGPoint(x: sx.rounded() + 0.5, y: Self.topRuler))
            ctx.addLine(to: CGPoint(x: sx.rounded() + 0.5, y: Self.topRuler - len))
            ctx.strokePath()
            let label = CanvasFormat.tickLabel(t.value, unit: world.x.unit,
                                               step: world.x.mapping == .lin ? xStep : t.value)
            (label as NSString).draw(at: CGPoint(x: sx + 3, y: 3), withAttributes: attrs)
        }
        ctx.restoreGState()

        // Frequency (left): ticks on the right edge, labels right-aligned against them.
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: plot.minY, width: Self.leftRuler, height: plot.height))
        let ys = CanvasTicks.ticks(for: world.y, visibleLo: world.y.unwarp(vp.y0w),
                                   visibleHi: world.y.unwarp(vp.y1w), length: vp.height)
        let yStep = world.y.mapping == .lin ? CanvasTicks.linearStep(pointsPerUnit: vp.pointsPerY) : 1
        for t in ys {
            let sy = plot.minY + CGFloat(vp.screenY(forWarped: world.y.warp(t.value)))
            guard sy.isFinite else { continue }
            let len: CGFloat = t.isMajor ? 8 : 4
            ctx.move(to: CGPoint(x: Self.leftRuler, y: sy.rounded() + 0.5))
            ctx.addLine(to: CGPoint(x: Self.leftRuler - len, y: sy.rounded() + 0.5))
            ctx.strokePath()
            let label = CanvasFormat.tickLabel(t.value, unit: world.y.unit,
                                               step: world.y.mapping == .lin ? yStep : t.value)
            let size = (label as NSString).size(withAttributes: attrs)
            (label as NSString).draw(at: CGPoint(x: Self.leftRuler - len - 3 - size.width,
                                                 y: sy - size.height / 2), withAttributes: attrs)
        }
        ctx.restoreGState()

        // The two edges between the rulers and the plot.
        ctx.move(to: CGPoint(x: plot.minX - 0.5, y: 0))
        ctx.addLine(to: CGPoint(x: plot.minX - 0.5, y: bounds.height))
        ctx.move(to: CGPoint(x: 0, y: plot.minY - 0.5))
        ctx.addLine(to: CGPoint(x: bounds.width, y: plot.minY - 0.5))
        ctx.strokePath()
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero,
                               options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    private func point(of event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    private func clampedToPlot(_ p: CGPoint) -> CGPoint {
        let r = plotRect
        return CGPoint(x: min(max(p.x, r.minX), r.maxX), y: min(max(p.y, r.minY), r.maxY))
    }

    /// A view point as DATA units.
    private func data(_ p: CGPoint, world: CanvasWorld, vp: CanvasViewport) -> CanvasPoint {
        let r = plotRect
        return CanvasPoint(x: world.x.unwarp(vp.warpedX(forScreen: Double(p.x - r.minX))),
                           y: world.y.unwarp(vp.warpedY(forScreen: Double(p.y - r.minY))))
    }

    override func mouseEntered(with event: NSEvent) {
        // The cursor is the canvas's own now (a `.cursorZone` over the plot): the timeline lets go.
        TimelineCursorKeeper.relinquish()
        updatePointer(point(of: event))
    }

    override func mouseExited(with event: NSEvent) { pointer.clear() }

    override func mouseMoved(with event: NSEvent) { updatePointer(point(of: event)) }

    private func updatePointer(_ p: CGPoint) {
        guard let c = store.canvases[canvasID], let world = c.world, let vp = viewport(),
              plotRect.contains(p) else { pointer.clear(); return }
        let r = plotRect
        let wx = vp.warpedX(forScreen: Double(p.x - r.minX))
        let wy = vp.warpedY(forScreen: Double(p.y - r.minY))
        let x = world.x.unwarp(wx), y = world.y.unwarp(wy)
        var value = ""
        if let img = c.image, img.hasValues, world.x.warpedSpan > 0, world.y.warpedSpan > 0 {
            let col = Int(floor((wx - world.x.warpedLo) / world.x.warpedSpan * Double(img.width)))
            let row = Int(floor((world.y.warpedHi - wy) / world.y.warpedSpan * Double(img.height)))
            if let v = img.value(column: col, row: row) {
                value = CanvasFormat.value(v.value, unit: c.valueUnit, isFloor: v.isFloor)
            }
        }
        pointer.set(x: CanvasFormat.axisValue(x, unit: world.x.unit),
                    y: CanvasFormat.axisValue(y, unit: world.y.unit), value: value)
    }

    /// The kind of the script's active tool; nil when it declared none.
    private func activeKind(_ c: ScriptCanvas) -> CanvasToolKind? {
        c.tools.first(where: { $0.id == c.activeTool })?.kind
    }

    private func seek(toScreenX x: CGFloat) {
        guard let c = store.canvases[canvasID], let world = c.world, let vp = viewport() else { return }
        let target = world.x.unwarp(vp.warpedX(forScreen: Double(x - plotRect.minX)))
        try? store.seek(canvasID, to: target)
    }

    override func mouseDown(with event: NSEvent) {
        guard let c = store.canvases[canvasID], c.state == .open, let world = c.world,
              let vp = viewport() else { return }
        let p = point(of: event)
        // A click in the time ruler always seeks, whatever the tool.
        if p.y < Self.topRuler, p.x >= Self.leftRuler {
            seek(toScreenX: p.x)
            return
        }
        guard plotRect.contains(p) else { return }
        updatePointer(p)
        // No tool declared: a left click in the plot does nothing (there is no Hand any more).
        guard let kind = activeKind(c) else { return }
        switch kind {
        case .rect:
            gesture = .rect(start: p, current: p)
        case .stroke:
            // The brush, frozen NOW: a zoom made during the stroke must not change what was drawn.
            var sizePt = 32.0
            if let key = c.tools.first(where: { $0.id == c.activeTool })?.sizeControl,
               let v = c.values[key]?.doubleValue { sizePt = v }
            sizePt = min(1000, max(1, sizePt))
            let size = vp.warpedSize(forPoints: sizePt)
            gesture = .stroke(points: [data(p, world: world, vp: vp)], last: p, sizeX: size.x, sizeY: size.y,
                              scaleX: vp.pointsPerX, scaleY: vp.pointsPerY)
        case .point:
            let d = data(p, world: world, vp: vp)
            _ = try? store.addPoint(canvasID, x: d.x, y: d.y)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = point(of: event)
        updatePointer(p)
        guard let c = store.canvases[canvasID], let world = c.world, let vp = viewport() else { return }
        switch gesture {
        case .pan(let start, let last, let moved)?:
            // The travel over the slop is what makes it a drag; the frame that crosses it only
            // starts the pan (the next ones move the view).
            if moved {
                store.setViewport(canvasID, vp.panned(byScreenDX: Double(p.x - last.x),
                                                      dy: Double(p.y - last.y), in: world))
            }
            gesture = .pan(start: start, last: p,
                           moved: moved || hypot(p.x - start.x, p.y - start.y) >= Self.clickSlop)
        case .rect(let start, _)?:
            gesture = .rect(start: start, current: clampedToPlot(p))
            needsDisplay = true
        case .stroke(var points, let last, let sx, let sy, let scx, let scy)?:
            let q = clampedToPlot(p)
            guard hypot(q.x - last.x, q.y - last.y) >= 0.5,
                  points.count < ScriptCanvasStore.maxStrokePoints else { return }
            points.append(data(q, world: world, vp: vp))
            gesture = .stroke(points: points, last: q, sizeX: sx, sizeY: sy, scaleX: scx, scaleY: scy)
            needsDisplay = true
        case nil:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        let p = point(of: event)
        defer { gesture = nil; needsDisplay = true }
        guard let g = gesture, let c = store.canvases[canvasID], c.state == .open,
              let world = c.world, let vp = viewport() else { return }
        switch g {
        case .pan(let start, _, let moved):
            // A click that did not travel puts the caret there.
            if !moved, hypot(p.x - start.x, p.y - start.y) < Self.clickSlop { seek(toScreenX: start.x) }
        case .rect(let start, _):
            let a = data(start, world: world, vp: vp), b = data(clampedToPlot(p), world: world, vp: vp)
            _ = try? store.addRect(canvasID, x0: a.x, x1: b.x, y0: a.y, y1: b.y)
        case .stroke(let points, _, _, _, let scx, let scy):
            _ = try? store.addStroke(canvasID, points: points, scale: (scx, scy))
        }
    }

    // MARK: Scroll and pinch

    /// Plain = pan. ⇧ = zoom, on the axis the gesture locked to (the timeline's own lock and factors:
    /// @see TimelineView.ScrollAxisLock), anchored under the pointer. The timeline's monitors let a
    /// canvas window's events alone (@see TimelineKeyHandler), so this is the only reader.
    override func scrollWheel(with event: NSEvent) {
        guard let c = store.canvases[canvasID], c.state == .open, let world = c.world,
              let vp = viewport() else { return }
        let p = point(of: event)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.shift) {
            scrollLock.observe(event, now: ProcessInfo.processInfo.systemUptime)
            guard let axis = scrollLock.decide(event, wheelDecidesAtOnce: false) else { return }
            let r = plotRect
            switch axis {
            case .horizontal:
                let dx = event.scrollingDeltaX
                guard dx != 0 else { return }
                let anchor = vp.warpedX(forScreen: Double(p.x - r.minX))
                store.setViewport(canvasID, vp.zoomedX(by: exp(Double(dx) * 0.01), anchor: anchor, in: world))
            case .vertical:
                let dy = event.scrollingDeltaY
                guard dy != 0 else { return }
                let anchor = vp.warpedY(forScreen: Double(p.y - r.minY))
                store.setViewport(canvasID, vp.zoomedY(by: exp(Double(dy) * 0.012), anchor: anchor, in: world))
            }
            return
        }
        // A notch wheel gives lines, not points.
        let scale: Double = event.hasPreciseScrollingDeltas ? 1 : 10
        store.setViewport(canvasID, vp.panned(byScreenDX: Double(event.scrollingDeltaX) * scale,
                                              dy: Double(event.scrollingDeltaY) * scale, in: world))
    }

    /// A pinch zooms time, under the pointer.
    override func magnify(with event: NSEvent) {
        guard event.magnification != 0, let c = store.canvases[canvasID], c.state == .open,
              let world = c.world, let vp = viewport() else { return }
        let anchor = vp.warpedX(forScreen: Double(point(of: event).x - plotRect.minX))
        store.setViewport(canvasID, vp.zoomedX(by: 1 + Double(event.magnification), anchor: anchor, in: world))
    }
}

// MARK: - In SwiftUI

struct ScriptCanvasPlotView: NSViewRepresentable {
    let store: ScriptCanvasStore
    let canvasID: UUID
    let pointer: ScriptCanvasPointer

    func makeNSView(context: Context) -> ScriptCanvasPlotNSView {
        let v = ScriptCanvasPlotNSView(store: store, canvasID: canvasID, pointer: pointer)
        ScriptCanvasWindows.shared.register(plot: v, for: canvasID)
        return v
    }

    func updateNSView(_ v: ScriptCanvasPlotNSView, context: Context) {
        v.needsDisplay = true
    }
}

// MARK: - The cursors of the tools

/// The cursor each kind of tool shows over the plot. Made once and reused (`set()` is called by the
/// claim on every AppKit query); a stroke's circle is cached by whole diameter.
@MainActor
enum ScriptCanvasCursors {

    private static var circles: [Int: NSCursor] = [:]

    /// A circle the size of the brush (points), a dark outline around a light one so that it reads on
    /// the spectrogram and on its black. Clamped: a cursor image has no business being bigger.
    static func circle(diameter: Double) -> NSCursor {
        let d = Int(min(128, max(8, diameter.rounded())))
        if let c = circles[d] { return c }
        let side = CGFloat(d + 4)
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let ring = rect.insetBy(dx: 2.5, dy: 2.5)
            NSColor.black.withAlphaComponent(0.6).setStroke()
            let outer = NSBezierPath(ovalIn: ring.insetBy(dx: -1, dy: -1))
            outer.lineWidth = 1
            outer.stroke()
            NSColor.white.setStroke()
            let path = NSBezierPath(ovalIn: ring)
            path.lineWidth = 1
            path.stroke()
            return true
        }
        let c = NSCursor(image: image, hotSpot: NSPoint(x: side / 2, y: side / 2))
        circles[d] = c
        return c
    }

    static func cursor(for c: ScriptCanvas) -> NSCursor {
        guard let tool = c.tools.first(where: { $0.id == c.activeTool }) else { return .arrow }
        switch tool.kind {
        case .rect, .point:
            return .crosshair
        case .stroke:
            var size = 32.0
            if let key = tool.sizeControl, let v = c.values[key]?.doubleValue { size = v }
            return circle(diameter: size)
        }
    }
}

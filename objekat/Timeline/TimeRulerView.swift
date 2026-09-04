import SwiftUI
import AppKit

// MARK: - Ruler

struct TimeRulerView: View {
    let totalDuration: Double
    let pixelsPerSecond: Double
    let height: Double
    let snapEnabled: Bool
    let snapGrid: Double
    var gridLevels: [GridLevel] = []
    // loopRegion / loopModeEnabled reflect Objekat's state (the user's intent),
    // not the Tracktion engine's internal state.
    var loopRegion: ClosedRange<Double>? = nil
    var loopModeEnabled: Bool = false
    var onLoopRegionChanged: ((ClosedRange<Double>) -> Void)? = nil
    var tempo: Double = 120.0
    var timeSigNumerator: Int = 4
    var timeSigDenominator: Int = 4
    var gridMode: GridMode = .time
    var scrollOffsetX: CGFloat = 0
    var viewportWidth: CGFloat = 0

    private var loopColor: Color { .orange }

    var body: some View {
        ZStack(alignment: .topLeading) {
        Canvas { context, size in
            // The visible window in x: we only draw ticks and labels that are on screen.
            let visX0 = Double(scrollOffsetX) - 1
            let visX1 = viewportWidth > 0
                ? Double(scrollOffsetX) + Double(viewportWidth) + 1
                : Double.greatestFiniteMagnitude
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(Color(nsColor: .windowBackgroundColor))
            )

            // Loop band (background)
            if let lr = loopRegion {
                let x0 = lr.lowerBound * pixelsPerSecond
                let x1 = lr.upperBound * pixelsPerSecond
                let bandRect = CGRect(x: x0, y: 0, width: x1 - x0, height: height)
                context.fill(Path(bandRect),
                             with: .color(loopColor.opacity(loopModeEnabled ? 0.18 : 0.07)))
            }

            // Snap grid (light lines behind the ticks)
            if snapEnabled && snapGrid > 0 && gridMode == .time {
                let steps = Int(totalDuration / snapGrid) + 1
                for i in 0...steps {
                    let x = Double(i) * snapGrid * pixelsPerSecond
                    if x < visX0 || x > visX1 { continue }
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: 0))
                    line.addLine(to: CGPoint(x: x, y: height))
                    context.stroke(line, with: .color(.accentColor.opacity(0.18)), lineWidth: 0.5)
                }
            }

            // Musical grid (bars / beats) — BPM mode, the LOWER zone (continuous with the clips)
            if gridMode == .bpm && tempo > 0 {
                let secondsPerBeat = 60.0 / tempo
                let secondsPerBar  = secondsPerBeat * Double(timeSigNumerator)
                if secondsPerBar > 0 {
                    let barWidthPx      = secondsPerBar * pixelsPerSecond
                    // The same scale as `gridLevels`: when zooming out the bar tick moves to the
                    // multiple (4, 8, 16…) instead of repeating every 2 px, and the label follows
                    // the MAJOR level so that the numbers never touch.
                    let anchorMult      = max(1, Int(BarLadder.anchor(barWidthPx: barWidthPx,
                                                                     minPx: bpmGridThresholdPx)))
                    let majorMult       = max(1, Int(BarLadder.anchor(barWidthPx: barWidthPx,
                                                                     minPx: gridMajorThresholdPx)))
                    let anchorWidthPx   = Double(anchorMult) * barWidthPx
                    // Bars off the anchor: a ghost tick for as long as it stays readable (see gridLevels).
                    let showGhostBars   = anchorMult > 1 && barWidthPx >= barGhostThresholdPx
                    let showBarLabel    = anchorWidthPx > 22
                    let showHalfBarTicks = gridLevels.contains { $0.kind == .halfBar }
                    let showBeatTicks   = gridLevels.contains { $0.kind == .beat }
                    let showSubdivs     = gridLevels.contains { $0.kind == .halfBeat }
                    let showSubdivs2    = gridLevels.contains { $0.kind == .quarterBeat }
                    let totalBars     = Int(totalDuration / secondsPerBar) + 2
                    for bar in 0..<totalBars {
                        let barX = Double(bar) * secondsPerBar * pixelsPerSecond
                        guard barX <= totalDuration * pixelsPerSecond + barWidthPx else { break }
                        if barX < visX0 - anchorWidthPx || barX > visX1 { continue }

                        // Off the anchor: nothing but the possible ghost (the finer subdivisions
                        // do not exist at that level of zoom-out anyway).
                        if bar % anchorMult != 0 {
                            if showGhostBars {
                                var ghost = Path()
                                ghost.move(to: CGPoint(x: barX, y: height * 0.78))
                                ghost.addLine(to: CGPoint(x: barX, y: height))
                                context.stroke(ghost, with: .color(.primary.opacity(0.16)), lineWidth: 0.5)
                            }
                            continue
                        }

                        var barTick = Path()
                        barTick.move(to: CGPoint(x: barX, y: height * 0.54))
                        barTick.addLine(to: CGPoint(x: barX, y: height))
                        context.stroke(barTick, with: .color(.primary.opacity(0.45)), lineWidth: 1)

                        let isMajorBar = bar % majorMult == 0
                        if showBarLabel && isMajorBar {
                            let label = Text(verbatim: "\(bar + 1)")
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(.secondary)
                            context.draw(label, at: CGPoint(x: barX + 3, y: height * 0.55), anchor: .topLeading)
                        }

                        // The bar tick extended into the upper zone plus a time label
                        if showBarLabel && isMajorBar {
                            var upperTick = Path()
                            upperTick.move(to: CGPoint(x: barX, y: height * 0.06))
                            upperTick.addLine(to: CGPoint(x: barX, y: height * 0.43))
                            context.stroke(upperTick, with: .color(.primary.opacity(0.28)), lineWidth: 1)

                            let t = Double(bar) * secondsPerBar
                            let timeStr: String
                            if t >= 60 {
                                timeStr = "\(Int(t / 60)):\(String(format: "%02d", Int(t) % 60))"
                            } else if t >= 1 {
                                let frac = t - t.rounded(.down)
                                timeStr = frac < 0.001 ? "\(Int(t.rounded()))s" : String(format: "%.1f", t) + "s"
                            } else if t > 0 {
                                timeStr = "\(Int((t * 1000).rounded()))ms"
                            } else {
                                timeStr = "0s"
                            }
                            let timeLabel = Text(timeStr)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(Color.secondary.opacity(0.5))
                            context.draw(timeLabel, at: CGPoint(x: barX + 3, y: height * 0.05), anchor: .topLeading)
                        }

                        if showHalfBarTicks {
                            let halfBarX = barX + secondsPerBeat * Double(timeSigNumerator) / 2.0 * pixelsPerSecond
                            var halfBarTick = Path()
                            halfBarTick.move(to: CGPoint(x: halfBarX, y: height * 0.62))
                            halfBarTick.addLine(to: CGPoint(x: halfBarX, y: height))
                            context.stroke(halfBarTick, with: .color(.secondary.opacity(0.28)), lineWidth: 0.5)
                        }

                        if showBeatTicks {
                            for beat in 1..<timeSigNumerator {
                                let beatX = barX + Double(beat) * secondsPerBeat * pixelsPerSecond
                                var beatTick = Path()
                                beatTick.move(to: CGPoint(x: beatX, y: height * 0.68))
                                beatTick.addLine(to: CGPoint(x: beatX, y: height))
                                context.stroke(beatTick, with: .color(.secondary.opacity(0.3)), lineWidth: 0.5)
                            }
                        }

                        if showSubdivs {
                            for beat in 0..<timeSigNumerator {
                                let subdivX = barX + (Double(beat) + 0.5) * secondsPerBeat * pixelsPerSecond
                                var subdivTick = Path()
                                subdivTick.move(to: CGPoint(x: subdivX, y: height * 0.82))
                                subdivTick.addLine(to: CGPoint(x: subdivX, y: height))
                                context.stroke(subdivTick, with: .color(.secondary.opacity(0.18)), lineWidth: 0.5)
                            }
                        }

                        if showSubdivs2 {
                            for beat in 0..<timeSigNumerator {
                                for quarter in [0.25, 0.75] {
                                    let subdivX = barX + (Double(beat) + quarter) * secondsPerBeat * pixelsPerSecond
                                    var subdivTick = Path()
                                    subdivTick.move(to: CGPoint(x: subdivX, y: height * 0.89))
                                    subdivTick.addLine(to: CGPoint(x: subdivX, y: height))
                                    context.stroke(subdivTick, with: .color(.secondary.opacity(0.12)), lineWidth: 0.5)
                                }
                            }
                        }
                    }
                }
            }

            // Time grid — tickInterval = snapGrid in both modes.
            // Time mode: the full-height zone, normal opacity.
            // BPM mode:  the upper zone (0→43 %), slightly greyed (the background).
            // A natural gap 43 %→54 % separates the two zones visually without a line.
            let isBpm        = gridMode == .bpm
            let barXPositions: [Double] = {
                guard isBpm, tempo > 0 else { return [] }
                let spBar = (60.0 / tempo) * Double(timeSigNumerator)
                guard spBar > 0 else { return [] }
                // Only the bars that ACTUALLY carry a time label (the major level) screen the
                // upper zone's graduations. Listing every bar hid them ALL when zooming out: at
                // 2 px a bar, no graduation was more than 20 px from a bar line.
                let step = max(1, Int(BarLadder.anchor(barWidthPx: spBar * pixelsPerSecond,
                                                       minPx: gridMajorThresholdPx)))
                let n = Int(totalDuration / spBar) + 2
                return stride(from: 0, to: n, by: step).map { Double($0) * spBar * pixelsPerSecond }
            }()
            // In time mode: the intervals come from gridLevels (the same source as the canvas plus snap).
            // In bpm mode:  the upper zone always shows a secondary time grid.
            let tickInterval: Double = isBpm
                ? TimeLadder.interval(pixelsPerSecond: pixelsPerSecond, minPx: 10.0)
                : (gridLevels.last?.interval ?? snapGrid)
            let labelInterval: Double = isBpm
                ? TimeLadder.interval(pixelsPerSecond: pixelsPerSecond, minPx: 40.0)
                : (gridLevels.first?.interval ?? tickInterval)
            let totalTicks    = Int(totalDuration / tickInterval) + 1
            let tickBottom   = isBpm ? height * 0.43 : height
            let majorOpacity = isBpm ? 0.28 : 0.60
            let minorOpacity = isBpm ? 0.13 : 0.30

            for i in 0...totalTicks {
                let t = Double(i) * tickInterval
                let x = t * pixelsPerSecond
                guard x <= totalDuration * pixelsPerSecond + 1 else { break }
                if x < visX0 || x > visX1 { continue }

                let isLabel: Bool = {
                    guard labelInterval > tickInterval else { return true }
                    let ratio = t / labelInterval
                    return abs(ratio - ratio.rounded()) < 0.01
                }()

                let tickTop = isBpm
                    ? (isLabel ? height * 0.06 : height * 0.22)
                    : (isLabel ? height * 0.25 : height * 0.55)

                var tick = Path()
                tick.move(to: CGPoint(x: x, y: tickTop))
                tick.addLine(to: CGPoint(x: x, y: tickBottom))
                context.stroke(tick,
                               with: .color(.secondary.opacity(isLabel ? majorOpacity : minorOpacity)),
                               lineWidth: isLabel ? 1 : 0.5)

                let isNearBar = isBpm && barXPositions.contains(where: { abs($0 - x) < 20 })
                if isLabel && !isNearBar {
                    let labelStr: String
                    if t >= 60 {
                        labelStr = "\(Int(t / 60)):\(String(format: "%02d", Int(t) % 60))"
                    } else if t >= 1 {
                        let frac = t - t.rounded(.down)
                        labelStr = frac < 0.001
                            ? "\(Int(t.rounded()))s"
                            : String(format: "%.1f", t).replacingOccurrences(of: ".0", with: "") + "s"
                    } else {
                        labelStr = "\(Int((t * 1000).rounded()))ms"
                    }
                    let label = Text(labelStr)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(isBpm ? Color.secondary.opacity(0.5) : Color.secondary)
                    context.draw(label, at: CGPoint(x: x + 3, y: height * 0.05), anchor: .topLeading)
                }
            }

            // The loop's I (In) and O (Out) markers
            if let lr = loopRegion {
                let alpha: Double = loopModeEnabled ? 1.0 : 0.45
                let markerColor = loopColor.opacity(alpha)
                drawLoopMarker(context: context, x: lr.lowerBound * pixelsPerSecond,
                               height: height, color: markerColor, isIn: true)
                drawLoopMarker(context: context, x: lr.upperBound * pixelsPerSecond,
                               height: height, color: markerColor, isIn: false)
            }
        }
        .frame(width: totalDuration * pixelsPerSecond, height: height)

        // An NSView overlay for dragging the loop markers.
        // It uses hitTest so as to intercept clicks only near the markers (±12 px),
        // letting every other event through to the ScrollView.
        if loopRegion != nil {
            LoopMarkerDragSurface(
                loopRegion: loopRegion,
                pixelsPerSecond: pixelsPerSecond,
                snapEnabled: snapEnabled,
                snapGrid: snapGrid,
                onRegionChanged: { onLoopRegionChanged?($0) }
            )
            .frame(width: totalDuration * pixelsPerSecond, height: height)
        }
        } // ZStack
        .frame(width: totalDuration * pixelsPerSecond, height: height)
    }

    private func drawLoopMarker(context: GraphicsContext, x: Double, height: Double,
                                color: Color, isIn: Bool) {
        let flagH: Double = height * 0.52
        let flagW: Double = 7
        // A vertical line
        var line = Path()
        line.move(to: CGPoint(x: x, y: 0))
        line.addLine(to: CGPoint(x: x, y: flagH))
        context.stroke(line, with: .color(color), lineWidth: 1.5)

        // A triangular flag pointing in the loop's direction
        var flag = Path()
        if isIn {
            flag.move(to: CGPoint(x: x, y: 0))
            flag.addLine(to: CGPoint(x: x + flagW, y: 0))
            flag.addLine(to: CGPoint(x: x, y: flagH * 0.55))
        } else {
            flag.move(to: CGPoint(x: x, y: 0))
            flag.addLine(to: CGPoint(x: x - flagW, y: 0))
            flag.addLine(to: CGPoint(x: x, y: flagH * 0.55))
        }
        flag.closeSubpath()
        context.fill(flag, with: .color(color))

        // The 'I' / 'O' label
        let label = Text(verbatim: isIn ? "I" : "O")
            .font(.system(size: 7, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
        let labelX = isIn ? x + flagW + 2 : x - flagW - 2
        context.draw(label, at: CGPoint(x: labelX, y: flagH * 0.25),
                     anchor: isIn ? .leading : .trailing)
    }

    private func formatTime(_ s: Int) -> String {
        let m = s / 60; let sec = s % 60
        return m > 0 ? "\(m):\(String(format: "%02d", sec))" : "\(sec)s"
    }
}

// MARK: - LoopMarkerDragSurface
//
// An NSViewRepresentable placed as an overlay on the ruler.
// hitTest returns nil everywhere EXCEPT within 12 px of a loop marker,
// which lets the ScrollView capture the events away from the markers.
// The drag is handled through mouseDown/mouseDragged/mouseUp, reliable where SwiftUI's
// DragGesture loses the competition against NSScrollView.

private struct LoopMarkerDragSurface: NSViewRepresentable {
    var loopRegion: ClosedRange<Double>?
    var pixelsPerSecond: Double
    var snapEnabled: Bool
    var snapGrid: Double
    var onRegionChanged: (ClosedRange<Double>) -> Void

    func makeNSView(context: Context) -> MarkerView { MarkerView() }

    func updateNSView(_ v: MarkerView, context: Context) {
        v.loopRegion     = loopRegion
        v.pixelsPerSecond = pixelsPerSecond
        v.snapEnabled    = snapEnabled
        v.snapGrid       = snapGrid
        v.onRegionChanged = onRegionChanged
        v.needsDisplay   = true
    }

    final class MarkerView: NSView {
        var loopRegion: ClosedRange<Double>? = nil
        var pixelsPerSecond: Double = 100
        var snapEnabled: Bool = false
        var snapGrid: Double = 1.0
        var onRegionChanged: ((ClosedRange<Double>) -> Void)? = nil

        private let hitRadius: Double = 12
        private var dragState: DragState? = nil
        // NSEvent monitors — the same pattern as TimelineKeyHandler.
        // SwiftUI intercepts the mouseDowns before AppKit routes them through hitTest,
        // so we short-circuit by listening straight at application level.
        private var monitorDown: Any? = nil
        private var monitorDrag: Any? = nil
        private var monitorUp:   Any? = nil

        private struct DragState {
            enum Marker { case loopIn, loopOut }
            let marker: Marker
            let baseBound: Double
            let startX: CGFloat
        }

        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { registerMonitors() } else { removeMonitors() }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { removeMonitors() }
            super.viewWillMove(toWindow: newWindow)
        }

        private func registerMonitors() {
            removeMonitors()

            monitorDown = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self else { return event }
                let loc = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(loc), let r = self.loopRegion else { return event }
                let inX  = CGFloat(r.lowerBound * self.pixelsPerSecond)
                let outX = CGFloat(r.upperBound * self.pixelsPerSecond)
                let hr   = CGFloat(self.hitRadius)
                if abs(loc.x - inX) < hr {
                    self.dragState = DragState(marker: .loopIn,  baseBound: r.lowerBound, startX: loc.x)
                    return nil
                } else if abs(loc.x - outX) < hr {
                    self.dragState = DragState(marker: .loopOut, baseBound: r.upperBound, startX: loc.x)
                    return nil
                }
                return event
            }

            monitorDrag = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
                guard let self, let ds = self.dragState, let r = self.loopRegion else { return event }
                let x     = self.convert(event.locationInWindow, from: nil).x
                let delta = Double(x - ds.startX) / self.pixelsPerSecond
                var newBound = max(0, ds.baseBound + delta)
                if self.snapEnabled, self.snapGrid > 0 {
                    newBound = (newBound / self.snapGrid).rounded() * self.snapGrid
                }
                let newRegion: ClosedRange<Double>
                switch ds.marker {
                case .loopIn:  newRegion = min(newBound, r.upperBound - 0.05)...r.upperBound
                case .loopOut: newRegion = r.lowerBound...max(newBound, r.lowerBound + 0.05)
                }
                DispatchQueue.main.async { self.onRegionChanged?(newRegion) }
                return nil
            }

            monitorUp = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                guard let self else { return event }
                if self.dragState != nil { self.dragState = nil; return nil }
                return event
            }
        }

        private func removeMonitors() {
            [monitorDown, monitorDrag, monitorUp].compactMap { $0 }.forEach { NSEvent.removeMonitor($0) }
            monitorDown = nil; monitorDrag = nil; monitorUp = nil
        }

        // hitTest is kept only for the resizeLeftRight cursor.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let r = loopRegion else { return nil }
            let inX  = r.lowerBound * pixelsPerSecond
            let outX = r.upperBound * pixelsPerSecond
            if abs(Double(point.x) - inX)  < hitRadius { return self }
            if abs(Double(point.x) - outX) < hitRadius { return self }
            return nil
        }

        override func resetCursorRects() {
            guard let r = loopRegion else { return }
            let h = bounds.height; let hr = CGFloat(hitRadius)
            let inX  = CGFloat(r.lowerBound * pixelsPerSecond)
            let outX = CGFloat(r.upperBound * pixelsPerSecond)
            addCursorRect(CGRect(x: inX  - hr, y: 0, width: hr * 2, height: h), cursor: .resizeLeftRight)
            addCursorRect(CGRect(x: outX - hr, y: 0, width: hr * 2, height: h), cursor: .resizeLeftRight)
        }
    }
}

// MARK: - HoverTracker

// A transparent overlay that captures mouseMoved through an NSTrackingArea (rock-solid macOS)
// without intercepting clicks (hitTest returns nil). A way round the SwiftUI bug where
// .onContinuousHover on multiple .offset views only fires on entry, not continuously.
struct HoverTracker: NSViewRepresentable {
    var onHover: (CGPoint?) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = TrackerView()
        v.onHover = onHover
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let v = nsView as? TrackerView else { return }
        v.onHover = onHover
    }

    final class TrackerView: NSView, TimelineCursorClaiming {
        var onHover: ((CGPoint?) -> Void)?
        private var trackingArea: NSTrackingArea?

        override var isFlipped: Bool { true }  // SwiftUI-compatible coordinates (origin top-left)

        // Transparent to hit-testing → clicks pass through to the SoundBlockViews underneath.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            // A single zone, laid once and for all: `.inVisibleRect` makes it follow the view
            // on its own, and remaking it on every call served no purpose.
            guard trackingArea == nil else { return }
            let t = NSTrackingArea(
                rect: bounds,
                options: [.activeInActiveApp, .mouseMoved, .mouseEnteredAndExited,
                          .inVisibleRect],
                owner: self, userInfo: nil
            )
            addTrackingArea(t)
            trackingArea = t
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.acceptsMouseMovedEvents = true
            // This view covers the whole timeline: it serves as a mark for `TimelineCursorKeeper`
            // to know that it really is the one with the cursor (several project windows can be
            // open). On leaving, it hands back.
            MainActor.assumeIsolated {
                if window != nil {
                    TimelineCursorKeeper.host = self
                } else if TimelineCursorKeeper.host === self {
                    TimelineCursorKeeper.relinquish()
                    TimelineCursorKeeper.host = nil
                }
            }
        }

        override func mouseMoved(with event: NSEvent) {
            lastLocation = event.locationInWindow
            onHover?(convert(event.locationInWindow, from: nil))
            syncCursorClaim()
        }
        override func mouseEntered(with event: NSEvent) {
            lastLocation = event.locationInWindow
            onHover?(convert(event.locationInWindow, from: nil))
            syncCursorClaim()
        }
        override func mouseExited(with event: NSEvent) {
            lastLocation = nil
            onHover?(nil)
            dropCursorClaim()
        }

        // MARK: - Claiming the cursor from AppKit
        //
        // With no claimant for the point under the mouse, AppKit puts the arrow back on every window
        // update (@see CursorClaim). This view cannot claim on its own: its `hitTest` returns `nil`
        // so as to let clicks through.
        //
        // The claim is refreshed on every mouse movement AND on every change of wanted cursor:
        // both sources are needed, since the cursor can be decided AFTER the movement that caused
        // it — which is the case for the piano roll and the automation bands, which set theirs from
        // their own SwiftUI hover.
        private lazy var claim = CursorClaim {
            MainActor.assumeIsolated {
                TimelineCursorKeeper.owned ? TimelineCursorKeeper.current : nil
            }
        }
        private var lastLocation: NSPoint?

        func syncCursorClaim() {
            guard TimelineCursorKeeper.owned, let loc = lastLocation else { dropCursorClaim(); return }
            claim.post(from: self, at: loc)
        }

        func dropCursorClaim() { claim.drop() }
    }
}

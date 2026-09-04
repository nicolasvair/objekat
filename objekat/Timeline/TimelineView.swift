import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The timeline's EXACT scroll position, kept out of `@State`.
///
/// A `@State` invalidates every view that read it while its body was being evaluated. The scroll
/// changing on every frame, reading it in `TimelineView`'s body amounted to rebuilding the WHOLE
/// timeline sixty times a second — the batched waveform `Canvas` included, whose drawing alone
/// costs a dozen milliseconds on a busy project.
///
/// It is an observable object only for the few views that have to STICK to the scroll to the
/// pixel: the ruler (a sticky header) and an infinite bus's band (set on the visible window).
/// Each observes it on its own account, and it alone is re-evaluated. All the rest — the
/// drawing's culling — goes through `cullScrollX`, which only moves in notches. @see TimelineView.cullScrollX
@Observable final class TimelineScrollAnchor {
    var x: CGFloat = 0
    var y: CGFloat = 0
}

/// Sticks its content to the top of the visible window, offsetting it by the vertical scroll.
///
/// It is a separate view — and not a plain `.offset(y:)` in the parent body — because the offset
/// reads off `TimelineScrollAnchor`: laid here, it only invalidates this small container, while
/// in the parent body it would invalidate the whole timeline. @see TimelineScrollAnchor
private struct StickyToViewportTop<Content: View>: View {
    let anchor: TimelineScrollAnchor
    let content: Content

    init(anchor: TimelineScrollAnchor, @ViewBuilder content: () -> Content) {
        self.anchor = anchor
        self.content = content()
    }

    var body: some View { content.offset(y: anchor.y) }
}

struct TimelineView: View {
    var viewModel: EditViewModel
    var playheadPosition: Double = 0
    var selectionCursor: Double = 0
    var isPlaying: Bool = false
    /// Playback suspended (⇧space): the playhead stays where it is and resuming starts from there.
    var isPaused: Bool = false
    var onTogglePlayback: () -> Void = {}
    /// ⇧space: suspend / resume in the same place (without going back to the cursor).
    var onTogglePause: () -> Void = {}
    var onMoveCursor: (Double) -> Void = { _ in }
    var onReturnToZero: () -> Void = {}
    /// S+space: it plays the selection/range only (a temporary solo). The transport (ContentView)
    /// arms the solo, seeks to the start and handles the automatic stop at the end of the window.
    var onSoloPlay: () -> Void = {}

    // Not `private`: read by the gesture handlers (extensions in other files) so as to bound the
    // tool controls to the block's visible portion (see visibleSpan).
    @State var viewportWidth: CGFloat = 800
    @State private var viewportHeight: CGFloat = 400
    @State private var scrollPosition = ScrollPosition()
    @State private var scrollAnchor = TimelineScrollAnchor()
    @State private var currentSelectionCursor: Double = 0

    /// The exact scroll. NOT TO BE READ while a view body is being evaluated: that would restore the
    /// per-frame invalidation `TimelineScrollAnchor` is precisely there to avoid. Reserved for
    /// EVENT handling (hit-tests, gestures, zoom sessions), where reading it records no dependency.
    /// For drawing, it is `cullScrollX`/`cullViewportWidth`.
    /// Not `private`: the gesture handlers live in extensions in other files.
    var scrollOffsetX: CGFloat { scrollAnchor.x }
    var scrollOffsetY: CGFloat { scrollAnchor.y }

    /// The origin of the CULLING WINDOW: the real scroll rounded down to a multiple of
    /// `cullStepPx`. So it only changes once every `cullStepPx` pixels travelled, and it is that —
    /// and not the scroll — that the view's body reads. Between two notches, the ScrollView merely
    /// translates already-rendered content: nothing is rebuilt.
    ///
    /// A corollary to respect everywhere it serves: the real viewport is NOT
    /// `[cullScrollX, cullScrollX + viewportWidth]` but can overflow by one notch to the right. So
    /// we cull on `cullViewportWidth`, which includes that notch — without which a band of content
    /// would stay blank until the next notch.
    @State private var cullScrollX: CGFloat = 0
    private static let cullStepPx: CGFloat = 512
    /// The width to cull: the real viewport plus the possible notch of lag. @see cullScrollX
    private var cullViewportWidth: CGFloat { viewportWidth + Self.cullStepPx }

    // MARK: Zoom session
    // A zoom (the wheel, a drag or a scroll on the pill, a pinch) is a GESTURE, not a series of
    // independent notches: its anchor — the point that must not move under the fingers — is
    // decided ONCE when the session opens, then frozen. Two reasons:
    //   1. `scrollOffsetX/Y` arrive from `onScrollGeometryChange`, hence AFTER the previous notch's
    //      `scrollTo`. Rereading the offset on every notch means rereading it stale — the anchor
    //      slid from one notch to the next (the zoom's 'jumps', all the more visible the faster
    //      the notches follow one another).
    //   2. The rule for choosing the anchor (the cursor visible or not) could flip DURING the
    //      gesture: the zoom changed fixed point in the middle of the movement.
    // The session closes on its explicit gesture (`endHorizontalZoomDrag`) or, for the wheel which
    // has no reliable end, after a silence (`zoomSessionIdleGap`).
    @State private var hZoomAnchorTime: Double = 0
    @State private var hZoomAnchorViewportX: CGFloat = 0
    @State private var hZoomLockedY: CGFloat = 0
    @State private var hZoomHeld: Bool = false            // an explicit gesture under way (a drag)
    @State private var hZoomLastEventTime: TimeInterval = 0
    @State private var vZoomAnchorRelY: CGFloat = 0
    @State private var vZoomBaseHeight: Double = 36
    @State private var vZoomLockedX: CGFloat = 0
    @State private var vZoomHeld: Bool = false
    @State private var vZoomLastEventTime: TimeInterval = 0

    /// The silence beyond which a wheel notch opens a NEW zoom session (and therefore reevaluates
    /// the anchor). Below it, the notches chain within the same gesture.
    private static let zoomSessionIdleGap: TimeInterval = 0.4

    var pixelsPerSecond: Double { viewModel.pixelsPerSecond }
    private var minZoom: Double { max(1, Double(viewportWidth) / totalDuration) }
    private let maxZoom: Double = 200000
    let rulerHeight: Double = 50
    var blockHeight: Double { viewModel.blockHeight }
    var waveformDisplayDB: Double { viewModel.waveformDisplayDB }
    private let laneGap: Double = 4
    private let minBlockHeight: Double = 16
    private var maxBlockHeight: Double {
        max(120, Double(viewportHeight) - Double(rulerHeight) - laneGap - 8)
    }
    private let minLanes: Int = 2

    /// The length the content really takes (plus some room to manoeuvre).
    private var contentDuration: Double {
        let maxObj = viewModel.items.map { $0.startTime + $0.duration }.max() ?? 0
        return max(60, maxObj + 10)
    }

    /// The length of the DISPLAYED timeline. It grows at once when the content does, but never
    /// shrinks under the hand: moving the last sound to the left would shorten the canvas, which
    /// would make the scroll jump and the zoom move under one's fingers. Shrinking is deferred
    /// until a moment when it moves nothing on screen (see `syncStickyDuration`) — only the zoom
    /// BOUNDS follow, never the current zoom.
    private var totalDuration: Double { max(contentDuration, stickyTotalDuration) }
    @State private var stickyTotalDuration: Double = 60

    /// The total width of the timeline's content (px). It serves as the width of an infinite bus,
    /// which takes up its whole lane (it 'processes the whole project'). Reachable by the extensions (hit-tests).
    var contentWidth: Double { totalDuration * pixelsPerSecond }

    @State var waveformCache = WaveformCache()
    @State var lastTapInfo: (time: Date, location: CGPoint) = (.distantPast, .zero)
    @State var moveDrag: MoveDragState? = nil
    @State var resizeDrag: ResizeDragState? = nil
    @State var trimDrag: TrimDragState? = nil
    @State var fadeDrag: FadeDragState? = nil
    @State var timeSelectionDrag: TimeSelectionDragState? = nil
    @State var volumeDrag: VolumeDragState? = nil
    @State var panDrag: PanDragState? = nil
    @State var sendDrag: SendDragState? = nil
    @State var cutDrag: CutDragState? = nil
    @State var slipDrag: SlipDragState? = nil
    @State var loopRangeDrag: LoopRangeDragState? = nil
    @State var keyMonitor: Any? = nil
    @State var scrollMonitor: Any? = nil
    @State var magnifyMonitor: Any? = nil
    @State var rightClickMonitor: Any? = nil
    /// Observers of the application losing / regaining focus: they release the held keys whose
    /// release the LOCAL monitor will never see (⌘-Tab). @see registerKeyMonitor.
    @State var focusObservers: [NSObjectProtocol] = []

    enum ScrollZoomAxis { case horizontal, vertical }

    final class HoverState {
        var position: CGPoint? = nil
        var scrollAccumulator: Float = 0
        var panScrollAccumulator: Float = 0
        var sendScrollAccumulator: Float = 0
        var automationScrollAccumulator: Float = 0
        /// The timestamp of the last continuous setting notch on the wheel (volume / pan / send).
        /// Two notches less than `valueScrollUndoGap` apart belong to the same gesture and share ONE
        /// undo — otherwise the wheel was not undoable at all.
        var lastValueScrollTime: TimeInterval = 0
        var shiftZoomAxis: ScrollZoomAxis? = nil
        var shiftZoomLastEventTime: TimeInterval = 0
        var shiftZoomAccumX: Double = 0
        var shiftZoomAccumY: Double = 0
    }
    @State var hoverState = HoverState()
    @State private var toolHoveredID: UUID? = nil
    // The hovered cut position (a top-level item OR a child) resolved by the canvas on
    // laneEntries, rendered at canvas level. localX = the snapped offset inside the block.
    @State private var cutHover: (id: UUID, localX: Double)? = nil
    // The hovered block under the selection tool plus the editing zone aimed at: it reveals the
    // block's six zones. Resolved by the canvas (like cutHover), rendered by ClipEditZonesOverlay.
    // (internal: a double click on a fade replays it from TimelineView+TapHandler)
    @State var editZoneHover: EditZoneHover? = nil
    /// The tooltip of the hovered tool zone. Carried by the CANVAS (the timeline's only
    /// hit-testable layer) and recomputed on every movement — @see toolZoneHelp.
    @State var toolZoneHelpText: String? = nil
    var laneStep: Double { blockHeight + laneGap }

    private var maxOccupiedLane: Int {
        viewModel.items.map(\.lane).max() ?? 0
    }

    private var totalExtraLanes: Int {
        viewModel.items.reduce(0) { acc, item in acc + item.expandedSpan }
    }

    private var visibleLanes: Int { max(maxOccupiedLane + 2, minLanes) + totalExtraLanes }

    /// The display lanes where the editing point is: the time selection, the insertion caret, and
    /// the lanes of the selected objects. It serves to know WHICH group one is working in (a lane
    /// of a subgroup belongs to the parent too → both bands light up, which is exactly the depth
    /// one is at).
    private var focusedDisplayLanes: Set<Int> {
        var lanes: Set<Int> = []
        if let sel = viewModel.timeSelection { lanes.formUnion(sel.lanes) }
        if let cl = viewModel.caretLane { lanes.insert(cl) }
        if !viewModel.selectedIDs.isEmpty {
            for e in viewModel.laneEntries where viewModel.selectedIDs.contains(e.item.id) {
                lanes.insert(e.displayLane)
            }
        }
        return lanes
    }
    private var canvasHeight: Double { canvasHeight(forBlockHeight: blockHeight) }

    /// The canvas's height for a GIVEN block height — the vertical zoom needs the height AFTER
    /// the change so as to bound the scroll (@see applyVerticalZoom).
    private func canvasHeight(forBlockHeight h: Double) -> Double {
        max(rulerHeight + Double(visibleLanes) * (h + laneGap) + 8, Double(viewportHeight))
    }

    var body: some View {
        ScrollView([.horizontal, .vertical], showsIndicators: true) {
            ZStack(alignment: .topLeading) {
                // Alternating background bands
                ForEach(0..<visibleLanes, id: \.self) { lane in
                    Rectangle()
                        .fill(lane % 2 == 0 ? Color.black.opacity(0.02) : Color.black.opacity(0.0))
                        .frame(width: totalDuration * pixelsPerSecond, height: laneStep)
                        .offset(x: 0, y: rulerHeight + Double(lane) * laneStep)
                        .allowsHitTesting(false)
                }

                // The background of the INNER lanes of an expanded group (nesting included): 'those rows
                // are in this group'. Tinted with the group's colour (custom, otherwise the stem's),
                // bounded at the top and bottom by a border so that the group's span reads at a glance.
                // It grows stronger when the editing point (the caret, the time selection, the selected
                // objects) falls inside it → 'you ARE in this group'. The blocks themselves are never
                // recoloured: only the background speaks.
                // A nested group stacks its band on the parent's → the depth is seen.
                let focusedLanes = focusedDisplayLanes
                ForEach(viewModel.laneEntries) { entry in
                    if entry.item.showsChildrenInline {
                        let gY     = rulerHeight + Double(entry.displayLane) * laneStep
                        let color  = entry.item.customColor ?? viewModel.stemColor(for: entry.item.id)
                        let span   = entry.item.childLaneCount
                        let bandH  = Double(span) * laneStep
                        let bandW  = totalDuration * pixelsPerSecond
                        let inside = !focusedLanes.isDisjoint(
                            with: (entry.displayLane + 1)...(entry.displayLane + span))
                        // The group block's HORIZONTAL span, in the MODEL's geometry (not a gesture
                        // preview): the border's rise and its interruption belong to the BAND, which
                        // does not follow a movement under way — otherwise they would stay hooked to
                        // the block and leave a hole.
                        let gX = entry.item.isInfiniteBus ? 0 : entry.absStart * pixelsPerSecond
                        let gW = entry.item.isInfiniteBus
                               ? contentWidth : max(1, entry.item.duration * pixelsPerSecond)
                        let lisX = min(max(0, gX), bandW)               // the start of the interruption
                        let lisR = min(max(0, gX + gW), bandW)          // ... and its end
                        ZStack(alignment: .topLeading) {
                            Rectangle()
                                .fill(color.opacity(inside ? 0.22 : 0.11))
                                .frame(width: bandW, height: bandH)
                            // The TOP border in TWO segments, interrupted under the block: the group's
                            // material rises there right up under the object (see just after), and a line
                            // across it would restore the very break we have just erased. The BOTTOM
                            // border, for its part, runs from one edge to the other: nothing crosses it.
                            Rectangle()
                                .fill(color.opacity(inside ? 0.8 : 0.35))
                                .frame(width: lisX, height: 1)
                            Rectangle()
                                .fill(color.opacity(inside ? 0.8 : 0.35))
                                .frame(width: bandW - lisR, height: 1)
                                .offset(x: lisR)
                            Rectangle()
                                .fill(color.opacity(inside ? 0.8 : 0.35))
                                .frame(width: bandW, height: 1)
                                .offset(y: bandH - 1)
                        }
                        .frame(width: bandW, height: bandH, alignment: .topLeading)
                        .offset(x: 0, y: gY + laneStep)
                        .allowsHitTesting(false)

                        // The RISE under the block: the group's inside crosses the gutter and slips
                        // under the BOTTOM rounded corners (hence the height `laneGap + radius`), so
                        // that the block sits on its own material instead of floating above it. It
                        // does not go any higher: the block is opaque, and lets only what its bottom
                        // corners cut out be seen — the TOP corners stay on the canvas's background.
                        //
                        // Painted with `interiorPaint` — the EXACT stack of the first inner row, its
                        // opaque base included, the very one the hem fills itself with. Taking only
                        // `color.opacity(...)` would not do: the canvas's alternating band changes
                        // parity from one row to the next, and the rise, laid on the GROUP's row,
                        // would take 2 % too much black (or too little) with respect to the row it
                        // continues.
                        ZStack(alignment: .topLeading) {
                            ForEach(Array(interiorPaint(for: entry).enumerated()), id: \.offset) { _, layer in
                                Rectangle().fill(layer)
                            }
                        }
                        .frame(width: gW, height: laneGap + entry.item.blockCornerRadius)
                        .offset(x: gX, y: gY + blockHeight - entry.item.blockCornerRadius)
                        .allowsHitTesting(false)
                    }
                }

                // A sub-lane background for MIDI clips whose piano roll is open: the same principle
                // as the expanded groups' band (it clarifies the MIDI clip's inside), more discreetly
                // — the piano roll covers the band anyway.
                ForEach(viewModel.laneEntries) { entry in
                    if entry.item.showsPianoRollInline {
                        let gY    = rulerHeight + Double(entry.displayLane) * laneStep
                        let color = viewModel.stemColor(for: entry.item.id)
                        ForEach(0..<SoundObject.pianoRollLaneSpan, id: \.self) { ci in
                            Rectangle()
                                .fill(color.opacity(0.06))
                                .frame(width: totalDuration * pixelsPerSecond, height: laneStep)
                                .offset(x: 0, y: gY + Double(1 + ci) * laneStep)
                                .allowsHitTesting(false)
                        }
                    }
                }

                // A '+' in the drop lane of each expanded group, centred on the in/out range
                ForEach(viewModel.laneEntries) { entry in
                    if entry.item.showsChildrenInline {
                        let dropLaneY  = rulerHeight + Double(entry.displayLane + entry.item.childLaneCount) * laneStep
                        let groupStartX = entry.absStart * pixelsPerSecond
                        let groupW      = entry.item.duration * pixelsPerSecond
                        Text(verbatim: "+")
                            .font(.system(size: 64, weight: .light))
                            .foregroundColor(Color.gray.opacity(0.45))
                            .frame(width: groupW, height: blockHeight, alignment: .center)
                            .offset(x: groupStartX, y: dropLaneY)
                            .allowsHitTesting(false)
                    }
                }

                // Grid
                Canvas { context, size in
                    let snapOn = viewModel.effectiveSnapEnabled
                    let isBpm  = viewModel.gridMode == .bpm
                    guard snapOn || isBpm else { return }
                    let style: StrokeStyle = (!snapOn && isBpm)
                        ? StrokeStyle(lineWidth: 0.5, dash: [2, 3])
                        : StrokeStyle(lineWidth: 0.5)
                    // Clamped to the viewport: we only draw the visible lines, not the
                    // thousands spread over the content's whole width.
                    let visX0 = Double(cullScrollX) - 1
                    let visX1 = Double(cullScrollX) + Double(cullViewportWidth) + 1
                    for level in viewModel.gridLevels {
                        guard level.interval > 0 else { continue }
                        let stepPx = level.interval * pixelsPerSecond
                        guard stepPx > 0 else { continue }
                        let steps  = Int(totalDuration / level.interval) + 1
                        let firstI = max(0, Int((visX0 / stepPx).rounded(.down)))
                        let lastI  = min(steps, Int((visX1 / stepPx).rounded(.up)))
                        guard lastI >= firstI else { continue }
                        for i in firstI...lastI {
                            let x = Double(i) * stepPx
                            guard x <= size.width + 1 else { break }
                            var line = Path()
                            line.move(to: CGPoint(x: x, y: 0))
                            line.addLine(to: CGPoint(x: x, y: size.height))
                            context.stroke(line,
                                           with: .color(.primary.opacity(level.opacity)),
                                           style: style)
                        }
                    }
                }
                .frame(width: totalDuration * pixelsPerSecond, height: canvasHeight - rulerHeight)
                .offset(x: 0, y: rulerHeight)
                .allowsHitTesting(false)

                // A sticky header: it follows the vertical scroll so as to stay at the top of the viewport,
                // above all the content (blocks, piano rolls). The horizontal scroll is still handled
                // internally (the graduations follow the content).
                StickyToViewportTop(anchor: scrollAnchor) {
                    TimeRulerView(
                        totalDuration: totalDuration,
                        pixelsPerSecond: pixelsPerSecond,
                        height: rulerHeight,
                        snapEnabled: viewModel.effectiveSnapEnabled,
                        snapGrid: viewModel.effectiveSnapGrid,
                        gridLevels: viewModel.gridLevels,
                        loopRegion: viewModel.loopRegion,
                        loopModeEnabled: viewModel.loopModeEnabled,
                        onLoopRegionChanged: { viewModel.loopRegion = $0 },
                        tempo: viewModel.tempo,
                        timeSigNumerator: viewModel.timeSigNumerator,
                        timeSigDenominator: viewModel.timeSigDenominator,
                        gridMode: viewModel.gridMode,
                        scrollOffsetX: cullScrollX,
                        viewportWidth: cullViewportWidth
                    )
                }
                .zIndex(4)

                let dragActive = moveDrag != nil || resizeDrag != nil || trimDrag != nil
                if let guide = viewModel.objectSnapGuide, dragActive {
                    Rectangle()
                        .fill(Color.yellow.opacity(0.55))
                        .frame(width: 1, height: canvasHeight - rulerHeight)
                        .offset(x: guide * pixelsPerSecond - 0.5, y: rulerHeight)
                        .allowsHitTesting(false)
                        .zIndex(3)
                }

                // While paused (⇧space), the playhead stays where playback stopped — that is where it
                // will start again — but in a muted red to say 'stopped'.
                if isPlaying || isPaused {
                    Rectangle()
                        .fill(Color.red.opacity(isPlaying ? 0.85 : 0.45))
                        .frame(width: 1.5, height: canvasHeight - rulerHeight)
                        .offset(x: playheadPosition * pixelsPerSecond - 0.75, y: rulerHeight)
                        .allowsHitTesting(false)
                        .zIndex(2.7)   // above the piano rolls (2.55) so as to stay visible
                }

                Rectangle()
                    .fill(Color.gray.opacity(0.5))
                    .frame(width: 1.5, height: canvasHeight - rulerHeight)
                    .offset(x: currentSelectionCursor * pixelsPerSecond - 0.75, y: rulerHeight)
                    .allowsHitTesting(false)
                    .zIndex(3)

                // The caret at the insertion point: the lane clicked (with no selection), or the left edge
                // of the time selection (on each of its lanes).
                if let sel = viewModel.timeSelection {
                    let ct = sel.timeRange.lowerBound
                    ForEach(Array(sel.lanes), id: \.self) { lane in
                        InsertionCaret(height: blockHeight,
                                       overObject: blockCovers(displayLane: lane, at: ct))
                            .offset(x: ct * pixelsPerSecond - InsertionCaret.halfWidth,
                                    y: rulerHeight + Double(lane) * laneStep)
                            .zIndex(3.1)
                    }
                } else if let cl = viewModel.caretLane {
                    InsertionCaret(height: blockHeight,
                                   overObject: blockCovers(displayLane: cl, at: currentSelectionCursor))
                        .offset(x: currentSelectionCursor * pixelsPerSecond - InsertionCaret.halfWidth,
                                y: rulerHeight + Double(cl) * laneStep)
                        .zIndex(3.1)
                }

                // Blocks (the root plus the descendants of expanded groups).
                // itemBlock branches on kind → a clip = SoundBlockView, a group = GroupBlockView
                // (a header plus a chevron, a nested subgroup included).
                // Blocks (the root plus the descendants of expanded groups). Hit-test/hover/gestures
                // are resolved geometrically by the canvas on laneEntries (pure presentation).
                // Virtualisation: we only render the blocks intersecting the viewport.
                //
                // A PERF SPLIT: the visible 'ordinary' clips are drawn in ONE Canvas (1 view node
                // instead of N×layers → the cost of scrolling was the number of SwiftUI nodes, not
                // the drawing). The rich blocks (selection, tools, renaming, a sound object, an aux,
                // MIDI, groups, a drag) keep their SwiftUI view.
                let plainVisible = viewModel.laneEntries.filter {
                    isEntryVisible($0) && isPlainCanvasClip($0.item)
                }
                let _ = ensureWaveformsLoaded(plainVisible)
                plainBlocksCanvas(plainVisible)
                ForEach(viewModel.laneEntries) { entry in
                    if isEntryVisible(entry), !isPlainCanvasClip(entry.item) {
                        itemBlock(for: entry.item, displayLane: entry.displayLane)
                            .allowsHitTesting(false)
                    }
                }

                // Piano rolls unfolded inline under the open MIDI clips. Interactive
                // (allowsHitTesting), unlike the blocks. Positioned on the band of sub-lanes
                // reserved by expandedSpan.
                ForEach(viewModel.laneEntries) { entry in
                    if entry.item.showsPianoRollInline, isEntryVisible(entry) {
                        // It covers the WHOLE band of sub-lanes (the clip-tinted background already fills
                        // 2·laneStep, the gap included): without the -laneGap, a 4px line in the clip's
                        // colour stuck out under the control band.
                        let bandH = Double(SoundObject.pianoRollLaneSpan) * laneStep
                        PianoRollView(
                            viewModel: viewModel,
                            object: entry.item,
                            pixelsPerSecond: pixelsPerSecond,
                            secPerBeat: 60.0 / viewModel.tempo,
                            bandHeight: bandH,
                            onSeekToTime: { t in
                                viewModel.timeSelection = nil
                                if !isPlaying { viewModel.engine?.seek(to: t) }
                                onMoveCursor(t)
                            }
                        )
                        .offset(x: entry.absStart * pixelsPerSecond,
                                y: rulerHeight + Double(entry.displayLane + 1) * laneStep)
                        .zIndex(2.55)
                    }
                }

                // AUTOMATION bands unfolded inline under the open objects. The same overlay mechanism
                // as the piano rolls, positioned on the band of sub-lanes reserved by expandedSpan.
                // Passive at this stage: the canvas simply ignores the clicks that fall in it
                // (@see openAutomationBandContains).
                ForEach(viewModel.laneEntries) { entry in
                    if let r = automationBandRect(for: entry), isEntryVisible(entry) {
                        AutomationBandView(
                            viewModel: viewModel,
                            object: entry.item,
                            pixelsPerSecond: pixelsPerSecond,
                            bandWidth: r.width,
                            laneStep: laneStep,
                            rowHeight: blockHeight
                        )
                        .offset(x: r.minX, y: r.minY)
                        .zIndex(2.56)
                    }
                }

                // The hovered cut line (top level AND children) — rendered at canvas level,
                // like all the rest of the geometry resolved on laneEntries.
                // Conditioned on the tool → it disappears as soon as one leaves the cut (no phantom line).
                // Cutting by dragging: the portion that would disappear if one released now is
                // struck through in red. The gesture's direction decides (pulling right = keep the left).
                if viewModel.activeTool == .toolCut, let cd = cutDrag {
                    ForEach(Array(cutDragDoomedRects.enumerated()), id: \.offset) { _, r in
                        Rectangle()
                            .fill(Color.red.opacity(0.28))
                            .frame(width: r.width, height: r.height)
                            .offset(x: r.minX, y: r.minY)
                            .allowsHitTesting(false)
                            .zIndex(2.62)
                    }
                    Rectangle()
                        .fill(Color.yellow.opacity(0.9))
                        .frame(width: 1.5, height: canvasHeight - rulerHeight)
                        .offset(x: cd.cutTime * pixelsPerSecond - 0.75, y: rulerHeight)
                        .allowsHitTesting(false)
                        .zIndex(2.63)
                }

                if viewModel.activeTool == .toolCut, cutDrag == nil,
                   let hover = cutHover,
                   let entry = viewModel.laneEntries.first(where: { $0.item.id == hover.id }) {
                    let absX = entry.absStart * pixelsPerSecond + hover.localX
                    let by   = rulerHeight + Double(entry.displayLane) * laneStep
                    Rectangle()
                        .fill(Color.yellow.opacity(0.85))
                        .frame(width: 1.5, height: blockHeight)
                        .offset(x: absX - 0.75, y: by)
                        .allowsHitTesting(false)
                        .zIndex(2.6)  // above the selected blocks (1) and the masks (0)
                }

                // The hovered block's editing zones (the selection tool): thin separations plus a
                // discreet veil over the zone that would answer the click. Hidden during a gesture — once
                // the drag is engaged, the gesture's preview already says what is happening.
                if viewModel.activeTool == .toolSelection, let hover = editZoneHover,
                   !dragActive, fadeDrag == nil, timeSelectionDrag == nil {
                    // UNDER the 'objects / automations' hem (2.57): the veil darkens the block's
                    // clickable zone, not the switch laid on it — which has its own material and its
                    // own hover state (@see updateCursor, which puts the veil out as soon as one
                    // comes into the hem).
                    ClipEditZonesOverlay(hover: hover)
                        .zIndex(2.565)
                }

                // The out-of-range masks of OPEN objects (the zones before/after the played range, inside
                // the unfolded band of sub-lanes). A SHARED mechanism driven by `expandedSpan`: an
                // expanded group (the band = the children) AND an open MIDI clip (the band = the piano
                // roll). It greys the outside of the content out so as to focus on the inside. See SoundObject.expandedSpan.
                ForEach(viewModel.laneEntries) { entry in
                    let span = entry.item.expandedSpan
                    // An infinite bus: no range any more → no out-of-range. Its inside is open over
                    // the whole timeline, so no grey mask.
                    if span > 0 && !entry.item.isInfiniteBus {
                        let item   = entry.item
                        let subY   = rulerHeight + Double(entry.displayLane + 1) * laneStep
                        let laneH  = Double(span) * laneStep
                        // A trim/resize under way: the mask's bounds follow the hand, otherwise the veil
                        // stayed at the old bounds and the inside was only revealed on release — the
                        // gesture looked as if it MOVED the group's start.
                        let gs     = item.startTime * pixelsPerSecond + previewTrimDX(for: item)
                        let ge     = (item.startTime + item.duration) * pixelsPerSecond + previewResizeDX(for: item)
                        let totalW = totalDuration * pixelsPerSecond
                        if gs > 0 {
                            Rectangle()
                                .fill(Color.black.opacity(0.28))
                                .frame(width: gs, height: laneH)
                                .offset(x: 0, y: subY)
                                .allowsHitTesting(false)
                        }
                        if ge < totalW {
                            Rectangle()
                                .fill(Color.black.opacity(0.28))
                                .frame(width: totalW - ge, height: laneH)
                                .offset(x: ge, y: subY)
                                .allowsHitTesting(false)
                        }
                    }
                }

                // The 'objects / automations' hem of the objects that have both to show (a group, a MIDI
                // clip): INSIDE the block, risen from the lower edge — its belonging is beyond question,
                // nested too. Pure rendering (like the rest of the canvas's controls); the click is
                // resolved geometrically by the tap handler.
                ForEach(viewModel.laneEntries) { entry in
                    if isEntryVisible(entry), let b = automationBezel(for: entry) {
                        let tint  = entry.item.customColor ?? viewModel.stemColor(for: entry.item.id)
                        let paint = interiorPaint(for: entry)
                        AutomationBezelView(placement: b, fill: paint, tint: tint,
                                            state: AutomationBezel.displayState(for: entry.item))
                            .zIndex(2.57)
                        // No 'weld' across the gutter under the plateau: it had the PLATEAU's width,
                        // not the block's, and so read as an added shape spilling out of the hem
                        // towards the lanes below — the opposite of what it meant. The hem stops at
                        // the block's lower edge; the gutter stays empty, as under any other object.
                    }
                }

                // Alt+drag ghosts
                ForEach(altDragGhosts, id: \.object.id) { ghost in
                    soundBlock(for: ghost.object)
                        .offset(x: ghost.dx, y: ghost.dy)
                        .opacity(0.6)
                        .allowsHitTesting(false)
                        .zIndex(2)

                    ZStack {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 18, height: 18)
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .offset(
                        x: ghost.object.startTime * pixelsPerSecond + ghost.dx + 6,
                        y: rulerHeight + Double(ghost.object.lane) * laneStep + ghost.dy + 6
                    )
                    .allowsHitTesting(false)
                    .zIndex(2.1)
                }

                // TimeSelection overlay
                if let sel = viewModel.timeSelection {
                    let w = (sel.timeRange.upperBound - sel.timeRange.lowerBound) * pixelsPerSecond
                    let x = sel.timeRange.lowerBound * pixelsPerSecond
                    ForEach(Array(sel.lanes), id: \.self) { lane in
                        Rectangle()
                            .fill(Color.cyan.opacity(0.18))
                            .frame(width: w, height: blockHeight)
                            .offset(x: x, y: rulerHeight + Double(lane) * laneStep)
                            .allowsHitTesting(false)
                            .zIndex(1.5)
                    }
                }

                // Plugin LINK overlay: a star from the clip whose editor is open towards the other
                // clips of the group, plus highlighting. Visible ONLY with an editor open.
                if let info = viewModel.linkOverlayInfo {
                    Canvas { ctx, _ in
                        guard let srcTarget = linkTarget(for: info.sourceObjectID) else { return }
                        let members = info.memberObjectIDs
                            .filter { $0 != info.sourceObjectID }
                            .compactMap { linkTarget(for: $0) }
                        LinkOverlay.drawStar(in: ctx, source: srcTarget, members: members,
                                             color: info.color)
                    }
                    .frame(width: totalDuration * pixelsPerSecond, height: canvasHeight, alignment: .topLeading)
                    .allowsHitTesting(false)
                    .zIndex(2.7)
                }

                // Sound object LINK overlay: PURPLE lines between the instances of one definition
                // (those that are visible). Contextual — like the plugin link, we only show it for the
                // selection. The selected placements are grouped by definition:
                //
                //  • one selected → a star from the source → the other instances (as before);
                //  • several selected → ONE single chain joining every instance (instead of a star
                //    from each to all the others, unreadable in a multiple selection).
                if viewModel.hasSelectedLinkedObject {
                    Canvas { ctx, _ in
                        var byDef: [UUID: [UUID]] = [:]
                        for id in viewModel.selectedIDs {
                            guard let obj = viewModel.find(id: id),
                                  let defID = obj.definitionID else { continue }
                            byDef[defID, default: []].append(id)
                        }
                        for (defID, selected) in byDef {
                            if selected.count <= 1 {
                                guard let src = selected.first, let srcTarget = linkTarget(for: src) else { continue }
                                let members = viewModel.placementIDs(forDefinition: defID, excluding: src)
                                    .compactMap { linkTarget(for: $0) }
                                guard !members.isEmpty else { continue }
                                LinkOverlay.drawStar(in: ctx, source: srcTarget, members: members,
                                                     color: LinkColor.soundObject)
                            } else {
                                // Every visible instance of the definition, ordered along the timeline
                                // (left→right, then top→bottom), joined in a chain.
                                let selectedSet = Set(selected)
                                let nodes = viewModel.placementIDs(forDefinition: defID)
                                    .compactMap { id -> (target: LinkTarget, active: Bool)? in
                                        guard let t = linkTarget(for: id) else { return nil }
                                        return (t, selectedSet.contains(id))
                                    }
                                    .sorted { l, r in
                                        l.target.rect.minX != r.target.rect.minX
                                            ? l.target.rect.minX < r.target.rect.minX
                                            : l.target.rect.minY < r.target.rect.minY
                                    }
                                guard nodes.count > 1 else { continue }
                                LinkOverlay.drawChain(in: ctx, nodes: nodes, color: LinkColor.soundObject)
                            }
                        }
                    }
                    .frame(width: totalDuration * pixelsPerSecond, height: canvasHeight, alignment: .topLeading)
                    .allowsHitTesting(false)
                    .zIndex(2.7)
                }

                // SEND overlay: red lines from the clip towards the auxes it feeds.
                // The send in focus (dragging/hovering a knob) is emphasised (a vivid red plus a
                // glow); the same clip's other wired sends stay discreet.
                if viewModel.activeTool == .toolAux {
                    Canvas { ctx, _ in
                        let focus = viewModel.sendToolFocus
                        // Every selected clip keeps its links visible; the clip
                        // hovered (focused) is merely emphasised, it does not erase the others.
                        var clipIDs = Array(viewModel.selectedIDs)
                        if let f = focus, !clipIDs.contains(f.objectID) { clipIDs.append(f.objectID) }
                        for clipID in clipIDs {
                            guard let cr = clipRect(for: clipID) else { continue }
                            let auxes = viewModel.sendToolAuxes(for: clipID)
                            let colW = sendColWidth(blockWidth: cr.width, count: auxes.count)
                            for (idx, aux) in auxes.enumerated() {
                                let isFocus = focus?.objectID == clipID && focus?.auxID == aux.id
                                let routed  = viewModel.isSendRouted(from: clipID, to: aux.id)
                                guard isFocus || routed else { continue }
                                guard let at = linkTarget(for: aux.id) else { continue }
                                let ar = at.rect
                                // The link sets off from the centre of that aux's on/off button (the
                                // bottom of its column), horizontally aligned on the knob.
                                let src = CGPoint(x: cr.minX + (Double(idx) + 0.5) * colW,
                                                  y: cr.maxY - 2 - sendToggleZoneHeight / 2)
                                let dst = CGPoint(x: ar.midX, y: ar.midY)
                                var path = Path()
                                LinkOverlay.appendCurve(&path, from: src, to: dst)
                                if isFocus {
                                    ctx.stroke(path, with: .color(.red.opacity(0.35)), lineWidth: 9)
                                    ctx.stroke(path, with: .color(.red.opacity(0.95)), lineWidth: 2.6)
                                    let halo = Path(roundedRect: ar.insetBy(dx: -5, dy: -5),
                                                    cornerRadius: at.cornerRadius + 5)
                                    ctx.stroke(halo, with: .color(.red.opacity(0.35)), lineWidth: 6)
                                    ctx.stroke(halo, with: .color(.red.opacity(0.9)), lineWidth: 2)
                                } else {
                                    ctx.stroke(path, with: .color(.red.opacity(0.18)), lineWidth: 6)
                                    ctx.stroke(path, with: .color(.red.opacity(0.45)), lineWidth: 1.8)
                                }
                            }
                        }
                    }
                    .frame(width: totalDuration * pixelsPerSecond, height: canvasHeight, alignment: .topLeading)
                    .allowsHitTesting(false)
                    .zIndex(2.7)
                }

                // A preview of the file drop: the blocks about to be born, at their lane and their
                // instant. A separate view (and not a piece of this body) because its position
                // follows the cursor: read here, the hover would have the whole timeline rebuilt on
                // every pixel travelled.
                FileDropGhostOverlay(viewModel: viewModel,
                                     pixelsPerSecond: pixelsPerSecond,
                                     rulerHeight: rulerHeight,
                                     laneStep: laneStep,
                                     blockHeight: blockHeight)
                    .allowsHitTesting(false)
                    .zIndex(2.95)

                // A live 'link' hint during a plugin drag with ⌘ (it follows the cursor).
                if let loc = viewModel.pluginLinkDropLocation {
                    LinkBadge(color: LinkColor.plugin)
                        .position(x: loc.x + 18, y: loc.y - 18)
                        .allowsHitTesting(false)
                        .zIndex(3)
                }
            }
            .frame(width: totalDuration * pixelsPerSecond, height: canvasHeight, alignment: .topLeading)
            .contentShape(Rectangle())
            .helpIf(toolZoneHelpText)
            .onTapGesture(coordinateSpace: .local) { handleCanvasTap(at: $0) }
            .simultaneousGesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .local)
                    .onChanged { handleCanvasDrag($0, phase: .changed) }
                    .onEnded   { handleCanvasDrag($0, phase: .ended)   }
            )
            .overlay(
                HoverTracker { pos in
                    if let p = pos {
                        updateCursor(at: p)
                        hoverState.position = p
                        updateToolHover(at: p)
                    } else {
                        // The pointer leaves the timeline: we release the claim, and it is AppKit
                        // that decides the cursor for whatever is under the pointer
                        // (@see TimelineCursorKeeper). Do not set anything ourselves: the arrow
                        // would override the neighbouring view's cursor — the inspector's resize
                        // handle, the transport's fields…
                        TimelineCursorKeeper.relinquish()
                        hoverState.position = nil
                        toolHoveredID = nil
                        toolZoneHelpText = nil
                        cutHover = nil
                        editZoneHover = nil
                    }
                }
            )
            .onDrop(of: [.plainText, .fileURL],
                    delegate: TimelineDropDelegate(
                        types: [.plainText, .fileURL],
                        onPerform: { providers, loc in
                            let ok = handleDrop(providers: providers, location: loc)
                            // The drop has just created / moved blocks under the pointer:
                            // the hover from before the drag is worth nothing any more (@see refreshHover).
                            DispatchQueue.main.async { refreshHover(at: loc) }
                            return ok
                        },
                        onLinkIndicator: { viewModel.pluginLinkDropLocation = $0 },
                        onFileHint: { beginFileDropPreview(providers: $0, location: $1) },
                        onFileHintEnd: { viewModel.endFileDropHint() },
                        onDropHover: { active in
                            // A drag from the system (the sound library, the Finder, a plugin card)
                            // emits NO mouseMoved: the hover veil would stay frozen on the last block
                            // pointed at while the drop ghost follows the cursor. We put it out for the
                            // length of the session.
                            if active {
                                if editZoneHover != nil { editZoneHover = nil }
                                if cutHover != nil { cutHover = nil }
                            }
                        }))
        }
        .scrollPosition($scrollPosition)
        // The mirror in the view-model (`viewScrollX/Y`, @ObservationIgnored) serves only to save
        // the visible area with the project — it invalidates no view.
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in
            scrollAnchor.x = x
            viewModel.viewScrollX = Double(x)
            refreshCullWindow()     // it only moves once per notch → it almost never invalidates
            relaxStickyDuration()   // back inside the content → the canvas can shrink
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
            scrollAnchor.y = y
            viewModel.viewScrollY = Double(y)
        }
        .background(GeometryReader { geo in
            Color(nsColor: .controlBackgroundColor)
                .onAppear { viewportWidth = geo.size.width; viewportHeight = geo.size.height }
                .onChange(of: geo.size.width)  { viewportWidth  = $0 }
                .onChange(of: geo.size.height) { viewportHeight = $0 }
        })
        .overlay(alignment: .bottomTrailing) { toolIndicator }
        // The cheat sheet and the HUD share the bottom of the view, stacked: the shortcut list reads
        // above the status bands, without hiding the centre of the timeline.
        .overlay(alignment: .bottom) {
            VStack(spacing: 6) {
                cheatsheetOverlay
                fileDropHintOverlay
                moveDragHUD
                heldSoloHUD
                soloHUD
                stemAssignHUD
                selectionInfoHUD
            }
        }
        .onAppear {
            registerKeyMonitor()
            registerScrollMonitor()
            registerMagnifyMonitor()
            registerRightClickMonitor()
            currentSelectionCursor = selectionCursor
            // The waveform cache folder = the project's waveforms/ (nil if unsaved).
            waveformCache.waveformsDirectory = viewModel.waveformsFolder
            // Dragging on the zoom pills: the same session as the wheel, simply held open by the
            // gesture (no inactivity window to respect).
            viewModel.beginHorizontalZoomDrag = {
                openHorizontalZoomSession()
                hZoomHeld = true
            }
            viewModel.endHorizontalZoomDrag = { hZoomHeld = false }
            viewModel.applyHorizontalZoom = { newPPS in applyZoom(newPPS) }
            viewModel.beginVerticalZoomDrag = {
                openVerticalZoomSession()
                vZoomHeld = true
            }
            viewModel.endVerticalZoomDrag = { vZoomHeld = false }
            viewModel.applyVerticalZoom = { newH in applyVerticalZoom(newH) }
        }
        .onDisappear { unregisterKeyMonitor() }
        // ⌥ pressed or released WITHOUT moving the mouse: the drag under way flips in place between
        // moving and copying. The handler does reread ⌥ on every frame, but a frame only arrives at
        // the next pixel — so pressing without moving had no effect. The same remedy as the
        // automation band's for ⌘ (@see AutomationBandView).
        .onChange(of: viewModel.optKeyHeld) { _, held in
            // Outside a drag, ⌥ changes what the next gesture WILL DO: the cursor has to say so at once
            // (the slip's ↔ over a time selection), without waiting for a movement.
            if let pos = hoverState.position, moveDrag == nil { refreshHover(at: pos) }
            // Drags born of a time selection froze their nature (fragments, slip) at the start,
            // according to ⌥⌘: their state is not reread along the way, here no more than elsewhere.
            guard moveDrag?.timeSelectionAnchor == nil else { return }
            moveDrag?.isAltCopy = held
        }
        .onChange(of: selectionCursor) { currentSelectionCursor = $0 }
        // The content's length: followed at once when it grows, shrunk only when
        // that moves nothing on screen (see syncStickyDuration).
        .onChange(of: contentDuration, initial: true) { syncStickyDuration() }
        .onChange(of: viewModel.pixelsPerSecond) { relaxStickyDuration() }
        // A loaded project: the zoom is already applied (by the view-model), and the scroll is what
        // is left. Deferred by one runloop turn so that the content has its final size (otherwise
        // the scroll is clamped on a width that is still empty).
        .onChange(of: viewModel.pendingViewRestore) { _, vp in
            guard let vp else { return }
            DispatchQueue.main.async {
                scrollPosition.scrollTo(x: CGFloat(vp.scrollX), y: CGFloat(vp.scrollY))
                viewModel.pendingViewRestore = nil
            }
        }
        // The area to REVEAL (the export panel: setting the I/O markers): we frame the timeline on
        // it — zooming so that it fits whole, scrolling to bring it to the left. The same protocol
        // as `pendingViewRestore`: applied then set back to nil, and deferred by one runloop turn so
        // that the canvas already has its width at the requested scale.
        .onChange(of: viewModel.pendingRangeReveal) { _, range in
            guard let range else { return }
            revealTimeRange(range)
            DispatchQueue.main.async { viewModel.pendingRangeReveal = nil }
        }
        // The project folder changes (Save As, opening, a new version) → retarget the
        // disk cache; becoming non-nil flushes the peaks already computed.
        .onChange(of: viewModel.projectURL) {
            waveformCache.waveformsDirectory = viewModel.waveformsFolder
        }
        // A new project / an opening: the displayed length starts again from the real content,
        // without waiting for `relaxStickyDuration`'s conditions — they protect an editing GESTURE
        // under way, a notion that means nothing when all the content has just been replaced. The
        // scroll is reclamped straight after, otherwise the ScrollView stays beyond the new canvas
        // and shows emptiness outside the content (which the slightest zoom made disappear).
        .onChange(of: viewModel.projectLoadToken) { resetStickyDuration() }
    }

    // MARK: - Cursor

    /// Recomputes EVERYTHING that depends on the hovered point — the cursor, the zone veil, the tool line.
    ///
    /// The hover is remembered as a RECTANGLE, frozen at the instant the mouse passed. While
    /// nothing moves, it is exact; as soon as a gesture or a drop moves, trims or creates a block,
    /// that rectangle names a place where there is nothing any more — and the veil, hidden during
    /// the gesture, reappeared on release in empty space. No `mouseMoved` will necessarily come to
    /// correct it (the mouse may very well not move again), hence this explicit reminder at the
    /// end of a gesture and after a drop.
    func refreshHover(at pos: CGPoint) {
        updateCursor(at: pos)
        hoverState.position = pos
        updateToolHover(at: pos)
    }

    private func updateCursor(at pos: CGPoint) {
        // Over an open piano roll or an automation band: those views drive the cursor (a note, a
        // point, a segment, a curvature) from their own `onContinuousHover`, and go through the same
        // `TimelineCursorKeeper` as we do. We let them speak, deciding nothing here — least of all
        // `relinquish`, which would release the claim on every mouse movement only to lay it again
        // just after (@see CursorClaim).
        if openPianoRollBandContains(pos) || openAutomationBandContains(pos) { return }
        // The hem is a button: a pointing hand, and no editing zone lights up underneath
        // (the bottom of the block is otherwise `.move`).
        if viewModel.activeTool == .toolSelection, automationBezelHit(at: pos) != nil {
            TimelineCursorKeeper.set(NSCursor.pointingHand)
            if editZoneHover != nil { editZoneHover = nil }
            if cutHover != nil { cutHover = nil }
            return
        }
        // Hovering the ruler: nothing to edit underneath, even when it covers lanes (a sticky
        // header). We put the veils / tool lines out instead of naming a hidden block the click
        // would not touch.
        if rulerBandContains(pos) {
            // The ruler has its OWN cursor zones — the transport loop's markers
            // (@see TimeRulerView.resetCursorRects). We hand back to it, and set NOTHING: setting the
            // arrow here would take it away from the hovered marker on every mouse movement.
            TimelineCursorKeeper.relinquish()
            if editZoneHover != nil { editZoneHover = nil }
            if cutHover != nil { cutHover = nil }
            return
        }
        // The editing zones are only revealed under the selection tool.
        if viewModel.activeTool != .toolSelection, editZoneHover != nil { editZoneHover = nil }
        switch viewModel.activeTool {
        case .toolCut:
            guard let entry = viewModel.laneEntries.first(where: { e in
                let bx = e.absStart * pixelsPerSecond
                let bw = max(e.item.duration * pixelsPerSecond, 2)
                let by = rulerHeight + Double(e.displayLane) * laneStep
                return pos.x >= bx && pos.x <= bx + bw && pos.y >= by && pos.y <= by + blockHeight
            }) else { TimelineCursorKeeper.set(NSCursor.arrow); cutHover = nil; return }
            // Uniform handling top-level / children (depth immaterial).
            let bx     = entry.absStart * pixelsPerSecond
            let bw     = max(entry.item.duration * pixelsPerSecond, 2)
            let localX = pos.x - bx
            let canCut = localX >= 10 && localX <= bw - 10
            TimelineCursorKeeper.set(canCut ? NSCursor.crosshair : NSCursor.operationNotAllowed)
            // A line set on the snap (the same computation as handleCutTap)
            let snappedX = viewModel.snappedTimePure(max(0, pos.x / pixelsPerSecond)) * pixelsPerSecond - bx
            cutHover = canCut ? (id: entry.item.id, localX: snappedX) : nil
        case .toolVolume:
            TimelineCursorKeeper.set(NSCursor.resizeUpDown)
        case .toolPan:
            TimelineCursorKeeper.set(NSCursor.resizeUpDown)   // pan is set vertically (see handlePanDrag)
        case .toolAux:
            if let hit = sendRowHit(at: pos), (pos.y - hit.by) >= blockHeight - sendToggleZoneHeight - 4 {
                TimelineCursorKeeper.set(NSCursor.pointingHand)
            } else if sendRowHit(at: pos) != nil {
                TimelineCursorKeeper.set(NSCursor.resizeUpDown)
            } else {
                TimelineCursorKeeper.set(NSCursor.arrow)
            }
        case .toolSelection:
            let zoneHover = selectionZoneHover(at: pos)
            // ⌥ on an object's upper band (or on a time selection): the drag will not move, it will
            // SLIP THE CONTENT inside the window. Nothing said so on screen — the gesture changed
            // nature without warning. The ↔ says it, and it reads by the SAME rule as the gesture
            // (@see slipGrab): where it does not appear, ⌥ will do something else.
            //
            let slipping = NSEvent.modifierFlags.contains(.option)
                && !slipGrab(at: pos, zone: zoneHover?.hover.zone, item: zoneHover?.item).isEmpty

            guard let (hover, item) = zoneHover else {
                TimelineCursorKeeper.set(slipping ? NSCursor.resizeLeftRight : NSCursor.arrow)
                if editZoneHover != nil { editZoneHover = nil }
                return
            }
            if editZoneHover != hover { editZoneHover = hover }
            if slipping { TimelineCursorKeeper.set(NSCursor.resizeLeftRight); return }

            switch hover.zone {
            case .fadeIn:  TimelineCursorKeeper.set(TimelineCursors.fadeIn)
            case .fadeOut: TimelineCursorKeeper.set(TimelineCursors.fadeOut)
            case .trimLeft:
                // Small arrows under the bracket: to the left while there is source content left
                // (and timeline), to the right while the clip can be trimmed.
                TimelineCursorKeeper.set(TimelineCursors.edge(
                    open: true,
                    canLeft: headroomBefore(item) > edgeEpsilon,
                    canRight: item.duration > 0.01 + edgeEpsilon))
            case .resizeRight:
                if item.loopEnabled {
                    TimelineCursorKeeper.set(TimelineCursors.loopEdge(open: false))
                } else {
                    TimelineCursorKeeper.set(TimelineCursors.edge(
                        open: false,
                        canLeft: item.duration > 0.01 + edgeEpsilon,
                        canRight: headroomAfter(item) > edgeEpsilon))
                }
            case .timeSelect: TimelineCursorKeeper.set(NSCursor.iBeam)
            case .move:
                // ⌥ on an object's BODY: the drag will not move the original, it will make a COPY of
                // it — of the object, or of the TIME SELECTION when the click falls inside it
                // (@see handleCanvasDrag, the `.move` case). The '+' says so before engaging the hand,
                // as the ↔ says it for the slip on the upper band — the lower half and the upper half
                // each announce what ⌥ will do there.
                TimelineCursorKeeper.set(NSEvent.modifierFlags.contains(.option)
                                         ? NSCursor.dragCopy : NSCursor.openHand)
            case .loopIn, .loopOut: TimelineCursorKeeper.set(NSCursor.resizeLeftRight)
            }
        case .toolStemAssign:
            // A 'pointer' cursor on a paintable object, an arrow elsewhere.
            let overItem = viewModel.laneEntries.contains { e in
                let bx = e.absStart * pixelsPerSecond
                let bw = max(e.item.duration * pixelsPerSecond, 2)
                let by = rulerHeight + Double(e.displayLane) * laneStep
                return pos.x >= bx && pos.x <= bx + bw && pos.y >= by && pos.y <= by + blockHeight
            }
            TimelineCursorKeeper.set(overItem ? NSCursor.pointingHand : NSCursor.arrow)
        }
    }

    // MARK: - Editing zones (the selection tool)

    /// The 'the edge cannot move any more' tolerance: half a pixel at the current scale, with a
    /// floor in seconds so as to stay stable at extreme zooms.
    private var edgeEpsilon: Double { max(0.001, 0.5 / max(pixelsPerSecond, 1)) }

    /// The content margin available BEFORE the clip's start, in timeline seconds. It bounds the
    /// left trim, exactly like `handleCanvasDrag` (the minimum of timeline 0 and the source content
    /// left, which swaps in reverse — @see SoundObject.contentRoomBefore). An object with no file
    /// (a group, an aux, a MIDI clip) has no stop other than timeline 0.
    private func headroomBefore(_ item: SoundObject) -> Double {
        min(item.startTime, item.contentRoomBefore)
    }

    /// The content margin available AFTER the clip's end (the same convention as `headroomBefore`).
    private func headroomAfter(_ item: SoundObject) -> Double {
        item.contentRoomAfter
    }

    /// True if a block covers the caret's WHOLE LINE on that display lane — hence the half
    /// thickness taken off each side: laid exactly on a block's start (or end), the caret
    /// straddles, and it had better keep the background's ink (@see InsertionCaret).
    func blockCovers(displayLane lane: Int, at t: Double) -> Bool {
        let margin = InsertionCaret.halfWidth / max(pixelsPerSecond, 1)
        return viewModel.laneEntries.contains { e in
            e.displayLane == lane
                && t >= e.absStart + margin
                && t <= e.absStart + e.item.duration - margin
        }
    }

    /// The width of a block's side handles: 25 % of its width, capped at 50 px and removed below
    /// 60 px wide. Shared by the hover, the gesture and the double click.
    func handleWidth(blockWidth bw: Double) -> Double { bw < 60 ? 0 : min(50.0, bw * 0.25) }

    /// The block under the cursor and the editing zone aimed at. The same carve-up as
    /// `handleCanvasDrag` (side handles, the upper half = fade / range selection, the lower half =
    /// trim / move, a set fade's triangle taking priority) — see `ClipEditZone.resolve`.
    func selectionZoneHover(at pos: CGPoint) -> (hover: EditZoneHover, item: SoundObject)? {
        guard let entry = viewModel.laneEntries.first(where: { e in
            let bx = e.absStart * pixelsPerSecond
            let bw = max(e.item.duration * pixelsPerSecond, 2)
            let by = rulerHeight + Double(e.displayLane) * laneStep
            return pos.x >= bx && pos.x <= bx + bw && pos.y >= by && pos.y <= by + blockHeight
        }) else { return nil }

        let bx      = entry.absStart * pixelsPerSecond
        let bw      = max(entry.item.duration * pixelsPerSecond, 2)
        let by      = rulerHeight + Double(entry.displayLane) * laneStep
        let localX  = pos.x - bx
        let localY  = pos.y - by
        let handleW = handleWidth(blockWidth: bw)
        let fiPx    = min(entry.item.fadeIn  * pixelsPerSecond, bw)
        let foPx    = min(entry.item.fadeOut * pixelsPerSecond, bw)
        // The loop's IN/OUT markers: nil (hence ignored by `resolve`) if the object does not loop,
        // or if the marker falls outside the current block (V1 scope, @see [[loop-item-plan]]).
        let loopLocal = entry.item.loopMarkerLocalRange
        let loopInPx  = loopLocal.flatMap { r -> Double? in
            let px = r.start * pixelsPerSecond
            return (0...bw).contains(px) ? px : nil
        }
        let loopOutPx = loopLocal.flatMap { r -> Double? in
            let px = r.end * pixelsPerSecond
            return (0...bw).contains(px) ? px : nil
        }

        let zone = ClipEditZone.resolve(localX: localX, localY: localY,
                                        blockWidth: bw, blockHeight: blockHeight,
                                        handleW: handleW, fadeInPx: fiPx, fadeOutPx: foPx,
                                        loopInPx: loopInPx, loopOutPx: loopOutPx)
        // A radius aligned on the block's (see SoundObject.blockCornerRadius).
        let radius = entry.item.blockCornerRadius
        let markerX = zone == .loopIn ? (loopInPx ?? 0) : (zone == .loopOut ? (loopOutPx ?? 0) : 0)
        let hover = EditZoneHover(id: entry.item.id,
                                  rect: CGRect(x: bx, y: by, width: bw, height: blockHeight),
                                  handleW: handleW, zone: zone, cornerRadius: radius,
                                  fadeInW: fiPx, fadeOutW: foPx, loopMarkerX: markerX)
        return (hover, entry.item)
    }

    // MARK: - Tool hover (Volume / Pan)

    private func updateToolHover(at pos: CGPoint) {
        let help = toolZoneHelp(at: pos)
        if toolZoneHelpText != help { toolZoneHelpText = help }
        // See updateCursor: under the ruler, no object is aimed at.
        if rulerBandContains(pos) {
            if toolHoveredID != nil { toolHoveredID = nil }
            if viewModel.sendToolFocus != nil, viewModel.activeTool == .toolAux, sendDrag == nil {
                viewModel.sendToolFocus = nil
            }
            return
        }
        if viewModel.activeTool == .toolAux {
            if sendDrag != nil { return }   // a drag is active: do not override the focus
            let hit = sendRowHit(at: pos)
            let focus = hit.map { SendFocus(objectID: $0.clipID, auxID: $0.auxID) }
            if viewModel.sendToolFocus != focus { viewModel.sendToolFocus = focus }
            return
        }
        guard viewModel.activeTool == .toolVolume || viewModel.activeTool == .toolPan
                || viewModel.activeTool == .toolStemAssign else {
            if toolHoveredID != nil { toolHoveredID = nil }
            return
        }
        let entry = viewModel.laneEntries.first { e in
            let bx = e.absStart * pixelsPerSecond
            let bw = max(e.item.duration * pixelsPerSecond, 2)
            let by = rulerHeight + Double(e.displayLane) * laneStep
            return pos.x >= bx && pos.x <= bx + bw && pos.y >= by && pos.y <= by + blockHeight
        }
        let newID = entry?.item.id
        if toolHoveredID != newID { toolHoveredID = newID }
    }

    // MARK: - Unified blocks

    @ViewBuilder
    private func itemBlock(for item: SoundObject, displayLane dl: Int) -> some View {
        if item.isInfiniteBus {
            // An infinite bus (an aux/group): no start/end any more → it takes up its WHOLE lane (it
            // processes the entire project). It is selected/handled like an ordinary clip.
            infiniteBusBand(for: item, displayLane: dl)
        } else {
            switch item.kind {
            case .clip, .aux, .midiClip:
                // The aux is rendered as a clip block (with no waveform) for now;
                // a dedicated look in 5b. The MIDI clip reuses the clip block (the note view = step C).
                soundBlock(for: item, overrideDisplayLane: dl)
            case .group:
                groupBlock(for: item, displayLane: dl)
            }
        }
    }

    /// An infinite bus's block: a band set on the VISIBLE WINDOW (so its rounded corners always
    /// stay on screen), in the visual language of its type — an aux keeps its mesh.
    /// Selection and handling go through the canvas (hit-testing via `clipRect`), like a clip.
    private func infiniteBusBand(for item: SoundObject, displayLane dl: Int) -> some View {
        InfiniteBusBandView(
            item: item,
            color: item.customColor ?? viewModel.stemColor(for: item.id),
            isSelected: viewModel.isSelected(item.id),
            isMuted: viewModel.isMutedInMix(item),
            blockHeight: blockHeight,
            yPos: rulerHeight + Double(dl) * laneStep,
            scrollAnchor: scrollAnchor,
            viewportWidth: viewportWidth,
            waveformCache: waveformCache,
            pixelsPerSecond: pixelsPerSecond,
            waveformDisplayDB: viewModel.waveformDisplayDB,
            isRenaming: viewModel.renamingID == item.id,
            onRename: { label in
                if let label { viewModel.renameObject(id: item.id, label: label) }
                viewModel.renamingID = nil
            }
        )
    }

    /// A block is only rendered if it intersects the visible window (plus a margin).
    /// Hit-testing does not depend on that: it goes through the canvas on laneEntries.
    private func isEntryVisible(_ entry: LaneEntry) -> Bool {
        let pps = pixelsPerSecond
        guard pps > 0 else { return true }
        let marginPx = 80.0
        // An infinite bus: it covers its whole lane (0 → the content's width) → always visible.
        if entry.item.isInfiniteBus { return true }
        let leftTime  = (Double(cullScrollX) - marginPx) / pps
        let rightTime = (Double(cullScrollX) + Double(cullViewportWidth) + marginPx) / pps
        let start = entry.absStart
        let end   = entry.absStart + entry.item.duration
        return end >= leftTime && start <= rightTime
    }

    /// A block's box plus its radius, for the link paths. The radius comes from the model
    /// (`SoundObject.blockCornerRadius`): the halo then hugs the block instead of cutting its
    /// corners — visible above all on a GROUP, which is very rounded.
    private func linkTarget(for id: UUID) -> LinkTarget? {
        guard let entry = viewModel.laneEntries.first(where: { $0.item.id == id }),
              let rect = clipRect(for: id)
        else { return nil }
        return LinkTarget(rect, cornerRadius: entry.item.blockCornerRadius)
    }

    // A clip's/group's rect in canvas coordinates (top level AND a child of a group),
    // resolved on laneEntries like the rest of the geometry. nil if it is not shown.
    //
    // THE GESTURE PREVIEW is part of it (the same deltas as `SoundBlockView`, @see its `xPos`):
    // without it, everything set on that rect — the link halos first and foremost — stayed at the
    // MODEL's position while the block was being moved, so hanging in empty space until release.
    //
    private func clipRect(for id: UUID) -> CGRect? {
        guard let e = viewModel.laneEntries.first(where: { $0.item.id == id }) else { return nil }
        let dy = previewOffset(for: e.item)?.dy ?? 0
        let y = rulerHeight + Double(e.displayLane) * laneStep + dy
        // An infinite bus: its clickable 'surface' is its whole lane (0 → the content's width).
        if e.item.isInfiniteBus {
            return CGRect(x: 0, y: y, width: contentWidth, height: blockHeight)
        }
        let dx    = previewOffset(for: e.item)?.dx ?? 0
        let trim  = previewTrimDX(for: e.item)
        let grow  = previewResizeDX(for: e.item)
        return CGRect(x: e.absStart * pixelsPerSecond + trim + dx, y: y,
                      width: max(1, e.item.duration * pixelsPerSecond + grow - trim),
                      height: blockHeight)
    }

    // MARK: - Automation bands

    /// The rectangle of an object's unfolded automation band, in CONTENT coordinates.
    /// nil if its band is not open. An infinite bus has neither a start nor an end: its band
    /// covers the whole timeline, like its block.
    func automationBandRect(for e: LaneEntry) -> CGRect? {
        guard e.item.automationOpen else { return nil }
        let y = rulerHeight + Double(e.displayLane + 1) * laneStep
        let h = Double(e.item.automationSpan) * laneStep - laneGap
        if e.item.isInfiniteBus {
            return CGRect(x: 0, y: y, width: contentWidth, height: h)
        }
        return CGRect(x: e.absStart * pixelsPerSecond, y: y,
                      width: max(1, e.item.duration * pixelsPerSecond), height: h)
    }

    /// The BENDABLE curve segment under a point of the timeline (in CONTENT coordinates), with
    /// everything needed to set it: the object, the row, and the storage index of the point
    /// carrying the curvature. It serves the wheel (@see registerScrollMonitor), which only has
    /// the hover position — the drag, for its part, goes through the band's local coordinates.
    ///
    /// nil outside a band, on a row with no point, on a plateau (before the first point, after
    /// the last: they have no curvature) and on a FLAT segment (where the engine returns a
    /// straight line whatever `c` says). In all those cases the wheel has to keep its normal
    /// meaning — scrolling the timeline — rather than being swallowed for nothing.
    func automationCurveHit(at point: CGPoint) -> (objectID: UUID, param: ParamRef, pointIndex: Int)? {
        for e in viewModel.laneEntries {
            guard let r = automationBandRect(for: e), r.contains(point) else { continue }
            let g = AutomationBandGeometry(rows: e.item.automationRows,
                                           pixelsPerSecond: pixelsPerSecond,
                                           laneStep: laneStep, rowHeight: blockHeight,
                                           bandWidth: r.width)
            let local = CGPoint(x: point.x - r.minX, y: point.y - r.minY)
            guard let row = g.rowIndex(atY: local.y) else { return nil }
            let ref = g.rows[row]
            let pts = e.item.automation.first(where: { $0.param == ref })?.points ?? []
            guard let seg = g.segment(atX: local.x, points: pts),
                  let owner = seg.curveOwner, let right = seg.right,
                  pts.indices.contains(owner), pts.indices.contains(right),
                  pts[owner].v != pts[right].v else { return nil }
            return (e.item.id, ref, owner)
        }
        return nil
    }

    /// True if the point falls inside an open automation band. Those areas belong to
    /// `AutomationBandView`; the canvas (tap / drag / hover) has to ignore them so as not to lay a
    /// caret or start a time selection there — the same contract as the piano rolls.
    func openAutomationBandContains(_ point: CGPoint) -> Bool {
        for e in viewModel.laneEntries {
            if let r = automationBandRect(for: e), r.contains(point) { return true }
        }
        return false
    }

    /// The placement of an object's hem, in CONTENT coordinates. nil if the object has no
    /// selector, if it is FOLDED, or if it is too narrow to carry one. The single entry point
    /// for the hem's geometry: rendering, the click's hit-testing, the drag's guard and the
    /// cursor all resolve there — two separate values would drift, and the button would end up
    /// not answering where it is drawn (@see AutomationSelectorBezel.swift).
    ///
    /// The hem exists ONLY on an open object (`expandedSpan > 0`, that is, unfolded content or an
    /// automation band): folded, an object has nothing to hem and the unlit hem merely cluttered
    /// its block. Reopening is still covered by the existing double clicks — the block's LOWER
    /// half to unfold a group / a piano roll, ⌥double click for the automation band
    /// (@see TimelineView+TapHandler) — and the chevron in a group's header goes on showing its
    /// state.
    ///
    /// Computed on the block's VISIBLE part (@see visibleSpan): a group wider than the viewport
    /// keeps its hem at hand, like its tool controls. It also follows the preview of a gesture
    /// under way (move / resize / trim) exactly as `SoundBlockView`/`GroupBlockView` position the
    /// block itself — without which the hem would come away from its block during the gesture.
    ///
    func automationBezel(for e: LaneEntry) -> AutomationBezel.Placement? {
        guard viewModel.hasAutomationSelector(e.item), e.item.expandedSpan > 0 else { return nil }
        let item = e.item
        let offset = previewOffset(for: item)
        let bx: Double
        let bw: Double
        if item.isInfiniteBus {
            bx = 0
            bw = contentWidth
        } else {
            bx = e.absStart * pixelsPerSecond + previewTrimDX(for: item) + (offset?.dx ?? 0)
            bw = max(item.duration * pixelsPerSecond + previewResizeDX(for: item) - previewTrimDX(for: item), 2)
        }
        let span = visibleSpan(blockX: bx, blockWidth: bw,
                               scrollOffsetX: scrollOffsetX, viewportWidth: viewportWidth)
        guard let m = AutomationBezel.metrics(width: span.width, blockHeight: blockHeight,
                                              handleW: handleWidth(blockWidth: span.width),
                                              corner: item.blockCornerRadius)
        else { return nil }
        let by = rulerHeight + Double(e.displayLane) * laneStep + (offset?.dy ?? 0)
        return AutomationBezel.Placement(
            plateau: CGRect(x: span.x + m.minX, y: by + blockHeight - m.height,
                            width: m.plateau, height: m.height),
            span:    CGRect(x: span.x, y: by, width: span.width, height: blockHeight),
            block:   CGRect(x: bx, y: by, width: bw, height: blockHeight),
            corner:  item.blockCornerRadius,
            metrics: m)
    }

    /// The object plus the zone a point aims at inside a hem. nil elsewhere.
    func automationBezelHit(at p: CGPoint) -> (id: UUID, hit: AutomationBezel.Hit)? {
        for e in viewModel.laneEntries {
            guard let b = automationBezel(for: e),
                  let h = AutomationBezel.hit(p, plateau: b.plateau, b.metrics) else { continue }
            return (e.item.id, h)
        }
        return nil
    }

    /// The REAL paint of an open object's inside, at the row that opens just under it: the layers
    /// in drawing order, the OPAQUE base at the head. That is what the hem fills itself with — it
    /// has to be a piece of what opens underneath, not an approximate colour (and certainly not
    /// white, which corresponds to nothing on a dark background).
    ///
    /// The `fill`s are taken AS THEY ARE from the canvas's lane-background sites — alternating
    /// bands, the inner band of an expanded group (`showsChildrenInline`), a piano roll's
    /// sub-lanes, the row background of an automation band (@see AutomationBandView.draw). The
    /// stacking of the ANCESTORS' bands reproduces by itself the tint that grows stronger as one
    /// goes down the nested groups: it is the same stacking, not a formula imitating it.
    ///
    /// The base is `controlBackgroundColor` — the background of the EDITING AREA, the one the
    /// canvas lays under all its lanes (@see the ScrollView's `.background`). It is NOT
    /// `windowBackgroundColor`, which is the ruler's background: the two look alike, but taking
    /// the ruler's put the hem out of step with the material opening underneath. That base is
    /// indispensable: the hem is laid OVER the block, which is opaque, while the inner layers are
    /// all translucent.
    func interiorPaint(for e: LaneEntry) -> [Color] {
        let lane = e.displayLane + 1                 // the row that opens just under the object
        var layers: [Color] = [Color(nsColor: .controlBackgroundColor)]
        if lane % 2 == 0 { layers.append(Color.black.opacity(0.02)) }
        let focused = focusedDisplayLanes
        for other in viewModel.laneEntries where other.item.showsChildrenInline {
            let span = other.item.childLaneCount
            guard span > 0 else { continue }
            let band = (other.displayLane + 1)...(other.displayLane + span)
            guard band.contains(lane) else { continue }
            let color = other.item.customColor ?? viewModel.stemColor(for: other.item.id)
            layers.append(color.opacity(focused.isDisjoint(with: band) ? 0.11 : 0.22))
        }
        if e.item.showsPianoRollInline {
            layers.append(viewModel.stemColor(for: e.item.id).opacity(0.06))
        }
        if e.item.automationOpen {
            // The background of the band's FIRST row: the 'future automation' row is more muted
            // than the others, and it comes first when nothing is automated yet
            // (@see SoundObject.automationRows, which puts the real curves first).
            let tint = e.item.customColor ?? viewModel.stemColor(for: e.item.id)
            let isFuture = e.item.automation.allSatisfy { $0.points.isEmpty }
            layers.append(tint.opacity(isFuture ? 0.05 : 0.10))
        }
        return layers
    }

    /// True if the point falls inside the band of an open MIDI piano roll. Those areas are owned
    /// by PianoRollView (interactive); the canvas (tap/drag) has to ignore them so as not to lay
    /// a caret or start a time selection there.
    func openPianoRollBandContains(_ point: CGPoint) -> Bool {
        for e in viewModel.laneEntries where e.item.showsPianoRollInline {
            let x = e.absStart * pixelsPerSecond
            let w = max(1, e.item.duration * pixelsPerSecond)
            let y = rulerHeight + Double(e.displayLane + 1) * laneStep
            let h = Double(SoundObject.pianoRollLaneSpan) * laneStep - laneGap
            if point.x >= x && point.x <= x + w && point.y >= y && point.y <= y + h { return true }
        }
        return false
    }

    /// True if the point (in CONTENT coordinates) falls inside the time ruler's band.
    /// The ruler is a sticky header (`.offset(y: scrollOffsetY)`): in content coordinates it
    /// occupies `[scrollOffsetY, scrollOffsetY + rulerHeight]`, and not `[0, rulerHeight]` —
    /// without which, once the view is scrolled, a click on the ruler would fall through onto the
    /// lanes it covers.
    func rulerBandContains(_ point: CGPoint) -> Bool {
        point.y >= scrollOffsetY && point.y <= scrollOffsetY + CGFloat(rulerHeight)
    }

    /// A click / drag in the ruler: ONLY the cursor moves. No object selection, no time range, no
    /// tool — the ruler never touches the content. It is the third gesture, alongside the click on
    /// an object (cursor plus selection) and the click in empty space (cursor plus deselection).
    ///
    func moveCursorFromRuler(atX x: Double) {
        let t = viewModel.snapTime(max(0, x / pixelsPerSecond))
        // No lane aimed at above: no black caret, and the line stays grey over its whole height.
        viewModel.caretLane = nil
        if !isPlaying { viewModel.engine?.seek(to: t) }
        onMoveCursor(t)
    }

    // The clip/group under a canvas point (for a plugin drop). Resolved on laneEntries.
    func objectID(at point: CGPoint) -> UUID? {
        for e in viewModel.laneEntries {
            if let r = clipRect(for: e.item.id), r.contains(point) {
                return e.item.id
            }
        }
        return nil
    }

    @ViewBuilder
    private func soundBlock(for object: SoundObject, overrideDisplayLane: Int? = nil) -> some View {
        let dLane = overrideDisplayLane ?? displayLane(for: object.lane)
        SoundBlockView(
            object: object,
            pixelsPerSecond: pixelsPerSecond,
            secPerBeat: 60.0 / viewModel.tempo,
            rulerHeight: rulerHeight,
            blockHeight: blockHeight,
            laneGap: laneGap,
            isSelected: viewModel.isSelected(object.id),
            activeTool: viewModel.activeTool,
            waveformCache: waveformCache,
            scrollOffsetX: cullScrollX,
            viewportWidth: cullViewportWidth,
            waveformDisplayDB: waveformDisplayDB,
            displayLane: dLane,
            stemColor: viewModel.stemColor(for: object.id),
            isMutedInMix:     viewModel.isMutedInMix(object),
            previewOffset:    previewOffset(for: object),
            previewResizeDX:  previewResizeDX(for: object),
            previewTrimDX:    previewTrimDX(for: object),
            previewFadeIn:    previewFadeIn(for: object),
            previewFadeOut:   previewFadeOut(for: object),
            previewLoopRange: previewLoopRange(for: object),
            isToolHovered:    toolHoveredID == object.id,
            stemAssignTarget: stemAssignTarget,
            sendRows:         (viewModel.activeTool == .toolAux && !object.isAux)
                                ? viewModel.sendRows(for: object.id) : [],
            isRenaming:       viewModel.renamingID == object.id,
            isBaking:         viewModel.isBaking(object.id),
            isStale:          object.isObjectInstance && viewModel.isStale(object.id),
            isPreviewing:     viewModel.hasLiveMirrors && viewModel.editingPlacementID == object.id,
            isRecomputing:    object.definitionID.map { viewModel.recomputingDefinitionIDs.contains($0) } ?? false,
            isResynced:       object.definitionID.map { viewModel.recentlyResyncedDefinitionIDs.contains($0) } ?? false,
            isEditing:        viewModel.editingPlacementID == object.id,
            onRename: { label in
                if let label { viewModel.renameObject(id: object.id, label: label) }
                viewModel.renamingID = nil
            }
        )
        // `.task(id:)` (and not `.onAppear`): the placement can change its `filePath` WITHOUT the
        // view being rebuilt (a clip→sound object transformation, a definition's re-bake) — `onAppear`
        // would not fire again and the waveform would stay frozen on the old wave. `load` is
        // idempotent (a no-op if it is already cached / in flight).
        .task(id: object.filePath) { waveformCache.load(filePath: object.filePath) }
        .opacity(blockOpacity(for: object))
    }

    /// A block's opacity: it combines the text filter's dimming and the solo's (an object that is
    /// not audible shown 'almost transparent').
    private func blockOpacity(for object: SoundObject) -> Double {
        let filterDim = !viewModel.filterText.isEmpty
            && !object.displayName.localizedCaseInsensitiveContains(viewModel.filterText)
        let soloDim = viewModel.isSoloDimmed(object.id)
        return (filterDim || soloDim) ? 0.25 : 1.0
    }

    // MARK: - 'Simple' blocks in ONE Canvas (perf)
    //
    // The cost of scrolling was the number of SwiftUI view NODES (≈260 blocks × ~6 layers
    // = layout/rendering/compositing at 6 fps), NOT the drawing (one waveform Canvas = 5 µs).
    // So we draw every visible 'ordinary' clip in a single Canvas (1 node), and keep a real
    // SwiftUI `SoundBlockView` only for the blocks that need rich interaction/overlays (few at
    // a time).

    /// True = this clip can be drawn in the shared Canvas (no SwiftUI need).
    private func isPlainCanvasClip(_ item: SoundObject) -> Bool {
        guard case .clip = item.kind else { return false }   // an aux / midi / group → a rich view
        if viewModel.isSelected(item.id) { return false }
        if viewModel.renamingID == item.id { return false }
        if viewModel.isBaking(item.id) { return false }
        if item.isObjectInstance { return false }   // a link/freshness badge → a rich view
        if item.colorIndex != nil { return false }   // a 10%/90% band → a rich view
        switch viewModel.activeTool {
        case .toolVolume, .toolPan, .toolAux: return false   // interactive overlays
        default: break
        }
        // A drag/preview under way on this clip → a live SwiftUI view.
        if previewOffset(for: item) != nil { return false }
        if previewResizeDX(for: item) != 0 { return false }
        if previewTrimDX(for: item) != 0 { return false }
        if previewFadeIn(for: item) != nil || previewFadeOut(for: item) != nil { return false }
        return true
    }

    /// It triggers the loading of the waveforms of the Canvas blocks (which no longer have a
    /// SoundBlockView's `.onAppear`). `load` is idempotent; we defer it outside the render so
    /// as not to mutate state while the body is being evaluated.
    private func ensureWaveformsLoaded(_ entries: [LaneEntry]) {
        guard !entries.isEmpty else { return }
        let paths = entries.map { $0.item.filePath }
        DispatchQueue.main.async {
            for p in paths { waveformCache.load(filePath: p) }
        }
    }

    private func plainBlocksCanvas(_ entries: [LaneEntry]) -> some View {
        Canvas { ctx, _ in
                let filterText = viewModel.filterText
                let dimActive = !filterText.isEmpty
                let soloDimActive = viewModel.hasAnySolo
                // A precomputed set (like `mutedStemIDs`): the nested `isDim` function is not MainActor
                // isolated, so it cannot call `viewModel.isSoloDimmed(_:)`. So we test membership of the
                // set of audible objects there directly.
                let soloAudibleIDs = viewModel.soloAudibleObjectIDs
                func isDim(_ item: SoundObject) -> Bool {
                    if dimActive, !item.displayName.localizedCaseInsensitiveContains(filterText) { return true }
                    if soloDimActive, !soloAudibleIDs.contains(item.id) { return true }
                    return false
                }
                // The 'muted' dimming (its own or its stem's): the listening snapshot carries the rule,
                // and we do not rewrite it here — it is a value, hence readable from this nested function,
                // and it says exactly what the engine hears.
                let audibility = viewModel.audibility
                func isMutedItem(_ item: SoundObject) -> Bool { audibility.isMutedInMix(item) }
                func rectFor(_ entry: LaneEntry) -> CGRect {
                    let x = entry.item.startTime * pixelsPerSecond
                    let w = max(2, entry.item.duration * pixelsPerSecond)
                    let y = rulerHeight + Double(entry.displayLane) * laneStep
                    return CGRect(x: x, y: y, width: w, height: blockHeight)
                }

                // ── Phase 1: BATCHED BACKGROUNDS ──────────────────────────────────────
                // The cost when scrolling zoomed out = ~936 drawing calls (2 fills + 1 border × N),
                // NOT the text (already skipped) or the waveform (a sliver). We accumulate one Path per
                // stem colour (there are few stems) → 3 ops per colour instead of 3 × N.
                var rects: [Color: Path] = [:]
                var rectsDim: [Color: Path] = [:]
                for entry in entries {
                    var rr = Path()
                    rr.addRoundedRect(in: rectFor(entry), cornerSize: CGSize(width: 4, height: 4))
                    let stem = viewModel.stemColor(for: entry.item.id)
                    if isDim(entry.item) { rectsDim[stem, default: Path()].addPath(rr) }
                    else                 { rects[stem, default: Path()].addPath(rr) }
                }
                func fillBackgrounds(_ groups: [Color: Path], opacity: Double) {
                    guard !groups.isEmpty else { return }
                    var c = ctx; c.opacity = opacity
                    for (color, path) in groups {
                        c.fill(path, with: .color(.white))
                        c.fill(path, with: .color(color.opacity(0.30)))
                        c.stroke(path, with: .color(color.opacity(0.3)), lineWidth: 1.5)
                    }
                }
                fillBackgrounds(rects, opacity: 1.0)
                fillBackgrounds(rectsDim, opacity: 0.25)

                // ── Phase 2: WAVEFORMS BATCHED by fill colour ────────────────────────
                // Instead of N fill/strokes (≈14 ms at 240 blocks), we accumulate one Path per colour
                // and fill once. Skipped below 3px (an invisible sliver). Filtered (dimmed) blocks and
                // 'samples' mode (extreme zoom) are drawn separately.
                var waveFills: [Color: Path] = [:]
                var loopMarkers = Path()
                for entry in entries {
                    let item = entry.item
                    let w = max(2, item.duration * pixelsPerSecond)
                    guard w >= 3 else { continue }
                    let rect = rectFor(entry)
                    let x = rect.minX, y = rect.minY
                    let stem = viewModel.stemColor(for: item.id)

                    if isDim(item) {
                        // Filtered: an individual opacity → drawn directly.
                        var wc = ctx; wc.opacity = 0.25; wc.translateBy(x: x, y: y)
                        WaveformDrawing.draw(
                            into: wc, size: CGSize(width: w, height: blockHeight),
                            waveformCache: waveformCache, filePath: item.filePath,
                            sourceOffset: item.sourceOffset, pixelsPerSecond: pixelsPerSecond,
                            scrollOffsetX: cullScrollX, viewportWidth: cullViewportWidth, xPos: x,
                            stemColor: stem, isSelected: false,
                            clipDuration: item.duration, speedRatio: item.speedRatio,
                            isReversed: item.isReversed, volumeDb: item.volume,
                            fadeIn: item.fadeIn, fadeOut: item.fadeOut,
                            isMuted: isMutedItem(item), waveformDisplayDB: waveformDisplayDB,
                            loopRange: item.loopMarkerLocalRange)
                        continue
                    }

                    let fillColor: Color = isMutedItem(item) ? Color.gray.opacity(0.45) : stem.opacity(0.95)
                    let handled = WaveformDrawing.appendPeaksFill(
                        to: &waveFills[fillColor, default: Path()],
                        originX: x, originY: y, size: CGSize(width: w, height: blockHeight),
                        waveformCache: waveformCache, filePath: item.filePath,
                        sourceOffset: item.sourceOffset, pixelsPerSecond: pixelsPerSecond,
                        scrollOffsetX: cullScrollX, viewportWidth: cullViewportWidth,
                        clipDuration: item.duration, speedRatio: item.speedRatio,
                        isReversed: item.isReversed, volumeDb: item.volume,
                        fadeIn: item.fadeIn, fadeOut: item.fadeOut,
                        waveformDisplayDB: waveformDisplayDB, loopRange: item.loopMarkerLocalRange)
                    if !handled {
                        // Samples mode (extreme zoom, few blocks) → drawn individually and in full.
                        var wc = ctx; wc.translateBy(x: x, y: y)
                        WaveformDrawing.draw(
                            into: wc, size: CGSize(width: w, height: blockHeight),
                            waveformCache: waveformCache, filePath: item.filePath,
                            sourceOffset: item.sourceOffset, pixelsPerSecond: pixelsPerSecond,
                            scrollOffsetX: cullScrollX, viewportWidth: cullViewportWidth, xPos: x,
                            stemColor: stem, isSelected: false,
                            clipDuration: item.duration, speedRatio: item.speedRatio,
                            isReversed: item.isReversed, volumeDb: item.volume,
                            fadeIn: item.fadeIn, fadeOut: item.fadeOut,
                            isMuted: isMutedItem(item), waveformDisplayDB: waveformDisplayDB,
                            loopRange: item.loopMarkerLocalRange)
                    } else if let loopLocal = item.loopMarkerLocalRange {
                        // `appendPeaksFill` only lays the fill (batched by colour): the loop marks are
                        // drawn separately, in coordinates LOCAL to the block, translated here as the
                        // 'samples' drawing already does.
                        var block = Path()
                        WaveformDrawing.appendLoopMarkers(
                            to: &block, blockOriginX: x, size: CGSize(width: w, height: blockHeight),
                            pixelsPerSecond: pixelsPerSecond,
                            scrollOffsetX: cullScrollX, viewportWidth: cullViewportWidth,
                            clipDuration: item.duration, isReversed: item.isReversed,
                            loopRange: loopLocal)
                        loopMarkers.addPath(block, transform: CGAffineTransform(translationX: x, y: y))
                    }
                }
                for (color, path) in waveFills { ctx.fill(path, with: .color(color)) }
                if !loopMarkers.isEmpty {
                    ctx.stroke(loopMarkers, with: .color(.black.opacity(0.35)),
                              style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                }

                // ── Phase 3: FADES / MUTE / LABEL per block (over the waveform) ──────
                // Skipped when the block is too narrow → when scrolling zoomed out, an empty loop.
                var resolvedLabels: [String: GraphicsContext.ResolvedText] = [:]
                func resolvedLabel(_ s: String) -> GraphicsContext.ResolvedText {
                    if let r = resolvedLabels[s] { return r }
                    let r = ctx.resolve(Text(s)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.black))
                    resolvedLabels[s] = r
                    return r
                }
                for entry in entries {
                    let item = entry.item
                    let w = max(2, item.duration * pixelsPerSecond)
                    let needsLabel = w > 10
                    let needsFade  = item.fadeIn > 0 || item.fadeOut > 0
                    let needsMute  = isMutedItem(item)
                    guard needsLabel || needsFade || needsMute else { continue }

                    let rect = rectFor(entry)
                    let x = rect.minX, y = rect.minY
                    var c = ctx
                    if isDim(item) { c.opacity = 0.25 }

                    if needsFade {
                        let fiPx = item.fadeIn * pixelsPerSecond
                        let foPx = item.fadeOut * pixelsPerSecond
                        if fiPx > 0 {
                            var p = Path()
                            p.move(to: CGPoint(x: x, y: y))
                            p.addLine(to: CGPoint(x: x + min(fiPx, w), y: y))
                            p.addLine(to: CGPoint(x: x, y: y + blockHeight))
                            p.closeSubpath()
                            c.fill(p, with: .color(.black.opacity(0.30)))
                        }
                        if foPx > 0 {
                            var p = Path()
                            p.move(to: CGPoint(x: x + w - min(foPx, w), y: y))
                            p.addLine(to: CGPoint(x: x + w, y: y))
                            p.addLine(to: CGPoint(x: x + w, y: y + blockHeight))
                            p.closeSubpath()
                            c.fill(p, with: .color(.black.opacity(0.30)))
                        }
                    }

                    if needsMute {
                        var rr = Path()
                        rr.addRoundedRect(in: rect, cornerSize: CGSize(width: 4, height: 4))
                        c.fill(rr, with: .color(.black.opacity(0.38)))
                    }

                    // The label cropped to the block (unreadable/skipped below 10px — the zoomed-out case).
                    if needsLabel {
                        var lc = c
                        lc.clip(to: Path(rect))
                        lc.draw(resolvedLabel(item.displayName),
                                at: CGPoint(x: x + 6, y: y + 3), anchor: .topLeading)
                    }
                }
        }
        .frame(width: totalDuration * pixelsPerSecond, height: canvasHeight, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func groupBlock(for group: SoundObject, displayLane dl: Int) -> some View {
        GroupBlockView(
            group: group,
            pixelsPerSecond: pixelsPerSecond,
            rulerHeight: rulerHeight,
            blockHeight: blockHeight,
            laneGap: laneGap,
            // `showsChildrenInline`: in automation mode, the group does not show its children —
            // an open chevron there would announce content that is not visible.
            isExpanded: group.showsChildrenInline,
            isSelected: viewModel.selectedIDs.contains(group.id),
            activeTool: viewModel.activeTool,
            stemColor: viewModel.stemColor(for: group.id),
            isMutedInMix: viewModel.isMutedInMix(group),
            displayLane: dl,
            scrollOffsetX: cullScrollX,
            viewportWidth: cullViewportWidth,
            waveformDisplayDB: waveformDisplayDB,
            previewOffset:   previewOffset(for: group),
            previewResizeDX: previewResizeDX(for: group),
            previewTrimDX:   previewTrimDX(for: group),
            previewFadeIn:   previewFadeIn(for: group),
            previewFadeOut:  previewFadeOut(for: group),
            previewLoopRange: previewLoopRange(for: group),
            isToolHovered:   toolHoveredID == group.id,
            stemAssignTarget: stemAssignTarget,
            sendRows:        (viewModel.activeTool == .toolAux)
                                ? viewModel.sendRows(for: group.id) : [],
            isRenaming:      viewModel.renamingID == group.id,
            isBaking:      viewModel.isBaking(group.id),
            isPreviewing:    viewModel.hasLiveMirrors && viewModel.editingPlacementID == group.id,
            isEditing:       viewModel.editingPlacementID == group.id,
            onRename: { label in
                if let label { viewModel.renameObject(id: group.id, label: label) }
                viewModel.renamingID = nil
            },
            waveformCache: waveformCache
        )
        .onAppear {
            if case .group(let children, _) = group.kind {
                for child in children {
                    if case .clip(let fp, _, _, _, _) = child.kind {
                        waveformCache.load(filePath: fp)
                    }
                }
            }
        }
        .opacity(blockOpacity(for: group))
    }

    // MARK: - Modifiers of the move under way

    /// A reminder of the two modifiers that change an object move WHILE one is making it, with
    /// each one's state. It is the only moment when they count, and the only one when one cannot
    /// go and read a cheat sheet — the hand is already holding the mouse.
    ///
    /// ⌥ is read off `moveDrag.isAltCopy` — the state the gesture WILL APPLY, not a second reading
    /// of the keyboard that could diverge from it. It stays up to date without moving the mouse
    /// thanks to the `onChange(of: optKeyHeld)` laid on the view. ⌘, for its part, is not carried
    /// by the gesture: it is `cmdKeyHeld` that feeds into `effectiveSnapEnabled`, so it is the
    /// source. A drag born of a time selection froze its ⌥ at the start (fragments prepared): we
    /// flag that with a padlock rather than let one believe it can be flipped.
    @ViewBuilder
    private var moveDragHUD: some View {
        if let md = moveDrag {
            let altFrozen = md.timeSelectionAnchor != nil
            let altOn     = md.isAltCopy
            HStack(spacing: 7) {
                Image(systemName: altOn ? "plus.square.on.square" : "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(altOn ? L("hud.move.copy") : L("hud.move.move"))
                    .font(.system(size: 11, weight: .bold))
                modifierChip("⌥", L("hud.move.chip.copy"), on: altOn, locked: altFrozen)
                modifierChip("⌘", viewModel.snapEnabled ? L("hud.move.chip.ignoreSnap") : L("hud.move.chip.forceSnap"),
                             on: viewModel.cmdKeyHeld, locked: false)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1))
            .padding(.bottom, 12)
            .allowsHitTesting(false)   // a gesture is under way: this band must catch nothing
        }
    }

    /// A modifier's badge: lit while it is held. `locked` = the gesture froze that choice at its
    /// start, and releasing it will change nothing.
    private func modifierChip(_ glyph: String, _ label: String,
                              on: Bool, locked: Bool) -> some View {
        HStack(spacing: 4) {
            Text(glyph)
                .font(.system(size: 11, weight: .bold, design: .rounded))
            Text(label)
                .font(.system(size: 10))
            if locked {
                Image(systemName: "lock.fill").font(.system(size: 8))
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .foregroundStyle(on ? Color.white : Color.secondary)
        .background(on ? Color.accentColor : Color.primary.opacity(0.09), in: Capsule())
    }

    /// The cheat sheet (a tool key or a modifier held) — see ShortcutCheatsheet.
    @ViewBuilder
    private var cheatsheetOverlay: some View {
        if let ctx = viewModel.cheatsheet {
            CheatsheetPanel(context: ctx)
                .padding(.bottom, 12)   // the same breathing space as the neighbouring status bands
        }
    }

    // MARK: - File drop band

    /// An explanatory rectangle shown while one or more files hover the timeline.
    /// It shows BOTH layouts and highlights the one that would apply if one released now. The
    /// preview follows ⌘ live, even without moving the mouse — that is the intended gesture
    /// (arrive over the timeline, read the band, press ⌘). Tracking the modifier is on the
    /// view-model's side (`beginFileDropHint`): `dropUpdated` only speaks on movement.
    @ViewBuilder
    private var fileDropHintOverlay: some View {
        if let hint = viewModel.fileDropHint {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text(Ln("hud.drop.fileCount", hint.count, hint.count))
                        .font(.system(size: 11, weight: .bold))
                    Text(L("hud.drop.cmdHint"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    fileDropModeCard(.stacked, active: hint.mode == .stacked, count: hint.count)
                    fileDropModeCard(.sequential, active: hint.mode == .sequential, count: hint.count)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1))
            .padding(.bottom, 12)
            .allowsHitTesting(false)   // it must never intercept the drop
            .animation(.easeOut(duration: 0.12), value: hint.mode)
        }
    }

    /// One of the two layouts, in the band. The active card is the one that would apply.
    @ViewBuilder
    private func fileDropModeCard(_ mode: EditViewModel.FileDropMode,
                                  active: Bool, count: Int) -> some View {
        VStack(spacing: 5) {
            fileDropModeGlyph(mode, active: active, count: count)
            HStack(spacing: 4) {
                if mode == .sequential {
                    Text(verbatim: "⌘")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(active ? Color.accentColor : .secondary)
                }
                Text(mode.title)
                    .font(.system(size: 10, weight: active ? .bold : .regular))
            }
            Text(mode.detail)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(active ? Color.accentColor.opacity(0.16) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(active ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.25),
                          lineWidth: active ? 1.4 : 1))
        .opacity(active ? 1 : 0.55)
    }

    /// A schematic preview: blocks laid out as they really will be — stacked on lanes at the same
    /// start, or lined up end to end on a single lane. A drawing says the layout faster than a
    /// sentence, and it is what flips under ⌘.
    private func fileDropModeGlyph(_ mode: EditViewModel.FileDropMode,
                                   active: Bool, count: Int) -> some View {
        let n = min(max(count, 2), 3)
        let color = active ? Color.accentColor : Color.secondary
        let isRow = mode == .sequential
        // `offset` takes no part in the layout: the size of the drawn group is given explicitly,
        // then centred in a box common to both cards (they have to keep the same width, otherwise
        // the band jumps from one mode to the other).
        let drawnW: Double = isRow ? 16 + Double(n - 1) * 17 : 16
        let drawnH: Double = isRow ? 5 : 5 + Double(n - 1) * 7
        return ZStack(alignment: .topLeading) {
            ForEach(Array(0..<n), id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color.opacity(active ? 0.9 : 0.55))
                    .frame(width: 16, height: 5)
                    .offset(x: isRow ? Double(i) * 17 : 0,
                            y: isRow ? 0 : Double(i) * 7)
            }
        }
        .frame(width: drawnW, height: drawnH, alignment: .topLeading)
        .frame(width: 56, height: 22)
    }

    // MARK: - Tool indicator

    private var toolIndicator: some View {
        HStack(spacing: 4) {
            Image(systemName: toolIcon).font(.system(size: 10))
            Text(toolKey).font(.system(size: 10, weight: .bold, design: .monospaced))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
        .padding(10)
    }

    // The 'assign stem' tool's HUD: visible while the tool is active (a digit held or locked with
    // ⇧). It reminds one of the target stem, the locked state, and the gesture (a click = paint
    // the object, Return = assign the selection).
    @ViewBuilder
    private var stemAssignHUD: some View {
        if viewModel.activeTool == .toolStemAssign,
           let n = viewModel.stemAssignIndex, n >= 1, n <= viewModel.stems.count {
            let stem = viewModel.stems[n - 1]
            let isMain = stem.id == viewModel.mainStemID
            let locked = viewModel.isToolPermanent
            // A reminder of the mute shortcut (unavailable on the Main, which is not mutable). A single
            // label both ways: the key TOGGLES, and the muted state already reads on the struck-through name.
            let muteHint = isMain ? "" : " " + L("hud.stem.muteHint")
            let stemLabel = "\(n) \(isMain ? L("stem.main.name") : stem.name)"
            HStack(spacing: 7) {
                Circle()
                    .fill(stem.color)   // the Main carries its colour like the other buses
                    .frame(width: 9, height: 9)
                Text(verbatim: "\(n) · \(isMain ? L("stem.main.name") : stem.name)")
                    .font(.system(size: 11, weight: .semibold))
                    .strikethrough(stem.muted, color: .secondary)
                if stem.muted {
                    Image(systemName: "speaker.slash.fill").font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                if locked {
                    Image(systemName: "lock.fill").font(.system(size: 9))
                        .foregroundStyle(Color.accentColor)
                }
                Text((locked
                     ? L("hud.stem.lockedHint", stemLabel)
                     : L("hud.stem.hint", stemLabel)) + muteHint)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                // A keyboard counterpart of digit+⏎: it assigns the selection to that stem without
                // releasing the held key.
                HUDButton(title: L("hud.stem.assignSelection"), shortcut: "⏎", prominent: true) {
                    viewModel.edit { viewModel.assignStemSelected(stemID: stem.id) }
                }
                .disabled(viewModel.selectedIDs.isEmpty)
                .help(L("hud.stem.assignSelection.help", isMain ? L("stem.main.name") : stem.name))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1))
            .padding(.bottom, 12)
        }
    }

    /// The stem the assignment tool is aiming at, or nil if the tool is not armed. Resolved here so
    /// that the blocks do not have to know about `stems`: they receive the name, the number and the colour.
    private var stemAssignTarget: StemAssignTarget? {
        guard viewModel.activeTool == .toolStemAssign,
              let n = viewModel.stemAssignIndex,
              n >= 1, n <= viewModel.stems.count else { return nil }
        let stem = viewModel.stems[n - 1]
        return StemAssignTarget(number: n,
                                name: stem.id == viewModel.mainStemID ? L("stem.main.name") : stem.name,
                                color: stem.color)
    }

    // MARK: - Selection info band

    /// The length of the current selection, in seconds: the time range if there is one, otherwise
    /// the span of the selected objects (from the earliest to the latest, in ABSOLUTE time — hence
    /// going through laneEntries, which handles children of groups). An infinite bus has neither a
    /// start nor an end: it does not count. nil = nothing measurable, and the band stays hidden.
    private var selectionDuration: Double? {
        if let sel = viewModel.timeSelection {
            let d = sel.timeRange.upperBound - sel.timeRange.lowerBound
            return d > 0 ? d : nil
        }
        let spans = viewModel.laneEntries.filter {
            viewModel.selectedIDs.contains($0.item.id) && !$0.item.isInfiniteBus
        }
        guard let lo = spans.map(\.absStart).min(),
              let hi = spans.map({ $0.absStart + $0.item.duration }).max(),
              hi > lo else { return nil }
        return hi - lo
    }

    /// A readable length: beyond the minute we count in min + s, below it in s + ms — the fine unit
    /// is always the one being handled at that scale. The roundings are done on the total before
    /// splitting, so as never to show '1 min 60.0 s'.
    static func selectionDurationString(_ d: Double) -> String {
        if d >= 60 {
            let tenths = (d * 10).rounded()
            let m      = Int(tenths) / 600
            let s      = (Int(tenths) % 600) / 10
            let dixth  = Int(tenths) % 10
            return String(format: L("duration.minutesSeconds"), m, s, dixth)
        }
        let totalMs = Int((d * 1000).rounded())
        if totalMs >= 1000 {
            return String(format: L("duration.secondsMillis"), totalMs / 1000, totalMs % 1000)
        }
        return "\(totalMs) ms"
    }

    /// The number of samples covered, grouped in thousands (a narrow no-break space).
    static func selectionSamplesString(_ d: Double, sampleRate: Double) -> String {
        let n = Int((d * sampleRate).rounded())
        return sampleCountFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private static let sampleCountFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = "\u{202F}"   // a narrow no-break space, French typographic usage
        f.groupingSize = 3
        return f
    }()

    /// The info band: as soon as a selection covers a non-zero length, one reads how long it is.
    ///
    /// The sample count only shows BELOW ONE SECOND. That is where it serves: under the second one
    /// works to the sample, and the readable time no longer says it; beyond, it is a large number
    /// nobody reads, which only lengthens the band.
    @ViewBuilder
    private var selectionInfoHUD: some View {
        if let d = selectionDuration {
            let sr = viewModel.engine?.currentSampleRate() ?? 0
            HStack(spacing: 7) {
                Image(systemName: "timeline.selection").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(L("hud.selection.title")).font(.system(size: 11, weight: .bold))
                Text(Self.selectionDurationString(d))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                if sr > 0, d < 1 {
                    Text(verbatim: "·").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(L("hud.selection.samples", Self.selectionSamplesString(d, sampleRate: sr), AudioStatusTitleView.shortRate(sr)))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1))
            .padding(.bottom, 12)
            .allowsHitTesting(false)   // a purely informative band: it does not take the click
        }
    }

    // The HUD of the temporary solo with 's' held: it reminds one of what is being added to what
    // is heard and how to leave (release the key). Distinct from the committed solo's HUD, which
    // persists after the gesture — the two coexist, since the two layers add up (the temporary
    // one being on top).
    // Visible as soon as 's' is down, even with nothing armed: that is where one reads 'click
    // objects to solo' — and its buttons give the mouse the equivalent of the s+⏎ and Esc chords,
    // for anyone composing what they hear by clicking with no free hand for the key.
    //
    // Vocabulary: the COMMITTED solo is called 'hold' on the interface's side — what one keeps
    // after releasing 's'. Hence [Hold] / [unHold] on the ⏎ button.
    @ViewBuilder
    private var heldSoloHUD: some View {
        if viewModel.soloKeyHeld || viewModel.heldSoloActive {
            let roots = viewModel.heldSoloActive ? (viewModel.tempSoloRoots ?? []) : []
            let n = roots.count
            // The same collective convention as the ⏎ key: everything one is hearing is already
            // committed → the gesture UNcommits it. The button announces that rather than lie about its effect.
            let undo = n > 0 && roots.allSatisfy { viewModel.soloedIDs.contains($0) }
            HStack(spacing: 7) {
                Image(systemName: "headphones").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(L("hud.solo.title")).font(.system(size: 11, weight: .bold))
                Text(n == 0
                     ? L("hud.solo.hintEmpty")
                     : Ln("hud.solo.hint", n, n))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                HUDButton(title: undo ? L("hud.solo.unhold") : L("hud.solo.hold"), shortcut: "⏎", prominent: !undo) {
                    viewModel.toggleSoloForCurrentSelection()
                }
                .disabled(n == 0)
                .help(undo ? L("hud.solo.unhold.help") : L("hud.solo.hold.help"))
                // Only if there is something to clear: with no hold, releasing 's' is already enough to
                // leave, and a greyed-out button says nothing more.
                if viewModel.soloActive {
                    HUDButton(title: L("hud.solo.exit"), shortcut: L("shortcut.escape")) {
                        viewModel.clearAllSolo()
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1))
            .padding(.bottom, 12)
        }
    }

    // The solo HUD: visible while a committed solo filters what is heard. It reminds one how many
    // objects/stems are soloed and how to leave (Esc). A temporary solo (tied to playback) does
    // not show it — it disappears of its own accord on stopping.
    @ViewBuilder
    private var soloHUD: some View {
        if viewModel.soloActive {
            let objCount  = viewModel.soloedIDs.count
            let stemCount = viewModel.soloedStemIDs.count
            let parts: [String] = [
                objCount  > 0 ? Ln("hud.solo.objectCount", objCount, objCount) : nil,
                stemCount > 0 ? Ln("hud.solo.stemCount", stemCount, stemCount) : nil,
            ].compactMap { $0 }
            HStack(spacing: 7) {
                Image(systemName: "headphones").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(L("hud.solo.title")).font(.system(size: 11, weight: .bold))
                Text(parts.joined(separator: " · "))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                HUDButton(title: L("hud.solo.exit"), shortcut: L("shortcut.escape")) {
                    viewModel.clearAllSolo()
                }
                .help(L("hud.solo.exit.help"))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1))
            .padding(.bottom, 12)
        }
    }

    private var toolIcon: String {
        switch viewModel.activeTool {
        case .toolSelection: return "cursorarrow"
        case .toolCut:       return "scissors"
        case .toolVolume:    return "speaker.wave.2"
        case .toolPan:       return "slider.horizontal.3"
        case .toolAux:      return "arrow.triangle.branch"
        case .toolStemAssign: return "paintbrush.pointed"
        }
    }

    private var toolKey: String {
        let permanent = viewModel.isToolPermanent
        switch viewModel.activeTool {
        case .toolSelection: return "E"
        case .toolCut:       return permanent ? "C⊙" : "C"
        case .toolVolume:    return permanent ? "V⊙" : "V"
        case .toolPan:       return permanent ? "P⊙" : "P"
        case .toolAux:      return permanent ? "A⊙" : "A"
        case .toolStemAssign:
            let n = viewModel.stemAssignIndex ?? 0
            return permanent ? "\(n)⊙" : "\(n)"
        }
    }

    // MARK: - Virtual lane layout

    func displayLane(for baseLane: Int) -> Int {
        let extra = viewModel.items.reduce(0) { acc, item in
            item.lane < baseLane ? acc + item.expandedSpan : acc
        }
        return baseLane + extra
    }

    func laneY(for baseLane: Int) -> Double {
        rulerHeight + Double(displayLane(for: baseLane)) * laneStep
    }

    // MARK: - The timeline's displayed length

    /// The canvas grows at once when the content does; it only shrinks when nobody is looking at
    /// the area concerned (see `relaxStickyDuration`).
    private func syncStickyDuration() {
        let content = contentDuration
        if content > stickyTotalDuration { stickyTotalDuration = content }
        else { relaxStickyDuration() }
    }

    /// Shrinks the timeline onto its real content — but only if that moves nothing on screen: no
    /// gesture under way, and the visible window already fitting inside the new content (otherwise
    /// the ScrollView would reclamp the scroll, which feels like a jump in zoom).
    private func relaxStickyDuration() {
        let content = contentDuration
        guard stickyTotalDuration > content else { return }
        guard moveDrag == nil, resizeDrag == nil, trimDrag == nil, fadeDrag == nil,
              timeSelectionDrag == nil, cutDrag == nil, slipDrag == nil,
              loopRangeDrag == nil else { return }
        // During a zoom, shrinking the canvas would move the scroll's stop under the anchor:
        // that is exactly the jump the zoom session is trying to avoid (@see applyZoom).
        guard !zoomSessionActive else { return }
        guard content * pixelsPerSecond >= Double(scrollOffsetX) + Double(viewportWidth) else { return }
        stickyTotalDuration = content
    }

    /// Rearms the displayed length on the real content, unconditionally, and brings the scroll back
    /// into the new canvas. Reserved for wholesale replacements of the content (a new project, an
    /// opening) — during editing, it is `relaxStickyDuration` that decides.
    private func resetStickyDuration() {
        let content = contentDuration
        stickyTotalDuration = content
        let maxScrollX = max(0, content * pixelsPerSecond - Double(viewportWidth))
        if Double(scrollOffsetX) > maxScrollX {
            scrollTo(x: CGFloat(maxScrollX), y: scrollOffsetY)
        }
    }

    // MARK: - Zoom helpers

    func clampZoom(_ v: Double) -> Double { min(max(v, minZoom), maxZoom) }
    func clampBlockHeight(_ v: Double) -> Double { min(max(v, minBlockHeight), maxBlockHeight) }

    /// A zoom session is under way: the canvas must neither shrink nor move under the anchor
    /// (see `relaxStickyDuration`).
    var zoomSessionActive: Bool {
        let now = ProcessInfo.processInfo.systemUptime
        return hZoomHeld || vZoomHeld
            || now - hZoomLastEventTime < Self.zoomSessionIdleGap
            || now - vZoomLastEventTime < Self.zoomSessionIdleGap
    }

    /// The horizontal zoom's fixed point: the BLACK CURSOR (the editing caret), which coincides
    /// with the start of the time selection when there is one (every piece of code that lays a
    /// selection calls `onMoveCursor` on its left bound). When it is off screen it cannot serve as
    /// a visual reference — we then zoom on the centre of the window, which keeps what one is
    /// looking at in view. That choice is only made when a session OPENS, never during it.
    private func openHorizontalZoomSession() {
        let pps = pixelsPerSecond
        let cursorX = CGFloat(currentSelectionCursor * pps)
        let isCursorVisible = cursorX >= scrollOffsetX && cursorX <= scrollOffsetX + viewportWidth
        hZoomAnchorTime = isCursorVisible
            ? currentSelectionCursor
            : Double((scrollOffsetX + viewportWidth / 2) / CGFloat(pps))
        hZoomAnchorViewportX = CGFloat(hZoomAnchorTime * pps) - scrollOffsetX
        hZoomLockedY = scrollOffsetY
    }

    private func openVerticalZoomSession() {
        vZoomAnchorRelY = max(0, scrollOffsetY + viewportHeight / 2 - CGFloat(rulerHeight))
        vZoomBaseHeight = blockHeight
        vZoomLockedX = scrollOffsetX
    }

    /// Opens a session if none is open (an explicit drag) or fresh (the wheel).
    /// It returns after dating the notch: the session stays alive while the notches chain.
    private func touchHorizontalZoomSession() {
        let now = ProcessInfo.processInfo.systemUptime
        if !hZoomHeld && now - hZoomLastEventTime > Self.zoomSessionIdleGap {
            openHorizontalZoomSession()
        }
        hZoomLastEventTime = now
    }

    private func touchVerticalZoomSession() {
        let now = ProcessInfo.processInfo.systemUptime
        if !vZoomHeld && now - vZoomLastEventTime > Self.zoomSessionIdleGap {
            openVerticalZoomSession()
        }
        vZoomLastEventTime = now
    }

    func applyZoom(_ newPPS: Double) {
        let clamped = clampZoom(newPPS)
        touchHorizontalZoomSession()
        guard clamped != pixelsPerSecond else { return }
        viewModel.pixelsPerSecond = clamped
        // x_screen(t) = t·pps − scrollX: keeping the anchor still means solving for scrollX.
        let maxScrollX = max(0, totalDuration * clamped - Double(viewportWidth))
        let newScrollX = min(CGFloat(maxScrollX),
                             max(0, CGFloat(hZoomAnchorTime * clamped) - hZoomAnchorViewportX))
        scrollTo(x: newScrollX, y: hZoomLockedY)
    }

    func applyVerticalZoom(_ newHeight: Double) {
        let clamped = clampBlockHeight(newHeight)
        touchVerticalZoomSession()
        guard clamped != blockHeight else { return }
        viewModel.blockHeight = clamped
        // The canvas grows WITH the block height: bounding the scroll on the old height
        // brought the view back on every zoom-in notch (hence the jumps).
        let ratio = CGFloat(clamped + laneGap) / CGFloat(vZoomBaseHeight + laneGap)
        let newContentY = CGFloat(rulerHeight) + vZoomAnchorRelY * ratio
        let newCanvasH = canvasHeight(forBlockHeight: clamped)
        let maxScrollY = max(0, newCanvasH - Double(viewportHeight))
        let newScrollY = min(CGFloat(maxScrollY), max(0, newContentY - viewportHeight / 2))
        scrollTo(x: vZoomLockedX, y: newScrollY)
    }

    /// Frames the view on a time range: it zooms so that it fits in the visible window (with a 6 %
    /// margin on either side, otherwise the markers stick to the edges) then scrolls to bring it to
    /// the left. Used by the export panel when setting the I/O markers — one wants to see the whole
    /// range, not guess it.
    ///
    /// The zoom goes through `viewModel.pixelsPerSecond` directly, without `applyZoom`: that one
    /// keeps an anchor point (the cursor or the centre of the window), which is exactly what is not
    /// wanted here — it is the RANGE that governs the framing.
    func revealTimeRange(_ range: ClosedRange<Double>) {
        let span = max(0.05, range.upperBound - range.lowerBound)
        let margin = 0.06
        let pps = clampZoom(Double(viewportWidth) * (1 - 2 * margin) / span)
        viewModel.pixelsPerSecond = pps
        // After the change of scale: the canvas has to have its new width before we move inside it,
        // otherwise the ScrollView bounds the scroll on the old one.
        DispatchQueue.main.async {
            let maxScrollX = max(0, totalDuration * pps - Double(viewportWidth))
            let x = min(maxScrollX, max(0, range.lowerBound * pps - Double(viewportWidth) * margin))
            scrollTo(x: CGFloat(x), y: scrollOffsetY)
        }
    }

    /// Moves the scroll AND updates `scrollOffsetX/Y` at once.
    ///
    /// Those two @States are not merely a mirror: all the drawing uses them so as to draw only the
    /// visible portion — grid lines, waveforms, blocks, the ruler, tool veils. And they are written
    /// by `onScrollGeometryChange`, which only speaks AFTER the ScrollView has applied the
    /// requested scroll. During a zoom, the content therefore takes its new scale one frame BEFORE
    /// the visible window is updated: the culling cuts in the wrong place, and part of the timeline
    /// disappears for the length of a frame — that is the flicker.
    ///
    /// So we set the REQUESTED value at once: it is already bounded by the same stop as the one the
    /// ScrollView will apply, so the two coincide, and the geometry callback merely confirms. In the
    /// contrary case it corrects, as before.
    private func scrollTo(x: CGFloat, y: CGFloat) {
        scrollPosition.scrollTo(x: x, y: y)
        scrollAnchor.x = x
        scrollAnchor.y = y
        viewModel.viewScrollX = Double(x)
        viewModel.viewScrollY = Double(y)
        refreshCullWindow()
    }

    /// Resets the culling window on the current notch. Called on every scrolling frame, it only
    /// writes — hence only invalidates — when a notch is crossed. @see cullScrollX
    private func refreshCullWindow() {
        let step = Self.cullStepPx
        let bucket = (scrollAnchor.x / step).rounded(.down) * step
        if bucket != cullScrollX { cullScrollX = bucket }
    }

    // A rubber-band selection in display-lane space.
    // It replaces viewModel.selectClipsIn (which compares base lanes) everywhere in TimelineView.
    func selectInDisplayLanes(_ sel: TimeSelection) {
        let t1 = sel.timeRange.lowerBound
        let t2 = sel.timeRange.upperBound
        viewModel.selectedIDs = Set(
            viewModel.laneEntries
                .filter { sel.lanes.contains($0.displayLane) }
                .filter { $0.absStart >= t1 && $0.absStart + $0.item.duration <= t2 }
                .map    { $0.item.id }
        )
    }
}

/// A status band's button (a temporary solo, a committed solo, stem assignment): the CLICKABLE
/// equivalent of a keyboard chord — s+⏎, Esc, digit+⏎. Those chords are played with one key
/// held and the other far away; when one is already composing with the mouse, the button saves
/// the contortion. The shortcut stays shown next to the label: the band teaches the keyboard as
/// much as it stands in for it.
private struct HUDButton: View {
    let title: String
    let shortcut: String
    var prominent: Bool = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).font(.system(size: 10, weight: .semibold))
                Text(shortcut)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .opacity(0.65)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background(prominent ? Color.accentColor : Color.primary.opacity(0.09), in: Capsule())
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

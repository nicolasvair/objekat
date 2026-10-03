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

/// The red playhead line — the only view of the timeline that reads the playhead, so that a
/// tick redraws this line and nothing else (@see TimelineView.playheadPosition).
private struct PlayheadLine: View {
    let position: () -> Double
    let pixelsPerSecond: Double
    let isPlaying: Bool
    let height: CGFloat
    let top: CGFloat
    var body: some View {
        Rectangle()
            .fill(Color.red.opacity(isPlaying ? 0.85 : 0.45))
            .frame(width: 1.5, height: height)
            .offset(x: position() * pixelsPerSecond - 0.75, y: top)
    }
}

struct TimelineView: View {
    var viewModel: EditViewModel
    /// A READER, not a value: passed by value, each tick of the playhead (20 per second) rebuilt
    /// the whole body — every block of the project — to move one line; on a 1 250-object project
    /// that was ~70 % of the main thread during playback. Only `PlayheadLine` calls it.
    var playheadPosition: () -> Double = { 0 }
    var selectionCursor: Double = 0
    var isPlaying: Bool = false
    /// Playback suspended (⇧space): the playhead stays where it is and resuming starts from there.
    var isPaused: Bool = false
    var onTogglePlayback: () -> Void = {}
    /// ⇧space: suspend / resume in the same place (without going back to the cursor).
    var onTogglePause: () -> Void = {}
    var onMoveCursor: (Double) -> Void = { _ in }
    var onReturnToZero: () -> Void = {}

    // Not `private`: read by the gesture handlers (extensions in other files) so as to bound the
    // tool controls to the block's visible portion (see visibleSpan).
    @State var viewportWidth: CGFloat = 800
    @State private var viewportHeight: CGFloat = 400
    @State private var scrollPosition = ScrollPosition()
    @State private var scrollAnchor = TimelineScrollAnchor()
    @State private var currentSelectionCursor: Double = 0

    // MARK: - Vertical lane snap (@see VerticalLaneSnap)

    /// The viewport has been MEASURED at least once: a clamp evaluated against the fake 400 pt
    /// default at launch would permanently shrink a restored zoom before the real size is known.
    @State private var viewportMeasured: Bool = false
    /// The available lane height as of the LAST resize handled — kept so D3's resize can compute
    /// the ratio against the height that is actually changing, not the new one twice over.
    @State private var lastAvailableLaneHeight: Double = 0
    /// Whether an end-of-zoom / D7 idle re-frame is armed and has not landed yet — read by
    /// `view.state.vsnap.pending` so a test does not sample mid-settle (@see waitViewAtRest).
    @State private var vSnapPendingFraming: Bool = false

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
    static let cullStepPx: CGFloat = 512
    /// What the blocks read to lay things in their VISIBLE portion with the exact scroll (@see
    /// LiveScroll). Holding it reads nothing: the anchor's `x` is only read by the small views
    /// that need it, and only when a block straddles the viewport's edge.
    private var liveScroll: LiveScroll {
        LiveScroll(anchor: scrollAnchor, viewportWidth: viewportWidth,
                   cullScrollX: cullScrollX, cullStepPx: Self.cullStepPx)
    }
    /// The width to cull: the real viewport plus the possible notch of lag. @see cullScrollX
    private var cullViewportWidth: CGFloat { viewportWidth + Self.cullStepPx }

    /// The VERTICAL notch, same contract as `cullScrollX`: the real vertical scroll rounded down to a
    /// multiple of `cullStepPx`. The layers that iterate lanes (the bands, the tints, the masks,
    /// the time selection and the carets…) cull on `[cullScrollY, cullScrollY + cullViewportHeight]`
    /// instead of walking everything the timeline holds: what a frame costs follows what is SHOWN.
    @State private var cullScrollY: CGFloat = 0
    /// What the caret's ink follows (@see caretsCanvas): read in the body, hence a change of
    /// appearance re-evaluates it.
    @Environment(\.colorScheme) private var colorScheme
    /// The height to cull: the real viewport plus the possible notch of lag. @see cullScrollY
    private var cullViewportHeight: CGFloat { viewportHeight + Self.cullStepPx }

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
    /// D12 — the lane span held centred on screen for the whole session, read ONCE at
    /// `openVerticalZoomSession` from `selectionAnchorLaneCentre`. `nil` means no selection, no
    /// caret and no traced time selection at the moment the session opened: `vZoomAnchorRelY`
    /// (the viewport's own centre) is what governs the zoom instead, exactly as before D12.
    @State private var vZoomAnchorLaneCentre: Double? = nil
    @State private var vZoomHeld: Bool = false
    /// D8 — the end-of-zoom-session settle: cancelled and rearmed on every notch of the wheel /
    /// ⇧-scroll / ⇧R / ⇧T, fires `VerticalLaneSnap.zoomSettleDebounce` after the last one.
    @State private var vZoomSettleWork: DispatchWorkItem? = nil
    @State private var vZoomLastEventTime: TimeInterval = 0

    /// The silence beyond which a wheel notch opens a NEW zoom session (and therefore reevaluates
    /// the anchor). Below it, the notches chain within the same gesture.
    private static let zoomSessionIdleGap: TimeInterval = 0.4

    var pixelsPerSecond: Double { viewModel.pixelsPerSecond }
    /// The furthest the view zooms OUT: the whole session, and a little more, in the window. The
    /// session's length is `contentEnd`, floored on a new project's span (60 s) so a short project
    /// still stops at a minute of timeline. It is deliberately NOT `totalDuration`: that one
    /// carries the 60 % right headroom, which depends on the zoom itself, and the fixed point of
    /// the two (`0.4 · viewportWidth / contentEnd`) left a session's last 60 % of the window
    /// unusable. The headroom stays — it is what one scrolls into past the last object — only it
    /// no longer bounds the zoom. The old `max(1, …)` capped the view at 1 px/s, i.e. ~10 min on
    /// a 600 px window, whatever the session lasted.
    private var minZoom: Double {
        let span = max(contentEnd * Self.zoomOutFitFactor, EditViewModel.newProjectSpan)
        return max(EditViewModel.minPixelsPerSecond, Double(viewportWidth) / span)
    }
    /// The room left round the session at full zoom-out: it fills 1 / 1.05 of the window.
    static let zoomOutFitFactor: Double = 1.05
    private let maxZoom: Double = 200000
    /// The WHOLE header: the ruler proper, plus one row per visible row of the marker band.
    /// Computed, and that is the point — every lane offset in this file is measured from it, so a
    /// row appearing or disappearing pushes the content down or lets it back up with no other
    /// change anywhere. @see MarkerBandGeometry, the single source the AppKit monitors read too.
    var rulerHeight: Double {
        MarkerBandGeometry.headerHeight(visibleLanes: viewModel.visibleMarkerLaneCount)
    }
    var blockHeight: Double { viewModel.blockHeight }
    var waveformDisplayDB: Double { viewModel.waveformDisplayDB }
    private let laneGap: Double = 4
    private let minBlockHeight: Double = 16
    /// D1 — "available height": the lane area under the sticky header, marker rows included in
    /// the header, read LIVE (the window and the marker rows both move it). `VerticalLaneSnap`
    /// measures a lane against the BLOCK alone, never `laneStep` — the 4 pt gap is not "the lane".
    var availableLaneHeight: Double { max(0, Double(viewportHeight) - Double(rulerHeight)) }
    /// D2 — the 90 % clamp. The old `max(120, …)` floor is gone: it could exceed a small window.
    private var maxBlockHeight: Double {
        VerticalLaneSnap.maxBlockHeight(available: availableLaneHeight, minBlockHeight: minBlockHeight)
    }
    /// Whether the vertical view is snapped to the lanes (§ the request): the block occupies more
    /// than 70 % of the available height.
    var verticalSnapActive: Bool {
        VerticalLaneSnap.isActive(blockHeight: blockHeight, available: availableLaneHeight)
    }
    private let minLanes: Int = 2

    /// Where the project's matter really ends: the right edge of its last object.
    /// Cached by the view model with `items` (@see EditViewModel+ItemsExtent): this is read some
    /// twenty times per pass, and a walk of every top-level object each time cost a fifth of a zoom.
    private var contentEnd: Double { viewModel.contentEnd }

    /// The length the content really takes (plus some room to manoeuvre). Deliberately free of the
    /// zoom: it is what `stickyTotalDuration` is measured against, and a length that changed with
    /// every wheel notch would have the canvas growing and shrinking under the hand.
    private var contentDuration: Double { max(EditViewModel.newProjectSpan, contentEnd + 10) }

    /// Empty room kept to the RIGHT of the last object, as a fraction of the window: one goes on
    /// scrolling and zooming out until that object's end sits 40 % of the way across, with the
    /// remaining 60 % empty. Working at the end of a project one is always laying sound down AFTER
    /// what is there, and a timeline that stops dead at its last object gives the hand nowhere to
    /// put it.
    private static let rightHeadroomFraction: Double = 0.60

    /// Empty rows kept BELOW the last one, as a fraction of the visible lanes: one goes on
    /// scrolling down until the lowest row sits 40 % of the way up from the foot. Measured on the
    /// LANE area and not on the window, the ruler being a sticky header that never shows content.
    private static let bottomHeadroomFraction: Double = 0.40

    /// That room, in seconds at the current scale.
    private var rightHeadroom: Double {
        pixelsPerSecond > 0 ? Self.rightHeadroomFraction * Double(viewportWidth) / pixelsPerSecond : 0
    }

    /// The length of the DISPLAYED timeline. It grows at once when the content does, but never
    /// shrinks under the hand: moving the last sound to the left would shorten the canvas, which
    /// would make the scroll jump and the zoom move under one's fingers. Shrinking is deferred
    /// until a moment when it moves nothing on screen (see `syncStickyDuration`) — only the zoom
    /// BOUNDS follow, never the current zoom.
    ///
    /// The headroom is added HERE and not to `contentDuration`, so that the sticky length goes on
    /// answering to the objects alone. It is also what bounds the zoom out, and the fixed point is
    /// exactly the rule asked for: `minZoom = viewportWidth / totalDuration` cannot be satisfied
    /// below `0.4 · viewportWidth / contentEnd`, i.e. the scale at which the project fills the
    /// first 40 % of the window. The 60 s floor keeps its say for a short project — one still
    /// zooms out to a minute of timeline rather than to a minute taking 40 % of the screen.
    private var totalDuration: Double {
        max(max(contentDuration, stickyTotalDuration), contentEnd + rightHeadroom)
    }
    @State private var stickyTotalDuration: Double = EditViewModel.newProjectSpan

    /// The total width of the timeline's content (px). It serves as the width of an infinite bus,
    /// which takes up its whole lane (it 'processes the whole project'). Reachable by the extensions (hit-tests).
    var contentWidth: Double { totalDuration * pixelsPerSecond }

    @State var waveformCache = WaveformCache()
    @State var lastTapInfo: (time: Date, location: CGPoint) = (.distantPast, .zero)
    @State var moveDrag: MoveDragState? = nil
    /// A drag held while the view scrolls (@see CanvasDragScrollFollow).
    @State var scrollFollow = CanvasDragScrollFollow()
    @State var resizeDrag: ResizeDragState? = nil
    @State var trimDrag: TrimDragState? = nil
    @State var fadeDrag: FadeDragState? = nil
    @State var timeSelectionDrag: TimeSelectionDragState? = nil
    /// A drag begun in the time ruler (@see handleRulerDrag).
    @State var rulerSelectionDrag: RulerSelectionDragState? = nil
    @State var volumeDrag: VolumeDragState? = nil
    @State var panDrag: PanDragState? = nil
    @State var sendDrag: SendDragState? = nil
    @State var cutDrag: CutDragState? = nil
    @State var slipDrag: SlipDragState? = nil
    @State var loopRangeDrag: LoopRangeDragState? = nil
    @State var crossfadeDrag: CrossfadeDragState? = nil
    /// A mark of the band being dragged, and a comment being dragged or cropped. Two slots of their
    /// own rather than a place among the drags above: neither moves an OBJECT, so neither has any
    /// business in the guards that ask whether the content is being edited.
    @State var markerBandDrag: MarkerBandDragState? = nil
    @State var commentDrag: CommentDragState? = nil
    /// A marker carried by an OBJECT being moved along it. A slot of its own for the same reason:
    /// it moves a mark inside the object's frame, not the object (@see ObjectMarkerDragState).
    @State var objectMarkerDrag: ObjectMarkerDragState? = nil
    /// An infinite bus being carried to another row. A slot of its own for the same reason as the
    /// two above: it moves no matter in TIME, so it has no business in the guards that ask whether
    /// the content is being edited (@see relaxStickyDuration).
    @State var infiniteBusDrag: InfiniteBusDragState? = nil
    @State var keyMonitor: Any? = nil
    @State var scrollMonitor: Any? = nil
    @State var magnifyMonitor: Any? = nil
    @State var rightClickMonitor: Any? = nil
    /// Observers of the application losing / regaining focus: they release the held keys whose
    /// release the LOCAL monitor will never see (⌘-Tab). @see registerKeyMonitor.
    @State var focusObservers: [NSObjectProtocol] = []

    enum ScrollZoomAxis { case horizontal, vertical }

    /// The axis lock of a scroll GESTURE (a trackpad's fingers AND its inertia, or a mouse wheel's
    /// run of notches): decided from its first events, then held until the next gesture. Shared by
    /// ⇧-zoom and the wheel over an automation line, so the two cannot drift apart.
    struct ScrollAxisLock {
        var axis: ScrollZoomAxis? = nil
        private var lastEventTime: TimeInterval = 0
        private var accumX: Double = 0
        private var accumY: Double = 0

        /// Call at EVERY event, first. Rearms on a new trackpad gesture (`.began`) or, failing a
        /// phase (a mouse), after a generous idle gap — NEVER on `.ended`, or the first inertia
        /// event would decide the axis again.
        mutating func observe(_ event: NSEvent, now: TimeInterval) {
            let hasPhase = !event.phase.isEmpty || !event.momentumPhase.isEmpty
            if event.phase.contains(.began) || (!hasPhase && now - lastEventTime > 0.4) {
                axis = nil
                accumX = 0
                accumY = 0
            }
            lastEventTime = now
        }

        /// The gesture's axis, nil while it is still undecided. A trackpad accumulates over a 3 pt
        /// dead zone (a diagonal swipe's first events are ambiguous); with `wheelDecidesAtOnce`, a
        /// notch wheel decides on its single event, because a dead zone would EAT notches.
        mutating func decide(_ event: NSEvent, wheelDecidesAtOnce: Bool) -> ScrollZoomAxis? {
            if let axis { return axis }
            let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
            if wheelDecidesAtOnce && !event.hasPreciseScrollingDeltas {
                guard dx != 0 || dy != 0 else { return nil }
                axis = abs(dx) >= abs(dy) ? .horizontal : .vertical
                return axis
            }
            accumX += dx
            accumY += dy
            let ax = abs(accumX), ay = abs(accumY)
            guard max(ax, ay) >= 3 else { return nil }
            axis = ax >= ay ? .horizontal : .vertical
            return axis
        }
    }

    final class HoverState {
        var position: CGPoint? = nil
        var scrollAccumulator: Float = 0
        var panScrollAccumulator: Float = 0
        var sendScrollAccumulator: Float = 0
        var automationScrollAccumulator: Float = 0
        var automationLineScrollAccumulator: Float = 0
        /// The automation line the wheel holds, frozen at its first notch and kept for as long as
        /// the notches follow each other (@see registerScrollMonitor).
        var automationLineWheel: AutomationLineWheel? = nil
        /// The timestamp of the last continuous setting notch on the wheel (volume / pan / send).
        /// Two notches less than `valueScrollUndoGap` apart belong to the same gesture and share ONE
        /// undo — otherwise the wheel was not undoable at all.
        var lastValueScrollTime: TimeInterval = 0
        var shiftZoomLock = ScrollAxisLock()
        /// The same lock for the wheel over a highlighted automation line, and whether the current
        /// gesture was identified as a VERTICAL one there (the sideways component is then swallowed).
        var automationLineWheelLock = ScrollAxisLock()
        var automationLineWheelEngaged = false

        // MARK: Vertical lane snap (D6) — the scroll monitor's own axis lock and step state,
        // independent of the ⇧-zoom fields above (a different gesture: no modifier held).
        var vSnapAxis: ScrollZoomAxis? = nil
        var vSnapAccumX: Double = 0
        var vSnapAccumY: Double = 0
        /// The trackpad step's own accumulator (D6.3): travel since the gesture began or last
        /// rearmed, reset at every `.began` — distinct from `vSnapAccumY`, which only serves the
        /// axis lock's dead zone and is never reset once the axis is decided.
        var vSnapStepAccum: Double = 0
        /// True once THIS gesture has already stepped a lane — the rest of it, momentum included,
        /// is swallowed (D6.3). Cleared on the next `.began` / idle rearm.
        var vSnapStepped: Bool = false
        /// The wheel's own running target (D6.4): consecutive notches accumulate onto it rather
        /// than onto the lane read back mid-animation, so a fast spin keeps advancing one lane per
        /// notch instead of losing notches to an animation still in flight. nil = no wheel step
        /// under way (read the framed lane instead).
        var vSnapWheelTargetLane: Int? = nil
        var vSnapLastEventTime: TimeInterval = 0
    }
    @State var hoverState = HoverState()
    /// The block aimed at under the Volume / Pan / Stem tools: the ONE piece of hover state the body
    /// reads (the partition needs the identity of the block that goes rich, and the rich blocks carry
    /// `isToolHovered`). Written only when that identity CHANGES. A plain `@State` on purpose, and not
    /// a property of `hoverStore`: it is the one trigger the body legitimately has, and routing it
    /// through Observation measured ~25 % slower per hover on a heavy project (@see TimelineHoverStore).
    @State private var toolHoveredID: UUID? = nil
    /// The rest of what the pointer is aiming at (the block's editing zone, the hovered cut position,
    /// the tooltip). A REFERENCE out of the view's state on purpose: read by leaf views alone, so a
    /// pointer moving from zone to zone re-evaluates no part of this body. @see TimelineHoverStore
    /// (internal: a double click on a fade replays the hover from TimelineView+TapHandler)
    @State var hoverStore = TimelineHoverStore()
    var laneStep: Double { blockHeight + laneGap }

    /// Cached with `items` as well (@see contentEnd).
    private var maxOccupiedLane: Int { viewModel.maxOccupiedLane }

    /// Cached by the view model with `laneEntries` (@see `EditViewModel.totalExtraLanes`): read
    /// once per `canvasHeight`, i.e. some fifteen times per pass.
    private var totalExtraLanes: Int { viewModel.totalExtraLanes }

    /// The empty rows that carry the bottom headroom, for a GIVEN row height. Real rows and not a
    /// bare padding: they get their alternating band, they can be aimed at, a range traced on them
    /// means something (@see stepTimeSelectionLanes) and a paste lands there — a strip of nothing
    /// below the last band would read as the end of the timeline rather than as room in it.
    ///
    /// Parametrised by the row height for the same reason `canvasHeight(forBlockHeight:)` is: the
    /// vertical zoom needs the canvas as it will be AFTER the change so as to bound the scroll, and
    /// a headroom counted at the old height would put that stop in the wrong place for a frame.
    private func headroomLanes(forLaneStep step: Double) -> Int {
        guard step > 0 else { return 0 }
        let room = Self.bottomHeadroomFraction * max(0, Double(viewportHeight) - rulerHeight)
        return max(0, Int((room / step).rounded(.up)))
    }

    private func visibleLanes(forLaneStep step: Double) -> Int {
        max(maxOccupiedLane + 2, minLanes) + totalExtraLanes + headroomLanes(forLaneStep: step)
    }

    private var visibleLanes: Int { visibleLanes(forLaneStep: laneStep) }

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
        let step = h + laneGap
        return max(rulerHeight + Double(visibleLanes(forLaneStep: step)) * step + 8,
                   Double(viewportHeight))
    }

    /// The sticky header (ruler + marker band), a property of its own: built inline in `body` its
    /// long initialisers were part of the one expression the type-checker gave up on.
    @ViewBuilder private var rulerHeaderLayer: some View {
    StickyToViewportTop(anchor: scrollAnchor) {
        VStack(spacing: 0) {
        TimeRulerView(
            totalDuration: totalDuration,
            pixelsPerSecond: pixelsPerSecond,
            height: MarkerBandGeometry.rulerCoreHeight,
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
        let bandLanes = viewModel.visibleMarkerLanes
        if !bandLanes.isEmpty {
            MarkerBandView(
                lanes: bandLanes,
                pixelsPerSecond: pixelsPerSecond,
                totalDuration: totalDuration,
                scrollOffsetX: cullScrollX,
                viewportWidth: cullViewportWidth,
                selected: viewModel.selectedAnnotationSet,
                renamingID: viewModel.renamingID,
                onRename: { id, name in
                    viewModel.renamingID = nil
                    // Resolved by the id the field carries, NOT through the selection: leaving the
                    // field is often what deselects, and the commit on the way out must still find
                    // its mark.
                    guard let name, !name.isEmpty,
                          case .laneMarker(let l, let m)? = viewModel.annotationSel(forMarkerID: id)
                    else { return }
                    viewModel.renameMarker(laneID: l, markerID: m, to: name)
                }
            )
        }
        }
        .overlay(alignment: .topLeading) {
            // The selection traced in the RULER, continued down the whole header. Non-hit-testing,
            // so the ruler's and the marker band's gestures are untouched.
            if let range = viewModel.rulerBandRange {
                RulerSelectionBand(range: range, pixelsPerSecond: pixelsPerSecond,
                                   top: MarkerBandGeometry.rulerCoreHeight * 0.32,
                                   bottom: rulerHeight)
            }
        }
    }
    }

    var body: some View {
        ScrollView([.horizontal, .vertical], showsIndicators: true) {
            ZStack(alignment: .topLeading) {
                // Alternating background bands: ONE Canvas that only draws the rows the viewport
                // shows (it was one SwiftUI rectangle per row, thousands of nodes on a tall
                // timeline). (The `ForEach` layers below report their element count to
                // `TimelineRegimeMeter.recordLayer`, one write per layer per pass: the number every
                // "how many SwiftUI nodes does this layer cost" question starts with.)
                laneBandsCanvas(laneRows: visibleLanes)

                // The background of the INNER lanes of an expanded group (nesting included): 'those rows
                // are in this group'. Tinted with the group's colour (custom, otherwise the stem's),
                // bounded at the top and bottom by a border so that the group's span reads at a glance.
                // It grows stronger when the editing point (the caret, the time selection, the selected
                // objects) falls inside it → 'you ARE in this group'. The blocks themselves are never
                // recoloured: only the background speaks.
                // A nested group stacks its band on the parent's → the depth is seen.
                let focusedLanes = focusedDisplayLanes
                // Every per-entry layer below iterates a PRE-FILTERED list, never `laneEntries`
                // with an `if` inside: a `ForEach` builds and diffs one node per element even when
                // its content is empty, so eight layers over a few hundred objects were thousands
                // of nodes re-diffed and re-laid out on every change of `items` — most of the
                // interface's freeze after a cut during playback. The filters are the layers' own
                // conditions, moved out; the content is unchanged.
                let visibleEntries = viewModel.laneEntries.filter { isEntryVisible($0) }
                let inlineGroupEntries = viewModel.laneEntries.filter { $0.item.showsChildrenInline }
                // What every consumer of an open group's band needs, computed ONCE per pass: the
                // band's rows, its colour, whether the editing point is inside it. The band layer,
                // its rise and the automation bezel's fill all read this one list — each used to
                // rebuild it per open group (`focusedDisplayLanes` and `occupiedLanes`' sort, both
                // O(objects), once per group).
                let inlineBands = inlineGroupBands(inlineGroupEntries, focused: focusedLanes)
                // The bands of the open groups: ONE Canvas (the 'selected clips' work's A/B switch,
                // in Debug builds, puts the old SwiftUI layers back — @see `DebugRenderSwitches`).
                #if DEBUG
                if forceRichBands {
                    richGroupBands(inlineGroupEntries, focusedLanes: focusedLanes)
                } else {
                    groupBandsCanvas(inlineBands)
                }
                #else
                groupBandsCanvas(inlineBands)
                #endif

                // A sub-lane background for MIDI clips whose piano roll is open: the same principle
                // as the expanded groups' band (it clarifies the MIDI clip's inside), more discreetly
                // — the piano roll covers the band anyway.
                // ONE Canvas, from the cached list of the open objects.
                pianoRollTintsCanvas()

                // The '+' of each open group's drop lane is drawn by the bands' Canvas above (the
                // piano-roll tint just before touches only a MIDI clip's own sub-lanes, never a
                // group's drop lane, so the order between the two is not visible). Only the Debug
                // A/B switch brings the old SwiftUI layer back, at its old place.
                #if DEBUG
                if forceRichBands {
                    richGroupPluses(inlineGroupEntries)
                }
                #endif

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

                // The markers the objects carry, and the comments laid on the surface. Both above the
                // blocks — a mark one cannot see names nothing — and both below the sticky header,
                // which stays the topmost thing in the canvas.
                ObjectMarkersOverlay(
                    entries: viewModel.laneEntries,
                    pixelsPerSecond: pixelsPerSecond,
                    rulerHeight: rulerHeight,
                    laneStep: laneStep,
                    blockHeight: blockHeight,
                    selected: viewModel.selectedAnnotationSet,
                    renamingID: viewModel.renamingID,
                    scrollOffsetX: cullScrollX,
                    viewportWidth: cullViewportWidth,
                    previews: objectMarkerPreviews,
                    width: totalDuration * pixelsPerSecond,
                    height: canvasHeight,
                    onRename: { id, name in
                        viewModel.renamingID = nil
                        guard let name, !name.isEmpty,
                              case .objectMarker(let o, let m)? = viewModel.annotationSel(forMarkerID: id)
                        else { return }
                        viewModel.renameObjectMarker(objectID: o, markerID: m, to: name)
                    }
                )
                .zIndex(2.66)

                // What a third-party script shows over the objects (words, zones). Above the marks,
                // below the comments, and never a hit: @see ScriptOverlayLayer
                // Always mounted, on purpose: reading `overlays` HERE (an `if` on it) would make every
                // rewrite of a script's zones re-evaluate the whole timeline. The layer reads it itself.
                do {
                    ScriptOverlayLayer(
                        store: viewModel.scriptOverlays,
                        entries: viewModel.laneEntries,
                        pixelsPerSecond: pixelsPerSecond,
                        rulerHeight: rulerHeight,
                        laneStep: laneStep,
                        blockHeight: blockHeight,
                        scrollOffsetX: cullScrollX,
                        viewportWidth: cullViewportWidth,
                        previews: objectMarkerPreviews,
                        width: totalDuration * pixelsPerSecond,
                        height: canvasHeight
                    )
                    .allowsHitTesting(false)
                    .zIndex(2.665)
                }

                if !viewModel.comments.isEmpty {
                    CommentsOverlay(
                        comments: viewModel.visibleComments,
                        pixelsPerSecond: pixelsPerSecond,
                        rulerHeight: rulerHeight,
                        laneStep: laneStep,
                        blockHeight: blockHeight,
                        selected: viewModel.selectedAnnotationSet,
                        editingID: viewModel.renamingID,
                        previewOffsets: commentPreviewOffsets,
                        onCommit: { id, text in
                            viewModel.renamingID = nil
                            guard let text else { return }
                            viewModel.setCommentText(id: id, text)
                        }
                    )
                    .zIndex(2.67)
                }

                // A sticky header: it follows the vertical scroll so as to stay at the top of the viewport,
                // above all the content (blocks, piano rolls). The horizontal scroll is still handled
                // internally (the graduations follow the content).
                rulerHeaderLayer
                .zIndex(4)

                // The snap guide. Drawn for the WHOLE of a move / crop / trim and not only when
                // it has something to say: what one wants to know while pulling an edge is
                // precisely whether one is aligned yet, and a line that only appears once the
                // answer is yes cannot be asked the question. The colour carries the answer —
                // YELLOW when the edge has landed on a mark (another object's edge, a marker, a
                // region's bound), GREY while it is merely following the hand or the grid.
                //
                // A MARK is in that list too, and it took a reading on screen to see why it had to
                // be: a marker and a region are placed against the same material an object's edge
                // is placed against, and a guide one gets for pulling an edge but not for pulling
                // the mark that names the same instant is a guide with a hole in it. The band's
                // drag and the comments' therefore light it exactly as a move does — and a mark
                // dragged is left OUT of its own targets, @see `EditViewModel.snapTargets`.
                let dragActive = moveDrag != nil || resizeDrag != nil || trimDrag != nil
                             || markerBandDrag != nil || commentDrag != nil
                             || objectMarkerDrag != nil
                //
                // Dashed while it is grey, solid once it is yellow. The width alone would not have
                // been enough to tell it from the selection cursor, which is grey too and sits one
                // pixel wider: two grey hairlines on the same canvas, one of them moving under the
                // hand, is a reading nobody should have to make.
                if let guide = viewModel.snapGuide, dragActive {
                    SnapGuideRule()
                        .stroke(guide.onTarget ? Color.yellow.opacity(0.75)
                                               : Color.gray.opacity(0.55),
                                style: StrokeStyle(lineWidth: 1,
                                                   dash: guide.onTarget ? [] : [3, 3]))
                        .frame(width: 1, height: canvasHeight - rulerHeight)
                        .offset(x: guide.time * pixelsPerSecond - 0.5, y: rulerHeight)
                        .allowsHitTesting(false)
                        .zIndex(3)
                }

                // The INSERTION line: a block let go while it straddles two rows goes BETWEEN them
                // (@see LaneInsertion), and the line is where. On the timeline itself it is full
                // width; inside a group, only over the group's own span — which is what says WHICH
                // group the objects will enter.
                if let ins = moveDrag?.insertion {
                    insertionLine(for: ins)
                        .allowsHitTesting(false)
                        .zIndex(3.05)
                }

                // While paused (⇧space), the playhead stays where playback stopped — that is where it
                // will start again — but in a muted red to say 'stopped'.
                if isPlaying || isPaused {
                    PlayheadLine(position: playheadPosition, pixelsPerSecond: pixelsPerSecond,
                                 isPlaying: isPlaying, height: canvasHeight - rulerHeight,
                                 top: rulerHeight)
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
                // of the time selection (on each of its lanes). ONE Canvas, the visible rows only.
                caretsCanvas()
                    .zIndex(3.1)

                // Blocks (the root plus the descendants of expanded groups).
                // itemBlock branches on kind → a clip = SoundBlockView, a group = GroupBlockView
                // (a header plus a chevron, a nested subgroup included).
                // Blocks (the root plus the descendants of expanded groups). Hit-test/hover/gestures
                // are resolved geometrically by the canvas on laneEntries (pure presentation).
                // Virtualisation: we only render the blocks intersecting the viewport.
                //
                // A PERF SPLIT: the visible 'ordinary' clips are drawn in ONE Canvas (1 view node
                // instead of N×layers → the cost of scrolling was the number of SwiftUI nodes, not
                // the drawing). The rich blocks (selection, tools, renaming, a consolidated object, an aux,
                // MIDI, groups, a drag) keep their SwiftUI view.
                // ONE pass splits the visible entries between the two regimes: `clipRichReason`
                // asks `spillPlan` and the preview helpers, so evaluating it once per entry per
                // list (it was twice) was paid in proportion to what is SHOWN, twice over.
                // The selection is read HERE, once, and handed to the Canvas: it paints a selected
                // clip differently, so a change of selection must re-evaluate this layer — and
                // the Canvas's renderer closure is not a place to count on tracking it.
                let selectedIDs = viewModel.selectedIDs
                // What the active tool needs the partition to know (the aimed block, the Send tool's
                // rows — computed ONCE here for every block shown —, the exact-scroll test): read
                // once per pass, and only under a tool.
                let tools = toolPartitionContext(visibleEntries, selectedIDs: selectedIDs)
                let partition = partitionVisibleBlocks(visibleEntries, tools: tools)
                let plainVisible = partition.plain
                let richVisible = partition.rich
                // The groups the Canvas draws, resolved HERE (their name, colour, mute, missing
                // flag…) and not in its renderer closure: what their look depends on must be read
                // where a change re-evaluates this layer.
                let canvasGroups = canvasGroups(for: partition.plainGroups, selectedIDs: selectedIDs,
                                                toolOverlays: partition.toolOverlays,
                                                previews: partition.previews)
                let _ = TimelineRegimeMeter.recordPass(
                    clipsCanvas: plainVisible.count,
                    clipsRich: richVisible.count - partition.richGroups,
                    groupsCanvas: canvasGroups.count, groupsRich: partition.richGroups,
                    groupBandsCanvas: forceRichBands ? 0 : inlineBands.count,
                    groupBandsRich: forceRichBands ? inlineBands.count : 0,
                    richReasons: partition.reasons)
                let _ = ensureWaveformsLoaded(plainVisible, groups: canvasGroups)
                // The blocks, in two draws of ONE function (@see StickyLabel): the notch-driven
                // Canvas (everything, but the names that depend on the exact scroll) and, above
                // it, the sticky pass that draws ONLY those names, anchored on the exact viewport
                // edge. A scroll redraws the second one and not the first.
                plainBlocksCanvas(plainVisible, groups: canvasGroups, selectedIDs: selectedIDs,
                                  rows: cullRows,
                                  secPerBeat: 60.0 / viewModel.tempo,
                                  consolidated: partition.consolidated,
                                  toolOverlays: partition.toolOverlays,
                                  previews: partition.previews,
                                  hidesClipMuteVeil: tools.tool == .volume,
                                  sticky: StickyLabelPass(exactScrollX: nil, cullScrollX: cullScrollX,
                                                          step: Self.cullStepPx))
                StickyScrollReader(anchor: scrollAnchor) { exactX in
                    plainBlocksCanvas(plainVisible, groups: canvasGroups, selectedIDs: selectedIDs,
                                      rows: cullRows,
                                      secPerBeat: 60.0 / viewModel.tempo,
                                      consolidated: partition.consolidated,
                                      toolOverlays: partition.toolOverlays,
                                      previews: partition.previews,
                                      hidesClipMuteVeil: tools.tool == .volume,
                                      sticky: StickyLabelPass(exactScrollX: exactX, cullScrollX: cullScrollX,
                                                              step: Self.cullStepPx))
                }
                let _ = TimelineRegimeMeter.recordLayer("rich_blocks", elements: richVisible.count)
                ForEach(richVisible) { entry in
                    itemBlock(for: entry.item, displayLane: entry.displayLane,
                              sendRows: tools.sendRows)
                        .allowsHitTesting(false)
                }

                // Piano rolls unfolded inline under the open MIDI clips. Interactive
                // (allowsHitTesting), unlike the blocks. Positioned on the band of sub-lanes
                // reserved by expandedSpan.
                let pianoRolls = visibleEntries.filter { $0.item.showsPianoRollInline }
                let _ = TimelineRegimeMeter.recordLayer("piano_rolls", elements: pianoRolls.count)
                ForEach(pianoRolls) { entry in
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

                // AUTOMATION bands unfolded inline under the open objects. The same overlay mechanism
                // as the piano rolls, positioned on the band of sub-lanes reserved by expandedSpan,
                // and like them they own their clicks: the canvas steps aside over them
                // (@see openAutomationBandContains).
                // Pre-filtered on `automationBandRect`'s own first condition (an open band): a
                // ForEach over every visible entry cost one node per object for a layer that is
                // empty almost everywhere.
                let openAutomationBands = visibleEntries.filter { $0.item.automationOpen }
                let _ = TimelineRegimeMeter.recordLayer("automation_bands", elements: openAutomationBands.count)
                ForEach(openAutomationBands) { entry in
                    if let r = automationBandRect(for: entry) {
                        AutomationBandView(
                            viewModel: viewModel,
                            object: entry.item,
                            bandTopLane: entry.displayLane + 1,
                            pixelsPerSecond: pixelsPerSecond,
                            bandWidth: r.width,
                            laneStep: laneStep,
                            rowHeight: blockHeight,
                            bandStartTime: r.minX / pixelsPerSecond,
                            onSeekToTime: { t in
                                // It no longer takes the caret away, and that is the change a
                                // curve's row being a DISPLAY LANE brings: a click here is a click
                                // on a lane like any other, so it leaves a point of insertion
                                // behind it, and the arrows and ⌘V have somewhere to start from.
                                // The band lays that caret itself, just before calling this
                                // (@see AutomationBandView.handleTap); clearing it here would undo
                                // the very gesture that asked for it. A RANGE has no caret, and
                                // the branches that make one drop it on their own.
                                let st = viewModel.snapTime(max(0, t))
                                if !isPlaying { viewModel.engine?.seek(to: st) }
                                onMoveCursor(st)
                            }
                        )
                        .offset(x: r.minX, y: r.minY)
                        .zIndex(2.56)
                    }
                }

                // The crossfades, drawn ONCE above the blocks. A zone belongs to two objects at
                // the same time — it is precisely the span they share — so neither block can draw
                // it: whatever each of them puts in there, the upper one hides the lower. Above
                // the blocks (1) and below the cut's lines (2.6), like the rest of what the canvas
                // says about a gesture rather than about an object. @see CrossfadeVeilDrawing.
                crossfadeCanvas()
                    .zIndex(2.55)

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
                    // ⌥ = ripple: the band says what the gesture really takes — the lanes of the
                    // objects it aims at over the hole's span, and not only the object one is
                    // holding. Struck through like the plain cut, plus the edge that shows where
                    // everything will come back.
                    ForEach(Array(cutDragRippleBands.enumerated()), id: \.offset) { _, band in
                        Rectangle()
                            .fill(Color.red.opacity(0.22))
                            .overlay(alignment: .leading) {
                                Rectangle().fill(Color.yellow.opacity(0.9)).frame(width: 1.5)
                            }
                            .frame(width: band.width, height: band.height)
                            .offset(x: band.minX, y: band.minY)
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

                // The position itself is read by the LEAF (`CutHoverLine`, @see TimelineHoverStore): it
                // changes at every snapped step of the pointer, and must not re-evaluate this body.
                if viewModel.activeTool == .toolCut, cutDrag == nil {
                    CutHoverLine(store: hoverStore, viewModel: viewModel,
                                 pixelsPerSecond: pixelsPerSecond, rulerHeight: rulerHeight,
                                 laneStep: laneStep, blockHeight: blockHeight)
                        .allowsHitTesting(false)
                        .zIndex(2.6)  // above the selected blocks (1) and the masks (0)
                }

                // The hovered block's editing zones (the selection tool): thin separations plus a
                // discreet veil over the zone that would answer the click. Hidden during a gesture — once
                // the drag is engaged, the gesture's preview already says what is happening.
                // The hovered zone is read by the LEAF (`EditZoneVeilLayer`, @see TimelineHoverStore),
                // not here: it changes with every zone the pointer crosses.
                if viewModel.activeTool == .toolSelection,
                   !dragActive, fadeDrag == nil, timeSelectionDrag == nil {
                    // UNDER the 'objects / automations' hem (2.57): the veil darkens the block's
                    // clickable zone, not the switch laid on it — which has its own material and its
                    // own hover state (@see updateCursor, which puts the veil out as soon as one
                    // comes into the hem).
                    EditZoneVeilLayer(store: hoverStore)
                        .allowsHitTesting(false)
                        .zIndex(2.565)
                }

                // The out-of-range masks of OPEN objects (the zones before/after the played range, inside
                // the unfolded band of sub-lanes). A SHARED mechanism driven by `expandedSpan`: an
                // expanded group (the band = the children) AND an open MIDI clip (the band = the piano
                // roll). It greys the outside of the content out so as to focus on the inside. See SoundObject.expandedSpan.
                // An infinite bus: no range any more → no out-of-range. Its inside is open over
                // the whole timeline, so no grey mask.
                // ONE Canvas, ABOVE the blocks' own (declared after them, no zIndex: the same place the
                // old per-object rectangles had), drawing only the masks that meet the viewport.
                rangeMasksCanvas()

                // The 'objects / automations' hem of the objects that have both to show (a group, a MIDI
                // clip): INSIDE the block, risen from the lower edge — its belonging is beyond question,
                // nested too. Pure rendering (like the rest of the canvas's controls); the click is
                // resolved geometrically by the tap handler.
                // Pre-filtered on `automationBezel`'s own first conditions (a selector to show, a
                // content to choose from): only groups and MIDI clips ever get here.
                let automationBezels = visibleEntries.filter { $0.expandedSpan > 0 && viewModel.hasAutomationSelector($0.item) }
                let _ = TimelineRegimeMeter.recordLayer("automation_bezels", elements: automationBezels.count)
                ForEach(automationBezels) { entry in
                    if let b = automationBezel(for: entry) {
                        let tint  = entry.item.customColor ?? viewModel.stemColor(for: entry.item.id)
                        let paint = interiorPaint(for: entry, bands: inlineBands)
                        AutomationBezelView(placement: b, fill: paint, tint: tint,
                                            state: AutomationBezel.displayState(for: entry.item, expandedSpan: entry.expandedSpan))
                            .zIndex(2.57)
                        // No 'weld' across the gutter under the plateau: it had the PLATEAU's width,
                        // not the block's, and so read as an added shape spilling out of the hem
                        // towards the lanes below — the opposite of what it meant. The hem stops at
                        // the block's lower edge; the gutter stays empty, as under any other object.
                    }
                }

                // Alt+drag ghosts (@see `altGhostsLayer`).
                altGhostsLayer(selectedIDs: selectedIDs)

                // TimeSelection overlay: ONE Canvas, bounded to the viewport (a rectangle per lane of
                // the selection, the visible rows and columns only).
                timeSelectionCanvas()
                    .zIndex(1.5)

                // Plugin LINK overlay: a star from the clip whose editor is open towards the other
                // clips of the group, plus highlighting. Visible ONLY with an editor open.
                // The targets are resolved HERE, in ONE walk of the entries for every id involved
                // (it was a scan of all the entries per member, twice).
                if let info = viewModel.linkOverlayInfo, let plan = pluginLinkPlan(info) {
                    Canvas { ctx, _ in
                        LinkOverlay.drawStar(in: ctx, source: plan.source, members: plan.members,
                                             color: info.color)
                    }
                    .frame(width: totalDuration * pixelsPerSecond, height: canvasHeight, alignment: .topLeading)
                    .allowsHitTesting(false)
                    .zIndex(2.7)
                }

                // Consolidated object LINK overlay: PURPLE lines between the instances of one definition
                // (those that are visible). Contextual — like the plugin link, we only show it for the
                // selection. The selected placements are grouped by definition:
                //
                //  • one selected → a star from the source → the other instances (as before);
                //  • several selected → ONE single chain joining every instance (instead of a star
                //    from each to all the others, unreadable in a multiple selection).
                //
                // Planned HERE, in a single walk of the entries (@see consolidateLinkPlan), and only
                // when the selection holds a consolidated object at all.
                let consolidateLinks = consolidateLinkPlan()
                if !consolidateLinks.isEmpty {
                    Canvas { ctx, _ in
                        for link in consolidateLinks {
                            switch link {
                            case .star(let source, let members):
                                LinkOverlay.drawStar(in: ctx, source: source, members: members,
                                                     color: LinkColor.consolidate)
                            case .chain(let nodes):
                                LinkOverlay.drawChain(in: ctx, nodes: nodes, color: LinkColor.consolidate)
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
                    Canvas { ctx, _ in drawSendLinks(&ctx) }
                    .frame(width: totalDuration * pixelsPerSecond, height: canvasHeight, alignment: .topLeading)
                    .allowsHitTesting(false)
                    .zIndex(2.7)
                }

                // The row an infinite bus is being carried to used to be drawn HERE, as an empty
                // rectangle, while the band itself stayed behind at its own row. It is the band
                // that travels now — the gesture reads like every other move of the canvas
                // (@see infiniteBusPreviewDY), and the refusal is said on the band itself.

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
                    // ABOVE the carried card, not beside the cursor: the drag image is drawn by the
                    // system over every window, so a badge under it is simply hidden — at +18/-18 it
                    // sat inside the card and was never seen.
                    LinkBadge(color: LinkColor.plugin)
                        .position(x: loc.x, y: loc.y - PluginDragPreview.height / 2 - 14)
                        .allowsHitTesting(false)
                        .zIndex(3)
                }
            }
            .frame(width: totalDuration * pixelsPerSecond, height: canvasHeight, alignment: .topLeading)
            .contentShape(Rectangle())
            .timelineHoverHelp(hoverStore)
            .onTapGesture(coordinateSpace: .local) { handleCanvasTap(at: $0) }
            .simultaneousGesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .local)
                    .onChanged { handleCanvasDrag(CanvasDrag($0), phase: .changed) }
                    .onEnded   { handleCanvasDrag(CanvasDrag($0), phase: .ended)   }
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
                        if toolHoveredID != nil { toolHoveredID = nil }
                        hoverStore.clearAll()
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
                            if active { hoverStore.clearZoneAndCut() }
                        },
                        pluginOutcome: { loc, flags in
                            guard let payload = PluginDragSession.shared.current else { return nil }
                            guard let host = objectID(at: loc) else { return .refuse("no object under the cursor") }
                            return viewModel.pluginDropOutcome(payload, toHost: host, at: .hostEnd, flags: flags)
                        }))
        }
        .scrollPosition($scrollPosition)
        // The mirror in the view-model (`viewScrollX/Y`, @ObservationIgnored) serves only to save
        // the visible area with the project — it invalidates no view.
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in
            scrollAnchor.x = x
            viewModel.viewScrollX = Double(x)
            scrollFollow.offset.x = x
            followScrollDuringDrag()
            refreshCullWindow()     // it only moves once per notch → it almost never invalidates
            relaxStickyDuration()   // back inside the content → the canvas can shrink
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
            scrollAnchor.y = y
            viewModel.viewScrollY = Double(y)
            scrollFollow.offset.y = y
            followScrollDuringDrag()
            refreshCullWindow()     // the vertical notch: same contract as the horizontal one
        }
        // D7 — the safety net: anything else that can leave `scrollY` between two lanes while
        // snapped (the scroller dragged by hand, a drag-follow scroll, a stray gesture) is caught
        // here, on the scroll coming to REST.
        .onScrollPhaseChange { _, newPhase in
            if newPhase == .idle { reframeIfOffGridOnIdle() }
        }
        .background(GeometryReader { geo in
            Color(nsColor: .controlBackgroundColor)
                .onAppear {
                    viewportWidth = geo.size.width
                    viewportHeight = geo.size.height
                    lastAvailableLaneHeight = availableLaneHeight
                    viewportMeasured = true
                    enforceVerticalZoomBounds()
                }
                .onChange(of: geo.size.width)  { viewportWidth  = $0 }
                .onChange(of: geo.size.height) { _, h in
                    viewportHeight = h
                    adjustForAvailableHeightChange()
                }
        })
        // The rows' names and the button that governs them: PINNED to the viewport, in the same
        // overlay layer as the tool indicator. A row's name is its identity, and an identity that
        // scrolls off with the content stops naming anything. @see MarkerLaneHeaderView
        .overlay(alignment: .topLeading) { markerLaneHeaders }
        .overlay(alignment: .bottomTrailing) { toolIndicator }
        // The cheat sheet and the HUD share the bottom of the view, stacked: the shortcut list reads
        // above the status bands, without hiding the centre of the timeline.
        .overlay(alignment: .bottom) {
            VStack(spacing: 6) {
                cheatsheetOverlay
                fileDropHintOverlay
                pluginDropHUD
                moveDragHUD
                fadeDragHUD
                crossfadeDragHUD
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
            waveformCache.setWaveformsDirectory(viewModel.waveformsFolder)
            // What the disk cache may write into that folder: only a file the CURRENT project
            // still names (@see WaveformCache.referencedPaths, WaveformCache.writeTarget) — set
            // once here, read on every flush and every completed compute from then on.
            waveformCache.referencedPaths = { [weak viewModel] in viewModel?.referencedAudioPaths ?? [] }
            // Dragging on the zoom pills: the same session as the wheel, simply held open by the
            // gesture (no inactivity window to respect).
            viewModel.beginHorizontalZoomDrag = {
                openHorizontalZoomSession()
                hZoomHeld = true
            }
            viewModel.endHorizontalZoomDrag = { hZoomHeld = false }
            viewModel.applyHorizontalZoom = { newPPS in applyZoom(newPPS) }
            // The one door `waveform.preload` calls through: a script has no Canvas to trigger
            // `ensureWaveformsLoaded`, and this closure is the only other way in.
            viewModel.preloadWaveforms = { paths in for p in paths { waveformCache.load(filePath: p) } }
            viewModel.beginVerticalZoomDrag = {
                openVerticalZoomSession()
                vZoomHeld = true
            }
            viewModel.endVerticalZoomDrag = {
                vZoomHeld = false
                // D8 — the pill drag ends its OWN session explicitly: no debounce needed, frame
                // now if the snap is active. D12: the same held anchor the drag zoomed about.
                vZoomSettleWork?.cancel()
                vZoomSettleWork = nil
                vSnapPendingFraming = false
                if verticalSnapActive {
                    let lane = vZoomAnchorLaneCentre.map { Int($0.rounded()) } ?? currentFramedLane()
                    frameLane(lane, animated: true)
                }
            }
            viewModel.applyVerticalZoom = { newH in applyVerticalZoom(newH) }
            viewModel.verticalSnapProbe = { verticalSnapProbeSnapshot() }
            viewModel.zoomBoundsProbe = { (min: minZoom, max: maxZoom) }
            viewModel.hoverProbe = {
                TimelineHoverProbe(position: hoverState.position,
                                   toolHoveredID: toolHoveredID,
                                   editZoneID: hoverStore.editZoneHover?.id,
                                   editZone: hoverStore.editZoneHover?.zone,
                                   cutHoverID: hoverStore.cutHover?.id,
                                   cutHoverLocalX: hoverStore.cutHover?.localX,
                                   helpText: hoverStore.toolZoneHelpText)
            }
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
            // The cut by dragging rereads ⌥ on every frame too, and a frame only comes at the
            // next pixel: without this, arming the ripple without moving changed nothing on screen.
            cutDrag?.ripple = held
            guard moveDrag?.timeSelectionAnchor == nil else { return }
            moveDrag?.isAltCopy = held
            // The insertion between two lanes depends on ⌥ (a copy pushes its originals too, and an
            // ⌥ copy from the root never enters a group): the plan shown follows the key without
            // waiting for the next pixel. The release asks again anyway.
            if var md = moveDrag, let probe = md.insertionProbe, probe.alt != held {
                md.insertion = viewModel.laneInsertionPlan(
                    row: probe.row, ids: md.ids, anchors: md.anchors,
                    sourceGroupID: md.sourceGroupID, isAltCopy: held)
                md.insertionProbe = (probe.row, held)
                moveDrag = md
            }
        }
        .onChange(of: selectionCursor) { currentSelectionCursor = $0 }
        // D2's catch-all: ANY door that writes `blockHeight` raw is re-clamped here.
        .onChange(of: viewModel.blockHeight) { enforceVerticalZoomBounds() }
        // A marker row shown or hidden moves the header, hence `availableLaneHeight` — D3's ratio
        // rule applies here exactly as it does to a window resize.
        .onChange(of: rulerHeight) { adjustForAvailableHeightChange() }
        // The content's length: followed at once when it grows, shrunk only when
        // that moves nothing on screen (see syncStickyDuration).
        .onChange(of: contentDuration, initial: true) { syncStickyDuration() }
        .onChange(of: viewModel.pixelsPerSecond) { relaxStickyDuration() }
        // The catch-all for the HORIZONTAL zoom, on the model of `enforceVerticalZoomBounds`: any
        // door that writes `pixelsPerSecond` raw (`view.set`, a project load, a tab restore, the
        // pill's nil-closure fallback) lands on the same bounds, with no second implementation.
        // Idempotent — the corrected write comes back here once and finds nothing to do.
        .onChange(of: viewModel.pixelsPerSecond) { enforceHorizontalZoomBounds() }
        // A loaded project: the zoom is already applied (by the view-model), and the scroll is what
        // is left. Deferred by one runloop turn so that the content has its final size (otherwise
        // the scroll is clamped on a width that is still empty).
        .onChange(of: viewModel.pendingViewRestore) { _, vp in
            guard let vp else { return }
            DispatchQueue.main.async {
                // D10 — clamp (D2) THEN apply the scroll: the window may not be the size it was
                // saved at. If the snap is active afterwards, the saved scrollY is replaced by the
                // nearest lane's own target — a project saved framed on lane k reopens framed on
                // lane k, not on whatever pixel the old window happened to leave it at.
                enforceVerticalZoomBounds()
                if verticalSnapActive {
                    let maxY = max(0, canvasHeight - Double(viewportHeight))
                    let nearest = VerticalLaneSnap.nearestLane(scrollY: vp.scrollY, blockHeight: blockHeight,
                                                               laneStep: laneStep, available: availableLaneHeight,
                                                               maxScrollY: maxY, laneCount: visibleLanes)
                    let target = VerticalLaneSnap.scrollY(forLane: nearest, blockHeight: blockHeight,
                                                          laneStep: laneStep, available: availableLaneHeight,
                                                          maxScrollY: maxY)
                    scrollPosition.scrollTo(x: CGFloat(vp.scrollX), y: CGFloat(target))
                } else {
                    scrollPosition.scrollTo(x: CGFloat(vp.scrollX), y: CGFloat(vp.scrollY))
                }
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
        // The row ↑ / ↓ has just walked the caret (or the time selection) onto: bring it back into
        // the window. Same protocol again — applied, then set back to nil. No deferral here: the
        // canvas keeps its size, only the scroll moves.
        .onChange(of: viewModel.pendingLaneReveal) { _, lane in
            guard let lane else { return }
            revealDisplayLane(lane)
            DispatchQueue.main.async { viewModel.pendingLaneReveal = nil }
        }
        // The sound list selected something and asks the view to show it (@see
        // EditViewModel.revealInTimeline, TimelineReveal). Same protocol once more — applied, then
        // set back to nil, unless a newer request has replaced it in the meantime.
        .onChange(of: viewModel.timelineRevealRequest) { _, req in
            guard let req else { return }
            revealObjects(req)
            DispatchQueue.main.async {
                if viewModel.timelineRevealRequest == req { viewModel.timelineRevealRequest = nil }
            }
        }
        // The project folder changes (Save As, opening, a new version) → retarget the
        // disk cache; becoming non-nil flushes the peaks already computed.
        .onChange(of: viewModel.projectURL) {
            waveformCache.setWaveformsDirectory(viewModel.waveformsFolder)
        }
        // A new project / an opening: the displayed length starts again from the real content,
        // without waiting for `relaxStickyDuration`'s conditions — they protect an editing GESTURE
        // under way, a notion that means nothing when all the content has just been replaced. The
        // scroll is reclamped straight after, otherwise the ScrollView stays beyond the new canvas
        // and shows emptiness outside the content (which the slightest zoom made disappear).
        .onChange(of: viewModel.projectLoadToken) { resetStickyDuration() }
        // A new project: 60 s long and 60 s on screen, from zero. The old project's zoom would
        // otherwise survive — a scale made to fit 2:30 leaves the one-minute canvas short of the
        // window, the ruler stopping part-way across.
        .onChange(of: viewModel.pendingNewProjectFrame) { _, pending in
            guard pending else { return }
            resetStickyDuration()
            viewModel.pixelsPerSecond = clampZoom(Double(viewportWidth) / EditViewModel.newProjectSpan)
            DispatchQueue.main.async {
                scrollTo(x: 0, y: 0)
                viewModel.pendingNewProjectFrame = false
            }
        }
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
            hoverStore.clearZoneAndCut()
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
            hoverStore.clearZoneAndCut()
            return
        }
        // The marker band: it has its own gestures, and nothing under it is reachable (it is a
        // sticky header laid over the lanes). Without this the blocks HIDDEN beneath it would light
        // their editing zones up under a hand that can never reach them.
        if markerBandContains(pos) {
            // A region's two ends crop and its body moves, so the cursor says which — the same
            // vocabulary a clip and a comment already speak. A point marker has only a body.
            let zone = markerBandZone(at: pos)
            TimelineCursorKeeper.set(zone == nil ? NSCursor.arrow
                                     : zone!.part == .move ? NSCursor.openHand
                                                           : NSCursor.resizeLeftRight)
            hoverStore.clearZoneAndCut()
            return
        }
        // A COMMENT: the ends crop, the body moves — the cursor says which, exactly as it does on a
        // clip. Asked before the blocks, like the click and the drag.
        if viewModel.activeTool == .toolSelection, let z = commentZone(at: pos) {
            TimelineCursorKeeper.set(z.part == .move ? NSCursor.openHand : NSCursor.resizeLeftRight)
            hoverStore.clearZoneAndCut()
            return
        }
        // A marker carried by an OBJECT: the open hand, the one word the band's marks and a comment
        // already speak for 'this can be taken hold of'. It has no crop cursor — a mark on an
        // object moves along it and nothing else. Same order as the click and the drag.
        if viewModel.activeTool == .toolSelection, objectMarkerHit(at: pos) != nil {
            TimelineCursorKeeper.set(NSCursor.openHand)
            hoverStore.clearZoneAndCut()
            return
        }
        // A CROSSFADE zone: the same priority as in the drag, and for the same reason — the
        // surfaces the per-block carve-up would name here are the two fade triangles the zone is
        // made of, and naming one of them would promise a gesture on one side alone. The cursor
        // says WHICH of the zone's four parts the hand is on: ✕ for the pair of curves, the open
        // hand for the body, and one fade cursor per side (@see crossfadeCursor).
        if viewModel.activeTool == .toolSelection, let c = crossfadeCursor(at: pos) {
            TimelineCursorKeeper.set(c)
            hoverStore.clearZoneAndCut()
            return
        }
        // The editing zones are only revealed under the selection tool.
        if viewModel.activeTool != .toolSelection { hoverStore.setEditZoneHover(nil) }
        switch viewModel.activeTool {
        case .toolCut:
            guard let entry = blockEntry(at: pos)
            else { TimelineCursorKeeper.set(NSCursor.arrow); hoverStore.setCutHover(nil); return }
            // Uniform handling top-level / children (depth immaterial).
            let bx     = entry.absStart * pixelsPerSecond
            let bw     = max(entry.item.duration * pixelsPerSecond, 2)
            let localX = pos.x - bx
            let canCut = localX >= 10 && localX <= bw - 10
            TimelineCursorKeeper.set(canCut ? NSCursor.crosshair : NSCursor.operationNotAllowed)
            // A line set on the snap (the same computation as handleCutTap)
            let snappedX = viewModel.snappedTimePure(max(0, pos.x / pixelsPerSecond)) * pixelsPerSecond - bx
            hoverStore.setCutHover(canCut ? TimelineHoverStore.CutHover(id: entry.item.id, localX: snappedX) : nil)
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
            // An INFINITE BUS first, and unconditionally: its band has no edge to take hold of and
            // no start to slide, only a row to change (@see InfiniteBusDragState). Asked before
            // `selectionZoneHover`, which knows nothing of infinites and was carving the bus's
            // stored window up into trim / fade / move zones — promising, over that stretch of the
            // band, three gestures the drag never performs.
            //
            // The OPEN HAND, the same one a block's body gets, and not the ↕ that was here first.
            // The ↕ named the one axis the gesture has, which is true and is not what the hand asks
            // when it arrives: it asks whether this can be taken hold of at all. A band that
            // answered with a resize cursor read as an edge one could pull. The axis needs no
            // announcing — the band only ever goes up and down, and one pixel of travel says so.
            // Never `dragCopy` under ⌥, unlike a block: there is no copy of a bus at the end of
            // that gesture, and a cursor promising one would be lying.
            if infiniteBusBandHit(at: pos) != nil {
                TimelineCursorKeeper.set(NSCursor.openHand)
                hoverStore.setEditZoneHover(nil)
                return
            }
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
                hoverStore.setEditZoneHover(nil)
                return
            }
            hoverStore.setEditZoneHover(hover)
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
            let overItem = blockEntry(at: pos) != nil
            TimelineCursorKeeper.set(overItem ? NSCursor.pointingHand : NSCursor.arrow)
        }
    }

    // MARK: - Editing zones (the selection tool)

    /// The 'the edge cannot move any more' tolerance: half a pixel at the current scale, with a
    /// floor in seconds so as to stay stable at extreme zooms.
    var edgeEpsilon: Double { max(0.001, 0.5 / max(pixelsPerSecond, EditViewModel.minPixelsPerSecond)) }

    /// The content margin available BEFORE the clip's start, in timeline seconds. It bounds the
    /// left trim, exactly like `handleCanvasDrag` (the minimum of timeline 0 and the source content
    /// left, which swaps in reverse — @see SoundObject.contentRoomBefore). An object with no file
    /// (a group, an aux, a MIDI clip) has no stop other than timeline 0.
    func headroomBefore(_ item: SoundObject) -> Double {
        min(item.startTime, item.contentRoomBefore)
    }

    /// The content margin available AFTER the clip's end (the same convention as `headroomBefore`).
    func headroomAfter(_ item: SoundObject) -> Double {
        item.contentRoomAfter
    }

    /// True if a block covers the caret's WHOLE LINE on that display lane — hence the half
    /// thickness taken off each side: laid exactly on a block's start (or end), the caret
    /// straddles, and it had better keep the background's ink (@see InsertionCaret).
    func blockCovers(displayLane lane: Int, at t: Double) -> Bool {
        let margin = InsertionCaret.halfWidth / max(pixelsPerSecond, EditViewModel.minPixelsPerSecond)
        // `laneEntries` is sorted by display lane: a binary search lands on the row, and only the
        // objects of THAT row are looked at (it was a scan of every entry, per caret).
        let entries = viewModel.laneEntries
        var i = LaneCulling.firstIndex(atOrAfterLane: lane, count: entries.count) { entries[$0].displayLane }
        while i < entries.count, entries[i].displayLane == lane {
            let e = entries[i]
            if t >= e.absStart + margin && t <= e.absStart + e.item.duration - margin { return true }
            i += 1
        }
        return false
    }

    /// The width of a block's side handles: 25 % of its width, capped at 50 px and removed below
    /// 60 px wide. Shared by the hover, the gesture and the double click.
    func handleWidth(blockWidth bw: Double) -> Double { bw < 60 ? 0 : min(50.0, bw * 0.25) }

    /// The block under the cursor and the editing zone aimed at. The same carve-up as
    /// `handleCanvasDrag` (side handles, the upper half = fade / range selection, the lower half =
    /// trim / move, a set fade's triangle taking priority) — see `ClipEditZone.resolve`.
    func selectionZoneHover(at pos: CGPoint) -> (hover: EditZoneHover, item: SoundObject)? {
        guard let entry = blockEntry(at: pos) else { return nil }

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
        hoverStore.setHelpText(help)
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
        let entry = blockEntry(at: pos)
        let newID = entry?.item.id
        if toolHoveredID != newID { toolHoveredID = newID }
    }

    // MARK: - Unified blocks

    @ViewBuilder
    private func itemBlock(for item: SoundObject, displayLane dl: Int,
                           sendRows: [UUID: [SendRow]]? = nil) -> some View {
        if item.isInfiniteBus {
            // An infinite bus (an aux/group): no start/end any more → it takes up its WHOLE lane (it
            // processes the entire project). It is selected/handled like an ordinary clip.
            infiniteBusBand(for: item, displayLane: dl)
        } else {
            switch item.kind {
            case .clip, .aux, .midiClip:
                // The aux is rendered as a clip block (with no waveform) for now;
                // a dedicated look in 5b. The MIDI clip reuses the clip block (the note view = step C).
                soundBlock(for: item, overrideDisplayLane: dl, sendRows: sendRows)
            case .group:
                groupBlock(for: item, displayLane: dl, sendRows: sendRows)
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
            containsMissingFile: viewModel.containsMissingDescendant(item),
            blockHeight: blockHeight,
            // Being carried: the band follows the hand, like any block (@see infiniteBusPreviewDY).
            yPos: rulerHeight + Double(dl) * laneStep + infiniteBusPreviewDY(for: item.id),
            dragRefused: infiniteBusDragRefused(item.id),
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
        guard let entry = viewModel.laneEntry(forID: id) else { return nil }
        return linkTarget(for: entry)
    }

    /// The same, for an entry the caller already holds — what the link overlays use once they have
    /// resolved their ids in a single walk, instead of one scan of the entries per id.
    private func linkTarget(for entry: LaneEntry) -> LinkTarget {
        LinkTarget(clipRect(for: entry), cornerRadius: entry.item.blockCornerRadius)
    }

    // A clip's/group's rect in canvas coordinates (top level AND a child of a group),
    // resolved on laneEntries like the rest of the geometry. nil if it is not shown.
    //
    // THE GESTURE PREVIEW is part of it (the same deltas as `SoundBlockView`, @see its `xPos`):
    // without it, everything set on that rect — the link halos first and foremost — stayed at the
    // MODEL's position while the block was being moved, so hanging in empty space until release.
    //
    /// The red links of the Send tool, drawn by a method of their own: left inline in `body` this
    /// closure (plus the rest) was more than the type-checker would take in reasonable time.
    private func drawSendLinks(_ ctx: inout GraphicsContext) {
        let focus = viewModel.sendToolFocus
        // Every selected clip keeps its links visible; the clip
        // hovered (focused) is merely emphasised, it does not erase the others.
        var clipIDs = Array(viewModel.selectedIDs)
        if let f = focus, !clipIDs.contains(f.objectID) { clipIDs.append(f.objectID) }
        for clipID in clipIDs {
            guard let cr = clipRect(for: clipID) else { continue }
            let auxes = viewModel.sendToolAuxes(for: clipID)
            // The same offset as the knobs themselves: a crossfade holds the left
            // edge, the columns start after it (@see ToolSendLayer), and a link
            // setting off from the old origin would leave its knob behind.
            let inset = sendLeadingInset(for: clipID)
            // …and from the block's VISIBLE portion, read from the exact scroll
            // here in the drawing closure (like the wire's far end below).
            let vis = visibleSpan(blockX: cr.minX, blockWidth: cr.width,
                                  scrollOffsetX: scrollAnchor.x,
                                  viewportWidth: viewportWidth)
            let lay = sendColumnsLayout(blockWidth: cr.width, leadingInset: inset,
                                        count: auxes.count,
                                        visibleX: vis.x - cr.minX, visibleWidth: vis.width)
            let colW = sendColWidth(blockWidth: lay.width, count: auxes.count)
            for (idx, aux) in auxes.enumerated() {
                let isFocus = focus?.objectID == clipID && focus?.auxID == aux.id
                let routed  = viewModel.isSendRouted(from: clipID, to: aux.id)
                guard isFocus || routed else { continue }
                guard let at = linkTarget(for: aux.id) else { continue }
                let ar = at.rect
                // The link sets off from the centre of that aux's on/off button (the
                // bottom of its column), horizontally aligned on the knob.
                let srcX: Double = cr.minX + lay.origin + (Double(idx) + 0.5) * colW
                let srcY: Double = cr.maxY - 2 - sendToggleZoneHeight / 2
                let src = CGPoint(x: srcX, y: srcY)
                // It lands on the middle of the aux's VISIBLE part, not of the block:
                // a long aux (an infinite bus above all) has its middle screens
                // away. Read from the EXACT scroll, here in the drawing closure, so
                // a frame of scroll redraws this Canvas and nothing else
                // (@see WireAnchor, TimelineScrollAnchor).
                let dstX = wireAnchorX(blockX: ar.minX, blockWidth: ar.width,
                                       scrollX: Double(scrollAnchor.x),
                                       viewportWidth: Double(viewportWidth))
                let dst = CGPoint(x: dstX, y: ar.midY)
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

    private func clipRect(for id: UUID) -> CGRect? {
        guard let e = viewModel.laneEntry(forID: id) else { return nil }
        return clipRect(for: e)
    }

    /// `clipRect(for:)` once the entry is in hand.
    private func clipRect(for e: LaneEntry) -> CGRect {
        let dy = previewOffset(for: e.item)?.dy ?? 0
        let y = rulerHeight + Double(e.displayLane) * laneStep + dy
        // An infinite bus: its clickable 'surface' is its whole lane (0 → the content's width).
        // Being carried, that surface follows the band — the same reason the rect follows a
        // block's move: everything hung off it (the send links first of all) would otherwise
        // stay at the row the bus has just left.
        if e.item.isInfiniteBus {
            return CGRect(x: 0, y: y + infiniteBusPreviewDY(for: e.item.id),
                          width: contentWidth, height: blockHeight)
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

    /// What the wheel holds while it moves an automation line: the drag's own grab, frozen, plus
    /// the anchors' geometry and the TOTAL steps since (a total, like the drag's travel).
    struct AutomationLineWheel {
        let objectID: UUID
        let param: ParamRef
        let row: Int
        let grab: AutomationLineGrab
        let geo: AutomationBandGeometry
        let bandRect: CGRect
        var steps: Int = 0
        /// The gesture's undo point is pushed at its first EFFECTIVE notch, not at its first event.
        var undoPushed = false
    }

    /// The automation LINE under a point of the timeline (content coordinates), as the drag would
    /// grab it — the band's hover highlight and this are one condition
    /// (@see EditViewModel.automationLineGrab). nil anywhere else, so that the wheel goes on
    /// scrolling the timeline. Taking the grab can drop the point selection, as a drag's does.
    func automationLineWheelHit(at point: CGPoint) -> AutomationLineWheel? {
        for e in viewModel.laneEntries {
            guard let r = automationBandRect(for: e), r.contains(point) else { continue }
            let g = AutomationBandGeometry(rows: e.item.automationRows,
                                           pixelsPerSecond: pixelsPerSecond,
                                           laneStep: laneStep, rowHeight: blockHeight,
                                           bandWidth: r.width)
            let local = CGPoint(x: point.x - r.minX, y: point.y - r.minY)
            guard let row = g.rowIndex(atY: local.y),
                  let grab = viewModel.automationLineGrab(object: e.item, rows: g.rows, geo: g,
                                                          row: row, at: local) else { return nil }
            return AutomationLineWheel(objectID: e.item.id, param: g.rows[row], row: row,
                                       grab: grab, geo: g, bandRect: r)
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
        guard e.expandedSpan > 0, viewModel.hasAutomationSelector(e.item) else { return nil }
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
    ///
    /// `bands` is the list of the open groups' bands, built ONCE per pass (`inlineGroupBands`):
    /// this used to rebuild it on every call — `focusedDisplayLanes` and each group's
    /// `childLaneCount` (a sort), once per open group per frame.
    func interiorPaint(for e: LaneEntry, bands: [InlineGroupBand]) -> [Color] {
        let lane = e.displayLane + 1                 // the row that opens just under the object
        var layers: [Color] = [Self.editingAreaBackground]
        if lane % 2 == 0 { layers.append(Color.black.opacity(0.02)) }
        for band in bands where band.range.contains(lane) {
            layers.append(band.color.opacity(band.inside ? 0.22 : 0.11))
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

    /// The opaque base of every `interiorPaint`: the editing area's background.
    static let editingAreaBackground = Color(nsColor: .controlBackgroundColor)

    // MARK: - Open groups' bands

    /// One OPEN group's band, in the terms every layer that reads it needs: the display lanes it
    /// covers, its colour, and whether the editing point is inside it. Built once per pass by
    /// `inlineGroupBands`; the band layer, its rise and `interiorPaint` all read it.
    struct InlineGroupBand {
        let entry: LaneEntry
        let span: Int                  // `childLaneCount`, carried by the entry (`expandedSpan`)
        let range: ClosedRange<Int>    // displayLane + 1 ... displayLane + span
        let color: Color
        let inside: Bool               // the caret / time selection / a selected object is in it
    }

    /// The bands of the open groups, in `laneEntries` order (the order they stack in).
    /// `focused` = `focusedDisplayLanes`, computed by the caller ONCE for the whole pass.
    func inlineGroupBands(_ groups: [LaneEntry], focused: Set<Int>) -> [InlineGroupBand] {
        groups.map { entry in
            // `expandedSpan` IS `childLaneCount` for a group that shows its children inline (the
            // only ones handed here), and it was computed when the entry was built.
            let span = entry.expandedSpan
            let range = (entry.displayLane + 1)...(entry.displayLane + max(1, span))
            // `focused ∩ range ≠ ∅`, walking the SMALLER of the two.
            let inside: Bool
            if focused.isEmpty { inside = false }
            else if focused.count < range.count { inside = focused.contains { range.contains($0) } }
            else { inside = range.contains { focused.contains($0) } }
            return InlineGroupBand(entry: entry, span: span, range: range,
                                   color: entry.item.customColor ?? viewModel.stemColor(for: entry.item.id),
                                   inside: inside)
        }
    }

    /// The A/B switch of the Debug builds (`DebugRenderSwitches.forceRichBlocks`) also puts the
    /// open groups' bands back on their old SwiftUI layers. Always false in Release.
    private var forceRichBands: Bool {
        #if DEBUG
        DebugRenderSwitches.shared.forceRichBlocks
        #else
        false
        #endif
    }

    /// One band, as the Canvas draws it: every number resolved before the drawing loop.
    private struct GroupBandDrawing {
        let color: Color
        let inside: Bool
        let bandTop: Double, bandH: Double          // the band: rows under the group's block
        let lisX: Double, lisR: Double              // the top border's interruption, under the block
        let riseX: Double, riseW: Double            // the rise under the block (hence its own span)
        let riseTop: Double, riseH: Double
        let riseLayers: [Color]                     // `interiorPaint`, opaque base first
        let plus: CGPoint                           // the centre of the '+' of the drop lane
    }

    /// The bands of the open groups, in ONE Canvas — pure geometry, no interaction (it was one
    /// ZStack of four rectangles, a rise and a '+' per open group, each as wide as the whole
    /// timeline: ~2 ms of SwiftUI per open group). Everything is the old layers' own values:
    ///  • the band `color.opacity(inside ? 0.22 : 0.11)`, its top border in TWO segments
    ///    interrupted under the block (the group's material rises there) and its bottom border
    ///    whole, `opacity(inside ? 0.8 : 0.35)`, 1 px;
    ///  • the RISE under the block: the group's inside crosses the gutter and slips under the
    ///    block's bottom rounded corners, painted with `interiorPaint` — the exact stack of the
    ///    first inner row, so block and row match;
    ///  • the '+' (64 pt, light, grey 0.45) in the drop lane, centred on the group's in/out range.
    /// Culled to the viewport like the other Canvases, so a band is no longer a rectangle of
    /// millions of pixels at a high zoom. Drawing order is the old one: group by group, band then
    /// rise, so a nested group's tint stacks on its parent's.
    private func groupBandsCanvas(_ bands: [InlineGroupBand]) -> some View {
        let pps = pixelsPerSecond
        let bandW = totalDuration * pps
        let drawings: [GroupBandDrawing] = bands.map { band in
            let entry = band.entry
            let gY = rulerHeight + Double(entry.displayLane) * laneStep
            // The group block's horizontal span in the MODEL's geometry, not a gesture preview
            // (@see the old layer: the rise and the interruption belong to the band, which does
            // not follow a movement under way).
            let gX = entry.item.isInfiniteBus ? 0 : entry.absStart * pps
            let gW = entry.item.isInfiniteBus ? bandW : max(1, entry.item.duration * pps)
            let radius = entry.item.blockCornerRadius
            let dropLaneY = rulerHeight + Double(entry.displayLane + band.span) * laneStep
            return GroupBandDrawing(
                color: band.color, inside: band.inside,
                bandTop: gY + laneStep, bandH: Double(band.span) * laneStep,
                lisX: min(max(0, gX), bandW), lisR: min(max(0, gX + gW), bandW),
                riseX: gX, riseW: gW,
                riseTop: gY + blockHeight - radius, riseH: laneGap + radius,
                riseLayers: interiorPaint(for: entry, bands: bands),
                // `Text` centred in a (groupW × blockHeight) frame at (absStart, dropLaneY): this
                // is its centre. Not the infinite-aware span: the old layer used the duration.
                plus: CGPoint(x: entry.absStart * pps + entry.item.duration * pps / 2,
                              y: dropLaneY + blockHeight / 2))
        }
        let visX0 = Double(cullScrollX) - 1
        let visX1 = Double(cullScrollX) + Double(cullViewportWidth) + 1
        return Canvas { ctx, _ in
            // A rectangle [x0, x1) × [y, y + h), cut to the visible columns.
            func fillRect(_ x0: Double, _ x1: Double, y: Double, h: Double, _ color: Color) {
                let a = max(x0, visX0), b = min(x1, visX1)
                guard b > a, h > 0 else { return }
                ctx.fill(Path(CGRect(x: a, y: y, width: b - a, height: h)), with: .color(color))
            }
            // The '+' is resolved once for all the groups, and only if one of them shows it.
            var plus: GraphicsContext.ResolvedText?
            for d in drawings {
                let band = d.color.opacity(d.inside ? 0.22 : 0.11)
                let border = d.color.opacity(d.inside ? 0.8 : 0.35)
                fillRect(0, bandW, y: d.bandTop, h: d.bandH, band)
                fillRect(0, d.lisX, y: d.bandTop, h: 1, border)
                fillRect(d.lisR, bandW, y: d.bandTop, h: 1, border)
                fillRect(0, bandW, y: d.bandTop + d.bandH - 1, h: 1, border)
                for layer in d.riseLayers {
                    fillRect(d.riseX, d.riseX + d.riseW, y: d.riseTop, h: d.riseH, layer)
                }
                // A glyph about 40 pt wide: drawn while any part of it can show.
                if d.plus.x + 40 >= visX0 && d.plus.x - 40 <= visX1 {
                    if plus == nil {
                        plus = ctx.resolve(Text(verbatim: "+")
                            .font(.system(size: 64, weight: .light))
                            .foregroundColor(Color.gray.opacity(0.45)))
                    }
                    if let plus { ctx.draw(plus, at: d.plus, anchor: .center) }
                }
            }
        }
        .frame(width: bandW, height: canvasHeight, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    // MARK: - Background layers drawn by Canvas (E1)

    /// The columns every culled layer draws: the viewport's notch window, clamped to the content.
    var cullColumns: (x0: Double, x1: Double) {
        let bandW = totalDuration * pixelsPerSecond
        return (max(0, Double(cullScrollX) - 1),
                min(bandW, Double(cullScrollX) + Double(cullViewportWidth) + 1))
    }

    /// The vertical window every culled layer draws, in canvas coordinates (@see cullScrollY).
    var cullRows: (y0: Double, y1: Double) {
        (Double(cullScrollY) - 1, Double(cullScrollY) + Double(cullViewportHeight) + 1)
    }

    /// The lane bands (every EVEN row is tinted, the odd ones are bare): ONE Canvas, bounded to the
    /// viewport's rows and columns, in place of one SwiftUI rectangle per row. Same colour, same
    /// geometry (a `laneStep`-tall row, the full width) as the layer it replaces.
    private func laneBandsCanvas(laneRows: Int) -> some View {
        let step = laneStep, ruler = rulerHeight
        let bandW = totalDuration * pixelsPerSecond
        let (x0, x1) = cullColumns
        let win = cullRows
        let rows = LaneCulling.rows(y0: win.y0, y1: win.y1, rulerHeight: ruler, laneStep: step,
                                    count: laneRows)
        let tint = Color.black.opacity(0.02)
        return Canvas { ctx, _ in
            guard x1 > x0 else { return }
            for lane in rows where lane % 2 == 0 {
                ctx.fill(Path(CGRect(x: x0, y: ruler + Double(lane) * step,
                                     width: x1 - x0, height: step)),
                         with: .color(tint))
            }
        }
        .frame(width: bandW, height: canvasHeight, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// The sub-lane background of the MIDI clips whose piano roll is open, tinted with the clip's
    /// stem colour: ONE Canvas, from the view model's cached list of open objects (never a filter
    /// over every entry of the timeline), culled to the viewport. The band's two sub-lanes touch,
    /// so they are one rectangle; each was a `laneStep`-tall rectangle of the same translucent
    /// colour before.
    private func pianoRollTintsCanvas() -> some View {
        struct Tint { let y: Double; let h: Double; let color: Color }
        let step = laneStep, ruler = rulerHeight
        let bandW = totalDuration * pixelsPerSecond
        let (x0, x1) = cullColumns
        let win = cullRows
        let tints: [Tint] = viewModel.expandedLaneEntries.compactMap { entry in
            guard entry.item.showsPianoRollInline else { return nil }
            let top = ruler + Double(entry.displayLane + 1) * step
            let h = Double(SoundObject.pianoRollLaneSpan) * step
            guard LaneCulling.meets(top: top, height: h, y0: win.y0, y1: win.y1) else { return nil }
            return Tint(y: top, h: h, color: viewModel.stemColor(for: entry.item.id).opacity(0.06))
        }
        return Canvas { ctx, _ in
            guard x1 > x0 else { return }
            for t in tints {
                ctx.fill(Path(CGRect(x: x0, y: t.y, width: x1 - x0, height: t.h)),
                         with: .color(t.color))
            }
        }
        .frame(width: bandW, height: canvasHeight, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// The out-of-range masks of OPEN objects (the zones before / after the played range, inside
    /// the unfolded band of sub-lanes). A SHARED mechanism driven by `expandedSpan`: an expanded
    /// group (the band = the children) AND an open MIDI clip (the band = the piano roll). It greys
    /// the outside of the content out so as to focus on the inside. An infinite bus has no range any
    /// more, hence no out-of-range: no mask. ONE Canvas, resolved HERE (the preview deltas of a trim
    /// under way included: the mask's bounds follow the hand, otherwise the veil stayed at the old
    /// bounds and the inside was only revealed on release) and culled to the viewport's rows and
    /// columns. The caller declares it AFTER the blocks, with no zIndex — the z-order of the layer
    /// it replaces: above the Canvas's blocks, below the selected rich ones (1).
    private func rangeMasksCanvas() -> some View {
        struct Mask { let y: Double; let h: Double; let gs: Double; let ge: Double }
        let step = laneStep, ruler = rulerHeight
        let totalW = totalDuration * pixelsPerSecond
        let (x0, x1) = cullColumns
        let win = cullRows
        var masks: [Mask] = []
        for entry in viewModel.expandedLaneEntries where !entry.item.isInfiniteBus {
            let item = entry.item
            let top = ruler + Double(entry.displayLane + 1) * step
            let h = Double(entry.expandedSpan) * step
            guard LaneCulling.meets(top: top, height: h, y0: win.y0, y1: win.y1) else { continue }
            let gs = item.startTime * pixelsPerSecond + previewTrimDX(for: item)
            let ge = (item.startTime + item.duration) * pixelsPerSecond + previewResizeDX(for: item)
            masks.append(Mask(y: top, h: h, gs: gs, ge: ge))
        }
        let veil = Color.black.opacity(0.28)
        return Canvas { ctx, _ in
            guard x1 > x0 else { return }
            for m in masks {
                // The part before the start [0, gs) and the part after the end [ge, totalW),
                // each cut to the visible columns.
                if m.gs > 0 {
                    let a = x0, b = min(x1, m.gs)
                    if b > a {
                        ctx.fill(Path(CGRect(x: a, y: m.y, width: b - a, height: m.h)), with: .color(veil))
                    }
                }
                if m.ge < totalW {
                    let a = max(x0, m.ge), b = x1
                    if b > a {
                        ctx.fill(Path(CGRect(x: a, y: m.y, width: b - a, height: m.h)), with: .color(veil))
                    }
                }
            }
        }
        .frame(width: totalW, height: canvasHeight, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    // MARK: - Layers drawn by Canvas (E2)

    /// The display rows of a set of lanes (a time selection's) that the cull window shows,
    /// ascending. It walks whichever is SMALLER — the set or the visible rows — so a selection of a
    /// thousand lanes costs what the screen holds, not what the selection does.
    private func visibleLanes(of lanes: Set<Int>) -> [Int] {
        let win = cullRows
        let rows = LaneCulling.rows(y0: win.y0, y1: win.y1, rulerHeight: rulerHeight,
                                    laneStep: laneStep, count: Int.max)
        if lanes.count <= rows.count { return lanes.filter { rows.contains($0) }.sorted() }
        return rows.filter { lanes.contains($0) }
    }

    /// Every crossfade zone — and the ghost of the one a spilling fade is about to open — in ONE
    /// Canvas, above the blocks (the caller sets the zIndex). The zones are resolved by
    /// `crossfadeDrawings()` (@see CrossfadeVeilOverlay.swift), culled to the viewport.
    @ViewBuilder private func crossfadeCanvas() -> some View {
        let drawings = crossfadeDrawings()
        if !drawings.isEmpty {
            Canvas { ctx, _ in
                for d in drawings { d.draw(in: ctx) }
            }
            .frame(width: totalDuration * pixelsPerSecond, height: canvasHeight, alignment: .topLeading)
            .allowsHitTesting(false)
        }
    }

    /// The time selection's fill: one rectangle per lane of the selection, the visible rows and the
    /// visible columns only. Same colour, same box (`blockHeight` tall, on its lane's top) as the
    /// SwiftUI rectangles it replaces.
    @ViewBuilder private func timeSelectionCanvas() -> some View {
        if let sel = viewModel.timeSelection {
            let cols = cullColumns
            let x = sel.timeRange.lowerBound * pixelsPerSecond
            let a = max(x, cols.x0)
            let b = min(x + (sel.timeRange.upperBound - sel.timeRange.lowerBound) * pixelsPerSecond, cols.x1)
            let ys = visibleLanes(of: sel.lanes).map { rulerHeight + Double($0) * laneStep }
            if b > a, !ys.isEmpty {
                let h = blockHeight
                Canvas { ctx, _ in
                    for y in ys {
                        ctx.fill(Path(CGRect(x: a, y: y, width: b - a, height: h)),
                                 with: .color(TimeSelection.overlayColor))
                    }
                }
                .frame(width: totalDuration * pixelsPerSecond, height: canvasHeight, alignment: .topLeading)
                .allowsHitTesting(false)
            }
        }
    }

    /// Where the carets are and what ink each takes, for the rows and columns the viewport shows.
    private func caretPlan() -> (x: Double, carets: [(y: Double, ink: Color)]) {
        let t: Double
        let lanes: [Int]
        if let sel = viewModel.timeSelection {
            t = sel.timeRange.lowerBound
            lanes = visibleLanes(of: sel.lanes)
        } else if let cl = viewModel.caretLane {
            t = currentSelectionCursor
            lanes = visibleLanes(of: [cl])
        } else {
            return (0, [])
        }
        let cols = cullColumns
        let x = t * pixelsPerSecond - InsertionCaret.halfWidth
        guard !lanes.isEmpty, x + InsertionCaret.width >= cols.x0, x <= cols.x1 else { return (x, []) }
        let carets: [(y: Double, ink: Color)] = lanes.map { lane in
            let over = blockCovers(displayLane: lane, at: t)
            return (rulerHeight + Double(lane) * laneStep,
                    over || colorScheme != .dark ? Color.black : Color.white)
        }
        return (x, carets)
    }

    /// The insertion caret(s): on each visible lane of the time selection at its left edge, or on
    /// the lane clicked (with no selection) at the cursor. The ink follows what the line COVERS
    /// (@see InsertionCaret): black over an object, otherwise the background's — resolved here, with
    /// `blockCovers`, which alone knows how the display lanes are flattened.
    @ViewBuilder private func caretsCanvas() -> some View {
        let plan = caretPlan()
        if !plan.carets.isEmpty {
            let x = plan.x
            let carets = plan.carets
            let h = blockHeight
            Canvas { ctx, _ in
                for c in carets {
                    ctx.fill(Path(CGRect(x: x, y: c.y, width: InsertionCaret.width, height: h)),
                             with: .color(c.ink))
                }
            }
            .frame(width: totalDuration * pixelsPerSecond, height: canvasHeight, alignment: .topLeading)
            .allowsHitTesting(false)
        }
    }

    /// The entries of `laneEntries` for a set of ids, in ONE walk (stopping as soon as all are
    /// found) — local to the link overlays, which used to scan every entry once per id.
    private func laneEntries(withIDs ids: Set<UUID>) -> [UUID: LaneEntry] {
        guard !ids.isEmpty else { return [:] }
        var found: [UUID: LaneEntry] = [:]
        found.reserveCapacity(ids.count)
        for e in viewModel.laneEntries where ids.contains(e.item.id) {
            found[e.item.id] = e
            if found.count == ids.count { break }
        }
        return found
    }

    /// The star of the plugin whose editor is open: the source object's target and the other
    /// members' that are shown. `nil` when the source itself is not shown (nothing to draw).
    private func pluginLinkPlan(_ info: EditViewModel.LinkOverlayInfo) -> (source: LinkTarget, members: [LinkTarget])? {
        var ids = Set(info.memberObjectIDs)
        ids.insert(info.sourceObjectID)
        let found = laneEntries(withIDs: ids)
        guard let src = found[info.sourceObjectID] else { return nil }
        let members = info.memberObjectIDs
            .filter { $0 != info.sourceObjectID }
            .compactMap { found[$0] }
            .map { linkTarget(for: $0) }
        return (linkTarget(for: src), members)
    }

    /// One consolidated definition's purple link, resolved.
    private enum ConsolidateLink {
        case star(source: LinkTarget, members: [LinkTarget])
        case chain(nodes: [(target: LinkTarget, active: Bool)])
    }

    /// The links the selection arms: for each consolidated definition a selected object belongs to,
    /// a star (one selected) or one chain (several). It reads the SHOWN placements — the same ones
    /// the overlay always drew, a placement with no row having no target — in a single walk of the
    /// entries for every definition at once, and does nothing at all (no walk) when the selection
    /// holds no consolidated object. It replaces `hasSelectedLinkedObject` (a walk of the whole
    /// tree per selected object) followed by `placementIDs` (another, per definition) and a scan of
    /// the entries per placement: O(selected × objects) twice over.
    private func consolidateLinkPlan() -> [ConsolidateLink] {
        guard !viewModel.selectedIDs.isEmpty else { return [] }
        var selectedByDef: [UUID: [UUID]] = [:]
        for id in viewModel.selectedIDs {
            guard let defID = viewModel.find(id: id)?.consolidateID else { continue }
            selectedByDef[defID, default: []].append(id)
        }
        guard !selectedByDef.isEmpty else { return [] }
        var placements: [UUID: [LaneEntry]] = [:]
        for e in viewModel.laneEntries {
            guard let defID = e.item.consolidateID, selectedByDef[defID] != nil else { continue }
            placements[defID, default: []].append(e)
        }
        var plan: [ConsolidateLink] = []
        for (defID, selected) in selectedByDef {
            let all = placements[defID] ?? []
            if selected.count <= 1 {
                guard let src = selected.first, let srcEntry = all.first(where: { $0.item.id == src })
                else { continue }
                let members = all.filter { $0.item.id != src }.map { linkTarget(for: $0) }
                guard !members.isEmpty else { continue }
                plan.append(.star(source: linkTarget(for: srcEntry), members: members))
            } else {
                // Every visible instance of the definition, ordered along the timeline
                // (left→right, then top→bottom), joined in a chain.
                let selectedSet = Set(selected)
                let nodes = all
                    .map { (target: linkTarget(for: $0), active: selectedSet.contains($0.item.id)) }
                    .sorted { l, r in
                        l.target.rect.minX != r.target.rect.minX
                            ? l.target.rect.minX < r.target.rect.minX
                            : l.target.rect.minY < r.target.rect.minY
                    }
                guard nodes.count > 1 else { continue }
                plan.append(.chain(nodes: nodes))
            }
        }
        return plan
    }

    #if DEBUG
    /// The OLD drawing of the open groups' bands — one SwiftUI layer stack per group — kept ONLY
    /// for the Debug A/B switch (`DebugRenderSwitches.forceRichBlocks`), so that the Canvas above
    /// can be compared with what it replaced, on the same project. Deliberately untouched by the
    /// optimisations of the new path, `legacyInteriorPaint` included.
    @ViewBuilder private func richGroupBands(_ inlineGroupEntries: [LaneEntry],
                                             focusedLanes: Set<Int>) -> some View {
        ForEach(inlineGroupEntries) { entry in
            let gY     = rulerHeight + Double(entry.displayLane) * laneStep
            let color  = entry.item.customColor ?? viewModel.stemColor(for: entry.item.id)
            let span   = entry.item.childLaneCount
            let bandH  = Double(span) * laneStep
            let bandW  = totalDuration * pixelsPerSecond
            let inside = !focusedLanes.isDisjoint(
                with: (entry.displayLane + 1)...(entry.displayLane + span))
            let gX = entry.item.isInfiniteBus ? 0 : entry.absStart * pixelsPerSecond
            let gW = entry.item.isInfiniteBus
                   ? contentWidth : max(1, entry.item.duration * pixelsPerSecond)
            let lisX = min(max(0, gX), bandW)
            let lisR = min(max(0, gX + gW), bandW)
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(color.opacity(inside ? 0.22 : 0.11))
                    .frame(width: bandW, height: bandH)
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

            ZStack(alignment: .topLeading) {
                ForEach(Array(legacyInteriorPaint(for: entry).enumerated()), id: \.offset) { _, layer in
                    Rectangle().fill(layer)
                }
            }
            .frame(width: gW, height: laneGap + entry.item.blockCornerRadius)
            .offset(x: gX, y: gY + blockHeight - entry.item.blockCornerRadius)
            .allowsHitTesting(false)
        }
    }

    /// The old '+' layer of the open groups' drop lanes (Debug A/B only).
    @ViewBuilder private func richGroupPluses(_ inlineGroupEntries: [LaneEntry]) -> some View {
        ForEach(inlineGroupEntries) { entry in
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

    /// The OLD `interiorPaint`, as it was before the bands got a precomputed list: it rebuilds
    /// `focusedDisplayLanes` and every open group's `childLaneCount` on each call. Debug A/B only.
    func legacyInteriorPaint(for e: LaneEntry) -> [Color] {
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
    #endif

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
        point.y >= scrollOffsetY
            && point.y <= scrollOffsetY + CGFloat(MarkerBandGeometry.rulerCoreHeight)
    }

    /// The row of the marker band a point falls on, or nil if it is not in the band.
    ///
    /// The band is part of the same sticky header, UNDER the ruler: in content coordinates it
    /// occupies `[scrollOffsetY + rulerCoreHeight, scrollOffsetY + rulerHeight]`. It is deliberately
    /// NOT part of `rulerBandContains`, which grants the ruler's one gesture — moving the cursor
    /// and nothing else. The band has its own.
    func markerBandRow(at point: CGPoint) -> Int? {
        let top = scrollOffsetY + CGFloat(MarkerBandGeometry.rulerCoreHeight)
        let rows = viewModel.visibleMarkerLaneCount
        guard rows > 0, point.y >= top else { return nil }
        let row = Int((point.y - top) / CGFloat(MarkerBandGeometry.rowHeight))
        return row < rows ? row : nil
    }

    func markerBandContains(_ point: CGPoint) -> Bool { markerBandRow(at: point) != nil }

    /// True where a point of the band lands on a PINNED control — a row's name (dot, field), or the
    /// button that governs the rows. They sit in the overlay layer and answer for themselves (the
    /// double click that renames, the menu), so the band's empty-space gestures leave them alone
    /// (@see MarkerBandGesture). Read relative to the viewport's left edge: they do not scroll.
    func markerLaneHeaderContains(_ point: CGPoint) -> Bool {
        guard markerBandContains(point) else { return false }
        return MarkerBandGesture.inPinnedControls(xInViewport: Double(point.x - scrollOffsetX),
                                                  viewportWidth: Double(viewportWidth))
    }

    /// The row whose COLOUR DOT a point lands on, or nil. The headers are pinned to the viewport,
    /// so the point is read relative to its left edge — `point.x - scrollOffsetX` — and never to the
    /// content, which slides under them.
    ///
    /// It exists because an AppKit local monitor sees a right click before the view hierarchy does:
    /// the dot cannot take its own click, so the monitor resolves it here, the way the canvas
    /// resolves every other click in this project (@see MarkerLaneHeaderView.dotXRange).
    func markerLaneDotHit(at point: CGPoint) -> UUID? {
        guard let row = markerBandRow(at: point) else { return nil }
        let lanes = viewModel.visibleMarkerLanes
        guard row < lanes.count else { return nil }
        let x = Double(point.x - scrollOffsetX)
        guard MarkerLaneHeaderView.dotXRange.contains(x) else { return nil }
        return lanes[row].id
    }

    /// The marker or region a point in the band lands on, and WHAT PART of it. A REGION is taken
    /// anywhere along its span, its two ends cropping and its body moving; a point marker is taken
    /// within `grabPx` of its tick, or anywhere along the name that hangs off it — one aims at the
    /// word one reads — and has only a body, a point having no length to pull.
    ///
    /// Point markers are tried FIRST: one sitting inside a region has to stay reachable, and it is
    /// the finer mark of the two.
    ///
    /// The handles are the comment's own rule (@see `commentZone`), capped so that a short region
    /// keeps a body to grab — with a cap of `grabPx`, which is what the band already calls 'near
    /// enough to a hairline'. Under four times that, a region is all body: one moves it, and crops
    /// it after zooming in, rather than having the two gestures fight over five pixels.
    func markerBandZone(at point: CGPoint)
        -> (lane: UUID, marker: UUID, part: MarkerBandDragState.Part)? {
        guard let row = markerBandRow(at: point) else { return nil }
        let lanes = viewModel.visibleMarkerLanes
        guard row < lanes.count, pixelsPerSecond > 0 else { return nil }
        let lane = lanes[row]
        let t = point.x / pixelsPerSecond
        let grab = MarkerBandGeometry.grabPx / pixelsPerSecond

        for m in lane.markers where !m.isRegion {
            let labelSpan = MarkerBandGeometry.labelWidth(m.name) / pixelsPerSecond
            if t >= m.time - grab && t <= m.time + max(grab, labelSpan) {
                return (lane.id, m.id, .move)
            }
        }
        for m in lane.markers where m.isRegion {
            guard t >= m.time, t <= m.endTime else { continue }
            let handle = min(grab, (m.endTime - m.time) / 4)
            if t <= m.time + handle    { return (lane.id, m.id, .resizeLeft) }
            if t >= m.endTime - handle { return (lane.id, m.id, .resizeRight) }
            return (lane.id, m.id, .move)
        }
        return nil
    }

    /// The mark a point in the band lands on, its part left aside — what a CLICK needs, a click
    /// selecting the whole mark wherever on it the hand came down. @see `markerBandZone`.
    func markerBandHit(at point: CGPoint) -> AnnotationSel? {
        markerBandZone(at: point).map { .laneMarker(lane: $0.lane, marker: $0.marker) }
    }

    /// The marker CARRIED BY AN OBJECT that a point lands on. Only the top strip of a block takes
    /// them: the rest of its surface belongs to the object itself, and a marker must not make a
    /// block harder to grab.
    /// The horizontal reading is done in TIME, exactly as the band reads its own marks
    /// (@see `markerBandZone`, which is this function's model in every other respect too) — and
    /// that conversion is what was MISSING: `point.x` arrives in PIXELS while the mark's instant,
    /// the tolerance and the name's span are all in seconds. The comparison could therefore only
    /// come true within a handful of pixels of the canvas's left edge, so a mark carried by an
    /// object was unreachable by EVERY gesture at once — the click that selects it, the double
    /// click that renames it, the right click that opens its menu and the drag that moves it all
    /// ask this one question, and all four got nil. The menu, the inline field and the model's
    /// `moveObjectMarker` existed and were correct; none of them had a door onto the hand.
    func objectMarkerHit(at point: CGPoint) -> AnnotationSel? {
        guard pixelsPerSecond > 0 else { return nil }
        let t    = point.x / pixelsPerSecond
        let grab = MarkerBandGeometry.grabPx / pixelsPerSecond
        for e in viewModel.laneEntries {
            let by = rulerHeight + Double(e.displayLane) * laneStep
            guard point.y >= by, point.y <= by + ObjectMarkersOverlay.grabStripHeight else { continue }
            // The part of a child under its group's out-of-range veil is not clickable.
            guard e.isUnmasked(atX: point.x, pixelsPerSecond: pixelsPerSecond) else { continue }
            for m in e.item.markers {
                // Only what is INSIDE the window: a marker pushed behind an edge is kept but not
                // drawn, so it must not be clickable either (@see Array where Element == Marker).
                guard m.time >= 0, m.time <= e.item.duration else { continue }
                let mt = e.absStart + m.time
                let labelSpan = MarkerBandGeometry.labelWidth(m.name) / pixelsPerSecond
                if t >= mt - grab && t <= mt + max(grab, labelSpan) {
                    return .objectMarker(object: e.item.id, marker: m.id)
                }
            }
        }
        return nil
    }

    /// The comment a point lands on. Comments sit OVER the lanes, so this is asked before the
    /// blocks — a comment one cannot click is a comment one cannot delete.
    func commentHit(at point: CGPoint) -> AnnotationSel? {
        guard pixelsPerSecond > 0 else { return nil }
        // `visibleComments` and not `comments`: a comment stores a BASE row of ITS OWN FRAME, and
        // the resolved list is where that becomes an absolute time and a row on screen. Reading
        // the model raw here would leave it clickable where it no longer is as soon as a group
        // above it opened — and would make one clickable whose group is folded.
        for p in viewModel.visibleComments.reversed() {   // the last laid is the one on top
            let x0 = p.absStart * pixelsPerSecond
            let x1 = p.absEnd * pixelsPerSecond
            let y0 = rulerHeight + Double(p.displayLane) * laneStep
            if point.x >= x0 && point.x <= x1 && point.y >= y0 && point.y <= y0 + blockHeight {
                return .comment(p.id)
            }
        }
        return nil
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
            if let r = clipRect(for: e.item.id), r.contains(point),
               e.isUnmasked(atX: point.x, pixelsPerSecond: pixelsPerSecond) {
                return e.item.id
            }
        }
        return nil
    }

    @ViewBuilder
    private func soundBlock(for object: SoundObject, overrideDisplayLane: Int? = nil,
                            sendRows memo: [UUID: [SendRow]]? = nil) -> some View {
        let dLane = overrideDisplayLane ?? displayLane(for: object.lane)
        // ONCE per block: it walks the partner cache and the drag's projection, and both ends used to
        // ask for it separately.
        let shared = crossfadeSharedPx(for: object)
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
            liveScroll: liveScroll,
            waveformDisplayDB: waveformDisplayDB,
            displayLane: dLane,
            stemColor: viewModel.stemColor(for: object.id),
            isMutedInMix:     viewModel.isMutedInMix(object),
            isMissingFile:    viewModel.isMissing(object),
            previewOffset:    previewOffset(for: object),
            previewResizeDX:  previewResizeDX(for: object),
            previewTrimDX:    previewTrimDX(for: object),
            previewFadeIn:    previewFadeIn(for: object),
            previewFadeOut:   previewFadeOut(for: object),
            previewFadeInCurve:  previewFadeCurveIn(for: object),
            previewFadeOutCurve: previewFadeCurveOut(for: object),
            sharedLeadingPx:  shared.leading,
            sharedTrailingPx: shared.trailing,
            previewLoopRange: previewLoopRange(for: object),
            isToolHovered:    toolHoveredID == object.id,
            stemAssignTarget: stemAssignTarget,
            sendRows:         (viewModel.activeTool == .toolAux && !object.isAux)
                                ? sendRowsFor(object.id, memo: memo) : [],
            isRenaming:       viewModel.renamingID == object.id,
            isBaking:         viewModel.isBaking(object.id),
            // A `let` of the view-model: reading it here tracks nothing. @see RenderProgressStore
            renderProgress:   viewModel.renderProgress,
            isStale:          object.isConsolidateInstance && viewModel.isStale(object.id),
            isPreviewing:     viewModel.hasLiveMirrors && viewModel.editingPlacementID == object.id,
            isRecomputing:    object.consolidateID.map { viewModel.recomputingConsolidateIDs.contains($0) } ?? false,
            isResynced:       object.consolidateID.map { viewModel.recentlyResyncedConsolidateIDs.contains($0) } ?? false,
            isEditing:        viewModel.editingPlacementID == object.id,
            onRename: { label in
                if let label { viewModel.renameObject(id: object.id, label: label) }
                viewModel.renamingID = nil
            }
        )
        // `.task(id:)` (and not `.onAppear`): the placement can change its `filePath` WITHOUT the
        // view being rebuilt (a clip→consolidated object transformation, a definition's re-bake) — `onAppear`
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

    /// Splits the visible entries into the clips the shared Canvas draws and the blocks that keep
    /// a rich view, in ONE pass (and counts the rich groups on the way, for `TimelineRegimeMeter`).
    /// The A/B switch of Debug builds (@see `DebugRenderSwitches`) is read here, once per pass.
    private struct BlockPartition {
        var plain: [LaneEntry] = []        // clips drawn by the Canvas
        var plainGroups: [LaneEntry] = []  // groups drawn by the Canvas
        var rich: [LaneEntry] = []         // everything that keeps a SwiftUI view
        var richGroups = 0                 // how many of `rich` are groups
        /// Why each rich block is rich, per `RichReason` (for `perf.census`): summed in this
        /// pass, from the very answer that decided the block's regime.
        var reasons = [Int](repeating: 0, count: RichReason.count)
        /// What the active tool lays over the blocks the Canvas draws (clips AND groups), by id.
        var toolOverlays: [UUID: CanvasToolOverlay] = [:]
        /// The instances of a consolidated object the Canvas draws (at rest: nothing recomputing,
        /// baking or being edited), with the badges they carry. Resolved here, in the body, and not
        /// in the Canvas's renderer closure.
        var consolidated: [UUID: ConsolidateBadge] = [:]
        /// The geometry of the blocks (clips AND groups) the Canvas draws while a gesture previews
        /// them — move, trim, resize, fade, spill, loop bound — by id. Empty at rest, and with the
        /// fallback `RenderPreferences.richPreviews` on (those blocks are then rich views). Resolved
        /// here, in the body, like everything else the Canvas's renderer closure draws from.
        var previews: [UUID: BlockPreviewGeometry] = [:]
    }

    /// What `plainBlocksCanvas` draws ONE clip with: its rectangle, its content's source offset
    /// and length, its fades and its loop bounds — the stored values, or the gesture's
    /// (`BlockPreviewGeometry`) for a block being previewed.
    private struct CanvasBlockLook {
        var rect: CGRect
        var sourceOffset: Double
        var duration: Double
        var fadeIn: Double
        var fadeOut: Double
        var curveIn: FadeCurve
        var curveOut: FadeCurve
        var loopRange: (start: Double, end: Double)?
        /// The left edge's travel in whole px (a MIDI clip's notes stay anchored in absolute terms).
        var trimDX: Double
        var w: Double { rect.width }
    }

    /// The freshness badges of a consolidated instance at rest: a warning if the bake captured
    /// content that has since changed, a transient green tick right after its re-bake.
    struct ConsolidateBadge {
        var stale: Bool
        var resynced: Bool
    }

    private func partitionVisibleBlocks(_ entries: [LaneEntry], tools: ToolPartitionContext) -> BlockPartition {
        var p = BlockPartition()
        #if DEBUG
        let forceRichSelected = DebugRenderSwitches.shared.forceRichBlocks
        #else
        let forceRichSelected = false
        #endif
        // The previews go to the Canvas unless the fallback puts them back on the rich views. The
        // gesture test is made ONCE for the pass: at rest no block is asked for its geometry.
        let richPreviews = RenderPreferences.shared.richPreviews
        let previewing = !richPreviews && hasPreviewGesture
        for entry in entries {
            if entry.item.isGroup {
                if let why = groupRichReason(entry, forceRich: forceRichSelected, tools: tools,
                                             richPreviews: richPreviews) {
                    p.rich.append(entry)
                    p.richGroups += 1
                    p.reasons[why.rawValue] += 1
                } else {
                    p.plainGroups.append(entry)
                    if let o = canvasToolOverlay(for: entry, tools: tools) { p.toolOverlays[entry.item.id] = o }
                    if previewing, let g = blockPreviewGeometry(for: entry.item) { p.previews[entry.item.id] = g }
                }
            } else if let why = clipRichReason(entry, forceRichSelected: forceRichSelected, tools: tools,
                                               richPreviews: richPreviews) {
                p.rich.append(entry)
                p.reasons[why.rawValue] += 1
            } else {
                p.plain.append(entry)
                if let o = canvasToolOverlay(for: entry, tools: tools) { p.toolOverlays[entry.item.id] = o }
                if previewing, let g = blockPreviewGeometry(for: entry.item) { p.previews[entry.item.id] = g }
                if entry.item.isConsolidateInstance {
                    let id = entry.item.id
                    p.consolidated[id] = ConsolidateBadge(
                        stale: viewModel.isStale(id),
                        resynced: entry.item.consolidateID.map { viewModel.recentlyResyncedConsolidateIDs.contains($0) } ?? false)
                }
            }
        }
        return p
    }

    // MARK: What the tools ask of the partition

    /// What the active tool contributes to the partition, read ONCE per pass (and only under a
    /// tool: `toolHoveredID`, the drags and the send focus are not read otherwise, so a hover under
    /// another tool never re-evaluates the layer).
    private struct ToolPartitionContext {
        var tool: ToolOverlayPartition.Tool = .none
        /// The Debug A/B switch (@see `DebugRenderSwitches.forceRichTools`): the pre-Canvas regime.
        var forceRich = false
        var selected = Set<UUID>()
        /// The blocks AIMED AT: hovered (Volume / Pan / Stem), grabbed by a drag, or holding the
        /// Send tool's focus. The rich view carries the full, live overlay of these.
        var hoveredID: UUID?
        var grabbedID: UUID?
        var focusedID: UUID?
        /// The Send tool's columns for every block shown, computed once per pass (nil = not asked:
        /// a rich block then reads them live, as the ghost's does).
        var sendRows: [UUID: [SendRow]]?
        /// The vertical window the lanes on screen cover (canvas coordinates): what lies outside
        /// it is not seen, so the tool asks nothing of it.
        var rows: (y0: Double, y1: Double) = (0, 0)
        var live: LiveScroll?

        func isAimed(_ id: UUID) -> Bool { id == hoveredID || id == grabbedID || id == focusedID }
    }

    private func toolPartitionContext(_ entries: [LaneEntry], selectedIDs: Set<UUID>) -> ToolPartitionContext {
        var t = ToolPartitionContext()
        switch viewModel.activeTool {
        case .toolVolume:
            t.tool = .volume
            t.hoveredID = toolHoveredID
            t.grabbedID = volumeDrag?.grabbedID
        case .toolPan:
            t.tool = .pan
            t.hoveredID = toolHoveredID
            t.grabbedID = panDrag?.grabbedID
        case .toolStemAssign:
            t.tool = .stem
            t.hoveredID = toolHoveredID
        case .toolAux:
            t.tool = .aux
            t.focusedID = viewModel.sendToolFocus?.objectID
            t.grabbedID = sendDrag?.grabbedID
        default:
            return t
        }
        #if DEBUG
        t.forceRich = DebugRenderSwitches.shared.forceRichTools
        #endif
        t.selected = selectedIDs
        t.rows = cullRows
        t.live = liveScroll
        if t.tool == .aux {
            // The Send tool's columns for every block on screen, in ONE walk (one sort of the auxes,
            // one parent map) instead of one per block — read by the partition (which blocks have
            // columns), by the Canvas (the columns themselves) and by the rich views.
            let (y0, y1) = t.rows
            let senders = entries.compactMap { e -> SoundObject? in
                let y = rulerHeight + Double(e.displayLane) * laneStep
                return !e.item.isAux && y + blockHeight >= y0 && y <= y1 ? e.item : nil
            }
            t.sendRows = viewModel.sendRows(forObjects: senders)
        }
        return t
    }

    /// Why the active tool keeps this block rich, nil if the Canvas can draw it (and the tool's
    /// overlay over it). The rule itself is `ToolOverlayPartition.verdict`; this reads the model.
    private func toolRichReason(_ entry: LaneEntry, isGroup: Bool, tools: ToolPartitionContext) -> RichReason? {
        guard tools.tool != .none else { return nil }
        let item = entry.item
        let aimed = tools.isAimed(item.id)

        if tools.tool == .stem {
            guard aimed else { return nil }
            // The pre-Canvas rule (Debug switch): a group hovered, but a clip only if selected as well.
            if tools.forceRich, !isGroup, !tools.selected.contains(item.id) { return nil }
            return .stemHover
        }
        if tools.forceRich { return .tool }
        if aimed { return .toolHover }

        // Outside the lanes on screen nothing is seen, whatever the tool would draw there.
        let y = rulerHeight + Double(entry.displayLane) * laneStep
        guard y + blockHeight >= tools.rows.y0, y <= tools.rows.y1 else { return nil }

        let w = max(2, item.duration * pixelsPerSecond)
        let x = item.startTime * pixelsPerSecond
        let hasRows = !(tools.sendRows?[item.id]?.isEmpty ?? true)
        let verdict = ToolOverlayPartition.verdict(
            tool: tools.tool, blockWidth: w, isSelected: tools.selected.contains(item.id),
            isAimed: false, hasSendRows: hasRows,
            spanIsInvariant: tools.live?.spanIsInvariant(blockX: x, blockWidth: w) ?? true)
        return verdict == .richSpan ? .toolSpan : nil
    }

    /// What the active tool lays over a block the Canvas draws, nil if nothing: the Volume tool's
    /// minimal veil (a selected block, or a narrow one), the Pan tool's panel. The values are read
    /// HERE, in the layer's body — the Canvas's renderer closure reads nothing from the model.
    ///
    /// The SPAN the controls sit in: a block no viewport edge can cut shows itself whole
    /// (`LiveScroll.spanIsInvariant`, which is exactly what `LiveVisibleSpan` answers for it); a
    /// NARROW block keeps the culling window's span, in the rich views as here. A wide block that an
    /// edge can cut never gets here — the partition keeps it rich.
    private func canvasToolOverlay(for entry: LaneEntry, tools: ToolPartitionContext) -> CanvasToolOverlay? {
        guard tools.tool != .none, tools.tool != .stem, !tools.forceRich else { return nil }
        let item = entry.item
        let y = rulerHeight + Double(entry.displayLane) * laneStep
        guard y + blockHeight >= tools.rows.y0, y <= tools.rows.y1 else { return nil }

        let w = max(2, item.duration * pixelsPerSecond)
        let x = item.startTime * pixelsPerSecond
        let selected = tools.selected.contains(item.id)
        func span(exact: Bool) -> (x: Double, width: Double) {
            if exact, tools.live?.spanIsInvariant(blockX: x, blockWidth: w) ?? true { return (0, w) }
            let s = visibleSpan(blockX: x, blockWidth: w,
                                scrollOffsetX: cullScrollX, viewportWidth: cullViewportWidth)
            return (s.x - x, s.width)
        }
        switch tools.tool {
        case .volume:
            let plan = ToolOverlayGeometry.volumePlan(blockWidth: w, isSelected: selected, isToolHovered: false)
            guard plan.showMinimal else { return nil }
            return CanvasToolOverlay(content: .volumeMinimal(volume: item.volume, isMuted: item.isMuted),
                                     span: span(exact: plan.needsExactSpan))
        case .pan:
            let plan = ToolOverlayGeometry.panPlan(blockWidth: w, isSelected: selected, isToolHovered: false)
            guard plan.shown else { return nil }
            return CanvasToolOverlay(content: .pan(pan: item.pan), span: span(exact: plan.needsExactSpan))
        case .aux:
            // One column per aux the block can send to, from the pass's memo. The columns follow
            // the exact scroll, so a block an edge can cut is never here (it is rich): its visible
            // span is the block itself.
            guard let rows = tools.sendRows?[item.id], !rows.isEmpty else { return nil }
            let columns = rows.map {
                ToolOverlaySendColumn(label: $0.label, level: $0.level, enabled: $0.enabled,
                                      focused: $0.focused, automated: $0.automated)
            }
            return CanvasToolOverlay(content: .sends(columns: columns,
                                                     leadingInset: crossfadeSharedPx(for: item).leading),
                                     span: span(exact: true))
        default:
            return nil
        }
    }

    /// The Send tool's rows for a block a rich view draws: the pass's memo when there is one (it
    /// holds every block shown), else asked of the view model (the drag ghost).
    private func sendRowsFor(_ id: UUID, memo: [UUID: [SendRow]]?) -> [SendRow] {
        if let memo { return memo[id] ?? [] }
        return viewModel.sendRows(for: id)
    }

    /// nil = this group's block can be drawn in the shared Canvas (`GroupBlocksCanvas`): a plain
    /// group, selected or not. Otherwise the reason it keeps `GroupBlockView`: an infinite
    /// bus (`InfiniteBusBandView`), a rename, a bake, an open consolidated object (its ✕ and
    /// spinner), a volume / pan / aux tool, a drag / trim / resize / fade preview, a loop (the
    /// composite repeats and the grips are views) — the FIRST one met, in this order (it IS the
    /// rule: the order is what decides what is read, hence what a hover re-evaluates).
    /// `forceRich` is the Debug A/B switch: every group back on its rich view (always false in
    /// Release). `richPreviews` is the fallback (`RenderPreferences`): the gestures' previews back
    /// on the rich views — by default the Canvas draws them (@see `BlockPreviewGeometry`).
    private func groupRichReason(_ entry: LaneEntry, forceRich: Bool, tools: ToolPartitionContext,
                                 richPreviews: Bool) -> RichReason? {
        // `entry.item` is a group: the partition only asks groups (it tests `isGroup` first).
        let item = entry.item
        if item.isInfiniteBus { return .infinite }
        #if DEBUG
        if forceRich { return .forceRich }
        #endif
        if viewModel.renamingID == item.id { return .rename }
        if viewModel.isBaking(item.id) { return .bake }
        // `isEditing` / `isPreviewing` (the latter is a subset of the former).
        if viewModel.editingPlacementID == item.id { return .editing }
        // The active tool's overlay (@see `toolRichReason`): the block aimed at, or one a viewport
        // edge cuts while the tool draws on it. The context was read ONCE for the pass, so that
        // `toolHoveredID` is read (and this layer re-evaluated on every hover) under the tools
        // that hover alone.
        if let why = toolRichReason(entry, isGroup: true, tools: tools) { return why }
        // The previews are the Canvas's (`CanvasGroup.preview`) unless the fallback is on.
        if richPreviews {
            if previewOffset(for: item) != nil { return .preview }
            if previewResizeDX(for: item) != 0 { return .preview }
            if previewTrimDX(for: item) != 0 { return .preview }
            if previewFadeIn(for: item) != nil || previewFadeOut(for: item) != nil { return .preview }
            if spillPlan(for: item.id) != nil { return .spill }
            // A looping group at rest is drawn by the Canvas (the composite repeats, the IN / OUT
            // grips are drawn) — and so is the DRAG of one of its bounds, unless the fallback is on.
            if loopRangeDrag?.id == item.id { return .loop }
        }
        return nil
    }

    /// Resolves what the Canvas needs for each group it draws (@see `CanvasGroup`), with the
    /// SELECTED ones last: they are drawn above the others, as their `zIndex(1)` put them.
    private func canvasGroups(for entries: [LaneEntry], selectedIDs: Set<UUID>,
                              toolOverlays: [UUID: CanvasToolOverlay] = [:],
                              previews: [UUID: BlockPreviewGeometry] = [:]) -> [CanvasGroup] {
        guard !entries.isEmpty else { return [] }
        let filterText = viewModel.filterText
        // Read ONCE, ahead of the loop: with nothing missing (the common case) the recursive
        // `containsMissingDescendant` is never asked.
        let nothingMissing = viewModel.missingPaths.isEmpty
        let resolved = entries.map { entry -> CanvasGroup in
            let item = entry.item
            let name = viewModel.displayName(of: item)
            let dim = (!filterText.isEmpty && !name.localizedCaseInsensitiveContains(filterText))
                || viewModel.isSoloDimmed(item.id)
            let shared = crossfadeSharedPx(for: item)
            return CanvasGroup(
                entry: entry,
                stem: viewModel.stemColor(for: item.id),
                selected: selectedIDs.contains(item.id),
                dim: dim,
                name: name,
                icon: ObjectKindIcon.name(for: item,
                                          isOpenConsolidate: viewModel.isInConsolidateEditStack(item.id)),
                missing: nothingMissing ? false : viewModel.containsMissingDescendant(item),
                mutedInMix: viewModel.isMutedInMix(item),
                expanded: item.showsChildrenInline,
                sharedLeading: shared.leading, sharedTrailing: shared.trailing,
                toolOverlay: toolOverlays[item.id],
                loopRange: previewLoopRange(for: item),
                preview: previews[item.id])
        }
        guard resolved.contains(where: { $0.selected }) else { return resolved }
        return resolved.filter { !$0.selected } + resolved.filter { $0.selected }
    }

    /// nil = this clip can be drawn in the shared Canvas (no SwiftUI need); otherwise the FIRST
    /// reason, in this order, it keeps a rich view (the order is the rule, @see `groupRichReason`).
    /// `forceRichSelected` is the Debug A/B switch (always false in Release, where the line that
    /// reads it does not exist). `richPreviews` is the fallback (`RenderPreferences`): the gestures'
    /// previews back on the rich views — by default the Canvas draws them.
    private func clipRichReason(_ entry: LaneEntry, forceRichSelected: Bool = false,
                                tools: ToolPartitionContext, richPreviews: Bool) -> RichReason? {
        let item = entry.item
        // A MIDI clip is drawn by the Canvas (its notes: `MidiNotesDrawing`) unless its piano roll
        // is open (or, with the fallback on, its loop's IN / OUT is being dragged).
        // An aux is drawn by the Canvas too (its glyph chequerboard: `GlyphTileDrawing`), except an
        // INFINITE one, which `InfiniteBusBandView` replaces (the same reason as an infinite group).
        switch item.kind {
        case .clip: break
        case .midiClip:
            if item.showsPianoRollInline { return .midi }
            if richPreviews, loopRangeDrag?.id == item.id { return .preview }
        case .aux:
            if item.isInfiniteBus { return .infinite }
        case .group:
            return .aux   // the partition never asks a group here (it tests `isGroup` first)
        }
        // A SELECTED clip is drawn in the Canvas like any other (it used to be excluded here: a
        // few hundred selected clips were a few hundred rich views, and the timeline fell to
        // 2 fps). The Debug A/B switch puts the old behaviour back (@see `DebugRenderSwitches`).
        #if DEBUG
        if forceRichSelected && viewModel.isSelected(item.id) { return .forceRich }
        #endif
        if viewModel.renamingID == item.id { return .rename }
        if viewModel.isBaking(item.id) { return .bake }
        // An instance of a consolidated object AT REST is drawn by the Canvas (its indigo ring and
        // its badges). What animates stays rich: the automatic re-bake under way (its filling
        // circle) and the opening for editing (its ✕ and spinner). A bake is tested above.
        if item.isConsolidateInstance {
            if viewModel.editingPlacementID == item.id { return .editing }
            if let defID = item.consolidateID, viewModel.recomputingConsolidateIDs.contains(defID) {
                return .consolidate
            }
        }
        // A custom colour (its name band and its border) is drawn by the Canvas: @see phase 1 of
        // `plainBlocksCanvas`, `CustomColorBatch`.
        // The active tool's overlay (@see `toolRichReason`).
        if let why = toolRichReason(entry, isGroup: false, tools: tools) { return why }
        // A drag/preview under way on this clip: the Canvas draws it (`BlockPreviewGeometry`, in
        // `plainBlocksCanvas`) — unless the fallback is on, which puts the live SwiftUI view back.
        if richPreviews {
            if previewOffset(for: item) != nil { return .preview }
            if previewResizeDX(for: item) != 0 { return .preview }
            if previewTrimDX(for: item) != 0 { return .preview }
            if previewFadeIn(for: item) != nil || previewFadeOut(for: item) != nil { return .preview }
            // The NEIGHBOUR of a spilling fade moves too, and it is in none of the drag's id sets:
            // without this it stayed in the batched Canvas, motionless, until the mouse came up.
            if spillPlan(for: item.id) != nil { return .spill }
        }
        return nil
    }

    /// It triggers the loading of the waveforms of the Canvas blocks (which no longer have a
    /// SoundBlockView's `.onAppear`). `load` is idempotent; we defer it outside the render so
    /// as not to mutate state while the body is being evaluated.
    /// The groups the Canvas draws load their DIRECT clip children's waveforms, as `groupBlock`'s
    /// `.onAppear` did for the rich view (the composite reads them).
    private func ensureWaveformsLoaded(_ entries: [LaneEntry], groups: [CanvasGroup] = []) {
        guard !entries.isEmpty || !groups.isEmpty else { return }
        // Only the clips have a file: a MIDI clip's path is empty, and loading "" would spawn a task per pass.
        var paths = entries.compactMap { $0.item.isClip ? $0.item.filePath : nil }
        for g in groups {
            if case .group(let children, _) = g.item.kind {
                for child in children {
                    if case .clip(let fp, _, _, _, _) = child.kind { paths.append(fp) }
                }
            }
        }
        DispatchQueue.main.async {
            for p in paths { waveformCache.load(filePath: p) }
        }
    }

    /// `selectedIDs`: a selected clip is painted as `SoundBlockView` paints it — a stronger tint
    /// (0.55 against 0.30), a bright border (0.9 against 0.3), a full-opacity waveform — and above
    /// its neighbours (drawn after them, as its `zIndex(1)` used to put it). Everything about the
    /// selection that is not a PAINT (hit-testing, hover, drags) is resolved on `laneEntries` by
    /// the parent canvas and does not pass through here.
    ///
    /// `toolOverlays`: what the active tool lays over the blocks drawn here (resolved by the body,
    /// like everything else this closure reads), drawn in the final phase between the fades and the
    /// mute veil, as the rich views stack them. `hidesClipMuteVeil`: under the Volume tool a CLIP
    /// shows no mute veil (its own red tint says it), a group's stays.
    private func plainBlocksCanvas(_ entries: [LaneEntry], groups: [CanvasGroup],
                                   selectedIDs: Set<UUID>,
                                   rows: (y0: Double, y1: Double),
                                   secPerBeat: Double,
                                   consolidated: [UUID: ConsolidateBadge] = [:],
                                   toolOverlays: [UUID: CanvasToolOverlay] = [:],
                                   previews: [UUID: BlockPreviewGeometry] = [:],
                                   hidesClipMuteVeil: Bool = false,
                                   sticky: StickyLabelPass? = nil) -> some View {
        Canvas { ctx, _ in
                // The sticky pass is a second draw of the SAME layer's names, not a frame of the
                // blocks: it must not count as one.
                if !(sticky?.isStickyPass ?? false) { TimelineRegimeMeter.recordCanvasDraw() }
                // The geometry, read ONCE per pass. `rulerHeight`, `blockHeight` and `laneStep` are
                // computed from observable properties of the view model, and `rectFor` / `look`
                // below read them per block and per phase: 600 blocks paid ~20 % of this closure
                // in `ObservationRegistrar.access` alone (`sample`, Release, a zoom, E8). Locals
                // of the same names, so every use below reads the value and not the property.
                let rulerHeight = self.rulerHeight
                let blockHeight = self.blockHeight
                let laneStep = self.laneStep
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
                // What ONE clip is drawn with: its stored values, or — for a block a gesture is
                // previewing — `BlockPreviewGeometry`'s (the SAME the rich view reads: where it
                // stands, how long it is, the fades the crop leaves it, the source offset its
                // waveform is read from). Never a write: the model is untouched until the release.
                func look(_ entry: LaneEntry) -> CanvasBlockLook {
                    let item = entry.item
                    if !previews.isEmpty, let g = previews[item.id] {
                        return CanvasBlockLook(
                            rect: CGRect(x: g.xPos,
                                         y: g.yPos(rulerHeight: rulerHeight, displayLane: entry.displayLane,
                                                   laneStep: laneStep),
                                         width: g.blockWidth, height: blockHeight),
                            sourceOffset: g.effectiveSourceOffset, duration: g.effectiveDuration,
                            fadeIn: g.effectiveFadeIn, fadeOut: g.effectiveFadeOut,
                            curveIn: g.effectiveFadeInCurve, curveOut: g.effectiveFadeOutCurve,
                            loopRange: g.previewLoopRange, trimDX: g.trimDX)
                    }
                    return CanvasBlockLook(
                        rect: rectFor(entry), sourceOffset: item.sourceOffset, duration: item.duration,
                        fadeIn: item.fadeIn, fadeOut: item.fadeOut,
                        curveIn: item.fadeInCurve, curveOut: item.fadeOutCurve,
                        loopRange: item.loopMarkerLocalRange, trimDX: 0)
                }

                // ── The names (declared ahead of phase 1: the STICKY pass below needs them) ──
                // @see StickyLabel. A block's name is anchored to the start of its VISIBLE part, so
                // a long object scrolled past its start keeps a name on screen. The notch-driven
                // pass draws every name that does not depend on the exact scroll; the ones that
                // might (those starting within the culling notch, `StickyLabel.isLive`) are left to
                // the sticky pass — this same function run again by `StickyScrollReader`, which
                // reads the exact scroll and draws nothing else. The two partition the names by
                // the same predicate, so none is drawn twice or lost.
                var labelCache = CanvasLabelCache()
                func resolvedLabel(_ s: String, icon: String, missing: Bool,
                                   meta: String, muteBadge: Bool) -> GraphicsContext.ResolvedText {
                    labelCache.resolve(ctx, s, icon: icon, missing: missing, meta: meta, muteBadge: muteBadge)
                }
                // Read ONCE, ahead of the drawing loop and not per block. `isMissing` is a pure
                // dictionary lookup — that is exactly why it may be read from a drawing pass at
                // all (@see EditViewModel+MissingFiles) — but the loop below is the one that runs
                // per block per frame, and it has no business asking the view model anything.
                // The emptiness test is the common case and it is worth its line: with nothing
                // missing the whole pass collapses to one question per frame instead of one per
                // block (the same early-out `missingFileCount` makes).
                var missingIDs = Set<UUID>()
                if !viewModel.missingPaths.isEmpty {
                    for entry in entries where viewModel.isMissing(entry.item) {
                        missingIDs.insert(entry.item.id)
                    }
                }
                // ONE block's name: the glyph, the name, the META summary and the MUTE badge in one
                // run, cropped to the block. Its place is the natural one (5 px past the fade-in
                // triangle, or 8 px with none) unless a sticky pass partitions the names.
                func drawClipLabel(_ entry: LaneEntry, _ blockLook: CanvasBlockLook) {
                    let item = entry.item
                    let w = blockLook.w
                    guard w > 10 else { return }   // unreadable/skipped below 10px — the zoomed-out case
                    let rect = blockLook.rect
                    // Same rule as the rich views: the name starts 5 px past the fade-in
                    // triangle, or 8 px with none, computed here since the label can show with
                    // no fade at all.
                    let leading = TimelineLabelMetrics.leading(fadeInPx: blockLook.fadeIn * pixelsPerSecond,
                                                                blockWidth: w)
                    var labelX = rect.minX + leading
                    if let sticky {
                        guard let placed = sticky.placement(naturalX: labelX, blockX: rect.minX,
                                                            blockWidth: w, rightLimit: rect.maxX)
                        else { return }
                        labelX = placed
                    }
                    var lc = ctx
                    if isDim(item) { lc.opacity = 0.25 }
                    lc.clip(to: Path(rect))
                    let missing = missingIDs.contains(item.id)
                    if missing {
                        // The white glow the rich views lay with `.shadow`: the red alone does
                        // not survive a band tinted red or salmon, and the band's base is white
                        // whatever the tint (@see MissingFileLabel.haloColor). A filter forces
                        // this one block offscreen, which is why it is armed for the missing
                        // ones only — a project where that costs is a project already broken.
                        lc.addFilter(.shadow(color: MissingFileLabel.haloColor,
                                             radius: MissingFileLabel.haloRadius, x: 0, y: 0))
                    }
                    // The meta is asked for only when the numbers say it is not empty: the guard
                    // is `timelineMetaSummary`'s own conditions, so it allocates nothing for
                    // the common clip (0 dB, centred, ×1), which is nearly all of them.
                    let hasMeta = w >= 60
                        && (item.volume <= -96 || abs(item.volume) >= 0.5
                            || abs(item.pan) >= 0.01 || abs(item.speedRatio - 1.0) >= 0.01)
                    lc.draw(resolvedLabel(item.displayName,
                                          icon: ObjectKindIcon.name(for: item),
                                          missing: missing,
                                          meta: hasMeta ? item.timelineMetaSummary : "",
                                          muteBadge: w >= 30 && item.isMuted),
                            // The same top inset as the rich views (@see TimelineLabelMetrics).
                            at: CGPoint(x: labelX,
                                        y: rect.minY + TimelineLabelMetrics.topInset + TimelineLabelMetrics.canvasCentring),
                            anchor: .topLeading)
                }
                // The STICKY pass: only the names that follow the exact scroll, nothing else.
                if let sticky, sticky.isStickyPass {
                    let selectedNow = selectedIDs
                    // The rows on screen only: this pass runs at every frame of a scroll.
                    func onRows(_ l: CanvasBlockLook) -> Bool {
                        l.rect.maxY >= rows.y0 && l.rect.minY <= rows.y1
                    }
                    // Unselected first, selected last, as the ordinary pass walks the blocks.
                    for entry in entries where !selectedNow.contains(entry.item.id) {
                        let l = look(entry)
                        if onRows(l) { drawClipLabel(entry, l) }
                    }
                    for entry in entries where selectedNow.contains(entry.item.id) {
                        let l = look(entry)
                        if onRows(l) { drawClipLabel(entry, l) }
                    }
                    GroupBlocksCanvas.drawStickyLabels(into: ctx, groups: groups, rows: rows,
                                                       geo: GroupBlocksCanvas.Geometry(
                                                           pixelsPerSecond: pixelsPerSecond, rulerHeight: rulerHeight,
                                                           laneStep: laneStep, blockHeight: blockHeight),
                                                       labels: &labelCache, sticky: sticky)
                    return
                }

                // ── Phase 1: BATCHED BACKGROUNDS ──────────────────────────────────────
                // The cost when scrolling zoomed out = ~936 drawing calls (2 fills + 1 border × N),
                // NOT the text (already skipped) or the waveform (a sliver). We accumulate one Path per
                // stem colour (there are few stems) → 3 ops per colour instead of 3 × N.
                // SELECTED clips are batched apart (their tint and border are stronger) and drawn
                // AFTER every unselected one, so that in a crossfade's shared span the selected one
                // sits above its neighbour's tint, as its rich view's `zIndex(1)` did. The
                // waveforms below are all drawn after ALL the backgrounds, which is what keeps the
                // neighbour's waveform visible through the selected clip's white base.
                var rects: [Color: Path] = [:]
                var rectsDim: [Color: Path] = [:]
                var rectsSel: [Color: Path] = [:]
                var rectsSelDim: [Color: Path] = [:]
                // The clips carrying their OWN colour (@see `CustomColorBatch`), batched the same
                // way: by (selected, dim), then by (custom colour, stem colour).
                var custom: [CustomColorKey: CustomColorBatch] = [:]
                var customDim: [CustomColorKey: CustomColorBatch] = [:]
                var customSel: [CustomColorKey: CustomColorBatch] = [:]
                var customSelDim: [CustomColorKey: CustomColorBatch] = [:]
                var anySelected = false
                for entry in entries {
                    let item = entry.item
                    let rect = look(entry).rect
                    let r = item.blockCornerRadius
                    let stem = viewModel.stemColor(for: item.id)
                    let selected = selectedIDs.contains(item.id)
                    if selected { anySelected = true }
                    let dim = isDim(item)
                    if let own = item.customColor {
                        // Bounded to the rows on screen, too (the plain path below is not: a Path
                        // of rounded rects is cheap and this is not the loop that costs).
                        guard rect.maxY >= rows.y0, rect.minY <= rows.y1 else { continue }
                        let key = CustomColorKey(custom: own, stem: stem)
                        switch (selected, dim) {
                        case (false, false): custom[key, default: .init()].add(rect, radius: r, blockHeight: blockHeight)
                        case (false, true):  customDim[key, default: .init()].add(rect, radius: r, blockHeight: blockHeight)
                        case (true, false):  customSel[key, default: .init()].add(rect, radius: r, blockHeight: blockHeight)
                        case (true, true):   customSelDim[key, default: .init()].add(rect, radius: r, blockHeight: blockHeight)
                        }
                        continue
                    }
                    var rr = Path()
                    rr.addRoundedRect(in: rect, cornerSize: CGSize(width: r, height: r))
                    switch (selected, dim) {
                    case (false, false): rects[stem, default: Path()].addPath(rr)
                    case (false, true):  rectsDim[stem, default: Path()].addPath(rr)
                    case (true, false):  rectsSel[stem, default: Path()].addPath(rr)
                    case (true, true):   rectsSelDim[stem, default: Path()].addPath(rr)
                    }
                }
                // The values are `SoundBlockView`'s own: tint 0.30 / 0.55, border 0.3 / 0.9, 1.5 pt.
                // The border stays CENTRED on the path (half of it outside the block, unlike the
                // rich view's inset stroke) for both states, so selecting does not move it.
                func fillBackgrounds(_ groups: [Color: Path], opacity: Double, selected: Bool) {
                    guard !groups.isEmpty else { return }
                    var c = ctx; c.opacity = opacity
                    for (color, path) in groups {
                        c.fill(path, with: .color(.white))
                        c.fill(path, with: .color(color.opacity(selected ? 0.55 : 0.30)))
                        c.stroke(path, with: .color(color.opacity(selected ? 0.9 : 0.3)), lineWidth: 1.5)
                    }
                }
                // A block with its own colour: white base, the name band in that colour over its
                // top 20 % (at least 3 pt), the body in the stem's, and the border in the OWN colour
                // (`effectiveColor` in the rich view).
                func fillCustomBackgrounds(_ groups: [CustomColorKey: CustomColorBatch],
                                           opacity: Double, selected: Bool) {
                    guard !groups.isEmpty else { return }
                    var c = ctx; c.opacity = opacity
                    let tint = selected ? 0.55 : 0.30
                    for (key, batch) in groups {
                        c.fill(batch.full, with: .color(.white))
                        c.fill(batch.band, with: .color(key.custom.opacity(tint)))
                        c.fill(batch.body, with: .color(key.stem.opacity(tint)))
                        c.stroke(batch.full, with: .color(key.custom.opacity(selected ? 0.9 : 0.3)), lineWidth: 1.5)
                    }
                }
                fillBackgrounds(rects, opacity: 1.0, selected: false)
                fillCustomBackgrounds(custom, opacity: 1.0, selected: false)
                fillBackgrounds(rectsDim, opacity: 0.25, selected: false)
                fillCustomBackgrounds(customDim, opacity: 0.25, selected: false)
                fillBackgrounds(rectsSel, opacity: 1.0, selected: true)
                fillCustomBackgrounds(customSel, opacity: 1.0, selected: true)
                fillBackgrounds(rectsSelDim, opacity: 0.25, selected: true)
                fillCustomBackgrounds(customSelDim, opacity: 0.25, selected: true)
                // The GROUPS' blocks (`GroupBlocksCanvas`): above the clips' backgrounds, as a rich
                // `GroupBlockView` (z 0) sat above the Canvas, and before every waveform below.
                let groupGeo = GroupBlocksCanvas.Geometry(
                    pixelsPerSecond: pixelsPerSecond, rulerHeight: rulerHeight,
                    laneStep: laneStep, blockHeight: blockHeight)
                GroupBlocksCanvas.drawBackgrounds(into: ctx, groups: groups, geo: groupGeo)
                // The order the next two phases walk the blocks in: unselected first, selected last.
                let drawOrder: [LaneEntry] = anySelected
                    ? entries.filter { !selectedIDs.contains($0.item.id) }
                        + entries.filter { selectedIDs.contains($0.item.id) }
                    : entries

                // ── Phase 2: WAVEFORMS BATCHED by fill colour ────────────────────────
                // Instead of N fill/strokes (≈14 ms at 240 blocks), we accumulate one Path per colour
                // and fill once. Skipped below 3px (an invisible sliver). Filtered (dimmed) blocks and
                // 'samples' mode (extreme zoom) are drawn separately.
                var waveFills: [Color: Path] = [:]
                // The hairline between a stereo file's two lanes, batched like the fills: one Path
                // per base colour (the stem's, or grey when muted — the colour the rich view strokes
                // it in, @see WaveformDrawing.laneSeparatorOpacity), stroked once each.
                var laneSeparators: [Color: Path] = [:]
                var loopMarkers = Path()
                // A selected clip's loop marks are stroked as its rich view's waveform strokes
                // them (the stem's colour at 0.6), not in the unselected clips' black.
                var loopMarkersSel: [Color: Path] = [:]
                // The MIDI clips' notes (@see `MidiNotesDrawing`), batched by (colour, velocity, dim).
                var midiFills: [MidiNotesDrawing.FillKey: Path] = [:]
                for entry in drawOrder {
                    let item = entry.item
                    let blockLook = look(entry)
                    let w = blockLook.w
                    let selected = selectedIDs.contains(item.id)
                    let rect = blockLook.rect
                    let x = rect.minX, y = rect.minY
                    let stem = viewModel.stemColor(for: item.id)

                    if item.isMIDI {
                        // No waveform: the notes, in the stem's colour whatever the block's own
                        // colour, bounded to the viewport's columns and rows.
                        guard rect.maxY >= rows.y0, rect.minY <= rows.y1 else { continue }
                        MidiNotesDrawing.append(
                            to: &midiFills, origin: CGPoint(x: x, y: y), notes: item.midiNotes,
                            secPerBeat: secPerBeat, pixelsPerSecond: pixelsPerSecond,
                            // A left trim reveals, it does not move the notes (as the rich view's
                            // `xOffset: -previewTrimDX`).
                            xOffset: -blockLook.trimDX,
                            size: CGSize(width: w, height: blockHeight),
                            loopRange: blockLook.loopRange,
                            visibleX: (Double(cullScrollX) - x - 1)...(Double(cullScrollX) + Double(cullViewportWidth) - x + 1),
                            color: stem, muted: item.isMuted, dim: isDim(item))
                        continue
                    }
                    if item.isAux {
                        // No waveform: the 'receives' glyph chequerboard in the block's effective
                        // colour, clipped to its (large) rounded corners, and bounded to the
                        // viewport's columns and rows.
                        guard rect.maxY >= rows.y0, rect.minY <= rows.y1 else { continue }
                        var ac = ctx
                        if isDim(item) { ac.opacity = 0.25 }
                        ac.clip(to: RoundedRectangle(cornerRadius: item.blockCornerRadius).path(in: rect))
                        ac.translateBy(x: x, y: y)
                        GlyphTileDrawing.draw(
                            into: ac, size: CGSize(width: w, height: blockHeight),
                            color: (item.customColor ?? stem).opacity(0.7), tile: 30, glyphSize: 17,
                            iconName: "arrow.down.right.circle",
                            visibleX: (Double(cullScrollX) - x - 1)...(Double(cullScrollX) + Double(cullViewportWidth) - x + 1))
                        continue
                    }
                    guard w >= 3 else { continue }

                    if isDim(item) {
                        // Filtered: an individual opacity → drawn directly.
                        var wc = ctx; wc.opacity = 0.25; wc.translateBy(x: x, y: y)
                        WaveformDrawing.draw(
                            into: wc, size: CGSize(width: w, height: blockHeight),
                            waveformCache: waveformCache, filePath: item.filePath,
                            sourceOffset: blockLook.sourceOffset, pixelsPerSecond: pixelsPerSecond,
                            scrollOffsetX: cullScrollX, viewportWidth: cullViewportWidth, xPos: x,
                            stemColor: stem, isSelected: selected,
                            clipDuration: blockLook.duration, speedRatio: item.speedRatio,
                            isReversed: item.isReversed, volumeDb: item.waveformDisplayGainDb,
                            fadeIn: blockLook.fadeIn, fadeOut: blockLook.fadeOut,
                            curveIn: blockLook.curveIn, curveOut: blockLook.curveOut,
                            isMuted: isMutedItem(item), waveformDisplayDB: waveformDisplayDB,
                            loopRange: blockLook.loopRange,
                            channelMode: item.channelMode)
                        continue
                    }

                    // The batch key IS the colour, opacity included — (stem, selected, muted) in
                    // one value, the same one `WaveformDrawing.draw` fills with.
                    let fillColor: Color = isMutedItem(item) ? Color.gray.opacity(0.45)
                                                             : stem.opacity(selected ? 1.0 : 0.95)
                    let separatorColor: Color = isMutedItem(item) ? .gray : stem
                    let handled = WaveformDrawing.appendPeaksFill(
                        to: &waveFills[fillColor, default: Path()],
                        separators: &laneSeparators[separatorColor, default: Path()],
                        originX: x, originY: y, size: CGSize(width: w, height: blockHeight),
                        waveformCache: waveformCache, filePath: item.filePath,
                        sourceOffset: blockLook.sourceOffset, pixelsPerSecond: pixelsPerSecond,
                        scrollOffsetX: cullScrollX, viewportWidth: cullViewportWidth,
                        clipDuration: blockLook.duration, speedRatio: item.speedRatio,
                        isReversed: item.isReversed, volumeDb: item.waveformDisplayGainDb,
                        fadeIn: blockLook.fadeIn, fadeOut: blockLook.fadeOut,
                        curveIn: blockLook.curveIn, curveOut: blockLook.curveOut,
                        waveformDisplayDB: waveformDisplayDB, loopRange: blockLook.loopRange,
                        channelMode: item.channelMode)
                    if !handled {
                        // Samples mode (extreme zoom, few blocks) → drawn individually and in full.
                        var wc = ctx; wc.translateBy(x: x, y: y)
                        WaveformDrawing.draw(
                            into: wc, size: CGSize(width: w, height: blockHeight),
                            waveformCache: waveformCache, filePath: item.filePath,
                            sourceOffset: blockLook.sourceOffset, pixelsPerSecond: pixelsPerSecond,
                            scrollOffsetX: cullScrollX, viewportWidth: cullViewportWidth, xPos: x,
                            stemColor: stem, isSelected: selected,
                            clipDuration: blockLook.duration, speedRatio: item.speedRatio,
                            isReversed: item.isReversed, volumeDb: item.waveformDisplayGainDb,
                            fadeIn: blockLook.fadeIn, fadeOut: blockLook.fadeOut,
                            curveIn: blockLook.curveIn, curveOut: blockLook.curveOut,
                            isMuted: isMutedItem(item), waveformDisplayDB: waveformDisplayDB,
                            loopRange: blockLook.loopRange,
                            channelMode: item.channelMode)
                    } else if let loopLocal = blockLook.loopRange {
                        // `appendPeaksFill` only lays the fill (batched by colour): the loop marks are
                        // drawn separately, in coordinates LOCAL to the block, translated here as the
                        // 'samples' drawing already does.
                        var block = Path()
                        WaveformDrawing.appendLoopMarkers(
                            to: &block, blockOriginX: x, size: CGSize(width: w, height: blockHeight),
                            pixelsPerSecond: pixelsPerSecond,
                            scrollOffsetX: cullScrollX, viewportWidth: cullViewportWidth,
                            clipDuration: blockLook.duration, isReversed: item.isReversed,
                            loopRange: loopLocal)
                        let placed = block.applying(CGAffineTransform(translationX: x, y: y))
                        if selected { loopMarkersSel[separatorColor, default: Path()].addPath(placed) }
                        else        { loopMarkers.addPath(placed) }
                    }
                }
                for (color, path) in waveFills { ctx.fill(path, with: .color(color)) }
                MidiNotesDrawing.fill(midiFills, into: ctx)
                for (color, path) in laneSeparators where !path.isEmpty {
                    ctx.stroke(path, with: .color(color.opacity(WaveformDrawing.laneSeparatorOpacity)),
                               lineWidth: 1)
                }
                if !loopMarkers.isEmpty {
                    ctx.stroke(loopMarkers, with: .color(.black.opacity(0.35)),
                              style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                }
                for (color, path) in loopMarkersSel {
                    ctx.stroke(path, with: .color(color.opacity(0.6)),
                               style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                }

                GroupBlocksCanvas.drawComposites(
                    into: ctx, groups: groups, geo: groupGeo, waveformCache: waveformCache,
                    waveformDisplayDB: waveformDisplayDB,
                    scrollOffsetX: cullScrollX, viewportWidth: cullViewportWidth)

                // ── Phase 3: FADES / MUTE / LABEL per block (over the waveform) ──────
                // Skipped when the block is too narrow → when scrolling zoomed out, an empty loop.
                // The run's construction and its two caches live in `CanvasLabelCache` (shared with
                // the groups' pass, so the two regimes build the glyph + name + meta + badge run
                // from ONE definition). The GLYPH travels INSIDE the resolved text rather than
                // being drawn as a second image beside it: `Text(Image(systemName:))` lays out and
                // styles as a character, so the kind and the name are one run — one resolve, one
                // cache entry, one `draw`, cropped together by the clip to the block's width. The
                // key carries the icon as well as the name (two clips can share a name and not a
                // kind), the META summary and the MUTE badge (9 pt, in the same run, on the name's
                // baseline where the rich row centres them: a pixel's difference, and the price of
                // not measuring text per block per frame).
                // The consolidated instances' rings, by (unselected, unselected dim, selected, selected dim).
                var ringPaths = (Path(), Path(), Path(), Path())
                for entry in drawOrder {
                    let item = entry.item
                    let blockLook = look(entry)
                    let w = blockLook.w
                    let needsLabel = w > 10
                    let needsFade  = blockLook.fadeIn > 0 || blockLook.fadeOut > 0
                    let needsMute  = isMutedItem(item) && !hidesClipMuteVeil
                    let toolOverlay = toolOverlays[item.id]
                    // The loop's grips (a bar and a flag at each bound) belong to a SELECTED clip, as
                    // they do in its rich view: they are what one takes hold of to move IN / OUT.
                    // A MIDI clip shows them whether selected or not, as its rich view always did.
                    let loopGrips = (selectedIDs.contains(item.id) || item.isMIDI) && !item.isReversed
                        ? blockLook.loopRange : nil
                    let consolidatedBadge = consolidated[item.id]
                    guard needsLabel || needsFade || needsMute || loopGrips != nil || toolOverlay != nil
                            || consolidatedBadge != nil else { continue }

                    let rect = blockLook.rect
                    let x = rect.minX, y = rect.minY
                    var c = ctx
                    if isDim(item) { c.opacity = 0.25 }

                    if needsFade {
                        // The veil follows the CURVE here too. It used to be a straight triangle
                        // whatever the shape said, so a fade drawn bent while its block was
                        // selected went straight again the moment it was deselected and fell back
                        // into this Canvas — the same `FadeVeilShape` path settles it (measured on
                        // a bent fade, 9 September 2026).
                        let box = CGRect(x: 0, y: 0, width: w, height: blockHeight)
                        let move = CGAffineTransform(translationX: x, y: y)
                        let fiPx = blockLook.fadeIn * pixelsPerSecond
                        let foPx = blockLook.fadeOut * pixelsPerSecond
                        if fiPx > 0 {
                            c.fill(FadeVeilShape.path(curve: blockLook.curveIn, widthPx: fiPx,
                                                      side: .in, in: box).applying(move),
                                   with: .color(.black.opacity(0.30)))
                        }
                        if foPx > 0 {
                            c.fill(FadeVeilShape.path(curve: blockLook.curveOut, widthPx: foPx,
                                                      side: .out, in: box).applying(move),
                                   with: .color(.black.opacity(0.30)))
                        }
                    }

                    if let loopGrips {
                        var grips = Path()
                        LoopRangeMarkersView.appendGrips(
                            to: &grips, originX: x, originY: y,
                            startPx: loopGrips.start * pixelsPerSecond, endPx: loopGrips.end * pixelsPerSecond,
                            blockWidth: w, blockHeight: blockHeight)
                        var gc = c
                        gc.addFilter(.shadow(color: .black.opacity(0.5), radius: 1))
                        gc.fill(grips, with: .color(item.customColor ?? viewModel.stemColor(for: item.id)))
                    }

                    // The active tool's overlay: over the waveform, the fades and the loop's grips,
                    // under the mute veil (which lies on top of it, as in the rich view).
                    if let toolOverlay {
                        var oc = c
                        oc.translateBy(x: x, y: y)
                        drawToolOverlay(oc, toolOverlay, size: CGSize(width: w, height: blockHeight))
                    }

                    if needsMute {
                        var rr = Path()
                        let veilR = item.blockCornerRadius
                        rr.addRoundedRect(in: rect, cornerSize: CGSize(width: veilR, height: veilR))
                        c.fill(rr, with: .color(.black.opacity(0.38)))
                    }

                    // A consolidated instance: the indigo ring (batched, stroked after the loop) and
                    // the badges, over the mute veil and under the label, as the rich view stacks them.
                    if let badge = consolidatedBadge {
                        let ring = RoundedRectangle(cornerRadius: item.blockCornerRadius)
                            .inset(by: 0.75).path(in: rect)
                        switch (selectedIDs.contains(item.id), isDim(item)) {
                        case (false, false): ringPaths.0.addPath(ring)
                        case (false, true):  ringPaths.1.addPath(ring)
                        case (true, false):  ringPaths.2.addPath(ring)
                        case (true, true):   ringPaths.3.addPath(ring)
                        }
                        if w >= 14 {
                            let corner = CGPoint(x: x + w - 3, y: y + 3)
                            if badge.stale {
                                c.draw(GlyphResolveCache.shared.glyph("exclamationmark.triangle.fill", size: 9,
                                                                       weight: .bold, color: .orange, in: ctx),
                                       at: corner, anchor: .topTrailing)
                            }
                            if badge.resynced {
                                c.draw(GlyphResolveCache.shared.glyph("checkmark.circle.fill", size: 11,
                                                                       weight: .bold, color: .green, in: ctx),
                                       at: corner, anchor: .topTrailing)
                            }
                        }
                    }

                    // The label cropped to the block (@see `drawClipLabel`, declared with the sticky pass).
                    if needsLabel { drawClipLabel(entry, blockLook) }
                }

                func strokeRings(_ path: Path, opacity: Double, selected: Bool) {
                    guard !path.isEmpty else { return }
                    var rc = ctx; rc.opacity = opacity
                    rc.stroke(path, with: .color(Color.indigo.opacity(selected ? 0.95 : 0.6)), lineWidth: 1.5)
                }
                strokeRings(ringPaths.0, opacity: 1.0, selected: false)
                strokeRings(ringPaths.1, opacity: 0.25, selected: false)
                strokeRings(ringPaths.2, opacity: 1.0, selected: true)
                strokeRings(ringPaths.3, opacity: 0.25, selected: true)

                // The groups' fades, mute veil and name row, over their composites.
                GroupBlocksCanvas.drawOverlays(into: ctx, groups: groups, geo: groupGeo,
                                               labels: &labelCache, sticky: sticky)
        }
        .frame(width: totalDuration * pixelsPerSecond, height: canvasHeight, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func altGhostsLayer(selectedIDs: Set<UUID>) -> some View {
        // Alt+drag ghosts. By default ONE Canvas draws them all (the same
        // `plainBlocksCanvas` the blocks use, each ghost previewed at its travel through
        // `BlockPreviewGeometry`) and a second one the "+" badges; the fallback
        // `RenderPreferences.richPreviews` puts back one rich view per ghost.
        let ghosts = altDragGhosts
        let richGhosts = RenderPreferences.shared.richPreviews
        // The ForEach of rich ghosts is a layer like the others (0 elements when the Canvas draws them).
        let _ = TimelineRegimeMeter.recordLayer("alt_ghosts", elements: richGhosts ? ghosts.count : 0)
        if richGhosts {
            ForEach(ghosts, id: \.object.id) { ghost in
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
        } else if !ghosts.isEmpty {
            // Only the ghosts the viewport can see (the rich ghosts were not culled at all).
            let ghostMargin = 80.0
            let ghostX0 = Double(cullScrollX) - ghostMargin
            let ghostX1 = Double(cullScrollX) + Double(cullViewportWidth) + ghostMargin
            let shown = ghosts.filter {
                let x = $0.object.startTime * pixelsPerSecond + $0.dx
                return x + max(2, $0.object.duration * pixelsPerSecond) >= ghostX0 && x <= ghostX1
            }
            let ghostEntries = shown.map {
                LaneEntry(displayLane: 0, item: $0.object, absStart: $0.object.startTime,
                          depth: 0, parentID: nil, expandedSpan: 0)
            }
            let ghostPreviews = Dictionary(
                shown.map { ($0.object.id, BlockPreviewGeometry(
                    object: $0.object, pixelsPerSecond: pixelsPerSecond,
                    previewOffset: ($0.dx, $0.dy))) },
                uniquingKeysWith: { first, _ in first })
            let _ = ensureWaveformsLoaded(ghostEntries)
            plainBlocksCanvas(ghostEntries, groups: [], selectedIDs: selectedIDs,
                              rows: cullRows,
                              secPerBeat: 60.0 / viewModel.tempo,
                              previews: ghostPreviews)
                .opacity(0.6)
                .zIndex(2)
            altCopyBadgesCanvas(shown.map {
                CGPoint(x: $0.object.startTime * pixelsPerSecond + $0.dx + 6,
                        y: rulerHeight + Double($0.object.lane) * laneStep + $0.dy + 6)
            })
            .zIndex(2.1)
        }
    }

    /// The green "+" a ⌥-drag lays at the top-left of each ghost (a copy is being made). ONE Canvas
    /// for all of them, `origins` being the top-left of each badge in canvas coordinates: the same
    /// 18 pt disc and 11 pt bold plus the rich ghost carried.
    private func altCopyBadgesCanvas(_ origins: [CGPoint]) -> some View {
        Canvas { ctx, _ in
            let plus = GlyphResolveCache.shared.glyph("plus", size: 11, weight: .bold,
                                                      color: .white, in: ctx)
            for o in origins {
                ctx.fill(Path(ellipseIn: CGRect(x: o.x, y: o.y, width: 18, height: 18)),
                         with: .color(.green))
                ctx.draw(plus, at: CGPoint(x: o.x + 9, y: o.y + 9), anchor: .center)
            }
        }
        .frame(width: totalDuration * pixelsPerSecond, height: canvasHeight, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func groupBlock(for group: SoundObject, displayLane dl: Int,
                            sendRows memo: [UUID: [SendRow]]? = nil) -> some View {
        let shared = crossfadeSharedPx(for: group)   // once per block, not once per end
        return GroupBlockView(
            group: group,
            displayName: viewModel.displayName(of: group),
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
            containsMissingFile: viewModel.containsMissingDescendant(group),
            isOpenConsolidate: viewModel.isInConsolidateEditStack(group.id),
            displayLane: dl,
            scrollOffsetX: cullScrollX,
            viewportWidth: cullViewportWidth,
            liveScroll: liveScroll,
            waveformDisplayDB: waveformDisplayDB,
            previewOffset:   previewOffset(for: group),
            previewResizeDX: previewResizeDX(for: group),
            previewTrimDX:   previewTrimDX(for: group),
            previewFadeIn:   previewFadeIn(for: group),
            previewFadeOut:  previewFadeOut(for: group),
            previewFadeInCurve:  previewFadeCurveIn(for: group),
            previewFadeOutCurve: previewFadeCurveOut(for: group),
            sharedLeadingPx:  shared.leading,
            sharedTrailingPx: shared.trailing,
            previewLoopRange: previewLoopRange(for: group),
            isToolHovered:   toolHoveredID == group.id,
            stemAssignTarget: stemAssignTarget,
            sendRows:        (viewModel.activeTool == .toolAux)
                                ? sendRowsFor(group.id, memo: memo) : [],
            isRenaming:      viewModel.renamingID == group.id,
            isBaking:      viewModel.isBaking(group.id),
            renderProgress: viewModel.renderProgress,
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

    // MARK: - The insertion between two lanes (line and HUD)

    /// The line in the gap before display row `ins.boundaryRow`: 3 px of accent in the middle of the
    /// 4 px between the two rows.
    private func insertionLine(for ins: LaneInsertion.Plan) -> some View {
        let y = rulerHeight + Double(ins.boundaryRow) * laneStep - laneGap / 2 - 1.5
        var x0 = 0.0
        var w = max(contentWidth, Double(viewportWidth))
        if let gid = ins.parentID, let e = viewModel.laneEntries.first(where: { $0.item.id == gid }),
           !e.item.isInfiniteBus {
            x0 = e.absStart * pixelsPerSecond
            w = e.item.duration * pixelsPerSecond
        }
        return Capsule()
            .fill(Color.accentColor)
            .frame(width: w, height: 3)
            .offset(x: x0, y: y)
    }

    /// The second line of the move HUD while a block is straddling two rows: WHERE it will be
    /// inserted and what that does to the lanes below. Lanes are numbered from 1, the way one counts
    /// them: the lane above the gap is `b`, the one below `b + 1`.
    @ViewBuilder
    private func insertionHUDLine(_ ins: LaneInsertion.Plan) -> some View {
        let b = ins.laneBefore
        let place: String = {
            if let gid = ins.parentID, let g = viewModel.find(id: gid) {
                let name = viewModel.displayName(of: g)
                return b == 0 ? L("hud.move.insert.group.top", name)
                              : L("hud.move.insert.group.between", name, b, b + 1)
            }
            return b == 0 ? L("hud.move.insert.top") : L("hud.move.insert.between", b, b + 1)
        }()
        HStack(spacing: 6) {
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text(place)
                .font(.system(size: 11, weight: .bold))
            Text(verbatim: "·").foregroundStyle(.secondary)
            Text(Ln("hud.move.insert.shift", ins.count, ins.count))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
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
            VStack(alignment: .leading, spacing: 3) {
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
                if let ins = md.insertion { insertionHUDLine(ins) }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1))
            .padding(.bottom, 12)
            .allowsHitTesting(false)   // a gesture is under way: this band must catch nothing
        }
    }

    /// The SHAPE the fade drag under way is about to lay down, named AND measured while one is
    /// making it. A fade has two dimensions here — the length under the hand, the bend under the
    /// vertical component — and nothing on the block announces the second one. The same reasoning
    /// as `moveDragHUD`: the only moment a modifier counts is the moment one cannot go and read a
    /// list, so the gesture says itself.
    ///
    /// The percentage is what makes a CONTINUOUS bend usable: without it one sees the veil bend
    /// but has no way of coming back to the same curve twice, and no way of knowing that one has
    /// hit the end of the travel. Both are read off the curve the gesture will COMMIT — the
    /// grabbed object's own, anchor included — and never off a second reading of the mouse: what
    /// one reads and what one gets cannot then diverge. Which is also why the HUD names the fade's
    /// existing shape while the hand is still inside the row: that is precisely what a drag ending
    /// there will leave behind.
    @ViewBuilder
    private var fadeDragHUD: some View {
        if let fd = fadeDrag {
            let curve = fd.grabbedCurve
            HStack(spacing: 7) {
                Image(systemName: fadeHUDSymbol(curve.shape))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(L(fadeCurveNameKey(curve.shape)))
                    .font(.system(size: 11, weight: .bold))
                if !curve.isStraight {
                    Text(verbatim: "\(Int((curve.amount * 100).rounded())) %")
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                        .foregroundStyle(Color.accentColor)
                }
                // The fade has run past its own edge onto the neighbour: what the hand is making
                // is no longer a fade but a CROSSFADE, and it says so while it is being made.
                if spillingCrossfadePreview != nil {
                    Text(verbatim: "→").foregroundStyle(.secondary)
                    Text(L("hud.crossfade.title"))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                } else if fd.seamNeighbours[fd.grabbedID] != nil,
                          fd.edgeRoom <= EditViewModel.seamEpsilon,
                          fd.finalFade <= EditViewModel.seamEpsilon {
                    // The edge touches a neighbour, so pulling further would open a crossfade —
                    // and there is nothing behind either edge to open it with. Left mute, the
                    // gesture would look broken; it is the seam that is empty.
                    Text(verbatim: "·").foregroundStyle(.secondary)
                    Text(L("hud.crossfade.seamEmpty"))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.orange)
                }
                Text(verbatim: "·")
                    .foregroundStyle(.secondary)
                Text(L("hud.fade.leaveLane"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                // Lit when the curve one is about to lay down IS an S, not when ⌥ is down: ⌥ flips
                // the S rather than imposing it, so on a fade that already carries one the key is
                // what turns the badge OFF.
                modifierChip("⌥", L("hud.fade.chip.sCurve"), on: curve.isS, locked: false)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1))
            .padding(.bottom, 12)
            .allowsHitTesting(false)
        }
    }

    /// The crossfade under the hand: what it is, how wide it is now, and the shape both its
    /// curves are taking. The same three-part reading as the fade's, for the same reason — the
    /// bend lives in the vertical, which nothing on the block announces.
    ///
    /// What is added here is the CEILING. A crossfade is bounded by what two objects can give
    /// between them, and that bound is invisible: a hand that reaches it sees the zone stop and
    /// has no way of telling a limit from a dropped gesture. So the HUD says the seam gives no
    /// more, and goes on saying it while the hand travels on into nothing.
    @ViewBuilder
    private var crossfadeDragHUD: some View {
        if let cd = crossfadeDrag {
            let curve = cd.curves().left
            // The zone as the gesture's copies hold it once they exist (the model holds it as the
            // hand found it); a zone the copies have shut says 0, as the model's did.
            let width = cd.shadow != nil
                ? (cd.shadowWidth ?? 0)
                : (viewModel.crossfadeZone(leftID: cd.leftID, rightID: cd.rightID)?.width ?? 0)
            HStack(spacing: 7) {
                Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(L("hud.crossfade.title")).font(.system(size: 11, weight: .bold))
                Text(Self.selectionDurationString(width))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                if cd.spilloverFade > 0 {
                    // The zone is shut and the travel that is left has become a PLAIN fade on the
                    // side being held. The HUD has to say the gesture changed nature, otherwise a
                    // hand that goes too far reads a crossfade that stopped obeying.
                    Text(verbatim: "→").foregroundStyle(.secondary)
                    Text(L("hud.crossfade.becomesFade"))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                    Text(Self.selectionDurationString(cd.spilloverFade))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                } else if cd.atCeiling {
                    Text(verbatim: "·").foregroundStyle(.secondary)
                    Text(L("hud.crossfade.atLimit"))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.orange)
                }
                Text(verbatim: "·").foregroundStyle(.secondary)
                Image(systemName: fadeHUDSymbol(curve.shape))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(L(fadeCurveNameKey(curve.shape)))
                    .font(.system(size: 11, weight: .bold))
                if !curve.isStraight {
                    Text(verbatim: "\(Int((curve.amount * 100).rounded())) %")
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                        .foregroundStyle(Color.accentColor)
                }
                Text(verbatim: "·").foregroundStyle(.secondary)
                Text(L("hud.fade.leaveLane")).font(.system(size: 10)).foregroundStyle(.secondary)
                modifierChip("⌥", L("hud.fade.chip.sCurve"), on: curve.isS, locked: false)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1))
            .padding(.bottom, 12)
            .allowsHitTesting(false)
        }
    }

    /// The translation key naming a shape's FAMILY. Shared with the inspector, so that a curve is
    /// called the same thing wherever it is named.
    func fadeCurveNameKey(_ c: FadeShape) -> String {
        switch c {
        case .linear:        return "fade.curve.linear"
        case .convex:        return "fade.curve.convex"
        case .concave:       return "fade.curve.concave"
        case .sCurve:        return "fade.curve.sCurve"
        case .sCurveInverse: return "fade.curve.sCurveInverse"
        }
    }

    private func fadeHUDSymbol(_ c: FadeShape) -> String {
        switch c {
        case .linear:                    return "line.diagonal"
        case .convex, .sCurveInverse:    return "arrow.up.right"
        case .concave, .sCurve:          return "arrow.down.right"
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

    /// The same band as the object move, for a plugin card being dragged (@see PluginDropHint):
    /// what a release would do NOW, and the two modifiers lit as they are held. Shown only while
    /// the card hovers a place that takes it — a system drag has no other signal to be read.
    /// Within a chain (the synoptic's cards and cables), ⌘ does not link: the chip is replaced
    /// by a line saying where it does.
    @ViewBuilder
    private var pluginDropHUD: some View {
        if let s = PluginDropHint.shared.state {
            HStack(spacing: 7) {
                Image(systemName: s.isLink ? "link"
                                  : s.isCopy ? "plus.square.on.square"
                                  : s.context == .intoBin ? "tray.and.arrow.down"
                                  : s.context == .outOfBin ? "tray.and.arrow.up"
                                  : "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(s.isLink ? LinkColor.plugin : Color.accentColor)
                Text(pluginDropTitle(s))
                    .font(.system(size: 11, weight: .bold))
                modifierChip("⌥", L("hud.move.chip.copy"), on: s.isCopy && s.alt, locked: false)
                switch s.context {
                case .host:
                    modifierChip("⌘", L("hud.pluginDrop.chip.link"), on: s.isLink, locked: false)
                case .blockMove:
                    // A block's ⌘ is a copy like ⌥: every copy of a bin stays on the bin.
                    modifierChip("⌘", L("hud.move.chip.copy"), on: s.cmd, locked: false)
                case .intoBin, .outOfBin:
                    Text(L("hud.pluginDrop.binNoCmd"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                case .sameChain:
                    Text(L("hud.pluginDrop.sameChainNoLink"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1))
            .padding(.bottom, 12)
            .allowsHitTesting(false)   // it must never intercept the drop
        }
    }

    /// The band's title for what a release would do (@see PluginDropHint.Context).
    private func pluginDropTitle(_ s: PluginDropHint.State) -> String {
        switch s.context {
        case .host, .sameChain:
            return s.isLink ? L("hud.pluginDrop.linkedCopy") : s.isCopy ? L("hud.move.copy") : L("hud.move.move")
        case .intoBin:
            return s.alt ? L("hud.pluginDrop.intoBin.copy") : L("hud.pluginDrop.intoBin")
        case .outOfBin:
            return s.alt ? L("hud.move.copy") : L("hud.pluginDrop.outOfBin")
        case .blockMove:
            return s.isCopy ? L("hud.pluginDrop.blockCopy") : L("hud.pluginDrop.blockMove")
        }
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

    // MARK: - Marker band headers

    private var markerLaneHeaders: some View {
        MarkerLaneHeaderView(
            lanes: viewModel.visibleMarkerLanes,
            allLanes: viewModel.markerLanes,
            // The scale and the LIVE scroll: a pinned name has to know what is under it. The
            // anchor is handed over as the object and read inside the header, so a scrolling
            // frame invalidates those few rows and not the timeline. @see TimelineScrollAnchor
            pixelsPerSecond: pixelsPerSecond,
            anchor: scrollAnchor,
            renamingID: viewModel.renamingID,
            onToggle: { id in
                guard let lane = viewModel.markerLane(id: id) else { return }
                viewModel.setMarkerLaneVisible(id: id, !lane.isVisible)
            },
            onCreate: { viewModel.addMarkerLane() },
            onDelete: { viewModel.removeMarkerLane(id: $0) },
            onBeginRename: { viewModel.renamingID = $0 },
            onRename: { id, name in
                viewModel.renamingID = nil
                if let name, !name.isEmpty { viewModel.renameMarkerLane(id: id, to: name) }
            },
            onRecolor: { id, index in viewModel.setMarkerLaneColor(id: id, colorIndex: index) }
        )
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
                    Text(L("hud.selection.samples", Self.selectionSamplesString(d, sampleRate: sr), AudioStatusText.shortRate(sr)))
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
    // objects/stems are soloed and how to leave (Esc). The temporary solo has its OWN HUD
    // (`heldSoloHUD`, just above): it no longer disappears on stopping playback, only on releasing
    // "s" (or Esc) — the transport does not touch it any more.
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

    /// The view's reading of a base lane. ONE definition, held in the view-model beside its own
    /// inverse (@see EditViewModel.displayLane(forBase:)): the two must count the same amount, and
    /// they cannot when they live in two files.
    func displayLane(for baseLane: Int) -> Int { viewModel.displayLane(forBase: baseLane) }

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
        // The canvas's real width, headroom included (@see totalDuration): clamping on the content
        // alone would drag the scroll back out of room that does exist. Recomputed here rather than
        // read off `totalDuration`, which would want the @State written just above.
        let width = max(content, contentEnd + rightHeadroom)
        let maxScrollX = max(0, width * pixelsPerSecond - Double(viewportWidth))
        if Double(scrollOffsetX) > maxScrollX {
            scrollTo(x: CGFloat(maxScrollX), y: scrollOffsetY)
        }
    }

    // MARK: - Zoom helpers

    func clampZoom(_ v: Double) -> Double { min(max(v, minZoom), maxZoom) }

    /// Re-clamps the zoom the model holds. Only ever pulls it INTO the bounds: the bounds moving
    /// (content edited, window resized) never drags the current zoom along — that would be a zoom
    /// change under the hand, made by a drag of an object.
    private func enforceHorizontalZoomBounds() {
        let clamped = clampZoom(viewModel.pixelsPerSecond)
        if clamped != viewModel.pixelsPerSecond { viewModel.pixelsPerSecond = clamped }
    }
    func clampBlockHeight(_ v: Double) -> Double { min(max(v, minBlockHeight), maxBlockHeight) }

    /// D2 — the catch-all: any door that writes `viewModel.blockHeight` RAW (`view.set`, a
    /// project load, a tab restore, the pill's nil-closure fallback) is re-clamped here, hung off
    /// `.onChange(of: viewModel.blockHeight)`. Idempotent — the corrected write triggers one more
    /// pass that finds nothing left to do.
    private func enforceVerticalZoomBounds() {
        guard viewportMeasured else { return }
        let clamped = clampBlockHeight(viewModel.blockHeight)
        if clamped != viewModel.blockHeight { viewModel.blockHeight = clamped }
    }

    /// D3 — the AVAILABLE height itself just changed (a window resize, a marker row shown or
    /// hidden): below 70 % this is a plain clamp (D2); at/above it, the lane keeps its FRACTION of
    /// the available height, so a resize does not silently switch the mode off (enlarging) or
    /// leave the lane pinned at 90 % once the window grows back (shrinking then re-enlarging).
    private func adjustForAvailableHeightChange() {
        guard viewportMeasured else {
            lastAvailableLaneHeight = availableLaneHeight
            return
        }
        let oldAvail = lastAvailableLaneHeight
        let newAvail = availableLaneHeight
        defer { lastAvailableLaneHeight = newAvail }
        guard oldAvail > 0, newAvail != oldAvail,
              VerticalLaneSnap.isActive(blockHeight: viewModel.blockHeight, available: oldAvail) else {
            enforceVerticalZoomBounds()
            return
        }
        let resized = VerticalLaneSnap.resizedBlockHeight(blockHeight: viewModel.blockHeight,
                                                           oldAvailable: oldAvail, newAvailable: newAvail,
                                                           minBlockHeight: minBlockHeight)
        if resized != viewModel.blockHeight { viewModel.blockHeight = resized }
    }

    /// `view.state.vsnap`'s door: a plain read, computed fresh from the current scroll/zoom —
    /// nothing here is cached or stored beyond what the view already keeps.
    private func verticalSnapProbeSnapshot() -> VerticalSnapProbe {
        let avail = availableLaneHeight
        let ls = laneStep
        let maxY = max(0, canvasHeight - Double(viewportHeight))
        let lanes = visibleLanes
        let active = VerticalLaneSnap.isActive(blockHeight: blockHeight, available: avail)
        let y = Double(scrollOffsetY)
        let nearest = VerticalLaneSnap.nearestLane(scrollY: y, blockHeight: blockHeight, laneStep: ls,
                                                   available: avail, maxScrollY: maxY, laneCount: lanes)
        let onGrid = VerticalLaneSnap.isOnGrid(scrollY: y, blockHeight: blockHeight, laneStep: ls,
                                               available: avail, maxScrollY: maxY, laneCount: lanes)
        return VerticalSnapProbe(availableHeight: avail,
                                 maxBlockHeight: VerticalLaneSnap.maxBlockHeight(available: avail,
                                                                                minBlockHeight: minBlockHeight),
                                 laneStep: ls, ratio: avail > 0 ? blockHeight / avail : 0, active: active,
                                 framedLane: active ? nearest : nil, onGrid: onGrid,
                                 pendingFraming: vSnapPendingFraming, rulerHeight: rulerHeight,
                                 viewportHeight: Double(viewportHeight))
    }

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
        vZoomAnchorLaneCentre = selectionAnchorLaneCentre
        vZoomAnchorRelY = max(0, scrollOffsetY + viewportHeight / 2 - CGFloat(rulerHeight))
        vZoomBaseHeight = blockHeight
        vZoomLockedX = scrollOffsetX
    }

    /// D12 — the lane span a vertical zoom keeps fixed on screen, in priority order: the SELECTED
    /// OBJECTS' own span (their lowest and highest display lane, centred between the two — a
    /// selection straddling several lanes zooms about its own middle, not about whichever single
    /// lane happened to be under the pointer); otherwise a TRACED TIME SELECTION's own lanes,
    /// centred the same way; otherwise the CARET's lane; otherwise `nil`, which leaves the zoom on
    /// its former anchor, the viewport's own centre. Read ONCE when a session opens and held for
    /// the whole gesture (@see `openVerticalZoomSession`) — recomputing it notch by notch from a
    /// scroll position that has already moved is exactly the mistake the pan's detent fixed on
    /// 15 September 2026 (compounding: @see CLAUDE.md, "the pan gets its detent back").
    private var selectionAnchorLaneCentre: Double? {
        let ids = viewModel.effectiveSelectedIDs
        if !ids.isEmpty {
            let lanes = viewModel.laneEntries.filter { ids.contains($0.item.id) }.map(\.displayLane)
            if let lo = lanes.min(), let hi = lanes.max() { return Double(lo + hi) / 2 }
        }
        if let sel = viewModel.timeSelection, let lo = sel.lanes.min(), let hi = sel.lanes.max() {
            return Double(lo + hi) / 2
        }
        if let caret = viewModel.caretLane { return Double(caret) }
        return nil
    }

    /// D12 — a lane SPAN's own centre in content coordinates: exact and LINEAR in the block
    /// height (no ratio, hence nothing to approximate and nothing to drift across sessions), where
    /// `centre` is `(lowLane + highLane) / 2` — possibly a half-lane for an even-numbered span.
    /// `rulerHeight + centre·(bh+gap) + bh/2` reduces to the ordinary single-lane centre
    /// (`rulerHeight + lane·(bh+gap) + bh/2`) when `centre` is a whole lane.
    private func laneSpanCentreContentY(_ centre: Double, blockHeight bh: Double) -> CGFloat {
        CGFloat(rulerHeight) + CGFloat(centre) * CGFloat(bh + laneGap) + CGFloat(bh) / 2
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
        // D8 — armed on EVERY notch, pill drag excepted (it ends its own session explicitly):
        // even a notch that changes nothing because it is already at the 90 % cap must still end
        // the session and re-frame, which is harmless (`guard clamped != blockHeight` below).
        if !vZoomHeld { scheduleVerticalZoomSettle() }
        guard clamped != blockHeight else { return }
        viewModel.blockHeight = clamped
        // The canvas grows WITH the block height: bounding the scroll on the old height
        // brought the view back on every zoom-in notch (hence the jumps).
        let newContentY: CGFloat
        if let centre = vZoomAnchorLaneCentre {
            // D12 — a selection (or the caret) held: its span's own centre, computed exactly for
            // the NEW block height. No ratio: the old `vZoomAnchorRelY * ratio` scaled the
            // captured content point's `blockHeight / 2` term by `(bh1+gap)/(bh0+gap)` instead of
            // by `bh1/bh0`, which is only the same fraction when `laneGap` is zero — with a real
            // gap it undershoots on zoom-in (`bh0<bh1` ⇒ `(bh1+gap)/(bh0+gap) < bh1/bh0`), so the
            // computed anchor point sits ABOVE the true lane centre and the lane held "centred"
            // crept downward on screen with every notch — exactly the reported symptom, and exactly
            // reproduced and measured before this fix (@see CLAUDE.md, the 28 September 2026 entry).
            newContentY = laneSpanCentreContentY(centre, blockHeight: clamped)
        } else {
            let ratio = CGFloat(clamped + laneGap) / CGFloat(vZoomBaseHeight + laneGap)
            newContentY = CGFloat(rulerHeight) + vZoomAnchorRelY * ratio
        }
        let newCanvasH = canvasHeight(forBlockHeight: clamped)
        let maxScrollY = max(0, newCanvasH - Double(viewportHeight))
        let newScrollY = min(CGFloat(maxScrollY), max(0, newContentY - viewportHeight / 2))
        scrollTo(x: vZoomLockedX, y: newScrollY)
    }

    /// D8 — crossing 70 % while zooming: never snap per notch (it would fight the zoom's own
    /// anchor — the held point stays fixed on-screen for the whole session). Cancelled and
    /// rearmed on every notch; `zoomSettleDebounce` after the last one, if the snap is active,
    /// frames the lane that was held — continuity: what was kept in place while zooming is what
    /// gets framed. D12: with a selection, caret or traced time selection held, that IS the
    /// anchor lane (rounded to the nearer whole lane for a multi-lane span), so the settle lands
    /// on the selected object's own lane rather than merely "nearest to wherever scroll ended up"
    /// — `currentFramedLane()` stays the fallback for a session with no such anchor. Zooming out
    /// below 70 % needs nothing: the debounce still fires, finds `verticalSnapActive` false, and
    /// does nothing.
    private func scheduleVerticalZoomSettle() {
        vZoomSettleWork?.cancel()
        vSnapPendingFraming = true
        let anchorCentre = vZoomAnchorLaneCentre
        let work = DispatchWorkItem { [self] in
            vSnapPendingFraming = false
            guard verticalSnapActive else { return }
            let lane = anchorCentre.map { Int($0.rounded()) } ?? currentFramedLane()
            frameLane(lane, animated: true)
        }
        vZoomSettleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + VerticalLaneSnap.zoomSettleDebounce, execute: work)
    }

    /// Brings a DISPLAY row into view, scrolling the LEAST it takes: a row above the window comes
    /// just under the header, a row below it just above the foot, and a row already in sight moves
    /// nothing. It is what ↑ / ↓ owe the caret and the time selection (@see pendingLaneReveal) —
    /// walking a point of insertion out of the window is walking it out of one's hands.
    ///
    /// The header is STICKY and its height GROWS with the marker rows shown, so the top of the
    /// visible CONTENT is `scrollOffsetY + rulerHeight` and not `scrollOffsetY`: a row brought to
    /// the latter would come to rest UNDER the band (@see rulerHeight).
    func revealDisplayLane(_ lane: Int) {
        // D9 — in snap mode "the least it takes" would bottom/top-align a lane partially visible
        // in its own sliver, which is off-grid. The view FRAMES the lane instead, exactly as the
        // scroll gesture and the end-of-zoom settle do: walking the caret or a selection with
        // ↑/↓ walks the view one lane per press, on the same grid.
        if verticalSnapActive {
            frameLane(lane, animated: true)
            return
        }
        let top = rulerHeight + Double(lane) * laneStep
        let bottom = top + blockHeight
        let y = Double(scrollOffsetY)
        let target: Double
        if top < y + rulerHeight {
            target = top - rulerHeight
        } else if bottom > y + Double(viewportHeight) {
            target = bottom - Double(viewportHeight)
        } else {
            return                                   // already in sight: the eye is not moved
        }
        let maxScrollY = max(0, canvasHeight - Double(viewportHeight))
        let clamped = min(maxScrollY, max(0, target))
        guard clamped != y else { return }
        scrollTo(x: scrollOffsetX, y: CGFloat(clamped))
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

    /// Brings the objects of a reveal request into view: the box they fill in time × display lanes
    /// is measured here (the only place that knows the window, the scroll and the zoom) and
    /// `TimelineReveal` says what has to change — nothing, when the box is already in sight. Every
    /// write goes through a door that already exists: the zoom through `pixelsPerSecond` as
    /// `revealTimeRange` does (an anchored `applyZoom` is exactly what a framing must not use),
    /// the scroll through `scrollTo`, the vertical snap through `frameLane`.
    ///
    /// Deferred by one turn of the run loop, twice when the zoom changes: the request can arrive
    /// in the transaction that has just unfolded a group (the canvas is not as tall as it is about
    /// to be) and a new scale gives the canvas its new width only after it has been set — a scroll
    /// bounded on the old one lands short of the box. @see revealTimeRange, which has the second.
    func revealObjects(_ req: TimelineRevealRequest) {
        DispatchQueue.main.async {
            guard let box = viewModel.revealBox(for: req.ids) else { return }
            let vw = Double(viewportWidth)
            let view = TimelineReveal.View(
                viewportWidth: vw,
                scrollX: Double(scrollOffsetX),
                pixelsPerSecond: pixelsPerSecond,
                minPixelsPerSecond: minZoom,
                maxPixelsPerSecond: maxZoom,
                // The canvas's width at a GIVEN zoom (@see totalDuration, whose headroom is a
                // fraction of the window and so depends on it).
                maxScrollX: { pps in
                    let total = max(max(contentDuration, stickyTotalDuration),
                                    contentEnd + Self.rightHeadroomFraction * vw / pps)
                    return max(0, total * pps - vw)
                },
                viewportHeight: Double(viewportHeight),
                scrollY: Double(scrollOffsetY),
                maxScrollY: max(0, canvasHeight - Double(viewportHeight)),
                rulerHeight: rulerHeight,
                laneStep: laneStep,
                blockHeight: blockHeight,
                snapActive: verticalSnapActive)
            let frame = TimelineReveal.frame(box: box, view: view)
            guard !frame.isEmpty else { return }
            let zoomed = frame.pixelsPerSecond
            if let pps = zoomed { viewModel.pixelsPerSecond = clampZoom(pps) }
            let apply = {
                var x = frame.scrollX.map { CGFloat($0) } ?? scrollOffsetX
                if zoomed != nil {
                    // Re-bounded on the canvas as it now IS, not as it was estimated.
                    x = min(x, CGFloat(max(0, totalDuration * pixelsPerSecond - Double(viewportWidth))))
                }
                let y = frame.scrollY.map { CGFloat($0) } ?? scrollOffsetY
                if x != scrollOffsetX || y != scrollOffsetY { scrollTo(x: x, y: y) }
                if let lane = frame.frameLane { frameLane(lane, animated: true) }
            }
            if zoomed != nil { DispatchQueue.main.async(execute: apply) } else { apply() }
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
        let bucketY = (scrollAnchor.y / step).rounded(.down) * step
        if bucketY != cullScrollY { cullScrollY = bucketY }
    }

    // MARK: - Vertical lane snap: framing (D5, D6.5, D9, D10)

    /// D6.5 — an animated VERTICAL scroll for the snap's step, distinct from `scrollTo`: it does
    /// NOT pre-set `scrollAnchor.y`. The sticky header reads that anchor, and a pre-set would jump
    /// the ruler straight to the target while the content is still animating underneath it — the
    /// exact flicker `scrollTo`'s own pre-set exists to AVOID for a zoom, turned into a jump here
    /// for the opposite reason. `onScrollGeometryChange` drives the anchor for the length of the
    /// animation instead; `x` is left as it is — the axis is locked for the whole gesture, so the
    /// cull window (keyed on `scrollAnchor.x`) has nothing to redo.
    private func animatedScrollTo(y: CGFloat) {
        withAnimation(.easeOut(duration: VerticalLaneSnap.easeOutDuration)) {
            scrollPosition.scrollTo(x: scrollOffsetX, y: y)
        }
        viewModel.viewScrollY = Double(y)
    }

    /// Frames display row `lane`: scrolls — animated or not — so it sits centred (or top-aligned,
    /// @see VerticalLaneSnap.framing) in the available area. The one function every snap door
    /// converges on: the scroll monitor's step, ↑/↓ in snap mode (`revealDisplayLane`), the
    /// end-of-zoom settle (D8), the idle safety net (D7), and a project reopen / tab switch (D10).
    func frameLane(_ lane: Int, animated: Bool) {
        let maxY = max(0, canvasHeight - Double(viewportHeight))
        let target = VerticalLaneSnap.scrollY(forLane: lane, blockHeight: blockHeight, laneStep: laneStep,
                                              available: availableLaneHeight, maxScrollY: maxY)
        guard abs(target - Double(scrollOffsetY)) > 0.01 else { return }
        if animated {
            animatedScrollTo(y: CGFloat(target))
        } else {
            scrollTo(x: scrollOffsetX, y: CGFloat(target))
        }
    }

    /// The display row currently framed: the one whose own target (@see VerticalLaneSnap.scrollY)
    /// is nearest to the scroll position.
    func currentFramedLane() -> Int {
        let maxY = max(0, canvasHeight - Double(viewportHeight))
        return VerticalLaneSnap.nearestLane(scrollY: Double(scrollOffsetY), blockHeight: blockHeight,
                                            laneStep: laneStep, available: availableLaneHeight,
                                            maxScrollY: maxY, laneCount: visibleLanes)
    }

    /// The neighbour of a GIVEN lane (not necessarily the one currently framed) — what the wheel's
    /// notches accumulate onto (D6.4: onto the step animation's running target, not onto the lane
    /// read back mid-flight, so a fast spin keeps advancing one lane per notch instead of losing
    /// notches to an animation still in progress).
    func neighbourLane(of lane: Int, direction: Int) -> Int? {
        let maxY = max(0, canvasHeight - Double(viewportHeight))
        return VerticalLaneSnap.neighbour(of: lane, direction: direction, blockHeight: blockHeight,
                                          laneStep: laneStep, available: availableLaneHeight,
                                          maxScrollY: maxY, laneCount: visibleLanes)
    }

    /// Steps the framed lane by `direction` (±1 — down/up), animated. No-op at an end: row 0 going
    /// up, or no row left with a target distinct from the last one going down (@see
    /// VerticalLaneSnap.neighbour, which several bottom rows can share once they clamp).
    @discardableResult
    func stepFramedLane(by direction: Int) -> Bool {
        guard let next = neighbourLane(of: currentFramedLane(), direction: direction) else { return false }
        frameLane(next, animated: true)
        return true
    }

    /// D7 — re-frames the nearest lane if the scroll came to rest OFF grid while snapped: the
    /// vertical scroller dragged by hand, a drag-follow scroll during a block drag, a horizontal
    /// gesture whose tiny vertical component slipped through, a programmatic scroll. Left alone
    /// while a gesture that moves matter is in flight (its own drag-follow will settle the scroll
    /// on its own terms) or while a framing is already pending (D8's debounce, the monitor's own
    /// step) — converges in one move: the framed position IS on-grid, so the next `.idle` finds
    /// nothing left to do.
    private func reframeIfOffGridOnIdle() {
        guard verticalSnapActive, !vSnapPendingFraming else { return }
        guard moveDrag == nil, resizeDrag == nil, trimDrag == nil, fadeDrag == nil,
              timeSelectionDrag == nil, cutDrag == nil, slipDrag == nil, loopRangeDrag == nil,
              markerBandDrag == nil, commentDrag == nil, objectMarkerDrag == nil,
              infiniteBusDrag == nil else { return }
        let maxY = max(0, canvasHeight - Double(viewportHeight))
        guard !VerticalLaneSnap.isOnGrid(scrollY: Double(scrollOffsetY), blockHeight: blockHeight,
                                         laneStep: laneStep, available: availableLaneHeight,
                                         maxScrollY: maxY, laneCount: visibleLanes) else { return }
        frameLane(currentFramedLane(), animated: true)
    }

    // A rubber-band selection in display-lane space.
    // It replaces viewModel.selectClipsIn (which compares base lanes) everywhere in TimelineView.
    /// The rule itself lives on the view-model, where the shared click rules can reach it
    /// (@see EditViewModel.selectObjectsInDisplayLanes). This stays so the call sites read the same.
    func selectInDisplayLanes(_ sel: TimeSelection) {
        viewModel.selectObjectsInDisplayLanes(sel)
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

/// The snap guide's hairline — a bare vertical stroke, so that it can be DASHED. A
/// `Rectangle().fill()` cannot be, and the dash is what tells the grey guide from the grey
/// selection cursor (@see the guide's own comment in the canvas).
private struct SnapGuideRule: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return p
    }
}

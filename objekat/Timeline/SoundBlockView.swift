import SwiftUI

// MARK: - Sound block

struct SoundBlockView: View {
    let object: SoundObject
    let pixelsPerSecond: Double
    /// Seconds per beat at the current tempo (60/bpm) — used to render a MIDI clip's notes.
    var secPerBeat: Double = 0.5
    let rulerHeight: Double
    let blockHeight: Double
    let laneGap: Double
    let isSelected: Bool
    let activeTool: ActiveTool
    var waveformCache: WaveformCache
    let scrollOffsetX: CGFloat
    let viewportWidth: CGFloat
    let waveformDisplayDB: Double
    let displayLane: Int
    let stemColor: Color
    /// True if the object is muted in the mix — its own mute, or its stem's — unless a direct solo.
    /// Composed by the view model, not here: @see isMutedInMix. It does not touch `object.isMuted`.
    var isMutedInMix: Bool = false
    let previewOffset: (dx: Double, dy: Double)?

    let previewResizeDX: Double
    let previewTrimDX: Double
    let previewFadeIn: Double?
    let previewFadeOut: Double?
    /// The loop's IN/OUT bounds in preview (seconds local to the block), @see previewLoopRange(for:)
    /// in TimelineView+DragHandler. `nil` if the object does not loop.
    var previewLoopRange: (start: Double, end: Double)? = nil
    var isToolHovered: Bool = false
    /// The stem the assignment tool is aiming at (nil = the tool is not armed), for the hover veil.
    var stemAssignTarget: StemAssignTarget? = nil
    var sendRows: [SendRow] = []
    var isRenaming: Bool = false
    var isBaking: Bool = false
    /// True if this sound object bake captures content that is now stale
    /// (`EditViewModel.isStale`) — a warning badge, see EditViewModel+Objects.
    var isStale: Bool = false
    /// True when OTHER instances are following this object live (a live mirror, for the length of
    /// the opening) — a small discreet indicator, not in the way. See EditViewModel+Objects.
    var isPreviewing: Bool = false
    /// True while this placement's definition is being re-baked AUTOMATICALLY in the background
    /// (a transitive cascade after a dependency changed). It replaces the frozen 'stale' flag with
    /// a transient indicator. See EditViewModel+Objects.cascadeRebakeStaleFixpoint.
    var isRecomputing: Bool = false
    /// True briefly (~15 s) after an instance has just been RESYNCED (the re-bake finished)
    /// — a transient ✓ taking over from the spinner. See EditViewModel.recentlyResyncedDefinitionIDs.
    var isResynced: Bool = false
    /// True if THIS instance is the OPEN sound object (the top of the stack): it shows the cancel
    /// button (✕) next to the live indicator. The click is resolved geometrically by the parent
    /// canvas (TimelineView+TapHandler), and the block stays pure presentation.
    var isEditing: Bool = false
    var onRename: (String?) -> Void = { _ in }

    @State private var editLabel: String = ""
    @FocusState private var renameFocused: Bool

    // The effective length during a trim/resize (a preview)
    private var effectiveDuration: Double {
        max(0.01, object.duration + (previewResizeDX - previewTrimDX) / pixelsPerSecond)
    }
    // The effective fades: a fade drag preview takes priority, otherwise the stored values,
    // then we apply the same compression logic as updateTrim/updateDuration so that the
    // preview reflects the crop in real time.
    private var effectiveFades: (fi: Double, fo: Double) {
        var fi = previewFadeIn  ?? object.fadeIn
        var fo = previewFadeOut ?? object.fadeOut
        let D = effectiveDuration
        if previewTrimDX != 0 {
            // crop in, left
            if D < fo { fo = D; fi = 0 }
            else if D < fi + fo { fi = D - fo }
        } else if previewResizeDX != 0 {
            // crop out, right
            if D < fi { fi = D; fo = 0 }
            else if D < fi + fo { fo = D - fi }
        } else {
            // no trim/resize: the dragged fade takes priority, the other gives way
            if fi + fo > D {
                if previewFadeIn != nil  { fo = max(0, D - fi) }
                else if previewFadeOut != nil { fi = max(0, D - fo) }
                else { fi = min(fi, D * 0.5); fo = min(fo, D * 0.5) }
            }
        }
        return (fi, fo)
    }
    private var effectiveFadeIn: Double  { effectiveFades.fi }
    private var effectiveFadeOut: Double { effectiveFades.fo }
    private var fadeInPx: Double  { effectiveFadeIn  * pixelsPerSecond }
    private var fadeOutPx: Double { effectiveFadeOut * pixelsPerSecond }

    /// The loop's IN/OUT bounds for display (px local to the block): a drag preview takes priority,
    /// otherwise the bounds that are set. `nil` if the object does not loop.
    private var loopMarkerPx: (start: Double, end: Double)? {
        guard let r = previewLoopRange else { return nil }
        return (r.start * pixelsPerSecond, r.end * pixelsPerSecond)
    }

    private var laneStep: Double { blockHeight + laneGap }
    /// The block's effective colour (border, controls): a custom colour if one is assigned,
    /// otherwise the stem's. Two things do NOT follow it. The BACKGROUND splits into two zones when
    /// a custom colour is set — the name band in the custom colour, the body in the stem's colour
    /// (see `body`). And the CONTENT — the waveform, the MIDI note preview — stays in the stem's
    /// colour whatever happens: it reads on the block's body, which is precisely the stem's zone
    /// (and that is already what a group does, see GroupBlockView).
    private var effectiveColor: Color { object.customColor ?? stemColor }
    /// Rounded corners: an AUX takes the same radius as groups; otherwise the clip's radius.
    /// Defined on the model so that the link halos draw the same radius as the block
    /// (see SoundObject.blockCornerRadius).
    private var cornerRadius: Double { object.blockCornerRadius }
    private var blockWidth: Double {
        let natural = (object.duration * pixelsPerSecond) + previewResizeDX - previewTrimDX
        if previewResizeDX != 0 { return max(natural, 1) }
        return max(natural, 2)
    }
    private var xPos: Double {
        let natural = (object.duration * pixelsPerSecond) + previewResizeDX - previewTrimDX
        let offset = previewOffset?.dx ?? 0
        // Anchoring on the right edge (a minimum width of 2px) is reserved for a left trim
        // under way: the right edge is the fixed anchor while the left one follows the mouse.
        if natural < 2 && previewTrimDX != 0 {
            return (object.startTime * pixelsPerSecond) + (object.duration * pixelsPerSecond) - 2 + offset
        }
        return (object.startTime * pixelsPerSecond) + previewTrimDX + offset
    }
    /// The effective source offset. OUTSIDE a trim under way, it is EXACTLY `object.sourceOffset`:
    /// the selected clip moves from the shared Canvas (which draws with the raw offset) to this
    /// view, and the slightest difference shows as the waveform jumping on selection. During a trim,
    /// it follows the edge to the pixel: `previewTrimDX` is ALREADY set on the whole pixel (see its
    /// definition), so the preview does not shimmer at sub-pixel level without the content shifting
    /// inside its block either — the block's position and the source offset derive from the same offset.
    /// In reverse, it is the RIGHT edge that governs the source range: the preview then follows the
    /// resizing and NOT the trimming (@see WaveformShaping.retrimmedSourceOffset).
    private var effectiveSourceOffset: Double {
        let moving = object.isReversed ? previewResizeDX : previewTrimDX
        guard moving != 0, pixelsPerSecond > 0 else { return object.sourceOffset }
        let dStart = previewTrimDX / pixelsPerSecond
        let dEnd   = previewResizeDX / pixelsPerSecond
        return WaveformShaping.retrimmedSourceOffset(
            object.sourceOffset,
            oldStart: object.startTime, oldDuration: object.duration,
            newStart: object.startTime + dStart,
            newDuration: object.duration - dStart + dEnd,
            speedRatio: object.speedRatio, isReversed: object.isReversed)
    }
    private var yPos: Double {
        rulerHeight + Double(displayLane) * laneStep + (previewOffset?.dy ?? 0)
    }

    /// The block's visible sub-window (in LOCAL coordinates) on which to lay the tool controls, so
    /// that they stay reachable when the block overflows the viewport. See `visibleSpan`.
    private var toolSpan: (x: Double, width: Double) {
        let s = visibleSpan(blockX: xPos, blockWidth: blockWidth,
                            scrollOffsetX: scrollOffsetX, viewportWidth: viewportWidth)
        return (s.x - xPos, s.width)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // A pale background (= white plus a faint tint) so as to carry the colour identity without saturating.
            // With no custom colour: a uniform stem tint, the behaviour unchanged. With a custom
            // colour: the top band — the one carrying the NAME — takes the custom colour, and the
            // body keeps the stem's. The colour chosen therefore reads with the clip's title,
            // without ever losing the stem membership, which occupies all the rest.
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color.white)
            if let custom = object.customColor {
                VStack(spacing: 0) {
                    UnevenRoundedRectangle(topLeadingRadius: cornerRadius, topTrailingRadius: cornerRadius)
                        .fill(custom.opacity(isSelected ? 0.55 : 0.30))
                        .frame(height: max(3, blockHeight * 0.20))
                    UnevenRoundedRectangle(bottomLeadingRadius: cornerRadius, bottomTrailingRadius: cornerRadius)
                        .fill(stemColor.opacity(isSelected ? 0.55 : 0.30))
                }
            } else {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(stemColor.opacity(isSelected ? 0.55 : 0.30))
            }
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(isSelected ? effectiveColor.opacity(0.9) : effectiveColor.opacity(0.3), lineWidth: 1.5)
 
            // The waveform — an aux has no file (it only receives) → no waveform,
            // just a chequerboard of the 'receives' icon.
            if object.isAux {
                GlyphTilePattern(color: effectiveColor.opacity(0.7), tile: 30, glyphSize: 17, iconName: "arrow.down.right.circle")
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                    .allowsHitTesting(false)
            } else if object.isMIDI {
                // A MIDI clip: no audio file → a small note preview (instead of the waveform).
                MidiNotesPreview(notes: object.midiNotes, secPerBeat: secPerBeat,
                                 pixelsPerSecond: pixelsPerSecond,
                                 xOffset: -previewTrimDX, color: stemColor,
                                 isMuted: object.isMuted,
                                 loopRange: previewLoopRange)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                    .allowsHitTesting(false)
            } else {
                TimelineWaveformView(
                    waveformCache: waveformCache,
                    filePath: object.filePath,
                    sourceOffset: effectiveSourceOffset,
                    pixelsPerSecond: pixelsPerSecond,
                    scrollOffsetX: scrollOffsetX,
                    viewportWidth: viewportWidth,
                    xPos: xPos,
                    stemColor: stemColor,
                    isSelected: isSelected,
                    clipDuration: effectiveDuration,
                    speedRatio: object.speedRatio,
                    isReversed: object.isReversed,
                    volumeDb: object.volume,
                    fadeIn: effectiveFadeIn,
                    fadeOut: effectiveFadeOut,
                    isMuted: object.isMuted,
                    waveformDisplayDB: waveformDisplayDB,
                    loopRange: previewLoopRange
                )
                // The same radius as the block: a block with a large radius carries its waveform, which
                // starts at x=0, and would otherwise spill out of the corners.
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            }

            // Fades
            if fadeInPx > 0 {
                GeometryReader { geo in
                    let w = min(fadeInPx, geo.size.width)
                    let h = geo.size.height
                    Path { p in
                        p.move(to: .zero)
                        p.addLine(to: CGPoint(x: w, y: 0))
                        p.addLine(to: CGPoint(x: 0, y: h))
                        p.closeSubpath()
                    }
                    .fill(Color.black.opacity(0.30))
                }
            }
            if fadeOutPx > 0 {
                GeometryReader { geo in
                    let w = min(fadeOutPx, geo.size.width)
                    let bw = geo.size.width
                    let h = geo.size.height
                    Path { p in
                        p.move(to: CGPoint(x: bw - w, y: 0))
                        p.addLine(to: CGPoint(x: bw, y: 0))
                        p.addLine(to: CGPoint(x: bw, y: h))
                        p.closeSubpath()
                    }
                    .fill(Color.black.opacity(0.30))
                }
            }

            // The loop's IN/OUT markers: two full-height vertical bars, with a small flag at the top
            // for the grip — @see SoundObject.loopMarkerLocalRange, [[loop-item-plan]].
            if let lm = loopMarkerPx {
                LoopRangeMarkersView(startPx: lm.start, endPx: lm.end,
                                     blockWidth: blockWidth, blockHeight: blockHeight,
                                     color: effectiveColor)
                    .allowsHitTesting(false)
            }

            // Volume overlay — an isolated view (the same logic as ToolCutLayer)
            if activeTool == .toolVolume {
                let isNarrow = blockWidth < 50
                if isSelected || isNarrow {
                    ToolVolumeLayerMinimal(object: object)
                }
                ToolVolumeLayer(object: object, showFullOverlay: !isNarrow, forceShow: isToolHovered, span: toolSpan)
            }

            // Pan overlay — an isolated view
            if activeTool == .toolPan {
                let isNarrow = blockWidth < 50
                ToolPanLayer(object: object, alwaysShowOverlay: isSelected || isNarrow || isToolHovered, span: toolSpan)
            }

            // Stem overlay — the hover veil naming the stem the click will assign.
            if activeTool == .toolStemAssign, let t = stemAssignTarget {
                ToolStemLayer(target: t, forceShow: isToolHovered,
                              span: toolSpan, cornerRadius: cornerRadius)
            }

            // Send overlay — one send knob per aux overlapping the clip.
            if activeTool == .toolAux && !sendRows.isEmpty {
                ToolSendLayer(rows: sendRows, blockWidth: blockWidth, blockHeight: blockHeight)
            }

            // Mute overlay — a semi-transparent grey, visible when the item OR its stem is muted.
            if isMutedInMix && activeTool != .toolVolume {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.black.opacity(0.38))
                    .allowsHitTesting(false)
            }

            // A SOUND OBJECT instance: an indigo border (plus a link icon on the label).
            if object.isObjectInstance {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color.indigo.opacity(isSelected ? 0.95 : 0.6), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }

            // A freshness badge: this sound object bake captures content that is now stale.
            // Hidden during the automatic re-bake (`isRecomputing`) → the flag becomes
            // transient (the spinner below) instead of 'sticking'.
            if isStale && !isRecomputing {
                VStack {
                    HStack {
                        Spacer()
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.orange)
                            .padding(3)
                    }
                    Spacer()
                }
                .allowsHitTesting(false)
            }

            // The definition's AUTOMATIC re-bake UNDER WAY (a transitive cascade): a small discreet
            // spinner, not in the way, like the preview. The object stays editable.
            if isRecomputing && !isBaking && !isEditing {
                VStack {
                    HStack {
                        Spacer()
                        ProgressView().controlSize(.small).scaleEffect(0.7).padding(3)
                    }
                    Spacer()
                }
                .allowsHitTesting(false)
            }

            // A RESYNCED instance (the re-bake finished): a transient green ✓ (~15 s), taking over from
            // the recompute spinner. Hidden during a recompute/bake/opening under way.
            if isResynced && !isRecomputing && !isBaking && !isEditing {
                VStack {
                    HStack {
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.green)
                            .padding(3)
                    }
                    Spacer()
                }
                .allowsHitTesting(false)
            }

            // An OPEN sound object: a cancel button (✕) at the top right, preceded by
            // the preview spinner during a live auto-bake. WITHOUT a veil — the object stays editable.
            // The click on ✕ is detected geometrically by the canvas (the top-right zone).
            if isEditing && !isBaking {
                VStack {
                    HStack {
                        Spacer()
                        HStack(spacing: 3) {
                            if isPreviewing {
                                ProgressView().controlSize(.small).scaleEffect(0.7)
                            }
                            Image(systemName: "arrow.uturn.backward.circle.fill")
                                .font(.system(size: 14))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .red)
                        }
                        .padding(3)
                    }
                    Spacer()
                }
                .allowsHitTesting(false)
            }

            // A BAKE UNDER WAY (a background render): a veil plus a spinner plus a render icon.
            if isBaking {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.black.opacity(0.28))
                    .allowsHitTesting(false)
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small)
                    if blockWidth >= 80 {
                        Image(systemName: "waveform")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            }

            // The cut line is rendered at canvas level (TimelineView), uniform top-level /
            // children — the block stays pure presentation.

            // The label: hidden when the block is too narrow, so as to keep it from spilling out
            // of the frame (SwiftUI does not clip by default, and the Text plus its padding imposes
            // an intrinsic width that would make the rendering bleed on tiny blocks).
            if blockWidth >= 30 {
                VStack {
                    HStack(spacing: 3) {
                        if object.isObjectInstance {
                            // The 'sound object' identity (purple = sound objects in the legend).
                            // Linked instances are made explicit by lines (in the selection),
                            // not by a badge — see LinkOverlay in TimelineView.
                            Image(systemName: "waveform.circle")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(LinkColor.soundObject)
                        }
                        if isRenaming {
                            TextField(noLabel, text: $editLabel)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.black)
                                .textFieldStyle(.plain)
                                .focused($renameFocused)
                                .onSubmit { onRename(editLabel) }
                                .onExitCommand { onRename(nil) }
                                .onAppear { beginRename(object.label) }
                        } else {
                            Text(object.displayName)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.black)
                                .lineLimit(1)
                                .layoutPriority(1)
                        }
                        if blockWidth >= 60 {
                            let meta = object.timelineMetaSummary
                            if !meta.isEmpty {
                                Text(meta)
                                    .font(.system(size: 9, weight: .regular))
                                    .foregroundStyle(.black.opacity(0.5))
                                    .lineLimit(1)
                            }
                        }
                        if object.isMuted {
                            Text(L("common.muteBadge"))
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.red)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 6)
                    Spacer()
                }
                .allowsHitTesting(isRenaming)
                // The text field disappears while keeping `renameFocused` true: on the NEXT rename of
                // the same object, setting the flag back to true changes nothing and the new field never
                // takes focus (one had to rename ANOTHER object to steal the focus and unblock this one).
                // So we reset it on the way out, and set it on the next turn so that the field already
                // exists when the focus arrives.
                .onChange(of: isRenaming) { _, now in
                    if now { beginRename(object.label) } else { renameFocused = false }
                }
            }

        }
        .frame(width: blockWidth, height: blockHeight)
        .offset(x: xPos, y: yPos)
        .zIndex(isSelected ? 1 : 0)
        // Tap, drag, hover and cursor are all resolved geometrically by the parent canvas
        // (TimelineView) on laneEntries — uniform top-level / children. The block is pure
        // presentation (SwiftUI hit-tests an .offset view on its layout frame stacked at (0,0),
        // not on its visual frame, hence the dispatch on the parent's side).
    }

    /// Starts typing a name: the initial text, then focus on the next runloop turn.
    private func beginRename(_ label: String?) {
        editLabel = label ?? ""
        DispatchQueue.main.async { renameFocused = true }
    }
}

// MARK: - MIDI note preview (a mini piano roll inside the block)

/// A compact representation of a MIDI clip's notes, drawn in place of the waveform.
/// The pitch range adjusts itself automatically to the notes present (with a margin), so that
/// the melodic contour fills the block's height. A single Canvas (efficient); no interaction
/// (fine editing goes through the unfolded piano roll).
struct MidiNotesPreview: View {
    let notes: [MidiNote]
    let secPerBeat: Double
    let pixelsPerSecond: Double
    /// The horizontal offset (px) of the CONTENT inside the block, during a live left trim:
    /// the edge moves, the notes do not. Negative when the edge comes into the clip.
    /// The MIDI equivalent of `effectiveSourceOffset` for the waveform. Outside a gesture: 0.
    var xOffset: Double = 0
    var color: Color = .accentColor
    var isMuted: Bool = false
    /// Looping: the [IN,OUT] slice (in seconds LOCAL to the block) repeats from the block's LEFT
    /// edge, for as long as the clip's window exceeds it — the same folding as the waveform and as
    /// the engine. `nil` = no loop. @see SoundObject.loopMarkerLocalRange, [[loop-item-plan]]
    var loopRange: (start: Double, end: Double)? = nil

    /// The minimum span of semitones shown (it avoids giant bars when there are 1-2 pitches).
    private static let minSpan = 8
    /// A ceiling on drawn repeats: a very short pattern looped over a very long window at high
    /// zoom must not generate an unreasonable number of iterations.
    private static let maxLoopRepeats = 2000

    var body: some View {
        Canvas { ctx, size in
            guard secPerBeat > 0 else { return }
            let period = loopRange.map { $0.end - $0.start }
            let periodPx = (period.map { $0 > 0.001 } ?? false)
                ? period! * pixelsPerSecond : nil
            // The pattern's offset: the block's left edge plays the part of the IN point.
            let loopShiftPx = (periodPx != nil ? (loopRange?.start ?? 0) : 0) * pixelsPerSecond

            // It counts only what the clip PLAYS: a note (or a loop repeat) whose attack falls
            // outside the edges is not pushed to the engine (see syncMidiNotes/setMidiLoop) and
            // must neither show nor weigh on the vertical scale.
            var visible: [(note: MidiNote, x: Double)] = []
            if let periodPx, periodPx > 0.5 {
                let maxK = min(Self.maxLoopRepeats, Int((size.width / periodPx).rounded(.up)) + 1)
                for k in 0...maxK {
                    let dx = Double(k) * periodPx
                    for n in notes {
                        let x = n.startBeat * secPerBeat * pixelsPerSecond + xOffset + dx - loopShiftPx
                        if x >= 0, x < size.width { visible.append((n, x)) }
                    }
                }
            } else {
                for n in notes {
                    let x = n.startBeat * secPerBeat * pixelsPerSecond + xOffset
                    if x >= 0, x < size.width { visible.append((n, x)) }
                }
            }
            guard !visible.isEmpty else { return }

            // A self-adjusting pitch range plus a 1 semitone margin at the top and at the bottom.
            let lo = visible.map(\.note.pitch).min()! - 1
            let hi = visible.map(\.note.pitch).max()! + 1
            let span = max(Self.minSpan, hi - lo)
            let top  = hi + (span - (hi - lo)) / 2          // re-centres if the span was widened
            // The vertical margin = 10% of the clip's height at the top AND at the bottom; the notes
            // are drawn in the central band that is left.
            let marginY = size.height * 0.10
            let usableH = max(1, size.height - 2 * marginY)
            let rowH = usableH / Double(span + 1)

            for (n, x) in visible {
                let w = max(1.5, n.lengthBeats * secPerBeat * pixelsPerSecond)
                let y = marginY + Double(top - n.pitch) * rowH
                let h = max(1.5, rowH - 1)
                let v = Double(n.velocity) / 127.0
                let rect = CGRect(x: x, y: y, width: w, height: h)
                ctx.fill(Path(roundedRect: rect, cornerRadius: min(2, h / 2)),
                         with: .color(color.opacity((isMuted ? 0.30 : 0.55) + 0.40 * v)))
            }
        }
    }
}

// MARK: - Icon chequerboard

/// An icon pattern repeated in a staggered chequerboard over the whole surface — it serves to
/// mark at a glance the nature of a block with no waveform (a 'receives' aux, an infinite bus).
/// Drawn through a Canvas (a single layer, efficient even on a long clip).
struct GlyphTilePattern: View {
    var color: Color = .secondary
    var tile: CGFloat = 22
    var glyphSize: CGFloat = 11
    var iconName: String = "arrow.down.right.circle"

    var body: some View {
        Canvas { ctx, size in
            let flake = Text(Image(systemName: iconName))
                .font(.system(size: glyphSize, weight: .semibold))
                .foregroundColor(color)
            var row = 0
            var y: CGFloat = tile / 2
            while y < size.height + tile {
                let xOffset: CGFloat = (row % 2 == 0) ? 0 : tile / 2   // staggered
                var x = tile / 2 + xOffset
                while x < size.width + tile {
                    ctx.draw(flake, at: CGPoint(x: x, y: y))
                    x += tile
                }
                y += tile
                row += 1
            }
        }
    }
}

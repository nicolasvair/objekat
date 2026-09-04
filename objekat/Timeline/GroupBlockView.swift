import SwiftUI

struct GroupBlockView: View {
    let group: SoundObject   // was SoundGroup — the same top-level interface
    let pixelsPerSecond: Double
    let rulerHeight: Double
    let blockHeight: Double
    let laneGap: Double
    let isExpanded: Bool
    let isSelected: Bool
    let activeTool: ActiveTool
    let stemColor: Color
    /// True if the group is muted in the mix — its own mute, or its stem's (the 'N + M'
    /// shortcut) — unless a direct solo. Composed by the view model, not here: @see isMutedInMix.
    var isMutedInMix: Bool = false
    let displayLane: Int         // a virtual lane (after expanded groups have shifted things)
    let scrollOffsetX: CGFloat
    let viewportWidth: CGFloat
    let waveformDisplayDB: Double

    let previewOffset: (dx: Double, dy: Double)?
    let previewResizeDX: Double
    let previewTrimDX: Double
    let previewFadeIn: Double?
    let previewFadeOut: Double?
    /// The loop's IN/OUT bounds in preview (seconds local to the block), @see previewLoopRange(for:)
    /// in TimelineView+DragHandler. `nil` if the group does not loop.
    var previewLoopRange: (start: Double, end: Double)? = nil
    var isToolHovered: Bool = false
    /// The stem the assignment tool is aiming at (nil = the tool is not armed), for the hover veil.
    var stemAssignTarget: StemAssignTarget? = nil
    var sendRows: [SendRow] = []
    var isRenaming: Bool = false
    var isBaking: Bool = false
    /// True when OTHER instances are following this group live (a live mirror, for the length of
    /// the opening) — a small discreet indicator, not in the way. See EditViewModel+Objects.
    var isPreviewing: Bool = false
    /// True if THIS (materialised) group is the OPEN sound object: it shows the cancel button (✕).
    /// The click is resolved geometrically by the parent canvas (TimelineView+TapHandler).
    var isEditing: Bool = false
    var onRename: (String?) -> Void = { _ in }

    @State private var editLabel: String = ""
    @FocusState private var renameFocused: Bool

    var waveformCache: WaveformCache

    private var laneStep: Double { blockHeight + laneGap }
    private var effectiveColor: Color { group.customColor ?? stemColor }

    private var blockWidth: Double {
        let natural = group.duration * pixelsPerSecond + previewResizeDX - previewTrimDX
        return max(natural, 2)
    }

    private var xPos: Double {
        (group.startTime * pixelsPerSecond) + previewTrimDX + (previewOffset?.dx ?? 0)
    }

    /// The group's effective start during a left trim under way (a preview). The edge follows the
    /// hand, but the children DO NOT MOVE: their startTime is absolute, and it is the group's
    /// window that moves over them. Without that effective start, the composite was drawn relative
    /// to the old edge while the block had already moved → the whole inside slid with the edge
    /// ('it shifts the start') instead of being revealed / covered. See `effectiveSourceOffset`
    /// in SoundBlockView, which plays exactly the same part for a clip.
    /// `previewTrimDX` is already set on the whole pixel (see its definition): the composite is
    /// sampled per pixel column, and a fractional delta would make it crawl — but the alignment
    /// has to come from the SAME offset as `xPos`, otherwise the composite slides inside its block.
    private var effectiveStartTime: Double {
        guard previewTrimDX != 0, pixelsPerSecond > 0 else { return group.startTime }
        return group.startTime + previewTrimDX / pixelsPerSecond
    }

    private var yPos: Double {
        rulerHeight + Double(displayLane) * laneStep + (previewOffset?.dy ?? 0)
    }

    /// The block's visible sub-window (in LOCAL coordinates) on which to lay the tool controls. See
    /// `visibleSpan` — it keeps mute/±/pan reachable when the group overflows the viewport.
    private var toolSpan: (x: Double, width: Double) {
        let s = visibleSpan(blockX: xPos, blockWidth: blockWidth,
                            scrollOffsetX: scrollOffsetX, viewportWidth: viewportWidth)
        return (s.x - xPos, s.width)
    }

    private var effectiveFadeIn:  Double { previewFadeIn  ?? group.fadeIn  }
    private var effectiveFadeOut: Double { previewFadeOut ?? group.fadeOut }
    private var fadeInPx:  Double { effectiveFadeIn  * pixelsPerSecond }
    private var fadeOutPx: Double { effectiveFadeOut * pixelsPerSecond }

    /// The loop's IN/OUT bounds for display (px local to the block), @see SoundBlockView.loopMarkerPx.
    private var loopMarkerPx: (start: Double, end: Double)? {
        guard let r = previewLoopRange else { return nil }
        return (r.start * pixelsPerSecond, r.end * pixelsPerSecond)
    }

    // The group's amplitude modifier (gain/fade/mute), applied to the composite of the
    // children by GroupWaveformView. Effective values (a drag preview included).
    private var rootMod: WaveformShaping.Modifier {
        let effDur = max(0.01, group.duration + (previewResizeDX - previewTrimDX) / pixelsPerSecond)
        return WaveformShaping.Modifier(
            absStart: effectiveStartTime, duration: effDur,
            fadeIn: effectiveFadeIn, fadeOut: effectiveFadeOut,
            gain: WaveformShaping.linearGain(dB: group.volume))
    }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.white)
            // The same split as a clip (@see SoundBlockView): the name band in the custom colour,
            // the body in the stem's colour.
            if let custom = group.customColor {
                VStack(spacing: 0) {
                    UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20)
                        .fill(custom.opacity(isSelected ? 0.55 : 0.30))
                        .frame(height: max(3, blockHeight * 0.20))
                    UnevenRoundedRectangle(bottomLeadingRadius: 20, bottomTrailingRadius: 20)
                        .fill(stemColor.opacity(isSelected ? 0.55 : 0.30))
                }
            } else {
                RoundedRectangle(cornerRadius: 20)
                    .fill(stemColor.opacity(isSelected ? 0.55 : 0.30))
            }
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(
                    isSelected ? effectiveColor.opacity(0.9) : effectiveColor.opacity(0.5),
                    lineWidth: 2
                )

            if case .group(let children, _) = group.kind {
                GroupWaveformView(
                    waveformCache: waveformCache,
                    children: children,
                    groupStartTime: effectiveStartTime,
                    pixelsPerSecond: pixelsPerSecond,
                    stemColor: stemColor,
                    blockXPos: xPos,
                    scrollOffsetX: scrollOffsetX,
                    viewportWidth: viewportWidth,
                    rootMod: rootMod,
                    rootMuted: group.isMuted,
                    waveformDisplayDB: waveformDisplayDB,
                    loopRange: previewLoopRange
                )
                // The same radius as the block (20): with 4, a child sitting at the very start of the group
                // spilled out of the rounded corners — the composite bled out of the border on the left.
                .clipShape(RoundedRectangle(cornerRadius: 20))
            }

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
                    let w  = min(fadeOutPx, geo.size.width)
                    let bw = geo.size.width
                    let h  = geo.size.height
                    Path { p in
                        p.move(to: CGPoint(x: bw - w, y: 0))
                        p.addLine(to: CGPoint(x: bw, y: 0))
                        p.addLine(to: CGPoint(x: bw, y: h))
                        p.closeSubpath()
                    }
                    .fill(Color.black.opacity(0.30))
                }
            }

            // The loop's IN/OUT markers — @see SoundBlockView (the same shared component).
            if let lm = loopMarkerPx {
                LoopRangeMarkersView(startPx: lm.start, endPx: lm.end,
                                     blockWidth: blockWidth, blockHeight: blockHeight,
                                     color: effectiveColor)
                    .allowsHitTesting(false)
            }

            // Volume overlay
            if activeTool == .toolVolume {
                let isNarrow = blockWidth < 50
                if isSelected || isNarrow {
                    ToolVolumeLayerMinimal(object: group)
                }
                ToolVolumeLayer(object: group, showFullOverlay: !isNarrow, forceShow: isToolHovered, span: toolSpan)
            }

            // Pan overlay
            if activeTool == .toolPan {
                let isNarrow = blockWidth < 50
                ToolPanLayer(object: group, alwaysShowOverlay: isSelected || isNarrow || isToolHovered, span: toolSpan)
            }

            // Stem overlay — the hover veil naming the stem the click will assign.
            if activeTool == .toolStemAssign, let t = stemAssignTarget {
                ToolStemLayer(target: t, forceShow: isToolHovered,
                              span: toolSpan, cornerRadius: 20)
            }

            // Send overlay — one send knob per aux overlapping the group.
            if activeTool == .toolAux && !sendRows.isEmpty {
                ToolSendLayer(rows: sendRows, blockWidth: blockWidth, blockHeight: blockHeight)
            }

            // The cut line is rendered at canvas level (TimelineView).

            if isMutedInMix {
                // The same radius as the block (20): otherwise the veil spilled out of the rounded corners.
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.black.opacity(0.38))
                    .allowsHitTesting(false)
            }

            if blockWidth >= 30 {
                VStack {
                    HStack(spacing: 0) {
                        Image(systemName: "folder")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(effectiveColor.opacity(0.85))
                            .padding(.leading, 6)

                        Spacer().frame(width: 4)

                        if isRenaming {
                            TextField(noLabel, text: $editLabel)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.black)
                                .textFieldStyle(.plain)
                                .focused($renameFocused)
                                .onSubmit { onRename(editLabel) }
                                .onExitCommand { onRename(nil) }
                                .onAppear { beginRename(group.label) }
                        } else {
                            Text(group.displayName)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.black)
                                .lineLimit(1)
                                .layoutPriority(1)
                        }

                        if blockWidth >= 80 {
                            let meta = group.timelineMetaSummary
                            if !meta.isEmpty {
                                Spacer().frame(width: 4)
                                Text(meta)
                                    .font(.system(size: 9, weight: .regular))
                                    .foregroundStyle(.black.opacity(0.5))
                                    .lineLimit(1)
                            }
                        }

                        Spacer(minLength: 4)

                        if blockWidth >= 60 {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.black.opacity(0.5))
                                .padding(.trailing, 6)
                        }
                    }
                    Spacer()
                }
                .allowsHitTesting(isRenaming)
                // See SoundBlockView: without this reset, `renameFocused` stays true after the field
                // disappears and the next rename of the same group never gets focus.
                //
                .onChange(of: isRenaming) { _, now in
                    if now { beginRename(group.label) } else { renameFocused = false }
                }
            }

            // An OPEN sound object (a materialised group): a cancel button (✕) at the top right,
            // preceded by the preview spinner during a live auto-bake. WITHOUT a veil.
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
                        .padding(5)
                    }
                    Spacer()
                }
                .allowsHitTesting(false)
            } else if isPreviewing && !isBaking {
                // A sound object's live mirror UNDER WAY outside the current opening frame
                // (a residual case): a small discreet spinner, not in the way.
                VStack {
                    HStack {
                        Spacer()
                        ProgressView().controlSize(.small).scaleEffect(0.7).padding(5)
                    }
                    Spacer()
                }
                .allowsHitTesting(false)
            }

            // A BAKE UNDER WAY (a background render): a veil plus a spinner plus a render icon.
            if isBaking {
                RoundedRectangle(cornerRadius: 20)
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
        }
        .frame(width: blockWidth, height: blockHeight)
        .offset(x: xPos, y: yPos)
        .zIndex(isSelected ? 1 : 0)
    }

    /// Starts typing a name: the initial text, then focus on the next runloop turn.
    private func beginRename(_ label: String?) {
        editLabel = label ?? ""
        DispatchQueue.main.async { renameFocused = true }
    }
}

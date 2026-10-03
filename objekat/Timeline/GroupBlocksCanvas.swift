import SwiftUI

// MARK: - The groups' blocks, drawn in the timeline's batched Canvas
//
// A group's block used to ALWAYS be a rich SwiftUI view (`GroupBlockView`): with a dozen open
// groups on screen the cost of a frame was SwiftUI's diff of those views and their layers, not
// the drawing. The batched Canvas (`TimelineView.plainBlocksCanvas`) now draws every "simple"
// group — one that is not renamed, baked, open for editing or under a tool overlay — and this
// file is that drawing. A group a gesture is previewing (move, trim, resize, fade, spill, loop
// bound) is drawn here too, from `BlockPreviewGeometry` (`CanvasGroup.preview`); the fallback
// `RenderPreferences.richPreviews` puts those back on `GroupBlockView`.
//
// It is `GroupBlockView`'s `body`, redrawn value for value (radius 20, tint 0.30 / 0.55, inset
// 2 pt border at 0.5 / 0.9, the custom colour's name band on 20 % of the height, the composite of
// the children through `GroupWaveformDrawing`, the fade veils, the mute veil, the glyph, the name,
// the meta and the chevron). The rich view stays the reference — the Debug A/B switch
// (`DebugRenderSwitches.forceRichBlocks`) puts every group back on it.
//
// The Canvas draws from VALUES resolved by the blocks layer's body (`CanvasGroup`) and reads
// nothing from the view model itself: a renderer closure is not a place to count on observation
// tracking, so whatever a group's look depends on is read in the body, where a change re-evaluates
// the layer.

/// Everything the Canvas needs to know about ONE group, resolved by the blocks layer's body.
struct CanvasGroup {
    let entry: LaneEntry
    var item: SoundObject { entry.item }
    let stem: Color
    let selected: Bool
    /// Filtered out by the text search or silenced by a solo: the whole block at 0.25.
    let dim: Bool
    /// `EditViewModel.displayName(of:)` — the memoised composed name.
    let name: String
    /// `ObjectKindIcon.name(for:isOpenConsolidate:)` — an open consolidated object stays a
    /// waveform in a circle, never a folder.
    let icon: String
    /// Anything in the group's sub-tree lost its file (`containsMissingDescendant`).
    let missing: Bool
    /// Muted in the mix (its own mute or its stem's): the black veil.
    let mutedInMix: Bool
    /// `showsChildrenInline`: the chevron points down.
    let expanded: Bool
    /// The span shared with a crossfaded neighbour at each end (px): the white base is punched
    /// out there, so the neighbour's content still reads (@see `OpaqueBaseMask`).
    let sharedLeading: Double
    let sharedTrailing: Double
    /// What the active tool lays over the block (Volume's minimal veil, Pan's panel…), resolved by
    /// the blocks layer's body. Drawn between the fades and the mute veil.
    var toolOverlay: CanvasToolOverlay? = nil
    /// The loop's IN / OUT bounds, in seconds LOCAL to the block (`previewLoopRange(for:)`): the
    /// composite repeats from the block's left edge and the two grips are drawn. nil = no loop.
    var loopRange: (start: Double, end: Double)? = nil
    /// The geometry of the block while a gesture previews it (move, trim, resize, fade, spill):
    /// where it stands, how long it is, its fades, the start its composite is aligned on. nil =
    /// nothing under way on it, and the stored values are drawn. A reading of the gesture, never a
    /// write (@see `BlockPreviewGeometry`).
    var preview: BlockPreviewGeometry? = nil

    /// The fades on screen, in seconds, and their curves: the gesture's while previewing, else the
    /// stored ones (a group shows its fades as they are, no compression).
    var fadeIn: Double { preview?.effectiveFadeIn ?? item.fadeIn }
    var fadeOut: Double { preview?.effectiveFadeOut ?? item.fadeOut }
    var fadeInCurve: FadeCurve { preview?.effectiveFadeInCurve ?? item.fadeInCurve }
    var fadeOutCurve: FadeCurve { preview?.effectiveFadeOutCurve ?? item.fadeOutCurve }

    var customColor: Color? { item.customColor }
    var outlineColor: Color { item.customColor ?? stem }   // GroupBlockView.effectiveColor
}

/// The text of a block's name run, shared by the clips' pass and the groups' pass of the Canvas:
/// glyph + name (+ meta, + mute badge) in ONE resolved `Text`, cached by what it says. One
/// definition of how the run is built, so the two regimes cannot disagree about the glyph, the
/// red of a missing file or the meta's grey.
struct CanvasLabelCache {
    private var normal: [String: GraphicsContext.ResolvedText] = [:]
    // TWO caches and not one keyed by the pair: two blocks can carry the same name while only one
    // of them has lost its file.
    private var missingOnes: [String: GraphicsContext.ResolvedText] = [:]

    mutating func resolve(_ ctx: GraphicsContext, _ s: String, icon: String, missing: Bool,
                          meta: String, muteBadge: Bool) -> GraphicsContext.ResolvedText {
        // The key carries the icon AND the name: two blocks can share a name and not a kind.
        let key = icon + "\u{0}" + s + "\u{0}" + meta + (muteBadge ? "\u{0}M" : "")
        func build() -> GraphicsContext.ResolvedText {
            // The values come from `MissingFileLabel` / `ObjectKindIcon`, which the rich views
            // read too: a red — or a glyph — that only one regime knows about is one that appears
            // or disappears with the number of objects on screen.
            let weight = missing ? MissingFileLabel.weight : MissingFileLabel.normalWeight
            let colour = missing ? MissingFileLabel.color : Color.black
            let glyph = Text(Image(systemName: icon))
                .font(.system(size: ObjectKindIcon.canvasSize, weight: weight))
            var run = glyph + Text(verbatim: " ") + Text(s)
            if !meta.isEmpty {
                run = run + Text(verbatim: " ").font(.system(size: 9))
                          + Text(verbatim: meta).font(.system(size: 9, weight: .regular))
                                .foregroundColor(.black.opacity(0.5))
            }
            if muteBadge {
                run = run + Text(verbatim: " ").font(.system(size: 9))
                          + Text(L("common.muteBadge")).font(.system(size: 9, weight: .bold))
                                .foregroundColor(.red)
            }
            return ctx.resolve(run
                .font(.system(size: MissingFileLabel.size, weight: weight))
                .foregroundColor(colour))
        }
        if missing {
            if let r = missingOnes[key] { return r }
            let r = build(); missingOnes[key] = r; return r
        }
        if let r = normal[key] { return r }
        let r = build(); normal[key] = r; return r
    }
}

enum GroupBlocksCanvas {

    /// The geometry the Canvas lays blocks out with (the timeline's own, handed in).
    struct Geometry {
        let pixelsPerSecond: Double
        let rulerHeight: Double
        let laneStep: Double
        let blockHeight: Double

        func rect(of g: CanvasGroup) -> CGRect {
            if let p = g.preview {
                return CGRect(x: p.xPos,
                              y: p.yPos(rulerHeight: rulerHeight, displayLane: g.entry.displayLane,
                                        laneStep: laneStep),
                              width: p.blockWidth, height: blockHeight)
            }
            return CGRect(x: g.item.startTime * pixelsPerSecond,
                   y: rulerHeight + Double(g.entry.displayLane) * laneStep,
                   width: max(2, g.item.duration * pixelsPerSecond),
                   height: blockHeight)
        }
    }

    /// The block's corner radius. The path comes from the SAME `RoundedRectangle` the rich view
    /// uses, so the radius is clamped on a small block exactly as SwiftUI clamps it.
    private static func outline(_ rect: CGRect, radius: Double) -> Path {
        RoundedRectangle(cornerRadius: radius).path(in: rect)
    }

    // MARK: Phase 1 — backgrounds

    /// One batch of backgrounds, keyed by (selected, dimmed): every path of a batch is filled in
    /// one operation per colour, the way the clips' backgrounds are.
    private struct Batch {
        var white = Path()
        /// Bases that must be punched out at a crossfade's shared span: drawn one by one.
        var sharedWhite: [(path: Path, keep: CGRect)] = []
        var tint: [Color: Path] = [:]
        var band: [Color: Path] = [:]
        var border: [Color: Path] = [:]
        var isEmpty: Bool { white.isEmpty && sharedWhite.isEmpty && tint.isEmpty && band.isEmpty }
    }

    /// The groups' white base, tint, name band and border — what `GroupBlockView` stacks first.
    /// `groups` arrives with the selected ones LAST (they are drawn above, as `zIndex(1)` did).
    static func drawBackgrounds(into ctx: GraphicsContext, groups: [CanvasGroup], geo: Geometry) {
        guard !groups.isEmpty else { return }
        // Index = (selected ? 2 : 0) + (dim ? 1 : 0).
        var batches = [Batch](repeating: Batch(), count: 4)
        for g in groups {
            let rect = geo.rect(of: g)
            let radius = g.item.blockCornerRadius
            let shape = outline(rect, radius: radius)
            let k = (g.selected ? 2 : 0) + (g.dim ? 1 : 0)
            if g.sharedLeading > 0 || g.sharedTrailing > 0 {
                let keep = CGRect(x: rect.minX + g.sharedLeading, y: rect.minY,
                                  width: max(0, rect.width - g.sharedLeading - g.sharedTrailing),
                                  height: rect.height)
                batches[k].sharedWhite.append((shape, keep))
            } else {
                batches[k].white.addPath(shape)
            }
            if let custom = g.customColor {
                // The name band in the custom colour (20 % of the height, at least 3 pt), the
                // body in the stem's: the same split as a clip, with the band's top corners and
                // the body's bottom corners rounded.
                let bandH = min(rect.height, max(3, geo.blockHeight * 0.20))
                let top = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: bandH)
                let bottom = CGRect(x: rect.minX, y: rect.minY + bandH,
                                    width: rect.width, height: rect.height - bandH)
                batches[k].band[custom, default: Path()].addPath(
                    UnevenRoundedRectangle(topLeadingRadius: radius, topTrailingRadius: radius)
                        .path(in: top))
                batches[k].tint[g.stem, default: Path()].addPath(
                    UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius)
                        .path(in: bottom))
            } else {
                batches[k].tint[g.stem, default: Path()].addPath(shape)
            }
            // `strokeBorder`: the stroke sits INSIDE the block (the shape inset by half the width).
            batches[k].border[g.outlineColor, default: Path()].addPath(
                RoundedRectangle(cornerRadius: radius).inset(by: 1).path(in: rect))
        }
        for k in 0..<4 where !batches[k].isEmpty {
            let selected = k >= 2
            var c = ctx
            c.opacity = (k % 2 == 1) ? 0.25 : 1.0
            let b = batches[k]
            c.fill(b.white, with: .color(.white))
            for (path, keep) in b.sharedWhite {
                var cc = c
                cc.clip(to: Path(keep))
                cc.fill(path, with: .color(.white))
            }
            let tintAlpha = selected ? 0.55 : 0.30
            for (color, path) in b.tint { c.fill(path, with: .color(color.opacity(tintAlpha))) }
            for (color, path) in b.band { c.fill(path, with: .color(color.opacity(tintAlpha))) }
            for (color, path) in b.border {
                c.stroke(path, with: .color(color.opacity(selected ? 0.9 : 0.5)), lineWidth: 2)
            }
        }
    }

    // MARK: Phase 2 — the composites

    /// The composite of each group's children, cut to the block's outline (radius 20: with a
    /// smaller one a child at the very start spilled out of the rounded corners). Drawn after ALL
    /// the backgrounds, which is what keeps a crossfaded neighbour's content visible.
    static func drawComposites(into ctx: GraphicsContext, groups: [CanvasGroup], geo: Geometry,
                               waveformCache: WaveformCache, waveformDisplayDB: Double,
                               scrollOffsetX: CGFloat, viewportWidth: CGFloat) {
        for g in groups {
            guard case .group(let children, _) = g.item.kind, !children.isEmpty else { continue }
            let rect = geo.rect(of: g)
            // Off screen: the cull in `isEntryVisible` has let it through with an 80 px margin,
            // and `draw` bounds itself to the window anyway.
            var gc = ctx
            if g.dim { gc.opacity = 0.25 }
            gc.clip(to: outline(rect, radius: g.item.blockCornerRadius))
            gc.translateBy(x: rect.minX, y: rect.minY)
            let item = g.item
            // A left trim under way moves the window, not the children: the composite is aligned on
            // where the window's left edge now stands (`effectiveStartTime`, the stored start
            // otherwise), over the length being drawn.
            let startTime = g.preview?.effectiveStartTime ?? item.startTime
            let duration = g.preview?.effectiveDuration ?? max(0.01, item.duration)
            let rootMod = GroupWaveformDrawing.rootModifier(
                for: item, absStart: startTime, duration: duration,
                fadeIn: g.fadeIn, fadeOut: g.fadeOut,
                curveIn: g.fadeInCurve, curveOut: g.fadeOutCurve)
            GroupWaveformDrawing.draw(
                into: gc, size: rect.size, waveformCache: waveformCache, children: children,
                groupStartTime: startTime, pixelsPerSecond: geo.pixelsPerSecond,
                stemColor: g.stem, blockXPos: rect.minX,
                scrollOffsetX: scrollOffsetX, viewportWidth: viewportWidth,
                rootMod: rootMod, rootMuted: item.isMuted,
                waveformDisplayDB: waveformDisplayDB, loopRange: g.loopRange)
        }
    }

    // MARK: Phase 3 — fades, mute veil, label

    /// A group's NAME ROW (glyph, name, meta), cropped before the chevron. Its left edge is the
    /// natural one unless a `StickyLabelPass` partitions the names (@see `StickyLabel`): the
    /// ordinary pass skips the names the sticky layer owns, the sticky pass draws only those,
    /// anchored on the exact viewport edge.
    private static func drawLabel(into c: GraphicsContext, g: CanvasGroup, rect: CGRect, fadeInPx: Double,
                                  labels: inout CanvasLabelCache, sticky: StickyLabelPass?) {
        let item = g.item
        let w = rect.width
        let x = rect.minX, y = rect.minY
        let showChevron = w >= 60
        // The name row stops before the chevron (6 pt of padding, the glyph, a gap) so the two
        // never overprint; the rich view truncates the name with an ellipsis there, this one
        // crops it.
        let labelRight = showChevron ? w - 22 : w
        let leading = TimelineLabelMetrics.leading(fadeInPx: fadeInPx, blockWidth: w)
        var labelX = x + leading
        if let sticky {
            guard let placed = sticky.placement(naturalX: labelX, blockX: x, blockWidth: w,
                                                rightLimit: x + labelRight)
            else { return }
            labelX = placed
        }
        var lc = c
        lc.clip(to: Path(CGRect(x: x, y: y, width: max(0, labelRight), height: rect.height)))
        if g.missing {
            // The white glow the rich views lay with `.shadow`: red alone does not survive a
            // red or salmon band (@see MissingFileLabel.haloColor). A filter forces this one
            // block offscreen — armed for the missing ones only.
            lc.addFilter(.shadow(color: MissingFileLabel.haloColor,
                                 radius: MissingFileLabel.haloRadius, x: 0, y: 0))
        }
        // The meta is asked for only when the numbers say it is not empty (a group's speed
        // means nothing): nearly every group has 0 dB and a centred pan.
        let hasMeta = w >= 80
            && (item.volume <= -96 || abs(item.volume) >= 0.5 || abs(item.pan) >= 0.01)
        lc.draw(labels.resolve(c, g.name, icon: g.icon, missing: g.missing,
                               meta: hasMeta ? item.timelineMetaSummary : "", muteBadge: false),
                at: CGPoint(x: labelX,
                            y: y + TimelineLabelMetrics.topInset + TimelineLabelMetrics.canvasCentring),
                anchor: .topLeading)
    }

    /// The STICKY pass for the groups: only the name rows that follow the exact scroll, nothing
    /// else (the fades, the veils and the chevron belong to the ordinary pass).
    static func drawStickyLabels(into ctx: GraphicsContext, groups: [CanvasGroup],
                                 rows: (y0: Double, y1: Double), geo: Geometry,
                                 labels: inout CanvasLabelCache, sticky: StickyLabelPass) {
        for g in groups {
            let rect = geo.rect(of: g)
            guard rect.width >= 30, rect.maxY >= rows.y0, rect.minY <= rows.y1 else { continue }
            var c = ctx
            if g.dim { c.opacity = 0.25 }
            drawLabel(into: c, g: g, rect: rect, fadeInPx: g.fadeIn * geo.pixelsPerSecond,
                      labels: &labels, sticky: sticky)
        }
    }

    /// What `GroupBlockView` stacks over the composite: the fade veils, the mute veil, then the
    /// name row (glyph, name, meta, chevron).
    static func drawOverlays(into ctx: GraphicsContext, groups: [CanvasGroup], geo: Geometry,
                             labels: inout CanvasLabelCache, sticky: StickyLabelPass? = nil) {
        var chevronDown: GraphicsContext.ResolvedText?
        var chevronRight: GraphicsContext.ResolvedText?
        func chevron(_ down: Bool) -> GraphicsContext.ResolvedText {
            if down, let r = chevronDown { return r }
            if !down, let r = chevronRight { return r }
            let r = ctx.resolve(Text(Image(systemName: down ? "chevron.down" : "chevron.right"))
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(.black.opacity(0.5)))
            if down { chevronDown = r } else { chevronRight = r }
            return r
        }

        for g in groups {
            let item = g.item
            let rect = geo.rect(of: g)
            let w = rect.width
            let fadeInPx = g.fadeIn * geo.pixelsPerSecond
            let fadeOutPx = g.fadeOut * geo.pixelsPerSecond
            let needsLabel = w >= 30
            guard needsLabel || fadeInPx > 0 || fadeOutPx > 0 || g.mutedInMix || g.toolOverlay != nil
                    || g.loopRange != nil else { continue }

            var c = ctx
            if g.dim { c.opacity = 0.25 }
            let x = rect.minX, y = rect.minY

            if fadeInPx > 0 || fadeOutPx > 0 {
                let box = CGRect(x: 0, y: 0, width: w, height: rect.height)
                let move = CGAffineTransform(translationX: x, y: y)
                if fadeInPx > 0 {
                    c.fill(FadeVeilShape.path(curve: g.fadeInCurve, widthPx: fadeInPx,
                                              side: .in, in: box).applying(move),
                           with: .color(.black.opacity(0.30)))
                }
                if fadeOutPx > 0 {
                    c.fill(FadeVeilShape.path(curve: g.fadeOutCurve, widthPx: fadeOutPx,
                                              side: .out, in: box).applying(move),
                           with: .color(.black.opacity(0.30)))
                }
            }

            // The loop's IN / OUT grips (a bar and a flag at each bound), over the fades and under
            // the tool's overlay, as the rich view stacks them. Always shown on a looping group.
            if let lr = g.loopRange {
                var grips = Path()
                LoopRangeMarkersView.appendGrips(
                    to: &grips, originX: x, originY: y,
                    startPx: lr.start * geo.pixelsPerSecond, endPx: lr.end * geo.pixelsPerSecond,
                    blockWidth: w, blockHeight: rect.height)
                var gc = c
                gc.addFilter(.shadow(color: .black.opacity(0.5), radius: 1))
                gc.fill(grips, with: .color(g.outlineColor))
            }

            // The tool's overlay, under the mute veil (a GROUP's mute veil stays under every tool,
            // the Volume one included).
            if let overlay = g.toolOverlay {
                var oc = c
                oc.translateBy(x: x, y: y)
                drawToolOverlay(oc, overlay, size: CGSize(width: w, height: rect.height))
            }

            if g.mutedInMix {
                c.fill(outline(rect, radius: item.blockCornerRadius), with: .color(.black.opacity(0.38)))
            }

            guard needsLabel else { continue }
            let showChevron = w >= 60
            drawLabel(into: c, g: g, rect: rect, fadeInPx: fadeInPx, labels: &labels, sticky: sticky)

            if showChevron {
                // 6 pt from the right edge, centred on the name row (3 pt of top inset + half a
                // 12 pt line).
                c.draw(chevron(g.expanded),
                       at: CGPoint(x: x + w - 6, y: y + TimelineLabelMetrics.topInset + 8),
                       anchor: .trailing)
            }
        }
    }
}

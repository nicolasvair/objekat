import SwiftUI

// MARK: - The Volume / Pan / Send / Stem overlays, drawn into a GraphicsContext
//
// PURE drawing functions: a context, a size, the values to show — no view, no model, no state of
// their own beyond the bounded cache below. They are the Canvas counterpart of the rich layers
// (`ToolVolumeLayer`, `ToolVolumeLayerMinimal`, `ToolPanLayer`, `ToolSendLayer`'s knob,
// `ToolStemLayer`), and they read the SAME numbers: the zones, the sizes, the labels and the veil
// opacities all come from `ToolOverlayGeometry`, so the two renderings cannot drift apart.
//
// NOT WIRED to the blocks' Canvas yet. Only the two knobs are shared with the rich layers
// (`PanKnob`, `ToolSendLayer.knob` call `drawPanKnob` / `drawSendKnob`: same strokes, same numbers,
// nothing visible changes).
//
// WHAT IS NOT HERE, on purpose — three asymmetries that belong to the BLOCKS, whoever draws them:
//   • a CLIP's mute veil is hidden under the Volume tool; a GROUP's is not;
//   • under Pan the mute veil lies ON TOP of the pan control (it is drawn after it);
//   • the automation lock (`drawSendKnob`'s `automated`) is only ever drawn under Send.
// None of the functions below draws a mute veil of its own; the one `drawVolumeVeilFull` /
// `drawVolumeVeilMinimal` do draw is the Volume tool's own red tint of the mute zone.
//
// THE CACHE. Resolving a `Text` or an `Image` is the expensive part of drawing a label, and a
// block's level reads one of ~140 whole-dB strings, its pan one of ~201 percentages. A resolved
// text is kept per (string, style, display scale) and drawn with the colour set at the call
// (`ResolvedText.shading`), so the colour is not part of the key. It is BOUNDED: past
// `capacity` entries it is emptied rather than evicted one by one — the working set is a few
// hundred strings, and a flush costs one more resolve per string, once.

// MARK: - Text styles

/// The fonts the overlays use, by role. A closed set on purpose: it is part of the cache key.
enum ToolOverlayTextStyle: Hashable {
    case volumeLevelFull        // 9 semibold monospaced
    case volumeLevelMinimal     // 8 semibold monospaced
    case muteBadge              // 8 bold
    case stepGlyph              // 12 medium
    case panLabel               // 9 semibold monospaced
    case stemLabel              // 9 semibold

    var font: Font {
        switch self {
        case .volumeLevelFull:    return .system(size: 9, weight: .semibold, design: .monospaced)
        case .volumeLevelMinimal: return .system(size: 8, weight: .semibold, design: .monospaced)
        case .muteBadge:          return .system(size: 8, weight: .bold)
        case .stepGlyph:          return .system(size: 12, weight: .medium)
        case .panLabel:           return .system(size: 9, weight: .semibold, design: .monospaced)
        case .stemLabel:          return .system(size: 9, weight: .semibold)
        }
    }
}

// MARK: - The bounded cache

final class ToolOverlayResolveCache: @unchecked Sendable {
    static let shared = ToolOverlayResolveCache()

    /// Twice the working set (~140 dB strings + ~201 pan strings — 334 distinct measured — plus the
    /// fixed glyphs and the stem labels), and small enough to be nothing in memory.
    static let capacity = 768

    private struct TextKey: Hashable {
        let string: String
        let style: ToolOverlayTextStyle
        let scale: Int          // display scale ×100
    }
    private struct SymbolKey: Hashable {
        let name: String
        let scale: Int
    }

    private let lock = NSLock()
    private var texts: [TextKey: GraphicsContext.ResolvedText] = [:]
    private var symbols: [SymbolKey: GraphicsContext.ResolvedImage] = [:]

    /// How many entries are held — for a diagnostic or a test, never for the drawing.
    var entryCount: Int {
        lock.lock(); defer { lock.unlock() }
        return texts.count + symbols.count
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        texts.removeAll(keepingCapacity: true)
        symbols.removeAll(keepingCapacity: true)
    }

    /// `string` resolved in `style`. The returned value carries no colour of its own: set its
    /// `shading` before drawing it.
    func text(_ string: String, style: ToolOverlayTextStyle,
              in ctx: GraphicsContext) -> GraphicsContext.ResolvedText {
        let key = TextKey(string: string, style: style, scale: Self.scaleKey(ctx))
        lock.lock()
        if let hit = texts[key] { lock.unlock(); return hit }
        lock.unlock()
        // Resolved OUTSIDE the lock: it is the slow part, and it needs nothing the lock guards.
        let resolved = ctx.resolve(Text(verbatim: string).font(style.font))
        lock.lock(); defer { lock.unlock() }
        if texts.count + symbols.count >= Self.capacity {
            texts.removeAll(keepingCapacity: true)
            symbols.removeAll(keepingCapacity: true)
        }
        texts[key] = resolved
        return resolved
    }

    /// The SF symbol `name` resolved at the system's default size; the caller scales it.
    func symbol(_ name: String, in ctx: GraphicsContext) -> GraphicsContext.ResolvedImage {
        let key = SymbolKey(name: name, scale: Self.scaleKey(ctx))
        lock.lock()
        if let hit = symbols[key] { lock.unlock(); return hit }
        lock.unlock()
        let resolved = ctx.resolve(Image(systemName: name))
        lock.lock(); defer { lock.unlock() }
        if texts.count + symbols.count >= Self.capacity {
            texts.removeAll(keepingCapacity: true)
            symbols.removeAll(keepingCapacity: true)
        }
        symbols[key] = resolved
        return resolved
    }

    private static func scaleKey(_ ctx: GraphicsContext) -> Int {
        Int((ctx.environment.displayScale * 100).rounded())
    }
}

// MARK: - Helpers

/// The point size SF symbols are resolved at, so a symbol drawn at `pointSize` is scaled by
/// `pointSize / symbolBaseSize`.
private let symbolBaseSize: Double = 13

/// Draws `string` centred on `center`, in `style` and `color`. When `maxWidth` is given and the text
/// is wider, it is scaled down — never below `minScale` (the rich layers' `minimumScaleFactor`);
/// what is still too wide is left to the caller's clip. Returns the SIZE it occupies, scale applied.
@discardableResult
private func drawOverlayText(_ ctx: GraphicsContext, _ string: String, style: ToolOverlayTextStyle,
                             color: Color, at center: CGPoint,
                             maxWidth: Double? = nil, minScale: Double = 0.5) -> CGSize {
    var resolved = ToolOverlayResolveCache.shared.text(string, style: style, in: ctx)
    resolved.shading = .color(color)
    let natural = resolved.measure(in: CGSize(width: 10_000, height: 10_000))
    var scale = 1.0
    if let maxWidth, maxWidth > 0, natural.width > maxWidth {
        scale = max(minScale, maxWidth / natural.width)
    }
    if scale == 1 {
        ctx.draw(resolved, at: center, anchor: .center)
    } else {
        var scaled = ctx
        scaled.translateBy(x: center.x, y: center.y)
        scaled.scaleBy(x: scale, y: scale)
        scaled.draw(resolved, at: .zero, anchor: .center)
    }
    return CGSize(width: natural.width * scale, height: natural.height * scale)
}

/// Draws the SF symbol `name` at `pointSize`, centred on `center`. Returns the size it occupies.
@discardableResult
private func drawOverlaySymbol(_ ctx: GraphicsContext, _ name: String, pointSize: Double,
                               color: Color, at center: CGPoint) -> CGSize {
    var resolved = ToolOverlayResolveCache.shared.symbol(name, in: ctx)
    resolved.shading = .color(color)
    let k = pointSize / symbolBaseSize
    let size = CGSize(width: resolved.size.width * k, height: resolved.size.height * k)
    ctx.draw(resolved, in: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                                  width: size.width, height: size.height))
    return size
}

/// The block's visible sub-window (LOCAL coordinates) the controls are laid on; nil = the whole
/// block. The same convention as the layers' `span`.
private func overlaySpan(_ span: (x: Double, width: Double)?, _ size: CGSize) -> (x: Double, width: Double) {
    (span?.x ?? 0, span?.width ?? size.width)
}

/// A copy of `ctx` clipped to the block's rounded rectangle — the veils' own clip.
private func clippedToBlock(_ ctx: GraphicsContext, size: CGSize, cornerRadius: Double) -> GraphicsContext {
    var c = ctx
    c.clip(to: Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: cornerRadius))
    return c
}

// MARK: - Pan knob

/// Half the angular travel (in degrees) of the pan knob, on either side of the centre.
let panKnobSweepDegrees: Double = 135

/// The pan knob: a travel arc (−135°…+135°), the arc covered from the centre (12 o'clock) to the
/// value, an index and a centre mark. `PanKnob` draws through it.
func drawPanKnob(_ ctx: GraphicsContext, pan: Float, size: CGSize) {
    let sweep = panKnobSweepDegrees
    let r = min(size.width, size.height) / 2
    let c = CGPoint(x: size.width / 2, y: size.height / 2)
    let ringR = r - 1.5
    let value = Double(max(-1, min(1, pan)))

    // The full travel (the track)
    // The reference: 0° = 3 o'clock, −90° = 12 o'clock (y downwards); the travel runs from
    // −90−135 to −90+135, an arc opening downwards, like a console knob.
    var track = Path()
    track.addArc(center: c, radius: ringR,
                 startAngle: .degrees(-90 - sweep),
                 endAngle: .degrees(-90 + sweep),
                 clockwise: false)
    ctx.stroke(track, with: .color(.white.opacity(0.22)),
               style: StrokeStyle(lineWidth: 2.5, lineCap: .round))

    // The portion covered from the centre (12 o'clock) → the L/R offset reads at once
    if abs(value) > 0.005 {
        let end = -90 + value * sweep
        var arc = Path()
        arc.addArc(center: c, radius: ringR,
                   startAngle: .degrees(-90), endAngle: .degrees(end),
                   clockwise: value < 0)
        ctx.stroke(arc, with: .color(.white.opacity(0.85)),
                   style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
    }

    // The centre mark
    var center = Path()
    center.move(to: CGPoint(x: c.x, y: c.y - ringR - 0.5))
    center.addLine(to: CGPoint(x: c.x, y: c.y - ringR + 3))
    ctx.stroke(center, with: .color(.white.opacity(0.35)), lineWidth: 1)

    // The index
    let a = CGFloat((-90 + value * sweep) * Double.pi / 180)
    var needle = Path()
    needle.move(to: CGPoint(x: c.x + cos(a) * (ringR - 6.5), y: c.y + sin(a) * (ringR - 6.5)))
    needle.addLine(to: CGPoint(x: c.x + cos(a) * (ringR - 1.5), y: c.y + sin(a) * (ringR - 1.5)))
    ctx.stroke(needle, with: .color(.white),
               style: StrokeStyle(lineWidth: 2, lineCap: .round))
}

// MARK: - Send knob

/// A send's rotary knob: a background arc plus a value arc (red) and a pointer, a 270° sweep.
/// `ToolSendLayer` draws its knob through it.
///
/// `automated`: a level driven by a CURVE is shown faded and carries the automation glyph — it still
/// SAYS what the send is doing, but no longer answers the hand. The glyph stays bright over the
/// faded knob (a reason as dim as the thing it explains explains nothing). That lock is the SEND
/// tool's alone: no other tool's overlay ever draws it.
func drawSendKnob(_ ctx: GraphicsContext, level: Float, enabled: Bool, focused: Bool,
                  automated: Bool = false, size: CGSize,
                  minDb: Float = sendMinDb, maxDb: Float = sendMaxDb) {
    let c = CGPoint(x: size.width / 2, y: size.height / 2)
    let r = min(size.width, size.height) / 2 - 2
    let startA = Angle.degrees(135)
    let sweep  = 270.0
    let frac   = ToolOverlayGeometry.sendKnobFraction(level: level, minDb: minDb, maxDb: maxDb)
    let valA   = Angle.degrees(135 + sweep * frac)

    var knobCtx = ctx
    if automated { knobCtx.opacity = 0.35 }

    // The background arc
    var bg = Path()
    bg.addArc(center: c, radius: r, startAngle: startA,
              endAngle: .degrees(135 + sweep), clockwise: false)
    knobCtx.stroke(bg, with: .color(.white.opacity(0.22)),
                   style: StrokeStyle(lineWidth: 2.5, lineCap: .round))

    // The value arc
    if frac > 0.001 {
        var val = Path()
        val.addArc(center: c, radius: r, startAngle: startA,
                   endAngle: valA, clockwise: false)
        let col: Color = enabled ? .red : .white.opacity(0.4)
        if focused && enabled {
            knobCtx.stroke(val, with: .color(.red.opacity(0.35)),
                           style: StrokeStyle(lineWidth: 6, lineCap: .round))
        }
        knobCtx.stroke(val, with: .color(col),
                       style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
    }

    // The pointer
    let px = c.x + cos(valA.radians) * r
    let py = c.y + sin(valA.radians) * r
    knobCtx.fill(Path(ellipseIn: CGRect(x: px - 2.2, y: py - 2.2, width: 4.4, height: 4.4)),
                 with: .color(enabled ? .red : .white.opacity(0.6)))

    // The lock's glyph, BRIGHT over the faded knob.
    if automated {
        drawOverlaySymbol(ctx, "point.topleft.down.curvedto.point.bottomright.up",
                          pointSize: max(7, min(size.width, size.height) * 0.5),
                          color: .white.opacity(0.9), at: c)
    }
}

// MARK: - Pan panel

/// The Pan tool's whole overlay: the 80 % veil over the block, the knob and the reading under it
/// ("C", "L 40 %", …), laid on the visible `span` so it stays reachable when the block overflows the
/// viewport. The block's mute veil is NOT drawn here — under Pan it lies on top of this panel.
func drawPanOverlay(_ ctx: GraphicsContext, size: CGSize, pan: Float,
                    span: (x: Double, width: Double)? = nil,
                    cornerRadius: Double = ToolOverlayGeometry.cornerRadius) {
    let s = overlaySpan(span, size)
    let c = clippedToBlock(ctx, size: size, cornerRadius: cornerRadius)
    let panel = CGRect(x: s.x, y: 0, width: s.width, height: size.height)
    c.fill(Path(roundedRect: panel, cornerRadius: cornerRadius),
           with: .color(.black.opacity(ToolOverlayGeometry.panVeilOpacity)))

    // The knob above, the reading under it, the pair centred as a VStack(spacing: 2) is.
    let k = ToolOverlayGeometry.panKnobSize(visibleWidth: s.width, height: size.height)
    var label = ToolOverlayResolveCache.shared.text(ToolOverlayGeometry.panLabel(pan: pan),
                                                    style: .panLabel, in: c)
    let labelH = label.measure(in: CGSize(width: 10_000, height: 10_000)).height
    label.shading = .color(.white)
    let total = k + 2 + labelH
    let top = (size.height - total) / 2
    let mid = s.x + s.width / 2
    drawPanKnob(c, pan: pan, size: CGSize(width: k, height: k), at: CGPoint(x: mid - k / 2, y: top))
    c.draw(label, at: CGPoint(x: mid, y: top + k + 2 + labelH / 2), anchor: .center)
}

/// `drawPanKnob` placed at `origin` (the knob's top-left corner in the block's coordinates).
func drawPanKnob(_ ctx: GraphicsContext, pan: Float, size: CGSize, at origin: CGPoint) {
    var placed = ctx
    placed.translateBy(x: origin.x, y: origin.y)
    drawPanKnob(placed, pan: pan, size: size)
}

// MARK: - Volume veils

/// The Volume tool's MINIMAL veil — what a selected or a narrow block shows: a 65 % veil, the red
/// tint of a muted object and the level, centred on the visible `span` (centred on the block with
/// none). The level is scaled down to fit, never below half.
func drawVolumeVeilMinimal(_ ctx: GraphicsContext, size: CGSize, volume: Float, isMuted: Bool,
                           span: (x: Double, width: Double)? = nil,
                           cornerRadius: Double = ToolOverlayGeometry.cornerRadius) {
    let s = overlaySpan(span, size)
    let c = clippedToBlock(ctx, size: size, cornerRadius: cornerRadius)
    let whole = CGRect(origin: .zero, size: size)
    c.fill(Path(whole), with: .color(.black.opacity(ToolOverlayGeometry.volumeMinimalVeilOpacity)))
    if isMuted {
        c.fill(Path(whole), with: .color(.red.opacity(ToolOverlayGeometry.volumeMinimalMuteTintOpacity)))
    }
    drawOverlayText(c, ToolOverlayGeometry.volumeLabel(db: volume, compact: true),
                    style: .volumeLevelMinimal,
                    color: isMuted ? Color.red.opacity(0.85) : Color.white.opacity(0.9),
                    at: CGPoint(x: s.x + s.width / 2, y: size.height / 2),
                    maxWidth: s.width - 4, minScale: 0.5)
}

/// The Volume tool's FULL veil — the hovered block: an 80 % veil and three zones across the visible
/// `span`, mute (40 %), ± 1 dB (20 %) and level (40 %), the red tint over the mute zone when the
/// object is muted. The zones are `ToolOverlayGeometry.volumeZone`'s, which the gestures read.
func drawVolumeVeilFull(_ ctx: GraphicsContext, size: CGSize, volume: Float, isMuted: Bool,
                        muteLabel: String,
                        span: (x: Double, width: Double)? = nil,
                        cornerRadius: Double = ToolOverlayGeometry.cornerRadius) {
    let s = overlaySpan(span, size)
    let c = clippedToBlock(ctx, size: size, cornerRadius: cornerRadius)
    c.fill(Path(CGRect(origin: .zero, size: size)),
           with: .color(.black.opacity(ToolOverlayGeometry.volumeFullVeilOpacity)))

    let sw = s.width
    let mw = ToolOverlayGeometry.volumeMuteColumnWidth(spanWidth: sw)
    let stepW = ToolOverlayGeometry.volumeStepColumnWidth(spanWidth: sw)
    let dragW = ToolOverlayGeometry.volumeDragColumnWidth(spanWidth: sw)
    let div = ToolOverlayGeometry.volumeDividerWidth
    let h = size.height

    // The mute zone's red tint, over the mute column's 40 %.
    if isMuted {
        c.fill(Path(CGRect(x: s.x, y: 0, width: mw, height: h)),
               with: .color(.red.opacity(ToolOverlayGeometry.volumeMuteTintOpacity)))
    }

    // The three columns plus two dividers add up to the span less 2: the row they form is
    // centred in the span, which shifts it by one pixel (as the layer's HStack does).
    var x = s.x + (sw - (mw + div + stepW + div + dragW)) / 2
    let divider = Color.white.opacity(0.2)

    // — Mute (40 %) —
    let muteColor: Color = isMuted ? .red : .white.opacity(0.6)
    do {
        // The icon above the badge, the pair centred (VStack, spacing 1).
        let iconName = isMuted ? "speaker.slash.fill" : "speaker.wave.2"
        let iconH = ToolOverlayResolveCache.shared.symbol(iconName, in: c).size.height * (9 / symbolBaseSize)
        let badge = ToolOverlayResolveCache.shared.text(muteLabel, style: .muteBadge, in: c)
            .measure(in: CGSize(width: 10_000, height: 10_000))
        let top = (h - (iconH + 1 + badge.height)) / 2
        let mid = x + mw / 2
        drawOverlaySymbol(c, iconName, pointSize: 9, color: muteColor,
                          at: CGPoint(x: mid, y: top + iconH / 2))
        drawOverlayText(c, muteLabel, style: .muteBadge, color: muteColor,
                        at: CGPoint(x: mid, y: top + iconH + 1 + badge.height / 2))
    }
    x += mw
    c.fill(Path(CGRect(x: x, y: 0, width: div, height: h)), with: .color(divider))
    x += div

    // — +/− (20 %) —: two halves split by a 1 px line.
    let halfH = (h - 1) / 2
    drawOverlayText(c, "+", style: .stepGlyph, color: .white, at: CGPoint(x: x + stepW / 2, y: halfH / 2))
    c.fill(Path(CGRect(x: x, y: halfH, width: stepW, height: 1)), with: .color(divider))
    drawOverlayText(c, "−", style: .stepGlyph, color: .white,
                    at: CGPoint(x: x + stepW / 2, y: halfH + 1 + halfH / 2))
    x += stepW
    c.fill(Path(CGRect(x: x, y: 0, width: div, height: h)), with: .color(divider))
    x += div

    // — Drag (40 %) —: the level over a ↕ glyph, the pair centred (VStack, spacing 2).
    let levelColor: Color = isMuted ? Color.red.opacity(0.8) : .white
    let level = ToolOverlayResolveCache.shared
        .text(ToolOverlayGeometry.volumeLabel(db: volume, compact: false), style: .volumeLevelFull, in: c)
        .measure(in: CGSize(width: 10_000, height: 10_000))
    let arrowH = ToolOverlayResolveCache.shared.symbol("arrow.up.arrow.down", in: c).size.height * (7 / symbolBaseSize)
    let top = (h - (level.height + 2 + arrowH)) / 2
    let mid = x + dragW / 2
    drawOverlayText(c, ToolOverlayGeometry.volumeLabel(db: volume, compact: false),
                    style: .volumeLevelFull, color: levelColor,
                    at: CGPoint(x: mid, y: top + level.height / 2))
    drawOverlaySymbol(c, "arrow.up.arrow.down", pointSize: 7, color: .white.opacity(0.4),
                      at: CGPoint(x: mid, y: top + level.height + 2 + arrowH / 2))
}

// MARK: - Stem veil

/// The Stem tool's hover veil: a 72 % veil and one line — a dot in the stem's colour and the text
/// announcing the assignment (`label`, already localised and formatted by the caller), centred on
/// the visible `span`. Not a tooltip: it reads on the object itself, the instant it is the target.
func drawStemVeil(_ ctx: GraphicsContext, size: CGSize, label: String, color: Color,
                  span: (x: Double, width: Double)? = nil,
                  cornerRadius: Double = ToolOverlayGeometry.cornerRadius) {
    let s = overlaySpan(span, size)
    let c = clippedToBlock(ctx, size: size, cornerRadius: cornerRadius)
    c.fill(Path(CGRect(origin: .zero, size: size)),
           with: .color(.black.opacity(ToolOverlayGeometry.stemVeilOpacity)))

    // dot (8) + 5 + text, in a row padded by 4 each side; the text scales down to 0.6 to fit.
    let dot = 8.0, gap = 5.0, pad = 4.0
    let avail = max(0, s.width - 2 * pad - dot - gap)
    let natural = ToolOverlayResolveCache.shared.text(label, style: .stemLabel, in: c)
        .measure(in: CGSize(width: 10_000, height: 10_000))
    let scale = natural.width > avail && avail > 0 ? max(0.6, avail / natural.width) : 1
    let textW = natural.width * scale
    let rowW = dot + gap + textW
    // Too wide even scaled: the row keeps its left padding and the block's clip cuts its tail,
    // where the layer's `lineLimit(1)` would have truncated it.
    let left = max(s.x + pad, s.x + (s.width - rowW) / 2)
    let midY = size.height / 2
    c.fill(Path(ellipseIn: CGRect(x: left, y: midY - dot / 2, width: dot, height: dot)), with: .color(color))
    drawOverlayText(c, label, style: .stemLabel, color: .white,
                    at: CGPoint(x: left + dot + gap + textW / 2, y: midY),
                    maxWidth: avail, minScale: 0.6)
}

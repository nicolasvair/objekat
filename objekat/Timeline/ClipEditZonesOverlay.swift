import SwiftUI

// MARK: - A block's editing zones (the selection tool)

/// The six sub-zones of a block under the selection tool. Their geometry is the same as the one
/// used by `updateCursor` and by `handleCanvasDrag` — a single definition for the cursor, the
/// gesture and this hover rendering.
enum ClipEditZone: Equatable {
    case fadeIn, fadeOut       // the upper half, left / right handles
    case trimLeft, resizeRight // the lower half, left / right handles
    case timeSelect            // the upper half, centre — selecting a range
    case move                  // the lower half, centre — moving
    case loopIn, loopOut       // full height, the loop's IN/OUT markers (@see [[loop-item-plan]])

    /// The zone aimed at inside a block, in coordinates LOCAL to the block. The single definition
    /// of the carve-up: the cursor (`updateCursor`), the gesture (`handleCanvasDrag`) and the
    /// double click (`handleCanvasTap`) all go through here.
    ///
    /// A fade THAT IS SET can be grabbed from anywhere in its grey triangle — beyond the handle
    /// too when it is long — but ONLY in the upper half: the lower half is left to trimming and
    /// resizing, which a somewhat long fade would otherwise confiscate.
    /// With no fade (0), the carve-up is exactly what it was.
    ///
    /// `loopInPx`/`loopOutPx`: the position (in px local to the block) of the loop's IN/OUT
    /// markers, or nil if the object does not loop / the marker falls outside the current block
    /// (V1 scope, @see [[loop-item-plan]] — a CLIP loop point can go beyond [0,bw] but is then
    /// not draggable from THIS block). They take priority over everything else: a narrow
    /// full-height target, tested before the handles/triangles that would otherwise cover the same pixel.
    static func resolve(localX: Double, localY: Double,
                        blockWidth bw: Double, blockHeight bh: Double,
                        handleW: Double,
                        fadeInPx: Double, fadeOutPx: Double,
                        loopInPx: Double? = nil, loopOutPx: Double? = nil) -> ClipEditZone {
        let loopTol = 5.0
        if let lip = loopInPx, abs(localX - lip) <= loopTol { return .loopIn }
        if let lop = loopOutPx, abs(localX - lop) <= loopTol { return .loopOut }

        let upper = localY < bh * 0.50
        if bh > 0, upper {
            // Fade triangles: (0,0)-(fiPx,0)-(0,bh) and (bw-foPx,0)-(bw,0)-(bw,bh).
            if fadeInPx > 1, (localX / fadeInPx + localY / bh) <= 1 { return .fadeIn }
            if fadeOutPx > 1, ((bw - localX) / fadeOutPx + localY / bh) <= 1 { return .fadeOut }
        }
        if handleW > 0 && localX < handleW      { return upper ? .fadeIn  : .trimLeft }
        if handleW > 0 && localX > bw - handleW { return upper ? .fadeOut : .resizeRight }
        return upper ? .timeSelect : .move
    }
}

/// The hovered block and the active zone, resolved by the canvas (the block stays pure presentation).
struct EditZoneHover: Equatable {
    let id: UUID
    /// The block's rect in canvas coordinates.
    let rect: CGRect
    /// The width of the side handles (0 = the block is too narrow, no handle).
    let handleW: Double
    let zone: ClipEditZone
    /// The hovered block's radius (a clip = 4, a group / aux / infinite bus = 20), so that the veil
    /// hugs its shape exactly.
    let cornerRadius: Double
    /// The widths of the fades that are set (px): when the zone aimed at is a fade ALREADY set, the
    /// veil hugs its triangle — that whole surface answers the gesture (see `ClipEditZone.resolve`).
    var fadeInW: Double = 0
    var fadeOutW: Double = 0
    /// The position (in local px) of the marker aimed at, for `.loopIn`/`.loopOut` only.
    var loopMarkerX: Double = 0
}

/// Two full-height vertical bars marking a loop's IN/OUT bounds, each topped with a small flag
/// to show it can be grabbed and dragged. Purely decorative — the drag is resolved by the
/// canvas (@see TimelineView+DragHandler.LoopRangeDragState), and it is shared by
/// SoundBlockView (clip/MIDI) and GroupBlockView. @see [[loop-item-plan]]
struct LoopRangeMarkersView: View {
    let startPx: Double
    let endPx: Double
    let blockWidth: Double
    let blockHeight: Double
    var color: Color = .white

    private let flagW: Double = 6
    private let flagH: Double = 8

    /// The width of the template carrying the bar AND its flag. Fixed, and that is the whole point:
    /// a `Path` is a FLEXIBLE shape, it takes the size it is offered. Under a `.position` the offer
    /// is the parent's — so the flag was drawn in a frame as wide as the whole block, its x=0
    /// falling at the block's left edge while the bar, having a fixed width, centred properly on
    /// the marker. Hence a flag offset by HALF A BLOCK WIDTH, that is, by several bars on a long
    /// group, and by less the shorter the block was. A fixed template = both in the same frame.
    private var markerBoxW: Double { flagW * 2 }

    @ViewBuilder
    private func marker(at x: Double, flagLeading: Bool) -> some View {
        // A marker OUTSIDE the block: not drawn. A bound can live outside the current window — a
        // 'sampler-style' loop point on a clip, or the right half of a cut looped group, whose IN
        // point precedes its own start (@see SoundObject.loopRangeStart,
        // EditViewModel.loopedGroupRightHalf). Folding it back to the edge would show a flag where
        // there is nothing to grab: `ClipEditZone.resolve` already only returns `.loopIn`/`.loopOut`
        // for a bound falling INSIDE the block.
        if x >= -0.5 && x <= blockWidth + 0.5 {
            marker(atClamped: max(0, min(blockWidth, x)), flagLeading: flagLeading)
        }
    }

    private func marker(atClamped x: Double, flagLeading: Bool) -> some View {
        let cx = markerBoxW / 2          // the marker's axis WITHIN the template
        return ZStack {
            Rectangle()
                .fill(color)
                .frame(width: 1.5, height: blockHeight)
            Path { p in
                p.move(to: CGPoint(x: cx, y: 0))
                p.addLine(to: CGPoint(x: flagLeading ? cx + flagW : cx - flagW, y: 0))
                p.addLine(to: CGPoint(x: cx, y: flagH))
                p.closeSubpath()
            }
            .fill(color)
            .frame(width: markerBoxW, height: blockHeight, alignment: .topLeading)
        }
        .frame(width: markerBoxW, height: blockHeight)
        .shadow(color: .black.opacity(0.5), radius: 1)
        .position(x: x, y: blockHeight / 2)
    }

    var body: some View {
        ZStack {
            marker(at: startPx, flagLeading: true)
            marker(at: endPx, flagLeading: false)
        }
        .frame(width: blockWidth, height: blockHeight)
    }
}

/// A gradient darkening over the one zone that would answer the click — towards BLACK, never
/// towards white: on blocks that are already light and coloured, a white veil read badly (and
/// washed the waveform out), where a shadow carries over every hue. No hard edge anywhere: the
/// veil is the product of two gradients (one horizontal, one vertical), so it dies out before
/// reaching its zone's boundary. The separators of the six zones were removed — gridding the
/// block up on hover made it talkative.
///
/// Purely decorative: no interaction (everything is resolved geometrically by the canvas).
struct ClipEditZonesOverlay: View {
    let hover: EditZoneHover

    /// The veil's tint. BLACK: @see the type's documentation — it is the only place to change to
    /// go back to a light veil (the mask's white is not a colour but an alpha).
    private static let veil: Color = .black
    /// The veil's opacity right at the edge concerned, before the two gradients. It only reaches
    /// that at the anchoring corner and falls to zero everywhere else.
    private static let peak: Double = 0.2
    /// The length (px) over which the central zones light up then die out, on the left and on the
    /// right. Bounded at 40 % of the zone so as to stay gradual even on a narrow block.
    private static let featherPx: Double = 44

    /// A single Canvas: the horizontal gradient is painted into a layer, then multiplied by a
    /// vertical gradient (`.destinationIn`). That product is what makes no edge of the veil sharp —
    /// neither in the middle of the block, nor at the handles' boundary.
    var body: some View {
        let r = hover.rect
        Canvas { ctx, _ in
            let spec  = veilSpec(width: r.width, height: r.height)
            guard spec.rect.width > 0, spec.rect.height > 0 else { return }
            // A fade that is set is grabbed by its whole triangle → the veil hugs that shape.
            let shape = trianglePath(width: r.width, height: r.height) ?? Path(spec.rect)

            ctx.clip(to: Path(roundedRect: CGRect(origin: .zero, size: r.size),
                              cornerRadius: hover.cornerRadius))
            ctx.drawLayer { layer in
                layer.fill(shape, with: .linearGradient(
                    Gradient(stops: spec.stops),
                    startPoint: CGPoint(x: spec.rect.minX, y: 0),
                    endPoint:   CGPoint(x: spec.rect.maxX, y: 0)))

                var mask = layer
                mask.blendMode = .destinationIn
                mask.fill(shape, with: .linearGradient(
                    Gradient(colors: [.white, .white.opacity(0)]),
                    startPoint: spec.maskFrom, endPoint: spec.maskTo))
            }
        }
        .frame(width: r.width, height: r.height)
        .offset(x: r.minX, y: r.minY)
        .allowsHitTesting(false)
    }

    private struct VeilSpec {
        var rect: CGRect
        var stops: [Gradient.Stop]
        /// Vertical fade-out: full at the anchoring edge (`maskFrom`), zero at the other end.
        var maskFrom: CGPoint
        var maskTo: CGPoint
    }

    /// The geometry and gradients of the zone aimed at.
    /// - handles: the veil is at its strongest ON the grabbed edge and dies out inwards;
    /// - central zones (selecting a range, moving): it lights up from the top or bottom edge
    ///   and dies out gradually towards the left AND the right, so that no vertical line comes
    ///   to mark the handles' boundary.
    private func veilSpec(width w: Double, height h: Double) -> VeilSpec {
        let hw   = hover.handleW
        let mid  = h / 2
        let peak = Self.veil.opacity(Self.peak)
        let none = Self.veil.opacity(0)

        // A handle's gradient: full at the grabbed edge, out at the inner boundary.
        func fromEdge(_ leftAnchored: Bool) -> [Gradient.Stop] {
            leftAnchored
                ? [.init(color: peak, location: 0), .init(color: none, location: 1)]
                : [.init(color: none, location: 0), .init(color: peak, location: 1)]
        }
        // A central zone's gradient: symmetrical lighting up and dying out at the edges.
        func centered(_ width: Double) -> [Gradient.Stop] {
            let f = min(0.4, Self.featherPx / max(width, 1))
            return [.init(color: none, location: 0),
                    .init(color: peak, location: f),
                    .init(color: peak, location: 1 - f),
                    .init(color: none, location: 1)]
        }

        // A zone's vertical fade-out: full at the outer edge, zero at the other end. The top
        // zones die out downwards, the bottom ones upwards — so the middle line is never
        // drawn.
        func mask(_ rect: CGRect, fromTop: Bool) -> (CGPoint, CGPoint) {
            fromTop ? (CGPoint(x: 0, y: rect.minY), CGPoint(x: 0, y: rect.maxY))
                    : (CGPoint(x: 0, y: rect.maxY), CGPoint(x: 0, y: rect.minY))
        }

        let rect: CGRect
        let stops: [Gradient.Stop]
        let fromTop: Bool

        switch hover.zone {
        case .fadeIn where hover.fadeInW > 1:
            // A fade that is set: the triangle carries the shape, but only its UPPER HALF answers the
            // gesture (the lower one is left to trimming) — so the vertical fade-out dies out at
            // half height, without drawing the middle line.
            rect = CGRect(x: 0, y: 0, width: min(hover.fadeInW, w), height: mid)
            stops = fromEdge(true); fromTop = true
        case .fadeOut where hover.fadeOutW > 1:
            let fw = min(hover.fadeOutW, w)
            rect = CGRect(x: w - fw, y: 0, width: fw, height: mid)
            stops = fromEdge(false); fromTop = true
        case .fadeIn:
            rect = CGRect(x: 0, y: 0, width: hw, height: mid)
            stops = fromEdge(true); fromTop = true
        case .fadeOut:
            rect = CGRect(x: w - hw, y: 0, width: hw, height: mid)
            stops = fromEdge(false); fromTop = true
        case .trimLeft:
            rect = CGRect(x: 0, y: mid, width: hw, height: h - mid)
            stops = fromEdge(true); fromTop = false
        case .resizeRight:
            rect = CGRect(x: w - hw, y: mid, width: hw, height: h - mid)
            stops = fromEdge(false); fromTop = false
        case .timeSelect:
            rect = CGRect(x: hw, y: 0, width: max(0, w - 2 * hw), height: mid)
            stops = centered(rect.width); fromTop = true
        case .move:
            rect = CGRect(x: hw, y: mid, width: max(0, w - 2 * hw), height: h - mid)
            stops = centered(rect.width); fromTop = false
        case .loopIn, .loopOut:
            // A narrow full-height band, centred on the marker — no upper/lower half.
            let mw = 8.0
            let x = max(0, min(w - mw, hover.loopMarkerX - mw / 2))
            rect = CGRect(x: x, y: 0, width: mw, height: h)
            stops = centered(mw); fromTop = true
        }

        let m = mask(rect, fromTop: fromTop)
        return VeilSpec(rect: rect, stops: stops, maskFrom: m.0, maskTo: m.1)
    }

    /// The triangle of the fade aimed at if it is already set (otherwise nil → the handle's veil).
    private func trianglePath(width w: Double, height h: Double) -> Path? {
        var p = Path()
        switch hover.zone {
        case .fadeIn where hover.fadeInW > 1:
            p.move(to: .zero)
            p.addLine(to: CGPoint(x: min(hover.fadeInW, w), y: 0))
            p.addLine(to: CGPoint(x: 0, y: h))
        case .fadeOut where hover.fadeOutW > 1:
            p.move(to: CGPoint(x: w - min(hover.fadeOutW, w), y: 0))
            p.addLine(to: CGPoint(x: w, y: 0))
            p.addLine(to: CGPoint(x: w, y: h))
        default:
            return nil
        }
        p.closeSubpath()
        return p
    }
}

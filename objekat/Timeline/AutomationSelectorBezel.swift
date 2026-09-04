import SwiftUI

/// The 'objects / automations' hem — the mode selector of an object with TWO things to show
/// (a group: its children or its curves; a MIDI clip: its piano roll or its curves).
///
/// Its shape: a plateau rising from the block's LOWER edge through two S-shaped shoulders,
/// filled with the material of the object's INSIDE (@see TimelineView.interiorPaint) — the hem
/// is a piece of what opens underneath, brought up into the block. That is what ties it to its
/// object beyond doubt, a group INSIDE a group included: it is in the block, it no longer
/// floats beside it (@see the badge it replaces, the old `automationSelectorRect`).
///
/// It exists only on an OPEN object (unfolded content or an automation band): folded, an object
/// has nothing to hem, and reopens through its double click (the block's lower half) or
/// ⌥double click for the automation band. That is a knowing departure from the original plan,
/// which kept an unlit hem with a `›` chevron as the only affordance for reopening.
enum AutomationBezel {

    // MARK: - Shape (values settled on the mock-up build/mockups/switch-bezel.html)

    static let plateauCap:   Double = 250      // a ceiling on the plateau's width
    static let plateauShare: Double = 0.60     // ... otherwise 60 % of the object
    /// The hem's height: half of what the mock-up offered (40 / blockHeight × 0.5) — on screen, a
    /// hem that tall ate the block. Both ceilings are halved TOGETHER, otherwise the relative one
    /// would take over again on a squashed block.
    static let heightCap:    Double = 20
    static let heightShare:  Double = 0.25     // ... bounded at blockHeight × 0.25 (an adjustable height)
    /// The shoulder radius, set on the height: the mock-up settled on 45 for a height of 40, so
    /// ~1.12 × the height. Keeping it at 45 on a hem half as tall would flatten the S shapes into
    /// two long soft ramps.
    static let shoulderCap:  Double = 22
    static let position:     Double = 0.62     // the plateau's centre, slightly to the right
    static let tension:      Double = 0.55     // the tension of the shoulders' béziers
    static let lineWidth:    Double = 2

    static let minFull:   Double = 170         // OBJECTS / AUTOMATIONS
    static let minShort:  Double = 112         // OBJECTS / AUTO
    static let minIcons:  Double = 62          // ▤ / ∿ — below that, no hem

    enum Labels { case full, short, icons }

    /// The resolved geometry, in coordinates LOCAL to the block's visible span.
    struct Metrics {
        let plateau:  Double      // the plateau's width (the flat part, the only clickable one)
        let shoulder: Double      // the shoulders' radius
        let height:   Double      // the hem's height
        let minX:     Double      // the plateau's left edge
        let labels:   Labels
        var maxX: Double { minX + plateau }
        /// The width of the chevron's zone, to the right of the plateau.
        var chevron: Double { min(26, plateau * 0.22) }
    }

    /// nil when the object is too narrow to carry a readable hem.
    /// - Parameters:
    ///   - width: the block's VISIBLE width (@see visibleSpan) — not its real width.
    ///   - handleW: `TimelineView.handleWidth(blockWidth:)` on the SAME width.
    ///   - corner: `SoundObject.blockCornerRadius` (20 for a group / aux, 4 for a clip).
    static func metrics(width: Double, blockHeight: Double,
                        handleW: Double, corner: Double) -> Metrics? {
        // Three ceilings: the fixed one, the object's share, and what the trim / resize handles
        // leave free (they take up to 25 % of each side, in the lower half — exactly where the
        // hem sits).
        let pw = min(plateauCap, width * plateauShare, width - 2 * handleW - 8)
        guard pw >= minIcons else { return nil }
        let h  = min(heightCap, blockHeight * heightShare)
        let r  = max(4, min(shoulderCap, (width - pw) / 2 - corner))
        // TWO bounds add up on the centre. The handle columns, first: the plateau must not cover
        // them. The block's radius, next: it is the FEET of the shoulders (at ±r from the plateau)
        // that count, not the plateau — bounded on the plateau alone, they fell into the rounded
        // corners and the hem stuck out of the block's outline. It is the mock-up's bound
        // (`cx = max(pw/2+r+CORNER, …)`), which the port had replaced with a fixed 8 px margin.
        //
        let lo = max(handleW + 4 + pw / 2, pw / 2 + r + corner)
        let hi = min(width - handleW - 4 - pw / 2, width - pw / 2 - r - corner)
        let cx = min(max(lo, width * position), max(lo, hi))
        return Metrics(plateau: pw, shoulder: r, height: h, minX: cx - pw / 2,
                       labels: pw >= minFull ? .full : (pw >= minShort ? .short : .icons))
    }

    /// The hem's OUTLINE, in a rect whose `maxY` is the BOTTOM of the block: it comes in along the
    /// lower edge, rises through an S, runs along the plateau, comes back down through the other S
    /// and leaves for the opposite edge. Deliberately OPEN — it is the path to STROKE: the block's
    /// edge is replaced by the hem there, it does not run underneath.
    static func outline(in rect: CGRect, _ m: Metrics) -> Path {
        let x0 = rect.minX + m.minX, x1 = rect.minX + m.maxX
        let r  = m.shoulder, k = tension
        let y0 = rect.maxY, y1 = rect.maxY - m.height
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: y0))
        p.addLine(to: CGPoint(x: x0 - r, y: y0))
        p.addCurve(to: CGPoint(x: x0, y: y1),
                   control1: CGPoint(x: x0 - r + r * k, y: y0),
                   control2: CGPoint(x: x0 - r * k,     y: y1))
        p.addLine(to: CGPoint(x: x1, y: y1))
        p.addCurve(to: CGPoint(x: x1 + r, y: y0),
                   control1: CGPoint(x: x1 + r * k,     y: y1),
                   control2: CGPoint(x: x1 + r - r * k, y: y0))
        p.addLine(to: CGPoint(x: rect.maxX, y: y0))
        return p
    }

    /// The hem's SURFACE: the outline closed by the block's lower edge. To be FILLED only.
    /// Stroking it would restore, under the plateau and its shoulders, the very edge line the hem
    /// is there to interrupt — that is the closing segment, which runs from one edge of the span
    /// to the other.
    static func path(in rect: CGRect, _ m: Metrics) -> Path {
        var p = outline(in: rect, m)
        p.closeSubpath()
        return p
    }

    /// Where an object's hem sits, in CONTENT coordinates. A single object for the geometry's four
    /// clients (rendering, the click's hit-testing, the drag's guard, the cursor): two separate
    /// values would drift, and the button would end up not answering where it is drawn.
    ///
    struct Placement {
        /// The plateau: the flat part, and the ONLY clickable one.
        let plateau: CGRect
        /// The block's VISIBLE part (@see visibleSpan): the frame the hem is drawn in, and the origin
        /// of `Metrics`' local coordinates.
        let span:    CGRect
        /// The WHOLE block — used to clip the hem on its radius. Distinct from `span`: on an object
        /// wider than the viewport, the block's corners are off screen.
        let block:   CGRect
        /// The `SoundObject.blockCornerRadius` of the block to clip.
        let corner:  Double
        let metrics: Metrics
    }

    /// What the click aimed at inside the plateau.
    enum Hit { case objects, automations, collapse }

    /// Resolves a point (in CONTENT coordinates) inside the plateau — nil outside it.
    /// The shoulders do NOT answer: they are decorative, and let the trim / resize handles work
    /// underneath.
    static func hit(_ p: CGPoint, plateau r: CGRect, _ m: Metrics) -> Hit? {
        guard r.contains(p) else { return nil }
        if p.x >= r.maxX - m.chevron { return .collapse }
        let switchW = r.width - m.chevron
        return p.x < r.minX + switchW / 2 ? .objects : .automations
    }

    // MARK: - Display state (@see the design §5: three states, not two)

    /// What the hem shows when lit, derived from the object's state ALONE — never stored: the
    /// automation band wins over unfolded content (the same rule as `SoundObject.expandedSpan`,
    /// which tests `automationOpen` before `isExpanded`/`pianoRollOpen`).
    ///
    /// `.collapsed` is no longer DRAWN: a folded object has no hem at all
    /// (@see TimelineView.automationBezel, which returns nil). The case is still named because the
    /// click on the chevron does have to recognise an already folded object.
    enum DisplayState { case objects, automations, collapsed }

    static func displayState(for item: SoundObject) -> DisplayState {
        if item.automationOpen { return .automations }
        if item.expandedSpan > 0 { return .objects }
        return .collapsed
    }
}

/// The block's outline, expressed in the hem view's LOCAL coordinates. It serves as a CLIP:
/// the foot of a shoulder, and the base line running along the lower edge, readily fall into a
/// rounded corner (20 px on a group) — without that clip, a bit of hem sticks out of the
/// block's outline, just above the gutter.
private struct BlockContour: Shape {
    let rect:   CGRect
    let radius: Double
    /// The rect the layout offers is ignored: the block is wider (or offset) with respect to the
    /// visible span the hem is drawn in.
    func path(in _: CGRect) -> Path { Path(roundedRect: rect, cornerRadius: radius) }
}

/// Pure rendering (`allowsHitTesting(false)`) of the hem: the click is resolved geometrically by
/// `TimelineView.automationBezelHit`, like all the rest of the canvas.
///
/// It receives the geometry already resolved by `TimelineView.automationBezel(for:)`. The drawing
/// frame is the block's VISIBLE SPAN (bounded by the viewport, so never outsized); the hem's
/// base line crosses it from end to end, as in the mock-up where the path ran across the block's
/// whole width, clipped by its `overflow:hidden`. Here that same clip is explicit
/// (`BlockContour`).
struct AutomationBezelView: View {
    /// The complete placement (plateau / span / block / radius / metrics), in CONTENT coordinates.
    let placement: AutomationBezel.Placement
    /// The paint layers of the object's INSIDE, in drawing order, the OPAQUE base at the head
    /// (@see TimelineView.interiorPaint). The hem is a piece of what opens underneath: it takes
    /// that exact stack, not an approximate colour.
    let fill:  [Color]
    let tint:  Color
    let state: AutomationBezel.DisplayState

    private var metrics: AutomationBezel.Metrics { placement.metrics }

    /// The LOCAL frame (origin 0,0): the block's visible span, the origin of `Metrics`' coordinates.
    private var localRect: CGRect {
        CGRect(origin: .zero, size: placement.span.size)
    }

    /// The block, in that same local frame. Offset to the left (a negative value) and wider than
    /// `localRect` as soon as the object overflows the viewport — that is normal, it only serves the clip.
    private var blockLocal: CGRect {
        CGRect(x: placement.block.minX - placement.span.minX,
               y: placement.block.minY - placement.span.minY,
               width: placement.block.width, height: placement.block.height)
    }

    /// The plateau in LOCAL coordinates — that is where the `HStack` of the three zones sits.
    private var plateauLocal: CGRect {
        CGRect(x: metrics.minX, y: localRect.height - metrics.height,
              width: metrics.plateau, height: metrics.height)
    }

    private var switchWidth: Double { metrics.plateau - metrics.chevron }

    var body: some View {
        let shape = AutomationBezel.path(in: localRect, metrics)
        ZStack(alignment: .topLeading) {
            // A stack, and not a colour composed by hand: the layers are the very ones the canvas lays
            // on the inner lanes, in the same order.
            ForEach(Array(fill.enumerated()), id: \.offset) { _, layer in
                shape.fill(layer)
            }
            // The OUTLINE, not the surface: under the hem, the block's edge fades — the material of
            // the inside passes through, it does not stop at a line (@see AutomationBezel.path).
            AutomationBezel.outline(in: localRect, metrics)
                .stroke(tint.opacity(0.75), lineWidth: AutomationBezel.lineWidth)
            zones
                .frame(width: plateauLocal.width, height: plateauLocal.height)
                .offset(x: plateauLocal.minX, y: plateauLocal.minY)
        }
        .frame(width: localRect.width, height: localRect.height, alignment: .topLeading)
        .clipShape(BlockContour(rect: blockLocal, radius: placement.corner))
        .offset(x: placement.span.minX, y: placement.span.minY)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var zones: some View {
        HStack(spacing: 0) {
            half(objectsText, active: state == .objects)
                .frame(width: switchWidth / 2, height: metrics.height)
            half(automationsText, active: state == .automations)
                .frame(width: switchWidth / 2, height: metrics.height)
            Rectangle()
                .fill(Color.black.opacity(0.14))
                .frame(width: 1, height: metrics.height * 0.6)
            Text(verbatim: state == .collapsed ? "›" : "⌄")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.black.opacity(0.55))
                .frame(width: metrics.chevron - 1, height: metrics.height)
        }
    }

    @ViewBuilder
    private func half(_ text: String, active: Bool) -> some View {
        ZStack {
            if active {
                Capsule().fill(tint).padding(2)
            }
            Text(text)
                .font(.system(size: metrics.labels == .icons ? 13 : 9,
                             weight: active ? .semibold : .regular))
                .foregroundColor(active ? .white.opacity(0.65) : .white.opacity(0.35))
                .lineLimit(1)
        }
    }

    private var objectsText: String {
        switch metrics.labels {
        case .full, .short: return "OBJETS"
        case .icons:         return "▤"
        }
    }

    private var automationsText: String {
        switch metrics.labels {
        case .full:  return "AUTOMATIONS"
        case .short: return "AUTO"
        case .icons: return "∿"
        }
    }
}

import SwiftUI

/// The zones round a '+' (@see SynopticPlusGesture.sectors): each a faint wedge with its icon, the one under
/// the hand lit up softly. Drawn round a '+' of the signal view while a drag leaves it, and — the same
/// drawing — on the plugin browser's "+" page (@see PluginBrowserPlusPage), where the user lays out what each
/// zone does. A zone bound to a plugin no longer installed is grey and dashed, with the "no" sign; a zone
/// bound to a colour category shows that colour. Pure display, deaf to the mouse.
struct PlusSectorsView: View {
    let center: CGPoint
    let sectors: [PlusSector]
    /// The index of the zone the hand is in (nil = none).
    let highlighted: Int?
    /// Draws the zone's icon (false on the "+" page, which lays its own labels over the zones).
    var showsIcons = true
    /// How strongly the zones are drawn (1 = the signal view's faint veil).
    var emphasis: Double = 1
    /// The drawing's size (1 = the signal view's, where a zone is the gesture's own geometry).
    var scale: CGFloat = 1
    /// An opaque ground laid under each wedge, so the zones read over the cards they cover (0 = none, the
    /// "+" page having its own plain ground).
    var backdrop: Double = 0.85

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(sectors.indices, id: \.self) { i in
                let s = sectors[i]
                let on = i == highlighted
                let tint = Self.tint(of: s)
                let shape = Self.path(of: s, center: center, scale: scale)
                if backdrop > 0 { shape.fill(Color(nsColor: .windowBackgroundColor).opacity(backdrop)) }
                shape.fill(tint.opacity((on ? 0.14 : 0.04) * emphasis))
                shape.stroke(tint.opacity(min(1, (on ? 0.45 : 0.15) * emphasis)),
                             style: StrokeStyle(lineWidth: 1, lineJoin: .round, dash: s.isAvailable ? [] : [3, 3]))
                if showsIcons {
                    Image(systemName: s.isAvailable ? SynopticPlusPresentation.symbol(for: s.result) : "nosign")
                        .font(.system(size: 10, weight: on ? .semibold : .regular))
                        .foregroundStyle(Self.iconColor(of: s) ?? (on ? tint : Color.secondary.opacity(0.7)))
                        .position(x: center.x + s.iconOffset.width * scale, y: center.y + s.iconOffset.height * scale)
                }
            }
        }
        .animation(.easeOut(duration: 0.12), value: highlighted)
    }

    /// The wedge of `s` round `center`, drawn `scale` times its size.
    static func path(of s: PlusSector, center: CGPoint, scale: CGFloat = 1) -> Path {
        Path { p in
            let pts = s.outline().map { CGPoint(x: center.x + $0.width * scale, y: center.y + $0.height * scale) }
            guard let first = pts.first else { return }
            p.move(to: first)
            for q in pts.dropFirst() { p.addLine(to: q) }
            p.closeSubpath()
        }
    }

    static func tint(of s: PlusSector) -> Color {
        s.isAvailable ? Color.accentColor : Color.secondary
    }

    /// A category zone's icon takes the category's colour.
    static func iconColor(of s: PlusSector) -> Color? {
        if s.isAvailable, case .category(let i) = s.result { return ObjekatPalette.pluginCategory(i) }
        return nil
    }
}

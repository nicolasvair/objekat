import SwiftUI

/// A VU bar: a thin capsule on a pale track, lit from the left up to `level`, each ZONE of the lit part
/// in its own colour (green, then yellow past -18 dBFS, orange past -6, red past 0 — @see `VUScale`):
/// only the portion over a threshold changes colour, never the whole bar.
///
/// Pure presentation: `level` is a 0...1 position on `VUScale` (already smoothed by the caller, @see
/// `VUBallistics`). The plugin cards' line (`SynopticCardVULine`) and the Inputs tab's rows both draw it.
struct VULevelBar: View {
    /// The bar's 0...1 position (`VUScale.fraction(dB)`).
    let level: Double
    var height: CGFloat = 2

    var body: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.2))
            .frame(height: height)
            .overlay(alignment: .leading) {
                GeometryReader { g in
                    let w = g.size.width
                    let lit = max(0, min(1, level))
                    ZStack(alignment: .leading) {
                        ForEach(VUScale.zones.indices, id: \.self) { i in
                            let z = VUScale.zones[i]
                            let from = z.from, to = min(z.to, lit)
                            if to > from {
                                Rectangle().fill(z.color)
                                    .frame(width: (to - from) * w)
                                    .offset(x: from * w)
                            }
                        }
                    }
                    .frame(width: w, alignment: .leading)
                    .clipShape(Capsule())
                }
            }
    }
}

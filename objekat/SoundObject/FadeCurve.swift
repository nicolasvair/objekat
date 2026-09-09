import Foundation

/// The SHAPE of a fade, next to its length. Five closed forms, and closed forms ONLY: a curve is
/// a function evaluated per sample, never a string of automation points approximating one. The
/// difference is not tidiness — a fade drawn with points would cost memory proportional to its
/// length, would quantise the very thing the ear hears best (the start of a fade in), and would
/// have to be redrawn at every trim.
///
/// The three plain shapes are Tracktion's own (`AudioFadeCurve`, sine-based rather than
/// logarithmic: a log runs to −∞ at zero and has to be clamped somewhere arbitrary, whereas the
/// quarter-sine reaches exactly 0 and 1 at its ends and has the same audible "hollow / bulge"). The
/// two S shapes are a blend of the other two, and `sCurveInverse` — the same blend with its weights
/// swapped — is ours: Tracktion carries only one of the pair.
///
/// The convention, for both edges: `alpha` is the fade's PROGRESS, 0 = silence, 1 = full level. A
/// fade OUT therefore reads it backwards (`(end - t) / fadeOut`), so one single family of formulas
/// serves both edges and a shape means the same thing on either — "bulged" is the curve that
/// stands ABOVE the diagonal, whichever way round it is drawn.
enum FadeCurve: String, Codable, CaseIterable, Sendable {
    /// The straight line. The default, and what every project made before 9 September 2026 has.
    case linear
    /// "Bulged" — above the diagonal: the level rises at once, then flattens.
    case convex
    /// "Hollowed" — below the diagonal: the level hangs back, then climbs.
    case concave
    /// An S that starts hollowed and ends bulged: flat, steep, flat.
    case sCurve
    /// The other S — bulged first, then hollowed: steep, flat, steep.
    case sCurveInverse

    /// The gain (0…1) at a progress `alpha` (0…1) along the fade.
    func gain(_ alpha: Double) -> Double {
        let a = min(1, max(0, alpha))
        let q = a * .pi / 2
        switch self {
        case .linear:        return a
        case .convex:        return sin(q)
        case .concave:       return 1 - cos(q)
        // The two S shapes are the SAME blend of the other two with the weights swapped, which is
        // what makes them a pair rather than two unrelated formulas: weight the hollow by `a` and
        // it opens the curve, weight it by `1 - a` and it closes it.
        case .sCurve:        return (1 - a) * (1 - cos(q)) + a * sin(q)
        case .sCurveInverse: return a * (1 - cos(q)) + (1 - a) * sin(q)
        }
    }

    /// The engine's integer code, mirrored in `ObjWindowFadePlugin` (which cannot see this enum).
    /// Fixed for good: it is written into the plugin state, hence into saved projects.
    var engineCode: Int32 {
        switch self {
        case .linear:        return 0
        case .convex:        return 1
        case .concave:       return 2
        case .sCurve:        return 3
        case .sCurveInverse: return 4
        }
    }

    /// An unknown name reads as `linear`: a project written by a later version must open rather
    /// than fail, and a straight fade is the honest fallback for a shape we cannot draw.
    init(engineCode: Int32) {
        self = Self.allCases.first { $0.engineCode == engineCode } ?? .linear
    }
}

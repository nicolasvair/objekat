import Foundation

/// The FAMILY a fade's shape belongs to: which way it leaves the straight line. It says the
/// direction, never how far — that is `FadeCurve.amount`, and the two together are what one
/// gesture lays down.
///
/// Closed forms, and closed forms ONLY: a curve is a function evaluated per sample, never a string
/// of automation points approximating one. The difference is not tidiness — a fade drawn with
/// points would cost memory proportional to its length, would quantise the very thing the ear
/// hears best (the start of a fade in), and would have to be redrawn at every trim.
///
/// The convention, for both edges: `alpha` is the fade's PROGRESS, 0 = silence, 1 = full level. A
/// fade OUT therefore reads it backwards (`(end - t) / fadeOut`), so one single family of formulas
/// serves both edges and a shape means the same thing on either — "bulged" is the curve that
/// stands ABOVE the diagonal, whichever way round it is drawn.
enum FadeShape: String, Codable, CaseIterable, Sendable {
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

    /// True of the two families that start by HANGING BACK. They take the exponent as it is; the
    /// other two take its inverse, which is what makes the pairs exact reflections of each other.
    var isHollow: Bool { self == .concave || self == .sCurve }

    /// The gain (0…1) at a progress `alpha`, for a bend expressed as an EXPONENT `p` ≥ 1
    /// (1 = the straight line, and the bigger the more curved). @see `FadeCurve.exponent`.
    ///
    /// A power rather than the quarter-sine this started with: `a^p` is a whole FAMILY where the
    /// sine was a single shape, so the bend has somewhere to go — the sine's own bend now sits at
    /// about a third of the travel, and the rest of the travel goes on curving. It keeps what made
    /// the sine the right choice over a logarithm: it reaches exactly 0 and 1 at its ends, with no
    /// clamp pulled out of nowhere at the silent end. And `a^p` / `a^(1/p)` are exact reflections
    /// of one another through the diagonal, which the sine pair was not: bulged and hollowed are
    /// now the same amount of bend, seen from either side.
    ///
    /// The two S's are the standard gain function — the same power applied to each half, the
    /// second one turned over. Continuous and C¹ at the middle (both halves have slope `p` there),
    /// which is what keeps an S from showing a corner at half-way.
    func gain(_ alpha: Double, exponent p: Double) -> Double {
        let a = min(1, max(0, alpha))
        guard self != .linear, p > 1 else { return a }
        let e = isHollow ? p : 1 / p
        switch self {
        case .convex, .concave:
            return pow(a, e)
        default:
            return a < 0.5 ? 0.5 * pow(2 * a, e)
                           : 1 - 0.5 * pow(2 - 2 * a, e)
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

/// The SHAPE of a fade: a family, and HOW FAR it has left the straight line. A shape is not a
/// choice among five, it is a continuum — the gesture that lays it down is a vertical travel, and
/// a travel that snapped to a single value the moment it crossed a threshold would throw away
/// everything the hand was saying past that first pixel.
///
/// `amount` is what the HAND says, 0…1 of the travel; the curve is driven by the EXPONENT it maps
/// to, `maxExponent ^ amount`. Geometric rather than proportional, because that is what the eye
/// and the ear read as an even progression: doubling the exponent is one same step of curvature
/// whether one starts at 1 or at 4, whereas an exponent growing by equal slices would run through
/// everything visible in its first quarter and then barely move.
struct FadeCurve: Codable, Equatable, Sendable {
    var shape: FadeShape
    /// How far from the straight line, 0…1. Kept clamped by every way in, so that no caller — the
    /// command API included — can hand the engine a gain that leaves [0, 1].
    private(set) var amount: Double

    init(shape: FadeShape, amount: Double = 1) {
        self.shape  = shape
        self.amount = min(1, max(0, amount))
    }

    /// The bend at the end of the travel. Deliberately far — at 8 a bulged fade is at −0.7 dB
    /// half-way through and a hollowed one at −48 dB, which is an extreme one asks for on purpose
    /// and reaches only by leaving the row for good. Everything gentler lives below it, and the
    /// quarter-sine this feature started with sits at about a third of the way up.
    static let maxExponent: Double = 8

    /// The straight fade. What every object has until one bends it.
    static let linear = FadeCurve(shape: .linear, amount: 0)

    /// True when nothing bends: a linear family, or a bend of zero. The two are the same curve, and
    /// the storage and the display both key off this rather than off the family alone.
    var isStraight: Bool { shape == .linear || amount <= 0 }

    /// The bend as the exponent the formulas take: 1 (straight) … `maxExponent`.
    var exponent: Double { pow(Self.maxExponent, min(1, max(0, amount))) }

    /// The gain (0…1) at a progress `alpha` (0…1) along the fade.
    func gain(_ alpha: Double) -> Double {
        guard !isStraight else { return min(1, max(0, alpha)) }
        return shape.gain(alpha, exponent: exponent)
    }

    /// The same curve bent by `amount`, family kept.
    func withAmount(_ a: Double) -> FadeCurve { FadeCurve(shape: shape, amount: a) }

    // MARK: Codable
    //
    // Two forms are read, one is written. A bare string is the shape as the very first version of
    // this feature wrote it, before the bend was continuous: it means the family at FULL bend.

    enum CodingKeys: String, CodingKey { case shape, amount }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let name = try? single.decode(String.self) {
            self.init(shape: FadeShape(rawValue: name) ?? .linear, amount: 1)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(shape: try c.decodeIfPresent(FadeShape.self, forKey: .shape) ?? .linear,
                  amount: try c.decodeIfPresent(Double.self, forKey: .amount) ?? 1)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(shape, forKey: .shape)
        try c.encode(amount, forKey: .amount)
    }
}

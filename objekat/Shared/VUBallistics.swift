import Foundation

/// The meters' ballistics, shared by the stem strips and the synoptic's plugin cards: an almost instant
/// attack (the engine already returns the MAX since the last read — `getAndClear`) and a slow release,
/// smoothed in the normalised domain (∝ dBFS) = a linear fall in dB. The VU/PPM convention.
enum VUBallistics {
    /// The release coefficient applied on every `referenceInterval` tick: ~0.1 → a time constant of
    /// ≈ 0.7 s, a 'slow' fall of the order of a second.
    static let releaseAlpha: Float = 0.1

    /// The tick the coefficient above was tuned on (the stem strips' 0.07 s poll).
    static let referenceInterval: Double = 0.07

    /// The coefficient for a tick of `interval` seconds, so a faster poll keeps the SAME fall in time:
    /// 1 - (1 - α)^(dt / dt_ref). For the reference interval it is exactly `releaseAlpha`.
    static func releaseAlpha(interval: Double) -> Float {
        guard interval > 0 else { return releaseAlpha }
        return Float(1.0 - pow(Double(1.0 - releaseAlpha), interval / referenceInterval))
    }

    /// One tick: a rise is taken as it comes, a fall is eased by `alpha`.
    static func smoothed(previous: Float, raw: Float, alpha: Float = releaseAlpha) -> Float {
        raw >= previous ? raw : previous + (raw - previous) * alpha
    }
}

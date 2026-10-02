import Foundation

/// How the two curves of a crossfade's X are SAMPLED for drawing, and the cache they are kept in.
///
/// Why it is a unit: the X is redrawn on every frame of a crossfade drag, for every zone on screen,
/// and each curve used to be rebuilt from scratch — up to 512 `FadeCurve.gain` calls, each of them
/// two `pow`s (the exponent, then the power itself) — only to be thrown away the next frame, when
/// nothing but the zone's POSITION and WIDTH had moved. The shape of a curve depends on the curve
/// alone, so it is worked out once in the UNIT square and stretched onto the zone by one affine
/// transform per frame. What is here is the half with nothing behind it (no SwiftUI, no model), so
/// it can be compiled alone and asserted: `tools/test_crossfade_curve_cache.swift`.
///
/// The budget is `min(width in px, 128)` samples per curve, 16 at the very least (it was `min(width, 512)`), made good by
/// WHERE the samples go: a power curve is steep only at its ends (the bulged family at the silent
/// end, the hollowed one at the full-level end, the S's in the middle by a mild slope), so the
/// progress is laid out on a cosine grid — dense where the curve turns fastest, sparse where it is
/// nearly straight. The test pins the result against a dense reference: under half a pixel at the
/// largest block height there is, for every family, three bends and zones from 4 to 900 px wide.
enum CrossfadeCurveSampling {

    /// The most samples a curve is drawn with.
    static let maxSamples = 128

    /// The fewest segments a curve gets, however narrow the zone: a zone 4 px wide and a block 900 px
    /// tall draws a near-vertical stroke that four chords cannot hold within half a pixel, and a
    /// handful more points on a tiny zone costs nothing.
    static let minSamples = 16

    /// Segments for a zone `width` px wide: one per pixel, between `minSamples` and `maxSamples`.
    static func sampleCount(forWidth width: Double) -> Int {
        guard width.isFinite else { return minSamples }
        return max(minSamples, min(Int(width.rounded()), maxSamples))
    }

    /// The fade's PROGRESS (0 = silence, 1 = full level) of sample `i` of `n` segments, on a cosine
    /// grid: it starts and ends in tiny steps and crosses the middle in the widest ones.
    static func progress(index i: Int, of n: Int) -> Double {
        if i <= 0 { return 0 }
        if i >= n { return 1 }
        return 0.5 * (1 - cos(Double.pi * Double(i) / Double(n)))
    }

    /// The curve in the UNIT square, from its first point to its last: x = 0…1 across the zone,
    /// y = 0…1 from the top (y = 1 − gain). The INCOMING curve climbs left to right; the OUTGOING
    /// one is the same family read right to left (`alpha` is progress for both edges, @see
    /// FadeCurve), so it comes down. A straight curve is two points whatever the budget.
    static func unitPoints(curve: FadeCurve, incoming: Bool, segments: Int) -> [(x: Double, y: Double)] {
        let n = curve.isStraight ? 1 : max(2, segments)
        var pts: [(x: Double, y: Double)] = []
        pts.reserveCapacity(n + 1)
        for i in 0...n {
            let a = curve.isStraight ? Double(i) : progress(index: i, of: n)
            pts.append((x: incoming ? a : 1 - a, y: 1 - curve.gain(a)))
        }
        return pts
    }

    /// What a cache entry is keyed by: the curve (family and bend, to the bit), the side, the count.
    struct Key: Hashable {
        let shape: FadeShape
        let amountBits: UInt64
        let incoming: Bool
        let segments: Int
        init(curve: FadeCurve, incoming: Bool, segments: Int) {
            self.shape = curve.shape
            self.amountBits = curve.amount.bitPattern
            self.incoming = incoming
            self.segments = curve.isStraight ? 1 : segments
        }
    }
}

/// A small bounded cache, safe from any thread (a `Canvas` may be rendered off the main one). When
/// it is full it is emptied outright: the entries are cheap to make and a drag asks for a handful.
final class CrossfadeCurveCache<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [CrossfadeCurveSampling.Key: Value] = [:]
    private let capacity: Int
    /// How many times `make` ran — what a test counts to prove the cache is doing its job.
    private(set) var misses = 0

    init(capacity: Int = 256) { self.capacity = capacity }

    func value(for key: CrossfadeCurveSampling.Key, make: () -> Value) -> Value {
        lock.lock()
        if let hit = entries[key] { lock.unlock(); return hit }
        lock.unlock()
        let made = make()
        lock.lock()
        if entries.count >= capacity { entries.removeAll(keepingCapacity: true) }
        entries[key] = made
        misses += 1
        lock.unlock()
        return made
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }
}

import Foundation

// The arithmetic of a loudness measurement (ITU-R BS.1770-4 / EBU R128, Tech 3341 and 3342) — the
// half that has no signal in it.
//
// The engine's tap (OBJExportTap, built on `Shared/OBJLoudness.h`) turns the rendered audio into
// SUB-BLOCKS of 100 ms, each carrying the weighted mean square of the K-weighted signal (its
// `energy`) and the largest true peak it saw. Everything a meter shows is a reading of that series:
//
//   • Momentary  — a 400 ms window: the mean of 4 sub-blocks, one value per sub-block (75 % overlap);
//   • Short-term — a 3 s window: the mean of 30 sub-blocks, one value per sub-block;
//   • Integrated — the momentary blocks gated at −70 LUFS (absolute), then at −10 LU under the
//                  power mean of what survived (relative), the mean of the rest;
//   • Range      — the short-term values gated at −70 LUFS and −20 LU (relative), then the spread
//                  between their 10th and 95th percentiles (Tech 3342);
//   • True peak  — the largest of the tap's peaks, in dBTP.
//
// The series arrives INCREMENTALLY (the poll reads what the render has produced since last time),
// and the running values are needed at every step — the panel draws the momentary, short-term and
// integrated CURVES while the render goes on — so the gated readings cannot re-scan the history
// each time: an hour of audio is 36 000 sub-blocks, drawn at 10 Hz. They live in HISTOGRAMS of 0.1 LU
// bins (the way libebur128, which passes the EBU's own test suite, does it): O(bins) to read,
// whatever the length. What the bins hold makes them nearly exact rather than merely quantised:
// each keeps the SUM of the energies that fell in it (so the mean over the kept bins is exact) and
// the mean loudness of what fell in it (so a plateau of equal values is reported as that value, not
// as the middle of its bin). What is quantised is only the GATE: a block within 0.1 LU of a
// threshold counts as a whole bin does — the resolution the standard's own tolerance (±0.1 LU)
// leaves room for.
//
// Nothing here knows about the engine, the view model or SwiftUI, which is why it can be compiled
// and asserted alone: `tools/test_loudness.swift`.

struct LoudnessAnalysis {

    // MARK: - Constants of the standard

    /// The tap's sub-block, in seconds. @see OBJLOUD_SUBBLOCK_SECONDS in Shared/OBJLoudness.h.
    static let subblockSeconds = 0.1
    /// A 400 ms momentary block, in sub-blocks.
    static let momentaryBlocks = 4
    /// A 3 s short-term window, in sub-blocks.
    static let shortTermBlocks = 30
    static let absoluteGate = -70.0
    /// Integrated loudness: the relative gate sits this far under the power mean (LU).
    static let integratedRelativeGate = -10.0
    /// Loudness range: the relative gate sits this far under the power mean (LU).
    static let rangeRelativeGate = -20.0
    static let rangeLowPercentile = 0.10
    static let rangeHighPercentile = 0.95
    /// BS.1770 equation 2: L = −0.691 + 10·log10(z). It is what makes a 997 Hz sine read the same
    /// loudness as its level in dBFS once both channels are summed.
    static let lufsOffset = -0.691

    /// Loudness of a weighted mean square. −infinity for silence.
    static func lufs(_ energy: Double) -> Double {
        energy > 0 ? lufsOffset + 10 * log10(energy) : -.infinity
    }

    // MARK: - The series

    /// Weighted mean square of each 100 ms sub-block, from the start of the render.
    private(set) var energies: [Double] = []
    /// Largest true peak of each sub-block, linear.
    private(set) var truePeaks: [Float] = []
    /// Momentary loudness (LUFS, −∞ for silence). Element m is the window that ENDS with sub-block
    /// m + 3, i.e. at (m + 4) × 0.1 s — the first one exists once 400 ms have been rendered.
    private(set) var momentary: [Double] = []
    /// Short-term loudness. Element s ends with sub-block s + 29, at (s + 30) × 0.1 s.
    private(set) var shortTerm: [Double] = []
    /// The integrated loudness as it stood at each momentary value (same indexing as `momentary`):
    /// what the meter would have read had the render stopped there.
    private(set) var integratedCurve: [Double] = []
    private(set) var momentaryMax = -Double.infinity
    private(set) var shortTermMax = -Double.infinity
    /// Largest true peak so far, linear.
    private(set) var truePeakMax: Float = 0

    private var integratedGate = GatedHistogram()
    private var rangeGate = GatedHistogram()

    init() {}

    /// How many sub-blocks have been taken in. Also the index the next one will get.
    var blockCount: Int { energies.count }

    /// The time covered, in seconds (whole sub-blocks only).
    var duration: Double { Double(blockCount) * Self.subblockSeconds }

    mutating func removeAll() { self = LoudnessAnalysis() }

    // MARK: - Feeding

    mutating func append(energy: Double, truePeak: Float) {
        // A NaN would poison every window it falls in, for ever. Treated as silence.
        let e = energy.isFinite && energy > 0 ? energy : 0
        energies.append(e)
        truePeaks.append(truePeak.isFinite ? max(0, truePeak) : 0)
        if truePeak.isFinite, truePeak > truePeakMax { truePeakMax = truePeak }

        let k = energies.count - 1

        if k >= Self.momentaryBlocks - 1 {
            let z = mean(endingAt: k, count: Self.momentaryBlocks)
            let l = Self.lufs(z)
            momentary.append(l)
            if l > momentaryMax { momentaryMax = l }
            integratedGate.add(energy: z)
            integratedCurve.append(integratedGate.gatedLoudness(relativeGate: Self.integratedRelativeGate))
        }
        if k >= Self.shortTermBlocks - 1 {
            let z = mean(endingAt: k, count: Self.shortTermBlocks)
            let l = Self.lufs(z)
            shortTerm.append(l)
            if l > shortTermMax { shortTermMax = l }
            rangeGate.add(energy: z)
        }
    }

    /// The mean of the `count` sub-blocks ending at `k`, summed directly: a running window would
    /// drift, and its difference of two large sums would answer a tiny number for a silence that
    /// follows a loud passage.
    private func mean(endingAt k: Int, count: Int) -> Double {
        var sum = 0.0
        for j in (k - count + 1)...k { sum += energies[j] }
        return sum / Double(count)
    }

    // MARK: - Readings

    /// The latest momentary loudness. nil until 400 ms have been rendered; −∞ for silence.
    var latestMomentary: Double? { momentary.last }
    var latestShortTerm: Double? { shortTerm.last }

    /// Gated integrated loudness, LUFS. −∞ when nothing passes the absolute gate (silence, or
    /// less than 400 ms of material).
    var integrated: Double {
        integratedGate.gatedLoudness(relativeGate: Self.integratedRelativeGate)
    }

    /// Loudness range, LU. nil when no short-term value survives the gates (fewer than 3 s
    /// rendered, or silence).
    var loudnessRange: Double? {
        rangeGate.percentileSpread(relativeGate: Self.rangeRelativeGate,
                                   low: Self.rangeLowPercentile, high: Self.rangeHighPercentile)
    }

    /// True peak in dBTP. −∞ for a signal that never left silence.
    var truePeakDB: Double {
        truePeakMax > 0 ? 20 * log10(Double(truePeakMax)) : -.infinity
    }

    /// What the three curves read at the end of sub-block `k` (0-based; the instant is
    /// (k + 1) × 0.1 s). Each is nil while its own window has not filled yet.
    func values(atSubblock k: Int) -> (momentary: Double?, shortTerm: Double?, integrated: Double?) {
        guard k >= 0, k < blockCount else { return (nil, nil, nil) }
        let m = k - (Self.momentaryBlocks - 1)
        let s = k - (Self.shortTermBlocks - 1)
        return (m >= 0 && m < momentary.count ? momentary[m] : nil,
                s >= 0 && s < shortTerm.count ? shortTerm[s] : nil,
                m >= 0 && m < integratedCurve.count ? integratedCurve[m] : nil)
    }

    /// The three curves cut down to at most `points` samples, evenly spread over the sub-blocks —
    /// what a script or a small drawing wants instead of ten values a second for an hour.
    /// `times[i]` is the instant (s) at which the window of point i ends; a curve that does not
    /// exist yet at that instant is nil there, and so is a silence (−∞ has no JSON form).
    func curves(points: Int) -> (times: [Double], momentary: [Double?],
                                 shortTerm: [Double?], integrated: [Double?]) {
        let n = blockCount
        guard n > 0, points > 0 else { return ([], [], [], []) }
        let count = min(points, n)
        var times: [Double] = [], m: [Double?] = [], s: [Double?] = [], i: [Double?] = []
        times.reserveCapacity(count); m.reserveCapacity(count)
        s.reserveCapacity(count); i.reserveCapacity(count)
        for p in 0..<count {
            let k = count == 1 ? n - 1 : Int((Double(p) * Double(n - 1) / Double(count - 1)).rounded())
            let v = values(atSubblock: k)
            times.append(Double(k + 1) * Self.subblockSeconds)
            m.append(v.momentary.flatMap { $0.isFinite ? $0 : nil })
            s.append(v.shortTerm.flatMap { $0.isFinite ? $0 : nil })
            i.append(v.integrated.flatMap { $0.isFinite ? $0 : nil })
        }
        return (times, m, s, i)
    }
}

// MARK: - The gating histogram

/// Loudness values in 0.1 LU bins from the absolute gate (−70 LUFS) upwards — the structure that
/// makes both gated readings cost the same after an hour as after a second.
///
/// A value at or under −70 LUFS is never stored: the absolute gate is applied on the way in, and
/// what passes it is all a relative gate can ever look at.
private struct GatedHistogram {
    static let binWidth = 0.1
    /// −70 … +10 LUFS. A louder block (a float render far over full scale) lands in the last bin:
    /// its energy still counts in full, only its place in the ranking saturates.
    static let binCount = 800

    private var counts = [Int](repeating: 0, count: binCount)
    /// Σ of the energies that fell in each bin — so the mean over the bins kept is exact.
    private var energySums = [Double](repeating: 0, count: binCount)
    /// Σ of their loudness — so a bin answers the MEAN of what it holds, not its middle.
    private var loudnessSums = [Double](repeating: 0, count: binCount)
    private var totalCount = 0
    private var totalEnergy = 0.0

    mutating func add(energy: Double) {
        let l = LoudnessAnalysis.lufs(energy)
        guard l > LoudnessAnalysis.absoluteGate else { return }
        let bin = min(Self.binCount - 1, max(0, Int((l - LoudnessAnalysis.absoluteGate) / Self.binWidth)))
        counts[bin] += 1
        energySums[bin] += energy
        loudnessSums[bin] += l
        totalCount += 1
        totalEnergy += energy
    }

    /// The first bin the relative gate keeps: those whose LOWER edge reaches the threshold. The
    /// threshold is `relativeGate` LU under the power mean of everything that passed the absolute
    /// gate. nil when nothing did.
    private func firstBinKept(relativeGate: Double) -> Int? {
        guard totalCount > 0 else { return nil }
        let threshold = LoudnessAnalysis.lufs(totalEnergy / Double(totalCount)) + relativeGate
        let edge = (threshold - LoudnessAnalysis.absoluteGate) / Self.binWidth
        // A hair of tolerance: a threshold that lands exactly on an edge must keep that bin, and
        // the same arithmetic done in another order can be off by an ulp.
        // Clamped to the last bin: a threshold above the range (a float render far over full scale)
        // keeps the saturated bin, which is where the loud blocks were put.
        return min(Self.binCount - 1, max(0, Int((edge - 1e-9).rounded(.up))))
    }

    /// Integrated loudness: the power mean of what both gates keep. −∞ when nothing does.
    func gatedLoudness(relativeGate: Double) -> Double {
        guard let first = firstBinKept(relativeGate: relativeGate) else { return -.infinity }
        var n = 0, e = 0.0
        for b in first..<Self.binCount { n += counts[b]; e += energySums[b] }
        return n > 0 ? LoudnessAnalysis.lufs(e / Double(n)) : -.infinity
    }

    /// The spread between two percentiles of what both gates keep, in LU. nil when nothing does.
    func percentileSpread(relativeGate: Double, low: Double, high: Double) -> Double? {
        guard let first = firstBinKept(relativeGate: relativeGate) else { return nil }
        var kept = 0
        for b in first..<Self.binCount { kept += counts[b] }
        guard kept > 0 else { return nil }
        let lo = value(atRank: Double(kept - 1) * low, from: first)
        let hi = value(atRank: Double(kept - 1) * high, from: first)
        return max(0, hi - lo)
    }

    /// The loudness at the given 0-based rank among the kept values, in ascending order: the mean
    /// of the bin that rank falls in. The nearest rank, not an interpolation — the values are
    /// already grouped, and an interpolation between two bins' means would invent a value.
    private func value(atRank rank: Double, from first: Int) -> Double {
        let target = Int(rank.rounded())
        var seen = 0
        for b in first..<Self.binCount where counts[b] > 0 {
            seen += counts[b]
            if target < seen { return loudnessSums[b] / Double(counts[b]) }
        }
        // Rounding pushed the rank past the last element: it is the last bin's mean.
        for b in stride(from: Self.binCount - 1, through: first, by: -1) where counts[b] > 0 {
            return loudnessSums[b] / Double(counts[b])
        }
        return -.infinity
    }
}

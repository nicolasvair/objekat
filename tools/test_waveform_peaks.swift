// `WaveformPeaks` (`Shared/WaveformPeaks.swift`) has no model behind it, which is why it can be
// compiled and run alone, exactly like `SendColumns` / `SynopticMarquee` / `PianoRollFraming` /
// `CutSelection` before it.
//
//     swiftc -parse-as-library ../objekat/Shared/WaveformPeaks.swift test_waveform_peaks.swift \
//         -o /tmp/wfpeaks && /tmp/wfpeaks
//
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation

var fails: [String] = []
var total = 0

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    total += 1
    if ok { print("ok    " + label) }
    else { fails.append(label); print("FAIL  \(label)  \(detail)") }
}

/// A tiny deterministic LCG — no `SystemRandomNumberGenerator`, so a failure is reproducible
/// from the printed seed alone and the suite behaves the same on every machine.
struct DeterministicRNG {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func nextFloat(in range: ClosedRange<Float>) -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let unit = Float(state >> 40) / Float(1 << 24)  // [0, 1)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}

/// The brute-force reference this suite checks `decimate` against: min/max recomputed by hand
/// over the same folded ranges, with NO shared code with `WaveformPeaks.decimate`.
func referenceDecimate(_ fine: [PeakPair], ratio: Int) -> [PeakPair] {
    guard ratio > 1, !fine.isEmpty else { return fine }
    let count = Int((Double(fine.count) / Double(ratio)).rounded(.up))
    var result: [PeakPair] = []
    result.reserveCapacity(count)
    for i in 0..<count {
        let start = i * ratio
        let end = min(start + ratio, fine.count)
        guard start < end else { continue }
        var lo = fine[start].lo, hi = fine[start].hi
        for j in (start + 1)..<end {
            lo = min(lo, fine[j].lo)
            hi = max(hi, fine[j].hi)
        }
        result.append(PeakPair(lo: lo, hi: hi))
    }
    return result
}

/// Streams `channels` (one array per channel, all the same length) through a
/// `PeakLaneAccumulator` in chunks of `chunk` frames, the way `WaveformCache.decodeChunked`
/// streams a file — the extent of each segment computed by hand here, with no vDSP and no code
/// shared with the accumulator.
func accumulate(_ channels: [[Float]], density: Double, sampleRate: Double,
                laneCount: Int, chunk: Int) -> PeakLanes {
    let total = channels[0].count
    var acc = PeakLaneAccumulator(density: density, duration: Double(total) / sampleRate,
                                  total: total, laneCount: laneCount)
    var s = 0
    while s < total {
        let n = min(chunk, total - s)
        let base = s
        acc.add(startFrame: base, frameCount: n, channelCount: channels.count) { c, from, count in
            var lo = channels[c][base + from], hi = lo
            for k in (base + from)..<(base + from + count) {
                lo = min(lo, channels[c][k])
                hi = max(hi, channels[c][k])
            }
            return PeakPair(lo: lo, hi: hi)
        }
        s += n
    }
    return acc.finish()
}

/// The brute-force reference for ONE channel: every block's min/max over its own frames,
/// starting from (0, 0) as the accumulator's blocks do, over the block grid the accumulator
/// documents (block i ends at floor((i+1) × total/count), the last one on the file's own end).
func referenceBlocks(_ samples: [Float], count: Int) -> [PeakPair] {
    let total = samples.count
    let step = Double(total) / Double(count)
    var result: [PeakPair] = []
    var start = 0
    for i in 0..<count {
        let end = i + 1 >= count ? total : min(Int(Double(i + 1) * step), total)
        var lo: Float = 0, hi: Float = 0
        if start < end {
            for k in start..<end { lo = min(lo, samples[k]); hi = max(hi, samples[k]) }
        }
        result.append(PeakPair(lo: lo, hi: hi))
        start = max(start, end)
    }
    return result
}

@main
enum WaveformPeaksTest {
  static func main() {

    // MARK: - foldRatio

    check("foldRatio(10000, 1000) == 10", WaveformPeaks.foldRatio(fine: 10000, coarse: 1000) == 10)
    check("foldRatio(1000, 100) == 10", WaveformPeaks.foldRatio(fine: 1000, coarse: 100) == 10)
    check("foldRatio guards >= 1 on equal densities",
          WaveformPeaks.foldRatio(fine: 1000, coarse: 1000) == 1)
    check("foldRatio guards >= 1 even if coarse > fine (should never happen, but must not crash)",
          WaveformPeaks.foldRatio(fine: 100, coarse: 1000) >= 1)

    // MARK: - coarseCount

    check("coarseCount(10007, 10) == 1001", WaveformPeaks.coarseCount(fineCount: 10007, ratio: 10) == 1001)
    check("coarseCount(10, 10) == 1", WaveformPeaks.coarseCount(fineCount: 10, ratio: 10) == 1)
    check("coarseCount(1, 10) == 1", WaveformPeaks.coarseCount(fineCount: 1, ratio: 10) == 1)
    check("coarseCount(0, 10) never 0", WaveformPeaks.coarseCount(fineCount: 0, ratio: 10) >= 1)
    check("coarseCount(1000000, 1) == fineCount (ratio 1 = identity in count too)",
          WaveformPeaks.coarseCount(fineCount: 1_000_000, ratio: 1) == 1_000_000)

    // MARK: - decimate: a deterministic 10 007-pair sweep against a hand-recomputed reference

    var rng = DeterministicRNG(seed: 0xC0FFEE)
    var fine: [PeakPair] = []
    fine.reserveCapacity(10_007)
    for _ in 0..<10_007 {
        let a = rng.nextFloat(in: -1...1)
        let b = rng.nextFloat(in: -1...1)
        fine.append(PeakPair(lo: min(a, b), hi: max(a, b)))
    }

    let coarse = WaveformPeaks.decimate(fine, ratio: 10)
    let ref = referenceDecimate(fine, ratio: 10)
    check("decimate(10007, ratio: 10) has the same block count as the reference",
          coarse.count == ref.count, "got \(coarse.count), expected \(ref.count)")
    if coarse.count == ref.count {
        var allExactButLast = true
        for i in 0..<(coarse.count - 1) where coarse[i] != ref[i] {
            allExactButLast = false
        }
        check("every block but the last matches the reference bit for bit", allExactButLast)
        // The last block: `decimate` may cover fewer fine blocks than a naive reference expects
        // right at the tail, never more — so it is always at least as wide an envelope, never
        // narrower (@see WaveformPeaks.decimate's doc comment, and pitfall #8 of PLAN-WAVEFORM.md).
        let lastCoarse = coarse[coarse.count - 1]
        let lastRef = ref[ref.count - 1]
        check("the last block is a superset of the reference's (lo <=, hi >=)",
              lastCoarse.lo <= lastRef.lo && lastCoarse.hi >= lastRef.hi,
              "got \(lastCoarse), reference \(lastRef)")
    }

    // MARK: - decimate: ratio 1 is the identity

    check("decimate(_, ratio: 1) == identity", WaveformPeaks.decimate(fine, ratio: 1) == fine)

    // MARK: - decimate: folding twice by 10 == folding once by 100 (the invariant that licenses
    // the single cascading pass in `computeMipmap`: fine -> ×10 -> ×10, instead of a fresh
    // ×100 fold recomputed from scratch for every coarser level)

    let foldedTwice = WaveformPeaks.decimate(WaveformPeaks.decimate(fine, ratio: 10), ratio: 10)
    let foldedOnce = WaveformPeaks.decimate(fine, ratio: 100)
    check("folding by 10 twice has the same block count as folding by 100 once",
          foldedTwice.count == foldedOnce.count,
          "got \(foldedTwice.count) vs \(foldedOnce.count)")
    if foldedTwice.count == foldedOnce.count {
        var identical = true
        for i in foldedTwice.indices where foldedTwice[i] != foldedOnce[i] { identical = false }
        check("folding by 10 twice == folding by 100 once, block for block", identical)
    }

    // The same invariant across a spread of lengths, including ones not evenly divisible by
    // either 10 or 100 — the case the tail's "fewer than ratio" rule exists for.
    for n in [1, 7, 10, 11, 99, 100, 101, 999, 1000, 1001, 4995, 50_000] {
        var rng2 = DeterministicRNG(seed: UInt64(n) &* 0x9E3779B97F4A7C15)
        var arr: [PeakPair] = []
        arr.reserveCapacity(n)
        for _ in 0..<n {
            let a = rng2.nextFloat(in: -1...1)
            let b = rng2.nextFloat(in: -1...1)
            arr.append(PeakPair(lo: min(a, b), hi: max(a, b)))
        }
        let twice = WaveformPeaks.decimate(WaveformPeaks.decimate(arr, ratio: 10), ratio: 10)
        let once = WaveformPeaks.decimate(arr, ratio: 100)
        check("n=\(n): folding by 10 twice == folding by 100 once (count)",
              twice.count == once.count, "got \(twice.count) vs \(once.count)")
        if twice.count == once.count {
            check("n=\(n): folding by 10 twice == folding by 100 once (values)", twice == once)
        }
    }

    // MARK: - PeakQuantisation (C1a): the round trip, and the assertion that IS the int16 decision

    // A sweep of 20 001 values across [-1, 1]: the round-trip error never exceeds half a step.
    let sweepCount = 20_001
    var worstError: Float = 0
    for i in 0..<sweepCount {
        let v = -1 + 2 * Float(i) / Float(sweepCount - 1)
        let roundTripped = PeakQuantisation.decode(PeakQuantisation.encode(v))
        let error = abs(roundTripped - v)
        worstError = max(worstError, error)
    }
    check("quantisation round trip stays within maxAbsoluteError across 20 001 values",
          worstError <= PeakQuantisation.maxAbsoluteError,
          "worst \(worstError), bound \(PeakQuantisation.maxAbsoluteError)")

    check("encode/decode(0) == 0 exactly", PeakQuantisation.decode(PeakQuantisation.encode(0)) == 0)
    check("encode/decode(1) == 1 exactly", PeakQuantisation.decode(PeakQuantisation.encode(1)) == 1)
    check("encode/decode(-1) == -1 exactly", PeakQuantisation.decode(PeakQuantisation.encode(-1)) == -1)
    check("+1.5 clamps to +1 (a float WAV sample legitimately exceeding ±1 is already pinned to "
          + "the block's edge by clampY — @see PeakQuantisation.encode's doc comment)",
          PeakQuantisation.decode(PeakQuantisation.encode(1.5)) == 1)
    check("-1.5 clamps to -1", PeakQuantisation.decode(PeakQuantisation.encode(-1.5)) == -1)

    // lo <= 0 <= hi preserved on a round trip: no rounding may push `hi` under zero or `lo` above
    // it, which would turn a real crossing envelope into a one-sided one.
    var envelopeOK = true
    for i in 0..<2000 {
        var rng3 = DeterministicRNG(seed: UInt64(i) &+ 1)
        let lo = min(0, rng3.nextFloat(in: -1...0.01))
        let hi = max(0, rng3.nextFloat(in: -0.01...1))
        let q = PeakQuantisation.encode(PeakPair(lo: lo, hi: hi))
        let back = PeakQuantisation.decode(q)
        if !(back.lo <= 0 && back.hi >= 0) { envelopeOK = false }
    }
    check("lo <= 0 <= hi is preserved by encode/decode on a spread of crossing pairs", envelopeOK)

    // The pixel-error bound at the project's own worst case (@see PeakQuantisation.maxAbsoluteError
    // and PLAN-WAVEFORM.md section A1): mid = 450 px, +24 dB = linear gain 15.85. This IS the
    // decision that int16 (not int8) is the right width.
    let worstCasePixelError = PeakQuantisation.maxAbsoluteError * 15.85 * 450
    check("worst-case pixel error (int16, mid 450 px, +24 dB) < 0.5 px",
          worstCasePixelError < 0.5, "got \(worstCasePixelError)")

    // MARK: - WaveformPeaks.sampleEnvelope (C1b0)

    // A known sinusoid: 16 samples per pixel-span should give back the true min and max.
    let sineLen = 1000
    var sine = [Float](repeating: 0, count: sineLen)
    for i in 0..<sineLen { sine[i] = sinf(Float(i) * 0.37) }
    let spanStart = 100.0, spanEnd = 116.0   // 16 samples: [100, 116)
    var bruteLo: Float = sine[100], bruteHi: Float = sine[100]
    for i in 100...115 {
        bruteLo = min(bruteLo, sine[i])
        bruteHi = max(bruteHi, sine[i])
    }
    let env = WaveformPeaks.sampleEnvelope(sine, from: spanStart, to: spanEnd)
    check("sampleEnvelope over 16 samples returns the true min",
          env.lo == bruteLo, "got \(env.lo), expected \(bruteLo)")
    check("sampleEnvelope over 16 samples returns the true max",
          env.hi == bruteHi, "got \(env.hi), expected \(bruteHi)")

    // Under one sample per pixel: degenerates to the linear interpolation the drawing always
    // did (lo == hi), so nothing changes at the zoom the samples mode used to start at.
    let midSpan = WaveformPeaks.sampleEnvelope(sine, from: 100.2, to: 100.8)
    let expectedMid = Double(sine[100]) * (1 - 0.5) + Double(sine[101]) * 0.5
    check("sampleEnvelope under 1 sample/px: lo == hi", midSpan.lo == midSpan.hi)
    check("sampleEnvelope under 1 sample/px: interpolates at the span's midpoint",
          abs(Double(midSpan.lo) - expectedMid) < 1e-6,
          "got \(midSpan.lo), expected \(expectedMid)")

    // An empty array or an out-of-bounds span answers (0, 0), never a crash.
    check("sampleEnvelope on an empty array is (0, 0)",
          WaveformPeaks.sampleEnvelope([], from: 0, to: 10) == PeakPair(lo: 0, hi: 0))
    check("sampleEnvelope entirely past the array's end is (0, 0)",
          WaveformPeaks.sampleEnvelope(sine, from: 5000, to: 5010) == PeakPair(lo: 0, hi: 0))
    check("sampleEnvelope entirely before the array's start is (0, 0)",
          WaveformPeaks.sampleEnvelope(sine, from: -50, to: -10) == PeakPair(lo: 0, hi: 0))

    // MARK: - WaveformPeaks.peakEnvelope (the crop-in bug)

    // One loud block among quiet ones: the transient a crop-in used to make vanish. At ~7 blocks
    // per pixel, EVERY phase of the pixel grid against the block grid must still see it —
    // shifting the phase is exactly what changing `sourceOffset` does.
    var spiky = [PeakPair](repeating: PeakPair(lo: -0.05, hi: 0.05), count: 700)
    spiky[353] = PeakPair(lo: -0.9, hi: 0.95)
    var everyPhaseSeesIt = true
    for step in 0..<20 {
        let phase = Double(step) / 20 * 7
        var seen = false
        var a = phase
        while a < 700 {
            let e = WaveformPeaks.peakEnvelope(spiky, from: a, to: a + 7)
            if e.hi == 0.95 && e.lo == -0.9 { seen = true }
            a += 7
        }
        if !seen { everyPhaseSeesIt = false }
    }
    check("peakEnvelope: an isolated transient survives every pixel phase (crop-in)", everyPhaseSeesIt)

    check("peakEnvelope: union over the blocks touched",
          WaveformPeaks.peakEnvelope(spiky, from: 350.5, to: 353.2) == PeakPair(lo: -0.9, hi: 0.95))
    check("peakEnvelope: a span ending exactly on a boundary does not enter the next block",
          WaveformPeaks.peakEnvelope(spiky, from: 350, to: 353) == PeakPair(lo: -0.05, hi: 0.05))
    check("peakEnvelope: under one block per pixel, straddling a boundary takes both",
          WaveformPeaks.peakEnvelope(spiky, from: 352.8, to: 353.1) == PeakPair(lo: -0.9, hi: 0.95))
    check("peakEnvelope: under one block per pixel, inside one block reads that block",
          WaveformPeaks.peakEnvelope(spiky, from: 352.2, to: 352.7) == PeakPair(lo: -0.05, hi: 0.05))
    check("peakEnvelope: order of from/to does not matter (reverse)",
          WaveformPeaks.peakEnvelope(spiky, from: 353.2, to: 350.5) == PeakPair(lo: -0.9, hi: 0.95))
    check("peakEnvelope: zero-width span reads its block",
          WaveformPeaks.peakEnvelope(spiky, from: 353.5, to: 353.5) == PeakPair(lo: -0.9, hi: 0.95))
    check("peakEnvelope: empty array is (0, 0)",
          WaveformPeaks.peakEnvelope([], from: 0, to: 3) == PeakPair(lo: 0, hi: 0))
    check("peakEnvelope: entirely past the end is (0, 0)",
          WaveformPeaks.peakEnvelope(spiky, from: 700, to: 705) == PeakPair(lo: 0, hi: 0))
    check("peakEnvelope: entirely before the start is (0, 0)",
          WaveformPeaks.peakEnvelope(spiky, from: -9, to: -2) == PeakPair(lo: 0, hi: 0))
    check("peakEnvelope: partly outside is clamped, not zeroed",
          WaveformPeaks.peakEnvelope(spiky, from: 698.5, to: 703) == PeakPair(lo: -0.05, hi: 0.05))

    // MARK: - Lanes: the policy (a stereo file is two stacked waveforms, everything else one)

    check("laneCount: mono → 1", WaveformPeaks.laneCount(channelCount: 1) == 1)
    check("laneCount: stereo → 2", WaveformPeaks.laneCount(channelCount: 2) == 2)
    check("laneCount: 5.1 → 1 (merged: nothing says which channels are left)",
          WaveformPeaks.laneCount(channelCount: 6) == 1)
    check("laneCount: 0 channels → 1, never 0", WaveformPeaks.laneCount(channelCount: 0) == 1)
    check("laneCount never exceeds maxLanes",
          (0...32).allSatisfy { WaveformPeaks.laneCount(channelCount: $0) <= WaveformPeaks.maxLanes })
    check("lane(forChannel:): stereo keeps each channel in its own lane",
          WaveformPeaks.lane(forChannel: 0, laneCount: 2) == 0
          && WaveformPeaks.lane(forChannel: 1, laneCount: 2) == 1)
    check("lane(forChannel:): one lane takes every channel",
          (0..<6).allSatisfy { WaveformPeaks.lane(forChannel: $0, laneCount: 1) == 0 })

    // MARK: - Lanes: the geometry (the bands tile the block, left on top)

    let blockH = 61.0   // odd on purpose: the halves are not whole pixels
    let one = WaveformPeaks.laneBand(0, of: 1, height: blockH)
    check("laneBand: a single lane is the whole block", one.top == 0 && one.height == blockH)
    let upper = WaveformPeaks.laneBand(0, of: 2, height: blockH)
    let lower = WaveformPeaks.laneBand(1, of: 2, height: blockH)
    check("laneBand: lane 0 (left) is the upper half", upper.top == 0 && upper.height == blockH / 2)
    check("laneBand: lane 1 (right) starts where lane 0 ends — no gap, no overlap",
          lower.top == upper.top + upper.height)
    check("laneBand: lane 1 ends exactly on the block's bottom edge",
          abs(lower.top + lower.height - blockH) < 1e-9, "ends at \(lower.top + lower.height)")
    let past = WaveformPeaks.laneBand(5, of: 2, height: blockH)
    let before = WaveformPeaks.laneBand(-1, of: 2, height: blockH)
    check("laneBand: an out-of-range lane is clamped, never outside the block",
          past.top == lower.top && past.height == lower.height
          && before.top == upper.top && before.height == upper.height)

    // MARK: - Lanes: merging them back (a group's composite)

    check("merged: the union of two real envelopes",
          WaveformPeaks.merged(PeakPair(lo: -0.2, hi: 0.7), PeakPair(lo: -0.6, hi: 0.1))
          == PeakPair(lo: -0.6, hi: 0.7))
    check("merged: silence on one side leaves the other whole",
          WaveformPeaks.merged(PeakPair(lo: 0, hi: 0), PeakPair(lo: -0.4, hi: 0.3))
          == PeakPair(lo: -0.4, hi: 0.3))
    check("merged: two degenerate lines → the LOUDER one, sign kept (not a band between them)",
          WaveformPeaks.merged(PeakPair(lo: 0.3, hi: 0.3), PeakPair(lo: -0.5, hi: -0.5))
          == PeakPair(lo: -0.5, hi: -0.5))
    check("merged: a lane merged with itself is itself",
          WaveformPeaks.merged(PeakPair(lo: -0.25, hi: 0.5), PeakPair(lo: -0.25, hi: 0.5))
          == PeakPair(lo: -0.25, hi: 0.5))

    // MARK: - PeakLaneAccumulator: a stereo file folded into two lanes

    // 1.5 s at 8 kHz, 1 000 peaks/s → 1 500 blocks of ~8 frames. LEFT: a sine that never goes
    // past ±0.5. RIGHT: silence, except one loud click the left channel does not have.
    let rate = 8000.0
    let frames = 12_000
    var left = [Float](repeating: 0, count: frames)
    var right = [Float](repeating: 0, count: frames)
    for k in 0..<frames { left[k] = 0.5 * sinf(Float(k) * 0.013) }
    let clickFrame = 7_777
    right[clickFrame] = 0.9
    right[clickFrame + 1] = -0.85
    left[frames - 1] = -0.95   // the file's LAST frame: it must land in the last block
    let stereo = accumulate([left, right], density: 1000, sampleRate: rate, laneCount: 2, chunk: 777)
    let blockCount = Int((1000 * Double(frames) / rate).rounded())
    check("stereo → two lanes", stereo.count == 2, "got \(stereo.count)")
    check("every lane has round(density × duration) blocks",
          stereo.allSatisfy { $0.count == blockCount }, "\(stereo.map { $0.count }) vs \(blockCount)")
    check("lane 0 is the LEFT channel, block for block",
          stereo.count == 2 && stereo[0] == referenceBlocks(left, count: blockCount))
    check("lane 1 is the RIGHT channel, block for block",
          stereo.count == 2 && stereo[1] == referenceBlocks(right, count: blockCount))
    if stereo.count == 2 {
        check("the right channel's click does NOT show on the left lane",
              stereo[0].allSatisfy { $0.hi <= 0.5 && $0.lo >= -0.95 })
        let clickBlocks = stereo[1].filter { $0.hi > 0.8 }
        check("the click shows on the right lane, in one block or two (a straddle)",
              (1...2).contains(clickBlocks.count), "\(clickBlocks.count) blocks")
        check("the right lane is silent everywhere else",
              stereo[1].filter { $0 != PeakPair(lo: 0, hi: 0) }.count <= 2)
        check("the file's last frame lands in the last block",
              stereo[0].last?.lo == -0.95, "last block \(String(describing: stereo[0].last))")
    }

    // The chunking must be invisible: a block straddling a chunk boundary is carried across.
    var chunkingInvisible = true
    for chunk in [1, 5, 8, 777, 4096, frames] {
        let other = accumulate([left, right], density: 1000, sampleRate: rate, laneCount: 2, chunk: chunk)
        if other != stereo { chunkingInvisible = false; print("      differs at chunk \(chunk)") }
    }
    check("the lanes do not depend on the chunk size (1, 5, 8, 777, 4096, whole file)", chunkingInvisible)

    // MARK: - PeakLaneAccumulator: one lane is the UNION, and it equals the lanes merged

    let single = accumulate([left, right], density: 1000, sampleRate: rate, laneCount: 1, chunk: 777)
    check("one lane for two channels → one array", single.count == 1)
    if single.count == 1, stereo.count == 2 {
        var mergedEqualsSingle = true
        for i in 0..<blockCount where WaveformPeaks.merged(stereo[0][i], stereo[1][i]) != single[0][i] {
            mergedEqualsSingle = false
        }
        check("merging the two lanes gives back EXACTLY the one-lane union, block for block "
              + "(so a group's composite of a stereo child is what it was before lanes)",
              mergedEqualsSingle)
        check("the one-lane union keeps the right channel's click (never a mixdown)",
              single[0].contains { $0.hi > 0.8 })
    }

    // The lanes decimate like any peak array, and stay in step.
    if stereo.count == 2 {
        let coarse0 = WaveformPeaks.decimate(stereo[0], ratio: 10)
        let coarse1 = WaveformPeaks.decimate(stereo[1], ratio: 10)
        check("decimating each lane keeps them the same length", coarse0.count == coarse1.count)
        check("the click survives decimation on its own lane only",
              coarse1.contains { $0.hi > 0.8 } && !coarse0.contains { $0.hi > 0.8 })
    }

    // A mono file: one lane, identical to the channel's own reference.
    let mono = accumulate([left], density: 1000, sampleRate: rate, laneCount: 1, chunk: 777)
    check("mono → one lane, the channel itself",
          mono.count == 1 && mono[0] == referenceBlocks(left, count: blockCount))

    print("\n\(total - fails.count)/\(total) passed")
    if !fails.isEmpty {
        print("FAILURES:")
        for f in fails { print(" - \(f)") }
        exit(1)
    }
  }
}

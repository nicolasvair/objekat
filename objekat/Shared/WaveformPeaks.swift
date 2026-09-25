import Foundation
import Accelerate

// The arithmetic of a peak mipmap, with no model behind it — in the spirit of `SendColumns` /
// `SynopticMarquee` / `PianoRollFraming` / `ComposedName` / `CutSelection`, so it can be compiled
// and asserted ALONE:
//
//     swiftc -parse-as-library ../objekat/Shared/WaveformPeaks.swift test_waveform_peaks.swift \
//         -o /tmp/wfpeaks && /tmp/wfpeaks
//
// `PeakPair` lives here rather than nested in `WaveformCache` (where it used to be — a plain
// move, verified source-compatible: nothing outside `WaveformCache.swift` ever names it, every
// other site gets it by type inference from `WaveformCache.peaks(for:pixelsPerSecond:)`).

/// An asymmetric envelope per block: negative extremum (lo) and positive one (hi), raw values in
/// [-1, 1] (no normalisation — the real amplitude).
struct PeakPair: Equatable {
    var lo: Float  // typically <= 0
    var hi: Float  // typically >= 0
}

/// One peak array per LANE, every lane holding the same number of blocks. A lane is what is drawn
/// as one waveform in its own horizontal band of the block: a stereo source has two (left on top,
/// right below), anything else has one (@see `WaveformPeaks.laneCount(channelCount:)` for why a
/// source of three channels or more is NOT split). Stored per lane and never ALSO merged: the
/// merged envelope a group's composite still wants is the union of the lanes, which min/max being
/// associative makes exactly what a single merged pass would have computed — so keeping a merged
/// copy beside the lanes would cost a third more memory to hold nothing new
/// (@see `WaveformPeaks.merged`).
typealias PeakLanes = [[PeakPair]]

// `nonisolated` throughout: this is called from `WaveformCache.computeMipmap`, which runs
// detached, off the main actor by design (@see `WaveformCacheMeter` for the same pattern and the
// same reason) — the project defaults every declaration to `@MainActor` otherwise.
enum WaveformPeaks {
    /// How many FINE blocks fold into one block of a coarser level.
    nonisolated static func foldRatio(fine: Double, coarse: Double) -> Int {
        guard coarse > 0 else { return 1 }
        return max(1, Int((fine / coarse).rounded()))
    }

    /// The block count of a coarser level, derived from the fine one — never recomputed from the
    /// density, so the levels stay exactly nested and the folding is a whole number of blocks
    /// (@see decimate). `ceil`, not a plain division: a fine count that is not a multiple of
    /// `ratio` still owns every one of its blocks, the last coarse block simply covering fewer
    /// than `ratio` of them. Never zero, even for an empty fine level.
    nonisolated static func coarseCount(fineCount: Int, ratio: Int) -> Int {
        guard ratio > 1, fineCount > 0 else { return max(1, fineCount) }
        return max(1, Int((Double(fineCount) / Double(ratio)).rounded(.up)))
    }

    /// min/max is associative, so a coarse level is the fold of the fine one. Three full passes
    /// over the buffer became one (×2.4 measured on the peak stage): `computeMipmap` decodes the
    /// FINEST level directly off the audio, then reaches every coarser level by folding THAT
    /// array instead of re-scanning raw samples. Folding twice by 10 lands on exactly the same
    /// blocks as folding once by 100 — the invariant that makes the cascade (fine → ×10 → ×10)
    /// as exact as one big fold, and cheaper, since the second fold works on an array already
    /// 10× smaller.
    ///
    /// The LAST block can cover FEWER than `ratio` fine blocks (@see coarseCount) — never more,
    /// and never fewer than one live block once `fine` is non-empty.
    nonisolated static func decimate(_ fine: [PeakPair], ratio: Int) -> [PeakPair] {
        guard ratio > 1 else { return fine }
        guard !fine.isEmpty else { return [] }
        let count = coarseCount(fineCount: fine.count, ratio: ratio)
        var result = [PeakPair](repeating: PeakPair(lo: 0, hi: 0), count: count)
        for i in 0..<count {
            let start = i * ratio
            let end = min(start + ratio, fine.count)
            guard start < end else { continue }
            var lo = fine[start].lo
            var hi = fine[start].hi
            for j in (start + 1)..<end {
                if fine[j].lo < lo { lo = fine[j].lo }
                if fine[j].hi > hi { hi = fine[j].hi }
            }
            result[i] = PeakPair(lo: lo, hi: hi)
        }
        return result
    }
}

/// A peak pair as it is WRITTEN to a `.wfc`: two signed 16-bit values. Only the DISK format is
/// quantised — the memory cache (`WaveformCache.Entry.peaks`) stays `Float`, because the drawing
/// reads a pair per pixel per block per FRAME, and a decode there would be paid forever, whereas
/// a decode at load is paid once per file.
struct QuantisedPeakPair: Equatable {
    var lo: Int16
    var hi: Int16
}

// `nonisolated` throughout — see the note above `WaveformPeaks`.
enum PeakQuantisation {
    /// `Int16.max`, not `32768`: encoding stays symmetric around zero (`encode(1) == -encode(-1)`
    /// in magnitude), at the cost of one unused code (`-32768`) nothing ever produces.
    nonisolated static let scale: Float = 32767

    /// A `|v| > 1` WAV float sample is legitimate and NOT clamped here for safety's sake alone:
    /// the drawing already clamps every point to its lane's own band (`appendEnvelopeFill`'s `y`,
    /// `WaveformDrawing.draw`'s `laneY` — the whole block for a mono file), and
    /// `waveformDisplayDB` only ever ADDS gain (0…24 dB, never negative) — so anything past ±1
    /// was already pinned to the block's edge before this quantisation existed. Clipping the
    /// cache loses nothing VISIBLE today. That is a property of the DRAWING, not a guarantee:
    /// the day `waveformDisplayDB` can go negative, this argument no longer holds and the format
    /// would need a stored scale factor instead of an assumed [-1, 1] range.
    nonisolated static func encode(_ v: Float) -> Int16 {
        let clamped = min(1, max(-1, v))
        return Int16((clamped * scale).rounded())
    }

    nonisolated static func decode(_ q: Int16) -> Float {
        Float(q) / scale
    }

    nonisolated static func encode(_ p: PeakPair) -> QuantisedPeakPair {
        QuantisedPeakPair(lo: encode(p.lo), hi: encode(p.hi))
    }

    nonisolated static func decode(_ q: QuantisedPeakPair) -> PeakPair {
        PeakPair(lo: decode(q.lo), hi: decode(q.hi))
    }

    /// The worst a round trip can drift: half a quantisation step. At the project's own worst
    /// case (a block stretched to `mid = 450` px, `waveformDisplayDB` pushed to +24 dB, i.e. a
    /// linear gain of 10^(24/20) ≈ 15.85) that is `maxAbsoluteError × 15.85 × 450 ≈ 0.11` px —
    /// the assertion that IS the int16 decision (@see PLAN-WAVEFORM.md, section A1).
    nonisolated static var maxAbsoluteError: Float { 1 / (2 * scale) }
}

extension WaveformPeaks {
    /// `PeakPair`'s layout as vDSP needs it: `lo` then `hi`, no padding.
    nonisolated static let peakPairIsInterleaved: Bool =
        MemoryLayout<PeakPair>.stride == 2 * MemoryLayout<Float>.stride
        && MemoryLayout<PeakPair>.offset(of: \PeakPair.hi) == MemoryLayout<Float>.stride

    /// The (lo, hi) of the PEAK BLOCKS a single pixel covers, `from`/`to` given as FRACTIONAL block
    /// indices into `p` (file time × blocks per second — the caller converts), in either order.
    ///
    /// The union of EVERY block the span touches, never one of them. The drawing used to read the
    /// single block under the pixel's left edge, which is point sampling: the level is picked so
    /// that a pixel covers one block or more (@see `WaveformCache.peaks(for:pixelsPerSecond:)` —
    /// at 150 px/s that is ~7 blocks of the 1 000/s level per pixel), so six blocks out of seven
    /// were never looked at. An isolated transient then showed or vanished depending on the
    /// PHASE between the pixel grid and the block grid — which is exactly what a crop-in moves
    /// (a new `sourceOffset` shifts every pixel's start by a fraction of a block), hence big peaks
    /// disappearing on a trim. Straddling a boundary with less than a block per pixel takes both
    /// blocks too: a peak block is already an envelope, and widening by one block at worst is
    /// invisible where losing a transient is not.
    ///
    /// (0, 0) on an empty array or a span entirely outside it; a span partly outside is clamped.
    nonisolated static func peakEnvelope(_ p: [PeakPair], from: Double, to: Double) -> PeakPair {
        let n = p.count
        guard n > 0 else { return PeakPair(lo: 0, hi: 0) }
        let a = min(from, to), b = max(from, to)
        guard b >= 0, a < Double(n) else { return PeakPair(lo: 0, hi: 0) }
        let first = max(0, Int(a.rounded(.down)))
        // `ceil(b) - 1` is the last block the span actually ENTERS (b exactly on a boundary does
        // not enter the next one); never before `first`, a zero-width span still reads its block.
        let last = min(n - 1, max(first, Int(b.rounded(.up)) - 1))
        guard last > first else { return p[first] }
        var lo: Float = 0, hi: Float = 0
        // `PeakPair` is two `Float`s, so the array reads as interleaved lo/hi at stride 2
        // (checked by `peakPairIsInterleaved`, a loop otherwise).
        if peakPairIsInterleaved {
            p.withUnsafeBufferPointer { buf in
                buf.withMemoryRebound(to: Float.self) { f in
                    let base = f.baseAddress! + 2 * first
                    let count = vDSP_Length(last - first + 1)
                    vDSP_minv(base, 2, &lo, count)
                    vDSP_maxv(base + 1, 2, &hi, count)
                }
            }
        } else {
            lo = p[first].lo; hi = p[first].hi
            for i in (first + 1)...last {
                if p[i].lo < lo { lo = p[i].lo }
                if p[i].hi > hi { hi = p[i].hi }
            }
        }
        return PeakPair(lo: lo, hi: hi)
    }

    /// The (lo, hi) of the samples a single pixel covers, `from`/`to` given as FRACTIONAL sample
    /// indices into `s` (not seconds — the caller has already multiplied by the sample rate).
    ///
    /// Under one sample per pixel (`to - from < 1`) this degenerates to the linear interpolation
    /// the samples-mode drawing has always done, `lo == hi` at the midpoint — so at the zoom the
    /// samples mode used to start at (30 000 px/s, ~1.6 samples/px at 48 kHz), nothing changes on
    /// screen. Above one sample per pixel it is a real min/max over the span, which is what a
    /// peaks LEVEL does and what point sampling does NOT: at 3 000 px/s a pixel spans 16 samples
    /// at 48 kHz, and drawing one of those 16 draws an alias, not a waveform (@see
    /// PLAN-WAVEFORM.md, section A2 — the reason this function exists at all).
    ///
    /// (0, 0) on an empty array or a span entirely out of `s`'s bounds — never a crash, the same
    /// contract the drawing's own bounds check (`sIdx < 0 || sIdx >= n - 1`) already relied on.
    nonisolated static func sampleEnvelope(_ s: [Float], from: Double, to: Double) -> PeakPair {
        let n = s.count
        guard n > 0 else { return PeakPair(lo: 0, hi: 0) }

        if to - from < 1 {
            // The exact formula the drawing used before this existed: interpolate at the span's
            // midpoint. Guarded the same way — `mid < n - 1` so `i0 + 1` never runs off the end.
            let mid = (from + to) * 0.5
            guard mid >= 0, mid < Double(n - 1) else { return PeakPair(lo: 0, hi: 0) }
            let i0 = Int(mid.rounded(.down))
            let frac = mid - Double(i0)
            let v = Float(Double(s[i0]) * (1 - frac) + Double(s[i0 + 1]) * frac)
            return PeakPair(lo: v, hi: v)
        }

        guard to >= 0, from < Double(n) else { return PeakPair(lo: 0, hi: 0) }
        let lo0 = max(0, Int(from.rounded(.down)))
        let hi0 = min(n - 1, Int(to.rounded(.up)))
        guard lo0 <= hi0 else { return PeakPair(lo: 0, hi: 0) }
        var lo: Float = 0, hi: Float = 0
        s.withUnsafeBufferPointer { p in
            let base = p.baseAddress! + lo0
            let count = vDSP_Length(hi0 - lo0 + 1)
            vDSP_minv(base, 1, &lo, count)
            vDSP_maxv(base, 1, &hi, count)
        }
        return PeakPair(lo: lo, hi: hi)
    }
}

// MARK: - Lanes: a stereo source drawn as two stacked waveforms

extension WaveformPeaks {
    /// The most lanes any source is drawn in. The `.wfc` reader refuses a file claiming more.
    nonisolated static let maxLanes = 2

    /// How many stacked waveforms a source of `channelCount` channels is drawn in: TWO for a stereo
    /// file (left on the upper half of the block, right on the lower), ONE for everything else.
    ///
    /// Why a file of three channels or more stays merged rather than being split in two: nothing in
    /// the file says which of its channels are "left". A 5.1 is L R C LFE Ls Rs in one convention
    /// and L C R Ls Rs LFE in another, a four-channel file may be a quad or two stereo pairs — any
    /// fold into two lanes would draw one of them under the wrong side, and a stacked pair READS as
    /// left/right whatever it was built from. One merged lane is less detailed but never lies
    /// (the union of every channel, @see `lane(forChannel:laneCount:)`). The whole policy is this
    /// one line: changing it changes what a `.wfc` holds, so it goes with a bump of
    /// `WaveformCache.formatVersion`, or a file written under the old rule would be read under the
    /// new one.
    nonisolated static func laneCount(channelCount: Int) -> Int {
        channelCount == 2 ? 2 : 1
    }

    /// The lane a channel's matter goes into. With one lane every channel folds into it — the
    /// UNION of their envelopes, never a mixdown: summing can halve matter sitting on one channel
    /// alone and cancel a pair in phase opposition outright, drawing silence over real sound.
    nonisolated static func lane(forChannel channel: Int, laneCount: Int) -> Int {
        laneCount <= 1 ? 0 : min(max(0, channel), laneCount - 1)
    }

    /// Lane `lane`'s horizontal band inside a block of `height`: equal shares, top to bottom, no
    /// gap and no overlap, so the bands tile the block exactly. Each lane is then drawn exactly as
    /// a whole block used to be — 0 dBFS at its band's own edges, its zero line at its band's middle,
    /// and clamped to its band, so a lane pushed past its edge by the waveform gain stops there
    /// rather than bleeding over its neighbour.
    nonisolated static func laneBand(_ lane: Int, of laneCount: Int, height: Double) -> (top: Double, height: Double) {
        let n = max(1, laneCount)
        let share = height / Double(n)
        return (share * Double(min(max(0, lane), n - 1)), share)
    }

    /// Two lanes' envelopes of the SAME pixel, merged into the one a single waveform draws — what a
    /// group's composite still shows, the lanes of every child flattened (@see `GroupWaveformView`).
    ///
    /// The union (the lowest `lo`, the highest `hi`) — exactly what one pass over every channel
    /// would have computed, min/max being associative, so a stereo child reads in the composite as
    /// it did before lanes existed. With ONE exception: when both envelopes have degenerated to a
    /// single value (under one sample per pixel, @see `sampleEnvelope`), a union would be a band
    /// between the two channels where a line is expected; the value of LARGEST MAGNITUDE wins then,
    /// sign kept — the rule the sample regions used to apply per sample before they were split into
    /// lanes, so the deep-zoom composite is still a line following the louder channel.
    nonisolated static func merged(_ a: PeakPair, _ b: PeakPair) -> PeakPair {
        if a.lo == a.hi, b.lo == b.hi {
            return abs(b.lo) > abs(a.lo) ? b : a
        }
        return PeakPair(lo: min(a.lo, b.lo), hi: max(a.hi, b.hi))
    }
}

/// The finest level's blocks, per LANE, filled while the file streams past in chunks — moved out
/// of `WaveformCache` (where it was `LevelAccumulator`, one lane) so the folding can be asserted
/// alone (`tools/test_waveform_peaks.swift`), in the spirit of the rest of this file.
///
/// It keeps the in-progress block's (lo, hi) of every lane across chunk boundaries — a block is far
/// narrower than a chunk (48 frames at 1 000 peaks/s and 48 kHz, against `chunkFrames`), so it WILL
/// straddle a boundary, at most one block per boundary. Skipping that carry would draw a false notch
/// once per chunk worth of file.
///
/// A block always starts at (0, 0), so its envelope always contains the zero line — what the
/// drawing has always assumed (a block of pure DC still draws down to the axis).
nonisolated struct PeakLaneAccumulator {
    let count: Int
    let laneCount: Int
    private let step: Double
    private let total: Int
    private var lanes: PeakLanes
    private var blockIndex = 0
    private var blockEnd: Int
    // The open block's running extrema, one slot per lane — allocated once, never per frame.
    private var lo: [Float]
    private var hi: [Float]

    init(density: Double, duration: Double, total: Int, laneCount: Int) {
        count = max(1, Int((density * duration).rounded()))
        self.laneCount = max(1, laneCount)
        step = Double(total) / Double(count)
        self.total = total
        lanes = PeakLanes(repeating: [PeakPair](repeating: PeakPair(lo: 0, hi: 0), count: count),
                          count: self.laneCount)
        lo = [Float](repeating: 0, count: self.laneCount)
        hi = [Float](repeating: 0, count: self.laneCount)
        blockEnd = Self.end(ofBlock: 0, count: count, step: step, total: total)
    }

    /// Where block `i` ends (exclusive, in frames). The LAST block ends on the file's own last
    /// frame by construction rather than by arithmetic: `Double(count) * (total / count)` can land
    /// a hair under `total`, and the old per-frame accumulator then dropped the final frame.
    private static func end(ofBlock i: Int, count: Int, step: Double, total: Int) -> Int {
        i + 1 >= count ? total : min(Int(Double(i + 1) * step), total)
    }

    /// Folds the file's next `frameCount` frames, starting at absolute frame `startFrame` — the
    /// chunks must arrive in order and contiguous across the whole file, the one assumption that
    /// makes this a single streaming pass.
    ///
    /// The chunk is cut at block boundaries and `extent(channel, from, count)` is asked for the
    /// (min, max) of `count >= 1` frames of `channel`, `from` frames into the chunk — once per
    /// SEGMENT and channel, never per frame, so the caller can hand it to vDSP (@see
    /// `WaveformCache.decodeChunked`). Channel `c` folds into `lane(forChannel: c, …)`.
    mutating func add(startFrame: Int, frameCount: Int, channelCount: Int,
                      extent: (_ channel: Int, _ from: Int, _ count: Int) -> PeakPair) {
        var f = startFrame
        let end = startFrame + frameCount
        while f < end {
            while f >= blockEnd, blockIndex < count { closeBlock() }
            guard blockIndex < count else { return }
            let segmentEnd = min(end, blockEnd)   // > f: the loop above left `blockEnd` past `f`
            for c in 0..<max(0, channelCount) {
                let e = extent(c, f - startFrame, segmentEnd - f)
                let l = WaveformPeaks.lane(forChannel: c, laneCount: laneCount)
                if e.lo < lo[l] { lo[l] = e.lo }
                if e.hi > hi[l] { hi[l] = e.hi }
            }
            f = segmentEnd
        }
    }

    private mutating func closeBlock() {
        for l in 0..<laneCount {
            lanes[l][blockIndex] = PeakPair(lo: lo[l], hi: hi[l])
            lo[l] = 0; hi[l] = 0
        }
        blockIndex += 1
        if blockIndex < count {
            blockEnd = Self.end(ofBlock: blockIndex, count: count, step: step, total: total)
        }
    }

    /// Closes whatever block is still open once the last chunk has been folded in.
    mutating func finish() -> PeakLanes {
        while blockIndex < count { closeBlock() }
        return lanes
    }
}

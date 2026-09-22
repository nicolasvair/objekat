import Foundation

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

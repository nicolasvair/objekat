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
    /// `WaveformDrawing.clampY` already bounds every drawn point to the block's own height, and
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

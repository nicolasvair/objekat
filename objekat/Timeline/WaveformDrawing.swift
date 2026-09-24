import SwiftUI

/// Drawing a clip's waveform into a SwiftUI `GraphicsContext`, in coordinates LOCAL to the
/// block (origin 0,0, size = `size`). A single source shared by:
///   - `TimelineWaveformView` (one Canvas per block — the rich/selected case),
///   - the SINGLE blocks Canvas (`TimelineBlocksCanvas`) which translates the context onto
///     each block then calls this drawing (1 view node for N blocks).
/// The same logic as the old one (peaks vs samples, fade/gain/speed/reverse at render time).
enum WaveformDrawing {

    /// Folding a display position back onto the looped slice. A single rule, shared by the batched
    /// fill and the rich drawing: the local time `u` (0 = the block's left edge) reads the content
    /// at `start + (u mod period)`. So the left edge plays the part of the IN point, and the slice
    /// repeats from there — exactly the engine's folding. @see [[loop-item-plan]]
    struct LoopFold {
        let start: Double
        let period: Double
        func sourceLocalTime(at u: Double) -> Double {
            start + max(0, u).truncatingRemainder(dividingBy: period)
        }
    }

    /// `nil` (= no folding) if the loop is off, the range empty, or the clip reversed
    /// (`canLoop` already rules reverse out on the model's side).
    static func loopFold(_ range: (start: Double, end: Double)?, isReversed: Bool) -> LoopFold? {
        guard !isReversed, let r = range, r.end - r.start > 0.0001 else { return nil }
        return LoopFold(start: r.start, period: r.end - r.start)
    }

    /// What ONE pixel column of a file looks like, read from whichever source the zoom calls for:
    /// decoded samples when a region is at hand, the peak level otherwise. The single reader of
    /// every waveform drawn — a clip's rich view, the batched canvas, a group's composite — so a
    /// clip and the same clip inside a group can no longer disagree (the group read one peak per
    /// pixel, capped at the 1 000/s level, and showed steps at a zoom where the clip beside it was
    /// smooth). Always the UNION of what the column covers, never a point sample
    /// (@see `WaveformPeaks.peakEnvelope` for the crop-in bug that point sampling was).
    struct EnvelopeSource {
        let peaks: [PeakPair]
        let fileDuration: Double
        let region: WaveformCache.SampleRegion?

        /// `fileA`/`fileB`: the file times at the column's two edges, in either order (reverse).
        func envelope(fileA: Double, fileB: Double) -> PeakPair {
            if let r = region {
                let sr = r.sampleRate
                return WaveformPeaks.sampleEnvelope(r.samples, from: (fileA - r.startTime) * sr,
                                                    to: (fileB - r.startTime) * sr)
            }
            guard fileDuration > 0 else { return PeakPair(lo: 0, hi: 0) }
            let perSecond = Double(peaks.count) / fileDuration
            return WaveformPeaks.peakEnvelope(peaks, from: fileA * perSecond, to: fileB * perSecond)
        }
    }

    /// The largest file window a samples region is requested for. A loop's whole slice can be
    /// asked for (@see `draw`), and beyond this a region would weigh on `regionByteCap` for a
    /// view that the peaks draw just as well.
    static let maxRegionRequestSpan: Double = 8

    /// The envelope source for a file at this zoom: a samples region past
    /// `WaveformCache.sampleModeThreshold` when the window is sane and the region already decoded
    /// (a miss schedules the decode and falls back on the peaks for this frame), the peaks
    /// otherwise. nil = nothing to draw yet (the file is still being analysed).
    static func envelopeSource(waveformCache: WaveformCache, filePath: String, pixelsPerSecond: Double,
                               window: (lo: Double, hi: Double)?) -> EnvelopeSource? {
        guard let fileDuration = waveformCache.duration(for: filePath), fileDuration > 0,
              let peaks = waveformCache.peaks(for: filePath, pixelsPerSecond: pixelsPerSecond),
              !peaks.isEmpty else { return nil }
        var region: WaveformCache.SampleRegion? = nil
        if pixelsPerSecond >= WaveformCache.sampleModeThreshold, let w = window,
           w.hi > w.lo, w.hi - w.lo <= maxRegionRequestSpan {
            region = waveformCache.samplesRegion(for: filePath, fileStart: max(0, w.lo),
                                                 fileEnd: min(fileDuration, w.hi))
        }
        return EnvelopeSource(peaks: peaks, fileDuration: fileDuration, region: region)
    }

    /// Adds the filled envelope of columns `startI...endI` to `path`: the `hi` edge forwards, the
    /// `lo` edge back. `column(i)` answers the (lo, hi) of column `i`, ALREADY multiplied by the
    /// gain/fade chain; `x(i)` places it. One pass per column — the envelope walks every block or
    /// sample the column covers, so it is computed once and its `lo` kept for the way back.
    static func appendEnvelopeFill(to path: inout Path, from startI: Int, through endI: Int,
                                   x: (Int) -> Double, y0: Double, h: Double, mid: Double, vScale: Double,
                                   column: (Int) -> (lo: Double, hi: Double)) {
        guard endI >= startI else { return }
        func y(_ v: Double) -> Double { y0 + min(h, max(0, mid - v * vScale)) }
        var los: [Double] = []
        los.reserveCapacity(endI - startI + 1)
        for i in startI...endI {
            let c = column(i)
            let p = CGPoint(x: x(i), y: y(c.hi))
            if i == startI { path.move(to: p) } else { path.addLine(to: p) }
            los.append(c.lo)
        }
        for i in stride(from: endI, through: startI, by: -1) {
            path.addLine(to: CGPoint(x: x(i), y: y(los[i - startI])))
        }
        path.closeSubpath()
    }

    /// The BATCHED variant (peaks mode): instead of filling, it ADDS the waveform's polygon to
    /// `path` in CANVAS coordinates (offset by originX/originY). The caller accumulates one Path
    /// per fill colour and fills ONCE (≈ 1 op instead of N). Returns `false`
    /// if 'samples' mode (extreme zoom) applies → the caller draws that block separately through
    /// `draw(...)`. Returns `true` if handled (added, or nothing to draw).
    static func appendPeaksFill(
        to path: inout Path,
        originX: Double, originY: Double, size: CGSize,
        waveformCache: WaveformCache, filePath: String,
        sourceOffset: Double, pixelsPerSecond: Double,
        scrollOffsetX: CGFloat, viewportWidth: CGFloat,
        clipDuration: Double, speedRatio: Double, isReversed: Bool,
        volumeDb: Float, fadeIn: Double, fadeOut: Double,
        curveIn: FadeCurve = .linear, curveOut: FadeCurve = .linear,
        waveformDisplayDB: Double,
        loopRange: (start: Double, end: Double)? = nil
    ) -> Bool {
        guard (waveformCache.duration(for: filePath) ?? 0) > 0 else { return true }
        if pixelsPerSecond >= WaveformCache.sampleModeThreshold { return false }   // samples mode → drawn individually
        guard let source = envelopeSource(waveformCache: waveformCache, filePath: filePath,
                                          pixelsPerSecond: pixelsPerSecond, window: nil) else { return true }

        let gainLin = WaveformShaping.linearGain(dB: volumeDb)
        let displayGain = WaveformShaping.linearGain(dB: Float(waveformDisplayDB))
        let h = size.height
        let mid = h * 0.5
        let vScale = mid * displayGain
        func mul(_ i: Int) -> Double {
            gainLin * WaveformShaping.fadeEnvelope(localTime: Double(i) / pixelsPerSecond,
                                                   duration: clipDuration, fadeIn: fadeIn, fadeOut: fadeOut,
                                                   curveIn: curveIn, curveOut: curveOut)
        }
        func src(_ i: Int) -> Double {
            WaveformShaping.sourceTime(localTime: Double(i) / pixelsPerSecond,
                                       sourceOffset: sourceOffset, duration: clipDuration,
                                       speedRatio: speedRatio, isReversed: isReversed)
        }
        // Looping: the [IN,OUT] slice (in seconds LOCAL to the block) repeats FROM THE BLOCK'S LEFT
        // EDGE — which is what the engine does, folding the playback position onto the range and
        // therefore making the block start on the IN point (@see OBJEngineCore.mm, updatePosition:,
        // [[loop-item-plan]]). The folding applies to the WHOLE block, not only beyond the content:
        // with the IN moved in, the first period is already offset.
        // Not handled in reverse (`canLoop` already rules it out on the model's side).
        let loop = WaveformDrawing.loopFold(loopRange, isReversed: isReversed)
        func loopedSrc(_ i: Int) -> Double {
            guard let loop else { return src(i) }
            return sourceOffset + loop.sourceLocalTime(at: Double(i) / pixelsPerSecond) * speedRatio
        }
        // A column's file span, UNFOLDED: the next column's own position would jump back across a
        // loop's repeat point and take the whole slice for one pixel.
        let srcStep = (isReversed ? -speedRatio : speedRatio) / pixelsPerSecond

        let margin: CGFloat = 2
        let visStart = max(0, scrollOffsetX - CGFloat(originX) - margin)
        let visEnd   = min(size.width, scrollOffsetX + viewportWidth - CGFloat(originX) + margin)
        let startI = Int(visStart)
        let endI   = Int(visEnd)
        guard endI > startI else { return true }

        appendEnvelopeFill(to: &path, from: startI, through: endI,
                           x: { originX + Double($0) }, y0: originY, h: h, mid: mid, vScale: vScale) { i in
            let a = loopedSrc(i)
            let e = source.envelope(fileA: a, fileB: a + srcStep)
            let m = mul(i)
            return (Double(e.lo) * m, Double(e.hi) * m)
        }
        return true
    }

    /// Thin vertical lines at the loop's boundaries (each repeat of the source content), in
    /// coordinates LOCAL to the block (like `draw`: 0 = the block's left edge — it is up to the
    /// caller to translate the context if it draws on a shared canvas). `blockOriginX` serves ONLY
    /// to compute the visible portion (the same formula as `visStart`/`visEnd` in `draw`), never to
    /// offset the points on the way out. Empty if the loop is not active, if the clip is reversed
    /// (not handled yet on the loop's side, @see SoundObject.canLoop) or if the period is zero.
    static func appendLoopMarkers(
        to path: inout Path,
        blockOriginX: Double, size: CGSize,
        pixelsPerSecond: Double,
        scrollOffsetX: CGFloat, viewportWidth: CGFloat,
        clipDuration: Double, isReversed: Bool,
        loopRange: (start: Double, end: Double)?
    ) {
        guard !isReversed, let r = loopRange else { return }
        let period = r.end - r.start              // LOCAL seconds (the block's window)
        guard period > 0.02 else { return }   // the period is too fine to read on screen

        let margin: CGFloat = 2
        let visStart = max(0, scrollOffsetX - CGFloat(blockOriginX) - margin)
        let visEnd   = min(size.width, scrollOffsetX + viewportWidth - CGFloat(blockOriginX) + margin)
        guard visEnd > visStart else { return }

        let tStart = Double(visStart) / pixelsPerSecond
        let tEnd   = Double(visEnd) / pixelsPerSecond
        var k = Int((tStart / period).rounded(.down))
        while Double(k) * period <= tEnd {
            let t = Double(k) * period
            k += 1
            guard t > 0.02, t < clipDuration - 0.02 else { continue }   // not on the block's edges
            let x = t * pixelsPerSecond
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
        }
    }

    static func draw(
        into ctx: GraphicsContext,
        size: CGSize,
        waveformCache: WaveformCache,
        filePath: String,
        sourceOffset: Double,
        pixelsPerSecond: Double,
        scrollOffsetX: CGFloat,
        viewportWidth: CGFloat,
        xPos: Double,
        stemColor: Color,
        isSelected: Bool,
        clipDuration: Double,
        speedRatio: Double,
        isReversed: Bool,
        volumeDb: Float,
        fadeIn: Double,
        fadeOut: Double,
        curveIn: FadeCurve = .linear,
        curveOut: FadeCurve = .linear,
        isMuted: Bool,
        waveformDisplayDB: Double,
        loopRange: (start: Double, end: Double)? = nil
    ) {
        guard (waveformCache.duration(for: filePath) ?? 0) > 0 else { return }

        let gainLin = WaveformShaping.linearGain(dB: volumeDb)
        let displayGain = WaveformShaping.linearGain(dB: Float(waveformDisplayDB))

        let h = size.height
        let mid = h * 0.5
        let strokeColor: Color = isMuted ? .gray : stemColor
        let fillColor:   Color = isMuted
            ? Color.gray.opacity(0.45)
            : stemColor.opacity(isSelected ? 1.0 : 0.95)

        func mulT(_ localT: Double) -> Double {
            gainLin * WaveformShaping.fadeEnvelope(
                localTime: localT, duration: clipDuration, fadeIn: fadeIn, fadeOut: fadeOut,
                curveIn: curveIn, curveOut: curveOut)
        }
        func mul(_ i: Int) -> Double { mulT(Double(i) / pixelsPerSecond) }
        func src(_ i: Int) -> Double {
            WaveformShaping.sourceTime(localTime: Double(i) / pixelsPerSecond,
                                       sourceOffset: sourceOffset, duration: clipDuration,
                                       speedRatio: speedRatio, isReversed: isReversed)
        }
        // @see appendPeaksFill: the same looping rule (folding onto the [IN,OUT] slice).
        let loop = WaveformDrawing.loopFold(loopRange, isReversed: isReversed)
        func loopedSrc(_ i: Int) -> Double {
            guard let loop else { return src(i) }
            return sourceOffset + loop.sourceLocalTime(at: Double(i) / pixelsPerSecond) * speedRatio
        }
        func clampY(_ y: Double) -> Double { min(h, max(0, y)) }
        // A column's file span, unfolded — @see appendPeaksFill.
        let srcStep = (isReversed ? -speedRatio : speedRatio) / pixelsPerSecond

        let margin: CGFloat = 2
        let visStart = max(0, scrollOffsetX - CGFloat(xPos) - margin)
        let visEnd   = min(size.width, scrollOffsetX + viewportWidth - CGFloat(xPos) + margin)
        let startI = Int(visStart)
        let endI   = Int(visEnd)
        guard endI > startI else { return }

        let vScale = mid * displayGain

        // The source window to load in 'samples' mode. Under a loop, the folded positions are no
        // longer monotonic: we load the whole looped SLICE rather than the raw range of the visible
        // edges, which ran past the end of the file and left a brief silence exactly at the repeat
        // points. @see [[loop-item-plan]]
        let srcA = src(startI), srcB = src(endI)
        var winStart = min(srcA, srcB)
        var winEnd   = max(srcA, srcB)
        if let loop {
            winStart = sourceOffset + loop.start * speedRatio
            winEnd   = sourceOffset + (loop.start + loop.period) * speedRatio
        }
        let region = pixelsPerSecond >= WaveformCache.sampleModeThreshold
            ? waveformCache.samplesRegion(for: filePath, fileStart: winStart, fileEnd: winEnd)
            : nil

        if let region {
            let samples = region.samples
            let sr = region.sampleRate
            let n = samples.count
            var poly = Path()
            var filled = Path()
            var polyStarted = false
            // The STROKE only earns its place where the envelope DEGENERATES (under ~2 samples per
            // pixel, @see WaveformPeaks.sampleEnvelope): above that it is a line of the fill's own
            // colour drawn INSIDE the fill — invisible, and a stroke of a jagged polyline is the
            // dearest thing CoreGraphics is asked for here, once per block per frame.
            let needsStroke = sr * abs(srcStep) < 2
            // One (lo, hi) per pixel, kept for the backward pass below instead of recomputed —
            // `sampleEnvelope` walks every sample the pixel covers, so doing it twice would cost
            // exactly what this commit exists to avoid.
            var loValues: [Double] = []
            loValues.reserveCapacity(endI - startI + 1)
            for i in startI...endI {
                let m = mul(i)
                let sIdx = (loopedSrc(i) - region.startTime) * sr
                if needsStroke {
                    // The stroke and the per-sample dots below read a single interpolated value:
                    // they only draw where the envelope is degenerate anyway, where the point they
                    // trace and the fill's own edge coincide.
                    var value: Double
                    if sIdx < 0 || sIdx >= Double(n - 1) {
                        value = 0
                    } else {
                        let i0 = Int(sIdx.rounded(.down))
                        let frac = sIdx - Double(i0)
                        value = Double(samples[i0]) * (1 - frac) + Double(samples[i0 + 1]) * frac
                    }
                    let strokePoint = CGPoint(x: Double(i), y: clampY(mid - value * m * vScale))
                    if !polyStarted { poly.move(to: strokePoint); polyStarted = true }
                    else { poly.addLine(to: strokePoint) }
                }

                // The FILL reads the true (lo, hi) spread of every sample this pixel covers —
                // what keeps the envelope from THINNING at the samples-mode threshold: a pixel
                // spanning several samples showed one aliased point among them before this commit
                // (@see PLAN-WAVEFORM.md section A2). The span is taken UNFOLDED (@see `srcStep`):
                // the next pixel's own position jumps back across a loop's repeat point and made
                // one pixel the envelope of the whole slice.
                let idxA = sIdx
                let idxB = idxA + srcStep * sr
                let envelope = WaveformPeaks.sampleEnvelope(samples, from: min(idxA, idxB), to: max(idxA, idxB))
                let hiVal = Double(envelope.hi) * m
                loValues.append(Double(envelope.lo) * m)
                if i == startI { filled.move(to: CGPoint(x: Double(i), y: clampY(mid - hiVal * vScale))) }
                else { filled.addLine(to: CGPoint(x: Double(i), y: clampY(mid - hiVal * vScale))) }
            }
            for i in stride(from: endI, through: startI, by: -1) {
                filled.addLine(to: CGPoint(x: Double(i), y: clampY(mid - loValues[i - startI] * vScale)))
            }
            filled.closeSubpath()
            ctx.fill(filled, with: .color(fillColor))
            if needsStroke { ctx.stroke(poly, with: .color(strokeColor), lineWidth: 1) }

            if pixelsPerSecond >= sr * 3 {
                let firstJ = max(0, Int(((winStart - region.startTime) * sr).rounded(.down)))
                let lastJ  = min(n - 1, Int(((winEnd - region.startTime) * sr).rounded(.up)))
                if lastJ > firstJ {
                    for j in firstJ...lastJ {
                        let st = region.startTime + Double(j) / sr
                        let localT0 = speedRatio != 0 ? (st - sourceOffset) / speedRatio : 0
                        let localT = isReversed ? (clipDuration - localT0) : localT0
                        let x = localT * pixelsPerSecond
                        if x < Double(startI) || x > Double(endI) { continue }
                        let y = clampY(mid - Double(samples[j]) * mulT(localT) * vScale)
                        let r: CGFloat = 2
                        let dot = Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
                        ctx.fill(dot, with: .color(strokeColor))
                    }
                }
            }
        } else if let source = envelopeSource(waveformCache: waveformCache, filePath: filePath,
                                              pixelsPerSecond: pixelsPerSecond, window: nil) {
            // Peaks: below the samples threshold, or while the region is still being decoded.
            var path = Path()
            appendEnvelopeFill(to: &path, from: startI, through: endI,
                               x: { Double($0) }, y0: 0, h: h, mid: mid, vScale: vScale) { i in
                let a = loopedSrc(i)
                let e = source.envelope(fileA: a, fileB: a + srcStep)
                let m = mul(i)
                return (Double(e.lo) * m, Double(e.hi) * m)
            }
            ctx.fill(path, with: .color(fillColor))
        }

        if loop != nil {
            var markers = Path()
            appendLoopMarkers(to: &markers, blockOriginX: xPos, size: size,
                              pixelsPerSecond: pixelsPerSecond,
                              scrollOffsetX: scrollOffsetX, viewportWidth: viewportWidth,
                              clipDuration: clipDuration, isReversed: isReversed,
                              loopRange: loopRange)
            ctx.stroke(markers, with: .color(strokeColor.opacity(0.6)),
                       style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        }
    }
}

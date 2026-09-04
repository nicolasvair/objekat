import SwiftUI

/// Drawing a clip's waveform into a SwiftUI `GraphicsContext`, in coordinates LOCAL to the
/// block (origin 0,0, size = `size`). A single source shared by:
///   - `TimelineWaveformView` (one Canvas per block — the rich/selected case),
///   - the SINGLE blocks Canvas (`TimelineBlocksCanvas`) which translates the context onto
///     each block then calls this drawing (1 view node for N blocks).
/// The same logic as the old one (peaks vs samples, fade/gain/speed/reverse at render time).
enum WaveformDrawing {

    /// The BATCHED variant (peaks mode): instead of filling, it ADDS the waveform's polygon to
    /// `path` in CANVAS coordinates (offset by originX/originY). The caller accumulates one Path
    /// per fill colour and fills ONCE (≈ 1 op instead of N). Returns `false`
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
        waveformDisplayDB: Double,
        loopRange: (start: Double, end: Double)? = nil
    ) -> Bool {
        guard let fileDuration = waveformCache.duration(for: filePath), fileDuration > 0 else { return true }
        let sampleModeThreshold = (WaveformCache.effectiveDensitiesPerSecond.last ?? 10000) * 3
        if pixelsPerSecond >= sampleModeThreshold { return false }   // samples mode → drawn individually
        guard let peaks = waveformCache.peaks(for: filePath, pixelsPerSecond: pixelsPerSecond),
              !peaks.isEmpty else { return true }

        let gainLin = WaveformShaping.linearGain(dB: volumeDb)
        let displayGain = WaveformShaping.linearGain(dB: Float(waveformDisplayDB))
        let h = size.height
        let mid = h * 0.5
        let vScale = mid * displayGain
        func mul(_ i: Int) -> Double {
            gainLin * WaveformShaping.fadeEnvelope(localTime: Double(i) / pixelsPerSecond,
                                                   duration: clipDuration, fadeIn: fadeIn, fadeOut: fadeOut)
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
        func clampY(_ y: Double) -> Double { min(h, max(0, y)) }
        func pt(_ i: Int, _ y: Double) -> CGPoint { CGPoint(x: originX + Double(i), y: originY + y) }

        let margin: CGFloat = 2
        let visStart = max(0, scrollOffsetX - CGFloat(originX) - margin)
        let visEnd   = min(size.width, scrollOffsetX + viewportWidth - CGFloat(originX) + margin)
        let startI = Int(visStart)
        let endI   = Int(visEnd)
        guard endI > startI else { return true }

        let n = peaks.count
        path.move(to: pt(startI, mid))
        for i in startI...endI {
            let fraction = loopedSrc(i) / fileDuration
            var amp = 0.0
            if fraction >= 0, fraction < 1 {
                let idx = min(Int(fraction * Double(n)), n - 1)
                amp = Double(peaks[idx].hi) * mul(i)
            }
            path.addLine(to: pt(i, clampY(mid - amp * vScale)))
        }
        for i in stride(from: endI, through: startI, by: -1) {
            let fraction = loopedSrc(i) / fileDuration
            var amp = 0.0
            if fraction >= 0, fraction < 1 {
                let idx = min(Int(fraction * Double(n)), n - 1)
                amp = Double(peaks[idx].lo) * mul(i)
            }
            path.addLine(to: pt(i, clampY(mid - amp * vScale)))
        }
        path.closeSubpath()
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
        isMuted: Bool,
        waveformDisplayDB: Double,
        loopRange: (start: Double, end: Double)? = nil
    ) {
        guard let fileDuration = waveformCache.duration(for: filePath), fileDuration > 0 else { return }

        let sampleModeThreshold = (WaveformCache.effectiveDensitiesPerSecond.last ?? 10000) * 3
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
                localTime: localT, duration: clipDuration, fadeIn: fadeIn, fadeOut: fadeOut)
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
        let region = pixelsPerSecond >= sampleModeThreshold
            ? waveformCache.samplesRegion(for: filePath, fileStart: winStart, fileEnd: winEnd)
            : nil

        if let region {
            let samples = region.samples
            let sr = region.sampleRate
            let n = samples.count
            var poly = Path()
            var filled = Path()
            filled.move(to: CGPoint(x: Double(startI), y: mid))
            var started = false
            for i in startI...endI {
                let sIdx = (loopedSrc(i) - region.startTime) * sr
                var value: Double
                if sIdx < 0 || sIdx >= Double(n - 1) {
                    value = 0
                } else {
                    let i0 = Int(sIdx.rounded(.down))
                    let frac = sIdx - Double(i0)
                    value = Double(samples[i0]) * (1 - frac) + Double(samples[i0 + 1]) * frac
                }
                value *= mul(i)
                let y = clampY(mid - value * vScale)
                let p = CGPoint(x: Double(i), y: y)
                filled.addLine(to: p)
                if !started { poly.move(to: p); started = true }
                else { poly.addLine(to: p) }
            }
            filled.addLine(to: CGPoint(x: Double(endI), y: mid))
            filled.closeSubpath()
            ctx.fill(filled, with: .color(fillColor))
            ctx.stroke(poly, with: .color(strokeColor), lineWidth: 1)

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
        } else if let peaks = waveformCache.peaks(for: filePath, pixelsPerSecond: pixelsPerSecond),
                  !peaks.isEmpty {
            let n = peaks.count
            var path = Path()
            path.move(to: CGPoint(x: Double(startI), y: mid))
            for i in startI...endI {
                let fraction = loopedSrc(i) / fileDuration
                var amp = 0.0
                if fraction >= 0, fraction < 1 {
                    let idx = min(Int(fraction * Double(n)), n - 1)
                    amp = Double(peaks[idx].hi) * mul(i)
                }
                path.addLine(to: CGPoint(x: Double(i), y: clampY(mid - amp * vScale)))
            }
            for i in stride(from: endI, through: startI, by: -1) {
                let fraction = loopedSrc(i) / fileDuration
                var amp = 0.0
                if fraction >= 0, fraction < 1 {
                    let idx = min(Int(fraction * Double(n)), n - 1)
                    amp = Double(peaks[idx].lo) * mul(i)
                }
                path.addLine(to: CGPoint(x: Double(i), y: clampY(mid - amp * vScale)))
            }
            path.closeSubpath()
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

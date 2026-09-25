import SwiftUI

struct GroupWaveformView: View {
    var waveformCache: WaveformCache
    let children: [SoundObject]
    let groupStartTime: Double
    let pixelsPerSecond: Double
    let stemColor: Color
    // The block's absolute position (= the GroupBlockView's .offset) plus the visible window,
    // so as to bound the drawing to the screen: at high zoom the block is millions of px wide.
    let blockXPos: Double
    let scrollOffsetX: CGFloat
    let viewportWidth: CGFloat
    // The (gain/fade) modifier of the group block itself, applied to the WHOLE composite.
    // Subgroups add their own recursively (nesting).
    let rootMod: WaveformShaping.Modifier
    // Is the group block itself muted? → a greyed-out composite (on its own block).
    let rootMuted: Bool
    let waveformDisplayDB: Double
    /// The GROUP's own loop (not a child's): the envelope of its DIRECT children repeats for as
    /// long as the group's window exceeds it — @see SoundObject.canLoop/groupContentSpan,
    /// OBJEngineCore.mm refreshContainerSpanForKey (the same envelope computation). The WHOLE
    /// composite (every descendant flattened, not just markers) is redrawn on each repeat,
    /// bounded by the visible window like the rest of the canvas. @see [[loop-item-plan]]
    /// The loop's IN/OUT bounds, in seconds LOCAL to the block (`nil` = no loop).
    /// @see SoundObject.loopMarkerLocalRange
    var loopRange: (start: Double, end: Double)? = nil

    /// A ceiling on redrawn repeats: a very short period at high zoom must not generate an
    /// unreasonable number of iterations (the same safeguard as MidiNotesPreview).
    private static let maxLoopRepeats = 2000

    private func modifier(for o: SoundObject) -> WaveformShaping.Modifier {
        WaveformShaping.Modifier(
            absStart: o.startTime, duration: o.duration,
            fadeIn: o.fadeIn, fadeOut: o.fadeOut,
            curveIn: o.fadeInCurve, curveOut: o.fadeOutCurve,
            gain: WaveformShaping.linearGain(dB: o.volume))
    }

    /// A ceiling on expanded instances, all depths together: two nested loops multiply their
    /// repeats, and the product has to stay bounded.
    private static let maxInstances = 4000

    /// One occurrence of a descendant clip, placed in the ROOT BLOCK's frame of reference.
    private struct ClipInstance {
        let clip: SoundObject
        let mods: [WaveformShaping.Modifier]
        /// The cumulative offset (s) to add to `clip.startTime - groupStartTime`: the sum of the
        /// loop foldings crossed on the way down. 0 when nothing loops.
        let shift: Double
        /// The window (in s, local to the root block) outside which this occurrence is cut:
        /// the intersection of the windows of every ancestor group and of their repeats.
        let winLo: Double
        let winHi: Double
    }

    /// Expands the descendants into instances recursively. Each ancestor group brings two things:
    /// its WINDOW — whatever overflows is cut by the container, on the engine side as here —
    /// and, if it loops, its REPEATS. That second point is what the composite ignored: only the
    /// root block's loop was expanded, so that a looped group NESTED in another never showed
    /// more than its first period, the waveform coming adrift from the sound at the very next
    /// repeat. The folding is the same as at the root and as on the engine side — the material at
    /// the IN point lands at the start of each period (@see refreshContainerSpanForKey:).
    /// A MUTED descendant (a clip or a subgroup) is LEFT OUT of the parent's composite.
    private func expand(_ objs: [SoundObject],
                        shift: Double,
                        win: (lo: Double, hi: Double),
                        mods: [WaveformShaping.Modifier],
                        visible: (lo: Double, hi: Double),
                        into out: inout [ClipInstance]) {
        guard win.hi > win.lo else { return }
        for o in objs {
            if o.isMuted { continue }   // a muted child → nothing in the parent group
            guard out.count < Self.maxInstances else { return }
            let start = o.startTime - groupStartTime + shift
            let lo = max(win.lo, start)
            let hi = min(win.hi, start + o.duration)
            // Outside the parent's window, or off screen: nothing to expand.
            guard hi > lo, hi > visible.lo, lo < visible.hi else { continue }

            switch o.kind {
            case .clip:
                out.append(ClipInstance(clip: o, mods: mods + [modifier(for: o)],
                                        shift: shift, winLo: lo, winHi: hi))
            case .aux, .midiClip:
                continue   // an aux (receive only) / a MIDI clip (no precomputed wave)
            case .group(let sub, _):
                let subMods = mods + [modifier(for: o)]
                guard let r = o.loopMarkerLocalRange, r.end - r.start > 0.02 else {
                    expand(sub, shift: shift, win: (lo, hi), mods: subMods,
                           visible: visible, into: &out)
                    continue
                }
                let period = r.end - r.start
                let origin = min(0, r.start)   // the origin of the repeats — @see body
                let from   = max(lo, visible.lo)
                let until  = min(hi, visible.hi)
                var k = max(0, Int(((from - start - origin) / period).rounded(.down)))
                while start + origin + Double(k) * period < until, out.count < Self.maxInstances {
                    expand(sub,
                           shift: shift + origin + Double(k) * period - r.start,
                           win: (max(lo, start + origin + Double(k) * period),
                                 min(hi, start + origin + Double(k + 1) * period)),
                           mods: subMods, visible: visible, into: &out)
                    k += 1
                }
            }
        }
    }

    var body: some View {
        Canvas { ctx, size in
            let h = size.height
            let mid = h * 0.5
            // the block's edge = 0 dBFS; waveform zoom (display dB, without touching the sound).
            let vScale = mid * WaveformShaping.linearGain(dB: Float(waveformDisplayDB))
            // A muted group (on its own block) = a greyed-out composite.
            let fillColor = rootMuted ? Color.gray.opacity(0.4) : stemColor.opacity(0.55)

            // The visible window in the block's local coordinates (x=0 = the block's left edge).
            let margin: CGFloat = 2
            let visStart = Int(max(0, scrollOffsetX - CGFloat(blockXPos) - margin))
            let visEnd   = Int(min(size.width, scrollOffsetX + viewportWidth - CGFloat(blockXPos) + margin))
            guard visEnd > visStart else { return }

            // The GROUP's loop: how many times to redraw the whole composite, and at what pitch.
            // The period = the [IN,OUT] slice the model set; it repeats FROM THE BLOCK'S LEFT EDGE
            // (the left edge plays the part of the IN point), exactly like the engine's folding —
            // @see refreshContainerSpanForKey:, WaveformDrawing.LoopFold.
            var groupPeriod = 0.0
            var loopStart = 0.0
            var loopOrigin = 0.0
            var repeats: [Int] = [0]
            if let r = loopRange, r.end - r.start > 0.02, !children.isEmpty {
                groupPeriod = r.end - r.start
                loopStart   = r.start
                // The ORIGIN of the repeats, local to the block. The engine sets the container's offset
                // to max(0, start − IN): as long as the IN point lives INSIDE the block — the ordinary
                // case — that offset is zero and the first period starts at the LEFT edge.
                // When the IN PRECEDES the block (the right half of a cut looped group, @see
                // EditViewModel.loopedGroupRightHalf), it is what sets the origin: the grid of repeats
                // is offset by as much, and that is exactly what preserves the phase across the cut.
                // @see refreshContainerSpanForKey:
                loopOrigin  = min(0, r.start)
                let tStart = Double(visStart) / pixelsPerSecond
                let tEnd   = Double(visEnd) / pixelsPerSecond
                let kMin = max(0, Int(((tStart - loopOrigin) / groupPeriod).rounded(.down)))
                let kMax = max(kMin, Int(((tEnd - loopOrigin) / groupPeriod).rounded(.down)))
                repeats = Array(kMin...min(kMax, kMin + Self.maxLoopRepeats))
            }
            let looping = groupPeriod > 0

            // The full expansion: the root block's repeats, AND those of every looped group met
            // on the way down. Each instance knows where it is laid (`shift`) and how far it is
            // allowed to extend (`winLo`/`winHi`) — the windows of the containers crossed, their
            // repeats included.
            let blockDuration = Double(size.width) / pixelsPerSecond
            let visible = (lo: Double(visStart) / pixelsPerSecond,
                           hi: Double(visEnd)   / pixelsPerSecond)
            var instances: [ClipInstance] = []
            for k in repeats {
                // The composite's offset for this repeat: the material at `loopStart` lands at the
                // start of period k.
                let shift = loopOrigin + Double(k) * groupPeriod - (looping ? loopStart : 0)
                // Each repeat shows ONLY its period: whatever goes past the OUT point is cut by the
                // folding on the engine side, and must not bleed onto the next repeat.
                let repLo = looping ? loopOrigin + Double(k) * groupPeriod : 0
                let repHi = looping ? min(blockDuration, loopOrigin + Double(k + 1) * groupPeriod)
                                    : blockDuration
                expand(children, shift: shift, win: (repLo, repHi), mods: [rootMod],
                       visible: visible, into: &instances)
            }

            for inst in instances {
                let child = inst.clip
                let mods  = inst.mods
                let shift = inst.shift
                guard case .clip(let filePath, let sourceOffset, _, let speedRatio, let isReversed) = child.kind,
                      let fileDuration = waveformCache.duration(for: filePath),
                      fileDuration > 0
                else { continue }

                let relStart = child.startTime - groupStartTime + shift
                // The instance's bounds ∩ the containers' windows ∩ the visible window.
                let xStart = max(max(0, Int(inst.winLo * pixelsPerSecond)), visStart)
                let xEnd   = min(min(Int(size.width), Int(inst.winHi * pixelsPerSecond)), visEnd)
                guard xEnd > xStart else { continue }

                // The child's OWN loop (independent of the group's): the same rule as
                // WaveformDrawing (@see [[loop-item-plan]]).
                let loopPeriod = (child.loopEnabled && !isReversed && fileDuration > sourceOffset)
                    ? fileDuration - sourceOffset : nil

                // The file time at a local pixel's left edge (the child's own loop folded in).
                func fileTime(_ i: Int) -> Double {
                    let timeInChild = Double(i) / pixelsPerSecond - relStart
                    var t = WaveformShaping.sourceTime(
                        localTime: timeInChild, sourceOffset: sourceOffset,
                        duration: child.duration, speedRatio: speedRatio, isReversed: isReversed)
                    if let period = loopPeriod, period > 0, t >= fileDuration {
                        t = sourceOffset + (t - sourceOffset).truncatingRemainder(dividingBy: period)
                    }
                    return t
                }
                // A column's file span, unfolded — @see WaveformDrawing.appendPeaksFill.
                let srcStep = (isReversed ? -speedRatio : speedRatio) / pixelsPerSecond

                // The file window on screen, for the samples region past the threshold — the SAME
                // path a top-level clip takes, which is the whole point: the composite used to read
                // peaks only, capped at 1 000/s, and showed steps where the clip was smooth. Under
                // the child's own loop the folded times are not monotonic, so the window is the
                // span actually visited, measured rather than taken from the two ends.
                var window: (lo: Double, hi: Double)? = nil
                if pixelsPerSecond >= WaveformCache.sampleModeThreshold {
                    var lo = Double.infinity, hi = -Double.infinity
                    if loopPeriod != nil {
                        for i in xStart...xEnd {
                            let a = fileTime(i)
                            lo = min(lo, a, a + srcStep); hi = max(hi, a, a + srcStep)
                        }
                    } else {
                        let a = fileTime(xStart), b = fileTime(xEnd) + srcStep
                        lo = min(a, b); hi = max(a, b)
                    }
                    window = (lo, hi)
                }
                guard let source = WaveformDrawing.envelopeSource(
                    waveformCache: waveformCache, filePath: filePath,
                    pixelsPerSecond: pixelsPerSecond, window: window) else { continue }

                var path = Path()
                WaveformDrawing.appendEnvelopeFill(
                    to: &path, from: xStart, through: xEnd,
                    x: { Double($0) }, y0: 0, h: h, mid: mid, vScale: vScale) { i in
                    let a = fileTime(i)
                    // MERGED, even for a stereo child: the composite stays ONE silhouette. It is
                    // many clips laid over each other at half opacity, and its band is the group's
                    // — a left/right split there would stack every child's left over every other
                    // child's, a picture of no channel anybody hears. The clip's own block is where
                    // its two lanes are read (@see WaveformDrawing.appendLanesFill).
                    let e = source.mergedEnvelope(fileA: a, fileB: a + srcStep)
                    // The ORIGINAL position (before the repeat offset) for the fades: the repeated
                    // pattern replays the same gain envelope, not a fade reset on it.
                    let t = groupStartTime + Double(i) / pixelsPerSecond - shift
                    let m = WaveformShaping.combinedMultiplier(mods, atAbsTime: t)
                    return (Double(e.lo) * m, Double(e.hi) * m)
                }
                ctx.fill(path, with: .color(fillColor))
                // Under one sample per pixel the envelope degenerates to a line (lo == hi, @see
                // WaveformPeaks.sampleEnvelope): a fill with no area draws nothing, so the outline
                // carries it — what the clip's own stroke does in WaveformDrawing.draw.
                if let r = source.region, r.sampleRate * abs(srcStep) < 2 {   // the same rule as WaveformDrawing.draw
                    ctx.stroke(path, with: .color(fillColor), lineWidth: 1)
                }
            }

            if looping {
                var markers = Path()
                for k in repeats {
                    let t = loopOrigin + Double(k) * groupPeriod
                    guard t > 0.02 else { continue }
                    let x = t * pixelsPerSecond
                    markers.move(to: CGPoint(x: x, y: 0))
                    markers.addLine(to: CGPoint(x: x, y: h))
                }
                ctx.stroke(markers, with: .color(stemColor.opacity(0.5)),
                          style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
        }
        .allowsHitTesting(false)
    }
}

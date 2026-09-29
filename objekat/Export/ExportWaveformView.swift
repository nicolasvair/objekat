import SwiftUI

// The waveform of a render, drawn as it is made.
//
// The peaks come from the engine's tap on the render (@see OBJEngineCore `exportPeaks`), which
// hands over min/max pairs for the buckets it has already filled — so the drawing does not have
// to be told how far the render has got: the DATA says it, and the part still to come is drawn as
// an empty channel. That is what makes the growth readable without a second number to keep in
// step with the first.
//
// It is also the audition's dial: the play head is a line over it and a click seeks. Hence the
// whole width standing for the RANGE ASKED FOR and not for what has been rendered — a bar that
// rescaled itself as it filled would move the instant under the finger at every frame.
//
// LOUDNESS is drawn OVER it, on the same time axis: momentary (400 ms), short-term (3 s) and
// integrated curves, on a −60…0 LUFS scale that runs the band's height. They come from the same
// tap (@see LoudnessAnalysis) and grow at the same pace as the waveform — the integrated one is
// what the meter would have read had the render stopped there, so its last point is the running
// answer. Hovering the band reads the three values at that instant.
struct ExportWaveformView: View {

    /// Peak pairs (min, max) interleaved, one pair per bucket, from the render's start.
    let peaks: [Float]
    /// How many buckets the whole render is cut into (the full width). @see OBJEngineCore.
    let resolution: Int
    /// The audition's position, in 0…1 of the range. nil = nobody is listening.
    let playhead: Double?
    /// Where the listening could reach right now (what has been flushed to disk), 0…1.
    let audible: Double?
    /// A click in the band, in 0…1 of the range.
    let onSeek: (Double) -> Void
    /// What has been measured of the loudness so far. Empty draws no curve.
    var loudness = LoudnessAnalysis()
    /// The length of the range the band's full width stands for, in seconds — the same axis the
    /// waveform and the listening use.
    var duration: Double = 0

    /// Where the mouse rests over the band (x, in points). nil = elsewhere.
    @State private var hoverX: CGFloat?

    /// The scale of the curves: the band's top is 0 LUFS, its bottom −60. Under that is silence for
    /// any practical purpose, and a scale that tried to show −70 would spend a sixth of its height
    /// on nothing.
    static let scaleTop = 0.0
    static let scaleBottom = -60.0

    private var filled: Int { min(peaks.count / 2, resolution) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            Canvas { ctx, size in
                draw(ctx: &ctx, size: size)
            }
            .contentShape(Rectangle())
            // Reading the curves under the mouse: a hover only ever DRAWS, it changes no state that
            // anything else reads, so it cannot get in the seek's way.
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hoverX = p.x
                case .ended: hoverX = nil
                }
            }
            .onTapGesture { p in
                guard w > 0 else { return }
                onSeek(min(1, max(0, p.x / w)))
            }
            // Dragging aims, and lands where the hand LETS GO — not at every pixel on the way.
            // Seeking here means restarting the listening at another frame of the file; done on
            // every frame of a drag it would stutter through fifty restarts rather than scrub.
            .gesture(DragGesture(minimumDistance: 2).onEnded { g in
                guard w > 0 else { return }
                onSeek(min(1, max(0, g.location.x / w)))
            })
            .frame(width: w, height: h)
        }
        .frame(height: 64)
        .background(Color.black.opacity(0.22))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    private func draw(ctx: inout GraphicsContext, size: CGSize) {
        let w = size.width, h = size.height
        guard w > 1, h > 1, resolution > 0 else { return }
        let mid = h / 2

        // The zero line runs the whole width: it is what says that the empty part to the right is
        // a channel still to be filled and not the end of the material.
        ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: mid)); $0.addLine(to: CGPoint(x: w, y: mid)) },
                   with: .color(.white.opacity(0.12)), lineWidth: 1)

        guard filled > 0 else { return }
        let step = w / CGFloat(resolution)
        let barWidth = max(1, step)

        var path = Path()
        for i in 0..<filled {
            let lo = CGFloat(peaks[i * 2])
            let hi = CGFloat(peaks[i * 2 + 1])
            let top = mid - hi * mid
            let bottom = mid - lo * mid
            // A silent bucket still draws a hairline: a rendered silence is not the same thing as
            // a passage not yet rendered, and the eye must be able to tell them apart.
            let y = min(top, bottom)
            let height = max(1, abs(bottom - top))
            path.addRect(CGRect(x: CGFloat(i) * step, y: y, width: barWidth, height: height))
        }
        ctx.fill(path, with: .color(.accentColor.opacity(0.85)))

        // What can be heard: the render runs ahead of the flush, so there is always a sliver of
        // waveform already drawn that cannot yet be played. Saying so avoids the reading that a
        // click over there did nothing.
        if let audible, audible > 0, audible < 1 {
            let x = w * CGFloat(min(1, audible))
            ctx.fill(Path(CGRect(x: x, y: 0, width: w - x, height: h)),
                     with: .color(.black.opacity(0.22)))
        }

        drawLoudness(ctx: &ctx, size: size)

        if let playhead {
            let x = w * CGFloat(min(1, max(0, playhead)))
            ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: h)) },
                       with: .color(.white.opacity(0.9)), lineWidth: 1)
        }
    }

    // MARK: - Loudness

    /// The three curves, then the hover's reading. Momentary is the thin one, short-term the
    /// medium, integrated the bold — the slower the reading, the heavier the line.
    private func drawLoudness(ctx: inout GraphicsContext, size: CGSize) {
        let w = size.width, h = size.height
        guard loudness.blockCount > 0, duration > 0 else { return }
        let step = LoudnessAnalysis.subblockSeconds

        // A window's value is stamped at the instant it ENDS, which is what a meter does.
        let curves: [(values: [Double], firstEnd: Double, color: Color, width: CGFloat)] = [
            (loudness.momentary, Double(LoudnessAnalysis.momentaryBlocks) * step,
             Color.mint.opacity(0.85), 1),
            (loudness.shortTerm, Double(LoudnessAnalysis.shortTermBlocks) * step,
             Color.yellow.opacity(0.9), 1.25),
            (loudness.integratedCurve, Double(LoudnessAnalysis.momentaryBlocks) * step,
             Color.white, 1.75),
        ]
        for curve in curves {
            let path = polyline(values: curve.values, firstEnd: curve.firstEnd, w: w, h: h)
            ctx.stroke(path, with: .color(curve.color),
                       style: StrokeStyle(lineWidth: curve.width, lineCap: .round, lineJoin: .round))
        }

        guard let x = hoverX, w > 0 else { return }
        let t = Double(min(max(0, x), w) / w) * duration
        // The sub-block whose window ended at or before the hovered instant.
        let k = min(loudness.blockCount - 1, Int(t / step) - 1)
        guard k >= 0 else { return }
        let v = loudness.values(atSubblock: k)
        func reading(_ label: String, _ value: Double?) -> String {
            guard let value else { return "\(label) –" }
            return value.isFinite ? String(format: "\(label) %.1f", value) : "\(label) −∞"
        }
        let instant = Double(k + 1) * step
        let minutes = Int(instant) / 60
        let clock = String(format: "%d:%04.1f", minutes, instant - Double(minutes * 60))
        let label = "\(clock)  \(reading("M", v.momentary))  \(reading("S", v.shortTerm))  \(reading("I", v.integrated))"

        ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: h)) },
                   with: .color(.white.opacity(0.35)), lineWidth: 1)

        let resolved = ctx.resolve(Text(verbatim: label)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundColor(.white))
        let box = resolved.measure(in: CGSize(width: 400, height: 40))
        // On the side of the line that has room, never past the band's edges.
        let onRight = x + 6 + box.width + 6 <= w
        let left = onRight ? x + 6 : max(2, x - 6 - box.width - 6)
        let rect = CGRect(x: left, y: 3, width: box.width + 6, height: box.height + 2)
        ctx.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(.black.opacity(0.72)))
        ctx.draw(resolved, at: CGPoint(x: rect.minX + 3, y: rect.minY + 1), anchor: .topLeading)
    }

    /// One curve as a path, at most about one point per pixel column: a long render holds far more
    /// values than the band has pixels, and a column shows the mean of what falls in it. Values are
    /// clamped to the scale BEFORE averaging so a −∞ (silence) reads as the floor instead of
    /// poisoning the mean.
    private func polyline(values: [Double], firstEnd: Double, w: CGFloat, h: CGFloat) -> Path {
        var path = Path()
        let n = values.count
        guard n > 0, w > 1, duration > 0 else { return path }
        let step = LoudnessAnalysis.subblockSeconds
        let stride = max(1, n / max(1, Int(w)))
        let span = Self.scaleTop - Self.scaleBottom
        var started = false
        var k = 0
        while k < n {
            let end = min(n, k + stride)
            var sum = 0.0
            for j in k..<end {
                let v = values[j]
                sum += min(Self.scaleTop, max(Self.scaleBottom, v.isNaN ? Self.scaleBottom : v))
            }
            let mean = sum / Double(end - k)
            let t = firstEnd + Double(end - 1) * step
            let x = CGFloat(min(1, t / duration)) * w
            let y = CGFloat((Self.scaleTop - mean) / span) * (h - 4) + 2
            if started { path.addLine(to: CGPoint(x: x, y: y)) }
            else { path.move(to: CGPoint(x: x, y: y)); started = true }
            k = end
        }
        return path
    }
}
